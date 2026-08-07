# Legado Rust+Flutter 重构进度

> 最后更新：2026-08-07（Rust 剩余项全批闭合 Task #140：R1-R10+R12 全部实现（subContent/replaceRegex/server 正文/字典规则引擎/缓存写与批量下载/payAction/导出参数/字体 cmap/JS 段评/bridge.rs DEPRECATED）+ QUIC 代码整体移除（用户决策，纯重构边界）；契约 §2.43 新增 7 方法 + §2.41 QUIC 移除记录；验证 cargo test --workspace 全绿、quickjs 213 全过、flutter analyze 0 error）

---

## 总览

- **已完成**：168 / 168 原子任务（100%）
- **完成度（2026-08-07 R 系列闭合后）**：Rust 轨道剩余项仅剩 **schema v102 重建表（触发型延后，见 docs/REFACTORING_REMAINING_PLAN.md §4.2.1）+ normalizeJsResult 引擎差异观察项**；此前审计口径 96-97% 及其 4 项 P1 实质缺口、Rust P2 缺口（subContent/replaceRegex/server 正文桩/dict 占位）均已闭合；QUIC 扩展能力按用户决策移除（纯重构边界）；Flutter UI 侧留项（缓存管理页、MoreConfig、定时调度器等）见 docs/REMAINING_ITEMS_DEV_REVIEW_20260806.md
- **剩余 P1 实质缺口（4 项）**：✅ 已全部闭合（2026-08-06 批次，见下方小节各销记）；2026-08-07 R 系列闭合后无新增实质缺口
- **测试状态**：cargo test 2283 passed（Rust workspace）+ 547 passed（quickjs feature）| flutter test 1087 passed（2026-08-05 实测） | flutter analyze 0 issues（缺口清单清零批次测试统计待回归更新）
- **QuickJS feature**：547 tests passed | legado-ffi：175 tests passed
- **里程碑**：🎉 上游同步窗口 2 跟进完成（141 提交同步 + 高亮体系一期 + P0/P1/P2 全部跟进项 + E2E 遗留修复闭环）+ 跨轨阻塞四连解除（MOBI 完整解析 / 书源校验 FFI / 规则订阅全链路 / 验证码交互通道）+ 缺口清单清零批次（Task #162~#168）

---

## 内部 API 非加法式变更记录（并行分支 rebase 须知）

> 本轨道绝大多数变更是加法式（新增函数/字段）；以下非加法式变更需并行分支 rebase 时注意。

### 2026-08-06（Task #120 批次）

- **`RssSourceRepository::new` 签名迁移**（本批唯一非加法式内部 API 变更）：
  构造参数由 `Arc<Mutex<Connection>>` 改为借用 `&Connection`，结构体带生命周期
  `RssSourceRepository<'a>`（与 BookGroupRepository 等新式仓储一致，适配 FFI 层
  r2d2 连接池的 per-call `Database` 包装）。工作区内调用方已全部适配；并行分支
  rebase 时若持有旧 `Arc<Mutex<Connection>>` 调用点，需改为
  `conn.lock()` 后传入借用，文件：`rust/legado-db/src/repository/rss_source_repository.rs`。

---

## 已完成（168/168 原子任务）

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
- [x] Task #85: MCP Server 实现（JSON-RPC 2.0 + 5 个 AI 工具：search_books/get_chapters/read_chapter/get_bookshelf/add_to_bookshelf，桩实现，待接入真实业务逻辑）
- [x] Task #86: 目录更新 API（批量更新 + 进度跟踪 + 并发控制）

**阶段 8 关键成果：**
- 路由集成：22 个新端点注册到 routes.rs（Debug 5 + ReadAloud 7 + RuleUpdate 3 + MCP 2 + TocUpdate 3 + 已有路由兼容）
- MCP Server：完整 JSON-RPC 2.0 实现，5 个工具（search_books/get_chapters/read_chapter/get_bookshelf/add_to_bookshelf），当前为桩实现，待接入真实业务逻辑
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
- [x] Task #99: 缺口#6 unrar 处置 + SOCKS5 e2e 实测（rar crate 0.4 纯 Rust 实现 unrarFile/getRarStringContent + sevenz-rust2 实现 get7zStringContent + SOCKS5 凭据代理 e2e 双用例 + startBrowserAwait 降级登记）

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

### 阶段 14：Flutter UI 打磨与阅读器增强（Task #108-#109） ✅

- [x] Task #108: 设置/书源/关联/书籍信息 UI 增强 — 设置页 License 页面 + 项目 URL 启动器；书源登录 SharedPreferences 持久化；关联导入 FilePicker 文件选择 + QR 平台提示；书籍信息 share_plus 分享集成
- [x] Task #109: 阅读器增强 — 目录搜索过滤、章节预加载（前后各 2 章）、退出时保存阅读进度

**阶段 14 关键成果：**
- 设置增强：开源许可页面 + 项目主页一键跳转
- 书源登录：登录状态 SharedPreferences 持久化，重启不丢失
- 关联导入：FilePicker 真实文件选择（替代文本输入）+ 平台适配提示
- 书籍分享：share_plus 集成，支持分享书名/作者/简介
- 阅读器：目录内搜索过滤 + 章节预加载（±2 章）+ 退出进度保存
- 质量门禁：cargo test 1225 passed / clippy 0 warnings / flutter test 30 passed / flutter analyze 0 issues

### 阶段 15：全量审计修复（Task #110-#114） ✅

- [x] Task #110: MCP Server 12 个工具接入真实数据库逻辑（search_books/get_chapters/read_chapter/list_sources/get_bookshelf/add_to_bookshelf/get_reading_progress/update_source/list_books/remove_book/get_book_info/call_tool）
- [x] Task #111: AnalyzeRule @js: 规则执行集成（JsExecutor trait 注入模式 + legado-js QuickJS 引擎对接）
- [x] Task #112: EPUB 封面提取（3 级 fallback：cover meta → OPF item → 首图片）+ MOBI EXTH 元数据 + KF8 检测 + 错误处理增强
- [x] Task #113: Flutter UI 修复（clearCache 接入 RustApi.clearCache()、主题导入真实实现、SharedPreferences TODO 清理）
- [x] Task #114: WebBook StubBookSourceFetcher 替换为真实实现（LegadoClient + AnalyzeUrl + AnalyzeRule 全链路：搜索→详情→目录→正文）

**阶段 15 关键成果：**
- 🎉 **Rust 侧零 TODO/FIXME/桩实现**（全量扫描确认）
  > ⚠️ **口径修正（2026-08-06 审计）**：该历史结论已修订——dict 为小规模静态数据（占位级覆盖）、legado-server 正文为待补项；「零 TODO/桩实现」表述不再作为当前状态声明。
  > ✅ **批次3治理闭合（Task #118，2026-08-06）**：platform.rs 5 个死代码桩已删除（JS 侧实际走 config_api/misc_api，无契约影响）；Dart 侧 getAudioChapterMedia/scanLocalBooks/parseTxt 确认零调用点，已在 rust_api.dart 注释标注死代码（保留契约面）；docs/README.md 同源表述已同步修正。
- MCP Server：12 个工具全部接入真实数据库查询逻辑
- @js: 规则执行：JsExecutor trait 注入模式解决跨 crate 循环依赖
- EPUB 封面：3 级 fallback 策略（cover meta → OPF item → 首图片）
- MOBI 完善：EXTH 元数据解析 + KF8 检测 + 错误处理增强
- WebBook 真实链路：AnalyzeUrl 模板解析 + LegadoClient HTTP + AnalyzeRule 规则解析，搜索→详情→目录→正文全流程
- Flutter：clearCache 接入真实 API、主题导入实现、零“功能开发中”占位
- 质量门禁：cargo test 1258 passed / clippy 0 warnings / flutter test 30 passed / flutter analyze 0 issues

### 阶段 16：P0-P3 审计修复与 FFI 重构（Task #115-#119） ✅

- [x] Task #115: js_eval FFI 使用 QuickJS 引擎（feature 启用时真实执行 JS，非桩实现）
- [x] Task #116: 阅读统计 + 音频章节媒体 REST 端点（reading_stats_record/get_total/get_daily + audio_chapter_media）
- [x] Task #117: readRecord + book_groups Repository 创建（ReadRecordRepository + BookGroupRepository 完整 CRUD）
- [x] Task #118: rss_star/search_keyword FFI 暴露 + Flutter 接线（rssStarList/Add/Delete/IsStarred + searchHistoryList/Add/Delete/Clear）
- [x] Task #119: 49 个 Mutex unwrap() → unwrap_or_else 毒性恢复 + Backup 扩展（bookSources/rssSources/readRecords）+ Flutter rust_api.dart 全量重写适配 codegen + 17 个模块 FFI 接通

**阶段 16 关键成果：**
- 🎉 **Flutter rust_api.dart 全量重写**：从桩函数重构为真实 FFI 调用，17 个模块全部接通
- codegen 重新生成：flutter_rust_bridge_codegen generate 最新绑定
- Mutex 安全：49 处 unwrap() 替换为 unwrap_or_else（毒性恢复，避免 panic 级联）
- Backup 扩展：备份范围新增 bookSources、rssSources、readRecords
- 质量门禁：cargo test 1283 passed / clippy 0 warnings / flutter test 30 passed / flutter analyze 0 issues

### 阶段 17：FFI 扩展与 Flutter 全量接线（Task #120-#123） ✅

- [x] Task #120: 阅读记录 + 书籍分组 FFI（read_record_list/upsert/delete/clear + book_group_list/add/update/delete/set_show 9 个函数）
- [x] Task #121: 阅读统计 + 缓存 + 配置 FFI（stats_today/daily/by_book/heatmap + cache_get_size/clear/get_chapter + config_get/set/get_all 10 个函数）
- [x] Task #122: HTTP TTS + 音频进度 FFI（http_tts_list/add/update/delete/set_enabled + audio_get_progress/save_progress + http_tts 表 + Repository 7 个函数）
- [x] Task #123: Flutter FFI 接线 + codegen + Provider 测试（rust_api.dart 26 处 UnimplementedError 替换为 bridge 调用 + 78 个新 Provider 测试）

**阶段 17 关键成果：**
- 🎉 **FFI 覆盖率大幅提升**：新增 28 个 FFI 函数（总计 73+），UnimplementedError 从 40+ 处降至 14 处
- Flutter 接线：read_record(4) + book_group(4) + stats(4) + cache(2) + config(3) + http_tts(5) + audio(2) = 24 个方法接通
- codegen 重新生成：flutter_rust_bridge_codegen generate 最新绑定（73+ Dart bindings）
- Provider 测试：78 个新测试（bookshelf 15 + search 19 + rss 12 + reader 32）
- 质量门禁：cargo test 1244 passed / clippy 0 warnings / flutter test 108 passed / flutter analyze 0 issues

### 阶段 18：UnimplementedError 清零 + Backup/Server FFI（Task #124-#125） ✅

- [x] Task #124: Backup + Server FFI 新增（backup_create/backup_restore/backup_list + server_start/server_stop/server_status 6 个新 FFI 函数）
- [x] Task #125: Flutter 29 处 UnimplementedError 全部替换为真实实现（bridge/prefs/http 三种策略）+ codegen 重新生成

**阶段 18 关键成果：**
- 🎉 **UnimplementedError 彻底清零**：Flutter rust_api.dart 不再有任何 UnimplementedError
- Backup FFI：backup_create（JSON 导出）/ backup_restore（导入恢复）/ backup_list（列出备份文件）
- Server FFI：server_start / server_stop / server_status（HTTP 服务生命周期控制）
- Flutter 实现策略：bridge 直调 FFI（核心数据）/ SharedPreferences（本地配置）/ HTTP（服务端 API）
- codegen 重新生成：flutter_rust_bridge_codegen generate 最新绑定
- 质量门禁：cargo test 1244 passed / legado-ffi 57 passed / quickjs 309 passed / clippy 0 warnings / flutter test 108 passed / flutter analyze 0 issues

### 阶段 19：Flutter UI 完善 + APK 构建（Task #126-#129） ✅

- [x] Task #126: AndroidManifest 修复 + APK 构建成功（android:label 冲突修复 + flutter build apk --debug 通过）
- [x] Task #127: P0-P1 屏幕补全（ImportBookScreen 本地导入 + BookGroupScreen 分组管理 + SearchContentScreen 书内搜索 + ReaderConfigScreen 阅读设置）
- [x] Task #128: P1-P2 屏幕补全（AboutScreen 关于 + DiscoverScreen 发现 + RssFavoritesScreen RSS 收藏 + ChangeCoverScreen 换封面 + TxtTocRulesScreen TXT 目录规则 + Home 新增发现 Tab）
- [x] Task #129: 通用组件库（10 个可复用 Widget：SearchBarWidget/SourceCard/BookGridItem/TagChip/SwipeAction/LoadingOverlay/CustomProgress/AppBottomSheet/BadgeWidget/ChapterTile + 43 个组件测试）

**阶段 19 关键成果：**
- 🎉 **APK 构建 + 模拟器安装成功**：flutter build apk --debug + adb install 验证通过
- 屏幕总数：6 → 15（+9 个新屏幕）
- 组件库：10 个可复用 Widget + 43 个组件测试
- Flutter 测试：108 → 151（+43）
- Home 导航：新增「发现」Tab（书架/发现/搜索/设置 四 Tab）
- 质量门禁：cargo test 1244 passed / clippy 0 warnings / flutter test 151 passed / flutter analyze 0 issues

### 阶段 20：审计修复与功能补全（Task #130-#133） ✅

- [x] Task #130: P0 Book 实体补全 + users 表（Book +4 字段 infoHtml/tocHtml/downloadUrls/coverOrigin + users 表 + UserRepository + FFI 6 个用户管理函数）
- [x] Task #131: JS 宿主 API 补全（+15 函数，提交 249f95451）：
  - config_api：getReadBookConfig/getThemeConfig/getThemeMode/getWebViewUA/androidId
  - concurrency_api：singleFlight/lock/tick
  - misc_api：connect/getSource/getTag/ajaxTestAll/toUrl/toast/logType
  - （2026-08-05 审计纠正：原名单 configGet/threadPool/randomString 等为登记失实，Kotlin 无此 API；timeFormat 大小写失配已于 #95 批次补别名修复）
- [x] Task #132: 书源/RSS 调试 WebSocket 端点（ws/debug/book-source + ws/debug/rss-source 实时日志推送）
- [x] Task #133: Flutter 5 屏幕实现（DictRuleScreen 字典规则 + FontManageScreen 字体管理 + QrCodeScanScreen 二维码扫描 + WelcomeScreen 欢迎页 + BrowserScreen 内置浏览器）+ dict_rules/keyboard_assists 表 + Repository

**阶段 20 关键成果：**
- 🎉 **P0 审计问题全部修复**：Book 实体字段与 Kotlin 原版对齐
- 用户管理：users 表 + UserRepository + FFI 6 函数（get_all/save/delete/login/logout/check_login）
- JS API：新增 15 个宿主 API（配置/并发/书籍信息/工具函数）
- WebSocket 调试：书源/RSS 调试日志实时推送
- Flutter 屏幕：15 → 20（+5 个新屏幕）
- 数据库：新增 dict_rules + keyboard_assists 表 + Repository
- 质量门禁：cargo test 1285 passed / clippy 0 warnings / flutter test 151 passed / flutter analyze 0 issues

### 阶段 21：数据库全覆盖 + FFI 真实链路（Task #134-#136） ✅

- [x] Task #134: rssSources + searchBooks Repository（DB 覆盖 25/25 = 100%）
- [x] Task #135: 7z 解压缩评估（技术调研 + 可行性分析）
- [x] Task #136: FfiStubFetcher → RealBookSourceFetcher 替换（LegadoClient + AnalyzeUrl + AnalyzeRule 真实网络链路）+ platform.rs WebView API 文档完善

**阶段 21 关键成果：**
- 🎉 **数据库 Repository 100% 覆盖**：25/25 表全部有 Repository
- FFI 真实链路：FfiStubFetcher 替换为 RealBookSourceFetcher，搜索→详情→目录→正文全流程真实网络请求
- platform.rs 文档：6 个 WebView API 添加明确的文档注释（仅在 Flutter 侧实现 + 无头模式不支持）
- 质量门禁：cargo test 1297 passed / clippy 0 warnings / flutter test 151 passed / flutter analyze 0 issues

### 阶段 22：TXT 分词搜索 + 质量修复（Task #137） ✅

- [x] Task #137: 本地 TXT 分词搜索（TxtSearch 引擎 + FFI 4 函数 + 18 个测试 + Clippy/Format 修复）

**阶段 22 关键成果：**
- TXT 搜索引擎：`txt_search.rs`（纯文本搜索 + 正则搜索 + 章节感知 + 上下文摘要 + 结果数限制）
- 支持中文文本搜索（字符级匹配，无需分词）
- FFI 4 函数：`ffi_txt_search` / `ffi_txt_search_regex` / `ffi_txt_search_in_chapter` / `ffi_txt_search_count`
- 质量修复：Clippy `redundant_closure` 修复（bridge.rs ffi_user_get_all）+ cargo fmt 格式化修复
- 文档同步：DEVELOPMENT.md 测试数/屏幕数/FFI函数数更新 + CHANGELOG.md Unreleased 全面更新
- 质量门禁：cargo test 1315 passed / clippy 0 warnings / flutter test 151 passed / flutter analyze 0 issues

### 阶段 23：Flutter UI 深度实现 + 工程化（Task #138-#148） ✅

- [x] Task #138: WebDAV sync FFI API（6 函数：list_dir/upload/download/delete/mkdir/full_sync）
- [x] Task #139: Download Manager FFI API（8 函数：add_task/get_stats/list_by_book/pause_all/resume_all/remove_task/update_progress/complete_task）
- [x] Task #140: Review 段评 FFI API（4 函数：get_by_chapter/add/delete/like）+ Flutter 段评弹窗
- [x] Task #141: 仿真翻页动画（移植 Kotlin SimulationPageDelegate.kt 贝塞尔曲线算法 613 行）
- [x] Task #142: RSS WebView 渲染 + JS 执行 + 纯文本 fallback
- [x] Task #143: 书源编辑器规则验证（webbookSearch/Info/Chapters/Content）+ 调试日志增强
- [x] Task #144: 听书播放器定时停止（Timer.periodic + 倒计时 UI + 预设时间选择器）
- [x] Task #145: 视频播放模块（video_player + 播放控制 + 全屏 + 手势）
- [x] Task #146: 漫画阅读模块（纵向滚动 + 双指缩放 + 图片预加载 + 进度保存）
- [x] Task #147: CI 自动发布 workflow（flutter-release.yml，push tag 触发）
- [x] Task #148: Flutter 阅读器测试覆盖（16 个新测试：翻页 8 + 段评 8）

**阶段 23 关键成果：**
- 🎉 **Flutter 屏幕数达到 40 个**：新增 video_screen + reader_comic_screen
- FFI 新增函数：18 个（WebDAV 6 + Download 8 + Review 4），总计 103+
- 仿真翻页：完整移植 Kotlin SimulationPageDelegate.kt 贝塞尔曲线算法（613 行）
- 段评弹窗：FFI 4 函数 + Flutter ReviewDialog 完整交互
- 视频播放：video_player 集成 + 播放控制 + 全屏 + 手势
- 漫画阅读：纵向滚动 + 双指缩放 + 图片预加载 + 进度保存
- RSS WebView：JS 执行 + 纯文本 fallback
- 书源调试：规则验证（webbookSearch/Info/Chapters/Content）+ 调试日志增强
- 听书定时：Timer.periodic + 倒计时 UI + 预设时间选择器
- CI 发布：flutter-release.yml，push tag 触发自动构建 APK
- 测试覆盖：16 个新 Flutter widget 测试（翻页 8 + 段评 8）
- 质量门禁：cargo test 1315 passed / clippy 0 warnings / flutter test 167 passed / flutter analyze 0 issues

### 阶段 24：上游同步窗口 2 跟进（2026-08-04 ~ 08-05）✅

- [x] Task #149: 上游同步 141 提交（e1c102803→308ac7b1e #543，提交 b10285b8c）
- [x] Task #150: 高亮体系一期——DB v99 迁移对齐上游（消除 v96 语义撞车）+ highlights/highlightRules 表 + Repository + FFI 11 方法（bcb583f17）
- [x] Task #151: PDF 导出（genpdf + 中文字体三级策略）（c81977f01）
- [x] Task #152: 网络层补强——gzip/brotli/deflate + SOCKS5 凭据认证 + Cookie 持久化（e954c3178）
- [x] Task #153: Repository 补齐上游新方法（CAS 乐观锁/音频语速/批量启停/阅读记录作者合并）（94c3e1e55）
- [x] Task #154: 听书修复同步——TTS 队列防串扰 + 音频跳过策略（e5dcf6b9e）
- [x] Task #155: 段评回复按需加载（review_rule_parser + reviewGetReplies FFI）（2a6d4c865）
- [x] Task #156: P2 八项——cURL 转换/MCP 5 工具/目录批量更新/AutoTask 协议/搜索阅读记录/JsSourceConfig/应用日志/登录 V2（98e6e264~24281fdd）
- [x] Task #157: E2E 会话遗留文件处置——宽松反序列化/loginCheckJs 降级/分组 camelCase/JSoup 对齐/交叉编译修复/搜索空数组（b3aa3fa~32fb823）
- [x] Task #158: MOBI 解析补全——HUFF/CDIC + INDX/TAGX + KF8(AZW3) + NCX/封面（mobi.rs 677→2563 行，对照 Kotlin lib/mobi/ 34 文件移植，d994a4fdb）
- [x] Task #159: 书源校验 FFI——单本校验 + 批量 Stream + 取消（sourceCheck/sourceCheckStream/sourceCheckCancel，86c299923）
- [x] Task #160: 规则订阅全链路——schema v100 补 7 字段 + FFI 7 方法（94b257390）
- [x] Task #161: 验证码交互通道——JS 钩子 getVerificationCode/startBrowserAwait + FFI 事件流 + 提交回传（6f5614e24）
- [x] Task #162: 图片书 PDF 导出（图片提取+注入式获取管线+A4 宽高比写入，对齐 #483）
- [x] Task #163: DB schema v101 偏离表补列（rssArticles/rssStars/readRecord/txtTocRules 对齐 Room 基线）
- [x] Task #164: JS 宿主 API 补齐（unzip 断线修复 + 6 个零星 API）
- [x] Task #165: txt_search frb 主链路接入 + FFI 测试串行锁消除竞态（3 轮并行验证零 flaky）
- [x] Task #166: RSA/SM2 非对称加密 JS API（加解密+签名验签+长文分段）
- [x] Task #167: 繁简转换 FFI 透传（不迁移项重评后改为迁移；chineseConverterType 对齐 Kotlin）
- [x] Task #168: unrar 处置 + get7zStringContent + SOCKS5 凭据 e2e 实测（自建 SOCKS5 测试服务器验证认证握手）；初评结论“无可用纯 Rust crate，降级”，后经复评发现 rar crate 0.4（纯 Rust，RAR4/RAR5 全压缩级别+加密档案）可用，已改为真实实现（见 Task #99 与已知降级项表备注）
- [x] 全量回归：Rust workspace 2283 + quickjs 547 + Flutter 1087 测试零失败（2026-08-05 实测，为缺口清单清零批次前数字；本批新增测试统计待回归更新）

---

## 测试分布

| Crate | 测试数 | 备注 |
|-------|--------|------|
| legado-core | 743 | 数据模型、规则定义、加密工具、排版引擎、换源匹配器、WebBook、CacheBook、ReadAloud、DebugSession、TocUpdater、ReadState、AudioPreload、AutoTask、DownloadManager、AudioCache、Cron、Passphrase、QueryTtf、SourceLock、SourceLogin、ContentHelp、ContentProcessor、PDF 导出、规则订阅服务 |
| legado-parser | 163 | RuleAnalyzer + 4 解析器 + AnalyzeRule 门面 + AnalyzeUrl 完整模板 + RuleComplete 自动补全 + review_rule_parser 段评回复 |
| legado-net | 224 | LegadoClient + CookieStore + URL 模板 + RSS + WebDAV + 并发去重 + UA/代理/SSL + SourceChecker + gzip/brotli/deflate + SOCKS5 凭据认证 + SOCKS5 凭据代理 e2e + Cookie 持久化（QUIC 测试已随 2026-08-07 QUIC 移除，实际数以最新 cargo test 为准） |
| legado-js | 402（默认）/ 547（quickjs） | 引擎池 + 宿主 API + 沙箱 + SourceEngine + java 命名空间 + ArchiveUtils 解压缩 + JsSourceConfig + 登录 V2 + 验证码 JS 钩子（getVerificationCode/startBrowserAwait） |
| legado-book | 140 | EPUB/TXT/MOBI/PDF 解析器 + LocalBook + 导出服务 + 封面提取 + EXTH 元数据 + TxtSearch 搜索引擎 + MOBI HUFF/CDIC/INDX/TAGX/KF8(AZW3)/NCX 完整解析 |
| legado-db | 260 | Schema v100 + highlights/highlightRules 表 + ruleSubscriptions 表 + Repository + MigrationRegistry + RoomImporter + DefaultData（CAS 乐观锁/批量启停/阅读记录作者合并） |
| legado-ffi | 175 | 120+ FFI 导出 + flutter_rust_bridge + 高亮 11 方法 + reviewGetReplies + 搜索阅读记录 + 书源校验（sourceCheck/sourceCheckStream/sourceCheckCancel）+ 规则订阅 7 方法 + 验证码事件流/提交回传 + 既有全部模块 API |
| legado-server | 178 | axum HTTP + 60+ REST 端点 + 5 WS 端点 + 静态文件 + TTS + RSS + WebBook + Debug + ReadAloud + MCP(17工具) + TocUpdate + AutoTask + Download + ReadingStats + Audio + cURL 转换 + 应用日志 + 集成测试 |
| **合计** | **Rust workspace 2283**（默认）+ **547**（quickjs feature） | Flutter: 1087 tests（2026-08-05 实测） |

---

## 剩余 P1 实质缺口（2026-08-06 审计）

> 来源：Rust 功能缺口源码级复查（完成度 96-97%）。台账登记见 docs/REFACTORING_REMAINING_PLAN.md §5.6，UI 侧影响见 docs/UI_FIX_PLAN.md「UI 缺口修复批次（2026-08-06）」。

| # | 缺口 | 现状 | 工时 | 备注 |
|---|------|------|------|------|
| ① | 正文 nextContentUrl 分页抓取 | `legado-ffi/src/api/web_book.rs`（或对应 get_content 链路）只抓一页，分页书源正文被截断——**唯一用户可见的核心解析缺口** | 2-3d | 对齐 Kotlin nextContentUrl 循环/并发抓取 |
| ② | audioSpeak TTS 真实管线 | `rust_api.dart` L1431 仅 http.get 探活，且被 audio_notifier 实际调用 | 3-5d | 跨轨；阻塞 Flutter P0 朗读功能 |
| ③ | WebView 桥接载荷 Flutter 侧拦截执行 | Rust 已交付 7 个 action JSON，Flutter lib 无拦截代码 | 2-3d | 跨轨 |
| ④ | rssUpdateSource 原子更新 FFI | 现用「删旧+加新」workaround | 0.5d | 承接 REMAINING_PLAN §4.3 P1-2 |

> ✅ **销记（2026-08-07，Task #140）**：上表 4 项 P1 已于 2026-08-06 批次闭合；本批 R 系列（R1-R10+R12）进一步闭合 P2 与治理项：subContent/replaceRegex、legado-server 正文桩、dict 占位（改为原版字典规则引擎 + 5 源 seed）、缓存写/批量下载/购买/导出参数 FFI（契约 §2.43）、字体 cmap 反爬真实替换、JS 书源段评回复、bridge.rs DEPRECATED 标注（步骤2）；QUIC 扩展能力整体移除（用户决策）。销记台账：docs/REFACTORING_REMAINING_PLAN.md §5.10。

**P2 与治理项（2026-08-07 更新）**：subContent/contentRule.replaceRegex ✅、legado-server 正文桩 ✅、dict 静态占位 ✅（重写为原版字典规则引擎）；12 个 FFI 补登 ✅（其中 QUIC 8 项随后移除）；待 UI 封装剩 backupList/bookGroupSetShow/httpTtsSetEnabled 3 项（QUIC 六件套已移除）；schema v102 重建表保持触发型延后（评估见 REMAINING_PLAN §4.2.1）；治理项已随批次3闭合（Task #118）；bridge.rs C ABI 废弃三步走已完成步骤2（R12 DEPRECATED 标注 + 冻结新增）；normalizeJsResult 引擎差异保留为观察项。

---

## 待完成（2026-07-31 完成度核查后修订）

### P0（阻塞核心体验）

- [x] Flutter 排版引擎渲染侧整合 — 预估 2-3 周
  > ✅ 核销（2026-07-31，Task #34）：paragraph_layout_engine 接入 reader_screen，屏级分页/中文避头尾/两端对齐落地，847+ 测试通过
- [x] 导出功能 UI（格式选择/字符集/进度显示）— 预估 1 周
  > ✅ 核销（2026-07-31）：export_dialog.dart 已具备格式选择/字符集/进度显示/路径选择/双入口（book_info + bookshelf），功能已实现
- [x] 离线缓存管理界面 — 预估 1 周
  > ✅ 核销（2026-07-30）：cache_settings_screen.dart（331 行）已存在，功能已实现

### P1

- [x] 下载管理深度（预下载智能算法 + 断点续传 + 失败重试）
  > ✅ 核销（2026-07-31）：download_manager.rs 870行，PreloadStrategy 预下载、get_range_header 断点续传、fail_task_with_retry 重试均已实现，代码验证通过
- [x] WebDAV 增量同步 + 冲突合并
  > ✅ 核销（2026-07-31）：webdav.rs 979行，incremental_sync 增量同步、conditional_put 乐观锁、ConflictResolution 四种策略均已实现，代码验证通过
- [x] 目录搜索 + 段评完整流程
  > ✅ 核销（2026-07-31）：search_content_screen.dart（351行）+ paragraph_comment_dialog.dart（466行）均已接线 FFI，功能完整
- [x] 听书后台媒体按钮 + 焦点管理（Platform Channel）— 预估 1 周
  > ✅ 核销（2026-07-31，Task #17）：MediaSession 通道注册 + AudioProvider 接线，后台媒体按钮与焦点管理可用，22/22 测试通过
- [x] 发现页 exploreUrl 分类展示 — 预估 1 周
  > ✅ 核销（2026-07-31，Task #30）：新增 explore_show_screen + Rust explore_api，分类展开/翻页加载/搜索防抖均实现，Rust 6+4 测试通过

### P2 / 远期优化

- [x] 漫画分页模式 + 高级手势
  > ✅ 核销（2026-07-31）：comic_reader_screen.dart 已实现单/双页分页模式 + 双指缩放 + 边缘翻页手势，代码验证通过
- [x] 压缩包导入 + 自动编码检测 — 预估 1 周
  > ✅ 核销（2026-07-31，Task #31）：新增 archive_import_dialog，支持 zip/rar/7z 解压导入 + 自动编码检测 + 手动编码选择 UI
- [x] audio/auto_task 函数 FFI 暴露 — 预估 2-3 天
  > ✅ 核销（2026-07-31，Task #19 注册 + Task #32 Flutter 接入）：legado-ffi 注册 audio/auto_task 共 9+2 个 FFI 方法，Flutter 侧完成接入
- [x] QUIC 接入主网络链路 — 预估 3-5 天
  > ✅ 核销（2026-07-31，Task #43）：client.rs 集成可选 QUIC + fallback HTTP/2，配置开关默认关闭，net 188 + ffi 79 测试通过
- [x] Flutter 测试覆盖率 65-70% → 75% — 预估 1 周
  > ✅ 核销（2026-07-31，Task #33）：新增 +148 测试，Providers 层覆盖率达 72.4%，总计 855 测试全部通过
- [x] Rust bookmark 测试隔离修复
  > ✅ 核销（2026-07-31）：cargo test 实测 6/6 通过，测试隔离问题已修复
- [x] webdav.rs 编译错误修复
  > ✅ 核销（2026-07-31）：cargo check -p legado-net 实测通过，无编译错误

### 已完成（历史遗留项）

- [x] Android 模拟器编译验证（2026-07-29 完成：APK build + adb install 成功）
- [x] 本地 TXT 分词搜索（2026-07-29 完成：TxtSearch 引擎 + FFI 4 函数 + 18 个测试）
- [x] 端到端流程验证（书源导入→搜索→阅读→书签→替换规则全链路可用）
- [x] 阅读器深度实现（仿真翻页动画 + 段评弹窗 + 漫画模式，2026-07-29 完成）

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

### 不迁移项登记（含用户已确认项）

> 以下为技术分析建议。其中 3 项已经用户确认为不迁移（2026-08-04；原第 4 项“繁”按钮经重评改为迁移并已完成，见 Task #167）；降级登记项为缺口清单清零批次评估结论（2026-08-05）；后续新增项确认前仅供参考。

| 不迁移项 | 原因 | 状态 |
|----------|------|------|
| Cronet 网络库 | Flutter 端使用 Rust reqwest 替代，无需引入 Cronet（原「+ QUIC 替代」表述随 2026-08-07 QUIC 移除修正） | ✅ 用户已确认不迁移（2026-08-04） |
| 旧版备份恢复逻辑 | 已有新版 BackupService 替代，旧版不再迁移 | ✅ 用户已确认不迁移（2026-08-04） |
| 应用自更新 | `help/update/` 4 文件 + UpdateDialog（上游 #520/#526/#528）；Android 平台特性（APK 下载+系统安装器），Flutter 跨平台目标以 Windows 为主，无真实需求；Android 端更新可走应用商店。备注：可选中间态“检查新版本提示”已建议单独登记 P2 待决策 | ✅ 用户已确认不迁移（2026-08-04） |

> 阅读界面“繁”按钮：已从“不迁移”移除，改为**已迁移**（Task #167，重评结论：引擎已存在只差透传，功能对齐硬约束相关）。startBrowserAwait 降级处置见下方「已知降级项登记」；unrar 经复评后已真实实现，不再属于降级项。

### 已知降级项登记

> 功能存在但语义弱于 Kotlin 原版的项，正式登记为已知限制。

| 降级项 | Kotlin 原版语义 | Rust 侧现状 | 登记时间 |
|--------|-----------------|-------------|----------|
| startBrowserAwait 浏览器模式 | `useBrowser=true`：内嵌浏览器打开验证页，支持 JS 交互与 refetchAfterSuccess 自动重取 | 桌面端无内置浏览器，一律降级为图片验证码通道（把 url 作为验证资源地址挂起等待用户输入，`legado-js platform.rs start_browser_await`）；已有测试 `test_start_browser_await_degrades_to_image_channel` 覆盖 | 2026-08-05（Task #99） |

> unrar（RAR 解压）：初评（Task #168）登记为降级，后复评发现 `rar` crate 0.4（纯 Rust，RAR4/RAR5 全压缩级别+加密档案，无 C 依赖）可用，已改为真实实现（`archive_utils::unrar_file` / `rar_entry_bytes` + RAR5 fixture 往返测试），从降级项中移除。

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
