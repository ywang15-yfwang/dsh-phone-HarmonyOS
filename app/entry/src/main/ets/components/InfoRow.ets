/**
 * 键值行 —— **公共展示件**（功能 1 / 3 / 4 / 11 都用）。
 *
 * 为什么抽到公共件：它原本长在 `pages/Index.ets` 里（未导出），任何页面内的功能块要用都得复制一份；
 * 抽成 `@Component` 后各功能块 import 同一份。
 *
 * 用 `@Prop` 子组件而非带参 `@Builder` —— 后者不随状态刷新（首帧后不再更新）。
 */
@Component
export struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    // 大字体（系统最大档 ≈1.45×）下原来 label 与 value 会**挤到一起**（`Blank()` 被压没了）
    // ⇒ 各占一半、各允许 2 行、顶部对齐；不许把信息挤掉。
    Row() {
      Text(this.label).fontSize(14).fontColor('#444444')
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.value).fontSize(14).fontColor('#111111').textAlign(TextAlign.End)
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}
