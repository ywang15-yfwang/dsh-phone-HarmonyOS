import { Want, common, CompletionHandlerForAbilityStartCallback } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'F1LOGIN';

/**
 * 登录用的"按类型拉起系统浏览器"辅助类 —— **照抄参考实现 MeshArc**
 * （`_refs\Tailscale-OHOS\entry\src\main\ets\components\BridgeStatus.ets:263-282`）。
 */
class BrowserStartParameters {
  uri: string;

  constructor(uri: string) {
    this.uri = uri;
  }
}

class SecureLoginAbilityStartCallback {
  completionHandler?: CompletionHandlerForAbilityStartCallback;
  private readonly errorHandler: (code: number, name: string, message: string) => void;

  constructor(errorHandler: (code: number, name: string, message: string) => void) {
    this.errorHandler = errorHandler;
  }

  onError(code: number, name: string, message: string): void {
    this.errorHandler(code, name, message);
  }
}

/**
 * 把授权链接交给**系统浏览器**：三级兜底（顺序照 MeshArc，别改）。
 * 返回实际走通的那一级（`startAbilityByType` / `openLink` / `want` / `failed`），便于界面如实说。
 */
export async function openSecureLoginBrowser(ctx: common.UIAbilityContext, url: string): Promise<string> {
  // ① 按类型拉起浏览器（系统浏览器解析器最认这条）
  try {
    // 审查 2026-10-22：派发成功但浏览器实际没起时，系统既不 resolve 也不回调 ⇒ 必须自己超时，
    // 否则 `await` 永不返回、界面永远卡在"正在打开浏览器…"。
    let timer: number = -1;
    const timeout: Promise<void> = new Promise<void>((_resolve: () => void, reject: (e: Error) => void) => {
      timer = setTimeout(() => reject(new Error('拉起浏览器超时（2.5s）')), 2500);
    });
    const start: Promise<void> = new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      const completionHandler: CompletionHandlerForAbilityStartCallback =
        new CompletionHandlerForAbilityStartCallback();
      completionHandler.onRequestSuccess = (_name: string): void => resolve();
      completionHandler.onRequestFailure = (_name: string, failureCode: number, _msg: string): void => {
        reject(new Error(`browser type start failed code=${failureCode}`));
      };
      const callback: SecureLoginAbilityStartCallback = new SecureLoginAbilityStartCallback(
        (code: number, _name: string, _message: string): void => {
          reject(new Error(`browser type start error code=${code}`));
        });
      callback.completionHandler = completionHandler;
      const browserParameters: BrowserStartParameters = new BrowserStartParameters(url);
      ctx.startAbilityByType('browser', browserParameters as Object as Record<string, Object>,
        callback as common.AbilityStartCallback)
        .then(() => resolve(), () => reject(new Error('browser type start rejected')));
    });
    try {
      await Promise.race([start, timeout]);
    } finally {
      if (timer >= 0) {
        clearTimeout(timer);
      }
    }
    hilog.info(DOMAIN, TAG, '浏览器已拉起（startAbilityByType browser）');
    return 'startAbilityByType';
  } catch (error) {
    const e = error as BusinessError;
    hilog.info(DOMAIN, TAG, '按类型拉起失败：%{public}s，降级 openLink', `${e.message}`);
  }
  // ② openLink
  try {
    await ctx.openLink(url, { appLinkingOnly: false });
    hilog.info(DOMAIN, TAG, '浏览器已拉起（openLink）');
    return 'openLink';
  } catch (error) {
    const e = error as BusinessError;
    hilog.info(DOMAIN, TAG, 'openLink 失败 code=%{public}d，降级 Want', e.code ?? -1);
  }
  // ③ 显式 Want
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: url,
    entities: ['entity.system.browsable']
  };
  try {
    await ctx.startAbility(want);
    hilog.info(DOMAIN, TAG, '浏览器已拉起（startAbility viewData）');
    return 'want';
  } catch (error) {
    const e2 = error as BusinessError;
    hilog.error(DOMAIN, TAG, '打开系统浏览器失败 code=%{public}d %{public}s', e2.code ?? -1, `${e2.message}`);
    return 'failed';
  }
}
