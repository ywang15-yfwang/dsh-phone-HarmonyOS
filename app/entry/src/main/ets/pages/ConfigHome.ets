import { ConfigHomeView } from '../features/f13-config/ConfigHomeView';

/** 配置页外壳：底部「配置」入口进来 */
@Entry
@Component
struct ConfigHome {
  @State pageTick: number = 0;

  onPageShow(): void {
    this.pageTick = this.pageTick + 1;
  }

  build() {
    Column() {
      ConfigHomeView({ pageTick: this.pageTick })
    }
    .width('100%')
    .height('100%')
  }
}
