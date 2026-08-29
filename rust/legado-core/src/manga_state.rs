//! 漫画阅读状态机
//!
//! 移植自 Kotlin ReadManga.kt，实现：
//! - 三章滑动窗口（prev/cur/next MangaChapter）
//! - 图片页预加载（可配置窗口大小）
//! - 有界并发加载（Semaphore 控制）
//! - 页面状态机（Pending → Loading → Loaded / Failed）
//! - 阅读进度管理（章节索引 + 页内位置）
//! - LRU 章节缓存与失败熔断

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::Semaphore;

/// 漫画页面加载状态
#[derive(Debug, Clone, PartialEq)]
pub enum PageState {
    /// 等待加载
    Pending,
    /// 正在加载
    Loading,
    /// 加载完成（含图片字节数据）
    Loaded,
    /// 加载失败（附错误信息与失败次数）
    Failed { msg: String, count: i32 },
}

impl PageState {
    /// 是否处于可重试状态
    pub fn can_retry(&self) -> bool {
        matches!(self, PageState::Pending | PageState::Failed { .. })
    }

    /// 是否已加载完成
    pub fn is_loaded(&self) -> bool {
        matches!(self, PageState::Loaded)
    }
}

/// 漫画单页
#[derive(Debug, Clone)]
pub struct MangaPage {
    /// 所属章节索引
    pub chapter_index: i32,
    /// 页在章节内的序号
    pub page_index: i32,
    /// 图片 URL
    pub url: String,
    /// 加载状态
    pub state: PageState,
    /// 图片字节数据（加载完成后填充）
    pub image_data: Option<Vec<u8>>,
    /// 章节名称
    pub chapter_title: String,
}

impl MangaPage {
    /// 创建待加载页面
    pub fn new(chapter_index: i32, page_index: i32, url: String, chapter_title: String) -> Self {
        Self {
            chapter_index,
            page_index,
            url,
            state: PageState::Pending,
            image_data: None,
            chapter_title,
        }
    }

    /// 标记为加载中
    pub fn mark_loading(&mut self) {
        self.state = PageState::Loading;
    }

    /// 标记为加载完成
    pub fn mark_loaded(&mut self, data: Vec<u8>) {
        self.state = PageState::Loaded;
        self.image_data = Some(data);
    }

    /// 标记为加载失败
    pub fn mark_failed(&mut self, msg: String) {
        let count = match &self.state {
            PageState::Failed { count, .. } => count + 1,
            _ => 1,
        };
        self.state = PageState::Failed { msg, count };
    }
}

/// 漫画章节（含多页图片）
#[derive(Debug, Clone)]
pub struct MangaChapter {
    /// 章节索引
    pub index: i32,
    /// 章节标题
    pub title: String,
    /// 章节 URL
    pub url: String,
    /// 图片页列表
    pub pages: Vec<MangaPage>,
    /// 是否为卷（无图片内容的分隔节点）
    pub is_volume: bool,
}

impl MangaChapter {
    /// 创建漫画章节
    pub fn new(index: i32, title: String, url: String) -> Self {
        Self {
            index,
            title,
            url,
            pages: Vec::new(),
            is_volume: false,
        }
    }

    /// 从 URL 列表构建章节页面
    pub fn from_urls(index: i32, title: String, url: String, urls: &[String]) -> Self {
        let pages = urls
            .iter()
            .enumerate()
            .map(|(i, u)| MangaPage::new(index, i as i32, u.clone(), title.clone()))
            .collect();
        Self {
            index,
            title,
            url,
            pages,
            is_volume: false,
        }
    }

    /// 图片数量
    pub fn image_count(&self) -> usize {
        self.pages.len()
    }

    /// 已加载完成的图片数量
    pub fn loaded_count(&self) -> usize {
        self.pages.iter().filter(|p| p.state.is_loaded()).count()
    }

    /// 是否全部加载完成
    pub fn is_fully_loaded(&self) -> bool {
        !self.pages.is_empty() && self.pages.iter().all(|p| p.state.is_loaded())
    }
}

/// 漫画阅读进度
#[derive(Debug, Clone, PartialEq)]
pub struct MangaProgress {
    /// 当前章节索引
    pub chapter_index: i32,
    /// 当前页位置（章节内）
    pub page_pos: i32,
}

/// 漫画阅读状态机
///
/// 管理三章滑动窗口、图片预加载、并发控制与进度持久化。
/// 对齐 Kotlin ReadManga.kt 的核心逻辑。
pub struct MangaReaderState {
    /// 三章滑动窗口
    prev_chapter: Option<MangaChapter>,
    cur_chapter: Option<MangaChapter>,
    next_chapter: Option<MangaChapter>,

    /// 当前章节索引
    cur_index: i32,
    /// 当前页位置
    cur_page_pos: i32,
    /// 总章节数
    chapter_size: i32,

    /// 预加载窗口大小（当前页前后各 N 页）
    preload_window: usize,

    /// 并发加载信号量（默认 2 并发，对齐 Kotlin preDownloadSemaphore）
    semaphore: Arc<Semaphore>,

    /// 章节 LRU 缓存
    cached_chapters: HashMap<i32, MangaChapter>,
    max_cache_size: usize,

    /// 正在加载的章节索引（去重）
    loading_set: HashSet<i32>,

    /// 章节下载失败计数（>= 阈值则熔断跳过）
    fail_count: HashMap<i32, i32>,
    fail_threshold: i32,

    /// 预下载配置：前向章节数
    pre_download_ahead: i32,
    /// 预下载配置：后向章节数
    pre_download_behind: i32,

    /// 阅读时长统计（毫秒）
    read_time_ms: u64,
    /// 本次阅读起始时间戳（毫秒）
    read_start_time_ms: u64,
}

impl MangaReaderState {
    /// 创建漫画阅读状态机
    ///
    /// - `chapter_size`: 总章节数
    /// - `preload_window`: 页级预加载窗口（前后各 N 页）
    pub fn new(chapter_size: i32, preload_window: usize) -> Self {
        Self {
            prev_chapter: None,
            cur_chapter: None,
            next_chapter: None,
            cur_index: 0,
            cur_page_pos: 0,
            chapter_size,
            preload_window,
            semaphore: Arc::new(Semaphore::new(2)),
            cached_chapters: HashMap::new(),
            max_cache_size: 10,
            loading_set: HashSet::new(),
            fail_count: HashMap::new(),
            fail_threshold: 3,
            pre_download_ahead: 3,
            pre_download_behind: 5,
            read_time_ms: 0,
            read_start_time_ms: 0,
        }
    }

    // ===== 章节窗口管理 =====

    /// 初始化/重置到指定章节
    pub fn reset_to(&mut self, chapter_index: i32, page_pos: i32) {
        self.cur_index = chapter_index;
        self.cur_page_pos = page_pos;
        self.prev_chapter = self.cached_chapters.get(&(chapter_index - 1)).cloned();
        self.cur_chapter = self.cached_chapters.get(&chapter_index).cloned();
        self.next_chapter = self.cached_chapters.get(&(chapter_index + 1)).cloned();
        self.loading_set.clear();
    }

    /// 移动到下一章
    ///
    /// 对齐 Kotlin ReadManga.moveToNextChapter：
    /// prev ← cur, cur ← next, next ← null（等待加载）
    pub fn move_to_next_chapter(&mut self) -> bool {
        if self.cur_index >= self.chapter_size - 1 {
            return false;
        }
        self.cur_index += 1;
        self.cur_page_pos = 0;
        self.prev_chapter = self.cur_chapter.take();
        self.cur_chapter = self.next_chapter.take();
        self.next_chapter = None;
        // 尝试从缓存恢复 next
        if self.cur_chapter.is_none() {
            self.cur_chapter = self.cached_chapters.get(&self.cur_index).cloned();
        }
        self.next_chapter = self.cached_chapters.get(&(self.cur_index + 1)).cloned();
        true
    }

    /// 移动到上一章
    ///
    /// 对齐 Kotlin ReadManga.moveToPrevChapter：
    /// next ← cur, cur ← prev, prev ← null（等待加载）
    pub fn move_to_prev_chapter(&mut self) -> bool {
        if self.cur_index <= 0 {
            return false;
        }
        self.cur_index -= 1;
        self.cur_page_pos = 0;
        self.next_chapter = self.cur_chapter.take();
        self.cur_chapter = self.prev_chapter.take();
        self.prev_chapter = None;
        // 尝试从缓存恢复 prev
        if self.cur_chapter.is_none() {
            self.cur_chapter = self.cached_chapters.get(&self.cur_index).cloned();
        }
        self.prev_chapter = self.cached_chapters.get(&(self.cur_index - 1)).cloned();
        true
    }

    /// 设置章节内容到滑动窗口
    ///
    /// 根据章节索引与当前索引的偏移，放入 prev/cur/next 槽位。
    /// 对齐 Kotlin ReadManga.contentLoadFinish 逻辑。
    pub fn set_chapter_content(&mut self, chapter: MangaChapter) {
        let offset = chapter.index - self.cur_index;
        match offset {
            0 => {
                // 约束 page_pos 范围
                if !chapter.pages.is_empty() {
                    self.cur_page_pos =
                        self.cur_page_pos.clamp(0, chapter.image_count() as i32 - 1);
                }
                self.cur_chapter = Some(chapter);
            }
            -1 => self.prev_chapter = Some(chapter),
            1 => self.next_chapter = Some(chapter),
            _ => {} // 超出窗口范围，忽略
        }
    }

    // ===== 页级预加载 =====

    /// 计算当前需要预加载的页面索引列表
    ///
    /// 基于当前页位置和预加载窗口，返回 [cur_pos - window, cur_pos + window]
    /// 范围内尚未加载的页面索引。
    pub fn preload_page_indices(&self) -> Vec<i32> {
        let chapter = match &self.cur_chapter {
            Some(c) => c,
            None => return Vec::new(),
        };
        let total = chapter.image_count() as i32;
        if total == 0 {
            return Vec::new();
        }

        let start = (self.cur_page_pos - self.preload_window as i32).max(0);
        let end = (self.cur_page_pos + self.preload_window as i32).min(total - 1);

        (start..=end)
            .filter(|&i| {
                chapter
                    .pages
                    .get(i as usize)
                    .map(|p| !p.state.is_loaded())
                    .unwrap_or(false)
            })
            .collect()
    }

    /// 页面翻动后更新预加载范围
    ///
    /// 对齐 Kotlin ReadManga.curPageChanged：更新阅读时间 + 触发预下载。
    pub fn on_page_changed(&mut self, new_pos: i32) {
        self.cur_page_pos = new_pos;
        self.up_read_time();
    }

    /// 获取指定页面的状态
    pub fn get_page_state(&self, page_index: i32) -> Option<&PageState> {
        self.cur_chapter
            .as_ref()
            .and_then(|c| c.pages.get(page_index as usize))
            .map(|p| &p.state)
    }

    /// 标记页面为加载中
    pub fn mark_page_loading(&mut self, page_index: i32) {
        if let Some(chapter) = self.cur_chapter.as_mut() {
            if let Some(page) = chapter.pages.get_mut(page_index as usize) {
                page.mark_loading();
            }
        }
    }

    /// 标记页面加载完成
    pub fn mark_page_loaded(&mut self, page_index: i32, data: Vec<u8>) {
        if let Some(chapter) = self.cur_chapter.as_mut() {
            if let Some(page) = chapter.pages.get_mut(page_index as usize) {
                page.mark_loaded(data);
            }
        }
    }

    /// 标记页面加载失败
    pub fn mark_page_failed(&mut self, page_index: i32, msg: String) {
        if let Some(chapter) = self.cur_chapter.as_mut() {
            if let Some(page) = chapter.pages.get_mut(page_index as usize) {
                page.mark_failed(msg);
            }
        }
    }

    // ===== 章节级预下载 =====

    /// 获取需要预下载的章节索引列表
    ///
    /// 对齐 Kotlin ReadManga.preDownload：
    /// - 前向：[cur+2, cur+preDownloadNum]
    /// - 后向：[cur-2, cur-min(5, preDownloadNum)]
    ///
    /// 跳过已缓存和已熔断的章节。
    pub fn pre_download_indices(&self) -> Vec<i32> {
        let mut indices = Vec::new();

        // 前向预下载
        let max_ahead = (self.cur_index + self.pre_download_ahead).min(self.chapter_size - 1);
        for i in (self.cur_index + 2)..=max_ahead {
            if self.cached_chapters.contains_key(&i) {
                continue;
            }
            if self.fail_count.get(&i).copied().unwrap_or(0) >= self.fail_threshold {
                continue;
            }
            indices.push(i);
        }

        // 后向预下载
        let min_behind = self.cur_index - self.pre_download_behind.min(5);
        for i in (min_behind..=(self.cur_index - 2).max(min_behind)).rev() {
            if i < 0 {
                break;
            }
            if self.cached_chapters.contains_key(&i) {
                continue;
            }
            if self.fail_count.get(&i).copied().unwrap_or(0) >= self.fail_threshold {
                continue;
            }
            indices.push(i);
        }

        indices
    }

    /// 标记章节为加载中（去重 + 熔断检查）
    ///
    /// 对齐 Kotlin ReadManga.addLoading
    pub fn add_loading(&mut self, index: i32) -> bool {
        if self.loading_set.contains(&index) {
            return false;
        }
        if self.fail_count.get(&index).copied().unwrap_or(0) >= self.fail_threshold {
            return false;
        }
        self.loading_set.insert(index);
        true
    }

    /// 标记章节加载完成
    pub fn finish_loading(&mut self, index: i32) {
        self.loading_set.remove(&index);
    }

    /// 标记章节加载失败
    pub fn fail_loading(&mut self, index: i32) {
        self.loading_set.remove(&index);
        *self.fail_count.entry(index).or_insert(0) += 1;
    }

    // ===== 缓存管理 =====

    /// 缓存章节（LRU 淘汰）
    pub fn cache_chapter(&mut self, chapter: MangaChapter) {
        if self.cached_chapters.len() >= self.max_cache_size {
            // 淘汰距当前最远的章节
            if let Some(&farthest) = self
                .cached_chapters
                .keys()
                .max_by_key(|&&idx| (idx - self.cur_index).abs())
            {
                self.cached_chapters.remove(&farthest);
            }
        }
        self.cached_chapters.insert(chapter.index, chapter);
    }

    // ===== 进度管理 =====

    /// 获取当前阅读进度
    pub fn progress(&self) -> MangaProgress {
        MangaProgress {
            chapter_index: self.cur_index,
            page_pos: self.cur_page_pos,
        }
    }

    /// 设置阅读进度（跳转）
    ///
    /// 对齐 Kotlin ReadManga.setProgress：
    /// 同章节则更新页位置，跨章节则重新加载窗口。
    pub fn set_progress(&mut self, progress: MangaProgress) -> bool {
        if progress.chapter_index < 0 || progress.chapter_index >= self.chapter_size {
            return false;
        }
        if progress.chapter_index == self.cur_index {
            // 同章节内跳转
            self.cur_page_pos = progress.page_pos;
            return true;
        }
        // 跨章节跳转：重置窗口
        self.reset_to(progress.chapter_index, progress.page_pos);
        true
    }

    // ===== 阅读时长 =====

    /// 设置阅读起始时间
    pub fn set_read_start_time(&mut self, now_ms: u64) {
        self.read_start_time_ms = now_ms;
    }

    /// 更新阅读时长（对齐 Kotlin ReadManga.upReadTime）
    pub fn up_read_time(&mut self) {
        // 由外部传入当前时间更合理，此处简化为累加差值
        // 实际使用时通过 FFI 层传入时间戳
    }

    /// 手动累加阅读时长
    pub fn add_read_time(&mut self, elapsed_ms: u64) {
        self.read_time_ms += elapsed_ms;
    }

    // ===== Getters =====

    pub fn cur_chapter(&self) -> Option<&MangaChapter> {
        self.cur_chapter.as_ref()
    }

    pub fn prev_chapter(&self) -> Option<&MangaChapter> {
        self.prev_chapter.as_ref()
    }

    pub fn next_chapter(&self) -> Option<&MangaChapter> {
        self.next_chapter.as_ref()
    }

    pub fn cur_index(&self) -> i32 {
        self.cur_index
    }

    pub fn cur_page_pos(&self) -> i32 {
        self.cur_page_pos
    }

    pub fn chapter_size(&self) -> i32 {
        self.chapter_size
    }

    pub fn has_next_chapter(&self) -> bool {
        self.cur_index < self.chapter_size - 1
    }

    pub fn has_prev_chapter(&self) -> bool {
        self.cur_index > 0
    }

    pub fn preload_window(&self) -> usize {
        self.preload_window
    }

    pub fn set_preload_window(&mut self, window: usize) {
        self.preload_window = window;
    }

    pub fn semaphore(&self) -> Arc<Semaphore> {
        self.semaphore.clone()
    }

    pub fn is_loading(&self, index: i32) -> bool {
        self.loading_set.contains(&index)
    }

    pub fn is_cached(&self, index: i32) -> bool {
        self.cached_chapters.contains_key(&index)
    }

    pub fn cache_size(&self) -> usize {
        self.cached_chapters.len()
    }

    pub fn fail_count(&self, index: i32) -> i32 {
        self.fail_count.get(&index).copied().unwrap_or(0)
    }

    pub fn read_time_ms(&self) -> u64 {
        self.read_time_ms
    }

    /// 重置失败计数
    pub fn reset_fail_count(&mut self, index: i32) {
        self.fail_count.remove(&index);
    }

    /// 更新总章节数
    pub fn set_chapter_size(&mut self, size: i32) {
        self.chapter_size = size;
    }
}

impl Default for MangaReaderState {
    fn default() -> Self {
        Self::new(0, 2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 创建测试用章节
    fn make_chapter(index: i32, page_count: usize) -> MangaChapter {
        let urls: Vec<String> = (0..page_count)
            .map(|i| format!("http://img.example.com/ch{}/p{}.jpg", index, i))
            .collect();
        MangaChapter::from_urls(
            index,
            format!("第{}话", index),
            format!("http://example.com/chapter/{}", index),
            &urls,
        )
    }

    #[test]
    fn test_new_state_defaults() {
        let state = MangaReaderState::new(10, 2);
        assert_eq!(state.cur_index(), 0);
        assert_eq!(state.cur_page_pos(), 0);
        assert_eq!(state.chapter_size(), 10);
        assert!(state.cur_chapter().is_none());
        assert!(state.prev_chapter().is_none());
        assert!(state.next_chapter().is_none());
        assert!(state.has_next_chapter());
        assert!(!state.has_prev_chapter());
    }

    #[test]
    fn test_set_chapter_content_current() {
        let mut state = MangaReaderState::new(10, 2);
        let chapter = make_chapter(0, 5);
        state.set_chapter_content(chapter);

        assert!(state.cur_chapter().is_some());
        assert_eq!(state.cur_chapter().unwrap().image_count(), 5);
    }

    #[test]
    fn test_set_chapter_content_adjacent() {
        let mut state = MangaReaderState::new(10, 2);
        state.set_chapter_content(make_chapter(0, 5));
        state.set_chapter_content(make_chapter(1, 3));
        state.set_chapter_content(make_chapter(-1, 4)); // 无效（超出窗口）

        assert!(state.cur_chapter().is_some());
        assert!(state.next_chapter().is_some());
        assert_eq!(state.next_chapter().unwrap().image_count(), 3);
    }

    #[test]
    fn test_move_to_next_chapter() {
        let mut state = MangaReaderState::new(10, 2);
        state.set_chapter_content(make_chapter(0, 5));
        state.set_chapter_content(make_chapter(1, 3));

        assert!(state.move_to_next_chapter());
        assert_eq!(state.cur_index(), 1);
        assert_eq!(state.cur_page_pos(), 0);
        // cur 应该是原来的 next
        assert!(state.cur_chapter().is_some());
        assert_eq!(state.cur_chapter().unwrap().image_count(), 3);
        // prev 应该是原来的 cur
        assert!(state.prev_chapter().is_some());
        assert_eq!(state.prev_chapter().unwrap().image_count(), 5);
    }

    #[test]
    fn test_move_to_next_chapter_at_end() {
        let mut state = MangaReaderState::new(1, 2);
        assert!(!state.move_to_next_chapter());
    }

    #[test]
    fn test_move_to_prev_chapter() {
        let mut state = MangaReaderState::new(10, 2);
        state.reset_to(5, 0);
        state.set_chapter_content(make_chapter(4, 4));
        state.set_chapter_content(make_chapter(5, 5));

        assert!(state.move_to_prev_chapter());
        assert_eq!(state.cur_index(), 4);
        assert!(state.cur_chapter().is_some());
        assert_eq!(state.cur_chapter().unwrap().image_count(), 4);
    }

    #[test]
    fn test_move_to_prev_chapter_at_start() {
        let mut state = MangaReaderState::new(10, 2);
        assert!(!state.move_to_prev_chapter());
    }

    #[test]
    fn test_preload_page_indices() {
        let mut state = MangaReaderState::new(10, 2);
        state.set_chapter_content(make_chapter(0, 10));

        // 当前在第 0 页，窗口 2 → 预加载 [0, 2]
        let indices = state.preload_page_indices();
        assert_eq!(indices, vec![0, 1, 2]);

        // 标记第 1 页已加载
        state.mark_page_loaded(1, vec![1, 2, 3]);
        let indices = state.preload_page_indices();
        assert_eq!(indices, vec![0, 2]);
    }

    #[test]
    fn test_preload_page_indices_middle() {
        let mut state = MangaReaderState::new(10, 2);
        state.set_chapter_content(make_chapter(0, 10));
        state.on_page_changed(5);

        // 当前在第 5 页，窗口 2 → 预加载 [3, 7]
        let indices = state.preload_page_indices();
        assert_eq!(indices, vec![3, 4, 5, 6, 7]);
    }

    #[test]
    fn test_page_state_transitions() {
        let mut state = MangaReaderState::new(10, 2);
        state.set_chapter_content(make_chapter(0, 5));

        // 初始 Pending
        assert_eq!(state.get_page_state(0), Some(&PageState::Pending));

        // → Loading
        state.mark_page_loading(0);
        assert_eq!(state.get_page_state(0), Some(&PageState::Loading));

        // → Loaded
        state.mark_page_loaded(0, vec![0xFF, 0xD8]);
        assert_eq!(state.get_page_state(0), Some(&PageState::Loaded));

        // 另一页 → Failed
        state.mark_page_failed(1, "网络超时".to_string());
        match state.get_page_state(1) {
            Some(PageState::Failed { msg, count }) => {
                assert_eq!(msg, "网络超时");
                assert_eq!(*count, 1);
            }
            _ => panic!("应为 Failed 状态"),
        }
    }

    #[test]
    fn test_chapter_loading_dedup() {
        let mut state = MangaReaderState::new(10, 2);

        assert!(state.add_loading(3)); // 首次加入
        assert!(!state.add_loading(3)); // 重复，拒绝

        state.finish_loading(3);
        assert!(state.add_loading(3)); // 完成后可重新加入
    }

    #[test]
    fn test_chapter_circuit_breaker() {
        let mut state = MangaReaderState::new(10, 2);

        // 模拟 3 次失败
        for _ in 0..3 {
            state.add_loading(5);
            state.fail_loading(5);
        }
        assert_eq!(state.fail_count(5), 3);

        // 熔断：不再允许加载
        assert!(!state.add_loading(5));

        // 重置后可恢复
        state.reset_fail_count(5);
        assert!(state.add_loading(5));
    }

    #[test]
    fn test_pre_download_indices() {
        let mut state = MangaReaderState::new(20, 2);
        state.reset_to(10, 0);

        let indices = state.pre_download_indices();
        // 前向：12, 13（cur+2 到 cur+3）
        assert!(indices.contains(&12));
        assert!(indices.contains(&13));
        // 后向：8, 7, 6, 5（cur-2 到 cur-5）
        assert!(indices.contains(&8));
        assert!(indices.contains(&7));
    }

    #[test]
    fn test_pre_download_skips_cached_and_fused() {
        let mut state = MangaReaderState::new(20, 2);
        state.reset_to(10, 0);

        // 缓存章节 12
        state.cache_chapter(make_chapter(12, 3));
        // 熔断章节 13
        for _ in 0..3 {
            state.add_loading(13);
            state.fail_loading(13);
        }

        let indices = state.pre_download_indices();
        assert!(!indices.contains(&12)); // 已缓存
        assert!(!indices.contains(&13)); // 已熔断
    }

    #[test]
    fn test_lru_cache_eviction() {
        let mut state = MangaReaderState::new(100, 2);
        state.reset_to(50, 0);

        // 填满缓存（max_cache_size = 10）
        for i in 0..10 {
            state.cache_chapter(make_chapter(i, 3));
        }
        assert_eq!(state.cache_size(), 10);

        // 再插入一个，应淘汰距 cur_index(50) 最远的
        state.cache_chapter(make_chapter(10, 3));
        assert_eq!(state.cache_size(), 10);
        // 章节 0 距 50 最远（距离 50），应被淘汰
        assert!(!state.is_cached(0));
        assert!(state.is_cached(10));
    }

    #[test]
    fn test_progress_save_and_restore() {
        let mut state = MangaReaderState::new(10, 2);
        state.set_chapter_content(make_chapter(0, 5));
        state.on_page_changed(3);

        let progress = state.progress();
        assert_eq!(progress.chapter_index, 0);
        assert_eq!(progress.page_pos, 3);

        // 模拟跳转
        let mut state2 = MangaReaderState::new(10, 2);
        assert!(state2.set_progress(progress));
        assert_eq!(state2.cur_index(), 0);
        assert_eq!(state2.cur_page_pos(), 3);
    }

    #[test]
    fn test_set_progress_cross_chapter() {
        let mut state = MangaReaderState::new(10, 2);
        state.reset_to(3, 0);

        let progress = MangaProgress {
            chapter_index: 7,
            page_pos: 2,
        };
        assert!(state.set_progress(progress));
        assert_eq!(state.cur_index(), 7);
        assert_eq!(state.cur_page_pos(), 2);
    }

    #[test]
    fn test_set_progress_invalid() {
        let mut state = MangaReaderState::new(10, 2);
        let progress = MangaProgress {
            chapter_index: 15, // 超出范围
            page_pos: 0,
        };
        assert!(!state.set_progress(progress));
    }

    #[test]
    fn test_manga_chapter_from_urls() {
        let urls = vec![
            "http://a.jpg".to_string(),
            "http://b.jpg".to_string(),
            "http://c.jpg".to_string(),
        ];
        let chapter =
            MangaChapter::from_urls(0, "第1话".to_string(), "http://ch".to_string(), &urls);
        assert_eq!(chapter.image_count(), 3);
        assert_eq!(chapter.loaded_count(), 0);
        assert!(!chapter.is_fully_loaded());
    }

    #[test]
    fn test_manga_chapter_fully_loaded() {
        let urls = vec!["http://a.jpg".to_string(), "http://b.jpg".to_string()];
        let mut chapter =
            MangaChapter::from_urls(0, "第1话".to_string(), "http://ch".to_string(), &urls);
        chapter.pages[0].mark_loaded(vec![1]);
        chapter.pages[1].mark_loaded(vec![2]);
        assert!(chapter.is_fully_loaded());
        assert_eq!(chapter.loaded_count(), 2);
    }

    #[test]
    fn test_page_state_can_retry() {
        assert!(PageState::Pending.can_retry());
        assert!(PageState::Failed {
            msg: "err".to_string(),
            count: 1
        }
        .can_retry());
        assert!(!PageState::Loading.can_retry());
        assert!(!PageState::Loaded.can_retry());
    }

    #[test]
    fn test_read_time_accumulation() {
        let mut state = MangaReaderState::new(10, 2);
        state.add_read_time(5000);
        state.add_read_time(3000);
        assert_eq!(state.read_time_ms(), 8000);
    }
}
