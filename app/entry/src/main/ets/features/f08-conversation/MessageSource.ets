import { ChatMessage } from './ChatModel';

/**
 * 聊天列表的数据源（`LazyForEach` 用）。
 *
 * 为什么要有：原来用 `Scroll + Column + ForEach`，进会话就**一次性建出全部气泡**
 * （实测这场会话 1200+ 条），首帧和滑动都会卡。改成 `List + LazyForEach` 后只建可视区附近的几条。
 *
 * 通知策略（够用且不抖）：
 *  · 条数变了（快照重建 / 追加一条）⇒ `notifyDataReload()`；
 *  · 条数没变（助手逐字流在改最后一条 / 合并一条记录）⇒ 只 `notifyDataChange(最后一条)`，
 *    这样逐字流不会每帧刷整张表。
 */
export class MessageSource implements IDataSource {
  private items: ChatMessage[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): ChatMessage {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /** 换一批消息（条数变了就整表刷新，否则只刷最后一条） */
  /**
   * 整表替换（重连快照 / 合并结果）。
   *
   * 审查 2026-10-22 修：以前"条数不变只刷新最后一条" ⇒ 本机回显被真实消息替换（删头加尾、条数不变）时，
   * 屏幕上那条旧回显永远不会更新。现在：**逐项比对**，键序列变了就整表 reload，
   * 否则把每个内容有变化的条目都通知一遍。
   */
  setAll(next: ChatMessage[]): void {
    const old: ChatMessage[] = this.items;
    this.items = next;
    let sameKeys: boolean = old.length === next.length;
    if (sameKeys) {
      for (let i = 0; i < next.length; i++) {
        if (old[i].key !== next[i].key) {
          sameKeys = false;
          break;
        }
      }
    }
    if (!sameKeys) {
      for (let i = 0; i < this.listeners.length; i++) {
        this.listeners[i].onDataReloaded();
      }
      return;
    }
    for (let i = 0; i < next.length; i++) {
      if (sameContent(old[i], next[i])) {
        continue;
      }
      for (let k = 0; k < this.listeners.length; k++) {
        this.listeners[k].onDataChange(i);
      }
    }
  }
}

/** 两条气泡内容是否一致（决定要不要通知刷新） */
function sameContent(a: ChatMessage, b: ChatMessage): boolean {
  if (a.text !== b.text || a.streaming !== b.streaming) {
    return false;
  }
  if (a.images.length !== b.images.length || a.files.length !== b.files.length) {
    return false;
  }
  for (let i = 0; i < a.images.length; i++) {
    if (a.images[i] !== b.images[i]) {
      return false;
    }
  }
  for (let i = 0; i < a.files.length; i++) {
    if (a.files[i].name !== b.files[i].name || a.files[i].attachmentId !== b.files[i].attachmentId) {
      return false;
    }
  }
  return true;
}