/*
 * 文件名：TreeCertificate.ets
 * 存放路径：entry/src/main/ets/pages/TreeCertificate.ets
 * 功能：植树证书页。把「累计减排量」折算成种树棵数，生成一张电子证书。
 *
 * 口径说明：
 *   1 棵成年树每年约吸收 18.3 kg 二氧化碳（业界常用的估算口径），
 *   因此 折合棵数 = 累计减排量 kgCO2e ÷ 18.3；
 *   累计减排量达到 1 kg 即达到发证线（约等于种下 0.05 棵树的贡献），
 *   低于该值时只展示进度，不生成证书。
 *
 * 职责边界：
 *   1. 累计减排量通过 service/TaskService.getProgress('co2', 1) 读取，
 *      本页不写 SQL、不操作 RdbStore、不新建数据表；
 *   2. 证书为电子纪念，随数据实时生成（编号由日期 + 累计量决定，同一数据下编号稳定）；
 *   3. 样式与 TaskList / BadgeList 保持一致，不引入第三方依赖。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TaskService, TaskProgress } from '../service/TaskService';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'TreeCertificate';

/* ============================ 主题色（与任务页 / 徽章页同一套） ============================ */
const COLOR_BG: string = '#F1F3F5';
const COLOR_PRIMARY: string = '#2E7D32';
const COLOR_PRIMARY_DEEP: string = '#1B5E20';
const COLOR_PRIMARY_LIGHT: string = '#E8F5E9';
const COLOR_GOLD: string = '#F9A825';
const COLOR_TITLE: string = '#263238';
const COLOR_TEXT: string = '#607D8B';
const COLOR_MUTED: string = '#90A4AE';
const COLOR_HINT: string = '#B0BEC5';
const COLOR_LINE: string = '#F0F0F0';
const COLOR_CARD: string = '#FFFFFF';
const COLOR_SEAL: string = '#C62828';

/** 一棵树每年的固碳量（kgCO2e），用于把减排量折算成棵数 */
const KG_PER_TREE: number = 18.3;
/** 发证线：累计减排量达到 1 kg 才能生成证书 */
const CERT_THRESHOLD: number = 1;

@Entry
@Component
struct TreeCertificate {
  /** 累计减排量 kgCO2e */
  @State totalCo2: number = 0;
  /** 0 加载中 / 1 成功 / 2 失败 */
  @State loadState: number = 0;
  @State errorMsg: string = '';

  onPageShow(): void {
    this.loadData();
  }

  /* ============================ 数据 ============================ */

  private async loadData(): Promise<void> {
    this.loadState = 0;
    this.errorMsg = '';
    try {
      // co2 口径的进度就是累计减排量，target 传 1 只是为了拿 current
      const progress: TaskProgress = await TaskService.getProgress('co2', 1);
      this.totalCo2 = Math.max(0, progress.current);
      this.loadState = 1;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'certificate loaded, totalCo2=%{public}s', String(this.totalCo2));
    } catch (err) {
      this.errorMsg = err instanceof Error ? err.message : String(err);
      this.loadState = 2;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load failed: %{public}s', this.errorMsg);
    }
  }

  /* ============================ 计算与文案 ============================ */

  /** 折合棵数（保留两位小数） */
  private treeCount(): number {
    return this.totalCo2 / KG_PER_TREE;
  }

  /** 是否达到发证线 */
  private qualified(): boolean {
    return this.totalCo2 >= CERT_THRESHOLD;
  }

  /**
   * 当前这棵树的已累计量（0 ~ KG_PER_TREE）。
   * 18.3 在浮点下不精确，直接取模在「正好整数棵」时会得到两种残差：
   * 54.9 % 18.3 = 18.3（界面显示还差 0.00 kg），而 18.3 % 18.3 = 0。
   * 先算整棵数再相减，可以消掉这层误差。
   */
  private treePart(): number {
    const trees: number = Math.floor(this.totalCo2 / KG_PER_TREE + 1e-9);
    const part: number = this.totalCo2 - trees * KG_PER_TREE;
    return Math.min(KG_PER_TREE, Math.max(0, Math.round(part * 100) / 100));
  }

  /** 距离下一棵树还差多少 kg */
  private remainToNext(): number {
    const part: number = this.treePart();
    const remain: number = part > 0 ? KG_PER_TREE - part : KG_PER_TREE;
    return Math.round(remain * 100) / 100;
  }

  /** 当前这棵树的进度百分比 0~100 */
  private treePercent(): number {
    const percent: number = Math.round(this.treePart() / KG_PER_TREE * 100);
    return percent > 100 ? 100 : percent;
  }

  /** 今天的日期，yyyy-MM-dd */
  private todayText(): string {
    const now: Date = new Date();
    const month: string = (now.getMonth() + 1).toString().padStart(2, '0');
    const day: string = now.getDate().toString().padStart(2, '0');
    return now.getFullYear() + '-' + month + '-' + day;
  }

  /** 证书编号：日期 + 累计减排量（×10 取整），同一数据下编号稳定 */
  private certNo(): string {
    const now: Date = new Date();
    const month: string = (now.getMonth() + 1).toString().padStart(2, '0');
    const day: string = now.getDate().toString().padStart(2, '0');
    const datePart: string = String(now.getFullYear()) + month + day;
    const seq: string = String(Math.round(this.totalCo2 * 10)).padStart(4, '0');
    return 'CT-' + datePart + '-' + seq;
  }

  /** 未达发证线时还差多少 */
  private remainToCert(): number {
    const remain: number = CERT_THRESHOLD - this.totalCo2;
    return remain > 0 ? Math.round(remain * 100) / 100 : 0;
  }

  /* ============================ 交互 ============================ */

  private goAddRecord(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/AddRecord' }).catch(() => {
        // 跳转失败时停留在当前页
      });
    } catch (err) {
      // 忽略
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      // 页面栈为空时忽略
    }
  }

  /* ============================ UI ============================ */

  /** 证书主体：渐变描边 + 白色内页 */
  /** 证书主体：奖状版式（双线边框 + 四角落款 + 印章） */
  /** 证书主体：金框证书底板 + 叠加文字（文字落在模板中间的空白区） */
  @Builder
  CertificateBody() {
    Stack({ alignContent: Alignment.Top }) {
      // 证书底板：荣誉证书模板（含标题与金色印章）
      Image($r('app.media.ic_cert_frame'))
        .width('100%')
        .objectFit(ImageFit.Contain)

      // 叠加文字：对应模板中间的空白区域
      Column() {
        Text('植 树 证 书 · TREE PLANTING')
          .fontSize(9)
          .fontColor('#8D6E63')
          .letterSpacing(1)

        Text('兹 证 明')
          .fontSize(11)
          .fontColor('#6D4C41')
          .letterSpacing(1)
          .margin({ top: 12 })

        Text('碳 足 迹 用 户')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#3E2723')
          .letterSpacing(1)
          .margin({ top: 8 })

        Text('截 至 ' + this.todayText() + ' 累 计 减 排')
          .fontSize(10)
          .fontColor('#5D4037')
          .margin({ top: 12 })

        Row() {
          Text(this.totalCo2.toFixed(2))
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#2E7D32')
          Text(' kg CO₂e')
            .fontSize(9)
            .fontColor('#795548')
            .margin({ left: 3, bottom: 4 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 2 })

        Text('折 合 植 树 ' + this.treeCount().toFixed(2) + ' 棵')
          .fontSize(12)
          .fontColor('#33691E')
          .letterSpacing(1)
          .margin({ top: 10 })

        Text('特 发 此 证')
          .fontSize(10)
          .fontColor('#5D4037')
          .margin({ top: 10 })
      }
      .width('100%')
      .padding({ left: 52, right: 52, top: 158 })
      .alignItems(HorizontalAlign.Center)

    }
    .width('100%')
    .borderRadius(10)
    .clip(true)

    // 编号与日期放在证书下方，避免压在模板的红色缎带上
    Row() {
      Text('证书编号 ' + this.certNo())
        .fontSize(9)
        .fontColor(COLOR_HINT)
      Blank()
      Text('颁发日期 ' + this.todayText())
        .fontSize(9)
        .fontColor(COLOR_HINT)
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
    .margin({ top: 10 })
  }


  @Builder
  NotYetBody() {
    Column() {
      Text('🌱')
        .fontSize(40)
      Text('还没有达到发证条件')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TITLE)
        .margin({ top: 10 })
      Text('累计减排满 ' + CERT_THRESHOLD.toFixed(0) + ' kg 即可生成植树证书')
        .fontSize(12)
        .fontColor(COLOR_TEXT)
        .margin({ top: 6 })
      Text('还差 ' + this.remainToCert().toFixed(2) + ' kg，记录几次低碳行为就够了')
        .fontSize(12)
        .fontColor(COLOR_PRIMARY)
        .margin({ top: 8 })
      Button('去记录低碳行为')
        .height(40)
        .fontSize(14)
        .borderRadius(20)
        .backgroundColor(COLOR_PRIMARY)
        .margin({ top: 16 })
        .onClick(() => {
          this.goAddRecord();
        })
    }
    .width('100%')
    .padding(24)
    .backgroundColor(COLOR_CARD)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      // 顶部导航
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(COLOR_PRIMARY)
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('植树证书')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TITLE)
        Blank()
        Text('     ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      if (this.loadState === 0) {
        Column() {
          Text('加载中…')
            .fontSize(14)
            .fontColor(COLOR_MUTED)
        }
        .width('100%')
        .padding(40)
      } else if (this.loadState === 2) {
        Column() {
          Text('数据加载失败')
            .fontSize(15)
            .fontColor(COLOR_TEXT)
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(COLOR_HINT)
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
          Button('重新加载')
            .height(36)
            .fontSize(13)
            .borderRadius(18)
            .backgroundColor(COLOR_PRIMARY)
            .margin({ top: 16 })
            .onClick(() => {
              this.loadData();
            })
        }
        .width('100%')
        .padding(32)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)
        .margin({ top: 16 })
      } else {
        Scroll() {
          Column() {
            if (this.qualified()) {
              this.CertificateBody()
            } else {
              this.NotYetBody()
            }

            // 进度：距离下一棵树
            Column() {
              Row() {
                Text('距离下一棵树')
                  .fontSize(13)
                  .fontColor(COLOR_TEXT)
                Blank()
                Text('还差 ' + this.remainToNext().toFixed(2) + ' kg')
                  .fontSize(12)
                  .fontColor(COLOR_PRIMARY)
              }
              .width('100%')

              Progress({
                value: this.treePart(),
                total: KG_PER_TREE,
                type: ProgressType.Linear
              })
                .width('100%')
                .height(6)
                .color(COLOR_PRIMARY)
                .backgroundColor('#EDEFF2')
                .margin({ top: 8 })

              Text('每 18.3 kg 减排量约等于一棵成年树一年的固碳量')
                .fontSize(11)
                .fontColor(COLOR_HINT)
                .width('100%')
                .margin({ top: 8 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(COLOR_CARD)
            .borderRadius(16)
            .margin({ top: 14 })
            .alignItems(HorizontalAlign.Start)

            // 口径与声明
            Column() {
              Text('关于这张证书')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(COLOR_TITLE)
              Text('折算口径：一棵成年树每年约吸收 18.3 kg 二氧化碳，因此用累计减排量除以 18.3 得到棵数。')
                .fontSize(12)
                .lineHeight(19)
                .fontColor(COLOR_TEXT)
                .margin({ top: 8 })
              Text('证书为应用内的电子纪念，按当前累计数据实时生成，不可兑换实物或碳资产。')
                .fontSize(12)
                .lineHeight(19)
                .fontColor(COLOR_TEXT)
                .margin({ top: 6 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(COLOR_CARD)
            .borderRadius(16)
            .margin({ top: 12, bottom: 20 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 4 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .backgroundColor(COLOR_BG)
    .alignItems(HorizontalAlign.Start)
  }
}
