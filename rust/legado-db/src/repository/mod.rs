//! 数据访问层（Repository 模式）

pub mod auto_task_repository;
pub mod book_chapter_repository;
pub mod book_repository;
pub mod book_source_repository;
pub mod bookmark_repository;
pub mod cache_book_repository;
pub mod cache_repository;
pub mod cookie_repository;
pub mod reading_stats_repository;
pub mod replace_rule_repository;
pub mod review_repository;
pub mod rss_article_repository;
pub mod rss_read_record_repository;
pub mod rss_star_repository;
pub mod rule_sub_repository;
pub mod search_keyword_repository;
pub mod txt_toc_rule_repository;

use legado_core::LegadoResult;

/// 通用 Repository trait
pub trait Repository<T> {
    fn find_all(&self) -> LegadoResult<Vec<T>>;
    fn insert(&self, item: &T) -> LegadoResult<()>;
    fn update(&self, item: &T) -> LegadoResult<()>;
    fn delete(&self, id: &str) -> LegadoResult<()>;
}
