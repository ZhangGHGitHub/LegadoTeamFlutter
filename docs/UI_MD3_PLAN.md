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
1. 全应用（除阅读器沉浸式页）渲染为 MD3 Expressive；
2. 12 套命名主题可切换，每套含**着色亮+暗配对**（Material You tonal，非纯黑）；
3. `flutter analyze && flutter test` 通过；
4. 模拟器冒烟 `-Device emulator-5556`（子代理）+ 用户验收 `-Device emulator-5558 -CheckUI` 通过；
5. `docs/design_system.md` 同步为 MD3 token **单一事实源**；
6. 不破坏 FFI/Rust 契约（除非主题持久化需字段变更，则先更新 `docs/API_CONTRACT.md`）。

## 三、已确认决策表（全部定案）

| 维度 | 定案 |
|---|---|
| MD3 变体 | Material3 **Expressive** |
| 配色 | **12 套命名主题**（WH/GR/Lemon/Koharu/Yuuka/Phoebe/Sora/August/Carlotta/Mujika/Elink）+ 可切换 |
| 暗色 | 每套 = **着色亮+暗配对**（tonal，非纯黑） |
| Material You 动态取色 | **后续批次**（本轮不做，需 Android seed color 平台通道） |
| 圆角 | Expressive 大圆角（extraLarge 28dp+） |
| 底部导航 | M3 **NavigationBar**（pill 指示器） |
| 图标 | **Material Symbols**（含皮肤图全部替换；无法映射为单 glyph 的插画用 MD3 矢量等价物，批次内定） |
| 字体 | **跟随系统**（Android=Roboto / iOS=SF Pro / Windows=系统字，不指定 fontFamily） |
| 动效 | **Hero 封面过渡**（书架↔详情）+ 标准转场；不做预测性返回 |
| 层次 | **Tonal Surface**（surfaceContainerLow/Medium/High 色阶分层 + 低 elevation） |
| 顶栏 | 标准 M3 AppBar + **主 Tab 根页可折叠 LargeTitle**；不做实时玻璃模糊（Flutter 无原生 blur，Windows 性能存疑） |
| Chip | 引入 **M3 Chip**（搜索筛选/标签） |
| 闪屏/欢迎 | 改 **MD3** |
| 主题设置 | **跟随参考只留 12 套**——下线现有 theme_config 手动 4 色配置 |
| 范围 | **4 批次**，每批独立验证 + 验收 + commit + CHANGELOG patch 递增 |
| 规则冲突 | AGENTS.md「apple-ui-designer 技能」条款修订为「遵循 Material Design 官方指南」 |

## 四、范围边界与红线

- **IN**：token/主题层、主框架、全部非阅读页、图标、字体、组件（AppBar/NavBar/Card/Chip/Dialog/Switch 等）、闪屏。
- **OUT（保持不动）**：阅读器沉浸式页 `reader_comic` / `reader_settings_sheet`（既有允许例外）；Material You 动态取色（后续批次）；参考仓库 Android-only 功能（timeline records / companion groups / controller page-flip / tablet layouts）。
- **红线**：仅移植视觉；界面功能/结构/交互与原版对齐，只换皮；UI 层不含业务逻辑，数据经 Rust Bridge。

## 五、参考仓库关键研究结论（实现依据）

1. **主题机制**：`Base.AppTheme` parent=`Theme.Material3Expressive.DynamicColors.DayNight.NoActionBar`；12 套命名主题（`Theme.Base.{WH,GR,Lemon,Koharu,Yuuka,Phoebe,Sora,August,Carlotta,Mujika,Elink}`），每套在 `res/values/colors.xml` 与 `res/values-night/colors.xml` 各定义 **47 个 tonal 色**（亮+暗配对）。
2. **着色暗色（非纯黑）**：由 seed 自动派生整套 tonal，色调以低明度烘焙进表面色。实测样例：
   - `koharu` DAY surface `#FFF8F7`（暖白）→ NIGHT surface `#1A1111`（深暖红棕，非 #000）；
   - `sora` DAY surface `#F8F9FF`（冷蓝白）→ NIGHT 为深蓝调暗面；
   - `wh`（中性白）DAY `#FAFAFA`/`#F8F8F8`，NIGHT 近中性深灰。
3. **顶栏**：参考用 `GlassTopAppBar` + Haze 实时模糊 + `CollapsibleHeader` 可折叠大标题，且支持 Miuix/M3 双引擎。**本计划不做实时玻璃模糊**（Flutter 无原生 blur、Windows 性能存疑），改为「标准 AppBar + 主 Tab 根页可折叠 LargeTitle」。
4. **动效**：参考用 Compose Navigation3 + 共享元素动画，核心是**书籍封面在书架↔详情间的过渡**（`BookCoverSharedElement.kt`）。Flutter 对应原生 `Hero` widget——纯视觉、不加功能，安全。预测性返回为 Android 12+ 系统级，需原生端启用，本计划不做。
5. **字体**：Roboto 非 iOS/Windows 原生；本计划跟随系统字体族（保持现状）。

### 参考色值锚点（Batch 0 `md3_colors.dart` 数据源样例）

| 主题 | DAY primary | DAY surface | DAY onSurface | NIGHT surface | NIGHT onSurface |
|---|---|---|---|---|---|
| wh | `#5C5C5C` | `#F8F8F8` | `#1C1B1B` | 近中性深灰 | 近白 |
| koharu | `#8F4A4D` | `#FFF8F7` | `#221919` | `#1A1111` | `#F0DEDE` |
| sora | `#3B608F` | `#F8F9FF` | — | 深蓝调暗面 | — |

> 完整数据源=参考 `res/values/colors.xml` + `res/values-night/colors.xml`（每套 47 色）。研究产物已抓至 `.tmp_net/`（非项目代码，收尾时清理）。

## 六、实施（按子系统/批次，逐批验证）

> 每批统一验证：`flutter analyze && flutter test` → `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）→ 用户 `-Device emulator-5558 -CheckUI` → commit（`feat(ui):`/`refactor(ui):` + 中文正文）+ CHANGELOG patch 递增。

### Batch 0 — Token 与主题地基（全局生效）
- **新增** `lib/src/theme/md3_colors.dart`：12 套调色板，每套完整 M3 tonal role 集（primary/onPrimary/primaryContainer/onPrimaryContainer/secondary/onSecondary/tertiary/background/surface/onSurface/onSurfaceVariant/surfaceVariant/outline/error…），各含 light+dark。数据源=参考 `colors.xml` + `values-night/colors.xml`。提供 `Md3Palette` 模型 + byId 查询。
- **重写** `app_theme.dart`：M3 `ThemeData` 构建器——Expressive shape scale（extraSmall/small/medium/large/extraLarge）、Tonal Surface elevation、AppBar（标准+LargeTitle）、NavigationBar theme、cardRadius、switch/checkbox/radio/chip/dialog/alert-dialog/bottom-sheet/snackbar themes；以 `md3Theme(paletteId, brightness)` 取代 `lightCustom/darkCustom(primary,accent,…)`。
- **重写** `app_typography.dart`：M3 type scale（display/headline/title/body/label），跟随系统字体族。
- **更新** `app.dart`：按 paletteId + themeMode 装配 ThemeData；保留 SystemBarBinder / 壁纸层。
- **扩展** ThemeNotifier/设置状态：存 active `paletteId`（0–11）。
- **同步** `docs/design_system.md` → MD3 token 单一事实源。
- 默认调色板 = **WH**（中性白，最接近现状、最小惊跳）。

### Batch 1 — 主框架 + 核心页
- `home_screen.dart`：M3 NavigationBar（bookshelf/explore/rss/my 4 tab）+ pill 指示器 + Material Symbols。
- `legado_app_bar.dart`：标准 M3 AppBar + 主 Tab 根页可折叠 LargeTitle；Material Symbols 返回图标。
- `settings/other_settings/theme_config` → **12 主题选择器 UI**；**下线手动 4 色配置**（隐藏/移除），其余功能位保留。
- `bookshelf*` + `search*`：M3 card/list tile，Material Symbols。
- **新增** Hero 封面过渡（书架↔详情，key=book url，稳定）。
- 上述页面用到的 `ios_widgets.dart` iOS 组件替换为 M3 等价物。

### Batch 2 — 设置长尾 + Chip + Dialog 核对
- webdav/audio/font/cache/backup/ai 等设置页 → MD3 + Material Symbols。
- **引入 M3 Chip**（搜索筛选/标签）。
- 全量核对已改页面的 Dialog / BottomSheet / Snackbar 为 M3 规范。

### Batch 3 — 发现/RSS/源编辑剩余 + 闪屏 + 暗色复核
- explore/discover、rss、source edit/debug 页 → MD3 + Material Symbols（替换全部剩余自定义 SVG + 皮肤图资产）。
- `welcome_screen` / splash → MD3。
- **暗色 WCAG AA 对比度复核**：着色暗面上 onSurface 文本 ≥ AA，跨多套主题抽查（WH/koharu/sora 等）。

## 七、数据流 / API 影响

- **主题持久化**：存 active `paletteId`。**先确认存储机制**——若为类型化 FFI 字段，**先更新 `docs/API_CONTRACT.md`（Rust 轨先行）**；若为通用 KV 存储则无需契约变更。
- 无其他 Rust/Bridge 变更。

## 八、规则修订（独立小 commit）

- AGENTS.md：「UI 开发必须使用 apple-ui-designer 技能」→「遵循 Material Design 官方指南（Material Design 3）」；apple-ui-designer 降为可选/参考。类型 `docs:`，中文正文。

## 九、测试与验收

- 每批：`flutter analyze && flutter test` → `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）→ 用户 `-Device emulator-5558 -CheckUI`。
- Batch 0 建议加 token golden/widget 测试；Batch 3 做暗色 AA 复核。

## 十、边界情况与失败模式

- **Windows 桌面**（主构建目标）：Material Symbols 字体渲染、系统字、未用 BackdropFilter（安全）；M3 在桌面宽度下的布局。
- **着色暗面**：确保 onSurface 文本对比度 ≥ AA。
- **Hero + cached_network_image**：key 稳定，避免过渡抖动。
- **24 组合**（12 主题 × light/dark）：至少测默认 + WH/koharu/sora 双模式。
- **阅读器沉浸式页不得回归**。

## 十一、假设

- 默认调色板 = WH。
- Material Symbols 经包/字体引入；无法映射为单 glyph 的插画资产用 MD3 矢量等价物（批次内定）。
- 无 FFI 变更，除非主题持久化需类型化字段（则 API_CONTRACT 先行）。
- 阅读器沉浸式页不动；参考仓库 Android-only 功能不移植。

## 十二、交付顺序

1. **写入 `docs/UI_MD3_PLAN.md`（本计划）并 commit**，随后**暂停**——不执行任何源码修改，等待用户指令再进入 Batch 0。
2. （后续，待用户放行）Batch 0 → 1 → 2 → 3，逐批验证/验收/commit/CHANGELOG。
3. 收尾：清理研究产物 `.tmp_net/`（非项目代码）。

---

编写者：Qoder ｜ 2026-08-27
