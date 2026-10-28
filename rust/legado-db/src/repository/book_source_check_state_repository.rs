//! BookSourceCheckState Repository — `book_source_check_states` 表读写
//!
//! 对齐原版 `BookSourceDao` 的检验状态方法（upstream
//! `app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt:280-343`）：
//!
//! | 原版方法 | 本实现 |
//! |---|---|
//! | `saveCheckStates(vararg)` | [`BookSourceCheckStateRepository::save`] / [`save_all`] |
//! | `allCheckStates()` | [`find_all`] |
//! | `getCheckState(url)` | [`find_by_url`] |
//! | `beginCheck(sources)`（事务） | [`begin_check`] |
//! | `finishCheck(url, revision, status, detail, checkedAt)` | [`finish_check`] |
//! | 源删除级联 | 由 DDL 外键 `ON DELETE CASCADE` 保证（无需代码） |
//!
//! `finish_check` 的 CAS 条件与原版逐字一致：
//! `where bookSourceUrl = :url and revision = :revision and status = 'NEEDS_CHECK'`，
//! 保证「旧任务/被停止任务/已被保存重置」的结果不会覆盖新状态。
//!
//! [`save_all`]: BookSourceCheckStateRepository::save_all
//! [`find_all`]: BookSourceCheckStateRepository::find_all
//! [`find_by_url`]: BookSourceCheckStateRepository::find_by_url
//! [`begin_check`]: BookSourceCheckStateRepository::begin_check
//! [`finish_check`]: BookSourceCheckStateRepository::finish_check

use rusqlite::{params, params_from_iter, Connection};

use legado_core::models::book_source_check_state::check_status;
use legado_core::models::BookSourceCheckState;
use legado_core::{LegadoError, LegadoResult};

/// 单次 `IN (...)` 查询的 URL 数量上限
///
/// 对齐原版 `BOOK_SOURCE_QUERY_CHUNK_SIZE = 900`（`BookSourcePart.kt:9`）：
/// SQLite 默认主机参数上限 999，留足余量；由调用方负责分块。
pub const BOOK_SOURCE_QUERY_CHUNK_SIZE: usize = 900;

/// 书源检验状态数据访问层
pub struct BookSourceCheckStateRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookSourceCheckStateRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 按书源地址查询状态
    pub fn find_by_url(&self, url: &str) -> LegadoResult<Option<BookSourceCheckState>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookSourceUrl, revision, sourceRevision, status, checkedAt, detail
                 FROM book_source_check_states WHERE bookSourceUrl = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询检验状态失败: {e}")))?;
        let mut rows = stmt
            .query_map(params![url], row_to_state)
            .map_err(|e| LegadoError::Database(format!("查询检验状态失败: {e}")))?;
        match rows.next() {
            Some(Ok(state)) => Ok(Some(state)),
            Some(Err(e)) => Err(LegadoError::Database(format!("检验状态行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 全部检验状态（按书源地址排序，保证响应稳定）
    pub fn find_all(&self) -> LegadoResult<Vec<BookSourceCheckState>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookSourceUrl, revision, sourceRevision, status, checkedAt, detail
                 FROM book_source_check_states ORDER BY bookSourceUrl ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询检验状态失败: {e}")))?;
        let states = stmt
            .query_map([], row_to_state)
            .map_err(|e| LegadoError::Database(format!("查询检验状态失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(states)
    }

    /// 按书源地址批量查询（`IN (...)`，调用方需先按
    /// [`BOOK_SOURCE_QUERY_CHUNK_SIZE`] 分块）
    pub fn find_by_urls(&self, urls: &[String]) -> LegadoResult<Vec<BookSourceCheckState>> {
        if urls.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = std::iter::repeat_n("?", urls.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT bookSourceUrl, revision, sourceRevision, status, checkedAt, detail
             FROM book_source_check_states WHERE bookSourceUrl IN ({placeholders})
             ORDER BY bookSourceUrl ASC"
        );
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| LegadoError::Database(format!("准备批量查询检验状态失败: {e}")))?;
        let states = stmt
            .query_map(params_from_iter(urls.iter()), row_to_state)
            .map_err(|e| LegadoError::Database(format!("批量查询检验状态失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(states)
    }

    /// 写入（INSERT OR REPLACE）单条状态
    pub fn save(&self, state: &BookSourceCheckState) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO book_source_check_states
                    (bookSourceUrl, revision, sourceRevision, status, checkedAt, detail)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    state.book_source_url,
                    state.revision,
                    state.source_revision,
                    state.status,
                    state.checked_at,
                    state.detail,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("写入检验状态失败: {e}")))?;
        Ok(())
    }

    /// 批量写入（单事务）
    pub fn save_all(&self, states: &[BookSourceCheckState]) -> LegadoResult<()> {
        if states.is_empty() {
            return Ok(());
        }
        crate::connection::in_transaction(self.conn, "批量写入书源检验状态", |conn| {
            let repo = BookSourceCheckStateRepository::new(conn);
            for state in states {
                repo.save(state)?;
            }
            Ok(())
        })
    }

    /// 删除单条状态（源删除通常由外键级联处理，本方法供显式清理）
    pub fn delete(&self, url: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "DELETE FROM book_source_check_states WHERE bookSourceUrl = ?1",
                params![url],
            )
            .map_err(|e| LegadoError::Database(format!("删除检验状态失败: {e}")))?;
        Ok(())
    }

    /// 检验开始前重置状态（对齐原版 `BookSourceDao.beginCheck` 的单条语义）
    ///
    /// 条件：库内源存在，且 `lastUpdateTime` 与状态 `revision` 均与调用方快照
    /// 一致（源或状态已被并发修改时放弃重置）。命中时写入并返回
    /// `Ok(Some(新状态))`；快照过期或源不存在返回 `Ok(None)`，调用方不应把
    /// 本次检验结果写回。
    ///
    /// 状态行缺失时按 `coalesce` 默认值处理（revision/sourceRevision 为空串），
    /// 与原版 `book_sources_part` 视图左联的默认值一致。
    pub fn begin_check(
        &self,
        url: &str,
        expected_last_update_time: i64,
        expected_revision: &str,
    ) -> LegadoResult<Option<BookSourceCheckState>> {
        let current: Option<(i64, Option<String>, Option<String>)> = match self.conn.query_row(
            "SELECT b.lastUpdateTime, c.revision, c.sourceRevision
             FROM book_sources b
             LEFT JOIN book_source_check_states c ON b.bookSourceUrl = c.bookSourceUrl
             WHERE b.bookSourceUrl = ?1",
            params![url],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ) {
            Ok(row) => Some(row),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => return Err(LegadoError::Database(format!("查询书源检验快照失败: {e}"))),
        };
        let Some((last_update_time, revision, source_revision)) = current else {
            return Ok(None);
        };
        if last_update_time != expected_last_update_time
            || revision.unwrap_or_default() != expected_revision
        {
            return Ok(None);
        }
        let queued = BookSourceCheckState {
            book_source_url: url.to_string(),
            revision: uuid::Uuid::new_v4().to_string(),
            source_revision: source_revision.unwrap_or_default(),
            status: check_status::NEEDS_CHECK.to_string(),
            checked_at: 0,
            detail: String::new(),
        };
        self.save(&queued)?;
        Ok(Some(queued))
    }

    /// 检验结果写回（对齐原版 `finishCheck` 的 CAS）
    ///
    /// 仅当 `(url, revision)` 命中且状态仍为 `NEEDS_CHECK` 时更新，返回是否
    /// 实际写入。`detail` 由调用方按原版拼接规则生成。
    pub fn finish_check(
        &self,
        url: &str,
        revision: &str,
        status: &str,
        detail: &str,
        checked_at: i64,
    ) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE book_source_check_states
                 SET status = ?3, detail = ?4, checkedAt = ?5
                 WHERE bookSourceUrl = ?1 AND revision = ?2 AND status = ?6",
                params![
                    url,
                    revision,
                    status,
                    detail,
                    checked_at,
                    check_status::NEEDS_CHECK
                ],
            )
            .map_err(|e| LegadoError::Database(format!("写回检验结果失败: {e}")))?;
        Ok(affected > 0)
    }
}

fn row_to_state(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookSourceCheckState> {
    Ok(BookSourceCheckState {
        book_source_url: row.get(0)?,
        revision: row.get(1)?,
        source_revision: row.get(2)?,
        status: row.get(3)?,
        checked_at: row.get(4)?,
        detail: row.get(5)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repository::book_source_repository::BookSourceRepository;
    use crate::repository::Repository;
    use legado_core::models::BookSource;

    fn make_source(url: &str) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            book_source_name: format!("源{url}"),
            ..BookSource::default()
        }
    }

    fn setup() -> crate::Database {
        crate::init_in_memory_database().unwrap()
    }

    #[test]
    fn test_save_and_find_roundtrip() {
        let db = setup();
        let conn = db.connection();
        BookSourceRepository::new(conn)
            .insert(&make_source("https://a.example.com"))
            .unwrap();

        let repo = BookSourceCheckStateRepository::new(conn);
        let mut state = BookSourceCheckState::new("https://a.example.com");
        state.source_revision = "fixed-source".to_string();
        repo.save(&state).unwrap();

        let found = repo.find_by_url("https://a.example.com").unwrap().unwrap();
        assert_eq!(found, state);
        assert_eq!(repo.find_all().unwrap().len(), 1);
        assert!(repo.find_by_url("missing").unwrap().is_none());
    }

    #[test]
    fn test_find_by_urls_batch_order() {
        let db = setup();
        let conn = db.connection();
        let source_repo = BookSourceRepository::new(conn);
        for url in ["https://b.example.com", "https://a.example.com"] {
            source_repo.insert(&make_source(url)).unwrap();
            BookSourceCheckStateRepository::new(conn)
                .save(&BookSourceCheckState::new(url))
                .unwrap();
        }
        let repo = BookSourceCheckStateRepository::new(conn);
        let states = repo
            .find_by_urls(&[
                "https://b.example.com".to_string(),
                "https://a.example.com".to_string(),
            ])
            .unwrap();
        assert_eq!(states.len(), 2);
        assert_eq!(states[0].book_source_url, "https://a.example.com");
        assert!(repo.find_by_urls(&[]).unwrap().is_empty());
    }

    #[test]
    fn test_delete_source_cascades_state() {
        let db = setup();
        let conn = db.connection();
        let source_repo = BookSourceRepository::new(conn);
        source_repo
            .insert(&make_source("https://a.example.com"))
            .unwrap();
        let repo = BookSourceCheckStateRepository::new(conn);
        repo.save(&BookSourceCheckState::new("https://a.example.com"))
            .unwrap();
        assert!(repo.find_by_url("https://a.example.com").unwrap().is_some());

        source_repo.delete("https://a.example.com").unwrap();
        assert!(
            repo.find_by_url("https://a.example.com").unwrap().is_none(),
            "删源后状态行应由外键级联删除"
        );
    }

    #[test]
    fn test_begin_check_resets_and_keeps_source_revision() {
        let db = setup();
        let conn = db.connection();
        let source_repo = BookSourceRepository::new(conn);
        let mut source = make_source("https://a.example.com");
        source.last_update_time = 123;
        source_repo.insert(&source).unwrap();

        let repo = BookSourceCheckStateRepository::new(conn);
        let mut state = BookSourceCheckState::new("https://a.example.com");
        state.status = "PASSED".to_string();
        state.checked_at = 9;
        state.detail = "old".to_string();
        repo.save(&state).unwrap();

        let queued = repo
            .begin_check("https://a.example.com", 123, &state.revision)
            .unwrap()
            .expect("快照匹配应重置");
        assert_eq!(queued.source_revision, state.source_revision);
        assert_ne!(queued.revision, state.revision);
        assert_eq!(queued.status, "NEEDS_CHECK");
        assert_eq!(queued.checked_at, 0);
        assert!(queued.detail.is_empty());
        let stored = repo.find_by_url("https://a.example.com").unwrap().unwrap();
        assert_eq!(stored, queued);
    }

    #[test]
    fn test_begin_check_rejects_stale_snapshot() {
        let db = setup();
        let conn = db.connection();
        let source_repo = BookSourceRepository::new(conn);
        let mut source = make_source("https://a.example.com");
        source.last_update_time = 200;
        source_repo.insert(&source).unwrap();
        let repo = BookSourceCheckStateRepository::new(conn);
        let state = BookSourceCheckState::new("https://a.example.com");
        repo.save(&state).unwrap();

        assert!(repo
            .begin_check("https://a.example.com", 100, &state.revision)
            .unwrap()
            .is_none());
        assert!(repo
            .begin_check("https://a.example.com", 200, "other-revision")
            .unwrap()
            .is_none());
        assert!(repo
            .begin_check("https://missing.example.com", 200, &state.revision)
            .unwrap()
            .is_none());
    }

    #[test]
    fn test_begin_check_on_missing_state_creates_row() {
        let db = setup();
        let conn = db.connection();
        BookSourceRepository::new(conn)
            .insert(&make_source("https://a.example.com"))
            .unwrap();
        let repo = BookSourceCheckStateRepository::new(conn);
        let queued = repo
            .begin_check("https://a.example.com", 0, "")
            .unwrap()
            .expect("缺状态行按 coalesce 默认值处理");
        assert_eq!(queued.source_revision, "");
        assert_eq!(queued.status, "NEEDS_CHECK");
        assert!(repo.find_by_url("https://a.example.com").unwrap().is_some());
    }

    #[test]
    fn test_finish_check_cas() {
        let db = setup();
        let conn = db.connection();
        BookSourceRepository::new(conn)
            .insert(&make_source("https://a.example.com"))
            .unwrap();
        let repo = BookSourceCheckStateRepository::new(conn);
        let state = BookSourceCheckState::new("https://a.example.com");
        repo.save(&state).unwrap();

        // revision 不匹配 → 不写
        assert!(!repo
            .finish_check("https://a.example.com", "wrong", "PASSED", "", 1)
            .unwrap());
        // 正常写回
        assert!(repo
            .finish_check("https://a.example.com", &state.revision, "PASSED", "", 42)
            .unwrap());
        let stored = repo.find_by_url("https://a.example.com").unwrap().unwrap();
        assert_eq!(stored.status, "PASSED");
        assert_eq!(stored.checked_at, 42);
        // 状态已非 NEEDS_CHECK → 再次写回被拒（旧任务不得覆盖）
        assert!(!repo
            .finish_check("https://a.example.com", &state.revision, "FAILED", "x", 43)
            .unwrap());
        assert_eq!(
            repo.find_by_url("https://a.example.com")
                .unwrap()
                .unwrap()
                .status,
            "PASSED"
        );
    }

    #[test]
    fn test_save_all_batch() {
        let db = setup();
        let conn = db.connection();
        let source_repo = BookSourceRepository::new(conn);
        for url in ["https://a.example.com", "https://b.example.com"] {
            source_repo.insert(&make_source(url)).unwrap();
        }
        let repo = BookSourceCheckStateRepository::new(conn);
        repo.save_all(&[
            BookSourceCheckState::new("https://a.example.com"),
            BookSourceCheckState::new("https://b.example.com"),
        ])
        .unwrap();
        assert_eq!(repo.find_all().unwrap().len(), 2);
    }
}
