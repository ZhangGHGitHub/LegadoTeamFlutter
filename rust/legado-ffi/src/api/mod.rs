//! 业务逻辑 API 模块
//!
//! 各子模块实现具体的业务操作，由 bridge.rs 的 FFI 函数调用。

pub mod book_export;
pub mod book_import;
pub mod bookshelf;
pub mod reader;
pub mod rss;
pub mod search;
pub mod source;
pub mod source_switch;
pub mod web_book;
