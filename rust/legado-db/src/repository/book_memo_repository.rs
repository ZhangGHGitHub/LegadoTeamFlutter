//! BookMemo Repository - book_memos 表 CRUD（schema v113，书备忘）
//!
//! 对齐原版 `BookMemo.kt` / `BookMemoDao.kt`：
//! - 主键 `bookUrl`（一书一条），**无级联外键**——导入时替换书架行不得连带删除备忘；
//! - `updatedAt` 为最后修改毫秒时间戳，恢复时仅接受「比库内更新」的条目
//!   （原版 `BookMemoDao.restore` 的 `memo.updatedAt > (get()?.updatedAt ?: -1)`）；
//! - 原版 `all()` 只导出书架内书籍的备忘（`inner join books`），备份收集走
//!   [`BookMemoRepository::list_for_bookshelf`]。
//!
//! 本批（批27）只做数据层与备份，无 FFI 方法；阅读器备忘面板后续批。

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 书备忘（对齐原版 Room v113 `BookMemo` 实体）
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BookMemo {
    #[serde(default, rename = "bookUrl", alias = "book_url")]
    pub book_url: String,
    #[serde(default)]
    pub content: String,
    #[serde(default, rename = "updatedAt", alias = "updated_at")]
    pub updated_at: i64,
}

/// 书备忘数据访问层
pub struct BookMemoRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookMemoRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 按 bookUrl 读取备忘
    pub fn get(&self, book_url: &str) -> LegadoResult<Option<BookMemo>> {
        self.conn
            .query_row(
                "SELECT bookUrl, content, updatedAt FROM book_memos WHERE bookUrl = ?1",
                params![book_url],
                |row| {
                    Ok(BookMemo {
                        book_url: row.get(0)?,
                        content: row.get(1)?,
                        updated_at: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询书备忘失败: {e}")))
    }

    /// 整条写入/替换（按 `bookUrl` 主键）
    pub fn upsert(&self, memo: &BookMemo) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO book_memos (bookUrl, content, updatedAt)
                 VALUES (?1, ?2, ?3)",
                params![memo.book_url, memo.content, memo.updated_at],
            )
            .map_err(|e| LegadoError::Database(format!("写入书备忘失败: {e}")))?;
        Ok(())
    }

    /// 删除某书的备忘，返回是否删除
    pub fn delete(&self, book_url: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "DELETE FROM book_memos WHERE bookUrl = ?1",
                params![book_url],
            )
            .map_err(|e| LegadoError::Database(format!("删除书备忘失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 按书 URL 列表批量读取备忘（空列表直接返回空；大批量分块避免
    /// SQLite 变量数上限）
    pub fn list_by_book_urls(&self, book_urls: &[String]) -> LegadoResult<Vec<BookMemo>> {
        if book_urls.is_empty() {
            return Ok(Vec::new());
        }
        let mut out = Vec::new();
        for chunk in book_urls.chunks(500) {
            let placeholders = (1..=chunk.len())
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT bookUrl, content, updatedAt FROM book_memos
                 WHERE bookUrl IN ({placeholders})"
            );
            let mut stmt = self
                .conn
                .prepare(&sql)
                .map_err(|e| LegadoError::Database(format!("准备书备忘批量查询失败: {e}")))?;
            let params: Vec<&dyn rusqlite::ToSql> = chunk
                .iter()
                .map(|url| url as &dyn rusqlite::ToSql)
                .collect();
            let rows = stmt
                .query_map(params.as_slice(), |row| {
                    Ok(BookMemo {
                        book_url: row.get(0)?,
                        content: row.get(1)?,
                        updated_at: row.get(2)?,
                    })
                })
                .map_err(|e| LegadoError::Database(format!("查询书备忘失败: {e}")))?
                .filter_map(|r| r.ok());
            out.extend(rows);
        }
        Ok(out)
    }

    /// 全表读取（测试/统计用；备份导出用 [`Self::list_for_bookshelf`] 对齐原版）
    pub fn find_all(&self) -> LegadoResult<Vec<BookMemo>> {
        let mut stmt = self
            .conn
            .prepare("SELECT bookUrl, content, updatedAt FROM book_memos ORDER BY updatedAt DESC")
            .map_err(|e| LegadoError::Database(format!("准备书备忘查询失败: {e}")))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(BookMemo {
                    book_url: row.get(0)?,
                    content: row.get(1)?,
                    updated_at: row.get(2)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询书备忘失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 书架内书籍的备忘（对齐原版 `BookMemoDao.all()` 的 `inner join books`）
    ///
    /// 备份导出用：书架已移除的书即使残留备忘也不进入备份。
    pub fn list_for_bookshelf(&self) -> LegadoResult<Vec<BookMemo>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT book_memos.bookUrl, book_memos.content, book_memos.updatedAt
                 FROM book_memos INNER JOIN books USING (bookUrl)
                 ORDER BY book_memos.updatedAt DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备书备忘查询失败: {e}")))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(BookMemo {
                    book_url: row.get(0)?,
                    content: row.get(1)?,
                    updated_at: row.get(2)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询书备忘失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 备份恢复单条（对齐原版 `BookMemoDao.restore`）
    ///
    /// 仅当库内存在该书（`hasBook`）且传入 `updatedAt` 大于库内值（无行视为 -1）
    /// 时写入；返回是否落库。
    pub fn restore_one(&self, memo: &BookMemo) -> LegadoResult<bool> {
        if !self.has_book(&memo.book_url)? {
            return Ok(false);
        }
        let current = self.get(&memo.book_url)?;
        let current_updated = current.map(|m| m.updated_at).unwrap_or(-1);
        if memo.updated_at <= current_updated {
            return Ok(false);
        }
        self.upsert(memo)?;
        Ok(true)
    }

    /// 书是否存在（对齐原版 `BookMemoDao.hasBook`）
    pub fn has_book(&self, book_url: &str) -> LegadoResult<bool> {
        let exists: i64 = self
            .conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM books WHERE bookUrl = ?1)",
                params![book_url],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询书籍是否存在失败: {e}")))?;
        Ok(exists != 0)
    }

    /// 备忘总数
    pub fn count(&self) -> LegadoResult<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM book_memos", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("书备忘计数失败: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repository::Repository;
    use crate::BookRepository;

    /// 造一本书架书（备忘保存/恢复要求书籍存在）
    fn seed_book(conn: &Connection, book_url: &str) {
        let book = legado_core::models::Book {
            book_url: book_url.to_string(),
            name: format!("书-{book_url}"),
            ..Default::default()
        };
        BookRepository::new(conn)
            .insert(&book)
            .expect("种子书籍写入失败");
    }

    #[test]
    fn test_memo_crud() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookMemoRepository::new(conn);

        assert!(repo.get("https://b/1").unwrap().is_none());
        assert_eq!(repo.count().unwrap(), 0);

        repo.upsert(&BookMemo {
            book_url: "https://b/1".to_string(),
            content: "第一条备忘".to_string(),
            updated_at: 100,
        })
        .unwrap();
        let memo = repo.get("https://b/1").unwrap().unwrap();
        assert_eq!(memo.content, "第一条备忘");
        assert_eq!(memo.updated_at, 100);

        repo.upsert(&BookMemo {
            book_url: "https://b/1".to_string(),
            content: "更新后的备忘".to_string(),
            updated_at: 200,
        })
        .unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(
            repo.get("https://b/1").unwrap().unwrap().content,
            "更新后的备忘"
        );

        assert!(repo.delete("https://b/1").unwrap());
        assert!(!repo.delete("https://b/1").unwrap());
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_list_by_book_urls() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookMemoRepository::new(db.connection());
        for i in 1..=3 {
            repo.upsert(&BookMemo {
                book_url: format!("https://b/{i}"),
                content: format!("备忘{i}"),
                updated_at: i as i64,
            })
            .unwrap();
        }

        assert!(repo.list_by_book_urls(&[]).unwrap().is_empty());
        let mut found = repo
            .list_by_book_urls(&["https://b/1".to_string(), "https://b/3".to_string()])
            .unwrap();
        found.sort_by(|a, b| a.book_url.cmp(&b.book_url));
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].book_url, "https://b/1");
        assert_eq!(found[1].book_url, "https://b/3");
    }

    /// 备份导出只含书架内书籍（对齐原版 inner join books）
    #[test]
    fn test_list_for_bookshelf_filters_missing_books() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        seed_book(conn, "https://b/on-shelf");
        let repo = BookMemoRepository::new(conn);
        repo.upsert(&BookMemo {
            book_url: "https://b/on-shelf".to_string(),
            content: "在架".to_string(),
            updated_at: 1,
        })
        .unwrap();
        repo.upsert(&BookMemo {
            book_url: "https://b/off-shelf".to_string(),
            content: "离架".to_string(),
            updated_at: 2,
        })
        .unwrap();

        let memos = repo.list_for_bookshelf().unwrap();
        assert_eq!(memos.len(), 1);
        assert_eq!(memos[0].book_url, "https://b/on-shelf");
        assert_eq!(repo.find_all().unwrap().len(), 2, "全表仍有两条");
    }

    /// restore_one：书不存在不写；更新者胜；旧值不覆盖
    #[test]
    fn test_restore_one_semantics() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        seed_book(conn, "https://b/restore");
        let repo = BookMemoRepository::new(conn);

        // 书不存在：跳过
        assert!(!repo
            .restore_one(&BookMemo {
                book_url: "https://b/ghost".to_string(),
                content: "孤儿备忘".to_string(),
                updated_at: 100,
            })
            .unwrap());

        // 无库内行：写入
        assert!(repo
            .restore_one(&BookMemo {
                book_url: "https://b/restore".to_string(),
                content: "备份一".to_string(),
                updated_at: 100,
            })
            .unwrap());

        // 旧备份不覆盖新值
        assert!(!repo
            .restore_one(&BookMemo {
                book_url: "https://b/restore".to_string(),
                content: "旧备份".to_string(),
                updated_at: 50,
            })
            .unwrap());
        assert_eq!(
            repo.get("https://b/restore").unwrap().unwrap().content,
            "备份一"
        );

        // 更新值胜出
        assert!(repo
            .restore_one(&BookMemo {
                book_url: "https://b/restore".to_string(),
                content: "备份二".to_string(),
                updated_at: 200,
            })
            .unwrap());
        assert_eq!(
            repo.get("https://b/restore").unwrap().unwrap().content,
            "备份二"
        );
    }
}
