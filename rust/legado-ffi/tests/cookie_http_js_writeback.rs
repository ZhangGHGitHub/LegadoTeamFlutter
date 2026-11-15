//! P1-1 回归：HTTP → JS 罐写穿不得用「整域全量视图」覆盖 JS 罐的新值
//!
//! 审查缺陷（基线 `4deb9e2e68`）：`AppCookieJar::set_cookies` 把
//! `persist_cookie_pairs` 返回的**该域全量视图**同时交给
//! `CookiePersistence::save` 与 `CookieWriteObserver`。而 App 罐与 JS 罐
//! 仍是两个存储（`java.setCookie` 只写 JS 罐 + DB，不回写 App 罐，P2-3
//! 另批处理），于是 App 罐里的同名旧值会经写穿反向镜像进 JS 罐：
//!
//! ```text
//! DB/App 罐 sid=OLD → java.setCookie(sid=JS_NEW)（JS 罐/DB 更新）
//!   → 任一普通响应带 Set-Cookie: track=1
//!   → 写穿把整域视图 "sid=OLD; track=1" 灌回 JS 罐/DB
//!   → java.getCookie('sid') 回到 OLD（登录态在进程内被打回）
//! ```
//!
//! 修复后落库与写穿只传「本次响应解析出的 pairs」，App 罐旧键不再外传。
//!
//! 本文件是**独立测试二进制**：`COOKIE_SINK` / `COOKIE_WRITE_OBSERVER` /
//! 全局 DB 均为进程级 first-wins 状态，独立进程保证布线不被其它测试
//! 抢先注册（同 `db_open_cookie_wiring.rs` 的隔离理由）。
//!
//! 运行：`cargo test -p legado-ffi --features quickjs --test cookie_http_js_writeback`

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use legado_ffi::http_state::DbCookiePersistence;
use legado_net::{CookiePersistence, LegadoClient, LegadoClientConfig, COOKIE_JAR_HEADER};

/// 临时 DB 路径（进程号后缀防并发二进制撞名；开头先清残留）
fn temp_db_path() -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "legado-ffi-cookie-http-js-writeback-{}.db",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&p);
    p
}

/// 直连 DB 读 `cookies` 行（绕过下沉读路径，验证真实落库内容）
fn query_cookie_row(db_path: &Path, tag: &str) -> Option<String> {
    use rusqlite::OptionalExtension;
    let conn = rusqlite::Connection::open(db_path).expect("rusqlite 直连临时 DB");
    conn.query_row(
        "SELECT cookie FROM cookies WHERE url = ?1",
        rusqlite::params![tag],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .expect("查询 cookies 表")
}

/// `name=value; ...` 解析为 map（断言顺序无关）
fn cookie_map(raw: &str) -> std::collections::HashMap<String, String> {
    raw.split(';')
        .filter_map(|part| {
            let part = part.trim();
            if part.is_empty() {
                return None;
            }
            part.split_once('=')
                .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        })
        .collect()
}

/// 最小回环 HTTP 服务器：对首个请求返回 200 + `Set-Cookie: track=1`，
/// 随后关闭并退出线程
///
/// 读请求头至 `\r\n\r\n` 后写响应（`Connection: close`）。本用例只需一条
/// 连接；单次 accept 让线程必然结束，避免测试阻塞在 `join()`。
fn spawn_set_cookie_server() -> (u16, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let port = listener.local_addr().expect("local_addr").port();
    let handle = std::thread::spawn(move || {
        let Ok((mut sock, _)) = listener.accept() else {
            return;
        };
        let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
        let mut buf = [0u8; 1024];
        let mut req = Vec::new();
        loop {
            match sock.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    req.extend_from_slice(&buf[..n]);
                    if req.windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\
                    Set-Cookie: track=1; Path=/\r\n\
                    Content-Length: 2\r\nConnection: close\r\n\r\nok";
        let _ = sock.write_all(resp.as_bytes());
    });
    (port, handle)
}

/// P1-1 回归：HTTP 写穿只覆盖本次响应的键，不得回滚 JS 罐/DB 中较新的同名值
#[tokio::test]
async fn http_write_through_must_not_rollback_newer_js_cookie() {
    use legado_js::host_api::cookie_store;
    use legado_js::{JsEngine, QuickJsEngine, SandboxConfig};

    let db_path = temp_db_path();

    // 1) 生产布线：db_open 注册 JS cookie 下沉（DB 合并 upsert）与
    //    HTTP→JS 罐写穿观察者（quickjs 档）
    legado_ffi::ffi::ffi::init().expect("ffi init");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned()).expect("db_open");

    // 与书源引擎同形的 QuickJS 实例：`java.setCookie` / `java.getCookie`
    // 走真实 JS 绑定（非直接调 host_api，复现审查路径）
    let engine = QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("QuickJS 引擎创建失败");

    let (port, server) = spawn_set_cookie_server();
    let url = format!("http://127.0.0.1:{port}/probe");

    // 2) 预置 App 罐来源：DB 行 sid=OLD（客户端构建时载入内存罐）
    let domain_key = "127.0.0.1";
    DbCookiePersistence.save(domain_key, "sid=OLD");
    let client = LegadoClient::with_cookie_persistence(
        LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        },
        Arc::new(DbCookiePersistence),
    )
    .expect("构建带 DB 持久化的客户端");
    {
        let store = client.cookie_store().read().unwrap();
        assert_eq!(
            store.get_key(domain_key, "sid"),
            Some("OLD".to_string()),
            "前置条件：App 罐必须已载入 DB 的旧会话"
        );
    }

    // 3) 书源 JS 登录：`java.setCookie` 只写 JS 罐 + DB（P2-3 已知：
    //    不回写 App 罐）
    engine
        .eval(&format!("java.setCookie('{url}', 'sid=JS_NEW')"))
        .expect("java.setCookie eval 失败");
    assert_eq!(
        engine
            .eval(&format!("java.getCookie('{url}', 'sid')"))
            .expect("java.getCookie eval 失败"),
        "JS_NEW",
        "前置条件：JS 罐应已写入新会话"
    );
    assert_eq!(
        cookie_map(&query_cookie_row(&db_path, domain_key).expect("JS 写后 DB 行必须存在"))
            .get("sid"),
        Some(&"JS_NEW".to_string()),
        "前置条件：DB 行应已由 JS 下沉更新为新会话"
    );

    // 4) 任一普通响应带无关 Set-Cookie（写侧门控开启 → 触发写穿）
    let mut headers = std::collections::HashMap::new();
    headers.insert(COOKIE_JAR_HEADER.to_string(), "1".to_string());
    let resp = client
        .get(&url, Some(headers))
        .await
        .expect("回环请求应成功");
    assert_eq!(resp.status, 200);
    server.join().expect("回环服务器线程正常退出");

    // 5) 回归断言：JS 罐新值必须保持；DB 行不得被 App 罐旧值回滚
    let js_sid = engine
        .eval(&format!("java.getCookie('{url}', 'sid')"))
        .expect("java.getCookie eval 失败");
    let row = query_cookie_row(&db_path, domain_key).expect("写穿后 DB 行必须存在");
    let db_sid = cookie_map(&row).get("sid").cloned();
    assert_eq!(
        js_sid, "JS_NEW",
        "HTTP 写穿不得用 App 罐整域视图覆盖 JS 罐新值（修复前此处为 OLD；DB sid={db_sid:?}）"
    );
    assert_eq!(
        engine
            .eval(&format!("java.getCookie('{url}', 'track')"))
            .expect("java.getCookie eval 失败"),
        "1",
        "本次响应的新键仍必须写穿到 JS 罐"
    );
    assert_eq!(
        db_sid,
        Some("JS_NEW".to_string()),
        "DB 行不得被 App 罐旧值回滚（修复前此处为 OLD）: {row:?}"
    );
    assert_eq!(
        cookie_map(&row).get("track"),
        Some(&"1".to_string()),
        "DB 行应含本次新键: {row:?}"
    );

    // 6) 清理进程级内存态（DB 文件随进程退出释放；Windows 下删除可能失败，忽略）
    cookie_store::clear_cookies(&url);
    let _ = std::fs::remove_file(&db_path);
}
