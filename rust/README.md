# Legado Rust 核心引擎

Legado（阅读）是一款开源小说阅读器，本目录包含其 **Rust 核心引擎**，负责所有跨平台业务逻辑：书源解析、网络请求、JavaScript 沙箱、书籍文件处理、本地数据库，以及通过 `flutter_rust_bridge` 向 Flutter 层暴露的 FFI 接口。

---

## 架构总览

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
```

---

## Crate 说明

| Crate | 职责 | 关键依赖 |
|-------|------|----------|
| **legado-core** | 公共基础层：统一错误类型（`thiserror`）、通用数据模型（`serde`）、WebBook 搜索链路、CacheBook 离线缓存 | serde, serde_json, thiserror |
| **legado-parser** | 书源规则解析：CSS 选择器、XPath、正则，将 HTML/XML 转换为结构化章节数据 | scraper, sxd-xpath, regex |
| **legado-net** | 网络引擎：HTTP 请求、Cookie 管理、URL 处理、响应编码检测、UA 轮换、代理/SSL 配置、书源有效性检查 | reqwest (rustls-tls), url, tokio |
| **legado-js** | JavaScript 沙箱：执行书源中的 JS 脚本，支持 MD5/SHA/Base64 等加密函数（可选 feature）| rquickjs (optional) |
| **legado-book** | 书籍文件处理：EPUB 解析、TXT 编码检测、ZIP 解压 | zip, quick-xml, encoding_rs |
| **legado-db** | 本地 SQLite 数据库：书架、阅读进度、书源存储、书签、替换规则 | rusqlite (bundled) |
| **legado-ffi** | FFI 出口：聚合所有 crate，通过 `flutter_rust_bridge` 生成跨语言接口 | flutter_rust_bridge, tokio |
| **legado-server** | HTTP 服务：axum Web 服务器，提供 REST API、静态文件服务、Web SPA 前端 | axum, tokio, tower-http |

---

## 环境要求

- **Rust**: stable（见 `rust-toolchain.toml`）
- **Android NDK**（交叉编译时需要）：建议 r26+
- **flutter_rust_bridge_codegen**（代码生成时需要）：
  ```bash
  cargo install flutter_rust_bridge_codegen
  ```

---

## 本地开发

### 语法检查（不生成产物，最快）
```bash
cargo check
```

### 编译（host 平台）
```bash
cargo build            # debug
cargo build --release  # release
```

### 运行测试

> **重要**：JS 书源依赖 QuickJS。默认 `cargo test` **不带** `quickjs` feature 时，`legado-ffi` 中依赖 JS 引擎的用例会失败或降级为 Stub（书源 JS 全不可用）。质量门禁须使用：

```bash
cargo test --workspace --exclude legado-ffi   # 非 FFI crate 全量
cargo test -p legado-ffi --features quickjs   # FFI + JS 引擎全量（CI 同口径）
cargo test -p legado-js --features quickjs    # JS 引擎单 crate
```

不带 `--features quickjs` 的 `cargo build` 产物可编译，但**无法执行书源 JS 规则**（AnalyzeUrl `@js:`、正文 jsLib 等）。

### 代码格式化 & Lint
```bash
cargo fmt --all
cargo clippy --all-targets -- -D warnings
```

---

## Android 交叉编译

### 前置准备

1. 安装 Android NDK，设置环境变量：
   ```bash
   export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/<version>
   ```

2. 安装 Rust Android targets：
   ```bash
   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
   ```

3. 配置 Cargo linker（`.cargo/config.toml` 已包含）。

### 使用构建脚本

**Linux / macOS:**
```bash
./scripts/build-android.sh          # release（默认）
./scripts/build-android.sh debug    # debug
```

**Windows (PowerShell):**
```powershell
.\scripts\build-android.ps1             # release（默认）
.\scripts\build-android.ps1 -Mode debug # debug
```

脚本会编译 `legado-ffi` 并将生成的 `.so` 文件复制到 `flutter_legado/android/app/src/main/jniLibs/`，同时写入 `liblegado_ffi.so.meta`（content hash 标记，供校验脚本与 Gradle 使用）。

### 校验与自动同步（根治 content hash 失配）

构建 APK 前会自动校验 Dart 侧 `rustContentHash` 与 jniLibs 中 `.so` 是否同步：

```powershell
# 仅校验（失败时打印可复制命令）
.\rust\scripts\verify-ffi-android.ps1

# 失配时自动重编
.\rust\scripts\verify-ffi-android.ps1 -AutoBuild -Mode debug -Targets "aarch64,x86_64"
```

**推荐统一入口**（校验 + 编译 + 打包 + 安装）：

```powershell
.\flutter_legado\scripts\build-apk.ps1
```

Gradle `preBuild` 也会执行 `verifyRustFfiLibs`；纯 Dart UI 开发者可设置 `LEGADO_SKIP_RUST_BUILD=1` 或使用 `--dart-define=USE_MOCK=true`。

---

## flutter_rust_bridge 代码生成

当 Rust 侧的公共 API（`legado-ffi/src/lib.rs`）发生变更后，需要重新生成 Dart 绑定：

```bash
cd flutter_legado
flutter_rust_bridge_codegen generate
# 或使用脚本
./scripts/generate-bridge.sh
```

生成产物位于 `flutter_legado/lib/src/bridge/`，已被 `.gitignore` 忽略。

---

## 技术栈

| 类别 | 技术 |
|------|------|
| 语言 | Rust 2021 Edition |
| 序列化 | serde + serde_json |
| 错误处理 | thiserror |
| 异步运行时 | tokio |
| HTTP 客户端 | reqwest（rustls-tls） |
| HTML 解析 | scraper |
| XPath | sxd-xpath + sxd-document |
| JS 引擎 | rquickjs（可选 feature） |
| 书籍格式 | zip + quick-xml + encoding_rs |
| 数据库 | rusqlite（bundled SQLite） |
| FFI 框架 | flutter_rust_bridge 2.12.0 |

---

## 目录结构

```
rust/
├── Cargo.toml              # workspace 配置
├── Cargo.lock
├── rust-toolchain.toml     # Rust 工具链版本
├── .cargo/config.toml      # Cargo 配置（含 Android linker）
├── scripts/
│   ├── build-android.sh    # Linux/Mac 交叉编译脚本
│   └── build-android.ps1   # Windows 交叉编译脚本
├── legado-core/            # 公共基础层（含 WebBook、CacheBook、ReviewRule、ExploreRule）
├── legado-parser/          # 书源解析（含 AnalyzeUrl 完整模板引擎）
├── legado-net/             # 网络引擎（含 UA/代理/SSL、SourceChecker）
├── legado-js/              # JavaScript 沙箱
├── legado-book/            # 书籍文件处理
├── legado-db/              # SQLite 数据库（含 Bookmark/ReplaceRule Repository）
├── legado-ffi/             # FFI 出口（cdylib + staticlib，含 WebBook API）
├── legado-server/          # HTTP 服务（axum Web 服务器，含 WebBook/SourceCheck 端点）
│   └── web-dist/           # Web SPA 前端静态资源
├── legacy-ffi/             # ⚠️ 已废弃，不参与编译（见下方说明）
└──
```

> **注意**：`legacy-ffi/` 为早期废弃模块，不在 workspace 成员中，不参与编译。保留仅供历史参考。

---

## 项目进度（截至 2026-08-01）

> 完整进度跟踪文档见 [PROGRESS.md](./PROGRESS.md)

### 当前状态：148/148 原子任务已完成，Rust 1409 测试默认通过 / Flutter 952 通过（2026-08-02 实测，Phase 5.4 去重 bookshelf_provider_test 后）

| Crate | 测试数 | 状态 |
|-------|--------|------|
| legado-core | 502 | ✅ 完成 |
| legado-parser | 72 | ✅ 完成 |
| legado-net | 188 | ✅ 完成 |
| legado-js | 158（默认）/ 327（quickjs） | ✅ 完成 |
| legado-book | 120 | ✅ 完成 |
| legado-db | 220（215 单元 + 4 集成 + 1 文档） | ✅ 完成 |
| legado-ffi | 105 | ✅ 完成 |
| legado-server | 164 | ✅ 完成 |
| **合计** | **1409**（默认）/ **1578**（quickjs+ffi） | |

### 已完成阶段
- **阶段 0**：基础设施（workspace 骨架、数据模型、FFI 规范）
- **阶段 1**：Rust 核心引擎（规则解析、JS 沙箱、HTTP 网络、书籍解析、数据库、加密、排版、换源）
- **阶段 2**：Flutter UI + FFI（85+ FFI 导出、38 页面、flutter_rust_bridge）
- **阶段 3**：集成与扩展（Android 桥接、axum HTTP 服务、Web SPA、TTS、RSS、WebDAV、DB 迁移、Room 导入、MCP Server）
- **阶段 4**：国际化与收尾（Flutter 中英文双语、语言切换、阅读统计、听书播放器、书源编辑器）
- **阶段 5**：最终收尾（DEVELOPMENT.md 开发者指南、PROGRESS.md 完整记录、README 更新）
- **阶段 6**：核心链路完善（AnalyzeUrl 模板、书签/替换规则、WebBook 搜索、网络中间件、书源发现、导出服务、离线缓存/段评、关联导入）
- **阶段 7**：JsExtensions 完整实现（java 命名空间、网络统一、引擎池化、55+ API、平台桩）
- **阶段 8**：Flutter UI 完善（38 屏幕、阅读器增强、书源调试、浏览器、词典、字体、二维码）
- **阶段 9**：Android 构建验证（交叉编译、APK 构建、雷电模拟器安装验证通过）
- **阶段 10-23**：补全与增强、内容处理管线、UI 集成接线、审计修复、FFI 扩展、Flutter UI 深度实现 + 工程化

### 已完成（原“远期优化”列表，已全部实现）
- ✅ 端到端流程跑通（书源导入→搜索→阅读→书签→替换规则全链路可用）
- ✅ 阅读器深度实现（仿真翻页动画 + 段评弹窗 + 漫画模式）
- ✅ CI 自动发布（flutter-release.yml，push tag 触发）
- ✅ 视频播放（video_player + 播放控制 + 全屏 + 手势，Task #145）
- ✅ 漫画阅读（纵向滚动 + 双指缩放 + 图片预加载 + 进度保存，Task #146）
- ✅ QUIC 接入主网络链路（可选 QUIC + fallback HTTP/2，Task #43）
- ✅ Cronet 替代方案（Rust reqwest + QUIC 替代，无需引入 Cronet）

---

## JS 沙箱安全基线

`legado-js` crate 在启用 `quickjs` feature 后，通过 `SandboxConfig` 实施以下安全策略：

| 维度 | 策略 | 说明 |
|------|------|------|
| 执行超时 | 5s | 超时后中断脚本 |
| eval / Function | **书源主路径启用** | `EnginePool` 默认 `allow_script_run=true`（对齐 Rhino）；`SandboxConfig::default()` 仍禁用，供 `js_eval` 严格入口 |
| 文件 IO | 禁止 | `allow_file_access=false`，不注册 readFile/writeFile 等宿主 API |
| 网络 | 受控保留 | 经 legado-net 统一通道，30s 超时 / 限流，与 Kotlin 原版书源对等 |
| 内存上限 | 16 MB | QuickJS 分配失败即报错 |
| 栈深度 | 512 | 配置项（enforcement 见 F3-3） |

> 详细实现见 `legado-js/src/sandbox.rs` 模块文档。

> 详细开发指南见 [DEVELOPMENT.md](./DEVELOPMENT.md)
