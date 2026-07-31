# Legado Flutter 设计规范文档

> 数据来源：`flutter_legado/lib/src/theme/app_colors.dart`、`app_typography.dart`、`app_theme.dart`
> 对齐基准：Android 端 `values/colors.xml` + `values-night/colors.xml`，M3 体系

---

## 1. 颜色 Token

### 1.1 亮色主题（Light）

| Token | 色值 | 用途 |
|-------|------|------|
| `primary` | `#039BE5` | 主色（AppBar、按钮、链接） |
| `onPrimary` | `#FFFFFF` | 主色上的前景（白色文字/图标） |
| `primaryContainer` | `#B3E5FC` | 主色容器背景 |
| `onPrimaryContainer` | `#01579B` | 主色容器前景 |
| `secondary` | `#AD1457` | 强调色（FAB、选中态） |
| `onSecondary` | `#FFFFFF` | 强调色上的前景 |
| `secondaryContainer` | `#F8BBD0` | 强调色容器背景 |
| `onSecondaryContainer` | `#880E4F` | 强调色容器前景 |
| `tertiary` | `#578FCC` | 第三色（辅助链接） |
| `error` | `#EB4333` | 错误色 |
| `onError` | `#FFFFFF` | 错误色上的前景 |
| `errorContainer` | `#FFDAD6` | 错误容器背景 |
| `onErrorContainer` | `#410002` | 错误容器前景 |
| `surface` | `#FFFFFF` | 表面色（卡片、对话框） |
| `onSurface` | `#DE000000`（87%黑） | 表面上的主要文字 |
| `surfaceContainerHighest` | `#F5F5F5` | 最高层容器背景 |
| `onSurfaceVariant` | `#8A000000`（54%黑） | 次要文字、图标 |
| `outline` | `#66666666`（40%灰） | 分割线、边框 |
| `outlineVariant` | `#39424242` | 弱边框 |
| `inverseSurface` | `#303030` | 反色表面（SnackBar） |
| `onInverseSurface` | `#F5F5F5` | 反色表面前景 |
| `scaffoldBackground` | `#FAFAFA` | 页面背景 |

### 1.2 暗色主题（Dark）

| Token | 色值 | 用途 |
|-------|------|------|
| `primary` | `#546E7A` | 主色 |
| `onPrimary` | `#FFFFFF` | 主色上的前景 |
| `primaryContainer` | `#37474F` | 主色容器背景 |
| `onPrimaryContainer` | `#CFD8DC` | 主色容器前景 |
| `secondary` | `#D84315` | 强调色 |
| `onSecondary` | `#FFFFFF` | 强调色上的前景 |
| `secondaryContainer` | `#BF360C` | 强调色容器背景 |
| `onSecondaryContainer` | `#FFCCBC` | 强调色容器前景 |
| `tertiary` | `#578FCC` | 第三色 |
| `error` | `#EB4333` | 错误色 |
| `onError` | `#FFFFFF` | 错误色上的前景 |
| `errorContainer` | `#93000A` | 错误容器背景 |
| `onErrorContainer` | `#FFDAD6` | 错误容器前景 |
| `surface` | `#303030` | 表面色 |
| `onSurface` | `#FFFFFF` | 表面上的主要文字 |
| `surfaceContainerHighest` | `#424242` | 最高层容器背景 |
| `onSurfaceVariant` | `#B3FFFFFF`（70%白） | 次要文字、图标 |
| `outline` | `#66666666` | 分割线、边框 |
| `outlineVariant` | `#39BDBDBD` | 弱边框 |
| `inverseSurface` | `#E0E0E0` | 反色表面 |
| `onInverseSurface` | `#303030` | 反色表面前景 |
| `scaffoldBackground` | `#212121` | 页面背景 |

### 1.3 通用色值（不区分亮暗）

| Token | 色值 | 用途 |
|-------|------|------|
| `transparent` | `#00000000` | 透明 |
| `black` | `#000000` | 纯黑（仅阅读器） |
| `white` | `#FFFFFF` | 纯白（仅 AppBar 前景等） |
| `lightBlue` | `#578FCC` | 链接蓝 |

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
