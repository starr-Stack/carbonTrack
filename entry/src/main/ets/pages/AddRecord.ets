/*
 * 文件名：AddRecord.ets
 * 功能：手动录入一条低碳行为——选分类、选行为、填数量，实时预览减排量与积分，提交入库
 * 说明：
 *   1. 分类与行为列表全部来自 CarbonCalculator.getCategories()，不在页面里写死；
 *   2. 数量上限取因子库的 maxPerRecord，超限直接拦截；
 *   3. 积分先按规则计算，再应用每日上限（applyDailyCap）；
 *   4. 入库调用 DBUtil.addCarbonRecord()，它会在一个事务里写明细、日汇总、用户累计。
 */
import { DBUtil } from '../common/DBUtil';
import { CarbonRecord } from '../model/TableType';
import { AppState } from '../model/AppState';
import { CarbonCalculator, Category, FactorItem, CalcResult } from '../utils/CarbonCalculator';

function pad2(value: number): string {
  return value < 10 ? '0' + value : String(value);
}

function nowText(): string {
  const now: Date = new Date();
  return now.getFullYear() + '-' + pad2(now.getMonth() + 1) + '-' + pad2(now.getDate()) +
    ' ' + pad2(now.getHours()) + ':' + pad2(now.getMinutes()) + ':' + pad2(now.getSeconds());
}

@Entry
@Component
struct AddRecord {
  @State categories: Category[] = [];
  @State catIndex: number = 0;
  @State itemIndex: number = 0;
  @State amountText: string = '';
  @State previewCo2: number = 0;
  @State previewPoint: number = 0;
  @State submitting: boolean = false;

  aboutToAppear(): void {
    this.categories = CarbonCalculator.getInstance().getCategories();
    // 因子库由 EntryAbility 异步加载，若页面打开过早则稍后重试一次
    if (this.categories.length === 0) {
      setTimeout(() => {
        this.categories = CarbonCalculator.getInstance().getCategories();
      }, 800);
    }
  }

  private currentCategory(): Category | undefined {
    if (this.catIndex < 0 || this.catIndex >= this.categories.length) {
      return undefined;
    }
    return this.categories[this.catIndex];
  }

  private currentItems(): FactorItem[] {
    const category: Category | undefined = this.currentCategory();
    return category === undefined ? [] : category.items;
  }

  private currentItem(): FactorItem | undefined {
    const items: FactorItem[] = this.currentItems();
    if (this.itemIndex < 0 || this.itemIndex >= items.length) {
      return undefined;
    }
    return items[this.itemIndex];
  }

  private selectCategory(index: number): void {
    this.catIndex = index;
    this.itemIndex = 0;
    this.amountText = '';
    this.previewCo2 = 0;
    this.previewPoint = 0;
  }

  private selectItem(index: number): void {
    this.itemIndex = index;
    this.amountText = '';
    this.previewCo2 = 0;
    this.previewPoint = 0;
  }

  /** 输入变化时实时预览 */
  private updatePreview(): void {
    const category: Category | undefined = this.currentCategory();
    const item: FactorItem | undefined = this.currentItem();
    const value: number = Number(this.amountText);
    if (category === undefined || item === undefined || !Number.isFinite(value) || value <= 0) {
      this.previewCo2 = 0;
      this.previewPoint = 0;
      return;
    }
    const calc: CalcResult = CarbonCalculator.getInstance().calcReduceCO2(category.id, item.id, value);
    this.previewCo2 = calc.reduceCo2;
    this.previewPoint = CarbonCalculator.getInstance()
      .applyDailyCap(calc.getPoint, AppState.getTodayEarnPoint());
  }

  /** 提交一条记录 */
  private async submit(): Promise<void> {
    if (this.submitting) {
      return;
    }
    const category: Category | undefined = this.currentCategory();
    const item: FactorItem | undefined = this.currentItem();
    if (category === undefined || item === undefined) {
      this.toast('因子库还没加载好，请稍后再试');
      return;
    }
    const value: number = Number(this.amountText);
    if (!Number.isFinite(value) || value <= 0) {
      this.toast('请输入大于 0 的数量');
      return;
    }
    const maxRaw: number | undefined = item.maxPerRecord;
    const max: number = maxRaw === undefined ? value : maxRaw;
    if (value > max) {
      this.toast('单次最多 ' + String(max) + ' ' + item.unit);
      return;
    }

    const calc: CalcResult = CarbonCalculator.getInstance().calcReduceCO2(category.id, item.id, value);
    const point: number = CarbonCalculator.getInstance()
      .applyDailyCap(calc.getPoint, AppState.getTodayEarnPoint());
    const record: CarbonRecord = {
      recordTime: nowText(),
      categoryId: category.id,
      itemId: item.id,
      itemName: item.name,
      amount: value,
      unit: item.unit,
      reduceCo2: calc.reduceCo2,
      getPoint: point,
      remark: ''
    };

    this.submitting = true;
    const id: number = await DBUtil.addCarbonRecord(record);
    this.submitting = false;

    if (id > 0) {
      AppState.addPoint(point);
      this.toast('已记录：' + item.name);
      this.goBack();
    } else {
      this.toast('保存失败，请检查数据库是否就绪');
    }
  }

  private unitText(): string {
    const item: FactorItem | undefined = this.currentItem();
    return item === undefined ? '' : item.unit;
  }

  private maxText(): string {
    const item: FactorItem | undefined = this.currentItem();
    if (item === undefined || item.maxPerRecord === undefined) {
      return '';
    }
    return '单次上限：' + String(item.maxPerRecord) + ' ' + item.unit;
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

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#2E7D32')
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('记录低碳行为').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#263238')
        Blank()
        Text('     ').fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      if (this.categories.length === 0) {
        Column() {
          Text('因子库还没加载好').fontSize(16).fontColor('#78909C')
          Text('请返回首页稍后再试，或重启应用').fontSize(13).fontColor('#B0BEC5').margin({ top: 8 })
        }
        .width('100%')
        .padding(40)
      } else {
        Scroll() {
          Column() {
            Text('选择分类').fontSize(14).fontColor('#607D8B').width('100%').margin({ bottom: 8 })
            Row() {
              ForEach(this.categories, (category: Category, index: number) => {
                Text(category.name)
                  .fontSize(13)
                  .fontColor(this.catIndex === index ? Color.White : '#37474F')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 8, bottom: 8 })
                  .layoutWeight(1)
                  .backgroundColor(this.catIndex === index ? '#2E7D32' : '#E0E0E0')
                  .borderRadius(10)
                  .margin({ right: index === this.categories.length - 1 ? 0 : 6 })
                  .onClick(() => {
                    this.selectCategory(index);
                  })
              }, (category: Category) => category.id)
            }
            .width('100%')

            Text('选择行为').fontSize(14).fontColor('#607D8B').width('100%').margin({ top: 20, bottom: 8 })
            Column() {
              ForEach(this.currentItems(), (item: FactorItem, index: number) => {
                Row() {
                  Column() {
                    Text(item.name).fontSize(15).fontColor('#263238')
                    Text(item.unit + ' · ' + String(item.factor) + ' kgCO₂e/' + item.unit)
                      .fontSize(12)
                      .fontColor('#90A4AE')
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (this.itemIndex === index) {
                    Text('✓').fontSize(16).fontColor('#2E7D32')
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor(this.itemIndex === index ? '#E8F5E9' : Color.White)
                .borderRadius(10)
                .margin({ bottom: 8 })
                .onClick(() => {
                  this.selectItem(index);
                })
              }, (item: FactorItem) => item.id)
            }
            .width('100%')

            Text('数量').fontSize(14).fontColor('#607D8B').width('100%').margin({ top: 12, bottom: 8 })
            Row() {
              TextInput({ text: this.amountText, placeholder: '请输入数量' })
                .type(InputType.Number)
                .layoutWeight(1)
                .height(44)
                .backgroundColor(Color.White)
                .onChange((value: string) => {
                  this.amountText = value;
                  this.updatePreview();
                })
              Text(this.unitText())
                .fontSize(15)
                .fontColor('#455A64')
                .width(56)
                .textAlign(TextAlign.Center)
            }
            .width('100%')

            Row() {
              Column() {
                Text('预计减排').fontSize(12).fontColor('#607D8B')
                Text(this.previewCo2.toFixed(2) + ' kg').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2E7D32')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column() {
                Text('预计积分').fontSize(12).fontColor('#607D8B')
                Text('+' + String(this.previewPoint)).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#F9A825')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)
            .margin({ top: 16 })

            if (this.maxText().length > 0) {
              Text(this.maxText())
                .fontSize(12)
                .fontColor('#90A4AE')
                .width('100%')
                .margin({ top: 8 })
            }

            Button(this.submitting ? '保存中…' : '确认记录')
              .width('100%')
              .height(48)
              .margin({ top: 20 })
              .backgroundColor('#2E7D32')
              .enabled(!this.submitting)
              .onClick(() => {
                this.submit();
              })
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .backgroundColor('#F1F3F5')
    .alignItems(HorizontalAlign.Start)
  }
}
