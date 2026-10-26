import { DshApiClient, DshApiResult, DshApiTarget } from '../../services/DshApiClient';
import { formatClock } from '../../model/VpnTypes';
import { DshConnState, DshProbeOutcome } from './DshConnModel';

/**
 * F3 连接探测层（**唯一的数据源**：界面只消费它的结果，不自造状态）。
 *
 * 判据（全部来自**只读**请求：未认证 `GET /` 与 `GET /api`，不带凭据）：
 *  - `GET /` **401** + dsh 固定指纹 ⇒ 确认"这里确实是 dsh"；
 *  - 再打 `GET /api`：**401 / 404** ⇒ 围栏已过（可用通道），判**连通**；
 *  - `GET /api` **403** ⇒ 围栏拦下（Host 不是回环形式）⇒ 判**失败**并给出可读原因；
 *  - `GET /api` **0** ⇒ 已连上 dsh 但 `/api` 无响应 ⇒ 判**失败**；
 *  - `GET /` **0**（连不上/超时）⇒ 判**失败**（带错误原文与可能原因）；
 *  - `GET /` **非 401**（例如 200）⇒ **不是 dsh** ⇒ 判**失败**（旧版此处曾判"已连接"，是假状态，已改）。
 *
 * 错误码可读化：扩展/VPN 层 `2203002` / `2097152` / `9568347` 的文案在 **`model/VpnErrors`**（本文件不再定义）。
 */

export interface DshConnResult {
  state: DshConnState;
  /** HTTP 状态码（0 = 没拿到任何响应）—— 证据要能落进界面 */
  httpCode: number;
  reason: string;
  detail: string;
  atMs: number;
  /**
   * 传输层 `BusinessError.code`（**可选**）：AC-21 判"离线 / 在线但 dsh 未起"的关键。
   * `2300007`=连接没被接受（⇒ **电脑在线、dsh 未起**）／`2300028`=超时、`2300006`=解析不了主机（⇒ **离线**）。
   * 依据：`references/js-apis-http.md:221/222/231`。
   */
  errCode?: number;
}

/**
 * 目标端口：**统一取 `model/EntryPorts.DSH_PORT`（全包唯一来源）**，本文件不再自持默认值。
 * ⚠️ 别在本文件或别处再写端口字面量 —— QC 在 #4 实测过"同包两套默认值 ⇒ 假的连接失败"。
 */

/**
 * 目标构造（**诊断/直连用**）：`address` 是**配置项**，`Host` 头**恒定回环形式**
 * （`127.0.0.1:<port>`，这是 `/api` 围栏的判据，不能被"配置"掉）。
 * 真机主流程走 `DshApiClient.pluginTarget()`（插件 插件端口 + `/pair/dsh`），**不用本函数**。
 */
export function connTarget(address: string, port: number): DshApiTarget {
  return {
    address: address,
    port: port,
    hostHeader: `127.0.0.1:${port}`,
    pathPrefix: '',
    tsTarget: '',
    viaKernelProxy: false
  };
}

/** 把探测结果转成状态机要的**原始观察**（判据只在这里）：`ok` = 确认是 dsh 且 /api 围栏已过 */
export function toProbeOutcome(result: DshConnResult): DshProbeOutcome {
  return {
    ok: result.state === DshConnState.CONNECTED,
    code: result.httpCode,
    reason: result.reason,
    detail: result.detail,
    atMs: result.atMs
  };
}

/**
 * 只读探测一次（`GET /` 指纹 → `GET /api` 围栏）。**默认目标 = 电脑回环（诊断用）**。
 * **只做只读判定**：不带凭据、不发会话、不改电脑侧任何东西。
 */
export async function probeConnection(port: number): Promise<DshConnResult> {
  return probeConnectionAt('127.0.0.1', port);
}

/** 同一次探测，目标地址可配（见 `connTarget` 的接缝说明） */
export async function probeConnectionAt(address: string, port: number): Promise<DshConnResult> {
  const client = new DshApiClient(connTarget(address, port));
  const root: DshApiResult = await client.fingerprint();
  if (root.code === 401) {
    const api: DshApiResult = await client.apiFenceProbe();
    if (api.code === 403) {
      return {
        state: DshConnState.FAILED,
        httpCode: api.code,
        reason: '围栏拦下：服务端看到的 Host 不是回环形式（403）⇒ 电脑侧入口须把 Host 写回 127.0.0.1:<dsh端口>',
        detail: `GET / = 401（dsh 指纹命中）｜GET /api = 403（Host 不受信）`,
        atMs: Date.now()
      };
    }
    if (api.code === 401) {
      return {
        state: DshConnState.CONNECTED,
        httpCode: api.code,
        reason: '已连通（确认是 dsh）：GET / = 401（dsh 指纹）且 GET /api = 401（围栏已过、缺凭据；凭据对用户不可见）',
        detail: `GET / = 401｜GET /api = 401（围栏放行）`,
        atMs: Date.now()
      };
    }
    if (api.code === 404) {
      return {
        state: DshConnState.CONNECTED,
        httpCode: api.code,
        reason: '已连通（是 dsh）：GET / = 401（指纹）且 GET /api = 404（围栏与鉴权均已通过，路由层）',
        detail: `GET / = 401｜GET /api = 404（${api.fenceVerdict}）`,
        atMs: Date.now()
      };
    }
    return {
      state: DshConnState.FAILED,
      httpCode: api.code,
      reason: `已连上电脑，但 dsh 的 /api 未按预期响应（HTTP ${api.code}：${api.fenceVerdict}）⇒ 判连接失败，不冒充「已连接」（没凭据时预期 401 或 404）`,
      detail: `GET / = 401（指纹命中）｜GET /api = ${api.code}｜耗时 ${api.elapsedMs} ms`,
      atMs: Date.now()
    };
  }
  if (root.code === 0) {
    return {
      state: DshConnState.FAILED,
      httpCode: 0,
      reason: `连不上电脑：目标 ${port} 端口无响应（可能原因：电脑侧 dsh 未起 / 端口不对 / 入口未就绪）`,
      detail: `目标 ${address}:${port}｜耗时 ${root.elapsedMs} ms｜错误原文：${root.error}`,
      atMs: Date.now(),
      // AC-21：把结构化错误码带出去（界面据此分"离线"与"在线但 dsh 未起"；0 = 没拿到结构化错误 ⇒ 判"未知"）
      errCode: root.errCode ?? 0
    };
  }
  return {
    state: DshConnState.FAILED,
    httpCode: root.code,
    reason: `有响应但不是 dsh：GET / 返回 ${root.code}（预期未认证的 dsh 返回 401 指纹）⇒ 判连接失败，不冒充「已连接」`,
    detail: root.body.length > 0 ? `响应片段：${root.body.substring(0, 120)}` : '(空响应体)',
    atMs: Date.now()
  };
}

/** VPN/扩展层的错误码 → 可读文案：**已移到 `model/VpnErrors`**（单一事实源，界面与入网状态机共用）。 */

/**
 * 一行日志用（**不是界面状态文案**）。
 * 界面四态文案一律取 `model/DshConnModel` 的 `connStateText` / `deriveConnView`。
 */
export function connLine(result: DshConnResult): string {
  const stateText: string = result.state === DshConnState.CONNECTING ? '连接中'
    : (result.state === DshConnState.CONNECTED ? '探测连通' : (result.state === DshConnState.FAILED ? '探测失败' : '未连接'));
  return `${formatClock(result.atMs)} ${stateText}（HTTP ${result.httpCode}）｜${result.reason}`;
}
