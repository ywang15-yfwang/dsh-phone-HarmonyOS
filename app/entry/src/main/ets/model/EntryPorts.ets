/**
 * **协议常量**（不含任何个人信息）。
 *
 * 历史教训（QC 实测）：同包出现两套端口默认值 ⇒ 假的"连接失败"；
 * 两条凭据路径用了两个端口 ⇒ 取凭据必失败。所以凡"跟协议有关"的常量都收在这里，
 * 且**不许再在别处写字面量**。
 *
 * 客户 2026-10-21 定稿：**端口、账号、本机路径一律不进包** ——
 * 那些值改由 `model/DeviceProfile` + 配置页按电脑逐台填写；
 * 本文件只留：dsh 端口默认值、插件路径前缀、电脑侧脚本的**固定约定位置**、超时。
 */

// dsh 端口的默认值只在 `model/DeviceProfile.DEFAULT_DSH_PORT` 一处（同包不许两套默认值）。

/**
 * **真机唯一通路**：dsh 只听电脑回环，tailnet 上唯一能到的门是配对插件。
 * 手机侧所有 dsh 请求都打 `插件地址:<插件端口>` + 本前缀，由插件转给本机 dsh（Host 改回环）。
 * 插件自己的 `/pair/info`、`/pair/claim` **不加**这个前缀。
 * （这是 App ↔ 插件的私约，不是 dsh 官方路由。）
 */
export const DSH_PATH_PREFIX: string = '/pair/dsh';

// ── 电脑侧脚本的**固定约定位置**（方案 A，客户 2026-10-21 选定）─────────────
// 电脑上一次性把三个脚本装到 `%LOCALAPPDATA%\dsh-phone\`；
// App 只发固定命令 ⇒ 安装包里**不出现任何本机路径**。
const SCRIPTS_DIR_ENV: string = '%LOCALAPPDATA%\\dsh-phone';

/**
 * 拉起 dsh 的**基础命令**（脚本语义：已在跑 → ALREADY；起成功 → READY；失败 → FAILED）。
 * ⚠️ 端口**不写在这条命令里**：由 `DshStarter` 追加 `-Port <配置页里的 dsh 端口>`
 * （客户 2026-10-22：手机端不许写死端口，要引用用户自己填的）。
 */
export const DSH_LAUNCH_COMMAND: string =
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${SCRIPTS_DIR_ENV}\\start.ps1"`;

/** 关掉 dsh 的**基础命令**（脚本语义：本来没跑 → ALREADY_STOPPED；关掉 → STOPPED；收不掉 → FAILED） */
export const DSH_STOP_COMMAND: string =
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${SCRIPTS_DIR_ENV}\\stop.ps1"`;

/** 关机（脚本语义：已排上倒计时 → SHUTTING_DOWN；失败 → FAILED；干跑 → WOULD_SHUTDOWN） */
export const DSH_POWER_COMMAND: string =
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${SCRIPTS_DIR_ENV}\\power.ps1"`;

export const SSH_LAUNCH_TIMEOUT_MS: number = 120000;
export const SSH_STOP_TIMEOUT_MS: number = 30000;
export const SSH_POWER_TIMEOUT_MS: number = 20000;
