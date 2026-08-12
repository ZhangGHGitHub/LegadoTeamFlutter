//! 音频播放 API
//!
//! - 播放进度读写（caches 表）
//! - 章节媒体取址（对齐 Android `AudioPlay.loadRemotePlayUrl` → `WebBook.getContent`）

use legado_core::audio::{
    resolve_audio_play_book as core_resolve_audio_play_book,
    with_audio_play_mode as core_with_audio_play_mode,
};
use legado_core::cache_book::CachedChapter;
use legado_core::models::Book;
use legado_core::web_book::WebChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{
    BookChapterRepository, BookRepository, BookSourceRepository, CacheBookRepository,
    CacheRepository,
};
use serde::Serialize;

use crate::db_state::with_database;
use crate::runtime;

/// 音频进度键前缀
const AUDIO_PROGRESS_PREFIX: &str = "audio_progress:";

/// 音频章节媒体取址结果（契约 §2.26 `getAudioChapterMedia`）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioChapterMedia {
    pub chapter_index: i32,
    pub title: String,
    /// 可播媒体地址（WebBook.getContent 正文 trim）
    pub media_url: String,
    /// 章节页 URL（兼容旧 Dart fallback 字段名 `url`）
    #[serde(rename = "url")]
    pub chapter_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resource_url: Option<String>,
    pub is_volume: bool,
    pub from_cache: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lyric: Option<String>,
    pub source_url: String,
}

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

/// 解析章节歌词（chapter.variable JSON 中的 lyric 字段）
fn lyric_from_variable(variable: &Option<String>) -> Option<String> {
    let raw = variable.as_ref()?.trim();
    if raw.is_empty() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    v.get("lyric")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
}

/// 音频章节取址（对齐 `AudioPlay.loadRemotePlayUrl` + `contentLoadFinish`）
///
/// 1. 查章节；卷章返回 `isVolume=true`、空 `mediaUrl`
/// 2. DB `cached_chapters` 命中 → 缓存正文即播放 URL（fromCache=true）
/// 3. 否则按 `book.origin` 调 WebBook.getContent（无正文规则回退章 URL）
/// 4. 成功后写入缓存；**不做**文本替换/净化（URL 会被污染）
pub fn get_audio_chapter_media(
    book_url: &str,
    chapter_index: i32,
) -> LegadoResult<AudioChapterMedia> {
    let chapter = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url_and_index(book_url, chapter_index)
    })?
    .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;

    let lyric = lyric_from_variable(&chapter.variable);
    let resource_url = chapter.resource_url.clone();

    if chapter.is_volume {
        return Ok(AudioChapterMedia {
            chapter_index: chapter.index,
            title: chapter.title.clone(),
            media_url: String::new(),
            chapter_url: chapter.url.clone(),
            resource_url,
            is_volume: true,
            from_cache: false,
            lyric,
            source_url: String::new(),
        });
    }

    let book = with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.find_by_url(book_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书籍 {book_url} 不存在")))?;

    let source_url = book.origin.clone();

    // 1) 内容缓存命中（阅读/听书 getContent 共享 cached_chapters）
    let cached = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.get_by_book_and_chapter_url(book_url, &chapter.url)
    })?;
    if let Some(cached_chapter) = cached {
        let media_url = cached_chapter.content.trim().to_string();
        if !media_url.is_empty() {
            return Ok(AudioChapterMedia {
                chapter_index: chapter.index,
                title: chapter.title.clone(),
                media_url,
                chapter_url: chapter.url.clone(),
                resource_url,
                is_volume: false,
                from_cache: true,
                lyric,
                source_url,
            });
        }
    }

    // 2) 无书源：回退 resourceUrl / 章节 URL（本地或异常数据）
    if source_url.is_empty() {
        let media_url = resource_url
            .as_ref()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| chapter.url.trim().to_string());
        return Ok(AudioChapterMedia {
            chapter_index: chapter.index,
            title: chapter.title.clone(),
            media_url,
            chapter_url: chapter.url.clone(),
            resource_url,
            is_volume: false,
            from_cache: false,
            lyric,
            source_url,
        });
    }

    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(&source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    let web_chapter = WebChapter {
        index: chapter.index,
        title: chapter.title.clone(),
        url: chapter.url.clone(),
        is_vip: chapter.is_vip,
        is_volume: chapter.is_volume,
    };

    let engine = super::web_book::build_engine();
    let content =
        runtime::block_on(async { engine.get_content(&source, &web_chapter).await })?;
    let media_url = content.trim().to_string();
    if media_url.is_empty() {
        return Err(LegadoError::ContentEmpty("未获取到资源链接".into()));
    }

    // 写入缓存（对齐 needSave=true；失败仅告警）
    save_audio_content_cache(
        book_url,
        chapter.index,
        &chapter.title,
        &chapter.url,
        &media_url,
    );

    Ok(AudioChapterMedia {
        chapter_index: chapter.index,
        title: chapter.title,
        media_url,
        chapter_url: chapter.url,
        resource_url,
        is_volume: false,
        from_cache: false,
        lyric,
        source_url,
    })
}

fn save_audio_content_cache(
    book_url: &str,
    chapter_index: i32,
    chapter_title: &str,
    chapter_url: &str,
    content: &str,
) {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let cached_chapter = CachedChapter {
        id: 0,
        book_url: book_url.to_string(),
        chapter_index,
        chapter_title: chapter_title.to_string(),
        chapter_url: chapter_url.to_string(),
        content: content.to_string(),
        cached_at: now_ms,
        size_bytes: content.len() as i64,
    };
    if let Err(e) = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.insert(&cached_chapter)?;
        Ok(())
    }) {
        log::warn!("音频章内容缓存写入失败（已忽略）: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::BookChapter;

    #[test]
    fn test_audio_progress() {
        let _db_guard = crate::db_state::ensure_test_db();

        let pos = get_audio_progress("http://book.com/audio", 0).unwrap();
        assert_eq!(pos, 0);

        assert!(save_audio_progress("http://book.com/audio", 0, 12345).unwrap());
        assert!(save_audio_progress("http://book.com/audio", 1, 67890).unwrap());

        assert_eq!(
            get_audio_progress("http://book.com/audio", 0).unwrap(),
            12345
        );
        assert_eq!(
            get_audio_progress("http://book.com/audio", 1).unwrap(),
            67890
        );

        assert!(save_audio_progress("http://book.com/audio", 0, 99999).unwrap());
        assert_eq!(
            get_audio_progress("http://book.com/audio", 0).unwrap(),
            99999
        );
    }

    #[test]
    fn test_get_audio_chapter_media_missing_chapter() {
        let _db_guard = crate::db_state::ensure_test_db();
        let err = get_audio_chapter_media("http://no-such-book", 0).unwrap_err();
        assert!(err.to_string().contains("不存在"));
    }

    #[test]
    fn test_get_audio_chapter_media_volume_short_circuit() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/volume-book";

        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            let mut book = Book::default();
            book.book_url = book_url.to_string();
            book.name = "听书卷测".into();
            book.origin = String::new();
            book_repo.insert(&book)?;

            let ch_repo = BookChapterRepository::new(db.connection());
            let mut ch = BookChapter::default();
            ch.book_url = book_url.to_string();
            ch.index = 0;
            ch.title = "第一卷".into();
            ch.url = "volume://1".into();
            ch.is_volume = true;
            ch_repo.insert(&ch)?;
            Ok(())
        })
        .unwrap();

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        assert!(media.is_volume);
        assert!(media.media_url.is_empty());
        assert_eq!(media.title, "第一卷");
    }

    #[test]
    fn test_get_audio_chapter_media_cache_hit() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/cache-book";
        let chapter_url = "http://test.audio/ch/0";
        let play_url = "https://cdn.example.com/ep0.mp3";

        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            let mut book = Book::default();
            book.book_url = book_url.to_string();
            book.name = "听书缓存".into();
            book.origin = "http://source.example/audio".into();
            book_repo.insert(&book)?;

            let ch_repo = BookChapterRepository::new(db.connection());
            let mut ch = BookChapter::default();
            ch.book_url = book_url.to_string();
            ch.index = 0;
            ch.title = "第1集".into();
            ch.url = chapter_url.to_string();
            ch.variable = Some(r#"{"lyric":"歌词A"}"#.into());
            ch_repo.insert(&ch)?;

            let cache_repo = CacheBookRepository::new(db.connection());
            cache_repo.insert(&CachedChapter {
                id: 0,
                book_url: book_url.to_string(),
                chapter_index: 0,
                chapter_title: "第1集".into(),
                chapter_url: chapter_url.to_string(),
                content: play_url.to_string(),
                cached_at: 1,
                size_bytes: play_url.len() as i64,
            })?;
            Ok(())
        })
        .unwrap();

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        assert!(media.from_cache);
        assert_eq!(media.media_url, play_url);
        assert_eq!(media.lyric.as_deref(), Some("歌词A"));
        assert!(!media.is_volume);
    }

    #[test]
    fn test_get_audio_chapter_media_no_origin_falls_back_to_chapter_url() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/local-fallback";
        let chapter_url = "https://cdn.example.com/direct.m4a";

        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            let mut book = Book::default();
            book.book_url = book_url.to_string();
            book.name = "无源听书".into();
            book.origin = String::new();
            book_repo.insert(&book)?;

            let ch_repo = BookChapterRepository::new(db.connection());
            let mut ch = BookChapter::default();
            ch.book_url = book_url.to_string();
            ch.index = 0;
            ch.title = "直链".into();
            ch.url = chapter_url.to_string();
            ch_repo.insert(&ch)?;
            Ok(())
        })
        .unwrap();

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        assert_eq!(media.media_url, chapter_url);
        assert!(!media.from_cache);
    }

    #[test]
    fn test_lyric_from_variable() {
        assert_eq!(
            lyric_from_variable(&Some(r#"{"lyric":"L1"}"#.into())).as_deref(),
            Some("L1")
        );
        assert!(lyric_from_variable(&None).is_none());
        assert!(lyric_from_variable(&Some("{}".into())).is_none());
    }
}
