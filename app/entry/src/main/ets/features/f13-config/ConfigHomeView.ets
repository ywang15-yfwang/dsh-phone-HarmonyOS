import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { cleanupTemp } from '../../services/TempFiles';
import { getControlUrl, setControlUrl } from '../../services/GlobalSettings';
import { DeviceProfile } from '../../model/DeviceProfile';
import { profileStore } from '../../services/ProfileStore';
import { sshKeys } from '../../services/ssh/SshKeys';
import { pluginRequest } from '../../services/net/DshNet';
import { http } from '@kit.NetworkKit';
import { BottomNav } from '../../components/BottomNav';
import {
  UI_BG_TOP, UI_BG_BOTTOM, UI_SURFACE, UI_TEXT, UI_TEXT2, UI_TEXT3,
  UI_ACCENT, UI_ACCENT_SOFT, UI_WARN, UI_CARD_RADIUS, UI_NAV_SPACE, UI_LINE
} from '../../model/UiTheme';

/**
 * 配置总览（客户 2026-10-22 定）：
 *  - 上面：Tailscale 控制服务器地址（全局，一般不用改；改了要重连/重启 VPN 才生效）
 *  - 下面：已经配置过的电脑（点进去改那台电脑的配置，不在这里新增）
 *  - 底部入口在首页（配置 / 文件），本页是「配置」那一入口的目标页
 */
@Component
export struct ConfigHomeView {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @StorageProp('safeBottomVp') safeBottom: number = 16;
  @State controlUrl: string = '';
  @State hosts: string[] = [];
  @State names: string[] = [];
  @State pairedFlags: boolean[] = [];
  @State note: string = '';
  @Prop @Watch('onTickChanged') pageTick: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  onTickChanged(): void {
    this.reload();
  }

  private ctx(): common.Context | undefined {
    try {
      return this.getUIContext().getHostContext();
    } catch (error) {
      return undefined;
    }
  }

  private reload(): void {
    const c: common.Context | undefined = this.ctx();
    if (c === undefined) {
      return;
    }
    this.controlUrl = getControlUrl(c);
    const all: Record<string, DeviceProfile> = profileStore.loadAll(c);
    const keys: string[] = Object.keys(all);
    const hs: string[] = [];
    const ns: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      hs.push(keys[i]);
      const one: DeviceProfile = all[keys[i]];
      ns.push(one.name.length > 0 ? one.name : keys[i]);
    }
    this.hosts = hs;
    this.names = ns;
  }

  private saveControlUrl(): void {
    const c: common.Context | undefined = this.ctx();
    if (c === undefined) {
      return;
    }
    if (setControlUrl(c, this.controlUrl)) {
      this.note = '已保存。重连 / 重启 VPN 后生效。';
      promptAction.showToast({ message: '已保存', duration: 2000 });
    } else {
      this.note = '地址不合法（要以 http:// 或 https:// 开头）';
    }
  }

  private clearCache(): void {
    const c: common.Context | undefined = this.ctx();
    if (c === undefined) {
      return;
    }
    const removed: number = cleanupTemp(c);
    this.note = `已清除临时文件 ${removed} 个`;
    promptAction.showToast({ message: '已清理', duration: 2000 });
  }

  private openConfig(host: string, name: string): void {
    router.pushUrl({ url: 'pages/DeviceConfig', params: { host: host, label: name } });
  }

  /** 删掉一台电脑的配置（客户 2026-10-25：旧配置可由用户自己清掉重配） */
  private confirmRemove(host: string, name: string): void {
    AlertDialog.show({
      title: '删除配置',
      message: `删除「${name.length > 0 ? name : host}」这台电脑的配置？`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#b3261e',
        action: () => {
          const c: common.Context | undefined = this.ctx();
          if (c === undefined) {
            return;
          }
          if (profileStore.remove(c, host)) {
            promptAction.showToast({ message: '已删除', duration: 1500 });
            this.reload();
          } else {
            this.note = '删除失败，请重试';
          }
        }
      }
    });
  }

  /** 把本机 SSH 公钥发给这台电脑的插件：电脑上会弹 UAC，点“是”即自动登记 */
  private async pairComputer(host: string, index: number): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const profile = profileStore.get(ctx, host);
    if (profile === undefined || profile.pluginPort <= 0) {
      promptAction.showToast({ message: '这台电脑还没配置插件端口', duration: 2500 });
      return;
    }
    try {
      await sshKeys.ensure(ctx);
      const key: string = sshKeys.publicKeyLine();
      promptAction.showToast({ message: '已发送，请在电脑上点 UAC「是」', duration: 3000 });
      const res = await pluginRequest(host, profile.pluginPort, http.RequestMethod.POST,
        '/pair/register-key', JSON.stringify({ publicKey: key }));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        profile.paired = true;
        profileStore.save(ctx, host, profile);
        this.pairedFlags[index] = true;
        promptAction.showToast({ message: '完成配对', duration: 3000 });
      } else {
        promptAction.showToast({ message: '电脑上未允许（UAC 被拒）', duration: 3000 });
      }
    } catch (error) {
      promptAction.showToast({ message: '发送失败：电脑插件没连上', duration: 3000 });
    }
  }
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 12 }) {
        Column({ space: 2 }) {
          Text('配置').fontSize(28).fontWeight(FontWeight.Bold).fontColor(UI_TEXT).width('100%')
          Text('网络、电脑与存储').fontSize(12).fontColor(UI_TEXT2).width('100%')
        }
        .width('100%')
        .padding({ top: 8 })
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('Tailscale 控制服务器').fontSize(13).fontColor(UI_TEXT2).width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.controlUrl, placeholder: 'https://controlplane.tailscale.com' })
              .fontSize(14).fontColor(UI_TEXT).placeholderColor(UI_TEXT3)
              .layoutWeight(1).height(42)
              .backgroundColor('#FBF4EC')
              .borderRadius(12)
            Text('保存')
              .fontSize(13).fontColor('#FFFFFF')
              .height(36).padding({ left: 16, right: 16 })
              .backgroundColor(UI_ACCENT).borderRadius(18)
              .onClick(() => {
                this.saveControlUrl();
              })
          }
          .width('100%')
          Text('一般不用改；换自建 headscale 时才需要填。改完重连 / 重启 VPN 生效。')
            .fontSize(11).fontColor(UI_TEXT3).width('100%')
        }
        .width('100%')
        .padding(16)
        .backgroundColor(UI_SURFACE)
        .borderRadius(UI_CARD_RADIUS)

        Text('已配置的电脑').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UI_TEXT).width('100%')

        if (this.hosts.length === 0) {
          Text('还没有配置过电脑。回「电脑」页选一台，点「配置」。')
            .fontSize(12).fontColor(UI_TEXT3).width('100%')
            .padding(16)
            .backgroundColor(UI_SURFACE)
            .borderRadius(UI_CARD_RADIUS)
        } else {
          List({ space: 10 }) {
            ForEach(this.hosts, (host: string, index: number) => {
              ListItem() {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(this.names[index]).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UI_TEXT).width('100%')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Text('删除')
                    .fontSize(12).fontColor(UI_WARN)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor('#FBE7E4').borderRadius(12)
                    .onClick(() => {
                      this.confirmRemove(host, this.names[index]);
                    })
                  Text('修改')
                    .fontSize(12).fontColor(UI_ACCENT)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor(UI_ACCENT_SOFT).borderRadius(12)
                    .onClick(() => {
                      this.openConfig(host, this.names[index]);
                    })
                }
                .width('100%')
                .padding(14)
                .backgroundColor(UI_SURFACE)
                .borderRadius(UI_CARD_RADIUS)
              }
            }, (host: string) => host)
          }
          .width('100%')
          .layoutWeight(1)
        }

        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text('清除临时文件').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UI_TEXT).width('100%')
              Text('下载 / 打开 / 保存的中转文件').fontSize(11).fontColor(UI_TEXT3).width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('清理')
              .fontSize(12).fontColor(UI_ACCENT)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .backgroundColor(UI_ACCENT_SOFT).borderRadius(12)
              .onClick(() => {
                this.clearCache();
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(UI_SURFACE)
          .borderRadius(UI_CARD_RADIUS)
        }
        .width('100%')

        if (this.note.length > 0) {
          Text(this.note).fontSize(11).fontColor(UI_TEXT3).width('100%')
        }
        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: UI_NAV_SPACE })
      .alignItems(HorizontalAlign.Start)

      BottomNav({ current: 'config' })
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








