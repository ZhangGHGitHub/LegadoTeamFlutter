# Legado Kotlin/Android → Rust + Flutter 全面迁移方案

## 概要

将 Legado 从 Android 原生 Kotlin 应用迁移为 **Rust 核心引擎 + Flutter UI** 的跨平台架构。Rust 承接所有平台无关的业务逻辑（规则解析、JS 沙箱、网络、数据库、书籍格式解析），Flutter 承接全部 UI 层和本地 Web 服务。采用渐进式迁移策略，预计总周期 12-18 个月，每阶段可独立交付。

## 当前架构关键数据

| 维度 | 现状 |
|------|------|
| 主模块 | `app/` 含 88 utils、48 help、28 model、19 UI 子包、22 DAO、32 实体、13 Service |
| 数据库 | Room v2.8.4，95 个 schema 版本，22 DAO，`.allowMainThreadQueries()` |
| 网络 | OkHttp 5.4 + Cronet 151.0.7922.29（Interceptor 模式，有降级路径） |
| JS 引擎 | htmlunit-core-js 定制 fork（`5.3.0-legado.3`），JsExtensions.kt 1318 行暴露 100+ API |
| 规则引擎 | AnalyzeRule 1048 行统一门面，支持 JSoup/XPath/JsonPath/Regex 四种策略 |
| 书籍格式 | EPUB（epublib）/ MOBI（自研）/ TXT（8MB 缓冲 + ICU4J）/ PDF（Android PdfRenderer） |
| 本地服务 | nanohttpd HTTP + Ktor CIO MCP Server + WebSocket |
| TTS | android.speech.tts + HTTP TTS + Media3 ExoPlayer |

## 推荐 Rust 技术栈

| 领域 | 推荐方案 | 备选 |
|------|---------|------|
| FFI 桥接 | `flutter_rust_bridge` | 手动 `dart:ffi` |
| 异步 Runtime | `tokio` | - |
| HTTP 客户端 | `reqwest` | `hyper` + `rustls` |
| HTML 解析 | `scraper` + `html5ever` | `kuchikiki` |
| XPath | `sxd-xpath` + `sxd-document` | libxml2 FFI |
| JsonPath | `jsonpath-rust` | `serde_json` 手动实现 |
| JS 引擎 | **QuickJS**（`quickjs-rs`）| `boa_engine`（ES6+ 兼容性不足）|
| 书籍解析 | `zip` + `quick-xml`（EPUB）| 自研 |
| 编码检测 | `encoding_rs` | chardet FFI |
| 数据库 | `rusqlite` + `refinery`（迁移） | `sqlx` |
| 本地 Web 服务 | `axum` + `tokio` | `actix-web` |
| 序列化 | `serde` + `serde_json` | - |

---

## 阶段 0：基础设施搭建（预估 3-4 周）

### 0.1 建立 Rust workspace 骨架
- 在项目根目录创建 `rust/` 目录，建立 Cargo workspace
- 定义 crate 结构：`legado-core`、`legado-parser`、`legado-net`、`legado-js`、`legado-book`、`legado-db`、`legado-ffi`
- 配置 Android NDK 交叉编译（aarch64-linux-android, armv7-linux-androideabi）
- 参考现有构建：`app/build.gradle`、`settings.gradle`

### 0.2 建立 Flutter 项目骨架
- 创建 `flutter/` 目录，初始化 Flutter 项目
- 配置 `flutter_rust_bridge` 自动生成 Dart/Rust 绑定
- 建立 Platform Channel 桥接架构
- 参考现有：`app/src/main/java/io/legado/app/base/`（11 个基类文件）

### 0.3 统一数据模型定义
- 从 `app/src/main/java/io/legado/app/data/entities/` 提取 32 个实体为语言无关定义
- 重点实体：`Book.kt`(14.6KB)、`BookSource.kt`(10.9KB)、`BookChapter.kt`(7.3KB)、`RssSource.kt`(7.5KB)
- 使用 `serde` derive + `rusqlite::FromRow` 映射

### 0.4 FFI 接口规范设计
- 定义 C ABI 兼容的 FFI 接口层，`repr(C)` 结构体
- 异步操作：Rust `tokio` runtime + Dart `Future`/`Stream` 桥接
- 统一错误传递：`LegadoError` 枚举 + 错误消息字符串

---

## 阶段 1：Rust 核心引擎（预估 16-20 周，最高优先级）

### 1.1 规则解析引擎 `legado-parser`（优先级最高，6-8 周）
- 用 Rust 重写 `RuleAnalyzer.kt`（378 行）词法分析器，利用零拷贝切片
- 用 `scraper`/`html5ever` 替换 `AnalyzeByJSoup.kt`（525 行）
- 用 `sxd-xpath` 替换 `AnalyzeByXPath.kt`（156 行）
- 用 `jsonpath-rust` 替换 `AnalyzeByJSonPath.kt`
- 统一 `AnalyzeRule` 门面（1048 行），根据内容类型自动选择解析策略
- **关键文件**：
  - `app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt`
  - `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt`
  - `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSoup.kt`
  - `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByXPath.kt`
  - `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt`

### 1.2 JS 沙箱引擎 `legado-js`（风险最高，6-8 周）
- **推荐 QuickJS**（C 实现，ES6+ 兼容性经过广泛验证，体积小）
- 用 Rust 实现 `JsExtensions.kt`（1318 行）暴露的全部宿主 API：网络请求、Cookie、缓存、编解码、MD5/SHA、URL 操作、JSON、正则、文件操作
- 复刻 `SharedJsScope.kt`（318 行）的 LRU 作用域管理和 CryptoJS 集成
- 复刻 `JsSourceEngine.kt`（189 行）的纯 JS 源执行流程
- 必须通过 `JsEngineCapabilitiesTest.kt`（17.2KB）和 `SourceCompatibilityTest.kt`（12.7KB）全部用例
- **关键文件**：
  - `modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt`（325 行）
  - `app/src/main/java/io/legado/app/help/JsExtensions.kt`（1318 行）
  - `app/src/main/java/io/legado/app/model/SharedJsScope.kt`（318 行）
  - `app/src/main/java/io/legado/app/model/jsSource/JsSourceEngine.kt`（189 行）
  - `app/src/test/java/io/legado/app/JsEngineCapabilitiesTest.kt`

### 1.3 网络层 `legado-net`（3-4 周）
- 基于 `reqwest` 构建 HTTP 客户端，支持自定义 UA、代理、SSL
- 用 `quinn`（Rust QUIC）替代 Cronet 的 QUIC/HTTP3 能力
- OkHttp Interceptor 架构映射为 Rust middleware/tower 层
- 实现 Cookie 存储和管理（内存 HashMap + SQLite 持久化）
- 复刻 `AnalyzeUrl.kt`（1032 行）的 URL 模板解析
- **关键文件**：
  - `app/src/main/java/io/legado/app/help/http/HttpHelper.kt`
  - `app/src/main/java/io/legado/app/help/http/CookieManager.kt`
  - `app/src/main/java/io/legado/app/help/http/CookieStore.kt`
  - `app/src/main/java/io/legado/app/lib/cronet/CronetInterceptor.kt`
  - `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt`

### 1.4 书籍格式解析器 `legado-book`（3-4 周，可与 1.2/1.3 并行）
- EPUB：`zip` crate + `quick-xml` 解析 OPF/NCX
- MOBI：移植或自研 KF6/KF8 解析
- TXT：零拷贝 mmap + `encoding_rs` 编码检测 + 正则目录提取
- PDF：`pdf` crate 或 MuPDF FFI
- **关键文件**：
  - `app/src/main/java/io/legado/app/model/localBook/EpubFile.kt`（482 行）
  - `app/src/main/java/io/legado/app/model/localBook/MobiFile.kt`（345 行）
  - `app/src/main/java/io/legado/app/model/localBook/TextFile.kt`（624 行）
  - `modules/book/src/main/java/me/ag2s/epublib/`

### 1.5 数据库层 `legado-db`（4-5 周，可在 1.1 完成后开始）
- 使用 `rusqlite` 直接操作 SQLite，保持与现有 `legado.db` 的 schema 完全兼容
- 实现 95 版本增量迁移框架
- 22 个 DAO 接口映射为 Rust trait + impl
- **关键文件**：
  - `app/src/main/java/io/legado/app/data/AppDatabase.kt`（276 行）
  - `app/src/main/java/io/legado/app/data/DatabaseMigrations.kt`（19.3KB）
  - `app/src/main/java/io/legado/app/data/dao/`（22 个文件）
  - `app/schemas/io.legado.app.data.AppDatabase/`（95 个 JSON）

---

## 阶段 2：Flutter UI 层（预估 12-16 周）

### 2.1 阅读器核心渲染（最高精度要求）
- Flutter `CustomPainter` 实现分页排版引擎
- 复刻 `ReadBook.kt`（1156 行/41KB）的三章预加载策略
- 精确中文排版：字体度量、行间距、分页断点
- 翻页动画（对应 `PageAnim`）
- **关键文件**：
  - `app/src/main/java/io/legado/app/model/ReadBook.kt`（41KB）
  - `app/src/main/java/io/legado/app/ui/book/read/`
  - `app/src/main/java/io/legado/app/model/ReadBook*.kt`（关联文件）

### 2.2 书架与管理 UI
- 书架列表、搜索界面、书源管理/编辑、RSS 订阅管理
- 参考 `ui/main/`（8 项）、`ui/book/`（16 项）、`ui/rss/`
- 全局状态管理（Riverpod/BLoC）

### 2.3 TTS 朗读集成
- Android: `flutter_tts` 封装系统 TTS
- HTTP TTS: Rust 网络层获取音频流 + `just_audio` 播放
- 通过 Platform Channel 直接调用 Android TTS API
- **关键文件**：
  - `app/src/main/java/io/legado/app/help/TTS.kt`
  - `app/src/main/java/io/legado/app/service/BaseReadAloudService.kt`（957 行）
  - `app/src/main/java/io/legado/app/service/HttpReadAloudService.kt`（754 行）

### 2.4 本地 Web 服务
- 用 Rust `axum` 替代 nanohttpd（HTTP）和 Ktor CIO（MCP）
- 提供 REST API + WebSocket
- 现有 Vue Web 前端（`modules/web/`）保持独立，通过 API 与 Rust 后端交互
- **关键文件**：
  - `app/src/main/java/io/legado/app/web/HttpServer.kt`（245 行）
  - `app/src/main/java/io/legado/app/web/mcp/`（6 个文件）
  - `app/src/main/java/io/legado/app/service/McpService.kt`（188 行）

---

## 阶段 3：平台集成与收尾（预估 4-6 周）

### 3.1 Android 平台适配
- Flutter Engine 嵌入 Android 壳工程
- Platform Channel 处理：通知栏、前台服务、WebView、权限、BroadcastReceiver
- 保留最小 Kotlin 层处理 Android 生命周期

### 3.2 移除旧代码与 CI/CD 更新
- 确认所有功能已通过 Rust+Flutter 实现
- 删除 `app/`、`modules/rhino/` 模块
- 从 Gradle 构建切换到 Flutter 构建 + Cargo cross-compile
- 更新 `.github/workflows/`（8 个 workflow 文件）

---

## 依赖关系图

```
阶段 0 (基础设施) ──┬──> 1.1 (规则解析) ──> 1.2 (JS引擎) ──> 1.5 (数据库)
                    ├──> 1.3 (网络层) ─────────────────────┘
                    ├──> 1.4 (书籍解析) [可并行]
                    └──> 2.1 (Flutter框架) ──> 2.2 (阅读器UI) ──> 2.3 (管理UI)
                                                                        │
                    1.1-1.5 全部完成 ──────────────────────────────────> 2.2
                    2.x 全部完成 ──> 3.1 (平台集成) ──> 3.2 (收尾)
```

**关键路径**：0 → 1.1 → 1.2 → 1.5 → 2.2 → 3.2

**可并行**：1.3/1.4 可同时进行；2.2/2.3/2.4 可并行开发

---

## 风险评估与缓解

| 风险 | 严重度 | 缓解措施 |
|------|--------|----------|
| **JS 引擎兼容性** | 极高 | 优先选 QuickJS（C 实现，兼容性广泛验证）；建立 Top 100 书源自动化测试套件；A/B 双引擎共存过渡期 |
| **书源生态断裂** | 高 | 版本化 JS API 保持向后兼容；`JsEngineCapabilitiesTest` + `SourceCompatibilityTest` 全覆盖 |
| **数据库迁移丢数据** | 高 | 保持 SQLite 格式不变直接复用；Rust 侧重写 DAO 访问层；过渡期通过 FFI 调用 Kotlin Room 降级 |
| **阅读器排版精度** | 高 | Flutter `CustomPainter` + `Paragraph` API；逐像素对比测试；保留 Kotlin 版本作参考实现 |
| **Rhino fork 定制功能丢失** | 中 | 审计 `htmlunitCoreJs 5.3.0-legado.3` 全部定制改动，确保 QuickJS 中复刻等价行为 |
| **Cronet QUIC 性能退化** | 中 | OkHttp HTTP/2 作为过渡；评估 `quinn` QUIC 成熟度 |
| **构建复杂度** | 中 | Gradle 作为顶层编排器，`cargo-ndk` + Flutter plugin 集成 Rust 构建 |

---

## 被拒绝的替代方案

| 方案 | 拒绝原因 |
|------|----------|
| **boa_engine 替代 JS 引擎** | ES6+ 兼容性不足，无法支持现有书源中的现代 JS 特性 |
| **deno_core（V8 绑定）** | 体积巨大（~30MB），不适合移动端嵌入 |
| **sqlx 替代 rusqlite** | sqlx 的编译期 schema 验证与 95 版本动态迁移冲突，rusqlite 更灵活 |
| **一次性全面重写** | 风险不可控，12-18 个月无法交付任何可用版本 |
| **Kotlin Multiplatform 替代** | 用户明确要求 Rust+Flutter，且 KMP 无法获得 Rust 的性能和内存安全优势 |

---

## 渐进式迁移路线图（推荐执行顺序）

1. **Phase A（3 个月）**：在当前 Android 项目中通过 JNI 引入 Rust `legado-parser`，A/B 测试验证性能和正确性
2. **Phase B（3 个月）**：继续 JNI 方式迁移 `legado-net`、`legado-js` 到 Rust
3. **Phase C（6 个月）**：启动 Flutter UI，Rust 核心通过 FFI 直接调用
4. **Phase D（3 个月）**：完成平台集成，下线旧 Android 原生代码

每阶段有可交付成果，风险分散，Rust 代码在 JNI 和 FFI 两种通道中复用。

---

## 多 Agent 并行开发方案

### 设计原则

- **模块隔离**：每个 Agent 负责独立 crate/目录，避免文件冲突
- **接口先行**：跨模块依赖先定义 trait/接口，再并行实现
- **每日同步**：每天早上 8:00 前停止开发，同步进度并合并成果
- **文档交接**：每次会话结束前更新 README 和 PROGRESS.md

### Agent 角色分工

| Agent | 职责范围 | 对应目录 | 分支前缀 |
|-------|----------|----------|----------|
| **Rust-Core** | legado-core / legado-parser / legado-book | `rust/legado-core/`、`rust/legado-parser/`、`rust/legado-book/` | `feature/rust-core-*` |
| **Rust-Infra** | legado-net / legado-js / legado-db / legado-server | `rust/legado-net/`、`rust/legado-js/`、`rust/legado-db/`、`rust/legado-server/` | `feature/rust-infra-*` |
| **Flutter-UI** | Flutter 全部页面 / Widget / 状态管理 | `flutter_legado/lib/` | `feature/flutter-*` |
| **Integration** | legado-ffi / CI/CD / 构建脚本 / Android 桥接 | `rust/legado-ffi/`、`.github/`、`Makefile` | `feature/integration-*` |
| **QA** | 测试 / 代码审查 / 文档验证 | 跨模块（只读 + 测试文件） | `fix/qa-*` |

### 模块责任区矩阵

```
┌─────────────────────────────────────────────────────────────┐
│  Rust-Core Agent                                             │
│  legado-core (models/crypto/layout/audio/web_book)           │
│  legado-parser (rule_analyzer/html/xpath/jsonpath/regex)     │
│  legado-book (epub/txt/mobi/pdf/export)                      │
├─────────────────────────────────────────────────────────────┤
│  Rust-Infra Agent                                            │
│  legado-net (client/cookie/middleware/rss/webdav)            │
│  legado-js (quickjs/host_api/engine_pool/sandbox)            │
│  legado-db (schema/repository/migration/import)              │
│  legado-server (axum/handlers/routes/web-dist)               │
├─────────────────────────────────────────────────────────────┤
│  Flutter-UI Agent                                            │
│  flutter_legado/lib/src/screens/ (18 页面)                    │
│  flutter_legado/lib/src/providers/ (状态管理)                 │
│  flutter_legado/lib/src/services/ (服务层)                    │
│  flutter_legado/lib/src/widgets/ (复用组件)                   │
├─────────────────────────────────────────────────────────────┤
│  Integration Agent                                           │
│  legado-ffi (bridge/api/frb_generated)                       │
│  .github/workflows/ (CI/CD)                                  │
│  Makefile / scripts/ (构建编排)                               │
│  flutter_legado/android/ (平台桥接)                          │
└─────────────────────────────────────────────────────────────┘
```

### 分支与合并协议

```
main (master)
 │
 ├── feature/rust-core-txt-search      ← Rust-Core Agent
 ├── feature/rust-infra-mcp-server     ← Rust-Infra Agent
 ├── feature/flutter-audio-player      ← Flutter-UI Agent
 ├── feature/integration-android-build ← Integration Agent
 └── fix/qa-regression-tests           ← QA Agent
```

**规则**：
1. 每个任务创建独立分支，命名格式：`{prefix}/{agent}-{task-name}`
2. 分支内可自由提交，合并到 main 前必须通过 CI
3. **跨模块接口变更**需在 main 上先合并接口定义，再各分支 rebase
4. 合并顺序：接口层 (core) → 实现层 (net/js/db) → 出口层 (ffi) → UI 层 (flutter)

### 每日协作节奏

```
┌───────────────────────────────────────────────────────────┐
│ 时间          │ 活动                                       │
├───────────────────────────────────────────────────────────┤
│ 会话开始      │ 读取 PROGRESS.md + README 了解当前状态      │
│ 开发期间      │ 各 Agent 在独立分支并行工作                 │
│ 07:30        │ 停止新功能开发，进入同步窗口                 │
│ 07:30-08:00  │ 合并分支 → 运行全量测试 → 更新文档          │
│ 08:00        │ 截止，确保 main 分支绿色                    │
└───────────────────────────────────────────────────────────┘
```

### 冲突避免策略

| 场景 | 策略 |
|------|------|
| 两个 Agent 需修改同一文件 | 由模块所有者执行，另一个 Agent 提 issue/需求 |
| 新增公共类型（legado-core） | Rust-Core 先行定义并合并，其他 Agent rebase |
| FFI 接口变更 | Integration Agent 统一维护，其他 Agent 提需求 |
| Cargo.toml 依赖变更 | 各自 crate 内独立管理，workspace 级变更由 Integration 处理 |
| Flutter 共享 Widget | Flutter-UI 统一维护，避免多人修改 |

### 当前剩余任务并行分配

| 任务 | 分配 Agent | 分支 | 依赖 |
|------|-----------|------|------|
| 解压缩 API (JsExt 5.2) | Rust-Infra | `feature/rust-infra-archive-api` | 无 |
| ReadBook 章节预加载 (JsExt 6.1) | Rust-Core | `feature/rust-core-read-preload` | 无 |
| AudioPlay 预加载 (JsExt 6.2) | Rust-Core | `feature/rust-core-audio-preload` | 无 |
| MCP Server 实现 | Rust-Infra | `feature/rust-infra-mcp-server` | 无 |
| 听书播放器完整实现 | Flutter-UI | `feature/flutter-audio-player` | AudioPlay 预加载 |
| 本地 TXT 分词搜索 | Rust-Core | `feature/rust-core-txt-search` | 无 |
| Android 实机编译验证 | Integration | `feature/integration-android-build` | 无 |
| Cronet QUIC 优化 | Rust-Infra | `feature/rust-infra-quic` | 无 |

**并行窗口分析**：
- **第一波（全并行）**：解压缩 API + ReadBook 预加载 + AudioPlay 预加载 + MCP Server + TXT 搜索 + Android 验证
- **第二波（依赖第一波）**：听书播放器（依赖 AudioPlay）+ Cronet QUIC
- **最大并行度**：6 个任务同时执行

### 质量门禁

每次合并到 main 前必须通过：
```bash
# Rust
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all -- --check

# Flutter
cd flutter_legado && flutter analyze && flutter test

# QuickJS（如涉及 legado-js）
cargo test -p legado-js --features quickjs
```

QA Agent 负责：
- 审查跨模块 PR 的接口一致性
- 验证 PROGRESS.md 与实际代码状态一致
- 回归测试（确保 534/613 测试不减少）

---

## 缺口分析与实际完成度审计（2026-07-29 源码审计）

> 本节数据来自 2026-07-29 对 Rust+FFI 层与 Flutter UI 层的两项源码级深度审计，替代此前基于任务清单的估算。

### 各层完成度总览

| 层 | 完成度 | 审计结论（vs 此前声称） |
|----|--------|----------|
| Rust 核心引擎 | **~85%** | 此前声称 92-98% 偏高：下载管理/WebDAV 同步深度不足 |
| FFI 暴露 | ~92% | 80+ 函数（含 webdav/download/review/txt_search 新模块），缺预下载/增量同步策略 API |
| JS 宿主 API | ~93% | 168 函数 vs Kotlin 112；12 个平台 API 属架构限制 |
| Flutter UI | **~78%** | 此前声称 60% 偏低、75% 接近；40 屏幕，排版引擎是最大短板（33%） |
| **整体迁移** | **~80%** | Rust ~85% / Flutter UI ~78% |

### Rust+FFI 层现状（整体 82-85%）

| 维度 | 完成度 | 关键差距 |
|------|--------|---------|
| 核心业务流程 | 98% | 全链路真实实现 |
| ReadBook 状态机 | 98% | 段评边界计算未移植 |
| WebBook 全链路 | 95% | checkJs 简化、多页目录并发合并 |
| FFI 暴露 | 92% | 80+ 函数，缺预下载/增量同步策略 API |
| JS 宿主 API | 93% | 168 函数 vs Kotlin 112；12 个平台 API 是架构限制 |
| 本地书籍 | 92% | PDF 提取精度低、MOBI 编码变体 |
| 备份恢复 | 90% | zip 字段迁移兼容性 |
| WebDAV 同步 | **75%** | 全量同步是简化版，缺增量检测+冲突合并 |
| 下载管理 | **60%** | 缺预下载智能算法（顺序/逆序5+3章）、断点续传、失败重试限制、进度持久化 |

### Flutter UI 层模块覆盖（整体 78%，40 屏幕）

| 模块 | 覆盖度 | 关键缺失 |
|------|--------|---------|
| 翻页动画（贝塞尔仿真） | 100% | - |
| 视频播放 | 100% | - |
| RSS 全家桶 | 100% | - |
| 搜索与换源 | 100% | - |
| 阅读配置面板 | 100% | - |
| 阅读器交互 | 87.5% | 长按菜单、高级菜单嵌套 |
| 设置系统 | 87.5% | WebDAV 完整流、代理配置 |
| 书源管理 | 83% | JS 沙箱联动、登录 Cookie 流 |
| 通用组件 | 83% | 复杂对话框样式 |
| 听书播放 | 80% | 后台媒体按钮、焦点管理 |
| 本地导入 | 80% | 压缩包导入、自动编码检测 |
| 主页/书架/发现 | 75% | 发现页推荐、高级分组 |
| 书签与目录 | 66.7% | 目录搜索、段评完整流程 |
| 漫画阅读 | 60% | 分页模式、高级手势 |
| 缓存/导出 | 50% | 导出格式选择 UI、EPUB 分割 |
| **排版引擎** | **33%** | **段落分页算法、中文避头尾、精确字体度量、两端对齐** |

**P0 缺失（阻塞核心体验）：**
1. 排版引擎不完整（33%）— 段落分页、中文排版优化、字体度量
2. 导出功能 UI 缺失 — 格式选择、字符集、进度显示
3. 离线缓存管理界面缺失

### FFI 桥接层现状（26+ API 模块，103+ 函数）

| 状态 | 模块 |
|------|------|
| ✅ 已实现 | bookshelf, reader, search, source, source_switch, rss, web_book, book_export, book_import, bookmark, replace_rule, audio, reading_stats, backup, config, http_tts, server, user, book_group, cache, read_record, rss_star, search_history, **webdav(6)**, **download(8)**, **review(4)**, **txt_search(4)** |
| ⚠️ 策略层缺口 | 预下载智能算法 API、WebDAV 增量同步/冲突合并 API |

### Top 10 待办事项（按优先级，2026-07-29 源码审计后修订）

| # | 事项 | 优先级 | 模块 | 预估 |
|---|------|--------|------|------|
| 1 | Flutter 排版引擎（段落分页+中文避头尾+字体度量） | **P0** | Flutter reader | 3-4 周 |
| 2 | 导出功能 UI（格式选择/字符集/进度） | **P0** | Flutter export | 1 周 |
| 3 | 离线缓存管理界面 | **P0** | Flutter cache | 1 周 |
| 4 | 下载管理深度（预下载算法/断点续传/重试限制） | P1 | Rust download | 2 周 |
| 5 | WebDAV 增量同步 + 冲突合并 | P1 | Rust webdav | 1-2 周 |
| 6 | 目录搜索 + 段评完整流程 | P1 | Flutter toc/review | 1 周 |
| 7 | 听书后台媒体按钮 + 焦点管理（Platform Channel） | P1 | Flutter audio | 1 周 |
| 8 | 漫画分页模式 + 高级手势 | P2 | Flutter comic | 1 周 |
| 9 | 压缩包导入 + 编码检测 | P2 | Flutter import | 1 周 |
| 10 | 发现页推荐 + WebDAV 设置完整流 | P2 | Flutter explore/settings | 1-2 周 |

---

## Android 构建流程（已验证）

### 环境要求

| 工具 | 路径/版本 | 用途 |
|------|----------|------|
| Android NDK | `D:\Android\ndk\28.2.13676358` | Rust 交叉编译链接器 |
| Rust targets | `aarch64-linux-android`, `x86_64-linux-android`, `armv7-linux-androideabi` | 多架构编译 |
| Flutter | 系统 PATH | APK 构建 |
| ADB | `D:\Android\platform-tools\adb.exe` | 安装/调试 |

### 一键构建

```powershell
cd flutter_legado
.\scripts\build-apk.ps1                    # 构建 debug APK 并安装到设备
.\scripts\build-apk.ps1 -Targets "x86_64"  # 仅编译模拟器架构（更快）
.\scripts\build-apk.ps1 -SkipRust          # 跳过 Rust 编译（.so 已存在）
.\scripts\build-apk.ps1 -Release           # Release 模式
```

### 手动分步构建

```powershell
# Step 1: Rust 交叉编译（自动复制 .so 到 jniLibs）
cd rust
.\scripts\build-android.ps1 -Mode release -Targets "aarch64,x86_64"

# Step 2: Flutter 构建 APK
cd ..\flutter_legado
flutter build apk --debug

# Step 3: 安装到设备
D:\Android\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-debug.apk
D:\Android\platform-tools\adb.exe shell am start -n "io.legado.flutter_legado/io.legado.flutter.MainActivity"
```

### 构建链路说明

```
rust/scripts/build-android.ps1
  ├─ 自动检测 NDK 路径
  ├─ 设置 CC/AR 环境变量（NDK clang）
  ├─ cargo build --release --target <triple> -p legado-ffi
  └─ 复制 .so → flutter_legado/android/app/src/main/jniLibs/<abi>/

flutter build apk
  ├─ build.gradle.kts 配置 jniLibs.srcDirs("src/main/jniLibs")
  ├─ 自动检测：若 jniLibs 为空，Gradle copyRustLibs 任务从 rust/target 复制
  └─ APK 打包包含 lib/<abi>/liblegado_ffi.so
```

### 关键技术决策

| 决策 | 原因 |
|------|------|
| reqwest `default-features = false` + `rustls-tls` | 避免 OpenSSL 交叉编译（需 Perl，本机未安装） |
| rustls 替代 native-tls | 纯 Rust TLS，无 C 依赖，Android 交叉编译零障碍 |
| .so 不入库（.gitignore） | 二进制产物 ~22MB/架构，由构建脚本生成 |
| jniLibs 标准目录 | Gradle 自动打包，无需额外配置 |

### 验证记录

- ✅ x86_64-linux-android 编译成功（雷电模拟器 ABI）
- ✅ aarch64-linux-android 编译成功（真机 ABI）
- ✅ APK 包含 liblegado_ffi.so（x86_64: 22.3MB, arm64-v8a: 22.7MB）
- ✅ 雷电模拟器安装启动零错误，FFI 初始化成功
- ✅ Windows `cargo check -p legado-ffi` 通过（不影响桌面端）
