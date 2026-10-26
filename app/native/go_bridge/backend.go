package main

// backend.go —— 内核侧控制器：把鸿蒙 VpnExtensionAbility 交来的 TUN fd 接到 tsnet 上，
// 并向 ArkTS 暴露**可轮询**的状态 / 授权 URL / peer 列表。
//
// 设计取自已跑通的参考实现 _refs\Tailscale-OHOS\native\go_bridge\backend.go
// （flypigJ/Tailscale-OHOS@fd49406f）的 startWithDevice / restartWithTun / status /
// authURL / peers 五条路径，**按本项目范围做了裁剪**：
//   N3  不做远程桌面        ⇒ 去掉 Sunshine / 媒体探测
//   N11 不做第三方服务集成  ⇒ 去掉 Taildrop / Taildrive
//   N12 不做 tailnet 运维台 ⇒ 去掉 exit node 切换 / 网络开关 / profile 管理
//   F14 手机侧不被反向操作  ⇒ **不启动任何"接收远端推送"的监听**
//                              （参考实现在 startAsync 里会拉起 Taildrop 收文件监听，
//                                那是一条"对端可把文件推到手机上"的通路，本项目不要）
//
// 与参考实现一致的两条关键决定（都有理由，不要"顺手改回去"）：
//  1. netns.SetEnabled(false)：OHOS Go 移植刻意沿用 Linux build tag，但应用进程用不了
//     tailscaled 那套 socket mark / 网络命名空间绕行；控制流量走普通系统拨号。
//  2. 没有真 TUN 时**不要**给 server.Tun 赋一个 nil *harmonyTunDevice —— 那会得到一个
//     非 nil 的 interface 里装着 nil 指针，wireguard-go 起 reader 后会在 nil 接收者上
//     调 Read 直接炸。
//
// 锁纪律：b.mu 只保护字段快照，**任何对 tsnet / local.Client 的调用都在持锁之外做**，
// 否则网络调用会把状态查询卡住，也可能和 tsnet 的日志回调死锁。

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/hostinfo"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/util/dnsname"
)

const (
	controlPort = 41641
	tunMTU      = 1280
)

// ---------------------------------------------------------------- DTO（JSON over C ABI）

type actionResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

type kernelStatus struct {
	BackendState  string   `json:"backendState"`
	Phase         string   `json:"phase"`
	Starting      bool     `json:"starting"`
	ExternalTun   bool     `json:"externalTun"`
	AuthURLReady  bool     `json:"authUrlReady"`
	TailscaleIPs  []string `json:"tailscaleIps"`
	SelfName      string   `json:"selfName,omitempty"`
	SelfDNSName   string   `json:"selfDnsName,omitempty"`
	Error         string   `json:"error,omitempty"`
	TunRead       uint64   `json:"tunRead"`
	TunWrite      uint64   `json:"tunWrite"`
	TunReadErrors uint64   `json:"tunReadErrors"`
	TunWriteError uint64   `json:"tunWriteErrors"`
	TxBytes       uint64   `json:"txBytes"`
	RxBytes       uint64   `json:"rxBytes"`
	TrafficID     uint64   `json:"trafficSession"`
	LastLog       string   `json:"lastLog,omitempty"`
}

type authURLResult struct {
	State   string `json:"state"` // ready | pending | failed
	URL     string `json:"url,omitempty"`
	Message string `json:"message,omitempty"`
}

// peerSummary 是给 App 看的设备条目。按 AC-13/F10 的口径，必须带**能区分是哪台电脑**的
// 标识（name / dnsName / 地址），并给出 online 与最后可见时间（F15/AC-21 会用到）。
// 只暴露展示用元数据：节点公钥、用户身份、控制平面细节一律不外传。
type peerSummary struct {
	Name           string   `json:"name"`
	HostName       string   `json:"hostName,omitempty"`
	DNSName        string   `json:"dnsName,omitempty"`
	Online         bool     `json:"online"`
	LastSeen       string   `json:"lastSeen,omitempty"` // RFC3339，仅在 offline 时由控制平面给出
	LastSeenUnixMS int64    `json:"lastSeenUnixMs,omitempty"`
	Addresses      []string `json:"addresses"`
	OS             string   `json:"os,omitempty"`
	OSVersion      string   `json:"osVersion,omitempty"`
	DeviceModel    string   `json:"deviceModel,omitempty"`
}

// ---------------------------------------------------------------- 控制器

type backendController struct {
	mu          sync.Mutex
	server      *tsnet.Server
	client      *local.Client
	starting    bool
	startErr    string
	phase       string
	generation  uint64
	stateDir    string
	externalTun bool
	tunDevice   *harmonyTunDevice
	cancelStart context.CancelFunc
	// loginRequestedGeneration 记录"已经为哪一代后端发起过 StartLoginInteractive"。
	// ArkTS 侧是**轮询**取授权 URL 的，而控制平面是异步把 URL 放出来的：不加这道闸，
	// 每次轮询都重启一次交互式登录，会把已经交给系统浏览器的那条 URL 弄失效。
	loginRequestedGeneration uint64
	lastLog                  string
}

var kernelBackend backendController

var hostinfoModelOnce sync.Once

// ---------------------------------------------------------------- 对外动作

func (b *backendController) start(stateDir, deviceModel, osVersion, controlURL string) string {
	return b.begin(stateDir, deviceModel, osVersion, controlURL, nil)
}

// restartWithTun 是 T3 的主入口：鸿蒙侧建好虚拟网卡、拿到 fd 之后调它。
// 会先把可能已存在的旧后端关掉，再用新 tun 起一份（VPN 槽位被替换时就是这个路径）。
func (b *backendController) restartWithTun(
	stateDir, deviceModel, osVersion, controlURL string, fd int,
) string {
	if fd < 0 {
		return marshalAction(false, fmt.Sprintf("invalid tun descriptor: %d", fd))
	}
	device, err := newHarmonyTunDevice(fd, tunMTU)
	if err != nil {
		// 这里必须把原始错误带出去：fd 不可用是最常见的现场故障。
		return marshalAction(false, "TUN descriptor adaptation failed: "+err.Error())
	}

	b.mu.Lock()
	oldServer := b.server
	cancelStart := b.cancelStart
	b.generation++
	b.server = nil
	b.client = nil
	b.starting = false
	b.startErr = ""
	b.phase = "vpn-restart"
	b.externalTun = false
	b.tunDevice = nil
	b.cancelStart = nil
	b.loginRequestedGeneration = 0
	b.mu.Unlock()

	// F14「随时可退出、断开后不残留」：换 tun 重建 = 上一代内核作废，
	// 把它名下所有在途 A 路句柄一并取消、断连、清表（在关旧 server 之前做，
	// 免得旧句柄还挂在即将关闭的 netstack 上）。
	if drained := drainPeerRequestHandles("kernel_not_running", "precheck",
		"backend restarted with a new TUN"); drained > 0 {
		b.recordLog(fmt.Sprintf("F14: drained %d peer request handle(s) on tun restart", drained))
	}

	if cancelStart != nil {
		cancelStart()
	}
	if oldServer != nil {
		if err := oldServer.Close(); err != nil {
			_ = device.Close()
			return marshalAction(false, "previous backend close failed: "+err.Error())
		}
	}
	return b.begin(stateDir, deviceModel, osVersion, controlURL, device)
}

func (b *backendController) begin(
	stateDir, deviceModel, osVersion, controlURL string, device *harmonyTunDevice,
) string {
	normalizedControlURL, err := normalizeControlURL(controlURL)
	if err != nil {
		return marshalAction(false, "invalid control server: "+err.Error())
	}
	if strings.TrimSpace(stateDir) == "" {
		return marshalAction(false, "empty state directory")
	}
	profileStateDir := controlServerStateDir(stateDir, normalizedControlURL)

	b.mu.Lock()
	if b.server != nil || b.starting {
		// 已经有一份在跑 / 在起：不重复起，把当前状态原样回给调用方（与参考实现一致）。
		snapshot := b.snapshotLocked()
		b.mu.Unlock()
		return marshalKernelStatus(snapshot)
	}
	// OHOS Go 移植刻意沿用 Linux build tag，但应用进程用不了 tailscaled 的
	// socket mark / 网络命名空间绕行 —— 控制流量走普通系统拨号。
	netns.SetEnabled(false)

	trimmedModel := stripHuaweiBrand(deviceModel)
	hostinfo.SetOSVersion(osVersion)
	hostinfoModelOnce.Do(func() {
		hostinfo.RegisterHostinfoNewHook(func(info *tailcfg.Hostinfo) {
			applyHarmonyHostinfo(info, osVersion, trimmedModel)
		})
	})

	b.generation++
	generation := b.generation
	startContext, cancelStart := context.WithCancel(context.Background())
	server := &tsnet.Server{
		Port:                   controlPort,
		Dir:                    profileStateDir,
		Hostname:               harmonyHostname(trimmedModel),
		ControlURL:             normalizedControlURL,
		Ephemeral:              false,
		UserLogf:               b.userLogf,
		Logf:                   b.backendLogf,
		UseNetstackForPeerDial: device != nil,
	}
	if device != nil {
		server.Tun = device
	}
	b.server = server
	b.starting = true
	b.startErr = ""
	b.phase = "starting"
	b.externalTun = device != nil
	b.tunDevice = device
	b.stateDir = profileStateDir
	b.cancelStart = cancelStart
	b.loginRequestedGeneration = 0
	b.mu.Unlock()

	go b.startAsync(server, generation, startContext)

	if device != nil {
		return marshalAction(true, "VPN backend starting with external TUN")
	}
	return marshalAction(true, "backend starting without TUN")
}

func (b *backendController) startAsync(
	server *tsnet.Server, generation uint64, startContext context.Context,
) {
	defer func() {
		if recovered := recover(); recovered != nil {
			b.setStartErrorFor(server, generation,
				fmt.Errorf("panic: %v\n%s", recovered, debug.Stack()))
		}
	}()

	if err := server.Start(); err != nil {
		b.setStartErrorFor(server, generation, err)
		return
	}
	client, err := server.LocalClient()
	if err != nil {
		b.setStartErrorFor(server, generation, err)
		return
	}

	b.mu.Lock()
	if b.server != server || b.generation != generation || startContext.Err() != nil {
		b.mu.Unlock()
		return
	}
	b.client = client
	// 刻意**不**在这里挂任何"接收远端推送"的监听（参考实现的 Taildrop 收件监听就在这一步）。
	b.starting = false
	b.cancelStart = nil
	b.phase = "ready"
	b.mu.Unlock()
}

func (b *backendController) setStartErrorFor(server *tsnet.Server, generation uint64, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.server != server || b.generation != generation {
		return
	}
	b.starting = false
	b.startErr = err.Error()
	b.cancelStart = nil
	b.phase = "start-failed"
}

func (b *backendController) stop() string {
	b.mu.Lock()
	server := b.server
	cancelStart := b.cancelStart
	b.generation++
	b.server = nil
	b.client = nil
	b.starting = false
	b.externalTun = false
	b.tunDevice = nil
	b.cancelStart = nil
	b.phase = "stopped"
	b.loginRequestedGeneration = 0
	b.mu.Unlock()

	// F14「随时可退出、断开后不残留」：停止后端时，所有在途 A 路句柄必须一起消失 ——
	// 它们是不挂在后端生命周期上的 goroutine，不在这里清就会继续跑网络动作、占着句柄槽。
	drained := drainPeerRequestHandles("kernel_not_running", "precheck", "backend stopped")
	if drained > 0 {
		b.recordLog(fmt.Sprintf("F14: drained %d peer request handle(s) on stop", drained))
	}

	if cancelStart != nil {
		cancelStart()
	}
	if server == nil {
		return marshalAction(true, "backend already stopped")
	}
	if err := server.Close(); err != nil {
		return marshalAction(false, "backend close failed: "+err.Error())
	}
	return marshalAction(true, "backend stopped")
}

func (b *backendController) logout() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return marshalAction(false, "backend not ready")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Logout(ctx); err != nil {
		return marshalAction(false, "logout failed: "+err.Error())
	}
	b.mu.Lock()
	b.loginRequestedGeneration = 0
	b.mu.Unlock()
	return marshalAction(true, "logged out")
}

// ---------------------------------------------------------------- 状态（可轮询）

func (b *backendController) status() string {
	b.mu.Lock()
	snapshot := b.snapshotLocked()
	client := b.client
	b.mu.Unlock()

	if client == nil {
		return marshalKernelStatus(snapshot)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil {
		snapshot.BackendState = "StatusUnavailable"
		snapshot.Error = err.Error()
		return marshalKernelStatus(snapshot)
	}
	snapshot.BackendState = status.BackendState
	snapshot.AuthURLReady = status.AuthURL != ""
	snapshot.TailscaleIPs = displayAddresses(status.TailscaleIPs)
	if status.Self != nil {
		snapshot.SelfName = status.Self.HostName
		snapshot.SelfDNSName = strings.TrimSuffix(status.Self.DNSName, ".")
	}
	return marshalKernelStatus(snapshot)
}

// snapshotLocked 只读字段，**不发网络请求**；调用者必须持有 b.mu。
func (b *backendController) snapshotLocked() kernelStatus {
	out := kernelStatus{
		Phase:       b.phase,
		Starting:    b.starting,
		ExternalTun: b.externalTun,
		Error:       b.startErr,
		LastLog:     b.lastLog,
	}
	if device := b.tunDevice; device != nil {
		out.TunRead, out.TunWrite = device.packetCounts()
		out.TxBytes, out.RxBytes, out.TrafficID = device.trafficCounts()
		out.TunReadErrors, out.TunWriteError = device.errorCounts()
	}
	switch {
	case b.startErr != "":
		out.BackendState = "StartFailed"
	case b.starting:
		out.BackendState = "Starting"
	case b.client != nil:
		// 后端已起好：真实状态名（Running/NeedsLogin/Stopped…）由 status() 用
		// StatusWithoutPeers 覆盖。这里给 "Running" 只是"还没问到之前"的占位，
		// **不能**落到 Stopped —— begin() 的"已经在跑就直接回状态"那条路径会用到它。
		out.BackendState = "Running"
	case b.server != nil:
		out.BackendState = "Initialized"
	default:
		out.BackendState = "Stopped"
	}
	return out
}

// ---------------------------------------------------------------- 授权 URL

func (b *backendController) authURL() string {
	b.mu.Lock()
	client := b.client
	starting := b.starting
	serverPresent := b.server != nil
	generation := b.generation
	alreadyRequested := b.loginRequestedGeneration == generation
	b.mu.Unlock()

	if client == nil {
		if starting || serverPresent {
			return marshalAuthURL(authURLResult{State: "pending", Message: "backend starting"})
		}
		return marshalAuthURL(authURLResult{State: "failed", Message: "backend not ready"})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	status, err := client.StatusWithoutPeers(ctx)
	cancel()
	if err != nil {
		return marshalAuthURL(authURLResult{State: "failed", Message: "status unavailable: " + err.Error()})
	}
	if status.AuthURL == "" {
		// 控制平面是异步放出 URL 的；ArkUI 侧轮询这个有界的 pending，
		// 所以对当前这一代后端**只能发起一次**，否则会把已交出去的 URL 弄失效。
		if alreadyRequested {
			return marshalAuthURL(authURLResult{State: "pending", Message: "requested"})
		}
		b.mu.Lock()
		b.loginRequestedGeneration = generation
		b.mu.Unlock()
		loginCtx, loginCancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := client.StartLoginInteractive(loginCtx)
		loginCancel()
		if err != nil {
			b.mu.Lock()
			if b.loginRequestedGeneration == generation {
				b.loginRequestedGeneration = 0
			}
			b.mu.Unlock()
			return marshalAuthURL(authURLResult{
				State: "failed", Message: "interactive login request failed: " + err.Error()})
		}
		return marshalAuthURL(authURLResult{State: "pending", Message: "requested"})
	}

	parsed, err := url.Parse(status.AuthURL)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") ||
		parsed.Host == "" || parsed.User != nil {
		// 交给系统浏览器之前先把住这一关：不接受非 http(s)、带凭据、无 host 的 URL。
		return marshalAuthURL(authURLResult{State: "failed", Message: "rejected unexpected auth URL origin"})
	}
	return marshalAuthURL(authURLResult{State: "ready", URL: status.AuthURL})
}

// ---------------------------------------------------------------- peer 列表

func (b *backendController) peers() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return "[]"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status.BackendState != "Running" {
		return "[]"
	}
	summaries := make([]peerSummary, 0, len(status.Peer))
	for _, peer := range status.Peer {
		if peer == nil {
			continue
		}
		name := strings.TrimSuffix(peer.DNSName, ".")
		if name == "" {
			name = peer.HostName
		}
		if name == "" {
			name = "Unnamed device"
		}
		summary := peerSummary{
			Name:        name,
			HostName:    peer.HostName,
			DNSName:     strings.TrimSuffix(peer.DNSName, "."),
			Online:      peer.Online,
			Addresses:   displayAddresses(peer.TailscaleIPs),
			OS:          peer.OS,
			OSVersion:   peer.OSVersion,
			DeviceModel: peer.DeviceModel,
		}
		// LastSeen 只在 offline 时由控制平面给出（就是 F15/AC-21 要的"最后可见时间"）。
		if !peer.LastSeen.IsZero() {
			summary.LastSeen = peer.LastSeen.UTC().Format(time.RFC3339)
			summary.LastSeenUnixMS = peer.LastSeen.UnixMilli()
		}
		summaries = append(summaries, summary)
	}
	sort.Slice(summaries, func(i, j int) bool {
		if summaries[i].Online != summaries[j].Online {
			return summaries[i].Online
		}
		return summaries[i].Name < summaries[j].Name
	})
	encoded, err := json.Marshal(summaries)
	if err != nil {
		return "[]"
	}
	return string(encoded)
}

// ---------------------------------------------------------------- 小工具

func (b *backendController) userLogf(format string, _ ...any) { b.recordLog(format) }

func (b *backendController) backendLogf(format string, _ ...any) { b.recordLog(format) }

// recordLog 只保留最后一条：既给"卡在哪一步"留现场线索，又不把内核日志刷进鸿蒙日志。
func (b *backendController) recordLog(format string) {
	if len(format) > 200 {
		format = format[:200]
	}
	b.mu.Lock()
	b.lastLog = format
	b.mu.Unlock()
}

func normalizeControlURL(rawURL string) (string, error) {
	trimmed := strings.TrimSpace(rawURL)
	if trimmed == "" || len(trimmed) > 2048 {
		return "", errors.New("empty control server")
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") ||
		parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("invalid control server")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return parsed.String(), nil
}

func controlServerStateDir(baseDir, controlURL string) string {
	sum := sha256.Sum256([]byte(controlURL))
	return filepath.Join(baseDir, "control-"+hex.EncodeToString(sum[:8]))
}

func harmonyHostname(deviceModel string) string {
	hostname := dnsname.SanitizeHostname(stripHuaweiBrand(deviceModel))
	if hostname == "" || hostname == "default" {
		return "harmonyos-next"
	}
	return hostname
}

func stripHuaweiBrand(deviceName string) string {
	trimmed := strings.TrimSpace(deviceName)
	const brand = "huawei"
	if strings.EqualFold(trimmed, brand) {
		return ""
	}
	if len(trimmed) <= len(brand) || !strings.EqualFold(trimmed[:len(brand)], brand) {
		return trimmed
	}
	remainder := strings.TrimLeft(trimmed[len(brand):], " _-")
	if remainder == trimmed[len(brand):] || remainder == "" {
		return trimmed
	}
	return remainder
}

// applyHarmonyHostinfo 让电脑侧 `tailscale status` / 管理台显示的本机 OS 是 HarmonyOS
// 而不是移植层的 linux —— AC-13 要在电脑侧认出这台手机。
func applyHarmonyHostinfo(info *tailcfg.Hostinfo, osVersion, deviceModel string) {
	if info == nil {
		return
	}
	info.OS = "HarmonyOS"
	if trimmedVersion := strings.TrimSpace(osVersion); trimmedVersion != "" {
		info.OSVersion = trimmedVersion
	}
	if trimmedModel := strings.TrimSpace(deviceModel); trimmedModel != "" && trimmedModel != "default" {
		info.DeviceModel = trimmedModel
	}
}

func displayAddresses(addresses []netip.Addr) []string {
	out := make([]string, 0, len(addresses))
	for _, addr := range addresses {
		out = append(out, addr.String())
	}
	return out
}

func marshalAction(ok bool, message string) string {
	encoded, err := json.Marshal(actionResult{OK: ok, Message: message})
	if err != nil {
		return `{"ok":false,"message":"marshal failed"}`
	}
	return string(encoded)
}

func marshalKernelStatus(status kernelStatus) string {
	encoded, err := json.Marshal(status)
	if err != nil {
		return `{"backendState":"StatusMarshalFailed"}`
	}
	return string(encoded)
}

func marshalAuthURL(result authURLResult) string {
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"state":"failed","message":"marshal failed"}`
	}
	return string(encoded)
}
