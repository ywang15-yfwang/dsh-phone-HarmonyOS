import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * **每台电脑一份**的连接配置（客户 2026-10-21 定稿）。
 *
 * 为什么按电脑存：用户可能有多台电脑，端口/账号可能不一样。
 * 为什么不再写死在包里：这些都是"个人信息"（名字、端口、账号），
 * 包里只留**协议常量**（如 `/pair/dsh` 前缀、超时），具体值由用户在配置界面填。
 *
 * 铁律：
 *  - `pluginPort` / `sshPort` / `sshUser` **没有默认值**（有默认值等于把端口/账号告诉看包的人）；
 *  - `dshPort` 默认 `dsh 端口`（客户明确：这个可以有默认，允许改）；
 *  - 名字默认取 `deviceInfo.marketName`（营销名），用户可改。
 */
export interface DeviceProfile {
  /** 设备名（tailnet 节点名 + dsh claim 的 device 字段都用它） */
  name: string;
  /** dsh 端口（默认 dsh 端口，可改） */
  dshPort: number;
  /** 配对插件端口（**必填**，无默认） */
  pluginPort: number;
  /** SSH 端口（**必填**，无默认） */
  sshPort: number;
  /** SSH 用户名（**必填**，无默认） */
  sshUser: string;
  /** 是否已完成配对（电脑已写入本机公钥） */
  paired: boolean;
}

/** dsh 端口的默认值（客户：这个可以预置） */
export const DEFAULT_DSH_PORT: number = 3080;

/** 空配置（占位；保存前必须补齐必填项） */
export function emptyProfile(): DeviceProfile {
  return {
    name: systemDeviceName(),
    dshPort: DEFAULT_DSH_PORT,
    pluginPort: 0,
    sshPort: 0,
    sshUser: '',
    paired: false
  };
}

/**
 * 设备名解析（客户 2026-10-21）：
 * 配置里的名字 > `deviceInfo.marketName`（营销名）> `productModelAlias` > `productModel` > `MyPhone`。
 */
export function resolveDeviceName(configured: string): string {
  const trimmed: string = configured.trim();
  if (trimmed.length > 0) {
    return trimmed;
  }
  const marketing: string = safe(() => deviceInfo.marketName).trim();
  if (marketing.length > 0) {
    return marketing;
  }
  const alias: string = safe(() => deviceInfo.productModelAlias).trim();
  if (alias.length > 0) {
    return alias;
  }
  const model: string = safe(() => deviceInfo.productModel).trim();
  if (model.length > 0) {
    return model;
  }
  return 'MyPhone';
}

/** 系统营销名（配置默认值用） */
export function systemDeviceName(): string {
  return resolveDeviceName('');
}

/** 系统版本串（登录时上报给内核；不再写死） */
export function systemOsVersion(): string {
  const full: string = safe(() => deviceInfo.osFullName).trim();
  return full.length > 0 ? full : 'HarmonyOS';
}

function safe(read: () => string): string {
  try {
    const value: string = read();
    return typeof value === 'string' ? value : '';
  } catch (error) {
    return '';
  }
}

/** 保存前校验：返回人话错误（'' = 通过） */
export function profileProblem(p: DeviceProfile): string {
  if (p.name.trim().length === 0) {
    return '设备名不能为空';
  }
  if (!isPort(p.dshPort)) {
    return 'dsh 端口要填 1–65535 的数字';
  }
  if (!isPort(p.pluginPort)) {
    return '插件端口要填 1–65535 的数字';
  }
  if (!isPort(p.sshPort)) {
    return 'SSH 端口要填 1–65535 的数字';
  }
  if (p.sshUser.trim().length === 0) {
    return 'SSH 用户名不能为空';
  }
  return '';
}

function isPort(value: number): boolean {
  return Number.isInteger(value) && value > 0 && value <= 65535;
}


