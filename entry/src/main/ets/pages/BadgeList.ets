/*
 * 文件名：BadgeList.ets
 * 存放路径：entry/src/main/ets/pages/BadgeList.ets
 * 功能：徽章展示页。读取 rawfile/badge_init.json 渲染徽章网格，
 *       未解锁徽章置灰弱化、已解锁徽章高亮，点击卡片弹出详情弹窗。
 *
 * 职责边界：
 *   1. 徽章元数据来自 rawfile/badge_init.json；解锁判定交给
 *      utils/BadgeUnlockUtil.ets（纯函数），解锁记录通过 service/BadgeService 持久化；
 *   2. 任务领奖状态通过 service/TaskService 读取，本页不写 SQL、不操作 RdbStore；
 *   3. 数据来源：
 *      - badge_init.json：徽章元数据（id / 名称 / 描述 / 图标资源名 / 绑定任务）
 *      - task_init.json ：只用于把 taskId 映射成任务名，读不到时退化为显示 taskId
 *      - TaskService.getClaimedTaskIds()：已领奖任务 -> 徽章解锁判定输入
 *   4. 样式（底色 #F1F3F5、白卡 16 圆角、主色 #2E7D32、金色 #F9A825、字号与间距）
 *      与 TaskList.ets、Index.ets 保持一致，不引入任何第三方依赖。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BadgeInitItem, BadgeUnlockState, TaskClaimState, BadgeUnlockUtil } from '../utils/BadgeUnlockUtil';
import { TaskService } from '../service/TaskService';
import { BadgeService, BadgeUnlockInput } from '../service/BadgeService';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'BadgeList';

/* ============================ 主题色（与 TaskList / Index 同一套） ============================ */
const COLOR_BG: string = '#F1F3F5';
const COLOR_PRIMARY: string = '#2E7D32';
const COLOR_PRIMARY_LIGHT: string = '#E8F5E9';
const COLOR_TITLE: string = '#263238';
const COLOR_TEXT: string = '#607D8B';
const COLOR_MUTED: string = '#90A4AE';
const COLOR_HINT: string = '#B0BEC5';
const COLOR_LINE: string = '#F0F0F0';
const COLOR_CARD: string = '#FFFFFF';
/** 未解锁卡片的底色与文字色：整体压暗，和已解锁形成对比 */
const COLOR_LOCKED_BG: string = '#F7F8FA';
const COLOR_LOCKED_BORDER: string = '#ECEFF1';
const COLOR_LOCKED_TEXT: string = '#9E9E9E';
const COLOR_LOCKED_DESC: string = '#B0BEC5';

/** task_init.json 中本页只用到两个字段，单独声明解析类型（配置 DTO，非数据库实体） */
interface TaskNameItem {
  taskId?: string;
  taskName?: string;
}

/** 徽章卡片的展示模型（页面内部组装，不对应任何数据表） */
interface BadgeView {
  badgeId: string;
  badgeName: string;
  badgeDesc: string;
  iconRes: string;
  /** 是否已解锁 */
  unlocked: boolean;
  /** 已领奖的绑定任务数 */
  claimedCount: number;
  /** 绑定的任务总数 */
  requiredCount: number;
  /** 绑定任务名，详情里展示解锁条件用 */
  bindTaskNames: string[];
  /** 仍未领奖的任务名，未解锁时提示“还差哪几个” */
  pendingTaskNames: string[];
  /** 解锁时间文案：数据库目前只返回已解锁的 badgeId，暂取不到时间戳，先留空显示为「—」 */
  unlockTime: string;
}

/** 详情弹窗的初始值，避免 @State 未初始化 */
const EMPTY_BADGE: BadgeView = {
  badgeId: '',
  badgeName: '',
  badgeDesc: '',
  iconRes: '',
  unlocked: false,
  claimedCount: 0,
  requiredCount: 0,
  bindTaskNames: [],
  pendingTaskNames: [],
  unlockTime: ''
};


@Entry
@Component
struct BadgeList {
  /** 徽章卡片数据 */
  @State badges: BadgeView[] = [];
  /** 0 加载中 / 1 成功 / 2 失败 */
  @State loadState: number = 0;
  @State errorMsg: string = '';
  /** 详情弹窗是否显示 */
  @State detailVisible: boolean = false;
  /** 当前弹窗展示的徽章 */
  @State detailBadge: BadgeView = EMPTY_BADGE;
  /** 已持久化的解锁记录，用于判断哪些是本次新解锁的，避免重复写库 */
  @State persistedBadgeIds: string[] = [];

  /** 每次回到本页都重新判定一次，保证从任务页领奖返回后状态立即刷新 */
  onPageShow(): void {
    this.loadData();
  }

  /* ============================ 数据加载 ============================ */

  /** 读取两个 rawfile 配置 -> 判定解锁 -> 组装卡片 */
  private async loadData(): Promise<void> {
    this.loadState = 0;
    this.errorMsg = '';
    try {
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('无法获取页面上下文');
      }

      const badgeText: string = this.readRawFile(context, 'badge_init.json');
      const badges: BadgeInitItem[] = JSON.parse(badgeText) as BadgeInitItem[];
      if (!Array.isArray(badges) || badges.length === 0) {
        throw new Error('badge_init.json 内容为空或根节点不是数组');
      }

      // 任务名只是展示用，读不到不影响解锁判定
      const taskNames: Map<string, string> = this.loadTaskNames(context);
            // 已解锁徽章从数据库取，避免刷新后重复点亮
      this.persistedBadgeIds = await BadgeService.getUnlockedBadgeIds();
      const states: TaskClaimState[] = await this.loadClaimStates();
      const unlocks: BadgeUnlockState[] = BadgeUnlockUtil.evaluateAll(badges, states);

      const views: BadgeView[] = [];
      for (let index: number = 0; index < badges.length; index++) {
        const config: BadgeInitItem = badges[index];
        const unlock: BadgeUnlockState = unlocks[index];
        const badgeId: string = config.badgeId ?? '';
        if (badgeId.length === 0) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'skip badge without badgeId');
          continue;
        }
        const bindIds: string[] = BadgeUnlockUtil.getBindTaskIds(config);
        views.push({
          badgeId: badgeId,
          badgeName: config.badgeName ?? '未命名徽章',
          badgeDesc: config.badgeDesc ?? '',
          iconRes: config.iconRes ?? '',
          unlocked: unlock.unlocked,
          claimedCount: unlock.claimedCount,
          requiredCount: unlock.requiredCount,
          bindTaskNames: this.mapTaskNames(bindIds, taskNames),
          pendingTaskNames: this.mapTaskNames(unlock.pendingTaskIds, taskNames),
          unlockTime: ''
        });
      }

      this.badges = views;
      this.loadState = 1;
      await this.persistNewlyUnlocked(views);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'badges loaded, count=%{public}d, unlocked=%{public}d',
        views.length, this.unlockedCount());
    } catch (err) {
      this.errorMsg = err instanceof Error ? err.message : String(err);
      this.loadState = 2;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load badge_init.json failed: %{public}s', this.errorMsg);
    }
  }

  /** 读 rawfile 文本（随 HAP 打包，读取不需要权限） */
  private readRawFile(context: common.Context, fileName: string): string {
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(fileName);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(bytes);
    } catch (err) {
      // getRawFileContentSync 带 @throws：文件缺失/损坏时会抛异常，
      // 这里就地转成可读文案再抛给上层，由页面的错误态统一展示
      const message: string = err instanceof Error ? err.message : String(err);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'read rawfile %{public}s failed: %{public}s', fileName, message);
      throw new Error('读取 ' + fileName + ' 失败：' + message);
    }
  }

  /** task_init.json -> taskId 到 taskName 的映射；失败时返回空 Map，不影响主流程 */
  private loadTaskNames(context: common.Context): Map<string, string> {
    const nameMap: Map<string, string> = new Map<string, string>();
    try {
      const text: string = this.readRawFile(context, 'task_init.json');
      const list: TaskNameItem[] = JSON.parse(text) as TaskNameItem[];
      if (!Array.isArray(list)) {
        return nameMap;
      }
      for (const item of list) {
        const id: string = item.taskId ?? '';
        const name: string = item.taskName ?? '';
        if (id.length > 0 && name.length > 0) {
          nameMap.set(id, name);
        }
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'load task_init.json for names failed: %{public}s',
        err instanceof Error ? err.message : String(err));
    }
    return nameMap;
  }

  /** 从任务服务读取已领奖任务，组装成徽章判定需要的状态列表 */
  private async loadClaimStates(): Promise<TaskClaimState[]> {
    const claimedIds: string[] = await TaskService.getClaimedTaskIds();
    const states: TaskClaimState[] = [];
    for (const taskId of claimedIds) {
      states.push({ taskId: taskId, claimed: true });
    }
    return states;
  }
  /**
   * 把本次新解锁的徽章写入数据库。
   * 只写「已解锁但库里还没有」的部分，BadgeService 内部按 badgeId 去重并放在同一事务里，
   * 所以重复进入页面也不会产生重复记录。
   */
  private async persistNewlyUnlocked(list: BadgeView[]): Promise<void> {
    const inputs: BadgeUnlockInput[] = [];
    for (const item of list) {
      if (item.unlocked && this.persistedBadgeIds.indexOf(item.badgeId) < 0) {
        inputs.push({ badgeId: item.badgeId, badgeName: item.badgeName });
      }
    }
    if (inputs.length === 0) {
      return;
    }
    const saved: boolean = await BadgeService.saveUnlocked(inputs);
    if (saved) {
      for (const item of inputs) {
        this.persistedBadgeIds = this.persistedBadgeIds.concat(item.badgeId);
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'persisted %{public}d badges', inputs.length);
    }
  }

  /* ============================ 交互 ============================ */

  private openDetail(item: BadgeView): void {
    this.detailBadge = item;
    this.detailVisible = true;
  }

  private closeDetail(): void {
    this.detailVisible = false;
  }

  /** 弹窗按钮：已解锁只关闭；未解锁则跳到任务页去做任务 */
  private onDetailButton(): void {
    if (this.detailBadge.unlocked) {
      this.closeDetail();
      return;
    }
    this.closeDetail();
    this.goTaskPage();
  }

  private goTaskPage(): void {    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskList' }).catch(() => {
        // 跳转失败时停留在当前页
      });
    } catch (err) {
      // 路由异常时静默处理，避免弹窗关闭后页面无响应
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      // 页面栈为空时忽略
    }
  }

  /** 打开植树证书页：把累计减排量折合成种下的树 */
  private goTreeCertificate(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TreeCertificate' }).catch(() => {
        // 跳转失败时停留在当前页
      });
    } catch (err) {
      // 忽略
    }
  }

  /* ============================ 工具方法 ============================ */

  /** 已解锁数量 */
  private unlockedCount(): number {
    return this.badges.filter((item: BadgeView) => item.unlocked).length;
  }

  /** 将任务 id 映射为任务名，查不到时退回 id，保证不出现空白 */
  private mapTaskNames(ids: string[], nameMap: Map<string, string>): string[] {
    const names: string[] = [];
    for (const id of ids) {
      names.push(nameMap.get(id) ?? id);
    }
    return names;
  }

  /**
   * iconRes 字符串 -> 资源对象。
   * ArkTS 的 $r() 只接受编译期字面量，不能用字符串拼接，
   * 所以这里用分支映射；新增徽章图标时记得在这里补一个分支，
   * 没匹配到时回退到项目已有的 startIcon，避免运行时取不到资源。
   */
  private iconResource(iconRes: string): Resource {
    if (iconRes === 'ic_badge_newbie') {
      return $r('app.media.ic_badge_newbie');
    }
    if (iconRes === 'ic_badge_green_travel') {
      return $r('app.media.ic_badge_green_travel');
    }
    if (iconRes === 'ic_badge_power_saver') {
      return $r('app.media.ic_badge_power_saver');
    }
    if (iconRes === 'ic_badge_carbon_pioneer') {
      return $r('app.media.ic_badge_carbon_pioneer');
    }
    return $r('app.media.startIcon');
  }

  /** 概览卡底部提示文案 */
  private hintText(): string {
    const total: number = this.badges.length;
    if (total === 0) {
      return '暂无徽章配置';
    }
    const unlocked: number = this.unlockedCount();
    if (unlocked >= total) {
      return '全部徽章已点亮，继续保持低碳习惯';
    }
    return '还有 ' + (total - unlocked) + ' 枚徽章待点亮，完成任务并领取奖励即可解锁';
  }

  /** 详情弹窗里的解锁条件文案 */
  private conditionText(): string {
    if (this.detailBadge.bindTaskNames.length === 0) {
      return '未绑定任务（配置异常，暂不可解锁）';
    }
    return '完成「' + this.detailBadge.bindTaskNames.join('」「') + '」并领取奖励';
  }

  /** 详情弹窗里“还差任务”的文案 */
  private pendingText(): string {
    if (this.detailBadge.pendingTaskNames.length === 0) {
      return '—';
    }
    return this.detailBadge.pendingTaskNames.join('、');
  }

  /* ============================ UI 片段 ============================ */

  /** 单个徽章卡片 */
  @Builder
  BadgeCard(item: BadgeView) {
    Column() {
      Image(this.iconResource(item.iconRes))
        .width(56)
        .height(56)
        .objectFit(ImageFit.Contain)
        // 未解锁：图标压到 35% 透明度，肉眼可见地“弱化”
        .opacity(item.unlocked ? 1 : 0.35)

      Text(item.badgeName)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(item.unlocked ? COLOR_TITLE : COLOR_LOCKED_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })

      Text(item.badgeDesc)
        .fontSize(11)
        .lineHeight(15)
        .fontColor(item.unlocked ? COLOR_TEXT : COLOR_LOCKED_DESC)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: 4 })

      Blank()

      Row() {
        Text(item.unlocked ? '已解锁' : '未解锁')
          .fontSize(10)
          .fontColor(item.unlocked ? COLOR_PRIMARY : COLOR_LOCKED_TEXT)
          .backgroundColor(item.unlocked ? COLOR_PRIMARY_LIGHT : '#EFEFEF')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(8)
        Blank()
        if (!item.unlocked) {
          Text(item.claimedCount + ' / ' + item.requiredCount)
            .fontSize(10)
            .fontColor(COLOR_LOCKED_DESC)
        }
      }
      .width('100%')
    }
    .width('48.5%')
    .height(196)
    .padding(12)
    .backgroundColor(item.unlocked ? COLOR_CARD : COLOR_LOCKED_BG)
    .borderRadius(16)
    .border({ width: 1, color: item.unlocked ? '#C8E6C9' : COLOR_LOCKED_BORDER })
    .margin({ bottom: 12 })
    .onClick(() => {
      this.openDetail(item);
    })
  }

  /** 详情弹窗里的一行「标签 - 值」 */
  @Builder
  DetailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(COLOR_HINT)
        .width(64)
      Text(value)
        .fontSize(12)
        .fontColor(COLOR_TEXT)
        .lineHeight(18)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 8 })
  }

  /** 详情弹窗内容 */
  @Builder
  DetailPanel() {
    Column() {
      Image(this.iconResource(this.detailBadge.iconRes))
        .width(76)
        .height(76)
        .objectFit(ImageFit.Contain)
        .opacity(this.detailBadge.unlocked ? 1 : 0.35)

      Text(this.detailBadge.badgeName)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.detailBadge.unlocked ? COLOR_TITLE : COLOR_LOCKED_TEXT)
        .margin({ top: 10 })

      Text(this.detailBadge.badgeDesc)
        .fontSize(13)
        .fontColor(COLOR_TEXT)
        .lineHeight(19)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })

      Text(this.detailBadge.unlocked ? '已解锁' : '未解锁')
        .fontSize(12)
        .fontColor(this.detailBadge.unlocked ? COLOR_PRIMARY : COLOR_LOCKED_TEXT)
        .backgroundColor(this.detailBadge.unlocked ? COLOR_PRIMARY_LIGHT : '#EFEFEF')
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .borderRadius(10)
        .margin({ top: 12 })

      Divider()
        .color(COLOR_LINE)
        .margin({ top: 16, bottom: 14 })

      this.DetailRow('解锁条件', this.conditionText())
      this.DetailRow('任务进度',
        this.detailBadge.claimedCount + ' / ' + this.detailBadge.requiredCount + ' 个任务已领奖')
      if (!this.detailBadge.unlocked) {
        this.DetailRow('还差任务', this.pendingText())
      }
      this.DetailRow('解锁时间',
        this.detailBadge.unlockTime.length > 0 ? this.detailBadge.unlockTime : '—')

      Button(this.detailBadge.unlocked ? '知道了' : '去做任务')
        .width('100%')
        .height(44)
        .fontSize(15)
        .borderRadius(22)
        .backgroundColor(COLOR_PRIMARY)
        .margin({ top: 14 })
        .onClick(() => {
          this.onDetailButton();
        })
    }
    .width('86%')
    .padding({ left: 20, right: 20, top: 24, bottom: 20 })
    .backgroundColor(Color.White)
    .borderRadius(20)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // 顶部导航，与 TaskList / AddRecord 保持同一写法
        Row() {
          Text('‹ 返回')
            .fontSize(15)
            .fontColor(COLOR_PRIMARY)
            .onClick(() => {
              this.goBack();
            })
          Blank()
          Text('我的徽章')
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
        Column() {
          Row() {
            Column() {
              Text('已解锁徽章')
                .fontSize(13)
                .fontColor(COLOR_TEXT)
              Row() {
                Text(String(this.unlockedCount()))
                  .fontSize(30)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(COLOR_PRIMARY)
                Text(' / ' + this.badges.length + ' 枚')
                  .fontSize(13)
                  .fontColor(COLOR_MUTED)
                  .margin({ left: 4, bottom: 4 })
              }
              .alignItems(VerticalAlign.Bottom)
              .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('去完成任务 ›')
              .fontSize(12)
              .fontColor(COLOR_PRIMARY)
              .padding({ top: 4 })
              .onClick(() => {
                this.goTaskPage();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Progress({
            value: this.unlockedCount(),
            total: this.badges.length > 0 ? this.badges.length : 1,
            type: ProgressType.Linear
          })
            .width('100%')
            .height(6)
            .color(COLOR_PRIMARY)
            .backgroundColor('#EDEFF2')
            .margin({ top: 12 })

          Text(this.hintText())
            .fontSize(12)
            .fontColor(COLOR_MUTED)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(18)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)

        // 植树证书入口：把累计减排量折合成种下的树，入口放在徽章页，拿到成就后顺手看一眼
        Row() {
          Text('🌳')
            .fontSize(26)
          Column() {
            Text('植树证书')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_TITLE)
            Text('把累计减排量折合成种下的树')
              .fontSize(11)
              .fontColor(COLOR_MUTED)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 10 })
          Text('›')
            .fontSize(18)
            .fontColor(COLOR_HINT)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.goTreeCertificate();
        })

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
            Text('徽章配置加载失败')
              .fontSize(15)
              .fontColor(COLOR_TEXT)
            Text(this.errorMsg)
              .fontSize(12)
              .fontColor(COLOR_HINT)
              .textAlign(TextAlign.Center)
              .margin({ top: 8 })
            Button('重新加载')
              .height(36)
              .fontSize(13)
              .borderRadius(18)
              .backgroundColor(COLOR_PRIMARY)
              .margin({ top: 16 })
              .onClick(() => {
                this.loadData();
              })
          }
          .width('100%')
          .padding(32)
          .backgroundColor(COLOR_CARD)
          .borderRadius(16)
          .margin({ top: 16 })
        } else if (this.badges.length === 0) {
          Column() {
            Text('还没有徽章')
              .fontSize(15)
              .fontColor(COLOR_LOCKED_TEXT)
            Text('完成低碳任务并领取奖励，就能点亮徽章')
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
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              ForEach(this.badges, (item: BadgeView) => {
                this.BadgeCard(item)
              }, (item: BadgeView) => item.badgeId + (item.unlocked ? '_u' : '_l') + item.claimedCount)
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
      .alignItems(HorizontalAlign.Start)

      // 详情弹窗：遮罩与面板是 Stack 的兄弟节点，点遮罩关闭、点面板不会穿透
      if (this.detailVisible) {
        Text('')
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeDetail();
          })

        this.DetailPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG)
  }
}
