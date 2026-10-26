import { router } from '@kit.ArkUI';
import {
  UI_ACCENT, UI_SURFACE, UI_TEXT2, UI_NAV_HEIGHT, UI_CARD_RADIUS
} from '../model/UiTheme';

/**
 * 底部悬浮胶囊导航（2026-10-25）：电脑 / 文件 / 配置 三个标签。
 * 只做导航，不做动作；当前页用橙色胶囊标出来。
 */
@Component
export struct BottomNav {
  /** 'computer' | 'files' | 'config' */
  @Prop current: string = 'computer';

  private go(target: string, url: string): void {
    if (this.current === target) {
      return;
    }
    router.replaceUrl({ url: url });
  }

  @Builder
  tabItem(key: string, label: string, url: string) {
    Text(label)
      .fontSize(15)
      .fontWeight(this.current === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.current === key ? '#FFFFFF' : UI_TEXT2)
      .backgroundColor(this.current === key ? UI_ACCENT : Color.Transparent)
      .layoutWeight(1)
      .height(46)
      .textAlign(TextAlign.Center)
      .borderRadius(23)
      .onClick(() => {
        this.go(key, url);
      })
  }

  build() {
    Row({ space: 6 }) {
      this.tabItem('computer', '电脑', 'pages/Index')
      this.tabItem('files', '文件', 'pages/Files')
      this.tabItem('config', '配置', 'pages/ConfigHome')
    }
    .width('92%')
    .height(UI_NAV_HEIGHT)
    .padding(8)
    .backgroundColor(UI_SURFACE)
    .borderRadius(UI_CARD_RADIUS + 11)
    .shadow({ radius: 24, color: '#26A9744F', offsetY: 8 })
  }
}
