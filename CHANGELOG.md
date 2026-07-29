# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
