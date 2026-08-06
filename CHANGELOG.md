# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.1] - 2026-08-06

### 修复（批次0 纯接线快赢）
- 阅读器翻页动画入口：reader_top_bar 翻页动画菜单接 ReaderSettingsSheet（对标原版 ReadStyleDialog）
- 日志入口接线：书架/搜索/书详/书源编辑/阅读器菜单的「日志」项接通 AppLogScreen（对标原版 menu_log → AppLogDialog）
- 朗读配置页入口：听书页 TTS 设置面板新增「朗读引擎」入口，接通孤儿页 ReadAloudConfigScreen（对标原版 pref_aloud）
- 替换规则导入：replace_rules_screen 新增导入菜单，本地文件导入接通 ReplaceRuleImportConfirmScreen；网络/二维码导入缺导入 service，留批次2

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
