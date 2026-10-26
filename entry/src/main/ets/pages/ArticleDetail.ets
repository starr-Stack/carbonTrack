/*
 * 文件名：ArticleDetail.ets
 * 存放路径：entry/src/main/ets/pages/ArticleDetail.ets
 * 功能：科普文章详情阅读页。根据路由参数 articleId 读取 rawfile/article_list.json，
 *       再用配置里的 contentRawPath 读取正文文本，解析成「标题 / 段落 / 列表 / 引用 / 表格」
 *       等区块，用 Scroll 支持长文滚动浏览。
 *
 * 职责边界：
 *   1. 不读写数据库、不建表、不定义数据库实体，正文全部来自 rawfile；
 *   2. 不引入 Markdown 渲染库（避免重型依赖），用一个几十行的轻量解析器处理
 *      项目自己约定的极简语法，见 parseContent() 的语法表；
 *   3. 不改动任务页 / 徽章页代码。
 *
 * 正文支持的极简语法（写文章时按这个约定）：
 *   # 一级标题     -> 详情页顶部已展示配置标题，正文首个 # 行会被自动跳过
 *   ## 二级标题    -> 带左侧绿色竖条的小节标题
 *   ### 三级标题   -> 更小的加粗标题
 *   - 列表项       -> 圆点列表
 *   > 引用         -> 浅绿底 + 左侧竖线的提示块
 *   | 左列 | 右列  -> 两列数据行（左列标签、右列数值，适合手机窄屏）
 *   ---            -> 分割线
 *   其它非空行     -> 普通段落
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'ArticleDetail';

/* ============================ 主题色（与任务页 / 徽章页同一套） ============================ */
const COLOR_BG: string = '#F1F3F5';
const COLOR_PRIMARY: string = '#2E7D32';
const COLOR_PRIMARY_LIGHT: string = '#E8F5E9';
const COLOR_TITLE: string = '#263238';
const COLOR_BODY: string = '#37474F';
const COLOR_TEXT: string = '#607D8B';
const COLOR_MUTED: string = '#90A4AE';
const COLOR_HINT: string = '#B0BEC5';
const COLOR_CARD: string = '#FFFFFF';

/* ============================ 正文区块类型 ============================ */
const BLOCK_H1: number = 0;
const BLOCK_H2: number = 1;
const BLOCK_H3: number = 2;
const BLOCK_PARAGRAPH: number = 3;
const BLOCK_BULLET: number = 4;
const BLOCK_QUOTE: number = 5;
const BLOCK_TABLE: number = 6;
const BLOCK_DIVIDER: number = 7;

/** article_list.json 的解析类型（配置 DTO，非数据库实体） */
interface ArticleItem {
  articleId?: string;
  title?: string;
  summary?: string;
  tag?: string;
  contentRawPath?: string;
}

/** 路由入参 */
interface ArticleRouteParams {
  articleId?: string;
}

/** 解析后的正文区块 */
interface ArticleBlock {
  /** 区块类型，取值见上方 BLOCK_* */
  type: number;
  /** 文本内容（标题、段落、列表项、引用使用） */
  text: string;
  /** 表格行左列，非表格区块为空串 */
  tableLabel: string;
  /** 表格行右列，非表格区块为空串 */
  tableValue: string;
}

@Entry
@Component
struct ArticleDetail {
  @State title: string = '';
  @State tag: string = '';
  @State blocks: ArticleBlock[] = [];
  /** 0 加载中 / 1 成功 / 2 失败 */
  @State loadState: number = 0;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.loadArticle();
  }

  /* ============================ 数据加载 ============================ */

  private loadArticle(): void {
    this.loadState = 0;
    this.errorMsg = '';
    try {
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('无法获取页面上下文');
      }
      const articleId: string = this.readArticleId();
      if (articleId.length === 0) {
        throw new Error('缺少 articleId，请从科普列表页进入');
      }

      // 1. 读配置，按 id 找到目标文章
      const listText: string = this.readRawFile(context, 'article_list.json');
      const list: ArticleItem[] = JSON.parse(listText) as ArticleItem[];
      if (!Array.isArray(list)) {
        throw new Error('article_list.json 根节点必须是数组');
      }
      let target: ArticleItem | undefined = undefined;
      for (const item of list) {
        if (item.articleId === articleId) {
          target = item;
          break;
        }
      }
      if (target === undefined) {
        throw new Error('未找到文章：' + articleId);
      }

      // 2. 读正文文本
      const contentPath: string = target.contentRawPath ?? '';
      if (contentPath.length === 0) {
        throw new Error('该文章未配置 contentRawPath');
      }
      const rawText: string = this.readRawFile(context, contentPath);

      this.title = target.title ?? '未命名文章';
      this.tag = target.tag ?? '科普';
      this.blocks = this.parseContent(rawText);
      this.loadState = 1;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'article loaded: %{public}s, blocks=%{public}d',
        articleId, this.blocks.length);
    } catch (err) {
      this.errorMsg = err instanceof Error ? err.message : String(err);
      this.loadState = 2;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load article failed: %{public}s', this.errorMsg);
    }
  }

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

  /**
   * 读路由参数里的 articleId。
   * getParams() 声明返回 Object，但未传参时运行期可能拿到 undefined；
   * 因此不写 `=== undefined` 判断（会与类型声明冲突），统一用 try/catch 兜底。
   */
  private readArticleId(): string {
    try {
      const raw: Object = this.getUIContext().getRouter().getParams();
      const params: ArticleRouteParams = raw as ArticleRouteParams;
      return params.articleId ?? '';
    } catch (err) {
      return '';
    }
  }

  /* ============================ 正文解析 ============================ */

  /** 逐行解析正文，生成区块数组（语法说明见文件头注释） */
  private parseContent(raw: string): ArticleBlock[] {
    const blocks: ArticleBlock[] = [];
    const lines: string[] = raw.split('\n');
    for (const rawLine of lines) {
      const line: string = rawLine.trim();
      if (line.length === 0) {
        continue;
      }
      if (line === '---') {
        blocks.push(this.makeBlock(BLOCK_DIVIDER, '', '', ''));
        continue;
      }
      if (line.startsWith('### ')) {
        blocks.push(this.makeBlock(BLOCK_H3, line.substring(4), '', ''));
        continue;
      }
      if (line.startsWith('## ')) {
        blocks.push(this.makeBlock(BLOCK_H2, line.substring(3), '', ''));
        continue;
      }
      if (line.startsWith('# ')) {
        // 详情页顶部已经用配置里的 title 展示，正文首个 H1 不再重复
        if (blocks.length === 0) {
          continue;
        }
        blocks.push(this.makeBlock(BLOCK_H1, line.substring(2), '', ''));
        continue;
      }
      if (line.startsWith('> ')) {
        blocks.push(this.makeBlock(BLOCK_QUOTE, line.substring(2), '', ''));
        continue;
      }
      if (line.startsWith('- ')) {
        blocks.push(this.makeBlock(BLOCK_BULLET, line.substring(2), '', ''));
        continue;
      }
      if (line.startsWith('|')) {
        const cells: string[] = this.splitTableRow(line);
        if (cells.length === 0 || this.isSeparatorRow(cells)) {
          continue;
        }
        const label: string = cells[0];
        const value: string = cells.length > 1 ? cells.slice(1).join('  ') : '';
        blocks.push(this.makeBlock(BLOCK_TABLE, '', label, value));
        continue;
      }
      blocks.push(this.makeBlock(BLOCK_PARAGRAPH, line, '', ''));
    }
    return blocks;
  }

  /** 拆表格行：去掉首尾的竖线，逐格 trim，丢弃空单元格 */
  private splitTableRow(line: string): string[] {
    const cells: string[] = [];
    const parts: string[] = line.split('|');
    for (const part of parts) {
      const cell: string = part.trim();
      if (cell.length > 0) {
        cells.push(cell);
      }
    }
    return cells;
  }

  /** 跳过 Markdown 风格的表格分隔行（|---|:--:|），正文里写了也不会渲染成一行横杠 */
  private isSeparatorRow(cells: string[]): boolean {
    for (const cell of cells) {
      if (!/^:?-{2,}:?$/.test(cell)) {
        return false;
      }
    }
    return true;
  }

  private makeBlock(type: number, text: string, label: string, value: string): ArticleBlock {
    return { type: type, text: text, tableLabel: label, tableValue: value };
  }

  /* ============================ 路由与交互 ============================ */

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      // 页面栈为空时忽略
    }
  }

  /** 标签配色与列表页保持一致 */
  private tagColor(tag: string): string {
    if (tag === '核算方法') {
      return '#1565C0';
    }
    if (tag === '机制说明') {
      return '#EF6C00';
    }
    return COLOR_PRIMARY;
  }

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

  /** 按区块类型渲染正文 */
  @Builder
  BlockView(block: ArticleBlock) {
    if (block.type === BLOCK_H2) {
      Row() {
        Text('')
          .width(3)
          .height(16)
          .backgroundColor(COLOR_PRIMARY)
          .borderRadius(2)
        Text(block.text)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TITLE)
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 24, bottom: 10 })
    } else if (block.type === BLOCK_H3) {
      Text(block.text)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TITLE)
        .width('100%')
        .margin({ top: 16, bottom: 6 })
    } else if (block.type === BLOCK_H1) {
      Text(block.text)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TITLE)
        .width('100%')
        .margin({ top: 20, bottom: 8 })
    } else if (block.type === BLOCK_BULLET) {
      Row() {
        Text('•')
          .fontSize(14)
          .fontColor(COLOR_PRIMARY)
          .width(14)
        Text(block.text)
          .fontSize(14)
          .lineHeight(23)
          .fontColor(COLOR_BODY)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ bottom: 7 })
    } else if (block.type === BLOCK_QUOTE) {
      Column() {
        Text(block.text)
          .fontSize(13)
          .lineHeight(21)
          .fontColor('#455A64')
          .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F1F8E9')
      .border({ width: { left: 3 }, color: COLOR_PRIMARY })
      .borderRadius(4)
      .margin({ top: 10, bottom: 14 })
    } else if (block.type === BLOCK_TABLE) {
      Row() {
        Text(block.tableLabel)
          .fontSize(13)
          .fontColor(COLOR_TEXT)
          .width('40%')
          .lineHeight(20)
        Text(block.tableValue)
          .fontSize(13)
          .fontColor(COLOR_TITLE)
          .layoutWeight(1)
          .lineHeight(20)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 10, bottom: 10 })
      .border({ width: { bottom: 1 }, color: '#F0F0F0' })
    } else if (block.type === BLOCK_DIVIDER) {
      Divider()
        .color('#E8EAED')
        .margin({ top: 18, bottom: 18 })
    } else {
      Text(block.text)
        .fontSize(14)
        .lineHeight(25)
        .fontColor(COLOR_BODY)
        .width('100%')
        .margin({ bottom: 12 })
    }
  }

  build() {
    Column() {
      // 顶部导航
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(COLOR_PRIMARY)
          .onClick(() => {
            this.goBack();
          })
        Blank()
        Text('科普详情')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TITLE)
        Blank()
        Text('     ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

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
          Text('文章加载失败')
            .fontSize(15)
            .fontColor(COLOR_TEXT)
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(COLOR_HINT)
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
          Row() {
            Button('重新加载')
              .height(36)
              .fontSize(13)
              .borderRadius(18)
              .backgroundColor(COLOR_PRIMARY)
              .onClick(() => {
                this.loadArticle();
              })
            Button('返回')
              .height(36)
              .fontSize(13)
              .borderRadius(18)
              .backgroundColor('#E0E0E0')
              .fontColor(COLOR_TEXT)
              .margin({ left: 12 })
              .onClick(() => {
                this.goBack();
              })
          }
          .margin({ top: 16 })
        }
        .width('100%')
        .padding(32)
        .backgroundColor(COLOR_CARD)
        .borderRadius(16)
        .margin({ top: 16 })
      } else {
        Scroll() {
          Column() {
            // 白卡承载正文，阅读时与页面底色区分开
            Column() {
              Row() {
                Text(this.tag)
                  .fontSize(11)
                  .fontColor(this.tagColor(this.tag))
                  .backgroundColor(this.tagBg(this.tag))
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(10)
              }
              .width('100%')

              Text(this.title)
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_TITLE)
                .lineHeight(31)
                .width('100%')
                .margin({ top: 12 })

              Divider()
                .color('#F0F0F0')
                .margin({ top: 16, bottom: 4 })

              ForEach(this.blocks, (block: ArticleBlock, index: number) => {
                this.BlockView(block)
              }, (block: ArticleBlock, index: number) => String(index) + '_' + block.type)

              Text('— 本文完 —')
                .fontSize(12)
                .fontColor(COLOR_HINT)
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 26 })

              Text('内容用于低碳科普与积分激励，不作为碳排放核算或碳交易的依据。')
                .fontSize(11)
                .lineHeight(17)
                .fontColor(COLOR_HINT)
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 10 })

              Button('返回列表')
                .width('100%')
                .height(44)
                .fontSize(15)
                .borderRadius(22)
                .backgroundColor(COLOR_PRIMARY)
                .margin({ top: 20 })
                .onClick(() => {
                  this.goBack();
                })
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 18, bottom: 22 })
            .backgroundColor(COLOR_CARD)
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 4, bottom: 24 })
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
