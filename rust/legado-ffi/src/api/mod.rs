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
pub mod cache_download_api;
pub mod config_api;
pub mod cover_api;
pub mod dict_api;
pub mod download_api;
pub mod explore_api;
pub mod explore_info_map;
pub mod highlight_api;
pub mod http_tts_api;
pub mod image_api;
pub mod js_source_config_api;
pub mod log_api;
pub mod net_api;
pub mod pay_action_api;
pub mod pre_update;
pub mod read_record_api;
pub mod reader;
pub mod replace_rule_api;
pub mod review_api;
pub mod rss;
pub mod rss_read_record_api;
pub mod rss_star_api;
pub mod rule_sub_api;
pub mod search;
pub mod search_history_api;
pub mod server_api;
pub mod source;
pub mod source_callback_api;
pub mod source_check_api;
pub mod source_debug_api;
pub mod source_js_bindings;
pub mod source_login_cache;
pub mod source_login_v1_api;
pub mod source_login_v2_api;
pub mod source_rate_limit;
pub mod source_switch;
pub mod tts_speak_api;
pub mod txt_search_api;
pub mod verification_api;
pub mod web_book;
pub mod webdav_api;
pub mod webview_api;

/// [S0-B] 四类离线响应夹具消费测试（仅测试编译；夹具见 tests/fixtures/search_s0/）
#[cfg(test)]
mod s0_fixture_tests;
