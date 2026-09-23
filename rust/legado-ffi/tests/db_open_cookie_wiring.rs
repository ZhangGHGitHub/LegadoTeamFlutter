//! 提示 2：独立测试二进制 —— `db_open` 的 JS cookie sink 布线端到端验证
//!
//! lib 单测（`src/http_state.rs` 的 `test_js_cookie_sink_db_roundtrip`）与
//! `register_js_cookie_sink` 同在进程内：`COOKIE_SINK` 是 first-wins `OnceLock`，
//! 进程内一旦先行的测试/入口注册过下沉，「`db_open` → 注册 → 回填」这条布线
//! 本身就无法再被覆盖（后注册者静默失败，回填可能已由他人完成）。
//! 本文件是**独立测试二进制**（新进程 = 新 OnceLock），从 FFI 入口驱动全链：
//!
//! ```text
//! ffi::init + ffi::db_open(临时 DB)      ← 内部注册 JsCookieDbSink + 启动全量回填
//!   → cookie_store::set_cookie（JS 写）  ← 下沉 upsert → cookies 表
//!   → rusqlite 直连查 DB 行               ← 验证真落库（不经下沉读路径）
//!   → test_clear_memory_only（清内存）    ← 模拟进程重启
//!   → backfill_from_sink（启动时同一路径） ← DB 行复活进内存
//!   → 读命中
//! ```
//!
//! 双档（默认 / quickjs）均可编译运行：落库行键与直连查询键均取同一
//! `normalized_cookie_key(URL)`（档位无关——写侧 `with_store_update` 的 sink
//! upsert 与查询用同一归一键），断言在两档下都成立。
//!
//! `test_clear_memory_only` 经本 crate `[dev-dependencies]` 的
//! `legado-js = { features = ["test-support"] }` 启用（生产构建不带该面）。

use std::path::Path;

/// 临时 DB 路径（进程号后缀防并发二进制撞名；测试开头先清掉上一次残留）
fn temp_db_path() -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "legado-ffi-db-open-wiring-{}.db",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&p);
    p
}

/// rusqlite 直连读 `cookies` 表行（绕过下沉读路径，验证真实落库内容）
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

#[test]
fn db_open_wires_js_cookie_sink_end_to_end() {
    let db_path = temp_db_path();

    // 1) FFI 入口：db_open 内部依次执行
    //    legacy_db::init_database → db_state::init_database →
    //    http_state::register_js_cookie_sink（下沉 first-wins 注册 + 全量回填）
    legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned())
        .expect("db_open（含 JS cookie 下沉注册 + 启动回填）");

    // 2) JS 侧写 cookie → 下沉 upsert → DB 行
    const URL: &str = "https://wiring.cookie.test/";
    let tag = legado_js::host_api::cookie_store::normalized_cookie_key(URL);
    legado_js::host_api::cookie_store::set_cookie(URL, "wiring", "ok");

    let row = query_cookie_row(&db_path, &tag);
    assert_eq!(
        row.as_deref(),
        Some("wiring=ok"),
        "db_open 后下沉应生效：set_cookie 后 DB 应有该行: {row:?}"
    );

    // 3) 模拟重启：清内存存储（test-only 面，dev-dep test-support feature 启用）
    legado_js::host_api::cookie_store::test_clear_memory_only();
    assert_eq!(
        legado_js::host_api::cookie_store::get_cookie_by_key(URL, "wiring"),
        "",
        "内存清空后读取应 miss"
    );

    // 4) 从下沉回填（与启动时 `register_js_cookie_sink` 同一入口）→ DB 行复活进内存
    legado_js::host_api::cookie_store::backfill_from_sink();
    assert_eq!(
        legado_js::host_api::cookie_store::get_cookie_by_key(URL, "wiring"),
        "ok",
        "回填后 DB 行应回到内存存储"
    );

    // 5) 清理 DB 文件（OnceLock 等进程级状态随进程退出自然释放）
    let _ = std::fs::remove_file(&db_path);
}
