/*
 * 文件名：HistoryService.ets
 * 功能：历史记录查询服务——按日期范围和分类筛选 carbon_record，支持分页。
 *
 * 设计说明：
 *   1. 独立服务，不修改 DBUtil，页面只调用 queryRecords()；
 *   2. 日期范围基于 recordTime（yyyy-MM-dd HH:mm:ss），字符串可直接比较；
 *   3. 先查出全部匹配记录，再在内存里分页（学生项目数据量小，够用）；
 *   4. 以后要接 SQL 分页，只需替换本文件内部实现，页面不用改。
 */

import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE, CarbonRecord } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'HistoryService';

/** 历史记录筛选条件，字段为空表示不限制 */
export interface HistoryFilter {
  /** 开始日期，格式 yyyy-MM-dd */
  startDate?: string;
  /** 结束日期，格式 yyyy-MM-dd */
  endDate?: string;
  /** 分类 id，如 travel；为空表示全部分类 */
  categoryId?: string;
}

/** 分页结果 */
export interface PagedRecords {
  /** 符合条件的总条数 */
  total: number;
  /** 当前页的数据 */
  items: CarbonRecord[];
}

export class HistoryService {
  /**
   * 查询历史记录
   * @param filter    筛选条件
   * @param pageIndex 页码，从 1 开始；不传表示不分页
   * @param pageSize  每页条数；不传表示不分页
   */
  public static async queryRecords(filter: HistoryFilter, pageIndex?: number,
    pageSize?: number): Promise<PagedRecords> {
    const empty: PagedRecords = { total: 0, items: [] };
    if (!DBUtil.isReady()) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'query skipped: database not ready');
      return empty;
    }

    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.carbon_record);

    // 日期范围：两端都有时用 between，只有一端时用 >= / <=
    const hasStart: boolean = filter.startDate !== undefined && filter.startDate.length > 0;
    const hasEnd: boolean = filter.endDate !== undefined && filter.endDate.length > 0;
    if (hasStart && hasEnd) {
      predicates.between('recordTime',
        (filter.startDate as string) + ' 00:00:00',
        (filter.endDate as string) + ' 23:59:59');
    } else if (hasStart) {
      predicates.greaterThanOrEqualTo('recordTime', (filter.startDate as string) + ' 00:00:00');
    } else if (hasEnd) {
      predicates.lessThanOrEqualTo('recordTime', (filter.endDate as string) + ' 23:59:59');
    }

    // 分类筛选
    if (filter.categoryId !== undefined && filter.categoryId.length > 0) {
      predicates.equalTo('categoryId', filter.categoryId);
    }

    // 时间倒序，同一时间按 id 倒序，保证顺序稳定
    predicates.orderByDesc('recordTime');
    predicates.orderByDesc('id');

    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.carbon_record, predicates);
    const all: CarbonRecord[] = [];
    for (const row of rows) {
      all.push(HistoryService.toRecord(row));
    }

    // 内存分页；不传 pageSize 时返回全部
    let items: CarbonRecord[] = all;
    if (pageSize !== undefined && pageSize > 0) {
      const index: number = pageIndex !== undefined && pageIndex > 0 ? pageIndex : 1;
      const start: number = (index - 1) * pageSize;
      items = all.slice(start, start + pageSize);
    }

    return { total: all.length, items: items };
  }

  /** 行数据 -> CarbonRecord */
  private static toRecord(row: rdb.ValuesBucket): CarbonRecord {
    return {
      id: HistoryService.asNumber(row['id']),
      recordTime: HistoryService.asText(row['recordTime']),
      categoryId: HistoryService.asText(row['categoryId']),
      itemId: HistoryService.asText(row['itemId']),
      itemName: HistoryService.asText(row['itemName']),
      amount: HistoryService.asNumber(row['amount']),
      unit: HistoryService.asText(row['unit']),
      reduceCo2: HistoryService.asNumber(row['reduceCo2']),
      getPoint: HistoryService.asNumber(row['getPoint']),
      remark: HistoryService.asText(row['remark'])
    };
  }

  private static asNumber(value: rdb.ValueType): number {
    return typeof value === 'number' ? value : 0;
  }

  private static asText(value: rdb.ValueType): string {
    return typeof value === 'string' ? value : '';
  }
}
