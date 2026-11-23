//! 角色卡（Characters）FFI API
//!
//! 契约 §2.56（R42 阶段 2A）：角色卡手动闭环数据层，逐条对齐参考版
//! `data/entities/BookKnowledge.kt:8-70`（`BookCharacterProfile`）与
//! `data/dao/BookKnowledgeDao.kt`。只做**手动建档最小闭环**，不含 AI 识别
//! （参考版 AI 栈依赖外部 LLM），不含其余 4 张角色/知识表。
//!
//! 三个入口：
//! - [`get_book_characters`]：按书取列表（`status != 3`、`updatedAt DESC`）；
//! - [`save_book_character`]：保存单条，**空 id 时按 `(bookUrl, name)` 精确查重
//!   并复用其 id**（用户裁决 D2=A，见下）；
//! - [`delete_book_character`]：按 `(bookUrl, id)` **硬删**。
//!
//! **D2=A 查重语义（本模块核心）**：参考版手动路径不做同名查重，`INSERT OR
//! REPLACE` 撞 `UNIQUE(bookUrl, name)` 时会**静默删旧行换新 id**，导致后续
//! 关系/事件/配音绑定全部指向失效 id。我方在 `id` 为空时先按
//! `(bookUrl, name)` **精确**查（不走 `aliasesJson LIKE`，参考版
//! `CastProfileMirror.kt:31-38` 自己已否定该用法），命中则复用其 id 与
//! `createdAt` 并更新其余字段。
//!
//! **已知差异（用户裁决 D4=A / D5=A，照抄参考版）**：换源后角色不迁移
//! （表以 `bookUrl` 为键）、不纳入备份、删书不清理孤儿行。

use uuid::Uuid;

use legado_core::models::BookCharacter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::BookCharacterRepository;

use crate::db_state::with_database;

/// 按书取角色列表（`status != 3`、`updatedAt DESC`）
///
/// `limit` 经仓储层 clamp（`<=0` → 50，`>500` → 500），不 panic。
/// `book_url` 为空或无数据 → 空数组（**不抛错**）。
pub fn get_book_characters(book_url: &str, limit: i32) -> LegadoResult<Vec<BookCharacter>> {
    with_database(|db| {
        let repo = BookCharacterRepository::new(db.connection());
        repo.find_by_book(book_url, limit)
    })
}

/// 保存角色卡，返回**落库后重新查出**的完整对象
///
/// 语义：
/// - 解析失败 → 参数错误；`bookUrl` 空白或 `name` 空白 → 参数错误；
/// - `id` 为空/空白：按 `(bookUrl, name)` 精确查重，命中则复用其 id 与
///   `createdAt`（用户裁决 D2=A）；未命中生成 UUID v4，`createdAt = now`；
/// - `id` 非空：按 id 覆盖；`createdAt <= 0` 时沿用库内既有值，仍取不到才用 now；
/// - `updatedAt` **恒写当前毫秒**（忽略入参）；
/// - `aliasesJson` / `tagsJson` 空白时回填 `"[]"`；`source` 空白回填 `"user"`，
///   `voiceGender` / `voiceAgeBand` 空白回填 `"unknown"`（与 DDL 默认一致）；
/// - 改名撞上**别人**的 `(bookUrl, name)` → 明确错误「已存在同名角色」。
pub fn save_book_character(profile_json: &str) -> LegadoResult<BookCharacter> {
    let mut character: BookCharacter = serde_json::from_str(profile_json)
        .map_err(|e| LegadoError::Parser(format!("解析角色卡 JSON 失败: {e}")))?;

    if character.book_url.trim().is_empty() {
        return Err(LegadoError::Internal("角色卡 bookUrl 不能为空".into()));
    }
    if character.name.trim().is_empty() {
        return Err(LegadoError::Internal("角色卡 name 不能为空".into()));
    }
    normalize_defaults(&mut character);

    let now = current_time_millis();
    with_database(|db| {
        let repo = BookCharacterRepository::new(db.connection());

        let incoming_id = character.id.trim().to_string();
        if incoming_id.is_empty() {
            // D2=A：空 id → 按 (bookUrl, name) 精确查重，命中复用 id 与 createdAt
            match repo.find_by_name(&character.book_url, &character.name)? {
                Some(existing) => {
                    character.id = existing.id;
                    character.created_at = existing.created_at;
                }
                None => {
                    character.id = Uuid::new_v4().to_string();
                    character.created_at = now;
                }
            }
        } else {
            character.id = incoming_id;
            // 改名撞别人：目标 (bookUrl, name) 已属于另一 id → 明确报错
            if let Some(conflict) = repo.find_by_name(&character.book_url, &character.name)? {
                if conflict.id != character.id {
                    return Err(LegadoError::Internal(
                        "已存在同名角色（同一本书内角色名必须唯一）".into(),
                    ));
                }
            }
            // 有 id：createdAt 优先沿用库内既有值（防调用方传 0 或脏值抹掉创建时间）
            let existing_created = repo.get_by_id(&character.id)?.map(|row| row.created_at);
            character.created_at = if character.created_at <= 0 {
                existing_created.unwrap_or(now)
            } else {
                character.created_at
            };
        }
        character.updated_at = now;

        // 兜底：INSERT OR REPLACE 仍可能撞 UNIQUE（并发/绕过路径），转明确文案
        repo.upsert(&character).map_err(|e| {
            let msg = e.to_string();
            if msg.contains("UNIQUE constraint failed") || msg.contains("constraint failed") {
                LegadoError::Internal("已存在同名角色（同一本书内角色名必须唯一）".into())
            } else {
                e
            }
        })?;

        repo.get_by_id(&character.id)?.ok_or_else(|| {
            LegadoError::Database(format!("角色卡落库后回查失败（id={}）", character.id))
        })
    })
}

/// 按 `(bookUrl, id)` 硬删角色卡；不存在返回 false（不报错）
pub fn delete_book_character(book_url: &str, character_id: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = BookCharacterRepository::new(db.connection());
        repo.delete(book_url, character_id)
    })
}

/// 空白可选字段回填契约默认值（与 DDL / 参考版实体默认一致）
fn normalize_defaults(character: &mut BookCharacter) {
    if character.aliases_json.trim().is_empty() {
        character.aliases_json = "[]".to_string();
    }
    if character.tags_json.trim().is_empty() {
        character.tags_json = "[]".to_string();
    }
    if character.source.trim().is_empty() {
        character.source = "user".to_string();
    }
    if character.voice_gender.trim().is_empty() {
        character.voice_gender = "unknown".to_string();
    }
    if character.voice_age_band.trim().is_empty() {
        character.voice_age_band = "unknown".to_string();
    }
    if character.schema_version <= 0 {
        character.schema_version = 1;
    }
    // 置信度越界/非有限值收敛到契约区间（手动恒 1.0）
    if !character.confidence.is_finite() || !(0.0..=1.0).contains(&character.confidence) {
        character.confidence = 1.0;
    }
}

/// 当前 Unix 毫秒时间戳
fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile_json(book_url: &str, name: &str) -> String {
        format!(r#"{{"bookUrl":"{book_url}","name":"{name}"}}"#)
    }

    /// 契约测试 3：id 为空 → 生成 UUID，createdAt == updatedAt
    #[test]
    fn test_save_generates_uuid_and_timestamps() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "bk://character_uuid";

        let saved = save_book_character(&profile_json(book_url, "角色甲")).unwrap();
        assert!(!saved.id.trim().is_empty(), "空 id 应生成 UUID");
        let parsed = Uuid::parse_str(&saved.id).expect("生成的 id 应为合法 UUID");
        assert_eq!(parsed.get_version_num(), 4, "应为 UUID v4");
        assert!(saved.created_at > 0, "createdAt 应为当前毫秒");
        assert_eq!(
            saved.created_at, saved.updated_at,
            "新建时 createdAt 与 updatedAt 应相同"
        );
        assert_eq!(saved.aliases_json, "[]", "空白别名应回填 []");
        assert_eq!(saved.tags_json, "[]");
        assert_eq!(saved.source, "user");
        assert_eq!(saved.status, 1);
        assert_eq!(saved.confidence, 1.0);
        assert_eq!(saved.voice_gender, "unknown");
        assert_eq!(saved.voice_age_band, "unknown");

        delete_book_character(book_url, &saved.id).unwrap();
    }

    /// 契约测试 4（D2=A 核心）：同名再存一次 → id 不变、字段被更新、总行数仍 1
    #[test]
    fn test_save_dedupes_by_name_and_reuses_id() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "bk://character_dedupe";

        let first = save_book_character(&profile_json(book_url, "角色乙")).unwrap();
        let original_id = first.id.clone();
        let original_created = first.created_at;

        // 第二次：同样空 id、同名，带新字段
        let second = save_book_character(&format!(
            r#"{{"bookUrl":"{book_url}","name":"角色乙","role":"male_lead",
                 "personality":"沉稳","summary":"新简介","tagsJson":"[\"主角\"]"}}"#
        ))
        .unwrap();

        assert_eq!(second.id, original_id, "D2=A：同名应复用 id，不得换新 id");
        assert_eq!(
            second.created_at, original_created,
            "复用行时 createdAt 必须保留"
        );
        assert_eq!(second.role, "male_lead", "字段应被更新");
        assert_eq!(second.personality, "沉稳");
        assert_eq!(second.summary, "新简介");
        assert_eq!(second.tags_json, r#"["主角"]"#);
        assert!(
            second.updated_at >= first.updated_at,
            "updatedAt 应刷新为当前毫秒"
        );

        let list = get_book_characters(book_url, 50).unwrap();
        assert_eq!(list.len(), 1, "同名重复保存不得新增第二行");
        assert_eq!(list[0].id, original_id);

        // 第三次：显式带同一 id 再存，仍是同一行
        let third = save_book_character(&format!(
            r#"{{"id":"{original_id}","bookUrl":"{book_url}","name":"角色乙","summary":"再改"}}"#
        ))
        .unwrap();
        assert_eq!(third.id, original_id);
        assert_eq!(
            third.created_at, original_created,
            "有 id 路径也须保留 createdAt"
        );
        assert_eq!(third.summary, "再改");
        assert_eq!(get_book_characters(book_url, 50).unwrap().len(), 1);

        delete_book_character(book_url, &original_id).unwrap();
    }

    /// 契约测试 5：id 为 A，改成已存在的 name → 明确 Err（不得静默 REPLACE）
    #[test]
    fn test_save_rename_collision_returns_clear_error() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "bk://character_rename";

        let a = save_book_character(&profile_json(book_url, "角色丙")).unwrap();
        let b = save_book_character(&profile_json(book_url, "角色丁")).unwrap();
        assert_ne!(a.id, b.id);

        let err = save_book_character(&format!(
            r#"{{"id":"{}","bookUrl":"{book_url}","name":"角色丁"}}"#,
            a.id
        ))
        .unwrap_err();
        assert!(
            err.to_string().contains("已存在同名角色"),
            "改名撞别人应返回明确文案，实际: {err}"
        );

        // 冲突未破坏库：两行仍在，id 不变
        let list = get_book_characters(book_url, 50).unwrap();
        assert_eq!(list.len(), 2, "冲突失败不得删改既有行");
        let ids: Vec<_> = list.iter().map(|c| c.id.as_str()).collect();
        assert!(ids.contains(&a.id.as_str()));
        assert!(ids.contains(&b.id.as_str()));

        // 改成自己的名字（无变化）应成功
        let same = save_book_character(&format!(
            r#"{{"id":"{}","bookUrl":"{book_url}","name":"角色丙","summary":"自改"}}"#,
            a.id
        ))
        .unwrap();
        assert_eq!(same.id, a.id);
        assert_eq!(same.summary, "自改");

        delete_book_character(book_url, &a.id).unwrap();
        delete_book_character(book_url, &b.id).unwrap();
    }

    /// 契约测试 6：deleteBookCharacter 删后查不到返回 true，再删 false
    #[test]
    fn test_delete_returns_true_then_false() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "bk://character_delete";

        let saved = save_book_character(&profile_json(book_url, "角色戊")).unwrap();
        assert_eq!(get_book_characters(book_url, 50).unwrap().len(), 1);

        assert!(
            delete_book_character(book_url, &saved.id).unwrap(),
            "命中应返回 true"
        );
        assert!(get_book_characters(book_url, 50).unwrap().is_empty());
        assert!(
            !delete_book_character(book_url, &saved.id).unwrap(),
            "再删应返回 false"
        );
        // 错误 bookUrl 也不得命中
        let again = save_book_character(&profile_json(book_url, "角色己")).unwrap();
        assert!(!delete_book_character("bk://wrong_book", &again.id).unwrap());
        assert!(delete_book_character(book_url, &again.id).unwrap());
    }

    /// 契约测试 2：getBookCharacters 排除 status=3 且 updatedAt DESC
    #[test]
    fn test_get_book_characters_filters_deleted_and_orders() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "bk://character_list";

        let c1 = save_book_character(&profile_json(book_url, "列表甲")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(3));
        let c2 = save_book_character(&profile_json(book_url, "列表乙")).unwrap();
        let mut deleted = save_book_character(&profile_json(book_url, "列表丙")).unwrap();
        deleted.status = 3;
        let deleted = save_book_character(&serde_json::to_string(&deleted).unwrap()).unwrap();
        assert_eq!(deleted.status, 3);

        let list = get_book_characters(book_url, 50).unwrap();
        let ids: Vec<_> = list.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![c2.id.as_str(), c1.id.as_str()],
            "updatedAt DESC、排除 status=3"
        );
        assert!(list.iter().all(|c| c.name != "列表丙"));

        // limit clamp：0 / 负数不 panic
        assert_eq!(get_book_characters(book_url, 0).unwrap().len(), 2);
        assert_eq!(get_book_characters(book_url, -5).unwrap().len(), 2);
        assert_eq!(get_book_characters(book_url, 1).unwrap().len(), 1);
        // 空 bookUrl / 无数据 → 空数组
        assert!(get_book_characters("", 50).unwrap().is_empty());

        for id in [&c1.id, &c2.id, &deleted.id] {
            delete_book_character(book_url, id).unwrap();
        }
    }

    /// 契约测试 8：返回 JSON 键名 camelCase
    #[test]
    fn test_returned_json_uses_camel_case_keys() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "bk://character_json_keys";

        let saved = save_book_character(&profile_json(book_url, "键名角色")).unwrap();
        let value: serde_json::Value = serde_json::to_value(&saved).unwrap();

        for key in [
            "bookUrl",
            "aliasesJson",
            "avatarUri",
            "tagsJson",
            "voiceGender",
            "voiceAgeBand",
            "schemaVersion",
            "createdAt",
            "updatedAt",
        ] {
            assert!(
                value.get(key).is_some(),
                "返回 JSON 应含 camelCase 键 {key}"
            );
        }
        for key in [
            "book_url",
            "aliases_json",
            "avatar_uri",
            "tags_json",
            "voice_gender",
            "voice_age_band",
            "schema_version",
            "created_at",
            "updated_at",
        ] {
            assert!(value.get(key).is_none(), "不应出现 snake_case 键 {key}");
        }

        // 列表同样 camelCase（裸数组元素）
        let list = get_book_characters(book_url, 50).unwrap();
        let arr = serde_json::to_value(&list).unwrap();
        assert!(arr.is_array(), "列表应序列化为裸 JSON 数组");
        assert_eq!(arr[0]["bookUrl"], book_url);

        delete_book_character(book_url, &saved.id).unwrap();
    }

    /// 参数校验：非法 JSON / 空 bookUrl / 空 name 均为参数错误
    #[test]
    fn test_save_rejects_invalid_input() {
        let _db_guard = crate::db_state::ensure_test_db();

        let err = save_book_character("not json").unwrap_err();
        assert!(
            err.to_string().contains("解析角色卡 JSON 失败"),
            "非法 JSON 应报解析错误，实际: {err}"
        );

        let err = save_book_character(r#"{"bookUrl":"  ","name":"角色"}"#).unwrap_err();
        assert!(err.to_string().contains("bookUrl 不能为空"), "实际: {err}");

        let err = save_book_character(r#"{"bookUrl":"bk://x","name":"   "}"#).unwrap_err();
        assert!(err.to_string().contains("name 不能为空"), "实际: {err}");
    }
}
