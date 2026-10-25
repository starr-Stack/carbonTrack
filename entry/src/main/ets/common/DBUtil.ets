/*
 * 文件名：DBUtil.ets
 * 功能：基于鸿蒙关系型数据库（relationalStore / RDB）的通用增删改查工具，
 *       以及碳足迹业务数据（carbon_record、user_info）的读写方法。
 *
 * 设计说明：
 *   1. 通用方法不写死表名，表名由调用方传入，后续新增数据表可直接复用；
 *   2. 所有 RDB 调用都包在 try/catch 中（避免 ArkTS "Function may throw exceptions" 告警），
 *      失败时返回安全默认值（-1 / 0 / []），并写 hilog 日志；
 *   3. ResultSet（游标）统一在 finally 中 close，保证资源释放；
 *   4. 行数据类型使用 rdb.ValueType 而不是 any：ArkTS 规范禁止 any，
 *      ValueType 与 rdb.ValuesBucket 的取值类型完全一致，调用方仍可传普通对象；
 *   5. API 版本：HarmonyOS API 12（getRow 为 API 11，limitAs/offsetAs 为 API 9，均可用）。
 */
import { relationalStore as rdb } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TABLE, CarbonRecord, UserInfo, SCHEMA_VERSION, TABLE_DEFS, buildCreateTableSql } from '../model/TableType';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'DBUtil';
const DB_NAME: string = 'carbon_db.db';
/** user_info 表只保留一条统计记录，主键固定为 1 */
const USER_ROW_ID: number = 1;

/*
 * 通用方法的 data 入参与查询结果统一使用 SDK 的 rdb.ValuesBucket
 * （等价于 Record<string, ValueType>，即“列名 -> 列值”），
 * 不额外定义行实体接口，字段定义以 model/TableType.ets 为准。
 */

let rdbStore: rdb.RdbStore | undefined = undefined;
/** 并发调用 initDB 时复用同一个初始化流程 */
let initPromise: Promise<boolean> | undefined = undefined;

export class DBUtil {
  // ==================================================================
  // 初始化
  // ==================================================================

  /**
   * 初始化数据库：创建 TABLE 中定义的数据表，并写入 user_info 初始行，可重复调用
   * @param context 建议传入 EntryAbility 的 this.context
   * @returns true 表示数据库可用；false 表示初始化失败（应用仍可运行，只是记录功能不可用）
   */
  public static async initDB(context: common.Context): Promise<boolean> {
    if (rdbStore !== undefined) {
      return true;
    }
    if (initPromise !== undefined) {
      return await initPromise;
    }
    initPromise = DBUtil.createStore(context);
    return await initPromise;
  }

  /** 数据库是否已就绪 */
  public static isReady(): boolean {
    return rdbStore !== undefined;
  }

  // ==================================================================
  // 通用增删改查（表名由调用方传入，可操作任意表）
  // ==================================================================

  /**
   * 通用插入
   * @param tableName 目标表名，如 TABLE.carbon_record
   * @param data      列名 -> 列值，键必须与表字段一致
   * @returns 新记录的主键 id；失败返回 -1
   *
   * 示例：
   *   const badge: rdb.ValuesBucket = { badgeName: '低碳新手' };
   *   await DBUtil.insert(TABLE.badge, badge);
   */
  public static async insert(tableName: string, data: rdb.ValuesBucket): Promise<number> {
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'insert skipped: database not ready');
      return -1;
    }
    if (!DBUtil.isValidTableName(tableName)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'insert failed: invalid table name %{public}s', tableName);
      return -1;
    }
    if (DBUtil.isEmptyData(data)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'insert skipped: empty data, table=%{public}s', tableName);
      return -1;
    }
    try {
      const bucket: rdb.ValuesBucket = data;
      const rowId: number = await store.insert(tableName, bucket);
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'insert into %{public}s ok, rowId=%{public}d', tableName, rowId);
      return rowId;
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'insert into %{public}s failed: %{public}s',
        tableName, DBUtil.describe(err));
      return -1;
    }
  }

  /**
   * 通用更新
   * @param tableName  表名（仅用于校验与日志，实际表由 predicates 携带）
   * @param data       需要更新的列，键必须与表字段一致
   * @param predicates 更新条件，必须用同一个表名构造：
   *                   new rdb.RdbPredicates(TABLE.carbon_record).equalTo('id', id)
   * @returns 受影响的行数；失败返回 0
   */
  public static async update(tableName: string, data: rdb.ValuesBucket, predicates: rdb.RdbPredicates): Promise<number> {
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'update skipped: database not ready');
      return 0;
    }
    if (!DBUtil.isValidTableName(tableName)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'update failed: invalid table name %{public}s', tableName);
      return 0;
    }
    if (DBUtil.isEmptyData(data)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'update skipped: empty data, table=%{public}s', tableName);
      return 0;
    }
    try {
      const bucket: rdb.ValuesBucket = data;
      const rows: number = await store.update(bucket, predicates);
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'update %{public}s ok, rows=%{public}d', tableName, rows);
      return rows;
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'update %{public}s failed: %{public}s',
        tableName, DBUtil.describe(err));
      return 0;
    }
  }

  /**
   * 通用删除
   * @param tableName  表名（仅用于校验与日志，实际表由 predicates 携带）
   * @param predicates 删除条件，必须用同一个表名构造
   * @returns 受影响的行数；失败返回 0
   */
  public static async delete(tableName: string, predicates: rdb.RdbPredicates): Promise<number> {
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'delete skipped: database not ready');
      return 0;
    }
    if (!DBUtil.isValidTableName(tableName)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'delete failed: invalid table name %{public}s', tableName);
      return 0;
    }
    try {
      const rows: number = await store.delete(predicates);
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'delete from %{public}s ok, rows=%{public}d', tableName, rows);
      return rows;
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'delete from %{public}s failed: %{public}s',
        tableName, DBUtil.describe(err));
      return 0;
    }
  }

  /**
   * 通用查询
   * @param tableName 表名（仅用于校验与日志，实际表由 predicates 携带）
   * @param predicates 查询条件/排序，必须用同一个表名构造
   * @param pageIndex 页码，从 1 开始，默认 1（仅在 pageSize > 0 时生效）
   * @param pageSize  每页条数，不传或 <= 0 表示不分页
   * @returns 查询结果，每一行是“列名 -> 列值”的对象；失败或无数据返回空数组
   *
   * 注意：分页会调用 predicates.limitAs()/offsetAs()，predicates 实例会被修改；
   *      如果要复用同一套条件反复查询，请每次重新 new rdb.RdbPredicates(...)。
   */
  public static async query(tableName: string, predicates: rdb.RdbPredicates,
    pageIndex?: number, pageSize?: number): Promise<Array<rdb.ValuesBucket>> {
    const rows: Array<rdb.ValuesBucket> = [];
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'query skipped: database not ready');
      return rows;
    }
    if (!DBUtil.isValidTableName(tableName)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'query failed: invalid table name %{public}s', tableName);
      return rows;
    }
    let rs: rdb.ResultSet | undefined = undefined;
    try {
      DBUtil.applyPagination(predicates, pageIndex, pageSize);
      rs = await store.query(predicates);
      while (rs.goToNextRow()) {
        rows.push(rs.getRow());
      }
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'query %{public}s ok, rows=%{public}d', tableName, rows.length);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'query %{public}s failed: %{public}s',
        tableName, DBUtil.describe(err));
    } finally {
      // ResultSet（游标）用完必须关闭，否则会泄漏数据库句柄
      DBUtil.closeQuietly(rs);
    }
    return rows;
  }

  /**
   * 执行任意 SQL（建表、迁移、批量语句），新增数据表时可复用
   * @param sql      要执行的 SQL
   * @param bindArgs 可选参数，使用 ? 占位符绑定，避免拼接 SQL
   * @returns 是否执行成功
   *
   * 示例：await DBUtil.executeSql('CREATE TABLE IF NOT EXISTS article(id INTEGER PRIMARY KEY, title TEXT)');
   */
  public static async executeSql(sql: string, bindArgs?: Array<rdb.ValueType>): Promise<boolean> {
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'executeSql skipped: database not ready');
      return false;
    }
    if (sql.trim().length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'executeSql skipped: empty sql');
      return false;
    }
    try {
      if (bindArgs === undefined) {
        await store.executeSql(sql);
      } else {
        await store.executeSql(sql, bindArgs);
      }
      return true;
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'executeSql failed: %{public}s', DBUtil.describe(err));
      return false;
    }
  }

  // ==================================================================
  // 碳足迹业务方法（全部基于上面的通用接口实现，可作调用范例）
  // ==================================================================

  /**
   * 新增一条减碳记录
   * @returns 新记录 id；失败返回 -1
   */
  public static async addCarbonRecord(item: CarbonRecord): Promise<number> {
    if (!Number.isFinite(item.amount) || item.amount <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'addCarbonRecord skipped: invalid amount %{public}s',
        String(item.amount));
      return -1;
    }
    let newId: number = -1;
    // 一条行为要同时写明细、日汇总、用户累计三张表，必须放在同一个事务里：
    // 任何一步失败都整体回滚，避免出现"有明细没汇总"的脏数据。
    const committed: boolean = await DBUtil.runInTransaction(async (store: rdb.RdbStore) => {
      newId = await store.insert(TABLE.carbon_record, DBUtil.toCarbonRecordBucket(item));
      if (newId <= 0) {
        throw new Error('insert carbon_record failed, rowId=' + newId);
      }
      await DBUtil.applyDailySummary(store, item);
      await DBUtil.addUserTotals(store, item.reduceCo2, item.getPoint);
    });
    if (!committed) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'addCarbonRecord rolled back');
      return -1;
    }
    return newId;
  }

  /**
   * 事务包装：work 内全部成功才提交，任意一步抛错则整体回滚。
   * @returns 是否提交成功
   */
  public static async runInTransaction(work: (store: rdb.RdbStore) => Promise<void>): Promise<boolean> {
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'transaction skipped: database not ready');
      return false;
    }
    try {
      store.beginTransaction();
      await work(store);
      store.commit();
      return true;
    } catch (err) {
      try {
        store.rollBack();
      } catch (rollbackErr) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'rollback failed: %{public}s', DBUtil.describe(rollbackErr));
      }
      hilog.error(LOG_DOMAIN, LOG_TAG, 'transaction rolled back: %{public}s', DBUtil.describe(err));
      return false;
    }
  }

  /** 用户累计值做加法（total_co2 / total_point），事务内部使用 */
  private static async addUserTotals(store: rdb.RdbStore, co2: number, point: number): Promise<void> {
    const sql: string = 'UPDATE ' + TABLE.user_info +
      ' SET total_co2 = total_co2 + ?, total_point = total_point + ? WHERE id = ?';
    try {
      await store.executeSql(sql, [co2, point, USER_ROW_ID]);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'addUserTotals failed: %{public}s', DBUtil.describe(err));
      throw err as Error;
    }
  }
  /**
   * 累加用户累计减排量与积分（对外方法，使用当前数据库连接）。
   * 与 updateUserInfo 的"绝对值覆盖"不同，本方法是增量写入，不会覆盖并发产生的增量。
   * @returns 是否更新成功
   */
  public static async incrementUserInfo(co2: number, point: number): Promise<boolean> {
    if (!Number.isFinite(co2) || !Number.isFinite(point) || co2 < 0 || point < 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'incrementUserInfo skipped: invalid value %{public}s/%{public}s',
        String(co2), String(point));
      return false;
    }
    const store: rdb.RdbStore | undefined = rdbStore;
    if (store === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'incrementUserInfo skipped: database not ready');
      return false;
    }
    try {
      await DBUtil.addUserTotals(store, co2, point);
      return true;
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'incrementUserInfo failed: %{public}s', DBUtil.describe(err));
      return false;
    }
  }

  /** 按天累加 daily_point_summary（同一天只保留一行），事务内部调用 */
  private static async applyDailySummary(store: rdb.RdbStore, item: CarbonRecord): Promise<void> {
    const day: string = item.recordTime.length >= 10 ? item.recordTime.substring(0, 10) : item.recordTime;
    const now: number = Date.now();
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
    predicates.equalTo('summaryDate', day);

    let existingId: number = -1;
    let totalCo2: number = 0;
    let totalPoint: number = 0;
    let recordCount: number = 0;
    let rs: rdb.ResultSet | undefined = undefined;
    try {
      rs = await store.query(predicates, ['id', 'totalCo2', 'totalPoint', 'recordCount']);
      if (rs.goToFirstRow()) {
        const row: rdb.ValuesBucket = rs.getRow();
        existingId = DBUtil.asNumber(row['id']);
        totalCo2 = DBUtil.asNumber(row['totalCo2']);
        totalPoint = DBUtil.asNumber(row['totalPoint']);
        recordCount = DBUtil.asNumber(row['recordCount']);
      }

      if (existingId > 0) {
        const data: rdb.ValuesBucket = {
          totalCo2: totalCo2 + item.reduceCo2,
          totalPoint: totalPoint + item.getPoint,
          recordCount: recordCount + 1,
          updateTime: now
        };
        const updatePredicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.daily_point_summary);
        updatePredicates.equalTo('id', existingId);
        await store.update(data, updatePredicates);
      } else {
        const data: rdb.ValuesBucket = {
          summaryDate: day,
          totalCo2: item.reduceCo2,
          totalPoint: item.getPoint,
          recordCount: 1,
          createTime: now,
          updateTime: now
        };
        await store.insert(TABLE.daily_point_summary, data);
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'applyDailySummary failed: %{public}s', DBUtil.describe(err));
      throw err as Error;
    } finally {
      DBUtil.closeQuietly(rs);
    }
  }
  /** CarbonRecord -> ValuesBucket，仅用于事务内部插入 */
  private static toCarbonRecordBucket(item: CarbonRecord): rdb.ValuesBucket {
    return {
      recordTime: item.recordTime,
      categoryId: item.categoryId,
      itemId: item.itemId,
      itemName: item.itemName,
      amount: item.amount,
      unit: item.unit,
      reduceCo2: item.reduceCo2,
      getPoint: item.getPoint,
      remark: item.remark
    };
  }
  /**
   * 读取全部减碳记录，按时间倒序
   * @returns 读取失败时返回已成功读出的部分（可能为空数组）
   */
  public static async getAllCarbonRecord(): Promise<CarbonRecord[]> {
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.carbon_record);
    predicates.orderByDesc('recordTime');
    predicates.orderByDesc('id');
    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.carbon_record, predicates);
    return rows.map((row: rdb.ValuesBucket) => DBUtil.toCarbonRecord(row));
  }

  /**
   * 按 id 删除一条减碳记录
   * @returns 是否删除成功
   */
  public static async deleteCarbonRecord(id: number): Promise<boolean> {
    if (!Number.isFinite(id) || id <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'deleteCarbonRecord skipped: invalid id %{public}s', String(id));
      return false;
    }
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.carbon_record);
    predicates.equalTo('id', id);
    const rows: number = await DBUtil.delete(TABLE.carbon_record, predicates);
    return rows > 0;
  }

  /**
   * 读取用户统计数据（累计减排量、累计积分）
   * @returns 读取失败时返回全 0 的默认值，不会返回 undefined
   */
  public static async getUserInfo(): Promise<UserInfo> {
    const fallback: UserInfo = { id: USER_ROW_ID, total_co2: 0, total_point: 0, create_time: 0 };
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.user_info);
    predicates.equalTo('id', USER_ROW_ID);
    const rows: Array<rdb.ValuesBucket> = await DBUtil.query(TABLE.user_info, predicates, 1, 1);
    if (rows.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'getUserInfo: user_info row missing');
      return fallback;
    }
    return DBUtil.toUserInfo(rows[0]);
  }

  /**
   * 覆盖更新用户统计数据
   * @param co2   累计减排量，单位 kgCO2e
   * @param point 累计积分
   * @returns 是否更新成功
   */
  public static async updateUserInfo(co2: number, point: number): Promise<boolean> {
    if (!Number.isFinite(co2) || !Number.isFinite(point) || co2 < 0 || point < 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'updateUserInfo skipped: invalid value %{public}s/%{public}s',
        String(co2), String(point));
      return false;
    }
    const data: rdb.ValuesBucket = { total_co2: co2, total_point: point };
    const predicates: rdb.RdbPredicates = new rdb.RdbPredicates(TABLE.user_info);
    predicates.equalTo('id', USER_ROW_ID);
    const rows: number = await DBUtil.update(TABLE.user_info, data, predicates);
    return rows > 0;
  }

  // ==================================================================
  // 内部工具
  // ==================================================================

  /** 真正执行建库、建表、写入初始行的逻辑 */
  private static async createStore(context: common.Context): Promise<boolean> {
    try {
      const cfg: rdb.StoreConfig = {
        name: DB_NAME,
        securityLevel: rdb.SecurityLevel.S1
      };
      const store: rdb.RdbStore = await rdb.getRdbStore(context, cfg);
      await DBUtil.migrateIfNeeded(store);
      // 兜底：即使版本已是最新，也执行一次 IF NOT EXISTS，防止库文件被部分创建
      await DBUtil.createAllTables(store);
      await DBUtil.ensureUserRow(store);
      rdbStore = store;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'database initialized: %{public}s (schema v%{public}d)',
        DB_NAME, SCHEMA_VERSION);
      return true;
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'initDB failed: %{public}s', DBUtil.describe(err));
      // 允许下次 initDB 重试
      initPromise = undefined;
      return false;
    }
  }

  /**
   * 按版本迁移表结构：
   *   新库 version 为 0，会执行 0 -> 1；
   *   老库按实际版本补齐；版本已经是最新时直接返回。
   * 以后改表结构：SCHEMA_VERSION 加 1，并在下面追加一个 if (current < N) 分支。
   */
  private static async migrateIfNeeded(store: rdb.RdbStore): Promise<void> {
    let current: number = 0;
    try {
      current = store.version;
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read schema version failed: %{public}s', DBUtil.describe(err));
      current = 0;
    }
    if (current >= SCHEMA_VERSION) {
      return;
    }
    // v0 -> v1：首次建表。IF NOT EXISTS 兼容"升级前已经由旧代码建过表"的数据库
    if (current < 1) {
      await DBUtil.createAllTables(store);
    }
    // 以后新增字段时照这个格式补：
    // if (current < 2) {
    //   await store.executeSql("ALTER TABLE carbon_record ADD COLUMN source TEXT DEFAULT ''");
    // }
    // v1 -> v2：任务领奖与徽章解锁需要的字段
    if (current < 2) {
      await DBUtil.addColumnIfMissing(store, TABLE.task_list, 'taskId', 'TEXT');
      await DBUtil.addColumnIfMissing(store, TABLE.task_list, 'rewardPoint', 'INTEGER');
      await DBUtil.addColumnIfMissing(store, TABLE.task_list, 'claimedAt', 'INTEGER');
      await DBUtil.addColumnIfMissing(store, TABLE.badge, 'badgeId', 'TEXT');
      await DBUtil.addColumnIfMissing(store, TABLE.badge, 'unlockedAt', 'INTEGER');
    }    store.version = SCHEMA_VERSION;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'schema migrated: %{public}d -> %{public}d', current, SCHEMA_VERSION);
  }

  /** 表中是否已经存在某一列（用于安全迁移） */
  private static async columnExists(store: rdb.RdbStore, table: string, column: string): Promise<boolean> {
    let rs: rdb.ResultSet | undefined = undefined;
    try {
      rs = await store.querySql('PRAGMA table_info(' + table + ')');
      while (rs.goToNextRow()) {
        const row: rdb.ValuesBucket = rs.getRow();
        if (row['name'] === column) {
          return true;
        }
      }
      return false;
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'columnExists failed: %{public}s', DBUtil.describe(err));
      return false;
    } finally {
      DBUtil.closeQuietly(rs);
    }
  }

  /** 缺列时补列，已存在则跳过 */
  private static async addColumnIfMissing(store: rdb.RdbStore, table: string,
    column: string, sqlType: string): Promise<void> {
    const exists: boolean = await DBUtil.columnExists(store, table, column);
    if (exists) {
      return;
    }
    try {
      await store.executeSql('ALTER TABLE ' + table + ' ADD COLUMN ' + column + ' ' + sqlType);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'added column %{public}s.%{public}s', table, column);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'addColumn failed: %{public}s', DBUtil.describe(err));
      throw err as Error;
    }
  }
  /** 根据 TABLE_DEFS 建表，可重复执行 */
  private static async createAllTables(store: rdb.RdbStore): Promise<void> {
    try {
      for (const def of TABLE_DEFS) {
        await store.executeSql(buildCreateTableSql(def));
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'createAllTables failed: %{public}s', DBUtil.describe(err));
      throw err as Error;
    }
  }  /** 确保 user_info 中存在主键为 1 的统计行 */
  private static async ensureUserRow(store: rdb.RdbStore): Promise<void> {
    let exists: boolean = false;
    let rs: rdb.ResultSet | undefined = undefined;
    try {
      rs = await store.querySql('SELECT id FROM ' + TABLE.user_info + ' WHERE id = ?', [USER_ROW_ID]);
      exists = rs.goToFirstRow();
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'ensureUserRow check failed: %{public}s', DBUtil.describe(err));
    } finally {
      DBUtil.closeQuietly(rs);
    }
    if (exists) {
      return;
    }
    try {
      const bucket: rdb.ValuesBucket = {
        id: USER_ROW_ID,
        total_co2: 0,
        total_point: 0,
        create_time: Date.now()
      };
      await store.insert(TABLE.user_info, bucket);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'user_info initial row created');
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'ensureUserRow insert failed: %{public}s', DBUtil.describe(err));
      throw err as Error;
    }
  }

  /** 分页参数落到 predicates 上（pageIndex 从 1 开始） */
  private static applyPagination(predicates: rdb.RdbPredicates,
    pageIndex?: number, pageSize?: number): void {
    if (pageSize === undefined || !Number.isFinite(pageSize) || pageSize <= 0) {
      return;
    }
    const size: number = Math.floor(pageSize);
    const index: number = pageIndex !== undefined && Number.isFinite(pageIndex) && pageIndex > 0
      ? Math.floor(pageIndex) : 1;
    predicates.limitAs(size);
    predicates.offsetAs((index - 1) * size);
  }

  /** 关闭结果集，关闭失败只记录日志，不向上抛异常 */
  private static closeQuietly(rs: rdb.ResultSet | undefined): void {
    if (rs === undefined) {
      return;
    }
    try {
      rs.close();
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'close result set failed: %{public}s', DBUtil.describe(err));
    }
  }

  /** 表名合法性校验：字母或下划线开头，只允许字母、数字、下划线 */
  private static isValidTableName(tableName: string): boolean {
    if (tableName.length === 0 || tableName.length > 64) {
      return false;
    }
    return /^[A-Za-z_][A-Za-z0-9_]*$/.test(tableName);
  }

  /** 待写入数据是否为空 */
  private static isEmptyData(data: rdb.ValuesBucket): boolean {
    return Object.keys(data).length === 0;
  }

  /** carbon_record 行 -> CarbonRecord 实体 */
  private static toCarbonRecord(row: rdb.ValuesBucket): CarbonRecord {
    return {
      id: DBUtil.asNumber(row['id']),
      recordTime: DBUtil.asText(row['recordTime']),
      categoryId: DBUtil.asText(row['categoryId']),
      itemId: DBUtil.asText(row['itemId']),
      itemName: DBUtil.asText(row['itemName']),
      amount: DBUtil.asNumber(row['amount']),
      unit: DBUtil.asText(row['unit']),
      reduceCo2: DBUtil.asNumber(row['reduceCo2']),
      getPoint: DBUtil.asNumber(row['getPoint']),
      remark: DBUtil.asText(row['remark'])
    };
  }

  /** user_info 行 -> UserInfo 实体 */
  private static toUserInfo(row: rdb.ValuesBucket): UserInfo {
    return {
      id: DBUtil.asNumber(row['id']),
      total_co2: DBUtil.asNumber(row['total_co2']),
      total_point: DBUtil.asNumber(row['total_point']),
      create_time: DBUtil.asNumber(row['create_time'])
    };
  }

  /** 列值转 number，类型不符时返回 0 */
  private static asNumber(value: rdb.ValueType): number {
    return typeof value === 'number' ? value : 0;
  }

  /** 列值转 string，类型不符时返回空字符串 */
  private static asText(value: rdb.ValueType): string {
    return typeof value === 'string' ? value : '';
  }

  /** 把任意异常转成可读文本，便于日志排查 */
  private static describe(err: Object): string {
    if (err instanceof Error) {
      const businessError: BusinessError = err as BusinessError;
      const code: string = typeof businessError.code === 'number' ? String(businessError.code) : '-';
      return code + ':' + businessError.message;
    }
    return String(err);
  }
}
