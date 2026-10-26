//! HTTP 请求日志（对齐 Kotlin `HttpLogStore` / `HttpLogRecord` / `HttpLogSanitizer`）
//!
//! 原版依据（upstream `app/src/main/java/io/legado/app/help/http/`）：
//! - `HttpLogRecord.kt:9-99`：内存环形存储，[`MAX_RECORDS`] = 50，最新在队首，
//!   `nextId` 进程级自增；`add`/`get`/`latest`/`clear` 四个同步入口；
//! - `HttpLogInterceptor.kt`：OkHttp 拦截器按 `AppConfig.recordHttpLog` 门控采集，
//!   请求/响应体截断 [`MAX_BODY_BYTES`] = 8192 字节并追加 `[truncated]` 标记；
//! - `HttpLogSanitizer.kt`：敏感头/敏感查询参数/Bearer·Basic·JSON 密值统一
//!   `[redacted]`，二进制体 `[binary body omitted]`。
//!
//! Rust 侧落点：[`HttpLogStore`] 进程级单例（`OnceLock`，对齐 Kotlin object 单例）。
//!
//! **生产者接线范围（如实登记）**：本批唯一新增的服务端出站 HTTP 是段评
//! 抓取链（`legacy/review_api.rs` 的 summary/detail/replies 三处 `AnalyzeUrl`
//! 请求），已按 `config:recordHttpLog` 门控写入本存储。App 全量 HTTP 采集
//! （对齐原版 `HttpLogInterceptor` 挂 OkHttp 客户端）需在 `legado-net`
//! `LegadoClient` 内挂拦截器——`legado-net` 属本批禁改范围，登记为「预留
//! （未接线）」，接线批在 `LegadoClient` 执行点调用 [`record_request_pair`]
//! 同款语义即可，读取端点零改动。

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Mutex, OnceLock};

use regex::Regex;
use serde::Serialize;

/// 环形容量上限（对齐 Kotlin `HttpLogStore.MAX_RECORDS`）
pub const MAX_RECORDS: usize = 50;

/// 请求/响应体截断上限（对齐 Kotlin `HttpLogInterceptor.MAX_BODY_BYTES`）
pub const MAX_BODY_BYTES: usize = 8_192;

/// 敏感头名集合（对齐 `HttpLogSanitizer.sensitiveNames`，比较前小写化并
/// 剔除非字母数字；见 [`is_sensitive_name`]）
const SENSITIVE_NAMES: &[&str] = &[
    "authorization",
    "proxyauthorization",
    "cookie",
    "setcookie",
    "password",
    "passwd",
    "token",
    "accesstoken",
    "refreshtoken",
    "secret",
    "apikey",
    "key",
    "signature",
    "sign",
];

const REDACTED: &str = "[redacted]";
const BINARY_BODY: &str = "[binary body omitted]";
const TRUNCATED: &str = "[truncated]";

/// 一条 HTTP 请求日志（字段对齐 Kotlin `HttpLogRecord.kt:9-21`）
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HttpLogRecord {
    pub id: i64,
    /// 请求开始时刻（Unix 毫秒）
    pub time: i64,
    pub method: String,
    /// 脱敏后的路径（对齐 `HttpLogSanitizer.redactPath`）
    pub path: String,
    /// 脱敏后的完整 URL（对齐 `HttpLogSanitizer.redactUrl`）
    pub url: String,
    /// 响应状态码；请求异常时为 -1（对齐拦截器错误分支）
    pub status_code: i32,
    /// 耗时（毫秒）
    pub duration: i64,
    pub request_headers: String,
    pub request_body: String,
    pub response_headers: String,
    pub response_body: String,
    /// 失败时的错误摘要；成功为 None（GSON 默认省略 null → 亦不输出）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 摘要视图字段（对齐 Kotlin `HttpLogController.summary`：id/time/method/url/
/// statusCode/duration/error，七键 map）
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HttpLogSummary {
    pub id: i64,
    pub time: i64,
    pub method: String,
    pub url: String,
    pub status_code: i32,
    pub duration: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl HttpLogRecord {
    /// `HttpLogController.summary` 同款摘要投影
    pub fn summary(&self) -> HttpLogSummary {
        HttpLogSummary {
            id: self.id,
            time: self.time,
            method: self.method.clone(),
            url: self.url.clone(),
            status_code: self.status_code,
            duration: self.duration,
            error: self.error.clone(),
        }
    }
}

struct StoreInner {
    records: VecDeque<HttpLogRecord>,
}

/// 进程级 HTTP 日志存储（对齐 Kotlin `HttpLogStore` object 单例）
pub struct HttpLogStore {
    inner: Mutex<StoreInner>,
    id_generator: AtomicI64,
}

static STORE: OnceLock<HttpLogStore> = OnceLock::new();

/// 取全局存储单例
pub fn http_log_store() -> &'static HttpLogStore {
    STORE.get_or_init(|| HttpLogStore {
        inner: Mutex::new(StoreInner {
            records: VecDeque::with_capacity(MAX_RECORDS),
        }),
        id_generator: AtomicI64::new(0),
    })
}

impl HttpLogStore {
    /// 下一条记录 ID（对齐 `HttpLogStore.nextId` 进程级自增）
    pub fn next_id(&self) -> i64 {
        self.id_generator.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// 追加一条记录（最新在队首；超容量从队尾淘汰，对齐 `HttpLogStore.add`）
    pub fn add(&self, record: HttpLogRecord) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.records.push_front(record);
            while inner.records.len() > MAX_RECORDS {
                inner.records.pop_back();
            }
        }
    }

    /// 按 ID 查找（对齐 `HttpLogStore.get`）
    pub fn get(&self, id: i64) -> Option<HttpLogRecord> {
        self.inner
            .lock()
            .ok()?
            .records
            .iter()
            .find(|r| r.id == id)
            .cloned()
    }

    /// 取最新 limit 条（对齐 `HttpLogStore.latest`：调用方先 clamp(1, MAX)）
    pub fn latest(&self, limit: usize) -> Vec<HttpLogRecord> {
        self.inner
            .lock()
            .map(|inner| inner.records.iter().take(limit).cloned().collect())
            .unwrap_or_default()
    }

    /// 当前条数（测试与诊断用）
    pub fn len(&self) -> usize {
        self.inner
            .lock()
            .map(|inner| inner.records.len())
            .unwrap_or(0)
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 清空（对齐 `HttpLogStore.clear`）
    pub fn clear(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.records.clear();
        }
    }
}

// ─── 采集侧（生产者入口） ───────────────────────────────────────────────────

/// 记录一次成功的请求/响应对（对齐 `HttpLogInterceptor` 成功分支）
///
/// `headers` 为合并后的请求头；`request_body` 为请求体文本；响应字段取自
/// `LegadoResponse`。脱敏与截断见 [`sanitize`] 族。
#[allow(clippy::too_many_arguments)]
pub fn record_success(
    method: &str,
    url: &str,
    request_headers: &HashMap<String, String>,
    request_body: &str,
    response_status: i32,
    response_headers: &HashMap<String, String>,
    response_body: &str,
    response_content_type: Option<&str>,
    duration_ms: i64,
) {
    let record = HttpLogRecord {
        id: http_log_store().next_id(),
        time: now_millis().saturating_sub(duration_ms.max(0)),
        method: method.to_string(),
        path: redact_path(url),
        url: redact_url(url),
        status_code: response_status,
        duration: duration_ms,
        request_headers: format_headers(request_headers),
        request_body: capture_body(request_body, None),
        response_headers: format_headers(response_headers),
        response_body: capture_body(response_body, response_content_type),
        error: None,
    };
    http_log_store().add(record);
}

/// 记录一次失败的请求（对齐 `HttpLogInterceptor` 异常分支：statusCode=-1、
/// 响应字段为空、error=异常摘要）
pub fn record_failure(
    method: &str,
    url: &str,
    request_headers: &HashMap<String, String>,
    request_body: &str,
    error: &str,
    duration_ms: i64,
) {
    let record = HttpLogRecord {
        id: http_log_store().next_id(),
        time: now_millis().saturating_sub(duration_ms.max(0)),
        method: method.to_string(),
        path: redact_path(url),
        url: redact_url(url),
        status_code: -1,
        duration: duration_ms,
        request_headers: format_headers(request_headers),
        request_body: capture_body(request_body, None),
        response_headers: String::new(),
        response_body: String::new(),
        error: Some(error.to_string()),
    };
    http_log_store().add(record);
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ─── 脱敏（对齐 HttpLogSanitizer 的子集，逐条登记差异） ─────────────────────

/// 头名是否敏感（对齐 `HttpLogSanitizer.isSensitive`：小写化并剔除非字母数字后
/// 精确命中集合，或以 authorization/cookie/password/token/secret/apikey/
/// signature/sign 结尾）
fn is_sensitive_name(name: &str) -> bool {
    let normalized: String = name
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    SENSITIVE_NAMES.contains(&normalized.as_str())
        || normalized.ends_with("authorization")
        || normalized.ends_with("cookie")
        || normalized.ends_with("password")
        || normalized.ends_with("token")
        || normalized.ends_with("secret")
        || normalized.ends_with("apikey")
        || normalized.ends_with("signature")
        || normalized.ends_with("sign")
}

/// 请求/响应头格式化（对齐 `HttpLogSanitizer.formatHeaders`：`name: value`
/// 按行拼接，敏感名值替换 `[redacted]`）
pub fn format_headers(headers: &HashMap<String, String>) -> String {
    let mut lines: Vec<String> = headers
        .iter()
        .map(|(name, value)| {
            let value = if is_sensitive_name(name) {
                REDACTED.to_string()
            } else {
                value.clone()
            };
            format!("{name}: {value}")
        })
        .collect();
    // 稳定输出：按头名排序（原版按 okhttp Headers 顺序；此处无序 Map，
    // 排序仅影响展示顺序，登记差异）
    lines.sort();
    lines.join("\n")
}

/// URL 脱敏（对齐 `HttpLogSanitizer.redactUrl` 的子集）：
/// - userinfo（`scheme://user:pass@host`）→ `[redacted]`；
/// - 敏感查询参数值 → `[redacted]`；
/// - 路径段形似凭据（恰 2 个 `.` 且长度 ≥ 32，对齐 `isCredentialLike`）→
///   `[redacted]`。
///
/// 差异：原版经 okhttp HttpUrl 重建（编码规范化），此处按字符串分段处理，
/// 不做百分号重编码。
pub fn redact_url(url: &str) -> String {
    let (before_query, query) = match url.split_once('?') {
        Some((b, q)) => (b, Some(q)),
        None => (url, None),
    };

    // userinfo 脱敏：scheme://…@host 形态（仅 // 与首个 / 之间的 @）
    let mut authority_part = before_query.to_string();
    if let Some(scheme_end) = before_query.find("://") {
        let rest = &before_query[scheme_end + 3..];
        let authority_end = rest.find('/').unwrap_or(rest.len());
        let authority = &rest[..authority_end];
        if let Some(at) = authority.rfind('@') {
            let start = scheme_end + 3;
            authority_part = format!(
                "{}{}{}",
                &before_query[..start],
                REDACTED,
                &before_query[start + at..]
            );
        }
    }

    // 路径段凭据脱敏
    let (prefix_path, path) = match authority_part.find("://") {
        Some(idx) => {
            let after = &authority_part[idx + 3..];
            let slash = after.find('/').map(|p| idx + 3 + p);
            match slash {
                Some(s) => (
                    authority_part[..s + 1].to_string(),
                    authority_part[s + 1..].to_string(),
                ),
                None => (authority_part.clone(), String::new()),
            }
        }
        None => (String::new(), authority_part.clone()),
    };
    let path = if path.is_empty() {
        path
    } else {
        path.split('/')
            .map(|segment| {
                if segment.matches('.').count() == 2 && segment.len() >= 32 {
                    REDACTED.to_string()
                } else {
                    segment.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("/")
    };

    // 查询参数脱敏
    let query_redacted = query.map(|q| {
        q.split('&')
            .map(|pair| match pair.split_once('=') {
                Some((name, _)) if is_sensitive_name(name) => format!("{name}={REDACTED}"),
                _ => pair.to_string(),
            })
            .collect::<Vec<_>>()
            .join("&")
    });

    match query_redacted {
        Some(q) => format!("{prefix_path}{path}?{q}"),
        None => format!("{prefix_path}{path}"),
    }
}

/// 路径脱敏（对齐 `HttpLogSanitizer.redactPath`：仅取 path 段并做凭据段脱敏）
pub fn redact_path(url: &str) -> String {
    let without_query = url.split('?').next().unwrap_or(url);
    let path_start = without_query
        .find("://")
        .and_then(|idx| without_query[idx + 3..].find('/').map(|p| idx + 3 + p))
        .unwrap_or(0);
    let path = &without_query[path_start..];
    if path.is_empty() {
        return "/".to_string();
    }
    path.split('/')
        .map(|segment| {
            if segment.matches('.').count() == 2 && segment.len() >= 32 {
                REDACTED.to_string()
            } else {
                segment.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// 自由文本脱敏（对齐 `HttpLogSanitizer.redactFreeText` 五条正则：
/// 头行密值 / Bearer / Basic / JSON 密值 / 查询参数密值）
pub fn redact_free_text(text: &str) -> String {
    let header_secret = Regex::new(
        r"(?i)((?:^|[\r\n\s])(?:authorization|proxy-authorization|cookie|set-cookie)\s*:\s*)([^\r\n]*)",
    )
    .expect("header secret 正则编译失败");
    let bearer =
        Regex::new(r"(?i)(bearer\s+)[A-Za-z0-9._~+/-]+={0,2}").expect("bearer 正则编译失败");
    let basic = Regex::new(r"(?i)(basic\s+)[A-Za-z0-9+/]+={0,2}").expect("basic 正则编译失败");
    let json_secret = Regex::new(
        r#"(?i)("(?:password|passwd|token|access[_-]?token|refresh[_-]?token|secret|authorization|cookie|api[_-]?key|sign|signature)"\s*:\s*")([^"]*)(")"#,
    )
    .expect("json secret 正则编译失败");
    let parameter_secret = Regex::new(
        r"(?i)((?:^|[?&\s])(?:password|passwd|token|access[_-]?token|refresh[_-]?token|secret|authorization|cookie|api[_-]?key|sign|signature)=)([^&\s]*)",
    )
    .expect("parameter secret 正则编译失败");

    let text = header_secret.replace_all(text, format!("${{1}}{REDACTED}"));
    let text = bearer.replace_all(&text, format!("${{1}}{REDACTED}"));
    let text = basic.replace_all(&text, format!("${{1}}{REDACTED}"));
    let text = json_secret.replace_all(&text, format!("${{1}}{REDACTED}${{3}}"));
    parameter_secret
        .replace_all(&text, format!("${{1}}{REDACTED}"))
        .into_owned()
}

/// 请求/响应体采集（对齐 `HttpLogSanitizer.body`：二进制检出、脱敏、截断标记）
///
/// `content_type` 为响应 `Content-Type`：
/// - 有 `Content-Type` 且非文本类 → `[binary body omitted]`（对齐 isText 门控）；
/// - 无 `Content-Type`（请求体路径）→ 仅按字节启发式判定二进制，否则按文本
///   采集（段评链请求体均为 URL 编码/文本表单；登记差异）。
pub fn capture_body(body: &str, content_type: Option<&str>) -> String {
    if body.is_empty() {
        return String::new();
    }
    if let Some(ct) = content_type {
        if !content_type_is_text(Some(ct)) {
            return BINARY_BODY.to_string();
        }
    } else if !looks_like_text(body) {
        return BINARY_BODY.to_string();
    }
    let truncated = body.len() > MAX_BODY_BYTES;
    // 按字节截断后再做 UTF-8 边界收缩（对齐原版按字节缓冲读取语义）
    let mut bytes = body.as_bytes();
    if truncated {
        bytes = &bytes[..MAX_BODY_BYTES];
    }
    let mut text = String::from_utf8_lossy(bytes).into_owned();
    text = redact_free_text(&text);
    if truncated {
        text.push('\n');
        text.push_str(TRUNCATED);
    }
    text
}

/// `Content-Type` 是否文本类（对齐 `HttpLogSanitizer.isText`）
fn content_type_is_text(content_type: Option<&str>) -> bool {
    let Some(ct) = content_type else {
        return false;
    };
    let lower = ct.to_lowercase();
    let subtype = lower.split(';').next().unwrap_or(lower.as_str());
    subtype.starts_with("text/")
        || subtype.contains("json")
        || subtype.contains("xml")
        || subtype.contains("html")
        || subtype.contains("javascript")
        || subtype.contains("x-www-form-urlencoded")
}

/// 字节级文本启发式（对齐 `HttpLogSanitizer.looksLikeText`：含替换符即二进制，
/// 前 256 字符须可打印）
fn looks_like_text(body: &str) -> bool {
    if body.contains('\u{FFFD}') {
        return false;
    }
    body.chars()
        .take(256)
        .all(|c| !c.is_control() || c == '\n' || c == '\r' || c == '\t')
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 串行保护：以下用例读写全局单例，须串行执行
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn record(id: i64) -> HttpLogRecord {
        HttpLogRecord {
            id,
            time: 1_700_000_000_000 + id,
            method: "GET".into(),
            path: "/a".into(),
            url: "https://x.example.com/a".into(),
            status_code: 200,
            duration: 12,
            request_headers: String::new(),
            request_body: String::new(),
            response_headers: String::new(),
            response_body: String::new(),
            error: None,
        }
    }

    #[test]
    fn test_ring_buffer_max_records() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = http_log_store();
        store.clear();
        for i in 0..(MAX_RECORDS + 10) {
            let mut r = record(i as i64);
            r.url = format!("https://x.example.com/{i}");
            store.add(r);
        }
        assert_eq!(store.len(), MAX_RECORDS, "环形容量上限应为 50（对齐原版）");
        let latest = store.latest(MAX_RECORDS);
        assert_eq!(latest[0].id as usize, MAX_RECORDS + 9, "队首应为最新记录");
        assert_eq!(latest.last().unwrap().id as usize, 10, "最旧 10 条应被淘汰");
        store.clear();
    }

    #[test]
    fn test_get_by_id_miss_and_hit() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = http_log_store();
        store.clear();
        store.add(record(7));
        assert!(store.get(7).is_some());
        assert!(store.get(8).is_none());
        store.clear();
    }

    #[test]
    fn test_summary_projection_fields() {
        let value = serde_json::to_value(record(3)).unwrap();
        // 全字段形态对齐 Kotlin HttpLogRecord（camelCase）
        for key in [
            "id",
            "time",
            "method",
            "path",
            "url",
            "statusCode",
            "duration",
            "requestHeaders",
            "requestBody",
            "responseHeaders",
            "responseBody",
        ] {
            assert!(value.get(key).is_some(), "字段 {key} 缺失");
        }
        let summary = serde_json::to_value(record(3).summary()).unwrap();
        let mut keys: Vec<&str> = summary
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            ["duration", "id", "method", "statusCode", "time", "url"],
            "summary 键集应对齐 HttpLogController.summary（error=null 时 GSON 省略）"
        );
    }

    #[test]
    fn test_format_headers_redacts_sensitive() {
        let mut headers = HashMap::new();
        headers.insert("Content-Type".to_string(), "text/html".to_string());
        headers.insert("Cookie".to_string(), "session=secret".to_string());
        headers.insert("authorization".to_string(), "Bearer abc".to_string());
        headers.insert("X-Api-Token".to_string(), "t".to_string());
        let text = format_headers(&headers);
        assert!(text.contains("Content-Type: text/html"));
        assert!(
            text.contains("Cookie: [redacted]"),
            "cookie 值应脱敏：{text}"
        );
        assert!(text.contains("authorization: [redacted]"));
        assert!(
            text.contains("X-Api-Token: [redacted]"),
            "token 后缀头应脱敏：{text}"
        );
    }

    #[test]
    fn test_redact_url_query_and_userinfo() {
        assert_eq!(
            redact_url("https://user:pass@example.com/path?token=abc&page=2"),
            "https://[redacted]@example.com/path?token=[redacted]&page=2"
        );
        // 路径段凭据（JWT 形态：恰 2 个点、长度 ≥ 32）
        let jwt = format!(
            "eyJ{}.{}.{}",
            "a".repeat(16),
            "b".repeat(16),
            "c".repeat(16)
        );
        let redacted = redact_url(&format!("https://x.example.com/{jwt}"));
        assert!(
            redacted.contains("[redacted]"),
            "凭据路径段应脱敏：{redacted}"
        );
        // 普通路径不动
        assert_eq!(redact_path("https://x.example.com/book/1"), "/book/1");
    }

    #[test]
    fn test_redact_free_text_patterns() {
        assert_eq!(
            redact_free_text("authorization: Bearer abc.def"),
            "authorization: [redacted]"
        );
        assert_eq!(
            redact_free_text(r#"{"token":"abc","name":"x"}"#),
            r#"{"token":"[redacted]","name":"x"}"#
        );
        assert_eq!(
            redact_free_text("https://x.example.com/login?password=123&ok=1"),
            "https://x.example.com/login?password=[redacted]&ok=1"
        );
    }

    #[test]
    fn test_capture_body_truncate_and_binary() {
        let big = "x".repeat(MAX_BODY_BYTES + 100);
        let captured = capture_body(&big, Some("text/html"));
        assert!(captured.ends_with(TRUNCATED), "超限体应带截断标记");
        assert!(captured.len() < big.len() + 32);
        assert_eq!(
            capture_body("{\"a\":1}", Some("application/json")),
            "{\"a\":1}"
        );
        assert_eq!(capture_body("图片数据", Some("image/png")), BINARY_BODY);
        assert_eq!(capture_body("", Some("application/json")), "");
    }
}
