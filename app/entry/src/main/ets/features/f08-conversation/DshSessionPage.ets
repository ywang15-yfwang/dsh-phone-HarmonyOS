import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DshApiClient, DshApiResult } from '../../services/DshApiClient';
import {
  PAGE_MAX_MESSAGES, PageOutcome, PageRecord, buildSessionListAltArgs, buildSessionListArgs,
  buildSessionPageArgs, buildSessionProjectionsArgs, clipLines, countVerbatim, parseCursorFromList,
  parseCursorFromProjections, parseSessionPage
} from './SessionPageModel';
import {
  buildPromptArgs, buildPromptArgsRich, buildPromptArgsWithFile, buildPromptArgsWithImage,
  buildSessionCreateArgs, parseAccepted, parseSessionId, ImagePayload
} from '../f06-typing/DshSessionProtocol';
import { NetTarget, requestText } from '../../services/net/DshNet';
import { pairingVault } from '../f03-connect/PairingVault';
import { activeProfile } from '../../services/ProfileStore';

const DOMAIN: number = 0xD001;
const TAG: string = 'F8SESSION';

/**
 * F11（AC-16）：**打字输入送进那场会话 ＋ 读回那场对话**。
 *
 * 三条口径：
 *  ① 送出与读回都走 **普通 `/api` HTTP**（`session/prompt` / `session/page`）；
 *     **不用 `session/search`** —— `#7` 实测本部署把 session-query 索引关成 `openAt:"never"`；
 *  ② **一字不差**靠 `countVerbatim(userTexts, needle)`：只有用户侧事件里**逐字**出现该文本才计数（不做模糊匹配）；
 *  ③ 助手回应（AC-16 ③）若**没取到**就如实空着 ⇒ 界面显示"未取到"，**不许写成通过**。
 */

export interface SessionEnsure {
  ok: boolean;
  sessionId: string;
  detail: string;
}

/**
 * 按路径取（或创建）工作区，返回它的 `workspaceId`（失败返回空串）。
 * 官方接口：`workspace/create`，args `{"request":{"path":"<电脑上的绝对路径>"}}`，
 * 结果 `{workspace:{workspaceId,…}, created:boolean}`（已存在时 `created:false`）。
 */
async function ensureWorkspace(client: DshApiClient, cwd: string): Promise<string> {
  const args: string = `{"request":{"path":${JSON.stringify(cwd)}}}`;
  const made: DshApiResult = await client.rpc('workspace/create', args);
  if (!made.apiOk) {
    hilog.warn(DOMAIN, TAG, 'workspace/create 失败 HTTP %{public}d，退回按 cwd 建会话', made.code);
    return '';
  }
  try {
    const parsed = JSON.parse(made.body) as Record<string, Object>;
    const result = parsed['result'] as Record<string, Object>;
    const value = result['value'] as Record<string, Object>;
    const ws = value['workspace'] as Record<string, Object>;
    const id = ws['workspaceId'];
    return typeof id === 'string' ? id as string : '';
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'workspace/create 响应解析失败');
    return '';
  }
}

/**
 * 确保有一场会话（没有就建一场）。
 *
 * `cwd`（客户 2026-10-17 的坑）：**必须把"当前会话的工作区"传过去**，否则 dsh 用它自己的默认工作区建，
 * 那场新会话就落在**别的项目**里 —— 电脑侧侧栏看不到（客户以为"没建会话"）。
 *
 * **官方口径（2026-10-17 晚，实证）**：只给 `cwd` 建的会话**不会**挂进工作区（dsh 源码
 * `dsh-api-session-controller/lib/index.js` 的 `create()`：只有传 `workspaceId` 才会 `workspace.attachSession()`；
 * `workspaceId` 与 `cwd` **不能同时传**，否则 bad-request）。所以按官方两步走：
 *   ① `workspace/create {path: cwd}` —— 按路径取（或创建）工作区，拿到 `workspaceId`（已存在时 `created:false`，
 *      实测对 dsh 的工作区目录返回的就是侧栏那个工作区）；
 *   ② `session/create {workspaceId}` —— 建出来的会话**当场就在那个工作区里**（实测 sessionIds 里马上有它）。
 * 这样**不需要插件**做"挂工作区"。
 */
export async function ensureSession(client: DshApiClient, cwd: string = ''): Promise<SessionEnsure> {
  let workspaceId: string = '';
  if (cwd.length > 0) {
    workspaceId = await ensureWorkspace(client, cwd);
  }
  const args: string = workspaceId.length > 0
    ? `{"request":{"workspaceId":${JSON.stringify(workspaceId)}}}`
    : (cwd.length > 0 ? `{"request":{"cwd":${JSON.stringify(cwd)}}}` : buildSessionCreateArgs());
  const created: DshApiResult = await client.rpc('session/create', args);
  const sessionId: string = parseSessionId(created.body);
  const ok: boolean = created.apiOk && sessionId.length > 0;
  return {
    ok: ok,
    sessionId: sessionId,
    detail: ok
      ? `会话已就绪（HTTP ${created.code}｜${created.elapsedMs}ms｜长度 ${sessionId.length}）`
      : `会话未建成（HTTP ${created.code}${created.apiError.length > 0 ? `｜${created.apiError}` : ''}）`
  };
}

/** 发消息的等待上限（客户 2026-10-18：10 秒没受理 ⇒ 判"dsh 已断开"，不无限等） */
const SEND_TIMEOUT_MS: number = 10000;

export interface Ac16SendResult {
  ok: boolean;
  accepted: boolean;
  text: string;
  atMs: number;
  elapsedMs: number;
  detail: string;
}

/**
 * 把"文字 ＋ 已上传的文件"送进会话（客户 2026-10-17：手机上选的文件要能发给那场对话）。
 * 文件必须先走 `POST /api/session/uploadFileBinary` 换到 `receiptId`，然后作为
 * `content[]` 里的 `{type:'file', receiptId}` 引用（官方 `session/prompt` 的形状）。
 */
export async function sendTextWithFile(client: DshApiClient, sessionId: string, text: string,
  receiptId: string, fileName: string): Promise<Ac16SendResult> {
  const started: number = Date.now();
  const sent: DshApiResult = await client.rpc('session/prompt',
    buildPromptArgsWithFile(sessionId, text, `req-file-${Date.now()}`, receiptId, fileName), SEND_TIMEOUT_MS);
  const accepted: boolean = parseAccepted(sent.body);
  const ok: boolean = sent.apiOk && accepted;
  return {
    ok: ok,
    accepted: accepted,
    text: text,
    atMs: Date.now(),
    elapsedMs: Date.now() - started,
    detail: ok
      ? `已受理（HTTP ${sent.code}｜${sent.elapsedMs}ms）｜附件：${fileName}`
      : `未被受理（HTTP ${sent.code}${sent.apiError.length > 0 ? `｜${sent.apiError}` : ''}）`
  };
}


/**
 * App 只连用户配置的 dsh 端口，不做跨实例自动打通。
 * 这里只在 dsh 端口 这份 dsh 进程内补投一次；它找不到 agent（会话在别的实例里开着）就算失败，
 * 由界面说明"这场会话正在电脑上使用"。
 */
async function injectViaPlugin(sessionId: string, text: string): Promise<boolean> {
  const host: string = pairingVault.hostOr('');
  if (host.length === 0) {
    return false;
  }
  const target: NetTarget = {
    address: host,
    port: activeProfile().pluginPort,
    hostHeader: `127.0.0.1:${activeProfile().dshPort}`
  };
  const res = await requestText(target, http.RequestMethod.POST, '/pair/prompt',
    JSON.stringify({ sessionId: sessionId, text: text }), 8000);
  hilog.info(DOMAIN, TAG, 'pair/prompt port=%{public}d status=%{public}d body=%{public}s',
    activeProfile().pluginPort, res.statusCode, res.body.slice(0, 160));
  return res.statusCode === 200;
}

export async function sendPlainText(client: DshApiClient, sessionId: string,
  text: string): Promise<Ac16SendResult> {
  const started: number = Date.now();
  const sent: DshApiResult = await client.rpc('session/prompt',
    buildPromptArgs(sessionId, text, `req-ac16-${Date.now()}`), SEND_TIMEOUT_MS);
  const accepted: boolean = parseAccepted(sent.body);
  let ok: boolean = sent.apiOk && accepted;
  let viaInjection: boolean = false;
  if (!ok) {
    // 2026-10-20：真机上"发不出去"要能定位——把状态码、错误、body 头一段打出来
    hilog.warn(DOMAIN, TAG, 'prompt 未被受理 code=%{public}d apiErr=%{public}s body=%{public}s',
      sent.code, sent.apiError, sent.body.slice(0, 200));
    if (sent.apiError.indexOf('writer-held') >= 0) {
      viaInjection = await injectViaPlugin(sessionId, text);
      ok = viaInjection;
    }
  }
  return {
    ok: ok,
    accepted: accepted || viaInjection,
    text: text,
    atMs: Date.now(),
    elapsedMs: Date.now() - started,
    detail: ok
      ? (viaInjection
        ? `已受理（进程内投递，网页端占着写句柄也不影响）｜原文：${text}`
        : `已受理（HTTP ${sent.code}｜${sent.elapsedMs}ms｜accepted:true）｜原文：${text}`)
      : `未被受理（HTTP ${sent.code}${sent.apiError.length > 0 ? `｜${sent.apiError}` : ''}）`
  };
}

/**
 * 发送**多附件**（2026-10-20）：图片内联成 image 块、文件用上传回执，一次提交。
 */
export async function sendRich(client: DshApiClient, sessionId: string, text: string,
  images: ImagePayload[], receipts: string[]): Promise<Ac16SendResult> {
  const started: number = Date.now();
  const sent: DshApiResult = await client.rpc('session/prompt',
    buildPromptArgsRich(sessionId, text, `req-rich-${Date.now()}`, images, receipts), 90000);
  const accepted: boolean = parseAccepted(sent.body);
  const ok: boolean = sent.apiOk && accepted;
  if (!ok) {
    hilog.warn(DOMAIN, TAG, '附件未受理 code=%{public}d apiErr=%{public}s body=%{public}s',
      sent.code, sent.apiError, sent.body.slice(0, 200));
  }
  return {
    ok: ok,
    accepted: accepted,
    text: text,
    atMs: Date.now(),
    elapsedMs: Date.now() - started,
    detail: ok
      ? `已受理（${images.length} 张图 / ${receipts.length} 个文件｜HTTP ${sent.code}｜${sent.elapsedMs}ms）`
      : `未被受理（HTTP ${sent.code}${sent.apiError.length > 0 ? `｜${sent.apiError}` : ''}）`
  };
}

/**
 * 发送**图片**（2026-10-20）：以 `{type:'image', data, mediaType}` 内联提交，
 * 两端（手机/电脑）都会直接显示图，而不是文件名。
 */
export async function sendImage(client: DshApiClient, sessionId: string, text: string,
  dataBase64: string, mediaType: string): Promise<Ac16SendResult> {
  const started: number = Date.now();
  const sent: DshApiResult = await client.rpc('session/prompt',
    buildPromptArgsWithImage(sessionId, text, `req-img-${Date.now()}`, dataBase64, mediaType), 60000);
  const accepted: boolean = parseAccepted(sent.body);
  if (!sent.apiOk || !accepted) {
    hilog.warn(DOMAIN, TAG, '图片未受理 code=%{public}d apiErr=%{public}s body=%{public}s',
      sent.code, sent.apiError, sent.body.slice(0, 200));
  }
  const ok: boolean = sent.apiOk && accepted;
  return {
    ok: ok,
    accepted: accepted,
    text: text,
    atMs: Date.now(),
    elapsedMs: Date.now() - started,
    detail: ok
      ? `已受理（图片内联｜HTTP ${sent.code}｜${sent.elapsedMs}ms）`
      : `未被受理（HTTP ${sent.code}${sent.apiError.length > 0 ? `｜${sent.apiError}` : ''}）`
  };
}

export interface Ac16ReadResult {
  /** 读到 ≥1 条**逐字**含该文本的用户侧事件（AC-16 ② 的 App 侧判据） */
  ok: boolean;
  parsed: boolean;
  pages: number;
  hasMore: boolean;
  /** 读回的用户侧文本原文（`user/message`） */
  userTexts: string[];
  /** 读回的助手侧文本原文（`assistant/message`） */
  assistantTexts: string[];
  /** F5：**按 seq 升序**的完整事件流（含角色来源＝`record.type`），供会话页逐条渲染 */
  records: PageRecord[];
  /** 用户侧事件里**逐字**出现固定文本的次数（AC-16 要 2 次） */
  verbatimCount: number;
  /** dsh 的回应原文（'' = 未取到 ⇒ 界面照实说） */
  replyText: string;
  /** cursor（`session/page` 的 `throughSeq` 上界）是否取到 */
  cursorResolved: boolean;
  /** 取到的 cursor（-1 = 未取到） */
  cursor: number;
  /** cursor 的来源（证据用） */
  cursorVia: string;
  detail: string;
}

/** 读回那场对话（`session/page` 分页；最多翻 `MAX_PAGES` 页，`hasMore` 如实报） */
export const PAGE_READ_MAX_PAGES: number = 3;

export interface CursorResolve {
  /** ≥0 = 该会话当前 seq 上界（`session/page` 的 `throughSeq` 必须 ≤ 它）；-1 = 未取到 */
  cursor: number;
  /** 从哪条路拿到的（证据用）：session/list | session/projections | 未取到 */
  via: string;
}

/**
 * **先问 cursor，再读页**（`#9` 的 bug 就在这一步：发哨兵 `throughSeq` 会被服务端判 `past cursor`）。
 *
 * ⚠️ 三条实测教训叠在这儿（**别再来回翻**）：
 *  - `#9`：服务端原话 `session page through seq N is past cursor 25` ⇒ **`throughSeq` 的上界就是它认的那个 cursor**；
 *  - `#13`：我为了"防取错会话"改成**先用 `session/projections`**；
 *  - `#15`（`qc` 同屏对照）：**那一步是错的** —— `session/projections` 给的 `asOfSeq=5` 与 `session/list` 里**同一场的
 *    `asOfSeq=18` 不一致**，现象就是"**只读到 seq 1–5、还 `hasMore=false`**"（`hasMore` 只表示"还有**更早**的页"，
 *    所以更晚的事件根本进不来）。⇒ **以 `session/list` 的 `projections.asOfSeq` 为准**（它同时就是侧栏显示的那个数，
 *    同一屏两个节点能自洽对照），`session/projections` 只作**兜底**并标明"水位可能不同"。
 */
export async function resolveCursor(client: DshApiClient, sessionId: string): Promise<CursorResolve> {
  const idTail: string = sessionId.length > 12 ? sessionId.substring(sessionId.length - 12) : sessionId;
  // ① 主源：`session/list`（与侧栏同一个数；服务端 `past cursor` 语义也以它为准）
  const listed: DshApiResult = await client.rpc('session/list', buildSessionListArgs());
  const fromList: number = parseCursorFromList(listed.body, sessionId);
  if (fromList >= 0) {
    return {
      cursor: fromList,
      via: `session/list（命中 …${idTail}，asOfSeq=${fromList}，HTTP ${listed.code}）`
    };
  }
  const listedAlt: DshApiResult = await client.rpc('session/list', buildSessionListAltArgs());
  const fromListAlt: number = parseCursorFromList(listedAlt.body, sessionId);
  if (fromListAlt >= 0) {
    return {
      cursor: fromListAlt,
      via: `session/list（args 键 request，命中 …${idTail}，asOfSeq=${fromListAlt}，HTTP ${listedAlt.code}）`
    };
  }
  // ② 兜底：`session/projections`（**它是另一套水位** —— `#15` 实测与 list 不一致，故只兜底并如实标注）
  const projections: DshApiResult = await client.rpc('session/projections',
    buildSessionProjectionsArgs(sessionId));
  const fromProjections: number = parseCursorFromProjections(projections.body);
  if (fromProjections >= 0) {
    return {
      cursor: fromProjections,
      via: `session/projections（**兜底源**：会话 …${idTail}，asOfSeq=${fromProjections}；` +
        `注意它与 session/list 的水位可能不同，HTTP ${projections.code}）`
    };
  }
  return {
    cursor: -1,
    via: `未取到（session/list _request HTTP ${listed.code}；session/list request HTTP ${listedAlt.code}；` +
      `session/projections …${idTail} HTTP ${projections.code}）`
  };
}

/**
 * 从服务端错误里抠出**它认的 cursor**：`session page through seq N is past cursor <C>` ⇒ `<C>`；拿不到 ⇒ -1。
 * 用途：万一 `throughSeq` 还是取小了/取大了，**用服务端自己说的那个数重试一次**（比猜强、且留证据）。
 */
export function parsePastCursorCursor(apiError: string): number {
  const m: RegExpMatchArray | null = apiError.match(/past cursor\s+(\d+)/);
  if (m === null) {
    return -1;
  }
  const v: number = Number(m[1]);
  return Number.isInteger(v) && v >= 0 ? v : -1;
}

export async function readConversation(client: DshApiClient, sessionId: string,
  needle: string): Promise<Ac16ReadResult> {
  const resolved: CursorResolve = await resolveCursor(client, sessionId);
  let cursor: number = resolved.cursor;   // 自愈时会被服务端给的数覆盖
  if (cursor < 0) {
    return {
      ok: false, parsed: false, pages: 0, hasMore: false, userTexts: [], assistantTexts: [], records: [],
      verbatimCount: 0, replyText: '', cursorResolved: false, cursor: -1, cursorVia: resolved.via,
      detail: `读回未取到：**没拿到 cursor**（${resolved.via}）⇒ 不发哨兵值、不猜，如实标"未取到"`
    };
  }

  const userTexts: string[] = [];
  const assistantTexts: string[] = [];
  const allRecords: PageRecord[] = [];
  let pages: number = 0;
  let hasMore: boolean = false;
  let parsedAny: boolean = false;
  let beforeSeq: number = 0;
  let note: string = '';

  while (pages < PAGE_READ_MAX_PAGES) {
    // throughSeq 取**上界 cursor**（契约：≤ cursor），翻旧页再带 beforeSeq
    const args: string = buildSessionPageArgs(sessionId, cursor, PAGE_MAX_MESSAGES, beforeSeq);
    let page: DshApiResult = await client.rpc('session/page', args);
    pages = pages + 1;
    let outcome: PageOutcome = parseSessionPage(page.body);
    // **自愈一次**：服务端说 `is past cursor <C>` ⇒ 用**它说的那个数**重试一次（比猜强，且把这条如实记进 note）
    if (!page.apiOk && page.apiError.length > 0) {
      const serverCursor: number = parsePastCursorCursor(page.apiError);
      if (serverCursor >= 0 && serverCursor !== cursor) {
        note = `⚠️ 首次 throughSeq=${cursor} 被服务端判 past cursor=${serverCursor} ⇒ 用服务端给的数重试一次`;
        cursor = serverCursor;
        page = await client.rpc('session/page', buildSessionPageArgs(sessionId, cursor, PAGE_MAX_MESSAGES, beforeSeq));
        pages = pages + 1;
        outcome = parseSessionPage(page.body);
      }
    }
    if (!page.apiOk && page.apiError.length > 0) {
      note = `${note.length > 0 ? `${note}｜` : ''}session/page 业务错误：${page.apiError}`;
      break;
    }
    if (!outcome.parsed) {
      note = `session/page 未能解析：${outcome.note}`;
      break;
    }
    parsedAny = true;
    for (let i = 0; i < outcome.userTexts.length; i++) {
      userTexts.push(outcome.userTexts[i]);
    }
    for (let i = 0; i < outcome.assistantTexts.length; i++) {
      assistantTexts.push(outcome.assistantTexts[i]);
    }
    for (let i = 0; i < outcome.records.length; i++) {
      allRecords.push(outcome.records[i]);
    }
    hasMore = outcome.hasMore;
    if (!hasMore || outcome.minSeq <= 0) {
      break;
    }
    beforeSeq = outcome.minSeq - 1;
  }

  const verbatimCount: number = countVerbatim(userTexts, needle);
  const replyText: string = assistantTexts.length > 0
    ? clipLines(assistantTexts[assistantTexts.length - 1], 600)
    : '';
  const ok: boolean = parsedAny && verbatimCount >= 1;

  let detail: string;
  const idTail: string = sessionId.length > 12 ? sessionId.substring(sessionId.length - 12) : sessionId;
  // 读到的事件范围（`#13` 的"读回不前进"要能一眼看出来：cursor 与读到的最大 seq 一起给）
  let minSeqRead: number = 0;
  let maxSeqRead: number = 0;
  for (let i = 0; i < allRecords.length; i++) {
    const s: number = allRecords[i].seq;
    if (minSeqRead === 0 || s < minSeqRead) {
      minSeqRead = s;
    }
    if (s > maxSeqRead) {
      maxSeqRead = s;
    }
  }
  if (!parsedAny) {
    detail = `读回未取到（会话 …${idTail}；cursor 来自 ${resolved.via}；${note.length > 0 ? note : 'session/page 无有效响应'}）`;
  } else {
    detail = `读回 ${pages} 页（**会话 …${idTail}**｜throughSeq=${cursor}，cursor 来自 ${resolved.via}，hasMore=${hasMore}）` +
      `｜读到事件 seq ${minSeqRead}–${maxSeqRead}（共 ${allRecords.length} 条）` +
      `｜用户侧 ${userTexts.length} 条、逐字命中「${needle}」${verbatimCount} 次` +
      `｜助手侧 ${assistantTexts.length} 条${replyText.length > 0 ? '（回应已取到）' : '（**回应未取到** ⇒ 照实说，不写成通过）'}`;
    if (cursor > maxSeqRead) {
      // **关键自证**：cursor 比读到的事件还大 ⇒ 要么服务端这个会话确实只到 maxSeqRead，要么 cursor 取错了会话
      detail = `${detail}｜⚠️ cursor(${cursor}) > 读到的最大 seq(${maxSeqRead})：若电脑侧刚有新事件却读不到，` +
        `优先怀疑"**cursor 取的不是这一场**"或"读的**不是被注入的那一场会话**"`;
    }
    if (hasMore) {
      detail = `${detail}｜⚠️ 还有更早的页未翻（已到本实现上限 ${PAGE_READ_MAX_PAGES} 页）`;
    }
  }

  return {
    ok: ok,
    parsed: parsedAny,
    pages: pages,
    hasMore: hasMore,
    userTexts: userTexts,
    assistantTexts: assistantTexts,
    records: sortRecords(allRecords),
    verbatimCount: verbatimCount,
    replyText: replyText,
    cursorResolved: true,
    cursor: cursor,
    cursorVia: resolved.via,
    detail: detail
  };
}

/** F5：按 `seq` 升序（会话页逐条渲染用；同 seq 保持稳定） */
export function sortRecords(records: PageRecord[]): PageRecord[] {
  const copy: PageRecord[] = [];
  for (let i = 0; i < records.length; i++) {
    copy.push(records[i]);
  }
  copy.sort((a: PageRecord, b: PageRecord) => a.seq - b.seq);
  return copy;
}

/** F5 侧栏：一场会话的一行 */
export interface SessionRow {
  sessionId: string;
  updatedAtMs: number;
  running: boolean;
  blank: boolean;
  title: string;
  asOfSeq: number;
  /** 这场会话声明的工作区（电脑上的 cwd）—— 内嵌图片的读取根就从它来 */
  cwd: string;
  /** 子 agent 的会话标 `subagent`（官方侧栏**不显示**这类，客户也不要） */
  origin: string;
  /** 子 agent 会话指向的父会话（官方侧栏用它把 fork 排在父会话旁边） */
  parentId: string;
}

export interface SessionListResult {
  ok: boolean;
  rows: SessionRow[];
  detail: string;
}

/**
 * F5 侧栏"**看见别的会话**"：`session/list`（形参名 `_request`）。
 * 依据（源码级）：结果 `items:[{sessionId, updatedAt, running, blank, projections:{asOfSeq, values:{title?}}}]`
 * —— `dsh-api-session-controller/lib/typert.host.js` 的 `session_list_result$schema`。
 */
export async function listSessions(client: DshApiClient): Promise<SessionListResult> {
  const listed: DshApiResult = await client.rpc('session/list', buildSessionListArgs());
  if (!listed.apiOk) {
    return {
      ok: false, rows: [],
      detail: `session/list 失败（HTTP ${listed.code}${listed.apiError.length > 0 ? `｜${listed.apiError}` : ''}）`
    };
  }
  const rows: SessionRow[] = [];
  try {
    const parsed = JSON.parse(listed.body) as Record<string, Object>;
    const result = parsed['result'] as Record<string, Object>;
    const value = result['value'] as Record<string, Object>;
    const items = value['items'] as Object[];
    for (let i = 0; i < items.length; i++) {
      const item = items[i] as Record<string, Object>;
      const sidObj: Object | undefined = item['sessionId'];
      const updated: Object | undefined = item['updatedAt'];
      const projections: Object | undefined = item['projections'];
      let asOfSeq: number = -1;
      let title: string = '';
      if (projections !== undefined && projections !== null) {
        const p = projections as Record<string, Object>;
        const asOf: Object | undefined = p['asOfSeq'];
        if (typeof asOf === 'number') {
          asOfSeq = asOf as number;
        }
        const values: Object | undefined = p['values'];
        if (values !== undefined && values !== null) {
          const t: Object | undefined = (values as Record<string, Object>)['title'];
          if (typeof t === 'string') {
            title = t as string;
          }
        }
      }
      rows.push({
        sessionId: typeof sidObj === 'string' ? sidObj as string : '',
        updatedAtMs: typeof updated === 'number' ? updated as number : 0,
        running: item['running'] === true,
        blank: item['blank'] === true,
        title: title,
        asOfSeq: asOfSeq,
        cwd: typeof item['cwd'] === 'string' ? item['cwd'] as string : '',
        origin: typeof item['origin'] === 'string' ? item['origin'] as string : '',
        parentId: typeof item['parentSessionId'] === 'string' ? item['parentSessionId'] as string : ''
      });
    }
  } catch (error) {
    return { ok: false, rows: [], detail: `session/list 响应解析失败（HTTP ${listed.code}）` };
  }
  rows.sort((a: SessionRow, b: SessionRow) => b.updatedAtMs - a.updatedAtMs);
  return { ok: true, rows: rows, detail: `session/list 取到 ${rows.length} 场会话（HTTP ${listed.code}）` };
}


