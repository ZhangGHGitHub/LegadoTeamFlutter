//! 业务逻辑 API 模块
//!
//! 各子模块实现具体的业务操作，由 bridge.rs 的 FFI 函数调用。

pub mod archive_import_api;
pub mod audio_api;
/// [B1 | 2026-10-04] 音频章节文件缓存只读/清理面（契约 §2.47）
pub mod audio_cache_api;
pub mod auto_task_api;
pub mod backup_api;
pub mod book_export;
pub mod book_group_api;
pub mod book_import;
/// [批7b-1 | 2026-11-09] 书签标记数据层（契约 §2.52，book_marks）
pub mod book_marking_api;
pub mod bookmark_api;
pub mod bookshelf;
pub mod cache_api;
pub mod cache_download_api;
/// [cbz 批 B | 2026-10-03] CBZ 本地漫画页读取（E9 参考版扩展，用户已授权）
pub mod cbz_api;
pub mod config_api;
pub mod cover_api;
pub mod dict_api;
/// [批16a | 2026-10-27] 直链上传（契约 §2.51：上传语义 + 下载链接规则求值）
pub mod direct_link_upload_api;
pub mod download_api;
pub mod explore_api;
pub mod explore_info_map;
pub mod highlight_api;
/// [批11 | 2026-10-26] HTTP 采集开关（契约 §2.10 / legado-net 采集点接线）
pub mod http_log_api;
pub mod http_tts_api;
pub mod image_api;
pub mod image_cache_api;
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
/// [批21a | 2026-10-27] RSS 阅读 WebView `preloadJs` 宿主桥（契约 §2.5）
pub mod rss_web_bridge;
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
/// [V-B1 | 2026-10-05] 视频弹幕数据链（契约 §2.49：查询面 + 抓取链落库 sink）
pub mod video_api;
pub mod web_book;
pub mod webdav_api;
pub mod webview_api;

/// [S0-B] 四类离线响应夹具消费测试（仅测试编译；夹具见 tests/fixtures/search_s0/）
#[cfg(test)]
mod s0_fixture_tests;

/// [回归 2026-09-17] get_chapters_with_vars「已解析目录页」语义（方案 A）
#[cfg(test)]
mod toc_no_rederive_tests;
