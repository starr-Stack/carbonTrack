/*
 * 文件名：TaskList.ets
 * 存放路径：entry/src/main/ets/pages/TaskList.ets
 * 功能：低碳任务列表页。读取 rawfile/task_init.json，以卡片形式展示任务，
 *       并按进度区分【未开始 / 进行中 / 已完成】三种状态，已完成任务可点击【领取积分】。
 *
 * 职责边界：
 *   1. 任务元数据（名称、条件、奖励、绑定徽章）来自 rawfile/task_init.json；
 *   2. 运行状态（进度、是否已领奖）全部通过 service/TaskService 读取，
 *      领奖也由它在一个事务里完成，本页不写 SQL、不操作 RdbStore；
 *   3. 每次页面重新可见都会重新计算进度，保证从录入页返回后数字是最新的；
 *   4. 样式（背景 #F1F3F5、白色圆角卡片 16、主色 #2E7D32、金色 #F9A825、
 *      字号/间距）全部对齐 Index.ets 与 AddRecord.ets，不引入任何第三方依赖。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../model/AppState';
import { TaskService, TaskProgress } from '../service/TaskService';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'TaskList';

/* ============================ 主题色（与主项目保持一致） ============================ */
/** 页面底色，与首页/录入页一致 */
const COLOR_BG: string = '#F1F3F5';
/** 主色（环保绿） */
const COLOR_PRIMARY: string = '#2E7D32';
/** 主色浅底，用于标签、状态底色 */
const COLOR_PRIMARY_LIGHT: string = '#E8F5E9';
/** 积分金色 */
const COLOR_GOLD: string = '#F9A825';
/** 标题深灰 */
const COLOR_TITLE: string = '#263238';
/** 正文说明灰 */
const COLOR_TEXT: string = '#607D8B';
/** 次要信息灰 */
const COLOR_MUTED: string = '#90A4AE';
/** 更浅的提示灰 */
const COLOR_HINT: string = '#B0BEC5';
/** 分割线 */
const COLOR_LINE: string = '#F0F0F0';
/** 卡片白 */
const COLOR_CARD: string = '#FFFFFF';
/** 未开始状态底色/文字 */
const COLOR_IDLE_BG: string = '#ECEFF1';
const COLOR_IDLE_TEXT: string = '#78909C';
/** 进行中状态底色/文字 */
const COLOR_DOING_BG: string = '#FFF8E1';
const COLOR_DOING_TEXT: string = '#EF6C00';

/* ============================ 任务状态常量 ============================ */
/** 未开始：进度为 0 */
const STATUS_NOT_STARTED: number = 0;
/** 进行中：0 < 进度 < 目标 */
const STATUS_DOING: number = 1;
/** 已完成：进度 >= 目标 */
const STATUS_DONE: number = 2;

/**
 * rawfile/task_init.json 的解析类型（配置 DTO，不是数据库实体）。
 * 字段全部声明为可选，因为外部 JSON 无法在编译期保证完整性，
 * 解析后必须逐项兜底，避免某个字段缺失导致页面白屏。
 */
interface TaskInitItem {
  taskId?: string;
  taskName?: string;
  taskDesc?: string;
  targetDesc?: string;
  rewardPoint?: number;
  bindBadgeId?: string;
  taskType?: string;
  targetValue?: number;
}

/** 任务卡片的展示模型（页面内部组装，不对应任何数据表） */
interface TaskCardItem {
  /** 任务唯一标识，用于领奖与进度查询 */
  taskId: string;
  /** 任务名称 */
  taskName: string;
  /** 任务描述 */
  taskDesc: string;
  /** 完成条件的展示文案 */
  targetDesc: string;
  /** 奖励积分 */
  rewardPoint: number;
  /** 绑定的徽章 id（本页不展示徽章，保留给徽章模块反查） */
  bindBadgeId: string;
  /** 任务判定口径：record / travel / electricity / water / recycle / food / co2 */
  taskType: string;
  /** 当前进度值 */
  current: number;
  /** 目标进度值 */
  target: number;
  /** 状态：0 未开始 / 1 进行中 / 2 已完成 */
  status: number;
}


@Entry
@Component
struct TaskList {
  /** 任务卡片数据 */
  @State tasks: TaskCardItem[] = [];
  /** 页面加载状态：0 加载中 / 1 成功 / 2 失败 */
  @State loadState: number = 0;
  /** 失败原因，展示在错误态里 */
  @State errorMsg: string = '';
  /** 已领取过奖励的任务 id（页面级临时状态，刷新后重置，最终以 A 的领奖记录表为准） */
  @State claimedTaskIds: string[] = [];
  /** 当前展开详情的任务 id，空字符串表示全部收起 */
  @State expandedTaskId: string = '';

  /**
   * 每次页面可见时都重新计算进度。
   * 用 onPageShow 而不是 aboutToAppear：用户可能刚从录入页记录了一条行为返回，
   * 只有重新拉取才能把 2/3 更新成 3/3，否则会看到过期数据。
   */
  onPageShow(): void {
    this.loadTasks();
  }

  /* ============================ 数据加载 ============================ */

  /**
   * 读取 rawfile 配置并组装卡片。
   * 失败时不抛异常，切到错误态并给出重试入口，避免白屏。
   */
  private async loadTasks(): Promise<void> {
    this.loadState = 0;
    this.errorMsg = '';
    try {
      // 页面上下文用于访问 rawfile；rawfile 随 HAP 打包，读取不需要任何权限
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('无法获取页面上下文');
      }
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync('task_init.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const jsonText: string = decoder.decodeToString(bytes);

      const parsed: TaskInitItem[] = JSON.parse(jsonText) as TaskInitItem[];
      if (!Array.isArray(parsed)) {
        throw new Error('task_init.json 根节点必须是数组');
      }
      if (parsed.length === 0) {
        throw new Error('task_init.json 没有任何任务');
      }

      // 先取已领奖任务，避免卡片先渲染成"可领取"
      this.claimedTaskIds = await TaskService.getClaimedTaskIds();

      const cards: TaskCardItem[] = [];
      for (const item of parsed) {
        const taskId: string = item.taskId ?? '';
        if (taskId.length === 0) {
          // 缺少主键的脏数据直接跳过，不让单条配置拖垮整页
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'skip task without taskId');
          continue;
        }
        const progress: TaskProgress = await TaskService.getProgress(item.taskType ?? '', item.targetValue ?? 0);
        const target: number = progress.target > 0 ? progress.target : 1;
        const current: number = progress.current < 0 ? 0 : progress.current;
        cards.push({
          taskId: taskId,
          taskName: item.taskName ?? '未命名任务',
          taskDesc: item.taskDesc ?? '',
          targetDesc: item.targetDesc ?? '',
          rewardPoint: item.rewardPoint ?? 0,
          bindBadgeId: item.bindBadgeId ?? '',
          taskType: item.taskType ?? '',
          current: current,
          target: target,
          status: this.resolveStatus(current, target)
        });
      }
      this.tasks = cards;
      this.loadState = 1;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'task_init.json loaded, count=%{public}d', cards.length);
    } catch (err) {
      this.errorMsg = err instanceof Error ? err.message : String(err);
      this.loadState = 2;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load task_init.json failed: %{public}s', this.errorMsg);
    }
  }

  /** 根据进度判定状态 */
  private resolveStatus(current: number, target: number): number {
    if (target > 0 && current >= target) {
      return STATUS_DONE;
    }
    if (current > 0) {
      return STATUS_DOING;
    }
    return STATUS_NOT_STARTED;
  }

  /* ============================ 交互逻辑 ============================ */

  /**
   * 领取任务奖励：
   *   1. TaskService.claimReward 在同一事务里写领奖记录、累加用户累计积分、
   *      更新当天汇总，并保证同一个任务不会重复发奖（幂等）；
   *   2. 成功后同步 AppState 的今日积分，回到首页即可看到加分；
   *   3. 失败（多为已领过奖或数据库未就绪）时重新拉取列表，让按钮回到真实状态。
   */
  private async onClaim(task: TaskCardItem): Promise<void> {
    if (task.status !== STATUS_DONE || this.isClaimed(task.taskId)) {
      return;
    }
    const ok: boolean = await TaskService.claimReward(task.taskId, task.taskName, task.rewardPoint);
    if (!ok) {
      this.toast('领取失败，可能已经领取过');
      await this.loadTasks();
      return;
    }
    AppState.addPoint(task.rewardPoint);
    this.claimedTaskIds = this.claimedTaskIds.concat(task.taskId);
    this.toast('已领取 ' + task.rewardPoint + ' 积分');
  }

  /** 是否已领取（页面级判断，刷新后以 A 的领奖记录为准） */
  private isClaimed(taskId: string): boolean {
    return this.claimedTaskIds.indexOf(taskId) >= 0;
  }

  /** 点击卡片展开/收起详情 */
  private toggleExpand(taskId: string): void {
    this.expandedTaskId = this.expandedTaskId === taskId ? '' : taskId;
  }

  /* ============================ 文案与数值工具 ============================ */

  /** 状态文案 */
  private statusText(status: number): string {
    if (status === STATUS_DONE) {
      return '已完成';
    }
    if (status === STATUS_DOING) {
      return '进行中';
    }
    return '未开始';
  }

  /** 状态文字颜色 */
  private statusColor(status: number): string {
    if (status === STATUS_DONE) {
      return COLOR_PRIMARY;
    }
    if (status === STATUS_DOING) {
      return COLOR_DOING_TEXT;
    }
    return COLOR_IDLE_TEXT;
  }

  /** 状态底色 */
  private statusBg(status: number): string {
    if (status === STATUS_DONE) {
      return COLOR_PRIMARY_LIGHT;
    }
    if (status === STATUS_DOING) {
      return COLOR_DOING_BG;
    }
    return COLOR_IDLE_BG;
  }

  /** 进度文案：减排量类任务用 kg，其余用次数 */
  private progressText(item: TaskCardItem): string {
    if (item.taskType === 'co2') {
      return item.current.toFixed(2) + ' / ' + item.target.toFixed(2) + ' kg';
    }
    return item.current + ' / ' + item.target + ' 次';
  }

  /** 进度百分比，0~100 */
  private progressPercent(item: TaskCardItem): number {
    if (item.target <= 0) {
      return 0;
    }
    const percent: number = Math.round(item.current / item.target * 100);
    return percent > 100 ? 100 : percent;
  }

  /** 任务判定口径的中文说明，用于详情区 */
  private typeLabel(taskType: string): string {
    if (taskType === 'record') {
      return '按记录条数判定';
    }
    if (taskType === 'co2') {
      return '按累计减排量判定';
    }
    if (taskType === 'travel') {
      return '按出行类记录次数判定';
    }
    if (taskType === 'electricity') {
      return '按节电类记录次数判定';
    }
    if (taskType === 'water') {
      return '按节水类记录次数判定';
    }
    if (taskType === 'recycle') {
      return '按旧物回收记录次数判定';
    }
    if (taskType === 'food') {
      return '按光盘行动记录次数判定';
    }
    return '按低碳行为记录判定';
  }

  /** 已完成任务数 */
  private doneCount(): number {
    return this.tasks.filter((item: TaskCardItem) => item.status === STATUS_DONE).length;
  }

  /** 待领取奖励的任务数 */
  private claimableCount(): number {
    return this.tasks.filter((item: TaskCardItem) =>
      item.status === STATUS_DONE && !this.isClaimed(item.taskId)).length;
  }

  /** 全部任务奖励积分合计 */
  private totalReward(): number {
    let sum: number = 0;
    for (const item of this.tasks) {
      sum += item.rewardPoint;
    }
    return sum;
  }

  /**
   * ForEach 的 key。
   * 必须把 status / claimed / expanded 一起拼进去：ArkUI 的 ForEach 在 key 不变时
   * 不会重建子组件，只写 taskId 会导致领取后按钮文案、展开态不刷新。
   */
  private buildKey(item: TaskCardItem): string {
    const claimed: string = this.isClaimed(item.taskId) ? '1' : '0';
    const expanded: string = this.expandedTaskId === item.taskId ? '1' : '0';
    return item.taskId + '_' + item.status + '_' + item.current + '_' + claimed + '_' + expanded;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      // 页面栈为空（如被直接设为首页）时忽略，停留在当前页
    }
  }

  /* ============================ UI 片段 ============================ */

  /** 状态标签 */
  @Builder
  StatusPill(status: number) {
    Text(this.statusText(status))
      .fontSize(11)
      .fontColor(this.statusColor(status))
      .backgroundColor(this.statusBg(status))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(10)
  }

  /** 单个任务卡片 */
  @Builder
  TaskCard(item: TaskCardItem) {
    Column() {
      // 第一行：任务名 + 状态
      Row() {
        Text(item.taskName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TITLE)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.StatusPill(item.status)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 任务描述，最多两行
      Text(item.taskDesc)
        .fontSize(13)
        .fontColor(COLOR_TEXT)
        .lineHeight(20)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })

      // 完成条件
      Row() {
        Text('条件')
          .fontSize(11)
          .fontColor(COLOR_PRIMARY)
          .backgroundColor(COLOR_PRIMARY_LIGHT)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
        Text(item.targetDesc)
          .fontSize(12)
          .fontColor('#78909C')
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 10 })

      // 进度条
      Column() {
        Row() {
          Text('进度')
            .fontSize(12)
            .fontColor(COLOR_MUTED)
          Blank()
          Text(this.progressText(item) + ' · ' + this.progressPercent(item) + '%')
            .fontSize(12)
            .fontColor(item.status === STATUS_DONE ? COLOR_PRIMARY : COLOR_MUTED)
        }
        .width('100%')

        Progress({
          value: item.target > 0 ? Math.min(item.current, item.target) : 0,
          total: item.target > 0 ? item.target : 1,
          type: ProgressType.Linear
        })
          .width('100%')
          .height(6)
          .color(COLOR_PRIMARY)
          .backgroundColor('#EDEFF2')
          .margin({ top: 6 })
      }
      .width('100%')
      .margin({ top: 12 })

      // 展开区：任务编号 + 判定口径 + 完整条件
      if (this.expandedTaskId === item.taskId) {
        Column() {
          Row() {
            Text('任务编号')
              .fontSize(12)
              .fontColor(COLOR_HINT)
              .width(64)
            Text(item.taskId)
              .fontSize(12)
              .fontColor(COLOR_TEXT)
          }
          .width('100%')

          Row() {
            Text('判定方式')
              .fontSize(12)
              .fontColor(COLOR_HINT)
              .width(64)
            Text(this.typeLabel(item.taskType))
              .fontSize(12)
              .fontColor(COLOR_TEXT)
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text('完成条件')
              .fontSize(12)
              .fontColor(COLOR_HINT)
              .width(64)
            Text(item.targetDesc)
              .fontSize(12)
              .fontColor(COLOR_TEXT)
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#FAFBFC')
        .borderRadius(10)
        .margin({ top: 12 })
      }

      Divider()
        .color(COLOR_LINE)
        .margin({ top: 12 })

      // 底部：奖励 + 领取按钮
      Row() {
        Text('奖励')
          .fontSize(12)
          .fontColor(COLOR_TEXT)
        Text('+' + item.rewardPoint)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_GOLD)
          .margin({ left: 4 })
        Text('积分')
          .fontSize(12)
          .fontColor(COLOR_TEXT)
          .margin({ left: 2 })

        Blank()

        if (item.status === STATUS_DONE) {
          Button(this.isClaimed(item.taskId) ? '已领取' : '领取积分')
            .height(32)
            .fontSize(13)
            .borderRadius(16)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.isClaimed(item.taskId) ? '#E0E0E0' : COLOR_PRIMARY)
            .fontColor(this.isClaimed(item.taskId) ? '#9E9E9E' : Color.White)
            .enabled(!this.isClaimed(item.taskId))
            .onClick(() => {
              this.onClaim(item);
            })
        } else {
          Text(item.status === STATUS_DOING ? '继续完成' : '去完成')
            .fontSize(12)
            .fontColor(COLOR_HINT)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_CARD)
    .borderRadius(16)
    .margin({ bottom: 12 })
    .onClick(() => {
      this.toggleExpand(item.taskId);
    })
  }

  build() {
    Column() {
      // 顶部导航：与 AddRecord 页保持同一写法
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(COLOR_PRIMARY)
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('低碳任务')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TITLE)
        Blank()
        Text('     ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      // 概览卡
      Row() {
        Column() {
          Text('已完成')
            .fontSize(12)
            .fontColor(COLOR_TEXT)
          Text(this.doneCount() + ' / ' + this.tasks.length)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_PRIMARY)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('待领取')
            .fontSize(12)
            .fontColor(COLOR_TEXT)
          Text(String(this.claimableCount()))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_GOLD)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('累计奖励')
            .fontSize(12)
            .fontColor(COLOR_TEXT)
          Row() {
            Text(String(this.totalReward()))
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TITLE)
            Text('分')
              .fontSize(12)
              .fontColor(COLOR_MUTED)
              .margin({ left: 2, bottom: 3 })
          }
          .margin({ top: 2 })
          .alignItems(VerticalAlign.Bottom)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(18)
      .backgroundColor(COLOR_CARD)
      .borderRadius(16)

      // 内容区
      if (this.loadState === 0) {
        Column() {
          Text('加载中…')
            .fontSize(14)
            .fontColor(COLOR_MUTED)
        }
        .width('100%')
        .padding(40)
      } else if (this.loadState === 2) {
        Column() {
          Text('任务配置加载失败')
            .fontSize(15)
            .fontColor(COLOR_TEXT)
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(COLOR_HINT)
            .margin({ top: 8 })
            .textAlign(TextAlign.Center)
          Button('重新加载')
            .height(36)
            .fontSize(13)
            .borderRadius(18)
            .backgroundColor(COLOR_PRIMARY)
            .margin({ top: 16 })
            .onClick(() => {
              this.loadTasks();
            })
        }
        .width('100%')
        .padding(32)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)
        .margin({ top: 16 })
      } else if (this.tasks.length === 0) {
        Column() {
          Text('还没有可做的任务')
            .fontSize(15)
            .fontColor(COLOR_IDLE_TEXT)
          Text('先记录一条低碳行为，任务进度会自动累积')
            .fontSize(12)
            .fontColor(COLOR_HINT)
            .margin({ top: 6 })
        }
        .width('100%')
        .padding(32)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)
        .margin({ top: 16 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.tasks, (item: TaskCardItem) => {
              this.TaskCard(item)
            }, (item: TaskCardItem) => this.buildKey(item))
          }
          .width('100%')
          .padding({ top: 16, bottom: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .backgroundColor(COLOR_BG)
    .alignItems(HorizontalAlign.Start)
  }
}
