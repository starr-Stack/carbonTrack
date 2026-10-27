/*
 * 文件名：StatisticsService.ets
 * 存放路径：entry/src/main/ets/service/StatisticsService.ets
 * 功能：看板的统计查询与图表数据组装。
 *
 * 设计说明：
 *   1. 页面只拿 TrendItem / PieItem 两种 DTO，不碰 SQL、不碰图表库；
 *   2. 聚合下推到 SQL：按 substr(recordTime,1,10) 分组，一次查询拿到每天的减排量与积分；
 *   3. 周/月/年分桶在内存里做：SQL 只负责最擅长的按日聚合，ISO 周、自然月、年的口径由代码控制；
 *   4. 先造桶再填值（不是"查到什么画什么"），时间轴上不会出现断点，缺失的周期补 0；
 *   5. recordTime 是 yyyy-MM-dd HH:mm:ss 文本，字典序即时间序，可以直接做字符串比较。
 */

import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE, UserInfo } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';
import { CarbonCalculator, Category } from '../utils/CarbonCalculator';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'StatisticsService';
const DAY_MS: number = 86400000;
/** 日视图：最近 7 天 */
const DAY_BUCKETS: number = 7;
/** 周视图：最近 4 周（一个月内看四周的变化） */
const WEEK_BUCKETS: number = 4;
/** 月视图：最近 6 个自然月 */
const MONTH_BUCKETS: number = 6;
/** 年视图：最近 5 年 */
const YEAR_BUCKETS: number = 5;

/** 趋势数据项：某个周期的减排量与积分 */
export interface TrendItem {
  /** 展示标签：10-24 / 10/05-10/11 / 2026-10 / 2026 */
  label: string;
  /** 减排量，kgCO2e */
  value: number;
  /** 当期积分 */
  point: number;
}

/** 饼图数据项：某个分类的占比 */
export interface PieItem {
  /** 分类中文名 */
  name: string;
  /** 该分类减排量，kgCO2e */
  value: number;
  /** 占比 0-100，整数，合计恒为 100 */
  percent: number;
}

/** 累计统计（取 user_info 全量值） */
export interface TotalStat {
  co2: number;
  point: number;
}

/** 时间桶：key 用于匹配数据库结果，label 用于坐标轴显示 */
interface Bucket {
  key: string;
  label: string;
}

/** 某一天的聚合值 */
interface DayAgg {
  co2: number;
  point: number;
}

/** ISO 周信息 */
interface IsoWeek {
  year: number;
  week: number;
}

export class StatisticsService {
  /**
   * 趋势数据：按周期分桶、时间升序、空桶补零。
   * @param range 日 / 周 / 月 / 年，非法值按「日」处理
   * @returns 窗口内没有记录时返回空数组（页面据此显示"暂无数据"）
   */
  public static async queryTrend(range: string): Promise<TrendItem[]> {
    const buckets: Bucket[] = StatisticsService.buildBuckets(range);
    if (buckets.length === 0) {
      return [];
    }
    const rows: Array<rdb.ValuesBucket> =
      await StatisticsService.queryDaily(StatisticsService.windowStart(range));
    if (rows.length === 0) {
      return [];
    }

    // 先按桶归并；周要多算一步 ISO 周归属
    const acc: Map<string, DayAgg> = new Map<string, DayAgg>();
    for (const row of rows) {
      const day: string = StatisticsService.asText(row['day']);
      if (day.length < 10) {
        continue;
      }
      const key: string = StatisticsService.bucketKey(day, range);
      const co2: number = StatisticsService.asNumber(row['co2']);
      const point: number = StatisticsService.asNumber(row['point']);
      const cur: DayAgg | undefined = acc.get(key);
      if (cur === undefined) {
        acc.set(key, { co2: co2, point: point });
      } else {
        cur.co2 += co2;
        cur.point += point;
      }
    }

    const list: TrendItem[] = [];
    for (const bucket of buckets) {
      const value: DayAgg | undefined = acc.get(bucket.key);
      list.push({
        label: bucket.label,
        value: value === undefined ? 0 : StatisticsService.round2(value.co2),
        point: value === undefined ? 0 : Math.round(value.point)
      });
    }
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'trend %{public}s: %{public}d buckets, %{public}d daily rows',
      range, list.length, rows.length);
    return list;
  }

  /**
   * 分类占比：同一时间窗口内按 categoryId 聚合，降序返回。
   * 百分比各自四舍五入后合计可能是 99 或 101，把误差补到占比最大的分类上。
   */
  public static async queryCategoryShare(range: string): Promise<PieItem[]> {
    if (!DBUtil.isReady()) {
      return [];
    }
    const sql: string = 'SELECT categoryId, SUM(reduceCo2) AS co2 FROM ' + TABLE.carbon_record +
      ' WHERE recordTime >= ? GROUP BY categoryId ORDER BY co2 DESC';
    const rows: Array<rdb.ValuesBucket> =
      await DBUtil.querySql(sql, [StatisticsService.windowStart(range) + ' 00:00:00']);
    if (rows.length === 0) {
      return [];
    }

    const items: PieItem[] = [];
    let total: number = 0;
    for (const row of rows) {
      const value: number = StatisticsService.round2(StatisticsService.asNumber(row['co2']));
      if (value <= 0) {
        continue;
      }
      items.push({
        name: StatisticsService.categoryName(StatisticsService.asText(row['categoryId'])),
        value: value,
        percent: 0
      });
      total += value;
    }
    if (items.length === 0 || total <= 0) {
      return [];
    }

    let sum: number = 0;
    for (let i: number = 0; i < items.length; i++) {
      const percent: number = Math.round(items[i].value / total * 100);
      items[i].percent = percent;
      sum += percent;
    }
    // 补误差：items[0] 是 SUM 最大的分类，改它的影响最小
    if (sum !== 100) {
      items[0].percent += 100 - sum;
    }
    return items;
  }

  /** 累计统计：直接取 user_info，保证与首页、证书页口径一致 */
  public static async queryTotals(): Promise<TotalStat> {
    const empty: TotalStat = { co2: 0, point: 0 };
    if (!DBUtil.isReady()) {
      return empty;
    }
    const info: UserInfo = await DBUtil.getUserInfo();
    return {
      co2: StatisticsService.round2(info.total_co2),
      point: Math.round(info.total_point)
    };
  }

  /* ============================ 查询 ============================ */

  /** 窗口内按日聚合；recordTime 是 yyyy-MM-dd HH:mm:ss，可直接与下界比较 */
  private static async queryDaily(from: string): Promise<Array<rdb.ValuesBucket>> {
    if (!DBUtil.isReady()) {
      return [];
    }
    const sql: string = 'SELECT substr(recordTime, 1, 10) AS day, ' +
      'SUM(reduceCo2) AS co2, SUM(getPoint) AS point FROM ' + TABLE.carbon_record +
      ' WHERE recordTime >= ? GROUP BY day ORDER BY day ASC';
    return await DBUtil.querySql(sql, [from + ' 00:00:00']);
  }

  /* ============================ 时间桶 ============================ */

  /** 窗口下界（含），格式 yyyy-MM-dd */
  private static windowStart(range: string): string {
    const today: Date = StatisticsService.today();
    if (range === '周') {
      const monday: Date = StatisticsService.mondayOf(today);
      return StatisticsService.dateKey(new Date(monday.getTime() - (WEEK_BUCKETS - 1) * 7 * DAY_MS));
    }
    if (range === '月') {
      return StatisticsService.dateKey(
        new Date(today.getFullYear(), today.getMonth() - (MONTH_BUCKETS - 1), 1));
    }
    if (range === '年') {
      return (today.getFullYear() - (YEAR_BUCKETS - 1)) + '-01-01';
    }
    return StatisticsService.dateKey(new Date(today.getTime() - (DAY_BUCKETS - 1) * DAY_MS));
  }

  /** 生成完整桶序列，顺序即坐标轴顺序 */
  private static buildBuckets(range: string): Bucket[] {
    const today: Date = StatisticsService.today();
    const list: Bucket[] = [];
    if (range === '周') {
      // 以周一为起点，往前数 4 周；标签用 10/05-10/11 这种区间，比"第41周"直观
      const monday: Date = StatisticsService.mondayOf(today);
      for (let i: number = WEEK_BUCKETS - 1; i >= 0; i--) {
        const start: Date = new Date(monday.getTime() - i * 7 * DAY_MS);
        const end: Date = new Date(start.getTime() + 6 * DAY_MS);
        const week: IsoWeek = StatisticsService.isoWeek(start);
        list.push({
          key: week.year + '-W' + StatisticsService.pad(week.week),
          label: StatisticsService.monthDay(start) + '-' + StatisticsService.monthDay(end)
        });
      }
      return list;
    }
    if (range === '月') {
      for (let i: number = MONTH_BUCKETS - 1; i >= 0; i--) {
        const d: Date = new Date(today.getFullYear(), today.getMonth() - i, 1);
        const key: string = d.getFullYear() + '-' + StatisticsService.pad(d.getMonth() + 1);
        list.push({ key: key, label: key });
      }
      return list;
    }
    if (range === '年') {
      for (let i: number = YEAR_BUCKETS - 1; i >= 0; i--) {
        const year: string = String(today.getFullYear() - i);
        list.push({ key: year, label: year });
      }
      return list;
    }
    for (let i: number = DAY_BUCKETS - 1; i >= 0; i--) {
      const d: Date = new Date(today.getTime() - i * DAY_MS);
      list.push({ key: StatisticsService.dateKey(d), label: StatisticsService.monthDay(d) });
    }
    return list;
  }

  /** 某一天归属哪个桶 */
  private static bucketKey(day: string, range: string): string {
    if (range === '周') {
      const week: IsoWeek = StatisticsService.isoWeek(StatisticsService.parseDay(day));
      return week.year + '-W' + StatisticsService.pad(week.week);
    }
    if (range === '月') {
      return day.substring(0, 7);
    }
    if (range === '年') {
      return day.substring(0, 4);
    }
    return day;
  }

  /* ============================ 日期工具 ============================ */

  private static today(): Date {
    const now: Date = new Date();
    return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  }

  /** 本周周一（周一为一周起点） */
  private static mondayOf(date: Date): Date {
    const index: number = (date.getDay() + 6) % 7;
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() - index);
  }

  /** ISO 8601 周：周四所在的年份就是该周的年份，避免跨年周被算错 */
  private static isoWeek(date: Date): IsoWeek {
    const d: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    const shift: number = (d.getDay() + 6) % 7;
    d.setDate(d.getDate() - shift + 3);
    const isoYear: number = d.getFullYear();
    const firstThursday: Date = new Date(isoYear, 0, 4);
    const firstShift: number = (firstThursday.getDay() + 6) % 7;
    firstThursday.setDate(firstThursday.getDate() - firstShift + 3);
    const week: number = 1 +
      Math.round((d.getTime() - firstThursday.getTime()) / (7 * DAY_MS));
    return { year: isoYear, week: week };
  }

  private static dateKey(date: Date): string {
    return date.getFullYear() + '-' + StatisticsService.pad(date.getMonth() + 1) +
      '-' + StatisticsService.pad(date.getDate());
  }

  /** MM/DD，用于周区间的起止 */
  private static monthDay(date: Date): string {
    return StatisticsService.pad(date.getMonth() + 1) + '/' + StatisticsService.pad(date.getDate());
  }

  private static parseDay(day: string): Date {
    const parts: string[] = day.split('-');
    if (parts.length < 3) {
      return StatisticsService.today();
    }
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  }

  /* ============================ 杂项 ============================ */

  /** categoryId -> 中文名；因子库没就绪时退回内置映射 */
  private static categoryName(categoryId: string): string {
    try {
      const calc: CarbonCalculator = CarbonCalculator.getInstance();
      if (calc.isReady()) {
        const categories: Category[] = calc.getCategories();
        const hit: Category | undefined =
          categories.find((item: Category) => item.id === categoryId);
        if (hit !== undefined && hit.name.length > 0) {
          return hit.name;
        }
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'categoryName failed: %{public}s',
        err instanceof Error ? err.message : String(err));
    }
    if (categoryId === 'travel') {
      return '出行';
    }
    if (categoryId === 'electricity') {
      return '节电';
    }
    if (categoryId === 'water') {
      return '节水';
    }
    if (categoryId === 'recycle') {
      return '旧物回收';
    }
    if (categoryId === 'food') {
      return '光盘行动';
    }
    return categoryId;
  }

  private static asNumber(value: rdb.ValueType): number {
    return typeof value === 'number' ? value : 0;
  }

  private static asText(value: rdb.ValueType): string {
    return typeof value === 'string' ? value : '';
  }

  private static round2(value: number): number {
    return Math.round(value * 100) / 100;
  }

  private static pad(value: number): string {
    return value < 10 ? '0' + value : String(value);
  }
}
