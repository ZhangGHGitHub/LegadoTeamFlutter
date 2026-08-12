//! 听书音频播放端点
//!
//! 提供章节列表获取、TTS 增强版语音合成、播放控制等 API。
//! `/api/audio/chapter-media` 对齐 FFI `audio_get_chapter_media`（缓存 / 卷章 / getContent）。

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::audio::{PlayMode, PlayerState};
use legado_core::cache_book::CachedChapter;
use legado_core::models::book::book_type;
use legado_core::web_book::WebChapter;
use legado_core::LegadoError;
use legado_db::{
    BookChapterRepository, BookRepository, BookSourceRepository, CacheBookRepository,
};

/// 获取章节列表请求
#[derive(Debug, Deserialize)]
pub struct ChaptersRequest {
    pub book_url: String,
}

/// 章节列表响应
#[derive(Debug, Serialize)]
pub struct ChaptersResponse {
    pub chapters: Vec<AudioChapterInfo>,
    pub total: usize,
}

/// 章节概要信息（不含完整文本，节省带宽）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioChapterInfo {
    pub index: i32,
    pub title: String,
    pub duration_estimate_ms: Option<i64>,
}

/// TTS 增强版请求
#[derive(Debug, Deserialize)]
pub struct AudioSpeakRequest {
    pub text: String,
    pub engine_url: String,
    pub voice_name: Option<String>,
    pub speed: Option<f32>,
    pub pitch: Option<f32>,
    pub volume: Option<f32>,
}

/// TTS 增强版响应
#[derive(Debug, Serialize)]
pub struct AudioSpeakResponse {
    pub audio_url: Option<String>,
    pub audio_data: Option<String>,
    pub content_type: String,
    pub text_length: usize,
    pub estimated_duration_ms: Option<i64>,
}

/// 播放控制动作
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlayAction {
    Play,
    Pause,
    Next,
    Prev,
    JumpTo { index: usize },
    SetMode { mode: PlayMode },
}

/// 章节媒体请求
#[derive(Debug, Deserialize)]
pub struct ChapterMediaRequest {
    pub book_url: String,
    pub chapter_index: i32,
}

/// 章节媒体响应（字段与 FFI `AudioChapterMedia` 对齐；保留 `duration_ms` 兼容旧客户端）
#[derive(Debug, Serialize)]
pub struct ChapterMediaResponse {
    pub media_url: Option<String>,
    pub duration_ms: Option<i64>,
    pub title: String,
    pub chapter_index: i32,
    /// 章节页 URL（兼容旧 Dart fallback 字段名 `url`）
    #[serde(rename = "url")]
    pub chapter_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resource_url: Option<String>,
    pub is_volume: bool,
    pub from_cache: bool,
    pub source_url: String,
}

/// 播放控制请求
#[derive(Debug, Deserialize)]
pub struct PlayControlRequest {
    pub action: PlayAction,
    pub book_url: Option<String>,
}

/// 播放状态响应
#[derive(Debug, Serialize)]
pub struct PlayControlResponse {
    pub state: PlayerState,
    pub current_index: Option<usize>,
    pub current_title: Option<String>,
    pub total_chapters: usize,
    pub mode: PlayMode,
}

/// POST /api/audio/chapters — 获取书籍章节列表（用于听书）
pub async fn get_chapters(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<ChaptersRequest>,
) -> Result<Json<ChaptersResponse>, ApiError> {
    // 通过 book_url 从数据库查询章节信息
    // 目前返回空列表，后续接入 legado-parser 解析
    let _ = &req.book_url;
    Ok(Json(ChaptersResponse {
        chapters: vec![],
        total: 0,
    }))
}

/// POST /api/audio/speak — 文本转语音（增强版，支持更多参数）
pub async fn speak(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<AudioSpeakRequest>,
) -> Result<Json<AudioSpeakResponse>, ApiError> {
    // 构建 TTS URL
    let encoded_text = urlencoding::encode(&req.text);
    let mut url = req.engine_url.replace("{speakText}", &encoded_text);

    if let Some(voice) = &req.voice_name {
        url = append_query(&url, "voice", voice);
    }
    if let Some(speed) = req.speed {
        url = append_query(&url, "speed", &speed.to_string());
    }
    if let Some(pitch) = req.pitch {
        url = append_query(&url, "pitch", &pitch.to_string());
    }
    if let Some(volume) = req.volume {
        url = append_query(&url, "volume", &volume.to_string());
    }

    let client = reqwest::Client::new();
    let response = client.get(&url).send().await.map_err(|e| {
        ApiError(LegadoError::Network(format!(
            "Audio TTS request failed: {}",
            e
        )))
    })?;

    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("audio/mpeg")
        .to_string();

    // 预估时长（粗略估计：每字 200ms，根据语速调整）
    let speed_factor = req.speed.unwrap_or(1.0);
    let char_count = req.text.chars().count();
    let estimated_duration_ms = Some((char_count as i64 * 200) / speed_factor.max(0.1) as i64);

    // 检查是否为音频二进制响应
    if content_type.starts_with("audio/") {
        let bytes = response.bytes().await.map_err(|e| {
            ApiError(LegadoError::Network(format!(
                "Audio read bytes failed: {}",
                e
            )))
        })?;

        use base64::{engine::general_purpose::STANDARD, Engine as _};
        let audio_data = STANDARD.encode(&bytes);

        return Ok(Json(AudioSpeakResponse {
            audio_url: None,
            audio_data: Some(audio_data),
            content_type,
            text_length: char_count,
            estimated_duration_ms,
        }));
    }

    // 非音频响应，可能是 JSON 含 audio_url
    let text = response.text().await.map_err(|e| {
        ApiError(LegadoError::Network(format!(
            "Audio read text failed: {}",
            e
        )))
    })?;

    if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&text) {
        if let Some(audio_url) = json_val.get("audio_url").and_then(|v| v.as_str()) {
            return Ok(Json(AudioSpeakResponse {
                audio_url: Some(audio_url.to_string()),
                audio_data: None,
                content_type: "audio/mpeg".to_string(),
                text_length: char_count,
                estimated_duration_ms,
            }));
        }
    }

    Ok(Json(AudioSpeakResponse {
        audio_url: Some(text),
        audio_data: None,
        content_type,
        text_length: char_count,
        estimated_duration_ms,
    }))
}

/// POST /api/audio/play — 播放控制
pub async fn play_control(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<PlayControlRequest>,
) -> Result<Json<PlayControlResponse>, ApiError> {
    // 当前为简化实现，返回状态响应
    // 完整的播放控制需要维护一个全局 AudioPlaylist 状态
    let (state, current_index, current_title, total, mode) = match req.action {
        PlayAction::Play => (PlayerState::Playing, None, None, 0, PlayMode::Sequential),
        PlayAction::Pause => (PlayerState::Paused, None, None, 0, PlayMode::Sequential),
        PlayAction::Next => (PlayerState::Playing, None, None, 0, PlayMode::Sequential),
        PlayAction::Prev => (PlayerState::Playing, None, None, 0, PlayMode::Sequential),
        PlayAction::JumpTo { index } => (
            PlayerState::Playing,
            Some(index),
            None,
            0,
            PlayMode::Sequential,
        ),
        PlayAction::SetMode { mode } => (PlayerState::Idle, None, None, 0, mode),
    };

    Ok(Json(PlayControlResponse {
        state,
        current_index,
        current_title,
        total_chapters: total,
        mode,
    }))
}

/// POST /api/audio/chapter-media — 获取章节音频媒体信息
///
/// 对齐 FFI `audio_get_chapter_media` / 原版 `AudioPlay.loadRemotePlayUrl`：
/// 查章 → 卷章短路 → DB 章节内容缓存 → 无源回退章 URL → 否则 WebBook.getContent 并写缓存。
pub async fn get_chapter_media(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ChapterMediaRequest>,
) -> Result<Json<ChapterMediaResponse>, ApiError> {
    let book_url = req.book_url.clone();
    let chapter_index = req.chapter_index;

    // 1) DB：章节 / 书籍 / 缓存 / 书源（查完即释放锁，避免持锁抓网）
    let prepared = {
        let db = state.db.lock().await;
        let ch_repo = BookChapterRepository::new(db.connection());
        let chapter = ch_repo
            .find_by_book_url_and_index(&book_url, chapter_index)?
            .ok_or_else(|| {
                LegadoError::Database(format!("章节 {chapter_index} 不存在"))
            })?;

        let resource_url = chapter.resource_url.clone();

        if chapter.is_volume {
            return Ok(Json(ChapterMediaResponse {
                media_url: None,
                duration_ms: None,
                title: chapter.title,
                chapter_index: chapter.index,
                chapter_url: chapter.url,
                resource_url,
                is_volume: true,
                from_cache: false,
                source_url: String::new(),
            }));
        }

        let book_repo = BookRepository::new(db.connection());
        let book = book_repo.find_by_url(&book_url)?.ok_or_else(|| {
            LegadoError::Database(format!("书籍 {book_url} 不存在"))
        })?;
        let source_url = book.origin.clone();

        let cache_repo = CacheBookRepository::new(db.connection());
        if let Some(cached) = cache_repo.get_by_book_and_chapter_url(&book_url, &chapter.url)? {
            let media = cached.content.trim().to_string();
            if !media.is_empty() {
                return Ok(Json(ChapterMediaResponse {
                    media_url: Some(media),
                    duration_ms: None,
                    title: chapter.title,
                    chapter_index: chapter.index,
                    chapter_url: chapter.url,
                    resource_url,
                    is_volume: false,
                    from_cache: true,
                    source_url,
                }));
            }
        }

        if source_url.is_empty() || source_url == book_type::LOCAL_TAG {
            let media = resource_url
                .as_ref()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| chapter.url.trim().to_string());
            return Ok(Json(ChapterMediaResponse {
                media_url: if media.is_empty() {
                    None
                } else {
                    Some(media)
                },
                duration_ms: None,
                title: chapter.title,
                chapter_index: chapter.index,
                chapter_url: chapter.url,
                resource_url,
                is_volume: false,
                from_cache: false,
                source_url,
            }));
        }

        let src_repo = BookSourceRepository::new(db.connection());
        let source = src_repo.find_by_url(&source_url)?.ok_or_else(|| {
            LegadoError::Database(format!("书源不存在: {source_url}"))
        })?;

        (chapter, source, source_url, resource_url)
    };

    let (chapter, source, source_url, resource_url) = prepared;
    let web_chapter = WebChapter {
        index: chapter.index,
        title: chapter.title.clone(),
        url: chapter.url.clone(),
        is_vip: chapter.is_vip,
        is_volume: chapter.is_volume,
    };

    let engine = crate::handlers::web_book::build_engine();
    let content = engine
        .get_content(&source, &web_chapter)
        .await
        .map_err(ApiError::from)?;
    let media_url = content.trim().to_string();
    if media_url.is_empty() {
        return Err(ApiError(LegadoError::ContentEmpty(
            "未获取到资源链接".into(),
        )));
    }

    // 写缓存（对齐 FFI needSave；失败仅告警）
    {
        let db = state.db.lock().await;
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let cached = CachedChapter {
            id: 0,
            book_url: book_url.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_url: chapter.url.clone(),
            content: media_url.clone(),
            cached_at: now_ms,
            size_bytes: media_url.len() as i64,
        };
        if let Err(e) = CacheBookRepository::new(db.connection()).insert(&cached) {
            tracing::warn!("音频章内容缓存写入失败（已忽略）: {e}");
        }
    }

    Ok(Json(ChapterMediaResponse {
        media_url: Some(media_url),
        duration_ms: None,
        title: chapter.title,
        chapter_index: chapter.index,
        chapter_url: chapter.url,
        resource_url,
        is_volume: false,
        from_cache: false,
        source_url,
    }))
}

/// 辅助：向 URL 追加 query 参数
fn append_query(url: &str, key: &str, value: &str) -> String {
    let encoded_value = urlencoding::encode(value);
    if url.contains('?') {
        format!("{}&{}={}", url, key, encoded_value)
    } else {
        format!("{}?{}={}", url, key, encoded_value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn make_test_router() -> axum::Router {
        let db = legado_db::init_in_memory_database().unwrap();
        let state = Arc::new(AppState {
            db: tokio::sync::Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        });
        crate::routes::create_router(state)
    }

    #[test]
    fn test_chapters_request_deserialize() {
        let json = r#"{"book_url": "https://example.com/book/1"}"#;
        let req: ChaptersRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.book_url, "https://example.com/book/1");
    }

    #[test]
    fn test_audio_speak_request_deserialize() {
        let json = r#"{
            "text": "你好世界",
            "engine_url": "https://tts.example.com/{speakText}",
            "voice_name": null,
            "speed": 1.5,
            "pitch": null,
            "volume": 0.8
        }"#;
        let req: AudioSpeakRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.text, "你好世界");
        assert_eq!(req.speed, Some(1.5));
        assert_eq!(req.volume, Some(0.8));
        assert!(req.pitch.is_none());
    }

    #[test]
    fn test_play_control_response_serialize() {
        let resp = PlayControlResponse {
            state: PlayerState::Playing,
            current_index: Some(2),
            current_title: Some("第三章".to_string()),
            total_chapters: 10,
            mode: PlayMode::Sequential,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("Playing"));
        assert!(json.contains("第三章"));
    }

    #[test]
    fn test_audio_chapter_info_serialize() {
        let info = AudioChapterInfo {
            index: 0,
            title: "第一章".to_string(),
            duration_estimate_ms: Some(60_000),
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("第一章"));
        assert!(json.contains("60000"));
    }

    #[tokio::test]
    async fn test_audio_chapters_endpoint() {
        let app = make_test_router();
        let body = serde_json::json!({"book_url": "https://example.com/book/1"});
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/audio/chapters")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_string(&body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_audio_play_endpoint() {
        let app = make_test_router();
        let body = serde_json::json!({"action": "play"});
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/audio/play")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_string(&body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[test]
    fn test_append_query_audio() {
        let url = "https://tts.example.com/speak";
        let result = append_query(url, "voice", "zh-CN");
        assert_eq!(result, "https://tts.example.com/speak?voice=zh-CN");
        let result2 = append_query(&result, "speed", "2.0");
        assert_eq!(
            result2,
            "https://tts.example.com/speak?voice=zh-CN&speed=2.0"
        );
    }

    #[tokio::test]
    async fn test_audio_chapter_media_endpoint() {
        let app = make_test_router();
        let body = serde_json::json!({
            "book_url": "https://example.com/book/1",
            "chapter_index": 0
        });
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/audio/chapter-media")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_string(&body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        // 无书时返回 Database 错误（对齐 FFI），不再返回假 Chapter 1 桩
        assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[tokio::test]
    async fn test_audio_chapter_media_volume_and_cache() {
        use legado_core::models::{Book, BookChapter};
        use legado_db::repository::Repository;

        let db = legado_db::init_in_memory_database().unwrap();
        let state = Arc::new(AppState {
            db: tokio::sync::Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        });

        let book_url = "https://audio.test/vol";
        {
            let db = state.db.lock().await;
            BookRepository::new(db.connection())
                .insert(&Book {
                    book_url: book_url.to_string(),
                    name: "听书".into(),
                    origin: String::new(),
                    ..Book::default()
                })
                .unwrap();
            BookChapterRepository::new(db.connection())
                .insert(&BookChapter {
                    url: format!("{book_url}/vol"),
                    title: "卷一".into(),
                    book_url: book_url.to_string(),
                    index: 0,
                    is_volume: true,
                    ..BookChapter::default()
                })
                .unwrap();
            BookChapterRepository::new(db.connection())
                .insert(&BookChapter {
                    url: format!("{book_url}/ch1"),
                    title: "第一章".into(),
                    book_url: book_url.to_string(),
                    index: 1,
                    ..BookChapter::default()
                })
                .unwrap();
            CacheBookRepository::new(db.connection())
                .insert(&CachedChapter {
                    id: 0,
                    book_url: book_url.to_string(),
                    chapter_index: 1,
                    chapter_title: "第一章".into(),
                    chapter_url: format!("{book_url}/ch1"),
                    content: "https://cdn.example/a.mp3".into(),
                    cached_at: 1,
                    size_bytes: 24,
                })
                .unwrap();
        }

        let app = crate::routes::create_router(state);

        let vol = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/audio/chapter-media")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "book_url": book_url,
                            "chapter_index": 0
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(vol.status(), StatusCode::OK);
        let vol_body = axum::body::to_bytes(vol.into_body(), usize::MAX)
            .await
            .unwrap();
        let vol_json: serde_json::Value = serde_json::from_slice(&vol_body).unwrap();
        assert_eq!(vol_json["title"], "卷一");
        assert_eq!(vol_json["is_volume"], true);
        assert!(vol_json["media_url"].is_null());

        let hit = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/audio/chapter-media")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "book_url": book_url,
                            "chapter_index": 1
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(hit.status(), StatusCode::OK);
        let hit_body = axum::body::to_bytes(hit.into_body(), usize::MAX)
            .await
            .unwrap();
        let hit_json: serde_json::Value = serde_json::from_slice(&hit_body).unwrap();
        assert_eq!(hit_json["media_url"], "https://cdn.example/a.mp3");
        assert_eq!(hit_json["from_cache"], true);
        assert_eq!(hit_json["title"], "第一章");
    }
}
