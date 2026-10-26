/**
 * DownloadClient —— F6/AC-07 的**电脑 → 手机**下载（走 `/api` 的文件路由）+ F7 的取图字节。
 *
 * 【预验】提前验证产物：不作通过、不进验收结论；真机按正式顺序重跑，以真机为准。
 *
 * ### 路由与鉴权的**代码级**事实（本轮核清，且修正了一处我先前的误判）
 *   · `/api/file` 是 **exact Fetch 路由**（`methods: ["GET","HEAD"]`）：
 *     `dsh-api-session-controller/lib/index.js:2396-2401`（`requestBody: "buffered"`），
 *     分发见 `dsh-client-connection/lib/index.js:608-624`（**先查 exact 路由，再落到 RPC 前缀**）。
 *   · ⇒ **取文件不该走 RPC 信封**（我第一版把它当 GET/HEAD 是对的）；
 *     **但凭据不能少**：exact 路由**也要过鉴权** —— 路由分发前有 `requestRejection()`
 *     （`index.js:585-588`：Host/Origin 围栏 → 403，浏览器鉴权不过 → 401；exact 路由本身不做 admit，
 *      但对外层 shared handler 而言**未认证仍是 401**）。
 *   · `path` 必须以 `/` 开头；**`HEAD` 只给 `Content-Length`**；`413` = 超过服务端字节上限
 *     （`dsh-api-session-controller/lib/index.js:2344-2382`）。
 *   · 真实取文件 URL 里 path 的编码方式**未验证**（我按 URL 编码发；`client.js` 未给反例）⇒ 标记为待实测。
 *
 * ### 两条纪律（照 F14/G3「文件落盘受控」）
 *   ① **落盘位置只允许 App 沙箱或用户显式选定** —— 只从 `context.filesDir` 下拼路径，**不接受远端指定的落盘路径**；
 *   ② **可读路径白名单**（`DownloadPolicy`）：**默认空 = 一律拒**，且放行的根**不得由远端内容决定**。
 *
 * ### 落盘用官方流式下载（2026-10-17 改）
 * `downloadToSandbox` 走官方 `request.downloadFile`：**边下边落盘**，不再把整包读进内存
 * （旧实现在这里自认"大于 ~50MB 不适合"，与"单文件 100MB"的口径冲突）。下完再用官方 `hash.hash` 算 SHA256。
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { NetTarget, StreamResult, streamToFile, writeAllSync } from '../../services/net/DshNet';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sha256OfFile } from '../f09-file-transfer/FileManifest';
import { IMAGE_LIMIT_BYTES } from '../f09-file-transfer/TransferLimits';
import { FileTransport, SimpleRequest, TransferResult, TransportTarget, transferFail } from '../../channel/FileTransport';

const DOMAIN: number = 0xD001;
const TAG: string = 'P2CH-DOWNLOAD';

/** 文件路由（与 `dsh-api-session-controller` 逐字一致）。 */
export const FILE_PATH: string = '/api/file';

/**
 * 可读路径白名单：**默认空 = 一律拒**（必须上层显式放行根目录才可能发请求）。
 *
 * **设计约束（项目经理 2026-10-12 复核加的一条，硬要求）**：
 *   被放行的根目录**只能来自"用户显式选择"或"会话自身声明的工作区"派生**，
 *   **不得由远端内容决定** —— 远端给的路径**绝不能自动进入白名单**。
 *   ⇒ 因此本类**只提供显式的放行入口**，**没有"按远端路径自动放行"的路径**；
 *     `check()` 永远不修改白名单；`allowRootFromUserSelection()` 是**唯一**带来源标记的入口，
 *     并拒绝可疑根（`..` / 相对路径 / 含 NUL）。
 *   ⚠️ **如实说**：这是**约束表达**，不是技术强制（同进程调用方仍可直接调）—— 靠调用方纪律 + 审查保证。
 */
export class DownloadPolicy {
  private allowedRoots: string[] = [];
  private rootOrigins: string[] = [];
  /**
   * **放宽到"任意绝对路径"**（客户 2026-10-18 定）。
   *
   * 为什么改：dsh 的 `GET /api/file` 是官方路由，**服务端本身不限制路径**
   * （`media-references.js`：Paths do not restrict access）。手机侧原来那条
   * "只放行本场会话 cwd" 是**我们自己加的**白名单 —— 它把 `artifacts\`、`shots\`、
   * 临时目录里的图全挡掉，表现为"电脑上明明有图，手机气泡里没有"。
   *
   * 放宽后仍保留的硬约束（挡的是**目录穿越**，不是正常读取）：
   *   · 必须是绝对路径（`/…` 或 `X:/…`）；
   *   · 不许含 `..`；不许含 NUL；不许是相对路径。
   */
  private anyAbsolute: boolean = false;

  /** 允许任何绝对路径（只保留"绝对 / 无 .. / 无 NUL"这三条硬约束） */
  allowAnyAbsolute(): void {
    this.anyAbsolute = true;
  }

  /**
   * 放行一个根（如客户电脑上的某个工作目录）。**只应由"用户显式选择"或"本会话声明的工作区"调用。**
   * @param origin 来源标记（证据用）：user-picked / session-workspace
   */
  allowRoot(root: string, origin: string = 'unspecified'): void {
    const normalized: string = DownloadPolicy.normalize(root);
    if (normalized.length === 0 || !DownloadPolicy.isAbsolute(normalized) || normalized.includes('..') || normalized.includes('\0')) {
      hilog.warn(DOMAIN, TAG, 'P2CH 拒绝放行可疑根：%{public}s（origin=%{public}s）', root, origin);
      return;
    }
    if (!this.allowedRoots.includes(normalized)) {
      this.allowedRoots.push(normalized);
      this.rootOrigins.push(`${normalized} <- ${origin}`);
    }
  }

  /** **唯一**的"从用户选择 / 会话工作区推导入白名单"入口（名字即约束）。 */
  allowRootFromUserSelection(root: string, origin: string): boolean {
    const before: number = this.allowedRoots.length;
    this.allowRoot(root, origin);
    const added: boolean = this.allowedRoots.length > before;
    if (added) {
      hilog.info(DOMAIN, TAG, 'P2CH 放行可读根（来源=%{public}s）：%{public}s', origin, root);
    }
    return added;
  }

  /** 清空白名单（恢复"一律拒"）。 */
  clear(): void {
    this.allowedRoots = [];
    this.rootOrigins = [];
  }

  list(): string[] {
    return this.allowedRoots.slice();
  }

  /** 放行记录（含来源）—— 证据链要能看出"每个根是谁放的"。 */
  listWithOrigins(): string[] {
    return this.rootOrigins.slice();
  }

  static normalize(path: string): string {
    return path.replace(/\\/g, '/').replace(/\/+$/, '');
  }

  /**
   * 绝对路径判定：**POSIX `/` 开头** 或 **Windows 盘符形态 `X:/`**（`normalize` 已把 `\` 换成 `/`）。
   *
   * **为什么放宽到盘符形态（2026-10-12 · 属平台差异，不是绕闸）**：
   *   宿主是 Windows，服务端真正接受的是 **`D:/…`**（宿主侧已实测 `GET /api/file?path=D:/…` ⇒ 200 + 25 B）；
   *   而 **`/D:/…` 在 Windows 上很可能被解析成「当前盘根下的绝对路径」** ⇒ 拿未知换已知不划算。
   *   ⇒ 本通道的原判定比真实部署**更严**，故在此对齐平台：**盘符形态也算绝对路径**。
   *
   * ⚠️ **放宽的只有"算不算绝对路径"这一条**：空 / NUL / `..` / **"必须在放行根之下"** 全部**原样不动**。
   */
  static isAbsolute(path: string): boolean {
    if (path.startsWith('/')) {
      return true;
    }
    return /^[A-Za-z]:\//.test(path);
  }

  /** 判定远端路径是否可读。 */
  check(remotePath: string): PathVerdict {
    const normalized: string = DownloadPolicy.normalize(remotePath);
    if (normalized.length === 0) {
      const v: PathVerdict = { allowed: false, reason: '远端路径为空' };
      return v;
    }
    if (!DownloadPolicy.isAbsolute(normalized)) {
      const v: PathVerdict = { allowed: false, reason: '远端路径必须是绝对路径（以 / 或盘符开头，如 D:/work）' };
      return v;
    }
    if (normalized.includes('\0')) {
      const v: PathVerdict = { allowed: false, reason: '远端路径含 NUL' };
      return v;
    }
    if (normalized.includes('..')) {
      const v: PathVerdict = { allowed: false, reason: '远端路径含 ..（拒绝目录穿越）' };
      return v;
    }
    if (this.anyAbsolute) {
      // 客户 2026-10-18：dsh 的 /api/file 服务端不限制路径 ⇒ 这里不再按"放行根"卡，
      // 只保留上面那三条硬约束（绝对路径 / 无 .. / 无 NUL）。
      const ok: PathVerdict = { allowed: true, reason: '' };
      return ok;
    }
    if (this.allowedRoots.length === 0) {
      const v: PathVerdict = { allowed: false, reason: '还没有可读取的目录：请先选择要读取的目录（本应用只读你明确选定的目录）' };
      return v;
    }
    for (const root of this.allowedRoots) {
      if (normalized === root || normalized.startsWith(`${root}/`)) {
        const v: PathVerdict = { allowed: true, reason: '' };
        return v;
      }
    }
    const denied: PathVerdict = {
      allowed: false, reason: `远端路径不在放行根内（放行根：${this.allowedRoots.join(' / ')}）`
    };
    return denied;
  }
}

export interface PathVerdict {
  allowed: boolean;
  reason: string;
}

/** 远端文件探测结果（HEAD）。 */
export interface RemoteFileProbe {
  ok: boolean;
  status: number;
  /** 服务端报的字节数（-1 = 没拿到） */
  bytes: number;
  contentType: string;
  message: string;
  rawHeaders: string;
}

/** 下载结果。 */
export interface DownloadOutcome {
  ok: boolean;
  status: number;
  /** 落到**沙箱内**的绝对路径（失败为空） */
  localPath: string;
  bytes: number;
  /** 落盘后本地重算的 SHA256（小写；未算为空） */
  sha256: string;
  receivedBytes: number;
  elapsedMs: number;
  message: string;
  stage: string;
}

export interface FetchBytesOutcome {
  ok: boolean;
  status: number;
  bytes: Uint8Array;
  contentType: string;
  message: string;
  receivedBytes: number;
}

function describeStatus(status: number): string {
  if (status === 200) return '成功';
  if (status === 400) return '400：path 缺失或不是绝对路径';
  if (status === 401) return '401：未带凭据（或凭据失效）';
  if (status === 403) return '403：Host 不受信 / 不是普通文件 / 权限或沙箱拒绝';
  if (status === 404) return '404：文件不存在';
  if (status === 413) return '413：文件超过服务端字节上限';
  if (status === 499) return '499：请求被中断';
  return `HTTP ${status}`;
}


export class DownloadClient {
  private transport: FileTransport;
  private policy: DownloadPolicy;

  constructor(transport: FileTransport, policy: DownloadPolicy) {
    this.transport = transport;
    this.policy = policy;
  }

  /** 拼取文件 URL（`path` 走 URL 编码）。 */
  buildPath(remotePath: string): string {
    return `${FILE_PATH}?path=${encodeURIComponent(remotePath)}`;
  }

  /**
   * `HEAD` 预判（先看大小与类型，再决定要不要下 —— AC-08 的"大图保护"与 AC-07 的口径都靠它）。
   * **走传输层统一入口**（Host 回环 + 凭据头都在那里加）。
   */
  async probe(target: TransportTarget, remotePath: string): Promise<RemoteFileProbe> {
    const verdict: PathVerdict = this.policy.check(remotePath);
    if (!verdict.allowed) {
      const denied: RemoteFileProbe = {
        ok: false, status: 0, bytes: -1, contentType: '',
        message: `本地策略拒绝：${verdict.reason}`, rawHeaders: ''
      };
      return denied;
    }
    const started: number = Date.now();
    const request: SimpleRequest = { method: 'HEAD', path: this.buildPath(remotePath) };
    const result: TransferResult = await this.transport.basic(target, request);
    if (!result.ok) {
      const failed: RemoteFileProbe = {
        ok: false, status: result.status, bytes: -1, contentType: '', message: result.error, rawHeaders: ''
      };
      return failed;
    }
    let header: Record<string, string> = {};
    try {
      header = JSON.parse(result.body) as Record<string, string>;
    } catch {
      header = {};
    }
    const lengthText: string = header['content-length'] !== undefined ? header['content-length'] : '-1';
    const parsed: number = Number.parseInt(lengthText, 10);
    const contentType: string = header['content-type'] !== undefined ? header['content-type'] : '';
    const code: number = result.status;
    const probe: RemoteFileProbe = {
      ok: code === 200,
      status: code,
      bytes: Number.isNaN(parsed) ? -1 : parsed,
      contentType: contentType,
      message: `${describeStatus(code)}${code === 200 ? `（${lengthText} 字节，${contentType.length > 0 ? contentType : '未知类型'}，${Date.now() - started}ms）` : ''}`,
      rawHeaders: result.body
    };
    return probe;
  }

  /** 取远端文件字节（**不落盘**，给 F7 图片显示用）。 */
  async fetchBytes(target: TransportTarget, remotePath: string): Promise<FetchBytesOutcome> {
    const verdict: PathVerdict = this.policy.check(remotePath);
    if (!verdict.allowed) {
      const denied: FetchBytesOutcome = {
        ok: false, status: 0, bytes: new Uint8Array(0), contentType: '',
        message: `本地策略拒绝：${verdict.reason}`, receivedBytes: 0
      };
      return denied;
    }
    const started: number = Date.now();
    // **必须 binary: true** —— 走文本路径会把二进制当字符串处理（预验实测：153,838 B 的 PNG 会变成 8 B）
    const request: SimpleRequest = { method: 'GET', path: this.buildPath(remotePath), binary: true };
    const result: TransferResult = await this.transport.basic(target, request);
    if (!result.ok) {
      const failed: FetchBytesOutcome = {
        ok: false, status: result.status, bytes: new Uint8Array(0), contentType: '',
        message: result.error, receivedBytes: 0
      };
      return failed;
    }
    if (result.status !== 200) {
      const bad: FetchBytesOutcome = {
        ok: false, status: result.status, bytes: new Uint8Array(0), contentType: '',
        message: describeStatus(result.status), receivedBytes: 0
      };
      return bad;
    }
    const bytes: Uint8Array = result.bytes !== undefined ? result.bytes : new Uint8Array(0);
    const outcome: FetchBytesOutcome = {
      ok: true, status: 200, bytes: bytes, contentType: '',
      message: `取回 ${bytes.byteLength} 字节（${Date.now() - started}ms）`, receivedBytes: bytes.byteLength
    };
    return outcome;
  }

  /**
   * 下载并落盘到**沙箱内**（官方流式下载：边下边落盘，不整包进内存）。
   * @param sandboxDir 只允许 App 自己的目录（如 `context.filesDir`）；**不接受远端给的落盘路径**
   * @param localName 落盘文件名（由本机决定）
   * @param maxBytes 超过即拒（0 = 不限）
   * @param ctx 运行上下文（`request.downloadFile` 必须；取不到就明确失败，不偷偷降级）
   */
  async downloadToSandbox(
    target: TransportTarget,
    remotePath: string,
    sandboxDir: string,
    localName: string,
    maxBytes: number = 0,
    ctx: common.Context | undefined = undefined
  ): Promise<DownloadOutcome> {
    // ① 落盘位置只允许沙箱（F14/G3）：这里再挡一次"路径逃逸"
    if (remotePath.includes('..') || localName.includes('..') || localName.includes('/') || localName.includes('\\')) {
      return this.fail('policy', '落盘文件名/远端路径含 .. 或分隔符，拒绝（只能落在本机应用目录）', 0);
    }
    const probe: RemoteFileProbe = await this.probe(target, remotePath);
    if (!probe.ok) {
      return this.fail('probe', probe.message, probe.status);
    }
    if (maxBytes > 0 && probe.bytes > maxBytes) {
      return this.fail('limit', `超过本地接受上限：${probe.bytes} > ${maxBytes} 字节`, probe.status);
    }
    if (ctx === undefined) {
      return this.fail('context', '拿不到运行上下文，没法用系统下载器落盘', probe.status);
    }
    const localPath: string = `${sandboxDir}/${localName}`;
    const started: number = Date.now();
    // ① 官方 HTTP 流式收（Host/Cookie 自己设；边收边写盘）
    const streamed: StreamResult = await this.downloadStreaming(target, remotePath, localPath, maxBytes);
    let ok: boolean = streamed.bytesWritten >= 0;
    let actualBytes: number = streamed.bytesWritten >= 0 ? streamed.bytesWritten : 0;
    const cap: number = maxBytes > 0 ? maxBytes : IMAGE_LIMIT_BYTES;
    if (!ok && streamed.overLimit) {
      // 超限被主动中止（半截文件已删）：绝不能再回落去整包读
      return this.fail('limit', `文件超过上限 ${cap} 字节`, probe.status);
    }
    if (ok && actualBytes > cap) {
      try {
        fileIo.unlinkSync(localPath);
      } catch (unlinkError) {
        // 忽略
      }
      return this.fail('limit', `实际下载 ${actualBytes} 字节，超过上限 ${cap}`, probe.status);
    }
    if (!ok && probe.bytes > 0 && probe.bytes <= cap) {
      // ② 流式失败时**只对"确定够小"的图**退回整包取字节（图都很小，功能不能因此挂掉）；
      //    长度未知或超过上限时不回落，避免绕过上限把大文件整包读进内存。
      hilog.warn(DOMAIN, TAG, 'P2CH 流式没成功，退回整包取字节（%{public}d 字节）', probe.bytes);
      const fetched: FetchBytesOutcome = await this.fetchBytes(target, remotePath);
      if (!fetched.ok) {
        return this.fail('read', fetched.message, fetched.status);
      }
      if (fetched.bytes.byteLength > cap) {
        return this.fail('limit', `实际下载 ${fetched.bytes.byteLength} 字节，超过上限 ${cap}`, fetched.status);
      }
      try {
        const file: fileIo.File = fileIo.openSync(localPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          // bytes 可能是底层 buffer 的一段视图：按 byteOffset/byteLength 切
          const body: ArrayBuffer = (fetched.bytes.byteOffset === 0 &&
            fetched.bytes.byteLength === fetched.bytes.buffer.byteLength)
            ? fetched.bytes.buffer as ArrayBuffer
            : fetched.bytes.buffer.slice(fetched.bytes.byteOffset,
              fetched.bytes.byteOffset + fetched.bytes.byteLength) as ArrayBuffer;
          writeAllSync(file.fd, body);
        } finally {
          fileIo.closeSync(file);
        }
        ok = true;
        actualBytes = fetched.bytes.byteLength;
      } catch (error) {
        try {
          fileIo.unlinkSync(localPath);
        } catch (unlinkError) {
          // 本来就没落盘
        }
        const e = error as BusinessError;
        return this.fail('write', `落盘失败：code=${e.code ?? -1} ${e.message}`, fetched.status);
      }
    }
    if (!ok) {
      // 流式失败且按策略不回落（长度未知 / 超过图片上限）⇒ 如实失败，不能当成功
      return this.fail('read', `下载失败（HTTP ${probe.status}）`, probe.status);
    }
    let digest: string = '';
    try {
      digest = await sha256OfFile(localPath);
    } catch (error) {
      const e = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'P2CH 落盘后哈希失败：code=%{public}d %{public}s', e.code ?? -1, e.message);
    }
    const done: DownloadOutcome = {
      // 实际写进去多少就报多少（以前拿 HEAD 的字节数充数，GET 短了也会报成功）
      ok: true, status: 200, localPath: localPath, bytes: actualBytes, sha256: digest,
      receivedBytes: actualBytes, elapsedMs: Date.now() - started,
      message: `已落盘到沙箱：${localPath}（${actualBytes} 字节）`, stage: 'none'
    };
    return done;
  }

  /**
   * **官方 HTTP 流式收**（`requestInStream` + `dataReceive`）：边收边写盘，不整包进内存，
   * 而且 `Host`/`Cookie` 由我们自己设（系统下载器不转发自定义 `Host`，会被 dsh 围栏挡掉，实测 err=8）。
   */
  private async downloadStreaming(target: TransportTarget, remotePath: string,
    localPath: string, maxBytes: number = 0): Promise<StreamResult> {
    // 规则全在 `services/net/DshNet`：Host 回环 / Cookie 首段 / 超时 / 错误码只在那里写
    const netTarget: NetTarget = {
      address: target.address, port: target.port, hostHeader: target.hostHeader,
      cookie: target.cookie, tsTarget: undefined,
      // 审查 2026-10-22：这里漏了 `/pair/dsh` 前缀 ⇒ 真机流式取图打到 /api/file（404），白退回整包进内存
      pathPrefix: target.pathPrefix
    };
    const cap: number = maxBytes > 0 ? maxBytes : 32 * 1024 * 1024;
    const res: StreamResult = await streamToFile(netTarget, this.buildPath(remotePath), localPath, cap);
    if (res.bytesWritten < 0) {
      hilog.warn(DOMAIN, TAG, 'P2CH 流式收失败 status=%{public}d code=%{public}d', res.statusCode, res.errorCode);
    } else {
      hilog.info(DOMAIN, TAG, 'P2CH 流式下载完成 bytes=%{public}d', res.bytesWritten);
    }
    return res;
  }

  /** 取回文本（诊断/清单用；如远端某个 json/txt）。 */
  async fetchText(target: TransportTarget, remotePath: string): Promise<TransferResult> {
    const verdict: PathVerdict = this.policy.check(remotePath);
    if (!verdict.allowed) {
      return transferFail('policy', `本地策略拒绝：${verdict.reason}`, 0, 0, 0, 0);
    }
    const request: SimpleRequest = { method: 'GET', path: this.buildPath(remotePath) };
    return this.transport.basic(target, request);
  }

  private fail(stage: string, message: string, status: number): DownloadOutcome {
    const outcome: DownloadOutcome = {
      ok: false, status: status, localPath: '', bytes: 0, sha256: '', receivedBytes: 0,
      elapsedMs: 0, message: message, stage: stage
    };
    return outcome;
  }
}


