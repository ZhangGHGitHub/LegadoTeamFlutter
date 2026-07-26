//! HTTP TTS 文本转语音端点
//!
//! 参考 Kotlin 实现 `HttpTTS.kt`，通过 HTTP 请求外部 TTS 引擎将文本转换为语音。

use axum::extract::State;
use axum::Json;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::LegadoError;

/// TTS 请求体
#[derive(Debug, Deserialize)]
pub struct TtsRequest {
    /// 要朗读的文本
    pub text: String,
    /// TTS 引擎 URL 模板（含 `{speakText}` 占位符）
    pub engine_url: String,
    /// 语音名称（可选）
    pub voice_name: Option<String>,
    /// 语速（可选，0.5 ~ 2.0）
    pub speed: Option<f32>,
    /// 音调（可选，0.5 ~ 2.0）
    pub pitch: Option<f32>,
    /// 音量（可选，0 ~ 100）
    pub volume: Option<i32>,
}

/// TTS 响应体
#[derive(Debug, Serialize)]
pub struct TtsResponse {
    /// 如果 TTS 返回音频 URL
    pub audio_url: Option<String>,
    /// Base64 编码的音频数据
    pub audio_data: Option<String>,
    /// 音频 MIME 类型：audio/mpeg, audio/wav 等
    pub content_type: String,
}

/// POST /api/tts/speak — 将文本转换为语音
///
/// 1. 构建 TTS 请求 URL（替换 `{speakText}` 占位符）
/// 2. 通过 reqwest 发送 GET 请求获取音频二进制数据
/// 3. 将音频字节进行 Base64 编码返回
pub async fn speak(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<TtsRequest>,
) -> Result<Json<TtsResponse>, ApiError> {
    // 构建 TTS URL：替换 {speakText} 占位符
    let encoded_text = urlencoding::encode(&req.text);
    let mut url = req.engine_url.replace("{speakText}", &encoded_text);

    // 可选参数：附加到 URL query string
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

    // 使用 reqwest 发送请求获取音频字节
    let client = reqwest::Client::new();
    let response = client
        .get(&url)
        .send()
        .await
        .map_err(|e| ApiError(LegadoError::Network(format!("TTS request failed: {}", e))))?;

    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("audio/mpeg")
        .to_string();

    // 检查是否是重定向到音频 URL（某些 TTS 引擎返回 Location 头）
    if content_type.starts_with("text/") || content_type.starts_with("application/json") {
        // 可能返回的是 JSON 或文本，检查是否有音频 URL
        let text = response.text().await.map_err(|e| {
            ApiError(LegadoError::Network(format!(
                "TTS read response failed: {}",
                e
            )))
        })?;

        // 尝试解析为 JSON 提取 audio_url
        if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(audio_url) = json_val.get("audio_url").and_then(|v| v.as_str()) {
                return Ok(Json(TtsResponse {
                    audio_url: Some(audio_url.to_string()),
                    audio_data: None,
                    content_type: "audio/mpeg".to_string(),
                }));
            }
        }

        // 非音频响应，直接返回文本作为 URL
        return Ok(Json(TtsResponse {
            audio_url: Some(text),
            audio_data: None,
            content_type,
        }));
    }

    let bytes = response.bytes().await.map_err(|e| {
        ApiError(LegadoError::Network(format!(
            "TTS read bytes failed: {}",
            e
        )))
    })?;

    // Base64 编码音频数据
    let audio_data = STANDARD.encode(&bytes);

    Ok(Json(TtsResponse {
        audio_url: None,
        audio_data: Some(audio_data),
        content_type,
    }))
}

/// TTS 引擎配置
#[derive(Debug, Serialize)]
pub struct TtsEngine {
    pub name: String,
    pub url_template: String,
}

/// GET /api/tts/engines — 列出可用的 TTS 引擎配置
///
/// 当前返回预设引擎列表，后续可从数据库查询。
pub async fn list_engines(
    State(_state): State<Arc<AppState>>,
) -> Result<Json<Vec<TtsEngine>>, ApiError> {
    // 预设 TTS 引擎示例（后续可从 DB http_tts 表加载）
    let engines = vec![TtsEngine {
        name: "示例 TTS 引擎".to_string(),
        url_template: "https://tts.example.com/speak?text={speakText}".to_string(),
    }];
    Ok(Json(engines))
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

    #[test]
    fn test_append_query_no_existing_params() {
        let url = "https://example.com/tts";
        let result = append_query(url, "voice", "en-US");
        assert_eq!(result, "https://example.com/tts?voice=en-US");
    }

    #[test]
    fn test_append_query_with_existing_params() {
        let url = "https://example.com/tts?text=hello";
        let result = append_query(url, "speed", "1.5");
        assert_eq!(result, "https://example.com/tts?text=hello&speed=1.5");
    }

    #[test]
    fn test_tts_request_deserialize() {
        let json = r#"{
            "text": "hello world",
            "engine_url": "https://tts.example.com/speak?text={speakText}",
            "voice_name": "en-US",
            "speed": 1.0,
            "pitch": null,
            "volume": 80
        }"#;
        let req: TtsRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.text, "hello world");
        assert_eq!(req.voice_name, Some("en-US".to_string()));
        assert_eq!(req.speed, Some(1.0));
        assert!(req.pitch.is_none());
        assert_eq!(req.volume, Some(80));
    }

    #[test]
    fn test_tts_response_serialize() {
        let resp = TtsResponse {
            audio_url: None,
            audio_data: Some("base64data".to_string()),
            content_type: "audio/mpeg".to_string(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("audio_data"));
        assert!(json.contains("audio/mpeg"));
    }

    #[test]
    fn test_tts_engine_serialize() {
        let engine = TtsEngine {
            name: "Test".to_string(),
            url_template: "https://example.com/{speakText}".to_string(),
        };
        let json = serde_json::to_string(&engine).unwrap();
        assert!(json.contains("{speakText}"));
    }

    #[test]
    fn test_url_encoding_in_speak_url() {
        let engine_url = "https://tts.example.com/speak?text={speakText}";
        let text = "你好 世界";
        let encoded_text = urlencoding::encode(text);
        let url = engine_url.replace("{speakText}", &encoded_text);
        assert!(url.contains("%"));
        assert!(!url.contains("{speakText}"));
    }

    #[test]
    fn test_base64_encode_audio() {
        let fake_audio_bytes = b"fake audio data";
        let encoded = STANDARD.encode(fake_audio_bytes);
        assert!(!encoded.is_empty());
        // Verify round-trip
        let decoded = STANDARD.decode(&encoded).unwrap();
        assert_eq!(decoded, fake_audio_bytes);
    }
}
