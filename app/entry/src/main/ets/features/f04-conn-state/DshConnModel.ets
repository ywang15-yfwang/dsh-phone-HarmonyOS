/**
 * F3「连接状态可见」的四态模型（《需求文档》v10 §3 第 3 条）。
 *
 * **本文件是四态的唯一事实源**：取值、文案、颜色、判据（纯函数）都在这里。
 * **无任何 Kit / ArkUI 依赖** ⇒ 可以在本机（宿主 node）直接跑，自查不需要设备。
 *
 * 三条防「假状态」硬口径（客户令 + 卡面「不得停在不真实的状态」）：
 *  ① **「已连接」只能由"最近一次探测成功且仍在心跳窗口内"支撑** —— 成功探测是唯一正证据；
 *  ② **「连接中」只在探测真的在飞的时候出现**（不为"没探测"装忙）；
 *  ③ **异常中断（探测失败 / 心跳超时）一律进「连接失败」并带可读原因**，绝不沿用「已连接」；
 *     **「已断开」只由"用户从未连过 / 用户主动断开"产生**（不由失败产生）。
 */

/** 四态取值（顺序即展示顺序，不要重排） */
export enum DshConnState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  FAILED = 3
}

/** 四态文案（单一事实源；界面与《交付文案清单》都取这里） */
export const CONN_STATE_TEXT: string[] = ['已断开', '连接中', '已连接', '连接失败'];

/** 四态颜色（灰 / 橙 / 绿 / 红）—— 与入网四态同一套语义色 */
export const CONN_STATE_COLOR: string[] = ['#5b6470', '#b26a00', '#1a7f37', '#b3261e'];

/** 状态条底色（浅色，保证文字对比度） */
export const CONN_BAR_BG: string[] = ['#EDEFF2', '#FBF1E0', '#EAF5EC', '#FDEBEA'];

/** 心跳窗口：最近一次成功探测超过它 ⇒ **不得**再显示「已连接」（判异常断开） */
export const CONN_FRESH_MS: number = 30000;

/** 前台自动重探周期：**必须 < 心跳窗口**，否则"已连接"会自己过期成假状态 */
export const CONN_REPROBE_MS: number = 15000;

/** 探测超时（与 `DshApiClient.send()` 的 connectTimeout / readTimeout 同源，仅用于文案自述） */
export const CONN_CONNECT_TIMEOUT_MS: number = 8000;
export const CONN_READ_TIMEOUT_MS: number = 15000;

/**
 * 探测**看门狗**：探测发出后超过它仍未返回 ⇒ 判「连接失败」并给可读原因。
 * 为什么必须有：`probing` 期间状态恒为「连接中」⇒ 若某次探测的 Promise 永不 settle
 * （本项目实测过这种平台行为：`startVpnExtensionAbility` 失败时 Promise 不 settle），
 * 界面就会**永远停在「连接中」= 装忙**。看门狗是这条路的兜底。
 */
export const CONN_PROBE_WATCHDOG_MS: number = 30000;

export function connStateText(state: number): string {
  return CONN_STATE_TEXT[state];
}

export function connStateColor(state: number): string {
  return CONN_STATE_COLOR[state];
}

export function connBarBg(state: number): string {
  return CONN_BAR_BG[state];
}

/**
 * 一次探测的**原始观察**（由 `services/DshConnection` 里的真探测产出）。
 * 本文件**只消费**它，不产生它 —— 状态不能自造。
 */
export interface DshProbeOutcome {
  /** true = 拿到"这里确实是 dsh、且 /api 围栏已过"的证据 */
  ok: boolean;
  /** HTTP 状态码（0 = 没拿到任何响应） */
  code: number;
  /** 人读原因（探测层给出的可读文案） */
  reason: string;
  /** 判据原文（证据；不许空话） */
  detail: string;
  /** 探测完成时刻（本机毫秒） */
  atMs: number;
}

/** 状态机的输入（全部来自可观察事实，不含"想让它是什么"） */
export interface DshConnObservation {
  /** 探测请求正在飞 */
  probing: boolean;
  /** 用户按过「主动断开」，且还没按「连接电脑」 */
  userDisconnected: boolean;
  /** 最近一次探测结果（`undefined` = 从未探测过） */
  last: DshProbeOutcome | undefined;
  /** 最近一次**成功**探测的时刻（0 = 从未成功） */
  lastOkAtMs: number;
  /** 本次探测的**发出时刻**（0 = 没有在飞的探测）—— 看门狗兜底用 */
  probeStartedAtMs: number;
  /**
   * 入网（VPN 扩展）层**已可读**的失败原文（'' = 无）。
   * 只并入**失败**路径，用来回答"为什么连不上"；不改四态结构、不新增状态。
   */
  vpnLayerError: string;
  nowMs: number;
}

/** 状态机的输出（界面只读这个） */
export interface DshConnView {
  state: number;
  text: string;
  /** 「一眼能看到」的短句：状态 + 一句依据摘要（顶部状态条用） */
  short: string;
  /** 判据/依据（可读，含证据与时刻；界面详情行用） */
  reason: string;
  /** 距最近一次成功探测的毫秒数（-1 = 从未成功） */
  sinceOkMs: number;
}

/** 时长的人读形态（只用于文案，避免与 `VpnTypes.formatAge` 的"xx 前"后缀重复） */
export function agoText(ms: number): string {
  if (ms < 0) {
    return '从未成功';
  }
  const sec: number = Math.floor(ms / 1000);
  if (sec < 60) {
    return `${sec} 秒`;
  }
  const min: number = Math.floor(sec / 60);
  if (min < 60) {
    return `${min} 分钟`;
  }
  const hour: number = Math.floor(min / 60);
  if (hour < 24) {
    return `${hour} 小时`;
  }
  return `${Math.floor(hour / 24)} 天`;
}

/** 入网层可读失败并入**失败**文案（无则空串；不改四态结构、不新增状态） */
function vpnClause(vpnLayerError: string): string {
  return vpnLayerError.length > 0 ? `｜入网层也报错：${vpnLayerError}` : '';
}

/**
 * 四态判定（**纯函数**，无副作用）。
 *
 * 判定顺序（顺序本身就是口径，别改）：
 *  ① 用户主动断开 ⇒ 已断开（用户意志优先于一切自动判定）
 *  ② 探测在飞：超过看门狗仍未返回 ⇒ **连接失败**（兜底，防"永远连接中"= 装忙）；否则 ⇒ 连接中
 *  ③ 从未探测过 ⇒ 已断开（如实说"没连过"，不冒充连接中/连接失败）
 *  ④ 有探测结果：
 *     - 失败：曾成功过 ⇒ 连接失败（异常断开）；从未成功 ⇒ 连接失败
 *     - 成功：在心跳窗口内 ⇒ 已连接；超出窗口 ⇒ 连接失败（异常断开，心跳超时）
 *  所有**失败**分支末尾都会并入「入网层也报错：…」（若入网层有可读错误）—— 回答"为什么连不上"。
 */
export function deriveConnView(obs: DshConnObservation): DshConnView {
  const sinceOkMs: number = obs.lastOkAtMs > 0 ? obs.nowMs - obs.lastOkAtMs : -1;
  const vpnTail: string = vpnClause(obs.vpnLayerError);

  if (obs.userDisconnected) {
    return {
      state: DshConnState.DISCONNECTED,
      text: connStateText(DshConnState.DISCONNECTED),
      short: '已断开 · 你已主动断开（不再自动重连）',
      reason: '你已主动断开：手机停止向电脑发起探测、也不会自动重连（点「连接电脑」可重连）。' +
        '注意：断开只发生在手机侧，未在电脑侧引发任何动作。',
      sinceOkMs: sinceOkMs
    };
  }

  if (obs.probing) {
    const elapsedMs: number = obs.probeStartedAtMs > 0 ? obs.nowMs - obs.probeStartedAtMs : 0;
    if (obs.probeStartedAtMs > 0 && elapsedMs > CONN_PROBE_WATCHDOG_MS) {
      return {
        state: DshConnState.FAILED,
        text: connStateText(DshConnState.FAILED),
        short: `连接失败 · 探测超时（看门狗 ${Math.floor(CONN_PROBE_WATCHDOG_MS / 1000)}s 未返回）`,
        reason: `连接失败：探测已发出 ${Math.floor(elapsedMs / 1000)}s 仍未返回，` +
          `超过看门狗 ${Math.floor(CONN_PROBE_WATCHDOG_MS / 1000)}s ⇒ 判连接失败，` +
          `不停留在「连接中」（不装忙；点「立即重探」可马上复核）${vpnTail}`,
        sinceOkMs: sinceOkMs
      };
    }
    return {
      state: DshConnState.CONNECTING,
      text: connStateText(DshConnState.CONNECTING),
      short: '连接中 · 探测已发出，等待电脑上的 dsh 响应',
      reason: `正在连接：已向电脑发出只读探测，等待电脑上的 dsh 响应` +
        `（连接超时 ${Math.floor(CONN_CONNECT_TIMEOUT_MS / 1000)}s / 读取超时 ${Math.floor(CONN_READ_TIMEOUT_MS / 1000)}s，` +
        `看门狗 ${Math.floor(CONN_PROBE_WATCHDOG_MS / 1000)}s 未返回即判失败）。` +
        `本状态只在探测真的在飞时出现，不是"装忙"。`,
      sinceOkMs: sinceOkMs
    };
  }

  const last: DshProbeOutcome | undefined = obs.last;
  if (last === undefined) {
    return {
      state: DshConnState.DISCONNECTED,
      text: connStateText(DshConnState.DISCONNECTED),
      short: '已断开 · 尚未发起连接',
      reason: '尚未发起连接：点「连接电脑」开始。本状态如实显示"没连过"，不冒充「连接中」或「连接失败」。',
      sinceOkMs: sinceOkMs
    };
  }

  if (!last.ok) {
    if (obs.lastOkAtMs > 0) {
      return {
        state: DshConnState.FAILED,
        text: connStateText(DshConnState.FAILED),
        short: '连接失败 · 连接已中断（异常断开）',
        reason: `连接已中断（异常断开）：最近一次成功探测在 ${agoText(sinceOkMs)}前，` +
          `本次复探失败 ⇒ ${last.reason}｜证据 ${last.detail}${vpnTail}`,
        sinceOkMs: sinceOkMs
      };
    }
    return {
      state: DshConnState.FAILED,
      text: connStateText(DshConnState.FAILED),
      short: `连接失败 · ${last.reason}`,
      reason: `连接失败：${last.reason}｜证据 ${last.detail}${vpnTail}`,
      sinceOkMs: sinceOkMs
    };
  }

  if (sinceOkMs >= 0 && sinceOkMs <= CONN_FRESH_MS) {
    return {
      state: DshConnState.CONNECTED,
      text: connStateText(DshConnState.CONNECTED),
      short: `已连接 · ${agoText(sinceOkMs)}前探测成功（心跳窗口 ${Math.floor(CONN_FRESH_MS / 1000)}s）`,
      reason: `已连接：${last.reason}｜证据 ${last.detail}｜最近成功 ${agoText(sinceOkMs)}前` +
        `（心跳窗口 ${Math.floor(CONN_FRESH_MS / 1000)}s，每 ${Math.floor(CONN_REPROBE_MS / 1000)}s 自动重探）`,
      sinceOkMs: sinceOkMs
    };
  }

  return {
    state: DshConnState.FAILED,
    text: connStateText(DshConnState.FAILED),
    short: '连接失败 · 连接已中断（心跳超时）',
    reason: `连接已中断（异常断开）：最近一次成功探测在 ${agoText(sinceOkMs)}前，` +
      `已超过心跳窗口 ${Math.floor(CONN_FRESH_MS / 1000)}s 且未取到新的成功证据 ⇒ 判为已中断，` +
      `不沿用「已连接」（点「立即重探」可马上复核）${vpnTail}`,
    sinceOkMs: sinceOkMs
  };
}

/** 初值（界面 @State 用）：等于"从未探测过"的判定结果，不另写一套文案 */
export function initialConnView(): DshConnView {
  const obs: DshConnObservation = {
    probing: false,
    userDisconnected: false,
    last: undefined,
    lastOkAtMs: 0,
    probeStartedAtMs: 0,
    vpnLayerError: '',
    nowMs: 0
  };
  return deriveConnView(obs);
}

