//! App Cookie 罐 ↔ reqwest `CookieService` 适配器（P2-2 单罐根治，方案 B2）
//!
//! # 背景（调研 `docs/audit_20261113/REPORT_Cookie双罐.md`）
//!
//! 改造前进程内存在三份互不同步的 cookie 内存态：
//! ① reqwest 内置 jar（`.cookie_store(true)`）、② App 罐
//! [`CookieStore`]、③ `legado-js` 的 `GLOBAL_COOKIES`。reqwest 的
//! `CookieService` 位于 `FollowRedirect` **内层**（每跳注入 + 每跳写回），
//! 因此 3xx 的 `Set-Cookie` 只进①，App/DB/JS 全部看不见；且显式
//! `Cookie` 请求头会让 reqwest **完全跳过**①的注入（`cookie.rs` 注入条件
//! 是「请求没有 Cookie 头」）——罐②对该域有任意 cookie 时即屏蔽，产生
//! 「302 下新会话 → 下一跳仍带旧会话」的登录死循环。
//!
//! # 本模块的解法
//!
//! - 关闭 reqwest 内置 jar，改用 [`reqwest::ClientBuilder::cookie_provider`]
//!   把 App 罐（[`CookieStore`]）适配成 [`reqwest::cookie::CookieStore`]
//!   （[`AppCookieJar`]）——存储器变成罐②，reqwest 依旧逐跳执行，
//!   于是**逐跳写入罐② + 逐跳注入**天然成立，重定向/方法改写/超时/重试
//!   语义完全留在 reqwest，不在本仓重写；
//! - 写侧门控（`CookieJar` 标记）与「规则/JS/登录头 Cookie 覆盖」通过
//!   **请求级上下文** [`CookieRequestContext`] 传递：reqwest 的 provider
//!   回调只拿得到 `(headers, url)`，拿不到请求头，故用 `tokio::task_local!`
//!   在发送 future 的作用域内存放上下文；
//! - [`AppCookieJar::cookies`] 把「罐②视图 + 规则 overlay」按键合并输出为
//!   `Cookie` 头（overlay 优先，保留 P1-2「规则优先」语义）；本次链中已被
//!   响应刷新过的同名键让罐②新值接管（`updated`），即「首跳规则优先、
//!   链内新值接管」；
//! - 每条 `Set-Cookie` 全量解析（不折叠），按域串行锁（D）写罐② + 持久化，
//!   释放 D 后经全局 [`CookieWriteObserver`] 通知 JS 罐写穿。
//!
//! # 锁纪律（与 `cookie_store::DOMAIN_WRITE_LOCKS` 文档一致）
//!
//! D（按域串行锁，最外层；其下允许 DB I/O）→ J（jar 写锁，短临界区，
//! 不做 I/O）→ 释放 J → 持久化（DB）→ 释放 D → observer（JS 罐 G 锁）。
//! **observer 必须在 D 释放之后调用**：JS 侧写路径的锁序是 D→G，若在持 D
//! 时取 G，会与「持 G 等 D」的 JS 写方形成 ABBA（`std::sync::Mutex` 不可
//! 重入，见 `legado-js` cookie_store.rs 的同类警告）。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use reqwest::cookie::CookieStore as ReqwestCookieStore;
use reqwest::header::HeaderValue;
use url::Url;

use crate::cookie_store::{
    cookie_domain_key, domain_write_lock, Cookie, CookiePersistence, CookieStore,
};

/// 请求级 cookie 上下文（`tokio::task_local!` 存放）
///
/// 一个**逻辑请求**（含客户端级重试的每次尝试、含 reqwest 自动跟随的每一跳）
/// 共享同一实例；`updated` 在每次尝试开始时清空（重试视为新的一次链）。
#[derive(Debug)]
pub struct CookieRequestContext {
    /// 写侧门控（对齐上游 `HttpHelper.kt:86-97`：请求头带 `CookieJar` 标记
    /// 才把响应 `Set-Cookie` 写回 jar/DB）
    save: bool,
    /// overlay 的归属域名键（ETLD+1）。跨站重定向后 `cookies(url)` 的域键
    /// 不再匹配，overlay 自动不生效（规则/登录 Cookie 不跨站泄漏）
    overlay_domain: Option<String>,
    /// 规则 / JS / loginHeader 带来的 `Cookie`（`name → value`，规则优先）
    overlay: HashMap<String, String>,
    /// 本次尝试链中已被响应刷新过的 cookie 名（域键 → 名字集合）
    updated: Mutex<HashMap<String, HashSet<String>>>,
    /// 本次逻辑请求是否有过任何一次 provider 写入（供最终响应兜底写回去重，
    /// 避免同一响应重复落库）
    wrote: AtomicBool,
}

impl CookieRequestContext {
    /// 构造请求级上下文
    ///
    /// `save`：写侧门控；`overlay_domain`/`overlay`：来自调用方 `Cookie` 头
    /// （见 [`crate::client::LegadoClient::build_cookie_context`]）。
    pub fn new(
        save: bool,
        overlay_domain: Option<String>,
        overlay: HashMap<String, String>,
    ) -> Self {
        Self {
            save,
            overlay_domain,
            overlay,
            updated: Mutex::new(HashMap::new()),
            wrote: AtomicBool::new(false),
        }
    }

    /// 开始一次新的发送尝试：清空 `updated`（重试 = 新的一次重定向链）
    pub fn begin_attempt(&self) {
        self.updated
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clear();
    }

    /// 本次逻辑请求是否已由 provider 写过罐（任一跳/任一次尝试）
    pub fn wrote_any(&self) -> bool {
        self.wrote.load(Ordering::Relaxed)
    }

    fn record_updated(&self, domain: &str, names: impl IntoIterator<Item = String>) {
        let mut guard = self.updated.lock().unwrap_or_else(|p| p.into_inner());
        let entry = guard.entry(domain.to_string()).or_default();
        for name in names {
            entry.insert(name);
        }
    }

    fn updated_names(&self, domain: &str) -> HashSet<String> {
        self.updated
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(domain)
            .cloned()
            .unwrap_or_default()
    }
}

tokio::task_local! {
    /// 当前发送 future 的请求级 cookie 上下文
    ///
    /// 由 [`with_cookie_context`] 在每次 `req.send()` 前后设置/清除；
    /// provider 回调（reqwest 在 poll 内同步调用）经 `try_with` 读取。
    static COOKIE_REQUEST_CONTEXT: Arc<CookieRequestContext>;
}

/// 在给定请求级上下文作用域内执行发送 future
///
/// 必须在**每一次** `req.send().await` 外层使用（8 个请求工厂与三处
/// 内联重试路径），否则 provider 写侧门控/overlay 失效。
pub async fn with_cookie_context<F>(ctx: Arc<CookieRequestContext>, f: F) -> F::Output
where
    F: std::future::Future,
{
    COOKIE_REQUEST_CONTEXT.scope(ctx, f).await
}

fn current_context() -> Option<Arc<CookieRequestContext>> {
    COOKIE_REQUEST_CONTEXT.try_with(Arc::clone).ok()
}

/// App Cookie 罐的 reqwest 适配器
///
/// 每个 `reqwest::Client` 一份（派生客户端如 `no_redirect_variant` 各自
/// 新建，但**共享同一 `Arc<RwLock<CookieStore>>`**——不产生第二份状态）。
pub struct AppCookieJar {
    store: Arc<RwLock<CookieStore>>,
    persistence: Option<Arc<dyn CookiePersistence>>,
}

impl AppCookieJar {
    /// 以既有 App 罐（与可选持久化后端）构造适配器
    pub fn new(
        store: Arc<RwLock<CookieStore>>,
        persistence: Option<Arc<dyn CookiePersistence>>,
    ) -> Self {
        Self { store, persistence }
    }
}

impl ReqwestCookieStore for AppCookieJar {
    /// reqwest 对**每一跳**响应调用（`CookieService::ResponseFuture::poll`）
    ///
    /// - 无上下文 / `save=false` → 整体跳过（写侧门控，对齐上游网络拦截器）；
    /// - 全量迭代 `Set-Cookie`（不折叠多条），逐条解析 `name=value`；
    /// - 走 [`persist_cookie_pairs`]：D 锁 → 写罐② → 持久化 → 释放 D →
    ///   通知 JS 罐写穿。
    fn set_cookies(&self, cookie_headers: &mut dyn Iterator<Item = &HeaderValue>, url: &Url) {
        let Some(ctx) = current_context() else {
            return;
        };
        if !ctx.save {
            return;
        }
        let Some(domain) = cookie_domain_key(url.as_str()) else {
            return;
        };
        let pairs: Vec<(String, String)> = cookie_headers
            .filter_map(|value| value.to_str().ok())
            .filter_map(parse_set_cookie_pair)
            .collect();
        if pairs.is_empty() {
            return;
        }
        let view = persist_cookie_pairs(&self.store, self.persistence.as_deref(), &domain, &pairs);
        ctx.record_updated(&domain, pairs.into_iter().map(|(name, _)| name));
        // 仅在确实写入成功（写入后视图非空）时标记，避免罐写锁中毒等异常
        // 情况下让最终响应兜底写回被误跳过
        if !view.is_empty() {
            ctx.wrote.store(true, Ordering::Relaxed);
        }
    }

    /// reqwest 对**每一跳**请求调用（仅当请求没有显式 `Cookie` 头）
    ///
    /// 输出「罐②该域视图 + 规则 overlay（overlay 优先；本次链已被响应
    /// 刷新的同名键让罐②新值接管）」。
    fn cookies(&self, url: &Url) -> Option<HeaderValue> {
        let domain = cookie_domain_key(url.as_str())?;
        // 先释放 J 读锁再取 ctx.updated（避免 J ↔ updated 交叉持锁）
        let base = {
            let store = self.store.read().unwrap_or_else(|p| p.into_inner());
            store.domain_cookie_string(&domain)
        };
        let ctx = current_context();
        let merged = merge_overlay_cookie_string(&base, &domain, ctx.as_deref());
        if merged.is_empty() {
            return None;
        }
        match HeaderValue::from_str(&merged) {
            Ok(value) => Some(value),
            Err(e) => {
                // Cookie 值含非可见 ASCII（畸形服务器/规则）：不发该请求的
                // Cookie 头，避免 panic（对齐 reqwest 自身的空值兜底方向）
                log::debug!("cookie 头构造失败（已跳过本次注入）: {e}");
                None
            }
        }
    }
}

/// 合并「罐视图 + overlay」为 `Cookie` 头字符串
///
/// - overlay 域键不匹配（跨站重定向）→ 只用罐视图；
/// - `updated` 中的名字 → 保留罐视图（本次链的新值，不被 overlay 旧值压制）；
/// - 其余 overlay 键 → 覆盖罐视图同名值（P1-2 规则优先），并追加罐视图
///   中 overlay 未覆盖的键。
pub(crate) fn merge_overlay_cookie_string(
    base: &str,
    domain: &str,
    ctx: Option<&CookieRequestContext>,
) -> String {
    let Some(ctx) = ctx else {
        return base.to_string();
    };
    if ctx.overlay.is_empty() || ctx.overlay_domain.as_deref() != Some(domain) {
        return base.to_string();
    }
    let updated = ctx.updated_names(domain);
    let mut map = CookieStore::cookie_string_to_map(base);
    for (name, value) in &ctx.overlay {
        if !updated.contains(name) {
            map.insert(name.clone(), value.clone());
        }
    }
    CookieStore::map_to_cookie_string(&map).unwrap_or_default()
}

/// 解析单条 `Set-Cookie` 的 `name=value` 部分（属性段丢弃）
///
/// 与改造前 `save_cookies_from_response` 的口径逐字一致：`;` 拆段取首段、
/// 无 `=` 跳过、name/value 各 trim。`Max-Age=0` 删除语义**未实现**（既有
/// 遗留项，见调研报告 §八.3）。
///
/// provider 逐跳写回与最终响应兜底写回**共用本解析器**（单一真源）。
pub(crate) fn parse_set_cookie_pair(raw: &str) -> Option<(String, String)> {
    let first = raw.split(';').next()?.trim();
    let (name, value) = first.split_once('=')?;
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    Some((name.to_string(), value.trim().to_string()))
}

/// 写入 App 罐 + 持久化 + JS 罐写穿（provider 与最终响应兜底共用）
///
/// 锁纪律（见模块文档）：D → J（写罐 + 捕获全量视图）→ 释放 J → 持久化
/// （仍在 D 内）→ 释放 D → observer。空视图不落库（`cookies` 行与 JS 侧
/// 共享，空视图仅说明本次未贡献可解析 name=value，不能证明 jar 独占该行）。
///
/// 返回写后该域的全量 cookie 串（供调用方断言/记录）。
pub(crate) fn persist_cookie_pairs(
    store: &Arc<RwLock<CookieStore>>,
    persistence: Option<&dyn CookiePersistence>,
    domain: &str,
    pairs: &[(String, String)],
) -> String {
    if pairs.is_empty() {
        return String::new();
    }
    let domain_guard = domain_write_lock(domain);
    let view = {
        let Ok(mut guard) = store.write() else {
            // 写锁 poisoned：与改造前一致，整体跳过本次写回
            return String::new();
        };
        for (name, value) in pairs {
            guard.set_cookie(Cookie {
                name: name.clone(),
                value: value.clone(),
                domain: domain.to_string(),
                path: "/".to_string(),
                expires: None,
                secure: false,
                http_only: false,
            });
        }
        guard.domain_cookie_string(domain)
    };

    if let Some(persistence) = persistence {
        if !view.is_empty() {
            persistence.save(domain, &view);
        }
    }

    // 显式释放 D：observer（JS 罐）只取 G 锁，不得在持 D 时调用
    drop(domain_guard);

    if !view.is_empty() {
        notify_cookie_write(domain, &view);
    }
    view
}

// ─── HTTP → JS 罐写穿（observer） ───────────────────────────────────────────

/// Cookie 写回观察者（HTTP 层写罐②/DB 后通知上层镜像到 JS 罐）
///
/// 目的：`java.getCookie` 读的是 `legado-js` 的 `GLOBAL_COOKIES`（罐③），
/// 运行期与罐②无同步——HTTP 层（含 3xx 逐跳）新写入的 cookie 必须写穿，
/// 否则「登录成功后立刻在 JS 里取 token」的源失败（调研报告 §2.5）。
pub trait CookieWriteObserver: Send + Sync {
    /// 某域全量 cookie 串已写入罐②并落库（D 锁**已释放**）
    fn on_cookies_saved(&self, domain: &str, cookie_string: &str);
}

/// 全局观察者（first-wins，仿 [`CookiePersistence`] 的注入方向）
static COOKIE_WRITE_OBSERVER: OnceLock<Arc<dyn CookieWriteObserver>> = OnceLock::new();

/// 注册 Cookie 写回观察者（first-wins，重复注册被忽略）
///
/// 返回 `true` = 实际注册成功；`false` = 已有观察者（忽略）。
pub fn set_cookie_write_observer(observer: Arc<dyn CookieWriteObserver>) -> bool {
    COOKIE_WRITE_OBSERVER.set(observer).is_ok()
}

fn notify_cookie_write(domain: &str, cookie_string: &str) {
    if let Some(observer) = COOKIE_WRITE_OBSERVER.get() {
        observer.on_cookies_saved(domain, cookie_string);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(overlay_domain: &str, overlay: &[(&str, &str)]) -> CookieRequestContext {
        CookieRequestContext::new(
            true,
            Some(overlay_domain.to_string()),
            overlay
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        )
    }

    fn as_map(s: &str) -> HashMap<String, String> {
        CookieStore::cookie_string_to_map(s)
    }

    #[test]
    fn test_merge_overlay_without_context_returns_base() {
        assert_eq!(
            merge_overlay_cookie_string("a=1; b=2", "example.com", None),
            "a=1; b=2"
        );
    }

    #[test]
    fn test_merge_overlay_rule_priority_same_name() {
        // 规则 overlay 覆盖罐视图同名键（P1-2）；非冲突键两侧都保留
        let c = ctx("example.com", &[("b", "rule"), ("c", "rule")]);
        let merged = merge_overlay_cookie_string("a=1; b=2", "example.com", Some(&c));
        let map = as_map(&merged);
        assert_eq!(map.get("a"), Some(&"1".to_string()));
        assert_eq!(
            map.get("b"),
            Some(&"rule".to_string()),
            "规则应覆盖同名: {merged}"
        );
        assert_eq!(map.get("c"), Some(&"rule".to_string()));
    }

    #[test]
    fn test_merge_overlay_updated_name_takes_store_value() {
        // 本次链已被响应刷新的同名键：罐视图胜出（overlay 旧值不得压制新会话）
        let c = ctx("example.com", &[("sid", "OLD"), ("rule", "1")]);
        c.record_updated("example.com", ["sid".to_string()]);
        let merged = merge_overlay_cookie_string("sid=NEW", "example.com", Some(&c));
        let map = as_map(&merged);
        assert_eq!(
            map.get("sid"),
            Some(&"NEW".to_string()),
            "链内新值应接管: {merged}"
        );
        assert_eq!(
            map.get("rule"),
            Some(&"1".to_string()),
            "未刷新的规则键保留: {merged}"
        );
    }

    #[test]
    fn test_merge_overlay_cross_domain_not_applied() {
        // 跨站重定向：overlay 归属域不匹配 → 绝不携带规则/登录 Cookie
        let c = ctx("a.example.com", &[("rule", "1")]);
        assert_eq!(
            merge_overlay_cookie_string("b=2", "b.example.com", Some(&c)),
            "b=2"
        );
    }

    #[test]
    fn test_begin_attempt_clears_updated() {
        let c = ctx("example.com", &[("sid", "OLD")]);
        c.record_updated("example.com", ["sid".to_string()]);
        c.begin_attempt();
        let merged = merge_overlay_cookie_string("sid=NEW", "example.com", Some(&c));
        assert_eq!(
            as_map(&merged).get("sid"),
            Some(&"OLD".to_string()),
            "新尝试应回到「规则优先」起点: {merged}"
        );
    }

    #[test]
    fn test_parse_set_cookie_pair() {
        assert_eq!(
            parse_set_cookie_pair("sid=abc123; Path=/; HttpOnly"),
            Some(("sid".to_string(), "abc123".to_string()))
        );
        assert_eq!(
            parse_set_cookie_pair("token=a=b; Path=/"),
            Some(("token".to_string(), "a=b".to_string())),
            "值内 = 必须保留"
        );
        assert_eq!(parse_set_cookie_pair("novalue"), None);
        assert_eq!(parse_set_cookie_pair("=empty; Path=/"), None);
    }

    #[test]
    fn test_persist_cookie_pairs_writes_store_and_notifies_observer() {
        /// 记录全部通知（并发用例可能追加其它域条目，故按「存在性」断言）
        struct RecordingObserver(Arc<Mutex<Vec<(String, String)>>>);
        impl CookieWriteObserver for RecordingObserver {
            fn on_cookies_saved(&self, domain: &str, cookie_string: &str) {
                self.0
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .push((domain.to_string(), cookie_string.to_string()));
            }
        }

        // OnceLock 全局 first-wins：本测试独占注册（同 crate 其余用例不注册；
        // 记录器无副作用，被其它用例共享不影响其断言）
        let notifications: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let _ = set_cookie_write_observer(Arc::new(RecordingObserver(Arc::clone(&notifications))));

        let store = Arc::new(RwLock::new(CookieStore::new()));
        // 独占域名键，避免与并发用例的通知混淆
        let domain = "cookie-jar-observer-test.example";
        let view = persist_cookie_pairs(
            &store,
            None,
            domain,
            &[
                ("a".to_string(), "1".to_string()),
                ("b".to_string(), "2".to_string()),
            ],
        );
        assert!(
            view.contains("a=1") && view.contains("b=2"),
            "写入后视图: {view}"
        );
        {
            let guard = store.read().unwrap();
            assert_eq!(guard.get_key(domain, "a"), Some("1".to_string()));
            assert_eq!(guard.get_key(domain, "b"), Some("2".to_string()));
        }
        let recorded = notifications
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .iter()
            .find(|(d, _)| d == domain)
            .cloned()
            .expect("本域应收到一次 observer 通知");
        assert!(recorded.1.contains("a=1"), "通知应带全量视图: {recorded:?}");
        assert!(recorded.1.contains("b=2"), "通知应带全量视图: {recorded:?}");
    }
}
