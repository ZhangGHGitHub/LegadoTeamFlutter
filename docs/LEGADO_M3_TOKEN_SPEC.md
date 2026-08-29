# Legado 10 个核心界面：Material Design 3 Token 规格表

适用范围：书架、发现、RSS、我的/设置、搜索、书籍详情、目录、阅读（日间）、阅读（夜间）、书源管理。

种子色：#039BE5（源码 app/src/main/res/values/colors.xml 的 primary -> md_light_blue_600）。实现时应引用语义 Token，不要在组件中直接写十六进制颜色。

## 1. 颜色系统

### 1.1 日间 ColorScheme

| Token | 值 | 使用场景 |
|---|---|---|
| primary | #00658A | 顶部应用栏动作图标、选中导航项、Filled Button、链接 |
| onPrimary | #FFFFFF | primary 背景上的文字与图标 |
| primaryContainer | #BEE9FF | 书架进度强调、选中状态容器、主要 FAB 容器 |
| secondary | #4C616B | 次要筛选、RSS 标签、辅助操作 |
| onSecondary | #FFFFFF | secondary 背景上的文字与图标 |
| surface | #F8FAFC | 页面 Scaffold、阅读日间基础背景 |
| onSurface | #171C1F | 页面标题、正文、书名、章节文本 |
| surfaceVariant | #DCE4E8 | 搜索框、筛选区域、列表弱填充、阅读分隔区域 |
| onSurfaceVariant | #40484C | 作者、来源、章节辅助信息、未选中图标 |
| outline | #70787C | Outlined Button、输入框边框、可操作分割线 |
| outlineVariant | #C0C8CC | 卡片弱边框、列表分隔线、禁用边界 |

### 1.2 夜间 ColorScheme

| Token | 值 | 使用场景 |
|---|---|---|
| primary | #6FD1FF | 夜间阅读菜单、选中导航项、链接、主操作 |
| onPrimary | #003548 | 夜间 primary 背景上的文字与图标 |
| primaryContainer | #004C63 | 夜间 FAB、选中章节、阅读进度容器 |
| secondary | #B4CBD5 | 夜间辅助操作、标签和筛选 |
| onSecondary | #1F333B | 夜间 secondary 背景上的文字与图标 |
| surface | #0F1416 | 夜间 Scaffold、阅读页基础背景 |
| onSurface | #DFE3E6 | 夜间标题、正文与章节内容 |
| surfaceVariant | #40484C | 夜间搜索框、控制区、弱填充容器 |
| onSurfaceVariant | #C0C8CC | 夜间辅助信息、未选中图标、元数据 |
| outline | #8A9297 | 夜间边框、Outlined Button、输入框轮廓 |
| outlineVariant | #40484C | 夜间分隔线、卡片弱边框、低强调边界 |

### 1.3 角色映射

| Token | 值 | 使用场景 |
|---|---|---|
| surfaceContainer | 日间 #EEF2F4 / 夜间 #1B2225 | 书籍卡片、RSS 源卡、设置项、目录行、书源行 |
| primaryContainer | 日间 #BEE9FF / 夜间 #004C63 | 继续阅读条、Filter Chip、已读章节、高亮操作区 |
| onSurfaceVariant | 日间 #40484C / 夜间 #C0C8CC | 作者、来源、统计、章节摘要、搜索提示 |

## 2. 字体系统（M3 Type Scale）

字重：w400=Regular，w500=Medium。格式为字号 / 字重 / 行高 / 字间距。

| Token | 值 | 使用场景 |
|---|---|---|
| displayLarge | 57sp / w400 / 64sp / -0.25sp | 统计页超大数字、阅读数据概览 |
| displayMedium | 45sp / w400 / 52sp / 0sp | 大型统计或空态主视觉 |
| displaySmall | 36sp / w400 / 44sp / 0sp | 详情页大型数值、沉浸式状态 |
| headlineLarge | 32sp / w400 / 40sp / 0sp | 设置分区或详情页大标题 |
| headlineMedium | 28sp / w400 / 36sp / 0sp | 详情页/阅读器章节主标题 |
| headlineSmall | 24sp / w400 / 32sp / 0sp | 页面大标题、阅读章节标题 |
| titleLarge | 22sp / w400 / 28sp / 0sp | Top App Bar 标题、书名 |
| titleMedium | 16sp / w500 / 24sp / 0.15sp | 书籍卡片主标题、列表项标题 |
| titleSmall | 14sp / w500 / 20sp / 0.1sp | Tab、分组标题、RSS 源名称 |
| bodyLarge | 16sp / w400 / 24sp / 0.5sp | 阅读正文、详情简介、长文本 |
| bodyMedium | 14sp / w400 / 20sp / 0.25sp | 搜索结果摘要、章节行、设置说明 |
| bodySmall | 12sp / w400 / 16sp / 0.4sp | 作者、来源 URL、统计、时间与进度 |
| labelLarge | 14sp / w500 / 20sp / 0.1sp | Filled/Tonal/Outlined Button 文案 |
| labelMedium | 12sp / w500 / 16sp / 0.5sp | Filter Chip、Badge、导航栏标签 |
| labelSmall | 11sp / w500 / 16sp / 0.5sp | 未读数、辅助状态、极小来源标记 |

## 3. 间距系统（dp）

| Token | 值 | 使用场景 |
|---|---|---|
| spacing.2 | 2dp | 进度条与卡片边缘、图标光学微调 |
| spacing.4 | 4dp | 图标与文字紧邻、Badge 内部微间距 |
| spacing.8 | 8dp | 卡片内部间距、列表项上下内边距 |
| spacing.12 | 12dp | 组件之间标准间距、卡片内部元素间距 |
| spacing.16 | 16dp | 页面水平边距、列表项左右内边距 |
| spacing.20 | 20dp | 详情封面与信息列间距、正文安全区 |
| spacing.24 | 24dp | 区块之间大间距、按钮组间距、空态留白 |
| spacing.32 | 32dp | 大区块分隔、简介与目录分隔 |
| spacing.40 | 40dp | 详情头部上下呼吸空间、空态图文间距 |
| spacing.48 | 48dp | 最小触控目标、列表行高、按钮高度 |
| spacing.56 | 56dp | Extended FAB/工具栏高度、操作区高度 |
| spacing.64 | 64dp | Top App Bar 高度、阅读页顶部安全区 |

## 4. 圆角系统（dp）

| Token | 值 | 使用场景 |
|---|---|---|
| corner.none | 0dp | 阅读正文背景、全宽分隔线 |
| corner.extraSmall | 4dp | Badge、进度条端点、紧凑标签 |
| corner.small | 8dp | Chip、Outlined TextField、章节行 |
| corner.medium | 12dp | 设置项、RSS 源卡、书源行、搜索框 |
| corner.large | 16dp | 书籍卡片、详情信息卡、标准 FAB |
| corner.extraLarge | 20dp | 详情主卡、继续阅读容器、强调卡片 |
| corner.full | 24dp | Stadium Button、Filter Chip、药丸控件 |

## 5. 高度/阴影系统（elevation，dp）

| Token | 值 | 使用场景 |
|---|---|---|
| elevation.level0 | 0dp | 阅读页正文、普通 Scaffold、无容器区域 |
| elevation.level1 | 1dp | 轻微浮起的搜索框、选中章节行 |
| elevation.level2 | 2dp | 书籍卡片、RSS 卡片、设置列表容器 |
| elevation.level3 | 3dp | 详情主卡、浮动筛选条、滚动后 App Bar |
| elevation.level4 | 4dp | 搜索结果浮层、目录快速操作条 |
| elevation.level6 | 6dp | 底部导航栏、标准 FAB、阅读菜单底栏 |
| elevation.level8 | 8dp | Extended FAB、悬浮工具面板、拖拽中的书源行 |
| elevation.level12 | 12dp | Dialog、Modal Bottom Sheet、全屏菜单过渡层 |

## 6. 组件与界面落地矩阵

| Token | 值 | 使用场景 |
|---|---|---|
| navigationBar | surfaceContainer + level6 + 80dp | 书架、发现、RSS、我的四项主导航 |
| topAppBar | surface + 64dp + titleLarge | 所有列表、详情与管理页顶部栏 |
| bookCard | surfaceContainer + corner.large/extraLarge + level2 | 书架网格、搜索结果、推荐结果 |
| searchField | surfaceVariant + corner.medium + 56dp | 发现、RSS、搜索、目录、书源管理 |
| filterChip | secondaryContainer + corner.small/full + labelMedium | 分类、搜索范围、RSS 分组、书源筛选 |
| primaryButton | primary/onPrimary + corner.full + 48dp | 详情“开始阅读”、搜索“加入书架” |
| tonalButton | primaryContainer/onSurface + corner.full + 48dp | 详情“加入书架”、次要操作 |
| fab | primaryContainer/onSurface + corner.large + level6 | 书架添加、RSS 新增、书源新增、搜索停止 |
| readerSurface | 日间 #F8FAFC / 夜间 #0F1416 + level0 | 阅读器正文与章节内容 |
| readerBody | bodyLarge + 行高 1.75 | 阅读正文排版 |
| tocRow | surfaceContainer，选中 primaryContainer，corner.small，最小 48dp | 目录章节、书签、高亮列表 |
| sourceRow | surfaceContainer + corner.medium + level2，最小 72dp | 书源管理、调试入口 |

## 7. 实施约束

1. 组件只引用上述语义 Token；禁止在页面代码中新增同义硬编码颜色、间距或圆角。
2. 日间/夜间只切换 ColorScheme 与阅读器专用表面，不改变信息架构、字号和触控目标。
3. 中文正文不使用负字间距；正文、章节、简介优先保证可读行高和左右安全区。
4. Android XML、Compose 或 Flutter 实现均应将这些 Token 映射为主题对象后再消费。

— Codex + UI，2026-08-29
