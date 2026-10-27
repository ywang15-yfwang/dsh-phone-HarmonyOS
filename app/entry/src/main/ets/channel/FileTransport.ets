/**
 * FileTransport —— F6/F7 的**传输层唯一落点**（与 app-ui 的 `DshApiClient.send()` 同构：只此一处可换挡）。
 *
 * 【预验】提前验证产物：不作通过、不进验收结论；真机按正式顺序重跑，以真机为准。
 *
 * ---------------------------------------------------------------------------
 * 契约口径（来自 client-core 的答复，2026-10-12；**照抄不解释**）
 *   ① **整包上传 = streaming（不 buffered）** ⇒ 走 `uploadFileBinary` 的**流式请求体**，
 *      **不要一次性把整包塞进一个字符串**；
 *   ② **进度**：上行 `accepted` / `sentBytes`；下行 `receivedBytes`（名字以契约为准）；
 *   ③ **取消** = `Close`（context cancel + 断连 + 释放缓冲）；
 *   ④ **HTTP 非 2xx 不算错误** —— 那是 `ok:true` + `status`（**413 / 403 是可读的业务结果**，
 *      不得当成传输层异常抛出）；
 *   ⑤ **背压 = 部分写**：一次写 `accepted` **可能小于**给定长度，**剩余部分由调用方重试**；
 *      内核队列 8 MiB、接收缓冲高水位 2 MiB ⇒ 不整包驻留、不丢数据；
 *   ⑥ **目标与 Host 都是内核 `open` 的 JSON 字段**（`Host` 默认回环 `127.0.0.1:<port>`）；
 *      **A 路没有 `X-Ts-Target`**（那是 B 路代理头，已随 B 作废）。
 * ---------------------------------------------------------------------------
 *
 * 本文件只定义**接口与数据形状**，不含任何实现；保证「换挡成本 = 换一个实现类」。
 */

/** 内核 `open` 的目标（对应契约里"目标与 Host 都是 open 的 JSON 字段"）。 */
export interface TransportTarget {
  /** 真正连的地址；= 电脑的 tailnet 地址 */
  address: string;
  /** 入口端口 */
  port: number;
  /** 发出去的 Host（**必须回环形式**，否则 `/api` 403 —— T2N 结论）；缺省由实现补 `127.0.0.1:<port>` */
  hostHeader?: string;
  /**
   * 路径前缀：真机走插件转发时 = `/pair/dsh`（dsh 只听回环，tailnet 上只有插件 插件端口 能到）；
   * 回环直连 = 空。
   */
  pathPrefix?: string;
  /**
   * 真 dsh 的凭据：**浏览器 Cookie**（启动 token 换 303 + `Set-Cookie` 得来的签名 Cookie）。
   * 对用户不可见；**首次配对**才需要（《开发文档》§6 第 3 条：扫码一次）。
   */
  cookie?: string;

}

/**
 * 传输层的结果。
 * **重要**：HTTP 非 2xx 也会返回 `ok:true`（契约 ④）—— `status` 是业务结果不是异常。
 */
export interface TransferResult {
  /** 传输本身是否完成（**不代表 HTTP 2xx**） */
  ok: boolean;
  /** HTTP 状态码；0 = 没拿到响应 */
  status: number;
  /** 响应体（文本）；`binary: true` 时为空串（用 `bytes`） */
  body: string;
  /** 响应体原始字节（仅在请求 `binary: true` 时填充）—— F7 取图必须走这条，否则二进制会被当文本毁掉 */
  bytes?: Uint8Array;
  /** 已发送字节（上行） */
  sentBytes: number;
  /** 已接收字节（下行） */
  receivedBytes: number;
  /** 耗时（毫秒） */
  elapsedMs: number;
  /** 失败阶段：none / open / write / read / cancel / unknown */
  stage: string;
  /** 失败原因原文（成功为空串） */
  error: string;
  /** 被取消 */
  cancelled: boolean;
}

/** 部分写语义（契约 ⑤）：调用方拿到 accepted 后要自行重试剩余字节。 */
export interface WriteAccepted {
  ok: boolean;
  /** 本次真正被接受的字节数（**可能小于**提交长度） */
  accepted: number;
  stage: string;
  error: string;
}

/** 写入端（上行流）。 */
export interface TransportWriter {
  /**
   * 写一段字节。**必须按"部分写"处理**：`accepted < bytes.byteLength` 时，
   * 调用方要从 `accepted` 处继续写剩余部分（见 `StreamUploader.writeAll`）。
   */
  write(bytes: Uint8Array): Promise<WriteAccepted>;
  /** 发送边界（结束请求体） */
  close(): Promise<TransferResult>;
  /** 已接受的总字节 */
  sentBytes(): number;
  /** 取消（= 契约里的 `Close`：断连 + 释放缓冲） */
  cancel(reason: string): Promise<void>;
}

/** 读取端（下行流）。 */
export interface TransportReader {
  /** 已接收字节 */
  receivedBytes(): number;
  status(): number;
  /** 当前收集到的响应体（文本场景） */
  text(): string;
  /** 读完（等待结束） */
  close(): Promise<TransferResult>;
  cancel(reason: string): Promise<void>;
}

/**
 * 打开的连接（一次请求一个）。
 *
 * ⚠️ **写成抽象类而不是 interface**：ArkTS 不允许**对象字面量里出现函数属性**
 *   （`arkts-no-untyped-obj-literals`）—— 接口里声明 `cancel(): Promise<void>` 会导致
 *   `{ …, cancel: … }` 这种字面量全部编译失败。抽象类 + `implements` 就没有这个限制，
 *   形态与语义完全一致。
 */
export abstract class TransportSession {
  abstract readonly writer: TransportWriter;
  abstract readonly reader: TransportReader;
  /** 整体取消（= 契约里的 `Close`：断开 + 释放缓冲） */
  abstract cancel(reason: string): Promise<void>;
}

/** 分块来源：**流式上传用**（不是把整包驻留在内存里）。 */
export interface ChunkSource {
  /** 总字节数（用于 100MB 前置判定与进度分母；未知时给 -1） */
  totalBytes(): number;
  /** 取下一块；返回 null 表示结束 */
  nextChunk(): Promise<Uint8Array | null>;
  /** 释放（关文件句柄等） */
  release(): Promise<void>;
}

/** 进度回调：上行按已接受字节报，下行按已接收字节报。 */
export interface ProgressSink {
  onUpload?(acceptedBytes: number, totalBytes: number): void;
  onDownload?(receivedBytes: number, totalBytes: number): void;
}

export interface OpenOptions {
  method: string;
  path: string;
  headers?: Record<string, string>;
  /** 请求体是否为流式（streaming） */
  streaming?: boolean;
  /**
   * 请求体总字节数（已知时传入）。
   * buffered 实现的写入端据此**一次性预分配**整块缓冲，避免“分块集合 + 拼接体”两份同时驻留。
   */
  totalBytes?: number;
  progress?: ProgressSink;
}

/** 一次简单请求的选项（GET / HEAD / POST 文本体；给"非流式"的路由用）。 */
export interface SimpleRequest {
  /** HTTP 方法（字符串；实现自行映射） */
  method: string;
  path: string;
  headers?: Record<string, string>;
  /** 文本体（不传 = 无体） */
  body?: string;
  /**
   * 是否需要**原始字节**响应（`true` ⇒ 用 `ARRAY_BUFFER` 收，填 `TransferResult.bytes`）。
   * **取图片 / 任何二进制必须置 true** —— 预验实测：走文本路径会把 153,838 B 的 PNG 毁成 8 B。
   */
  binary?: boolean;
}

/**
 * 传输层接口 —— **唯一的换挡点**。
 *
 * 两种实现（都在动，见 `HttpTransport` 与 `KernelTransport`）：
 *  - `HttpTransport`：本机预验用（`@ohos.net.http`）。**buffered**，故**不满足契约 ①**；
 *    仅用于「通道逻辑 + Host 处理 + 状态码语义」的预验，**不作为正式形态**。
 *  - `KernelTransport`：正式形态（client-core 的 5 个导出落地后接通）——**streaming + 部分写 + 进度 + 取消**。
 */
export interface FileTransport {
  /** 实现名（日志与证据里要写清用的是哪一档） */
  readonly name: string;
  /** 当前实现是否满足契约 ①（流式）。**buffered 实现必须如实返回 false**。 */
  isStreaming(): boolean;
  /** 打开一次请求 */
  open(target: TransportTarget, options: OpenOptions): Promise<TransportSession>;
  /** 一次到位的 JSON POST（RPC 信封用） */
  postJson(target: TransportTarget, path: string, body: string): Promise<TransferResult>;
  /**
   * 一次简单请求（GET / HEAD / 文本 POST）——
   * **路由语义按真 dsh 实际注册的来**：`/api/file` 是 **exact Fetch 路由（GET/HEAD）**
   * （`dsh-client-connection/lib/index.js:608-624`：先查 exact 路由，再落到 RPC 前缀），
   * 所以取文件**不该**走 RPC 信封。
   */
  basic(target: TransportTarget, request: SimpleRequest): Promise<TransferResult>;
}

/** 生成默认回环 Host（契约 ⑥：Host 默认回环 `127.0.0.1:<port>`）。 */
export function defaultLoopbackHost(target: TransportTarget): string {
  const explicit = target.hostHeader;
  if (explicit !== undefined && explicit.length > 0) {
    return explicit;
  }
  return `127.0.0.1:${target.port}`;
}

/** 构造一个成功结果（内部用）。 */
export function transferOk(status: number, body: string, sent: number, received: number, elapsed: number): TransferResult {
  return {
    ok: true, status: status, body: body, sentBytes: sent, receivedBytes: received,
    elapsedMs: elapsed, stage: 'none', error: '', cancelled: false
  };
}

/** 构造一个失败结果（内部用；**HTTP 非 2xx 不走这里**，那是 ok:true + status）。 */
export function transferFail(stage: string, error: string, status: number, sent: number, received: number, elapsed: number): TransferResult {
  return {
    ok: false, status: status, body: '', sentBytes: sent, receivedBytes: received,
    elapsedMs: elapsed, stage: stage, error: error, cancelled: false
  };
}

/** 构造一个被取消的结果。 */
export function transferCancelled(stage: string, sent: number, received: number, elapsed: number): TransferResult {
  return {
    ok: false, status: 0, body: '', sentBytes: sent, receivedBytes: received,
    elapsedMs: elapsed, stage: stage, error: 'cancelled', cancelled: true
  };
}


