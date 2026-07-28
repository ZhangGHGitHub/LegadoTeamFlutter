//! legado-ffi: 统一的 Dart FFI 绑定层
//!
//! 本 crate 聚合所有 legado-* crate，生成 cdylib/staticlib 供 Flutter/Dart 调用。
//!
//! - `ffi` 模块：flutter_rust_bridge 桥接定义（由 codegen 自动生成 Dart bindings）
//! - `bridge` 模块：旧式 C ABI 导出函数（向后兼容）

// flutter_rust_bridge 宏生成的 cfg 和 unsafe fn 产生不可避免的 clippy 警告
#![allow(unexpected_cfgs)]
#![allow(clippy::missing_safety_doc)]

// AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs.
mod frb_generated;

pub mod api;
pub mod bridge;
pub mod db_state;
pub mod error;
pub mod ffi;
pub mod runtime;

// 重新导出各业务 crate，便于外部（如 codegen）统一访问
pub use legado_book;
pub use legado_core;
pub use legado_db;
pub use legado_js;
pub use legado_net;
pub use legado_parser;
pub use legado_server;
