//! RSS 已读记录 API
//!
//! 提供 RSS 文章已读标记的增删查操作，通过 RssReadRecordRepository 访问数据库。

use legado_core::LegadoResult;
use legado_db::{RssReadRecordMeta, RssReadRecordRepository, RssReadRecordRow};

use crate::db_state::with_database;

/// 标记文章为已读（兼容入口，扩展字段取 DB 缺省值）
pub fn mark_read(origin: &str, title: &str, link: Option<&str>) -> LegadoResult<()> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read(origin, title, link)
    })
}

/// 标记文章为已读并写入扩展字段（批20，对齐原版 `RssArticle.toRecord()`）
///
/// `article_type` 缺省 0；`sort` 缺省空串；`image` / `pub_date` 缺省 NULL；
/// `dur_pos` 缺省 0。旧调用（不传扩展字段）行为与 [`mark_read`] 一致。
#[allow(clippy::too_many_arguments)]
pub fn mark_read_full(
    origin: &str,
    title: &str,
    link: Option<&str>,
    article_type: Option<i32>,
    sort: Option<&str>,
    image: Option<&str>,
    pub_date: Option<&str>,
    dur_pos: Option<i32>,
) -> LegadoResult<()> {
    let meta = RssReadRecordMeta {
        article_type,
        sort: sort.map(str::to_string),
        image: image.map(str::to_string),
        pub_date: pub_date.map(str::to_string),
        dur_pos,
    };
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read_with(origin, title, link, &meta)
    })
}

/// 判断文章是否已读（按 link 匹配）
pub fn is_read(link: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.is_read(link)
    })
}

/// 判断文章是否已读（按 origin + title 匹配）
pub fn is_read_by_title(origin: &str, title: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.is_read_by_title(origin, title)
    })
}

/// 清空所有已读记录
pub fn clear_all() -> LegadoResult<()> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.clear_all()
    })
}

/// 清空指定 RSS 源的已读记录（仅 `None` 清空全部）
///
/// 对齐原版 `RssReadRecordDao.deleteAllRecord(origin)`：`ReadRecordDialog`
/// 的「清空」按当前源过滤，全局入口传 `null` 清空全部。
///
/// 批29b 审查 P1-1：`Some` 一律按 trim 后的 origin **精确过滤**——空串
/// （`Some("")` / `Some("  ")`）删除 0 行，绝不再退化为 `clear_all()`。
/// 原版 `deleteAllRecord("")` 的 WHERE 同样只匹配 origin=''（正常记录不会
/// 命中，等价不删）；此前把空串当 `None` 会把「按源清空」误升级为
/// 「清空全部」，一处空 origin 即丢全部源的阅读记录。
pub fn clear_by_origin(origin: Option<&str>) -> LegadoResult<()> {
    match origin {
        Some(origin) => with_database(|db| {
            let repo = RssReadRecordRepository::new(db.connection());
            repo.clear_by_origin(origin).map(|_| ())
        }),
        None => clear_all(),
    }
}

/// 获取已读记录总数
pub fn count() -> LegadoResult<i64> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.count()
    })
}

/// 获取已读记录列表（按 readTime 降序）
pub fn list_records(limit: Option<i32>) -> LegadoResult<Vec<RssReadRecordRow>> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.list_records(limit)
    })
}

/// 按 origin 获取已读记录列表（对齐原版 RssReadRecordDao.getRecordsByOrigin）
pub fn list_records_by_origin(
    origin: &str,
    limit: Option<i32>,
) -> LegadoResult<Vec<RssReadRecordRow>> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.list_records_by_origin(origin, limit)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rss_read_record_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 标记已读
        mark_read(
            "https://rss.example.com",
            "Test Article",
            Some("https://link.com/1"),
        )
        .unwrap();

        // 判断已读
        assert!(is_read("https://link.com/1").unwrap());
        assert!(!is_read("https://link.com/999").unwrap());

        // 按标题判断
        assert!(is_read_by_title("https://rss.example.com", "Test Article").unwrap());
        assert!(!is_read_by_title("https://rss.example.com", "Other").unwrap());

        // 计数
        let c = count().unwrap();
        assert!(c >= 1);

        // 列表
        let records = list_records(Some(10)).unwrap();
        assert!(records.iter().any(|r| r.title == "Test Article"));

        // 按 origin 列表
        mark_read("https://other.com", "Other", Some("https://link.com/2")).unwrap();
        let by_origin = list_records_by_origin("https://rss.example.com", None).unwrap();
        assert!(by_origin
            .iter()
            .all(|r| r.origin == "https://rss.example.com"));
        assert_eq!(by_origin.len(), 1);

        // 清空
        clear_all().unwrap();
        assert_eq!(count().unwrap(), 0);
    }

    /// 批20：扩展字段经 FFI 层写读回环
    #[test]
    fn test_rss_mark_read_full_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_all().unwrap();

        mark_read_full(
            "https://rss.example.com",
            "图片文章",
            Some("https://link.com/img"),
            Some(1),
            Some("图片分类"),
            Some("https://img.test/1.jpg"),
            Some("2026-10-27"),
            Some(7),
        )
        .unwrap();
        // 旧入口不传扩展字段：保持缺省口径
        mark_read(
            "https://rss.example.com",
            "网页文章",
            Some("https://link.com/web"),
        )
        .unwrap();

        let records = list_records(Some(10)).unwrap();
        let img = records
            .iter()
            .find(|r| r.link.as_deref() == Some("https://link.com/img"))
            .expect("图片记录应存在");
        assert_eq!(img.r#type, 1);
        assert_eq!(img.sort, "图片分类");
        assert_eq!(img.image.as_deref(), Some("https://img.test/1.jpg"));
        assert_eq!(img.pub_date.as_deref(), Some("2026-10-27"));
        assert_eq!(img.dur_pos, 7);

        let web = records
            .iter()
            .find(|r| r.link.as_deref() == Some("https://link.com/web"))
            .expect("网页记录应存在");
        assert_eq!(web.r#type, 0);
        assert_eq!(web.sort, "");
        assert!(web.image.is_none());
        assert!(web.pub_date.is_none());
        assert_eq!(web.dur_pos, 0);

        // 按源入口与全量入口口径一致
        let by_origin = list_records_by_origin("https://rss.example.com", None).unwrap();
        let img_by_origin = by_origin
            .iter()
            .find(|r| r.link.as_deref() == Some("https://link.com/img"))
            .expect("按源查询应返回图片记录");
        assert_eq!(img_by_origin.r#type, 1);
        assert_eq!(img_by_origin.dur_pos, 7);

        clear_all().unwrap();
    }

    /// 批29b 审查 P1-1/P2-2：`clear_by_origin` 三分支口径
    ///
    /// - `None` → 清空全部；
    /// - `Some(origin)` → 只删 trim 后精确匹配的源；
    /// - `Some("")` / `Some("  ")` → 删除 0 行，**不得**退化为清空全部
    ///   （改前空串落到 `clear_all()`，两个源 mark 后其它源全丢 → 本用例红）。
    #[test]
    fn test_clear_by_origin_none_some_and_blank() {
        let _db_guard = crate::db_state::ensure_test_db();

        let seed = || {
            clear_all().unwrap();
            mark_read("https://a.rss.com", "A1", Some("a1")).unwrap();
            mark_read("https://b.rss.com", "B1", Some("b1")).unwrap();
            assert_eq!(count().unwrap(), 2);
        };

        // 空白串：删除 0 行，两个源都保留（红线：不得清空全部）
        seed();
        clear_by_origin(Some("")).unwrap();
        assert_eq!(count().unwrap(), 2, "空 origin 必须删除 0 行");
        assert!(is_read("a1").unwrap());
        assert!(is_read("b1").unwrap());
        clear_by_origin(Some("   ")).unwrap();
        assert_eq!(count().unwrap(), 2, "纯空白 origin 必须删除 0 行");
        assert!(is_read("a1").unwrap());
        assert!(is_read("b1").unwrap());

        // Some(origin)：按 trim 后精确过滤，只删目标源
        clear_by_origin(Some(" https://a.rss.com ")).unwrap();
        assert_eq!(count().unwrap(), 1, "按源清空只影响目标源");
        assert!(!is_read("a1").unwrap());
        assert!(is_read("b1").unwrap());

        // 不存在 / 空 origin 仍不误删
        clear_by_origin(Some("")).unwrap();
        clear_by_origin(Some("https://c.rss.com")).unwrap();
        assert_eq!(count().unwrap(), 1);
        assert!(is_read("b1").unwrap());

        // None：清空全部（旧调用不传参数行为不变）
        clear_by_origin(None).unwrap();
        assert_eq!(count().unwrap(), 0);
        assert!(!is_read("b1").unwrap());
    }
}
