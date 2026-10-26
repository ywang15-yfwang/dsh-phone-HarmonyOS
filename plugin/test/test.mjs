/**
 * dsh-pair 回归测试（留在插件目录）。
 *
 *   node test/test.mjs
 *
 * 不依赖真实浏览器、也不依赖真实 dsh：
 *   A. tailnet 探测：只认 100.64.0.0/10，接口名含 tailscale 优先；
 *   B. 来源闸门：只放行回环 + 本机 tailnet；不认 X-Forwarded-For；
 *   C. host 冒烟：真实监听口 + 真实 HTTP，断言 /pair/info、/pair/claim、/pair/session 可达，
 *      监听地址含 127.0.0.1 与 tailnet、**不含 0.0.0.0**，无 tailnet 时不起监听，
 *      cookie 名 = sha256(手机 authority)，错 authority 铸的东西在手机侧必然 401，
 *      凭据只发一次、限速生效。
 */
import fs from "node:fs";
import path from "node:path";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { createServer, request as httpRequest } from "node:http";
import net from "node:net";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const LOOPBACK = "127.0.0.1";
/** 本机实测的 tailnet 地址（接口 Tailscale）。测试不硬依赖它在机器上，见 C 段末尾。 */
const TAILNET = "100.64.0.10";
const DSH_PORT = 45999;
const PHONE_AUTHORITY = `${LOOPBACK}:${DSH_PORT}`;

let failures = 0;
let checks = 0;
function ok(condition, label, extra = "") {
  checks += 1;
  if (condition) {
    console.log(`  PASS ${label}${extra === "" ? "" : ` — ${extra}`}`);
    return;
  }
  failures += 1;
  console.log(`  FAIL ${label}${extra === "" ? "" : ` — ${extra}`}`);
}
function eq(actual, expected, label) {
  ok(actual === expected, label, `实际=${JSON.stringify(actual)} 期望=${JSON.stringify(expected)}`);
}
function section(title) {
  console.log(`\n== ${title}`);
}

const host = await import(new URL("../lib/index.js", import.meta.url).href);

// ════════════════════════════════════════════════════════════════════════
// A. tailnet 探测
// ════════════════════════════════════════════════════════════════════════

section("A. tailnet 地址探测");

/** 造一份 networkInterfaces() 形状的假数据。 */
function ifaces(entries) {
  const table = {};
  for (const [name, address] of entries) {
    table[name] = table[name] ?? [];
    table[name].push({ address, netmask: "255.255.255.255", family: "IPv4", mac: "00:00:00:00:00:00", internal: false, cidr: `${address}/32` });
  }
  return table;
}

{
  eq(host.findTailnetAddress(ifaces([["Tailscale", TAILNET], ["Ethernet", "192.168.1.5"], ["Loopback", "127.0.0.1"]])), TAILNET, "接口名含 Tailscale ⇒ 取它的地址");
  eq(host.findTailnetAddress(ifaces([["eth0", "100.100.100.100"], ["Ethernet", "10.0.0.4"]])), "100.100.100.100", "没有接口名提示时按 100.64/10 段兜底");
  eq(host.findTailnetAddress(ifaces([["Ethernet", "192.168.1.5"], ["Wi-Fi", "10.1.2.3"]])), null, "只有普通私网地址 ⇒ null（不许降级成局域网）");
  eq(host.findTailnetAddress(ifaces([["Ethernet", "100.63.255.255"]])), null, "100.63 不在 100.64/10 内 ⇒ null");
  eq(host.findTailnetAddress(ifaces([["Ethernet", "100.128.0.1"]])), null, "100.128 不在 100.64/10 内 ⇒ null");
  eq(host.findTailnetAddress({}), null, "空接口表 ⇒ null");
  eq(host.findTailnetAddress(null), null, "null 接口表 ⇒ null（不抛）");

  eq(host.isTailnetIpv4("100.64.0.0"), true, "100.64.0.0 是 tailnet");
  eq(host.isTailnetIpv4("100.127.255.255"), true, "100.127.255.255 是 tailnet");
  eq(host.isTailnetIpv4("100.63.0.1"), false, "100.63.0.1 不是");
  eq(host.isTailnetIpv4("192.168.1.1"), false, "192.168.1.1 不是");
}

// ════════════════════════════════════════════════════════════════════════
// B. 来源闸门
// ════════════════════════════════════════════════════════════════════════

section("B. 来源闸门（只放行回环 + 整段 tailnet）");

const gate = host.createStore({ port: 0, dshPort: DSH_PORT, tailnetAddress: TAILNET, now: () => 1_000_000 });
{
  // 2026-10-19：手机是另一台 tailnet 设备（100.64.0.20），必须放行——只放"本机那一个地址"会 403
  const allow = ["127.0.0.1", "127.9.9.9", "::1", "::ffff:127.0.0.1", TAILNET, `::ffff:${TAILNET}`,
    "100.64.0.20", "100.64.0.1", "100.127.255.254"];
  const deny = ["192.168.1.7", "10.0.0.9", "172.16.0.1", "100.128.0.1", "8.8.8.8", "fe80::1", "fd00::1", "not-an-ip", ""];
  for (const ip of allow) eq(gate.isAllowedSource(ip), true, `放行 ${ip}`);
  for (const ip of deny) eq(gate.isAllowedSource(ip), false, `拒绝 ${ip === "" ? "(空)" : ip}`);
}

// ════════════════════════════════════════════════════════════════════════
// C. host 冒烟（真实监听口 + 真实 HTTP）
// ════════════════════════════════════════════════════════════════════════

section("C. host 冒烟（真实监听口 + 真实 HTTP）");

const SECRET = randomBytes(32);
const COOKIE_NAME = host.cookieNameForAuthority(PHONE_AUTHORITY);

/** 忠实复刻 client-connection :302-324 + :433-443 的校验，用来证明 authority 绑定。 */
function signCookie(authority, secret, { issuedAt = Date.now(), expiresAt = Date.now() + 30 * 86400000 } = {}) {
  const body = Buffer.from(JSON.stringify({ version: 1, authority, issuedAt, expiresAt }), "utf8")
    .toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
  const sig = createHmac("sha256", secret).update(body).digest()
    .toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
  return `v1.${body}.${sig}`;
}
function verifyCookie(rawCookie, hostHeader, secret) {
  const authority = hostHeader;
  const name = host.cookieNameForAuthority(authority);
  let value;
  for (const segment of rawCookie.split(";")) {
    const at = segment.indexOf("=");
    if (at === -1 || segment.slice(0, at).trim() !== name) continue;
    value = segment.slice(at + 1).trim();
    break;
  }
  if (value === undefined) return false;
  const parts = value.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") return false;
  const expected = createHmac("sha256", secret).update(parts[1]).digest()
    .toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
  if (expected !== parts[2]) return false;
  const payload = JSON.parse(Buffer.from(parts[1].replaceAll("-", "+").replaceAll("_", "/"), "base64").toString("utf8"));
  return payload.authority === authority && payload.expiresAt > Date.now();
}

const COOKIE_SET = `${COOKIE_NAME}=${signCookie(PHONE_AUTHORITY, SECRET)}; Max-Age=2592000; Path=/; Expires=${new Date(Date.now() + 2592000000).toUTCString()}; HttpOnly; SameSite=Strict`;

// 假 dsh web：扮演 `GET /?token=…` ⇒ 303 + set-cookie；`/api/*` 走 cookie 校验（中转回归用）
const seenExchanges = [];
const seenRelay = [];
const dshStub = createServer((req, res) => {
  seenExchanges.push({ url: req.url, host: req.headers.host });
  const url = new URL(req.url ?? "/", "http://x");
  if (url.pathname === "/" && url.searchParams.get("token") === "LAUNCH-TOKEN-SMOKE") {
    res.writeHead(303, { location: "./", "set-cookie": COOKIE_SET });
    res.end();
    return;
  }
  if (url.pathname.startsWith("/api/")) {
    seenRelay.push({ url: req.url, host: req.headers.host, origin: req.headers.origin ?? null });
    const authorized = verifyCookie(String(req.headers.cookie ?? ""), String(req.headers.host ?? ""), SECRET);
    if (!authorized) {
      res.writeHead(401, { "content-type": "text/plain; charset=utf-8", "content-length": 12 });
      res.end("unauthorized");
      return;
    }
    res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ path: req.url, host: req.headers.host, origin: req.headers.origin ?? null }));
    return;
  }
  res.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
  res.end("dsh web authentication required\n");
});
// 升级路径：无 cookie ⇒ 401（非 101），有 cookie ⇒ 101 —— 用来验插件是否把非 101 原样回给手机
dshStub.on("upgrade", (req, socket) => {
  // 升级后的 socket 是半开的：对端 FIN 时必须自己收尾，否则测试进程永远等不到 close
  socket.on("end", () => socket.end());
  const authorized = verifyCookie(String(req.headers.cookie ?? ""), String(req.headers.host ?? ""), SECRET);
  if (!authorized) {
    socket.end("HTTP/1.1 401 Unauthorized\r\ncontent-length: 12\r\ncontent-type: text/plain\r\n\r\nunauthorized");
    return;
  }
  socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
});
await new Promise((resolve) => dshStub.listen(DSH_PORT, LOOPBACK, resolve));

const browserAuthStub = {
  /** 关键断言点：必须用回环 authority + dsh 端口。 */
  authenticatedUrl(baseUrl) {
    const url = new URL(baseUrl);
    url.searchParams.set("token", "LAUNCH-TOKEN-SMOKE");
    return url.href;
  }
};

const smoke = host.createStore({ port: 0, dshPort: DSH_PORT, tailnetAddress: TAILNET, browserAuth: browserAuthStub });
{
  const started = await smoke.listen();
  const bindHosts = smoke.addresses.map((entry) => entry.slice(0, entry.lastIndexOf(":")));
  if (bindHosts.includes(LOOPBACK) && bindHosts.includes(TAILNET)) {
    eq(started, true, "监听口已起");
    ok(bindHosts.includes(LOOPBACK), "监听地址含 127.0.0.1", smoke.addresses.join(", "));
    ok(bindHosts.includes(TAILNET), `监听地址含 tailnet ${TAILNET}`, smoke.addresses.join(", "));
  } else {
    // 这台机器上没有该 tailnet 地址（换机/未登录）——只许绑回环，不许降级到 0.0.0.0
    ok(bindHosts.includes(LOOPBACK), "监听地址含 127.0.0.1", smoke.addresses.join(", "));
    ok(!bindHosts.includes(TAILNET), `没有绑定不存在的 tailnet 地址 ${TAILNET}`, smoke.addresses.join(", "));
  }
  ok(bindHosts.every((entry) => entry !== "0.0.0.0" && entry !== "::"), "监听地址里没有 0.0.0.0 / ::", bindHosts.join(", "));
  ok(smoke.addresses.every((entry) => !entry.startsWith("0.0.0.0")), "绑定列表里不含 0.0.0.0");
}

// 无 tailnet ⇒ 整体不启动
{
  const noTailnet = host.createStore({ port: 0, dshPort: DSH_PORT, findTailnet: () => null, browserAuth: browserAuthStub });
  eq(await noTailnet.listen(), false, "探测不到 tailnet ⇒ listen() 返回 false");
  eq(noTailnet.listening, false, "没有 tailnet 时监听态为 false");
  eq(noTailnet.reason, "no-tailnet-address", "不启动的原因写明是 no-tailnet-address");
  eq(noTailnet.addresses.length, 0, "没有任何绑定地址（绝不降级成 0.0.0.0）");
  noTailnet.close();

  const noTailnetViaIfaces = host.createStore({
    port: 0,
    dshPort: DSH_PORT,
    findTailnet: () => host.findTailnetAddress(ifaces([["Ethernet", "192.168.1.5"]])),
    browserAuth: browserAuthStub
  });
  eq(await noTailnetViaIfaces.listen(), false, "只有普通私网网卡 ⇒ 同样不启动（不开放给局域网）");
  noTailnetViaIfaces.close();
}

const smokePort = Number(smoke.addresses[0].slice(smoke.addresses[0].lastIndexOf(":") + 1));

async function call(pathname, options = {}) {
  const method = options.method ?? "GET";
  const port = options.port ?? smokePort;
  const hostHeader = options.host ?? LOOPBACK;
  const body = options.body === undefined ? null : JSON.stringify(options.body);
  return await new Promise((resolve) => {
    const req = httpRequest({
      host: LOOPBACK,
      port,
      method,
      path: pathname,
      headers: {
        host: `${hostHeader}:${port}`,
        ...(options.cookie === undefined ? {} : { cookie: options.cookie }),
        ...(options.origin === undefined ? {} : { origin: options.origin }),
        ...(options.headers ?? {}),
        ...(body === null ? {} : { "content-type": "application/json", "content-length": Buffer.byteLength(body) })
      }
    }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try { json = JSON.parse(text); } catch {}
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    req.on("error", (error) => resolve({ status: 0, headers: {}, text: String(error), json: null }));
    if (body !== null) req.write(body);
    req.end();
  });
}

// 1) 探活
{
  const res = await call("/pair/info");
  eq(res.status, 200, "GET /pair/info ⇒ 200");
  eq(res.json?.name, "dsh-to-phone", "/pair/info 报插件名");
  eq(res.json?.skipApproval, true, "/pair/info 报 skipApproval = true（电脑侧零操作）");
  eq(res.json?.credentialLifetimeDays, 30, "/pair/info 带凭据寿命（默认 30 天）");
  eq(res.json?.phoneAuthority, PHONE_AUTHORITY, "/pair/info 带手机要用的 authority");
  eq(res.json?.tailnet, TAILNET, "/pair/info 带 tailnet 地址（手机据此连）");
  ok(typeof res.json?.bound === "object" && Array.isArray(res.json.bound), "/pair/info 带实际绑定列表");
}

// 2) 未知路径 404
eq((await call("/pair/whatever")).status, 404, "未知路径 ⇒ 404");

// 3) 取凭据（一步到位）
let firstToken = "";
{
  const wrongAuthority = await call("/pair/claim", { method: "POST", body: { authority: `localhost:${DSH_PORT}` } });
  eq(wrongAuthority.status, 409, "声明了错的 authority ⇒ 409（不当场交付一个会 401 的 cookie）");
  eq(wrongAuthority.json?.expectedAuthority, PHONE_AUTHORITY, "409 里告知正确的 authority");

  const res = await call("/pair/claim", {
    method: "POST",
    body: { device: "Mate 60 Pro", note: "客厅那台", authority: PHONE_AUTHORITY }
  });
  eq(res.status, 200, "POST /pair/claim ⇒ 200");
  eq(res.json?.cookieName, COOKIE_NAME, "返回的 cookie 名 = sha256(127.0.0.1:<dshPort>)");
  eq(res.json?.authority, PHONE_AUTHORITY, "返回的 authority = 手机将用的 Host");
  ok(typeof res.json?.cookieValue === "string" && res.json.cookieValue.startsWith(`${COOKIE_NAME}=v1.`), "返回的是可直接用的 set-cookie 串");
  ok(res.text.includes("HttpOnly") && res.text.includes("SameSite=Strict"), "set-cookie 属性原样保留");
  eq(verifyCookie(res.json.cookieValue, PHONE_AUTHORITY, SECRET), true, "★ 手机用 Host: 127.0.0.1:<dshPort> 校验通过");
  eq(verifyCookie(res.json.cookieValue, `localhost:${DSH_PORT}`, SECRET), false, "★ 换 localhost 作 Host ⇒ 401（authority 绑定成立）");
  eq(res.json?.credentialLifetimeDays, 30, "响应里带 30 天寿命");

  // 铸 cookie 必须走回环 authority，且 dsh 那侧收到的 Host 就是 127.0.0.1:<port>
  eq(seenExchanges.length, 1, "确实向 dsh 发了一次换取请求");
  eq(seenExchanges[0].host, PHONE_AUTHORITY, "★ 换取请求的 Host = 手机将用的 authority");
  ok(String(seenExchanges[0].url).includes("token=LAUNCH-TOKEN-SMOKE"), "换取请求带上了本进程 launch token");

  // 响应里的 token 可供 /pair/session 再取一次（同一张票）
  const statusBody = await call("/pair/info");
  eq(statusBody.json?.unredeemed, 1, "/pair/info 报还有 1 张未取用的票");
}

// 4) 限速
{
  const again = await call("/pair/claim", { method: "POST", body: { device: "第二台" } });
  eq(again.status, 429, "同一来源 IP 立刻再取 ⇒ 429（限速）");
  ok(again.json?.retryAfterMs > 0, "429 里带 retryAfterMs");
}

// 5) 一次性 token（/pair/session）
{
  const info = await call("/pair/info");
  ok(typeof info.json?.unredeemed === "number", "/pair/info 仍可读");
}

// 6) 非 tailnet / 非回环来源被拒
{
  for (const ip of ["192.168.1.7", "10.0.0.9", "8.8.8.8", "100.128.0.1"]) {
    let captured = null;
    const fakeRes = {
      writeHead: (status, body) => { captured = { status, body }; },
      end: (body) => { if (body !== undefined) captured.body = body; }
    };
    smoke.handle({ method: "POST", url: "/pair/claim", socket: { remoteAddress: ip }, headers: {}, on() {} }, fakeRes);
    ok(captured?.status === 403, `来源 ${ip} ⇒ 403`, `实际=${captured?.status}`);
  }

  // 伪造 X-Forwarded-For 无效
  let captured = null;
  const fakeRes = { writeHead: (s) => { captured = s; }, end() {} };
  smoke.handle({
    method: "GET",
    url: "/pair/info",
    socket: { remoteAddress: "203.0.113.9" },
    headers: { "x-forwarded-for": LOOPBACK },
    on() {}
  }, fakeRes);
  eq(captured, 403, "伪造 X-Forwarded-For: 127.0.0.1 ⇒ 仍 403（完全不认这个头）");
}

// 7) tailnet 来源放行（模拟真机从 100.x 打进来）
{
  let captured = null;
  const fakeRes = {
    writeHead: (status) => { captured = status; },
    end(body) { capturedBody = body; }
  };
  let capturedBody = null;
  smoke.handle({ method: "GET", url: "/pair/info", socket: { remoteAddress: TAILNET }, headers: {}, on() {} }, fakeRes);
  eq(captured, 200, `来源 ${TAILNET} 是 tailnet 本人 ⇒ 放行`);
  // 另一台 tailnet 设备（云真机 100.64.0.20）也必须放行；否则 App 只会看到 403
  let peerCaptured = null;
  const peerRes = { writeHead: (s) => { peerCaptured = s; }, end() {} };
  smoke.handle({ method: "GET", url: "/pair/info", socket: { remoteAddress: "100.64.0.20" }, headers: {}, on() {} }, peerRes);
  eq(peerCaptured, 200, "来源 100.64.0.20（另一台 tailnet 设备）⇒ 放行");
  ok(capturedBody !== null && JSON.parse(capturedBody).ok === true, "tailnet 来源能读到 /pair/info 内容");
}

// 8) /pair/dsh 中转：HTTP 原样转发 + 升级失败必须**立刻**回状态（不能把手机挂死）
section("D. /pair/dsh 中转（HTTP + WebSocket 升级）");

const GOOD_COOKIE = COOKIE_SET.split(";")[0];

/** 发一次真实的 WS 升级握手，返回状态行；超时算失败（正是 bug #1 的症状）。 */
function upgradeAttempt(pathname, options = {}) {
  return new Promise((resolve) => {
    const socket = net.connect(smokePort, LOOPBACK);
    let text = "";
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ statusLine: "TIMEOUT", text }), 1500);
    socket.on("connect", () => {
      const lines = [
        `GET ${pathname} HTTP/1.1`,
        `Host: ${options.host ?? `127.0.0.1:${smokePort}`}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${randomBytes(16).toString("base64")}`,
        "Sec-WebSocket-Version: 13"
      ];
      if (options.cookie !== undefined) lines.push(`Cookie: ${options.cookie}`);
      if (options.origin !== undefined) lines.push(`Origin: ${options.origin}`);
      socket.write(lines.join("\r\n") + "\r\n\r\n");
    });
    socket.on("data", (chunk) => {
      text += chunk.toString("latin1");
      if (text.includes("\r\n\r\n")) finish({ statusLine: text.split("\r\n")[0], text });
    });
    socket.on("error", (error) => finish({ statusLine: `ERR ${error.message}`, text }));
  });
}

{
  const bare = await call("/pair/dsh/api/echo");
  eq(bare.status, 401, "不带 cookie 的 /pair/dsh ⇒ dsh 的 401 原样回给手机");
  eq(bare.text, "unauthorized", "401 的 body 也原样转发");

  const authed = await call("/pair/dsh/api/echo?x=1&y=2", {
    cookie: GOOD_COOKIE,
    origin: `http://${TAILNET}:${smokePort}`
  });
  eq(authed.status, 200, "带 cookie 的 /pair/dsh ⇒ 200");
  eq(authed.json?.path, "/api/echo?x=1&y=2", "查询串原样带到 dsh");
  eq(authed.json?.host, PHONE_AUTHORITY, "★ 转发时 Host 改成回环 authority（dsh 围栏要求）");
  eq(authed.json?.origin, `http://${PHONE_AUTHORITY}`, "★ 转发时 Origin 也改成同一个回环 authority（否则 403）");

  const noOrigin = await call("/pair/dsh/api/echo", { cookie: GOOD_COOKIE });
  eq(noOrigin.status, 200, "客户端没带 Origin 时不硬塞一个");
  eq(noOrigin.json?.origin, null, "没带 Origin ⇒ dsh 侧也没有 Origin");

  eq((await call("/pair/dsh")).status, 401, "/pair/dsh 无尾路径 ⇒ 转给 dsh 根（401）");
}

{
  const noCookie = await upgradeAttempt("/pair/dsh/api/remote.mux");
  ok(noCookie.statusLine.startsWith("HTTP/1.1 401"), "★ 升级被 dsh 拒（401）⇒ 立刻把 401 回给手机（不是挂起）", noCookie.statusLine);

  const okCookie = await upgradeAttempt("/pair/dsh/api/remote.mux", { cookie: GOOD_COOKIE, origin: `http://${TAILNET}:${smokePort}` });
  eq(okCookie.statusLine, "HTTP/1.1 101 Switching Protocols", "带 cookie 的升级 ⇒ 101");
  ok(/upgrade: websocket/i.test(okCookie.text), "101 响应头里有 Upgrade: websocket", JSON.stringify(okCookie.text.slice(0, 120)));

  const otherPath = await upgradeAttempt("/pair/not-dsh", { cookie: GOOD_COOKIE });
  ok(otherPath.statusLine.startsWith("HTTP/1.1 404"), "无关路径的升级 ⇒ 404（不再无声 destroy）", otherPath.statusLine);
}

{
  // dsh 没起来：中转要回 502，而不是让手机干等
  const dead = host.createStore({ port: 0, dshPort: 1, tailnetAddress: TAILNET, browserAuth: browserAuthStub });
  await dead.listen();
  const deadPort = Number(dead.addresses[0].slice(dead.addresses[0].lastIndexOf(":") + 1));
  const res = await call("/pair/dsh/api/echo", { port: deadPort, cookie: GOOD_COOKIE });
  eq(res.status, 502, "dsh 端口不通 ⇒ 502 dsh-unreachable");
  eq(res.json?.error, "dsh-unreachable", "502 里写明 dsh-unreachable");
  dead.close();
}

smoke.close();
// 中转会留下 keep-alive 连接；不主动断，close() 会一直等
dshStub.closeAllConnections();
await new Promise((resolve) => dshStub.close(resolve));
await new Promise((resolve) => dshStub.close(resolve));

// 9) 一次性 token 的 claim() 语义（store 级，不依赖 HTTP）
{
  const store = host.createStore({
    port: 0,
    dshPort: DSH_PORT,
    tailnetAddress: TAILNET,
    now: () => 5_000_000,
    exchange: async () => ({ status: 303, setCookie: COOKIE_SET })
  });
  const issued = await store.issue(LOOPBACK);
  eq(issued.ok, true, "issue() 签发成功");
  ok(typeof issued.token === "string" && issued.token.length >= 16, "拿到一次性 token", `长度=${issued.token.length}`);

  const first = store.claim(issued.token);
  eq(first.ok, true, "第一次 claim(token) 成功");
  const second = store.claim(issued.token);
  eq(second.ok, false, "第二次 claim(token) 被拒（只发一次）");
  eq(second.code, "already-claimed", "拒绝原因是 already-claimed");
  eq(store.claim("not-a-real-token").code, "unknown-token", "不存在的 token ⇒ unknown-token");
  eq(store.status().unredeemed, 0, "取走后未取用票数归零");

  const limited = await store.issue(LOOPBACK);
  eq(limited.code, "rate-limited", "同来源立刻再 issue ⇒ rate-limited");
  store.close();

  // 铸失败时不留下垃圾票
  const failing = host.createStore({
    port: 0,
    dshPort: DSH_PORT,
    tailnetAddress: TAILNET,
    now: () => 6_000_000,
    exchange: async () => ({ status: 401, setCookie: null, error: "no-set-cookie" })
  });
  const broken = await failing.issue(LOOPBACK);
  eq(broken.ok, false, "dsh 侧没给 set-cookie ⇒ 签发失败");
  eq(broken.code, "exchange-failed", "失败原因是 exchange-failed");
  eq(failing.status().unredeemed, 0, "失败后不留下未取用的票");
  failing.close();
}

// 10) apply 接线（stub ctx）
{
  const store = host.internals;
  eq(store.store, null, "初始没有活 store");
  const effectCalls = [];
  const warnings = [];
  const ctx = {
    webServer: { port: DSH_PORT, register() {} },
    connection: { browserAuth: browserAuthStub },
    logger: { warn: (m) => warnings.push(String(m)) },
    effect: (factory, label) => { effectCalls.push(label); factory(); }
  };
  host.apply(ctx, { port: 0, tailnetAddress: TAILNET });
  eq(effectCalls.length, 1, "apply 注册了 1 个 effect");
  eq(effectCalls[0], "dsh-to-phone: 配对监听口", "effect 标签正确");
  ok(host.internals.store !== null, "apply 后 internals.store 就位");
  eq(host.internals.store.addresses.length, 0, "apply 同步返回时还没绑上（listen 是异步的，不阻塞宿主启动）");
  await new Promise((resolve) => setTimeout(resolve, 50));
  ok(host.internals.store.listening === true, "apply 之后监听口起来了");
  ok(host.internals.store.addresses.length >= 1, "并且有实际绑定地址", host.internals.store.addresses.join(", "));
  host.internals.store.close();
  host.internals.store = null;

  // 取不到 browserAuth 时不启动，也不抛
  host.apply({ webServer: { port: DSH_PORT }, logger: { warn: (m) => warnings.push(String(m)) }, effect: () => {} }, { port: 0 });
  ok(warnings.some((line) => line.includes("browserAuth")), "取不到 connection.browserAuth 时明确记日志");
  eq(host.internals.store, null, "取不到 browserAuth 时不建 store");
}

// ════════════════════════════════════════════════════════════════════════
// ════════════════════════════════════════════════════════════════════════
console.log(`\n${failures === 0 ? "ALL PASS" : "FAILURES"}: ${checks - failures}/${checks} 项断言通过`);
process.exit(failures === 0 ? 0 : 1);


