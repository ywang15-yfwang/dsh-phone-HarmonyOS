# dsh-to-phone

手机 App 与电脑上的 dsh 之间的**配对 + 中转层**。

电脑侧只跑 dsh，不需要装任何服务；插件挂在 dsh 自己的 Node 进程里，另开一个**只对 tailnet 可见**的配对口，
手机从这个口完成配对、拿凭据、发会话、看审批、取工件、传附件。

> 文中地址、端口、路径、账号一律是占位符；实际值只在运行时配置里，不写进代码或文档。

## 一、它解决什么

| 能力 | 手机侧表现 |
|---|---|
| 配对 | 「配置 → 连接配置 → 配对电脑」，一次配对长期有效（默认 30 天） |
| 登记 SSH 公钥 | 配对时把手机公钥交给电脑，**电脑上弹一次 UAC**，只有人在电脑前点「是」才成功 |
| 会话 | 列会话、看消息流、发消息（走进程内投递，不抢写句柄） |
| 审批 | 手机弹「需要授权」，点允许/拒绝，由网页端那侧执行真实裁决 |
| 权限预设 | 只改当前会话的权限档位，不动全局默认 |
| 工件 | 列 `.html` 工件，手机用 WebView 打开 |
| 附件 | 手机能上传；网页端据此决定只给「在电脑上打开」不给「保存」 |
| 在电脑上打开 | 手机点一下，电脑用默认程序（播放器/浏览器/Office）打开 |

## 二、三条链路（这是全篇的重点）

### 链路 1：配对与凭据

```
手机 ──GET /pair/info──────────────▶ 我是谁 / dsh 端口 / tailnet 地址 / authority
手机 ──POST /pair/register-key─────▶ 写公钥 → 提权脚本 → UAC → 结果 JSON
手机 ──POST /pair/claim────────────▶ dsh 的 set-cookie（绑 authority）
手机 ──GET /pair/session?t=…───────▶ 一次性票据换凭据（只成功一次）
```

- 凭据不是自己签的：插件拿 `ctx.connection.browserAuth.authenticatedUrl()` 换一次 set-cookie，原样交给手机，
  不复制签名算法、不读密钥、不碰磁盘上的 secret。
- **authority 必须与手机一致**：cookie 名和签名载荷都绑 `Host`。手机声明了不一致的 authority 直接 409，
  免得交付一个“看着能用、其实 401”的 cookie。

### 链路 2：dsh 中转

dsh 只听回环，手机在 tailnet 上够不着。`/pair/dsh/<path>` 把手机请求**原样**转给本机 dsh：

- Host 改写成回环形式（dsh 的围栏要求），Cookie 原样带过去；
- **WebSocket 升级也转发**（dsh 的消息流走 `/api/remote.mux`），插件只搬字节，不解析协议；
- 顺手记一件事：`uploadFileBinary` 且带 `name` 的，说明这份文件是**手机传上来的**。

### 链路 3：进程内投递

`session/prompt` 走 HTTP 会被 `session/writer-held` 挡掉（写句柄被网页端占着）。
插件和网页端在**同一个 dsh 进程**里，所以直接拿活动 agent 追加一条用户消息：

```
POST /pair/prompt { sessionId, text }
```

投递失败要给出明确错误（`no-injector` / `inject-failed`），不要假装成功。

## 三、接口清单

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/pair/info` | 探活。返回 `{name, version, phoneAuthority, dshAuthority, tailnet, bound, listenPort, credentialLifetimeDays}` |
| POST | `/pair/register-key` | 登记手机 SSH 公钥。校验 `ssh-ed25519` / `ssh-rsa` 格式，交给提权脚本，弹 UAC |
| POST | `/pair/claim` | 签发凭据。body 可带 `authority`，不符 409；限速 10s/来源 |
| GET | `/pair/session?t=` | 一次性票据换凭据；重放 410 |
| GET/POST | `/pair/dsh/*` | 转发到本机 dsh（含 WS 升级、上传标记） |
| POST | `/pair/prompt` | 进程内给会话追加用户消息 |
| GET | `/pair/permissions?sessionId=` | 读当前会话权限档位 |
| POST | `/pair/permissions/set` | 改当前会话权限档位（`{sessionId, value}`） |
| GET | `approvals/pending` | 未决审批列表（手机回前台补拉；**注意没有 `/pair` 前缀**） |
| GET | `/pair/approvals/debug` | 审批诊断（现场排查用） |
| WS | `/pair/approvals` | 审批推送 |
| GET | `/pair/artifacts` | 工件列表（只列 `.html`，按修改时间倒序） |
| GET | `/pair/artifact?name=` | 读单个工件（`text/html`，拒绝路径分隔符与 `..`） |
| POST/GET | `/pair/desktop/open` | 在电脑上打开 dsh 网页（审批的电脑兜底） |
| GET | `/pair/open/<id>` | 用电脑默认程序打开附件 |
| GET | `/pair/phone-uploads` | 手机上传过的文件名列表（网页端据此决定按钮） |
| GET | `/pair/client-config` | 给网页端半边：本实例的配对口端口 |

响应统一 `{ ok, error }`；错误不用 200 掩盖。`METHOD` 不符 405，服务不可用 501，参数坏 400，限速 429，
上游签不出（dsh web 没跑 / launch token 失效）502。

## 四、配置（profile 里，全部可选）

```yaml
- id: pair
  config:
    port: <pair-port>          # 配对口端口；不配用代码里的 DEFAULT_PORT
    phonePort: <dsh-port>      # 只在这个 dsh 实例上绑配对口（同一 profile 多实例时必配）
    credentialDays: 30         # 手机凭据寿命
    artifactsDir: "<dir>"      # 工件根目录；不配按约定位置找
```

代码里只放**产品默认值**；具体机器的地址、端口、路径、用户名一律运行时配置。

## 五、装机与回滚

```powershell
# 装：link 进目标 profile（务必用 cmd /c pnpm.cmd，不要 pnpm.ps1）
$env:CI='true'; cmd /c "pnpm --dir <profile-dir> add link:<repo-dir> --reporter=append-only"
# 再把 "dsh-to-phone" 追加进该 profile package.json 的 dsh.profile.bundles
# 最后重启对应的 dsh web —— host 半边不热加载
```

```powershell
# 回滚：从 bundles 删掉 → pnpm remove → 重启
cmd /c "pnpm --dir <profile-dir> remove dsh-to-phone --reporter=append-only"
```

提权脚本装在这一侧：`%LOCALAPPDATA%\dsh-phone\register-phone-key.ps1`（缺了就是 `helper-missing`）。

## 六、安全边界（写清楚，别指望它做更多）

- 监听口**只 bind 回环 + 本机 tailnet 地址**；探测不到 tailnet 就**不启动**，不降级成开放局域网；
- 来源闸门只放行回环与 tailnet 段，**连 WebSocket 升级也单独判一次**（升级不走普通 handler）；
- `POST /pair/claim` 每来源 10s 限一次，凭据只发一次；
- **没有全局审批闸门**：能到达配对口 = 有资格。安全性完全由“只有 tailnet 设备能到”承担；
- 日志只打长度与 authority，**绝不打印 cookie / token / 公钥内容**。

## 七、测试

```powershell
node --check lib/index.js
node --check lib/client.js
node test/test.mjs
```

覆盖：tailnet 探测（含网段边界）、来源闸门（含伪造 XFF）、真实监听口冒烟（**不含 0.0.0.0**、无 tailnet 不起监听）、
凭据签发与一次性、限速、authority 绑定、审批未决表、工件读取、日志不泄密。

## 八、已知边界

- 手机必须在这条 tailnet 里（真机装 Tailscale 并登录同一账号）；不在就到不了 `100.x`。
- 网页没开就没有按钮可点：此时审批只能回电脑处理，插件不该假装成功。
- 配对/重装会重置应用数据：HUKS 里的 SSH 密钥重新生成 ⇒ 需要重新配对一次（覆盖升级不受影响）。
- 发布证书签的包不能侧载，真机自测一律用调试签名的包。

## 九、历史（为什么有些接口没了）

- 2026-10-17：`/pair/stream`（NDJSON 转发 `session/follow`）与 `/pair/attach`（挂工作区）删除 ——
  手机端能直连官方 WebSocket 载体 `/api/remote.mux`，工作区归属用官方 `workspace/create` + `session/create` 两步即可。
- 2026-10-18：加回 `/pair/dsh/*` 中转 —— dsh 只听回环，手机在 tailnet 上必须有个门。
- 2026-10-20：加 `/pair/prompt` 进程内投递 —— HTTP 的 `session/prompt` 会被 `writer-held` 挡。
- 2026-10-26：加 `/pair/register-key` —— 手机上直接用系统 SSH 连电脑前，先得把公钥写进电脑。
