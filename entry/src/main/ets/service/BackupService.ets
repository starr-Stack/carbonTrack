/*
 * 文件名：BackupService.ets
 * 功能：本地数据备份 / 恢复 + 统计报表导出。
 *
 * 设计说明：
 *   1. 备份内容：carbon_record、user_info、daily_point_summary、task_list、badge 五张表；
 *   2. 备份格式：JSON，带 app 标识和 schemaVersion，恢复前校验，避免导入错文件；
 *   3. 恢复：在同一个事务里清空并重新写入五张表，失败整体回滚；
 *   4. 保存位置：通过系统文件选择器让用户选择（如下载目录），不依赖额外权限；
 *   5. 报表：CSV（带 BOM，Excel 打开不乱码），按时间倒序导出全部减碳记录。
 */

import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'BackupService';
/** 备份文件标识，恢复时校验 */
const APP_TAG: string = 'CarbonTrack';
/** 与 TableType.SCHEMA_VERSION 对应 */
const BACKUP_SCHEMA: number = 2;

/** 备份文件结构 */
interface BackupPayload {
  app: string;
  schemaVersion: number;
  exportedAt: string;
  carbon_record: Array<rdb.ValuesBucket>;
  user_info: Array<rdb.ValuesBucket>;
  daily_point_summary: Array<rdb.ValuesBucket>;
  task_list: Array<rdb.ValuesBucket>;
  badge: Array<rdb.ValuesBucket>;
}

/** 恢复结果 */
export interface RestoreResult {
  ok: boolean;
  /** 恢复的总行数，失败为 0 */
  rows: number;
  /** 失败原因，成功为空 */
  message: string;
}

export class BackupService {
  /** 生成备份 JSON 文本 */
  public static async buildBackupJson(): Promise<string> {
    if (!DBUtil.isReady()) {
      throw new Error('数据库尚未就绪');
    }
    const payload: BackupPayload = {
      app: APP_TAG,
      schemaVersion: BACKUP_SCHEMA,
      exportedAt: BackupService.nowText(),
      carbon_record: await BackupService.queryAll(TABLE.carbon_record),
      user_info: await BackupService.queryAll(TABLE.user_info),
      daily_point_summary: await BackupService.queryAll(TABLE.daily_point_summary),
      task_list: await BackupService.queryAll(TABLE.task_list),
      badge: await BackupService.queryAll(TABLE.badge)
    };
    return JSON.stringify(payload, null, 2);
  }

  /** 生成统计报表 CSV 文本（带 BOM，Excel 可直接打开） */
  public static async buildReportCsv(): Promise<string> {
    if (!DBUtil.isReady()) {
      throw new Error('数据库尚未就绪');
    }
    const rows: Array<rdb.ValuesBucket> = await BackupService.queryAll(TABLE.carbon_record);
    // 按时间倒序，和页面展示一致
    rows.sort((a: rdb.ValuesBucket, b: rdb.ValuesBucket) => {
      const ta: string = typeof a['recordTime'] === 'string' ? a['recordTime'] as string : '';
      const tb: string = typeof b['recordTime'] === 'string' ? b['recordTime'] as string : '';
      return tb.localeCompare(ta);
    });

    const lines: string[] = [];
    lines.push('记录时间,分类ID,行为ID,行为名称,数量,单位,减排量(kgCO2e),获得积分,备注');
    for (const row of rows) {
      const cells: string[] = [
        BackupService.text(row['recordTime']),
        BackupService.text(row['categoryId']),
        BackupService.text(row['itemId']),
        BackupService.text(row['itemName']),
        String(BackupService.number(row['amount'])),
        BackupService.text(row['unit']),
        String(BackupService.number(row['reduceCo2'])),
        String(BackupService.number(row['getPoint'])),
        BackupService.text(row['remark'])
      ];
      lines.push(cells.map((cell: string) => BackupService.escapeCsv(cell)).join(','));
    }
    return '\uFEFF' + lines.join('\r\n');
  }

  /**
   * 弹出系统保存框，把文本写入用户选择的位置
   * @returns true 保存成功；false 用户取消
   */
  public static async saveTextWithPicker(context: common.Context, fileName: string,
    content: string): Promise<boolean> {
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save(options);
    if (uris === undefined || uris.length === 0) {
      return false;
    }
    const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'saved: %{public}s', fileName);
    return true;
  }

  /**
   * 弹出系统选择框，读取备份文件并恢复
   */
  public static async pickAndRestore(context: common.Context): Promise<RestoreResult> {
    const failed: RestoreResult = { ok: false, rows: 0, message: '' };
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select(options);
    if (uris === undefined || uris.length === 0) {
      failed.message = '已取消';
      return failed;
    }

    let payload: BackupPayload;
    try {
      const text: string = BackupService.readTextFromUri(uris[0]);
      payload = JSON.parse(text) as BackupPayload;
    } catch (err) {
      failed.message = '文件读取或解析失败';
      return failed;
    }

    if (payload.app !== APP_TAG) {
      failed.message = '不是本应用的备份文件';
      return failed;
    }

    const total: number = payload.carbon_record.length + payload.user_info.length +
      payload.daily_point_summary.length + payload.task_list.length + payload.badge.length;

    const committed: boolean = await DBUtil.runInTransaction(async (store: rdb.RdbStore) => {
      await BackupService.replaceTable(store, TABLE.carbon_record, payload.carbon_record);
      await BackupService.replaceTable(store, TABLE.user_info, payload.user_info);
      await BackupService.replaceTable(store, TABLE.daily_point_summary, payload.daily_point_summary);
      await BackupService.replaceTable(store, TABLE.task_list, payload.task_list);
      await BackupService.replaceTable(store, TABLE.badge, payload.badge);
    });

    if (!committed) {
      failed.message = '写入数据库失败，已回滚';
      return failed;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'restored rows=%{public}d', total);
    return { ok: true, rows: total, message: '' };
  }

  /** 通过文件描述符读取文本，兼容文件选择器返回的 URI */
  private static readTextFromUri(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(buffer));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 清空并写入一张表 */
  private static async replaceTable(store: rdb.RdbStore, table: string,
    rows: Array<rdb.ValuesBucket>): Promise<void> {
    try {
      await store.delete(new rdb.RdbPredicates(table));
      for (const row of rows) {
        await store.insert(table, row);
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceTable %{public}s failed: %{public}s',
        table, BackupService.describe(err));
      throw err as Error;
    }
  }

  /** 查整张表 */
  private static async queryAll(table: string): Promise<Array<rdb.ValuesBucket>> {
    return await DBUtil.query(table, new rdb.RdbPredicates(table));
  }

  /** CSV 转义 */
  private static escapeCsv(value: string): string {
    if (value.indexOf(',') >= 0 || value.indexOf('"') >= 0 || value.indexOf('\n') >= 0) {
      return '"' + value.replace(/"/g, '""') + '"';
    }
    return value;
  }

  private static nowText(): string {
    const now: Date = new Date();
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return now.getFullYear() + '-' + p(now.getMonth() + 1) + '-' + p(now.getDate()) +
      ' ' + p(now.getHours()) + ':' + p(now.getMinutes()) + ':' + p(now.getSeconds());
  }

  /** 文件名用时间戳，避免覆盖 */
  public static fileStamp(): string {
    const now: Date = new Date();
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return now.getFullYear() + p(now.getMonth() + 1) + p(now.getDate()) + '-' +
      p(now.getHours()) + p(now.getMinutes()) + p(now.getSeconds());
  }

  private static text(value: rdb.ValueType): string {
    return typeof value === 'string' ? value : '';
  }

  private static number(value: rdb.ValueType): number {
    return typeof value === 'number' ? value : 0;
  }

  private static describe(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }
    return String(err);
  }
}
