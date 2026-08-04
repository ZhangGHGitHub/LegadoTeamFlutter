//! SearchBook Repository - searchBooks 表 CRUD

use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection};

use legado_core::models::SearchBook;

/// 搜索结果数据访问层
pub struct SearchBookRepository {
    conn: Arc<Mutex<Connection>>,
}

impl SearchBookRepository {
    pub fn new(conn: Arc<Mutex<Connection>>) -> Self {
        Self { conn }
    }

    /// 插入搜索结果（主键冲突时替换）
    pub fn insert(&self, book: &SearchBook) -> Result<i64, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        conn.execute(
            "INSERT OR REPLACE INTO searchBooks
             (bookUrl, origin, originName, type, name, author, kind, coverUrl,
              intro, wordCount, latestChapterTitle, tocUrl, time, variable,
              originOrder, chapterWordCountText, chapterWordCount, respondTime)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
            params![
                book.book_url,
                book.origin,
                book.origin_name,
                book.book_type,
                book.name,
                book.author,
                book.kind,
                book.cover_url,
                book.intro,
                book.word_count,
                book.latest_chapter_title,
                book.toc_url,
                book.time,
                book.variable,
                book.origin_order,
                book.chapter_word_count_text,
                book.chapter_word_count,
                book.respond_time,
            ],
        )
        .map_err(|e| format!("插入失败: {e}"))?;
        Ok(conn.last_insert_rowid())
    }

    /// 按书名关键字模糊搜索
    pub fn find_by_keyword(&self, keyword: &str) -> Result<Vec<SearchBook>, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let pattern = format!("%{keyword}%");
        let mut stmt = conn
            .prepare(
                "SELECT bookUrl, origin, originName, type, name, author, kind, coverUrl,
                        intro, wordCount, latestChapterTitle, tocUrl, time, variable,
                        originOrder, chapterWordCountText, chapterWordCount, respondTime
                 FROM searchBooks WHERE name LIKE ?1 ORDER BY originOrder ASC",
            )
            .map_err(|e| format!("准备查询失败: {e}"))?;

        let books = stmt
            .query_map(params![pattern], row_to_search_book)
            .map_err(|e| format!("查询失败: {e}"))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(books)
    }

    /// 按关键字删除匹配的搜索结果（书名模糊匹配）
    pub fn delete_by_keyword(&self, keyword: &str) -> Result<usize, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let pattern = format!("%{keyword}%");
        let affected = conn
            .execute(
                "DELETE FROM searchBooks WHERE name LIKE ?1",
                params![pattern],
            )
            .map_err(|e| format!("删除失败: {e}"))?;
        Ok(affected)
    }

    /// 清空所有搜索结果
    pub fn clear_all(&self) -> Result<usize, String> {
        let conn = self.conn.lock().map_err(|e| format!("锁获取失败: {e}"))?;
        let affected = conn
            .execute("DELETE FROM searchBooks", [])
            .map_err(|e| format!("清空失败: {e}"))?;
        Ok(affected)
    }
}

/// 将 rusqlite Row 转换为 SearchBook
fn row_to_search_book(row: &rusqlite::Row<'_>) -> rusqlite::Result<SearchBook> {
    Ok(SearchBook {
        book_url: row.get(0)?,
        origin: row.get(1)?,
        origin_name: row.get(2)?,
        book_type: row.get(3)?,
        name: row.get(4)?,
        author: row.get(5)?,
        kind: row.get(6)?,
        cover_url: row.get(7)?,
        intro: row.get(8)?,
        word_count: row.get(9)?,
        latest_chapter_title: row.get(10)?,
        toc_url: row.get(11)?,
        time: row.get(12)?,
        variable: row.get(13)?,
        origin_order: row.get(14)?,
        chapter_word_count_text: row.get(15)?,
        chapter_word_count: row.get(16)?,
        respond_time: row.get(17)?,
        // searchBooks 表不存储阅读记录标识（#424 加法式字段，默认 false/None）
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_repo() -> SearchBookRepository {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        // 插入一条 book_sources 记录以满足外键约束
        conn.execute(
            "INSERT INTO book_sources (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight)
             VALUES ('origin1', '测试源', 0, 0, 0, 0)",
            [],
        )
        .unwrap();
        let conn = Arc::new(Mutex::new(conn));
        SearchBookRepository::new(conn)
    }

    fn make_book(url: &str, name: &str) -> SearchBook {
        SearchBook {
            book_url: url.to_string(),
            origin: "origin1".to_string(),
            origin_name: "测试源".to_string(),
            name: name.to_string(),
            ..SearchBook::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_keyword() {
        let repo = make_repo();
        let book = make_book("https://book.example.com/1", "斗破苍穹");
        repo.insert(&book).unwrap();
        let results = repo.find_by_keyword("斗破").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "斗破苍穹");
        assert_eq!(results[0].book_url, "https://book.example.com/1");
    }

    #[test]
    fn test_find_by_keyword_no_match() {
        let repo = make_repo();
        repo.insert(&make_book("u1", "斗破苍穹")).unwrap();
        let results = repo.find_by_keyword("完美世界").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_delete_by_keyword() {
        let repo = make_repo();
        repo.insert(&make_book("u1", "斗破苍穹")).unwrap();
        repo.insert(&make_book("u2", "斗破苍穹II")).unwrap();
        repo.insert(&make_book("u3", "完美世界")).unwrap();
        let deleted = repo.delete_by_keyword("斗破").unwrap();
        assert_eq!(deleted, 2);
        let remaining = repo.find_by_keyword("完美").unwrap();
        assert_eq!(remaining.len(), 1);
    }

    #[test]
    fn test_clear_all() {
        let repo = make_repo();
        repo.insert(&make_book("u1", "book1")).unwrap();
        repo.insert(&make_book("u2", "book2")).unwrap();
        repo.insert(&make_book("u3", "book3")).unwrap();
        let cleared = repo.clear_all().unwrap();
        assert_eq!(cleared, 3);
        let results = repo.find_by_keyword("book").unwrap();
        assert!(results.is_empty());
    }
}
