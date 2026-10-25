/*
 * 文件名：BadgeService.ets
 * 功能：低碳徽章的解锁记录持久化（数据层）。
 *
 * 设计说明：
 *   1. 解锁判定仍由 utils/BadgeUnlockUtil 完成（纯函数），本服务只负责存取；
 *   2. getUnlockedBadgeIds() 供页面回显已点亮徽章；
 *   3. saveUnlocked() 在事务里批量写入，按 badgeId 去重，重复调用不会产生重复记录；
 *   4. 徽章名称一起落库，方便后续做「我的徽章」页面或导出。
 */

import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'BadgeService';

/** 一条待写入的徽章解锁记录 */
export interface BadgeUnlockInput {
  badgeId: string;
  badgeName: string;
}

export class BadgeService {
  /** 查询已解锁的徽章 id 列表 */
  public static async getUnlockedBadgeIds(): Promise<string[]> {
    const ids: string[] = [];
    if (!DBUtil.isReady()) {
      return ids;
    }
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.badge);
    predicates.greaterThan('unlockedAt', 0);
    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.badge, predicates);
    for (const row of rows) {
      const badgeId: rdb.ValueType = row['badgeId'];
      if (typeof badgeId === 'string' && badgeId.length > 0) {
        ids.push(badgeId);
      }
    }
    return ids;
  }

  /**
   * 批量保存新解锁的徽章（幂等）
   * @returns 是否提交成功
   */
  public static async saveUnlocked(list: BadgeUnlockInput[]): Promise<boolean> {
    if (!DBUtil.isReady() || list.length === 0) {
      return true;
    }

    const committed: boolean = await DBUtil.runInTransaction(async (store: rdb.RdbStore) => {
      for (const item of list) {
        if (item.badgeId.length === 0) {
          continue;
        }
        const exists: boolean = await BadgeService.exists(store, item.badgeId);
        if (exists) {
          continue;
        }
        const record: rdb.ValuesBucket = {
          badgeId: item.badgeId,
          badgeName: item.badgeName,
          unlockedAt: Date.now()
        };
        await BadgeService.insert(store, record);
      }
    });

    if (!committed) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'saveUnlocked transaction failed');
    }
    return committed;
  }

  /** 该徽章是否已有记录 */
  private static async exists(store: rdb.RdbStore, badgeId: string): Promise<boolean> {
    try {
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.badge);
      predicates.equalTo('badgeId', badgeId);
      let rs: rdb.ResultSet | undefined = undefined;
      try {
        rs = await store.query(predicates, ['id']);
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
      hilog.error(LOG_DOMAIN, LOG_TAG, 'exists failed: %{public}s', BadgeService.describe(err));
      throw err as Error;
    }
  }

  private static async insert(store: rdb.RdbStore, record: rdb.ValuesBucket): Promise<void> {
    try {
      await store.insert(TABLE.badge, record);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'insert failed: %{public}s', BadgeService.describe(err));
      throw err as Error;
    }
  }

  private static describe(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }
    return String(err);
  }
}
