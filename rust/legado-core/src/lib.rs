//! legado-core: 通用类型、错误处理、FFI 桥接宏

pub mod audio;
pub mod audio_cache;
pub mod audio_preload;
pub mod auto_task;
pub mod cache_book;
pub mod content_help;
pub mod content_processor;
pub mod cron;
pub mod crypto;
pub mod debug_session;
pub mod download_manager;
pub mod error;
pub mod ffi_macros;
pub mod layout;
pub mod models;
pub mod passphrase;
pub mod query_ttf;
pub mod read_aloud;
pub mod read_state;
pub mod reading_stats;
pub mod review;
pub mod search_engine;
pub mod source_lock;
pub mod source_login;
pub mod source_matcher;
pub mod toc_updater;
pub mod types;
pub mod web_book;

pub use error::{LegadoError, LegadoResult};
pub use search_engine::{
    MultiSourceSearcher, NoopSourceSearcher, SearchConfig, SearchResult, SourceSearcher,
};
pub use source_matcher::{SourceMatch, SourceMatcher};
