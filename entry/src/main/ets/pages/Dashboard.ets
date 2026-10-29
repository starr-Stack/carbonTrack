/*
 * 文件名：Dashboard.ets
 * 功能：碳足迹数据看板（接入 @ohos/mpchart 折线图）
 *
 * 说明：
 *   1. 顶部下拉框选择「日 / 周 / 月 / 年」，切换后重新组装 Entry 并刷新模型；
 *   2. 两张统计卡片：累计减排、累计积分；
 *   3. 折线图：X 轴为时间标签，Y 轴为减排量 kgCO₂e，绿色线条 + 数值标签；
 *   4. 分类占比为饼图，数据明细列出当前周期的逐项数据；
 *   5. 空数据时显示提示文字，不渲染图表；
 *   6. 数据来自 service/StatisticsService（对 carbon_record 做 SUM/GROUP BY），
 *      累计卡片取 user_info 的全量累计，与首页、证书页口径一致。
 *
 * 依赖：@ohos/mpchart（已通过 ohpm 安装到项目依赖）
 */

import {
  LineChart,
  LineChartModel,
  LineData,
  LineDataSet,
  BarChart,
  BarChartModel,
  BarData,
  BarDataSet,
  BarEntry,
  IBarDataSet,
  PieChart,
  PieChartModel,
  PieData,
  PieDataSet,
  PieEntry,
  EntryOhos,
  ILineDataSet,
  JArrayList,
  Mode,
  XAxis,
  XAxisPosition,
  YAxis,
  YAxisLabelPosition,
  Legend,
  LegendForm,
  IAxisValueFormatter,
  IValueFormatter,
  AxisBase,
  ViewPortHandler,
  ChartColor
} from '@ohos/mpchart';

import { hilog } from '@kit.PerformanceAnalysisKit';
import { StatisticsService, TrendItem, PieItem, TotalStat } from '../service/StatisticsService';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'Dashboard';

/* ==================== 低碳绿配色（页面与图表统一） ==================== */
/** 主色：深绿 */
const COLOR_PRIMARY: string = '#2E7D32';
/** 主色浅底：用于卡片/按钮背景 */
const COLOR_PRIMARY_LIGHT: string = '#E8F5E9';
/** 积分强调色：琥珀 */
const COLOR_ACCENT: string = '#F9A825';
/** 正文文字 */
const COLOR_TEXT: string = '#263238';
/** 次要文字 */
const COLOR_TEXT_SECONDARY: string = '#607D8B';
/** 提示文字 */
const COLOR_TEXT_HINT: string = '#90A4AE';
/** 页面背景 */
const COLOR_BG: string = '#F1F3F5';
/** 图表内部用的绿色（ARGB 数值，与 COLOR_PRIMARY 同色） */
const CHART_GREEN: number = 0xFF2E7D32;

@Entry
@Component
struct Dashboard {
  /** 当前选中的时间范围下标：0 日、1 周、2 月、3 年 */
  @State rangeIndex: number = 0;
  /** 当前选中的时间范围文字，用于 Select 显示 */
  @State rangeLabel: string = '日';
  /** 趋势数据 */
  @State trendData: TrendItem[] = [];
  /** 分类占比数据 */
  @State pieData: PieItem[] = [];
  /** 累计减排量 */
  @State totalCo2: number = 0;
  /** 累计积分 */
  @State totalPoint: number = 0;
  /** 是否正在加载 */
  @State loading: boolean = false;

  /** 折线图模型：只创建一次，切换范围时更新数据后 invalidate */
  private model: LineChartModel = new LineChartModel();
  /** X 轴引用，用于绑定标签格式化器 */
  private xAxis: XAxis | null = null;
  /** 柱状图模型：与折线图共用 trendData */
  private barModel: BarChartModel = new BarChartModel();
  /** 柱状图 X 轴引用 */
  private barXAxis: XAxis | null = null;
  /** 饼图模型 */
  private pieModel: PieChartModel = new PieChartModel();

  /** 下拉框选项 */
  private ranges: SelectOption[] = [
    { value: '日' },
    { value: '周' },
    { value: '月' },
    { value: '年' }
  ];

  /**
   * X 轴标签格式化：把索引值换成时间文字
   * 例如 0 -> "10-18"，1 -> "10-19"
   */
  private xFormatter: IAxisValueFormatter = {
    getFormattedValue: (value: number, axis: AxisBase): string => {
      const index: number = Math.round(value);
      if (index >= 0 && index < this.trendData.length) {
        return this.trendData[index].label;
      }
      return '';
    }
  };

  /**
   * 数值标签格式化：
   * 第一个点紧贴 Y 轴，标签向左会压住轴刻度，所以 x=0 的点不显示数值
   */
  private valueFormatter: IValueFormatter = {
    getFormattedValue: (value: number, entry: EntryOhos, dataSetIndex: number,
      viewPortHandler: ViewPortHandler): string => {
      if (entry.getX() === 0) {
        return '';
      }
      return value.toFixed(2);
    }
  };

  /** 柱状图数值标签：每根柱子都显示，不做隐藏 */
  private barValueFormatter: IValueFormatter = {
    getFormattedValue: (value: number, entry: EntryOhos, dataSetIndex: number,
      viewPortHandler: ViewPortHandler): string => {
      return value.toFixed(2);
    }
  };

  /** 饼图数值标签：传进来的已经是百分比整数，只补一个百分号 */
  private pieValueFormatter: IValueFormatter = {
    getFormattedValue: (value: number, entry: EntryOhos, dataSetIndex: number,
      viewPortHandler: ViewPortHandler): string => {
      const percent: number = Math.round(value);
      // 占比不足 1% 的扇区角度几乎为 0，标签会挤在别的扇区上，看起来像“数字错了”
      if (percent <= 0) {
        return '';
      }
      return String(percent) + '%';
    }
  };

  aboutToAppear(): void {
    this.initChart();
    this.initBarChart();
    this.initPieChart();
    this.refresh();
  }

  /** 一次性配置图表：坐标轴、图例、背景等 */
  private initChart(): void {
    // 不显示图表右下角的描述文字
    this.model.getDescription()?.setEnabled(false);

    // 图例：显示，线形，内容取自 DataSet 的 label
    const legend: Legend | null = this.model.getLegend();
    if (legend) {
      legend.setEnabled(true);
      legend.setForm(LegendForm.LINE);
      legend.setTextSize(11);
      legend.setTextColor(COLOR_TEXT_SECONDARY);
    }

    // 图表基础设置
    this.model.setMaxVisibleValueCount(60);
    this.model.setDrawGridBackground(false);
    // 固定交互：禁止缩放/拖拽，避免误触后图表跑偏（mpchart 常见渲染问题）
    this.model.setScaleEnabled(false);
    this.model.setPinchZoom(false);
    this.model.setDragEnabled(false);
    this.model.setDrawBorders(false);

    // X 轴：底部，不画网格，按索引取标签
    this.xAxis = this.model.getXAxis();
    if (this.xAxis) {
      this.xAxis.setPosition(XAxisPosition.BOTTOM);
      this.xAxis.setDrawGridLines(false);
      this.xAxis.setGranularity(1);
      this.xAxis.setLabelCount(5);
      this.xAxis.setValueFormatter(this.xFormatter);
      this.xAxis.setTextSize(10);
      this.xAxis.setTextColor(COLOR_TEXT_SECONDARY);
    }

    // 左 Y 轴：从 0 开始，标签在图表外侧
    const leftAxis: YAxis | null = this.model.getAxisLeft();
    if (leftAxis) {
      leftAxis.setAxisMinimum(0);
      leftAxis.setLabelCount(5, false);
      leftAxis.setPosition(YAxisLabelPosition.OUTSIDE_CHART);
      leftAxis.setTextSize(10);
      leftAxis.setTextColor(COLOR_TEXT_SECONDARY);
    }

    // 右 Y 轴：用不到，隐藏
    const rightAxis: YAxis | null = this.model.getAxisRight();
    if (rightAxis) {
      rightAxis.setEnabled(false);
    }
  }

  /** 一次性配置柱状图：与折线图保持同样的坐标轴和图例风格 */
  private initBarChart(): void {
    this.barModel.getDescription()?.setEnabled(false);

    const legend: Legend | null = this.barModel.getLegend();
    if (legend) {
      legend.setEnabled(true);
      legend.setForm(LegendForm.SQUARE);
      legend.setTextSize(11);
      legend.setTextColor(COLOR_TEXT_SECONDARY);
    }

    this.barModel.setDrawGridBackground(false);
    this.barModel.setDrawValueAboveBar(true);
    this.barModel.setDrawBarShadow(false);
    this.barModel.setFitBars(true);
    // 与折线图保持一致：禁止缩放/拖拽
    this.barModel.setScaleEnabled(false);
    this.barModel.setPinchZoom(false);
    this.barModel.setDragEnabled(false);
    this.barModel.setDrawBorders(false);

    this.barXAxis = this.barModel.getXAxis();
    if (this.barXAxis) {
      this.barXAxis.setPosition(XAxisPosition.BOTTOM);
      this.barXAxis.setDrawGridLines(false);
      this.barXAxis.setGranularity(1);
      this.barXAxis.setLabelCount(5);
      this.barXAxis.setValueFormatter(this.xFormatter);
      this.barXAxis.setTextSize(10);
      this.barXAxis.setTextColor(COLOR_TEXT_SECONDARY);
    }

    const leftAxis: YAxis | null = this.barModel.getAxisLeft();
    if (leftAxis) {
      leftAxis.setAxisMinimum(0);
      leftAxis.setLabelCount(5, false);
      leftAxis.setPosition(YAxisLabelPosition.OUTSIDE_CHART);
      leftAxis.setTextSize(10);
      leftAxis.setTextColor(COLOR_TEXT_SECONDARY);
    }

    const rightAxis: YAxis | null = this.barModel.getAxisRight();
    if (rightAxis) {
      rightAxis.setEnabled(false);
    }
  }

  /** 一次性配置饼图：不显示图表自带图例，改用页面下方的彩色图例 */
  private initPieChart(): void {
    this.pieModel.getDescription()?.setEnabled(false);

    const legend: Legend | null = this.pieModel.getLegend();
    if (legend) {
      legend.setEnabled(false);
    }

    // 扇区数值直接使用页面算好的百分比（见 rebuildPieData），关掉图表自己的归一化，
    // 否则图表按 kg 再算一遍、图例按 kg 先算再修正，两边四舍五入后会差 1%
    this.pieModel.setUsePercentValues(false);
    this.pieModel.setDrawEntryLabels(false); // 不在扇区上画名称，避免拥挤
    this.pieModel.setHoleRadius(0);          // 实心饼图
    this.pieModel.setTransparentCircleRadius(0);
    this.pieModel.setDrawCenterText(false);
    this.pieModel.setRotationAngle(0);
    // 给饼图留出内边距，避免圆形被卡片边缘裁切
    this.pieModel.setExtraOffsets(8, 12, 8, 8);
  }

  /**
   * 刷新全部数据：趋势、分类占比、累计统计。
   * 趋势与占比由 StatisticsService 查库聚合；两张累计卡片取 user_info 的全量累计，
   * 这样切换日/周/月时卡片不会跳变，也和首页、证书页的数字对得上。
   */
  private async refresh(): Promise<void> {
    this.loading = true;
    try {
      const trend: TrendItem[] = await StatisticsService.queryTrend(this.rangeLabel);
      const pie: PieItem[] = await StatisticsService.queryCategoryShare(this.rangeLabel);
      const total: TotalStat = await StatisticsService.queryTotals();

      this.trendData = trend;
      this.pieData = pie;
      this.totalCo2 = total.co2;
      this.totalPoint = total.point;

      // 数据变了就重新组装 Entry、刷新模型
      if (this.trendData.length > 0) {
        this.rebuildLineData();
        this.rebuildBarData();
      }
      if (this.pieData.length > 0) {
        this.rebuildPieData();
      }
    } catch (err) {
      this.trendData = [];
      this.pieData = [];
      hilog.error(LOG_DOMAIN, LOG_TAG, 'refresh failed: %{public}s',
        err instanceof Error ? err.message : String(err));
    }
    this.loading = false;
  }

  /**
   * 重新组装折线数据：
   *   trendData -> EntryOhos(index, value) -> LineDataSet -> LineData -> model
   * 切换日/周/月/年时都会走这里
   */
  private rebuildLineData(): void {
    const entries: JArrayList<EntryOhos> = new JArrayList<EntryOhos>();
    for (let i = 0; i < this.trendData.length; i++) {
      entries.add(new EntryOhos(i, this.trendData[i].value));
    }

    const dataSet: LineDataSet = new LineDataSet(entries, '减排量 (kgCO₂e)');
    dataSet.setMode(Mode.LINEAR);        // 直线连接
    dataSet.setDrawCircles(true);        // 数据点画圆
    dataSet.setCircleColor(CHART_GREEN); // 圆点绿色
    dataSet.setCircleRadius(3);
    dataSet.setColorByColor(CHART_GREEN); // 折线绿色
    dataSet.setLineWidth(2);
    dataSet.setDrawValues(true);          // 显示数值标签
    dataSet.setValueTextSize(9);
    dataSet.setValueTextColor(CHART_GREEN);
    dataSet.setValueFormatter(this.valueFormatter);
    dataSet.setHighlightEnabled(false); // 关闭点击高亮，避免出现橙色十字线

    const dataSets: JArrayList<ILineDataSet> = new JArrayList<ILineDataSet>();
    dataSets.add(dataSet);

    // 标签数量随数据点数变化；月份标签较长时倾斜并防首尾裁切，避免重叠
    if (this.xAxis) {
      const firstLabel: string = this.trendData.length > 0 ? this.trendData[0].label : '';
      const longLabels: boolean = firstLabel.length > 5;
      this.xAxis.setLabelCount(Math.min(this.trendData.length, 7), false);
      this.xAxis.setLabelRotationAngle(longLabels ? -45 : 0);
      this.xAxis.setAvoidFirstLastClipping(longLabels);
    }

    const lineData: LineData = new LineData(dataSets);
    this.model.setData(lineData);
    this.model.notifyDataSetChanged();
    this.model.invalidate();
  }

  /**
   * 重新组装柱状图数据，与折线图共用同一份 trendData
   *   trendData -> BarEntry(index, value) -> BarDataSet -> BarData -> barModel
   */
  private rebuildBarData(): void {
    const entries: JArrayList<BarEntry> = new JArrayList<BarEntry>();
    for (let i = 0; i < this.trendData.length; i++) {
      entries.add(new BarEntry(i, this.trendData[i].value));
    }

    const dataSet: BarDataSet = new BarDataSet(entries, '减排量 (kgCO₂e)');
    dataSet.setColorByColor(CHART_GREEN); // 与折线同色，保持风格统一
    dataSet.setDrawValues(true);          // 柱顶显示数值
    dataSet.setValueTextSize(9);
    dataSet.setValueTextColor(CHART_GREEN);
    dataSet.setValueFormatter(this.barValueFormatter);
    dataSet.setHighlightEnabled(false); // 关闭点击高亮

    const dataSets: JArrayList<IBarDataSet> = new JArrayList<IBarDataSet>();
    dataSets.add(dataSet);

    // 标签数量与倾斜角度跟折线图保持一致
    if (this.barXAxis) {
      const firstLabel: string = this.trendData.length > 0 ? this.trendData[0].label : '';
      const longLabels: boolean = firstLabel.length > 5;
      this.barXAxis.setLabelCount(Math.min(this.trendData.length, 7), false);
      this.barXAxis.setLabelRotationAngle(longLabels ? -45 : 0);
      this.barXAxis.setAvoidFirstLastClipping(longLabels);
    }

    const barData: BarData = new BarData(dataSets);
    barData.setBarWidth(0.5);
    this.barModel.setData(barData);
    this.barModel.notifyDataSetChanged();
    this.barModel.invalidate();
  }

  /**
   * 重新组装饼图数据：
   *   pieData -> PieEntry(value, name) -> PieDataSet -> PieData -> pieModel
   * 扇区颜色按分类名称区分
   */
  private rebuildPieData(): void {
    const entries: JArrayList<PieEntry> = new JArrayList<PieEntry>();
    const colors: number[] = [];
    for (const item of this.pieData) {
      // 传百分比而不是 kg：扇区标注与下方图例用的是同一个整数，天然一致
      entries.add(new PieEntry(item.percent, item.name));
      colors.push(this.pieColorOf(item.name));
    }

    const dataSet: PieDataSet = new PieDataSet(entries, '分类占比');
    dataSet.setColorsByVariable(colors); // 每个分类一个颜色
    dataSet.setValueTextSize(10);
    dataSet.setValueTextColor(Color.White);
    dataSet.setValueFormatter(this.pieValueFormatter);
    dataSet.setSliceSpace(2);

    hilog.info(LOG_DOMAIN, LOG_TAG, 'pie percents: %{public}s', JSON.stringify(this.pieData));
    const pieData: PieData = new PieData(dataSet);
    this.pieModel.setData(pieData);
    this.pieModel.notifyDataSetChanged();
    this.pieModel.invalidate();
  }

  /** 分类 -> 颜色（ARGB 数值，给图表用） */
  private pieColorOf(name: string): number {
    // 先判断更具体的关键词，避免"光盘行动"被"行"误判成出行
    if (name.indexOf('光盘') >= 0) {
      return 0xFFEF6C00; // 光盘行动：橙
    }
    if (name.indexOf('回收') >= 0) {
      return 0xFF6A1B9A; // 旧物回收：紫
    }
    if (name.indexOf('电') >= 0) {
      return 0xFFF9A825; // 节电：琥珀
    }
    if (name.indexOf('水') >= 0) {
      return 0xFF1565C0; // 节水：蓝
    }
    if (name.indexOf('行') >= 0 || name.indexOf('骑') >= 0) {
      return 0xFF2E7D32; // 出行 / 骑行：深绿
    }
    return 0xFF90A4AE; // 其他：灰
  }

  /** 分类 -> 颜色（十六进制字符串，给文字图例用） */
  private pieColorText(name: string): string {
    return '#' + this.pieColorOf(name).toString(16).slice(2).toUpperCase();
  }

  build() {
    Column() {
      // ==================== 顶部：标题 + 时间范围下拉框 ====================
      Row() {
        Column() {
          Text('碳足迹看板')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B5E20')
          Text('减排趋势与分类占比')
            .fontSize(12)
            .fontColor('#78909C')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Select(this.ranges)
          .selected(this.rangeIndex)
          .value(this.rangeLabel)
          .font({ size: 14 })
          .fontColor('#2E7D32')
          .backgroundColor(Color.White)
          .borderRadius(10)
          .onSelect((index: number, value: string) => {
            // 切换时间范围后重新拉取数据并重绘折线图
            this.rangeIndex = index;
            this.rangeLabel = value;
            this.refresh();
          })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      // ==================== 统计卡片 ====================
      Row() {
        Column() {
          Text('累计减排')
            .fontSize(12)
            .fontColor('#607D8B')
          Text(this.totalCo2.toFixed(2))
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#2E7D32')
          Text('kg CO₂e')
            .fontSize(11)
            .fontColor('#90A4AE')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          Text('累计积分')
            .fontSize(12)
            .fontColor('#607D8B')
          Text(String(this.totalPoint))
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F9A825')
          Text('分')
            .fontSize(11)
            .fontColor('#90A4AE')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(18)
      .backgroundColor(Color.White)
      .borderRadius(16)
      .margin({ top: 8 })

      // ==================== 图表区域（Flex 布局，四块容器） ====================
      Stack() {
        // 滚动区：四块图表卡片
        Scroll() {
        Flex({ direction: FlexDirection.Column, alignItems: ItemAlign.Stretch }) {

          // ---------- 容器 1：减排趋势折线图 ----------
          Column() {
            Text('减排趋势')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('X 轴时间 · Y 轴减排量（kgCO₂e）')
              .fontSize(11)
              .fontColor('#90A4AE')
              .margin({ top: 2 })

            if (this.trendData.length === 0) {
              // 空数据提示：不渲染图表，避免空模型报错
              Text('暂无趋势数据')
                .fontSize(13)
                .fontColor('#90A4AE')
                .width('100%')
                .height(200)
                .textAlign(TextAlign.Center)
            } else {
              // 折线图：模型只建一次，数据变化后调用 invalidate 重绘
              LineChart({ model: this.model })
                .width('100%')
                .height(220)
                .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12 })

          // ---------- 容器 2：减排对比（柱状图，与折线共用数据） ----------
          Column() {
            Text('减排对比')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('柱状图 · 与折线图共用同一组减排数据')
              .fontSize(11)
              .fontColor('#90A4AE')
              .margin({ top: 2 })

            if (this.trendData.length === 0) {
              // 空数据提示：不渲染图表
              Text('暂无对比数据')
                .fontSize(13)
                .fontColor('#90A4AE')
                .width('100%')
                .height(200)
                .textAlign(TextAlign.Center)
            } else {
              BarChart({ model: this.barModel })
                .width('100%')
                .height(220)
                .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12 })

          // ---------- 容器 3：分类占比（饼图） ----------
          Column() {
            Text('分类占比')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('饼图展示各分类减排量占比')
              .fontSize(11)
              .fontColor('#90A4AE')
              .margin({ top: 2 })

            if (this.pieData.length === 0) {
              // 空数据提示
              Text('暂无分类数据')
                .fontSize(13)
                .fontColor('#90A4AE')
                .width('100%')
                .height(140)
                .textAlign(TextAlign.Center)
            } else {
              // 饼图：颜色按分类区分，百分比显示在扇区上
              PieChart({ model: this.pieModel })
                .width('100%')
                .height(240)
                .margin({ top: 6 })

              // 自定义图例：彩色圆点 + 分类名称 + 占比
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.pieData, (item: PieItem) => {
                  Row() {
                    Text('●')
                      .fontSize(10)
                      .fontColor(this.pieColorText(item.name))
                    Text(item.name + ' ' + String(item.percent) + '%')
                      .fontSize(11)
                      .fontColor('#546E7A')
                      .margin({ left: 4 })
                  }
                  .margin({ right: 12, top: 6 })
                // key 必须带上数值：只按 name 做 key 时 ArkUI 会复用旧节点，
                // 切换日/周/月后圆点还在、百分比却不刷新，图例就会和饼图对不上
                }, (item: PieItem) => item.name + '|' + item.percent + '|' + item.value)
              }
              .width('100%')
              .margin({ top: 4 })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12 })

          // ---------- 容器 4：数据明细 ----------
          Column() {
            Text('数据明细')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#263238')
            Text('当前时间范围下的逐项数据')
              .fontSize(11)
              .fontColor('#90A4AE')
              .margin({ top: 2 })

            if (this.trendData.length === 0) {
              // 空数据提示
              Text('暂无明细数据')
                .fontSize(13)
                .fontColor('#90A4AE')
                .width('100%')
                .height(100)
                .textAlign(TextAlign.Center)
            } else {
              ForEach(this.trendData, (item: TrendItem) => {
                Row() {
                  Text(item.label)
                    .fontSize(13)
                    .fontColor('#455A64')
                    .layoutWeight(1)
                  Text(item.value.toFixed(2) + ' kg')
                    .fontSize(13)
                    .fontColor('#2E7D32')
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                  Text('+' + String(item.point))
                    .fontSize(13)
                    .fontColor('#F9A825')
                    .width(60)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .border({ width: { bottom: 1 }, color: '#F0F0F0' })
              }, (item: TrendItem) => item.label + '|' + item.value + '|' + item.point)
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .margin({ top: 12, bottom: 20 })
        }
        .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)

        // 加载遮罩：切换周期时盖在图表上方，避免看到旧数据闪动
        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color(COLOR_PRIMARY)
            Text('正在加载' + this.rangeLabel + '数据…')
              .fontSize(13)
              .fontColor(COLOR_TEXT_SECONDARY)
              .margin({ top: 8 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#CCF1F3F5')
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .backgroundColor('#F1F3F5')
    .alignItems(HorizontalAlign.Start)
  }
}
