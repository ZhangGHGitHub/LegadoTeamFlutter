//! HTTP TTS 朗读源管理 API
//!
//! 提供 HTTP TTS 源的增删改查操作，通过 HttpTtsRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::HttpTtsRepository;

use crate::db_state::with_database;

/// HTTP TTS 源 DTO
#[derive(Debug, Clone, Serialize)]
pub struct HttpTtsDto {
    pub id: i64,
    pub name: String,
    pub url: String,
    pub content_type: String,
    pub is_enabled: bool,
    pub created_at: i64,
}

/// 获取所有 HTTP TTS 源
pub fn get_http_tts_list() -> LegadoResult<Vec<HttpTtsDto>> {
    with_database(|db| {
        let repo = HttpTtsRepository::new(db.connection());
        let list = repo.find_all()?;
        Ok(list
            .into_iter()
            .map(|t| HttpTtsDto {
                id: t.id,
                name: t.name,
                url: t.url,
                content_type: t.content_type,
                is_enabled: t.is_enabled,
                created_at: t.created_at,
            })
            .collect())
    })
}

/// 添加 HTTP TTS 源，返回新 ID
pub fn add_http_tts(name: &str, url: &str) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = HttpTtsRepository::new(db.connection());
        repo.insert(name, url)
    })
}

/// 更新 HTTP TTS 源
pub fn update_http_tts(id: i64, name: &str, url: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = HttpTtsRepository::new(db.connection());
        repo.update(id, name, url)
    })
}

/// 删除 HTTP TTS 源
pub fn delete_http_tts(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = HttpTtsRepository::new(db.connection());
        repo.delete(id)
    })
}

/// 设置 HTTP TTS 源启用/禁用
pub fn set_http_tts_enabled(id: i64, enabled: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = HttpTtsRepository::new(db.connection());
        repo.set_enabled(id, enabled)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_http_tts_crud() {
        crate::db_state::ensure_test_db();

        // 添加
        let id = add_http_tts("测试TTS", "http://tts.example.com/speak").unwrap();
        assert!(id > 0);

        // 获取列表
        let list = get_http_tts_list().unwrap();
        assert!(list.iter().any(|t| t.name == "测试TTS"));

        // 更新
        assert!(update_http_tts(id, "新TTS", "http://new.tts.com").unwrap());
        let list = get_http_tts_list().unwrap();
        let tts = list.iter().find(|t| t.id == id).unwrap();
        assert_eq!(tts.name, "新TTS");

        // 禁用
        assert!(set_http_tts_enabled(id, false).unwrap());
        let list = get_http_tts_list().unwrap();
        let tts = list.iter().find(|t| t.id == id).unwrap();
        assert!(!tts.is_enabled);

        // 删除
        assert!(delete_http_tts(id).unwrap());
        let list = get_http_tts_list().unwrap();
        assert!(!list.iter().any(|t| t.id == id));
    }
}
