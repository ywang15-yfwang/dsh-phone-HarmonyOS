import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'GLOBALCFG';
const STORE_NAME: string = 'dsh_global_v1';
const KEY_CONTROL_URL: string = 'control_url';

/** 官方控制平面（客户：平时不会改，放出来只是为了能改） */
export const DEFAULT_CONTROL_URL: string = 'https://controlplane.tailscale.com';

function normalize(url: string): string {
  let one: string = url.trim();
  while (one.length > 1 && one.endsWith('/')) {
    one = one.substring(0, one.length - 1);
  }
  return one;
}

/** 控制服务器地址（读不到/不合法就用官方默认） */
export function getControlUrl(ctx: common.Context): string {
  try {
    const st: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: STORE_NAME } as preferences.Options);
    const raw: string = st.getSync(KEY_CONTROL_URL, '') as string;
    const one: string = normalize(raw);
    if (one.startsWith('http://') || one.startsWith('https://')) {
      return one;
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '读全局配置失败：%{public}s', `${error}`);
  }
  return DEFAULT_CONTROL_URL;
}

/** 保存控制服务器地址；不合法返回 false（不做静默兜底） */
export function setControlUrl(ctx: common.Context, url: string): boolean {
  const one: string = normalize(url);
  if (!(one.startsWith('http://') || one.startsWith('https://')) || one.indexOf(' ') >= 0) {
    return false;
  }
  try {
    const st: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: STORE_NAME } as preferences.Options);
    st.putSync(KEY_CONTROL_URL, one);
    st.flushSync();
    hilog.info(DOMAIN, TAG, '已保存控制服务器地址：%{public}s', one);
    return true;
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '保存全局配置失败：%{public}s', `${error}`);
    return false;
  }
}
