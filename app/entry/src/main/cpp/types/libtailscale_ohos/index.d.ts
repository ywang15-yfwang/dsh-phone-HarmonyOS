// libtailscale_ohos.so 的 ArkTS 类型声明。
// 与 entry/src/main/cpp/napi_init.cpp 的 Init() 注册表**一一对应**；
// 每个后端接口都返回 JSON 字符串（hello / probeEngine / controlProbe / tunFdProbe 除外）。
//
// 按项目范围裁剪：不做 Taildrop / Taildrive / 媒体探测 / exit node / 网络开关
// （N3 / N11 / N12；且 F14 要求手机侧不存在远端推送通路）。

// 存活证明：`.so` 被 dlopen、Go 运行时装起来了才会有正常返回
export const hello: () => string;
export const tailscaleVersion: () => string;
// Tailscale userspace 引擎自检：不需要 tun、不需要网络
export const probeEngine: () => string;
export const probeEngineAsync: () => Promise<string>;
// 控制平面可达性探测（DNS + TCP + TLS 握手，不发凭据）
export const controlProbe: () => string;
export const controlProbeAsync: () => Promise<string>;

// ---- 后端生命周期 ----
// 不带 tun 起一份（先探控制平面 / 先拿授权 URL）
export const backendStart: (
  stateDir: string, deviceModel: string, osVersion: string, controlURL: string) => string;
export const backendStartAsync: (
  stateDir: string, deviceModel: string, osVersion: string, controlURL: string) => Promise<string>;
// T3 主入口：把鸿蒙虚拟网卡的 fd 交给内核，重建后端
export const backendRestartWithTun: (
  stateDir: string, deviceModel: string, osVersion: string, controlURL: string,
  tunFd: number) => string;
export const backendRestartWithTunAsync: (
  stateDir: string, deviceModel: string, osVersion: string, controlURL: string,
  tunFd: number) => Promise<string>;
export const backendStop: () => string;
export const backendStopAsync: () => Promise<string>;
export const backendLogout: () => string;
export const backendLogoutAsync: () => Promise<string>;

// ---- 可轮询的状态（同步返回，正是为了兜住"Promise 不 settle"） ----
// JSON: { backendState, phase, starting, externalTun, authUrlReady, tailscaleIps[],
//         selfName, selfDnsName, error, tunRead, tunWrite, tunReadErrors,
//         tunWriteErrors, txBytes, rxBytes, trafficSession, lastLog }
export const backendStatus: () => string;

// ---- 授权 URL ----
// JSON: { state: "ready"|"pending"|"failed", url?, message? }
// 注意：对同一代后端，调用方要**轮询**而不是重复触发交互式登录
export const backendAuthURL: () => string;
export const backendAuthURLAsync: () => Promise<string>;

// ---- peer 列表 ----
// JSON 数组: [{ name, hostName, dnsName, online, lastSeen, lastSeenUnixMs,
//               addresses[], os, osVersion, deviceModel }]
export const backendPeers: () => string;
export const backendPeersAsync: () => Promise<string>;

// ---- TUN fd 探针：只验证 fd 能否被 dup 并包成 TUN 设备，不读不写 ----
export const tunFdProbe: (tunFd: number) => string;

// ---- A 路：经内核 netstack 到 tailnet 的流式请求（5 个，**全部非阻塞** ⇒ 没有 …Async） ----
//
// 契约（签名/语义的单一来源）：harmonyos-app-toolchain\docs\p2-kernel-request-export-contract-draft.md
// **只允许扩展进程调用** —— UI 进程里是另一个空内核（内核状态是进程内的）。
// 典型用法：open → (hasBody ? write…→ finish) → 反复 read 直到 eof → close
//
// open 请求 JSON: { target, port, allowedPorts[], method, path, host, headers{}, hasBody,
//                   bodyLength, connectTimeoutMs, responseHeaderTimeoutMs,
//                   overallTimeoutMs, idleTimeoutMs, maxChunkBytes }
//   · host 默认 "127.0.0.1:<port>"（dsh 的 /api 围栏只认回环 Host）
//   · overallTimeoutMs = 0 ⇒ **不设整体超时**（事件流必须这样）
//   · allowedPorts 为空 ⇒ 全部拒绝（fail-closed）
// 返回: { ok, handle, state, authority, target } | { ok:false, code, stage, message }
export const backendPeerRequestOpen: (requestJson: string) => string;

// write: 返回 { ok, state, accepted, sentBytes, queuedBytes }
//   **accepted = 本次真正收下的字节数 ⇒ 调用方必须重试剩余部分**（背压＝部分写）
export const backendPeerRequestWrite: (handle: number, chunkBase64: string) => string;

// finish: 声明请求体结束（hasBody:false 时也要调，才开始等响应）
export const backendPeerRequestFinish: (handle: number) => string;

// read: 返回 { ok, state, status, headers{}, dataBase64, bytes, receivedBytes, sentBytes, eof, elapsedMs }
//   **永不阻塞**：只返回当前已到达的字节；没数据也立即返回（state 照常）⇒ 兼作状态轮询
//   **HTTP 非 2xx 不是错误**：ok:true + status（401/403/404 的围栏语义靠它）
export const backendPeerRequestRead: (handle: number, maxBytes: number) => string;

// close: 关闭 / 取消（内核 context cancel + 断连 + 释放缓冲）
export const backendPeerRequestClose: (handle: number) => string;
