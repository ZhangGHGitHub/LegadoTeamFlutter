//! 书源运行时变量持久化下沉（B6/A4）
//!
//! 上游 `CacheManager` 把 `source.put` / `source.setVariable` /
//! `putLoginHeader` / `putLoginInfo` / `infoMap_*` 写入 `caches` 表
//! （`deadline = 0` 永久），重启后仍可读；我方此前这些键只存在于
//! `legado-js` 的进程级内存变量表，重启即失（备份的 `runtimeSourceCache`
//! 段因此也备份不到真实数据）。
//!
//! 本模块提供基于 [`CacheRepository`] 的 [`VariableSink`] 实现，由
//! `Bridge::db_open` 在 DB 初始化后注册（first-wins），并执行一次启动回填
//! （`caches` 表 → 内存变量表，内存优先、miss 回落）。
//!
//! `legado-js` 自身不依赖 DB（依赖方向不变）；本模块只实现 trait 与注册点。
//!
//! 键范围：`legado-js` 侧已按 [`legado_js::host_api::variable_store::is_persisted_key`]
//! 过滤，仅五族（`v_` / `userInfo_` / `loginHeader_` / `sourceVariable_` /
//! `infoMap_`）进入本下沉——与备份格式的 `runtimeSourceCache` 段口径一致。

use std::sync::Arc;

use legado_db::CacheRepository;
use legado_js::host_api::variable_store::{self, VariableSink};

/// 基于 `CacheRepository` 的变量持久化下沉
///
/// 每次调用经 [`crate::db_state::with_database`] 从全局连接池取连接；
/// DB 未初始化 / 读写失败仅记日志（JS 内存写入已成功，持久化失败不向
/// JS 传播——对齐上游「持久化宽容失败」方向）。
pub struct JsVariableDbSink;

impl VariableSink for JsVariableDbSink {
    fn upsert(&self, key: &str, value: &str) {
        let result = crate::db_state::with_database(|db| {
            CacheRepository::new(db.connection()).put(key, value, 0)
        });
        if let Err(e) = result {
            log::warn!("JS 变量持久化失败 '{key}': {e}");
        }
    }

    fn remove(&self, key: &str) {
        let result =
            crate::db_state::with_database(|db| CacheRepository::new(db.connection()).delete(key));
        if let Err(e) = result {
            log::warn!("JS 变量持久行删除失败 '{key}': {e}");
        }
    }

    fn load_all(&self) -> Vec<(String, String)> {
        let result = crate::db_state::with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            let mut rows = Vec::new();
            for prefix in variable_store::PERSISTED_KEY_PREFIXES {
                rows.extend(repo.list_by_prefix(prefix)?);
            }
            Ok(rows)
        });
        match result {
            Ok(rows) => rows,
            Err(e) => {
                log::warn!("JS 变量启动回填读取失败: {e}");
                Vec::new()
            }
        }
    }

    fn get(&self, key: &str) -> Option<String> {
        let result =
            crate::db_state::with_database(|db| CacheRepository::new(db.connection()).get(key));
        match result {
            Ok(value) => value,
            Err(e) => {
                log::warn!("JS 变量持久行读取失败 '{key}': {e}");
                None
            }
        }
    }
}

/// 注册变量持久化下沉并执行启动回填
///
/// 由 [`crate::ffi::Bridge::db_open`] 在 DB 初始化后调用（进程启动点，
/// 任何 JS 执行之前）。first-wins：重复调用被忽略（不重复回填，回填本身
/// 幂等但会白跑一遍全表扫描）。
pub fn register_js_variable_sink() {
    let registered = variable_store::set_variable_sink(Arc::new(JsVariableDbSink));
    if !registered {
        log::debug!("JS 变量持久化下沉已注册，忽略重复注册");
        return;
    }
    variable_store::backfill_from_sink();
}

/// 备份恢复后重载运行时变量内存（P1-3，批10 审查）
///
/// 恢复链路（`backup_api::restore_from_zip` / `restore_backup_data`）在写完
/// `caches` 行后调用 `clear_source_variables()`（对齐上游
/// `Restore.kt:393-397/415`），此后到进程重启前内存变量为空——`source.get()` /
/// `getLoginHeader()` 读空，登录头还会继续用旧的独立内存层值。
///
/// 本函数在**恢复入口**（`ffi::backup_restore`）成功后执行：
/// 1. `source_login_cache::reload_from_db()`：丢弃登录缓存内存（其真源已统一到
///    `variable_store`，此步保证语义显式）；
/// 2. `variable_store::backfill_from_sink()`：按 DB 权威值回填五族内存。
///
/// 与 P1-3 方案 2（持久键内存 miss 懒加载）互为双保险：即使本函数因故未跑到，
/// 下一次持久键读也会从 DB 重载；本函数只是让「恢复后立即读」连一次 DB 回查
/// 都不必付。DB 未初始化/下沉未注册时安全 no-op。
pub fn reload_runtime_variables_after_restore() {
    if let Err(e) = crate::api::source_login_cache::reload_from_db() {
        log::warn!("备份恢复后清理登录缓存内存失败（懒加载兜底）: {e}");
    }
    variable_store::backfill_from_sink();
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_js::host_api::variable_store;

    /// B6：`source.put` 类写入落 `caches` 表，清内存后回填仍可读（模拟重启）
    ///
    /// 锁序：先取全局变量表锁（`lock_global_store`），后取 DB 锁
    /// （`ensure_test_db`），与 `test_support` 模块的不变式一致。
    #[test]
    fn test_variable_persists_and_backfills_after_restart() {
        let _store_guard = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();

        // 保证下沉已注册（生产由 db_open 注册；测试二进制可能未走该入口）
        register_js_variable_sink();

        let url = "https://b6-sink.example.com/source";
        let key = format!("v_{url}_token");
        variable_store::put_flow_variable(&key, "tok-123").expect("写持久键");

        // 持久行确实落库（直接查 caches 表，绕开内存层）
        let stored = crate::db_state::with_database(|db| {
            legado_db::CacheRepository::new(db.connection()).get(&key)
        })
        .expect("查库")
        .expect("caches 应有该行");
        assert_eq!(
            stored, "tok-123",
            "source.put 应写穿 caches 表（deadline=0）"
        );

        // 模拟重启：只清内存变量表，回填后应恢复
        variable_store::clear_variables().expect("清内存");
        assert_eq!(variable_store::get_variable(&key).unwrap(), None);
        variable_store::backfill_from_sink();
        assert_eq!(
            variable_store::get_flow_variable(&key),
            Some("tok-123".into()),
            "重启回填后 source.put 的值应可读"
        );

        // 收尾：删持久行，避免污染共享测试库
        variable_store::remove_variable(&key).expect("删键");
        let after = crate::db_state::with_database(|db| {
            legado_db::CacheRepository::new(db.connection()).get(&key)
        })
        .expect("查库");
        assert!(after.is_none(), "remove_variable 应删掉持久行");
    }

    /// B6：跨源同名键不串（不同源 URL 的 `v_*` 各自独立）
    #[test]
    fn test_variable_sink_keeps_cross_source_keys_separate() {
        let _store_guard = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        register_js_variable_sink();

        let key_a = "v_https://b6-a.example.com_src_k";
        let key_b = "v_https://b6-b.example.com_src_k";
        variable_store::put_flow_variable(key_a, "a-value").expect("写 A");
        variable_store::put_flow_variable(key_b, "b-value").expect("写 B");

        variable_store::clear_variables().expect("清内存");
        variable_store::backfill_from_sink();
        assert_eq!(
            variable_store::get_flow_variable(key_a),
            Some("a-value".into())
        );
        assert_eq!(
            variable_store::get_flow_variable(key_b),
            Some("b-value".into())
        );

        let _ = variable_store::remove_variable(key_a);
        let _ = variable_store::remove_variable(key_b);
    }
}
