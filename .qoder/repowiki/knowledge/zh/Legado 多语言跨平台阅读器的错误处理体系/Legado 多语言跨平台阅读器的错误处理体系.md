---
kind: error_handling
name: Legado 多语言跨平台阅读器的错误处理体系
category: error_handling
scope:
    - '**'
source_files:
    - rust/legado-core/src/error.rs
    - rust/legado-ffi/src/error.rs
    - rust/legado-server/src/error.rs
    - rust/legado-net/src/middleware.rs
    - app/src/main/java/io/legado/app/help/CrashHandler.kt
    - app/src/main/java/io/legado/app/exception/NoStackTraceException.kt
    - app/src/main/java/io/legado/app/utils/CoroutineExtensions.kt
---

## 1. 系统/方法概述
Legado 在 Android（Kotlin）、Rust 核心引擎与 Flutter 前端之间采用分层、统一的错误处理策略：
- Rust 层通过 thiserror 定义统一枚举 LegadoError，并映射为整型错误码，作为跨模块、跨 FFI 的通用错误语义。
- FFI 层将 Rust 错误序列化为轻量 JSON 结构 FfiError(code, message)，供 Dart/Flutter 消费。
- HTTP API 层（axum）将 LegadoError 转换为标准 JSON 响应体 { error: { type, code, message } } 并映射到合适的 HTTP 状态码。
- Android 层保留传统 Exception 体系，同时提供全局崩溃捕获 CrashHandler 与协程扩展工具，对可取消异常进行专门处理。

## 2. 关键文件与包
- Rust 核心错误定义：rust/legado-core/src/error.rs
- FFI 错误序列化：rust/legado-ffi/src/error.rs
- HTTP API 错误响应：rust/legado-server/src/error.rs
- 网络中间件（错误分类）：rust/legado-net/src/middleware.rs
- Android 崩溃捕获：app/src/main/java/io/legado/app/help/CrashHandler.kt
- Android 无堆栈异常基类：app/src/main/java/io/legado/app/exception/NoStackTraceException.kt
- 协程超时与取消异常：app/src/main/java/io/legado/app/utils/CoroutineExtensions.kt

## 3. 架构与约定
- 统一错误枚举：LegadoError 以领域划分（Parser、Network、JsEngine、Database、BookParse、Io、Serialization、Ffi、Timeout、Internal），并通过 to_error_code() 映射为稳定 i32 错误码，便于上层按类型分发。
- FFI 边界传递：FfiError 仅包含 code + message，避免跨进程携带复杂对象；From<LegadoError> 保证转换一致性。
- Web API 响应格式：ApiError 实现 IntoResponse，将 LegadoError 映射为 axum::Json 响应，并依据错误类别选择 4xx/5xx 状态码（如 Parser→BAD_REQUEST、Network→BAD_GATEWAY、Timeout→GATEWAY_TIMEOUT、Internal→INTERNAL_SERVER_ERROR）。
- 网络中间件：MiddlewareChain 在执行链中统一将 reqwest 错误分类为 Timeout 或 Network，再包装为 LegadoError，使重试、限流等横切逻辑可复用。
- Android 侧：CrashHandler 作为 Thread.UncaughtExceptionHandler 记录崩溃日志、可选 heap dump 并清理过期文件；NoStackTraceException 用于不需要堆栈的轻量报错；TimeoutCancellationException 区分普通 CancellationException，配合 runCatchingCancellable 避免误吞取消信号。

## 4. 约定与约束
- Rust 层必须使用 LegadoError 及其 Result 别名 LegadoResult<T> 表达失败路径，禁止直接向上抛出 std::io::Error 等原生错误。
- 所有 LegadoError 变体都必须实现 to_error_code() 的稳定映射，新增变体需补充测试覆盖（见 error.rs 中的断言）。
- FFI 层对外暴露的错误必须经 From<LegadoError> 转为 FfiError，确保 code/message 字段一致。
- HTTP API 层 handler 应返回 ApiError(LegadoError) 以便自动映射状态码与 JSON 结构，禁止手动拼装响应体。
- Android 协程代码应优先使用 runCatchingCancellable / withTimeoutAsync / withTimeoutOrNullAsync，显式区分取消与超时，避免 catch(Exception) 吞掉 CancellationException。
- 全局崩溃由 CrashHandler 统一接管，业务代码不应自行设置默认 UncaughtExceptionHandler。
- 需要抑制堆栈打印的场景使用 NoStackTraceException，减少日志体积。