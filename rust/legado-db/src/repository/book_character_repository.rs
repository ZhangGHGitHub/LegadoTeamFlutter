//! BookCharacterRepository — book_character_profiles 表数据访问层
//! （schema v120，角色卡 Characters 手动闭环）
//!
//! 逐条对齐参考版 `data/dao/BookKnowledgeDao.kt` 的角色档案查询：
//! - `getCharacterProfiles(bookUrl, limit)` → [`BookCharacterRepository::find_by_book`]
//!   （`status != 3`、`ORDER BY updatedAt DESC`、limit clamp `1..500`）；
//! - 同名精确查重 → [`BookCharacterRepository::find_by_name`]
//!   （**只认完全相等**：`WHERE bookUrl = ? AND name = ?`。参考版
//!   `getCharacterProfile` 的 `id = x OR name = x OR aliasesJson LIKE '%x%'`
//!   **不得复用**——`CastProfileMirror.kt:31-38` 自己已否定 LIKE 用法，
//!   LIKE 会把「记着该别名的别人」捞出来改名）；
//! - `upsertCharacterProfile` → [`BookCharacterRepository::upsert`]
//!   （`INSERT OR REPLACE`）；
//! - `deleteCharacterProfile` → [`BookCharacterRepository::delete`]（硬删）。
//!
//! 角色卡与其余 4 张角色/知识表独立；**无外键**；**不纳入备份**。
//!
//! 列表查询走 [`super::collect_rows_logged`]：坏行（列类型漂移/损坏）跳过但记
//! stderr 日志，避免角色「凭空消失」无从定位（同 `book_marking_repository.rs`
//! 批7b-1 先例）。

use rusqlite::{params, Connection, OptionalExtension};

use legado_core::models::BookCharacter;
use legado_core::{LegadoError, LegadoResult};

/// 查询列（与 [`row_to_character`] 的索引一一对应）
const SELECT_COLUMNS: &str = "SELECT id, bookUrl, name, aliasesJson, avatarUri, tagsJson,
    role, voiceGender, voiceAgeBand, personality, summary, status, source, confidence,
    schemaVersion, createdAt, updatedAt FROM book_character_profiles";

/// 列表查询默认上限（对齐参考版详情页 `getCharacterProfiles(limit = 50)`）
pub const DEFAULT_LIST_LIMIT: i32 = 50;

/// 列表查询上限（对齐参考版 `limit clamp 1..500`）
pub const MAX_LIST_LIMIT: i32 = 500;

/// 把外部传入的 limit 收敛到 `1..=MAX_LIST_LIMIT`
///
/// `limit <= 0` 取默认值（不 panic，不返回全表）；
/// 超过上限按上限截断（对齐参考版 `coerceIn(1, 500)`）。
pub fn clamp_limit(limit: i32) -> i32 {
    if limit <= 0 {
        DEFAULT_LIST_LIMIT
    } else {
        limit.min(MAX_LIST_LIMIT)
    }
}

/// 角色卡数据访问层
pub struct BookCharacterRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookCharacterRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 按书取角色列表：`status != 3`（排除 DELETED）、`ORDER BY updatedAt DESC`
    ///
    /// `limit` 经 [`clamp_limit`] 收敛（`<=0` → 默认 50，`>500` → 500）。
    /// 同毫秒多条时以 `id` 兜底，保证结果可复现。
    pub fn find_by_book(&self, book_url: &str, limit: i32) -> LegadoResult<Vec<BookCharacter>> {
        let limit = clamp_limit(limit);
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS} WHERE bookUrl = ?1 AND status != 3
                 ORDER BY updatedAt DESC, id ASC LIMIT ?2"
            ))
            .map_err(|e| LegadoError::Database(format!("准备角色卡列表查询失败: {e}")))?;
        let rows = super::collect_rows_logged(
            stmt.query_map(params![book_url, limit], row_to_character)
                .map_err(|e| LegadoError::Database(format!("查询角色卡失败: {e}")))?,
            "book_character_profiles find_by_book",
        );
        Ok(rows)
    }

    /// 按 `(bookUrl, name)` **精确**查重（保存路径复用 id 用）
    ///
    /// 只认完全相等，**不走 LIKE**（见模块文档）。同书同名由
    /// `UNIQUE(bookUrl, name)` 保证至多一行；`ORDER BY` 仅为防御性稳定。
    /// 不过滤 `status`：DELETED 行仍占用唯一键，复用它才能避免 REPLACE 换 id。
    pub fn find_by_name(&self, book_url: &str, name: &str) -> LegadoResult<Option<BookCharacter>> {
        self.conn
            .query_row(
                &format!("{SELECT_COLUMNS} WHERE bookUrl = ?1 AND name = ?2 LIMIT 1"),
                params![book_url, name],
                row_to_character,
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询同名角色卡失败: {e}")))
    }

    /// 按主键读取（不存在返回 None）
    pub fn get_by_id(&self, id: &str) -> LegadoResult<Option<BookCharacter>> {
        self.conn
            .query_row(
                &format!("{SELECT_COLUMNS} WHERE id = ?1"),
                params![id],
                row_to_character,
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询角色卡失败: {e}")))
    }

    /// 整条写入/覆盖（`INSERT OR REPLACE`）
    ///
    /// 注意 `UNIQUE(bookUrl, name)` 的副作用：**不同 id 但同名**的 REPLACE 会
    /// 静默删旧行（SQLite `ON CONFLICT` 语义）。保存路径须先经
    /// [`Self::find_by_name`] 复用 id，避免换 id 导致关系/事件/配音绑定失效。
    /// 若调用方绕过该约定（如「有 id 但改名撞了别人」），`execute` 会返回
    /// UNIQUE 约束错误，由上层转成明确文案。
    pub fn upsert(&self, character: &BookCharacter) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO book_character_profiles
                 (id, bookUrl, name, aliasesJson, avatarUri, tagsJson, role,
                  voiceGender, voiceAgeBand, personality, summary, status, source,
                  confidence, schemaVersion, createdAt, updatedAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
                params![
                    character.id,
                    character.book_url,
                    character.name,
                    character.aliases_json,
                    character.avatar_uri,
                    character.tags_json,
                    character.role,
                    character.voice_gender,
                    character.voice_age_band,
                    character.personality,
                    character.summary,
                    character.status,
                    character.source,
                    character.confidence,
                    character.schema_version,
                    character.created_at,
                    character.updated_at,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("写入角色卡失败: {e}")))?;
        Ok(())
    }

    /// 按 `(bookUrl, id)` **硬删**（物理 DELETE），返回是否命中
    ///
    /// 带 `bookUrl` 条件防跨书误删（对齐契约签名）。不存在为 no-op（返回 false）。
    pub fn delete(&self, book_url: &str, id: &str) -> LegadoResult<bool> {
        let rows = self
            .conn
            .execute(
                "DELETE FROM book_character_profiles WHERE bookUrl = ?1 AND id = ?2",
                params![book_url, id],
            )
            .map_err(|e| LegadoError::Database(format!("删除角色卡失败: {e}")))?;
        Ok(rows > 0)
    }
}

fn row_to_character(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookCharacter> {
    Ok(BookCharacter {
        id: row.get(0)?,
        book_url: row.get(1)?,
        name: row.get(2)?,
        aliases_json: row.get(3)?,
        avatar_uri: row.get(4)?,
        tags_json: row.get(5)?,
        role: row.get(6)?,
        voice_gender: row.get(7)?,
        voice_age_band: row.get(8)?,
        personality: row.get(9)?,
        summary: row.get(10)?,
        status: row.get(11)?,
        source: row.get(12)?,
        confidence: row.get(13)?,
        schema_version: row.get(14)?,
        created_at: row.get(15)?,
        updated_at: row.get(16)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init_in_memory_database;

    fn make_character(
        id: &str,
        book_url: &str,
        name: &str,
        status: i32,
        updated_at: i64,
    ) -> BookCharacter {
        BookCharacter {
            id: id.to_string(),
            book_url: book_url.to_string(),
            name: name.to_string(),
            updated_at,
            created_at: updated_at,
            status,
            ..BookCharacter::default()
        }
    }

    /// 契约测试 2：getBookCharacters 排除 status=3、按 updatedAt DESC
    #[test]
    fn test_find_by_book_excludes_deleted_and_orders_desc() {
        let db = init_in_memory_database().unwrap();
        let repo = BookCharacterRepository::new(db.connection());
        let book = "https://a/char_order";

        repo.upsert(&make_character("c1", book, "甲", 1, 100))
            .unwrap();
        repo.upsert(&make_character("c2", book, "乙", 1, 300))
            .unwrap();
        repo.upsert(&make_character("c3", book, "丙", 3, 500))
            .unwrap();

        let list = repo.find_by_book(book, 50).unwrap();
        let ids: Vec<_> = list.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, vec!["c2", "c1"], "status=3 应排除，updatedAt DESC");
        assert!(list.iter().all(|c| c.status != 3));

        // 跨书隔离
        repo.upsert(&make_character("x1", "https://a/other", "甲", 1, 999))
            .unwrap();
        let list = repo.find_by_book(book, 50).unwrap();
        assert_eq!(list.len(), 2, "不得串书");

        // 空 bookUrl / 无数据 → 空数组（不报错）
        assert!(repo.find_by_book("", 50).unwrap().is_empty());
        assert!(repo
            .find_by_book("https://a/no_such_book", 50)
            .unwrap()
            .is_empty());
    }

    /// 契约测试 7：limit clamp 不 panic（0 / 负数 → 默认，超限 → 500）
    #[test]
    fn test_limit_clamp_never_panics() {
        let db = init_in_memory_database().unwrap();
        let repo = BookCharacterRepository::new(db.connection());
        let book = "https://a/char_limit";

        for i in 0..3 {
            repo.upsert(&make_character(
                &format!("l{i}"),
                book,
                &format!("角色{i}"),
                1,
                100 + i as i64,
            ))
            .unwrap();
        }

        for limit in [0, -1, i32::MIN] {
            let list = repo.find_by_book(book, limit).unwrap();
            assert_eq!(list.len(), 3, "limit={limit} 应按默认 50 返回全部 3 条");
        }
        // 超大 limit 按 500 截断，不 panic
        assert_eq!(repo.find_by_book(book, i32::MAX).unwrap().len(), 3);

        assert_eq!(clamp_limit(0), DEFAULT_LIST_LIMIT);
        assert_eq!(clamp_limit(-7), DEFAULT_LIST_LIMIT);
        assert_eq!(clamp_limit(1), 1);
        assert_eq!(clamp_limit(200), 200);
        assert_eq!(clamp_limit(10_000), MAX_LIST_LIMIT);
    }

    /// 契约测试 4 的前置能力：find_by_name 精确匹配（不走 LIKE、不跨书）
    #[test]
    fn test_find_by_name_is_exact_match() {
        let db = init_in_memory_database().unwrap();
        let repo = BookCharacterRepository::new(db.connection());
        let book = "https://a/char_exact";

        repo.upsert(&BookCharacter {
            id: "e1".into(),
            book_url: book.into(),
            name: "林".into(),
            aliases_json: r#"["林林"]"#.into(),
            ..BookCharacter::default()
        })
        .unwrap();
        repo.upsert(&BookCharacter {
            id: "e2".into(),
            book_url: book.into(),
            name: "林林".into(),
            ..BookCharacter::default()
        })
        .unwrap();

        let hit = repo.find_by_name(book, "林").unwrap().unwrap();
        assert_eq!(hit.id, "e1", "必须精确匹配 name，不得被别名行抢走");
        assert!(repo.find_by_name(book, "林林").unwrap().is_some());
        assert!(
            repo.find_by_name(book, "林").unwrap().unwrap().id != "e2",
            "LIKE 语义会把别名行捞出来"
        );

        // 子串/别名都不得命中
        assert!(repo.find_by_name(book, "林林林").unwrap().is_none());
        assert!(repo.find_by_name(book, "").unwrap().is_none());
        // 跨书同名不算命中
        assert!(repo
            .find_by_name("https://a/char_exact_other", "林")
            .unwrap()
            .is_none());
    }

    /// 契约测试 6 的仓储层：硬删命中返回 true，再删 false，且按 bookUrl 隔离
    #[test]
    fn test_delete_is_hard_and_scoped_by_book() {
        let db = init_in_memory_database().unwrap();
        let repo = BookCharacterRepository::new(db.connection());
        let book = "https://a/char_delete";

        repo.upsert(&make_character("d1", book, "删我", 1, 100))
            .unwrap();

        // 错误 bookUrl 不得误删
        assert!(!repo.delete("https://a/wrong_book", "d1").unwrap());
        assert!(repo.get_by_id("d1").unwrap().is_some());

        assert!(repo.delete(book, "d1").unwrap(), "存在时应返回 true");
        assert!(repo.get_by_id("d1").unwrap().is_none(), "应为物理删除");
        assert!(!repo.delete(book, "d1").unwrap(), "再删应返回 false");
    }

    /// upsert 覆盖同 id；**不同 id 同名会静默删旧行换 id**（D2=A 的存在理由）
    ///
    /// 该测试把 SQLite `INSERT OR REPLACE` 的危险语义固化为可执行证据：
    /// 命中 `UNIQUE(bookUrl, name)` 时 REPLACE **不报错**，而是删旧行插新行
    /// （id 变成新的）。参考版手动路径正因此让关系/事件/配音绑定全部指向
    /// 失效 id；我方必须在 FFI 保存路径先按 `(bookUrl, name)` 查重复用 id。
    #[test]
    fn test_upsert_replace_and_unique_conflict() {
        let db = init_in_memory_database().unwrap();
        let repo = BookCharacterRepository::new(db.connection());
        let book = "https://a/char_upsert";

        let mut character = make_character("u1", book, "角色", 1, 100);
        repo.upsert(&character).unwrap();

        character.summary = "新简介".into();
        character.updated_at = 200;
        repo.upsert(&character).unwrap();
        let loaded = repo.get_by_id("u1").unwrap().unwrap();
        assert_eq!(loaded.summary, "新简介");
        assert_eq!(loaded.created_at, 100, "upsert 不得改写 createdAt");

        let count: i64 = db
            .connection()
            .query_row("SELECT COUNT(*) FROM book_character_profiles", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 1, "同 id 覆盖不得新增行");

        // 不同 id 同名：REPLACE 静默删旧行（旧 id 消失、新 id 上位）——正是 D2=A 要防的
        let dup = make_character("u2", book, "角色", 1, 300);
        repo.upsert(&dup).unwrap();
        assert!(
            repo.get_by_id("u1").unwrap().is_none(),
            "REPLACE 会静默删除旧 id 行（故 FFI 保存路径必须先查重）"
        );
        let survivor = repo.get_by_id("u2").unwrap().unwrap();
        assert_eq!(survivor.name, "角色");
        let count: i64 = db
            .connection()
            .query_row("SELECT COUNT(*) FROM book_character_profiles", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 1, "UNIQUE 保证同书同名至多一行");
    }

    /// 损坏行跳过不 panic（同 book_marks 批7b-1 P3-1 口径）
    #[test]
    fn test_damaged_row_is_skipped_without_panic() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookCharacterRepository::new(conn);
        let book = "https://a/char_bad";

        repo.upsert(&make_character("good", book, "好行", 1, 100))
            .unwrap();
        // status 声明为 INTEGER，SQLite 动态类型允许写入非数字文本，
        // 读回 row.get::<i32> 失败 → collect_rows_logged 坏行分支。
        conn.execute(
            "INSERT INTO book_character_profiles (id, bookUrl, name, status)
             VALUES ('bad', ?1, '坏行', 'not-a-number')",
            params![book],
        )
        .unwrap();

        let list = repo.find_by_book(book, 50).unwrap();
        assert_eq!(list.len(), 1, "坏行应跳过，不得整查失败");
        assert_eq!(list[0].id, "good");

        // 坏行仍在库内（只跳过，不误删）
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_character_profiles", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(total, 2);
    }
}
