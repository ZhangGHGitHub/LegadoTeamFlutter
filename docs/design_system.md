# Legado Flutter 设计规范文档

> 数据来源：`flutter_legado/lib/src/theme/app_colors.dart`、`app_typography.dart`、`app_theme.dart`
> Token 来源基准：iOS Human Interface Guidelines 系统色（亮/暗两套），语义槽位与 Android 原版一一对应
>
> **定位说明（2026-08-05 更新）**：本文档描述当前主题 Token 体系，作为 UI 实现的统一依据。项目对齐标准为：**界面功能与交互流程对齐 Android 原版，UI 视觉风格自由**——当前视觉语言已切换为 iOS 体系，本文档中的色值/字号等可随设计演进更新，修改 Token 时需同步更新本档与代码实现，保持单一事实源。

---

## 1. 颜色 Token

### 1.1 亮色主题（Light）

| Token | 色值 | 用途 |
|-------|------|------|
| `primary` | `#007AFF` | 主色 / Tint（iOS 系统蓝，AppBar、按钮、链接） |
| `onPrimary` | `#FFFFFF` | 主色上的前景（白色文字/图标） |
| `primaryContainer` | `#D6E9FF` | 主色容器背景 |
| `onPrimaryContainer` | `#003E82` | 主色容器前景 |
| `secondary` | `#FF2D55` | 强调色（iOS 系统粉，FAB、选中态） |
| `onSecondary` | `#FFFFFF` | 强调色上的前景 |
| `secondaryContainer` | `#FFDCE3` | 强调色容器背景 |
| `onSecondaryContainer` | `#8A0F2E` | 强调色容器前景 |
| `tertiary` | `#5856D6` | 第三色（iOS 系统靛蓝） |
| `error` | `#FF3B30` | 错误色（iOS 系统红） |
| `onError` | `#FFFFFF` | 错误色上的前景 |
| `errorContainer` | `#FFDAD6` | 错误容器背景 |
| `onErrorContainer` | `#410002` | 错误容器前景 |
| `surface` | `#FFFFFF` | 表面色（卡片、对话框） |
| `onSurface` | `#000000` | 表面上的主要文字（Label） |
| `surfaceContainerHighest` | `#F2F2F7` | 最高层容器背景（iOS Grouped Background） |
| `onSurfaceVariant` | `#993C3C43`（60% Secondary Label） | 次要文字、图标 |
| `outline` | `#4A3C3C43`（29% Separator） | 分割线、边框 |
| `outlineVariant` | `#1E3C3C43`（12% hairline） | 弱边框 |
| `inverseSurface` | `#1C1C1E` | 反色表面（SnackBar） |
| `onInverseSurface` | `#F2F2F7` | 反色表面前景 |
| `scaffoldBackground` | `#F2F2F7` | 页面背景（iOS Grouped Background） |

### 1.2 暗色主题（Dark）

| Token | 色值 | 用途 |
|-------|------|------|
| `primary` | `#0A84FF` | 主色 / Tint（iOS 系统蓝·暗） |
| `onPrimary` | `#FFFFFF` | 主色上的前景 |
| `primaryContainer` | `#0A3A6B` | 主色容器背景 |
| `onPrimaryContainer` | `#D6E9FF` | 主色容器前景 |
| `secondary` | `#FF375F` | 强调色（iOS 系统粉·暗） |
| `onSecondary` | `#FFFFFF` | 强调色上的前景 |
| `secondaryContainer` | `#5C0F22` | 强调色容器背景 |
| `onSecondaryContainer` | `#FFDCE3` | 强调色容器前景 |
| `tertiary` | `#5E5CE6` | 第三色（iOS 系统靛蓝·暗） |
| `error` | `#FF453A` | 错误色（iOS 系统红·暗） |
| `onError` | `#FFFFFF` | 错误色上的前景 |
| `errorContainer` | `#93000A` | 错误容器背景 |
| `onErrorContainer` | `#FFDAD6` | 错误容器前景 |
| `surface` | `#1C1C1E` | 表面色（Secondary Grouped Background） |
| `onSurface` | `#FFFFFF` | 表面上的主要文字（Label） |
| `surfaceContainerHighest` | `#2C2C2E` | 最高层容器背景（Tertiary Grouped Background） |
| `onSurfaceVariant` | `#99EBEBF5`（60% Secondary Label） | 次要文字、图标 |
| `outline` | `#99545458`（60% Separator） | 分割线、边框 |
| `outlineVariant` | `#1E545458`（12% hairline） | 弱边框 |
| `inverseSurface` | `#F2F2F7` | 反色表面 |
| `onInverseSurface` | `#1C1C1E` | 反色表面前景 |
| `scaffoldBackground` | `#000000` | 页面背景（iOS Dark Grouped Background） |

### 1.3 通用色值（不区分亮暗）

| Token | 色值 | 用途 |
|-------|------|------|
| `transparent` | `#00000000` | 透明 |
| `black` | `#000000` | 纯黑（仅阅读器） |
| `white` | `#FFFFFF` | 纯白（仅 AppBar 前景等） |
| `lightBlue` | `#578FCC` | 链接蓝（历史语义色，部分阅读器配色引用） |

> iOS 系统色补充（`AppColors.ios*Light/Dark`，用于高亮预设、开关绿、徽标等场景）：
> 红 `#FF3B30`/`#FF453A`、橙 `#FF9500`/`#FF9F0A`、黄 `#FFCC00`/`#FFD60A`、绿 `#34C759`/`#30D158`、
> 薄荷绿 `#00C7BE`/`#63E6E2`、青 `#5AC8FA`/`#40C8E0`、蓝 `#007AFF`/`#0A84FF`、靛蓝 `#5856D6`/`#5E5CE6`、
> 紫 `#AF52DE`/`#BF5AF2`、粉 `#FF2D55`/`#FF375F`、棕 `#A2845E`/`#AC8E68`（亮/暗）。

---

## 2. 字体层级

对齐安卓端 sp 值：28 / 22 / 18 / 16 / 14 / 12

| 层级 | M3 映射 | 字号 | 字重 | 行高 | 字间距 | 用途 |
|------|---------|------|------|------|--------|------|
| display | `displayLarge` / `displayMedium` | 28 | w400 | 1.2 | -0.25 / 0 | 大标题 |
| largeTitle | `displaySmall` / `headlineMedium` | 22 | w400 / w500 | 1.2 | 0 | 页面标题 |
| title | `headlineSmall` / `titleLarge` | 18 | w500 | 1.2 | 0 / 0.15 | 区块标题 |
| titleMedium | `titleMedium` | 16 | w500 | 1.4 | 0.15 | 列表主文字 |
| titleSmall | `titleSmall` | 14 | w500 | 1.4 | 0.1 | 小标题 |
| body | `bodyLarge` | 16 | w400 | 1.5 | 0.5 | 正文 |
| bodyMedium | `bodyMedium` | 14 | w400 | 1.5 | 0.25 | 辅助正文 |
| caption | `bodySmall` | 12 | w400 | 1.4 | 0.4 | 小字说明 |
| label | `labelLarge` | 14 | w500 | 1.4 | 0.1 | 按钮文字 |
| labelMedium | `labelMedium` | 12 | w500 | 1.4 | 0.5 | 标签 |
| labelSmall | `labelSmall` | 10 | w500 | 1.4 | 0.5 | 极小标签 |

**行高规范**：标题类 1.2、正文类 1.5、辅助/标签类 1.4

---

## 3. 间距 Token

| Token | 值 | 用途 |
|-------|-----|------|
| `spacing.xs` | 4 | 图标与文字间距、紧凑内边距 |
| `spacing.sm` | 8 | 列表项内部小间距 |
| `spacing.md` | 12 | 输入框内边距、卡片内元素间距 |
| `spacing.lg` | 16 | 列表项水平内边距、区块间距 |
| `spacing.xl` | 24 | 区块之间大间距 |
| `spacing.xxl` | 32 | 页面级分隔 |

---

## 4. 圆角 Token

| Token | 值 | 用途 |
|-------|-----|------|
| `radius.sm` | 8 | 按钮、输入框、弹出菜单、SnackBar |
| `radius.md` | 12 | 卡片 |
| `radius.lg` | 16 | 对话框、BottomSheet |

---

## 5. 组件主题约定（14 个）

### 5.1 AppBar
- 背景：`colorScheme.primary`（亮 `#039BE5` / 暗 `#546E7A`）
- 前景：`#FFFFFF`
- 标题左对齐，elevation 4

### 5.2 NavigationBar（底部导航）
- 背景：`scaffoldBackgroundColor`
- 指示器：`secondary` 12% 透明度
- elevation 1

### 5.3 Card
- 背景：亮 `#F5F5F5` / 暗 `#303030`
- 边框：亮 `#39424242` / 暗 `#39BDBDBD`
- 圆角 12，elevation 0

### 5.4 ElevatedButton
- 背景：`colorScheme.primary`
- 前景：`colorScheme.onPrimary`
- 圆角 8，elevation 0

### 5.5 TextButton
- 前景：`colorScheme.primary`

### 5.6 InputDecoration（输入框）
- 填充色：`surfaceContainerHighest` 40% 透明度
- 圆角 8，无边框
- 内边距：水平 12、垂直 12

### 5.7 ListTile
- 水平内边距：16
- 图标色：`colorScheme.onSurfaceVariant`

### 5.8 Divider（分割线）
- 颜色：亮 `#8FE0E0E0` / 暗 `#FF363636`
- 厚度 0.5，间距 1

### 5.9 FloatingActionButton
- 背景：`colorScheme.primary`
- 前景：`colorScheme.onPrimary`
- elevation 2

### 5.10 Dialog
- 背景：`colorScheme.surface`
- 圆角 16

### 5.11 BottomSheet
- 背景：`colorScheme.surface`
- 顶部圆角 16

### 5.12 TabBar
- 选中色：`colorScheme.primary`
- 未选中色：`colorScheme.onSurfaceVariant`
- 指示器：`colorScheme.primary`

### 5.13 Switch
- 选中 thumb：`colorScheme.primary`
- 未选中 thumb：亮 `#737373` / 暗 `#737373`
- 选中 track：`primary` 30% 透明度
- 未选中 track：`outline` 30% 透明度

### 5.14 PopupMenu
- 背景：`colorScheme.surface`
- 圆角 8

### 5.15 SnackBar
- 背景：`colorScheme.inverseSurface`
- 文字：`colorScheme.onInverseSurface`
- 浮动式，圆角 8

---

## 6. 图标使用规范

| 场景 | 颜色 Token | 说明 |
|------|-----------|------|
| 列表前导图标 | `colorScheme.onSurfaceVariant` | 通过 ListTileTheme 统一 |
| 操作图标（AppBar） | `AppBar.foregroundColor`（白色） | 跟随 AppBar 主题 |
| 功能入口图标 | `colorScheme.primary` | 强调可交互 |
| 空状态占位图标 | `colorScheme.onSurfaceVariant` | 低对比、不抢眼 |
| 状态指示图标 | 语义色（green/orange/error） | 需适配亮暗（暗色用 shade300） |
| 媒体覆盖层图标 | `#FFFFFF` | 仅在深色覆盖层上使用 |

**禁止**：
- 禁止使用 `Colors.black` 作为通用图标色（暗色下不可见）
- 禁止使用 `Colors.grey` 硬编码（应使用 `onSurfaceVariant`）

---

## 7. 暗色模式规范

### 7.1 核心原则

1. **所有颜色必须来自 Theme Token**：通过 `Theme.of(context).colorScheme.*` 获取
2. **禁止硬编码颜色**：不允许在 widget 中直接写 `Colors.white`/`Colors.black`/`Color(0xFF...)` 作为通用 UI 颜色
3. **语义色需适配亮暗**：如 `Colors.green.shade800`（亮色）→ `Colors.green.shade300`（暗色）

### 7.2 对比度标准（WCAG AA）

| 类型 | 最低对比度 |
|------|-----------|
| 普通文本（< 18sp） | ≥ 4.5:1 |
| 大号文本（≥ 18sp 或 14sp 加粗） | ≥ 3:1 |
| 图标/图形元素 | ≥ 3:1 |

### 7.3 暗色模式检查清单

- [ ] 文本颜色使用 `onSurface` / `onSurfaceVariant`
- [ ] 图标颜色使用 `onSurfaceVariant` / `primary`
- [ ] 背景色使用 `surface` / `surfaceContainerHighest` / `scaffoldBackgroundColor`
- [ ] 分割线使用 `outline` / `dividerColor`
- [ ] 状态色（成功/警告/错误）在暗色背景下对比度达标
- [ ] 无 `Colors.grey` / `Colors.black` / `Colors.white` 硬编码用于通用 UI

### 7.4 例外场景（允许硬编码）

| 场景 | 说明 |
|------|------|
| 阅读器/漫画阅读器 | 沉浸式全屏，自管理背景色 |
| 视频播放覆盖层 | 半透明黑色遮罩 + 白色控件 |
| 滑动操作按钮 | 彩色背景 + 白色前景 |
| 主题配置预览 | 展示固定色板供用户选择 |

---

## 8. 使用方式

```dart
// 在 MaterialApp 中配置
MaterialApp(
  theme: AppTheme.light,
  darkTheme: AppTheme.dark,
  themeMode: ThemeMode.system, // 跟随系统
)

// 在 Widget 中获取颜色
final colorScheme = Theme.of(context).colorScheme;
Text(
  '标题',
  style: TextStyle(color: colorScheme.onSurface),
)
Icon(
  Icons.menu,
  color: colorScheme.onSurfaceVariant,
)
```
