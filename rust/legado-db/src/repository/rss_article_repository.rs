//! RssArticle Repository - rssArticles 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 文章记录（v101 补齐 group/read/article_type/dur_pos，对齐 Room 99.json）
#[derive(Debug, Clone)]
pub struct RssArticleRecord {
    pub origin: String,
    pub sort: String,
    pub title: String,
    pub order: i64,
    pub link: Option<String>,
    pub pub_date: Option<String>,
    pub description: Option<String>,
    pub content: Option<String>,
    pub image: Option<String>,
    pub variable: Option<String>,
    /// 分组（对齐 Kotlin RssArticle.group，默认“默认分组”）
    pub group: String,
    /// 是否已读（对齐 Kotlin RssArticle.read）
    pub read: bool,
    /// 类型 0网页，1图片，2视频（对齐 Kotlin RssArticle.type）
    pub article_type: i32,
    /// 阅读进度（对齐 Kotlin RssArticle.durPos）
    pub dur_pos: i32,
}

/// 默认分组名（对齐 Kotlin `@ColumnInfo(defaultValue = "默认分组")`）
pub const DEFAULT_RSS_GROUP: &str = "默认分组";

impl Default for RssArticleRecord {
    fn default() -> Self {
        Self {
            origin: String::new(),
            sort: String::new(),
            title: String::new(),
            order: 0,
            link: None,
            pub_date: None,
            description: None,
            content: None,
            image: None,
            variable: None,
            group: DEFAULT_RSS_GROUP.to_string(),
            read: false,
            article_type: 0,
            dur_pos: 0,
        }
    }
}

/// RSS 文章数据访问层
pub struct RssArticleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RssArticleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入文章（主键冲突时替换），主键 (origin, link, sort)
    pub fn insert(&self, article: &RssArticleRecord) -> LegadoResult<()> {
        // 空分组回退为默认分组（对齐 Kotlin 实体默认值）
        let group = if article.group.is_empty() {
            DEFAULT_RSS_GROUP
        } else {
            &article.group
        };
        let link = resolve_rss_link(
            &article.origin,
            &article.title,
            &article.sort,
            article.link.as_deref(),
        );
        self.conn
            .execute(
                "INSERT OR REPLACE INTO rssArticles (origin, sort, title, \"order\", link,
                 pubDate, description, content, image, \"group\", \"read\", variable,
                 type, durPos)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    article.origin,
                    article.sort,
                    article.title,
                    article.order,
                    link,
                    article.pub_date,
                    article.description,
                    article.content,
                    article.image,
                    group,
                    article.read,
                    article.variable,
                    article.article_type,
                    article.dur_pos,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入 RSS 文章失败: {e}")))?;
        Ok(())
    }

    /// 标记文章已读状态（按 origin+title；同标题多 link 时批量更新）
    pub fn update_read(&self, origin: &str, title: &str, read: bool) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE rssArticles SET \"read\" = ?1 WHERE origin = ?2 AND title = ?3",
                params![read, origin, title],
            )
            .map_err(|e| LegadoError::Database(format!("更新 RSS 文章已读状态失败: {e}")))?;
        Ok(())
    }

    /// 按来源查询文章列表（按 order 降序）
    pub fn find_by_source(
        &self,
        source_url: &str,
        limit: i32,
    ) -> LegadoResult<Vec<RssArticleRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, sort, title, \"order\", link, pubDate, description,
                        content, image, \"group\", \"read\", variable, type, durPos
                 FROM rssArticles WHERE origin = ?1
                 ORDER BY \"order\" DESC LIMIT ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![source_url, limit], row_to_article)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 link 删除文章
    pub fn delete(&self, link: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM rssArticles WHERE link = ?1", params![link])
            .map_err(|e| LegadoError::Database(format!("删除 RSS 文章失败: {e}")))?;
        Ok(())
    }

    /// 按来源删除所有文章
    pub fn delete_by_source(&self, source_url: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "DELETE FROM rssArticles WHERE origin = ?1",
                params![source_url],
            )
            .map_err(|e| LegadoError::Database(format!("按来源删除 RSS 文章失败: {e}")))?;
        Ok(())
    }

    /// 获取文章总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM rssArticles", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

fn resolve_rss_link(origin: &str, title: &str, sort: &str, link: Option<&str>) -> String {
    match link {
        Some(l) if !l.trim().is_empty() => l.to_string(),
        _ => format!("legacy:{origin}:{title}:{sort}"),
    }
}

fn row_to_article(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssArticleRecord> {
    let link: String = row.get(4)?;
    Ok(RssArticleRecord {
        origin: row.get(0)?,
        sort: row.get(1)?,
        title: row.get(2)?,
        order: row.get(3)?,
        link: if link.is_empty() { None } else { Some(link) },
        pub_date: row.get(5)?,
        description: row.get(6)?,
        content: row.get(7)?,
        image: row.get(8)?,
        group: row.get(9)?,
        read: row.get::<_, i32>(10)? != 0,
        variable: row.get(11)?,
        article_type: row.get(12)?,
        dur_pos: row.get(13)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_article(origin: &str, title: &str, order: i64) -> RssArticleRecord {
        RssArticleRecord {
            origin: origin.to_string(),
            sort: "default".to_string(),
            title: title.to_string(),
            order,
            link: Some(format!("https://example.com/{title}")),
            pub_date: Some("2025-01-01".to_string()),
            description: Some("desc".to_string()),
            content: None,
            image: None,
            variable: None,
            ..Default::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_source() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "Article1", 1))
            .unwrap();
        repo.insert(&make_article("https://rss.com", "Article2", 2))
            .unwrap();

        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles.len(), 2);
        // order DESC
        assert_eq!(articles[0].title, "Article2");
    }

    #[test]
    fn test_insert_replace() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "Article1", 1))
            .unwrap();
        // 相同主键 (origin, link, sort) 替换
        let mut updated = make_article("https://rss.com", "Article1", 5);
        updated.description = Some("updated".to_string());
        repo.insert(&updated).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles[0].description, Some("updated".to_string()));
    }

    #[test]
    fn test_delete_by_link() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "A1", 1))
            .unwrap();
        repo.insert(&make_article("https://rss.com", "A2", 2))
            .unwrap();
        repo.delete("https://example.com/A1").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_delete_by_source() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss1.com", "A1", 1))
            .unwrap();
        repo.insert(&make_article("https://rss1.com", "A2", 2))
            .unwrap();
        repo.insert(&make_article("https://rss2.com", "B1", 1))
            .unwrap();
        repo.delete_by_source("https://rss1.com").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let remaining = repo.find_by_source("https://rss2.com", 10).unwrap();
        assert_eq!(remaining.len(), 1);
    }

    #[test]
    fn test_find_by_source_limit() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        for i in 0..10 {
            repo.insert(&make_article("https://rss.com", &format!("A{i}"), i))
                .unwrap();
        }
        let articles = repo.find_by_source("https://rss.com", 3).unwrap();
        assert_eq!(articles.len(), 3);
    }

    #[test]
    fn test_find_by_source_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        let articles = repo.find_by_source("https://nonexist.com", 10).unwrap();
        assert!(articles.is_empty());
    }

    // ─── v101 新增字段读写测试（group/read/type/durPos）────────────

    #[test]
    fn test_new_fields_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        let mut article = make_article("https://rss.com", "新字段文章", 1);
        article.group = "科技".to_string();
        article.read = true;
        article.article_type = 2;
        article.dur_pos = 42;
        repo.insert(&article).unwrap();

        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles.len(), 1);
        assert_eq!(articles[0].group, "科技");
        assert!(articles[0].read);
        assert_eq!(articles[0].article_type, 2);
        assert_eq!(articles[0].dur_pos, 42);
    }

    #[test]
    fn test_default_group_and_update_read() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        // 默认构造：group 为默认分组，未读
        repo.insert(&make_article("https://rss.com", "默认分组文章", 1))
            .unwrap();

        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles[0].group, "默认分组");
        assert!(!articles[0].read);

        // 更新已读状态
        repo.update_read("https://rss.com", "默认分组文章", true)
            .unwrap();
        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert!(articles[0].read);
    }
}
