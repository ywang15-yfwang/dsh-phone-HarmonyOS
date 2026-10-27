import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardAvoidMode, promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { DshApiClient, pluginTarget } from '../../services/DshApiClient';
import { pairingVault } from '../f03-connect/PairingVault';
import {
  Ac16SendResult, SessionEnsure, SessionListResult, SessionRow, ensureSession, listSessions, sendTextWithFile,
  sendPlainText, sendImage, sendRich
} from './DshSessionPage';
import { FollowFile, FollowRecord, FollowSnapshot, SessionFollow } from './FollowStream';
import {
  WorkspaceState, emptyWorkspaceState, fetchWorkspaceState, visibleRows
} from './WorkspaceSessions';
import { ChatMessage, appendStreamText, dropLiveStream, localMessage, mergeRecord, messagesFromRecords } from './ChatModel';import { MessageSource } from './MessageSource';
import { formatClock } from '../../model/VpnTypes';
import { InlineImageResult, isAttachmentId, loadAttachmentImage, loadRemoteImage } from '../f10-image/InlineImageLoader';
import { ImagePayload } from '../f06-typing/DshSessionProtocol';
import { picker } from '@kit.CoreFileKit';
import { UploadClient, UploadOutcome } from '../f09-file-transfer/UploadClient';
import { OpenFileResult, openAttachment, openByNameViaPlugin, openPickedUri, openRemotePath, saveToPhone } from '../f09-file-transfer/FileOpener';
import { parseReceiptId } from '../f09-file-transfer/ReceiptId';
import { VideoThumb } from '../f09-file-transfer/VideoThumb';
import { IMAGE_LIMIT_BYTES } from '../f09-file-transfer/TransferLimits';
import { HttpTransport } from '../../channel/HttpTransport';
import { pairTarget } from '../../services/PairTarget';
import { PermOption, fetchPermission, setPermission } from '../f14-permission/PermissionClient';
import { ApprovalBridge, ApprovalRequest } from '../f15-approval/ApprovalBridge';
import { setPromptMode } from '../f06-typing/DshSessionProtocol';
import { isImageName as isImageFile, isVideoName as isVideoFile, mimeOf } from '../../model/MediaTypes';
import { cleanupTemp } from '../../services/TempFiles';

const DOMAIN: number = 0xD001;
const TAG: string = 'F8CHAT';

/** 待发送的一条附件（选了就挂在输入栏，发送时才读/上传） */
interface PendingAttachment {
  name: string;
  uri: string;
}

/** 首帧快照的等待上限：超了就如实说"电脑没把对话发过来"，**不改成轮询** */
const SNAPSHOT_WAIT_MS: number = 8000;

/** 一条内嵌图片的加载态（界面用它决定显示图 / 显示"加载中" / 显示失败原因） */
interface InlineState {
  path: string;
  /** 'loading' | 'ok' | 'fail' */
  state: string;
  pixelMap: image.PixelMap | undefined;
  detail: string;
}

/**
 * **会话页（功能 5/8）—— 手机就是 dsh 的一块屏**（客户 2026-10-16 口径）。
 *
 * 两条路，都是"真的连在电脑上那场会话"：
 *  - **显示**：`session/follow` **长连订阅**（`FollowStream.ets`）—— 首帧把已有对话整段给出，之后电脑侧
 *    每有一条新事件就推一帧过来（助手还是**逐字**流），App 收到即上屏。**没有轮询、没有"刷新消息"按钮。**
 *  - **输入**：输入框的文字经 `session/prompt` **发给那场会话**（就是往电脑上那场对话里发消息）；
 *    点发送本机**立刻上屏**自己的这句（不等服务器），电脑侧确认后以电脑侧那条为准。
 *
 * 连不上就说人话（"dsh 没启动"）；断线由实时连接自己重试，失败只显示状态，不给按钮。
 * 上传文件 / 看图**本轮不接**（客户："上传文件什么的先不管，先把会话搞好"）。
 */
@Component
export struct ConversationView {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @State messages: ChatMessage[] = [];
  /** 聊天列表的懒加载数据源（`List + LazyForEach` 用；见 `MessageSource.ets`） */
  private msgSource: MessageSource = new MessageSource();
  /** 改消息的唯一入口：`@State` 与懒加载数据源一起更新（别直接赋值 `this.messages`） */
  private setMessages(next: ChatMessage[]): void {
    this.messages = next;
    this.msgSource.setAll(next);
  }
  @State statusText: string = '正在连接电脑…';
  /** **连接**出的问题（红字；按客户要求不提供手动重连按钮） */
  @State errorText: string = '';
  /** 发消息之类的提示（红字，**不给**重连按钮：跟连接无关） */
  @State noticeText: string = '';
  /** 文件类的**灰字**提示（不是错误，不刷红） */
  @State hintText: string = '';
  private hintTimer: number = -1;
  @State sessionTitle: string = '会话';
  @State currentId: string = '';
  /** 当前会话的权限预设（f14）与审批通道（f15） */
  @State permCurrent: string = '';
  @State permOptions: PermOption[] = [];
  @StorageLink('appForegroundTick') @Watch('onForegroundTick') appForegroundTick: number = 0;
  private approvalBridge: ApprovalBridge | undefined = undefined;
  private approvalQueue: ApprovalRequest[] = [];
  private approvalShowing: boolean = false;
  private currentApprovalId: string = '';
  /** 审批改成底部 sheet（2026-10-25）：这三个状态驱动界面，不再用系统对话框 */
  @State approvalVisible: boolean = false;
  @State approvalTitle: string = '';
  @State approvalTool: string = '';
  @State approvalReason: string = '';
  private approvalCurrent: ApprovalRequest | undefined = undefined;
  @State draft: string = '';
  /** 待发送的附件（可多张；客户 2026-10-20：添加多张要并列显示） */
  @State attachedItems: PendingAttachment[] = [];
  /** 上传中的提示（'' = 没在上传）；成功后就空着，等附件条显示 */
  @State attachNote: string = '';
  /** 附件区短提示（"图片太大"这类）的定时器：几秒后自动清掉（客户 2026-10-21） */
  private noteTimer: number = -1;
  @State uploading: boolean = false;
  /** 订阅状态：'实时' = 长连正连着（这就是唯一模式） */
  @State liveMode: string = '';
  @State showSide: boolean = false;
  @State rows: SessionRow[] = [];
  /** 摘要全量（`session/list` 原样；列表显示的是按官方分组收窄后的 `rows`） */
  private allRows: SessionRow[] = [];
  @State sideNote: string = '';
  /** 当前会话声明的工作区（电脑上的 cwd）—— 内嵌图片只允许从这个根取 */
  @State sessionCwd: string = '';
  /** 消息里那些图片的加载态（按远端路径做键） */
  @State inlineStates: InlineState[] = [];
  /** 正在全屏查看的那张图（'' = 没在看）；点气泡里的图打开、点任意位置关闭 */
  @State viewerPath: string = '';
  /** 全屏那张的高清版（720 的气泡图放到全屏会糊 ⇒ 打开时按 2160 重新解一次） */
  @State viewerMap: image.PixelMap | undefined = undefined;
  /** 这轮在不在干活（turn/start→true、turn/end→false）⇒ 顶上显示「正在思考…／空闲」 */
  @State busy: boolean = false;
  /** 图片加载是否在跑（避免并发重复取同一张） */
  private loadingImages: boolean = false;
  /** 加载期间又来了带图消息：本轮结束后再补扫一遍 */
  private imagesPending: boolean = false;
  /** 全屏看图的代次：关闭/重开/切会话 +1，迟到的解码结果据此丢弃 */
  private viewerGeneration: number = 0;
  /** 会话代次：切会话 +1，旧的图片加载循环据此自行退出（审查 2026-10-22） */
  private sessionGeneration: number = 0;
  /** 页面已销毁（异步回调据此不再 setState / 不再起长连） */
  private disposed: boolean = false;
  /** 上一次 loadRows 的 session/list 是否成功（boot 据此决定要不要新建会话） */
  private loadRowsOk: boolean = true;
  private imageGeneration: number = 0;
  @State sending: boolean = false;
  /** 正在进行的保存/打开（同一附件连点两次时不并发下载同一个文件） */
  private fileOps: string[] = [];
  /** 发送代次：每次发送/切会话 +1，旧的 send 收尾不再改界面状态 */
  private sendGen: number = 0;

  private follow: SessionFollow | undefined = undefined;
  private snapshotTimer: number = -1;
  private listScroller: Scroller = new Scroller();
  /** 用户刚在本机挑过的文件：文件名 → 选择器给的 uri（点卡片时优先直接打开本机这份） */
  private pickedFiles: Map<string, string> = new Map<string, string>();
  /**
   * **附件 id → 本机原文件 uri**（客户 2026-10-21 视频问题的真因所在）。
   *
   * 电脑侧会把上传的文件**改名**（`video_<时间戳>.mp4`），所以回来那条消息里的 `name`
   * 跟手机上的文件名对不上 ⇒ `pickedFiles` 查不到 ⇒ 掉进附件接口（那个**只服务图片**）
   * ⇒ 点视频什么都不发生。用 `attachmentId` 记一份就绕开改名这件事。
   */
  private sentFiles: Map<string, string> = new Map<string, string>();
  /**
   * **字节数 → 本机原文件 uri**：`receiptId` 是电脑侧铸的不透明回执，跟消息里的
   * `attachmentId`（`sha256:…`）不是同一个值，所以还得有一条按**大小**兜底的匹配
   * （同一场会话里同字节数的两个不同文件极少见，够用）。
   */
  private sentSizes: Map<number, string> = new Map<number, string>();

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'F8 chat open paired=%{public}s', `${pairingVault.has()}`);
    // **压缩模式**：键盘弹起时压缩页面（顶栏留在原位），而不是把整页上抬（会把顶栏顶出屏幕）
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.boot();
  }


  aboutToDisappear(): void {
    this.disposed = true;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    this.stopFollow();
    this.closeViewer();
    // 内嵌图片的 PixelMap 是 native 内存，页面销毁必须逐张 release，否则反复进出会累积
    for (let i = 0; i < this.inlineStates.length; i++) {
      const pm: image.PixelMap | undefined = this.inlineStates[i].pixelMap;
      if (pm !== undefined) {
        try {
          pm.release();
        } catch (releaseError) {
          // 已经释放过就忽略
        }
      }
    }
    this.inlineStates = [];
    // 离开会话页：审批通道随页面关闭（插件据此判断手机不在线）
    this.approvalBridge?.close();
    this.approvalBridge = undefined;
    this.approvalQueue = [];
    this.approvalShowing = false;
    // 离开会话页：打开过的文件这份中转已经没人读了，清掉
    try {
      const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx !== undefined) {
        cleanupTemp(hostCtx);
      }
    } catch (ctxError) {
      // 拿不到上下文就留给下次启动清理
    }
    if (this.snapshotTimer >= 0) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = -1;
    }
  }

  /** 与 dsh 说话的客户端：目标＝插件地址（插件端口 + `/pair/dsh`），Host 恒回环（围栏判据） */
  private client(): DshApiClient {
    const c: DshApiClient = new DshApiClient(pluginTarget(pairingVault.hostOr('')));
    c.setCookie(pairingVault.get());
    return c;
  }

  private shortId(id: string): string {
    return id.length > 12 ? id.substring(id.length - 12) : id;
  }

  /** 进页：挑一场会话（最近的非空会话，没有就新建）→ 订阅它 */
  private async boot(): Promise<void> {
    this.disposed = false;
    if (!pairingVault.has()) {
      this.statusText = '还没连接电脑';
      this.errorText = '先回上一页点「连接」';
      return;
    }
    this.statusText = '正在读取会话…';
    try {
      let listed: SessionListResult = await listSessions(this.client());
      if (this.disposed) {
        return;
      }
      if (!listed.ok) {
        // 列表读失败不能当成"没有会话"去新建：按连接错误处理
        this.statusText = 'dsh 已断开';
        hilog.warn(DOMAIN, TAG, 'F8 session/list 失败：%{public}s', listed.detail);
        return;
      }
      // 先定"当前项目"（最近那场非空会话的 cwd），再按官方分组把列表收窄到这一个项目
      let picked: string = '';
      let title: string = '';
      let cwd: string = '';
      for (let i = 0; i < listed.rows.length; i++) {
        if (!listed.rows[i].blank && listed.rows[i].cwd.length > 0) {
          cwd = listed.rows[i].cwd;
          break;
        }
      }
      this.sessionCwd = cwd;
      const rows: SessionRow[] = await this.loadRows('');
      if (this.disposed) {
        return;
      }
      if (!this.loadRowsOk) {
        this.statusText = 'dsh 已断开';
        return;
      }
      this.rows = rows;
      for (let i = 0; i < rows.length; i++) {
        if (!rows[i].blank) {
          picked = rows[i].sessionId;
          title = rows[i].title;
          cwd = rows[i].cwd;
          break;
        }
      }
      if (picked.length === 0 && rows.length > 0) {
        picked = rows[0].sessionId;
        title = rows[0].title;
        cwd = rows[0].cwd;
      }
      this.sessionCwd = cwd;
      if (picked.length === 0) {
        const ensured: SessionEnsure = await ensureSession(this.client(), this.sessionCwd);
        if (this.disposed) {
          return;
        }
        if (!ensured.ok) {
          // 客户 2026-10-18：别写一长串原因，就一句「dsh 已断开」
          this.statusText = 'dsh 已断开';
          return;
        }
        picked = ensured.sessionId;
      }
      this.currentId = picked;
      this.sessionTitle = title.length > 0 ? title : `会话 …${this.shortId(picked)}`;
      this.subscribe(picked);
      this.ensureApprovalBridge();
      this.loadPermission();
    } catch (error) {
      this.statusText = 'dsh 已断开';
      this.busy = false;
      hilog.error(DOMAIN, TAG, 'F8 boot failed');
    }
  }

  /** 订阅这场会话（先停旧的）：**这是唯一的显示通道** */
  private subscribe(sessionId: string): void {
    this.stopFollow();
    this.setMessages([]);
    this.errorText = '';
    this.liveMode = '';
    this.statusText = '正在连接电脑…';
    if (this.snapshotTimer >= 0) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = -1;
    }

    const follow: SessionFollow = new SessionFollow();
    this.follow = follow;
    // 流走**dsh 官方载体**（`/api/remote.mux` + `session/follow`）：手机自建握手，经插件中转（dsh 只听回环）
    follow.start(pairingVault.hostOr(''), sessionId, pairingVault.get(), {
      onSnapshot: (snap: FollowSnapshot) => {
        // 审查 2026-10-22：快照**合并**而不是覆盖 —— 否则刚上屏、还没被电脑确认的本机回显会被抹掉
        this.setMessages(keepPendingEcho(messagesFromRecords(snap.records), this.messages));
        if (snap.title.length > 0) {
          this.sessionTitle = snap.title;
        }
        this.liveMode = '实时';
        this.statusText = '已连接';
        this.errorText = '';
        // 首帧到了就撤掉看门狗，否则 8 秒后它会在"断线重连中"误报「没连上」
        if (this.snapshotTimer >= 0) {
          clearTimeout(this.snapshotTimer);
          this.snapshotTimer = -1;
        }
        // 重连/刷新是重试取图的机会：清掉失败的旧状态，让 ensureImages 重新取
        this.retryFailedImages();
        this.ensureImages();
        this.scrollToBottom();
      },
      onRecord: (rec: FollowRecord) => {
        this.setMessages(mergeRecord(this.messages, rec));
        this.ensureImages();
        this.scrollToBottom();
      },
      onStreamText: (text: string) => {
        this.setMessages(appendStreamText(this.messages, text, Date.now()));
        this.scrollToBottom();
      },
      onStreamReset: () => {
        this.setMessages(dropLiveStream(this.messages));
      },
      onError: (human: string, detail: string) => {
        hilog.warn(DOMAIN, TAG, 'F8 follow error: %{public}s', detail);
        this.liveMode = '';
        // 客户 2026-10-18：断开是**状态**，写右上角；红字与「重新连接」按钮都不要了
        this.statusText = 'dsh 已断开';
        // 断线后不能还挂着“正在思考…”：否则按钮变成「插入」、下一条按 steer 发出去
        this.busy = false;
      },
      onTitle: (fresh: string) => {
        this.sessionTitle = fresh;
        // 换一个新数组：直接改 rows[i].title 不会触发 @State 刷新（SessionRow 是普通 interface）
        const nextRows: SessionRow[] = [];
        for (let i = 0; i < this.rows.length; i++) {
          const one: SessionRow = this.rows[i];
          if (one.sessionId === this.currentId) {
            nextRows.push({
              sessionId: one.sessionId, updatedAtMs: one.updatedAtMs, running: one.running,
              blank: one.blank, title: fresh, asOfSeq: one.asOfSeq, cwd: one.cwd,
              origin: one.origin, parentId: one.parentId
            });
          } else {
            nextRows.push(one);
          }
        }
        this.rows = nextRows;
      },
      onTurnState: (busyNow: boolean) => {
        this.busy = busyNow;
      },
      onClosed: (detail: string) => {
        hilog.info(DOMAIN, TAG, 'F8 follow closed: %{public}s', detail);
        this.liveMode = '';
        this.statusText = 'dsh 已断开';
        // 流断了就别再挂着“正在思考…”
        this.busy = false;
      }
    });

    // 看门狗：到点还没首帧 ⇒ 如实说；**不偷偷换成轮询**
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = -1;
      if (this.liveMode !== '实时') {
        this.statusText = '没连上';
        this.errorText = '电脑没把这场对话发过来（确认电脑上 dsh 起着、这页刚才点过「连接」）';
      }
    }, SNAPSHOT_WAIT_MS);
  }

  private stopFollow(): void {
    const f: SessionFollow | undefined = this.follow;
    this.follow = undefined;
    if (f !== undefined) {
      f.stop();
    }
  }

  /**
   * 把消息里出现过的**电脑上的图片**取回来显示（客户 2026-10-17：图片要能看到）。
   * - 每张只取一次（按远端路径做键）；
   * - 串行取，避免一次打一堆请求；
   * - 读取根只放行**本场会话的工作区**（`sessionCwd`），别处一律不取。
   */
  /** 把加载失败的图从状态里清掉（重连/刷新后再试一次） */
  private retryFailedImages(): void {
    const kept: InlineState[] = [];
    let changed: boolean = false;
    for (let i = 0; i < this.inlineStates.length; i++) {
      if (this.inlineStates[i].state === 'fail') {
        changed = true;
        continue;
      }
      kept.push(this.inlineStates[i]);
    }
    if (changed) {
      this.inlineStates = kept;
    }
  }

  private ensureImages(): void {
    if (this.loadingImages) {
      // 这一轮结束时会再扫一遍（否则加载期间新来的图会一直停在"加载中"）
      this.imagesPending = true;
      return;
    }
    const missing: string[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      const paths: string[] = this.messages[i].images;
      for (let k = 0; k < paths.length; k++) {
        const p: string = paths[k];
        if (!this.hasImageState(p) && !missing.includes(p)) {
          missing.push(p);
        }
      }
    }
    if (missing.length === 0) {
      return;
    }
    this.loadingImages = true;
    const gen: number = this.sessionGeneration;
    this.imageGeneration = gen;
    this.loadImagesOneByOne(missing, 0, gen);
  }

  private hasImageState(path: string): boolean {
    for (let i = 0; i < this.inlineStates.length; i++) {
      if (this.inlineStates[i].path === path) {
        return true;
      }
    }
    return false;
  }

  private async loadImagesOneByOne(paths: string[], index: number, gen: number): Promise<void> {
    // 审查 2026-10-22：代次用**局部变量**（共享的 imageGeneration 会被新会话的 ensureImages 改掉）
    if (index >= paths.length || this.sessionGeneration !== gen || this.disposed) {
      if (this.sessionGeneration === gen && !this.disposed) {
        this.loadingImages = false;
        if (this.imagesPending) {
          this.imagesPending = false;
          this.ensureImages();
        }
      }
      return;
    }
    const path: string = paths[index];
    this.inlineStates = this.inlineStates.concat([
      { path: path, state: 'loading', pixelMap: undefined, detail: '' }
    ]);
    let filesDir: string = '';
    try {
      filesDir = (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
    } catch (ctxError) {
      filesDir = '';
    }
    const result: InlineImageResult = isAttachmentId(path)
      ? await loadAttachmentImage(this.client(), this.currentId, path, 720, 720)
      : await loadRemoteImage(path, this.sessionCwd, filesDir, 720, 720, this.getUIContext().getHostContext());
    // 回来时已经切了会话：这张图没人要了，必须自己释放（否则每切一次会话漏一份解码缓冲）
    if (this.sessionGeneration !== gen || this.disposed) {
      if (result.pixelMap !== undefined) {
        try {
          result.pixelMap.release();
        } catch (releaseError) {
          // 忽略
        }
      }
      return;
    }
    const next: InlineState[] = [];
    for (let i = 0; i < this.inlineStates.length; i++) {
      const one: InlineState = this.inlineStates[i];
      if (one.path === path) {
        next.push({
          path: path, state: result.ok ? 'ok' : 'fail', pixelMap: result.pixelMap, detail: result.detail
        });
      } else {
        next.push(one);
      }
    }
    this.inlineStates = next;
    this.scrollToBottom();
    this.loadImagesOneByOne(paths, index + 1, gen);
  }

  private imageStateOf(path: string): InlineState | undefined {
    for (let i = 0; i < this.inlineStates.length; i++) {
      if (this.inlineStates[i].path === path) {
        return this.inlineStates[i];
      }
    }
    return undefined;
  }

  /** 拿这张图的像素图（没加载好就是 undefined） */
  private imageMapOf(path: string): image.PixelMap | undefined {
    const st: InlineState | undefined = this.imageStateOf(path);
    return st === undefined ? undefined : st.pixelMap;
  }

  /** 这张图当前的一句说明（加载中 / 取不到的原因） */
  private imageNoteOf(path: string): string {
    const st: InlineState | undefined = this.imageStateOf(path);
    if (st === undefined || st.state === 'loading') {
      return '图片加载中…';
    }
    return `图片没取到：${st.detail}`;
  }

  /** 气泡里的一张图（客户 2026-10-17：会话里说的图片要能看到；2026-10-17 晚：要能点开看大图） */
  @Builder
  inlineImage(path: string) {
    if (this.imageMapOf(path) !== undefined) {
      Image(this.imageMapOf(path) as image.PixelMap)
        .width(240)
        .height(180)
        .objectFit(ImageFit.Contain)
        .borderRadius(8)
        .onClick(() => {
          // 点开看大图（全屏遮罩，点任意位置关闭）
          this.openViewer(path);
        })
    } else {
      Text(this.imageNoteOf(path))
        .fontSize(11)
        .fontColor('#8a8f98')
        .width(240)
        .height(40)
        .textAlign(TextAlign.Center)
    }
  }

  /**
   * 气泡里的**文件附件卡片**（客户 2026-10-18："我发的文件看不到"）：
   * 图标 + 文件名 + 大小；手机发出去的文件在电脑侧存成 `{type:'file', attachment:{name,bytes}}`。
   */
  @Builder
  fileChip(f: FollowFile) {
    Row({ space: 8 }) {
      // 客户 2026-10-21：**发完之后**气泡里也要有画面预览（不能只有添加时有）；
      // 而且**视频不显示文件名**（图片就是这样：只有画面）。
      if (isVideoFile(f.name) && this.localUriFor(f).length > 0) {
        VideoThumb({ uri: this.localUriFor(f), side: 96 })
      } else {
        SymbolGlyph($r('sys.symbol.doc_text')).fontSize(20).fontColor(['#E0622A'])
      }
      if (!(isVideoFile(f.name) && this.localUriFor(f).length > 0)) {
        Column({ space: 2 }) {
          Text(this.nameOfPath(f.name).length > 0 ? this.nameOfPath(f.name) : '文件')
            .fontSize(13).fontColor('#2A1C14').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(f.bytes >= 0 ? this.sizeText(f.bytes) : (f.attachmentId.length > 0 ? '已发送' : '电脑上的文件'))
            .fontSize(10).fontColor('#8a8f98')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      } else {
        Blank().layoutWeight(1)
      }
      // 「保存」：**只给电脑发来的**（客户 2026-10-21：自己发的还保存什么）。
      // 判据：这条附件对得上本机原文件 ⇒ 就是我自己发出去的 ⇒ 不给保存。
      if (!this.isOwnUpload(f)) {
        Button('保存')
          .fontSize(10)
          .constraintSize({ minHeight: 22 })
          .backgroundColor('#FBE6DA')
          .fontColor('#8C6F5A')
          .onClick(() => {
            this.saveFile(f);
          })
      }
    }
    // 客户 2026-10-21：**格子要跟着内容走** —— 视频只有一张图，别再留 220 宽的空白。
    .width(this.chipWidth(f))
    .padding(8)
    .backgroundColor('#ffffff')
    .border({ width: 1, color: '#d9dee6' })
    .borderRadius(8)
    .onClick(() => {
      this.openFile(f);
    })
  }

  /** 正文里提到的**电脑文档**：显示成一张卡片，点开就取到手机并交给系统打开 */
  @Builder
  docChip(path: string) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.doc_text')).fontSize(20).fontColor(['#5b6470'])
      Column({ space: 2 }) {
        Text(this.nameOfPath(path))
          .fontSize(13).fontColor('#2A1C14').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('电脑上的文件')
          .fontSize(10).fontColor('#8a8f98')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button('保存')
        .fontSize(10)
        .constraintSize({ minHeight: 22 })
        .backgroundColor('#FBE6DA')
        .fontColor('#8C6F5A')
        .onClick(() => {
          this.saveFile({ attachmentId: '', name: path, bytes: -1 });
        })
    }
    .width(220)
    .padding(8)
    .backgroundColor('#ffffff')
    .border({ width: 1, color: '#d9dee6' })
    .borderRadius(8)
    .onClick(() => {
      this.openFile({ attachmentId: '', name: path, bytes: -1 });
    })
  }
  /** 字节数 → 人话大小 */
  private sizeText(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  /**
   * 卡片上的「保存」：把文件**存到手机的用户存储**（客户 2026-10-18）。
   * 流程：文件夹选择器选目录 → App 自动避重命名（`名字 (1)`）→ 落盘。
   * 保存过程中**不显示任何"正在保存…"字样**（客户 2026-10-18 要求），成功也不刷提示；
   * 只有真失败才用灰字说一句。
   */
  private async saveFile(f: FollowFile): Promise<void> {
    const key: string = `s:${f.attachmentId.length > 0 ? f.attachmentId : f.name}`;
    if (this.fileOps.indexOf(key) >= 0) {
      return;
    }
    this.fileOps.push(key);
    try {
      const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      let filesDir: string = '';
      try {
        filesDir = hostCtx.filesDir;
      } catch (ctxError) {
        filesDir = '';
      }
      let result: OpenFileResult;
      try {
        const localUri: string | undefined = this.pickedFiles.get(f.name);
        result = await saveToPhone(this.client(), this.currentId, f.attachmentId, f.name,
          this.nameOfPath(f.name), filesDir, hostCtx, localUri === undefined ? '' : localUri);
      } catch (error) {
        const e = error as BusinessError;
        hilog.warn(DOMAIN, TAG, 'F8 保存失败 %{public}s', e.message);
        this.hint('');
        return;
      }
      this.hint(result.ok ? '' : result.message);
    } finally {
      const at: number = this.fileOps.indexOf(key);
      if (at >= 0) {
        this.fileOps.splice(at, 1);
      }
    }
  }

  /**
   * 这条附件在**本机**的那份 uri（'' = 找不到）：
   *  ① 用户刚挑过的同名文件；② 按**附件 id**（电脑侧会改名）；③ 按**字节数**兜底。
   */
  /** 这条附件是不是**我自己（手机）发出去的** —— 是的话手机侧不给「保存」 */
  private isOwnUpload(f: FollowFile): boolean {
    if (f.attachmentId.length > 0 && this.sentFiles.has(f.attachmentId)) {
      return true;
    }
    if (f.bytes > 0 && this.sentSizes.has(f.bytes)) {
      return true;
    }
    return this.pickedFiles.has(f.name);
  }
  /** 视频卡片只有一张图：宽度按图算（96+左右内边距）；其它文件仍按原宽度 */
  private chipWidth(f: FollowFile): number {
    if (isVideoFile(f.name) && this.localUriFor(f).length > 0) {
      return this.isOwnUpload(f) ? 112 : 112 + 56; // 收到的还要放一个「保存」
    }
    return 220;
  }

  private localUriFor(f: FollowFile): string {
    const byName: string | undefined = this.pickedFiles.get(f.name);
    if (byName !== undefined && byName.length > 0) {
      return byName;
    }
    if (f.attachmentId.length > 0) {
      const byId: string | undefined = this.sentFiles.get(f.attachmentId);
      if (byId !== undefined && byId.length > 0) {
        return byId;
      }
    }
    if (f.bytes > 0) {
      const bySize: string | undefined = this.sentSizes.get(f.bytes);
      if (bySize !== undefined && bySize.length > 0) {
        if (f.attachmentId.length > 0) {
          this.sentFiles.set(f.attachmentId, bySize);
        }
        return bySize;
      }
    }
    return '';
  }

  /**
   * 点文件卡片 → 交给系统打开（客户 2026-10-18 口径）：
   *  - **自己发过的**：手机上本来就有那份，直接用选择器给的 uri 打开，**不复制副本**（不留垃圾）；
   *  - **对话里提到的电脑文档**：走 `/api/file?path=` 取到手机再打开；
   *  - **别人发来的附件**：dsh 的 `session/attachment` 只服务图片，非图片取不到副本 —— **不弹红字**，只记日志。
   * 打开失败也不刷红：用灰字（`hintText`），红字只留给真正的连接错误。
   */
  private hint(text: string): void {
    this.hintText = text;
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
    if (text.length > 0) {
      this.hintTimer = setTimeout(() => {
        this.hint('');
        this.hintTimer = -1;
      }, 4000);
    }
  }

  private async openFile(f: FollowFile): Promise<void> {
    const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    let filesDir: string = '';
    try {
      filesDir = hostCtx.filesDir;
    } catch (ctxError) {
      filesDir = '';
    }
    // 本机那份（同名 / 附件 id / 字节数三种对上方式，统一在 `localUriFor` 里）
    const localUri: string = this.localUriFor(f);
    if (localUri.length > 0) {
      const opened: OpenFileResult = await openPickedUri(localUri, f.name, hostCtx);
      this.hint(opened.ok ? '' : opened.message);
      return;
    }
    this.hint(`正在打开 ${f.name}…`);
    let result: OpenFileResult;
    try {
      // 电脑发来的文件：**经插件按名取**（dsh 的 `session/attachment` 只服务图片）；
      // 取不到再退回老路（图片 / 电脑绝对路径）。
      result = await openByNameViaPlugin(f.name, filesDir, hostCtx);
      if (!result.ok && result.terminal !== true) {
        result = f.attachmentId.length > 0
          ? await openAttachment(this.client(), this.currentId, f.attachmentId, f.name, filesDir, hostCtx)
          : await openRemotePath(f.name, f.name, filesDir, hostCtx);
      }
    } catch (error) {
      const e = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'F8 打开文件失败 %{public}s', e.message);
      this.hint('');
      return;
    }
    this.hint(result.ok ? '' : result.message);
  }
  /** 正文里出现的**电脑上的文档路径**（客户 2026-10-18：我告诉他的文档在手机上点不开） */
  private docPathsOf(text: string): string[] {
    const out: string[] = [];
    const re: RegExp = /(^|[^A-Za-z])([A-Za-z]:[\\/][^\s"`'`，。、；：（）()<>|]*\.[A-Za-z0-9]{1,5})/g;
    let match: RegExpExecArray | null = re.exec(text);
    while (match !== null) {
      const found: string = match[2];
      if (out.indexOf(found) < 0) {
        out.push(found);
      }
      match = re.exec(text);
    }
    return out;
  }

  /** 路径里取文件名 */
  private nameOfPath(p: string): string {
    const at: number = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return at >= 0 ? p.substring(at + 1) : p;
  }

  /** 打开全屏看图：先用已有的 720 图顶上，同时后台按 2160 重新解一张换上 */
  private async openViewer(path: string): Promise<void> {
    this.viewerPath = path;
    this.viewerGeneration = this.viewerGeneration + 1;
    const gen: number = this.viewerGeneration;
    const previous: image.PixelMap | undefined = this.viewerMap;
    this.viewerMap = undefined;
    if (previous !== undefined) {
      try {
        previous.release();
      } catch (releaseError) {
        // 已释放/未初始化都忽略
      }
    }
    let filesDir: string = '';
    try {
      filesDir = (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
    } catch (ctxError) {
      filesDir = '';
    }
    const result: InlineImageResult = isAttachmentId(path)
      ? await loadAttachmentImage(this.client(), this.currentId, path, 2160, 2160)
      : await loadRemoteImage(path, this.sessionCwd, filesDir, 2160, 2160, this.getUIContext().getHostContext());
    // 代次 + 路径都匹配才算"这次打开要的图"（同一张图连点两次，第一张的迟到结果不能盖第二张）
    if (this.viewerGeneration === gen && this.viewerPath === path && result.ok && result.pixelMap !== undefined) {
      this.replaceViewerMap(result.pixelMap);
    } else if (result.pixelMap !== undefined) {
      // 用户已经关掉/换了一张：这张迟到的图没人持有，必须自己释放
      try {
        result.pixelMap.release();
      } catch (releaseError) {
        // 忽略
      }
    }
  }

  /**
   * 选附件：**先挂在输入栏**，点「发送」时才真正上传（客户 2026-10-20）。
   * 只记住选择器给的 uri，不上传、不复制副本。
   */
  private async pickAndUpload(): Promise<void> {
    if (this.uploading || this.currentId.length === 0) {
      return;
    }
    this.attachNote = '';
    let uris: string[] = [];
    try {
      const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        this.showNote('拿不到运行环境，选不了文件');
        return;
      }
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      // 客户 2026-10-20：一次可选多张（上限 10）
      uris = await documentPicker.select({ maxSelectNumber: 10 });
    } catch (error) {
      const e = error as BusinessError;
      this.showNote(`选文件失败：${e.message}`);
      return;
    }
    if (uris.length === 0) {
      return;
    }
    // 多张并列：逐个加，同一个 uri 不重复
    const next: PendingAttachment[] = this.attachedItems.slice();
    for (let u = 0; u < uris.length; u++) {
      const uri: string = uris[u];
      let exists: boolean = false;
      for (let i = 0; i < next.length; i++) {
        if (next[i].uri === uri) {
          exists = true;
          break;
        }
      }
      if (exists) {
        continue;
      }
      const name: string = this.fileNameOf(uri);
      this.pickedFiles.set(name, uri);
      next.push({ name: name, uri: uri });
    }
    this.attachedItems = next;
    hilog.info(DOMAIN, TAG, 'F8 已选附件（共 %{public}d 个，待发送时处理）', this.attachedItems.length);
  }

  /** 只看扩展名判断是不是图片（附件条里给小图预览用）—— 表在 `model/MediaTypes` */
  private isImageName(name: string): boolean {
    return isImageFile(name);
  }

  /** 内联发图用的 MIME —— 同一张表，别在这里另写一份 */
  private mediaTypeOf(name: string): string {
    return mimeOf(name);
  }

  /** 把选择器给的图片读成 base64（超过 8MB 直接拒绝，免得把整条 prompt 撑爆） */
  private readImageBase64(uri: string): string {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      if (size <= 0) {
        throw new Error('空文件');
      }
      if (size > IMAGE_LIMIT_BYTES) {
        throw new Error('图片太大');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      return new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer.slice(0, read)));
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 附件区短提示：显示出来，3.5 秒后自动消失（客户 2026-10-21：别一直挂着） */
  private showNote(text: string): void {
    this.attachNote = text;
    if (this.noteTimer >= 0) {
      clearTimeout(this.noteTimer);
    }
    this.noteTimer = setTimeout(() => {
      this.attachNote = '';
      this.noteTimer = -1;
    }, 3500);
  }
  /** 从 picker 的 URI 里取文件名（取最后一段，去掉查询串） */
  private fileNameOf(uri: string): string {
    let path: string = uri;
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    const at: number = path.lastIndexOf('/');
    const name: string = at >= 0 ? path.substring(at + 1) : path;
    return decodeURIComponent(name);
  }

  /** 发送：**本机立刻上屏**，同时把文字（＋已上传的附件）送进那场会话 */
  /** 发送：**本机立刻上屏**，同时把文字（＋多张图片/文件）一次送进那场会话 */
  private async send(): Promise<void> {
    setPromptMode(this.busy ? 'steer' : 'queue');
    let text: string = this.draft.trim();
    const items: PendingAttachment[] = this.attachedItems;
    hilog.info(DOMAIN, TAG, 'F8 send 触发 text=%{public}d 附件=%{public}d sending=%{public}s',
      text.length, items.length, this.sending ? 'true' : 'false');
    if ((text.length === 0 && items.length === 0) || this.sending) {
      return;
    }
    if (this.currentId.length === 0) {
      this.errorText = '还没连上会话，等一下再发';
      return;
    }
    // 审查 2026-10-22：发送期间锁定**这一场会话**；sendGen 用来让"切走后的旧发送"不再写任何界面状态
    const sessionAtSend: string = this.currentId;
    const sendToken: number = this.sendGen + 1;
    this.sendGen = sendToken;
    this.sending = true;
    this.noticeText = '';
    this.uploading = true;
    this.attachNote = '正在发送…';
    const images: ImagePayload[] = [];
    const receipts: string[] = [];
    // 预处理失败会 return：这时必须自己把 sending 放掉（第二阶段另有 finally 负责）
    let enteredSecondPhase: boolean = false;
    try {
      // 内联图会整段驻留内存并拼进 prompt：一次发送的图片总量也要设上限
      let imageBytes: number = 0;
      for (let i = 0; i < items.length; i++) {
        if (this.isImageName(items[i].name)) {
          try {
            imageBytes += fileIo.statSync(items[i].uri).size;
          } catch (statError) {
            hilog.warn(DOMAIN, TAG, 'F8 图片取大小失败（按未知处理）');
          }
        }
      }
      if (imageBytes > IMAGE_LIMIT_BYTES) {
        this.showNote('图片太大');
        return;
      }
      for (let i = 0; i < items.length; i++) {
        // 上传过程中切会话/退页：立刻中止，别让上传和锁状态带进新会话
        if (this.currentId !== sessionAtSend || this.disposed || this.sendGen !== sendToken) {
          hilog.warn(DOMAIN, TAG, 'F8 发送中止：上传期间切换了会话');
          return;
        }
        const one: PendingAttachment = items[i];
        if (this.isImageName(one.name)) {
          const b64: string = this.readImageBase64(one.uri);
          if (b64.length > Math.ceil(IMAGE_LIMIT_BYTES * 4 / 3)) {
            this.showNote('图片太大');
            return;
          }
          images.push({ data: b64, mediaType: this.mediaTypeOf(one.name) });
        } else {
          const outcome: UploadOutcome =
            await new UploadClient(new HttpTransport()).uploadFile(pairTarget(), sessionAtSend, one.uri, one.name);
          // 上传是长 await：回来时可能已经切会话/退页，后续任何提示与映射都不能写进新会话
          if (this.currentId !== sessionAtSend || this.disposed || this.sendGen !== sendToken) {
            hilog.warn(DOMAIN, TAG, 'F8 上传结果丢弃：期间切换了会话');
            return;
          }
          if (!outcome.ok) {
            this.showNote(`上传失败：${outcome.message}`);
            return;
          }
          const uploaded: string = parseReceiptId(outcome.rawBody);
          if (uploaded.length === 0) {
            this.showNote('上传没成功：电脑侧没给回执');
            return;
          }
          receipts.push(uploaded);
          // 记住「电脑侧给的附件 id / 文件字节数 → 本机原文件」，点卡片时能直接放本机这份（视频靠它）
          // 关键：消息里带的是 attachmentId（sha256），回执里的是 receiptId ⇒ 两个键都记，否则 id 永远对不上
          if (outcome.attachmentId.length > 0) {
            this.sentFiles.set(outcome.attachmentId, one.uri);
          }
          this.sentFiles.set(uploaded, one.uri);
          try {
            this.sentSizes.set(fileIo.statSync(one.uri).size, one.uri);
          } catch (statError) {
            hilog.warn(DOMAIN, TAG, 'F8 附件取大小失败（不影响发送）');
          }
        }
      }
      // 走到这里 = 附件预处理成功、马上进入发 prompt；finally 在 return 前会看到 true
      enteredSecondPhase = true;
    } catch (error) {
      const e = error as BusinessError;
      this.showNote(`发送前处理附件失败：${e.message}`);
      return;
    } finally {
      // 只有"这次发送"才能释放锁：切走后旧发送的 finally 不能把新会话的锁清掉
      if (this.sendGen === sendToken) {
        this.uploading = false;
        if (enteredSecondPhase) {
          this.attachNote = '';
        } else {
          // 预处理失败：放掉发送锁，但**保留 showNote 的提示**（由它的 3.5s 定时器收尾）
          this.sending = false;
        }
      }
    }
    // 上传期间可能已经切会话/退页：**先判再写**，否则旧会话的发送会清掉新会话草稿、把气泡落到新会话
    if (this.currentId !== sessionAtSend || this.disposed || this.sendGen !== sendToken) {
      hilog.warn(DOMAIN, TAG, 'F8 send 中断：期间切换了会话或页面已退出');
      return;
    }
    enteredSecondPhase = true;
    this.draft = '';
    // ① 立刻显示自己这条（不等电脑）
    const shown: string = text.length > 0 ? text : `（${items.length} 个附件）`;
    const echo: ChatMessage = localMessage(shown, items.length > 0 ? items[0].name : '');
    this.setMessages(this.messages.concat([echo]));
    this.scrollToBottom();
    try {
      const sent: Ac16SendResult = await sendRich(this.client(), sessionAtSend, text, images, receipts);
      // 等结果期间切走/退页：这条结果属于旧会话，绝不能写新会话的草稿/提示/输入栏
      if (this.currentId !== sessionAtSend || this.disposed || this.sendGen !== sendToken) {
        hilog.warn(DOMAIN, TAG, 'F8 send 结果丢弃：期间切换了会话或页面已退出');
        return;
      }
      if (!sent.ok) {
        hilog.warn(DOMAIN, TAG, 'F8 send failed');
        // 没受理 ⇒ 撤掉乐观气泡、把文字放回输入框（别让人以为发出去了）
        this.setMessages(this.messages.filter((m: ChatMessage) => m.key !== echo.key));
        if (this.draft.length === 0) {
          this.draft = text;
        }
        // 连接状态只由实时流维护，不因一次发送结果写死成"已断开"
        this.noticeText = humanOfSend(sent.detail);
      } else {
        this.noticeText = '';
        this.attachedItems = [];
      }
    } catch (error) {
      const e = error as Error;
      hilog.warn(DOMAIN, TAG, 'F8 send exception %{public}s', e.message);
      if (this.currentId !== sessionAtSend || this.disposed || this.sendGen !== sendToken) {
        return;
      }
      this.statusText = 'dsh 已断开';
      this.noticeText = '';
    } finally {
      if (this.sendGen === sendToken) {
        this.sending = false;
      }
    }
  }


  private scrollToBottom(): void {
    setTimeout(() => {
      try {
        this.listScroller.scrollEdge(Edge.Bottom);
      } catch (scrollError) {
        hilog.warn(DOMAIN, TAG, 'F8 scroll failed');
      }
    }, 30);
  }

  /**
   * 读会话列表：**官方分组视图**（`workspace/follow`）＋ 会话摘要（`session/list`）。
   * 客户 2026-10-17 口径：只要**当前项目（DeepSeek）下面**的会话 —— 分组、归档、置顶全部以电脑给的为准，
   * 手机不再"全量拉回来自己分组"。取不到分组视图时退回摘要全量（尽力剔掉子 agent / 归档）。
   */
  private async loadRows(currentId: string): Promise<SessionRow[]> {
    const listed: SessionListResult = await listSessions(this.client());
    this.loadRowsOk = listed.ok;
    if (!listed.ok) {
      // 第二次 session/list 失败也不能当成"没有会话"（否则 boot 会凭空新建一场）
      this.allRows = [];
      return [];
    }
    // 成功路径清掉"正在读取…"；分组失败会在下面重新写成错误提示
    this.sideNote = '';
    this.allRows = listed.rows;
    // 当前项目 = 最近那场非空会话的 cwd（第一次进页时就是它）
    let cwd: string = this.sessionCwd;
    if (cwd.length === 0) {
      for (let i = 0; i < listed.rows.length; i++) {
        if (!listed.rows[i].blank && listed.rows[i].cwd.length > 0) {
          cwd = listed.rows[i].cwd;
          break;
        }
      }
    }
    if (cwd.length === 0) {
      return visibleRows(listed.rows, emptyWorkspaceState(), '', currentId);
    }
    const state: WorkspaceState = await fetchWorkspaceState(
      pairingVault.hostOr(''), pairingVault.get());
    // 界面不摆开发者的话；只在取不到分组视图时给一句人话
    this.sideNote = state.ok ? '' : `没能读到电脑上的分组（${state.detail}）`;
    return visibleRows(listed.rows, state, cwd, currentId);
  }

  /** 左栏：会话列表（看见别的会话）＋ 新建 */
  private async refreshSide(): Promise<void> {
    this.sideNote = '正在读取…';
    const rows: SessionRow[] = await this.loadRows(this.currentId);
    if (!this.loadRowsOk) {
      // 读失败时保留旧列表并说明，不能把侧栏清空成"没有会话"
      this.sideNote = '没能读到会话列表（dsh 已断开）';
      return;
    }
    this.rows = rows;
  }

  private async newSession(): Promise<void> {
    this.sideNote = '正在新建…';
    const ensured: SessionEnsure = await ensureSession(this.client(), this.sessionCwd);
    if (this.disposed) {
      return;
    }
    this.sideNote = ensured.detail;
    if (ensured.ok) {
      this.currentId = ensured.sessionId;
      this.sessionTitle = `会话 …${this.shortId(ensured.sessionId)}`;
      this.showSide = false;
      this.resetForSessionSwitch();
      this.subscribe(ensured.sessionId);
      this.loadPermission();
      // 不再需要"把会话挂进工作区"：dsh 的工作区归属**按会话头的 cwd 匹配**（实测：新建即进 DeepSeek 组）
      await this.refreshSide();
    }
  }

  private pickSession(row: SessionRow): void {
    this.showSide = false;
    this.currentId = row.sessionId;
    // 换会话就换读取根（内嵌图片只允许从这场会话的工作区取）
    this.sessionCwd = row.cwd;
    this.sessionTitle = row.title.length > 0 ? row.title : `会话 …${this.shortId(row.sessionId)}`;
    this.resetForSessionSwitch();
    this.subscribe(row.sessionId);
    this.loadPermission();
  }

  /**
   * 切会话/新建会话：清掉一切"属于上一场"的界面状态（图片、本机文件映射、忙状态、看大图）。
   * 以前只有 pickSession 做了清理，newSession 没做 ⇒ 旧会话的图会卡在"加载中"、旧文件映射会串台。
   */
  private resetForSessionSwitch(): void {
    this.sessionGeneration = this.sessionGeneration + 1;
    for (let i = 0; i < this.inlineStates.length; i++) {
      const map: image.PixelMap | undefined = this.inlineStates[i].pixelMap;
      if (map !== undefined) {
        try {
          map.release();
        } catch (releaseError) {
          // 已释放/未初始化都忽略
        }
      }
    }
    this.inlineStates = [];
    this.loadingImages = false;
    this.imagesPending = false;
    this.pickedFiles.clear();
    // sentFiles 的键是 sha256/回执（全局唯一）⇒ 保留：切回来还能认回"本机那份"（视频首帧、自己发的不给保存）
    // sentSizes 的键是字节数（会串台）⇒ 随会话作废
    this.sentSizes.clear();
    // 上一场挑的附件不该跟到新会话（否则"发送"会把旧会话的文件带过去）
    this.attachedItems = [];
    this.attachNote = '';
    // 旧会话的发送可能还在等上传/回执：UI 锁必须随会话立刻释放（旧发送自己会按代次丢弃结果）
    this.sendGen = this.sendGen + 1;
    this.sending = false;
    this.uploading = false;
    // 上一场的发送失败红字 / 打开文件灰字不能留到新会话
    this.noticeText = '';
    this.hintText = '';
    this.busy = false;
    this.closeViewer();
  }

  /** 关全屏看图，并释放它持有的 PixelMap（不释放会随每次点开累积） */
  private closeViewer(): void {
    this.viewerGeneration = this.viewerGeneration + 1;
    const map: image.PixelMap | undefined = this.viewerMap;
    this.viewerPath = '';
    this.viewerMap = undefined;
    if (map !== undefined) {
      try {
        map.release();
      } catch (releaseError) {
        // 忽略
      }
    }
  }

  /** 换上新的全屏图，并释放上一张（同一张图连点两次也不会漏） */
  private replaceViewerMap(map: image.PixelMap): void {
    const old: image.PixelMap | undefined = this.viewerMap;
    this.viewerMap = map;
    if (old !== undefined) {
      try {
        old.release();
      } catch (releaseError) {
        // 忽略
      }
    }
  }

  @Builder
  bubble(m: ChatMessage) {
    Row() {
      if (m.role === 'user') {
        Blank()
      }
      Column({ space: 3 }) {
        // 不写 width('100%')：让它按约束自然换行（写 100% 会撑到整行宽，看起来"字体超边界"）
        Text(m.text)
          .fontSize(15)
          .fontColor('#2A1C14')
          // 客户 2026-10-20：对话内容要能长按选中复制
          .copyOption(CopyOptions.LocalDevice)
        // 消息里带的图片（工具调用 present/show_image 或正文 [名][路径]）
        if (m.images.length > 0) {
          ForEach(m.images, (path: string) => {
            this.inlineImage(path)
          }, (path: string) => path)
        }
        // 消息里带的**文件附件**（手机发出去的文件）——显示成一张小卡片
        if (m.files.length > 0) {
          ForEach(m.files, (f: FollowFile) => {
            this.fileChip(f)
          }, (f: FollowFile) => `${f.attachmentId}-${f.name}`)
        }
        // 正文里提到的**电脑上的文档**（客户 2026-10-18：我告诉他的文档，在手机上也应该点得开）
        if (this.docPathsOf(m.text).length > 0) {
          ForEach(this.docPathsOf(m.text), (p: string) => {
            this.docChip(p)
          }, (p: string) => p)
        }
        Row({ space: 8 }) {
          Text(`${formatClock(m.timeMs)}${m.streaming ? '｜正在输入…' : ''}`)
            .fontSize(10)
            .fontColor('#8a8f98')
          if (m.text.length > 0 && !m.streaming) {
            Text('复制')
              .fontSize(10)
              .fontColor('#E0622A')
              .onClick(() => {
                this.copyText(m.text);
              })
          }
        }
      }
      .padding(10)
      .backgroundColor(m.role === 'user' ? '#FBE6DA' : '#FFFFFF')
      .borderRadius(12)
      .border({ width: 1, color: '#EAD9C8' })
      .constraintSize({ maxWidth: '78%' })
      .alignItems(HorizontalAlign.Start)
      if (m.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
  }

  @Builder
  sideDrawer() {
    // 客户 2026-10-20：不要标题和「关闭」按钮；点空白处关闭；新建=圆圈 +，刷新=刷子跟在后面
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .onClick(() => {
          this.showSide = false;
        })
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          // 新建：圆圈直径 = 刷新图标直径（22），空心无底色，线宽与加号一致
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(22)
              .height(22)
              .border({ width: 2, color: '#E0622A' })
              .borderRadius(11)
            Text('+')
              .fontSize(18)
              .fontColor('#E0622A')
              .textAlign(TextAlign.Center)
              .width(22)
              .height(22)
          }
          .width(44)
          .height(44)
          .onClick(() => {
            this.newSession();
          })
          Text('⟳')
            .fontSize(22)
            .fontColor('#5b6470')
            .textAlign(TextAlign.Center)
            .width(44)
            .height(44)
            .onClick(() => {
              this.refreshSide();
            })
        }
        .width('100%')
        Text(this.sideNote).fontSize(11).fontColor('#8a8f98').width('100%')
        List({ space: 6 }) {
          ForEach(this.rows, (row: SessionRow) => {
            ListItem() {
              Column({ space: 2 }) {
                Text(row.title.length > 0 ? row.title : (row.blank ? '新会话' : `会话 …${this.shortId(row.sessionId)}`))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(row.sessionId === this.currentId ? '#E0622A' : '#2A1C14')
                  .width('100%')
                Text(`${formatClock(row.updatedAtMs)}${row.running ? '｜运行中' : ''}${row.blank ? '｜空会话' : ''}`)
                  .fontSize(10).fontColor('#8a8f98').width('100%')
              }
              .padding(10)
              .backgroundColor(row.sessionId === this.currentId ? '#FBE6DA' : '#F7F2EC')
              .borderRadius(10)
              .width('100%')
            }
            .onClick(() => {
              this.pickSession(row);
            })
          }, (row: SessionRow) => `${row.sessionId}-${row.title}-${row.running}-${row.updatedAtMs}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
      .padding({ left: 12, right: 12, top: this.safeTop + 8, bottom: 12 })
      .width(280)
      .height('100%')
      .backgroundColor('#ffffff')
      .borderRadius({ topRight: 14, bottomRight: 14 })
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        // 抽屉内部点击不穿透到遮罩
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  inputBar() {
    Column({ space: 6 }) {
      // ② 发消息出的问题：红字，**不给**重连按钮（跟连接无关）
      if (this.noticeText.length > 0) {
        Text(this.noticeText).fontSize(12).fontColor('#b3261e').width('100%')
      }
      // ②b 打开文件的结果：**灰字**（不是错误；客户 2026-10-18：别刷红）
      if (this.hintText.length > 0) {
        Text(this.hintText).fontSize(12).fontColor('#8a8f98').width('100%')
      }
      // ④ 附件条：可多张并列；**图片只显示缩略图**（客户 2026-10-20：不要显示文件名），文件才显示名字
      if (this.attachedItems.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.attachedItems, (one: PendingAttachment, index: number) => {
              Stack({ alignContent: Alignment.TopEnd }) {
                if (this.isImageName(one.name)) {
                  Image(one.uri)
                    .width(56)
                    .height(56)
                    .borderRadius(8)
                    .objectFit(ImageFit.Cover)
                } else if (isVideoFile(one.name)) {
                  // 客户 2026-10-21：视频也给**画面预览**（只出第一帧、不播放），别再只显示文件名
                  VideoThumb({ uri: one.uri, side: 56 })
                } else {
                  Row({ space: 4 }) {
                    SymbolGlyph($r('sys.symbol.doc_text')).fontSize(16).fontColor(['#5b6470'])
                    Text(one.name).fontSize(12).fontColor('#8C6F5A').maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .padding({ left: 8, right: 8 })
                  .height(56)
                  .backgroundColor('#f4f6f9')
                  .borderRadius(8)
                }
                Text('×')
                  .fontSize(12)
                  .fontColor('#ffffff')
                  .textAlign(TextAlign.Center)
                  .width(18)
                  .height(18)
                  .borderRadius(9)
                  .backgroundColor('#8a8f98')
                  // 发送/上传期间不许移除：send() 已经按引用快照了附件，移除也拦不住上传，只会造成"界面消失了但还在传"
                  .enabled(!this.sending && !this.uploading)
                  .onClick(() => {
                    const next: PendingAttachment[] = this.attachedItems.slice();
                    next.splice(index, 1);
                    this.attachedItems = next;
                  })
              }
            }, (one: PendingAttachment) => one.uri)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .align(Alignment.Start)
        .width('100%')
      }
      if (this.attachNote.length > 0) {
        Text(this.attachNote).fontSize(12).fontColor('#8a8f98').width('100%')
      }
      Row({ space: 8 }) {
        // 「＋」：从手机选一个文件传到电脑上的这场对话（功能 8 的界面入口）
        Button() {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor(['#5b6470'])
        }
        .id('chat-attach')
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor('#FFFFFF')
        .enabled(!this.uploading && !this.sending && this.currentId.length > 0)
        .onClick(() => {
          this.pickAndUpload();
        })
        // 输入框**始终在**：语音识别的文字就是往这里铺的（说一个字显示一个字）。
        // 外观（客户 2026-10-16）：**不要占位文字**；做成**下凹**一点（顶部偏暗 → 底部偏亮 + 一道浅边），不是平的。
        Row() {
          // 客户 2026-10-20：输入框要能换行 ⇒ TextInput 换 TextArea（Enter 换行，发送仍走「发送」按钮）
          TextArea({ text: this.draft })
            .id('chat-input')
            .layoutWeight(1)
            .constraintSize({ minHeight: 32, maxHeight: 120 })
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .borderRadius(19)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            // 客户 2026-10-21：大视频上传要时间，这段时间**输入框要变灰、不能输入**（光标别闪），
            // 发完再恢复 —— 否则用户以为发完了，其实还在传。
            .enabled(!this.uploading && !this.sending)
            .fontColor(this.uploading || this.sending ? '#66000000' : '#2A1C14')
            .onChange((value: string) => {
              this.draft = value;
            })
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: 34 })
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#EAD9C8' })
        .borderRadius(17)
        // 语音输入：**交给系统输入法**（客户 2026-10-17 定）——
        // 不再自绘麦克风、不再自己采音写流。手机上点键盘上的语音键说话，文字落进下面的输入框，改了再发。
          .onClick(() => {
          })
          .onClick(() => {
          })
        if (this.busy && this.draft.trim().length === 0 && this.attachedItems.length === 0) {
          Button('停止')
            .id('chat-stop')
            .width(64)
            .height(34)
            .fontSize(15)
            .maxFontScale(1.6)
            .backgroundColor('#FBE6DA')
            .fontColor('#8C6F5A')
            .onClick(() => {
              this.stopGeneration();
            })
        } else if (this.busy) {
          Button('插入')
            .id('chat-steer')
            .width(64)
            .height(34)
            .fontSize(15)
            .maxFontScale(1.6)
            .backgroundColor('#E0622A')
            .enabled((this.draft.trim().length > 0 || this.attachedItems.length > 0) && !this.uploading)
            .onClick(() => {
              this.send();
            })
        } else {
          Button('发送')
            .id('chat-send')
            .width(64)
            .height(34)
            .fontSize(15)
            .maxFontScale(1.6)
            .backgroundColor('#E0622A')
            .enabled((this.draft.trim().length > 0 || this.attachedItems.length > 0) && !this.sending && !this.uploading)
            .onClick(() => {
              this.send();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /**
   * 右上角那一个字：**连接状态优先**（客户 2026-10-18：dsh 断了就写这里，底部不再刷红字）。
   * 正常时显示这轮在不在干活（正在思考…／空闲）。
   */
  private async stopGeneration(): Promise<void> {
    if (this.currentId.length === 0) {
      return;
    }
    try {
      const args: string = '{"request":{"sessionId":' + JSON.stringify(this.currentId) + '}}';
      const res = await this.client().rpc('session/cancel', args);
      if (!res.apiOk) {
        promptAction.showToast({ message: `停止失败：${res.apiError}`, duration: 2000 });
      }
    } catch (error) {
      promptAction.showToast({ message: '停止失败', duration: 2000 });
    }
  }

  private statusLabel(): string {
    if (this.statusText === '正在连接电脑…' || this.statusText === '正在读取会话…' ||
      this.statusText === '还没连接电脑') {
      return this.statusText;
    }
    if (this.statusText === 'dsh 已断开' || this.statusText === '没连上') {
      return this.statusText;
    }
    return this.busy ? '正在思考…' : '空闲';
  }

  private statusColor(): string {
    if (this.statusText === 'dsh 已断开' || this.statusText === '没连上') {
      return '#b3261e';
    }
    return this.busy ? '#E0622A' : '#8a8f98';
  }

  // ── f14 权限 / f15 审批 ──────────────────────────────────────────

  @Builder
  permMenu() {
    Menu() {
      ForEach(this.permOptions, (one: PermOption) => {
        MenuItem({ content: one.name })
          .onClick(() => {
            this.changePermission(one.value);
          })
      }, (one: PermOption) => one.value)
    }
  }

  private permLabel(): string {
    if (this.permCurrent === 'custom') {
      return '自定义权限';
    }
    for (let i = 0; i < this.permOptions.length; i++) {
      if (this.permOptions[i].value === this.permCurrent) {
        return this.permOptions[i].name;
      }
    }
    return this.permCurrent.length > 0 ? this.permCurrent : '权限';
  }

  private async loadPermission(): Promise<void> {
    if (this.currentId.length === 0) {
      return;
    }
    const state = await fetchPermission(this.currentId);
    if (this.disposed || this.currentId.length === 0) {
      return;
    }
    if (state.ok) {
      this.permOptions = state.options;
      this.permCurrent = state.current;
    }
  }

  private async changePermission(value: string): Promise<void> {
    if (this.currentId.length === 0) {
      return;
    }
    const state = await setPermission(this.currentId, value);
    if (state.ok) {
      this.permOptions = state.options;
      this.permCurrent = state.current;
      promptAction.showToast({ message: `权限：${this.permLabel()}`, duration: 2000 });
    } else {
      promptAction.showToast({ message: state.detail.length > 0 ? state.detail : '改权限失败', duration: 2500 });
    }
  }

  onForegroundTick(): void {
    this.approvalBridge?.refresh();
  }

  private ensureApprovalBridge(): void {
    if (this.approvalBridge !== undefined) {
      return;
    }
    const bridge: ApprovalBridge = new ApprovalBridge();
    bridge.onRequest = (request: ApprovalRequest) => {
      this.enqueueApproval(request);
    };
    bridge.onPendingList = (items: ApprovalRequest[]) => {
      for (let i = 0; i < items.length; i++) {
        this.enqueueApproval(items[i]);
      }
    };
    bridge.onCancelled = (id: string) => {
      for (let i = this.approvalQueue.length - 1; i >= 0; i--) {
        if (this.approvalQueue[i].id === id) {
          this.approvalQueue.splice(i, 1);
        }
      }
      // 电脑那边先处理了：把这个 sheet 收起来，继续下一条
      if (this.currentApprovalId === id) {
        this.approvalVisible = false;
        this.approvalCurrent = undefined;
        this.approvalShowing = false;
        this.currentApprovalId = '';
        this.showNextApproval();
      }
    };
    bridge.onClickFailed = (id: string, reason: string) => {
      this.showNote(reason === 'no-web' ? '电脑网页没开，去电脑上处理' : '审批已经处理过了');
    };
    bridge.onClosed = () => { };
    bridge.connect();
    this.approvalBridge = bridge;
  }

  private enqueueApproval(request: ApprovalRequest): void {
    if (request.id.length === 0 || request.id === this.currentApprovalId) {
      return;
    }
    for (let i = 0; i < this.approvalQueue.length; i++) {
      if (this.approvalQueue[i].id === request.id) {
        return;
      }
    }
    this.approvalQueue.push(request);
    this.showNextApproval();
  }

  private copyText(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '已复制', duration: 1500 });
      }).catch(() => {
      });
    } catch (error) {
      // 忽略
    }
  }

  /**
   * 审批改成底部 sheet（2026-10-25）：
   * 原来的系统对话框没法写清"在电脑上执行什么"，也不能做成暖色风格。
   */
  private showNextApproval(): void {
    if (this.approvalShowing) {
      return;
    }
    const request: ApprovalRequest | undefined = this.approvalQueue.shift();
    if (request === undefined) {
      this.approvalVisible = false;
      return;
    }
    this.approvalShowing = true;
    this.currentApprovalId = request.id;
    this.approvalCurrent = request;
    this.approvalTitle = request.sessionId === this.currentId ? '需要授权' : '另一个会话需要授权';
    this.approvalTool = request.toolName;
    this.approvalReason = request.displayReason.length > 0 ? request.displayReason : request.reason;
    this.approvalVisible = true;
  }

  private decideApproval(allow: boolean): void {
    const request: ApprovalRequest | undefined = this.approvalCurrent;
    this.approvalVisible = false;
    this.approvalCurrent = undefined;
    this.approvalShowing = false;
    this.currentApprovalId = '';
    if (request !== undefined) {
      this.approvalBridge?.decide(request.id, allow);
      promptAction.showToast({ message: '已提交审批', duration: 1200 });
    }
    this.showNextApproval();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // ── 顶栏：会话列表 ｜ 回首页 ｜ 会话标题 ｜ 状态 ──
        Row({ space: 6 }) {
          // 客户 2026-10-20：三横改两横（上长下短），不要底色；箭头去掉（手机自带侧滑返回）
          Column({ space: 5 }) {
            Row().width(18).height(2.5).borderRadius(2).backgroundColor('#1f2329')
            Row().width(12).height(2.5).borderRadius(2).backgroundColor('#1f2329')
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            this.showSide = true;
            this.refreshSide();
          })
          Text(this.sessionTitle)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 客户 2026-10-17：不要「已连接（实时）」那种状态串；只显示"在不在干活"。
          // 客户 2026-10-18：断开时这里改写成「dsh 已断开」（红），不再在底部刷红字。
          if (this.permOptions.length > 0) {
            Button(this.permLabel())
              .fontSize(10)
              .height(24)
              .padding({ left: 8, right: 8 })
              .backgroundColor('#FBE6DA')
              .fontColor('#8C6F5A')
              .bindMenu(this.permMenu())
          }
          Button('工件')
            .fontSize(10)
            .height(24)
            .padding({ left: 8, right: 8 })
            .backgroundColor('#FBE6DA')
            .fontColor('#8C6F5A')
            .onClick(() => {
              router.pushUrl({ url: 'pages/Artifacts' });
            })
          Text(this.statusLabel())
            .fontSize(11)
            .fontColor(this.statusColor())
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })

        // ── 对话正文：来一条就上一条，并自动滚到底 ──
        List({ scroller: this.listScroller, space: 10 }) {
          LazyForEach(this.msgSource, (m: ChatMessage) => {
            ListItem() {
              this.bubble(m)
            }
          }, (m: ChatMessage) => m.key)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
        .scrollBar(BarState.Off)
        .cachedCount(6)

        // 空态：还没有消息时只显示"正在连接…"；**断开的那句只在底部红字出现一次**（客户 2026-10-18）
        if (this.messages.length === 0 && this.errorText.length === 0) {
          Text('正在连接电脑上的那场会话…')
            .fontSize(13)
            .fontColor('#8a8f98')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 24 })
        }

        // ── 错误提示（以前只写进 errorText，界面上根本看不到 ⇒ 静默失败）──
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(12)
            .fontColor('#b3261e')
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 4 })
        }

        // ── 底部输入条 ──
        this.inputBar()
      }
      .width('100%')
      .height('100%')
      // 键盘弹起时把键盘高度当底部内边距（页面自己缩，系统就不再整页上移 ⇒ 顶栏留得住）
      .padding({ top: this.safeTop + 8, bottom: 8 })
      .backgroundColor('#FFFBF5')

      if (this.showSide) {
        this.sideDrawer()
      }

      // ── 图片全屏查看（客户 2026-10-17：对话里的图要能点开看）──
      if (this.viewerPath.length > 0) {
        Column({ space: 8 }) {
          if (this.viewerMap !== undefined) {
            Image(this.viewerMap as image.PixelMap)
              .objectFit(ImageFit.Contain)
              .constraintSize({ maxWidth: '100%', maxHeight: '82%' })
              .borderRadius(6)
          } else if (this.imageMapOf(this.viewerPath) !== undefined) {
            Image(this.imageMapOf(this.viewerPath) as image.PixelMap)
              .objectFit(ImageFit.Contain)
              .constraintSize({ maxWidth: '100%', maxHeight: '82%' })
              .borderRadius(6)
          } else {
            Text('这张图还没取到')
              .fontSize(14).fontColor('#ffffff')
          }
          Text('点任意位置关闭').fontSize(12).fontColor('#c9c9c9')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#e6000000')
        .onClick(() => {
          this.closeViewer();
        })
      }

      // ── 审批：底部 sheet（2026-10-25），写清在电脑上要执行什么 ──
      if (this.approvalVisible) {
        Column() {
          Blank()
          Column({ space: 10 }) {
            Text(this.approvalTitle)
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#2A1C14')
            Text(this.approvalTool)
              .fontSize(12).fontColor('#8C6F5A')
            if (this.approvalReason.length > 0) {
              Text(this.approvalReason)
                .fontSize(13).fontColor('#2A1C14')
                .maxLines(5)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            Row({ space: 12 }) {
              Button('拒绝')
                .layoutWeight(1).height(46)
                .backgroundColor('#FBE6DA').fontColor('#E0622A')
                .borderRadius(23)
                .onClick(() => {
                  this.decideApproval(false);
                })
              Button('允许一次')
                .layoutWeight(1).height(46)
                .backgroundColor('#E0622A').fontColor('#FFFFFF')
                .borderRadius(23)
                .onClick(() => {
                  this.decideApproval(true);
                })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('100%')
          .padding(20)
          .backgroundColor('#FFFFFF')
          .borderRadius({ topLeft: 24, topRight: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 发送失败是不是"连接没了"（HTTP 0 = 没发出去；401 = 凭据失效；平台网络码同样算） */
function sendFailureMeansOffline(detail: string): boolean {
  const lower: string = detail.toLowerCase();
  return lower.indexOf('http 0') >= 0 || lower.indexOf('401') >= 0 ||
    lower.indexOf('2300007') >= 0 || lower.indexOf('2300028') >= 0;
}

/** 发送失败 → 人话 */
function humanOfSend(detail: string): string {
  if (detail.indexOf('401') >= 0) {
    return '凭据失效了，回上一页重新点「连接」';
  }
  if (detail.indexOf('writer-held') >= 0) {
    return '这场会话正在电脑上使用（换一场或新建会话再发）';
  }
  if (detail.indexOf('not-found') >= 0) {
    return '这场会话在电脑上已经没有了（换一场再发）';
  }
  return `发不出去：${detail}`;
}






























/**
 * 快照合并（审查 2026-10-22）：把**还没被电脑确认的本机回显**保留下来。
 * 快照里出现同文本的 user 消息 ⇒ 说明已被确认，那个回显就该丢；
 * 否则保留（否则网络一抖，刚发出去的泡泡凭空消失，用户会重发）。
 */
function keepPendingEcho(fromSnapshot: ChatMessage[], current: ChatMessage[]): ChatMessage[] {
  const confirmed: string[] = [];
  for (let i = 0; i < fromSnapshot.length; i++) {
    if (fromSnapshot[i].role === 'user') {
      confirmed.push(fromSnapshot[i].text.trim());
    }
  }
  const out: ChatMessage[] = [];
  for (let i = 0; i < fromSnapshot.length; i++) {
    out.push(fromSnapshot[i]);
  }
  for (let i = 0; i < current.length; i++) {
    const m: ChatMessage = current[i];
    if (!m.key.startsWith('local-')) {
      continue;
    }
    const shown: string = m.text.trim();
    if (shown.length > 0 && confirmed.indexOf(shown) >= 0) {
      continue; // 已被电脑侧确认
    }
    out.push(m);
  }
  return out;
}








