/** T4a 公共类型与纯函数（无状态、可单测） */

/** 入网四态（AC-14 口径） */
export enum VpnPhase {
  NOT_ONBOARDED = 0,
  CONNECTING = 1,
  ONBOARDED = 2,
  DISCONNECTED = 3
}

/**
 * 目标电脑在线状态（F15 / AC-21 的口径）。
 *
 * ⚠️ `UNREACHABLE`（看不到）是**本机路径下必需的一档**：访问"宿主上没监听的端口"时
 * 给的是**超时**（`2300028`）而不是**连接被拒**（`2300007`）⇒ **"电脑没开"与"电脑开着但 dsh 没起"区分不了**。
 * 因此**不许**把超时直接写成"离线"（那会把"你只是关了 dsh"误报成"电脑不在线"）；如实写"看不到"。
 */
export enum TargetHostState {
  UNKNOWN = 0,
  OFFLINE = 1,
  ONLINE_DSH_DOWN = 2,
  ONLINE_DSH_READY = 3,
  /** 看不到（本机路径下"电脑没开"与"dsh 没起"不可区分；**不武断判离线**） */
  UNREACHABLE = 4
}

/** VPN 扩展写进沙箱的状态文件内容（扩展进程 → UI 进程的唯一事实源） */
/** 扩展状态文件内容（契约 §4.1，字段名以 client-core 订正版为准） */
export interface VpnExtensionStatus {
  /** 单调递增；读方只接受比上次大的（A3） */
  seq: number;
  /** 写入时刻（本机毫秒）—— 订正：就是 `updatedAtMs`，不再叫 writtenAtMs */
  updatedAtMs: number;
  /** 心跳时刻（UI 侧 >15s 无更新判掉线） */
  heartbeatAtMs: number;
  /** 扩展自己的阶段：creating-tun / kernel-starting / running / stopped / failed */
  phase: string;
  /** 本机 tailnet 地址（= backendStatus().tailscaleIps[0]） */
  address: string;
  /** 内核原始状态串（NeedsLogin / Starting / Running / …），**不改写成 UI 自己的词**（A1） */
  backendState: string;
  /** 是否已有授权 URL（A1） */
  authUrlReady: boolean;
  /** 授权 URL（URL 在扩展进程里产生，UI 进程拿不到内核 ⇒ 只能经文件传） */
  authUrl: string;
  /** 系统/VPN 层错误码（number：2203002 / 2097152 / 9568347 …），订正：不是字符串 */
  errorCode: number;
  /** 人读说明（actionResult.message 等） */
  detail: string;
  /** 内核失败原文（backendStatus().error / lastLog）（A1） */
  kernelError: string;
  /** `StatusUnavailable` 连续出现次数（用于"持续失败 ⇒ 降级为检测中"的上限判据） */
  statusUnavailableStreak: number;
  /** 本轮 `StatusUnavailable` 的起始时刻（0 = 本 tick 之前没有连续失败） */
  statusUnavailableSinceMs: number;
  /** backendStatus() 整个 JSON 原样放进来（诊断用） */
  kernelJson: string;
  /**
   * F15：**peer 段**（内核在扩展进程 ⇒ 只有扩展采得到；UI 从文件读）。
   * 采集前置：**`backendState === 'Running'`** —— `peers()` 在"内核没起"与"没入网"时都给 `[]`，
   * 不判这个前置就会把"未入网"误判成"电脑离线"（AC-14② 禁止的假状态）。
   * 空字符串 = 本 tick 没采（例如未 Running）。
   */
  peersJson?: string;
  /** F15：peer 段的采集时刻（本机毫秒；0 = 未采）。 */
  peersAtMs?: number;
}

/** 状态机输出 */
export interface PhaseResult {
  phase: VpnPhase;
  reason: string;
}

export interface TargetHostSnapshot {
  state: TargetHostState;
  peerName: string;
  tailnetAddress: string;
  lastSeenAtMs: number;
  probeNote: string;
}

const PHASE_TEXT: string[] = ['未入网 / 登录失效', '登录中', '已入网', '主动退出 / 已断开'];
const TARGET_TEXT: string[] = ['未知（检测中）', '离线', '电脑在线，但 dsh 未起', '在线且 dsh 可用', '看不到（电脑没开，或 dsh 没起）'];

export function phaseText(phase: number): string {
  return PHASE_TEXT[phase];
}

export function targetStateText(state: number): string {
  return TARGET_TEXT[state];
}

/** 秒级年龄文本（用于"最后可见 xx 前"） */
export function formatAge(nowMs: number, thenMs: number): string {
  if (thenMs <= 0) {
    return '无记录';
  }
  const diffSec: number = Math.max(0, Math.floor((nowMs - thenMs) / 1000));
  if (diffSec < 60) {
    return `${diffSec} 秒前`;
  }
  const diffMin: number = Math.floor(diffSec / 60);
  if (diffMin < 60) {
    return `${diffMin} 分钟前`;
  }
  const diffHour: number = Math.floor(diffMin / 60);
  if (diffHour < 24) {
    return `${diffHour} 小时前`;
  }
  return `${Math.floor(diffHour / 24)} 天前`;
}

export function formatClock(ms: number): string {
  if (ms <= 0) {
    return '—';
  }
  const d = new Date(ms);
  const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  const ss: string = d.getSeconds() < 10 ? `0${d.getSeconds()}` : `${d.getSeconds()}`;
  return `${hh}:${mm}:${ss}`;
}

