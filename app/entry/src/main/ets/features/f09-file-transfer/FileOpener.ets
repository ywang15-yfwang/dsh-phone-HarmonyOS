import { common, Want } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DshApiClient, DshApiResult } from '../../services/DshApiClient';
import { NetTarget, streamToFile, writeAllSync } from '../../services/net/DshNet';
import { pairTarget } from '../../services/PairTarget';
import { TransportTarget } from '../../channel/FileTransport';
import { mimeOf } from '../../model/MediaTypes';
import { IMAGE_LIMIT_BYTES, VIDEO_LIMIT_BYTES, limitMessageFor } from './TransferLimits';
import { ensureTempDirIn } from '../../services/TempFiles';

/**
 * 打开/保存对话里的文件。
 *
 * **打开**（点卡片）：取到手机沙箱，然后用系统 `Want(action=viewData)` 交给能打开它的应用。
 * **保存到手机**（客户 2026-10-18：对话里的东西要能下载到手机上）：
 *   用官方 `picker.DocumentViewPicker.save()` 弹系统保存对话框 → 用户选位置 → 我们把字节写进那个 uri，
 *   文件就落在**用户存储**里（文件管理能看到），不是 App 沙箱。
 *
 * 三种来源：
 *  - 用户自己刚挑过的本机文件（选择器 uri）：直接打开/直接复制；
 *  - 电脑上的绝对路径（正文链接、`present` 卡片）：`GET /api/file?path=` 流式落盘；
 *  - 附件（`attachmentId`）：官方 `session/attachment`，**只服务图片**（源码 `readImage`），非图片取不到。
 */
const DOMAIN: number = 0xD001;
const TAG: string = 'F8FILE';

export interface OpenFileResult {
  ok: boolean;
  /** 落盘后的本地路径（失败时为空） */
  localPath: string;
  /** 人话结果（成功/失败都能直接显示） */
  message: string;
  /** 失败是否"终态"（超限等）：上层不要再走回落链，否则会白传/换一条错误文案 */
  terminal?: boolean;
}

/** 每次下载用唯一临时名：同一附件连点两次「保存/打开」时不会并发覆盖同一个文件 */
function tempPath(sandboxDir: string, localName: string): string {
  return `${sandboxDir}/dl-${Date.now()}-${Math.floor(Math.random() * 100000)}-${localName}`;
}

function safeName(name: string, fallback: string): string {
  const trimmed: string = name.trim();
  const base: string = trimmed.length > 0 ? trimmed : fallback;
  const cut: number = Math.max(base.lastIndexOf('/'), base.lastIndexOf('\\'));
  const leaf: string = cut >= 0 ? base.substring(cut + 1) : base;
  return leaf.length > 0 ? leaf : fallback;
}

/** 交给系统打开时的 MIME —— **统一走 `model/MediaTypes`**（视频/音频必须给对，否则找不到播放器） */
function guessMime(name: string): string {
  return mimeOf(name);
}

async function startView(ctx: common.Context, uri: string, type: string): Promise<boolean> {
  try {
    const want: Want = { action: 'ohos.want.action.viewData', uri: uri, type: type, flags: 1 };
    const abilityCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
    await abilityCtx.startAbility(want);
    return true;
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'F8FILE 没有应用能打开 code=%{public}d %{public}s', e.code ?? -1, e.message);
    return false;
  }
}

/** 已经在本机了：直接交给系统打开 */
export async function openLocalFile(localPath: string, name: string, ctx: common.Context): Promise<OpenFileResult> {
  const opened: boolean = await startView(ctx, fileUri.getUriFromPath(localPath), guessMime(name));
  if (opened) {
    return { ok: true, localPath: localPath, message: `已打开 ${name}` };
  }
  return { ok: false, localPath: localPath, message: `这台设备没有能打开 ${name} 的应用（已下载到手机）` };
}

/** 本机已有的文件（选择器给的 uri）：直接交给系统打开 */
export async function openPickedUri(uri: string, name: string, ctx: common.Context): Promise<OpenFileResult> {
  const opened: boolean = await startView(ctx, uri, guessMime(name));
  if (opened) {
    return { ok: true, localPath: uri, message: `已打开 ${name}` };
  }
  return { ok: false, localPath: uri, message: `这台设备没有能打开 ${name} 的应用` };
}

function copyFileBytes(srcPath: string, destPath: string): void {
  const src: fileIo.File = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY);
  let dst: fileIo.File | undefined = undefined;
  try {
    dst = fileIo.openSync(destPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const buffer: ArrayBuffer = new ArrayBuffer(64 * 1024);
    let read: number = fileIo.readSync(src.fd, buffer);
    while (read > 0) {
      // writeSync 可能短写：必须按返回值循环写满，不能当整块写完
      let off: number = 0;
      while (off < read) {
        const wrote: number = fileIo.writeSync(dst.fd, buffer.slice(off, read));
        if (wrote <= 0) {
          throw new Error('写文件失败（0 字节）');
        }
        off += wrote;
      }
      read = fileIo.readSync(src.fd, buffer);
    }
  } catch (error) {
    // 写一半失败：删掉半截目标文件，免得用户拿到坏文件（审查 2026-10-22）
    try {
      fileIo.unlinkSync(destPath);
    } catch (cleanupError) {
      // 已经不存在
    }
    throw error as Error;
  } finally {
    if (dst !== undefined) {
      try {
        fileIo.closeSync(dst);
      } catch (closeDstError) {
        // 忽略
      }
    }
    try {
      fileIo.closeSync(src);
    } catch (closeSrcError) {
      // 忽略
    }
  }
}

/**
 * 沙箱里的一份文件复制到用户选的保存位置（**只用系统保存对话框**）。
 * 客户 2026-10-20：`save()` 本身就是"选目录 + 填名字 + 打勾"，我们不要再自己弹一次目录；
 * 取消就静默，不留字。
 */
async function saveCopyToUser(srcPath: string, name: string, ctx: common.Context): Promise<OpenFileResult> {
  const leaf: string = safeName(name, 'file.bin');
  const options: picker.DocumentSaveOptions = { newFileNames: [leaf] };
  let uris: string[];
  try {
    const saver: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    uris = await saver.save(options);
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'F8FILE 保存对话框失败 %{public}s', e.message);
    return { ok: false, localPath: '', message: `保存失败：${e.message}` };
  }
  if (uris.length === 0) {
    return { ok: false, localPath: '', message: '' };
  }
  const dest: string = uris[0];
  try {
    copyFileBytes(srcPath, dest);
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, 'F8FILE 写保存位置失败 %{public}s', e.message);
    return { ok: false, localPath: '', message: `保存失败：${e.message}` };
  }
  return { ok: true, localPath: dest, message: `已保存：${leaf}` };
}

/** 附件（`sha256:…`）落到沙箱 */
export async function fetchAttachment(client: DshApiClient, sessionId: string, attachmentId: string,
  name: string, sandboxDir: string): Promise<OpenFileResult> {
  const localName: string = safeName(name, 'attachment.bin');
  const args: string = `{"request":{"sessionId":${JSON.stringify(sessionId)},` +
    `"attachmentId":${JSON.stringify(attachmentId)}}}`;
  // 图片原图 base64 可达 27MB+：默认 15s 总超时在慢尾网必然不够
  const fetched: DshApiResult = await client.rpc('session/attachment', args, 120000);
  if (!fetched.apiOk) {
    return { ok: false, localPath: '', message: '' };
  }
  let base64Text: string = '';
  try {
    const parsed: Record<string, Object> = JSON.parse(fetched.body) as Record<string, Object>;
    const resultValue: Object | undefined = parsed['result'];
    if (resultValue !== undefined && resultValue !== null) {
      const valueValue: Object | undefined = (resultValue as Record<string, Object>)['value'];
      if (valueValue !== undefined && valueValue !== null) {
        const dataValue: Object | undefined = (valueValue as Record<string, Object>)['data'];
        if (typeof dataValue === 'string') {
          base64Text = dataValue as string;
        }
      }
    }
  } catch (parseError) {
    return { ok: false, localPath: '', message: '附件响应不是 JSON' };
  }
  if (base64Text.length === 0) {
    return { ok: false, localPath: '', message: '附件内容是空的' };
  }
  if (base64Text.length > Math.ceil(IMAGE_LIMIT_BYTES * 4 / 3)) {
    return { ok: false, localPath: '', message: '图片太大' };
  }
  let bytes: Uint8Array;
  try {
    bytes = new util.Base64Helper().decodeSync(base64Text);
  } catch (decodeError) {
    return { ok: false, localPath: '', message: '附件解码失败' };
  }
  const localPath: string = tempPath(ensureTempDirIn(sandboxDir), localName);
  try {
    const file: fileIo.File = fileIo.openSync(localPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      // decodeSync 返回的 Uint8Array 可能只是大 buffer 的一段：必须按 byteOffset/byteLength 切
      const body: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      writeAllSync(file.fd, body);
    } finally {
      fileIo.closeSync(file);
    }
  } catch (writeError) {
    try {
      fileIo.unlinkSync(localPath);
    } catch (unlinkError) {
      // 本来就没落盘
    }
    const e = writeError as BusinessError;
    return { ok: false, localPath: '', message: `落盘失败：${e.message}` };
  }
  return { ok: true, localPath: localPath, message: '' };
}

/** 电脑上的绝对路径文件 → 沙箱 */
export async function fetchRemotePath(remotePath: string, name: string, sandboxDir: string): Promise<OpenFileResult> {
  const localName: string = safeName(name.length > 0 ? name : remotePath, 'file.bin');
  const localPath: string = tempPath(ensureTempDirIn(sandboxDir), localName);
  const base: TransportTarget = pairTarget();
  const target: NetTarget = {
    address: base.address, port: base.port,
    hostHeader: base.hostHeader, cookie: base.cookie, tsTarget: undefined, pathPrefix: base.pathPrefix
  };
  const res = await streamToFile(target, `/api/file?path=${encodeURIComponent(remotePath)}`, localPath,
    VIDEO_LIMIT_BYTES);
  if (res.overLimit) {
    return { ok: false, localPath: '', message: limitMessageFor(name.length > 0 ? name : remotePath), terminal: true };
  }
  if (res.bytesWritten < 0) {
    return { ok: false, localPath: '', message: `取文件失败（HTTP ${res.statusCode}）` };
  }
  return { ok: true, localPath: localPath, message: '' };
}

/**
 * **经插件按文件名取附件**（`/pair/media-by-name/<名>`）—— 视频 / 文档都能取。
 *
 * 为什么不用 dsh 自己的 `session/attachment`：那个接口**只服务图片**
 * （`dsh-api-session-controller` 的 `attachment()` = `referencedImage` + `readImage`），
 * 电脑发来的视频/文档拿不到字节 ⇒ 手机侧 "保存 / 打开" 都会哑掉。
 */
export async function fetchByNameViaPlugin(name: string, sandboxDir: string): Promise<OpenFileResult> {
  const localName: string = safeName(name, 'file.bin');
  const localPath: string = tempPath(ensureTempDirIn(sandboxDir), localName);
  const base: TransportTarget = pairTarget();
  const target: NetTarget = {
    address: base.address, port: base.port,
    hostHeader: base.hostHeader, cookie: base.cookie, tsTarget: undefined, pathPrefix: ''
  };
  const res = await streamToFile(target, `/pair/media-by-name/${encodeURIComponent(name)}`, localPath,
    VIDEO_LIMIT_BYTES);
  if (res.overLimit) {
    return { ok: false, localPath: '', message: limitMessageFor(name), terminal: true };
  }
  if (res.bytesWritten < 0) {
    return { ok: false, localPath: '', message: `取文件失败（HTTP ${res.statusCode}）` };
  }
  return { ok: true, localPath: localPath, message: '' };
}

/** 从插件按名取到沙箱，再用**系统**打开 */
export async function openByNameViaPlugin(name: string, sandboxDir: string,
  ctx: common.Context): Promise<OpenFileResult> {
  const fetched: OpenFileResult = await fetchByNameViaPlugin(name, sandboxDir);
  if (!fetched.ok) {
    return fetched;
  }
  return openLocalFile(fetched.localPath, name, ctx);
}

/** 取附件到沙箱后打开 */
export async function openAttachment(client: DshApiClient, sessionId: string, attachmentId: string,
  name: string, sandboxDir: string, ctx: common.Context): Promise<OpenFileResult> {
  const fetched: OpenFileResult = await fetchAttachment(client, sessionId, attachmentId, name, sandboxDir);
  if (!fetched.ok) {
    return fetched;
  }
  return openLocalFile(fetched.localPath, name, ctx);
}

/** 电脑上的绝对路径文件：流式落到沙箱，然后交给系统打开 */
export async function openRemotePath(remotePath: string, name: string, sandboxDir: string,
  ctx: common.Context): Promise<OpenFileResult> {
  const fetched: OpenFileResult = await fetchRemotePath(remotePath, name, sandboxDir);
  if (!fetched.ok) {
    return fetched;
  }
  return openLocalFile(fetched.localPath, name, ctx);
}

/**
 * **保存到手机**（客户 2026-10-18）：取到沙箱 → 弹系统保存对话框 → 写进用户存储。
 * 取不到内容时返回空 message（界面不弹提示）。
 */
export async function saveToPhone(client: DshApiClient, sessionId: string, attachmentId: string,
  remotePath: string, name: string, sandboxDir: string, ctx: common.Context,
  localUri: string = ''): Promise<OpenFileResult> {
  if (localUri.length > 0) {
    // 用户自己挑的本机文件：先复制到沙箱（唯一临时名），再走保存
    const copyPath: string = tempPath(ensureTempDirIn(sandboxDir), `save-${safeName(name, 'file.bin')}`);
    try {
      copyFileBytes(localUri, copyPath);
    } catch (error) {
      const e = error as BusinessError;
      return { ok: false, localPath: '', message: `保存失败：${e.message}` };
    }
    const saved: OpenFileResult = await saveFetched(copyPath, name, ctx);
    // 保存完就删临时副本（用户存储里已经有一份了）
    try {
      fileIo.unlinkSync(copyPath);
    } catch (cleanupError) {
      // 忽略
    }
    return saved;
  }
  let fetched: OpenFileResult;
  // **电脑发来的**（视频 / 文档 / 图片都走这条）：经插件按文件名取，别再赌 dsh 那个只读图片的接口。
  fetched = await fetchByNameViaPlugin(name, sandboxDir);
  if (!fetched.ok && fetched.terminal !== true && attachmentId.length > 0) {
    // 兜底：图片还能走 dsh 的 `session/attachment`
    fetched = await fetchAttachment(client, sessionId, attachmentId, name, sandboxDir);
  }
  if (!fetched.ok && fetched.terminal !== true && remotePath.length > 0) {
    fetched = await fetchRemotePath(remotePath, name, sandboxDir);
  }
  if (!fetched.ok) {
    return fetched;
  }
  const saved: OpenFileResult = await saveFetched(fetched.localPath, name, ctx);
  // 保存完就删临时副本
  try {
    fileIo.unlinkSync(fetched.localPath);
  } catch (cleanupError) {
    // 忽略
  }
  return saved;
}

/**
 * 统一出口（客户 2026-10-20 定）：**只用系统保存对话框**。
 * 踩过的坑：`DocumentViewPicker.save()` 本身就已经是"选目录 + 填名字 + 打勾"；
 * 我又在它前面加了一次 `select(FOLDER)` ⇒ 用户要点两次勾，还因为拿不到目录列表把同名文件覆盖了。
 * 现在不再自己选目录、不再自己判重：名字、目录、重名冲突全部交给系统对话框。
 */
async function saveFetched(srcPath: string, name: string, ctx: common.Context): Promise<OpenFileResult> {
  return saveCopyToUser(srcPath, name, ctx);
}
