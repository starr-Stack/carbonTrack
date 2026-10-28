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

/** 右上角大字用的短日期：MM/dd */
function monthDayText(): string {
  const now: Date = new Date();
  return pad2(now.getMonth() + 1) + '/' + pad2(now.getDate());
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
  /** 打开数据管理 */
  private openDataManage(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/DataManage' }).catch((err: BusinessError) => {
        this.toast('打开数据管理失败：' + err.message);
      });
    } catch (err) {
      this.toast('打开数据管理失败');
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

  /** 纯原生形状绘制的叶片标识，不引入外部图片 */
  @Builder
  leafBadge(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor('#EAF4E2')

      Shape() {
        Path()
          .commands('M28 6 C15 13 11 31 28 49 C45 31 41 13 28 6 Z')
          .fill('#7CB342')
        Path()
          .commands('M28 12 L28 45')
          .stroke('#F6FBF2')
          .strokeWidth(2)
        Path()
          .commands('M28 24 L21 18')
          .stroke('#F6FBF2')
          .strokeWidth(1.5)
        Path()
          .commands('M28 32 L35 26')
          .stroke('#F6FBF2')
          .strokeWidth(1.5)
      }
      .width(size * 0.58)
      .height(size * 0.58)
      .viewPort({ x: 0, y: 0, width: 56, height: 56 })
    }
    .width(size)
    .height(size)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // ==================== 顶部：标题 + 日期 ====================
        Row() {
          Text('碳足迹')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B5E20')
            .letterSpacing(1)
            .layoutWeight(1)

          // 日期移到右上角：月/日大字 + 年份小字
          Column() {
            Text(monthDayText())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor('#2E7D32')
              .letterSpacing(1)
            Text(String(new Date().getFullYear()))
              .fontSize(11)
              .fontColor('#7A8F7C')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 4 })

        // ==================== 今日数据卡片 ====================
        Column() {
          Row({ space: 8 }) {
            Column() {
              Row() {
                Row()
                  .width(6)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor('#66BB6A')
                Text('今日减排')
                  .fontSize(13)
                  .fontColor('#5F7362')
                  .margin({ left: 6 })
              }
              .alignItems(VerticalAlign.Center)

              Text('≈ ' + this.todayCo2.toFixed(2))
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor('#2E7D32')
                .margin({ top: 8 })
                .maxLines(1)

              Text('kg CO₂e · 按实际值')
                .fontSize(11)
                .fontColor('#6F8372')
                .margin({ top: 4 })
                .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 14, right: 10, top: 16, bottom: 16 })
            .backgroundColor('#F1F8EC')
            .borderRadius(18)

            Column() {
              Row() {
                Row()
                  .width(6)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor('#F9A825')
                Text('今日积分')
                  .fontSize(13)
                  .fontColor('#6E6045')
                  .margin({ left: 6 })
              }
              .alignItems(VerticalAlign.Center)

              Text(String(this.todayPoint))
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor('#D97706')
                .margin({ top: 8 })
                .maxLines(1)

              Text('分')
                .fontSize(11)
                .fontColor('#7A6A4E')
                .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 14, right: 10, top: 16, bottom: 16 })
            .backgroundColor('#FFF9EC')
            .borderRadius(18)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding(8)
        .backgroundColor(Color.White)
        .borderRadius(24)
        .shadow({ radius: 20, color: '#102E7D32', offsetY: 8 })

        // ==================== 主操作 ====================
        Button('+ 记录低碳行为')
          .width('100%')
          .height(54)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor('#2E7D32')
          .borderRadius(27)
          .shadow({ radius: 18, color: '#292E7D32', offsetY: 8 })
          .onClick(() => {
            this.openAdd();
          })

        // ==================== 功能入口 ====================
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Button('数据看板 →')
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E7D32')
              .backgroundColor('#F2F8ED')
              .borderRadius(14)
              .onClick(() => {
                this.openDashboard();
              })
            Button('历史记录 →')
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E7D32')
              .backgroundColor('#F2F8ED')
              .borderRadius(14)
              .onClick(() => {
                this.openHistory();
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Button('低碳任务')
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E7D32')
              .backgroundColor('#F2F8ED')
              .borderRadius(14)
              .onClick(() => {
                this.openTasks();
              })
            Button('我的徽章')
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E7D32')
              .backgroundColor('#F2F8ED')
              .borderRadius(14)
              .onClick(() => {
                this.openBadges();
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Button('双碳科普')
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E7D32')
              .backgroundColor('#F2F8ED')
              .borderRadius(14)
              .onClick(() => {
                this.openArticles();
              })
            Button('数据管理 →')
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E7D32')
              .backgroundColor('#F2F8ED')
              .borderRadius(14)
              .onClick(() => {
                this.openDataManage();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(10)
        .backgroundColor(Color.White)
        .borderRadius(22)
        .shadow({ radius: 20, color: '#0D2E7D32', offsetY: 8 })

        // ==================== 今日记录 ====================
        Row() {
          Text('今日记录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#263238')
          Blank()
          Text(String(this.records.length) + ' 条')
            .fontSize(12)
            .fontColor('#4F6B52')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor('#E8F3E1')
            .borderRadius(12)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })

        if (!this.loaded) {
          Column() {
            Text('加载中…')
              .fontSize(14)
              .fontColor('#5F7462')
          }
          .width('100%')
          .padding({ top: 28, bottom: 28 })
          .backgroundColor(Color.White)
          .borderRadius(22)
        } else if (this.records.length === 0) {
          Column() {
            this.leafBadge(64)
            Text('今天还没有记录')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#5F7462')
              .margin({ top: 14 })
            Text('点击上面的按钮，记录第一件低碳小事')
              .fontSize(12)
              .fontColor('#66796A')
              .margin({ top: 6 })
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: 30, bottom: 30, left: 20, right: 20 })
          .backgroundColor(Color.White)
          .borderRadius(22)
        } else {
          Column() {
            ForEach(this.records, (item: CarbonRecord, index: number) => {
              Row() {
                Row()
                  .width(4)
                  .height(36)
                  .borderRadius(2)
                  .backgroundColor('#C8E6C9')
                  .margin({ right: 12 })

                Column() {
                  Text(item.itemName)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#263238')
                  Text(String(item.amount) + ' ' + item.unit + ' · ' + item.recordTime.substring(11, 16))
                    .fontSize(12)
                    .fontColor('#66796A')
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Column() {
                  Text(item.reduceCo2.toFixed(2) + ' kg')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#2E7D32')
                    .maxLines(1)
                  Text('+' + String(item.getPoint) + ' 分')
                    .fontSize(12)
                    .fontColor('#B45309')
                    .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.End)
                .margin({ left: 8 })

                Row() {
                  Text('删除')
                    .fontSize(12)
                    .fontColor('#C62828')
                }
                .height(32)
                .padding({ left: 10, right: 10 })
                .justifyContent(FlexAlign.Center)
                .backgroundColor('#FFF3F1')
                .borderRadius(10)
                .margin({ left: 6 })
                .onClick(() => {
                  this.confirmDelete(item);
                })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 12, bottom: 12 })
              .border({ width: { bottom: index === this.records.length - 1 ? 0 : 1 }, color: '#EFF4EB' })
            }, (item: CarbonRecord) => String(item.id))
          }
          .width('100%')
          .padding({ left: 16, right: 12, top: 4, bottom: 4 })
          .backgroundColor(Color.White)
          .borderRadius(22)
          .shadow({ radius: 16, color: '#0A2E7D32', offsetY: 6 })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 24, bottom: 32 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F8F1')
    .scrollBar(BarState.Off)
  }
}
