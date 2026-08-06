# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.3] - 2026-08-06

### 修复（阅读器点击翻页失效回归——Qoder）
- 阅读器点击翻页失效（P0 回归）根因修复：`reader_screen._handleTap` 命中 `TapAction.nextPage/prevPage` 时经 `ReaderNotifier.nextGlobalPage/prevGlobalPage` 走「全局连续分页」路径，该路径仅更新 `globalPageIndex/currentChapterPos` 状态，却从未驱动 `ReaderPageView` 内部的 `PageController`，故点击后视觉上不翻页；且其「`globalPageIndex` 未变才回退章级翻页」的兜底判定在同章翻页时永不成立（同章翻页必然 +1），兜底 `pageView.nextPageOrChapter()` 从不触发。改为在 `_handleTap` 中直接调用 `ReaderPageView.next/prevPageOrChapter()`——统一驱动 `PageController` 完成各翻页模式（仿真/滑动/覆盖/无动画/滚动）视觉翻页与跨章无缝切换；删除失效的 `_navigateNextPage/_navigatePrevPage`
- 全局页码指示器同步修复：`ReaderNotifier.updatePosition` 在更新章内页位后补调 `_syncGlobalPageInfo()`，使点击翻页与滑动手势翻页时底部「全局页 N/总页」指示器实时更新（此前仅 `updateChapterPageCount` 才刷新，章内翻页时指示器停滞）
- 实机 E2E 验证（emulator-5556）：滑动模式右侧点击 1/558→2/558→3/558、左侧点击 3→2、中间点击呼出/隐藏菜单；仿真模式右侧点击 2→3 均生效，滑动手势翻页未受影响

### 修复（书详情页章节列表区背景虚化覆盖——Qoder）
- 书详情页向下滚动到章节列表时背景无封面虚化修复：`book_info_screen._buildBody` 中章节列表 section（章节搜索/章节列表（N）头/列表项 ListTile/空态/底部间距）原使用不透明 `cs.surface` 背景，完全遮挡了 `_buildPage` 铺满全页的 `ImageFilter.blur` 封面虚化层，导致仅顶部封面区可见景深、下方列表区为纯色。改为半透明 scrim（`cs.surface` withValues alpha 0.82），让封面虚化背景隐约透出、整页保持 iOS 沉浸景深一致；仍保留足够对比度确保章节文字可读（方案 B）

### 变更（书详情页 iOS 视觉重设计 + 溢出菜单对齐原版 + 阅读器顶栏溢出修复，署名 Qoder）
- 书详情页封面高斯虚化背景：`book_info_screen._buildPage` 封面图改用 `ImageFiltered(ImageFilter.blur sigma 25)` 作背景层 + 保留半透明 scrim 叠层，营造 iOS 沉浸景深；无封面降级纯色背景不加模糊
- 顶栏精简至 iOS 导航栏节奏：移除下载/导出按钮（原版书详情无此入口）；编辑按钮条件化，仅在架书籍显示（对标原版 `editMenuItem.isVisible = inBookshelf`）；保留分享 + 更多菜单；标题固定「书籍信息」
- 溢出菜单对齐原版 book_info.xml：条目顺序/可见性对标原版（onMenuOpened 判定）——上传至远程(仅本地书)/刷新/创建更新任务(在架+书源+非本地+允许更新)/登录(书源支持)/置顶/设置源变量·书籍变量(书源存在)/拷贝书籍URL·目录URL/允许更新(勾选,书源存在)/拆分长章节(勾选,本地txt)/删除提醒(勾选)/清理缓存/日志；移除「更新目录」独立项（刷新即含目录更新）；文案「拷贝书籍链接/目录链接」→「拷贝书籍URL/目录URL」、「删除警告」→「删除提醒」；占位项(设置源/书籍变量·删除提醒·上传远程·创建更新任务)保持 _todo 标注不强行实现
- iOS 排版层级：书名改 SF Pro 大标题风格(22sp/w700/负字距)，底部按钮主次分明（放入书架=tinted、开始阅读=filled），分享图标改 `ios_share`
- 阅读器顶栏溢出修复：`reader_top_bar` 顶栏 Row 图标过多致 `RIGHT OVERFLOWED BY 68 PIXELS`，将换源/刷新/缓存（原 menu_group_on_line 三枚 IconButton）收入溢出菜单（仅在线书显示），顶栏仅保留高频的夜间/搜索/书签，Row 不再溢出

### 修复（未入库书详情页加载链路，署名 Qoder）
- 未入库书「目录/章节/封面」加载链路修复（三现象同源，对齐原版 BookInfoViewModel.upBook）：从搜索结果跳转的未入库书进入详情页时，`book_info_screen._loadData` 由「仅查 DB」改为完整链路——在线书 DB 无章节时按 origin 取书源，`webbookInfo` 补全封面/简介/tocUrl/字数（现象③封面缺失），`webbookChapters` 联网取目录用于展示（现象①共 0 章）；未入库时「仅展示不落库」（对齐原版 loadChapter 在 !inBookshelf 时不写 DB），避免污染书架（getBooks=find_all 无 notShelf 过滤）
- 阅读器「章节不存在/未配置书源」修复（现象②）：`_openReader` 对齐原版 readBook——未入库在线书阅读前先 `addBook` 带正确 origin 落库，使 Rust `get_chapter_content_full` 按 book.origin 找书源取正文成立，规避 refresh_toc 兜底插入空 origin 记录导致的第二章及后续报错；已入库则幂等跳过
- 阅读器「翻章后目录被清空 / 章节 N 不存在」根因修复（现象②真因，实机 E2E 定位）：`BookRepository::update` 此前复用 `insert` 的 `INSERT OR REPLACE INTO books`，主键冲突时会先删除旧 books 行再插入，触发 chapters 表 `ON DELETE CASCADE` 级联删除该书全部章节；每次翻章 `_saveProgress → update_reading_progress → repo.update` 都会清空目录，导致下一章「章节不存在」（影响所有在线书，非仅未入库）。改为真正原地 `UPDATE books SET ... WHERE bookUrl=?`（行不存在时退化 insert，保留 upsert 语义且不误触发级联删除），并新增回归测试 `test_update_book_preserves_chapters` 守护；实机验证翻章后 chapters 计数稳定 2598、第三/四章连续阅读正常
- WebBookInfo/WebChapter 为 snake_case（cover_url/toc_url/is_vip），手动映射合并而非 Book.fromJson 直解，避免封面/目录链接丢失
- 发现分类书籍 origin 丢失修复（同源缺陷，端到端验证时发现）：`rust_api.exploreFetchBooks` 返回的 Rust `WebSearchResult` 为 snake_case（book_url/cover_url/source_url，且无 origin/originName），此前直接 `SearchBook.fromJson`（期望 camelCase）会丢失 bookUrl/origin/coverUrl，导致从「发现」进入书详情页的未入库书同样共 0 章、无封面、阅读报「章节不存在」；改为显式归一化（兼容 snake/camel 两种键名）并用本次发现所属书源补齐 origin/originName，使详情页联网补全链路对搜索/发现两个入口一致生效
- 未入库书 notShelf 标记与书架过滤（对齐原版 `BookType.notShelf` / `BookDao.getBooksOnBookshelf`，彻底闭合上一条所述「污染书架」隐患）：新增 `BookType.notShelf`(0x400) / `book_type::NOT_SHELF`(1024) 常量与 `BookRepository::find_all_in_shelf`（`WHERE (type & 1024)=0 ORDER BY "order"`），`list_books` 改走书架过滤查询、`add_book` 改用原地 UPDATE 安全 upsert（避免对已存在临时书触发 INSERT OR REPLACE 级联删章节）；`_openReader` 阅读前落库时打 notShelf 位、`_toggleShelf`「加入书架」时清位转正。相比「详情页离开时清理临时记录」的退路方案，本方案复用既有 type 位标志、书架查询 O(1) 过滤且幂等，并能保留临时书阅读进度/已缓存章节（UX 更优），故择优采用。同步补齐 `update_preserving_read_config` 调用点由 `insert` 改 `update`（原地 UPDATE 三处调用点全覆盖）

### 修复（评审修复：三维评审问题收口，署名 Qoder）
- 搜索结果直达阅读：search_screen 搜索结果点击由弹出仅含「加入书架」的简易 AlertDialog 改为 `Navigator.pushNamed(bookInfo)` 跳转书详情页（对齐原版 SearchActivity→BookInfoActivity），补齐「开始阅读」入口——未入架时开始阅读自动 openBook 直达阅读器，无需先手动加书架；同步删除废弃的 `_showBookDetail`/`_addToBookshelf` 方法及 bookshelf_notifier 冗余引用
- rssUpdateSource 真实接线：`rust_api.updateRssSource` 由误接 `sourceUpdate`（按 BookSource 语义落 book_sources 表，产生幽灵书源脏数据且 RSS 变更静默丢失）改接 `bridge.rssUpdateSource` 原子更新管线，Mock 同步对齐「源不存在时报错」语义（审计缺口④至此全链闭合）
- 书架缓存导出：书架菜单新增缓存章节导出，新增 `BookApi.getCachedChapter` 封装（接通 `cacheGetChapter` FFI）逐章取缓存正文拼接 TXT 经分享通道保存；缓存管理页/epub·pdf/模板等扩展项 TODO(留批次) 登记（台账 §5.9）
- 嗅探委托合并：platform_bridge_service WebView 嗅探改为单一 NavigationDelegate（跳转拦截与加载终态等待共用，不再二次重设委托与二次加载），修复 JS 分支嗅探因委托覆盖必超时问题
- ttsSetCacheDir 初始化接线：`RustApi.init` 内注入应用支持目录 tts_cache（Rust 默认临时目录 Android 可能不可写），失败仅记日志不阻断初始化
- AutoTask 导入 id 碰撞修复：空 id 批量补齐改为基准时间戳拼接循环下标（`${baseId}_$i`），避免同一循环内 microsecondsSinceEpoch 重复导致 id 碰撞
- 日志入口补接：source_edit_screen「日志」菜单接通 AppLogScreen（批次0 遗漏项，日志入口销记口径修正为 7/7，补提交）
- 署名补齐：audio_screen/browser_screen/app.dart 共 3 处注释署名/标记补齐
- 台账口径修正：API_CONTRACT §3 待封装清单销记（登录 V2 三件套/ttsSpeak/cacheGetChapter/rssUpdateSource/ttsSetCacheDir）、审计报告 §7.3 留项修订 + §7.4 P2 处置明细（诚实口径）、UI_FIX_PLAN widget 测试验收口径显式修订、台账 v1.9 + §5.9 TODO(留批次) 登记

### 修复（批次3 P2 收尾：排版细节 + 菜单行为，署名 Qoder）
- 阅读器页面边距：阅读高级配置新增上/下/左/右四向边距滑杆（对标原版 ReadBookConfig paddingTop/Bottom/Left/Right），接入分页缓存键与排版渲染，默认值与历史行为零变化
- 阅读器设置编码：顶栏溢出菜单新增「设置编码」（对标原版 menu_set_charset → showCharsetConfig），写入 book.charset 并重载当前章，本地书乱码可按 UTF-8/GBK/GB18030 等候选重读
- 定时任务页溢出菜单：导入本地（txt/json）/导入线上（URL）/导出（exportAutoTask.json）/帮助，导入经 autoTaskPrepareImported FFI 合并本地运行时状态（对标原版 AutoTaskActivity menu_import_local/import_on_line/export/help）

### 销记（审计 P2 台账核验后无需改动）
- 日志入口 7/7：批次0 已接通 6 处 AppLogScreen（书架/搜索/书详/阅读器/听书/关于），source_edit_screen（书源编辑）为批次0 遗漏项随本次评审修复补接（补提交），销记
- 字距/段距/首行缩进/两端对齐：v2.0.2 已接入排版引擎，销记
- 书源导入排序：排序已应用于显示列表且导入后 reload 保持当前排序（原版 ImportBookSourceDialog 亦无排序 UI），判定对齐，销记

## [2.0.2] - 2026-08-06

### 修复（批次2 组A 阅读器系，署名 Qoder）
- 阅读器顶栏菜单补齐 10 项：重新加载当前章正文（替换规则开关重新分段）、同步已持久化书对象到 State 等，对齐原版 ReadBookActivity 菜单
- 阅读器源操作：批量换源链路接通（对标 Kotlin changeSource）
- 阅读配置 5 项：字体选择/字距调节/首行缩进/两端对齐（MoreConfig textFullJustify）接入排版参数与分页渲染，对标原版 ReadBookConfig
- 离线缓存：阅读器离线下载配置项接通（待 Rust 侧缓存体系补齐）
- 朗读控制条完善：read_aloud_bar 定时/目录/章节跳转等控制项补齐，阅读器底栏朗读入口接线 AudioNotifier.startReadAloud

### 修复（批次2 组B 书架书详，署名 Qoder）
- 书架菜单 7 项：更新目录接真实 refreshToc FFI、添加网址接 WebBook 入库（对标 addBookByUrl）、导入/导出书单对齐 Kotlin importBookshelf/exportBookshelf（url/json/文件三通道）等
- 书详页：登录接通书源登录链路（V2 动态协议+旧版凭据页）、置顶接 topBook FFI、清缓存接 clearCache FFI、批量换源入口（对标 changeSource）
- 书架管理页：批量置顶/置底（对标原版 + replace_rule_sel.xml menu_top_sel/menu_bottom_sel），重排后逐条持久化

### 修复（批次2 组C RSS·规则·换源·听书·设置+结构治理，署名 Qoder）
- RSS：文章列表菜单（登录/刷新/排序/设置源变量/编辑源/切换布局，对标 rss_articles.xml）、双列网格布局切换本地态（articleStyle 0-4）、详情收藏接 addRssStar/deleteRssStar/isStarred FFI（对标 RssFavoritesDialog）、阅读记录对话框（对标 ReadRecordDialog）、rssMarkRead 已读标记
- 替换规则：分组筛选（menu_group：全部/启用/禁用/无分组/分组:x）、批量模式（启用/禁用选中/置顶/置底/导出选中，对标 replace_rule_sel.xml）、网络/二维码导入接通确认页、新规则 pattern 预填
- 换源页：高级选项（搜索筛选/停止刷新切换/书源管理入口/刷新列表/校验作者开关/加载字数开关，对标 change_source.xml）+ 搜索筛选（对标 menu_screen SearchView）
- 听书页：溢出菜单 7 动作（换源/登录/复制播放地址/缓存目录选择/缓存范围/清当前章缓存等，对标 audio_play.xml）
- 设置页：登录/置顶/清缓存等入口接线
- 结构治理：删除 rss_config_screen.dart 及 rssConfig 路由（原版无此页，订阅源管理统一走 rssSourceManage）

### 修复（批次2 跨轨管线：WebView 拦截 + TTS 接线，署名 Qoder）
- WebView 桥接拦截：新建 platform_bridge_service.dart 统一承接 Rust 侧 7 个平台桥接 API（webView/webViewGetSource/webViewGetOverrideUrl/showBrowser/startBrowser/openUrl/openVideoPlayer）结构化 JSON 桥载荷；rust_api.dart 11 处拦截接入，browser_screen/routes/app.dart 联动打开真实 WebView/浏览器（Task #114）
- audioSpeak 接 ttsSpeak 真实管线：rust_api.dart audioSpeak 由 http.get 探活改接 bridge.ttsSpeak（模板替换+MD5 文件缓存+Content-Type 校验由 Rust 侧完成），异常降级探活保留 audio_notifier 既有保护（契约 §2.42，缺口②闭合，署名 QoderCN）
- 搜索内容页：支持阅读器长按选中文本作为初始查询词预填+自动搜索（对标 searchContentQuery）

## [2.0.1] - 2026-08-06

### 修复（批次0 纯接线快赢）
- 阅读器翻页动画入口：reader_top_bar 翻页动画菜单接 ReaderSettingsSheet（对标原版 ReadStyleDialog）
- 日志入口接线：书架/搜索/书详/书源编辑/阅读器菜单的「日志」项接通 AppLogScreen（对标原版 menu_log → AppLogDialog）
- 朗读配置页入口：听书页 TTS 设置面板新增「朗读引擎」入口，接通孤儿页 ReadAloudConfigScreen（对标原版 pref_aloud）
- 替换规则导入：replace_rules_screen 新增导入菜单，本地文件导入接通 ReplaceRuleImportConfirmScreen；网络/二维码导入缺导入 service，留批次2

### 修复（批次1 P0 长按选择 + 朗读链路）
- 阅读器正文长按选择：新增段落选区面板（SelectText 精细选区），接通复制/书签/高亮（5色）/词典/浏览器/分享，操作菜单对齐原版 content_select_action 顺序（审计 P0-1，署名 Qoder）
- 阅读器朗读链路：底栏朗读按钮接通朗读启动/播放暂停切换，新增朗读控制条（章节切换/语速 0.5-3.0x/目录/朗读设置/转后台），对标原版 ReadAloud 控制项（审计 P0-2，真实 TTS 管线待批次2，署名 Qoder）

### 新增（2026-07-31 重构遗留任务收尾）
- 排版引擎渲染侧整合（Task #34）：paragraph_layout_engine 接入 reader_screen，屏级分页 + 中文避头尾 + 两端对齐，847+ 测试通过
- 听书后台媒体按钮（Task #17）：MediaSession 通道注册 + AudioProvider 接线，锁屏/通知栏媒体控制 + 音频焦点管理，22/22 测试
- 发现页 exploreUrl 分类（Task #30）：新增 explore_show_screen + Rust explore_api，分类展开/翻页加载/搜索防抖，Rust 6+4 测试
- 压缩包导入 + 编码检测（Task #31）：archive_import_dialog 支持 zip/rar/7z 解压导入 + TXT 自动编码检测 + 手动编码选择 UI
- audio/auto_task FFI（Task #19 注册 + Task #32 接入）：legado-ffi 新增 9+2 个 FFI 方法，Flutter 侧完成接入
- QUIC 主网络链路（Task #43）：client.rs 集成可选 QUIC/HTTP3 + 失败自动 fallback HTTP/2，配置开关默认关闭，net 188 + ffi 79 测试
- M3 主题系统集中化（Task #39）：独立 app_theme.dart + app_typography.dart，light/dark 双 ColorScheme（用户确认 M3 方向）
- 响应式网格布局（Task #35）：bookshelf/rss/explore 改用 MaxCrossAxisExtent 自适应列数 + responsive.dart 断点工具
- SafeArea 安全边距（Task #36）：home_screen 导航栏与主体补充 SafeArea

### 修复（2026-07-31 UI 一致性）
- 长按多选精确化（Task #37）：长按多选限定封面区域，标题区域排除误触
- 全局 ScrollBehavior 统一（Task #38）：统一滚动物理，各列表手感一致
- Dark Mode 完整校验（Task #41）：42 个 screen 暗色对比度（WCAG ≥ 4.5）与图标可见性核验

### 优化（2026-07-31 性能与质量）
- 性能优化（Task #40）：cached_network_image 双缓存 + RepaintBoundary/稳定 Key/const 构造 + dispose 资源释放审计 + 冷启动/滚动 FPS/翻页性能基线
- 测试覆盖率（Task #33）：新增 +148 测试，Providers 层覆盖率达 72.4%，总计 855 测试全部通过

### 新增
- Tab 自定义图标：8 个安卓原版 SVG 图标（选中/未选中各 4 个）+ flutter_svg 集成 + home_screen.dart 导航栏替换
- 书架自定义刷新组件：custom_refresh_indicator.dart，对齐安卓下拉刷新动画
- 搜索分组筛选：分组/书源双 Tab 筛选面板，对齐安卓 SearchScopeDialog
- 导出路径选择与入口：FilePicker 路径选择 + book_info_screen/bookshelf_screen 双入口集成
- 崩溃防护体系：CrashLogService 全局错误捕获、runZonedGuarded 异步兖底、启动崩溃日志检测弹窗
- 崩溃日志弹窗组件，支持查看详情和清除日志

### 修复
- 阻塞修复：bookshelf_screen.dart dynamic 调用修复、reader_provider.dart 异步空安全、reader_screen.dart PageController hasClients 守卫
- 翻页动画参数对齐：300ms + linear，与安卓 PageDelegate 一致
- RSS 界面样式对齐：4 列网格 + 50x50 圆角图标居中
- 搜索框样式对齐：35dp 胶囊 + 半透明填充 + 0.5dp 描边
- 发现页样式对齐：AppBar 内嵌搜索框 + 扁平列表项

### 变更
- 路由参数规范化：bookInfo/changeSource/audio/searchContent/changeCover/export 6 个路由支持 Book 对象传递
- ExportDialog 参数从 bookId 改为 Book 对象，支持完整书籍信息导出

### 优化
- main.dart 启动流程：SharedPreferences 与 Rust FFI 并行初始化
- HomeScreen Tab 懒构建，减少首帧构建开销
- SettingsService/CacheService 全部方法添加异常保护
- BookshelfProvider/ReaderProvider loadSettings 下沉到首帧回调
- 添加启动阶段 Stopwatch 计时调试日志
- 移除章节预热缓存功能（`_prewarmChapterContent`），保持与 Android 原版一致

## [Unreleased]

### Added
- **JsExtensions 完整实现**：40+ 宿主 API（加密/编码/字符串/正则/JSON/文件/时间/网络/变量/Cookie），java 命名空间绑定，QuickJS 统一注册框架
- **服务端功能扩展**：书源调试 API（会话管理 + 步骤跟踪）、朗读引擎 API（状态机 + 段落分割）、书源规则更新 API、MCP Server（JSON-RPC 2.0 + 12 个 AI 工具）、目录更新 API
- **章节预加载状态机**：三章滑动窗口 + Semaphore 有界并发 + LRU 内存缓存 + 失败熔断器
- **音频预加载优化**：有界 LRU 淘汰 + 磁盘持久化 + 流式分块加载
- **自动任务执行层**：cron 调度策略 + 脚本执行 + 导入/导出 + REST 全 CRUD 7 端点
- **下载管理器**：优先级队列 + 并发池(3) + 暂停/恢复 + REST 5 端点
- **解压缩宿主 API**：zip 完整实现 + 7z/rar 桩化，java 命名空间双挂载
- **CacheManager + SourceLock + RuleComplete**：KV 缓存 + deadline 过期、singleFlight 并发控制、JSOUP/XPath 规则自动补全
- **数据库全覆盖**：25/25 表 Repository 100% 覆盖（新增 search_keywords/cookies/rssArticles/rssReadRecords/rssStars/txtTocRules 等 6 张表）
- **WebSocket 实时通道**：搜索进度推送 + 书源/RSS 调试日志流，5 个 WS 端点
- **DefaultData + Cron 解析**：JSON 默认数据导入 + 5/6 段 cron 表达式解析
- **ContentHelp 段落重排**：完整移植 Kotlin ContentHelp.kt（630 行）至 Rust
- **FFI 大规模扩展**：103+ FFI 导出函数，新增书签/替换规则/在线阅读/换源/AutoTask/RSS收藏/搜索历史/阅读记录/书籍分组/统计/缓存/配置/HTTP TTS/音频进度/Backup/Server/User/WebDAV/Download/Review 等 API
- **Flutter UI 完善**：40 个屏幕（+14）、10 个可复用组件、78 个新 Provider 测试、APK 构建 + 模拟器安装验证通过
- **MCP Server 12 工具接入真实数据库**：search_books/get_chapters/read_chapter/list_sources 等全部接入真实查询
- **用户管理**：users 表 + UserRepository + FFI 6 函数
- **本地 TXT 分词搜索**：TxtSearch 引擎（纯文本/正则 + 章节感知 + 上下文摘要 + 结果数限制）+ FFI 4 函数 + 18 个测试
- **阅读记录 + 书籍分组**：ReadRecordRepository + BookGroupRepository 完整 CRUD
- **HTTP TTS**：http_tts 表 + Repository + FFI 5 函数
- Multi-Agent parallel development scheme (5 roles)
- Module ownership matrix and branch protocol
- WebDAV sync FFI API (6 functions)
- Download Manager FFI API (8 functions)
- Review/paragraph comment FFI API (4 functions) + Flutter dialog
- Simulation page flip animation (ported from Kotlin SimulationPageDelegate.kt bezier algorithm)
- RSS article WebView rendering with JS execution and plain-text fallback
- Source editor rule validation (webbook search/info/chapters/content) and debug log enhancement
- Audio player timer/stop countdown with preset duration selector
- Video player screen with playback controls and fullscreen
- Comic reader screen with vertical scroll, pinch zoom, and image preloading
- CI auto-release workflow (flutter-release.yml)
- 16 new Flutter widget tests (page flip + paragraph comment)

### Changed
- **2026-07-29 源码深度审计**：整体迁移完成度修正为 ~80%（Rust ~85%，Flutter UI ~78%），识别 P0 缺口：排版引擎/导出UI/缓存管理
- **网络栈统一**：从独立 ureq 迁移至 LegadoClient，复用连接池、中间件、重试策略
- **引擎池化增强**：SharedScopeManager LRU 缓存 + 超时中断保护
- **flutter_rust_bridge codegen**：53 → 103+ Dart bindings，rust_api.dart 全量重写为真实 FFI 调用
- **Mutex 安全**：49 处 unwrap() 替换为 unwrap_or_else（毒性恢复，避免 panic 级联）
- **Backup 扩展**：备份范围新增 bookSources、rssSources、readRecords
- Agent configs specialized with role-specific prompts
- rust-ci.yml: exclude legado-ffi from workspace checks
- flutter-ci.yml: pin Flutter 3.41.7, add test step
- All workflows: upgrade actions/checkout to v7

### Fixed
- **java 命名空间核心修复**：`java.get()`/`java.post()`/`java.getStr()` 等关键方法可用
- **QuickJS 超时中断**：从相对时间修复为绝对 deadline
- **AnalyzeRule @js: 规则执行**：JsExecutor trait 注入模式解决跨 crate 循环依赖
- **EPUB 封面提取**：3 级 fallback 策略（cover meta → OPF item → 首图片）
- **MOBI 完善**：EXTH 元数据解析 + KF8 检测 + 错误处理增强
- **WebBook 真实链路**：AnalyzeUrl 模板解析 + LegadoClient HTTP + AnalyzeRule 规则解析，搜索→详情→目录→正文全流程
- **Flutter UI 修复**：clearCache 接入 RustApi、主题导入实现、SharedPreferences TODO 清理
- **FFI UnimplementedError 清零**：Flutter rust_api.dart 全部替换为真实实现
- Rust CI failure: legado-ffi needs Flutter/Dart toolchain not available in Rust CI
- Flutter CI failure: unspecified Flutter version didn't satisfy `sdk: ^3.11.5`
- Node.js 20 deprecation warnings in GitHub Actions
- Clippy redundant_closure warning in bridge.rs ffi_user_get_all

## [2.0.0] - 2026-07-26

### Added
- **Rust Core Engine**: Complete Rust workspace with 8 crates (core, parser, net, js, book, db, ffi, server)
- **Flutter UI**: 18 screens, 12 providers, cross-platform Material3 design
- **QuickJS Engine**: Real QuickJS runtime with 70+ host APIs, sandbox security, engine pooling
- **Rule Parser**: RuleAnalyzer with JSoup/XPath/JsonPath/Regex parsers + @js: mode
- **Network Layer**: LegadoClient with retry/rate-limit/proxy/UA rotation/SSL middleware
- **Book Parsers**: EPUB/TXT/MOBI/PDF/UMD format support + TXT/EPUB/HTML export
- **Database**: SQLite Schema v95, Room migration (v90-v95), 7 repositories
- **HTTP Server**: axum-based REST API with 25+ endpoints + Web SPA frontend
- **FFI Bridge**: flutter_rust_bridge v2.12.0 with 30+ export functions
- **Multimedia**: Audio playback with preload optimization, TTS integration
- **Reading Engine**: Chapter preloading state machine with LRU cache and failure circuit breaker
- **Security**: File API sandbox with path traversal protection
- **Cloud Sync**: WebDAV client for book data synchronization
- **i18n**: Chinese/English dual language support
- **CI/CD**: GitHub Actions workflows for Rust and Flutter
- **Build Scripts**: Windows one-click build (PowerShell + BAT)

### Changed
- Migrated from Android Kotlin to Rust core + Flutter UI architecture
- Network stack unified from ureq to LegadoClient (connection pooling, middleware chain)
- JS engine upgraded from stub to real QuickJS runtime with engine pooling

### Fixed
- QuickJS timeout interrupt (was using relative time instead of absolute deadline)
- Java namespace for book source JS scripts (java.xxx() calling convention)
- File API path traversal vulnerability (added sandbox validation)
- HostApiRegistry dead code removed (150 lines of empty TODOs)

## [1.0.0] - Legacy

### Description
- Original Android Kotlin implementation (io.legado.app)
- 329 releases tracked via git tags (3.YYMMDDHH format)
- Full-featured Android reading app with 60+ Kotlin models, 20+ services
