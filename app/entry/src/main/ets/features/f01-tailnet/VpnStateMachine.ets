import { PhaseResult, VpnExtensionStatus, VpnPhase } from '../../model/VpnTypes';
import { readableVpnError } from '../../model/VpnErrors';

/**
 * 超时与重试参数（T2 实测依据：startVpnExtensionAbility 失败时 Promise 不 settle，
 * 故一切系统调用都必须有超时，且最终以"状态回读"判定真实结果）。
 */
export const START_TIMEOUT_MS: number = 15000;
export const CREATE_TIMEOUT_MS: number = 15000;
export const STOP_TIMEOUT_MS: number = 10000;
/** 持续 `StatusUnavailable` 的降级上限（≥3 次 或 ≥15s ⇒ 降级为"检测中"） */
export const STATUS_UNAVAILABLE_CAP_MS: number = 15000;
export const STATUS_UNAVAILABLE_CAP_COUNT: number = 3;

/** 扩展阶段取值（由内核状态串映射而来，契约 §4.1） */
export const EXT_PHASE_RUNNING: string = 'running';
export const EXT_PHASE_STARTING: string = 'starting';
export const EXT_PHASE_NEED_LOGIN: string = 'need-login';
export const EXT_PHASE_NEED_MACHINE_AUTH: string = 'need-machine-auth';
export const EXT_PHASE_STOPPED: string = 'stopped';
export const EXT_PHASE_FAILED: string = 'failed';

/**
 * 内核 `backendState` → 扩展阶段（固定映射，A1；照 client-core 订正表）：
 *  NeedsLogin / NoState → need-login；Running + 地址非空 → running；StartFailed → failed …
 *  **这条映射是把 AC-14① "登录失效" 与 "未启动" 分开的关键。**
 */
export function phaseFromBackendState(backendState: string, address: string): string {
  if (backendState === 'NeedsLogin' || backendState === 'NoState') {
    return EXT_PHASE_NEED_LOGIN;
  }
  if (backendState === 'NeedsMachineAuth') {
    return EXT_PHASE_NEED_MACHINE_AUTH;
  }
  if (backendState === 'Stopped') {
    return EXT_PHASE_STOPPED;
  }
  if (backendState === 'Running') {
    return address.length > 0 ? EXT_PHASE_RUNNING : EXT_PHASE_STARTING;
  }
  if (backendState === 'Starting' || backendState === 'Initialized') {
    return EXT_PHASE_STARTING;
  }
  if (backendState === 'StartFailed') {
    return EXT_PHASE_FAILED;
  }
  // `StatusUnavailable` = **这一次状态查询失败**（2s 超时的占位值），后端可能仍在跑
  // ⇒ 绝不能当"启动失败"（那是 AC-14② 反方向的假状态）；映射到 starting 由调用方保留上一次判定
  if (backendState === 'StatusUnavailable') {
    return EXT_PHASE_STARTING;
  }
  return EXT_PHASE_STARTING;
}

export interface PhaseInput {
  status: VpnExtensionStatus | undefined;
  nowMs: number;
  startRequestedAtMs: number;
  startSettled: boolean;
  stopping: boolean;
  exitedByUser: boolean;
  /** 上一次判定（用于 `StatusUnavailable` 时保留上一次状态，避免"假失败"） */
  previousPhase: number;
}

/**
 * 四态状态机（纯函数）。
 * 判据（不采信单一状态字）：**心跳新鲜 + 内核 `backendState` + 地址非空 + 超时兜底**。
 * 已入网 = `Running` + 地址非空 + 心跳新鲜；缺任一条即降级并给出可读原因（不放假状态）。
 * 注意：**"已入网但目标不可达"不在这里判** —— 它在 UI 侧探活（30s）里做**附加标注**，不是第五态。
 */
export function derivePhase(input: PhaseInput): PhaseResult {
  const status: VpnExtensionStatus | undefined = input.status;
  const nowMs: number = input.nowMs;
  // 客户 2026-10-18：**不再靠心跳判活**。空闲时没有"要不要知道连接状态"的问题 ——
  // 扩展不再周期写心跳；有状态文件就当最后一次已知状态，断没断由下一次操作自己发现。
  const alive: boolean = status !== undefined;

  if (input.exitedByUser) {
    if (status === undefined || status.backendState === 'Stopped' || status.phase === EXT_PHASE_STOPPED) {
      return { phase: VpnPhase.DISCONNECTED, reason: '用户主动退出：扩展已停止 / 内核 Stopped（已确认）' };
    }
    return { phase: VpnPhase.CONNECTING, reason: '正在断开：已发出 backendStop，等待内核确认 Stopped' };
  }

  if (input.stopping) {
    return { phase: VpnPhase.CONNECTING, reason: '正在断开：已发出停止请求，等待扩展/内核确认' };
  }

  if (status !== undefined && alive) {
    const backendState: string = status.backendState;
    const address: string = status.address;
    const kernelError: string = status.kernelError;

    if (backendState === 'Running') {
      if (address.length > 0) {
        return {
          phase: VpnPhase.ONBOARDED,
          reason: `内核 Running + 本机地址 ${address} + 心跳新鲜（目标可达性另在电脑状态卡标注）`
        };
      }
      return { phase: VpnPhase.CONNECTING, reason: '内核已 Running，但尚未取到本机 tailnet 地址' };
    }
    if (backendState === 'NeedsLogin' || backendState === 'NoState') {
      const extra: string = status.authUrlReady ? '（授权 URL 已就绪，待浏览器完成授权）' : '';
      return {
        phase: VpnPhase.NOT_ONBOARDED,
        reason: `内核 ${backendState}：未入网 / 登录失效${extra}`
      };
    }
    if (backendState === 'NeedsMachineAuth') {
      return { phase: VpnPhase.NOT_ONBOARDED, reason: '需要管理员在 Tailscale 管理台批准这台设备（NeedsMachineAuth）' };
    }
    if (backendState === 'Starting' || backendState === 'Initialized') {
      return { phase: VpnPhase.CONNECTING, reason: `内核 ${backendState}：正在启动${status.authUrlReady ? '，授权 URL 已就绪' : ''}` };
    }
    if (backendState === 'StartFailed') {
      const tail: string = kernelError.length > 0 ? `｜内核原文：${kernelError}` : '';
      return { phase: VpnPhase.NOT_ONBOARDED, reason: `内核 StartFailed（phase=${status.phase}）${tail}` };
    }
    if (backendState === 'StatusUnavailable') {
      // AC-14② 的反方向：**临时查询失败不得翻转成 failed**；
      // 但**也不得无上限沿用上一次状态** —— 持续失败（≥3 次 或 ≥15s）必须降级为"检测中"
      const streak: number = status.statusUnavailableStreak > 0 ? status.statusUnavailableStreak : 0;
      const since: number = status.statusUnavailableSinceMs > 0 ? status.statusUnavailableSinceMs : 0;
      const sustainedMs: number = since > 0 ? nowMs - since : 0;
      const sustained: boolean = streak >= 3 || sustainedMs >= STATUS_UNAVAILABLE_CAP_MS;
      const raw: string = kernelError.length > 0 ? kernelError : '(空)';
      if (sustained) {
        return {
          phase: VpnPhase.CONNECTING,
          reason: `内核状态查询持续失败（连续 ${streak} 次 / ${Math.floor(sustainedMs / 1000)}s）` +
            `⇒ 降级为"检测中"，不沿用"已入网"；原文：${raw}`
        };
      }
      const prev: VpnPhase = input.previousPhase as VpnPhase;
      return {
        phase: prev,
        reason: `内核状态查询本次失败（StatusUnavailable，2s 超时的占位值，第 ${streak} 次）` +
          `⇒ 保留上一次判定、不翻转；原文：${raw}`
      };
    }
    if (backendState === 'Stopped') {
      return { phase: VpnPhase.NOT_ONBOARDED, reason: '内核 Stopped（非用户退出）' };
    }
    // **QC 实测风险点（2097152 = VPN 扩展起不来）：必须兜底成"可读失败"，不许落到"连接中"装忙。**
    // 旧版直接落到下面那行 ⇒ 界面显示「登录中」+ "内核状态未识别"（≥15s 无可读提示、调用状态仍显示"空闲"）。
    // 位置刻意放在**所有已知 backendState 分支之后**：errorCode 是扩展上一次 publish 留下的值，
    // 放在前面会把"当前确实 Running"也压成失败（陈旧码不得压过健康态）。
    if (status.phase === EXT_PHASE_FAILED || status.errorCode !== 0) {
      const vpnErr: string = status.errorCode !== 0
        ? readableVpnError(status.errorCode)
        : '扩展自报 failed 但未带错误码';
      const kernelTail: string = kernelError.length > 0 ? `｜内核原文：${kernelError}` : '';
      const detailTail: string = status.detail.length > 0 ? `｜扩展 detail：${status.detail}` : '';
      return {
        phase: VpnPhase.NOT_ONBOARDED,
        reason: `入网层失败（扩展 phase=${status.phase}）：${vpnErr}${kernelTail}${detailTail}` +
          ` ⇒ 判「未入网」，不显示「登录中」（不装忙）`
      };
    }
    return { phase: VpnPhase.CONNECTING, reason: `内核状态未识别：${backendState}（扩展 phase=${status.phase}）` };
  }

  // （旧的"心跳超时 ⇒ 判掉线"分支已删除：空闲不探测连接状态）

  if (input.startRequestedAtMs > 0 && !input.startSettled) {
    const elapsed: number = nowMs - input.startRequestedAtMs;
    if (elapsed > START_TIMEOUT_MS) {
      return {
        phase: VpnPhase.NOT_ONBOARDED,
        reason: `启动超时 ${Math.floor(START_TIMEOUT_MS / 1000)}s：Promise 未 settle（T2 实测行为）` +
          `＋状态回读=无扩展状态 ⇒ 判"未启动"`
      };
    }
    return {
      phase: VpnPhase.CONNECTING,
      reason: `启动请求已发出 ${Math.floor(elapsed / 1000)}s，等待结果（超时 ${Math.floor(START_TIMEOUT_MS / 1000)}s）`
    };
  }

  return { phase: VpnPhase.NOT_ONBOARDED, reason: '无扩展状态文件 ⇒ 未启动 / 未入网' };
}
