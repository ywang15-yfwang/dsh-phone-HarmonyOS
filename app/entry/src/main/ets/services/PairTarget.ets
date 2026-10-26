import { pairingVault } from '../features/f03-connect/PairingVault';
import { DSH_PATH_PREFIX } from '../model/EntryPorts';
import { activeProfile } from './ProfileStore';
import { TransportTarget } from '../channel/FileTransport';

/**
 * 文件/图片通道的**传输目标**（上传、整夹上传、取图共用）。
 *
 * **凭据单源**：只从 `pairingVault`（内存单例）取 —— 与首页、会话页是同一份，**不新增第二套凭据来源**。
 *
 * **真机唯一通路**：dsh 只听电脑回环，tailnet 上只有插件 插件端口 能到 ⇒
 *   · socket 目标 = `插件地址:插件端口`；
 *   · `Host` 恒为回环 `127.0.0.1:<dsh端口>`（插件铸凭据时绑的 `phoneAuthority`）；
 *   · 路径带 `/pair/dsh` 前缀，由插件转给本机 dsh。
 *
 * ⚠️ 历史坑（`#D` 实测）：这三条请求曾因清理取证代码时把 `cookie` 接线一并删掉而**不带 Cookie**
 * ⇒ 服务端回 `401：围栏已过但没有凭据`。`HttpTransport.authHeaders()` 只在 `cookie` 非空时加 `Cookie` 头。
 */
export function pairTarget(): TransportTarget {
  const profile = activeProfile();
  const host: string = pairingVault.hostOr('');
  const port: number = pairingVault.portOr(profile.pluginPort);
  return {
    address: host, port: port, hostHeader: pairingVault.authorityOr(`127.0.0.1:${profile.dshPort}`),
    pathPrefix: DSH_PATH_PREFIX,
    cookie: pairingVault.get()
  };
}
