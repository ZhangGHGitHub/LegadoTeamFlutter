//! RssSource Repository - rssSources 表 CRUD

use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection};

use legado_core::models::RssSource;

/// RSS 源数据访问层
pub struct RssSourceRepository {
    conn: Arc<Mutex<Connection>>,
}

impl RssSourceRepository {
    pub fn new(conn: Arc<Mutex<Connection>>) -> Self {
        Self { conn }
    }

    /// 查询所有 RSS 源
    pub fn find_all(&self) -> Result<Vec<RssSource>, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let mut stmt = conn
            .prepare(
                "SELECT sourceUrl, sourceName, sourceIcon, sourceGroup, sourceComment,
                        enabled, sortUrl, customOrder, lastUpdateTime, header,
                        enableJs, loadWithBaseUrl, variableComment, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, concurrentRate,
                        ruleArticles, ruleNextPage, ruleTitle, rulePubDate,
                        ruleDescription, ruleImage, ruleLink, ruleContent,
                        style, enableCookieJar, articleStyle, singleUrl
                 FROM rssSources ORDER BY customOrder ASC",
            )
            .map_err(|e| format!("准备查询失败: {e}"))?;

        let sources = stmt
            .query_map([], row_to_rss_source)
            .map_err(|e| format!("查询失败: {e}"))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(sources)
    }

    /// 根据 URL 查询 RSS 源
    pub fn find_by_url(&self, source_url: &str) -> Result<Option<RssSource>, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let mut stmt = conn
            .prepare(
                "SELECT sourceUrl, sourceName, sourceIcon, sourceGroup, sourceComment,
                        enabled, sortUrl, customOrder, lastUpdateTime, header,
                        enableJs, loadWithBaseUrl, variableComment, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, concurrentRate,
                        ruleArticles, ruleNextPage, ruleTitle, rulePubDate,
                        ruleDescription, ruleImage, ruleLink, ruleContent,
                        style, enableCookieJar, articleStyle, singleUrl
                 FROM rssSources WHERE sourceUrl = ?1",
            )
            .map_err(|e| format!("准备查询失败: {e}"))?;

        let mut rows = stmt
            .query_map(params![source_url], row_to_rss_source)
            .map_err(|e| format!("查询失败: {e}"))?;

        match rows.next() {
            Some(Ok(src)) => Ok(Some(src)),
            Some(Err(e)) => Err(format!("行解析失败: {e}")),
            None => Ok(None),
        }
    }

    /// 查询所有启用的 RSS 源
    pub fn find_enabled(&self) -> Result<Vec<RssSource>, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let mut stmt = conn
            .prepare(
                "SELECT sourceUrl, sourceName, sourceIcon, sourceGroup, sourceComment,
                        enabled, sortUrl, customOrder, lastUpdateTime, header,
                        enableJs, loadWithBaseUrl, variableComment, loginUrl, loginUi,
                        loginCheckJs, coverDecodeJs, concurrentRate,
                        ruleArticles, ruleNextPage, ruleTitle, rulePubDate,
                        ruleDescription, ruleImage, ruleLink, ruleContent,
                        style, enableCookieJar, articleStyle, singleUrl
                 FROM rssSources WHERE enabled = 1 ORDER BY customOrder ASC",
            )
            .map_err(|e| format!("准备查询失败: {e}"))?;

        let sources = stmt
            .query_map([], row_to_rss_source)
            .map_err(|e| format!("查询失败: {e}"))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(sources)
    }

    /// 插入 RSS 源（主键冲突时替换）
    pub fn insert(&self, source: &RssSource) -> Result<i64, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        conn.execute(
            "INSERT OR REPLACE INTO rssSources
             (sourceUrl, sourceName, sourceIcon, sourceGroup, sourceComment,
              enabled, sortUrl, customOrder, lastUpdateTime, header,
              enableJs, loadWithBaseUrl, variableComment, loginUrl, loginUi,
              loginCheckJs, coverDecodeJs, concurrentRate,
              ruleArticles, ruleNextPage, ruleTitle, rulePubDate,
              ruleDescription, ruleImage, ruleLink, ruleContent,
              style, enableCookieJar, articleStyle, singleUrl)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,
                     ?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30)",
            params![
                source.source_url,
                source.source_name,
                source.source_icon,
                source.source_group,
                source.source_comment,
                source.enabled,
                source.sort_url,
                source.custom_order,
                source.last_update_time,
                source.header,
                source.enable_js,
                source.load_with_base_url,
                source.variable_comment,
                source.login_url,
                source.login_ui,
                source.login_check_js,
                source.cover_decode_js,
                source.concurrent_rate,
                source.rule_articles,
                source.rule_next_page,
                source.rule_title,
                source.rule_pub_date,
                source.rule_description,
                source.rule_image,
                source.rule_link,
                source.rule_content,
                source.style,
                source.enabled_cookie_jar,
                source.article_style,
                source.single_url,
            ],
        )
        .map_err(|e| format!("插入失败: {e}"))?;
        Ok(conn.last_insert_rowid())
    }

    /// 更新 RSS 源（等同于 upsert）
    pub fn update(&self, source: &RssSource) -> Result<bool, String> {
        let exists = self.find_by_url(&source.source_url)?.is_some();
        self.insert(source)?;
        Ok(exists)
    }

    /// 根据 URL 删除 RSS 源
    pub fn delete(&self, source_url: &str) -> Result<bool, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let affected = conn
            .execute(
                "DELETE FROM rssSources WHERE sourceUrl = ?1",
                params![source_url],
            )
            .map_err(|e| format!("删除失败: {e}"))?;
        Ok(affected > 0)
    }

    /// 设置 RSS 源启用/禁用状态
    pub fn set_enabled(&self, source_url: &str, enabled: bool) -> Result<bool, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let affected = conn
            .execute(
                "UPDATE rssSources SET enabled = ?2 WHERE sourceUrl = ?1",
                params![source_url, enabled],
            )
            .map_err(|e| format!("更新状态失败: {e}"))?;
        Ok(affected > 0)
    }

    /// 获取 RSS 源总数
    pub fn count(&self) -> Result<i64, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rssSources", [], |row| row.get(0))
            .map_err(|e| format!("计数查询失败: {e}"))?;
        Ok(count)
    }
}

/// 将 rusqlite Row 转换为 RssSource
fn row_to_rss_source(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssSource> {
    Ok(RssSource {
        source_url: row.get(0)?,
        source_name: row.get(1)?,
        source_icon: row.get(2)?,
        source_group: row.get(3)?,
        source_comment: row.get(4)?,
        enabled: row.get(5)?,
        sort_url: row.get(6)?,
        custom_order: row.get(7)?,
        last_update_time: row.get(8)?,
        header: row.get(9)?,
        enable_js: row.get(10)?,
        load_with_base_url: row.get(11)?,
        variable_comment: row.get(12)?,
        login_url: row.get(13)?,
        login_ui: row.get(14)?,
        login_check_js: row.get(15)?,
        cover_decode_js: row.get(16)?,
        concurrent_rate: row.get(17)?,
        rule_articles: row.get(18)?,
        rule_next_page: row.get(19)?,
        rule_title: row.get(20)?,
        rule_pub_date: row.get(21)?,
        rule_description: row.get(22)?,
        rule_image: row.get(23)?,
        rule_link: row.get(24)?,
        rule_content: row.get(25)?,
        style: row.get(26)?,
        enabled_cookie_jar: row.get(27)?,
        article_style: row.get(28)?,
        single_url: row.get(29)?,
        ..RssSource::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_repo() -> RssSourceRepository {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        let conn = Arc::new(Mutex::new(conn));
        RssSourceRepository::new(conn)
    }

    fn make_source(url: &str, name: &str) -> RssSource {
        RssSource {
            source_url: url.to_string(),
            source_name: name.to_string(),
            ..RssSource::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_url() {
        let repo = make_repo();
        let src = make_source("https://rss.example.com", "测试RSS");
        repo.insert(&src).unwrap();
        let found = repo.find_by_url("https://rss.example.com").unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().source_name, "测试RSS");
    }

    #[test]
    fn test_find_by_url_not_found() {
        let repo = make_repo();
        let found = repo.find_by_url("https://nonexist.com").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn test_find_all() {
        let repo = make_repo();
        repo.insert(&make_source("u1", "s1")).unwrap();
        repo.insert(&make_source("u2", "s2")).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_enabled() {
        let repo = make_repo();
        let mut s1 = make_source("u1", "enabled");
        s1.enabled = true;
        let mut s2 = make_source("u2", "disabled");
        s2.enabled = false;
        repo.insert(&s1).unwrap();
        repo.insert(&s2).unwrap();
        let enabled = repo.find_enabled().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].source_name, "enabled");
    }

    #[test]
    fn test_update() {
        let repo = make_repo();
        let mut src = make_source("u1", "original");
        repo.insert(&src).unwrap();
        src.source_name = "updated".to_string();
        let existed = repo.update(&src).unwrap();
        assert!(existed);
        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.source_name, "updated");
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_delete() {
        let repo = make_repo();
        repo.insert(&make_source("u1", "s1")).unwrap();
        let deleted = repo.delete("u1").unwrap();
        assert!(deleted);
        assert_eq!(repo.count().unwrap(), 0);
        let not_deleted = repo.delete("u_nonexist").unwrap();
        assert!(!not_deleted);
    }

    #[test]
    fn test_set_enabled() {
        let repo = make_repo();
        let mut src = make_source("u1", "s1");
        src.enabled = true;
        repo.insert(&src).unwrap();
        let ok = repo.set_enabled("u1", false).unwrap();
        assert!(ok);
        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert!(!found.enabled);
        let fail = repo.set_enabled("u_nonexist", true).unwrap();
        assert!(!fail);
    }

    #[test]
    fn test_count() {
        let repo = make_repo();
        assert_eq!(repo.count().unwrap(), 0);
        repo.insert(&make_source("u1", "s1")).unwrap();
        repo.insert(&make_source("u2", "s2")).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
    }
}
