---
kind: logging_system
name: Android 应用日志系统（LogUtils + AppLog + Debug）
category: logging_system
scope:
    - '**'
source_files:
    - app/src/main/java/io/legado/app/utils/LogUtils.kt
    - app/src/main/java/io/legado/app/constant/AppLog.kt
    - app/src/main/java/io/legado/app/model/Debug.kt
    - app/src/main/java/io/legado/app/App.kt
    - modules/book/src/main/resources/log4j.properties
---

## 1. 使用的系统与框架
- Android 原生 `java.util.logging` 作为核心日志后端，通过自定义 `FileHandler` 将日志写入外部缓存目录的文本文件。
- 业务层封装了 `LogUtils`（统一 d/e 输出与文件 handler）、`AppLog`（错误/异常集中收集与内存缓冲）、`Debug`（书源/RSS 解析调试会话）三个组件。
- 部分 UI 组件使用内嵌的私有 `Logger` 对象 + `DebugLog` 工具类进行局部调试输出。
- 第三方库 `log4j` 仅在 `modules/book` 的 epublib 子模块中通过 `log4j.properties` 配置控制台和文件输出，与主应用日志体系相互独立。
- 未引入 Timber、SLF4J、Logback 等通用日志门面或高级框架。

## 2. 关键文件与包
- `app/src/main/java/io/legado/app/utils/LogUtils.kt`：基于 `java.util.logging.Logger` 的轻量封装，负责初始化 FileHandler、按日期命名日志文件、清理过期日志、记录设备信息。
- `app/src/main/java/io/legado/app/constant/AppLog.kt`：集中收集错误与异常，维护最多 100 条内存日志列表，支持可选 Toast 提示，并转发到 LogUtils。
- `app/src/main/java/io/legado/app/model/Debug.kt`：面向书源/RSS 解析的调试子系统，提供会话管理、时间追踪、HTML 格式化输出及回调机制。
- `app/src/main/java/io/legado/app/App.kt`：应用启动时调用 `LogUtils.init(this)`，并通过 `EventLogger` 桥接 LiveEventBus 的日志到 LogUtils。
- `modules/book/src/main/resources/log4j.properties`：epublib 子模块的 log4j 配置，独立于主应用日志。

## 3. 架构与约定
- **分层设计**：
  - 基础设施层：`LogUtils` 封装 `java.util.logging`，提供 `d()` / `e()` 方法与文件输出。
  - 错误聚合层：`AppLog` 统一捕获异常与错误消息，限制内存大小，支持调试模式直接打印堆栈。
  - 业务调试层：`Debug` 为书源/RSS 解析提供结构化调试会话，支持 HTML 输出与时间戳。
  - 组件级调试：各 UI 组件可定义私有 `Logger` 对象，复用 `DebugLog` 工具。
- **日志级别策略**：
  - `LogUtils.d()` 映射到 `Level.INFO`，`LogUtils.e()` 映射到 `Level.WARNING`。
  - 文件输出级别由 `AppConfig.recordLog` 控制，开启时为 INFO，关闭时为 OFF。
- **输出格式**：
  - 文件日志采用 `yyyy-MM-dd HH:mm:ss.SSS: message\n` 格式，按天生成 `appLog-YYYY-MM-DD.txt`。
  - 内存日志以 `Triple<Long, String, Throwable?>` 存储，按时间倒序保留最多 100 条。
- **生命周期集成**：
  - 在 `Application.onCreate()` 中初始化日志系统，确保全局可用。
  - LiveEventBus 的日志通过自定义 `EventLogger` 桥接到 `LogUtils`。

## 4. 约定与约束
- **文件路径约束**：日志文件始终写入 `context.externalCacheDir/logs/` 目录下，文件名包含日期。
- **自动清理规则**：启动时异步清理超过 7 天的日志文件和 `.lck` 临时文件。
- **条件输出**：所有日志输出均受 `BuildConfig.DEBUG` 和 `AppConfig.recordLog` 双重控制。
- **线程安全**：`AppLog` 和 `Debug` 的关键方法使用 `@Synchronized` 保证并发安全。
- **异常处理**：创建 FileHandler 失败时通过 `AppLog.putNotSave()` 记录错误，避免崩溃。
- **第三方库隔离**：epublib 的 log4j 配置独立存在，不影响主应用日志系统。
- **调试会话机制**：`Debug` 组件通过 sessionId 和 withActiveDebugSession 确保调试消息只在活跃会话中输出。