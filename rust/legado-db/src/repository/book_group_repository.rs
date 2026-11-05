//! BookGroup Repository - book_groups 表 CRUD

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

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
                 enableRefresh, show, bookSort, onlyUpdateRead)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    group.group_id,
                    group.group_name,
                    group.cover,
                    group.order,
                    group.enable_refresh as i32,
                    group.show as i32,
                    group.book_sort,
                    group.only_update_read as i32,
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
                 enableRefresh, show, bookSort, onlyUpdateRead)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    group.group_id,
                    group.group_name,
                    group.cover,
                    group.order,
                    group.enable_refresh as i32,
                    group.show as i32,
                    group.book_sort,
                    group.only_update_read as i32,
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
                        show, bookSort, onlyUpdateRead
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
                        show, bookSort, onlyUpdateRead
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
                 enableRefresh=?4, show=?5, bookSort=?6, onlyUpdateRead=?7
                 WHERE groupId=?8",
                params![
                    group.group_name,
                    group.cover,
                    group.order,
                    group.enable_refresh as i32,
                    group.show as i32,
                    group.book_sort,
                    group.only_update_read as i32,
                    group.group_id,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新分组失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除分组
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM book_groups WHERE groupId = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除分组失败: {e}")))?;
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
    Ok(BookGroup {
        group_id: row.get(0)?,
        group_name: row.get(1)?,
        cover: row.get(2)?,
        order: row.get(3)?,
        enable_refresh: enable_refresh != 0,
        show: show != 0,
        book_sort: row.get(6)?,
        only_update_read: only_update_read != 0,
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

        // 同 id 重复恢复：整行替换不重复
        let mut again = group.clone();
        again.group_name = "改后".to_string();
        repo.upsert(&again).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.find_by_id(42).unwrap().unwrap().group_name, "改后");
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
}
