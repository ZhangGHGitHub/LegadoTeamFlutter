//! 书签管理 API
//!
//! 提供书签的增删查搜索操作，通过 BookmarkRepository 访问数据库。

use legado_core::models::Bookmark;
use legado_core::LegadoResult;
use legado_db::BookmarkRepository;

use crate::db_state::with_database;

/// 获取书籍的所有书签（按 book_name 查询）
pub fn get_bookmarks(book_name: &str) -> LegadoResult<Vec<Bookmark>> {
    with_database(|db| {
        let repo = BookmarkRepository::new(db.connection());
        repo.get_by_book(book_name)
    })
}

/// 按书名+作者获取某本书的所有书签（契约 §2.7 getBookmarksByBook，
/// 台账 §5.14-2，Task #63 加法式新增）
///
/// 对齐原版 `bookmarkDao.getByBook(name, author)`，规避同名书混入；
/// 既有 `get_bookmarks`（仅按书名）签名保持不变。
pub fn get_bookmarks_by_book(book_name: &str, book_author: &str) -> LegadoResult<Vec<Bookmark>> {
    with_database(|db| {
        let repo = BookmarkRepository::new(db.connection());
        repo.get_by_book_and_author(book_name, book_author)
    })
}

/// 添加书签，返回新书签的 id
pub fn add_bookmark(
    book_name: &str,
    book_author: &str,
    chapter_index: i32,
    chapter_pos: i32,
    chapter_name: &str,
    book_text: &str,
    content: &str,
) -> LegadoResult<i64> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let bm = Bookmark {
        id: 0,
        time: now,
        book_name: book_name.to_string(),
        book_author: book_author.to_string(),
        chapter_index,
        chapter_pos,
        chapter_name: chapter_name.to_string(),
        book_text: book_text.to_string(),
        content: content.to_string(),
    };

    with_database(|db| {
        let repo = BookmarkRepository::new(db.connection());
        repo.insert(&bm)
    })
}

/// 删除书签
pub fn delete_bookmark(bookmark_id: i64) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookmarkRepository::new(db.connection());
        repo.delete(bookmark_id)
    })
}

/// 搜索书签（按关键词模糊匹配 bookText / content / chapterName）
pub fn search_bookmarks(keyword: &str) -> LegadoResult<Vec<Bookmark>> {
    with_database(|db| {
        let repo = BookmarkRepository::new(db.connection());
        repo.search(keyword)
    })
}

/// 获取所有书签
pub fn get_all_bookmarks() -> LegadoResult<Vec<Bookmark>> {
    with_database(|db| {
        let repo = BookmarkRepository::new(db.connection());
        repo.find_all()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 辅助：初始化内存数据库并设置全局状态（返回串行锁守卫，测试必须绑定到变量）
    fn setup_test_db() -> std::sync::MutexGuard<'static, ()> {
        crate::db_state::ensure_test_db()
    }

    #[test]
    fn test_add_and_get_bookmarks() {
        let _db_guard = setup_test_db();
        let id = add_bookmark(
            "bm_测试书籍_1",
            "作者A",
            0,
            100,
            "第一章",
            "书签文本",
            "备注",
        )
        .unwrap();
        assert!(id > 0);

        let bookmarks = get_bookmarks("bm_测试书籍_1").unwrap();
        assert_eq!(bookmarks.len(), 1);
        assert_eq!(bookmarks[0].book_name, "bm_测试书籍_1");
        assert_eq!(bookmarks[0].chapter_index, 0);
        assert_eq!(bookmarks[0].chapter_pos, 100);
    }

    #[test]
    fn test_add_multiple_bookmarks() {
        let _db_guard = setup_test_db();
        add_bookmark("bm_书A_2", "作者1", 0, 0, "ch0", "text1", "").unwrap();
        add_bookmark("bm_书A_2", "作者1", 1, 50, "ch1", "text2", "").unwrap();
        add_bookmark("bm_书B_2", "作者2", 0, 0, "ch0", "text3", "").unwrap();

        let a = get_bookmarks("bm_书A_2").unwrap();
        assert_eq!(a.len(), 2);
        let b = get_bookmarks("bm_书B_2").unwrap();
        assert_eq!(b.len(), 1);
    }

    #[test]
    fn test_delete_bookmark() {
        let _db_guard = setup_test_db();
        let id = add_bookmark("bm_书A_3", "作者", 0, 0, "ch0", "text", "").unwrap();
        assert_eq!(get_bookmarks("bm_书A_3").unwrap().len(), 1);

        delete_bookmark(id).unwrap();
        assert_eq!(get_bookmarks("bm_书A_3").unwrap().len(), 0);
    }

    #[test]
    fn test_search_bookmarks() {
        let _db_guard = setup_test_db();
        add_bookmark(
            "bm_书A_4",
            "作者",
            0,
            0,
            "第一章",
            "unique_hello_world_4",
            "",
        )
        .unwrap();
        add_bookmark("bm_书A_4", "作者", 1, 0, "第二章", "goodbye_4", "").unwrap();

        let results = search_bookmarks("unique_hello_world_4").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].book_text, "unique_hello_world_4");
    }

    #[test]
    fn test_search_bookmarks_by_content() {
        let _db_guard = setup_test_db();
        add_bookmark("bm_书A_5", "作者", 0, 0, "ch0", "text", "重要备注_5").unwrap();

        let results = search_bookmarks("备注_5").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].content, "重要备注_5");
    }

    #[test]
    fn test_get_all_bookmarks() {
        let _db_guard = setup_test_db();
        add_bookmark("bm_书A_6", "作者1", 0, 0, "ch0", "t1", "").unwrap();
        add_bookmark("bm_书B_6", "作者2", 0, 0, "ch0", "t2", "").unwrap();

        let all = get_all_bookmarks().unwrap();
        // 验证我们添加的书签存在于全量列表中
        assert!(all.iter().any(|b| b.book_name == "bm_书A_6"));
        assert!(all.iter().any(|b| b.book_name == "bm_书B_6"));
    }

    /// 台账 §5.14-2：get_bookmarks_by_book 按书名+作者精准查询，同名书不混入
    #[test]
    fn test_get_bookmarks_by_book() {
        let _db_guard = setup_test_db();
        // 同名书两本，作者不同
        add_bookmark("bm_同名书_7", "作者甲7", 0, 0, "ch0", "甲书签", "").unwrap();
        add_bookmark("bm_同名书_7", "作者乙7", 0, 0, "ch0", "乙书签", "").unwrap();

        // 仅按书名：两条都命中（既有 get_bookmarks 行为保留）
        assert_eq!(get_bookmarks("bm_同名书_7").unwrap().len(), 2);

        // 书名+作者：仅命中本书
        let a = get_bookmarks_by_book("bm_同名书_7", "作者甲7").unwrap();
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].book_text, "甲书签");
        assert_eq!(a[0].book_author, "作者甲7");

        // 作者不匹配 → 空列表
        assert!(get_bookmarks_by_book("bm_同名书_7", "不存在").unwrap().is_empty());
    }
}
