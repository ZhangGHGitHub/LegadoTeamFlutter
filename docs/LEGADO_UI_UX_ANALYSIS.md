# Legado 安卓阅读 App：UI/UX 与 M3 重构分析

## 一、源码证据与视觉基线

分析范围为 app/src/main。activity_main.xml 使用 ViewPager + ThemeBottomNavigationView；main_bnv.xml 明确提供四个主入口：书架、发现、RSS、我的。书架支持 BookshelfFragment1/2 两套样式以及网格/列表适配器；发现与 RSS 使用带搜索的 TitleBar + RecyclerView；我的页挂载偏好设置 Fragment。

源码主题色中 primary=@color/md_light_blue_600（#039BE5），primaryDark=md_light_blue_700，accent=md_pink_800；浅色背景为 md_grey_50（#FAFAFA），卡片/菜单层级为 md_grey_100/200，深色背景为 md_grey_850（#303030）。M3 稿将 #039BE5 作为种子色，构造 primary、onPrimary、secondaryContainer、surface、surfaceContainer、onSurface、onSurfaceVariant 语义角色。

## 二、主要界面清单

1. 书架页（Bookshelf）
2. 发现页（Explore）
3. RSS 订阅页
4. 我的/设置页
5. 搜索页与搜索结果页
6. 书籍详情页
7. 目录页
8. 阅读页（日间）
9. 阅读页（夜间）
10. 书源管理页

书源编辑、规则编辑、导入导出、自动任务、缓存、书签、朗读、漫画/视频等是从上述入口进入的次级流程，本批效果图聚焦主要页面。

## 三、《界面功能与布局分析》

### 1. 书架页 - 展示与继续阅读
用途：展示所有书籍，支持分组、排序、网格/列表切换、批量管理和继续阅读。
布局：状态栏 → 顶部 TitleBar（标题、搜索、更多）→ 统计与继续阅读提示 → ViewPager 分组内容 → 底部四项导航。
关键元素：封面卡片、未读 Badge、阅读进度条、分组 Tab、下拉刷新、空态、添加书籍入口。
源码依据：fragment_bookshelf1.xml、fragment_books.xml、view_bookshelf_header.xml、item_bookshelf_grid.xml、BookshelfFragment1/2。

### 2. 发现页 - 书源驱动的分类探索
用途：通过书源、分类、标签与关键字探索新书。
布局：TitleBar 内嵌搜索 → RecyclerView/分页列表 → FastScroller → 空态覆盖层。
关键元素：搜索框、分类 Chip、书源分组、发现结果卡片、加载/错误状态。
源码依据：fragment_explore.xml、ExploreFragment.kt、ExploreAdapter.kt。

### 3. RSS 订阅页 - 订阅源与未读文章
用途：管理 RSS 源并进入文章列表、收藏和阅读记录。
布局：TitleBar + 搜索 → 网格 RSS 源列表（spanCount=4）→ 空态 → 底部导航。
关键元素：源图标、未读数、分组 Chip、添加源、刷新和收藏入口。
源码依据：fragment_rss.xml、RssFragment.kt、RssAdapter.kt、item_rss*.xml。

### 4. 我的/设置页 - 偏好与数据工具
用途：集中承载阅读偏好、主题、备份恢复、书源/规则管理、日志与关于。
布局：TitleBar → PreferenceFragment/分组设置列表 → 二级页面或 Dialog。
关键元素：设置分类、开关、滑杆、选择项、备份恢复、关于与日志入口。
源码依据：fragment_my_config.xml、MyFragment.kt、ConfigActivity.kt、ThemeConfigFragment.kt。

### 5. 搜索页与搜索结果页 - 全书源检索
用途：输入书名/作者，跨书源检索并批量加入书架。
布局：TitleBar + view_search 搜索框 → 结果 RecyclerView → 进度提示/FAB 停止按钮 → 历史搜索抽屉。
关键元素：搜索历史、范围筛选、来源标签、加入书架 Chip、停止搜索 FAB、结果计数。
源码依据：activity_book_search.xml、activity_search_content.xml、SearchActivity.kt、SearchContentActivity.kt。

### 6. 书籍详情页 - 书籍元数据与操作
用途：查看封面、作者、来源、简介、目录状态，执行开始阅读、加入书架、换源、换封面。
布局：沉浸式 TitleBar → 封面与元数据卡 → 操作按钮行 → 简介 → 目录摘要与底部操作栏。
关键元素：封面、作者/来源/分组、标签、开始阅读主按钮、加入书架次按钮、简介展开、查看目录。
源码依据：activity_book_info.xml、view_book_intro.xml、BookInfoActivity.kt。

### 7. 目录页 - 章节定位
用途：按卷/章节浏览、搜索并跳转阅读位置，显示已读状态。
布局：TitleBar + Tab → 章节搜索 → RecyclerView 章节列表 → 定位/阅读操作。
关键元素：卷标题、章节行、已读标记、搜索、快速滚动、加载更多。
源码依据：activity_chapter_list.xml、TocActivity.kt、ChapterListFragment.kt。

### 8-9. 阅读页（日间/夜间） - 沉浸式正文阅读
用途：分页/滚动阅读正文，支持点击唤出菜单、目录、书签、划线、高亮、朗读和阅读设置。
布局：全屏 ReadView → 顶部章节信息（可隐藏）→ 正文排版区 → 底部页码/进度提示。
关键元素：正文、章节标题、进度、上一章/下一章、阅读菜单、字体/边距/背景配置、夜间切换。
源码依据：activity_book_read.xml、ReadBookActivity.kt、ReadMenu、ReadView、ui/book/read/config。

### 10. 书源管理页 - 来源与规则维护
用途：启用/禁用、排序、搜索、编辑和导入书源，进入调试与登录流程。
布局：返回型 TitleBar + 搜索 → 分组/筛选 Chip → 书源列表 → 添加 FAB/菜单。
关键元素：来源名称、URL、启用状态、拖拽排序、更多菜单、扫码/导入/调试操作。
源码依据：activity_book_source.xml、BookSourceActivity.kt、item_book_source.xml。

## 四、M3 设计落地建议

采用 4dp 基线、8/12/16dp 间距，顶部应用栏 64dp，导航栏 80dp，卡片圆角 12-16dp；主操作用 Filled Button，次操作用 Tonal/Outlined Button；来源/分类用 Assist/Filter Chip；搜索用 Filled Text Field。正文使用高可读衬线字体与 1.7-1.9 行高，夜间模式降低对比度而非纯黑白。

效果图位于 docs/ui_mockups/，文件名与清单一一对应。

— Codex + UI，2026-08-29

## 目录索引

1. 源码证据与视觉基线
2. 主要界面清单
3. 界面功能与布局分析
4. M3 设计落地建议
5. 📐 精修补充
   - M3 Design Token：LEGADO_M3_TOKEN_SPEC.md
   - 状态与空态：LEGADO_UI_STATE_SPEC.md
   - 组件映射：LEGADO_M3_COMPONENT_MAPPING.md
   - 微动效：LEGADO_UI_MOTION_SPEC.md
   - 无障碍：LEGADO_UI_ACCESSIBILITY_SPEC.md

## 📐 精修补充

本节汇总精修交付物，原有界面分析内容保持不变。所有补充均以 app/src/main 为源码范围；M3 推荐值与源码推断在各专项文档中逐项标注。

### 5.1 M3 Design Token 完整化

完整日间/夜间 ColorScheme、Type Scale、spacing、corner、elevation 及组件映射见 [LEGADO_M3_TOKEN_SPEC.md](LEGADO_M3_TOKEN_SPEC.md)。源码依据：app/src/main/res/values/colors.xml、colors_material_design.xml、dimens.xml、styles.xml；M3 依据：Material 3 Color Roles、Type Scale、Shape/Elevation 规范。

### 5.2 状态与空态

10 个界面的空态、加载态、错误态、边界态、交互反馈见 [LEGADO_UI_STATE_SPEC.md](LEGADO_UI_STATE_SPEC.md)。源码依据：对应 fragment/activity/item XML、RefreshProgressBar、RecyclerView、ReadView；M3 依据：Loading/Progress、Snackbar、Banner、overscroll、state-layer 推荐。

### 5.3 组件映射

逐元素 Android 控件到 M3 组件的映射见 [LEGADO_M3_COMPONENT_MAPPING.md](LEGADO_M3_COMPONENT_MAPPING.md)。源码依据：app/src/main/res/layout、res/menu、res/values 和 app/src/main/java/io/legado/app/ui；M3 依据：TopAppBar、NavigationBar、Card、SearchBar、Chip、Button、FAB、ListItem、Dialog、BottomSheet 等组件规范。

### 5.4 微动效

Tab 指示器、书架布局切换、搜索展开/收起、阅读工具栏、翻页、FAB、卡片 ripple 的时长、缓动、触发和可中断性见 [LEGADO_UI_MOTION_SPEC.md](LEGADO_UI_MOTION_SPEC.md)。源码依据：app/src/main/res/anim、animator，以及 ReadBookActivity.kt、ReadView.kt、PageDelegate.kt、MainActivity.kt；M3 依据：Material Motion standard/emphasized easing、State Layer、reduced motion。

### 5.5 无障碍清单

颜色对比度、48dp 触摸目标、contentDescription、200% 字体缩放和 TalkBack/键盘焦点顺序见 [LEGADO_UI_ACCESSIBILITY_SPEC.md](LEGADO_UI_ACCESSIBILITY_SPEC.md)。源码依据：布局控件尺寸、contentDescription、clickable/focusable、ReadView 自绘节点；规范依据：WCAG 2.1 AA 与 Android Accessibility 指南。

### 5.6 精修项验收状态

| 精修项 | 状态 | 交付物 | 源码依据标注 | M3 依据标注 |
|---|---|---|---|---|
| M3 Design Token | 已完成 | LEGADO_M3_TOKEN_SPEC.md | 已标注 | 已标注 |
| 状态与空态 | 已完成 | LEGADO_UI_STATE_SPEC.md | 已标注 | 已标注 |
| 组件映射表 | 已完成 | LEGADO_M3_COMPONENT_MAPPING.md | 已标注 | 已标注 |
| 微动效规格 | 已完成 | LEGADO_UI_MOTION_SPEC.md | 已标注 | 已标注 |
| 无障碍清单 | 已完成 | LEGADO_UI_ACCESSIBILITY_SPEC.md | 已标注 | WCAG/Android 已标注 |
