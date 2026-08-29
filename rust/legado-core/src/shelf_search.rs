//! 书架模糊搜索服务 — Server REST 与 MCP 工具共享（P2-2 搜索实现统一）
//!
//! 历史上 `/api/search`（REST）与 MCP 工具 `search_books` 各自内联实现
//! 「按书名/作者不区分大小写包含匹配」，匹配语义重复且结果组装各自漂移；
//! 本模块把匹配语义收敛为单一实现，两个调用点只保留各自的响应组装。
//!
//! 匹配语义（与既有两处内联实现逐字等价）：
//! - 关键词与书名/作者均转小写后做 `contains` 判断，命中其一即入选；
//! - 保持入参切片原有顺序（即数据库 find_all 的返回顺序）；
//! - 空关键词匹配全部书籍（`contains("")` 恒真，与原实现一致）。
//!
//! 定位说明：多源**网络**搜索由 FFI 侧基于本 crate 的
//! `search_engine::MultiSourceSearcher` 实现；Server 侧当前不存在网络搜索
//! 入口（/api/search/multi 已于 P0-3 下线）。本服务统一的是「书架本地搜索」，
//! 放置于公共 crate 以便 Server 与 FFI 未来任何调用点共享同一实现。

use crate::models::Book;

/// 在书架书籍列表中按名称/作者模糊匹配关键词
///
/// 返回命中书籍的引用，顺序与 `books` 一致。
pub fn match_shelf_books<'a>(books: &'a [Book], keyword: &str) -> Vec<&'a Book> {
    let keyword_lower = keyword.to_lowercase();
    books
        .iter()
        .filter(|book| {
            book.name.to_lowercase().contains(&keyword_lower)
                || book.author.to_lowercase().contains(&keyword_lower)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_book(name: &str, author: &str) -> Book {
        serde_json::from_value(serde_json::json!({
            "bookUrl": format!("https://example.com/{}", name),
            "name": name,
            "author": author,
        }))
        .expect("测试书籍 JSON 应可反序列化")
    }

    #[test]
    fn test_match_by_name_case_insensitive() {
        let books = vec![make_book("斗破苍穹", "天蚕土豆")];
        let hits = match_shelf_books(&books, "斗破");
        assert_eq!(hits.len(), 1);
        // 大写关键词同样命中（不区分大小写）
        assert_eq!(
            match_shelf_books(&books, "斗破".to_uppercase().as_str()).len(),
            1
        );
    }

    #[test]
    fn test_match_by_author() {
        let books = vec![make_book("某书", "TianCan")];
        // 作者小写包含命中
        assert_eq!(match_shelf_books(&books, "tiancan").len(), 1);
        // 大写形式同样命中
        assert_eq!(match_shelf_books(&books, "TIANCAN").len(), 1);
    }

    #[test]
    fn test_no_hit_returns_empty() {
        let books = vec![make_book("斗破苍穹", "天蚕土豆")];
        assert!(match_shelf_books(&books, "凡人修仙").is_empty());
    }

    #[test]
    fn test_empty_keyword_matches_all() {
        // contains("") 恒真：空关键词匹配全部（与原内联实现语义一致）
        let books = vec![make_book("甲", "乙"), make_book("丙", "丁")];
        assert_eq!(match_shelf_books(&books, "").len(), 2);
    }

    #[test]
    fn test_order_preserved_and_both_fields_considered() {
        // 第一本按书名命中、第二本按作者命中、第三本不命中 → 顺序保持
        let books = vec![
            make_book("斗破苍穹", "某人"),
            make_book("其他书", "天蚕土豆"),
            make_book("无关书", "路人"),
        ];
        let hits = match_shelf_books(&books, "斗");
        assert_eq!(hits.len(), 1);
        let hits_author = match_shelf_books(&books, "土豆");
        assert_eq!(hits_author.len(), 1);
        assert_eq!(hits_author[0].name, "其他书");
        let hits_none = match_shelf_books(&books, "不存在的关键词");
        assert!(hits_none.is_empty());
    }
}
