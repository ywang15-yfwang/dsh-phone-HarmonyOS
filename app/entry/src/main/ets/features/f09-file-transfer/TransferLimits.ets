import { isImageName, isVideoName } from '../../model/MediaTypes';

/**
 * 传输上限（客户 2026-10-21 定稿，按类型分）：
 *  - 图片 **20MB**，超限提示「图片太大」；
 *  - 文档 / 其它文件 **20MB**，提示「文件太大」；
 *  - 视频 **150MB**，提示「视频太大」。
 *
 * 纪律：**超限在发起任何请求之前就拒绝**，不留半截残文件。
 * 提示文案要短（客户口径），且界面上**几秒后自动消失**（由界面负责）。
 */
export const IMAGE_LIMIT_BYTES: number = 20 * 1024 * 1024;
export const FILE_LIMIT_BYTES: number = 20 * 1024 * 1024;
export const VIDEO_LIMIT_BYTES: number = 150 * 1024 * 1024;

export interface SizeEntry {
  /** 相对路径 / 文件名（用于按类型判上限、以及提示可读性） */
  relativePath: string;
  bytes: number;
}

export interface LimitDecision {
  allowed: boolean;
  /** 本次传输的总字节数 */
  totalBytes: number;
  /** 参与计数的文件数 */
  fileCount: number;
  /** 被拒时给用户看的**短**文案（允许时为空） */
  message: string;
  /** 超出的字节数（未超限为 0） */
  overByBytes: number;
}

/** 单个文件的上限（按扩展名分类） */
export function limitBytesFor(name: string): number {
  if (isImageName(name)) {
    return IMAGE_LIMIT_BYTES;
  }
  if (isVideoName(name)) {
    return VIDEO_LIMIT_BYTES;
  }
  return FILE_LIMIT_BYTES;
}

/** 该类型的超限提示（客户要求就一句话） */
export function limitMessageFor(name: string): string {
  if (isImageName(name)) {
    return '图片太大';
  }
  if (isVideoName(name)) {
    return '视频太大';
  }
  return '文件太大';
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KiB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(2)} MiB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GiB`;
}

/**
 * 判定一次传输是否放行：**逐个文件按类型判**（图片/文档 20MB、视频 150MB）。
 * 文件夹 = 递归后的全部文件，逐个判；不再有"整批总量"这一条（客户要的是按类型）。
 */
export function checkTransferLimit(entries: SizeEntry[]): LimitDecision {
  let total = 0;
  for (const entry of entries) {
    if (entry.bytes < 0) {
      return {
        allowed: false,
        totalBytes: 0,
        fileCount: entries.length,
        message: `文件大小异常（${entry.relativePath}）`,
        overByBytes: 0
      };
    }
    total += entry.bytes;
    const limit: number = limitBytesFor(entry.relativePath);
    if (entry.bytes > limit) {
      return {
        allowed: false,
        totalBytes: total,
        fileCount: entries.length,
        overByBytes: entry.bytes - limit,
        message: limitMessageFor(entry.relativePath)
      };
    }
  }
  return {
    allowed: true,
    totalBytes: total,
    fileCount: entries.length,
    message: '',
    overByBytes: 0
  };
}

/** 单个文件的快速判定（不看目录）。 */
export function checkSingleFile(bytes: number, displayName: string): LimitDecision {
  return checkTransferLimit([{ relativePath: displayName, bytes: bytes }]);
}
