import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, promptAction } from '@kit.ArkUI';
import { DEFAULT_DSH_PORT, DeviceProfile, profileProblem } from '../../model/DeviceProfile';
import { profileStore } from '../../services/ProfileStore';
import { clearHostKey } from '../../services/ssh/HostKeyStore';
import { sshKeys } from '../../services/ssh/SshKeys';
import { pluginRequest } from '../../services/net/DshNet';
import { http } from '@kit.NetworkKit';
import { UI_TEXT, UI_TEXT2, UI_TEXT3, UI_SURFACE, UI_ACCENT, UI_ACCENT_SOFT, UI_WARN, UI_LINE, UI_CARD_RADIUS } from '../../model/UiTheme';

const DOMAIN: number = 0xD001;
const TAG: string = 'F12CONF';

/** 配置页传参 */
export interface DeviceConfigParams {
  /** 电脑的 tailnet 地址（配置键） */
  host: string;
  /** 列表里显示的名字（仅提示用） */
  label: string;
}

/**
 * **每台电脑的连接配置**（客户 2026-10-21）：
 *  - 没配置过的电脑，首页不给「连接」，只给「配置」；
 *  - **保存不测任何端口**（客户 2026-10-25 定）：配置只是先记下来，
 *    电脑可能还没开机，dsh 更没起 —— 连通性一律等到点「开启 / 连接」时再判；
 *  - 保存后**回读一次**，写进去的值必须就是输入值（防"看着保存了、其实没落盘"）；
 *  - 「取消」= 不保存，直接回首页。
 */
@Component
export struct DeviceConfigView {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @Prop host: string = '';
  @Prop label: string = '';

  @State name: string = '';
  @State dshPortText: string = '';
  @State pluginPortText: string = '';
  @State sshPortText: string = '';
  @State sshUser: string = '';
  @State errorText: string = '';
  @State saving: boolean = false;
  @State paired: boolean = false;

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.ctx();
    const stored: DeviceProfile | undefined = ctx === undefined ? undefined : profileStore.get(ctx, this.host);
    // 设备名预填（客户 2026-10-25）：已有配置名 > 这台电脑的名字（列表传进来的）> 留空 + 占位。
    // 不再拿手机型号当默认值 —— 那是手机自己的名字，不是这台电脑的。
    this.name = stored !== undefined && stored.name.trim().length > 0
      ? stored.name
      : (this.label.length > 0 && this.label !== this.host ? this.label : '');
    this.dshPortText = stored !== undefined && stored.dshPort > 0 ? `${stored.dshPort}` : `${DEFAULT_DSH_PORT}`;
    this.pluginPortText = stored !== undefined && stored.pluginPort > 0 ? `${stored.pluginPort}` : '';
    this.sshPortText = stored !== undefined && stored.sshPort > 0 ? `${stored.sshPort}` : '';
    this.sshUser = stored !== undefined ? stored.sshUser : '';
    this.paired = stored !== undefined && stored.paired === true;
  }

  private ctx(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  private num(text: string): number {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return 0;
    }
    const value: number = Number(trimmed);
    return Number.isFinite(value) ? Math.round(value) : 0;
  }

  private draft(): DeviceProfile {
    return {
      name: this.name.trim(),
      dshPort: this.num(this.dshPortText),
      pluginPort: this.num(this.pluginPortText),
      sshPort: this.num(this.sshPortText),
      sshUser: this.sshUser.trim(),
      paired: this.paired
    };
  }

  /** 保存：本地校验 → 落盘 → 回读比对（**不测任何端口**，客户 2026-10-25 定） */
  private save(): void {
    if (this.saving) {
      return;
    }
    this.errorText = '';
    const profile: DeviceProfile = this.draft();
    const problem: string = profileProblem(profile);
    if (problem.length > 0) {
      this.errorText = problem;
      return;
    }
    const ctx: common.Context | undefined = this.ctx();
    if (ctx === undefined) {
      this.errorText = '拿不到应用上下文';
      return;
    }
    this.saving = true;
    try {
      const saved: boolean = profileStore.save(ctx, this.host, profile);
      if (!saved) {
        this.errorText = '配置写入手机失败，请重试';
        return;
      }
      // 回读校验：写进去的值必须就是输入值（否则就是"看着保存了、其实没落盘"）
      const back: DeviceProfile | undefined = profileStore.get(ctx, this.host);
      const same: boolean = back !== undefined && back.name === profile.name && back.dshPort === profile.dshPort &&
        back.pluginPort === profile.pluginPort && back.sshPort === profile.sshPort && back.sshUser === profile.sshUser;
      if (!same) {
        this.errorText = '保存后回读不一致，请重试';
        hilog.warn(DOMAIN, TAG, '配置回读不一致');
        return;
      }
      hilog.info(DOMAIN, TAG, '配置已保存 dsh=%{public}d 插件=%{public}d SSH=%{public}d',
        profile.dshPort, profile.pluginPort, profile.sshPort);
      promptAction.showToast({ message: '配置已保存', duration: 1500 });
      router.back();
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(DOMAIN, TAG, '保存失败 %{public}s', e.message);
      this.errorText = `保存失败：${e.message}`;
    } finally {
      this.saving = false;
    }
  }

  private cancel(): void {
    router.back();
  }

  @Builder
  field(label: string, hint: string, value: string, onChange: (v: string) => void, numeric: boolean) {
    Column({ space: 4 }) {
      Text(label).fontSize(12).fontColor(UI_TEXT2)
      Row() {
        TextInput({ text: value, placeholder: hint })
          .type(numeric ? InputType.Number : InputType.Normal)
            // 测通/保存期间锁住输入：否则界面显示新值、落盘却是点保存那一刻的旧值
            .enabled(!this.saving)
          // 页面是浅色底：不显式给颜色时，系统深色模式下输入框字会跟着主题变成浅色 ⇒ 看不见预填值
          .fontColor(UI_TEXT)
          .placeholderColor(UI_TEXT3)
          .fontSize(15)
          .height(44)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onChange((v: string) => {
            onChange(v);
          })
      }
      .padding({ left: 10, right: 10 })
      .borderRadius(12)
      .border({ width: 1, color: UI_LINE })
      .backgroundColor(UI_SURFACE)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 12 })
  }

  /** 配对：把本机 SSH 公钥发给这台电脑的插件，电脑上会弹 UAC；成功即写入授权文件 */
  private async pairComputer(): Promise<void> {
    const c: common.Context | undefined = this.ctx();
    if (c === undefined) {
      return;
    }
    const port: number = this.num(this.pluginPortText);
    if (port <= 0) {
      this.errorText = '先填插件端口，再点配对';
      return;
    }
    try {
      await sshKeys.ensure(c);
      promptAction.showToast({ message: '请在电脑上点 UAC「是」', duration: 3000 });
      const res = await pluginRequest(this.host, port, http.RequestMethod.POST,
        '/pair/register-key', JSON.stringify({ publicKey: sshKeys.publicKeyLine() }));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        this.paired = true;
        const stored: DeviceProfile | undefined = profileStore.get(c, this.host);
        const profile: DeviceProfile = stored !== undefined ? stored : this.draft();
        profile.paired = true;
        profile.pluginPort = port;
        profileStore.save(c, this.host, profile);
        promptAction.showToast({ message: '完成配对', duration: 3000 });
      } else {
        this.errorText = '电脑上未允许（UAC 被拒）';
      }
    } catch (error) {
      this.errorText = '电脑插件没连上：先在电脑上打开 dsh';
    }
  }
  build() {
    Column() {
      Row({ space: 8 }) {
        Button('‹')
          .enabled(!this.saving)
          .fontSize(22)
          .height(40)
          .width(40)
          .borderRadius(20)
          .backgroundColor(UI_SURFACE)
          .fontColor(UI_TEXT)
          .onClick(() => {
            this.cancel();
          })
        Text('连接配置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      Scroll() {
        Column() {
          Text(`这台电脑：${this.label.length > 0 ? this.label : this.host}`)
            .fontSize(12)
            .fontColor(UI_TEXT2)
            .width('100%')
            .margin({ bottom: 4 })

          this.field('设备名（显示在电脑上）', '例如：家里的电脑', this.name, (v: string) => {
            this.name = v;
          }, false)
          this.field('dsh 端口', `${DEFAULT_DSH_PORT}`, this.dshPortText, (v: string) => {
            this.dshPortText = v;
          }, true)
          this.field('插件端口（必填）', '例如电脑上配对插件的监听口', this.pluginPortText, (v: string) => {
            this.pluginPortText = v;
          }, true)
          this.field('SSH 端口（必填）', '电脑 sshd 监听的口', this.sshPortText, (v: string) => {
            this.sshPortText = v;
          }, true)
          this.field('SSH 用户名（必填）', '电脑上的 Windows 账号名', this.sshUser, (v: string) => {
            this.sshUser = v;
          }, false)

          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(this.paired ? '此电脑已配对' : '未配对')
                .fontSize(13).fontColor(this.paired ? '#2E7D32' : UI_TEXT2).width('100%')
              Text('配对会把这台手机的 SSH 公钥写入电脑，电脑上需点一次 UAC')
                .fontSize(11).fontColor(UI_TEXT3).width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Button(this.paired ? '重新配对' : '配对电脑')
              .fontSize(13)
              .constraintSize({ minHeight: 34 })
              .padding({ left: 14, right: 14 })
              .backgroundColor(UI_ACCENT_SOFT)
              .fontColor(UI_ACCENT)
              .borderRadius(17)
              .onClick(() => {
                void this.pairComputer();
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(UI_SURFACE)
          .borderRadius(UI_CARD_RADIUS)
          .margin({ bottom: 12 })
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(12)
              .fontColor(UI_WARN)
              .width('100%')
              .margin({ bottom: 8 })
          }

          Button('重置这台电脑的主机指纹')
            .fontSize(12)
            .constraintSize({ minHeight: 34 })
            .padding({ left: 16, right: 16 })
            .backgroundColor(UI_ACCENT_SOFT)
            .fontColor(UI_ACCENT)
            .borderRadius(17)
            .margin({ bottom: 8 })
            .onClick(() => {
              const c: common.Context | undefined = this.ctx();
              if (c !== undefined && clearHostKey(c, this.host)) {
                this.errorText = '已重置：下次连这台电脑会重新信任它的指纹';
                promptAction.showToast({ message: '已重置', duration: 2000 });
              }
            })

          Row({ space: 12 }) {
            Button('取消')
              .enabled(!this.saving)
              .fontSize(15)
              .constraintSize({ minHeight: 46, minWidth: 110 })
              .backgroundColor(UI_ACCENT_SOFT)
              .fontColor(UI_ACCENT)
              .borderRadius(23)
              .onClick(() => {
                this.cancel();
              })
            Button(this.saving ? '保存中…' : '保存')
              .fontSize(15)
              .constraintSize({ minHeight: 46, minWidth: 110 })
              .backgroundColor(UI_ACCENT)
              .borderRadius(23)
              .enabled(!this.saving)
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 4, bottom: 20 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop + 8 })
    .backgroundColor('#FFFBF5')
  }
}





