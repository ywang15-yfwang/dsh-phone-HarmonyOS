import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { Want, bundleManager, common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resolveDeviceName } from '../model/DeviceProfile';
import { fileIo } from '@kit.CoreFileKit';
import { VpnExtensionStatus } from '../model/VpnTypes';
import { EVENT_VPN_COMMAND, subscribeEvent } from '../features/f01-tailnet/VpnBus';
import {
  writeExtensionStatus
} from '../features/f01-tailnet/VpnStatusStore';
import {
  COMMAND_TTL_MS, VpnCommand, VpnCommandResponse, readCommand, writeResponse
} from '../features/f01-tailnet/VpnChannel';
import { AuthUrlResult, KernelStatus, authUrlResult, firstAddress, kernelStatus, logoutBackendRaw, restartWithTunRaw, startBackendRaw, stopBackendRaw, tunFdProbe, peersAsync, PeerInfo} from '../features/f01-tailnet/KernelBridge';
import { getControlUrl } from '../services/GlobalSettings';
import { EXT_PHASE_FAILED, EXT_PHASE_RUNNING, phaseFromBackendState } from '../features/f01-tailnet/VpnStateMachine';

const DOMAIN: number = 0xD001;
const TAG: string = 'T4EXT';
/** 上次入网后内核报的本机 tailnet 地址（客户：不删机器就不会变） */
const TAILNET_ADDRESS_FILE: string = 'tailnet-address.txt';
/** 系统同时只允许一个 VPN；槽位被占时 create 返回这个码（契约 §6） */
const VPN_EXISTS_ERROR_CODE: number = 2203002;
const STATUS_POLL_FAST_MS: number = 1000;
const STATUS_POLL_SLOW_MS: number = 5000;
/** b 条：一次同步状态查询超过这个耗时 ⇒ 自适应降频 */
const STATUS_COST_DOWNGRADE_MS: number = 1000;
const AUTH_POLL_MS: number = 2000;
/** 入网后状态心跳间隔（App 用它判"扩展还活着"，70s 窗口） */
const RUNNING_HEARTBEAT_MS: number = 30000;

function selfBundleName(): string {
  try {
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return info.name;
  } catch (error) {
    // 取不到就回空串（不写死包名：客户 2026-10-21）
    return '';
  }
}

/**
 * T4：真实的 VPN 扩展 —— 两阶段 VpnConfig + 唯一 VPN 槽位冲突替换 + tunFd 交接 + 状态回读。
 * 进程分工：tun 与 Go 内核都在**本扩展进程**；UI 进程经 `vpn-extension-status.json`（回读）
 * 与 `vpn-command.json`（命令，seq/issuedAtMs）交换。
 * 注意：**本文件的一切"能不能跑"结论均须在真机验证后才成立**。
 */
export default class DshVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  private tunFd: number = -1;
  private seq: number = 0;
  private phase: string = 'creating-tun';
  private address: string = '';
  private backendState: string = '';
  /** F15：peer 段（**只有扩展进程采得到**；UI 从状态文件读）。`''` = 本 tick 没采。 */
  private peersJson: string = '';
  private peersAtMs: number = 0;
  /** 防止 peer 采集重叠（`peers()` 是 3 s 超时的同步调用 ⇒ 用异步变体 + 单飞）。 */
  private peersInFlight: boolean = false;
  private authUrl: string = '';
  private authUrlReady: boolean = false;
  private errorCode: number = 0;
  private detail: string = '';
  private kernelError: string = '';
  private kernelJson: string = '';
  private rebuilt: boolean = false;
  private destroying: boolean = false;
  private authPolling: boolean = false;
  /** 上一次取授权链接的结果（只在变化时打日志，免得 2 秒一条刷屏） */
  private lastAuthState: string = '';
  /** 最近一次 `backendRestartWithTun` 的原始返回（内核 NoState 时给用户看原因） */
  private lastHandOffRaw: string = '';
  /** 连续 NoState 的次数（超过阈值判"内核没起来"） */
  private noStateStreak: number = 0;
  /**
   * 本次 tun 用的本机 tailnet 地址（'' = 还是 probe tun）。
   * 教训（2026-10-19 云真机）：**内核 Running 时再 `backendRestartWithTun` 会卡成 NoState**
   * （restartWithTun 先 Close 旧 server 再起新的，旧 server 的关闭把新的一代顶掉），
   * 但**从 NoState/Stopped 起步是好的**。⇒ 有上次的地址就**一次建真 tun**，不再两阶段重建。
   */
  private tunAddress: string = '';
  /** 真 tun 建好并交接内核的进行中标志（pollStatusOnce 每 3s 一次，防重入） */
  private handoffInFlight: boolean = false;
  /** 只在状态串变化时打 error/lastLog，避免 3 秒一条刷屏 */
  private lastKernelDiag: string = '';
  private statusBusy: boolean = false;
  private lastStatusCostMs: number = 0;
  private statusPollIntervalMs: number = STATUS_POLL_FAST_MS;
  private unavailableStreak: number = 0;
  private unavailableSinceMs: number = 0;
  private lastConsumedSeq: number = 0;
  private statusTimer: number = -1;
  private authTimer: number = -1;
  /** 入网后的状态心跳（30s 一次，只写状态文件，不查内核） */
  private heartbeatTimer: number = -1;
  /** 命令订阅的退订函数（客户 2026-10-18：不再 1s 轮询命令文件） */
  private unsubscribeCommand: (() => void) | undefined = undefined;

  onCreate(want: Want): void {
    this.log('onCreate：扩展进程已拉起');
    this.publish('kernel-starting', 0, 'onCreate：先起 userspace 内核（不带 tun）拿 tailnet 地址');
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    } catch (error) {
      const e = error as BusinessError;
      this.publish(EXT_PHASE_FAILED, e.code ?? -1, `createVpnConnection 失败：${e.message}`);
      return;
    }
    this.startCommandWatcher();
    // 2026-10-20：**上次的 tailnet 地址存盘**（客户：不删机器就不会变）⇒ 直接带真 tun 起一次内核，
    // 省掉"先 userspace 拿地址、再 restart"里的第二次控制平面连接（约 1–2 秒）。
    const cached: string = this.readCachedAddress();
    if (cached.length > 0) {
      this.log(`沿用已存 tailnet 地址 ${cached} ⇒ 直接建真 tun（省一次控制平面连接）`);
      this.startWithCachedAddress(cached);
    } else {
      this.startUserspaceBackend();
    }
  }

  /** 已存的本机 tailnet 地址（扩展私有文件，一行 IPv4） */
  private readCachedAddress(): string {
    try {
      const path: string = `${this.context.filesDir}/${TAILNET_ADDRESS_FILE}`;
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const text: string = fileIo.readTextSync(path).trim();
      return /^\d{1,3}(\.\d{1,3}){3}$/.test(text) ? text : '';
    } catch (error) {
      return '';
    }
  }

  private writeCachedAddress(address: string): void {
    if (address.length === 0) {
      return;
    }
    try {
      const path: string = `${this.context.filesDir}/${TAILNET_ADDRESS_FILE}`;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, address);
      fileIo.closeSync(file);
    } catch (error) {
      this.log('缓存 tailnet 地址失败（下次会走慢路径）');
    }
  }

  /**
   * 有缓存地址：直接建真 tun → 一次 `restartWithTun`。
   * 起完对一下内核报的地址；对不上（删过机器/换了节点密钥）就走「停→重建」兜底并更新缓存。
   */
  private async startWithCachedAddress(address: string): Promise<void> {
    const conn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (conn === undefined || this.destroying) {
      return;
    }
    this.publish('creating-tun', 0, `create(real ${address}) 已调用，等待 tun fd`);
    const fd: number = await this.createWithConflictReplacement(this.realConfig(address), 'real-cached');
    if (fd < 0 || this.destroying) {
      return;
    }
    this.tunFd = fd;
    this.tunAddress = address;
    const probe: string = tunFdProbe(fd);
    this.publish('creating-tun', 0, `tunFd=${fd}｜tunFdProbe: ${probe}｜addr=${address}`);
    if (!probe.startsWith('OK')) {
      this.publish(EXT_PHASE_FAILED, -1, `TUN fd 不可用（tunFdProbe=${probe}）`);
      return;
    }
    // 与慢路径保持一致：缓存地址快路径也必须把扩展进程排除在 VPN 之外（否则内核控制面会绕进 tun）
    try {
      await (this.vpnConnection as vpnExtension.VpnConnection).protectProcessNet();
      this.log('protectProcessNet：扩展进程已排除在 VPN 之外（缓存地址路径）');
    } catch (error) {
      this.log('protectProcessNet 不可用（缓存地址路径；内核控制面走公网，不影响 100.x 路由）');
    }
    this.handOffTunToKernel(fd, 'real-cached');
  }

  /**
   * 2026-10-19 照 MeshArc 的顺序重做（`_refs\Tailscale-OHOS\...\TailscaleVpnExtensionAbility.ets:762-537`）：
   * **先 `backendStart`（不带 tun）→ 轮询到 Running 拿到分配地址 → 只建一枚真 tun → restartWithTun**。
   * 我们之前"probe tun → Running → 销毁重建 → restart"会多出一次 destroy/create，
   * 云真机实测它把新一代 server 的 start 打成 `context aborted dialing`（NoState）。
   */
  private startUserspaceBackend(): void {
    const stateDir: string = `${this.context.filesDir}/tailscale`;
    const raw: string = startBackendRaw(stateDir, this.deviceModel(), this.osVersion(), getControlUrl(this.context as common.Context));
    this.log(`backendStart（无 tun）返回（不据此判成败）：${raw}`);
    this.publish('kernel-starting', 0, `backendStart=${raw}`);
    this.startStatusPoller();
  }

  onDestroy(): void {
    this.destroying = true;
    this.clearTimers();
    this.log('onDestroy：停内核 + 销毁 VPN 连接');
    try {
      const stopResult: string = stopBackendRaw();
      this.log(`onDestroy backendStop -> ${stopResult}`);
    } catch (error) {
      this.log('onDestroy backendStop 抛异常');
    }
    this.destroyConnection();
    // 客户 2026-10-22：**App 关闭 = 真停**，不能只改 phase 把 backendState/地址留着装"还在跑"。
    // 注意：切后台不会走到这里（VPN 扩展继续活着），只有进程被销毁才调用 onDestroy。
    this.finalizeStopped('App 已关闭：内核停止、VPN 连接销毁');
  }

  // ── 真 tun：内核 Running（userspace）后只建一次、只交接一次 ──────────

  /** 真实 tailnet 地址 + tailnet 网段/10，自排除避免自环 */
  private realConfig(address: string): vpnExtension.VpnConfig {
    const config: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: address, family: 1 },
        prefixLength: 32
      }],
      routes: [{
        interface: 'vpn-tun',
        destination: {
          address: { address: '100.64.0.0', family: 1 },
          prefixLength: 10
        },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: false
      }],
      dnsAddresses: [],
      searchDomains: [],
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isInternal: true,
      isBlocking: false,
      // ⚠️ 2026-10-19 纠正：这里原来写 blockedApplications: [self]，把**整个 App**排除在 VPN 之外
      //   （官方 net-vpnextension.md:268「该列表中的应用数据不会被 VPN 代理」）⇒ App 自己发的 100.x 请求
      //   绕过 tun、走物理网卡，永远到不了插件（云真机实测：节点 Connected、tun 在跑、插件端口 一条连接都没有）。
      //   现在不排除任何应用；只对**扩展进程**调 protectProcessNet()（见 createWithConflictReplacement 之后），
      //   让内核自己的控制面流量不绕进 tun，UI 进程的流量正常走 VPN。
      blockedApplications: []
    };
    return config;
  }

  /** 内核已在 Running（userspace，不带 tun）⇒ 建唯一一枚真 tun，然后 restartWithTun 交接 */
  private async handOffWithRealTun(address: string): Promise<void> {
    if (this.destroying || this.handoffInFlight) {
      return;
    }
    this.handoffInFlight = true;
    try {
      this.publish('creating-tun', 0, `create(real ${address}) 已调用，等待 tun fd`);
      const fd: number = await this.createWithConflictReplacement(this.realConfig(address), 'real');
      if (fd < 0 || this.destroying) {
        return;
      }
      this.tunFd = fd;
      this.tunAddress = address;
      const probe: string = tunFdProbe(fd);
      this.publish('creating-tun', 0, `tunFd=${fd}｜tunFdProbe: ${probe}｜addr=${address}`);
      if (!probe.startsWith('OK')) {
        this.publish(EXT_PHASE_FAILED, -1, `TUN fd 不可用（tunFdProbe=${probe}）`);
        return;
      }
      // 只保护**扩展进程**的 socket（内核控制面不绕进 tun）；UI 进程必须留在 VPN 内，否则 App 请求到不了 tailnet。
      try {
        await (this.vpnConnection as vpnExtension.VpnConnection).protectProcessNet();
        this.log('protectProcessNet：扩展进程已排除在 VPN 之外');
      } catch (error) {
        this.log('protectProcessNet 不可用（内核控制面走公网，不影响 100.x 路由）');
      }
      // 唯一一次交接：userspace 内核 → 带 tun 的内核（MeshArc 同序：先 create 再 restartWithTun）
      this.handOffTunToKernel(fd, 'real');
    } finally {
      this.handoffInFlight = false;
    }
  }

  private handOffTunToKernel(fd: number, tag: string): void {
    const stateDir: string = `${this.context.filesDir}/tailscale`;
    this.publish('kernel-starting', 0, `backendRestartWithTun(${tag}, fd=${fd}) 已调用，等待内核`);
    // 契约 §2.5：**不解析返回值判成败**，一律以 backendStatus() 为准。
    // 但原始返回要留一份：内核一直 NoState 时要能告诉用户"为什么没起来"。
    const raw: string = restartWithTunRaw(stateDir, this.deviceModel(), this.osVersion(), getControlUrl(this.context as common.Context), fd);
    this.lastHandOffRaw = raw;
    this.log(`backendRestartWithTun(${tag}) 返回（不据此判成败）：${raw}`);
    this.startStatusPoller();
    // ⚠️ 契约 §2.3：授权轮询**不能**在这里启动（内核还是 Starting，此时问会把这一代的
    // "交互式登录触发"闸消耗掉）⇒ 由 pollStatusOnce 在 backendState 变 NeedsLogin 时再启动。
  }

  // ── 唯一 VPN 槽位冲突替换（2203002） ───────────────────────────────

  private async createWithConflictReplacement(config: vpnExtension.VpnConfig, tag: string): Promise<number> {
    const conn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (conn === undefined) {
      return -1;
    }
    try {
      return await conn.create(config);
    } catch (error) {
      const e = error as BusinessError;
      const code: number = e.code ?? -1;
      this.log(`create(${tag}) 第一次失败 code=${code} msg=${e.message}`);
      if (code !== VPN_EXISTS_ERROR_CODE) {
        this.publish(EXT_PHASE_FAILED, code, `create(${tag}) 失败：${e.message}`);
        return -1;
      }
      // 系统已有 VPN 连接：先销毁自己的旧连接再重试（契约 §6 / 参考实现 createTunWithConflictReplacement）
      this.publish('creating-tun', code, `槽位被占（2203002）⇒ 走冲突替换：先 destroy 再重建（${tag}）`);
      try {
        await conn.destroy();
      } catch (destroyError) {
        this.log('冲突替换：destroy 旧连接失败');
      }
      try {
        return await conn.create(config);
      } catch (retryError) {
        const re = retryError as BusinessError;
        this.publish(EXT_PHASE_FAILED, re.code ?? -1,
          `冲突替换后 create(${tag}) 仍失败：${re.message}（系统可能有其它 VPN 在运行）`);
        return -1;
      }
    }
  }

  // ── 状态回读（主判据）+ 第二阶段重配 ──────────────────────────────

  private startStatusPoller(): void {
    if (this.statusTimer >= 0) {
      return;
    }
    this.statusTimer = setInterval(() => {
      this.pollStatusOnce();
    }, STATUS_POLL_FAST_MS);
  }

  /** 快轮询自适应降频（b 条：同步 kernelStatus 可能挤掉同线程心跳） */
  private rescheduleStatusPoll(intervalMs: number): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
    }
    this.statusTimer = setInterval(() => {
      this.pollStatusOnce();
    }, intervalMs);
  }

  private pollStatusOnce(): void {
    if (this.destroying || this.statusBusy) {
      return; // b 条：同一时刻只允许一个在途查询
    }
    // b 条：**同一 tick 内先写心跳**，再发同步状态查询，避免心跳被挤掉 >15s 判掉线
    this.publish(this.phase, this.errorCode, this.detail);
    this.statusBusy = true;
    const started: number = Date.now();
    const status: KernelStatus | undefined = kernelStatus();
    const cost: number = Date.now() - started;
    this.statusBusy = false;
    this.lastStatusCostMs = cost;
    if (cost > STATUS_COST_DOWNGRADE_MS) {
      // b 条：一次查询超过 1s ⇒ 自适应降频
      if (this.statusPollIntervalMs !== STATUS_POLL_SLOW_MS) {
        this.statusPollIntervalMs = STATUS_POLL_SLOW_MS;
        this.rescheduleStatusPoll(STATUS_POLL_SLOW_MS);
        this.log(`状态查询耗时 ${cost}ms > ${STATUS_COST_DOWNGRADE_MS}ms ⇒ 轮询降频到 ${STATUS_POLL_SLOW_MS}ms`);
      }
    }
    if (status === undefined) {
      this.kernelError = 'backendStatus() 无法解析（内核可能还没起来）';
      this.publish(this.phase, this.errorCode, `${this.detail}｜状态回读失败`);
      return;
    }
    this.kernelJson = JSON.stringify(status);
    this.backendState = `${status.backendState}`;
    // 现场留证：NoState / StartFailed / StatusUnavailable 时把 error + lastLog 打出来（只在变化时打）
    if (this.backendState === 'NoState' || this.backendState === 'StartFailed' ||
      this.backendState === 'StatusUnavailable') {
      const diag: string = `${this.backendState}｜error=${status.error}｜lastLog=${status.lastLog}`;
      if (diag !== this.lastKernelDiag) {
        this.lastKernelDiag = diag;
        this.log(`内核现场：${diag}`);
      }
    } else {
      this.lastKernelDiag = '';
    }
    // 契约 §2.3：**只有内核真的在 NeedsLogin 时才取授权 URL**（早取会把这一代的触发闸吃掉）
    if (this.backendState === 'NeedsLogin' && !this.authUrlReady) {
      this.startAuthPoller();
    }
    // 连续 NoState = 内核根本没起来 ⇒ 把交接时的原始返回写进 detail（客户端能直接看到原因）
    if (this.backendState === 'NoState') {
      this.noStateStreak = this.noStateStreak + 1;
      if (this.noStateStreak === 5 && this.lastHandOffRaw.length > 0) {
        this.publish(EXT_PHASE_FAILED, -1, `内核没起来（backend=NoState）｜${this.lastHandOffRaw}`);
        return;
      }
    } else {
      this.noStateStreak = 0;
    }
    // F15：peer 段随状态轮询采（低频；内部按 `backendState === 'Running'` 前置 + 单飞）
    void this.collectPeers();
    this.kernelError = `${status.error}`;
    // 持续失败计数（供 UI 侧"持续失败 ⇒ 降级为检测中"的上限判据）
    if (this.backendState === 'StatusUnavailable') {
      if (this.unavailableStreak === 0) {
        this.unavailableSinceMs = Date.now();
      }
      this.unavailableStreak = this.unavailableStreak + 1;
    } else {
      this.unavailableStreak = 0;
      this.unavailableSinceMs = 0;
    }
    const addr: string = firstAddress(status);
    if (addr.length > 0) {
      this.address = addr;
    }
    const mapped: string = phaseFromBackendState(this.backendState, this.address);
    // 入网后把地址存盘（下次直接用真 tun 起，省一次控制平面连接）
    if (mapped === EXT_PHASE_RUNNING && this.address.length > 0) {
      this.writeCachedAddress(this.address);
    }
    if (mapped === EXT_PHASE_RUNNING && this.address.length > 0 && !this.rebuilt) {
      if (this.tunAddress === this.address) {
        // 真 tun 已交接且内核重新 Running ⇒ 完成，不再重建
        this.rebuilt = true;
        this.publish(EXT_PHASE_RUNNING, 0,
          `内核 Running + 地址 ${this.address}（真 tun 已交接，链路就绪）`);
        this.stopStatusPoll();
        return;
      }
      if (this.tunAddress.length > 0) {
        // 缓存地址与内核报的不一致（删过机器/换过节点密钥）⇒ 停后端，改走慢路径拿新地址
        this.log(`缓存地址 ${this.tunAddress} 与内核 ${this.address} 不一致 ⇒ 停后端，改走 userspace 拿地址`);
        this.tunAddress = '';
        this.tunFd = -1;
        stopBackendRaw();
        this.startUserspaceBackend();
        return;
      }
      // 第一次 Running（userspace，无 tun）⇒ 建唯一一枚真 tun 并交接
      this.publish(EXT_PHASE_RUNNING, 0,
        `内核 Running + 地址 ${this.address} ⇒ 建真 tun 并交接（仅一次，不销毁重建）`);
      this.handOffWithRealTun(this.address);
      return;
    }
    // b 条：StatusUnavailable 是临时值 ⇒ 保留上一次 phase，不翻转成 failed
    const effectivePhase: string = this.backendState === 'StatusUnavailable' ? this.phase : mapped;
    const detail: string =
      `内核 ${this.backendState}（phase=${status.phase}）｜tunR=${status.tunRead}/W=${status.tunWrite}` +
      `｜查询耗时 ${cost}ms` +
      `${this.kernelError.length > 0 ? `｜error: ${this.kernelError}` : ''}`;
    this.publish(effectivePhase, this.errorCode, detail);
    // 客户 2026-10-18：**入网完成就停**（tun 已用真实地址重建过，之后空闲不再查内核）
    if (effectivePhase === EXT_PHASE_RUNNING && this.rebuilt && this.address.length > 0 &&
      this.tunAddress === this.address) {
      this.stopStatusPoll();
      return;
    }
    // 稳态放慢轮询（契约 §3）
    if (effectivePhase === EXT_PHASE_RUNNING && this.statusPollIntervalMs !== STATUS_POLL_SLOW_MS) {
      this.statusPollIntervalMs = STATUS_POLL_SLOW_MS;
      this.rescheduleStatusPoll(STATUS_POLL_SLOW_MS);
    }
  }

  /** 客户 2026-10-18：入网完成（Running + tun 已交接）⇒ 停止查内核；断没断由下一次操作自己发现 */
  private stopStatusPoll(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    this.log('已入网 ⇒ 停状态轮询（空闲不再查内核）');
    this.startRunningHeartbeat();
  }

  /**
   * 2026-10-19：入网后每 30s 写一次状态（**不查内核**，只写当前状态）。
   * 用途：App 重启/装包后要靠"心跳是否新鲜"判断扩展还活着，否则旧状态文件会骗它"已入网"。
   * 2026-10-25：入网后状态轮询已停 ⇒ 心跳顺手重采一次 peers。否则 peers 永远停在入网那一刻，
   * 电脑关机后列表一直显示"在线"（客户真机发现）。
   */
  private startRunningHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      return;
    }
    this.heartbeatTimer = setInterval(() => {
      if (!this.destroying) {
        this.publish(this.phase, this.errorCode, this.detail);
        if (this.backendState === 'Running') {
          void this.collectPeers();
        }
      }
    }, RUNNING_HEARTBEAT_MS);
  }

  // ── 授权 URL（只取字符串；是否交给浏览器由 UI 决定） ───────────────

  private startAuthPoller(): void {
    if (this.authTimer >= 0) {
      return;
    }
    this.authTimer = setInterval(() => {
      this.pollAuthOnce();
    }, AUTH_POLL_MS);
  }

  /** 周期刷新走 **异步** NAPI（契约 §1 总纪律 1；同步形态只留单次兜底） */
  private async pollAuthOnce(): Promise<void> {
    if (this.destroying || this.authUrlReady || this.authPolling) {
      return;
    }
    this.authPolling = true;
    try {
      // ⚠️ 实测（2026-10-18 云真机）：`backendAuthURLAsync()` **不 settle**，await 在那里永远不返回，
      // 于是 authPolling 一直为真、后面每 2 秒全被跳过 —— 日志里一条"取授权 URL"都没有。
      // 契约也写了 Async 形态可能不 settle ⇒ 这里用**同步**形态（每次 1–2 秒问一次，可接受）。
      const result: AuthUrlResult = authUrlResult();
      // 客户 2026-10-18：**每次结果都记一行**（只在变化时打），否则"为什么一直 need-login"永远查不到
      const line: string = `${result.state}${result.message.length > 0 ? '｜' + result.message : ''}`;
      if (line !== this.lastAuthState) {
        this.lastAuthState = line;
        this.log(`取授权 URL：${line}`);
      }
      if (result.state === 'ready' && result.url.length > 0) {
        this.authUrl = result.url;
        this.authUrlReady = true;
        this.log('授权 URL 已就绪（仅取字符串，不代用户完成授权）');
        this.publish(this.phase, this.errorCode, `授权 URL 已就绪：${result.url}`);
        if (this.authTimer >= 0) {
          clearInterval(this.authTimer);
          this.authTimer = -1;
        }
      } else if (result.state === 'failed') {
        this.detail = `取授权 URL 失败：${result.message}`;
      }
    } catch (error) {
      this.log('取授权 URL 抛异常（已忽略本次）');
    } finally {
      this.authPolling = false;
    }
  }

  // ── 命令通道（UI → 扩展，防陈旧三步） ─────────────────────────────

  private startCommandWatcher(): void {
    if (this.unsubscribeCommand !== undefined) {
      return;
    }
    // **事件驱动**（客户 2026-10-18）：UI 写完命令发一条应用内事件，这里收到才读一次
    this.unsubscribeCommand = subscribeEvent(EVENT_VPN_COMMAND, () => {
      this.consumeCommandOnce();
    });
    // 冷启动时 UI 的 ping 事件可能早于订阅建立而丢失 ⇒ 订阅后补读一次；**只补 ping**：
    // 命令文件消费后不删，补读别的命令会把 10s 内的 stop/refreshAuthURL 再执行一遍
    this.consumeCommandOnce(true);
  }

  private consumeCommandOnce(initialRead: boolean = false): void {
    if (this.destroying) {
      return;
    }
    const command: VpnCommand | undefined = readCommand(this.context.filesDir);
    if (command === undefined) {
      return;
    }
    if (initialRead && command.command !== 'ping') {
      return;
    }
    if (command.seq <= this.lastConsumedSeq) {
      return; // 防陈旧第 1 步：seq 单调
    }
    const age: number = Date.now() - command.issuedAtMs;
    if (age > COMMAND_TTL_MS) {
      // 防陈旧第 2 步：过期命令丢弃并回 stale（不补执行）
      this.lastConsumedSeq = command.seq;
      this.respond(command.seq, false, 'stale', `命令已过期（${age}ms > ${COMMAND_TTL_MS}ms），已丢弃`);
      return;
    }
    this.lastConsumedSeq = command.seq;
    this.log(`消费命令 seq=${command.seq} command=${command.command}`);
    // 2026-10-20：UI 用它判断"扩展进程还活着"（装包/重启后旧状态文件会骗人）
    if (command.command === 'ping') {
      this.respond(command.seq, true, 'ok', `phase=${this.phase} backend=${this.backendState}`);
      return;
    }
    // 2026-10-25：手机点「刷新」时让扩展**立刻**重采一次 peers（不然只能等 30s 心跳）
    if (command.command === 'refreshPeers') {
      void this.collectPeers();
      this.respond(command.seq, true, 'ok', '已重新采集 peers');
      return;
    }
    if (command.command === 'stop') {
      const raw: string = stopBackendRaw();
      this.destroyConnection();
      this.finalizeStopped(`收到 stop：backendStop 返回 ${raw}`);
      this.respond(command.seq, true, 'ok', '已停止内核并销毁 VPN 连接');
      return;
    }
    if (command.command === 'logout') {
      const raw: string = logoutBackendRaw();
      this.destroyConnection();
      this.finalizeStopped(`收到 logout：${raw}`);
      this.respond(command.seq, true, 'ok', raw);
      return;
    }
    if (command.command === 'refreshAuthURL') {
      // 契约 §2.3/§2.6：**同一代后端只触发一次交互式登录**，空轮询永远拿不到新链接。
      // 要重新拿链接只能让 generation +1 ⇒ 重起后端（带当前 tun fd），再等内核进 NeedsLogin 才取 URL。
      this.authUrl = '';
      this.authUrlReady = false;
      this.lastAuthState = '';
      // 重起后端前先停掉旧的授权轮询：否则它会在新后端还 Starting 时就去问，
      // 把这一代唯一的交互式登录触发消耗掉（契约 §2.3）
      if (this.authTimer >= 0) {
        clearInterval(this.authTimer);
        this.authTimer = -1;
      }
      this.log('refreshAuthURL：重起后端（generation+1）以重新触发登录');
      if (this.tunFd >= 0) {
        this.handOffTunToKernel(this.tunFd, 'relogin');
      } else {
        // 首次登录还没有 tun：必须真的重起 userspace 后端，否则同一代不会再触发登录（命令会空转）
        stopBackendRaw();
        this.startUserspaceBackend();
      }
      this.respond(command.seq, true, 'ok', '已重起后端以重新触发登录');
      return;
    }
    if (command.command === 'clearTailscaleState') {
      // G4：**先停后端，再删 `<filesDir>/tailscale`**（节点密钥/profile 都在那里）
      // ⚠️ 语义：**会丢节点身份、需重新授权**（界面按钮有二次确认 + 明写这句）
      const stopRaw: string = stopBackendRaw();
      const removed: number = this.clearTailscaleState();
      this.authUrl = '';
      this.authUrlReady = false;
      this.respond(command.seq, removed >= 0, removed >= 0 ? 'ok' : 'failed',
        `clearTailscaleState：removed=${removed}｜stop=${stopRaw}`);
      this.finalizeStopped(`已清 tailscale 状态（removed=${removed}）`);
      return;
    }
    this.respond(command.seq, false, 'unsupported', `T4 未支持的命令：${command.command}`);
  }

  /**
   * G4：清掉 `<filesDir>/tailscale`（**保留节点密钥与 profile 的目录** —— 也是"不重装也能恢复"的地基）。
   * ⚠️ **会丢节点身份、需重新授权**。返回被删条目数（失败 -1）；hilog **只记路径与条数、不含任何密钥内容**。
   */
  private clearTailscaleState(): number {
    const stateDir: string = `${this.context.filesDir}/tailscale`;
    let removed: number = 0;
    try {
      if (fileIo.accessSync(stateDir)) {
        const names: string[] = fileIo.listFileSync(stateDir, { recursion: true });
        removed = names.length + 1;
      }
    } catch (countError) {
      removed = 1;
    }
    try {
      if (fileIo.accessSync(stateDir)) {
        fileIo.rmdirSync(stateDir);
      }
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'P1CLR stateDir=%{public}s failed code=%{public}d', stateDir, e.code ?? -1);
      return -1;
    }
    hilog.info(DOMAIN, TAG, 'P1CLR stateDir=%{public}s removed=%{public}d', stateDir, removed);
    return removed;
  }

  private respond(seq: number, ok: boolean, code: string, message: string): void {
    const response: VpnCommandResponse = {
      seq: seq,
      ok: ok,
      code: code,
      message: message,
      atMs: Date.now()
    };
    writeResponse(this.context.filesDir, response);
  }

  // ── 状态文件（唯一事实源，原子写 + 单调 seq） ─────────────────────

  /**
   * F15：采 `peers()`（异步变体、单飞）⇒ 供 UI 判"电脑在线 + 最后可见"。
   * **前置判据（陷阱 2）**：**只有 `backendState === 'Running'` 才采** ——
   *   `peers()` 在 `client == nil`（内核没起）与 `BackendState != "Running"`（没入网）时**都返回 `[]`**，
   *   不判前置就会把"未入网"误判成"电脑离线"（**AC-14② 禁止的假状态**）。
   * 采集结果原样 JSON 存状态文件（UI 侧解析；`online` 与 `lastSeen` 都在 `PeerInfo` 里，
   *  **`lastSeen` 只在 offline 时出现** ⇒ UI 侧 online 时显示"—/在线"，不显示 1970）。
   */
  private async collectPeers(): Promise<void> {
    if (this.peersInFlight) {
      return;
    }
    if (this.backendState !== 'Running') {
      this.peersJson = '';
      this.peersAtMs = 0;
      return;
    }
    this.peersInFlight = true;
    try {
      const list: PeerInfo[] = await peersAsync();
      this.peersJson = JSON.stringify(list);
      this.peersAtMs = Date.now();
      hilog.info(DOMAIN, TAG, 'T4EXT peers n=%{public}d', list.length);
    } catch (error) {
      const e = error as BusinessError;
      this.peersJson = '';
      this.peersAtMs = 0;
      hilog.warn(DOMAIN, TAG, 'T4EXT peers failed code=%{public}d', e.code ?? -1);
    } finally {
      this.peersInFlight = false;
    }
    // peer 是异步采的：采完必须再写一次状态，否则文件里永远没有 peersJson
    // （入网后轮询已停，不补这一次，首屏"网络里的电脑"就是空的）
    if (!this.destroying) {
      this.publish(this.phase, this.errorCode, this.detail);
    }
  }

  private publish(phase: string, errorCode: number, detail: string): void {
    this.phase = phase;
    this.errorCode = errorCode;
    this.detail = detail;
    const nowMs: number = Date.now();
    this.seq = this.seq + 1;
    const status: VpnExtensionStatus = {
      seq: this.seq,
      updatedAtMs: nowMs,
      heartbeatAtMs: nowMs,
      phase: phase,
      address: this.address,
      backendState: this.backendState,
      authUrlReady: this.authUrlReady,
      authUrl: this.authUrl,
      errorCode: errorCode,
      detail: detail,
      kernelError: this.kernelError,
      kernelJson: this.kernelJson,
      statusUnavailableStreak: this.unavailableStreak,
      statusUnavailableSinceMs: this.unavailableSinceMs,
      peersJson: this.peersJson,
      peersAtMs: this.peersAtMs
    };
    if (!writeExtensionStatus(this.context.filesDir, status)) {
      hilog.error(DOMAIN, TAG, 'T4EXT 状态文件写入失败');
    }
    hilog.info(DOMAIN, TAG, 'T4EXT seq=%{public}d phase=%{public}s backend=%{public}s err=%{public}d',
      this.seq, phase, this.backendState, errorCode);
  }

  private startHeartbeat(): void {
    // 客户 2026-10-18：**不再周期性写心跳**。空闲时没有"需要知道的连接状态" ——
    // 断没断由下一次操作（发消息/取数据）自己发现，不为此每 5s 写一次文件。
  }

  /**
   * **真收尾**：把"还在跑"的所有痕迹清干净（客户 2026-10-22：不要假停）。
   * 清 backendState/地址/tun 句柄/授权串/peers，停定时器，写出终态 status。
   */
  private finalizeStopped(detail: string): void {
    this.clearTimers();
    this.address = '';
    this.backendState = 'Stopped';
    this.authUrl = '';
    this.authUrlReady = false;
    this.tunAddress = '';
    this.tunFd = -1;
    this.rebuilt = false;
    this.kernelError = '';
    this.kernelJson = '';
    this.peersJson = '';
    this.peersAtMs = 0;
    this.unavailableStreak = 0;
    this.unavailableSinceMs = 0;
    this.publish('stopped', 0, detail);
    this.log(`真收尾完成：${detail}`);
  }

  private clearTimers(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    if (this.authTimer >= 0) {
      clearInterval(this.authTimer);
      this.authTimer = -1;
    }
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    if (this.unsubscribeCommand !== undefined) {
      this.unsubscribeCommand();
      this.unsubscribeCommand = undefined;
    }
  }

  private destroyConnection(): void {
    const conn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (conn === undefined) {
      return;
    }
    try {
      conn.destroy().then(() => {
        this.log('VPN 连接已销毁');
      }).catch((error: BusinessError) => {
        this.log(`VPN 连接销毁失败 code=${error.code ?? -1}`);
      });
    } catch (error) {
      this.log('VPN 连接销毁抛异常');
    }
  }

  private deviceModel(): string {
    // 客户 2026-10-21：不再写死名字 —— 取系统营销名（marketName），没有才退机型/默认
    return resolveDeviceName('');
  }

  private osVersion(): string {
    return `${deviceInfo.osFullName}`;
  }

  private log(line: string): void {
    hilog.info(DOMAIN, TAG, 'T4EXT %{public}s', line);
  }
}

