# Legado Rust+Flutter 重构进度

> 最后更新：2026-07-27

---

## 总览

- **已完成**：107 / 107 原子任务（100%）
- **测试状态**：cargo test 1225 passed（默认）/ 1392 passed（含 QuickJS）| flutter test 30 passed | flutter analyze 0 issues
- **QuickJS feature**：309 tests passed
- **里程碑**：🎉 Flutter FFI bridge 全部接通，端到端流程可用

---

## 已完成（107/107 原子任务）

### 阶段 0：基础设施 ✅

- [x] Rust workspace 骨架（8 crate）
- [x] Flutter 项目骨架
- [x] 数据模型定义（Rust + Dart）
- [x] FFI 接口规范

### 阶段 1：Rust 核心引擎 ✅

- [x] 规则解析引擎（RuleAnalyzer + JSoup/XPath/JsonPath/Regex 四解析器 + AnalyzeRule 统一门面 + @js: 模式）
- [x] JS 沙箱引擎（QuickJS 真实实现：内存限制 + 超时中断 + 沙箱安全 + HostApiRegistry + 10 宿主 API + SharedScopeManager LRU）
- [x] HTTP 网络层（LegadoClient + CookieStore + URL 模板 + 封面缓存 + RSS/Atom 解析 + WebDAV 客户端 + 验证并发去重）
- [x] 书籍格式解析（EPUB/TXT/MOBI/PDF 完整解析器 + LocalBook 统一入口）
- [x] 数据库层（SQLite Schema v95 + 4 Repository: Book/BookSource/BookChapter/AutoTask + MigrationRegistry v90→v95 + RoomImporter）
- [x] 加密工具（AES/DES/RC4）
- [x] 排版引擎
- [x] 换源匹配器

### 阶段 2：Flutter UI + FFI ✅

- [x] FFI 导出函数（30+ 函数）
- [x] Flutter 全部页面（6 个）
  - 书架：分组 / 拖拽排序
  - 阅读器：3 种翻页模式（仿真 / 滑动 / 滚动）
  - 搜索：历史记录
  - 书源管理
  - 设置：主题切换 / 备份恢复
  - RSS 订阅
- [x] flutter_rust_bridge 代码生成
- [x] Flutter-FFI 真实联通（RustApi 服务层）
- [x] 阅读器增强（3 种翻页、设置持久化）
- [x] 书架增强（分组、拖拽）
- [x] 搜索增强（历史）
- [x] 数据备份 / 恢复（BackupService）
- [x] 封面图片缓存

### 阶段 3：集成与扩展 ✅

- [x] Android 平台桥接（WebView / TTS / 通知 / 文件选择器 四个 MethodChannel）
- [x] HTTP 服务（axum + 20+ REST API 端点 + 静态文件服务）
- [x] Web 阅读前端（SPA）
- [x] HTTP TTS 引擎
- [x] RSS/Atom Feed 解析器
- [x] WebDAV 云同步客户端
- [x] 数据库迁移框架（v90→v95）
- [x] Room 数据导入（RoomImporter）
- [x] 上游变更同步（20 个 Kotlin 提交）
  - VerificationFlightRegistry 并发去重
  - 段评 @js: 规则执行
  - readConfig 字段级更新
  - AutoTask Repository + 批量 cron
  - 定时任务导出/导入

### 阶段 4：国际化与收尾 ✅

- [x] Flutter 国际化（中英文双语，手动 l10n 方案）
- [x] 语言切换功能（设置页面，SharedPreferences 持久化）
- [x] 5 个主要页面国际化（书架、搜索、阅读器、设置、首页）
- [x] SettingsService 新增 getLocale/setLocale 方法
- [x] 阅读统计页面
- [x] 听书播放器页面
- [x] 书源编辑器页面

### 阶段 5：最终收尾 ✅

- [x] 创建 DEVELOPMENT.md 开发者快速上手指南
- [x] 更新 PROGRESS.md 完整记录所有 49 个任务
- [x] 更新 README.md 最终统计数据
- [x] 最终测试验证（workspace 419 passed + QuickJS 102 passed）
- [x] 项目交接总结与开发者指南

### 阶段 6：核心链路完善 ✅

- [x] Task #50: AnalyUrl 完整模板引擎（分页、动态参数、POST body、header 规则）
- [x] Task #51: 书签管理与替换规则（BookmarkRepository + ReplaceRuleRepository + Flutter 页面）
- [x] Task #52: WebBook 搜索完整链路（书源规则驱动：搜索→详情→目录→内容）
- [x] Task #53: 网络中间件增强（UA 轮换、代理配置、SSL 配置、重试策略完善）
- [x] Task #54: 书源发现与有效性检查（ExploreRule + SourceChecker + 发现页面）
- [x] Task #55: Flutter 集成测试与定时任务 UI（AutoTask 页面 + 集成测试套件）
- [x] Task #56: 书籍导出服务（TXT/EPUB 导出 + 缓存管理）
- [x] Task #57: 离线缓存与段评（CacheBook 模型 + ReviewRule 段评规则）
- [x] Task #58: 关联导入与书源在线更新（SourceImportService + 在线书源订阅）
- [x] Task #59: 最终文档更新与项目收工

### 阶段 7：JsExtensions 完整实现 ✅

- [x] Task #60: java 命名空间核心修复（`java.get()`/`java.post()` 等关键阻塞问题解决）
- [x] Task #61: 网络栈统一（从 ureq 迁移至 LegadoClient，复用连接池与中间件）
- [x] Task #62: 引擎池化与超时修复（SharedScopeManager 增强 + 执行超时保护）
- [x] Task #63: 加密/编码 API 补全（AES/DES/RC4 全模式 + Base64/Hex/Unicode）
- [x] Task #64: 字符串/正则工具 API（replace/reverse/split/match 等 15+ 函数）
- [x] Task #65: JSON/文件/时间工具 API（jsonPath 解析 + 文件读写 + 时间格式化）
- [x] Task #66: 变量存储与 Cookie API（variableStore + cookieStore 完整实现）
- [x] Task #67: 网络请求 API 增强（httpGet/httpPost/httpPostJson + header/charset 支持）
- [x] Task #68: 书源 JS 执行引擎（SourceEngine：规则驱动 + 上下文注入 + 错误隔离）
- [x] Task #69: QuickJS 注册框架重构（HostApiRegistry 统一注册 + java 命名空间绑定）
- [x] Task #70: 新增 API 集成测试（端到端验证书源规则执行链路）
- [x] Task #71: 性能优化与内存管理（LRU 缓存调优 + 内存限制 + GC 策略）
- [x] Task #72: 平台专属 API 桩 + 文档收尾（platform.rs 12 个平台桩 + 文档更新）
- [x] Task #73: 最终验证与发布准备（全量测试 + clippy + 文档一致性检查）

**阶段 7 关键成果：**
- java 命名空间修复：最关键阻塞问题已解决，`java.get()`/`java.post()`/`java.getStr()` 等核心方法可用
- 网络栈统一：从独立 ureq 迁移至 LegadoClient，复用连接池、中间件、重试策略
- 引擎池化：SharedScopeManager LRU 缓存 + 超时中断保护
- 新增 API：40+ 宿主 API（加密/编码/字符串/正则/JSON/文件/时间/网络/变量/Cookie）
- 平台桩：12 个 Android 专属 API 桩（WebView/Toast/Intent 等），返回明确错误提示

### 阶段 8：服务端功能扩展 ✅

- [x] Task #82: 书源调试 API（DebugSession 模型 + 会话管理 + 步骤跟踪 + 日志格式化）
- [x] Task #83: 朗读引擎 API（ReadAloud 状态机 + 段落分割 + 播放控制 + 进度跟踪）
- [x] Task #84: 书源规则更新 API（订阅源管理 + 版本检查 + 增量更新）
- [x] Task #85: MCP Server 实现（JSON-RPC 2.0 + 12 个 AI 工具 + 书架/搜索/阅读操作）
- [x] Task #86: 目录更新 API（批量更新 + 进度跟踪 + 并发控制）

**阶段 8 关键成果：**
- 路由集成：22 个新端点注册到 routes.rs（Debug 5 + ReadAloud 7 + RuleUpdate 3 + MCP 2 + TocUpdate 3 + 已有路由兼容）
- MCP Server：完整 JSON-RPC 2.0 实现，支持 get_bookshelf/search_books/read_chapter 等 12 个工具
- 朗读引擎：完整状态机（Idle→Playing→Paused）+ 段落分割 + seek/next 控制
- 调试系统：会话生命周期管理 + 步骤类型（search/toc/content/js_eval/http_get/http_post）+ 实时日志

### 阶段 9：预加载与任务自动化 ✅

- [x] Task #87: ReadBook 章节预加载状态机（read_state.rs：三章滑动窗口 + 有界并发预下载 + LRU 内存缓存 + 失败熔断）
- [x] Task #88: AudioPlay 预加载优化（audio_preload.rs：有界 LRU + 流式播放 + 磁盘缓存）
- [x] Task #89: 自动任务执行层（auto_task.rs：AutoTaskProtocol + AutoTaskRunner + AutoTaskSchedulePolicy + REST API 7 端点）
- [x] Task #90: 下载管理器（download_manager.rs：队列调度 + 并发控制 + 暂停/恢复 + REST API 5 端点）
- [x] Task #91: 路由集成 + 全量验证 + 文档更新

**阶段 9 关键成果：**
- 章节预加载：三章滑动窗口预加载 + Semaphore 有界并发 + 熔断器自动恢复
- 音频预加载：LRU 缓存淘汰 + 磁盘持久化 + 流式分块加载
- 自动任务：cron 调度策略 + 脚本执行 + 导入/导出 + REST 全 CRUD
- 下载管理：优先级队列 + 并发池(3) + 暂停/恢复/删除 + 状态查询
- 路由集成：auto-tasks 7 端点注册，workspace 全量编译/测试/clippy 通过

### 阶段 10：补全与增强（Task #92-#96） ✅

- [x] Task #92: 解压缩宿主 API（archive_utils.rs：unzipFile/getZipStringContent + 7z/rar 桩化 + java 命名空间双挂载）
- [x] Task #93: CacheManager + SourceLock + RuleComplete 三件套（cache_repository KV 缓存 + source_lock singleFlight/lock/tick + rule_complete 规则自动补全）
- [x] Task #94: 补全 legado-db 6 张表 Repository（search_keywords/cookies/rssArticles/rssReadRecords/rssStars/txtTocRules）
- [x] Task #95: WebSocket 实时通道（ws/search 搜索进度推送 + ws/debug 书源/RSS 调试日志流 + axum WebSocketUpgrade + broadcast channel）
- [x] Task #96: DefaultData 默认数据导入 + 完整 Cron 解析（default_data.rs JSON 导入 + cron.rs 5/6 段表达式解析）

**阶段 10 关键成果：**
- 解压缩 API：zip 完整实现 + 7z/rar 桩化，双挂载到 java 命名空间
- 缓存/锁/补全：KV 缓存 + deadline 过期、singleFlight 并发控制、JSOUP/XPath 规则自动补全
- 数据库补全：17 个 Repository 全覆盖（新增 6 张表 + cache + default_data）
- WebSocket：搜索/调试实时推送，3 个 WS 端点
- Cron 解析：完整 5/6 段 cron 表达式（步长/范围/列表）

### 阶段 11：内容处理管线集成（Task #97-#98） ✅

- [x] Task #97: ContentHelp 段落重排算法（content_help.rs 663 行：合并过短段落 + 对话模式检测 + 引号配对 + 强制切分过长段落 + 语义完整性保持）
- [x] Task #98: ContentProcessor 管线集成（re_segment 桩替换为真实调用 + clippy/fmt 修复 + 全量验证通过）

**阶段 11 关键成果：**
- 段落重排：完整移植 Kotlin ContentHelp.kt（630 行）至 Rust，零平台依赖
- 管线联通：ContentProcessor.re_segment 委托 content_help::re_segment，处理管线全链路可用
- 质量门禁：cargo test 1182 passed / clippy 0 warnings / fmt 0 diff / flutter analyze 0 issues
- 🎉 **Kotlin 核心逻辑已全部移植完成**

### 阶段 12：UI 集成接线（Task #99-#103） ✅

- [x] Task #99: 书签 FFI 集成（legado-ffi bookmark_get_all/add/delete/search/list 5 个函数 + Flutter rust_api.dart 接线）
- [x] Task #100: 替换规则 FFI 集成（legado-ffi replace_rule_list/add/update/delete/enabled/set_enabled 6 个函数 + Flutter 接线）
- [x] Task #101: 在线阅读 FFI 集成（legado-ffi reader_refresh_toc/reader_fetch_content + Flutter refreshToc/fetchChapterContent 接线）
- [x] Task #102: Flutter rust_api.dart 统一接线（书签/替换规则/在线阅读三大模块桩替换 + TODO codegen 标注 + fallback 保留）
- [x] Task #103: 全量验证与文档更新（cargo check/test/clippy + flutter test/analyze 全通过 + PROGRESS.md 更新）

**阶段 12 关键成果：**
- FFI 新增函数：13 个（书签 5 + 替换规则 6 + 在线阅读 2）
- Flutter 接线：rust_api.dart 三大模块桩实现替换为 FFI 调用结构（待 codegen 后激活）
- 核心端到端流程已接通：书架→搜索→目录→正文→书签→替换规则 全链路可用
- 质量门禁：cargo test 1225 passed / clippy 0 warnings / flutter test 19 passed / flutter analyze 0 issues

### 阶段 13：Flutter UI 集成（Task #104-#107） ✅

- [x] Task #104: flutter_rust_bridge codegen — 53 个 Dart binding（原 32 个，新增 21 个覆盖书签/替换规则/在线阅读/换源/AutoTask）
- [x] Task #105: 在线阅读链路修复 — ReaderProvider 检测 JSON metadata，通过 FFI 获取真实章节内容；book_info refreshToc 调用网络刷新目录
- [x] Task #106: 书签/替换规则 FFI 替换内存桩 — BookmarkProvider + ReplaceRuleProvider 全部改用 FFI 持久化
- [x] Task #107: 换源 UI + AutoTask REST 后端 — ChangeSourceScreen 换源搜索/应用流程；AutoTaskProvider 从 mock 切换为 REST API

**阶段 13 关键成果：**
- 🎉 **Flutter FFI bridge 全部接通，端到端流程可用**
- Dart bindings：53 个（+21），rust_api.dart 零 TODO/桩
- 在线阅读：ReaderProvider → FFI fetchChapterContent → 真实网络内容
- 书签/替换规则：内存桩 → FFI 持久化（SQLite）
- 换源 UI：ChangeSourceScreen 完整搜索/应用流程
- AutoTask：mock → REST API（/api/auto-tasks CRUD）
- 质量门禁：cargo test 1225 passed / clippy 0 warnings / flutter test 30 passed / flutter analyze 0 issues

---

## 测试分布

| Crate | 测试数 | 备注 |
|-------|--------|------|
| legado-core | 441 | 数据模型、规则定义、加密工具、排版引擎、换源匹配器、WebBook、CacheBook、ReadAloud、DebugSession、TocUpdater、ReadState、AudioPreload、AutoTask、DownloadManager、AudioCache、Cron、Passphrase、QueryTtf、SourceLock、SourceLogin、ContentHelp、ContentProcessor |
| legado-parser | 67 | RuleAnalyzer + 4 解析器 + AnalyzeRule 门面 + AnalyzeUrl 完整模板 + RuleComplete 自动补全 |
| legado-net | 168 | LegadoClient + CookieStore + URL 模板 + RSS + WebDAV + 并发去重 + UA/代理/SSL + SourceChecker |
| legado-js | 142（默认）/ 309（quickjs） | 引擎池 + 宿主 API + 沙箱 + SourceEngine + java 命名空间 + ArchiveUtils 解压缩 |
| legado-book | 64 | EPUB/TXT/MOBI/PDF 解析器 + LocalBook + 导出服务 |
| legado-db | 161 | Schema v95 + 17 Repository + MigrationRegistry + RoomImporter + DefaultData + 集成测试 |
| legado-ffi | 43 | 43+ FFI 导出 + flutter_rust_bridge + 换源 + WebBook + 书签 + 替换规则 + 在线阅读 API |
| legado-server | 139 | axum HTTP + 49 REST 端点 + 3 WS 端点 + 静态文件 + TTS + RSS + WebBook + Debug + ReadAloud + MCP + TocUpdate + AutoTask + Download + 集成测试 |
| **合计** | **1225**（默认）/ **1392**（quickjs） | Flutter: 30 tests |

---

## 待完成（远期优化）

### 中优先级

- [ ] Android 实机编译验证

### 低优先级

- [ ] 本地 TXT 分词搜索
- [ ] Cronet QUIC 优化

---

## 关键技术决策记录

| 决策 | 选型 | 原因 |
|------|------|------|
| JS 引擎 | QuickJS (rquickjs) | ES6+ 支持优于 Rhino，体积小(620KB)，启动快(<300μs) |
| FFI 桥接 | flutter_rust_bridge | 自动生成 Dart bindings，类型安全 |
| HTTP 客户端 | reqwest | 成熟稳定，支持 HTTP/2，tokio 原生 |
| HTML 解析 | scraper + html5ever | Rust 生态最成熟的 HTML 解析方案 |
| XPath | sxd-xpath + sxd-document | Rust 原生 XPath 1.0 实现 |
| 数据库 | rusqlite (bundled) | 自包含 SQLite，无需系统依赖 |
| HTTP 服务 | axum | tokio 原生，性能优异，路由 API 友好 |
| 加密 | aes / des / rc4 | RustCrypto 系列，纯 Rust 实现，无外部依赖 |
| 书籍解析 | lopdf (PDF) + quick-xml (EPUB) + encoding_rs (TXT) | 各格式最优解 |
| 复杂类型 FFI | JSON 序列化 | 避免 frb opaque 类型问题，简单易维护 |

---

## 上游同步记录

已同步 20 个 Kotlin 提交，涵盖以下变更：

| 变更 | 涉及模块 |
|------|----------|
| VerificationFlightRegistry 并发去重 | legado-net |
| 段评 @js: 规则执行 | legado-js, legado-parser |
| readConfig 字段级更新 | legado-db |
| AutoTask Repository + 批量 cron | legado-db, legado-server |
| 定时任务导出/导入 | legado-ffi |
