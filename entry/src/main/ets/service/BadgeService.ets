/*
 * 文件名：BadgeService.ets
 * 功能：低碳徽章的解锁记录持久化（数据层）。
 *
 * 设计说明：
 *   1. 解锁判定仍由 utils/BadgeUnlockUtil 完成（纯函数），本服务只负责存取；
 *   2. getUnlockedBadges() 返回 badgeId / badgeName / unlockedAt，供徽章详情展示解锁时间；
 *   3. getUnlockTime() 查询单枚徽章的解锁时间，未解锁返回 -1；
 *   4. saveUnlocked() 在事务里批量写入，按 badgeId 去重，重复调用不会产生重复记录。
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

/** 已解锁徽章（含解锁时间） */
export interface UnlockedBadge {
  badgeId: string;
  badgeName: string;
  /** 解锁时间戳（毫秒），0 表示异常数据 */
  unlockedAt: number;
}

export class BadgeService {
  /** 查询已解锁徽章（含名称与解锁时间），按解锁时间倒序 */
  public static async getUnlockedBadges(): Promise<UnlockedBadge[]> {
    const list: UnlockedBadge[] = [];
    if (!DBUtil.isReady()) {
      return list;
    }
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.badge);
    predicates.greaterThan('unlockedAt', 0);
    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.badge, predicates);
    for (const row of rows) {
      const badgeId: rdb.ValueType = row['badgeId'];
      if (typeof badgeId !== 'string' || badgeId.length === 0) {
        continue;
      }
      const badgeName: rdb.ValueType = row['badgeName'];
      const unlockedAt: rdb.ValueType = row['unlockedAt'];
      list.push({
        badgeId: badgeId,
        badgeName: typeof badgeName === 'string' ? badgeName : '',
        unlockedAt: typeof unlockedAt === 'number' ? unlockedAt : 0
      });
    }
    list.sort((a: UnlockedBadge, b: UnlockedBadge) => b.unlockedAt - a.unlockedAt);
    return list;
  }

  /** 查询已解锁的徽章 id 列表（兼容旧调用） */
  public static async getUnlockedBadgeIds(): Promise<string[]> {
    const badges: UnlockedBadge[] = await BadgeService.getUnlockedBadges();
    const ids: string[] = [];
    for (const item of badges) {
      ids.push(item.badgeId);
    }
    return ids;
  }

  /** 查询单枚徽章的解锁时间，未解锁返回 -1 */
  public static async getUnlockTime(badgeId: string): Promise<number> {
    if (!DBUtil.isReady() || badgeId.length === 0) {
      return -1;
    }
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.badge);
    predicates.equalTo('badgeId', badgeId);
    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.badge, predicates);
    if (rows.length === 0) {
      return -1;
    }
    const value: rdb.ValueType = rows[0]['unlockedAt'];
    return typeof value === 'number' && value > 0 ? value : -1;
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
