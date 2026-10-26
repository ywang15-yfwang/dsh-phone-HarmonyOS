/**
 * dsh-to-phone — host half.
 *
 * 目的：手机 App 点一下「连接电脑」就自动拿到 dsh 的浏览器会话 cookie，配对一次长期有效。
 * **全套流程里电脑侧零操作** —— 没有任何审批弹窗、没有 client 半边。
 *
 * ## 资格 = 网络身份，不是"人点一下"
 * 监听口**只 bind `127.0.0.1` 和本机 tailnet 地址**（`100.64.0.0/10`，Tailscale 的 CGNAT 段）：
 *   - 绝不 bind `0.0.0.0`，绝不绑公网网卡；
 *   - 探测不到 tailnet 地址 ⇒ **不启动监听**（记日志说明原因，**不降级**成"开放给局域网"）；
 *   - 来源闸门只放行「回环」与「tailnet 段（100.64.0.0/10）」，其余一律 403；**完全不看 X-Forwarded-For**。
 * 效果：只有你自己的 tailnet 设备能到达这个口（鸿蒙模拟器走 `10.0.2.2` → 宿主回环，同样命中）。
 *
 * ## 凭据怎么来（路径 1：复用 dsh 自己的签发能力，不复制算法、不建反向代理）
 *   - `ctx.connection.browserAuth`（`HostConnectionService` 的公开字段，
 *     `@deepseek-ai/dsh-client-connection/lib/index.js:568`）暴露 `authenticatedUrl()`（同文件 :374），
 *     它用本进程的 launch token 拼出 `GET /?token=…` 的 URL；
 *   - 我们拿 `http://127.0.0.1:<dshPort>/` 去调它（**authority 必须与手机将用的 Host 完全一致**：
 *     cookie 名与签名载荷都绑 authority，同文件 :284-286 / :397-407 / :440）；
 *   - 由插件自己（不是手机）对那个 URL 发一次本机 HTTP GET，dsh 的 `authorizeIndex`（:388-411）
 *     返回 `303 + set-cookie: dsh-auth-<hash>=v1.<body>.<sig>`，把这个 `set-cookie` 原样交给手机。
 *
 * 为什么不读 credentials 里的密钥自签：`encodeCookie` / `initializeSecret` 是模块内部函数，
 * 没随 `export` 暴露（同文件 :850），自签要复制算法；而 `browserAuth.secret` 是**激活时载入内存**的
 * 活密钥（:349），磁盘记录被改动要到下次激活才生效 —— 复制品一旦漂移就会造出 401 的 cookie。
 * 走 `authorizeIndex` 用的是同一把钥匙，零漂移。
 *
 * 自有监听口（端口由部署配置指定）**刻意不是 dsh 的 `/api` 路由**：`/api` 一律先过围栏，
 * 手机在拿到 cookie 之前必然 401，所以配对话必须发生在围栏之外。
 */
import { createServer, request as httpRequest } from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { networkInterfaces, homedir } from "node:os";
import { dirname, join, extname } from "node:path";
import { createReadStream, existsSync, readFileSync, writeFileSync, promises as fsp } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { createApprovalHub } from "./approval-hub.js";
import { createPermissionApi } from "./permission-api.js";
import { createArtifactsApi, resolveArtifactsDir } from "./artifacts.js";

const name = "dsh-to-phone";
const inject = ["webServer", "connection"];

/** 手机（以及本机）始终以回环 authority 访问 dsh —— 铸 cookie 也必须用同一个。 */
const LOOPBACK_HOST = "127.0.0.1";

const API_PREFIX = "/pair/";

const DEFAULT_PORT = 18099;
/** 同一来源 IP 的两次取凭据最小间隔。 */
const CLAIM_COOLDOWN_MS = 10 * 1000;
/** 请求体上限，防止有人在监听口上灌大包。 */
const MAX_BODY_BYTES = 8 * 1024;
/** dsh 浏览器会话 cookie 的默认寿命（与 client-connection 的 cookieMaxAgeDays 默认 30 一致）。 */
const DEFAULT_CREDENTIAL_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;
/** Tailscale / CGNAT 共享地址段。 */
const TAILNET_FIRST = [100, 64];
const TAILNET_LAST = [100, 127];

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff"
};

/** 附件目录里常见类型的 Content-Type（浏览器靠它决定"播放"还是"下载"） */
const MEDIA_TYPES = {
  ".mp4": "video/mp4",
  ".m4v": "video/x-m4v",
  ".mov": "video/quicktime",
  ".3gp": "video/3gpp",
  ".mkv": "video/x-matroska",
  ".webm": "video/webm",
  ".avi": "video/x-msvideo",
  ".mp3": "audio/mpeg",
  ".m4a": "audio/mp4",
  ".wav": "audio/wav",
  ".ogg": "audio/ogg",
  ".flac": "audio/flac",
  ".pdf": "application/pdf",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
  ".json": "application/json"
};

/** 手机上传过的文件名（进程内记一份；重启清空 —— 只影响"要不要显示保存"，不影响功能） */
const phoneUploads = new Set();

function markPhoneUpload(name) {
  if (typeof name !== "string" || name === "") return;
  phoneUploads.add(name);
  // 只留最近 200 个，避免长跑内存涨
  if (phoneUploads.size > 200) {
    const first = phoneUploads.values().next().value;
    phoneUploads.delete(first);
  }
}

function listPhoneUploads() {
  return Array.from(phoneUploads);
}

/** 附件 id → 磁盘路径（`serveAttachment` / `openOnDesktop` 共用；只认 64 位十六进制） */
async function resolveAttachmentFile(rawId) {
  const id = String(rawId ?? "").trim().toLowerCase().replace(/^sha256:/, "");
  if (!/^[0-9a-f]{64}$/.test(id)) return { ok: false, error: "bad-attachment-id", code: 400 };
  const configured = typeof process.env.DSH_HOME === "string" ? process.env.DSH_HOME.trim() : "";
  const home = configured !== "" ? configured : join(homedir(), ".dsh");
  const dir = join(home, "attachments", "v1", "files", id.slice(0, 2), id);
  let names;
  try {
    names = await fsp.readdir(dir);
  } catch {
    return { ok: false, error: "not-found", code: 404 };
  }
  for (const one of names) {
    if (one.startsWith(".")) continue;
    const candidate = join(dir, one);
    const st = await fsp.stat(candidate).catch(() => null);
    if (st !== null && st.isFile()) return { ok: true, file: candidate, name: one };
  }
  return { ok: false, error: "not-found", code: 404 };
}

/** 按**文件名**在附件库里找那一个（用户消息卡片只有名字，没有 id） */
async function findAttachmentByName(rawName) {
  const name = String(rawName ?? "").trim();
  if (name === "" || name.includes("/") || name.includes("\\") || name.includes("..")) {
    return { ok: false, error: "bad-name", code: 400 };
  }
  const configured = typeof process.env.DSH_HOME === "string" ? process.env.DSH_HOME.trim() : "";
  const home = configured !== "" ? configured : join(homedir(), ".dsh");
  const root = join(home, "attachments", "v1", "files");
  let buckets;
  try {
    buckets = await fsp.readdir(root);
  } catch {
    return { ok: false, error: "not-found", code: 404 };
  }
  for (const bucket of buckets) {
    const bucketDir = join(root, bucket);
    const st = await fsp.stat(bucketDir).catch(() => null);
    if (st === null || !st.isDirectory()) continue;
    const hashes = await fsp.readdir(bucketDir).catch(() => []);
    for (const hash of hashes) {
      const candidate = join(bucketDir, hash, name);
      const fileStat = await fsp.stat(candidate).catch(() => null);
      if (fileStat !== null && fileStat.isFile()) return { ok: true, file: candidate, name };
    }
  }
  return { ok: false, error: "not-found", code: 404 };
}

/**
 * 模块级日志（`createStore` 内部的 logWarn 只在那个作用域可见；
 * 这里的模块级函数如果调它会在错误分支抛 ReferenceError，反而把宿主带崩）。
 */
function logWarn(message) {
  try {
    console.warn(message);
  } catch {}
}

/**
 * 用**电脑上的默认程序**打开这个附件。
 * Windows 上 `cmd /c start "" <file>` 才会走文件关联（直接 spawn 文件打不开）；
 * 空字符串是窗口标题位，不能省。
 */
async function openOnDesktop(resolved) {
  if (resolved.ok !== true) return resolved;
  const file = resolved.file;
  try {
    if (process.platform === "win32") {
      // 用 verbatim 参数自己拼命令行：Node 默认会把我们加的引号再转义一次，cmd 拿到的是字面 \"…\"。
      // 标题位必须是字面 ""（不是空串），路径整体加引号，否则含 & 的文件名会被 cmd 当命令分隔符。
      const child = spawn("cmd.exe", ["/c", "start", '""', `"${file}"`], {
        detached: true, stdio: "ignore", windowsHide: true, windowsVerbatimArguments: true
      });
      child.on("error", () => logWarn("dsh-to-phone: 默认程序启动失败（cmd.exe）"));
      child.unref();
    } else if (process.platform === "darwin") {
      const child = spawn("open", [file], { detached: true, stdio: "ignore" });
      child.on("error", () => logWarn("dsh-to-phone: 默认程序启动失败（open）"));
      child.unref();
    } else {
      const child = spawn("xdg-open", [file], { detached: true, stdio: "ignore" });
      child.on("error", () => logWarn("dsh-to-phone: 默认程序启动失败（xdg-open）"));
      child.unref();
    }
    return { ok: true, name: resolved.name };
  } catch (error) {
    return { ok: false, error: "open-failed", code: 500 };
  }
}

/** 读文件流回响应；`error` 事件必须接住（否则会冒到进程级让 dsh 退出） */
function pipeFile(res, file, options) {
  const stream = createReadStream(file, options);
  stream.on("error", (error) => {
    logWarn(`dsh-to-phone: 读文件失败 ${String(error && error.message || error)}`);
    res.destroy();
  });
  // 客户端提前断开（视频抽首帧后立刻 remove 就是这条）时必须销毁读流，否则 fd 一直开着
  res.on("close", () => {
    stream.destroy();
  });
  stream.pipe(res);
}

/** 给返回的小页面做个转义（文件名里可能有 `<` 之类） */
function escapeHtml(text) {
  const map = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" };
  return String(text ?? "").replace(/[&<>"']/g, (ch) => map[ch]);
}

/**
 * 解百分号编码。**非法编码（如 `%FF`）必须返回 undefined 而不是抛异常** ——
 * 抛出去会冒到 dsh 的 uncaughtException，整个 dsh web 进程会退出。
 */
function safeDecode(raw) {
  try {
    return decodeURIComponent(raw);
  } catch {
    return undefined;
  }
}

/**
 * 把 `DSH_HOME/attachments/v1/files/<前两位>/<sha256>/<文件名>` 里的文件流回去。
 *
 * 三条纪律：
 *  ① 只认 **64 位十六进制** 的 attachmentId（挡路径穿越）；
 *  ② 目录里取**第一个普通文件**（附件目录是"一 hash 一目录"，落盘时的显示名在里面）；
 *  ③ 支持 `Range`（视频拖动进度条要 206；不支持的话 Safari/Chrome 可能整段重下）。
 */
async function serveAttachment(req, res, rawId) {
  const id = String(rawId ?? "").trim().toLowerCase().replace(/^sha256:/, "");
  if (!/^[0-9a-f]{64}$/.test(id)) {
    sendJson(res, 400, { ok: false, error: "bad-attachment-id" });
    return;
  }
  const configured = typeof process.env.DSH_HOME === "string" ? process.env.DSH_HOME.trim() : "";
  const home = configured !== "" ? configured : join(homedir(), ".dsh");
  const dir = join(home, "attachments", "v1", "files", id.slice(0, 2), id);
  let names;
  try {
    names = await fsp.readdir(dir);
  } catch {
    sendJson(res, 404, { ok: false, error: "not-found" });
    return;
  }
  let file = "";
  for (const one of names) {
    if (one.startsWith(".")) continue;
    const candidate = join(dir, one);
    const st = await fsp.stat(candidate).catch(() => null);
    if (st !== null && st.isFile()) {
      file = candidate;
      break;
    }
  }
  if (file === "") {
    sendJson(res, 404, { ok: false, error: "not-found" });
    return;
  }
  await streamFile(req, res, file);
}

/** 把一个文件流回去（Range / download / CORS 都在这里；`serveAttachment` 与按名读共用） */
async function streamFile(req, res, file) {
  const stat = await fsp.stat(file);
  const type = MEDIA_TYPES[extname(file).toLowerCase()] ?? "application/octet-stream";
  const leaf = file.split(/[\\/]/).pop() ?? "file";
  // `?download=1` ⇒ 让浏览器**存盘**（附一个像样的文件名）；否则 inline（能预览/播放）
  const wantsDownload = /(?:^|[?&])download=1(?:&|$)/.test(typeof req.url === "string" ? req.url : "");
  const headers = {
    "content-type": type,
    "accept-ranges": "bytes",
    "cache-control": "private, max-age=3600",
    "content-disposition": `${wantsDownload ? "attachment" : "inline"}; filename*=UTF-8''${encodeURIComponent(leaf)}`,
    // 网页端要用 <video crossOrigin> + canvas 抽首帧做缩略图，必须允许跨源读
    "access-control-allow-origin": "*"
  };
  const range = typeof req.headers.range === "string" ? req.headers.range : "";
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (match !== null && stat.size > 0) {
    const startRaw = match[1];
    const endRaw = match[2];
    let start = startRaw === "" ? Math.max(0, stat.size - Number(endRaw || 0)) : Number(startRaw);
    let end = endRaw === "" ? stat.size - 1 : Math.min(Number(endRaw), stat.size - 1);
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start) {
      res.writeHead(416, { "content-range": `bytes */${String(stat.size)}` });
      res.end();
      return;
    }
    headers["content-length"] = String(end - start + 1);
    headers["content-range"] = `bytes ${String(start)}-${String(end)}/${String(stat.size)}`;
    res.writeHead(206, headers);
    if (req.method === "HEAD") {
      res.end();
      return;
    }
    pipeFile(res, file, { start, end });
    return;
  }
  headers["content-length"] = String(stat.size);
  res.writeHead(200, headers);
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  pipeFile(res, file);
}
/** 可测试的模块状态：测试直接建 store 起临时口，apply 只做接线。 */
const internals = { store: null };

// ---- 小工具 ---------------------------------------------------------------

/**
 * 登记手机 SSH 公钥：把公钥交给提权脚本，由它在电脑上弹 UAC 并写入授权文件。
 * 只在电脑前有人点“是”时才会成功。
 */
function registerSshPublicKey(publicKey) {
  return new Promise((resolve) => {
    try {
      const localAppData = process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
      const helper = join(localAppData, "dsh-phone", "register-phone-key.ps1");
      if (!existsSync(helper)) {
        resolve({ status: 503, body: { ok: false, error: "helper-missing" } });
        return;
      }
      const tempDir = process.env.TEMP ?? join(homedir(), "AppData", "Local", "Temp");
      const stamp = String(Date.now());
      const keyFile = join(tempDir, `dsh-phone-key-${stamp}.pub`);
      const resultFile = join(tempDir, `dsh-phone-key-${stamp}.result.json`);
      writeFileSync(keyFile, publicKey + "\n", "utf8");
      const command = `Start-Process -FilePath powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${helper}','-KeyFile','${keyFile}','-ResultFile','${resultFile}'`;
      const child = spawn("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], {
        windowsHide: true
      });
      child.on("error", () => resolve({ status: 500, body: { ok: false, error: "spawn-failed" } }));
      child.on("exit", () => {
        // UAC 提权进程可能在父进程退出后才写结果：轮询等一会儿，别立刻判失败
        const startedAt = Date.now();
        const poll = () => {
          try {
            const parsed = JSON.parse(readFileSync(resultFile, "utf8").replace(/^\uFEFF/, ""));
            resolve({ status: parsed.ok === true ? 200 : 403, body: parsed });
            return;
          } catch {
            if (Date.now() - startedAt > 12000) {
              resolve({ status: 403, body: { ok: false, error: "denied-or-failed" } });
              return;
            }
            setTimeout(poll, 250);
          }
        };
        poll();
      });
    } catch (error) {
      resolve({ status: 500, body: { ok: false, error: String((error && error.message) || error) } });
    }
  });
}
function sendJson(res, status, body) {
  res.writeHead(status, JSON_HEADERS);
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        chunks.length = 0;
        req.destroy();
        resolve(null);
        return;
      }
      chunks.push(chunk);
    });
    req.on("error", () => resolve(null));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      if (text === "") return resolve({});
      try {
        const parsed = JSON.parse(text);
        resolve(parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {});
      } catch {
        resolve({});
      }
    });
  });
}

function clampText(value, max) {
  if (typeof value !== "string") return "";
  // 去掉控制字符（换行会污染日志与界面），再夹长度。
  return value.replace(/[\u0000-\u001f\u007f]/gu, " ").trim().slice(0, max);
}

function isLoopbackIpv4(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4) return false;
  const octets = parts.map((part) => Number(part));
  if (octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) return false;
  return octets[0] === 127;
}

/** 是否落在 Tailscale 的 CGNAT 共享地址段 `100.64.0.0/10`。 */
function isTailnetIpv4(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4) return false;
  const octets = parts.map((part) => Number(part));
  if (octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) return false;
  if (octets[0] !== TAILNET_FIRST[0]) return false;
  return octets[1] >= TAILNET_FIRST[1] && octets[1] <= TAILNET_LAST[1];
}

/** 归一化一个来源地址（剥掉 IPv6 方括号与 `%zone`，并把 IPv4-mapped 还原成点分四段）。 */
function normalizeSource(remoteAddress) {
  if (typeof remoteAddress !== "string" || remoteAddress === "") return { ip: "", v4: null };
  let ip = remoteAddress.trim().toLowerCase();
  if (ip.startsWith("[") && ip.endsWith("]")) ip = ip.slice(1, -1);
  const zone = ip.indexOf("%");
  if (zone !== -1) ip = ip.slice(0, zone);
  if (ip.includes(".")) return { ip, v4: ip.startsWith("::ffff:") ? ip.slice(7) : ip };
  return { ip, v4: null };
}

/**
 * 探测本机 tailnet 地址：优先接口名含 `tailscale` 的，其次地址落在 `100.64.0.0/10` 的。
 * @returns {string|null} 点分四段的地址；探测不到返回 null（调用方据此**不启动**监听）。
 */
function findTailnetAddress(interfaces = networkInterfaces()) {
  if (interfaces === null || typeof interfaces !== "object") return null;
  const byCgnat = [];
  for (const [ifName, records] of Object.entries(interfaces)) {
    const named = String(ifName).toLowerCase().includes("tailscale");
    for (const record of Array.isArray(records) ? records : []) {
      if (record === null || typeof record !== "object") continue;
      if (record.family !== "IPv4" && record.family !== 4) continue;
      if (record.internal === true) continue;
      const address = typeof record.address === "string" ? record.address : "";
      if (!isTailnetIpv4(address)) continue;
      if (named) return address;
      byCgnat.push(address);
    }
  }
  return byCgnat.length > 0 ? byCgnat[0] : null;
}

/** cookie 名 = `dsh-auth-` + base64url(sha256(authority))，与 client-connection :284-286 一致。 */
function cookieNameForAuthority(authority) {
  const digest = createHash("sha256").update(authority).digest().toString("base64");
  return `dsh-auth-${digest.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "")}`;
}

function randomToken() {
  return randomBytes(24).toString("base64url");
}

// ---- store ---------------------------------------------------------------

/**
 * 没有审批弹窗，所以没有 pending 状态机：一次 `POST /pair/claim` 直接签发，
 * 用一次性 token 换 `set-cookie`。凭据**只发一次**，取走后 token 立即作废。
 */
function createStore(options = {}) {
  const port = Number.isInteger(options.port) && options.port >= 0 ? options.port : DEFAULT_PORT;
  const credentialDays = Number.isInteger(options.credentialDays) ? options.credentialDays : DEFAULT_CREDENTIAL_DAYS;
  const dshPort = Number.isInteger(options.dshPort) && options.dshPort > 0 ? options.dshPort : 0;
  const logger = options.logger ?? null;
  const now = typeof options.now === "function" ? options.now : () => Date.now();
  const exchangeImpl = typeof options.exchange === "function" ? options.exchange : null;
  /** 2026-10-20：进程内直接投递（绕过 dsh 的 `session/writer-held` 写句柄独占）。 */
  const injectPrompt = typeof options.injectPrompt === "function" ? options.injectPrompt : null;
  const approvalHub = options.approvalHub ?? null;
  const artifactsApi = options.artifactsApi ?? null;
  const permissionApi = options.permissionApi ?? null;
  const detectTailnet = typeof options.findTailnet === "function" ? options.findTailnet : findTailnetAddress;
  /** 凭据绑定的 authority —— 手机之后直连 dsh 时必须用同一个 Host。 */
  const phoneAuthority = typeof options.phoneAuthority === "string" && options.phoneAuthority !== ""
    ? options.phoneAuthority
    : dshPort > 0 ? `${LOOPBACK_HOST}:${String(dshPort)}` : "";

  /** @type {Map<string, object>} 已签发、等手机取走的凭据；只放内存，重启即清。 */
  const tickets = new Map();
  /** @type {Map<string, number>} 来源 IP → 上次签发时间。 */
  const lastClaimAt = new Map();

  const servers = [];
  const bound = [];
  const bindErrors = [];
  let tailnet = typeof options.tailnetAddress === "string" && options.tailnetAddress !== "" ? options.tailnetAddress : null;
  let started = false;
  let closed = false;
  let reason = "not-started";

  function logWarn(message) {
    try {
      logger?.warn?.(message);
    } catch {}
  }

  function sweep() {
    const at = now();
    for (const [token, ticket] of tickets) {
      if (at >= ticket.expiresAt) {
        tickets.delete(token);
        continue;
      }
      // 已取用的票留一小会儿再删：这样重复取用报的是明确的 already-claimed，
      // 而不是"这条 token 从来不存在"。
      if (ticket.claimed === true && at - ticket.claimedAt >= CLAIM_COOLDOWN_MS) tickets.delete(token);
    }
  }

  /**
   * 只有回环和 **tailnet 段内**（100.64.0.0/10）的来源算"自己人"。
   * 2026-10-19 修正：以前只放行"本机那一个 tailnet 地址"，手机（另一台 tailnet 设备）打进来会被 403 ——
   * 云真机实测手机是 100.119.240.30，`源 100.119.240.30 => false`，App 因此显示"dsh 未启动"。
   * 安全边界本来就是"只有 tailnet 设备能到达这个口"，按整段放行与设计一致。
   */
  function isAllowedSource(remoteAddress) {
    const { ip, v4 } = normalizeSource(remoteAddress);
    if (ip === "") return false;
    if (ip === "::1") return true;
    if (v4 === null) return false;
    if (isLoopbackIpv4(v4)) return true;
    // tailnet 未探测到时不监听，这里也不放行任何 100.x
    if (tailnet !== null && isTailnetIpv4(v4)) return true;
    return false;
  }

  /**
   * 用 dsh 自己的签发能力换一份 cookie：对 `http://127.0.0.1:<dshPort>/?token=…` 发本机 GET，
   * 取回 `set-cookie`。authority 与手机将用的 Host 完全一致。
   */
  async function exchangeDefault() {
    if (dshPort <= 0) return { status: 0, setCookie: null, error: "no-dsh-port" };
    const auth = state.browserAuth;
    if (auth === null || typeof auth.authenticatedUrl !== "function") {
      return { status: 0, setCookie: null, error: "no-browser-auth" };
    }
    let url;
    try {
      url = auth.authenticatedUrl(`http://${LOOPBACK_HOST}:${String(dshPort)}/`);
    } catch (error) {
      return { status: 0, setCookie: null, error: `mint-failed:${error instanceof Error ? error.message : String(error)}` };
    }
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      return { status: 0, setCookie: null, error: "mint-failed:bad-url" };
    }
    const authority = `${LOOPBACK_HOST}:${String(dshPort)}`;
    const response = await new Promise((resolve) => {
      const request = httpRequest(
        {
          host: LOOPBACK_HOST,
          port: dshPort,
          method: "GET",
          path: `${parsed.pathname}${parsed.search}`,
          headers: { host: authority, accept: "*/*" }
        },
        resolve
      );
      request.on("error", () => resolve(null));
      request.end();
    });
    if (response === null) return { status: 0, setCookie: null, error: "exchange-unreachable" };
    const raw = response.headers["set-cookie"];
    const setCookie = Array.isArray(raw) ? raw[0] ?? null : typeof raw === "string" ? raw : null;
    return { status: response.status, setCookie, error: setCookie === null ? "no-set-cookie" : undefined };
  }

  /**
   * 一步到位签发：限速 → 造一次性 token → 立刻铸 cookie → 返回给手机。
   * 返回体里带 token，手机不需要再来一次（`/pair/session` 是给"只想拿 token"的调用方留的）。
   */
  async function issue(source) {
    sweep();
    const at = now();
    const previous = lastClaimAt.get(source);
    if (previous !== undefined && at - previous < CLAIM_COOLDOWN_MS) {
      return { ok: false, code: "rate-limited", retryAfterMs: CLAIM_COOLDOWN_MS - (at - previous) };
    }
    lastClaimAt.set(source, at);
    const token = randomToken();
    const ticket = {
      token,
      source,
      createdAt: at,
      expiresAt: at + credentialDays * DAY_MS,
      claimed: false
    };
    tickets.set(token, ticket);
    const result = typeof exchangeImpl === "function" ? await exchangeImpl(ticket) : await exchangeDefault();
    if (result.setCookie === null || result.setCookie === undefined) {
      tickets.delete(token);
      logWarn(`dsh-to-phone: 铸凭据失败（${String(result.error ?? "unknown")}）来源=${source}`);
      return { ok: false, code: "exchange-failed", detail: String(result.error ?? "") };
    }
    const cookieName = cookieNameForAuthority(phoneAuthority);
    // 只打长度与 authority，绝不打内容。
    logWarn(`dsh-to-phone: 已签发凭据 authority=${phoneAuthority} 来源=${source} cookieBytes=${String(result.setCookie.length)} nameBytes=${String(cookieName.length)}`);
    return {
      ok: true,
      ticket,
      token,
      setCookie: result.setCookie,
      cookieName,
      authority: phoneAuthority,
      expiresAt: ticket.expiresAt,
      credentialLifetimeDays: credentialDays
    };
  }

  /** 用一次性 token 换凭据 —— 只成功一次。 */
  function claim(token) {
    sweep();
    const ticket = tickets.get(typeof token === "string" ? token : "");
    if (ticket === undefined) return { ok: false, code: "unknown-token" };
    if (ticket.claimed === true) return { ok: false, code: "already-claimed" };
    if (now() >= ticket.expiresAt) {
      tickets.delete(ticket.token);
      return { ok: false, code: "expired" };
    }
    ticket.claimed = true;
    ticket.claimedAt = now();
    return { ok: true, ticket };
  }

  /** 限速表里还有凉不掉的记录？ */
  function hasRecentClaim() {
    const at = now();
    for (const [ip, when] of lastClaimAt) {
      if (at - when < CLAIM_COOLDOWN_MS) return true;
      lastClaimAt.delete(ip);
    }
    return false;
  }

  function status() {
    sweep();
    let unredeemed = 0;
    for (const ticket of tickets.values()) if (ticket.claimed !== true) unredeemed += 1;
    return { unredeemed };
  }

  // ---- HTTP ------------------------------------------------------------

  function handle(req, res) {
    const ip = req.socket?.remoteAddress ?? "";
    if (!isAllowedSource(ip)) {
      logWarn(`dsh-to-phone: 拒绝非 tailnet/回环来源 ${ip === "" ? "(unknown)" : ip}`);
      sendJson(res, 403, { ok: false, error: "source-not-allowed" });
      return;
    }
    let url;
    try {
      url = new URL(req.url ?? "/", "http://pair.invalid");
    } catch {
      sendJson(res, 400, { ok: false, error: "bad-request" });
      return;
    }
    const path = url.pathname;
    const method = req.method ?? "GET";

    if (method === "OPTIONS") {
      res.writeHead(204, {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST",
        "access-control-allow-headers": "content-type",
        "access-control-max-age": "600"
      });
      res.end();
      return;
    }

    if (path === `${API_PREFIX}info`) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      const state2 = status();
      sendJson(res, 200, {
        ok: true,
        name,
        version: "0.5.5",
        skipApproval: true,
        needApproval: false,
        credentialLifetimeDays: credentialDays,
        phoneAuthority,
        dshAuthority: phoneAuthority,
        tailnet: tailnet,
        bound,
        unredeemed: state2.unredeemed,
        listenPort: port
      });
      return;
    }


    // **权限查询/切换**（客户 2026-10-22）：只动当前会话的权限预设。
    if (path === `${API_PREFIX}permissions`) {
      if (method !== "GET") return sendJson(res, 405, { ok: false, error: "method" });
      if (permissionApi === null) return sendJson(res, 501, { ok: false, error: "no-permission-service" });
      const sessionId = clampText(url.searchParams.get("sessionId") ?? "", 160);
      const outcome = permissionApi.state(sessionId);
      sendJson(res, outcome.ok === true ? 200 : 400, outcome);
      return;
    }
    if (path === `${API_PREFIX}permissions/set`) {
      if (method !== "POST") return sendJson(res, 405, { ok: false, error: "method" });
      if (permissionApi === null) return sendJson(res, 501, { ok: false, error: "no-permission-service" });
      readBody(req).then((body) => {
        if (body === null) return sendJson(res, 413, { ok: false, error: "body-too-large" });
        const outcome = permissionApi.set(clampText(body.sessionId, 160), clampText(body.value, 80));
        sendJson(res, outcome.ok === true ? 200 : 400, outcome);
      });
      return;
    }

    // **登记手机 SSH 公钥**（首次/重装后；电脑上会弹 UAC）
    if (path === `${API_PREFIX}register-key`) {
      if (method !== "POST") return sendJson(res, 405, { ok: false, error: "method" });
      readBody(req).then(async (body) => {
        if (body === null) return sendJson(res, 413, { ok: false, error: "body-too-large" });
        const key = String(body.publicKey || "").trim();
        if (!/^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+(?: [^\r\n]*)?$/.test(key) || key.length > 4096) {
          return sendJson(res, 400, { ok: false, error: "bad-key" });
        }
        const outcome = await registerSshPublicKey(key);
        sendJson(res, outcome.status, outcome.body);
      });
      return;
    }
    // **审批待处理列表**（手机回前台补拉）
    if (path === `approvals/pending`) {
      if (method !== `GET`) return sendJson(res, 405, { ok: false, error: `method` });
      if (approvalHub === null) return sendJson(res, 501, { ok: false, error: `no-approval-hub` });
      sendJson(res, 200, { ok: true, items: approvalHub.pendingItems() });
      return;
    }

    // **审批诊断**（客户 2026-10-22 现场排查：手机点了不生效）
    if (path === `${API_PREFIX}approvals/debug`) {
      if (method !== "GET") return sendJson(res, 405, { ok: false, error: "method" });
      if (approvalHub === null) return sendJson(res, 501, { ok: false, error: "no-approval-hub" });
      sendJson(res, 200, { ok: true, ...approvalHub.debug() });
      return;
    }

    // **工件列表/内容**（客户 2026-10-23）：只读 .html，手机用 WebView 打开
    if (path === `${API_PREFIX}artifacts`) {
      if (method !== "GET") return sendJson(res, 405, { ok: false, error: "method" });
      if (artifactsApi === null) return sendJson(res, 501, { ok: false, error: "no-artifacts-api" });
      sendJson(res, 200, artifactsApi.list());
      return;
    }
    if (path === `${API_PREFIX}artifact`) {
      if (method !== "GET") return sendJson(res, 405, { ok: false, error: "method" });
      if (artifactsApi === null) return sendJson(res, 501, { ok: false, error: "no-artifacts-api" });
      const html = artifactsApi.read(url.searchParams.get("name") || "");
      if (html === null) return sendJson(res, 404, { ok: false, error: "not-found" });
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      res.end(html);
      return;
    }
    // **在电脑上打开已登录的 dsh 网页**（客户 2026-10-22）：审批的电脑兜底靠它。
    if (path === `${API_PREFIX}desktop/open`) {
      if (method !== "POST" && method !== "GET") return sendJson(res, 405, { ok: false, error: "method" });
      if (dshPort <= 0 || state.browserAuth === null || typeof state.browserAuth.authenticatedUrl !== "function") {
        return sendJson(res, 503, { ok: false, error: "no-browser-auth" });
      }
      let desktopUrl = "";
      try {
        desktopUrl = state.browserAuth.authenticatedUrl(`http://${LOOPBACK_HOST}:${String(dshPort)}/`);
      } catch (error) {
        return sendJson(res, 500, { ok: false, error: "mint-failed" });
      }
      openOnDesktop({ ok: true, name: "dsh web", file: desktopUrl }).then((outcome) => {
        sendJson(res, outcome.ok === true ? 200 : 500, { ok: outcome.ok === true, error: outcome.error });
      });
      return;
    }

    // **用电脑上的默认程序打开**（2026-10-21）：`GET /pair/open/<attachmentId>`。
    // 客户口径："当然要直接打开，还要什么下载"；"视频直接调默认播放器就行"。
    // 视频 ⇒ 默认播放器（这台机器上是 PotPlayer）；PDF ⇒ 浏览器；Office ⇒ Word/Excel。
    if (path.startsWith(`${API_PREFIX}open/`)) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      const openId = safeDecode(path.slice(`${API_PREFIX}open/`.length));
      if (openId === undefined) return sendJson(res, 400, { ok: false, error: "bad-encoding" });
      resolveAttachmentFile(openId)
        .then((resolved) => openOnDesktop(resolved)).then((outcome) => {
        if (outcome.ok !== true) {
          sendJson(res, outcome.code ?? 500, { ok: false, error: outcome.error });
          return;
        }
        const page = "<!doctype html><meta charset=\"utf-8\"><title>已打开</title>" +
          "<body style=\"font:14px/1.6 system-ui;padding:32px\">" +
          "<p>已用电脑上的默认程序打开：<b>" + escapeHtml(outcome.name) + "</b></p>" +
          "<p style=\"color:#888\">这个页面可以直接关掉。</p>";
        res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
        res.end(page);
      }).catch((error) => {
        logWarn(`dsh-to-phone: 打开附件失败 ${String(error && error.message || error)}`);
        if (!res.headersSent) sendJson(res, 500, { ok: false, error: "open-failed" });
      });
      return;
    }

    // **按文件名打开**（2026-10-21）：用户消息里的文件卡片只有名字（`title` 属性），没有 id。
    // 网页那边的点开就走这条；host 在附件库里按叶子名找到那一个再交给默认程序。
    if (path.startsWith(`${API_PREFIX}open-by-name/`)) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      const openName = safeDecode(path.slice(`${API_PREFIX}open-by-name/`.length));
      if (openName === undefined) return sendJson(res, 400, { ok: false, error: "bad-encoding" });
      findAttachmentByName(openName)
        .then((resolved) => openOnDesktop(resolved)).then((outcome) => {
        if (outcome.ok !== true) {
          sendJson(res, outcome.code ?? 500, { ok: false, error: outcome.error });
          return;
        }
        const page = "<!doctype html><meta charset=\"utf-8\"><title>已打开</title>" +
          "<body style=\"font:14px/1.6 system-ui;padding:32px\">" +
          "<p>已用电脑上的默认程序打开：<b>" + escapeHtml(outcome.name) + "</b></p>" +
          "<p style=\"color:#888\">这个页面可以直接关掉。</p>";
        res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
        res.end(page);
      }).catch((error) => {
        logWarn(`dsh-to-phone: 按名打开附件失败 ${String(error && error.message || error)}`);
        if (!res.headersSent) sendJson(res, 500, { ok: false, error: "open-failed" });
      });
      return;
    }


    // **按文件名读**（2026-10-21）：网页里给文件卡片抽首帧做缩略图用（卡片只有名字）。
    if (path.startsWith(`${API_PREFIX}media-by-name/`)) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      const mediaName = safeDecode(path.slice(`${API_PREFIX}media-by-name/`.length));
      if (mediaName === undefined) return sendJson(res, 400, { ok: false, error: "bad-encoding" });
      findAttachmentByName(mediaName)
        .then((resolved) => {
          if (resolved.ok !== true) {
            sendJson(res, resolved.code ?? 404, { ok: false, error: resolved.error });
            return undefined;
          }
          return streamFile(req, res, resolved.file);
        })
        .catch((error) => {
          logWarn(`dsh-to-phone: 按名读附件失败 ${String(error && error.message || error)}`);
          if (!res.headersSent) sendJson(res, 500, { ok: false, error: "media-failed" });
        });
      return;
    }
    // **媒体直读**（2026-10-21）：把附件目录里的**非图片**文件（视频 / 音频 / 文档）流回去。
    // 为什么需要：dsh 的 `session/attachment` 只读图片（`referencedImage` + `readImage`），
    // 网页端拿到非图片附件只有"名字 + 字节数"，**没有任何读取通道** ⇒ 电脑端永远播不了。
    // 有了这个口，浏览器（电脑本机或任何 tailnet 设备）就能直接打开/播放。
    // 用法：`GET /pair/media/<attachmentId>`，attachmentId = `sha256:<64 hex>` 或裸 64 hex。
    if (path.startsWith(`${API_PREFIX}media/`)) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      const mediaId = safeDecode(path.slice(`${API_PREFIX}media/`.length));
      if (mediaId === undefined) return sendJson(res, 400, { ok: false, error: "bad-encoding" });
      serveAttachment(req, res, mediaId).catch((error) => {
        logWarn(`dsh-to-phone: 读附件失败 ${String(error && error.message || error)}`);
        if (!res.headersSent) sendJson(res, 500, { ok: false, error: "media-failed" });
        else res.destroy();
      });
      return;
    }
    // **dsh 中转**（2026-10-18）：手机在 tailnet 上唯一能到的门是这里，而 dsh 只听 127.0.0.1。
    // 插件把 `/pair/dsh/<path>` 原样转给本机 dsh，Host 改回环形式（dsh 的围栏要求），Cookie 原样带过去。
    if (path === `${API_PREFIX}dsh` || path.startsWith(`${API_PREFIX}dsh/`)) {
      const upstreamPath = path.slice(`${API_PREFIX}dsh`.length) || "/";
      // **记下"这是手机上传的"**（客户 2026-10-21 的规则：谁发的谁那侧不给"保存"、另一侧才给）：
      // 手机上传走 `/api/session/uploadFileBinary?sessionId=…&name=<文件名>`（经这里转发），
      // 抓到 `name` 就知道哪些附件是手机那头发来的。
      if (upstreamPath.includes("uploadFileBinary")) {
        const uploaded = url.searchParams.get("name");
        if (typeof uploaded === "string" && uploaded.trim() !== "") {
          markPhoneUpload(uploaded.trim());
        }
      }
      proxyToDsh(req, res, `${upstreamPath}${url.search}`, dshPort);
      return;
    }

    // 手机上传过哪些文件名（网页端据此决定要不要给「保存」）
    if (path === `${API_PREFIX}phone-uploads`) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      res.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
        "access-control-allow-origin": "*"
      });
      res.end(JSON.stringify({ ok: true, names: listPhoneUploads() }));
      return;
    }

    // **进程内投递**（2026-10-20）：`session/prompt` 走 HTTP 会被"写句柄被别的客户端占着"挡掉
    // （`session/writer-held`）。插件和网页端在同一个 dsh 进程里，直接拿活动 agent 追加一条用户消息即可。
    if (path === `${API_PREFIX}prompt`) {
      if (method !== "POST") return sendJson(res, 405, { ok: false, error: "method" });
      if (injectPrompt === null) return sendJson(res, 501, { ok: false, error: "no-injector" });
      readBody(req).then(async (body) => {
        if (body === null) return sendJson(res, 413, { ok: false, error: "body-too-large" });
        const sessionId = clampText(body.sessionId, 160);
        const text = clampText(body.text, 8000);
        if (sessionId === "" || text === "") {
          return sendJson(res, 400, { ok: false, error: "session-and-text-required" });
        }
        try {
          const outcome = await injectPrompt(sessionId, text);
          sendJson(res, outcome.ok === true ? 200 : 409, outcome);
        } catch (error) {
          logWarn(`dsh-to-phone: 进程内投递失败 ${String(error && error.message || error)}`);
          sendJson(res, 500, { ok: false, error: "inject-failed", message: String(error && error.message || error) });
        }
      });
      return;
    }

    if (path === `${API_PREFIX}claim`) {
      if (method !== "POST") return sendJson(res, 405, { ok: false, error: "method" });
      readBody(req).then(async (body) => {
        if (body === null) return sendJson(res, 413, { ok: false, error: "body-too-large" });
        // 手机可以声明它之后要用的 authority；对不上就直接说清楚，免得交付一个"看着能用其实 401"的 cookie。
        const requested = clampText(body.authority, 80);
        if (requested !== "" && requested !== phoneAuthority) {
          sendJson(res, 409, {
            ok: false,
            error: "authority-mismatch",
            expectedAuthority: phoneAuthority,
            message: `凭据只能绑到 ${phoneAuthority}；手机之后直连 dsh 时请用同一个 Host`
          });
          return;
        }
        const outcome = await issue(ip);
        if (outcome.ok !== true) {
          const status2 = outcome.code === "rate-limited" ? 429 : 502;
          sendJson(res, status2, {
            ok: false,
            error: outcome.code,
            retryAfterMs: outcome.retryAfterMs ?? 0,
            detail: outcome.detail ?? "",
            message: outcome.code === "rate-limited" ? "刚刚已经签过一份，稍候再试" : "电脑侧没能签出凭据（dsh web 是否在跑？）"
          });
          return;
        }
        sendJson(res, 200, {
          ok: true,
          cookieName: outcome.cookieName,
          cookieValue: outcome.setCookie,
          authority: outcome.authority,
          issuedAt: outcome.ticket.createdAt,
          expiresAt: outcome.expiresAt,
          credentialLifetimeDays: outcome.credentialLifetimeDays,
          credentialLifetimeMs: outcome.expiresAt - outcome.ticket.createdAt
        });
      });
      return;
    }

    if (path === `${API_PREFIX}session`) {
      if (method !== "GET" && method !== "HEAD") return sendJson(res, 405, { ok: false, error: "method" });
      const outcome = claim(url.searchParams.get("t") ?? "");
      if (outcome.ok !== true) {
        sendJson(res, 410, { ok: false, error: outcome.code });
        return;
      }
      sendJson(res, 200, {
        ok: true,
        cookieName: cookieNameForAuthority(phoneAuthority),
        authority: phoneAuthority,
        expiresAt: outcome.ticket.expiresAt
      });
      return;
    }

    sendJson(res, 404, { ok: false, error: "not-found" });
  }

  function startServer(listeningHost) {
    return new Promise((resolve) => {
      const server = createServer(handle);
      // WebSocket 升级（dsh 的 remote.mux）也走本插件中转
      server.on("upgrade", (req, socket, head) => {
        // 裸 socket 必须先挂 error：对端在响应写出前 RST 会触发未捕获 ECONNRESET，
        // dsh 的 fail-loud 会直接 process.exit(1)（任何能到本口的客户端都能触发）
        socket.on("error", () => {
          try {
            socket.destroy();
          } catch {}
        });
        const source = req.socket?.remoteAddress ?? "";
        // 升级请求不经过 handle()，来源闸门必须在这里再判一次（否则只靠"只 bind 回环+tailnet"兜底）
        if (!isAllowedSource(source)) {
          logWarn(`dsh-to-phone: 拒绝非 tailnet/回环来源的 WS 升级 ${source === "" ? "(unknown)" : source}`);
          try {
            socket.end(httpHead(403, "Forbidden", { "content-type": "text/plain; charset=utf-8" }));
          } catch {}
          return;
        }
        const u = req.url || "/";
        let upgradePath = "";
        try {
          upgradePath = new URL(u, "http://pair.invalid").pathname;
        } catch {
          upgradePath = "";
        }
        if (upgradePath === `${API_PREFIX}approvals` && approvalHub !== null) {
          approvalHub.handleUpgrade(req, socket, head);
          return;
        }
        if (u.startsWith(`${API_PREFIX}dsh`)) {
          proxyUpgradeToDsh(req, socket, head, dshPort);
          return;
        }
        try {
          socket.end(httpHead(404, "Not Found", { "content-type": "text/plain; charset=utf-8" }));
        } catch {}
      });
      server.on("error", (error) => {
        bindErrors.push(`${listeningHost}:${String(error.code ?? error.message)}`);
        resolve(false);
      });
      server.listen(port, listeningHost, () => {
        servers.push(server);
        const address = server.address();
        bound.push(`${listeningHost}:${String(address !== null && typeof address === "object" ? address.port : port)}`);
        resolve(true);
      });
    });
  }

  /**
   * 只绑回环 + tailnet。探测不到 tailnet ⇒ **整体不启动**（不降级、不绑 0.0.0.0）。
   * 两个地址都绑不上也视为不启动。
   */
  async function listen() {
    if (closed) return false;
    if (tailnet === null) {
      try {
        tailnet = detectTailnet();
      } catch {
        tailnet = null;
      }
    }
    if (tailnet === null || isTailnetIpv4(tailnet) === false) {
      reason = "no-tailnet-address";
      logWarn("dsh-to-phone: 没探测到 tailnet 地址（100.64.0.0/10，接口名含 Tailscale），配对监听口**不启动**（不会降级成开放局域网）");
      return false;
    }
    const loopbackOk = await startServer(LOOPBACK_HOST);
    const tailnetOk = await startServer(tailnet);
    started = loopbackOk || tailnetOk;
    if (!started) {
      reason = `bind-failed:${bindErrors.join(",")}`;
      logWarn(`dsh-to-phone: 绑定失败，配对监听口未启动（${bindErrors.join(", ")}）`);
      return false;
    }
    reason = "listening";
    logWarn(`dsh-to-phone: 配对口已监听 ${bound.join(", ")}（tailnet=${tailnet}，凭据 authority=${phoneAuthority}）`);
    if (!loopbackOk || !tailnetOk) logWarn(`dsh-to-phone: 部分绑定失败：${bindErrors.join(", ")}`);
    return true;
  }

  function close() {
    closed = true;
    started = false;
    for (const server of servers) {
      try {
        server.close();
      } catch {}
    }
    servers.length = 0;
    tickets.clear();
    lastClaimAt.clear();
  }

  const state = {
    port,
    dshPort,
    credentialDays,
    phoneAuthority,
    bindHosts: () => [LOOPBACK_HOST, ...(tailnet === null ? [] : [tailnet])],
    /** 由 apply / 测试注入的浏览器签发能力（dsh 的 `ctx.connection.browserAuth`）。 */
    browserAuth: options.browserAuth ?? null,
    get tailnet() {
      return tailnet;
    },
    get listening() {
      return started && !closed;
    },
    get reason() {
      return reason;
    },
    get addresses() {
      return [...bound];
    },
    get bindErrors() {
      return [...bindErrors];
    },
    listen,
    close,
    handle,
    issue,
    claim,
    status,
    hasRecentClaim,
    isAllowedSource,
    cookieNameForAuthority
  };
  return state;
}

// ---- 插件接线 --------------------------------------------------------------

/** 从活上下文里取 dsh 的签发能力；取不到就明确报错，绝不悄悄降级。 */
function resolveBrowserAuth(ctx, options) {
  if (options.browserAuth != null) return options.browserAuth;
  const direct = ctx?.connection?.browserAuth;
  if (direct != null) return direct;
  // 兜底：Service 实例也注册在自己身上（cordis Service 构造里 `ctx.reflect.provide(name, self)`），
  // 所以 `ctx.get("connection")` 拿到的就是同一个实例。
  for (const probe of [
    () => ctx?.get?.("connection"),
    () => ctx?.root?.get?.("connection")
  ]) {
    try {
      const auth = probe()?.browserAuth;
      if (auth != null) return auth;
    } catch {}
  }
  return null;
}

/**
 * **只在指定的那台 dsh 上绑配对口**（2026-10-18 加的闸）。
 *
 * 为什么需要：同一台电脑上可能同时跑着多个 dsh web 实例（例如手机要连的 `:3080` 与
 * 另开的 `:3090`），它们**用同一份 profile** ⇒ 都会加载本插件；而配对口端口是固定 18099，
 * **谁先绑上，谁就是手机的配对口**。
 * 一旦被别的实例抢走，`/pair/info` 报的 `phoneAuthority` 就是那台实例的 authority
 * （实测踩过：拿到 `127.0.0.1:3090` 的 cookie，打 3080 的 `/api` 全 401）。
 *
 * 配置：profile 的插件 config 里写 `phonePort: 3080`；不写则不设闸（默认行为不变，测试也不受影响）。
 */
function rejectIfNotPhoneInstance(ctx, options) {
  const want = Number.isInteger(options.phonePort) ? options.phonePort : 0;
  if (want <= 0) {
    return false;
  }
  const hostPort = Number.isInteger(ctx?.webServer?.port) ? ctx.webServer.port : 0;
  if (hostPort === want) {
    return false;
  }
  ctx.logger?.info?.(`dsh-to-phone: 这台 dsh 在 :${hostPort}，不是手机要连的 :${want} ⇒ 不绑配对口`);
  return true;
}

/**
 * 2026-10-20：**进程内投递**。
 * 为什么：dsh 每场会话只允许一个写句柄，网页端开着那场会话时，手机走 HTTP `session/prompt`
 * 会被 `session/writer-held` 拒掉（HTTP 200 + 错误 body）。插件和网页端同在一个 dsh 进程，
 * 直接取到活动 agent（`ctx.get("agents").get(id)`）追加一条 user 消息即可，绕过 HTTP 层的独占检查。
 */
function createPromptInjector(ctx) {
  let llm = null;
  const llmModulePath = () => {
    // process.argv[1] = <...>\@deepseek-ai\dsh\lib\bin.js ⇒ 往上两级就是 dsh 包根
    const dshLib = dirname(process.argv[1] ?? "");
    const dshRoot = dirname(dshLib);
    return join(dshRoot, "node_modules", "@deepseek-ai", "dsh-llm", "lib", "index.js");
  };
  return async function injectPrompt(sessionId, text) {
    const agents = ctx?.get?.("agents");
    const agent = agents?.get?.(sessionId);
    if (agent === undefined || agent === null) {
      return { ok: false, reason: "no-live-agent", sessionId };
    }
    if (llm === null) {
      llm = await import(pathToFileURL(llmModulePath()).href);
    }
    const message = llm.createUserMessage({
      content: [{ type: "text", text }],
      source: { kind: "user", rpcId: `pair-${String(Date.now())}` }
    });
    agent.followup(message);
    return { ok: true, sessionId };
  };
}

function apply(ctx, options = {}) {  const dshPort = Number.isInteger(ctx?.webServer?.port) ? ctx.webServer.port : 0;
  if (rejectIfNotPhoneInstance(ctx, options)) {
    return;
  }
  const browserAuth = resolveBrowserAuth(ctx, options);
  if (browserAuth === null) {
    ctx.logger?.warn?.("dsh-to-phone: 取不到 connection.browserAuth，配对口不会启动");
    return;
  }
  const permissionApi = createPermissionApi(ctx);
  const artifactsApi = createArtifactsApi(resolveArtifactsDir(options.artifactsDir));
  const approvalHub = createApprovalHub(ctx, logWarn, (sessionId) => {
    const state = permissionApi.state(sessionId);
    return state.ok === true && state.current === "auto";
  });
  const store = createStore({
    port: Number.isInteger(options.port) ? options.port : DEFAULT_PORT,
    credentialDays: Number.isInteger(options.credentialDays) ? options.credentialDays : DEFAULT_CREDENTIAL_DAYS,
    dshPort,
    browserAuth,
    permissionApi,
    artifactsApi,
    approvalHub,
    logger: ctx.logger,
    phoneAuthority: typeof options.phoneAuthority === "string" ? options.phoneAuthority : undefined,
    tailnetAddress: typeof options.tailnetAddress === "string" ? options.tailnetAddress : undefined,
    findTailnet: typeof options.findTailnet === "function" ? options.findTailnet : undefined,
    exchange: typeof options.exchange === "function" ? options.exchange : null,
    injectPrompt: typeof options.injectPrompt === "function" ? options.injectPrompt : createPromptInjector(ctx),
    now: typeof options.now === "function" ? options.now : null
  });
  internals.store = store;
  // 网页端要按"自己这个实例"的配对端口访问 host 半边（以前写死 18099，3090 的网页会问错实例）
  const clientConfigPort = Number.isInteger(options.port) ? options.port : DEFAULT_PORT;
  ctx.effect(() => {
    const disposeRoute = ctx.webServer.register({
      kind: "exact",
      path: "/pair/client-config",
      handler: (req, res) => {
        sendJson(res, 200, { ok: true, port: clientConfigPort });
      }
    });
    store.listen();
    return () => {
      if (internals.store === store) internals.store = null;
      store.close();
      if (typeof disposeRoute === "function") {
        disposeRoute();
      }
    };
  }, "dsh-to-phone: 配对监听口");
}

export {
  DEFAULT_PORT,
  LOOPBACK_HOST,
  apply,
  cookieNameForAuthority,
  createStore,
  findTailnetAddress,
  inject,
  internals,
  isTailnetIpv4,
  name,
  normalizeSource
};
/**
 * 拼一段 HTTP 响应头（给升级 socket 用）。
 * 升级请求没法走 `res`，401/403/502 只能自己写成报文 —— 不写手机就一直等（这是 bug #1 的根因）。
 */
function httpHead(statusCode, statusMessage, headers) {
  const lines = [`HTTP/1.1 ${String(statusCode)} ${statusMessage === undefined ? "" : statusMessage}`];
  for (const [key, value] of Object.entries(headers ?? {})) {
    if (value === undefined) continue;
    if (Array.isArray(value)) {
      for (const one of value) lines.push(`${key}: ${String(one)}`);
    } else {
      lines.push(`${key}: ${String(value)}`);
    }
  }
  return `${lines.join("\r\n")}\r\n\r\n`;
}

/**
 * 转发前把 `Host` 改回环（dsh 围栏要求），`Origin` 若有也改成同一个回环 authority
 * （dsh 校验 `new URL(origin).host === host`；原样转发 tailnet 的 Origin 会被 403，实测过）。
 */
function loopbackHeaders(req, dshPort) {
  const headers = Object.assign({}, req.headers);
  const authority = `${LOOPBACK_HOST}:${String(dshPort)}`;
  headers.host = authority;
  if (headers.origin !== undefined) headers.origin = `http://${authority}`;
  return headers;
}

/** 把一次请求转发给本机 dsh（来源闸门已在 handle 里过了） */
function proxyToDsh(req, res, targetPath, dshPort) {
  const upstream = httpRequest(
    { host: LOOPBACK_HOST, port: dshPort, method: req.method, path: targetPath, headers: loopbackHeaders(req, dshPort) },
    (up) => {
      res.writeHead(up.statusCode || 502, Object.assign({}, up.headers));
      up.pipe(res);
    }
  );
  upstream.on("error", () => {
    if (!res.headersSent) sendJson(res, 502, { ok: false, error: "dsh-unreachable" });
    else res.destroy();
  });
  req.pipe(upstream);
}

/**
 * WebSocket 升级也转发（dsh 的 `session/follow` 走 `remote.mux`）。
 *
 * 三条出口都必须给手机一个明确答复：
 *  - `upgrade`  → 101（转发头与后续字节）；
 *  - `response` → dsh 回的不是 101（401 凭据失效 / 403 围栏拒绝）：**原样把状态回给手机**，
 *    否则客户端永远等不到响应（`RawWs` 会一直挂在"连接中"）；
 *  - `error`    → 502（dsh 没起来 / 端口不通）。
 * 两端 socket 都挂 `error`：手机突然断网时不能让异常冒到 dsh web 进程（未捕获 'error' 会带崩整个进程）。
 */
function proxyUpgradeToDsh(req, socket, head, dshPort) {
  const upstream = httpRequest({
    host: LOOPBACK_HOST,
    port: dshPort,
    method: "GET",
    path: req.url.replace(`${API_PREFIX}dsh`, "") || "/",
    headers: loopbackHeaders(req, dshPort)
  });
  let answered = false;

  socket.on("error", () => {
    try {
      upstream.destroy();
    } catch {}
    socket.destroy();
  });

  upstream.on("response", (up) => {
    answered = true;
    socket.write(httpHead(up.statusCode || 502, up.statusMessage, up.headers));
    up.pipe(socket);
    up.on("end", () => socket.end());
    up.on("error", () => socket.destroy());
  });

  upstream.on("upgrade", (upRes, upSocket, upHead) => {
    answered = true;
    socket.write(httpHead(101, upRes.statusMessage || "Switching Protocols", upRes.headers));
    if (upHead && upHead.length) socket.write(upHead);
    if (head && head.length) upSocket.write(head);
    socket.on("end", () => {
      // 手机关掉自己那一端（只发 FIN）时，升级过的 socket 不会自动 close ⇒ 必须主动拆上游，
      // 否则每重连一次就在 dsh 侧留一条死连接。
      upSocket.destroy();
      socket.end();
    });
    socket.on("close", () => upSocket.destroy());
    upSocket.on("error", () => socket.destroy());
    upSocket.on("close", () => socket.destroy());
    upSocket.pipe(socket).pipe(upSocket);
  });

  upstream.on("error", () => {
    if (!answered) socket.end(httpHead(502, "Bad Gateway", { "content-type": "text/plain; charset=utf-8" }));
    else socket.destroy();
  });

  upstream.end();
}





