//! Book Repository - books 表 CRUD

use rusqlite::{params, Connection};

use legado_core::models::Book;
use legado_core::{LegadoError, LegadoResult};

use super::Repository;

/// 书籍数据访问层
pub struct BookRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 根据 bookUrl 查询单本书籍
    pub fn find_by_url(&self, book_url: &str) -> LegadoResult<Option<Book>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookUrl, tocUrl, origin, originName, name, author, kind, customTag,
                        coverUrl, customCoverUrl, intro, customIntro, charset, type,
                        \"group\", latestChapterTitle, latestChapterTime, lastCheckTime,
                        lastCheckCount, totalChapterNum, durChapterTitle, durChapterIndex,
                        durVolumeIndex, chapterInVolumeIndex, durChapterPos, durChapterTime,
                        wordCount, canUpdate, \"order\", originOrder, variable, readConfig, syncTime,
                        infoHtml, tocHtml, downloadUrls, coverOrigin
                 FROM books WHERE bookUrl = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![book_url], row_to_book)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(book)) => Ok(Some(book)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 按名称和作者查询
    pub fn find_by_name_author(&self, name: &str, author: &str) -> LegadoResult<Option<Book>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookUrl, tocUrl, origin, originName, name, author, kind, customTag,
                        coverUrl, customCoverUrl, intro, customIntro, charset, type,
                        \"group\", latestChapterTitle, latestChapterTime, lastCheckTime,
                        lastCheckCount, totalChapterNum, durChapterTitle, durChapterIndex,
                        durVolumeIndex, chapterInVolumeIndex, durChapterPos, durChapterTime,
                        wordCount, canUpdate, \"order\", originOrder, variable, readConfig, syncTime,
                        infoHtml, tocHtml, downloadUrls, coverOrigin
                 FROM books WHERE name = ?1 AND author = ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![name, author], row_to_book)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(book)) => Ok(Some(book)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 删除指定 bookUrl 的书籍
    pub fn delete_by_url(&self, book_url: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM books WHERE bookUrl = ?1", params![book_url])
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(())
    }

    /// 获取书籍总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }

    /// 更新书籍的 readConfig JSON 字段中的指定键值
    ///
    /// 参考 Kotlin `BookDao.updateReadConfigJson()`
    pub fn update_read_config_field(
        &self,
        book_url: &str,
        key: &str,
        value: &serde_json::Value,
    ) -> LegadoResult<()> {
        // 1. 读取当前 readConfig JSON
        let current_str: Option<String> = self
            .conn
            .query_row(
                "SELECT readConfig FROM books WHERE bookUrl = ?1",
                params![book_url],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询 readConfig 失败: {e}")))?;

        // 2. 解析现有 JSON 或创建新对象
        let mut config: serde_json::Value = current_str
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| serde_json::Value::Object(serde_json::Map::new()));

        // 3. 合并新字段
        if let Some(obj) = config.as_object_mut() {
            obj.insert(key.to_string(), value.clone());
        } else {
            return Err(LegadoError::Database(
                "readConfig 不是 JSON 对象".to_string(),
            ));
        }

        // 4. 写回
        let updated_json = serde_json::to_string(&config)
            .map_err(|e| LegadoError::Database(format!("序列化 readConfig 失败: {e}")))?;

        self.conn
            .execute(
                "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                params![updated_json, book_url],
            )
            .map_err(|e| LegadoError::Database(format!("更新 readConfig 失败: {e}")))?;

        Ok(())
    }

    /// 更新书籍的听书播放模式
    ///
    /// 参考 Kotlin `BookDao.updateAudioPlayMode()`
    pub fn update_audio_play_mode(&self, book_url: &str, play_mode: i32) -> LegadoResult<()> {
        self.update_read_config_field(
            book_url,
            "playMode",
            &serde_json::Value::Number(play_mode.into()),
        )
    }
}

impl<'a> Repository<Book> for BookRepository<'a> {
    fn find_all(&self) -> LegadoResult<Vec<Book>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookUrl, tocUrl, origin, originName, name, author, kind, customTag,
                        coverUrl, customCoverUrl, intro, customIntro, charset, type,
                        \"group\", latestChapterTitle, latestChapterTime, lastCheckTime,
                        lastCheckCount, totalChapterNum, durChapterTitle, durChapterIndex,
                        durVolumeIndex, chapterInVolumeIndex, durChapterPos, durChapterTime,
                        wordCount, canUpdate, \"order\", originOrder, variable, readConfig, syncTime,
                        infoHtml, tocHtml, downloadUrls, coverOrigin
                 FROM books ORDER BY \"order\" ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let books = stmt
            .query_map([], row_to_book)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(books)
    }

    fn insert(&self, item: &Book) -> LegadoResult<()> {
        let read_config_json = item
            .read_config
            .as_ref()
            .map(|rc| serde_json::to_string(rc).unwrap_or_default());

        self.conn
            .execute(
                "INSERT OR REPLACE INTO books
             (bookUrl, tocUrl, origin, originName, name, author, kind, customTag,
              coverUrl, customCoverUrl, intro, customIntro, charset, type,
              \"group\", latestChapterTitle, latestChapterTime, lastCheckTime,
              lastCheckCount, totalChapterNum, durChapterTitle, durChapterIndex,
              durVolumeIndex, chapterInVolumeIndex, durChapterPos, durChapterTime,
              wordCount, canUpdate, \"order\", originOrder, variable, readConfig, syncTime,
              infoHtml, tocHtml, downloadUrls, coverOrigin)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,
                     ?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,
                     ?34,?35,?36,?37)",
                params![
                    item.book_url,
                    item.toc_url,
                    item.origin,
                    item.origin_name,
                    item.name,
                    item.author,
                    item.kind,
                    item.custom_tag,
                    item.cover_url,
                    item.custom_cover_url,
                    item.intro,
                    item.custom_intro,
                    item.charset,
                    item.book_type,
                    item.group,
                    item.latest_chapter_title,
                    item.latest_chapter_time,
                    item.last_check_time,
                    item.last_check_count,
                    item.total_chapter_num,
                    item.dur_chapter_title,
                    item.dur_chapter_index,
                    item.dur_volume_index,
                    item.chapter_in_volume_index,
                    item.dur_chapter_pos,
                    item.dur_chapter_time,
                    item.word_count,
                    item.can_update,
                    item.order,
                    item.origin_order,
                    item.variable,
                    read_config_json,
                    item.sync_time,
                    item.info_html,
                    item.toc_html,
                    item.download_urls,
                    item.cover_origin,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
        Ok(())
    }

    fn update(&self, item: &Book) -> LegadoResult<()> {
        // INSERT OR REPLACE 即可实现 upsert
        self.insert(item)
    }

    fn delete(&self, id: &str) -> LegadoResult<()> {
        self.delete_by_url(id)
    }
}

fn row_to_book(row: &rusqlite::Row<'_>) -> rusqlite::Result<Book> {
    let read_config_str: Option<String> = row.get(31)?;
    let read_config = read_config_str.and_then(|s| serde_json::from_str(&s).ok());

    Ok(Book {
        book_url: row.get(0)?,
        toc_url: row.get(1)?,
        origin: row.get(2)?,
        origin_name: row.get(3)?,
        name: row.get(4)?,
        author: row.get(5)?,
        kind: row.get(6)?,
        custom_tag: row.get(7)?,
        cover_url: row.get(8)?,
        custom_cover_url: row.get(9)?,
        intro: row.get(10)?,
        custom_intro: row.get(11)?,
        charset: row.get(12)?,
        book_type: row.get(13)?,
        group: row.get(14)?,
        latest_chapter_title: row.get(15)?,
        latest_chapter_time: row.get(16)?,
        last_check_time: row.get(17)?,
        last_check_count: row.get(18)?,
        total_chapter_num: row.get(19)?,
        dur_chapter_title: row.get(20)?,
        dur_chapter_index: row.get(21)?,
        dur_volume_index: row.get(22)?,
        chapter_in_volume_index: row.get(23)?,
        dur_chapter_pos: row.get(24)?,
        dur_chapter_time: row.get(25)?,
        word_count: row.get(26)?,
        can_update: row.get(27)?,
        order: row.get(28)?,
        origin_order: row.get(29)?,
        variable: row.get(30)?,
        read_config,
        sync_time: row.get(32)?,
        info_html: row.get(33)?,
        toc_html: row.get(34)?,
        download_urls: row.get(35)?,
        cover_origin: row.get(36)?,
    })
}

#[cfg(test)]
mod tests {
    use super::super::Repository;
    use super::*;

    fn make_book(url: &str, name: &str, author: &str) -> Book {
        Book {
            book_url: url.to_string(),
            name: name.to_string(),
            author: author.to_string(),
            ..Book::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let book = make_book("https://example.com/1", "测试", "作者");
        repo.insert(&book).unwrap();
        let found = repo.find_by_url("https://example.com/1").unwrap();
        assert!(found.is_some());
        let found = found.unwrap();
        assert_eq!(found.name, "测试");
        assert_eq!(found.author, "作者");
    }

    #[test]
    fn test_find_by_url_not_found() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let found = repo.find_by_url("nonexistent").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn test_find_by_name_author() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let book = make_book("url1", "书名", "作者名");
        repo.insert(&book).unwrap();
        let found = repo.find_by_name_author("书名", "作者名").unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().book_url, "url1");
    }

    #[test]
    fn test_count() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        assert_eq!(repo.count().unwrap(), 0);
        repo.insert(&make_book("u1", "n1", "a1")).unwrap();
        repo.insert(&make_book("u2", "n2", "a2")).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
    }

    #[test]
    fn test_delete_by_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        repo.insert(&make_book("u1", "n1", "a1")).unwrap();
        repo.delete_by_url("u1").unwrap();
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        repo.insert(&make_book("u1", "n1", "a1")).unwrap();
        repo.insert(&make_book("u2", "n2", "a2")).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_update_upsert() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let mut book = make_book("u1", "original", "a1");
        repo.insert(&book).unwrap();
        book.name = "updated".to_string();
        repo.update(&book).unwrap();
        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.name, "updated");
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_book_with_read_config() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let mut book = make_book("u1", "n1", "a1");
        book.read_config = Some(legado_core::models::ReadConfig {
            reverse_toc: true,
            ..legado_core::models::ReadConfig::default()
        });
        repo.insert(&book).unwrap();
        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert!(found.read_config.is_some());
        assert!(found.read_config.unwrap().reverse_toc);
    }

    #[test]
    fn test_update_read_config_field() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let mut book = make_book("u1", "n1", "a1");
        book.read_config = Some(legado_core::models::ReadConfig {
            reverse_toc: true,
            play_mode: 0,
            ..legado_core::models::ReadConfig::default()
        });
        repo.insert(&book).unwrap();

        // 更新 playMode 字段
        repo.update_read_config_field("u1", "playMode", &serde_json::json!(2))
            .unwrap();

        let found = repo.find_by_url("u1").unwrap().unwrap();
        let rc = found.read_config.unwrap();
        assert_eq!(rc.play_mode, 2);
        // reverse_toc 不受影响
        assert!(rc.reverse_toc);
    }

    #[test]
    fn test_update_audio_play_mode() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let book = make_book("u1", "n1", "a1");
        repo.insert(&book).unwrap();

        repo.update_audio_play_mode("u1", 3).unwrap();

        let found = repo.find_by_url("u1").unwrap().unwrap();
        let rc = found.read_config.unwrap();
        assert_eq!(rc.play_mode, 3);
    }
}
