/**
 * 从上传原始响应体里取 `receiptId`（**判成败要用它**）。
 *
 * 实测：真实例上传成功体是 `{"ok":true,"value":{"receiptId":"…","file":{…}}}` ⇒ **取 `value.receiptId`**；
 * 兼容库层已解包的顶层 `receiptId`。取不到 ⇒ 业务未成功（哪怕 HTTP 是 200）。
 *
 * **为什么放这里**：它原本长在 `pages/Index.ets` 里（被会话页的功能块**反向 import 页面**），
 * 是"功能块依赖页面"的一处不干净接缝 ⇒ 挪到 `channel/`，谁都能用、没人要依赖页面。
 */
export function parseReceiptId(rawBody: string): string {
  if (rawBody.length === 0 || rawBody.charAt(0) !== '{') {
    return '';
  }
  try {
    const parsed = JSON.parse(rawBody) as Record<string, Object>;
    const valueRaw = parsed['value'] as Record<string, Object>;
    const fromValue: Object | undefined = valueRaw === undefined ? undefined : valueRaw['receiptId'];
    const fromTop: Object | undefined = parsed['receiptId'];
    if (typeof fromValue === 'string') {
      return fromValue as string;
    }
    if (typeof fromTop === 'string') {
      return fromTop as string;
    }
    return '';
  } catch (e) {
    return '';
  }
}
