//! 音频播放进度 API
//!
//! 提供音频播放进度的读写操作，基于 caches 表存储。

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
pub fn save_audio_progress(book_url: &str, chapter_index: i32, position: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let key = format!("{}{}:{}", AUDIO_PROGRESS_PREFIX, book_url, chapter_index);
        repo.put(&key, &position.to_string(), 0)?; // 永不过期
        Ok(true)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_audio_progress() {
        crate::db_state::ensure_test_db();

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
