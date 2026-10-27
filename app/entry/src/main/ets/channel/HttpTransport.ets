/**
 * HttpTransport —— `FileTransport` 的**本机预验实现**（`@ohos.net.http`）。
 *
 * 【预验】提前验证产物：不作通过、不进验收结论；真机按正式顺序重跑，以真机为准。
 *
 * ⚠️ **它不满足契约 ①（streaming）**：`@ohos.net.http` 的 `extraData` 要求请求体一次性给出
 *    （字符串 / ArrayBuffer），所以本实现把写入累积在内存里、在 `close()` 时一次发出。
 *   ⇒ `isStreaming()` **如实返回 false**；**不作正式形态**，只用来在本机网络上预验
 *     ① 通道逻辑；② Host 处理；③ **HTTP 非 2xx = 业务结果（413/403 不抛异常）** 这条语义。
 *
 * 正式形态 = `KernelTransport`（client-core 5 个导出：streaming + 部分写 + 进度 + 取消）。
 *
 * 传输层纪律（照 app-ui `DshApiClient.ets` 的做法，不另起一套）：
 *   - `Host` 一律发**回环形式**（`127.0.0.1:<port>`），否则 `/api` 会 403（T2N 结论）；
 *   - 目标地址与 Host 分开配置。
 */

import { http } from '@kit.NetworkKit';
import { NetTarget, RawResult, requestRaw as dshRequestRaw } from '../services/net/DshNet';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ChunkSource, FileTransport, OpenOptions, ProgressSink, SimpleRequest, TransferResult, TransportReader,
  TransportSession, TransportTarget, TransportWriter, WriteAccepted,
  transferCancelled, transferFail, transferOk
} from './FileTransport';

const DOMAIN: number = 0xD001;
const TAG: string = 'P2CH-HTTP';

/** 把 Uint8Array 拼成一个 ArrayBuffer（预验用；正式形态不需要，因为它是流式的）。 */
function concatChunks(chunks: Uint8Array[]): ArrayBuffer {
  let total = 0;
  for (const chunk of chunks) {
    total += chunk.byteLength;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (let i = 0; i < chunks.length; i++) {
    const chunk: Uint8Array = chunks[i];
    out.set(chunk, offset);
    offset += chunk.byteLength;
    // 审查 2026-10-22：拼完立刻置空源分块，让 GC 逐步回收 ——
    // 否则 150MB 视频会同时存在"分块集合 + 拼接体"两份内存，峰值翻倍。
    chunks[i] = EMPTY_CHUNK;
  }
  return out.buffer as ArrayBuffer;
}

const EMPTY_CHUNK: Uint8Array = new Uint8Array(0);

class HttpWriter implements TransportWriter {
  private chunks: Uint8Array[] = [];
  private sent: number = 0;
  private cancelled: boolean = false;
  private target: TransportTarget;
  private options: OpenOptions;
  /**
   * 已知总大小时预分配的整块缓冲。
   * 有了它，写入是"逐块拷进同一块内存"，close() 直接发这块，
   * 不再需要 concatChunks（那一步会同时存在分块集合与拼接体两份）。
   */
  private prealloc: Uint8Array | undefined = undefined;

  constructor(target: TransportTarget, options: OpenOptions) {
    this.target = target;
    this.options = options;
    const hint: number = options.totalBytes === undefined ? -1 : options.totalBytes;
    if (hint > 0 && hint <= 512 * 1024 * 1024) {
      this.prealloc = new Uint8Array(hint);
    }
  }

  async write(bytes: Uint8Array): Promise<WriteAccepted> {
    if (this.cancelled) {
      return { ok: false, accepted: 0, stage: 'cancel', error: 'cancelled' };
    }
    if (this.prealloc !== undefined) {
      if (this.sent + bytes.byteLength > this.prealloc.byteLength) {
        return { ok: false, accepted: 0, stage: 'write', error: '写入超过声明的总大小' };
      }
      this.prealloc.set(bytes, this.sent);
    } else {
      this.chunks.push(bytes);
    }
    this.sent += bytes.byteLength;
    const sink: ProgressSink | undefined = this.options.progress;
    if (sink !== undefined && sink.onUpload !== undefined) {
      sink.onUpload(this.sent, -1);
    }
    // 预验实现一次全收，故 accepted == 全部长度（**正式形态必须按部分写处理**）
    return { ok: true, accepted: bytes.byteLength, stage: 'none', error: '' };
  }

  sentBytes(): number {
    return this.sent;
  }

  async cancel(reason: string): Promise<void> {
    this.cancelled = true;
    hilog.info(DOMAIN, TAG, 'P2CH http writer cancel: %{public}s', reason);
  }

  /** 预验实现：把累积的字节一次性发出（规则在 DshNet，本类只管"传什么"）。 */
  async close(): Promise<TransferResult> {
    const started: number = Date.now();
    if (this.cancelled) {
      return transferCancelled('cancel', this.sent, 0, Date.now() - started);
    }
    const netTarget: NetTarget = {
      address: this.target.address, port: this.target.port, hostHeader: this.target.hostHeader,
      cookie: this.target.cookie, tsTarget: undefined, pathPrefix: this.target.pathPrefix
    };
    let body: ArrayBuffer | undefined = undefined;
    if (this.prealloc !== undefined) {
      // 预分配路径：直接用这块内存，不拼接（少一份整包副本）
      body = this.sent === this.prealloc.byteLength
        ? this.prealloc.buffer as ArrayBuffer
        : this.prealloc.slice(0, this.sent).buffer as ArrayBuffer;
    } else if (this.chunks.length > 0) {
      body = concatChunks(this.chunks);
    }
    const method: http.RequestMethod = this.options.method === 'POST' ? http.RequestMethod.POST
      : http.RequestMethod.GET;
    // 上传体大小决定总超时（readTimeout 在 netstack 里是整次传输总时长，固定 60s 传不完 150MiB 视频）
    const uploadTimeout: number = this.sent > 0
      ? Math.max(120000, Math.ceil(this.sent / (512 * 1024)) * 1000)
      : 60000;
    const raw: RawResult = await dshRequestRaw(netTarget, method, this.options.path,
      this.options.headers, body, false, uploadTimeout);
    if (raw.errorCode !== 0) {
      return transferFail('write', describeTransportError(raw.errorCode, raw.errorMessage), 0, this.sent, 0,
        Date.now() - started);
    }
    // 契约 ④：HTTP 非 2xx 也不抛异常 ⇒ 一律 ok:true，状态码交给上层读
    return transferOk(raw.statusCode, raw.text, this.sent, raw.text.length, raw.elapsedMs);
  }
}

class HttpReader implements TransportReader {
  private received: number = 0;
  private statusCode: number = 0;
  private bodyText: string = '';
  private target: TransportTarget;
  private options: OpenOptions;

  constructor(target: TransportTarget, options: OpenOptions) {
    this.target = target;
    this.options = options;
  }

  receivedBytes(): number {
    return this.received;
  }

  status(): number {
    return this.statusCode;
  }

  text(): string {
    return this.bodyText;
  }

  async close(): Promise<TransferResult> {
    if (this.statusCode !== 0 || this.bodyText.length > 0) {
      return transferOk(this.statusCode, this.bodyText, 0, this.received, 0);
    }
    return transferFail('read', 'reader 尚未开始（预验实现里由 writer.close() 完成一次往返）', 0, 0, 0, 0);
  }

  async cancel(reason: string): Promise<void> {
    hilog.info(DOMAIN, TAG, 'P2CH http reader cancel: %{public}s', reason);
  }
}

/** 会话实现（抽象类 `TransportSession` 的具体类，避开 ArkTS 的"字面量函数属性"限制）。 */
class HttpSession extends TransportSession {
  readonly writer: TransportWriter;
  readonly reader: TransportReader;

  constructor(writer: TransportWriter, reader: TransportReader) {
    super();
    this.writer = writer;
    this.reader = reader;
  }

  async cancel(reason: string): Promise<void> {
    await this.writer.cancel(reason);
    await this.reader.cancel(reason);
  }
}

/**
 * 把传输层异常翻成**可读文案**（含 PM 转来的真语义，2026-10-12）。
 *
 * ⚠️ **实测语义（实测）**：**目标端口没人监听时，`@ohos.net.http` 表现为
 * `2300028 Operation timeout`（超时），不是立即拒绝** ⇒ 文案不要写成"连接被拒绝"，要写
 * "**目标不可达（超时）：端口没有服务在监听，或路径不通**"。
 */
function describeTransportError(code: number, message: string): string {
  if (code === 2300028) {
    return `EXCEPTION code=2300028（超时）：目标不可达 —— 端口没有服务在监听，或路径不通。原文=${message}`;
  }
  if (code === 2300007 || code === 2300006) {
    return `EXCEPTION code=${code}（主机/地址解析失败）。原文=${message}`;
  }
  if (code === 2300003) {
    return `EXCEPTION code=2300003（URL 或参数错误）。原文=${message}`;
  }
  return `EXCEPTION code=${code} ${message}`;
}

/**
 * 预验用传输实现（**buffered**）。
 */
export class HttpTransport implements FileTransport {
  readonly name: string = 'HttpTransport(@ohos.net.http, buffered=预验用)';

  isStreaming(): boolean {
    return false;
  }

  async open(target: TransportTarget, options: OpenOptions): Promise<TransportSession> {
    const writer = new HttpWriter(target, options);
    const reader = new HttpReader(target, options);
    const session: TransportSession = new HttpSession(writer, reader);
    return session;
  }

  async postJson(target: TransportTarget, path: string, body: string): Promise<TransferResult> {
    // JSON 信封直接一次性发（RPC 信封很小，不涉及流式契约）
    return this.requestRaw(target, { method: 'POST', path: path, headers: { 'Content-Type': 'application/json' }, body: body });
  }

  /** 发送一段文本请求体（内部/便利）。 */
  async postRaw(target: TransportTarget, path: string, body: string, contentType: string): Promise<TransferResult> {
    return this.requestRaw(target, { method: 'POST', path: path, headers: { 'Content-Type': contentType }, body: body });
  }

  /** 一次简单请求（GET / HEAD / 文本 POST）—— **带凭据头 + 回环 Host**。 */
  async basic(target: TransportTarget, request: SimpleRequest): Promise<TransferResult> {
    return this.requestRaw(target, request);
  }

  private async requestRaw(target: TransportTarget, request: SimpleRequest): Promise<TransferResult> {
    const started: number = Date.now();
    // **规则全在 DshNet**：Host/Cookie/超时/错误码只在那里写（客户 2026-10-17 定的规矩）
    const netTarget: NetTarget = {
      address: target.address, port: target.port, hostHeader: target.hostHeader,
      cookie: target.cookie, tsTarget: undefined, pathPrefix: target.pathPrefix
    };
    const method: http.RequestMethod = request.method === 'GET' ? http.RequestMethod.GET
      : (request.method === 'PUT' ? http.RequestMethod.PUT
        : (request.method === 'HEAD' ? http.RequestMethod.HEAD : http.RequestMethod.POST));
    const wantBinary: boolean = request.binary === true;
    const bodyForNet: string | undefined = request.body !== undefined && request.body.length > 0
      ? request.body : undefined;
    const raw: RawResult = await dshRequestRaw(netTarget, method, request.path, request.headers,
      bodyForNet, wantBinary);
    if (raw.errorCode !== 0) {
      return transferFail('write', describeTransportError(raw.errorCode, raw.errorMessage), 0, 0, 0,
        Date.now() - started);
    }
    const sentBytes: number = request.body === undefined ? 0 : request.body.length;
    if (request.method === 'HEAD') {
      return transferOk(raw.statusCode, JSON.stringify(raw.headers), 0, 0, raw.elapsedMs);
    }
    if (wantBinary) {
      const bytes: Uint8Array = raw.bytes.byteLength > 0 ? new Uint8Array(raw.bytes) : new Uint8Array(0);
      const binaryResult: TransferResult = {
        ok: true, status: raw.statusCode, body: '', bytes: bytes,
        sentBytes: sentBytes, receivedBytes: bytes.byteLength, elapsedMs: raw.elapsedMs,
        stage: 'none', error: '', cancelled: false
      };
      return binaryResult;
    }
    return transferOk(raw.statusCode, raw.text, sentBytes, raw.text.length, raw.elapsedMs);
  }
}

/**
 * 从 `ChunkSource` 一次传完（含**部分写重试**与**进度**）。
 * 这是上层 `UploadClient` 要用的公共路径 —— **无论 buffered 还是 streaming 实现，都走这一个函数**，
 * 区别只在 `FileTransport.write()` 的 `accepted` 语义（预验实现恒等于全长）。
 *
 * 契约 ⑤：`accepted < 长度` ⇒ 从 `accepted` 处继续写剩余部分；`accepted == 0` 连续 3 次 ⇒ 判失败（防死循环）。
 *
 * @returns 一次传输的结果（**ok 只代表传输完成；HTTP 状态码在 result.status 里**）
 */
export async function streamUpload(
  transport: FileTransport,
  target: TransportTarget,
  path: string,
  headers: Record<string, string>,
  source: ChunkSource,
  progress?: (acceptedBytes: number, totalBytes: number) => void
): Promise<TransferResult> {
  const started: number = Date.now();
  // 先把总大小告诉传输层：buffered 实现据此预分配，避免出现两份整包内存
  const total: number = source.totalBytes();
  const options: OpenOptions = {
    method: 'POST',
    path: path,
    headers: headers,
    streaming: true,
    totalBytes: total
  };
  let session: TransportSession | undefined = undefined;
  try {
    session = await transport.open(target, options);
  } catch (openError) {
    // 审查 2026-10-22：open 抛错时以前不 release 来源 ⇒ 文件句柄泄漏
    await source.release();
    throw openError as Error;
  }
  const opened: TransportSession = session;
  let acceptedTotal: number = 0;
  try {
    while (true) {
      const chunk: Uint8Array | null = await source.nextChunk();
      if (chunk === null) {
        break;
      }
      let offset: number = 0;
      let zeroWrites: number = 0;
      while (offset < chunk.byteLength) {
        const remaining: Uint8Array = chunk.subarray(offset);
        const accepted: WriteAccepted = await opened.writer.write(remaining);
        if (!accepted.ok) {
          await opened.writer.cancel(accepted.error);
          await source.release();
          return transferFail(accepted.stage, accepted.error, 0, acceptedTotal, 0, Date.now() - started);
        }
        if (accepted.accepted <= 0) {
          zeroWrites += 1;
          if (zeroWrites >= 3) {
            await opened.writer.cancel('部分写连续 3 次 accepted=0');
            await source.release();
            return transferFail('write', '部分写异常：连续 3 次 accepted=0（上游未接收）', 0, acceptedTotal, 0, Date.now() - started);
          }
          continue;
        }
        zeroWrites = 0;
        offset += accepted.accepted;
        acceptedTotal += accepted.accepted;
        if (progress !== undefined) {
          progress(acceptedTotal, total);
        }
      }
    }
    const result: TransferResult = await opened.writer.close();
    await source.release();
    return result;
  } catch (error) {
    const e = error as BusinessError;
    await source.release();
    return transferFail('write', describeTransportError(e.code ?? -1, e.message), 0, acceptedTotal, 0, Date.now() - started);
  }
}





