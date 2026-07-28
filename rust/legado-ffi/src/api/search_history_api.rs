//! 搜索历史 API
//!
//! 提供搜索关键词历史的增删查操作，通过 SearchKeywordRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::SearchKeywordRepository;

use crate::db_state::with_database;

/// 搜索历史条目 DTO
#[derive(Debug, Clone, Serialize)]
pub struct SearchHistoryItem {
    pub keyword: String,
    pub book_name: String,
    pub time: i64,
}

/// 获取最近搜索历史（按时间降序）
pub fn get_search_history(limit: i32) -> LegadoResult<Vec<SearchHistoryItem>> {
    with_database(|db| {
        let repo = SearchKeywordRepository::new(db.connection());
        let rows = repo.find_recent(limit)?;
        Ok(rows
            .into_iter()
            .map(|(keyword, book_name, time)| SearchHistoryItem {
                keyword,
                book_name,
                time,
            })
            .collect())
    })
}

/// 添加搜索关键词（自动去重），返回当前时间戳
pub fn add_search_keyword(keyword: &str, book_name: &str) -> LegadoResult<i64> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    with_database(|db| {
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert(keyword, book_name)?;
        Ok(now)
    })
}

/// 删除搜索关键词（按关键词文本匹配）
pub fn delete_search_keyword(keyword: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = SearchKeywordRepository::new(db.connection());
        repo.delete(keyword)?;
        Ok(true)
    })
}

/// 清空所有搜索历史
pub fn clear_search_history() -> LegadoResult<bool> {
    with_database(|db| {
        let repo = SearchKeywordRepository::new(db.connection());
        repo.clear_all()?;
        Ok(true)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_search_history_crud() {
        crate::db_state::ensure_test_db();

        // 添加关键词
        let ts = add_search_keyword("斗破苍穹", "").unwrap();
        assert!(ts > 0);
        add_search_keyword("完美世界", "").unwrap();

        // 获取历史
        let history = get_search_history(10).unwrap();
        assert!(history.len() >= 2);
        assert!(history.iter().any(|h| h.keyword == "斗破苍穹"));

        // 删除关键词
        assert!(delete_search_keyword("斗破苍穹").unwrap());
        let history = get_search_history(10).unwrap();
        assert!(!history.iter().any(|h| h.keyword == "斗破苍穹"));

        // 清空历史
        assert!(clear_search_history().unwrap());
        let history = get_search_history(10).unwrap();
        assert!(history.is_empty());
    }
}
