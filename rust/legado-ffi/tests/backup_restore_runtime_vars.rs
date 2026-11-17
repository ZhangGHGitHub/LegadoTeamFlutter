//! P1-3 / P2-2 / P2-6（批10 审查）端到端回归：备份恢复后运行时变量立即生效
//!
//! 独立测试二进制（新进程 = 新 `OnceLock`），从 FFI 入口驱动真实 DB 下沉：
//!
//! ```text
//! ffi::init + ffi::db_open(临时 DB)      ← 注册 JsVariableDbSink + 启动回填
//!   → 写旧登录头/旧变量（内存 + DB）
//!   → ffi::backup_restore(zip 含 runtimeSourceCache.json 新值)
//!        └ 恢复体写 caches 新行 → clear_source_variables()（清内存）
//!        └ 恢复入口钩子 reload_runtime_variables_after_restore()
//!   → **不重启**立即读：新值可见、旧值消失
//! ```
//!
//! 用例分组（同进程共享 DB，进程级锁串行防串表）：
//! - `restore_makes_new_runtime_variables_visible_immediately`（P1-3 方案 1+2）
//! - `lazy_reload_after_memory_clear_without_restore_hook`（P1-3 方案 2 独立验证）
//! - `remove_login_header_deletes_db_row_without_memory_hit`（P2-2）
//! - `delete_source_clears_five_family_cache_rows`（P2-6，书源 + RSS 源）

use std::io::Write as _;
use std::sync::{Mutex, MutexGuard, OnceLock};

use legado_db::repository::Repository;
use legado_db::CacheRepository;
use legado_ffi::api::{source, source_login_cache};
use legado_ffi::db_state::with_database;

/// 进程级串行锁：本文件各用例共享同一临时 DB 与全局变量表
fn serial() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

/// 临时 DB 路径（进程号后缀防并发二进制撞名）
fn temp_db_path() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("legado-ffi-runtime-vars-{}.db", std::process::id()))
}

/// 首次调用完成 ffi init + db_open（幂等：db_open 内部已初始化时早退）
fn ensure_db() -> std::path::PathBuf {
    let path = temp_db_path();
    static INIT: OnceLock<()> = OnceLock::new();
    INIT.get_or_init(|| {
        legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
        legado_ffi::ffi::ffi::db_open(path.to_string_lossy().into_owned())
            .expect("db_open（含 JS 变量下沉注册 + 启动回填）");
    });
    path
}

/// 构造原版 zip 备份（仅写运行时变量段）
fn write_runtime_backup(dir_name: &str, runtime_json: &str) -> (std::path::PathBuf, String) {
    let dir = std::env::temp_dir().join(dir_name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("建临时目录");
    let zip_path = dir.join("backup.zip");
    {
        let file = std::fs::File::create(&zip_path).expect("建 zip 文件");
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        writer
            .start_file("runtimeSourceCache.json", options)
            .expect("开始条目");
        writer
            .write_all(runtime_json.as_bytes())
            .expect("写运行时变量段");
        writer.finish().expect("完成 zip");
    }
    let path = zip_path.to_str().expect("路径 UTF-8").to_string();
    (dir, path)
}

/// DB 中该键的原始值（绕过内存层）
fn db_row(key: &str) -> Option<String> {
    with_database(|db| CacheRepository::new(db.connection()).get(key)).expect("查 caches")
}

fn runtime_cache_json(entries: &[(&str, &str)]) -> String {
    let list: Vec<serde_json::Value> = entries
        .iter()
        .map(|(key, value)| serde_json::json!({ "key": key, "value": value, "deadline": 0 }))
        .collect();
    serde_json::to_string(&list).expect("序列化 runtimeSourceCache")
}

/// P1-3 核心断言：备份恢复后**不重启**即可读到恢复值
///
/// 恢复链路会清空内存五族（对齐上游 `Restore.kt:415`）；若没有恢复入口的显式
/// 重载（方案 1）与持久键懒加载（方案 2），此处 `source.get()` 读空、
/// `getLoginHeader()` 继续返回旧值。
#[test]
fn restore_makes_new_runtime_variables_visible_immediately() {
    let _lock = serial();
    ensure_db();
    let url = "https://p13-restore-immediate.example.com/source";
    let var_key = format!("v_{url}_token");
    let header_key = format!("loginHeader_{url}");
    let info_key = format!("userInfo_{url}");

    // 旧值：内存 + DB（模拟恢复前进程内的过期凭据）
    legado_ffi::legado_js::host_api::variable_store::set_variable(&var_key, "old-token")
        .expect("写旧变量");
    source_login_cache::put_login_header(url, r#"{"X-Token":"old"}"#).expect("写旧登录头");
    source_login_cache::put_login_info(url, r#"{"u":"old"}"#).expect("写旧登录信息");
    assert_eq!(db_row(&var_key).as_deref(), Some("old-token"));

    // 备份：新值
    let (dir, path) = write_runtime_backup(
        "legado-p13-restore-immediate",
        &runtime_cache_json(&[
            (&var_key, "new-token"),
            (&header_key, r#"{"X-Token":"new"}"#),
            (&info_key, r#"{"u":"new"}"#),
        ]),
    );

    legado_ffi::ffi::ffi::backup_restore(path.clone(), None).expect("恢复备份");

    // 恢复后立即读（不重启、不手动 backfill）
    assert_eq!(
        legado_ffi::legado_js::host_api::variable_store::get_flow_variable(&var_key).as_deref(),
        Some("new-token"),
        "恢复后 source.get() 必须立即读到新值（不是读空）"
    );
    assert_eq!(
        source_login_cache::get_login_header(url).as_deref(),
        Some(r#"{"X-Token":"new"}"#),
        "恢复后 getLoginHeader() 必须立即用新登录头（不是旧值）"
    );
    assert_eq!(
        source_login_cache::get_login_info(url).as_deref(),
        Some(r#"{"u":"new"}"#),
        "恢复后 getLoginInfo() 必须立即用新值"
    );
    // DB 权威值同步
    assert_eq!(db_row(&var_key).as_deref(), Some("new-token"));

    // 清理
    let _ = legado_ffi::legado_js::host_api::variable_store::remove_variable(&var_key);
    let _ = source_login_cache::remove_login_header(url);
    let _ = source_login_cache::remove_login_info(url);
    let _ = std::fs::remove_dir_all(&dir);
}

/// P1-3 方案 2 独立验证：**不经过恢复入口钩子**，仅清内存后读持久键
///
/// 直接调 `backup_api::backup_restore_with_password`（内部只做
/// `clear_source_variables()`，不含 FFI 入口的重载钩子），验证「清内存」本身
/// 已等价于「下次读从 DB 重载」。
#[test]
fn lazy_reload_after_memory_clear_without_restore_hook() {
    let _lock = serial();
    ensure_db();
    let url = "https://p13-lazy-reload.example.com/source";
    let var_key = format!("v_{url}_token");
    let header_key = format!("loginHeader_{url}");

    legado_ffi::legado_js::host_api::variable_store::set_variable(&var_key, "old-token")
        .expect("写旧变量");
    source_login_cache::put_login_header(url, r#"{"X-Token":"old"}"#).expect("写旧登录头");

    let (dir, path) = write_runtime_backup(
        "legado-p13-lazy-reload",
        &runtime_cache_json(&[
            (&var_key, "lazy-new"),
            (&header_key, r#"{"X-Token":"lazy-new"}"#),
        ]),
    );

    // 绕过 FFI 入口钩子：恢复体自身只清内存
    legado_ffi::api::backup_api::backup_restore_with_password(&path, None).expect("恢复备份");
    legado_ffi::legado_js::host_api::variable_store::clear_source_variables().expect("清内存");

    assert_eq!(
        legado_ffi::legado_js::host_api::variable_store::get_flow_variable(&var_key).as_deref(),
        Some("lazy-new"),
        "持久键内存 miss 时必须回查 DB（方案 2）"
    );
    assert_eq!(
        source_login_cache::get_login_header(url).as_deref(),
        Some(r#"{"X-Token":"lazy-new"}"#),
        "登录头读路径也必须回查 DB"
    );

    let _ = legado_ffi::legado_js::host_api::variable_store::remove_variable(&var_key);
    let _ = source_login_cache::remove_login_header(url);
    let _ = std::fs::remove_dir_all(&dir);
}

/// P2-2：内存无该键时 `removeLoginHeader` 仍必须删 DB 行（重启不复活）
#[test]
fn remove_login_header_deletes_db_row_without_memory_hit() {
    let _lock = serial();
    ensure_db();
    let url = "https://p22-remove-header.example.com/source";
    let header_key = format!("loginHeader_{url}");

    // 只有 DB 行（内存已被恢复链路/clear_variables 清掉）
    source_login_cache::put_login_header(url, r#"{"X-Token":"stale"}"#).expect("写登录头");
    legado_ffi::legado_js::host_api::variable_store::remove_memory_only(&header_key)
        .expect("只清内存");
    assert_eq!(
        legado_ffi::legado_js::host_api::variable_store::get_variable(&header_key).unwrap(),
        None
    );

    source_login_cache::remove_login_header(url).expect("删登录头");
    assert_eq!(db_row(&header_key), None, "内存 miss 时也必须删 DB 行");

    // 模拟重启：回填不得复活
    legado_ffi::legado_js::host_api::variable_store::backfill_from_sink();
    assert_eq!(
        source_login_cache::get_login_header(url),
        None,
        "重启回填不得复活已登出的登录头"
    );
}

/// P2-6：FFI 删除书源/RSS 源必须清掉五族运行时缓存行（否则孤儿传播 +
/// 同 URL 重导入继承旧登录态）
#[test]
fn delete_source_clears_five_family_cache_rows() {
    let _lock = serial();
    ensure_db();
    let url = "https://p26-delete-source.example.com/source";

    // 书源行 + 五族缓存行（B6 之后是真实持久数据）
    with_database(|db| {
        legado_db::BookSourceRepository::new(db.connection()).insert(
            &legado_ffi::legado_core::models::BookSource {
                book_source_url: url.to_string(),
                book_source_name: "P2-6 删除测试源".to_string(),
                ..Default::default()
            },
        )
    })
    .expect("插入书源");

    let keys = [
        format!("v_{url}_token"),
        format!("loginHeader_{url}"),
        format!("userInfo_{url}"),
        format!("sourceVariable_{url}"),
        format!("infoMap_{url}"),
    ];
    for key in &keys {
        legado_ffi::legado_js::host_api::variable_store::set_variable(key, "x").expect("写缓存行");
        assert!(db_row(key).is_some(), "前置：{key} 应已落库");
    }

    source::delete_source(url).expect("删除书源");

    for key in &keys {
        assert_eq!(db_row(key), None, "删源后 {key} 的五族行必须被清除");
        assert_eq!(
            legado_ffi::legado_js::host_api::variable_store::get_flow_variable(key),
            None,
            "删源后内存与懒加载读都不得再拿到 {key}"
        );
    }

    // RSS 源同一口径
    let rss_url = "https://p26-delete-rss.example.com/feed";
    legado_ffi::api::rss::add_rss_source(&format!(
        r#"{{"sourceUrl":"{rss_url}","sourceName":"P2-6 RSS 源"}}"#
    ))
    .expect("插入 RSS 源");
    let rss_keys = [
        format!("v_{rss_url}_k"),
        format!("loginHeader_{rss_url}"),
        format!("userInfo_{rss_url}"),
        format!("sourceVariable_{rss_url}"),
        format!("infoMap_{rss_url}"),
    ];
    for key in &rss_keys {
        legado_ffi::legado_js::host_api::variable_store::set_variable(key, "y")
            .expect("写 RSS 缓存行");
        assert!(db_row(key).is_some(), "前置：{key} 应已落库");
    }
    legado_ffi::api::rss::delete_rss_source(rss_url).expect("删除 RSS 源");
    for key in &rss_keys {
        assert_eq!(db_row(key), None, "删 RSS 源后 {key} 的行必须被清除");
    }
}

/// 同 URL 重导入不得继承旧登录头（P2-6 的用户可见后果）
#[test]
fn reimport_same_url_does_not_inherit_old_login_header() {
    let _lock = serial();
    ensure_db();
    let url = "https://p26-reimport.example.com/source";
    let header_key = format!("loginHeader_{url}");

    with_database(|db| {
        legado_db::BookSourceRepository::new(db.connection()).insert(
            &legado_ffi::legado_core::models::BookSource {
                book_source_url: url.to_string(),
                book_source_name: "P2-6 重导入源".to_string(),
                ..Default::default()
            },
        )
    })
    .expect("插入书源");
    source_login_cache::put_login_header(url, r#"{"X-Token":"old-session"}"#).expect("写登录头");
    assert!(db_row(&header_key).is_some());

    source::delete_source(url).expect("删除书源");
    // 同 URL 重导入
    with_database(|db| {
        legado_db::BookSourceRepository::new(db.connection()).insert(
            &legado_ffi::legado_core::models::BookSource {
                book_source_url: url.to_string(),
                book_source_name: "P2-6 重导入源".to_string(),
                ..Default::default()
            },
        )
    })
    .expect("重导入书源");

    assert_eq!(
        source_login_cache::get_login_header(url),
        None,
        "重导入后不得继承旧登录头"
    );
    assert_eq!(db_row(&header_key), None);
    let _ = source::delete_source(url);
}
