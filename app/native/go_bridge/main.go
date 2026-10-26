package main

// main.go —— 通过 CGO 导出给 NAPI 的 C ABI 面。
//
// 返回值一律是**调用方负责释放**的 C 字符串（用 TSFreeString 释放）。
// 除 TSHello / TSProbeEngine / TSControlProbe 外，统一返回 **JSON**，方便 ArkTS 侧
// 直接 JSON.parse，而不是解析分隔符字符串。
//
// 本文件按项目范围裁剪过：参考实现 _refs\Tailscale-OHOS\native\go_bridge\main.go
// （flypigJ/Tailscale-OHOS@fd49406f）里的 Taildrop / Taildrive / 媒体探测 / exit node /
// 网络开关等导出**一律不提供**（N3 / N11 / N12，且 F14 要求手机侧不存在远端推送通路）。
// 完整的参考导出面清单见 harmonyos-app-toolchain\dist\EXPORTS.txt。

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"runtime"
	"runtime/debug"
	"unsafe"

	"tailscale.com/net/netns"
	"tailscale.com/net/tsdial"
	"tailscale.com/tsd"
	"tailscale.com/version"
	"tailscale.com/wgengine"
)

// TSHello 是最小存活证明：能返回它，说明 .so 已被 dlopen、Go 运行时已在鸿蒙进程里起来。
//
//export TSHello
func TSHello() *C.char {
	platform := runtime.GOOS
	if runtime.IsOpenharmony {
		platform = "openharmony"
	}
	message := fmt.Sprintf("OK | Go %s | %s/%s", runtime.Version(), platform, runtime.GOARCH)
	return C.CString(message)
}

// TSProbeEngine 试着把 Tailscale 的 userspace 引擎初始化一遍（不需要 tun、不需要网络）。
// 它是"这条移植在这台设备上到底能不能跑"的最便宜探针：panic 也要被兜住并如实上报。
//
//export TSProbeEngine
func TSProbeEngine() (result *C.char) {
	stage := "entry"
	defer func() {
		if recovered := recover(); recovered != nil {
			result = C.CString(fmt.Sprintf(
				"FAILED | stage=%s | Tailscale engine panic | %v\n%s",
				stage, recovered, debug.Stack()))
		}
	}()
	stage = "disable-netns"
	netns.SetEnabled(false)
	logf := func(string, ...any) {}
	stage = "new-system"
	sys := tsd.NewSystem()
	dialer := &tsdial.Dialer{Logf: logf}
	stage = "new-userspace-engine"
	engine, err := wgengine.NewUserspaceEngine(logf, wgengine.Config{
		EventBus:      sys.Bus.Get(),
		Dialer:        dialer,
		SetSubsystem:  sys.Set,
		ControlKnobs:  sys.ControlKnobs(),
		HealthTracker: sys.HealthTracker(),
		Metrics:       sys.UserMetricsRegistry(),
	})
	if err != nil {
		return C.CString(fmt.Sprintf("FAILED | Tailscale %s | %v", version.Short(), err))
	}
	stage = "close-userspace-engine"
	defer engine.Close()
	stage = "set-engine-subsystem"
	sys.Set(engine)
	stage = "complete"
	return C.CString(fmt.Sprintf("OK | Tailscale %s | userspace engine initialized", version.Short()))
}

// TSBackendStart 不带 tun 起一份后端（用于先探控制平面 / 先拿到授权 URL）。
//
//export TSBackendStart
func TSBackendStart(stateDir *C.char, deviceModel *C.char, osVersion *C.char, controlURL *C.char) *C.char {
	if stateDir == nil || deviceModel == nil || osVersion == nil || controlURL == nil {
		return C.CString(`{"ok":false,"message":"missing startup metadata"}`)
	}
	return C.CString(kernelBackend.start(
		C.GoString(stateDir), C.GoString(deviceModel), C.GoString(osVersion), C.GoString(controlURL)))
}

// TSBackendRestartWithTun 是 T3 主入口：把鸿蒙虚拟网卡的 fd 交给内核，重建后端。
//
//export TSBackendRestartWithTun
func TSBackendRestartWithTun(
	stateDir *C.char, deviceModel *C.char, osVersion *C.char, controlURL *C.char, fd C.int,
) *C.char {
	if stateDir == nil || deviceModel == nil || osVersion == nil || controlURL == nil {
		return C.CString(`{"ok":false,"message":"missing startup metadata"}`)
	}
	return C.CString(kernelBackend.restartWithTun(
		C.GoString(stateDir), C.GoString(deviceModel), C.GoString(osVersion),
		C.GoString(controlURL), int(fd)))
}

//export TSBackendStop
func TSBackendStop() *C.char {
	return C.CString(kernelBackend.stop())
}

//export TSBackendLogout
func TSBackendLogout() *C.char {
	return C.CString(kernelBackend.logout())
}

// TSBackendStatus 可轮询：鸿蒙侧 startVpnExtensionAbility 失败时 Promise 不会 settle，
// 所以状态必须能被反复读，而不是只靠一次调用的返回。
//
//export TSBackendStatus
func TSBackendStatus() *C.char {
	return C.CString(kernelBackend.status())
}

//export TSBackendAuthURL
func TSBackendAuthURL() *C.char {
	return C.CString(kernelBackend.authURL())
}

//export TSBackendPeers
func TSBackendPeers() *C.char {
	return C.CString(kernelBackend.peers())
}

//export TSTailscaleVersion
func TSTailscaleVersion() *C.char {
	return C.CString(version.Short())
}

//export TSControlProbe
func TSControlProbe() *C.char {
	return C.CString(harmonyControlProbe.startOrStatus())
}

// TSTunFDProbe 只验证"这个 fd 能不能被 dup 并包成 wireguard-go 的 TUN 设备"，
// 全程不读也不写该描述符。
//
//export TSTunFDProbe
func TSTunFDProbe(fd C.int) *C.char {
	return C.CString(probeTunFD(int(fd)))
}

// ---------------------------------------------------------------- 经内核 netstack 的流式请求（A 路）
//
// 契约：harmonyos-app-toolchain\docs\p2-kernel-request-export-contract-draft.md
// **5 个函数全部非阻塞**（拉模型），**不提供 …Async 变体**；生命周期由 handle 承载。
// **手机侧零监听** —— 这一组是唯一与"手机怎么走到电脑"有关的导出面。

//export TSBackendPeerRequestOpen
func TSBackendPeerRequestOpen(request *C.char) *C.char {
	if request == nil {
		return C.CString(`{"ok":false,"code":"invalid_request","stage":"precheck","message":"missing request"}`)
	}
	return C.CString(kernelBackend.peerRequestOpen(C.GoString(request)))
}

//export TSBackendPeerRequestWrite
func TSBackendPeerRequestWrite(handle C.ulonglong, chunkBase64 *C.char) *C.char {
	if chunkBase64 == nil {
		return C.CString(`{"ok":false,"code":"invalid_request","message":"missing chunk"}`)
	}
	return C.CString(kernelBackend.peerRequestWrite(uint64(handle), C.GoString(chunkBase64)))
}

//export TSBackendPeerRequestFinish
func TSBackendPeerRequestFinish(handle C.ulonglong) *C.char {
	return C.CString(kernelBackend.peerRequestFinish(uint64(handle)))
}

//export TSBackendPeerRequestRead
func TSBackendPeerRequestRead(handle C.ulonglong, maxBytes C.int) *C.char {
	return C.CString(kernelBackend.peerRequestRead(uint64(handle), int(maxBytes)))
}

//export TSBackendPeerRequestClose
func TSBackendPeerRequestClose(handle C.ulonglong) *C.char {
	return C.CString(kernelBackend.peerRequestClose(uint64(handle)))
}

//export TSFreeString
func TSFreeString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func main() {}
