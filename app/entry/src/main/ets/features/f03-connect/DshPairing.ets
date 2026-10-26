import { http } from '@kit.NetworkKit';
import { TextResult, pluginRequest } from '../../services/net/DshNet';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'F2PAIRP';

/**
 * F2 配对（功能 3 现行口径）：**走 `dsh-pair` 插件的自有监听口** ——
 * 手机点一下就拿钥匙、电脑侧零操作；**凭据只进内存、不落盘**（插件随时能再签一份）。
 *
 * 与旧版的区别（**本轮的口径变更**）：
 *  - 旧版：打电脑侧 `run-isolated-dsh.mjs --serve-once <port>` 的**一次性端点**（读一次即关、要人先起好）；
 *  - 新版：`GET /pair/info` 探活 → `POST /pair/claim` 一步取凭据（`{cookieName, cookieValue, authority, expiresAt}`）。
 *
 * 插件契约（`dsh-to-phone` 的 README ＋ 其实现实测）：
 *  - `GET  /pair/info`  ⇒ `{ok, name, version, phoneAuthority, credentialLifetimeDays, tailnet, bound, listenPort}`；
 *  - `POST /pair/claim` body `{device, note, authority}` ⇒ `200 {cookieName, cookieValue, authority, expiresAt, credentialLifetimeMs}`；
 *    **`cookieValue` 是原始 `set-cookie` 串**（首段＝`name=value`，后面跟 `; Path=/…` 等属性）；
 *  - 错码：`403` 来源闸门（只放行回环与本机 tailnet）／`409` authority 不匹配／`429` 同来源 10s 限 1 次／
 *    `502` 插件铸不出 cookie（dsh web 未跑或 launch token 失效）。
 *
 * 纪律：**只记长度与 authority**，绝不把 `cookieValue` 拼进日志或界面；**不落盘**。
 */

export interface PairInfoResult {
  ok: boolean;
  status: number;
  /** 凭据会绑到的 authority（＝手机之后直连 dsh 时必须用的 Host） */
  phoneAuthority: string;
  dshAuthority: string;
  credentialLifetimeDays: number;
  pluginName: string;
  pluginVersion: string;
  tailnet: string;
  elapsedMs: number;
  /** 可读说明（成功/失败都能直接显示） */
  message: string;
  /** 探活 URL（**不含凭据**） */
  url: string;
}

export interface PairClaimResult {
  ok: boolean;
  status: number;
  cookieName: string;
  /** ⚠️ **凭据本体（原始 set-cookie 串）**：只许交给 `pairingVault.set()`，别拿去拼字符串/打日志/渲染 */
  cookieValue: string;
  authority: string;
  expiresAtMs: number;
  elapsedMs: number;
  message: string;
  url: string;
}

export function pairInfoUrl(host: string, port: number): string {
  return `http://${host}:${port}/pair/info`;
}

export function pairClaimUrl(host: string, port: number): string {
  return `http://${host}:${port}/pair/claim`;
}

/** JSON 平铺取值：`Record` ＋ `typeof` 收窄（避开 ArkTS 对 `any`/索引访问的限制） */
function strField(o: Record<string, Object>, key: string): string {
  const v: Object | undefined = o[key];
  return typeof v === 'string' ? v as string : '';
}

function numField(o: Record<string, Object>, key: string): number {
  const v: Object | undefined = o[key];
  return typeof v === 'number' ? v as number : 0;
}

/** 错码 → 人话（码的来源见文件头注释） */
function reasonFor(status: number, body: string): string {
  if (status === 403) {
    return '403：来源被闸门拦下（配对口只放行"回环"与"本机 tailnet 地址"）';
  }
  if (status === 409) {
    return `409：authority 不匹配（插件要求手机用同一个 Host）${body.length > 0 ? `｜${body}` : ''}`;
  }
  if (status === 429) {
    return '429：请求太快（同一来源 IP 10 秒内只允许 1 次 claim）⇒ 等 10 秒再点一次';
  }
  if (status === 502) {
    return '502：插件拿不到 cookie（dsh web 未跑、或 launch token 失效）';
  }
  return `HTTP ${status}${body.length > 0 ? `｜${body}` : ''}`;
}

/** 探活：`GET /pair/info`。**只读**，不铸凭据。 */
export async function fetchPairInfo(host: string, port: number): Promise<PairInfoResult> {
  const url: string = pairInfoUrl(host, port);
  const started: number = Date.now();
  const fail = (status: number, message: string): PairInfoResult => {
    return {
      ok: false, status: status, phoneAuthority: '', dshAuthority: '', credentialLifetimeDays: 0,
      pluginName: '', pluginVersion: '', tailnet: '', elapsedMs: Date.now() - started,
      message: message, url: url
    };
  };
  try {
    // 规则统一在 `services/net/DshNet`（不在这里拼头/建连接）
    const res: TextResult = await pluginRequest(host, port, http.RequestMethod.GET, '/pair/info');
    if (res.errorCode !== 0) {
      return fail(0, `不通：配对口 ${host}:${port} 连不上（插件未加载 / 不在同一网段 / 端口不对）（平台码 ${res.errorCode}）`);
    }
    const status: number = res.statusCode;
    const raw: string = res.body;
    const elapsed: number = Date.now() - started;
    hilog.info(DOMAIN, TAG, 'F2PAIRP info status=%{public}d bytes=%{public}d', status, raw.length);
    if (status < 200 || status >= 300) {
      return fail(status, `探活失败：${reasonFor(status, raw.substring(0, 120))}`);
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (parseError) {
      return fail(status, '探活失败：配对口回了内容，但不是 /pair/info 的 JSON（端口可能打到了别的服务）');
    }
    const authority: string = strField(parsed, 'phoneAuthority');
    if (authority.length === 0) {
      return fail(status, '探活失败：响应里没有 phoneAuthority ⇒ 这不像 dsh-pair 插件（端口可能打到了别的服务）');
    }
    const name: string = strField(parsed, 'name');
    const version: string = strField(parsed, 'version');
    return {
      ok: true, status: status, phoneAuthority: authority,
      dshAuthority: strField(parsed, 'dshAuthority'),
      credentialLifetimeDays: numField(parsed, 'credentialLifetimeDays'),
      pluginName: name, pluginVersion: version, tailnet: strField(parsed, 'tailnet'),
      elapsedMs: elapsed,
      message: `插件在线（${name} ${version}）｜凭据绑 authority=${authority}`, url: url
    };
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'F2PAIRP info unreachable code=%{public}d', e.code ?? -1);
    return fail(0,
      `不通：配对口 ${host}:${port} 连不上（插件未加载 / 不在同一网段 / 端口不对）（平台码 ${e.code ?? -1}）`);
  }
}

/** 取凭据：`POST /pair/claim`（一步签发；到期前可重跑续期，同来源 IP 限速 10s）。 */
export async function claimCredential(host: string, port: number, authority: string,
  device: string, note: string): Promise<PairClaimResult> {
  const url: string = pairClaimUrl(host, port);
  const started: number = Date.now();
  const fail = (status: number, message: string): PairClaimResult => {
    return {
      ok: false, status: status, cookieName: '', cookieValue: '', authority: authority,
      expiresAtMs: 0, elapsedMs: Date.now() - started, message: message, url: url
    };
  };
  const payload: Record<string, string> = { 'device': device, 'note': note, 'authority': authority };
  try {
    // 规则统一在 `services/net/DshNet`
    const res: TextResult = await pluginRequest(host, port, http.RequestMethod.POST, '/pair/claim',
      JSON.stringify(payload));
    if (res.errorCode !== 0) {
      return fail(0, `不通：配对口 ${host}:${port} 连不上（插件未加载 / 不在同一网段 / 端口不对）（平台码 ${res.errorCode}）`);
    }
    const status: number = res.statusCode;
    const raw: string = res.body;
    const elapsed: number = Date.now() - started;
    if (status < 200 || status >= 300) {
      hilog.warn(DOMAIN, TAG, 'F2PAIRP claim status=%{public}d', status);
      return fail(status, `取凭据失败：${reasonFor(status, raw.substring(0, 160))}`);
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (parseError) {
      return fail(status, '取凭据失败：插件回了内容但不是 JSON');
    }
    const cookieName: string = strField(parsed, 'cookieName');
    const cookieValue: string = strField(parsed, 'cookieValue');
    const gotAuthority: string = strField(parsed, 'authority');
    const expiresAtMs: number = numField(parsed, 'expiresAt');
    // **只记长度**（凭据本体不回显、不进日志）
    hilog.info(DOMAIN, TAG, 'F2PAIRP claim ok cookieBytes=%{public}d nameBytes=%{public}d',
      cookieValue.length, cookieName.length);
    if (cookieValue.length === 0 || cookieName.length === 0) {
      return fail(status, '取凭据失败：插件回 200 但没给 cookieName/cookieValue');
    }
    const head: string = cookieValue.split(';')[0];
    if (head.indexOf('=') < 0) {
      return fail(status, '取凭据失败：cookieValue 首段不是 `name=value`（插件响应形态变了）');
    }
    if (expiresAtMs <= 0) {
      return fail(status, '取凭据失败：插件没给 expiresAt（有效期未知）');
    }
    return {
      ok: true, status: status, cookieName: cookieName, cookieValue: cookieValue,
      authority: gotAuthority.length > 0 ? gotAuthority : authority, expiresAtMs: expiresAtMs,
      elapsedMs: elapsed, message: '取到凭据（只记长度；本体只进内存）', url: url
    };
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'F2PAIRP claim unreachable code=%{public}d', e.code ?? -1);
    return fail(0,
      `不通：配对口 ${host}:${port} 连不上（插件未加载 / 不在同一网段 / 端口不对）（平台码 ${e.code ?? -1}）`);
  }
}


/** 配对/探活的 HTTP 状态码 → 人话（原来在首页里，2026-10-21 挪到这里给配置页共用） */
export function humanPairError(status: number): string {
  if (status === 403) {
    return '403：来源被闸门拦下（配对口只放行"回环"与"本机 tailnet 地址"）';
  }
  if (status === 409) {
    return '409：authority 不匹配（插件要求手机用同一个 Host）';
  }
  if (status === 429) {
    return '429：请求太快（同一来源 10 秒内只允许 1 次 claim）⇒ 等 10 秒再点一次';
  }
  if (status === 502) {
    return '502：插件拿不到 cookie（dsh web 未跑、或 launch token 失效）';
  }
  if (status === 0) {
    return '连不上：插件端口不通（端口错、电脑没开，或不在同一网络）';
  }
  return `配对失败：HTTP ${status}`;
}