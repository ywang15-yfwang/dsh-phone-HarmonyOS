import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'TMPFILES';

/** App 自己的临时目录名（所有下载/打开/保存的中转文件都放这里，方便整目录清） */
const TMP_DIR: string = 'dsh-tmp';

/** 确保 `<base>/dsh-tmp` 存在，返回该目录（base 一般是 context.filesDir） */
export function ensureTempDirIn(base: string): string {
  const dir: string = `${base}/${TMP_DIR}`;
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '创建临时目录失败：%{public}s', `${error}`);
  }
  return dir;
}

/** 用 App context 拿临时目录 */
export function tempDirOf(ctx: common.Context): string {
  return ensureTempDirIn(ctx.filesDir);
}

/** 这些是 App 的**状态文件/目录**，清缓存时不能删（删了会让 VPN/会话状态丢） */
const KEEP_NAMES: string[] = [
  'tailscale',
  'tailnet-address.txt',
  'vpn-extension-status.json',
  'vpn-status.json',
  'vpn-command.json',
  'vpn-response.json'
];

/**
 * 清临时目录 + **旧版本遗留在 filesDir 根下的中转文件**
 * （v5 之前下载的图片/文件直接落在根目录，文件名没有统一前缀，只能按"排除状态文件"来清）。
 */
export function cleanupTemp(ctx: common.Context): number {
  const dir: string = `${ctx.filesDir}/${TMP_DIR}`;
  let removed: number = 0;
  try {
    if (fileIo.accessSync(dir)) {
      const names: string[] = fileIo.listFileSync(dir, { recursion: true });
      for (let i = 0; i < names.length; i++) {
        try {
          fileIo.unlinkSync(`${dir}/${names[i]}`);
          removed += 1;
        } catch (unlinkError) {
          // 单个文件删不掉就跳过
        }
      }
      try {
        fileIo.rmdirSync(dir);
      } catch (rmdirError) {
        // 目录非空/已删除都忽略，下次还会再清
      }
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, '清理临时目录失败：%{public}s', `${error}`);
  }
  // 旧版本遗留：根目录下除状态文件外的普通文件/缓存目录
  try {
    const entries: string[] = fileIo.listFileSync(ctx.filesDir);
    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i];
      if (KEEP_NAMES.indexOf(name) >= 0) {
        continue;
      }
      const path: string = `${ctx.filesDir}/${name}`;
      try {
        const stat: fileIo.Stat = fileIo.statSync(path);
        if (stat.isDirectory()) {
          fileIo.rmdirSync(path);
        } else {
          fileIo.unlinkSync(path);
        }
        removed += 1;
      } catch (oneError) {
        // 删不掉的跳过（可能是系统目录）
      }
    }
  } catch (listError) {
    // 根目录列不出来就只清 dsh-tmp
  }
  if (removed > 0) {
    hilog.info(DOMAIN, TAG, '已清理临时文件 %{public}d 个', removed);
  }
  return removed;
}
