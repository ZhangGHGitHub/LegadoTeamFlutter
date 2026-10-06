//! Web 服务停止→立即同端口重启回归（W-1）：
//! `server_stop` 必须等服务器任务真正结束（listener drop、监听端口释放）
//! 后再返回；否则紧随其后的同端口 `server_start` 会在 spawn 前的同步 bind
//! 处报 `AddrInUse`（os error 10048）。
//!
//! 背景：审查报告 `docs/WEB_SERVICE_REACHABILITY_CODE_REVIEW_20261006.md`
//! §W-1（本机 Windows 探针实测：10 轮 stop→立即同端口 start 第 2 轮即
//! `os error 10048`；加 200ms 等待后 10/10 过）。修法对齐同文件
//! `mcp_stop_internal`（Task #76 M1）：abort 后 `block_on(handle)` 等任务
//! 实际结束。本测试先红（旧实现无等待）后绿（等待端口释放）。
//!
//! 本测试运行于独立进程（integration test），使用文件库初始化全局池。

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// stop→立即同端口 start 的连续轮数（对齐审查探针口径的缩减版）
const CYCLES: usize = 5;

/// 建立进程唯一的临时文件库并初始化为全局池；返回库文件路径
fn setup_file_db() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("legado_ffi_stop_release_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("创建临时目录");
    let path = dir.join("stop_release.db");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    let path_str = path.to_str().expect("测试 DB 路径含非 UTF-8 字符");
    legado_ffi::db_state::record_db_path(path_str);
    let db = legado_ffi::legado_db::init_database(path_str).expect("打开临时文件库");
    legado_ffi::db_state::init_database(db).expect("初始化全局连接池");
    path
}

/// 取一个空闲端口（先绑 0.0.0.0:0 再释放；与 Web 服务绑定地址同址族，
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

/// 等待 HTTP 服务就绪（轮询 /api/health；上限 10s）——确保旧任务真正在
/// accept 循环上运行（abort 的异步性由此才可观察）
fn wait_server_ready(addr: SocketAddr) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(resp) = http_get(addr) {
            if resp.starts_with("HTTP/1.1") || resp.starts_with("HTTP/1.0") {
                return;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("Web 服务未在 10s 内就绪（{addr}）");
}

/// 先红后绿判据：stop 返回后**零等待**立即同端口 start，连续 5 轮全部成功
#[test]
fn server_stop_releases_port_for_immediate_same_port_restart() {
    let db_path = setup_file_db();
    let port = pick_free_port();
    let ready_addr = SocketAddr::from(([127, 0, 0, 1], port));

    // 首启（干净起点），确保第 1 轮 stop 时任务已在 accept 循环上
    legado_ffi::api::server_api::server_start(port).expect("首启应成功");
    wait_server_ready(ready_addr);

    for cycle in 1..=CYCLES {
        let stopped = legado_ffi::api::server_api::server_stop();
        assert_eq!(stopped, "Server stopped", "第 {cycle} 轮 stop 返回值异常");

        // 核心判据：stop 返回即端口已释放，同端口 start 必须零等待成功
        match legado_ffi::api::server_api::server_start(port) {
            Ok(msg) => {
                assert!(
                    msg.contains("Server started"),
                    "第 {cycle} 轮 start 返回值异常: {msg}"
                );
            }
            Err(e) => panic!("第 {cycle} 轮 stop→立即同端口 start 失败（端口未随 stop 释放）: {e}"),
        }
        wait_server_ready(ready_addr);
    }

    // 收尾：末轮服务仍在运行
    assert_eq!(legado_ffi::api::server_api::server_stop(), "Server stopped");
    let _ = db_path;
}
