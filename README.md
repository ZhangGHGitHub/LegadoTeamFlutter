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
├── flutter_legado/     # Flutter UI 层（18 个页面）
├── app/                # [旧] Android 原生 Kotlin 代码
├── modules/            # [旧] Android 子模块（rhino/web/book）
└── CHANGELOG.md        # 更新日志
```

---

## 快速开始

### 环境要求

- Rust stable（见 `rust/rust-toolchain.toml`）
- Flutter SDK >= 3.11.5
- Android NDK r26+（交叉编译时需要）

### 编译与测试

```bash
# Rust 检查与测试
cd rust
cargo check --workspace
cargo test --workspace

# Flutter
cd flutter_legado
flutter pub get
flutter analyze
flutter test
```

详细开发指南见 [rust/DEVELOPMENT.md](rust/DEVELOPMENT.md)。

---

## 文档

| 文档 | 内容 |
|------|------|
| [rust/README.md](rust/README.md) | Rust 引擎架构与 Crate 说明 |
| [rust/DEVELOPMENT.md](rust/DEVELOPMENT.md) | 开发者快速上手指南（含版本控制与发布流程） |
| [rust/PROGRESS.md](rust/PROGRESS.md) | 迁移进度跟踪 |
| [flutter_legado/README.md](flutter_legado/README.md) | Flutter 客户端文档 |
| [CHANGELOG.md](CHANGELOG.md) | 版本更新日志 |

---

## 版本与发布

- 当前版本：**v4.0.0-alpha**（开发中）
- 版本规范：[语义化版本](https://semver.org/lang/zh-CN/)
- 提交规范：[Conventional Commits](https://www.conventionalcommits.org/zh-hans/)
- 详见 [DEVELOPMENT.md — 版本控制与发布流程](rust/DEVELOPMENT.md#版本控制与发布流程)

---

## 致谢

基于 [gedoor/legado](https://github.com/gedoor/legado) 开源项目。

主要依赖：
- Rust: tokio, reqwest, rquickjs, scraper, sxd-xpath, rusqlite, axum, serde
- Flutter: flutter_rust_bridge, provider, freezed
- Android (旧): jsoup, OkHttp, Cronet, Room, Glide, nanohttpd

---

## 许可证

[GPL-3.0](LICENSE)
[![icon_android](https://github.com/gedoor/gedoor.github.io/blob/master/static/img/legado/icon_android.png)](https://play.google.com/store/apps/details?id=io.legado.play.release)
<a href="https://jb.gg/OpenSourceSupport" target="_blank">
<img width="24" height="24" src="https://resources.jetbrains.com/storage/products/company/brand/logos/jb_beam.svg?_gl=1*135yekd*_ga*OTY4Mjg4NDYzLjE2Mzk0NTE3MzQ.*_ga_9J976DJZ68*MTY2OTE2MzM5Ny4xMy4wLjE2NjkxNjMzOTcuNjAuMC4w&_ga=2.257292110.451256242.1669085120-968288463.1639451734" alt="idea"/>
</a>

<div align="center">
  
Legado
Legado 是一款免费的 Android 平台开源小说阅读器。
</div>

# Grateful-感谢 [![](https://img.shields.io/badge/-Grateful-F5F5F5.svg)](#Grateful-感谢-)
> * org.jsoup:jsoup
> * cn.wanghaomiao:JsoupXpath
> * com.jayway.jsonpath:json-path
> * com.github.gedoor:rhino-android
> * com.squareup.okhttp3:okhttp
> * com.github.bumptech.glide:glide
> * org.nanohttpd:nanohttpd
> * org.nanohttpd:nanohttpd-websocket
> * cn.bingoogolapple:bga-qrcode-zxing
> * com.jaredrummler:colorpicker
> * org.apache.commons:commons-text
> * io.noties.markwon:core
> * io.noties.markwon:image-glide
> * com.hankcs:hanlp
> * com.positiondev.epublib:epublib-core
> * com.github.Moriafly:LyricViewX
> * io.github.rosemoe:editor
