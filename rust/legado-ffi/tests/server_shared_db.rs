//! §二.8 双 DB 修复（P1+P2）回归：Web 服务的写路径必须落 `db_state` 当前库，
//! 且与主应用（ffi 数据面）双向可见。
//!
//! 背景（审计 `docs/S28_DUAL_DB_AUDIT_20261004.md` §五修法 A/B）：
//! 旧实现 Web 路径硬编码相对路径 `"legado.db"`（`server_api.rs:114`），
//! Android 上会打开 cwd 下的第二个空库 / 打不开——Web 书架读空、用户
//! 写入落分裂库。修复后 server 使用 `db_state` 当前 DB（P2 后为同一全局
//! 连接池），本测试断言：
//! 1. HTTP 写入 → ffi `with_database` 立即可读（同一库）；
//! 2. ffi 写入 → HTTP GET 可见（同一数据面）。
//!
//! 本测试运行于独立进程（integration test），使用**文件库**（非 `:memory:`）：
//! P2 后 server 会长期持有共享池的一条连接，`:memory:` 池容量 1 会饿死主侧。

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// 测试 server 生命周期守卫：无论断言是否 panic，退出前尽力停止服务
struct ServerGuard;

impl Drop for ServerGuard {
    fn drop(&mut self) {
        let _ = legado_ffi::api::server_api::server_stop();
    }
}

/// 取一个空闲端口（先绑 :0 再释放，随机端口策略避免 CI 冲突）
fn pick_free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

/// 极简 HTTP/1.1 客户端（测试专用）：按 Content-Length 截断完整响应，
/// 不依赖对端主动关闭连接。
fn http_request(addr: &str, method: &str, path: &str, json_body: Option<&str>) -> String {
    let mut stream = TcpStream::connect(addr).expect("连接测试 server 失败");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("设置读超时");

    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n");
    if let Some(body) = json_body {
        req.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    req.push_str("\r\n");
    if let Some(body) = json_body {
        req.push_str(body);
    }
    stream.write_all(req.as_bytes()).expect("发送请求");

    let mut resp = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            // 超时/对端关闭：返回已读内容（断言处会给出可读失败信息）
            Err(_) => break,
        };
        resp.extend_from_slice(&buf[..n]);
        if let Some(header_end) = resp.windows(4).position(|w| w == b"\r\n\r\n".as_slice()) {
            let headers = String::from_utf8_lossy(&resp[..header_end]).to_lowercase();
            let body_start = header_end + 4;
            let content_length = headers
                .lines()
                .find_map(|l| l.strip_prefix("content-length:"))
                .and_then(|v| v.trim().parse::<usize>().ok());
            if let Some(len) = content_length {
                if resp.len() >= body_start + len {
                    break;
                }
            }
        }
    }
    String::from_utf8_lossy(&resp).into_owned()
}

/// 等待 HTTP 服务就绪（spawn 后监听器异步绑定，轮询 TCP 连接；上限 10s）
fn wait_server_ready(port: u16) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("Web 服务未在 10s 内就绪（端口 {port}）");
}

/// 建立进程唯一的临时文件库并初始化为全局池；返回库文件路径
fn setup_file_db() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("legado_ffi_server_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("创建临时目录");
    let path = dir.join("server_shared.db");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    let path_str = path.to_str().expect("测试 DB 路径含非 UTF-8 字符");
    legado_ffi::db_state::record_db_path(path_str);
    let db = legado_ffi::legado_db::init_database(path_str).expect("打开临时文件库");
    legado_ffi::db_state::init_database(db).expect("初始化全局连接池");
    path
}

/// server 写入 → ffi 可读；ffi 写入 → server 可读（同一库 / P2 后同一池）
#[test]
fn server_and_ffi_share_same_database() {
    let db_path = setup_file_db();
    let _guard = ServerGuard;

    let port = pick_free_port();
    legado_ffi::api::server_api::server_start(port).expect("初始化后启动 Web 服务应成功");
    wait_server_ready(port);

    // 1) HTTP 写入（POST /api/books）→ ffi 侧立即可读
    let body = r#"{"book_url":"https://example.com/s28-http-write","name":"单池验证","author":"测试"}"#;
    let resp = http_request(&format!("127.0.0.1:{port}"), "POST", "/api/books", Some(body));
    assert!(
        resp.starts_with("HTTP/1.1 201") || resp.starts_with("HTTP/1.0 201"),
        "POST /api/books 应返回 201，实际响应: {}",
        &resp[..resp.len().min(200)]
    );

    let count = legado_ffi::db_state::with_database(|db| {
        let n: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM books WHERE bookUrl = ?1",
                ["https://example.com/s28-http-write"],
                |row| row.get(0),
            )
            .map_err(|e| {
                legado_ffi::legado_core::LegadoError::Database(format!("查询失败: {e}"))
            })?;
        Ok(n)
    })
    .expect("ffi 侧读库失败");
    assert_eq!(
        count, 1,
        "HTTP 写入必须落在 db_state 当前库（{}）——不得是 cwd 下的分裂库",
        db_path.display()
    );

    // 2) ffi 写入 → HTTP GET 可见（双向同一数据面）
    legado_ffi::db_state::with_database(|db| {
        db.connection()
            .execute(
                "INSERT INTO books (bookUrl, tocUrl, origin, originName, name, author) \
                 VALUES (?1, '', 'ffi', 'ffi', '反向书', 'x')",
                ["https://example.com/s28-ffi-write"],
            )
            .map_err(|e| {
                legado_ffi::legado_core::LegadoError::Database(format!("插入失败: {e}"))
            })?;
        Ok(())
    })
    .expect("ffi 侧写入失败");

    let resp = http_request(&format!("127.0.0.1:{port}"), "GET", "/api/books", None);
    assert!(
        resp.contains("s28-ffi-write"),
        "server 应读到 ffi 侧写入（同一数据面），实际响应: {}",
        &resp[..resp.len().min(400)]
    );

    let _ = legado_ffi::api::server_api::server_stop();
}
