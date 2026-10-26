/**
 * 配对凭据的**内存单例**（跨页面共用），**不落盘**。
 *
 * 为什么要有它：F5 开了新页面 `pages/Conversation.ets`，而配对是在 `Index` 里做的 ——
 * 凭据若留在页内私有字段，新页面读不到。放进模块级单例后**两页共用一份**。
 *
 * **为什么仍然不落盘**（客户 2026-10-13 口径，见 `需求文档-v12 §4` 第 2 条）：
 * 改成走 `dsh-pair` 插件后，**插件随时能再签一份** ⇒ 打开 App 点一次「连接电脑」就拿得到，
 * 不必在手机上留一个凭据文件。进程一退凭据即无 —— 这正是"**凭据不落盘是刻意选择**"。
 *
 * 纪律（不放松的部分）：
 *  - **不打日志、不进界面**：只记**长度**与 authority，绝不把凭据本体拼进任何字符串；
 *  - 送进 HTTP 头的是 `set-cookie` 的首段 `name=value`（原始串带 `; Path=/…` 等属性，
 *    整串塞进 `Cookie` 头是错的）—— 由 `get()` 统一裁出来，调用方不必知道这个细节。
 */

/** 到期前多久算"该续期"：插件侧 claim 可重复调用（同来源 IP 限速 10s），这里留 1 天 */
export const RENEW_WINDOW_MS: number = 24 * 60 * 60 * 1000;

/** 把毫秒时刻写成可读的"有效期至 …"（本地时区；<=0 ⇒ `—`） */
export function expiryText(ms: number): string {
  if (ms <= 0) {
    return '—';
  }
  const d: Date = new Date(ms);
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

class PairingVaultImpl {
  private cookieName: string = '';
  /** **原始 `set-cookie` 串**（含 `; Path=/…` 这类属性）；送头时由 `get()` 只取首段 */
  private cookieRaw: string = '';
  private expiresAtMs: number = 0;
  private authorityValue: string = '';
  /** 插件地址（真机 tailnet 上唯一能到的门；dsh 只听电脑回环） */
  private dshHost: string = '';
  /** 插件端口（插件端口）；dsh 自己的 dsh 端口 只在 Host 头里出现 */
  private dshPortValue: number = 0;
  private pairedAtMsValue: number = 0;
  /**
   * 见过 401 的**临时标记**（不落盘）：`DshApiClient` 带凭据的请求收到 401 时置真
   * ⇒ 下一次续期检查会真跑一次 claim。这是"收到 401 自动续期一次"的触发点；
   * 时间口径另由 `expiresAt` 负责。
   */
  private rejected: boolean = false;

  /** 存入（**只在内存**）：`cookieRaw` = 插件给的**原始 `set-cookie` 串** */
  set(cookieName: string, cookieRaw: string, expiresAtMs: number, authority: string,
    dshHost: string, dshPort: number): void {
    this.cookieName = cookieName;
    this.cookieRaw = cookieRaw;
    this.expiresAtMs = expiresAtMs;
    this.authorityValue = authority;
    this.dshHost = dshHost;
    this.dshPortValue = dshPort;
    this.pairedAtMsValue = Date.now();
    this.rejected = false;
  }

  /** 送进 `Cookie` 头的值＝`set-cookie` 首段 `name=value`（原始串带属性，整串送是错的） */
  get(): string {
    const head: string = this.cookieRaw.split(';')[0].trim();
    if (head.length > 0) {
      return head;
    }
    return this.cookieName.length > 0 ? `${this.cookieName}=` : '';
  }

  has(): boolean {
    return this.get().length > 0;
  }

  /** 唯一可对外显示的信息：**长度** */
  length(): number {
    return this.get().length;
  }

  pairedAtMs(): number {
    return this.pairedAtMsValue;
  }

  expiresAt(): number {
    return this.expiresAtMs;
  }

  authorityName(): string {
    return this.authorityValue;
  }

  /** 插件地址：取过凭据就用当场记下的（同一个 authority 才有效），否则退回调用方给的默认值 */
  hostOr(fallback: string): string {
    return this.dshHost.length > 0 ? this.dshHost : fallback;
  }

  /** 插件端口：取过凭据就用当场记下的 */
  portOr(fallback: number): number {
    return this.dshPortValue > 0 ? this.dshPortValue : fallback;
  }

  /**
   * 插件铸凭据时绑定的 authority（`127.0.0.1:<dsh端口>`）。
   * dsh 的围栏与签名 Cookie 都按它判 ⇒ 发请求的 `Host` 必须与它**完全一致**。
   */
  authorityOr(fallback: string): string {
    return this.authorityValue.length > 0 ? this.authorityValue : fallback;
  }

  /** 到期前 `RENEW_WINDOW_MS` 内、或带凭据的请求刚见过 401 ⇒ 该续期（**一次** claim） */
  needsRenewal(nowMs: number): boolean {
    if (!this.has()) {
      return false;
    }
    if (this.rejected) {
      return true;
    }
    return this.expiresAtMs > 0 && nowMs >= this.expiresAtMs - RENEW_WINDOW_MS;
  }

  /** `DshApiClient` 带凭据的请求见到 401 时调用（只置标记，**不在这里发请求**，免得把重试风暴引进传输层） */
  markRejected(): void {
    this.rejected = true;
  }

  clearRejected(): void {
    this.rejected = false;
  }

  /** 清空内存态（用户显式"重配"时用；**不落盘** ⇒ 没有文件要删） */
  clear(): void {
    this.cookieName = '';
    this.cookieRaw = '';
    this.expiresAtMs = 0;
    this.authorityValue = '';
    this.dshHost = '';
    this.dshPortValue = 0;
    this.pairedAtMsValue = 0;
    this.rejected = false;
  }
}

/** 全应用共用一份 */
export const pairingVault: PairingVaultImpl = new PairingVaultImpl();
