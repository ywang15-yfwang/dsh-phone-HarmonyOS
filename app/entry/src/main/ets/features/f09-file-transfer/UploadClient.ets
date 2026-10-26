/**
 * UploadClient —— F6/AC-07 的**手机 → 电脑**上传（走 `/api` 的上传路由）。
 *
 * 【预验】提前验证产物：不作通过、不进验收结论；真机按正式顺序重跑，以真机为准。
 *
 * 路由（**代码级已核**，不是猜的）：
 *   `POST /api/session/uploadFileBinary?sessionId=<id>&name=<文件名>`
 *   `content-type: application/octet-stream`，**请求体为流式原始字节**
 *   —— `dsh-client-file-upload/lib/index.js:73`（`FILE_UPLOAD_PATH`）、`:171-176`（`requestBody: "streaming"`）；
 *      调用侧 `lib/client.js:179-191`（`URLSearchParams({sessionId})` + 可选 `name` + `content-type: octet-stream`）。
 *   返回：`{receiptId, file:{attachmentId,name,bytes,...}}`（`lib/client.js:285-289` 的解析形状）
 *   ⇒ **`receiptId` 原样带回给上层**（怎么进下一轮 prompt 由 app-ui / 契约定）。
 *
 * 两条纪律：
 *   ① **100MB 前置拒绝**：`TransferLimits.checkTransferLimit` 在**发起任何请求之前**判定，超限直接返回可读提示，
 *      **不留半截残文件**（AC-07 通过条件 ④）；
 *   ② **HTTP 非 2xx 不是传输层异常**（契约 ④）：403/413 等作为**业务结果**返回给上层渲染。
 *
 * 传输形态：**流式** —— 逐块从文件读、逐块交给传输层（`streamUpload` 负责**部分写重试**与进度）。
 *   ⚠️ 预验实现 `HttpTransport` 是 buffered（`isStreaming()=false`），故大文件会整包驻留内存；
 *      正式形态走 `KernelTransport`（streaming）。
 */

import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ChunkSource, FileTransport, TransferResult, TransportTarget, transferFail
} from '../../channel/FileTransport';
import { streamUpload } from '../../channel/HttpTransport';
import { FileManifest, walkDirectory } from './FileManifest';
import { checkTransferLimit, checkSingleFile, LimitDecision, SizeEntry } from './TransferLimits';

const DOMAIN: number = 0xD001;
const TAG: string = 'P2CH-UPLOAD';

/** 上传路由（与 `dsh-client-file-upload` 逐字一致）。 */
export const UPLOAD_PATH: string = '/api/session/uploadFileBinary';

/** 逐块读取一个文件（**不整包驻留**）。 */
export class FileChunkSource implements ChunkSource {
  private fd: fileIo.File;
  private offset: number = 0;
  private readonly total: number;
  private readonly chunkBytes: number;

  private constructor(fd: fileIo.File, total: number, chunkBytes: number) {
    this.fd = fd;
    this.total = total;
    this.chunkBytes = chunkBytes;
  }

  /** 打开一个文件作为分块来源；文件不存在/无权限时抛错（由调用方转成可读提示）。 */
  static open(absPath: string, chunkBytes: number = 1024 * 1024): FileChunkSource {
    const fd: fileIo.File = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(absPath);
      return new FileChunkSource(fd, stat.size, chunkBytes);
    } catch (error) {
      // stat 失败也要把刚打开的 fd 还回去
      try {
        fileIo.closeSync(fd);
      } catch (closeError) {
        // 已关闭
      }
      throw error as Error;
    }
  }

  totalBytes(): number {
    return this.total;
  }

  async nextChunk(): Promise<Uint8Array | null> {
    const remaining: number = this.total - this.offset;
    if (remaining <= 0) {
      return null;
    }
    const want: number = remaining < this.chunkBytes ? remaining : this.chunkBytes;
    const buffer = new ArrayBuffer(want);
    const read: number = fileIo.readSync(this.fd.fd, buffer);
    if (read <= 0) {
      // 文件在传输中被截断/删掉：**必须抛错**，否则传输层当成正常收尾，服务端收到半截还回 ok
      hilog.error(DOMAIN, TAG, 'P2CH 源文件读取中断 offset=%{public}d total=%{public}d',
        this.offset, this.total);
      throw new Error('源文件在传输中变短（上传失败）');
    }
    this.offset += read;
    return new Uint8Array(buffer, 0, read);
  }

  async release(): Promise<void> {
    try {
      fileIo.closeSync(this.fd);
    } catch (error) {
      const e = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'P2CH close 文件失败：code=%{public}d %{public}s', e.code ?? -1, e.message);
    }
  }
}

/** 由内存字节构成的来源（桩数据/小文件测试用）。 */
export class BytesChunkSource implements ChunkSource {
  private offset: number = 0;
  private data: Uint8Array;
  private chunkBytes: number;

  constructor(data: Uint8Array, chunkBytes: number = 1024 * 1024) {
    this.data = data;
    this.chunkBytes = chunkBytes;
  }

  totalBytes(): number {
    return this.data.byteLength;
  }

  async nextChunk(): Promise<Uint8Array | null> {
    if (this.offset >= this.data.byteLength) {
      return null;
    }
    const end: number = Math.min(this.offset + this.chunkBytes, this.data.byteLength);
    const slice: Uint8Array = this.data.subarray(this.offset, end);
    this.offset = end;
    return slice;
  }

  async release(): Promise<void> {
    this.offset = 0;
  }
}

/** 上传结果（给上层的形状）。 */
export interface UploadOutcome {
  /** 传输是否完成（**不代表 HTTP 2xx**，契约 ④） */
  ok: boolean;
  status: number;
  /** 服务端回执（原样），失败时为空串 */
  receiptId: string;
  /** 电脑侧的内容寻址 id（`sha256:…`）；空串 = 没拿到 */
  attachmentId: string;
  /** 服务端记的文件名 */
  storedName: string;
  /** 服务端记的字节数（-1 = 没拿到） */
  storedBytes: number;
  /** 本次实际发出的字节 */
  sentBytes: number;
  elapsedMs: number;
  /** 给用户看的可读文案（成功/失败都有） */
  message: string;
  /** 原始响应体（证据用） */
  rawBody: string;
  /** 传输层失败阶段（none = 传输本身成功） */
  stage: string;
  /** 是否被本体判定拒绝（超限前置拒绝 / 非 2xx） */
  rejected: boolean;
}

/** 服务端回执的解析形状（`dsh-client-file-upload/lib/client.js:285-289`）。 */
interface ParsedUpload {
  receiptId: string;
  /** 电脑侧的内容寻址 id（`sha256:…`）—— 视频/文件的"电脑端播放"链接要靠它 */
  attachmentId: string;
  name: string;
  bytes: number;
  /**
   * 业务错误码（`body.error.code`）—— **真实例实测：业务失败时 HTTP 仍是 200**，
   * 例如 `session/not-found`、`session/attachment-invalid`。
   * ⇒ **光看 HTTP 状态码不够，必须解析 body**（这条是"真 dsh 才看得到"的语义）。
   */
  errorCode: string;
  errorMessage: string;
}

function parseUploadResponse(body: string): ParsedUpload {
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    // **官方响应是 `{ok, value:{receiptId, file:{attachmentId,name,bytes}}}`**（2026-10-17 实测）
    // ⇒ 先读 `value.*`；顶层字段只作兼容。
    const valueRaw: Object | undefined = parsed['value'];
    const scope: Record<string, Object> = valueRaw === undefined || valueRaw === null
      ? parsed : valueRaw as Record<string, Object>;
    const receiptRaw: Object | undefined = scope['receiptId'] !== undefined
      ? scope['receiptId'] : parsed['receiptId'];
    const fileRaw: Object | undefined = scope['file'] !== undefined ? scope['file'] : parsed['file'];
    const file: Record<string, Object> | undefined = fileRaw === undefined
      ? undefined : fileRaw as Record<string, Object>;
    const nameRaw: Object | undefined = file === undefined ? undefined : file['name'];
    const bytesRaw: Object | undefined = file === undefined ? undefined : file['bytes'];
    const attachmentRaw: Object | undefined = file === undefined ? undefined : file['attachmentId'];
    let errorCode: string = '';
    let errorMessage: string = '';
    const error: Record<string, Object> | undefined = parsed['error'] as Record<string, Object>;
    if (error !== undefined) {
      const codeRaw: Object | undefined = error['code'];
      const messageRaw: Object | undefined = error['message'];
      errorCode = typeof codeRaw === 'string' ? codeRaw as string : '';
      errorMessage = typeof messageRaw === 'string' ? messageRaw as string : '';
    }
    const result: ParsedUpload = {
      receiptId: typeof receiptRaw === 'string' ? receiptRaw as string : '',
      attachmentId: typeof attachmentRaw === 'string' ? attachmentRaw as string : '',
      name: typeof nameRaw === 'string' ? nameRaw as string : '',
      bytes: typeof bytesRaw === 'number' ? bytesRaw as number : -1,
      errorCode: errorCode,
      errorMessage: errorMessage
    };
    return result;
  } catch {
    const empty: ParsedUpload = { receiptId: '', attachmentId: '', name: '', bytes: -1, errorCode: '', errorMessage: '' };
    return empty;
  }
}

/** 把 HTTP 状态码翻成人话（**都是业务结果，不是异常**）。 */
function describeStatus(status: number): string {
  if (status === 200) {
    return '上传完成';
  }
  if (status === 401) {
    return '401：围栏已过但没有凭据（配对/凭据问题）';
  }
  if (status === 403) {
    return '403：Host 不受信（围栏拦下）—— 必须发回环形式的 Host';
  }
  if (status === 404) {
    return '404：路由未命中（路径或 sessionId 不对）';
  }
  if (status === 413) {
    return '413：请求体超过服务端上限（注意产品口径仍是 100MB）';
  }
  if (status === 400) {
    return '400：请求不合法（检查 sessionId / name 编码）';
  }
  return `HTTP ${status}`;
}

export class UploadClient {
  private transport: FileTransport;

  constructor(transport: FileTransport) {
    this.transport = transport;
  }

  /** 当前传输实现是否流式（**预验实现会如实返回 false**）。 */
  transportIsStreaming(): boolean {
    return this.transport.isStreaming();
  }

  transportName(): string {
    return this.transport.name;
  }

  /** 拼上传 URL（`name` 走 URL 编码，中文/空格不炸）。 */
  buildPath(sessionId: string, displayName: string): string {
    const query: string = `sessionId=${encodeURIComponent(sessionId)}&name=${encodeURIComponent(displayName)}`;
    return `${UPLOAD_PATH}?${query}`;
  }

  /**
   * 传一个文件（**流式**）。
   * @param absPath 沙箱内/用户显式选定的绝对路径
   * @param displayName 电脑侧落盘用的显示名（默认取文件名）
   * @param onProgress 进度（已接受字节, 总字节）
   */
  async uploadFile(
    target: TransportTarget,
    sessionId: string,
    absPath: string,
    displayName: string,
    onProgress?: (accepted: number, total: number) => void
  ): Promise<UploadOutcome> {
    let totalBytes: number = 0;
    try {
      totalBytes = fileIo.statSync(absPath).size;
    } catch (error) {
      const e = error as BusinessError;
      return this.fail('open', `读不到文件：code=${e.code ?? -1} ${e.message}`, 0, 0, false);
    }

    // ① 100MB 前置拒绝：**任何请求之前**
    const decision: LimitDecision = checkSingleFile(totalBytes, displayName);
    if (!decision.allowed) {
      hilog.warn(DOMAIN, TAG, 'P2CH 前置拒绝（超限）：%{public}s', decision.message);
      return this.fail('limit', decision.message, totalBytes, 0, true);
    }

    let source: FileChunkSource;
    try {
      source = FileChunkSource.open(absPath);
    } catch (error) {
      const e = error as BusinessError;
      return this.fail('open', `打开文件失败：code=${e.code ?? -1} ${e.message}`, totalBytes, 0, false);
    }

    const result: TransferResult = await streamUpload(
      this.transport, target, this.buildPath(sessionId, displayName),
      { 'Content-Type': 'application/octet-stream' }, source,
      onProgress === undefined ? undefined : onProgress
    );
    return this.toOutcome(result, displayName, totalBytes);
  }

  /** 传内存字节（桩/小文件）。 */
  async uploadBytes(
    target: TransportTarget,
    sessionId: string,
    data: Uint8Array,
    displayName: string,
    onProgress?: (accepted: number, total: number) => void
  ): Promise<UploadOutcome> {
    const decision: LimitDecision = checkSingleFile(data.byteLength, displayName);
    if (!decision.allowed) {
      return this.fail('limit', decision.message, data.byteLength, 0, true);
    }
    const result: TransferResult = await streamUpload(
      this.transport, target, this.buildPath(sessionId, displayName),
      { 'Content-Type': 'application/octet-stream' }, new BytesChunkSource(data),
      onProgress === undefined ? undefined : onProgress
    );
    return this.toOutcome(result, displayName, data.byteLength);
  }

  /**
   * 传一个目录（**逐文件**；整包 ≤100MB 才放行）。
   * 先 `walkDirectory` 拿清单与总量 → 前置判定 → 逐文件上传。
   *
   * 注意（**待实测**）：电脑侧"按相对路径建目录并落盘"的语义**未验证**（《开发文档》§3 g / D5②）；
   *   本方法如实把每个文件的 `relativePath` 作为 `name` 传（含 `/`），**并在返回值里标明这一点**。
   */
  async uploadDirectory(
    target: TransportTarget,
    sessionId: string,
    dirPath: string,
    onFileProgress?: (relativePath: string, index: number, total: number) => void,
    onByteProgress?: (accepted: number, total: number) => void
  ): Promise<UploadDirectoryOutcome> {
    const manifest: FileManifest = await walkDirectory(dirPath);
    const entries: SizeEntry[] = [];
    for (const item of manifest.entries) {
      entries.push({ relativePath: item.relativePath, bytes: item.bytes });
    }
    const decision: LimitDecision = checkTransferLimit(entries);
    if (!decision.allowed) {
      return {
        ok: false, rejected: true, message: decision.message, transferLimitBytes: decision.totalBytes,
        files: [], succeeded: 0, failed: manifest.entries.length,
        relativePathSemantics: 'not-sent', manifest: manifest
      };
    }
    const files: UploadOutcome[] = [];
    let index: number = 0;
    let succeeded: number = 0;
    const problemCount: number = manifest.problems.length;
    for (const item of manifest.entries) {
      index += 1;
      if (onFileProgress !== undefined) {
        onFileProgress(item.relativePath, index, manifest.entries.length);
      }
      // `name` 传**相对路径**（含 `/`）——这是让电脑侧按目录落盘的唯一通道；
      // **落盘语义待实测**（见方法注释与 `UploadDirectoryOutcome.relativePathSemantics`）
      const outcome: UploadOutcome = await this.uploadFile(
        target, sessionId, `${dirPath}/${item.relativePath}`, item.relativePath, onByteProgress
      );
      files.push(outcome);
      if (outcome.ok && !outcome.rejected && outcome.status === 200) {
        succeeded += 1;
      }
    }
    return {
      // 有读不到的条目（权限/stat 失败）就不能算"目录上传完成"
      ok: succeeded === manifest.entries.length && manifest.entries.length > 0 && problemCount === 0,
      rejected: false,
      message: succeeded === manifest.entries.length && problemCount === 0
        ? `目录上传完成：${succeeded} 个文件，共 ${decision.totalBytes} 字节（相对路径语义待电脑侧实测确认）`
        : `目录上传部分失败：成功 ${succeeded}/${manifest.entries.length}` +
          (problemCount > 0 ? `，另有 ${problemCount} 项读不到` : ''),
      transferLimitBytes: decision.totalBytes,
      files: files,
      succeeded: succeeded,
      failed: manifest.entries.length - succeeded,
      relativePathSemantics: 'sent-relative-path-as-name',
      manifest: manifest
    };
  }

  private toOutcome(result: TransferResult, displayName: string, totalBytes: number): UploadOutcome {
    if (!result.ok) {
      return {
        ok: false, status: result.status, receiptId: '', attachmentId: '', storedName: '', storedBytes: -1,
        sentBytes: result.sentBytes, elapsedMs: result.elapsedMs,
        message: result.cancelled ? '上传已取消' : `传输失败（${result.stage}）：${result.error}`,
        rawBody: result.body, stage: result.stage, rejected: false
      };
    }
    const parsed = parseUploadResponse(result.body);
    const is2xx: boolean = result.status >= 200 && result.status < 300;
    // **真实例实测**：业务失败时 HTTP 仍可能是 200，失败详情在 body.error ⇒ 必须解析出来
    const businessFailed: boolean = parsed.errorCode.length > 0;
    const ok: boolean = is2xx && !businessFailed;
    const message: string = businessFailed
      ? `服务端业务失败：${parsed.errorCode} — ${parsed.errorMessage}（HTTP ${result.status}；注意业务失败时 HTTP 仍可能是 200）`
      : `${describeStatus(result.status)}（发出 ${result.sentBytes}/${totalBytes} 字节）`;
    return {
      ok: ok,
      status: result.status,
      receiptId: parsed.receiptId,
      attachmentId: parsed.attachmentId,
      storedName: parsed.name.length > 0 ? parsed.name : displayName,
      storedBytes: parsed.bytes,
      sentBytes: result.sentBytes,
      elapsedMs: result.elapsedMs,
      message: message,
      rawBody: result.body,
      stage: result.stage,
      rejected: !ok
    };
  }

  private fail(stage: string, message: string, totalBytes: number, sentBytes: number, rejected: boolean): UploadOutcome {
    return {
      ok: false, status: 0, receiptId: '', attachmentId: '', storedName: '', storedBytes: -1,
      sentBytes: sentBytes, elapsedMs: 0, message: message, rawBody: '', stage: stage, rejected: rejected
    };
  }
}

export interface UploadDirectoryOutcome {
  ok: boolean;
  /** 是否被前置拒绝（超限，未发出任何请求） */
  rejected: boolean;
  message: string;
  transferLimitBytes: number;
  files: UploadOutcome[];
  succeeded: number;
  failed: number;
  /** 相对路径语义：not-sent / sent-relative-path-as-name（**电脑侧落盘语义待实测**） */
  relativePathSemantics: string;
  manifest: FileManifest;
}

