/*
 * 文件名：DataManage.ets
 * 功能：本地数据管理页——备份与统计报表导出。
 *
 * 说明：
 *   1. 备份/导出都通过系统文件选择器选择保存位置；
 *   2. 备份文件为 JSON（五张表），带 app 标识和版本号；
 *   3. 报表为 CSV，带 BOM，Excel 直接打开不乱码；
 *   4. 页面只负责交互与提示，具体读写由 service/BackupService 完成。
 */

import { common } from '@kit.AbilityKit';
import { BackupService } from '../service/BackupService';
import { DemoDataService, DemoSeedResult } from '../service/DemoDataService';

@Entry
@Component
struct DataManage {
  /** 是否有操作正在进行，防止重复点击 */
  @State working: boolean = false;
  /** 最近一次操作的结果提示 */
  @State status: string = '';

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      // 返回失败时停留在当前页
    }
  }

  private hostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  /** 备份五张表到用户选择的位置 */
  private async doBackup(): Promise<void> {
    if (this.working) {
      return;
    }
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.working = true;
    this.status = '正在生成备份…';
    try {
      const json: string = await BackupService.buildBackupJson();
      const fileName: string = 'carbon-backup-' + BackupService.fileStamp() + '.json';
      const saved: boolean = await BackupService.saveTextWithPicker(context, fileName, json);
      this.status = saved ? '备份已保存：' + fileName : '已取消备份';
      this.toast(this.status);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.status = '备份失败：' + message;
      this.toast(this.status);
    }
    this.working = false;
  }

  /** 导出 CSV 统计报表 */
  private async doExport(): Promise<void> {
    if (this.working) {
      return;
    }
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.working = true;
    this.status = '正在生成报表…';
    try {
      const csv: string = await BackupService.buildReportCsv();
      const fileName: string = 'carbon-report-' + BackupService.fileStamp() + '.csv';
      const saved: boolean = await BackupService.saveTextWithPicker(context, fileName, csv);
      this.status = saved ? '报表已导出：' + fileName : '已取消导出';
      this.toast(this.status);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.status = '导出失败：' + message;
      this.toast(this.status);
    }
    this.working = false;
  }

  /* ============================ 导出内容预览 ============================ */

  /**
   * 把生成的文本写进 AppStorage 并跳到预览页。
   * 手机/模拟器上没有 CSV、JSON 查看器，录屏演示时用这个页面直接看内容。
   * @param title    预览页标题
   * @param content  完整文本
   * @param maxLines 最多展示多少行（避免超长文本拖慢渲染）
   */
  private openPreview(title: string, content: string, maxLines: number): void {
    try {
      const lines: string[] = content.split('\n');
      const total: number = lines.length;
      const shown: string[] = total > maxLines ? lines.slice(0, maxLines) : lines;
      let body: string = shown.join('\n');
      if (total > maxLines) {
        body += '\n\n…… 共 ' + String(total) + ' 行，此处仅预览前 ' +
          String(maxLines) + ' 行（完整内容已保存到文件）';
      }
      AppStorage.setOrCreate<string>('previewTitle', title);
      AppStorage.setOrCreate<string>('previewBody', body);
      this.getUIContext().getRouter().pushUrl({ url: 'pages/Preview' }).catch(() => {
        this.toast('打开预览失败');
      });
    } catch (err) {
      this.toast('打开预览失败');
    }
  }

  /** 只预览不保存：演示时最快看到内容 */
  private async previewBackup(): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    try {
      const json: string = await BackupService.buildBackupJson();
      this.openPreview('备份文件预览（JSON）', json, 60);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.toast('生成备份失败：' + message);
    }
    this.working = false;
  }

  /** 只预览不保存 */
  private async previewCsv(): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    try {
      const csv: string = await BackupService.buildReportCsv();
      this.openPreview('CSV 报表预览', csv, 60);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.toast('生成报表失败：' + message);
    }
    this.working = false;
  }

  /** 载入示例数据前二次确认：会清空现有记录，避免误点覆盖真实数据 */
  private confirmSeed(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '载入示例数据',
        message: '会先清空现有记录，再写入 40 条示例数据（最近 3 个月）。确定继续吗？',
        autoCancel: true,
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '载入',
          fontColor: '#2E7D32',
          action: () => {
            this.doSeed();
          }
        }
      });
    } catch (err) {
      this.toast('无法打开确认框');
    }
  }

  /** 清空全部业务数据前二次确认 */
  private confirmClear(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '清空全部数据',
        message: '将删除所有减碳记录、积分、领奖与徽章记录，且无法恢复。确定清空吗？',
        autoCancel: true,
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '清空',
          fontColor: '#C62828',
          action: () => {
            this.doClear();
          }
        }
      });
    } catch (err) {
      this.toast('无法打开确认框');
    }
  }

  /** 写入示例数据：真实入库，首页/看板/证书/徽章共用同一份 */
  private async doSeed(): Promise<void> {
    if (this.working) {
      return;
    }
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.working = true;
    this.status = '正在写入示例数据…';
    try {
      const result: DemoSeedResult = await DemoDataService.seed(context);
      this.status = '示例数据已载入：' + String(result.records) + ' 条记录、' +
        String(result.claims) + ' 次领奖，累计减排 ' + result.co2.toFixed(2) + ' kg';
      this.toast('示例数据已载入');
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.status = '载入示例数据失败：' + message;
      this.toast(this.status);
    }
    this.working = false;
  }

  /** 清空全部业务数据 */
  private async doClear(): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    this.status = '正在清空数据…';
    try {
      const ok: boolean = await DemoDataService.clearAll();
      this.status = ok ? '已清空全部记录、积分与徽章' : '清空失败：数据库未就绪';
      this.toast(this.status);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.status = '清空失败：' + message;
      this.toast(this.status);
    }
    this.working = false;
  }

  build() {
    Column() {
      // 顶部
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#2E7D32')
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('数据管理')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#263238')
        Blank()
        Text('      ').fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      Scroll() {
        Column() {
          // 备份
          Column() {
            Text('备份数据')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('把减碳记录、积分、每日汇总、任务和徽章一起导出为 JSON 备份文件，可保存到下载目录。')
              .fontSize(12)
              .fontColor('#607D8B')
              .margin({ top: 6, bottom: 12 })
            Row() {
              Button(this.working ? '处理中…' : '备份到文件')
                .layoutWeight(2)
                .height(44)
                .backgroundColor('#2E7D32')
                .enabled(!this.working)
                .onClick(() => {
                  this.doBackup();
                })
              Button('预览')
                .layoutWeight(1)
                .height(44)
                .backgroundColor('#EEF2F5')
                .fontColor('#455A64')
                .enabled(!this.working)
                .margin({ left: 10 })
                .onClick(() => {
                  this.previewBackup();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)

          // 报表
          Column() {
            Text('导出统计报表')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('把所有减碳记录导出为 CSV 表格（时间、行为、数量、减排量、积分），可用 Excel 打开留存。')
              .fontSize(12)
              .fontColor('#607D8B')
              .margin({ top: 6, bottom: 12 })
            Row() {
              Button(this.working ? '处理中…' : '导出 CSV 报表')
                .layoutWeight(2)
                .height(44)
                .backgroundColor('#E8F5E9')
                .fontColor('#2E7D32')
                .enabled(!this.working)
                .onClick(() => {
                  this.doExport();
                })
              Button('预览')
                .layoutWeight(1)
                .height(44)
                .backgroundColor('#EEF2F5')
                .fontColor('#455A64')
                .enabled(!this.working)
                .margin({ left: 10 })
                .onClick(() => {
                  this.previewCsv();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12 })

          // 演示数据：答辩/演示时一键构造一份"像用过一段时间"的数据
          Column() {
            Text('演示数据')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('写入 40 条跨 3 个月的示例记录（含 2 次领奖），让看板、证书、徽章都有内容；也可以一键清空回到初始状态。')
              .fontSize(12)
              .fontColor('#607D8B')
              .margin({ top: 6, bottom: 12 })
            Row() {
              Button(this.working ? '处理中…' : '载入示例数据')
                .layoutWeight(1)
                .height(44)
                .backgroundColor('#E8F5E9')
                .fontColor('#2E7D32')
                .enabled(!this.working)
                .onClick(() => {
                  this.confirmSeed();
                })
              Button(this.working ? '处理中…' : '清空全部数据')
                .layoutWeight(1)
                .height(44)
                .backgroundColor('#FDECEA')
                .fontColor('#C62828')
                .enabled(!this.working)
                .margin({ left: 10 })
                .onClick(() => {
                  this.confirmClear();
                })
            }
            .width('100%')

            Text('示例数据写入真实数据表，与手动录入的记录完全等价，导出的 CSV 与备份里也会包含。')
              .fontSize(11)
              .fontColor('#90A4AE')
              .width('100%')
              .margin({ top: 10 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12 })

          // 状态
          if (this.status.length > 0) {
            Text(this.status)
              .fontSize(12)
              .fontColor('#546E7A')
              .width('100%')
              .margin({ top: 16 })
          }

          Text('提示：备份和报表通过系统文件选择器保存，可选择下载目录。')
            .fontSize(11)
            .fontColor('#90A4AE')
            .width('100%')
            .margin({ top: 12, bottom: 20 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .backgroundColor('#F1F3F5')
    .alignItems(HorizontalAlign.Start)
  }
}
