//! RssArticle Repository - rssArticles 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 文章记录
#[derive(Debug, Clone, Default)]
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
}

/// RSS 文章数据访问层
pub struct RssArticleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RssArticleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入文章（主键冲突时替换）
    pub fn insert(&self, article: &RssArticleRecord) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO rssArticles (origin, sort, title, \"order\", link,
                 pubDate, description, content, image, variable)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    article.origin,
                    article.sort,
                    article.title,
                    article.order,
                    article.link,
                    article.pub_date,
                    article.description,
                    article.content,
                    article.image,
                    article.variable,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入 RSS 文章失败: {e}")))?;
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
                        content, image, variable
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

fn row_to_article(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssArticleRecord> {
    Ok(RssArticleRecord {
        origin: row.get(0)?,
        sort: row.get(1)?,
        title: row.get(2)?,
        order: row.get(3)?,
        link: row.get(4)?,
        pub_date: row.get(5)?,
        description: row.get(6)?,
        content: row.get(7)?,
        image: row.get(8)?,
        variable: row.get(9)?,
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
        // 相同主键 (origin, title) 替换
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
}
