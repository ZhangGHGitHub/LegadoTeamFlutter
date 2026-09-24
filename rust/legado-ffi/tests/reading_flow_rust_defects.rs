//! [视角 B 猎捕 2026-09-24] 阅读主流程 Rust 数据链路缺陷复现
//!
//! 本文件是**缺陷复现集**（红态证据），只新增测试、不改生产代码。
//! 覆盖范围：缓存语义（cached_chapters 键/命中条件/换目录失效）、
//! 进度读写（整行覆盖）、目录写入原子性、正文取用（空缓存短路）。
//!
//! 基建纪律（与 tests/toc_refresh_perf.rs / three_entry_parity.rs 同款）：
//! - 本文件自建**文件型** DB（`ffi::db_open` → 池 16 连接），使
//!   「两个连接观察同一份数据」可确定性复现；内存库池大小固定 1 无法做到；
//! - 全部测试持 `TEST_LOCK` 串行（共享全局 DB 池/进程级状态）；
//! - 不触网：所有用例要么纯 DB，要么走「缓存命中不联网」的短路分支
//!   （书源 URL 故意用不存在域名，命中缓存时不会走到书源查找）。
//!
//! 运行：`cargo test -p legado-ffi --test reading_flow_rust_defects -- --nocapture`
//! 预期：本文件中的 `red_*` 用例**红**（缺陷复现），`perf_*` 用例绿。

use std::sync::{Mutex, MutexGuard, OnceLock};

use legado_core::models::BookChapter;
use legado_ffi::legado_db::repository::Repository as _;
use legado_ffi::legado_db::{BookChapterRepository, BookRepository, CacheBookRepository};

// ─── 基建 ───────────────────────────────────────────────────────────────────

/// 全部测试串行：共享全局文件 DB。
static TEST_LOCK: Mutex<()> = Mutex::new(());

fn temp_db_path() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "legado-ffi-reading-flow-defects-{}.db",
        std::process::id()
    ))
}

/// 打开本文件专用文件型 DB（池 16 连接；进程内 first-wins，只开一次）
fn ensure_file_db() -> MutexGuard<'static, ()> {
    static INIT: OnceLock<()> = OnceLock::new();
    let guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    INIT.get_or_init(|| {
        let path = temp_db_path();
        let _ = std::fs::remove_file(&path);
        legado_ffi::ffi::ffi::db_open(path.to_string_lossy().into_owned())
            .expect("db_open 文件型 DB（含迁移 + 池构建）");
    });
    guard
}

fn with_db<F, R>(f: F) -> R
where
    F: FnOnce(&legado_ffi::legado_db::Database) -> legado_ffi::legado_core::LegadoResult<R>,
{
    legado_ffi::db_state::with_database(f).expect("DB 访问失败")
}

/// 清理一本书的全部痕迹（用例开始前调用，保证不依赖历史状态）
fn purge(book_url: &str) {
    with_db(|db| {
        let _ = CacheBookRepository::new(db.connection()).delete_by_book(book_url);
        let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
        let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
        Ok(())
    });
}

fn book_json(url: &str, name: &str, origin: &str, toc_url: &str) -> String {
    format!(
        r#"{{"bookUrl":"{url}","name":"{name}","author":"作者","origin":"{origin}",
            "originName":"源","tocUrl":"{toc_url}","type":0}}"#
    )
}

fn seed_chapters(book_url: &str, n: usize, url_prefix: &str) {
    let chapters: Vec<BookChapter> = (0..n)
        .map(|i| BookChapter {
            url: format!("{url_prefix}/{i}"),
            title: format!("第{}章", i + 1),
            base_url: url_prefix.to_string(),
            book_url: book_url.to_string(),
            index: i as i32,
            ..BookChapter::default()
        })
        .collect();
    with_db(|db| BookChapterRepository::new(db.connection()).insert_batch(&chapters));
}

// ─── 缺陷 1：进度读写的整行覆盖 ─────────────────────────────────────────────

/// [缺陷 B-1 | 主流程重扰] `update_book` 全行覆盖：Dart 侧持陈旧 Book 快照
/// 回写（目录页菜单/详情页开关）会把阅读进度整列打回快照值。
///
/// 触发路径（三入口全走 Rust 公共 FFI，无 mock）：
/// 1. `add_book`（Dart 目录页加载时的 Book 快照，durChapterIndex=0）
/// 2. 阅读器翻到第 8 章 → `update_reading_progress(7, 123)` 落库
/// 3. 回到目录页点菜单「拆分长章节」→ `update_book(第 1 步快照 + readConfig)`
///    （toc_screen.dart:405 `_updateBook(_book.copyWith(...))`，`_book` 不随阅读更新）
/// 4. `get_book` → durChapterIndex 被打回 0、durChapterPos 被打回 0
///
/// 期望：更新 readConfig 不得影响进度列（对齐 updat2026-09-17 P2-1 单列更新先例）。
/// 实际：`bookshelf.rs:59 repo.update(&book)` 全 37 列写入，进度回退。
#[test]
fn red_update_book_stale_snapshot_reverts_reading_progress() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b1.example.com/book/1";
    purge(book_url);

    // 1) Dart 侧快照（目录页打开时）
    let snapshot = book_json(
        book_url,
        "缺陷书一",
        "https://defect-b1.example.com",
        "https://defect-b1.example.com/toc",
    );
    legado_ffi::api::bookshelf::add_book(&snapshot).expect("加入书架");
    seed_chapters(book_url, 10, "https://defect-b1.example.com/ch1");

    // 2) 阅读器翻到第 8 章并保存进度
    legado_ffi::api::bookshelf::update_reading_progress(book_url, 7, 123).expect("保存进度");
    let after_read = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");
    assert_eq!(after_read.dur_chapter_index, 7, "前置：进度已写入");
    assert_eq!(after_read.dur_chapter_pos, 123, "前置：位置已写入");

    // 3) 目录页菜单回写陈旧快照（仅改 readConfig）
    let stale_with_toggle = snapshot.replace(
        r#""type":0"#,
        r#""type":0,"readConfig":{"splitLongChapter":true}"#,
    );
    legado_ffi::api::bookshelf::update_book(&stale_with_toggle).expect("目录页菜单保存");

    // 4) 进度是否被陈旧快照覆盖
    let after_toggle = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");
    assert_eq!(
        after_toggle.dur_chapter_index, 7,
        "期望：目录页菜单保存不得回退进度；实际 durChapterIndex={}（被陈旧快照打回 0）",
        after_toggle.dur_chapter_index
    );
    assert_eq!(
        after_toggle.dur_chapter_pos, 123,
        "期望：durChapterPos 保持 123；实际 {}",
        after_toggle.dur_chapter_pos
    );
}

/// [缺陷 B-2 | 主流程阻断] 换源结果被陈旧 Book 快照整行撤销：
/// `update_book(旧快照)` 会把 origin/originName/tocUrl/originBookUrl 打回旧源，
/// 而 chapters 表已是新源章节 → 「origin=旧源 + 目录=新源章节」不一致态，
/// 阅读器按旧源取正文（旧源章节 URL 已不在目录中）必然抓不到正文。
///
/// 触发路径：换源（`source_switch.rs:830` 写 origin/tocUrl/originBookUrl）成功后，
/// 任何持换源前 Book 对象的 `updateBook`（书架置顶/分组/详情页开关/目录页菜单）
/// 都会把书源字段打回。本用例以 `update_reading_progress` 之外的写路径复现
/// （`update_reading_progress` 内部读的是 DB 新值，不受影响；`update_book` 读的是
/// 调用方传入的对象）。
#[test]
fn red_update_book_stale_snapshot_reverts_source_switch() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b2.example.com/book/1";
    let old_origin = "https://defect-b2-old.example.com";
    let new_origin = "https://defect-b2-new.example.com";
    purge(book_url);

    // 换源前：Dart 侧持有旧源快照
    let stale_snapshot = book_json(
        book_url,
        "缺陷书二",
        old_origin,
        "https://defect-b2-old.example.com/toc",
    );
    legado_ffi::api::bookshelf::add_book(&stale_snapshot).expect("加入书架");
    seed_chapters(book_url, 3, "https://defect-b2-old.example.com/ch");

    // 换源事务的 DB 段（source_switch.rs:783-840 逐语句等价：全行 update + 清缓存 + 换章节）。
    // [B-7] 生产换源链本就包在同一事务（delete_by_book_url 事务外为 no-op），
    // 模拟同样须包事务，旧章节才会真正被删除（断言不变）
    with_db(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| legado_core::LegadoError::Database(format!("开启事务失败: {e}")))?;
        let repo = BookRepository::new(conn);
        let mut book = repo.find_by_url(book_url)?.expect("书籍存在");
        book.origin = new_origin.to_string();
        book.origin_name = "新源".to_string();
        book.toc_url = format!("{new_origin}/toc");
        book.origin_book_url = format!("{new_origin}/book/1");
        repo.update(&book)?;
        CacheBookRepository::new(conn).delete_by_book(book_url)?;
        BookChapterRepository::new(conn).delete_by_book_url(book_url)?;
        tx.commit()
            .map_err(|e| legado_core::LegadoError::Database(format!("提交事务失败: {e}")))?;
        Ok(())
    });
    seed_chapters(book_url, 5, "https://defect-b2-new.example.com/ch");

    // 换源后：Dart 侧某处仍持旧快照 → updateBook（如「置顶」topBook 读的是新值，
    // 但目录页/详情页的 _book 是旧对象）
    legado_ffi::api::bookshelf::update_book(&stale_snapshot).expect("陈旧快照回写");

    let after = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");
    let chapter_count =
        with_db(|db| BookChapterRepository::new(db.connection()).count_by_book_url(book_url));

    assert_eq!(
        after.origin, new_origin,
        "期望：换源结果（origin）不被陈旧快照撤销；实际 origin={}（被打回旧源）",
        after.origin
    );
    assert_eq!(
        after.toc_url,
        format!("{new_origin}/toc"),
        "期望：tocUrl 保持新源目录页；实际 {}",
        after.toc_url
    );
    assert_eq!(chapter_count, 5, "前置：目录已是新源 5 章");
}

// ─── 缺陷 2：进度保存整行覆盖（并发写次序） ─────────────────────────────────

/// [缺陷 B-3 | 主流程重扰] 换源事务用「抓取前快照」全行回写，抹掉换源窗口内的
/// 进度写入。窗口 = 详情抓取 + 目录抓取（网络，实测 ≈10 分钟量级）——
/// 用户换源期间继续阅读/切后台触发的进度保存全部丢失。
///
/// 本用例用**真实进度写入口** `update_reading_progress`（不是复刻调用序列）
/// 在换源窗口内写进度，再执行换源事务的 DB 段，断言进度是否被抹平。
/// 期望：换源提交后进度仍为窗口内写入的值。
/// 实际：`source_switch.rs:830 BookRepository::update(&book)` 用 10 分钟前的
/// 37 列快照整行覆盖 → 进度回退。
#[test]
fn red_source_switch_snapshot_clobbers_progress_written_in_window() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b3.example.com/book/1";
    let old_origin = "https://defect-b3-old.example.com";
    let new_origin = "https://defect-b3-new.example.com";
    purge(book_url);

    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "缺陷书三",
        old_origin,
        "https://defect-b3-old.example.com/toc",
    ))
    .expect("加入书架");
    seed_chapters(book_url, 4, "https://defect-b3-old.example.com/ch");

    // 换源开始：抓取前快照（source_switch.rs:645）
    let mut switch_snapshot = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");

    // —— 换源窗口（详情 + 目录网络抓取，分钟级）内，阅读器保存进度 ——
    legado_ffi::api::bookshelf::update_reading_progress(book_url, 3, 456).expect("窗口内保存进度");
    let in_window = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");
    assert_eq!(in_window.dur_chapter_index, 3, "前置：窗口内进度已落库");

    // —— 换源事务提交（source_switch.rs:783-840：改快照书源字段后全行 update）——
    switch_snapshot.origin = new_origin.to_string();
    switch_snapshot.origin_name = "新源".to_string();
    switch_snapshot.toc_url = format!("{new_origin}/toc");
    switch_snapshot.origin_book_url = format!("{new_origin}/book/1");
    switch_snapshot.last_check_time = 0;
    with_db(|db| {
        BookRepository::new(db.connection()).update(&switch_snapshot)?;
        CacheBookRepository::new(db.connection()).delete_by_book(book_url)?;
        BookChapterRepository::new(db.connection()).delete_by_book_url(book_url)?;
        Ok(())
    });
    seed_chapters(book_url, 6, "https://defect-b3-new.example.com/ch");

    let after = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");
    assert_eq!(
        after.dur_chapter_index, 3,
        "期望：换源提交不得抹掉窗口内写入的进度；实际 durChapterIndex={}（被抓取前快照覆盖）",
        after.dur_chapter_index
    );
    assert_eq!(
        after.dur_chapter_pos, 456,
        "期望：durChapterPos=456；实际 {}",
        after.dur_chapter_pos
    );
}

// ─── 缺陷 3：缓存命中条件（空内容算命中） ──────────────────────────────────

/// [缺陷 B-4 | 主流程阻断] 空正文缓存行被当作**命中**，正文获取被永久短路：
/// 编辑内容清空后保存（reader_top_bar.dart `_saveEditedContent(ctrl.text)` 允许
/// 空串）→ 写空缓存 → 之后每次 `fetchChapterContent` 都命中空缓存直接返回空，
/// 永不重取网络 → 该章永久空白（只有清缓存能恢复）。
///
/// 证据手法：书源 URL 故意用不存在域名。
///
/// - 若空缓存**不算命中**，函数会走网络路径 → 先 `BookSourceRepository::find_by_url`
///   → 必然返回可读错误「书源不存在」；
/// - 若空缓存**算命中**，函数直接 Ok("") 返回，完全不查书源。
///
/// 断言「返回空串且不报错」即证明命中短路。
#[test]
fn red_empty_cached_chapter_content_short_circuits_fetch() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b4.example.com/book/1";
    let chapter_url = "https://defect-b4.example.com/ch/0";
    let bogus_source = "https://defect-b4-no-such-source.example.com";
    purge(book_url);

    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "缺陷书四",
        bogus_source,
        "https://defect-b4.example.com/toc",
    ))
    .expect("加入书架");
    seed_chapters(book_url, 1, "https://defect-b4.example.com/ch");

    // 模拟「编辑内容 → 清空 → 保存」写入空正文缓存
    legado_ffi::api::cache_api::save_chapter_content(book_url, 0, "第1章", "", chapter_url)
        .expect("写空缓存");

    let result =
        legado_ffi::api::reader::fetch_chapter_content(book_url, chapter_url, bogus_source);

    // 期望：空缓存不应视为命中（应继续抓取，此处因书源不存在而报错）
    assert!(
        result.is_err(),
        "期望：空正文缓存应视为未命中并继续取正文（书源不存在 → Err）；\
         实际 Ok({:?}) = 空缓存短路了网络抓取",
        result.as_ref().ok()
    );
}

/// [缺陷 B-5 | 主流程重扰] 索引键读取 vs (book,url) 复合键写入的键不一致：
/// 换目录（refresh_toc 重写 chapters 的 URL）后旧缓存行**不被清理**，
/// `get_chapter_cache(book, index)` 仍返回**上一代目录页**的正文。
///
/// 消费者：change_chapter_source_sheet.dart:180（单章换源取候选正文）、
/// reader_top_bar.dart:983（去重复标题试算）、缓存导出。
/// 单章换源场景会把上一代目录的正文当成本章正文写回当前书 → 张冠李戴。
#[test]
fn red_stale_cache_row_returned_after_toc_change() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b5.example.com/book/1";
    let old_chapter_url = "https://defect-b5-old.example.com/ch/5";
    purge(book_url);

    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "缺陷书五",
        "https://defect-b5.example.com",
        "https://defect-b5.example.com/toc",
    ))
    .expect("加入书架");

    // 一代目录：第 6 章（index=5）正文已缓存
    seed_chapters(book_url, 8, "https://defect-b5-old.example.com/ch");
    legado_ffi::api::cache_api::save_chapter_content(
        book_url,
        5,
        "第6章",
        "【上一代目录页的第6章正文】",
        old_chapter_url,
    )
    .expect("写缓存");

    // 换目录：refresh_toc 的实际写库效果（仅重写 chapters 表，
    // 不触碰 cached_chapters）。[B-7] 修复后 refresh_toc 的删旧+写新包在同一
    // 事务（delete_by_book_url 事务外为 no-op），故此处模拟也须包事务，
    // 旧章节才会真正被删除（断言不变）
    with_db(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| legado_core::LegadoError::Database(format!("开启事务失败: {e}")))?;
        BookChapterRepository::new(conn).delete_by_book_url(book_url)?;
        tx.commit()
            .map_err(|e| legado_core::LegadoError::Database(format!("提交事务失败: {e}")))?;
        Ok(())
    });
    seed_chapters(book_url, 9, "https://defect-b5-new.example.com/ch");

    let new_chapter_url = with_db(|db| {
        Ok(BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, 5)?
            .expect("新目录第 6 章存在")
            .url)
    });
    assert_ne!(new_chapter_url, old_chapter_url, "前置：换目录后 URL 已变");

    // 目录页云图标数据源：仍返回上一代 URL（新目录 9 章全被判「未缓存」）
    let cached_urls =
        legado_ffi::api::cache_api::list_cached_chapter_urls(book_url).expect("列出缓存 URL");
    assert!(
        cached_urls.iter().all(|u| u != &new_chapter_url),
        "期望：换目录后缓存 URL 集合应随新目录对齐；实际 {cached_urls:?} 不含 {new_chapter_url}"
    );

    // 索引键读取：把上一代正文当成本章正文返回
    let by_index =
        legado_ffi::api::cache_api::get_chapter_cache(book_url, 5).expect("按索引读缓存");
    assert!(
        by_index.is_empty(),
        "期望：新目录第 6 章（URL 未缓存）应返回空；实际返回上一代正文 {by_index:?}（张冠李戴）"
    );
}

// ─── 缺陷 4：目录删除 + 重写的原子性 ───────────────────────────────────────

/// [缺陷 B-6 | 主流程重扰] `refresh_toc` 的「删旧章节 + 写新章节」未包同一事务：
/// `delete_by_book_url`（reader.rs:566，autocommit）与 `insert_batch`
/// （reader.rs:567，自己的事务）分属两条 statement，中间态「0 章」可被
/// 另一连接并发观察到：并发翻章 `get_chapter_content_full` → 「章节 N 不存在」，
/// 并发 `get_chapters` → 空目录。写锁被占时 insert 还会等 busy_timeout=5s，
/// 中间态最长可达秒级。
///
/// 证据手法：本文件用文件型 DB（池 16）→ 连接 A 执行 delete、连接 B 观察到 0 章
/// （生产 `with_database` 每次取池连接，两调用点确实可能落在不同连接）。
#[test]
fn red_toc_rewrite_delete_and_insert_not_atomic() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b6.example.com/book/1";
    purge(book_url);

    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "缺陷书六",
        "https://defect-b6.example.com",
        "https://defect-b6.example.com/toc",
    ))
    .expect("加入书架");
    seed_chapters(book_url, 4, "https://defect-b6.example.com/ch");

    // 连接 A：refresh_toc 的第一步（reader.rs:566）
    with_db(|db| BookChapterRepository::new(db.connection()).delete_by_book_url(book_url));

    // 连接 B：并发读者看到的世界
    let observed = legado_ffi::api::reader::get_chapters(book_url).expect("并发读目录");
    let observed_count = observed.total;

    // 连接 A：refresh_toc 的第二步（reader.rs:567）
    seed_chapters(book_url, 6, "https://defect-b6.example.com/ch");

    assert_eq!(
        observed_count, 4,
        "期望：目录刷新期间读者不得观察到「0 章」中间态（删+写须同事务）；实际并发读到 {observed_count} 章"
    );
}

// ─── 缺陷 5：换源事务持写锁期间的读者/写者行为 ─────────────────────────────

/// [缺陷 B-8 | 主流程重扰] 换源/刷新目录事务持写锁期间（联网抓取完成后到提交前的
/// 写事务段，最长可被 busy_timeout 拉到秒级；抓取本身分钟级不持锁）：
/// - 读者（get_book / get_chapters / 缓存命中取正文）不受影响（WAL：读不阻塞）；
/// - 写者（保存阅读进度）等待 busy_timeout=5000ms 后以 `database is locked` 失败，
///   Dart `_saveProgress` 用 `catch (_) {}` 吞掉 → **进度静默丢失、无任何反馈**。
///
/// 本用例证明：换源事务持锁时进度写入必然失败（约 5s 后），而同一时刻读取正常。
/// 期望：进度保存要么排队成功、要么向用户暴露失败；实际静默丢。
/// （本用例本身为绿——它度量的是「失败延迟 5s」这一事实，红态断言在 Dart 侧
/// `catch (_) {}` 的无反馈语义，需实机观察，见汇报「疑似未复现」小节。）
#[test]
fn green_progress_write_fails_during_switch_write_lock() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b8.example.com/book/1";
    purge(book_url);
    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "缺陷书八",
        "https://defect-b8.example.com",
        "https://defect-b8.example.com/toc",
    ))
    .expect("加入书架");
    seed_chapters(book_url, 2, "https://defect-b8.example.com/ch");

    // 连接 A（独立 rusqlite 连接，同一文件）：模拟换源事务的写事务段——
    // BEGIN IMMEDIATE 立即取 RESERVED 写锁并保持不提交（生产为
    // source_switch.rs:826 `unchecked_transaction()` 起的写事务，语义等价）
    let holder = rusqlite::Connection::open(temp_db_path()).expect("持锁连接");
    holder
        .execute_batch(
            "PRAGMA busy_timeout = 5000;\
             BEGIN IMMEDIATE;\
             UPDATE books SET origin = 'https://defect-b8-new.example.com' WHERE 0;",
        )
        .expect("取写锁");

    // 读者：WAL 下不被阻塞
    let t_read = std::time::Instant::now();
    let read_ok = legado_ffi::api::bookshelf::get_book(book_url).is_ok();
    let read_elapsed = t_read.elapsed();

    // 写者：保存进度 → 等满 busy_timeout(5s) 后失败
    let t_write = std::time::Instant::now();
    let write_result = legado_ffi::api::bookshelf::update_reading_progress(book_url, 1, 42);
    let write_elapsed = t_write.elapsed();

    drop(holder); // 关闭连接 → 回滚，释放写锁

    eprintln!(
        "[busy] 持锁期间：读 getBook ok={read_ok} 耗时={read_elapsed:?}；\
         写 update_reading_progress is_err={} 耗时={write_elapsed:?} 错误={:?}",
        write_result.is_err(),
        write_result.as_ref().err().map(|e| e.to_string())
    );

    assert!(read_ok, "前置：WAL 下读不应被写事务阻塞");
    assert!(
        write_result.is_err(),
        "前置：持写锁时进度写入应经 busy_timeout 失败（Dart 侧 catch(_) 吞掉 = 静默丢进度）"
    );
}

/// [缺陷 B-8 | 量化验证] 写锁**短暂持有**（6s，模拟换源事务写事务段的实际
/// 时长上界）后释放：进度写入应在重试窗口内成功（首次尝试等满
/// busy_timeout=5s 失败 → 退避 200ms → 第二次尝试在锁释放时成功，总耗时
/// ≈6s）。证明 [B-8] 的短重试把「静默丢进度」变为「排队成功后写入」。
#[test]
fn green_progress_write_succeeds_after_brief_write_lock_release() {
    let _g = ensure_file_db();
    let book_url = "https://defect-b8-retry.example.com/book/1";
    purge(book_url);
    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "缺陷书八-重试",
        "https://defect-b8-retry.example.com",
        "https://defect-b8-retry.example.com/toc",
    ))
    .expect("加入书架");
    seed_chapters(book_url, 2, "https://defect-b8-retry.example.com/ch");

    // 连接 A：模拟换源事务写事务段——持写锁 6s 后释放（生产写事务段
    // 远短于抓取前的分钟级窗口，6s 覆盖 busy_timeout=5s 量级）
    let holder_path = temp_db_path();
    let holder = std::thread::spawn(move || {
        let conn = rusqlite::Connection::open(holder_path).expect("持锁连接");
        conn.execute_batch(
            "PRAGMA busy_timeout = 0;\
             BEGIN IMMEDIATE;\
             UPDATE books SET origin = 'https://defect-b8-retry-new.example.com' WHERE 0;",
        )
        .expect("取写锁");
        std::thread::sleep(std::time::Duration::from_secs(6));
        drop(conn); // 回滚释放写锁
    });

    // 等持锁连接完成 BEGIN IMMEDIATE 后再发起进度写
    std::thread::sleep(std::time::Duration::from_millis(300));
    let t_write = std::time::Instant::now();
    let result = legado_ffi::api::bookshelf::update_reading_progress(book_url, 1, 42);
    let elapsed = t_write.elapsed();
    let _ = holder.join();

    let is_err = result.is_err();
    eprintln!(
        "[busy-retry] 持锁 6s 释放后：update_reading_progress is_err={is_err} 耗时={elapsed:?}"
    );

    assert!(
        result.is_ok(),
        "期望：锁在重试窗口内释放后进度写入应成功；实际 {:?}",
        result.as_ref().err().map(|e| e.to_string())
    );
    assert!(
        elapsed < std::time::Duration::from_secs(12),
        "期望：总耗时 ≈6s（首试 5s 失败 + 退避 200ms + 二试随锁释放成功）；实际 {elapsed:?}"
    );

    let saved = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("查询")
        .expect("书籍存在");
    assert_eq!(saved.dur_chapter_index, 1, "进度应已落库（index=1）");
    assert_eq!(saved.dur_chapter_pos, 42, "位置应已落库（pos=42）");
}

// ─── 耗时剖面（本文件自带，绿） ─────────────────────────────────────────────

/// [耗时剖面] 本地（无网络）各接口耗时：章节规模 3000 的在线书。
///
/// 覆盖 `getBook` / `getChapters` / `getChapterContentFull`（缓存命中分支）/
/// `fetchChapterContent`（缓存未命中 → 缺书源报错，只度量前置 DB 段）。
/// 断言宽松上限（< 2s）防回归；数值经 `--nocapture` 打印供汇报取用。
#[test]
fn perf_reader_data_local_profile() {
    let _g = ensure_file_db();
    let book_url = "https://perf-profile.example.com/book/1";
    let bogus_origin = "https://perf-profile-no-such-source.example.com";
    purge(book_url);

    legado_ffi::api::bookshelf::add_book(&book_json(
        book_url,
        "剖面书",
        bogus_origin,
        "https://perf-profile.example.com/toc",
    ))
    .expect("加入书架");
    seed_chapters(book_url, 3000, "https://perf-profile.example.com/ch");

    let t = std::time::Instant::now();
    let book = legado_ffi::api::bookshelf::get_book(book_url)
        .expect("getBook")
        .expect("存在");
    let t_get_book = t.elapsed();

    let t = std::time::Instant::now();
    let toc = legado_ffi::api::reader::get_chapters(book_url).expect("getChapters");
    let t_get_chapters = t.elapsed();

    // 缓存命中分支：先写缓存，再取正文（不联网）
    let idx = 1500;
    let chapter_url = with_db(|db| {
        Ok(BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, idx)?
            .expect("章节存在")
            .url)
    });
    legado_ffi::api::cache_api::save_chapter_content(
        book_url,
        idx,
        "第1501章",
        &"正文内容".repeat(2000),
        &chapter_url,
    )
    .expect("写缓存");

    let t = std::time::Instant::now();
    let content = legado_ffi::api::reader::get_chapter_content_full(book_url, idx)
        .expect("getChapterContentFull（缓存命中）");
    let t_content_full_hit = t.elapsed();

    // 缓存未命中：走到「书源不存在」报错即止（度量前置 DB 段 + 章节全集查询）
    let miss_url = format!("https://perf-profile.example.com/ch/{}", 2999);
    let t = std::time::Instant::now();
    let miss = legado_ffi::api::reader::fetch_chapter_content(book_url, &miss_url, bogus_origin);
    let t_fetch_miss = t.elapsed();

    eprintln!(
        "[perf] book={} toc={} content_len={} | getBook={t_get_book:?} getChapters={t_get_chapters:?} \
         getChapterContentFull(hit)={t_content_full_hit:?} fetchChapterContent(miss)={t_fetch_miss:?} \
         miss_is_err={}",
        book.name,
        toc.total,
        content.len(),
        miss.is_err()
    );

    assert!(
        t_get_book < std::time::Duration::from_secs(2),
        "getBook > 2s"
    );
    assert!(
        t_get_chapters < std::time::Duration::from_secs(2),
        "getChapters > 2s"
    );
    assert!(
        t_content_full_hit < std::time::Duration::from_secs(2),
        "getChapterContentFull > 2s"
    );
    assert!(
        t_fetch_miss < std::time::Duration::from_secs(2),
        "fetchChapterContent(前置段) > 2s"
    );
}
