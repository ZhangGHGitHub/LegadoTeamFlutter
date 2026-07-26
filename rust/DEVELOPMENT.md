# Legado Rust 开发者指南

> 本文档面向新加入项目的开发者，帮助你快速搭建环境、理解代码结构并开始贡献。

---

## 环境配置

### 1. 安装 Rust

```bash
# 安装 rustup（推荐）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 安装 stable 工具链
rustup install stable
```

> **Windows 注意**：若 `cargo` 命令不可识别，需将 `C:\Users\<用户名>\.cargo\bin` 加入系统 PATH，或在 PowerShell 中临时执行：
> ```powershell
> $env:PATH = "C:\Users\<用户名>\.cargo\bin;$env:PATH"
> ```

### 2. 安装 Flutter

参考官方文档：https://flutter.dev/docs/get-started/install

确保 Flutter SDK >= 3.11.5：
```bash
flutter --version
```

### 3. 安装 flutter_rust_bridge CLI

```bash
cargo install flutter_rust_bridge_codegen
```

### 4. 验证环境

```bash
cargo --version
flutter --version
flutter_rust_bridge_codegen --version
```

---

## 项目结构

本项目由 8 个 Rust crate 组成，分层架构如下：

```
┌─────────────────────────────────────────────────────┐
│                   Flutter UI 层                      │
│              (flutter_legado/)                       │
└────────────────────────┬────────────────────────────┘
                         │  flutter_rust_bridge (FFI)
┌────────────────────────▼────────────────────────────┐
│                    legado-ffi                        │
│           (cdylib / staticlib 入口)                  │
├──────────┬──────────┬──────────┬──────────┬─────────┤
│legado-   │legado-   │legado-   │legado-   │legado-  │
│parser    │net       │js        │book      │db       │
├──────────┴──────────┴──────────┴──────────┴─────────┤
│                   legado-core                        │
│            (公共类型 / 错误 / 工具)                   │
└─────────────────────────────────────────────────────┘

legado-server — 独立 HTTP 服务，依赖 legado-core/db/net/parser/js
```

### Crate 依赖关系

| Crate | 依赖 | 说明 |
|-------|------|------|
| **legado-core** | serde, thiserror | 无内部依赖，公共基础层 |
| **legado-parser** | core | 书源规则解析（CSS/XPath/Regex/JsonPath） |
| **legado-net** | core | HTTP 请求、Cookie、URL 模板、RSS、WebDAV |
| **legado-js** | core | JavaScript 沙箱（可选 QuickJS feature） |
| **legado-book** | core | 书籍文件解析（EPUB/TXT/MOBI/PDF） |
| **legado-db** | core | SQLite 数据库（rusqlite bundled） |
| **legado-ffi** | 全部 | FFI 出口，聚合所有 crate |
| **legado-server** | core, db, net, parser, js | axum HTTP 服务 |

---

## 常用命令

### 编译检查

```bash
# 全 workspace 检查（不生成产物，最快）
cargo check --workspace

# 检查特定 crate
cargo check -p legado-core
```

### 运行测试

```bash
# 全 workspace 测试（不含 QuickJS）
cargo test --workspace

# 含 QuickJS feature 的完整测试
cargo test -p legado-js --features quickjs

# 测试单个 crate
cargo test -p legado-core
cargo test -p legado-parser
cargo test -p legado-net
cargo test -p legado-book
cargo test -p legado-db
cargo test -p legado-ffi
cargo test -p legado-server
```

### 代码质量

```bash
# Lint 检查
cargo clippy --workspace --all-targets -- -D warnings

# 格式化
cargo fmt --all

# 格式化检查（CI 用）
cargo fmt --all -- --check
```

### 构建

```bash
# Debug 构建
cargo build --workspace

# Release 构建（服务端部署）
cargo build --release -p legado-server

# Android 交叉编译（Linux/Mac）
./scripts/build-android.sh release

# Android 交叉编译（Windows PowerShell）
.\scripts\build-android.ps1 -Mode release
```

### Flutter

```bash
cd flutter_legado

# 安装依赖
flutter pub get

# 代码分析
flutter analyze

# 运行（热重载）
flutter run

# 构建 APK
flutter build apk

# 生成 Bridge 代码（Rust API 变更后）
flutter_rust_bridge_codegen generate
# 或使用脚本
.\scripts\generate-bridge.ps1   # Windows
./scripts/generate-bridge.sh    # Linux/Mac
```

### Windows 桌面构建与运行

```powershell
# 一键构建+运行（PowerShell）
cd flutter_legado
.\scripts\build-windows.ps1

# 仅构建不运行
.\scripts\build-windows.ps1 -BuildOnly

# Release 模式
.\scripts\build-windows.ps1 -Release

# 清理后重新构建
.\scripts\build-windows.ps1 -Clean

# CMD 兼容
flutter_legado\scripts\build-windows.bat
```

构建流程：
1. 编译 Rust FFI 库（`cargo build -p legado-ffi`）
2. 构建 Flutter Windows 应用（`flutter build windows`）
3. 复制 `legado_ffi.dll` 到 Flutter 构建输出目录
4. 可选运行应用（`flutter run -d windows`）

也可通过根目录 Makefile：
```bash
make run-windows          # 构建并运行
make build-windows        # 仅构建（Debug）
make build-windows-release  # 仅构建（Release）
```

### Makefile 快捷命令

```bash
cd flutter_legado
make check    # Rust cargo check + Flutter analyze
make test     # Rust cargo test + Flutter test
make build    # Rust .so + Flutter APK (release)
make clean    # cargo clean + flutter clean
make gen      # flutter_rust_bridge_codegen generate
```

---

## 代码结构概览

### legado-core — 公共基础层

| 文件 | 职责 |
|------|------|
| `lib.rs` | 模块导出 |
| `error.rs` | 统一错误类型 `LegadoError`（thiserror） |
| `types.rs` | 通用类型定义 |
| `models/` | 数据模型：Book、BookChapter、BookSource、RssSource、Misc、ExploreRule、ReviewRule |
| `crypto.rs` | 加密工具：AES/DES/RC4 |
| `layout.rs` | 排版引擎 |
| `source_matcher.rs` | 换源匹配器 |
| `search_engine.rs` | 搜索引擎接口 |
| `web_book.rs` | WebBook 搜索完整链路（搜索→详情→目录→内容） |
| `cache_book.rs` | 离线缓存模型与管理 |
| `audio.rs` | 音频/TTS 类型定义 |
| `reading_stats.rs` | 阅读统计数据类型 |
| `ffi_macros.rs` | FFI 辅助宏 |

### legado-parser — 书源规则解析

| 文件 | 职责 |
|------|------|
| `rule_analyzer.rs` | 规则分析器：解析 `@js:`/CSS/XPath/Regex 混合规则 |
| `html.rs` | JSoup/CSS 选择器解析（scraper） |
| `xpath.rs` | XPath 1.0 解析（sxd-xpath） |
| `regex_engine.rs` | 正则引擎 |
| `jsonpath.rs` | JsonPath 解析 |
| `analyze_rule.rs` | AnalyzeRule 统一门面：组合多解析器 |
| `analyze_url.rs` | AnalyzeUrl 完整 URL 模板引擎（分页、动态参数、POST body、header） |

### legado-net — 网络引擎

| 文件 | 职责 |
|------|------|
| `client.rs` | LegadoClient：统一 HTTP 客户端（reqwest） |
| `cookie_store.rs` | Cookie 持久化管理 |
| `url_template.rs` | URL 模板处理 |
| `request.rs` / `response.rs` | 请求/响应封装 |
| `middleware.rs` | 网络中间件链 |
| `retry.rs` | 请求重试策略 |
| `rate_limit.rs` | 请求限流 |
| `user_agent.rs` | UA 轮换管理 |
| `proxy.rs` | 代理配置 |
| `ssl_config.rs` | SSL/TLS 配置 |
| `source_checker.rs` | 书源有效性检查 |
| `rss.rs` | RSS/Atom Feed 解析 |
| `webdav.rs` | WebDAV 云同步客户端 |
| `cover.rs` | 封面图片缓存 |
| `verification.rs` | VerificationFlightRegistry 并发去重 |

### legado-js — JavaScript 沙箱

| 文件 | 职责 |
|------|------|
| `engine.rs` | JsEngine 主引擎（无 QuickJS 时的 fallback） |
| `sandbox.rs` | 沙箱管理：内存限制 + 超时中断 |
| `scope.rs` | SharedScopeManager（LRU 作用域缓存） |
| `context.rs` | JS 执行上下文 |
| `source_engine.rs` | 书源 JS 执行引擎 |
| `host_api/` | 宿主 API 目录 |
| `host_api/encoding.rs` | MD5/SHA/Base64 编解码 |
| `host_api/string_utils.rs` | 字符串处理函数 |
| `host_api/regex_utils.rs` | 正则工具函数 |
| `host_api/json_utils.rs` | JSON 工具函数 |
| `host_api/network.rs` | httpGet/httpPost（LegadoClient 统一网络栈） |
| `host_api/platform.rs` | 平台专属 API 桩（Android WebView/Toast/Intent 等） |
| `host_api/file_utils.rs` | 文件工具 |
| `host_api/time_utils.rs` | 时间工具 |
| `host_api/variable_store.rs` | 变量存储 |
| `host_api/quickjs_impl.rs` | QuickJS 真实实现（需 `quickjs` feature） |

### legado-book — 书籍文件处理

| 文件 | 职责 |
|------|------|
| `lib.rs` | LocalBook 统一入口：自动识别格式 |
| `epub.rs` | EPUB 解析（quick-xml + zip） |
| `txt.rs` | TXT 编码检测与解析（encoding_rs） |
| `mobi.rs` | MOBI 格式解析 |
| `pdf.rs` | PDF 解析（lopdf） |

### legado-db — SQLite 数据库

| 文件 | 职责 |
|------|------|
| `connection.rs` | 数据库连接管理（tokio::Mutex 包装） |
| `schema.rs` | Schema v95 定义（CREATE TABLE 语句） |
| `migration.rs` | 迁移框架入口 |
| `migration/migrations.rs` | 具体迁移脚本（v90→v95） |
| `import.rs` | RoomImporter：从 Android Room 导入数据 |
| `repository/` | Repository 模式 |
| `repository/book_repository.rs` | 书籍 CRUD |
| `repository/book_chapter_repository.rs` | 章节 CRUD |
| `repository/book_source_repository.rs` | 书源 CRUD |
| `repository/auto_task_repository.rs` | 定时任务 CRUD |
| `repository/bookmark_repository.rs` | 书签 CRUD |
| `repository/replace_rule_repository.rs` | 替换规则 CRUD |
| `repository/reading_stats_repository.rs` | 阅读统计 CRUD |
| `tests/integration_test.rs` | 数据库集成测试 |

### legado-ffi — FFI 出口

| 文件 | 职责 |
|------|------|
| `lib.rs` | 入口：flutter_rust_bridge 初始化 |
| `bridge.rs` | Bridge API 聚合 |
| `runtime.rs` | tokio 运行时管理 |
| `db_state.rs` | 全局数据库状态 |
| `error.rs` | FFI 错误转换 |
| `ffi.rs` | 底层 FFI 导出函数 |
| `frb_generated.rs` | flutter_rust_bridge 生成代码 |
| `api/` | 按功能分组的 API |
| `api/bookshelf.rs` | 书架操作 API |
| `api/reader.rs` | 阅读器 API |
| `api/search.rs` | 搜索 API |
| `api/source.rs` | 书源管理 API |
| `api/source_switch.rs` | 换源 API |
| `api/rss.rs` | RSS API |
| `api/book_import.rs` | 书籍导入 API |
| `api/web_book.rs` | WebBook 搜索链路 API |

### legado-server — HTTP 服务

| 文件 | 职责 |
|------|------|
| `server.rs` | axum 服务器启动与配置 |
| `routes.rs` | 路由注册（20+ REST 端点） |
| `state.rs` | AppState：共享数据库/客户端 |
| `error.rs` | HTTP 错误处理 |
| `handlers/` | 请求处理器 |
| `handlers/bookshelf.rs` | 书架 REST API |
| `handlers/reader.rs` | 阅读 REST API |
| `handlers/search.rs` | 搜索 REST API |
| `handlers/source.rs` | 书源 REST API |
| `handlers/source_check.rs` | 书源有效性检查 API |
| `handlers/web_book.rs` | WebBook 搜索链路 API |
| `handlers/rss.rs` | RSS REST API |
| `handlers/audio.rs` | 音频/TTS REST API |
| `handlers/tts.rs` | TTS 引擎端点 |
| `handlers/health.rs` | 健康检查 |
| `tests/integration_test.rs` | HTTP 服务集成测试 |
| `web-dist/` | Web SPA 前端静态资源 |

---

## 关键设计决策

### 1. JSON 序列化跨 FFI

**问题**：flutter_rust_bridge 对复杂 Rust 类型（嵌套结构体、枚举）的映射存在限制（opaque 类型问题）。

**方案**：所有复杂类型通过 FFI 时序列化为 JSON 字符串，Flutter 端反序列化。

```rust
// Rust 端
pub fn get_bookshelf() -> Result<String> {
    let books = repo.get_all_books()?;
    Ok(serde_json::to_string(&books)?)
}

// Dart 端
final json = await RustLib.instance.api.getBookshelf();
final books = (jsonDecode(json) as List).map((e) => Book.fromJson(e)).toList();
```

**优点**：简单、类型安全、避免 frb opaque 问题。
**缺点**：有序列化开销（实际可忽略，数据量小）。

### 2. rquickjs 可选 feature — 条件编译

**问题**：QuickJS 需要编译大量 C 代码（~30 秒），开发迭代时不需要。

**方案**：使用 Cargo feature 条件编译：

```toml
[features]
default = []
quickjs = ["dep:rquickjs"]
```

- 默认（无 feature）：使用 fallback 引擎，仅提供基础 JS 执行
- 启用 `quickjs`：完整 QuickJS ES6+ 支持

**开发时**：`cargo test --workspace`（快速）
**发布/完整测试**：`cargo test -p legado-js --features quickjs`

### 3. rusqlite tokio::Mutex — Connection 非 Sync

**问题**：`rusqlite::Connection` 是 `!Sync`，无法直接在 tokio 异步任务间共享。

**方案**：使用 `tokio::sync::Mutex` 包装连接：

```rust
pub struct Database {
    conn: tokio::sync::Mutex<rusqlite::Connection>,
}
```

每次操作获取锁：
```rust
async fn get_books(&self) -> Result<Vec<Book>> {
    let conn = self.conn.lock().await;
    // 执行 SQL
}
```

### 4. 网络中间件链

**设计**：请求经过中间件链处理：

```
Request → RetryMiddleware → RateLimitMiddleware → CookieMiddleware → Client → Response
```

- **RetryMiddleware**：失败自动重试（指数退避）
- **RateLimitMiddleware**：请求限流（令牌桶）
- **CookieMiddleware**：自动管理 Cookie 持久化

### 5. SharedScopeManager（LRU 作用域缓存）

JS 引擎创建开销大，使用 LRU 缓存复用 JS 作用域：

- 每个书源对应一个 JS 作用域
- 最近使用的作用域优先保留
- 超出容量时淘汰最久未使用的

### 6. java 命名空间约定

书源 JS 规则通过 `java` 对象访问宿主 API，这是 Kotlin 端 `JsExtensions` 的核心约定：

```javascript
// 书源规则中的典型用法
java.get(url)              // GET 请求
java.post(url, body)       // POST 请求
java.getStr(url)           // GET 请求返回字符串
java.postJson(url, json)   // POST JSON
java.md5(str)              // MD5 哈希
java.aesDecodeToString(data, key, transformation, iv)  // AES 解密
java.cookieStore.get(name) // 读取 Cookie
java.variableStore.get(key) // 读取变量
```

**Rust 实现**：通过 `HostApiRegistry` 在 QuickJS 全局上下文中注册 `java` 对象，绑定所有宿主 API 方法。网络请求统一使用 `LegadoClient`（复用连接池、中间件、重试策略）。

---

## 已知限制

1. **QuickJS 编译耗时较长**：首次编译需编译 C 代码（约 30 秒），后续增量编译较快
2. **Android 实机编译未验证**：交叉编译脚本已就绪，但未在真实设备上验证运行
3. **平台专属 API 不可用**：依赖 Android 平台的 API（WebView、Toast、Intent 等）在 Rust 运行时中返回错误提示，详见下方清单

### 不支持的平台 API 清单（platform.rs）

以下 API 依赖 Android 平台，在 Rust 运行时中返回明确错误提示或降级默认值：

| API | 原 Android 依赖 | Rust 运行时行为 |
|-----|----------------|------------------|
| `web_view(url)` | Android WebView | 返回 `[ERROR]` 提示 |
| `web_view_get_source(url)` | Android WebView | 返回 `[ERROR]` 提示 |
| `web_view_get_override_url()` | Android WebView | 返回 `[ERROR]` 提示 |
| `start_browser(url)` | Android Intent | 返回 `[ERROR]` 提示 |
| `open_url(url)` | Android Intent | 返回 `[ERROR]` 提示 |
| `toast(msg)` | Android Toast | 输出到 stderr，返回空字符串 |
| `get_verification_code(url)` | WebView + 人机交互 | 返回 `[ERROR]` 提示 |
| `android_id()` | Android Context | 返回 `[ERROR]` 提示 |
| `get_web_view_ua()` | Android WebView | 返回 `[ERROR]` 提示 |
| `open_video_player(url)` | Android Intent | 返回 `[ERROR]` 提示 |
| `get_read_book_config()` | SharedPreferences | 返回 `{}`（空 JSON 降级） |
| `get_theme_mode()` | Android 主题 | 返回 `"light"`（默认浅色） |

---

## 调试技巧

### 启用日志

```bash
# 全量 debug 日志
RUST_LOG=debug cargo run -p legado-server

# 指定模块日志
RUST_LOG=legado_net=debug,legado_parser=info cargo run -p legado-server
```

### 测试单个 crate

```bash
cargo test -p legado-core
cargo test -p legado-parser
cargo test -p legado-net
cargo test -p legado-db
```

### QuickJS 调试

```bash
# 带输出打印
cargo test -p legado-js --features quickjs -- --nocapture

# 运行特定测试
cargo test -p legado-js --features quickjs test_quickjs_eval -- --nocapture
```

### 数据库调试

```bash
# 运行集成测试（会创建临时数据库）
cargo test -p legado-db -- --nocapture
```

### HTTP 服务调试

```bash
# 启动本地服务器
cargo run -p legado-server

# 访问 http://localhost:8080
# Web SPA: http://localhost:8080/
# API: http://localhost:8080/api/health
```

---

## 常见问题

### Q: `cargo` 命令未找到（Windows）

**A**: Rust 工具链未加入 PATH。执行：
```powershell
$env:PATH = "C:\Users\admin\.cargo\bin;$env:PATH"
```
或永久添加到系统环境变量。

### Q: cargo check 超时或报 "Missing manifest in toolchain"

**A**: rustup 工具链损坏，重新安装：
```bash
rustup toolchain install stable
```

### Q: QuickJS 编译失败（链接错误）

**A**: QuickJS 需要 C 编译器。确保安装了：
- Windows: Visual Studio Build Tools (MSVC)
- Linux: `build-essential`
- macOS: Xcode Command Line Tools

### Q: flutter_rust_bridge_codegen 报错

**A**: 确保版本匹配（当前使用 2.12.0）：
```bash
cargo install flutter_rust_bridge_codegen --version 2.12.0
```

### Q: 测试全部通过但 CI 失败

**A**: CI 通常启用 `-D warnings` 严格模式。本地运行：
```bash
cargo clippy --workspace --all-targets -- -D warnings
```

### Q: Android 交叉编译链接失败

**A**: 检查 `.cargo/config.toml` 中的 linker 配置，确保 Android NDK 路径正确：
```bash
# 确认 NDK 路径
echo $ANDROID_NDK_HOME
# 确认 target 已安装
rustup target list --installed
```

### Q: 如何只运行部分测试？

**A**: 使用测试名称过滤：
```bash
cargo test -p legado-core test_book_model
cargo test --workspace test_search
```

---

## 测试统计（2026-07-26）

| Crate | 测试数（默认） | 测试数（quickjs） | 备注 |
|-------|---------------|-------------------|------|
| legado-core | 126 | 126 | 数据模型、规则、加密、排版、换源、WebBook、CacheBook |
| legado-parser | 53 | 53 | 4 解析器 + AnalyzeRule + AnalyzeUrl 完整模板 |
| legado-net | 140 | 140 | HTTP、Cookie、RSS、WebDAV、并发去重、UA/代理/SSL、SourceChecker |
| legado-js | 34 | 113 | 默认 34 + QuickJS 额外 79（含 platform 桩 2 tests） |
| legado-book | 36 | 36 | EPUB/TXT/MOBI/PDF |
| legado-db | 74 | 74 | Schema + 7 Repository + 集成测试 |
| legado-ffi | 14 | 14 | 30+ FFI 导出 + 换源 + WebBook |
| legado-server | 57 | 57 | axum + 20+ REST + Web SPA + WebBook + SourceCheck |
| **合计** | **534** | **613** | Flutter: 15 tests |

---

## 版本控制与发布流程

### 版本管理规范

#### 版本号
- Rust crates: 语义化版本（SemVer），当前 0.2.0
- Flutter app: 语义化版本 + 构建号，当前 2.0.0+2
- 格式: MAJOR.MINOR.PATCH（不兼容变更.新功能.修复）

#### 发布流程
1. 更新各 Cargo.toml 和 pubspec.yaml 版本号
2. 更新 CHANGELOG.md
3. git tag vX.Y.Z
4. GitHub Release 自动生成 Release Notes

#### CHANGELOG 维护
- 格式遵循 [Keep a Changelog](https://keepachangelog.com/)
- 每次 PR 需在 CHANGELOG 对应版本下添加条目
- 分类: Added / Changed / Fixed / Breaking Changes

### 版本号规范

| 组件 | 版本格式 | 当前版本 | 说明 |
|------|----------|----------|------|
| 整体项目 | `vX.Y.Z` | v4.0.0-alpha | 语义化版本，Git tag 格式 |
| Rust crate | `X.Y.Z` | 0.2.0 | 各 crate 独立版本，workspace 统一发布时同步递增 |
| Flutter | `X.Y.Z+build` | 2.0.0+2 | pubspec.yaml 中维护，build 号递增 |
| Android（旧） | `3.YYMMDDHH` | 自动生成 | 历史遗留格式，仅旧架构使用 |

### 语义化版本规则

- **Major (X)**：不兼容的 API/架构变更（如 FFI 接口破坏性改动）
- **Minor (Y)**：向后兼容的功能新增（如新增宿主 API、新增页面）
- **Patch (Z)**：向后兼容的 Bug 修复

### Git 提交规范

项目使用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范，通过 commitizen 辅助：

```bash
# 使用 commitizen 交互式提交
git cz

# 或手动遵循格式
git commit -m "feat: 新增书源批量导出功能"
git commit -m "fix: 修复阅读器翻页闪烁"
git commit -m "perf: 优化引擎池化内存占用"
```

**类型前缀**：

| 前缀 | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | Bug 修复 |
| `perf` | 性能优化 |
| `refactor` | 重构（不改变功能） |
| `docs` | 文档变更 |
| `test` | 测试相关 |
| `chore` | 构建/工具/依赖变更 |
| `ci` | CI/CD 配置变更 |
| `breaking` | 破坏性变更（在 footer 中标注 `BREAKING CHANGE:`） |

### 发布流程

```
1. 确保所有测试通过
   cargo test --workspace
   cargo test -p legado-js --features quickjs
   cd flutter_legado && flutter test

2. 代码质量检查
   cargo clippy --workspace --all-targets -- -D warnings
   cargo fmt --all -- --check
   cd flutter_legado && flutter analyze

3. 更新 CHANGELOG.md
   - 在顶部添加新版本条目
   - 按 Added/Changed/Fixed/Breaking Changes 分类

4. 递增版本号
   - rust/*/Cargo.toml 中的 version 字段
   - flutter_legado/pubspec.yaml 中的 version 字段

5. 提交并打 tag
   git add -A
   git commit -m "release: v4.0.0-beta"
   git tag -a v4.0.0-beta -m "Release v4.0.0-beta"

6. 推送
   git push origin main --tags
```

### CHANGELOG 维护规则

- 文件位置：项目根目录 `CHANGELOG.md`
- 格式：[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)
- 每个版本条目格式：`## [X.Y.Z] - YYYY-MM-DD`
- 分类：`Added` / `Changed` / `Fixed` / `Removed` / `Breaking Changes`
- **开发期间**： unreleased 变更累积在 `[Unreleased]` 节下
- **发布时**：将 `[Unreleased]` 重命名为具体版本号和日期
- 记录内容应为**用户可感知的变更**，纯内部重构可简略

### Git Tag 命名

- 新架构：`v4.0.0-alpha`、`v4.0.0-beta`、`v4.0.0`、`v4.1.0`
- 预发布后缀：`-alpha`（内部测试）→ `-beta`（公开测试）→ `-rc.1`（候选）→ 正式版
- 历史 Android tag（`3.YYMMDDHH`）保留不动，不再新增

### 分支策略

| 分支 | 用途 |
|------|------|
| `main` | 主干，始终保持可构建状态 |
| `feature/*` | 功能开发分支 |
| `fix/*` | Bug 修复分支 |
| `release/*` | 发布准备分支（版本号递增、CHANGELOG 定稿） |

---

## 项目相关链接

- [Rust README](./README.md) — 架构与 Crate 详细说明
- [进度跟踪](./PROGRESS.md) — 任务完成状态
- [更新日志](../CHANGELOG.md) — 版本历史记录
- [Flutter 客户端](../flutter_legado/README.md) — UI 层文档
- [上游 Legado 项目](https://github.com/gedoor/legado) — Kotlin 原版
- [本项目仓库](https://github.com/ZhangGHGitHub/LegadoTeamFlutter) — Rust+Flutter 版
