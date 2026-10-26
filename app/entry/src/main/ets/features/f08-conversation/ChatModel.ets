import { FollowFile, FollowRecord } from './FollowStream';

/**
 * 聊天气泡模型（功能 5/8 的**纯逻辑**：零 Kit 依赖 ⇒ 本机可断言，不需要设备）。
 *
 * 口径：
 *  - 一条气泡 = 一条 `user/message` 或 `assistant/message` 事件；
 *  - **用户消息只认真的**：`data.source.kind === 'user'`。dsh 注入的
 *    `runtime-context` / `skill-catalog` / `agent-instructions`、队友的 `team-message`、
 *    子代理的 `subagent-settled` **都不进气泡**（客户 2026-10-17：别把注入当我说的话）；
 *  - **同 seq 覆盖**：助手先来"逐字流"、后来"完整消息" ⇒ 用完整消息覆盖同 seq 的流式气泡（不重复、不两行）；
 *  - **本机乐观回显**：点发送时立刻上屏一条 `local-*` 气泡，等电脑侧真回同文本的 `user/message` 时**把它撤掉**；
 *  - **图片**：消息里带的电脑图片路径（`images`）原样带到气泡上，由界面去取字节显示；
 *  - 文本与图片都为空的事件**不显示**（避免空气泡）。
 */

/** 一条气泡 */
export interface ChatMessage {
  /** 稳定键：`seq-<序号>` / `live`（逐字流）/ `local-<时刻>`（本机回显） */
  key: string;
  seq: number;
  /** 'user' | 'assistant' */
  role: string;
  text: string;
  timeMs: number;
  /** 正在逐字流（显示时会带一点"正在输入"的意味） */
  streaming: boolean;
  /** 这条消息里要显示的**电脑上的图片**路径 */
  images: string[];
  /** 这条消息带的**文件附件**（手机发出去的文件） */
  files: FollowFile[];
}

/** 事件类型 → 角色（不认识的返回空串 ⇒ 不进气泡） */
export function roleOf(eventType: string): string {
  if (eventType === 'user/message') {
    return 'user';
  }
  if (eventType === 'assistant/message') {
    return 'assistant';
  }
  // **`present` 工具产出的"文件卡片"**（客户 2026-10-18：我在对话里发的卡片，手机上一个都没有）
  // 官方事件：`deliverables/presented`，`data.files = [{description, path}]`
  if (eventType === 'deliverables/presented') {
    return 'assistant';
  }
  return '';
}

/** 这条记录该不该进气泡（用户消息必须 `source.kind === 'user'`） */
export function acceptedRecord(rec: FollowRecord): boolean {
  const role: string = roleOf(rec.type);
  if (role.length === 0) {
    return false;
  }
  if (role === 'user') {
    return rec.sourceKind === 'user';
  }
  return true;
}

function keyOf(seq: number): string {
  return `seq-${seq}`;
}

/** 排序：真实消息按 seq 升序；本机回显（seq < 0）**排在最后**，不能被顶到历史前面 */
function bySeq(a: ChatMessage, b: ChatMessage): number {
  const aLocal: boolean = a.seq < 0;
  const bLocal: boolean = b.seq < 0;
  if (aLocal !== bLocal) {
    return aLocal ? 1 : -1;
  }
  return a.seq - b.seq;
}

/** 记录列表 → 气泡列表（按 seq 升序） */
export function messagesFromRecords(records: FollowRecord[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (let i = 0; i < records.length; i++) {
    const r: FollowRecord = records[i];
    if (!acceptedRecord(r)) {
      continue;
    }
    if (r.text.length === 0 && r.images.length === 0 && r.files.length === 0) {
      continue;
    }
    out.push({
      key: keyOf(r.seq), seq: r.seq, role: roleOf(r.type), text: r.text,
      timeMs: r.timeMs, streaming: false, images: r.images, files: r.files
    });
  }
  out.sort(bySeq);
  return out;
}

/** 本机乐观回显的气泡（还没得到电脑侧确认）；`fileName` 非空 = 这条带着一个刚上传的文件 */
export function localMessage(text: string, fileName: string = ''): ChatMessage {
  const files: FollowFile[] = fileName.length > 0
    ? [{ attachmentId: '', name: fileName, bytes: -1 }]
    : [];
  return {
    key: `local-${Date.now()}`, seq: -1, role: 'user', text: text, timeMs: Date.now(),
    streaming: false, images: [], files: files
  };
}

/**
 * 把一条新记录并进列表：
 *  - 不该进气泡的类型/来源 ⇒ 原样返回；
 *  - 助手的那条**完整消息**到了 ⇒ 先撤掉逐字流气泡（`live`），再用它覆盖同 seq；
 *  - 电脑侧确认了本机刚发的那句 ⇒ 撤掉对应的 `local-*` 回显（**只认电脑侧这条**）。
 */
export function mergeRecord(list: ChatMessage[], rec: FollowRecord): ChatMessage[] {
  if (!acceptedRecord(rec)) {
    return list;
  }
  const role: string = roleOf(rec.type);
  // 只有文件（没有文字/图片）的消息也必须留下 —— 否则发视频不写字，电脑侧回执会被整条丢掉
  if (rec.text.length === 0 && rec.images.length === 0 && rec.files.length === 0) {
    return list;
  }
  const next: ChatMessage[] = [];
  for (let i = 0; i < list.length; i++) {
    // **只在助手的完整消息到达时**撤逐字流气泡；用户/附件记录不该把正在流出的回答抹掉
    if (!(list[i].key === 'live' && role === 'assistant')) {
      next.push(list[i]);
    }
  }
  // 电脑侧确认了本机发的这句 ⇒ 撤掉回显（按文本比对，比对成功只撤一条）
  if (role === 'user') {
    let dropped: boolean = false;
    const kept: ChatMessage[] = [];
    for (let i = 0; i < next.length; i++) {
      const m: ChatMessage = next[i];
      // 文本消息按 trim 后比对；纯附件消息（电脑侧 text 为空）撤掉最早的一条回显
      const sameText: boolean = m.text.trim() === rec.text.trim();
      const attachmentEcho: boolean = rec.text.length === 0 &&
        (rec.files.length > 0 || rec.images.length > 0);
      if (!dropped && m.key.startsWith('local-') && (sameText || attachmentEcho)) {
        dropped = true;
        continue;
      }
      kept.push(m);
    }
    next.length = 0;
    for (let i = 0; i < kept.length; i++) {
      next.push(kept[i]);
    }
  }
  // 同 seq 覆盖（文本可能从"部分"变成"完整"）
  let replaced: boolean = false;
  for (let i = 0; i < next.length; i++) {
    if (next[i].seq === rec.seq) {
      next[i] = {
        key: keyOf(rec.seq), seq: rec.seq, role: role, text: rec.text,
        timeMs: rec.timeMs, streaming: false, images: rec.images, files: rec.files
      };
      replaced = true;
      break;
    }
  }
  if (!replaced) {
    next.push({
      key: keyOf(rec.seq), seq: rec.seq, role: role, text: rec.text,
      timeMs: rec.timeMs, streaming: false, images: rec.images, files: rec.files
    });
  }
  next.sort(bySeq);
  return next;
}

/** 助手逐字流：拼进末尾那条 `live` 气泡（没有就新建一条） */export function appendStreamText(list: ChatMessage[], text: string, atMs: number): ChatMessage[] {
  const next: ChatMessage[] = [];
  for (let i = 0; i < list.length; i++) {
    next.push(list[i]);
  }
  for (let i = next.length - 1; i >= 0; i--) {
    if (next[i].key === 'live') {
      next[i] = {
        key: 'live', seq: next[i].seq, role: 'assistant',
        text: `${next[i].text}${text}`, timeMs: next[i].timeMs, streaming: true,
        images: next[i].images, files: next[i].files
      };
      return next;
    }
  }
  let maxSeq: number = 0;
  for (let i = 0; i < next.length; i++) {
    if (next[i].seq > maxSeq) {
      maxSeq = next[i].seq;
    }
  }
  next.push({
    key: 'live', seq: maxSeq + 1, role: 'assistant', text: text, timeMs: atMs,
    streaming: true, images: [], files: []
  });
  return next;
}

/**
 * 丢掉正在拼的逐字气泡。dsh 的模型请求重试会换 attemptId 重新发 start，
 * 旧尝试的半句不能留在新尝试前面（否则界面上会出现"前一次半句+这次整句"）。
 */
export function dropLiveStream(list: ChatMessage[]): ChatMessage[] {
  const next: ChatMessage[] = [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].key !== 'live') {
      next.push(list[i]);
    }
  }
  return next;
}






