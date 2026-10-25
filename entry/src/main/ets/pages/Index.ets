/*
 * 文件名：Index.ets
 * 功能：首页——展示今日减排量、今日积分和今日记录列表，并提供"记录低碳行为"入口
 * 说明：
 *   1. 数据全部来自 DBUtil，页面不直接写 SQL；
 *   2. 每次从录入页返回时 onPageShow 会重新拉取，保证列表和统计是最新的；
 *   3. 删除记录暂未开放（删除需要同步回滚日汇总和累计，下一步再补）。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { DBUtil } from '../common/DBUtil';
import { CarbonRecord } from '../model/TableType';
import { AppState } from '../model/AppState';
import { RecordDeleteService, DeleteRecordResult } from '../service/RecordDeleteService';

function pad2(value: number): string {
  return value < 10 ? '0' + value : String(value);
}

function todayText(): string {
  const now: Date = new Date();
  return now.getFullYear() + '-' + pad2(now.getMonth() + 1) + '-' + pad2(now.getDate());
}

@Entry
@Component
struct Index {
  @State todayCo2: number = 0;
  @State todayPoint: number = 0;
  @State records: CarbonRecord[] = [];
  @State loaded: boolean = false;
  @State retry: number = 0;

  onPageShow(): void {
    this.refresh();
  }

  /** 重新统计今日数据 */
  private async refresh(): Promise<void> {
    // 数据库由 EntryAbility 异步初始化，首页可能先一步加载，未就绪时短延迟重试
    if (!DBUtil.isReady()) {
      if (this.retry < 10) {
        this.retry++;
        setTimeout(() => {
          this.refresh();
        }, 300);
      }
      return;
    }
    this.retry = 0;
    const all: CarbonRecord[] = await DBUtil.getAllCarbonRecord();
    const key: string = todayText();
    const todayList: CarbonRecord[] = all.filter((item: CarbonRecord) => item.recordTime.startsWith(key));
    let co2: number = 0;
    for (const item of todayList) {
      co2 += item.reduceCo2;
    }
    this.records = todayList;
    this.todayCo2 = Math.round(co2 * 100) / 100;
    this.todayPoint = AppState.getTodayEarnPoint();
    this.loaded = true;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  private openAdd(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/AddRecord' }).catch((err: BusinessError) => {
        this.toast('打开失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开失败');
    }
  }

  /** 打开数据看板 */
  private openDashboard(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/Dashboard' }).catch((err: BusinessError) => {
        this.toast('打开看板失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开看板失败');
    }
  }

  /** 打开历史记录 */
  private openHistory(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/History' }).catch((err: BusinessError) => {
        this.toast('打开历史记录失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开历史记录失败');
    }
  }
  /** 打开低碳任务 */
  private openTasks(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskList' }).catch((err: BusinessError) => {
        this.toast('打开任务失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开任务失败');
    }
  }

  /** 打开徽章 */
  private openBadges(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/BadgeList' }).catch((err: BusinessError) => {
        this.toast('打开徽章失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开徽章失败');
    }
  }

  /** 打开科普 */
  private openArticles(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/ArticleList' }).catch((err: BusinessError) => {
        this.toast('打开科普失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开科普失败');
    }
  }
  /** 删除前先确认，避免误触 */
  private confirmDelete(item: CarbonRecord): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '删除记录',
        message: '确定删除「' + item.itemName + '」吗？今日统计会同步扣减。',
        autoCancel: true,
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '删除',
          fontColor: '#C62828',
          action: () => {
            this.removeRecord(item);
          }
        }
      });
    } catch (err) {
      this.toast('无法打开确认框');
    }
  }

  /** 调用独立服务删除，成功后再刷新页面 */
  private async removeRecord(item: CarbonRecord): Promise<void> {
    if (item.id === undefined) {
      return;
    }
    const result: DeleteRecordResult = await RecordDeleteService.deleteRecord(item.id);
    if (!result.success) {
      this.toast('删除失败，请重试');
      return;
    }
    // 只有删除的是今天的记录，才扣减今日积分
    if (result.recordTime.startsWith(todayText())) {
      AppState.setTodayEarnPoint(Math.max(0, AppState.getTodayEarnPoint() - result.removedPoint));
    }
    this.toast('已删除');
    await this.refresh();
  }

  build() {
    Column() {
      Column() {
        Text('碳足迹').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#1B5E20')
        Text(todayText()).fontSize(13).fontColor('#78909C').margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row() {
        Column() {
          Text('今日减排').fontSize(13).fontColor('#607D8B')
          Text('≈ ' + this.todayCo2.toFixed(2)).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#2E7D32')
          Text('kg CO₂e · 按实际值').fontSize(12).fontColor('#90A4AE')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('今日积分').fontSize(13).fontColor('#607D8B')
          Text(String(this.todayPoint)).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#F9A825')
          Text('分').fontSize(12).fontColor('#90A4AE')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(18)
      .backgroundColor(Color.White)
      .borderRadius(16)
      .margin({ top: 16 })

      Button('+ 记录低碳行为')
        .width('100%')
        .height(48)
        .margin({ top: 16 })
        .backgroundColor('#2E7D32')
        .onClick(() => {
          this.openAdd();
        })

      Button('数据看板 →')
        .width('100%')
        .height(44)
        .margin({ top: 10 })
        .backgroundColor('#E8F5E9')
        .fontColor('#2E7D32')
        .onClick(() => {
          this.openDashboard();
        })
      Button('历史记录 →')
        .width('100%')
        .height(44)
        .margin({ top: 10 })
        .backgroundColor('#E8F5E9')
        .fontColor('#2E7D32')
        .onClick(() => {
          this.openHistory();
        })
      Row() {
        Button('低碳任务')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#E8F5E9')
          .fontColor('#2E7D32')
          .onClick(() => {
            this.openTasks();
          })
        Button('我的徽章')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .margin({ left: 8 })
          .backgroundColor('#E8F5E9')
          .fontColor('#2E7D32')
          .onClick(() => {
            this.openBadges();
          })
        Button('双碳科普')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .margin({ left: 8 })
          .backgroundColor('#E8F5E9')
          .fontColor('#2E7D32')
          .onClick(() => {
            this.openArticles();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('今日记录').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#263238')
        Blank()
        Text(String(this.records.length) + ' 条').fontSize(13).fontColor('#90A4AE')
      }
      .width('100%')
      .margin({ top: 24, bottom: 8 })

      if (!this.loaded) {
        Text('加载中…').fontSize(14).fontColor('#90A4AE').margin({ top: 20 })
      } else if (this.records.length === 0) {
        Column() {
          Text('今天还没有记录').fontSize(15).fontColor('#78909C')
          Text('点击上面的按钮，记录第一件低碳小事').fontSize(12).fontColor('#B0BEC5').margin({ top: 6 })
        }
        .width('100%')
        .padding(28)
        .backgroundColor(Color.White)
        .borderRadius(16)
      } else {
        Column() {
          ForEach(this.records, (item: CarbonRecord) => {
            Row() {
              Column() {
                Text(item.itemName).fontSize(15).fontColor('#263238')
                Text(String(item.amount) + ' ' + item.unit + ' · ' + item.recordTime.substring(11, 16))
                  .fontSize(12)
                  .fontColor('#90A4AE')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column() {
                Text(item.reduceCo2.toFixed(2) + ' kg').fontSize(14).fontColor('#2E7D32')
                Text('+' + String(item.getPoint) + ' 分').fontSize(12).fontColor('#F9A825').margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.End)

              Text('删除')
                .fontSize(12)
                .fontColor('#C62828')
                .padding({ left: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  this.confirmDelete(item);
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .border({ width: { bottom: 1 }, color: '#F0F0F0' })
          }, (item: CarbonRecord) => String(item.id))
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(16)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 20 })
    .backgroundColor('#F1F3F5')
    .alignItems(HorizontalAlign.Start)
  }
}
