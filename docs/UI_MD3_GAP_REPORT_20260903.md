# MD3 风格差距调研报告（发现页 / 订阅页 / 我的页 / 转场动画 / 加载动画）

- 编写者：Qoder ｜ 2026-09-03
- 目标风格源码：`HapeLee/legado-with-MD3`（本地只读副本 `D:\tmp\md3_ref_legado`，下文「参考」均指该副本文件）
- 我方代码根：`flutter_legado/lib/src/`
- 性质：**仅调研，未改任何代码**。每项给出「现状 file:line」「参考目标 file:line」「优化空间与优先级」。

---

## 一、发现页布局（Explore）

### 1.1 现状（explore_screen.dart，643 行）

| 区域 | 位置 | 实现 |
|---|---|---|
| 顶栏搜索 | :87–145 | `LegadoAppBar` 的 title 槽内嵌 TextField：高 36、圆角 10、填充 `onSurfaceVariant α0.12`，常驻不可收起 |
| 分组筛选 | :146–168 | actions 里 `PopupMenuButton(Symbols.groups_rounded)`，普通 PopupMenu（无头部/分隔样式） |
| 书源卡片行 | :471–531 | `IosGroup`（不透明 Card + 0.5px Divider）+ minHeight 44 行；展开箭头 `AnimatedRotation(chevron_right_rounded, turns 0.25)`，250ms easeInOut |
| 展开动画 | :521–528 | `SizeTransition + FadeTransition`（250ms） |
| 长按菜单 | :533–556 | `showMenu` 弹在行左上角：编辑/置顶/登录/搜索/刷新/删除（删除 error 色 :548–554） |
| 分类加载中 | :598–611 | 居中 `CircularProgressIndicator(strokeWidth: 2)`，18×18 |
| 平板双栏 | :205–266 | Row + VerticalDivider（此为我方特色布局，参考侧无对应） |

### 1.2 参考目标（D:\tmp\md3_ref_legado）

- `ui/main/explore/ExploreScreen.kt`：
  - 顶栏 = `ListScaffold` → `DynamicTopAppBar`：**无常驻搜索框**；标题「发现」+ 副标题=当前分组；右侧 **search 图标按钮**，点击后在顶栏下方以 `AnimatedVisibility(expandVertically + fadeIn)` 展开 `SearchBar`（DynamicTopAppBar.kt:112–131）；加载中/选择模式时标题自动切「加载中」/「已选 n/total」，导航键换 Close（:60–81）。
  - 分组 = `dropDownMenuContent` → **RoundDropdownMenu**（圆角下拉 + PillHeaderDivider 头部），非普通 PopupMenu。
  - 书源头卡 = **GlassCard(cornerRadius 12.dp)**：`animateColorAsState` 收起=surfaceContainerLow / 展开=secondaryContainer，文字 onSurface→primary，tween(200, FastOutSlowInEasing)；加载中箭头位用 `AnimatedContent` 换成 **AppContainedLoadingIndicator(18dp)**。
  - 长按 → **RoundDropdownMenu**：PillHeaderDivider(sourceName) 头部 + 6 项（删除 error tint），锚定在条目旁而非屏幕左上角。
  - **TopFloatingStickyItem + TextCard(cornerRadius 12)**：吸顶药丸显示当前可见书源头，点击滚动回该源。
  - 分类 = KindRow 6 列网格（`ExploreKindMultiTypeItem` + Spacer 占位）。

### 1.3 优化空间

| # | 项 | 优先级 | 说明 |
|---|---|---|---|
| E1 | 顶栏搜索改为「search 图标 → 动画展开 SearchBar」 | P1 | 复刻 DynamicTopAppBar.kt:82–90 + 112–131；Flutter 侧用 `AnimatedSize/AnimatedContainer` + `expandVertically` 等效（`AnimatedContainer` 高度动画或 `AnimatedScale+AnimatedOpacity`）。同时支持加载中/选择态标题切换 |
| E2 | 书源头卡 GlassCard 化 + 展开变色过渡 | P1 | IosGroup → 玻璃卡片（surfaceContainer、tonalElevation 0、无阴影、圆角 12、可选 outlineVariant 描边）；展开时底色/文字色 200ms FastOutSlowInEasing 过渡（对应参考 animateColorAsState）。颜色全部取 colorScheme token |
| E3 | 分组菜单 RoundDropdownMenu 化 | P1 | 替换 :146–168 的 PopupMenuButton；可做成共享组件（发现/订阅/RSS 管理三处复用） |
| E4 | 长按菜单锚定 + PillHeaderDivider 头部 | P2 | showMenu 改为锚定条目右下的圆角菜单，头部显示书源名；删除项保留 error 色 |
| E5 | 分类加载中换 ContainedLoadingIndicator(18dp) | P0 | :598–611 strokeWidth 2 的默认 spinner → 统一小尺寸容器内加载指示（见 §五 L1） |
| E6 | 吸顶书源药丸（TopFloatingStickyItem） | P2 | 列表滚动时显示当前可见书源头的 TextCard(12dp)，点击回滚。工作量中等，体验增益明显 |

---

## 二、订阅页布局（RSS）

### 2.1 现状（rss_screen.dart，599 行）

| 区域 | 位置 | 实现 |
|---|---|---|
| 顶栏搜索 | :92–130 | title 槽内嵌**胶囊搜索框**：高 36、圆角 **35**（stadium）、填充 α0.12，常驻 |
| 顶栏动作 | :131–174 | 4 个独立 IconButton：history_rounded（阅读记录对话框）/ star_rounded（收藏页）/ groups_rounded（PopupMenuButton 分组）/ settings_rounded（订阅源管理） |
| 网格 | :205–235 | `GridView` + `SliverGridDelegateWithFixedCrossAxisCount`，列数按宽度 4/6，间距 **8dp**，childAspectRatio 驱动行高 |
| 「规则订阅」入口格 | :274–332 | 网格第 0 格：50×50 圆角 12 图标芯片（primary α0.12 + 阴影）+ 13sp onSurfaceVariant 文字 |
| 源项 | :335–404 | 无卡片底：50×50 圆角 12 图标（带阴影，iOS App 图标风）+ 名称 13sp 居中 maxLines 2；**长按 = 直接弹删除确认对话框**（:61–85，error FilledButton） |
| 空态 | :224–233 | EmptyState 叠在网格中央 |

### 2.2 参考目标（RssScreen.kt）

- 顶栏 = `ListScaffold(title=订阅)`：**标题「订阅」+ ⋮ RoundDropdownMenu**（「管理信息源」PillDivider + 分组列表）——**没有独立齿轮/历史/收藏图标**；搜索同为 search 图标 → SearchBar 展开。
- 网格 = `LazyVerticalGrid(GridCells.Adaptive(minSize=72.dp))`，间距 **12dp**。
- 首行 = **两个 GlassCard 快捷操作卡**（规则订阅/Subscriptions 图标 + 收藏/Star 图标），各占 weight(1f)，内边距 12dp，AppIcon + labelMediumEmphasized——收藏入口从顶栏移入网格首行卡片。
- 源项 = `Column.clip(RoundedCornerShape(16.dp))` 的**整卡可点**：tap=打开、longPress=**RoundDropdownMenu（置顶/编辑/登录/禁用源/删除 error）**；SourceIcon **48dp** 居中 + labelMedium maxLines 2。

### 2.3 优化空间

| # | 项 | 优先级 | 说明 |
|---|---|---|---|
| R1 | 顶栏 MD3 化：标题「订阅」+ ⋮ RoundDropdownMenu（管理信息源 + PillDivider + 分组）+ search 图标展开搜索 | P1 | 替换 :92–174；阅读记录入口可移入 ⋮ 菜单或网格卡片，收藏按参考移入首行 GlassCard。与 E1/E3 共用组件 |
| R2 | 源项 GlassCard(16dp) 化 + 长按菜单 | P1 | :335–404：整卡 clip 16dp（surfaceContainer、无阴影）、图标 48dp；长按从「直接删除确认」改为 RoundDropdownMenu（置顶/编辑/登录/禁用源/删除），删除仍走现有确认对话框 |
| R3 | 「规则订阅 + 收藏」双 GlassCard 首行 | P1 | :274–332 单格 → 参考式两卡（各 weight 1f，padding 12dp）；顺带解决「收藏」入口位置 |
| R4 | 网格间距 8→12dp、Adaptive(minSize≈72) 替代固定列数 | P2 | :205–235；`SliverGridDelegateWithMaxCrossAxisExtent(max: 72, mainAxisSpacing: 12, crossAxisSpacing: 12)` 等效 Adaptive |

---

## 三、我的页布局（My / Settings）

### 3.1 现状（settings_screen.dart，446 行 + 子页面）

| 区域 | 位置 | 实现 |
|---|---|---|
| 顶栏 | :191–202 | `LegadoLargeTitleScroll`：**LargeTitle**（headlineSmall 24dp 覆盖），可收缩大标题 |
| 列表结构 | 全文件 | `IosGroupedBody` + ListView，3 组：顶部管理（书源管理/定时任务/SwitchListTile×3，Web 服务 busy→CircularProgressIndicator）、`IosSectionHeader('设置')`（备份与恢复/主题设置/其他设置）、`IosSectionHeader('其他')`（书签/阅读记录/文件管理/关于/退出） |
| 行样式 | widgets/ios_widgets.dart | `IosListTile`：32×32 **primaryContainer 图标芯片**（圆角 8）+ 文字 + SwitchListTile |
| 子页偏离 | cache_settings_screen.dart :153–166 / file_manage_screen.dart :233、:271 / read_record_screen.dart :71 / theme_config_screen.dart | 裸 ListView + stat Cards；stadium 搜索圆角 35 + chevron 面包屑；硬编码 `onSurface α0.45` hint；自定义圆角字面量 12/20 |

### 3.2 参考目标（MyScreen.kt）

- 顶栏 = **GlassMediumFlexibleTopAppBar**（可收缩 medium bar，标题「我的」+ help 图标），**非大标题**。
- 内容 = `verticalScroll Column` + adaptiveContentPadding(bottom 120dp)，**SplicedColumnGroup** 分段：规则段（书源管理/替换净化/TXT目录规则/字典规则/高亮标签）、其他（AI对话/设置/书签/阅读记录/缓存管理/文件管理/关于/退出）。
- 行 = **ClickableSettingItem / SwitchSettingItem**：图标直接落在卡片底上（无彩色芯片底），支持 title + description 两行；**无头像/profile 卡**。
- Web 服务块 = SwitchSettingItem + `AnimatedVisibility(expandVertically/shrinkVertically)` 展开 **SmallPlainButton(复制URL / 浏览器打开)**。

### 3.3 优化空间

| # | 项 | 优先级 | 说明 |
|---|---|---|---|
| M1 | 顶栏风格决策：保留 LargeTitle vs 参考 medium flexible bar | **需用户拍板** | LargeTitle 是此前用户授权偏离（AGENTS.md），可保留；若要完全贴参考则换 medium bar + help 图标。本项不默认执行，列入待决 |
| M2 | Web 服务行 AnimatedVisibility 展开「复制URL/浏览器打开」按钮 | P1 | 对齐 MyScreen.kt:270–299；我方现有 Web 服务 busy 时只显示 CircularProgressIndicator，缺展开动作区 |
| M3 | 子页硬编码值清理（圆角 12/20、α0.45 hint、stadium 35） | P1 | 统一走 design_system token / IosGroup 模式；file_manage :233 的 stadium 搜索与 RSS/发现页搜索样式应一并统一 |
| M4 | 行图标芯片去色底（可选） | P2 | IosListTile 32×32 primaryContainer 芯片 → 参考式裸图标落卡底；视觉差异较小，可随 M1 决策一并定 |

---

## 四、转场动画

### 4.1 现状

- `app_theme.dart`（404 行）：有 cardTheme(:222)、dialogTheme(:328)，**无 pageTransitionsTheme**；`main.dart:122` 的 MaterialApp 未设任何页面转场 → **全部路由走 Material 默认 MaterialPageRoute 转场**。
- 全项目 **19 个文件**存在 `MaterialPageRoute` 调用点（association_import_dialog / audio_screen / book_info_screen(+builders.part) / bottom_bar_skin_screen / code_edit_screen / js_source_edit_screen / replace_rules_screen / rss_articles_screen / rss_screen / rss_source_manage_screen / rule_sub_screen / source_*_part×3 / webview_login_screen / utils/source_login_entry、source_login_prompt / widgets/reader/reader_top_bar）。
- 共享元素：**仅书架↔书详情封面 Hero**（widgets/book_cover.dart:70，tag=`cover:<book url>`）；发现分类页/搜索结果 → 书详情 **没有**共享封面过渡。

### 4.2 参考目标（MainNavGraph.kt）

- **按路由定制 transitionSpec/popTransitionSpec**：
  - ReadBook：进出均 **crossfade tween(600)**，且受 `predictiveBackEnabled` 门控的 predictivePopTransitionSpec；
  - BookInfo：从 Home/ExploreShow/Search 进入时 **crossfade tween(300)**，其余默认。
- **系统预测式返回手势**（predictive back）。
- **共享元素封面**：`bookCoverSharedElementKey` / `sharedCoverKey` 跨 Home/ExploreShow/Search → BookInfo 全程复用同一 key。

### 4.3 优化空间

| # | 项 | 优先级 | 说明 |
|---|---|---|---|
| T1 | 全局 pageTransitionsTheme（main.dart MaterialApp） | P0 | 按路由分档：阅读页 crossfade 600ms；书详情/搜索结果进入 crossfade 300ms；其余保持默认。Flutter 侧用 `MaterialApp.pageTransitionsTheme` + `PageBasedTransitionTheme`（或自定义 PageRouteBuilder 分发）实现，零侵入现有 19 处调用点 |
| T2 | Hero 扩展到发现分类/搜索 → 书详情 | P0 | book_cover.dart:70 的 tag 约定已存在，只需让 explore_show / search 结果卡片复用同一 `cover:<url>` tag；参考侧正是这三个入口共享封面 |
| T3 | 微动效曲线/时长 token 统一 | P1 | 参考统一 200ms FastOutSlowInEasing（头部变色/箭头）、slideIn+fadeIn（选择底栏）、expandVertically+fadeIn（搜索条）。我方现有 250ms easeInOut（explore :57）等散落各处，建议在 design_system 层定 `kMd3Fast=200ms` / `kMd3Standard=300ms` + FastOutSlowIn 曲线常量并逐步替换 |
| T4 | 预测式返回手势（Android predictive back） | P2/调研 | 属平台级能力（Android 16+），Flutter 侧支持有限，需先调研可行性再立项；参考侧靠 Compose `predictiveBackEnabled`。暂不排期，仅记录 |

---

## 五、加载动画

### 5.1 现状

| 项 | 位置 | 实现 |
|---|---|---|
| 整页加载 | widgets/loading_indicator.dart + loading_overlay.dart | **Md3LoadingIndicator**：自绘波形 CustomPainter（3600ms 循环），仅用于整页/覆盖层 |
| 列表内加载 | explore_screen.dart :598–611、settings Web 服务行等 | 裸 `CircularProgressIndicator`（默认 strokeWidth）；全项目约 **91 处** CircularProgressIndicator（67 个文件）+ **15 处** LinearProgressIndicator，多数未定制主题 |
| 骨架屏 | — | **无**。首页/书架模块加载时直接整页 LoadingIndicator |

### 5.2 参考目标

- **AppContainedLoadingIndicator(18dp)**：M3 Expressive `ContainedLoadingIndicator`，用于列表内/头部加载（Explore 头卡箭头位）。
- **AppCircularProgressIndicator(strokeWidth=4.dp)**、**AppLinearProgressIndicator**：统一描边宽度与 token。
- **骨架 shimmer**：首页模块（Waterfall/Grid/Banner）用 `rememberShimmerBrush` / `rememberInfiniteTransition` 做流光占位，而非全屏 spinner。

### 5.3 优化空间

| # | 项 | 优先级 | 说明 |
|---|---|---|---|
| L1 | ContainedLoadingIndicator(18dp) Flutter 等效组件 | P0 | 新建共享小组件（可基于 Md3LoadingIndicator 缩小版或 M3 contained 样式），替换列表内裸 spinner（explore :598–611 等高频处）；一次建组件、分批换调用点 |
| L2 | LinearProgressIndicator 主题化 | P0 | 在 app_theme.dart 加 `progressIndicatorTheme`/linear 定制：高度、trackColor=outlineVariant α、strokeWidth 4dp，覆盖全部 15+91 处裸用法（全局生效，零调用点改动） |
| L3 | 首页模块骨架 shimmer | P1 | 自绘 shimmer（LinearGradient + AnimationController 平移，或引入 flutter_shimmer 依赖——需评估是否新增第三方包）用于首页瀑布/网格/Banner 首载；替代整页 LoadingIndicator |
| L4 | 全页 Md3LoadingIndicator 与 spinner 家族参数对齐 | P2 | 波形保留（已 MD3 token 化），但时长/曲线向 kMd3Fast/kMd3Standard 收敛，避免两套动效节奏 |

---

## 六、汇总与执行建议

**P0（低风险高收益，可先做）**：T1 全局转场分档、T2 Hero 封面扩展到发现/搜索入口、L1 ContainedLoadingIndicator 组件 + 高频替换、L2 ProgressIndicator 主题化。
**P1（布局主视觉）**：E1/E2/E3（发现页顶栏+头卡+菜单）、R1/R2/R3（订阅页顶栏+源项+首行双卡）、M2/M3（我的页 Web 服务展开 + 子页硬编码清理）。
**P2（体验增强/决策项）**：E4/E6、R4、M1（LargeTitle 去留需用户拍板）、M4、T3/T4、L3/L4。

组件复用关系：**RoundDropdownMenu（E3/R1 共用）+ SearchBar 展开（E1/R1 共用）+ GlassCard（E2/R2/R3 共用）+ ContainedLoadingIndicator（E5/L1）**——建议按「先建共享组件，再逐页替换」的顺序分批实施，每批走 analyze/test/冒烟 5556+5558 + pubspec patch + 双更新日志。

编写者：Qoder ｜ 2026-09-03
