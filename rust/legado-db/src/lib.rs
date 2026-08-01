//! legado-db: 数据库层（基于 rusqlite）
//!
//! 提供完整的 SQLite 数据库访问能力，包括：
//!
//! - [`connection`] — 连接管理与 PRAGMA 配置（含自动迁移）
//! - [`schema`] — 全量表结构 DDL（v95，25 张表）
//! - [`repository`] — Repository 模式的数据访问层（25 个 Repository）
//! - [`migration`] — 基于版本号的增量迁移框架（MigrationRegistry）
//! - [`import`] — Room JSON 数据导入工具
//! - [`default_data`] — 默认数据导入（JSON 格式）
//!
//! # Examples
//!
//! ```rust
//! use legado_db::init_in_memory_database;
//!
//! // 初始化内存数据库（用于测试）
//! let db = init_in_memory_database().unwrap();
//! let conn = db.connection();
//!
//! // 执行查询
//! let count: i64 = conn
//!     .query_row("SELECT COUNT(*) FROM books", [], |row| row.get(0))
//!     .unwrap_or(0);
//! assert_eq!(count, 0);
//! ```

pub mod connection;
pub mod default_data;
pub mod import;
pub mod migration;
pub mod repository;
pub mod rule_big_data;
pub mod schema;

pub use connection::Database;
pub use import::RoomImporter;
pub use migration::MigrationRegistry;
pub use repository::auto_task_repository::AutoTaskRepository;
pub use repository::book_chapter_repository::BookChapterRepository;
pub use repository::book_group_repository::{BookGroup, BookGroupRepository};
pub use repository::book_repository::BookRepository;
pub use repository::book_source_repository::BookSourceRepository;
pub use repository::bookmark_repository::BookmarkRepository;
pub use repository::cache_book_repository::CacheBookRepository;
pub use repository::cache_repository::CacheRepository;
pub use repository::cookie_repository::CookieRepository;
pub use repository::dict_rule_repository::{DictRule, DictRuleRepository};
pub use repository::http_tts_repository::{HttpTts, HttpTtsRepository};
pub use repository::keyboard_assist_repository::{KeyboardAssist, KeyboardAssistRepository};
pub use repository::read_record_repository::{ReadRecord, ReadRecordRepository};
pub use repository::reading_stats_repository::ReadingStatsRepository;
pub use repository::replace_rule_repository::ReplaceRuleRepository;
pub use repository::review_repository::ReviewRepository;
pub use repository::rss_article_repository::{RssArticleRecord, RssArticleRepository};
pub use repository::rss_read_record_repository::{RssReadRecordRepository, RssReadRecordRow};
pub use repository::rss_source_repository::RssSourceRepository;
pub use repository::rss_star_repository::{RssStarRecord, RssStarRepository};
pub use repository::rule_sub_repository::{RuleSubRecord, RuleSubRepository};
pub use repository::search_book_repository::SearchBookRepository;
pub use repository::search_keyword_repository::SearchKeywordRepository;
pub use repository::txt_toc_rule_repository::{TxtTocRuleRecord, TxtTocRuleRepository};
pub use repository::user_repository::{UserRecord, UserRepository};
pub use schema::SCHEMA_VERSION;

use legado_core::LegadoResult;

/// 初始化数据库：打开连接 → 自动迁移 → 返回 Database 实例
///
/// 注意：Database::open 已内置自动迁移，此函数为向后兼容保留。
pub fn init_database(path: &str) -> LegadoResult<Database> {
    Database::open(path)
}

/// 初始化内存数据库（用于测试）
pub fn init_in_memory_database() -> LegadoResult<Database> {
    Database::open_in_memory()
}
