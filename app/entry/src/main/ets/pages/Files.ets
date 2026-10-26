import { BottomNav } from '../components/BottomNav';
import {
  UI_BG_TOP, UI_BG_BOTTOM, UI_SURFACE, UI_TEXT, UI_TEXT2, UI_TEXT3,
  UI_CARD_RADIUS, UI_NAV_SPACE
} from '../model/UiTheme';

/** 文件页（占位）：客户说先放入口，后面再做传输文件 */
@Entry
@Component
struct Files {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @StorageProp('safeBottomVp') safeBottom: number = 16;
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 12 }) {
        Column({ space: 6 }) {
          Text('文件').fontSize(28).fontWeight(FontWeight.Bold).fontColor(UI_TEXT).width('100%')
          Text('手机与电脑之间').fontSize(12).fontColor(UI_TEXT2).width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('文件传输还没做')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor(UI_TEXT)
          Text('之后可以上传到电脑，或从电脑拉取。')
            .fontSize(12).fontColor(UI_TEXT3)
        }
        .width('100%')
        .padding(24)
        .backgroundColor(UI_SURFACE)
        .borderRadius(UI_CARD_RADIUS)
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 8 })

        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: UI_NAV_SPACE })
      .alignItems(HorizontalAlign.Start)

      BottomNav({ current: 'files' })
        .margin({ bottom: this.safeBottom + 12 })
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 160,
      colors: [[UI_BG_TOP, 0.0], [UI_BG_BOTTOM, 1.0]]
    })
  }
}



