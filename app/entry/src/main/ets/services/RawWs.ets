import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * **最小 WebSocket 客户端（跑在 TCP socket 上）** —— 为什么不用 `@ohos.net.webSocket`：
 *
 * dsh 的 `/api` 与 `/api/remote.mux`（官方流载体）前面有一道**围栏**：`Host` 必须是回环形式，
 * 而且若带 `Origin`，`Origin` 的 host 必须**等于** `Host`（源码 `new URL(origin).host === hostUrl.host`）。
 * 但系统 WS 客户端把这两个头写死、且不允许改写（实测：自定义 `Host` 被忽略；自定义 `Origin`
 * 被**追加**成 `"http://本机网关, http://127.0.0.1:dsh 端口"` 两个值）。
 *
 * 走 TCP 自己发升级握手 ⇒ 头完全可控：`Host: 127.0.0.1:dsh 端口`、`Origin: http://127.0.0.1:dsh 端口`，
 * 两个天然一致 ⇒ 101，而且配对拿到的凭据（绑的就是这个 authority）直接生效。
 *
 * 只实现我们需要的子集：文本帧（含分片）、ping/pong、close、客户端掩码。
 */

const DOMAIN: number = 0xD001;
const TAG: string = 'RAWWS';

export interface RawWsTarget {
  /** socket 目标（电脑的 tailnet 地址） */
  host: string;
  port: number;
  /** 握手路径，例如 `/api/remote.mux` */
  path: string;
  /** 发出去的 `Host` 头（必须回环形式） */
  hostHeader: string;
  /** 发出去的 `Origin` 头（host 部分必须与 hostHeader 一致） */
  origin: string;
  /** 配对拿到的 `name=value`；空串表示不带 */
  cookie: string;
}

/** `Sec-WebSocket-Key`：官方的加密安全随机 + 官方 base64（不再自己写表） */
function randomKey(): string {
  const bytes: Uint8Array = cryptoFramework.createRandom().generateRandomSync(16).data;
  return new util.Base64Helper().encodeToStringSync(bytes);
}

export class RawWs {
  private sock: socket.TCPSocket | undefined = undefined;
  private rx: Uint8Array = new Uint8Array(0);
  private upgraded: boolean = false;
  private closed: boolean = false;
  private fragOpcode: number = -1;
  private fragParts: Uint8Array[] = [];
  /** 握手超时定时器（对端不回 101 时自己失败，别永久挂起） */
  private handshakeTimer: number = -1;

  onOpen: () => void = () => { };
  onText: (text: string) => void = () => { };
  onClose: (code: number, reason: string) => void = () => { };
  onFail: (message: string) => void = () => { };

  /** 建连并握手（返回后仍要等 `onOpen`；失败走 `onFail`） */
  connect(target: RawWsTarget): void {
    const sock: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.sock = sock;
    sock.on('message', (info: socket.SocketMessageInfo) => {
      this.feed(new Uint8Array(info.message));
    });
    sock.on('close', () => {
      this.finish(1006, 'socket closed');
    });
    sock.on('error', (err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'socket error code=%{public}d', err === undefined ? -1 : err.code);
      this.finish(1006, 'socket error');
    });
    const addr: socket.NetAddress = { address: target.host, port: target.port };
    sock.connect({ address: addr, timeout: 8000 })
      .then(() => {
        const lines: string[] = [
          `GET ${target.path} HTTP/1.1`,
          `Host: ${target.hostHeader}`,
          `Origin: ${target.origin}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${randomKey()}`,
          'Sec-WebSocket-Version: 13'
        ];
        if (target.cookie.length > 0) {
          lines.push(`Cookie: ${target.cookie}`);
        }
        lines.push('', '');
        sock.send({ data: lines.join('\r\n') }).then(() => {
          hilog.info(DOMAIN, TAG, '握手已发出 → %{public}s:%{public}d%{public}s', target.host, target.port, target.path);
        }).catch((e: BusinessError) => {
          this.fail(`发送握手失败 code=${e === undefined ? -1 : e.code}`);
        });
        // 审查 2026-10-22：对端接受 TCP 却不回 101 时必须自己超时，否则永久挂起
        this.handshakeTimer = setTimeout(() => {
          this.handshakeTimer = -1;
          this.fail('握手超时（对端没回 101）');
        }, 8000);
      })
      .catch((e: BusinessError) => {
        this.fail(`TCP 连不上 ${target.host}:${target.port} code=${e === undefined ? -1 : e.code}`);
      });
  }

  /** 发一个文本帧 */
  sendText(text: string): void {
    const payload: Uint8Array = new util.TextEncoder().encodeInto(text);
    this.sendFrame(0x1, payload);
  }

  close(): void {
    this.sendFrame(0x8, new Uint8Array(0));
    this.finish(1000, 'client close');
  }

  // ── 内部 ────────────────────────────────────────────────

  private clearHandshakeTimer(): void {
    if (this.handshakeTimer >= 0) {
      clearTimeout(this.handshakeTimer);
      this.handshakeTimer = -1;
    }
  }

  private fail(message: string): void {
    this.clearHandshakeTimer();
    hilog.error(DOMAIN, TAG, '%{public}s', message);
    this.onFail(message);
    this.finish(1006, message);
  }

  private finish(code: number, reason: string): void {
    this.clearHandshakeTimer();
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      this.sock?.close();
    } catch (error) {
      // 已经关了，忽略
    }
    this.onClose(code, reason);
  }

  private sendFrame(opcode: number, payload: Uint8Array): void {
    const sock: socket.TCPSocket | undefined = this.sock;
    if (sock === undefined || !this.upgraded) {
      return;
    }
    const len: number = payload.length;
    const header: number[] = [];
    header.push(0x80 | opcode);
    const mask: number[] = [];
    for (let i = 0; i < 4; i++) {
      mask.push(Math.floor(Math.random() * 256));
    }
    if (len < 126) {
      header.push(0x80 | len);
    } else if (len < 65536) {
      header.push(0x80 | 126);
      header.push((len >> 8) & 0xff, len & 0xff);
    } else {
      header.push(0x80 | 127);
      for (let i = 7; i >= 0; i--) {
        header.push(Math.floor(len / Math.pow(2, 8 * i)) & 0xff);
      }
    }
    for (let i = 0; i < 4; i++) {
      header.push(mask[i]);
    }
    const out: Uint8Array = new Uint8Array(header.length + len);
    out.set(new Uint8Array(header), 0);
    for (let i = 0; i < len; i++) {
      out[header.length + i] = payload[i] ^ mask[i % 4];
    }
    sock.send({ data: out.buffer as ArrayBuffer }).catch((e: BusinessError) => {
      this.fail(`发送帧失败 code=${e === undefined ? -1 : e.code}`);
    });
  }

  private feed(chunk: Uint8Array): void {
    if (this.closed) {
      return;
    }
    const merged: Uint8Array = new Uint8Array(this.rx.length + chunk.length);
    merged.set(this.rx, 0);
    merged.set(chunk, this.rx.length);
    this.rx = merged;
    this.pump();
  }

  private pump(): void {
    while (!this.closed) {
      if (!this.upgraded) {
        const headEnd: number = indexOfCrlfCrlf(this.rx);
        if (headEnd < 0) {
          return;
        }
        const head: string = new util.TextDecoder().decodeToString(this.rx.slice(0, headEnd));
        this.rx = this.rx.slice(headEnd + 4);
        const statusLine: string = head.split('\r\n')[0];
        if (statusLine.indexOf('101') < 0) {
          const shortLine: string = statusLine.substring(0, 80);
          this.fail(`握手被拒：${shortLine}`);
          return;
        }
        this.upgraded = true;
        hilog.info(DOMAIN, TAG, '101 Switching Protocols（握手成功）');
        this.clearHandshakeTimer();
        this.onOpen();
        continue;
      }
      if (this.rx.length < 2) {
        return;
      }
      const b0: number = this.rx[0];
      const b1: number = this.rx[1];
      const fin: boolean = (b0 & 0x80) !== 0;
      const opcode: number = b0 & 0x0f;
      const masked: boolean = (b1 & 0x80) !== 0;
      let len: number = b1 & 0x7f;
      let off: number = 2;
      if (len === 126) {
        if (this.rx.length < 4) {
          return;
        }
        len = (this.rx[2] << 8) | this.rx[3];
        off = 4;
      } else if (len === 127) {
        if (this.rx.length < 10) {
          return;
        }
        let big: number = 0;
        for (let i = 2; i < 10; i++) {
          big = big * 256 + this.rx[i];
        }
        len = big;
        off = 10;
      }
      let maskKey: Uint8Array | undefined = undefined;
      if (masked) {
        if (this.rx.length < off + 4) {
          return;
        }
        maskKey = this.rx.slice(off, off + 4);
        off += 4;
      }
      if (this.rx.length < off + len) {
        return;
      }
      const payload: Uint8Array = this.rx.slice(off, off + len);
      if (maskKey !== undefined) {
        for (let i = 0; i < len; i++) {
          payload[i] = payload[i] ^ maskKey[i % 4];
        }
      }
      this.rx = this.rx.slice(off + len);
      this.dispatch(fin, opcode, payload);
    }
  }

  private dispatch(fin: boolean, opcode: number, payload: Uint8Array): void {
    if (opcode === 0x9) {
      this.sendFrame(0xA, payload);
      return;
    }
    if (opcode === 0xA) {
      return;
    }
    if (opcode === 0x8) {
      let code: number = 1005;
      if (payload.length >= 2) {
        code = (payload[0] << 8) | payload[1];
      }
      this.finish(code, 'server close');
      return;
    }
    if (opcode === 0x1 || opcode === 0x2) {
      if (!fin) {
        this.fragOpcode = opcode;
        this.fragParts = [payload];
        return;
      }
      this.emit(opcode, payload);
      return;
    }
    if (opcode === 0x0) {
      this.fragParts.push(payload);
      if (!fin) {
        return;
      }
      let total: number = 0;
      for (let i = 0; i < this.fragParts.length; i++) {
        total += this.fragParts[i].length;
      }
      const joined: Uint8Array = new Uint8Array(total);
      let at: number = 0;
      for (let i = 0; i < this.fragParts.length; i++) {
        joined.set(this.fragParts[i], at);
        at += this.fragParts[i].length;
      }
      const op: number = this.fragOpcode;
      this.fragOpcode = -1;
      this.fragParts = [];
      this.emit(op, joined);
    }
  }

  private emit(opcode: number, payload: Uint8Array): void {
    if (opcode !== 0x1) {
      return;
    }
    const text: string = new util.TextDecoder().decodeToString(payload);
    this.onText(text);
  }
}

/** 在字节流里找 `\r\n\r\n` 的位置（找不到 = -1） */
function indexOfCrlfCrlf(buf: Uint8Array): number {
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
      return i;
    }
  }
  return -1;
}

