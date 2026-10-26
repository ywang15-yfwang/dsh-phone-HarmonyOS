import { WelcomeView } from '../features/f01-tailnet/WelcomeView';

/**
 * **第一页外壳：登录网络**（功能 11「加入 Tailscale 网络」的入口）。
 *
 * ⚠️ 本文件**只是外壳**：实现全在 `features/f01-tailnet/WelcomeView.ets`
 * （一个功能一块 —— 页面里只留一行引用）。
 *
 * `onPageShow` 只能写在 **@Entry 页面**上（写在子组件里不会被调用）：
 * 从系统浏览器授权完切回 App 时要靠它再查一次入网状态。
 */
@Entry
@Component
struct Welcome {
  /** 每次页面重新可见 +1，转发给子组件触发重查 */
  @State resumeTick: number = 0;

  onPageShow(): void {
    this.resumeTick = this.resumeTick + 1;
  }

  build() {
    Column() {
      WelcomeView({ resumeTick: this.resumeTick })
    }
    .width('100%')
    .height('100%')
  }
}
