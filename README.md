# dsh 手机端

在手机上接着用电脑上的 dsh。

- **dsh 仍然跑在电脑上**，手机不跑 dsh；
- 手机和电脑登录同一个 **Tailscale** 网络，通过点对点加密通道通信；
- 电脑端需要安装配套插件，并保持已登录桌面（建议开启 Windows 自动登录）。

## 仓库组成

| 目录 | 内容 |
|---|---|
| `app/` | HarmonyOS NEXT 客户端（ArkTS / ArkUI，API 26） |
| `plugin/` | 电脑端 dsh 插件 `dsh-to-phone`：配对、转发、审批、工件 |
| `scripts/` | 电脑端启停 dsh、SSH 加固、自动登录的 PowerShell 脚本 |

## 工作原理

```
手机 App ──Tailscale(加密)──> 电脑:插件端口 ──> 本机 dsh(127.0.0.1)
```

- dsh 只监听电脑回环，手机够不到；
- 插件在 tailnet 上监听一个**你自己配置的端口**（没有默认值），负责配对和转发；
- 手机拿到一次性凭据后，经插件访问 dsh 的会话、审批、工件等接口。

## 要求

- 手机：HarmonyOS NEXT（API 26 及以上）
- 电脑：Windows，已安装 dsh，已登录桌面（建议配置自动登录）
- 网络：手机与电脑在同一 Tailscale tailnet

## 快速开始

1. 电脑上安装插件 `dsh-to-phone` 并配置端口（源码在 `plugin/`，步骤见 `docs/快速开始.md`）；
2. 安装电脑端脚本（见 `scripts/README.md`）；
3. 手机安装 App，登录 Tailscale，在「配置」里填电脑的端口与 SSH 信息，回到「电脑」页连接。

详细步骤见 [`docs/快速开始.md`](docs/快速开始.md)。

## 构建

见 [`docs/构建与签名.md`](docs/构建与签名.md)。首次构建需要先编译原生桥：源码在 `app/native/go_bridge/`，仓库不带编译好的 50 MB 级 `.so`。本仓库**不包含任何签名材料**，签名请在本机配置，切勿提交。

## 安全与隐私

- 不收集、不上传使用数据，不需要注册账号；
- 手机与电脑之间走 Tailscale 点对点加密；
- 配对凭据只放内存；
- 电脑侧 SSH 可配置为只认公钥。

## 版本

0.7.0

## 许可

本项目使用 **MIT** 许可证，全文见 [LICENSE](LICENSE)。

第三方软件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
