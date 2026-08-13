//! 阅读器核心状态机
//!
//! 移植自 Kotlin ReadBook.kt 的核心阅读逻辑，实现：
//! - 阅读进度管理（章节索引 + 页/字符位置）
//! - 进度保存与恢复
//! - 章节跳转与自动翻章
//! - 阅读模式（仿真/滑动/滚动）
//! - 阅读统计（时长/字数/速度）
//!
//! 与现有模块的关系：
//! - [`crate::read_state::ReadBookState`] — 三章滑动窗口 + LRU 缓存 + 预下载（本模块复用）
//! - [`crate::reading_stats`] — 阅读统计计算（本模块在会话结束时生成统计数据）
//! - [`crate::layout::LayoutEngine`] — 排版分页（本模块使用其分页结果定位页码）

use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::layout::{LayoutConfig, LayoutEngine, LayoutPage};
use crate::read_state::ReadBookState;
use crate::reading_stats::{ReadingSession, ReadingStatsCalculator};

// ─── 阅读模式 ─────────────────────────────────────────────

/// 阅读翻页模式
///
/// 对应 Kotlin `ReadBookConfig.pageAnim`：
/// - 0 = 仿真翻页（Simulation）
/// - 1 = 滑动翻页（Slide）
/// - 2 = 覆盖翻页（Cover，归入 Slide）
/// - 3 = 滚动翻页（Scroll）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum ReadingMode {
    /// 仿真翻页（模拟纸张翻转效果）
    #[default]
    Simulation,
    /// 滑动翻页（左右滑动切换页面）
    Slide,
    /// 滚动翻页（上下连续滚动）
    Scroll,
}

impl ReadingMode {
    /// 从 Kotlin pageAnim 整数值转换
    pub fn from_page_anim(anim: i32) -> Self {
        match anim {
            3 => Self::Scroll,
            1 | 2 => Self::Slide,
            _ => Self::Simulation,
        }
    }

    /// 转换为 Kotlin pageAnim 整数值
    pub fn to_page_anim(self) -> i32 {
        match self {
            Self::Simulation => 0,
            Self::Slide => 1,
            Self::Scroll => 3,
        }
    }

    /// 是否为滚动模式
    pub fn is_scroll(self) -> bool {
        self == Self::Scroll
    }
}

// ─── 阅读进度 ─────────────────────────────────────────────

/// 阅读进度快照（可持久化）
///
/// 对应 Kotlin `BookProgress` 实体：
/// - `durChapterIndex` — 当前章节索引
/// - `durChapterPos` — 当前章节内字符位置
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadingProgress {
    /// 书籍 URL（唯一标识）
    pub book_url: String,
    /// 当前章节索引（0-based）
    pub chapter_index: i32,
    /// 章节内字符位置（偏移量）
    pub chapter_pos: usize,
    /// 当前页码（由排版引擎计算，非持久化核心字段）
    pub page_index: usize,
    /// 总页数（当前章排版后的总页数）
    pub total_pages: usize,
    /// 进度保存时间戳（Unix 毫秒）
    pub saved_at: i64,
}

impl ReadingProgress {
    /// 创建新的阅读进度
    pub fn new(book_url: impl Into<String>, chapter_index: i32, chapter_pos: usize) -> Self {
        Self {
            book_url: book_url.into(),
            chapter_index,
            chapter_pos,
            page_index: 0,
            total_pages: 0,
            saved_at: current_millis(),
        }
    }

    /// 计算阅读百分比进度（0.0 ~ 1.0）
    pub fn percentage(&self) -> f64 {
        if self.total_pages == 0 {
            return 0.0;
        }
        (self.page_index as f64) / (self.total_pages as f64)
    }
}

// ─── 章节跳转结果 ──────────────────────────────────────────

/// 章节跳转结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChapterTransition {
    /// 成功跳转到目标章节
    Success {
        from_index: i32,
        to_index: i32,
    },
    /// 已到达首章（无法再向前）
    AtFirstChapter,
    /// 已到达末章（无法再向后）
    AtLastChapter,
    /// 目标章节超出范围
    OutOfBounds {
        target: i32,
        total_chapters: i32,
    },
}

impl ChapterTransition {
    /// 跳转是否成功
    pub fn is_success(&self) -> bool {
        matches!(self, Self::Success { .. })
    }
}

// ─── 阅读统计快照 ──────────────────────────────────────────

/// 实时阅读统计（会话内）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveReadingStats {
    /// 本次会话已阅读时长
    pub elapsed: Duration,
    /// 本次会话已阅读字数
    pub chars_read: usize,
    /// 当前阅读速度（字/分钟）
    pub speed_wpm: f64,
    /// 本次会话跨越的章节数
    pub chapters_visited: usize,
}

// ─── 阅读器状态机 ──────────────────────────────────────────

/// 阅读器核心状态机
///
/// 整合阅读进度、章节加载、翻页逻辑与阅读统计。
/// 对应 Kotlin `ReadBook` object 的核心状态管理逻辑。
pub struct ReaderStateMachine {
    /// 书籍 URL
    book_url: String,
    /// 总章节数
    total_chapters: i32,
    /// 当前章节索引
    current_chapter: i32,
    /// 当前章节内字符位置
    current_position: usize,
    /// 当前页码
    current_page: usize,
    /// 当前章排版后的总页数
    total_pages: usize,
    /// 阅读模式
    reading_mode: ReadingMode,

    // ─── 阅读统计 ───
    /// 本次阅读会话开始时间
    session_start: Option<Instant>,
    /// 累计阅读时长（跨会话）
    total_reading_time: Duration,
    /// 本次会话已阅读字数
    session_chars_read: usize,
    /// 本次会话访问过的章节数
    session_chapters_visited: usize,

    // ─── 预加载窗口（复用 read_state） ───
    /// 章节预加载状态机
    preload_state: ReadBookState,

    // ─── 排版引擎 ───
    /// 排版配置
    layout_config: LayoutConfig,

    // ─── 进度历史 ───
    /// 跳转前的进度记录（对应 Kotlin lastBookProgress）
    last_progress: Option<ReadingProgress>,
}

impl ReaderStateMachine {
    /// 创建阅读器状态机
    ///
    /// - `book_url`: 书籍唯一标识
    /// - `total_chapters`: 总章节数
    pub fn new(book_url: impl Into<String>, total_chapters: i32) -> Self {
        Self {
            book_url: book_url.into(),
            total_chapters,
            current_chapter: 0,
            current_position: 0,
            current_page: 0,
            total_pages: 0,
            reading_mode: ReadingMode::default(),
            session_start: None,
            total_reading_time: Duration::ZERO,
            session_chars_read: 0,
            session_chapters_visited: 0,
            preload_state: ReadBookState::new(),
            layout_config: LayoutConfig::default(),
            last_progress: None,
        }
    }

    /// 使用自定义排版配置创建
    pub fn with_layout_config(
        book_url: impl Into<String>,
        total_chapters: i32,
        layout_config: LayoutConfig,
    ) -> Self {
        let mut state = Self::new(book_url, total_chapters);
        state.layout_config = layout_config;
        state
    }

    // ─── 阅读会话管理 ─────────────────────────────────────

    /// 开始阅读会话（打开书籍时调用）
    pub fn start_session(&mut self) {
        self.session_start = Some(Instant::now());
        self.session_chars_read = 0;
        self.session_chapters_visited = 1;
    }

    /// 结束阅读会话（关闭书籍时调用），返回本次会话统计
    pub fn end_session(&mut self) -> Option<ReadingSession> {
        let start = self.session_start.take()?;
        let elapsed = start.elapsed();
        self.total_reading_time += elapsed;

        let duration_ms = elapsed.as_millis() as i64;
        let speed = ReadingStatsCalculator::calculate_speed(
            self.session_chars_read as i32,
            duration_ms,
        );

        let now_ms = current_millis();
        Some(ReadingSession {
            id: 0, // 由持久层分配
            book_url: self.book_url.clone(),
            chapter_index: self.current_chapter,
            chapter_name: None,
            start_time: now_ms - duration_ms,
            end_time: Some(now_ms),
            word_count: self.session_chars_read as i32,
            reading_speed: speed,
        })
    }

    /// 获取实时阅读统计
    pub fn live_stats(&self) -> LiveReadingStats {
        let elapsed = self.session_start.map(|s| s.elapsed()).unwrap_or_default();
        let duration_ms = elapsed.as_millis() as i64;
        let speed = ReadingStatsCalculator::calculate_speed(
            self.session_chars_read as i32,
            duration_ms,
        );
        LiveReadingStats {
            elapsed,
            chars_read: self.session_chars_read,
            speed_wpm: speed,
            chapters_visited: self.session_chapters_visited,
        }
    }

    // ─── 进度管理 ─────────────────────────────────────────

    /// 保存当前阅读进度（生成可持久化的进度快照）
    pub fn save_progress(&self) -> ReadingProgress {
        ReadingProgress {
            book_url: self.book_url.clone(),
            chapter_index: self.current_chapter,
            chapter_pos: self.current_position,
            page_index: self.current_page,
            total_pages: self.total_pages,
            saved_at: current_millis(),
        }
    }

    /// 恢复阅读进度（打开书籍时恢复上次位置）
    pub fn restore_progress(&mut self, progress: ReadingProgress) {
        self.current_chapter = progress.chapter_index;
        self.current_position = progress.chapter_pos;
        self.current_page = progress.page_index;
        self.total_pages = progress.total_pages;
        // 同步预加载窗口到新位置
        self.preload_state.jump_to(progress.chapter_index);
    }

    /// 保存跳转前的进度（对应 Kotlin saveCurrentBookProgress）
    pub fn save_current_progress_before_jump(&mut self) {
        if self.last_progress.is_some() {
            return; // 避免连续跳转覆盖最初的进度记录
        }
        self.last_progress = Some(self.save_progress());
    }

    /// 恢复跳转前的进度（对应 Kotlin restoreLastBookProgress）
    pub fn restore_last_progress(&mut self) -> bool {
        if let Some(progress) = self.last_progress.take() {
            self.restore_progress(progress);
            true
        } else {
            false
        }
    }

    // ─── 页内导航 ─────────────────────────────────────────

    /// 翻到下一页（对应 Kotlin moveToNextPage）
    ///
    /// 返回 true 表示成功翻页，false 表示已到本章最后一页
    pub fn next_page(&mut self) -> bool {
        if self.current_page + 1 < self.total_pages {
            self.current_page += 1;
            // 更新字符位置（使用排版引擎的页面对应偏移）
            self.current_position = self.page_start_offset(self.current_page);
            true
        } else {
            false
        }
    }

    /// 翻到上一页（对应 Kotlin moveToPrevPage）
    ///
    /// 返回 true 表示成功翻页，false 表示已到本章第一页
    pub fn prev_page(&mut self) -> bool {
        if self.current_page > 0 {
            self.current_page -= 1;
            self.current_position = self.page_start_offset(self.current_page);
            true
        } else {
            false
        }
    }

    /// 跳转到指定页（对应 Kotlin skipToPage）
    pub fn skip_to_page(&mut self, page_index: usize) -> bool {
        if page_index < self.total_pages {
            self.current_page = page_index;
            self.current_position = self.page_start_offset(page_index);
            true
        } else {
            false
        }
    }

    /// 更新当前章节的排版信息（由外部在章节内容加载后调用）
    ///
    /// - `pages`: 排版引擎计算出的分页结果
    ///
    /// 调用后会根据当前 `current_position` 自动定位到正确页码。
    pub fn update_layout(&mut self, pages: &[LayoutPage]) {
        self.total_pages = pages.len();
        // 根据当前字符位置定位页码
        self.current_page = self.find_page_for_offset(pages, self.current_position);
    }

    /// 使用排版引擎对章节内容进行分页并更新排版信息
    pub fn paginate_and_update(&mut self, content: &str) -> Vec<LayoutPage> {
        let engine = LayoutEngine::new(self.layout_config.clone());
        let pages = engine.paginate(content);
        self.update_layout(&pages);
        pages
    }

    // ─── 章节跳转 ─────────────────────────────────────────

    /// 跳转到下一章（对应 Kotlin moveToNextChapter）
    ///
    /// 自动翻章：读完当前章后加载下一章，位置重置为 0。
    pub fn next_chapter(&mut self) -> ChapterTransition {
        if self.current_chapter >= self.total_chapters - 1 {
            return ChapterTransition::AtLastChapter;
        }
        let from = self.current_chapter;
        self.current_chapter += 1;
        self.current_position = 0;
        self.current_page = 0;
        self.total_pages = 0;
        self.session_chapters_visited += 1;
        // 滑动预加载窗口
        self.preload_state.next();
        ChapterTransition::Success {
            from_index: from,
            to_index: self.current_chapter,
        }
    }

    /// 跳转到上一章（对应 Kotlin moveToPrevChapter）
    ///
    /// - `to_last`: 是否定位到上一章末尾（true = 末尾，false = 开头）
    pub fn prev_chapter(&mut self, to_last: bool) -> ChapterTransition {
        if self.current_chapter <= 0 {
            return ChapterTransition::AtFirstChapter;
        }
        let from = self.current_chapter;
        self.current_chapter -= 1;
        self.current_page = 0;
        self.total_pages = 0;
        self.session_chapters_visited += 1;
        // 定位到上一章末尾或开头
        if to_last {
            // 实际使用时由外部设置正确的末尾位置
            // 此处标记为 usize::MAX 表示"需要外部填充末尾偏移"
            self.current_position = usize::MAX;
        } else {
            self.current_position = 0;
        }
        // 滑动预加载窗口
        self.preload_state.prev();
        ChapterTransition::Success {
            from_index: from,
            to_index: self.current_chapter,
        }
    }

    /// 跳转到指定章节（对应 Kotlin openChapter）
    pub fn jump_to_chapter(&mut self, index: i32, position: usize) -> ChapterTransition {
        if index < 0 || index >= self.total_chapters {
            return ChapterTransition::OutOfBounds {
                target: index,
                total_chapters: self.total_chapters,
            };
        }
        let from = self.current_chapter;
        self.current_chapter = index;
        self.current_position = position;
        self.current_page = 0;
        self.total_pages = 0;
        self.session_chapters_visited += 1;
        // 跳转预加载窗口
        self.preload_state.jump_to(index);
        ChapterTransition::Success {
            from_index: from,
            to_index: index,
        }
    }

    /// 判断是否应该自动翻章（当前页已是最后一页且用户继续翻页）
    pub fn should_auto_next_chapter(&self) -> bool {
        self.total_pages > 0 && self.current_page >= self.total_pages - 1
    }

    /// 自动翻章：如果当前在最后一页，自动跳到下一章
    ///
    /// 返回跳转结果；如果不在最后一页则返回 AtLastChapter（表示无需跳转）
    pub fn auto_next_chapter(&mut self) -> ChapterTransition {
        if !self.should_auto_next_chapter() {
            // 当前不在最后一页，不需要自动翻章
            return ChapterTransition::AtLastChapter;
        }
        self.next_chapter()
    }

    // ─── 阅读统计更新 ─────────────────────────────────────

    /// 更新阅读字数统计（翻页/滚动时调用）
    ///
    /// - `chars`: 本次新增阅读字符数
    pub fn add_chars_read(&mut self, chars: usize) {
        self.session_chars_read += chars;
    }

    /// 根据页面内容长度更新阅读统计（翻页时自动调用）
    pub fn update_reading_stats(&mut self, page_content_len: usize) {
        self.session_chars_read += page_content_len;
    }

    /// 获取累计阅读时长（包含当前会话）
    pub fn total_reading_time(&self) -> Duration {
        let current_session = self.session_start.map(|s| s.elapsed()).unwrap_or_default();
        self.total_reading_time + current_session
    }

    // ─── 阅读模式 ─────────────────────────────────────────

    /// 获取当前阅读模式
    pub fn reading_mode(&self) -> ReadingMode {
        self.reading_mode
    }

    /// 切换阅读模式
    pub fn set_reading_mode(&mut self, mode: ReadingMode) {
        self.reading_mode = mode;
    }

    /// 是否为滚动模式
    pub fn is_scroll_mode(&self) -> bool {
        self.reading_mode.is_scroll()
    }

    // ─── 排版配置 ─────────────────────────────────────────

    /// 更新排版配置（字体大小/屏幕尺寸变化时调用）
    pub fn update_layout_config(&mut self, config: LayoutConfig) {
        self.layout_config = config;
        // 配置变更后需要重新排版（由外部触发）
        self.total_pages = 0;
        self.current_page = 0;
    }

    /// 获取当前排版配置
    pub fn layout_config(&self) -> &LayoutConfig {
        &self.layout_config
    }

    // ─── Getters ──────────────────────────────────────────

    /// 书籍 URL
    pub fn book_url(&self) -> &str {
        &self.book_url
    }

    /// 总章节数
    pub fn total_chapters(&self) -> i32 {
        self.total_chapters
    }

    /// 当前章节索引
    pub fn current_chapter(&self) -> i32 {
        self.current_chapter
    }

    /// 当前字符位置
    pub fn current_position(&self) -> usize {
        self.current_position
    }

    /// 当前页码
    pub fn current_page(&self) -> usize {
        self.current_page
    }

    /// 当前章总页数
    pub fn total_pages(&self) -> usize {
        self.total_pages
    }

    /// 获取预加载状态机的可变引用
    pub fn preload_state_mut(&mut self) -> &mut ReadBookState {
        &mut self.preload_state
    }

    /// 获取预加载状态机的只读引用
    pub fn preload_state(&self) -> &ReadBookState {
        &self.preload_state
    }

    /// 是否有跳转前的进度记录
    pub fn has_saved_progress(&self) -> bool {
        self.last_progress.is_some()
    }

    /// 是否为首章
    pub fn is_first_chapter(&self) -> bool {
        self.current_chapter == 0
    }

    /// 是否为末章
    pub fn is_last_chapter(&self) -> bool {
        self.current_chapter >= self.total_chapters - 1
    }

    /// 是否为第一页
    pub fn is_first_page(&self) -> bool {
        self.current_page == 0
    }

    /// 是否为最后一页
    pub fn is_last_page(&self) -> bool {
        self.total_pages > 0 && self.current_page >= self.total_pages - 1
    }

    // ─── 内部辅助 ─────────────────────────────────────────

    /// 根据页码获取该页起始字符偏移（简化版：等分估算）
    ///
    /// 实际使用时应由外部传入 LayoutPage 数组精确定位。
    fn page_start_offset(&self, page_index: usize) -> usize {
        if self.total_pages == 0 {
            return 0;
        }
        // 简化估算：按页码等分（精确值需排版引擎提供）
        // 外部可通过 update_layout 传入精确分页后使用 find_page_for_offset
        page_index * self.current_position.max(1) / self.current_page.max(1)
    }

    /// 在分页结果中查找字符偏移所在的页码
    fn find_page_for_offset(&self, pages: &[LayoutPage], offset: usize) -> usize {
        pages
            .iter()
            .position(|p| offset >= p.start_offset && offset < p.end_offset)
            .unwrap_or(pages.len().saturating_sub(1))
    }
}

impl Default for ReaderStateMachine {
    fn default() -> Self {
        Self::new("", 0)
    }
}

/// 获取当前 Unix 毫秒时间戳
fn current_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ─── 测试 ─────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_reader(chapters: i32) -> ReaderStateMachine {
        ReaderStateMachine::new("https://example.com/book/1", chapters)
    }

    // ─── 基础创建 ─────────────────────────────────────────

    #[test]
    fn test_new_reader_defaults() {
        let reader = make_reader(100);
        assert_eq!(reader.book_url(), "https://example.com/book/1");
        assert_eq!(reader.total_chapters(), 100);
        assert_eq!(reader.current_chapter(), 0);
        assert_eq!(reader.current_position(), 0);
        assert_eq!(reader.current_page(), 0);
        assert_eq!(reader.reading_mode(), ReadingMode::Simulation);
        assert!(reader.is_first_chapter());
        assert!(!reader.is_last_chapter());
    }

    #[test]
    fn test_reading_mode_conversion() {
        assert_eq!(ReadingMode::from_page_anim(0), ReadingMode::Simulation);
        assert_eq!(ReadingMode::from_page_anim(1), ReadingMode::Slide);
        assert_eq!(ReadingMode::from_page_anim(2), ReadingMode::Slide);
        assert_eq!(ReadingMode::from_page_anim(3), ReadingMode::Scroll);
        assert_eq!(ReadingMode::from_page_anim(99), ReadingMode::Simulation);

        assert_eq!(ReadingMode::Simulation.to_page_anim(), 0);
        assert_eq!(ReadingMode::Slide.to_page_anim(), 1);
        assert_eq!(ReadingMode::Scroll.to_page_anim(), 3);
    }

    #[test]
    fn test_reading_mode_scroll() {
        assert!(!ReadingMode::Simulation.is_scroll());
        assert!(!ReadingMode::Slide.is_scroll());
        assert!(ReadingMode::Scroll.is_scroll());
    }

    #[allow(unused_comparisons)]

    // ─── 阅读模式切换 ─────────────────────────────────────

    #[test]
    fn test_set_reading_mode() {
        let mut reader = make_reader(10);
        assert_eq!(reader.reading_mode(), ReadingMode::Simulation);
        reader.set_reading_mode(ReadingMode::Scroll);
        assert_eq!(reader.reading_mode(), ReadingMode::Scroll);
        assert!(reader.is_scroll_mode());
    }

    // ─── 章节跳转 ─────────────────────────────────────────

    #[test]
    fn test_next_chapter_success() {
        let mut reader = make_reader(10);
        let result = reader.next_chapter();
        assert!(result.is_success());
        assert_eq!(reader.current_chapter(), 1);
        assert_eq!(reader.current_position(), 0);
        assert_eq!(reader.current_page(), 0);
    }

    #[test]
    fn test_next_chapter_at_last() {
        let mut reader = make_reader(1);
        let result = reader.next_chapter();
        assert_eq!(result, ChapterTransition::AtLastChapter);
        assert_eq!(reader.current_chapter(), 0);
    }

    #[test]
    fn test_prev_chapter_success() {
        let mut reader = make_reader(10);
        reader.jump_to_chapter(5, 0);
        let result = reader.prev_chapter(false);
        assert!(result.is_success());
        assert_eq!(reader.current_chapter(), 4);
        assert_eq!(reader.current_position(), 0);
    }

    #[test]
    fn test_prev_chapter_to_last() {
        let mut reader = make_reader(10);
        reader.jump_to_chapter(5, 0);
        let result = reader.prev_chapter(true);
        assert!(result.is_success());
        assert_eq!(reader.current_chapter(), 4);
        // to_last=true 时位置标记为 MAX（由外部填充）
        assert_eq!(reader.current_position(), usize::MAX);
    }

    #[test]
    fn test_prev_chapter_at_first() {
        let mut reader = make_reader(10);
        let result = reader.prev_chapter(false);
        assert_eq!(result, ChapterTransition::AtFirstChapter);
        assert_eq!(reader.current_chapter(), 0);
    }

    #[test]
    fn test_jump_to_chapter() {
        let mut reader = make_reader(100);
        let result = reader.jump_to_chapter(50, 128);
        assert!(result.is_success());
        assert_eq!(reader.current_chapter(), 50);
        assert_eq!(reader.current_position(), 128);
    }

    #[test]
    fn test_jump_to_chapter_out_of_bounds() {
        let mut reader = make_reader(10);
        let result = reader.jump_to_chapter(10, 0);
        assert_eq!(
            result,
            ChapterTransition::OutOfBounds {
                target: 10,
                total_chapters: 10
            }
        );
        let result = reader.jump_to_chapter(-1, 0);
        assert_eq!(
            result,
            ChapterTransition::OutOfBounds {
                target: -1,
                total_chapters: 10
            }
        );
    }

    #[test]
    fn test_chapter_transition_details() {
        let mut reader = make_reader(10);
        let result = reader.next_chapter();
        assert_eq!(
            result,
            ChapterTransition::Success {
                from_index: 0,
                to_index: 1
            }
        );
    }

    // ─── 自动翻章 ─────────────────────────────────────────

    #[test]
    fn test_should_auto_next_chapter_false() {
        let reader = make_reader(10);
        // 没有排版信息时不触发
        assert!(!reader.should_auto_next_chapter());
    }

    #[test]
    fn test_should_auto_next_chapter_true() {
        let mut reader = make_reader(10);
        // 模拟排版：5 页
        let pages = make_pages(5);
        reader.update_layout(&pages);
        reader.skip_to_page(4); // 最后一页
        assert!(reader.should_auto_next_chapter());
    }

    #[test]
    fn test_auto_next_chapter() {
        let mut reader = make_reader(10);
        let pages = make_pages(3);
        reader.update_layout(&pages);
        reader.skip_to_page(2); // 最后一页
        let result = reader.auto_next_chapter();
        assert!(result.is_success());
        assert_eq!(reader.current_chapter(), 1);
        assert_eq!(reader.current_position(), 0);
    }

    #[test]
    fn test_auto_next_chapter_not_at_last_page() {
        let mut reader = make_reader(10);
        let pages = make_pages(5);
        reader.update_layout(&pages);
        reader.skip_to_page(2); // 中间页
        let result = reader.auto_next_chapter();
        // 不在最后一页，返回 AtLastChapter（表示无需跳转）
        assert_eq!(result, ChapterTransition::AtLastChapter);
        assert_eq!(reader.current_chapter(), 0);
    }

    // ─── 页内导航 ─────────────────────────────────────────

    #[test]
    fn test_next_page() {
        let mut reader = make_reader(10);
        let pages = make_pages(5);
        reader.update_layout(&pages);
        assert_eq!(reader.current_page(), 0);
        assert!(reader.next_page());
        assert_eq!(reader.current_page(), 1);
        assert!(reader.next_page());
        assert_eq!(reader.current_page(), 2);
    }

    #[test]
    fn test_next_page_at_last() {
        let mut reader = make_reader(10);
        let pages = make_pages(3);
        reader.update_layout(&pages);
        reader.skip_to_page(2);
        assert!(!reader.next_page()); // 已是最后一页
        assert_eq!(reader.current_page(), 2);
    }

    #[test]
    fn test_prev_page() {
        let mut reader = make_reader(10);
        let pages = make_pages(5);
        reader.update_layout(&pages);
        reader.skip_to_page(3);
        assert!(reader.prev_page());
        assert_eq!(reader.current_page(), 2);
    }

    #[test]
    fn test_prev_page_at_first() {
        let mut reader = make_reader(10);
        let pages = make_pages(5);
        reader.update_layout(&pages);
        assert!(!reader.prev_page()); // 已是第一页
        assert_eq!(reader.current_page(), 0);
    }

    #[test]
    fn test_skip_to_page() {
        let mut reader = make_reader(10);
        let pages = make_pages(10);
        reader.update_layout(&pages);
        assert!(reader.skip_to_page(7));
        assert_eq!(reader.current_page(), 7);
        assert!(!reader.skip_to_page(10)); // 超出范围
        assert_eq!(reader.current_page(), 7);
    }

    #[test]
    fn test_is_first_last_page() {
        let mut reader = make_reader(10);
        let pages = make_pages(5);
        reader.update_layout(&pages);
        assert!(reader.is_first_page());
        assert!(!reader.is_last_page());
        reader.skip_to_page(4);
        assert!(!reader.is_first_page());
        assert!(reader.is_last_page());
    }

    // ─── 进度保存与恢复 ───────────────────────────────────

    #[test]
    fn test_save_progress() {
        let mut reader = make_reader(50);
        reader.jump_to_chapter(10, 256);
        let pages = make_pages(8);
        reader.update_layout(&pages);

        let progress = reader.save_progress();
        assert_eq!(progress.book_url, "https://example.com/book/1");
        assert_eq!(progress.chapter_index, 10);
        assert_eq!(progress.chapter_pos, 256);
        assert_eq!(progress.total_pages, 8);
        assert!(progress.saved_at > 0);
    }

    #[test]
    fn test_restore_progress() {
        let mut reader = make_reader(50);
        let progress = ReadingProgress {
            book_url: "https://example.com/book/1".to_string(),
            chapter_index: 25,
            chapter_pos: 512,
            page_index: 3,
            total_pages: 10,
            saved_at: current_millis(),
        };
        reader.restore_progress(progress);
        assert_eq!(reader.current_chapter(), 25);
        assert_eq!(reader.current_position(), 512);
        assert_eq!(reader.current_page(), 3);
        assert_eq!(reader.total_pages(), 10);
    }

    #[test]
    fn test_save_and_restore_before_jump() {
        let mut reader = make_reader(50);
        reader.jump_to_chapter(10, 100);
        let pages = make_pages(5);
        reader.update_layout(&pages);

        // 保存跳转前进度
        reader.save_current_progress_before_jump();
        assert!(reader.has_saved_progress());

        // 跳转到新位置
        reader.jump_to_chapter(30, 0);
        assert_eq!(reader.current_chapter(), 30);

        // 恢复跳转前进度
        assert!(reader.restore_last_progress());
        assert_eq!(reader.current_chapter(), 10);
        assert_eq!(reader.current_position(), 100);
        assert!(!reader.has_saved_progress());
    }

    #[test]
    fn test_save_progress_no_overwrite_on_consecutive_jumps() {
        let mut reader = make_reader(50);
        reader.jump_to_chapter(5, 0);

        // 第一次保存
        reader.save_current_progress_before_jump();
        // 跳转
        reader.jump_to_chapter(10, 0);
        // 第二次保存应被忽略（避免覆盖最初进度）
        reader.save_current_progress_before_jump();
        reader.jump_to_chapter(20, 0);

        // 恢复应回到 chapter 5
        reader.restore_last_progress();
        assert_eq!(reader.current_chapter(), 5);
    }

    #[test]
    fn test_restore_last_progress_none() {
        let mut reader = make_reader(10);
        assert!(!reader.restore_last_progress());
    }

    #[test]
    fn test_progress_percentage() {
        let progress = ReadingProgress {
            book_url: "test".to_string(),
            chapter_index: 0,
            chapter_pos: 0,
            page_index: 5,
            total_pages: 10,
            saved_at: 0,
        };
        assert!((progress.percentage() - 0.5).abs() < f64::EPSILON);

        let empty = ReadingProgress::new("test", 0, 0);
        assert_eq!(empty.percentage(), 0.0);
    }

    // ─── 阅读统计 ─────────────────────────────────────────

    #[test]
    fn test_start_and_end_session() {
        let mut reader = make_reader(10);
        reader.start_session();
        reader.add_chars_read(500);

        // 模拟阅读了一段时间
        std::thread::sleep(Duration::from_millis(10));

        let session = reader.end_session();
        assert!(session.is_some());
        let session = session.unwrap();
        assert_eq!(session.book_url, "https://example.com/book/1");
        assert_eq!(session.word_count, 500);
        assert!(session.reading_speed >= 0.0);
        assert!(session.end_time.unwrap() >= session.start_time);
    }

    #[test]
    fn test_end_session_without_start() {
        let mut reader = make_reader(10);
        assert!(reader.end_session().is_none());
    }

    #[test]
    fn test_live_stats() {
        let mut reader = make_reader(10);
        reader.start_session();
        reader.add_chars_read(300);

        let stats = reader.live_stats();
        assert_eq!(stats.chars_read, 300);
        assert_eq!(stats.chapters_visited, 1);
        assert!(stats.elapsed.as_millis() < u128::MAX); // 时间有效
    }

    #[test]
    fn test_update_reading_stats() {
        let mut reader = make_reader(10);
        reader.start_session();
        reader.update_reading_stats(200);
        reader.update_reading_stats(150);
        let stats = reader.live_stats();
        assert_eq!(stats.chars_read, 350);
    }

    #[test]
    fn test_total_reading_time_accumulates() {
        let mut reader = make_reader(10);
        // 第一次会话
        reader.start_session();
        std::thread::sleep(Duration::from_millis(5));
        reader.end_session();

        let time_after_first = reader.total_reading_time();
        assert!(time_after_first.as_millis() >= 5);

        // 第二次会话
        reader.start_session();
        std::thread::sleep(Duration::from_millis(5));
        reader.end_session();

        let time_after_second = reader.total_reading_time();
        assert!(time_after_second > time_after_first);
    }

    #[test]
    fn test_chapters_visited_increments() {
        let mut reader = make_reader(10);
        reader.start_session();
        assert_eq!(reader.live_stats().chapters_visited, 1);
        reader.next_chapter();
        assert_eq!(reader.live_stats().chapters_visited, 2);
        reader.next_chapter();
        assert_eq!(reader.live_stats().chapters_visited, 3);
    }

    // ─── 排版集成 ─────────────────────────────────────────

    #[test]
    fn test_paginate_and_update() {
        let config = LayoutConfig {
            chars_per_line: Some(10),
            lines_per_page: Some(3),
            ..LayoutConfig::default()
        };
        let mut reader = ReaderStateMachine::with_layout_config(
            "https://example.com/book/1",
            10,
            config,
        );
        let content = "这是一段很长的文本内容用来测试分页功能是否正确工作";
        let pages = reader.paginate_and_update(content);
        assert!(!pages.is_empty());
        assert_eq!(reader.total_pages(), pages.len());
    }

    #[test]
    fn test_update_layout_positions_correctly() {
        let mut reader = make_reader(10);
        let pages = vec![
            LayoutPage {
                index: 0,
                content: "page0".to_string(),
                start_offset: 0,
                end_offset: 100,
                line_count: 5,
            },
            LayoutPage {
                index: 1,
                content: "page1".to_string(),
                start_offset: 100,
                end_offset: 200,
                line_count: 5,
            },
            LayoutPage {
                index: 2,
                content: "page2".to_string(),
                start_offset: 200,
                end_offset: 300,
                line_count: 5,
            },
        ];
        // 设置位置为 150（应在第 2 页）
        reader.jump_to_chapter(0, 150);
        reader.update_layout(&pages);
        assert_eq!(reader.current_page(), 1);
        assert_eq!(reader.total_pages(), 3);
    }

    #[test]
    fn test_update_layout_config_resets() {
        let mut reader = make_reader(10);
        let pages = make_pages(5);
        reader.update_layout(&pages);
        assert_eq!(reader.total_pages(), 5);

        reader.update_layout_config(LayoutConfig {
            font_size: 24.0,
            ..LayoutConfig::default()
        });
        // 配置变更后排版信息重置
        assert_eq!(reader.total_pages(), 0);
        assert_eq!(reader.current_page(), 0);
    }

    // ─── 预加载窗口集成 ───────────────────────────────────

    #[test]
    fn test_preload_state_syncs_on_jump() {
        let mut reader = make_reader(100);
        reader.preload_state_mut().cache_chapter(
            crate::read_state::TextChapter {
                index: 50,
                title: "Ch50".to_string(),
                content: "content".to_string(),
                url: "url".to_string(),
            },
        );
        reader.jump_to_chapter(50, 0);
        assert_eq!(reader.preload_state().cur_index(), 50);
    }

    #[test]
    fn test_preload_state_syncs_on_next() {
        let mut reader = make_reader(100);
        reader.jump_to_chapter(10, 0);
        reader.next_chapter();
        assert_eq!(reader.preload_state().cur_index(), 11);
    }

    // ─── 边界条件 ─────────────────────────────────────────

    #[test]
    fn test_single_chapter_book() {
        let mut reader = make_reader(1);
        assert!(reader.is_first_chapter());
        assert!(reader.is_last_chapter());
        assert_eq!(reader.next_chapter(), ChapterTransition::AtLastChapter);
        assert_eq!(reader.prev_chapter(false), ChapterTransition::AtFirstChapter);
    }

    #[test]
    fn test_zero_chapter_book() {
        let mut reader = make_reader(0);
        assert_eq!(reader.next_chapter(), ChapterTransition::AtLastChapter);
        assert_eq!(reader.prev_chapter(false), ChapterTransition::AtFirstChapter);
    }

    #[test]
    fn test_sequential_reading_flow() {
        // 模拟完整阅读流程：打开 → 阅读 → 翻章 → 保存 → 关闭
        let mut reader = make_reader(5);
        reader.start_session();

        // 排版第一章
        let pages = make_pages(3);
        reader.update_layout(&pages);

        // 翻页阅读
        reader.next_page();
        reader.update_reading_stats(100);
        reader.next_page();
        reader.update_reading_stats(100);

        // 到最后一页，自动翻章
        assert!(reader.should_auto_next_chapter());
        let transition = reader.auto_next_chapter();
        assert!(transition.is_success());
        assert_eq!(reader.current_chapter(), 1);

        // 排版第二章
        let pages2 = make_pages(4);
        reader.update_layout(&pages2);
        reader.update_reading_stats(150);

        // 保存进度
        let progress = reader.save_progress();
        assert_eq!(progress.chapter_index, 1);

        // 结束会话
        let session = reader.end_session();
        assert!(session.is_some());
        assert_eq!(session.unwrap().word_count, 350);
    }

    // ─── 辅助函数 ─────────────────────────────────────────

    /// 生成指定数量的虚拟分页
    fn make_pages(count: usize) -> Vec<LayoutPage> {
        (0..count)
            .map(|i| LayoutPage {
                index: i,
                content: format!("page content {}", i),
                start_offset: i * 100,
                end_offset: (i + 1) * 100,
                line_count: 5,
            })
            .collect()
    }
}
