/*
 * 文件名：History.ets
 * 功能：历史记录页——按分类、时间范围筛选减碳记录，支持删除。
 *
 * 说明：
 *   1. 查询走独立的 HistoryService，删除复用 RecordDeleteService；
 *   2. 分类来自 CarbonCalculator.getCategories()，不在页面写死；
 *   3. 删除前二次确认，删除后同步扣减今日积分（仅当天记录）；
 *   4. 无数据时显示空状态，不渲染列表。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { CarbonRecord } from '../model/TableType';
import { AppState } from '../model/AppState';
import { CarbonCalculator, Category } from '../utils/CarbonCalculator';
import { RecordDeleteService, DeleteRecordResult } from '../service/RecordDeleteService';
import { HistoryService, HistoryFilter, PagedRecords } from '../service/HistoryService';

function pad2(value: number): string {
  return value < 10 ? '0' + value : String(value);
}

/** Date -> yyyy-MM-dd */
function formatDate(date: Date): string {
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate());
}

function todayText(): string {
  return formatDate(new Date());
}

/** 今天往前推 days 天 */
function daysAgo(days: number): string {
  const date: Date = new Date();
  date.setDate(date.getDate() - days);
  return formatDate(date);
}

/** 今年 1 月 1 日 */
function yearStartText(): string {
  return new Date().getFullYear() + '-01-01';
}

@Entry
@Component
struct History {
  /** 分类列表（来自因子库） */
  @State categories: Category[] = [];
  /** 当前分类下标：0 表示全部分类 */
  @State categoryIndex: number = 0;
  /** 分类 Select 的显示文字 */
  @State categoryLabel: string = '全部分类';
  /** 时间范围下标 */
  @State rangeIndex: number = 0;
  /** 时间范围显示文字 */
  @State rangeLabel: string = '全部时间';
  /** 查询结果 */
  @State records: CarbonRecord[] = [];
  /** 总条数 */
  @State total: number = 0;
  /** 合计减排量 */
  @State totalCo2: number = 0;
  /** 是否加载中 */
  @State loading: boolean = false;

  /** 因子库加载重试次数 */
  private categoryRetry: number = 0;

  /** 时间范围选项 */
  private ranges: SelectOption[] = [
    { value: '全部时间' },
    { value: '近 7 天' },
    { value: '近 30 天' },
    { value: '今年' }
  ];

  aboutToAppear(): void {
    this.loadCategories();
    this.refresh();
  }

  /** 加载分类；因子库由 EntryAbility 异步初始化，未就绪时短暂重试 */
  private loadCategories(): void {
    this.categories = CarbonCalculator.getInstance().getCategories();
    if (this.categories.length === 0 && this.categoryRetry < 10) {
      this.categoryRetry++;
      setTimeout(() => {
        this.loadCategories();
      }, 500);
    }
  }

  /** 分类下拉选项：第一项固定为「全部分类」 */
  private categoryOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部分类' }];
    for (const category of this.categories) {
      options.push({ value: category.name });
    }
    return options;
  }

  /** 根据当前选择组装筛选条件 */
  private buildFilter(): HistoryFilter {
    const filter: HistoryFilter = {};
    if (this.categoryIndex > 0 && this.categoryIndex - 1 < this.categories.length) {
      filter.categoryId = this.categories[this.categoryIndex - 1].id;
    }
    if (this.rangeIndex === 1) {
      filter.startDate = daysAgo(6);
      filter.endDate = todayText();
    } else if (this.rangeIndex === 2) {
      filter.startDate = daysAgo(29);
      filter.endDate = todayText();
    } else if (this.rangeIndex === 3) {
      filter.startDate = yearStartText();
      filter.endDate = todayText();
    }
    return filter;
  }

  /** 重新查询并统计 */
  private async refresh(): Promise<void> {
    this.loading = true;
    const result: PagedRecords = await HistoryService.queryRecords(this.buildFilter());
    this.records = result.items;
    this.total = result.total;
    let co2: number = 0;
    for (const item of result.items) {
      co2 += item.reduceCo2;
    }
    this.totalCo2 = Math.round(co2 * 100) / 100;
    this.loading = false;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
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

  /** 删除确认 */
  private confirmDelete(item: CarbonRecord): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '删除记录',
        message: '确定删除「' + item.itemName + '」吗？统计会同步扣减。',
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

  /** 调用删除服务，成功后刷新列表 */
  private async removeRecord(item: CarbonRecord): Promise<void> {
    if (item.id === undefined) {
      return;
    }
    const result: DeleteRecordResult = await RecordDeleteService.deleteRecord(item.id);
    if (!result.success) {
      this.toast('删除失败，请重试');
      return;
    }
    // 删除的是今天的记录时，同步扣减今日积分
    if (result.recordTime.startsWith(todayText())) {
      AppState.setTodayEarnPoint(Math.max(0, AppState.getTodayEarnPoint() - result.removedPoint));
    }
    this.toast('已删除');
    await this.refresh();
  }

  build() {
    Column() {
      // ==================== 顶部栏 ====================
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#2E7D32')
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('历史记录')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#263238')
        Blank()
        Text('      ').fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      // ==================== 筛选卡片 ====================
      Column() {
        Row() {
          Text('分类')
            .fontSize(13)
            .fontColor('#607D8B')
            .width(56)
          Select(this.categoryOptions())
            .selected(this.categoryIndex)
            .value(this.categoryLabel)
            .font({ size: 13 })
            .fontColor('#2E7D32')
            .backgroundColor('#F5F7F6')
            .borderRadius(8)
            .layoutWeight(1)
            .onSelect((index: number, value: string) => {
              this.categoryIndex = index;
              this.categoryLabel = value;
              this.refresh();
            })
        }
        .width('100%')

        Row() {
          Text('时间')
            .fontSize(13)
            .fontColor('#607D8B')
            .width(56)
          Select(this.ranges)
            .selected(this.rangeIndex)
            .value(this.rangeLabel)
            .font({ size: 13 })
            .fontColor('#2E7D32')
            .backgroundColor('#F5F7F6')
            .borderRadius(8)
            .layoutWeight(1)
            .onSelect((index: number, value: string) => {
              this.rangeIndex = index;
              this.rangeLabel = value;
              this.refresh();
            })
        }
        .width('100%')
        .margin({ top: 10 })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Color.White)
      .borderRadius(16)

      // ==================== 汇总 ====================
      Row() {
        Text('共 ' + String(this.total) + ' 条')
          .fontSize(13)
          .fontColor('#607D8B')
        Blank()
        Text('合计 ' + this.totalCo2.toFixed(2) + ' kg')
          .fontSize(13)
          .fontColor('#2E7D32')
      }
      .width('100%')
      .margin({ top: 14, bottom: 8 })

      // ==================== 列表 ====================
      if (this.loading) {
        Row() {
          LoadingProgress()
            .width(24)
            .height(24)
            .color('#2E7D32')
          Text('加载中…')
            .fontSize(13)
            .fontColor('#90A4AE')
            .margin({ left: 8 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding(30)
      } else if (this.records.length === 0) {
        Column() {
          Text('没有符合条件的记录')
            .fontSize(14)
            .fontColor('#78909C')
          Text('换个分类或时间范围试试')
            .fontSize(12)
            .fontColor('#B0BEC5')
            .margin({ top: 6 })
        }
        .width('100%')
        .padding(40)
        .backgroundColor(Color.White)
        .borderRadius(16)
      } else {
        Scroll() {
          Column() {
            ForEach(this.records, (item: CarbonRecord) => {
              Row() {
                Column() {
                  Text(item.itemName)
                    .fontSize(15)
                    .fontColor('#263238')
                  Text(item.recordTime.substring(0, 16) + ' · ' + String(item.amount) + ' ' + item.unit)
                    .fontSize(11)
                    .fontColor('#90A4AE')
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column() {
                  Text(item.reduceCo2.toFixed(2) + ' kg')
                    .fontSize(13)
                    .fontColor('#2E7D32')
                  Text('+' + String(item.getPoint) + ' 分')
                    .fontSize(11)
                    .fontColor('#F9A825')
                    .margin({ top: 2 })
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
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 12 })
    .backgroundColor('#F1F3F5')
    .alignItems(HorizontalAlign.Start)
  }
}
