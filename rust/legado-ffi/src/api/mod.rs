//! 业务逻辑 API 模块
//!
//! 各子模块实现具体的业务操作，由 bridge.rs 的 FFI 函数调用。

pub mod archive_import_api;
pub mod audio_api;
pub mod auto_task_api;
pub mod backup_api;
pub mod book_export;
pub mod book_group_api;
pub mod book_import;
pub mod bookmark_api;
pub mod bookshelf;
pub mod cache_api;
pub mod config_api;
pub mod dict_api;
pub mod download_api;
pub mod explore_api;
pub mod highlight_api;
pub mod http_tts_api;
pub mod js_source_config_api;
pub mod quic_api;
pub mod read_record_api;
pub mod reader;
pub mod reading_stats_api;
pub mod replace_rule_api;
pub mod review_api;
pub mod rss;
pub mod rss_read_record_api;
pub mod rss_star_api;
pub mod search;
pub mod search_history_api;
pub mod server_api;
pub mod source;
pub mod source_switch;
pub mod txt_search_api;
pub mod user_api;
pub mod web_book;
pub mod webdav_api;
