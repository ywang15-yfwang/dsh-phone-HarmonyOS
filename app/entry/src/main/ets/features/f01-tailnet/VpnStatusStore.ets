import { fileIo } from '@kit.CoreFileKit';
import { VpnExtensionStatus } from '../../model/VpnTypes';
import { VpnCommand, readResponse, readTextSafe, writeCommand, writeTextAtomic } from './VpnChannel';
import { EVENT_VPN_COMMAND, EVENT_VPN_STATUS, publishEvent } from './VpnBus';

/** 扩展状态文件（VPN 扩展进程写，UI 进程读）—— 状态回读的唯一事实源（契约 §4.1） */
export const EXT_STATUS_FILE: string = 'vpn-extension-status.json';
/** T4 期间一度用过的文件名：仍可读，作兼容回退 */
export const LEGACY_STATUS_FILE: string = 'vpn-status.json';

/** 心跳新鲜窗口：扩展每 5 s 写一次心跳，3 个周期（15 s）无心跳即判掉线 */
export const HEARTBEAT_INTERVAL_MS: number = 5000;
export const HEARTBEAT_STALE_MS: number = 15000;

export function extStatusPath(filesDir: string): string {
  return `${filesDir}/${EXT_STATUS_FILE}`;
}

export function readExtensionStatus(filesDir: string): VpnExtensionStatus | undefined {
  try {
    const path: string = extStatusPath(filesDir);
    let text: string = readTextSafe(path);
    if (text.length === 0) {
      text = readTextSafe(`${filesDir}/${LEGACY_STATUS_FILE}`);
    }
    if (text.length === 0) {
      return undefined;
    }
    // 审查 2026-10-22：以前直接 `as` 强转 —— 旧版/字段不全的状态文件会让调用方在 .length/.indexOf 上抛 TypeError
    return normalize(JSON.parse(text) as Record<string, Object>);
  } catch (error) {
    return undefined;
  }
}

/** 把读到的 JSON 补齐默认值（字段缺失/类型不对都不会崩） */
function normalize(raw: Record<string, Object>): VpnExtensionStatus {
  const base: Record<string, Object> = raw === null || raw === undefined ? {} as Record<string, Object> : raw;
  const str = (key: string): string => {
    const v: Object | undefined = base[key];
    return typeof v === 'string' ? v as string : '';
  };
  const num = (key: string): number => {
    const v: Object | undefined = base[key];
    return typeof v === 'number' ? v as number : 0;
  };
  const bool = (key: string): boolean => {
    const v: Object | undefined = base[key];
    return v === true;
  };
  const ipsRaw: Object | undefined = base['tailscaleIps'];
  const ips: string[] = [];
  if (ipsRaw !== undefined && ipsRaw !== null && Array.isArray(ipsRaw)) {
    const arr: Object[] = ipsRaw as Object[];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        ips.push(arr[i] as string);
      }
    }
  }
  const st: VpnExtensionStatus = {
    seq: num('seq'),
    updatedAtMs: num('updatedAtMs'),
    heartbeatAtMs: num('heartbeatAtMs'),
    phase: str('phase'),
    address: str('address'),
    backendState: str('backendState'),
    authUrlReady: bool('authUrlReady'),
    authUrl: str('authUrl'),
    errorCode: num('errorCode'),
    detail: str('detail'),
    kernelError: str('kernelError'),
    statusUnavailableStreak: num('statusUnavailableStreak'),
    statusUnavailableSinceMs: num('statusUnavailableSinceMs'),
    kernelJson: str('kernelJson'),
    peersJson: str('peersJson'),
    peersAtMs: num('peersAtMs')
  };
  return st;
}

/** 原子写（`.tmp`→rename）：避免 UI 读到半个 JSON；写完**发事件**通知对面（不再每秒读文件） */
export function writeExtensionStatus(filesDir: string, status: VpnExtensionStatus): boolean {
  let ok: boolean = false;
  try {
    ok = writeTextAtomic(extStatusPath(filesDir), JSON.stringify(status));
  } catch (error) {
    ok = false;
  }
  if (ok) {
    publishEvent(EVENT_VPN_STATUS, `seq=${status.seq}`);
  }
  return ok;
}

export function isHeartbeatFresh(status: VpnExtensionStatus | undefined, nowMs: number): boolean {
  if (status === undefined) {
    return false;
  }
  const beat: number = status.heartbeatAtMs > 0 ? status.heartbeatAtMs : status.updatedAtMs;
  return (nowMs - beat) <= HEARTBEAT_STALE_MS;
}

/**
 * 2026-10-19：扩展**还活着且已入网**吗（用来决定"要不要自动进主界面 / 要不要说没入网"）。
 * 光看 `backendState === 'Running'` 不够：装包重启后状态文件还是旧的 Running，App 会误以为已入网，
 * 实际扩展进程早没了、隧道是断的（云真机实测：0.1.15 装完直接进主界面，点连接报"dsh 未启动"）。
 * 所以扩展入网后每 30s 写一次心跳，这里用 70s 窗口判活。
 */
export const EXT_LIVE_WINDOW_MS: number = 70000;

export function isExtensionLive(status: VpnExtensionStatus | undefined, nowMs: number): boolean {
  if (status === undefined) {
    return false;
  }
  // Running 但地址还没下发 = 还没真入网（扩展的 phase 映射也把这态叫 starting）
  const running: boolean = (status.backendState === 'Running' || status.phase === 'running') &&
    status.address.length > 0;
  if (!running) {
    return false;
  }
  const beat: number = status.heartbeatAtMs > 0 ? status.heartbeatAtMs : status.updatedAtMs;
  return beat > 0 && (nowMs - beat) <= EXT_LIVE_WINDOW_MS;
}

/** 给扩展发一条命令（不等回执；要回执的用 `pingExtension`） */
export function sendExtensionCommand(filesDir: string, command: string): boolean {
  if (filesDir.length === 0) {
    return false;
  }
  const seq: number = Date.now();
  const cmd: VpnCommand = { seq: seq, issuedAtMs: Date.now(), command: command, tunFd: -1 };
  const ok: boolean = writeCommand(filesDir, cmd);
  if (ok) {
    publishEvent(EVENT_VPN_COMMAND, `seq=${seq}`);
  }
  return ok;
}

/**
 * **直接问扩展进程"你还在吗"**（2026-10-20 真机踩到：装包后状态文件还写着 Running，
 * 但扩展进程已经没了，1500ms 内收不到 ping 回执 ⇒ 判"没入网"，停在登录页）。
 * 回执按 `seq` 匹配（防陈旧），通道就是既有的命令/响应文件。
 */
export async function pingExtension(filesDir: string, timeoutMs: number = 1500): Promise<boolean> {
  if (filesDir.length === 0) {
    return false;
  }
  const attemptMs: number = Math.max(400, Math.floor(timeoutMs / 2));
  // 冷启动时扩展的事件订阅可能还没建好：一次不发就重发一次（命令文件会被补读）
  for (let attempt = 0; attempt < 2; attempt++) {
    const seq: number = Date.now() + attempt;
    const command: VpnCommand = { seq: seq, issuedAtMs: Date.now(), command: 'ping', tunFd: -1 };
    if (!writeCommand(filesDir, command)) {
      return false;
    }
    publishEvent(EVENT_VPN_COMMAND, `seq=${seq}`);
    const deadline: number = Date.now() + attemptMs;
    while (Date.now() < deadline) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 100);
      });
      const response = readResponse(filesDir);
      if (response !== undefined && response.seq === seq) {
        return response.ok;
      }
    }
  }
  return false;
}

/** seq 单调：只接受比上次大的（契约 §4.2 防陈旧第 1 步） */
export function isNewerSeq(status: VpnExtensionStatus, lastSeq: number): boolean {
  return status.seq > lastSeq;
}

/**
 * 2026-10-20：拉起扩展**之前**把旧状态文件删掉。
 * 踩过：上一轮留下的 `authUrl` 还在文件里，登录页一启动扩展就读到它、拿旧链接开浏览器 ⇒ Tailscale 回 404。
 */
export function clearExtensionStatus(filesDir: string): void {
  if (filesDir.length === 0) {
    return;
  }
  for (const name of [EXT_STATUS_FILE, LEGACY_STATUS_FILE]) {
    try {
      const path: string = `${filesDir}/${name}`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      // 删不掉就留着，扩展起来后会覆盖
    }
  }
}



