//! 听书音频播放端点
//!
//! 提供章节列表获取、TTS 增强版语音合成、播放控制等 API。

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::audio::{PlayMode, PlayerState};
use legado_core::LegadoError;

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

/// 章节媒体响应
#[derive(Debug, Serialize)]
pub struct ChapterMediaResponse {
    pub media_url: Option<String>,
    pub duration_ms: Option<i64>,
    pub title: String,
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
pub async fn get_chapter_media(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<ChapterMediaRequest>,
) -> Result<Json<ChapterMediaResponse>, ApiError> {
    // 完整取址在 FFI `audio_get_chapter_media`（legado-ffi audio_api）。
    // Server 进程未嵌入 FFI DB 会话时仍返回结构兼容桩；客户端请走 BookApi。
    let title = format!("Chapter {}", req.chapter_index + 1);
    Ok(Json(ChapterMediaResponse {
        media_url: None,
        duration_ms: None,
        title,
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
        assert_eq!(resp.status(), StatusCode::OK);

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(json.get("title").is_some());
        assert_eq!(json["title"], "Chapter 1");
    }
}
