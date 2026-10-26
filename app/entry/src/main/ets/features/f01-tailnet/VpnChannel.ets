import { fileIo } from '@kit.CoreFileKit';

/**
 * 进程通道（契约 §4）：UI 进程 ↔ VPN 扩展进程。
 * 防陈旧三步（缺一不可）：`seq` 单调 + `issuedAtMs` TTL + **`.tmp`→rename 原子落盘**；
 * 响应**必须回显 `seq`**。
 */
export const STATUS_FILE: string = 'vpn-extension-status.json';
export const COMMAND_FILE: string = 'vpn-command.json';
export const RESPONSE_FILE: string = 'vpn-response.json';
export const COMMAND_TTL_MS: number = 10000;

export interface VpnCommand {
  seq: number;
  issuedAtMs: number;
  command: string;
  tunFd: number;
}

export interface VpnCommandResponse {
  seq: number;
  ok: boolean;
  code: string;
  message: string;
  atMs: number;
}

export function pathOf(filesDir: string, name: string): string {
  return `${filesDir}/${name}`;
}

export function readTextSafe(path: string): string {
  try {
    if (!fileIo.accessSync(path)) {
      return '';
    }
    return fileIo.readTextSync(path);
  } catch (error) {
    return '';
  }
}

/** 原子写：先写 `<path>.tmp` 再 rename 覆盖，避免读到半个 JSON */
export function writeTextAtomic(path: string, text: string): boolean {
  const tmp: string = `${path}.tmp`;
  let file: fileIo.File | undefined = undefined;
  try {
    file = fileIo.openSync(tmp,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, text);
    fileIo.closeSync(file);
    file = undefined;
    fileIo.renameSync(tmp, path);
    return true;
  } catch (error) {
    try {
      if (fileIo.accessSync(tmp)) {
        fileIo.unlinkSync(tmp);
      }
    } catch (cleanupError) {
      // 下次写入覆盖它
    }
    // 审查 2026-10-22：写/rename 失败时以前不 close ⇒ 每次落盘失败漏一个 fd
    if (file !== undefined) {
      try {
        fileIo.closeSync(file);
      } catch (closeError) {
        // 已关闭
      }
    }
    return false;
  }
}

// ── 命令（UI → 扩展） ────────────────────────────────────────────────

export function writeCommand(filesDir: string, command: VpnCommand): boolean {
  return writeTextAtomic(pathOf(filesDir, COMMAND_FILE), JSON.stringify(command));
}

export function readCommand(filesDir: string): VpnCommand | undefined {
  const text: string = readTextSafe(pathOf(filesDir, COMMAND_FILE));
  if (text.length === 0) {
    return undefined;
  }
  try {
    return JSON.parse(text) as VpnCommand;
  } catch (error) {
    return undefined;
  }
}

// ── 响应（扩展 → UI，回显 seq） ──────────────────────────────────────

export function writeResponse(filesDir: string, response: VpnCommandResponse): boolean {
  return writeTextAtomic(pathOf(filesDir, RESPONSE_FILE), JSON.stringify(response));
}

export function readResponse(filesDir: string): VpnCommandResponse | undefined {
  const text: string = readTextSafe(pathOf(filesDir, RESPONSE_FILE));
  if (text.length === 0) {
    return undefined;
  }
  try {
    return JSON.parse(text) as VpnCommandResponse;
  } catch (error) {
    return undefined;
  }
}
