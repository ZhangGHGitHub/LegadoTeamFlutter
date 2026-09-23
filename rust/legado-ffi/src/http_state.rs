//! 共享 HTTP 客户端单例（Phase 1b）
//!
//! 背景：取章/搜索/发现等链路此前每次都 `LegadoClient::new()`，各自持有全新的
//! reqwest 连接池 + CookieStore，导致 TLS 握手重复、Cookie 丢失。
//!
//! 本模块提供进程级共享的 [`LegadoClient`] 单例。`LegadoClient` 已 `#[derive(Clone)]`
//! 且内部全为 `Arc`，clone 廉价；所有调用点改为 `shared_client()` 取同一底层客户端，
//! 复用连接池与 Cookie 存储。
//!
//! 单例以 `RwLock<Option<...>>` 承载（而非裸 `OnceLock`），以便 [`reset_shared_client`]
//! 在需要时清空并重建。
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

use std::sync::{Arc, Mutex, OnceLock, RwLock};

use legado_core::{LegadoError, LegadoResult};
use legado_net::{CookiePersistence, CookieStore, LegadoClient, LegadoClientConfig};

fn read_client_slot() -> std::sync::RwLockReadGuard<'static, Option<LegadoClient>> {
    client_slot()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn write_client_slot() -> std::sync::RwLockWriteGuard<'static, Option<LegadoClient>> {
    client_slot()
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Cookie 持久化行的读-改-写串行锁
///
/// 两个写方——HTTP jar 写回（[`DbCookiePersistence::save`]）与 JS 宿主下沉
/// （[`JsCookieDbSink::upsert`]）——写**同一张** `cookies` 表（quickjs 档
/// 同域行共用 ETLD+1 键）。若各写各的全量串（裸 upsert），后写者会用**本侧
/// store 的视图**覆盖掉另一侧已写入的同域键（跨 store 键丢失：jar 的
/// Set-Cookie 会话值被 JS 侧旧视图覆盖，反之亦然；重启后另一侧运行期
/// cookie 整体消失）。本锁串行化「读现有行 → 按键并集合并 → upsert」的
/// 读-改-写序列：并发陈旧写（一侧读到旧行后另一侧已更新）退化为
/// 「最新行 ∪ 最新写」而非盲目覆盖。
static COOKIE_PERSIST_RW_LOCK: Mutex<()> = Mutex::new(());

/// 按键合并两段完整 cookie 串（键集并集；同名键 `incoming` 胜出——与
/// net 层 `CookieStore::merge_cookies_str` / 上游 `CookieManager.mergeCookies`
/// 语义一致；解析口径同为 `CookieStore::cookie_string_to_map`：`;` 拆段、
/// 首个 `=` 分界、无 `=` 段 / 空键跳过、name/value 各 trim）
///
/// 输出按键名排序（行内容稳定：HashMap 迭代序不保证，裸拼接会让同一
/// 内容产生不同行串 → 无谓重 upsert / 重启后行抖动）。
fn merge_cookie_strings(existing: &str, incoming: &str) -> String {
    let mut map = CookieStore::cookie_string_to_map(existing);
    map.extend(CookieStore::cookie_string_to_map(incoming));
    let mut parts: Vec<String> = map.iter().map(|(k, v)| format!("{k}={v}")).collect();
    parts.sort();
    parts.join("; ")
}

/// 合并 upsert 一条 cookie 持久化行（两个写方共用：
/// [`DbCookiePersistence::save`] / [`JsCookieDbSink::upsert`]）
///
/// 在 [`COOKIE_PERSIST_RW_LOCK`] 内：读现有行 → 与传入串按键合并
///（同名键新值胜）→ upsert 合并结果。两侧皆空时跳过（行本不存在；
/// 空串写回走 `delete` 专门路径，此为防御分支）。
/// DB 未初始化 / 读写失败仅记日志——绝不向 JS 执行线程或网络请求传播。
fn persist_cookie_row_merged(tag: &str, incoming: &str) {
    let _guard = COOKIE_PERSIST_RW_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    let tag_for_log = tag.to_string();
    let tag = tag.to_string();
    let incoming = incoming.to_string();
    if let Err(e) = crate::db_state::with_database(move |db| {
        let repo = legado_db::CookieRepository::new(db.connection());
        let merged = match repo.get_by_tag(&tag)? {
            Some(existing) if existing != incoming => merge_cookie_strings(&existing, &incoming),
            _ => incoming.clone(),
        };
        if merged.is_empty() {
            Ok(())
        } else {
            repo.upsert(&tag, &merged)
        }
    }) {
        log::warn!("合并持久化 Cookie '{tag_for_log}' 写入失败: {e}");
    }
}

/// 基于 legado-db cookies 表的 Cookie 持久化实现
///
/// 通过 [`crate::db_state::with_database`] 从全局连接池取连接，
/// DB 未初始化或读写失败时仅记日志，不影响网络请求。
///
/// [`save`] 为**合并 upsert**（见 [`persist_cookie_row_merged`]）：与
/// JS 宿主下沉共用一行（同域键），按键并集合并而非整行覆盖——
/// 避免 jar 写回抹掉 JS 侧已写入的同域键。
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
        persist_cookie_row_merged(tag, cookie);
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

// ─── JS 宿主 Cookie 持久化下沉（上游同步 2026-09-23 用户裁决）─────────────────
//
// JS 侧 `java.setCookie` 写入的 cookie 经 [`legado_js::host_api::cookie_store::CookieSink`]
// 落同一张 `cookies` 表（域名键 → 按键合并后的完整串），与 HTTP 响应 Set-Cookie
// 的持久化共用同一存储；`legado-js` 自身不依赖 DB，下沉由本模块（FFI 层）
// 注册。
//
// 两个写方共用行 → **合并写**（[`persist_cookie_row_merged`]，键集并集、
// 同名键新值胜），`remove` / `remove_all` 在删 DB 行的同时同步清 HTTP 客户端
// 内存 CookieStore 对应域（统一存储清除语义：JS 清除 = 该域 cookie 全层
// 清除，jar 后续写回不会从旧内存复活已清域）。

/// 基于 [`legado_db::CookieRepository`] 的 JS 宿主 Cookie 持久化下沉
///
/// 每次调用经 [`crate::db_state::with_database`] 从全局连接池取连接；
/// DB 未初始化 / 读写失败仅记日志（JS 内存写入已成功，持久化失败不向
/// JS 传播——对齐上游「持久化宽容失败」方向）。
///
/// **锁序不变式**：`remove` / `remove_all` 先完成 DB 工作，再以**作用域内
/// 写锁**清共享客户端内存 CookieStore（写锁临界区内不含 DB/sink 调用）；
/// 调用方（`clear_cookies` / `clear_all_cookies` 的发起者）不得同时持有
/// 客户端 cookie store 的读/写 guard（`client.cookie_store().read()/write()`
/// 的 guard 跨调用存活）——同线程读 guard + 本下沉的 `write()` 是
/// `std::sync::RwLock` 保证的自死锁（写方等待全部读方释放，而读方即
/// 本线程、永不释放）。测试断言 jar 内存后须先释放读 guard 再触发清除。
pub struct JsCookieDbSink;

impl legado_js::host_api::cookie_store::CookieSink for JsCookieDbSink {
    fn upsert(&self, domain_key: &str, cookie_str: &str) {
        persist_cookie_row_merged(domain_key, cookie_str);
    }

    fn remove(&self, domain_key: &str) {
        let key = domain_key.to_string();
        let key_for_log = key.clone();
        let key_for_db = key.clone();
        if let Err(e) = crate::db_state::with_database(move |db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.delete_by_tag(&key_for_db)
        }) {
            log::warn!("JS Cookie 持久化 '{key_for_log}' 删除失败: {e}");
        }
        // 同步清共享 HTTP 客户端内存 CookieStore 的对应域（键为域名键时
        // 命中；原始串键与 jar 域名键不符 → 天然 no-op）：否则 jar 后续
        // Set-Cookie 写回会以旧内存态把已清域重新落库（复活），且本进程
        // 内该域 cookie 仍会随请求发出（统一清除语义）。
        if let Ok(client) = shared_client() {
            client
                .cookie_store()
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .remove_domain(&key);
        }
    }

    fn remove_all(&self) {
        if let Err(e) = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.clear_all()
        }) {
            log::warn!("JS Cookie 持久化全清失败: {e}");
        }
        // 同步清空共享客户端内存 CookieStore（全量清除 = 全层清除）
        if let Ok(client) = shared_client() {
            *client
                .cookie_store()
                .write()
                .unwrap_or_else(|p| p.into_inner()) = CookieStore::default();
        }
    }

    fn load_all(&self) -> Vec<(String, String)> {
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.find_all()
        })
        .unwrap_or_else(|e| {
            log::warn!("加载 JS Cookie 持久化行失败（跳过回填）: {e}");
            Vec::new()
        })
    }
}

/// 注册 JS 宿主 Cookie 持久化下沉并执行启动回填
///
/// 由 [`crate::ffi::Bridge::db_open`] 在 DB 初始化后调用（进程启动点，
/// 任何 JS 执行之前）：
/// - 下沉注册 first-wins（[`set_cookie_sink`](legado_js::host_api::cookie_store::set_cookie_sink)
///   重复注册被忽略）；
/// - 随后全量回填（`cookies` 表 → 内存 cookie store，**内存优先、miss 回落**，
///   幂等不覆盖既有内存值）——读侧热路径不加 DB 兜底，启动一次性载入。
pub fn register_js_cookie_sink() {
    use legado_js::host_api::cookie_store;

    let registered = cookie_store::set_cookie_sink(Arc::new(JsCookieDbSink));
    if !registered {
        log::debug!("JS Cookie 持久化下沉已注册，忽略重复注册");
        return;
    }
    cookie_store::backfill_from_sink();
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
///
/// **锁序约束**：客户端构建（含持久化后端的 DB `load_all`）在持有客户端槽位
/// **写锁之前**完成——槽位锁临界区内不做 DB/sink 调用（连接池取连接等待
/// 不得拖住全部 `shared_client` 读方，也避免与测试池单连接形成锁环）。
/// 并发首次构建时各线程自建客户端，槽位内先装者胜（败者构建直接丢弃——
/// 其 CookieStore 是 DB 全新加载、无在途写入，丢弃无数据损失）。
pub fn shared_client() -> LegadoResult<LegadoClient> {
    // 快路径：已初始化则直接 clone 返回
    {
        let guard = read_client_slot();
        if let Some(client) = guard.as_ref() {
            return Ok(client.clone());
        }
    }

    // 慢路径：先构建（含 DB load_all，不持槽位锁），再短暂持写锁装入
    let client = build_default_client()?;

    {
        let mut guard = write_client_slot();
        // 并发首次构建时再次检查：他线程已装入则返回其结果（自身构建丢弃）
        if let Some(existing) = guard.as_ref() {
            return Ok(existing.clone());
        }
        *guard = Some(client.clone());
    }
    Ok(client)
}

/// 构建默认配置的共享客户端（含 Cookie 持久化后端的 DB 加载）
///
/// **必须在不持有客户端槽位锁时调用**（见 [`shared_client`] 锁序约束）：
/// `LegadoClient::build` 同步执行 `persistence.load_all()`（DB I/O），
/// 若在槽位写锁临界区内执行，池取连接的等待会拖住全部读方。
fn build_default_client() -> LegadoResult<LegadoClient> {
    let client = match make_cookie_persistence() {
        Some(persistence) => {
            LegadoClient::with_cookie_persistence(LegadoClientConfig::default(), persistence)
        }
        None => LegadoClient::new(LegadoClientConfig::default()),
    };
    client.map_err(|e| LegadoError::Network(format!("初始化共享 HTTP 客户端失败: {e}")))
}

/// 重置共享客户端
///
/// 清空单例缓存，下次 [`shared_client`] 调用将重新构建。
pub fn reset_shared_client() {
    let mut guard = write_client_slot();
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
        let c1 = shared_client().unwrap();
        let c2 = shared_client().unwrap();
        assert!(
            Arc::ptr_eq(c1.cookie_store(), c2.cookie_store()),
            "多次 shared_client 应共享同一底层 CookieStore"
        );
    }

    /// 并发调用 shared_client 安全，且均共享同一底层客户端。
    #[test]
    fn test_shared_client_concurrent() {
        let _g = TEST_LOCK.lock().unwrap();
        let baseline = shared_client().unwrap();
        let baseline_ptr = Arc::as_ptr(baseline.cookie_store()) as usize;

        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(std::thread::spawn(move || {
                let c = shared_client().unwrap();
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
        let before = shared_client().unwrap();
        reset_shared_client();
        let after = shared_client().unwrap();
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
        let _db_guard = crate::db_state::ensure_test_db();

        // 预置一条 Cookie 到 DB（tag 为域名，与内存 CookieStore 键对齐）
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert("persist-test.com", "session=from_db")
        })
        .unwrap();

        // reset 后重建客户端，应从 DB 加载 Cookie
        reset_shared_client();
        let client = shared_client().unwrap();
        assert!(
            client.cookie_persistence().is_some(),
            "DB 已初始化时共享客户端应携带持久化后端"
        );
        let store = client
            .cookie_store()
            .read()
            .unwrap_or_else(|e| e.into_inner());
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
        let _db_guard = crate::db_state::ensure_test_db();

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

    // ─── JS 宿主 Cookie 持久化下沉（db_open 注册）测试 ──────────────────────

    /// cookie 串按键集合比较辅助（HashMap 迭代序不保证，按键集合相等断言）
    fn cookie_parts(s: &str) -> Vec<String> {
        let mut parts: Vec<String> = s
            .split(';')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        parts.sort();
        parts
    }

    fn db_cookie_row(dk: &str) -> Option<String> {
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(dk)
        })
        .expect("DB 必须已初始化（ensure_test_db）")
    }

    /// JS 宿主下沉 → DB 往返：写入落库（合并串）→ 模拟重启（清内存）→
    /// 回填命中；同名覆盖 / 异名保留后 DB 行与内存自洽；清除后两侧无残留
    #[test]
    fn test_js_cookie_sink_db_roundtrip() {
        let _g = TEST_LOCK.lock().unwrap();
        // 用例含 clear_all_cookies（进程级）+ 全局 cookie store 断言，
        // 必须持全局 store 串行锁排除其他 FFI 用例的 cookie 状态；
        // 全局锁序不变式：先 store 锁、后 DB 锁（见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL: &str = "https://ffi-js-persist.test/";
        let dk = cookie_store::normalized_cookie_key(URL);
        // 清理残留（幂等）
        cookie_store::clear_cookies(URL);
        assert!(db_cookie_row(&dk).is_none(), "测试前清理残留 DB 行");

        register_js_cookie_sink();

        // 写入 → DB 行（域名键 → 合并后完整串）
        cookie_store::set_cookie(URL, "a", "1");
        cookie_store::set_cookie(URL, "b", "2");
        let row = db_cookie_row(&dk).expect("写入后 DB 必须有「域名键 → 合并串」行");
        assert_eq!(
            cookie_parts(&row),
            cookie_parts(&cookie_store::get_cookie(URL)),
            "落库串必须与内存串按键相等（重启后从 DB 恢复 = 重启前内存态）"
        );

        // 模拟进程重启：仅丢弃内存 store（重启不清 DB 行）→ 启动回填 → 必须命中
        cookie_store::test_clear_memory_only();
        assert_eq!(cookie_store::get_cookie(URL), "", "回填前内存态必为空");
        cookie_store::backfill_from_sink();
        assert_eq!(
            cookie_parts(&cookie_store::get_cookie(URL)),
            cookie_parts(&row),
            "回填后内存态必须等于重启前落库串"
        );

        // 同名键覆盖 + 异名键保留，DB 行随写更新且自洽
        cookie_store::set_cookie(URL, "a", "3");
        let row2 = db_cookie_row(&dk).expect("覆盖写后 DB 行必须更新");
        let parts = cookie_parts(&row2);
        assert!(
            parts.contains(&"a=3".to_string()),
            "同名键后写必须覆盖: {row2}"
        );
        assert!(
            !parts.contains(&"a=1".to_string()),
            "同名键旧值必须被覆盖: {row2}"
        );
        assert!(parts.contains(&"b=2".to_string()), "异名键必须保留: {row2}");
        assert_eq!(
            parts,
            cookie_parts(&cookie_store::get_cookie(URL)),
            "DB 行必须与内存态按键自洽"
        );

        // 收尾：两侧齐清（内存 + DB）
        cookie_store::clear_cookies(URL);
        assert_eq!(cookie_store::get_cookie(URL), "");
        assert!(
            db_cookie_row(&dk).is_none(),
            "清除后 DB 行必须删除（无残留）"
        );
    }

    /// 合并写回归（跨 store 键丢失防护）：HTTP jar 行与 JS 下沉写同一
    /// 域名键时必须按键并集合并——jar 写回不得抹 JS 键集、JS 写不得抹
    /// jar 键集（裸 upsert 会以本侧全量串覆盖他侧键）；同名键后写胜出
    ///（对齐上游单存储 last-write 语义）；FFI `clear_cookie` 全层齐清
    #[test]
    fn test_js_cookie_sink_merge_with_http_rows() {
        let _g = TEST_LOCK.lock().unwrap();
        // 全局锁序不变式：先 crate 级全局 store 锁、后测试 DB 锁（与
        // source_switch / search 测试组同序；颠倒 + 并行执行 = ABBA 死锁，
        // 见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL: &str = "https://merge.collide.test/";
        let dk = cookie_store::normalized_cookie_key(URL);
        cookie_store::clear_cookies(URL);
        assert!(db_cookie_row(&dk).is_none(), "测试前清理残留 DB 行");

        register_js_cookie_sink();

        // 1) HTTP jar 行先存在（模拟 Set-Cookie 写回 "a=1"）
        DbCookiePersistence.save(&dk, "a=1");
        assert_eq!(
            db_cookie_row(&dk).map(|r| cookie_parts(&r)),
            Some(cookie_parts("a=1")),
            "空行合并写 = 传入串"
        );

        // 2) JS 写 c=3 → 行必须并集（jar 行键不得被抹）
        cookie_store::set_cookie(URL, "c", "3");
        let row = db_cookie_row(&dk).expect("JS 写后行必须存在");
        assert_eq!(
            cookie_parts(&row),
            cookie_parts("a=1; c=3"),
            "JS 写不得抹 jar 行键（并集合并）: {row}"
        );

        // 3) 同名键覆盖：JS 覆盖 a=9（写方胜出）
        cookie_store::set_cookie(URL, "a", "9");
        let row = db_cookie_row(&dk).expect("同名覆盖后行必须存在");
        assert_eq!(
            cookie_parts(&row),
            cookie_parts("a=9; c=3"),
            "同名键后写必须覆盖（写方胜出）: {row}"
        );

        // 4) jar 再写回（其自身视图 "a=9; b=2"——jar 内存无 c 键）→
        //    并集必须保留 JS 的 c=3（jar 全量串不得抹 JS 键集）
        DbCookiePersistence.save(&dk, "a=9; b=2");
        let row = db_cookie_row(&dk).expect("jar 写回后行必须存在");
        assert_eq!(
            cookie_parts(&row),
            cookie_parts("a=9; b=2; c=3"),
            "jar 写回不得抹 JS 键（并集合并）: {row}"
        );

        // 5) FFI 入口全层齐清：jar 内存 + DB 行 + JS 内存 + DB 行
        crate::api::net_api::clear_cookie(URL).expect("clear_cookie 必须成功");
        assert!(db_cookie_row(&dk).is_none(), "全层清除后 DB 行必须删除");
        assert_eq!(
            cookie_store::get_cookie(URL),
            "",
            "全层清除后 JS 内存必须为空"
        );
        // jar 读 guard 必须**块内释放**：随后的 clear_cookies → sink.remove
        // 会对同一 `Arc<RwLock<CookieStore>>` 取**写**锁——同一线程仍持读
        // guard 时 `RwLock::write()` 是 std 保证的自死锁（写方等待全部读方
        // 释放，而读方就是本线程、永远无法释放），且会连带卡住持 TEST_LOCK
        // 之外的全部 FFI 测试
        {
            let client = shared_client().unwrap();
            let store = client
                .cookie_store()
                .read()
                .unwrap_or_else(|p| p.into_inner());
            assert!(
                store.get_key(&dk, "a").is_none(),
                "全层清除后 jar 内存必须无该域 cookie"
            );
        }
        cookie_store::clear_cookies(URL); // 幂等收尾（raw 键行若有残留一并清）
    }

    /// JS 清除路径（`clear_cookies` → `sink.remove`）必须同步清共享 HTTP
    /// 客户端内存 CookieStore 的对应域：统一清除语义——清除后 jar 的后续
    /// 写回不会以旧内存态把已清域重新落库（复活）
    #[test]
    fn test_js_cookie_sink_remove_covers_jar_memory() {
        let _g = TEST_LOCK.lock().unwrap();
        // 全局锁序不变式：先 crate 级全局 store 锁、后测试 DB 锁（与
        // source_switch / search 测试组同序；颠倒 + 并行执行 = ABBA 死锁，
        // 见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL: &str = "https://jar.sync.test/";
        let dk = cookie_store::normalized_cookie_key(URL);
        register_js_cookie_sink();
        cookie_store::clear_cookies(URL); // 幂等清理

        // 预置 jar 内存域 cookie（模拟 Set-Cookie 已写入的内存态）
        {
            let client = shared_client().unwrap();
            client
                .cookie_store()
                .write()
                .unwrap_or_else(|p| p.into_inner())
                .set_cookies_from_string(&dk, "a=1");
        }
        cookie_store::set_cookie(URL, "js", "1"); // JS 写（行并集 "a=1; js=1"）
        cookie_store::clear_cookies(URL); // JS 清除路径（JS 内存 + DB 行 + jar 内存）
        assert!(db_cookie_row(&dk).is_none(), "清除后 DB 行必须删除");
        assert_eq!(cookie_store::get_cookie(URL), "", "清除后 JS 内存必须为空");
        let client = shared_client().unwrap();
        let store = client
            .cookie_store()
            .read()
            .unwrap_or_else(|p| p.into_inner());
        assert!(
            store.get_key(&dk, "a").is_none(),
            "JS 清除后 jar 内存对应域必须同步清除（不得写回复活）"
        );
    }

    /// 全量清除（`clear_all_cookies` → `sink.remove_all`）：DB 全部行
    /// （含 jar 写回行）+ jar 内存全清，回填后不复活
    #[test]
    fn test_js_cookie_sink_remove_all() {
        let _g = TEST_LOCK.lock().unwrap();
        // 全局锁序不变式：先 crate 级全局 store 锁、后测试 DB 锁（与
        // source_switch / search 测试组同序；颠倒 + 并行执行 = ABBA 死锁，
        // 见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL_A: &str = "https://clearall.a.test/";
        const URL_B: &str = "https://clearall.b.test/";
        register_js_cookie_sink();
        cookie_store::clear_cookies(URL_A);
        cookie_store::clear_cookies(URL_B); // 幂等清理

        let dk_a = cookie_store::normalized_cookie_key(URL_A);
        let dk_b = cookie_store::normalized_cookie_key(URL_B);
        cookie_store::set_cookie(URL_A, "k", "v");
        DbCookiePersistence.save(&dk_b, "other=1"); // 模拟另一域的 jar 写回行
        assert!(db_cookie_row(&dk_a).is_some(), "JS 行必须存在");
        assert!(db_cookie_row(&dk_b).is_some(), "jar 行必须存在");

        cookie_store::clear_all_cookies();

        assert!(
            db_cookie_row(&dk_a).is_none(),
            "全量清除必须删除 DB 行（JS 侧）"
        );
        assert!(
            db_cookie_row(&dk_b).is_none(),
            "全量清除必须删除 DB 行（jar 侧，统一存储全清）"
        );
        assert_eq!(cookie_store::get_cookie(URL_A), "");
        let client = shared_client().unwrap();
        let store = client
            .cookie_store()
            .read()
            .unwrap_or_else(|p| p.into_inner());
        assert!(
            store.get_key(&dk_b, "other").is_none(),
            "全量清除必须同步清空 jar 内存（不得写回复活）"
        );
        cookie_store::backfill_from_sink();
        assert_eq!(
            cookie_store::get_cookie(URL_A),
            "",
            "全量清除 + 回填后不得复活已清除域"
        );
    }

    /// 写放大缓解吞吐：1000 次值变化 `set_cookie`（每次触发一次 DB upsert，
    /// 值不变写跳过）+ 500 次四段串批量 `set_cookie_str`（每次 JS 调用至多
    /// 一次 upsert，逐段调用则每段一次），量级校验（DB 初始化后写路径
    /// 不阻塞 JS 执行）
    #[test]
    fn test_js_cookie_sink_upsert_throughput() {
        let _g = TEST_LOCK.lock().unwrap();
        // 全局锁序不变式：先 crate 级全局 store 锁、后测试 DB 锁（与
        // source_switch / search 测试组同序；颠倒 + 并行执行 = ABBA 死锁，
        // 见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL: &str = "https://perf.jspersist.test/";
        let dk = cookie_store::normalized_cookie_key(URL);
        cookie_store::clear_cookies(URL);
        assert!(db_cookie_row(&dk).is_none(), "测试前清理残留 DB 行");

        register_js_cookie_sink();

        const N: usize = 1000;
        let start = std::time::Instant::now();
        for i in 0..N {
            // 值每次变化 → 每次触发一次 DB upsert（值不变写被跳过，
            // 本用例测的就是「必须写」路径的吞吐下限）
            cookie_store::set_cookie(URL, "v", &format!("v{i}"));
        }
        let elapsed = start.elapsed();
        eprintln!(
            "[perf] JS cookie sink upsert: {N} ops in {elapsed:?} \
             (avg {} µs/op)",
            elapsed.as_micros() / N as u128
        );
        assert!(
            elapsed < std::time::Duration::from_secs(10),
            "DB 写放大吞吐不可接受: {elapsed:?}"
        );

        // 批量形态（JS `setCookie` 绑定实际入口）：四段串一次 JS 调用 =
        // 至多一次 upsert（逐段 set_cookie 则四段四次——量化批量收敛收益）
        const M: usize = 500;
        let batch_start = std::time::Instant::now();
        for i in 0..M {
            cookie_store::set_cookie_str(URL, &format!("p0=v{i}; p1=v{i}; p2=v{i}; p3=v{i}"));
        }
        let batch_elapsed = batch_start.elapsed();
        eprintln!(
            "[perf] JS cookie sink batch upsert (4-pair string): {M} ops in \
             {batch_elapsed:?} (avg {} µs/op, 每 op 至多 1 次 DB upsert)",
            batch_elapsed.as_micros() / M as u128
        );
        assert!(
            batch_elapsed < std::time::Duration::from_secs(10),
            "DB 批量写吞吐不可接受: {batch_elapsed:?}"
        );

        // 收尾：两侧齐清
        cookie_store::clear_cookies(URL);
        assert!(
            db_cookie_row(&dk).is_none(),
            "清除后 DB 行必须删除（无残留）"
        );
    }
}
