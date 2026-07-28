# Legado 开发者指南

> Legado 是一款开源网络文学阅读器，本项目为 Rust + Flutter 双端重构版本。

---

## 项目概述

本项目采用 **Rust 核心引擎 + Flutter 跨平台 UI** 架构，通过 `flutter_rust_bridge` (FFI) 连接两端：

```
┌─────────────────────────────────────────────────────┐
│                   Flutter UI 层                      │
│              (flutter_legado/)                       │
│     18 个页面 · 30 个测试 · 53 个 Dart bindings      │
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

legado-server — 独立 HTTP 服务（axum + 49 REST + 3 WS + MCP）
```

### 核心能力

- **书源规则解析**：CSS / XPath / JsonPath / Regex 四解析器 + AnalyzeRule 统一门面
- **JS 沙箱引擎**：QuickJS 真实实现，40+ 宿主 API，java 命名空间兼容
- **网络引擎**：reqwest + 中间件链（重试/限流/Cookie）+ WebDAV 云同步
- **书籍格式**：EPUB / TXT / MOBI / PDF 解析 + 导出
- **数据库**：SQLite Schema v95 + 17 个 Repository + Room 数据导入
- **HTTP 服务**：axum REST API + WebSocket 实时通道 + MCP Server
- **Flutter UI**：书架 / 阅读器 / 搜索 / 书源管理 / 设置 / RSS 等 18 个页面

---

## 环境配置

### 1. Rust 工具链

```bash
# 安装 rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup install stable
```

> **Windows 注意**：若 `cargo` 命令不可识别，在 PowerShell 中执行：
> ```powershell
> $env:PATH = "C:\Users\<用户名>\.cargo\bin;$env:PATH"
> ```

### 2. Flutter SDK

参考官方文档：https://flutter.dev/docs/get-started/install

要求 Flutter SDK >= 3.11.5：
```bash
flutter --version
```

### 3. flutter_rust_bridge CLI

```bash
cargo install flutter_rust_bridge_codegen --version 2.12.0
```

### 4. C 编译器（QuickJS 需要）

- **Windows**: Visual Studio Build Tools (MSVC)
- **Linux**: `build-essential`
- **macOS**: Xcode Command Line Tools

### 5. 验证环境

```bash
cargo --version
flutter --version
flutter_rust_bridge_codegen --version
```

---

## 目录结构

```
legado/
├── rust/                        # Rust workspace（8 个 crate）
│   ├── legado-core/             # 公共基础层：数据模型、加密、排版、换源、WebBook
│   ├── legado-parser/           # 书源规则解析：CSS/XPath/JsonPath/Regex/AnalyzeUrl
│   ├── legado-net/              # 网络引擎：HTTP/Cookie/RSS/WebDAV/中间件
│   ├── legado-js/               # JS 沙箱：QuickJS + 40+ 宿主 API
│   ├── legado-book/             # 书籍格式：EPUB/TXT/MOBI/PDF 解析与导出
│   ├── legado-db/               # 数据库：SQLite Schema v95 + 17 Repository
│   ├── legado-ffi/              # FFI 出口：flutter_rust_bridge 聚合层
│   ├── legado-server/           # HTTP 服务：axum REST + WS + MCP
│   ├── Cargo.toml               # Workspace 配置
│   ├── DEVELOPMENT.md           # Rust 端详细开发文档
│   └── PROGRESS.md              # 任务进度跟踪
├── flutter_legado/              # Flutter 跨平台 UI
│   ├── lib/                     # Dart 源码
│   ├── test/                    # Flutter 测试（30 个）
│   ├── scripts/                 # 构建/代码生成脚本
│   └── pubspec.yaml             # Flutter 依赖配置
├── app/                         # 原 Android Kotlin 版（历史代码）
├── modules/                     # 原 Android 模块（历史代码）
├── .github/workflows/           # CI/CD 工作流
├── CHANGELOG.md                 # 版本更新日志
└── DEVELOPMENT.md               # 本文件
```

---

## 构建命令

### Rust

```bash
cd rust

# 编译检查（最快）
cargo check --workspace

# Debug 构建
cargo build --workspace

# Release 构建（服务端部署）
cargo build --release -p legado-server

# Android 交叉编译（Windows）
.\scripts\build-android.ps1 -Mode release
```

### Flutter

```bash
cd flutter_legado

# 安装依赖
flutter pub get

# 运行（热重载）
flutter run

# 构建 APK
flutter build apk

# Windows 桌面构建
.\scripts\build-windows.ps1
```

### FFI Bridge 代码生成

Rust API 变更后需重新生成 Dart bindings：

```bash
cd flutter_legado
flutter_rust_bridge_codegen generate
# 或使用脚本
.\scripts\generate-bridge.ps1   # Windows
./scripts/generate-bridge.sh    # Linux/Mac
```

### Makefile 快捷命令

```bash
# 根目录
make run-windows              # 构建并运行 Windows 桌面版
make build-windows            # 仅构建（Debug）
make build-windows-release    # 仅构建（Release）

# flutter_legado 目录
cd flutter_legado
make check    # Rust cargo check + Flutter analyze
make test     # Rust cargo test + Flutter test
make build    # Rust .so + Flutter APK (release)
make gen      # flutter_rust_bridge_codegen generate
```

---

## 测试命令

### Rust 测试

```bash
cd rust

# 全 workspace 测试（默认，不含 QuickJS）
cargo test --workspace

# 含 QuickJS feature 的完整测试
cargo test -p legado-js --features quickjs

# 测试单个 crate
cargo test -p legado-core
cargo test -p legado-parser
cargo test -p legado-net
cargo test -p legado-js
cargo test -p legado-book
cargo test -p legado-db
cargo test -p legado-ffi
cargo test -p legado-server
```

### Flutter 测试

```bash
cd flutter_legado
flutter test
```

### 测试统计

| 组件 | 测试数 | 说明 |
|------|--------|------|
| Rust workspace（默认） | 1225 | 8 个 crate 全量测试 |
| Rust QuickJS feature | 309 | legado-js 含 QuickJS 额外测试 |
| Flutter | 30 | Widget + 单元测试 |
| **总计** | **1564** | |

---

## 质量门禁

所有代码提交前必须通过以下检查（零问题）：

### Rust

```bash
cd rust

# Clippy lint（-D warnings 严格模式）
cargo clippy --workspace --all-targets -- -D warnings

# 格式化检查
cargo fmt --all -- --check

# 格式化修复
cargo fmt --all
```

### Flutter

```bash
cd flutter_legado

# 静态分析
flutter analyze
```

### CI 流水线

GitHub Actions 自动执行以下检查（排除 legado-ffi，因其需要 Flutter 工具链）：

1. `cargo check --workspace --exclude legado-ffi`
2. `cargo clippy --workspace --exclude legado-ffi -- -D warnings`
3. `cargo test --workspace --exclude legado-ffi`
4. `cargo test -p legado-js --features quickjs`
5. `flutter analyze`
6. `flutter test`

---

## 版本与发布

### 当前版本

| 组件 | 版本 | 说明 |
|------|------|------|
| 整体项目 | v4.0.0-alpha | Git tag 格式 |
| Rust crates | 0.2.0 | Workspace 统一版本 |
| Flutter app | 2.0.0+2 | pubspec.yaml |

### Git 提交规范

项目使用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范：

```bash
git commit -m "feat: 新增书源批量导出功能"
git commit -m "fix: 修复阅读器翻页闪烁"
git commit -m "perf: 优化引擎池化内存占用"
```

类型前缀：`feat` / `fix` / `perf` / `refactor` / `docs` / `test` / `chore` / `ci`

### 发布流程

1. 确保所有测试通过 + 质量门禁零问题
2. 更新 `CHANGELOG.md`
3. 递增版本号（Cargo.toml + pubspec.yaml）
4. `git tag -a vX.Y.Z -m "Release vX.Y.Z"`
5. `git push origin main --tags`

---

## 相关链接

- [Rust 端详细开发文档](./rust/DEVELOPMENT.md) — 架构设计、代码结构、调试技巧
- [任务进度跟踪](./rust/PROGRESS.md) — 109 个任务完成状态
- [更新日志](./CHANGELOG.md) — 版本历史记录
- [Flutter 客户端](./flutter_legado/README.md) — UI 层文档
- [上游 Legado 项目](https://github.com/gedoor/legado) — Kotlin 原版
- [本项目仓库](https://github.com/ZhangGHGitHub/LegadoTeamFlutter) — Rust+Flutter 版
