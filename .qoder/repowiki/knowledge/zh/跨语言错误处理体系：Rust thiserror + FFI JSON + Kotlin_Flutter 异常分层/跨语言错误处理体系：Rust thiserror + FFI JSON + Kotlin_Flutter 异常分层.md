---
kind: error_handling
name: 跨语言错误处理体系：Rust thiserror + FFI JSON + Kotlin/Flutter 异常分层
category: error_handling
scope:
    - '**'
source_files:
    - rust/legado-core/src/error.rs
    - rust/legado-ffi/src/error.rs
    - rust/legado-server/src/error.rs
    - app/src/main/java/io/legado/app/exception/NoStackTraceException.kt
    - app/src/main/java/io/legado/app/exception/InvalidBooksDirException.kt
    - app/src/main/java/io/legado/app/lib/webdav/WebDavException.kt
    - flutter_legado/lib/src/services/rust_bridge.dart
    - flutter_legado/lib/src/services/rust_api.dart
---

## 1. 系统/方法概述
Legado 在 Android（Kotlin）、Rust 核心与 Flutter 前端之间采用分层错误模型：
- Rust 层使用 `thiserror` 定义统一的 `LegadoError` 枚举，并通过 `to_error_code()` 映射为 i32 错误码。
- FFI 层将 `LegadoError` 序列化为 `FfiError { code, message }` JSON 结构，供 Dart 侧解析。
- Android/Kotlin 层使用自定义 Exception 层次（`NoStackTraceException`、`WebDavException` 等）表达业务异常。
- Flutter 层通过 `rust_bridge.dart` 中的 `LegadoFfiException` 统一包装 FFI 返回的错误码与消息。
- Web API 服务（axum）将 `LegadoError` 转换为 HTTP 状态码与 JSON 响应体。

## 2. 关键文件与包
- Rust 核心错误定义：`rust/legado-core/src/error.rs`
- FFI 错误序列化：`rust/legado-ffi/src/error.rs`
- HTTP API 错误转换：`rust/legado-server/src/error.rs`
- Kotlin 基础异常：`app/src/main/java/io/legado/app/exception/NoStackTraceException.kt`、`InvalidBooksDirException.kt`、`lib/webdav/WebDavException.kt`
- Flutter FFI 桥接异常：`flutter_legado/lib/src/services/rust_bridge.dart`（`LegadoFfiException`）
- Flutter Rust API 封装：`flutter_legado/lib/src/services/rust_api.dart`

## 3. 架构与约定
- **统一错误枚举**：`LegadoError` 覆盖 Parser、Network、JsEngine、Database、BookParse、Io、Serialization、Ffi、Timeout、Internal 十大类，每个变体携带 String 描述。
- **错误码映射**：`to_error_code()` 将枚举映射为 1001~1999 的整型码，贯穿 FFI 与 HTTP 层。
- **FFI 协议**：所有字符串返回值统一 JSON 格式 `{"code": 0, "data": ..., "error": ...}`；非零 code 在 Dart 侧抛出 `LegadoFfiException`。
- **HTTP 响应**：`ApiError` 实现 axum `IntoResponse`，按错误类型映射到对应 `StatusCode` 并返回 `{ error: { type, code, message } }`。
- **Kotlin 异常**：`NoStackTraceException` 禁用堆栈记录以节省内存；业务异常继承该基类或 `Exception`。
- **Flutter 异常**：`LegadoFfiException(code, message)` 作为 FFI 边界唯一异常类型，上层通过 catch 分支处理不同 code。

## 4. 约定与约束
- Rust 侧所有公开 API 必须返回 `Result<T, LegadoError>`，禁止 panic 传播到 FFI。
- FFI 层不得直接暴露 `LegadoError`，仅允许 `FfiError` JSON 序列化后传递。
- Flutter 侧对 FFI 调用统一使用 `_runGuarded` 包裹，捕获任意异常并转为 `LegadoFfiException(-1, ...)`。
- HTTP 服务端 handler 中可直接 `?` 传播 `LegadoError`，由 `From<LegadoError> for ApiError` 自动转换。
- Kotlin 业务异常优先继承 `NoStackTraceException` 以减少日志开销，仅在需要调试时保留堆栈。
- 错误码分配遵循分类区间：1001~1009 为具体错误类型，1999 为内部错误，Dart 侧据此决定用户提示策略。