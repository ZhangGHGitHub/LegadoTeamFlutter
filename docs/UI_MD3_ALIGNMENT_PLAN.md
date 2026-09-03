# UI 风格对齐 HapeLee/legado-with-MD3 实施方案

> 版本：v1.1 ｜ 日期：2026-09-04 ｜ 编写：Qoder ｜ 状态：已批准（Plan v1.1）
> 参考目标：https://github.com/HapeLee/legado-with-MD3 （锚点 6dc2972，已消费至本地；当前 HEAD 0ce6805 同结构）
> 关联规范：`docs/design_system.md`（MD3 token 单一事实源）、`docs/LEGADO_M3_TOKEN_SPEC.md`、`docs/LEGADO_M3_COMPONENT_MAPPING.md`、`docs/UI_MD3_PLAN.md`、`docs/API_CONTRACT.md`、`docs/TWO_TRACK_DEV_SPEC.md`

---

## 一、背景与目标

Legado Flutter 侧已在 `UI_MD3_PLAN.md` B0–B6 七批次完成 iOS HIG → Material Design 3 Expressive 的视觉切换，`lib/src/theme/md3_colors.dart` 由 `tool/gen_md3_colors.py` 逐字拷贝 HapeLee `6dc2972` 的 `values/colors.xml(697 行)+values-night/colors.xml(616 行)`，12 套×47 role tonal 调色板与 `AppTheme.palette()` 装配已对齐。

本方案回答：**若需与 HapeLee/legado-with-MD3 风格 90–98% 同步，还需改哪些界面？Rust 侧是否要动？iOS 兼容如何保障？**并给出可执行的分批计划。

**目标**：在保留全部现有功能（含自定义 4 色 `themeConfigList`、底栏皮肤、响应式双栏）前提下，使 `flutter_legado` 的视觉层与 HapeLee MD3 Expressive 签名一致，且在 Android / iOS / Windows 三端均可构建、可交互、可无障碍通过。

**约束**：

- 界面功能/页面结构/交互流程与 Android 原版一致，视觉风格按 `AGENTS.md` 自由走 M3（2026-08-05 用户确认）。
- 无 FFI 破坏性变更；新增 FFI 需先冻结 `docs/API_CONTRACT.md`（本方案 Rust 侧仅 2 个可选透传点，不新增 FFI）。
- 新建计划/报告类 `.md` 入 `docs/`，根目录仅保留约定文件。
- Windows 无 `make`，命令一律 CMD/PowerShell；`flutter analyze 0 issues + flutter test 全绿` 为每批门禁。

---

## 二、已确认约束（冻结，Plan v1.1 定版）

| 维度 | 定案 |
|---|---|
| 对齐范围 | 90–98% 复刻 HapeLee，仅部分界面需改（已发现例：`change_source_screen`）；排除清单不在计划期冻结，开发时逐屏发现、逐项登记 |
| 自定义主题 | 保留并存（12 套内置 MD3 preset + `themeConfigList` 4 色+bgImage，自定义已应用色优先） |
| iOS 手势 | 视觉统一 MD3，手势兼容（侧滑返回 + Home Indicator 避让 + 键盘顶起，其余统一 MD3） |
| 阅读器工具栏 | `readBarStyleFollowPage` 双轨保持（开=跟纸张色，关=跟 tonal surface） |
| Rust | **R1+R2 都做**（`get_theme_config` 默认值对齐 `wh #5C5C5C` + `get_theme_mode` 读库跟随系统） |
| 批次 | **审计后压到 3 批**（Phase 0 审计 → B0 地基必独立 → 主链 → 长尾，Rust 随 B0） |
| iOS 门禁 | **以 CI 为准**（`ios-build.yml` 的 macOS runner 异步结果，Windows 本地不跑 `flutter build ios`） |
| Git 分支 | `feature/ui-md3-align-*` → 集成 `integration/ui-md3`；仅从当前 HEAD 创建，不得改历史（`AGENTS.md` 分支策略） |

---

## 三、Git 卫生（开工前必做，当前不干净）

**现状**（只读探测 2026-09-04）：`master` 领先 `origin/master` 1377 commits；工作区 30 个 `M`（全为 `*.g.dart/*.freezed.dart` 生成代码的 LF/CRLF 差异）+ 21 个未跟踪（含 `docs/UI_MD3_ALIGNMENT_PLAN.md` 未入索引、`docs/UI_MD3_GAP_REPORT_20260903.md`、`.tmp/legado-with-MD3` 克隆、`flutter_legado/tool/fix_info_lints.ps1` 等）；暂存区空。

**开工前清洁**（不属本方案实现，仅前置）：

1. 生成代码 30 个 `M`：`dart run build_runner build --delete-conflicting-outputs` 重跑后 `git diff --stat` 归零，或确认仅换行符后 `git restore --worktree` 回退；
2. 未跟踪：`docs/UI_MD3_ALIGNMENT_PLAN.md` 入索引（本计划 v1.1 升版时一并提交），`.tmp/legado-with-MD3` 保持 `.gitignore` 忽略，`tool/*.ps1` 按需 `git add`；
3. 新分支仅从当前 HEAD 创建，不得改历史。

---

## 四、目标仓库风格画像（HapeLee/legado-with-MD3）

| 维度 | 特征 |
|---|---|
| 锚点 | `6dc2972`（本地已消费）；当前 HEAD `0ce6805 refactor: 清理 View 体系死代码，遗留弹层迁移 Compose`，同属同一 MD3 结构，无 role 变更 |
| 颜色 | 12 套前缀 `gr_/wh_/lemon_/koharu_/sora_/august_/carlotta_/mujika_/yuuka_/phoebe_/transparent_/elink_`，每套 47 role（含 `primary/secondary/tertiary/error + background/surface/surfaceVariant/outline + inverse + Fixed/FixedDim/Variant + surfaceDim/Bright + surfaceContainerLowest/Low/Container/High/Highest`），命名 `{id}_theme_{role}`；亮面 `surface ~ #F8F8F8–#FFF8F7` 高明度，暗面 `surface #141313–#1A1111–#111318` 着色深灰，仅 `elink` 暗面纯黑 |
| 主题 | `Base.AppTheme parent Theme.Material3Expressive.DynamicColors.DayNight.NoActionBar` + 12 个 `Theme.Base.{GR…Elink}+Transparent` 各覆写 35+ M3 attr；`values-night/themes.xml` 仅 52 行，颜色由夜间 `colors.xml` 驱动 |
| 样式 | `styles.xml` 72 行：`Widget.App.TabLayout(tabIndicator stretch+secondaryContainer, tabTextColor onSurfaceVariant, selected onSecondaryContainer)`、`Widget.MyApp.Chip.Assist → chip_background_selector(secondaryContainer)`、`AppTheme.AlertDialog(dialogCornerRadius 28dp, colorBackground surfaceContainerLow)` |
| 依赖 | `material 1.14.0` + `compose.material3 1.5.0-alpha23(Expressive)` + `materialKolor 4.1.1` + `haze` + `miuix`，`compileSdk 37, minSdk 26, targetSdk 37, JVM 21` |
| 布局 | View+Compose 混合，已 Compose 化，仅 `dialog_*/view_title_bar/view_search/preference_theme_card/item_theme_card` 遗留 View；`drawable` 含 `bg_surface_variant/bg_textfield_search/popup_background/fastscroll_*` |
| 与本地关系 | 本地 `tool/gen_md3_colors.py` 的 `SOURCE_COMMIT=6dc2972` 逐字拷贝即权威源，`transparent` 缺 `surfaceContainerLow` 有回补逻辑；`AppTheme.palette()` 复现 `ThemePackageManager` 的自定义 4 色优先级与 `surfaceTint/_onColor` |

---

## 五、本地现状与差距研判

| 维度 | 本地现状 | 结论 |
|---|---|---|
| 调色板 | `lib/src/theme/md3_colors.dart` 12 套×47 role，`test/unit/md3_palette_test.dart` 守护对比度 ≥4.5（`elink 3.95/AA-large` 例外、`transparent` 豁免） | 已对齐，仅需追一次 `6dc2972→0ce6805` 的 `colors.xml` diff |
| Theme 装配 | `lib/src/theme/app_theme.dart: AppTheme.palette(brightness, palette, primary/accent/background/bottomBackground)` + `app_typography.dart` 15 级 M3 type scale；Tonal Surface 映射 `Scaffold/AppBar→surface / Card→亮 surfaceContainerLowest/暗 Low / NavBar/Menu→surfaceContainer / BottomSheet→surfaceContainerLow / Dialog→surfaceContainerHigh / 输入框→surfaceContainerHighest / 指示器→secondaryContainer`；圆角 `card 20/control 12/extraLarge 28/menu 16/fab 16/按钮 Stadium` | 已对齐，Expressive 无 preset 需 componentTheme 显式落地（已做） |
| 组件 | `app_theme.dart` 已补全 `Card/Button/Input/ListTile/Divider/FAB/Dialog/BottomSheet/TabBar/Popup/SnackBar/Tooltip` 的 componentTheme | 局部遗漏：少量页面未消费 Theme，仍硬编码 `Colors.*`/`AppColors` |
| 页面 | `lib/src/screens/` 81 文件=66 逻辑屏+15 part，`lib/src/widgets/` 54 文件；`ios_widgets.dart` Batch 0 已原地转 MD3（`Card+outlineVariant 分隔+primaryContainer 图标块+32×4 grabber`，类名 `Ios*` 仅 shim） | 核心差距：少量 token 未消费 + 1 个 Cupertino 孤岛，非 60 屏重做；精确清单由 Phase 0 审计产出 |
| 图标 | `material_symbols_icons ^4.2960.0` + `flutter_svg`，`cupertino_icons` 逐步退役；`CupertinoAlertDialog×1/CupertinoPicker×2` 已清 | 仅剩 `review_detail_sheet` 15 行 Cupertino 孤岛待清 |

---

## 六、iOS 与阅读器口径（详细解释）

### 6.1 iOS 视觉

HapeLee 纯 Android（`Theme.Material3Expressive.DynamicColors.DayNight + values/colors.xml 697 行 + values-night 616 行 + styles.xml TabLayout/Chip/Dialog`，`materialKolor/haze/miuix`）无 iOS 分支；本地 Flutter 在 iOS 跑同一套 Material 是按 `AGENTS.md`“视觉自由走 M3”的预期。`ios_widgets.dart` 235 行 5 组件已原地转 MD3 shim（`Card surfaceContainerLowest/Low 20dp + Divider outlineVariant + 32×32 primaryContainer 图标块 + 32×4 grabber`），`AppTheme` 无 `Platform.isIOS` 分支，`Platform.isIOS` 24 命中均属能力分叉（TTS/亮度/深链/缓存），无 UI 分支。`transparent` 保持静态 `00FFFFFF` 不引壁纸取色，`elink 3.95` 按 `AA-large` 豁免，VoiceOver 复用 `调色板中文标签语义化+底栏≥48dp`。

| 维度 | HapeLee（Android） | 本地 Flutter（iOS 实际） | 对齐动作 |
|---|---|---|---|
| 主题父 | `Theme.Material3Expressive.DynamicColors.DayNight.NoActionBar` + 12 个 `Theme.Base.*` 各覆写 35+ M3 attr | `ThemeData(useMaterial3:true, ColorScheme from Md3Palettes)`，无 `Platform.isIOS` 分支 | 保持跨平台一致 |
| 颜色 | 12 套 tonal，亮 `surface ~#F8F8F8` 暗 `surface #141313` 着色深灰，仅 `elink` 暗纯黑；`transparent` 大量 `B0FFFFFF/00FFFFFF` 半透明 | 同源（逐字拷贝），`transparent` 缺 `surfaceContainerLow` 有回补逻辑 | Batch 0 追一次 `6dc2972→0ce6805` diff 并重跑 `gen_md3_colors.py` |
| 形状 | Expressive 大圆角无 preset，需显式 `28dp Dialog/20dp Card/12dp control/Stadium 按钮` | `AppTheme._cardRadius 20/_control 12/_extraLarge 28` 已显式落地 | 校验 `ios_widgets.Card` 与 `Dialog/BottomSheet 28dp` 取值一致 |
| 分组列表 | `preference_theme_card/item_theme_card` + `view_title_bar/view_search` 遗留 View | `IosGroup(Card surfaceContainerLowest/Low,20dp)+Divider outlineVariant+ListTile+32×32 primaryContainer 图标块` | 已完成，仅核对 token 取值 |
| 导航 | `NavigationBar surfaceContainer + pill secondaryContainer 80dp` | 同规，`NavigationBarTheme` pill 已配 | 校验选中 `onSecondaryContainer`/未选中 `onSurfaceVariant`，`transparent/elink` 例外 |
| 状态栏 | `values-night/themes.xml` 仅 52 行，`windowLightStatusBar true/false` | `AppBarTheme.systemOverlayStyle` 按 `brightness` 决定 + `SystemBarService` 仅 Android 设 `edgeToEdge`，iOS 靠 Flutter 默认 | iOS 真机核 `system/light/dark` 三档图标亮暗 |
| 手势/安全区 | Android 无侧滑返回概念 | iOS 需侧滑返回 + `SafeArea(top:false)` + `BottomSheet SafeArea(bottom:true)+IosGrabber 32×4` + 键盘顶起 | 视觉统一 MD3，手势兼容：路由仍 `MaterialPageRoute`（Flutter 在 iOS 自动启用 `CupertinoBackGesture`，不改路由） |
| 壁纸/纯黑 | `transparent` 配合壁纸、`elink` 纯黑灰阶暗面、`DynamicColors` 种色 | `transparent` 保持静态 `00FFFFFF` 复刻，不引入壁纸取色 | 不引入 `materialKolor` |
| 无障碍 | — | `调色板中文标签语义化+底栏≥48dp` 已落地，`md3_palette_test.dart` 守护 `≥4.5/large 3.0` | iOS VoiceOver 复用同一语义 |

**三类风险与对策**：

| 类别 | 风险 | 对策 |
|---|---|---|
| A. 构建/启动 | Xcode 16 链接器 + Release strip 复发；`material_symbols_icons` 单 glyph 缺字；`transparent` 全透明 Scaffold 在 iOS 暗色异常 | Batch 0 追加 `flutter build ios --no-codesign` 门禁；`md3_colors.dart` 追新时校验 `transparent→surfaceContainerLow` 回补在 iOS 暗色不产生全透明；Symbols 缺字由 `material_symbols_icons ^4.2960.0` 兜底 |
| B. 交互/手势 | iOS 侧滑返回、Home Indicator 遮挡、键盘顶起 BottomSheet、`ScrollPhysics` 回弹、`windowLightStatusBar` 在 iOS 由 `SystemChrome` 而非 `values-night/themes.xml` 驱动 | 路由仍 `MaterialPageRoute`（自动 `CupertinoBackGesture`，不改路由）；所有 BottomSheet 包 `SafeArea(bottom:true)+IosGrabber`；校验 `offline_cache/cache_download/manga_config` 长表单在 iPhone SE 小屏不被键盘遮挡；`system_bar_notifier.dart` 联动 `themeMode`，真机核对三档 |
| C. 视觉/无障碍 | `transparent` 壁纸在 iOS 无壁纸取色；`elink` 纯黑 OLED 对比度 3.95 按 `AA-large` 豁免；VoiceOver 标签在 card 分组中丢失 | `transparent` 保持静态 `00FFFFFF` 复刻；`md3_palette_test.dart` 的 `transparent 豁免+elink 3.95` 在 iOS 同生效；复用既有语义 |

### 6.2 阅读器

`reader_screen/reader_comic_screen` 为沉浸式飞地（`Scaffold.backgroundColor = ReaderState.backgroundColor` 5 档 `白/绿/棕/护眼/夜间` + 16 色自定义，`SystemChrome manual` 自管，不消费 `ColorScheme`；漫画硬编码 `Colors.black/0xCC000000` 纯黑画廊），`UI_MD3_PLAN.md` 已冻结“正文区不走 tonal”。仅 `reader_top_bar/bottom_bar/read_aloud_bar/change_chapter_source_sheet` 按 `readBarStyleFollowPage` 双轨（开=纸张色，关=tonal surface），`reader_config_panel` 8 处 `colorScheme` 可随 MD3 变色。

| 区域 | 是否跟 tonal | 原因 | 对齐动作 |
|---|---|---|---|
| 正文排版（`reader_page_view/text_content/page_chrome/status_strip`） | 否 | 纸张语义与 `surface/surfaceContainer` 正交；硬套 tonal 会抹掉用户纸张 | 保持 `ReaderState.backgroundColor/textColor` 自管 |
| 漫画（`reader_comic_screen`） | 否 | 纯黑画廊 `Colors.black/0xFF1A1A1A/0xCC000000` 与 MD3 暗面 `surface #141313` 非同色 | 保持纯黑，不纳入 |
| 工具栏（`reader_top_bar/reader_bottom_bar/read_aloud_bar/change_chapter_source_sheet`） | 双轨 | `readBarStyleFollowPage=true` 时 `followColor=state.backgroundColor`，`false` 时 `Theme.surface` | 保持双轨语义，仅校验取值与 `scrolledUnderElevation` |
| 配置面板（`reader_settings/padding/tip_config_sheet`） | Sheet 容器跟 tonal，内容色板保持纸张 | Sheet 容器 `BottomSheetTheme surfaceContainerLow 28dp` 为 M3，色板 16 色为纸张选择器 | 已部分落地，校验边框 `primary/outlineVariant` |
| 段评/帮助 | 否（沉浸域排除） | `review_detail_sheet/column` 的 `CupertinoColors` 属沉浸域，按计划“不改” | 若移出排除清单则单独立项（当前保持排除） |

**Rust 透传**：`config_api.rs:get_read_book_config` 默认 `#FFFFFF/#333333` 与 Flutter 5 档两套源，`get_theme_config` 旧 `#FF4CAF50` 与 MD3 无关；仅当 JS 书源依赖主题时改 R1/R2（见第七节），否则不动。

---

## 七、需修改界面清单（文件级，Phase 0 精确化前为参考）

> 按 `LEGADO_M3_COMPONENT_MAPPING.md` 10 界面映射 + 新增页分组；精确清单由 Phase 0 审计产出，以下为参考基线。

### A. 全局壳与导航（4 文件）— P0

| 文件 | 当前 | 目标 | 改动点 |
|---|---|---|---|
| `lib/src/screens/home_screen.dart` | NavigationBar 已 80dp，pill 指示器待核 `secondaryContainer/onSecondaryContainer` | HapeLee `NavigationBar surfaceContainer + pill secondaryContainer, labelBehavior alwaysShow` | 校验 `NavigationBarTheme` 高度/指示器 shape，选中 `onSecondaryContainer`/未选中 `onSurfaceVariant`；`transparent/elink` 例外 |
| `lib/src/screens/settings_screen.dart`（我的 Tab） | 部分 IosGroup，硬编码 `AppColors` | `Card(surfaceContainerLowest/Low, radius 20, elevation 0)` 分组，图标 `onSurfaceVariant` | `IosGroup→Card`，`ListTile` 套 `design_system.md §5` |
| `lib/src/screens/theme_config_screen.dart` | 主题卡片已部分 M3 | `preference_theme_card/item_theme_card` 对齐原生卡片：`surfaceContainer` + 28dp Dialog 预览 | 卡片选中态 `primaryContainer` 边框，`transparent/elink` 预览特殊处理 |
| `lib/src/screens/welcome_screen.dart` / `welcome_config_screen.dart` | 引导页旧式按钮 | `FilledButton(primary/onPrimary, Stadium)` + `surface` 背景 | 按钮、间距 token、字阶对齐 |

### B. 书架/书籍（12 文件）— P0

`bookshelf_screen.dart`、`book_info_screen{,_builders,_dialogs,_load}.part.dart`、`bookshelf_manage_screen.dart`、`book_group_screen.dart`、`edit_book_info_screen.dart`、`toc_screen.dart`、`bookmark_screen.dart`、`remote_book_screen.dart`

- `bookshelf_screen.dart`：`item_bookshelf_grid → Card(radius 20) + surfaceContainerLowest/Low`，Badge `Badge(primary)`，空态 `empty_state.dart` 套 `onSurfaceVariant`；网格/列表切换 `FilterChip(secondaryContainer pill)`。
- `book_info_screen.dart`：标题栏 `CenterAlignedTopAppBar(surface/onSurface, elevation 0, scrolledUnder 3, centerTitle false)`；封面 `book_cover.dart` + 信息分组 `Card`；操作区 `FilledButton/TonalButton Stadium`；删除确认 `AlertDialog(surfaceContainerHigh, 28dp)`。
- `toc_screen.dart`：`chapter_tile.dart` 选中态 `primaryContainer`，`tocRow` 高度/字级对齐 `LEGADO_M3_TOKEN_SPEC.md`；`md3_fast_scroller.dart` 仅校验 `fastscroll_bubble 88/44dp`。

### C. 发现/搜索/RSS（10 文件）— P1

`explore_screen.dart`、`explore_show_screen.dart`、`explore_kind_layout.dart|_action`、`search_screen{,_builders,_helpers,_scope_sheet}.part.dart`、`search_content_screen.dart`、`rss_screen.dart`、`rss_articles_screen.dart`、`rss_article_detail_screen.dart`、`rss_favorites_screen.dart`

### D. 阅读器（12 文件）— P0（沉浸式例外）

`reader_screen.dart`、`reader_comic_screen.dart`、`reader_config_panel{,_builders,_data}.part.dart`、`widgets/reader/*` — 仅 chrome 走 tonal，正文区保持用户配色（见 6.2）。

### E. 书源/规则/订阅（18 文件）— P1

`source_screen{,_actions,_builders,_widgets}.part.dart`、`source_edit_screen{,_actions,_builders,_dialogs,_load}.part.dart`、`source_debug_screen.dart`、`source_import_confirm_screen.dart`、`source_login_screen.dart`、`replace_rules_screen.dart`、`replace_rule_import_confirm_screen.dart`、`txt_toc_rules_screen.dart`、`highlight_rules_screen.dart`、`rule_sub_screen.dart`、`auto_task_screen.dart`

### F. 设置子页与其他（约 20 文件）— P1/P2

`other_settings_screen.dart`、`cache_settings_screen.dart`、`cache_download_screen.dart`、`offline_cache_screen.dart`、`read_aloud_config_screen.dart`、`read_record_screen.dart`、`file_manage_screen.dart`、`font_screen.dart`、`webdav_settings_screen.dart`、`browser_screen.dart`、`video_screen.dart`、`audio_screen.dart`、`app_log_screen.dart`、`dict_screen.dart`、`qrcode_screen.dart`、`about_screen.dart`、`import_screen.dart`、`bottom_bar_skin_screen.dart`、`bottom_bar_skin_assign_screen.dart`

### G. 通用 widgets（约 15 文件）— P0

| 文件 | 改动 |
|---|---|
| `lib/src/widgets/ios_widgets.dart` | 已转 MD3 shim，保留兼容，仅核对 token 取值 |
| `lib/src/widgets/legado_app_bar.dart` | 对齐 `AppBarTheme(surface/onSurface, elevation 0, scrolledUnder 3)` |
| `lib/src/widgets/book_cover.dart` / `book_list_item.dart` / `book_grid_item.dart` / `source_card.dart` / `chapter_tile.dart` / `tag_chip.dart` / `badge_widget.dart` / `swipe_action.dart` | 禁 `Colors.*`，一律 `colorScheme.*`；Chip 迁 `FilterChip/AssistChip(secondaryContainer)` |
| `lib/src/widgets/empty_state.dart` / `error_view.dart` / `loading_indicator.dart` / `md3_loading_indicator.dart` | 空态/错误/加载走 `onSurfaceVariant + primary` |
| `lib/src/widgets/confirm_dialog.dart` / `bottom_sheet_widget.dart` / `md3_picker_sheet.dart` / `export_dialog.dart` / `crash_log_dialog.dart` / `dict_dialog.dart` | Dialog 28dp `surfaceContainerHigh`，Sheet 28dp `surfaceContainerLow`，按钮 Stadium |
| `lib/src/widgets/help/help_markdown_styles.dart` | 标题/链接色跟随 `onSurface/primary` |
| `lib/src/theme/app_colors.dart` | 冻结为兼容层，新增代码禁引，存量逐步迁 `colorScheme` |

无需改：`md3_heatmap_calendar / md3_fast_scroller / md3_animated_text_line / custom_refresh_indicator` 已 M3；`manga_config_sheet` 登记为阅读器沉浸域排除。

---

## 八、Rust 侧改动（仅 2 个透传点，随 B0）

| # | 位置 | 现状 | 动作 | 优先级 | 工作量 |
|---|---|---|---|---|---|
| R1 | `rust/legado-js/src/host_api/config_api.rs: get_theme_config()` | 硬编码 6 字段旧默认值（`primaryColor #FF4CAF50` 等，与 MD3 `wh #5C5C5C` 不一致） | 默认值对齐 `wh` 调色板（`#5C5C5C/#F8F8F8`）或改读 `CacheRepository(config:themeConfig)`，避免 `getThemeConfig()` 与界面不一致 | P2 | ≤10 行 |
| R2 | `rust/legado-js/src/host_api/config_api.rs: get_theme_mode()` | 硬编码 `return "light"`，与 Flutter `ThemeMode.system/light/dark` 脱节 | 改为可注入：Flutter `setConfig("themeMode","0/1/2")` 写入 `caches(config:themeMode)`，Rust 侧读库（未写入回退 `"light"`），对齐 Kotlin `AppConfig.themeMode ?: "0"`；否则书源 `getThemeMode()` 永远 light | P1 | ≤10 行 |

不改：`rust/legado-ffi/src/api/config_api.rs`（`get_config/set_config/get_all_config` 通用 KV 已满足 `app_palette_id/themeConfigList/themeMode` 透传）、所有业务 crate、`paletteId` 的 `SharedPreferences` 持久化（本地独立于 Rust）。

---

## 九、分批实施方案

> 分支：`feature/ui-md3-align-*` 独立，集成 `integration/ui-md3`；每批 `flutter analyze 0 error + flutter test` 通过后再合；`ios_widgets` shim 保证回滚安全。

| 批次 | 内容 | 涉及文件 | 工期 | 优先级 |
|---|---|---|---|---|
| **Phase 0** | 增量差异审计 | `git diff 6dc2972..0ce6805 -- colors.xml` 判增量；全量 `grep` 产出精确待改清单；产出 `docs/UI_MD3_ALIGNMENT_AUDIT.md` | 1 天 | P0 |
| **Batch 0** | Token 地基 + Rust R1/R2 | Flutter：`gen_md3_colors.py` 重跑 + `md3_palette_test 22 组合`守护；Rust：R1/R2 各 ≤10 行；单 PR 触发 `rust-ci + flutter-ci` 双链 | 1 天 | P0 |
| **Batch A** | 主链域 | `home/theme_config/welcome/bottom_bar_skin` + `bookshelf/book_info/toc/bookmark/remote_book` + `reader chrome`；样板 `change_source_screen` 沉淀 checklist | 3 天 | P0 |
| **Batch B** | 长尾域 + 全域复核 + iOS 闭环 | 剩余增量屏（Phase 0 清单）+ `review_detail_sheet` Cupertino 清理（`manga_config_sheet` 保持排除）；`grep IosGroup` 仅 shim 内；`ios-build.yml` 异步 + 真机走查 | 3 天 | P1/P2 |

**合计**：Phase 0 1d + B0 1d + BA 3d + BB 3d ≈ **8 天**（含 CI 异步等待，不含分支清洁）。

> 附录：旧 60 屏全量清单已移至 `docs/UI_MD3_GAP_REPORT_20260903.md` 与本方案七节参考基线，不再作为批次输入。

---

## 十、验收标准

| 项 | 口径 |
|---|---|
| 静态门禁 | 每批 `flutter analyze 0 issues` + `flutter test` 全绿（含 `md3_palette_test.dart` 22 组合 ≥AA 4.5 + `md3_acceptance_matrix_test.dart` 渲染矩阵 `theme_config/home/settings/search × WH/koharu/sora × 亮暗`） |
| 对比度 | `test/unit/md3_palette_test.dart` 自动化守护；`transparent` 豁免、`elink 3.95` 按 `AA-large` 豁免已登记 |
| 截图 | 模拟器 `-CheckUI` 流程承担（Windows/Linux 字体差异不做 golden 二进制基线），以 `docs/baseline_android/` 功能一致为准，视觉不做像素级验收（`docs/UI_FIX_PLAN.md` 口径） |
| 冒烟 | `.\scripts\emulator_smoke_test.ps1 -Device emulator-5556`（子代理）+ `-Device emulator-5558 -CheckUI`（用户验收） |
| iOS | `ios-build.yml` 异步（90min 超时）+ 真机侧滑/键盘/Sheet/状态栏三档走查 + `grep -R Cupertino` 零新增；以 CI 为准，Windows 本地不跑 `flutter build ios` |
| Rust | B0 额外 `cargo test -p legado-js --features quickjs` |

---

## 十一、风险与回滚

- `transparent` 不引 `materialKolor` 壁纸取色；阅读器正文不走 tonal；`ios_widgets` shim 保证任一批可 `git revert`；`app_colors.dart` 冻结为兼容层分批迁；Windows 一律 CMD/PowerShell，BOM 坑沿用既有修复脚本。
- B0 为地基不可拆，A/B 按逻辑屏加锁，避免 `app_theme/ios_widgets` 热点并发冲突；单 PR 建议 ≤500 行（历史 B0 2639 行已为上限参考）。

---

## 十二、文档变更

- 本文件 `docs/UI_MD3_ALIGNMENT_PLAN.md` v1.0 → v1.1（并入已确认约束、iOS/阅读器口径、压到 3 批、Rust R1/R2 都做、以 CI 为准）。
- 新增 `docs/UI_MD3_ALIGNMENT_AUDIT.md`（Phase 0 产出）。

---

编写者：Qoder ｜ 2026-09-04

变更记录：
- v1.1（2026-09-04）：已批准 Plan v1.1 落盘。冻结已确认约束（90–98%、保留自定义、手势兼容+统一MD3、双轨、R1+R2、压到3批、以CI为准）；新增 Git 卫生与 iOS/阅读器口径详解；批次由 7 批压到 3 批（Phase 0 1d + B0 1d + BA 3d + BB 3d ≈8 天）；Rust R1/R2 随 B0；旧 60 屏清单移附录，精确清单由 Phase 0 审计产出。
- v1.0（2026-09-04）：初始方案（HapeLee 画像 + 60 屏清单 + iOS 兼容 + 6 批 14.5 天）。
