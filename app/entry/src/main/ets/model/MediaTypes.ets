/**
 * **媒体类型的唯一来源** —— 全包只在这里按后缀判类型、只在这里给出 MIME。
 *
 * 为什么要有这个文件（客户 2026-10-21 的原话："你犯了和图片一样的错误，不知道举一反三"）：
 * 之前按后缀判类型是**一个类型一个类型散着写的** —— 图片在三处各有一份后缀表，
 * 视频/音频根本没有表，于是：
 *   · 发视频 → 落到"普通文件"分支（只做上传，没有本地预览/内联）；
 *   · 点开视频 → `guessMime` 回 `application/octet-stream` ⇒ 系统没有应用能接 ⇒ **不调播放器**；
 *   · 各处判断互不一致，改一个漏一个。
 * ⇒ 现在把「判类型 + 给 MIME」收成一处：**加新类型只改这里**，别处一律调它。
 *
 * 纪律：后缀一律先小写再比；表里没有的按二进制处理（`application/octet-stream`），
 * **不要"猜"成图片**。
 */

function lowerOf(name: string): string {
  return name.toLowerCase();
}

function hasSuffix(lower: string, list: string[]): boolean {
  for (let i = 0; i < list.length; i++) {
    if (lower.endsWith(list[i])) {
      return true;
    }
  }
  return false;
}

const IMAGE_EXT: string[] = ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp', '.heic'];
/**
 * 只用于"**远端图片内联显示**"的那一份（`InlineImageLoader`）：
 * 比 `IMAGE_EXT` 少 heic/heif —— 这条路的解码器对 HEIC 支持不稳，历史上就没让它进来。
 * ⚠️ 这不是忘了合并，是**故意的**：合并会让原本显示成文件卡片的 heic 改走解码，属于改行为。
 */
const IMAGE_INLINE_EXT: string[] = ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'];
const VIDEO_EXT: string[] = ['.mp4', '.m4v', '.mov', '.3gp', '.3g2', '.mkv', '.webm', '.avi', '.flv', '.wmv'];
const AUDIO_EXT: string[] = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac', '.amr', '.opus', '.wma'];

/** 是不是图片（决定：内联发送 / 附件条给缩略图）—— **集合与改造前完全一致**，不要随手加类型 */
export function isImageName(name: string): boolean {
  return hasSuffix(lowerOf(name), IMAGE_EXT);
}

/** 远端图片能不能内联解码显示（集合与改造前一致） */
export function isInlineImagePath(path: string): boolean {
  return hasSuffix(lowerOf(path), IMAGE_INLINE_EXT);
}

/** 是不是视频（决定：点开要调系统播放器、不要当图片去解） */
export function isVideoName(name: string): boolean {
  return hasSuffix(lowerOf(name), VIDEO_EXT);
}

/** 是不是音频 */
export function isAudioName(name: string): boolean {
  return hasSuffix(lowerOf(name), AUDIO_EXT);
}

/**
 * 交给系统打开时用的 MIME。
 * ⚠️ 视频/音频**必须**给对（`video/*`、`audio/*`），否则 `Want(action=viewData)` 找不到播放器
 * —— 这是"发了视频手机端不播放"的直接原因之一。
 */
export function mimeOf(name: string): string {
  const lower: string = lowerOf(name);
  // 图片
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.bmp')) {
    return 'image/bmp';
  }
  if (lower.endsWith('.heic')) {
    return 'image/heic';
  }
  if (lower.endsWith('.heif')) {
    return 'image/heif';
  }
  // 视频
  if (lower.endsWith('.mp4')) {
    return 'video/mp4';
  }
  if (lower.endsWith('.m4v')) {
    return 'video/x-m4v';
  }
  if (lower.endsWith('.mov')) {
    return 'video/quicktime';
  }
  if (lower.endsWith('.3gp')) {
    return 'video/3gpp';
  }
  if (lower.endsWith('.3g2')) {
    return 'video/3gpp2';
  }
  if (lower.endsWith('.mkv')) {
    return 'video/x-matroska';
  }
  if (lower.endsWith('.webm')) {
    return 'video/webm';
  }
  if (lower.endsWith('.avi')) {
    return 'video/x-msvideo';
  }
  if (lower.endsWith('.ts')) {
    // `.ts` 在 dsh 场景里几乎都是 TypeScript 源码；以前按 MPEG-TS 视频处理，会把源码当视频预览/按视频限额
    return 'text/plain';
  }
  if (lower.endsWith('.flv')) {
    return 'video/x-flv';
  }
  if (lower.endsWith('.wmv')) {
    return 'video/x-ms-wmv';
  }
  // 音频
  if (lower.endsWith('.mp3')) {
    return 'audio/mpeg';
  }
  if (lower.endsWith('.m4a')) {
    return 'audio/mp4';
  }
  if (lower.endsWith('.aac')) {
    return 'audio/aac';
  }
  if (lower.endsWith('.wav')) {
    return 'audio/wav';
  }
  if (lower.endsWith('.ogg')) {
    return 'audio/ogg';
  }
  if (lower.endsWith('.flac')) {
    return 'audio/flac';
  }
  if (lower.endsWith('.amr')) {
    return 'audio/amr';
  }
  if (lower.endsWith('.opus')) {
    return 'audio/opus';
  }
  if (lower.endsWith('.wma')) {
    return 'audio/x-ms-wma';
  }
  // 文档
  if (lower.endsWith('.pdf')) {
    return 'application/pdf';
  }
  if (lower.endsWith('.md') || lower.endsWith('.txt') || lower.endsWith('.log')) {
    return 'text/plain';
  }
  if (lower.endsWith('.json')) {
    return 'application/json';
  }
  if (lower.endsWith('.csv')) {
    return 'text/csv';
  }
  if (lower.endsWith('.html') || lower.endsWith('.htm')) {
    return 'text/html';
  }
  if (lower.endsWith('.zip')) {
    return 'application/zip';
  }
  if (lower.endsWith('.doc')) {
    return 'application/msword';
  }
  if (lower.endsWith('.docx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (lower.endsWith('.xls')) {
    return 'application/vnd.ms-excel';
  }
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (lower.endsWith('.ppt')) {
    return 'application/vnd.ms-powerpoint';
  }
  if (lower.endsWith('.pptx')) {
    return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  }
  return 'application/octet-stream';
}
