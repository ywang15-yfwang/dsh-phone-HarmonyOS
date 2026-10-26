import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xD001;
const TAG: string = 'F9THUMB';

/**
 * 视频缩略图（**只出画面，不播放**）。
 *
 * 客户 2026-10-21：附件条里视频现在只显示文件名；手机屏幕小，就算能播也看不清，
 * 所以**给一帧预览**就行，点开再看。
 *
 * 做法：`AVMetadataExtractor.fetchFrameByTime(0, NEXT_SYNC)` —— 取**第一帧**解成 PixelMap。
 * 取不到（编码怪、权限、损坏）就退回灰底 + 播放小标，**不影响发送**。
 */
async function loadFirstFrame(uri: string, side: number): Promise<image.PixelMap | undefined> {
  let fd = -1;
  let extractor: media.AVMetadataExtractor | undefined = undefined;
  try {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    fd = file.fd;
    const stat: fileIo.Stat = fileIo.statSync(fd);
    extractor = await media.createAVMetadataExtractor();
    extractor.fdSrc = { fd: fd, offset: 0, length: stat.size };
    const params: media.PixelMapParams = { width: side, height: side };
    const pm: image.PixelMap = await extractor.fetchFrameByTime(0,
      media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, params);
    return pm;
  } catch (error) {
    const e = error as BusinessError;
    hilog.warn(DOMAIN, TAG, '取视频首帧失败 code=%{public}d %{public}s', e.code ?? -1, e.message ?? '');
    return undefined;
  } finally {
    if (extractor !== undefined) {
      try {
        await extractor.release();
      } catch (releaseError) {
        // 忽略
      }
    }
    if (fd >= 0) {
      try {
        fileIo.closeSync(fd);
      } catch (closeError) {
        // 忽略
      }
    }
  }
}

@Component
export struct VideoThumb {
  /** 选择器给的 uri（本机文件） */
  uri: string = '';
  /** 边长（vp） */
  side: number = 56;
  @State private frame: image.PixelMap | undefined = undefined;
  /** 组件已销毁（首帧可能晚到，晚到就丢弃并释放） */
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.releaseFrame();
  }

  /** 释放 PixelMap（审查 2026-10-22：以前从不 release，翻附件条会累积） */
  private releaseFrame(): void {
    const pm: image.PixelMap | undefined = this.frame;
    this.frame = undefined;
    if (pm !== undefined) {
      try {
        pm.release();
      } catch (releaseError) {
        // 已释放
      }
    }
  }

  private load(): void {
    loadFirstFrame(this.uri, Math.max(64, Math.round(this.side * 3))).then((pm: image.PixelMap | undefined) => {
      if (pm === undefined) {
        return;
      }
      if (this.disposed) {
        // 组件没了才拿到帧 ⇒ 立刻释放，别泄漏
        try {
          pm.release();
        } catch (releaseError) {
          // 忽略
        }
        return;
      }
      if (this.frame !== undefined) {
        this.releaseFrame();
      }
      this.frame = pm;
    }).catch(() => {
      // 失败就保持占位
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.frame !== undefined) {
        Image(this.frame)
          .width(this.side)
          .height(this.side)
          .objectFit(ImageFit.Cover)
          .borderRadius(8)
      } else {
        Column()
          .width(this.side)
          .height(this.side)
          .backgroundColor('#eef0f3')
          .borderRadius(8)
      }
      // 播放小标：**只是"这是视频"的标识**，这里不播（客户：屏幕小，预览不播）
      Text('▶')
        .fontSize(12)
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
        .width(20)
        .height(20)
        .borderRadius(10)
        .backgroundColor('#66000000')
    }
    .width(this.side)
    .height(this.side)
  }
}
