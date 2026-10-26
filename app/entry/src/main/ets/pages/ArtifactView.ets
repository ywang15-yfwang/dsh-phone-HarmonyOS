import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { artifactUrl } from '../features/f16-artifacts/ArtifactClient';

@Entry
@Component
struct ArtifactView {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @State url: string = '';
  @State title: string = '工件';
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    try {
      const params = router.getParams() as Record<string, Object>;
      const name: string = typeof params['name'] === 'string' ? params['name'] as string : '';
      this.title = typeof params['title'] === 'string' ? params['title'] as string : '工件';
      if (name.length > 0) {
        this.url = artifactUrl(name);
      }
    } catch (error) {
      this.url = '';
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('‹').fontSize(20).height(34).width(36).backgroundColor('#eef1f5').fontColor('#3f4956')
          .onClick(() => {
            router.back();
          })
        Text(this.title).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#111111').layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      if (this.url.length > 0) {
        Web({ src: this.url, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
      } else {
        Text('没有工件地址').fontSize(13).fontColor('#8a8f98').layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop + 8 })
    .backgroundColor('#FFFBF5')
  }
}


