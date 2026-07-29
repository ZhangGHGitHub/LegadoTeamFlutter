//! DownloadTask Repository - download_tasks 表 CRUD

use rusqlite::{params, Connection};

use legado_core::models::{DownloadStatus, DownloadTask};
use legado_core::{LegadoError, LegadoResult};

use super::Repository;

/// 下载任务数据访问层
pub struct DownloadTaskRepository<'a> {
    conn: &'a Connection,
}

impl<'a> DownloadTaskRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 根据 ID 查询下载任务
    pub fn find_by_id(&self, id: &str) -> LegadoResult<Option<DownloadTask>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_url, chapter_title, chapter_index, status,
                        progress, priority, created_at, completed_at, error,
                        fail_count, last_retry_at, next_retry_at
                 FROM download_tasks WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败：{e}")))?;

        let mut rows = stmt
            .query_map(params![id], row_to_download_task)
            .map_err(|e| LegadoError::Database(format!("查询失败：{e}")))?;

        match rows.next() {
            Some(Ok(task)) => Ok(Some(task)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败：{e}"))),
            None => Ok(None),
        }
    }

    /// 根据书籍 URL 获取该书的所
    pub fn get_by_book_url(&self, book_url: &str) -> LegadoResult<Vec<DownloadTask>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_url, chapter_title, chapter_index, status,
                        progress, priority, created_at, completed_at, error,
                        fail_count, last_retry_at, next_retry_at
                 FROM download_tasks WHERE book_url = ?1 ORDER BY chapter_index ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败：{e}")))?;

        let tasks = stmt
            .query_map(params![book_url], row_to_download_task)
            .map_err(|e| LegadoError::Database(format!("查询失败：{e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(tasks)
    }
}

impl<'a> Repository<DownloadTask> for DownloadTaskRepository<'a> {
    fn find_all(&self) -> LegadoResult<Vec<DownloadTask>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_url, chapter_title, chapter_index, status,
                        progress, priority, created_at, completed_at, error,
                        fail_count, last_retry_at, next_retry_at
                 FROM download_tasks ORDER BY chapter_index ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败：{e}")))?;

        let tasks = stmt
            .query_map([], row_to_download_task)
            .map_err(|e| LegadoError::Database(format!("查询失败：{e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(tasks)
    }

    fn insert(&self, item: &DownloadTask) -> LegadoResult<()> {
        // 将状态转换为字符串并存储为整数
        let status_int = match &item.status {
            DownloadStatus::Pending => 0,
            DownloadStatus::Downloading => 1,
            DownloadStatus::Completed => 2,
            DownloadStatus::Failed(_) => 3,
            DownloadStatus::Paused => 4,
        };

        self.conn
            .execute(
                "INSERT OR REPLACE INTO download_tasks
                 (id, book_url, chapter_url, chapter_title, chapter_index, status,
                  progress, priority, created_at, completed_at, error,
                  fail_count, last_retry_at, next_retry_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
                params![
                    item.id,
                    item.book_url,
                    item.chapter_url,
                    item.chapter_title,
                    item.chapter_index,
                    status_int,
                    item.progress,
                    item.priority,
                    item.created_at,
                    item.completed_at.unwrap_or(0),
                    item.error.as_deref().unwrap_or(""),
                    item.fail_count,
                    item.last_retry_at.unwrap_or(0),
                    item.next_retry_at.unwrap_or(0),
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入失败：{e}")))?;
        Ok(())
    }

    fn update(&self, item: &DownloadTask) -> LegadoResult<()> {
        self.insert(item)
    }

    fn delete(&self, id: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM download_tasks WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除失败：{e}")))?;
        Ok(())
    }
}

fn row_to_download_task(row: &rusqlite::Row<'_>) -> rusqlite::Result<DownloadTask> {
    use legado_core::models::DownloadStatus;
    
    let status_int: i32 = row.get(5)?;
    let status = match status_int {
        0 => DownloadStatus::Pending,
        1 => DownloadStatus::Downloading,
        2 => DownloadStatus::Completed,
        3 => DownloadStatus::Failed(String::new()),
        4 => DownloadStatus::Paused,
        _ => DownloadStatus::Pending,
    };

    Ok(DownloadTask {
        id: row.get(0)?,
        book_url: row.get(1)?,
        chapter_url: row.get(2)?,
        chapter_title: row.get(3)?,
        chapter_index: row.get(4)?,
        status,
        progress: row.get(6)?,
        priority: row.get(7)?,
        created_at: row.get(8)?,
        completed_at: row.get(9)?,
        error: {
            let s: String = row.get(10)?;
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        },
        fail_count: row.get(11)?,
        last_retry_at: row.get(12)?,
        next_retry_at: row.get(13)?,
        downloaded_bytes: row.get::<_, Option<i64>>(14).unwrap_or(Some(0)).unwrap_or(0),
        max_retry_count: row.get::<_, Option<i64>>(15).unwrap_or(Some(3)).unwrap_or(3) as u32,
    })
}

#[cfg(test)]
mod tests {
    use super::super::Repository;
    use super::*;
    use legado_core::models::DownloadStatus;

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
            created_at: 0,
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
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DownloadTaskRepository::new(db.connection());

        repo.insert(&make_task("1", "book1", 0)).unwrap();
        repo.insert(&make_task("2", "book1", 1)).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DownloadTaskRepository::new(db.connection());

        repo.insert(&make_task("t1", "book1", 0)).unwrap();

        let found = repo.find_by_id("t1").unwrap().unwrap();
        assert_eq!(found.chapter_title, "Chapter 0");
    }

    #[test]
    fn test_find_by_id_not_found() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DownloadTaskRepository::new(db.connection());

        let found = repo.find_by_id("nonexistent").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DownloadTaskRepository::new(db.connection());

        repo.insert(&make_task("1", "book1", 0)).unwrap();
        repo.delete("1").unwrap();

        let all = repo.find_all().unwrap();
        assert!(all.is_empty());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DownloadTaskRepository::new(db.connection());

        let mut task = make_task("1", "book1", 0);
        repo.insert(&task).unwrap();

        task.chapter_title = "updated".to_string();
        repo.update(&task).unwrap();

        let found = repo.find_by_id("1").unwrap().unwrap();
        assert_eq!(found.chapter_title, "updated");
    }

    #[test]
    fn test_get_by_book_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DownloadTaskRepository::new(db.connection());

        repo.insert(&make_task("1", "book_a", 0)).unwrap();
        repo.insert(&make_task("2", "book_a", 1)).unwrap();
        repo.insert(&make_task("3", "book_b", 0)).unwrap();

        let book_a_tasks = repo.get_by_book_url("book_a").unwrap();
        assert_eq!(book_a_tasks.len(), 2);

        let book_b_tasks = repo.get_by_book_url("book_b").unwrap();
        assert_eq!(book_b_tasks.len(), 1);
    }
}
