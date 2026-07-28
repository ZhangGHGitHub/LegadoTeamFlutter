//! 书籍分组管理 API
//!
//! 提供书籍分组的增删改查操作，通过 BookGroupRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::{BookGroup, BookGroupRepository};

use crate::db_state::with_database;

/// 书籍分组 DTO
#[derive(Debug, Clone, Serialize)]
pub struct BookGroupDto {
    pub group_id: i64,
    pub group_name: String,
    pub cover: Option<String>,
    pub order: i32,
    pub show: bool,
}

/// 获取所有书籍分组（按 order 升序）
pub fn get_book_groups() -> LegadoResult<Vec<BookGroupDto>> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        let groups = repo.find_all()?;
        Ok(groups
            .into_iter()
            .map(|g| BookGroupDto {
                group_id: g.group_id,
                group_name: g.group_name,
                cover: g.cover,
                order: g.order,
                show: g.show,
            })
            .collect())
    })
}

/// 添加书籍分组，返回新分组 ID
pub fn add_book_group(group_name: &str, cover: &str, order: i32) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        // 使用当前时间戳作为 group_id
        let id = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let group = BookGroup {
            group_id: id,
            group_name: group_name.to_string(),
            cover: if cover.is_empty() {
                None
            } else {
                Some(cover.to_string())
            },
            order,
            enable_refresh: true,
            show: true,
            book_sort: -1,
            only_update_read: false,
        };
        repo.insert(&group)?;
        Ok(id)
    })
}

/// 更新书籍分组
pub fn update_book_group(id: i64, group_name: &str, cover: &str, order: i32) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        let existing = repo.find_by_id(id)?;
        match existing {
            Some(mut g) => {
                g.group_name = group_name.to_string();
                g.cover = if cover.is_empty() {
                    None
                } else {
                    Some(cover.to_string())
                };
                g.order = order;
                repo.update(&g)
            }
            None => Ok(false),
        }
    })
}

/// 删除书籍分组
pub fn delete_book_group(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        repo.delete(id)
    })
}

/// 设置分组显示状态
pub fn set_book_group_show(id: i64, show: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        repo.set_show(id, show)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_group_crud() {
        crate::db_state::ensure_test_db();

        // 添加分组
        let id = add_book_group("科幻", "", 0).unwrap();
        assert!(id > 0);

        // 获取列表
        let groups = get_book_groups().unwrap();
        assert!(groups.iter().any(|g| g.group_name == "科幻"));

        // 更新分组
        assert!(update_book_group(id, "玄幻", "cover.jpg", 1).unwrap());
        let groups = get_book_groups().unwrap();
        let g = groups.iter().find(|g| g.group_id == id).unwrap();
        assert_eq!(g.group_name, "玄幻");

        // 设置隐藏
        assert!(set_book_group_show(id, false).unwrap());

        // 删除分组
        assert!(delete_book_group(id).unwrap());
        let groups = get_book_groups().unwrap();
        assert!(!groups.iter().any(|g| g.group_id == id));
    }
}
