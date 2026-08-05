//! 音频播放进度 API
//!
//! 提供音频播放进度的读写操作，基于 caches 表存储。

use legado_core::audio::{
    resolve_audio_play_book as core_resolve_audio_play_book,
    with_audio_play_mode as core_with_audio_play_mode,
};
use legado_core::models::Book;
use legado_core::LegadoResult;
use legado_db::CacheRepository;

use crate::db_state::with_database;

/// 音频进度键前缀
const AUDIO_PROGRESS_PREFIX: &str = "audio_progress:";

/// 获取音频播放进度（毫秒），无记录返回 0
pub fn get_audio_progress(book_url: &str, chapter_index: i32) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let key = format!("{}{}:{}", AUDIO_PROGRESS_PREFIX, book_url, chapter_index);
        match repo.get(&key)? {
            Some(val) => Ok(val.parse::<i64>().unwrap_or(0)),
            None => Ok(0),
        }
    })
}

/// 保存音频播放进度（毫秒）
pub fn save_audio_progress(
    book_url: &str,
    chapter_index: i32,
    position: i64,
) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let key = format!("{}{}:{}", AUDIO_PROGRESS_PREFIX, book_url, chapter_index);
        repo.put(&key, &position.to_string(), 0)?; // 永不过期
        Ok(true)
    })
}

/// 将播放模式写入 readConfig JSON（对应 Kotlin `String?.withAudioPlayMode`）
///
/// 读取现有 readConfig JSON，设置 playMode 字段，返回更新后的 JSON 字符串。
/// `read_config` 为空或非法 JSON 时返回仅含 playMode 的新对象。
pub fn with_audio_play_mode(read_config: Option<&str>, play_mode: i32) -> String {
    core_with_audio_play_mode(read_config, play_mode)
}

/// 解析听书书籍（对应 Kotlin `resolveAudioPlayBook`）
///
/// 用于修复听书通知恢复错误书籍的问题：
/// - 请求 bookUrl 为空时返回缓存书籍（如果有效）
/// - 缓存书籍 URL 与请求匹配时直接返回缓存
/// - 否则按 URL 从数据库查找正确的书籍
///
/// `cached_book_json` 为缓存书籍的 JSON（含 bookUrl 字段），可为空。
/// 返回解析到的书籍，未找到时为 None。
pub fn resolve_audio_play_book(
    requested_book_url: Option<&str>,
    cached_book_json: Option<&str>,
) -> LegadoResult<Option<Book>> {
    let cached: Option<Book> = match cached_book_json {
        Some(json) if !json.trim().is_empty() => serde_json::from_str(json)?,
        _ => None,
    };
    let resolved = core_resolve_audio_play_book(
        requested_book_url,
        cached,
        |b| b.book_url.as_str(),
        |url| {
            with_database(|db| legado_db::BookRepository::new(db.connection()).find_by_url(url))
                .ok()
                .flatten()
        },
    );
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_audio_progress() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 无记录时返回 0
        let pos = get_audio_progress("http://book.com/audio", 0).unwrap();
        assert_eq!(pos, 0);

        // 保存进度
        assert!(save_audio_progress("http://book.com/audio", 0, 12345).unwrap());
        assert!(save_audio_progress("http://book.com/audio", 1, 67890).unwrap());

        // 读取进度
        assert_eq!(
            get_audio_progress("http://book.com/audio", 0).unwrap(),
            12345
        );
        assert_eq!(
            get_audio_progress("http://book.com/audio", 1).unwrap(),
            67890
        );

        // 更新进度
        assert!(save_audio_progress("http://book.com/audio", 0, 99999).unwrap());
        assert_eq!(
            get_audio_progress("http://book.com/audio", 0).unwrap(),
            99999
        );
    }
}
