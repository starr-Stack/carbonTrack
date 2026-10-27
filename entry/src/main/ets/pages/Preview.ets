/*
 * 文件名：Preview.ets
 * 存放路径：entry/src/main/ets/pages/Preview.ets
 * 功能：导出内容的只读预览页。
 *
 * 为什么需要它：
 *   手机与模拟器上都没有 CSV / JSON 查看器，文件保存到"下载"目录后点不开，
 *   录屏演示时看不到内容。这个页面直接把 DataManage 生成的文本显示在屏幕上，
 *   既能证明"文件确实生成了"，也方便讲解表头、字段和 JSON 结构。
 *
 * 数据传递：
 *   DataManage 通过 AppStorage 写入 previewTitle / previewBody，再 router.pushUrl 过来；
 *   不通过路由参数传大段文本，避免超长参数被截断。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'Preview';

@Entry
@Component
struct Preview {
  /** 标题：CSV 报表预览 / 备份文件预览（JSON） */
  @StorageLink('previewTitle') previewTitle: string = '预览';
  /** 正文：已按行裁剪过的文本 */
  @StorageLink('previewBody') previewBody: string = '';

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'back failed');
    }
  }

  build() {
    Column() {
      // 顶部导航，与其它页面保持一致
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#2E7D32')
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text(this.previewTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#263238')
        Blank()
        Text('      ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      // 正文：等宽感靠字号与行高实现，长行自动换行
      Scroll() {
        Text(this.previewBody)
          .fontSize(11)
          .lineHeight(16)
          .fontColor('#37474F')
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding(12)
      .backgroundColor(Color.White)
      .borderRadius(12)
      .margin({ bottom: 10 })

      Text('移动端没有 CSV / JSON 查看器，这里直接展示导出内容；完整文件已按你选择的位置保存。长按文本可复制。')
        .fontSize(10)
        .lineHeight(15)
        .fontColor('#90A4AE')
        .width('100%')
        .margin({ bottom: 10 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .backgroundColor('#F1F3F5')
    .alignItems(HorizontalAlign.Start)
  }
}
