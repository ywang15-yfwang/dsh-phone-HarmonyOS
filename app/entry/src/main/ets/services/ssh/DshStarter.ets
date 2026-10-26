import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SshClient, SshExecResult } from './SshClient';
import { Ed25519Pair } from './SshCrypto';
import { SshKeys, sshKeys } from './SshKeys';
import { pinHostKey, pinnedHostKey } from './HostKeyStore';
import {
  DSH_LAUNCH_COMMAND,
  DSH_POWER_COMMAND,
  DSH_STOP_COMMAND,
  SSH_LAUNCH_TIMEOUT_MS,
  SSH_POWER_TIMEOUT_MS,
  SSH_STOP_TIMEOUT_MS
} from '../../model/EntryPorts';
import { DeviceProfile } from '../../model/DeviceProfile';

const DOMAIN: number = 0xD001;
const TAG: string = 'SSHLAUNCH';

/** 启动的三态回执（电脑上脚本的三句话）＋ `ERROR` = 连不上/没权限/超时 */
export enum StartState {
  ALREADY = 'already',
  READY = 'ready',
  FAILED = 'failed',
  ERROR = 'error'
}

export interface StartOutcome {
  state: StartState;
  /** 直接可上界面的人话 */
  message: string;
  /** 界面展示/复制用的公钥（出错时引导用户去加公钥） */
  publicKey: string;
}

/** 关闭的对称三态（客户 2026-10-21） */
export enum StopState {
  ALREADY = 'already_stopped',
  STOPPED = 'stopped',
  FAILED = 'failed',
  ERROR = 'error'
}

export interface StopOutcome {
  state: StopState;
  message: string;
}

/** 关机的三态（客户 2026-10-21） */
export enum PowerState {
  SHUTTING_DOWN = 'shutting_down',
  FAILED = 'failed',
  ERROR = 'error'
}

export interface PowerOutcome {
  state: PowerState;
  message: string;
}

/**
 * 把配置页里填的 **dsh 端口** 追加到脚本命令后面（客户 2026-10-22）：
 * 手机端不在命令里写死端口，电脑侧脚本按这个值判"起没起 / 停没停"。
 */
function withPort(command: string, port: number): string {
  return port > 0 ? `${command} -Port ${port}` : command;
}

/**
 * 「一键把电脑上的 dsh 拉起来 / 关掉」的业务层。
 *
 * 分工：
 *   · `SshClient` —— 只懂 SSH；
 *   · 这里 —— 懂"要跑哪条命令、回执怎么翻译、界面该说什么"；
 *   · 界面 —— 只认 `StartOutcome` / `StopOutcome`。
 *
 * **不探测 dsh 端口**：起没起、停没停都由电脑上的脚本自己判（它测端口），
 * 手机侧重复探测只会造成"两个事实源打架"。
 */
export class DshStarter {
  private keys: SshKeys = sshKeys;

  /** 拉起 dsh；`host` 是这台电脑的 tailnet 地址 */
  async ensureDsh(ctx: common.Context, host: string, profile: DeviceProfile): Promise<StartOutcome> {
    // 先把身份准备好：错误回执里要带公钥（首次授权时用户就靠它粘贴），以前取太早会是空串
    try {
      await this.keys.ensure(ctx);
    } catch (ensureError) {
      hilog.warn(DOMAIN, TAG, 'SSH 身份准备失败（继续尝试，回执里可能没有公钥）');
    }
    const pub: string = this.keys.publicKeyLine();
    const result: SshExecResult = await this.run(ctx, host, profile,
      withPort(DSH_LAUNCH_COMMAND, profile.dshPort), SSH_LAUNCH_TIMEOUT_MS);
    if (!result.ok) {
      return { state: StartState.ERROR, message: this.humanError(result.error), publicKey: pub } as StartOutcome;
    }
    const out: string = result.output;
    if (out.indexOf('ALREADY') >= 0) {
      return { state: StartState.ALREADY, message: 'dsh 本来就在跑', publicKey: pub } as StartOutcome;
    }
    if (out.indexOf('READY') >= 0) {
      return { state: StartState.READY, message: 'dsh 已启动', publicKey: pub } as StartOutcome;
    }
    // 电脑侧分得清"这个端口没有配过实例"和"配了但没起来"，这里照它的话说
    if (out.indexOf('FAILED_NO_INSTANCE') >= 0) {
      return {
        state: StartState.FAILED,
        message: `电脑上没有配 ${profile.dshPort} 这个端口的实例`,
        publicKey: pub
      } as StartOutcome;
    }
    if (out.indexOf('FAILED_NO_TASK') >= 0) {
      return {
        state: StartState.FAILED,
        message: '电脑上的启动任务没装好（需要重新跑一次安装脚本）',
        publicKey: pub
      } as StartOutcome;
    }
    if (out.indexOf('FAILED') >= 0) {
      return { state: StartState.FAILED, message: 'dsh 端口不对（没能起来）', publicKey: pub } as StartOutcome;
    }
    return {
      state: StartState.ERROR,
      message: `电脑回了看不懂的内容：${out.trim().substring(0, 60)}`,
      publicKey: pub
    } as StartOutcome;
  }

  /**
   * 关掉 dsh（客户 2026-10-21：手机上也得能收）。
   * 电脑侧只杀**监听 dsh 端口 的那个进程**，不按名字杀、不停计划任务（停任务收不掉已起的 node）。
   */
  async stopDsh(ctx: common.Context, host: string, profile: DeviceProfile): Promise<StopOutcome> {
    const result: SshExecResult = await this.run(ctx, host, profile,
      withPort(DSH_STOP_COMMAND, profile.dshPort), SSH_STOP_TIMEOUT_MS);
    if (!result.ok) {
      return { state: StopState.ERROR, message: this.humanError(result.error) } as StopOutcome;
    }
    const out: string = result.output;
    if (out.indexOf('ALREADY_STOPPED') >= 0) {
      return { state: StopState.ALREADY, message: 'dsh 本来就没在跑' } as StopOutcome;
    }
    if (out.indexOf('STOPPED') >= 0) {
      return { state: StopState.STOPPED, message: 'dsh 已关闭' } as StopOutcome;
    }
    if (out.indexOf('FAILED') >= 0) {
      return { state: StopState.FAILED, message: '电脑没能把 dsh 关掉' } as StopOutcome;
    }
    return { state: StopState.ERROR, message: `电脑回了看不懂的内容：${out.trim().substring(0, 60)}` } as StopOutcome;
  }

  /**
   * **关机**（客户 2026-10-21：SSH 打通了，手机上也能让电脑关机）。
   *
   * 电脑侧脚本默认**延迟 10 秒**再断电：这条 SSH 连接就是那个命令拉起来的，
   * 立刻关会连回执都发不回来，手机端就会误报"失败"。所以我们只等它回 `SHUTTING_DOWN`。
   */
  async powerOff(ctx: common.Context, host: string, profile: DeviceProfile): Promise<PowerOutcome> {
    const result: SshExecResult = await this.run(ctx, host, profile, DSH_POWER_COMMAND, SSH_POWER_TIMEOUT_MS);
    if (!result.ok) {
      return { state: PowerState.ERROR, message: this.humanError(result.error) } as PowerOutcome;
    }
    const out: string = result.output;
    if (out.indexOf('SHUTTING_DOWN') >= 0) {
      return { state: PowerState.SHUTTING_DOWN, message: '电脑正在关机（10 秒后断电）' } as PowerOutcome;
    }
    if (out.indexOf('FAILED') >= 0) {
      return { state: PowerState.FAILED, message: '电脑没能关机' } as PowerOutcome;
    }
    return {
      state: PowerState.ERROR,
      message: `电脑回了看不懂的内容：${out.trim().substring(0, 60)}`
    } as PowerOutcome;
  }

  /** 跑一条 SSH 命令（起/停/关机共用：身份、超时、日志口径都在这里） */
  private async run(ctx: common.Context, host: string, profile: DeviceProfile,
    command: string, timeoutMs: number): Promise<SshExecResult> {
    const pair: Ed25519Pair = await this.keys.ensure(ctx);
    const client: SshClient = new SshClient();
    const expected: string = pinnedHostKey(ctx, host);
    hilog.info(DOMAIN, TAG, 'SSH → %{public}s:%{public}d（user=%{public}s）', host, profile.sshPort, profile.sshUser);
    const result: SshExecResult = await client.exec({
      host: host,
      port: profile.sshPort,
      user: profile.sshUser,
      command: command,
      priKey: pair.priKey,
      rawPub: pair.rawPub,
      timeoutMs: timeoutMs,
      expectedHostKey: expected
    });
    // 第一次连成功：把这台电脑的主机指纹固定下来（TOFU），以后不一致就拒绝
    if (result.ok && expected.length === 0) {
      pinHostKey(ctx, host, client.hostKeyFingerprint());
    }
    return result;
  }

  /** 把 SSH 底层错误翻成人话（界面直接显示） */
  private humanError(raw: string): string {
    if (raw.indexOf('认证失败') >= 0) {
      return '这台电脑还不认识本机（SSH 公钥没加）';
    }
    if (raw.indexOf('连不上') >= 0) {
      return '连不上这台电脑（电脑没开机，或 SSH 端口不对）';
    }
    if (raw.indexOf('超时') >= 0) {
      return '超时';
    }
    return `操作失败：${raw}`;
  }
}

export const dshStarter: DshStarter = new DshStarter();
