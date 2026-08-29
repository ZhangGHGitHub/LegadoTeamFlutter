//! 缓存管理 API
//!
//! 提供缓存大小查询、清理、章节缓存读取操作；
//! Task #136 R5 补齐写侧（[`save_chapter_content`]）。

use legado_core::cache_book::CachedChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::{CacheBookRepository, CacheRepository};

use crate::db_state::with_database;

/// 获取缓存总大小（字节）
pub fn get_cache_size() -> LegadoResult<i64> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let stats = repo.get_stats()?;
        Ok(stats.total_size_bytes)
    })
}

/// 清空所有章节缓存
pub fn clear_cache() -> LegadoResult<bool> {
    with_database(|db| {
        let conn = db.connection();
        // 清空 cached_chapters 表
        conn.execute("DELETE FROM cached_chapters", [])
            .map_err(|e| legado_core::LegadoError::Database(format!("清空缓存失败: {e}")))?;
        // 同时清空通用 KV 缓存
        let cache_repo = CacheRepository::new(conn);
        cache_repo.clear()?;
        Ok(true)
    })
}

/// 清除指定书籍的章节缓存（对齐原版 BookHelp.clearCache(book) 的 DB 侧语义）
pub fn clear_book_cache(book_url: &str) -> LegadoResult<i32> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let deleted = repo.delete_by_book(book_url)?;
        Ok(deleted as i32)
    })
}

/// 获取指定章节的缓存内容（无缓存返回空字符串）
pub fn get_chapter_cache(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let chapters = repo.get_by_book(book_url)?;
        let found = chapters
            .into_iter()
            .find(|c| c.chapter_index == chapter_index);
        Ok(found.map(|c| c.content).unwrap_or_default())
    })
}

/// 列出某本书已缓存章节的 chapter_url 集合（Task #22，目录页云图标缓存态）
///
/// 复用 [`CacheBookRepository::get_by_book`]（按 book_url 复合键查询，不串本），
/// 仅提取 chapter_url 供 Flutter 目录页据此为每章标记「已缓存/未缓存」渲染
/// 云图标；返回顺序按 chapter_index 升序（仓储已排序），空 chapter_url 过滤。
pub fn list_cached_chapter_urls(book_url: &str) -> LegadoResult<Vec<String>> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let chapters = repo.get_by_book(book_url)?;
        Ok(chapters
            .into_iter()
            .map(|c| c.chapter_url)
            .filter(|u| !u.trim().is_empty())
            .collect())
    })
}

/// 获取缓存书籍数量
pub fn get_cache_book_count() -> LegadoResult<i32> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let stats = repo.get_stats()?;
        Ok(stats.books_cached)
    })
}

/// 获取缓存章节数量
pub fn get_cache_chapter_count() -> LegadoResult<i32> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let stats = repo.get_stats()?;
        Ok(stats.total_chapters)
    })
}

/// 写入/覆盖单章缓存（Task #136 R5，API_CONTRACT §2.43.1）
///
/// 复用 [`CacheBookRepository::insert`]（INSERT OR REPLACE），供阅读器
/// 「编辑内容/反转」闭环回写章节缓存；正文按原文存储（不做净化，
/// 与正文抓取链路缓存写入一致，读取时再净化）。
///
/// `title` / `chapter_url` 为空串时从 DB 章节表回填（章节也不存在则报错）。
pub fn save_chapter_content(
    book_url: &str,
    chapter_index: i32,
    title: &str,
    content: &str,
    chapter_url: &str,
) -> LegadoResult<bool> {
    // 缺省字段回填：对齐 Kotlin cached_chapters 主键（book_url + chapter_url）
    let (chapter_title, chapter_url) = if title.is_empty() || chapter_url.is_empty() {
        let ch = with_database(|db| {
            let repo = BookChapterRepository::new(db.connection());
            repo.find_by_book_url_and_index(book_url, chapter_index)
        })?
        .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在: {book_url}")))?;
        (
            if title.is_empty() {
                ch.title
            } else {
                title.to_string()
            },
            if chapter_url.is_empty() {
                ch.url
            } else {
                chapter_url.to_string()
            },
        )
    } else {
        (title.to_string(), chapter_url.to_string())
    };

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let chapter = CachedChapter {
        id: 0,
        book_url: book_url.to_string(),
        chapter_index,
        chapter_title,
        chapter_url,
        content: content.to_string(),
        cached_at: now_ms,
        size_bytes: content.len() as i64,
    };

    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.insert(&chapter)?;
        Ok(true)
    })
}

/// 执行 SQLite VACUUM 压缩数据库，返回释放的字节数（Task #51，API_CONTRACT §2.16.6）
///
/// 通过 VACUUM 前后 `PRAGMA page_count * page_size` 对比计算释放量；
/// VACUUM 失败（数据库锁/文件损坏）或数据库未初始化时一律降级返回 0，
/// 不抛异常阻断业务（契约错误语义）。FFI 同步函数由 frb 调度在
/// 工作线程执行，不阻塞 Dart isolate。
pub fn shrink_database() -> i64 {
    shrink_database_inner().unwrap_or(0)
}

/// VACUUM 内部实现（错误由上层降级为 0）
fn shrink_database_inner() -> LegadoResult<i64> {
    with_database(|db| {
        let conn = db.connection();
        let before = db_logical_size_bytes(conn)?;
        conn.execute("VACUUM", [])
            .map_err(|e| LegadoError::Database(format!("VACUUM 失败: {e}")))?;
        let after = db_logical_size_bytes(conn)?;
        Ok(before.saturating_sub(after))
    })
}

/// 数据库逻辑大小（字节）：`page_count * page_size`
fn db_logical_size_bytes(conn: &rusqlite::Connection) -> LegadoResult<i64> {
    let page_count: i64 = conn
        .query_row("PRAGMA page_count", [], |row| row.get(0))
        .map_err(|e| LegadoError::Database(format!("查询 page_count 失败: {e}")))?;
    let page_size: i64 = conn
        .query_row("PRAGMA page_size", [], |row| row.get(0))
        .map_err(|e| LegadoError::Database(format!("查询 page_size 失败: {e}")))?;
    Ok(page_count.saturating_mul(page_size))
}

/// 清除指定时间之前的缓存，返回删除的行数
///
/// 语义对齐原版（Task #55 F5）：原版时段清理会删除对应章节的 .nr
/// 缓存标记文件（即复位「不删重复标题」章级标记）；本实现等价地在清理
/// cached_chapters 的同时，删除【被清理书籍】在 caches 表的
/// `sameTitleRemoved:{bookUrl}:*` 章级开关键；未被清理的书籍不受影响。
pub fn clear_cache_before(before_timestamp: i64) -> LegadoResult<i64> {
    with_database(|db| {
        use rusqlite::params;
        let conn = db.connection();
        // 先收集将被清理的书籍 book_url 集合（仅这些书的章级开关需复位）
        let book_urls: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT DISTINCT book_url FROM cached_chapters WHERE cached_at < ?1")
                .map_err(|e| {
                    legado_core::LegadoError::Database(format!("查询待清理书籍失败：{e}"))
                })?;
            let rows = stmt
                .query_map(params![before_timestamp], |row| row.get::<_, String>(0))
                .map_err(|e| {
                    legado_core::LegadoError::Database(format!("查询待清理书籍失败：{e}"))
                })?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| {
                legado_core::LegadoError::Database(format!("查询待清理书籍失败：{e}"))
            })?
        };

        let deleted = conn
            .execute(
                "DELETE FROM cached_chapters WHERE cached_at < ?1",
                params![before_timestamp],
            )
            .map_err(|e| legado_core::LegadoError::Database(format!("清空过期缓存失败：{e}")))?;

        // 复位被清理书籍的章级「删除重复标题」开关（caches 表键前缀匹配）；
        // book_url 可能含 %/_ 等 LIKE 通配符（如 URL 百分号编码），先转义
        // 再匹配，避免误删他书键。
        for book_url in book_urls {
            let pattern = format!("sameTitleRemoved:{}:%", like_escape(&book_url));
            conn.execute(
                "DELETE FROM caches WHERE key LIKE ?1 ESCAPE '\\'",
                params![pattern],
            )
            .map_err(|e| legado_core::LegadoError::Database(format!("复位章级开关失败：{e}")))?;
        }
        Ok(deleted as i64)
    })
}

/// LIKE 模式转义：将 `\`、`%`、`_` 转为带 `\` 前缀的字面量，
/// 配合 `ESCAPE '\\'` 使用，防止 book_url 中的通配符造成跨书误删
fn like_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_apis() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 先清空缓存确保测试隔离
        clear_cache().unwrap();

        // 清空后缓存大小为 0
        let size = get_cache_size().unwrap();
        assert_eq!(size, 0);

        // 无缓存时返回空
        let content = get_chapter_cache("http://book.com/1", 0).unwrap();
        assert!(content.is_empty());

        // 清空缓存不报错
        assert!(clear_cache().unwrap());
    }

    /// Task #136 R5：写入→cache_get 读回一致
    #[test]
    fn test_save_chapter_content_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cache().unwrap();

        let book_url = "http://save-chapter.example.com/book1";
        let chapter_url = "http://save-chapter.example.com/ch3";
        let content = "第三章正文：缓存写侧闭环测试。";

        // 写入（显式 title/chapter_url）
        assert!(save_chapter_content(book_url, 3, "第三章", content, chapter_url).unwrap());

        // 读回一致
        let read_back = get_chapter_cache(book_url, 3).unwrap();
        assert_eq!(read_back, content, "写入后读回应一致");

        // 覆盖写入（INSERT OR REPLACE）
        let edited = "第三章正文（用户编辑后）";
        assert!(save_chapter_content(book_url, 3, "第三章", edited, chapter_url).unwrap());
        assert_eq!(get_chapter_cache(book_url, 3).unwrap(), edited);

        // 清理测试数据
        clear_cache().unwrap();
    }

    /// Task #51：VACUUM 压缩释放可回收空间；Task #55 F7 断言加强：
    /// 构造已知垃圾数据后首次压缩必须释放 > 0 字节，且首次释放量
    /// 大于第二次（第二次通常释放 0）
    #[test]
    fn test_shrink_database() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 制造可回收空间：写入再删除一大批缓存（量级足够大，确保
        // 删除后留下可被 VACUUM 回收的整页，共享库下仍稳定 freed > 0）
        for i in 0..100 {
            save_chapter_content(
                "http://shrink-test.example.com/book",
                i,
                &format!("第{i}章"),
                &"冗余正文数据填充".repeat(2000),
                &format!("http://shrink-test.example.com/ch/{i}"),
            )
            .unwrap();
        }
        clear_cache().unwrap();

        // 首次 VACUUM：构造的垃圾数据刚被删除，必然回收空间
        let freed = shrink_database();
        assert!(freed > 0, "首次压缩应释放正字节数，实际 {freed}");

        // 重复执行不报错（幂等语义：无新增垃圾时释放量应小于首次）
        let freed_again = shrink_database();
        assert!(freed_again >= 0);
        assert!(
            freed_again < freed,
            "第二次压缩释放量应小于首次（首次 {freed}，二次 {freed_again}）"
        );
    }

    /// Task #55 F5：clear_cache_before 清理过期章节的同时，复位被清理
    /// 书籍的章级「删除重复标题」开关键；未过期/他书的键不受影响
    #[test]
    fn test_clear_cache_before_resets_same_title_flags() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cache().unwrap();

        let old_book = "http://clear-before.example.com/book/old";
        let fresh_book = "http://clear-before.example.com/book/fresh";

        // 两本书各写一章缓存
        assert!(save_chapter_content(
            old_book,
            0,
            "旧章",
            "旧正文",
            "http://clear-before.example.com/ch/old0"
        )
        .unwrap());
        assert!(save_chapter_content(
            fresh_book,
            0,
            "新章",
            "新正文",
            "http://clear-before.example.com/ch/fresh0"
        )
        .unwrap());

        // 将 old_book 的 cached_at 改为远古时间，fresh_book 保持当前时间
        with_database(|db| {
            use rusqlite::params;
            db.connection()
                .execute(
                    "UPDATE cached_chapters SET cached_at = 1 WHERE book_url = ?1",
                    params![old_book],
                )
                .map_err(|e| LegadoError::Database(format!("构造测试数据失败: {e}")))?;
            Ok(())
        })
        .unwrap();

        // 两本书各写一个章级开关键（格式与 reader.rs same_title_removed_key 一致）
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            repo.put(&format!("sameTitleRemoved:{old_book}:0"), "1", 0)?;
            repo.put(&format!("sameTitleRemoved:{fresh_book}:0"), "1", 0)?;
            Ok(())
        })
        .unwrap();

        // 以中间时刻为界清理（old_book cached_at=1 命中，fresh_book
        // cached_at=当前时间不命中）
        let cutoff = 1_000_000_000_000i64; // 2001-09-09，介于远古与当前之间
        let deleted = clear_cache_before(cutoff).unwrap();
        assert_eq!(deleted, 1, "应仅删除 old_book 的过期章节");

        // old_book 的章级开关被复位（键已删），fresh_book 的不受影响
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            assert!(
                !repo.contains_key(&format!("sameTitleRemoved:{old_book}:0"))?,
                "被清理书籍的章级开关键应被删除"
            );
            assert!(
                repo.contains_key(&format!("sameTitleRemoved:{fresh_book}:0"))?,
                "未清理书籍的章级开关键应保留"
            );
            Ok(())
        })
        .unwrap();

        // 清理测试数据
        clear_cache().unwrap();
    }
}
