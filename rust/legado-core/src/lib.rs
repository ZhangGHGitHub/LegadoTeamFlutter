//! legado-core: 公共基础层
//!
//! 提供 Legado Rust 引擎的所有 crate 共享的基础设施：
//!
//! - [`models`] — 核心数据模型（Book, BookSource, BookChapter, RssSource 等）
//! - [`error`] — 统一错误类型 [`LegadoError`] 和 [`LegadoResult`]
//! - [`crypto`] — 加密工具（AES/DES/Base64/MD5）
//! - [`search_engine`] — 多源并行搜索引擎框架
//! - [`web_book`] — 网络书籍访问层（搜索→详情→目录→正文）
//! - [`content_processor`] — 内容净化与替换规则处理
//! - [`layout`] — 文本排版引擎（分页/分行）
//! - [`types`] — 通用类型定义（PageInfo, FfiString）
//!
//! # Examples
//!
//! ```rust
//! use legado_core::{LegadoError, LegadoResult};
//!
//! fn parse_source(json: &str) -> LegadoResult<serde_json::Value> {
//!     serde_json::from_str(json).map_err(|e| LegadoError::Parser(e.to_string()))
//! }
//! ```

pub mod audio;
pub mod audio_cache;
pub mod audio_preload;
pub mod audio_skip_policy;
pub mod auto_task;
pub mod cache_book;
pub mod chinese_convert;
pub mod content_help;
pub mod content_processor;
pub mod cron;
pub mod crypto;
pub mod debug_session;
pub mod download_manager;
pub mod error;
pub mod explore;
pub mod ffi_macros;
pub mod html_formatter;
pub mod layout;
pub mod manga_state;
pub mod models;
pub mod passphrase;
pub mod query_ttf;
pub mod read_aloud;
pub mod read_state;
pub mod reader_state;
pub mod reading_stats;
pub mod review;
pub mod search_engine;
pub mod source_lock;
pub mod source_login;
pub mod source_matcher;
pub mod toc_updater;
pub mod types;
pub mod video_state;
pub mod web_book;

pub use error::{LegadoError, LegadoResult};
pub use search_engine::{
    MultiSourceSearcher, NoopSourceSearcher, SearchConfig, SearchResult, SourceSearcher,
};
pub use source_matcher::{SourceMatch, SourceMatcher};
