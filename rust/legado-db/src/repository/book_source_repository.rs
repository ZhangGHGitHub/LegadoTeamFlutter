//! BookSource Repository - book_sources 表 CRUD

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
                        ruleContent, ruleReview, mainJs, eventListener, customButton
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
                        ruleContent, ruleReview, mainJs, eventListener, customButton
                 FROM book_sources WHERE enabled = 1 ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = stmt
            .query_map([], row_to_book_source)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
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
                        ruleContent, ruleReview, mainJs, eventListener, customButton
                 FROM book_sources WHERE bookSourceGroup = ?1 ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = stmt
            .query_map(params![group], row_to_book_source)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
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
                        ruleContent, ruleReview, mainJs, eventListener, customButton
                 FROM book_sources ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = stmt
            .query_map([], row_to_book_source)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
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
              ruleContent, ruleReview, mainJs, eventListener, customButton)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,
                     ?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33)",
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
}
