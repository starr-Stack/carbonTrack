/*
 * 文件名：BackupService.ets
 * 功能：本地数据备份 + 统计报表导出。
 *
 * 设计说明：
 *   1. 备份内容：carbon_record、user_info、daily_point_summary、task_list、badge 五张表；
 *   2. 备份格式：JSON，带 app 标识和 schemaVersion，便于识别；
 *
 *   3. 保存位置：通过系统文件选择器让用户选择（如下载目录），不依赖额外权限；
 *   4. 报表：CSV（带 BOM，Excel 打开不乱码），按时间倒序导出全部减碳记录。
 */

import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { relationalStore as rdb } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE } from '../model/TableType';
import { DBUtil } from '../common/DBUtil';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'BackupService';
/** 备份文件标识 */
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

}
