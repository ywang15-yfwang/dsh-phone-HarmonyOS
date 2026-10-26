import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * # DshNet —— **全仓唯一允许碰 HTTP 的地方**
 *
 * ## 为什么要有这个文件（客户 2026-10-17 定的规矩）
 * dsh 的 `/api` 有一道**围栏**，规则是三条、而且都容易写歪：
 *   ① `Host` 必须是**回环形式** `127.0.0.1:<dsh端口>`（否则 403）；
 *   ② `Cookie` 必须只送 `set-cookie` 的**首段** `name=value`（整串送 ⇒ 401）；
 *   ③ 带 `Origin` 时其 host 必须等于 `Host`（系统 WS 客户端做不到 ⇒ 见 `services/RawWs.ets`）。
 * 以前这套规则在 5 个文件里各写一遍（`DshApiClient` / `HttpTransport` / `DshPairing` / `UploadClient` / `DownloadClient`），
 * 改一处漏四处，漏的那处只会在某个页面偶发失败 —— 最难查的那类 bug。
 *
 * ⇒ **现在起：造请求头 / 建连接 / 映射错误码，只准在这里做。**
 * 其它文件一律调用本模块的 `requestText` / `requestBinary` / `streamToFile` / `pluginRequest`。
 * 这条规矩由 `tools/check-net-rule.mjs` 机械校验（构建前与 git 提交前各跑一次，违规直接失败）。
 */

const DOMAIN: number = 0xD001;
const TAG: string = 'NET';

/** 一台 dsh / 一个插件口的连接事实（**Host 与 Cookie 只从这里出去**） */
export interface NetTarget {
  /** 真正连的地址（真机 = 插件 tailnet 地址 `100.x`；插件自己的路由也走它） */
  address: string;
  /** 端口（dsh dsh 端口 / 配对口 插件端口） */
  port: number;
  /** 发出去的 `Host`；缺省 = 回环形式 `127.0.0.1:<port>` */
  hostHeader?: string;
  /** 浏览器 Cookie（`name=value` 首段）；空 = 不带 */
  cookie?: string;
  /** 走内核回环代理时的目标头（可选） */
  tsTarget?: string;
  /**
   * 路径前缀：**真机走插件转发时** = `/pair/dsh`（dsh 只听回环，tailnet 上只有插件 插件端口 能到）。
   * 插件自己的 `/pair/info`、`/pair/claim` 以及回环直连 dsh 时都不带。
   */
  pathPrefix?: string;
}

export interface TextResult {
  statusCode: number;
  body: string;
  elapsedMs: number;
  /** 连接层失败（拿不到响应）时的平台码；0 = 正常拿到响应 */
  errorCode: number;
  errorMessage: string;
}

export interface BinaryResult {
  statusCode: number;
  bytes: ArrayBuffer;
  elapsedMs: number;
  errorCode: number;
  errorMessage: string;
}

export interface StreamResult {
  statusCode: number;
  bytesWritten: number;
  localPath: string;
  elapsedMs: number;
  errorCode: number;
  errorMessage: string;
  /** 是否因为超过 maxBytes 被中止（上层据此不要回落整包读取） */
  overLimit: boolean;
}

/** **唯一的** Host 归一化点：缺省一律回环形式（围栏判据） */
export function hostHeaderOf(target: NetTarget): string {
  if (target.hostHeader !== undefined && target.hostHeader.length > 0) {
    return target.hostHeader;
  }
  return `127.0.0.1:${target.port}`;
}

/** **唯一的** 请求头构造点：Host / Cookie / 目标头 只在这里拼 */
export function headersOf(target: NetTarget, extra?: Record<string, string>): Record<string, string> {
  const headers: Record<string, string> = { 'Host': hostHeaderOf(target) };
  if (target.cookie !== undefined && target.cookie.length > 0) {
    headers['Cookie'] = target.cookie;
  }
  if (target.tsTarget !== undefined && target.tsTarget.length > 0) {
    headers['X-Ts-Target'] = target.tsTarget;
  }
  if (extra !== undefined) {
    const keys: string[] = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = extra[keys[i]];
    }
  }
  return headers;
}

export function urlOf(target: NetTarget, path: string): string {
  const prefix: string = target.pathPrefix !== undefined ? target.pathPrefix : '';
  return `http://${target.address}:${target.port}${prefix}${path}`;
}

/**
 * 一条 RPC / 探活请求（文本响应）。
 * @param body 非空则作为请求体（JSON）
 */
export async function requestText(target: NetTarget, method: http.RequestMethod, path: string,
  body: string = '', timeoutMs: number = 15000): Promise<TextResult> {
  const started: number = Date.now();
  const request: http.HttpRequest = http.createHttp();
  const extra: Record<string, string> = {};
  if (body.length > 0) {
    extra['Content-Type'] = 'application/json';
  }
  try {
    const response: http.HttpResponse = await request.request(urlOf(target, path), {
      method: method,
      header: headersOf(target, extra),
      extraData: body.length > 0 ? body : undefined,
      connectTimeout: 8000,
      readTimeout: timeoutMs,
      // 平台默认最多收 5MiB：session/attachment 的图片 base64 轻松超过它
      maxLimit: 32 * 1024 * 1024,
      expectDataType: http.HttpDataType.STRING
    });
    const text: string = typeof response.result === 'string' ? response.result as string : '(非文本)';
    return {
      statusCode: response.responseCode, body: text, elapsedMs: Date.now() - started,
      errorCode: 0, errorMessage: ''
    };
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'requestText 失败 path=%{public}s code=%{public}d', path, e.code ?? -1);
    return {
      statusCode: 0, body: '', elapsedMs: Date.now() - started,
      errorCode: e.code ?? -1, errorMessage: `${e.message}`
    };
  } finally {
    request.destroy();
  }
}

/** 一条二进制 GET（整包；只用于小文件——大文件请用 `streamToFile`） */
export async function requestBinary(target: NetTarget, method: http.RequestMethod,
  path: string): Promise<BinaryResult> {
  const started: number = Date.now();
  const request: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await request.request(urlOf(target, path), {
      method: method,
      header: headersOf(target),
      connectTimeout: 8000,
      readTimeout: 30000,
      maxLimit: 32 * 1024 * 1024,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    const bytes: ArrayBuffer = typeof response.result === 'object' && response.result !== null
      ? response.result as ArrayBuffer : new ArrayBuffer(0);
    return {
      statusCode: response.responseCode, bytes: bytes, elapsedMs: Date.now() - started,
      errorCode: 0, errorMessage: ''
    };
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'requestBinary 失败 path=%{public}s code=%{public}d', path, e.code ?? -1);
    return {
      statusCode: 0, bytes: new ArrayBuffer(0), elapsedMs: Date.now() - started,
      errorCode: e.code ?? -1, errorMessage: `${e.message}`
    };
  } finally {
    request.destroy();
  }
}

/**
 * **流式下载到文件**：`requestInStream` + `dataReceive` 边收边写盘，不整包进内存。
 * （系统下载器 `request.downloadFile` 不转发自定义 `Host` ⇒ 会被 dsh 围栏 403，故不用它。）
 */
export async function streamToFile(target: NetTarget, path: string, localPath: string,
  maxBytes: number = 0): Promise<StreamResult> {
  const started: number = Date.now();
  const request: http.HttpRequest = http.createHttp();
  try {
    if (fileIo.accessSync(localPath)) {
      fileIo.unlinkSync(localPath);
    }
  } catch (cleanError) {
    hilog.warn(DOMAIN, TAG, 'streamToFile 清理旧文件失败（忽略）');
  }
  let file: fileIo.File | undefined = undefined;
  let written: number = 0;
  let writeFailed: boolean = false;
  let overLimit: boolean = false;
  try {
    file = fileIo.openSync(localPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const targetFile: fileIo.File = file;
    request.on('dataReceive', (data: ArrayBuffer) => {
      if (writeFailed) {
        return;
      }
      try {
        // writeSync 可能短写：循环写满，只按实际写入量累计
        let off: number = 0;
        while (off < data.byteLength) {
          const part: ArrayBuffer = data.slice(off);
          const wrote: number = fileIo.writeSync(targetFile.fd, part);
          if (wrote <= 0) {
            throw new Error('写盘返回 0 字节');
          }
          off += wrote;
        }
        written += data.byteLength;
        // 审查 2026-10-22：服务端不给 Content-Length 时也要有上限，超了就停（否则巨大文件整包落盘）
        if (maxBytes > 0 && written > maxBytes) {
          overLimit = true;
          writeFailed = true;
          hilog.warn(DOMAIN, TAG, 'streamToFile 超过上限 %{public}d 字节，停止接收', maxBytes);
          try {
            request.destroy();
          } catch (destroyError) {
            // 已销毁
          }
        }
      } catch (writeError) {
        writeFailed = true;
        hilog.warn(DOMAIN, TAG, 'streamToFile 写盘失败');
      }
    });
    const code: number = await request.requestInStream(urlOf(target, path), {
      method: http.RequestMethod.GET,
      header: headersOf(target),
      connectTimeout: 8000,
      // readTimeout 在 netstack 里是**整次传输**的总超时：按上限估算至少 512KiB/s 的时长
      readTimeout: maxBytes > 0 ? Math.max(120000, Math.ceil(maxBytes / (512 * 1024)) * 1000) : 120000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    const bad: boolean = code < 200 || code >= 300 || writeFailed;
    if (overLimit) {
      // 超限落下的文件是半截，删掉，别让上层当成可用文件
      try {
        fileIo.unlinkSync(localPath);
      } catch (unlinkError) {
        // 忽略
      }
    }
    if (bad) {
      // 失败/截断落下的半截文件必须删掉，别让上层当成可用文件（审查 2026-10-22）
      try {
        fileIo.unlinkSync(localPath);
      } catch (unlinkError) {
        // 忽略
      }
      hilog.warn(DOMAIN, TAG, 'streamToFile 失败 code=%{public}d written=%{public}d', code, written);
    }
    return {
      statusCode: code, bytesWritten: bad ? -1 : written, localPath: localPath,
      elapsedMs: Date.now() - started, errorCode: 0, errorMessage: bad ? `HTTP ${code}` : '',
      overLimit: overLimit
    };
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'streamToFile 抛错 code=%{public}d', e.code ?? -1);
    // 异常路径（断网/超时/超限 destroy）同样会留下半截文件
    try {
      fileIo.unlinkSync(localPath);
    } catch (unlinkError) {
      // 忽略
    }
    return {
      statusCode: 0, bytesWritten: -1, localPath: localPath, elapsedMs: Date.now() - started,
      errorCode: e.code ?? -1, errorMessage: `${e.message}`, overLimit: overLimit
    };
  } finally {
    try {
      request.destroy();
    } catch (destroyError) {
      // 已销毁
    }
    if (file !== undefined) {
      try {
        fileIo.closeSync(file);
      } catch (closeError) {
        hilog.warn(DOMAIN, TAG, 'streamToFile 关闭文件失败');
      }
    }
  }
}

/** 把整段字节写满（`fileIo.writeSync` 可能短写；只写一次会静默截断文件） */
export function writeAllSync(fd: number, body: ArrayBuffer): void {
  let off: number = 0;
  while (off < body.byteLength) {
    const part: ArrayBuffer = body.slice(off);
    const wrote: number = fileIo.writeSync(fd, part);
    if (wrote <= 0) {
      throw new Error('写文件失败（0 字节）');
    }
    off += wrote;
  }
}

/** 插件口（配对口）的一问一答：来源闸门只放行回环/tailnet，不需要伪造 Host，但仍从这里走 */
export async function pluginRequest(host: string, port: number, method: http.RequestMethod,
  path: string, body: string = ''): Promise<TextResult> {
  const target: NetTarget = { address: host, port: port, hostHeader: `${host}:${port}` };
  return requestText(target, method, path, body, 10000);
}

// ── 错误码 → 人话（**唯一映射点**：界面文案不要各写一套） ─────────────────

/** HTTP 状态 → 人话（围栏/凭据/方法/不存在） */
export function humanizeHttp(status: number): string {
  if (status === 0) {
    return '连不上这台电脑（网络不通或 dsh 没起）';
  }
  if (status === 401) {
    return '凭据过期了，回上一页重新点「连接」';
  }
  if (status === 403) {
    return '电脑侧把这次连接拦下了（地址不被允许）';
  }
  if (status === 404) {
    return '电脑上没有这个接口（dsh 版本不对？）';
  }
  if (status === 409) {
    return '配对信息对不上：重开一次 App 再点「连接」';
  }
  if (status === 413) {
    return '这次送的内容太大，电脑侧不收';
  }
  if (status === 429) {
    return '电脑刚发过一份凭据，稍后再点一次';
  }
  if (status === 502) {
    return 'dsh 起着，但电脑侧拿不到访问凭据（dsh web 可能没就绪）';
  }
  if (status >= 500) {
    return `电脑侧出错了（HTTP ${status}），稍后再试`;
  }
  return `没成功（HTTP ${status}）`;
}

/** 平台网络码 → 人话（常见几个：2300007 连不上 / 2300028 超时） */
export function humanizeNetCode(code: number): string {
  if (code === 2300007) {
    return '连不上这台电脑（网络不通，或 dsh 没在跑）';
  }
  if (code === 2300028) {
    return '等太久了（电脑没回话）';
  }
  if (code === 201) {
    return '没有网络权限（App 的 INTERNET 权限被关了）';
  }
  return `网络异常（平台码 ${code}）`;
}

/** 一次原始往返（给文件传输层这种需要自带额外头的场景用；Host/Cookie 仍由本模块注入） */
export interface RawResult {
  statusCode: number;
  /** 响应头（HEAD 探长度要用） */
  headers: Record<string, string>;
  text: string;
  bytes: ArrayBuffer;
  elapsedMs: number;
  errorCode: number;
  errorMessage: string;
}

export async function requestRaw(target: NetTarget, method: http.RequestMethod, path: string,
  extraHeaders: Record<string, string> | undefined, body: ArrayBuffer | string | undefined,
  wantBytes: boolean, timeoutMs: number = 60000): Promise<RawResult> {
  const started: number = Date.now();
  const request: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await request.request(urlOf(target, path), {
      method: method,
      header: headersOf(target, extraHeaders),
      extraData: body,
      connectTimeout: 8000,
      // readTimeout 是整次传输总时长：上传按体积给（150MiB 约 5 分钟），而不是固定 60s
      readTimeout: timeoutMs,
      // 平台默认最多收 5MiB（session/attachment 的 base64、fetchBytes 兜底都可能超）
      maxLimit: 32 * 1024 * 1024,
      expectDataType: wantBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING
    });
    const text: string = typeof response.result === 'string' ? response.result as string : '';
    const headers: Record<string, string> = {};
    try {
      const rawHeaders: Record<string, Object> = response.header as Record<string, Object>;
      const keys: string[] = Object.keys(rawHeaders);
      for (let i = 0; i < keys.length; i++) {
        headers[keys[i].toLowerCase()] = `${rawHeaders[keys[i]]}`;
      }
    } catch (headerError) {
      // 取不到头就算了，别让下载因为探头失败而挂
    }
    const bytes: ArrayBuffer = typeof response.result === 'object' && response.result !== null && !(typeof response.result === 'string')
      ? response.result as ArrayBuffer : new ArrayBuffer(0);
    return {
      statusCode: response.responseCode, headers: headers, text: text, bytes: bytes, elapsedMs: Date.now() - started,
      errorCode: 0, errorMessage: ''
    };
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'requestRaw 失败 path=%{public}s code=%{public}d', path, e.code ?? -1);
    return {
      statusCode: 0, headers: {}, text: '', bytes: new ArrayBuffer(0), elapsedMs: Date.now() - started,
      errorCode: e.code ?? -1, errorMessage: `${e.message}`
    };
  } finally {
    request.destroy();
  }
}

