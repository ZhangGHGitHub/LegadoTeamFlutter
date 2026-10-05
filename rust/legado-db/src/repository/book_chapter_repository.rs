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

    /// 根据 bookUrl + chapterUrl 查询指定章节（复合主键精确查找）
    ///
    /// 视频弹幕写入链（契约 §2.49）用：抓取链捕获的副内容按
    /// (bookUrl, chapterUrl) 落库，与 `chapters` 表复合主键
    /// `(url, bookUrl)` 对应，避免仅按 index 查找时的目录重排错位。
    pub fn find_by_book_url_and_chapter_url(
        &self,
        book_url: &str,
        chapter_url: &str,
    ) -> LegadoResult<Option<BookChapter>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,
                        resourceUrl, tag, wordCount, start, end, startFragmentId,
                        endFragmentId, variable, imgUrl
                 FROM chapters WHERE bookUrl = ?1 AND url = ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![book_url, chapter_url], row_to_chapter)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(ch)) => Ok(Some(ch)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 按 (书源 URL, 章节 URL) 反查书籍取址点（V-B1 §2.49 媒体副内容落库兜底）
    ///
    /// 目录链 `refresh_toc` 不经 fetcher 的「章节 → 书」进程内映射，正文
    /// 阶段按 (sourceUrl, chapterUrl) 反查 meta 未命中时用本查询兜底；
    /// `books.origin` 即书源 URL。命中多行（同源多书共用章节 URL）视为
    /// 歧义返回 `None`（宁可不落库也不串书）。
    pub fn find_book_url_by_source_and_chapter_url(
        &self,
        source_url: &str,
        chapter_url: &str,
    ) -> LegadoResult<Option<String>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT c.bookUrl FROM chapters c
                 JOIN books b ON b.bookUrl = c.bookUrl
                 WHERE c.url = ?1 AND b.origin = ?2
                 LIMIT 2",
            )
            .map_err(|e| LegadoError::Database(format!("准备反查失败: {e}")))?;
        let mut rows = stmt
            .query_map(params![chapter_url, source_url], |row| {
                row.get::<_, String>(0)
            })
            .map_err(|e| LegadoError::Database(format!("反查失败: {e}")))?;
        let mut found: Vec<String> = Vec::new();
        for row in rows.by_ref() {
            match row {
                Ok(url) => found.push(url),
                Err(e) => return Err(LegadoError::Database(format!("行解析失败: {e}"))),
            }
        }
        Ok(if found.len() == 1 { found.pop() } else { None })
    }

    /// 仅更新章节 `variable` 单列（对齐原版 `BookChapterDao.update` 写 variable
    /// 的语义，规避全行 INSERT OR REPLACE 风险）
    ///
    /// 视频弹幕写入链（契约 §2.49）用：`danmaku` 键在章节 variable JSON 中
    /// 合并后写回本列；返回是否实际命中行。方法口径对齐
    /// `BookSourceRepository::update_variable`（书源变量单列更新先例）。
    pub fn update_variable(
        &self,
        book_url: &str,
        chapter_url: &str,
        variable: &str,
    ) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE chapters SET variable = ?3 WHERE bookUrl = ?1 AND url = ?2",
                params![book_url, chapter_url, variable],
            )
            .map_err(|e| LegadoError::Database(format!("章节变量更新失败: {e}")))?;
        Ok(affected > 0)
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

    /// 回填章节字数（[P2-28b]，对齐原版 BookChapterDao.upWordCount：
    /// `update chapters set wordCount = :wordCount where bookUrl = :bookUrl and url = :url`）
    ///
    /// 调用方：正文缓存写入成功后 / 缓存命中且 wordCount 为空时的惰性自愈
    /// （reader.rs `save_chapter_cache` / `fetch_chapter_content_inner` 命中路径），
    /// 写入值由调用方按原版 `StringUtils.wordCountFormat` 语义格式化后传入。
    ///
    /// 返回受影响行数（0 = 无匹配章节行，非错误——该章不在目录中时无需回填）。
    /// 方法顺序与原版一致（bookUrl, url, wordCount）。
    pub fn up_word_count(
        &self,
        book_url: &str,
        chapter_url: &str,
        word_count: &str,
    ) -> LegadoResult<u64> {
        let affected = self
            .conn
            .execute(
                "UPDATE chapters SET wordCount = ?3 WHERE bookUrl = ?1 AND url = ?2",
                params![book_url, chapter_url, word_count],
            )
            .map_err(|e| LegadoError::Database(format!("字数回填失败: {e}")))?;
        Ok(affected as u64)
    }

    /// 该章 wordCount 是否为空（NULL/空白）——[P2-28b] 存量惰性自愈判据
    ///
    /// 缓存命中返回路径调用：章节行存在但 wordCount 为空（旧版本写入的缓存，
    /// 早于回填链引入）时返回 true，调用方据此按缓存正文长度补算回填一次；
    /// 章节行不存在返回 false（目录里没有该章，无需也无从回填）。
    pub fn word_count_missing(&self, book_url: &str, chapter_url: &str) -> LegadoResult<bool> {
        let mut stmt = self
            .conn
            .prepare("SELECT wordCount FROM chapters WHERE bookUrl = ?1 AND url = ?2")
            .map_err(|e| LegadoError::Database(format!("准备字数查询失败: {e}")))?;
        let mut rows = stmt
            .query_map(params![book_url, chapter_url], |row| {
                row.get::<_, Option<String>>(0)
            })
            .map_err(|e| LegadoError::Database(format!("字数查询失败: {e}")))?;
        Ok(match rows.next() {
            Some(Ok(Some(wc))) => wc.trim().is_empty(),
            Some(Ok(None)) => true,
            Some(Err(e)) => return Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => false,
        })
    }

    /// 删除指定书籍的所有章节
    ///
    /// [B-7] 删旧目录 + 写新目录必须包在**同一事务**（先例：换源事务
    /// source_switch.rs `unchecked_transaction()` + `insert_batch_no_tx`）：
    /// 裸 autocommit 删除与后续批量插入之间，并发读者（另一池连接）能
    /// 观察到该书「0 章」中间态（并发翻章报「章节不存在」、目录为空）。
    /// 因此本方法在**事务外**（autocommit）是 no-op 并告警，强制调用方
    /// 在 `unchecked_transaction()` 内调用；事务内正常执行删除。
    /// 调用方审计：换源事务（事务内✓）、refresh_toc 重写（已包事务）、
    /// legado-server toc_update（已包事务）、各 cfg(test) 清理段（no-op
    /// 无害，测试库按用例隔离/全新）均不受损。
    pub fn delete_by_book_url(&self, book_url: &str) -> LegadoResult<()> {
        // rusqlite 0.31 无 in_transaction()（0.32 才有）；is_autocommit()==false
        // 即处于显式事务内（unchecked_transaction() 的 BEGIN 已生效）
        if self.conn.is_autocommit() {
            eprintln!(
                "[B-7] delete_by_book_url 在事务外被调用（bookUrl={book_url}）：\
                 已跳过删除（no-op），避免向并发读者暴露「0 章」中间态；\
                 请改用 unchecked_transaction() 包裹删除+写入"
            );
            return Ok(());
        }
        self.conn
            .execute("DELETE FROM chapters WHERE bookUrl = ?1", params![book_url])
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(())
    }

    /// 批量插入章节（使用事务提高性能）
    ///
    /// 内部自开一个事务保证批量插入的原子性，适用于独立调用场景。
    /// 若调用方已处于外层事务中（如换源流程），请改用
    /// [`Self::insert_batch_no_tx`]，避免嵌套 `BEGIN` 触发
    /// "cannot start a transaction within a transaction" 错误。
    pub fn insert_batch(&self, chapters: &[BookChapter]) -> LegadoResult<()> {
        let tx = self
            .conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启事务失败: {e}")))?;

        // 复用无事务版本执行实际插入，保持单一 SQL 实现
        self.insert_batch_no_tx(chapters)?;

        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交事务失败: {e}")))?;
        Ok(())
    }

    /// 批量插入章节（不自开事务版本）
    ///
    /// 直接在 `self.conn` 上执行插入，不发起 `BEGIN`/`COMMIT`。
    /// 供已由外层持有事务的调用方复用（如换源流程 source_switch），
    /// 使清缓存+删旧章节+写新章节能包裹进同一个 DB 事务，中途失败整体回滚。
    pub fn insert_batch_no_tx(&self, chapters: &[BookChapter]) -> LegadoResult<()> {
        let mut stmt = self
            .conn
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
    fn test_find_by_book_url_and_chapter_url() {
        let db = crate::init_in_memory_database().unwrap();
        insert_parent_book(db.connection(), "book1");
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&make_chapter("book1", 0, "第1章")).unwrap();
        repo.insert(&make_chapter("book1", 5, "第6章")).unwrap();

        let ch = repo
            .find_by_book_url_and_chapter_url("book1", "book1/ch5")
            .unwrap()
            .expect("复合键应命中第6章");
        assert_eq!(ch.index, 5);
        assert_eq!(ch.title, "第6章");

        // 未命中章节 / 未命中书 → None（不报错）
        assert!(repo
            .find_by_book_url_and_chapter_url("book1", "book1/ch9")
            .unwrap()
            .is_none());
        assert!(repo
            .find_by_book_url_and_chapter_url("book2", "book1/ch0")
            .unwrap()
            .is_none());
    }

    /// [V-B1 §2.49] 按 (书源, 章节 URL) 反查书籍取址点：唯一命中 → Some；
    /// 同源多书共用章节 URL → 歧义 None；无匹配 → None
    #[test]
    fn test_find_book_url_by_source_and_chapter_url() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookChapterRepository::new(conn);

        // book1（origin = src1）与 book2（origin = src2）
        let book1 = Book {
            book_url: "book1".to_string(),
            origin: "src1".to_string(),
            name: "书1".to_string(),
            ..Book::default()
        };
        BookRepository::new(conn).insert(&book1).unwrap();
        let book2 = Book {
            book_url: "book2".to_string(),
            origin: "src2".to_string(),
            name: "书2".to_string(),
            ..Book::default()
        };
        BookRepository::new(conn).insert(&book2).unwrap();

        let mut ch1 = make_chapter("book1", 0, "第1章");
        ch1.url = "https://sp.example/ch/1".to_string();
        repo.insert(&ch1).unwrap();
        // book2 的另一章 URL 不同
        let mut ch2 = make_chapter("book2", 0, "第1章");
        ch2.url = "https://sp.example/ch/2".to_string();
        repo.insert(&ch2).unwrap();

        assert_eq!(
            repo.find_book_url_by_source_and_chapter_url("src1", "https://sp.example/ch/1")
                .unwrap()
                .as_deref(),
            Some("book1"),
            "唯一命中应返回 bookUrl"
        );
        // 书源不匹配 / 章节 URL 不存在 → None
        assert_eq!(
            repo.find_book_url_by_source_and_chapter_url("src2", "https://sp.example/ch/1")
                .unwrap(),
            None
        );
        assert_eq!(
            repo.find_book_url_by_source_and_chapter_url("src1", "https://sp.example/none")
                .unwrap(),
            None
        );

        // 歧义：book3（origin = src1）与 book1 共用同一章节 URL → None
        let book3 = Book {
            book_url: "book3".to_string(),
            origin: "src1".to_string(),
            name: "书3".to_string(),
            ..Book::default()
        };
        BookRepository::new(conn).insert(&book3).unwrap();
        let mut ch3 = make_chapter("book3", 0, "第1章");
        ch3.url = "https://sp.example/ch/1".to_string();
        repo.insert(&ch3).unwrap();
        assert_eq!(
            repo.find_book_url_by_source_and_chapter_url("src1", "https://sp.example/ch/1")
                .unwrap(),
            None,
            "同源多书共用章节 URL 属歧义，应返回 None（不得串书）"
        );
    }

    /// [V-B1 §2.49] update_variable 单列更新：命中行写回且可回读；
    /// 未命中返回 false 不报错（不产生新行）
    #[test]
    fn test_update_variable() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        let repo = BookChapterRepository::new(conn);
        repo.insert(&make_chapter("book1", 0, "第1章")).unwrap();

        assert!(repo
            .update_variable("book1", "book1/ch0", r#"{"danmaku":"<xml/>"}"#)
            .unwrap());
        let saved = repo
            .find_by_book_url_and_chapter_url("book1", "book1/ch0")
            .unwrap()
            .unwrap();
        assert_eq!(saved.variable.as_deref(), Some(r#"{"danmaku":"<xml/>"}"#));

        // 未命中章节 → false（仅影响行数为 0，非错误）
        assert!(!repo
            .update_variable("book1", "book1/ch9", r#"{"a":"b"}"#)
            .unwrap());
        assert!(!repo
            .update_variable("no-such-book", "book1/ch0", r#"{"a":"b"}"#)
            .unwrap());
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

    /// [P2-28b] up_word_count 回填：命中行更新且可回读；未命中返回 0 不报错
    #[test]
    fn test_up_word_count() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        let repo = BookChapterRepository::new(conn);
        repo.insert(&make_chapter("book1", 0, "第1章")).unwrap();

        assert_eq!(
            repo.up_word_count("book1", "book1/ch0", "12字").unwrap(),
            1,
            "命中章节的行数回填应影响 1 行"
        );
        let saved = repo
            .find_by_book_url_and_index("book1", 0)
            .unwrap()
            .unwrap();
        assert_eq!(saved.word_count.as_deref(), Some("12字"));

        // 未命中章节 / 未命中书 → 0 行受影响，非错误（对齐原版 upWordCount 静默语义）
        assert_eq!(repo.up_word_count("book1", "book1/ch9", "1字").unwrap(), 0);
        assert_eq!(
            repo.up_word_count("no-such-book", "book1/ch0", "1字")
                .unwrap(),
            0
        );
    }

    /// [P2-28b] word_count_missing：NULL/空白 → true；有值 → false；
    /// 行不存在 → false（目录里没有该章，无需也无从回填）
    #[test]
    fn test_word_count_missing() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        let repo = BookChapterRepository::new(conn);
        repo.insert(&make_chapter("book1", 0, "ch0")).unwrap(); // 默认 wordCount 为 NULL
        let mut full = make_chapter("book1", 1, "ch1");
        full.word_count = Some("3400字".to_string());
        repo.insert(&full).unwrap();
        let mut blank = make_chapter("book1", 2, "ch2");
        blank.word_count = Some("  ".to_string()); // 空白同样判为空
        repo.insert(&blank).unwrap();

        assert!(
            repo.word_count_missing("book1", "book1/ch0").unwrap(),
            "NULL wordCount 应判为空"
        );
        assert!(
            repo.word_count_missing("book1", "book1/ch2").unwrap(),
            "空白 wordCount 应判为空"
        );
        assert!(
            !repo.word_count_missing("book1", "book1/ch1").unwrap(),
            "有值 wordCount 不应判为空"
        );
        assert!(!repo.word_count_missing("book1", "book1/ch9").unwrap());
        assert!(!repo
            .word_count_missing("no-such-book", "book1/ch0")
            .unwrap());
    }

    /// [P2-28b] 失败形态：缺 chapters 表时回填/判空均 Err（调用方须降级告警，
    /// 不得传播影响正文返回——对应 reader 层「回填失败不影响正文」要求）
    #[test]
    fn test_word_count_ops_fail_without_chapters_table() {
        // 裸内存连接无 schema → "no such table: chapters"
        let bare = rusqlite::Connection::open_in_memory().unwrap();
        let repo = BookChapterRepository::new(&bare);
        assert!(repo.up_word_count("b", "u", "1字").is_err());
        assert!(repo.word_count_missing("b", "u").is_err());
    }

    #[test]
    fn test_delete_by_book_url() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        insert_parent_book(conn, "book2");
        let repo = BookChapterRepository::new(conn);
        repo.insert(&make_chapter("book1", 0, "ch0")).unwrap();
        repo.insert(&make_chapter("book1", 1, "ch1")).unwrap();
        repo.insert(&make_chapter("book2", 0, "ch0")).unwrap();
        // [B-7] delete_by_book_url 事务外为 no-op（防「0 章」中间态），
        // 删除须包事务（与换源/refresh_toc 事务同款 unchecked_transaction 模式）
        let tx = conn.unchecked_transaction().unwrap();
        repo.delete_by_book_url("book1").unwrap();
        tx.commit().unwrap();
        assert_eq!(repo.count_by_book_url("book1").unwrap(), 0);
        assert_eq!(repo.count_by_book_url("book2").unwrap(), 1);
    }

    /// [B-7] 事务外裸调用 delete_by_book_url 是 no-op（不删章、不报错）
    #[test]
    fn test_delete_by_book_url_noop_outside_transaction() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        let repo = BookChapterRepository::new(conn);
        repo.insert(&make_chapter("book1", 0, "ch0")).unwrap();
        // 无外层事务 → no-op，章节仍在
        repo.delete_by_book_url("book1").unwrap();
        assert_eq!(
            repo.count_by_book_url("book1").unwrap(),
            1,
            "事务外删除应 no-op（防并发读者看到 0 章中间态）"
        );
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

    /// Task #19 补强1：换源事务失败应整体回滚，保留原章节
    ///
    /// 模拟 source_switch 的"删旧章节 + 写新章节"包事务：先删除 book1
    /// 的旧章节，再写入一条引用不存在父书的章节→触发外键约束失败。
    /// 事务未 commit，drop 时回滚，原 2 章节应仍在（不会留下"无章节"状态）。
    #[test]
    fn test_source_switch_tx_rollback_preserves_chapters() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        let repo = BookChapterRepository::new(conn);
        repo.insert_batch(&[
            make_chapter("book1", 0, "第1章"),
            make_chapter("book1", 1, "第2章"),
        ])
        .unwrap();
        assert_eq!(repo.count_by_book_url("book1").unwrap(), 2);

        // 包事务执行：删旧章节 + 写新章节（引用不存在的 book_ghost 触发 FK 失败）
        let result: LegadoResult<()> = (|| {
            let tx = conn
                .unchecked_transaction()
                .map_err(|e| LegadoError::Database(format!("开启事务失败: {e}")))?;
            repo.delete_by_book_url("book1")?;
            repo.insert_batch_no_tx(&[make_chapter("book_ghost", 0, "坏章节")])?;
            tx.commit()
                .map_err(|e| LegadoError::Database(format!("提交失败: {e}")))?;
            Ok(())
        })();
        assert!(result.is_err(), "写入引用不存在父书的章节应因外键约束失败");

        // 事务未提交，drop 时回滚，原 2 章节保留
        assert_eq!(
            repo.count_by_book_url("book1").unwrap(),
            2,
            "事务回滚后应保留原章节"
        );
    }

    /// Task #19 补强1：外层事务内调用 insert_batch_no_tx 不报嵌套 BEGIN
    ///
    /// 验证无事务版本可安全地在已有事务内复用，并在 commit 后生效。
    #[test]
    fn test_insert_batch_no_tx_within_outer_tx() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        insert_parent_book(conn, "book1");
        let repo = BookChapterRepository::new(conn);

        let tx = conn.unchecked_transaction().unwrap();
        repo.insert_batch_no_tx(&[
            make_chapter("book1", 0, "c0"),
            make_chapter("book1", 1, "c1"),
        ])
        .unwrap();
        tx.commit().unwrap();

        assert_eq!(repo.count_by_book_url("book1").unwrap(), 2);
    }
}
