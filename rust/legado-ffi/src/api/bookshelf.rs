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
///
/// [批18c 设备复验 | 2026-10-27] origin 的例外：远程书库导入先把文件导入为
/// 本地书（`loc_book`），再用 `update_book` 改写为 `webDav::<url>`。这是
/// 「存储位置」变化而非换源，若沿用「既有非空即优先」会被打回 `loc_book`，
/// 导致远程书 origin 丢失。故入参为 WebDAV origin 且库内为本地/WebDAV
/// origin 时，允许入参覆盖；在线书源（http(s)）仍按 B-2 防回退。
fn merge_source_fields(repo: &BookRepository<'_>, book: &mut Book) -> LegadoResult<()> {
    use legado_core::models::book_type;

    let Ok(Some(existing)) = repo.find_by_url(&book.book_url) else {
        return Ok(());
    };
    let incoming_is_webdav = book_type::is_web_dav_origin(book.origin.trim());
    let existing_is_storage = existing.origin.trim() == book_type::LOCAL_TAG
        || book_type::is_web_dav_origin(existing.origin.trim());
    let allow_webdav_rewrite = incoming_is_webdav && existing_is_storage;
    if !existing.origin.trim().is_empty() && !allow_webdav_rewrite {
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

/// 单键更新书籍 `readConfig` JSON 中的指定键（契约 §2.2 `updateReadConfigField`）
///
/// [批32] 背景：`update_book` 是整书快照写，Dart `ReadConfig` 未建模的键
/// （`useGlobalAudioSkip` / `tocExpanded` / `manualReplaceRuleIds` 等）在
/// 「Dart → Rust 类型化模型 → 全行回写」往返中被丢弃——目录页每切一次
/// 「反转」就会把这些键清空。本方法在 DB 侧只合并目标键，其余键（含未建模
/// 键）原样保留，且不触碰其他列与进度列。
///
/// `value_json` 是**值本身**的 JSON 编码串（bool/string/number/对象/数组），
/// 直接经 `serde_json::Value` 合并进现有 readConfig 对象；`key` 为空白、
/// JSON 非法、书籍不存在一律报错（fail-closed，不静默成功）。
pub fn update_read_config_field(book_url: &str, key: &str, value_json: &str) -> LegadoResult<()> {
    let key = key.trim();
    if key.is_empty() {
        return Err(legado_core::LegadoError::Ffi(
            "readConfig 键名不能为空".to_string(),
        ));
    }
    let value: serde_json::Value = serde_json::from_str(value_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("readConfig 值 JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        if repo.find_by_url(book_url)?.is_none() {
            return Err(legado_core::LegadoError::Internal(format!(
                "书籍不存在: {book_url}"
            )));
        }
        repo.update_read_config_field(book_url, key, &value)
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

#[cfg(test)]
mod tests {
    use crate::db_state::with_database;
    use legado_core::models::{Book, ReadConfig};
    use legado_db::repository::Repository;
    use legado_db::BookRepository;

    /// [漫画设置作用域 2026-10-01] `update_book`（Dart `updateBook` 的 FFI 入口）
    /// 全行回写必须保留 readConfig 书级字段 `mangaScrollMode` /
    /// `webtoonSidePaddingDp`（此前 Rust 类型化 ReadConfig 不含该键，会被
    /// serde 静默丢弃），且进度列按既有语义不被陈旧快照回滚。
    #[test]
    fn test_update_book_preserves_manga_scope_read_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://manga-scope-ffi.example.com/book/1";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "书名".to_string(),
                author: "作者".to_string(),
                read_config: Some(ReadConfig {
                    reverse_toc: true,
                    daily_chapters: 7,
                    manga_scroll_mode: Some(2),
                    webtoon_side_padding_dp: Some(20),
                    ..ReadConfig::default()
                }),
                ..Book::default()
            })?;
            repo.update_progress(book_url, 5, 9, Some("第五章"), 1_700_000_000_000)?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // Dart 侧 updateBook 载荷形态：书级字段更新 + 故意携带陈旧进度快照
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "改名",
            "author": "作者",
            "type": 0,
            "durChapterIndex": 0,
            "durChapterPos": 0,
            "readConfig": {
                "reverseToc": true,
                "dailyChapters": 7,
                "mangaScrollMode": 3,
                "webtoonSidePaddingDp": 45
            }
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let saved = repo.find_by_url(book_url)?.expect("书籍记录应仍存在");
            assert_eq!(saved.name, "改名");
            let rc = saved.read_config.expect("readConfig 应保留");
            assert_eq!(rc.manga_scroll_mode, Some(3), "书级翻页模式不得被静默丢弃");
            assert_eq!(
                rc.webtoon_side_padding_dp,
                Some(45),
                "书级侧边留白不得被静默丢弃"
            );
            assert!(rc.reverse_toc);
            assert_eq!(rc.daily_chapters, 7);
            // 进度列不回滚（唯一常规写入口仍是 update_progress）
            assert_eq!(saved.dur_chapter_index, 5);
            assert_eq!(saved.dur_chapter_pos, 9);
            assert_eq!(saved.dur_chapter_title.as_deref(), Some("第五章"));
            Ok(())
        })
        .expect("DB 终态断言失败");

        // 收尾清理（共享测试库不留固定行）
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18c 设备复验] 远程书库导入：本地书 `loc_book` → `webDav::` origin
    /// 必须生效（旧实现被 B-2 防回退合并打回 `loc_book`，设备上导入后
    /// `books.origin` 仍是 `loc_book`，远程页无法显示「已在书架」）。
    #[test]
    fn test_update_book_allows_local_to_webdav_origin() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18c-remote-import.example.com/tmp/txt-sample.txt";
        let webdav_origin = "webDav::http://192.168.100.52:18081/dav/books/txt-sample.txt,{\"serverID\":1793070940707}";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "txt-sample".to_string(),
                origin: "loc_book".to_string(),
                origin_name: "txt-sample.txt".to_string(),
                ..Book::default()
            })
        })
        .expect("本地书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "txt-sample",
            "origin": webdav_origin,
            "originName": "txt-sample.txt",
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, webdav_origin,
                "远程书库导入必须能把 loc_book 改写为 webDav:: origin"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// B-2 回归：在线书源（http）的 origin 仍按「库内既有值优先」，
    /// 陈旧快照不得撤销换源结果（批18c 放宽仅限本地/WebDAV 存储 origin）。
    #[test]
    fn test_update_book_keeps_online_origin_against_stale_snapshot() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18c-stale-snapshot.example.com/book/1";
        let new_origin = "https://batch18c-new-source.example.com";
        let old_origin = "https://batch18c-old-source.example.com";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "书名".to_string(),
                origin: new_origin.to_string(),
                ..Book::default()
            })
        })
        .expect("换源后状态入库失败");

        let stale_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "书名",
            "origin": old_origin,
            "type": 0
        })
        .to_string();
        super::update_book(&stale_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, new_origin,
                "在线书源换源结果不得被陈旧快照撤销"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18d P3] 存储 origin 的合并分支：库内为 `webDav::`、入参也是
    /// `webDav::` 时允许入参覆盖（后写胜）。注意该分支的已知语义：Dart 若持有
    /// 陈旧快照（旧 URL），可能把更新的远程 URL 回退为旧值——这是「存储位置
    /// 变化」场景下为支持 loc_book → webDav 改写而接受的取舍；换源（http）
    /// 仍由 B-2 防回退保护。
    #[test]
    fn test_merge_origin_webdav_to_webdav_later_write_wins() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18d-webdav-rewrite.example.com/tmp/a.txt";
        let existing_origin = "webDav::http://dav.example.com/books/old.txt";
        let incoming_origin = "webDav::http://dav.example.com/books/new.txt";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "远程书".to_string(),
                origin: existing_origin.to_string(),
                ..Book::default()
            })
        })
        .expect("既有 webDav 书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "远程书",
            "origin": incoming_origin,
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, incoming_origin,
                "webDav→webDav 属存储位置变更，允许入参覆盖（后写胜）"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18d P3] 入参为本地 origin、库内为 `webDav::` 时不得回退：
    /// 远程书导入后的陈旧快照（loc_book）不能覆盖已写入的 webDav origin。
    #[test]
    fn test_merge_origin_webdav_kept_against_local_incoming() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18d-webdav-keep.example.com/tmp/b.txt";
        let existing_origin = "webDav::http://dav.example.com/books/b.txt";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "远程书".to_string(),
                origin: existing_origin.to_string(),
                ..Book::default()
            })
        })
        .expect("既有 webDav 书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "远程书",
            "origin": legado_core::models::book_type::LOCAL_TAG,
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, existing_origin,
                "入参为本地 origin 时不得覆盖库内 webDav origin"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18d P3] 库内 origin 为空时用入参补齐（空值不视为有效既有值）。
    #[test]
    fn test_merge_origin_empty_existing_uses_incoming() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18d-empty-origin.example.com/book/1";
        let incoming_origin = "https://batch18d-source.example.com";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "空 origin 书".to_string(),
                origin: String::new(),
                ..Book::default()
            })
        })
        .expect("空 origin 书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "空 origin 书",
            "origin": incoming_origin,
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, incoming_origin,
                "库内 origin 为空时应采用入参补齐"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    // ─── 批32：readConfig 单键写（契约 §2.2 updateReadConfigField）──────────

    /// 造一本 readConfig 直接写**原始 JSON** 的书（绕过类型化模型，
    /// 可写入 Dart/Rust 均未建模的键）
    fn seed_read_config_raw(book_url: &str, raw_json: Option<&str>) {
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "单键写测试书".to_string(),
                origin: "https://batch32.example.com".to_string(),
                ..Book::default()
            })?;
            if let Some(raw) = raw_json {
                db.connection()
                    .execute(
                        "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                        rusqlite::params![raw, book_url],
                    )
                    .map_err(|e| {
                        legado_core::LegadoError::Database(format!("写原始 readConfig 失败: {e}"))
                    })?;
            }
            Ok(())
        })
        .expect("原始 readConfig 入库失败");
    }

    /// 读回 readConfig 原始 JSON（用于断言未建模键保留）
    fn raw_read_config(book_url: &str) -> serde_json::Value {
        with_database(|db| {
            let raw: Option<String> = db
                .connection()
                .query_row(
                    "SELECT readConfig FROM books WHERE bookUrl = ?1",
                    rusqlite::params![book_url],
                    |row| row.get(0),
                )
                .map_err(|e| {
                    legado_core::LegadoError::Database(format!("查询 readConfig 失败: {e}"))
                })?;
            Ok(
                serde_json::from_str(&raw.unwrap_or_else(|| "{}".to_string()))
                    .expect("readConfig 应为合法 JSON"),
            )
        })
        .expect("读取 readConfig 失败")
    }

    fn cleanup_book(book_url: &str) {
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// 单键写只改目标键：Dart `ReadConfig` 未建模的键（`useGlobalAudioSkip` /
    /// `tocExpanded` / `manualReplaceRuleIds`）与其他键原样保留，进度列不受影响。
    ///
    /// 红→绿对照：旧路径 `update_book`（整书快照写）用 Dart 侧 `ReadConfig`
    /// JSON（不含未建模键）回写时，`useGlobalAudioSkip` 被 Rust 类型化默认值
    /// 覆盖为 false、`tocExpanded`/`manualReplaceRuleIds` 被直接丢弃；本用例
    /// 的断言在旧路径下失败（红），单键写后通过（绿）。
    #[test]
    fn test_update_read_config_field_preserves_unmodeled_keys() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-single-key.example.com/book/1";
        seed_read_config_raw(
            book_url,
            Some(
                r#"{"reverseToc":false,"reverseTocDisplay":false,"useGlobalAudioSkip":true,"tocExpanded":{"0":true},"manualReplaceRuleIds":[3,5]}"#,
            ),
        );
        with_database(|db| {
            BookRepository::new(db.connection()).update_progress(
                book_url,
                7,
                11,
                Some("第七章"),
                1_700_000_000_000,
            )?;
            Ok(())
        })
        .expect("进度写入失败");

        super::update_read_config_field(book_url, "reverseToc", "true").expect("单键写应成功");

        let cfg = raw_read_config(book_url);
        assert_eq!(cfg["reverseToc"], serde_json::json!(true), "目标键应被更新");
        assert_eq!(
            cfg["reverseTocDisplay"],
            serde_json::json!(false),
            "非目标键不得被改写"
        );
        assert_eq!(
            cfg["useGlobalAudioSkip"],
            serde_json::json!(true),
            "Dart 未建模的 useGlobalAudioSkip 必须原样保留"
        );
        assert_eq!(
            cfg["tocExpanded"],
            serde_json::json!({"0": true}),
            "未建模的对象键必须原样保留"
        );
        assert_eq!(
            cfg["manualReplaceRuleIds"],
            serde_json::json!([3, 5]),
            "未建模的数组键必须原样保留"
        );

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            let rc = saved.read_config.expect("readConfig 应保留");
            assert!(rc.reverse_toc, "单键写结果应对类型化模型可见");
            assert!(rc.use_global_audio_skip, "未建模键读出不应回退默认值");
            assert_eq!(saved.dur_chapter_index, 7, "进度列不得被触碰");
            assert_eq!(saved.dur_chapter_pos, 11, "进度列不得被触碰");
            Ok(())
        })
        .expect("类型化读回断言失败");

        cleanup_book(book_url);
    }

    /// JSON 值类型往返：bool / string / number / 对象 均按 `valueJson` 原样落库
    #[test]
    fn test_update_read_config_field_json_value_types() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-value-types.example.com/book/1";
        seed_read_config_raw(book_url, Some(r#"{"reverseToc":true}"#));

        super::update_read_config_field(book_url, "flagKey", "false").expect("bool 写入失败");
        super::update_read_config_field(book_url, "stringKey", "\"你好, legado\"")
            .expect("string 写入失败");
        super::update_read_config_field(book_url, "numberKey", "3.5").expect("number 写入失败");
        super::update_read_config_field(book_url, "objectKey", r#"{"a":1,"b":["x"]}"#)
            .expect("对象写入失败");

        let cfg = raw_read_config(book_url);
        assert_eq!(cfg["flagKey"], serde_json::json!(false));
        assert_eq!(cfg["stringKey"], serde_json::json!("你好, legado"));
        assert_eq!(cfg["numberKey"], serde_json::json!(3.5));
        assert_eq!(cfg["objectKey"], serde_json::json!({"a": 1, "b": ["x"]}));
        assert_eq!(
            cfg["reverseToc"],
            serde_json::json!(true),
            "可选键写入不影响其他键"
        );

        cleanup_book(book_url);
    }

    /// `readConfig` 为空（NULL）时新建对象并只写入目标键
    #[test]
    fn test_update_read_config_field_creates_config_when_empty() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-empty-config.example.com/book/1";
        seed_read_config_raw(book_url, None);

        super::update_read_config_field(book_url, "reverseTocDisplay", "true")
            .expect("空 readConfig 单键写应成功");

        let cfg = raw_read_config(book_url);
        assert_eq!(cfg, serde_json::json!({"reverseTocDisplay": true}));

        cleanup_book(book_url);
    }

    /// fail-closed：书籍不存在 / 键名为空白 / 值 JSON 非法 均报错
    #[test]
    fn test_update_read_config_field_rejects_missing_book_blank_key_and_bad_json() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-errors.example.com/book/1";
        seed_read_config_raw(book_url, Some(r#"{"reverseToc":false}"#));

        let err = super::update_read_config_field(
            "https://batch32-errors.example.com/book/missing",
            "reverseToc",
            "true",
        )
        .expect_err("书不存在必须报错");
        assert!(
            err.to_string().contains("书籍不存在"),
            "错误信息应指出书籍不存在，实际：{err}"
        );

        let err =
            super::update_read_config_field(book_url, "   ", "true").expect_err("空白键名必须报错");
        assert!(
            err.to_string().contains("键名不能为空"),
            "错误信息应指出键名为空，实际：{err}"
        );

        let err = super::update_read_config_field(book_url, "reverseToc", "not-json")
            .expect_err("非法 JSON 值必须报错");
        assert!(
            err.to_string().contains("JSON 解析失败"),
            "错误信息应指出 JSON 非法，实际：{err}"
        );

        // 失败调用不得留下半写状态
        let cfg = raw_read_config(book_url);
        assert_eq!(cfg, serde_json::json!({"reverseToc": false}));

        cleanup_book(book_url);
    }
}
