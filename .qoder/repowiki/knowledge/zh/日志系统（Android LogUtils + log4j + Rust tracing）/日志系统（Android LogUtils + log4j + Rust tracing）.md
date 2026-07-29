---
kind: logging_system
name: 日志系统（Android LogUtils + log4j + Rust tracing）
category: logging_system
scope:
    - '**'
source_files:
    - app/src/main/java/io/legado/app/utils/LogUtils.kt
    - app/src/main/java/io/legado/app/App.kt
    - app/src/main/java/io/legado/app/constant/AppLog.kt
    - modules/book/src/main/resources/log4j.properties
    - rust/legado-server/Cargo.toml
    - rust/legado-server/src/server.rs
---

## 1. 使用的系统与框架
- Android 端：基于 `java.util.logging`（JUL）封装的 `LogUtils`，配合自定义 `AsyncFileHandler` 输出到外部缓存目录的文件；同时通过 `AppConfig.recordLog` 开关控制是否写入文件。
- 第三方库（epublib/umdlib）：使用 `log4j`，通过 `modules/book/src/main/resources/log4j.properties` 配置控制台、每日滚动文件与 HTML 三种 Appender。
- Rust 服务端（legado-server）：使用 `tracing` + `tracing-subscriber` 进行结构化日志记录，并通过 WebSocket 将调试日志推送给前端。
- Flutter/Dart 层：未发现统一的日志框架，主要依赖平台侧日志。

## 2. 核心文件与位置
- Android 统一日志入口：`app/src/main/java/io/legado/app/utils/LogUtils.kt`
- Android 应用初始化与日志开关：`app/src/main/java/io/legado/app/App.kt`（调用 `LogUtils.init`、设置 LiveEventBus 的 `EventLogger`）
- Android 错误收集与内存日志：`app/src/main/java/io/legado/app/constant/AppLog.kt`
- 第三方库日志配置：`modules/book/src/main/resources/log4j.properties`（默认 rootCategory=INFO，输出到 console + logs/epublib.log + logs/epublib_log.html）
- Rust 服务日志：`rust/legado-server/Cargo.toml`（声明 `tracing` 与 `tracing-subscriber`），`rust/legado-server/src/server.rs`（`tracing::info!` 示例）

## 3. 架构与约定
- **统一入口**：所有 Android 业务代码通过 `LogUtils.d/e(tag, msg)` 或 `AppLog.put(...)` 输出，避免直接调用 `android.util.Log`。
- **文件输出策略**：`LogUtils.createFileHandler` 在 `context.externalCacheDir/logs` 下按日期生成 `appLog-yy-MM-dd_HH-mm-ss.txt`，并异步清理超过 7 天的旧日志；是否启用由 `AppConfig.recordLog` 决定，未开启时 `Level.OFF`。
- **级别约定**：`d()` 映射为 `Level.INFO`，`e()` 映射为 `Level.WARNING`；未提供 debug 级别方法，实际通过 `BuildConfig.DEBUG` 与 `AppConfig.recordLog` 双重控制。
- **事件总线日志**：`App.EventLogger` 继承 `DefaultLogger`，将 LiveEventBus 的事件日志转发到 `LogUtils.d("[LiveEventBus]", ...)`。
- **第三方库隔离**：epublib 等独立模块通过自身 `log4j.properties` 输出到 `logs/epublib.*`，与主应用日志分离。
- **Rust 侧**：仅 `legado-server` 使用 `tracing`，其他 crate 未见统一日志宏，调试信息多通过返回值或 WebSocket 消息传递。

## 4. 约束与规则
- 日志文件路径固定为 `externalCacheDir/logs/appLog-<date>.txt`，且自动清理 7 天前文件（见 `LogUtils.createFileHandler` 中的过期判断逻辑）。
- 是否写入文件严格受 `AppConfig.recordLog` 控制：`upLevel()` 会动态切换 FileHandler 的 level 为 `INFO` 或 `OFF`。
- `AppLog` 内部维护最多 100 条最近日志的内存队列，`putNotSave` 不持久化但保留在内存中，便于调试界面查看。
- log4j 根级别默认为 `INFO`，ConsoleAppender 与 DailyRollingFileAppender 均使用 PatternLayout，HTML 格式日志限制单文件 100KB。
- Rust 服务端仅在 `Cargo.toml` 中声明 `tracing` 与 `tracing-subscriber` 依赖，当前代码中仅 `server.rs` 有 `tracing::info!` 调用，尚未发现全局初始化（如 `env_logger` 或 `tracing_subscriber::fmt::init`）。

## 5. 关键文件清单
- `app/src/main/java/io/legado/app/utils/LogUtils.kt`
- `app/src/main/java/io/legado/app/App.kt`
- `app/src/main/java/io/legado/app/constant/AppLog.kt`
- `modules/book/src/main/resources/log4j.properties`
- `rust/legado-server/Cargo.toml`
- `rust/legado-server/src/server.rs`