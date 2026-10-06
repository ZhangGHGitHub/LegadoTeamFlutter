//! Web 服务绑定前置（缺陷 B）回归：端口被占用时 `server_start` 必须**同步**
//! 返回 Err，而不是 spawn 后才 bind、把失败吞进任务内 `eprintln!` 并假成功。
//!
//! 背景：调研 `docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md` §一.4
//! （缺陷 B：`server_start` 在 spawn 前返回 Ok，真正 bind 在 spawn 后）。
//! 修法对齐同文件 MCP 路径（`mcp_start_internal` 的 spawn 前 bind、
//! 失败即 `Internal` 可读错误）。
//!
//! 本测试运行于独立进程（integration test），使用文件库初始化全局池。

use std::path::PathBuf;

/// 建立进程唯一的临时文件库并初始化为全局池；返回库文件路径
fn setup_file_db() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("legado_ffi_bind_conflict_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("创建临时目录");
    let path = dir.join("bind_conflict.db");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    let path_str = path.to_str().expect("测试 DB 路径含非 UTF-8 字符");
    legado_ffi::db_state::record_db_path(path_str);
    let db = legado_ffi::legado_db::init_database(path_str).expect("打开临时文件库");
    legado_ffi::db_state::init_database(db).expect("初始化全局连接池");
    path
}

/// 端口被占用（0.0.0.0 同址族）：server_start 必须同步 Err 且不得置运行态
#[test]
fn server_start_reports_bind_conflict_synchronously() {
    let db_path = setup_file_db();

    // 占用 0.0.0.0 端口（与修复后 Web 服务绑定地址同址族）
    let blocker = std::net::TcpListener::bind("0.0.0.0:0").expect("占用测试端口");
    let port = blocker.local_addr().unwrap().port();

    let result = legado_ffi::api::server_api::server_start(port);

    let err = result.expect_err("端口被占用时 server_start 必须同步返回 Err（禁止假成功）");
    assert!(
        matches!(err, legado_ffi::legado_core::LegadoError::Internal(_)),
        "应为 Internal 可读错误: {err:?}"
    );
    let msg = err.to_string();
    assert!(msg.contains("绑定失败"), "错误消息应说明绑定失败: {msg}");
    assert!(msg.contains(&port.to_string()), "错误消息应含端口号: {msg}");

    // 失败不得留下「已启动」态
    let status = legado_ffi::api::server_api::server_status();
    assert!(
        status.contains("\"running\":false"),
        "失败启动不得置运行态: {status}"
    );

    drop(blocker);
    let _ = db_path;
}
