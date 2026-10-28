//! ReadRecord Repository - readRecord 表 CRUD（schema v113）
//!
//! v113 起主键为 `(deviceId, bookName, author)`（对齐原版 Room schema 113.json）：
//! 同设备同名书按作者分行记录，写入侧**不再合并作者**。历史遗留的合并作者串
//! （`\u{1E}authors:[...]`，旧版「同书不同作者共用一条记录」的产物）在迁移时
//! 原样保留，仅由 [`decode_read_record_authors`] 解码用于展示/搜索标识。

use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 旧合并作者串前缀（仅解码历史数据，写入侧不再产生）
const AUTHORS_PREFIX: &str = "\u{1E}authors:";

/// readRecord 全列（顺序与建表语句一致，供 SELECT/INSERT 复用）
const COLUMNS: &str = "deviceId, bookName, author, readTime, lastRead, lastChapterTitle, \
                       lastChapterIndex, lastChapterPos, coverUrl, resolvedAuthor, \
                       displayBookName, displayAuthor, metadataEditedAt";

/// 阅读记录（13 字段，对齐原版 Room v113 `ReadRecord` 实体）
///
/// serde 键名对齐 Room 列/原版备份 `readRecord.json`（camelCase）；`alias` 兼容
/// 历史备份的 snake_case 旧键（备份格式 v1 时期由仓库结构体无 rename 直出，
/// `device_id`/`book_name`/`read_time`/`last_read` 四键），恢复时双形态均可解析。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadRecord {
    /// 设备标识（单设备模型下本机固定空串）
    #[serde(default, rename = "deviceId", alias = "device_id")]
    pub device_id: String,
    #[serde(default, rename = "bookName", alias = "book_name")]
    pub book_name: String,
    /// 作者（v113 起为物理主键的一部分；旧合并串原样保留）
    #[serde(default)]
    pub author: String,
    #[serde(default, rename = "readTime", alias = "read_time")]
    pub read_time: i64,
    /// 最后阅读时间（毫秒时间戳）
    #[serde(default, rename = "lastRead", alias = "last_read")]
    pub last_read: i64,
    /// 最后阅读章节标题快照（书架删除后仍可展示）
    #[serde(default, rename = "lastChapterTitle")]
    pub last_chapter_title: Option<String>,
    /// 最后阅读章节索引快照（-1 表示未知）
    #[serde(default = "default_chapter_index", rename = "lastChapterIndex")]
    pub last_chapter_index: i32,
    /// 最后阅读章节内位置快照
    #[serde(default, rename = "lastChapterPos")]
    pub last_chapter_pos: i32,
    /// 封面 URL 快照（本地缓存路径或网络 URL）
    #[serde(default, rename = "coverUrl")]
    pub cover_url: Option<String>,
    /// 旧备份中作者为空时还原出的作者（保持空白作者账户稳定）
    #[serde(default, rename = "resolvedAuthor")]
    pub resolved_author: Option<String>,
    /// 显示书名（用户编辑后的展示值；空串回退 bookName）
    #[serde(default, rename = "displayBookName")]
    pub display_book_name: String,
    /// 显示作者（用户编辑后的展示值；空串回退 author/resolvedAuthor）
    #[serde(default, rename = "displayAuthor")]
    pub display_author: String,
    /// 显示元数据最后编辑时间（毫秒；0 表示未编辑，恢复时按物理键派生显示值）
    #[serde(default, rename = "metadataEditedAt")]
    pub metadata_edited_at: i64,
}

/// `lastChapterIndex` 的 serde 默认值（对齐原版实体 `-1`）
fn default_chapter_index() -> i32 {
    -1
}

impl Default for ReadRecord {
    fn default() -> Self {
        Self {
            device_id: String::new(),
            book_name: String::new(),
            author: String::new(),
            read_time: 0,
            last_read: 0,
            last_chapter_title: None,
            last_chapter_index: -1,
            last_chapter_pos: 0,
            cover_url: None,
            resolved_author: None,
            display_book_name: String::new(),
            display_author: String::new(),
            metadata_edited_at: 0,
        }
    }
}

impl ReadRecord {
    /// 归一显示元数据（对齐上游 `ReadRecord.withDisplayMetadata`）
    ///
    /// - `metadata` 有编辑（`metadataEditedAt > 0`）且不旧于当前记录 → 采用其显示值；
    /// - 否则若当前已有编辑 → 保留当前显示值；
    /// - 都未编辑过 → 按物理键派生：`displayBookName = bookName`，
    ///   `displayAuthor = author`（为空时回落 `resolvedAuthor`）。
    pub fn with_display_metadata(mut self, metadata: Option<&Self>) -> Self {
        let edited = metadata.filter(|m| {
            m.metadata_edited_at > 0 && m.metadata_edited_at >= self.metadata_edited_at
        });
        let (book, author, edited_at) = match edited {
            Some(source) => (
                source.display_book_name.clone(),
                source.display_author.clone(),
                source.metadata_edited_at,
            ),
            None if self.metadata_edited_at > 0 => (
                self.display_book_name.clone(),
                self.display_author.clone(),
                self.metadata_edited_at,
            ),
            None => (
                self.book_name.clone(),
                if self.author.is_empty() {
                    self.resolved_author.clone().unwrap_or_default()
                } else {
                    self.author.clone()
                },
                0,
            ),
        };
        self.display_book_name = book;
        self.display_author = author;
        self.metadata_edited_at = edited_at;
        self
    }
}

/// 解码 author 列值为作者列表（对齐上游 `ReadRecordAuthors.decode`）
///
/// - 空白值返回空列表（上游返回 {""}，合并/匹配时会被非空过滤，等价）；
/// - 无前缀视为单一作者；
/// - 前缀后 JSON 解析失败时返回空列表（上游 getOrNull 后同样被过滤）。
///
/// 公开供上层构建阅读记录索引使用（如搜索结果阅读记录标识，
/// 对齐上游 `ReadRecordIndex.of` 对 author 列的解码）。
pub fn decode_read_record_authors(value: &str) -> Vec<String> {
    if value.trim().is_empty() {
        return Vec::new();
    }
    if let Some(json) = value.strip_prefix(AUTHORS_PREFIX) {
        serde_json::from_str::<Vec<String>>(json)
            .map(|arr| {
                let mut out: Vec<String> = Vec::new();
                for a in arr {
                    // 保持插入顺序并去重（上游 linkedSetOf 语义）
                    if !a.trim().is_empty() && !out.contains(&a) {
                        out.push(a);
                    }
                }
                out
            })
            .unwrap_or_default()
    } else {
        vec![value.to_string()]
    }
}

/// 恢复合并（对齐上游 `mergeRestoredReadRecord`，`ReadRecordMerge.kt`）
///
/// `current` 为库内同主键记录（物理键 `deviceId/bookName/author` 相同）：
/// - 章节快照取 `lastRead` 较新者（其无快照时回退另一侧）；
/// - `readTime`：本机记录取两侧最大（防旧备份回滚时长），他机记录以传入为准；
/// - `lastRead` 取两侧最大；`coverUrl` 取较新者非空值，否则回退另一侧；
/// - `resolvedAuthor` 优先保留库内值；显示元数据按 `metadataEditedAt` 选择。
pub fn merge_restored_read_record(
    current: Option<&ReadRecord>,
    incoming: &ReadRecord,
    local_device: bool,
) -> ReadRecord {
    let Some(current) = current else {
        return incoming.clone().with_display_metadata(None);
    };
    // 物理键不同（调用方按主键查找，理论不会发生）：直接采用传入记录
    if current.device_id != incoming.device_id
        || current.book_name != incoming.book_name
        || current.author != incoming.author
    {
        return incoming.clone().with_display_metadata(None);
    }

    let (latest, previous) = if incoming.last_read >= current.last_read {
        (incoming, current)
    } else {
        (current, incoming)
    };
    let chapter = if latest.last_chapter_index >= 0
        || latest
            .last_chapter_title
            .as_deref()
            .is_some_and(|title| !title.trim().is_empty())
    {
        latest
    } else {
        previous
    };
    let cover_url = latest
        .cover_url
        .as_deref()
        .filter(|url| !url.trim().is_empty())
        .map(str::to_string)
        .or_else(|| previous.cover_url.clone());

    let mut merged = incoming.clone();
    merged.read_time = if local_device {
        current.read_time.max(incoming.read_time)
    } else {
        incoming.read_time
    };
    merged.last_read = current.last_read.max(incoming.last_read);
    merged.last_chapter_title = chapter.last_chapter_title.clone();
    merged.last_chapter_index = chapter.last_chapter_index;
    merged.last_chapter_pos = chapter.last_chapter_pos;
    merged.cover_url = cover_url;
    merged.resolved_author = current
        .resolved_author
        .clone()
        .or_else(|| incoming.resolved_author.clone());
    merged.with_display_metadata(Some(current))
}

/// 行 → 记录
fn record_from_row(row: &Row<'_>) -> rusqlite::Result<ReadRecord> {
    Ok(ReadRecord {
        device_id: row.get(0)?,
        book_name: row.get(1)?,
        author: row.get(2)?,
        read_time: row.get(3)?,
        last_read: row.get(4)?,
        last_chapter_title: row.get(5)?,
        last_chapter_index: row.get(6)?,
        last_chapter_pos: row.get(7)?,
        cover_url: row.get(8)?,
        resolved_author: row.get(9)?,
        display_book_name: row.get(10)?,
        display_author: row.get(11)?,
        metadata_edited_at: row.get(12)?,
    })
}

/// 阅读记录数据访问层
pub struct ReadRecordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ReadRecordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 本机 deviceId（Rust 侧单设备固定空串）
    pub const LOCAL_DEVICE_ID: &'static str = "";

    /// 添加/更新阅读记录（FFI 既有签名：只带书名与时长）
    ///
    /// 定位该书的「主记录」后只更新其 `readTime`：
    /// 优先 `author = ''` 的旧式本机记录，其次 `lastRead` 最新的一行。
    /// 不存在的书按本机空作者新建（`author=''`）。快照/显示字段保持不变。
    pub fn upsert(&self, book_name: &str, read_time: i64) -> LegadoResult<()> {
        match self.primary_record(book_name)? {
            Some(existing) => {
                self.conn
                    .execute(
                        "UPDATE readRecord SET readTime = ?1
                         WHERE deviceId = ?2 AND bookName = ?3 AND author = ?4",
                        params![
                            read_time,
                            existing.device_id,
                            existing.book_name,
                            existing.author
                        ],
                    )
                    .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
            }
            None => self.insert_local_row(book_name, "", read_time)?,
        }
        Ok(())
    }

    /// 添加/更新阅读记录（全字段版，覆盖 deviceId/author/lastRead）
    ///
    /// 主键冲突时只更新 `readTime/lastRead`，**保留**章节快照/封面/显示元数据
    /// （旧实现用 INSERT OR REPLACE 会把 v113 新列清空，每次保存阅读进度即丢快照）。
    pub fn upsert_full(
        &self,
        device_id: &str,
        book_name: &str,
        author: &str,
        read_time: i64,
        last_read: i64,
    ) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT INTO readRecord
                 (deviceId, bookName, author, readTime, lastRead, displayBookName, displayAuthor)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?2, CASE WHEN ?3 = '' THEN '' ELSE ?3 END)
                 ON CONFLICT(deviceId, bookName, author) DO UPDATE SET
                   readTime = excluded.readTime,
                   lastRead = excluded.lastRead",
                params![device_id, book_name, author, read_time, last_read],
            )
            .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 新增/更新本机某作者记录（按新主键 upsert，不做作者合并）
    ///
    /// 主键冲突时只更新 `readTime`，保留 `lastRead` 与快照字段。
    pub fn insert_with_author(
        &self,
        book_name: &str,
        author: &str,
        read_time: i64,
    ) -> LegadoResult<()> {
        self.insert_local_row(book_name, author, read_time)
    }

    /// 本机记录 upsert（仅 `readTime`，保留其余列）
    fn insert_local_row(&self, book_name: &str, author: &str, read_time: i64) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT INTO readRecord
                 (deviceId, bookName, author, readTime, displayBookName, displayAuthor)
                 VALUES ('', ?1, ?2, ?3, ?1, ?2)
                 ON CONFLICT(deviceId, bookName, author) DO UPDATE SET
                   readTime = excluded.readTime",
                params![book_name, author, read_time],
            )
            .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 备份恢复写入（对齐原版 `Restore.kt` + `mergeRestoredReadRecord`）
    ///
    /// 按物理主键 `(deviceId, bookName, author)` 查找库内记录：
    /// 无同键记录 → 直接整行写入；有 → 按 [`merge_restored_read_record`] 合并后
    /// 整行 REPLACE。`local_device = deviceId == ''`（Rust 单设备模型）。
    ///
    /// 供备份恢复使用；不触碰 readRecordDaily 热力图聚合面（恢复不产生阅读时长）。
    pub fn upsert_restore(&self, record: &ReadRecord) -> LegadoResult<()> {
        let current = self.get_by_pk(&record.device_id, &record.book_name, &record.author)?;
        let merged = merge_restored_read_record(
            current.as_ref(),
            record,
            record.device_id == Self::LOCAL_DEVICE_ID,
        );
        self.write_row(&merged)
    }

    /// 整行写入（13 列，主键冲突时整行替换）
    pub fn write_row(&self, record: &ReadRecord) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO readRecord
                 (deviceId, bookName, author, readTime, lastRead, lastChapterTitle,
                  lastChapterIndex, lastChapterPos, coverUrl, resolvedAuthor,
                  displayBookName, displayAuthor, metadataEditedAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    record.device_id,
                    record.book_name,
                    record.author,
                    record.read_time,
                    record.last_read,
                    record.last_chapter_title,
                    record.last_chapter_index,
                    record.last_chapter_pos,
                    record.cover_url,
                    record.resolved_author,
                    record.display_book_name,
                    record.display_author,
                    record.metadata_edited_at
                ],
            )
            .map_err(|e| LegadoError::Database(format!("写入阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 按完整主键 `(deviceId, bookName, author)` 查询记录
    pub fn get_by_pk(
        &self,
        device_id: &str,
        book_name: &str,
        author: &str,
    ) -> LegadoResult<Option<ReadRecord>> {
        let sql = format!(
            "SELECT {COLUMNS} FROM readRecord
             WHERE deviceId = ?1 AND bookName = ?2 AND author = ?3"
        );
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let record = stmt
            .query_row(params![device_id, book_name, author], record_from_row)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(record)
    }

    /// 该书的「主记录」：同书多作者时优先 `author = ''` 的旧式本机行，
    /// 其次 `lastRead` 最新者（无匹配返回 `None`）
    fn primary_record(&self, book_name: &str) -> LegadoResult<Option<ReadRecord>> {
        let sql = format!(
            "SELECT {COLUMNS} FROM readRecord WHERE bookName = ?1
             ORDER BY (author = '') DESC, lastRead DESC, readTime DESC
             LIMIT 1"
        );
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let record = stmt
            .query_row(params![book_name], record_from_row)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(record)
    }

    /// 更新指定书籍主记录的最后阅读时间（lastRead 列）
    pub fn update_last_read(&self, book_name: &str, last_read: i64) -> LegadoResult<bool> {
        let Some(existing) = self.primary_record(book_name)? else {
            return Ok(false);
        };
        let affected = self
            .conn
            .execute(
                "UPDATE readRecord SET lastRead = ?1
                 WHERE deviceId = ?2 AND bookName = ?3 AND author = ?4",
                params![
                    last_read,
                    existing.device_id,
                    existing.book_name,
                    existing.author
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新 lastRead 失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 获取指定书籍的主记录（含 author，对齐上游 `ReadRecordDao.getRecord` 的书名维度）
    pub fn get_record(&self, book_name: &str) -> LegadoResult<Option<ReadRecord>> {
        self.primary_record(book_name)
    }

    /// 获取指定书籍主记录的 author 列
    pub fn get_author(&self, book_name: &str) -> LegadoResult<Option<String>> {
        Ok(self.primary_record(book_name)?.map(|r| r.author))
    }

    /// 返回有阅读记录的书名列表（对齐上游 `ReadRecordDao.flowBooks` 的书名维度）
    pub fn list_books(&self) -> LegadoResult<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT DISTINCT bookName FROM readRecord ORDER BY bookName ASC")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let names = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(names)
    }

    /// 获取所有阅读记录（全 13 列，按 readTime 降序）
    pub fn find_all(&self) -> LegadoResult<Vec<ReadRecord>> {
        let sql = format!("SELECT {COLUMNS} FROM readRecord ORDER BY readTime DESC, lastRead DESC");
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], record_from_row)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取指定书籍的主记录
    pub fn find_by_book_name(&self, book_name: &str) -> LegadoResult<Option<ReadRecord>> {
        self.get_record(book_name)
    }

    /// 删除指定书籍的阅读记录（v113 起删除该书**全部作者**的行）
    pub fn delete_by_book_name(&self, book_name: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "DELETE FROM readRecord WHERE bookName = ?1",
                params![book_name],
            )
            .map_err(|e| LegadoError::Database(format!("删除阅读记录失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 清空所有阅读记录，返回删除的行数
    pub fn clear_all(&self) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute("DELETE FROM readRecord", [])
            .map_err(|e| LegadoError::Database(format!("清空阅读记录失败: {e}")))?;
        Ok(affected)
    }

    /// 获取阅读记录总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM readRecord", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }

    // ─── [热力图每日时长契约] 每日时长聚合（热力图"每日时长"模式数据源）────────

    /// 确保 readRecordDaily 表存在（CREATE TABLE IF NOT EXISTS，无数据迁移需求）
    fn ensure_daily_table(&self) -> LegadoResult<()> {
        self.conn
            .execute(
                "CREATE TABLE IF NOT EXISTS readRecordDaily (\
                 date TEXT PRIMARY KEY,\
                 durationSeconds INTEGER NOT NULL DEFAULT 0)",
                [],
            )
            .map_err(|e| LegadoError::Database(format!("创建 readRecordDaily 表失败: {e}")))?;
        Ok(())
    }

    /// 向指定日期累计阅读秒数（增量 upsert）
    ///
    /// 日期格式：`YYYY-MM-DD`（本地时区）。
    /// 由 FFI `read_record_upsert` 自动调用，无需 Dart 侧额外调用。
    pub fn add_daily_seconds(&self, date: &str, seconds: i64) -> LegadoResult<()> {
        self.ensure_daily_table()?;
        self.conn
            .execute(
                "INSERT INTO readRecordDaily (date, durationSeconds) VALUES (?1, ?2)\
                 ON CONFLICT(date) DO UPDATE SET durationSeconds = durationSeconds + ?2",
                params![date, seconds],
            )
            .map_err(|e| LegadoError::Database(format!("更新每日阅读时长失败: {e}")))?;
        Ok(())
    }

    /// 按年查询每日阅读时长列表（热力图"每日时长"模式数据源）
    ///
    /// 返回按日期升序排列的 (date, durationSeconds) 对。
    pub fn list_daily_year(&self, year: i32) -> LegadoResult<Vec<(String, i64)>> {
        self.ensure_daily_table()?;
        let prefix = format!("{year:04}-%");
        let mut stmt = self
            .conn
            .prepare(
                "SELECT date, durationSeconds FROM readRecordDaily \
                 WHERE date LIKE ?1 ORDER BY date ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备每日时长查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![prefix], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|e| LegadoError::Database(format!("查询每日时长失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_upsert_and_find() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();

        let record = repo.find_by_book_name("book1").unwrap();
        assert!(record.is_some());
        let r = record.unwrap();
        assert_eq!(r.book_name, "book1");
        assert_eq!(r.read_time, 1000);
    }

    #[test]
    fn test_upsert_replaces_existing() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();
        repo.upsert("book1", 2000).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let r = repo.find_by_book_name("book1").unwrap().unwrap();
        assert_eq!(r.read_time, 2000);
    }

    #[test]
    fn test_find_all_ordered() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book_a", 100).unwrap();
        repo.upsert("book_b", 300).unwrap();
        repo.upsert("book_c", 200).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].book_name, "book_b");
        assert_eq!(all[1].book_name, "book_c");
        assert_eq!(all[2].book_name, "book_a");
    }

    #[test]
    fn test_find_by_book_name_not_found() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        let result = repo.find_by_book_name("nonexistent").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_delete_by_book_name() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();
        repo.upsert("book2", 2000).unwrap();

        assert!(repo.delete_by_book_name("book1").unwrap());
        assert!(!repo.delete_by_book_name("book1").unwrap());
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_clear_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();
        repo.upsert("book2", 2000).unwrap();
        repo.upsert("book3", 3000).unwrap();

        let deleted = repo.clear_all().unwrap();
        assert_eq!(deleted, 3);
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_count() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        assert_eq!(repo.count().unwrap(), 0);
        repo.upsert("book1", 1000).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        repo.upsert("book2", 2000).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
    }

    // ─── author 解码（旧合并串，仅展示/搜索标识）────────────────

    /// 空白/单作者/集合三种形态
    #[test]
    fn test_decode_authors() {
        assert!(decode_read_record_authors("").is_empty());
        assert!(decode_read_record_authors("   ").is_empty());
        assert_eq!(
            decode_read_record_authors("作者A"),
            vec!["作者A".to_string()]
        );

        let set_value = format!("{AUTHORS_PREFIX}[\"作者A\",\"作者B\"]");
        assert_eq!(
            decode_read_record_authors(&set_value),
            vec!["作者A".to_string(), "作者B".to_string()]
        );
        // 空白项过滤 + 去重
        let dup = format!("{AUTHORS_PREFIX}[\"作者A\",\" \",\"作者A\"]");
        assert_eq!(decode_read_record_authors(&dup), vec!["作者A".to_string()]);
    }

    /// 非法 JSON 集合值：解析失败按空列表处理，不残留垃圾数据
    #[test]
    fn test_decode_authors_invalid_json_falls_back() {
        let bad = format!("{AUTHORS_PREFIX}not-json");
        assert!(decode_read_record_authors(&bad).is_empty());
    }

    // ─── v113 主键：同名不同作者分行 ─────────────────────────────

    /// 同书名两个作者：两行独立存在，时长互不覆盖
    #[test]
    fn test_insert_with_author_keeps_separate_rows() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.insert_with_author("同名书", "作者A", 100).unwrap();
        repo.insert_with_author("同名书", "作者B", 200).unwrap();

        assert_eq!(repo.count().unwrap(), 2, "同名不同作者应分行");
        let rows = repo.find_all().unwrap();
        let a = rows.iter().find(|r| r.author == "作者A").unwrap();
        let b = rows.iter().find(|r| r.author == "作者B").unwrap();
        assert_eq!(a.read_time, 100);
        assert_eq!(b.read_time, 200);
    }

    /// 同作者重复写入：只更新 readTime，仍为一行
    #[test]
    fn test_insert_with_author_same_author_updates() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.insert_with_author("书", "作者A", 100).unwrap();
        repo.insert_with_author("书", "作者A", 300).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let record = repo.get_record("书").unwrap().unwrap();
        assert_eq!(record.author, "作者A");
        assert_eq!(record.read_time, 300);
    }

    /// 旧式 upsert（无作者）优先命中空作者行；无空作者行时更新 lastRead 最新的行
    #[test]
    fn test_legacy_upsert_targets_primary_row() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        // 只有带作者的行：更新 lastRead 最新者
        repo.insert_with_author("书", "作者A", 100).unwrap();
        repo.insert_with_author("书", "作者B", 200).unwrap();
        repo.upsert("书", 999).unwrap();
        let rows = repo.find_all().unwrap();
        assert_eq!(rows.len(), 2);
        let b = rows.iter().find(|r| r.author == "作者B").unwrap();
        assert_eq!(b.read_time, 999, "无空作者行时应更新 lastRead 最新的主记录");

        // 存在空作者行：优先更新空作者行
        repo.upsert_full("", "书", "", 50, 500).unwrap();
        repo.upsert("书", 777).unwrap();
        let blank = repo
            .get_by_pk("", "书", "")
            .unwrap()
            .expect("空作者行应存在");
        assert_eq!(blank.read_time, 777);
    }

    /// get_author：存在/不存在两种情况
    #[test]
    fn test_get_author() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.insert_with_author("书", "作者A", 100).unwrap();
        assert_eq!(repo.get_author("书").unwrap().as_deref(), Some("作者A"));
        assert_eq!(repo.get_author("不存在").unwrap(), None);
    }

    /// list_books：书名去重并按书名排序
    #[test]
    fn test_list_books() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        assert!(repo.list_books().unwrap().is_empty());

        repo.upsert("b书", 10).unwrap();
        repo.upsert("a书", 20).unwrap();
        repo.upsert("c书", 30).unwrap();
        repo.insert_with_author("c书", "另一作者", 40).unwrap();

        assert_eq!(
            repo.list_books().unwrap(),
            vec!["a书".to_string(), "b书".to_string(), "c书".to_string()]
        );
    }

    /// get_record：旧接口 upsert 写入的记录 author 为空字符串，可正常读取
    #[test]
    fn test_get_record_legacy_row() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert("legacy", 123).unwrap();
        let record = repo.get_record("legacy").unwrap().unwrap();
        assert_eq!(record.author, "");
        assert_eq!(record.read_time, 123);
        assert!(repo.get_record("none").unwrap().is_none());
    }

    // ─── v101/v113 新字段 ────────────────────────────────────────

    /// 全字段写入后 get_record / find_all / get_by_pk 均能完整读回
    #[test]
    fn test_upsert_full_new_fields_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert_full("device-1", "书A", "作者A", 500, 42)
            .unwrap();

        let record = repo.get_record("书A").unwrap().unwrap();
        assert_eq!(record.device_id, "device-1");
        assert_eq!(record.book_name, "书A");
        assert_eq!(record.author, "作者A");
        assert_eq!(record.read_time, 500);
        assert_eq!(record.last_read, 42);
        // 新行显示字段按物理键派生（对齐上游 withDisplayMetadata）
        assert_eq!(record.display_book_name, "书A");
        assert_eq!(record.display_author, "作者A");
        assert_eq!(record.last_chapter_index, -1);

        let by_pk = repo.get_by_pk("device-1", "书A", "作者A").unwrap().unwrap();
        assert_eq!(by_pk.read_time, 500);

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].device_id, "device-1");
        assert_eq!(all[0].last_read, 42);
    }

    /// 旧接口 upsert 写入的记录：新字段回落列默认值（''/0/-1/None）
    #[test]
    fn test_legacy_upsert_new_field_defaults() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert("旧接口", 10).unwrap();
        let record = repo.get_record("旧接口").unwrap().unwrap();
        assert_eq!(record.device_id, "");
        assert_eq!(record.last_read, 0);
        assert_eq!(record.last_chapter_index, -1);
        assert_eq!(record.last_chapter_pos, 0);
        assert_eq!(record.last_chapter_title, None);
        assert_eq!(record.cover_url, None);
        assert_eq!(record.resolved_author, None);
        assert_eq!(record.metadata_edited_at, 0);
        assert_eq!(record.display_book_name, "旧接口");
        assert_eq!(record.display_author, "");
    }

    /// upsert_full 重复写入只更新 readTime/lastRead，章节快照/显示元数据保留
    #[test]
    fn test_upsert_full_preserves_snapshot_columns() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        let mut record = ReadRecord {
            book_name: "快照书".to_string(),
            author: "作者A".to_string(),
            read_time: 100,
            last_read: 10,
            ..Default::default()
        };
        record = record.with_display_metadata(None);
        record.last_chapter_title = Some("第十章".to_string());
        record.last_chapter_index = 9;
        record.last_chapter_pos = 88;
        record.cover_url = Some("https://cover.example/1.jpg".to_string());
        record.metadata_edited_at = 5;
        record.display_book_name = "显示书名".to_string();
        record.display_author = "显示作者".to_string();
        repo.write_row(&record).unwrap();

        repo.upsert_full("", "快照书", "作者A", 300, 30).unwrap();
        let row = repo.get_by_pk("", "快照书", "作者A").unwrap().unwrap();
        assert_eq!(row.read_time, 300);
        assert_eq!(row.last_read, 30);
        assert_eq!(row.last_chapter_title.as_deref(), Some("第十章"));
        assert_eq!(row.last_chapter_index, 9);
        assert_eq!(row.last_chapter_pos, 88);
        assert_eq!(
            row.cover_url.as_deref(),
            Some("https://cover.example/1.jpg")
        );
        assert_eq!(row.display_book_name, "显示书名");
        assert_eq!(row.display_author, "显示作者");
        assert_eq!(row.metadata_edited_at, 5);
    }

    /// update_last_read：存在时更新主记录，不存在时返回 false
    #[test]
    fn test_update_last_read() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert("书B", 100).unwrap();
        assert!(repo.update_last_read("书B", 77).unwrap());
        assert_eq!(repo.get_record("书B").unwrap().unwrap().last_read, 77);
        assert!(!repo.update_last_read("不存在", 1).unwrap());
    }

    /// [热力图每日时长契约] add_daily_seconds：同日多次累加，按日累计
    #[test]
    fn test_daily_add_accumulates_same_date() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.add_daily_seconds("2026-08-29", 600).unwrap();
        repo.add_daily_seconds("2026-08-29", 900).unwrap();
        let rows = repo.list_daily_year(2026).unwrap();
        assert_eq!(rows, vec![("2026-08-29".to_string(), 1500)]);
    }

    /// [热力图每日时长契约] list_daily_year：跨年隔离 + 日期升序
    #[test]
    fn test_daily_list_year_filter_and_order() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.add_daily_seconds("2026-01-02", 100).unwrap();
        repo.add_daily_seconds("2026-08-29", 300).unwrap();
        repo.add_daily_seconds("2025-12-31", 999).unwrap();

        let rows = repo.list_daily_year(2026).unwrap();
        assert_eq!(
            rows,
            vec![
                ("2026-01-02".to_string(), 100),
                ("2026-08-29".to_string(), 300),
            ]
        );
        let rows_2025 = repo.list_daily_year(2025).unwrap();
        assert_eq!(rows_2025, vec![("2025-12-31".to_string(), 999)]);
        assert!(repo.list_daily_year(2024).unwrap().is_empty());
    }

    // ─── 恢复合并语义（upsert_restore，对齐原版 mergeRestoredReadRecord）──────

    /// 非本机记录直接整行插入：deviceId 归属正确，author/lastRead 落库
    #[test]
    fn test_restore_foreign_device_row_inserted() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        // 本机已有同书名记录（不同 author，互不干扰）
        repo.upsert_full("", "书A", "作者甲", 100, 10).unwrap();

        repo.upsert_restore(&ReadRecord {
            device_id: "device-A".to_string(),
            book_name: "书A".to_string(),
            author: "作者甲".to_string(),
            read_time: 500,
            last_read: 50,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(repo.count().unwrap(), 2);
        let all = repo.find_all().unwrap();
        let foreign = all.iter().find(|r| r.device_id == "device-A").unwrap();
        assert_eq!(foreign.book_name, "书A");
        assert_eq!(foreign.read_time, 500);
        assert_eq!(foreign.last_read, 50);
        assert_eq!(foreign.author, "作者甲");
        // 本机记录不受非本机记录影响
        let local = all.iter().find(|r| r.device_id.is_empty()).unwrap();
        assert_eq!(local.read_time, 100);
    }

    /// 同名不同作者：恢复时按物理键分行，不合并时长
    #[test]
    fn test_restore_same_name_different_author_separate_rows() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert_full("", "书B", "作者乙", 200, 20).unwrap();
        repo.upsert_restore(&ReadRecord {
            device_id: String::new(),
            book_name: "书B".to_string(),
            author: "作者丙".to_string(),
            read_time: 100,
            last_read: 5,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(repo.count().unwrap(), 2, "同名不同作者应分行");
        let rows = repo.find_all().unwrap();
        assert_eq!(
            rows.iter()
                .find(|r| r.author == "作者乙")
                .unwrap()
                .read_time,
            200
        );
        assert_eq!(
            rows.iter()
                .find(|r| r.author == "作者丙")
                .unwrap()
                .read_time,
            100
        );
    }

    /// 同键本机记录传入较旧：readTime/lastRead 保留库内值，快照按较新者合并
    #[test]
    fn test_restore_local_older_keeps_times_and_merges_snapshot() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        let mut current = ReadRecord {
            device_id: String::new(),
            book_name: "书C".to_string(),
            author: "作者丁".to_string(),
            read_time: 200,
            last_read: 20,
            ..Default::default()
        };
        current.last_chapter_title = Some("库内章节".to_string());
        current.last_chapter_index = 8;
        current.last_chapter_pos = 80;
        current.cover_url = Some("https://cover.example/old.jpg".to_string());
        repo.write_row(&current).unwrap();

        repo.upsert_restore(&ReadRecord {
            device_id: String::new(),
            book_name: "书C".to_string(),
            author: "作者丁".to_string(),
            read_time: 100,
            last_read: 5,
            last_chapter_title: Some("备份章节".to_string()),
            last_chapter_index: 2,
            last_chapter_pos: 20,
            cover_url: Some("https://cover.example/new.jpg".to_string()),
            ..Default::default()
        })
        .unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let row = repo.get_record("书C").unwrap().unwrap();
        assert_eq!(row.read_time, 200, "库内较新 readTime 不得被旧值覆盖");
        assert_eq!(row.last_read, 20, "lastRead 取两侧最大");
        assert_eq!(row.last_chapter_title.as_deref(), Some("库内章节"));
        assert_eq!(row.last_chapter_index, 8);
        assert_eq!(row.last_chapter_pos, 80);
        // 快照跟随较新记录（库内），封面也取较新者的非空值
        assert_eq!(
            row.cover_url.as_deref(),
            Some("https://cover.example/old.jpg")
        );
    }

    /// 同键本机记录传入较新：readTime/lastRead 覆盖，快照取传入值
    #[test]
    fn test_restore_local_incoming_newer_overwrites() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert_full("", "书D", "作者戊", 50, 5).unwrap();
        repo.upsert_restore(&ReadRecord {
            device_id: String::new(),
            book_name: "书D".to_string(),
            author: "作者戊".to_string(),
            read_time: 999,
            last_read: 99,
            last_chapter_title: Some("备份章节".to_string()),
            last_chapter_index: 3,
            last_chapter_pos: 30,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let row = repo.get_record("书D").unwrap().unwrap();
        assert_eq!(row.read_time, 999);
        assert_eq!(row.last_read, 99);
        assert_eq!(row.last_chapter_title.as_deref(), Some("备份章节"));
        assert_eq!(row.last_chapter_index, 3);
        assert_eq!(row.last_chapter_pos, 30);
    }

    /// 库内无同键记录：直接整行写入（显示字段按物理键派生）
    #[test]
    fn test_restore_missing_row_inserted() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert_restore(&ReadRecord {
            device_id: String::new(),
            book_name: "书E".to_string(),
            author: "作者己".to_string(),
            read_time: 42,
            last_read: 7,
            ..Default::default()
        })
        .unwrap();

        let row = repo.get_record("书E").unwrap().unwrap();
        assert_eq!(row.author, "作者己");
        assert_eq!(row.read_time, 42);
        assert_eq!(row.last_read, 7);
        assert_eq!(row.display_book_name, "书E");
        assert_eq!(row.display_author, "作者己");
    }

    /// 显示元数据：库内有编辑（metadataEditedAt>0）且不旧于传入 → 保留库内显示值
    #[test]
    fn test_restore_display_metadata_newer_edited_wins() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        let edited = ReadRecord {
            book_name: "书F".to_string(),
            author: "作者庚".to_string(),
            read_time: 100,
            last_read: 10,
            metadata_edited_at: 50,
            display_book_name: "编辑书名".to_string(),
            display_author: "编辑作者".to_string(),
            ..Default::default()
        };
        repo.write_row(&edited).unwrap();

        repo.upsert_restore(&ReadRecord {
            device_id: String::new(),
            book_name: "书F".to_string(),
            author: "作者庚".to_string(),
            read_time: 200,
            last_read: 20,
            metadata_edited_at: 10,
            display_book_name: "旧编辑".to_string(),
            display_author: "旧作者".to_string(),
            ..Default::default()
        })
        .unwrap();

        let row = repo.get_record("书F").unwrap().unwrap();
        assert_eq!(row.read_time, 200);
        assert_eq!(row.display_book_name, "编辑书名");
        assert_eq!(row.display_author, "编辑作者");
        assert_eq!(row.metadata_edited_at, 50);
    }

    /// 显示元数据：传入编辑时间更新 → 采用传入显示值
    #[test]
    fn test_restore_display_metadata_incoming_edited_wins() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        let old = ReadRecord {
            book_name: "书G".to_string(),
            author: "作者辛".to_string(),
            read_time: 100,
            last_read: 10,
            metadata_edited_at: 10,
            display_book_name: "旧书名".to_string(),
            display_author: "旧作者".to_string(),
            ..Default::default()
        };
        repo.write_row(&old).unwrap();

        repo.upsert_restore(&ReadRecord {
            device_id: String::new(),
            book_name: "书G".to_string(),
            author: "作者辛".to_string(),
            read_time: 200,
            last_read: 20,
            metadata_edited_at: 90,
            display_book_name: "新书名".to_string(),
            display_author: "新作者".to_string(),
            ..Default::default()
        })
        .unwrap();

        let row = repo.get_record("书G").unwrap().unwrap();
        assert_eq!(row.display_book_name, "新书名");
        assert_eq!(row.display_author, "新作者");
        assert_eq!(row.metadata_edited_at, 90);
    }
}
