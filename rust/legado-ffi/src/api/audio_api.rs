//! 音频播放 API
//!
//! - 播放进度读写（caches 表）
//! - 章节媒体取址（对齐 Android `AudioPlay.loadRemotePlayUrl` → `WebBook.getContent`）

use legado_core::audio::{
    resolve_audio_play_book as core_resolve_audio_play_book,
    with_audio_play_mode as core_with_audio_play_mode,
};
use legado_core::cache_book::CachedChapter;
use legado_core::models::{Book, BookChapter, BookSource};
use legado_core::web_book::WebChapter;
use legado_core::{LegadoError, LegadoResult};
#[cfg(test)]
use legado_db::repository::Repository; // 测试模块的 Book/BookChapter Repository::insert 需要此 trait
use legado_db::rule_big_data::RuleBigDataManager;
use legado_db::{
    BookChapterRepository, BookRepository, BookSourceRepository, CacheBookRepository,
    CacheRepository,
};
use serde::Serialize;
use std::collections::HashMap;

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
    /// 播放请求头（书源 `header` + 同站登录头合并；见 §2.26）
    ///
    /// 播放器（Dart `VideoPlayerController.networkUrl` 的 `httpHeaders`）需
    /// 携带防盗链 Referer/UA 才能拉到 segment。`None` = 无可用头（本地/直链
    /// 回退路径），`skip_serializing_if` 保持旧返回 JSON 形状不变。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub headers: Option<HashMap<String, String>>,
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
        |url| match with_database(|db| {
            legado_db::BookRepository::new(db.connection()).find_by_url(url)
        }) {
            Ok(book) => book,
            Err(e) => {
                // DB 读取异常不再静默吞错：warn 后按未缓存继续解析（行为不变）
                log::warn!("读取听书书籍缓存失败，按未缓存继续解析: {e}");
                None
            }
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

/// 解析章节歌词：variable 直存优先，未命中回退大数据文件（P2-2 收口）
///
/// 对齐原版 `RuleDataInterface.getVariable`（`variableMap[key] ?: getBigVariable(key)`，
/// `AudioPlay.kt:408` `chapter.getVariable("lyric")`）：歌词 ≥10000 字符时
/// 写入侧（`put_media_sub_content`）与弹幕同链落 `RuleBigDataHelp` 文件，
/// 读取侧必须补 File 回退，否则长歌词读不回。文件读失败降级无歌词（不抛）。
fn lyric_for_chapter(book_url: &str, chapter: &BookChapter) -> Option<String> {
    if let Some(inline) = lyric_from_variable(&chapter.variable) {
        return Some(inline);
    }
    let manager = RuleBigDataManager::new(&super::video_api::rule_data_dir());
    match manager.get_chapter_variable(book_url, &chapter.url, super::video_api::LYRIC_KEY) {
        Ok(Some(content)) if !content.is_empty() => Some(content),
        Ok(_) => None,
        Err(e) => {
            log::warn!("[audio_lyric] 大数据歌词文件读取失败（降级无歌词）: {e}");
            None
        }
    }
}

/// 解析播放请求头（书源 `header` ⊕ 同站登录头）
///
/// 播放器（ExoPlayer/video_player）取 HLS 主清单与分片时需带防盗链
/// Referer/UA：原版 `AudioPlay` 用 `WebBook.getContent` 返回的 `AnalyzeUrl`
/// 携带 headerMap 起播，我方 `mediaUrl` 只回传裸地址，故此处把书源请求头
/// 随 `AudioChapterMedia.headers` 一并返回。
///
/// 合并语义与书源抓取链同源（`SourceHeaderSet::for_request`，见
/// `image_api::fetch_image_with_decode` 同款先例）：
/// - 静态头 = `BookSource.header` JSON；
/// - 登录头**仅当播放地址与书源同站（eTLD+1）时**附加（原版 #1099
///   `AnalyzeUrl.isLoginHeaderSite`：媒体常托管第三方 CDN，跨域不送认证头；
///   无法判定域名时保持旧行为附加）；
/// - `proxy` 键是代理配置而非 HTTP 头，合并后剔除（同 `strip_proxy_header`）；
/// - 内部 CookieJar 写侧标记头**不**回传（`legado-net` 发送前剥离；交给
///   Dart 播放器只会把内部头泄漏出去）。
///
/// 空结果返回 `None`（保持旧 JSON 形状）。
fn playback_headers(source: &BookSource, play_url: &str) -> Option<HashMap<String, String>> {
    let mut headers: HashMap<String, String> = source
        .header
        .as_deref()
        .and_then(|h| serde_json::from_str(h).ok())
        .unwrap_or_default();

    if legado_fetcher::web_book::is_login_header_site(&source.book_source_url, play_url, None) {
        if let Some(login_header_json) =
            crate::api::source_login_cache::get_login_header(&source.book_source_url)
        {
            if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(&login_header_json) {
                headers.extend(map);
            }
        }
    }

    legado_fetcher::web_book::strip_proxy_header(&mut headers);
    headers.retain(|key, _| !key.eq_ignore_ascii_case(legado_net::COOKIE_JAR_HEADER));

    if headers.is_empty() {
        None
    } else {
        Some(headers)
    }
}

/// 按书源 URL 解析播放请求头（源缺失/DB 异常 → 无头，播放不受阻断）
fn playback_headers_for_source(
    source_url: &str,
    play_url: &str,
) -> Option<HashMap<String, String>> {
    if source_url.trim().is_empty() {
        return None;
    }
    let source =
        with_database(|db| BookSourceRepository::new(db.connection()).find_by_url(source_url))
            .ok()
            .flatten()?;
    playback_headers(&source, play_url)
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

    let lyric = lyric_for_chapter(book_url, &chapter);
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
            headers: None,
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
            // 缓存正文是**远程播放地址**（不是本地文件），防盗链头同样需要
            let headers = playback_headers_for_source(&source_url, &media_url);
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
                headers,
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
            headers: None,
        });
    }

    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(&source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // [T4 | RuleDataInterface] 听书链同步内容链变量合并：book.variable ⊕
    // chapter.variable（章节优先），保证 token/host 类书级变量可达正文请求
    let book_variable: Option<String> = with_database(|db| {
        Ok(BookRepository::new(db.connection())
            .find_by_url(book_url)?
            .and_then(|b| b.variable))
    })?;
    let merged_variable = super::web_book::merge_variables_json(
        book_variable.as_deref(),
        chapter.variable.as_deref(),
    );

    let web_chapter = WebChapter {
        index: chapter.index,
        title: chapter.title.clone(),
        url: chapter.url.clone(),
        is_vip: chapter.is_vip,
        // P1-1：透传 DB 章节卷章/付费标记与章节附加信息
        is_volume: chapter.is_volume,
        is_pay: chapter.is_pay,
        tag: chapter.tag.clone(),
        variable: merged_variable,
        word_count: None,
    };

    let engine = super::web_book::build_engine()?;
    let content = runtime::block_on(async { engine.get_content(&source, &web_chapter).await })?;
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

    let headers = playback_headers(&source, &media_url);

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
        headers,
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
            let book = Book {
                book_url: book_url.to_string(),
                name: "听书卷测".into(),
                origin: String::new(),
                ..Default::default()
            };
            book_repo.insert(&book)?;

            let ch_repo = BookChapterRepository::new(db.connection());
            let ch = BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: "第一卷".into(),
                url: "volume://1".into(),
                is_volume: true,
                ..Default::default()
            };
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
            let book = Book {
                book_url: book_url.to_string(),
                name: "听书缓存".into(),
                origin: "http://source.example/audio".into(),
                ..Default::default()
            };
            book_repo.insert(&book)?;

            let ch_repo = BookChapterRepository::new(db.connection());
            let ch = BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: "第1集".into(),
                url: chapter_url.to_string(),
                variable: Some(r#"{"lyric":"歌词A"}"#.into()),
                ..Default::default()
            };
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
            let book = Book {
                book_url: book_url.to_string(),
                name: "无源听书".into(),
                origin: String::new(),
                ..Default::default()
            };
            book_repo.insert(&book)?;

            let ch_repo = BookChapterRepository::new(db.connection());
            let ch = BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: "直链".into(),
                url: chapter_url.to_string(),
                ..Default::default()
            };
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

    /// 临时规则数据目录 env 守卫（Drop 恢复原值）
    ///
    /// 本模块测试与 video_api 测试同持 `ensure_test_db` 串行锁，env 不会被
    /// 并发改写；锁序遵循 test_support 全局锁序不变式。
    struct LyricRuleDataDirGuard {
        dir: std::path::PathBuf,
        prev: Option<String>,
    }

    impl LyricRuleDataDirGuard {
        fn new() -> Self {
            let dir = std::env::temp_dir()
                .join(format!("legado_audio_lyric_test_{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            let prev = std::env::var(crate::api::video_api::RULE_DATA_DIR_ENV).ok();
            std::env::set_var(crate::api::video_api::RULE_DATA_DIR_ENV, &dir);
            Self { dir, prev }
        }
    }

    impl Drop for LyricRuleDataDirGuard {
        fn drop(&mut self) {
            match &self.prev {
                Some(v) => std::env::set_var(crate::api::video_api::RULE_DATA_DIR_ENV, v),
                None => std::env::remove_var(crate::api::video_api::RULE_DATA_DIR_ENV),
            }
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// [P2-2] ≥10000 字符歌词落大数据文件后应能读回：
    /// `getAudioChapterMedia` 的 lyric 须补 File 回退
    /// （对齐原版 `RuleDataInterface.getVariable` = variableMap[key] ?:
    /// getBigVariable(key)，`AudioPlay.kt:408`）。
    #[test]
    fn test_get_audio_chapter_media_large_lyric_file_fallback() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _rule_dir = LyricRuleDataDirGuard::new();
        let book_url = "http://test.audio/large-lyric-book";
        let chapter_url = "http://test.audio/ch/large-lyric";
        let big_lyric = "词".repeat(10000); // UTF-16 10000 → 写入侧走大文件分支

        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            book_repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "长歌词听书".into(),
                origin: String::new(), // 无书源 → 取址走章 URL 回退，不触网
                ..Default::default()
            })?;
            let ch_repo = BookChapterRepository::new(db.connection());
            ch_repo.insert(&BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: "第1集".into(),
                url: chapter_url.to_string(),
                ..Default::default()
            })?;
            Ok(())
        })
        .unwrap();

        // 经捕获落库（写侧与弹幕同链分流）：≥10000 → lyric 落大数据文件
        crate::api::video_api::put_media_sub_content(
            book_url,
            chapter_url,
            crate::api::video_api::LYRIC_KEY,
            &big_lyric,
        );
        let file = legado_db::rule_big_data::RuleBigDataManager::new(
            &crate::api::video_api::rule_data_dir(),
        )
        .chapter_variable_path(book_url, chapter_url, crate::api::video_api::LYRIC_KEY);
        assert!(file.is_file(), "长歌词应落大数据文件: {file:?}");

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        assert_eq!(
            media.lyric.as_deref(),
            Some(big_lyric.as_str()),
            "variable 未命中时应回退大数据文件读回长歌词"
        );
    }

    // ─── 播放请求头（§2.26 headers 字段，批 1）──────────────────────────────

    /// 播种「音频书 + 单章 + 内容缓存命中」的最小数据集
    ///
    /// 走缓存命中路径（不触网），`play_url` 即缓存正文（远程播放地址）。
    fn seed_cached_audio_book(book_url: &str, source_url: &str, chapter_url: &str, play_url: &str) {
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.to_string(),
                name: "听书头测试".into(),
                origin: source_url.to_string(),
                ..Default::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: "第1集".into(),
                url: chapter_url.to_string(),
                ..Default::default()
            })?;
            CacheBookRepository::new(db.connection()).insert(&CachedChapter {
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
    }

    fn seed_source(source_url: &str, header_json: Option<&str>) {
        with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "听书源".into(),
                header: header_json.map(str::to_string),
                ..Default::default()
            })
        })
        .unwrap();
    }

    /// 书源 header 必须随返回 JSON 一并回传（播放器靠它过防盗链）
    #[test]
    fn test_audio_chapter_media_returns_source_headers() {
        let _store = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/headers-book";
        let source_url = "http://test.audio/headers-source";
        let chapter_url = "http://test.audio/headers-ch/0";
        let play_url = "http://test.audio/headers-cdn/ep0.m3u8?token=t";

        seed_source(
            source_url,
            Some(r#"{"Referer":"http://test.audio/","X-Token":"abc"}"#),
        );
        seed_cached_audio_book(book_url, source_url, chapter_url, play_url);

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        let headers = media
            .headers
            .as_ref()
            .expect("书源 header 应随返回 JSON 回传");
        assert_eq!(
            headers.get("Referer").map(String::as_str),
            Some("http://test.audio/")
        );
        assert_eq!(headers.get("X-Token").map(String::as_str), Some("abc"));

        // 序列化形态：JSON 键名 `headers`，且旧字段不受影响
        let json = serde_json::to_value(&media).unwrap();
        assert_eq!(json["headers"]["X-Token"], "abc");
        assert_eq!(json["mediaUrl"], play_url);
    }

    /// 同站登录头合并进播放头（覆盖同名键，对齐 loginHeader 在后）
    #[test]
    fn test_audio_chapter_media_merges_same_site_login_header() {
        let _store = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/login-book";
        let source_url = "http://test.audio/login-source";
        let chapter_url = "http://test.audio/login-ch/0";
        // 播放地址与书源同站（test.audio）
        let play_url = "http://test.audio/login-cdn/ep0.m3u8";

        seed_source(
            source_url,
            Some(r#"{"X-Token":"static","Referer":"http://test.audio/"}"#),
        );
        seed_cached_audio_book(book_url, source_url, chapter_url, play_url);
        crate::api::source_login_cache::put_login_header(
            source_url,
            r#"{"X-Token":"login","Authorization":"Bearer t"}"#,
        )
        .unwrap();

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        let headers = media.headers.expect("同站播放应合并登录头");
        assert_eq!(
            headers.get("X-Token").map(String::as_str),
            Some("login"),
            "登录头应在书源静态头之后合并（同名覆盖）"
        );
        assert_eq!(
            headers.get("Authorization").map(String::as_str),
            Some("Bearer t")
        );
        assert_eq!(
            headers.get("Referer").map(String::as_str),
            Some("http://test.audio/"),
            "静态头未被登录头覆盖的键应保留"
        );

        crate::api::source_login_cache::remove_login_header(source_url).unwrap();
    }

    /// 跨站播放地址（第三方 CDN）不得携带登录头（原版 #1099 同站门控）
    #[test]
    fn test_audio_chapter_media_omits_login_header_for_cross_site_url() {
        let _store = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/cross-book";
        let source_url = "http://test.audio/cross-source";
        let chapter_url = "http://test.audio/cross-ch/0";
        // 播放地址在第三方 CDN（不同 eTLD+1）
        let play_url = "http://cdn.other-domain.net/cross/ep0.m3u8";

        seed_source(source_url, Some(r#"{"Referer":"http://test.audio/"}"#));
        seed_cached_audio_book(book_url, source_url, chapter_url, play_url);
        crate::api::source_login_cache::put_login_header(
            source_url,
            r#"{"Authorization":"Bearer secret"}"#,
        )
        .unwrap();

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        let headers = media.headers.expect("静态头仍应回传");
        assert!(
            !headers.contains_key("Authorization"),
            "跨站播放地址不得携带登录认证头: {headers:?}"
        );
        assert_eq!(
            headers.get("Referer").map(String::as_str),
            Some("http://test.audio/")
        );

        crate::api::source_login_cache::remove_login_header(source_url).unwrap();
    }

    /// `proxy`（代理配置伪头）与内部 CookieJar 标记头都不得进播放头
    #[test]
    fn test_audio_chapter_media_strips_proxy_and_cookie_jar_marker() {
        let _store = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/strip-book";
        let source_url = "http://test.audio/strip-source";
        let chapter_url = "http://test.audio/strip-ch/0";
        let play_url = "http://test.audio/strip-cdn/ep0.mp3";

        seed_source(
            source_url,
            Some(r#"{"proxy":"http://u:p@h:1","CookieJar":"1","X-Keep":"v"}"#),
        );
        seed_cached_audio_book(book_url, source_url, chapter_url, play_url);

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        let headers = media.headers.expect("其余头应回传");
        assert!(
            !headers.contains_key("proxy"),
            "代理配置键不得当 HTTP 头: {headers:?}"
        );
        assert!(
            !headers.keys().any(|k| k.eq_ignore_ascii_case("cookiejar")),
            "内部 CookieJar 标记头不得泄漏给播放器: {headers:?}"
        );
        assert_eq!(headers.get("X-Keep").map(String::as_str), Some("v"));
    }

    /// 无书源 header 时 `headers` 键整体省略（旧 JSON 形状不变）
    #[test]
    fn test_audio_chapter_media_omits_headers_key_when_absent() {
        let _store = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/no-headers-book";
        let source_url = "http://test.audio/no-headers-source";
        let chapter_url = "http://test.audio/no-headers-ch/0";
        let play_url = "http://test.audio/no-headers-cdn/ep0.mp3";

        seed_source(source_url, None);
        seed_cached_audio_book(book_url, source_url, chapter_url, play_url);

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        assert!(media.headers.is_none());
        let json = serde_json::to_value(&media).unwrap();
        assert!(
            json.get("headers").is_none(),
            "无头时不得输出 headers 键（保持旧返回形状）: {json}"
        );
    }

    /// 无书源回退路径（origin 为空）不得编造 headers
    #[test]
    fn test_audio_chapter_media_no_source_has_no_headers() {
        let _store = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://test.audio/fallback-no-headers";
        let chapter_url = "http://test.audio/fallback-ch/0";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.to_string(),
                name: "无源听书".into(),
                origin: String::new(),
                ..Default::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: "第1集".into(),
                url: chapter_url.to_string(),
                ..Default::default()
            })?;
            Ok(())
        })
        .unwrap();

        let media = get_audio_chapter_media(book_url, 0).unwrap();
        assert!(media.headers.is_none());
    }
}
