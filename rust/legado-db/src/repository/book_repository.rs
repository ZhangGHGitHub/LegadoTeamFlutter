//! Book Repository - books 表 CRUD

use rusqlite::{params, Connection, OptionalExtension};

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

    /// 仅查询已入书架的书籍（过滤 notShelf 临时书）
    ///
    /// Task#125 P0：搜索/发现打开在线书阅读时会落库临时记录（打 NOT_SHELF 位），
    /// 书架列表须排除这些临时书，对齐上游 `BookDao.getBooksOnBookshelf()`（type & NOT_SHELF = 0）。
    pub fn find_all_in_shelf(&self) -> LegadoResult<Vec<Book>> {
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
                 FROM books WHERE (type & 1024) = 0 ORDER BY \"order\" ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let books = stmt
            .query_map([], row_to_book)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(books)
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

    /// 更新书籍的听书播放速度（局部列更新）
    ///
    /// 对齐上游 Kotlin `BookDao.updateAudioPlaySpeed()` 及 `withAudioPlayPreference()`：
    /// 仅改写 readConfig JSON 中的 `playSpeed` 键；若 readConfig 为空或非法 JSON，
    /// 则新建对象并预写入 `useGlobalAudioSkip = true`（与上游回退分支一致）。
    pub fn update_audio_play_speed(&self, book_url: &str, play_speed: f32) -> LegadoResult<()> {
        // 1. 读取当前 readConfig JSON
        let current = self.read_config_json(book_url)?;

        // 2. 解析现有 JSON；为空/非法时对齐上游新建分支（预置 useGlobalAudioSkip=true）
        let mut config: serde_json::Value = current
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .filter(|v| v.is_object())
            .unwrap_or_else(|| serde_json::json!({ "useGlobalAudioSkip": true }));

        // 3. 仅更新 playSpeed 键
        if let Some(obj) = config.as_object_mut() {
            obj.insert(
                "playSpeed".to_string(),
                serde_json::Value::Number(serde_json::Number::from_f64(f64::from(play_speed))
                    .unwrap_or_else(|| serde_json::Number::from(1))),
            );
        }

        // 4. 写回
        let updated_json = serde_json::to_string(&config)
            .map_err(|e| LegadoError::Database(format!("序列化 readConfig 失败: {e}")))?;
        self.conn
            .execute(
                "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                params![updated_json, book_url],
            )
            .map_err(|e| LegadoError::Database(format!("更新 playSpeed 失败: {e}")))?;
        Ok(())
    }

    /// 更新书籍但保留库内原有 readConfig（对齐上游 `BookDao.updatePreservingReadConfig`）
    ///
    /// 上游事务语义：先取库内 readConfig JSON → 执行全行 update → 再写回原 JSON，
    /// 使调用方传入的 readConfig 不会覆盖库内已有配置（如进度相关的听书设置）。
    pub fn update_preserving_read_config(&self, book: &Book) -> LegadoResult<()> {
        // 1. 读取库内当前 readConfig（保持 NULL 状态）
        let saved = self.read_config_json(&book.book_url)?;

        // 2. 全行原地更新（Task#125 P0：改用 update 原地 UPDATE，避免 insert 的
        //    INSERT OR REPLACE 删行触发 chapters ON DELETE CASCADE 清空目录）
        self.update(book)?;

        // 3. 写回原 readConfig，避免被传入值覆盖
        self.conn
            .execute(
                "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                params![saved, book.book_url],
            )
            .map_err(|e| LegadoError::Database(format!("写回 readConfig 失败: {e}")))?;
        Ok(())
    }

    /// 读取指定书籍的 readConfig 原始 JSON（不存在时返回 None）
    ///
    /// 对应 Kotlin `BookDao.getReadConfigJson()`
    fn read_config_json(&self, book_url: &str) -> LegadoResult<Option<String>> {
        // optional() 已包一层 Option（行不存在），列本身又可为 NULL，故用双层后 flatten
        let json: Option<Option<String>> = self
            .conn
            .query_row(
                "SELECT readConfig FROM books WHERE bookUrl = ?1",
                params![book_url],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询 readConfig 失败: {e}")))?;
        Ok(json.flatten())
    }

    /// 直接执行 INSERT OR REPLACE（供 insert/update 的插入分支复用）
    ///
    /// 仅用于「目标 bookUrl 行确定不存在」的场景：此时 REPLACE 至多替换
    /// (name, author) 唯一索引冲突的另一本书，不会删到自身行。
    fn insert_replace(&self, item: &Book) -> LegadoResult<()> {
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

    /// 同名同作者冲突时：迁移 chapters/相关表的 bookUrl，再替换 books 行（保目录）
    fn remap_book_url_preserving_chapters(
        &self,
        old_url: &str,
        item: &Book,
    ) -> LegadoResult<()> {
        let new_url = &item.book_url;
        if old_url == new_url {
            // 防御：同 URL 不应进入冲突路径，直接 REPLACE 字段
            return self.insert_replace(item);
        }
        // 临时关闭 FK，避免迁移瞬间外键失败；删除旧行时也不会 CASCADE 清 chapters
        self.conn
            .execute_batch("PRAGMA foreign_keys = OFF;")
            .map_err(|e| LegadoError::Database(format!("关闭外键失败: {e}")))?;
        let result = (|| -> LegadoResult<()> {
            self.conn
                .execute(
                    "UPDATE chapters SET bookUrl = ?1 WHERE bookUrl = ?2",
                    params![new_url, old_url],
                )
                .map_err(|e| LegadoError::Database(format!("迁移 chapters 失败: {e}")))?;
            let _ = self.conn.execute(
                "UPDATE highlights SET bookUrl = ?1 WHERE bookUrl = ?2",
                params![new_url, old_url],
            );
            let _ = self.conn.execute(
                "UPDATE cached_chapters SET book_url = ?1 WHERE book_url = ?2",
                params![new_url, old_url],
            );
            let _ = self.conn.execute(
                "UPDATE download_tasks SET book_url = ?1 WHERE book_url = ?2",
                params![new_url, old_url],
            );
            self.conn
                .execute("DELETE FROM books WHERE bookUrl = ?1", params![old_url])
                .map_err(|e| LegadoError::Database(format!("删除冲突书籍失败: {e}")))?;
            self.insert_replace(item)?;
            Ok(())
        })();
        self.conn
            .execute_batch("PRAGMA foreign_keys = ON;")
            .map_err(|e| LegadoError::Database(format!("恢复外键失败: {e}")))?;
        result
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
        // 台账 §5.14-3：根治 INSERT OR REPLACE 重复插入同 bookUrl 时先删旧行
        // 再插新行，触发 chapters ON DELETE CASCADE 级联删除（目录丢失）的隐患。
        // upsert 改为：先按主键判存在——存在则原地全列 UPDATE（不删行、不级联）；
        // 不存在则直接 INSERT OR REPLACE 入库。
        //
        // 注意 books 除主键 bookUrl 外还有二级唯一索引 index_books_name_author
        // (name, author)：主键不存在但 (name,author) 与他书冲突时，必须沿用
        // OR REPLACE 语义替换冲突行（对齐改造前行为）；不能用 OR IGNORE，
        // 否则 INSERT 被静默忽略而行从未创建。此时被替换的是另一 bookUrl 的
        // 旧行，与「同 bookUrl 重复插入不丢自身目录」的修复目标不冲突。
        let exists: bool = self
            .conn
            .query_row(
                "SELECT 1 FROM books WHERE bookUrl = ?1",
                params![item.book_url],
                |_| Ok(true),
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询书籍失败: {e}")))?
            .unwrap_or(false);

        if exists {
            // 行已存在：原地全列 UPDATE，新值覆盖语义与原 INSERT OR REPLACE
            // 一致；UPDATE 不删旧行，不会误触发 chapters 级联删除。
            return self.update(item);
        }
        // D5：二级索引 (name,author) 冲突预检——避免 INSERT OR REPLACE
        // 删掉另一 bookUrl 行并 CASCADE 清空其 chapters。
        if let Some(conflict) = self.find_by_name_author(&item.name, &item.author)? {
            if conflict.book_url != item.book_url {
                self.remap_book_url_preserving_chapters(&conflict.book_url, item)?;
                return Ok(());
            }
        }
        self.insert_replace(item)
    }

    fn update(&self, item: &Book) -> LegadoResult<()> {
        // Task#125 P0：update 改为原地 UPDATE，避免 INSERT OR REPLACE
        // 删除 books 行触发 chapters 的 ON DELETE CASCADE，导致翻章后目录被清空
        let read_config_json = item
            .read_config
            .as_ref()
            .map(|rc| serde_json::to_string(rc).unwrap_or_default());

        let affected = self
            .conn
            .execute(
                "UPDATE books SET
                    tocUrl=?1, origin=?2, originName=?3, name=?4, author=?5, kind=?6,
                    customTag=?7, coverUrl=?8, customCoverUrl=?9, intro=?10, customIntro=?11,
                    charset=?12, type=?13, \"group\"=?14, latestChapterTitle=?15,
                    latestChapterTime=?16, lastCheckTime=?17, lastCheckCount=?18,
                    totalChapterNum=?19, durChapterTitle=?20, durChapterIndex=?21,
                    durVolumeIndex=?22, chapterInVolumeIndex=?23, durChapterPos=?24,
                    durChapterTime=?25, wordCount=?26, canUpdate=?27, \"order\"=?28,
                    originOrder=?29, variable=?30, readConfig=?31, syncTime=?32,
                    infoHtml=?33, tocHtml=?34, downloadUrls=?35, coverOrigin=?36
                 WHERE bookUrl=?37",
                params![
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
                    item.book_url,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新失败: {e}")))?;

        // 行不存在时退化为插入，保留 upsert 语义（不会误触发级联删除，因为无旧行）。
        // 直接走 insert_replace 而非 self.insert()，与 insert 的 exists 分支互不
        // 回环，彻底切断 insert↔update 互递归（二级唯一索引 index_books_name_author
        // 冲突曾使 OR IGNORE 静默忽略 + UPDATE 零命中同时成立，导致无限递归）。
        if affected == 0 {
            self.insert_replace(item)?;
        }
        Ok(())
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

    /// update_audio_play_speed：仅更新 playSpeed，其他 readConfig 字段不受影响
    #[test]
    fn test_update_audio_play_speed_preserves_other_fields() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let mut book = make_book("u1", "n1", "a1");
        book.read_config = Some(legado_core::models::ReadConfig {
            reverse_toc: true,
            play_mode: 2,
            ..legado_core::models::ReadConfig::default()
        });
        repo.insert(&book).unwrap();

        repo.update_audio_play_speed("u1", 1.75).unwrap();

        let rc = repo.find_by_url("u1").unwrap().unwrap().read_config.unwrap();
        assert!((rc.play_speed - 1.75).abs() < f32::EPSILON);
        assert!(rc.reverse_toc);
        assert_eq!(rc.play_mode, 2);
    }

    /// update_audio_play_speed：readConfig 为空时新建对象并预置 useGlobalAudioSkip=true（对齐上游）
    #[test]
    fn test_update_audio_play_speed_creates_config_with_global_skip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let book = make_book("u1", "n1", "a1");
        assert!(book.read_config.is_none());
        repo.insert(&book).unwrap();

        repo.update_audio_play_speed("u1", 2.0).unwrap();

        let rc = repo.find_by_url("u1").unwrap().unwrap().read_config.unwrap();
        assert!((rc.play_speed - 2.0).abs() < f32::EPSILON);
        assert!(rc.use_global_audio_skip);
    }

    /// update_preserving_read_config：库内 readConfig 不被传入值覆盖
    #[test]
    fn test_update_preserving_read_config_keeps_db_config() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let mut book = make_book("u1", "n1", "a1");
        book.read_config = Some(legado_core::models::ReadConfig {
            reverse_toc: true,
            play_speed: 1.5,
            ..legado_core::models::ReadConfig::default()
        });
        repo.insert(&book).unwrap();

        // 传入带不同 readConfig 的更新；其他字段应生效，readConfig 保持库内原值
        let mut updated = book.clone();
        updated.name = "改名".to_string();
        updated.read_config = Some(legado_core::models::ReadConfig {
            reverse_toc: false,
            play_speed: 3.0,
            ..legado_core::models::ReadConfig::default()
        });
        repo.update_preserving_read_config(&updated).unwrap();

        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.name, "改名");
        let rc = found.read_config.unwrap();
        assert!(rc.reverse_toc);
        assert!((rc.play_speed - 1.5).abs() < f32::EPSILON);
    }

    /// update_preserving_read_config：库内 readConfig 为 NULL 时保持 NULL
    #[test]
    fn test_update_preserving_read_config_keeps_null() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        let book = make_book("u1", "n1", "a1");
        repo.insert(&book).unwrap();

        let mut updated = book.clone();
        updated.name = "改名".to_string();
        updated.read_config = Some(legado_core::models::ReadConfig {
            reverse_toc: true,
            ..legado_core::models::ReadConfig::default()
        });
        repo.update_preserving_read_config(&updated).unwrap();

        let found = repo.find_by_url("u1").unwrap().unwrap();
        assert_eq!(found.name, "改名");
        assert!(found.read_config.is_none());
    }

    /// 台账 §5.14-3：重复插入同一 bookUrl 不得触发 chapters 外键级联删除
    /// （原 INSERT OR REPLACE 会删旧行连带清空目录；修复后章节全量保留，
    /// 且新字段值照常覆盖，保留 upsert 语义）
    #[test]
    fn test_reinsert_same_book_url_keeps_chapters() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookRepository::new(conn);
        let book = make_book("u1", "书名", "作者");
        repo.insert(&book).unwrap();

        // 落库两章关联数据
        let ch_repo = crate::BookChapterRepository::new(conn);
        let chapters: Vec<legado_core::models::BookChapter> = (0..2)
            .map(|i| legado_core::models::BookChapter {
                url: format!("u1/ch{i}"),
                title: format!("第{i}章"),
                book_url: "u1".to_string(),
                base_url: "u1".to_string(),
                index: i,
                ..legado_core::models::BookChapter::default()
            })
            .collect();
        ch_repo.insert_batch(&chapters).unwrap();
        assert_eq!(ch_repo.find_by_book_url("u1").unwrap().len(), 2);

        // 重复插入同一 bookUrl（字段变更）
        let mut rebook = book.clone();
        rebook.name = "新书名".to_string();
        repo.insert(&rebook).unwrap();

        // 书籍仅一本，新字段值覆盖生效（upsert 语义保留）
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.find_by_url("u1").unwrap().unwrap().name, "新书名");

        // 关键：章节关联数据未丢失
        assert_eq!(
            ch_repo.find_by_book_url("u1").unwrap().len(),
            2,
            "重复插入不得触发 chapters 外键级联删除"
        );
    }

    /// D5 / §5.14-10：同名同作者不同 bookUrl 插入时预检迁移，目录不丢
    #[test]
    fn test_insert_name_author_conflict_keeps_chapters() {
        let db = crate::init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookRepository::new(conn);
        let book = make_book("https://old.example/book", "同名书", "同作者");
        repo.insert(&book).unwrap();

        let ch_repo = crate::BookChapterRepository::new(conn);
        let chapters: Vec<legado_core::models::BookChapter> = (0..2)
            .map(|i| legado_core::models::BookChapter {
                url: format!("old/ch{i}"),
                title: format!("第{i}章"),
                book_url: "https://old.example/book".to_string(),
                base_url: "https://old.example/book".to_string(),
                index: i,
                ..legado_core::models::BookChapter::default()
            })
            .collect();
        ch_repo.insert_batch(&chapters).unwrap();
        assert_eq!(
            ch_repo
                .find_by_book_url("https://old.example/book")
                .unwrap()
                .len(),
            2
        );

        let replacement = make_book("https://new.example/book", "同名书", "同作者");
        repo.insert(&replacement).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        assert!(repo.find_by_url("https://old.example/book").unwrap().is_none());
        assert!(repo.find_by_url("https://new.example/book").unwrap().is_some());
        assert_eq!(
            ch_repo
                .find_by_book_url("https://new.example/book")
                .unwrap()
                .len(),
            2,
            "name+author 冲突预检必须保留 chapters"
        );
    }
}
