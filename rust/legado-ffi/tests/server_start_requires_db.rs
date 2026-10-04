//! §二.8 双 DB 修复（P1）回归：DB 未初始化时启动 Web 服务必须**同步**返回 Err。
//!
//! 背景（审计 `docs/S28_DUAL_DB_AUDIT_20261004.md` §五修法 A）：
//! 旧实现 `server_api::server_start` 在 spawn 前即返回 Ok
//! （「Server started on port ...」），数据库打开失败只在任务内
//! `eprintln!`——Android 上 DB 打不开时用户看到「已启动」而进程已死，
//! 属「假成功」。修复后：DB 未初始化 / 路径未记录 → 同步 Err。
//!
//! 本测试必须运行在**独立进程**（integration test）：序列化到本进程，
//! 全局池从未被 `db_state::init_database` 初始化。

/// 取一个空闲端口（先绑 :0 再释放，随机端口策略避免 CI 冲突）
fn pick_free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

/// DB 未初始化（未调用 db_open）时：server_start 必须返回 Err，且不得进入运行态
#[test]
fn server_start_without_db_open_returns_err() {
    assert!(
        !legado_ffi::db_state::is_initialized(),
        "本测试进程不得预先初始化 DB（integration test 独立进程前提）"
    );

    let port = pick_free_port();
    let result = legado_ffi::api::server_api::server_start(port);

    let err = result.expect_err("DB 未初始化时 server_start 必须返回 Err（禁止假成功）");
    assert!(
        matches!(err, legado_ffi::legado_core::LegadoError::Internal(_)),
        "应为 Internal 可读错误: {err:?}"
    );
    let msg = err.to_string();
    assert!(msg.contains("未初始化"), "错误消息应说明 DB 未初始化: {msg}");
    assert!(
        msg.contains("db_open"),
        "错误消息应提示先调用 db_open: {msg}"
    );

    // 防御性清理 + 状态断言：绝不能留下「已启动」态
    let _ = legado_ffi::api::server_api::server_stop();
    let status = legado_ffi::api::server_api::server_status();
    assert!(
        status.contains("\"running\":false"),
        "失败启动不得置运行态: {status}"
    );
}
