//! BookGroup Repository - book_groups 表 CRUD

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 新分组位掩码最大组合值（1<<30 及以下所有位全开）
const MAX_GROUP_MASK: i64 = (1 << 31) - 1;

/// 书籍分组
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookGroup {
    pub group_id: i64,
    pub group_name: String,
    pub cover: Option<String>,
    pub order: i32,
    pub enable_refresh: bool,
    pub show: bool,
    pub book_sort: i32,
    pub only_update_read: bool,
    /// 私密分组标记（批9a，对齐参考版 `BookGroup.isPrivate`，`BookGroup.kt:27`）
    pub is_private: bool,
}

/// 书籍分组数据访问层
pub struct BookGroupRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookGroupRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 添加分组，返回新分组 ID
    pub fn insert(&self, group: &BookGroup) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO book_groups (groupId, groupName, cover, \"order\",
                 enableRefresh, show, bookSort, onlyUpdateRead, isPrivate)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    group.group_id,
                    group.group_name,
                    group.cover,
                    group.order,
                    group.enable_refresh as i32,
                    group.show as i32,
                    group.book_sort,
                    group.only_update_read as i32,
                    group.is_private as i32,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入分组失败: {e}")))?;
        Ok(group.group_id)
    }

    /// 全列 upsert 分组（INSERT OR REPLACE，主键 groupId 冲突时整行替换）
    ///
    /// 供备份恢复使用（对齐原版 `BookGroupDao.insert` 的 REPLACE 语义）；
    /// 与 [`insert`] 的区别：主键已存在时替换而非报错。
    pub fn upsert(&self, group: &BookGroup) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO book_groups (groupId, groupName, cover, \"order\",
                 enableRefresh, show, bookSort, onlyUpdateRead, isPrivate)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    group.group_id,
                    group.group_name,
                    group.cover,
                    group.order,
                    group.enable_refresh as i32,
                    group.show as i32,
                    group.book_sort,
                    group.only_update_read as i32,
                    group.is_private as i32,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("恢复分组失败: {e}")))?;
        Ok(())
    }

    /// 获取所有分组（按 order 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<BookGroup>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT groupId, groupName, cover, \"order\", enableRefresh,
                        show, bookSort, onlyUpdateRead, isPrivate
                 FROM book_groups ORDER BY \"order\" ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_book_group)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 查询分组
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<BookGroup>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT groupId, groupName, cover, \"order\", enableRefresh,
                        show, bookSort, onlyUpdateRead, isPrivate
                 FROM book_groups WHERE groupId = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let group = stmt
            .query_row(params![id], row_to_book_group)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(group)
    }

    /// 更新分组
    pub fn update(&self, group: &BookGroup) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE book_groups SET groupName=?1, cover=?2, \"order\"=?3,
                 enableRefresh=?4, show=?5, bookSort=?6, onlyUpdateRead=?7, isPrivate=?8
                 WHERE groupId=?9",
                params![
                    group.group_name,
                    group.cover,
                    group.order,
                    group.enable_refresh as i32,
                    group.show as i32,
                    group.book_sort,
                    group.only_update_read as i32,
                    group.is_private as i32,
                    group.group_id,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新分组失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除分组（同事务清理 `books.group`）
    ///
    /// 对齐参考 `BookGroupMutationRepository.kt:85-93`：先清书的分组位再删组。
    /// - 2^n 新组：只清位掩码值（`0 < group <= 1<<31-1`）的对应位，避免
    ///   误清旧时间戳高位；
    /// - 非 2^n/高位旧组：exact 命中清 0；
    /// - `id <= 0` 特殊组：不动书籍。
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let tx = self
            .conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("删除分组事务失败: {e}")))?;
        if id > 0 {
            let is_bit = id <= MAX_GROUP_MASK && id.count_ones() == 1;
            if is_bit {
                tx.execute(
                    "UPDATE books SET \"group\" = \"group\" - ?1
                     WHERE \"group\" > 0 AND \"group\" <= ?2 AND (\"group\" & ?1) > 0",
                    params![id, MAX_GROUP_MASK],
                )
                .map_err(|e| LegadoError::Database(format!("清理分组成员失败: {e}")))?;
            } else {
                tx.execute(
                    "UPDATE books SET \"group\" = 0 WHERE \"group\" = ?1",
                    params![id],
                )
                .map_err(|e| LegadoError::Database(format!("清理旧分组成员失败: {e}")))?;
            }
        }
        let affected = tx
            .execute("DELETE FROM book_groups WHERE groupId = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除分组失败: {e}")))?;
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("删除分组提交失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 设置分组显示状态
    pub fn set_show(&self, id: i64, show: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE book_groups SET show = ?1 WHERE groupId = ?2",
                params![show as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("设置显示状态失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 设置分组私密标记（批9a，契约 §2.53 `setBookGroupPrivate`）
    ///
    /// 单列 UPDATE，返回是否命中行。组内书籍的私密判定由消费方与
    /// `books.isPrivate` 取并集，不在本方法内级联改写书籍。
    pub fn set_private(&self, group_id: i64, is_private: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE book_groups SET isPrivate = ?1 WHERE groupId = ?2",
                params![is_private as i32, group_id],
            )
            .map_err(|e| LegadoError::Database(format!("设置分组私密标记失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 全部私密分组 ID（批9a，契约 §2.53 `getPrivateGroupIds`）
    ///
    /// 按 `groupId` 升序稳定输出。
    pub fn private_group_ids(&self) -> LegadoResult<Vec<i64>> {
        let mut stmt = self
            .conn
            .prepare("SELECT groupId FROM book_groups WHERE isPrivate = 1 ORDER BY groupId ASC")
            .map_err(|e| LegadoError::Database(format!("准备私密分组查询失败: {e}")))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, i64>(0))
            .map_err(|e| LegadoError::Database(format!("查询私密分组失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取分组总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM book_groups", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }

    /// 返回最小未占用的 2 的幂分组 ID（1, 2, 4, …, 上限 1<<30）
    ///
    /// 对齐原版 `BookGroupDao.getUnusedId()`：`books.group` 是位掩码，新
    /// 分组必须使用 2 的幂才能表达「一本书属于多个分组」。只跳过已存在的
    /// 合法 2^n ID；存量时间戳/任意 ID 不参与碰撞判断（Dart 侧按 exact
    /// 语义兼容旧组）。
    pub fn get_unused_id(&self) -> LegadoResult<i64> {
        const MAX_GROUP_BIT: i64 = 1 << 30;
        let mut stmt = self
            .conn
            .prepare("SELECT groupId FROM book_groups")
            .map_err(|e| LegadoError::Database(format!("准备分组 ID 查询失败: {e}")))?;
        let ids: Vec<i64> = stmt
            .query_map([], |row| row.get::<_, i64>(0))
            .map_err(|e| LegadoError::Database(format!("查询分组 ID 失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();

        let mut id = 1_i64;
        while id <= MAX_GROUP_BIT && ids.contains(&id) {
            id <<= 1;
        }
        if id > MAX_GROUP_BIT {
            return Err(LegadoError::Database(
                "分组 ID 已用尽（上限 2^30）".to_string(),
            ));
        }
        Ok(id)
    }
}

fn row_to_book_group(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookGroup> {
    let enable_refresh: i32 = row.get(4)?;
    let show: i32 = row.get(5)?;
    let only_update_read: i32 = row.get(7)?;
    let is_private: i32 = row.get(8)?;
    Ok(BookGroup {
        group_id: row.get(0)?,
        group_name: row.get(1)?,
        cover: row.get(2)?,
        order: row.get(3)?,
        enable_refresh: enable_refresh != 0,
        show: show != 0,
        book_sort: row.get(6)?,
        only_update_read: only_update_read != 0,
        is_private: is_private != 0,
    })
}

use rusqlite::OptionalExtension;

#[cfg(test)]
mod tests {
    use super::*;

    fn make_group(id: i64, name: &str, order: i32) -> BookGroup {
        BookGroup {
            group_id: id,
            group_name: name.to_string(),
            cover: None,
            order,
            enable_refresh: true,
            show: true,
            book_sort: -1,
            only_update_read: false,
            is_private: false,
        }
    }

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1, "科幻", 0)).unwrap();
        repo.insert(&make_group(2, "玄幻", 1)).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].group_name, "科幻");
        assert_eq!(all[1].group_name, "玄幻");
    }

    #[test]
    fn test_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(10, "悬疑", 0)).unwrap();

        let found = repo.find_by_id(10).unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().group_name, "悬疑");

        assert!(repo.find_by_id(999).unwrap().is_none());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1, "原名", 0)).unwrap();

        let mut group = make_group(1, "新名", 5);
        group.cover = Some("cover.jpg".to_string());
        assert!(repo.update(&group).unwrap());

        let updated = repo.find_by_id(1).unwrap().unwrap();
        assert_eq!(updated.group_name, "新名");
        assert_eq!(updated.order, 5);
        assert_eq!(updated.cover, Some("cover.jpg".to_string()));
    }

    #[test]
    fn test_update_nonexistent() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        let group = make_group(999, "不存在", 0);
        assert!(!repo.update(&group).unwrap());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1, "分组1", 0)).unwrap();
        repo.insert(&make_group(2, "分组2", 1)).unwrap();

        assert!(repo.delete(1).unwrap());
        assert!(!repo.delete(1).unwrap());
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_set_show() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1, "分组", 0)).unwrap();

        assert!(repo.set_show(1, false).unwrap());
        let g = repo.find_by_id(1).unwrap().unwrap();
        assert!(!g.show);

        assert!(repo.set_show(1, true).unwrap());
        let g = repo.find_by_id(1).unwrap().unwrap();
        assert!(g.show);

        assert!(!repo.set_show(999, true).unwrap());
    }

    #[test]
    fn test_count() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        assert_eq!(repo.count().unwrap(), 0);
        repo.insert(&make_group(1, "A", 0)).unwrap();
        repo.insert(&make_group(2, "B", 1)).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
        repo.delete(1).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
    }

    /// 恢复路径全列 upsert：主键冲突整行替换，全 8 列逐列读回
    #[test]
    fn test_upsert_replaces_all_columns() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());

        let group = BookGroup {
            group_id: 42,
            group_name: "恢复分组".to_string(),
            cover: Some("cover.png".to_string()),
            order: 7,
            enable_refresh: false,
            show: false,
            book_sort: 3,
            only_update_read: true,
            is_private: true,
        };
        repo.upsert(&group).unwrap();

        let found = repo.find_by_id(42).unwrap().unwrap();
        assert_eq!(found.group_name, "恢复分组");
        assert_eq!(found.cover.as_deref(), Some("cover.png"));
        assert_eq!(found.order, 7);
        assert!(!found.enable_refresh);
        assert!(!found.show);
        assert_eq!(found.book_sort, 3);
        assert!(found.only_update_read);
        assert!(found.is_private);

        // 同 id 重复恢复：整行替换不重复
        let mut again = group.clone();
        again.group_name = "改后".to_string();
        repo.upsert(&again).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.find_by_id(42).unwrap().unwrap().group_name, "改后");
    }

    /// [批9a] 分组私密标记：命中返回 true / 未命中 false；
    /// 私密分组 ID 升序，取消后从列表移除
    #[test]
    fn test_set_private_and_private_group_ids() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(4, "组4", 0)).unwrap();
        repo.insert(&make_group(1, "组1", 1)).unwrap();
        repo.insert(&make_group(2, "组2", 2)).unwrap();

        assert!(repo.set_private(4, true).unwrap());
        assert!(repo.set_private(1, true).unwrap());
        assert!(!repo.set_private(999, true).unwrap());
        assert_eq!(repo.private_group_ids().unwrap(), vec![1, 4]);

        assert!(repo.set_private(1, false).unwrap());
        assert_eq!(repo.private_group_ids().unwrap(), vec![4]);
        assert!(!repo.find_by_id(1).unwrap().unwrap().is_private);
        assert!(repo.find_by_id(4).unwrap().unwrap().is_private);
    }

    #[test]
    fn test_get_unused_id_starts_at_one_and_skips_powers_of_two() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        assert_eq!(repo.get_unused_id().unwrap(), 1);

        repo.insert(&make_group(1, "A", 0)).unwrap();
        assert_eq!(repo.get_unused_id().unwrap(), 2);
        repo.insert(&make_group(2, "B", 1)).unwrap();
        repo.insert(&make_group(4, "C", 2)).unwrap();
        assert_eq!(repo.get_unused_id().unwrap(), 8);

        // 释放 2 后应优先复用最小空洞
        repo.delete(2).unwrap();
        assert_eq!(repo.get_unused_id().unwrap(), 2);
    }

    #[test]
    fn test_get_unused_id_ignores_legacy_timestamp_ids() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1_793_904_884_364, "旧组A", 0))
            .unwrap();
        repo.insert(&make_group(1_793_904_908_173, "旧组B", 1))
            .unwrap();

        // 旧时间戳 ID 非 2 的幂，不应占用位掩码 ID
        assert_eq!(repo.get_unused_id().unwrap(), 1);
    }

    #[test]
    fn test_get_unused_id_rejects_when_all_bits_used() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        for i in 0..=30 {
            repo.insert(&make_group(1_i64 << i, &format!("组{i}"), i))
                .unwrap();
        }
        assert!(repo.get_unused_id().is_err());
    }

    fn insert_book(db: &crate::Database, url: &str, group: i64) {
        db.connection()
            .execute(
                "INSERT INTO books (bookUrl, name, \"group\") VALUES (?1, ?2, ?3)",
                params![url, url, group],
            )
            .unwrap();
    }

    fn book_group(db: &crate::Database, url: &str) -> i64 {
        db.connection()
            .query_row(
                "SELECT \"group\" FROM books WHERE bookUrl = ?1",
                params![url],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn test_delete_power_of_two_clears_bit_and_id_not_inherited() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1, "组1", 0)).unwrap();
        repo.insert(&make_group(4, "组4", 1)).unwrap();
        insert_book(&db, "book://bit", 1 | 4);

        assert!(repo.delete(1).unwrap());
        assert_eq!(book_group(&db, "book://bit"), 4, "删除组1只清对应位");

        // 释放的位可复用，但书已不再带该位，不会继承新组
        assert_eq!(repo.get_unused_id().unwrap(), 1);
        assert_eq!(book_group(&db, "book://bit") & 1, 0);
    }

    #[test]
    fn test_delete_legacy_group_exact_only() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        let legacy = 12_345_i64; // 非 2^n
        repo.insert(&make_group(legacy, "旧组", 0)).unwrap();
        insert_book(&db, "book://exact", legacy);
        insert_book(&db, "book://other", legacy | 4);

        assert!(repo.delete(legacy).unwrap());
        assert_eq!(book_group(&db, "book://exact"), 0);
        assert_eq!(book_group(&db, "book://other"), legacy | 4);
    }

    #[test]
    fn test_delete_new_bit_does_not_touch_legacy_high_value() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(4, "组4", 0)).unwrap();
        let legacy = 1_793_904_884_364_i64 | 4; // 高位旧时间戳且含 bit2
        insert_book(&db, "book://legacy", legacy);

        assert!(repo.delete(4).unwrap());
        assert_eq!(book_group(&db, "book://legacy"), legacy);
    }

    #[test]
    fn test_delete_special_group_does_not_touch_books() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        insert_book(&db, "book://special", 3);

        assert!(!repo.delete(-1).unwrap());
        assert_eq!(book_group(&db, "book://special"), 3);
    }

    #[test]
    fn test_delete_rolls_back_when_group_delete_fails() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        repo.insert(&make_group(1, "组1", 0)).unwrap();
        insert_book(&db, "book://rollback", 3);
        db.connection()
            .execute_batch(
                "CREATE TRIGGER prevent_group_delete BEFORE DELETE ON book_groups
                 BEGIN SELECT RAISE(ABORT, 'blocked'); END;",
            )
            .unwrap();

        assert!(repo.delete(1).is_err());
        assert_eq!(book_group(&db, "book://rollback"), 3, "删除失败应回滚清位");
        assert!(repo.find_by_id(1).unwrap().is_some(), "分组不应被删除");
    }
}
