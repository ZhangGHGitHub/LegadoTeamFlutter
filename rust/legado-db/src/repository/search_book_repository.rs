//! SearchBook Repository - searchBooks 表 CRUD
//!
//! 对齐原版 `SearchBookDao`：搜索时逐条 insert，换源优先 `changeSourceByGroup`
//! 读库复用，避免二次全量搜索。

use rusqlite::{params, Connection};

use legado_core::models::SearchBook;
use legado_core::{LegadoError, LegadoResult};

/// 搜索结果数据访问层
pub struct SearchBookRepository<'a> {
    conn: &'a Connection,
}

impl<'a> SearchBookRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入搜索结果（主键 bookUrl 冲突时替换，对齐原版 OnConflictStrategy.REPLACE）
    pub fn insert(&self, book: &SearchBook) -> LegadoResult<i64> {
        self.conn
            .execute(
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
            .map_err(|e| LegadoError::Database(format!("插入 searchBooks 失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 批量插入（单源批次）；单条失败不阻断其余（对齐原版逐条 insert 尽力而为）
    pub fn insert_all(&self, books: &[SearchBook]) -> LegadoResult<usize> {
        let mut ok = 0usize;
        for book in books {
            if self.insert(book).is_ok() {
                ok += 1;
            }
        }
        Ok(ok)
    }

    /// 按书名关键字模糊搜索
    pub fn find_by_keyword(&self, keyword: &str) -> LegadoResult<Vec<SearchBook>> {
        let pattern = format!("%{keyword}%");
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookUrl, origin, originName, type, name, author, kind, coverUrl,
                        intro, wordCount, latestChapterTitle, tocUrl, time, variable,
                        originOrder, chapterWordCountText, chapterWordCount, respondTime
                 FROM searchBooks WHERE name LIKE ?1 ORDER BY originOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let books = stmt
            .query_map(params![pattern], row_to_search_book)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(books)
    }

    /// 换源读库（对齐 `SearchBookDao.changeSourceByGroup`）
    ///
    /// - `author` 空串：不校验作者（`changeSourceCheckAuthor=false`）
    /// - `author` 非空：`author LIKE %author%`
    /// - `source_group` 空：不限分组；非空时在 Rust 侧按分组成员过滤
    ///   （与 `SOURCE_GROUP_MEMBERSHIP_FILTER` 语义一致的简化实现）
    pub fn change_source_by_group(
        &self,
        name: &str,
        author: &str,
        source_group: &str,
    ) -> LegadoResult<Vec<SearchBook>> {
        let author = author.trim();
        let mut stmt = self
            .conn
            .prepare(
                "SELECT t1.bookUrl, t1.origin, t1.originName, t1.type, t1.name, t1.author,
                        t1.kind, t1.coverUrl, t1.intro, t1.wordCount, t1.latestChapterTitle,
                        t1.tocUrl, t1.time, t1.variable, t2.customOrder as originOrder,
                        t1.chapterWordCountText, t1.chapterWordCount, t1.respondTime,
                        t2.bookSourceGroup
                 FROM searchBooks AS t1
                 INNER JOIN book_sources AS t2 ON t1.origin = t2.bookSourceUrl
                 WHERE t1.name = ?1
                   AND (?2 = '' OR t1.author LIKE '%' || ?2 || '%')
                   AND t2.enabled = 1
                 ORDER BY t2.customOrder",
            )
            .map_err(|e| LegadoError::Database(format!("准备换源查询失败: {e}")))?;

        let group = source_group.trim();
        let books = stmt
            .query_map(params![name, author], |row| {
                let book = row_to_search_book(row)?;
                let group_field: String = row.get(18).unwrap_or_default();
                Ok((book, group_field))
            })
            .map_err(|e| LegadoError::Database(format!("换源查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .filter(|(_, g)| group.is_empty() || group_contains(g, group))
            .map(|(book, _)| book)
            .collect();
        Ok(books)
    }

    /// 按书名+作者删除（强制换源重搜前清理，对齐 startSearch 删除旧结果）
    pub fn clear_by_name_author(&self, name: &str, author: &str) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute(
                "DELETE FROM searchBooks WHERE name = ?1 AND (?2 = '' OR author = ?2)",
                params![name, author.trim()],
            )
            .map_err(|e| LegadoError::Database(format!("删除 searchBooks 失败: {e}")))?;
        Ok(affected)
    }

    /// 按关键字删除匹配的搜索结果（书名模糊匹配）
    pub fn delete_by_keyword(&self, keyword: &str) -> LegadoResult<usize> {
        let pattern = format!("%{keyword}%");
        let affected = self
            .conn
            .execute(
                "DELETE FROM searchBooks WHERE name LIKE ?1",
                params![pattern],
            )
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(affected)
    }

    /// 清空所有搜索结果
    pub fn clear_all(&self) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute("DELETE FROM searchBooks", [])
            .map_err(|e| LegadoError::Database(format!("清空失败: {e}")))?;
        Ok(affected)
    }
}

/// 分组字段是否包含目标组名（`,`/`;`/`，`/`；` 分隔，trim 后精确相等）
fn group_contains(group_field: &str, target: &str) -> bool {
    if target.is_empty() {
        return true;
    }
    group_field
        .split([',', ';', '，', '；'])
        .map(str::trim)
        .any(|g| g == target)
}

/// 将 rusqlite Row 转换为 SearchBook（前 18 列）
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

    fn make_repo_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.execute(
            "INSERT INTO book_sources (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight, enabled, bookSourceGroup, customOrder)
             VALUES ('origin1', '测试源', 0, 0, 0, 0, 1, '快速书源', 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO book_sources (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight, enabled, bookSourceGroup, customOrder)
             VALUES ('origin2', '源2', 0, 0, 0, 0, 1, '其他', 2)",
            [],
        )
        .unwrap();
        conn
    }

    fn make_book(url: &str, name: &str, author: &str, origin: &str) -> SearchBook {
        SearchBook {
            book_url: url.to_string(),
            origin: origin.to_string(),
            origin_name: "测试源".to_string(),
            name: name.to_string(),
            author: author.to_string(),
            ..SearchBook::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_keyword() {
        let conn = make_repo_conn();
        let repo = SearchBookRepository::new(&conn);
        let book = make_book("https://book.example.com/1", "斗破苍穹", "天蚕土豆", "origin1");
        repo.insert(&book).unwrap();
        let results = repo.find_by_keyword("斗破").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "斗破苍穹");
        assert_eq!(results[0].book_url, "https://book.example.com/1");
    }

    #[test]
    fn test_change_source_by_group_reuses_search_hits() {
        let conn = make_repo_conn();
        let repo = SearchBookRepository::new(&conn);
        repo.insert(&make_book("u1", "斗破苍穹", "天蚕土豆", "origin1"))
            .unwrap();
        repo.insert(&make_book("u2", "斗破苍穹", "天蚕土豆", "origin2"))
            .unwrap();
        repo.insert(&make_book("u3", "斗破苍穹", "别人", "origin1"))
            .unwrap();

        // 校验作者：仅同名同作者子集
        let with_author = repo
            .change_source_by_group("斗破苍穹", "天蚕土豆", "")
            .unwrap();
        assert_eq!(with_author.len(), 2);

        // 不校验作者：同名全部
        let all_name = repo.change_source_by_group("斗破苍穹", "", "").unwrap();
        assert_eq!(all_name.len(), 3);

        // 分组过滤
        let quick = repo
            .change_source_by_group("斗破苍穹", "天蚕土豆", "快速书源")
            .unwrap();
        assert_eq!(quick.len(), 1);
        assert_eq!(quick[0].origin, "origin1");
    }

    #[test]
    fn test_find_by_keyword_no_match() {
        let conn = make_repo_conn();
        let repo = SearchBookRepository::new(&conn);
        repo.insert(&make_book("u1", "斗破苍穹", "天蚕土豆", "origin1"))
            .unwrap();
        let results = repo.find_by_keyword("完美世界").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_delete_by_keyword() {
        let conn = make_repo_conn();
        let repo = SearchBookRepository::new(&conn);
        repo.insert(&make_book("u1", "斗破苍穹", "天蚕土豆", "origin1"))
            .unwrap();
        repo.insert(&make_book("u2", "斗破苍穹II", "天蚕土豆", "origin1"))
            .unwrap();
        repo.insert(&make_book("u3", "完美世界", "辰东", "origin1"))
            .unwrap();
        let deleted = repo.delete_by_keyword("斗破").unwrap();
        assert_eq!(deleted, 2);
        let remaining = repo.find_by_keyword("完美").unwrap();
        assert_eq!(remaining.len(), 1);
    }

    #[test]
    fn test_clear_all() {
        let conn = make_repo_conn();
        let repo = SearchBookRepository::new(&conn);
        repo.insert(&make_book("u1", "book1", "a", "origin1"))
            .unwrap();
        repo.insert(&make_book("u2", "book2", "a", "origin1"))
            .unwrap();
        let cleared = repo.clear_all().unwrap();
        assert_eq!(cleared, 2);
        assert!(repo.find_by_keyword("book").unwrap().is_empty());
    }
}
