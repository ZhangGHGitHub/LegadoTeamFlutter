//! 共享 HTTP 客户端单例（Phase 1b）
//!
//! 背景：取章/搜索/发现等链路此前每次都 `LegadoClient::new()`，各自持有全新的
//! reqwest 连接池 + CookieStore + QUIC 客户端，导致 TLS 握手重复、Cookie 丢失。
//!
//! 本模块提供进程级共享的 [`LegadoClient`] 单例。`LegadoClient` 已 `#[derive(Clone)]`
//! 且内部全为 `Arc`，clone 廉价；所有调用点改为 `shared_client()` 取同一底层客户端，
//! 复用连接池与 Cookie 存储。
//!
//! 单例以 `RwLock<Option<...>>` 承载（而非裸 `OnceLock`），以便 [`reset_shared_client`]
//! 在 QUIC 开关切换等场景清空并重建。
//!
//! ## Cookie 持久化（Task #72）
//!
//! 依赖方向：legado-net 不依赖 legado-db，因此网络层仅定义
//! [`legado_net::CookiePersistence`] trait；本模块提供基于 legado-db
//! `CookieRepository` 的实现 [`DbCookiePersistence`]，在共享客户端初始化时注入：
//! - 构建时从 DB 加载全部 Cookie 到内存 CookieStore（重启不丢 Cookie）
//! - 响应 Set-Cookie 变更时同步写回 DB（按域名 upsert）
//!
//! 若构建时 DB 尚未初始化（`ffi_db_open` 未先于首次请求调用），则降级为纯内存
//! Cookie（与既有行为一致）；`reset_shared_client` 后重建时会重新尝试接入。

use std::sync::{Arc, OnceLock, RwLock};

use legado_net::{CookiePersistence, LegadoClient, LegadoClientConfig};

/// 基于 legado-db cookies 表的 Cookie 持久化实现
///
/// 通过 [`crate::db_state::with_database`] 从全局连接池取连接，
/// DB 未初始化或读写失败时仅记日志，不影响网络请求。
pub struct DbCookiePersistence;

impl CookiePersistence for DbCookiePersistence {
    fn load_all(&self) -> Vec<(String, String)> {
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.find_all()
        })
        .unwrap_or_else(|e| {
            log::warn!("加载持久化 Cookie 失败（降级为内存 Cookie）: {}", e);
            Vec::new()
        })
    }

    fn save(&self, tag: &str, cookie: &str) {
        let tag_for_log = tag.to_string();
        let tag = tag.to_string();
        let cookie = cookie.to_string();
        if let Err(e) = crate::db_state::with_database(move |db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert(&tag, &cookie)
        }) {
            log::warn!("持久化 Cookie '{}' 写入失败: {}", tag_for_log, e);
        }
    }

    fn delete(&self, tag: &str) {
        let tag_for_log = tag.to_string();
        let tag = tag.to_string();
        if let Err(e) = crate::db_state::with_database(move |db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.delete_by_tag(&tag)
        }) {
            log::warn!("删除持久化 Cookie '{}' 失败: {}", tag_for_log, e);
        }
    }
}

/// 构造 Cookie 持久化后端（DB 已初始化时返回 DB 实现，否则 None）
fn make_cookie_persistence() -> Option<Arc<dyn CookiePersistence>> {
    if crate::db_state::is_initialized() {
        Some(Arc::new(DbCookiePersistence))
    } else {
        log::debug!("共享客户端构建时数据库未初始化，Cookie 仅驻留内存");
        None
    }
}

/// 承载单例的可变槽位
///
/// 用 `OnceLock` 惰性创建 `RwLock`，再用 `Option` 支持重置（设为 `None` 后下次访问重建）。
fn client_slot() -> &'static RwLock<Option<LegadoClient>> {
    static SLOT: OnceLock<RwLock<Option<LegadoClient>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(None))
}

/// 获取进程共享的 HTTP 客户端（默认配置）
///
/// 首次调用时以 [`LegadoClientConfig::default`] 惰性初始化并缓存；
/// 后续调用返回缓存客户端的廉价 clone（共享同一底层连接池与 CookieStore）。
///
/// 采用双重检查锁：读路径走 `read()` 快路径，仅在未初始化时升级 `write()`。
pub fn shared_client() -> LegadoClient {
    // 快路径：已初始化则直接 clone 返回
    {
        let guard = client_slot().read().unwrap();
        if let Some(client) = guard.as_ref() {
            return client.clone();
        }
    }

    // 慢路径：加写锁初始化（再次检查，避免并发重复创建）
    let mut guard = client_slot().write().unwrap();
    if let Some(client) = guard.as_ref() {
        return client.clone();
    }

    // 默认配置不含 proxy/ssl，构建实际不会失败；与既有 RealBookSourceFetcher 一致用 expect
    // Cookie 持久化：DB 已初始化时注入 DbCookiePersistence（启动加载 + 变更写回）
    let client = match make_cookie_persistence() {
        Some(persistence) => {
            LegadoClient::with_cookie_persistence(LegadoClientConfig::default(), persistence)
        }
        None => LegadoClient::new(LegadoClientConfig::default()),
    }
    .expect("初始化共享 HTTP 客户端失败（默认配置不应失败）");
    *guard = Some(client.clone());
    client
}

/// 重置共享客户端
///
/// 清空单例缓存，下次 [`shared_client`] 调用将重新构建。
/// 用于 QUIC 传输开关切换等需要重建底层客户端的场景。
pub fn reset_shared_client() {
    let mut guard = client_slot().write().unwrap();
    *guard = None;
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// 串行保护：以下测试会读写全局单例（含 reset），需串行执行避免相互干扰。
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 多次调用 shared_client 应共享同一底层客户端。
    ///
    /// 通过公共访问器 `cookie_store()` 返回的 `Arc` 指针相等来判定
    /// （clone 共享同一 `Arc<RwLock<CookieStore>>`）。
    #[test]
    fn test_shared_client_same_underlying() {
        let _g = TEST_LOCK.lock().unwrap();
        let c1 = shared_client();
        let c2 = shared_client();
        assert!(
            Arc::ptr_eq(c1.cookie_store(), c2.cookie_store()),
            "多次 shared_client 应共享同一底层 CookieStore"
        );
    }

    /// 并发调用 shared_client 安全，且均共享同一底层客户端。
    #[test]
    fn test_shared_client_concurrent() {
        let _g = TEST_LOCK.lock().unwrap();
        let baseline = shared_client();
        let baseline_ptr = Arc::as_ptr(baseline.cookie_store()) as usize;

        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(std::thread::spawn(move || {
                let c = shared_client();
                let ptr = Arc::as_ptr(c.cookie_store()) as usize;
                assert_eq!(ptr, baseline_ptr, "并发 shared_client 应共享同一底层客户端");
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
    }

    /// reset 后应重建底层客户端（CookieStore Arc 指针不同）。
    #[test]
    fn test_reset_shared_client_rebuilds() {
        let _g = TEST_LOCK.lock().unwrap();
        let before = shared_client();
        reset_shared_client();
        let after = shared_client();
        assert!(
            !Arc::ptr_eq(before.cookie_store(), after.cookie_store()),
            "reset 后应重建底层客户端"
        );
    }

    // ─── Cookie 持久化（DB 注入）测试 ──────────────────────────

    /// DB 已初始化时，shared_client 应携带持久化后端，
    /// 且 DB 中预置的 Cookie 应被加载到客户端 CookieStore。
    #[test]
    fn test_shared_client_with_db_cookie_persistence() {
        let _g = TEST_LOCK.lock().unwrap();
        crate::db_state::ensure_test_db();

        // 预置一条 Cookie 到 DB（tag 为域名，与内存 CookieStore 键对齐）
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert("persist-test.com", "session=from_db")
        })
        .unwrap();

        // reset 后重建客户端，应从 DB 加载 Cookie
        reset_shared_client();
        let client = shared_client();
        assert!(
            client.cookie_persistence().is_some(),
            "DB 已初始化时共享客户端应携带持久化后端"
        );
        let store = client.cookie_store().read().unwrap();
        assert_eq!(
            store.get_key("persist-test.com", "session"),
            Some("from_db".to_string()),
            "DB 预置 Cookie 应被加载到内存 CookieStore"
        );
    }

    /// DbCookiePersistence 直接测试：save/load/delete 与 CookieRepository 联动。
    #[test]
    fn test_db_cookie_persistence_roundtrip() {
        let _g = TEST_LOCK.lock().unwrap();
        crate::db_state::ensure_test_db();

        let persistence = DbCookiePersistence;
        persistence.save("roundtrip.com", "a=1; b=2");

        let loaded = persistence.load_all();
        assert!(
            loaded
                .iter()
                .any(|(tag, c)| tag == "roundtrip.com" && c == "a=1; b=2"),
            "save 后 load_all 应包含写入条目"
        );

        persistence.delete("roundtrip.com");
        let loaded = persistence.load_all();
        assert!(
            !loaded.iter().any(|(tag, _)| tag == "roundtrip.com"),
            "delete 后 load_all 不应再包含该条目"
        );
    }
}
