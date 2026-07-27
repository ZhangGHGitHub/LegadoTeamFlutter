//! RssStar Repository - rssStars 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 收藏记录
#[derive(Debug, Clone, Default)]
pub struct RssStarRecord {
    pub origin: String,
    pub sort: String,
    pub title: String,
    pub star_time: i64,
    pub link: Option<String>,
    pub pub_date: Option<String>,
    pub description: Option<String>,
    pub content: Option<String>,
    pub image: Option<String>,
    pub variable: Option<String>,
}

/// RSS 收藏数据访问层
pub struct RssStarRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RssStarRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 添加收藏（主键冲突时替换）
    pub fn add_star(&self, star: &RssStarRecord) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO rssStars (origin, sort, title, starTime, link,
                 pubDate, description, content, image, variable)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    star.origin,
                    star.sort,
                    star.title,
                    star.star_time,
                    star.link,
                    star.pub_date,
                    star.description,
                    star.content,
                    star.image,
                    star.variable,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("添加收藏失败: {e}")))?;
        Ok(())
    }

    /// 取消收藏（按 link 删除）
    pub fn remove_star(&self, link: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM rssStars WHERE link = ?1", params![link])
            .map_err(|e| LegadoError::Database(format!("取消收藏失败: {e}")))?;
        Ok(())
    }

    /// 判断是否已收藏（按 link 匹配）
    pub fn is_starred(&self, link: &str) -> LegadoResult<bool> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rssStars WHERE link = ?1",
                params![link],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询收藏状态失败: {e}")))?;
        Ok(count > 0)
    }

    /// 获取所有收藏（按 starTime 降序）
    pub fn find_all(&self) -> LegadoResult<Vec<RssStarRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, sort, title, starTime, link, pubDate, description,
                        content, image, variable
                 FROM rssStars ORDER BY starTime DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_star)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取收藏总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM rssStars", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

fn row_to_star(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssStarRecord> {
    Ok(RssStarRecord {
        origin: row.get(0)?,
        sort: row.get(1)?,
        title: row.get(2)?,
        star_time: row.get(3)?,
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

    fn make_star(origin: &str, title: &str, time: i64) -> RssStarRecord {
        RssStarRecord {
            origin: origin.to_string(),
            sort: "default".to_string(),
            title: title.to_string(),
            star_time: time,
            link: Some(format!("https://link.com/{title}")),
            pub_date: Some("2025-01-01".to_string()),
            description: Some("starred".to_string()),
            content: None,
            image: None,
            variable: None,
        }
    }

    #[test]
    fn test_add_star_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssStarRepository::new(db.connection());
        repo.add_star(&make_star("https://rss.com", "S1", 100))
            .unwrap();
        repo.add_star(&make_star("https://rss.com", "S2", 200))
            .unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        // starTime DESC
        assert_eq!(all[0].title, "S2");
    }

    #[test]
    fn test_remove_star() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssStarRepository::new(db.connection());
        repo.add_star(&make_star("https://rss.com", "S1", 100))
            .unwrap();
        repo.add_star(&make_star("https://rss.com", "S2", 200))
            .unwrap();
        repo.remove_star("https://link.com/S1").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        assert!(!repo.is_starred("https://link.com/S1").unwrap());
    }

    #[test]
    fn test_is_starred() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssStarRepository::new(db.connection());
        repo.add_star(&make_star("https://rss.com", "S1", 100))
            .unwrap();

        assert!(repo.is_starred("https://link.com/S1").unwrap());
        assert!(!repo.is_starred("https://link.com/S99").unwrap());
    }

    #[test]
    fn test_add_star_replace() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssStarRepository::new(db.connection());
        repo.add_star(&make_star("https://rss.com", "S1", 100))
            .unwrap();
        // 相同主键 (origin, title) 替换
        let mut updated = make_star("https://rss.com", "S1", 300);
        updated.description = Some("updated star".to_string());
        repo.add_star(&updated).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].description, Some("updated star".to_string()));
        assert_eq!(all[0].star_time, 300);
    }

    #[test]
    fn test_find_all_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssStarRepository::new(db.connection());
        let all = repo.find_all().unwrap();
        assert!(all.is_empty());
    }
}
