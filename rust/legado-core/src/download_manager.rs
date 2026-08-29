//! 下载管理器
//!
//! 管理章节内容的离线下载，支持队列、并发控制、暂停/恢复。

use std::collections::{HashMap, VecDeque};

// 导出到模型模块
pub use crate::models::DownloadStatus;
pub use crate::models::DownloadTask;

/// 预下载策略
#[derive(Debug, Clone)]
pub enum PreloadStrategy {
    /// 顺序模式：当前章 + 后续 N 章
    Sequential {
        ahead: usize,  // 后续章节数 (默认 5)
        behind: usize, // 前序章节数 (默认 0)
    },
    /// 逆序模式：当前章 + 前序 N 章
    Reverse {
        behind: usize, // 前序章节数 (默认 5)
    },
    /// 自适应：根据阅读方向自动判断
    Adaptive,
}

impl Default for PreloadStrategy {
    fn default() -> Self {
        Self::Sequential {
            ahead: 5,
            behind: 0,
        }
    }
}

/// 预下载触发阈值（阅读进度达到 80% 时触发预下载）
pub const PRELOAD_TRIGGER_THRESHOLD: f64 = 0.8;

/// 预下载配置
#[derive(Debug, Clone)]
pub struct PreloadConfig {
    /// 是否启用移动数据预下载
    pub enable_mobile_data: bool,
    /// 移动数据下的最大并发预下载数
    pub mobile_max_concurrent: usize,
    /// 预下载章节的最大数量
    pub max_preload_chapters: usize,
}

impl Default for PreloadConfig {
    fn default() -> Self {
        Self {
            enable_mobile_data: false, // 默认关闭移动数据预下载
            mobile_max_concurrent: 1,
            max_preload_chapters: 10,
        }
    }
}

/// 下载管理器
pub struct DownloadManager {
    /// 任务队列
    queue: VecDeque<String>, // task_id
    /// 任务存储
    tasks: HashMap<String, DownloadTask>,
    /// 最大并发下载数
    max_concurrent: usize,
    /// 当前下载中的数量
    active_count: usize,
    /// 是否暂停
    is_paused: bool,
    // 预下载配置
    preload_strategy: PreloadStrategy,
    preload_config: PreloadConfig,
    // 阅读方向检测（用于 Adaptive 策略）
    last_chapter_index: Option<i32>,
    direction_hint: Option<ReadDirection>,
    /// 全局最大重试次数（默认 3）
    max_retry_count: u32,
}

/// 阅读方向
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ReadDirection {
    Forward,  // 正序阅读
    Backward, // 逆序阅读
}

impl DownloadManager {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            queue: VecDeque::new(),
            tasks: HashMap::new(),
            max_concurrent,
            active_count: 0,
            is_paused: false,
            preload_strategy: PreloadStrategy::default(),
            preload_config: PreloadConfig::default(),
            last_chapter_index: None,
            direction_hint: None,
            max_retry_count: 3,
        }
    }

    /// 设置全局最大重试次数
    pub fn set_max_retry_count(&mut self, count: u32) {
        self.max_retry_count = count;
    }

    /// 获取全局最大重试次数
    pub fn get_max_retry_count(&self) -> u32 {
        self.max_retry_count
    }

    /// 添加下载任务
    pub fn add_task(&mut self, task: DownloadTask) -> String {
        let id = task.id.clone();
        self.queue.push_back(id.clone());
        self.tasks.insert(id.clone(), task);
        id
    }

    /// 获取下一个待下载任务
    pub fn next_pending(&self) -> Option<&DownloadTask> {
        if self.is_paused || self.active_count >= self.max_concurrent {
            return None;
        }
        // 按优先级排序找到第一个 Pending 任务
        self.queue
            .iter()
            .filter_map(|id| self.tasks.get(id))
            .find(|t| t.status == DownloadStatus::Pending)
    }

    /// 标记任务开始下载
    pub fn start_task(&mut self, task_id: &str) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.status = DownloadStatus::Downloading;
            self.active_count += 1;
        }
    }

    /// 标记任务完成
    pub fn complete_task(&mut self, task_id: &str) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.status = DownloadStatus::Completed;
            task.progress = 1.0;
            task.completed_at = Some(now_millis());
            self.active_count = self.active_count.saturating_sub(1);
        }
    }

    /// 标记任务失败
    pub fn fail_task(&mut self, task_id: &str, error: String) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.status = DownloadStatus::Failed(error.clone());
            task.error = Some(error);
            self.active_count = self.active_count.saturating_sub(1);
        }
    }

    /// 标记任务失败（带退避策略和重试限制）
    ///
    /// 指数退避策略：1s, 2s, 4s, 8s...
    /// 超过最大重试次数后标记为永久失败。
    pub fn fail_task_with_retry(&mut self, task_id: &str, error: String) {
        let now = now_millis();
        let max_retry = self.max_retry_count;

        if let Some(mut task) = self.tasks.remove(task_id) {
            task.fail_count += 1;
            task.last_retry_at = Some(now);
            task.max_retry_count = max_retry; // 同步管理器配置

            // 超过最大重试次数，标记为永久失败
            if task.fail_count >= max_retry {
                task.status = DownloadStatus::Failed(error.clone());
                task.error = Some(format!(
                    "永久失败（已重试{}次）：{}",
                    task.fail_count, error
                ));
                task.next_retry_at = None; // 不再重试
                task.priority = 1000; // 降级为低优先级
            } else {
                task.status = DownloadStatus::Failed(error.clone());
                task.error = Some(error);
                // 计算指数退避时间：1s, 2s, 4s, 8s...
                let retry_time = now + self.calculate_backoff(task.fail_count);
                task.next_retry_at = Some(retry_time);

                // 连续失败 3 次后降级
                if task.fail_count >= 3 {
                    task.priority = 1000;
                }
            }

            self.active_count = self.active_count.saturating_sub(1);

            // 重新插入任务
            self.tasks.insert(task_id.to_string(), task);
        }
    }

    /// 暂停所有下载
    pub fn pause_all(&mut self) {
        self.is_paused = true;
    }

    /// 恢复所有下载
    pub fn resume_all(&mut self) {
        self.is_paused = false;
    }

    /// 更新进度
    pub fn update_progress(&mut self, task_id: &str, progress: f64) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.progress = progress.clamp(0.0, 1.0);
        }
    }

    /// 更新已下载字节数（断点续传）
    pub fn update_downloaded_bytes(&mut self, task_id: &str, bytes: i64) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.downloaded_bytes = bytes;
        }
    }

    /// 获取任务的断点续传 Range 头
    ///
    /// 返回 HTTP Range 请求头值，用于断点续传。
    /// 如果服务端不支持 Range，应重新下载（重置 downloaded_bytes 为 0）。
    pub fn get_range_header(&self, task_id: &str) -> Option<String> {
        self.tasks.get(task_id).and_then(|t| t.range_header())
    }

    /// 重置断点续传状态（服务端不支持 Range 时调用）
    pub fn reset_download_progress(&mut self, task_id: &str) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.downloaded_bytes = 0;
            task.progress = 0.0;
        }
    }

    /// 判断是否应触发预下载
    ///
    /// 当阅读进度达到 80% 时触发预下载。
    pub fn should_trigger_preload(&self, reading_progress: f64) -> bool {
        reading_progress >= PRELOAD_TRIGGER_THRESHOLD
    }

    /// 移除任务
    pub fn remove_task(&mut self, task_id: &str) {
        self.tasks.remove(task_id);
        self.queue.retain(|id| id != task_id);
    }

    /// 获取状态统计
    pub fn stats(&self) -> DownloadStats {
        DownloadStats {
            total: self.tasks.len(),
            pending: self
                .tasks
                .values()
                .filter(|t| t.status == DownloadStatus::Pending)
                .count(),
            downloading: self.active_count,
            completed: self
                .tasks
                .values()
                .filter(|t| t.status == DownloadStatus::Completed)
                .count(),
            failed: self
                .tasks
                .values()
                .filter(|t| matches!(t.status, DownloadStatus::Failed(_)))
                .count(),
            paused: self.is_paused,
        }
    }

    /// 获取某本书的所有任务
    pub fn tasks_by_book(&self, book_url: &str) -> Vec<&DownloadTask> {
        self.tasks
            .values()
            .filter(|t| t.book_url == book_url)
            .collect()
    }

    /// 获取指定任务
    pub fn get_task(&self, task_id: &str) -> Option<&DownloadTask> {
        self.tasks.get(task_id)
    }

    /// 是否处于暂停状态
    pub fn is_paused(&self) -> bool {
        self.is_paused
    }

    /// 设置预下载策略
    pub fn set_preload_strategy(&mut self, strategy: PreloadStrategy) {
        self.preload_strategy = strategy;
    }

    /// 设置预下载配置
    pub fn set_preload_config(&mut self, config: PreloadConfig) {
        self.preload_config = config;
    }

    /// 启用/禁用移动数据预下载
    pub fn enable_mobile_data_preload(&mut self, enable: bool) {
        self.preload_config.enable_mobile_data = enable;
    }

    /// 获取重试统计信息
    pub fn get_retry_stats(&self, task_id: &str) -> Option<RetryStats> {
        self.tasks.get(task_id).map(|t| RetryStats {
            fail_count: t.fail_count,
            last_retry_at: t.last_retry_at,
            next_retry_at: t.next_retry_at,
            degraded: t.fail_count >= 3,
        })
    }

    /// 计算指数退避时间
    fn calculate_backoff(&self, fail_count: u32) -> i64 {
        // 初始 1s -> 2s -> 4s -> 8s -> ... -> 最大 60s
        let base_ms = 1000i64;
        let max_ms = 60000i64;
        let backoff = base_ms.saturating_mul(2i64.saturating_pow(fail_count));
        backoff.min(max_ms)
    }

    /// 获取可重试的任务
    pub fn next_retryable(&mut self) -> Option<String> {
        let now = now_millis();
        let mut best: Option<(&str, i32)> = None;

        for (id, task) in self.tasks.iter() {
            if let DownloadStatus::Failed(_) = &task.status {
                // 跳过已永久失败的任务
                if task.fail_count >= task.max_retry_count {
                    continue;
                }
                if let Some(next) = task.next_retry_at {
                    if next <= now {
                        // 可重试，选择优先级最高的
                        if best.map(|(_, p)| p > task.priority).unwrap_or(true) {
                            best = Some((id, task.priority));
                        }
                    }
                }
            }
        }

        best.map(|(id, _)| id.to_string())
    }

    /// 重置任务为待下载状态（用于重试）
    pub fn reset_for_retry(&mut self, task_id: &str) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.status = DownloadStatus::Pending;
            task.error = None;
            task.next_retry_at = None;
        }
    }

    /// 计算需要预下载的章节索引列表
    ///
    /// # 参数
    /// - `book_url`: 书籍 URL
    /// - `current_chapter`: 当前阅读章节索引 (从 0 开始)
    /// - `total_chapters`: 总章节数
    ///
    /// # 返回
    /// 待预下载的章节索引列表
    ///
    /// # 策略
    /// - 顺序阅读：当前 + 后续 5 章
    /// - 逆序阅读：当前 + 前序 5 章
    /// - 自适应：根据阅读方向自动判断
    /// - 移动数据下最多预下载 10 章 (通过配置限制)
    pub fn calculate_preload_indices(
        &mut self,
        book_url: &str,
        current_chapter: i32,
        total_chapters: i32,
    ) -> Vec<i32> {
        let (ahead, behind) = match &self.preload_strategy {
            PreloadStrategy::Sequential { ahead, behind } => (*ahead, *behind),
            PreloadStrategy::Reverse { behind } => (0, *behind),
            PreloadStrategy::Adaptive => self.detect_direction_and_get_indices(current_chapter),
        };

        let mut indices = Vec::new();

        // 添加当前章节
        if current_chapter >= 0 && current_chapter < total_chapters {
            indices.push(current_chapter);
        }

        // 添加前序章节
        for offset in 1..=behind {
            let idx = current_chapter - offset as i32;
            if idx >= 0 && idx < total_chapters {
                indices.push(idx);
            }
        }

        // 添加后续章节
        for offset in 1..=ahead {
            let idx = current_chapter + offset as i32;
            if idx >= 0 && idx < total_chapters {
                indices.push(idx);
            }
        }

        // 限制最大预下载数量
        indices.truncate(self.preload_config.max_preload_chapters);

        // 过滤已下载/正在下载的章节
        indices.retain(|&idx| {
            let task_id = format!("{}_{}", book_url.replace(['/', ':', '?', '&'], "_"), idx);
            self.tasks
                .get(&task_id)
                .map(|t| {
                    !matches!(
                        t.status,
                        DownloadStatus::Completed | DownloadStatus::Downloading
                    )
                })
                .unwrap_or(true)
        });

        indices
    }

    /// 预下载 API 别名（保持与 Kotlin 代码的一致性）
    pub fn pre_download_indices(
        &mut self,
        book_url: &str,
        current_chapter: i32,
        total_chapters: i32,
    ) -> Vec<i32> {
        self.calculate_preload_indices(book_url, current_chapter, total_chapters)
    }

    /// 检测阅读方向并获取合适的预下载数量
    fn detect_direction_and_get_indices(&mut self, current_chapter: i32) -> (usize, usize) {
        if let Some(last) = self.last_chapter_index {
            if current_chapter > last {
                self.direction_hint = Some(ReadDirection::Forward);
            } else if current_chapter < last {
                self.direction_hint = Some(ReadDirection::Backward);
            }
        }
        self.last_chapter_index = Some(current_chapter);

        match self.direction_hint {
            Some(ReadDirection::Forward) => (5, 0), // 顺序阅读：后续 5 章
            Some(ReadDirection::Backward) => (0, 5), // 逆序阅读：前序 5 章
            None => (5, 0),                         // 默认顺序阅读
        }
    }

    /// 更新任务优先级（动态优先级调整）
    pub fn update_task_priority(&mut self, task_id: &str, priority: i32) {
        if let Some(task) = self.tasks.get_mut(task_id) {
            task.priority = priority;
        }
    }

    /// 批量添加预下载任务
    pub fn add_preload_tasks(
        &mut self,
        book_url: &str,
        chapters: Vec<(i32, String, String)>, // (index, url, title)
        base_priority: i32,
    ) -> Vec<String> {
        let mut task_ids = Vec::new();

        for (i, (idx, url, title)) in chapters.iter().enumerate() {
            let task_id = format!("{}_{}", book_url.replace(['/', ':', '?', '&'], "_"), idx);

            // 跳过已存在的任务
            if self.tasks.contains_key(&task_id) {
                continue;
            }

            // 预下载任务优先级高于手动触发的任务
            let priority = base_priority - i as i32;

            let task = DownloadTask {
                id: task_id.clone(),
                book_url: book_url.to_string(),
                chapter_url: url.clone(),
                chapter_title: title.clone(),
                chapter_index: *idx,
                status: DownloadStatus::Pending,
                progress: 0.0,
                priority,
                created_at: now_millis(),
                completed_at: None,
                error: None,
                fail_count: 0,
                last_retry_at: None,
                next_retry_at: None,
                downloaded_bytes: 0,
                max_retry_count: self.max_retry_count,
            };

            self.add_task(task);
            task_ids.push(task_id);
        }

        task_ids
    }
}

/// 下载统计信息
#[derive(Debug, Clone)]
pub struct DownloadStats {
    pub total: usize,
    pub pending: usize,
    pub downloading: usize,
    pub completed: usize,
    pub failed: usize,
    pub paused: bool,
}

/// 重试统计信息
#[derive(Debug, Clone)]
pub struct RetryStats {
    pub fail_count: u32,
    pub last_retry_at: Option<i64>,
    pub next_retry_at: Option<i64>,
    pub degraded: bool,
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_task(id: &str, book_url: &str, index: i32) -> DownloadTask {
        DownloadTask {
            id: id.to_string(),
            book_url: book_url.to_string(),
            chapter_url: format!("http://example.com/ch{index}"),
            chapter_title: format!("Chapter {index}"),
            chapter_index: index,
            status: DownloadStatus::Pending,
            progress: 0.0,
            priority: index,
            created_at: now_millis(),
            completed_at: None,
            error: None,
            fail_count: 0,
            last_retry_at: None,
            next_retry_at: None,
            downloaded_bytes: 0,
            max_retry_count: 3,
        }
    }

    #[test]
    fn test_new_manager_empty() {
        let mgr = DownloadManager::new(3);
        let stats = mgr.stats();
        assert_eq!(stats.total, 0);
        assert_eq!(stats.pending, 0);
        assert_eq!(stats.downloading, 0);
        assert_eq!(stats.completed, 0);
        assert_eq!(stats.failed, 0);
        assert!(!stats.paused);
    }

    #[test]
    fn test_add_task() {
        let mut mgr = DownloadManager::new(3);
        let id = mgr.add_task(make_task("t1", "book1", 0));
        assert_eq!(id, "t1");
        assert_eq!(mgr.stats().total, 1);
    }

    #[test]
    fn test_next_pending_returns_first() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        assert_eq!(mgr.next_pending().unwrap().id, "t1");
    }

    #[test]
    fn test_next_pending_none_when_paused() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.pause_all();
        assert!(mgr.next_pending().is_none());
    }

    #[test]
    fn test_next_pending_none_when_max_concurrent() {
        let mut mgr = DownloadManager::new(1);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        mgr.start_task("t1");
        assert!(mgr.next_pending().is_none());
    }

    #[test]
    fn test_complete_task() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.start_task("t1");
        mgr.complete_task("t1");
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(task.status, DownloadStatus::Completed);
        assert_eq!(task.progress, 1.0);
        assert!(task.completed_at.is_some());
    }

    #[test]
    fn test_fail_task() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.start_task("t1");
        mgr.fail_task("t1", "net error".to_string());
        assert_eq!(mgr.stats().failed, 1);
    }

    #[test]
    fn test_pause_and_resume() {
        let mut mgr = DownloadManager::new(3);
        mgr.pause_all();
        assert!(mgr.is_paused());
        mgr.resume_all();
        assert!(!mgr.is_paused());
    }

    #[test]
    fn test_update_progress_clamped() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.update_progress("t1", 1.5);
        assert_eq!(mgr.get_task("t1").unwrap().progress, 1.0);
        mgr.update_progress("t1", -0.5);
        assert_eq!(mgr.get_task("t1").unwrap().progress, 0.0);
    }

    #[test]
    fn test_remove_task() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.remove_task("t1");
        assert!(mgr.get_task("t1").is_none());
    }

    #[test]
    fn test_tasks_by_book() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book2", 0));
        assert_eq!(mgr.tasks_by_book("book1").len(), 1);
        assert_eq!(mgr.tasks_by_book("book3").len(), 0);
    }

    #[test]
    fn test_concurrent_limit() {
        let mut mgr = DownloadManager::new(2);
        mgr.add_task(make_task("t1", "b", 0));
        mgr.add_task(make_task("t2", "b", 1));
        mgr.add_task(make_task("t3", "b", 2));
        mgr.start_task("t1");
        mgr.start_task("t2");
        assert!(mgr.next_pending().is_none());
        mgr.complete_task("t1");
        assert_eq!(mgr.next_pending().unwrap().id, "t3");
    }

    // === 预下载策略 ===

    #[test]
    fn test_default_preload_strategy() {
        let mgr = DownloadManager::new(3);
        match &mgr.preload_strategy {
            PreloadStrategy::Sequential { ahead, behind } => {
                assert_eq!(*ahead, 5);
                assert_eq!(*behind, 0);
            }
            _ => panic!("Expected Sequential"),
        }
    }

    #[test]
    fn test_preload_forward() {
        let mut mgr = DownloadManager::new(3);
        let indices = mgr.calculate_preload_indices("b", 0, 20);
        assert!(indices.contains(&0));
        assert!(indices.contains(&5));
        assert!(indices.len() <= 6);
    }

    #[test]
    fn test_preload_reverse() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_strategy(PreloadStrategy::Reverse { behind: 5 });
        let indices = mgr.calculate_preload_indices("b", 10, 20);
        assert!(indices.contains(&10));
        assert!(indices.contains(&5));
        assert!(!indices.contains(&11));
    }

    #[test]
    fn test_preload_adaptive_forward() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_strategy(PreloadStrategy::Adaptive);
        mgr.calculate_preload_indices("b", 5, 20);
        let indices = mgr.calculate_preload_indices("b", 10, 20);
        assert!(indices.contains(&15));
    }

    #[test]
    fn test_preload_adaptive_backward() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_strategy(PreloadStrategy::Adaptive);
        mgr.calculate_preload_indices("b", 10, 20);
        let indices = mgr.calculate_preload_indices("b", 5, 20);
        assert!(indices.contains(&0));
    }

    #[test]
    fn test_preload_trigger() {
        let mgr = DownloadManager::new(3);
        assert!(!mgr.should_trigger_preload(0.79));
        assert!(mgr.should_trigger_preload(0.8));
        assert!(mgr.should_trigger_preload(1.0));
    }

    #[test]
    fn test_max_preload_limit() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_config(PreloadConfig {
            enable_mobile_data: false,
            mobile_max_concurrent: 1,
            max_preload_chapters: 3,
        });
        let indices = mgr.calculate_preload_indices("b", 10, 100);
        assert!(indices.len() <= 3);
    }

    // === 重试机制 ===

    #[test]
    fn test_exponential_backoff() {
        let mgr = DownloadManager::new(3);
        assert_eq!(mgr.calculate_backoff(1), 2000);
        assert_eq!(mgr.calculate_backoff(2), 4000);
        assert_eq!(mgr.calculate_backoff(3), 8000);
        assert_eq!(mgr.calculate_backoff(7), 60000);
    }

    #[test]
    fn test_fail_with_retry_permanent() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "b", 0));
        mgr.fail_task_with_retry("t1", "e1".to_string());
        mgr.fail_task_with_retry("t1", "e2".to_string());
        mgr.fail_task_with_retry("t1", "e3".to_string());
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(task.fail_count, 3);
        assert_eq!(task.priority, 1000);
        assert!(task.next_retry_at.is_none());
        assert!(task.error.as_ref().unwrap().contains("永久失败"));
        assert!(task.is_permanently_failed());
        assert!(!task.can_retry());
    }

    #[test]
    fn test_retry_before_max() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "b", 0));
        mgr.fail_task_with_retry("t1", "e1".to_string());
        mgr.fail_task_with_retry("t1", "e2".to_string());
        let task = mgr.get_task("t1").unwrap();
        assert!(!task.is_permanently_failed());
        assert!(task.next_retry_at.is_some());
    }

    #[test]
    fn test_custom_max_retry() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_max_retry_count(5);
        assert_eq!(mgr.get_max_retry_count(), 5);
        mgr.add_task(make_task("t1", "b", 0));
        for i in 1..=4 {
            mgr.fail_task_with_retry("t1", format!("e{i}"));
        }
        assert!(!mgr.get_task("t1").unwrap().is_permanently_failed());
        mgr.fail_task_with_retry("t1", "e5".to_string());
        assert!(mgr.get_task("t1").unwrap().is_permanently_failed());
    }

    #[test]
    fn test_reset_for_retry() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "b", 0));
        mgr.fail_task_with_retry("t1", "err".to_string());
        mgr.reset_for_retry("t1");
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(task.status, DownloadStatus::Pending);
        assert!(task.error.is_none());
    }

    #[test]
    fn test_add_preload_tasks() {
        let mut mgr = DownloadManager::new(3);
        let chapters = vec![
            (1, "http://ex.com/ch1".to_string(), "Ch1".to_string()),
            (2, "http://ex.com/ch2".to_string(), "Ch2".to_string()),
        ];
        let ids = mgr.add_preload_tasks("b", chapters, 10);
        assert_eq!(ids.len(), 2);
        assert_eq!(mgr.stats().pending, 2);
    }

    // === 断点续传 ===

    #[test]
    fn test_downloaded_bytes() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "b", 0));
        mgr.update_downloaded_bytes("t1", 1024);
        assert_eq!(mgr.get_task("t1").unwrap().downloaded_bytes, 1024);
    }

    #[test]
    fn test_range_header() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "b", 0));
        assert!(mgr.get_range_header("t1").is_none());
        mgr.update_downloaded_bytes("t1", 2048);
        assert_eq!(mgr.get_range_header("t1").unwrap(), "bytes=2048-");
    }

    #[test]
    fn test_reset_download_progress() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "b", 0));
        mgr.update_downloaded_bytes("t1", 4096);
        mgr.update_progress("t1", 0.5);
        mgr.reset_download_progress("t1");
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(task.downloaded_bytes, 0);
        assert_eq!(task.progress, 0.0);
    }

    // === 性能 ===

    #[test]
    fn test_performance() {
        use std::time::Instant;
        let mut mgr = DownloadManager::new(3);
        let start = Instant::now();
        let indices = mgr.calculate_preload_indices("http://ex.com/book", 500, 1000);
        assert!(indices.len() <= 10);
        assert!(start.elapsed().as_millis() < 100);
    }

    #[test]
    fn test_memory_efficiency() {
        use std::mem;
        assert!(mem::size_of::<DownloadTask>() < 600);
    }
}
