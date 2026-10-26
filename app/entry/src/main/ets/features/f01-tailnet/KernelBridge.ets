import { BusinessError } from '@kit.BasicServicesKit';
import nativeBridge from 'libtailscale_ohos.so';

/**
 * 内核桥（契约 §1/§2/§3）：所有 nativeBridge 调用的唯一入口。
 * 两条总纪律：
 *  ① UI 线程一律用 …Async 形态（内核调用会等网络）；
 *  ② **不解析 `backendStart()` 的返回值判成败** —— 它有两种形状（actionResult / kernelStatus），
 *     **一律以 `backendStatus()` 为准**（契约 §2.5 / §8.1）。
 */
export const CONTROL_URL: string = 'https://controlplane.tailscale.com';

export interface KernelStatus {
  backendState: string;
  phase: string;
  starting: boolean;
  externalTun: boolean;
  authUrlReady: boolean;
  tailscaleIps: string[];
  selfName: string;
  selfDnsName: string;
  error: string;
  tunRead: number;
  tunWrite: number;
  tunReadErrors: number;
  tunWriteErrors: number;
  txBytes: number;
  rxBytes: number;
  trafficSession: number;
  lastLog: string;
}

export interface AuthUrlResult {
  state: string;
  url: string;
  message: string;
}

export interface ActionResult {
  ok: boolean;  message: string;
}

export interface PeerInfo {
  name: string;
  hostName: string;
  dnsName: string;
  online: boolean;
  lastSeen: string;
  lastSeenUnixMs: number;
  addresses: string[];
  os: string;
}

export function safeString(fn: () => string): string {
  try {
    const value: string = fn();
    return value === undefined || value === null ? '(null)' : `${value}`;
  } catch (error) {
    const e = error as BusinessError;
    return `EXCEPTION | ${e.message}（code=${e.code ?? -1}）`;
  }
}

export function hello(): string {
  return safeString(() => nativeBridge.hello() as string);
}

export function tailscaleVersion(): string {
  return safeString(() => nativeBridge.tailscaleVersion() as string);
}

export function probeEngine(): string {
  return safeString(() => nativeBridge.probeEngine() as string);
}

/** 控制平面可达性：**异步探测**，要循环调（契约 §2.1） */
export function controlProbe(): string {
  return safeString(() => nativeBridge.controlProbe() as string);
}

/** 只验证 fd 能否被适配成 TUN 设备（不读不写） */
// ── A 路 peerRequest（G2）：让内核 dial 到 tailnet 对端的 HTTP 通道 ────────────────
// 契约来源（**照抄，不猜**）：`native/go_bridge/peer_request.go:61-79`（请求字段）；
//  NAPI 签名：`entry/src/main/cpp/types/libtailscale_ohos/index.d.ts:70-85`。
// 三条口径：① `allowedPorts` 为空 ⇒ **fail-closed**（拒绝一切目标）；
//  ② **事件流**用 `overallTimeoutMs: 0`（显式"不设整体超时"；**不传该字段 = 默认 30 s**，二者语义不同）；
//  ③ **判成败一律解析返回体里的 `ok`** —— native 侧不抛异常，失败是 JSON 里的 `code/stage/message`。
//  ④ ≤100MB 走 `write`+`finish` 分块（`maxChunkBytes` 控制块大小），`write` 返回 `accepted/sentBytes/queuedBytes` 支持**部分写重试**。
// **必填/默认值逐条对齐 `parsePeerRequest`（`peer_request.go:492-536`）—— 见 `_dev/P1-G2-字段对齐清单.md`**。
export interface PeerOpenRequest {
  /** **必填**（空白 ⇒ `invalid_request: target is required`） */
  target: string;
  /** **必填**，**须在 `1..65535`**（超出 ⇒ `invalid_request`） */
  port: number;
  /** 放行端口白名单：**空 = fail-closed**；⚠️ 该字段**不经 `parsePeerRequest` 校验**（fail-closed 在别处实现） */
  allowedPorts: number[];
  /** 可选：**空 ⇒ 实现按 `GET`**（并 `ToUpper`；非法 token ⇒ 拒） */
  method?: string;
  /** **必填**：非空 **且须以 `/` 开头**，并且必须是**合法 request URI** */
  path: string;
  /** 可选：**空 ⇒ 实现自动补回环形式**（Host 是 `/api` 围栏的判据；非回环 ⇒ 403） */
  host?: string;
  headers: Record<string, string>;
  hasBody: boolean;
  bodyLength: number;
  /** 可选：`<=0` ⇒ 取实现默认 */
  connectTimeoutMs?: number;
  /** 可选：`<=0` ⇒ 取实现默认（Go 字段名是 `ResponseHeaderMs`，**json tag 才是这个名字**） */
  responseHeaderTimeoutMs?: number;
  /** 可选：**不传 ⇒ 默认 30 s**；**显式 `0` ⇒ 不设整体超时**（事件流要这个）；**负数 ⇒ 非法**（`invalid_request`） */
  overallTimeoutMs?: number;
  /** 可选：`<=0` ⇒ 取实现默认 */
  idleTimeoutMs?: number;
  /** 可选：`<=0` **或 > `maxReadBytes`** ⇒ 取实现默认 */
  maxChunkBytes?: number;
}

/** `open` ⇒ 原始 JSON（含 `ok/handle/state/authority/target/code/stage/message`；**调用方自行解析**）。 */
export function peerRequestOpen(request: PeerOpenRequest): string {
  return safeString(() => nativeBridge.backendPeerRequestOpen(JSON.stringify(request)) as string);
}

/** `write`（分块；chunk 为 base64）⇒ 原始 JSON（含 `accepted/sentBytes/queuedBytes`，供部分写重试）。 */
export function peerRequestWrite(handle: number, chunkBase64: string): string {
  return safeString(() => nativeBridge.backendPeerRequestWrite(handle, chunkBase64) as string);
}

/** `finish`（半关，告诉对端"请求体发完了"）⇒ 原始 JSON。 */
export function peerRequestFinish(handle: number): string {
  return safeString(() => nativeBridge.backendPeerRequestFinish(handle) as string);
}

/** `read`（每次最多 maxBytes）⇒ 原始 JSON。 */
export function peerRequestRead(handle: number, maxBytes: number): string {
  return safeString(() => nativeBridge.backendPeerRequestRead(handle, maxBytes) as string);
}

/** `close`（收尾/取消）⇒ 原始 JSON。 */
export function peerRequestClose(handle: number): string {
  return safeString(() => nativeBridge.backendPeerRequestClose(handle) as string);
}

export function tunFdProbe(fd: number): string {
  return safeString(() => nativeBridge.tunFdProbe(fd) as string);
}

/** 注意：返回值形状不一致，**不要**用它判成败（契约 §2.5） */
export function startBackendRaw(stateDir: string, deviceModel: string, osVersion: string,
  controlUrl: string): string {
  return safeString(() => nativeBridge.backendStart(stateDir, deviceModel, osVersion, controlUrl) as string);
}

/**
 * ⚠️ **UI 线程必须用这个**：`backendStart` 的同步形态会**把界面卡住**
 * （起 tailscale 后端要连控制平面，同步调用期间 UI 线程不转 ⇒ 界面停在"正在起后端…"）。
 * 与"Async 可能不 settle"的坑不同 —— 这个 Promise 实测**会** settle
 * （返回 `{"ok":true,"message":"backend starting without TUN"}`）。
 */
export async function startBackendAsync(stateDir: string, deviceModel: string, osVersion: string,
  controlUrl: string): Promise<string> {
  try {
    const promise: Promise<string> =
      nativeBridge.backendStartAsync(stateDir, deviceModel, osVersion, controlUrl) as Promise<string>;
    return await promise;
  } catch (error) {
    const e = error as BusinessError;
    return `EXCEPTION | ${e.message}（code=${e.code ?? -1}）`;
  }
}

/** T4 主入口：把 tun fd 交给内核（会先关掉旧后端再带 tun 起新的） */
export function restartWithTunRaw(stateDir: string, deviceModel: string, osVersion: string,
  controlUrl: string, tunFd: number): string {
  return safeString(() =>
    nativeBridge.backendRestartWithTun(stateDir, deviceModel, osVersion, controlUrl, tunFd) as string);
}

export function stopBackendRaw(): string {
  return safeString(() => nativeBridge.backendStop() as string);
}

export function logoutBackendRaw(): string {
  return safeString(() => nativeBridge.backendLogout() as string);
}

export function kernelStatusRaw(): string {
  return safeString(() => nativeBridge.backendStatus() as string);
}

/** T4 的主判据（只有同步形态，专门用来做超时兜底） */
export function kernelStatus(): KernelStatus | undefined {
  const raw: string = kernelStatusRaw();
  if (!raw.startsWith('{')) {
    return undefined;
  }
  try {
    // 同样补默认值：内核 JSON 的空字段可能整条缺失（`omitempty` / 版本差异）
    const parsed: KernelStatus = JSON.parse(raw) as KernelStatus;
    const st: KernelStatus = {
      backendState: parsed.backendState ?? '',
      phase: parsed.phase ?? '',
      starting: parsed.starting ?? false,
      externalTun: parsed.externalTun ?? false,
      authUrlReady: parsed.authUrlReady ?? false,
      tailscaleIps: parsed.tailscaleIps ?? [],
      selfName: parsed.selfName ?? '',
      selfDnsName: parsed.selfDnsName ?? '',
      error: parsed.error ?? '',
      tunRead: parsed.tunRead ?? 0,
      tunWrite: parsed.tunWrite ?? 0,
      tunReadErrors: parsed.tunReadErrors ?? 0,
      tunWriteErrors: parsed.tunWriteErrors ?? 0,
      txBytes: parsed.txBytes ?? 0,
      rxBytes: parsed.rxBytes ?? 0,
      trafficSession: parsed.trafficSession ?? 0,
      lastLog: parsed.lastLog ?? ''
    };
    return st;
  } catch (error) {
    return undefined;
  }
}

export function authUrlResult(): AuthUrlResult {
  const raw: string = safeString(() => nativeBridge.backendAuthURL() as string);
  if (!raw.startsWith('{')) {
    const bad: AuthUrlResult = { state: 'failed', url: '', message: raw };
    return bad;
  }
  try {
    // ⚠️ 内核 JSON 里 `url` / `message` 带 `omitempty` ⇒ **空值不出现**（字段是 undefined）。
    //    必须在这里补齐默认值，否则调用方写 `first.url.length` 会直接抛
    //    `Cannot read property length of undefined`（本轮实测踩到，白折腾了好几轮）。
    const parsed: AuthUrlResult = JSON.parse(raw) as AuthUrlResult;
    const filled: AuthUrlResult = {
      state: parsed.state ?? 'failed',
      url: parsed.url ?? '',
      message: parsed.message ?? ''
    };
    return filled;
  } catch (error) {
    const bad: AuthUrlResult = { state: 'failed', url: '', message: '授权 URL JSON 解析失败' };
    return bad;
  }
}

export function peers(): PeerInfo[] {
  const raw: string = safeString(() => nativeBridge.backendPeers() as string);
  if (!raw.startsWith('[')) {
    return [];
  }
  try {
    const parsed: PeerInfo[] = JSON.parse(raw) as PeerInfo[];
    if (parsed === undefined || parsed === null) {
      return [];
    }
    // 每条也补默认值：缺 name / online 会让调用方拼串时炸
    return parsed.map((p: PeerInfo) => {
      const one: PeerInfo = {
        name: p.name ?? '(未命名)',
        hostName: p.hostName ?? '',
        dnsName: p.dnsName ?? '',
        online: p.online ?? false,
        lastSeen: p.lastSeen ?? '',
        lastSeenUnixMs: p.lastSeenUnixMs ?? 0,
        addresses: p.addresses ?? [],
        os: p.os ?? ''
      };
      return one;
    });
  } catch (error) {
    return [];
  }
}

// ── 异步形态（契约 §1 总纪律 1：可能阻塞的入口一律用 …Async；周期刷新必须用这些） ──

export async function authUrlResultAsync(): Promise<AuthUrlResult> {
  try {
    const promise: Promise<string> = nativeBridge.backendAuthURLAsync() as Promise<string>;
    const raw: string = await promise;
    if (!raw.startsWith('{')) {
      const bad: AuthUrlResult = { state: 'failed', url: '', message: raw };
      return bad;
    }
    const parsed: AuthUrlResult = JSON.parse(raw) as AuthUrlResult;
    // 同上：`omitempty` 会让空字段消失，这里补齐
    const filled: AuthUrlResult = {
      state: parsed.state ?? 'failed',
      url: parsed.url ?? '',
      message: parsed.message ?? ''
    };
    return filled;
  } catch (error) {
    const e = error as BusinessError;
    const bad: AuthUrlResult = { state: 'failed', url: '', message: `EXCEPTION | ${e.message}` };
    return bad;
  }
}

export async function peersAsync(): Promise<PeerInfo[]> {
  try {
    const promise: Promise<string> = nativeBridge.backendPeersAsync() as Promise<string>;
    const raw: string = await promise;
    if (!raw.startsWith('[')) {
      return [];
    }
    const parsed: PeerInfo[] = JSON.parse(raw) as PeerInfo[];
    if (parsed === undefined || parsed === null) {
      return [];
    }
    return parsed.map((p: PeerInfo) => {
      const one: PeerInfo = {
        name: p.name ?? '(未命名)',
        hostName: p.hostName ?? '',
        dnsName: p.dnsName ?? '',
        online: p.online ?? false,
        lastSeen: p.lastSeen ?? '',
        lastSeenUnixMs: p.lastSeenUnixMs ?? 0,
        addresses: p.addresses ?? [],
        os: p.os ?? ''
      };
      return one;
    });
  } catch (error) {
    return [];
  }
}

/** tailscaleIps 可能缺失/为 null，统一取首个地址 */
export function firstAddress(status: KernelStatus | undefined): string {
  if (status === undefined) {
    return '';
  }
  const ips: string[] = status.tailscaleIps;
  if (ips === undefined || ips === null || ips.length === 0) {
    return '';
  }
  return `${ips[0]}`;
}
