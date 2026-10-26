import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DecodePlan, DisplayPlan, planDecode, planDisplay } from './ImageViewModel';

const DOMAIN: number = 0xD001;
const TAG: string = 'F7IMAGE';

/**
 * F7（AC-08）图片显示的**服务层**：造测试图 / 按上限解码沙箱里的图。
 *
 * 依据（文档级，先读后写）：
 *  - `image.createPixelMap(colors: ArrayBuffer, options: InitializationOptions): Promise<PixelMap>`
 *    （`references/arkts-apis-image-f.md:377`）＋ `InitializationOptions.{size,pixelFormat,alphaType}`（`…-i.md:35-39/113`）
 *    ⇒ **造图**：直接给 RGBA 字节。
 *  - `image.createImageSource(uri: string): ImageSource`（`…-f.md:1404`）＋ `ImageSource.getImageInfo`（`…-imagesource.md:30/65`）
 *    ＋ `DecodingOptions.desiredSize`（`…-i.md:126`）⇒ **解码前先拿原始尺寸、再按上限降采样**（AC-08④ 的实现基础）。
 *
 * 口径：**只产出"尺寸/耗时/像素图"**，不判"通过"；能不能辨认出 `DSH-IMG-OK` 只能靠截图判。
 */

export interface LoadImageResult {
  ok: boolean;
  pixelMap: image.PixelMap | undefined;
  srcWidth: number;
  srcHeight: number;
  /** 实际解码尺寸（按上限降采样后） */
  decodeWidth: number;
  decodeHeight: number;
  downscaled: boolean;
  /** 从发起到拿到像素图 */
  loadMs: number;
  /** 按 `planDisplay` 算出的保比例绘制尺寸说明（给界面用） */
  displayNote: string;
  detail: string;
}

/**
 * 从**沙箱里的文件**加载图片：先取原始尺寸 → `planDecode` 定解码上限 → 解码 → 交给界面显示。
 * `box` 是界面给显示框的尺寸（用于算保比例绘制尺寸，**只用于说明**；真正的 contain 由 ArkUI 的 `ImageFit.Contain` 保证）。
 */
export function loadImageFromFile(absPath: string, boxW: number, boxH: number,
  onDone: (result: LoadImageResult) => void): void {
  const started: number = Date.now();
  const fail = (detail: string): void => {
    onDone({
      ok: false, pixelMap: undefined, srcWidth: 0, srcHeight: 0, decodeWidth: 0, decodeHeight: 0,
      downscaled: false, loadMs: Date.now() - started, displayNote: '', detail: detail
    });
  };
  let src: image.ImageSource | undefined = undefined;
  try {
    src = image.createImageSource(absPath);
  } catch (error) {
    const e = error as BusinessError;
    fail(`建 ImageSource 失败：code=${e.code ?? -1} ${e.message}`);
    return;
  }
  const source: image.ImageSource = src;
  source.getImageInfo(0, (err: BusinessError, info: image.ImageInfo) => {
    if (err) {
      releaseSource(source);
      fail(`取图像信息失败：code=${err.code ?? -1} ${err.message}`);
      return;
    }
    const srcW: number = info.size.width;
    const srcH: number = info.size.height;
    const plan: DecodePlan = planDecode(srcW, srcH);
    const shown: DisplayPlan = planDisplay(srcW, srcH, { width: boxW, height: boxH });
    const options: image.DecodingOptions = {
      desiredSize: { width: plan.decodeWidth, height: plan.decodeHeight }
    };
    source.createPixelMap(options).then((pm: image.PixelMap) => {
      const loadMs: number = Date.now() - started;
      hilog.info(DOMAIN, TAG, 'F7 load %{public}dx%{public}d → %{public}dx%{public}d loadMs=%{public}d',
        srcW, srcH, plan.decodeWidth, plan.decodeHeight, loadMs);
      releaseSource(source); // 解码完成即可释放（PixelMap 独立持有像素）
      onDone({
        ok: true, pixelMap: pm, srcWidth: srcW, srcHeight: srcH,
        decodeWidth: plan.decodeWidth, decodeHeight: plan.decodeHeight, downscaled: plan.downscaled,
        loadMs: loadMs, displayNote: shown.note,
        detail: `原图 ${srcW}×${srcH}｜${plan.note}｜${shown.note}`
      });
    }).catch((decodeErr: BusinessError) => {
      releaseSource(source);
      fail(`解码失败：code=${decodeErr.code ?? -1} ${decodeErr.message}`);
    });
  });
}
/** 释放 ImageSource（审查 2026-10-22：以前从不 release，长会话会累积解码缓冲） */
function releaseSource(source: image.ImageSource): void {
  try {
    source.release();
  } catch (releaseError) {
    // 已释放
  }
}