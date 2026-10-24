/*
 * 文件名：RecordDeleteService.ets
 * 功能：删除一条减碳记录，并在同一个事务里回滚它带来的日汇总和用户累计。
 *
 * 为什么单独一个文件：
 *   1. 删除要动三张表（carbon_record / daily_point_summary / user_info），
 *      逻辑比"插入一条"复杂，放在独立服务里，DBUtil 保持通用；
 *   2. 页面只调用 deleteRecord(id)，不关心内部怎么回滚；
 *   3. 不修改 DBUtil 的任何现有方法，旧功能不受影响。
 *
 * 事务保证：任何一步失败，整次删除回滚，不会出现"明细删了、统计没减"的脏数据。
 */
import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE, CarbonRecord } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'RecordDelete';
/** user_info 固定单行，主键为 1 */
const USER_ROW_ID: number = 1;

/** 删除结果：页面据此决定是否扣减今日积分、是否提示成功 */
export interface DeleteRecordResult {
  success: boolean;
  /** 被删除记录原本获得的积分（没有删除成功时为 0） */
  removedPoint: number;
  /** 被删除记录的时间，页面用它判断是不是"今天"的记录 */
  recordTime: string;
}

export class RecordDeleteService {
  /**
   * 删除一条记录并回滚相关统计。
   * @param id carbon_record 的主键
   */
  public static async deleteRecord(id: number): Promise<DeleteRecordResult> {
    const failed: DeleteRecordResult = { success: false, removedPoint: 0, recordTime: '' };
    if (!Number.isFinite(id) || id <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'invalid id: %{public}s', String(id));
      return failed;
    }

    let removedPoint: number = 0;
    let recordTime: string = '';

    const committed: boolean = await DBUtil.runInTransaction(async (store: rdb.RdbStore) => {
      const record: CarbonRecord | undefined = await RecordDeleteService.findRecord(store, id);
      if (record === undefined) {
        throw new Error('record not found: ' + id);
      }
      removedPoint = record.getPoint;
      recordTime = record.recordTime;

      await RecordDeleteService.deleteRow(store, id);
      await RecordDeleteService.rollbackDailySummary(store, record);
      await RecordDeleteService.rollbackUserTotals(store, record.reduceCo2, record.getPoint);
    });

    if (!committed) {
      return failed;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'record deleted: id=%{public}d, point=%{public}d', id, removedPoint);
    return { success: true, removedPoint: removedPoint, recordTime: recordTime };
  }

  /** 按 id 查一条记录，查不到返回 undefined */
  private static async findRecord(store: rdb.RdbStore, id: number): Promise<CarbonRecord | undefined> {
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.carbon_record);
    predicates.equalTo('id', id);
    let rs: rdb.ResultSet | undefined = undefined;
    try {
      rs = await store.query(predicates);
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      const row: rdb.ValuesBucket = rs.getRow();
      return {
        id: RecordDeleteService.asNumber(row['id']),
        recordTime: RecordDeleteService.asText(row['recordTime']),
        categoryId: RecordDeleteService.asText(row['categoryId']),
        itemId: RecordDeleteService.asText(row['itemId']),
        itemName: RecordDeleteService.asText(row['itemName']),
        amount: RecordDeleteService.asNumber(row['amount']),
        unit: RecordDeleteService.asText(row['unit']),
        reduceCo2: RecordDeleteService.asNumber(row['reduceCo2']),
        getPoint: RecordDeleteService.asNumber(row['getPoint']),
        remark: RecordDeleteService.asText(row['remark'])
      };
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'findRecord failed: %{public}s', RecordDeleteService.describe(err));
      throw err as Error;
    } finally {
      if (rs !== undefined) {
        try {
          rs.close();
        } catch (err) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'close result set failed');
        }
      }
    }
  }

  /** 删除明细行，必须真的删掉一条，否则让事务失败 */
  private static async deleteRow(store: rdb.RdbStore, id: number): Promise<void> {
    try {
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.carbon_record);
      predicates.equalTo('id', id);
      const rows: number = await store.delete(predicates);
      if (rows <= 0) {
        throw new Error('delete affected 0 rows, id=' + id);
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'deleteRow failed: %{public}s', RecordDeleteService.describe(err));
      throw err as Error;
    }
  }

  /** 把这笔记录从当天汇总里减掉；减到 0 条就删掉这一天的汇总行 */
  private static async rollbackDailySummary(store: rdb.RdbStore, record: CarbonRecord): Promise<void> {
    try {
      const day: string = record.recordTime.length >= 10 ? record.recordTime.substring(0, 10) : record.recordTime;
      const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
      predicates.equalTo('summaryDate', day);

      let summaryId: number = -1;
      let totalCo2: number = 0;
      let totalPoint: number = 0;
      let recordCount: number = 0;
      let rs: rdb.ResultSet | undefined = undefined;
      try {
        rs = await store.query(predicates, ['id', 'totalCo2', 'totalPoint', 'recordCount']);
        if (rs.goToFirstRow()) {
          const row: rdb.ValuesBucket = rs.getRow();
          summaryId = RecordDeleteService.asNumber(row['id']);
          totalCo2 = RecordDeleteService.asNumber(row['totalCo2']);
          totalPoint = RecordDeleteService.asNumber(row['totalPoint']);
          recordCount = RecordDeleteService.asNumber(row['recordCount']);
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

      // 没有汇总行（例如旧数据）时直接跳过，删除明细仍然有效
      if (summaryId <= 0) {
        return;
      }

      const nextCount: number = recordCount - 1;
      if (nextCount <= 0) {
        const del: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
        del.equalTo('id', summaryId);
        await store.delete(del);
      } else {
        const data: rdb.ValuesBucket = {
          totalCo2: Math.max(0, totalCo2 - record.reduceCo2),
          totalPoint: Math.max(0, totalPoint - record.getPoint),
          recordCount: nextCount,
          updateTime: Date.now()
        };
        const update: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
        update.equalTo('id', summaryId);
        await store.update(data, update);
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'rollbackDailySummary failed: %{public}s',
        RecordDeleteService.describe(err));
      throw err as Error;
    }
  }

  /** 用户累计值做减法，并用 max(...,0) 防止出现负数 */
  private static async rollbackUserTotals(store: rdb.RdbStore, co2: number, point: number): Promise<void> {
    try {
      const sql: string = 'UPDATE ' + TABLE.user_info +
        ' SET total_co2 = max(total_co2 - ?, 0), total_point = max(total_point - ?, 0) WHERE id = ?';
      await store.executeSql(sql, [co2, point, USER_ROW_ID]);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'rollbackUserTotals failed: %{public}s', RecordDeleteService.describe(err));
      throw err as Error;
    }
  }

  private static asNumber(value: rdb.ValueType): number {
    return typeof value === 'number' ? value : 0;
  }

  private static asText(value: rdb.ValueType): string {
    return typeof value === 'string' ? value : '';
  }

  private static describe(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }
    return String(err);
  }
}
