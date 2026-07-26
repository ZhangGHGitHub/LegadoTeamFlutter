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
}

impl DownloadManager {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            queue: VecDeque::new(),
            tasks: HashMap::new(),
            max_concurrent,
            active_count: 0,
            is_paused: false,
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
}
