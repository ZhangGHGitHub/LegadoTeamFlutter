# Legado — Rust + Flutter 跨平台阅读器

[![Rust CI](https://github.com/ZhangGHGitHub/LegadoTeamFlutter/actions/workflows/rust-ci.yml/badge.svg)](https://github.com/ZhangGHGitHub/LegadoTeamFlutter/actions/workflows/rust-ci.yml)
[![Flutter CI](https://github.com/ZhangGHGitHub/LegadoTeamFlutter/actions/workflows/flutter-ci.yml/badge.svg)](https://github.com/ZhangGHGitHub/LegadoTeamFlutter/actions/workflows/flutter-ci.yml)

Legado（阅读）是一款免费开源的小说阅读器，正在从 Android 原生 Kotlin 架构迁移为 **Rust 核心引擎 + Flutter UI** 的跨平台架构。

---

## 项目结构

```
├── rust/               # Rust 核心引擎（8 个 crate）
│   ├── legado-core/    # 公共基础层（数据模型、错误、加密、排版）
│   ├── legado-parser/  # 书源规则解析（CSS/XPath/JsonPath/Regex）
│   ├── legado-net/     # HTTP 网络引擎（reqwest + 中间件）
│   ├── legado-js/      # JavaScript 沙箱（QuickJS）
│   ├── legado-book/    # 书籍格式解析（EPUB/TXT/MOBI/PDF）
│   ├── legado-db/      # SQLite 数据库（rusqlite）
│   ├── legado-ffi/     # FFI 出口（flutter_rust_bridge）
│   └── legado-server/  # HTTP 服务（axum）
├── flutter_legado/     # Flutter UI 层（62 个 Screen 页面）
├── app/                # [旧] Android 原生 Kotlin 代码
├── modules/            # [旧] Android 子模块（rhino/web/book）
└── CHANGELOG.md        # 更新日志
```

---

## 快速开始

### 环境要求

- Rust stable（见 `rust/rust-toolchain.toml`）
- Flutter SDK >= 3.8.0
- Android NDK r26+（交叉编译时需要）

### 编译与测试

```powershell
# Rust 检查与测试
cd rust
cargo test -p legado-ffi --features quickjs

# Flutter
cd flutter_legado
flutter pub get
flutter analyze
flutter test
```

详细开发指南见 [rust/DEVELOPMENT.md](rust/DEVELOPMENT.md) 与 [AGENTS.md](AGENTS.md)。

---

## 文档

| 文档 | 内容 |
|------|------|
| [AGENTS.md](AGENTS.md) | Agent 工作入口与验证命令 |
| [rust/README.md](rust/README.md) | Rust 引擎架构与 Crate 说明 |
| [docs/API_CONTRACT.md](docs/API_CONTRACT.md) | FFI / BookApi 契约 |
| [docs/AUDIT_FIX_TASKS_20260814.md](docs/AUDIT_FIX_TASKS_20260814.md) | 审计修复任务清单 |
| [CHANGELOG.md](CHANGELOG.md) | 版本更新日志 |

---

## 版本与发布

- 当前版本：**2.0.60+62**（Flutter `pubspec.yaml`）
- 功能基准：Android 原版 `com.legado.app.release` 3.26081008
- 版本规范：[语义化版本](https://semver.org/lang/zh-CN/)
- 提交规范：中文说明 + `[Rust]` / `[UI]` / `[docs]` 前缀

---

## 致谢

基于 [gedoor/legado](https://github.com/gedoor/legado) 开源项目。
