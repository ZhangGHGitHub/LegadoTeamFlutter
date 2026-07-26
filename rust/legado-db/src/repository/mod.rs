//! 数据访问层（Repository 模式）

pub mod auto_task_repository;
pub mod book_chapter_repository;
pub mod book_repository;
pub mod book_source_repository;
pub mod bookmark_repository;
pub mod cache_book_repository;
pub mod reading_stats_repository;
pub mod replace_rule_repository;
pub mod review_repository;

use legado_core::LegadoResult;

/// 通用 Repository trait
pub trait Repository<T> {
    fn find_all(&self) -> LegadoResult<Vec<T>>;
    fn insert(&self, item: &T) -> LegadoResult<()>;
    fn update(&self, item: &T) -> LegadoResult<()>;
    fn delete(&self, id: &str) -> LegadoResult<()>;
}
