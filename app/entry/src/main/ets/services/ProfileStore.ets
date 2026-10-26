import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_DSH_PORT, DeviceProfile, emptyProfile, systemDeviceName } from '../model/DeviceProfile';

const DOMAIN: number = 0xD001;
const TAG: string = 'PROFILE';

const STORE_NAME: string = 'dsh_profiles_v1';
const KEY_PROFILES: string = 'profiles';

/**
 * **每台电脑一份配置**的落盘（客户 2026-10-21）：
 *  - 键 = 电脑的 tailnet 地址（同一台机器地址一般不变；变了重新配一次即可）；
 *  - 值 = `DeviceProfile`（名字 / dsh 端口 / 插件端口 / SSH 端口 / SSH 用户名）；
 *  - 只存这些**连接参数**，不存 cookie（cookie 仍在内存的 `PairingVault`）。
 */
class ProfileStoreImpl {
  private cache: Record<string, DeviceProfile> | undefined = undefined;
  /**
   * 上一次读盘是否失败。失败时**不缓存空表**、也**拒绝保存** ——
   * 否则"读坏了 → 空表 → 保存一台把其它电脑的配置全冲掉"（审查 2026-10-22 指出）。
   */
  private loadFailed: boolean = false;

  private open(ctx: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(ctx, { name: STORE_NAME });
  }

  /** 全部配置（按电脑地址） */
  loadAll(ctx: common.Context): Record<string, DeviceProfile> {
    if (this.cache !== undefined) {
      return this.cache;
    }
    const out: Record<string, DeviceProfile> = {};
    try {
      const store: preferences.Preferences = this.open(ctx);
      const raw: string = store.getSync(KEY_PROFILES, '{}') as string;
      const parsed: Record<string, Object> = JSON.parse(raw.length > 0 ? raw : '{}') as Record<string, Object>;
      const keys: string[] = Object.keys(parsed);
      for (let i = 0; i < keys.length; i++) {
        const one: DeviceProfile | undefined = toProfile(parsed[keys[i]]);
        if (one !== undefined) {
          out[keys[i]] = one;
        }
      }
      this.loadFailed = false;
    } catch (error) {
      // 读坏了：不缓存、标记失败；下次调用会重试读盘，保存则直接拒绝
      this.loadFailed = true;
      hilog.error(DOMAIN, TAG, '读配置失败（本次不缓存、不允许覆盖保存）%{public}s', `${error}`);
      return out;
    }
    this.cache = out;
    return out;
  }

  /** 上次读盘是否失败（UI 可据此提示"配置读取失败"） */
  readFailed(ctx: common.Context): boolean {
    this.loadAll(ctx);
    return this.loadFailed;
  }

  /** 这台电脑有没有配置过 */
  has(ctx: common.Context, host: string): boolean {
    return this.loadAll(ctx)[host] !== undefined;
  }

  get(ctx: common.Context, host: string): DeviceProfile | undefined {
    return this.loadAll(ctx)[host];
  }

  /** 存一份（整表重写，避免 preferences 的嵌套对象坑） */
  save(ctx: common.Context, host: string, profile: DeviceProfile): boolean {
    const all: Record<string, DeviceProfile> = this.loadAll(ctx);
    if (this.loadFailed) {
      hilog.error(DOMAIN, TAG, '配置读取失败过，拒绝保存（免得覆盖其它电脑的配置）');
      return false;
    }
    // 先写副本：落盘成功后才更新缓存（失败不能让界面以为已保存）
    const next: Record<string, DeviceProfile> = {};
    const keys: string[] = Object.keys(all);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = all[keys[i]];
    }
    next[host] = profile;
    try {
      const store: preferences.Preferences = this.open(ctx);
      store.putSync(KEY_PROFILES, JSON.stringify(next));
      store.flushSync();
      this.cache = next;
      hilog.info(DOMAIN, TAG, '已保存配置 %{public}s（插件 %{public}d / SSH %{public}d）',
        host, profile.pluginPort, profile.sshPort);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, '保存配置失败 %{public}s', `${error}`);
      return false;
    }
  }

  /** 删掉一台电脑的配置（客户 2026-10-25：旧配置可由用户自己清掉重配） */
  remove(ctx: common.Context, host: string): boolean {
    const all: Record<string, DeviceProfile> = this.loadAll(ctx);
    if (this.loadFailed) {
      hilog.error(DOMAIN, TAG, '配置读取失败过，拒绝删除（免得覆盖其它电脑的配置）');
      return false;
    }
    const next: Record<string, DeviceProfile> = {};
    const keys: string[] = Object.keys(all);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== host) {
        next[keys[i]] = all[keys[i]];
      }
    }
    try {
      const store: preferences.Preferences = this.open(ctx);
      store.putSync(KEY_PROFILES, JSON.stringify(next));
      store.flushSync();
      this.cache = next;
      hilog.info(DOMAIN, TAG, '已删除配置 %{public}s', host);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, '删除配置失败 %{public}s', `${error}`);
      return false;
    }
  }
}

function toProfile(value: Object): DeviceProfile | undefined {
  if (value === null || value === undefined) {
    return undefined;
  }
  const rec: Record<string, Object> = value as Record<string, Object>;
  const base: DeviceProfile = emptyProfile();
  const name: Object | undefined = rec['name'];
  const dshPort: Object | undefined = rec['dshPort'];
  const pluginPort: Object | undefined = rec['pluginPort'];
  const sshPort: Object | undefined = rec['sshPort'];
  const sshUser: Object | undefined = rec['sshUser'];
  const paired: Object | undefined = rec['paired'];
  return {
    name: typeof name === 'string' ? name : base.name,
    // 端口必须在 1–65535：旧版/损坏的配置里可能出现 0 或越界值，不能拿去建连或拼命令
    dshPort: typeof dshPort === 'number' && dshPort > 0 && dshPort <= 65535 ? dshPort : DEFAULT_DSH_PORT,
    pluginPort: typeof pluginPort === 'number' && pluginPort > 0 && pluginPort <= 65535 ? pluginPort : 0,
    sshPort: typeof sshPort === 'number' && sshPort > 0 && sshPort <= 65535 ? sshPort : 0,
    sshUser: typeof sshUser === 'string' ? sshUser : '',
    paired: paired === true
  };
}

export const profileStore: ProfileStoreImpl = new ProfileStoreImpl();

// ---- 当前生效的配置（内存）--------------------------------------------------
let active: DeviceProfile | undefined = undefined;

/** 连接/进入会话前设置；`PairTarget`、`DshApiClient` 从这里取端口 */
export function setActiveProfile(profile: DeviceProfile): void {
  active = profile;
}

export function activeProfile(): DeviceProfile {
  if (active !== undefined) {
    return active;
  }
  return {
    name: systemDeviceName(),
    dshPort: DEFAULT_DSH_PORT,
    pluginPort: 0,
    sshPort: 0,
    sshUser: '',
    paired: false
  };
}

export function activeDeviceName(): string {
  return active !== undefined ? active.name : systemDeviceName();
}


