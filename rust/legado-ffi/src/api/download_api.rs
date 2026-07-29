//! 下载管理器 FFI API
//!
//! 暴露 legado-core::download_manager 的 DownloadManager 到 Flutter 端。
//! 使用全局 OnceLock + Mutex 管理 DownloadManager 实例。

use std::sync::{Mutex, OnceLock};

use legado_core::download_manager::{DownloadManager, DownloadStatus, DownloadTask};
use legado_core::{LegadoError, LegadoResult};

/// 全局 DownloadManager 实例
static DOWNLOAD_MANAGER: OnceLock<Mutex<DownloadManager>> = OnceLock::new();

fn get_manager() -> &'static Mutex<DownloadManager> {
    DOWNLOAD_MANAGER.get_or_init(|| Mutex::new(DownloadManager::new(3)))
}

fn with_manager<F, R>(f: F) -> LegadoResult<R>
where
    F: FnOnce(&mut DownloadManager) -> LegadoResult<R>,
{
    let slot = get_manager();
    let mut guard = slot
        .lock()
        .map_err(|_| LegadoError::Internal("DownloadManager 互斥锁被毒化".into()))?;
    f(&mut guard)
}

/// 添加下载任务
///
/// # 参数
/// - `book_url`: 书籍 URL
/// - `chapter_url`: 章节 URL
/// - `chapter_title`: 章节标题
/// - `chapter_index`: 章节序号
/// - `priority`: 优先级（越小越优先）
///
/// # 返回
/// 任务 ID
pub fn download_add_task(
    book_url: &str,
    chapter_url: &str,
    chapter_title: &str,
    chapter_index: i32,
    priority: i32,
) -> LegadoResult<String> {
    let task_id = format!(
        "{}_{}",
        book_url.replace(['/', ':', '?', '&'], "_"),
        chapter_index
    );
    let task = DownloadTask {
        id: task_id.clone(),
        book_url: book_url.to_string(),
        chapter_url: chapter_url.to_string(),
        chapter_title: chapter_title.to_string(),
        chapter_index,
        status: DownloadStatus::Pending,
        progress: 0.0,
        priority,
        created_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64,
        completed_at: None,
        error: None,
    };
    with_manager(|mgr| {
        let id = mgr.add_task(task);
        Ok(id)
    })
}

/// 获取下载统计信息（摘要）
pub fn download_list_tasks() -> LegadoResult<String> {
    download_get_stats()
}

/// 获取指定书籍的下载任务
pub fn download_list_by_book(book_url: &str) -> LegadoResult<String> {
    with_manager(|mgr| {
        let tasks: Vec<serde_json::Value> = mgr
            .tasks_by_book(book_url)
            .into_iter()
            .map(task_to_json)
            .collect();
        serde_json::to_string(&tasks).map_err(|e| LegadoError::Internal(format!("序列化失败: {e}")))
    })
}

/// 获取下载统计信息
pub fn download_get_stats() -> LegadoResult<String> {
    with_manager(|mgr| {
        let stats = mgr.stats();
        let result = serde_json::json!({
            "total": stats.total,
            "pending": stats.pending,
            "downloading": stats.downloading,
            "completed": stats.completed,
            "failed": stats.failed,
            "paused": stats.paused,
        });
        serde_json::to_string(&result)
            .map_err(|e| LegadoError::Internal(format!("序列化失败: {e}")))
    })
}

/// 暂停所有下载
pub fn download_pause_all() -> LegadoResult<()> {
    with_manager(|mgr| {
        mgr.pause_all();
        Ok(())
    })
}

/// 恢复所有下载
pub fn download_resume_all() -> LegadoResult<()> {
    with_manager(|mgr| {
        mgr.resume_all();
        Ok(())
    })
}

/// 移除指定任务
pub fn download_remove_task(task_id: &str) -> LegadoResult<()> {
    with_manager(|mgr| {
        mgr.remove_task(task_id);
        Ok(())
    })
}

/// 标记任务完成（由实际下载执行者调用）
pub fn download_complete_task(task_id: &str) -> LegadoResult<()> {
    with_manager(|mgr| {
        mgr.complete_task(task_id);
        Ok(())
    })
}

/// 更新任务进度
pub fn download_update_progress(task_id: &str, progress: f64) -> LegadoResult<()> {
    with_manager(|mgr| {
        mgr.update_progress(task_id, progress);
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// 辅助函数
// ---------------------------------------------------------------------------

fn task_to_json(task: &DownloadTask) -> serde_json::Value {
    let status_str = match &task.status {
        DownloadStatus::Pending => "pending",
        DownloadStatus::Downloading => "downloading",
        DownloadStatus::Completed => "completed",
        DownloadStatus::Failed(_) => "failed",
        DownloadStatus::Paused => "paused",
    };
    serde_json::json!({
        "id": task.id,
        "book_url": task.book_url,
        "chapter_url": task.chapter_url,
        "chapter_title": task.chapter_title,
        "chapter_index": task.chapter_index,
        "status": status_str,
        "progress": task.progress,
        "priority": task.priority,
        "created_at": task.created_at,
        "completed_at": task.completed_at,
        "error": task.error,
    })
}
