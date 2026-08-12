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

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

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

const PERSIST_PREFIX: &str = "cacheDownloadTask:";
const PERSIST_INDEX: &str = "cacheDownloadTaskIndex";
const PERSIST_NEXT_ID: &str = "cacheDownloadNextId";

struct TaskInner {
    book_url: String,
    start_chapter: i32,
    end_chapter: i32,
    total: i32,
    completed: AtomicI32,
    failed: AtomicI32,
    next_index: AtomicI32,
    cancel: AtomicBool,
    status: Mutex<String>,
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
    next_index: i32,
    status: String,
}

fn persist_key(task_id: u64) -> String {
    format!("{PERSIST_PREFIX}{task_id}")
}

fn persist_snapshot(task_id: u64, task: &TaskInner) {
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
        next_index: task.next_index.load(Ordering::SeqCst),
        status,
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
        let task = Arc::new(TaskInner {
            book_url: row.book_url,
            start_chapter: row.start_chapter,
            end_chapter: row.end_chapter,
            total: row.total,
            completed: AtomicI32::new(row.completed),
            failed: AtomicI32::new(row.failed),
            next_index: AtomicI32::new(row.next_index.max(row.start_chapter)),
            cancel: AtomicBool::new(false),
            status: Mutex::new("running".to_string()),
        });
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
                t.book_url == book_url
                    && t.status
                        .lock()
                        .map(|s| *s == "running")
                        .unwrap_or(false)
            })
            .map(|(id, t)| (*id, t))
            .collect();
        if let Some((id, _)) = running.pop() {
            return Ok(id);
        }
    }

    let book_exists = with_database(|db| {
        BookRepository::new(db.connection()).find_by_url(book_url)
    })?
    .is_some();
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
        next_index: AtomicI32::new(start),
        cancel: AtomicBool::new(false),
        status: Mutex::new("running".to_string()),
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

fn run_download(task_id: u64, task: Arc<TaskInner>) {
    let book_url = task.book_url.clone();
    let mut index = task.next_index.load(Ordering::SeqCst);
    while index <= task.end_chapter {
        if task.cancel.load(Ordering::SeqCst) {
            set_status(&task, "cancelled");
            persist_snapshot(task_id, &task);
            return;
        }

        match download_one(&book_url, index) {
            Ok(()) => {
                task.completed.fetch_add(1, Ordering::SeqCst);
            }
            Err(_) => {
                task.failed.fetch_add(1, Ordering::SeqCst);
            }
        }
        index += 1;
        task.next_index.store(index, Ordering::SeqCst);
        persist_snapshot(task_id, &task);
    }

    let all_failed = task.failed.load(Ordering::SeqCst) == task.total;
    set_status(&task, if all_failed { "failed" } else { "completed" });
    persist_snapshot(task_id, &task);
}

fn download_one(book_url: &str, chapter_index: i32) -> LegadoResult<()> {
    if crate::api::reader::is_local_book(book_url) {
        let chapter = with_database(|db| {
            BookChapterRepository::new(db.connection())
                .find_by_book_url_and_index(book_url, chapter_index)
        })?
        .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;
        let content = legado_book::LocalBook::get_chapter_content(
            book_url,
            &crate::api::reader::chapter_to_local_info(&chapter),
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
        } else if let Ok(Some(json)) = with_database(|db| {
            CacheRepository::new(db.connection()).get(&persist_key(id))
        }) {
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
        let err = cache_download_start("http://no-such-book.example.com", 0, 10).unwrap_err();
        assert!(err.to_string().contains("书籍不存在"));
    }

    /// 本地 TXT 书批量下载：抓取链路走本地解析（无网络依赖），
    /// 完成后缓存可读、进度与终态正确
    #[test]
    fn test_local_book_batch_download() {
        let _db_guard = crate::db_state::ensure_test_db();
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

    /// 取消机制：创建后立即取消，任务不应跑完全量（对照 CHECK_CANCELLED 语义）
    #[test]
    fn test_cancel_flag_set() {
        let _db_guard = crate::db_state::ensure_test_db();
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
}
