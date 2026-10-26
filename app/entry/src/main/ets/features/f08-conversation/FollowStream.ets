import { hilog } from '@kit.PerformanceAnalysisKit';
import { RawWs, RawWsTarget } from '../../services/RawWs';
import { DSH_PATH_PREFIX } from '../../model/EntryPorts';
import { activeProfile } from '../../services/ProfileStore';
import { eventTexts } from './SessionPageModel';

const DOMAIN: number = 0xD001;
const TAG: string = 'F5FOLLOW';
/** 断线重连：最多几次、每次间隔（`session/follow` 没有 resume 游标 ⇒ 重连=重新订阅拿新快照） */
const RECONNECT_MAX: number = 5;
const RECONNECT_DELAY_MS: number = 2000;

/**
 * **会话实时订阅**（功能 5/8 的"消息自动出现"就靠它）—— 走 dsh 官方流载体，经插件中转。
 *
 * ## 链路（2026-10-18 真机口径）
 * dsh 的 `session/follow` 只能走它的 stream carrier：**WebSocket `/api/remote.mux`**。
 * 但 dsh **只监听电脑回环**（`127.0.0.1:dsh 端口`），tailnet 上唯一能到的门是插件 `插件端口`。
 * ⇒ 手机用自建握手（`services/RawWs.ets`，Host/Origin 都写回环）连
 *   `ws://<插件地址>:插件端口/pair/dsh/api/remote.mux`；插件按字节转发给本机 dsh（Host 改成回环）。
 * 系统 WS 客户端不能改 `Host`/`Origin`，所以必须用 `RawWs`。
 *
 * 帧（WS 文本帧，一行一个 JSON）：
 *  - `{"type":"item","streamId":…,"value":<session/follow 的一帧>}` —— snapshot / event / assistant-stream
 */

/** 消息里带的一个**文件附件**（手机发出去的文件在电脑侧存成这个形状） */
export interface FollowFile {
  /** 附件 id（`sha256:…`）；空串 = 只知道文件名（本机乐观回显时） */
  attachmentId: string;
  name: string;
  /** 字节数；-1 = 不知道 */
  bytes: number;
}

/** 一条事件（只留聊天要用的：谁说的 / 序号 / 时刻 / 文本 / 图片 / 文件 / 来源种类） */
export interface FollowRecord {
  seq: number;
  type: string;
  timeMs: number;
  text: string;
  /**
   * `data.source.kind`：真用户消息是 `user`；dsh 注入的上下文是 `runtime-context` / `skill-catalog` /
   * `agent-instructions` 等；队友/子代理是 `team-message` / `subagent-settled`。
   * **聊天只显示 `user`**（其余折起或不显示）。
   */
  sourceKind: string;
  /** 这条消息里要显示的**电脑上的图片**路径（来自工具调用 present/show_image 或正文 `[名][路径]`） */
  images: string[];
  /** 这条消息里带的**文件附件**（`content[]` 里 `{type:'file', attachment:{…}}`） */
  files: FollowFile[];
}

/** 首帧快照：当场把已有对话整段给出 */
export interface FollowSnapshot {
  cursor: number;
  title: string;
  records: FollowRecord[];
}

/** 订阅期间的三个回调（都在 UI 线程消费） */
export interface FollowSink {
  onSnapshot: (snap: FollowSnapshot) => void;
  onRecord: (rec: FollowRecord) => void;
  /** 助手的**逐字流**（可能来很多次，调用方拼起来显示） */
  onStreamText: (text: string) => void;
  /** 新一次助手尝试开始（模型重试会重新 start）：清掉正在拼的旧半句 */
  onStreamReset: () => void;
  /** 人话原因 ＋ 证据原文（界面显示前面那条，日志记后面那条） */
  onError: (human: string, detail: string) => void;
  /** 流正常结束（被 stop() 主动停的**不回调**） */
  onClosed: (detail: string) => void;
  /** 电脑侧改了这场会话的标题（`session/title` 事件） */
  onTitle: (title: string) => void;
  /** **这轮在不在干活**（`turn/start`→true、`turn/end`→false）；界面据此显示「正在思考…／空闲」 */
  onTurnState: (busy: boolean) => void;
}

interface FrameEvent {
  type: string;
  seq: number;
  time: number;
  data: Object;
}

interface FrameRecord {
  type: string;
  event: FrameEvent;
}

interface ProjectionValues {
  title?: string;
}

interface Projection {
  asOfSeq: number;
  values?: ProjectionValues;
}

/** 快照里的"正在生成"基线：activeAttempt.stream 是 compact 记录数组（TextChunks 带 texts[]） */
interface AttemptBaseline {
  stream?: Object[];
}

interface StreamBaseline {
  activeAttempt?: AttemptBaseline;
}

/** 实时助手流的一帧：dsh 官方 `SessionAssistantStreamFrame`（start / chunk / end） */
interface AssistantFrame {
  type: string;
  index?: number;
  /** chunk 帧里是 `StreamChunk`（text-delta / reasoning-delta / …） */
  chunk?: StreamChunkLike;
}

interface StreamChunkLike {
  type: string;
  text?: string;
}

/** `session/follow` 的一帧（宽容形状：缺字段当"没有"） */
interface FollowFrame {
  type: string;
  event?: FrameEvent;
  cursor?: number;
  records?: FrameRecord[];
  projections?: Projection;
  assistantStream?: StreamBaseline;
  /** 实时帧的正文都在这里（`{type:'assistant-stream', frame:{type:'chunk', chunk:{…}}}`） */
  frame?: AssistantFrame;
}

/** 插件发来的一行（NDJSON） */
interface StreamLine {
  type: string;
  value?: FollowFrame;
  error?: LineError;
  at?: number;
}

interface LineError {
  code?: string;
  message?: string;
}

/** 递归收字符串（`assistant-stream.stream` 是字符串数组，`extractTexts` 认不出 ⇒ 单独走这条） */
function collectStrings(value: Object | undefined, out: string[], depth: number): void {
  if (value === undefined || value === null || depth > 6) {
    return;
  }
  if (typeof value === 'string') {
    const s: string = value as string;
    if (s.length > 0) {
      out.push(s);
    }
    return;
  }
  if (Array.isArray(value)) {
    const arr: Object[] = value as Object[];
    for (let i = 0; i < arr.length; i++) {
      collectStrings(arr[i], out, depth + 1);
    }
    return;
  }
  if (typeof value !== 'object') {
    return;
  }
  const obj: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    collectStrings(obj[keys[i]], out, depth + 1);
  }
}

function streamTextOf(frame: FollowFrame): string {
  // 实时帧（dsh 官方 SessionAssistantStreamFrame）：正文在 frame.frame.chunk
  const live: AssistantFrame | undefined = frame.frame;
  if (live === undefined || live === null) {
    return '';
  }
  if (live.type === 'chunk') {
    const chunk: StreamChunkLike | undefined = live.chunk;
    if (chunk !== undefined && chunk !== null && chunk.type === 'text-delta') {
      const text: string | undefined = chunk.text;
      return typeof text === 'string' ? text : '';
    }
  }
  // start / end / reasoning / tool-call 都不进正文
  return '';
}

/**
 * 快照里"正在生成的这段"已产出的正文。
 * dsh 的 `session/follow` 快照带 `assistantStream.activeAttempt.stream`（compact 记录数组），
 * 且后续只补发快照切点之后的**新增量** chunk —— 不从这里恢复，重连后回答会从半句开始。
 */
function baselineTextOf(baseline: StreamBaseline | undefined): string {
  if (baseline === undefined || baseline === null) {
    return '';
  }
  const attempt: AttemptBaseline | undefined = baseline.activeAttempt;
  if (attempt === undefined || attempt === null) {
    return '';
  }
  const stream: Object[] | undefined = attempt.stream;
  if (stream === undefined || !Array.isArray(stream)) {
    return '';
  }
  let out: string = '';
  for (let i = 0; i < stream.length; i++) {
    const rec: Record<string, Object> = stream[i] as Record<string, Object>;
    if (rec['type'] !== 'text-chunks') {
      continue;
    }
    const texts: Object | undefined = rec['texts'];
    if (texts === undefined || !Array.isArray(texts)) {
      continue;
    }
    const list: Object[] = texts as Object[];
    for (let k = 0; k < list.length; k++) {
      if (typeof list[k] === 'string') {
        out = out + (list[k] as string);
      }
    }
  }
  return out;
}

/** `session/title` 的标题文本（没有就给空串） */
function titleOf(data: Object | undefined): string {
  if (data === undefined || data === null || typeof data !== 'object') {
    return '';
  }
  const value: Object | undefined = (data as Record<string, Object>)['title'];
  return typeof value === 'string' ? value as string : '';
}

/** `data.source.kind`（没有就给空串；真用户消息是 `user`） */
function sourceKindOf(data: Object | undefined): string {
  if (data === undefined || data === null || typeof data !== 'object') {
    return '';
  }
  const sourceValue: Object | undefined = (data as Record<string, Object>)['source'];
  if (sourceValue === undefined || sourceValue === null || typeof sourceValue !== 'object') {
    return '';
  }
  const kindValue: Object | undefined = (sourceValue as Record<string, Object>)['kind'];
  return typeof kindValue === 'string' ? kindValue as string : '';
}

/** 只认这几种后缀当"要显示的图" */
function looksLikeImage(path: string): boolean {
  const lower: string = path.toLowerCase();
  return lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
    lower.endsWith('.webp') || lower.endsWith('.gif') || lower.endsWith('.bmp');
}

/**
 * 从内容块里找"要给我看的图"（**实测形状**）：
 *  - `present` 的 `arguments` = `{"files":[{"path":"…","description":"…"}]}`
 *  - `show_image` 的 `arguments` = `{"paths":["…"]}`
 * 别的一律不当图（工具调用参数里可能有一堆代码路径，不该显示）。
 */
function imagePathsFromBlocks(blocks: Object[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const block: Object = blocks[i];
    if (block === undefined || block === null || typeof block !== 'object') {
      continue;
    }
    const obj: Record<string, Object> = block as Record<string, Object>;
    if (obj['type'] !== 'tool-call') {
      continue;
    }
    const nameValue: Object | undefined = obj['name'];
    const name: string = typeof nameValue === 'string' ? nameValue as string : '';
    if (name !== 'present' && name !== 'show_image') {
      continue;
    }
    const argsValue: Object | undefined = obj['arguments'];
    const argsText: string = typeof argsValue === 'string' ? argsValue as string : '';
    if (argsText.length === 0) {
      continue;
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(argsText) as Record<string, Object>;
    } catch (parseError) {
      continue;
    }
    const filesValue: Object | undefined = parsed['files'];
    if (Array.isArray(filesValue)) {
      const files: Object[] = filesValue as Object[];
      for (let k = 0; k < files.length; k++) {
        const one: Object = files[k];
        if (one === undefined || one === null || typeof one !== 'object') {
          continue;
        }
        const p: Object | undefined = (one as Record<string, Object>)['path'];
        if (typeof p === 'string' && looksLikeImage(p as string)) {
          out.push(p as string);
        }
      }
    }
    const pathsValue: Object | undefined = parsed['paths'];
    if (Array.isArray(pathsValue)) {
      const paths: Object[] = pathsValue as Object[];
      for (let k = 0; k < paths.length; k++) {
        const p: Object = paths[k];
        if (typeof p === 'string' && looksLikeImage(p as string)) {
          out.push(p as string);
        }
      }
    }
  }
  return out;
}

/** 正文里的 `[名字][绝对路径]` 也算（老消息就是这么写的；例：`[a.png][<路径>\a.png]`） */function imagePathsInText(text: string): string[] {
  const out: string[] = [];
  const pattern: RegExp = /\[[^\]]*\]\[([A-Za-z]:[\\/][^\]]+)\]/g;
  let matched: RegExpMatchArray | null = text.match(pattern);
  if (matched === null) {
    return out;
  }
  for (let i = 0; i < matched.length; i++) {
    const raw: string = matched[i];
    const path: string = raw.substring(raw.indexOf('][') + 2, raw.length - 1);
    if (looksLikeImage(path)) {
      out.push(path);
    }
  }
  return out;
}

/**
 * 消息里的**图片附件**（实测形状）：`{type:'image', attachment:{attachmentId:'sha256:…', mediaType, width, height, bytes, name}}`
 * —— 用户自己发的图、助手回的图都可能长这样。`attachmentId` 直接当路径键（`sha256:` 前缀）。
 */
function attachmentIdsFromBlocks(blocks: Object[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const block: Object = blocks[i];
    if (block === undefined || block === null || typeof block !== 'object') {
      continue;
    }
    const obj: Record<string, Object> = block as Record<string, Object>;
    if (obj['type'] !== 'image') {
      continue;
    }
    const attachValue: Object | undefined = obj['attachment'];
    if (attachValue === undefined || attachValue === null || typeof attachValue !== 'object') {
      continue;
    }
    const idValue: Object | undefined = (attachValue as Record<string, Object>)['attachmentId'];
    if (typeof idValue === 'string' && (idValue as string).length > 0) {
      out.push(idValue as string);
    }
  }
  return out;
}

/** 消息的正文内容块（`assistant/message` → `data.message.content`；`user/message` → `data.content`） */
function contentBlocksOf(eventType: string, data: Object | undefined): Object[] {
  if (data === undefined || data === null || typeof data !== 'object') {
    return [];
  }
  const obj: Record<string, Object> = data as Record<string, Object>;
  const direct: Object | undefined = obj['content'];
  const messageObj: Object | undefined = obj['message'];
  let nested: Object | undefined = undefined;
  if (messageObj !== undefined && messageObj !== null && typeof messageObj === 'object') {
    nested = (messageObj as Record<string, Object>)['content'];
  }
  const first: Object | undefined = eventType === 'assistant/message' ? nested : direct;
  const second: Object | undefined = eventType === 'assistant/message' ? direct : nested;
  if (Array.isArray(first)) {
    return first as Object[];
  }
  if (Array.isArray(second)) {
    return second as Object[];
  }
  return [];
}

/**
 * 一条 `event` → 记录。
 * 文本走 `SessionPageModel.eventTexts`（**只取正式内容块**，避免重复）；
 * 同时带上 `source.kind`（判"是不是真用户消息"）与要显示的图片（附件 id 或本机文件路径）。
 */
export function recordOf(event: FrameEvent): FollowRecord {
  const texts: string[] = eventTexts(event.type, event.data);
  let joined: string = '';
  for (let i = 0; i < texts.length; i++) {
    joined = i === 0 ? texts[i] : `${joined}\n${texts[i]}`;
  }
  const images: string[] = [];
  const blocks: Object[] = contentBlocksOf(event.type, event.data);
  // ① 图片附件（用户/助手消息里的 image 块）
  const attachmentIds: string[] = attachmentIdsFromBlocks(blocks);
  for (let i = 0; i < attachmentIds.length; i++) {
    images.push(attachmentIds[i]);
  }
  // ② 工具调用带的"本机文件"（present / show_image）
  const fromTools: string[] = imagePathsFromBlocks(blocks);
  for (let i = 0; i < fromTools.length; i++) {
    images.push(fromTools[i]);
  }
  // ③ 正文里的 `[名][绝对路径]`
  const inText: string[] = imagePathsInText(joined);
  for (let i = 0; i < inText.length; i++) {
    images.push(inText[i]);
  }
  // ④ 文件附件（手机发出去的文件：`{type:'file', attachment:{attachmentId,name,bytes}}`）
  const files: FollowFile[] = filesFromBlocks(blocks);
  // ⑤ `present` 工具产出的文件卡片（`deliverables/presented`）：
  //    `data.files = [{description, path}]` ⇒ 每条变一张卡片，`name` 放**完整路径**（点开时走 `/api/file`）
  const presented: FollowFile[] = filesFromPresented(event.type, event.data);
  for (let i = 0; i < presented.length; i++) {
    files.push(presented[i]);
  }
  const rec: FollowRecord = {
    seq: event.seq, type: event.type, timeMs: event.time, text: joined,
    sourceKind: sourceKindOf(event.data), images: images, files: files
  };
  return rec;
}

/** `deliverables/presented` 的 `files` → 卡片用的 `FollowFile`（attachmentId 空、name=路径） */
function filesFromPresented(eventType: string, data: Object | undefined): FollowFile[] {
  const out: FollowFile[] = [];
  if (eventType !== 'deliverables/presented' || data === undefined || data === null) {
    return out;
  }
  const obj: Record<string, Object> = data as Record<string, Object>;
  const listRaw: Object | undefined = obj['files'];
  if (!Array.isArray(listRaw)) {
    return out;
  }
  const list: Object[] = listRaw as Object[];
  for (let i = 0; i < list.length; i++) {
    if (list[i] === null || list[i] === undefined) {
      continue;
    }
    const item: Record<string, Object> = list[i] as Record<string, Object>;
    const pathRaw: Object | undefined = item['path'];
    if (typeof pathRaw !== 'string' || (pathRaw as string).length === 0) {
      continue;
    }
    out.push({ attachmentId: '', name: pathRaw as string, bytes: -1 });
  }
  return out;
}

/**
 * 从内容块里取**文件附件**。
 * 实测形状（2026-10-18，`session/page` 里的 user/message）：
 * `{"type":"file","attachment":{"attachmentId":"sha256:…","name":"契约核对.md","bytes":27}}`
 */
function filesFromBlocks(blocks: Object[]): FollowFile[] {
  const out: FollowFile[] = [];
  for (let i = 0; i < blocks.length; i++) {
    // 畸形内容（如 [null]）不能让整帧消费中断
    if (blocks[i] === null || blocks[i] === undefined) {
      continue;
    }
    const block: Record<string, Object> = blocks[i] as Record<string, Object>;
    const kind: Object | undefined = block['type'];
    if (typeof kind !== 'string' || (kind as string) !== 'file') {
      continue;
    }
    const attRaw: Object | undefined = block['attachment'];
    const att: Record<string, Object> | undefined = attRaw === undefined || attRaw === null
      ? undefined : attRaw as Record<string, Object>;
    const id: string = att === undefined ? '' : strOf(att['attachmentId']);
    const name: string = att === undefined ? '' : strOf(att['name']);
    const bytes: number = att === undefined ? -1 : numOf(att['bytes']);
    out.push({ attachmentId: id, name: name, bytes: bytes });
  }
  return out;
}

function strOf(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : '';
}

function numOf(value: Object | undefined): number {
  return typeof value === 'number' ? value as number : -1;
}

/**
 * 人话原因。⚠️ 参数一律当"可能没有"：JSON 可选字段与 `err.message` 运行期都可能是 `undefined`，
 * 直接 `.length` 会抛 `Cannot read property length of undefined`（本轮实测把 App 崩掉过一次）。
 */
function humanOf(code: number, apiError: string | undefined, transport: string | undefined): string {
  const api: string = apiError === undefined || apiError === null ? '' : `${apiError}`;
  const net: string = transport === undefined || transport === null ? '' : `${transport}`;
  if (code === 0) {
    return '和电脑断开了（dsh 可能被关掉，或网络断了）';
  }
  if (api.length > 0) {
    return `电脑没把对话发过来：${api}`;
  }
  if (net.length > 0) {
    return `实时订阅出错：${net}`;
  }
  return `实时订阅出错（${code}）`;
}

export class SessionFollow {
  private ws: RawWs | undefined = undefined;
  private stopped: boolean = false;
  private gotSnapshot: boolean = false;
  /** 重连用的连接参数（首次 `start` 时记下） */
  private targetAddress: string = '';
  private targetSession: string = '';
  private targetPort: number = 0;
  private targetCookie: string = '';
  private sinkRef: FollowSink | undefined = undefined;
  private attempt: number = 0;
  /** 稳定计时器：连上 30s 才把重连计数清零 */
  private stableTimer: number = -1;
  private reconnectTimer: number = -1;

  hasSnapshot(): boolean {
    return this.gotSnapshot;
  }

  /**
   * 订阅一场会话。**同一个实例只能 start 一次**（换会话就 `stop()` 后新建）。
   *
   * 走**官方载体**：手机自建握手（`services/RawWs.ets`）经插件中转连 `/pair/dsh/api/remote.mux`，
   * 开一条 `session/follow` 逻辑流；服务端每帧 `{"type":"item","streamId":…,"value":<帧>}`。
   *
   * `pluginHost` = 插件地址（真机 tailnet `100.x`）；`cookie` = 配对拿到的 `name=value`。
   * 端口/前缀/Host 全由 `model/EntryPorts` 决定（插件口 插件端口、前缀 `/pair/dsh`、Host 回环 dsh 端口）。
   */
  start(pluginHost: string, sessionId: string, cookie: string, sink: FollowSink, pluginPort: number = 0): void {
    if (pluginPort <= 0) {
      pluginPort = activeProfile().pluginPort;
    }
    this.stopped = false;
    this.gotSnapshot = false;
    this.targetAddress = pluginHost;
    this.targetPort = pluginPort;
    this.targetSession = sessionId;
    this.targetCookie = cookie;
    this.sinkRef = sink;
    this.attempt = 0;
    this.open(sink);
  }

  /**
   * 真开一次（`start` 与重连都走它）。断线重连：`session/follow` 没有 resume 游标，
   * 所以重连就是**重新订阅一次** —— 首帧又是整段快照，界面按快照重建（客户要的"回答来了立刻显示"不受影响）。
   */
  private open(sink: FollowSink): void {
    const address: string = this.targetAddress;
    const sessionId: string = this.targetSession;
    const cookie: string = this.targetCookie;

    const target: RawWsTarget = {
      host: address,
      port: this.targetPort,
      path: `${DSH_PATH_PREFIX}/api/remote.mux`,
      hostHeader: `127.0.0.1:${activeProfile().dshPort}`,
      origin: `http://127.0.0.1:${activeProfile().dshPort}`,
      cookie: cookie
    };
    const ws: RawWs = new RawWs();
    this.ws = ws;

    ws.onOpen = () => {
      if (this.stopped) {
        return;
      }
      const frame: string = `{"type":"open","streamId":"f1","endpoint":"session/follow","payload":{"args":{"request":{"address":{"kind":"session","sessionId":${JSON.stringify(sessionId)}},"assistantStream":true,"maxMessages":200}}}}`;
      ws.sendText(frame);
    };
    ws.onText = (text: string) => {
      if (this.stopped) {
        return;
      }
      this.consume(text, sink);
    };
    ws.onFail = (message: string) => {
      if (this.stopped) {
        return;
      }
      sink.onError(humanOf(0, '', message), `raw ws: ${message}`);
      this.scheduleReconnect(sink);
    };
    ws.onClose = (code: number, reason: string) => {
      if (this.stopped) {
        return;
      }
      sink.onClosed(`订阅流结束（${this.gotSnapshot ? '历史已上屏' : '连快照都没拿到'}，code=${code}）`);
      this.scheduleReconnect(sink);
    };
    ws.connect(target);

    hilog.info(DOMAIN, TAG, 'F5FOLLOW subscribe via 官方载体（经插件）会话=%{public}s %{public}s:%{public}d（第 %{public}d 次）',
      sessionId.length > 12 ? sessionId.substring(sessionId.length - 12) : sessionId, address, this.targetPort,
      this.attempt + 1);
  }

  /** 断线重连：最多 `RECONNECT_MAX` 次，间隔 2s；成功后计数清零（在 `consume` 收到快照时） */
  private scheduleReconnect(sink: FollowSink): void {
    if (this.stopped || this.reconnectTimer >= 0) {
      return;
    }
    if (this.attempt >= RECONNECT_MAX) {
      hilog.warn(DOMAIN, TAG, 'F5FOLLOW 重连放弃（已试 %{public}d 次）', this.attempt);
      return;
    }
    this.attempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (this.stopped) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'F5FOLLOW 重连第 %{public}d 次', this.attempt);
      this.open(sink);
    }, RECONNECT_DELAY_MS);
  }

  /** 连上后稳定 30s 才把重连计数清零（避免"发完快照就断"导致无限重连） */
  private scheduleAttemptReset(): void {
    if (this.stableTimer >= 0) {
      clearTimeout(this.stableTimer);
    }
    this.stableTimer = setTimeout(() => {
      this.attempt = 0;
      this.stableTimer = -1;
    }, 30000);
  }

  /** 主动停止（**不再回调 onClosed/onError**：是调用方自己要停的） */
  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    const ws: RawWs | undefined = this.ws;
    this.ws = undefined;
    if (ws === undefined) {
      return;
    }
    try {
      ws.close();
    } catch (closeError) {
      hilog.warn(DOMAIN, TAG, 'F5FOLLOW close failed');
    }
    hilog.info(DOMAIN, TAG, 'F5FOLLOW stopped');
  }

  /** 一行 → 分发 */
  private consume(line: string, sink: FollowSink): void {
    let parsed: StreamLine;
    try {
      parsed = JSON.parse(line) as StreamLine;
    } catch (parseError) {
      hilog.warn(DOMAIN, TAG, 'F5FOLLOW line parse failed (len=%{public}d)', line.length);
      return;
    }
    const kind: string = parsed.type ?? '';
    if (kind === 'ping') {
      return;
    }
    if (kind === 'end') {
      if (!this.stopped) {
        sink.onClosed('电脑侧结束了这次订阅');
      }
      return;
    }
    if (kind === 'error') {
      const body: LineError | undefined = parsed.error;
      const detail: string = body === undefined || body === null
        ? '' : `${body.code ?? ''}${body.message !== undefined ? `｜${body.message}` : ''}`;
      sink.onError(humanOf(200, detail, ''), `插件错误行：${detail}`);
      return;
    }
    if (kind !== 'item') {
      return;
    }
    const frame: FollowFrame | undefined = parsed.value;
    if (frame === undefined || frame === null) {
      return;
    }
    const frameKind: string = frame.type ?? '';
    if (frameKind === 'snapshot') {
      const records: FollowRecord[] = [];
      const raw: FrameRecord[] | undefined = frame.records;
      if (raw !== undefined && raw !== null) {
        for (let i = 0; i < raw.length; i++) {
          const one: FrameRecord = raw[i];
          if (one !== undefined && one !== null && one.event !== undefined && one.event !== null) {
            records.push(recordOf(one.event));
          }
        }
      }
      let title: string = '';
      const proj: Projection | undefined = frame.projections;
      if (proj !== undefined && proj !== null && proj.values !== undefined && proj.values !== null) {
        title = proj.values.title ?? '';
      }
      this.gotSnapshot = true;
      // 审查 2026-10-22：以前一收快照就清零 ⇒ 对端"发完快照就断"会无限重连（永远到不了上限）。
      // 改成**稳定 30 秒**后才清零。
      this.scheduleAttemptReset();
      const snap: FollowSnapshot = { cursor: frame.cursor ?? 0, title: title, records: records };
      hilog.info(DOMAIN, TAG, 'F5FOLLOW snapshot cursor=%{public}d records=%{public}d',
        snap.cursor, records.length);
      sink.onSnapshot(snap);
      // 快照里可能有一轮"正在生成"的回答：服务端之后只补新增量，前半段必须从这里恢复
      const prefix: string = baselineTextOf(frame.assistantStream);
      if (prefix.length > 0) {
        hilog.info(DOMAIN, TAG, 'F5FOLLOW 恢复进行中的回答 %{public}d 字', prefix.length);
        sink.onStreamText(prefix);
      }
      return;
    }
    if (frameKind === 'event') {
      const event: FrameEvent | undefined = frame.event;
      if (event !== undefined && event !== null) {
        // 标题变了就通知界面（新建会话后 dsh 会自动起标题）
        if (event.type === 'session/title') {
          const freshTitle: string = titleOf(event.data);
          if (freshTitle.length > 0) {
            sink.onTitle(freshTitle);
          }
        }
        // 先在不在干活：界面据此显示「正在思考…／空闲」
        if (event.type === 'turn/start' || event.type === 'step/start') {
          sink.onTurnState(true);
        } else if (event.type === 'turn/end') {
          sink.onTurnState(false);
        }
        sink.onRecord(recordOf(event));
      }
      return;
    }
    if (frameKind === 'assistant-stream') {
      const live: AssistantFrame | undefined = frame.frame;
      if (live !== undefined && live !== null && live.type === 'start') {
        // 模型请求重试：旧尝试的残文要撤掉，新 delta 从头拼
        sink.onStreamReset();
        return;
      }
      const text: string = streamTextOf(frame);
      if (text.length > 0) {
        sink.onStreamText(text);
      }
      return;
    }
    // 其它帧（turn/step/tool/…）本页不渲染
  }
}

