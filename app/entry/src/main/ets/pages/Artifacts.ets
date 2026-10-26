import { router } from '@kit.ArkUI';
import { ArtifactItem, listArtifacts } from '../features/f16-artifacts/ArtifactClient';
import {
  UI_BG_TOP, UI_BG_BOTTOM, UI_SURFACE, UI_TEXT, UI_TEXT2, UI_TEXT3,
  UI_ACCENT, UI_ACCENT_SOFT, UI_CARD_RADIUS
} from '../model/UiTheme';

@Entry
@Component
struct Artifacts {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @State items: ArtifactItem[] = [];
  @State note: string = '正在读取工件…';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const items: ArtifactItem[] = await listArtifacts();
    this.items = items;
    this.note = items.length === 0 ? '电脑上还没有工件' : '';
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Button('‹')
          .fontSize(22)
          .height(40)
          .width(40)
          .borderRadius(20)
          .backgroundColor(UI_SURFACE)
          .fontColor(UI_TEXT)
          .onClick(() => {
            router.back();
          })
        Text('工件')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.items.length === 0) {
        Column({ space: 6 }) {
          Text(this.note).fontSize(13).fontColor(UI_TEXT2)
        }
        .width('100%')
        .padding(24)
        .backgroundColor(UI_SURFACE)
        .borderRadius(UI_CARD_RADIUS)
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (one: ArtifactItem) => {
            ListItem() {
              Row({ space: 12 }) {
                Text('▤')
                  .fontSize(18)
                  .fontColor(UI_ACCENT)
                  .width(40)
                  .height(40)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(UI_ACCENT_SOFT)
                  .borderRadius(12)
                Column({ space: 3 }) {
                  Text(one.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UI_TEXT).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(one.name).fontSize(11).fontColor(UI_TEXT3).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text('›').fontSize(18).fontColor(UI_TEXT3)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(UI_SURFACE)
              .borderRadius(UI_CARD_RADIUS)
              .onClick(() => {
                router.pushUrl({ url: 'pages/ArtifactView', params: { name: one.name, title: one.title } });
              })
            }
          }, (one: ArtifactItem) => one.name)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: 16 })
    .linearGradient({
      angle: 160,
      colors: [[UI_BG_TOP, 0.0], [UI_BG_BOTTOM, 1.0]]
    })
  }
}

