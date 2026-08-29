//! ReadRecord Repository - readRecord 表 CRUD

use std::collections::BTreeSet;

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 阅读记录
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReadRecord {
    /// 设备标识（v101 补齐 Room 基线 deviceId 列，当前单设备 Rust 侧固定空串）
    #[serde(default, rename = "deviceId")]
    pub device_id: String,
    pub book_name: String,
    /// 作者（同书名的多本书共用一条记录时，以作者集合形式合并存储）
    #[serde(default)]
    pub author: String,
    pub read_time: i64,
    /// 最后阅读位置/章节索引（v101 补齐 Room 基线 lastRead 列）
    #[serde(default, rename = "lastRead")]
    pub last_read: i64,
}

/// 作者集合存储前缀（对齐上游 Kotlin `ReadRecordAuthors.PREFIX`）
///
/// author 列兼容纯文本旧记录：无前缀时为单一作者；
/// 多作者时存储为 `\u{1E}authors:` + JSON 字符串数组。
const AUTHORS_PREFIX: &str = "\u{1E}authors:";

/// 解码 author 列值为作者列表（对齐上游 `ReadRecordAuthors.decode`）
///
/// - 空白值返回空列表（上游返回 {""}，合并时会被非空过滤掉，等价）；
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

/// 合并两个 author 列值（对齐上游 `ReadRecordAuthors.merge`）
///
/// 取并集后去空白、去重并按字典序排序（上游 sortedSetOf）：
/// - 0 个作者 → 空字符串；
/// - 1 个作者 → 纯文本（兼容旧记录）；
/// - 多个作者 → `前缀 + JSON 数组`。
pub fn merge_read_record_authors(current: &str, incoming: &str) -> String {
    let mut set: BTreeSet<String> = BTreeSet::new();
    for author in decode_read_record_authors(current)
        .into_iter()
        .chain(decode_read_record_authors(incoming))
    {
        if !author.trim().is_empty() {
            set.insert(author);
        }
    }
    match set.len() {
        0 => String::new(),
        1 => set.into_iter().next().unwrap_or_default(),
        _ => {
            let arr: Vec<String> = set.into_iter().collect();
            format!(
                "{AUTHORS_PREFIX}{}",
                serde_json::to_string(&arr).unwrap_or_default()
            )
        }
    }
}

/// 阅读记录数据访问层
pub struct ReadRecordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ReadRecordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 添加/更新阅读记录（主键冲突时替换）
    ///
    /// 说明：本方法签名保持不变（FFI 既有契约），deviceId/lastRead 依赖列默认值
    /// （''/0）；需要写入新字段时使用 [`upsert_full`]。
    pub fn upsert(&self, book_name: &str, read_time: i64) -> LegadoResult<()> {
        // 主键 (deviceId, bookName)；单设备 deviceId=''；保留 author/lastRead
        self.conn
            .execute(
                "INSERT INTO readRecord (deviceId, bookName, readTime)
                 VALUES ('', ?1, ?2)
                 ON CONFLICT(deviceId, bookName) DO UPDATE SET readTime = excluded.readTime",
                params![book_name, read_time],
            )
            .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 添加/更新阅读记录（全字段版，覆盖 v101 新增的 deviceId/lastRead 列）
    ///
    /// 主键冲突时整行替换；author 不做合并（调用方自行处理）。
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
                "INSERT OR REPLACE INTO readRecord
                 (deviceId, bookName, author, readTime, lastRead)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![device_id, book_name, author, read_time, last_read],
            )
            .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 更新指定书籍的最后阅读位置（lastRead 列，v101 新增）
    pub fn update_last_read(&self, book_name: &str, last_read: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE readRecord SET lastRead = ?1 WHERE bookName = ?2",
                params![last_read, book_name],
            )
            .map_err(|e| LegadoError::Database(format!("更新 lastRead 失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 添加/更新阅读记录并合并作者（对齐上游 `ReadRecordDao.insert` 事务）
    ///
    /// 上游语义：同设备同书名共用一条记录，新记录的 author 与库内旧 author
    /// 通过 `ReadRecordAuthors.merge` 合并后再 REPLACE 写入，
    /// 避免同名书不同作者互相覆盖；readTime 以传入值为准。
    pub fn insert_with_author(
        &self,
        book_name: &str,
        author: &str,
        read_time: i64,
    ) -> LegadoResult<()> {
        // 1. 读取旧记录的 author（对应上游 getAuthor(deviceId, bookName)）
        let existing = self.get_author(book_name)?.unwrap_or_default();

        // 2. 作者集合并（对应上游 ReadRecordAuthors.merge）
        let merged = merge_read_record_authors(&existing, author);

        // 3. upsert 写入（主键含 deviceId；保留 lastRead）
        self.conn
            .execute(
                "INSERT INTO readRecord (deviceId, bookName, author, readTime)
                 VALUES ('', ?1, ?2, ?3)
                 ON CONFLICT(deviceId, bookName) DO UPDATE SET
                   author = excluded.author,
                   readTime = excluded.readTime",
                params![book_name, merged, read_time],
            )
            .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 获取指定书籍的完整阅读记录（含 author，对齐上游 `ReadRecordDao.getRecord`）
    pub fn get_record(&self, book_name: &str) -> LegadoResult<Option<ReadRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookName, author, readTime, deviceId, lastRead
                 FROM readRecord WHERE bookName = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let record = stmt
            .query_row(params![book_name], |row| {
                Ok(ReadRecord {
                    device_id: row.get(3)?,
                    book_name: row.get(0)?,
                    author: row.get(1)?,
                    read_time: row.get(2)?,
                    last_read: row.get(4)?,
                })
            })
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(record)
    }

    /// 获取指定书籍记录的 author 列（对齐上游 `ReadRecordDao.getAuthor`）
    pub fn get_author(&self, book_name: &str) -> LegadoResult<Option<String>> {
        let author: Option<String> = self
            .conn
            .query_row(
                "SELECT author FROM readRecord WHERE bookName = ?1",
                params![book_name],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询 author 失败: {e}")))?;
        Ok(author)
    }

    /// 返回有阅读记录的书名列表（对齐上游 `ReadRecordDao.flowBooks` 的书名维度）
    ///
    /// 上游返回 distinct (bookName, author) 对；Rust 侧 readRecord 主键即 bookName，
    /// 天然去重，按 bookName 排序输出。
    pub fn list_books(&self) -> LegadoResult<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT bookName FROM readRecord ORDER BY bookName ASC")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let names = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(names)
    }

    /// 获取所有阅读记录（按 readTime 降序）
    pub fn find_all(&self) -> LegadoResult<Vec<ReadRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT bookName, author, readTime, deviceId, lastRead
                 FROM readRecord ORDER BY readTime DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(ReadRecord {
                    device_id: row.get(3)?,
                    book_name: row.get(0)?,
                    author: row.get(1)?,
                    read_time: row.get(2)?,
                    last_read: row.get(4)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取指定书籍的阅读记录
    pub fn find_by_book_name(&self, book_name: &str) -> LegadoResult<Option<ReadRecord>> {
        self.get_record(book_name)
    }

    /// 删除指定书籍的阅读记录
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
}

use rusqlite::OptionalExtension;

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

    // ─── 作者合并逻辑（对齐上游 ReadRecordAuthors）──────────────

    /// 单作者 + 空值：保持纯文本，不进入集合编码
    #[test]
    fn test_merge_authors_plain_and_blank() {
        assert_eq!(merge_read_record_authors("", "作者A"), "作者A");
        assert_eq!(merge_read_record_authors("作者A", ""), "作者A");
        assert_eq!(merge_read_record_authors("", ""), "");
        // 空白字符串被过滤
        assert_eq!(merge_read_record_authors("   ", "作者A"), "作者A");
    }

    /// 同作者去重：仍为纯文本单作者
    #[test]
    fn test_merge_authors_dedup_single() {
        assert_eq!(merge_read_record_authors("作者A", "作者A"), "作者A");
    }

    /// 多作者合并：去重 + 排序 + 前缀编码
    #[test]
    fn test_merge_authors_multi_sorted() {
        let merged = merge_read_record_authors("作者B", "作者A");
        assert!(merged.starts_with(AUTHORS_PREFIX));
        let arr: Vec<String> =
            serde_json::from_str(merged.strip_prefix(AUTHORS_PREFIX).unwrap()).unwrap();
        // 排序后的作者集合
        assert_eq!(arr, vec!["作者A".to_string(), "作者B".to_string()]);
    }

    /// 集合值与纯文本混合合并，重复作者去重
    #[test]
    fn test_merge_authors_set_with_plain() {
        let set_value = format!("{AUTHORS_PREFIX}[\"作者A\",\"作者B\"]");
        let merged = merge_read_record_authors(&set_value, "作者B");
        // 仍为两个作者，去重后保持集合编码
        let arr: Vec<String> =
            serde_json::from_str(merged.strip_prefix(AUTHORS_PREFIX).unwrap()).unwrap();
        assert_eq!(arr, vec!["作者A".to_string(), "作者B".to_string()]);
    }

    /// 非法 JSON 集合值：解析失败时按空处理，不残留垃圾数据
    #[test]
    fn test_merge_authors_invalid_json_falls_back() {
        let bad = format!("{AUTHORS_PREFIX}not-json");
        assert_eq!(merge_read_record_authors(&bad, "作者C"), "作者C");
    }

    // ─── 带作者合并的 insert ──────────────────────────────────

    /// 同书名多次写入不同作者：作者合并存储，readTime 以新值为准，仅一条记录
    #[test]
    fn test_insert_with_author_merges() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.insert_with_author("同名书", "作者A", 100).unwrap();
        repo.insert_with_author("同名书", "作者B", 200).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let record = repo.get_record("同名书").unwrap().unwrap();
        assert_eq!(record.read_time, 200);
        assert!(record.author.starts_with(AUTHORS_PREFIX));
        let arr: Vec<String> =
            serde_json::from_str(record.author.strip_prefix(AUTHORS_PREFIX).unwrap()).unwrap();
        assert_eq!(arr, vec!["作者A".to_string(), "作者B".to_string()]);
    }

    /// 同作者重复写入：不产生集合编码
    #[test]
    fn test_insert_with_author_same_author() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.insert_with_author("书", "作者A", 100).unwrap();
        repo.insert_with_author("书", "作者A", 300).unwrap();

        let record = repo.get_record("书").unwrap().unwrap();
        assert_eq!(record.author, "作者A");
        assert_eq!(record.read_time, 300);
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

    /// list_books：返回有阅读记录的书名列表，按书名排序
    #[test]
    fn test_list_books() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        assert!(repo.list_books().unwrap().is_empty());

        repo.upsert("b书", 10).unwrap();
        repo.upsert("a书", 20).unwrap();
        repo.upsert("c书", 30).unwrap();

        assert_eq!(
            repo.list_books().unwrap(),
            vec!["a书".to_string(), "b书".to_string(), "c书".to_string()]
        );
    }

    /// get_record：旧接口 upsert 写入的记录 author 为空字符串，get_record 可正常读取
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

    // ─── v101 新字段（deviceId / lastRead）────────────────────

    /// 全字段写入后 get_record / find_all 均能完整读回
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

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].device_id, "device-1");
        assert_eq!(all[0].last_read, 42);
    }

    /// 旧接口 upsert 写入的记录：新字段回落列默认值（''/0）
    #[test]
    fn test_legacy_upsert_new_field_defaults() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert("旧接口", 10).unwrap();
        let record = repo.get_record("旧接口").unwrap().unwrap();
        assert_eq!(record.device_id, "");
        assert_eq!(record.last_read, 0);
    }

    /// update_last_read：存在时更新成功，不存在时返回 false
    #[test]
    fn test_update_last_read() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());

        repo.upsert("书B", 100).unwrap();
        assert!(repo.update_last_read("书B", 77).unwrap());
        assert_eq!(repo.get_record("书B").unwrap().unwrap().last_read, 77);
        assert!(!repo.update_last_read("不存在", 1).unwrap());
    }
}
