//! 朗读状态机
//!
//! 移植自 Kotlin BaseReadAloudService + ReadAloud.kt
//! 实现连续朗读的完整状态管理。

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

/// 朗读状态
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ReadAloudStatus {
    Idle,
    Playing,
    Paused,
    Loading,
    Stopped,
    Error(String),
}

/// TTS 引擎类型
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TtsEngineType {
    /// HTTP TTS API
    HttpTts,
    /// 系统 TTS
    SystemTts,
}

/// TTS 配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadAloudConfig {
    pub engine_type: TtsEngineType,
    /// HTTP TTS URL
    pub engine_url: Option<String>,
    /// 语速 0.5-3.0
    pub speed: f32,
    /// 音调 0.5-2.0
    pub pitch: f32,
    /// 音量 0.0-1.0
    pub volume: f32,
    /// 段落间延迟（毫秒）
    pub paragraph_delay_ms: u64,
}

impl Default for ReadAloudConfig {
    fn default() -> Self {
        Self {
            engine_type: TtsEngineType::HttpTts,
            engine_url: None,
            speed: 1.0,
            pitch: 1.0,
            volume: 1.0,
            paragraph_delay_ms: 500,
        }
    }
}

/// 文本段落（朗读单元）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextParagraph {
    pub index: usize,
    pub text: String,
    pub chapter_index: i32,
    pub is_spoken: bool,
}

/// 朗读状态机
pub struct ReadAloudState {
    pub status: ReadAloudStatus,
    pub config: ReadAloudConfig,
    pub paragraphs: Vec<TextParagraph>,
    pub current_paragraph: usize,
    pub current_chapter: i32,
    /// 待朗读章节队列
    pub chapter_queue: VecDeque<i32>,
}

impl ReadAloudState {
    pub fn new(config: ReadAloudConfig) -> Self {
        Self {
            status: ReadAloudStatus::Idle,
            config,
            paragraphs: Vec::new(),
            current_paragraph: 0,
            current_chapter: 0,
            chapter_queue: VecDeque::new(),
        }
    }

    /// 分割章节文本为朗读段落
    pub fn split_paragraphs(chapter_text: &str, chapter_index: i32) -> Vec<TextParagraph> {
        chapter_text
            .split(['\n', '。', '！', '？', '；'])
            .enumerate()
            .filter(|(_, s)| !s.trim().is_empty())
            .map(|(i, text)| TextParagraph {
                index: i,
                text: text.trim().to_string(),
                chapter_index,
                is_spoken: false,
            })
            .collect()
    }

    /// 加载章节文本
    pub fn load_chapter(&mut self, chapter_index: i32, text: &str) {
        self.paragraphs = Self::split_paragraphs(text, chapter_index);
        self.current_chapter = chapter_index;
        self.current_paragraph = 0;
    }

    /// 开始朗读
    pub fn play(&mut self) {
        self.status = ReadAloudStatus::Playing;
    }

    /// 暂停朗读
    pub fn pause(&mut self) {
        if self.status == ReadAloudStatus::Playing {
            self.status = ReadAloudStatus::Paused;
        }
    }

    /// 恢复朗读
    pub fn resume(&mut self) {
        if self.status == ReadAloudStatus::Paused {
            self.status = ReadAloudStatus::Playing;
        }
    }

    /// 停止朗读
    pub fn stop(&mut self) {
        self.status = ReadAloudStatus::Stopped;
    }

    /// 获取当前待朗读段落
    pub fn current_text(&self) -> Option<&TextParagraph> {
        self.paragraphs.get(self.current_paragraph)
    }

    /// 标记当前段落已朗读，前进到下一段
    ///
    /// 返回 true 表示还有后续内容（当前章节下一段或需要加载下一章），
    /// 返回 false 表示全部朗读完毕。
    pub fn advance(&mut self) -> bool {
        if let Some(p) = self.paragraphs.get_mut(self.current_paragraph) {
            p.is_spoken = true;
        }
        self.current_paragraph += 1;
        if self.current_paragraph >= self.paragraphs.len() {
            // 当前章节朗读完毕，尝试下一章节
            if let Some(&next_chapter) = self.chapter_queue.front() {
                self.chapter_queue.pop_front();
                self.current_chapter = next_chapter;
                self.current_paragraph = 0;
                self.paragraphs.clear();
                self.status = ReadAloudStatus::Loading;
                return true; // 需要加载下一章
            } else {
                self.status = ReadAloudStatus::Stopped;
                return false;
            }
        }
        true
    }

    /// 添加章节到朗读队列
    pub fn enqueue_chapter(&mut self, chapter_index: i32) {
        self.chapter_queue.push_back(chapter_index);
    }

    /// 跳转到指定段落
    pub fn seek_to(&mut self, paragraph_index: usize) {
        if paragraph_index < self.paragraphs.len() {
            self.current_paragraph = paragraph_index;
        }
    }

    /// 获取朗读进度 (0.0 - 1.0)
    pub fn progress(&self) -> f64 {
        if self.paragraphs.is_empty() {
            return 0.0;
        }
        self.current_paragraph as f64 / self.paragraphs.len() as f64
    }

    /// 是否正在朗读（Playing 或 Paused 均视为活跃）
    pub fn is_active(&self) -> bool {
        matches!(
            self.status,
            ReadAloudStatus::Playing | ReadAloudStatus::Paused | ReadAloudStatus::Loading
        )
    }

    /// 获取已朗读段落数
    pub fn spoken_count(&self) -> usize {
        self.paragraphs.iter().filter(|p| p.is_spoken).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_state() -> ReadAloudState {
        ReadAloudState::new(ReadAloudConfig::default())
    }

    #[test]
    fn test_default_config() {
        let cfg = ReadAloudConfig::default();
        assert_eq!(cfg.engine_type, TtsEngineType::HttpTts);
        assert!(cfg.engine_url.is_none());
        assert!((cfg.speed - 1.0).abs() < f32::EPSILON);
        assert!((cfg.pitch - 1.0).abs() < f32::EPSILON);
        assert!((cfg.volume - 1.0).abs() < f32::EPSILON);
        assert_eq!(cfg.paragraph_delay_ms, 500);
    }

    #[test]
    fn test_new_state_is_idle() {
        let state = default_state();
        assert_eq!(state.status, ReadAloudStatus::Idle);
        assert_eq!(state.current_paragraph, 0);
        assert_eq!(state.current_chapter, 0);
        assert!(state.paragraphs.is_empty());
        assert!(state.chapter_queue.is_empty());
    }

    #[test]
    fn test_split_paragraphs_basic() {
        let text = "第一句话。第二句话！第三句话？";
        let paragraphs = ReadAloudState::split_paragraphs(text, 0);
        assert_eq!(paragraphs.len(), 3);
        assert_eq!(paragraphs[0].text, "第一句话");
        assert_eq!(paragraphs[1].text, "第二句话");
        assert_eq!(paragraphs[2].text, "第三句话");
    }

    #[test]
    fn test_split_paragraphs_newline() {
        let text = "段落一\n段落二\n段落三";
        let paragraphs = ReadAloudState::split_paragraphs(text, 1);
        assert_eq!(paragraphs.len(), 3);
        assert_eq!(paragraphs[0].chapter_index, 1);
        assert!(!paragraphs[0].is_spoken);
    }

    #[test]
    fn test_split_paragraphs_filters_empty() {
        let text = "有效文本。\n\n。\n有效文本二";
        let paragraphs = ReadAloudState::split_paragraphs(text, 0);
        // 空段被过滤
        assert!(paragraphs.iter().all(|p| !p.text.is_empty()));
        assert_eq!(paragraphs.len(), 2);
    }

    #[test]
    fn test_split_paragraphs_empty_input() {
        let paragraphs = ReadAloudState::split_paragraphs("", 0);
        assert!(paragraphs.is_empty());
    }

    #[test]
    fn test_load_chapter() {
        let mut state = default_state();
        state.load_chapter(2, "句子一。句子二。句子三。");
        assert_eq!(state.current_chapter, 2);
        assert_eq!(state.current_paragraph, 0);
        assert_eq!(state.paragraphs.len(), 3);
    }

    #[test]
    fn test_play_pause_resume_stop() {
        let mut state = default_state();
        state.play();
        assert_eq!(state.status, ReadAloudStatus::Playing);

        state.pause();
        assert_eq!(state.status, ReadAloudStatus::Paused);

        state.resume();
        assert_eq!(state.status, ReadAloudStatus::Playing);

        state.stop();
        assert_eq!(state.status, ReadAloudStatus::Stopped);
    }

    #[test]
    fn test_pause_only_when_playing() {
        let mut state = default_state();
        // Idle 状态下 pause 无效
        state.pause();
        assert_eq!(state.status, ReadAloudStatus::Idle);
    }

    #[test]
    fn test_resume_only_when_paused() {
        let mut state = default_state();
        // Idle 状态下 resume 无效
        state.resume();
        assert_eq!(state.status, ReadAloudStatus::Idle);
    }

    #[test]
    fn test_current_text() {
        let mut state = default_state();
        assert!(state.current_text().is_none());

        state.load_chapter(0, "段落A。段落B。");
        let cur = state.current_text().unwrap();
        assert_eq!(cur.text, "段落A");
        assert_eq!(cur.index, 0);
    }

    #[test]
    fn test_advance_within_chapter() {
        let mut state = default_state();
        state.load_chapter(0, "句一。句二。句三。");
        state.play();

        assert!(state.advance());
        assert_eq!(state.current_paragraph, 1);
        assert!(state.paragraphs[0].is_spoken);
        assert!(!state.paragraphs[1].is_spoken);
    }

    #[test]
    fn test_advance_to_next_chapter() {
        let mut state = default_state();
        state.load_chapter(0, "唯一段落");
        state.enqueue_chapter(1);
        state.play();

        // advance 到章节末尾 → 需要加载下一章
        let need_load = state.advance();
        assert!(need_load);
        assert_eq!(state.current_chapter, 1);
        assert_eq!(state.current_paragraph, 0);
        assert!(state.paragraphs.is_empty());
        assert_eq!(state.status, ReadAloudStatus::Loading);
        assert!(state.chapter_queue.is_empty());
    }

    #[test]
    fn test_advance_end_of_all() {
        let mut state = default_state();
        state.load_chapter(0, "唯一段落");
        state.play();

        // 没有后续章节 → 停止
        let need_load = state.advance();
        assert!(!need_load);
        assert_eq!(state.status, ReadAloudStatus::Stopped);
    }

    #[test]
    fn test_enqueue_chapter() {
        let mut state = default_state();
        state.enqueue_chapter(5);
        state.enqueue_chapter(6);
        state.enqueue_chapter(7);
        assert_eq!(state.chapter_queue.len(), 3);
        assert_eq!(*state.chapter_queue.front().unwrap(), 5);
    }

    #[test]
    fn test_seek_to() {
        let mut state = default_state();
        state.load_chapter(0, "A。B。C。D。E。");
        state.seek_to(3);
        assert_eq!(state.current_paragraph, 3);
        assert_eq!(state.current_text().unwrap().text, "D");
    }

    #[test]
    fn test_seek_to_out_of_bounds() {
        let mut state = default_state();
        state.load_chapter(0, "A。B。");
        state.seek_to(99);
        // 越界不改变
        assert_eq!(state.current_paragraph, 0);
    }

    #[test]
    fn test_progress() {
        let mut state = default_state();
        assert!((state.progress() - 0.0).abs() < f64::EPSILON);

        state.load_chapter(0, "A。B。C。D。");
        assert!((state.progress() - 0.0).abs() < f64::EPSILON);

        state.advance();
        assert!((state.progress() - 0.25).abs() < f64::EPSILON);

        state.advance();
        assert!((state.progress() - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_is_active() {
        let mut state = default_state();
        assert!(!state.is_active());

        state.play();
        assert!(state.is_active());

        state.pause();
        assert!(state.is_active());

        state.stop();
        assert!(!state.is_active());
    }

    #[test]
    fn test_spoken_count() {
        let mut state = default_state();
        state.load_chapter(0, "A。B。C。");
        assert_eq!(state.spoken_count(), 0);

        state.advance();
        assert_eq!(state.spoken_count(), 1);

        state.advance();
        assert_eq!(state.spoken_count(), 2);
    }

    #[test]
    fn test_config_serde_roundtrip() {
        let cfg = ReadAloudConfig {
            engine_type: TtsEngineType::SystemTts,
            engine_url: Some("https://tts.example.com/{speakText}".to_string()),
            speed: 1.5,
            pitch: 0.8,
            volume: 0.9,
            paragraph_delay_ms: 300,
        };
        let json = serde_json::to_string(&cfg).unwrap();
        let de: ReadAloudConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(de.engine_type, TtsEngineType::SystemTts);
        assert_eq!(de.engine_url, cfg.engine_url);
        assert!((de.speed - 1.5).abs() < f32::EPSILON);
        assert_eq!(de.paragraph_delay_ms, 300);
    }

    #[test]
    fn test_status_serde_roundtrip() {
        let statuses = vec![
            ReadAloudStatus::Idle,
            ReadAloudStatus::Playing,
            ReadAloudStatus::Paused,
            ReadAloudStatus::Loading,
            ReadAloudStatus::Stopped,
            ReadAloudStatus::Error("test error".to_string()),
        ];
        for status in &statuses {
            let json = serde_json::to_string(status).unwrap();
            let de: ReadAloudStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(&de, status);
        }
    }

    #[test]
    fn test_text_paragraph_serde() {
        let p = TextParagraph {
            index: 3,
            text: "测试段落".to_string(),
            chapter_index: 1,
            is_spoken: true,
        };
        let json = serde_json::to_string(&p).unwrap();
        let de: TextParagraph = serde_json::from_str(&json).unwrap();
        assert_eq!(de.index, 3);
        assert_eq!(de.text, "测试段落");
        assert_eq!(de.chapter_index, 1);
        assert!(de.is_spoken);
    }

    #[test]
    fn test_multi_chapter_flow() {
        let mut state = default_state();
        state.load_chapter(0, "第一章内容。");
        state.enqueue_chapter(1);
        state.enqueue_chapter(2);
        state.play();

        // 第一章读完 → 切到第二章
        assert!(state.advance());
        assert_eq!(state.current_chapter, 1);
        assert_eq!(state.status, ReadAloudStatus::Loading);

        // 加载第二章
        state.load_chapter(1, "第二章内容。");
        state.play();

        // 第二章读完 → 切到第三章
        assert!(state.advance());
        assert_eq!(state.current_chapter, 2);
        assert_eq!(state.status, ReadAloudStatus::Loading);

        // 加载第三章
        state.load_chapter(2, "第三章内容。");
        state.play();

        // 第三章读完 → 无后续，停止
        assert!(!state.advance());
        assert_eq!(state.status, ReadAloudStatus::Stopped);
    }
}
