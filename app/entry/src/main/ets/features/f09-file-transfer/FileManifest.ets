/**
 * FileManifest —— F6/AC-07 需要的「目录结构 + 逐文件 SHA256」清单。
 *
 * 【预验】提前验证产物：不作通过、不进验收结论；真机按正式顺序重跑，以真机为准。
 *
 * 为什么要有它：AC-07 的通过条件 ②③ 要求
 *   「文本文件与图片**两侧 SHA256 完全一致**」「文件夹传输后**目标端目录结构与文件清单一致**、**逐文件哈希一致**」。
 *   ⇒ 传输前后要有一份**可比对的清单**：相对路径 + 字节数 + 逐文件 SHA256。
 *
 * 用系统能力算哈希（不自研摘要算法）：`hash.hash(path, 'sha256')` —— `@kit.CoreFileKit`，
 *   `js-apis-file-hash.md:72-75`；返回**十六进制串**（**大写**）⇒ 本文件统一**归一成小写**，
 *   以便与宿主侧 `Get-FileHash` / `sha256sum` 的输出直接 `===` 比对（AC-07 的判据要能客观比对）。
 *
 * 按 F14/G3（文件落盘受控）：本文件只**读**沙箱内的文件、只产出清单；不移动、不删除、不写盘。
 */

import { fileIo } from '@kit.CoreFileKit';
import { hash } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SizeEntry } from './TransferLimits';

const DOMAIN: number = 0xD001;
const TAG: string = 'P2CH-MANIFEST';

/** 清单里的一条 = 一个**文件**（空目录单独记，见 `emptyDirs`）。 */
export interface ManifestEntry {
  /** 相对根目录的路径，**一律用 `/` 分隔**（两侧比对时不会再纠结分隔符） */
  relativePath: string;
  bytes: number;
  /** SHA256 十六进制小写；未算（-skipHash）时为空串 */
  sha256: string;
}

export interface FileManifest {
  rootPath: string;
  entries: ManifestEntry[];
  /** 空目录的相对路径（AC-07 的"目录结构一致"要能看出空目录） */
  emptyDirs: string[];
  totalBytes: number;
  fileCount: number;
  /** 采集过程中的非致命问题（如某文件读取失败）——**如实列出，不吞** */
  problems: string[];
}

/** 把路径统一成 `/` 分隔（比对用）。 */
export function normalizeRelative(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/+/g, '/');
}

function joinRelative(base: string, name: string): string {
  if (base.length === 0) {
    return name;
  }
  return `${base}/${name}`;
}

/** 算一个文件的 SHA256（十六进制**小写**）。 */
export async function sha256OfFile(absPath: string): Promise<string> {
  const value: string = await hash.hash(absPath, 'sha256');
  return value.toLowerCase();
}

export interface WalkOptions {
  /** 跳过算哈希（只量体积；用于"先算总量再决定要不要传"的快路径） */
  skipHash?: boolean;
  /** 单文件超过此值即放弃算哈希（保护内存/时间；0 = 不限） */
  hashSizeLimitBytes?: number;
}

/**
 * 递归采集一个目录的清单。
 * @param dirPath 绝对路径（沙箱内或用户显式选定）
 */
export async function walkDirectory(dirPath: string, options?: WalkOptions): Promise<FileManifest> {
  const manifest: FileManifest = {
    rootPath: dirPath,
    entries: [],
    emptyDirs: [],
    totalBytes: 0,
    fileCount: 0,
    problems: []
  };
  await walkInto(dirPath, '', manifest, options ?? {});
  return manifest;
}

async function walkInto(absDir: string, relativeDir: string, manifest: FileManifest, options: WalkOptions): Promise<boolean> {
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(absDir);
  } catch (error) {
    const e = error as BusinessError;
    manifest.problems.push(`列目录失败 ${absDir}：code=${e.code ?? -1} ${e.message}`);
    return false;
  }
  let subDirCount: number = 0;
  let hasFiles: boolean = false;
  for (const name of names) {
    const childAbs: string = `${absDir}/${name}`;
    const childRelative: string = joinRelative(relativeDir, name);
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(childAbs);
    } catch (error) {
      const e = error as BusinessError;
      manifest.problems.push(`stat 失败 ${childRelative}：code=${e.code ?? -1} ${e.message}`);
      continue;
    }
    if (stat.isDirectory()) {
      subDirCount += 1;
      // 让子树回报"有没有文件"：空子树只记一次，避免父子重复记同一个空目录
      const childHasFiles: boolean = await walkInto(childAbs, childRelative, manifest, options);
      if (!childHasFiles) {
        manifest.emptyDirs.push(childRelative);
      }
      hasFiles = hasFiles || childHasFiles;
      continue;
    }
    const bytes: number = stat.size;
    let digest: string = '';
    if (options.skipHash !== true) {
      const limit: number = options.hashSizeLimitBytes ?? 0;
      if (limit > 0 && bytes > limit) {
        manifest.problems.push(`跳过大文件哈希（${childRelative}：${bytes} 字节 > ${limit}）`);
      } else {
        try {
          digest = await sha256OfFile(childAbs);
        } catch (error) {
          const e = error as BusinessError;
          manifest.problems.push(`哈希失败 ${childRelative}：code=${e.code ?? -1} ${e.message}`);
        }
      }
    }
    manifest.entries.push({ relativePath: normalizeRelative(childRelative), bytes: bytes, sha256: digest });
    manifest.totalBytes += bytes;
    manifest.fileCount += 1;
    hasFiles = true;
  }
  if (subDirCount === 0 && relativeDir.length === 0 && !hasFiles) {
    manifest.emptyDirs.push('');
  }
  return hasFiles;
}





