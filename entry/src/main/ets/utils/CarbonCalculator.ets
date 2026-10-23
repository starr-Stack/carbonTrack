/*
 * 文件名：CarbonCalculator.ets
 * 功能：读取 rawfile 下的碳排放因子 JSON，计算单次低碳行为的减排量与积分
 * 模型：Stage 模型，API 12
 * 说明：纯本地计算，不联网；rawfile 随应用包体分发，读取不需要任何权限
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'CarbonCalculator';
/** rawfile 中因子文件名，按顺序探测，兼容 carbon_factor.json / carbon_factors.json */
const RAW_FILE_CANDIDATES: string[] = ['carbon_factor.json', 'carbon_factors.json'];
/** 减排量保留的小数位数，kg 精度到 0.1 g */
const CO2_DECIMAL: number = 4;
/**
 * 计算结果
 * reduceCo2：本次减排量，单位 kgCO2e
 * getPoint：本次可获得积分，整数
 */
export interface CalcResult {
  reduceCo2: number;
  getPoint: number;
}
/** 出行基准（燃油私家车） */
export interface CategoryBaseline {
  id: string;
  name: string;
  factor: number;
  unit: string;
}
/** 单个低碳行为因子 */
export interface FactorItem {
  id: string;
  name: string;
  icon?: string;
  unit: string;
  /** 每单位行为的净减排因子，kgCO2e/unit */
  factor: number;
  /** 替代前基准因子（出行场景） */
  baselineFactor?: number;
  /** 替代方式自身因子（出行场景） */
  modeFactor?: number;
  type?: string;
  quality?: string;
  source?: string;
  /** 电力类因子可随省级电网因子按比例修正 */
  provinceOverridable?: boolean;
  step?: number;
  /** 单条记录允许的最大数值，防止误输入 */
  maxPerRecord?: number;
  tips?: string;
}
/** 行为分类 */
export interface Category {
  id: string;
  name: string;
  icon?: string;
  color?: string;
  description?: string;
  baseline?: CategoryBaseline;
  items: FactorItem[];
}
/** 全国电力平均因子 */
export interface DefaultElectricityFactor {
  id: string;
  name: string;
  factor: number;
  unit: string;
  year: number;
  source?: string;
  quality?: string;
}
/** 区域 / 省级电力因子 */
export interface RegionFactor {
  id: string;
  name: string;
  factor: number;
}
/** 电力因子配置 */
export interface ElectricityConfig {
  default: DefaultElectricityFactor;
  byRegion: RegionFactor[];
  byProvince: RegionFactor[];
}
/** 各分类积分权重 */
export interface CategoryWeight {
  travel?: number;
  electricity?: number;
  water?: number;
  recycle?: number;
  food?: number;
}
/** 积分有效期 */
export interface PointExpire {
  enabled: boolean;
  days: number;
  note?: string;
}
/** 积分示例 */
export interface PointExample {
  itemId: string;
  amount: number;
  unit: string;
  kgCO2e: number;
  points: number;
}
/** 积分换算规则 */
export interface PointsRule {
  enabled: boolean;
  /** 每 1 kgCO2e 折算的基础积分 */
  pointsPerKgCO2e: number;
  formula?: string;
  /** 取整方式：floor / round */
  rounding?: string;
  minPerRecord: number;
  maxPerRecord: number;
  categoryWeights: CategoryWeight;
  dailyCap: number;
  monthlyCap: number;
  perItemDailyLimit: number;
  expire?: PointExpire;
  examples?: PointExample[];
}
/** 因子文件根结构（只声明计算所需字段，其余字段解析时自动忽略） */
export interface CarbonFactorData {
  schemaVersion: string;
  fileVersion?: string;
  name: string;
  baseUnit: string;
  electricity: ElectricityConfig;
  categories: Category[];
  points: PointsRule;
}
/**
 * 碳核算工具类（单例）
 * 1. init() 只解析一次 rawfile，常驻内存；
 * 2. calcReduceCO2() 纯函数式计算，无 IO、无网络，可多次调用；
 * 3. 所有异常均记录日志并返回 0 值，不向业务层抛异常。
 */
export class CarbonCalculator {
  private static instance: CarbonCalculator | undefined = undefined;
  /** 解析后的因子数据 */
  private data: CarbonFactorData | undefined = undefined;
  /** 当前使用的省级电网因子，未设置时使用全国平均因子 */
  private provinceFactor: number | undefined = undefined;
  /** 当前省级行政区 id，仅用于状态展示 */
  private provinceId: string = '';
  /** 防止并发初始化重复解析 */
  private loadingPromise: Promise<void> | undefined = undefined;
  /** 实际命中的文件名 */
  private loadedFileName: string = '';
  private constructor() {
  }
  /** 获取单例 */
  public static getInstance(): CarbonCalculator {
    if (CarbonCalculator.instance === undefined) {
      CarbonCalculator.instance = new CarbonCalculator();
    }
    return CarbonCalculator.instance;
  }
  /**
   * 初始化：读取并解析 rawfile 因子文件
   * @param context 任意可用的 Context，推荐 EntryAbility 的 this.context 或页面的 getContext(this)
   */
  public async init(context: common.Context): Promise<void> {
    if (this.data !== undefined) {
      return;
    }
    // 已有初始化在进行中则复用同一个 Promise，避免重复读取 rawfile
    const pending: Promise<void> = this.loadingPromise ?? this.startLoad(context);
    try {
      await pending;
    } finally {
      if (this.loadingPromise === pending) {
        this.loadingPromise = undefined;
      }
    }
  }
  /** 启动一次 rawfile 解析，并记录 Promise 供并发调用复用 */
  private startLoad(context: common.Context): Promise<void> {
    const pending: Promise<void> = this.load(context);
    this.loadingPromise = pending;
    return pending;
  }
  /** 因子是否已就绪 */
  public isReady(): boolean {
    return this.data !== undefined;
  }
  /** 实际加载的文件名，便于排查问题 */
  public getLoadedFileName(): string {
    return this.loadedFileName;
  }
  /**
   * 设置省级电网因子（节电类因子会按比例修正）
   * @param provinceId 与 JSON 中 byProvince[].id 一致，如 "guangdong"
   * @returns 是否设置成功
   */
  public setProvince(provinceId: string): boolean {
    if (this.data === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setProvince before init');
      return false;
    }
    const target: RegionFactor | undefined =
      this.data.electricity.byProvince.find((item: RegionFactor) => item.id === provinceId);
    if (target === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown province: %{public}s', provinceId);
      return false;
    }
    this.provinceId = target.id;
    this.provinceFactor = target.factor;
    return true;
  }
  /** 直接指定电网因子（如使用了更新的官方数据），单位 kgCO2/kWh */
  public setElectricityFactor(factor: number): void {
    if (!Number.isFinite(factor) || factor <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'invalid electricity factor: %{public}s', String(factor));
      return;
    }
    this.provinceFactor = factor;
    this.provinceId = '';
  }
  /** 清除省级因子，回到全国平均值 */
  public resetElectricityFactor(): void {
    this.provinceFactor = undefined;
    this.provinceId = '';
  }
  /** 获取全部省级因子，供设置页下拉框使用（返回副本，避免外部改动内部数据） */
  public getProvinces(): RegionFactor[] {
    return this.data === undefined ? [] : this.data.electricity.byProvince.slice();
  }
  /** 当前生效的省级行政区 id，未设置时为空字符串 */
  public getProvinceId(): string {
    return this.provinceId;
  }
  /** 全国平均电网因子，单位 kgCO2/kWh */
  public getDefaultElectricityFactor(): number {
    return this.data === undefined ? 0 : this.data.electricity.default.factor;
  }
  /** 获取全部行为分类，供首页/记录页渲染 */
  public getCategories(): Category[] {
    return this.data === undefined ? [] : this.data.categories.slice();
  }
  /**
   * 碳核算主函数
   * @param type    行为类型（分类 id），如 "travel"、"electricity"、"water"、"recycle"、"food"
   * @param subType 行为子类型，可传 "walk" 或完整 id "travel.walk"
   * @param value   行为数值，单位与因子 unit 一致（km、kwh、m3、kg、meal 等）
   * @returns 本次减排量（kgCO2e，4 位小数）与获得积分（整数）；非法入参返回 0
   */
  public calcReduceCO2(type: string, subType: string, value: number): CalcResult {
    const empty: CalcResult = { reduceCo2: 0, getPoint: 0 };
    if (this.data === undefined) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'calc before init, call init() first');
      return empty;
    }
    if (!Number.isFinite(value) || value <= 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'invalid value: %{public}s', String(value));
      return empty;
    }
    const category: Category | undefined =
      this.data.categories.find((item: Category) => item.id === type);
    if (category === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown type: %{public}s', type);
      return empty;
    }
    const fullId: string = subType.startsWith(type + '.') ? subType : type + '.' + subType;
    const factorItem: FactorItem | undefined = category.items.find((item: FactorItem) =>
    item.id === fullId || item.id === subType || item.name === subType);
    if (factorItem === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown subType: %{public}s/%{public}s', type, subType);
      return empty;
    }
    // 单条记录上限保护，避免误输入导致数据异常
    const max: number = factorItem.maxPerRecord === undefined ? value : factorItem.maxPerRecord;
    const amount: number = Math.min(value, max);
    // 有效因子：默认取 JSON 因子；节电类按当前省级电网因子等比例修正
    let factor: number = factorItem.factor;
    const nationalFactor: number = this.data.electricity.default.factor;
    if (factorItem.provinceOverridable === true && this.provinceFactor !== undefined && nationalFactor > 0) {
      factor = factorItem.factor * this.provinceFactor / nationalFactor;
    }
    const reduceCo2: number = this.round(amount * factor, CO2_DECIMAL);
    const getPoint: number = this.calcPoint(this.data.points, type, reduceCo2);
    hilog.debug(LOG_DOMAIN, LOG_TAG,
      'calc %{public}s amount=%{public}s factor=%{public}s co2=%{public}s point=%{public}s',
      factorItem.id, String(amount), String(factor), String(reduceCo2), String(getPoint));
    return { reduceCo2: reduceCo2, getPoint: getPoint };
  }
  /**
   * 查询某个行为的元数据（单位、步长、提示、单条上限），便于 UI 渲染
   * @returns 未找到时返回 undefined
   */
  public getItemInfo(type: string, subType: string): FactorItem | undefined {
    if (this.data === undefined) {
      return undefined;
    }
    const category: Category | undefined =
      this.data.categories.find((item: Category) => item.id === type);
    if (category === undefined) {
      return undefined;
    }
    const fullId: string = subType.startsWith(type + '.') ? subType : type + '.' + subType;
    return category.items.find((item: FactorItem) =>
    item.id === fullId || item.id === subType || item.name === subType);
  }
  /** 获取积分规则（只读用途，如展示每日上限） */
  public getPointsRule(): PointsRule | undefined {
    return this.data?.points;
  }
  /**
   * 应用每日积分上限（单次核算不含累计逻辑，持久化层累加时调用）
   * @param point       本次应得积分
   * @param earnedToday 今日已获得积分
   * @returns 实际上限内的积分
   */
  public applyDailyCap(point: number, earnedToday: number): number {
    const rule: PointsRule | undefined = this.data?.points;
    if (rule === undefined) {
      return point;
    }
    const remain: number = rule.dailyCap - earnedToday;
    if (remain <= 0) {
      return 0;
    }
    return Math.min(point, remain);
  }
  /**
   * 读取并解析 rawfile，按候选文件名依次尝试
   */
  private async load(context: common.Context): Promise<void> {
    let lastMessage: string = '';
    for (const fileName of RAW_FILE_CANDIDATES) {
      try {
        // rawfile 内容随 HAP 打包，读取无需权限
        const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(fileName);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        const jsonText: string = decoder.decodeToString(bytes);
        const parsed: CarbonFactorData = JSON.parse(jsonText) as CarbonFactorData;
        if (parsed.categories === undefined || parsed.categories.length === 0 ||
          parsed.electricity === undefined || parsed.points === undefined) {
          throw new Error('factor file missing required fields');
        }
        this.data = parsed;
        this.loadedFileName = fileName;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'loaded %{public}s, categories=%{public}d',
          fileName, parsed.categories.length);
        return;
      } catch (err) {
        lastMessage = err instanceof Error ? err.message : String(err);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'load %{public}s failed: %{public}s', fileName, lastMessage);
      }
    }
    hilog.error(LOG_DOMAIN, LOG_TAG, 'no factor file available: %{public}s', lastMessage);
    throw new Error('load carbon factor file failed: ' + lastMessage);
  }
  /**
   * 积分换算：points = max(min, floor(kgCO2e × 每公斤积分 × 分类权重))
   * 结果再受单条上限约束
   */
  private calcPoint(rule: PointsRule, categoryId: string, reduceCo2: number): number {
    if (rule.enabled !== true || reduceCo2 <= 0) {
      return 0;
    }
    const weight: number = this.getWeight(rule.categoryWeights, categoryId);
    const raw: number = reduceCo2 * rule.pointsPerKgCO2e * weight;
    let point: number = rule.rounding === 'round' ? Math.round(raw) : Math.floor(raw);
    if (point < rule.minPerRecord) {
      point = rule.minPerRecord;
    }
    if (point > rule.maxPerRecord) {
      point = rule.maxPerRecord;
    }
    return point;
  }
  /** 分类权重，缺失时默认 1.0（避免 ArkTS 动态下标访问） */
  private getWeight(weights: CategoryWeight, categoryId: string): number {
    switch (categoryId) {
      case 'travel':
        return weights.travel ?? 1;
      case 'electricity':
        return weights.electricity ?? 1;
      case 'water':
        return weights.water ?? 1;
      case 'recycle':
        return weights.recycle ?? 1;
      case 'food':
        return weights.food ?? 1;
      default:
        return 1;
    }
  }
  /** 四舍五入到指定小数位，规避浮点尾差 */
  private round(value: number, decimal: number): number {
    const base: number = Math.pow(10, decimal);
    return Math.round(value * base) / base;
  }
}
export default CarbonCalculator;
/*
 * ============================ 使用示例 ============================
 *
 * 1. EntryAbility.onWindowStageCreate 中初始化（应用启动即加载）：
 *
 *    import CarbonCalculator from '../utils/CarbonCalculator';
 *
 *    private async initApp(): Promise<void> {
 *      await CarbonCalculator.getInstance().init(this.context);
 *    }
 *
 * 2. 页面中直接使用：
 *
 *    const result: CalcResult =
 *      CarbonCalculator.getInstance().calcReduceCO2('travel', 'walk', 3);
 *    // result.reduceCo2 = 0.576 (kgCO2e)
 *    // result.getPoint  = 57
 *
 *    const power: CalcResult =
 *      CarbonCalculator.getInstance().calcReduceCO2('electricity', 'save_kwh', 2);
 *    // power.reduceCo2 = 1.0732, power.getPoint = 107
 *
 * 3. 按省份修正节电因子：
 *
 *    CarbonCalculator.getInstance().setProvince('guangdong');
 *    // 之后 electricity.* 按省级因子 / 全国平均因子 的比例修正
 *
 * 4. 每日上限（业务层累计后调用）：
 *
 *    const calc: CarbonCalculator = CarbonCalculator.getInstance();
 *    const realPoint: number = calc.applyDailyCap(result.getPoint, AppState.getTodayEarnPoint());
 *
 * ============================ 权限说明 ============================
 * rawfile 属于应用安装包内资源，读取不涉及用户隐私与系统能力，
 * module.json5 无需添加任何 requestPermissions。
 * 仅当后续增加联网上传、定位记录等功能时，才需要相应声明：
 *   "requestPermissions": [
 *     { "name": "ohos.permission.INTERNET" }
 *   ]
 */