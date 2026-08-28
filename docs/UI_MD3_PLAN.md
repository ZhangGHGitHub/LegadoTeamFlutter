# Legado Flutter UI 迁移至 Material Design 3（Expressive）完整计划

> 角色：Flutter UI 负责人
> 职责边界：所有 Dart 代码（页面/组件/状态管理/路由/主题），通过 Rust Bridge 获取数据，不含业务计算逻辑。UI 层只做渲染、交互与状态管理。
> 参考目标：`https://github.com/HapeLee/legado-with-MD3`（Android/Kotlin MD3 Expressive + Material You 分支）

---

## 一、背景与定位

Legado 为 Rust + Flutter 跨平台阅读器，与 Android 原版双轨对齐。当前 `flutter_legado/` 的视觉语言已于 2026-08-05 从「M3 迁移」回退为 **iOS HIG**（见 `docs/design_system.md`）。本计划将其切换为 **Material Design 3 Expressive**，对齐参考仓库的视觉签名。

按 AGENTS.md：界面功能、页面结构、交互流程与原版一致；**UI 视觉风格允许自由改变**。因此本计划仅移植 MD3 **视觉层**，不引入参考仓库的 Android-only 功能。

## 二、目标与成功标准

**目标**：将 `flutter_legado/` UI 视觉语言从 iOS HIG 全面切换为 MD3 Expressive。

**成功标准**：
1. 全应用（除阅读器沉浸式屏）渲染为 MD3 Expressive；
2. 12 套命名主题可切换，每套含**着色亮+暗配对**（Material You tonal，非纯黑）；
3. `flutter analyze && flutter test` 通过——**含受影响 widget 测试的迁移**（见第九节）；
4. 模拟器冒烟 `-Device emulator-5556`（子代理）+ 用户验收 `-Device emulator-5558 -CheckUI` 通过；
5. `docs/design_system.md` 同步为 MD3 token **单一事实源**；
6. 保持既有**响应式/桌面双栏布局**行为不回归（有对应测试守护）；
7. 不破坏 FFI/Rust 契约（主题持久化为本地 SharedPreferences，**无需改 API_CONTRACT**）。

## 三、已确认决策表（全部定案）

| 维度 | 定案 |
|---|---|
| MD3 变体 | Material3 **Expressive** |
| 配色 | **12 套命名主题**（WH/GR/Lemon/Koharu/Yuuka/Phoebe/Sora/August/Carlotta/Mujika/Elink）+ 可切换 |
| 暗色 | 每套 = **着色亮+暗配对**（tonal，非纯黑） |
| Material You 动态取色 | **后续批次**（本轮不做，需 Android seed color 平台通道） |
| 圆角 | Expressive 大圆角（extraLarge 28dp+） |
| 底部导航 | M3 **NavigationBar**（pill 指示器）；默认图标用 Material Symbols，激活皮肤时渲染用户图 |
| 图标 | **Material Symbols**（换内置/功能图标 + 默认底栏 SVG；无法映射为单 glyph 的插画用 MD3 矢量等价物，批次内定） |
| 字体 | **跟随系统**（Android=Roboto / iOS=SF Pro / Windows=系统字，不指定 fontFamily） |
| 动效 | **Hero 封面过渡**（书架↔详情）+ 标准转场；不做预测性返回 |
| 层次 | **Tonal Surface**（surfaceContainerLow/Medium/High 色阶分层 + 低 elevation） |
| 顶栏 | 标准 M3 AppBar + **主 Tab 根页可折叠 LargeTitle**；不做实时玻璃模糊（Flutter 无原生 blur，Windows 性能存疑） |
| Chip | 引入 **M3 Chip**（搜索筛选/标签） |
| 闪屏/欢迎 | 改 **MD3** |
| 主题设置 | **跟随参考只留 12 套**——下线现有 theme_config 手动 4 色配置 |
| 底栏皮肤功能 | **完整保留**；Material Symbols 只换「默认内置图标」路径，M3 NavigationBar 有皮肤时渲染用户自定义图（`iconsForSlot`） |
| 背景图/壁纸 | **保留为独立功能**（与 12 套主题正交，叠加在 surface 上） |
| 持久化 | **SharedPreferences 本地**（非 Rust FFI）；`paletteId` 新增一个 PrefKey |
| 范围 | **6 批次**（按功能域），每批独立验证 + 验收 + commit + CHANGELOG patch 递增 |
| 规则冲突 | AGENTS.md「apple-ui-designer 技能」条款修订为「遵循 Material Design 官方指南」 |

## 四、范围边界与红线

- **规模实测**：**65 个 screen**（`lib/src/screens/`）+ **50+ widget**（`lib/src/widgets/`）。其中 `reader_comic_screen` / `reader_screen` 为沉浸式屏，**保持不动**。
- **IN**：token/主题层、主框架、其余 63 个 screen、全部非阅读 widget、图标、字体、组件、闪屏。
- **OUT（保持不动）**：阅读器沉浸式屏；Material You 动态取色（后续批次）；参考仓库 Android-only 功能（timeline records / companion groups / controller page-flip / tablet layouts）。
- **软边界说明**：`reader_config_panel.dart` 有 8 处 `colorScheme` 引用（primary/onSurfaceVariant，标准 token），会**自动跟随**新 MD3 色（期望行为）；真正隔离的是沉浸式屏（0 引用）。设计文档须注明此软边界。
- **红线**：仅移植视觉；界面功能/结构/交互与原版对齐，只换皮；UI 层不含业务逻辑，数据经 Rust Bridge。

## 五、参考仓库关键研究结论（实现依据）

1. **主题机制**：`Base.AppTheme` parent=`Theme.Material3Expressive.DynamicColors.DayNight.NoActionBar`；12 套命名主题，每套在 `res/values/colors.xml` + `res/values-night/colors.xml` 各定义 **47 个 tonal 色**（亮+暗配对）。
2. **着色暗色（非纯黑）**：由 seed 自动派生整套 tonal。实测样例：
   - `koharu` DAY surface `#FFF8F7`（暖白）→ NIGHT surface `#1A1111`（深暖红棕，非 #000）；
   - `sora` DAY surface `#F8F9FF`（冷蓝白）→ NIGHT 深蓝调暗面；
   - `wh`（中性白）DAY `#FAFAFA`/`#F8F8F8`，NIGHT 近中性深灰。
3. **顶栏**：参考用 `GlassTopAppBar` + Haze 实时模糊 + `CollapsibleHeader`。**本计划不做实时玻璃模糊**（Flutter 无原生 blur、Windows 性能存疑），改为「标准 AppBar + 主 Tab 根页可折叠 LargeTitle」。
4. **动效**：参考用 Compose Navigation3 + 共享元素动画，核心是**书籍封面在书架↔详情间的过渡**。Flutter 对应原生 `Hero`——纯视觉、不加功能。预测性返回为 Android 系统级，本计划不做。
5. **字体**：Roboto 非 iOS/Windows 原生；本计划跟随系统字体族（保持现状）。

### 参考色值锚点（Batch 0 `md3_colors.dart` 数据源样例）

| 主题 | DAY primary | DAY surface | DAY onSurface | NIGHT surface | NIGHT onSurface |
|---|---|---|---|---|---|
| wh | `#5C5C5C` | `#F8F8F8` | `#1C1B1B` | 近中性深灰 | 近白 |
| koharu | `#8F4A4D` | `#FFF8F7` | `#221919` | `#1A1111` | `#F0DEDE` |
| sora | `#3B608F` | `#F8F9FF` | — | 深蓝调暗面 | — |

> 完整数据源=参考 `res/values/colors.xml` + `res/values-night/colors.xml`（每套 47 色）。研究产物已抓至 `.tmp_net/`（非项目代码，收尾时清理）。

## 六、前置项（Batch 0 之前必须确认）

1. **Flutter SDK 版本**：确认支持 Expressive shape scale + NavigationBar + Hero + Material Symbols。⚠️ `flutter --version` 曾超时（600s），需重测——可能为环境/首次下载问题，非真挂起。
2. **Material Symbols 引入方案**：现状仅 `cupertino_icons` + 8 个 SVG；需新增 MS 依赖（包或字体资产），确认与 Dart `>=3.8.0` 兼容。
3. **freezed regen 工具链**：`build_runner`/`freezed` 已在 dev_deps ✓；为 `ThemeState` 加 `paletteId` 字段后需 `dart run build_runner` 重新生成 `.freezed.dart`。

## 七、实施（6 批次，逐批验证 + 测试迁移）

> **每批统一门禁**：`flutter analyze && flutter test`（含本批受影响 widget 测试迁移）→ `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）→ 用户 `-Device emulator-5558 -CheckUI` → commit（`feat(ui):`/`refactor(ui):` + 中文正文）+ CHANGELOG patch 递增。

### Batch 0 — Token 与主题地基（全局生效，无页面）
- **新增** `lib/src/theme/md3_colors.dart`：12 套调色板，每套完整 M3 tonal role 集，各含 light+dark；数据源=参考 colors.xml + values-night/colors.xml；提供 `Md3Palette` 模型 + byId 查询。
- **重写** `app_theme.dart`：M3 `ThemeData`——Expressive shape scale、Tonal Surface elevation、AppBar（标准+LargeTitle）、NavigationBar theme、cardRadius、switch/checkbox/radio/chip/dialog/alert-dialog/bottom-sheet/snackbar themes；以 `md3Theme(paletteId, brightness)` 取代 `lightCustom/darkCustom(primary,accent,…)`。
- **重写** `app_typography.dart`：M3 type scale，跟随系统字体族。
- **更新** `app.dart`：按 paletteId + themeMode 装配 ThemeData；保留 SystemBarBinder / `_ThemeBackgroundLayer`（壁纸层）。
- **主题状态**：`paletteId` 存 SharedPreferences（新 PrefKey）；`ThemeState`(freezed) regen 或独立 notifier。
- **同步** `docs/design_system.md` → MD3 token 单一事实源。
- 默认调色板 = **WH**。

### Batch 1 — 主框架 + 主题选择器
- `home_screen`：M3 NavigationBar（4 tab）+ pill 指示器；默认 Material Symbols，激活皮肤时渲染用户图（保留 `bottom_bar_skin_notifier` 逻辑）。
- `legado_app_bar`：标准 M3 AppBar + 主 Tab 根页可折叠 LargeTitle。
- `theme_config` → **12 主题选择器 UI**；**下线手动 4 色配置**（隐藏/移除）；保留 bgImage 独立入口。
- `welcome` / `welcome_config` / `font` → MD3。
- `bottom_bar_skin` / `bottom_bar_skin_assign` → MD3 改皮，功能不变。
- **Hero 封面过渡**基础设施（书架↔详情，key=book url）。

### Batch 2 — 书架/书籍域
- `bookshelf`、`book_info`、`edit_book_info`、`change_cover`、`change_source`、`book_group`、`bookshelf_manage`、`bookmark`、`read_record`、`toc`、`reader_config_panel`、`remote_book`。
- 组件：`book_cover`、`book_grid_item`、`book_list_item`、`chapter_tile` → M3 card/list tile + Material Symbols。

### Batch 3 — 搜索/发现/浏览域
- `search`、`search_content`、`explore`、`explore_show`、`dict`、`association`、`browser`、`qrcode`。
- 组件：`search_bar_widget`、`search_filter_panel` + **M3 Chip**（筛选/标签）、`explore_kind_*`、`source_card`。

### Batch 4 — 源编辑/调试/开发域
- `source`、`source_edit`、`source_debug`、`code_edit`、`js_source_edit`、`curl_analyze_url_sheet`、`rule_sub`、`replace_rules`、`replace_rule_import_confirm`、`txt_toc_rules`、`highlight_rules`、`source_login`、`source_import_confirm`。
- RSS 源管理同域：`rss_source_edit`、`rss_source_debug`、`rss_source_manage`、`rss_source_import_confirm`。

### Batch 5 — RSS/音视频/缓存域
- `rss`、`rss_articles`、`rss_article_detail`、`rss_favorites`、`video`、`audio`、`read_aloud_config`、`cache_download`、`offline_cache`。

### Batch 6 — 设置长尾/admin/misc + 收尾核对
- `settings`、`other_settings`、`webdav_settings`、`cache_settings`、`file_manage`、`auto_task`、`app_log`、`about`、`import`、`archive_import_dialog`。
- **全量 Dialog / BottomSheet / Snackbar 为 M3 规范核对**。
- **暗色 WCAG AA 对比度复核**：着色暗面上 onSurface ≥ AA，跨 WH/koharu/sora 等抽查。

## 八、主题架构与数据流（已澄清）

- **持久化 = SharedPreferences 本地**（`SettingsService`），非 Rust FFI → `paletteId` 加一个 PrefKey，**无需改 API_CONTRACT**。
- `ThemeState`(freezed)：themeMode + fontScaleRaw；加 `paletteId` 走 build_runner regen。
- `ThemeColorsState`：8 个颜色字段（cPrimary/cAccent/cBackground/cBBackground × day/night）+ bgImage/bgImageN → **下线手动取色**（隐藏 UI），bgImage 保留独立。
- **底栏皮肤两路径**：无皮肤=Material Symbols；有皮肤=`iconsForSlot` 渲染用户图（`bottom_bar_skin_service`，ZIP 导入/分配/编辑/导出功能完整保留）。
- **背景图/壁纸**：`_ThemeBackgroundLayer` + bgImage prefs，与 12 套主题正交，保留。

## 九、测试迁移工作流（关键）

`test/` 有 **100+ 测试文件**，含大量 UI widget 测试断言当前样式/布局/token：
- `theme_config_test` → 随手动取色下线**改写**为 12 主题选择器测试。
- 组件/屏测试（`book_grid_item_test`、`tag_chip_test`、`source_card_test`、`home_navigation_test`、`settings_test`…）→ 每批迁移受影响的断言至 MD3 期望值。
- **响应式守护**：`responsive_test`、`explore_screen_dual_pane_test`、`bookshelf_grid_responsive_test` → M3 改动须保持既有双栏/桌面布局行为不回归。
- `home_navigation_test`（双击重选 300ms / 两段式退出 2000ms）→ NavigationBar 迁移后交互行为必须保留。

## 十、规则修订（独立小 commit）

- AGENTS.md：「UI 开发必须使用 apple-ui-designer 技能」→「遵循 Material Design 官方指南（Material Design 3）」；apple-ui-designer 降为可选/参考。类型 `docs:`，中文正文。

## 十一、测试与验收

- 每批：`flutter analyze && flutter test`（含测试迁移）→ `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）→ 用户 `-Device emulator-5558 -CheckUI`。
- Batch 0 建议加 token golden/widget 测试；Batch 6 做暗色 AA 复核。

## 十二、边界情况与失败模式

- **Windows 桌面**（主构建目标）：Material Symbols 字体渲染、系统字、未用 BackdropFilter（安全）；M3 在桌面宽度的双栏布局。
- **着色暗面**：确保 onSurface 文本对比度 ≥ AA。
- **Hero + cached_network_image**：key 稳定，避免过渡抖动。
- **底栏皮肤路径**：激活皮肤时 Material Symbols 与用户图切换无闪烁；皮肤缺失回退默认 MS。
- **24 组合**（12 主题 × light/dark）：至少测默认 + WH/koharu/sora 双模式。
- **阅读器沉浸式屏不得回归**。

## 十三、假设

- 默认调色板 = WH。
- Material Symbols 经包/字体引入；无法映射为单 glyph 的插画资产用 MD3 矢量等价物（批次内定）。
- 主题持久化走 SharedPreferences，无 FFI 变更。
- 阅读器沉浸式屏不动；参考仓库 Android-only 功能不移植。

## 十四、交付顺序

1. **写入 `docs/UI_MD3_PLAN.md`（本计划）并 commit**，随后**暂停**——不执行任何源码修改，等待用户指令再进入 Batch 0。
2. （后续，待用户放行）前置项确认 → Batch 0 → 1 → 2 → 3 → 4 → 5 → 6，逐批验证/验收/commit/CHANGELOG。
3. 收尾：清理研究产物 `.tmp_net/`（非项目代码）。

---

编写者：Qoder ｜ 2026-08-27
