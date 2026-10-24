/*
 * 文件名：BadgeUnlockUtil.ets
 * 存放路径：entry/src/main/ets/utils/BadgeUnlockUtil.ets
 * 功能：徽章解锁判定工具（纯函数，无 UI、无 IO、无数据库）。
 *
 * 判定规则（与产品口径一致）：
 *   1. 一枚徽章绑定 1 个或多个任务 id（bindTaskIdList）；
 *   2. 只有这些任务【全部领奖成功】，该徽章才解锁；
 *   3. 任一任务未领奖 / 状态列表里查不到该任务，都视为未解锁；
 *   4. bindTaskIdList 缺失、为空或不是数组时一律判为未解锁，
 *      防止配置漏写导致所有徽章被误点亮。
 *
 * 设计说明：
 *   - 纯函数：不修改入参，不依赖页面状态，方便单测与复用（任务页、个人页都能调）；
 *   - 输入是「任务领奖状态列表」，由调用方从 A 的任务领奖记录接口取来后组装，
 *     本工具不关心数据从哪来；
 *   - 本文件只做判定，解锁结果的持久化由页面调用 A 的接口完成（见 BadgeList.ets
 *     的 persistNewlyUnlocked 占位注释），这里不写任何 SQL。
 *
 * 使用示例：
 *   const badge: BadgeInitItem = { badgeId: 'B002', bindTaskIdList: ['T002'] };
 *   const states: TaskClaimState[] = [{ taskId: 'T002', claimed: true }];
 *   BadgeUnlockUtil.isUnlocked(badge, states);      // true
 *   BadgeUnlockUtil.evaluate(badge, states);        // { unlocked: true, claimedCount: 1, ... }
 */

/**
 * 任务领奖状态（判定输入的最小单元）。
 * 由 A 的任务领奖记录接口返回后组装，例如把「已领奖任务 id 列表」映射成该结构。
 */
export interface TaskClaimState {
  /** 任务 id，对应 task_init.json 的 taskId */
  taskId: string;
  /** 是否已领奖：true 已领取奖励，false 未领取 */
  claimed: boolean;
}

/**
 * 徽章初始化配置的解析类型（rawfile/badge_init.json 的结构）。
 * 注意：这是配置文件 DTO，不是数据库实体；字段全部可选，
 * 因为外部 JSON 无法在编译期保证完整性，解析后必须逐项兜底。
 */
export interface BadgeInitItem {
  /** 徽章 id，与 task_init.json 的 bindBadgeId 一一对应 */
  badgeId?: string;
  /** 徽章名称 */
  badgeName?: string;
  /** 徽章描述 */
  badgeDesc?: string;
  /** 图标资源名（不含 app.media. 前缀与后缀） */
  iconRes?: string;
  /** 绑定的任务 id 数组：全部领奖成功才解锁 */
  bindTaskIdList?: string[];
}

/** 单枚徽章的判定结果 */
export interface BadgeUnlockState {
  /** 徽章 id */
  badgeId: string;
  /** 是否解锁 */
  unlocked: boolean;
  /** 已领奖的绑定任务数 */
  claimedCount: number;
  /** 绑定的任务总数（去重后的有效 id 数） */
  requiredCount: number;
  /** 仍未领奖的任务 id，用于详情里提示“还差哪几个任务” */
  pendingTaskIds: string[];
}

export class BadgeUnlockUtil {
  /**
   * 判断单枚徽章是否解锁。
   * @param badge  徽章配置
   * @param states 任务领奖状态列表
   * @returns true 表示绑定的任务全部已领奖
   */
  public static isUnlocked(badge: BadgeInitItem, states: TaskClaimState[]): boolean {
    const required: string[] = BadgeUnlockUtil.getBindTaskIds(badge);
    if (required.length === 0) {
      // 没有绑定任务 = 配置异常，不点亮，避免出现“白送徽章”
      return false;
    }
    const claimedMap: Map<string, boolean> = BadgeUnlockUtil.buildClaimMap(states);
    for (const taskId of required) {
      if (claimedMap.get(taskId) !== true) {
        return false;
      }
    }
    return true;
  }

  /**
   * 计算单枚徽章的完整判定结果（页面展示进度用）。
   * @param badge  徽章配置
   * @param states 任务领奖状态列表
   */
  public static evaluate(badge: BadgeInitItem, states: TaskClaimState[]): BadgeUnlockState {
    return BadgeUnlockUtil.evaluateWithMap(badge, BadgeUnlockUtil.buildClaimMap(states));
  }

  /**
   * 批量判定，返回顺序与入参 badges 一一对应，页面可按下标合并展示数据。
   * @param badges 徽章配置列表
   * @param states 任务领奖状态列表
   */
  public static evaluateAll(badges: BadgeInitItem[], states: TaskClaimState[]): BadgeUnlockState[] {
    const result: BadgeUnlockState[] = [];
    // 状态表只构建一次，避免每个徽章都重建 Map
    const claimedMap: Map<string, boolean> = BadgeUnlockUtil.buildClaimMap(states);
    for (const badge of badges) {
      result.push(BadgeUnlockUtil.evaluateWithMap(badge, claimedMap));
    }
    return result;
  }

  /**
   * 取出徽章绑定的有效任务 id：去空白、去空串、去重，保持配置顺序。
   * 页面也用这个方法拿绑定关系来展示任务名，保证与判定逻辑同源。
   */
  public static getBindTaskIds(badge: BadgeInitItem): string[] {
    const raw: string[] | undefined = badge.bindTaskIdList;
    if (raw === undefined || !Array.isArray(raw)) {
      return [];
    }
    const unique: string[] = [];
    for (const rawId of raw) {
      // JSON 内容不可全信：统一转字符串再 trim，避免 number / null 直接调用字符串方法报错
      const id: string = String(rawId).trim();
      if (id.length === 0 || id === 'null' || id === 'undefined') {
        continue;
      }
      if (unique.indexOf(id) < 0) {
        unique.push(id);
      }
    }
    return unique;
  }

  /* ============================ 内部实现 ============================ */

  /** 复用已构建的领奖状态表做判定，避免批量计算时重复建 Map */
  private static evaluateWithMap(badge: BadgeInitItem, claimedMap: Map<string, boolean>): BadgeUnlockState {
    const required: string[] = BadgeUnlockUtil.getBindTaskIds(badge);
    const pending: string[] = [];
    let claimedCount: number = 0;
    for (const taskId of required) {
      if (claimedMap.get(taskId) === true) {
        claimedCount++;
      } else {
        pending.push(taskId);
      }
    }
    return {
      badgeId: badge.badgeId ?? '',
      unlocked: required.length > 0 && pending.length === 0,
      claimedCount: claimedCount,
      requiredCount: required.length,
      pendingTaskIds: pending
    };
  }

  /**
   * 领奖状态列表 -> Map。
   * 同一个 taskId 重复出现时以第一次为准，避免后面的脏数据覆盖真实状态。
   */
  private static buildClaimMap(states: TaskClaimState[]): Map<string, boolean> {
    const map: Map<string, boolean> = new Map<string, boolean>();
    if (!Array.isArray(states)) {
      return map;
    }
    for (const state of states) {
      const id: string = String(state.taskId ?? '').trim();
      if (id.length === 0) {
        continue;
      }
      if (!map.has(id)) {
        map.set(id, state.claimed === true);
      }
    }
    return map;
  }
}
