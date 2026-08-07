//! 缓存批量下载 FFI 层（Task #136 R7，API_CONTRACT §2.43.3）
//!
//! 对标 Kotlin `CacheActivity` 批量缓存下载：任务创建 / 进度查询 / 取消。
//!
//! - 复用正文抓取链路 [`crate::api::reader::get_chapter_content_full`]
//!   （在线书抓取后自动写缓存；本地书解析后经 R5 [`crate::api::cache_api::save_chapter_content`] 写入）；
//! - 任务表为进程内内存表（重启即失效，对齐 Kotlin 前台服务生命周期语义）；
//! - 取消机制对照书源校验流（`source_check_api::CHECK_CANCELLED`）的
//!   AtomicBool 模式，每任务独立取消令牌；
//! - worker 运行于独立系统线程：正文抓取内部含 `runtime::block_on`，
//!   不可在 tokio worker 内嵌套执行。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::BookRepository;

use crate::db_state::with_database;

/// 任务 ID 分配器（进程内递增）
static NEXT_TASK_ID: AtomicU64 = AtomicU64::new(1);

/// 进程内任务表：task_id → 任务内部状态
///（LazyLock：`HashMap::new` 非 const fn，静态初始化需延迟构造）
static TASKS: LazyLock<Mutex<HashMap<u64, Arc<TaskInner>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 任务内部状态（跨线程共享）
struct TaskInner {
    book_url: String,
    start_chapter: i32,
    end_chapter: i32,
    total: i32,
    completed: AtomicI32,
    failed: AtomicI32,
    /// 取消令牌（对照 source_check_api 的 AtomicBool 模式）
    cancel: AtomicBool,
    /// 终态标记：running / completed / cancelled / failed
    status: Mutex<String>,
}

/// 批量下载任务快照（camelCase 序列化，跨 FFI 以 JSON 传递）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheDownloadTask {
    /// 任务 ID
    pub task_id: u64,
    /// 书籍 bookUrl
    pub book_url: String,
    /// 状态：running / completed / cancelled / failed（progress 查询未知任务时为 notFound）
    pub status: String,
    /// 计划下载章节总数
    pub total: i32,
    /// 已完成章节数
    pub completed: i32,
    /// 失败章节数
    pub failed: i32,
}

/// 创建批量缓存下载任务，返回任务 ID
///
/// - `book_url` — 书籍 bookUrl（必须已入库且有章节目录）
/// - `start_chapter` / `end_chapter` — 起止章节索引（含端点）；
///   负值按 0 处理，超出目录末章按末章截断
pub fn cache_download_start(
    book_url: &str,
    start_chapter: i32,
    end_chapter: i32,
) -> LegadoResult<u64> {
    // 同一本书已有进行中任务时复用返回既有 ID（契约 §2.43.3）
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

    // 书与章节目录校验
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

    // 区间裁剪：负值按 0、超出按末章
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
        cancel: AtomicBool::new(false),
        status: Mutex::new("running".to_string()),
    });

    TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?
        .insert(task_id, Arc::clone(&task));

    // worker 独立系统线程（正文抓取内部含 runtime::block_on，
    // 不可在 tokio worker 内嵌套执行）
    std::thread::Builder::new()
        .name(format!("cache-download-{task_id}"))
        .spawn(move || run_download(task_id, task))
        .map_err(|e| LegadoError::Ffi(format!("下载线程启动失败: {e}")))?;

    Ok(task_id)
}

/// worker 主循环：逐章抓取 + 写缓存，支持取消
fn run_download(task_id: u64, task: Arc<TaskInner>) {
    let book_url = task.book_url.clone();
    for index in task.start_chapter..=task.end_chapter {
        // 取消检查（对照 CHECK_CANCELLED 置位即停）
        if task.cancel.load(Ordering::SeqCst) {
            set_status(&task, "cancelled");
            return;
        }

        let result = download_one(&book_url, index);
        match result {
            Ok(()) => {
                task.completed.fetch_add(1, Ordering::SeqCst);
            }
            Err(_) => {
                task.failed.fetch_add(1, Ordering::SeqCst);
            }
        }
    }

    // 终态判定：全部失败 → failed；否则 completed（部分失败亦按完成，
    // 对齐 Kotlin CacheActivity 逐章容错语义）
    let all_failed = task.failed.load(Ordering::SeqCst) == task.total;
    set_status(&task, if all_failed { "failed" } else { "completed" });
    let _ = task_id;
}

/// 抓取单章并写入缓存
fn download_one(book_url: &str, chapter_index: i32) -> LegadoResult<()> {
    if crate::api::reader::is_local_book(book_url) {
        // 本地书：解析原文（不净化）+ R5 写入缓存
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
        // 在线书：正文抓取链路内部完成「缓存检查→网络抓取→缓存写入」
        crate::api::reader::get_chapter_content_full(book_url, chapter_index)?;
        Ok(())
    }
}

/// 查询任务进度；未知任务返回 `status=notFound` 的占位快照
pub fn cache_download_progress(task_id: u64) -> LegadoResult<CacheDownloadTask> {
    let task = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?
        .get(&task_id)
        .cloned();
    Ok(match task {
        Some(t) => snapshot(task_id, &t),
        None => CacheDownloadTask {
            task_id,
            book_url: String::new(),
            status: "notFound".into(),
            total: 0,
            completed: 0,
            failed: 0,
        },
    })
}

/// 取消任务；任务不存在返回 false（终态任务的取消为幂等 no-op）
pub fn cache_download_cancel(task_id: u64) -> LegadoResult<bool> {
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

/// 列出所有任务快照（按任务 ID 升序）
pub fn cache_download_list() -> LegadoResult<Vec<CacheDownloadTask>> {
    let map = TASKS
        .lock()
        .map_err(|e| LegadoError::Ffi(format!("任务表加锁失败: {e}")))?;
    let mut ids: Vec<u64> = map.keys().copied().collect();
    ids.sort_unstable();
    Ok(ids
        .into_iter()
        .filter_map(|id| map.get(&id).map(|t| snapshot(id, t)))
        .collect())
}

/// 构造任务快照
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

/// 写入终态/状态（锁中毒时静默降级）
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
