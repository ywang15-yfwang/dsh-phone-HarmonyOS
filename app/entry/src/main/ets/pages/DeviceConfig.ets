import { router } from '@kit.ArkUI';
import { DeviceConfigParams, DeviceConfigView } from '../features/f12-config/DeviceConfigView';

/**
 * 配置页外壳（客户 2026-10-21）：从首页点「配置」进来，一台上一条配置。
 * 真正的实现在 `features/f12-config/DeviceConfigView`（整块拿走 = 删那个目录 + 本文件一行）。
 */
@Entry
@Component
struct DeviceConfig {
  @State host: string = '';
  @State label: string = '';

  aboutToAppear(): void {
    try {
      const params = router.getParams() as DeviceConfigParams;
      if (params !== null && params !== undefined) {
        this.host = params.host;
        this.label = params.label;
      }
    } catch (error) {
      this.host = '';
      this.label = '';
    }
  }

  build() {
    Column() {
      DeviceConfigView({ host: this.host, label: this.label })
    }
    .width('100%')
    .height('100%')
  }
}
