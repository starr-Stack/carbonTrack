/*
 * 文件名：AppState.ets
 * 版本：v2.0（AppStorage + PersistentStorage 持久化全局状态，替代单例方案）
 * 功能：基于 AppStorage + PersistentStorage 的全局状态（选中省份、今日积分）。
 *       页面通过 @StorageLink 与 AppStorage 双向绑定，状态变化自动刷新 UI 并落盘。
 *
 * 说明：
 *   1. AppStorage 只存在于内存，进程被杀就没了；要“关闭 APP 后数据不丢失”，
 *      必须用 PersistentStorage.persistProp 把对应的 key 注册为持久化属性；
 *   2. 调用顺序必须是“先 persistProp，再访问 AppStorage”，否则会用内存默认值
 *      覆盖上次退出时持久化的值；
 *   3. API 12 限制：PersistentStorage 依赖 UI 实例，必须在 loadContent 回调
 *      （UI 实例创建成功）之后调用，早于该时机（如 EntryAbility.onCreate）会导致
 *      持久化失效，因此 initGlobalState() 由 EntryAbility 在 loadContent 回调中调用；
 *   4. 跨天重置需要一个辅助 key pointDate（记录今日积分归属的日期）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'AppState';

/**
 * 全局状态管理类（纯静态工具类，状态本身存放在 AppStorage 中，不再持有单例）。
 * 页面绑定写法（装饰器参数必须是字符串字面量，与下面的 KEY_* 常量保持一致）：
 *   @StorageLink('todayEarnPoint') todayPoint: number = 0;
 */
export class AppState {
  /** 选中省份 id 的 key（持久化），如 guangdong */
  public static readonly KEY_SELECT_PROVINCE_ID: string = 'selectProvinceId';
  /** 今日已得积分的 key（持久化） */
  public static readonly KEY_TODAY_EARN_POINT: string = 'todayEarnPoint';
  /** 今日积分归属日期的 key（持久化，yyyy-MM-dd），仅用于跨天判断，不直接展示 */
  public static readonly KEY_POINT_DATE: string = 'pointDate';

  /** 是否已完成持久化初始化，避免重复注册 */
  private static initialized: boolean = false;

  /**
   * 初始化全局状态：注册持久化 -> 创建 AppStorage 属性 -> 处理跨天重置。
   * 必须在 UI 实例创建成功后调用（EntryAbility 的 loadContent 回调）。
   * 重复调用是安全的（内部做了幂等判断）。
   */
  public static initGlobalState(): void {
    if (AppState.initialized) {
      return;
    }
    try {
      // 1. 先注册持久化：按“磁盘值 > AppStorage 已有值 > 默认值”的顺序初始化
      PersistentStorage.persistProp<string>(AppState.KEY_SELECT_PROVINCE_ID, '');
      PersistentStorage.persistProp<number>(AppState.KEY_TODAY_EARN_POINT, 0);
      PersistentStorage.persistProp<string>(AppState.KEY_POINT_DATE, '');
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'persistProp failed: %{public}s', AppState.describe(err));
    }

    // 2. 再 setOrCreate 兜底，保证页面无论何时绑定 @StorageLink 都能取到值。
    //    注意：这里读取的是 persistProp 刚从磁盘恢复的值，不会覆盖持久化数据。
    AppStorage.setOrCreate<string>(AppState.KEY_SELECT_PROVINCE_ID,
      AppStorage.get<string>(AppState.KEY_SELECT_PROVINCE_ID) ?? '');
    AppStorage.setOrCreate<number>(AppState.KEY_TODAY_EARN_POINT,
      AppStorage.get<number>(AppState.KEY_TODAY_EARN_POINT) ?? 0);
    AppStorage.setOrCreate<string>(AppState.KEY_POINT_DATE,
      AppStorage.get<string>(AppState.KEY_POINT_DATE) ?? '');

    AppState.initialized = true;

    // 3. 跨天重置
    AppState.loadTodayPoint();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'global state ready, province=%{public}s, todayPoint=%{public}d',
      AppState.getSelectProvinceId(), AppState.getTodayEarnPoint());
  }

  /**
   * 加载/校准今日积分：同一天保留持久化值，跨天自动清零。
   * 页面可随时调用；addPoint 内部也会先调用一次，保证跨天后不会把昨天的积分继续累加。
   */
  public static loadTodayPoint(): void {
    const today: string = AppState.todayKey();
    const savedDate: string = AppStorage.get<string>(AppState.KEY_POINT_DATE) ?? '';
    if (savedDate === today) {
      return;
    }
    AppStorage.setOrCreate<number>(AppState.KEY_TODAY_EARN_POINT, 0);
    AppStorage.setOrCreate<string>(AppState.KEY_POINT_DATE, today);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cross day detected: %{public}s -> %{public}s, today point reset to 0',
      savedDate, today);
  }

  /**
   * 加分：先做跨天判断，再累加到今日积分。
   * @param point 本次新增积分，非法值（非数字、<=0）会被忽略
   */
  public static addPoint(point: number): void {
    if (!Number.isFinite(point) || point <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'addPoint ignored, invalid point=%{public}s', String(point));
      return;
    }
    // 跨天保护：如果已经是新的一天，先把积分清零再加
    AppState.loadTodayPoint();
    const next: number = AppState.getTodayEarnPoint() + Math.floor(point);
    AppState.setTodayEarnPoint(next);
  }

  /** 持久化全局状态是否已初始化完成（页面/Ability 在写入前可用于判断） */
  public static isInitialized(): boolean {
    return AppState.initialized;
  }

  /** 读取今日积分 */
  public static getTodayEarnPoint(): number {
    return AppStorage.get<number>(AppState.KEY_TODAY_EARN_POINT) ?? 0;
  }

  /**
   * 设置今日积分（同时把 pointDate 同步为今天，避免跨天后被旧日期误重置）。
   * 页面一般不需要直接调用，加分请用 addPoint()。
   */
  public static setTodayEarnPoint(point: number): void {
    const safe: number = Number.isFinite(point) && point > 0 ? Math.floor(point) : 0;
    AppStorage.setOrCreate<number>(AppState.KEY_TODAY_EARN_POINT, safe);
    AppStorage.setOrCreate<string>(AppState.KEY_POINT_DATE, AppState.todayKey());
  }

  /** 今日积分清零（如手动重置、退出登录） */
  public static resetTodayPoint(): void {
    AppState.setTodayEarnPoint(0);
  }

  /** 读取选中省份 id，未选择时返回空字符串 */
  public static getSelectProvinceId(): string {
    return AppStorage.get<string>(AppState.KEY_SELECT_PROVINCE_ID) ?? '';
  }

  /** 设置选中省份 id，会同步写回 AppStorage，并由 PersistentStorage 落盘 */
  public static setSelectProvinceId(provinceId: string): void {
    AppStorage.setOrCreate<string>(AppState.KEY_SELECT_PROVINCE_ID, provinceId);
  }

  /** 今天的日期 key，格式 yyyy-MM-dd */
  public static todayKey(): string {
    const now: Date = new Date();
    const month: string = (now.getMonth() + 1).toString().padStart(2, '0');
    const day: string = now.getDate().toString().padStart(2, '0');
    return `${now.getFullYear()}-${month}-${day}`;
  }

  /** 把任意异常转成可读文本，便于日志排查 */
  private static describe(err: Object): string {
    return err instanceof Error ? err.message : String(err);
  }
}

/*
 * ==================================================================
 * 页面使用示例（@StorageLink 双向绑定）
 * ------------------------------------------------------------------
 * import { AppState } from '../model/AppState';
 *
 * @Entry
 * @Component
 * struct Index {
 *   // @StorageLink 与 AppStorage 双向同步：AppStorage 变 -> UI 刷新；
 *   // 组件内赋值 -> 写回 AppStorage -> PersistentStorage 自动落盘
 *   // 注意：装饰器参数必须是字符串字面量，与 AppState.KEY_* 常量保持一致
 *   @StorageLink('selectProvinceId') provinceId: string = '';
 *   @StorageLink('todayEarnPoint') todayPoint: number = 0;
 *
 *   build() {
 *     Column({ space: 12 }) {
 *       Text(`当前省份：${this.provinceId.length === 0 ? '未选择' : this.provinceId}`)
 *       Text(`今日积分：${this.todayPoint}`)
 *
 *       Button('选择广东')
 *         .onClick(() => {
 *           // 推荐：通过 AppState 方法写入，便于统一做校验/埋点
 *           AppState.setSelectProvinceId('guangdong');
 *         })
 *
 *       Button('完成任务 +10 积分')
 *         .onClick(() => {
 *           AppState.addPoint(10);
 *           // addPoint 写入 AppStorage 后，上面的 @StorageLink 会自动刷新
 *         })
 *     }
 *     .width('100%')
 *     .height('100%')
 *     .justifyContent(FlexAlign.Center)
 *   }
 * }
 *
 * 只读展示、不需要回写的页面用 @StorageProp：
 *   @StorageProp('todayEarnPoint') todayPoint: number = 0;
 * ==================================================================
 */
