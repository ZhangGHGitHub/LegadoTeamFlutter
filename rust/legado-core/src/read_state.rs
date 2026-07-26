//! ReadBook 章节预加载状态机
//!
//! 移植自 Kotlin ReadBook.kt，实现三章滑动窗口、有界并发预下载、
//! LRU 内存缓存和失败熔断。

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::Semaphore;

/// 章节内容
#[derive(Debug, Clone)]
pub struct TextChapter {
    pub index: i32,
    pub title: String,
    pub content: String,
    pub url: String,
}

/// 预加载状态
#[derive(Debug, Clone, PartialEq)]
pub enum LoadState {
    Idle,
    Loading,
    Loaded,
    Failed(i32), // 失败次数
}

/// ReadBook 状态机
pub struct ReadBookState {
    /// 三章滑动窗口
    prev_chapter: Option<TextChapter>,
    cur_chapter: Option<TextChapter>,
    next_chapter: Option<TextChapter>,

    /// 当前章节索引
    cur_index: i32,

    /// 预下载信号量（有界并发 = 2）
    semaphore: Arc<Semaphore>,

    /// 已下载章节缓存（LRU）
    cached_chapters: HashMap<i32, TextChapter>,
    max_cache_size: usize,

    /// 正在加载的章节（去重）
    loading_set: HashSet<i32>,

    /// 下载失败记录（失败 >= 3 次则熔断跳过）
    fail_count: HashMap<i32, i32>,
    fail_threshold: i32,

    /// 预下载配置
    pre_download_ahead: i32, // 前向预下载章节数
    pre_download_behind: i32, // 后向预下载章节数（默认 5）
}

impl ReadBookState {
    pub fn new() -> Self {
        Self {
            prev_chapter: None,
            cur_chapter: None,
            next_chapter: None,
            cur_index: 0,
            semaphore: Arc::new(Semaphore::new(2)),
            cached_chapters: HashMap::new(),
            max_cache_size: 20,
            loading_set: HashSet::new(),
            fail_count: HashMap::new(),
            fail_threshold: 3,
            pre_download_ahead: 3,
            pre_download_behind: 5,
        }
    }

    /// 切换到指定章节
    pub fn jump_to(&mut self, index: i32) {
        self.cur_index = index;
        // 更新三章窗口
        self.prev_chapter = self.cached_chapters.get(&(index - 1)).cloned();
        self.cur_chapter = self.cached_chapters.get(&index).cloned();
        self.next_chapter = self.cached_chapters.get(&(index + 1)).cloned();
    }

    /// 下一章
    pub fn next(&mut self) {
        self.prev_chapter = self.cur_chapter.take();
        self.cur_chapter = self.next_chapter.take();
        self.cur_index += 1;
        self.next_chapter = self.cached_chapters.get(&(self.cur_index + 1)).cloned();
    }

    /// 上一章
    pub fn prev(&mut self) {
        self.next_chapter = self.cur_chapter.take();
        self.cur_chapter = self.prev_chapter.take();
        self.cur_index -= 1;
        self.prev_chapter = self.cached_chapters.get(&(self.cur_index - 1)).cloned();
    }

    /// 缓存章节内容
    pub fn cache_chapter(&mut self, chapter: TextChapter) {
        // LRU 淘汰
        if self.cached_chapters.len() >= self.max_cache_size {
            // 移除距当前最远的章节
            if let Some(&farthest) = self
                .cached_chapters
                .keys()
                .min_by_key(|&&idx| -(idx as i64 - self.cur_index as i64).abs())
            {
                self.cached_chapters.remove(&farthest);
            }
        }
        self.cached_chapters.insert(chapter.index, chapter);
    }

    /// 标记章节为加载中（去重）
    pub fn add_loading(&mut self, index: i32) -> bool {
        if self.loading_set.contains(&index) {
            return false; // 已在加载
        }
        if self.fail_count.get(&index).copied().unwrap_or(0) >= self.fail_threshold {
            return false; // 熔断跳过
        }
        self.loading_set.insert(index);
        true
    }

    /// 标记加载完成
    pub fn finish_loading(&mut self, index: i32) {
        self.loading_set.remove(&index);
    }

    /// 标记加载失败
    pub fn fail_loading(&mut self, index: i32) {
        self.loading_set.remove(&index);
        *self.fail_count.entry(index).or_insert(0) += 1;
    }

    /// 获取需要预下载的章节索引列表
    pub fn pre_download_indices(&self) -> Vec<i32> {
        let mut indices = Vec::new();
        // 前向预下载
        for i in 1..=self.pre_download_ahead {
            let idx = self.cur_index + i;
            if !self.cached_chapters.contains_key(&idx) {
                indices.push(idx);
            }
        }
        // 后向预下载
        for i in 1..=self.pre_download_behind {
            let idx = self.cur_index - i;
            if idx >= 0 && !self.cached_chapters.contains_key(&idx) {
                indices.push(idx);
            }
        }
        indices
    }

    /// 获取章节加载状态
    pub fn load_state(&self, index: i32) -> LoadState {
        if self.loading_set.contains(&index) {
            return LoadState::Loading;
        }
        if self.cached_chapters.contains_key(&index) {
            return LoadState::Loaded;
        }
        let fails = self.fail_count.get(&index).copied().unwrap_or(0);
        if fails > 0 {
            return LoadState::Failed(fails);
        }
        LoadState::Idle
    }

    /// 重置失败计数
    pub fn reset_fail_count(&mut self, index: i32) {
        self.fail_count.remove(&index);
    }

    // Getters
    pub fn cur_chapter(&self) -> Option<&TextChapter> {
        self.cur_chapter.as_ref()
    }

    pub fn prev_chapter(&self) -> Option<&TextChapter> {
        self.prev_chapter.as_ref()
    }

    pub fn next_chapter(&self) -> Option<&TextChapter> {
        self.next_chapter.as_ref()
    }

    pub fn cur_index(&self) -> i32 {
        self.cur_index
    }

    pub fn is_cached(&self, index: i32) -> bool {
        self.cached_chapters.contains_key(&index)
    }

    pub fn cache_size(&self) -> usize {
        self.cached_chapters.len()
    }

    pub fn semaphore(&self) -> Arc<Semaphore> {
        self.semaphore.clone()
    }

    pub fn is_loading(&self, index: i32) -> bool {
        self.loading_set.contains(&index)
    }

    pub fn fail_count(&self, index: i32) -> i32 {
        self.fail_count.get(&index).copied().unwrap_or(0)
    }
}

impl Default for ReadBookState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_chapter(index: i32) -> TextChapter {
        TextChapter {
            index,
            title: format!("Chapter {}", index),
            content: format!("Content of chapter {}", index),
            url: format!("http://example.com/chapter/{}", index),
        }
    }

    #[test]
    fn test_new_state_defaults() {
        let state = ReadBookState::new();
        assert_eq!(state.cur_index(), 0);
        assert!(state.cur_chapter().is_none());
        assert!(state.prev_chapter().is_none());
        assert!(state.next_chapter().is_none());
        assert_eq!(state.cache_size(), 0);
    }

    #[test]
    fn test_jump_to_with_cached_chapters() {
        let mut state = ReadBookState::new();
        state.cache_chapter(make_chapter(4));
        state.cache_chapter(make_chapter(5));
        state.cache_chapter(make_chapter(6));

        state.jump_to(5);
        assert_eq!(state.cur_index(), 5);
        assert_eq!(state.cur_chapter().unwrap().index, 5);
        assert_eq!(state.prev_chapter().unwrap().index, 4);
        assert_eq!(state.next_chapter().unwrap().index, 6);
    }

    #[test]
    fn test_jump_to_without_cache() {
        let mut state = ReadBookState::new();
        state.jump_to(10);
        assert_eq!(state.cur_index(), 10);
        assert!(state.cur_chapter().is_none());
        assert!(state.prev_chapter().is_none());
        assert!(state.next_chapter().is_none());
    }

    #[test]
    fn test_next_slides_window() {
        let mut state = ReadBookState::new();
        state.cache_chapter(make_chapter(0));
        state.cache_chapter(make_chapter(1));
        state.cache_chapter(make_chapter(2));
        state.cache_chapter(make_chapter(3));

        state.jump_to(1);
        assert_eq!(state.cur_chapter().unwrap().index, 1);

        state.next();
        assert_eq!(state.cur_index(), 2);
        assert_eq!(state.cur_chapter().unwrap().index, 2);
        assert_eq!(state.prev_chapter().unwrap().index, 1);
        assert_eq!(state.next_chapter().unwrap().index, 3);
    }

    #[test]
    fn test_prev_slides_window() {
        let mut state = ReadBookState::new();
        state.cache_chapter(make_chapter(0));
        state.cache_chapter(make_chapter(1));
        state.cache_chapter(make_chapter(2));

        state.jump_to(1);
        state.prev();
        assert_eq!(state.cur_index(), 0);
        assert_eq!(state.cur_chapter().unwrap().index, 0);
        assert!(state.prev_chapter().is_none());
        assert_eq!(state.next_chapter().unwrap().index, 1);
    }

    #[test]
    fn test_next_multiple_times() {
        let mut state = ReadBookState::new();
        for i in 0..6 {
            state.cache_chapter(make_chapter(i));
        }
        state.jump_to(0);

        state.next();
        state.next();
        state.next();
        assert_eq!(state.cur_index(), 3);
        assert_eq!(state.cur_chapter().unwrap().index, 3);
        assert_eq!(state.prev_chapter().unwrap().index, 2);
        assert_eq!(state.next_chapter().unwrap().index, 4);
    }

    #[test]
    fn test_lru_eviction() {
        let mut state = ReadBookState::new();
        // max_cache_size = 20, fill it up
        for i in 0..20 {
            state.cache_chapter(make_chapter(i));
        }
        assert_eq!(state.cache_size(), 20);

        // cur_index = 0, farthest is index 19
        state.cache_chapter(make_chapter(100));
        assert_eq!(state.cache_size(), 20);
        // index 19 should be evicted (farthest from 0)
        assert!(!state.is_cached(19));
        assert!(state.is_cached(100));
    }

    #[test]
    fn test_lru_eviction_respects_cur_index() {
        let mut state = ReadBookState::new();
        for i in 0..20 {
            state.cache_chapter(make_chapter(i));
        }
        // Move to center
        state.jump_to(10);

        // Now farthest from 10 is index 0 or 19 (both distance 10/9)
        // min_by_key with negated abs => picks the one with largest distance
        state.cache_chapter(make_chapter(50));
        assert_eq!(state.cache_size(), 20);
        assert!(state.is_cached(50));
        // index 0 is distance 10 from cur_index=10, index 19 is distance 9
        // so index 0 should be evicted
        assert!(!state.is_cached(0));
    }

    #[test]
    fn test_add_loading_dedup() {
        let mut state = ReadBookState::new();
        assert!(state.add_loading(5));
        assert!(!state.add_loading(5)); // duplicate
        assert!(state.add_loading(6)); // different index
        assert!(state.is_loading(5));
        assert!(state.is_loading(6));
    }

    #[test]
    fn test_finish_loading_removes() {
        let mut state = ReadBookState::new();
        state.add_loading(3);
        assert!(state.is_loading(3));
        state.finish_loading(3);
        assert!(!state.is_loading(3));
        // Can add again after finish
        assert!(state.add_loading(3));
    }

    #[test]
    fn test_fail_loading_increments() {
        let mut state = ReadBookState::new();
        state.add_loading(7);
        state.fail_loading(7);
        assert!(!state.is_loading(7));
        assert_eq!(state.fail_count(7), 1);

        state.add_loading(7);
        state.fail_loading(7);
        assert_eq!(state.fail_count(7), 2);
    }

    #[test]
    fn test_circuit_breaker_skips_after_threshold() {
        let mut state = ReadBookState::new();
        // Fail 3 times
        for _ in 0..3 {
            state.add_loading(9);
            state.fail_loading(9);
        }
        assert_eq!(state.fail_count(9), 3);
        // Now add_loading should return false (circuit breaker)
        assert!(!state.add_loading(9));
        assert!(!state.is_loading(9));
    }

    #[test]
    fn test_reset_fail_count_allows_reload() {
        let mut state = ReadBookState::new();
        for _ in 0..3 {
            state.add_loading(4);
            state.fail_loading(4);
        }
        assert!(!state.add_loading(4));
        state.reset_fail_count(4);
        assert!(state.add_loading(4));
    }

    #[test]
    fn test_pre_download_indices_forward() {
        let mut state = ReadBookState::new();
        state.jump_to(10);
        let indices = state.pre_download_indices();
        // Forward: 11, 12, 13
        assert!(indices.contains(&11));
        assert!(indices.contains(&12));
        assert!(indices.contains(&13));
    }

    #[test]
    fn test_pre_download_indices_backward() {
        let mut state = ReadBookState::new();
        state.jump_to(10);
        let indices = state.pre_download_indices();
        // Backward: 9, 8, 7, 6, 5
        assert!(indices.contains(&9));
        assert!(indices.contains(&8));
        assert!(indices.contains(&7));
        assert!(indices.contains(&6));
        assert!(indices.contains(&5));
    }

    #[test]
    fn test_pre_download_skips_cached() {
        let mut state = ReadBookState::new();
        state.jump_to(10);
        state.cache_chapter(make_chapter(11));
        state.cache_chapter(make_chapter(12));

        let indices = state.pre_download_indices();
        assert!(!indices.contains(&11));
        assert!(!indices.contains(&12));
        assert!(indices.contains(&13));
    }

    #[test]
    fn test_pre_download_no_negative_indices() {
        let mut state = ReadBookState::new();
        state.jump_to(2);
        let indices = state.pre_download_indices();
        // Backward from 2: 1, 0 (not -1, -2, -3)
        assert!(indices.contains(&1));
        assert!(indices.contains(&0));
        assert!(!indices.contains(&-1));
        assert!(!indices.contains(&-2));
    }

    #[test]
    fn test_semaphore_permits() {
        let state = ReadBookState::new();
        let sem = state.semaphore();
        assert_eq!(sem.available_permits(), 2);
    }

    #[tokio::test]
    async fn test_semaphore_acquire_release() {
        let state = ReadBookState::new();
        let sem = state.semaphore();

        let p1 = sem.clone().acquire_owned().await.unwrap();
        assert_eq!(sem.available_permits(), 1);

        let p2 = sem.clone().acquire_owned().await.unwrap();
        assert_eq!(sem.available_permits(), 0);

        drop(p1);
        assert_eq!(sem.available_permits(), 1);

        drop(p2);
        assert_eq!(sem.available_permits(), 2);
    }

    #[test]
    fn test_load_state_transitions() {
        let mut state = ReadBookState::new();
        assert_eq!(state.load_state(1), LoadState::Idle);

        state.add_loading(1);
        assert_eq!(state.load_state(1), LoadState::Loading);

        state.finish_loading(1);
        state.cache_chapter(make_chapter(1));
        assert_eq!(state.load_state(1), LoadState::Loaded);
    }

    #[test]
    fn test_load_state_failed() {
        let mut state = ReadBookState::new();
        state.add_loading(2);
        state.fail_loading(2);
        assert_eq!(state.load_state(2), LoadState::Failed(1));

        state.add_loading(2);
        state.fail_loading(2);
        assert_eq!(state.load_state(2), LoadState::Failed(2));
    }

    #[test]
    fn test_cache_chapter_overwrite() {
        let mut state = ReadBookState::new();
        let mut ch = make_chapter(5);
        ch.content = "old".to_string();
        state.cache_chapter(ch);

        let mut ch2 = make_chapter(5);
        ch2.content = "new".to_string();
        state.cache_chapter(ch2);

        assert_eq!(state.cache_size(), 1);
    }
}
