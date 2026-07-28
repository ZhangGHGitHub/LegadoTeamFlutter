//! 业务逻辑 API 模块
//!
//! 各子模块实现具体的业务操作，由 bridge.rs 的 FFI 函数调用。

pub mod audio_api;
pub mod backup_api;
pub mod book_export;
pub mod book_group_api;
pub mod book_import;
pub mod bookmark_api;
pub mod bookshelf;
pub mod cache_api;
pub mod config_api;
pub mod http_tts_api;
pub mod read_record_api;
pub mod reader;
pub mod reading_stats_api;
pub mod replace_rule_api;
pub mod rss;
pub mod rss_star_api;
pub mod search;
pub mod search_history_api;
pub mod server_api;
pub mod source;
pub mod source_switch;
pub mod web_book;
