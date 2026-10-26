import { ConversationView } from '../features/f08-conversation/ConversationView';

/**
 * 会话页 —— **只是外壳**。
 *
 * 功能 8「界面（会话 ＋ 左侧可收缩栏）」的实现**全在** `features/f08-conversation/ConversationView.ets`；
 * 本文件只负责把它挂成 `@Entry` 页面（ArkTS 要求页面文件里有 `@Entry`）。
 *
 * ⇒ 「一个功能一块」落到实处：整块拿走 = 删 `features/f08-conversation/` ＋ 本文件这一行。
 */
@Entry
@Component
struct Conversation {
  build() {
    // `@Entry` 的 build 必须是**一个容器根节点** ⇒ 包一层 Column（本身不带任何样式语义）
    Column() {
      ConversationView()
    }
    .width('100%')
    .height('100%')
  }
}
