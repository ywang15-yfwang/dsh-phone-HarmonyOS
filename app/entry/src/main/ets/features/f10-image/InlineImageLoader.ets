import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DshApiClient, DshApiResult } from '../../services/DshApiClient';
import { DownloadClient, DownloadOutcome, DownloadPolicy } from './DownloadClient';
import { LoadImageResult, loadImageFromFile } from './DshImage';
import { HttpTransport } from '../../channel/HttpTransport';
import { pairTarget } from '../../services/PairTarget';
import { isInlineImagePath } from '../../model/MediaTypes';
import { IMAGE_LIMIT_BYTES } from '../f09-file-transfer/TransferLimits';
import { ensureTempDirIn } from '../../services/TempFiles';

const DOMAIN: number = 0xD001;
const TAG: string = 'F7INLINE';

/**
 * **聊天里内嵌显示图片**（客户 2026-10-17：会话里说的图片要能看到）。
 *
 * 事实（抓真实事件看过，不是猜）：
 *  - 图片**不在 `assistant/message` 的 content 块里**（那里只有 `reasoning` / `tool-call` / `text`）；
 *  - 它出现在**工具调用**里：`present`（`files:[{path}]`）或 `show_image`（`paths:[…]`）——电脑侧 GUI 就是那样渲染成附件卡片的；
 *  - 取字节走 dsh 的文件路由 `GET /api/file?path=…`（现有的 `DownloadClient` 已经实现，含 Host 回环 + Cookie）。
 *
 * 落盘与白名单口径（沿用 `DownloadClient` 的既有纪律）：
 *  - **只落 App 沙箱**（`filesDir/imagecache`），不接受远端指定落盘路径；
 *  - 可读根的放行**只来自"会话自身声明的工作区"**（即该会话的 `cwd`，用它自己在手机侧的合法来源），
 *    远端给的路径**不自动进白名单**。
 */

/** 一次内嵌图片的加载结果（给界面用） */
export interface InlineImageResult {
  ok: boolean;
  /** 远端路径（原样，作唯一键） */
  path: string;
  pixelMap: image.PixelMap | undefined;
  detail: string;
}

/** 图片后缀（只认这几种，别的当普通文件不显示）—— 表在 `model/MediaTypes`，别在这里另写一份 */
export function isImagePath(path: string): boolean {
  return isInlineImagePath(path);
}

/** 文件名（同时压成沙箱安全名：去掉分隔符与非法字符） */
function safeNameOf(remotePath: string): string {
  const normalized: string = remotePath.replace(/\\/g, '/');
  const base: string = normalized.substring(normalized.lastIndexOf('/') + 1);
  const cleaned: string = base.replace(/[^A-Za-z0-9._-]/g, '_').slice(-60);
  // 用路径的简单散列做前缀，避免同名不同目录互相覆盖
  let hash: number = 0;
  for (let i = 0; i < normalized.length; i++) {
    hash = (hash * 31 + normalized.charCodeAt(i)) | 0;
  }
  return `${(hash >>> 0).toString(16)}-${cleaned.length > 0 ? cleaned : 'image'}`;
}

/**
 * 加载一张"电脑上的图片"→ PixelMap。
 * @param remotePath 电脑上的绝对路径（来自消息里的工具调用）
 * @param sessionCwd 该会话声明的工作区（**优先放行**；客户 2026-10-18 起不再作为唯一读取根）
 * @param sandboxDir App 沙箱目录（`filesDir`）
 * @param boxW/boxH  显示框（按框降采样，避免大图爆内存）
 */
export async function loadRemoteImage(remotePath: string, sessionCwd: string, sandboxDir: string,
  boxW: number, boxH: number, ctx: common.Context | undefined = undefined): Promise<InlineImageResult> {
  const fail = (detail: string): InlineImageResult => {
    hilog.warn(DOMAIN, TAG, 'F7INLINE fail %{public}s', detail);
    return { ok: false, path: remotePath, pixelMap: undefined, detail: detail };
  };
  if (!isImagePath(remotePath)) {
    return fail('不是图片后缀');
  }
  const policy: DownloadPolicy = new DownloadPolicy();
  // 先放行本场会话的工作区；**再放宽到任意绝对路径**（客户 2026-10-18）：
  // dsh 的 `/api/file` 服务端本就不限制路径，原来的"只看 cwd"会把 artifacts / shots 里的图挡掉。
  // 仍保留硬约束：绝对路径 / 不许 `..` / 不许 NUL。
  if (sessionCwd.length > 0) {
    policy.allowRootFromUserSelection(sessionCwd, 'session-workspace');
  }
  policy.allowAnyAbsolute();
  const client: DownloadClient = new DownloadClient(new HttpTransport(), policy);
  const out: DownloadOutcome = await client.downloadToSandbox(
    pairTarget(), remotePath, ensureTempDirIn(sandboxDir), safeNameOf(remotePath), 20 * 1024 * 1024, ctx);
  if (!out.ok) {
    return fail(`取图失败：${out.message}`);
  }
  const pixelMap: image.PixelMap | undefined = await new Promise<image.PixelMap | undefined>((resolve) => {
    loadImageFromFile(out.localPath, boxW, boxH, (result: LoadImageResult) => {
      if (!result.ok || result.pixelMap === undefined) {
        hilog.warn(DOMAIN, TAG, 'F7INLINE decode failed %{public}s', result.detail);
        resolve(undefined);
        return;
      }
      resolve(result.pixelMap);
    });
  });
  // 画面已经解到内存：磁盘上这份中转文件立刻删（客户要求：不留在手机上）
  try {
    fileIo.unlinkSync(out.localPath);
  } catch (cleanupError) {
    // 忽略
  }
  if (pixelMap === undefined) {
    return fail('解码失败（文件可能不是有效图片）');
  }
  hilog.info(DOMAIN, TAG, 'F7INLINE ok bytes=%{public}d show=%{public}s', out.bytes, out.message);
  return { ok: true, path: remotePath, pixelMap: pixelMap, detail: out.message };
}

/** 是不是"图片附件 id"（形如 `sha256:…`）；不是就当电脑上的文件路径 */
export function isAttachmentId(key: string): boolean {
  return key.startsWith('sha256:');
}

/**
 * 加载一张**图片附件**（用户自己发的图 / 助手回的图都可能是这种）。
 *
 * 为什么走另一条路：这种图**不在电脑的文件系统里**，它只有 `attachmentId`（`sha256:…`），
 * 要通过 dsh 的 `session/attachment` 接口取（它自带"必须被该会话引用过"的授权检查）——
 * 返回 base64，直接在内存里解码，不落盘。
 */
export async function loadAttachmentImage(client: DshApiClient, sessionId: string, attachmentId: string,
  boxW: number, boxH: number): Promise<InlineImageResult> {
  const fail = (detail: string): InlineImageResult => {
    hilog.warn(DOMAIN, TAG, 'F7INLINE attach fail %{public}s', detail);
    return { ok: false, path: attachmentId, pixelMap: undefined, detail: detail };
  };
  const args: string = `{"request":{"sessionId":${JSON.stringify(sessionId)},` +
    `"attachmentId":${JSON.stringify(attachmentId)}}}`;
  // 原图 base64 可能 27MB+：默认 15s 总超时不够（同一张图发送侧用的是 60–90s）
  const fetched: DshApiResult = await client.rpc('session/attachment', args, 120000);
  if (!fetched.apiOk) {
    return fail(`取图片失败（HTTP ${fetched.code}${fetched.apiError.length > 0 ? `｜${fetched.apiError}` : ''}）`);
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
    return fail('响应解析失败');
  }
  if (base64Text.length === 0) {
    return fail('接口没给图片数据');
  }
  if (base64Text.length > Math.ceil(IMAGE_LIMIT_BYTES * 4 / 3)) {
    return fail('图片太大');
  }
  let bytes: Uint8Array;
  try {
    bytes = new util.Base64Helper().decodeSync(base64Text);
  } catch (decodeError) {
    return fail('base64 解码失败');
  }
  let source: image.ImageSource | undefined = undefined;
  try {
    // 不整包复制：decodeSync 通常给的就是独占 buffer，只有分段时才切一份
    const buffer: ArrayBuffer = (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength)
      ? bytes.buffer as ArrayBuffer
      : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    source = image.createImageSource(buffer);
    const info: image.ImageInfo = await source.getImageInfo();
    const srcW: number = info.size.width;
    const srcH: number = info.size.height;
    const scale: number = Math.min(boxW / srcW, boxH / srcH, 1);
    const options: image.DecodingOptions = {
      desiredSize: {
        width: Math.max(1, Math.round(srcW * scale)),
        height: Math.max(1, Math.round(srcH * scale))
      }
    };
    const pixelMap: image.PixelMap = await source.createPixelMap(options);
    hilog.info(DOMAIN, TAG, 'F7INLINE attach ok %{public}dx%{public}d', srcW, srcH);
    return { ok: true, path: attachmentId, pixelMap: pixelMap, detail: `${srcW}×${srcH}` };
  } catch (decodeError) {
    return fail('图片解码失败');
  } finally {
    // 审查 2026-10-22：成功/失败两条出口都要 release，否则每张图漏一份解码缓冲
    if (source !== undefined) {
      try {
        source.release();
      } catch (releaseError) {
        // 已释放
      }
    }
  }
}
