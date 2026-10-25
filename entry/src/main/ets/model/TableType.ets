/*
 * 文件名：TableType.ets
 * 功能：项目内所有数据库实体的唯一定义文件，同时也是建表结构的唯一来源。
 *       表名常量、列定义、实体 interface 全部从这里 export，DBUtil 与页面统一 import，
 *       禁止在其他文件中重复定义实体，避免字段与建表 SQL 不一致。
 *
 * 字段与下方 TABLE_DEFS 的列定义严格一一对应：
 *   SQL 类型 INTEGER / REAL          -> number
 *   SQL 类型 TEXT                    -> string
 *   INTEGER PRIMARY KEY AUTOINCREMENT -> id?: number（新增时由数据库生成）
 */

/**
 * 数据表名常量类型。
 * 每新增一张表：先在此 interface 加字段，再在下方 TABLE 中赋同名值，
 * 再在 TABLE_DEFS 中补列定义，最后在本文件下方补 interface。
 */
export interface TableNameType {
  /** 减碳记录表：每次低碳行为的明细 */
  carbon_record: string;
  /** 每日积分汇总表：按天聚合的减排量、积分、记录条数 */
  daily_point_summary: string;
  /** 用户统计表：全量累计减排量与积分（固定单行，id = 1） */
  user_info: string;
  /** 任务表：低碳任务及完成状态 */
  task_list: string;
  /** 徽章表：用户已获得的徽章 */
  badge: string;
  /** 科普文章表 */
  article: string;
}

/** 表名常量，业务代码统一引用，避免手写字符串出错 */
export const TABLE: TableNameType = {
  carbon_record: 'carbon_record',
  daily_point_summary: 'daily_point_summary',
  user_info: 'user_info',
  task_list: 'task_list',
  badge: 'badge',
  article: 'article'
};

/* ==================================================================
 * 建表结构（CREATE TABLE 的唯一来源）
 * ------------------------------------------------------------------
 * DBUtil 不再手写建表 SQL，而是根据下面的 TABLE_DEFS 生成。
 * 改字段时只需要改这一处；改完必须把 SCHEMA_VERSION 加 1，
 * 并在 DBUtil.migrateIfNeeded() 里补一个对应版本的迁移分支。
 * ================================================================== */

/** 列定义：name 列名，sqlType SQL 类型，constraint 约束（没有就填空字符串） */
export interface ColumnDef {
  name: string;
  sqlType: string;
  constraint: string;
}

/** 一张表的完整定义 */
export interface TableDef {
  name: string;
  columns: ColumnDef[];
}

/** 当前数据库结构版本。每次改表结构必须 +1 */
export const SCHEMA_VERSION: number = 2;

/** 所有表的列定义，数组顺序就是建表顺序 */
export const TABLE_DEFS: TableDef[] = [
  {
    name: TABLE.carbon_record,
    columns: [
      { name: 'id', sqlType: 'INTEGER', constraint: 'PRIMARY KEY AUTOINCREMENT' },
      { name: 'recordTime', sqlType: 'TEXT', constraint: '' },
      { name: 'categoryId', sqlType: 'TEXT', constraint: '' },
      { name: 'itemId', sqlType: 'TEXT', constraint: '' },
      { name: 'itemName', sqlType: 'TEXT', constraint: '' },
      { name: 'amount', sqlType: 'REAL', constraint: '' },
      { name: 'unit', sqlType: 'TEXT', constraint: '' },
      { name: 'reduceCo2', sqlType: 'REAL', constraint: '' },
      { name: 'getPoint', sqlType: 'INTEGER', constraint: '' },
      { name: 'remark', sqlType: 'TEXT', constraint: '' }
    ]
  },
  {
    name: TABLE.daily_point_summary,
    columns: [
      { name: 'id', sqlType: 'INTEGER', constraint: 'PRIMARY KEY AUTOINCREMENT' },
      { name: 'summaryDate', sqlType: 'TEXT', constraint: 'NOT NULL UNIQUE' },
      { name: 'totalCo2', sqlType: 'REAL', constraint: 'NOT NULL DEFAULT 0' },
      { name: 'totalPoint', sqlType: 'INTEGER', constraint: 'NOT NULL DEFAULT 0' },
      { name: 'recordCount', sqlType: 'INTEGER', constraint: 'NOT NULL DEFAULT 0' },
      { name: 'createTime', sqlType: 'INTEGER', constraint: 'NOT NULL DEFAULT 0' },
      { name: 'updateTime', sqlType: 'INTEGER', constraint: 'NOT NULL DEFAULT 0' }
    ]
  },
  {
    name: TABLE.user_info,
    columns: [
      { name: 'id', sqlType: 'INTEGER', constraint: 'PRIMARY KEY AUTOINCREMENT' },
      { name: 'total_co2', sqlType: 'REAL', constraint: 'DEFAULT 0' },
      { name: 'total_point', sqlType: 'INTEGER', constraint: 'DEFAULT 0' },
      { name: 'create_time', sqlType: 'INTEGER', constraint: '' }
    ]
  },
  {
    name: TABLE.task_list,
    columns: [
      { name: 'id', sqlType: 'INTEGER', constraint: 'PRIMARY KEY AUTOINCREMENT' },
      { name: 'taskName', sqlType: 'TEXT', constraint: '' },
      { name: 'finish', sqlType: 'INTEGER', constraint: '' },
      { name: 'taskId', sqlType: 'TEXT', constraint: '' },
      { name: 'rewardPoint', sqlType: 'INTEGER', constraint: 'DEFAULT 0' },
      { name: 'claimedAt', sqlType: 'INTEGER', constraint: 'DEFAULT 0' }
    ]
  },
  {
    name: TABLE.badge,
    columns: [
      { name: 'id', sqlType: 'INTEGER', constraint: 'PRIMARY KEY AUTOINCREMENT' },
      { name: 'badgeName', sqlType: 'TEXT', constraint: '' },
      { name: 'badgeId', sqlType: 'TEXT', constraint: '' },
      { name: 'unlockedAt', sqlType: 'INTEGER', constraint: 'DEFAULT 0' }
    ]
  },
  {
    name: TABLE.article,
    columns: [
      { name: 'id', sqlType: 'INTEGER', constraint: 'PRIMARY KEY AUTOINCREMENT' },
      { name: 'title', sqlType: 'TEXT', constraint: '' },
      { name: 'content', sqlType: 'TEXT', constraint: '' }
    ]
  }
];

/** 根据表定义生成 CREATE TABLE IF NOT EXISTS 语句 */
export function buildCreateTableSql(def: TableDef): string {
  const lines: string[] = [];
  for (const column of def.columns) {
    const suffix: string = column.constraint.length > 0 ? ' ' + column.constraint : '';
    lines.push('  ' + column.name + ' ' + column.sqlType + suffix);
  }
  return 'CREATE TABLE IF NOT EXISTS ' + def.name + '(\n' + lines.join(',\n') + '\n)';
}

/* ==================================================================
 * 核心表实体
 * ================================================================== */

/**
 * 减碳记录实体，对应表 carbon_record。
 * 列定义见上方 TABLE_DEFS 中的 carbon_record。
 */
export interface CarbonRecord {
  /** 主键，自增；新增记录时不需要传，查询时由数据库返回 */
  id?: number;
  /** 记录时间，格式 yyyy-MM-dd HH:mm:ss */
  recordTime: string;
  /** 行为分类 id，对应因子库 categories[].id，如 travel、electricity、water、recycle、food */
  categoryId: string;
  /** 具体低碳行为 id，对应因子库 categories[].items[].id，如 travel.walk */
  itemId: string;
  /** 行为名称，冗余存储，便于历史记录直接展示 */
  itemName: string;
  /** 行为数量，单位与 unit 一致，如 3（公里）、2（度） */
  amount: number;
  /** 行为数量单位，如 km、kwh、m3、kg、meal */
  unit: string;
  /** 本次减排量，单位 kgCO2e，保留 4 位小数 */
  reduceCo2: number;
  /** 本次获得的积分，整数 */
  getPoint: number;
  /** 备注，没有备注时为空字符串 */
  remark: string;
}

/**
 * 每日积分汇总实体，对应表 daily_point_summary。
 * 列定义见上方 TABLE_DEFS 中的 daily_point_summary。
 */
export interface DailyPointSummary {
  /** 主键，自增；新增时不需要传 */
  id?: number;
  /** 汇总日期，格式 yyyy-MM-dd；同一日期只允许一条记录（UNIQUE 约束） */
  summaryDate: string;
  /** 当日累计减排量，单位 kgCO2e */
  totalCo2: number;
  /** 当日累计获得的积分 */
  totalPoint: number;
  /** 当日产生的减碳记录条数 */
  recordCount: number;
  /** 该汇总记录的创建时间，毫秒时间戳 */
  createTime: number;
  /** 该汇总记录的最后更新时间，毫秒时间戳 */
  updateTime: number;
}

/* ==================================================================
 * 已有辅助表实体（DBUtil 已在使用，字段与各自建表 SQL 对齐）
 * ================================================================== */

/**
 * 用户统计实体，对应表 user_info。
 * 该表只保留一行（id = 1），记录全量累计数据。
 */
export interface UserInfo {
  /** 主键，固定为 1 */
  id?: number;
  /** 累计减排量，单位 kgCO2e */
  total_co2: number;
  /** 累计获得积分 */
  total_point: number;
  /** 统计记录创建时间，毫秒时间戳 */
  create_time: number;
}

/**
 * 低碳任务实体，对应表 task_list。
 */
export interface TaskItem {
  /** 主键，自增；新增时不需要传 */
  id?: number;
  /** 任务名称 */
  taskName: string;
  /** 完成状态：0 表示未完成，1 表示已完成 */
  finish: number;
}

/**
 * 徽章实体，对应表 badge。
 */
export interface BadgeItem {
  /** 主键，自增；新增时不需要传 */
  id?: number;
  /** 徽章名称 */
  badgeName: string;
}

/**
 * 科普文章实体，对应表 article。
 */
export interface ArticleItem {
  /** 主键，自增；新增时不需要传 */
  id?: number;
  /** 文章标题 */
  title: string;
  /** 文章正文 */
  content: string;
}

/* ==================================================================
 * 预留区：后续新增表的实体统一写在这里
 * ------------------------------------------------------------------
 * 新增一张表的固定步骤：
 *   1. 在 TableNameType / TABLE 中加表名；
 *   2. 在 TABLE_DEFS 中加列定义；
 *   3. 把 SCHEMA_VERSION 加 1，并在 DBUtil.migrateIfNeeded() 补迁移分支；
 *   4. 在本文件下方按字段一一对应补 interface；
 *   5. 其他文件（DBUtil、页面、ViewModel）一律 import 使用，
 *      禁止在页面或 DBUtil 里重复定义实体。
 *
 * 待新增表示例（补完列定义后取消注释即可）：
 *
 * // 用户表（user_info）扩展，或拆分出的用户资料表（user_profile）
 * // export interface UserProfile {
 * //   id?: number;                // 主键，自增
 * //   nickname: string;           // 昵称
 * //   avatar: string;             // 头像地址
 * //   provinceId: string;         // 常住省份 id，如 guangdong
 * //   createTime: number;         // 创建时间，毫秒时间戳
 * // }
 *
 * // 行为分类表（category）：分类元数据
 * // export interface CarbonCategory {
 * //   id?: number;                // 主键，自增
 * //   categoryId: string;         // 分类 id，如 travel
 * //   name: string;               // 分类名称，如 出行
 * //   icon: string;               // 图标资源名
 * //   sort: number;               // 排序值，越小越靠前
 * // }
 * ================================================================== */
