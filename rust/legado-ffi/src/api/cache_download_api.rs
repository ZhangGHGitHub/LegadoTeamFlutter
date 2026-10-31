//! 缓存批量下载 FFI 层（Task #136 R7，API_CONTRACT §2.43.3）
//!
//! 对标 Kotlin `CacheActivity` 批量缓存下载：任务创建 / 进度查询 / 取消。
//!
//! - 复用正文抓取链路 [`crate::api::reader::get_chapter_content_full`]
//!   （在线书抓取后自动写缓存；本地书解析后经 R5 [`crate::api::cache_api::save_chapter_content`] 写入）；
//! - 任务表进程内内存 + caches KV 落库（重启后恢复进行中任务）；
//! - 取消机制对照书源校验流（`source_check_api::CHECK_CANCELLED`）的
//!   AtomicBool 模式，每任务独立取消令牌；
//! - worker 运行于独立系统线程：正文抓取内部含 `runtime::block_on`，
//!   不可在 tokio worker 内嵌套执行。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::time::Duration;

use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::BookRepository;
use serde::{Deserialize, Serialize};

use crate::db_state::with_database;

/// 任务 ID 分配器（进程内递增；启动时从 DB 恢复最大值）
static NEXT_TASK_ID: AtomicU64 = AtomicU64::new(1);

/// 进程内任务表：task_id → 任务内部状态
static TASKS: LazyLock<Mutex<HashMap<u64, Arc<TaskInner>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 是否已从 DB 恢复过进行中任务
static RESTORED: AtomicBool = AtomicBool::new(false);

/// 测试注入：指定章节 index 在 worker 内 panic（i32::MIN = 不注入）
///
/// 批9b-2 审查回修：验证 `catch_unwind` 隔离与「panic 计失败」语义。
#[cfg(test)]
static TEST_PANIC_CHAPTER: AtomicI32 = AtomicI32::new(i32::MIN);

/// 测试注入：worker 循环入口 panic（验证 P3-5 整体隔离与 join 收尾）
#[cfg(test)]
static TEST_PANIC_WORKER_LOOP: AtomicBool = AtomicBool::new(false);

const PERSIST_PREFIX: &str = "cacheDownloadTask:";
const PERSIST_INDEX: &str = "cacheDownloadTaskIndex";
const PERSIST_NEXT_ID: &str = "cacheDownloadNextId";

/// 单书派发/持久化滑动窗口（章，批9b-2 审查回修）
///
/// 4×并发上限（8×4=32）：既给乱序完成留足缓冲，又保证
/// `finished_ahead` / 持久化 `finishedChapters` 长度有界（≤32），
/// 慢首章时不会无限增长。窗口外的章不派发（恢复后重下，幂等）。
const DOWNLOAD_WINDOW: i32 = (MAX_DOWNLOAD_CONCURRENCY as i32) * 4;

/// 进程级下载准入：同时只准入 1 本书（批9b-2 审查回修）
///
/// 排队任务仅保留 1 个协调线程在 Condvar 上等待（不做 HTTP、不占
/// worker），获得准入后才创建单书 N 个 worker。取消用 100ms 超时
/// 轮询兜底「取消置位 → notify」之间的丢失唤醒窗口（非忙等）。
struct DownloadAdmission {
    /// 当前准入的任务 ID（None = 空闲）
    active: Mutex<Option<u64>>,
    cv: Condvar,
}

impl DownloadAdmission {
    fn new() -> Self {
        Self {
            active: Mutex::new(None),
            cv: Condvar::new(),
        }
    }

    /// 申请本书准入；排队期间取消置位 → 返回 None（不发起任何 HTTP）
    fn acquire<'a>(
        &'a self,
        task_id: u64,
        cancel: &AtomicBool,
    ) -> Option<DownloadAdmissionGuard<'a>> {
        let mut active = self.active.lock().unwrap_or_else(|p| p.into_inner());
        loop {
            if cancel.load(Ordering::SeqCst) {
                return None;
            }
            if active.is_none() {
                *active = Some(task_id);
                return Some(DownloadAdmissionGuard {
                    admission: self,
                    task_id,
                });
            }
            let (guard, _) = self
                .cv
                .wait_timeout(active, Duration::from_millis(100))
                .unwrap_or_else(|p| p.into_inner());
            active = guard;
        }
    }

    /// 唤醒所有排队任务（取消/释放时调用）
    fn notify(&self) {
        let _guard = self.active.lock().unwrap_or_else(|p| p.into_inner());
        self.cv.notify_all();
    }
}

/// 准入守卫：离开作用域（含 panic 展开）即释放并唤醒下一本书
struct DownloadAdmissionGuard<'a> {
    admission: &'a DownloadAdmission,
    task_id: u64,
}

impl Drop for DownloadAdmissionGuard<'_> {
    fn drop(&mut self) {
        let mut active = self
            .admission
            .active
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        if *active == Some(self.task_id) {
            *active = None;
        }
        self.admission.cv.notify_all();
    }
}

/// 全局下载准入单例（进程级同时只准入 1 本书）
static DOWNLOAD_ADMISSION: LazyLock<DownloadAdmission> = LazyLock::new(DownloadAdmission::new);

struct TaskInner {
    book_url: String,
    start_chapter: i32,
    end_chapter: i32,
    total: i32,
    completed: AtomicI32,
    failed: AtomicI32,
    /// 派发游标：下一个待认领的章节 index（批9b-2 起多 worker 共享）。
    /// 仅在滑动窗口 `[finished_prefix, finished_prefix + DOWNLOAD_WINDOW)`
    /// 内认领；进程内状态，不持久化
    next_dispatch: AtomicI32,
    /// 连续完成前缀：所有 `< 该值` 的章节 index 均已尝试（成功或失败）。
    /// 持久化快照的 `nextIndex` 取该值，重启续跑从此处继续（不跳过未完成章）
    finished_prefix: AtomicI32,
    cancel: AtomicBool,
    status: Mutex<String>,
    /// 任务内已失败章节 index 集合（对齐参考版 `CacheDownloadStateStore`
    /// 的 `failedIndices`：失败加入、成功移除、恢复回读；查询按书跨任务合并）
    failed_chapters: Mutex<HashSet<i32>>,
    /// 已完成但连续前缀尚未推进的章节 index（`>= finished_prefix`，
    /// 批9b-2）。派发窗口保证长度 ≤ `DOWNLOAD_WINDOW`（32）；持久化到
    /// 快照 `finishedChapters`，重启后续跑不重复计数/下载已完成的散章
    finished_ahead: Mutex<HashSet<i32>>,
    /// 当前在途（正在抓取）的章节 index 集合（§2.43.7 数据源；
    /// 批9b-2 审查回修：0..=N 个，0 表示排队等待全局准入）
    in_flight: Mutex<HashSet<i32>>,
    /// 任务状态锁：完成计数 / 失败集合 / 完成前缀与快照落库在同一临界区内
    /// 更新，保证落库快照自洽（completed 包含的章必然也在完成集合中）。
    /// 锁序：state_lock → failed_chapters / finished_ahead；禁止反向获取
    state_lock: Mutex<()>,
    /// 滑动窗口等待：前缀推进或取消时唤醒被窗口挡住的 worker
    /// （等待用 100ms 超时兜底丢失唤醒，非忙等）
    window_lock: Mutex<()>,
    window_cv: Condvar,
    /// worker 循环 panic 标志（P3-5）：任一 worker 逃逸单章隔离后置位，
    /// 终态不判 completed，置 failed 供用户重试
    worker_panicked: AtomicBool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheDownloadTask {
    pub task_id: u64,
    pub book_url: String,
    pub status: String,
    pub total: i32,
    pub completed: i32,
    pub failed: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedTask {
    task_id: u64,
    book_url: String,
    start_chapter: i32,
    end_chapter: i32,
    total: i32,
    completed: i32,
    failed: i32,
    /// 连续完成前缀（批9b-2 语义；旧快照的「下一待下载章」含义是其特例：
    /// 单 worker 顺序执行时两者等价）。所有 `< nextIndex` 的章均已尝试
    next_index: i32,
    status: String,
    /// 失败章索引集合（升序存储）。`#[serde(default)]` 兼容旧快照：
    /// 契约冻结前落库的 `cacheDownloadTask:` JSON 无此字段，读为未失败
    #[serde(default)]
    failed_chapters: Vec<i32>,
    /// 已完成但连续前缀尚未推进的章索引（升序；批9b-2）。
    /// **有界**：派发滑动窗口 32 章 ⇒ 长度 ≤32；`#[serde(default)]`
    /// 兼容旧快照（旧版单 worker 无此状态）。恢复时窗口外条目丢弃并
    /// 扣减对应计数（该章重下，幂等）
    #[serde(default)]
    finished_chapters: Vec<i32>,
}

fn persist_key(task_id: u64) -> String {
    format!("{PERSIST_PREFIX}{task_id}")
}

fn persist_snapshot(task_id: u64, task: &TaskInner) {
    let _state_guard = task
        .state_lock
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    persist_snapshot_locked(task_id, task);
}

/// 快照落库（调用方必须持有 `task.state_lock`）
///
/// 批9b-2：并发完成路径在同一临界区内更新计数/集合/前缀后再调用本函数，
/// 保证快照不会出现「completed 已增加但完成集合未记录」的撕裂状态
/// （否则重启续跑会重复计数/重复下载）。
fn persist_snapshot_locked(task_id: u64, task: &TaskInner) {
    let status = task
        .status
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| "running".to_string());
    let row = PersistedTask {
        task_id,
        book_url: task.book_url.clone(),
        start_chapter: task.start_chapter,
        end_chapter: task.end_chapter,
        total: task.total,
        completed: task.completed.load(Ordering::SeqCst),
        failed: task.failed.load(Ordering::SeqCst),
        next_index: task.finished_prefix.load(Ordering::SeqCst),
        status,
        failed_chapters: failed_indices(task),
        finished_chapters: finished_ahead_indices(task),
    };
    let Ok(json) = serde_json::to_string(&row) else {
        return;
    };
    let _ = with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.put(&persist_key(task_id), &json, 0)?;
        let mut ids: Vec<u64> = repo
            .get(PERSIST_INDEX)?
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        if !ids.contains(&task_id) {
            ids.push(task_id);
            ids.sort_unstable();
            let idx = serde_json::to_string(&ids).unwrap_or_else(|_| "[]".into());
            repo.put(PERSIST_INDEX, &idx, 0)?;
        }
        let next = NEXT_TASK_ID.load(Ordering::SeqCst);
        repo.put(PERSIST_NEXT_ID, &next.to_string(), 0)?;
        Ok(())
    });
}

/// 任务失败章索引（升序；锁中毒时降级空集合）。对齐参考版
/// `CacheDownloadStateStore.failedIndices`（`CacheDownloadStateStore.kt:45`）
fn failed_indices(task: &TaskInner) -> Vec<i32> {
    let mut out: Vec<i32> = task
        .failed_chapters
        .lock()
        .map(|set| set.iter().copied().collect())
        .unwrap_or_default();
    out.sort_unstable();
    out
}

/// 记入失败章（对齐参考版 `markFailed`：`CacheDownloadStateStore.kt:48-57`
/// 失败加入 `failedIndices`）
fn mark_failed(task: &TaskInner, index: i32) {
    if let Ok(mut set) = task.failed_chapters.lock() {
        set.insert(index);
    }
}

/// 清除本任务失败章标记（对齐参考版 `markSuccess`
/// `CacheDownloadStateStore.kt:35-46` 成功从 `failedIndices` 移除）
fn clear_failed(task: &TaskInner, index: i32) {
    if let Ok(mut set) = task.failed_chapters.lock() {
        set.remove(&index);
    }
}

/// 跨任务清除某书某章的失败标记：参考版失败集合是**单书一份**
/// （`CacheDownloadStateStore` 按 bookUrl 聚合），该书任一任务重新取到该章
/// 开始下载即清除之前任何一次任务的失败记录（对齐参考版
/// `CacheBookModel.kt:571-573` 在 `nextDownloadCandidate` 取到章时
/// `clearFailure`，即「任务启动清空/重试移除」语义；我方失败集合按任务
/// 存储，故需跨任务清除以保持单书可观测语义一致）。
fn clear_failed_for_book(book_url: &str, index: i32) {
    if let Ok(map) = TASKS.lock() {
        for task in map.values().filter(|t| t.book_url == book_url) {
            clear_failed(task, index);
        }
    }
}

/// 已完成但连续前缀未推进的章索引（升序；锁中毒时降级空集合）
fn finished_ahead_indices(task: &TaskInner) -> Vec<i32> {
    let mut out: Vec<i32> = task
        .finished_ahead
        .lock()
        .map(|set| set.iter().copied().collect())
        .unwrap_or_default();
    out.sort_unstable();
    out
}

/// 记录一章已完成（成功或失败均算「已尝试」），并推进连续完成前缀
///
/// 批9b-2：调用方必须持有 `task.state_lock`（与计数/快照同一临界区）。
/// 乱序完成时该章先进入 `finished_ahead`；前缀逐章推进时把它们移出。
/// 批9b-2 审查回修：派发窗口 `[prefix, prefix+32)` 保证集合长度 ≤32；
/// 前缀推进后唤醒被窗口挡住的 worker。
fn record_finished_locked(task: &TaskInner, index: i32) {
    let mut advanced = false;
    if let Ok(mut ahead) = task.finished_ahead.lock() {
        let mut prefix = task.finished_prefix.load(Ordering::SeqCst);
        if index >= prefix {
            ahead.insert(index);
            while ahead.remove(&prefix) {
                prefix += 1;
                advanced = true;
            }
            task.finished_prefix.store(prefix, Ordering::SeqCst);
        }
    }
    if advanced {
        task.window_cv.notify_all();
    }
}

/// 在途章索引（升序；锁中毒时降级空集合）
fn in_flight_indices(task: &TaskInner) -> Vec<i32> {
    let mut out: Vec<i32> = task
        .in_flight
        .lock()
        .map(|set| set.iter().copied().collect())
        .unwrap_or_default();
    out.sort_unstable();
    out
}

/// 由落库快照构建任务内存态（`ensure_restored` 回读复用；失败集合一并恢复）
fn task_from_persisted(row: PersistedTask) -> Arc<TaskInner> {
    // 批9b-2 审查回修：恢复连续完成前缀，并把「已完成但前缀未推进」的散章
    // 重放回 finished_ahead；派发游标从前缀开始（散章在前缀推进到其位置时跳过）。
    // 防御历史/异常超窗快照：只保留窗口内条目；窗口外条目已计入持久化计数，
    // 恢复时同步扣减（该章会被重下，幂等），保证 completed+failed 最终可回到 total。
    let start = row.start_chapter;
    let end = row.end_chapter;
    let mut prefix = row.next_index.max(start).min(end.saturating_add(1));
    let window_end = prefix.saturating_add(DOWNLOAD_WINDOW);
    let failed_set: HashSet<i32> = row.failed_chapters.into_iter().collect();
    let mut ahead: HashSet<i32> = HashSet::new();
    let mut dropped_success: i32 = 0;
    let mut dropped_failed: i32 = 0;
    for index in row.finished_chapters {
        if index < prefix || index < start || index > end {
            continue;
        }
        if index < window_end {
            ahead.insert(index);
        } else if failed_set.contains(&index) {
            dropped_failed += 1;
        } else {
            dropped_success += 1;
        }
    }
    while ahead.remove(&prefix) {
        prefix += 1;
    }
    Arc::new(TaskInner {
        book_url: row.book_url,
        start_chapter: start,
        end_chapter: end,
        total: row.total,
        completed: AtomicI32::new(row.completed.saturating_sub(dropped_success)),
        failed: AtomicI32::new(row.failed.saturating_sub(dropped_failed)),
        next_dispatch: AtomicI32::new(prefix),
        finished_prefix: AtomicI32::new(prefix),
        cancel: AtomicBool::new(false),
        status: Mutex::new("running".to_string()),
        failed_chapters: Mutex::new(failed_set),
        finished_ahead: Mutex::new(ahead),
        in_flight: Mutex::new(HashSet::new()),
        state_lock: Mutex::new(()),
        window_lock: Mutex::new(()),
        window_cv: Condvar::new(),
        worker_panicked: AtomicBool::new(false),
    })
}

fn ensure_restored() {
    if RESTORED.swap(true, Ordering::SeqCst) {
        return;
    }
    let restored: Vec<PersistedTask> = with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        if let Some(next_s) = repo.get(PERSIST_NEXT_ID)? {
            if let Ok(next) = next_s.parse::<u64>() {
                NEXT_TASK_ID.fetch_max(next, Ordering::SeqCst);
            }
        }
        let ids: Vec<u64> = repo
            .get(PERSIST_INDEX)?
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let mut out = Vec::new();
        for id in ids {
            if let Some(json) = repo.get(&persist_key(id))? {
                if let Ok(row) = serde_json::from_str::<PersistedTask>(&json) {
                    out.push(row);
                }
            }
        }
        Ok(out)
    })
    .unwrap_or_default();

    for row in restored {
        if row.status != "running" {
            continue;
        }
        let task_id = row.task_id;
        NEXT_TASK_ID.fetch_max(task_id + 1, Ordering::SeqCst);
        // 恢复回读：失败章集合一并恢复（对齐参考版 `clearRuntimeState`
        // 重启/关闭时保留 `failedIndices` 供展示与重试，
        // `CacheDownloadStateStore.kt:103-121`）
        let task = task_from_persisted(row);
        if let Ok(mut map) = TASKS.lock() {
            if map.contains_key(&task_id) {
                continue;
            }
            map.insert(task_id, Arc::clone(&task));
        } else {
            continue;
        }
        let _ = std::thread::Builder::new()
            .name(format!("cache-download-resume-{task_id}"))
            .spawn(move || run_download(task_id, task));
    }
}

pub fn cache_download_start(
    book_url: &str,
    start_chapter: i32,
    end_chapter: i32,
) -> LegadoResult<u64> {
    ensure_restored();

    {
        let map = TASKS
            .lock()
            .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?;
        let mut running: Vec<(u64, &Arc<TaskInner>)> = map
            .iter()
            .filter(|(_, t)| {
                t.book_url == book_url && t.status.lock().map(|s| *s == "running").unwrap_or(false)
            })
            .map(|(id, t)| (*id, t))
            .collect();
        if let Some((id, _)) = running.pop() {
            return Ok(id);
        }
    }

    let book_exists =
        with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))?.is_some();
    if !book_exists {
        return Err(LegadoError::Database(format!("书籍不存在: {book_url}")));
    }
    let chapter_count = with_database(|db| {
        BookChapterRepository::new(db.connection()).count_by_book_url(book_url)
    })?;
    if chapter_count <= 0 {
        return Err(LegadoError::Database(format!(
            "书籍无章节目录，无法批量缓存: {book_url}"
        )));
    }

    let start = start_chapter.max(0);
    let end = end_chapter.min(chapter_count as i32 - 1);
    if end < start {
        return Err(LegadoError::Ffi(format!(
            "章节范围非法: start={start} > end={end}"
        )));
    }

    let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);
    let task = Arc::new(TaskInner {
        book_url: book_url.to_string(),
        start_chapter: start,
        end_chapter: end,
        total: end - start + 1,
        completed: AtomicI32::new(0),
        failed: AtomicI32::new(0),
        next_dispatch: AtomicI32::new(start),
        finished_prefix: AtomicI32::new(start),
        cancel: AtomicBool::new(false),
        status: Mutex::new("running".to_string()),
        failed_chapters: Mutex::new(HashSet::new()),
        finished_ahead: Mutex::new(HashSet::new()),
        in_flight: Mutex::new(HashSet::new()),
        state_lock: Mutex::new(()),
        window_lock: Mutex::new(()),
        window_cv: Condvar::new(),
        worker_panicked: AtomicBool::new(false),
    });

    TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?
        .insert(task_id, Arc::clone(&task));

    persist_snapshot(task_id, &task);

    std::thread::Builder::new()
        .name(format!("cache-download-{task_id}"))
        .spawn(move || run_download(task_id, task))
        .map_err(|e| LegadoError::Ffi(format!("下载线程启动失败: {e}")))?;

    Ok(task_id)
}

/// 批量下载并发硬上限（批9b-2，契约 §2.43.3）
///
/// 对齐参考版 `CacheBook.maxDownloadConcurrency = 8`（`CacheBook.kt:50,79`
/// 的 `cacheBookThreadCount.coerceIn(1, 8)`）与原版下载线程池
/// `min(threadCount, AppConst.MAX_THREAD=9)` 的收敛口径。
pub(crate) const MAX_DOWNLOAD_CONCURRENCY: usize = 8;

/// 读取本次任务的章节下载并发（批9b-2 审查回修）
///
/// `config:threadCount`（缺省 16）夹逼 1..=[`MAX_DOWNLOAD_CONCURRENCY`]；
/// 任务启动时读取一次，进行中任务不热更新。
fn download_concurrency() -> usize {
    crate::api::config_api::resolve_thread_count(
        crate::api::config_api::DEFAULT_THREAD_COUNT,
        MAX_DOWNLOAD_CONCURRENCY,
    )
}

fn run_download(task_id: u64, task: Arc<TaskInner>) {
    // 批9b-2 审查回修：进程级同时只准入 1 本书。排队期间仅本协调线程在
    // Condvar 上等待（不发起 HTTP、不创建 worker）；取消会唤醒并直接进入
    // cancelled。守卫 Drop 释放准入并唤醒下一本书（含 panic 展开路径）。
    let Some(_admission) = DOWNLOAD_ADMISSION.acquire(task_id, &task.cancel) else {
        set_status(&task, "cancelled");
        persist_snapshot(task_id, &task);
        return;
    };
    if task.cancel.load(Ordering::SeqCst) {
        set_status(&task, "cancelled");
        persist_snapshot(task_id, &task);
        return;
    }

    let concurrency = download_concurrency();
    // 当前线程作为 worker 0；其余 worker 用显式系统线程承载——正文抓取
    // 链路内部含 `runtime::block_on`，不可在 tokio worker 内嵌套执行。
    let mut workers = Vec::with_capacity(concurrency.saturating_sub(1));
    for worker in 1..concurrency {
        let task_for_worker = Arc::clone(&task);
        match std::thread::Builder::new()
            .name(format!("cache-download-{task_id}-w{worker}"))
            .spawn(move || download_worker(task_id, &task_for_worker))
        {
            Ok(handle) => workers.push(handle),
            // 启动失败降级为更少并发，不阻断任务
            Err(e) => log::warn!("下载 worker 启动失败（降级并发继续）: {e}"),
        }
    }
    download_worker(task_id, &task);
    let mut join_failed = false;
    for handle in workers {
        if handle.join().is_err() {
            join_failed = true;
        }
    }
    // 主 worker 的循环 panic 已在 download_worker 内捕获并置位；
    // spawned worker 若逃逸（join Err）同样计入。
    let worker_panicked = task.worker_panicked.load(Ordering::SeqCst) || join_failed;

    let all_attempted = task.finished_prefix.load(Ordering::SeqCst) > task.end_chapter;
    let counted = task.completed.load(Ordering::SeqCst) + task.failed.load(Ordering::SeqCst);
    if worker_panicked {
        // worker 循环 panic：不再派发并等待收尾后置 failed（供用户重试；
        // `ensure_restored` 只恢复 running 状态，不会自动重跑 failed 任务）。
        // 即使 panic 置位了取消标志，也不能误报 cancelled。
        log::warn!(
            "批量下载任务 {task_id} worker panic：attempted={all_attempted} counted={counted}/{}",
            task.total
        );
        set_status(&task, "failed");
    } else if task.cancel.load(Ordering::SeqCst) && !all_attempted {
        // 取消：已全部尝试时保持 completed/failed，与旧单线程实现
        // 「最后一章完成后循环自然退出」语义一致。
        set_status(&task, "cancelled");
    } else if all_attempted && counted == task.total {
        let all_failed = task.failed.load(Ordering::SeqCst) == task.total;
        set_status(&task, if all_failed { "failed" } else { "completed" });
    } else {
        // 未全部尝试（意外早退）或计数不自洽：不谎报 completed，
        // 置 failed 供**用户重试**（`ensure_restored` 只恢复 running 状态）。
        log::warn!(
            "批量下载任务 {task_id} 未完整完成：attempted={all_attempted} counted={counted}/{}",
            task.total
        );
        set_status(&task, "failed");
    }
    persist_snapshot(task_id, &task);
}

/// 判断章 index 是否已尝试（连续前缀之前，或已完成散章）
///
/// P0-1（批9b-2 复验）：必须在 `finished_ahead` 锁内**同时**读取
/// `finished_prefix`——`record_finished_locked` 在同一把锁内先移除 ahead
/// 条目、再把前缀写回原子变量；分开读取会出现「ahead 已移除、前缀尚未更新」
/// 的窗口，导致刚完成（或快照中已完成）的章被重新下载并重复计数。
fn is_finished(task: &TaskInner, index: i32) -> bool {
    let ahead = task
        .finished_ahead
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    index < task.finished_prefix.load(Ordering::SeqCst) || ahead.contains(&index)
}

/// 从滑动窗口认领下一个章节 index（批9b-2 审查回修）
///
/// 仅在 `[finished_prefix, finished_prefix + DOWNLOAD_WINDOW)` 内认领，
/// 保证 `finished_ahead` 与持久化集合有界；窗口满时在 Condvar 上等待
/// 前缀推进或取消（100ms 超时兜底丢失唤醒，非忙等）。
fn claim_next(task: &TaskInner) -> Option<i32> {
    loop {
        if task.cancel.load(Ordering::SeqCst) {
            return None;
        }
        // P0-1：游标不得落后于连续前缀，避免派发已被前缀越过的陈旧 index
        let prefix_now = task.finished_prefix.load(Ordering::SeqCst);
        task.next_dispatch.fetch_max(prefix_now, Ordering::SeqCst);
        let mut claim = task.next_dispatch.load(Ordering::SeqCst);
        loop {
            if claim > task.end_chapter {
                return None;
            }
            let prefix = task.finished_prefix.load(Ordering::SeqCst);
            if claim >= prefix.saturating_add(DOWNLOAD_WINDOW) {
                break; // 窗口满 → 等前缀推进
            }
            match task.next_dispatch.compare_exchange(
                claim,
                claim + 1,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return Some(claim),
                Err(actual) => claim = actual,
            }
        }
        let guard = task
            .window_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let _ = task
            .window_cv
            .wait_timeout(guard, Duration::from_millis(100));
    }
}

/// 下载 worker：整个循环经 `catch_unwind` 包裹（P3-5）
///
/// panic 时置 `worker_panicked` + 取消标志，停止其他 worker 继续派发并
/// 唤醒窗口等待者；在途章完成后各 worker 退出，`run_download` join 全部
/// worker 后才释放全局准入。单章抓取另有一层 `catch_unwind`（panic 计为
/// 该章失败，任务可继续）。
fn download_worker(task_id: u64, task: &Arc<TaskInner>) {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        download_worker_loop(task_id, task);
    }));
    if result.is_err() {
        log::error!("下载 worker 循环 panic（已隔离；停止派发并等待其他 worker 收尾）");
        task.worker_panicked.store(true, Ordering::SeqCst);
        task.cancel.store(true, Ordering::SeqCst);
        task.window_cv.notify_all();
    }
}

fn download_worker_loop(task_id: u64, task: &Arc<TaskInner>) {
    let book_url = task.book_url.clone();
    #[cfg(test)]
    if TEST_PANIC_WORKER_LOOP.load(Ordering::SeqCst) {
        panic!("测试注入：worker loop panic");
    }
    loop {
        let Some(index) = claim_next(task) else {
            return;
        };
        // P0-1：前缀推进可能使刚认领的 index 过期，或该章已在恢复快照的
        // 完成集合中——跳过且不重复计数（is_finished 在 ahead 锁内同时读前缀）
        if is_finished(task, index) {
            continue;
        }

        // 取到该章开始下载即清除其失败标记（对齐参考版
        // `CacheBookModel.kt:571-573` nextDownloadCandidate 的 clearFailure，
        // 「任务启动清空/重试移除」）；若本次再失败，下方失败分支重新记入
        clear_failed_for_book(&book_url, index);
        task.in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(index);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            #[cfg(test)]
            if TEST_PANIC_CHAPTER.load(Ordering::SeqCst) == index {
                panic!("测试注入：下载 worker panic");
            }
            download_one(&book_url, index)
        }));
        task.in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&index);

        let succeeded = match result {
            Ok(Ok(())) => true,
            Ok(Err(_)) => false,
            Err(_) => {
                log::error!("批量下载章节 {index} 时 worker panic（已隔离，计为失败）");
                false
            }
        };

        // 计数/失败集合/完成前缀/快照同一临界区，保证快照自洽
        let _state_guard = task
            .state_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if succeeded {
            task.completed.fetch_add(1, Ordering::SeqCst);
            // 成功分支从集合移除（对齐参考版 markSuccess
            // `CacheDownloadStateStore.kt:35-46`；取章时已清，此处二次兜底）
            clear_failed(task, index);
        } else {
            task.failed.fetch_add(1, Ordering::SeqCst);
            // 失败分支除计数外同步记入失败集合（契约 §2.43.8）：
            // 目录页 ERROR 态数据来源（对齐参考版 markFailed
            // `CacheDownloadStateStore.kt:48-57`）
            mark_failed(task, index);
        }
        record_finished_locked(task, index);
        persist_snapshot_locked(task_id, task);
    }
}

fn download_one(book_url: &str, chapter_index: i32) -> LegadoResult<()> {
    if crate::api::reader::is_local_book(book_url) {
        let chapter = with_database(|db| {
            BookChapterRepository::new(db.connection())
                .find_by_book_url_and_index(book_url, chapter_index)
        })?
        .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;
        // [批18d P3] 本地书 book_url 可能是相对可迁移标识（如 `books/x.txt`），
        // 落盘读取前必须经 resolver 还原为当前 Documents 下的真实路径；
        // 绝对路径/Web URL 原样透传（与 reader.rs 阅读链路同语义）。
        let real_path = crate::db_state::resolve_local_book_path(book_url);
        // [批37b P1-1] 离线缓存与阅读器同口径：本地 TXT 按 Book.charset 解码
        let charset = crate::api::reader::local_book_charset(book_url)?;
        let content = legado_book::LocalBook::get_chapter_content_with_charset(
            &real_path,
            &crate::api::reader::chapter_to_local_info(&chapter),
            charset.as_deref(),
        )?;
        crate::api::cache_api::save_chapter_content(
            book_url,
            chapter_index,
            &chapter.title,
            &content,
            &chapter.url,
        )?;
        Ok(())
    } else {
        crate::api::reader::get_chapter_content_full(book_url, chapter_index)?;
        Ok(())
    }
}

pub fn cache_download_progress(task_id: u64) -> LegadoResult<CacheDownloadTask> {
    ensure_restored();
    let task = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?
        .get(&task_id)
        .cloned();
    if let Some(t) = task {
        return Ok(snapshot(task_id, &t));
    }
    // 内存无任务时回读落库快照（终态/进程重启后仍可查进度）
    if let Ok(Some(json)) =
        with_database(|db| CacheRepository::new(db.connection()).get(&persist_key(task_id)))
    {
        if let Ok(row) = serde_json::from_str::<PersistedTask>(&json) {
            return Ok(CacheDownloadTask {
                task_id: row.task_id,
                book_url: row.book_url,
                status: row.status,
                total: row.total,
                completed: row.completed,
                failed: row.failed,
            });
        }
    }
    Ok(CacheDownloadTask {
        task_id,
        book_url: String::new(),
        status: "notFound".into(),
        total: 0,
        completed: 0,
        failed: 0,
    })
}

pub fn cache_download_cancel(task_id: u64) -> LegadoResult<bool> {
    ensure_restored();
    let task = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?
        .get(&task_id)
        .cloned();
    match task {
        Some(t) => {
            t.cancel.store(true, Ordering::SeqCst);
            // 批9b-2 审查回修：唤醒全局排队者（排队任务取消后不发起 HTTP）
            // 与窗口等待中的 worker（在途完成后停止）。
            DOWNLOAD_ADMISSION.notify();
            t.window_cv.notify_all();
            Ok(true)
        }
        None => Ok(false),
    }
}

pub fn cache_download_list() -> LegadoResult<Vec<CacheDownloadTask>> {
    ensure_restored();
    let map = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?;
    let mut ids: Vec<u64> = map.keys().copied().collect();
    if let Ok(db_ids) = with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        Ok(repo
            .get(PERSIST_INDEX)?
            .and_then(|s| serde_json::from_str::<Vec<u64>>(&s).ok())
            .unwrap_or_default())
    }) {
        for id in db_ids {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    ids.sort_unstable();
    let mut out = Vec::new();
    for id in ids {
        if let Some(t) = map.get(&id) {
            out.push(snapshot(id, t));
        } else if let Ok(Some(json)) =
            with_database(|db| CacheRepository::new(db.connection()).get(&persist_key(id)))
        {
            if let Ok(row) = serde_json::from_str::<PersistedTask>(&json) {
                out.push(CacheDownloadTask {
                    task_id: row.task_id,
                    book_url: row.book_url,
                    status: row.status,
                    total: row.total,
                    completed: row.completed,
                    failed: row.failed,
                });
            }
        }
    }
    Ok(out)
}

/// P2-29：该书当前在途下载章节 index 集合（API_CONTRACT §2.43.7，
/// 纯任务表读 + `ensure_restored` 落库恢复回读，**零写入**）
///
/// 在途章语义（批9b-2 起）：§2.43.3 每任务 N 个 worker 并发逐章下载
/// （N = `config:threadCount` 夹逼 1..=8），故每 `running` 任务的在途章
/// 集合 = 当前正在抓取的全部章节（1..=N 个；越出 `[start_chapter,
/// end_chapter]` 闭区间不收录，任务终态后不收录）。`threadCount=1` 时
/// 退化为至多一个在途章，与旧版语义一致；无活跃任务的书籍返回空集合。
/// 返回升序（0-based；同书多任务时各自去重排序）。
pub fn cache_download_running_chapters(book_url: &str) -> LegadoResult<Vec<i32>> {
    ensure_restored();
    let map = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?;
    let mut out: Vec<i32> = Vec::new();
    for task in map.values() {
        if task.book_url != book_url
            || !task.status.lock().map(|s| *s == "running").unwrap_or(false)
        {
            continue;
        }
        out.extend(
            in_flight_indices(task)
                .into_iter()
                .filter(|index| *index >= task.start_chapter && *index <= task.end_chapter),
        );
    }
    out.sort_unstable();
    out.dedup();
    Ok(out)
}

/// 本书批量下载**已失败**章节 index 集合（API_CONTRACT §2.43.8，
/// 纯任务表读 + `ensure_restored` 落库恢复回读，**零写入**）
///
/// 对齐参考版 `CacheBook.errorIndices(bookUrl)`（`CacheBook.kt:192-194`
/// 读 `stateStore.bookState(bookUrl)?.failedIndices`）的单书语义：
/// 合并该书全部任务（进行中/已完成/已取消）的失败集合
/// （`markFailed` 记入后任务终态仍保留，供目录页 ERROR 态展示与重试；
/// 成功/重试由 `run_download` 取章清空，见 `clear_failed_for_book`）。
/// 返回升序去重（0-based；无失败/未知书为空集合）。
pub fn cache_download_failed_chapters(book_url: &str) -> LegadoResult<Vec<i32>> {
    ensure_restored();
    let map = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?;
    let mut out: Vec<i32> = map
        .values()
        .filter(|t| t.book_url == book_url)
        .flat_map(|t| failed_indices(t))
        .collect();
    out.sort_unstable();
    out.dedup();
    Ok(out)
}

fn snapshot(task_id: u64, task: &TaskInner) -> CacheDownloadTask {
    let status = task
        .status
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| "running".to_string());
    CacheDownloadTask {
        task_id,
        book_url: task.book_url.clone(),
        status,
        total: task.total,
        completed: task.completed.load(Ordering::SeqCst),
        failed: task.failed.load(Ordering::SeqCst),
    }
}

fn set_status(task: &TaskInner, status: &str) {
    if let Ok(mut guard) = task.status.lock() {
        *guard = status.to_string();
    }
}

// ─── 测试 ──────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    // Repository trait：BookChapterRepository::insert / BookRepository::delete_by_url
    use legado_db::repository::Repository;

    /// 单章 panic 注入守卫（Drop 复位，panic 展开也安全）
    struct PanicChapterGuard;

    impl PanicChapterGuard {
        fn set(index: i32) -> Self {
            TEST_PANIC_CHAPTER.store(index, Ordering::SeqCst);
            Self
        }
    }

    impl Drop for PanicChapterGuard {
        fn drop(&mut self) {
            TEST_PANIC_CHAPTER.store(i32::MIN, Ordering::SeqCst);
        }
    }

    /// worker 循环 panic 注入守卫（Drop 复位）
    struct PanicWorkerLoopGuard;

    impl PanicWorkerLoopGuard {
        fn new() -> Self {
            TEST_PANIC_WORKER_LOOP.store(true, Ordering::SeqCst);
            Self
        }
    }

    impl Drop for PanicWorkerLoopGuard {
        fn drop(&mut self) {
            TEST_PANIC_WORKER_LOOP.store(false, Ordering::SeqCst);
        }
    }

    /// 未知任务：progress 返回 notFound，cancel 返回 false
    #[test]
    fn test_unknown_task() {
        let progress = cache_download_progress(u64::MAX).unwrap();
        assert_eq!(progress.status, "notFound");
        assert!(!cache_download_cancel(u64::MAX).unwrap());
    }

    /// 书籍不存在 / 无章节目录 → 报错
    #[test]
    fn test_start_validation() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        let err = cache_download_start("http://no-such-book.example.com", 0, 10).unwrap_err();
        assert!(err.to_string().contains("书籍不存在"));
    }

    /// 本地 TXT 书批量下载：抓取链路走本地解析（无网络依赖），
    /// 完成后缓存可读、进度与终态正确
    #[test]
    fn test_local_book_batch_download() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();

        // 构造本地 TXT 文件 + 入库书与章节目录
        let dir = std::env::temp_dir().join("legado_r7_test");
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("r7_batch.txt");
        std::fs::write(
            &txt_path,
            "第一章 开始\n\n这是第一章的正文内容。\n\n第二章 继续\n\n这是第二章的正文内容。\n\n第三章 结束\n\n这是第三章的正文内容。\n",
        )
        .unwrap();
        let book_url = txt_path.to_string_lossy().to_string();

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "批量缓存测试",
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        // 本地书章节目录由解析器懒加载入库（真实 start/end 偏移）
        let list = crate::api::reader::get_chapters(&book_url).unwrap();
        assert_eq!(list.total, 3, "TXT 应解析出 3 章");

        // 创建任务（全范围）
        let task_id = cache_download_start(&book_url, 0, 100).unwrap();
        let progress = cache_download_progress(task_id).unwrap();
        assert_eq!(progress.total, 3, "end 应按末章截断");

        // 等待 worker 完成（本地解析极快，轮询上限 5s）
        let final_progress = loop {
            let p = cache_download_progress(task_id).unwrap();
            if p.status != "running" {
                break p;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        assert_eq!(final_progress.status, "completed", "任务应完成");
        assert_eq!(final_progress.completed + final_progress.failed, 3);

        // 任务列表包含该任务
        let list = cache_download_list().unwrap();
        assert!(list.iter().any(|t| t.task_id == task_id));

        // 取消已终态任务幂等返回 true
        assert!(cache_download_cancel(task_id).unwrap());

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
        let _ = std::fs::remove_file(&txt_path);
    }

    /// [批39] 下载口径保持严格：目录「已缓存」显示为宽松（有正文即已缓存，
    /// 缺图不影响），下载链路不消费该显示集合——即使缓存行已存在（含缺图
    /// 正文），仍按章节重新抓取/解析并覆盖缓存。
    #[test]
    fn test_download_strict_even_when_loose_cache_exists() {
        use legado_core::cache_book::CachedChapter;
        use legado_db::CacheBookRepository;

        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();

        let dir = std::env::temp_dir().join("legado_r7_strict_test");
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("r7_strict.txt");
        std::fs::write(
            &txt_path,
            "第一章 开始

这是第一章的正文内容。

第二章 继续

这是第二章的正文内容。
",
        )
        .unwrap();
        let book_url = txt_path.to_string_lossy().to_string();

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "严格下载测试",
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();
        let chapters = crate::api::reader::get_chapters(&book_url).unwrap();
        assert_eq!(chapters.total, 2, "TXT 应解析出 2 章");
        let chapter_url = chapters.chapters[0].url.clone();

        // 预置「缺图」缓存行：正文引用未落盘图片 → 显示口径仍算已缓存
        let loose_content = "<img src=\"https://img.example.com/missing.jpg\">";
        with_database(|db| {
            CacheBookRepository::new(db.connection()).insert(&CachedChapter {
                id: 0,
                book_url: book_url.clone(),
                chapter_index: 0,
                chapter_title: "第一章".to_string(),
                chapter_url: chapter_url.clone(),
                content: loose_content.to_string(),
                cached_at: 0,
                size_bytes: loose_content.len() as i64,
            })?;
            Ok(())
        })
        .unwrap();
        let display = crate::api::cache_api::list_cached_chapter_urls(&book_url).unwrap();
        assert!(
            display.contains(&chapter_url),
            "显示口径宽松：有正文（含缺图）即已缓存"
        );

        // 下载链路严格：不因显示集合命中而跳过，仍重新解析并覆盖缓存
        download_one(&book_url, 0).expect("本地解析下载应成功");
        let after = crate::api::cache_api::get_chapter_cache(&book_url, 0).unwrap();
        assert_ne!(after, loose_content, "严格下载应覆盖缺图缓存行");
        assert!(
            after.contains("这是第一章的正文内容"),
            "下载后应为真实正文，实际: {after}"
        );

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            CacheBookRepository::new(conn).delete_by_book(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
        let _ = std::fs::remove_file(&txt_path);
    }

    /// [批39 审查回修 P3-11 登记] 网络章「缺图」不会重抓（与参考版严格口径
    /// 的已知差异，成本高，本批登记不改）：
    ///
    /// - 参考版 `BookHelp.isChapterCacheComplete` 对批量下载用**严格**口径
    ///   （正文 + 章节内图片均已缓存），缺图章视为未完成 → 重抓；
    /// - 本仓 `download_one` 的在线书分支复用
    ///   [`crate::api::reader::get_chapter_content_full`]，该链是 **cache-first**
    ///   （正文非空即返回），因此「有正文但图片未落盘」的缓存行不会被重抓；
    /// - 要补齐严格口径，需要（a）解析缓存正文中的 `<img src>`（含相对 URL
    ///   解析）并逐张校验图片磁盘缓存、（b）绕过正文缓存重新抓取，且需同步
    ///   补「下载时缓存图片」的能力，否则每次批量下载都会对相对图片 URL 的
    ///   章节重复联网 —— 属功能级改动，超出本批审查回修授权。
    ///
    /// 本用例**锁定当前行为**（不发起章节请求、缓存行原样保留），并作为差异
    /// 登记；参考版严格口径落地后本用例应改为断言重抓（红 → 绿）。
    #[test]
    fn test_network_chapter_missing_image_is_not_refetched_registered_gap() {
        use legado_core::models::BookChapter;
        use legado_db::CacheBookRepository;
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::AtomicUsize;

        // 网络抓取会经 begin_book_flow（全局 store）→ 必须先持 store 锁
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();

        let chapter_hits = Arc::new(AtomicUsize::new(0));
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
        let port = listener.local_addr().expect("取端口").port();
        let hits = Arc::clone(&chapter_hits);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut byte) {
                        Ok(1) => head.push(byte[0]),
                        _ => break,
                    }
                    if head.len() > 16 * 1024 {
                        break;
                    }
                }
                let head = String::from_utf8_lossy(&head);
                let path = head
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .split('?')
                    .next()
                    .unwrap_or("/")
                    .to_string();
                let (status, body) = if path.starts_with("/ch/") {
                    hits.fetch_add(1, Ordering::SeqCst);
                    (
                        200,
                        "<html><body><div class=\"content\">网络正文A\
                         <img src=\"http://127.0.0.1/not-cached.jpg\"/></div></body></html>"
                            .to_string(),
                    )
                } else {
                    (404, "missing".to_string())
                };
                let reason = if status < 400 { "OK" } else { "Not Found" };
                let resp = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            }
        });

        let source_url = format!("http://127.0.0.1:{port}/src/p311");
        let source_json = format!(
            r#"{{"bookSourceUrl":"{source_url}","bookSourceName":"P3-11 缺图源","ruleContent":{{"content":"class.content@html"}}}}"#
        );
        crate::api::source::add_source(&source_json).expect("书源写入");

        let book_url = format!("http://127.0.0.1:{port}/book/p311");
        let chapter_url = format!("http://127.0.0.1:{port}/ch/p311");
        crate::api::bookshelf::add_book(
            &serde_json::json!({
                "bookUrl": book_url,
                "name": "P3-11 网络缺图书",
                "author": "P3-11",
                "origin": source_url,
            })
            .to_string(),
        )
        .expect("书行写入");
        with_database(|db| {
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                book_url: book_url.clone(),
                index: 0,
                title: "第一章".to_string(),
                url: chapter_url.clone(),
                base_url: chapter_url.clone(),
                ..BookChapter::default()
            })
        })
        .expect("章节行写入");

        // 预置「缺图」缓存行：正文引用未落盘图片 → 显示口径仍算已缓存
        let loose_content = "<img src=\"http://127.0.0.1/not-cached.jpg\"/>";
        assert!(crate::api::cache_api::save_chapter_content(
            &book_url,
            0,
            "第一章",
            loose_content,
            &chapter_url,
        )
        .unwrap());
        let display = crate::api::cache_api::list_cached_chapter_urls(&book_url).unwrap();
        assert!(
            display.contains(&chapter_url),
            "显示口径宽松：有正文（含缺图）即已缓存"
        );

        // 登记项（当前行为）：cache-first 正文链返回已缓存内容 → 不发起
        // 章节请求，缺图缓存行原样保留（参考版严格口径下应重抓）
        download_one(&book_url, 0).expect("网络章下载应成功（命中缓存直接返回）");
        assert_eq!(
            chapter_hits.load(Ordering::SeqCst),
            0,
            "当前实现为 cache-first：缺图缓存行不会触发章节请求（登记差异）"
        );
        let after = crate::api::cache_api::get_chapter_cache(&book_url, 0).unwrap();
        assert_eq!(
            after, loose_content,
            "当前实现保留原缓存行（严格口径落地后应被服务器正文覆盖）"
        );

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            CacheBookRepository::new(conn).delete_by_book(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
    }

    /// [批18d P3] 相对可迁移标识（`books/rel_cache.txt`）批量缓存必须经
    /// resolver 还原真实文件，否则本地书每章读取失败、任务以 failed 收尾。
    #[test]
    fn test_local_book_relative_identifier_batch_download() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let base =
            std::env::temp_dir().join(format!("legado_cache_rel_{}_{}", std::process::id(), n));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        std::fs::write(
            books.join("rel_cache.txt"),
            "第一章 开始\n\n这是第一章的正文内容。\n\n第二章 继续\n\n这是第二章的正文内容。\n",
        )
        .unwrap();

        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        let prev_db_path = crate::db_state::current_db_path();
        // resolver 以 DB 路径的父目录为 Documents 基
        crate::db_state::record_db_path(base.join("legado.db").to_str().unwrap());
        crate::api::cache_api::clear_cache().unwrap();

        let book_url = "books/rel_cache.txt";
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "相对路径缓存",
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        let list = crate::api::reader::get_chapters(book_url).unwrap();
        assert_eq!(list.total, 2, "TXT 应解析出 2 章");

        let task_id = cache_download_start(book_url, 0, 100).unwrap();
        let final_progress = loop {
            let p = cache_download_progress(task_id).unwrap();
            if p.status != "running" {
                break p;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        assert_eq!(final_progress.status, "completed", "相对标识任务应完成");
        assert_eq!(final_progress.failed, 0, "相对标识不应出现读取失败");
        assert_eq!(final_progress.completed, 2);

        // 清理共享测试库、缓存、DB 路径与临时目录
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(book_url)?;
            BookRepository::new(conn).delete_by_url(book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
        crate::db_state::record_db_path(prev_db_path.as_deref().unwrap_or(""));
        let _ = std::fs::remove_dir_all(&base);
    }

    /// 取消机制：创建后立即取消，任务不应跑完全量（对照 CHECK_CANCELLED 语义）
    #[test]
    fn test_cancel_flag_set() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        // 批9b-2：单 worker 以保持「创建后立即取消」的确定性（并发下本地
        // 解析极快，多个 worker 可能在取消到达前完成更多章）；并发取消
        // 语义由 `test_download_cancel_with_concurrency_stops_after_in_flight`
        // 用回环服务器覆盖。
        crate::api::config_api::set_config("threadCount", "1").unwrap();
        // 复用 test_local_book_batch_download 之外的独立书
        let dir = std::env::temp_dir().join("legado_r7_cancel_test");
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("r7_cancel.txt");
        let mut content = String::new();
        for i in 0..20 {
            // 正文行不以「第X章」开头，避免被章节切分正则误判为标题行
            content.push_str(&format!("第{i}章 标题\n\n这是第{i}章的正文。\n\n"));
        }
        std::fs::write(&txt_path, &content).unwrap();
        let book_url = txt_path.to_string_lossy().to_string();

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "取消测试",
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        // 本地书章节目录由解析器懒加载入库
        let list = crate::api::reader::get_chapters(&book_url).unwrap();
        assert_eq!(list.total, 20, "TXT 应解析出 20 章");

        let task_id = cache_download_start(&book_url, 0, 19).unwrap();
        // 立即取消
        assert!(cache_download_cancel(task_id).unwrap());

        // 等待终态
        let final_progress = loop {
            let p = cache_download_progress(task_id).unwrap();
            if p.status != "running" {
                break p;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        assert_eq!(
            final_progress.status, "cancelled",
            "取消后任务应进入 cancelled 终态"
        );
        assert!(
            final_progress.completed + final_progress.failed < 20,
            "取消后不应跑完全量章节"
        );

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        let _ = std::fs::remove_file(&txt_path);
    }

    /// P2-29：在途章集合 = 运行中任务的 in-flight 章节（区间内）；
    /// 终态后清空；无关书恒空；零写入（只读）
    #[test]
    fn test_running_chapters() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();

        // 200 章本地 TXT：保证 worker 运行窗口足够长，可稳定观测在途态
        let dir = std::env::temp_dir().join("legado_p229_running_test");
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("p229_running.txt");
        let mut content = String::new();
        for i in 0..200 {
            content.push_str(&format!("第{i}章 标题\n\n这是第{i}章的正文。\n\n"));
        }
        std::fs::write(&txt_path, &content).unwrap();
        let book_url = txt_path.to_string_lossy().to_string();

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "在途章查询测试",
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        let list = crate::api::reader::get_chapters(&book_url).unwrap();
        assert_eq!(list.total, 200, "TXT 应解析出 200 章");

        let task_id = cache_download_start(&book_url, 0, 199).unwrap();

        // 运行中：在途章集合非空且恒在 [0, 199] 内
        let mut seen = 0usize;
        loop {
            let running = cache_download_running_chapters(&book_url).unwrap();
            if !running.is_empty() {
                assert!(
                    running.iter().all(|&i| (0..=199).contains(&i)),
                    "在途章应位于任务闭区间内: {running:?}"
                );
                seen += 1;
            }
            let p = cache_download_progress(task_id).unwrap();
            if p.status != "running" {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(seen > 0, "任务运行期间应观测到非空在途章集合");

        // 终态：在途章集合清空（in-flight 清空 / 状态非 running）
        assert!(
            cache_download_running_chapters(&book_url)
                .unwrap()
                .is_empty(),
            "任务终态后不应再有在途章"
        );
        // 无关书籍恒空
        assert!(
            cache_download_running_chapters("http://unrelated.example.com/book")
                .unwrap()
                .is_empty(),
            "无活跃任务的书籍应返回空集合"
        );

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
        let _ = std::fs::remove_file(&txt_path);
    }

    /// 轮询等待任务进入终态（上限 5s）
    fn wait_terminal(task_id: u64) -> CacheDownloadTask {
        for _ in 0..200 {
            let p = cache_download_progress(task_id).unwrap();
            if p.status != "running" {
                return p;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        panic!("任务超时未进入终态");
    }

    /// 构造本地 TXT 书并解析章节目录（返回 book_url 与入库章节）
    fn make_local_txt_book(
        dir_name: &str,
        file_name: &str,
        book_name: &str,
        chapter_count: usize,
    ) -> (String, Vec<legado_core::models::BookChapter>) {
        let dir = std::env::temp_dir().join(dir_name);
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join(file_name);
        let mut content = String::new();
        for i in 0..chapter_count {
            content.push_str(&format!("第{i}章 标题\n\n这是第{i}章的正文。\n\n"));
        }
        std::fs::write(&txt_path, &content).unwrap();
        let book_url = txt_path.to_string_lossy().to_string();
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": book_name,
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();
        let chapters = crate::api::reader::get_chapters(&book_url).unwrap();
        assert_eq!(chapters.total, chapter_count as i32, "TXT 章节数应匹配");
        let rows = with_database(|db| {
            BookChapterRepository::new(db.connection()).find_by_book_url(&book_url)
        })
        .unwrap();
        (book_url, rows)
    }

    /// §2.43.8：失败记入集合（成功不入）、按书查询升序去重、重试/任务启动
    /// 取章清空（跨任务）、无任务书空集合、重复查询纯读
    #[test]
    fn test_failed_chapters_recorded_and_cleared_on_retry() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();

        let (book_url, chapters) = make_local_txt_book(
            "legado_p2438_failed_test",
            "p2438_failed.txt",
            "失败章查询测试",
            3,
        );

        // 删除第 0 章行 → 该章抓取必然失败（本地章节不存在），其余章成功。
        // 注意：删后 count=2，任务 0..2 的 end 会按末章截断为 1，
        // 恰好覆盖「缺失的第 0 章 + 正常第 1 章」
        let missing: Vec<_> = chapters.iter().filter(|c| c.index == 0).cloned().collect();
        assert_eq!(missing.len(), 1);
        // [B-7] delete_by_book_url 事务外为 no-op，须包 unchecked_transaction
        with_database(|db| {
            let conn = db.connection();
            let repo = BookChapterRepository::new(conn);
            let tx = conn
                .unchecked_transaction()
                .map_err(|e| legado_core::LegadoError::Database(format!("开启事务失败: {e}")))?;
            repo.delete_by_book_url(&book_url)?;
            let kept: Vec<_> = chapters.into_iter().filter(|c| c.index != 0).collect();
            repo.insert_batch_no_tx(&kept)?;
            tx.commit()
                .map_err(|e| legado_core::LegadoError::Database(format!("提交事务失败: {e}")))?;
            Ok(())
        })
        .unwrap();

        let task_id = cache_download_start(&book_url, 0, 2).unwrap();
        let final_progress = wait_terminal(task_id);
        assert_eq!(final_progress.status, "completed");
        assert_eq!(final_progress.completed, 1, "一章应成功（第 1 章）");
        assert_eq!(final_progress.failed, 1, "一章应失败（第 0 章）");

        // 失败记入集合：仅第 0 章（成功章不入集）；重复查询结果恒定（纯读）
        assert_eq!(
            cache_download_failed_chapters(&book_url).unwrap(),
            vec![0],
            "失败章集合应为升序 [0]"
        );
        assert_eq!(cache_download_failed_chapters(&book_url).unwrap(), vec![0]);
        // 无任务书籍恒空
        assert!(
            cache_download_failed_chapters("http://no-task-book.example.com")
                .unwrap()
                .is_empty(),
            "无任务书籍应返回空集合"
        );

        // 恢复第 0 章行 → 新任务重试该章：取章即清失败标记（任务启动清空/
        // 重试移除，跨任务清除），成功后集合为空
        with_database(|db| BookChapterRepository::new(db.connection()).insert_batch(&missing))
            .unwrap();
        let task2 = cache_download_start(&book_url, 0, 0).unwrap();
        let p2 = wait_terminal(task2);
        assert_ne!(task2, task_id, "终态任务不应复用，应新建任务");
        assert_eq!(p2.status, "completed");
        assert_eq!(p2.failed, 0);
        assert!(
            cache_download_failed_chapters(&book_url)
                .unwrap()
                .is_empty(),
            "重试成功后失败集合应清空（跨任务清除）"
        );

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
        let _ = std::fs::remove_file(&book_url);
    }

    /// §2.43.8：持久化往返（集合升序序列化）、旧快照无字段可读（serde
    /// default）、恢复回读（task_from_persisted）一并恢复集合、查询零写入
    #[test]
    fn test_failed_chapters_persistence_roundtrip_and_legacy_snapshot() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();

        // 旧快照（契约冻结前落库，无 failedChapters 字段）可读 → 空集合
        let legacy_json = r#"{"taskId":99991,"bookUrl":"http://legacy-book.example.com","startChapter":0,"endChapter":2,"total":3,"completed":1,"failed":1,"nextIndex":2,"status":"completed"}"#;
        let legacy_row: PersistedTask = serde_json::from_str(legacy_json).unwrap();
        assert!(
            legacy_row.failed_chapters.is_empty(),
            "旧快照无 failedChapters 字段应读为空集合"
        );
        let legacy_task = task_from_persisted(legacy_row);
        assert!(
            failed_indices(&legacy_task).is_empty(),
            "恢复回读旧快照 → 空失败集合"
        );

        // 新快照往返：集合升序序列化，恢复回读一并恢复
        let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);
        let task = Arc::new(TaskInner {
            book_url: "http://persist-roundtrip.example.com".to_string(),
            start_chapter: 0,
            end_chapter: 5,
            total: 6,
            completed: AtomicI32::new(4),
            failed: AtomicI32::new(2),
            next_dispatch: AtomicI32::new(6),
            finished_prefix: AtomicI32::new(6),
            cancel: AtomicBool::new(false),
            status: Mutex::new("completed".to_string()),
            failed_chapters: Mutex::new([5, 3].iter().copied().collect()),
            finished_ahead: Mutex::new(HashSet::new()),
            in_flight: Mutex::new(HashSet::new()),
            state_lock: Mutex::new(()),
            window_lock: Mutex::new(()),
            window_cv: Condvar::new(),
            worker_panicked: AtomicBool::new(false),
        });
        persist_snapshot(task_id, &task);
        let json =
            with_database(|db| CacheRepository::new(db.connection()).get(&persist_key(task_id)))
                .unwrap()
                .expect("快照应落库");
        let row: PersistedTask = serde_json::from_str(&json).unwrap();
        assert_eq!(row.failed_chapters, vec![3, 5], "失败集合应按升序序列化");
        let restored = task_from_persisted(row);
        assert_eq!(
            failed_indices(&restored),
            vec![3, 5],
            "恢复回读应一并恢复失败集合"
        );

        // 查询零写入：查询前后该任务落库快照逐字不变
        let before = json;
        assert!(
            cache_download_failed_chapters("http://no-task-book-2.example.com")
                .unwrap()
                .is_empty()
        );
        let after =
            with_database(|db| CacheRepository::new(db.connection()).get(&persist_key(task_id)))
                .unwrap()
                .unwrap();
        assert_eq!(after, before, "查询不得改写任务快照（零写入）");
    }

    // ─── 批9b-2：下载并发受 config:threadCount 控制 ─────────────────────

    /// 回环章节服务器：统计每章请求次数 + 最大在途请求数
    struct ChapterServer {
        port: u16,
        hits: Arc<Mutex<HashMap<i32, usize>>>,
        max_active: Arc<std::sync::atomic::AtomicUsize>,
    }

    /// 启动回环章节服务器：`/ch/{index}` 返回含 index 的正文（延迟 delay_ms）
    fn start_chapter_server(delay_ms: u64) -> ChapterServer {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::AtomicUsize;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
        let port = listener.local_addr().expect("取端口").port();
        let hits: Arc<Mutex<HashMap<i32, usize>>> = Arc::new(Mutex::new(HashMap::new()));
        let max_active = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));

        let hits_srv = Arc::clone(&hits);
        let max_srv = Arc::clone(&max_active);
        let active_srv = Arc::clone(&active);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let hits = Arc::clone(&hits_srv);
                let max_active = Arc::clone(&max_srv);
                let active = Arc::clone(&active_srv);
                // 每连接独立线程，避免 accept 循环把请求串行化
                std::thread::spawn(move || {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        match stream.read(&mut byte) {
                            Ok(1) => head.push(byte[0]),
                            _ => break,
                        }
                        if head.len() > 16 * 1024 {
                            break;
                        }
                    }
                    let path = String::from_utf8_lossy(&head)
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or("/")
                        .split('?')
                        .next()
                        .unwrap_or("/")
                        .to_string();
                    let index = path.rsplit('/').next().and_then(|s| s.parse::<i32>().ok());
                    let (status, body) = match index {
                        Some(i) => {
                            *hits.lock().unwrap().entry(i).or_insert(0) += 1;
                            let cur = active.fetch_add(1, Ordering::SeqCst) + 1;
                            max_active.fetch_max(cur, Ordering::SeqCst);
                            std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                            active.fetch_sub(1, Ordering::SeqCst);
                            (
                                "200 OK",
                                format!(
                                    "<html><body><div class=\"content\">正文{i}</div></body></html>"
                                ),
                            )
                        }
                        None => ("404 Not Found", "missing".to_string()),
                    };
                    let resp = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(resp.as_bytes());
                    let _ = stream.flush();
                });
            }
        });

        ChapterServer {
            port,
            hits,
            max_active,
        }
    }

    /// 写入在线书 + 章节目录（章节 URL = 回环服务器 `/ch/{index}`）
    fn setup_online_book(port: u16, chapter_count: i32) -> (String, String) {
        use legado_core::models::BookChapter;

        let source_url = format!("http://127.0.0.1:{port}/src");
        crate::api::source::add_source(
            &serde_json::json!({
                "bookSourceUrl": source_url,
                "bookSourceName": "下载并发源",
                "ruleContent": {"content": "class.content@text"},
            })
            .to_string(),
        )
        .expect("书源写入");
        let book_url = format!("http://127.0.0.1:{port}/book");
        crate::api::bookshelf::add_book(
            &serde_json::json!({
                "bookUrl": book_url,
                "name": "下载并发测试书",
                "author": "测试",
                "origin": source_url,
            })
            .to_string(),
        )
        .expect("书籍写入");
        let chapters: Vec<BookChapter> = (0..chapter_count)
            .map(|index| {
                let url = format!("http://127.0.0.1:{port}/ch/{index}");
                BookChapter {
                    url: url.clone(),
                    title: format!("第{index}章"),
                    base_url: url,
                    book_url: book_url.clone(),
                    index,
                    ..BookChapter::default()
                }
            })
            .collect();
        with_database(|db| BookChapterRepository::new(db.connection()).insert_batch(&chapters))
            .expect("章节写入");
        (book_url, source_url)
    }

    /// 清理在线书夹具（章节/缓存/书行/书源）
    fn cleanup_online_book(book_url: &str, source_url: &str) {
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(book_url)?;
            legado_db::CacheBookRepository::new(conn).delete_by_book(book_url)?;
            BookRepository::new(conn).delete_by_url(book_url)
        })
        .unwrap();
        let _ = crate::api::source::delete_source(source_url);
        crate::api::cache_api::clear_cache().unwrap();
    }

    /// 多书回环服务器（批9b-2 审查回修：全局准入/慢首章）
    ///
    /// 路径约定 `/{book}/ch/{index}`；统计全局最大在途请求数、跨书重叠、
    /// 请求到达序列与慢首章（index 0）响应完成时刻。
    struct MultiBookServer {
        port: u16,
        /// (book, chapter) → 请求次数
        hits: Arc<Mutex<HashMap<(String, i32), usize>>>,
        /// 请求到达顺序（book, chapter）
        sequence: Arc<Mutex<Vec<(String, i32)>>>,
        /// 全局最大在途请求数（所有书籍合计，应 ≤8）
        max_active: Arc<std::sync::atomic::AtomicUsize>,
        /// 是否观测到两本书同时在途（应恒 false）
        overlap: Arc<AtomicBool>,
        /// 慢首章（index 0）服务器处理完成（sleep 结束）
        first_chapter_served: Arc<AtomicBool>,
    }

    fn start_multi_book_server(
        delay_ms: u64,
        first_chapter_delay_ms: u64,
        chapters_per_book: i32,
    ) -> MultiBookServer {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::AtomicUsize;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
        let port = listener.local_addr().expect("取端口").port();
        let hits: Arc<Mutex<HashMap<(String, i32), usize>>> = Arc::new(Mutex::new(HashMap::new()));
        let sequence: Arc<Mutex<Vec<(String, i32)>>> = Arc::new(Mutex::new(Vec::new()));
        let max_active = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let overlap = Arc::new(AtomicBool::new(false));
        let first_chapter_served = Arc::new(AtomicBool::new(false));

        let hits_srv = Arc::clone(&hits);
        let seq_srv = Arc::clone(&sequence);
        let max_srv = Arc::clone(&max_active);
        let active_srv = Arc::clone(&active);
        let overlap_srv = Arc::clone(&overlap);
        let served_srv = Arc::clone(&first_chapter_served);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let hits = Arc::clone(&hits_srv);
                let sequence = Arc::clone(&seq_srv);
                let max_active = Arc::clone(&max_srv);
                let active = Arc::clone(&active_srv);
                let overlap = Arc::clone(&overlap_srv);
                let first_chapter_served = Arc::clone(&served_srv);
                std::thread::spawn(move || {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        match stream.read(&mut byte) {
                            Ok(1) => head.push(byte[0]),
                            _ => break,
                        }
                        if head.len() > 16 * 1024 {
                            break;
                        }
                    }
                    let path = String::from_utf8_lossy(&head)
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or("/")
                        .split('?')
                        .next()
                        .unwrap_or("/")
                        .to_string();
                    let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
                    let parsed = match parts.as_slice() {
                        [book, "ch", index] => {
                            index.parse::<i32>().ok().map(|i| (book.to_string(), i))
                        }
                        _ => None,
                    };
                    let (status, body) = match parsed {
                        Some((book, index)) => {
                            let mut hits = hits.lock().unwrap();
                            // 跨书重叠：另一本书已开始但尚未收齐请求（按书聚合计数，
                            // 不能按逐章条目判断）
                            let mut totals: HashMap<&str, usize> = HashMap::new();
                            for ((other, _), count) in hits.iter() {
                                *totals.entry(other.as_str()).or_default() += count;
                            }
                            let other_incomplete = totals.iter().any(|(other, count)| {
                                *other != book && *count > 0 && *count < chapters_per_book as usize
                            });
                            if other_incomplete {
                                overlap.store(true, Ordering::SeqCst);
                            }
                            *hits.entry((book.clone(), index)).or_insert(0) += 1;
                            let cur = active.fetch_add(1, Ordering::SeqCst) + 1;
                            max_active.fetch_max(cur, Ordering::SeqCst);
                            sequence.lock().unwrap().push((book.clone(), index));
                            drop(hits);

                            let delay = if index == 0 {
                                first_chapter_delay_ms
                            } else {
                                delay_ms
                            };
                            if delay > 0 {
                                std::thread::sleep(std::time::Duration::from_millis(delay));
                            }
                            active.fetch_sub(1, Ordering::SeqCst);
                            if index == 0 {
                                first_chapter_served.store(true, Ordering::SeqCst);
                            }
                            (
                                "200 OK",
                                format!(
                                    "<html><body><div class=\"content\">正文{book}-{index}</div></body></html>"
                                ),
                            )
                        }
                        None => ("404 Not Found", "missing".to_string()),
                    };
                    let resp = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(resp.as_bytes());
                    let _ = stream.flush();
                });
            }
        });

        MultiBookServer {
            port,
            hits,
            sequence,
            max_active,
            overlap,
            first_chapter_served,
        }
    }

    /// 写入多本在线书（共享一个书源；章节 URL = `/{book}/ch/{index}`）
    fn setup_multi_book(
        port: u16,
        book_count: usize,
        chapters_per_book: i32,
    ) -> (Vec<String>, String) {
        use legado_core::models::BookChapter;

        let source_url = format!("http://127.0.0.1:{port}/src");
        crate::api::source::add_source(
            &serde_json::json!({
                "bookSourceUrl": source_url,
                "bookSourceName": "下载准入源",
                "ruleContent": {"content": "class.content@text"},
            })
            .to_string(),
        )
        .expect("书源写入");

        let mut books = Vec::new();
        for k in 0..book_count {
            let book_url = format!("http://127.0.0.1:{port}/book{k}");
            crate::api::bookshelf::add_book(
                &serde_json::json!({
                    "bookUrl": book_url,
                    "name": format!("下载准入书{k}"),
                    "author": "测试",
                    "origin": source_url,
                })
                .to_string(),
            )
            .expect("书籍写入");
            let chapters: Vec<BookChapter> = (0..chapters_per_book)
                .map(|index| {
                    let url = format!("http://127.0.0.1:{port}/book{k}/ch/{index}");
                    BookChapter {
                        url: url.clone(),
                        title: format!("第{index}章"),
                        base_url: url,
                        book_url: book_url.clone(),
                        index,
                        ..BookChapter::default()
                    }
                })
                .collect();
            with_database(|db| BookChapterRepository::new(db.connection()).insert_batch(&chapters))
                .expect("章节写入");
            books.push(book_url);
        }
        (books, source_url)
    }

    fn cleanup_multi_book(books: &[String], source_url: &str) {
        for book in books {
            with_database(|db| {
                let conn = db.connection();
                BookChapterRepository::new(conn).delete_by_book_url(book)?;
                legado_db::CacheBookRepository::new(conn).delete_by_book(book)?;
                BookRepository::new(conn).delete_by_url(book)
            })
            .unwrap();
        }
        let _ = crate::api::source::delete_source(source_url);
        crate::api::cache_api::clear_cache().unwrap();
    }

    /// 下载并发解析：config:threadCount 夹逼 1..=8（缺省 16 → 8）
    #[test]
    fn test_download_concurrency_clamps_thread_count() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();

        assert_eq!(
            download_concurrency(),
            MAX_DOWNLOAD_CONCURRENCY,
            "未配置时缺省 16 被下载上限 8 夹逼"
        );
        crate::api::config_api::set_config("threadCount", "1").unwrap();
        assert_eq!(download_concurrency(), 1);
        crate::api::config_api::set_config("threadCount", "5").unwrap();
        assert_eq!(download_concurrency(), 5);
        crate::api::config_api::set_config("threadCount", "99").unwrap();
        assert_eq!(download_concurrency(), MAX_DOWNLOAD_CONCURRENCY);
        crate::api::config_api::set_config("threadCount", "-3").unwrap();
        assert_eq!(download_concurrency(), 1);
        crate::api::config_api::set_config("threadCount", "").unwrap();
        assert_eq!(
            download_concurrency(),
            MAX_DOWNLOAD_CONCURRENCY,
            "缺省 16 被下载上限 8 夹逼"
        );
        crate::api::config_api::set_config("threadCount", "abc").unwrap();
        assert_eq!(download_concurrency(), MAX_DOWNLOAD_CONCURRENCY);
    }

    /// 批9b-2：N worker 并发——最大在途 = threadCount、每章恰好下载一次、
    /// 进度/终态/逐章缓存内容正确
    #[test]
    fn test_download_concurrency_max_in_flight_order_and_no_duplicate() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "2").unwrap();

        let server = start_chapter_server(120);
        let (book_url, source_url) = setup_online_book(server.port, 6);

        let task_id = cache_download_start(&book_url, 0, 5).unwrap();
        let progress = wait_terminal(task_id);

        assert_eq!(progress.status, "completed");
        assert_eq!(progress.completed, 6);
        assert_eq!(progress.failed, 0);
        assert_eq!(
            server.max_active.load(Ordering::SeqCst),
            2,
            "最大在途下载数应等于 config:threadCount=2"
        );

        let hits = server.hits.lock().unwrap().clone();
        for index in 0..6 {
            assert_eq!(
                hits.get(&index),
                Some(&1),
                "章节 {index} 应恰好下载一次（无重复）: {hits:?}"
            );
            let cached = crate::api::cache_api::get_chapter_cache(&book_url, index).unwrap();
            assert!(
                cached.contains(&format!("正文{index}")),
                "章节 {index} 缓存内容应与章节号对应（无串章）: {cached}"
            );
        }

        // 快照自洽：前缀推进到末章之后、无散章残留
        let json =
            with_database(|db| CacheRepository::new(db.connection()).get(&persist_key(task_id)))
                .unwrap()
                .expect("终态快照应落库");
        let row: PersistedTask = serde_json::from_str(&json).unwrap();
        assert_eq!(row.next_index, 6, "连续完成前缀应越过末章");
        assert!(
            row.finished_chapters.is_empty(),
            "前缀已推进，finishedChapters 应为空"
        );

        cleanup_online_book(&book_url, &source_url);
    }

    /// P0-1 回归（单 worker 确定性复现）：快照 `nextIndex=0`、
    /// `finishedChapters=[1]`、`completed=1`；worker 完成 0 后前缀越过 1，
    /// 随后 claim 到 1 时必须跳过——不得重下/重复计数。
    /// 修复前：completed 超 total（4/3）且终态 failed、章 1 被重复请求。
    #[test]
    fn test_download_resume_p0_prefix_advance_must_not_redownload_finished_ahead() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "1").unwrap();

        let server = start_chapter_server(10);
        let (book_url, source_url) = setup_online_book(server.port, 3);

        // 快照：章 1 已完成；章 0、2 未完成
        let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);
        let task = task_from_persisted(PersistedTask {
            task_id,
            book_url: book_url.clone(),
            start_chapter: 0,
            end_chapter: 2,
            total: 3,
            completed: 1,
            failed: 0,
            next_index: 0,
            status: "running".to_string(),
            failed_chapters: Vec::new(),
            finished_chapters: vec![1],
        });
        TASKS.lock().unwrap().insert(task_id, Arc::clone(&task));

        run_download(task_id, task);

        let progress = cache_download_progress(task_id).unwrap();
        assert_eq!(progress.status, "completed", "不得因重复计数判 failed");
        assert_eq!(progress.completed, 3, "completed 不得超 total");
        assert_eq!(progress.failed, 0);
        assert_eq!(progress.completed + progress.failed, progress.total);

        let hits = server.hits.lock().unwrap().clone();
        assert_eq!(hits.get(&0), Some(&1), "缺口章 0 应下载一次");
        assert_eq!(hits.get(&2), Some(&1), "缺口章 2 应下载一次");
        assert!(!hits.contains_key(&1), "快照已完成章 1 不得重下: {hits:?}");

        TASKS.lock().unwrap().remove(&task_id);
        cleanup_online_book(&book_url, &source_url);
    }

    /// P0-1 竞态保护（2 worker）：前缀推进与 ahead 移除交错时，
    /// 已完成的散章仍不得被重新派发/重复计数
    #[test]
    fn test_download_resume_two_workers_skip_finished_ahead_race() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "2").unwrap();

        let server = start_chapter_server(15);
        let (book_url, source_url) = setup_online_book(server.port, 6);

        // 快照：章 1、3 已完成（前缀 0）；completed 已含这 2 章
        let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);
        let task = task_from_persisted(PersistedTask {
            task_id,
            book_url: book_url.clone(),
            start_chapter: 0,
            end_chapter: 5,
            total: 6,
            completed: 2,
            failed: 0,
            next_index: 0,
            status: "running".to_string(),
            failed_chapters: Vec::new(),
            finished_chapters: vec![1, 3],
        });
        TASKS.lock().unwrap().insert(task_id, Arc::clone(&task));

        run_download(task_id, task);

        let progress = cache_download_progress(task_id).unwrap();
        assert_eq!(progress.status, "completed");
        assert_eq!(progress.completed, 6, "2 已恢复 + 4 新下载");
        assert_eq!(progress.failed, 0);
        assert_eq!(progress.completed + progress.failed, progress.total);

        let hits = server.hits.lock().unwrap().clone();
        for index in [0, 2, 4, 5] {
            assert_eq!(hits.get(&index), Some(&1), "缺口章 {index} 应下载一次");
        }
        for done in [1, 3] {
            assert!(
                !hits.contains_key(&done),
                "已完成章 {done} 不得重下: {hits:?}"
            );
        }

        TASKS.lock().unwrap().remove(&task_id);
        cleanup_online_book(&book_url, &source_url);
    }

    /// 批9b-2：并发任务取消——不再派发新章，在途章完成后停止；
    /// 终态 cancelled 且未跑完全量
    #[test]
    fn test_download_cancel_with_concurrency_stops_after_in_flight() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "2").unwrap();

        let server = start_chapter_server(250);
        let (book_url, source_url) = setup_online_book(server.port, 10);

        let task_id = cache_download_start(&book_url, 0, 9).unwrap();
        assert!(cache_download_cancel(task_id).unwrap());
        let progress = wait_terminal(task_id);

        assert_eq!(progress.status, "cancelled");
        assert!(
            progress.completed + progress.failed < 10,
            "取消后不得跑完全量: {progress:?}"
        );
        assert!(
            cache_download_running_chapters(&book_url)
                .unwrap()
                .is_empty(),
            "终态后不应再有在途章"
        );

        cleanup_online_book(&book_url, &source_url);
    }

    // ─── 批9b-2 审查回修：全局准入 / 有界快照 / panic 隔离 ───────────────

    /// 恢复防御：历史/异常超窗快照的 `finishedChapters` 只保留窗口内条目，
    /// 窗口外条目同步扣减计数（该章重下，幂等），集合长度 ≤32
    #[test]
    fn test_task_from_persisted_trims_oversized_finished_ahead() {
        let row = PersistedTask {
            task_id: 1,
            book_url: "http://trim.example.com/book".to_string(),
            start_chapter: 0,
            end_chapter: 99,
            total: 100,
            completed: 39, // 40 个散章（1..=40）中 39 成功
            failed: 1,     // 其中第 40 章失败
            next_index: 0,
            status: "running".to_string(),
            failed_chapters: vec![40],
            finished_chapters: (1..=40).collect(),
        };
        let task = task_from_persisted(row);
        let ahead = finished_ahead_indices(&task);
        assert!(
            ahead.len() <= DOWNLOAD_WINDOW as usize,
            "恢复后集合长度应 ≤ 窗口: {}",
            ahead.len()
        );
        assert_eq!(ahead.first(), Some(&1));
        assert_eq!(ahead.last(), Some(&31), "保留窗口内最小的 31 个散章");
        assert_eq!(
            task.completed.load(Ordering::SeqCst),
            31,
            "窗口外 8 个成功散章计数扣减（39-8）"
        );
        assert_eq!(
            task.failed.load(Ordering::SeqCst),
            0,
            "窗口外 1 个失败散章计数扣减（重下后重新计数）"
        );
        assert_eq!(
            failed_indices(&task),
            vec![40],
            "失败集合保留供 UI 展示（重下时清除/重记）"
        );
    }

    /// P2：超窗快照裁剪后实际跑完，`completed+failed==total`（不重复计数）
    #[test]
    fn test_task_from_persisted_trimmed_fixture_runs_to_total() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "2").unwrap();

        let (book_url, _chapters) =
            make_local_txt_book("legado_trim_run_test", "trim_run.txt", "裁剪续跑测试", 50);

        let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);
        let task = task_from_persisted(PersistedTask {
            task_id,
            book_url: book_url.clone(),
            start_chapter: 0,
            end_chapter: 49,
            total: 50,
            completed: 39,
            failed: 1,
            next_index: 0,
            status: "running".to_string(),
            failed_chapters: vec![40],
            finished_chapters: (1..=40).collect(),
        });
        TASKS.lock().unwrap().insert(task_id, Arc::clone(&task));

        run_download(task_id, task);

        let progress = cache_download_progress(task_id).unwrap();
        assert_eq!(progress.status, "completed");
        assert_eq!(progress.failed, 0);
        assert_eq!(progress.completed, 50, "裁剪后跑完不得重复计数");
        assert_eq!(
            progress.completed + progress.failed,
            progress.total,
            "completed 终态计数必须闭合"
        );

        TASKS.lock().unwrap().remove(&task_id);
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(&book_url)?;
            legado_db::CacheBookRepository::new(conn).delete_by_book(&book_url)?;
            BookRepository::new(conn).delete_by_url(&book_url)
        })
        .unwrap();
        crate::api::cache_api::clear_cache().unwrap();
        let _ = std::fs::remove_file(&book_url);
    }

    /// 全局准入：3 本书同时启动——任意时刻全局在途 ≤8、同时只有 1 本书
    /// 在发请求（请求序列中每本书各成连续一段）、单书 8 worker 达到 8 在途
    #[test]
    fn test_download_global_admission_one_book_at_a_time() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "8").unwrap();

        let server = start_multi_book_server(40, 0, 10);
        let (books, source_url) = setup_multi_book(server.port, 3, 10);

        let mut task_ids = Vec::new();
        for book in &books {
            task_ids.push(cache_download_start(book, 0, 9).unwrap());
        }
        for task_id in &task_ids {
            let progress = wait_terminal(*task_id);
            assert_eq!(progress.status, "completed");
            assert_eq!(progress.completed, 10);
            assert_eq!(progress.failed, 0);
        }

        assert!(
            !server.overlap.load(Ordering::SeqCst),
            "同时只准入 1 本书：不得观测到两本书同时在途"
        );
        assert!(
            server.max_active.load(Ordering::SeqCst) <= MAX_DOWNLOAD_CONCURRENCY,
            "全局在途不得超过单书并发上限 8: {}",
            server.max_active.load(Ordering::SeqCst)
        );
        assert_eq!(
            server.max_active.load(Ordering::SeqCst),
            MAX_DOWNLOAD_CONCURRENCY,
            "单书 8 worker、10 章应有 8 个在途请求"
        );

        // 请求序列：每本书各成连续一段（第二/三本在首本完成后才开始）
        let sequence = server.sequence.lock().unwrap().clone();
        assert_eq!(sequence.len(), 30, "3 本书 × 10 章各请求一次");
        let mut runs: Vec<&str> = Vec::new();
        for (book, _) in &sequence {
            if runs.last() != Some(&book.as_str()) {
                runs.push(book);
            }
        }
        assert_eq!(runs.len(), 3, "3 本书应各自连续成段: {runs:?}");
        for (book, index) in &sequence {
            assert_eq!(
                server.hits.lock().unwrap().get(&(book.clone(), *index)),
                Some(&1),
                "章节 ({book}, {index}) 应恰好请求一次"
            );
        }

        cleanup_multi_book(&books, &source_url);
    }

    /// 重启恢复：多个 running 任务同时续跑时仍只准入 1 本书
    /// （模拟 `ensure_restored` 对每个 running 任务调用 `run_download`）
    #[test]
    fn test_download_restore_running_tasks_admit_one_book() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "8").unwrap();

        let server = start_multi_book_server(40, 0, 6);
        let (books, source_url) = setup_multi_book(server.port, 2, 6);

        let mut task_ids = Vec::new();
        let mut handles = Vec::new();
        for book in &books {
            let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);
            let task = task_from_persisted(PersistedTask {
                task_id,
                book_url: book.clone(),
                start_chapter: 0,
                end_chapter: 5,
                total: 6,
                completed: 0,
                failed: 0,
                next_index: 0,
                status: "running".to_string(),
                failed_chapters: Vec::new(),
                finished_chapters: Vec::new(),
            });
            TASKS.lock().unwrap().insert(task_id, Arc::clone(&task));
            task_ids.push(task_id);
            handles.push(std::thread::spawn(move || run_download(task_id, task)));
        }
        for handle in handles {
            handle.join().expect("恢复任务线程不应 panic");
        }

        for task_id in &task_ids {
            let progress = cache_download_progress(*task_id).unwrap();
            assert_eq!(progress.status, "completed");
            assert_eq!(progress.completed, 6);
            assert_eq!(progress.failed, 0);
        }
        assert!(
            !server.overlap.load(Ordering::SeqCst),
            "重启恢复的多任务仍须串行准入"
        );
        assert!(server.max_active.load(Ordering::SeqCst) <= MAX_DOWNLOAD_CONCURRENCY);

        for task_id in &task_ids {
            TASKS.lock().unwrap().remove(task_id);
        }
        cleanup_multi_book(&books, &source_url);
    }

    /// 取消排队任务：首本持有准入期间取消第二本 → 第二本零 HTTP、终态 cancelled
    #[test]
    fn test_download_cancel_queued_task_not_executed() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "8").unwrap();

        let server = start_multi_book_server(120, 0, 10);
        let (books, source_url) = setup_multi_book(server.port, 2, 10);

        let first_key = books[0].rsplit('/').next().unwrap().to_string();
        let second_key = books[1].rsplit('/').next().unwrap().to_string();
        let first = cache_download_start(&books[0], 0, 9).unwrap();
        // 等首本真正开始请求，确保其持有全局准入
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let started = server
                .hits
                .lock()
                .unwrap()
                .keys()
                .any(|(book, _)| book == &first_key);
            if started {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "首本未在 5s 内发起请求"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        // 第二本排队后立即取消：不得发起任何请求
        let queued = cache_download_start(&books[1], 0, 9).unwrap();
        assert!(cache_download_cancel(queued).unwrap());
        let queued_progress = wait_terminal(queued);
        assert_eq!(queued_progress.status, "cancelled");
        assert_eq!(queued_progress.completed, 0);
        assert!(
            !server
                .hits
                .lock()
                .unwrap()
                .keys()
                .any(|(book, _)| book == &second_key),
            "取消的排队任务不得发起 HTTP"
        );

        assert_eq!(wait_terminal(first).status, "completed");
        cleanup_multi_book(&books, &source_url);
    }

    /// 慢首章：滑动窗口保证 in-memory/持久化 `finishedChapters` 长度 ≤32，
    /// 且首章完成前最多只派发窗口内的 32 章；最终计数完整、无重复
    #[test]
    fn test_download_slow_first_chapter_keeps_finished_ahead_bounded() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "8").unwrap();

        let server = start_multi_book_server(5, 1_500, 100);
        let (books, source_url) = setup_multi_book(server.port, 1, 100);
        let book_url = books[0].clone();
        let task_id = cache_download_start(&book_url, 0, 99).unwrap();

        let mut max_persisted_ahead = 0usize;
        let mut max_distinct_before_first_served = 0usize;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        loop {
            let progress = cache_download_progress(task_id).unwrap();
            if let Ok(Some(json)) =
                with_database(|db| CacheRepository::new(db.connection()).get(&persist_key(task_id)))
            {
                if let Ok(row) = serde_json::from_str::<PersistedTask>(&json) {
                    max_persisted_ahead = max_persisted_ahead.max(row.finished_chapters.len());
                }
            }
            if !server.first_chapter_served.load(Ordering::SeqCst) {
                let distinct = server
                    .hits
                    .lock()
                    .unwrap()
                    .keys()
                    .filter(|(book, _)| book == &book_url)
                    .count();
                max_distinct_before_first_served = max_distinct_before_first_served.max(distinct);
            }
            if progress.status != "running" {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "慢首章任务未在 15s 内完成: {progress:?}"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }

        assert!(
            max_persisted_ahead <= DOWNLOAD_WINDOW as usize,
            "持久化 finishedChapters 应 ≤32，实际 {max_persisted_ahead}"
        );
        assert!(
            max_distinct_before_first_served <= DOWNLOAD_WINDOW as usize,
            "首章完成前派发章数应 ≤32，实际 {max_distinct_before_first_served}"
        );
        let progress = cache_download_progress(task_id).unwrap();
        assert_eq!(progress.status, "completed");
        assert_eq!(progress.completed, 100);
        assert_eq!(progress.failed, 0);
        assert_eq!(server.hits.lock().unwrap().len(), 100, "每章恰好请求一次");

        cleanup_multi_book(&books, &source_url);
    }

    /// worker panic 隔离：panic 章计为失败并记录，其余章继续，
    /// completed 时 completed+failed==total
    #[test]
    fn test_download_worker_panic_counted_as_failed() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "2").unwrap();

        let server = start_chapter_server(10);
        let (book_url, source_url) = setup_online_book(server.port, 3);

        let _panic_guard = PanicChapterGuard::set(1);
        let task_id = cache_download_start(&book_url, 0, 2).unwrap();
        let progress = wait_terminal(task_id);

        assert_eq!(progress.status, "completed", "全部章已尝试 → completed");
        assert_eq!(progress.completed, 2);
        assert_eq!(progress.failed, 1);
        assert_eq!(
            progress.completed + progress.failed,
            progress.total,
            "completed 终态必须满足 completed+failed==total"
        );
        assert_eq!(
            cache_download_failed_chapters(&book_url).unwrap(),
            vec![1],
            "panic 章记入失败集合"
        );

        cleanup_online_book(&book_url, &source_url);
    }

    /// P3-5：worker 循环（主 + spawned）panic 被整体捕获——任务不挂死、
    /// 先 join 收尾再释放准入，终态置 failed（不误报 cancelled/completed）
    #[test]
    fn test_download_worker_loop_panic_marks_failed_and_joins() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = crate::api::config_api::ThreadCountResetGuard::new();
        crate::api::cache_api::clear_cache().unwrap();
        crate::api::config_api::set_config("threadCount", "2").unwrap();

        let server = start_chapter_server(10);
        let (book_url, source_url) = setup_online_book(server.port, 3);

        let _panic_guard = PanicWorkerLoopGuard::new();
        let task_id = cache_download_start(&book_url, 0, 2).unwrap();
        let progress = wait_terminal(task_id);

        assert_eq!(progress.status, "failed", "worker 循环 panic → failed");
        assert!(
            progress.completed + progress.failed <= progress.total,
            "计数不得超 total: {progress:?}"
        );
        assert!(
            server.hits.lock().unwrap().is_empty(),
            "worker 在认领前 panic，不应发起 HTTP"
        );

        cleanup_online_book(&book_url, &source_url);
    }
}
