//! [STAGE3-C2B | 2026-09-28] 刷新正文强制联网重取（对齐上游原版，用户已裁决）Rust 层语义验收
//!
//! 由 `.tmp/p3verify_c2.rs.hold` 红测试保管物恢复并改写：原 C2 核验证实了缺陷形态
//! （已缓存章经缓存优先 fetch 返回旧缓存、刷新不生效；且 Dart 成功路径
//! clearBookCache 误清整书离线缓存）。用户裁决对齐上游原版后：
//! ① 新增 FFI `clear_chapter_cache` ≡ 上游 `BookHelp.delContent`——仅删
//!   单条 cached_chapters 行（book_url, chapter_index），不触碰章级开关键；
//! ② Dart `refreshChapterContent` 重排为「先失效当前章 → 再抓取」
//!   （对齐上游 `refreshContentDur` = delContent → loadContent）；
//! ③ 失败语义对齐上游：仅当前章缓存行被删，同书他章缓存原样保留。
//!
//! 注意（用户裁决后语义）：「失败保留旧缓存持久层」不再保留——失败时当前章
//! 缓存行已在「先失效」步骤删除（UI 仍显示旧内容与失败原因，但当前章
//! 持久层缓存丢失），与上游 loadContent 失败时该章缓存文件已删一致。
//!
//! mock：回环服务器 /ch/stale 返回新版正文（200）、/ch/fail 返回 500。
//!
//! 预期：三条测试全部 GREEN
//! （A 失败仅丢当前章 / B 已缓存章刷新必发网络请求 / C 单章粒度对照）。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex, MutexGuard, Once};

use legado_ffi::legado_core::models::{Book, BookChapter};
use legado_ffi::legado_db::repository::Repository;
use legado_ffi::legado_db::{BookChapterRepository, BookRepository, CacheBookRepository};

static TEST_LOCK: Mutex<()> = Mutex::new(());
static ENV_INIT: Once = Once::new();

fn lock_test() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
    std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
    legado_ffi::http_state::reset_shared_client();
}

type Hits = Arc<Mutex<HashMap<String, u32>>>;

fn spawn_content_server() -> (u16, Hits) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环 mock 服务器");
    let port = listener.local_addr().expect("取端口").port();
    let hits: Hits = Arc::new(Mutex::new(HashMap::new()));
    let listener = Arc::new(listener);
    let conn_hits = Arc::clone(&hits);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let hits = Arc::clone(&conn_hits);
            std::thread::spawn(move || handle_conn(&mut s, &hits));
        }
    });
    (port, hits)
}

fn handle_conn(stream: &mut std::net::TcpStream, hits: &Hits) {
    let mut buf = Vec::new();
    let mut one = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut one) {
            Ok(1) => buf.push(one[0]),
            _ => return,
        }
        if buf.len() > 16 * 1024 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let path = head
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .split('?')
        .next()
        .unwrap_or("/")
        .to_string();

    let (status, body) = match path.as_str() {
        // 站点已更新的新版正文（证明刷新取到的是网络新内容而非旧缓存）
        "/ch/stale" => (
            200,
            "<html><body><div class=\"content\">新版正文B</div></body></html>".to_string(),
        ),
        // 注入抓取失败
        "/ch/fail" => (500, "injected failure".to_string()),
        _ => (404, "not found".to_string()),
    };
    {
        let mut h = hits.lock().unwrap();
        *h.entry(path).or_insert(0) += 1;
    }
    let reason = if status < 400 {
        "OK"
    } else {
        "Internal Server Error"
    };
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

/// 建书源 + 书 + 2 章节行（idx0=/ch/stale，idx1=/ch/fail）
///
/// `scenario`：场景唯一后缀——同进程内多个场景共享全局内存 DB，book_url
/// 必须跨场景唯一（端口 + 场景名双保险），避免 PageBodyCache/DB 残留串扰。
fn setup_book(port: u16, scenario: &str) -> (String, String, String, String) {
    let source_url = format!("http://127.0.0.1:{port}/src/{scenario}");
    let book_url = format!("http://127.0.0.1:{port}/book/{scenario}");
    let source_json = format!(
        r#"{{"bookSourceUrl":"{source_url}","bookSourceName":"C2B 缓存核验源","ruleContent":{{"content":"class.content@text"}}}}"#
    );
    legado_ffi::api::source::add_source(&source_json).expect("夹具书源写入");

    let book = Book {
        book_url: book_url.clone(),
        origin: source_url.clone(),
        // 场景唯一书名：BookRepository::insert 对「同名同作者」冲突走
        // remap_book_url_preserving_chapters（迁移 cached_chapters 到新
        // bookUrl 的设计行为），共享内存库多场景必须避免 name/author 相撞
        name: format!("C2B 缓存核验-{scenario}"),
        author: format!("C2B-{scenario}"),
        ..Book::default()
    };
    legado_ffi::db_state::with_database(|db| {
        BookRepository::new(db.connection()).insert(&book)?;
        BookChapterRepository::new(db.connection()).insert_batch(&[
            BookChapter {
                url: format!("http://127.0.0.1:{port}/ch/stale?s={scenario}"),
                title: "第一章".to_string(),
                book_url: book_url.clone(),
                index: 0,
                ..BookChapter::default()
            },
            BookChapter {
                url: format!("http://127.0.0.1:{port}/ch/fail?s={scenario}"),
                title: "第二章".to_string(),
                book_url: book_url.clone(),
                index: 1,
                ..BookChapter::default()
            },
        ])?;
        Ok(())
    })
    .expect("书行/章节行写入");
    let base = format!("http://127.0.0.1:{port}");
    let stale_url = format!("{base}/ch/stale?s={scenario}");
    let fail_url = format!("{base}/ch/fail?s={scenario}");
    (source_url, book_url, stale_url, fail_url)
}

fn cached_content(book_url: &str, chapter_index: i32) -> Option<String> {
    legado_ffi::db_state::with_database(|db| {
        let rows = CacheBookRepository::new(db.connection()).get_by_book(book_url)?;
        Ok(rows
            .into_iter()
            .find(|c| c.chapter_index == chapter_index)
            .map(|c| c.content))
    })
    .expect("cached_chapters 查询")
}

fn dump_all_cache_rows(tag: &str) {
    legado_ffi::db_state::with_database(|db| {
        let mut stmt = db
            .connection()
            .prepare("SELECT book_url, chapter_index, chapter_url, content FROM cached_chapters")
            .map_err(|e| legado_ffi::legado_core::LegadoError::Database(format!("{e}")))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i32>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| legado_ffi::legado_core::LegadoError::Database(format!("{e}")))?;
        let all: Vec<_> = rows.filter_map(|r| r.ok()).collect();
        eprintln!("[refresh-chapter-cache][{tag}] cached_chapters 全表 {all:?}");
        Ok(())
    })
    .ok();
}

/// 测试 A（修复后验收，预期 GREEN）：抓取失败仅丢当前章缓存
///
/// 新编排（先失效再抓取）：① clear_chapter_cache 只删目标章行；
/// ② fetch 500 注入 → Err，失败不写任何缓存行；③ 同书他章缓存原样保留
/// （无整书清理），对齐上游 refreshContentDur 失败语义。
#[test]
fn c2a_failed_fetch_only_loses_current_chapter_cache() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);
    let (port, _hits) = spawn_content_server();
    let (source_url, book_url, stale_url, fail_url) = setup_book(port, "c2a");

    // 预置：两章旧缓存（idx0 = 他章，idx1 = 刷新目标章）
    assert!(
        legado_ffi::api::cache_api::save_chapter_content(
            &book_url,
            0,
            "第一章",
            "旧缓存第一章正文",
            &stale_url
        )
        .unwrap(),
        "预置 idx0 缓存应写入"
    );
    assert!(
        legado_ffi::api::cache_api::save_chapter_content(
            &book_url,
            1,
            "第二章",
            "旧缓存第二章正文",
            &fail_url
        )
        .unwrap(),
        "预置 idx1 缓存应写入"
    );

    // 新编排步骤 1：失效目标章（idx1，对齐上游 delContent：只删本章）
    let deleted =
        legado_ffi::api::cache_api::clear_chapter_cache(&book_url, 1).expect("clear_chapter_cache");
    assert_eq!(deleted, 1, "目标章缓存行应删除 1 行");

    // 新编排步骤 2：抓取 → 注入 500 → 必须 Err
    let err = legado_ffi::api::reader::fetch_chapter_content(&book_url, &fail_url, &source_url)
        .expect_err("500 注入下抓取应失败");
    eprintln!("[refresh-chapter-cache] 失败路径错误：{err}");

    // 失败仅丢当前章缓存：
    // - idx1（目标章）：步骤 ① 已删，失败不回填 → 不存在
    assert!(
        cached_content(&book_url, 1).is_none(),
        "目标章缓存行应不存在（先失效已删；失败不得回填新行）"
    );
    // - idx0（同书他章）：原样保留（无整书清理）
    assert_eq!(
        cached_content(&book_url, 0).as_deref(),
        Some("旧缓存第一章正文"),
        "失败仅丢当前章缓存，同书他章缓存必须原样保留"
    );
    dump_all_cache_rows("c2a-结束");
}

/// 测试 B（修复后验收，预期 GREEN）：已缓存章刷新必发网络请求
///
/// 新编排：clear_chapter_cache（删当前章缓存行）→ fetch_chapter_content
/// （缓存已空 → 强制联网）→ 成功持久化新内容（fetch 自动写缓存行）。
#[test]
fn c2b_cached_chapter_refresh_forces_network_after_clear() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);
    let (port, hits) = spawn_content_server();
    let (source_url, book_url, stale_url, _fail_url) = setup_book(port, "c2b");

    // 预置：当前章旧缓存（阅读即缓存语义下，用户点「刷新正文」时本章必然已有缓存）
    assert!(
        legado_ffi::api::cache_api::save_chapter_content(
            &book_url,
            0,
            "第一章",
            "旧版正文A",
            &stale_url
        )
        .unwrap(),
        "预置缓存应写入"
    );
    assert_eq!(
        cached_content(&book_url, 0).as_deref(),
        Some("旧版正文A"),
        "预置缓存应可读回"
    );

    // 新编排步骤 1：失效当前章（对齐上游 delContent：只删本章）
    let deleted =
        legado_ffi::api::cache_api::clear_chapter_cache(&book_url, 0).expect("clear_chapter_cache");
    assert_eq!(deleted, 1, "当前章缓存行应删除 1 行");
    assert!(
        cached_content(&book_url, 0).is_none(),
        "失效后当前章缓存行应不存在"
    );

    // 新编排步骤 2：抓取（缓存已空 → 强制联网）
    let content =
        legado_ffi::api::reader::fetch_chapter_content(&book_url, &stale_url, &source_url)
            .expect("fetch_chapter_content 应成功返回");

    let stale_hits = {
        let h = hits.lock().unwrap();
        h.get("/ch/stale").copied().unwrap_or(0)
    };
    eprintln!("[refresh-chapter-cache] 返回内容={content:?} 网络请求次数={stale_hits}");

    // 断言（修复后全绿）：
    // ① 取到站点新版正文（而非旧缓存）
    assert_eq!(
        content, "新版正文B",
        "刷新必须取到站点新版正文，不得返回旧缓存"
    );
    // ② 必向站点发起网络请求（证明失效生效，缓存优先不再拦截）
    assert!(
        stale_hits >= 1,
        "刷新必发至少 1 次网络请求（实际 {stale_hits} 次：缓存优先命中时为 0）"
    );
    // ③ 成功后持久化新内容（fetch 自动写缓存行）
    assert_eq!(
        cached_content(&book_url, 0).as_deref(),
        Some("新版正文B"),
        "刷新成功后新内容应持久化"
    );
    dump_all_cache_rows("c2b-结束");
}

/// 对照测试（单章粒度核实，预期 GREEN）：成功抓取只写当前章一行；
/// clear_chapter_cache 只删当前章行——他章缓存原样保留（整书清理是
/// clear_book_cache 的显式清缓存 UI 语义，刷新路径不再使用）
#[test]
fn c2c_success_writes_single_row_and_clear_chapter_is_single_grain() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);
    let (port, _hits) = spawn_content_server();
    let (source_url, book_url, stale_url, fail_url) = setup_book(port, "c2c");

    // 另一章预置旧缓存（模拟「其余章节的旧内容」）
    assert!(
        legado_ffi::api::cache_api::save_chapter_content(
            &book_url,
            1,
            "第二章",
            "旧缓存第二章正文",
            &fail_url
        )
        .unwrap(),
        "预置 idx1 缓存应写入"
    );

    // 成功抓取当前章（idx0 无预置缓存 → 走网络 → 写 1 行）
    dump_all_cache_rows("c2c-fetch前");
    let content =
        legado_ffi::api::reader::fetch_chapter_content(&book_url, &stale_url, &source_url)
            .expect("成功抓取");
    assert_eq!(content, "新版正文B", "未缓存章应取到站点正文");
    assert_eq!(
        cached_content(&book_url, 0).as_deref(),
        Some("新版正文B"),
        "成功抓取后当前章缓存行应写入"
    );

    // 新 FFI：clear_chapter_cache 只删当前章行（非整书）
    let deleted =
        legado_ffi::api::cache_api::clear_chapter_cache(&book_url, 0).expect("clear_chapter_cache");
    assert_eq!(deleted, 1, "单章失效应删 1 行（当前章）");
    assert!(
        cached_content(&book_url, 0).is_none(),
        "当前章缓存行应被删除"
    );
    assert_eq!(
        cached_content(&book_url, 1).as_deref(),
        Some("旧缓存第二章正文"),
        "单章失效不得误伤他章缓存（粒度对照：区别于 clear_book_cache 整书语义）"
    );
}
