/**
 * 扩展 / VPN 层的错误码 → 人读文案（**单一事实源**）。
 *
 * 为什么独立成文件（而不是留在 `services/DshConnection`）：
 *  ① 界面（`pages/`）与入网状态机（`services/VpnStateMachine`）要用**同一套**文案 —— 两处各写一份就会各说各话；
 *  ② 本文件**不依赖任何 Kit** ⇒ 不会把 `@ohos.net.http`（NetworkKit）拖进 VPN 扩展进程的 import 图
 *     （`DshVpnExtensionAbility` 会 import `VpnStateMachine`）；
 *  ③ 可在宿主 node 上直接跑自查。
 *
 * 码值来源：契约 §6（`2203002` / `2097152` / `9568347`）。
 */
export function readableVpnError(code: number): string {
  if (code === 2203002) {
    return '系统已有其它 VPN 连接占用槽位（2203002）⇒ 需替换或先关闭';
  }
  if (code === 2097152) {
    return 'VPN 组件不可用（2097152：扩展拉不起来，如镜像缺 com.huawei.hmos.vpndialog）';
  }
  if (code === 9568347) {
    return '装包失败 9568347：HAP 缺该 ABI 的原生库（构建期问题，查 abiFilters）';
  }
  if (code === 0) {
    return '无错误';
  }
  return `系统错误码 ${code}`;
}
