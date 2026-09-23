//! JS 宿主 cookie 持久化往返（对齐上游 2026-09-23 用户裁决）——先红后绿
//!
//! 上游 `CookieStore.saveCookie` 把 JS 写入的 cookie 落 DB（`cookies` 表，
//! 域名键 → 完整 cookie 串），重启后 `getCookieNoSession` 内存 miss 回落
//! DB 仍可读到；我方改造前 `GLOBAL_COOKIES` 为纯进程内存态，重启即失。
//!
//! **红证据（改造前）**：`test_persistence_roundtrip_survives_restart` 断言
//! 模拟重启（`test_clear_memory_only()` 仅丢弃内存 store、持久行仍在）后
//! 回填必须命中——未接入持久化下沉前读必为空，该用例必红（原始红输出
//! 见批次报告）。本文件自带内存型 RecordingSink 充当「DB 持久层」
//! （legado-js 自身不依赖 DB，生产环境由 FFI/server 注册基于
//! `CookieRepository` 的下沉），同一断言转绿。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use legado_js::host_api::cookie_store;

/// 文件内串行锁（`clear_all_cookies` 为进程级操作，须串行；下沉计数/行
/// 均为共享静态，相对断言须排除并发写入）
static TEST_LOCK: Mutex<()> = Mutex::new(());

/// 内存型「DB 持久层」（模拟 cookies 表：域名键 → 完整 cookie 串）
static SINK_ROWS: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct RecordingSink;

impl cookie_store::CookieSink for RecordingSink {
    fn upsert(&self, domain_key: &str, cookie_str: &str) {
        SINK_ROWS
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(domain_key.to_string(), cookie_str.to_string());
    }
    fn remove(&self, domain_key: &str) {
        SINK_ROWS
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(domain_key);
    }
    fn remove_all(&self) {
        SINK_ROWS.lock().unwrap_or_else(|p| p.into_inner()).clear();
    }
    fn load_all(&self) -> Vec<(String, String)> {
        SINK_ROWS
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
            .into_iter()
            .collect()
    }
}

/// 本二进制共享下沉（first-wins：重复注册被忽略）
static SHARED_SINK: LazyLock<Arc<RecordingSink>> = LazyLock::new(|| Arc::new(RecordingSink));

fn register_shared_sink() {
    let _ = cookie_store::set_cookie_sink(SHARED_SINK.clone());
}

fn sink_row(key: &str) -> Option<String> {
    SINK_ROWS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(key)
        .cloned()
}

/// cookie 串按键集合（`;` 拆段、去空、排序——HashMap 迭代序不保证，
/// 必须按键集合比较）
fn cookie_set(s: &str) -> Vec<String> {
    let mut parts: Vec<String> = s
        .split(';')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect();
    parts.sort();
    parts
}

/// 持久化往返：JS 写入 → 模拟进程重启（丢弃内存 store）→ 启动回填 → 读必须命中
#[test]
fn test_persistence_roundtrip_survives_restart() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    register_shared_sink();
    const URL: &str = "https://persist.roundtrip.test/";
    let dk = cookie_store::normalized_cookie_key(URL);
    cookie_store::set_cookie(URL, "k", "v");
    assert!(
        sink_row(&dk).is_some(),
        "写入后持久层必须有「域名键 → 完整串」行"
    );
    // 模拟进程重启：仅丢弃内存 store（持久行仍在——重启不清 DB）
    cookie_store::test_clear_memory_only();
    assert_eq!(cookie_store::get_cookie(URL), "", "回填前内存态必为空");
    // 进程启动点：全量回填（内存优先、miss 回落）
    cookie_store::backfill_from_sink();
    assert_eq!(
        cookie_store::get_cookie(URL),
        "k=v",
        "重启（内存丢弃）+ 回填后读必须命中（上游语义：cookie 已落 DB 持久层）"
    );
    // 收尾：两侧齐清
    cookie_store::clear_cookies(URL);
    assert_eq!(cookie_store::get_cookie(URL), "");
    assert!(
        sink_row(&dk).is_none(),
        "清除后持久行必须删除（内存 + DB 无残留）"
    );
}

/// 合并语义落库自洽：同名键覆盖、异名键保留，落库串 == 内存串
#[test]
fn test_merge_self_consistent_persisted_equals_memory() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    register_shared_sink();
    const URL: &str = "https://persist.merge.test/";
    let dk = cookie_store::normalized_cookie_key(URL);
    cookie_store::set_cookie(URL, "a", "1");
    cookie_store::set_cookie(URL, "b", "2");
    let persisted = sink_row(&dk).expect("写入后持久层必须更新");
    assert_eq!(
        cookie_set(&persisted),
        cookie_set(&cookie_store::get_cookie(URL)),
        "落库串必须与内存串按键相等（重启后从 DB 恢复 = 重启前内存态）"
    );
    // 同名键后写覆盖（异名键保留）
    cookie_store::set_cookie(URL, "a", "3");
    let persisted = sink_row(&dk).expect("覆盖写后持久行必须更新");
    let parts = cookie_set(&persisted);
    assert!(
        parts.contains(&"a=3".to_string()),
        "同名键后写必须覆盖: {persisted}"
    );
    assert!(
        !parts.contains(&"a=1".to_string()),
        "同名键旧值必须被覆盖: {persisted}"
    );
    assert!(
        parts.contains(&"b=2".to_string()),
        "异名键必须保留: {persisted}"
    );
    cookie_store::clear_cookies(URL);
}

/// 清除两侧齐清且幂等：内存 + 持久行（归一键 + 原始串键）全清，
/// 重复清除 no-op，回填后不复活
#[test]
fn test_clear_covers_both_sides_idempotent() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    register_shared_sink();
    const URL: &str = "https://persist.clear.test/";
    let dk = cookie_store::normalized_cookie_key(URL);
    let raw = URL.to_string();
    cookie_store::set_cookie(URL, "s", "1");
    assert!(sink_row(&dk).is_some(), "写入后持久行必须存在");
    cookie_store::clear_cookies(URL);
    assert_eq!(cookie_store::get_cookie(URL), "", "清除后内存态必须为空");
    assert!(sink_row(&dk).is_none(), "归一域名键持久行必须删除");
    if dk != raw {
        assert!(sink_row(&raw).is_none(), "原始串键持久行必须删除");
    }
    // 幂等：重复清除不 panic、状态不变
    cookie_store::clear_cookies(URL);
    cookie_store::backfill_from_sink();
    assert_eq!(cookie_store::get_cookie(URL), "", "回填后不得复活已清除域");
}

/// 域键一致性（quickjs 档：ETLD+1 单一真源）——多段 TLD 取末三段、
/// IP 字面量自键，且异域写入不串
#[cfg(feature = "quickjs")]
#[test]
fn test_domain_key_persistence_consistency() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    register_shared_sink();
    // 多段 TLD（com.cn）：host a.b.book.com.cn → 域名键取公共后缀 com.cn
    // 前的注册域 book.com.cn（不得塌缩为 com.cn——与 HTTP 层口径一致）
    const TLD_URL: &str = "https://a.b.book.com.cn/x";
    let tld_dk = cookie_store::normalized_cookie_key(TLD_URL);
    assert_eq!(
        tld_dk, "book.com.cn",
        "多段 TLD 域名键必须为 ETLD+1（注册域），不得塌缩末两段"
    );
    // IP 字面量（含 :port）：域名键为 IP 自身
    const IP_URL: &str = "http://203.0.113.7:8080/y";
    let ip_dk = cookie_store::normalized_cookie_key(IP_URL);
    assert_eq!(ip_dk, "203.0.113.7", "IP 字面量域名键必须为 IP 自身");
    // 跨域隔离：写入 TLD 域 cookie 后，IP 域读不得串入
    cookie_store::set_cookie(TLD_URL, "tld_ck", "tld-val");
    assert!(sink_row(&tld_dk).is_some(), "TLD 域写入必须落在 ETLD+1 键");
    let ip_read = cookie_store::get_cookie(IP_URL);
    assert!(
        !ip_read.contains("tld_ck"),
        "异域 cookie 不得串入: {ip_read}"
    );
    // 收尾
    cookie_store::clear_cookies(TLD_URL);
    cookie_store::clear_cookies(IP_URL);
}

/// 全量清除两侧齐清：内存 + 持久层全清，幂等，回填后不复活
#[test]
fn test_clear_all_covers_persistence() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    register_shared_sink();
    const URL: &str = "https://persist.clearall.test/";
    let dk = cookie_store::normalized_cookie_key(URL);
    cookie_store::set_cookie(URL, "s", "1");
    assert!(sink_row(&dk).is_some(), "写入后持久行必须存在");
    cookie_store::clear_all_cookies();
    assert_eq!(
        cookie_store::get_cookie(URL),
        "",
        "全量清除后内存态必须为空"
    );
    assert!(
        sink_row(&dk).is_none(),
        "全量清除后持久行必须删除（不得残留）"
    );
    // 幂等：重复全量清除 no-op
    cookie_store::clear_all_cookies();
    cookie_store::backfill_from_sink();
    assert_eq!(
        cookie_store::get_cookie(URL),
        "",
        "全量清除 + 回填后不得复活已清除域"
    );
}
