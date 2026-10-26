# go_bridge

HarmonyOS 端的 Tailscale 原生桥：用 Go 编译成 `libtailscale_go.so`（`-buildmode=c-shared`），由 `entry/src/main/cpp/napi_init.cpp` 通过 NAPI 暴露给 ArkTS，运行在 `DshVpnExtensionAbility` 进程里。

## 包含什么

- `main.go`：导出 C 接口（启动/停止内核、查询状态、取授权 URL、列 peer 等，统一返回 JSON）；
- `backend.go`：Tailscale 后端启动与状态；
- `harmony_tun.go`：鸿蒙 TUN fd 适配（dup、清 `O_NONBLOCK`、部分写补全）；
- `peer_request*.go`：按 tailnet 地址发起的点对点请求；
- `tun_probe.go`、`control_probe.go`：连通性自检；
- `go.mod`：依赖 `tailscale.com` 与 `tailscale/wireguard-go`。

## 构建前提

- Go 1.24+
- HarmonyOS NDK（`OHOS_NDK_HOME`）
- **打过 `tailscale-ohos.patch` 的 tailscale v1.86.5 源码**，放在与本仓库同级的工具链目录：

  ```
  <root>/harmonyos-app-toolchain/third_party/tailscale
  ```

  `go.mod` 里的 `replace tailscale.com =>` 指向它；补丁来自 [flypigJ/Tailscale-OHOS](https://github.com/flypigJ/Tailscale-OHOS)。

## 构建

```powershell
cd app/native/go_bridge
go build -buildmode=c-shared -o ..\..\entry\libs\arm64-v8a\libtailscale_go.so .
```

把生成的头文件一起放到 `app/entry/libs/arm64-v8a/`。这个目录不入库（`.gitignore` 已排除 `.so` 与 `libs/`）。

## 平台限制

- 只支持 **arm64-v8a** 真机；
- 没有编译好的 `.so` 时，ArkTS 部分能编译，但打包/运行会缺库；
- 首次运行需要用户在 App 内授权 VPN 扩展。

## 第三方代码

- `tailscale.com` — BSD-3-Clause
- `tailscale/wireguard-go` — MIT
- 参考实现 `flypigJ/Tailscale-OHOS` — BSD-3-Clause（本项目按其裁剪）

详见仓库根目录的 [`THIRD_PARTY_NOTICES.md`](../../../THIRD_PARTY_NOTICES.md)。
