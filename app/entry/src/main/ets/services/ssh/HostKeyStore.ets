import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'HOSTKEY';
const STORE_NAME: string = 'dsh_hostkeys_v1';

function open(ctx: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(ctx, { name: STORE_NAME } as preferences.Options);
}

/** 这台电脑第一次连时记住的主机公钥指纹（空 = 还没信任过） */
export function pinnedHostKey(ctx: common.Context, host: string): string {
  try {
    return open(ctx).getSync(host, '') as string;
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '读主机指纹失败：%{public}s', `${error}`);
    return '';
  }
}

/** 第一次连成功后固定指纹（TOFU） */
export function pinHostKey(ctx: common.Context, host: string, fingerprint: string): void {
  if (fingerprint.length === 0) {
    return;
  }
  try {
    const st: preferences.Preferences = open(ctx);
    st.putSync(host, fingerprint);
    st.flushSync();
    hilog.info(DOMAIN, TAG, '已记住主机指纹 %{public}s', host);
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '保存主机指纹失败：%{public}s', `${error}`);
  }
}

/** 用户主动"重置信任"（换了电脑/重装系统后指纹变了才需要） */
export function clearHostKey(ctx: common.Context, host: string): boolean {
  try {
    const st: preferences.Preferences = open(ctx);
    st.putSync(host, '');
    st.flushSync();
    return true;
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '清除主机指纹失败：%{public}s', `${error}`);
    return false;
  }
}
