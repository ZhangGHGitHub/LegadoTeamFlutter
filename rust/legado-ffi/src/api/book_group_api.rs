//! 书籍分组管理 API
//!
//! 提供书籍分组的增删改查操作，通过 BookGroupRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::{BookGroup, BookGroupRepository};

use crate::db_state::with_database;

/// 书籍分组 DTO
///
/// 序列化契约：camelCase 字段名（groupId/groupName/…），
/// 与 Dart 侧 `BookGroup.fromJson` 的 `@JsonKey` 一一对应。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
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
    fn test_dto_serializes_camel_case() {
        // 与 Dart BookGroup.fromJson 的 @JsonKey(name: 'groupId'/'groupName') 契约一致
        let dto = BookGroupDto {
            group_id: 42,
            group_name: "科幻".to_string(),
            cover: None,
            order: 1,
            show: true,
        };
        let json = serde_json::to_string(&dto).unwrap();
        assert!(json.contains("\"groupId\":42"));
        assert!(json.contains("\"groupName\":\"科幻\""));
        assert!(!json.contains("group_id"));
    }

    #[test]
    fn test_book_group_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

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

    /// setShow 生效验证：设置后通过 get_book_groups 读回，
    /// 确认 show 状态确实持久化变更（对齐 Kotlin dao upShow 语义）
    #[test]
    fn test_set_show_readback() {
        let _db_guard = crate::db_state::ensure_test_db();

        let id = add_book_group("显示状态测试", "", 0).unwrap();
        assert!(id > 0);

        // 新建分组默认显示
        let g = get_book_groups()
            .unwrap()
            .into_iter()
            .find(|g| g.group_id == id)
            .expect("分组应存在");
        assert!(g.show);

        // 隐藏后读回应为 false
        assert!(set_book_group_show(id, false).unwrap());
        let g = get_book_groups()
            .unwrap()
            .into_iter()
            .find(|g| g.group_id == id)
            .expect("分组应存在");
        assert!(!g.show);

        // 恢复显示后读回应为 true
        assert!(set_book_group_show(id, true).unwrap());
        let g = get_book_groups()
            .unwrap()
            .into_iter()
            .find(|g| g.group_id == id)
            .expect("分组应存在");
        assert!(g.show);

        // 不存在的分组返回 false
        assert!(!set_book_group_show(id + 999_999, true).unwrap());

        // 清理
        assert!(delete_book_group(id).unwrap());
    }
}
