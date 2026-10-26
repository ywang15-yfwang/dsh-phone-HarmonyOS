# dsh-to-phone

手机 App 点一下「连接电脑」，自动拿到 dsh 的浏览器会话 cookie。**配对一次长期有效（默认 30 天）**，而且**电脑侧零操作**：没有审批弹窗、不用手抄、不用跑命令。

## 它是怎么做到的（路径 1：复用 dsh 自己的签发能力）

dsh 的鉴权事实（源码 `@deepseek-ai/dsh-client-connection/lib/index.js`，v0.2.0-rc.2）：

| 行 | 事实 |
|---|---|
| :223 | 签名密钥存在 `credentials` 记录 `credentialKey("client-connection","browser-session")` 里 |
| :325-341 | 该记录持久化，激活时载入；插件**不改写**它 |
| :374 | `BrowserAuth.authenticatedUrl(baseUrl)` 把本进程 launch token 挂到 URL 上 |
| :388-411 | `GET /?token=…` ⇒ `303 + set-cookie: dsh-auth-<b64url(sha256(authority))>=v1.<b64url(json)>.<b64url(HMAC)>`，载荷 `{version,authority,issuedAt,expiresAt}` |
| :433-443 | `isAuthenticated` 只认 `Host` + `Cookie` 两个头；authority 必须匹配 |
| :568 | `HostConnectionService.browserAuth` 是公开字段 ⇒ 任何插件 `ctx.connection.browserAuth` 直接可用 |

所以插件不复制算法、不读密钥、不做反向代理，而是：
拿到 `browserAuth` → 用 `http://127.0.0.1:<dshPort>/` 调 `authenticatedUrl()` → **插件自己**对那个 URL 发一次本机 GET → 把 dsh 回的 `set-cookie` 原样交给手机。

> **authority 必须与手机一致**：cookie 名与签名载荷都绑 `Host`。插件固定在 `127.0.0.1:<dshPort>` 上铸，手机之后直连 dsh 时必须用同样的 `Host: 127.0.0.1:<dshPort>`（模拟器则可让 dsh 侧用别的 authority，见下）。
> **不自签的理由**：`encodeCookie`/`initializeSecret` 未导出（:850），自签要复制算法；而 `browserAuth.secret` 是激活时载入内存的活密钥（:349），磁盘记录改动要等下次激活 —— 复制品一漂移就造出 401 的 cookie。

## 资格 = 网络身份，不是"人点一下"

- 监听口**只 bind `127.0.0.1` 与本机 tailnet 地址**（`100.64.0.0/10`）：**绝不 bind `0.0.0.0`、绝不绑公网网卡**；
- **探测不到 tailnet 地址 ⇒ 不启动**（日志写明 `no-tailnet-address`，**不降级**成开放局域网）；
- 来源闸门只放行「回环」与「tailnet 段 `100.64.0.0/10`」（2026-10-19 修正：以前只放行本机那一个地址，手机打进来会 403）；**完全不看 `X-Forwarded-For`**；
- `POST /pair/claim` 每来源 IP 10s 限 1 次；凭据**只发一次**；
- 日志只打长度与 authority，**绝不打印 cookie/token 内容**。

## API（自有监听口；端口由部署配置指定，**不是** dsh 的 `/api` 路由）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/pair/info` | 探活。返回 `{name, version, skipApproval, credentialLifetimeDays, phoneAuthority, tailnet, bound, unredeemed}`；手机据此得到要连的地址与凭据会绑到哪个 authority |
| POST | `/pair/claim` | 一步取凭据。body 可选 `{device, note, authority}`；`authority` 与 `phoneAuthority` 不符 ⇒ 409（免得交付一个会 401 的 cookie）。成功 ⇒ `{cookieName, cookieValue, authority, expiresAt, credentialLifetimeMs}` —— `cookieValue` 就是可直接塞进 `Cookie` 头的 set-cookie 串 |
| GET | `/pair/session?t=<token>` | 用一次性 token 换同一份凭据；**只成功一次**，重复 ⇒ 410 |

限速 ⇒ 429；铸不出来（dsh web 没跑 / launch token 失效）⇒ 502 `exchange-failed`，且不留下垃圾票。

> **2026-10-17 起只剩这个职责**：`/pair/stream`（NDJSON 转发 `session/follow`）与 `/pair/attach`（挂工作区）
> **已删除**。原因（都有实证，别再照着旧结论做）：
> ① 手机端**能**直连 dsh 的官方 WebSocket 载体 `/api/remote.mux` —— 它自己用 TCP 握手（App 里 `services/RawWs.ets`），
>    把 `Host`/`Origin` 都写成回环即可 101；`session/follow`、`workspace/follow` 都能跑通；
> ② 工作区归属不用插件：官方 `workspace/create {path}` → `session/create {workspaceId}` 两步，
>    建出来的会话当场就在那个工作区里。
> 所以插件只保留"探活 + 发凭据"——dsh 的 cookie 只能用**每个进程随机生成的启动令牌**换，
> 令牌只在电脑启动时打印、手机拿不到，这一步必须由电脑侧代换（"不设口令"的前提）。

## 手机侧怎么接（清单，App 改动另议）

1. 确定配对口地址：**真机** `<tailnet 地址或主机名>:<配对口端口>`；**鸿蒙模拟器** `10.0.2.2:<配对口端口>`（模拟器的 `10.0.2.2` = 宿主回环 ⇒ 命中 `127.0.0.1` 绑定）。
2. `GET http://<pairHost>/pair/info` 探活，读 `phoneAuthority` 与 `credentialLifetimeDays`。
3. `POST /pair/claim`，body `{device:"Mate 60 Pro", note:"", authority:"<phoneAuthority>"}`。
4. 存下 `cookieValue`（整串 set-cookie，或只取 `name=value` 两段）与 `expiresAt`。
5. 之后直连 dsh：`Host: 127.0.0.1:<dshPort>`（模拟器是 `10.0.2.2:<dshPort>`，**此时 dsh 侧要按该 authority 铸**，见配置）+ 请求头 `Cookie: dsh-auth-…=v1.…`。
6. 到 `expiresAt` 前重新 `POST /pair/claim` 续期即可（受限速 10s）。

## 装进 profile（本地 link）

目标 profile：`E:\dsh\profiles\web`（`dsh web --port 3080`）。**只动 web，不要动 team。**

```powershell
# 0) 备份（改前）
Copy-Item E:\dsh\profiles\web\package.json E:\dsh\profiles\web\package.json.bak-YYYYmmdd_HHMMSS
# 1) link（务必走 cmd /c 的 pnpm.cmd，不要 pnpm.ps1）
$env:CI='true'; cmd /c "pnpm --dir E:\dsh\profiles\web add link:D:/DeepSeek/dsh-to-phone --reporter=append-only"
# 2) 把 "dsh-to-phone" 追加进 E:\dsh\profiles\web\package.json 的 dsh.profile.bundles
# 3) 重启 dsh web —— host 半边不热加载，必须重启
```

## 回滚

```powershell
# 1) 从 bundles 数组里删掉 "dsh-to-phone"
# 2) cmd /c "pnpm --dir E:\dsh\profiles\web remove dsh-to-phone --reporter=append-only"
# 3) 或者直接恢复备份：Copy-Item <备份> E:\dsh\profiles\web\package.json -Force
# 4) 重启 dsh web
```

## 测试

```powershell
node --check lib/index.js
node test/test.mjs
```

`test/test.mjs` 覆盖：tailnet 探测（含 100.63/100.128 边界）、来源闸门（含伪造 XFF）、
真实监听口冒烟（地址含回环+tailnet、**不含 0.0.0.0**、无 tailnet 时不起监听）、
`/pair/claim` 与 `/pair/session`、限速、一次性、**authority 绑定**（错 authority ⇒ 手机侧 401）、
日志不泄露凭据。

## 已知边界

- 只绑回环 + tailnet ⇒ **手机必须在这条 tailnet 里**（真机需装 Tailscale 并登录同一账号）；不在 tailnet 就到不了 `100.x`。
- 真机连 dsh 本体仍走它自己的方式（`Host: 127.0.0.1:<dshPort>`）；**若真机不能用回环 Host 访问 dsh，就要让 `phoneAuthority` 改成它实际用的 authority** 并重启 dsh web。
- 没有任何审批闸门 —— 到达配对口 = 拿到凭据。安全边界完全由「只有 tailnet 设备能到达」承担。

`pair/dsh/*` —— dsh 中转（2026-10-18）

- 手机在 tailnet 上唯一能到的门是插件（dsh 只听 `127.0.0.1:3080`）。
- `GET/POST /pair/dsh/<path>` 原样转给本机 dsh：`Host` 改回环形式（dsh 围栏要求），`Cookie` 原样带过去。
- `upgrade` 也转发（dsh 的 `session/follow` 走 WebSocket `remote.mux`）：插件只做字节转发，不解析协议。
- 测试：`node test/test.mjs` **107/107 通过**（2026-10-19：新增整段 tailnet 来源，含另一台设备 100.119.240.30）；语法 `node --check` 通过。

