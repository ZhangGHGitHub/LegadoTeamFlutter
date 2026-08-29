//! 备份/恢复 API
//!
//! 提供数据库备份创建、恢复和备份文件列表功能。
//! 备份格式为 JSON，包含 books/bookmarks/replaceRules/bookSources/rssSources/readRecords。

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use legado_core::models::{Book, BookSource, Bookmark, RssSource};
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{
    BookRepository, BookSourceRepository, BookmarkRepository, ReadRecordRepository,
    ReplaceRuleRepository,
};

use crate::db_state::with_database;

/// 备份数据结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupData {
    /// 备份版本
    #[serde(default = "default_version")]
    pub version: i32,
    /// 备份时间戳（毫秒）
    #[serde(default, rename = "backupTime")]
    pub backup_time: i64,
    /// 书籍列表
    #[serde(default)]
    pub books: Vec<serde_json::Value>,
    /// 书签列表
    #[serde(default)]
    pub bookmarks: Vec<serde_json::Value>,
    /// 替换规则列表
    #[serde(default, rename = "replaceRules")]
    pub replace_rules: Vec<serde_json::Value>,
    /// 书源列表
    #[serde(default, rename = "bookSources")]
    pub book_sources: Vec<serde_json::Value>,
    /// RSS 源列表
    #[serde(default, rename = "rssSources")]
    pub rss_sources: Vec<serde_json::Value>,
    /// 阅读记录列表
    #[serde(default, rename = "readRecords")]
    pub read_records: Vec<serde_json::Value>,
}

fn default_version() -> i32 {
    1
}

/// 恢复统计
#[derive(Debug, Clone, Serialize)]
pub struct RestoreStats {
    pub books: usize,
    pub bookmarks: usize,
    pub replace_rules: usize,
    pub book_sources: usize,
    pub rss_sources: usize,
    pub read_records: usize,
}

/// 创建备份到指定路径
///
/// 收集 books/bookmarks/replaceRules/bookSources/rssSources/readRecords，
/// 序列化为 JSON 写入文件，返回备份文件路径。
pub fn backup_create(path: &str) -> LegadoResult<String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let backup_data = with_database(|db| {
        let conn = db.connection();

        // 收集书籍
        let book_repo = BookRepository::new(conn);
        let books: Vec<serde_json::Value> = book_repo
            .find_all()?
            .into_iter()
            .filter_map(|b| serde_json::to_value(&b).ok())
            .collect();

        // 收集书签
        let bookmark_repo = BookmarkRepository::new(conn);
        let bookmarks: Vec<serde_json::Value> = bookmark_repo
            .find_all()?
            .into_iter()
            .filter_map(|b| serde_json::to_value(&b).ok())
            .collect();

        // 收集替换规则
        let rule_repo = ReplaceRuleRepository::new(conn);
        let replace_rules: Vec<serde_json::Value> = rule_repo
            .find_all()?
            .into_iter()
            .filter_map(|r| serde_json::to_value(&r).ok())
            .collect();

        // 收集书源
        let source_repo = BookSourceRepository::new(conn);
        let book_sources: Vec<serde_json::Value> = source_repo
            .find_all()?
            .into_iter()
            .filter_map(|s| serde_json::to_value(&s).ok())
            .collect();

        // 收集 RSS 源（直接 SQL 查询）
        let rss_sources = collect_rss_sources(conn)?;

        // 收集阅读记录
        let record_repo = ReadRecordRepository::new(conn);
        let read_records: Vec<serde_json::Value> = record_repo
            .find_all()?
            .into_iter()
            .filter_map(|r| serde_json::to_value(&r).ok())
            .collect();

        Ok(BackupData {
            version: 1,
            backup_time: now,
            books,
            bookmarks,
            replace_rules,
            book_sources,
            rss_sources,
            read_records,
        })
    })?;

    // 确保目录存在
    if let Some(parent) = Path::new(path).parent() {
        fs::create_dir_all(parent).map_err(|e| {
            LegadoError::Io(std::io::Error::other(format!("创建备份目录失败: {e}")))
        })?;
    }

    // 写入文件
    let json = serde_json::to_string_pretty(&backup_data)
        .map_err(|e| LegadoError::Internal(format!("备份序列化失败: {e}")))?;
    fs::write(path, &json)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("写入备份文件失败: {e}"))))?;

    Ok(path.to_string())
}

/// 从备份文件恢复
///
/// 读取 JSON 文件，逐条恢复各表数据，返回恢复统计。
pub fn backup_restore(path: &str) -> LegadoResult<String> {
    let content = fs::read_to_string(path)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;

    let backup: BackupData = serde_json::from_str(&content)
        .map_err(|e| LegadoError::Internal(format!("备份文件解析失败: {e}")))?;

    let stats = with_database(|db| {
        let conn = db.connection();
        let mut stats = RestoreStats {
            books: 0,
            bookmarks: 0,
            replace_rules: 0,
            book_sources: 0,
            rss_sources: 0,
            read_records: 0,
        };

        // 恢复书籍
        // 评审 W3：失败不再静默吞错——UNIQUE 撞名等写入失败记 warn 日志，
        // 便于排查「恢复数量少于备份数量」类问题（RestoreStats 仅含成功计数，
        // 失败不入统计以免变更 FFI 返回结构）
        let book_repo = BookRepository::new(conn);
        for value in &backup.books {
            if let Ok(book) = serde_json::from_value::<Book>(value.clone()) {
                match book_repo.insert(&book) {
                    Ok(()) => stats.books += 1,
                    Err(e) => log::warn!("恢复书籍失败（已跳过）: {} - {e}", book.book_url),
                }
            }
        }

        // 恢复书签
        let bookmark_repo = BookmarkRepository::new(conn);
        for value in &backup.bookmarks {
            if let Ok(bm) = serde_json::from_value::<Bookmark>(value.clone()) {
                match bookmark_repo.insert(&bm) {
                    Ok(_) => stats.bookmarks += 1,
                    Err(e) => log::warn!("恢复书签失败（已跳过）: {} - {e}", bm.book_name),
                }
            }
        }

        // 恢复替换规则
        let rule_repo = ReplaceRuleRepository::new(conn);
        for value in &backup.replace_rules {
            if let Ok(rule) =
                serde_json::from_value::<legado_core::models::ReplaceRule>(value.clone())
            {
                match rule_repo.insert(&rule) {
                    Ok(_) => stats.replace_rules += 1,
                    Err(e) => log::warn!("恢复替换规则失败（已跳过）: {} - {e}", rule.name),
                }
            }
        }

        // 恢复书源
        let source_repo = BookSourceRepository::new(conn);
        for value in &backup.book_sources {
            if let Ok(source) = serde_json::from_value::<BookSource>(value.clone()) {
                match source_repo.insert(&source) {
                    Ok(()) => stats.book_sources += 1,
                    Err(e) => {
                        log::warn!("恢复书源失败（已跳过）: {} - {e}", source.book_source_url)
                    }
                }
            }
        }

        // 恢复 RSS 源
        for value in &backup.rss_sources {
            if let Ok(source) = serde_json::from_value::<RssSource>(value.clone()) {
                match insert_rss_source(conn, &source) {
                    Ok(()) => stats.rss_sources += 1,
                    Err(e) => {
                        log::warn!("恢复 RSS 源失败（已跳过）: {} - {e}", source.source_url)
                    }
                }
            }
        }

        // 恢复阅读记录
        let record_repo = ReadRecordRepository::new(conn);
        for value in &backup.read_records {
            if let Ok(record) =
                serde_json::from_value::<legado_core::models::ReadRecord>(value.clone())
            {
                match record_repo.upsert(&record.book_name, record.read_time) {
                    Ok(()) => stats.read_records += 1,
                    Err(e) => {
                        log::warn!("恢复阅读记录失败（已跳过）: {} - {e}", record.book_name)
                    }
                }
            }
        }

        Ok(stats)
    })?;

    let result = serde_json::to_string(&stats)
        .map_err(|e| LegadoError::Internal(format!("统计序列化失败: {e}")))?;
    Ok(result)
}

/// 列出备份文件
///
/// 列出目录中的 .json 备份文件，返回 JSON 数组。
pub fn backup_list(dir: &str) -> String {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return "[]".to_string(),
    };

    let files: Vec<serde_json::Value> = entries
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path()
                .extension()
                .map(|ext| ext == "json")
                .unwrap_or(false)
        })
        .filter_map(|e| {
            let path = e.path();
            let metadata = e.metadata().ok()?;
            let name = path.file_name()?.to_str()?.to_string();
            let size = metadata.len();
            let modified = metadata
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            Some(serde_json::json!({
                "name": name,
                "path": path.to_str().unwrap_or_default(),
                "size": size,
                "modified": modified,
            }))
        })
        .collect();

    serde_json::to_string(&files).unwrap_or_else(|_| "[]".to_string())
}

/// 导入旧版（阅读 2.x）备份目录
///
/// 对齐 `ImportOldData.importUri`：扫描 `myBookShelf.json` / `myBookSource.json` /
/// `myBookReplaceRule.json`，字段映射后写入 DB。缺文件不致命，记入 messages。
pub fn import_old_data(dir: &str) -> LegadoResult<String> {
    let dir_path = Path::new(dir);
    if !dir_path.is_dir() {
        return Err(LegadoError::Io(std::io::Error::other(format!(
            "目录不存在或不可用: {dir}"
        ))));
    }

    let mut messages: Vec<String> = Vec::new();
    let mut books_n = 0usize;
    let mut sources_n = 0usize;
    let mut rules_n = 0usize;

    // 书架
    let shelf_path = dir_path.join("myBookShelf.json");
    if shelf_path.is_file() {
        match fs::read_to_string(&shelf_path) {
            Ok(json) => match with_database(|db| {
                let conn = db.connection();
                let book_repo = BookRepository::new(conn);
                let existing: std::collections::HashSet<String> = book_repo
                    .find_all()?
                    .into_iter()
                    .map(|b| b.book_url)
                    .collect();
                let books = legado_core::import_old::from_old_books(&json, &existing);
                let mut n = 0usize;
                for book in &books {
                    match book_repo.insert(book) {
                        Ok(()) => n += 1,
                        Err(e) => log::warn!("导入旧版书籍失败（已跳过）: {} - {e}", book.book_url),
                    }
                }
                Ok(n)
            }) {
                Ok(n) => {
                    books_n = n;
                    messages.push(format!("成功导入书架{n}"));
                }
                Err(e) => messages.push(format!("导入书架失败: {e}")),
            },
            Err(e) => messages.push(format!("导入书架失败: {e}")),
        }
    } else {
        messages.push("未找到 myBookShelf.json".to_string());
    }

    // 书源
    let source_path = dir_path.join("myBookSource.json");
    if source_path.is_file() {
        match fs::read_to_string(&source_path) {
            Ok(json) => match with_database(|db| {
                let conn = db.connection();
                let source_repo = BookSourceRepository::new(conn);
                let sources = legado_core::import_old::from_old_book_sources(&json);
                let mut n = 0usize;
                for source in &sources {
                    match source_repo.insert(source) {
                        Ok(()) => n += 1,
                        Err(e) => log::warn!(
                            "导入旧版书源失败（已跳过）: {} - {e}",
                            source.book_source_url
                        ),
                    }
                }
                Ok(n)
            }) {
                Ok(n) => {
                    sources_n = n;
                    messages.push(format!("成功导入书源{n}"));
                }
                Err(e) => messages.push(format!("导入源失败: {e}")),
            },
            Err(e) => messages.push(format!("导入源失败: {e}")),
        }
    } else {
        messages.push("未找到 myBookSource.json".to_string());
    }

    // 替换规则
    let rule_path = dir_path.join("myBookReplaceRule.json");
    if rule_path.is_file() {
        match fs::read_to_string(&rule_path) {
            Ok(json) => match with_database(|db| {
                let conn = db.connection();
                let rule_repo = ReplaceRuleRepository::new(conn);
                let rules = legado_core::import_old::from_old_replace_rules(&json);
                let mut n = 0usize;
                for rule in &rules {
                    match rule_repo.insert(rule) {
                        Ok(_) => n += 1,
                        Err(e) => log::warn!("导入旧版替换规则失败（已跳过）: {} - {e}", rule.name),
                    }
                }
                Ok(n)
            }) {
                Ok(n) => {
                    rules_n = n;
                    messages.push(format!("成功导入替换规则{n}"));
                }
                Err(e) => messages.push(format!("导入替换规则失败: {e}")),
            },
            Err(e) => messages.push(format!("导入替换规则失败: {e}")),
        }
    } else {
        messages.push("未找到替换规则".to_string());
    }

    let result = serde_json::json!({
        "books": books_n,
        "bookSources": sources_n,
        "replaceRules": rules_n,
        "messages": messages,
    });
    serde_json::to_string(&result)
        .map_err(|e| LegadoError::Internal(format!("统计序列化失败: {e}")))
}

/// 收集 RSS 源（直接 SQL）
fn collect_rss_sources(conn: &rusqlite::Connection) -> LegadoResult<Vec<serde_json::Value>> {
    let mut stmt = conn
        .prepare("SELECT * FROM rssSources ORDER BY customOrder ASC")
        .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

    let columns: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();

    let rows = stmt
        .query_map([], |row| {
            let mut map = serde_json::Map::new();
            for (i, col) in columns.iter().enumerate() {
                let val: rusqlite::types::Value =
                    row.get(i).unwrap_or(rusqlite::types::Value::Null);
                let json_val = match val {
                    rusqlite::types::Value::Null => serde_json::Value::Null,
                    rusqlite::types::Value::Integer(v) => serde_json::Value::Number(v.into()),
                    rusqlite::types::Value::Real(v) => serde_json::Number::from_f64(v)
                        .map(serde_json::Value::Number)
                        .unwrap_or(serde_json::Value::Null),
                    rusqlite::types::Value::Text(v) => serde_json::Value::String(v),
                    rusqlite::types::Value::Blob(v) => {
                        use base64::Engine;
                        serde_json::Value::String(
                            base64::engine::general_purpose::STANDARD.encode(&v),
                        )
                    }
                };
                map.insert(col.clone(), json_val);
            }
            Ok(serde_json::Value::Object(map))
        })
        .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// 插入 RSS 源（直接 SQL）
fn insert_rss_source(conn: &rusqlite::Connection, source: &RssSource) -> LegadoResult<()> {
    conn.execute(
        "INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceIcon, sourceGroup,
            enabled, customOrder, type)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            source.source_url,
            source.source_name,
            source.source_icon,
            source.source_group,
            source.enabled,
            source.custom_order,
            source.rss_type,
        ],
    )
    .map_err(|e| LegadoError::Database(format!("插入 RSS 源失败: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_backup_create_and_restore() {
        let _db_guard = crate::db_state::ensure_test_db();

        let dir = std::env::temp_dir().join("legado_backup_test");
        let _ = fs::create_dir_all(&dir);
        let backup_path = dir.join("test_backup.json");
        let path_str = backup_path.to_str().unwrap();

        // 创建备份
        let result = backup_create(path_str);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), path_str);

        // 验证文件存在
        assert!(backup_path.exists());

        // 验证 JSON 格式
        let content = fs::read_to_string(&backup_path).unwrap();
        let data: BackupData = serde_json::from_str(&content).unwrap();
        assert_eq!(data.version, 1);
        assert!(data.backup_time > 0);

        // 恢复备份
        let restore_result = backup_restore(path_str);
        assert!(restore_result.is_ok());

        // 清理
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_backup_list() {
        let dir = std::env::temp_dir().join("legado_backup_list_test");
        let _ = fs::create_dir_all(&dir);

        // 创建测试文件
        let file1 = dir.join("backup1.json");
        let file2 = dir.join("backup2.json");
        let file3 = dir.join("not_backup.txt");
        fs::write(&file1, "{}").unwrap();
        fs::write(&file2, "{}").unwrap();
        fs::write(&file3, "text").unwrap();

        let result = backup_list(dir.to_str().unwrap());
        let list: Vec<serde_json::Value> = serde_json::from_str(&result).unwrap();
        assert_eq!(list.len(), 2);

        // 清理
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_backup_list_nonexistent_dir() {
        let result = backup_list("/nonexistent/path/that/does/not/exist");
        assert_eq!(result, "[]");
    }
}
