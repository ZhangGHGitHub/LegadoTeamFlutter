//! HTTP TTS 语音合成管线 API（Task #113 批次 2 缺口②）
//!
//! 对照 Kotlin 原版 `HttpReadAloudService.getSpeakStream`：
//! url 模板替换（speakText/speakSpeed）→ HTTP 拉取音频二进制（legado-net `get_raw`）
//! → Content-Type 校验 → MD5 命名本地缓存。合成/缓存纯逻辑位于
//! `legado_core::tts_speak`，本模块负责注入共享 HTTP 客户端与全局缓存目录。

use std::path::PathBuf;
use std::sync::{OnceLock, RwLock};

use serde::Serialize;

use legado_core::tts_speak::{self, SpeakResponse};
use legado_core::LegadoResult;

/// TTS 合成结果 DTO（camelCase 对齐 Dart 侧解析约定，见 API_CONTRACT §2.42）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TtsSpeakDto {
    /// 本地音频文件绝对路径
    pub audio_path: String,
    /// 是否缓存命中（true 时未发起网络请求）
    pub from_cache: bool,
    /// 音频 MIME 类型
    pub content_type: String,
}

/// 全局 TTS 音频缓存目录（默认系统临时目录下 `legado_tts_cache`）
fn tts_cache_dir_slot() -> &'static RwLock<PathBuf> {
    static SLOT: OnceLock<RwLock<PathBuf>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(std::env::temp_dir().join("legado_tts_cache")))
}

/// 获取当前 TTS 音频缓存目录
pub fn tts_cache_dir() -> PathBuf {
    tts_cache_dir_slot()
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
}

/// 设置 TTS 音频缓存目录（全局生效）
pub fn set_tts_cache_dir(path: &str) -> LegadoResult<bool> {
    let dir = PathBuf::from(path);
    std::fs::create_dir_all(&dir)?;
    *tts_cache_dir_slot()
        .write()
        .unwrap_or_else(|p| p.into_inner()) = dir;
    Ok(true)
}

/// TTS 真实合成：返回本地音频文件路径（缓存命中时免网络请求）
///
/// - `text`: 朗读文本
/// - `engine_url`: 引擎 URL 模板（`{{speakText}}` / `{{text}}` / `{{speakSpeed}}` / `{{speed}}` 占位符）
/// - `speed`: 语速
pub fn tts_speak(text: &str, engine_url: &str, speed: f64) -> LegadoResult<TtsSpeakDto> {
    let cache_dir = tts_cache_dir();
    let engine_url = engine_url.to_string();
    let result = tts_speak::speak_text(&engine_url, text, speed, &cache_dir, |url| {
        // 同步签名适配：FFI 调用线程内 block_on 共享 tokio runtime（同 rss.rs 模式）
        let raw = crate::runtime::block_on(async {
            let client = crate::http_state::shared_client()?;
            client.get_raw(url, None).await
        })?;
        Ok(SpeakResponse {
            status: raw.status,
            content_type: raw.content_type().cloned().unwrap_or_default(),
            body: raw.body,
        })
    })?;
    Ok(TtsSpeakDto {
        audio_path: result.audio_path.to_string_lossy().to_string(),
        from_cache: result.from_cache,
        content_type: result.content_type,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试串行锁：以下测试会改写全局 TTS 缓存目录，并行执行会互相污染
    static TTS_DIR_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn test_set_tts_cache_dir_roundtrip() {
        let _guard = TTS_DIR_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let dir =
            std::env::temp_dir().join(format!("legado_tts_api_dir_test_{}", std::process::id()));
        let dir_str = dir.to_str().unwrap().to_string();
        assert!(set_tts_cache_dir(&dir_str).unwrap());
        assert_eq!(tts_cache_dir(), dir);
        assert!(dir.exists());

        // 恢复默认，避免污染其他并行测试
        let default_dir = std::env::temp_dir().join("legado_tts_cache");
        set_tts_cache_dir(default_dir.to_str().unwrap()).unwrap();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_tts_speak_cache_hit_without_network() {
        let _guard = TTS_DIR_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // 独立缓存目录：预置缓存文件后调用 tts_speak，应命中缓存且不触网
        let dir =
            std::env::temp_dir().join(format!("legado_tts_api_hit_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(set_tts_cache_dir(dir.to_str().unwrap()).unwrap());

        let template = "https://tts.example.com/api?text={{speakText}}";
        let key = tts_speak::speak_cache_key(template, "缓存命中测试", 1.0);
        let cache_file = dir.join(format!("tts_{}.mp3", key));
        std::fs::write(&cache_file, b"FAKE_MP3").unwrap();

        let dto = tts_speak("缓存命中测试", template, 1.0).unwrap();
        assert!(dto.from_cache);
        assert_eq!(dto.audio_path, cache_file.to_string_lossy().to_string());
        assert_eq!(dto.content_type, "audio/mpeg");

        // 恢复默认缓存目录，避免污染其他并行测试
        let default_dir = std::env::temp_dir().join("legado_tts_cache");
        set_tts_cache_dir(default_dir.to_str().unwrap()).unwrap();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_tts_speak_empty_text_error() {
        let _guard = TTS_DIR_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let err = tts_speak("  ", "https://tts.example.com/{{text}}", 1.0).unwrap_err();
        assert!(err.to_string().contains("朗读文本为空"));
    }
}
