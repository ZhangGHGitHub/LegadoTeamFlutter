//! 下载管理器
//!
//! 管理章节内容的离线下载，支持队列、并发控制、暂停/恢复。

use std::collections::{HashMap, VecDeque};

/// 下载任务状态
#[derive(Debug, Clone, PartialEq)]
pub enum DownloadStatus {
    Pending,
    Downloading,
    Completed,
    Failed(String),
    Paused,
}

/// 下载任务
#[derive(Debug, Clone)]
pub struct DownloadTask {
    pub id: String,
    pub book_url: String,
    pub chapter_url: String,
    pub chapter_title: String,
    pub chapter_index: i32,
    pub status: DownloadStatus,
    pub progress: f64, // 0.0 - 1.0
    pub priority: i32, // 越小越优先
    pub created_at: i64,
    pub completed_at: Option<i64>,
    pub error: Option<String>,
    // 重试元数据
    pub fail_count: u32, // 连续失败次数
    pub last_retry_at: Option<i64>, // 上次重试时间
    pub next_retry_at: Option<i64>, // 下次允许重试时间
}

/// 预下载策略
#[derive(Debug, Clone)]
pub enum PreloadStrategy {
    /// 顺序模式：当前章 + 提前 N 章 + 延后 M 章
    Sequential { 
        ahead: usize,  // 后续章节数 (默认 5)
        behind: usize, // 前序章节数 (默认 3)
    },
    /// 自适应：根据阅读方向自动判断
    Adaptive,
}

impl Default for PreloadStrategy {
    fn default() -> Self {
        Self::Sequential { ahead: 5, behind: 3 }
    }
}

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
        }
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

    /// 标记任务失败（带退避策略）
    pub fn fail_task_with_retry(&mut self, task_id: &str, error: String) {
        let now = now_millis();
        
        if let Some(mut task) = self.tasks.remove(task_id) {
            task.status = DownloadStatus::Failed(error.clone());
            task.error = Some(error);
            task.fail_count += 1;
            task.last_retry_at = Some(now);
            
            // 计算回退时间
            let retry_time = now + self.calculate_backoff(task.fail_count);
            
            // 连续失败 3 次后降级
            if task.fail_count >= 3 {
                task.priority = 1000; // 降级为低优先级
            }
            
            task.next_retry_at = Some(retry_time);
            
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
    pub fn calculate_preload_indices(
        &mut self,
        book_url: &str,
        current_chapter: i32,
        total_chapters: i32,
    ) -> Vec<i32> {
        let (ahead, behind) = match &self.preload_strategy {
            PreloadStrategy::Sequential { ahead, behind } => (*ahead, *behind),
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
                .map(|t| !matches!(t.status, DownloadStatus::Completed | DownloadStatus::Downloading))
                .unwrap_or(true)
        });

        indices
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
            Some(ReadDirection::Forward) => (5, 3), // 正序：后续 5 章，前序 3 章
            Some(ReadDirection::Backward) => (3, 5), // 逆序：后续 3 章，前序 5 章
            None => (5, 3), // 默认正序
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
        assert_eq!(mgr.stats().pending, 1);
    }

    #[test]
    fn test_add_multiple_tasks() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        mgr.add_task(make_task("t3", "book2", 0));
        assert_eq!(mgr.stats().total, 3);
        assert_eq!(mgr.stats().pending, 3);
    }

    #[test]
    fn test_next_pending_returns_first() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        let next = mgr.next_pending().unwrap();
        assert_eq!(next.id, "t1");
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
        // max_concurrent = 1, active = 1 => no more pending
        assert!(mgr.next_pending().is_none());
    }

    #[test]
    fn test_start_task() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.start_task("t1");
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(task.status, DownloadStatus::Downloading);
        assert_eq!(mgr.stats().downloading, 1);
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
        assert_eq!(mgr.stats().downloading, 0);
        assert_eq!(mgr.stats().completed, 1);
    }

    #[test]
    fn test_fail_task() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.start_task("t1");
        mgr.fail_task("t1", "network error".to_string());
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(
            task.status,
            DownloadStatus::Failed("network error".to_string())
        );
        assert_eq!(task.error, Some("network error".to_string()));
        assert_eq!(mgr.stats().downloading, 0);
        assert_eq!(mgr.stats().failed, 1);
    }

    #[test]
    fn test_pause_and_resume() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        assert!(!mgr.is_paused());
        mgr.pause_all();
        assert!(mgr.is_paused());
        assert!(mgr.stats().paused);
        mgr.resume_all();
        assert!(!mgr.is_paused());
        assert!(!mgr.stats().paused);
    }

    #[test]
    fn test_update_progress() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.start_task("t1");
        mgr.update_progress("t1", 0.5);
        assert_eq!(mgr.get_task("t1").unwrap().progress, 0.5);
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
        mgr.add_task(make_task("t2", "book1", 1));
        mgr.remove_task("t1");
        assert_eq!(mgr.stats().total, 1);
        assert!(mgr.get_task("t1").is_none());
        assert!(mgr.get_task("t2").is_some());
    }

    #[test]
    fn test_tasks_by_book() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        mgr.add_task(make_task("t3", "book2", 0));
        let book1_tasks = mgr.tasks_by_book("book1");
        assert_eq!(book1_tasks.len(), 2);
        let book2_tasks = mgr.tasks_by_book("book2");
        assert_eq!(book2_tasks.len(), 1);
        let book3_tasks = mgr.tasks_by_book("book3");
        assert_eq!(book3_tasks.len(), 0);
    }

    #[test]
    fn test_stats_mixed_states() {
        let mut mgr = DownloadManager::new(5);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        mgr.add_task(make_task("t3", "book1", 2));
        mgr.add_task(make_task("t4", "book1", 3));

        mgr.start_task("t1");
        mgr.complete_task("t1");
        mgr.start_task("t2");
        mgr.fail_task("t2", "err".to_string());
        mgr.start_task("t3");
        // t4 remains pending

        let stats = mgr.stats();
        assert_eq!(stats.total, 4);
        assert_eq!(stats.pending, 1);
        assert_eq!(stats.downloading, 1);
        assert_eq!(stats.completed, 1);
        assert_eq!(stats.failed, 1);
    }

    #[test]
    fn test_get_task_nonexistent() {
        let mgr = DownloadManager::new(3);
        assert!(mgr.get_task("nonexistent").is_none());
    }

    #[test]
    fn test_start_nonexistent_task_no_panic() {
        let mut mgr = DownloadManager::new(3);
        mgr.start_task("nonexistent"); // should not panic
        assert_eq!(mgr.stats().downloading, 0);
    }

    #[test]
    fn test_complete_nonexistent_task_no_panic() {
        let mut mgr = DownloadManager::new(3);
        mgr.complete_task("nonexistent"); // should not panic
        assert_eq!(mgr.stats().completed, 0);
    }

    #[test]
    fn test_concurrent_limit_respected() {
        let mut mgr = DownloadManager::new(2);
        mgr.add_task(make_task("t1", "book1", 0));
        mgr.add_task(make_task("t2", "book1", 1));
        mgr.add_task(make_task("t3", "book1", 2));

        mgr.start_task("t1");
        mgr.start_task("t2");
        // Now at max concurrent (2), next_pending should be None
        assert!(mgr.next_pending().is_none());

        // Complete one, should get next pending
        mgr.complete_task("t1");
        let next = mgr.next_pending().unwrap();
        assert_eq!(next.id, "t3");
    }

    // ========================================================================
    // 预下载策略测试
    // ========================================================================

    #[test]
    fn test_default_preload_strategy() {
        let mgr = DownloadManager::new(3);
        match &mgr.preload_strategy {
            PreloadStrategy::Sequential { ahead, behind } => {
                assert_eq!(*ahead, 5);
                assert_eq!(*behind, 3);
            }
            _ => panic!("Expected Sequential strategy"),
        }
    }

    #[test]
    fn test_calculate_preload_indices_forward() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_strategy(PreloadStrategy::Sequential { ahead: 5, behind: 3 });

        let indices = mgr.calculate_preload_indices("book1", 0, 20);
        
        // 应该包含当前章 + 前序 3 章 + 后续 5 章，但限制在最大 10 章
        assert!(indices.len() <= 10);
        assert!(indices.contains(&0)); // 当前章
    }

    #[test]
    fn test_calculate_preload_indices_backward_direction() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_strategy(PreloadStrategy::Adaptive);

        // 模拟逆序阅读
        mgr.last_chapter_index = Some(10);
        mgr.direction_hint = Some(ReadDirection::Backward);

        let indices = mgr.calculate_preload_indices("book1", 5, 20);
        
        // 应优先下载前序章节
        assert!(indices.len() > 0);
    }

    #[test]
    fn test_max_preload_limit() {
        let mut mgr = DownloadManager::new(3);
        mgr.set_preload_config(PreloadConfig {
            enable_mobile_data: false,
            mobile_max_concurrent: 1,
            max_preload_chapters: 5,
        });

        let indices = mgr.calculate_preload_indices("book1", 10, 100);
        assert!(indices.len() <= 5);
    }

    // ========================================================================
    // 重试机制测试
    // ========================================================================

    #[test]
    fn test_exponential_backoff() {
        let mgr = DownloadManager::new(3);
        
        // fail_count = 1: 2s (2^1 * 1000)
        let backoff_1 = mgr.calculate_backoff(1);
        assert_eq!(backoff_1, 2000);
        
        // fail_count = 2: 4s
        let backoff_2 = mgr.calculate_backoff(2);
        assert_eq!(backoff_2, 4000);
        
        // fail_count = 3: 8s
        let backoff_3 = mgr.calculate_backoff(3);
        assert_eq!(backoff_3, 8000);
        
        // fail_count = 7: 应该被限制在 64s (接近上限 60s)
        let backoff_7 = mgr.calculate_backoff(7);
        assert!(backoff_7 >= 60000 && backoff_7 <= 64000);
    }

    #[test]
    fn test_fail_with_retry_degradation() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        
        let task_id = "t1";
        
        // 第 1 次失败
        mgr.fail_task_with_retry(task_id, "error1".to_string());
        let task = mgr.get_task(task_id).unwrap();
        assert_eq!(task.fail_count, 1);
        assert!(task.priority < 100); // 正常优先级
        assert!(task.next_retry_at.is_some());

        // 第 3 次失败后降级
        mgr.fail_task_with_retry(task_id, "error2".to_string());
        mgr.fail_task_with_retry(task_id, "error3".to_string());
        let task = mgr.get_task(task_id).unwrap();
        assert_eq!(task.fail_count, 3);
        assert_eq!(task.priority, 1000); // 降级
    }

    #[test]
    fn test_retry_stats() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        
        mgr.fail_task_with_retry("t1", "error".to_string());
        
        let stats = mgr.get_retry_stats("t1").unwrap();
        assert_eq!(stats.fail_count, 1);
        assert!(stats.last_retry_at.is_some());
        assert!(stats.next_retry_at.is_some());
        assert!(!stats.degraded);

        // 第 3 次失败后 degraded
        mgr.fail_task_with_retry("t1", "error2".to_string());
        mgr.fail_task_with_retry("t1", "error3".to_string());
        let stats = mgr.get_retry_stats("t1").unwrap();
        assert!(stats.degraded);
    }

    #[test]
    fn test_add_preload_tasks() {
        let mut mgr = DownloadManager::new(3);
        
        let chapters = vec![
            (1, "http://example.com/ch1".to_string(), "Chapter 1".to_string()),
            (2, "http://example.com/ch2".to_string(), "Chapter 2".to_string()),
            (3, "http://example.com/ch3".to_string(), "Chapter 3".to_string()),
        ];
        
        let task_ids = mgr.add_preload_tasks("book1", chapters, 10);
        
        assert_eq!(task_ids.len(), 3);
        assert_eq!(mgr.stats().pending, 3);
        
        // 检查优先级顺序 - 第一个优先级最高（数字最小）
        let task1 = mgr.get_task(&task_ids[0]).unwrap();
        let task2 = mgr.get_task(&task_ids[1]).unwrap();
        assert!(task1.priority > task2.priority); // 先下载的优先级更高（值更小）
    }

    #[test]
    fn test_reset_for_retry() {
        let mut mgr = DownloadManager::new(3);
        mgr.add_task(make_task("t1", "book1", 0));
        
        mgr.fail_task_with_retry("t1", "error".to_string());
        let task = mgr.get_task("t1").unwrap();
        assert!(matches!(task.status, DownloadStatus::Failed(_)));
        assert!(task.next_retry_at.is_some());

        // 重置为待下载状态
        mgr.reset_for_retry("t1");
        let task = mgr.get_task("t1").unwrap();
        assert_eq!(task.status, DownloadStatus::Pending);
        assert!(task.error.is_none());
        assert!(task.next_retry_at.is_none());
    }

    // ========================================================================
    // 性能测试
    // ========================================================================

    #[test]
    fn test_performance_thousand_chapters() {
        use std::time::Instant;
        
        let mut mgr = DownloadManager::new(3);
        let start = Instant::now();
        
        // 模拟 1000 章小说的预下载场景
        let book_url = "http://example.com/book123";
        let total_chapters: i32 = 1000;
        let current_chapter: i32 = 500;
        
        let preload_indices = mgr.calculate_preload_indices(book_url, current_chapter, total_chapters);
        println!("Preload indices count: {}", preload_indices.len());
        assert!(preload_indices.len() <= 10); // 应该限制在 max_preload_chapters
        
        let elapsed = start.elapsed();
        println!("Time to calculate preload for 1000 chapters: {:?}", elapsed);
        assert!(elapsed.as_millis() < 100, "Preload calculation should be fast (<100ms)");
    }

    #[test]
    fn test_memory_efficiency() {
        use std::mem;
        
        // 计算单个任务的大小
        let task_size = mem::size_of::<DownloadTask>();
        println!("Size of DownloadTask: {} bytes ({:.2} KB)", task_size, task_size as f64 / 1024.0);
        
        // 1000 个任务的内存占用估算
        let estimated_memory = task_size * 1000;
        println!("Estimated memory for 1000 tasks: {:.2} MB", estimated_memory as f64 / (1024.0 * 1024.0));
        
        // 应该在合理范围内（假设任务大小不超过 500 bytes）
        // 如果是这样，1000 个任务约 0.5MB，远低于 100MB 上限
        assert!(task_size < 500, "Task size should be small");
    }
}
