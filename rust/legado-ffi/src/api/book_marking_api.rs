//! 书签标记（book_marks）FFI API
//!
//! 契约 §2.52（批7b-1）：书签标记数据层，逐条对齐参考版
//! `data/entities/BookMarking.kt:21-46` 与 `data/dao/BookMarkingDao.kt:13-87`。
//! 与既有书签（`bookmarks`，页面导航）和正文高亮记录（`highlights`）相互独立。
//! 备份口径（审查 20261113 P1-1 更正）：参考版自 `488a375`（2026-09-28）起在
//! `Backup.kt:71,158` / `Restore.kt:163-165` 备份 `bookMarking.json`，批7b 当时
//! 登记的「与参考版一致不纳入备份」不成立；备份格式 v6 起 `book_marks` 随
//! `backup_create` / `backup_restore` 与参考版 zip 往返（见 `backup_api.rs`）。
//!
//! 本模块只做数据层，不做渲染：划词内联卡、编辑 Sheet、目录笔记页与正文渲染
//! 属 7b-2，锚点解析与文本匹配放 Dart 侧。

use uuid::Uuid;

use legado_core::models::BookMarking;
use legado_core::{LegadoError, LegadoResult};
use legado_db::BookMarkingRepository;

use crate::db_state::with_database;

/// 按「书名 + 作者」取全部章节/全部源的标记
///
/// 排序 `chapterIndex` 升序、`createdAt` 升序（对齐参考版 `flowByBook`）。
pub fn book_marking_list_by_book(
    book_name: &str,
    book_author: &str,
) -> LegadoResult<Vec<BookMarking>> {
    with_database(|db| {
        let repo = BookMarkingRepository::new(db.connection());
        repo.list_by_book(book_name, book_author)
    })
}

/// 按源地址取标记
///
/// `chapter_index` 为 Some 时同时返回 `chapterIndex IS NULL` 的全局标记
/// （对齐参考版 `getForChapterSync`）；None 时取该书全部章节。`createdAt` 升序。
pub fn book_marking_list_for_chapter(
    book_url: &str,
    chapter_index: Option<i32>,
) -> LegadoResult<Vec<BookMarking>> {
    with_database(|db| {
        let repo = BookMarkingRepository::new(db.connection());
        repo.list_for_chapter(book_url, chapter_index)
    })
}

/// 保存书签标记，返回落库后的完整对象
///
/// - `id` 为空串 → 生成 UUID v4；
/// - `createdAt <= 0` → 当前毫秒；
/// - `updatedAt` 恒写当前毫秒（忽略入参）；
/// - `INSERT OR REPLACE`（同 id 覆盖，重复导入幂等）；
/// - `anchorJson` 空/纯空白 → 参数错误；非法 JSON → 参数错误。
pub fn book_marking_save(marking_json: &str) -> LegadoResult<BookMarking> {
    let mut marking: BookMarking = serde_json::from_str(marking_json)
        .map_err(|e| LegadoError::Parser(format!("解析书签标记 JSON 失败: {e}")))?;
    if marking.anchor_json.trim().is_empty() {
        return Err(LegadoError::Internal("书签标记 anchorJson 不能为空".into()));
    }
    let now = current_time_millis();
    if marking.id.trim().is_empty() {
        marking.id = Uuid::new_v4().to_string();
    }
    if marking.created_at <= 0 {
        marking.created_at = now;
    }
    marking.updated_at = now;

    with_database(|db| {
        let repo = BookMarkingRepository::new(db.connection());
        repo.upsert(&marking)?;
        Ok(marking)
    })
}

/// 按主键删除书签标记；id 不存在为 no-op（不报错）
pub fn book_marking_delete(id: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookMarkingRepository::new(db.connection());
        repo.delete(id)?;
        Ok(())
    })
}

/// 更新启用状态与 `updatedAt`；id 不存在为 no-op（不报错）
pub fn book_marking_set_enabled(id: &str, enabled: bool) -> LegadoResult<()> {
    let now = current_time_millis();
    with_database(|db| {
        let repo = BookMarkingRepository::new(db.connection());
        repo.set_enabled(id, enabled, now)?;
        Ok(())
    })
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

    fn save_json(book_url: &str, book_name: &str, chapter_index: Option<i32>) -> String {
        let chapter = chapter_index
            .map(|i| i.to_string())
            .unwrap_or_else(|| "null".to_string());
        format!(
            r#"{{"bookUrl":"{book_url}","bookName":"{book_name}","bookAuthor":"标记作者",
                 "chapterIndex":{chapter},"anchorJson":"{{\"p\":1}}",
                 "styleJson":"{{\"textColor\":-1}}","note":"n","chapterName":"章"}}"#
        )
    }

    /// 空 id 生成 UUID v4；createdAt<=0 补当前毫秒；updatedAt 恒写当前毫秒
    #[test]
    fn test_save_generates_uuid_and_timestamps() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_name = "ffi标记UUID测试书";

        let first = book_marking_save(&save_json("bk://marking_uuid", book_name, Some(0))).unwrap();
        assert!(!first.id.trim().is_empty(), "空 id 应生成 UUID");
        let parsed = Uuid::parse_str(&first.id).expect("生成的 id 应为合法 UUID");
        assert_eq!(parsed.get_version_num(), 4, "应为 UUID v4");
        assert!(first.created_at > 0, "createdAt 应补当前毫秒");
        assert!(
            first.updated_at >= first.created_at,
            "updatedAt 应为当前毫秒"
        );

        // 同 id 二次保存：id/createdAt 保留，updatedAt 重写
        let mut json: serde_json::Value =
            serde_json::from_str(&save_json("bk://marking_uuid", book_name, Some(0))).unwrap();
        json["id"] = serde_json::Value::String(first.id.clone());
        json["createdAt"] = serde_json::Value::from(first.created_at);
        json["note"] = serde_json::Value::String("更新备注".into());
        json["updatedAt"] = serde_json::Value::from(1);
        let second = book_marking_save(&json.to_string()).unwrap();
        assert_eq!(second.id, first.id);
        assert_eq!(second.created_at, first.created_at, "createdAt 不得被覆盖");
        assert!(
            second.updated_at >= first.updated_at,
            "updatedAt 应重写为当前毫秒"
        );
        assert_eq!(second.note, "更新备注");

        let listed = book_marking_list_by_book(book_name, "标记作者").unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, first.id);

        book_marking_delete(&first.id).unwrap();
        assert!(book_marking_list_by_book(book_name, "标记作者")
            .unwrap()
            .is_empty());
    }

    /// 空 anchor / 非法 JSON 为参数错误
    #[test]
    fn test_save_rejects_empty_anchor_and_invalid_json() {
        let _db_guard = crate::db_state::ensure_test_db();

        let empty_anchor = r#"{"bookUrl":"bk://bad","anchorJson":"  "}"#;
        let err = book_marking_save(empty_anchor).unwrap_err();
        assert!(
            err.to_string().contains("anchorJson 不能为空"),
            "空 anchor 应报参数错误，实际: {err}"
        );

        let missing_anchor = r#"{"bookUrl":"bk://bad"}"#;
        let err = book_marking_save(missing_anchor).unwrap_err();
        assert!(
            err.to_string().contains("anchorJson 不能为空"),
            "缺省 anchor 应报参数错误，实际: {err}"
        );

        let err = book_marking_save("not json").unwrap_err();
        assert!(
            err.to_string().contains("解析书签标记 JSON 失败"),
            "非法 JSON 应报解析错误，实际: {err}"
        );
    }

    /// setEnabled / delete 对不存在 id 为 no-op
    #[test]
    fn test_set_enabled_and_delete_noop() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_name = "ffi标记启停测试书";

        let saved =
            book_marking_save(&save_json("bk://marking_enabled", book_name, Some(1))).unwrap();
        assert!(saved.enabled, "默认 enabled 应为 true");

        book_marking_set_enabled(&saved.id, false).unwrap();
        let listed = book_marking_list_for_chapter("bk://marking_enabled", Some(1)).unwrap();
        assert_eq!(listed.len(), 1);
        assert!(!listed[0].enabled);
        assert!(
            listed[0].updated_at >= saved.updated_at,
            "启停应刷新 updatedAt"
        );

        // no-op：不报错
        book_marking_set_enabled("不存在的-id", true).unwrap();
        book_marking_delete("不存在的-id").unwrap();

        book_marking_delete(&saved.id).unwrap();
        assert!(book_marking_list_for_chapter("bk://marking_enabled", None)
            .unwrap()
            .is_empty());
    }

    /// 章节过滤：Some 含该章 + chapterIndex IS NULL；None 取全书；排序与跨源
    #[test]
    fn test_list_for_chapter_and_cross_source() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_name = "ffi标记章节测试书";
        let book_url = "bk://marking_chapter";

        let c1 = book_marking_save(&save_json(book_url, book_name, Some(1))).unwrap();
        let c2 = book_marking_save(&save_json(book_url, book_name, Some(2))).unwrap();
        let global = book_marking_save(&save_json(book_url, book_name, None)).unwrap();
        // 另一源，同名+作者（跨源）
        let other_source =
            book_marking_save(&save_json("bk://marking_chapter_other", book_name, Some(1)))
                .unwrap();

        let chapter1 = book_marking_list_for_chapter(book_url, Some(1)).unwrap();
        let ids: Vec<_> = chapter1.iter().map(|m| m.id.as_str()).collect();
        assert!(ids.contains(&c1.id.as_str()));
        assert!(
            ids.contains(&global.id.as_str()),
            "Some 查询应含 chapterIndex IS NULL"
        );
        assert!(!ids.contains(&c2.id.as_str()));

        let all = book_marking_list_for_chapter(book_url, None).unwrap();
        assert_eq!(all.len(), 3, "None 取当前源全部章节");

        let cross = book_marking_list_by_book(book_name, "标记作者").unwrap();
        assert_eq!(cross.len(), 4, "按书名+作者应覆盖全部源");
        // chapterIndex 升序：NULL 行在前（SQLite 默认），同章按 createdAt
        assert!(cross[0].chapter_index.is_none());

        for m in [c1, c2, global, other_source] {
            book_marking_delete(&m.id).unwrap();
        }
        assert!(book_marking_list_by_book(book_name, "标记作者")
            .unwrap()
            .is_empty());
    }
}
