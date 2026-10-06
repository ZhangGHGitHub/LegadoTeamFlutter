//! Web 服务绑定地址回归（缺陷 A）：必须监听 `0.0.0.0`（全接口），
//! 局域网设备（PC 浏览器）才能访问 `http://<设备IP>:1122`。
//!
//! 背景：调研 `docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md` §一.3
//! （缺陷 A：旧实现硬编码 `127.0.0.1`，仅回环可达）。原版 `HttpServer.kt`
//! `NanoHTTPD(port)`（hostname=null → 绑全接口），本项目 MCP 路径亦为
//! `0.0.0.0`（F5）——本路径是偏差。
//!
//! 判据：服务启动后从**本机非回环 IPv4**（同一网卡地址）连入必须成功；
//! 仅绑回环时该连接必被拒（红）。
//!
//! 本测试运行于独立进程（integration test），使用文件库初始化全局池。

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream, UdpSocket};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// 建立进程唯一的临时文件库并初始化为全局池；返回库文件路径
fn setup_file_db() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("legado_ffi_bind_all_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("创建临时目录");
    let path = dir.join("bind_all.db");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    let path_str = path.to_str().expect("测试 DB 路径含非 UTF-8 字符");
    legado_ffi::db_state::record_db_path(path_str);
    let db = legado_ffi::legado_db::init_database(path_str).expect("打开临时文件库");
    legado_ffi::db_state::init_database(db).expect("初始化全局连接池");
    path
}

/// 取本机默认出口的非回环 IPv4。
///
/// UDP `connect` 只触发内核路由选择、不实际发包（目标用 TEST-NET-1
/// 保留地址 192.0.2.1）；无路由/无网卡时返回 None（测试降级为回环冒烟）。
fn local_non_loopback_ipv4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:80").ok()?;
    match socket.local_addr().ok()? {
        SocketAddr::V4(v4) if !v4.ip().is_loopback() && !v4.ip().is_unspecified() => Some(*v4.ip()),
        _ => None,
    }
}

/// 取一个空闲端口（先绑 0.0.0.0:0 再释放；与修复后绑定地址同址族，
/// 随机端口策略避免 CI 冲突）
fn pick_free_port() -> u16 {
    let listener = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

/// 极简 HTTP/1.1 GET 冒烟：连接 + 发请求 + 读首段，返回原始响应文本
fn http_get(addr: SocketAddr) -> Option<String> {
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    stream
        .write_all(b"GET /api/health HTTP/1.1\r\nHost: probe\r\nConnection: close\r\n\r\n")
        .ok()?;
    let mut buf = [0u8; 1024];
    let n = stream.read(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf[..n]).into_owned())
}

/// 等待 HTTP 服务就绪（轮询 /api/health；上限 10s）
fn wait_server_ready(addr: SocketAddr) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(resp) = http_get(addr) {
            if resp.starts_with("HTTP/1.1") || resp.starts_with("HTTP/1.0") {
                return resp;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("Web 服务未在 10s 内就绪（{addr}）");
}

/// 非回环地址（局域网语义）可达性：仅绑 127.0.0.1 时必红
#[test]
fn server_start_listens_on_all_interfaces() {
    let db_path = setup_file_db();

    let port = pick_free_port();
    legado_ffi::api::server_api::server_start(port).expect("初始化后启动 Web 服务应成功");

    // 回环冒烟：0.0.0.0 包含回环，先证明服务活着
    let loopback = SocketAddr::from(([127, 0, 0, 1], port));
    wait_server_ready(loopback);

    match local_non_loopback_ipv4() {
        Some(ip) => {
            let lan_addr = SocketAddr::from((ip, port));
            let resp = http_get(lan_addr).unwrap_or_else(|| {
                panic!("Web 服务应监听 0.0.0.0（全接口），但经本机非回环地址 {lan_addr} 连接失败")
            });
            assert!(
                resp.starts_with("HTTP/1.1") || resp.starts_with("HTTP/1.0"),
                "经非回环地址 {lan_addr} 应收到 HTTP 响应，实际: {resp}"
            );
        }
        None => {
            eprintln!("未发现非回环 IPv4（无网络路由），本轮降级为回环冒烟");
        }
    }

    let _ = legado_ffi::api::server_api::server_stop();
    let _ = db_path;
}
