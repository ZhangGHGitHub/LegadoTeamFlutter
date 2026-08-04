//! 书架目录批量更新调度器
//!
//! 移植自 Kotlin MainViewModel.updateToc()
//! 支持并发控制、进度追踪、失败重试。

use serde::{Deserialize, Serialize};
use std::future::Future;
use std::sync::{Arc, Mutex};
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

/// 目录更新请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TocUpdateRequest {
    pub book_url: String,
    pub book_name: String,
    pub source_url: String,
    /// 越小越优先
    pub priority: i32,
    /// 是否强制刷新书籍详情（对标 Kotlin refreshBookInfo）
    #[serde(default)]
    pub refresh_book_info: bool,
}

/// 单本书更新状态
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TocUpdateStatus {
    pub book_url: String,
    pub book_name: String,
    pub status: UpdateState,
    /// 新发现的章节数
    pub new_chapters: i32,
    pub error: Option<String>,
    pub duration_ms: u64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum UpdateState {
    Pending,
    Updating,
    Completed,
    Failed,
}

/// 批量更新进度
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchUpdateProgress {
    pub total: usize,
    pub completed: usize,
    pub failed: usize,
    pub updating: usize,
    pub is_running: bool,
    pub results: Vec<TocUpdateStatus>,
}

/// 目录更新调度器
pub struct TocUpdater {
    /// 当前批量更新状态
    progress: Arc<Mutex<BatchUpdateProgress>>,
    /// 最大并发数
    max_concurrent: usize,
    /// 失败重试次数
    max_retries: i32,
}

impl TocUpdater {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            progress: Arc::new(Mutex::new(BatchUpdateProgress {
                total: 0,
                completed: 0,
                failed: 0,
                updating: 0,
                is_running: false,
                results: Vec::new(),
            })),
            max_concurrent,
            max_retries: 3,
        }
    }

    /// 获取最大并发数
    pub fn max_concurrent(&self) -> usize {
        self.max_concurrent
    }

    /// 获取最大重试次数
    pub fn max_retries(&self) -> i32 {
        self.max_retries
    }

    /// 设置最大重试次数
    pub fn set_max_retries(&mut self, retries: i32) {
        self.max_retries = retries;
    }

    /// 开始批量更新
    pub fn start_batch(&self, requests: Vec<TocUpdateRequest>) {
        let mut progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        progress.total = requests.len();
        progress.completed = 0;
        progress.failed = 0;
        progress.updating = 0;
        progress.is_running = true;
        progress.results = requests
            .iter()
            .map(|r| TocUpdateStatus {
                book_url: r.book_url.clone(),
                book_name: r.book_name.clone(),
                status: UpdateState::Pending,
                new_chapters: 0,
                error: None,
                duration_ms: 0,
                updated_at: 0,
            })
            .collect();
    }

    /// 标记单本开始更新
    pub fn mark_updating(&self, book_url: &str) {
        let mut progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(r) = progress.results.iter_mut().find(|r| r.book_url == book_url) {
            r.status = UpdateState::Updating;
            progress.updating += 1;
        }
    }

    /// 标记单本更新完成
    pub fn mark_completed(&self, book_url: &str, new_chapters: i32) {
        let mut progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(r) = progress.results.iter_mut().find(|r| r.book_url == book_url) {
            r.status = UpdateState::Completed;
            r.new_chapters = new_chapters;
            r.updated_at = now_millis();
            progress.completed += 1;
            progress.updating = progress.updating.saturating_sub(1);
        }
    }

    /// 标记单本更新失败
    pub fn mark_failed(&self, book_url: &str, error: &str) {
        let mut progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(r) = progress.results.iter_mut().find(|r| r.book_url == book_url) {
            r.status = UpdateState::Failed;
            r.error = Some(error.to_string());
            progress.failed += 1;
            progress.updating = progress.updating.saturating_sub(1);
        }
    }

    /// 完成批量更新
    pub fn finish_batch(&self) {
        let mut progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        progress.is_running = false;
    }

    /// 获取当前进度
    pub fn get_progress(&self) -> BatchUpdateProgress {
        self.progress
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// 获取需要更新的书籍（Pending 状态）
    pub fn pending_requests(&self) -> Vec<String> {
        let progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        progress
            .results
            .iter()
            .filter(|r| r.status == UpdateState::Pending)
            .map(|r| r.book_url.clone())
            .collect()
    }

    /// 是否可以开始新任务（并发控制）
    pub fn can_start_next(&self) -> bool {
        let progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        progress.is_running && progress.updating < self.max_concurrent
    }

    /// 重置进度
    pub fn reset(&self) {
        let mut progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        *progress = BatchUpdateProgress {
            total: 0,
            completed: 0,
            failed: 0,
            updating: 0,
            is_running: false,
            results: Vec::new(),
        };
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// 批量更新调度执行器（对标 Kotlin `MainViewModel.startUpTocJob` + `onEachParallel(threadCount)`）
///
/// 调度语义：
/// 1. 按 `book_url` 去重（对标 Kotlin `TocUpdateRequests.enqueue` 的同书合并语义，保留先到请求）
/// 2. 按 `priority` 升序稳定排序（越小越优先）
/// 3. 以 `updater.max_concurrent()` 为并发上限限流执行（对标 Kotlin 线程池并发数）
/// 4. 单本失败不中断整批（对标 Kotlin 逐本 runCatching + 标记 updateError）
/// 5. `should_stop` 触发后，尚未开始的书目标记为失败（对标 Kotlin cancelAll）
///
/// `worker` 为单本更新的真实逻辑（请求书源→获取目录→落库），
/// 成功时返回新发现章节数，失败时返回错误描述。
pub async fn run_batch<F, Fut, S>(
    updater: Arc<TocUpdater>,
    requests: Vec<TocUpdateRequest>,
    worker: F,
    should_stop: S,
) -> BatchUpdateProgress
where
    F: Fn(TocUpdateRequest) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<i32, String>> + Send + 'static,
    S: Fn() -> bool + Send + Sync + 'static,
{
    // 1. 按 book_url 去重，保留先到请求
    let mut deduped: Vec<TocUpdateRequest> = Vec::new();
    for req in requests {
        if !deduped.iter().any(|r| r.book_url == req.book_url) {
            deduped.push(req);
        }
    }
    // 2. 稳定排序：priority 越小越优先
    deduped.sort_by_key(|r| r.priority);

    updater.start_batch(deduped.clone());

    // 3. 信号量限流（并发数至少为 1）
    let semaphore = Arc::new(Semaphore::new(updater.max_concurrent().max(1)));
    let worker = Arc::new(worker);
    let should_stop = Arc::new(should_stop);

    let mut join_set = JoinSet::new();
    for req in deduped {
        let sem = Arc::clone(&semaphore);
        let u = Arc::clone(&updater);
        let w = Arc::clone(&worker);
        let stop = Arc::clone(&should_stop);
        join_set.spawn(async move {
            // 限流：拿到许可后才开始（许可持有至任务结束）
            let _permit = sem.acquire().await;
            let book_url = req.book_url.clone();
            if stop() {
                u.mark_failed(&book_url, "批量更新已停止");
                return;
            }
            u.mark_updating(&book_url);
            match w(req).await {
                Ok(new_chapters) => u.mark_completed(&book_url, new_chapters),
                Err(err) => u.mark_failed(&book_url, &err),
            }
        });
    }
    // 4. 等待全部任务结束（单本失败不影响其他任务）
    while join_set.join_next().await.is_some() {}

    updater.finish_batch();
    updater.get_progress()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_requests(n: usize) -> Vec<TocUpdateRequest> {
        (0..n)
            .map(|i| TocUpdateRequest {
                book_url: format!("https://example.com/book{}", i),
                book_name: format!("Book {}", i),
                source_url: format!("https://source.com/{}", i % 3),
                priority: i as i32,
                refresh_book_info: false,
            })
            .collect()
    }

    /// 在临时 current-thread 运行时上执行异步测试
    fn block_on<F: std::future::Future>(fut: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(fut)
    }

    #[test]
    fn test_new_updater_initial_state() {
        let updater = TocUpdater::new(4);
        let progress = updater.get_progress();
        assert_eq!(progress.total, 0);
        assert_eq!(progress.completed, 0);
        assert_eq!(progress.failed, 0);
        assert_eq!(progress.updating, 0);
        assert!(!progress.is_running);
        assert!(progress.results.is_empty());
    }

    #[test]
    fn test_start_batch() {
        let updater = TocUpdater::new(4);
        let requests = sample_requests(5);
        updater.start_batch(requests);

        let progress = updater.get_progress();
        assert_eq!(progress.total, 5);
        assert!(progress.is_running);
        assert_eq!(progress.results.len(), 5);
        assert!(progress
            .results
            .iter()
            .all(|r| r.status == UpdateState::Pending));
    }

    #[test]
    fn test_start_batch_empty() {
        let updater = TocUpdater::new(4);
        updater.start_batch(vec![]);

        let progress = updater.get_progress();
        assert_eq!(progress.total, 0);
        assert!(progress.is_running);
        assert!(progress.results.is_empty());
    }

    #[test]
    fn test_mark_updating() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(3));

        updater.mark_updating("https://example.com/book0");
        let progress = updater.get_progress();
        assert_eq!(progress.updating, 1);
        assert_eq!(progress.results[0].status, UpdateState::Updating);
        assert_eq!(progress.results[1].status, UpdateState::Pending);
    }

    #[test]
    fn test_mark_completed() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(3));

        updater.mark_updating("https://example.com/book1");
        updater.mark_completed("https://example.com/book1", 5);

        let progress = updater.get_progress();
        assert_eq!(progress.completed, 1);
        assert_eq!(progress.updating, 0);
        assert_eq!(progress.results[1].status, UpdateState::Completed);
        assert_eq!(progress.results[1].new_chapters, 5);
        assert!(progress.results[1].updated_at > 0);
    }

    #[test]
    fn test_mark_failed() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(3));

        updater.mark_updating("https://example.com/book2");
        updater.mark_failed("https://example.com/book2", "network timeout");

        let progress = updater.get_progress();
        assert_eq!(progress.failed, 1);
        assert_eq!(progress.updating, 0);
        assert_eq!(progress.results[2].status, UpdateState::Failed);
        assert_eq!(
            progress.results[2].error.as_deref(),
            Some("network timeout")
        );
    }

    #[test]
    fn test_finish_batch() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(2));
        assert!(updater.get_progress().is_running);

        updater.finish_batch();
        assert!(!updater.get_progress().is_running);
    }

    #[test]
    fn test_pending_requests() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(4));

        updater.mark_updating("https://example.com/book0");
        updater.mark_completed("https://example.com/book0", 2);
        updater.mark_updating("https://example.com/book1");

        let pending = updater.pending_requests();
        assert_eq!(pending.len(), 2);
        assert!(pending.contains(&"https://example.com/book2".to_string()));
        assert!(pending.contains(&"https://example.com/book3".to_string()));
    }

    #[test]
    fn test_can_start_next_within_limit() {
        let updater = TocUpdater::new(2);
        updater.start_batch(sample_requests(5));

        assert!(updater.can_start_next());
        updater.mark_updating("https://example.com/book0");
        assert!(updater.can_start_next());
        updater.mark_updating("https://example.com/book1");
        // 已达到并发上限
        assert!(!updater.can_start_next());
    }

    #[test]
    fn test_can_start_next_not_running() {
        let updater = TocUpdater::new(4);
        // 未启动批量更新
        assert!(!updater.can_start_next());
    }

    #[test]
    fn test_can_start_next_after_completion() {
        let updater = TocUpdater::new(1);
        updater.start_batch(sample_requests(3));

        updater.mark_updating("https://example.com/book0");
        assert!(!updater.can_start_next());

        updater.mark_completed("https://example.com/book0", 1);
        assert!(updater.can_start_next());
    }

    #[test]
    fn test_reset() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(5));
        updater.mark_updating("https://example.com/book0");
        updater.mark_completed("https://example.com/book0", 3);

        updater.reset();
        let progress = updater.get_progress();
        assert_eq!(progress.total, 0);
        assert_eq!(progress.completed, 0);
        assert!(!progress.is_running);
        assert!(progress.results.is_empty());
    }

    #[test]
    fn test_progress_statistics() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(6));

        updater.mark_updating("https://example.com/book0");
        updater.mark_updating("https://example.com/book1");
        updater.mark_updating("https://example.com/book2");
        updater.mark_completed("https://example.com/book0", 10);
        updater.mark_failed("https://example.com/book1", "error");

        let progress = updater.get_progress();
        assert_eq!(progress.total, 6);
        assert_eq!(progress.completed, 1);
        assert_eq!(progress.failed, 1);
        assert_eq!(progress.updating, 1);
    }

    #[test]
    fn test_mark_nonexistent_book() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(2));

        // 不应 panic
        updater.mark_updating("https://nonexistent.com");
        updater.mark_completed("https://nonexistent.com", 0);
        updater.mark_failed("https://nonexistent.com", "err");

        let progress = updater.get_progress();
        assert_eq!(progress.updating, 0);
        assert_eq!(progress.completed, 0);
        assert_eq!(progress.failed, 0);
    }

    #[test]
    fn test_max_retries() {
        let mut updater = TocUpdater::new(4);
        assert_eq!(updater.max_retries(), 3);
        updater.set_max_retries(5);
        assert_eq!(updater.max_retries(), 5);
    }

    #[test]
    fn test_thread_safety_concurrent_operations() {
        let updater = Arc::new(TocUpdater::new(10));
        updater.start_batch(sample_requests(100));

        let mut handles = vec![];
        for i in 0..10 {
            let u = Arc::clone(&updater);
            handles.push(std::thread::spawn(move || {
                for j in 0..10 {
                    let idx = i * 10 + j;
                    let url = format!("https://example.com/book{}", idx);
                    u.mark_updating(&url);
                    if j % 3 == 0 {
                        u.mark_failed(&url, "simulated error");
                    } else {
                        u.mark_completed(&url, j);
                    }
                }
            }));
        }

        for h in handles {
            h.join().unwrap();
        }

        let progress = updater.get_progress();
        assert_eq!(progress.total, 100);
        assert_eq!(progress.completed + progress.failed, 100);
        assert_eq!(progress.updating, 0);
    }

    #[test]
    fn test_restart_batch_resets_previous() {
        let updater = TocUpdater::new(4);
        updater.start_batch(sample_requests(3));
        updater.mark_updating("https://example.com/book0");
        updater.mark_completed("https://example.com/book0", 5);

        // 重新开始一批
        updater.start_batch(sample_requests(2));
        let progress = updater.get_progress();
        assert_eq!(progress.total, 2);
        assert_eq!(progress.completed, 0);
        assert_eq!(progress.results.len(), 2);
        assert!(progress.is_running);
    }

    // ─── run_batch 异步调度器测试 ──────────────────────────────────────────────

    /// 全部成功：逐本回报新章节数，结束后 is_running 为 false
    #[test]
    fn test_run_batch_all_success() {
        let progress = block_on(async {
            let updater = Arc::new(TocUpdater::new(4));
            run_batch(
                updater,
                sample_requests(5),
                |_req| async { Ok(3) },
                || false,
            )
            .await
        });

        assert_eq!(progress.total, 5);
        assert_eq!(progress.completed, 5);
        assert_eq!(progress.failed, 0);
        assert_eq!(progress.updating, 0);
        assert!(!progress.is_running);
        assert!(progress
            .results
            .iter()
            .all(|r| r.status == UpdateState::Completed && r.new_chapters == 3));
    }

    /// 失败处理：单本失败不中断整批，错误信息逐本回报
    #[test]
    fn test_run_batch_failure_handling() {
        let progress = block_on(async {
            let updater = Arc::new(TocUpdater::new(4));
            run_batch(
                updater,
                sample_requests(4),
                |req| async move {
                    if req.book_url.ends_with('1') {
                        Err("网络超时".to_string())
                    } else {
                        Ok(2)
                    }
                },
                || false,
            )
            .await
        });

        assert_eq!(progress.total, 4);
        assert_eq!(progress.completed, 3);
        assert_eq!(progress.failed, 1);
        let failed = progress
            .results
            .iter()
            .find(|r| r.status == UpdateState::Failed)
            .unwrap();
        assert_eq!(failed.book_url, "https://example.com/book1");
        assert_eq!(failed.error.as_deref(), Some("网络超时"));
    }

    /// 限流：同时在飞任务数不超过 max_concurrent
    #[test]
    fn test_run_batch_respects_concurrency_limit() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let current = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let progress = block_on({
            let current = Arc::clone(&current);
            let peak = Arc::clone(&peak);
            async move {
                let updater = Arc::new(TocUpdater::new(2));
                run_batch(
                    updater,
                    sample_requests(6),
                    move |_req| {
                        let current = Arc::clone(&current);
                        let peak = Arc::clone(&peak);
                        async move {
                            let now = current.fetch_add(1, Ordering::SeqCst) + 1;
                            // 记录并发峰值
                            peak.fetch_max(now, Ordering::SeqCst);
                            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                            current.fetch_sub(1, Ordering::SeqCst);
                            Ok(1)
                        }
                    },
                    || false,
                )
                .await
            }
        });

        assert_eq!(progress.completed, 6);
        assert!(
            peak.load(Ordering::SeqCst) <= 2,
            "并发峰值 {} 超过上限 2",
            peak.load(Ordering::SeqCst)
        );
    }

    /// 停止：should_stop 触发后未开始的书目标记为失败
    #[test]
    fn test_run_batch_stop_marks_remaining_failed() {
        let progress = block_on(async {
            let updater = Arc::new(TocUpdater::new(1));
            run_batch(updater, sample_requests(3), |_req| async { Ok(1) }, || true).await
        });

        assert_eq!(progress.total, 3);
        assert_eq!(progress.completed, 0);
        assert_eq!(progress.failed, 3);
        assert!(progress
            .results
            .iter()
            .all(|r| r.error.as_deref() == Some("批量更新已停止")));
        assert!(!progress.is_running);
    }

    /// 去重 + 优先级：同 book_url 仅保留一次，结果按 priority 升序排列
    #[test]
    fn test_run_batch_dedup_and_priority_order() {
        let mut requests = vec![
            TocUpdateRequest {
                book_url: "https://example.com/a".into(),
                book_name: "A".into(),
                source_url: "s1".into(),
                priority: 9,
                refresh_book_info: false,
            },
            TocUpdateRequest {
                book_url: "https://example.com/b".into(),
                book_name: "B".into(),
                source_url: "s2".into(),
                priority: 1,
                refresh_book_info: false,
            },
            // 与第一本重复，应被去重
            TocUpdateRequest {
                book_url: "https://example.com/a".into(),
                book_name: "A-dup".into(),
                source_url: "s3".into(),
                priority: 0,
                refresh_book_info: false,
            },
        ];
        requests.push(TocUpdateRequest {
            book_url: "https://example.com/c".into(),
            book_name: "C".into(),
            source_url: "s4".into(),
            priority: 5,
            refresh_book_info: false,
        });

        let progress = block_on(async {
            let updater = Arc::new(TocUpdater::new(4));
            run_batch(updater, requests, |_req| async { Ok(0) }, || false).await
        });

        assert_eq!(progress.total, 3);
        let urls: Vec<&str> = progress
            .results
            .iter()
            .map(|r| r.book_url.as_str())
            .collect();
        // priority 升序：b(1) → c(5) → a(9)
        assert_eq!(
            urls,
            vec![
                "https://example.com/b",
                "https://example.com/c",
                "https://example.com/a",
            ]
        );
    }

    /// 空批次：正常结束不 panic
    #[test]
    fn test_run_batch_empty() {
        let progress = block_on(async {
            let updater = Arc::new(TocUpdater::new(4));
            run_batch(updater, vec![], |_req| async { Ok(0) }, || false).await
        });
        assert_eq!(progress.total, 0);
        assert!(!progress.is_running);
    }
}
