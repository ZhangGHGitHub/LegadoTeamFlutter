# R49 正文字符级选区技术调研与方案设计

- 任务：为 R49「正文实现字符级选区」做技术调研与方案设计（只读调研，本文件不随附任何代码改动）
- 日期：2026-11-28
- 参考版：kazusa 3.26.19（`D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`）
- 我方版本：flutter_legado 2.0.514+515，Flutter 3.44.8 / Dart 3.12.2
- 用户裁决：A 方案（对齐参考版，实现字符级选区 + 拖拽手柄）

---

## 一、结论摘要

**推荐方案：A3（自研命中测试 + 自绘选区 + 自绘手柄），不采用 Flutter 原生 SelectionArea/SelectableRegion 作为正文选区内核。**

一句话理由：正文是高敏感的分页渲染链，A3 完全不改任何一行的布局高度与测量路径（分页仍由 `ParagraphLayoutEngine` 单源决定），只在其上叠加"手势 + 几何查询 + 绘制"层；而 A1/A2 会把 `RawGestureDetector`（Tap + TapAndHorizontalDrag + LongPress）插进正文，与阅读器现有的点击分区、长按浮条、以及 `ReaderTurnView` 的**裸 Listener 翻页**机制正面冲突，且原生选区拿不到可靠的章节偏移范围用于书签/笔记/朗读。

- 预估工作量：**3.5 ~ 5 人日**（原登记 2~4 天偏乐观；多出的部分主要是手势门控与两套渲染模式回归）
- 置信度：**中（约 0.65）**。A3 的技术不确定性集中在手柄拖拽与翻页手势门控；渲染/测量本身不动，可回归性最好。
- 若强行走 A1：置信度约 0.2；A2 约 0.35；A4 不建议（两套行为双维护，收益为零）。

**重要结论（先说风险）**：A 方案本身可行，但"用 Flutter 原生选区一把梭"不可行。本项目此前已实证 `SelectionArea` 在阅读器手势栈下长按不触发（`CHANGELOG.md:3019`、`lib/src/widgets/reader/reader_text_content.dart:566-572`），当前翻页层虽已从 PageView 换成 turn 系统，但 turn 系统用的是**裸 Pointer Listener**（不走手势竞技场），原生选区即便能赢竞技场，拖手柄时仍会被翻页层同时消费。必须自研并显式门控翻页层。

---

## 二、现状结构图（文字版）

### 2.1 正文渲染链（分页模式）

```
ReaderScreen (lib/src/screens/reader_screen.dart)
  └ body: GestureDetector(onTapDown/onTapUp)            // 全局九宫格点击（:1346-1369）
       └ Stack
          └ ReaderPageView (lib/src/widgets/reader/reader_page_view.dart)
               └ _buildContent (:1198-1260)
                    ├ state.pageTurnMode == scroll ? _buildScrollContent (:2307-2449)
                    └ 否则 _buildTurnContent (:2249-2305)
                         └ ReaderTurnView (lib/src/widgets/reader/turn/reader_turn_view.dart)
                              ├ 裸 Listener（onPointerDown/Move/Up，:728-733）→ PageTurnController
                              ├ 隐藏快照栈（prev/cur/next + 章边界，:736-760，RepaintBoundary :684-701）
                              └ live page: buildPage(i)
                                   └ _buildTypographicPage (:2456-2535)
                                        └ ReaderTypographicPage (reader_text_content.dart:23-317)
                                             ├ 页眉/标题/页脚
                                             └ ClipRect (:223-244)
                                                  └ ReaderTextContent (:322-704)
                                                       └ LayoutBuilder (:396-407)
                                                            └ Column[ 段落 × N ]
                                                                 └ GestureDetector(onLongPressStart)  // 段落级长按（:590-604）
                                                                      └ (Row[Expanded(Column[行 × N]), 段评角标])
                                                                           └ 每行 SizedBox(height: line.height)（:524-544）
                                                                                └ Text / Text.rich（:501-522）
```

### 2.2 正文渲染链（滚动模式）

```
_buildScrollContent (:2307-2449)
  └ SingleChildScrollView (:2333)
       └ Column
            ├ 章节标题 Text（不可选中）
            └ for pageInfo in _paginatedPages: ReaderTextContent  // 仍是分页结果逐页渲染（:2379-2409）
            └ 兜底：ReaderParagraphs（未分页时，段落级长按 :804-813）
```

**关键事实**：滚动模式并没有独立的"整章 Text"渲染，它复用同一套分页结果，把每个 `PageInfo` 交给 `ReaderTextContent`。因此**只要把选区能力做进 `ReaderTextContent`，分页/滚动两模式天然同时覆盖**（单页/单 chunk 粒度）。

### 2.3 手势层

| 层 | 位置 | 机制 | 与选区的关系 |
|---|---|---|---|
| 阅读器全局点击（菜单/翻页分区） | `reader_screen.dart:1346-1369` | 祖先 `GestureDetector`（Tap） | 原生选区会抢走 Tap，导致点击菜单失效 |
| 正文段落长按 | `reader_text_content.dart:590-604`（分页）、`:804-813`（滚动兜底） | 段落 `GestureDetector`（LongPress） | 现为段落级入口，需改为字符级选区起点 |
| 翻页拖拽 | `reader_turn_view.dart:728-733` → `page_turn_controller.dart:84-163` | **裸 Listener + 手写位移判定**，不参与手势竞技场 | 选区手柄拖拽只要产生横向位移，翻页层同样会翻页 |
| 下滑书签 | `reader_turn_view.dart:388-397` | 同一 Listener 内纵向优先判定；`selectionActive: false` 硬编码 | 注释假设"选区是模态路由，手势到不了本层"，字符级选区打破该假设 |
| 滚动模式滚动 | `SingleChildScrollView`（`reader_page_view.dart:2333`） | 标准 Scrollable（手势竞技场） | 手柄纵向拖拽需赢过 Scrollable |

### 2.4 测量层

```
_paginateIfNeeded (reader_page_view.dart:831-1113)
  ├ 分页键：内容/章号/字号/行高/段距/字距/缩进/字重/斜体/对齐/字体/baseStyle/边距/页眉页脚/系统栏/双页/ZhLayout/悬挂/图片 revision (:880-905)
  ├ ParagraphConfig（baseStyle + textScaler 与渲染同参，:991-1017）
  └ ParagraphLayoutEngine.paginateChapter(availableWidth, availableHeight, firstPageHeight) (:1042-1049)
       ├ 整段 TextPainter.layout + getBoxesForSelection 逐字测宽（paragraph_layout_engine.dart:1423-1471）
       ├ 分行结果 LineInfo（words/width/height/startIndex/endIndex/chapterStartIndex/highlightSkip/chapterOffsets，:248-311）
       └ 分页切片保留段落全局 startIndex/endIndex（:659-778）
```

**渲染侧不使用任何 Text 的测量结果反推分页**：每行高度直接取 `line.height`（`reader_text_content.dart:524-544`）。因此"在 Text 之上叠加不改变布局尺寸的层"不会影响分页结果。

### 2.5 浮条/菜单层

| 组成 | 位置 | 现状 |
|---|---|---|
| 长按浮条 | `text_selection_panel.dart:803-899`（`ReaderSelectionToolbar.show`） | 全屏 OverlayEntry + **不透明点击屏障**（`:861-869`），点任意处收起 |
| 浮条动作 | `text_selection_panel.dart:1007-1064` → `selection_menu_actions.dart:31-210` | 复制/分享/浏览器/朗读/书签/笔记/词典/替换/编辑/搜正文，文本取自 show 时捕获的整段 |
| "更多"底部面板 | `text_selection_panel.dart:212-794`（`TextSelectionPanel.show` :235-254） | 面板内再放一个 `SelectableText`（`:392-415`）做原生精细选区；默认操作整段 |
| 锚点布局 | `text_selection_panel.dart:1099-1135` | 以按压点 `anchor` 为中心 `dx-150 / dy-64` 并 clamp |

**关键事实**：现有浮条的点击屏障会让"页内手柄"完全不可拖——浮条一旦弹出，全屏屏障吃掉所有触摸。字符级选区必须把浮条改成非模态（`TapRegion` 外部点击语义），否则手柄交互无法成立。

---

## 三、承重约束实证（逐条核实）

### 问题 1：正文渲染链完整结构

结论：**是"排版引擎分行结果 + 逐行 Text"渲染，不是单个 SelectableText/TextPainter 自绘整页**。证据：

- 分页页由 `ReaderTypographicPage` → `ReaderTextContent` 组成（`reader_text_content.dart:225-244`、`:322-704`）。
- 每个段落遍历 `para.lines`，每个视觉行一个 `Text`/`Text.rich`，外层 `SizedBox(height: line.height)`，两端对齐通过额外 `letterSpacing` 注入（`reader_text_content.dart:433-469`、`:501-522`、`:524-544`）。
- 段首标点悬挂行额外包 `OverflowBox + Transform.translate`（`:533-542`）。
- 行内图片用 `WidgetSpan` 替换占位符（`:620-677`）。
- 翻页层为移植重构版 turn 系统（`reader_page_view.dart:1212-1221`、`reader_turn_view.dart:20-40`），不是 PageView。
- 滚动模式复用 `ReaderTextContent` 逐页渲染（`reader_page_view.dart:2379-2409`），仅未分页时兜底 `ReaderParagraphs`（`reader_text_content.dart:707-842`）。
- 相邻章预览页 `selectText: false`（`reader_page_view.dart:2197-2236`），不受选区影响。

### 问题 2：布局是怎么做的？`SelectableText` 能否用上？

结论：**布局/分页完全由自研 `ParagraphLayoutEngine` 决定；正文 Text 只负责画，不负责断行与页高。`SelectableText` 在正文没有位置，`SelectionArea` 理论上可包裹多行 Text，但会引入手势与范围提取问题。**

证据：

- 分页入口 `ParagraphLayoutEngine.paginateChapter`（`reader_page_view.dart:1042-1049`），测量是整段一次 `TextPainter.layout` + 逐字 `getBoxesForSelection`（`paragraph_layout_engine.dart:1423-1471`），与渲染同源同参（`baseStyle` + `textScaler`，`:1429-1443`；配置注入 `reader_page_view.dart:991-1017`）。
- 每行是 `maxLines: 1` 的独立 Text，`overflow: clip`（`reader_text_content.dart:501-522`）；行高由引擎给定（`:524-544`）。
- `SelectableText` 内部是 `RenderEditable`（Flutter SDK `material/selectable_text.dart`，`TextEditingController`/`selectionControls`/`onSelectionChanged`），它会自己测量、自己滚动，且**每个实例只能在自己的文本内选择**；放在逐行 Text 的位置上会导致"一行一个选区"，不能跨行。用它替换正文等于重写渲染层并改变测量路径，风险最高。
- `SelectionArea`/`SelectableRegion` 走的是 `SelectionContainer` + 各 `RenderParagraph` 注册，可以在多个 Text 之间做跨 widget 选区（SDK `widgets/selection_container.dart:10-30`），**不改变布局尺寸**；但见问题 4 的手势与范围问题。

### 问题 3：翻页位移/动画是否依赖"每段高度固定"或"测量缓存"？引入选区会不会破坏？

结论：**翻页动画依赖的是"页面内容稳定 + RepaintBoundary 位图快照"，不直接依赖段落高度；选区只要不改变任何 SizedBox 高度、不触发重分页，就不会破坏翻页。真正的风险是"选区绘层被拍进快照"与"手柄拖拽被裸 Listener 当成翻页"。**

证据：

- 翻页页面由 `buildPage(i)` 渲染，快照用 `RepaintBoundary.toImage` 抓图（`reader_turn_view.dart:684-701`、`turn/page_snapshot_cache.dart:25-86`），暖快照在布局/页号/模式/预览变化时触发（`reader_turn_view.dart:232-257`），不是每帧重抓。
- 翻页位移全部由 `PageTurnController` 的触摸坐标驱动（`page_turn_controller.dart:84-163`），与文本高度无关。
- 章边界承接态依赖预载页与位图作废逻辑（`reader_turn_view.dart:134-149`、`:196-214`、`:761-768`），与选区无交集。
- 若选区绘层留在页面内并被抓进 `cur/prev/next` 位图，翻页动画会出现"残影灰块 + 手柄"。对策：**翻页手势开始前清选区**（见问题 5 与设计 §5.5），并在选区激活期间跳过暖快照刷新。
- 选区不改变布局：推荐方案只在 Text 外层加 `Stack/CustomPaint/GestureDetector`，不替换 Text，不动 `SizedBox(height: line.height)`，因此分页命中 `_paginateIfNeeded` 的键不变（`:880-905`），不会触发重分页。

### 问题 4：`TextSelectionPanel.show(text:)` 与 10 个动作如何消费 text？

结论：**动作层已经"文本参数化"，可复用；需要扩展的是"选区起点/终点"和浮条非模态化，而不是重写 10 个动作。**

证据：

- `TextSelectionPanel.show(context, {text, chapterPos, chapterIndex, chapterTitle})`（`text_selection_panel.dart:235-254`）；面板内部 `_selectedText` 优先取原生选区、否则整段（`:291-294`）。
- 面板动作分发 `_panelAction`（`:569-634`）；浮条动作分发 `_actionFor`（`:1007-1064`），两者都调用 `selection_menu_actions.dart`：
  - 复制/分享/浏览器/词典/替换/搜正文/编辑：直接消费 `text`（`selection_menu_actions.dart:31-54`、`:56-81`、`:167-210`）。
  - 朗读：真正消费的是 `chapterPos`（起点）与 `paragraphText`（回退定位），`selectedText` 仅用于展示（`selection_menu_actions.dart:83-111`；`audio_notifier.dart:723-810` 按 `startChapterPos` 映射段落）。
  - 书签：消费 `selectedText` + `chapterPos`（`selection_menu_actions.dart:113-165`）。
  - 笔记：`openMarkingForSelection` 消费 `paragraphText/chapterPos/selectedText/fineSelection/selectionStart`，内部用 `chapterOffsetOfSelection` 换算（`text_selection_panel.dart:130-206`、`:49-70`）。
- 高亮 JSON 的 `chapterPosEnd` 目前用 `chapterPos + selectedText.length`（`text_selection_panel.dart:79-108`，`:97`）；字符级选区跨段/含图片占位符时该推导会错，需改为显式终点。

### 问题 5：是否已有滚动/分页两套渲染路径？

结论：**是两套外层路径，但共用 `ReaderTextContent` 正文渲染单元。选区做在 `ReaderTextContent` 内即可同时覆盖；差异只在手势冲突（滚动模式要赢 Scrollable，分页模式要门控裸 Listener）。**

证据：

- 模式分支：`reader_page_view.dart:1217-1221`。
- 分页：`_buildTurnContent` → `ReaderTurnView`（`:2249-2305`）→ `_buildTypographicPage`（`:2456-2535`）→ `ReaderTypographicPage` → `ReaderTextContent`。
- 滚动：`_buildScrollContent`（`:2307-2449`）→ `SingleChildScrollView` → `ReaderTextContent`（`:2379-2409`）。
- 未分页兜底：`ReaderParagraphs`（`:2410-2431`，组件在 `reader_text_content.dart:707-842`），保持段落级即可，属边界路径。
- 相邻章预览：`selectText: false`（`:2227`），不受影响。
- 双页模式：两列各自一个 `ReaderTypographicPage`（`:2560-2576`）；选区按列独立，不跨栏（与参考分页模式单列语义一致，登记为设计边界）。

### 补充：现有"选区长按浮条"的既有结论

- 项目在 2.0.214 已裁决"长按点 Overlay 浮条"，并记录 `SelectionArea` 在旧 PageView 手势栈下长按不触发（`CHANGELOG.md:3019`、`reader_text_content.dart:566-572`、`text_selection_panel.dart:798-802`）。
- 当前 turn 系统替换 PageView 后，该结论**需要重新实测**；但即便长按能触发，裸 Listener 的翻页冲突仍在（见 §4 对比表）。

---

## 四、方案对比表

| 维度 | A1 `SelectableText` / `SelectionArea` 包裹 | A2 `SelectableRegion` + 自定义 `contextMenuBuilder` | A3 自研命中 + 自绘选区 + 手柄 | A4 混合（分页自研、滚动原生） |
|---|---|---|---|---|
| 能否字符级 | 手柄可到字符；长按首选取词；`SelectableText` 逐行则不能跨行 | 手柄 `TextGranularity.character`（SDK `selectable_region.dart:1408-1409`）；长按拖选是**词粒度**（`:1014-1018`）；可跨 widget | 是；可按 RenderParagraph 原生位置取任意字符（等价参考 `elementAt` + `chapterPosition`） | 分页可字符级；滚动模式行为不一致 |
| 是否改测量路径 | `SelectableText` 会引入 `RenderEditable`，改变行测量/滚动；`SelectionArea` 不改尺寸但增加选区注册开销 | 同左（不改分页测量） | **完全不改**：Text/SizedBox 原样，分页键不变 | 分页不改；滚动用原生 |
| 与翻页手势冲突风险 | **高**：裸 Listener 不参与竞技场，拖手柄横向位移仍会翻页；Tap 会被 Region 抢走导致点击菜单失效（SDK `selectable_region.dart:929-955`、`:1940-1979`） | **高**：同上；且长按拖选词粒度、手柄浮层在根 Overlay | **中**：需显式把"选区激活"传给 `ReaderTurnView` 并在裸 Listener 里短路（改动点明确） | 高（两套冲突面都要处理） |
| 精确章节范围（书签/笔记/朗读） | `onSelectionChanged` 只给 `SelectedContent` 文本；精确偏移要靠 `SelectionListener`，跨 widget 时 `SelectedContentRange` 语义需实测 | 同左 + 自定义 | 直接由 `LineInfo.chapterStartIndex/highlightSkip/chapterOffsets` 反算，确定性强 | 分页确定、滚动不确定 |
| 手柄形态对齐参考（竖线 + 空心圆，位于行底） | Material/Cupertino 默认手柄，需自定义 `TextSelectionControls` 才接近；`SelectableText` 无法跨行 | 可自定义 `selectionControls`，但定位/显隐受 `SelectionOverlay` 约束 | **可 1:1 复刻**（半径 7dp、描边 2dp、行底圆心、28dp 热区） | 分页 1:1、滚动原生 |
| 浮条非模态 | `contextMenuBuilder` 由 `ContextMenuController` 弹出，可非模态 | 同左 | 改造 `ReaderSelectionToolbar` 为 `TapRegion` + 可更新控制器 | 同左 |
| 工作量 | 3~5 人日（且需重做点击分区） | 3~4 人日（+范围提取实验） | **3.5~5 人日** | 5 人日+ |
| 风险等级 | 高 | 高 | **中** | 高 |
| 结论 | 不推荐 | 不推荐（可作备选） | **推荐** | 不推荐 |

补充说明：

- A1 的 `SelectableText` 变体在正文没有可用位置：正文一行一个 Text，`SelectableText` 无法跨行选区；替换为整页 `SelectableText` 会改变断行/行高与分页测量，直接违背"测量同源同参"。
- A2 理论上能做，但需要同时解决：点击分区重接、裸 Listener 门控、跨 widget 精确范围提取、手柄样式定制、滚动模式纵向拖手柄与 Scrollable 竞争。投入不小于 A3，且每项都有不确定性，因此不推荐。
- A4 没有收益：`ReaderTextContent` 是共用单元，分页/滚动拆两套只会增加测试矩阵与行为差异。

---

## 五、推荐方案详细设计（A3）

### 5.1 总体原则

1. **零布局改动**：不替换 `Text`/`Text.rich`，不改 `SizedBox(height: line.height)`，不改 `reader_page_view` 的分页键。选区层只做三件事：命中测试、几何查询、绘制/手柄。
2. **零测量改动**：不新增/修改 `ParagraphLayoutEngine`；选区坐标全部从既有 `LineInfo` 映射与既有 `RenderParagraph` 读取。
3. **状态本地化**：选区是瞬时 UI 状态，不进 Riverpod、不落库、不进快照。
4. **翻页优先安全**：选区激活时翻页层必须短路；翻页开始前必须清选区，保证快照干净。

### 5.2 数据结构

新增 `lib/src/widgets/reader/reader_text_selection.dart`（建议文件名，实施时可调整）：

```dart
/// 一页/一个 ReaderTextContent 内的选区（章节 UTF-16 偏移，半开区间）
@immutable
class ReaderTextSelection {
  final int anchor;   // 长按起点（章节偏移）
  final int focus;    // 当前拖动端点（章节偏移）
  final bool isTitle; // 预留：当前正文不选标题，恒 false
  int get start => anchor <= focus ? anchor : focus;
  int get endInclusive => anchor <= focus ? focus : anchor;
  // 半开区间 [start, endExclusive)
  int get endExclusive => endInclusive + 1;
  bool get isCollapsed => anchor == focus;
}
```

- 坐标统一用**章节 UTF-16 偏移**（与参考版 `ReaderSelection.anchor/focus` 一致，与高亮/书签/笔记/朗读链路天然对齐）。
- 内部不保存"段内偏移/行内偏移"；这些在每次绘制/命中时按行现算，避免与重排/切片失配。

新增几何辅助（同文件或 `reader_text_selection_geometry.dart`）：

```dart
/// 一行在渲染文本坐标（含缩进）与章节坐标之间的映射
class ReaderLineSelectionMap {
  final LineInfo line;
  final String text;                 // line.words.join('')
  int localToChapter(int local);     // 处理 highlightSkip / chapterOffsets / clamp
  int chapterToLocal(int chapter);   // 反向，返回未命中时 -1
  (int, int)? localRangeFor(int startChapter, int endExclusiveChapter);
}
```

映射规则（与高亮渲染完全同口径，`highlight_span_builder.dart:1-140`）：

- 纯文本行：`lineBodyStart = line.chapterStartIndex`，`skip = line.highlightSkip`；
  - 章节 → 行内：`local = chapter - line.chapterStartIndex + skip`，clamp 到 `[skip, text.length]`。
  - 行内 → 章节：`chapter = line.chapterStartIndex + (local - skip)`；`local < skip` 视为缩进区，落到段首。
- 含行内图片行：优先用 `line.chapterOffsets`（`paragraph_layout_engine.dart:278-304`）；`-1` 表示缩进/占位符，映射到最近的非空偏移。占位符在复制文本中剔除（`readerImagePlaceholderChar`）。
- 行边界：半开区间，`local == text.length` 归下一行行首；页内最后一行末端归段落 `endIndex`。

### 5.3 选区状态放哪

- 放在 **`ReaderTextContent` 自己的 `State`**（把该 Widget 从 `StatelessWidget` 改为 `StatefulWidget`，构造参数保持兼容）。
- 理由：
  - 分页/滚动两模式共用该组件，天然覆盖；
  - 每个页面实例（live / boundary / 相邻章预览 / 滚动分页）各自独立，不会把隐藏快照页的选区混进来；
  - 不引入 provider 生命周期与持久化问题。
- 生命周期：
  - `didUpdateWidget`：`pageInfo`、`chapterIndex`、章标题、字号/行高/字距/字重/字体/对齐任一变化 → 清选区（防止偏移失效）。
  - `dispose`：置空并通知父级"选区失活"。
  - 页面切换：分页模式 live 子树的 `ValueKey('live-$pageIndex')` 变化会重建 State，自动清空；仍建议父级在 `onPageChanged` 显式 `selectionActive=false` 兜底。滚动模式给 `ReaderTextContent` 加 `ValueKey('scroll-${chapterIndex}-${pageIndex}')`。
- 父级联动：
  - `ReaderPageViewState` 持有一个 `ValueNotifier<bool> _selectionActive`；
  - `ReaderTextContent` 新增 `ValueChanged<bool>? onSelectionActiveChanged`；开始/清除选区时调用；
  - `ReaderTurnView` 新增 `ValueListenable<bool> selectionActive`（默认恒 false），在 `_onPointerDown/_onPointerMove/_onPointerUp/_pullDrag` 入口读取，激活时直接 return；
  - `ReaderScreen._handleTap` 通过 `_pageViewKey.currentState?.hasActiveSelection` 在 tapDown 时记录，若为 true 则本次 tap 不做九宫格/菜单动作（对齐参考 `suppressTap` 语义）。

### 5.4 命中测试与几何查询（不改渲染的关键）

**核心技巧：不复制 TextPainter，而是直接向已渲染的 `RenderParagraph` 要几何。**

- 每行 Text 外层包一个轻量 `Builder`（或 `_LineProbe`），在 build 时把该行的 `BuildContext` 记到 State 持有的 `_LineHandle`：
  ```dart
  class _LineHandle {
    BuildContext? context;          // 行 Text 的 context
    final int paraIndex, lineIndex;
    RenderParagraph? get paragraph =>
        context?.mounted == true ? context!.findRenderObject() as RenderParagraph? : null;
  }
  ```
  - 不使用 `GlobalKey`：`buildPage(i)` 会同时构建隐藏边界页与 live 页（`reader_turn_view.dart:703-711`、`:736-760`），同一页会被构建两份，GlobalKey 会重复；State 内持有的 context 天然按实例隔离。
  - context 在 build 中赋值属于只写探测字段，不触发重建；越界/失活时 `mounted` 兜底。
- 命中：
  1. 长按/拖动给的是 `globalPosition`；
  2. 先按"行矩形"找目标行：对当前页每行 `RenderParagraph.localToGlobal(Offset.zero)` + `size`，命中 y 区间即目标；y 落在行间空隙时按最近行吸附（参考 `ReaderSelectionPolicy.snapToText`，`ReaderSelection.kt:176-199`）；
  3. `paragraph.getPositionForOffset(paragraph.globalToLocal(globalPos))` → `TextPosition`（SDK `rendering/paragraph.dart:1110-1114`）；
  4. `ReaderLineSelectionMap.localToChapter(position.offset)` → 章节偏移。
- 首选取词：
  - `paragraph.getWordBoundary(position)`（SDK `rendering/paragraph.dart:1125`，底层 ICU UAX#29，与参考 `BreakIterator.getWordInstance` 同源）→ 行内 `[ws, we)`；
  - 两端换成章节偏移，`anchor = wordStart`，`focus = max(wordEnd-1, wordStart)`（半开转闭区间）；
  - 词跨视觉行时按当前行截断（参考是整段分词；登记为 P3 差异）。
- 选区高亮矩形：
  - 对每个相交行：`ReaderLineSelectionMap.localRangeFor(start, endExclusive)`；
  - `paragraph.getBoxesForSelection(TextSelection(baseOffset: ls, extentOffset: le), boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle)`（SDK `rendering/paragraph.dart:1093-1107`）；
  - 用 `paragraph.localToGlobal(box.topLeft, ancestor: pageRenderBox)` 转到 `ReaderTextContent` 根坐标；
  - `pageRenderBox = context.findRenderObject()`（State 自己的根 Stack），无需 GlobalKey。
- 选区文本：
  - 按段落/行顺序取 `text.substring(ls, le)`，剔除 `readerImagePlaceholderChar`；
  - 跨段落补 `'\n'`（章节正文分隔符语义，与参考 `selectedText` 一致，`ReaderSelection.kt:110-141`）；
  - 章节终点显式取 `selection.endExclusive`，不再用 `text.length` 推算。

**为什么不复制 TextPainter**：行内图片是 `WidgetSpan`，其实际宽度由 `ReaderInlineImageWidget` 决定（`reader_text_content.dart:643-656`、`reader_inline_image.dart:508-521`），与占位符字宽只在大多数情况下相等；复制 TextPainter 会在含图行产生亚像素/宽度偏差。直接问真实 `RenderParagraph` 可保证"看到什么就选什么"，也让两端对齐额外字距、悬挂 `Transform`（`:533-542`）全部自动一致。

### 5.5 选区绘制与手柄

**绘制层**（不改变布局）：

```
ReaderTextContent root
  └ Stack
       ├ Column[段落...]                      // 原样，不动
       ├ 每段内部（在 Row 的 Expanded 内）：
       │    Stack[ IgnorePointer(CustomPaint(选区灰块)), paragraphBody ]
       ├ Positioned(手柄 start)               // 仅选区激活时挂载
       └ Positioned(手柄 end)
```

- 灰块：`Theme.of(context).colorScheme.primary.withValues(alpha: 0.28)`（参考 `ReadBookRouteScreen.kt:713`）；画在文字下方（`CustomPaint` 在 Text 之前），与参考一致。绘制回调用 `ValueNotifier<ReaderTextSelection?>` 驱动 `repaint`，选区变化时不重建文字树。
- 手柄形态（对齐参考 `ReaderCanvasSurface.kt:1783-1830`）：
  - 每个手柄 = 行内竖线（从行 top 到行 bottom，宽 2dp）+ 行底下方空心圆（半径 7dp，描边 2dp，圆心 = `(x, lineBottom + radius)`）；
  - 起点手柄 x = 首个选中行首个 box 的 `left`；终点手柄 x = 末个选中行末个 box 的 `right`；
  - 颜色 = 选区色（primary 全不透明）；白色阴影可选；
  - 拖动中的手柄圆淡出（参考 90ms/140ms），另一只手柄保留。
- 手柄命中：热区半径 28dp 的胶囊（竖线 + 圆），实现为两个约 48×48 的透明 `Positioned` + `GestureDetector(onPanStart/Update/End)`；不覆盖整页，因此不影响正文点击。
- 手柄拖动：
  - `onPanStart`：记录端点、隐藏该手柄圆、**收起浮条**（参考在抓取手柄时 `dismissSelectionMenu`）；
  - `onPanUpdate`：`cursorY = global.dy - radius`（参考语义：手指在圆上，指针位置减半径回到行底，`ReaderCanvasSurface.kt:1176-1180`）→ 吸附最近行 → `global.dx` 映射字符 → 更新 `focus`（起点手柄则更新 `anchor` 方向语义，内部按视觉端点区分）；
  - 越界（拖到正文外）：分页模式不翻页，保持端点；滚动模式不做边缘自动滚动（登记 P3；参考有边缘自动扩展，`selectable_region.dart` 的边缘更新逻辑不适用于自研路径）；
  - `onPanEnd`：按新选区重新弹出浮条（参考 `ReaderCanvasSurface.kt:1380-1388`）。
- 长按拖选（不抓手柄）：
  - `onLongPressStart`：起选（词级）→ 立即显示手柄；通知父级 `selectionActive=true`；`selectVibrator` 时 haptic；
  - `onLongPressMoveUpdate`：累计位移 > `kTouchSlop` 后进入字符级扩展（参考另有 `selectionDragSlop`，最小 1px，`ReaderGestureSettingsPolicy.kt:16-19`）；每次扩展可选 haptic（节流 60ms，参考 TextHandleMove）；
  - `onLongPressEnd`：显示浮条（参考在 release 时 show）；
  - `onLongPressCancel`：若尚未形成非折叠选区则清空。
- 清除：
  - 点击空白/任意非手柄位置：根 `Listener.onPointerDown` 命中判定（是否落在手柄热区）→ 非手柄则清选区并收起浮条；不清则保留给手柄；
  - 翻页开始/页面变化/进面板/执行动作：清；
  - `selectText == false`：不挂长按与手柄。

### 5.6 与 `TextSelectionPanel` / `ReaderSelectionToolbar` 的接口改动

目标：**旧调用保持兼容，新增字符级选区入口**。

1. `ReaderSelectionToolbar.show` 扩展（`text_selection_panel.dart:830-899`）：
   - 新增可选参数：
     - `String? selectedText`：精确选区文本；
     - `int? selectionStartChapterPos`：选区起点（章节偏移）；
     - `String? paragraphText` + `int? paragraphChapterPos`：仅"笔记"动作需要；
     - `Rect? selectionBounds`：浮条锚点（首行 box 与末行 box 的并集），用于替代 `anchor` 的粗定位；
     - `bool modalBarrier = true`：字符级路径传 `false`。
   - 返回类型从 `void` 改为一个轻量控制器（`ReaderSelectionToolbarHandle`，含 `dismiss()` / `update(...)`），旧调用可忽略返回值。
   - `modalBarrier == false` 时不再插 `Positioned.fill` 屏障（`:861-869`），改用 `TapRegion(groupId, onTapOutside: dismiss)`，保证手柄可拖、外部点击仍能收起。
   - 布局代理（`:1099-1135`）增加"选区矩形优先"分支：优先放在选区上方（底边 = 选区顶边 - 8dp），放不下放下方（顶边 = 选区底边 + 手柄半径 + 8dp），水平按选区中心 clamp。对齐参考 `TextActionSelectionMenu.kt:660-700` 的"上有空间放上、否则放下"。
   - 动作取文本：字符级路径固定用 `selectedText`，`chapterPos` 固定用 `selectionStartChapterPos`；朗读/书签语义不变（动作 helper 已按参数消费，见 §3 问题 4）。
2. "笔记"动作：
   - 现有 `openMarkingForSelection`（`text_selection_panel.dart:130-206`）保留；
   - 新增可选 `int? absoluteChapterPos`：提供时跳过 `chapterOffsetOfSelection`（`:160-166`），直接用绝对起点。字符级路径传 `absoluteChapterPos = selectionStartChapterPos`，同时传 `selectedText` 原文（保留内部空白语义）。
   - 顺带修复"跨页长段落后续页 chapterPos 基线偏差"（Active Plan 已登记），因为字符级路径不再依赖 `paragraphText.indexOf`。
3. 底部面板 `TextSelectionPanel.show`（`:235-254`）：
   - 新增 `String? initialSelectedText`、`int? initialSelectionStartInParagraph`、`int? initialSelectionEndInParagraph`；
   - State 初始化时把它们填入 `_userSelected` / `_userSelectionStart`（`:260-265`），面板打开即按字符级选区执行动作；
   - `SelectableText` 仍在面板内做原生精细调整（它只能改页内选区的"副本"，用于面板动作；不改页面选区），这是既有能力，保留；
   - 高亮保存改用显式 `chapterPosEnd`（`buildBookHighlightJson` 增加 `int? chapterPosEnd`，默认仍由 `selectedText.length` 推导，旧调用不变）。
4. 触觉：抽出公共 `maybeSelectionHaptic(ref, cause)`（参考面板内 `_maybeSelectHaptic`，`text_selection_panel.dart:277-288`），起选与手柄拖动共用，受 `selectVibrator` 控制。

### 5.7 两套渲染模式覆盖

| 场景 | 分页模式 | 滚动模式 |
|---|---|---|
| 正文单元 | `ReaderTextContent`（每页一个） | `ReaderTextContent`（每分页结果一个，堆叠） |
| 选区范围 | 当前页内（与参考分页一致） | 单个 chunk 内；跨 chunk/跨章不自动扩展（登记 P3，参考滚动模式可跨到下一章首页） |
| 手柄拖拽 vs 滚动 | 无 Scrollable；靠 `selectionActive` 门控 `ReaderTurnView` 裸 Listener | 手柄 `GestureDetector` 为 Scrollable 子节点，拖动时赢竞技场；根 `Listener` 不消费，滚动正常 |
| 翻页/滚动开始 | 清选区 + 短路翻页 | 清选区（down 非手柄时），滚动继续 |
| 兜底 `ReaderParagraphs` | 不涉及 | 保持段落级（`reader_text_content.dart:804-813`），不改 |
| 双页 | 每列独立选区，不跨栏 | 不涉及 |

### 5.8 明确的边界与不做项

- 不选章节标题（参考支持标题选区 `anchorIsTitle`；我方标题在 `ReaderTextContent` 之外，登记 P3）。
- 不支持跨页/跨章拖选（滚动模式跨 chunk 不做；参考滚动模式支持，登记 P3）。
- 不做选区放大镜（参考有 magnifier；Flutter 自研可后续接 `RawMagnifier`，登记 P3）。
- 不做长按 600ms 定制（保留 `GestureDetector` 的 500ms；参考为 600ms，登记 P3）。
- 不做图片元素的选区高亮（复制文本剔除图片；含图行的灰块可能覆盖占位宽度，登记 P3）。

---

## 六、参考版行为对照

| 维度 | 参考版 kazusa 3.26.19 | 我方现状 2.0.514 | A3 目标 |
|---|---|---|---|
| 选区粒度 | **字符/cluster 级**：布局为每个 cluster 生成 `ReaderElement.Text`，带 `bounds` + `chapterPosition`（`ReaderPaginator.kt:592-620`）；选区端点就是章节 UTF-16 偏移（`ReaderSelection.kt:25-57`） | 段落级：`ReaderTextContent` 长按把整段 `paraText` 交给面板（`reader_text_content.dart:550-604`）；滚动兜底同（`:804-813`） | 字符级，端点用章节偏移 |
| 长按首选取 | `startWord`：ICU `BreakIterator` 按词取整词（`ReaderSelection.kt:201-250`） | 整段 | 词级起选（`RenderParagraph.getWordBoundary`），手柄可扩到任意字符 |
| 长按拖选 | 过阈值后按 `elementAt` **字符级**扩展（`ReaderCanvasSurface.kt:940-1010`、`ReaderSelection.kt:257-272`） | 无 | 过 `kTouchSlop` 后字符级扩展 |
| 手柄数量/形态 | **2 个**：起点在首行 box 左端、终点在末行 box 右端；每只手柄 = 行高竖线（2dp）+ 行底空心圆（半径 7dp，描边 2dp）；颜色 = 选区色不透明；拖动中的手柄圆淡出（`ReaderCanvasSurface.kt:1783-1830`、`181-184`） | 仅底部面板里的 `SelectableText` 有原生手柄；正文无手柄 | 2 个 pin 手柄，几何/颜色对齐参考 |
| 手柄热区 | 28dp 半径，竖线+圆视作同一胶囊（`ReaderCanvasSurface.kt:1022-1058`） | 无 | 28dp 胶囊热区 |
| 选区颜色 | `colorScheme.primary.copy(alpha=0.28f)`（`ReadBookRouteScreen.kt:713`），画在文字下方 | 无页内选区 | `primary @ 28%`，画在文字下方 |
| 浮条出现时机 | 长按释放后（`ReaderCanvasSurface.kt:1380-1388`）；手柄拖动结束再弹；抓手柄/外部点击/执行动作/翻页时收起 | 长按即弹（`onLongPressStart` → `show`） | 长按释放弹；手柄拖动结束弹；抓手柄/外部点击/动作/翻页收起 |
| 浮条形态 | Compose `Popup`，`focusable=false`，`dismissOnClickOutside`（多行菜单时关闭）；锚点基于选区首行 top/末行 bottom，上有空间放上、否则放下（`TextActionSelectionMenu.kt:147-156`、`:660-700`） | 全屏不透明屏障 + 按压点锚定（`text_selection_panel.dart:861-869`、`:1099-1135`） | `TapRegion` 非模态 + 选区矩形锚定 |
| 动作集 | 14 项（复制/分享/浏览器/朗读/书签/笔记/词典/替换/编辑/AI 净化/AI 改写/搜正文/BGM 前/后），作用于选区（`ReadBookController.kt:2153-2175`、`:2003-2145`） | 10 项已实现（`selection_menu_actions.dart` + 笔记），作用于整段 | 10 项作用于选区 |
| 翻页联动 | 选区存在时翻页/书签下拉禁用；页面变化清选区（`ReaderCanvasSurface.kt:483-495`、`:1035-1044`） | 无选区状态，`_pullDrag` 硬编码 `selectionActive: false`（`reader_turn_view.dart:394-396`） | 选区激活短路裸 Listener；翻页前清选区 |
| 长按时长 | 600ms（`ReaderCanvasSurface.kt:1882`） | 平台默认 500ms | 500ms（登记 P3） |
| 触觉 | 起选 LongPress + 拖手柄 TextHandleMove，受 selectVibrator 控制（`ReaderCanvasSurface.kt:1108-1110`、`:1225`） | 浮条弹出时一次 selectionClick（`text_selection_panel.dart:838-845`） | 起选 + 手柄拖动，节流，受 selectVibrator 控制 |

---

## 七、实施步骤拆分（每步可独立验证）

| 步 | 内容 | 验证方式 | 风险 |
|---|---|---|---|
| 1 | 新增选区模型与映射纯函数（`ReaderLineSelectionMap`/`ReaderTextSelection`），覆盖缩进、悬挂、CRLF、行内图片、跨行、跨段 | 新增 `test/unit/reader_selection_mapping_test.dart`；`flutter test` 该文件 | 低 |
| 2 | `ReaderTextContent` 改 Stateful；行 context 捕获；长按命中选择 + 词级起选 + 灰块绘制（**先不做手柄/浮条**） | Widget 测试：长按后出现灰块 `CustomPaint`，选区文本正确；设备：长按出灰块、松手不翻页 | 中 |
| 3 | 手柄绘制 + 拖拽 + 吸附 + 触觉 | Widget 测试：按坐标拖起点/终点手柄，选区扩展正确；设备录像核对形态 | 中高（最易翻车之一） |
| 4 | 浮条非模态化（`TapRegion` + 控制器）+ 选区文本/起点/锚点接入 + 更多面板初值 + 笔记绝对偏移 | 既有 `reader_selection_toolbar_test`/`text_selection_menu_test` 全绿；新增"复制=选区文本"用例 | 中 |
| 5 | `selectionActive` 接线：`ReaderPageView` → `ReaderTurnView` 裸 Listener 短路；`_pullDrag` 用真实状态；`ReaderScreen` tapDown 抑制；页面切换/点击清选区 | `reader_swipe_bookmark_test` 全绿；新增"选区时横拖不翻页、清选区后可翻页"用例 | **最高（最易破坏翻页/书签）** |
| 6 | 滚动模式覆盖 + key/生命周期 + `selectText=false` + 全量回归 | `flutter analyze`、`flutter test`、`md3_acceptance_matrix_test`；设备双模式验收 | 中 |

**最容易翻车的一步：第 5 步**。原因：`ReaderTurnView` 的裸 Listener 不属于手势竞技场（`reader_turn_view.dart:728-733`、`page_turn_controller.dart:109-163`），门控只能靠显式状态；一旦"清选区"与"短路翻页"的时序错了，会出现三种用户可见故障：选区拖手柄时翻页、选区清除后首次拖拽不翻页、下滑书签在选区态误触发。第 3 步次之（手柄坐标系/行吸附）。

---

## 八、回归风险清单

### 8.1 受影响的现有测试（必须先跑）

| 测试文件 | 关注点 |
|---|---|
| `flutter_legado/test/widget/reader_selection_toolbar_test.dart` | 长按正文 → 浮条出现（复制/分享/更多） |
| `flutter_legado/test/widget/reader_wiring_1a_test.dart` | selectVibrator 起选振动恰好 1 次 |
| `flutter_legado/test/widget/text_selection_menu_test.dart` | 浮条/面板 10 项、笔记、折叠/隐藏、滚动兜底 `ReaderParagraphs`、高亮/书签/朗读快照章号 |
| `flutter_legado/test/unit/text_selection_offset_test.dart` | `chapterOffsetOfSelection` 缩进/重复词/空白选区 |
| `flutter_legado/test/unit/reader_pagination_overflow_test.dart` | 分页高度与渲染容器严格一致（选区层不得改高度） |
| `flutter_legado/test/widget/reader_swipe_bookmark_test.dart` | turn 裸 Listener 的下滑书签/横滑翻页/滚动模式 |
| `flutter_legado/test/widget/reader_tap_zones_dispatch_test.dart` | 九宫格点击分区不被选区/浮条吞掉 |
| `flutter_legado/test/unit/reading_flow_state_machine_hunt_test.dart` | turn 系统页状态机 |
| `flutter_legado/test/widget/md3_acceptance_matrix_test.dart` | reader 屏 3 调色板 × 亮暗无异常渲染（不依赖手势，但必须继续通过） |
| `flutter_legado/test/widget/reader_highlight_render_test.dart`、`reader_saved_highlight_render_test.dart`、`reader_scroll_highlight_render_test.dart` | 逐行 `Text.rich` 结构/span 样式不得被 wrapper 破坏 |
| `flutter_legado/test/widget/reader_inline_image_render_test.dart` | 行内图片 `WidgetSpan`/独立图行渲染与查找 |
| `flutter_legado/test/widget/reader_bookmark_badge_test.dart`、`reader_italic_style_test.dart`、`reader_title_font_test.dart`、`reader_scroll_title_font_test.dart`、`reader_app_font_independence_test.dart` | 行/段包裹结构调整后仍能找到 Text 并断言样式 |
| `flutter_legado/test/widget/page_flip_test.dart`、`test/performance/reader_page_test.dart` | 旧 `SimulationPageFlipWidget`，与 turn 系统无关，确认零影响 |

### 8.2 建议新增测试

- `reader_selection_mapping_test.dart`：缩进/悬挂/CRLF/行内图/跨行/跨段映射。
- `reader_char_selection_test.dart`（widget）：长按出词选 + 2 手柄；拖手柄扩展/收缩；复制得到精确文本；点击空白清选区且不弹菜单；`selectText=false` 不长按；翻页后选区清除。
- `reader_char_selection_turn_guard_test.dart`（widget）：选区激活时横拖 `ReaderTurnView` 不翻页、下滑不触发书签；清选区后同一手势可翻页。
- `reader_char_selection_scroll_test.dart`（widget）：滚动模式选区 + 手柄拖动不滚动、松手后可滚动。
- 既有面板测试补一例：从字符级选区打开"更多"，默认操作为选区而非整段。

### 8.3 需人工实机验证的场景

1. 分页四模式（仿真/覆盖/滑动/无动画）× 长按起选、拖两端手柄跨行、复制/分享/搜正文结果正确。
2. 选区激活时：横拖不翻页、竖拉不触发书签、点击空白清选区后下一次手势可正常翻页。
3. 章边界翻页、相邻章承接态、双页模式：无选区残影、无闪帧、无异常。
4. 翻页后再长按：新页可正常起选，旧选区不带入。
5. 滚动模式：长按起选、手柄纵向拖动优先于滚动、松手后滚动正常、跨 chunk 不选中。
6. 显示设置改动（字号/行高/字体/边距/双页/悬挂/对齐）时，选区自动清除且不崩。
7. `selectText=false`：无长按、无手柄。
8. 高亮/笔记/书签渲染、段评角标点击、正文行内图片点击不受影响。
9. 320dp 窄屏 + 1.6 倍字号：浮条不越界、手柄可点、菜单项可达。
10. 实机截图与参考 `parity_shots/r43_b_class_20261124/1-12_long_press_menu.png`、`ref_20260914/12_reader_longpress.png` 对比：灰块范围、手柄位置/大小/颜色、浮条锚点。

### 8.4 既有约束复核

- `docs/REMAINING_WORK_INVENTORY_20261120.md:84` 明确 R49 触及"阅读排版/翻页承重约束"。本设计对"测量同源同参"的保证：**零测量改动**；对"长按点 Overlay 浮条"的保证：字符级浮条仍走 Overlay，只是从模态改为 `TapRegion` 非模态，锚点改为选区矩形。
- "ZhLayout 压缩行超宽属设计内"：选区几何一律以实际 `RenderParagraph` 为准，不按引擎行宽反推、不据此重排；超宽行被 `ClipRect`（`reader_text_content.dart:223-244`）裁掉的部分自然不可选，与现状一致。
- "翻页动画层已整体换为移植重构版 turn 系统（回退即坏）"：本设计不改 turn 系统的快照/画笔/承接态，只在其裸 Listener 入口增加一个"选区激活"短路判断；禁止以"退回 PageView"作为兜底方案。
- `docs/REFACTORING_ACTIVE_PLAN.md` 批4c 登记"页内 Canvas 选区/手柄不改"；R49 即该项的正式立项，需在 Active Plan 回写本设计结论后再实施。

---

## 九、复现/核实命令

```bash
# 1) 当前实现位置与关键证据
cd /d/OH-WorkSpace/LegadoTeam/legado
grep -n "onLongPress" flutter_legado/lib/src/widgets/reader/reader_text_content.dart
grep -n "selectionActive" flutter_legado/lib/src/widgets/reader/turn/reader_turn_view.dart
grep -n "paginateChapter" flutter_legado/lib/src/widgets/reader/reader_page_view.dart

# 2) 静态分析与受影响的聚焦测试
cd flutter_legado
flutter analyze
flutter test test/widget/reader_selection_toolbar_test.dart \
             test/widget/reader_wiring_1a_test.dart \
             test/widget/text_selection_menu_test.dart \
             test/unit/text_selection_offset_test.dart \
             test/unit/reader_pagination_overflow_test.dart \
             test/widget/reader_swipe_bookmark_test.dart \
             test/widget/reader_tap_zones_dispatch_test.dart \
             test/widget/md3_acceptance_matrix_test.dart

# 3) 全量 Flutter 回归（CI 口径）
cd /d/OH-WorkSpace/LegadoTeam/legado/flutter_legado && flutter test

# 4) 参考版行为核对（源码）
cd /d/OH-WorkSpace/LegadoTeam/legado-with-MD3
grep -n "startWord\|fun extend\|data class ReaderSelection" app/src/main/java/io/legado/app/feature/reader/core/selection/ReaderSelection.kt
grep -n "SelectionHandleRadius\|LONG_PRESS_TIMEOUT_MILLIS\|drawPinHandle" app/src/main/java/io/legado/app/feature/reader/ReaderCanvasSurface.kt
grep -n "selectionColor" app/src/main/java/io/legado/app/ui/book/read/ReadBookRouteScreen.kt

# 5) Flutter SDK 原生选区机制核对（版本 3.44.8）
grep -n "TapAndHorizontalDragGestureRecognizer\|LongPressGestureRecognizer\|TextGranularity.character" \
  "D:/Flutter/SDK/flutter/packages/flutter/lib/src/widgets/selectable_region.dart"
grep -n "getBoxesForSelection\|getPositionForOffset\|getWordBoundary" \
  "D:/Flutter/SDK/flutter/packages/flutter/lib/src/rendering/paragraph.dart"

# 6) 设计通过后实施前：确认工作区干净（不要 reset --hard）
git status --porcelain
```

---

## 十、结论与建议

1. **A 方案可行，但落地形态应为 A3**：自研命中/绘制/手柄，Text 与分页引擎原样不动。
2. **A1/A2 不建议**：原生区域会抢点击、长按拖选粒度是词、精确章节范围提取不确定，且无法绕过 `ReaderTurnView` 的裸 Listener 翻页冲突；改造面并不比 A3 小。
3. **实施顺序必须先做第 5 步（翻页门控）的接线设计评审**：它是唯一会破坏"阅读主流程"的改动点；建议在第 2 步灰块可用后立即做一个"选区态横拖不翻页、清选区后可翻页"的探针用例，红→绿后再继续手柄与浮条。
4. **验收口径**：以 `flutter analyze` 0 诊断 + 全量 `flutter test` + 实机双模式截图为证；与参考版逐项对照灰块形状、两只 pin 手柄、浮条锚点与动作作用范围。

---

编写：调研员（调研子代理）｜ 2026-11-28
