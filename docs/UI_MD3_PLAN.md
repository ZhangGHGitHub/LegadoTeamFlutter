# Legado Flutter UI 迁移至 Material Design 3（Expressive）完整计划

> 角色：Flutter UI 负责人
> 职责边界：所有 Dart 代码（页面/组件/状态管理/路由/主题），通过 Rust Bridge 获取数据，不含业务计算逻辑。UI 层只做渲染、交互与状态管理。
> 参考目标：`https://github.com/HapeLee/legado-with-MD3`（Android/Kotlin MD3 Expressive + Material You 分支）

---

## 〇、实施状态（2026-08-28 更新）

**B0–B6 七批次全部落地**，门禁均为 `flutter analyze 0 issues + flutter test 全绿`；运行时验证见下。

| 批次 | 内容 | 提交 |
|---|---|---|
| 治理步骤（第十四节） | AGENTS/design_system/Active Plan 三处规范切换 MD3 | `63c197d59` |
| Batch 0 | md3_colors 12 套调色板（P1-5 生成器+校验）/ M3 主题装配 / ios_widgets 集中改造 / paletteId / design_system 重写 | `281951dd0` |
| Batch 1 | Material Symbols 引入 / home 底栏 / theme_config 内置主题双区 / Hero 基础设施 | `024208d49`（含 B2） |
| Batch 2 | 书架/书籍域 token 收尾（TabBar 前景 / toc 滑删 onError） | `024208d49` |
| Batch 3 | 搜索/发现/浏览域（M3 segmented 视觉 / association onPrimary） | `8d4554f60` |
| Batch 4 | 源编辑/调试域（js 编辑区 token 化 + 功能色例外登记） | `a58415b94` |
| Batch 5 | RSS/音视频/缓存域（shadow token / FAB onPrimaryContainer） | `0356e8efd` |
| Batch 6 | 设置长尾（我的页去 iOS 彩色图标底 / app_log TabBar token 化）+ 全域复核 | `c8cc3d824` |
| 收尾 | 验收矩阵自动化 + 2 个溢出修复（palette 卡片/error_view）+ 文档同步 + .tmp_net 清理 | 见 CHANGELOG [2.0.117] |

**第十三节验收矩阵落地口径**：
- token 对比度：`test/unit/md3_palette_test.dart`（22 不透明组合 ≥ AA 4.5 + elink 3.95/AA-large 例外 + transparent 豁免）✓
- 关键页 golden：**以渲染矩阵替代**（`test/widget/md3_acceptance_matrix_test.dart`：theme_config/home/settings/search × WH/koharu/sora × 亮暗）。理由：golden 二进制基线在 Windows 开发 / Linux CI 双平台字体渲染下脆弱；截图验收改由模拟器 `-CheckUI` 流程承担
- 断点：矩阵测试用主流机型逻辑视口（360×753dp）；响应式双栏由既有 `responsive_test`/`explore_screen_dual_pane_test`/`bookshelf_grid_responsive_test` 守护 ✓
- 字体缩放：0.8x/1.6x 边界渲染无溢出 ✓（并修复 error_view 超高溢出）
- 语义/触控目标：底栏 ≥48dp + 调色板中文标签语义化 ✓

**遗留项（如实登记）**：
1. ~~主 Tab 根页可折叠 LargeTitle~~ **已实施（2026-08-28，版本 2.0.118+122）**：「书架」（无分组时）与「我的」采用 SliverAppBar.large（152dp 展开大标题，滚动折叠为标准 M3 AppBar，跳顶随滚动复位；书架有分组时为 pinned TabBar 头保持原版嵌入结构）；「发现」「订阅」两根页的顶栏为原版 view_search 嵌入式搜索框（无标题文字），按原版对齐红线不适用 LargeTitle，维持既有顶栏——已在 `LegadoTabRootHeaderSliver`/`LegadoLargeTitleScroll` 文档注释与本节登记口径；
2. Material You 动态取色：按计划即为后续批次（需 Android seed-color 平台通道）；
3. Batch 1–6 的模拟器冒烟未单独执行——emulator-5556/5558 被搜索 parity 后端轨（SEARCH_PARITY_HANDOVER_20260828.md）占用为 P0-3 e2e 实验环境，为避免互相干扰而并入用户验收流程（Batch 0 冒烟已 PASSED 7/7）。**2026-08-28 补跑：后端轨释放模拟器后，LargeTitle 批次已在 5556 冒烟 + 5558 -CheckUI 验证（结果见 CHANGELOG [2.0.118]）。**

---

## 一、背景与定位

Legado 为 Rust + Flutter 跨平台阅读器，与 Android 原版双轨对齐。当前 `flutter_legado/` 视觉语言为 **iOS HIG**（2026-08-05 回退自 M3）。本计划切换为 **Material Design 3 Expressive**，对齐参考仓库视觉签名。

按 AGENTS.md：界面功能、页面结构、交互流程与原版一致；**UI 视觉风格允许自由改变**。因此仅移植 MD3 **视觉层**，不引入参考仓库 Android-only 功能，且**不移除任何现有 UI 功能**。

## 二、目标与成功标准

**目标**：将 `flutter_legado/` UI 视觉从 iOS HIG 全面切换为 MD3 Expressive，**保留全部现有功能**（含用户命名主题系统）。

**成功标准**：
1. 全应用（除阅读器沉浸式屏）渲染为 MD3 Expressive；
2. **12 套内置主题 + 自定义主题并存**，每套内置含着色亮+暗配对（tonal，非纯黑）；
3. `flutter analyze && flutter test` 通过——**含受影响 widget 测试迁移**（第十二节）；
4. **12×亮暗全矩阵验收**：token 对比度自动化 + 关键页 golden/截图 + 手机/桌面断点 + 系统字体缩放 + 语义/触控目标（第十三节）；
5. `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）+ 用户 `-Device emulator-5558 -CheckUI`；
6. `docs/design_system.md` 同步为 MD3 token **单一事实源**；
7. 保持既有**响应式/桌面双栏布局**不回归；
8. **无 FFI/Rust 变更**（主题持久化为本地 SharedPreferences，无需改 API_CONTRACT）。

## 三、已确认决策表（全部定案）

| 维度 | 定案 |
|---|---|
| MD3 变体 | Material3 **Expressive**（按 Flutter 实际 API 面落地，见第七节映射 + 降级）|
| 配色 | **12 套内置命名主题**（WH/GR/Lemon/Koharu/Yuuka/Phoebe/Sora/August/Carlotta/Mujika/Elink）+ 可切换 |
| 暗色 | 每套 = **着色亮+暗配对**（tonal，非纯黑） |
| Material You 动态取色 | **后续批次**（需 Android seed-color 平台通道，非 Rust FFI；本轮不做）|
| 圆角 | Expressive 大圆角（extraLarge 28dp+，经 component theme 显式设 borderRadius）|
| 底部导航 | M3 **NavigationBar**（pill 指示器）；默认 Material Symbols，激活皮肤时渲染用户图 |
| 图标 | **Material Symbols**（换内置/功能图标 + 默认底栏 SVG；无法映射为单 glyph 的插画用 MD3 矢量等价物）|
| 字体 | **跟随系统**（不指定 fontFamily）|
| 动效 | **Hero 封面过渡**（书架↔详情）+ 标准转场；不做预测性返回 |
| 层次 | **Tonal Surface**（surfaceContainerLow/Medium/High + 低 elevation）|
| 顶栏 | 标准 M3 AppBar + 主 Tab 根页可折叠 LargeTitle；不做实时玻璃模糊 |
| Chip | 引入 **M3 Chip**（搜索筛选/标签）|
| 闪屏/欢迎 | 改 **MD3** |
| **主题设置** | **12 内置 + 自定义并存**：保留 `themeConfigList` 读/存/应用/删除 + bgImage；新增 12 套 MD3 preset 可切换（见第九节迁移）|
| 底栏皮肤功能 | **完整保留**；Material Symbols 只换默认内置图标，M3 NavigationBar 有皮肤时渲染用户图 |
| 背景图/壁纸 | **保留为独立功能**（与 12 套主题正交）|
| 持久化 | **SharedPreferences 本地**（非 Rust FFI）；`paletteId` 新增一个 PrefKey，**免 API_CONTRACT** |
| 范围 | **7 批次 = B0 地基 + B1–B6 六功能域**，每批独立验证 + 验收 + commit + CHANGELOG patch 递增 |
| AGENTS 规则 | **独立治理步骤（已授权）**：修订「apple-ui-designer 必用」条款为「遵循 Material Design 官方指南」，同步 AGENTS/design_system/Active Plan 三处；**不并入 UI 批次**（第十四节）|

## 四、范围边界与红线

- **规模实测**：**65 screen** + **50+ widget** + **~133 处共享 iOS wrapper 组件**（IosListTile 68 / IosGroup 26 / IosSectionHeader 20 / IosGroupedBody 11 / IosGrabber 8）。
- **IN**：token/主题层、主框架、其余 screen、非阅读 widget、共享 iOS wrapper 层（集中改造）、图标、字体、组件、闪屏。
- **OUT（保持不动）**：阅读器**沉浸式屏**（`reader_comic_screen`/`reader_screen`，0 theme 引用，真正隔离）；Material You 动态取色（后续批次）；参考 Android-only 功能。
- **reader 精确边界**：`reader_config_panel.dart` 有 8 处 `colorScheme` 引用（primary/onSurfaceVariant，标准 token）→ **属可改范围**（自动跟随新 MD3 色，期望行为）；沉浸式屏的 Sheet/面板 → **不改**。
- **无功能删除红线**：保留 themeConfigList、bottom_bar_skin、bgImage 全部现有功能。
- **数据流**：仅 UI 层改动，数据经现有 Rust Bridge 原样获取，持久化走本地 SharedPreferences——不碰 `rust/`、FFI bridge、API_CONTRACT。

## 五、参考仓库研究结论（实现依据）

1. **主题机制**：`Base.AppTheme` parent=`Theme.Material3Expressive.DynamicColors.DayNight.NoActionBar`；12 套命名主题，每套在 `res/values/colors.xml` + `values-night/colors.xml` 各定义 **47 tonal 色**（亮+暗配对）。
2. **着色暗色（非纯黑）**：由 seed 自动派生整套 tonal。样例：koharu DAY surface `#FFF8F7` → NIGHT `#1A1111`；sora DAY `#F8F9FF` → NIGHT 深蓝调；wh DAY `#F8F8F8` → NIGHT 近中性深灰。
3. **顶栏**：参考用 GlassTopAppBar + Haze 实时模糊 + CollapsibleHeader。**本计划不做实时玻璃模糊**（Flutter 无原生 blur、Windows 性能存疑），改为「标准 AppBar + 主 Tab 根页可折叠 LargeTitle」。
4. **动效**：Compose Navigation3 + 共享元素，核心是书籍封面书架↔详情过渡。Flutter 对应原生 `Hero`。预测性返回为 Android 系统级，不做。
5. **字体**：跟随系统（保持现状）。

### 参考色值锚点（Batch 0 `md3_colors.dart` 数据源样例）

| 主题 | DAY primary | DAY surface | DAY onSurface | NIGHT surface | NIGHT onSurface |
|---|---|---|---|---|---|
| wh | `#5C5C5C` | `#F8F8F8` | `#1C1B1B` | 近中性深灰 | 近白 |
| koharu | `#8F4A4D` | `#FFF8F7` | `#221919` | `#1A1111` | `#F0DEDE` |
| sora | `#3B608F` | `#F8F9FF` | — | 深蓝调暗面 | — |

> **可复现来源（P1-5）**：完整数据源=参考 `res/values/colors.xml` + `values-night/colors.xml`（每套 47 色）。**Batch 0 必须把每套 palette 的 seed + 完整 role 映射 + 来源版本固化进受版本控制的 `md3_colors.dart`（含生成校验测试）**，之后才清理 `.tmp_net/`。研究产物现暂存 `.tmp_net/`。

## 六、前置项（Batch 0 之前必须交付）

1. **Flutter Expressive API 核实**：确认 Flutter 3.44.8 实际支持面——`DynamicSchemeVariant.expressive`（色彩变体，已确认存在）；**shape scale / typography 无单一 preset**，须经 component theme 显式落地。产出第七节映射表并冻结降级方案。
2. **Material Symbols 引入方案**：现状仅 `cupertino_icons` + 8 SVG；新增 MS 依赖（包/字体资产），确认 Dart `>=3.8.0` 兼容。
3. **共享组件矩阵**：产出第八节「组件 → 消费页 → 批次」矩阵，冻结 iOS wrapper 层集中改造方案。
4. **主题迁移测试 + 视觉基线**：Batch 0 前交付 themeConfigList/8色/bgImage 的迁移与回滚测试、12×亮暗对比度自动化测试、关键页面 golden 基线（第十三节）。
5. **freezed regen 工具链**：`build_runner`/`freezed` 已在 dev_deps ✓；为 `ThemeState` 加 `paletteId` 后 `dart run build_runner` 重生成 `.freezed.dart`。

## 七、Flutter Expressive API 映射与降级（P1-2）

> **原则**：不把 Compose `Material3Expressive` 当 Flutter 全量可用能力。每个目标对应具体 Flutter 3.44.8 API，缺失时采用标准 M3 等价方案。以下为待 Batch-0 前置核实的映射草案：

| Expressive 目标 | Flutter 3.44.8 API（待核实）| 标准 M3 降级 |
|---|---|---|
| Dynamic color expressive 变体 | `DynamicSchemeVariant.expressive`（色彩，已确认存在）| 静态 tonal palette（`md3_colors.dart`）|
| Expressive 大圆角 shape scale | **无单一 preset**；经 component theme 显式设 borderRadius：`cardTheme`/`navigationBarTheme`/`dialogTheme`/`chipTheme` + `StadiumBorder`/`BorderRadius.circular(28)` | 标准 M3 默认 cardRadius |
| Expressive typography | `TextTheme` 自定义 scale（无 expressive preset）| 默认 M3 type scale |
| Tonal surface 层次 | `surfaceContainerLow/Medium/High` colorScheme + 低 `elevation` | 标准 M3 elevation |
| Hero 封面动效 | `Hero` widget（标准，非 Expressive 专属）| — |

## 八、共享组件覆盖矩阵（P1-3）

> **策略**：iOS wrapper 层（`ios_widgets.dart`）**集中改造**为 MD3 等价物，消费屏继承，而非逐屏重复。reader 边界见第四节。

| 共享 iOS 组件 | 用量 | M3 替换 | 主要消费页 | 批次 |
|---|---|---|---|---|
| `IosListTile` | 68 | M3 `ListTile`/`Card` | other_settings(23)/settings(18)/theme_config(17)/webdav(12)/about(12) | B0 集中 + 各屏批 |
| `IosGroup` | 26 | M3 分组容器（surfaceContainer）| settings/theme/webdav/about/welcome | B0/B1 |
| `IosSectionHeader` | 20 | M3 section header | 同上 | B0/B1 |
| `IosGroupedBody` | 11 | M3 grouped body | 同上 | B0/B1 |
| `IosGrabber` | 8 | M3 grabber/drag handle | bottom_bar_skin_* | B1 |

- **Dialog/BottomSheet**：跨业务域分布，逐屏批内改为 M3 `dialogTheme`/`bottomSheetTheme`（非 Batch 6 一次性「全量核对」）。
- **reader Sheet 边界**：沉浸式 reader Sheet **不改**；`reader_config_panel` 的 Sheet **可改**（跟随 colorScheme）。

## 九、数据迁移与回滚（P0-3）

> **并存模型**：`paletteId`（12 内置 preset，选一套设完整 tonal scheme）与 `themeConfigList`（用户命名主题，4 色 + bgImage）**独立持久化**；UI 提供「内置主题」+「自定义主题」两个区。优先级规则（Batch 0/1 定稿）：自定义已应用的 4 色 > 内置 palette 对应 role。

- **现有存储**：`themeConfigList`（JSON，SharedPreferences）、8 色 pref（cPrimary…cNBBackground）、bgImage/bgImageN、`bottomBarSkin`。
- **迁移策略**：**无强制迁移**——现有 pref 继续工作；新增 `paletteId` 默认 WH；自定义主题仍可叠加/应用。
- **回滚路径**：自定义主题引用已退役颜色语义时，回退到当前存储值（`_loadThemeList` 已有 JSON 解析失败 → 空列表的兜底）；bgImage 路径无效 → 无壁纸。
- **测试**：Batch 0 前交付 themeConfigList/8色/bgImage 的读/存/应用/删除 + 迁移 + 回滚测试（守护不回归）。

## 十、实施（7 批次 = B0 地基 + B1–B6 六功能域）

> **每批统一门禁**：`flutter analyze && flutter test`（含本批受影响 widget 测试迁移）→ `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）→ 用户 `-Device emulator-5558 -CheckUI` → commit（`feat(ui):`/`refactor(ui):` + 中文正文）+ CHANGELOG patch 递增。

### Batch 0 — Token 与主题地基（全局生效，无页面）
- **新增** `lib/src/theme/md3_colors.dart`：12 套调色板，每套完整 M3 tonal role 集（light+dark），含 seed + role 映射 + 来源版本 + 生成校验测试（P1-5）。
- **重写** `app_theme.dart`：M3 `ThemeData`——按第七节 API 映射落地 Expressive shape/type/tonal surface；AppBar（标准+LargeTitle）、NavigationBar/card/chip/dialog/bottomSheet/snackbar themes。
- **重写** `app_typography.dart`：M3 type scale，跟随系统字体族。
- **集中改造** `ios_widgets.dart`：IosListTile/IosGroup/IosSectionHeader/IosGroupedBody/IosGrabber → MD3 等价（消费屏继承）。
- **更新** `app.dart`：按 paletteId + themeMode 装配；保留 SystemBarBinder / `_ThemeBackgroundLayer`。
- **主题状态**：`paletteId` 存 SharedPreferences（新 PrefKey）；`ThemeState`(freezed) regen。**自定义 themeConfigList 功能完整保留**。
- **同步** `docs/design_system.md` → MD3 token 单一事实源。
- 默认调色板 = **WH**。

### Batch 1 — 主框架 + 主题选择器
- `home_screen`：M3 NavigationBar（4 tab）+ pill；默认 Material Symbols，激活皮肤渲染用户图。
- `legado_app_bar`：标准 M3 AppBar + 主 Tab 根页可折叠 LargeTitle。
- `theme_config`：**「内置 12 主题」+「自定义主题」双区**（保留 save/apply/delete + bgImage）；新增 12 preset 选择器。
- `welcome`/`welcome_config`/`font` → MD3。
- `bottom_bar_skin`/`bottom_bar_skin_assign` → MD3 改皮，功能不变。
- **Hero 封面过渡**基础设施（书架↔详情，key=book url）。

### Batch 2 — 书架/书籍域
- `bookshelf`、`book_info`、`edit_book_info`、`change_cover`、`change_source`、`book_group`、`bookshelf_manage`、`bookmark`、`read_record`、`toc`、`reader_config_panel`（可改，跟随 colorScheme）、`remote_book`。
- 组件：`book_cover`、`book_grid_item`、`book_list_item`、`chapter_tile` → M3 + Material Symbols。

### Batch 3 — 搜索/发现/浏览域
- `search`、`search_content`、`explore`、`explore_show`、`dict`、`association`、`browser`、`qrcode`。
- 组件：`search_bar_widget`、`search_filter_panel` + **M3 Chip**、`explore_kind_*`、`source_card`。

### Batch 4 — 源编辑/调试/开发域
- `source`、`source_edit`、`source_debug`、`code_edit`、`js_source_edit`、`curl_analyze_url_sheet`、`rule_sub`、`replace_rules`、`replace_rule_import_confirm`、`txt_toc_rules`、`highlight_rules`、`source_login`、`source_import_confirm`。
- RSS 源管理同域：`rss_source_edit`、`rss_source_debug`、`rss_source_manage`、`rss_source_import_confirm`。

### Batch 5 — RSS/音视频/缓存域
- `rss`、`rss_articles`、`rss_article_detail`、`rss_favorites`、`video`、`audio`、`read_aloud_config`、`cache_download`、`offline_cache`。

### Batch 6 — 设置长尾/admin/misc + 收尾核对
- `settings`、`other_settings`、`webdav_settings`、`cache_settings`、`file_manage`、`auto_task`、`app_log`、`about`、`import`、`archive_import_dialog`。
- **暗色 WCAG AA 对比度复核**（12×亮暗全矩阵，非仅 WH/koharu/sora）。

## 十一、主题架构与数据流（已澄清）

- **持久化 = SharedPreferences 本地**（`SettingsService`），非 Rust FFI → `paletteId` 加一个 PrefKey，**无需改 API_CONTRACT**。
- `ThemeState`(freezed)：themeMode + fontScaleRaw；加 `paletteId` 走 build_runner regen。
- `ThemeColorsState`：8 色字段 + bgImage/bgImageN → **保留**（自定义主题功能），非下线。
- **底栏皮肤两路径**：无皮肤=Material Symbols；有皮肤=`iconsForSlot` 渲染用户图（ZIP 导入/分配/编辑/导出完整保留）。
- **背景图/壁纸**：`_ThemeBackgroundLayer` + bgImage prefs，与 12 套主题正交，保留。

## 十二、测试迁移工作流

`test/` 有 **100+ 测试文件**，含大量 UI widget 测试断言当前样式/布局/token：
- `theme_config_test` → **扩展**为「内置 12 + 自定义并存」的读/存/应用/删除 + 迁移测试（非下线改写）。
- 组件/屏测试（`book_grid_item_test`、`tag_chip_test`、`source_card_test`、`home_navigation_test`、`settings_test`…）→ 每批迁移受影响断言至 MD3 期望值。
- **响应式守护**：`responsive_test`、`explore_screen_dual_pane_test`、`bookshelf_grid_responsive_test` → 保持既有双栏/桌面布局不回归。
- `home_navigation_test`（双击重选 300ms / 两段式退出 2000ms）→ NavigationBar 迁移后交互行为必须保留。

## 十三、验收矩阵（12×亮暗全量，P1-4）

> 仅 analyze/test + 冒烟无法发现视觉回归。须交付自动化：
- **token 对比度**：12×亮暗 = 24 组合，onSurface/onBackground/primary 等 role 的 WCAG AA 对比度自动化断言。
- **关键页 golden/截图**：home/bookshelf/search/settings/theme_config × 抽样 palette（WH/koharu/sora）× light/dark。
- **断点**：手机 + 桌面（Windows）双栏布局快照。
- **系统字体缩放**：fontScale 边界值渲染不溢出。
- **语义/触控目标**：Material Symbols 语义标签 + 触控目标 ≥ 48dp。

## 十四、AGENTS 规则修订（独立治理步骤，已授权，P0-2）

> **不并入任何 UI 批次**。作为独立 commit 执行，先于或独立于 MD3 改造：
1. AGENTS.md：「UI 开发必须使用 apple-ui-designer 技能」→「遵循 Material Design 官方指南（Material Design 3）」；apple-ui-designer 降为可选/参考。
2. **同步** `docs/design_system.md` + `docs/REFACTORING_ACTIVE_PLAN.md` 三处一致。
3. 类型 `docs:`，中文正文；单独 commit，可独立回滚。

## 十五、边界情况与失败模式

- **Windows 桌面**（主构建目标）：Material Symbols 字体渲染、系统字、未用 BackdropFilter（安全）；M3 桌面宽双栏布局。
- **着色暗面**：onSurface 文本对比度 ≥ AA（12×亮暗全矩阵守护）。
- **Hero + cached_network_image**：key 稳定，避免过渡抖动。
- **底栏皮肤路径**：激活皮肤时 MS 与用户图切换无闪烁；皮肤缺失回退默认 MS。
- **自定义主题并存**：内置 palette 与自定义 4 色优先级清晰（第九节），无视觉跳变。
- **24 组合**（12×light/dark）全量过对比度 + golden。
- **阅读器沉浸式屏不得回归**。

## 十六、假设与交付顺序

**假设**：默认调色板 = WH；Material Symbols 经包/字体引入，无法映射为单 glyph 的插画用 MD3 矢量等价物；主题持久化走 SharedPreferences 无 FFI 变更；Flutter 3.44.8（按审查确认），Expressive shape/type 经 component theme 落地非单一 preset。

**交付顺序**：
1. **写入本计划并 commit，随后暂停**——不执行任何源码修改。
2. （待用户放行）独立治理步骤：AGENTS/design_system/Active Plan 规则同步（第十四节）。
3. 前置项确认（第六节：API 映射 + 组件矩阵 + 色数据固化 + 迁移测试基线）。
4. Batch 0 → 1 → 2 → 3 → 4 → 5 → 6，逐批验证/验收/commit/CHANGELOG。
5. 收尾：**先** `md3_colors.dart` 含完整色数据 + 校验测试 commit，**后**清理研究产物 `.tmp_net/`（非项目代码）。

---

编写者：Qoder ｜ 2026-08-27
修订：Qoder ｜ 2026-08-27（据审查补 P0×3 + P1×5：自定义主题并存、AGENTS 独立治理、数据迁移回滚、7 批次口径、Flutter API 映射降级、共享组件矩阵、12×亮暗全量验收、色数据可复现来源）
