/*
 * 文件名：ArticleList.ets
 * 存放路径：entry/src/main/ets/pages/ArticleList.ets
 * 功能：双碳科普专栏列表页。读取 rawfile/article_list.json，以卡片展示标题、简介、标签，
 *       点击卡片跳转到详情页（pages/ArticleDetail）。
 *
 * 职责边界：
 *   1. 本页不读写数据库、不建表、不定义数据库实体，纯读 rawfile 配置；
 *   2. 不改动任务页 / 徽章页的任何代码，三个模块通过路由互相跳转；
 *   3. 样式（底色 #F1F3F5、白卡 16 圆角、主色 #2E7D32、字号与间距）与
 *      TaskList.ets、BadgeList.ets 完全一致。
 *
 * ======================== Tab 导航入口预留 ========================
 * 当前工程还没有底部 Tab 骨架（由队友 A 统一搭建，见团队分工）。
 * 本页已做成独立路由页，等 Tab 骨架合并后，直接在 TabContent 里挂载即可，
 * 不需要改本文件：
 *
 *   // A 的 Tab 骨架里（示意，不要照抄到这个文件）
 *   Tabs() {
 *     TabContent() { HomeView() }.tabBar('首页')
 *     TabContent() { TaskView() }.tabBar('任务')
 *     TabContent() { BadgeView() }.tabBar('徽章')
 *     TabContent() { Column().onClick(() => router.pushUrl({ url: 'pages/ArticleList' })) }
 *       .tabBar('科普')
 *   }
 *
 * 另外本页右上角已放了一个「任务 ›」入口，作为 Tab 上线前的临时跳转通道，
 * Tab 骨架合并后把这行删掉即可（见 goTaskPage 注释）。
 * ================================================================
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'ArticleList';

/* ============================ 主题色（与任务页 / 徽章页同一套） ============================ */
const COLOR_BG: string = '#F1F3F5';
const COLOR_PRIMARY: string = '#2E7D32';
const COLOR_PRIMARY_LIGHT: string = '#E8F5E9';
const COLOR_TITLE: string = '#263238';
const COLOR_TEXT: string = '#607D8B';
const COLOR_MUTED: string = '#90A4AE';
const COLOR_HINT: string = '#B0BEC5';
const COLOR_CARD: string = '#FFFFFF';

/** article_list.json 的解析类型（配置 DTO，非数据库实体；字段全可选，解析后逐项兜底） */
interface ArticleItem {
  articleId?: string;
  title?: string;
  summary?: string;
  tag?: string;
  contentRawPath?: string;
}

/** 列表卡片的展示模型（页面内部组装，不对应任何数据表） */
interface ArticleCardView {
  articleId: string;
  title: string;
  summary: string;
  tag: string;
}

/** 详情页的入参 */
interface ArticleRouteParams {
  articleId: string;
}

@Entry
@Component
struct ArticleList {
  @State articles: ArticleCardView[] = [];
  /** 0 加载中 / 1 成功 / 2 失败 */
  @State loadState: number = 0;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.loadArticles();
  }

  /* ============================ 数据 ============================ */

  private loadArticles(): void {
    this.loadState = 0;
    this.errorMsg = '';
    try {
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('无法获取页面上下文');
      }
      const text: string = this.readRawFile(context, 'article_list.json');
      const list: ArticleItem[] = JSON.parse(text) as ArticleItem[];
      if (!Array.isArray(list)) {
        throw new Error('article_list.json 根节点必须是数组');
      }
      if (list.length === 0) {
        throw new Error('article_list.json 没有文章');
      }

      const views: ArticleCardView[] = [];
      for (const item of list) {
        const articleId: string = item.articleId ?? '';
        if (articleId.length === 0) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'skip article without articleId');
          continue;
        }
        views.push({
          articleId: articleId,
          title: item.title ?? '未命名文章',
          summary: item.summary ?? '',
          tag: item.tag ?? '科普'
        });
      }
      this.articles = views;
      this.loadState = 1;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'articles loaded, count=%{public}d', views.length);
    } catch (err) {
      this.errorMsg = err instanceof Error ? err.message : String(err);
      this.loadState = 2;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load article_list.json failed: %{public}s', this.errorMsg);
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

  /* ============================ 路由 ============================ */

  /** 跳详情：只传 articleId，详情页自己再读一次配置，避免整篇文章塞进路由参数 */
  private openArticle(articleId: string): void {
    const params: ArticleRouteParams = { articleId: articleId };
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/ArticleDetail',
        params: params
      }).catch(() => {
        // 跳转失败时停留在列表页
      });
    } catch (err) {
      // 路由异常不阻塞页面
    }
  }

  /**
   * 跳任务页（Tab 骨架上线前的临时入口）。
   * Tab 骨架合并后，删掉 build() 里右上角的「任务 ›」即可，
   * 本方法可保留给其它页面复用。
   */
  private goTaskPage(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TaskList' }).catch(() => {
        // 跳转失败时停留在当前页
      });
    } catch (err) {
      // 忽略
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      // 页面栈为空（如被直接设为首页）时忽略
    }
  }

  /* ============================ 标签配色 ============================ */

  /** 标签文字色：按主题区分，方便用户扫读 */
  private tagColor(tag: string): string {
    if (tag === '核算方法') {
      return '#1565C0';
    }
    if (tag === '机制说明') {
      return '#EF6C00';
    }
    return COLOR_PRIMARY;
  }

  /** 标签底色 */
  private tagBg(tag: string): string {
    if (tag === '核算方法') {
      return '#E3F2FD';
    }
    if (tag === '机制说明') {
      return '#FFF3E0';
    }
    return COLOR_PRIMARY_LIGHT;
  }

  /* ============================ UI ============================ */

  /** 单篇文章卡片 */
  @Builder
  ArticleCard(item: ArticleCardView) {
    Column() {
      Row() {
        Text(item.tag)
          .fontSize(11)
          .fontColor(this.tagColor(item.tag))
          .backgroundColor(this.tagBg(item.tag))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
        Blank()
        Text('阅读 ›')
          .fontSize(12)
          .fontColor(COLOR_HINT)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(item.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TITLE)
        .lineHeight(23)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 10 })

      Text(item.summary)
        .fontSize(13)
        .fontColor(COLOR_TEXT)
        .lineHeight(20)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_CARD)
    .borderRadius(16)
    .margin({ bottom: 12 })
    .onClick(() => {
      this.openArticle(item.articleId);
    })
  }

  build() {
    Column() {
      // 顶部导航：与任务页 / 徽章页同一写法
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(COLOR_PRIMARY)
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('科普专栏')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TITLE)
        Blank()
        // Tab 骨架上线前的临时入口，合并后删除这一行
        Text('任务 ›')
          .fontSize(13)
          .fontColor(COLOR_PRIMARY)
          .onClick(() => {
            this.goTaskPage();
          })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      // 栏目标题卡：顶部配图 + 文案
      Column() {
        Image($r('app.media.ic_knowledge_banner'))
          .width('100%')
          .height(126)
          .objectFit(ImageFit.Cover)

        Column() {
          Text('双碳科普')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_PRIMARY)
          Text('政策依据、核算方法、市场机制，按官方口径梳理')
            .fontSize(12)
            .fontColor(COLOR_TEXT)
            .margin({ top: 6 })
          Text('共 ' + this.articles.length + ' 篇 · 每篇约 3~5 分钟')
            .fontSize(11)
            .fontColor(COLOR_MUTED)
            .margin({ top: 10 })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 18 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .backgroundColor(COLOR_CARD)
      .borderRadius(16)
      .clip(true)

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
          Text('文章列表加载失败')
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
              this.loadArticles();
            })
        }
        .width('100%')
        .padding(32)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)
        .margin({ top: 16 })
      } else if (this.articles.length === 0) {
        Column() {
          Text('还没有科普文章')
            .fontSize(15)
            .fontColor(COLOR_TEXT)
          Text('配置 article_list.json 后即可展示')
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
            ForEach(this.articles, (item: ArticleCardView) => {
              this.ArticleCard(item)
            }, (item: ArticleCardView) => item.articleId)
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
