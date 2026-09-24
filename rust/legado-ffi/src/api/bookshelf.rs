//! 书架管理 API
//!
//! 提供书籍的增删改查操作，通过 BookRepository 访问数据库。

use legado_core::models::Book;
use legado_core::LegadoResult;
use legado_db::import::RoomImporter;
use legado_db::repository::Repository;
use legado_db::BookRepository;

use crate::db_state::with_database;

/// 获取书架上所有书籍
pub fn list_books() -> LegadoResult<Vec<Book>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        // Task#125 P0：仅返回已入书架的书，过滤 notShelf 临时书（搜索/发现打开的在线书）
        repo.find_all_in_shelf()
    })
}

/// [B-2 | P2-8 写侧防守 | 2026-09-18 审查 P1-1] 书源字段防陈旧快照回写合并：
/// `origin` / `originName` / `tocUrl` / `originBookUrl` 四列语义唯一——只由
/// 换源事务（source_switch.rs）与 preUpdateJs 钩子（reader.rs）写入，书架侧
/// **不存在合法的清空/改源场景**（改源走 `switch_book_source` API）。
/// Dart 侧持有的 Book 是陈旧内存快照（目录页/详情页 `_book` 对象不随换源
/// 更新），全行回写会把换源结果（origin/tocUrl/originBookUrl=新源）打回旧源，
/// 形成「origin=旧源 + 目录=新源章节」的不一致态，按旧源取正文必然失败。
///
/// 合并规则（书籍已存在时）：库内既有值非空 → 既有值优先（入参忽略）；
/// 既有值为空 → 用入参补齐（含 [P2-8 P1-1] 的 originBookUrl 入参为空补齐
/// 场景）。新建路径（无既有行）按入参原样落库。
/// `variable`/`customTag` 等**不参与**合并——用户可合法清空/修改，保持
/// 全行写入语义（入参为准）。
fn merge_source_fields(repo: &BookRepository<'_>, book: &mut Book) -> LegadoResult<()> {
    let Ok(Some(existing)) = repo.find_by_url(&book.book_url) else {
        return Ok(());
    };
    if !existing.origin.trim().is_empty() {
        book.origin = existing.origin;
    }
    if !existing.origin_name.trim().is_empty() {
        book.origin_name = existing.origin_name;
    }
    if !existing.toc_url.trim().is_empty() {
        book.toc_url = existing.toc_url;
    }
    if !existing.origin_book_url.trim().is_empty() {
        book.origin_book_url = existing.origin_book_url;
    }
    Ok(())
}

pub fn add_book(book_json: &str) -> LegadoResult<Book> {
    let mut book: Book = serde_json::from_str(book_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("Book JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        // Task#125 P0：用原地 UPDATE 语义的 upsert，避免对已存在的临时书
        // 触发 INSERT OR REPLACE 级联删除其章节目录（转正/重复加入书架时安全）
        merge_source_fields(&repo, &mut book)?; // [B-2 / P2-8 P1-1] 书源字段防回退
        repo.update(&book)?;
        Ok(book)
    })
}

/// 更新书籍信息（JSON 序列化传入）
pub fn update_book(book_json: &str) -> LegadoResult<()> {
    let mut book: Book = serde_json::from_str(book_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("Book JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        merge_source_fields(&repo, &mut book)?; // [B-2] 陈旧快照不得撤销换源结果
        repo.update(&book)
    })
}

/// 按 bookUrl 删除书籍
pub fn delete_book(book_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.delete_by_url(book_url)
    })
}

/// 按 bookUrl 获取单本书籍详情
pub fn get_book(book_url: &str) -> LegadoResult<Option<Book>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.find_by_url(book_url)
    })
}

/// 批量导入书籍（JSON 数组）
///
/// `json_array` 中每个元素为一本书的 JSON 对象，返回成功导入的数量。
pub fn import_books(json_array: &str) -> LegadoResult<i32> {
    with_database(|db| {
        let count = RoomImporter::import_books(db.connection(), json_array)?;
        Ok(count as i32)
    })
}

/// 更新阅读进度
///
/// [B-8] 换源/刷新目录的写事务持锁期间，进度写入会等满 busy_timeout(5s)
/// 后以 `database is locked` 失败，Dart 侧 `_saveProgress` 用 `catch (_) {}`
/// 吞掉 → 进度静默丢失。Rust 侧加短重试：锁类错误（消息含 locked/busy）
/// 最多 3 次尝试、200/400ms 退避；非锁错误（书籍不存在等）立即返回。
/// FFI 同步函数运行在工作线程，`std::thread::sleep` 不阻塞 Dart 主 isolate。
///
/// [B-9] chapter_index 越界时按既有目录范围收敛（目录为空只保证非负）；
/// 章节查不到时不保留旧标题（写 NULL）。
pub fn update_reading_progress(
    book_url: &str,
    chapter_index: i32,
    chapter_pos: i32,
) -> LegadoResult<()> {
    const MAX_ATTEMPTS: u32 = 3;
    let mut attempt: u32 = 0;
    loop {
        attempt += 1;
        match write_reading_progress_once(book_url, chapter_index, chapter_pos) {
            Ok(()) => return Ok(()),
            Err(e) => {
                let msg = e.to_string().to_lowercase();
                let lock_error = msg.contains("locked") || msg.contains("busy");
                if !lock_error || attempt >= MAX_ATTEMPTS {
                    return Err(e);
                }
                // [B-8] 退避 200ms / 400ms：等换源事务的写锁释放
                std::thread::sleep(std::time::Duration::from_millis(200 * attempt as u64));
            }
        }
    }
}

/// 进度写入单次执行（一次 DB 访问 + 单条字段级 UPDATE）
fn write_reading_progress_once(
    book_url: &str,
    chapter_index: i32,
    chapter_pos: i32,
) -> LegadoResult<()> {
    with_database(|db| {
        let conn = db.connection();
        let repo = BookRepository::new(conn);
        // 书籍必须存在：进度不写入不存在的书（对齐原实现「书籍不存在」错误）
        if repo.find_by_url(book_url)?.is_none() {
            return Err(legado_core::LegadoError::Database("书籍不存在".into()));
        }
        // [B-9] 越界保护：按既有目录收敛（目录为空时不收敛，仅保证非负）
        let chapter_repo = legado_db::BookChapterRepository::new(conn);
        let count = chapter_repo.count_by_book_url(book_url)?;
        let (clamped_index, chapter_title) = if count > 0 {
            let upper = (count - 1).min(i32::MAX as i64) as i32;
            let idx = chapter_index.clamp(0, upper);
            let title = chapter_repo
                .find_by_book_url_and_index(book_url, idx)?
                .map(|ch| ch.title);
            (idx, title)
        } else {
            (chapter_index.max(0), None)
        };
        let chapter_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        // [B-3] 进度只走字段级 update_progress，不整行写（其他列不受影响）
        repo.update_progress(
            book_url,
            clamped_index,
            chapter_pos,
            chapter_title.as_deref(),
            chapter_time,
        )
    })
}

/// 批量持久化书架排序（JSON 数组：`[{"bookUrl":"...", "order":1}, ...]`）
///
/// 对齐原版 `BookAdapter.swap` 结束后 `updateBook(*getItems())` 的 order 写回语义。
pub fn reorder_books(orders_json: &str) -> LegadoResult<()> {
    #[derive(serde::Deserialize)]
    struct BookOrderItem {
        #[serde(rename = "bookUrl")]
        book_url: String,
        order: i32,
    }
    let items: Vec<BookOrderItem> = serde_json::from_str(orders_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("排序 JSON 解析失败: {e}")))?;
    let orders: Vec<(String, i32)> = items.into_iter().map(|i| (i.book_url, i.order)).collect();
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.update_orders(&orders)
    })
}
