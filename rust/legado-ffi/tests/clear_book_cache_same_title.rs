//! [B-10 回归测试 | 2026-09-28] clear_book_cache 必须复位章级开关键
//!
//! 历史登记（Active 计划·第 1 波视角 B）：「登记不改：B-10（clear_book_cache
//! 不清章级开关键）」。本测试原为 STAGE3-VERIFY 红复现（exit 101，开关键
//! 残留），B-10 修复后收编为正式回归测试（GREEN 基线）。
//!
//! 章级开关在当前实现的落点：caches 表 KV
//! `sameTitleRemoved:{book_url}:{chapter_index}`（reader.rs:69-78 写入，
//! toggle_same_title_removed / is_same_title_removed 消费）。
//!
//! 文档化不变式（reader.rs:71-72）：「缓存清理时开关随之复位为默认，与
//! 原版语义一致」。原版 BookHelp.clearCache(book)（BookHelp.kt:128-131）
//! 删除整书缓存目录，连章级标记状态一并复位；本仓已有实现遵循该不变式的
//! 两个入口：
//! - `clear_cache()`（全清，cache_api.rs:23-34，连带清 caches KV 表）；
//! - `clear_cache_before()`（时段清理，cache_api.rs:226-273，Task #55 F5
//!   显式复位被清理书籍的 sameTitleRemoved 键）。
//!
//! 本测试验证第三个入口 `clear_book_cache(bookUrl)`（cache_api.rs:37-43，
//! 书籍信息页「清缓存」按钮 book_info_screen_builders.part.dart:1866 与
//! 刷新正文成功路径 reader_notifier.dart:594 的后端）是否同样复位章级开关。
//!
//! 判别力保留：修复前主断言 RED（开关键残留，exit 101）；修复后 GREEN。
//! 对照场景（全清复位）恒 GREEN，证明残留为书级入口独有。

use std::sync::{Mutex, MutexGuard, Once};

use legado_ffi::legado_core::models::{Book, BookChapter};
use legado_ffi::legado_db::repository::Repository;
use legado_ffi::legado_db::{BookChapterRepository, BookRepository, CacheRepository};

static TEST_LOCK: Mutex<()> = Mutex::new(());
static ENV_INIT: Once = Once::new();

fn lock_test() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
}

/// 建书 + 1 章 + 1 条内容缓存 + 章级 opt-out 开关
fn setup_book_with_switch(book_url: &str) {
    ENV_INIT.call_once(setup_env);
    let source_url = "http://p3verify-b10.example.com/src";
    legado_ffi::db_state::with_database(|db| {
        let conn = db.connection();
        BookRepository::new(conn).insert(&Book {
            book_url: book_url.to_string(),
            origin: source_url.to_string(),
            ..Book::default()
        })?;
        BookChapterRepository::new(conn).insert_batch(&[BookChapter {
            url: format!("{book_url}/ch/0"),
            title: "第一章".to_string(),
            book_url: book_url.to_string(),
            index: 0,
            ..BookChapter::default()
        }])?;
        Ok(())
    })
    .expect("书行/章节行写入");

    assert!(
        legado_ffi::api::cache_api::save_chapter_content(book_url, 0, "第一章", "旧正文", "")
            .unwrap(),
        "内容缓存行应写入"
    );
    // 章级 opt-out（保留重复标题）→ caches 表写入 "1"
    legado_ffi::api::reader::toggle_same_title_removed(book_url, 0, false).expect("章级开关键写入");
}

fn switch_key(book_url: &str) -> String {
    format!("sameTitleRemoved:{book_url}:0")
}

fn key_exists(key: &str) -> bool {
    legado_ffi::db_state::with_database(|db| {
        CacheRepository::new(db.connection()).contains_key(key)
    })
    .expect("caches KV 查询")
}

/// B-10 回归主断言：clear_book_cache（书级清缓存）后章级开关键必须复位
///
/// 按文档化不变式（reader.rs:71-72「缓存清理时开关随之复位为默认」）与
/// 原版 BookHelp.clearCache(book) 整目录删除语义，书级清缓存应连带复位
/// sameTitleRemoved 键。修复前缺陷形态：键残留 → 重新联网抓取后该章仍按
/// opt-out 处理（不删重复标题），清缓存未还原默认净化行为。
#[test]
fn clear_book_cache_resets_same_title_switch() {
    let _lock = lock_test();
    let book_url = "http://p3verify-b10.example.com/book/main";
    setup_book_with_switch(book_url);

    // 前置：开关与内容缓存均在
    let key = switch_key(book_url);
    assert!(key_exists(&key), "前置：章级开关键应存在");

    // 书级清缓存（书籍信息页「清缓存」按钮的后端入口）
    let deleted = legado_ffi::api::cache_api::clear_book_cache(book_url).expect("clear_book_cache");
    assert!(deleted >= 1, "内容缓存行应被删除，实际删除 {deleted} 行");

    // 断言（缺陷形态为 RED）：章级开关键应随缓存清理复位
    assert!(
        !key_exists(&key),
        "B-10 复现：clear_book_cache 后章级开关键 {key} 残留（违反 reader.rs:71-72 文档化不变式，\
         原版 BookHelp.clearCache(book) 会连同标记文件一并删除）"
    );
}

/// 对照场景：全清入口（clear_cache）复位章级开关键 —— 证明修复前残留
/// 仅为书级入口（clear_book_cache）独有，全清入口实现正确。
#[test]
fn clear_cache_all_resets_same_title_switch() {
    let _lock = lock_test();
    let book_url = "http://p3verify-b10.example.com/book/control";
    setup_book_with_switch(book_url);

    let key = switch_key(book_url);
    assert!(key_exists(&key), "前置：章级开关键应存在");

    legado_ffi::api::cache_api::clear_cache().expect("clear_cache");

    // 对照断言（应为 GREEN）：全清连带清 caches KV 表 → 开关键复位
    assert!(
        !key_exists(&key),
        "对照失败：clear_cache（全清）后章级开关键竟残留——不变式实现被破坏，需复查"
    );
}
