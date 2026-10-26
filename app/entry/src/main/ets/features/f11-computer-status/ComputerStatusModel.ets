/**
 * F10（AC-21 电脑在线状态 ＋ AC-15 可用 dsh 发现）的**纯逻辑**部分（零 Kit 依赖 ⇒ 本机可断言）。
 *
 * AC-21 通过条件（原文，一字不改）：① 离线（含**最后可见时间**）／② 在线但 dsh 未起／
 * ③ 在线且 dsh 可用／④ **未知·检测中**（**不得误报离线、不得沿用上次**）／
 * ⑤ **自动刷新 ≤30 秒 ＋ 手动刷新立即生效**／⑥ 失败/不可达**有可读提示**／⑦ **不得"假在线"**。
 *
 * AC-15 通过条件（原文）：① 数量与电脑侧实际一致；② 每条有**能对照出"是哪台电脑上的哪个 dsh"的标识**；
 * ③ 关掉/开回/退出再入网三组变化后能**跟随变化**；④ **不得列出电脑侧并不存在的 dsh**。
 * ⚠️ 本机等价（台账第 13 条）：**"退出 tailnet 再入网"与"区分是哪台电脑"本地无对应动作** ⇒ 只如实标，不假造。
 *
 * 本文件**只做派生**：输入全是**可观察事实**（探测结果、错误码、时刻），输出是四态与可读文案；
 * **判不了就判"未知"**，绝不用"上一次的结果"或"想让它是什么"凑答案。
 *
 * 设计上**不 import 任何服务**（连 `services/DshConnection` 也不 import）：
 * 由调用方把探测结果**映射成下面的 `ComputerProbeFact`** ⇒ 本文件**零依赖**、可在本机 node 上直接断言。
 */

/** 一次探测的**事实**（由服务层从 `DshConnResult` 映射过来；本文件不产生它） */
export interface ComputerProbeFact {
  /** true = 拿到"这里确实是 dsh、且 /api 围栏已过"的证据 */
  dshOk: boolean;
  /** HTTP 状态码（0 = 没拿到任何响应） */
  httpCode: number;
  /** 传输层 `BusinessError.code`（0 = 无结构化错误） */
  errCode: number;
  /** 人读原因 */
  reason: string;
  /** 判据原文（证据） */
  detail: string;
  atMs: number;
}

/** AC-21 的四态（**与 F3「连接四态」是两个视角**，别混用代号） */
export enum ComputerStatus {
  UnknownChecking = 0,
  Offline = 1,
  OnlineNoDsh = 2,
  OnlineDshOk = 3
}

export const COMPUTER_STATUS_TEXT: string[] = [
  '未知·检测中', '离线', '在线（dsh 未起）', '在线（dsh 可用）'
];
export const COMPUTER_STATUS_COLOR: string[] = ['#b26a00', '#5b6470', '#b26a00', '#1a7f37'];

/** AC-21⑤：自动刷新间隔**上限**（必须 ≤30 秒） */
export const COMPUTER_AUTO_REFRESH_MS: number = 30000;
/** AC-21④：单次检测的看门狗（超过它仍无结果 ⇒ 回"未知"，**不把上次结果顶上来**） */
export const COMPUTER_CHECK_WATCHDOG_MS: number = 20000;

/** HarmonyOS http 错误码（依据 `references/js-apis-http.md:221/222/231`） */
export const HTTP_ERR_RESOLVE: number = 2300006;   // Failed to resolve the host name ⇒ 离线
export const HTTP_ERR_CONNECT: number = 2300007;   // Failed to connect to the server ⇒ **连接没被接受**（在线但端口没开）
export const HTTP_ERR_TIMEOUT: number = 2300028;   // Operation timeout ⇒ 离线

/** 一次检测的**可观察事实**（`checking` 为真时，下面那些字段**一概不看** ⇒ 不可能"沿用上次"） */
export interface ComputerObservation {
  /** 检测请求正在飞 */
  checking: boolean;
  /** 本次检测的发出时刻（0 = 没有在飞的检测） */
  checkStartedAtMs: number;
  /** 本次探测结果（`undefined` = 本次还没结果；**不是**用上一次的） */
  last: ComputerProbeFact | undefined;
  /** 最近一次**观察到电脑在线**的时刻（0 = 从未） */
  lastOnlineAtMs: number;
  nowMs: number;
}

export interface ComputerStatusView {
  status: number;
  text: string;
  color: string;
  /** 最后可见时间文案（④/① 都要能读到） */
  lastSeenText: string;
  /** 判据原文（证据；不许空话） */
  evidence: string;
}

/** 最后可见时间（AC-21①） */
export function lastSeenText(lastOnlineAtMs: number, nowMs: number): string {
  if (lastOnlineAtMs <= 0) {
    return '最后可见：从未（本机本轮未观察到）';
  }
  const sec: number = Math.max(0, Math.floor((nowMs - lastOnlineAtMs) / 1000));
  if (sec < 60) {
    return `最后可见：${sec} 秒前`;
  }
  if (sec < 3600) {
    return `最后可见：${Math.floor(sec / 60)} 分钟前`;
  }
  return `最后可见：${Math.floor(sec / 3600)} 小时前`;
}

/**
 * AC-21 四态派生。**判读顺序写死**（每条都有出处/理由）：
 *  ① `checking` ⇒ **未知·检测中**（不看任何旧结果 ⇒ 满足"不得沿用上次"；也**不判离线** ⇒ 满足"不得误报离线"）
 *  ② 拿到 dsh 指纹且 /api 围栏已过 ⇒ **在线且 dsh 可用**
 *  ③ 有 HTTP 响应但不是 dsh ⇒ **在线（dsh 未起）**（主机确实在应答，只是那个端口上不是可用的 dsh）
 *  ④ 无响应 ＋ `errCode = 2300007`（连接没被接受）⇒ **在线（dsh 未起）**
 *  ⑤ 无响应 ＋ `errCode ∈ {2300028 超时, 2300006 解析不了主机}` ⇒ **离线**（含最后可见时间）
 *  ⑥ 其余（无响应但没有可判读的结构化错误码）⇒ **未知**（可读原因照给）—— **不许硬塞成"离线"**
 */
export function deriveComputerStatus(obs: ComputerObservation): ComputerStatusView {
  const seen: string = lastSeenText(obs.lastOnlineAtMs, obs.nowMs);
  if (obs.checking) {
    const flying: number = obs.checkStartedAtMs > 0 ? Math.max(0, obs.nowMs - obs.checkStartedAtMs) : 0;
    const watchdog: string = flying > COMPUTER_CHECK_WATCHDOG_MS
      ? `｜⚠️ 已超过看门狗 ${COMPUTER_CHECK_WATCHDOG_MS}ms，仍按"未知·检测中"显示（不沿用上次结果）`
      : `（已 ${flying}ms，看门狗 ${COMPUTER_CHECK_WATCHDOG_MS}ms）`;
    return {
      status: ComputerStatus.UnknownChecking, text: COMPUTER_STATUS_TEXT[0], color: COMPUTER_STATUS_COLOR[0],
      lastSeenText: seen, evidence: `检测中，尚无结果${watchdog}｜${seen}`
    };
  }
  const last: ComputerProbeFact | undefined = obs.last;
  if (last === undefined) {
    return {
      status: ComputerStatus.UnknownChecking, text: COMPUTER_STATUS_TEXT[0], color: COMPUTER_STATUS_COLOR[0],
      lastSeenText: seen, evidence: `本次没有探测结果（也没在检测中）⇒ 判"未知"，不猜、不沿用｜${seen}`
    };
  }
  if (last.dshOk) {
    return {
      status: ComputerStatus.OnlineDshOk, text: COMPUTER_STATUS_TEXT[3], color: COMPUTER_STATUS_COLOR[3],
      lastSeenText: seen, evidence: `dsh 可用（HTTP ${last.httpCode}）｜${last.detail}`
    };
  }
  const err: number = last.errCode;
  if (last.httpCode > 0) {
    return {
      status: ComputerStatus.OnlineNoDsh, text: COMPUTER_STATUS_TEXT[2], color: COMPUTER_STATUS_COLOR[2],
      lastSeenText: seen,
      evidence: `电脑在应答，但该端口不是可用的 dsh（HTTP ${last.httpCode}）｜${last.reason}`
    };
  }
  if (err === HTTP_ERR_CONNECT) {
    return {
      status: ComputerStatus.OnlineNoDsh, text: COMPUTER_STATUS_TEXT[2], color: COMPUTER_STATUS_COLOR[2],
      lastSeenText: seen,
      evidence: `连接没被接受（http ${err}：${last.detail}）⇒ 判"在线但 dsh 未起"｜${seen}`
    };
  }
  if (err === HTTP_ERR_TIMEOUT || err === HTTP_ERR_RESOLVE) {
    return {
      status: ComputerStatus.Offline, text: COMPUTER_STATUS_TEXT[1], color: COMPUTER_STATUS_COLOR[1],
      lastSeenText: seen,
      evidence: `${err === HTTP_ERR_TIMEOUT ? '超时无响应' : '主机名解析不了'}（http ${err}：${last.detail}）⇒ 判离线｜${seen}`
    };
  }
  return {
    status: ComputerStatus.UnknownChecking, text: COMPUTER_STATUS_TEXT[0], color: COMPUTER_STATUS_COLOR[0],
    lastSeenText: seen,
    evidence: `无响应且没有可判读的结构化错误码（errCode=${err}）⇒ 判"未知"，不硬塞成离线｜${last.reason}｜${seen}`
  };
}

/** AC-21⑤：自动刷新是否到期（间隔**必须 ≤30 秒**） */
export function autoRefreshDue(lastCheckAtMs: number, nowMs: number): boolean {
  if (lastCheckAtMs <= 0) {
    return true;
  }
  return nowMs - lastCheckAtMs >= COMPUTER_AUTO_REFRESH_MS;
}

/** 距下次自动刷新还有多久（0 = 现在就该刷） */
export function nextRefreshInMs(lastCheckAtMs: number, nowMs: number): number {
  if (lastCheckAtMs <= 0) {
    return 0;
  }
  return Math.max(0, COMPUTER_AUTO_REFRESH_MS - (nowMs - lastCheckAtMs));
}


// ── AC-15：候选清单与行 ────────────────────────────────────────────────────

export interface DshCandidate {
  address: string;
  port: number;
}


/**
 * AC-15② 的**可区分标识**。
 * ⚠️ 本机等价下只能用 `地址:端口`（**"是哪台电脑"本地无对应动作** —— 台账第 13 条）⇒ 不假造主机名/机器码。
 */
export function candidateId(c: DshCandidate): string {
  return `${c.address}:${c.port}`;
}


export interface DshRow {
  /** = `candidateId`（界面上的"哪一台"） */
  id: string;
  address: string;
  port: number;
  /** 该候选**是否应答**（false ⇒ 这一条**不许**当成"存在的 dsh"列出） */
  reachable: boolean;
  /** 是否确认为可用的 dsh（拿到 dsh 指纹且围栏已过） */
  dshOk: boolean;
  note: string;
}

/** AC-15④：**只保留有应答的行**（没应答的 = 电脑侧并不存在/没起 ⇒ 不得列进去） */
export function onlyResponded(rows: DshRow[]): DshRow[] {
  const out: DshRow[] = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].reachable) {
      out.push(rows[i]);
    }
  }
  return out;
}



