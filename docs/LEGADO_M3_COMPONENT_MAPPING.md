# Legado 安卓阅读 App：10 个界面 M3 组件映射表

源码范围严格限定：app/src/main。控件依据来自 app/src/main/res/layout、res/menu、res/values，以及 app/src/main/java/io/legado/app/ui。表中源码路径均指向安卓原版文件。

## 书架页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 书架页 | 顶部标题栏 | res/layout/fragment_bookshelf1.xml: title_bar (TitleBar) | CenterAlignedTopAppBar | height=64dp；titleLarge；containerColor=surface |
| 书架页 | 搜索按钮 | TitleBar toolbar action；MainActivity.kt | IconButton | size=48dp；icon=Search；ripple=surfaceVariant |
| 书架页 | 更多菜单 | res/menu/main_bookshelf.xml；Toolbar overflow | IconButton + DropdownMenu | size=48dp；icon=MoreVert；shape=corner.medium；elevation=level3 |
| 书架页 | 分组标签 | res/layout/view_tab_layout_min.xml；view_pager_bookshelf | PrimaryTabRow | height=48dp；indicator=primary；labelMedium |
| 书架页 | 书架统计 | res/layout/view_bookshelf_header.xml: tv_shelf_stats | Text | bodyMedium；color=onSurfaceVariant；padding=16dp |
| 书架页 | 继续阅读 | res/layout/view_bookshelf_header.xml: continue_reading | ElevatedCard + ListItem | minHeight=56dp；shape=corner.medium；elevation=level1 |
| 书架页 | 书籍列表 | res/layout/fragment_books.xml: rv_bookshelf | LazyVerticalGrid / LazyColumn | contentPadding=8dp；itemSpacing=12dp；overscroll=M3 |
| 书架页 | 书籍卡片 | res/layout/item_bookshelf_grid.xml: cv_content | Card | shape=corner.large；container=surfaceContainer；elevation=level2 |
| 书架页 | 封面 | item_bookshelf_grid.xml: iv_cover (CoverImageView) | Card media / AsyncImage | aspectRatio≈0.68；clip=corner.medium；contentScale=Crop |
| 书架页 | 未读徽标 | item_bookshelf_grid.xml: bv_unread (BadgeView) | Badge | labelSmall；container=error；content=onError |
| 书架页 | 阅读进度 | item_bookshelf_grid.xml: pb_read_progress | LinearProgressIndicator | height=4dp；indicator=primary；track=surfaceVariant |
| 书架页 | 空态 | fragment_books.xml: tv_empty_msg | EmptyState Column | icon=MenuBook；headlineSmall；action=FilledButton |
| 书架页 | 添加书籍 | BaseBookshelfFragment.kt 添加操作 | FloatingActionButton | size=56dp；shape=corner.large；container=primaryContainer；elevation=level6 |
| 书架页 | 刷新 | fragment_books.xml: refresh_layout (SwipeRefreshLayout) | PullToRefreshBox | indicator=CircularProgressIndicator；threshold=48dp |
| 书架页 | 底部导航 | activity_main.xml: bottom_navigation_view；res/menu/main_bnv.xml | NavigationBar | height=80dp；selectedIndicator=secondaryContainer；elevation=level6 |

## 发现页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 发现页 | 顶部栏 | res/layout/fragment_explore.xml: title_bar | TopAppBar | height=64dp；titleLarge；containerColor=surface |
| 发现页 | 搜索框 | res/layout/view_search.xml: search_view (SearchView) | SearchBar | height=56dp；shape=corner.medium；container=surfaceVariant；leading=Search |
| 发现页 | 分类筛选 | ExploreAdapter.kt 动态分类 View | FilterChip | height=32dp；shape=corner.full；selected=primaryContainer |
| 发现页 | 分组标题 | ExploreAdapter.kt: llTitle | ListItem | minHeight=48dp；titleMedium；trailing=ExpandMore |
| 发现页 | 结果列表 | fragment_explore.xml: rv_find | LazyColumn / Pager | contentPadding=16dp；verticalSpacing=12dp；overscroll=M3 |
| 发现页 | 结果卡片 | item_find_book.xml | ElevatedCard | shape=corner.large；elevation=level2；onClick=ripple |
| 发现页 | 结果封面 | item_find_book.xml: iv_cover | Card media | width=72dp；height=104dp；shape=corner.small |
| 发现页 | 结果标签 | ExploreAdapter.kt 标签 TextView | AssistChip | height=32dp；container=secondaryContainer；labelMedium |
| 发现页 | 快速滚动 | fragment_explore.xml: fast_scroller | FastScroller | width=4dp；thumb=primary；endPadding=4dp |
| 发现页 | 空态/错误 | fragment_explore.xml: tv_empty_msg；ExploreViewModel.kt | EmptyState / InlineErrorBanner | icon=Explore；重试=TextButton；位置=内容区 |

## RSS 订阅页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| RSS 订阅页 | 顶部栏 | res/layout/fragment_rss.xml: title_bar | TopAppBar | height=64dp；titleLarge；containerColor=surface |
| RSS 订阅页 | 搜索框 | fragment_rss.xml + view_search.xml: search_view | SearchBar | height=56dp；shape=corner.medium；container=surfaceVariant |
| RSS 订阅页 | 添加订阅源 | RssFragment.kt Toolbar action | IconButton | size=48dp；icon=Add；tint=primary |
| RSS 订阅页 | 源网格 | fragment_rss.xml: recycler_view | LazyVerticalGrid | spanCount=4；contentPadding=16dp；spacing=12dp |
| RSS 订阅页 | 源卡片 | res/layout/item_rss.xml | ElevatedCard | shape=corner.large；elevation=level2；minHeight=112dp |
| RSS 订阅页 | 源图标 | item_rss.xml ImageView | IconContainer / AsyncImage | size=48dp；shape=corner.medium；container=secondaryContainer |
| RSS 订阅页 | 未读徽标 | item_rss.xml 未读控件 | Badge | labelSmall；container=primary；content=onPrimary |
| RSS 订阅页 | 分组筛选 | RssFragment.kt group query | FilterChip | shape=corner.full；selectedContainer=primaryContainer |
| RSS 订阅页 | 空态 | fragment_rss.xml: tv_empty_msg | EmptyState | icon=RssFeed；headlineSmall；action=FilledButton |
| RSS 订阅页 | 底部导航 | activity_main.xml: bottom_navigation_view | NavigationBar | selectedItem=RSS；height=80dp；elevation=level6 |

## 我的/设置页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 我的/设置页 | 顶部栏 | res/layout/fragment_my_config.xml: title_bar | TopAppBar | height=64dp；titleLarge；containerColor=surface |
| 我的/设置页 | 偏好分组标题 | MyFragment.kt: MyPreferenceFragment / PreferenceCategory | ListSubheader | titleSmall；color=onSurfaceVariant；paddingTop=24dp |
| 我的/设置页 | 普通设置项 | PreferenceFragment.kt: Preference | ListItem | minHeight=64dp；headline=titleMedium；supporting=bodySmall；ripple |
| 我的/设置页 | 图标设置项 | res/layout/item_icon_preference.xml | ListItem + Icon | leadingIcon=24dp；tint=onSurfaceVariant |
| 我的/设置页 | 开关 | SwitchPreferenceCompat | Switch | width=52dp；checkedTrack=primary；thumb=onPrimary |
| 我的/设置页 | 单选项 | ListPreference + ListPreferenceDialog.kt | RadioDialog / ExposedDropdownMenu | shape=corner.medium；selected=primary |
| 我的/设置页 | 多选项 | MultiSelectListPreferenceDialog.kt | AlertDialog + Checkbox | container=surfaceContainerHigh；corner.extraLarge |
| 我的/设置页 | 数值设置 | PreferenceFragment SeekBarPreference | Slider | activeTrack=primary；track=surfaceVariant；valueLabel |
| 我的/设置页 | 备份恢复 | BackupConfigFragment.kt | FilledTonalButton | height=48dp；shape=corner.full；container=primaryContainer |
| 我的/设置页 | 底部导航 | activity_main.xml: bottom_navigation_view | NavigationBar | selectedItem=我的；height=80dp；elevation=level6 |

## 搜索页与搜索结果页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 搜索页 | 返回/标题栏 | res/layout/activity_book_search.xml: title_bar | TopAppBar | navigationIcon=ArrowBack；height=64dp；titleLarge |
| 搜索页 | 搜索输入框 | activity_book_search.xml + view_search.xml: search_view | SearchBar | height=56dp；singleLine；imeAction=Search；shape=corner.medium |
| 搜索页 | 搜索范围 | SearchScopeDialog.kt | FilterChip + ModalBottomSheet | selectedContainer=primaryContainer；elevation=level12 |
| 搜索页 | 搜索历史 | activity_book_search.xml: rv_history_key | AssistChip / ListItem | chip height=32dp；dismissIcon=Close |
| 搜索页 | 结果列表 | activity_book_search.xml: recycler_view | LazyColumn | contentPadding=16dp；verticalSpacing=12dp |
| 搜索页 | 结果项 | res/layout/item_search.xml | ElevatedCard + ListItem | shape=corner.large；elevation=level2；minHeight=112dp |
| 搜索页 | 来源标签 | item_search.xml 来源 TextView | AssistChip | container=secondaryContainer；labelMedium |
| 搜索页 | 加入书架 | item_search.xml 操作按钮 | FilledTonalButton | height=40dp；shape=corner.full；icon=Add |
| 搜索页 | 停止搜索 | activity_book_search.xml: fb_start_stop | SmallFloatingActionButton | size=40dp；container=primaryContainer；elevation=level6；icon=Stop |
| 搜索页 | 进度文本 | activity_book_search.xml: tv_search_progress | AssistiveSnackbar / PlainTooltip | labelSmall；anchor=FAB 上方 8dp；container=surfaceContainer |
| 搜索页 | 空态/错误 | activity_book_search.xml: content_view 状态层 | EmptyState / InlineErrorBanner | 重试=TextButton；Banner 位于结果列表顶部 |

## 书籍详情页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 书籍详情页 | 返回按钮 | res/layout/activity_book_info.xml: title_bar navigation | IconButton | size=48dp；icon=ArrowBack；tooltip=返回 |
| 书籍详情页 | 标题栏 | activity_book_info.xml: title_bar | TopAppBar | titleLarge；scrolledContainerColor=surface；height=64dp |
| 书籍详情页 | 封面 | activity_book_info.xml: iv_cover | Card media | width=128dp；aspectRatio=0.68；shape=corner.large |
| 书籍详情页 | 书名与作者 | activity_book_info.xml: tv_name、tv_author | Text / Column | titleLarge + bodyMedium；color=onSurface/onSurfaceVariant |
| 书籍详情页 | 分类标签 | activity_book_info.xml: lb_kind (LabelsBar) | AssistChip | height=32dp；shape=corner.full；container=secondaryContainer |
| 书籍详情页 | 元数据容器 | activity_book_info 信息 LinearLayout | ElevatedCard | shape=corner.extraLarge；container=surfaceContainer；elevation=level2 |
| 书籍详情页 | 开始阅读 | activity_book_info.xml: tv_read | FilledButton | height=48dp；shape=corner.full；container=primary |
| 书籍详情页 | 加入书架 | activity_book_info.xml: tv_shelf | FilledTonalButton | height=48dp；shape=corner.full；container=primaryContainer |
| 书籍详情页 | 简介 | view_book_intro.xml + tv_intro_toggle | ExpandableCard / ListItem | bodyLarge；trailingIcon=ExpandMore；动画=220ms |
| 书籍详情页 | 查看目录 | activity_book_info.xml: ll_toc、tv_toc_view | ListItem + TextButton | minHeight=48dp；trailing=TextButton；ripple |
| 书籍详情页 | 底部操作栏 | activity_book_info.xml: fl_action | BottomAppBar | height=64dp；container=surfaceContainer；elevation=level6 |

## 目录页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 目录页 | 返回按钮 | res/layout/activity_chapter_list.xml: title_bar navigation | IconButton | size=48dp；icon=ArrowBack |
| 目录页 | 目录标签 | activity_chapter_list.xml: view_pager + view_tab_layout | PrimaryTabRow | height=48dp；indicatorColor=primary |
| 目录页 | 章节搜索 | TitleBar contentLayout=view_search.xml | SearchBar | height=56dp；shape=corner.medium；leadingIcon=Search |
| 目录页 | 卷标题 | ChapterListFragment.kt volume header | ListSubheader | titleSmall；minHeight=48dp；trailing=章节数 |
| 目录页 | 章节列表 | ChapterListFragment.kt RecyclerView | LazyColumn | contentPadding=8dp；verticalSpacing=4dp |
| 目录页 | 章节行 | res/layout/item_chapter_list.xml | ListItem | minHeight=48dp；headline=bodyMedium；shape=corner.small |
| 目录页 | 当前章节 | item_chapter_list.xml selected state | ListItem selected | containerColor=primaryContainer；leadingIcon=Check |
| 目录页 | 已读标记 | item_chapter_list.xml 状态控件 | Badge | labelSmall；containerColor=secondaryContainer |
| 目录页 | 快速滚动 | FastScrollRecyclerView/FastScroller | FastScroller | thumbColor=primary；tooltip=章节索引 |
| 目录页 | 加载更多 | res/layout/view_load_more.xml | CircularProgressIndicator + ListItem | size=24dp；位置=列表底部 |

## 阅读页（日间）

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 阅读页（日间） | 正文渲染区 | res/layout/activity_book_read.xml: read_view (ReadView) | FullScreen ReaderSurface | background=readerSurface；elevation=level0；paddingHorizontal=20dp |
| 阅读页（日间） | 章节标题 | ReadView chapter title | Text headlineSmall | 24sp/w400/32sp；color=onSurface；marginBottom=24dp |
| 阅读页（日间） | 正文段落 | ReadView content | Text bodyLarge | 16sp；lineHeight=1.75；letterSpacing=0sp；color=onSurface |
| 阅读页（日间） | 阅读菜单 | activity_book_read.xml: read_menu；view_read_menu.xml | ModalBottomSheet | container=surfaceContainer；shape=corner.extraLarge；elevation=level12 |
| 阅读页（日间） | 章节搜索菜单 | activity_book_read.xml: search_menu | SearchBar + ModalSheet | height=56dp；container=surfaceVariant |
| 阅读页（日间） | 上一章/下一章 | ReadMenu actions | FilledTonalButton | height=48dp；shape=corner.full；disabled=onSurfaceVariant |
| 阅读页（日间） | 进度指示 | res/layout/view_detail_seek_bar.xml | Slider | activeTrack=primary；valueLabel=labelMedium |
| 阅读页（日间） | 朗读浮条 | res/layout/view_read_aloud_float_bar.xml | FloatingToolbar | height=56dp；shape=corner.large；elevation=level8 |
| 阅读页（日间） | 文本选择栏 | res/layout/view_select_action_bar.xml | FloatingToolbar | container=surfaceContainer；elevation=level8；actions=IconButton |
| 阅读页（日间） | 空态/错误 | ReadView 内容状态 | EmptyState / ErrorCard | readerSurface 居中；重试=TextButton |

## 阅读页（夜间）

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 阅读页（夜间） | 正文渲染区 | res/layout/activity_book_read.xml: read_view (ReadView) | FullScreen ReaderSurface | background=surface；夜间 surface=#0F1416；elevation=level0 |
| 阅读页（夜间） | 章节标题 | ReadView chapter title | Text headlineSmall | 24sp/w400/32sp；color=onSurface；禁止纯白高亮 |
| 阅读页（夜间） | 正文段落 | ReadView content | Text bodyLarge | 16sp；lineHeight=1.75；letterSpacing=0sp；color=onSurface |
| 阅读页（夜间） | 阅读菜单 | activity_book_read.xml: read_menu | ModalBottomSheet | container=surfaceContainer；shape=corner.extraLarge；elevation=level12 |
| 阅读页（夜间） | 进度指示 | res/layout/view_detail_seek_bar.xml | Slider | activeTrack=primary；inactiveTrack=surfaceVariant |
| 阅读页（夜间） | 昼夜切换 | ReadStyleDialog.kt / ReadMenu action | Switch | checkedTrack=primary；thumb=onPrimary；transition=220ms |
| 阅读页（夜间） | 选区高亮 | ReadView text selection | SelectionContainer | selectionColor=primaryContainer；handles=primary |
| 阅读页（夜间） | 朗读浮条 | res/layout/view_read_aloud_float_bar.xml | FloatingToolbar | container=surfaceContainer；elevation=level8；contentColor=onSurface |
| 阅读页（夜间） | 空态/错误 | ReadView 内容状态 | EmptyState / ErrorCard | container=surfaceContainer；icon=onSurfaceVariant；action=primary |

## 书源管理页

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 书源管理页 | 返回按钮 | res/layout/activity_book_source.xml: title_bar navigation | IconButton | size=48dp；icon=ArrowBack |
| 书源管理页 | 页面标题 | activity_book_source.xml: title_bar | TopAppBar | titleLarge；height=64dp；containerColor=surface |
| 书源管理页 | 搜索书源 | activity_book_source.xml + view_search.xml: search_view | SearchBar | height=56dp；shape=corner.medium；container=surfaceVariant |
| 书源管理页 | 分组筛选 | BookSourceActivity.kt group controls | FilterChip | height=32dp；shape=corner.full；selectedContainer=primaryContainer |
| 书源管理页 | 书源列表 | activity_book_source.xml: recycler_view | LazyColumn | contentPadding=16dp；verticalSpacing=12dp；overscroll=M3 |
| 书源管理页 | 书源行 | res/layout/item_book_source.xml | ElevatedCard + ListItem | minHeight=72dp；shape=corner.medium；elevation=level2 |
| 书源管理页 | 书源图标 | item_book_source.xml source icon | Avatar / IconContainer | size=40dp；shape=corner.full；container=secondaryContainer |
| 书源管理页 | 启用开关 | item_book_source.xml enabled control | Switch | width=52dp；checkedTrack=primary |
| 书源管理页 | 更多操作 | item_book_source.xml overflow | IconButton + DropdownMenu | size=48dp；icon=MoreVert；menu elevation=level3 |
| 书源管理页 | 拖拽排序 | BookSourceActivity.kt drag handle | ReorderableListItem | dragElevation=level8；pressedContainer=surfaceVariant；haptic=true |
| 书源管理页 | 添加书源 | BookSourceActivity.kt add action | FloatingActionButton | size=56dp；shape=corner.large；container=primaryContainer；elevation=level6 |
| 书源管理页 | 批量操作栏 | activity_book_source.xml: select_action_bar | ContextualBottomAppBar | height=64dp；container=surfaceContainer；批量操作=IconButton |
| 书源管理页 | 空态/错误 | RecyclerView 状态容器 | EmptyState / AssistiveBanner | icon=Public；错误 Banner 含导入/重试 TextButton |

## 统一属性约束

| 界面 | 元素名称 | 源码中的对应控件 | 映射的 M3 组件 | M3 组件的关键属性 |
|---|---|---|---|---|
| 全部界面 | 页面背景 | app/src/main/res/values/colors.xml: background；各根布局 | Scaffold | surface；日间/夜间由 ColorScheme 控制 |
| 全部界面 | 点击反馈 | XML selectableItemBackground、clickable/focusable | InteractionSource + ripple | pressed=surfaceVariant；focus ring=outline；动效=180-300ms |
| 全部界面 | 加载指示 | RefreshProgressBar、RotateLoading、view_loading.xml | LinearProgressIndicator / CircularProgressIndicator | 首屏优先骨架；增量请求用线性进度；不改变布局尺寸 |
| 全部界面 | 错误反馈 | Toast、Snackbar、动态错误 TextView | InlineErrorBanner + SnackbarHost | 持久错误内嵌；短暂操作反馈 Snackbar |
| 全部界面 | 系统安全区 | WindowInsets、status/navigation bar | Scaffold contentWindowInsets | 顶部/底部至少16dp内容安全区；导航栏高度80dp |

— Codex + UI，2026-08-29
