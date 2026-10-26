import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { R, W, base64, concat, hex, mpint, sshStr, text, utf8 } from './SshWire';
import {
  AesCtr, ed25519Sign, ed25519SpkiFromRaw, ed25519Verify, hmacSha256, safeEqual, sha256,
  x25519Generate, x25519Secret, X25519Pair
} from './SshCrypto';

/**
 * 最小 SSH 客户端（**只做一条 exec 命令 + 读输出**，够把电脑上的 dsh 拉起来）。
 *
 * 为什么自己实现：鸿蒙没有 SSH API、ohpm 也没有可用组件；底层原语系统齐备，
 * 我们只落地 OpenSSH 默认套件里最小的一组：
 *   kex    curve25519-sha256
 *   hostkey ssh-ed25519（校验服务端签名，证明 K/H 与服务端一致）
 *   cipher  aes128-ctr
 *   mac     hmac-sha2-256
 *   auth    publickey ssh-ed25519（手机侧身份，见 SshKeys）
 *   压缩    none
 * 字节级流程先在 Node 原型（tools/dsh-launcher/min-ssh.mjs）跑通（真机 sshd 实测 200），
 * 这里 1:1 移植；**改动协议细节请先改 Node 原型再同步这里**。
 *
 * 两个踩过的坑（改代码前先看）：
 *  ① KDF 的 K 必须是 **SSH string** 形式（4 字节长度 + mpint 内容）——
 *     只塞 mpint 内容会让首个加密包在服务端报 `Bad packet length`；
 *  ② userauth 的签名字段本身也是 **string**，里面再套（算法名 + 签名）两个 string，
 *     少套一层就是"签名被解析成算法名"（11 字节），认证必挂。
 */

const DOMAIN: number = 0xD001;
const TAG: string = 'SSH';

const MSG_DISCONNECT: number = 1;
const MSG_IGNORE: number = 2;
const MSG_UNIMPLEMENTED: number = 3;
const MSG_DEBUG: number = 4;
const MSG_SERVICE_REQUEST: number = 5;
const MSG_SERVICE_ACCEPT: number = 6;
const MSG_KEXINIT: number = 20;
const MSG_NEWKEYS: number = 21;
const MSG_KEX_ECDH_INIT: number = 30;
const MSG_KEX_ECDH_REPLY: number = 31;
const MSG_USERAUTH_REQUEST: number = 50;
const MSG_USERAUTH_SUCCESS: number = 52;
const MSG_GLOBAL_REQUEST: number = 80;
const MSG_REQUEST_FAILURE: number = 82;
const MSG_CHANNEL_OPEN: number = 90;
const MSG_CHANNEL_OPEN_CONFIRMATION: number = 91;
const MSG_CHANNEL_OPEN_FAILURE: number = 92;
/** 累计消费多少字节回一次窗口（32 KiB） */
const WINDOW_ADJUST_BYTES: number = 32768;
const MSG_CHANNEL_DATA: number = 94;
/** 90 | SSH_MSG_CHANNEL_WINDOW_ADJUST */
const MSG_CHANNEL_WINDOW_ADJUST: number = 93;
const MSG_CHANNEL_EXTENDED_DATA: number = 95;
const MSG_CHANNEL_CLOSE: number = 97;
const MSG_CHANNEL_REQUEST: number = 98;
const MSG_CHANNEL_SUCCESS: number = 99;
const MSG_CHANNEL_FAILURE: number = 100;

const MAX_PACKET: number = 256 * 1024;
const BLOCK: number = 16;
const MAC_LEN: number = 32;
/**
 * 送出去的算法名。**只报一种**，避免"客户端偏好 vs 服务端偏好"的协商歧义；
 * 这三个在 OpenSSH 8.0+ 的默认套件里都在。
 */
const CIPHER_NAME: string = 'aes128-ctr';
const KEY_LEN: number = 16;

export interface SshExecOptions {
  host: string;
  port: number;
  user: string;
  command: string;
  /** 手机侧身份私钥（Ed25519） */
  priKey: cryptoFramework.PriKey;
  /** 手机侧身份公钥（裸 32 字节） */
  rawPub: Uint8Array;
  /** 单条命令的总超时（毫秒）；launcher 自己最多等 40s ⇒ 超时给 60s */
  timeoutMs: number;
  /** 这台电脑第一次连时记住的主机指纹（空 = 第一次，连成功后由调用方保存） */
  expectedHostKey?: string;
}

export interface SshExecResult {
  ok: boolean;
  output: string;
  /** 失败原因（人话，直接可上界面） */
  error: string;
}

/** 读等待者：超时/断开都要能准确 settle 一次 */
class Waiter {
  resolve: (p: Uint8Array) => void = (p: Uint8Array) => {
  };
  reject: (e: Error) => void = (e: Error) => {
  };
  timer: number = -1;
}

export class SshClient {
  private sock: socket.TCPSocket | undefined = undefined;
  private rx: Uint8Array = new Uint8Array(0);
  private queue: Uint8Array[] = [];
  private waiters: Waiter[] = [];
  private closed: boolean = false;
  private failure: string = '';

  private seqOut: number = 0;
  private seqIn: number = 0;
  private enc: AesCtr | undefined = undefined;
  private dec: AesCtr | undefined = undefined;
  private macOut: Uint8Array = new Uint8Array(0);
  private macIn: Uint8Array = new Uint8Array(0);
  private headDec: Uint8Array | undefined = undefined;
  private headLen: number = 0;

  private versionDone: boolean = false;
  private serverVersion: string = '';
  private sessionId: Uint8Array = new Uint8Array(0);
  private fingerprint: string = '';

  /** 这台电脑的主机公钥指纹（SHA256(公钥 blob) 的 base64；连成功后由调用方固定） */
  hostKeyFingerprint(): string {
    return this.fingerprint;
  }
  /** 整次 exec 的总截止时刻（握手/认证/执行都受它约束） */
  private deadlineMs: number = 0;
  private versionTimer: number = -1;

  /** 单次读取超时：不超过 10s，也不超过整次 exec 的剩余时间 */
  private ioTimeout(perRead: number = 10000): number {
    if (this.deadlineMs <= 0) {
      return perRead;
    }
    const left: number = this.deadlineMs - Date.now();
    if (left <= 0) {
      return 1;
    }
    return left < perRead ? left : perRead;
  }

  /** 连上并跑一条命令；**全过程自带超时**，绝不挂死界面 */
  async exec(opts: SshExecOptions): Promise<SshExecResult> {
    this.deadlineMs = Date.now() + opts.timeoutMs;
    // 总超时看门狗：握手/认证循环即使被对端持续喂包，也会在到点后断开
    const watchdog: number = setTimeout(() => {
      this.fail(`SSH 总超时（${opts.timeoutMs}ms）`);
    }, opts.timeoutMs + 1500);
    try {
      hilog.info(DOMAIN, TAG, 'exec：连接 %{public}s:%{public}d', opts.host, opts.port);
      await this.connect(opts);
      hilog.info(DOMAIN, TAG, 'exec：版本交换完成');
      await this.kexAndAuth(opts);
      hilog.info(DOMAIN, TAG, 'exec：开始执行命令');
      const out: string = await this.runCommand(opts);
      return { ok: true, output: out, error: '' } as SshExecResult;
    } catch (error) {
      const e = error as BusinessError;
      const message: string = e !== undefined && e.message !== undefined ? e.message : '未知错误';
      const where: string = e !== undefined && e.stack !== undefined ? `${e.stack}` : '';
      hilog.warn(DOMAIN, TAG, 'SSH 失败：%{public}s', message);
      hilog.warn(DOMAIN, TAG, 'SSH 栈：%{public}s', where.substring(0, 400));
      return { ok: false, output: '', error: message } as SshExecResult;
    } finally {
      clearTimeout(watchdog);
      this.shutdown();
    }
  }

  shutdown(): void {
    try {
      this.sock?.close();
    } catch (error) {
      // 已关闭，忽略
    }
    this.sock = undefined;
    this.fail('已关闭');
  }

  // ── 连接与版本交换 ───────────────────────────────────────

  /**
   * 建 TCP、发自己的版本行、**等对端版本行到齐**再往下走。
   * ⚠️ 等版本行这一步不能省：H 里要带对方的版本字符串，早一步算 KEXINIT 就是错的版本字节。
   */
  private async connect(opts: SshExecOptions): Promise<void> {
    const sock: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.sock = sock;
    sock.on('message', (info: socket.SocketMessageInfo) => {
      // 解析失败（包含 MAC 校验失败）必须就地转成连接失败，不能让异常从回调里冒出去：
      // 以前某个 waiter 会一直挂到超时，界面只看到"等对端回包超时"
      try {
        this.onData(new Uint8Array(info.message));
      } catch (error) {
        const e = error as Error;
        this.fail(`解析 SSH 回包失败：${e.message}`);
      }
    });
    sock.on('close', () => {
      this.fail('连接已断开');
    });
    sock.on('error', (err: BusinessError) => {
      this.fail(`socket 错误 code=${err === undefined ? -1 : err.code}`);
    });
    const addr: socket.NetAddress = { address: opts.host, port: opts.port };
    try {
      await sock.connect({ address: addr, timeout: this.ioTimeout(10000) });
    } catch (error) {
      const e = error as BusinessError;
      throw new Error(`连不上 ${opts.host}:${opts.port}（code=${e === undefined ? -1 : e.code}）`);
    }
    hilog.info(DOMAIN, TAG, 'TCP 已连 %{public}s:%{public}d', opts.host, opts.port);
    // 客户端版本行：服务端会拿它算 H，**必须与下面 H 计算里用的完全一致**
    const vc: string = 'SSH-2.0-dsh-phone_1.0';
    this.versionString = vc;
    try {
      await this.writeRaw(concat([utf8(vc), new Uint8Array([13, 10])]));
    } catch (error) {
      const e = error as BusinessError;
      throw new Error(`发送版本行失败 code=${e === undefined ? -1 : e.code}）`);
    }
    await this.waitVersion(this.ioTimeout(10000));
  }

  /** 等对端版本行（`onData` 切出来后 settle） */
  private waitVersion(timeoutMs: number): Promise<void> {
    if (this.versionDone) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      // 对端在发版本行之前就断了：别等满 10 秒
      if (this.closed || this.failure.length > 0) {
        reject(new Error(this.failure.length > 0 ? this.failure : '连接已断开'));
        return;
      }
      this.versionWaiter = resolve;
      this.versionReject = reject;
      this.versionTimer = setTimeout(() => {
        this.versionTimer = -1;
        // 只有"还是这次等待"时才按超处理（已经由 fail/版本行 settle 过就不动）
        if (this.versionWaiter !== resolve) {
          return;
        }
        this.versionWaiter = undefined;
        this.versionReject = undefined;
        reject(new Error('等对端版本行超时'));
      }, timeoutMs);
    });
  }

  private versionWaiter: (() => void) | undefined = undefined;
  private versionReject: ((e: Error) => void) | undefined = undefined;

  private versionString: string = '';

  /** 收字节 → 切出版本行 → 循环解包 */
  private onData(chunk: Uint8Array): void {
    this.rx = concat([this.rx, chunk]);
    if (!this.versionDone) {
      let nl: number = -1;
      for (let i = 0; i < this.rx.length; i++) {
        if (this.rx[i] === 0x0a) {
          nl = i;
          break;
        }
      }
      if (nl < 0) {
        return;
      }
      let line: string = text(this.rx.slice(0, nl));
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.serverVersion = line;
      this.rx = this.rx.slice(nl + 1);
      this.versionDone = true;
      hilog.info(DOMAIN, TAG, '服务端版本 %{public}s', line);
      const vw: (() => void) | undefined = this.versionWaiter;
      this.versionWaiter = undefined;
      this.versionReject = undefined;
      if (this.versionTimer >= 0) {
        clearTimeout(this.versionTimer);
        this.versionTimer = -1;
      }
      if (vw !== undefined) {
        vw();
      }
    }
    while (this.closed) {
      return;
    }
    while (true) {
      const pkt: Uint8Array | undefined = this.tryParse();
      if (pkt === undefined) {
        return;
      }
      const w: Waiter | undefined = this.waiters.shift();
      if (w !== undefined) {
        if (w.timer >= 0) {
          clearTimeout(w.timer);
        }
        w.resolve(pkt);
      } else {
        this.queue.push(pkt);
      }
    }
  }

  private tryParse(): Uint8Array | undefined {
    const dec: AesCtr | undefined = this.dec;
    if (dec === undefined) {
      if (this.rx.length < 4) {
        return undefined;
      }
      const pktLen: number = this.u32At(this.rx, 0);
      if (pktLen < 5 || pktLen + 4 > MAX_PACKET) {
        throw new Error(`长度非法 ${pktLen}`);
      }
      if (this.rx.length < 4 + pktLen) {
        return undefined;
      }
      const padLen: number = this.rx[4];
      const body: Uint8Array = this.rx.slice(5, 4 + pktLen - padLen);
      this.rx = this.rx.slice(4 + pktLen);
      this.seqIn = (this.seqIn + 1) >>> 0;
      return body;
    }
    // 加密态：先解 4 字节拿长度，再解包体；解过的部分不能重解（CTR 有状态）
    if (this.headDec === undefined) {
      if (this.rx.length < 4) {
        return undefined;
      }
      this.headDec = dec.transform(this.rx.slice(0, 4));
      this.headLen = this.u32At(this.headDec, 0);
      if (this.headLen < 5 || this.headLen + 4 + MAC_LEN > MAX_PACKET + 16) {
        throw new Error(`长度非法（加密）${this.headLen}`);
      }
    }
    const pktLen: number = this.headLen;
    const total: number = 4 + pktLen + MAC_LEN;
    if (this.rx.length < total) {
      return undefined;
    }
    const restPlain: Uint8Array = dec.transform(this.rx.slice(4, 4 + pktLen));
    const plain: Uint8Array = concat([this.headDec, restPlain]);
    const macGot: Uint8Array = this.rx.slice(4 + pktLen, total);
    const macWant: Uint8Array = hmacSha256(this.macIn, [this.seqBytes(this.seqIn), plain]);
    if (!safeEqual(macGot, macWant)) {
      throw new Error('MAC 校验失败');
    }
    this.seqIn = (this.seqIn + 1) >>> 0;
    const padLen: number = plain[4];
    this.rx = this.rx.slice(total);
    this.headDec = undefined;
    this.headLen = 0;
    return plain.slice(5, 4 + pktLen - padLen);
  }

  private u32At(b: Uint8Array, at: number): number {
    return (((b[at] << 24) >>> 0) + (b[at + 1] << 16) + (b[at + 2] << 8) + b[at + 3]) >>> 0;
  }

  private seqBytes(n: number): Uint8Array {
    return new W().u32(n).bytes();
  }

  /** 发一个包（明/密自动判） */
  private async sendPacket(payload: Uint8Array): Promise<void> {
    let pad: number = BLOCK - ((payload.length + 5) % BLOCK);
    if (pad < 4) {
      pad += BLOCK;
    }
    const pktLen: number = payload.length + pad + 1;
    const head: Uint8Array = new W().u32(pktLen).u8(pad).bytes();
    const plain: Uint8Array = concat([head, payload, this.randomBytes(pad)]);
    const enc: AesCtr | undefined = this.enc;
    if (enc === undefined) {
      this.seqOut = (this.seqOut + 1) >>> 0;
      await this.writeRaw(plain);
      return;
    }
    const mac: Uint8Array = hmacSha256(this.macOut, [this.seqBytes(this.seqOut), plain]);
    this.seqOut = (this.seqOut + 1) >>> 0;
    await this.writeRaw(concat([enc.transform(plain), mac]));
  }

  private randomBytes(n: number): Uint8Array {
    if (n === 0) {
      return new Uint8Array(0);
    }
    return cryptoFramework.createRandom().generateRandomSync(n).data;
  }

  private writeRaw(bytes: Uint8Array): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const sock: socket.TCPSocket | undefined = this.sock;
      if (sock === undefined) {
        reject(new Error('连接已关闭'));
        return;
      }
      sock.send({ data: bytes.buffer as ArrayBuffer }).then(() => {
        resolve();
      }).catch((e: BusinessError) => {
        reject(new Error(`发送失败 code=${e === undefined ? -1 : e.code}`));
      });
    });
  }

  /** 读一个包（带超时；失败抛带人话原因） */
  private readPacket(timeoutMs: number): Promise<Uint8Array> {
    const have: Uint8Array | undefined = this.queue.shift();
    if (have !== undefined) {
      return Promise.resolve(have);
    }
    if (this.failure.length > 0) {
      return Promise.reject(new Error(this.failure));
    }
    return new Promise<Uint8Array>((resolve, reject) => {
      const w: Waiter = new Waiter();
      w.resolve = resolve;
      w.reject = reject;
      w.timer = setTimeout(() => {
        const at: number = this.waiters.indexOf(w);
        if (at >= 0) {
          this.waiters.splice(at, 1);
        }
        reject(new Error('等对端回包超时'));
      }, timeoutMs);
      this.waiters.push(w);
    });
  }

  private fail(reason: string): void {
    if (this.failure.length === 0) {
      this.failure = reason;
    }
    this.closed = true;
    // 版本行还没到就断了：立刻 settle，否则 waitVersion 要干等满 10 秒才报超时
    if (this.versionTimer >= 0) {
      clearTimeout(this.versionTimer);
      this.versionTimer = -1;
    }
    const vr: ((e: Error) => void) | undefined = this.versionReject;
    this.versionWaiter = undefined;
    this.versionReject = undefined;
    if (vr !== undefined) {
      vr(new Error(reason));
    }
    const ws: Waiter[] = this.waiters;
    this.waiters = [];
    for (let i = 0; i < ws.length; i++) {
      if (ws[i].timer >= 0) {
        clearTimeout(ws[i].timer);
      }
      ws[i].reject(new Error(reason));
    }
    // 失败即断开：否则还在 await connect/read 的地方会挂到各自的超时
    try {
      this.sock?.close();
    } catch (error) {
      // 已关闭
    }
  }

  // ── KEX + 认证 ───────────────────────────────────────────

  private async kexAndAuth(opts: SshExecOptions): Promise<void> {
    if (this.serverVersion.length === 0) {
      throw new Error('没收到服务端版本行');
    }
    hilog.info(DOMAIN, TAG, 'kex：发 KEXINIT');
    const iC: Uint8Array = new W()
      .u8(MSG_KEXINIT).raw(this.randomBytes(16))
      .strText('curve25519-sha256')
      .strText('ssh-ed25519')
      .strText(CIPHER_NAME).strText(CIPHER_NAME)
      .strText('hmac-sha2-256').strText('hmac-sha2-256')
      .strText('none').strText('none')
      .strText('').strText('')
      .u8(0).u32(0).bytes();
    await this.sendPacket(iC);

    let iS: Uint8Array = await this.readPacket(this.ioTimeout());
    while (iS[0] !== MSG_KEXINIT) {
      if (iS[0] === MSG_DISCONNECT) {
        throw new Error('服务端在协商阶段断开（可能算法不匹配）');
      }
      iS = await this.readPacket(this.ioTimeout());
    }

    const pair: X25519Pair = x25519Generate();
    await this.sendPacket(new W().u8(MSG_KEX_ECDH_INIT).str(pair.rawPub).bytes());

    let reply: Uint8Array = await this.readPacket(this.ioTimeout());
    while (reply[0] !== MSG_KEX_ECDH_REPLY) {
      if (reply[0] === MSG_DISCONNECT) {
        throw new Error('服务端拒绝密钥交换');
      }
      reply = await this.readPacket(this.ioTimeout());
    }
    const rr: R = new R(reply.slice(1));
    hilog.info(DOMAIN, TAG, 'kex：收到 ECDH_REPLY %{public}d 字节', reply.length);
    const kS: Uint8Array = rr.str();
    const qS: Uint8Array = rr.str();
    const sig: Uint8Array = rr.str();

    const K: Uint8Array = x25519Secret(pair.priKey, qS);
    const Kenc: Uint8Array = mpint(K);
    const H: Uint8Array = sha256([sshStr(utf8(this.versionString)), sshStr(utf8(this.serverVersion)),
      sshStr(iC), sshStr(iS), sshStr(kS), sshStr(pair.rawPub), sshStr(qS), sshStr(Kenc)]);
    this.sessionId = H;
    hilog.info(DOMAIN, TAG, 'KEX 完成：H=%{public}s… 主机密钥 %{public}d 字节', hex(H).substring(0, 16), kS.length);
    if (sig.length === 0) {
      throw new Error('服务端没给签名');
    }
    // **服务端主机签名校验**（审查 2026-10-22：以前只判非空，等于完全没验）：
    // kS = { "ssh-ed25519", 32 字节公钥 }，sig = { "ssh-ed25519", 64 字节签名 }，都按 RFC 4253 核对 H。
    const fingerprint: string = verifyHostSignature(kS, sig, H);
    this.fingerprint = fingerprint;
    const expected: string = opts.expectedHostKey === undefined ? '' : opts.expectedHostKey;
    if (expected.length > 0 && fingerprint !== expected) {
      throw new Error('这台电脑的主机指纹和上次不一样（可能不是同一台机器）');
    }

    // KDF（RFC 4253 §7.2）。**K 要带 SSH string 的头**，否则首个加密包会被判长度非法
    const Ks: Uint8Array = sshStr(Kenc);
    const derive = (letter: string, need: number): Uint8Array => {
      let out: Uint8Array = sha256([Ks, H, utf8(letter), H]);
      while (out.length < need) {
        out = concat([out, sha256([Ks, H, out])]);
      }
      return out.slice(0, need);
    };
    const ivC2S: Uint8Array = derive('A', 16);
    const ivS2C: Uint8Array = derive('B', 16);
    const keyC2S: Uint8Array = derive('C', KEY_LEN);
    const keyS2C: Uint8Array = derive('D', KEY_LEN);
    this.macOut = derive('E', 32);
    this.macIn = derive('F', 32);

    await this.sendPacket(new Uint8Array([MSG_NEWKEYS]));
    let nk: Uint8Array = await this.readPacket(this.ioTimeout());
    while (nk[0] !== MSG_NEWKEYS) {
      nk = await this.readPacket(this.ioTimeout());
    }
    this.enc = new AesCtr(keyC2S, ivC2S, true);
    this.dec = new AesCtr(keyS2C, ivS2C, false);

    await this.sendPacket(new W().u8(MSG_SERVICE_REQUEST).strText('ssh-userauth').bytes());
    let svc: Uint8Array = await this.readPacket(this.ioTimeout());
    while (svc[0] === MSG_GLOBAL_REQUEST || svc[0] === MSG_DEBUG) {
      svc = await this.readPacket(this.ioTimeout());
    }
    if (svc[0] !== MSG_SERVICE_ACCEPT) {
      throw new Error(`服务端不接受 ssh-userauth（${svc[0]}）`);
    }

    // publickey 认证：签 "session_id(string) || 请求体(不含签名)"
    const pubBlob: Uint8Array = new W().strText('ssh-ed25519').str(opts.rawPub).bytes();
    const base: Uint8Array = new W().u8(MSG_USERAUTH_REQUEST).strText(opts.user)
      .strText('ssh-connection').strText('publickey').u8(1).strText('ssh-ed25519').str(pubBlob).bytes();
    const sigRaw: Uint8Array = ed25519Sign(opts.priKey, concat([sshStr(H), base]));
    const sigBlob: Uint8Array = new W().strText('ssh-ed25519').str(sigRaw).bytes();
    await this.sendPacket(concat([base, sshStr(sigBlob)]));

    let auth: Uint8Array = await this.readPacket(this.ioTimeout());
    // 认证阶段可能穿插：IGNORE(2) / UNIMPLEMENTED(3) / DEBUG(4) / USERAUTH_BANNER(53) / PK_OK(60) / GLOBAL_REQUEST(80)
    while (auth[0] === MSG_GLOBAL_REQUEST || auth[0] === MSG_UNIMPLEMENTED || auth[0] === MSG_DEBUG ||
      auth[0] === 2 || auth[0] === 53 || auth[0] === 60) {
      auth = await this.readPacket(this.ioTimeout());
    }
    if (auth[0] !== MSG_USERAUTH_SUCCESS) {
      throw new Error(auth[0] === 51 ? 'SSH 认证失败：这台电脑还没加入手机的 SSH 公钥' : `SSH 认证失败（${auth[0]}）`);
    }
    hilog.info(DOMAIN, TAG, 'SSH 认证通过');
  }

  // ── 通道 + exec ──────────────────────────────────────────

  private async runCommand(opts: SshExecOptions): Promise<string> {
    await this.sendPacket(new W().u8(MSG_CHANNEL_OPEN).strText('session').u32(0).u32(1 << 20).u32(32768).bytes());
    // 先按字节累积，最后一次性解码：按包解码会把跨包的多字节 UTF-8 字符切成 U+FFFD
    let outBytes: Uint8Array = new Uint8Array(0);
    // 输出硬上限：脚本刷日志时不能无限累积（命令只用少量标记，保留前 1MiB 足够）
    const OUT_CAP: number = 1024 * 1024;
    let outTruncated: boolean = false;
    let remoteChan: number = -1;
    let rxCum: number = 0;
    // 用 exec 的总截止时间，不在执行阶段重新起算
    const deadline: number = this.deadlineMs > 0 ? this.deadlineMs : Date.now() + opts.timeoutMs;
    while (true) {
      const left: number = deadline - Date.now();
      if (left <= 0) {
        throw new Error('命令执行超时（电脑一直没回执）');
      }
      const p: Uint8Array = await this.readPacket(left);
      const type: number = p[0];
      if (type === MSG_GLOBAL_REQUEST) {
        // 服务端全局请求（hostkeys-prove 等）：统一回"不支持"，够用
        if (p[p.length - 1] === 1) {
          await this.sendPacket(new Uint8Array([MSG_REQUEST_FAILURE]));
        }
        continue;
      }
      if (type === MSG_CHANNEL_OPEN_CONFIRMATION) {
        const orr: R = new R(p.slice(1));
        orr.u32();
        remoteChan = orr.u32();
        await this.sendPacket(new W().u8(MSG_CHANNEL_REQUEST).u32(remoteChan)
          .strText('exec').u8(1).strText(opts.command).bytes());
        continue;
      }
      if (type === MSG_CHANNEL_OPEN_FAILURE) {
        throw new Error('电脑拒绝打开通道');
      }
      if (type === MSG_CHANNEL_DATA || type === MSG_CHANNEL_EXTENDED_DATA) {
        const dr: R = new R(p.slice(1));
        dr.u32(); // recipient channel
        if (type === MSG_CHANNEL_EXTENDED_DATA) {
          dr.u32(); // data_type_code（审查 2026-10-22：以前少跳这一个，把 stderr 类型码当成了长度）
        }
        const rawPiece: Uint8Array = dr.str();
        outBytes = concat([outBytes, rawPiece]);
        if (outBytes.length > OUT_CAP) {
          // 只留最后 OUT_CAP 字节：结果标记（ALREADY/READY/FAILED）在输出末尾，截头不能截尾
          outBytes = outBytes.slice(outBytes.length - OUT_CAP);
          outTruncated = true;
        }
        // C3：按已消费**字节**回窗口（以前按解码后字符数，中文/emoji 会把窗口算少，最终卡到超时）
        rxCum += rawPiece.length;
        if (rxCum >= WINDOW_ADJUST_BYTES) {
          if (remoteChan >= 0) {
            await this.sendPacket(new W().u8(MSG_CHANNEL_WINDOW_ADJUST).u32(remoteChan).u32(rxCum).bytes());
          }
          rxCum = 0;
        }
        continue;
      }
      if (type === MSG_CHANNEL_FAILURE) {
        throw new Error('电脑拒绝执行这条命令');
      }
      if (type === MSG_CHANNEL_CLOSE) {
        if (remoteChan >= 0) {
          await this.sendPacket(new W().u8(MSG_CHANNEL_CLOSE).u32(remoteChan).bytes());
        }
        break;
      }
      if (type === MSG_DISCONNECT) {
        break;
      }
      // CHANNEL_SUCCESS / EOF / WINDOW_ADJUST / REQUEST / DEBUG / IGNORE 忽略
    }
    const out: string = text(outBytes);
    hilog.info(DOMAIN, TAG, 'SSH 命令结束，输出 %{public}d 字节%s', outBytes.length,
      outTruncated ? '（已截断，只保留末尾 1MiB）' : '');
    return out;
  }
}

/**
 * 校验服务端主机密钥对 `H` 的签名（RFC 4253 §6.6）。
 * 失败直接抛错 —— 同 tailnet 上的其它主机不能冒充这台电脑。
 */
function verifyHostSignature(kS: Uint8Array, sig: Uint8Array, H: Uint8Array): string {
  const kr: R = new R(kS);
  const keyAlgo: string = text(kr.str());
  const keyRaw: Uint8Array = kr.str();
  const sr: R = new R(sig);
  const sigAlgo: string = text(sr.str());
  const sigRaw: Uint8Array = sr.str();
  if (keyAlgo !== 'ssh-ed25519' || sigAlgo !== 'ssh-ed25519') {
    throw new Error(`不支持的主机密钥算法：${keyAlgo}`);
  }
  if (keyRaw.length !== 32 || sigRaw.length !== 64) {
    throw new Error('主机密钥/签名长度不对');
  }
  const ok: boolean = ed25519Verify(ed25519SpkiFromRaw(keyRaw), H, sigRaw);
  if (!ok) {
    throw new Error('主机签名校验失败（连的可能不是你以为的那台电脑）');
  }
  return base64(sha256([kS]));
}