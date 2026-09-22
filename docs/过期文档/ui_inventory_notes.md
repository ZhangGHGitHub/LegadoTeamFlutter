# Legado 安卓 UI 界面清单与布局证据

> 依据 `app/src/main` 下 Activity/Fragment、layout、menu、values 资源静态分析整理。仅描述现有源码界面，不改变产品功能。

## 颜色与通用框架

- `activity_main.xml` 为竖向根布局：上方 `ViewPager`，下方 `ThemeBottomNavigationVIew`，菜单 `main_bnv.xml` 固定四项：书架、发现、RSS、我的。
- `colors.xml` 的主色链为 `primary -> md_light_blue_600`、深色 `primaryDark -> md_light_blue_700`、强调色 `accent -> md_pink_800`；背景为 `md_grey_50`，卡片 `md_grey_100`，菜单/底部 `md_grey_200`。M3 重绘时可将蓝色作为 seed，采用语义角色 primary/onPrimary/surface 等映射，避免直接写十六进制。
- 多数页面复用 `TitleBar`，可注入 `view_search`（搜索框）、`view_tab_layout`（标签页）或 `view_tab_layout_min`；列表统一使用 RecyclerView/FastScroller，空态通过 `tv_empty_msg`。

## 主要界面清单（建议效果图页面）

1. 书架页（`MainActivity` + `BooksFragment`；`fragment_bookshelf1/2.xml`）
2. 发现页（`ExploreFragment`；`fragment_explore.xml`）
3. RSS 源页（`RssFragment`；`fragment_rss.xml`）
4. 我的/设置入口页（`MyFragment`；`fragment_my_config.xml`）
5. 书籍搜索页（`SearchActivity`；`activity_book_search.xml`）
6. 搜索结果/书源筛选状态（搜索页菜单 `book_search.xml`，作为搜索页交互状态）
7. 书籍详情页（`BookInfoActivity`；`activity_book_info.xml`）
8. 章节目录页（`TocActivity`；`activity_chapter_list.xml`，含目录/书签/高亮标签）
9. 阅读页·日间（`ReadBookActivity`；`activity_book_read.xml`）
10. 阅读页·夜间（同上，夜间主题状态）
11. 阅读页搜索/阅读菜单浮层（`ReadMenu`、`SearchMenu`、`view_read_menu.xml`、`view_search_menu.xml`）
12. 书源管理页（`BookSourceActivity`；`activity_book_source.xml`）
13. 书源编辑/调试页（`BookSourceEditActivity`、`JsSourceEditActivity`、`BookSourceDebugActivity`；对应 `activity_book_source_edit.xml`、`activity_js_source_edit.xml`、`activity_source_debug.xml`）
14. 本地/远程导入书籍页（`ImportBookActivity`、`RemoteBookActivity`；`activity_import_book.xml`）
15. RSS 文章列表页（`RssSortActivity` + `RssArticlesFragment`；`activity_rss_artivles.xml`、`fragment_rss_articles.xml`）
16. RSS 文章阅读页（`ReadRssActivity`；`activity_rss_read.xml`）
17. RSS 收藏页（`RssFavoritesActivity/Fragment`；`activity_rss_favorites.xml`）
18. 设置页·通用/主题/备份/封面/欢迎（`ConfigActivity` + 五个 Config Fragment；`activity_config.xml`）
19. 阅读记录页（`ReadRecordActivity`；`activity_read_record.xml`）
20. 书签与高亮管理页（`AllBookmarkActivity`、`BookmarkFragment`、`HighlightFragment`；`activity_all_bookmark.xml`、`fragment_bookmark.xml`）
21. 文件管理/文件导入页（`FileManageActivity`、`HandleFileActivity`；`activity_file_manage.xml`）
22. 视频播放页（`VideoPlayerActivity`；`activity_video_player.xml`）
23. 漫画阅读页（`ReadMangaActivity`；`activity_manga.xml`）
24. 音频播放页（`AudioPlayActivity`；`activity_audio_play.xml`）
25. 关于页（`AboutActivity`；`activity_about.xml`）
26. 欢迎/初始化页（`WelcomeActivity`；`activity_welcome.xml`）

## 《界面功能与布局分析》

### 1. 书架页
**用途**：展示用户书籍、阅读进度与分组。`BooksFragment` 根据 `AppConfig.bookshelfLayout` 在网格/列表间切换，并支持按最近章节或更新时间排序。
**结构**：状态栏 → `TitleBar`（标题“书架”，可挂最小 Tab）→ `view_bookshelf_header`（分组/排序/布局控制）→ `ViewPager` 或 `SwipeRefreshLayout` 包裹的 RecyclerView → FastScroller/空态。主 Activity 底部为四项导航。
**元素**：书籍封面卡片（`item_bookshelf_grid*`）或列表行（`item_bookshelf_list*`）、分组标题、刷新手势、快速滚动条、空书架提示、管理/导入 FAB 或菜单动作。

### 2. 发现页
**用途**：浏览书源探索规则，按分组或关键词查找可发现书籍。
**结构**：TitleBar + 内嵌 SearchView（hint“发现”）→ `rv_find` 纵向结果列表 → FastScroller；无结果显示 `explore_empty`。
**元素**：搜索框、来源分组菜单（`main_explore.xml`）、发现书籍行（`item_find_book`）、来源编辑/管理入口。

### 3. RSS 源页
**用途**：管理并打开启用的 RSS 订阅源。
**结构**：TitleBar + SearchView → 4 列 Grid RecyclerView（`item_rss`）→ 空态。
**元素**：RSS 源图标/名称卡片、分组筛选菜单、阅读记录/收藏/源管理菜单。

### 4. 我的/设置入口页
**用途**：个人与应用配置入口。
**结构**：TitleBar（标题“我的”）→ PreferenceFragment 动态填充 `pre_fragment`；顶部菜单含帮助。
**元素**：偏好设置分类行（书源管理、主题、备份、其他）、开关/单选项、帮助入口。

### 5. 书籍搜索页
**用途**：跨书源搜索书名并汇总候选结果。
**结构**：TitleBar + SearchView → 2dp 搜索进度条 → RecyclerView 结果流；输入为空时展示书架快捷项和搜索历史；底部悬浮开始/停止 FAB。
**元素**：搜索输入、来源/分组/精确搜索菜单、结果行（`item_search`，封面/书名/作者/来源）、历史关键词、清除历史、进度计数、停止 FAB。

### 6. 书籍详情页
**用途**：查看书籍元数据、简介、章节并执行加入书架/更新/换源。
**结构**：全屏背景封面 `bg_book` + 半透明遮罩 → 深色 TitleBar → 可下拉 ScrollView；顶部居中封面卡片（110×160dp），下方标题/作者/标签、简介、操作区与章节预览。
**元素**：封面、书名/作者、来源标签、简介文本、加入书架/开始阅读按钮、更新/换源/编辑菜单、章节列表、加载状态。

### 7. 章节目录页
**用途**：按目录、书签、高亮定位章节。
**结构**：TitleBar 内嵌 TabLayout → ViewPager，三个 Fragment（ChapterList、Bookmark、Highlight）；支持 SearchView 搜索章节。
**元素**：标签页、章节行、书签/高亮条目、章节搜索、替换规则与字数统计菜单。

### 8. 阅读页（日间/夜间）
**用途**：沉浸式分页阅读，支持翻页、选文、朗读与阅读设置。
**结构**：全屏 `ReadView`；点击后显示 `ReadMenu` 覆盖层（顶部章节/进度，底部工具栏）；`SearchMenu` 用于正文检索；底部导航区域与朗读悬浮条。日间使用 surface/primary 文本对比，夜间切换深色 surface、onSurface 与较低亮度分割线。
**元素**：正文、章节标题/页码、进度 SeekBar、目录/上一章/下一章、字体与背景设置、自动阅读、朗读、正文搜索、选中文本操作。

### 9. 书源管理/编辑/调试
**用途**：维护书源规则、分组、启停与验证。
**结构**：TitleBar + SearchView → FastScrollRecyclerView 书源列表 → SelectActionBar 批量操作；编辑页为表单/代码编辑器，调试页显示请求与解析结果。
**元素**：启用开关、来源名称/域名/分组、拖拽排序、导入导出、检查书源、JS 代码编辑、调试日志。

### 10. 导入与文件管理
**用途**：从本地目录、远程 URL 或文件选择器导入书籍/书源。
**结构**：TitleBar + 搜索框 → 路径栏（返回按钮）→ 文件 RecyclerView；底部 SelectActionBar 批量确认。
**元素**：目录/文件行、路径文本、返回、全选/导入、进度条、空态。

### 11. RSS 文章列表/阅读/收藏
**用途**：浏览订阅源文章、阅读正文、收藏与朗读。
**结构**：文章页 TitleBar + 源 Tab 容器 + ViewPager；文章 Fragment 按样式使用线性/网格/瀑布流 RecyclerView。阅读页为 TitleBar + WebView 容器 + 顶部进度条。收藏页沿用列表与筛选。
**元素**：文章卡片（标题/摘要/时间/缩略图）、源标签、下拉刷新/加载更多、收藏、分享、浏览器打开、朗读、登录。

### 12. 设置、记录、书签、高亮、关于与媒体
**用途**：设置页承载通用/主题/备份/封面/欢迎偏好；记录和书签页提供阅读历史与标注管理；关于页展示版本与简介；视频/漫画/音频页分别提供媒体播放与专用控制。
**布局共性**：TitleBar 顶部，主体为 Preference/RecyclerView/WebView/播放器；使用菜单、Tab、FAB、BottomSheet 或对话框承载次级动作。

## 供 M3 效果图生成的统一约束

- 画布：390×844dp 竖屏，顶部系统状态栏 24dp；底部手势区 24dp。
- Seed：取源码 `md_light_blue_600` 近似蓝色作为动态色彩种子，生成 light/dark ColorScheme；所有组件仅使用 primary、onPrimary、surface、surfaceContainer、onSurface、secondary、error 等语义角色。
- 组件：TopAppBar、NavigationBar、FilledTonalButton、OutlinedButton、Card、FilterChip、AssistChip、LinearProgressIndicator、FloatingActionButton、ModalBottomSheet。
- 阅读器日间背景采用低对比 surface（米白/浅灰语义角色），夜间使用 dark surface；正文留白、行高和页码强调可读性。

编写者：Codex 子代理｜2026-08-29
