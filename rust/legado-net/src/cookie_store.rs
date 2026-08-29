//! Cookie 管理模块
//!
//! 参考 Kotlin 实现 `CookieStore.kt` 和 `CookieManager.kt`，
//! 提供基于内存的 Cookie 存储、查询、合并与过期清理功能。

use std::collections::HashMap;
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
    /// 删除单个域名的全部 Cookie
    fn delete(&self, tag: &str);
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
    /// `url` 用于提取域名。解析失败时返回空字符串。
    pub fn get_cookie_string(&self, url: &str) -> String {
        let domain = match extract_domain(url) {
            Some(d) => d,
            None => return String::new(),
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

/// 从 URL 提取子域名（简化版，对应 `NetworkUtils.getSubDomain`）
///
/// 例如 `https://www.example.com/path` -> `example.com`
fn extract_domain(url: &str) -> Option<String> {
    use url::Url;
    let parsed = Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    // 简单取最后两段作为子域名
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() >= 2 {
        Some(parts[parts.len() - 2..].join("."))
    } else {
        Some(host.to_string())
    }
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
}
