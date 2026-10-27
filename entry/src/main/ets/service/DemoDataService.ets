/*
 * 文件名：DemoDataService.ets
 * 存放路径：entry/src/main/ets/service/DemoDataService.ets
 * 功能：演示数据的一键载入与清空，供答辩/演示时快速构造一份"像用过一段时间"的数据。
 *
 * 设计说明：
 *   1. 写入的是真实数据表，不是界面上的假数据：首页、看板、任务、徽章、证书、CSV 导出
 *      读到的都是同一批记录，因此各页面数字天然一致，不会出现"看板和首页对不上"；
 *   2. 记录统一走 DBUtil.addCarbonRecord()，由它在同一个事务里写明细、日汇总、用户累计，
 *      这里不手写 INSERT，避免出现"有明细没汇总"的脏数据；
 *   3. 减排量用 CarbonCalculator 的因子实时计算，不写死数值，因子库调整后示例数据自动跟着变；
 *   4. 随机数用固定种子的 Lehmer 生成器，每次载入生成的数据完全一致，演示可复现；
 *   5. seed() 开头先 clearAll()，重复点击不会产生重复记录。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE, CarbonRecord } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';
import { AppState } from '../model/AppState';
import { CarbonCalculator, CalcResult, Category, FactorItem } from '../utils/CarbonCalculator';
import { TaskService, ClaimResult } from './TaskService';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'DemoDataService';
/** user_info 固定单行 */
const USER_ROW_ID: number = 1;
/** 示例记录条数 */
const RECORD_COUNT: number = 40;
/** 数据铺开的天数：覆盖最近 12 周，保证日/周/月三个视图都有点 */
const SPAN_DAYS: number = 84;
/** 一天毫秒数 */
const DAY_MS: number = 86400000;
/** 模拟领奖的任务数（每枚徽章绑一个任务，领 2 个任务即解锁 2 枚徽章） */
const CLAIM_COUNT: number = 2;
/** 参与示例数据的最大单位因子：高于它的行为（换 LED、换家电等）单条就是几十公斤，不符合个人三个月的量级 */
const LIGHT_ITEM_MAX_FACTOR: number = 3;
/** 单条记录的数量上限，避免"500 升水"这类极端值 */
const MAX_AMOUNT: number = 50;
/** 因子表未给上限时的默认数量上限 */
const DEFAULT_MAX_AMOUNT: number = 6;
/** 单条记录的减排量目标区间（kg），反推数量用 */
const CO2_MIN: number = 0.15;
const CO2_RANGE: number = 80;
/** 固定落在最近 7 天的记录条数，保证「日」视图不是一条平线 */
const RECENT_RECORDS: number = 12;

/** 载入结果，供页面提示文案使用 */
export interface DemoSeedResult {
  /** 实际写入的记录条数 */
  records: number;
  /** 模拟的领奖次数（决定解锁几枚徽章） */
  claims: number;
  /** 写入记录的减排量合计 kgCO2e */
  co2: number;
}

/** task_init.json 中本服务用到的字段（配置 DTO，非数据库实体） */
interface TaskSeedItem {
  taskId?: string;
  taskName?: string;
  rewardPoint?: number;
}

/** Lehmer 随机数生成器的状态容器 */
interface Rng {
  state: number;
}

export class DemoDataService {
  /**
   * 载入示例数据。
   * 流程：清空 → 模拟 2 次领奖（解锁 2 枚徽章）→ 按因子库生成 40 条记录铺在最近 84 天。
   * 先领奖再写记录，是为了避开每日积分上限：领奖时"今日已得"还是 0，两笔奖励必然发放。
   * @param context 页面上下文，用于读取 rawfile/task_init.json
   */
  public static async seed(context: common.Context): Promise<DemoSeedResult> {
    if (!DBUtil.isReady()) {
      throw new Error('数据库尚未就绪');
    }
    // 先清空，保证重复点击不会叠加
    const cleared: boolean = await DemoDataService.clearAll();
    if (!cleared) {
      throw new Error('清空旧数据失败');
    }

    // ① 模拟领奖：任务页显示"已领取"，徽章页据此解锁
    let claims: number = 0;
    const tasks: TaskSeedItem[] = DemoDataService.readTasks(context);
    for (const task of tasks) {
      if (claims >= CLAIM_COUNT) {
        break;
      }
      const taskId: string = task.taskId ?? '';
      const rewardPoint: number = task.rewardPoint ?? 0;
      if (taskId.length === 0 || rewardPoint <= 0) {
        continue;
      }
      const claim: ClaimResult = await TaskService.claimReward(taskId, task.taskName ?? taskId, rewardPoint);
      if (claim.success) {
        claims += 1;
      } else if (claim.capped) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'claim capped: %{public}s', taskId);
      }
    }

    // ② 生成减碳记录
    const calc: CarbonCalculator = CarbonCalculator.getInstance();
    if (!calc.isReady()) {
      await calc.init(context);
    }
    const categories: Category[] = calc.getCategories();
    if (categories.length === 0) {
      throw new Error('碳因子库未就绪，无法生成示例数据');
    }

    const rng: Rng = { state: 20261027 };
    const now: Date = new Date();
    let records: number = 0;
    let co2: number = 0;

    for (let i: number = 0; i < RECORD_COUNT; i++) {
      // 轮转分类，保证每个分类都有记录，饼图才有内容
      const category: Category = categories[i % categories.length];
      // 只从"日常轻量行为"里取：单位因子太大（换 LED、换家电、换肉）的一条就顶别人一个月，
      // 拼出来的演示数据不像个人三个月的记录
      const pool: FactorItem[] =
        category.items.filter((entry: FactorItem) => entry.factor <= LIGHT_ITEM_MAX_FACTOR);
      if (pool.length === 0) {
        continue;
      }
      const item: FactorItem = pool[DemoDataService.nextInt(rng, pool.length)];
      const rawMax: number = item.maxPerRecord === undefined ? 0 : item.maxPerRecord;
      const cap: number = rawMax > 0 ? Math.min(rawMax, MAX_AMOUNT) : DEFAULT_MAX_AMOUNT;
      // 先定"这一条大约减多少"，再反推数量：不同行为的单位（km / kwh / kg / meal）差别太大，
      // 直接随机数量会得到从 0.03 kg 到 30 kg 的一堆离谱值
      const targetCo2: number = CO2_MIN + DemoDataService.nextInt(rng, CO2_RANGE) / 100;
      const amount: number = Math.max(1, Math.min(Math.round(targetCo2 / item.factor), cap));
      const calcResult: CalcResult = calc.calcReduceCO2(category.id, item.id, amount);
      if (calcResult.reduceCo2 <= 0) {
        continue;
      }

      // 前 12 条固定在最近 7 天，保证「日」视图有点；其余铺到 84 天内
      const offsetDays: number = i < RECENT_RECORDS
        ? (i % 7) : 7 + DemoDataService.nextInt(rng, SPAN_DAYS - 7);
      const day: Date = new Date(now.getTime() - offsetDays * DAY_MS);
      const hour: number = 7 + DemoDataService.nextInt(rng, 13);
      const minute: number = DemoDataService.nextInt(rng, 60);

      const record: CarbonRecord = {
        recordTime: DemoDataService.stamp(day, hour, minute),
        categoryId: category.id,
        itemId: item.id,
        itemName: item.name,
        amount: amount,
        unit: item.unit,
        reduceCo2: calcResult.reduceCo2,
        getPoint: calcResult.getPoint,
        remark: '演示数据'
      };
      const id: number = await DBUtil.addCarbonRecord(record);
      if (id > 0) {
        records += 1;
        co2 += calcResult.reduceCo2;
      }
    }

    // 今日积分缓存按新数据重算
    AppState.loadTodayPoint();

    const result: DemoSeedResult = {
      records: records,
      claims: claims,
      co2: Math.round(co2 * 100) / 100
    };
    hilog.info(LOG_DOMAIN, LOG_TAG, 'seeded: %{public}d records, %{public}d claims, co2=%{public}s',
      records, claims, String(result.co2));
    return result;
  }

  /**
   * 清空全部业务数据：减碳记录、日汇总、领奖记录、徽章解锁记录，并把用户累计归零。
   * 静态内容（任务定义、徽章定义、科普文章、碳因子库）都在 rawfile 里，不受影响。
   * @returns 是否清空成功
   */
  public static async clearAll(): Promise<boolean> {
    if (!DBUtil.isReady()) {
      return false;
    }
    const ok: boolean = await DBUtil.runInTransaction(async (store: rdb.RdbStore) => {
      await store.executeSql('DELETE FROM ' + TABLE.carbon_record);
      await store.executeSql('DELETE FROM ' + TABLE.daily_point_summary);
      await store.executeSql('DELETE FROM ' + TABLE.task_list);
      await store.executeSql('DELETE FROM ' + TABLE.badge);
      // user_info 保留这一行，只把累计值归零，避免后续 UPDATE 落空
      await store.executeSql('UPDATE ' + TABLE.user_info +
        ' SET total_co2 = ?, total_point = ? WHERE id = ?', [0, 0, USER_ROW_ID]);
    });
    if (ok) {
      AppState.resetTodayPoint();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'all business data cleared');
    } else {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'clear failed');
    }
    return ok;
  }

  /** 读取 task_init.json（读不到时返回空数组，不影响记录写入） */
  private static readTasks(context: common.Context): TaskSeedItem[] {
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync('task_init.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const text: string = decoder.decodeToString(bytes);
      const parsed: TaskSeedItem[] = JSON.parse(text) as TaskSeedItem[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read task_init.json failed: %{public}s',
        DemoDataService.describe(err));
      return [];
    }
  }

  /**
   * Lehmer 随机数（state = state * 16807 % 2147483647）。
   * 同一种子永远产出同一串数，且乘积 < 2^53，不会丢精度。
   */
  private static nextInt(rng: Rng, bound: number): number {
    rng.state = (rng.state * 16807) % 2147483647;
    return rng.state % bound;
  }

  /** Date + 时分 -> yyyy-MM-dd HH:mm:ss */
  private static stamp(day: Date, hour: number, minute: number): string {
    const month: string = DemoDataService.pad(day.getMonth() + 1);
    const date: string = DemoDataService.pad(day.getDate());
    return day.getFullYear() + '-' + month + '-' + date +
      ' ' + DemoDataService.pad(hour) + ':' + DemoDataService.pad(minute) + ':00';
  }

  private static pad(value: number): string {
    return value < 10 ? '0' + value : String(value);
  }

  private static describe(err: Object): string {
    return err instanceof Error ? err.message : String(err);
  }
}
