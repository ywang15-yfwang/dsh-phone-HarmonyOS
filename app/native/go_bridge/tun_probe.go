package main

// tun_probe.go —— 只验证 fd 能否被 dup 并包成 wireguard-go 的 TUN 设备。
// 逐字取自参考实现 _refs\Tailscale-OHOS\native\go_bridge\tun_probe.go
// （flypigJ/Tailscale-OHOS@fd49406f），未改动逻辑。

import "runtime/debug"

// probeTunFD verifies that a HarmonyOS VPN descriptor can be duplicated and
// wrapped as the wireguard-go TUN device expected by Tailscale. The descriptor
// is never read from or written to during this probe.
func probeTunFD(fd int) (result string) {
	defer func() {
		if recover() != nil {
			result = "FAILED | TUN fd probe | panic"
			_ = debug.Stack()
		}
	}()
	if fd < 0 {
		return "FAILED | TUN fd probe | invalid descriptor"
	}

	device, err := newHarmonyTunDevice(fd, tunMTU)
	if err != nil {
		return "FAILED | TUN fd probe | descriptor adaptation"
	}
	if err := device.Close(); err != nil {
		return "FAILED | TUN fd probe | descriptor close"
	}
	return "OK | HarmonyOS TUN fd adapted for wireguard-go"
}
