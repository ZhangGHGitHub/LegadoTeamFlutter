# Legado Rust+Flutter 重构进度

> 最后更新：2026-07-26

---

## 总览

- **已完成**：73 / 73 原子任务（100%）
- **测试状态**：cargo test 534 passed（默认）/ 613 passed（含 QuickJS）| flutter test 15 passed | flutter analyze 0 issues
- **QuickJS feature**：111 tests passed

---

## 已完成（73/73 原子任务）

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

---

## 测试分布

| Crate | 测试数 | 备注 |
|-------|--------|------|
| legado-core | 126 | 错误类型、数据模型、规则定义、加密工具、排版引擎、换源匹配器、WebBook、CacheBook |
| legado-parser | 53 | RuleAnalyzer + 4 解析器 + AnalyzeRule 门面 + AnalyzeUrl 完整模板 |
| legado-net | 140 | LegadoClient + CookieStore + URL 模板 + RSS + WebDAV + 并发去重 + UA/代理/SSL + SourceChecker |
| legado-js | 34（默认）/ 113（quickjs） | 无 quickjs: 34 | 含 quickjs: 113 | 含 platform 桩 2 tests |
| legado-book | 36 | EPUB/TXT/MOBI/PDF 解析器 + LocalBook |
| legado-db | 74 | Schema v95 + 7 Repository + MigrationRegistry + RoomImporter + 集成测试 |
| legado-ffi | 14 | 30+ FFI 导出 + flutter_rust_bridge + 换源 + WebBook API |
| legado-server | 57 | axum HTTP + 20+ REST + 静态文件 + TTS + RSS + Web SPA + WebBook + SourceCheck + 集成测试 |
| **合计** | **534**（默认）/ **613**（quickjs） | Flutter: 15 tests |

---

## 待完成（远期优化）

### 中优先级

- [ ] Android 实机编译验证

### 低优先级

- [ ] MCP Server 实现（AI 集成）
- [ ] 听书播放器完整实现
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
