//! 听书播放模块

use serde::{Deserialize, Serialize};

/// TTS 配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsConfig {
    /// TTS 引擎 URL（含 {speakText} 占位符）
    pub engine_url: String,
    /// 语音名称
    pub voice_name: Option<String>,
    /// 语速（0.5 - 3.0，默认 1.0）
    pub speed: f32,
    /// 音调（0.5 - 2.0，默认 1.0）
    pub pitch: f32,
    /// 音量（0.0 - 1.0，默认 1.0）
    pub volume: f32,
}

impl Default for TtsConfig {
    fn default() -> Self {
        Self {
            engine_url: String::new(),
            voice_name: None,
            speed: 1.0,
            pitch: 1.0,
            volume: 1.0,
        }
    }
}

/// 音频章节信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioChapter {
    /// 章节索引
    pub index: i32,
    /// 章节标题
    pub title: String,
    /// 章节文本内容
    pub text: String,
    /// 预估时长（基于字数，毫秒）
    pub duration_estimate_ms: Option<i64>,
}

/// 播放模式
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum PlayMode {
    /// 顺序播放
    Sequential,
    /// 单曲循环
    SingleLoop,
    /// 随机
    Shuffle,
}

impl PlayMode {
    /// 切换到下一个播放模式（循环）
    /// 对应 Kotlin AudioPlayMode.next()
    pub fn next(&self) -> Self {
        match self {
            PlayMode::Sequential => PlayMode::SingleLoop,
            PlayMode::SingleLoop => PlayMode::Shuffle,
            PlayMode::Shuffle => PlayMode::Sequential,
        }
    }

    /// 获取播放模式的序号（用于持久化）
    pub fn ordinal(&self) -> i32 {
        match self {
            PlayMode::Sequential => 0,
            PlayMode::SingleLoop => 1,
            PlayMode::Shuffle => 2,
        }
    }

    /// 从序号恢复播放模式
    pub fn from_ordinal(ord: i32) -> Self {
        match ord {
            1 => PlayMode::SingleLoop,
            2 => PlayMode::Shuffle,
            _ => PlayMode::Sequential,
        }
    }
}

/// 播放状态
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PlayerState {
    Idle,
    Playing,
    Paused,
    Loading,
    Error(String),
}

/// 播放列表管理
pub struct AudioPlaylist {
    chapters: Vec<AudioChapter>,
    current_index: usize,
    mode: PlayMode,
}

impl AudioPlaylist {
    pub fn new(chapters: Vec<AudioChapter>) -> Self {
        Self {
            chapters,
            current_index: 0,
            mode: PlayMode::Sequential,
        }
    }

    pub fn current(&self) -> Option<&AudioChapter> {
        if self.chapters.is_empty() || self.current_index >= self.chapters.len() {
            None
        } else {
            Some(&self.chapters[self.current_index])
        }
    }

    pub fn next_chapter(&mut self) -> Option<&AudioChapter> {
        if self.chapters.is_empty() {
            return None;
        }
        match self.mode {
            PlayMode::Sequential => {
                if self.current_index + 1 < self.chapters.len() {
                    self.current_index += 1;
                    Some(&self.chapters[self.current_index])
                } else {
                    None
                }
            }
            PlayMode::SingleLoop => Some(&self.chapters[self.current_index]),
            PlayMode::Shuffle => {
                use std::time::{SystemTime, UNIX_EPOCH};
                let seed = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .subsec_nanos() as usize;
                self.current_index = seed % self.chapters.len();
                Some(&self.chapters[self.current_index])
            }
        }
    }

    pub fn previous(&mut self) -> Option<&AudioChapter> {
        if self.chapters.is_empty() {
            return None;
        }
        match self.mode {
            PlayMode::Sequential => {
                if self.current_index > 0 {
                    self.current_index -= 1;
                    Some(&self.chapters[self.current_index])
                } else {
                    None
                }
            }
            PlayMode::SingleLoop => Some(&self.chapters[self.current_index]),
            PlayMode::Shuffle => {
                use std::time::{SystemTime, UNIX_EPOCH};
                let seed = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .subsec_nanos() as usize;
                self.current_index = seed % self.chapters.len();
                Some(&self.chapters[self.current_index])
            }
        }
    }

    pub fn set_mode(&mut self, mode: PlayMode) {
        self.mode = mode;
    }

    pub fn jump_to(&mut self, index: usize) -> Option<&AudioChapter> {
        if index < self.chapters.len() {
            self.current_index = index;
            Some(&self.chapters[self.current_index])
        } else {
            None
        }
    }

    pub fn current_index(&self) -> usize {
        self.current_index
    }

    pub fn len(&self) -> usize {
        self.chapters.len()
    }

    pub fn is_empty(&self) -> bool {
        self.chapters.is_empty()
    }

    pub fn chapters(&self) -> &[AudioChapter] {
        &self.chapters
    }

    pub fn mode(&self) -> PlayMode {
        self.mode
    }
}

/// 将播放模式写入 readConfig JSON（对应 Kotlin String?.withAudioPlayMode）
///
/// 读取现有 readConfig JSON，设置 playMode 字段，返回更新后的 JSON 字符串
pub fn with_audio_play_mode(read_config: Option<&str>, play_mode: i32) -> String {
    let mut config: serde_json::Value = read_config
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
        .filter(|v: &serde_json::Value| v.is_object())
        .unwrap_or_else(|| serde_json::json!({}));
    config["playMode"] = serde_json::json!(play_mode);
    serde_json::to_string(&config).unwrap_or_else(|_| format!("{{\"playMode\":{play_mode}}}"))
}

/// 解析听书书籍（对应 Kotlin resolveAudioPlayBook）
///
/// 用于修复听书通知恢复错误书籍的问题：
/// - 如果请求的 bookUrl 为空，返回缓存书籍（如果有效）
/// - 如果缓存书籍的 URL 匹配请求，直接返回缓存
/// - 否则通过 find_book 查找正确的书籍
pub fn resolve_audio_play_book<T, F>(
    requested_book_url: Option<&str>,
    cached_book: Option<T>,
    book_url_of: impl Fn(&T) -> &str,
    find_book: F,
) -> Option<T>
where
    F: Fn(&str) -> Option<T>,
{
    let target_url = match requested_book_url {
        Some(url) if !url.trim().is_empty() => url,
        _ => {
            // 无请求 URL，返回缓存（如果有效）
            return cached_book.filter(|b| !book_url_of(b).is_empty());
        }
    };

    // 缓存书籍 URL 匹配，直接返回
    if let Some(cached) = cached_book {
        if book_url_of(&cached) == target_url {
            return Some(cached);
        }
        // 不匹配，通过 find_book 查找
        return find_book(target_url).filter(|b| book_url_of(b) == target_url);
    }

    // 无缓存，直接查找
    find_book(target_url).filter(|b| book_url_of(b) == target_url)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_chapters(n: usize) -> Vec<AudioChapter> {
        (0..n)
            .map(|i| AudioChapter {
                index: i as i32,
                title: format!("Chapter {}", i),
                text: format!("Text for chapter {}", i),
                duration_estimate_ms: Some(i as i64 * 60_000),
            })
            .collect()
    }

    #[test]
    fn test_tts_config_default() {
        let cfg = TtsConfig::default();
        assert!(cfg.engine_url.is_empty());
        assert!(cfg.voice_name.is_none());
        assert!((cfg.speed - 1.0).abs() < f32::EPSILON);
        assert!((cfg.pitch - 1.0).abs() < f32::EPSILON);
        assert!((cfg.volume - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_tts_config_serde_roundtrip() {
        let cfg = TtsConfig {
            engine_url: "https://tts.example.com/{speakText}".to_string(),
            voice_name: Some("zh-CN".to_string()),
            speed: 1.5,
            pitch: 0.8,
            volume: 0.9,
        };
        let json = serde_json::to_string(&cfg).unwrap();
        let de: TtsConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(de.engine_url, cfg.engine_url);
        assert_eq!(de.voice_name, cfg.voice_name);
        assert!((de.speed - 1.5).abs() < f32::EPSILON);
    }

    #[test]
    fn test_audio_chapter_serde() {
        let ch = AudioChapter {
            index: 0,
            title: "第一章".to_string(),
            text: "正文内容".to_string(),
            duration_estimate_ms: Some(120_000),
        };
        let json = serde_json::to_string(&ch).unwrap();
        let de: AudioChapter = serde_json::from_str(&json).unwrap();
        assert_eq!(de.title, "第一章");
        assert_eq!(de.duration_estimate_ms, Some(120_000));
    }

    #[test]
    fn test_playlist_new_and_current() {
        let chapters = make_chapters(3);
        let pl = AudioPlaylist::new(chapters);
        assert_eq!(pl.current_index(), 0);
        assert_eq!(pl.len(), 3);
        assert!(!pl.is_empty());
        let cur = pl.current().unwrap();
        assert_eq!(cur.title, "Chapter 0");
    }

    #[test]
    fn test_playlist_empty() {
        let mut pl = AudioPlaylist::new(vec![]);
        assert!(pl.is_empty());
        assert!(pl.current().is_none());
        assert!(pl.next_chapter().is_none());
        assert!(pl.previous().is_none());
        assert!(pl.jump_to(0).is_none());
    }

    #[test]
    fn test_playlist_sequential_next_prev() {
        let chapters = make_chapters(3);
        let mut pl = AudioPlaylist::new(chapters);
        assert_eq!(pl.current().unwrap().title, "Chapter 0");
        assert!(pl.next_chapter().is_some());
        assert_eq!(pl.current().unwrap().title, "Chapter 1");
        assert!(pl.next_chapter().is_some());
        assert_eq!(pl.current().unwrap().title, "Chapter 2");
        // At end, next returns None
        assert!(pl.next_chapter().is_none());
        // Go back
        assert!(pl.previous().is_some());
        assert_eq!(pl.current().unwrap().title, "Chapter 1");
    }

    #[test]
    fn test_playlist_jump_to() {
        let chapters = make_chapters(5);
        let mut pl = AudioPlaylist::new(chapters);
        assert!(pl.jump_to(3).is_some());
        assert_eq!(pl.current().unwrap().title, "Chapter 3");
        // Out of bounds
        assert!(pl.jump_to(10).is_none());
        assert_eq!(pl.current().unwrap().title, "Chapter 3");
    }

    #[test]
    fn test_playlist_single_loop() {
        let chapters = make_chapters(3);
        let mut pl = AudioPlaylist::new(chapters);
        pl.set_mode(PlayMode::SingleLoop);
        assert_eq!(pl.mode(), PlayMode::SingleLoop);
        let _ = pl.next_chapter();
        // SingleLoop stays on same chapter
        assert_eq!(pl.current_index(), 0);
    }

    #[test]
    fn test_play_mode_serde() {
        let mode = PlayMode::Shuffle;
        let json = serde_json::to_string(&mode).unwrap();
        let de: PlayMode = serde_json::from_str(&json).unwrap();
        assert_eq!(de, PlayMode::Shuffle);
    }

    #[test]
    fn test_player_state_variants() {
        let states: Vec<PlayerState> = vec![
            PlayerState::Idle,
            PlayerState::Playing,
            PlayerState::Paused,
            PlayerState::Loading,
            PlayerState::Error("test error".to_string()),
        ];
        for state in &states {
            let json = serde_json::to_string(state).unwrap();
            let _de: PlayerState = serde_json::from_str(&json).unwrap();
        }
    }

    // ─── PlayMode::next / ordinal / from_ordinal 测试 ─────────

    #[test]
    fn test_play_mode_next_cycles() {
        assert_eq!(PlayMode::Sequential.next(), PlayMode::SingleLoop);
        assert_eq!(PlayMode::SingleLoop.next(), PlayMode::Shuffle);
        assert_eq!(PlayMode::Shuffle.next(), PlayMode::Sequential);
    }

    #[test]
    fn test_play_mode_ordinal_roundtrip() {
        for mode in [
            PlayMode::Sequential,
            PlayMode::SingleLoop,
            PlayMode::Shuffle,
        ] {
            let ord = mode.ordinal();
            assert_eq!(PlayMode::from_ordinal(ord), mode);
        }
    }

    #[test]
    fn test_play_mode_from_ordinal_unknown() {
        // 未知序号默认为 Sequential
        assert_eq!(PlayMode::from_ordinal(99), PlayMode::Sequential);
        assert_eq!(PlayMode::from_ordinal(-1), PlayMode::Sequential);
    }

    // ─── with_audio_play_mode 测试 ────────────────────────

    #[test]
    fn test_with_audio_play_mode_none_config() {
        let result = with_audio_play_mode(None, 2);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["playMode"], 2);
    }

    #[test]
    fn test_with_audio_play_mode_existing_config() {
        let config = r#"{"fontSize":16,"playMode":0}"#;
        let result = with_audio_play_mode(Some(config), 1);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["playMode"], 1);
        assert_eq!(parsed["fontSize"], 16);
    }

    #[test]
    fn test_with_audio_play_mode_invalid_json() {
        let result = with_audio_play_mode(Some("not json"), 2);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["playMode"], 2);
    }

    // ─── resolve_audio_play_book 测试 ─────────────────────

    #[test]
    fn test_resolve_no_url_returns_cached() {
        let cached = Some(("book1".to_string(), "url1".to_string()));
        let result =
            resolve_audio_play_book(None, cached, |b| b.1.as_str(), |_| None::<(String, String)>);
        assert!(result.is_some());
        assert_eq!(result.unwrap().0, "book1");
    }

    #[test]
    fn test_resolve_blank_url_returns_cached() {
        let cached = Some(("book1".to_string(), "url1".to_string()));
        let result = resolve_audio_play_book(
            Some("  "),
            cached,
            |b| b.1.as_str(),
            |_| None::<(String, String)>,
        );
        assert!(result.is_some());
        assert_eq!(result.unwrap().0, "book1");
    }

    #[test]
    fn test_resolve_matching_cached() {
        let cached = Some(("book1".to_string(), "url1".to_string()));
        let result = resolve_audio_play_book(
            Some("url1"),
            cached,
            |b| b.1.as_str(),
            |_| None::<(String, String)>,
        );
        assert!(result.is_some());
        assert_eq!(result.unwrap().0, "book1");
    }

    #[test]
    fn test_resolve_mismatched_cached_uses_find() {
        let cached = Some(("book1".to_string(), "url1".to_string()));
        let result = resolve_audio_play_book(
            Some("url2"),
            cached,
            |b| b.1.as_str(),
            |url| {
                if url == "url2" {
                    Some(("book2".to_string(), "url2".to_string()))
                } else {
                    None
                }
            },
        );
        assert!(result.is_some());
        assert_eq!(result.unwrap().0, "book2");
    }

    #[test]
    fn test_resolve_no_cached_uses_find() {
        let result = resolve_audio_play_book(
            Some("url1"),
            None::<(String, String)>,
            |b| b.1.as_str(),
            |url| {
                if url == "url1" {
                    Some(("book1".to_string(), "url1".to_string()))
                } else {
                    None
                }
            },
        );
        assert!(result.is_some());
        assert_eq!(result.unwrap().0, "book1");
    }

    #[test]
    fn test_resolve_find_returns_wrong_url() {
        let result = resolve_audio_play_book(
            Some("url1"),
            None::<(String, String)>,
            |b| b.1.as_str(),
            |_| Some(("book_wrong".to_string(), "url_other".to_string())),
        );
        // find_book 返回的书籍 URL 不匹配，应被过滤
        assert!(result.is_none());
    }
}
