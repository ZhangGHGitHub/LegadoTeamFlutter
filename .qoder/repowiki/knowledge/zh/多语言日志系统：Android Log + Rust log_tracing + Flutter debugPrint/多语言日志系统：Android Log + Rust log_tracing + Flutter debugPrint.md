---
kind: logging_system
name: 多语言日志系统：Android Log + Rust log/tracing + Flutter debugPrint
category: logging_system
scope:
    - '**'
source_files:
    - app/src/main/java/io/legado/app/utils/LogUtils.kt
    - app/src/main/java/io/legado/app/constant/AppLog.kt
    - app/src/main/java/io/legado/app/utils/DebugLog.kt
    - app/src/main/java/io/legado/app/model/Debug.kt
    - rust/legado-net/Cargo.toml
    - rust/legado-server/Cargo.toml
    - rust/legado-net/src/proxy.rs
    - rust/legado-net/src/retry.rs
    - rust/legado-net/src/ssl_config.rs
    - rust/legado-net/src/webdav.rs
    - rust/legado-server/src/server.rs
    - flutter_legado/lib/main.dart
    - modules/book/src/main/resources/log4j.properties
---

## 1. 使用的系统与框架

Legado 阅读器采用**多语言、多模块**的日志方案，各语言层使用各自生态的标准/轻量级日志库：
- **Android (Kotlin)**：`android.util.Log` + 自研 `LogUtils`（基于 `java.util.logging`）+ `DebugLog`（BuildConfig.DEBUG 开关）
- **Rust 核心**：`log` crate（0.4）与 `tracing` crate（0.1）并存，由 `legado-server` 通过 `tracing-subscriber` 初始化
- **Flutter/Dart**：`debugPrint` / `debugPrintStack` 作为开发期输出
- **第三方库**：`modules/book` 中的 epublib 使用 `log4j.properties` 配置控制台与文件输出

## 2. 关键文件与位置

| 层级 | 关键文件 | 作用 |
|------|----------|------|
| Android | `app/src/main/java/io/legado/app/utils/LogUtils.kt` | 统一日志门面，写入外部缓存 `logs/appLog-日期.txt`，按 `AppConfig.recordLog` 控制级别 |
| Android | `app/src/main/java/io/legado/app/constant/AppLog.kt` | 内存中保留最近 100 条日志，支持可选 toast 提示 |
| Android | `app/src/main/java/io/legado/app/utils/DebugLog.kt` | DEBUG 构建下包装 `android.util.Log` 的 e/d/i/w 方法 |
| Android | `app/src/main/java/io/legado/app/model/Debug.kt` | 书源/RSS 解析调试会话，带时间戳与状态码 |
| Rust | `rust/legado-net/Cargo.toml` | 依赖 `log = "0.4"`，使用 `log::debug!` / `log::warn!` / `log::info!` |
| Rust | `rust/legado-server/Cargo.toml` | 依赖 `tracing = "0.1"` + `tracing-subscriber = "0.3"`，server.rs 中 `tracing::info!` |
| Rust | `rust/legado-core/src/download_manager.rs` 等 | 使用 `println!` / `eprintln!` 做临时调试输出 |
| Flutter | `flutter_legado/lib/main.dart` | `debugPrint` 打印 FFI 初始化错误 |
| 第三方 | `modules/book/src/main/resources/log4j.properties` | log4j 根级别 INFO，ConsoleAppender + DailyRollingFileAppender |

## 3. 架构与约定

- **Android 层**：所有业务代码通过 `LogUtils.d(tag, msg)` 或 `DebugLog.e/tag/msg` 输出；`AppLog` 提供内存环形缓冲（最多 100 条），便于 UI 展示历史日志。
- **日志级别策略**：
  - `LogUtils` 默认以 `Level.INFO` 写入文件，受 `AppConfig.recordLog` 开关控制（可动态 `upLevel()` 切换 OFF/INFO）。
  - `DebugLog` 仅在 `BuildConfig.DEBUG` 时生效，避免 release 包产生开销。
  - `AppLog.putNotSave` 仅入内存不入持久化文件。
- **Rust 层**：`legado-net` 使用 `log` crate 的 `debug!/warn!/info!` 宏；`legado-server` 使用 `tracing` 生态。两者未统一，存在混用。
- **Flutter 层**：仅使用 `debugPrint`，无结构化日志或级别管理。
- **第三方库隔离**：epublib 的 log4j 独立于应用日志，输出到 `logs/epublib.log`。

## 4. 约定与约束

- **Android 日志必须经 `LogUtils`/`DebugLog`/`AppLog` 三件套**，禁止直接调用 `android.util.Log`（部分遗留代码仍直接调用，但新代码应遵循此约定）。
- **文件日志路径固定**：`context.externalCacheDir/logs/appLog-YYYY-MM-dd_HH-mm-ss.txt`，超过 7 天的文件自动清理。
- **调试开关**：`AppConfig.recordLog` 控制是否写文件；`BuildConfig.DEBUG` 控制 `DebugLog` 是否输出。
- **Rust 日志未统一初始化**：`legado-net` 的 `log` crate 与 `legado-server` 的 `tracing` 各自为政，没有全局 `env_logger`/`tracing-subscriber` 初始化入口，导致非 server 模块的日志可能丢失。
- **临时调试输出**：多处 Rust/Kotlin 代码仍使用 `println!`/`println`，属于开发期调试痕迹，不应出现在生产逻辑中。

## 5. 现状评估

该仓库的日志系统处于**分散且未完全统一**的状态：Android 侧有较完善的门面封装，Rust 侧 log 与 tracing 混用且缺少全局初始化，Flutter 侧仅依赖 `debugPrint`。整体缺乏跨语言的统一日志格式、集中式收集与分级导出能力。