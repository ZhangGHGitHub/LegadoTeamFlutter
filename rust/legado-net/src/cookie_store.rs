//! Cookie 管理模块
//!
//! 参考 Kotlin 实现 `CookieStore.kt` 和 `CookieManager.kt`，
//! 提供基于内存的 Cookie 存储、查询、合并与过期清理功能。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::SystemTime;

/// 单个 Cookie 条目
#[derive(Debug, Clone)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    pub expires: Option<SystemTime>,
    pub secure: bool,
    pub http_only: bool,
}

impl Cookie {
    /// 判断 Cookie 是否已过期
    pub fn is_expired(&self) -> bool {
        match self.expires {
            Some(exp) => SystemTime::now() > exp,
            None => false, // 会话 Cookie，不过期
        }
    }
}

/// Cookie 持久化后端抽象（注入模式）
///
/// legado-net 不能依赖 legado-db（避免循环依赖），因此网络层仅定义 trait：
/// - 启动时由上层（legado-ffi）注入 DB 实现，将持久化 Cookie 载入内存 [`CookieStore`]
/// - Cookie 变更时 [`LegadoClient`](crate::client::LegadoClient) 同步回调写回后端
///
/// 方法均为同步接口：DB 实现（r2d2 连接池）本身是同步的，避免引入异步开销。
/// 各方法应自行吞掉底层错误（仅记日志），持久化失败不应阻断网络请求。
pub trait CookiePersistence: Send + Sync {
    /// 加载全部持久化 Cookie，返回 `(域名 tag, "name=value; ...")` 列表
    fn load_all(&self) -> Vec<(String, String)>;
    /// 插入/更新单个域名的 Cookie 字符串
    fn save(&self, tag: &str, cookie: &str);
}

// ─── 按域 Cookie 写通道（per-domain 串行锁） ─────────────────────────────────

/// 按域写通道注册表
///
/// 目的：让**同一域**的「jar 更新 + 捕获全量串 + 持久化落库」原子化。
/// HTTP 写回路径（[`save_cookies_from_response`](crate::client::LegadoClient::save_cookies_from_response)）
/// 与 JS 宿主写路径（`legado-js` `with_store_update`，quickjs 档委托本注册表）
/// 都**先**取该域串行锁再取 jar/内存存储锁，使「本次捕获的视图」不会被并发的
/// 同域写入者覆盖——否则「捕获全量串 → 落库」之间被插入的并发写会让落库行
/// 回退为过期视图（内存=NEW，重启回填=OLD）。
///
/// **锁序（唯一固定顺序，无环）**：
/// ```text
/// D（本按域串行锁，最外层；其下允许 DB/sink I/O，
///   但持 J/G 时绝不做 DB I/O）
///   → J（jar RwLock：短临界区，仅更新/捕获/删除，不回调 D、不做 DB I/O）
///   → G（JS 内存存储 Mutex：短临界区，不回调 D、不做 sink 调用）
///   → C（FFI COOKIE_PERSIST_RW_LOCK：DB 行读-改-写串行化）
///   → P（DB 连接池：取连接等待有界）
/// ```
/// 无环论证：J 持有者（jar 路径）必先持 D 再取 J，临界区内不等待 D/C/P；
/// `JsCookieDbSink::remove/remove_all`（FFI 侧）持 C/P 后**短暂 scoped** 取 J
///（且从不持 D），P 连接在取 J 前已归还；C/P 持有者不回调 D/J/G。
/// 因此等待图 D→J→C→P 是链状，任何「持内锁等外锁」的回边均不存在。
/// 中毒策略：各 `Mutex` 中毒后经 `into_inner` 恢复（与项目内其它锁的恢复
/// 语义一致——持有者 panic 不应让写通道永久不可用）。
static DOMAIN_WRITE_LOCKS: LazyLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 域锁注册表条目数告警阈值（资源保护，不改变正确性语义）
///
/// 注册表条目 = 出现过的域键（正常应用：书源域数十至数千个）；无界增长
/// 只能来自病态输入（规则脚本以拼接/随机串反复调用 cookie 接口 → 每个新
/// 串登记一条域锁）。超阈值时一次性告警（带当前条目数）——纯诊断信号：
/// **不做逐出/拒绝**（逐出会破坏「裸指针 `'static` 有效」不变式，正确性
/// 语义不可变；条目数量本身不影响任何互斥语义）。
const DOMAIN_REGISTRY_WARN_CAP: usize = 4096;

/// 一次性告警标记（每进程至多告警一次，避免病态输入刷屏）
static DOMAIN_REGISTRY_CAP_WARNED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// 注册表条目数超阈值时一次性告警（仅诊断，不参与锁语义）
fn maybe_warn_domain_registry_growth(count: usize) {
    if count > DOMAIN_REGISTRY_WARN_CAP
        && !DOMAIN_REGISTRY_CAP_WARNED.swap(true, std::sync::atomic::Ordering::Relaxed)
    {
        eprintln!(
            "[legado-net] cookie 域锁注册表条目数 {count} 超过阈值 {DOMAIN_REGISTRY_WARN_CAP}（病态输入持续生成新域键；一次性告警，不影响正确性）"
        );
    }
}

/// 从静态注册表取得某域写通道锁对象的 `'static` 原始指针
///
/// 若该域尚未注册，先向 [`DOMAIN_WRITE_LOCKS`] 登记 `Arc<Mutex<()>>`，再对
/// 登记后的 `Arc` 克隆一次经 `Arc::into_raw` 交出裸指针（克隆保证注册表
/// 仍持有原对象）。域锁（`Mutex<()>`）一经注册即由静态注册表永久持有
/// （注册表条目永不删除），故其裸指针可安全地以 `'static` 解引用。
fn domain_lock_raw(
    registry: &mut HashMap<String, Arc<Mutex<()>>>,
    domain: &str,
) -> *const Mutex<()> {
    let is_new = !registry.contains_key(domain);
    let arc = registry
        .entry(domain.to_string())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone();
    if is_new {
        maybe_warn_domain_registry_growth(registry.len());
    }
    // 不变式断言（debug 构建）：注册表此刻仍持有交出裸指针的那个 Arc。
    // 该不变式是 [`lock_domain_ptr`] unsafe 合法性的前提——条目一旦可被
    // 删除/替换，已交出的裸指针即悬垂。
    debug_assert!(
        registry
            .get(domain)
            .is_some_and(|held| Arc::ptr_eq(held, &arc)),
        "cookie 域锁注册表不变式被破坏：条目被删除/替换，裸指针 'static 有效性失效"
    );
    Arc::into_raw(arc)
}

/// 由 `'static` 裸指针取域锁（本文件唯一的 unsafe 解引用点）
///
/// # Safety
/// 指针必须来自 [`domain_lock_raw`]（或同一注册表存活条目的
/// `Arc::as_ptr`）——`Arc<Mutex<()>>` 一经注册即由静态注册表永久持有
///（**注册表条目永不删除**——本文件 unsafe 的不变式：任何未来引入
/// 注册表清理/条目删除的改动都会立即制造悬垂指针，必须同步重构本指针
/// 方案，例如改为经注册表守卫加锁）。对象存活期 `'static`；此处仅加锁
/// 并返回守卫，守卫 drop 只解锁、不触碰对象所有权，故不构成双重 free
/// 或悬垂。
fn lock_domain_ptr(ptr: *const Mutex<()>) -> MutexGuard<'static, ()> {
    unsafe { (&*ptr).lock().unwrap_or_else(|p| p.into_inner()) }
}

/// 取某域的写通道串行锁（最外层 D 锁）
///
/// 返回守卫，drop 时该域写通道放行。`domain` 为域键：
/// - net 层 jar 路径用 [`cookie_domain_key`]（ETLD+1，解析失败回退原 URL）；
/// - JS 宿主路径用 `normalized_cookie_key`（quickjs 档委托本函数）。
///
/// 两侧必须经**同一来源**的域键规则，保证同域互斥。
pub fn domain_write_lock(domain: &str) -> MutexGuard<'static, ()> {
    let ptr = {
        let mut registry = DOMAIN_WRITE_LOCKS.lock().unwrap_or_else(|p| p.into_inner());
        domain_lock_raw(&mut registry, domain)
    };
    lock_domain_ptr(ptr)
}

/// 持有全部按域写通道（注册表锁 + 全部域锁，按域键排序取锁防环）
///
/// 供「整体清空」类操作（`clear_all_cookies`）与逐域写方互斥：
/// - 持**注册表锁**期间新域的 `domain_write_lock` 无法注册，临界区内不存在
///   「快照后新建域」的旁路；
/// - 域锁按**排序键序**获取（固定顺序 → 无环）。
///
/// 注册表锁与各域锁在其它持有者（`domain_write_lock`）处从不嵌套持有
/// （注册表守卫在取域锁前已释放），故本函数持「注册表 + 域锁」亦无环。
pub struct AllDomainWriteGuards {
    /// 注册表锁（阻塞新域注册）
    _registry: MutexGuard<'static, HashMap<String, Arc<Mutex<()>>>>,
    /// 全部既有域锁（按域键排序）
    _domains: Vec<MutexGuard<'static, ()>>,
}

impl AllDomainWriteGuards {
    /// 取全部按域写通道（见 [`lock_all_domain_writes`]）
    pub(crate) fn new(
        registry: MutexGuard<'static, HashMap<String, Arc<Mutex<()>>>>,
        domains: Vec<MutexGuard<'static, ()>>,
    ) -> Self {
        Self {
            _registry: registry,
            _domains: domains,
        }
    }
}

/// 取全部按域写通道（注册表锁 + 全部域锁），供整体清空操作使用
pub fn lock_all_domain_writes() -> AllDomainWriteGuards {
    let registry = DOMAIN_WRITE_LOCKS.lock().unwrap_or_else(|p| p.into_inner());
    let mut keys: Vec<String> = registry.keys().cloned().collect();
    keys.sort();
    let mut domains = Vec::with_capacity(keys.len());
    for key in &keys {
        // 注册表守卫在持期间条目不可被删/换，[`lock_domain_ptr`] 的 SAFETY
        // 前提在此平凡成立（与 [`domain_write_lock`] 不同，此处连克隆 Arc
        // 都不需要）。
        let ptr = Arc::as_ptr(registry.get(key).expect("键来自同一注册表快照，必然存在"));
        domains.push(lock_domain_ptr(ptr));
    }
    AllDomainWriteGuards::new(registry, domains)
}

/// 基于内存的 Cookie 存储
///
/// 以 domain 为键管理 Cookie 列表，支持：
/// - 按域名查询
/// - 设置/替换单个 Cookie
/// - 清理过期 Cookie
/// - 生成 HTTP Cookie 头字符串
#[derive(Debug, Clone, Default)]
pub struct CookieStore {
    cookies: HashMap<String, Vec<Cookie>>,
}

impl CookieStore {
    /// 创建空的 CookieStore
    pub fn new() -> Self {
        Self {
            cookies: HashMap::new(),
        }
    }

    /// 获取指定域名的所有 Cookie（不含已过期的）
    pub fn get_cookies(&self, domain: &str) -> Vec<&Cookie> {
        self.cookies
            .get(domain)
            .map(|list| list.iter().filter(|c| !c.is_expired()).collect())
            .unwrap_or_default()
    }

    /// 设置一个 Cookie。若同名 Cookie 已存在则替换。
    pub fn set_cookie(&mut self, cookie: Cookie) {
        let entry = self.cookies.entry(cookie.domain.clone()).or_default();
        // 同名替换
        if let Some(existing) = entry.iter_mut().find(|c| c.name == cookie.name) {
            *existing = cookie;
        } else {
            entry.push(cookie);
        }
    }

    /// 从 Cookie 字符串解析并设置多个 Cookie（格式: `name1=value1; name2=value2`）
    ///
    /// 参考 `CookieStore.cookieToMap()` / `CookieStore.replaceCookie()`
    pub fn set_cookies_from_string(&mut self, domain: &str, cookie_str: &str) {
        if cookie_str.is_empty() {
            return;
        }
        let map = Self::cookie_string_to_map(cookie_str);
        for (name, value) in map {
            self.set_cookie(Cookie {
                name,
                value,
                domain: domain.to_string(),
                path: "/".to_string(),
                expires: None,
                secure: false,
                http_only: false,
            });
        }
    }

    /// 移除所有已过期的 Cookie
    pub fn remove_expired(&mut self) {
        for list in self.cookies.values_mut() {
            list.retain(|c| !c.is_expired());
        }
        self.cookies.retain(|_, list| !list.is_empty());
    }

    /// 移除指定域名的全部 Cookie
    pub fn remove_domain(&mut self, domain: &str) {
        self.cookies.remove(domain);
    }

    /// 移除指定域名下的某个 Cookie（按 name）
    pub fn remove_cookie(&mut self, domain: &str, name: &str) {
        if let Some(list) = self.cookies.get_mut(domain) {
            list.retain(|c| c.name != name);
            if list.is_empty() {
                self.cookies.remove(domain);
            }
        }
    }

    /// 生成 HTTP `Cookie` 请求头的值：`name1=value1; name2=value2`
    ///
    /// `url` 用于提取域名（ETLD+1，见 [`cookie_domain_key`]）。解析失败时返回空字符串。
    pub fn get_cookie_string(&self, url: &str) -> String {
        let Some(domain) = cookie_domain_key(url) else {
            return String::new();
        };
        self.domain_cookie_string(&domain)
    }

    /// 序列化指定域名下全部 Cookie（不含已过期）为 `name1=value1; name2=value2`
    ///
    /// 用于持久化写回（与 DB cookies 表的 cookie 字段格式对齐）。
    pub fn domain_cookie_string(&self, domain: &str) -> String {
        self.get_cookies(domain)
            .iter()
            .map(|c| format!("{}={}", c.name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// 批量加载持久化 Cookie 条目：`(域名 tag, "name=value; ...")`
    ///
    /// 用于启动时从 DB 恢复 Cookie 到内存。
    pub fn load_persisted(&mut self, entries: impl IntoIterator<Item = (String, String)>) {
        for (domain, cookie_str) in entries {
            self.set_cookies_from_string(&domain, &cookie_str);
        }
    }

    /// 获取指定域名下某个 key 的值
    pub fn get_key(&self, domain: &str, key: &str) -> Option<String> {
        self.get_cookies(domain)
            .iter()
            .find(|c| c.name == key)
            .map(|c| c.value.clone())
    }

    // ---------- 内部辅助 ----------

    /// 将 `"name1=value1; name2=value2"` 解析为 `HashMap`
    ///
    /// 对应 Kotlin `CookieStore.cookieToMap()`
    pub fn cookie_string_to_map(cookie: &str) -> HashMap<String, String> {
        let mut map = HashMap::new();
        if cookie.is_empty() {
            return map;
        }
        for pair in cookie.split(';') {
            let pair = pair.trim();
            if pair.is_empty() {
                continue;
            }
            if let Some((key, value)) = pair.split_once('=') {
                let key = key.trim();
                let value = value.trim();
                if !key.is_empty() {
                    map.insert(key.to_string(), value.to_string());
                }
            }
        }
        map
    }

    /// 将 `HashMap` 序列化为 `"name1=value1; name2=value2"`
    ///
    /// 对应 Kotlin `CookieStore.mapToCookie()`
    pub fn map_to_cookie_string(map: &HashMap<String, String>) -> Option<String> {
        if map.is_empty() {
            return None;
        }
        let parts: Vec<String> = map.iter().map(|(k, v)| format!("{}={}", k, v)).collect();
        Some(parts.join("; "))
    }

    /// 合并两段 Cookie 字符串（后者覆盖前者的同名键）
    ///
    /// 对应 Kotlin `CookieManager.mergeCookies()`
    pub fn merge_cookies_str(a: &str, b: &str) -> Option<String> {
        let mut map = Self::cookie_string_to_map(a);
        let other = Self::cookie_string_to_map(b);
        map.extend(other);
        Self::map_to_cookie_string(&map)
    }
}

/// 高频多段公共后缀（两段 TLD）静态表
///
/// 覆盖各国/地区常见的「二段顶级域」（如 `com.cn`、`co.uk`），用于计算
/// 「有效顶级域 + 1」（ETLD+1）作为 Cookie 存储的域名键。命中时域名键取
/// host 末三段；未命中时回退为单段 TLD 语义（取末两段）。
///
/// 该表为高频子集，并非完整 Public Suffix List（无通配符/例外规则）；
/// 如需全量对齐可后续替换为内嵌 PSL 数据。
const MULTI_LABEL_TLDS: &[&str] = &[
    // 中国
    "com.cn",
    "net.cn",
    "org.cn",
    "gov.cn",
    "edu.cn",
    "ac.cn",
    "mil.cn",
    // 英国
    "co.uk",
    "org.uk",
    "me.uk",
    "net.uk",
    "sch.uk",
    "ac.uk",
    "gov.uk",
    // 澳大利亚
    "com.au",
    "net.au",
    "org.au",
    "edu.au",
    "gov.au",
    "id.au",
    // 中国香港
    "com.hk",
    "org.hk",
    "net.hk",
    "idv.hk",
    "edu.hk",
    "gov.hk",
    // 中国台湾
    "com.tw",
    "org.tw",
    "net.tw",
    "edu.tw",
    "gov.tw",
    // 日本
    "co.jp",
    "ne.jp",
    "or.jp",
    "ac.jp",
    "go.jp",
    "ed.jp",
    "lg.jp",
    // 巴西
    "com.br",
    "net.br",
    "org.br",
    "gov.br",
    "edu.br",
    // 墨西哥
    "com.mx",
    "org.mx",
    "net.mx",
    "gob.mx",
    "edu.mx",
    // 新加坡
    "com.sg",
    "org.sg",
    "net.sg",
    "edu.sg",
    "gov.sg",
    // 马来西亚
    "com.my",
    "net.my",
    "org.my",
    "gov.my",
    "edu.my",
    // 新西兰
    "co.nz",
    "org.nz",
    "net.nz",
    "govt.nz",
    "school.nz",
    // 韩国
    "co.kr",
    "or.kr",
    "ne.kr",
    "go.kr",
    "re.kr",
    // 印度
    "co.in",
    "net.in",
    "org.in",
    "firm.in",
    "gen.in",
    "ind.in",
    // 印度尼西亚
    "co.id",
    "or.id",
    "go.id",
    "web.id",
    // 越南
    "com.vn",
    "net.vn",
    "org.vn",
    "edu.vn",
    "gov.vn",
    // 泰国
    "co.th",
    "in.th",
    "ac.th",
    "go.th",
    "or.th",
    // 俄罗斯
    "co.ru",
    "org.ru",
    "net.ru",
    "pp.ru",
    // 乌克兰
    "com.ua",
    "in.ua",
    "org.ua",
    "gov.ua",
    "edu.ua",
    // 以色列
    "co.il",
    "org.il",
    "net.il",
    "ac.il",
    "gov.il",
    // 拉丁美洲
    "com.ar",
    "com.co",
    "com.pe",
    "com.cl",
    "com.ec",
    "com.ve",
    "com.py",
    "com.uy",
    "com.bo",
    "com.do",
    // 欧洲
    "com.tr",
    "com.pl",
    "com.gr",
    "com.it",
    "com.es",
    "com.pt",
    "com.cz",
    "com.ro",
    "com.hu",
    "com.se",
    // 中东/非洲
    "com.sa",
    "com.eg",
    "com.ng",
    "co.za",
    "com.pk",
    "com.bd",
    // 私有后缀（PSL 通配条目：用户子域本身即可注册，如 `user.github.io`）
    "github.io",
    "blogspot.com",
    "pages.dev",
    "vercel.app",
    "netlify.app",
    "workers.dev",
];

/// 由 host 计算 Cookie 存储的域名键（对齐上游 `NetworkUtils.getSubDomain`
/// 的「有效顶级域 + 1」语义）
///
/// 规则（按优先级）：
/// 1. IP 字面量（IPv4/IPv6，含 URL 中的 `[...]` 括号形式）→ 以自身为键；
/// 2. 末两段命中 [`MULTI_LABEL_TLDS`]（多段公共后缀，如 `com.cn`）→ 取末三段；
/// 3. 其余（单段 TLD，如 `com`）→ 取末两段；
/// 4. 段数不足时回退为 host 自身（单段 host 兜底，如 `localhost`）。
///
/// 对齐说明：上游 `getSubDomain` 用 `PublicSuffixDatabase.getEffectiveTldPlusOne`，
/// 其本质即「从 host 末尾按公共后缀长度截断 + 保留 1 段」；此处以高频多段
/// 表近似该截断点（命中多段表则后缀长 2，否则后缀长 1），等价于对 host 做
/// 「末段索引 = 总段数 - 后缀长 - 1」的 `lastIndexOf('.')` 定位。
pub fn domain_key_from_host(host: &str) -> String {
    // 去除 IPv6 的方括号（URL host 中 IPv6 形如 `[::1]`）
    let bare = match host.strip_prefix('[') {
        Some(inner) => inner.strip_suffix(']').unwrap_or(host),
        None => host,
    };
    // 尾点归一化（FQDN 形式 `a.example.com.` 不应产生空尾段，
    // 否则键塌缩为 `com.` 之类同形缺陷；同时让带尾点的 IP 仍命中 IP 自键分支）
    let bare = bare.trim_end_matches('.');
    // IP 字面量（IPv4/IPv6）以自身为键
    if bare.parse::<std::net::Ipv4Addr>().is_ok() || bare.parse::<std::net::Ipv6Addr>().is_ok() {
        return bare.to_string();
    }

    let labels: Vec<&str> = bare.split('.').collect();
    // 单段 host（如 localhost / 内网主机名）：以自身为键
    if labels.len() <= 1 {
        return bare.to_string();
    }
    // 判断末两段是否为多段公共后缀（决定后缀长度为 2 还是 1）
    let last_two = format!("{}.{}", labels[labels.len() - 2], labels[labels.len() - 1]);
    let suffix_len = if MULTI_LABEL_TLDS.contains(&last_two.as_str()) {
        2
    } else {
        1
    };
    let take = suffix_len + 1;
    // 段数不足（host 恰好等于或短于 后缀+1，如 host 即 `co.uk`）：以自身为键
    if labels.len() <= take {
        return bare.to_string();
    }
    bare.split('.')
        .skip(labels.len() - take)
        .collect::<Vec<_>>()
        .join(".")
}

/// 从 URL 提取 Cookie 存储的域名键（对齐上游 `NetworkUtils.getSubDomain`）
///
/// 例如 `https://a.example.com.cn/` -> `example.com.cn`（多段 TLD 取末三段），
/// `https://www.example.com/` -> `example.com`，`http://192.168.1.1/` -> `192.168.1.1`。
///
/// URL 解析失败或无 host 时返回 `None`。
pub fn cookie_domain_key(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    Some(domain_key_from_host(host))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get_cookie() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "session".to_string(),
            value: "abc123".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        let cookies = store.get_cookies("example.com");
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].name, "session");
        assert_eq!(cookies[0].value, "abc123");
    }

    #[test]
    fn test_replace_same_name_cookie() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "id".to_string(),
            value: "1".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.set_cookie(Cookie {
            name: "id".to_string(),
            value: "2".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        let cookies = store.get_cookies("example.com");
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].value, "2");
    }

    #[test]
    fn test_cookie_string_parsing() {
        let map = CookieStore::cookie_string_to_map("a=1; b=2; c=3");
        assert_eq!(map.get("a"), Some(&"1".to_string()));
        assert_eq!(map.get("b"), Some(&"2".to_string()));
        assert_eq!(map.get("c"), Some(&"3".to_string()));
    }

    #[test]
    fn test_get_cookie_string() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "a".to_string(),
            value: "1".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.set_cookie(Cookie {
            name: "b".to_string(),
            value: "2".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        let result = store.get_cookie_string("https://www.example.com/path");
        assert!(result.contains("a=1"));
        assert!(result.contains("b=2"));
    }

    #[test]
    fn test_merge_cookies() {
        let merged = CookieStore::merge_cookies_str("a=1; b=2", "b=3; c=4").unwrap();
        let map = CookieStore::cookie_string_to_map(&merged);
        assert_eq!(map.get("a"), Some(&"1".to_string()));
        assert_eq!(map.get("b"), Some(&"3".to_string())); // 被覆盖
        assert_eq!(map.get("c"), Some(&"4".to_string()));
    }

    #[test]
    fn test_remove_domain() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "a".to_string(),
            value: "1".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.set_cookie(Cookie {
            name: "b".to_string(),
            value: "2".to_string(),
            domain: "other.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.remove_domain("example.com");
        assert!(store.get_cookies("example.com").is_empty());
        assert_eq!(store.get_cookies("other.com").len(), 1);
    }

    #[test]
    fn test_remove_cookie_by_name() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "a".to_string(),
            value: "1".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.set_cookie(Cookie {
            name: "b".to_string(),
            value: "2".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.remove_cookie("example.com", "a");
        let cookies = store.get_cookies("example.com");
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].name, "b");
    }

    #[test]
    fn test_set_cookies_from_string() {
        let mut store = CookieStore::new();
        store.set_cookies_from_string("example.com", "session=abc; theme=dark");
        let cookies = store.get_cookies("example.com");
        assert_eq!(cookies.len(), 2);
    }

    #[test]
    fn test_set_cookies_from_empty_string() {
        let mut store = CookieStore::new();
        store.set_cookies_from_string("example.com", "");
        assert!(store.get_cookies("example.com").is_empty());
    }

    #[test]
    fn test_get_key() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "session".to_string(),
            value: "xyz".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        assert_eq!(
            store.get_key("example.com", "session"),
            Some("xyz".to_string())
        );
        assert_eq!(store.get_key("example.com", "missing"), None);
    }

    #[test]
    fn test_expired_cookie_not_returned() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "old".to_string(),
            value: "expired".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: Some(SystemTime::UNIX_EPOCH),
            secure: false,
            http_only: false,
        });
        assert!(store.get_cookies("example.com").is_empty());
    }

    #[test]
    fn test_remove_expired() {
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "valid".to_string(),
            value: "ok".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.set_cookie(Cookie {
            name: "expired".to_string(),
            value: "gone".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: Some(SystemTime::UNIX_EPOCH),
            secure: false,
            http_only: false,
        });
        store.remove_expired();
        let cookies = store.get_cookies("example.com");
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].name, "valid");
    }

    #[test]
    fn test_cookie_string_to_map_empty() {
        let map = CookieStore::cookie_string_to_map("");
        assert!(map.is_empty());
    }

    #[test]
    fn test_map_to_cookie_string_empty() {
        let map = HashMap::new();
        assert_eq!(CookieStore::map_to_cookie_string(&map), None);
    }

    #[test]
    fn test_merge_cookies_empty() {
        assert_eq!(CookieStore::merge_cookies_str("", ""), None);
    }

    #[test]
    fn test_domain_cookie_string() {
        let mut store = CookieStore::new();
        store.set_cookies_from_string("example.com", "a=1; b=2");
        let s = store.domain_cookie_string("example.com");
        let map = CookieStore::cookie_string_to_map(&s);
        assert_eq!(map.get("a"), Some(&"1".to_string()));
        assert_eq!(map.get("b"), Some(&"2".to_string()));
    }

    #[test]
    fn test_load_persisted() {
        let mut store = CookieStore::new();
        store.load_persisted(vec![
            (
                "example.com".to_string(),
                "session=abc; theme=dark".to_string(),
            ),
            ("other.com".to_string(), "token=xyz".to_string()),
        ]);
        assert_eq!(store.get_cookies("example.com").len(), 2);
        assert_eq!(store.get_key("other.com", "token"), Some("xyz".to_string()));
    }

    // ─── 域名键（ETLD+1 / IP / 单段兜底）测试 ──────────────

    #[test]
    fn test_domain_key_multi_label_tld() {
        // 多段 TLD（.com.cn）：不同二级域名应得到不同键，互不塌缩
        assert_eq!(
            cookie_domain_key("https://a.example.com.cn/x"),
            Some("example.com.cn".to_string())
        );
        assert_eq!(
            cookie_domain_key("https://b.other.com.cn/x"),
            Some("other.com.cn".to_string())
        );
        // 两者不同（P1-1 缺陷的最小断言）
        assert_ne!(
            cookie_domain_key("https://a.example.com.cn/x"),
            cookie_domain_key("https://b.other.com.cn/x"),
            "不同 .com.cn 站点不应塌缩为同一域名键"
        );
    }

    #[test]
    fn test_domain_key_co_uk() {
        // .co.uk 同理：取末三段
        assert_eq!(
            cookie_domain_key("https://shop.a.co.uk/"),
            Some("a.co.uk".to_string())
        );
        assert_eq!(
            cookie_domain_key("https://shop.b.co.uk/"),
            Some("b.co.uk".to_string())
        );
    }

    #[test]
    fn test_domain_key_single_label_tld() {
        // 单段 TLD（.com）：取末两段
        assert_eq!(
            cookie_domain_key("https://www.example.com/p"),
            Some("example.com".to_string())
        );
    }

    #[test]
    fn test_domain_key_ipv4() {
        // IPv4 字面量以自身为键
        assert_eq!(
            cookie_domain_key("http://192.168.1.10/"),
            Some("192.168.1.10".to_string())
        );
        assert_eq!(
            cookie_domain_key("http://127.0.0.1:8080/x"),
            Some("127.0.0.1".to_string())
        );
    }

    #[test]
    fn test_domain_key_ipv6() {
        // IPv6 字面量（URL 中方括号形式）以去括号后的自身为键
        assert_eq!(cookie_domain_key("http://[::1]/x"), Some("::1".to_string()));
        assert_eq!(
            cookie_domain_key("http://[2001:db8::1]/x"),
            Some("2001:db8::1".to_string())
        );
    }

    #[test]
    fn test_domain_key_single_label_host() {
        // 单段 host（localhost / 内网主机名）兜底为自身
        assert_eq!(
            cookie_domain_key("http://localhost:3000/"),
            Some("localhost".to_string())
        );
        assert_eq!(
            cookie_domain_key("http://intranet/"),
            Some("intranet".to_string())
        );
    }

    #[test]
    fn test_domain_key_host_equals_suffix() {
        // host 恰好等于多段后缀本身（如 `co.uk`）：段数不足，以自身为键
        assert_eq!(domain_key_from_host("co.uk"), "co.uk");
        assert_eq!(domain_key_from_host("com.cn"), "com.cn");
    }

    #[test]
    fn test_domain_key_invalid_url() {
        assert_eq!(cookie_domain_key("not a url"), None);
    }

    #[test]
    fn test_domain_key_trailing_dot_normalized() {
        // 尾点 FQDN 形式不应产生 `com.` 类塌缩键（P2-1）
        assert_eq!(
            cookie_domain_key("https://a.example.com.cn./x"),
            Some("example.com.cn".to_string())
        );
        assert_eq!(domain_key_from_host("localhost."), "localhost");
        // 带尾点的 IP 仍命中 IP 自键分支
        assert_eq!(domain_key_from_host("192.168.1.10."), "192.168.1.10");
    }

    #[test]
    fn test_domain_key_private_suffixes() {
        // 私有后缀（PSL 通配条目）：用户子域本身即注册域（ETLD+1）
        assert_eq!(
            cookie_domain_key("https://user.github.io/"),
            Some("user.github.io".to_string())
        );
        assert_eq!(
            cookie_domain_key("https://x.vercel.app/"),
            Some("x.vercel.app".to_string())
        );
        assert_eq!(
            cookie_domain_key("https://x.blogspot.com/"),
            Some("x.blogspot.com".to_string())
        );
    }

    #[test]
    fn test_get_cookie_string_multi_tld_isolated() {
        // 两个不同 .com.cn 站点各存一个 cookie，互访只携带各自的 cookie
        let mut store = CookieStore::new();
        store.set_cookie(Cookie {
            name: "siteA".to_string(),
            value: "1".to_string(),
            domain: "example.com.cn".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        store.set_cookie(Cookie {
            name: "siteB".to_string(),
            value: "2".to_string(),
            domain: "other.com.cn".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: false,
            http_only: false,
        });
        let a = store.get_cookie_string("https://a.example.com.cn/");
        let b = store.get_cookie_string("https://b.other.com.cn/");
        assert!(a.contains("siteA=1"), "a 站应携带自身 cookie: {a}");
        assert!(!a.contains("siteB=2"), "a 站不应携带 b 站 cookie: {a}");
        assert!(b.contains("siteB=2"), "b 站应携带自身 cookie: {b}");
        assert!(!b.contains("siteA=1"), "b 站不应携带 a 站 cookie: {b}");
    }
}
