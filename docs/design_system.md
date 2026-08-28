# Legado Flutter 设计规范文档（Material Design 3）

> 数据来源：`flutter_legado/lib/src/theme/app_theme.dart`（MD3 主题装配）、`md3_colors.dart`（12 套内置调色板）、`app_typography.dart`（M3 字阶）
> Token 来源基准：Material Design 3 官方指南（Expressive 视觉层），12 套内置命名主题 × 亮/暗 tonal 配对，语义槽位与 Android 原版一一对应
>
> **定位说明（2026-08-28 更新）**：本文档描述当前主题 Token 体系，作为 UI 实现的统一依据。项目对齐标准为：**界面功能与交互流程对齐 Android 原版，UI 视觉风格自由**——UI 开发遵循 Material Design 官方指南（Material Design 3 Expressive，apple-ui-designer 技能降为可选参考），视觉语言正按 `docs/UI_MD3_PLAN.md` 由 iOS 体系迁移至 MD3 体系；**本文档为 MD3 token 单一事实源**，修改 Token 时需同步更新本档与代码实现（`md3_colors.dart` 走生成器）。

---

## 1. 内置调色板（12 套）

数据来源：参考仓库 HapeLee/legado-with-MD3@`6dc297221a22e532354810fb2804592dd08e5a9d`
的 `res/values/colors.xml` + `values-night/colors.xml`，每套 47 个 M3 tonal role（亮/暗配对），
role 值逐字拷贝（非重推导）；由 `flutter_legado/tool/gen_md3_colors.py` 生成 `md3_colors.dart`，
锚点与对比度由 `test/unit/md3_palette_test.dart` 守护。

| id | 显示名 | seed 锚点（亮色 primary） | 特例说明 |
|----|--------|--------------------------|----------|
| `wh` | 纯白 | `#5C5C5C` | **默认调色板**（paletteId 未设置时） |
| `gr` | 森绿 | `#4C662B` | |
| `lemon` | 柠檬 | — | |
| `koharu` | 小春 | `#8F4A4D` | 亮 surface `#FFF8F7` / 暗 surface `#1A1111` |
| `yuuka` | 优香 | — | |
| `phoebe` | 菲比 | — | |
| `sora` | 穹 | `#3B608F` | 暗 surface 深蓝调 `#111318` |
| `august` | 八月 | — | |
| `carlotta` | 卡洛塔 | — | |
| `mujika` | 姆吉卡 | — | |
| `elink` | 墨水 | `#000000` | 墨水屏灰阶：暗面 surface 允许纯黑（登记例外） |
| `transparent` | 透明 | `#000000` | 表面全透明，配合背景图使用（对比度矩阵豁免） |

- 持久化：`SharedPreferences` 键 `app_palette_id`（本地存储，非 Rust FFI，免 API_CONTRACT）。
- 未知 `paletteId` 由 `Md3Palettes.byId` 回退 `wh`（回滚路径）。

### 1.1 默认调色板 WH 关键 role（亮/暗）

| Token | 亮色 | 暗色 | 用途 |
|-------|------|------|------|
| `primary` | `#5C5C5C` | 见 `md3_colors.dart` | 主色 / Tint（按钮、链接、选中态） |
| `onPrimary` | `#FFFFFF` | — | 主色上的前景 |
| `primaryContainer` | `#747474` | — | 主色容器（FAB、图标容器） |
| `surface` | `#F8F8F8` | `#141313`（着色深灰，非纯黑） | 页面背景 / Scaffold |
| `onSurface` | `#1C1B1B` | — | 主要文字 |
| `onSurfaceVariant` | `#444748` | — | 次要文字、列表图标 |
| `outlineVariant` | `#C4C7C7` | — | 分隔线、弱边框 |

> 其余 11 套及全部 47 role 的权威值一律以 `md3_colors.dart` 为准（本档不重复罗列，避免双源漂移）。

### 1.2 Tonal Surface 层次映射（组件 → role）

| 组件 | Role |
|------|------|
| Scaffold / AppBar 背景 | `surface` |
| 分组卡片（Card / IosGroup） | 亮 `surfaceContainerLowest` / 暗 `surfaceContainerLow` |
| 底部导航栏 / 菜单（PopupMenu / DropdownMenu） | `surfaceContainer` |
| BottomSheet | `surfaceContainerLow` |
| Dialog | `surfaceContainerHigh` |
| 输入框填充 | `surfaceContainerHighest` |
| 指示器（NavigationBar pill） | `secondaryContainer` |

### 1.3 用户自定义主题并存模型（themeConfigList 功能完整保留）

- **优先级**：自定义已应用的 4 色（主色调/强调色/背景色/底部操作栏，日/夜各一套）> 内置 palette 对应 role。
- 映射：`colorAccent`→`primary`+`secondary`+`surfaceTint`、`colorPrimary`→AppBar 背景（未设时回退 `colorBackground`）、`colorBackground`→`surface`/Scaffold、`colorBottomBackground`→底部导航栏背景；AppBar 前景按背景明暗动态计算（`_onColor`）。
- 背景/壁纸：`_ThemeBackgroundLayer` + `bgImage/bgImageN` prefs，与 12 套主题正交保留。
- 底栏皮肤（bottom_bar_skin）：完整保留，与主题正交。

---

## 2. 字体层级（M3 type scale，跟随系统字体）

不指定 fontFamily——运行时自动取系统字体。字阶对齐 Material 3 官方 type scale：

| 层级 | 字号 | 字重 | 行高 | 字间距 | 用途 |
|------|------|------|------|--------|------|
| displayLarge | 57 | w400 | 64/57 | -0.25 | 超大数字/展示 |
| displayMedium | 45 | w400 | 52/45 | 0 | |
| displaySmall | 36 | w400 | 44/36 | 0 | |
| headlineLarge | 32 | w400 | 40/32 | 0 | |
| headlineMedium | 28 | w400 | 36/28 | 0 | 页面大标题 |
| headlineSmall | 24 | w400 | 32/24 | 0 | 区块标题 |
| titleLarge | 22 | w400 | 28/22 | 0 | AppBar 标题 |
| titleMedium | 16 | w500 | 24/16 | 0.15 | 列表主文字 |
| titleSmall | 14 | w500 | 20/14 | 0.1 | 小标题 / Tab |
| bodyLarge | 16 | w400 | 24/16 | 0.5 | 正文 |
| bodyMedium | 14 | w400 | 20/14 | 0.25 | 辅助正文 |
| bodySmall | 12 | w400 | 16/12 | 0.4 | 小字说明 |
| labelLarge | 14 | w500 | 20/14 | 0.1 | 按钮文字 |
| labelMedium | 12 | w500 | 16/12 | 0.5 | 分组标题 / 标签 |
| labelSmall | 11 | w500 | 16/11 | 0.5 | 极小标签 |

**行高规范**：行高以分数形式写入 TextStyle（`height`），随字号等比缩放。

---

## 3. 间距 Token

| Token | 值 | 用途 |
|-------|-----|------|
| `spacing.xs` | 4 | 图标与文字间距、紧凑内边距 |
| `spacing.sm` | 8 | 列表项内部小间距 |
| `spacing.md` | 12 | 输入框内边距、卡片内元素间距 |
| `spacing.lg` | 16 | 列表项水平内边距、区块间距 |
| `spacing.xl` | 24 | 按钮水平内边距、区块之间大间距 |
| `spacing.xxl` | 32 | 页面级分隔 |

---

## 4. 圆角 Token（Expressive 大圆角）

Flutter 无 Expressive shape scale preset，经 component theme 显式落地（`app_theme.dart`）：

| Token | 值 | 用途 |
|-------|-----|------|
| `radius.card` | 20 | 卡片 / 分组容器（cardTheme） |
| `radius.control` | 12 | 输入框、SnackBar、ListTile 形状 |
| `radius.extraLarge` | 28 | Dialog / BottomSheet（M3 extraLarge） |
| `radius.menu` | 16 | PopupMenu / DropdownMenu |
| `radius.fab` | 16 | FloatingActionButton |
| StadiumBorder | 全圆角 | Elevated/Filled/Outlined 按钮（Expressive） |

---

## 5. 组件主题约定

### 5.1 AppBar
- 背景：`surface`（自定义主题时为 colorPrimary/colorBackground 回退）
- 前景：`onSurface`（自定义时按背景明暗动态计算）
- elevation 0，滚动抬升 `scrolledUnderElevation 3`（M3 tonal surfaceTint）
- 标题左对齐（centerTitle: false）

### 5.2 NavigationBar（底部导航，M3 pill 指示器）
- 背景：`surfaceContainer`（自定义时 colorBottomBackground）
- 指示器：`secondaryContainer` pill
- 选中图标：`onSecondaryContainer`；未选中：`onSurfaceVariant`
- 高度 80，label 常显；激活底栏皮肤时渲染用户图（bottom_bar_skin）

### 5.3 Card / 分组容器（IosGroup）
- 背景：亮 `surfaceContainerLowest` / 暗 `surfaceContainerLow`
- 圆角 20，elevation 0，无边框
- 分隔线：`outlineVariant` 1px（带缩进）

### 5.4 ElevatedButton / FilledButton / OutlinedButton
- 主按钮：`primary` 底 + `onPrimary` 前景，StadiumBorder，elevation 0
- 轮廓按钮：`primary` 前景 + `outlineVariant` 边线

### 5.5 InputDecoration（输入框）
- 填充色：`surfaceContainerHighest`，圆角 12，无边框
- 聚焦：`primary` 1.5px 边线

### 5.6 ListTile
- 水平内边距：16；图标色：`onSurfaceVariant`（IosListTile 默认容器 `primaryContainer` + `onPrimaryContainer` 图标，可覆写）

### 5.7 Divider（分割线）
- `outlineVariant`，厚度 1，间距 1

### 5.8 FloatingActionButton
- 背景：`primaryContainer`；前景：`onPrimaryContainer`；elevation 3，圆角 16

### 5.9 Dialog
- 背景：`surfaceContainerHigh`，圆角 28

### 5.10 BottomSheet
- 背景：`surfaceContainerLow`，顶部圆角 28；拖拽把手 = IosGrabber（32×4，`onSurfaceVariant`）

### 5.11 TabBar
- 选中/指示器：`primary`；未选中：`onSurfaceVariant`；indicatorSize label

### 5.12 Switch / Checkbox / Radio / Slider / Progress
- 跟随 M3 默认主题（不再覆写为 iOS 绿等自定义色）

### 5.13 PopupMenu / DropdownMenu
- 背景：`surfaceContainer`，圆角 16，elevation 3

### 5.14 SnackBar
- 背景：`inverseSurface`；文字：`onInverseSurface`；浮动式，圆角 12

### 5.15 Tooltip
- 背景：`inverseSurface`；文字：`onInverseSurface`，圆角 4

---

## 6. 图标使用规范

| 场景 | 颜色 Token | 说明 |
|------|-----------|------|
| 列表前导图标 | `colorScheme.onSurfaceVariant` | 通过 ListTileTheme 统一 |
| IosListTile 图标容器 | `primaryContainer` 底 + `onPrimaryContainer` 图标 | 可经 iconBackground/iconColor 覆写 |
| 操作图标（AppBar） | `AppBar.foregroundColor` | 跟随 AppBar 主题 |
| 功能入口图标 | `colorScheme.primary` | 强调可交互 |
| 空状态占位图标 | `colorScheme.onSurfaceVariant` | 低对比、不抢眼 |
| 状态指示图标 | 语义色（green/orange/error） | 需适配亮暗（暗色用 shade300） |
| 媒体覆盖层图标 | `#FFFFFF` | 仅在深色覆盖层上使用 |

**图标字体**：Batch 1 起引入 Material Symbols（默认内置/功能图标与底栏 SVG），无法映射为单 glyph 的插画用 MD3 矢量等价物（UI_MD3_PLAN.md 第三节）。

**禁止**：
- 禁止使用 `Colors.black` 作为通用图标色（暗色下不可见）
- 禁止使用 `Colors.grey` 硬编码（应使用 `onSurfaceVariant`）

> 历史兼容：`AppColors.ios*Light/Dark` 系统色常量（红/橙/黄/绿/…）保留供高亮预设、设置页图标底色等
> 功能色引用，各屏按批次迁移至 M3 token 后逐步退役。

---

## 7. 暗色模式规范

### 7.1 核心原则

1. **所有颜色必须来自 Theme Token**：通过 `Theme.of(context).colorScheme.*` 获取
2. **禁止硬编码颜色**：不允许在 widget 中直接写 `Colors.white`/`Colors.black`/`Color(0xFF...)` 作为通用 UI 颜色
3. **着色暗面（tonal，非纯黑）**：12 套调色板暗面 surface 均为带主题色调的深灰（如 wh `#141313`、sora `#111318`、koharu `#1A1111`）；唯 elink（墨水屏）按参考仓库为纯黑（登记例外）

### 7.2 对比度标准（WCAG AA）

| 类型 | 最低对比度 |
|------|-----------|
| 普通文本（< 18sp） | ≥ 4.5:1 |
| 大号文本（≥ 18sp 或 14sp 加粗） | ≥ 3:1 |
| 图标/图形元素 | ≥ 3:1 |

**自动化守护**：`test/unit/md3_palette_test.dart` 对 11 套不透明调色板 × 亮/暗全矩阵断言
onSurface/onSurfaceVariant/onPrimary/onXxxContainer×容器/surfaceContainer 系 ≥ 4.5；
登记例外：elink `onSecondaryContainer/secondaryContainer` = 3.95（参考仓库原始值，按 AA-large 3.0 守护）。

### 7.3 暗色模式检查清单

- [ ] 文本颜色使用 `onSurface` / `onSurfaceVariant`
- [ ] 图标颜色使用 `onSurfaceVariant` / `primary`
- [ ] 背景色使用 Tonal Surface 层次（1.2 节映射表）
- [ ] 分割线使用 `outline` / `outlineVariant`
- [ ] 状态色（成功/警告/错误）在暗色背景下对比度达标
- [ ] 无 `Colors.grey` / `Colors.black` / `Colors.white` 硬编码用于通用 UI

### 7.4 例外场景（允许硬编码）

| 场景 | 说明 |
|------|------|
| 阅读器/漫画阅读器 | 沉浸式全屏，自管理背景色（`reader_config_panel` 可跟随 colorScheme） |
| 视频播放覆盖层 | 半透明黑色遮罩 + 白色控件 |
| 滑动操作按钮 | 彩色背景 + 白色前景 |
| 主题配置预览 | 展示固定色板供用户选择（12 内置 + 自定义） |

---

## 8. 使用方式

```dart
// app.dart 装配：按 paletteId + themeMode（ThemeNotifier 驱动全局实时切换）
final palette = Md3Palettes.byId(themeState.paletteId);
MaterialApp(
  theme: AppTheme.palette(brightness: Brightness.light, palette: palette),
  darkTheme: AppTheme.palette(brightness: Brightness.dark, palette: palette),
  themeMode: themeState.themeMode, // 亮/暗/跟随系统
)

// 自定义主题 4 色叠加（themeConfigList 保留功能）
AppTheme.palette(
  brightness: Brightness.light,
  palette: palette,
  primary: c(themeColors.primary),          // AppBar 背景
  accent: c(themeColors.accent),            // primary/secondary/surfaceTint
  background: c(themeColors.background),    // surface/Scaffold
  bottomBackground: c(themeColors.bottomBackground), // 底部导航栏
)

// 在 Widget 中获取颜色
final colorScheme = Theme.of(context).colorScheme;
Text('标题', style: TextStyle(color: colorScheme.onSurface))
Icon(Icons.menu, color: colorScheme.onSurfaceVariant)
```

---

编写者：Qoder ｜ 2026-08-28（MD3 Batch 0：本档重写为 MD3 token 单一事实源，随 `md3_colors.dart`/`app_theme.dart` 落地同步）
