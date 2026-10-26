import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { DeviceProfile, profileProblem } from '../../model/DeviceProfile';
import { profileStore, setActiveProfile } from '../../services/ProfileStore';
import { DshApiClient, DshApiResult, pluginTarget } from '../../services/DshApiClient';
import { KernelStatus, PeerInfo, kernelStatus, peersAsync } from '../f01-tailnet/KernelBridge';
import { isExtensionLive, readExtensionStatus, sendExtensionCommand } from '../f01-tailnet/VpnStatusStore';
import { VpnExtensionStatus } from '../../model/VpnTypes';
import { PairClaimResult, PairInfoResult, claimCredential, fetchPairInfo, humanPairError } from '../f03-connect/DshPairing';
import { expiryText, pairingVault } from '../f03-connect/PairingVault';
import { EVENT_VPN_STATUS, subscribeEvent } from '../f01-tailnet/VpnBus';
import { dshStarter } from '../../services/ssh/DshStarter';
import { StartOutcome, StartState, StopOutcome, StopState, PowerOutcome, PowerState } from '../../services/ssh/DshStarter';
import { tcpOpen } from '../../services/ssh/SshProbe';
import { openDesktopPage } from '../f14-permission/PermissionClient';
import {
  UI_TEXT, UI_TEXT2, UI_TEXT3, UI_SURFACE, UI_ACCENT, UI_ACCENT_SOFT,
  UI_OK, UI_OK_SOFT, UI_WARN, UI_WARN_SOFT, UI_LINE, UI_CARD_RADIUS
} from '../../model/UiTheme';

const DOMAIN: number = 0xD001;
const TAG: string = 'DEVICE';

/** 一行设备：**电脑名字 ＋ 在线/离线 ＋ 连接按钮**（客户 2026-10-15 定） */
interface DeviceRow {
  /** 电脑名字（优先 Tailscale 的设备名） */
  name: string;
  /** 主地址（连它用；优先 IPv4） */
  address: string;
  /** 全部 tailnet 地址（用来认"答话的是不是这一行"） */
  addresses: string[];
  /** 这台电脑在不在线（tailnet 报的） */
  online: boolean;
  /** 这台机器上的 dsh 配对口**真的回话了**（探过才算；客户 2026-10-17） */
  dshReady: boolean;
  /** 一行的说明（在线 / 离线） */
  note: string;
  /** **第二行字**：这台电脑上的 dsh 状态（客户 2026-10-17：要单独一行，不要挤在"在线"后面） */
  dshNote: string;
  /**
   * 这台机器**能不能被 SSH 拉起来**（客户 2026-10-21：手机等非电脑设备不该出现「启动」）。
   * 判据 = 它的 SSH 端口（SSH 端口）真的开着；探一次，不轮询。
   */
  canStart: boolean;
}

/** 列表显示的电脑名：优先短主机名，没有再取 DNS 名的第一段（去掉 .tailxxxx.ts.net 这类尾巴） */
function shortPeerName(p: PeerInfo, fallback: string): string {
  if (p.hostName !== undefined && p.hostName.length > 0) {
    return p.hostName;
  }
  if (p.name.length > 0) {
    const dot: number = p.name.indexOf('.');
    return dot > 0 ? p.name.substring(0, dot) : p.name;
  }
  return fallback;
}

/** 探活超时时的兜底结果（形状要与 `PairInfoResult` 一致） */
function probeFallback(): PairInfoResult {
  const fallback: PairInfoResult = {
    ok: false, status: 0, phoneAuthority: '', dshAuthority: '', credentialLifetimeDays: 0,
    pluginName: '', pluginVersion: '', tailnet: '', elapsedMs: 0,
    message: '超时', url: ''
  };
  return fallback;
}

function withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
  const timeout: Promise<T> = new Promise<T>((resolve: (v: T) => void) => {
    setTimeout(() => {
      resolve(fallback);
    }, ms);
  });
  return Promise.race([p, timeout]);
}

/**
 * 真机的内核跑在 **VPN 扩展进程**里，本进程的 NAPI 看不到它 ⇒ 网络状态与 peer 列表
 * 只能从扩展写的状态文件里取（扩展写完会发事件，这里进页面读一次就够）。
 */
function extensionRunning(filesDir: string): boolean {
  const st: VpnExtensionStatus | undefined = readExtensionStatus(filesDir);
  if (st === undefined) {
    return false;
  }
  // 心跳必须新鲜：装包/重启后旧文件里的 Running 不能当"已入网"（否则会跳过登录、隧道是断的）
  return isExtensionLive(st, Date.now());
}

/** 从扩展状态文件里取 peer 列表（取不到返回空数组） */
function peersFromExtension(filesDir: string): PeerInfo[] {
  const st: VpnExtensionStatus | undefined = readExtensionStatus(filesDir);
  if (st === undefined || st.peersJson === undefined || st.peersJson.length === 0) {
    return [];
  }
  const raw: string = st.peersJson;
  let parsed: Object[] = [];
  try {
    parsed = JSON.parse(raw) as Object[];
  } catch (parseError) {
    return [];
  }
  if (!Array.isArray(parsed)) {
    // 合法 JSON 但不是数组（旧版/写坏的状态文件）：当没有 peers，别让整页报错
    return [];
  }
  // 旧版本/写坏的状态文件可能缺字段：逐项补默认，别让一个坏 peer 把整页打成「查找出错」
  const out: PeerInfo[] = [];
  for (const item of parsed) {
    if (item === null || item === undefined) {
      continue;
    }
    const rec: Record<string, Object> = item as Record<string, Object>;
    const rawName: Object | undefined = rec['name'];
    const rawHost: Object | undefined = rec['hostName'];
    const rawDns: Object | undefined = rec['dnsName'];
    const rawOnline: Object | undefined = rec['online'];
    const rawLastSeen: Object | undefined = rec['lastSeen'];
    const rawLastSeenMs: Object | undefined = rec['lastSeenUnixMs'];
    const rawOs: Object | undefined = rec['os'];
    const rawAddresses: Object | undefined = rec['addresses'];
    const addresses: string[] = [];
    if (Array.isArray(rawAddresses)) {
      const list: Object[] = rawAddresses as Object[];
      for (const one of list) {
        if (typeof one === 'string') {
          addresses.push(one as string);
        }
      }
    }
    out.push({
      name: typeof rawName === 'string' ? rawName as string : '',
      hostName: typeof rawHost === 'string' ? rawHost as string : '',
      dnsName: typeof rawDns === 'string' ? rawDns as string : '',
      online: rawOnline === true,
      lastSeen: typeof rawLastSeen === 'string' ? rawLastSeen as string : '',
      lastSeenUnixMs: typeof rawLastSeenMs === 'number' ? rawLastSeenMs as number : 0,
      addresses: addresses,
      os: typeof rawOs === 'string' ? rawOs as string : ''
    });
  }
  return out;
}

/** 优先取 IPv4（拼 URL 用；IPv6 要加方括号，先不碰），没有就退回第一个 */
function primaryAddress(addresses: string[]): string {
  for (const a of addresses) {
    if (a.indexOf(':') < 0 && a.length > 0) {
      return a;
    }
  }
  return addresses.length > 0 ? addresses[0] : '';
}

/** `tailnet` 是不是这行的地址之一（容忍 `::ffff:` 这类前缀形态） */
function addressMatches(addresses: string[], tailnet: string): boolean {
  if (tailnet.length === 0) {
    return false;
  }
  for (const a of addresses) {
    // 精确匹配；IPv4-mapped 形态只认 ::ffff: 前缀，不能用裸 endsWith（.55 会误命中 .5）
    if (a === tailnet || a === `::ffff:${tailnet}`) {
      return true;
    }
  }
  return false;
}

/**
 * **功能块：「网络里的电脑」**（客户定的流程：登录网络 → **网络里的电脑** → 会话页）。
 * 页面（`pages/Index.ets`）里只剩一行 `ComputerListView()`。
 *
 * ## 这一页只回答一件事：**有哪些电脑在线**
 *   · 列表 = tailnet peer 列表（内核 `backendPeers`），**只报在线 / 离线**，**一个探测都不发**；
 *   · **进页面读一次网络状态**，之后只有客户点顶栏「刷新」才重扫（客户 2026-10-17：
 *     5 秒自动重扫没必要，去掉；它还会把行内已经写好的「请先启动 dsh」擦回空）；
 *   · 「连接」按钮＝**在线的才能点**；
 *   · **能不能连上 dsh，点下去才知道** —— 点「连接」＝ 真的走一遍「连接电脑上的 dsh」：
 *     `GET /pair/info` 探活 → `POST /pair/claim` 取凭据（只进内存、不落盘）；
 *   · **连上 ⇒ 进会话页**；**连不上 ⇒ 在下面给可读的错误信息**，不改这一行的结论。
 *
 * ## 打哪个地址
 *  · 只打**这台电脑的 tailnet 地址** `row.address:插件端口`（不再走本机网关）；
 *  · 拿到 `/pair/info` 后要**认一认答话的是不是这一行**（插件的 `tailnet` 必须在
 *    这行的地址里）—— 对不上就如实报"连不上这台"，**不冒充连上了**。
 */
@Component
export struct ComputerListView {
  /** 由 EntryAbility 写入的系统状态栏/挖孔高度（vp），换机不写死 */
  @StorageProp('safeTopVp') safeTop: number = 40;
  @State rows: DeviceRow[] = [];
  /** 是否已加入网络（决定底部「加入 Tailscale 网络」要不要出现） */
  @State joined: boolean = false;
  @State hintText: string = '正在查找网络里的电脑…';
  /** 正在连的那台（'' = 没有在连）；连的时候按钮显示"连接中…"并锁住全部按钮 */
  @State connectingName: string = '';
  /** 正在 SSH 拉起 dsh 的那台（地址；'' = 没有在拉） */
  @State startingAddress: string = '';
  /** 正在 SSH 关掉 dsh 的那台（地址；'' = 没有在关）—— 客户 2026-10-21 要的「关闭」 */
  @State stoppingAddress: string = '';
  /** 正在发关机指令的那台（地址；'' = 没有在关机）—— 客户 2026-10-21 追加 */
  @State poweringAddress: string = '';
  /** 需要用户加到电脑上的 SSH 公钥（'' = 不显示这张卡） */
  @State sshPubKey: string = '';
  /** 连不上的可读原因（'' = 没有错误）；**「请先启动 dsh」不写这里**，写进那一行 */
  @State errorText: string = '';
  /** 配置版本号：从配置页回来 / 打开配置页时 +1，用来让"是否已配置"重算（客户 2026-10-21） */
  @State configVersion: number = 0;
  /** 已配置过的电脑地址（决定按钮是「连接」还是「配置」） */
  @State configuredHosts: string[] = [];
  private refreshing: boolean = false;
  /** 行状态的版本号：动作每写一次行 +1，刷新赋值前比对，防止旧快照盖回动作结果 */
  private rowEpoch: number = 0;
  /** 状态事件订阅（登录后隧道起来自动刷新用） */
  private subscribed: boolean = false;
  private unsubscribeStatus: (() => void) | undefined = undefined;
  /** 应用私有目录（读扩展状态文件用；真机内核在扩展进程，只能这样回读） */
  private filesDir: string = '';

  aboutToAppear(): void {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      this.filesDir = ctx.filesDir;
    } catch (ctxError) {
      this.filesDir = '';
    }
    // 进页面读一次；之后靠顶栏「刷新」手动重扫（客户 2026-10-17：不要 5 秒自动重扫）
    this.refresh();
    // 2026-10-20：登录后**立刻进首页**，隧道还在起 —— 扩展每次写状态都通知这里，
    // 一旦 Running 就自动重扫一次，用户不用手点刷新。
    if (!this.subscribed) {
      this.subscribed = true;
      this.unsubscribeStatus = subscribeEvent(EVENT_VPN_STATUS, () => {
        // 首次进页时扩展的 peers 是异步采的：joined 变真之后还会再写一次带 peers 的状态
        // ⇒ 列表还是空的时候也要重扫，否则会一直停在"网络里还没看到别的电脑"
        if (!this.joined || this.rows.length === 0) {
          this.refresh();
        }
      });
    }
  }

  aboutToDisappear(): void {
    if (this.unsubscribeStatus !== undefined) {
      this.unsubscribeStatus();
      this.unsubscribeStatus = undefined;
    }
    this.subscribed = false;
  }

  /** 客户 2026-10-16：**手动刷新网络** —— 点一下立刻重扫一遍网络里的电脑状态 */
  private async manualRefresh(): Promise<void> {
    // 有动作在跑时先不刷新：否则 refresh() 会直接 return，hint 永远停在「正在刷新…」
    if (this.refreshing || this.connectingName.length > 0 ||
      this.startingAddress.length > 0 || this.stoppingAddress.length > 0 ||
      this.poweringAddress.length > 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, '手动刷新网络（客户点的「刷新」）');
    this.errorText = '';
    this.hintText = '正在刷新…';
    // 2026-10-25：刷新要看到"电脑真在不在" —— 先让扩展重采一次 peers，不能只读旧文件
    await this.refreshPeersNow();
    this.refresh();
  }

  /** 让扩展立刻重采一次 peers（最多等 ~2s；拿不到新值就照旧读文件） */
  private async refreshPeersNow(): Promise<void> {
    if (this.filesDir.length === 0) {
      return;
    }
    const beforeStatus = readExtensionStatus(this.filesDir);
    let before: number = 0;
    if (beforeStatus !== undefined && beforeStatus.peersAtMs !== undefined) {
      before = beforeStatus.peersAtMs;
    }
    if (!sendExtensionCommand(this.filesDir, 'refreshPeers')) {
      return;
    }
    for (let i = 0; i < 8; i++) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 250);
      });
      const nowStatus = readExtensionStatus(this.filesDir);
      let now: number = 0;
      if (nowStatus !== undefined && nowStatus.peersAtMs !== undefined) {
        now = nowStatus.peersAtMs;
      }
      if (now > before) {
        return;
      }
    }
  }

  /** 拉一次设备列表（**不探测 dsh** —— 探测发生在点「连接」的时候） */
  private async refresh(): Promise<void> {
    // 启动/关闭/关机进行中就别刷新，否则旧快照会覆盖刚写下的状态（审查 2026-10-22）
    if (this.refreshing || this.connectingName.length > 0 ||
      this.startingAddress.length > 0 || this.stoppingAddress.length > 0 ||
      this.poweringAddress.length > 0) {
      return;
    }
    this.refreshing = true;
    const epoch: number = this.rowEpoch;
    // 每台电脑的配置（没配置过的只给「配置」按钮）
    const ctxForProfiles: common.Context | undefined = this.getUIContext().getHostContext();
    this.syncConfiguredHosts(ctxForProfiles);
    try {
      const st: KernelStatus | undefined = kernelStatus();
      const hasKernel: boolean = st !== undefined && st.backendState === 'Running';
      // 真机：内核在扩展进程 ⇒ 入网状态以扩展状态文件为准
      this.joined = hasKernel || (this.filesDir.length > 0 && extensionRunning(this.filesDir));
      if (!this.joined) {
        // 客户 2026-10-18：**不走本机直连**（本机网关那条）—— 要连电脑先加入 Tailscale 网络
        // 期间用户点过动作就不能清列表（动作结果比这次刷新新）
        if (epoch === this.rowEpoch) {
          this.rows = [];
        }
        this.hintText = '还没加入网络';
        return;
      }
      let peers: PeerInfo[] = await withTimeout<PeerInfo[]>(peersAsync(), 3000, []);
      if (peers.length === 0 && this.filesDir.length > 0) {
        // 真机主路：peers 由扩展采集后写进状态文件
        peers = peersFromExtension(this.filesDir);
      }
      if (peers.length === 0) {
        this.hintText = '网络里还没看到别的电脑';
        if (epoch === this.rowEpoch) {
          this.rows = [];
        }
        return;
      }
      const next: DeviceRow[] = [];
      let onlineCount: number = 0;
      for (const p of peers) {
        const addresses: string[] = p.addresses !== undefined && p.addresses !== null ? p.addresses : [];
        const address: string = primaryAddress(addresses);
        if (p.online) {
          onlineCount++;
        }
        next.push({
          name: shortPeerName(p, address),
          address: address,
          addresses: addresses,
          online: p.online,
          dshReady: false,
          note: p.online ? '在线' : '离线',
          dshNote: p.online ? '检测中…' : '',
          canStart: false
        });
      }
      // tailnet 说"在线"只代表电脑开着；还要那台机器上的插件回话
      for (let i = 0; i < next.length; i++) {
        if (!next[i].online) {
          continue;
        }
        const rowLoaded: DeviceProfile | undefined = ctxForProfiles === undefined
          ? undefined : profileStore.get(ctxForProfiles, next[i].address);
        const rowProfile: DeviceProfile | undefined =
          rowLoaded === undefined || profileProblem(rowLoaded).length > 0 ? undefined : rowLoaded;
        if (rowProfile === undefined) {
          // 没配置过这台：不探 dsh、不探 SSH —— 只给「配置」按钮（客户 2026-10-21）
          next[i].dshNote = '未配置';
          continue;
        }
        // 刚进页面 / 网络刚热起来时第一次探活经常失败：重试一次再判"未启动"，避免显示成假的未启动
        let probed: PairInfoResult = await withTimeout<PairInfoResult>(
          fetchPairInfo(next[i].address, rowProfile.pluginPort), 4000, probeFallback());
        if (!probed.ok) {
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => {
              resolve();
            }, 700);
          });
          probed = await withTimeout<PairInfoResult>(
            fetchPairInfo(next[i].address, rowProfile.pluginPort), 4000, probeFallback());
        }
        if (probed.ok && addressMatches(next[i].addresses, probed.tailnet)) {
          // 插件当前转发的 dsh authority 必须和手机配置里的 dsh 端口一致，否则连进去必 401
          const wantAuthority: string = `127.0.0.1:${rowProfile.dshPort}`;
          if (probed.dshAuthority.length > 0 && probed.dshAuthority !== wantAuthority) {
            next[i].dshNote = 'dsh 端口不对';
          } else {
            next[i].dshReady = true;
            next[i].dshNote = 'dsh已启动';
          }
        } else {
          // 插件没回话（dsh 没起 = 插件跟着没了，或端口暂时不通）：统一按「dsh未启动」显示，
          // 客户口径要的是能直接点「开启」，不要在这里给"状态未知"这种没法操作的说法。
          next[i].dshNote = 'dsh未启动';
        }
      }
      // 「启动 / 关闭」这两个小按钮只给**真的能 SSH 进去**的机器（手机等设备没有 sshd ⇒ 不显示）。
      // 在线就探一次（dsh 已起的机器也要探：它的「关闭」同样要走 SSH），短超时、一次刷新探一次。
      const probes: Promise<boolean>[] = [];
      const probeRows: number[] = [];
      for (let i = 0; i < next.length; i++) {
        if (next[i].online) {
          const raw2: DeviceProfile | undefined = ctxForProfiles === undefined
            ? undefined : profileStore.get(ctxForProfiles, next[i].address);
          const p: DeviceProfile | undefined =
            raw2 === undefined || profileProblem(raw2).length > 0 ? undefined : raw2;
          if (p === undefined) {
            continue;
          }
          probeRows.push(i);
          probes.push(tcpOpen(next[i].address, p.sshPort));
        }
      }
      if (probes.length > 0) {
        const results: boolean[] = await Promise.all(probes);
        for (let k = 0; k < probeRows.length; k++) {
          next[probeRows[k]].canStart = results[k];
          hilog.info(DOMAIN, TAG, 'ssh 探活 %{public}s｜%{public}s', next[probeRows[k]].name,
            results[k] ? 'SSH 口开着（可启停）' : 'SSH 口不通（不给启停按钮）');
        }
      }
      // 探测期间用户点了动作（哪怕动作已完成并清了进行中字段）⇒ 旧快照不能盖回去
      if (this.connectingName.length > 0 || this.startingAddress.length > 0 ||
        this.stoppingAddress.length > 0 || this.poweringAddress.length > 0 || epoch !== this.rowEpoch) {
        this.hintText = '';
        return;
      }
      this.rows = next;
      // 客户 2026-10-17：不要那行数量说明
      this.hintText = '';
    } catch (error) {
      this.hintText = '查找出错，稍后自动重试';
      hilog.error(DOMAIN, TAG, '刷新设备列表异常');
    } finally {
      this.refreshing = false;
    }
  }

  /**
   * 点「连接」：**真的连一次**（配对口探活 → 取凭据），连上就进会话页，连不上就把原因写在下面。
   * 凭据只进内存（`pairingVault`），**不落盘**；日志与界面**只出现长度与 authority**。
   */
  /** 把这台电脑的 dsh 没起写进**那一行**的状态里（客户 2026-10-17：不要写在页面底部） */
  private markRowNeedsDsh(row: DeviceRow): void {
    this.rowEpoch = this.rowEpoch + 1;
    const next: DeviceRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const one: DeviceRow = this.rows[i];
      if (one.address === row.address) {
        next.push({
          name: one.name, address: one.address, addresses: one.addresses,
          online: one.online, dshReady: false, note: one.note, dshNote: 'dsh未启动',
          canStart: one.canStart
        });
      } else {
        next.push(one);
      }
    }
    this.rows = next;
    this.errorText = '';
  }

  /** 入网判据：本进程内核**或** 扩展状态文件（真机内核在扩展进程里） */
  private joinedNow(): boolean {
    const st: KernelStatus | undefined = kernelStatus();
    if (st !== undefined && st.backendState === 'Running') {
      return true;
    }
    // 2026-10-19：真机上本进程的 NAPI 是**另一个空内核**（契约 §0.1 不变量 1），
    // 只看它会永远 NoState ⇒ 点「连接」直接弹"请先加入网络"（云真机实测）。
    return this.filesDir.length > 0 && extensionRunning(this.filesDir);
  }

  private async connect(row: DeviceRow): Promise<void> {
    if (this.connectingName.length > 0 || this.startingAddress.length > 0 ||
      this.stoppingAddress.length > 0 || this.poweringAddress.length > 0) {
      return;
    }
    this.errorText = '';
    this.connectingName = row.name;
    try {
      // 客户 2026-10-18：**没入网就直接说"请先加入网络"** —— 不去探电脑，更别说成"没启动 dsh"
      if (!this.joinedNow()) {
        this.errorText = '请先加入网络';
        hilog.warn(DOMAIN, TAG, '连接 %{public}s｜未入网', row.name);
        return;
      }
      const pluginHost: string = row.address;
      // 每台电脑的连接配置（客户 2026-10-21）：没配置过就先去配置页，不给连
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      const loaded: DeviceProfile | undefined = ctx === undefined ? undefined : profileStore.get(ctx, pluginHost);
      // 端口为 0 / 字段不全的旧配置，等同"没配置" —— 否则会向 :0 发请求，只显示"dsh未启动"（审查 2026-10-22）
      const profile: DeviceProfile | undefined = loaded === undefined || profileProblem(loaded).length > 0
        ? undefined : loaded;
      if (profile === undefined) {
        this.connectingName = '';
        this.openConfig(row);
        return;
      }
      setActiveProfile(profile);
      const pluginPort: number = profile.pluginPort;
      const info: PairInfoResult = await fetchPairInfo(pluginHost, pluginPort);
      hilog.info(DOMAIN, TAG, '连接 %{public}s｜配对口 %{public}s:%{public}d', row.name,
        pluginHost, pluginPort);
      if (!info.ok) {
        // **按需诊断** —— 探不通时先分清是"网络断了"还是"电脑上的 dsh 没开"（客户 2026-10-18）
        if (info.status === 0) {
          const stillJoined: boolean = this.joinedNow();
          if (!stillJoined) {
            this.errorText = '请先加入网络';
            hilog.warn(DOMAIN, TAG, '连接 %{public}s｜内核已不在运行', row.name);
            return;
          }
          let peers: PeerInfo[] = await withTimeout<PeerInfo[]>(peersAsync(), 3000, []);
          if (peers.length === 0 && this.filesDir.length > 0) {
            // 真机的内在本进程没有内核 ⇒ 用扩展写下的 peers 判在线（审查 2026-10-22）
            peers = peersFromExtension(this.filesDir);
          }
          let online: boolean = false;
          for (let i = 0; i < peers.length; i++) {
            if (addressMatches(row.addresses, peers[i].name) ||
              addressMatches(row.addresses, primaryAddress(peers[i].addresses))) {
              online = peers[i].online;
              break;
            }
          }
          if (!online) {
            // 判不出来就**别赖网络**：明确说"这台电脑/配对口没回应"（审查 2026-10-22）
            this.errorText = '这台电脑没回应（检查插件端口，或电脑上的 dsh 没起）';
            hilog.warn(DOMAIN, TAG, '连接 %{public}s｜tailnet 里这台不在线', row.name);
            return;
          }
          this.markRowNeedsDsh(row);
        } else {
          this.errorText = humanPairError(info.status);
        }
        hilog.warn(DOMAIN, TAG, '连接失败（探活）：%{public}s', info.message);
        return;
      }

      // 配对口答话的必须就是这一行对应的那台机器（tailnet 对不上 ⇒ 这个端口可能给了别的电脑）
      if (!addressMatches(row.addresses, info.tailnet)) {
        this.errorText = '连到的不是这台电脑（配对口 tailnet 对不上）';
        hilog.warn(DOMAIN, TAG, '连接 %{public}s｜配对口 tailnet=%{public}s 与本行不符',
          row.name, info.tailnet);
        return;
      }
      // 电脑侧 dsh 端口和手机配置不一致：claim 会用电脑当前 authority，但后续 Host 还是旧端口 ⇒ 401
      const wantedAuthority: string = `127.0.0.1:${profile.dshPort}`;
      if (info.dshAuthority.length > 0 && info.dshAuthority !== wantedAuthority) {
        this.errorText = `电脑那边的 dsh 端口是 ${info.dshAuthority}，请改配置`;
        this.connectingName = '';
        this.openConfig(row);
        return;
      }

      // 客户 2026-10-18：**手里的凭据还有效就直接用** —— 不再每点一次都去 claim；
      // 顺带避开插件的"同来源 10 秒一次"限速（连接期间按钮本来就被锁住，用户不该看到这个限制）。
      // 2026-10-22：端口是可配置的 —— 配置里换了端口就必须作废旧凭据，否则会拿旧端口的 cookie 打新端口。
      // 凭据是**绑 authority** 的：插件端口或 dsh 端口只要有一个变了，就必须重新 claim。
      const wantAuthority: string = `127.0.0.1:${profile.dshPort}`;
      if (pairingVault.has() && (pairingVault.portOr(0) !== pluginPort ||
        pairingVault.authorityOr('') !== wantAuthority)) {
        hilog.info(DOMAIN, TAG, '连接 %{public}s｜端口/authority 变了，旧凭据作废', row.name);
        pairingVault.clear();
      }
      const reused: boolean = pairingVault.has() && !pairingVault.needsRenewal(Date.now()) &&
        pairingVault.hostOr('') === pluginHost;
      if (reused) {
        hilog.info(DOMAIN, TAG, '连接 %{public}s｜复用尚未过期的凭据（长度 %{public}d）', row.name,
          pairingVault.length());
      } else {
        let claim: PairClaimResult =
          await claimCredential(pluginHost, pluginPort, info.phoneAuthority, profile.name, '');
        if (!claim.ok && claim.status === 429) {
          // 插件按来源限速：同来源 10s 内只铸一次（夹在插件里的冷却常量），等 1.2s 重试必然还是 429
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => {
              resolve();
            }, 10500);
          });
          claim = await claimCredential(pluginHost, pluginPort, info.phoneAuthority, profile.name, '');
        }
        if (!claim.ok) {
          this.errorText = humanPairError(claim.status);
          hilog.warn(DOMAIN, TAG, '连接失败（取凭据）：%{public}s', claim.message);
          return;
        }
        // 凭据入内存单例（下一屏共用同一份）；**只记长度**
        pairingVault.set(claim.cookieName, claim.cookieValue, claim.expiresAtMs, claim.authority,
          pluginHost, pluginPort);
        hilog.info(DOMAIN, TAG, '已连接 %{public}s（凭据长度 %{public}d，有效期至 %{public}s）', row.name,
          pairingVault.length(), expiryText(claim.expiresAtMs));
      }

      // 客户 2026-10-18：进会话前真去敲一次 dsh —— 光探配对口不够（那条 keep-alive 连接断网后还能答一次，会"假成功"）。
      const probeClient: DshApiClient = new DshApiClient(pluginTarget(pluginHost));
      probeClient.setCookie(pairingVault.get());
      const alive: DshApiResult = await probeClient.rpc('session/list', '{"_request":{}}');
      if (!alive.ok) {
        // 探测失败**不直接拦**：不同部署下这条路可能因代理/围栏差异误报（客户 2026-10-18 真机实测：入网正常也报"网络已断"）。
        // 只在**内核也说没入网**时才判定为网络问题；否则放行，会话页会自己显示「dsh 已断开」状态。
        const stillJoined: boolean = this.joinedNow();
        if (!stillJoined) {
          this.errorText = '请先加入网络';
          return;
        }
      }
      router.pushUrl({ url: 'pages/Conversation' }).catch((err: BusinessError) => {
        this.errorText = `连上了，但打不开会话页：${err.message}（code=${err.code ?? -1}）`;
        hilog.error(DOMAIN, TAG, '进会话页失败 code=%{public}d', err.code ?? -1);
      });
    } catch (error) {
      const e = error as BusinessError;
      this.errorText = `连不上这台电脑：${e.message}（code=${e.code ?? -1}）`;
      hilog.error(DOMAIN, TAG, '连接异常：%{public}s', `${e.message}`);
    } finally {
      this.connectingName = '';
    }
  }

  /**
   * 点「启动」：**SSH 到这台电脑**跑那条固定命令，把 dsh 拉起来（客户 2026-10-20 需求）。
   *
   * 口径：
   *  · 电脑上**不放任何东西**（不装常驻服务），只用它已有的 sshd（SSH 端口）；
   *  · 公钥身份在手机侧生成（`SshKeys`），首次需要把这行公钥加到电脑（失败时界面上给出来）；
   *  · 回执三态 `ALREADY / READY / FAILED` 由电脑上的脚本自己判（它测 dsh 端口 端口），
   *    手机侧**不重复探测**，避免两个事实源打架；
   *  · 起来之后再刷新这一行（复探配对口）⇒ 状态变「dsh 可用」，用户可以直接点连接。
   */
  private async startDsh(row: DeviceRow): Promise<void> {
    if (this.startingAddress.length > 0 || this.stoppingAddress.length > 0 || this.connectingName.length > 0) {
      return;
    }
    this.errorText = '';
    this.startingAddress = row.address;
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const profile: DeviceProfile | undefined = profileStore.get(ctx, row.address);
      if (profile === undefined) {
        this.startingAddress = '';
        this.openConfig(row);
        return;
      }
      setActiveProfile(profile);
      const usedHost: string = row.address;
      this.setRowDshNote(row, '正在启动 dsh…');
      const outcome: StartOutcome = await dshStarter.ensureDsh(ctx, row.address, profile);
      hilog.info(DOMAIN, TAG, '启动 dsh %{public}s｜%{public}s（%{public}s）', row.name,
        `${outcome.state}`, outcome.message);
      if (outcome.state === StartState.ERROR) {
        if (outcome.message.indexOf('公钥') >= 0) {
          this.sshPubKey = outcome.publicKey;
        }
        // 行内只说结果（按钮位置固定），详细原因放页面底部
        this.errorText = outcome.message;
        this.setRowCanStart(row, outcome.message.indexOf('连不上') < 0);
        this.setRowDshNote(row, '启动失败');
        return;
      }
      if (outcome.state === StartState.FAILED) {
        // dsh 端口没起来 / 电脑上没有配这个端口的实例 —— 电脑侧脚本已经把这两种分开了
        this.errorText = outcome.message;
        this.setRowCanStart(row, true);
        this.setRowDshNote(row, '启动失败');
        return;
      }
      // dsh 端口已经通了（ALREADY / READY）：再看插件口 —— 手机能连到 dsh 的唯一入口
      this.setRowDshNote(row, '正在检查插件端口…');
      const probe: PairInfoResult = await fetchPairInfo(usedHost, profile.pluginPort);
      if (!probe.ok) {
        this.errorText = probe.status === 0
          ? `插件端口 ${profile.pluginPort} 不通`
          : humanPairError(probe.status);
        this.setRowCanStart(row, true);
        this.setRowDshNote(row, '插件端口不通');
        return;
      }
      this.setRowReady(row, true);
      // 插件口确认可用之后，才让电脑打开已登录的 dsh 网页（客户 2026-10-22）
      openDesktopPage(row.address, profile.pluginPort);
    } catch (error) {
      const e = error as BusinessError;
      this.errorText = `启动失败：${e.message}（code=${e.code ?? -1}）`;
      hilog.error(DOMAIN, TAG, '启动 dsh 异常：%{public}s', `${e.message}`);
    } finally {
      this.startingAddress = '';
    }
  }

  /**
   * 点「关闭」：SSH 到这台电脑跑 `stop-command.ps1`，把 dsh 收掉（客户 2026-10-21）。
   *
   * 口径与「启动」对称：
   *  · 电脑侧只杀**监听 dsh 端口 的那个进程**，不按名字杀、不停计划任务（停任务收不掉已起的 node）；
   *  · 回执 `STOPPED / ALREADY_STOPPED / FAILED` 由电脑上的脚本判，手机侧不重复探端口；
   *  · 关掉之后这一行回到「请先启动 dsh」，同时「启动」小按钮出现（同一行可再拉起来）。
   */
  private async stopDsh(row: DeviceRow): Promise<void> {
    if (this.startingAddress.length > 0 || this.stoppingAddress.length > 0 || this.connectingName.length > 0) {
      return;
    }
    this.errorText = '';
    this.stoppingAddress = row.address;
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const profile: DeviceProfile | undefined = profileStore.get(ctx, row.address);
      if (profile === undefined) {
        this.stoppingAddress = '';
        this.openConfig(row);
        return;
      }
      setActiveProfile(profile);
      const outcome: StopOutcome = await dshStarter.stopDsh(ctx, row.address, profile);
      hilog.info(DOMAIN, TAG, '关闭 dsh %{public}s｜%{public}s（%{public}s）', row.name,
        `${outcome.state}`, outcome.message);
      if (outcome.state === StopState.ERROR || outcome.state === StopState.FAILED) {
        // 行内只说结果；详细原因放页面底部
        this.errorText = outcome.message;
        this.setRowCanStart(row, outcome.message.indexOf('连不上') < 0);
        this.setRowDshNote(row, '关闭失败');
        return;
      }
      // 关掉了（或本来就没跑）：这一行回到「请先启动 dsh」
      this.setRowStopped(row);
    } catch (error) {
      const e = error as BusinessError;
      this.errorText = `关闭失败：${e.message}（code=${e.code ?? -1}）`;
      hilog.error(DOMAIN, TAG, '关闭 dsh 异常：%{public}s', `${e.message}`);
    } finally {
      this.stoppingAddress = '';
    }
  }

  /**
   * 点「关机」：SSH 到这台电脑跑 `power-command.ps1`，让它**真的断电**（客户 2026-10-21）。
   *
   * 三条口径：
   *  · **先问一句** —— 关机会断掉电脑上所有会话（包括 dsh 本身），误点代价大；
   *  · 电脑侧脚本**延迟 10 秒**再关：这条 SSH 连接就是那个命令拉起来的，立刻关会连回执都发不回来；
   *  · 手机只认回执 `SHUTTING_DOWN`，**不假装它已经关了**（tailnet 里掉线要等几秒才看得到）。
   */
  private powerOff(row: DeviceRow): void {
    if (this.startingAddress.length > 0 || this.stoppingAddress.length > 0 ||
      this.poweringAddress.length > 0 || this.connectingName.length > 0) {
      return;
    }
    AlertDialog.show({
      title: '关机',
      // 客户 2026-10-21：别写那么多话，就一句「是否确定关机？」
      message: '是否确定关机？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '关机',
        fontColor: '#B3261E',
        action: () => {
          this.doPowerOff(row);
        }
      }
    });
  }

  private async doPowerOff(row: DeviceRow): Promise<void> {
    this.errorText = '';
    this.poweringAddress = row.address;
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const profile: DeviceProfile | undefined = profileStore.get(ctx, row.address);
      if (profile === undefined) {
        this.poweringAddress = '';
        this.openConfig(row);
        return;
      }
      setActiveProfile(profile);
      const outcome: PowerOutcome = await dshStarter.powerOff(ctx, row.address, profile);
      hilog.info(DOMAIN, TAG, '关机 %{public}s｜%{public}s（%{public}s）', row.name,
        `${outcome.state}`, outcome.message);
      this.setRowDshNote(row, outcome.state === PowerState.SHUTTING_DOWN ? '正在关机…' : '关机失败');
      if (outcome.state !== PowerState.SHUTTING_DOWN) {
        this.errorText = outcome.message;
      }
      if (outcome.state === PowerState.SHUTTING_DOWN) {
        // 请求已排上（10s 后断电）：自己盯着这台电脑什么时候不响应，别等 tailnet 的 peer 快照
        this.watchPowerOff(row, profile.sshPort);
      }
    } catch (error) {
      const e = error as BusinessError;
      this.errorText = `关机失败：${e.message}（code=${e.code ?? -1}）`;
      hilog.error(DOMAIN, TAG, '关机异常：%{public}s', `${e.message}`);
    } finally {
      this.poweringAddress = '';
    }
  }

  /**
   * 关机后主动检测（客户 2026-10-25）：
   * 关机脚本只排了 10s 倒计时；tailnet 的 peer 快照要等扩展下次采集才变离线。
   * 所以这里自己探这台电脑的 SSH 口：探不通就立刻把这一行改成「离线 / dsh未启动」。
   */
  private async watchPowerOff(row: DeviceRow, sshPort: number): Promise<void> {
    for (let i = 0; i < 40; i++) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 3000);
      });
      const alive: boolean = await tcpOpen(row.address, sshPort, 2000);
      if (!alive) {
        this.setRowOffline(row);
        return;
      }
    }
    this.setRowDshNote(row, '关机命令已发出，但电脑还有响应');
  }

  /** 改成「离线 + dsh未启动」（关机确认后 / 主动探测不到时用） */
  private setRowOffline(row: DeviceRow): void {
    this.rowEpoch = this.rowEpoch + 1;
    const next: DeviceRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const one: DeviceRow = this.rows[i];
      if (one.address === row.address) {
        next.push({
          name: one.name, address: one.address, addresses: one.addresses,
          online: false, dshReady: false, note: '离线', dshNote: '',
          canStart: false
        });
      } else {
        next.push(one);
      }
    }
    this.rows = next;
  }

  /** 把一行改成「dsh 没在跑」（关闭成功后用；canStart 保持，方便再点启动） */
  private setRowStopped(row: DeviceRow): void {
    this.rowEpoch = this.rowEpoch + 1;
    const next: DeviceRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const one: DeviceRow = this.rows[i];
      if (one.address === row.address) {
        next.push({
          name: one.name, address: one.address, addresses: one.addresses,
          online: one.online, dshReady: false, note: one.note, dshNote: 'dsh未启动',
          canStart: one.canStart
        });
      } else {
        next.push(one);
      }
    }
    this.rows = next;
  }

  /** 改某一行的「能不能启动」（决定「启动」按钮出不出现） */
  /** 这台电脑有没有配置过（没配置 ⇒ 只给「配置」按钮，客户 2026-10-21） */
  private configured(row: DeviceRow): boolean {
    return this.configuredHosts.indexOf(row.address) >= 0;
  }

  /** 把"哪些电脑已经配置过"同步进状态（配置页保存/回来后都要重算） */
  private syncConfiguredHosts(ctx: common.Context | undefined): void {
    if (ctx === undefined) {
      this.configuredHosts = [];
      return;
    }
    const all: Record<string, DeviceProfile> = profileStore.loadAll(ctx);
    this.configuredHosts = Object.keys(all);
  }

  /** 进配置页（连/启停/关机 都要求先配置） */
  private openConfig(row: DeviceRow): void {
    this.configVersion = this.configVersion + 1;
    router.pushUrl({
      url: 'pages/DeviceConfig',
      params: { host: row.address, label: row.name }
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, '打开配置页失败 code=%{public}d', err.code ?? -1);
    });
  }

  /** 页面重新可见（由 `pages/Index` 的 onPageShow 通过 `pageTick` 传进来）：重算按钮并刷新 */
  @Prop @Watch('onPageTickChanged') pageTick: number = 0;

  onPageTickChanged(): void {
    this.configVersion = this.configVersion + 1;
    this.syncConfiguredHosts(this.getUIContext().getHostContext());
    this.refresh();
  }

  private setRowCanStart(row: DeviceRow, can: boolean): void {
    this.rowEpoch = this.rowEpoch + 1;
    const next: DeviceRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const one: DeviceRow = this.rows[i];
      if (one.address === row.address) {
        next.push({
          name: one.name, address: one.address, addresses: one.addresses,
          online: one.online, dshReady: one.dshReady, note: one.note, dshNote: one.dshNote,
          canStart: can
        });
      } else {
        next.push(one);
      }
    }
    this.rows = next;
  }

  /** 改某一行的 dsh 状态说明（不改别的行） */
  private setRowDshNote(row: DeviceRow, note: string): void {
    this.rowEpoch = this.rowEpoch + 1;
    const next: DeviceRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const one: DeviceRow = this.rows[i];
      if (one.address === row.address) {
        next.push({
          name: one.name, address: one.address, addresses: one.addresses,
          online: one.online, dshReady: one.dshReady, note: one.note, dshNote: note,
          canStart: one.canStart
        });
      } else {
        next.push(one);
      }
    }
    this.rows = next;
  }

  /** 改某一行的 dsh 可用状态 */
  private setRowReady(row: DeviceRow, ready: boolean): void {
    this.rowEpoch = this.rowEpoch + 1;
    const next: DeviceRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const one: DeviceRow = this.rows[i];
      if (one.address === row.address) {
        next.push({
          name: one.name, address: one.address, addresses: one.addresses,
          online: one.online, dshReady: ready, note: one.note,
          dshNote: ready ? 'dsh已启动' : one.dshNote,
          canStart: one.canStart
        });
      } else {
        next.push(one);
      }
    }
    this.rows = next;
  }

  /** 复制公钥（用户去电脑上加一次） */
  private copyPubKey(): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.sshPubKey);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      hilog.info(DOMAIN, TAG, 'SSH 公钥已复制');
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '复制公钥失败 code=%{public}d', e.code ?? -1);
    });
  }

  build() {
    Column() {
      // ── 顶栏：标题 ＋「刷新」（无底色图标，和会话页顶栏同一套视觉）──
      Row({ space: 8 }) {
        Text('可用电脑')
          .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#2A1C14').layoutWeight(1)
        Text('⟳')
          .id('net-refresh')
          .fontSize(22)
          .fontColor('#2A1C14')
          .textAlign(TextAlign.Center)
          .width(48)
          .height(48)
          .enabled(this.connectingName.length === 0)
          .onClick(() => {
            this.manualRefresh();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.hintText)
        .fontSize(13).fontColor('#8C6F5A').width('100%')

      // ── 设备列表：一行一台，**名字 ＋ 在线/离线 ＋ 连接** ──
      List({ space: 12 }) {
        ForEach(this.rows, (row: DeviceRow) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Text(row.name)
                  .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#2A1C14').width('100%')
                Row({ space: 18 }) {
                  // ① **电脑状态**：`在线 [关机]`（开机不做：电脑关机时 SSH 本来就不通，
                  //    手机没法把它唤醒；客户 2026-10-25 定只保留关机）
                  Row({ space: 4 }) {
                    Text(row.note)
                      .fontSize(12)
                      .fontColor(row.online ? '#2C7A5E' : '#8C6F5A')
                    if (row.online && row.canStart) {
                      Text(this.poweringAddress === row.address ? '关机中…' : '关机')
                        .fontSize(12)
                        .fontColor('#8C6F5A')
                        .textAlign(TextAlign.Center)
                        .height(24)
                        .padding({ left: 10, right: 10 })
                        .backgroundColor('#ffffff')
                        .borderWidth(1)
                        .borderColor('#EAD9C8')
                        .borderRadius(20)
                        .opacity(this.poweringAddress.length === 0 && row.canStart ? 1 : 0.4)
                        .onClick(() => {
                          if (this.poweringAddress.length === 0) {
                            this.powerOff(row);
                          }
                        })
                    }
                  }
                  .alignItems(VerticalAlign.Center)
                  // ② **dsh 状态**：`dsh已启动 [关闭]` / `dsh未启动 [开启]`（与电脑状态隔开；按钮紧跟状态）
                  //    离线时 dshNote 为空、按钮条件都不满足 ⇒ 这一组自然不显示（客户 2026-10-25）
                  Row({ space: 4 }) {
                    if (row.dshNote.length > 0) {
                      Text(row.dshNote)
                        .fontSize(12)
                        .fontColor(row.dshReady ? '#2C7A5E' : '#B3261E')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: 170 })
                    }
                    if (row.online && row.dshReady && row.canStart) {
                      Text(this.stoppingAddress === row.address ? '关闭中…' : '关闭')
                        .fontSize(12)
                        .fontColor('#8C6F5A')
                        .textAlign(TextAlign.Center)
                        .height(24)
                        .padding({ left: 10, right: 10 })
                        .backgroundColor('#ffffff')
                        .borderWidth(1)
                        .borderColor('#EAD9C8')
                        .borderRadius(20)
                        .opacity(this.stoppingAddress.length === 0 && this.startingAddress.length === 0 &&
                          this.connectingName.length === 0 ? 1 : 0.4)
                        .onClick(() => {
                          if (this.stoppingAddress.length === 0 && this.startingAddress.length === 0 &&
                            this.connectingName.length === 0) {
                            this.stopDsh(row);
                          }
                        })
                    }
                    if (row.online && !row.dshReady && row.canStart && this.configured(row)) {
                      Text(this.startingAddress === row.address ? '启动中…' : '开启')
                        .fontSize(12)
                        .fontColor('#8C6F5A')
                        .textAlign(TextAlign.Center)
                        .height(24)
                        .padding({ left: 10, right: 10 })
                        .backgroundColor('#ffffff')
                        .borderWidth(1)
                        .borderColor('#EAD9C8')
                        .borderRadius(20)
                        .opacity(this.startingAddress.length === 0 && this.stoppingAddress.length === 0 &&
                          this.connectingName.length === 0 ? 1 : 0.4)
                        .onClick(() => {
                          if (this.startingAddress.length === 0 && this.stoppingAddress.length === 0 &&
                            this.connectingName.length === 0) {
                            this.startDsh(row);
                          }
                        })
                    }
                  }
                  .alignItems(VerticalAlign.Center)
                }
                .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              // 在线但 dsh 没起 ⇒ 给一个「启动」（客户 2026-10-20）
              // 只给 **SSH 端口探测通过** 的机器（客户 2026-10-21：手机等设备不该出现「启动」）
              // ⚠️ 2026-10-21 客户口径：**放在「请先启动 dsh」后面当小按钮**，不要和「连接」并排 ——
              //    所以这里不再渲染任何按钮，见上方状态行里那个。

              // 客户 2026-10-21：**这台电脑没配置过 ⇒ 不给「连接」，只给「配置」**
              Button(!this.configured(row) ? '配置'
                : (this.connectingName === row.name ? '连接中…' : '连接'))
                .fontSize(15)
                .constraintSize({ minHeight: 38 })
                .maxFontScale(1.6)
                .backgroundColor(this.configured(row) ? (row.online ? '#E0622A' : '#D9C6B6') : '#F1E8DF')
                .fontColor(this.configured(row) ? '#ffffff' : '#3f4956')
                .borderRadius(19)
                .padding({ left: 18, right: 18 })
                .enabled(row.online && this.connectingName.length === 0)
                .onClick(() => {
                  if (this.configured(row)) {
                    this.connect(row);
                  } else {
                    this.openConfig(row);
                  }
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(20)
            .shadow({ radius: 18, color: '#14A9744F', offsetY: 6 })
          }
        }, (row: DeviceRow) =>
          `${row.name}-${row.address}-${row.dshReady}-${row.dshNote}-${row.canStart}-${this.configured(row) ? 'c' : 'n'}`)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ top: 12 })

      // 客户 2026-10-20：这一页不要再出现「加入 Tailscale 网络」按钮（入网是登录页的事）

      // ── 首次用「启动」时：电脑还不认识本机，把公钥摆出来让用户加一次 ──
      if (this.sshPubKey.length > 0) {
        Column({ space: 6 }) {
          Text('这台电脑还不认识本机。把下面这行加到电脑的 SSH 授权文件里（一次就够）：')
            .fontSize(12).fontColor('#8C6F5A').width('100%')
          Text(this.sshPubKey)
            .fontSize(11).fontColor('#2A1C14').width('100%')
            .copyOption(CopyOptions.LocalDevice)
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Button('复制公钥')
              .fontSize(13).constraintSize({ minHeight: 32 })
              .backgroundColor('#eef3ff').fontColor('#E0622A').borderRadius(16)
              .onClick(() => {
                this.copyPubKey();
              })
            Blank()
            Text('收起')
              .fontSize(12).fontColor('#8C6F5A').padding(8)
              .onClick(() => {
                this.sshPubKey = '';
              })
          }.width('100%')
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#f7f8fa')
        .borderRadius(10)
        .margin({ bottom: 8 })
      }

      // ── 连不上的原因（有错才出现；人话，不给开发者黑话）──
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(13).fontColor('#B3261E').width('100%').textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 28 })
      } else {
        Text('')
          .height(28)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: 4 })
    .backgroundColor(Color.Transparent)
  }
}








