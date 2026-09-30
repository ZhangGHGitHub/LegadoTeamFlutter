# 全局统一组件对照盘点报告（STAGE-R-GLOBALCOMP，参考版 vs 我方）

- 日期：2026-09-30 ｜ 作者：调研员（只读调研，未改任何代码，除本报告）
- 范围：参考版 `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3\app\src\main\java\io\legado\app\ui\widget\components\`（只读视觉基准）；我方 `flutter_legado/lib/`（工作仓）
- 方法：参考版 components/ 全目录清单化（29 顶层 .kt + 40 子目录）+ 逐符号 grep 引用面统计（**注意：子目录文件名 ≠ composable 函数名**，如 `AppButton.kt` 内是 `PrimaryButton/SecondaryButton`，引用计数一律按实际符号名重测）+ 我方 widgets/ 全清单对照 + 原生组件散用 grep 计数
- 前次报告：`docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md`（加载指示器三件套已收口；其 §4.3 勿误改清单在本报告继续有效）

---

## 结论摘要（先看这里）

1. **两家统一思路结构性不同，这是本调研最重要的背景**：参考版走「组件层统一」——91 个具名 Composable 封装（AppModalBottomSheet 91 文件引用、AppText 142、AppScaffold 59…）+ 双引擎（Miuix/MD3 按 `ThemeResolver` 分流）；我方走「主题层统一」——`app_theme.dart` 一个 `ThemeData` 里挂 **30+ 组件 Theme**（card/dialog/bottomSheet/tabBar/chip/switch/checkbox/radio/slider/FAB/snackbar/tooltip/menu/popupMenu/searchBar/4 种按钮/divider/listTile/navigationBar…，`app_theme.dart:214-575`），原生组件裸用即继承 MD3 token。**因此我方「散用」≠ 视觉散乱**：真正缺失的是「结构/行为统一」（Scaffold 模糊壳、BottomSheet 壳、Dialog 壳、刷新与 scrollBehavior 联动、输入框参数收敛），而非颜色圆角。
2. **加载三件套已完成勿再立项**：`app_progress_indicator.dart`（`AppCircularProgressIndicator`/`AppLinearProgressIndicator`/`AppContainedLoadingIndicator`，注释标注 STAGE-UI-P43UNIFY2 B3 对齐参考版 `progressIndicator/`）已落地；`Md3LoadingIndicator`/`SkeletonBox`/`ContainedLoadingIndicator`/`TopNetworkLoadingBar` 为授权 expressive 件，全部保留。
3. **我方已有 10+ 个高引用对齐封装，对照时勿误判为缺失**：`LegadoAppBar`（66 文件，对齐参考版 topbar 全家）、`EmptyState`（24 文件，颜文字池与参考版 `EmptyMessage.kt:33-44` 逐字同）、`ConfirmDialog`（15）、`CustomRefreshIndicator`（13，对齐 `AppPullToRefresh` 语义）、`Md3FastScroller`（13，对齐 `FastScrollLazyColumn` 15）、`BookCover`（14，对齐 `CoilBookCover` 21）、`Md3HeatmapCalendar`（授权特性）、`Md3PickerSheet`（滚轮选择，对齐 `ColorPickerSheet` 语义）、`app_navigation_bars`（对齐 `AppNavigationBar`）、`explore_kind_*`（对齐 `ExploreKind*`）、`TopBarButton` 5 档样式（对齐 `TopBarButton`/`GlassDefaults`，含 glass/liquidGlass 实色回退）。
4. **真正的全局统一机会（按「引用面 × 偏离度」排序 Top5）**：① `AppTextField` 统一输入框（参考版 58 / 我方 59 文件 123 处散用 + **无 textInputTheme** + 9 文件 `InputBorder.none` + 10+ 文件自定 hintStyle）——量级 L；② `AppScaffold` 统一页壳（参考版 59 / 我方 70 文件裸 `Scaffold(`，缺 edge-to-edge/模糊采样行为）——量级 L；③ `AppAlertDialog` 对话框壳统一（参考版 74 / 我方 62 文件 126 处裸 `AlertDialog(` + 20+ 自造 dialog 类 + `showDialog` 180 处）——量级 M；④ `AppModalBottomSheet` 底栏壳统一（参考版 91 / 我方 `AppBottomSheet` 封装**已存在但仅 1 处接线**，其余各域 sheet 各造壳）——量级 M；⑤ settingItem 行语义组件族（参考版 `ClickableSettingItem` 20 / `SwitchSettingItem` 16 / `SliderSettingItem` 12 / `InputSettingItem` 7 / `DropdownListSettingItem` 11 / 我方设置页分组容器已统一（`IosGroupedBody`/`IosListTile` 86 处）但**行语义散用 `SwitchListTile`/`CheckboxListTile`/裸 `Slider`**）——量级 M。
5. **7 个自造孤儿组件（有封装零接线，仅测试引用）**：`pill_divider.dart`、`search_bar_widget.dart`、`swipe_action.dart`、`source_card.dart`、`tag_chip.dart`、`badge_widget.dart`、`chapter_tile.dart`——对应参考版 `PillDivider`（14 文件）/`SearchBar`（16）/`SwipeAction`（3）等真实需求；接线或删除需用户裁决（删除属红线范围）。
6. **功能级缺口 ≠ 组件统一，勿混入批次**：参考版有、我方完全没有的（privacy 隐私模式 8 件、BgEffect 背景效果 6 件、`VariableEditorSheet`、`ValueStepper`、`BookshelfConflictSheet`、`DraggableSelectionHandler` 长按拖选、player 域 5 件、heatmap 已对齐除外）属 AGENTS「未经允许禁止新增功能」红线，本报告只登记不立项。

---

## 一、参考版组件清单（components/ 全量）

> 引用面 = 参考版仓内引用该符号的 .kt 文件数（含定义文件；`grep -rlw` 实测；主代理预统计数字已复核一致）。
> 「0 引用」= 符号仅文件内使用或文件名与符号名不符（已按实际符号名重测；仍为 0 的属域内私有，登记不深挖）。

### 1.1 顶层组件（29 个 .kt）

| 组件（符号） | 引用 | 一句话语义 | 关键参数面 / 色槽来源 |
|---|---|---|---|
| `AppScaffold` | **59** | 统一页壳：HazeState 模糊采样 + 液态玻璃 backdrop + 背景图透明化 + edge-to-edge + snackbarHost + FAB 位 | `topBar:(HazeState)->Unit`、`bottomBar`、`snackbarHost`、`floatingActionButton(+Position)`、`alwaysDrawBehindBars=false`、`disableContentSampling=false`（WebView 关采样）、`content(PaddingValues)->Unit`；色槽 `MiuixTheme.colorScheme.surface/background`（`AppScaffold.kt:41`） |
| `AppTextField` | **58** | 内嵌 label 输入框（自定义 surface，非原生 OutlinedBorder） | `state:TextFieldState`、`label`+`labelPosition=Inside`、`placeholder`、`leading/trailing/prefix/suffix`、`isError`、`keyboardOptions`；`AppTextField.kt:37`（`AppDenseTextField:293` 密排版、`AppTextFieldSurface` 2 处） |
| `EmptyMessage` | **26** | 颜文字 7 面池空态 + `AnimatedTextLine` 文案 + `SmallTonalButton`；`isLoading` 分支 → `AppContainedLoadingIndicator` | `message`、`isLoading=false`、`buttonText`、`buttonImageVector`、`faces=listOf("(；′⌒`)"…7 面,32sp)`、`faceTextSize`、`onFaceClick`（`EmptyMessage.kt:33`） |
| `AppFloatingActionButton` | **25**（`Menu` 4 / `FabMenuItem` 4） | FAB/扩展菜单：primaryContainer 容器 + primary 内容 | `icon:ImageVector?`、`containerColor=primaryContainer`、`contentColor=primary`、`tooltipText`、`content?`（`AppFloatingActionButton.kt:60`） |
| `SplicedColumnGroup` | **21**（`Divider` 6 / `SettingItemWithDivider` 2） | 设置分组列（组间 SplicedColumnDivider） | `title`、`items:ColumnScope.()`（`SplicedColumnGroup.kt:43`） |
| `SearchBar` | **16**（`AppSearchBar` 1） | 搜索栏：surfaceContainerLow 底、自动聚焦、清除、下拉菜单、滚动联动 | `query`、`onQueryChange`、`onSearch`、`placeholder`、`leadingIcon`、`backgroundColor=surfaceContainerLow`、`scrollState`、`autoFocus=true`、`dropdownMenu?`（`SearchBar.kt:42`） |
| `AppPullToRefresh` | **8** | 下拉刷新，可联动顶栏滚动行为 | `isRefreshing`、`onRefresh`、`enabled=true`、`topPadding`、`scrollBehavior:GlassTopAppBarScrollBehavior?`（`AppPullToRefresh.kt:33`） |
| `AppSlider` | **7** | Slider 薄封装（主题槽 + a11y 标签） | `value`、`onValueChange`、`valueRange`、`steps`、`accessibilityLabel/Value`（`AppSlider.kt:14`） |
| `SectionTitle` | **6** | 居中分组标题（labelMediumEmphasized，垂直 8dp） | `title`（`SectionTitle.kt:14`） |
| `LoadMoreFooter` | **5** | 列表页脚：加载/错误/到底/重试/自动加载 | `isLoading`、`errorMsg`、`isEnd`、`onRetry`、`onLoadMore?`、`autoLoad=true`（`LoadMoreFooter.kt:43`） |
| `FloatingBottomBar` | **5** | 底部悬浮操作条（拖拽阻尼） | `DampedDragAnimationHolder` 配套 |
| `ValueStepper` | **4** | 数值步进器 | — |
| `GroupManageBottomSheet` | **4** | 通用分组管理底栏（书源/RSS/替换规则共用） | — |
| `AdaptiveSwitch`/`TinySwitch` | 4/4（`IconSwitch` 1） | 开关变体族 | — |
| `AppRadioButton` | **4** | Radio 封装 | — |
| `AccentColorButton` | 3 | 强调色按钮 | — |
| `AppContainerBackground(Type)` | 3/3 | 容器背景工具 | — |
| `SelectionBottomBar` | 3（`ActionItem` 12 / `SelectionActions` 5） | 多选底部操作条 | — |
| `ReorderableConfigList` | 3（`ConfigListEntryRow` 3） | 配置项拖拽排序 | — |
| `JsonRawEditor` | 3（`JsonConfigEditor` 2） | 规则 JSON 编辑 | — |
| `FontSelectSheet` | 6（`Grid` 2） | 字体选择 | — |
| `CollapsibleHeader` | 2 | 可折叠分组头 | — |
| `AppVerticalSlider` | 2 | 垂直滑杆 | — |
| `DraggableSelectionHandler` | **7** | 长按拖拽多选 | — |
| `ReorderAccessibility` | 0（域内） | 排序 a11y | — |
| `GlassDefaults` | **5** | 玻璃效果参数（`glassColor`/`secondaryColorOr`） | — |

### 1.2 子目录组件（40 目录，重点 UI 分类；引用数为实测）

**高频全局类（引用 ≥4，逐一语义化）：**

| 符号 | 引用 | 一句话语义 / 关键参数 |
|---|---|---|
| `AppText`（text/） | **142** | 全局文本薄封装：主题 typography + Miuix 引擎回退；参数面 = 标准 Text 全量（`AppText.kt:22`） |
| `AppModalBottomSheet`（modalBottomSheet/） | **91** | 统一底栏壳：标题 + start/end 动作 + 内容区 padding + 手势/尺寸动画开关（`show`、`title`、`startAction`、`endAction`、`animateContentSize=true`、`contentPaddingEnabled=true`、`sheetGesturesEnabled=true`；`AppModalBottomSheet.kt:48`） |
| `AppAlertDialog`（alert/） | **74** | 统一对话框：`show` 受控 + title/text/content + confirm/dismiss 双按钮默认「确定/取消」（`AppAlertDialog.kt:33`） |
| `GlassTopAppBarDefaults`（topbar/） | **57** | 顶栏默认值（圆角/色/滚动行为工厂） |
| `RoundDropdownMenuItem`（menuItem/） | **58** | 圆角下拉菜单项：`text`、`isSelected`、`leading/trailingIcon`、`contentPadding`（`:44`） |
| `GlassCard`（card/） | **56** | 玻璃卡（`NormalCard` 39 非玻璃版）：`onClick/onLongClick`、`cornerRadius=MiuixCardDefaults`、`containerColor?`、`border?`（`GlassCard.kt:116/144`） |
| `TopBarNavigationButton`（topbar/） | **51** | 顶栏返回钮：默认 `AppIcons.Back` + 「返回」语义（`TopBarButton.kt:276`） |
| `RoundDropdownMenu`（menuItem/） | **50** | 圆角下拉菜单：`shape=medium`、`shadowElevation=4dp`、`verticalSpacing=8dp`（`:38`） |
| `GlassMediumFlexibleTopAppBar`（topbar/） | **49** | 中大号弹性顶栏：`title`、`useCharMode`（首字母模式）、`subtitle`、`scrollBehavior`、`navigationIcon`、`actions`、`bottomContent`（`:45`） |
| `AppIcon`（icon/） | **40** | 图标封装（painter/imageVector 双通道 + tint，`:29`）；`AppIcons` 39 = 图标池常量类 |
| `TextCard`（card/） | **38** | 文本小卡：icon + text + 可选点击，8dp 圆角（`:27`） |
| `TopBarActionButton`（topbar/） | **30** | 顶栏动作钮（`:305`） |
| `ListUiState`（list/） | **22**（`SelectableItem` 13） | 列表状态/选中模型（VM 侧，非纯 UI） |
| `CoilBookCover`（image/cover/） | **21** | 书封（Coil + 默认封面 + 加载占位 Book 图标）（`CoilBookCover.kt:238`） |
| `ClickableSettingItem`（settingItem/） | **20** | 设置点击行：`title`、`description`、`option`、`imageVector`、`trailingContent`、`onLongClick`（`:17`） |
| `ConfirmDismissButtonsRow`（button/） | **17** | 对话框确认/取消按钮行（`:15`） |
| `ColorPickerSheet`（dialog/） | **17** | 颜色选择底栏（`:51`） |
| `SwitchSettingItem`（settingItem/） | **16** | 设置开关行：`title`、`description`、`checked`、`imageVector`、`color`（`:20`） |
| `FilePickerSheet`（filePicker/） | **16** | 文件选择底栏（导入域）（`:22`） |
| `AppTabRow`（tabRow/） | **15** | 标签行：`tabTitles`、`selectedTabIndex`、`onTabSelected`、`isScrollable=true`（`:19`） |
| `FastScrollLazyColumn`（lazylist/） | **15** | 带快速滚动条的 LazyColumn（`VerticalFastScroller` 2 / `VerticalGridFastScroller` 2） |
| `AnimatedTextLine`（text/） | **15** | 单行动画文本（EmptyMessage 用，`:92`） |
| `PillDivider`（divider/） | **14** | 胶囊分隔线：`thickness=2dp`、`widthFraction=0.2`、`outlineVariant 60%`（`:21`） |
| `SelectableItem`（list/） | 13 | 可选项模型 |
| `SliderSettingItem`（settingItem/） | **12** | 设置滑杆行：`value`/`defaultValue`/`valueRange`/`steps`/`valueLabel`（`:48`） |
| `CardTabRow`（tabRow/） | **12** | 卡片式标签行（`:28`） |
| `ActionItem`（顶层） | 12 | 选择操作项 |
| `CheckboxItem`（checkBox/） | **11** | 勾选行：`title`、`checked`、`description`、`color=onSheetContent`（`:21`） |
| `DropdownListSettingItem`（settingItem/ListSettingItem.kt） | **11** | 下拉设置行 |
| `SourceInputDialog`（importComponents/） | **10** | 导入源输入框 |
| `CompactDropdownSettingItem`（settingItem/） | **10**（Compact 族：Switch 7 / Clickable 7 / Slider 4） | 密排设置行 |
| `AppLogSheet`（log/） | **10**（`CrashLogSheet` 2 / `LogDetailSheet` 3） | 日志底栏 |
| `SettingItem`（settingItem/） | 9 | 设置行基类（`:48`，含 semantic 参数） |
| `RuleListScaffold`（rules/） | 9（`RuleEditSheet` 4） | 规则列表壳（包 `ListScaffold` 7，`RuleListScaffold.kt:40`） |
| `PillHeaderDivider`（divider/） | 7 | 头部胶囊分隔线 |
| `InputSettingItem`（settingItem/） | 7 | 输入设置行（`:30`） |
| `ChangeSourceSheet`（changeSource/） | 7 | 换源底栏 |
| `BookshelfConflictSheet`（conflict/） | 7 | 书架冲突底栏 |
| `TopFloatingStickyItem`（list/） | 6 | 列表顶吸浮项 |
| `OptionSheet`（modalBottomSheet/） | 6 | 选项底栏（`:25`） |
| `MarkdownBlock`（text/） | 6 | Markdown 块 |
| `VariableEditorSheet`（variable/） | 5 | 变量编辑底栏 |
| `TextListInputDialog`（dialog/） | 5 | 文本列表输入框 |
| `BookmarkEditSheet`（bookmark/） | 5 | 书签编辑底栏 |
| `AppCheckbox`（checkBox/） | 5（`AppTriStateCheckbox` 1 / `CheckboxGroupContainer` 1） | 复选框封装 |
| `ToggleChip`（button/） | 4 | 切换 Chip（`:31`） |
| `SecondaryButton`（button/AppButton.kt） | 6（`PrimaryButton` 5） | 主/次按钮（双引擎） |
| `SearchBookGridItem`（book/） | 5（`ListItem` 4 / `PreviewSheet` 4 / `TagChip` 3） | 搜索书卡 |
| `CustomTipDialog`（dialog/） | 3（`TimePickerDialog` 3 / `HtmlContent` 3 / `GlassSmallTopAppBar` 3 / `ExploreKindSelectSheet` 3 / `MiuixScrollBehavior` 3 / `SwipeAction` 3 / `PlayerProgressSlider` 3 等） | 低引用，登记 |

**0/低引用登记（不深挖）**：`TinySettingItems` 族、`SmallTitle`（实际符号 `AdaptiveTitle` 2）、`TopBarLiquidGlass`（`internal fun Modifier`，域内）、`PagerHeight`/`PagerNestedScroll`（0 外部，翻页域）、`ListSettingItem`（符号在 `DropdownListSettingItem`）、`ImportComponents`（`ImportItemRow` 1）、`HeatmapCalendarComponents`（`HeatmapCalendarCell` 1 + `HeatmapConfig` 3，特性已授权）、`ExploreKindTextField`（`ExploreKindCompactTextField` 0 外部）、reader/ 域 8 件（阅读菜单玻璃系，我方 `reader_menu_panel.dart` 等已对齐）、privacy/ 域 8 件（**我方无隐私模式**）、player/ 域 5 件（听读/视频域）、effect/ 域 6 件（**我方无 BgEffect**）、heatmap/ 域、bookmark/、log/、rules/ 其余。

---

## 二、我方对照（核心）

### 2.0 我方 widgets/ 全清单（101 个 .dart，分类速览）

- **统一封装（有接线）**：`legado_app_bar.dart`(66 文件引用)、`top_bar_button.dart`(7)、`confirm_dialog.dart`(15)、`empty_state.dart`(24)、`error_view.dart`(23)、`loading_indicator.dart`(33)、`loading_overlay.dart`、`md3_loading_indicator.dart`、`skeleton.dart`(8)、`contained_loading_indicator.dart`(5)、`app_progress_indicator.dart`（**三件套，已对齐参考版 progressIndicator/**）、`list_footer.dart`(3，含 `TopNetworkLoadingBar`)、`custom_refresh_indicator.dart`(13)、`ios_widgets.dart`(14，`IosGroupedBody`/`IosGroup`/`IosListTile` 86 处/`IosSectionHeader` 10/`IosSectionFooter`/`IosGrabber`)、`md3_fast_scroller.dart`(13)、`book_cover.dart`(14)、`md3_picker_sheet.dart`(3)、`md3_animated_text_line.dart`(4)、`md3_heatmap_calendar.dart`(2)、`app_navigation_bars.dart`(2)、`system_bar_binder.dart`(2)、`dynamic_search_app_bar.dart`(3)、`explore_kind_layout/action.dart`(4)、`setting_cards.dart`(2)、`bottom_sheet_widget.dart`(2)、`zh_layout.dart`(6)、`paragraph_layout_engine.dart`(3)、`badge/chapter_tile/source_card/tag_chip/swipe_action/pill_divider/search_bar_widget`(各 1=仅自测，**孤儿**)
- **域内 sheet/dialog（各 1-4 接线）**：`reader/*`（19 件，阅读器域）、`manga/*`、`export_dialog`/`update_dialog`/`crash_log_dialog`/`dict_dialog`/`open_url_confirm_dialog`/`restore_ignore_dialog`/`video_settings_dialog`/`classic_login_dialog`/`login_v2_dialog`/`auto_task_debug_dialog`/`*_group_manage_dialog`(3)/`custom_group_dialog`(4 屏)

### 2.1 散用统计（我方 `flutter_legado/lib` 实测，occ=出现行 / files=文件数）

| 原生组件 | 我方散用 | 参考版对应 | 判定 |
|---|---|---|---|
| `Text(` | 2277 / 159 | `AppText` 142 | **维持现状**：我方 typography 已统一在 `ThemeData.textTheme=AppTypography.lightTextTheme`（`app_theme.dart:218`），参考版 `AppText` 是双引擎薄壳，我方无 Miuix 引擎需求 |
| `Icon(` | 573 / 116 | `AppIcon` 40 / `AppIcons` 39 | **维持现状**：`material_symbols_icons` 等价 `AppIcons` 图标池；`AppIcon` 仅双引擎意义 |
| `Scaffold(` | **73 / 70** | `AppScaffold` 59 | **散用 = 统一机会**：我方无页壳封装，系统栏走 `system_bar_binder`（app.dart 单点），边缘留白/模糊无统一 |
| 裸 `AppBar(`（排除 LegadoAppBar） | 25 | topbar 族 49+57+51+30 | **已对齐**：`LegadoAppBar` 62 处 / 57 文件（`legado_app_bar.dart:24`，注释声明对齐 Android TitleBar/displayHomeAsUp 语义） |
| `TextField(` | **123 / 59**（+`TextFormField` 9） | `AppTextField` 58 | **散用 = 统一机会**：`app_theme.dart` **无 textInputTheme**；`border: InputBorder.none` 至少 9 文件（`bottom_bar_skin_assign_screen.dart:311`、`code_edit_screen.dart:320`、`js_source_edit_screen.dart:408`、`read_record_screen.dart:96`、`search_screen_scope_sheet.part.dart:293`、`source_edit_screen_builders.part.dart:249`、`toc_screen.dart:682`、`search_bar_widget.dart:75`、`explore_kind_layout.dart:760`）；自定 `hintStyle` 10+ 文件（`bookshelf_manage_screen.dart:301` 等） |
| `AlertDialog(` | **126 / 62**（`showDialog*` 180 / 63） | `AppAlertDialog` 74 | **散用 + 半对齐**：`dialogTheme` 已 token 化（`app_theme.dart:392`：surfaceContainer + extraLarge 圆角）；`ConfirmDialog`（15 文件，按钮规范注释声明对齐参考仓 `confirm_dialog.dart:14-30`）；20+ 自造 dialog 类 |
| 底栏壳 | `showModalBottomSheet` 裸用 2 + 各域自造壳（`reader_settings_sheet.dart:35`、`change_chapter_source_sheet.dart:28`、`manga_page_actions_sheet.dart:84`…） | `AppModalBottomSheet` 91 | **自造偏离**：`AppBottomSheet` 封装**已存在**（`bottom_sheet_widget.dart:4`，注释声明对齐 `AppModalBottomSheet` 标题规格、把手走主题统一）但**仅 `file_manage_screen.dart:149` 1 处接线**（注释「统一壳迁移示范」）；`bottomSheetTheme` 已 token 化（`app_theme.dart:403`：surfaceContainer + 28dp 顶角 + 抓手） |
| `FloatingActionButton(` | 9 / 7（auto_task/book_group/audio/toc/txt_toc_rules/reader_bottom_bar/read_aloud_bar） | `AppFloatingActionButton` 25 | **散用**：`floatingActionButtonTheme` 已 token 化（`app_theme.dart:381`），缺结构封装（量级小） |
| `RefreshIndicator(` | 13 / 12 | `AppPullToRefresh` 8 | **已对齐**：`CustomRefreshIndicator`（13 文件，`:11`，displacement 64 / 色 primary / 线宽 2.5 对齐 SwipeRefreshLayout）；12 个裸用文件多为封装定义与长尾 |
| `Slider(` | 29 / 14 | `AppSlider` 7 + `SliderSettingItem` 12 + player 域 | **散用**：`sliderTheme` 已 token 化（`:540`）；设置页滑杆行 = `IosListTile`+裸 Slider 自拼 |
| `Checkbox(` | 20 / 14 | `CheckboxItem` 11 + `AppCheckbox` 5 | **散用**：`checkboxTheme` 已 token 化（`:515`） |
| `Switch(` | 12 / 11（+`SwitchListTile` 散用） | `SwitchSettingItem` 16 + 开关族 1+4+4 | **散用**：`switchTheme` 已 token 化（`:498`） |
| `Chip(` | 48 / 16 | `ToggleChip` 4 + 标签 chip 5 | **散用**：`chipTheme` 已 token 化（`:479`） |
| `TabBar(` | 10 / 7 | `AppTabRow` 15 + `CardTabRow` 12 | **散用**：`tabBarTheme` 已 token 化（`:414`，label 指示器 + titleSmall） |
| `DropdownMenuItem(` | 15 / 7（`DropdownMenu`/`showMenu` 0 处） | `RoundDropdownMenu` 50 + `Item` 58 | **散用**：`dropdownMenuTheme`/`popupMenuTheme` 已 token 化（`:427/:437`）；参考版圆角菜单是结构件，我方用原生 DropdownMenu |
| `ReorderableListView` | 5 / 5 | `ReorderableConfigList` 3 | **等价**（原生即统一） |
| `SnackBar` | 89 文件 | `AppScaffold` snackbarHost 参数 | **散用**：`snackBarTheme` 已 token 化（`:451`）；页壳统一时顺带收拢 |
| `ExpansionTile` | 2 | `CollapsibleHeader` 2 | 等价 |
| `RadioButton(` | 0 | `AppRadioButton` 4 | 我方无 radio 场景（登记） |
| `Card(`（裸 Material） | 95 / 32 | `GlassCard` 56 + `NormalCard` 39 + `TextCard` 38 | **散用但视觉统一**：`cardTheme`（`:281`：elevation 0 + 统一圆角 + 透明 tint）；参考版玻璃卡是效果件，我方无玻璃需求 |

### 2.2 已对齐（勿误判为缺失）——抽样比对结果

| 我方 | 参考版 | 抽样比对证据 |
|---|---|---|
| `empty_state.dart` | `EmptyMessage.kt:33` | 颜文字 7 面池逐字同（`empty_state.dart:50` `'(；′⌒`)'` 起，与参考版 `faces` 默认参一致；`isLoading` 分支走 `ContainedLoadingIndicator`） |
| `app_progress_indicator.dart` | `progressIndicator/` 三件套 | 文件头注释逐项对齐（`AppCircular` 4dp 默认 / `AppLinear` / `AppContained` 委托既有件），STAGE-UI-P43UNIFY2 B3 产物 |
| `md3_loading_indicator.dart` / `skeleton.dart` / `contained_loading_indicator.dart` / `list_footer.dart`(`TopNetworkLoadingBar`) | `SkeletonPlaceholders` / `ContainedLoadingIndicator` / `RefreshProgressBar` | 前次报告 §1.4 已取证：shimmer 1200ms、Contained 48dp、顶栏 2dp 条逐项同参；授权 expressive 件 |
| `legado_app_bar.dart` | topbar 族（`GlassMediumFlexibleTopAppBar` 49 等） | 62 处/57 文件；返回语义对齐 Android TitleBar；`toolbarOpacity` 背景混色（`:24-60` 注释） |
| `top_bar_button.dart` | `TopBarButton`/`GlassDefaults` | 5 档样式（plain/tonal/outlined/glass/liquidGlass），glass/liquidGlass 走**实色玻璃回退**（`top_bar_button.dart:84-85,198-199`：`surfaceContainerHighest@50%`）——**刻意对齐行为**（参考版真模糊我方无 HazeState 等价，回退而非缺失） |
| `custom_refresh_indicator.dart` | `AppPullToRefresh` | `:11-40` 注释声明对齐 SwipeRefreshLayout 参数（64dp/primary/2.5 线宽） |
| `book_cover.dart` | `CoilBookCover` | 前次报告：默认封面图 md5 字节级对齐（`9ebc9cd62e`） |
| `md3_fast_scroller.dart` | `FastScrollLazyColumn` 15 + `VerticalFastScroller` | 13 文件接线，快滚条形态对齐 |
| `md3_heatmap_calendar.dart` | `HeatmapCalendarComponents` | 用户授权特性（AGENTS 红线授权清单） |
| `md3_picker_sheet.dart` | `ColorPickerSheet`/滚轮选择语义 | `showMd3WheelPickerSheet` 走 `bottomSheetTheme` + `ListWheelScrollView`（`:1-14` 注释） |
| `ios_widgets.dart`（Ios 族） | settingItem 分组容器 + `SplicedColumnGroup` | `IosGroupedBody`（`:22-30` 注释：MD3 tonal 表面 + 大圆角分组容器，UI_MD3_PLAN 第八节）；设置页 9 屏已用（`settings_screen.dart:258`、`theme_config_screen.dart:639`、`webdav_settings_screen.dart:506`…） |
| `explore_kind_layout/action.dart` | `ExploreKind*` | 4 文件接线 |
| `app_navigation_bars.dart` | `AppNavigationBar` 2 | home_screen 单点接线 |
| `reader_settings_sheet.dart` 行内字体面板 | `FontSelectSheet` | 注释声明「Tt 入口行内展开形态，不再跳转整页字体管理」（对标参考版行内展开） |
| `help_markdown_builders.dart` 等 | `MarkdownBlock` 6 / `HtmlContent` 3 | 帮助/规则说明页 |
| `swipe_action.dart`（语义对齐但**未接线**，见 2.4） | `SwipeAction` 3 | — |

### 2.3 自造偏离（语义不同/变体）

| 我方 | 参考版 | 偏离点 |
|---|---|---|
| 3 个分组管理对话框：`book_source_group_manage_dialog.dart`（`source_screen.dart:25` 用）、`rss_group_manage_dialog.dart`（`rss_source_manage_screen.dart:27`）、`replace_rule_group_manage_dialog.dart`（`replace_rules_screen.dart:21`） | `GroupManageBottomSheet` 4（单一通用件） | **三份重复实现**：同构 CRUD + 拖拽排序底栏各造一套；`CustomGroupDialog`（5 文件：4 个导入确认屏 `*_import_confirm_screen.dart:153/173/175/179` + 定义）是第五个近亲 |
| 各域 sheet 自造壳（`reader_settings_sheet.dart:35` 用 `DraggableScrollableSheet` 自包、`change_chapter_source_sheet.dart:28` 自定 28dp 圆角） | `AppModalBottomSheet` 91（统一壳） | 视觉靠 `bottomSheetTheme` 兜住，但**结构参数**（拖拽尺寸/isScrollControlled/把手开关）各域自定 |
| 顶栏 glass/liquidGlass **实色回退**（`top_bar_button.dart:198-199`） | 真 Haze/液态玻璃（`AppScaffold.kt:63-92`） | 我方无模糊采样等价；回退方案已注释声明，属**已裁决的偏离**（勿改回，除非做真模糊） |
| `reader_comic_screen` 硬编码暗色占位（前次报告 §1.2） | 主题色环 + 素材图 | 前次报告已列裁决点，本报告不重复 |
| `CustomProgress`（`custom_progress.dart`，全仓无调用方） | — | 死代码（前次报告已列，随统一批清理确认） |
| 多选管理 = `bookshelf_manage_screen` Checkbox 管理屏 | `DraggableSelectionHandler` 长按拖选 + `SelectionBottomBar` | 交互形态不同（我方无长按拖选）；**功能级差异**，是否对齐需用户裁决 |

### 2.4 自造孤儿组件（封装已建、零生产接线，仅 `test/widget/*_test.dart` 引用）

| 我方文件 | 对应参考版 | 处置 |
|---|---|---|
| `pill_divider.dart`（`:12`，注释声明对齐 HapeLee PillDivider 2dp/20%/outlineVariant60%） | `PillDivider` **14 文件** | 参考版真实需求（设置行内分隔），**建议接线** |
| `search_bar_widget.dart`（`:6`，带清除/提交的搜索栏） | `SearchBar` 16 | 需与 `DynamicSearchAppBar`（explore/rss 已用）合并定位，**建议接线或并入** |
| `swipe_action.dart`（`:16`，列表滑出操作） | `SwipeAction` 3 + `Container` 2 | 接线或删 |
| `source_card.dart` / `tag_chip.dart` / `badge_widget.dart` / `chapter_tile.dart` | `TextCard` 38 / `SearchBookTagChip` 3 / — / — | 4 件低优，**接线或删除需用户裁决**（删除=资产清理红线） |

---

## 三、统一候选清单（对齐收益 = 参考版引用面 × 我方偏离度）

| # | 组件 | 参考版语义/参数 | 我方现状（散用面） | 建议动作 | 量级 |
|---|---|---|---|---|---|
| 1 | **AppTextField** | 58 文件；Inside label 自定义 surface、`keyboardOptions`、前后缀图标 | `TextField(` 123 处/59 文件散用；**无 textInputTheme**；`InputBorder.none` 9 文件 + 自定 hintStyle 10+ 文件 | 新建 `AppTextField`（统一 border/hint/label 参数面 + 补 `textInputTheme`），先收敛 9+10 个偏离点，再批量替换 | **L** |
| 2 | **AppScaffold** | 59 文件；HazeState 模糊 + 背景图透明化 + edge-to-edge + snackbarHost + FAB 位 | `Scaffold(` 73 处/70 文件裸用；系统栏仅 `system_bar_binder` 单点；无页壳 | 新建 `AppScaffold` 轻量壳（背景/安全区/snackbarHost 统一 + edge-to-edge 策略）；**模糊/液态玻璃明确不做**（维持 TopBarButton 实色回退既有裁决） | **L** |
| 3 | **AppAlertDialog** | 74 文件；`show` 受控 + confirm/dismiss 默认 | `AlertDialog(` 126 处/62 文件 + `showDialog` 180 处 + 20+ 自造 dialog 类；`dialogTheme` 已 token 化 | 新建 `showAppDialog`（受控壳 + 按钮行对齐 `ConfirmDismissButtonsRow`），`ConfirmDialog` 并入，自造 dialog 逐个接线 | **M** |
| 4 | **AppModalBottomSheet** | 91 文件；统一壳（title/动作/手势/尺寸动画） | `AppBottomSheet` 已存在仅 1 处接线；各域 sheet 自造壳 10+；`bottomSheetTheme` 已 token 化 | **接线既有 `AppBottomSheet`**（扩 `showAppBottomSheet` 静态入口，吸收 DraggableScrollableSheet 参数），各域 sheet 逐批换壳 | **M** |
| 5 | **settingItem 行语义族** | `Clickable` 20 / `Switch` 16 / `Slider` 12 / `Input` 7 / `DropdownList` 11 / `CheckboxItem` 11 | 设置页分组容器已统一（`IosListTile` 86 处/7 文件）；行语义散用 `SwitchListTile`/`CheckboxListTile`/裸 `Slider`（设置 4 屏：settings/theme_config/webdav/other） | 补 4 个行语义件（`SettingSwitchRow`/`SettingSliderRow`/`SettingInputRow`/`SettingDropdownRow`，基于 `IosListTile` 壳），设置 4 屏接线 | **M** |
| 6 | **AppFloatingActionButton** | 25；primaryContainer/primary 默认 | `FloatingActionButton(` 9 处/7 文件；FAB theme 已 token 化 | 新建 `AppFAB`（薄封装 + 位置规范），7 处接线 | **S** |
| 7 | **RoundDropdownMenu** | `Menu` 50 + `Item` 58；圆角/4dp 阴影/8dp 行距 | `DropdownMenuItem(` 15 处/7 文件（原生 DropdownMenu） | 新建圆角下拉菜单族（对齐 `RoundDropdownMenu` 参数面），7 文件接线 | **S-M** |
| 8 | **GroupManageBottomSheet 合并** | 4；单一通用件 | 3 个自造 group manage dialog + `CustomGroupDialog`（共 5 份近亲，3 屏使用） | 合并为 1 个通用分组管理底栏（参数化标题/数据源），3 屏回归 | **S** |
| 9 | **孤儿组件接线批** | `PillDivider` 14 / `SearchBar` 16 / `SwipeAction` 3 | 7 个孤儿（2.4 节） | 接线 `PillDivider`（设置行内分隔真实需求）；`SearchBarWidget` 并入搜索方案；其余 5 件**提请用户裁决**接线或删除 | **S** |
| 10 | **AppTabRow** | 15 + 12；标签行统一 | `TabBar(` 10 处/7 文件；`tabBarTheme` 已 token 化 | 可选：薄封装 `AppTabRow`（滚动/吸顶参数统一）；收益低可维持现状 | **S** |
| 11 | **维持现状（不立项）** | `AppText` 142 / `AppIcon` 40 / `GlassCard` 56 / `CoilBookCover` 21 / `LoadMoreFooter` 5 / 进度三件套 39 | 我方 typography/图标/卡片 token 已统一（`app_theme.dart`）；`EmptyState`/`BookCover`/`Md3FastScroller`/`ContainedLoadingIndicator`/`TopNetworkLoadingBar`/`CustomRefreshIndicator`/`LegadoAppBar`/`TopBarButton`/`Md3HeatmapCalendar`/`explore_kind_*`/`app_navigation_bars` 已对齐 | **零改动**（已对齐件清单即「勿误改清单」，见 §4.1） | — |

### 3.1 总量级

- 统一机会合计：**2×L（TextField、Scaffold）+ 2×M（Dialog、BottomSheet、settingItem 行族）+ 4×S（FAB、RoundDropdownMenu、GroupManage 合并、孤儿接线）**。
- 无 FFI/契约影响；无 Rust 轨变更；回归面 = 涉及屏的加载/输入/弹窗/底栏走查。

---

## 四、风险与建议批次

### 4.1 勿误改清单（触碰已裁决/已对齐实现的「统一」陷阱）

| 项 | 判断 | 依据 |
|---|---|---|
| 加载三件套 + 4 件 expressive 件（`app_progress_indicator.dart`、`md3_loading_indicator.dart`、`skeleton.dart`、`contained_loading_indicator.dart`、`list_footer.dart` 的 `TopNetworkLoadingBar`） | **保留**（前次报告 §4.3 已裁决：对齐 HapeLee/UI_MD3_PLAN 签名，授权 expressive） | 前次报告 + 文件头注释 |
| `EmptyState` 颜文字池 | **保留**（逐字对齐 + 用户授权彩蛋，AGENTS 红线授权清单） | `empty_state.dart:50` + AGENTS「重构红线」节 |
| `LegadoAppBar`/`TopBarButton` 5 档样式（含 glass/liquidGlass **实色回退**） | **保留**（回退是已裁决的无 Haze 等价方案；做真模糊是**新特性**，须用户批准） | `top_bar_button.dart:84-85,198-199` 注释 |
| `CustomRefreshIndicator` 参数（64dp/primary/2.5） | **保留**（对齐 SwipeRefreshLayout 实测参数） | `custom_refresh_indicator.dart:11-40` 注释 |
| `BookCover` 默认封面图 | **保留**（md5 字节级对齐原版） | 前次报告 §3.1（`9ebc9cd62e`） |
| `md3_heatmap_calendar` | **保留**（授权特性） | AGENTS 红线授权清单 |
| `reader_settings_sheet` 行内字体面板 | **保留**（对标参考版 Tt 行内展开形态，刻意设计） | `reader_settings_sheet.dart:48-51` 注释 |
| 3 个 group manage dialog 合并 | 合并本身低风险，但**必须回归 3 屏**（source/rss_source_manage/replace_rules）+ `CustomGroupDialog` 4 导入屏 | §2.3 |
| 功能级缺口（privacy/BgEffect/VariableEditor/ValueStepper/ConflictSheet/长按拖选/player 域） | **不立项**（AGENTS「未经允许禁止新增功能」红线；若做须用户逐条裁决） | AGENTS「重构红线」节 |
| `reader_comic_screen` 硬编码暗色 + `CustomProgress` 死代码 | 前次报告 §4.1-4 裁决点，**随加载批处理，不在本调研范围** | 前次报告 |

### 4.2 建议批次（按依赖排序，每批 patch 递增 + CHANGELOG + 台账回写，遵循 AGENTS 规范）

| 批 | 内容 | 量级 | 说明 |
|---|---|---|---|
| **B1** | 孤儿组件裁决接线：`PillDivider` 接入设置行内分隔（真实需求 14 屏对应面）；`SearchBarWidget` 并入搜索方案；`SwipeAction` 接线或删除（用户裁决）；其余 4 件（source_card/tag_chip/badge/chapter_tile）提请用户裁决 | S | 无视觉变更风险，先清库存 |
| **B2** | 弹窗壳统一：`showAppDialog`（受控 + 按钮行对齐参考版）+ 既有 `AppBottomSheet` 扩 `showAppBottomSheet` 静态入口；`ConfirmDialog` 并入；先接高频面（关于/设置/导入 4 屏） | M | 视觉靠既有 dialogTheme/bottomSheetTheme 兜底，风险低 |
| **B3** | `AppTextField` 统一输入框 + 补 `textInputTheme`：先收敛 9 个 `InputBorder.none` + 10+ 自定 hintStyle 偏离点，再批量接线 59 文件（可脚本化 diff 复核） | L | 输入框是全局最高频控件，单独成批 |
| **B4** | `AppScaffold` 页壳：统一背景/安全区/snackbarHost/edge-to-edge 策略，70 屏分批接线（先主 Tab 4 屏 + 设置 4 屏）；**不做模糊**（维持实色回退裁决） | L | 最大面，最后做，避免与 B2/B3 同屏冲突 |
| **B5** | 设置行语义族（`SettingSwitchRow`/`SettingSliderRow`/`SettingInputRow`/`SettingDropdownRow`）+ `AppFAB` + `RoundDropdownMenu` + GroupManage 3+1 合并 | M | 可与 B2 并行（文件不重叠：B2 动 dialog 类，B5 动 settings 4 屏 + 7 处 FAB） |

> 冲突避让：B2 与 B5 均触碰 `settings_screen`/`about_screen` 等，按「文件不重叠」原则 B2 先行、B5 随后；B3/B4 与 B2/B5 无文件重叠可并行，但受 AGENTS「子代理并行上限 = 2」约束，建议 B1→B2→B5→B3→B4 串行推进。

---

## 附：证据索引（关键 file:line）

**参考版**（`legado-with-MD3/app/src/main/java/io/legado/app/ui/widget/components/`）
- 顶层签名：`AppScaffold.kt:41`、`AppTextField.kt:37/293`、`AppFloatingActionButton.kt:60`、`SplicedColumnGroup.kt:43`、`SearchBar.kt:42`、`AppPullToRefresh.kt:33`、`AppSlider.kt:14`、`SectionTitle.kt:14`、`LoadMoreFooter.kt:43`、`EmptyMessage.kt:33`
- 子目录签名：`modalBottomSheet/AppModalBottomSheet.kt:48`、`alert/AppAlertDialog.kt:33`、`menuItem/RoundDropdownMenu.kt:38`、`RoundDropdownMenuItem.kt:44`、`topbar/GlassMediumFlexibleTopAppBar.kt:45`、`TopBarButton.kt:276/305`、`card/GlassCard.kt:116/144`、`icon/AppIcon.kt:29`、`card/TextCard.kt:27`、`image/cover/CoilBookCover.kt:238`、`settingItem/ClickableSettingItem.kt:17`、`SwitchSettingItem.kt:20`、`SliderSettingItem.kt:48`、`button/ConfirmDismissButtonsRow.kt:15`、`dialog/ColorPickerSheet.kt:51`、`tabRow/AppTabRow.kt:19`、`CardTabRow.kt:28`、`divider/PillDivider.kt:21`、`checkBox/CheckboxItem.kt:21`、`list/ListUiState.kt`、`rules/RuleListScaffold.kt:40`、`text/AppText.kt:22`、`AnimatedText.kt:92`、`lazylist/LazyList.kt:60`、`button/AppButton.kt`（`PrimaryButton`/`SecondaryButton`）、`filePicker/FilePickerSheet.kt:22`
- 引用计数：全部 `grep -rlw <符号> --include="*.kt"` 实测（29 顶层数字与主代理预统计一致；子目录按实际符号名重测，文件名≠符号名的坑已列明）

**我方**（`flutter_legado/lib/`）
- 主题层统一：`src/theme/app_theme.dart:214`（ThemeData）、`:218`（textTheme）、`:281`（cardTheme）、`:381`（FAB）、`:392`（dialogTheme）、`:403`（bottomSheetTheme）、`:414`（tabBar）、`:427/:437`（popup/dropdown）、`:479`（chip）、`:498/:515/:529`（switch/checkbox/radio）、`:540`（slider）、`:557`（searchBar）——**无 textInputTheme**
- 封装件：`src/widgets/legado_app_bar.dart:24`（66 文件引用）、`top_bar_button.dart:5-8/84-85/198-199`、`bottom_sheet_widget.dart:4`（接线仅 `screens/file_manage_screen.dart:149-150`）、`confirm_dialog.dart:14`、`custom_refresh_indicator.dart:11-40`、`empty_state.dart:50`、`app_progress_indicator.dart:4-9`、`ios_widgets.dart:22-30`（Ios 族）、`md3_picker_sheet.dart:1-14`、`pill_divider.dart:12`（孤儿）、`search_bar_widget.dart:6`（孤儿）、`swipe_action.dart:16`（孤儿）
- 散用实测：`Scaffold(` 73/70、`TextField(` 123/59、`AlertDialog(` 126/62（`showDialog*` 180/63）、`FloatingActionButton(` 9/7、`RefreshIndicator(` 13/12、`Slider(` 29/14、`Checkbox(` 20/14、`Switch(` 12/11、`Chip(` 48/16、`TabBar(` 10/7、`DropdownMenuItem(` 15/7、`ReorderableListView` 5/5、`Text(` 2277/159、`SnackBar` 89 文件（2.1 表全量）
- 设置屏：`screens/settings_screen.dart:258-428`（Ios 族用法）、`theme_config_screen.dart:639`、`webdav_settings_screen.dart:506`、`other_settings_screen.dart`
- 孤儿测试：`test/widget/{badge_widget,chapter_tile,source_card,tag_chip,search_bar_widget,swipe_action}_test.dart`

编写者：调研员 ｜ 2026-09-30（STAGE-R-GLOBALCOMP 只读调研）
