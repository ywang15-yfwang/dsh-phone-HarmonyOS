import { ComputerListView } from '../features/f11-computer-status/ComputerListView';
import { BottomNav } from '../components/BottomNav';
import { UI_BG_TOP, UI_BG_BOTTOM, UI_NAV_SPACE } from '../model/UiTheme';

/**
 * **第二页外壳：网络里的电脑**（登录网络 → 网络里的电脑 → 会话页）。
 * 2026-10-25：改成暖色卡片风 + 底部悬浮胶囊导航（电脑 / 文件 / 配置）。
 */
@Entry
@Component
struct Index {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @StorageProp('safeBottomVp') safeBottom: number = 16;
  /** 每次页面重新可见 +1；传给子组件触发重算 */
  @State pageTick: number = 0;

  onPageShow(): void {
    this.pageTick = this.pageTick + 1;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        ComputerListView({ pageTick: this.pageTick })
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: UI_NAV_SPACE })

      BottomNav({ current: 'computer' })
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


