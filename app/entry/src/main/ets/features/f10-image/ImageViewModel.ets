/**
 * F7（AC-08）图片显示的**纯逻辑**部分（零 Kit 依赖 ⇒ 可在本机 node 上直接断言）。
 *
 * AC-08 四条通过条件（原文，一字不改）：
 *  ① 截图中能辨认出 `DSH-IMG-OK`；② **比例正确**（不拉伸变形）；③ **透明 PNG** 显示正常；
 *  ④ **大图不崩溃、不长时间白屏**。
 *
 * 本文件负责其中**可判定、可复算**的部分：
 *  - `planDisplay`：在给定显示框内算**保比例**的绘制尺寸（②：宽高比必须与源图一致，不许拉伸）；
 *  - `planDecode`：**解码尺寸上限**（④：超大图先降采样再解码，避免 OOM/长时间白屏）；
 *  - `formatOf` / `isTransparentFormat`：③ 的格式判定（PNG 支持 alpha）；
 *  - `renderStateNote`：④ 的"白屏"判据 —— 把"从发起到首帧"的耗时如实说出来，超阈值就明示风险。
 *
 * ⚠️ 口径：这些函数**只算尺寸与状态**，**不判"通过"**；①（能辨认出 `DSH-IMG-OK`）只能靠**截图**判定，
 * 代码不许替它下结论。
 */

/** 显示框（vp 或 px 都行，只要同单位进出） */
export interface DisplayBox {
  width: number;
  height: number;
}

export interface DisplayPlan {
  /** 实际绘制尺寸（保比例） */
  drawWidth: number;
  drawHeight: number;
  /** 源图宽高比（w/h） */
  sourceRatio: number;
  /** 绘制尺寸的宽高比 */
  drawRatio: number;
  /** 是否**保持**了比例（浮点误差内相等） */
  ratioKept: boolean;
  /** 是否因超出显示框而被缩小 */
  scaledDown: boolean;
  /** 是否被放大过（我们不放大：放大只会糊，且没必要） */
  upscaled: boolean;
  note: string;
}

/** 浮点比较容差（比例只允许到小数第 6 位） */
const RATIO_EPS: number = 0.000001;

/**
 * 在 `box` 内**按 `contain` 语义**算保比例绘制尺寸（与 ArkUI `ImageFit.Contain` 同义）。
 * 退化输入（宽或高 ≤ 0）⇒ 返回 0 尺寸并如实说明，**不抛异常、不返回 NaN**。
 */
export function planDisplay(srcWidth: number, srcHeight: number, box: DisplayBox): DisplayPlan {
  if (srcWidth <= 0 || srcHeight <= 0 || box.width <= 0 || box.height <= 0) {
    return {
      drawWidth: 0, drawHeight: 0, sourceRatio: 0, drawRatio: 0,
      ratioKept: false, scaledDown: false, upscaled: false,
      note: `尺寸非法（源 ${srcWidth}×${srcHeight}，框 ${box.width}×${box.height}）⇒ 不绘制，如实标"未取到"`
    };
  }
  const sourceRatio: number = srcWidth / srcHeight;
  const boxRatio: number = box.width / box.height;
  let drawWidth: number = box.width;
  let drawHeight: number = box.height;
  if (sourceRatio > boxRatio) {
    // 源更宽 ⇒ 以宽为准
    drawHeight = box.width / sourceRatio;
  } else {
    drawWidth = box.height * sourceRatio;
  }
  const drawRatio: number = drawWidth / drawHeight;
  const ratioKept: boolean = Math.abs(drawRatio - sourceRatio) <= RATIO_EPS;
  // 是否缩小：源图在两个方向上都超出或至少一个方向超出
  const scaledDown: boolean = srcWidth > box.width || srcHeight > box.height;
  const upscaled: boolean = drawWidth > srcWidth + RATIO_EPS || drawHeight > srcHeight + RATIO_EPS;
  const note: string = ratioKept
    ? `保比例：源 ${srcWidth}×${srcHeight}（比 ${round6(sourceRatio)}）⇒ 画 ${round2(drawWidth)}×${round2(drawHeight)}` +
      `（比 ${round6(drawRatio)}）${scaledDown ? '｜已缩小以适配' : ''}${upscaled ? '｜被放大（不推荐）' : ''}`
    : `⚠️ 比例不一致：源比 ${round6(sourceRatio)} vs 画比 ${round6(drawRatio)}（这就是"拉伸变形"，不许出现）`;
  return {
    drawWidth: drawWidth, drawHeight: drawHeight, sourceRatio: sourceRatio, drawRatio: drawRatio,
    ratioKept: ratioKept, scaledDown: scaledDown, upscaled: upscaled, note: note
  };
}

function round6(v: number): number {
  return Math.round(v * 1000000) / 1000000;
}

function round2(v: number): number {
  return Math.round(v * 100) / 100;
}

/** 默认解码像素上限：4M 像素（≈ 2048×2048 / 2400×1600），超过就先降采样再解码 */
export const IMAGE_MAX_DECODE_PIXELS: number = 4000000;

export interface DecodePlan {
  decodeWidth: number;
  decodeHeight: number;
  /** 是否降过采样 */
  downscaled: boolean;
  /** 实际解码像素数 */
  pixels: number;
  note: string;
}

/**
 * ④ 的实现依据：**先按上限降采样再解码**（对超大图尤其重要 —— 原尺寸解码是"崩/白屏"的主因）。
 * 依据（源码级）：旧项目 `dsh-attachment/lib/index.js:221` 在服务端做白名单与规范化；
 * 客户端这侧由本函数保证"进解码器的像素数有上限"。
 */
export function planDecode(srcWidth: number, srcHeight: number,
  maxPixels: number = IMAGE_MAX_DECODE_PIXELS): DecodePlan {
  if (srcWidth <= 0 || srcHeight <= 0 || maxPixels <= 0) {
    return {
      decodeWidth: 0, decodeHeight: 0, downscaled: false, pixels: 0,
      note: `尺寸非法（${srcWidth}×${srcHeight}）⇒ 不解码`
    };
  }
  const pixels: number = srcWidth * srcHeight;
  if (pixels <= maxPixels) {
    return {
      decodeWidth: srcWidth, decodeHeight: srcHeight, downscaled: false, pixels: pixels,
      note: `原尺寸解码 ${srcWidth}×${srcHeight}（${pixels} 像素 ≤ 上限 ${maxPixels}）`
    };
  }
  const factor: number = Math.sqrt(maxPixels / pixels);
  const decodeWidth: number = Math.max(1, Math.floor(srcWidth * factor));
  const decodeHeight: number = Math.max(1, Math.floor(srcHeight * factor));
  return {
    decodeWidth: decodeWidth, decodeHeight: decodeHeight, downscaled: true,
    pixels: decodeWidth * decodeHeight,
    note: `大图降采样：${srcWidth}×${srcHeight}（${pixels} 像素）⇒ 解码 ${decodeWidth}×${decodeHeight}` +
      `（${decodeWidth * decodeHeight} 像素，上限 ${maxPixels}）`
  };
}

/** 按扩展名/路径取格式（小写）；认不出就返回 `unknown`（不猜） */
export function formatOf(name: string): string {
  const lower: string = name.toLowerCase();
  const dot: number = lower.lastIndexOf('.');
  if (dot < 0 || dot === lower.length - 1) {
    return 'unknown';
  }
  const ext: string = lower.substring(dot + 1);
  if (ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'webp' || ext === 'gif' || ext === 'bmp') {
    return ext === 'jpeg' ? 'jpg' : ext;
  }
  return 'unknown';
}

/** ③ 透明：只有 PNG/WEBP/GIF 具备 alpha 通道（jpg/bmp 无 ⇒ 透明图必须走这几类） */
export function isTransparentFormat(format: string): boolean {
  return format === 'png' || format === 'webp' || format === 'gif';
}

/** ④ 的"大图"门槛（宽度 ≥2000px 即按大图对待 —— 与 AC-08 判定用的测试图规格一致） */
export const IMAGE_LARGE_WIDTH_PX: number = 2000;


/** ④ 的"长时间白屏"阈值（发起到首帧超过它 ⇒ 明示"白屏风险"） */
export const IMAGE_WHITE_SCREEN_MS: number = 1500;

/**
 * ④：把"从发起到首帧"的耗时与状态**如实**说清楚（不给结论）。
 * `state`：`idle` / `loading` / `shown` / `failed`
 */
export function renderStateNote(state: string, elapsedMs: number, detail: string = ''): string {
  const tail: string = detail.length > 0 ? `｜${detail}` : '';
  if (state === 'idle') {
    return `未开始加载${tail}`;
  }
  if (state === 'loading') {
    return `加载中（已 ${elapsedMs}ms）${elapsedMs > IMAGE_WHITE_SCREEN_MS
      ? `｜⚠️ 已超过白屏阈值 ${IMAGE_WHITE_SCREEN_MS}ms ⇒ 如实标"长时间白屏风险"`
      : `（阈值 ${IMAGE_WHITE_SCREEN_MS}ms）`}${tail}`;
  }
  if (state === 'shown') {
    return `已显示首帧：耗时 ${elapsedMs}ms${elapsedMs > IMAGE_WHITE_SCREEN_MS
      ? `｜⚠️ 超过阈值 ${IMAGE_WHITE_SCREEN_MS}ms（如实记，不掩盖）`
      : `（在阈值 ${IMAGE_WHITE_SCREEN_MS}ms 内）`}${tail}`;
  }
  if (state === 'failed') {
    return `加载失败（${elapsedMs}ms）${tail}`;
  }
  return `状态未知：${state}${tail}`;
}

