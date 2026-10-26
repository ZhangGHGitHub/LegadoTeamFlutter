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
//! 对齐 `HttpLogStore.add` 的 `AppLog.put(record.summary)`：每条记录同时向
//! `legado_core::app_log` 追加一条级别 `http` 的单行摘要（应用日志页可见）。
//!
//! **生产者接线范围（2026-10-26 批11 起全量接线）**：原版 `HttpLogInterceptor`
//! 挂在 App 单例 OkHttp 客户端上，所有出站 HTTP（书源/搜索/正文/图片/TTS…）
//! 按 `AppConfig.recordHttpLog` 采集。我方与之对应的唯一统一出入口是
//! `legado_net::LegadoClient`（含 FFI 主链路、JS 桥共享池、服务端抓取链、
//! 段评/发现/RSS 等），故本批：
//!
//! - `legado-net` 新增 [`legado_net::http_log`] 采集接口（trait + 开关 + 单槽
//!   注册，不依赖本 crate——依赖方向硬约束）；
//! - 本模块提供存储实现 [`StoreHttpLogRecorder`] 并注册到 `legado-net`
//!   （[`install_http_log_recorder`]，FFI `db_open` 与服务启动各自调用，幂等）；
//! - 段评抓取链（`legacy/review_api.rs`）删除手工 `record_*` 调用，避免与
//!   net 层采集**双记录**（单实现原则）；
//! - 开关真源统一为 `config:recordHttpLog`：FFI `setHttpLogRecording` 落库并
//!   切换运行期开关；服务启动经 [`apply_recording_config`] 从库回填。
//!
//! **已知边界（登记）**：`legado-net` 内直接用 `reqwest::Client` 的旁路
//! （`webdav.rs`、`remote_book.rs`）与 `legado-server` handler 内的裸 reqwest
//! （TTS/音频/源更新下载）不经过 `LegadoClient`，不在本采集面内。

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use legado_net::{HttpLogEntry, HttpLogRecorder};
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

    /// 单行摘要（对齐 Kotlin `HttpLogRecord.summary`，`HttpLogStore.add` 同时
    /// 写入 `AppLog` 用）：
    /// `[HTTP#id] METHOD path -> status durationms`，失败追加 ` | error`。
    pub fn summary_line(&self) -> String {
        let path = if self.path.is_empty() {
            "/"
        } else {
            self.path.as_str()
        };
        let mut line = format!(
            "[HTTP#{}] {} {} -> {} {}ms",
            self.id, self.method, path, self.status_code, self.duration
        );
        if let Some(error) = self.error.as_deref() {
            if !error.is_empty() {
                line.push_str(" | ");
                line.push_str(error);
            }
        }
        line
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

/// `legado-net` 采集实现：把统一请求入口的采集记录写入本进程级 ring
///
/// 脱敏/截断/容量全部复用既有 [`record_success`] / [`record_failure`] 单实现。
pub struct StoreHttpLogRecorder;

impl HttpLogRecorder for StoreHttpLogRecorder {
    fn record(&self, entry: HttpLogEntry) {
        match entry.error {
            Some(error) => record_failure(
                &entry.method,
                &entry.url,
                &entry.request_headers,
                &entry.request_body,
                &error,
                entry.duration_ms,
            ),
            None => record_success(
                &entry.method,
                &entry.url,
                &entry.request_headers,
                &entry.request_body,
                entry.status_code,
                &entry.response_headers,
                &entry.response_body,
                entry.response_content_type.as_deref(),
                entry.duration_ms,
            ),
        }
    }
}

/// 注册进程级采集实现（幂等；FFI `db_open` 与服务启动各自调用）
///
/// `legado-net` 侧为 first-wins 单槽：重复注册保留首次实现并忽略后续，
/// 因此 FFI 与服务同进程时不会重复写入（同一 store 单例）。
pub fn install_http_log_recorder() {
    legado_net::http_log::install_recorder(Arc::new(StoreHttpLogRecorder));
}

/// 按 caches 存储值（`config:recordHttpLog`）解析并注入 `legado-net` 运行期开关
///
/// 语义对齐 `AppConfig.recordHttpLog`：缺省/空/其他值 → false，`"true"`/`"1"`
/// → true。返回生效值（供调用方回写响应/日志）。
pub fn apply_recording_config(value: Option<&str>) -> bool {
    let enabled = value
        .map(|raw| matches!(raw.trim(), "true" | "1"))
        .unwrap_or(false);
    legado_net::http_log::set_recording_enabled(enabled);
    enabled
}

/// 写入 ring 并同步一条 `AppLog`（级别 http）
///
/// 对齐 Kotlin `HttpLogStore.add`：`records.addFirst` 后
/// `AppLog.put(record.summary)`——应用日志页与 HTTP 日志页都能看到该请求。
fn store_record(record: HttpLogRecord) {
    legado_core::app_log::push_log(legado_core::app_log::LogLevel::Http, record.summary_line());
    http_log_store().add(record);
}

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
    store_record(record);
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
    store_record(record);
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

/// URL 脱敏（对齐 `HttpLogSanitizer.redactUrl`）：
/// - userinfo（`scheme://user:pass@host`）→ `[redacted]`；
/// - 敏感查询参数值 → `[redacted]`；
/// - 路径段：敏感名路径段的下一段（`/token/abc`）与形似凭据段（恰 2 个 `.`
///   且长度 ≥ 32，对齐 `isCredentialLike`）→ `[redacted]`。
///
/// 差异：原版经 okhttp HttpUrl 重建（编码规范化），此处按字符串分段处理，
/// 不做百分号重编码；userinfo 整体替换为单个 `[redacted]`（原版分别替换
/// 用户名/密码，形如 `[redacted]:[redacted]@host`）。
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
        redact_path_segments(&path)
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
    redact_path_segments(path)
}

/// 路径段脱敏（对齐 `HttpLogSanitizer.redactHttpUrl` 的 `pathSegments` 循环）
///
/// 两条规则（与原先补齐）：
/// 1. **敏感名路径段的下一段** → `[redacted]`（如 `/token/abc`、`/api/sign/xyz`；
///    上一段名按 [`is_sensitive_name`] 判定，含 `token`/`password`/`secret` 等
///    及其后缀形态）——审查批4 P2-4 补齐项；
/// 2. 段形似凭据（恰 2 个 `.` 且长度 ≥ 32，对齐 `isCredentialLike`）→
///    `[redacted]`（JWT 等）。
fn redact_path_segments(path: &str) -> String {
    let segments: Vec<&str> = path.split('/').collect();
    segments
        .iter()
        .enumerate()
        .map(|(index, segment)| {
            let sensitive_previous = index > 0 && is_sensitive_name(segments[index - 1]);
            if sensitive_previous || is_credential_like(segment) {
                REDACTED.to_string()
            } else {
                (*segment).to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// 路径段是否形似凭据（对齐 `HttpLogSanitizer.isCredentialLike`：恰 2 个 `.`
/// 且长度 ≥ 32，覆盖 JWT `header.payload.signature` 形态）
fn is_credential_like(value: &str) -> bool {
    value.matches('.').count() == 2 && value.len() >= 32
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

    /// 审查批4 P2-4：敏感名路径段的下一段必须脱敏（对齐
    /// `HttpLogSanitizer.redactHttpUrl` 的 `pathSegments` 循环）
    #[test]
    fn test_redact_path_sensitive_segment_next() {
        assert_eq!(
            redact_url("https://x.example.com/token/abc?page=2"),
            "https://x.example.com/token/[redacted]?page=2"
        );
        assert_eq!(
            redact_path("https://x.example.com/token/abc"),
            "/token/[redacted]"
        );
        assert_eq!(
            redact_path("https://x.example.com/api/accessToken/secret-value/x"),
            "/api/accessToken/[redacted]/x",
            "大小写变体（accessToken）同样命中敏感名"
        );
        assert_eq!(
            redact_path("https://x.example.com/api/sign/xyz"),
            "/api/sign/[redacted]",
            "sign 后缀敏感名同样命中"
        );
        // 敏感名段自身保留（原版只脱敏下一段）
        assert_eq!(
            redact_path("https://x.example.com/password/only"),
            "/password/[redacted]"
        );
        // 普通路径不受影响
        assert_eq!(
            redact_path("https://x.example.com/tokens/abc"),
            "/tokens/abc",
            "非敏感名（tokens）不得触发下一段脱敏"
        );
    }

    /// 采集实现落存储：成功/失败字段逐项透传（含脱敏与状态码）
    #[test]
    fn test_store_recorder_writes_entry() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = http_log_store();
        store.clear();

        let mut request_headers = HashMap::new();
        request_headers.insert("CookieJar".to_string(), "1".to_string());
        request_headers.insert("Authorization".to_string(), "Bearer x".to_string());
        let mut response_headers = HashMap::new();
        response_headers.insert("Content-Type".to_string(), "application/json".to_string());

        StoreHttpLogRecorder.record(HttpLogEntry {
            method: "POST".to_string(),
            url: "https://x.example.com/token/abc?page=2".to_string(),
            request_headers,
            request_body: "{\"token\":\"secret\"}".to_string(),
            status_code: 201,
            response_headers,
            response_body: "{\"ok\":true}".to_string(),
            response_content_type: Some("application/json".to_string()),
            duration_ms: 12,
            error: None,
        });
        let record = store.latest(1).pop().expect("应写入一条记录");
        assert_eq!(record.method, "POST");
        assert_eq!(record.status_code, 201);
        assert_eq!(record.path, "/token/[redacted]");
        assert!(
            !record.url.contains("abc"),
            "敏感名下一段不得出现在 url：{}",
            record.url
        );
        assert!(record.request_headers.contains("Authorization: [redacted]"));
        assert!(!record.request_headers.contains("Bearer x"));
        assert!(!record.request_body.contains("secret"));
        assert!(record.error.is_none());
        assert_eq!(
            record.summary_line(),
            format!("[HTTP#{}] POST /token/[redacted] -> 201 12ms", record.id),
            "AppLog 摘要行对齐 Kotlin HttpLogRecord.summary"
        );

        StoreHttpLogRecorder.record(HttpLogEntry {
            method: "GET".to_string(),
            url: "https://x.example.com/fail".to_string(),
            request_headers: HashMap::new(),
            request_body: String::new(),
            status_code: -1,
            response_headers: HashMap::new(),
            response_body: String::new(),
            response_content_type: None,
            duration_ms: 3,
            error: Some("Connection failed".to_string()),
        });
        let failure = store.latest(1).pop().expect("应写入失败记录");
        assert_eq!(failure.status_code, -1);
        assert_eq!(failure.error.as_deref(), Some("Connection failed"));
        assert!(
            failure.summary_line().ends_with(" | Connection failed"),
            "失败摘要应追加 error：{}",
            failure.summary_line()
        );
        store.clear();
    }

    /// 开关解析：缺省/空/其他 → false；"true"/"1"（含空白）→ true
    #[test]
    fn test_apply_recording_config() {
        let _g = TEST_LOCK.lock().unwrap();
        assert!(!apply_recording_config(None));
        assert!(!apply_recording_config(Some("")));
        assert!(!apply_recording_config(Some("false")));
        assert!(apply_recording_config(Some("true")));
        assert!(apply_recording_config(Some(" 1 ")));
        // 复位，避免影响同进程其他用例（缺省关闭）
        assert!(!apply_recording_config(None));
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
