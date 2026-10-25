/*
 * 文件名：DataManage.ets
 * 功能：本地数据管理页——备份、恢复、统计报表导出。
 *
 * 说明：
 *   1. 备份/恢复/导出都通过系统文件选择器选择保存或读取位置；
 *   2. 备份文件为 JSON（五张表），恢复前会校验文件来源并在事务里整体替换；
 *   3. 报表为 CSV，带 BOM，Excel 直接打开不乱码；
 *   4. 页面只负责交互与提示，具体读写由 service/BackupService 完成。
 */

import { common } from '@kit.AbilityKit';
import { BackupService, RestoreResult } from '../service/BackupService';

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

  /** 恢复前二次确认 */
  private confirmRestore(): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '恢复备份',
        message: '恢复会用备份内容覆盖当前全部数据（减碳记录、积分、任务、徽章），确定继续吗？',
        autoCancel: true,
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '选择备份文件',
          fontColor: '#C62828',
          action: () => {
            this.doRestore();
          }
        }
      });
    } catch (err) {
      this.toast('无法打开确认框');
    }
  }

  /** 选择备份文件并恢复 */
  private async doRestore(): Promise<void> {
    if (this.working) {
      return;
    }
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.working = true;
    this.status = '正在恢复…';
    try {
      const result: RestoreResult = await BackupService.pickAndRestore(context);
      if (result.ok) {
        this.status = '恢复成功，共 ' + String(result.rows) + ' 行。请重启应用查看。';
        this.toast('恢复成功，请重启应用');
      } else if (result.message === '已取消') {
        this.status = '已取消恢复';
        this.toast('已取消');
      } else {
        this.status = '恢复失败：' + result.message;
        this.toast(this.status);
      }
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.status = '恢复失败：' + message;
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
            Button(this.working ? '处理中…' : '备份到文件')
              .width('100%')
              .height(44)
              .backgroundColor('#2E7D32')
              .enabled(!this.working)
              .onClick(() => {
                this.doBackup();
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)

          // 恢复
          Column() {
            Text('恢复备份')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('从之前导出的 JSON 备份恢复数据。恢复会覆盖当前全部数据，请谨慎操作。')
              .fontSize(12)
              .fontColor('#607D8B')
              .margin({ top: 6, bottom: 12 })
            Button(this.working ? '处理中…' : '选择备份文件恢复')
              .width('100%')
              .height(44)
              .backgroundColor('#FFF3E0')
              .fontColor('#EF6C00')
              .enabled(!this.working)
              .onClick(() => {
                this.confirmRestore();
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12 })

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
            Button(this.working ? '处理中…' : '导出 CSV 报表')
              .width('100%')
              .height(44)
              .backgroundColor('#E8F5E9')
              .fontColor('#2E7D32')
              .enabled(!this.working)
              .onClick(() => {
                this.doExport();
              })
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

          Text('提示：备份和报表通过系统文件选择器保存，可选择下载目录；恢复会覆盖当前数据，操作前建议先备份。')
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
