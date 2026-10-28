//! BookSource Repository - book_sources 表 CRUD
//!
//! 查询口径（批30b P3-7）：全量/批量查询不再用 `filter_map(|r| r.ok())`
//! 静默吞掉行解析错误，统一走 [`super::collect_rows_logged`]——坏行跳过但
//! 记 stderr 日志（含前 3 条错误与总条数），避免「书源凭空消失」无从定位。

use rusqlite::{params, Connection};

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};

use super::Repository;

/// 书源数据访问层
pub struct BookSourceRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookSourceRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 根据 URL 查询书源
    pub fn find_by_url(&self, url: &str) -> LegadoResult<Option<BookSource>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
                        bookUrlPattern, customOrder, enabled, enabledExplore, jsLib,
                        enabledCookieJar, concurrentRate, header, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, bookSourceComment, variableComment,
                        lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen,
                        ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
                        ruleContent, ruleReview, mainJs, eventListener, customButton,
                        variable
                 FROM book_sources WHERE bookSourceUrl = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![url], row_to_book_source)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(bs)) => Ok(Some(bs)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 查询所有启用的书源
    pub fn find_enabled(&self) -> LegadoResult<Vec<BookSource>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
                        bookUrlPattern, customOrder, enabled, enabledExplore, jsLib,
                        enabledCookieJar, concurrentRate, header, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, bookSourceComment, variableComment,
                        lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen,
                        ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
                        ruleContent, ruleReview, mainJs, eventListener, customButton,
                        variable
                 FROM book_sources WHERE enabled = 1 ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = super::collect_rows_logged(
            stmt.query_map([], row_to_book_source)
                .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?,
            "启用书源查询",
        );
        Ok(sources)
    }

    /// 按分组查询书源
    pub fn find_by_group(&self, group: &str) -> LegadoResult<Vec<BookSource>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
                        bookUrlPattern, customOrder, enabled, enabledExplore, jsLib,
                        enabledCookieJar, concurrentRate, header, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, bookSourceComment, variableComment,
                        lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen,
                        ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
                        ruleContent, ruleReview, mainJs, eventListener, customButton,
                        variable
                 FROM book_sources WHERE bookSourceGroup = ?1 ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = super::collect_rows_logged(
            stmt.query_map(params![group], row_to_book_source)
                .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?,
            "按分组查询书源",
        );
        Ok(sources)
    }

    /// 获取书源总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM book_sources", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }

    /// CAS 乐观锁更新书源检查结果（对齐上游 `BookSourceDao.updateCheckResult`）
    ///
    /// 仅当数据库中 `lastUpdateTime`/`bookSourceGroup`/`bookSourceComment`/`respondTime`
    /// 与调用方读取时的快照（expected_*）完全一致时才执行更新，
    /// 避免并发检查时覆盖其他会话的修改。
    ///
    /// 语义对齐说明：
    /// - Kotlin 中 `(col is null and :p is null) or col = :p` 的空值安全比较，
    ///   在 SQLite 中等价于 `col IS ?`（两侧同为 NULL 时返回真）；
    /// - Kotlin 返回受影响行数 Int，此处按任务要求收敛为 bool（affected > 0）。
    ///
    /// 返回 `Ok(true)` 表示 CAS 成功（已更新），`Ok(false)` 表示快照已过期未更新。
    #[allow(clippy::too_many_arguments)]
    pub fn update_check_result(
        &self,
        book_source_url: &str,
        book_source_group: Option<&str>,
        book_source_comment: Option<&str>,
        respond_time: i64,
        expected_last_update_time: i64,
        expected_book_source_group: Option<&str>,
        expected_book_source_comment: Option<&str>,
        expected_respond_time: i64,
    ) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE book_sources SET
                    bookSourceGroup = ?2,
                    bookSourceComment = ?3,
                    respondTime = ?4
                 WHERE bookSourceUrl = ?1
                    AND lastUpdateTime = ?5
                    AND bookSourceGroup IS ?6
                    AND bookSourceComment IS ?7
                    AND respondTime = ?8",
                params![
                    book_source_url,
                    book_source_group,
                    book_source_comment,
                    respond_time,
                    expected_last_update_time,
                    expected_book_source_group,
                    expected_book_source_comment,
                    expected_respond_time,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("CAS 更新检查结果失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 单列更新书源自定义变量（契约 §2.3 setSourceVariable 语义，台账 §5.11-3）
    ///
    /// 仅更新 `variable` 单列，规避 updateBookSource 全行更新风险（对齐原版
    /// `source.setVariable`）；空串即清除。返回是否命中书源行
    /// （`false` 表示书源不存在，调用方据此报 Internal 错误）。
    pub fn update_variable(&self, source_url: &str, variable: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE book_sources SET variable = ?2 WHERE bookSourceUrl = ?1",
                params![source_url, variable],
            )
            .map_err(|e| LegadoError::Database(format!("更新书源变量失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 按 URL 批量查询书源（`IN (...)`，调用方需先按
    /// [`crate::repository::book_source_check_state_repository::BOOK_SOURCE_QUERY_CHUNK_SIZE`]
    /// 分块）
    ///
    /// 对齐原版 `BookSourceDao.getBookSources(keys)`（`BookSourceCheckController.sources`
    /// 的指定 URL 分支），按 `customOrder` 升序返回保证响应稳定。
    pub fn find_by_urls(&self, urls: &[String]) -> LegadoResult<Vec<BookSource>> {
        if urls.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = std::iter::repeat_n("?", urls.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
                    bookUrlPattern, customOrder, enabled, enabledExplore, jsLib,
                    enabledCookieJar, concurrentRate, header, loginUrl, loginUi,
                    loginCheckJs, coverDecodeJs, bookSourceComment, variableComment,
                    lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen,
                    ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
                    ruleContent, ruleReview, mainJs, eventListener, customButton,
                    variable
             FROM book_sources WHERE bookSourceUrl IN ({placeholders})
             ORDER BY customOrder ASC"
        );
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| LegadoError::Database(format!("准备批量查询失败: {e}")))?;
        let sources = super::collect_rows_logged(
            stmt.query_map(rusqlite::params_from_iter(urls.iter()), row_to_book_source)
                .map_err(|e| LegadoError::Database(format!("批量查询失败: {e}")))?,
            "书源批量查询",
        );
        Ok(sources)
    }

    /// 更新书源响应时间（单列；对齐原版 `BookSourceDao.updateRespondTime`）
    pub fn update_respond_time(&self, source_url: &str, respond_time: i64) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE book_sources SET respondTime = ?2 WHERE bookSourceUrl = ?1",
                params![source_url, respond_time],
            )
            .map_err(|e| LegadoError::Database(format!("更新响应时间失败: {e}")))?;
        Ok(())
    }

    /// 批量写入书源（单事务原子，P1-1 批量导入原子性）
    ///
    /// 复用 [`Repository::insert`]（INSERT OR REPLACE 全列 upsert，与
    /// add_source/update_source 同一写实现）逐条写入，并通过
    /// [`crate::connection::in_transaction`] 包成单个 DB 事务：
    /// 任一条失败回滚整批（调用方看到 Err 时库内零改动，不出现前 k-1 条
    /// 已提交的部分成功态）；全部成功提交后才返回 Ok。
    ///
    /// 与 `RoomImporter::import_book_sources` 共享同一事务边界实现；
    /// 调用方若已持有外层事务则自动复用（不嵌套 BEGIN），提交/回滚由外层负责。
    pub fn insert_batch(&self, items: &[BookSource]) -> LegadoResult<()> {
        crate::connection::in_transaction(self.conn, "批量写入书源", |conn| {
            let repo = BookSourceRepository::new(conn);
            for item in items {
                repo.insert(item)?;
            }
            Ok(())
        })
    }

    /// 新增/覆盖书源并**重建**检验状态（对齐原版 `BookSourceDao.insert`）
    ///
    /// 原版 `@Transaction insert` 在写入源后固定执行
    /// `saveCheckStates(BookSourceCheckState(url))`——无论同 URL 是否已有旧行，
    /// 都生成新 revision/sourceRevision 并回到 `NEEDS_CHECK`。网页保存
    /// （`/saveBookSource`、`/saveBookSources`）、JS 源保存、源导入均走该语义。
    ///
    /// 实现注意：`INSERT OR REPLACE` 会先删除旧行，外键 `ON DELETE CASCADE`
    /// 随之清掉旧状态；随后写入新状态即等价原版行为。
    pub fn insert_with_check_state(&self, item: &BookSource) -> LegadoResult<()> {
        crate::connection::in_transaction(self.conn, "写入书源与检验状态", |conn| {
            let repo = BookSourceRepository::new(conn);
            repo.insert(item)?;
            crate::repository::book_source_check_state_repository::BookSourceCheckStateRepository::new(conn)
                .save(&legado_core::models::BookSourceCheckState::new(
                    &item.book_source_url,
                ))?;
            Ok(())
        })
    }

    /// 更新书源；仅当规则内容变化时重建检验状态（对齐原版 `BookSourceDao.update`）
    ///
    /// 原版比较 `current.checkContent() != source.checkContent()`：仅改启用开关/
    /// 分组/排序等不影响规则的字段时，保留已有检验状态（含 revision 与
    /// sourceRevision）；规则内容变化则重建状态（`NEEDS_CHECK` + 新 revision）。
    ///
    /// 源不存在时按既有 upsert 语义写入并创建状态（本轨 `update` 一直是
    /// upsert；原版 `update` 对不存在行是 no-op，差异为既有行为登记）。
    pub fn update_with_check_state(&self, item: &BookSource) -> LegadoResult<()> {
        crate::connection::in_transaction(self.conn, "更新书源与检验状态", |conn| {
            let repo = BookSourceRepository::new(conn);
            let state_repo =
                crate::repository::book_source_check_state_repository::BookSourceCheckStateRepository::new(conn);
            let previous = repo.find_by_url(&item.book_source_url)?;
            let previous_state = state_repo.find_by_url(&item.book_source_url)?;
            repo.insert(item)?;
            let content_unchanged = previous
                .as_ref()
                .is_some_and(|old| old.check_content() == item.check_content());
            let state = if content_unchanged {
                previous_state.unwrap_or_else(|| {
                    legado_core::models::BookSourceCheckState::new(&item.book_source_url)
                })
            } else {
                legado_core::models::BookSourceCheckState::new(&item.book_source_url)
            };
            state_repo.save(&state)?;
            Ok(())
        })
    }

    /// 批量导入书源并为每条重建检验状态（单事务，对齐原版逐条 `insert`）
    pub fn insert_batch_with_check_state(&self, items: &[BookSource]) -> LegadoResult<()> {
        crate::connection::in_transaction(self.conn, "批量写入书源与检验状态", |conn| {
            let repo = BookSourceRepository::new(conn);
            for item in items {
                repo.insert_with_check_state(item)?;
            }
            Ok(())
        })
    }
}

impl<'a> Repository<BookSource> for BookSourceRepository<'a> {
    fn find_all(&self) -> LegadoResult<Vec<BookSource>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
                        bookUrlPattern, customOrder, enabled, enabledExplore, jsLib,
                        enabledCookieJar, concurrentRate, header, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, bookSourceComment, variableComment,
                        lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen,
                        ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
                        ruleContent, ruleReview, mainJs, eventListener, customButton,
                        variable
                 FROM book_sources ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = super::collect_rows_logged(
            stmt.query_map([], row_to_book_source)
                .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?,
            "书源全量查询",
        );
        Ok(sources)
    }

    fn insert(&self, item: &BookSource) -> LegadoResult<()> {
        let rule_explore_json = item
            .rule_explore
            .as_ref()
            .map(|r| serde_json::to_string(r).unwrap_or_default());
        let rule_search_json = item
            .rule_search
            .as_ref()
            .map(|r| serde_json::to_string(r).unwrap_or_default());
        let rule_book_info_json = item
            .rule_book_info
            .as_ref()
            .map(|r| serde_json::to_string(r).unwrap_or_default());
        let rule_toc_json = item
            .rule_toc
            .as_ref()
            .map(|r| serde_json::to_string(r).unwrap_or_default());
        let rule_content_json = item
            .rule_content
            .as_ref()
            .map(|r| serde_json::to_string(r).unwrap_or_default());
        let rule_review_json = item
            .rule_review
            .as_ref()
            .map(|r| serde_json::to_string(r).unwrap_or_default());

        self.conn
            .execute(
                "INSERT OR REPLACE INTO book_sources
             (bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
              bookUrlPattern, customOrder, enabled, enabledExplore, jsLib,
              enabledCookieJar, concurrentRate, header, loginUrl, loginUi,
              loginCheckJs, coverDecodeJs, bookSourceComment, variableComment,
              lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen,
              ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
              ruleContent, ruleReview, mainJs, eventListener, customButton, variable)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,
                     ?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,
                     ?34)",
                params![
                    item.book_source_url,
                    item.book_source_name,
                    item.book_source_group,
                    item.book_source_type,
                    item.book_url_pattern,
                    item.custom_order,
                    item.enabled,
                    item.enabled_explore,
                    item.js_lib,
                    item.enabled_cookie_jar,
                    item.concurrent_rate,
                    item.header,
                    item.login_url,
                    item.login_ui,
                    item.login_check_js,
                    item.cover_decode_js,
                    item.book_source_comment,
                    item.variable_comment,
                    item.last_update_time,
                    item.respond_time,
                    item.weight,
                    item.explore_url,
                    item.explore_screen,
                    rule_explore_json,
                    item.search_url,
                    rule_search_json,
                    rule_book_info_json,
                    rule_toc_json,
                    rule_content_json,
                    rule_review_json,
                    item.main_js,
                    item.event_listener,
                    item.custom_button,
                    item.variable,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
        Ok(())
    }

    fn update(&self, item: &BookSource) -> LegadoResult<()> {
        self.insert(item)
    }

    fn delete(&self, id: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "DELETE FROM book_sources WHERE bookSourceUrl = ?1",
                params![id],
            )
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(())
    }
}

/// 将 rusqlite Row 转换为 BookSource（规则字段从 JSON 反序列化）
fn row_to_book_source(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookSource> {
    let rule_explore_str: Option<String> = row.get(23)?;
    let rule_search_str: Option<String> = row.get(25)?;
    let rule_book_info_str: Option<String> = row.get(26)?;
    let rule_toc_str: Option<String> = row.get(27)?;
    let rule_content_str: Option<String> = row.get(28)?;
    let rule_review_str: Option<String> = row.get(29)?;

    Ok(BookSource {
        book_source_url: row.get(0)?,
        book_source_name: row.get(1)?,
        book_source_group: row.get(2)?,
        book_source_type: row.get(3)?,
        book_url_pattern: row.get(4)?,
        custom_order: row.get(5)?,
        enabled: row.get(6)?,
        enabled_explore: row.get(7)?,
        js_lib: row.get(8)?,
        enabled_cookie_jar: row.get(9)?,
        concurrent_rate: row.get(10)?,
        header: row.get(11)?,
        login_url: row.get(12)?,
        login_ui: row.get(13)?,
        login_check_js: row.get(14)?,
        cover_decode_js: row.get(15)?,
        book_source_comment: row.get(16)?,
        variable_comment: row.get(17)?,
        last_update_time: row.get(18)?,
        respond_time: row.get(19)?,
        weight: row.get(20)?,
        explore_url: row.get(21)?,
        explore_screen: row.get(22)?,
        rule_explore: rule_explore_str.and_then(|s| serde_json::from_str(&s).ok()),
        search_url: row.get(24)?,
        rule_search: rule_search_str.and_then(|s| serde_json::from_str(&s).ok()),
        rule_book_info: rule_book_info_str.and_then(|s| serde_json::from_str(&s).ok()),
        rule_toc: rule_toc_str.and_then(|s| serde_json::from_str(&s).ok()),
        rule_content: rule_content_str.and_then(|s| serde_json::from_str(&s).ok()),
        rule_review: rule_review_str.and_then(|s| serde_json::from_str(&s).ok()),
        main_js: row.get(30)?,
        event_listener: row.get(31)?,
        custom_button: row.get(32)?,
        variable: row.get(33)?,
    })
}

#[cfg(test)]
mod tests {
    use super::super::Repository;
    use super::*;

    fn make_source(url: &str, name: &str) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            book_source_name: name.to_string(),
            ..BookSource::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let src = make_source("https://source.example.com", "测试书源");
        repo.insert(&src).unwrap();
        let found = repo.find_by_url("https://source.example.com").unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().book_source_name, "测试书源");
    }

    /// 批28b（P2-3 端到端）：`ruleContent.contentBatch` / `maxBatchSize`
    /// 经 repository insert → find 往返不丢（规则 JSON 列全字段序列化）
    #[test]
    fn test_insert_and_find_preserves_content_batch_fields() {
        use legado_core::models::ContentRule;

        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("https://batch.example.com", "批量源");
        src.rule_content = Some(ContentRule {
            content: Some(".content@text".to_string()),
            content_batch: Some("batch@js:result".to_string()),
            max_batch_size: Some(20),
            ..ContentRule::default()
        });
        repo.insert(&src).unwrap();

        let found = repo
            .find_by_url("https://batch.example.com")
            .unwrap()
            .expect("书源应可读回");
        let rule = found.rule_content.as_ref().expect("ruleContent 应存在");
        assert_eq!(rule.content.as_deref(), Some(".content@text"));
        assert_eq!(
            rule.content_batch.as_deref(),
            Some("batch@js:result"),
            "contentBatch 必须随仓储往返保留"
        );
        assert_eq!(
            rule.max_batch_size,
            Some(20),
            "maxBatchSize 必须随仓储往返保留"
        );

        // 更新路径（update = INSERT OR REPLACE）同样保真
        let mut updated = found.clone();
        updated.rule_content.as_mut().unwrap().max_batch_size = Some(5);
        repo.update(&updated).unwrap();
        let reread = repo
            .find_by_url("https://batch.example.com")
            .unwrap()
            .unwrap();
        let rule = reread.rule_content.expect("ruleContent 应存在");
        assert_eq!(rule.content_batch.as_deref(), Some("batch@js:result"));
        assert_eq!(rule.max_batch_size, Some(5));
    }

    #[test]
    fn test_find_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut s1 = make_source("u1", "enabled");
        s1.enabled = true;
        let mut s2 = make_source("u2", "disabled");
        s2.enabled = false;
        repo.insert(&s1).unwrap();
        repo.insert(&s2).unwrap();
        let enabled = repo.find_enabled().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].book_source_name, "enabled");
    }

    #[test]
    fn test_find_by_group() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut s1 = make_source("u1", "s1");
        s1.book_source_group = Some("分组A".to_string());
        let mut s2 = make_source("u2", "s2");
        s2.book_source_group = Some("分组B".to_string());
        repo.insert(&s1).unwrap();
        repo.insert(&s2).unwrap();
        let group_a = repo.find_by_group("分组A").unwrap();
        assert_eq!(group_a.len(), 1);
        assert_eq!(group_a[0].book_source_name, "s1");
    }

    #[test]
    fn test_count_and_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        repo.insert(&make_source("u1", "s1")).unwrap();
        repo.insert(&make_source("u2", "s2")).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
        repo.delete("u1").unwrap();
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        repo.insert(&make_source("u1", "s1")).unwrap();
        repo.insert(&make_source("u2", "s2")).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_update_upsert() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "original");
        repo.insert(&src).unwrap();
        src.book_source_name = "updated".to_string();
        repo.update(&src).unwrap();
        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.book_source_name, "updated");
        assert_eq!(repo.count().unwrap(), 1);
    }

    // ─── 批30：保存钩子的检验状态语义（对齐 BookSourceDao.insert/update） ───

    fn state_repo<'a>(
        conn: &'a rusqlite::Connection,
    ) -> crate::repository::book_source_check_state_repository::BookSourceCheckStateRepository<'a>
    {
        crate::repository::book_source_check_state_repository::BookSourceCheckStateRepository::new(
            conn,
        )
    }

    /// insert_with_check_state：新源生成 NEEDS_CHECK 状态；再次 insert 重建
    #[test]
    fn test_insert_with_check_state_creates_and_resets() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookSourceRepository::new(conn);
        let src = make_source("https://a.example.com", "a");
        repo.insert_with_check_state(&src).unwrap();

        let first = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .expect("应创建状态");
        assert_eq!(first.status, "NEEDS_CHECK");

        repo.insert_with_check_state(&src).unwrap();
        let second = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap();
        assert_ne!(
            first.revision, second.revision,
            "insert 语义应重建 revision"
        );
        assert_ne!(first.source_revision, second.source_revision);
    }

    /// update_with_check_state：仅启用开关变化 → 状态保留；规则变化 → 重建
    #[test]
    fn test_update_with_check_state_preserves_or_resets() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookSourceRepository::new(conn);
        let mut src = make_source("https://a.example.com", "a");
        repo.insert_with_check_state(&src).unwrap();
        let before = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap();

        // 仅 enabled 变化（checkContent 归一后一致）→ 状态原样保留
        src.enabled = !src.enabled;
        repo.update_with_check_state(&src).unwrap();
        let kept = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap();
        assert_eq!(kept, before, "不影响规则的字段变化不应重置状态");

        // searchUrl 变化（规则内容变化）→ 重建状态
        src.search_url = Some("https://a.example.com/search?q={key}".to_string());
        repo.update_with_check_state(&src).unwrap();
        let reset = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap();
        assert_ne!(reset.revision, before.revision);
        assert_ne!(reset.source_revision, before.source_revision);
        assert_eq!(reset.status, "NEEDS_CHECK");
    }

    /// update_with_check_state：规则不变时保留 PASSED 结果与时间
    #[test]
    fn test_update_with_check_state_keeps_passed_result() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookSourceRepository::new(conn);
        let mut src = make_source("https://a.example.com", "a");
        repo.insert_with_check_state(&src).unwrap();
        let mut state = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap();
        state.status = "PASSED".to_string();
        state.checked_at = 777;
        state_repo(conn).save(&state).unwrap();

        src.custom_order = 5;
        src.weight = 9;
        repo.update_with_check_state(&src).unwrap();
        let kept = state_repo(conn)
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap();
        assert_eq!(kept.status, "PASSED");
        assert_eq!(kept.checked_at, 777);
        assert_eq!(kept.revision, state.revision);
    }

    /// insert_batch_with_check_state：逐条创建状态
    #[test]
    fn test_insert_batch_with_check_state() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookSourceRepository::new(conn);
        repo.insert_batch_with_check_state(&[
            make_source("https://a.example.com", "a"),
            make_source("https://b.example.com", "b"),
        ])
        .unwrap();
        assert_eq!(state_repo(conn).find_all().unwrap().len(), 2);
    }

    /// CAS 成功：expected 快照与库内一致，字段被更新并返回 true
    #[test]
    fn test_update_check_result_success() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "s1");
        src.book_source_group = Some("分组A".to_string());
        src.book_source_comment = Some("旧备注".to_string());
        src.last_update_time = 100;
        src.respond_time = 500;
        repo.insert(&src).unwrap();

        let ok = repo
            .update_check_result(
                "u1",
                Some("分组B"),
                Some("新备注"),
                300,
                100,
                Some("分组A"),
                Some("旧备注"),
                500,
            )
            .unwrap();
        assert!(ok);

        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.book_source_group.as_deref(), Some("分组B"));
        assert_eq!(found.book_source_comment.as_deref(), Some("新备注"));
        assert_eq!(found.respond_time, 300);
        // lastUpdateTime 不在更新列内，保持原值
        assert_eq!(found.last_update_time, 100);
    }

    /// CAS 竞态：expected_last_update_time 不匹配时返回 false 且不落库
    #[test]
    fn test_update_check_result_conflict_on_last_update_time() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "s1");
        src.last_update_time = 200;
        src.respond_time = 500;
        repo.insert(&src).unwrap();

        // 调用方持有旧快照（lastUpdateTime=100），库内已被其他会话推进到 200
        let ok = repo
            .update_check_result("u1", Some("G"), None, 300, 100, None, None, 500)
            .unwrap();
        assert!(!ok);

        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.book_source_group, None);
        assert_eq!(found.respond_time, 500);
    }

    /// CAS 竞态：respondTime 快照不匹配时同样拒绝更新
    #[test]
    fn test_update_check_result_conflict_on_respond_time() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "s1");
        src.last_update_time = 100;
        src.respond_time = 400;
        repo.insert(&src).unwrap();

        let ok = repo
            .update_check_result("u1", None, None, 300, 100, None, None, 500)
            .unwrap();
        assert!(!ok);
        assert_eq!(repo.find_by_url("u1").unwrap().unwrap().respond_time, 400);
    }

    /// 空值安全比较：库内 group/comment 为 NULL 时 expected 传 None 应匹配成功
    #[test]
    fn test_update_check_result_null_fields_match() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "s1");
        src.book_source_group = None;
        src.book_source_comment = None;
        src.last_update_time = 100;
        src.respond_time = 500;
        repo.insert(&src).unwrap();

        let ok = repo
            .update_check_result("u1", None, None, 250, 100, None, None, 500)
            .unwrap();
        assert!(ok);
        assert_eq!(repo.find_by_url("u1").unwrap().unwrap().respond_time, 250);
    }

    /// 空值安全比较：库内 group 为 NULL 而 expected 传 Some 时应拒绝（反之亦然）
    #[test]
    fn test_update_check_result_null_mismatch_rejected() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "s1");
        src.book_source_group = None;
        src.last_update_time = 100;
        src.respond_time = 500;
        repo.insert(&src).unwrap();

        let ok = repo
            .update_check_result("u1", None, None, 300, 100, Some("分组A"), None, 500)
            .unwrap();
        assert!(!ok);
        assert_eq!(repo.find_by_url("u1").unwrap().unwrap().respond_time, 500);
    }

    /// 台账 §5.11-3：variable 随 insert/查询自然带出，默认空串
    #[test]
    fn test_variable_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "s1");
        src.enabled = true; // find_enabled 仅返回启用书源
        src.variable = "初始变量".to_string();
        repo.insert(&src).unwrap();

        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.variable, "初始变量");
        // find_all / find_enabled 也自然带出 variable
        assert_eq!(repo.find_all().unwrap()[0].variable, "初始变量");
        assert_eq!(repo.find_enabled().unwrap()[0].variable, "初始变量");

        // 未显式设置时默认空串
        repo.insert(&make_source("u2", "s2")).unwrap();
        assert_eq!(repo.find_by_url("u2").unwrap().unwrap().variable, "");
    }

    /// 台账 §5.11-3：update_variable 单列更新——命中返回 true，
    /// 不触碰其他列；书源不存在返回 false；空串即清除
    #[test]
    fn test_update_variable_single_column() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let mut src = make_source("u1", "原名");
        src.book_source_comment = Some("备注".to_string());
        repo.insert(&src).unwrap();

        // 命中：variable 更新，其他列不受影响
        assert!(repo.update_variable("u1", "user=abc").unwrap());
        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.variable, "user=abc");
        assert_eq!(found.book_source_name, "原名");
        assert_eq!(found.book_source_comment.as_deref(), Some("备注"));

        // 空串 = 清除
        assert!(repo.update_variable("u1", "").unwrap());
        assert_eq!(repo.find_by_url("u1").unwrap().unwrap().variable, "");

        // 书源不存在 → false
        assert!(!repo.update_variable("不存在", "x").unwrap());
    }

    // ─── 批量写入原子性（P1-1） ──────────────────────────────────────────

    /// 成功批次整体提交：2 条均入库
    #[test]
    fn test_insert_batch_commits_all_on_success() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookSourceRepository::new(db.connection());
        let items = vec![
            make_source("https://batch-ok-1.example", "批量一"),
            make_source("https://batch-ok-2.example", "批量二"),
        ];
        repo.insert_batch(&items).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
        assert!(repo
            .find_by_url("https://batch-ok-1.example")
            .unwrap()
            .is_some());
        assert!(repo
            .find_by_url("https://batch-ok-2.example")
            .unwrap()
            .is_some());
    }

    /// 行级失败整批回滚：第 1 条合法、第 2 条被临时触发器 ABORT（确定性
    /// 注入行级 SQL 失败，等价于唯一键冲突场景）→ 第 1 条也必须回滚，
    /// 库内零新增
    #[test]
    fn test_insert_batch_rolls_back_on_row_failure() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TRIGGER trg_bs_batch_bomb BEFORE INSERT ON book_sources
             WHEN NEW.bookSourceName = 'batch-bomb'
             BEGIN SELECT RAISE(ABORT, 'batch-bomb'); END;",
        )
        .unwrap();

        let repo = BookSourceRepository::new(conn);
        let items = vec![
            make_source("https://batch-rollback-ok.example", "batch-ok"),
            make_source("https://batch-rollback-bomb.example", "batch-bomb"),
        ];
        let err = repo.insert_batch(&items).unwrap_err();
        assert!(
            matches!(err, LegadoError::Database(_)),
            "第 2 条触发器 ABORT 应报 Database 错误"
        );
        assert_eq!(repo.count().unwrap(), 0, "第 2 条失败必须回滚第 1 条");
    }
}
