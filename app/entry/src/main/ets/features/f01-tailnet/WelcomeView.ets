import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, promptAction } from '@kit.ArkUI';
import { vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  KernelStatus, kernelStatus, peersAsync
} from './KernelBridge';
import { openSecureLoginBrowser } from './LoginLauncher';
import { clearExtensionStatus, isExtensionLive, pingExtension, readExtensionStatus } from './VpnStatusStore';
import { EVENT_VPN_COMMAND, EVENT_VPN_STATUS, publishEvent, subscribeEvent } from './VpnBus';
import { VpnCommand, writeCommand } from './VpnChannel';
import { readableVpnError } from '../../model/VpnErrors';
import { selfBundleName } from '../../model/BundleName';
import { VpnExtensionStatus } from '../../model/VpnTypes';

const DOMAIN: number = 0xD001;
const TAG: string = 'WELCOME';

// ── 配色与间距**照 HarmonyOS UX 规范**（`harmonyos-docs/docs/ux-design/color-*.md` / `interval-parameter-*.md`）──
const BRAND: string = '#0a59f7';          // brand 品牌色（浅色模式）
const FONT_PRIMARY: string = '#e5000000'; // font_primary 一级文本
const FONT_SECONDARY: string = '#99000000'; // font_secondary 二级文本
const FONT_TERTIARY: string = '#66000000'; // font_tertiary 三级文本
const FONT_ON_PRIMARY: string = '#ffffffff';
const BG_PRIMARY: string = '#ffffffff';
const BG_SECONDARY: string = '#f1f3f5';
const MARGIN_H: number = 16;   // 手机屏幕左右边距 16vp
const MARGIN_TOP: number = 36; // 顶部 36vp
const MARGIN_BOTTOM: number = 28; // 底部 28vp

/**
 * **功能块：第一页「登录网络」**（功能 11「加入 Tailscale 网络」的界面半边）。
 * 页面（`pages/Welcome.ets`）里只剩一行 `WelcomeView()`。
 *
 * 客户口径：功能 11 是基础 ⇒ 打开 App 第一眼就该是登录入口。
 * 设计依据（官方 UX 规范）：
 * - 8vp 网格 ＋ 手机边距 16vp（左右）/36vp（顶）/28vp（底）；
 * - 主按钮热区 ≥ 48vp、字号 ≥ 12vp（推荐）；
 * - 一级/二级/三级文本用规范色，正文对比度 ≥ 4.5:1；
 * - 一屏只做一件事：**登录**。技术细节不在这里出现。
 *
 * 登录成功后进主界面（`pages/Index`）；未登录时本页就是唯一入口。
 */
@Component
export struct WelcomeView {
  @State phaseText: string = '未登录';
  @State hintText: string = '登录你自己的 Tailscale 网络，才能看见电脑上的 dsh';
  @State busy: boolean = false;
  @State loggedIn: boolean = false;
  /** 真机排查用的一行：扩展状态文件里的 phase / backendState / 地址（看不到就写"没读到"） */
  @State diagText: string = '';
  /** 授权链接（拿到就显示出来；浏览器没自动弹也能手动打开） */
  @State authUrlText: string = '';
  private pollTimer: number = -1;
  aboutToDisappear(): void {
    this.stopPoll();
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 内核调用的统一保护：**异步 ＋ 超时**（同步会堵 UI、异步可能永不 settle） */
  private withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
    const timeout: Promise<T> = new Promise<T>((resolve: (v: T) => void) => {
      setTimeout(() => {
        resolve(fallback);
      }, ms);
    });
    return Promise.race([p, timeout]);
  }

  private enterMain(): void {
    router.replaceUrl({ url: 'pages/Index' }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, '进主界面失败 code=%{public}d', err.code ?? -1);
      // 审查 2026-10-22：路由失败必须回滚，否则 loggedIn 永远为真、界面卡在"已登录"不动
      this.loggedIn = false;
      this.phaseText = '进主界面失败，请再点一次「登录 Tailscale」';
    });
  }

  /**
   * 给扩展发一条命令（seq 用毫秒，单调即可）。用途：NEED LOGIN 卡住时让它重新取一次授权链接。
   */
  private sendExtensionCommand(filesDir: string, command: string): void {
    const cmd: VpnCommand = { seq: Date.now(), issuedAtMs: Date.now(), command: command, tunFd: -1 };
    const ok: boolean = writeCommand(filesDir, cmd);
    if (ok) {
      publishEvent(EVENT_VPN_COMMAND, `seq=${cmd.seq}`);
    }
    hilog.info(DOMAIN, TAG, '给扩展发命令 %{public}s（写入%s）', command, ok ? '成功' : '失败');
  }

  /** 扩展状态文件说 Running 就算入网（真机的内核在扩展进程里，本进程 NAPI 看不见它） */
  private joinedByExtension(): boolean {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const st: VpnExtensionStatus | undefined = readExtensionStatus(ctx.filesDir);
      if (st === undefined) {
        this.diagText = '没读到扩展状态';
        return false;
      }
      this.diagText = `${st.phase} / ${st.backendState}${st.address.length > 0 ? ' / ' + st.address : ''}`;
      hilog.info(DOMAIN, TAG, '状态回读：phase=%{public}s backend=%{public}s',
        st.phase, st.backendState);
      return isExtensionLive(st, Date.now());
    } catch (error) {
      return false;
    }
  }

  /** 只进一次主界面（页面重进 / 事件回调都可能触发） */
  private enterMainOnce(): void {
    if (this.loggedIn) {
      return;
    }
    this.loggedIn = true;
    this.phaseText = '已登录';
    this.enterMain();
  }

  /** 若已经入网（Running）⇒ 直接进主界面，不必再登一次 */
  aboutToAppear(): void {
    // 2026-10-20：**预热**——有缓存地址就先把 VPN 扩展拉起来（系统已信任，不再弹授权）。
    // 隧道建立本身要 ~3s（连控制平面），这段时间正好盖住用户在登录页的停留。
    this.prewarmVpn();
    this.checkJoined();
  }

  /** 后台预热：有 `<filesDir>/tailnet-address.txt` 才做（说明之前成功入过网） */
  private prewarmVpn(): void {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const marker: string = `${ctx.filesDir}/tailnet-address.txt`;
      if (!fileIo.accessSync(marker)) {
        return;
      }
      const want: Want = { deviceId: '', bundleName: selfBundleName(), abilityName: 'DshVpnExtensionAbility' };
      vpnExtension.startVpnExtensionAbility(want).catch((err: BusinessError) => {
        hilog.info(DOMAIN, TAG, '预热 VPN 扩展失败（忽略）code=%{public}d', err.code ?? -1);
      });
    } catch (error) {
      hilog.info(DOMAIN, TAG, '预热跳过（拿不到目录）');
    }
  }

  /**
   * 页面重新可见（由 `pages/Welcome` 的 onPageShow 通过 `resumeTick` 转发进来）——
   * 审查 2026-10-22：`onPageShow` 写在子组件里**根本不会被调用**，浏览器登录完回来不会重查。
   */
  @Prop @Watch('resumeTickChanged') resumeTick: number = 0;

  /** 真正干活的地方（页面重新可见 ⇒ 再查一次入网状态） */
  private resumeTickChanged(): void {
    if (this.loggedIn) {
      return;
    }
    this.checkJoined();
  }

  /**
   * 2026-10-20：不能只看状态文件——装包/重启后文件还写着 Running，扩展进程其实已经没了。
   * 先 ping 扩展，有回执才认状态文件；没回执就停在登录页，让用户把隧道拉起来。
   */
  private async checkJoined(): Promise<void> {
    if (this.loggedIn) {
      return;
    }
    const st: KernelStatus | undefined = kernelStatus();
    if (st !== undefined && st.backendState === 'Running') {
      this.enterMainOnce();
      return;
    }
    let filesDir: string = '';
    try {
      filesDir = (this.getUIContext().getHostContext() as common.Context).filesDir;
    } catch (error) {
      filesDir = '';
    }
    const alive: boolean = await pingExtension(filesDir);
    if (!alive) {
      this.diagText = '扩展进程没在跑（需要登录）';
      return;
    }
    if (this.joinedByExtension()) {
      this.enterMainOnce();
    }
  }

  /**
   * **真机入口**（客户 2026-10-18："把真 tailscale 入口接进去"）：
   * 启动系统 VPN 扩展 → 扩展建 tun、把 fd 交内核 → 内核 Running 写进状态文件 ⇒ 算入网。
   *
   * 为什么读状态文件而不是 `kernelStatus()`：真机上内核跑在**扩展进程**里，
   * 本进程的 NAPI 看不到它；扩展会把 `backendState/phase/地址/peers` 写进
   * `vpn-extension-status.json`（写完发事件）。这是我们唯一的真机回读通道。
   */
  private async startVpnAndWait(ctx: common.UIAbilityContext): Promise<boolean> {
    const want: Want = { deviceId: '', bundleName: selfBundleName(), abilityName: 'DshVpnExtensionAbility' };
    this.phaseText = '正在登录网络…';
    let startErrorCode: number = -1;
    // 预热可能已经把扩展拉起来了：活着就别清状态、别再 start（二次 start 会 reject，还会把状态文件删掉）
    const existing: VpnExtensionStatus | undefined = readExtensionStatus(ctx.filesDir);
    const hadStatus: boolean = existing !== undefined;
    const liveByHeartbeat: boolean = hadStatus && isExtensionLive(existing, Date.now());
    // 心跳只能证明"状态文件新"，不能证明扩展进程还在：必须 ping 到才算活着
    const alreadyLive: boolean = liveByHeartbeat && (await pingExtension(ctx.filesDir, 1200));
    // 扩展内存里可能还揣着上一次没登录完的旧授权链接（NeedsLogin 时它每秒把旧 URL 写回状态文件）
    const staleUrl: string = existing !== undefined && existing.authUrlReady ? existing.authUrl : '';
    if (!alreadyLive) {
      if (staleUrl.length > 0) {
        // 让扩展作废旧链接并重起后端（不清状态文件：活扩展会立刻把它写回来）
        hilog.info(DOMAIN, TAG, '复用扩展的旧授权链接：先让它作废');
        this.sendExtensionCommand(ctx.filesDir, 'refreshAuthURL');
      }
      // 2026-10-20：先把上一轮的状态文件删掉——否则这里会立刻读到旧的 `authUrl`，拿过期链接开浏览器 ⇒ 404
      clearExtensionStatus(ctx.filesDir);
      // 2026-10-20：**不等 startVpnExtensionAbility 的 Promise**——它可能迟迟不 settle，
      // 之前会把"进首页"硬拖 15 秒。直接发起，然后靠状态文件/事件判断。
      try {
        vpnExtension.startVpnExtensionAbility(want).catch((err: BusinessError) => {
          // 异步失败也必须走到界面：以前只记日志，按钮会一直锁着
          startErrorCode = err === undefined ? -1 : (err.code ?? -1);
          hilog.warn(DOMAIN, TAG, 'startVpnExtensionAbility 异步失败 code=%{public}d', startErrorCode);
        });
      } catch (error) {
        const e = error as BusinessError;
        hilog.warn(DOMAIN, TAG, 'startVpnExtensionAbility 同步失败 code=%{public}d', e.code ?? -1);
        this.phaseText = `VPN 起不来：${readableVpnError(e.code)}`;
        promptAction.showToast({ message: 'VPN 起不来', duration: 2500 });
        return false;
      }
    } else {
      hilog.info(DOMAIN, TAG, '扩展已在运行：复用，不重启');
    }
    const filesDir: string = ctx.filesDir;
    const ready: boolean = await new Promise<boolean>((resolve: (v: boolean) => void) => {
      let settled: boolean = false;
      let openedBrowser: boolean = false;
      let askedRefresh: boolean = false;
      let lastPhase: string = '';
      let lastBackend: string = '';
      let unsub: (() => void) | undefined = undefined;
      let ticker: number = -1;
      const startedAtMs: number = Date.now();
      const finish = (value: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (ticker >= 0) {
          clearInterval(ticker);
          ticker = -1;
        }
        if (unsub !== undefined) {
          unsub();
        }
        resolve(value);
      };
      // 扩展把「阶段 / 错误码 / 授权 URL」都写进状态文件 ⇒ 每个阶段推进都在这里被看见
      const check = (): void => {
        // 登录页按客户口径只留标题+按钮，状态文字没有渲染位 ⇒ 失败用短 toast 告知
        const deadWaitMs: number = hadStatus ? 35000 : 8000;
        if (startErrorCode !== -1 && Date.now() - startedAtMs > deadWaitMs) {
          // 有旧状态时扩展可能在跑（心跳 30s 一次）⇒ 等 35s；全新拉起没有心跳可等，8s 就报
          const stFirst: VpnExtensionStatus | undefined = readExtensionStatus(filesDir);
          if (stFirst === undefined) {
            this.phaseText = `VPN 起不来：${readableVpnError(startErrorCode)}`;
            promptAction.showToast({ message: 'VPN 起不来', duration: 2500 });
            finish(false);
            return;
          }
          // 扩展其实起来了（预热/二次 start）：reject 只作诊断，继续看状态文件
          startErrorCode = -1;
        }
        const st: VpnExtensionStatus | undefined = readExtensionStatus(filesDir);
        if (st === undefined) {
          this.diagText = '没读到扩展状态（VPN 扩展可能没起来）';
          return;
        }
        // 每次状态变化打一行：这是真机上排查"卡在哪一步"的唯一线索
        if (st.phase !== lastPhase || st.backendState !== lastBackend) {
          lastPhase = st.phase;
          lastBackend = st.backendState;
          this.diagText = `${st.phase} / ${st.backendState}${st.address.length > 0 ? ' / ' + st.address : ''}` +
            `${st.detail.length > 0 ? '｜' + st.detail : ''}`;
          hilog.info(DOMAIN, TAG, 'VPN 阶段：%{public}s / %{public}s（地址 %{public}s）',
            st.phase, st.backendState, st.address);
        }
        // 内核要登录、但迟迟拿不到授权链接 ⇒ 让扩展重新取一次（它自己可能卡在 pending）
        if (!openedBrowser && !st.authUrlReady && st.backendState.indexOf('NeedsLogin') >= 0 &&
          !askedRefresh && Date.now() - startedAtMs > 15000) {
          askedRefresh = true;
          this.sendExtensionCommand(filesDir, 'refreshAuthURL');
          this.phaseText = '正在重新获取登录链接…';
        }
        if (st.phase === 'failed') {
          // 内核 StartFailed 常带 errorCode=0（失败原因在 detail/kernelError），不能只看错误码
          const why: string = st.errorCode !== 0
            ? readableVpnError(st.errorCode)
            : (st.kernelError.length > 0 ? st.kernelError : st.detail);
          this.phaseText = `VPN 起不来：${why}`;
          promptAction.showToast({ message: 'VPN 起不来', duration: 2500 });
          finish(false);
          return;
        }
        // 入网判据与 isExtensionLive 保持一致：必须有地址才算真入网
        // 先判"已入网"再谈浏览器：复用活着的扩展时，旧状态里的 authUrl 可能还是上一轮的，不能拿去开浏览器
        if ((st.backendState === 'Running' || st.phase === 'running') && st.address.length > 0) {
          finish(true);
          return;
        }
        // 只开"这次登录"拿到的链接：扩展内存里上一次的旧 URL 不能再用（过期会 404）
        if (st.authUrlReady && st.authUrl.length > 0 && st.authUrl !== staleUrl) {
          this.authUrlText = st.authUrl;
          if (!openedBrowser) {
            openedBrowser = true;
            this.phaseText = '请在浏览器里登录 Tailscale';
            hilog.info(DOMAIN, TAG, '打开授权链接（长度 %{public}d）', st.authUrl.length);
            openSecureLoginBrowser(ctx, st.authUrl).then((how: string) => {
              // 这个函数失败时 resolve 'failed'（不 reject），所以必须判返回值
              if (how === 'failed') {
                this.phaseText = '打不开浏览器，请重试';
                promptAction.showToast({ message: '打不开浏览器', duration: 2500 });
                finish(false);
              }
            }).catch(() => {
              // 审查 2026-10-22：以前只改文案，busy 一直锁着、要等满 180 秒才能重试
              this.phaseText = '打不开浏览器，请重试';
              promptAction.showToast({ message: '打不开浏览器', duration: 2500 });
              finish(false);
            });
          }
        } else if (st.phase === 'kernel-starting' || st.phase === 'creating-tun') {
          this.phaseText = '正在连 Tailscale…';
        }
        // 登录成功但设备还没被批准：说清楚，别让人干等
        if (st.backendState === 'NeedsMachineAuth') {
          this.phaseText = '已登录，等 Tailscale 管理员批准这台设备';
        }
      };
      const timer: number = setTimeout(() => {
        this.phaseText = '还没登录完（等太久），点「登录 Tailscale」再试';
        promptAction.showToast({ message: '登录超时', duration: 2500 });
        finish(false);
      }, 180000);
      unsub = subscribeEvent(EVENT_VPN_STATUS, () => {
        check();
      });
      // 兜底：App 被浏览器切到后台时可能收不到那条事件（扩展入网后就不再写状态）⇒
      // 等登录这几分钟里每 5 秒补看一次状态文件。到 Running 或超时就停，不常驻。
      ticker = setInterval(() => {
        check();
      }, 1000);
      check();
    });
    return ready;
  }

  /** 点「登录 Tailscale」：起后端 → 拿授权链接 → 拉起系统浏览器 → 轮询到 Running 就进主界面 */
  private async login(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.phaseText = '正在准备…';
    try {
      let ctx: common.UIAbilityContext | undefined = undefined;
      try {
        ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      } catch (error) {
        this.phaseText = '拿不到运行环境，登录不可用';
        return;
      }
      const abilityContext: common.UIAbilityContext = ctx;

      // 真机主路：系统 VPN 扩展（建 tun + 系统路由）。
      // 客户 2026-10-20：**回到"等在登录页"**——提前进首页只是把等待挪个地方，更乱。
      const vpnReady: boolean = await this.startVpnAndWait(abilityContext);
      if (vpnReady) {
        this.enterMainOnce();
      }
      return;
    } catch (error) {
      const e = error as BusinessError;
      this.phaseText = `登录出错：${e.message}`;
      hilog.error(DOMAIN, TAG, '登录异常：%{public}s', `${e.message}`);
    } finally {
      this.busy = false;
    }
  }


  build() {
    // 暖色 Expressive 风格的登录页（2026-10-25 第二轮）：
    // 浅暖底 + 柔和光 + 圆形头像 + 胶囊主按钮；不显示「未登录」这类状态废话。
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#FFFBF5', 0.0], ['#F7E9D8', 0.55], ['#F1DEC9', 1.0]]
        })
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '30%'],
          radius: 520,
          colors: [['#66FFFFFF', 0.0], ['#00FFFFFF', 1.0]]
        })

      Column({ space: 52 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(220).height(220).borderRadius(110)
            .backgroundColor('#FFFFFF')
            .shadow({ radius: 40, color: '#33C08A5E', offsetY: 12 })
          Image($r('app.media.whale_avatar'))
            .width(200)
            .height(200)
            .borderRadius(100)
            .objectFit(ImageFit.Cover)
        }
        .width(220)
        .height(220)

        Column({ space: 14 }) {
          Button(this.busy ? '正在登录…' : '登录 Tailscale')
            .id('welcome-login')
            .fontSize(17)
            .fontColor('#FFFFFF')
            .backgroundColor(this.busy ? '#C98A6B' : '#E0622A')
            .width(220)
            .height(50)
            .borderRadius(25)
            .enabled(!this.busy)
            .onClick(() => {
              this.login();
            })
          if (this.phaseText.length > 0 && this.phaseText !== '未登录' && this.phaseText !== '已登录') {
            Text(this.phaseText)
              .fontSize(12)
              .fontColor('#8C6F5A')
              .maxLines(2)
              .textAlign(TextAlign.Center)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding({ left: 32, right: 32 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFBF5')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}






