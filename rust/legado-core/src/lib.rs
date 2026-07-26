//! legado-core: 通用类型、错误处理、FFI 桥接宏

pub mod audio;
pub mod audio_preload;
pub mod cache_book;
pub mod crypto;
pub mod error;
pub mod ffi_macros;
pub mod layout;
pub mod models;
pub mod read_state;
pub mod reading_stats;
pub mod review;
pub mod search_engine;
pub mod source_login;
pub mod source_matcher;
pub mod types;
pub mod web_book;

pub use error::{LegadoError, LegadoResult};
pub use search_engine::{
    MultiSourceSearcher, NoopSourceSearcher, SearchConfig, SearchResult, SourceSearcher,
};
pub use source_matcher::{SourceMatch, SourceMatcher};
