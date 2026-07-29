---
kind: error_handling
name: 跨语言统一错误体系：Rust thiserror + FFI 错误码 + HTTP API 错误映射
category: error_handling
scope:
    - '**'
source_files:
    - rust/legado-core/src/error.rs
    - rust/legado-ffi/src/error.rs
    - rust/legado-server/src/error.rs
    - rust/legado-core/src/lib.rs
    - rust/legado-ffi/src/bridge.rs
    - rust/legado-ffi/src/ffi.rs
---

## 1. 系统/方案概述
Legado 在 Rust 核心层采用 `thiserror` 定义统一的 `LegadoError` 枚举，并通过 `to_error_code()` 将每种错误映射为稳定的 i32 错误码；FFI 层通过可序列化的 `FfiError`（code + message）把错误传递给 Dart/Flutter；HTTP 服务层通过 `ApiError` 实现 axum 的 `IntoResponse`，将 `LegadoError` 自动转换为标准 JSON 响应体 `{ error: { type, code, message } }`。Android/Kotlin 侧未发现集中式异常类型定义，错误处理主要依赖各模块自行抛出或桥接 FFI 返回的错误码。

## 2. 关键文件与包
- `rust/legado-core/src/error.rs`：全局 `LegadoError` 枚举、`LegadoResult<T>` 别名、`to_error_code()` 错误码映射
- `rust/legado-ffi/src/error.rs`：`FfiError` 结构体及 `From<LegadoError>` / `From<serde_json::Error>` 转换
- `rust/legado-server/src/error.rs`：`ApiError` 包装器，实现 `IntoResponse`，完成 LegadoError → HTTP 状态码与 JSON 体的映射
- `rust/legado-core/src/lib.rs`：重新导出 `pub use error::{LegadoError, LegadoResult}`
- `rust/legado-ffi/src/bridge.rs`、`rust/legado-ffi/src/ffi.rs`：FFI 调用处使用 `LegadoError` 并转为 `FfiError`
- `rust/legado-server/src/handlers/*.rs`：各 handler 直接 `use crate::error::ApiError`，通过 `?` 传播错误

## 3. 架构与约定
- **单一错误源**：所有领域错误收敛到 `legado_core::LegadoError`，避免各 crate 各自定义错误类型
- **稳定错误码**：每个变体固定映射到 i32（如 Parser=1001、Network=1002、JsEngine=1003、Database=1004、BookParse=1005、Io=1006、Serialization=1007、Ffi=1008、Timeout=1009、Internal=1999），由单元测试保证一致性
- **FFI 边界序列化**：`FfiError` 仅包含 `code` 和 `message`，便于 Dart 端解析与展示
- **HTTP 层语义化**：`ApiError::into_response` 将不同 `LegadoError` 映射为合适的 HTTP 状态码（BAD_REQUEST、BAD_GATEWAY、INTERNAL_SERVER_ERROR、GATEWAY_TIMEOUT 等），并附带 `type` 字符串用于前端分类处理
- **无 panic 策略**：错误通过 `Result` 向上冒泡，未观察到 `panic!` 作为错误路径的使用

## 4. 约定与约束
- 所有 Rust crate 必须通过 `LegadoError` 表达业务错误，禁止在各层散落自定义错误类型
- 新增错误变体时必须同时更新 `to_error_code()` 映射与对应测试断言
- FFI 暴露给 Dart 的错误信息不得包含敏感堆栈，仅保留 `code` 与 `message` 字段
- HTTP handler 中应直接使用 `?` 将 `LegadoError` 传播至 `ApiError`，由框架统一序列化响应
- Android/Kotlin 侧若需与 Rust 交互，应遵循 FFI 返回的错误码进行判断，而非直接传递异常对象