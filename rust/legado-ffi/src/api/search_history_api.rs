//! 搜索历史 API
//!
//! 提供搜索关键词历史的增删查操作，通过 SearchKeywordRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::SearchKeywordRepository;

use crate::db_state::with_database;

/// 搜索历史条目 DTO
///
/// 序列化字段对齐 Dart `SearchKeyword` 模型：word / usage / lastUseTime
#[derive(Debug, Clone, Serialize)]
pub struct SearchHistoryItem {
    pub word: String,
    pub usage: i32,
    #[serde(rename = "lastUseTime")]
    pub last_use_time: i64,
}

/// 获取最近搜索历史（按时间降序）
pub fn get_search_history(limit: i32) -> LegadoResult<Vec<SearchHistoryItem>> {
    with_database(|db| {
        let repo = SearchKeywordRepository::new(db.connection());
        let rows = repo.find_recent(limit)?;
        Ok(rows
            .into_iter()
            .map(|(keyword, _book_name, time)| SearchHistoryItem {
                word: keyword,
                usage: 1,
                last_use_time: time,
            })
            .collect())
    })
}

/// 按前缀搜索历史关键词（用于搜索联想）
pub fn search_history_by_prefix(prefix: &str, limit: i32) -> LegadoResult<Vec<String>> {
    with_database(|db| {
        let repo = SearchKeywordRepository::new(db.connection());
        let mut results = repo.find_by_prefix(prefix)?;
        results.truncate(limit as usize);
        Ok(results)
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
        assert!(history.iter().any(|h| h.word == "斗破苍穹"));

        // 删除关键词
        assert!(delete_search_keyword("斗破苍穹").unwrap());
        let history = get_search_history(10).unwrap();
        assert!(!history.iter().any(|h| h.word == "斗破苍穹"));

        // 清空历史
        assert!(clear_search_history().unwrap());
        let history = get_search_history(10).unwrap();
        assert!(history.is_empty());
    }

    #[test]
    fn test_search_history_by_prefix() {
        crate::db_state::ensure_test_db();

        // 清空后插入测试数据
        clear_search_history().unwrap();
        add_search_keyword("斗破苍穹", "").unwrap();
        add_search_keyword("斗战神", "").unwrap();
        add_search_keyword("完美世界", "").unwrap();

        // 前缀匹配
        let results = search_history_by_prefix("斗", 20).unwrap();
        assert_eq!(results.len(), 2);

        // limit 截断
        let results = search_history_by_prefix("斗", 1).unwrap();
        assert_eq!(results.len(), 1);

        // 无匹配
        let results = search_history_by_prefix("xyz", 20).unwrap();
        assert!(results.is_empty());

        // 清理
        clear_search_history().unwrap();
    }
}
