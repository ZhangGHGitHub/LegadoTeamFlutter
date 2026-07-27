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

## 缺口分析与实际完成度审计（2026-07-26）

### 各层完成度总览

| 层 | 完成度 | 关键瓶颈 |
|----|--------|----------|
| Rust 核心引擎 | ~90% | 排版细节、MCP Server 缺失 |
| JS 沙箱 (JsExtensions) | ~95% | 仅 7z/rar 解压为桩 |
| FFI 桥接 | ~65% | 缺 5 个 API 模块 |
| **Flutter UI** | **~35%** | **最大瓶颈**：功能深度不足，7 个模块完全缺失 |
| 工程化 | ~60% | 测试不足、未真机验证、无自动发布 |

### Flutter UI 层缺口明细

| Kotlin 原版模块 | 代码量 | Flutter 对应 | 覆盖度 | 缺口 |
|----------------|--------|-------------|--------|------|
| ReadBookActivity (阅读器) | 90KB/2247行 | reader_screen.dart 22KB/603行 | **25%** | 翻页动画、排版渲染、段评、朗读条、文本选择、漫画模式 |
| BookSourceEditActivity (书源编辑) | 44KB | source_edit_screen.dart 18KB | **40%** | JS 源编辑、调试面板、规则验证 |
| AudioPlayActivity (听书) | 23KB | audio_screen.dart 11KB | **40%** | 通知栏控制、进度持久化、定时停止 |
| ReadRssActivity (RSS 阅读) | 34KB | rss_article_detail 6.5KB | **20%** | WebView 渲染、JS 执行、收藏、分页 |
| RssSourceEditActivity (RSS 源编辑) | 30KB | 无 | **0%** | 完全缺失 |
| 书源调试 (Debug) | 8.4KB | 无 | **0%** | 完全缺失 |
| 浏览器 (browser/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 代码编辑器 (code/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 文件管理 (file/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 字体管理 (font/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 视频播放 (video/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 漫画阅读 (manga/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 二维码 (qrcode/) | 完整模块 | 无 | **0%** | 完全缺失 |
| 词典 (dict/) | 完整模块 | 无 | **0%** | 完全缺失 |

### FFI 桥接层缺口

| 缺失 API 模块 | Flutter 调用方 | 影响 |
|--------------|---------------|------|
| audio/TTS API | audio_provider | 听书播放器无后端支撑 |
| auto_task API | auto_task_provider | 定时任务无法执行 |
| reading_stats API | reading_stats_provider | 阅读统计无数据 |
| sync/WebDAV API | sync_provider | 云同步不可用 |
| download API | — | 下载管理无法触发 |

### 工程化缺口

| 维度 | 现状 | 缺口 |
|------|------|------|
| Flutter 测试 | 6 文件 / 15 tests | 无阅读器深度测试、无网络 mock、无集成测试 |
| Android 实机 | 从未执行 | 交叉编译→APK→真机全链路未验证 |
| 端到端流程 | 未跑通 | 书源导入→搜索→阅读全流程不可用 |
| CI 发布 | 仅手动 | 缺 Flutter APK 构建 + Rust 交叉编译自动发布 |

### Top 10 待办事项（按优先级）

| # | 事项 | 模块 | 预估 |
|---|------|------|------|
| 1 | 阅读器深度实现（翻页动画/排版/段评/朗读条） | Flutter reader | 4-6 周 |
| 2 | FFI 补齐 audio/auto_task/stats/sync API | legado-ffi | 1-2 周 |
| 3 | Android 实机编译验证 | Integration | 1 周 |
| 4 | 书源编辑器完善（JS 源/调试/验证） | Flutter source_edit | 2-3 周 |
| 5 | RSS 阅读深度实现（WebView/JS/收藏） | Flutter rss | 2 周 |
| 6 | Flutter 测试覆盖提升 | test/ | 2 周 |
| 7 | 听书播放器完善 + FFI audio API | Flutter audio + ffi | 2 周 |
| 8 | 书源调试页面 | Flutter 新增 | 1 周 |
| 9 | 主框架/导航完善 | Flutter home | 1 周 |
| 10 | CI 自动发布流程 | .github/workflows | 1 周 |
