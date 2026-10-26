/*
 * 文件名：TaskService.ets
 * 功能：低碳任务的进度计算与领奖入账（数据层）。
 *
 * 设计说明：
 *   1. 任务元数据（名称、奖励、绑定徽章）仍来自 rawfile/task_init.json，
 *      本服务只负责「运行状态」：进度查询、是否已领奖、领奖写入；
 *   2. 进度按 taskType 从 carbon_record 实时统计：
 *        record -> 总记录条数
 *        co2    -> 累计减排量
 *        其他   -> 对应 categoryId 的记录条数
 *   3. 领奖在一个事务里完成：额度校验 + 写 task_list 领奖记录 + 加 user_info 累计积分
 *      + 更新当天 daily_point_summary，任何一步失败整体回滚；
 *   4. 每日积分上限与记录页共用同一规则（CarbonCalculator 的 dailyCap）：
 *      今天已得积分 + 本次奖励 > 上限时，本次领取失败，任务保持可领取，次日再来；
 *   5. 幂等：同一个 taskId 已领过奖时直接返回 alreadyClaimed，不会重复发积分。
 */

import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';
import { CarbonCalculator } from '../utils/CarbonCalculator';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'TaskService';
/** user_info 固定单行 */
const USER_ROW_ID: number = 1;
/** 因子库没加载出来时的兜底上限，与 factors.json 的 dailyCap 保持一致 */
const FALLBACK_DAILY_CAP: number = 500;

/** 任务进度 */
export interface TaskProgress {
  /** 当前值：条数或减排量 */
  current: number;
  /** 目标值 */
  target: number;
}

/** 领奖结果 */
export interface ClaimResult {
  /** 是否成功发放积分 */
  success: boolean;
  /** 实际发放的积分，失败为 0 */
  awarded: number;
  /** 今日积分额度不足，本次未发放 */
  capped: boolean;
  /** 该任务之前已经领过 */
  alreadyClaimed: boolean;
}

export class TaskService {
  /**
   * 查询某个任务的进度
   * @param taskType   判定口径：record / co2 / travel / electricity / water / recycle / food
   * @param targetValue 目标值（来自 task_init.json 的 targetValue）
   */
  public static async getProgress(taskType: string, targetValue: number): Promise<TaskProgress> {
    const target: number = targetValue > 0 ? targetValue : 1;
    if (!DBUtil.isReady()) {
      return { current: 0, target: target };
    }

    let current: number = 0;
    if (taskType === 'co2') {
      const rows: Array<rdb.ValuesBucket> =
        await DBUtil.query(TABLE.carbon_record, new rdb.RdbPredicates(TABLE.carbon_record));
      for (const row of rows) {
        current += TaskService.asNumber(row['reduceCo2']);
      }
      current = Math.round(current * 100) / 100;
    } else if (taskType === 'record') {
      const rows: Array<rdb.ValuesBucket> =
        await DBUtil.query(TABLE.carbon_record, new rdb.RdbPredicates(TABLE.carbon_record));
      current = rows.length;
    } else if (taskType.length > 0) {
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.carbon_record);
      predicates.equalTo('categoryId', taskType);
      const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.carbon_record, predicates);
      current = rows.length;
    }

    return { current: current, target: target };
  }

  /** 查询已领奖的任务 id 列表 */
  public static async getClaimedTaskIds(): Promise<string[]> {
    const ids: string[] = [];
    if (!DBUtil.isReady()) {
      return ids;
    }
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.task_list);
    predicates.equalTo('finish', 1);
    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.task_list, predicates);
    for (const row of rows) {
      const taskId: rdb.ValueType = row['taskId'];
      if (typeof taskId === 'string' && taskId.length > 0) {
        ids.push(taskId);
      }
    }
    return ids;
  }

  /**
   * 领取任务奖励
   * @returns 领取结果；失败时 awarded 为 0
   */
  public static async claimReward(taskId: string, taskName: string,
    rewardPoint: number): Promise<ClaimResult> {
    const failed: ClaimResult = {
      success: false,
      awarded: 0,
      capped: false,
      alreadyClaimed: false
    };
    if (!DBUtil.isReady() || taskId.length === 0 || rewardPoint <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'claim skipped: invalid args');
      return failed;
    }

    let alreadyClaimed: boolean = false;
    let capped: boolean = false;
    const committed: boolean = await DBUtil.runInTransaction(async (store: rdb.RdbStore) => {
      alreadyClaimed = await TaskService.hasClaimed(store, taskId);
      if (alreadyClaimed) {
        return;
      }

      const earnedToday: number = await TaskService.readTodayPoint(store);
      const cap: number = TaskService.dailyCap();
      if (earnedToday + rewardPoint > cap) {
        capped = true;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'daily cap reached: %{public}d + %{public}d > %{public}d',
          earnedToday, rewardPoint, cap);
        return;
      }

      const record: rdb.ValuesBucket = {
        taskId: taskId,
        taskName: taskName,
        finish: 1,
        rewardPoint: rewardPoint,
        claimedAt: Date.now()
      };
      await TaskService.insertClaim(store, record);
      await TaskService.addUserPoint(store, rewardPoint);
      await TaskService.addDailyPoint(store, rewardPoint);
    });

    const success: boolean = committed && !alreadyClaimed && !capped;
    if (!committed) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'claim transaction failed: %{public}s', taskId);
    } else if (success) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'claimed: %{public}s +%{public}d', taskId, rewardPoint);
    }
    return {
      success: success,
      awarded: success ? rewardPoint : 0,
      capped: capped,
      alreadyClaimed: alreadyClaimed
    };
  }

  /** 每日积分上限：优先取因子库规则，取不到用 500 兜底 */
  private static dailyCap(): number {
    try {
      const rule = CarbonCalculator.getInstance().getPointsRule();
      if (rule !== undefined && rule.dailyCap > 0) {
        return rule.dailyCap;
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read daily cap failed, use fallback');
    }
    return FALLBACK_DAILY_CAP;
  }

  /** 是否已领奖 */
  private static async hasClaimed(store: rdb.RdbStore, taskId: string): Promise<boolean> {
    try {
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.task_list);
      predicates.equalTo('taskId', taskId);
      predicates.equalTo('finish', 1);
      let rs: rdb.ResultSet | undefined = undefined;
      try {
        rs = await store.query(predicates);
        return rs.goToFirstRow();
      } finally {
        if (rs !== undefined) {
          try {
            rs.close();
          } catch (err) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'close result set failed');
          }
        }
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'hasClaimed failed: %{public}s', TaskService.describe(err));
      throw err as Error;
    }
  }

  /** 写领奖记录 */
  private static async insertClaim(store: rdb.RdbStore, record: rdb.ValuesBucket): Promise<void> {
    try {
      await store.insert(TABLE.task_list, record);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'insertClaim failed: %{public}s', TaskService.describe(err));
      throw err as Error;
    }
  }

  /** 累计积分 +point */
  private static async addUserPoint(store: rdb.RdbStore, point: number): Promise<void> {
    try {
      await store.executeSql('UPDATE ' + TABLE.user_info +
        ' SET total_point = total_point + ? WHERE id = ?', [point, USER_ROW_ID]);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'addUserPoint failed: %{public}s', TaskService.describe(err));
      throw err as Error;
    }
  }

  /** 当天汇总积分 +point；没有当天汇总行时新建 */
  private static async addDailyPoint(store: rdb.RdbStore, point: number): Promise<void> {
    try {
      const day: string = TaskService.todayKey();
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
      predicates.equalTo('summaryDate', day);

      let rs: rdb.ResultSet | undefined = undefined;
      let summaryId: number = -1;
      let totalPoint: number = 0;
      try {
        rs = await store.query(predicates, ['id', 'totalPoint']);
        if (rs.goToFirstRow()) {
          const row: rdb.ValuesBucket = rs.getRow();
          summaryId = TaskService.asNumber(row['id']);
          totalPoint = TaskService.asNumber(row['totalPoint']);
        }
      } finally {
        if (rs !== undefined) {
          try {
            rs.close();
          } catch (err) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'close summary result set failed');
          }
        }
      }

      const now: number = Date.now();
      if (summaryId > 0) {
        const update: rdb.ValuesBucket = {
          totalPoint: totalPoint + point,
          updateTime: now
        };
        const updatePredicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
        updatePredicates.equalTo('id', summaryId);
        await store.update(update, updatePredicates);
      } else {
        const insert: rdb.ValuesBucket = {
          summaryDate: day,
          totalCo2: 0,
          totalPoint: point,
          recordCount: 0,
          createTime: now,
          updateTime: now
        };
        await store.insert(TABLE.daily_point_summary, insert);
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'addDailyPoint failed: %{public}s', TaskService.describe(err));
      throw err as Error;
    }
  }

  /** 读取今天的汇总积分，用于额度校验 */
  private static async readTodayPoint(store: rdb.RdbStore): Promise<number> {
    try {
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
      predicates.equalTo('summaryDate', TaskService.todayKey());
      let rs: rdb.ResultSet | undefined = undefined;
      try {
        rs = await store.query(predicates, ['totalPoint']);
        if (rs.goToFirstRow()) {
          return TaskService.asNumber(rs.getRow()['totalPoint']);
        }
        return 0;
      } finally {
        if (rs !== undefined) {
          try {
            rs.close();
          } catch (err) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'close today point result set failed');
          }
        }
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'readTodayPoint failed: %{public}s', TaskService.describe(err));
      throw err as Error;
    }
  }

  private static todayKey(): string {
    const now: Date = new Date();
    const month: string = now.getMonth() + 1 < 10 ? '0' + (now.getMonth() + 1) : String(now.getMonth() + 1);
    const day: string = now.getDate() < 10 ? '0' + now.getDate() : String(now.getDate());
    return now.getFullYear() + '-' + month + '-' + day;
  }

  private static asNumber(value: rdb.ValueType): number {
    return typeof value === 'number' ? value : 0;
  }

  private static describe(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }
    return String(err);
  }
}
