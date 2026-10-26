/**
 * F2（AC-03）会话协议：**纯函数**（零 Kit 依赖 ⇒ 可在宿主 node 上跑自查）。
 *
 * 字段形状**逐个对齐源码**（不猜）：
 *  - `session/create`：`{workspaceId?, cwd?, sessionId?, agentPreset?}`（全可选）→ `{sessionId, agentPreset?}`
 *    —— 依据 `dsh-api-session-controller/lib/typert.host.js:192-202`；
 *  - `session/prompt`：`{requestId, sessionId, mode:'queue'|'steer', content:[{type:'text',text}|{type:'image',…}|{type:'file',receiptId}], clientTimeZone?}`
 *    → `{accepted: z.literal(true)}` —— 同文件 `:784-805`；
 *  - `session/search`：`{query}` → `{items:[{sessionId, snippet}], hasMore}` —— 同文件 `:817-827`。
 *
 * ⚠️ **端点名必须在 URL 路径里**（`POST /api/session/prompt`），且 body 的 `method` 与端点一字不差
 *    —— 见 `dsh-client-connection/lib/index.js:689-693 / 711-716`（本项目踩过 404：端点只写在 body 里）。
 *    这一层由 `DshApiClient.rpc()` 负责；本文件只产出它要的 `args` 内容。
 *
 * ⚠️ **AC-03 的"不是 App 内假象"靠什么证**：不是靠 App 自己说自己成功，而是
 *    ① `session/create` 真的在电脑上建了会话（拿回 `sessionId`）；
 *    ② `session/prompt` 把**带固定标识的原文**交进去（`accepted:true`）；
 *    ③ **回手用 `session/search` 在该 dsh 自己的会话库里检索那个标识** —— 搜到了，才说明
 *       这句话确实落在了电脑侧（`snippet` 就是电脑侧的原文片段）。
 */

/** F2/AC-03 固定标识（沿用项目经理给的测试标识） */
export const AC03_MARKER: string = 'DSH-AC03-OK-2026';

/** 本轮 prompt 的投递方式：queue = 排队到下一轮，steer = 立即插入当前轮 */
let promptMode: string = 'queue';

export function setPromptMode(mode: string): void {
  promptMode = mode === 'steer' ? 'steer' : 'queue';
}

/** 发出去的指令原文（**含固定标识**；原样送去，界面也原样显示，便于两侧对号） */
export function ac03PromptText(marker: string): string {
  return `请原样回复这一行（测试标识）：${marker}`;
}

/** `session/create` 的 args（全字段可选 ⇒ 空对象合法；实测缺 `request` 会 `gateway/arguments-invalid`） */
export function buildSessionCreateArgs(): string {
  return '{"request":{}}';
}

export interface TextPart {
  type: string;
  text: string;
}

export interface PromptRequest {
  requestId: string;
  sessionId: string;
  mode: string;
  content: (TextPart | FilePart)[];
}

/** `session/prompt` 的 args（一条 `text` 部件） */
export function buildPromptArgs(sessionId: string, text: string, requestId: string): string {
  const part: TextPart = { type: 'text', text: text };
  const request: PromptRequest = {
    requestId: requestId,
    sessionId: sessionId,
    mode: promptMode,
    content: [part]
  };
  return JSON.stringify({ request: request });
}

interface SearchRequest {
  query: string;
}

/** 一张内联图片（base64 + MIME） */
export interface ImagePayload {
  data: string;
  mediaType: string;
}

/**
 * **多附件**的 prompt（2026-10-20）：文本 + 任意张图片（内联）+ 任意个文件（回执）。
 * 顺序：先文字，再图片，再文件；都没有就给一个占位文字。
 */
export function buildPromptArgsRich(sessionId: string, text: string, requestId: string,
  images: ImagePayload[], receipts: string[]): string {
  const parts: string[] = [];
  if (text.length > 0) {
    parts.push(`{"type":"text","text":${JSON.stringify(text)}}`);
  }
  for (let i = 0; i < images.length; i++) {
    parts.push(`{"type":"image","data":${JSON.stringify(images[i].data)},` +
      `"mediaType":${JSON.stringify(images[i].mediaType)}}`);
  }
  for (let i = 0; i < receipts.length; i++) {
    parts.push(`{"type":"file","receiptId":${JSON.stringify(receipts[i])}}`);
  }
  if (parts.length === 0) {
    parts.push('{"type":"text","text":"（附件）"}');
  }
  return `{"request":{"requestId":${JSON.stringify(requestId)},"sessionId":${JSON.stringify(sessionId)},` +
    `"mode":${JSON.stringify(promptMode)},"content":[${parts.join(',')}]}}`;
}

/**
 * 带**图片**的 prompt（2026-10-20 实测：图片以 `{type:'image', data:<base64>, mediaType}` **内联**提交，
 * 服务端自己落成图片附件）。**不要**先 uploadFileBinary 再当 `{type:'file'}` 发 —— 那样两端都只显示文件名。
 */
export function buildPromptArgsWithImage(sessionId: string, text: string, requestId: string,
  dataBase64: string, mediaType: string): string {
  const textPart: string = text.length > 0
    ? `{"type":"text","text":${JSON.stringify(text)}},` : '';
  const imagePart: string = `{"type":"image","data":${JSON.stringify(dataBase64)},"mediaType":${JSON.stringify(mediaType)}}`;
  return `{"request":{"requestId":${JSON.stringify(requestId)},"sessionId":${JSON.stringify(sessionId)},` +
    `"mode":${JSON.stringify(promptMode)},"content":[${textPart}${imagePart}]}}`;
}

/** `session/search` 的 args（**电脑侧检索**用；就是它让"不是假象"可自证） */
export function buildSearchArgs(query: string): string {
  const request: SearchRequest = { query: query };
  return JSON.stringify({ request: request });
}

/** 从 RPC 响应体里取 `result.value.sessionId`（取不到 ⇒ 空串 = 没建成） */
export function parseSessionId(body: string): string {
  if (body.length === 0 || body.charAt(0) !== '{') {
    return '';
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const result: Object | undefined = parsed['result'];
    if (result === undefined || result === null) {
      return '';
    }
    const value: Object | undefined = (result as Record<string, Object>)['value'];
    if (value === undefined || value === null) {
      return '';
    }
    const id: Object | undefined = (value as Record<string, Object>)['sessionId'];
    return typeof id === 'string' ? id as string : '';
  } catch (error) {
    return '';
  }
}

/** 判 `session/prompt` 是否受理：`result.value.accepted === true`（源码里是 `z.literal(true)`） */
export function parseAccepted(body: string): boolean {
  if (body.length === 0 || body.charAt(0) !== '{') {
    return false;
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const result: Object | undefined = parsed['result'];
    if (result === undefined || result === null) {
      return false;
    }
    const value: Object | undefined = (result as Record<string, Object>)['value'];
    if (value === undefined || value === null) {
      return false;
    }
    return (value as Record<string, Object>)['accepted'] === true;
  } catch (error) {
    return false;
  }
}

export interface SearchHit {
  sessionId: string;
  snippet: string;
}

export interface SearchOutcome {
  /** body 能不能解析成 `result.value` */
  parsed: boolean;
  hits: SearchHit[];
  hasMore: boolean;
  /** 可读说明（给界面；空 = 一切正常） */
  note: string;
}

/** 解析 `session/search` 的响应：`{items:[{sessionId, snippet}], hasMore}` */
export function parseSearchItems(body: string): SearchOutcome {
  const empty: SearchOutcome = { parsed: false, hits: [], hasMore: false, note: '响应体不是 JSON 对象' };
  if (body.length === 0 || body.charAt(0) !== '{') {
    return empty;
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const result: Object | undefined = parsed['result'];
    if (result === undefined || result === null) {
      return { parsed: false, hits: [], hasMore: false, note: '响应里没有 result（可能被网关拦下）' };
    }
    const value: Object | undefined = (result as Record<string, Object>)['value'];
    if (value === undefined || value === null) {
      // `result.ok=false` 时 error 在 result.error 里，由调用方读 apiError
      return { parsed: false, hits: [], hasMore: false, note: '响应里没有 result.value（业务失败）' };
    }
    const valueObj: Record<string, Object> = value as Record<string, Object>;
    const itemsRaw: Object | undefined = valueObj['items'];
    const hits: SearchHit[] = [];
    if (itemsRaw !== undefined && itemsRaw !== null) {
      const arr: Object[] = itemsRaw as Object[];
      for (let i = 0; i < arr.length; i++) {
        const row: Record<string, Object> = arr[i] as Record<string, Object>;
        const sid: Object | undefined = row['sessionId'];
        const snip: Object | undefined = row['snippet'];
        const hit: SearchHit = {
          sessionId: typeof sid === 'string' ? sid as string : '',
          snippet: typeof snip === 'string' ? snip as string : ''
        };
        hits.push(hit);
      }
    }
    return {
      parsed: true,
      hits: hits,
      hasMore: valueObj['hasMore'] === true,
      note: ''
    };
  } catch (error) {
    return { parsed: false, hits: [], hasMore: false, note: '响应体解析失败' };
  }
}

/** 电脑侧检索结果里有没有那个标识（**AC-03"不是假象"的判据**） */
export function markerFound(outcome: SearchOutcome, marker: string): boolean {
  for (let i = 0; i < outcome.hits.length; i++) {
    if (outcome.hits[i].snippet.includes(marker)) {
      return true;
    }
  }
  return false;
}

/** 命中里是否**有**本机刚建的那个会话（同一次动作对号用） */
export function hitInSession(outcome: SearchOutcome, sessionId: string): boolean {
  if (sessionId.length === 0) {
    return false;
  }
  for (let i = 0; i < outcome.hits.length; i++) {
    if (outcome.hits[i].sessionId === sessionId) {
      return true;
    }
  }
  return false;
}

/** 截断（界面显示用；避免一屏塞满） */
export function clip(text: string, max: number): string {
  if (text.length <= max) {
    return text;
  }
  return `${text.substring(0, max)}…（共 ${text.length} 字）`;
}

/**
 * `session/search` 的**这一类**业务错误 = **本部署把会话检索索引关掉了**（`openAt: "never"`）。
 *
 * 为什么要单独认出来：它**不是失败、也不是"没搜到"** —— 是**这套部署不支持该步**。
 * 「看起来能验、其实验不了」的入口不许留（与"不得放假状态"同族）⇒ 界面必须**明示部署不支持**，
 * 并说明**本步不参与判定**、电脑侧证据以落盘原文为准。
 * 依据：`#7` 实测原文 `gateway/internal｜session search failed: SessionQueryError: session search is disabled: this deployment configures the session-query index with openAt "never"`。
 */
export function searchDisabled(apiError: string): boolean {
  return apiError.includes('session search is disabled') || apiError.includes('openAt');
}

/** 「部署不支持会话检索」时**统一的明示句**（单一来源；界面与步骤行都取它，别在别处另写一版） */
export function searchDisabledNote(apiError: string): string {
  const raw: string = apiError.length > 0 ? `（业务错误原文：${apiError}）` : '';
  return '当前部署已禁用会话检索（openAt:"never"）⇒ 本步不参与 AC-03 判定，电脑侧证据以落盘原文为准' + raw;
}

/** 文件附件块（官方 `session/prompt` 的 `content[]` 支持）
 *  依赖上传 `POST /api/session/uploadFileBinary` 换来的 `receiptId`。 */
export interface FilePart {
  type: string;
  receiptId: string;
}

/** 带文件附件的 prompt（客户 2026-10-17：手机上选的文件要发给那场对话） */
export function buildPromptArgsWithFile(sessionId: string, text: string, requestId: string,
  receiptId: string, fileName: string): string {
  const parts: (TextPart | FilePart)[] = [];
  if (text.length > 0) {
    const textPart: TextPart = { type: 'text', text: text };
    parts.push(textPart);
  }
  if (receiptId.length > 0) {
    const filePart: FilePart = { type: 'file', receiptId: receiptId };
    parts.push(filePart);
  }
  if (parts.length === 0) {
    const fallback: TextPart = { type: 'text', text: fileName.length > 0 ? `（附件）${fileName}` : '（附件）' };
    parts.push(fallback);
  }
  const request: PromptRequest = {
    requestId: requestId,
    sessionId: sessionId,
    mode: promptMode,
    content: parts
  };
  return JSON.stringify({ request: request });
}
