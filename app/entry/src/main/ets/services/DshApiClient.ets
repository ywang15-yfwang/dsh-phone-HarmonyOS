import { http } from '@kit.NetworkKit';
import { NetTarget, TextResult, humanizeNetCode, requestText } from './net/DshNet';
import { DSH_PATH_PREFIX } from '../model/EntryPorts';
import { activeProfile } from './ProfileStore';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buildPromptArgs } from '../features/f06-typing/DshSessionProtocol';
import { pairingVault } from '../features/f03-connect/PairingVault';

const DOMAIN: number = 0xD001;
const TAG: string = 'P2API';

/**
 * P2 通道客户端骨架（**预验**：不作通过、不进验收结论；真机按正式顺序重跑以真机为准）。
 *
 * 三条口径：
 *  ① **目标地址与 `Host` 头分开配置** —— T2N 实测：`/api` 的围栏判据是 **Host 头**（非回环 ⇒ 403），
 *     所以**地址**用 tailnet 上插件那一侧、**Host 仍发回环形式**；
 *  ② **传输层隔离在一处**（`send()`）——
 *     **最终方向（lead 定）：走 A = 内核 dial 导出、手机侧零监听；B（内核回环代理）不采用。**
 *     将来由 **A 的内核 dial 形态**替换这一处（client-core 在写"带句柄的流式请求"契约：
 *     `open/write/read/close` 或等价的"回调 + 轮询取块"，覆盖**长连事件流**与 **≤100MB 流式上传**）。
 *     **契约未到手前不猜、不加码**：`send()` 现在只是预验底座（普通 `http.request`）。
 *     Host 由我们在契约里定成**回环形式**（`127.0.0.1:<dsh端口>`）。
 *  ③ **凭据对用户不可见** —— 启动 token 换签名 Cookie，全程不要求用户输入任何东西。
 */

/** 目标：地址（socket 目标）与 Host 头（围栏判据）分开 */
export interface DshApiTarget {
  /** 真正连的地址：**真机 = 插件 tailnet 地址**（dsh 只听回环，插件转发到 dsh 端口） */
  address: string;
  /** socket 端口（插件口 插件端口；诊断件才用 dsh 端口 直连） */
  port: number;
  /** 发出去的 Host 头：**必须回环形式**，否则 /api 403 */
  hostHeader: string;
  /** 路径前缀（真机走插件转发 = `/pair/dsh`；回环直连 = 空串） */
  pathPrefix: string;
  /**
   * **走内核代理时的目标**（`<tailnet IP>:<dsh端口>`），由 `X-Ts-Target` 头交给内核转发；
   * 空串 = 不走代理（本机回环 / 真机直连）。
   */
  tsTarget: string;
  /** 经内核 netstack dial（方向 B）⇒ true；普通 OS socket（方向 A）⇒ false */
  viaKernelProxy: boolean;
}

export interface DshApiResult {
  ok: boolean;
  /** **双看后的判成败**：`2xx && body 无 error`（真 dsh 实测：业务失败时 HTTP 仍可能是 200） */
  apiOk: boolean;
  /** body 里的 `error.code｜error.message`（可读；无错误则空） */
  apiError: string;
  /** HTTP 状态码；0 = 没拿到响应（连接失败/超时） */
  code: number;
  body: string;
  elapsedMs: number;
  error: string;
  /**
   * 传输层 `BusinessError.code`（**可选**；0/undefined = 无结构化错误）。
   * 为什么要有它：AC-21 要分"**电脑离线**"与"**电脑在线但 dsh 未起**" —— 只能靠错误码区分：
   * `2300007 Failed to connect to the server`（连接没被接受）VS `2300028 Operation timeout`（超时）。
   * 依据：`references/js-apis-http.md:221/222/231`。
   */
  errCode?: number;
  /** T2N 语义：403 = 来源(Host)不对；401 = 来源对但无凭据；404 = 已通过 */
  fenceVerdict: string;
}

/**
 * body 里的业务错误（真 dsh 实测形状）：
 * `POST /api/session/uploadFileBinary?sessionId=nope` ⇒ **HTTP 200**，body `{"ok":false,"error":{"code":"session/not-found",…}}`
 * ⇒ **只看状态码会把业务失败当成功**（AC-07：`HTTP 200 ≠ 传输成功`；界面必须显示为失败、不得静默）。
 */
export function extractApiError(body: string): string {
  if (body.length === 0 || body.charAt(0) !== '{') {
    return '';
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    // 真实例实测：`/api` 的错误在外层 `result.error`
    // 例 `{"type":"server-response","rpcId":"s1","result":{"ok":false,"error":{"code":"gateway/internal","message":"…"}}}`
    // ⇒ 两层都要认（顶层 `error` 与 `result.error`），否则真跑通时也会判错。
    let errorValue: Object = parsed['error'];
    const resultValue: Object = parsed['result'];
    if ((errorValue === undefined || errorValue === null) && resultValue !== undefined && resultValue !== null) {
      errorValue = (resultValue as Record<string, Object>)['error'];
    }
    if (errorValue === undefined || errorValue === null) {
      return '';
    }
    const errObj = errorValue as Record<string, Object>;
    const codeValue: Object = errObj['code'];
    const messageValue: Object = errObj['message'];
    const code: string = codeValue === undefined ? '' : `${codeValue}`;
    const message: string = messageValue === undefined ? '' : `${messageValue}`;
    if (code.length === 0 && message.length === 0) {
      return '';
    }
    return `${code}${message.length > 0 ? `｜${message}` : ''}`;
  } catch (parseError) {
    return '';
  }
}

/**
 * **真机唯一通路**：手机在 tailnet 上唯一能到的门是插件 `插件端口`（dsh 只听电脑回环）。
 * 请求打 `插件地址:插件端口` + `/pair/dsh` + 原路径；`Host` 恒 `127.0.0.1:dsh 端口`（插件铸凭据绑的 authority）。
 */
export function pluginTarget(pluginHost: string): DshApiTarget {
  // 端口与 Host 都来自**当前电脑的配置**（客户 2026-10-21：不许再写死端口）
  const target: DshApiTarget = {
    address: pluginHost,
    port: activeProfile().pluginPort,
    hostHeader: `127.0.0.1:${activeProfile().dshPort}`,
    pathPrefix: DSH_PATH_PREFIX,
    tsTarget: '',
    viaKernelProxy: false
  };
  return target;
}

/**
 * **最终形态（方向 B，待 lead 裁 AC-20③ 后实现）**：内核只绑 `127.0.0.1:<proxyPort>` 的小代理，
 * 目标经 `X-Ts-Target: <tailnet IP>:<dsh端口>` 指定，**Host 由内核代理设成回环形式**。
 *
 * ⚠️ **authority 与 Cookie 的坑（现在就按最终形态设计）**：dsh 的签名 Cookie **绑定 authority(host:port)**
 * ⇒ `GET /?token=…` 与后续 `/api` **必须同一 authority**；**中途改路径（例如从直连改成走代理）⇒ 必须重取 Cookie**。
 * ⇒ 因此 `proxyPort` 定了之后**不要再换**。
 */
export function kernelProxyTarget(proxyPort: number, tailnetIp: string, dshPort: number): DshApiTarget {
  const target: DshApiTarget = {
    address: '127.0.0.1',
    port: proxyPort,
    hostHeader: `127.0.0.1:${dshPort}`,
    pathPrefix: '',
    tsTarget: `${tailnetIp}:${dshPort}`,
    viaKernelProxy: true
  };
  return target;
}

/** 真机：地址走电脑 tailnet 地址；Host 仍发回环（由电脑侧小转发重写/落到回环 dsh） */
export function tailnetTarget(address: string, port: number, hostPort: number): DshApiTarget {
  const target: DshApiTarget = {
    address: address,
    port: port,
    hostHeader: `127.0.0.1:${hostPort}`,
    pathPrefix: '',
    tsTarget: '',
    viaKernelProxy: false
  };
  return target;
}

function fenceVerdict(code: number): string {
  if (code === 403) {
    return '403 = Host 不受信（围栏拦下）⇒ Host 必须改成回环形式';
  }
  if (code === 401) {
    return '401 = 围栏已过、缺凭据 ⇒ 只差凭据';
  }
  if (code === 404) {
    return '404 = 围栏与鉴权都已通过（路由层）';
  }
  return `code=${code}`;
}

export class DshApiClient {
  private target: DshApiTarget;
  /** 签名 Cookie（首次配对换得；对用户不可见） */
  private cookie: string = '';
  private rpcSeq: number = 0;

  constructor(target: DshApiTarget) {
    this.target = target;
  }

  setCookie(cookie: string): void {
    this.cookie = cookie;
  }

  hasCookie(): boolean {
    return this.cookie.length > 0;
  }

  baseUrl(): string {
    return `http://${this.target.address}:${this.target.port}`;
  }

  apiUrl(): string {
    return `${this.baseUrl()}/api`;
  }

  private nextRpcId(): string {
    this.rpcSeq = this.rpcSeq + 1;
    return `p2-${Date.now()}-${this.rpcSeq}`;
  }

  /**
   * **传输层唯一落点**（对齐页 A/B 问题的切换点）。
   * 现在按假设 A：普通 `http.request`（OS 会话经 tun 路由）。
   */
  private async send(url: string, method: http.RequestMethod, body: string,
    timeoutMs: number = 15000): Promise<DshApiResult> {
    const started: number = Date.now();
    // **规则全在 services/net/DshNet**（Host 回环 / Cookie 首段 / 超时 / 错误码）
    const netTarget: NetTarget = {
      address: this.target.address, port: this.target.port,
      hostHeader: this.target.hostHeader, cookie: this.cookie, tsTarget: this.target.tsTarget,
      pathPrefix: this.target.pathPrefix
    };
    const path: string = this.pathOf(url);
    const res: TextResult = await requestText(netTarget, method, path, body, timeoutMs);
    if (res.errorCode !== 0) {
      const failed: DshApiResult = {
        ok: false, apiOk: false, apiError: '', code: 0, body: '', elapsedMs: res.elapsedMs,
        error: `EXCEPTION | code=${res.errorCode} ${res.errorMessage}`,
        errCode: res.errorCode, fenceVerdict: humanizeNetCode(res.errorCode)
      };
      return failed;
    }
    const text: string = res.body;
    const code: number = res.statusCode;
    if (code === 401 && this.cookie.length > 0) {
      pairingVault.markRejected();
    }
    const apiError: string = extractApiError(text);
    const apiOk: boolean = (code >= 200 && code < 300) && apiError.length === 0;
    const result: DshApiResult = {
      ok: code >= 200 && code < 300, apiOk: apiOk, apiError: apiError, code: code, body: text,
      elapsedMs: res.elapsedMs, error: '', fenceVerdict: fenceVerdict(code)
    };
    return result;
  }

  /** 由完整 URL 反推出 /api... 路径（规则集中在 DshNet，本类不拼头） */
  private pathOf(url: string): string {
    const base: string = this.baseUrl();
    if (url.startsWith(base)) {
      const rest: string = url.substring(base.length);
      return rest.length > 0 ? rest : '/';
    }
    return url;
  }

  /** 未认证 `GET /`：dsh 固定指纹（用于"这里是不是 dsh"） */
  async fingerprint(): Promise<DshApiResult> {
    return this.send(`${this.baseUrl()}/`, http.RequestMethod.GET, '');
  }

  /**
   * 未认证 `GET /api`：**围栏探针**（只读、无凭据）。
   * 用于判定"平台 http 栈能否显式覆盖 Host"：**同一地址发不同 Host，看返回码是否不同** ——
   * `Host: 127.0.0.1:<端口>` ⇒ 401（围栏放行、缺凭据）；非回环 `Host` ⇒ 403（围栏拦下）。
   */
  async apiFenceProbe(): Promise<DshApiResult> {
    return this.send(this.apiUrl(), http.RequestMethod.GET, '');
  }

  currentHostHeader(): string {
    return this.target.hostHeader;
  }

  /**
   * `/api` RPC：**端点必须在 URL 路径里**（`/api/<namespace>/<method>`），
   * **body 的 `method` 与端点一字不差**，且 `Content-Type: application/json` 不能省。
   * 依据（源码级 + 四格实测）：`dsh-client-connection/lib/index.js:711-716`（`endpointFromPath`：路径须以 `/api/` 开头 ⇒ 端点 = 去掉 `/api/`）、`:678`（取不到端点 ⇒ **404**）、`:679`（非 JSON ⇒ 415）、`:689-693`（`method` 与端点不一致 ⇒ 400）。
   * ⇒ 旧写法 `POST /api` + body.method ⇒ **404 `not found`**（我踩过）；改路径形态后 **200**（打到服务；`gateway/internal` 才是环境缺件）。
   */
  async rpc(method: string, payload: string, timeoutMs: number = 15000): Promise<DshApiResult> {
    // 服务实测要求（`gateway/internal: Remote payload must contain exactly one plain-object args field`）：
    // `payload` **不是字符串、也不是参数本身**，而是**恰好一个 `args` 字段的 plain-object** ⇒ `payload:{args:{…}}`。
    // 用字符串拼接而不是对象字面量，规避 ArkTS 未声明类型字面量的限制。
    const rpcId: string = JSON.stringify(this.nextRpcId());
    const envelope: string = `{"type":"client-request","rpcId":${rpcId},"method":${JSON.stringify(method)},` +
      `"payload":{"args":${payload.length > 0 ? payload : '{}'}}}`;
    const url: string = `${this.baseUrl()}/api/${method}`;
    hilog.info(DOMAIN, TAG, 'P2API rpc endpoint=/api/%{public}s', method);
    return this.send(url, http.RequestMethod.POST, envelope, timeoutMs);
  }

  /**
   * F11/F2：建会话（电脑端落盘，手机不另存）。
   * ⚠️ 形状订正（F2 轮，源码级）：args 里**必须有 `request` 层**
   * —— `typert.host.js:192-202` 的形参名就是 `request`（字段 `workspaceId?/cwd?/sessionId?/agentPreset?` 全可选）。
   * 旧写法 `{"workspaceId":…}` 缺这一层 ⇒ 实测必踩 `gateway/arguments-invalid`（已有卡面记录）。
   */
  async sessionCreate(workspaceId: string): Promise<DshApiResult> {
    const args: string = workspaceId.length > 0
      ? `{"request":{"workspaceId":${JSON.stringify(workspaceId)}}}`
      : '{"request":{}}';
    return this.rpc('session/create', args);
  }

  /**
   * F11/F2：把文字送进那场会话。
   * ⚠️ 形状订正（F2 轮，源码级）：`session/prompt` 的 request 是
   * `{requestId, sessionId, mode:'queue'|'steer', content:[{type:'text',text}]}`，返回 `{accepted:true}`
   * —— `typert.host.js:784-805`。旧写法 `{sessionId, prompt}` **既缺 `request` 层、字段名也不对**。
   * 这里直接复用 `model/DshSessionProtocol` 的构造器（单一事实源）。
   */
  async sessionPrompt(sessionId: string, text: string): Promise<DshApiResult> {
    return this.rpc('session/prompt', buildPromptArgs(sessionId, text, `req-app-${Date.now()}`));
  }
}



