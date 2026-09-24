//! Cookie 存储 API
//!
//! 对应 Kotlin JsExtensions.kt 中的 getCookie(url) / getCookie(url, key)
//! 与 `CookieStore.setCookie(url, cookie)`。
//!
//! # 上游同步（2026-09-23 用户裁决）：cookie 属于域名，不属于书源
//!
//! - **写侧归一**：`set_cookie(url, …)` 的键按上游 `NetworkUtils.getSubDomain(url)`
//!   等价规则归一为 ETLD+1 域名键（http(s) URL → 域名键；非 http(s) 串 / 解析
//!   失败 → 保留原串，对齐上游 `getSubDomain` 回退）；
//! - **读侧按请求 URL 取**：[`cookies_for_url`] 以请求 URL 的域名键取 cookie
//!   （对齐上游 `CookieManager.loadRequest` 的 `getSubDomain(request.url)` 口径），
//!   **去掉书源 tag 维度**——同域 cookie 跨书源共享；不相关域名的 cookie
//!   绝不携带（P2-19 不变式保留）。取代 P2-19 的 `cookies_for_source_tag`
//!   （含「未归属不携带」收紧——本批取消：未归属上下文也携带请求域 cookie）。
//!
//! 键规则单一真源：[`legado_net::cookie_store::cookie_domain_key`] /
//! [`legado_net::cookie_store::domain_key_from_host`]（与 HTTP 层 Cookie 存储、
//! FFI `get_sub_domain` / `clear_cookie` 同一套 ETLD+1 规则，不另写第二套）。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, OnceLock};

/// 全局 Cookie 存储（按域名键 / 原始串键隔离；值为 name → value 映射）
static GLOBAL_COOKIES: LazyLock<Mutex<HashMap<String, HashMap<String, String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Cookie 持久化下沉（由上层注入；`legado-js` 自身不依赖任何 DB）
///
/// 对齐上游 `CookieStore.saveCookie` 落库语义：JS 侧 `java.setCookie` 写入
/// 经此下沉落 DB `cookies` 表（**域名键 → 按键合并后的完整 cookie 串**），
/// 进程启动时由 [`backfill_from_sink`] 回填内存存储，重启不丢。
///
/// 下沉调用发生在 JS 执行线程、且**在 cookie store 锁释放之后**（不持
/// cookie 锁跨 DB I/O）：实现必须 `Send + Sync` 且快速；失败仅记日志、
/// 绝不向 JS 传播（cookie 内存写入本身已成功，持久化失败不影响本进程
/// 读侧——对齐上游「持久化宽容失败」方向）。
pub trait CookieSink: Send + Sync {
    /// upsert 指定域名键的完整 cookie 串（`name1=value1; name2=value2`，
    /// 按键合并后的全量串——保证「重启后从 DB 恢复 = 重启前内存态」）
    fn upsert(&self, domain_key: &str, cookie_str: &str);
    /// 删除指定域名键的持久化行（幂等）
    fn remove(&self, domain_key: &str);
    /// 清空全部持久化行（幂等；对齐 [`clear_all_cookies`] 的清除语义——
    /// 保证「清除后回填不得复活」，生产实现必须覆盖此方法）
    fn remove_all(&self);
    /// 加载全部持久化行（域名键 → 完整 cookie 串），供启动回填
    fn load_all(&self) -> Vec<(String, String)>;
}

/// 全局持久化下沉（first-wins：上层在 DB 初始化点注册一次，重复调用被
/// 忽略——与 net 层 `CookiePersistence` 注入方向一致，避免二次注册静默
/// 切换持久化后端）
static COOKIE_SINK: OnceLock<Arc<dyn CookieSink>> = OnceLock::new();

/// 注册 Cookie 持久化下沉（first-wins，后续调用被忽略）
///
/// 返回 `true` = 实际注册成功；`false` = 已存在下沉（忽略）。
/// **默认未注册 → 纯内存**（行为与改造前完全一致；测试 / 无 DB 环境
/// 不受影响，见集成测试 `cookie_no_sink.rs`）。
pub fn set_cookie_sink(sink: Arc<dyn CookieSink>) -> bool {
    COOKIE_SINK.set(sink).is_ok()
}

/// 将持久化行回填进内存存储（上层注册后调用一次，即进程启动点）
///
/// **内存优先、miss 回落**：同名键以既有内存值胜出（内存态可能更新，
/// 例如「模拟重启」前内存写入而 DB 行较旧）；DB 独有的键按 key 补齐
///（miss 回填）。幂等：重复调用不改变既有内存值。未注册下沉时 no-op。
///
/// **归一键、跳过非归一行（重要 2）**：历史批次中 DB 行可能以**原始 URL**
/// 为键（如 `"https://x.com/"`）。读侧 [`merge_cookie_entries`] 原始键优先，
/// 若原样回填成原始键条目，其后 `set_cookie`（写归一域名键 `x.com`）的新值
/// 在读取时会被原始键旧值**永久遮蔽**（getCookie 恒返旧值）。故回填前按
/// [`normalize_cookie_key`] 归一校验：归一结果 ≠ 存储键的行**跳过**（不做
/// 迁移——把原始 URL 行并入 ETLD+1 域键会把不同子域的 cookie 混进同一键，
/// 语义扩张；跳过后旧行自然废弃，由后续对该域的写入重建归一行）。
///
/// # 可见性变化（回填把 jar 行灌入 JS store，评审已查证为无害）
///
/// `cookies` 表的行有**两个生产者**：本 crate 的 JS `set_cookie` sink
/// upsert，与 HTTP jar 写回（net 层 `DbCookiePersistence`，含 **jar 独占**
/// 的会话 cookie）。回填将后者一并灌入 JS 内存 store；而 JS ajax 使用
/// **进程级共享池**客户端（`network.rs::shared_client_for_url`；客户端自身
/// 仅持内存 CookieStore、无持久 jar）+ [`merge_js_cookies`] 把本 store
/// 并入请求头 → jar 会话 cookie 对 JS ajax 变为**可见**（批次前 JS ajax
/// 只见 JS 写入的 cookie）——这是一个可见性
/// 变化。结论（查证）：按域匹配仍然 sound——两侧共享单一来源域键规则
/// （`cookie_domain_key` ETLD+1），jar cookie 只落在自身域键下，JS 读侧只
/// 取请求自身域键、绝不跨域携带；与上游「cookie 属于域名」语义一致
/// （上游 JS getCookie 亦不做 scheme 门控）。残余细节：JS store 只保存
/// `name=value`（不保存 Secure/HttpOnly 标志）→ 带 Secure 标志的 jar cookie
/// 可能随**同域** plain-HTTP JS ajax 下发——与上游行为一致（上游 JS store
/// 同样无标志过滤），低风险已知细节。
pub fn backfill_from_sink() {
    let Some(sink) = COOKIE_SINK.get() else {
        return;
    };
    let rows = sink.load_all();
    if rows.is_empty() {
        return;
    }
    let mut store = lock_store();
    for (domain_key, cookie_str) in rows {
        // 归一键校验（重要 2）：非归一存储键（历史原始 URL 键）跳过——
        // 读侧原始键优先会遮蔽归一键新值；不做迁移（避免子域 cookie
        // 混键），见函数文档
        let norm = normalize_cookie_key(&domain_key);
        if norm != domain_key {
            continue;
        }
        let entry = store.entry(domain_key).or_default();
        for (name, value) in parse_cookie_pairs(&cookie_str) {
            entry.entry(name).or_insert(value);
        }
    }
}

/// 解析 `name1=value1; name2=value2` 形态的完整 cookie 串为 (name, value)
/// 对（与 JS 绑定 `java.setCookie` 循环的 `split(';')` + 首个 `=` 拆分口径
/// 一致；段内无 `=` → 值为空串）。仅本模块内部使用（回填 / 写侧更新）；
/// 跨 crate 的按键合并统一走 net 层 `CookieStore::cookie_string_to_map`
/// （与 jar 写回串、请求头合并同一口径，不另写第二套解析）。
fn parse_cookie_pairs(cookie_str: &str) -> Vec<(String, String)> {
    cookie_str
        .split(';')
        .filter_map(|part| {
            let part = part.trim();
            if part.is_empty() {
                return None;
            }
            let (name, value) = part.split_once('=').unwrap_or((part, ""));
            Some((name.trim().to_string(), value.trim().to_string()))
        })
        .collect()
}

/// 测试专用（双档）：进程级 cookie 存储串行锁（跨测试模块共享——回环
/// 域名键 `127.0.0.1` 与常见域名键（`book.com.cn` 等）被 cookie_store.rs / network.rs /
/// source_engine.rs 等多处用例共用；
/// 中毒恢复语义同 `legado-ffi::test_support::GLOBAL_STORE_TEST_LOCK`）
#[cfg(test)]
pub(crate) static COOKIE_STORE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 测试专用（双档）：取 [`COOKIE_STORE_TEST_LOCK`] 的 guard（中毒即恢复复用）
#[cfg(test)]
pub(crate) fn lock_cookie_store_test() -> std::sync::MutexGuard<'static, ()> {
    COOKIE_STORE_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

/// 取全局 cookie store 锁（毒化即 `into_inner` 恢复复用——持锁侧 panic
/// 不应令存储永久不可用；与测试锁 `lock_cookie_store_test` 同一恢复语义）
fn lock_store() -> std::sync::MutexGuard<'static, HashMap<String, HashMap<String, String>>> {
    GLOBAL_COOKIES.lock().unwrap_or_else(|e| e.into_inner())
}

// ─── 按域写通道（与 HTTP jar 写回路径互斥同域「捕获 + 落库」，重要 1） ─────

/// 取某域写通道串行锁（最外层 D 锁；锁序不变式与 net 层
/// `cookie_store::DOMAIN_WRITE_LOCKS` 文档一致——
/// D（按域，最外层；其下允许 DB/sink I/O）→ G（内存存储，短临界区，
/// 不回调 D、不做 sink 调用）→ C（FFI DB 行锁）→ P（连接池））
///
/// - **quickjs 档**（进程内有 HTTP jar 客户端）：复用 net 层注册表
///   [`legado_net::cookie_store::domain_write_lock`]——JS 写 / 清与 jar
///   写回路径（`save_cookies_from_response`）在同一把锁上互斥，「捕获 +
///   落库」对同域原子（关闭本文件 `with_store_update`「锁内合并、锁外
///   upsert」被并发同域写插入导致落库过期视图的窗口）；
/// - **默认档**（无 `legado-net` 依赖、进程内亦无 jar 客户端）：使用本
///   crate 本地同形注册表（无跨路径争用方；关闭并发同域 JS 写之间
///   「内存更新 + sink 写回」的交错窗口）。
fn domain_write_guard(domain_key: &str) -> std::sync::MutexGuard<'static, ()> {
    #[cfg(feature = "quickjs")]
    {
        use legado_net::cookie_store::domain_write_lock;
        domain_write_lock(domain_key)
    }
    #[cfg(not(feature = "quickjs"))]
    {
        let ptr = {
            let mut registry = LOCAL_DOMAIN_WRITE_LOCKS
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            let arc = registry
                .entry(domain_key.to_string())
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone();
            Arc::into_raw(arc)
        };
        // SAFETY：同 net 层 `domain_write_lock`——锁对象由静态注册表永久
        // 持有（条目永不删除）；此处仅加锁，守卫 drop 只解锁、不触碰所有权。
        unsafe { (&*ptr).lock().unwrap_or_else(|p| p.into_inner()) }
    }
}

/// 默认档本地按域写通道注册表（quickjs 档复用 net 层注册表，不用本表）
#[cfg(not(feature = "quickjs"))]
static LOCAL_DOMAIN_WRITE_LOCKS: LazyLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 全部按域写通道守卫（整体清空操作用；quickjs 档 = net 层
/// [`legado_net::cookie_store::AllDomainWriteGuards`]，默认档 = 本地同形结构）
#[cfg(feature = "quickjs")]
type DomainWriteAllGuards = legado_net::cookie_store::AllDomainWriteGuards;

/// 默认档本地「注册表 + 全部域锁」守卫
#[cfg(not(feature = "quickjs"))]
pub struct DomainWriteAllGuards {
    /// 注册表锁（阻塞新域注册）
    _registry: std::sync::MutexGuard<'static, HashMap<String, Arc<Mutex<()>>>>,
    /// 全部既有域锁（按域键排序取锁防环）
    _domains: Vec<std::sync::MutexGuard<'static, ()>>,
}

/// 取全部按域写通道（注册表锁 + 全部域锁，按域键排序取锁防环；注册表锁
/// 阻塞临界期内的新域注册）——供整体清空操作与逐域写方互斥
fn lock_all_domain_writes() -> DomainWriteAllGuards {
    #[cfg(feature = "quickjs")]
    {
        legado_net::cookie_store::lock_all_domain_writes()
    }
    #[cfg(not(feature = "quickjs"))]
    {
        let registry = LOCAL_DOMAIN_WRITE_LOCKS
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let mut keys: Vec<String> = registry.keys().cloned().collect();
        keys.sort();
        let mut domains = Vec::with_capacity(keys.len());
        for key in &keys {
            let ptr = Arc::as_ptr(registry.get(key).expect("键来自同一注册表快照，必然存在"));
            // SAFETY：同 `domain_write_guard`——锁对象由静态注册表永久持有，
            // 指针存活期 'static；此处仅加锁返回守卫，守卫 drop 只解锁。
            domains.push(unsafe { (&*ptr).lock().unwrap_or_else(|p| p.into_inner()) });
        }
        DomainWriteAllGuards {
            _registry: registry,
            _domains: domains,
        }
    }
}

/// Cookie 键归一（上游 `NetworkUtils.getSubDomain` 等价规则）
///
/// - http(s) URL（大小写不敏感，对齐上游 `getBaseUrl` 的 `startsWith("http://", true)`）
///   → ETLD+1 域名键，复用 [`legado_net::cookie_store::cookie_domain_key`] 单一真源
///   （URL 解析取 host → `domain_key_from_host`：IP 字面量自键、多段 TLD 末三段、
///   其余末两段、单段兜底自身）；解析失败 → 保留原串（对齐上游异常回退 `baseUrl`
///   的「失败即退回原输入」方向，本实现退回未 trim 前的 trim 串）；
/// - 非 http(s) 串（裸 host / 裸域名 / 任意非 URL 形态）→ 保留原串
///   （对齐上游 `getSubDomain`：`getBaseUrl` 返回 null → 原样返回 url）。
#[cfg(feature = "quickjs")]
fn normalize_cookie_key(input: &str) -> String {
    use legado_net::cookie_store::cookie_domain_key;
    let input = input.trim();
    let lower = input.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return cookie_domain_key(input).unwrap_or_else(|| input.to_string());
    }
    input.to_string()
}

/// 默认档（未启用 quickjs，无 `legado-net` 依赖）降级：不推导域名键，
/// 键为 trim 后的原串（与 P2-19 前「精确键」行为一致，域名键形态仅
/// quickjs 档的 FFI `clear_cookie` / 读侧路径使用）。
#[cfg(not(feature = "quickjs"))]
fn normalize_cookie_key(input: &str) -> String {
    input.trim().to_string()
}

/// 读侧键候选合并：域名键条目先入（继承/域级写入），原始串条目覆盖
///（更具体 / 历史原始串键胜出——延续 P2-19「精确键胜出」方向；归一后
/// 新写入必落域名键，原始串候选仅覆盖历史遗留的原始键与「归一结果
/// 恰为原串」的非 URL 输入）
fn merge_cookie_entries(
    store: &HashMap<String, HashMap<String, String>>,
    input: &str,
) -> HashMap<String, String> {
    let raw = input.trim().to_string();
    let norm = normalize_cookie_key(input);
    let mut merged: HashMap<String, String> = HashMap::new();
    if norm != raw {
        if let Some(map) = store.get(&norm) {
            for (name, value) in map {
                merged.insert(name.clone(), value.clone());
            }
        }
    }
    if let Some(map) = store.get(&raw) {
        for (name, value) in map {
            merged.insert(name.clone(), value.clone());
        }
    }
    merged
}

fn format_cookies(cookies: &HashMap<String, String>) -> String {
    cookies
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// getCookie(url) — 获取 URL 所属域（getSubDomain 等价域名键）的全部 Cookie
///（格式: "key1=value1; key2=value2"；历史原始串键同名时胜出）
pub fn get_cookie(url: &str) -> String {
    let store = lock_store();
    format_cookies(&merge_cookie_entries(&store, url))
}

/// getCookie(url, key) — 获取 URL 所属域下指定 key 的 Cookie 值
pub fn get_cookie_by_key(url: &str, key: &str) -> String {
    let store = lock_store();
    merge_cookie_entries(&store, url)
        .get(key)
        .cloned()
        .unwrap_or_default()
}

/// 写侧更新公共骨架：单锁内更新域名键条目，`f` 返回「是否有值变化」；
/// 有变化时在**内存锁释放后**经下沉 upsert「域名键 → 按键合并后的完整串」
///（不持 cookie 锁跨 DB I/O；值不变写跳过——缓解高频 `set_cookie` 的
/// 写放大，每次 JS 写调用至多一次持久化写回）
///
/// **按域写通道（重要 1）**：全程持有该归一域键的串行锁（最外层 D 锁），
/// 使「内存更新 + 合并串落库」对同域原子——并发同域写（quickjs 档含
/// HTTP jar 写回路径）不得在「锁内合并」与「锁外 upsert」之间插入，
/// 否则落库行回退为过期视图。sink 调用仍在**内存锁（G）释放后**执行
///（不持 cookie 锁跨 DB I/O——死锁修复的结构性不变式不回归）。
fn with_store_update(url: &str, f: impl FnOnce(&mut HashMap<String, String>) -> bool) {
    let domain_key = normalize_cookie_key(url);
    let _domain_guard = domain_write_guard(&domain_key);
    let merged = {
        let mut store = lock_store();
        let entry = store.entry(domain_key.clone()).or_default();
        if f(entry) {
            Some(format_cookies(entry))
        } else {
            None
        }
    };
    if let Some(merged) = merged {
        if let Some(sink) = COOKIE_SINK.get() {
            sink.upsert(&domain_key, &merged);
        }
    }
}

/// setCookie(url, key, value) — 设置单个 Cookie（写侧归一：http(s) URL 键
/// 归一为 ETLD+1 域名键，对齐上游 `CookieStore.setCookie(url, cookie)` 的
/// `domain = getSubDomain(url)` 落库口径）
///
/// 持久化下沉（若已注册 [`set_cookie_sink`]）：**值变化时**才 upsert
/// 「域名键 → 按键合并后的完整 cookie 串」（同名值重写不产生 DB 写，
/// 缓解 JS 循环内高频 `set_cookie` 的写放大）；下沉调用在 cookie store
/// 锁释放之后执行（不持锁跨 DB I/O）。
pub fn set_cookie(url: &str, key: &str, value: &str) {
    with_store_update(url, |entry| {
        let changed = entry.get(key).map(String::as_str) != Some(value);
        entry.insert(key.to_string(), value.to_string());
        changed
    });
}

/// setCookie(url, cookieStr) 批量形态 — 一次写入完整 cookie 串
///（`"key=value"` 或 `"key=value; key2=value2"`；解析口径与 JS 绑定
/// `java.setCookie` 逐段拆分一致：`;` 拆段、首个 `=` 分界、无 `=` 段跳过、
/// 空键跳过、name/value 各 trim 一次）
///
/// 与逐段调 [`set_cookie`] 的差别在**写放大**：多段串仅一次锁内更新 +
/// 至多一次持久化 upsert（逐段调用则每段一次锁 + 一次 upsert）——JS 绑定
/// `java.setCookie(url, cookieStr)` 走本入口。
pub fn set_cookie_str(url: &str, cookie_str: &str) {
    with_store_update(url, |entry| {
        let mut changed = false;
        for pair in cookie_str.split(';') {
            let pair = pair.trim();
            let Some(eq) = pair.find('=') else {
                continue;
            };
            let key = pair[..eq].trim();
            if key.is_empty() {
                continue;
            }
            let value = pair[eq + 1..].trim();
            if entry.get(key).map(String::as_str) != Some(value) {
                changed = true;
            }
            entry.insert(key.to_string(), value.to_string());
        }
        changed
    });
}

/// clearCookies(url) — 清除该 URL 归一域名键的 Cookie，并连带清除
///（不同的）原始串键——覆盖历史遗留的原始 URL 形态键（兼容：存储为
/// 内存态、无迁移负担，读侧同时尝试两候选，清理侧同样两键齐清）
///
/// 持久化下沉（若已注册）：内存两键清除后**对称删除持久行**
///（raw 键 + 归一域名键，幂等）——保证 FFI `clear_cookie` 入口把
/// 「内存 + DB」两侧都清干净。
pub fn clear_cookies(url: &str) {
    let raw = url.trim().to_string();
    let norm = normalize_cookie_key(url);
    let norm_differs = norm != raw;
    // 按域写通道（重要 1）：与同域写方互斥（写方统一锁归一键；raw 键为
    // 历史遗留、无写方锁它），否则「内存清除 + sink 删行」完成后并发写
    // 可复活已清除域（quickjs 档同时挡住 jar 写回路径）
    let _domain_guard = domain_write_guard(&norm);
    {
        let mut store = lock_store();
        store.remove(&raw);
        if norm_differs {
            store.remove(&norm);
        }
    }
    // sink 删行在内存锁（G）释放后执行（不持 cookie 锁跨 DB I/O）；
    // 仍在域通道锁（D）内——保证「清除 + 删行」对同域原子
    if let Some(sink) = COOKIE_SINK.get() {
        sink.remove(&raw);
        if norm_differs {
            sink.remove(&norm);
        }
    }
}

/// 给定 URL 的 cookie 键归一结果（[`normalize_cookie_key`] 的公共包装，
/// 供测试 / 上层断言键形态：quickjs 档 http(s) URL → ETLD+1 域名键，
/// 默认档 → trim 后原串；与写侧归一口径恒等）
pub fn normalized_cookie_key(url: &str) -> String {
    normalize_cookie_key(url)
}

/// 测试支撑（非生产 API）：仅清空**内存** cookie store（不触持久层下沉）
///
/// 用于「模拟进程重启丢失内存态」类测试：重启语义 = 内存态消失、
/// 持久层（DB 行）仍在 → 随后 [`backfill_from_sink`] 必须恢复。生产进程
/// 重启即进程重启，不经此入口；生产级「全量清除」走
/// [`clear_all_cookies`]（内存 + 持久层两侧齐清）。
///
/// **门控（提示 1）**：仅 `cfg(test)`（lib 单测）或 `test-support` feature
/// （`tests/` 集成二进制 / 依赖 crate 的测试，经 dev-dependency 启用）
/// 可见——误用于生产 = 「内存已清、DB 仍在、重启后复活」的语义陷阱。
#[cfg(any(test, feature = "test-support"))]
#[doc(hidden)]
pub fn test_clear_memory_only() {
    let mut store = lock_store();
    store.clear();
}

/// 上游同步（2026-09-23）：序列化请求应携带的 JS 宿主存储 Cookie——
/// 按**请求 URL** 取（对齐上游 `CookieManager.loadRequest` 的
/// `getSubDomain(request.url)` 口径），**无书源 tag 维度**：
///
/// - 请求 URL 的 ETLD+1 域名键条目 +（不同的）请求 URL 原始串条目
///   （历史兼容，原始串胜出）合并为 `name1=value1; name2=value2`（无则空串）；
/// - 同域不同书源共享（cookie 属于域名）；**不相关域名的 cookie 绝不
///   携带**（P2-19 不变式保留）；
/// - 取代 P2-19 `cookies_for_source_tag` 的「未归属不携带」收紧
///   （本批取消，用户裁决）：未归属上下文（字典规则 / 自动任务等）
///   也按请求 URL 所属域携带。
pub fn cookies_for_url(url: &str) -> String {
    let url = url.trim();
    if url.is_empty() {
        return String::new();
    }
    let store = lock_store();
    format_cookies(&merge_cookie_entries(&store, url))
}

/// clearAllCookies() — 清除所有 Cookie
///
/// 持久化下沉（若已注册 [`set_cookie_sink`]）：内存全清后**对称清空持久层**
///（`sink.remove_all`，幂等）——保证「全量清除后回填不得复活」，与
/// [`clear_cookies`] 的「内存 + 持久两侧齐清」口径一致。
pub fn clear_all_cookies() {
    // 按域写通道（重要 1）：注册表锁 + 全部域锁（排序取锁防环；注册表锁
    // 阻塞临界期内的新域注册）——与逐域写方（含 quickjs 档 jar 写回路径）
    // 互斥，否则「全清」完成后并发写可复活已清除域
    let _domain_guards = lock_all_domain_writes();
    {
        let mut store = lock_store();
        store.clear();
    }
    // sink 全清在内存锁（G）释放后执行（不持 cookie 锁跨 DB I/O）；
    // 仍在域通道锁（D）内——保证「全清 + 全删」对全部域原子
    if let Some(sink) = COOKIE_SINK.get() {
        sink.remove_all();
    }
}

/// 将 JS 宿主 cookie 按**键**合并进请求头（对齐上游 `AnalyzeUrl.setCookie`
/// → `CookieManager.mergeCookies` 的按键合并语义：已有同名键胜、非冲突
/// JS 键追加——上游反例：静态 `Cookie: a=1` + JS 写 `b=2` → 发
/// `a=1; b=2`，而非整条丢弃 JS cookie）：
///
/// - 取请求 URL 属域的 JS cookie 串（[`cookies_for_url`]；空 → no-op）；
/// - 已有 Cookie 头（**大小写不敏感**键匹配，覆盖 Cookie/cookie/COOKIE
///   等变体）：按 `;` 拆出已有 cookie 名集，非冲突 JS 键按序追加；
///   结果写回**原键**（保留原键大小写），不新插第二键；
/// - 无已有 Cookie 键 → 直接插 `"Cookie"` 键。
pub fn merge_js_cookies(headers: &mut HashMap<String, String>, url: &str) {
    let js_cookie = cookies_for_url(url);
    if js_cookie.is_empty() {
        return;
    }
    let existing_key = headers
        .keys()
        .find(|k| k.eq_ignore_ascii_case("cookie"))
        .cloned();
    match existing_key {
        Some(key) => {
            let existing = headers.get(&key).map(String::as_str).unwrap_or("");
            // 已有 cookie 名集（cookie 名大小写敏感：按 `;` 拆段取 `=` 前）
            let mut existing_names: std::collections::HashSet<String> = existing
                .split(';')
                .filter_map(|part| {
                    let part = part.trim();
                    if part.is_empty() {
                        return None;
                    }
                    Some(part.split('=').next()?.to_string())
                })
                .collect();
            // 非冲突 JS 键按序追加（同名跳过——已有键胜）
            let mut extra = String::new();
            for pair in js_cookie.split("; ") {
                let name = match pair.split_once('=') {
                    Some((n, _)) => n,
                    None => continue,
                };
                if existing_names.insert(name.to_string()) {
                    if !extra.is_empty() {
                        extra.push_str("; ");
                    }
                    extra.push_str(pair);
                }
            }
            if !extra.is_empty() {
                let combined = if existing.trim().is_empty() {
                    extra
                } else {
                    format!("{existing}; {extra}")
                };
                headers.insert(key, combined);
            }
        }
        None => {
            headers.insert("Cookie".to_string(), js_cookie);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get_cookie() {
        let _lock = lock_cookie_store_test();
        let tag = "cookie_set_get";
        set_cookie(tag, "session", "abc123");
        assert_eq!(get_cookie_by_key(tag, "session"), "abc123");
        assert!(get_cookie(tag).contains("session=abc123"));
    }

    #[test]
    fn test_multiple_cookies() {
        let _lock = lock_cookie_store_test();
        let tag = "cookie_multi";
        set_cookie(tag, "session", "abc");
        set_cookie(tag, "token", "xyz");
        let all = get_cookie(tag);
        assert!(all.contains("session=abc"));
        assert!(all.contains("token=xyz"));
    }

    #[test]
    fn test_tag_isolation() {
        let _lock = lock_cookie_store_test();
        let tag1 = "cookie_iso_1";
        let tag2 = "cookie_iso_2";
        set_cookie(tag1, "key", "val1");
        set_cookie(tag2, "key", "val2");
        assert_eq!(get_cookie_by_key(tag1, "key"), "val1");
        assert_eq!(get_cookie_by_key(tag2, "key"), "val2");
    }

    #[test]
    fn test_missing_cookie() {
        assert_eq!(get_cookie_by_key("cookie_never_set", "key"), "");
        assert_eq!(get_cookie("cookie_never_set"), "");
    }

    #[test]
    fn test_clear_cookies() {
        let _lock = lock_cookie_store_test();
        let tag = "cookie_clear_target";
        set_cookie(tag, "key", "val");
        clear_cookies(tag);
        assert_eq!(get_cookie(tag), "");
    }

    /// 上游同步：空 / 空白 URL 取不到任何 cookie（无请求即无域名键）
    #[test]
    fn test_cookies_for_url_empty_returns_empty() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_none_url", "k", "v");
        assert_eq!(cookies_for_url(""), "");
        assert_eq!(cookies_for_url("   "), "");
        clear_cookies("p219_none_url");
    }

    /// 非 URL 形态的原始串键（两档行为一致：归一为 trim 原串，自键命中）
    #[test]
    fn test_raw_string_key_hit() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_exact", "tk", "v1");
        let out = cookies_for_url("p219_exact");
        assert!(out.contains("tk=v1"), "原始串键 cookie 必须携带: {out}");
        clear_cookies("p219_exact");
    }

    /// 多段 TLD（com.cn）——域名键取末三段（ETLD+1 = book.com.cn，
    /// 前缀 a/b 是子域不属于注册域），不得回落末两段（com.cn）——与 HTTP 层
    /// MULTI_LABEL_TLDS 口径一致
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_multi_label_tld_domain_key() {
        // host a.b.book.com.cn：com.cn 为多段公共后缀 → 键取末三段
        let _lock = lock_cookie_store_test();
        const URL: &str = "https://a.b.book.com.cn/search";
        set_cookie("book.com.cn", "p219_dk", "dk-val");
        // 末两段裸后缀键不得参与（多段 TLD 必须取末三段的证据）
        set_cookie("com.cn", "p219_suffix", "suffix-val");
        let out = cookies_for_url(URL);
        assert!(
            out.contains("p219_dk=dk-val"),
            "ETLD+1（book.com.cn）cookie 必须携带: {out}"
        );
        assert!(
            !out.contains("p219_suffix"),
            "两段 TLD（com.cn）键不得参与: {out}"
        );
        clear_cookies(URL);
        clear_cookies("com.cn");
    }

    /// IP 字面量 host（含 :port）——域名键为 IP 自身（对齐 HTTP 层）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_ip_literal_domain_key() {
        let _lock = lock_cookie_store_test();
        set_cookie("192.168.1.10", "p219_ip", "ip-val");
        let out = cookies_for_url("http://192.168.1.10:8080/api");
        assert!(
            out.contains("p219_ip=ip-val"),
            "IP 字面量键 cookie 必须携带: {out}"
        );
        clear_cookies("192.168.1.10");
    }

    /// 上游同步：裸 host 串（无 scheme，可带 :port）按上游 `getSubDomain`
    /// 回退规则**自键**（`getBaseUrl` 返回 null → 原样返回输入）——不再
    /// 推导 ETLD+1（P2-19 旧口径已废）：写「a.example.com:8080」命中读
    /// 「a.example.com:8080」，而 URL 形态读归一到 example.com，两者不串。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_bare_host_string_is_self_keyed() {
        let _lock = lock_cookie_store_test();
        const BARE: &str = "a.example.com:8080";
        const URL_FORM: &str = "https://a.example.com:8080/";
        set_cookie(BARE, "p219_bare", "bare-val");
        set_cookie("example.com", "p219_url_dk", "url-val");
        let out_bare = cookies_for_url(BARE);
        assert!(
            out_bare.contains("p219_bare=bare-val"),
            "裸 host 串自键命中: {out_bare}"
        );
        assert!(
            !out_bare.contains("p219_url_dk"),
            "裸 host 串自键，不得串到 ETLD+1 域名键: {out_bare}"
        );
        let out_url = cookies_for_url(URL_FORM);
        assert!(
            out_url.contains("p219_url_dk=url-val"),
            "URL 形态读归一 ETLD+1（example.com）命中: {out_url}"
        );
        assert!(
            !out_url.contains("p219_bare"),
            "URL 形态读不得串到裸 host 串键: {out_url}"
        );
        clear_cookies(BARE);
        clear_cookies("example.com");
    }

    /// 上游同步：同域同名 cookie 后写覆盖先写（归一后两次写入落同一域名键，
    /// 对齐上游 `CookieStore` REPLACE 语义；按 name 合并时后写胜出）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_same_domain_same_name_last_write_wins() {
        // host c.d.shop.co.uk：co.uk 为多段公共后缀 → 域名键取末三段 shop.co.uk
        let _lock = lock_cookie_store_test();
        const URL: &str = "https://c.d.shop.co.uk/";
        set_cookie("shop.co.uk", "dup", "domain-v");
        set_cookie(URL, "dup", "exact-v");
        let out = cookies_for_url(URL);
        assert!(out.contains("dup=exact-v"), "后写必须覆盖: {out}");
        assert!(!out.contains("domain-v"), "先写同名值必须被覆盖: {out}");
        clear_cookies(URL);
        clear_cookies("shop.co.uk");
    }

    // ─── 上游同步（2026-09-23 用户裁决）：cookie 属于域名，不属于书源 ─────────────
    //
    // 以下用例按上游语义（写侧归一 `getSubDomain(url)` 域名键、读侧按请求 URL 取、
    // 去掉书源 tag 维度）断言。场景①/②/⑤ 改前按旧 `cookies_for_source_tag`
    // （tag 维度）行为为红（红输出见批次报告），改造后转绿。

    /// 上游同步场景①：同域跨书源共享——源 A 写 cookie，同注册域的源 B 请求
    /// 该域 URL 必须携带（cookie 属于域名，跨书源共享）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_upstream_sync_same_domain_cross_source_sharing() {
        // host www.usa-shop-a.com.cn / api.usa-shop-a.com.cn：com.cn 多段 TLD
        // → 域名键取末三段 usa-shop-a.com.cn（同一注册域，两个不同书源 URL）
        let _lock = lock_cookie_store_test();
        const SRC_A: &str = "https://www.usa-shop-a.com.cn/";
        const SRC_B: &str = "https://api.usa-shop-a.com.cn/login";
        const DK: &str = "usa-shop-a.com.cn";
        clear_cookies(SRC_A);
        clear_cookies(DK);
        set_cookie(SRC_A, "p219_sync", "sync-val-8d21");
        // 源 B 上下文请求同域 URL（读侧按请求 URL 归一域名键，与书写者无关）
        let out = cookies_for_url(SRC_B);
        assert!(
            out.contains("p219_sync=sync-val-8d21"),
            "同域跨书源必须共享 cookie（上游语义：cookie 属于域名）: {out}"
        );
        clear_cookies(SRC_A);
        clear_cookies(DK);
    }

    /// 上游同步场景②：非本源 URL 写的 cookie（`java.setCookie('https://api.…', …)`
    /// 第三方域写入缺口）——后续请求该域必须携带（改前缺口：写落原始串键，
    /// 读按 tag / 未归属取 → 落空）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_upstream_sync_thirdparty_url_cookie_carried() {
        let _lock = lock_cookie_store_test();
        const WRITE_URL: &str = "https://api.usa-thirdparty.com/";
        const REQ_URL: &str = "https://api.usa-thirdparty.com/v2/items";
        const DK: &str = "usa-thirdparty.com";
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
        set_cookie(WRITE_URL, "p219_tp", "tp-val-4b7c");
        // 请求该域的其他 URL（不同路径）：写读两侧归一到同一域名键
        let out = cookies_for_url(REQ_URL);
        assert!(
            out.contains("p219_tp=tp-val-4b7c"),
            "按请求 URL 属域取 cookie 时，第三方域写入的 cookie 必须携带: {out}"
        );
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
    }

    /// 上游同步场景⑤：无书源上下文的 JS 执行路径（字典规则/自动任务）向某域
    /// 发请求时携带该域 cookie——P2-19 的「未归属不携带」收紧本批取消
    ///（用户裁决同步上游：上游 `CookieManager.loadRequest` 按请求 URL 取 cookie，
    /// 与书源上下文无关）。
    /// 纯单测（无网络）：127.0.0.3 的域名键为 IP 自身。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_upstream_sync_unowned_context_carries_request_domain_cookie() {
        let _lock = lock_cookie_store_test();
        const WRITE_URL: &str = "http://127.0.0.3:8080/";
        const REQ_URL: &str = "http://127.0.0.3:8080/echo";
        const DK: &str = "127.0.0.3";
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
        set_cookie(WRITE_URL, "p219_un", "un-val-3f7d");
        // 未归属上下文（无书源绑定）：读侧只看请求 URL 属域
        let out = cookies_for_url(REQ_URL);
        assert!(
            out.contains("p219_un=un-val-3f7d"),
            "未归属上下文请求 127.0.0.3 域时必须携带该域 cookie: {out}"
        );
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
    }

    // ─── 按键合并（对齐上游 AnalyzeUrl.setCookie → CookieManager.mergeCookies）──
    //
    // 以下用例用非 URL 裸串键（双档归一均为 trim 原串自键，行为一致，
    // 不设 feature 门控），钉住「已有键胜、非冲突追加、大小写不敏感
    // 键查找、无已有键插 Cookie」四条语义。

    /// 无已有 Cookie 键 → 直接插 `"Cookie"` 键
    #[test]
    fn test_merge_js_cookies_no_existing_inserts_cookie_key() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_new", "a", "1");
        let mut headers: HashMap<String, String> = HashMap::new();
        merge_js_cookies(&mut headers, "p219_merge_new");
        assert_eq!(headers.get("Cookie").map(String::as_str), Some("a=1"));
        clear_cookies("p219_merge_new");
    }

    /// 非冲突键追加（上游反例：静态 `Cookie: x=0` + JS `a=1; b=2` →
    /// 发 `x=0; a=1; b=2`，而非仅 `x=0`）
    #[test]
    fn test_merge_js_cookies_appends_nonconflicting_keys() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_append", "a", "1");
        set_cookie("p219_merge_append", "b", "2");
        let mut headers = HashMap::from([("Cookie".to_string(), "x=0".to_string())]);
        merge_js_cookies(&mut headers, "p219_merge_append");
        let cookie = headers.get("Cookie").map(String::as_str).unwrap_or("");
        assert!(cookie.starts_with("x=0; "), "已有值必须保留在前: {cookie}");
        assert!(cookie.contains("a=1"), "非冲突键 a 必须追加: {cookie}");
        assert!(cookie.contains("b=2"), "非冲突键 b 必须追加: {cookie}");
        clear_cookies("p219_merge_append");
    }

    /// 同名键：已有 header 值胜（JS 不覆盖），非冲突键仍追加
    #[test]
    fn test_merge_js_cookies_existing_key_wins() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_win", "a", "9");
        set_cookie("p219_merge_win", "b", "2");
        let mut headers = HashMap::from([("Cookie".to_string(), "a=1".to_string())]);
        merge_js_cookies(&mut headers, "p219_merge_win");
        let cookie = headers.get("Cookie").map(String::as_str).unwrap_or("");
        assert!(cookie.contains("a=1"), "已有键 a 必须保留既有值: {cookie}");
        assert!(!cookie.contains("a=9"), "JS 不得覆盖已有同名键: {cookie}");
        assert!(cookie.contains("b=2"), "非冲突键 b 必须追加: {cookie}");
        clear_cookies("p219_merge_win");
    }

    /// 已有键大小写变体（小写 `cookie`）：原键保留、不新插 `Cookie` 键
    #[test]
    fn test_merge_js_cookies_preserves_existing_key_case() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_case", "b", "2");
        let mut headers = HashMap::from([("cookie".to_string(), "a=1".to_string())]);
        merge_js_cookies(&mut headers, "p219_merge_case");
        assert!(headers.contains_key("cookie"), "已有小写键必须保留");
        assert!(!headers.contains_key("Cookie"), "不得新插大写 Cookie 键");
        let cookie = headers.get("cookie").map(String::as_str).unwrap_or("");
        assert!(cookie.contains("b=2"), "非冲突键必须追加到原键: {cookie}");
        clear_cookies("p219_merge_case");
    }

    /// P2-19 不变式（本批保留，改前改后均绿）：不相关域名的 cookie 绝不携带。
    #[test]
    fn test_p219_unrelated_domain_cookie_never_carried() {
        // iso-a.com.cn 域写入；iso-b.com.cn 域请求 → 必须落空
        let _lock = lock_cookie_store_test();
        const WRITE_URL: &str = "https://www.iso-a.com.cn/";
        const READ_URL: &str = "https://www.iso-b.com.cn/x";
        const DK: &str = "iso-a.com.cn";
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
        set_cookie(WRITE_URL, "p219_iso", "iso-val-9a4e");
        // 异域请求：iso-b.com.cn 域名键 / 原始串候选均取不到 iso-a.com.cn 的 cookie
        let out = cookies_for_url(READ_URL);
        assert!(
            !out.contains("p219_iso=iso-val-9a4e"),
            "不相关域名的 cookie 绝不携带（P2-19 不变式）: {out}"
        );
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
    }
}

// ─── 持久化下沉（sink）测试 ─────────────────────────────────────────────────────
//
// 对齐上游 2026-09-23 裁决：JS 写入 cookie 落持久层（域名键 → 合并后完整串），
// 重启回填命中；清除两侧齐清；值不变不写（写放大缓解）。用例持
// `lock_cookie_store_test()` 串行（sink 计数为相对增量断言，须排除其他
// 用例的并发 cookie 写入）。

#[cfg(test)]
mod sink_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// 进程共享记录型下沉（OnceLock first-wins：本测试二进制内所有用例共享
    /// 同一实例；断言用**相对增量 + 唯一域名键**，不受他例写入干扰）
    static SINK_STORE: LazyLock<Mutex<HashMap<String, String>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));
    static UPSERTS: AtomicUsize = AtomicUsize::new(0);
    static REMOVALS: AtomicUsize = AtomicUsize::new(0);
    static REMOVE_ALLS: AtomicUsize = AtomicUsize::new(0);

    struct RecordingSink;

    impl CookieSink for RecordingSink {
        fn upsert(&self, domain_key: &str, cookie_str: &str) {
            UPSERTS.fetch_add(1, Ordering::SeqCst);
            SINK_STORE
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(domain_key.to_string(), cookie_str.to_string());
        }
        fn remove(&self, domain_key: &str) {
            REMOVALS.fetch_add(1, Ordering::SeqCst);
            SINK_STORE
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .remove(domain_key);
        }
        fn remove_all(&self) {
            REMOVE_ALLS.fetch_add(1, Ordering::SeqCst);
            SINK_STORE.lock().unwrap_or_else(|p| p.into_inner()).clear();
        }
        fn load_all(&self) -> Vec<(String, String)> {
            SINK_STORE
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .clone()
                .into_iter()
                .collect()
        }
    }

    fn register_sink() {
        let _ = set_cookie_sink(Arc::new(RecordingSink));
    }

    fn sink_row(key: &str) -> Option<String> {
        SINK_STORE
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(key)
            .cloned()
    }

    /// cookie 串按 `;` 拆段集合（HashMap 迭代序不保证，按键集合比较）
    fn cookie_set(s: &str) -> Vec<String> {
        let mut parts: Vec<String> = s
            .split(';')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        parts.sort();
        parts
    }

    /// 写回 + 落库自洽 + 重启回填：同名键覆盖、异名键保留、落库串 == 内存串
    #[test]
    fn test_sink_roundtrip_merge_self_consistent() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_rt";
        clear_cookies(KEY); // 清理残留（幂等）
        set_cookie(KEY, "a", "1");
        set_cookie(KEY, "b", "2");
        let persisted = sink_row(KEY).expect("写入后 sink 必须有持久行");
        assert_eq!(
            cookie_set(&persisted),
            cookie_set(&get_cookie(KEY)),
            "落库串必须与内存串按键相等（重启后从 DB 恢复 = 重启前内存态）"
        );
        // 同名键覆盖（异名键保留）
        set_cookie(KEY, "a", "3");
        let persisted = sink_row(KEY).expect("覆盖写后持久行必须更新");
        assert!(
            cookie_set(&persisted).contains(&"a=3".to_string()),
            "同名键后写必须覆盖: {persisted}"
        );
        assert!(
            !cookie_set(&persisted).contains(&"a=1".to_string()),
            "同名键旧值必须被覆盖: {persisted}"
        );
        assert!(
            cookie_set(&persisted).contains(&"b=2".to_string()),
            "异名键必须保留: {persisted}"
        );
        // 模拟重启：仅丢弃内存 store（持久行仍在）→ 回填 → 必须命中
        test_clear_memory_only();
        assert_eq!(get_cookie(KEY), "");
        backfill_from_sink();
        assert_eq!(
            cookie_set(&get_cookie(KEY)),
            cookie_set(&persisted),
            "回填后内存态必须等于重启前持久串"
        );
        clear_cookies(KEY);
    }

    /// 值不变重写跳过持久化写回（写放大缓解：JS 循环内重复 set 不刷 DB）
    #[test]
    fn test_sink_skip_unchanged_write() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_skip";
        clear_cookies(KEY);
        let before = UPSERTS.load(Ordering::SeqCst);
        set_cookie(KEY, "a", "1");
        assert_eq!(
            UPSERTS.load(Ordering::SeqCst),
            before + 1,
            "值变化必须触发持久化写回"
        );
        set_cookie(KEY, "a", "1");
        assert_eq!(
            UPSERTS.load(Ordering::SeqCst),
            before + 1,
            "同名同值重写不得触发持久化写"
        );
        set_cookie(KEY, "c", "4");
        assert_eq!(UPSERTS.load(Ordering::SeqCst), before + 2);
        clear_cookies(KEY);
    }

    /// clear_cookies 两侧齐清（内存 + 持久行，raw 键与归一键），回填后仍无残留
    #[test]
    fn test_sink_clear_removes_persisted() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_clr";
        set_cookie(KEY, "a", "1");
        assert!(sink_row(KEY).is_some(), "写入后必须有持久行");
        let before = REMOVALS.load(Ordering::SeqCst);
        clear_cookies(KEY);
        assert!(
            REMOVALS.load(Ordering::SeqCst) > before,
            "clear_cookies 必须触发 sink 删除"
        );
        assert!(sink_row(KEY).is_none(), "持久行必须被删除");
        assert_eq!(get_cookie(KEY), "");
        backfill_from_sink();
        assert_eq!(get_cookie(KEY), "", "回填后不得复活已清除域");
    }

    /// 回填内存优先：同名键既有内存值胜出（不覆盖），DB 独有键补齐
    #[test]
    fn test_sink_backfill_memory_first() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_memo";
        clear_cookies(KEY);
        set_cookie(KEY, "x", "mem"); // 内存 x=mem，sink 行 "x=mem"
                                     // 直接改写记录 map 模拟「DB 行与内存态不一致」（DB 侧有 x=db 旧值 + y=3 独有键）
        SINK_STORE
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(KEY.to_string(), "x=db; y=3".to_string());
        backfill_from_sink();
        let out = get_cookie(KEY);
        assert!(
            cookie_set(&out).contains(&"x=mem".to_string()),
            "同名键内存值必须胜出（内存优先、不覆盖）: {out}"
        );
        assert!(
            !cookie_set(&out).contains(&"x=db".to_string()),
            "DB 旧值不得覆盖内存新值: {out}"
        );
        assert!(
            cookie_set(&out).contains(&"y=3".to_string()),
            "DB 独有键必须补齐（miss 回落）: {out}"
        );
        clear_cookies(KEY);
    }

    /// set_cookie_sink first-wins：重复注册被忽略
    #[test]
    fn test_set_cookie_sink_first_wins() {
        register_sink();
        assert!(
            !set_cookie_sink(Arc::new(RecordingSink)),
            "已注册后重复注册必须被忽略"
        );
    }

    /// set_cookie_str 批量写回：多段串一次锁内更新 + 至多一次持久化
    /// upsert（逐段 set_cookie 则每段一次——写放大的批量化收敛）
    #[test]
    fn test_sink_batch_write_single_upsert() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_batch";
        clear_cookies(KEY);
        let before = UPSERTS.load(Ordering::SeqCst);
        set_cookie_str(KEY, "a=1; b=2; c=3");
        assert_eq!(
            UPSERTS.load(Ordering::SeqCst),
            before + 1,
            "三段串必须只触发一次持久化 upsert"
        );
        assert_eq!(
            cookie_set(&sink_row(KEY).expect("批量写后必须有持久行")),
            cookie_set(&get_cookie(KEY)),
            "批量落库串必须与内存串按键相等"
        );
        // 全同值重写 → 零 upsert（值不变写跳过，批量口径同单段口径）
        set_cookie_str(KEY, "a=1; b=2; c=3");
        assert_eq!(
            UPSERTS.load(Ordering::SeqCst),
            before + 1,
            "全同值批量重写不得触发持久化写"
        );
        // 部分变化 → 一次 upsert，异名键保留
        set_cookie_str(KEY, "b=9; d=4");
        assert_eq!(UPSERTS.load(Ordering::SeqCst), before + 2);
        let persisted = cookie_set(&sink_row(KEY).expect("部分变化后持久行必须更新"));
        assert!(
            persisted.contains(&"b=9".to_string()),
            "变化键必须更新: {persisted:?}"
        );
        assert!(
            persisted.contains(&"a=1".to_string()) && persisted.contains(&"d=4".to_string()),
            "异名键必须保留/补齐: {persisted:?}"
        );
        clear_cookies(KEY);
    }

    /// set_cookie_str 解析口径镜像 JS 绑定：无 `=` 段跳过、空键跳过、
    /// name/value 各 trim 一次
    #[test]
    fn test_sink_batch_parse_mirrors_binding() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_batch_parse";
        clear_cookies(KEY);
        set_cookie_str(KEY, " a = 1 ; junk_noeq ; =empty ; x= 5 ");
        let out = cookie_set(&get_cookie(KEY));
        assert!(
            out.contains(&"a=1".to_string()),
            "trim 后键值必须落库: {out:?}"
        );
        assert!(
            out.contains(&"x=5".to_string()),
            "value 侧 trim 必须生效: {out:?}"
        );
        assert_eq!(
            get_cookie_by_key(KEY, ""),
            "",
            "空键段必须跳过（不得落空键行）"
        );
        // 段内无 `=`（junk_noeq）按绑定口径跳过（不进存储）
        assert!(
            !out.iter().any(|p| p.starts_with("junk_noeq")),
            "无 = 段必须跳过: {out:?}"
        );
        clear_cookies(KEY);
    }

    /// 重要 2：回填归一键、跳过非归一行——历史原始 URL 键行不得遮蔽新写
    ///
    /// 反例（修复前必红）：历史 DB 行以原始 URL 为键（`"https://legacy.shadow.test/"`
    /// = `"token=OLD"`）被**原样**回填成原始键条目；读侧 `merge_cookie_entries`
    /// 原始键优先 → `set_cookie`（写归一域名键 `legacy.shadow.test`）的新值
    /// 被旧值永久遮蔽，`get_cookie` 恒返 OLD。修复后（回填按归一键校验、
    /// 跳过非归一行）：读必须命中新值 NEW。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_backfill_skips_legacy_raw_url_row_no_shadowing() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const URL: &str = "https://legacy.shadow.test/";
        let dk = normalized_cookie_key(URL);
        assert_ne!(
            dk, URL,
            "前提：原始 URL 键的归一结果必须与原始键不同（否则本用例无意义）"
        );
        // 清残留（幂等）
        clear_cookies(URL);
        // 预置历史原始 URL 键行（模拟旧版本 DB 行：直接写记录表，
        // 绕过归一键写路径——真实 DB 里该形态行只可能来自历史批次）
        SINK_STORE
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(URL.to_string(), "token=OLD".to_string());
        // 启动回填
        backfill_from_sink();
        // JS 写新值（落归一域名键）
        set_cookie(URL, "token", "NEW");
        // 读必须命中新值（原始键行不得遮蔽）
        assert_eq!(
            get_cookie(URL),
            "token=NEW",
            "历史原始 URL 键行回填后不得遮蔽新写值（修复前读侧原始键优先 → 恒返 OLD）"
        );
        // 清理
        clear_cookies(URL);
        SINK_STORE
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(URL);
    }

    /// clear_all_cookies 两侧齐清（内存 + 持久层全清），回填后不复活
    #[test]
    fn test_clear_all_covers_persistence_no_resurrection() {
        let _lock = lock_cookie_store_test();
        register_sink();
        const KEY: &str = "p219_sink_clearall";
        set_cookie(KEY, "a", "1");
        assert!(sink_row(KEY).is_some(), "写入后必须有持久行");
        let before = REMOVE_ALLS.load(Ordering::SeqCst);
        clear_all_cookies();
        assert_eq!(
            REMOVE_ALLS.load(Ordering::SeqCst),
            before + 1,
            "全量清除必须触发 sink 全清"
        );
        assert!(
            sink_row(KEY).is_none(),
            "全量清除后持久行必须删除（不得残留）"
        );
        backfill_from_sink();
        assert_eq!(get_cookie(KEY), "", "全量清除 + 回填后不得复活已清除域");
    }
}
