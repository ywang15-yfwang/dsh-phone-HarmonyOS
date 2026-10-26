import { commonEventManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appEventName, selfBundleName } from '../../model/BundleName';

/**
 * VPN 扩展 <-> App 主进程的**跨进程事件通道**（客户 2026-10-18："有活动才处理，别拿定时器兜底"）。
 *
 * 背景：扩展是**独立进程**，和界面之间没有直接回调；以前靠"写 JSON 文件 + 每秒读文件"，
 * 现在文件仍当**数据**（原子写、seq 单调、心跳时间都在里面），但**通知**改成官方公共事件：
 * 谁改了谁发一条，对面收到立刻读一次 —— 不再每秒空转。
 *
 * 两个事件都用 `publisherBundleName` 限定在**本应用内**，别的应用收不到。
 *
 * ⚠️ 注意：查 **VPN 内核**（`kernelStatus()`）那条 3~5s 轮询**换不掉** ——
 * 内核 NAPI 只有"问一次"，没有推送，停了就不知道断线/地址变化。
 */
const DOMAIN: number = 0xD001;
const TAG: string = 'F1BUS';

/** 扩展状态已更新（扩展 → UI） */
export const EVENT_VPN_STATUS: string = appEventName('VPN_STATUS');
/** 有新命令（UI → 扩展） */
export const EVENT_VPN_COMMAND: string = appEventName('VPN_COMMAND');

/** 发一条应用内事件（尽力而为：失败只记日志，不影响主流程） */
export function publishEvent(event: string, detail: string): void {
  try {
    const options: commonEventManager.CommonEventPublishData =
      { bundleName: selfBundleName(), parameters: { detail: detail } };
    commonEventManager.publish(event, options, (err: BusinessError) => {
      if (err !== undefined && err !== null && err.code !== 0) {
        hilog.warn(DOMAIN, TAG, 'F1BUS 发事件失败 %{public}s %{public}d', event, err.code);
      }
    });
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'F1BUS 发事件异常 %{public}s', event);
  }
}

/** 订阅一个应用内事件；返回取消订阅函数（页面/扩展销毁时必须调用） */
export function subscribeEvent(event: string, onEvent: () => void): () => void {
  let subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  // 审查 2026-10-22：退订可能发生在 createSubscriber 的回调之前 —— 记住"已退订"，
  // 回调到达后立刻 unsubscribe，别把一个活订阅漏在进程里。
  let cancelled: boolean = false;
  const info: commonEventManager.CommonEventSubscribeInfo =
    { events: [event], publisherBundleName: selfBundleName() };
  try {
    commonEventManager.createSubscriber(info,
      (err: BusinessError, sub: commonEventManager.CommonEventSubscriber) => {
        if (err !== undefined && err !== null && err.code !== 0) {
          hilog.warn(DOMAIN, TAG, 'F1BUS 建订阅失败 %{public}s %{public}d', event, err.code);
          return;
        }
        if (cancelled) {
          return; // 已经被退订了，不建立订阅
        }
        subscriber = sub;
        try {
          commonEventManager.subscribe(sub, () => {
            onEvent();
          });
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'F1BUS 订阅异常 %{public}s', event);
        }
      });
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'F1BUS 建订阅异常 %{public}s', event);
  }
  return () => {
    cancelled = true;
    const sub: commonEventManager.CommonEventSubscriber | undefined = subscriber;
    if (sub === undefined) {
      return;
    }
    try {
      commonEventManager.unsubscribe(sub, (err: BusinessError) => {
        if (err !== undefined && err !== null && err.code !== 0) {
          hilog.warn(DOMAIN, TAG, 'F1BUS 退订失败 %{public}d', err.code);
        }
      });
    } catch (error) {
      // 已退订
    }
  };
}
