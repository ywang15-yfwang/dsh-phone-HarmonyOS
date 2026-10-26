import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'BUNDLE';

/**
 * **运行时取自己的包名**（客户 2026-10-21：包里不再写死 `com.dsh.phone`）。
 *
 * 为什么以前写死：`commonEventManager` 的事件要带 `publisherBundleName`，
 * 启动 VPN 扩展的 Want 要带 `bundleName`。这两处以前抄了包名常量 ⇒ 改包名就断。
 * 现在统一从这里取：改包名/多包名都不会错。
 *
 * 兜底：万一取不到（极早期/受限环境），返回空串，调用方自己决定怎么办。
 */
let cached: string = '';

export function selfBundleName(): string {
  if (cached.length > 0) {
    return cached;
  }
  try {
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    cached = typeof info.name === 'string' ? info.name : '';
    if (cached.length > 0) {
      hilog.info(DOMAIN, TAG, '包名=%{public}s', cached);
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '取包名失败 %{public}s', `${error}`);
    cached = '';
  }
  return cached;
}

/** 应用内公共事件名（沿用 `<包名>.event.<后缀>` 的约定） */
export function appEventName(suffix: string): string {
  const bundle: string = selfBundleName();
  return bundle.length > 0 ? `${bundle}.event.${suffix}` : `dsh-phone.event.${suffix}`;
}
