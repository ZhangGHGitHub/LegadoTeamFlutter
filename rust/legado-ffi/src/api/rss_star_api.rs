//! RSS 收藏管理 API
//!
//! 提供 RSS 文章收藏的增删查操作，通过 RssStarRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::{RssStarRecord, RssStarRepository};

use crate::db_state::with_database;

/// RSS 收藏 DTO（可序列化）
#[derive(Debug, Clone, Serialize)]
pub struct RssStarDto {
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

impl From<RssStarRecord> for RssStarDto {
    fn from(r: RssStarRecord) -> Self {
        Self {
            origin: r.origin,
            sort: r.sort,
            title: r.title,
            star_time: r.star_time,
            link: r.link,
            pub_date: r.pub_date,
            description: r.description,
            content: r.content,
            image: r.image,
            variable: r.variable,
        }
    }
}

/// 获取所有 RSS 收藏（按 starTime 降序）
pub fn get_rss_stars() -> LegadoResult<Vec<RssStarDto>> {
    with_database(|db| {
        let repo = RssStarRepository::new(db.connection());
        let records = repo.find_all()?;
        Ok(records.into_iter().map(RssStarDto::from).collect())
    })
}

/// 添加 RSS 收藏，返回收藏时间戳（作为标识）
pub fn add_rss_star(source_url: &str, title: &str, link: &str) -> LegadoResult<i64> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let record = RssStarRecord {
        origin: source_url.to_string(),
        sort: "default".to_string(),
        title: title.to_string(),
        star_time: now,
        link: Some(link.to_string()),
        pub_date: None,
        description: None,
        content: None,
        image: None,
        variable: None,
    };

    with_database(|db| {
        let repo = RssStarRepository::new(db.connection());
        repo.add_star(&record)?;
        Ok(now)
    })
}

/// 取消 RSS 收藏（按 link 删除）
pub fn delete_rss_star(link: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssStarRepository::new(db.connection());
        repo.remove_star(link)?;
        Ok(true)
    })
}

/// 判断是否已收藏（按 link 匹配）
pub fn is_rss_starred(link: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssStarRepository::new(db.connection());
        repo.is_starred(link)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rss_star_crud() {
        crate::db_state::ensure_test_db();

        // 添加收藏
        let ts = add_rss_star("https://rss.example.com", "Test Article", "https://link.com/1")
            .unwrap();
        assert!(ts > 0);

        // 判断已收藏
        assert!(is_rss_starred("https://link.com/1").unwrap());
        assert!(!is_rss_starred("https://link.com/999").unwrap());

        // 获取列表
        let stars = get_rss_stars().unwrap();
        assert!(stars.iter().any(|s| s.title == "Test Article"));

        // 删除收藏
        assert!(delete_rss_star("https://link.com/1").unwrap());
        assert!(!is_rss_starred("https://link.com/1").unwrap());
    }
}
