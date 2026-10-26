/**
 * F11（AC-16）＋ F4 的**读回**协议：`session/page`（纯函数，零 Kit ⇒ 可 host 自查）。
 *
 * 为什么用它而**不用 `session/search`**：`#7` 实测本部署把 session-query 索引关成 `openAt:"never"`
 * ⇒ `session/search` 不可用；`session/page` 是**分页读会话事件**的正规路（不依赖检索索引）。
 *
 * 字段形状**逐个对齐源码**（不猜；`dsh-api-session-controller/lib/typert.host.js`）：
 *  - 请求 `session/page`（`:620-637`）：`{ address: {kind:'session', sessionId} | {kind:'subagent',…},
 *    throughSeq: number（必填）, beforeSeq?: number, maxMessages?: number, turnWindow?: {minMessages,minTurns} }`
 *  - 响应（`:639-653`）：`{ records: [{ type:'event', event: { type: string, seq: number, time: number, data } }], hasMore: boolean }`
 *  - 事件名表（`dsh-session-reference/lib/typert.host.js:487` 的 `SessionEventMap`）：
 *    **`user/message`** = 用户消息（我们发出去的文本在这里）、
 *    **`assistant/message`** = 助手消息（dsh 的回应在这里）；另有 turn/step/tool 等。
 *  - 消息体（同文件 `:139 / :659` ＋ `MessageBase`）：`MessageBase { id, content: ContentBlock[], source }`，
 *    `ContentBlockMap.text = TextBlock` ⇒ 文本块形如 `{ type:'text', text:string }`。
 *
 * 取文本用**容忍式遍历**（不写死嵌套层）：`user/message` 的 data 本身就是 UserMessage（`content[]` 直接在 data 上），
 * `assistant/message` 的 data 是 `{turn,step,message:{content[]},…}`（文本在 `data.message.content[]`）——
 * 两种都给同一把"找出所有 `{type:'text',text}`"的走法，避免猜错一层就取空。
 */

/** F11/AC-16 固定测试文本（原样送、原样读回，便于两侧对号） */

/** F5/AC-18 的固定标识（手机发起这场对话时用它，电脑侧据此认同一场） */

/**
 * ⚠️ **不要再用"哨兵 throughSeq"读到底**（`#9` 实测踩过）：
 * 发 `9007199254740991` ⇒ 服务端逐字回 `gateway/bad-request｜session page through seq 9007199254740991 is past cursor 25`
 * ⇒ 契约是 **`throughSeq ≤ cursor`**。cursor 必须**先问出来**（见下面两个解析函数），取不到就**如实标"未取到"**，不许再发哨兵值。
 */

/** 一页最多取多少条（防止一次拉爆） */
export const PAGE_MAX_MESSAGES: number = 200;

interface AddressRef {
  kind: string;
  sessionId: string;
}

interface PageRequest {
  address: AddressRef;
  throughSeq: number;
  beforeSeq?: number;
  maxMessages?: number;
}

/** `session/page` 的 args（`beforeSeq` 只在翻旧页时给） */
export function buildSessionPageArgs(sessionId: string, throughSeq: number,
  maxMessages: number, beforeSeq: number): string {
  const address: AddressRef = { kind: 'session', sessionId: sessionId };
  if (beforeSeq > 0) {
    const withBefore: PageRequest = {
      address: address, throughSeq: throughSeq, beforeSeq: beforeSeq, maxMessages: maxMessages
    };
    return JSON.stringify({ request: withBefore });
  }
  const request: PageRequest = { address: address, throughSeq: throughSeq, maxMessages: maxMessages };
  return JSON.stringify({ request: request });
}

interface ProjectionsRequest {
  sessionId: string;
}

/** `session/list` 的 args —— 形参名是 **`_request`**（源码声明的 `name:'_request', wire:'_request'`，不是 `request`） */
export function buildSessionListArgs(): string {
  return '{"_request":{}}';
}

/**
 * 备用形状：`session/list` 用 **`request`** 当 args 键。
 *
 * 为什么留这个备用：`pc-bridge` 报的是 `payload.args.request = {}`，而**宿主声明**是
 * `_request`（`dsh-api-session-controller/lib/typert.host.js:1117-1127`，`wire: '_request'`；
 * 同文件里 `session/page|projections|prompt|create` 等**都是 `request`**，只有 `list` 是 `_request`）。
 * 两边不一致时**不赌** —— 先按声明试 `_request`，失败再试 `request`，并把**哪一条起效**写进 cursor 来源（证据）。
 */
export function buildSessionListAltArgs(): string {
  return '{"request":{}}';
}

/** `session/projections` 的 args —— 形参名是 `request`（源码声明） */
export function buildSessionProjectionsArgs(sessionId: string): string {
  const request: ProjectionsRequest = { sessionId: sessionId };
  return JSON.stringify({ request: request });
}

/**
 * 从 `session/list` 响应里取**该会话的 cursor**（= `items[].projections.asOfSeq`）；取不到 ⇒ **-1**。
 * 依据（源码级）：`session/list` 结果 `{items:[{sessionId, updatedAt, running, blank, projections:{kind, asOfSeq, values}}], …}`
 * —— `dsh-api-session-controller/lib/typert.host.js` 的 `session_list_result$schema`。
 * ⚠️ 这个值是 `session/page` 的 `throughSeq` **上界**（`#9` 实测：超过它就 `gateway/bad-request … is past cursor N`）。
 */
export function parseCursorFromList(body: string, sessionId: string): number {
  if (body.length === 0 || body.charAt(0) !== '{') {
    return -1;
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const result: Object | undefined = parsed['result'];
    if (result === undefined || result === null) {
      return -1;
    }
    const value: Object | undefined = (result as Record<string, Object>)['value'];
    if (value === undefined || value === null) {
      return -1;
    }
    const itemsRaw: Object | undefined = (value as Record<string, Object>)['items'];
    if (itemsRaw === undefined || itemsRaw === null) {
      return -1;
    }
    const items: Object[] = itemsRaw as Object[];
    for (let i = 0; i < items.length; i++) {
      const item: Record<string, Object> = items[i] as Record<string, Object>;
      const sid: Object | undefined = item['sessionId'];
      if (typeof sid !== 'string' || (sid as string) !== sessionId) {
        continue;
      }
      const projections: Object | undefined = item['projections'];
      if (projections === undefined || projections === null) {
        return -1;
      }
      const asOf: Object | undefined = (projections as Record<string, Object>)['asOfSeq'];
      return typeof asOf === 'number' ? asOf as number : -1;
    }
    return -1;
  } catch (error) {
    return -1;
  }
}

/** 从 `session/projections` 响应里取 cursor（`result.value.asOfSeq`）；取不到 ⇒ **-1** */
export function parseCursorFromProjections(body: string): number {
  if (body.length === 0 || body.charAt(0) !== '{') {
    return -1;
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const result: Object | undefined = parsed['result'];
    if (result === undefined || result === null) {
      return -1;
    }
    const value: Object | undefined = (result as Record<string, Object>)['value'];
    if (value === undefined || value === null) {
      return -1;
    }
    const asOf: Object | undefined = (value as Record<string, Object>)['asOfSeq'];
    return typeof asOf === 'number' ? asOf as number : -1;
  } catch (error) {
    return -1;
  }
}

/** 一条事件（只留界面要用的：类型/序号/时刻/取到的文本） */export interface PageRecord {
  seq: number;
  type: string;
  timeMs: number;
  /** 该事件里取到的文本（空 = 这个事件没文本） */
  text: string;
}

export interface PageOutcome {
  parsed: boolean;
  records: PageRecord[];
  hasMore: boolean;
  /** 用户侧文本（`user/message`） */
  userTexts: string[];
  /** 助手侧文本（`assistant/message`） */
  assistantTexts: string[];
  /** 最小 seq（翻旧页用；-1 = 没有记录） */
  minSeq: number;
  note: string;
}

/**
 * 容忍式取文本：递归找**带 `text` 字符串字段的对象**（文本块 `{type:'text',text}`、`{text}` 都算），
 * 按出现顺序拼起来。
 *
 * ⚠️ **标量（id / type / source / reason 等字符串）一律不当正文** —— 否则消息体里的
 * `id:"m1"`、`source:"user"` 会被当成文本混进"读回原文"，把"一字不差"的判据污染掉（自检里踩过）。
 */
export function extractTexts(data: Object | undefined, depth: number): string[] {
  const out: string[] = [];
  if (data === undefined || data === null || depth > 6) {
    return out;
  }
  if (Array.isArray(data)) {
    const arr: Object[] = data as Object[];
    for (let i = 0; i < arr.length; i++) {
      const inner: string[] = extractTexts(arr[i], depth + 1);
      for (let j = 0; j < inner.length; j++) {
        out.push(inner[j]);
      }
    }
    return out;
  }
  if (typeof data !== 'object') {
    return out;
  }
  const obj: Record<string, Object> = data as Record<string, Object>;
  // 「思考过程 / 推理」不是正文：整棵子树跳过（客户反馈：气泡里把模型的思考也贴出来了）。
  // 形状依据：内容块是 `{type:'text'|'reasoning'|…, text}`（`MessageBase.content: ContentBlock[]`）。
  const kindValue: Object | undefined = obj['type'];
  if (typeof kindValue === 'string') {
    const kind: string = kindValue as string;
    if (kind === 'reasoning' || kind === 'thinking') {
      return out;
    }
  }
  const textValue: Object | undefined = obj['text'];
  if (typeof textValue === 'string') {
    out.push(textValue as string);
    return out;
  }
  // 继续往下走（message.content / content / inserted / data…）
  const keys: string[] = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    const child: Object | undefined = obj[keys[i]];
    if (child === undefined || child === null) {
      continue;
    }
    const inner: string[] = extractTexts(child, depth + 1);
    for (let j = 0; j < inner.length; j++) {
      out.push(inner[j]);
    }
  }
  return out;
}

/** 内容块数组 → 正文：**只认 `type === 'text'`**（reasoning / thinking / tool 等一律不是正文） */
export function textsFromContentBlocks(blocks: Object[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const block: Object = blocks[i];
    if (block === undefined || block === null || typeof block !== 'object') {
      continue;
    }
    const obj: Record<string, Object> = block as Record<string, Object>;
    const kindValue: Object | undefined = obj['type'];
    if (typeof kindValue !== 'string' || (kindValue as string) !== 'text') {
      continue;
    }
    const textValue: Object | undefined = obj['text'];
    if (typeof textValue === 'string' && (textValue as string).length > 0) {
      out.push(textValue as string);
    }
  }
  return out;
}

/** 从对象里取一个数组字段（不是数组就给空数组，不抛） */
function arrayFieldOf(obj: Record<string, Object> | undefined, key: string): Object[] {
  if (obj === undefined || obj === null) {
    return [];
  }
  const value: Object | undefined = obj[key];
  return Array.isArray(value) ? value as Object[] : [];
}

/**
 * **一条事件的正文**（**唯一入口**：分页读与实时流都走它）。
 *
 * 走**正式路径**，不走"到处找 text"的容忍式遍历：
 *  - `assistant/message` ⇒ `data.message.content[]`
 *  - `user/message`     ⇒ `data.content[]`（形状不同就退回 `data.message.content[]`）
 *  - 其它类型 ⇒ 才用容忍式遍历兜底（它们不进气泡，只为"内容都可见"）
 *
 * ⚠️ **为什么必须这样**（实测）：`assistant/message` 的 `data` 里除了 `message.content[]`，
 * 还有一份 `data.stream[]` —— **这条消息的流式日志**，里面同样带着正文
 * ⇒ 容忍式遍历会把同一句话取两遍（现象：气泡里同一句重复出现）。
 */
export function eventTexts(eventType: string, data: Object | undefined): string[] {
  if (data === undefined || data === null || typeof data !== 'object') {
    return [];
  }
  const obj: Record<string, Object> = data as Record<string, Object>;
  const messageObj: Record<string, Object> | undefined = (() => {
    const value: Object | undefined = obj['message'];
    return value !== undefined && value !== null && typeof value === 'object'
      ? value as Record<string, Object> : undefined;
  })();
  const candidates: Object[][] = eventType === 'assistant/message'
    ? [arrayFieldOf(messageObj, 'content'), arrayFieldOf(obj, 'content')]
    : eventType === 'user/message'
      ? [arrayFieldOf(obj, 'content'), arrayFieldOf(messageObj, 'content')]
      : [];
  for (let i = 0; i < candidates.length; i++) {
    const texts: string[] = textsFromContentBlocks(candidates[i]);
    if (texts.length > 0) {
      return texts;
    }
  }
  return extractTexts(data, 0);
}

/** 解析 `session/page` 响应 → 记录列表 ＋ 用户/助手文本 */
export function parseSessionPage(body: string): PageOutcome {
  const empty: PageOutcome = {
    parsed: false, records: [], hasMore: false, userTexts: [], assistantTexts: [], minSeq: -1,
    note: '响应体不是 JSON 对象'
  };
  if (body.length === 0 || body.charAt(0) !== '{') {
    return empty;
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const result: Object | undefined = parsed['result'];
    if (result === undefined || result === null) {
      return {
        parsed: false, records: [], hasMore: false, userTexts: [], assistantTexts: [], minSeq: -1,
        note: '响应里没有 result（可能被网关拦下）'
      };
    }
    const value: Object | undefined = (result as Record<string, Object>)['value'];
    if (value === undefined || value === null) {
      return {
        parsed: false, records: [], hasMore: false, userTexts: [], assistantTexts: [], minSeq: -1,
        note: '响应里没有 result.value（业务失败）'
      };
    }
    const valueObj: Record<string, Object> = value as Record<string, Object>;
    const records: PageRecord[] = [];
    const userTexts: string[] = [];
    const assistantTexts: string[] = [];
    let minSeq: number = -1;
    const recordsRaw: Object | undefined = valueObj['records'];
    if (recordsRaw !== undefined && recordsRaw !== null) {
      const arr: Object[] = recordsRaw as Object[];
      for (let i = 0; i < arr.length; i++) {
        const row: Record<string, Object> = arr[i] as Record<string, Object>;
        const event: Object | undefined = row['event'];
        if (event === undefined || event === null) {
          continue;
        }
        const e: Record<string, Object> = event as Record<string, Object>;
        const seqValue: Object | undefined = e['seq'];
        const typeValue: Object | undefined = e['type'];
        const timeValue: Object | undefined = e['time'];
        const seq: number = typeof seqValue === 'number' ? seqValue as number : -1;
        const type: string = typeof typeValue === 'string' ? typeValue as string : '';
        const timeMs: number = typeof timeValue === 'number' ? timeValue as number : 0;
        const texts: string[] = eventTexts(type, e['data']);
        let joined: string = '';
        for (let j = 0; j < texts.length; j++) {
          joined = j === 0 ? texts[j] : `${joined}\n${texts[j]}`;
        }
        records.push({ seq: seq, type: type, timeMs: timeMs, text: joined });
        if (seq >= 0 && (minSeq < 0 || seq < minSeq)) {
          minSeq = seq;
        }
        if (type === 'user/message' && joined.length > 0) {
          userTexts.push(joined);
        }
        if (type === 'assistant/message' && joined.length > 0) {
          assistantTexts.push(joined);
        }
      }
    }
    return {
      parsed: true,
      records: records,
      hasMore: valueObj['hasMore'] === true,
      userTexts: userTexts,
      assistantTexts: assistantTexts,
      minSeq: minSeq,
      note: ''
    };
  } catch (error) {
    return {
      parsed: false, records: [], hasMore: false, userTexts: [], assistantTexts: [], minSeq: -1,
      note: '响应体解析失败'
    };
  }
}

/** 文本里**逐字**出现某串若干次（AC-16 判"一字不差"＋"重复 2 次"用） */export function countOccurrences(hay: string, needle: string): number {  if (needle.length === 0 || hay.length === 0) {
    return 0;
  }
  let count: number = 0;
  let from: number = 0;
  while (true) {
    const at: number = hay.indexOf(needle, from);
    if (at < 0) {
      break;
    }
    count = count + 1;
    from = at + needle.length;
  }
  return count;
}

/** 用户侧文本里逐字命中固定文本的总次数（**一字不差**才计数） */
export function countVerbatim(texts: string[], needle: string): number {
  let total: number = 0;
  for (let i = 0; i < texts.length; i++) {
    total = total + countOccurrences(texts[i], needle);
  }
  return total;
}

/** 截断（界面显示） */
export function clipLines(text: string, maxChars: number): string {
  const one: string = text.replace(/\r?\n/g, ' ⏎ ');
  if (one.length <= maxChars) {
    return one;
  }
  return `${one.substring(0, maxChars)}…（共 ${one.length} 字）`;
}
