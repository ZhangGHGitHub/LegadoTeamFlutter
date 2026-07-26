//! BookChapter Repository - chapters 表 CRUD

use rusqlite::{params, Connection};

use legado_core::models::BookChapter;
use legado_core::{LegadoError, LegadoResult};

use super::Repository;

/// 章节数据访问层
pub struct BookChapterRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookChapterRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 根据 bookUrl 查询该书所有章节（按 index 排序）
    pub fn find_by_book_url(&self, book_url: &str) -> LegadoResult<Vec<BookChapter>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,
                        resourceUrl, tag, wordCount, start, end, startFragmentId,
                        endFragmentId, variable, imgUrl
                 FROM chapters WHERE bookUrl = ?1 ORDER BY \"index\" ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let chapters = stmt
            .query_map(params![book_url], row_to_chapter)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(chapters)
    }

    /// 根据 bookUrl 和 index 查询指定章节
    pub fn find_by_book_url_and_index(
        &self,
        book_url: &str,
        index: i32,
    ) -> LegadoResult<Option<BookChapter>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,
                        resourceUrl, tag, wordCount, start, end, startFragmentId,
                        endFragmentId, variable, imgUrl
                 FROM chapters WHERE bookUrl = ?1 AND \"index\" = ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![book_url, index], row_to_chapter)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(ch)) => Ok(Some(ch)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 获取指定书籍的章节数量
    pub fn count_by_book_url(&self, book_url: &str) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM chapters WHERE bookUrl = ?1",
                params![book_url],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }

    /// 删除指定书籍的所有章节
    pub fn delete_by_book_url(&self, book_url: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM chapters WHERE bookUrl = ?1", params![book_url])
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(())
    }

    /// 批量插入章节（使用事务提高性能）
    pub fn insert_batch(&self, chapters: &[BookChapter]) -> LegadoResult<()> {
        let tx = self
            .conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启事务失败: {e}")))?;

        {
            let mut stmt = tx
                .prepare(
                    "INSERT OR REPLACE INTO chapters
                     (url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,
                      resourceUrl, tag, wordCount, start, end, startFragmentId,
                      endFragmentId, variable, imgUrl)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
                )
                .map_err(|e| LegadoError::Database(format!("准备插入失败: {e}")))?;

            for ch in chapters {
                stmt.execute(params![
                    ch.url,
                    ch.title,
                    ch.is_volume,
                    ch.base_url,
                    ch.book_url,
                    ch.index,
                    ch.is_vip,
                    ch.is_pay,
                    ch.resource_url,
                    ch.tag,
                    ch.word_count,
                    ch.start,
                    ch.end,
                    ch.start_fragment_id,
                    ch.end_fragment_id,
                    ch.variable,
                    ch.img_url,
                ])
                .map_err(|e| LegadoError::Database(format!("批量插入失败: {e}")))?;
            }
        }

        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交事务失败: {e}")))?;
        Ok(())
    }
}

impl<'a> Repository<BookChapter> for BookChapterRepository<'a> {
    fn find_all(&self) -> LegadoResult<Vec<BookChapter>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,
                        resourceUrl, tag, wordCount, start, end, startFragmentId,
                        endFragmentId, variable, imgUrl
                 FROM chapters ORDER BY bookUrl, \"index\" ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let chapters = stmt
            .query_map([], row_to_chapter)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(chapters)
    }

    fn insert(&self, item: &BookChapter) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO chapters
                 (url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,
                  resourceUrl, tag, wordCount, start, end, startFragmentId,
                  endFragmentId, variable, imgUrl)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
                params![
                    item.url,
                    item.title,
                    item.is_volume,
                    item.base_url,
                    item.book_url,
                    item.index,
                    item.is_vip,
                    item.is_pay,
                    item.resource_url,
                    item.tag,
                    item.word_count,
                    item.start,
                    item.end,
                    item.start_fragment_id,
                    item.end_fragment_id,
                    item.variable,
                    item.img_url,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
        Ok(())
    }

    fn update(&self, item: &BookChapter) -> LegadoResult<()> {
        self.insert(item)
    }

    fn delete(&self, id: &str) -> LegadoResult<()> {
        // id 为 "url|bookUrl" 拼接，简化处理仅按 url 删除
        self.conn
            .execute("DELETE FROM chapters WHERE url = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(())
    }
}

/// 将 rusqlite Row 转换为 BookChapter
fn row_to_chapter(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookChapter> {
    Ok(BookChapter {
        url: row.get(0)?,
        title: row.get(1)?,
        is_volume: row.get(2)?,
        base_url: row.get(3)?,
        book_url: row.get(4)?,
        index: row.get(5)?,
        is_vip: row.get(6)?,
        is_pay: row.get(7)?,
        resource_url: row.get(8)?,
        tag: row.get(9)?,
        word_count: row.get(10)?,
        start: row.get(11)?,
        end: row.get(12)?,
        start_fragment_id: row.get(13)?,
        end_fragment_id: row.get(14)?,
        variable: row.get(15)?,
        img_url: row.get(16)?,
    })
}

#[cfg(test)]
mod tests {
    use super::super::book_repository::BookRepository;
    use super::super::Repository;
    use super::*;
    use legado_core::models::Book;

    fn insert_parent_book(conn: &Connection, book_url: &str) {
        let book = Book {
            book_url: book_url.to_string(),
            name: format!("book_{book_url}"),
            author: format!("author_{book_url}"),
            ..Book::default()
        };
        let repo = BookRepository::new(conn);
        repo.insert(&book).unwrap();
    }

    fn make_chapter(book_url: &str, index: i32, title: &str) -> BookChapter {
        BookChapter {
            url: format!("{book_url}/ch{index}"),
            title: title.to_string(),
            book_url: book_url.to_string(),
            index,
            ..BookChapter::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_book_url() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "book1");
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&make_chapter("book1", 0, "第1章")).unwrap();
        repo.insert(&make_chapter("book1", 1, "第2章")).unwrap();
        let chapters = repo.find_by_book_url("book1").unwrap();
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "第1章");
        assert_eq!(chapters[1].title, "第2章");
    }

    #[test]
    fn test_find_by_book_url_and_index() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "book1");
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&make_chapter("book1", 0, "第1章")).unwrap();
        repo.insert(&make_chapter("book1", 5, "第6章")).unwrap();
        let ch = repo.find_by_book_url_and_index("book1", 5).unwrap();
        assert!(ch.is_some());
        assert_eq!(ch.unwrap().title, "第6章");
    }

    #[test]
    fn test_count_by_book_url() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "book1");
        insert_parent_book(db.connection(), "book2");
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&make_chapter("book1", 0, "ch0")).unwrap();
        repo.insert(&make_chapter("book1", 1, "ch1")).unwrap();
        repo.insert(&make_chapter("book2", 0, "ch0")).unwrap();
        assert_eq!(repo.count_by_book_url("book1").unwrap(), 2);
        assert_eq!(repo.count_by_book_url("book2").unwrap(), 1);
    }

    #[test]
    fn test_delete_by_book_url() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "book1");
        insert_parent_book(db.connection(), "book2");
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&make_chapter("book1", 0, "ch0")).unwrap();
        repo.insert(&make_chapter("book1", 1, "ch1")).unwrap();
        repo.insert(&make_chapter("book2", 0, "ch0")).unwrap();
        repo.delete_by_book_url("book1").unwrap();
        assert_eq!(repo.count_by_book_url("book1").unwrap(), 0);
        assert_eq!(repo.count_by_book_url("book2").unwrap(), 1);
    }

    #[test]
    fn test_insert_batch() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "book1");
        let repo = BookChapterRepository::new(db.connection());
        let chapters = vec![
            make_chapter("book1", 0, "第1章"),
            make_chapter("book1", 1, "第2章"),
            make_chapter("book1", 2, "第3章"),
        ];
        repo.insert_batch(&chapters).unwrap();
        assert_eq!(repo.count_by_book_url("book1").unwrap(), 3);
    }

    #[test]
    fn test_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "b1");
        insert_parent_book(db.connection(), "b2");
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&make_chapter("b1", 0, "c0")).unwrap();
        repo.insert(&make_chapter("b2", 0, "c0")).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_insert_batch_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookChapterRepository::new(db.connection());
        let empty: Vec<BookChapter> = vec![];
        repo.insert_batch(&empty).unwrap();
        assert_eq!(repo.find_all().unwrap().len(), 0);
    }
}
