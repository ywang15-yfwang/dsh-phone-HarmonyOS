# dsh-to-phone

dsh 插件：让手机（tailnet 上的另一台设备）通过一个**你自己指定的端口**访问这台电脑上的 dsh —— 配对、会话转发、审批、工件、附件。

## 要求

- dsh（支持 profile bundle 的版本）
- 电脑与手机在同一 Tailscale tailnet
- Node.js 18+

## 安装

把本目录 link 进 dsh 的 profile：

```powershell
$env:CI='true'
cmd /c "pnpm --dir <profile目录> add link:<本仓库路径>/plugin --reporter=append-only"
```

然后在 profile 的 `package.json` 的 `dsh.profile.bundles` 里加入 `dsh-to-phone`。

## 配置（必填 port，没有默认值）

在 profile 的插件配置里：

```yaml
- id: pair
  name: dsh-to-phone
  config:
    port: <配对端口>          # 必填，1-65535；每个 dsh 实例各不相同
    # phonePort: <该实例的 dsh 端口>  # 可选：只在这个实例上绑配对口
    # artifactsDir: <工件目录>        # 可选：工件列表
    # credentialDays: 30              # 可选：凭据有效期（天）
```

**没有配置 `port` 时插件不会启用**，日志会提示。这样避免多个实例悄悄抢同一个端口。

## 接口

插件在 `port` 上提供：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/pair/info` | 探活：版本、tailnet、绑定的 authority |
| POST | `/pair/claim` | 取一次性凭据（只进手机内存） |
| ALL | `/pair/dsh/*` | 转发给本机 dsh（Host 改为回环） |
| WS | `/pair/approvals` | 审批通道 |
| GET | `/pair/artifacts` | 工件列表 |
| GET | `/pair/artifact?name=` | 工件内容 |
| GET | `/pair/media-by-name/<名>` | 按文件名取附件 |

来源限制：只允许回环和 tailnet 段（`100.64.0.0/10`）。

## 测试

```powershell
cd plugin
node test/test.mjs
```

## 安全说明

- 配对凭据只返回给手机一次，手机侧只放内存；
- 插件不监听公网，只接受 tailnet / 回环来源；
- 不要把端口、证书或任何密钥提交进仓库。


