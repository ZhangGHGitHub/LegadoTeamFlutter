//! 原版 `BookSourceController` / `RssSourceController` / `ReplaceRuleController` /
//! `HttpLogController` 的管理读端点（B4 管理读+令牌 7 条）
//!
//! 原版依据（upstream）：
//! - `HttpServer.kt:133-154`（GET 分派）与 `:246-262`（保护路由集合）；
//! - `BookSourceController.kt:28-35`（sources）/`:189-194`（isJsSourceApiTokenRequired）/
//!   `:196-205`（getSource）/`:138-145`（hasValidJsSourceApiToken）；
//! - `RssSourceController.kt:15-22`（sources）/`:57-66`（getSource）；
//! - `ReplaceRuleController.kt:14-20`（allRules，**data 为规则数组的 JSON 字符串**，
//!   `setData(GSON.toJson(rules))` 双层编码形态照抄）；
//! - `HttpLogController.kt:13-39`（getLogs/getLog，limit clamp(1, MAX_RECORDS)）。
//!
//! 令牌语义（对齐 `BookSourceController.hasValidJsSourceApiToken`）：
//! - `jsSourceApiTokenRequired`（caches `config:jsSourceApiTokenRequired`，缺省
//!   **true**，对齐 AppConfig.kt:524-525 默认值）为 false 时全部放行；
//! - 否则校验 `x-legado-token` 头与 `config:jsSourceApiToken` 字节级相等
//!   （复用 [`crate::server::matches_js_source_api_token`]，与 MCP 路径同一实现）；
//! - 失败统一 `errorMsg`「Web 书源访问令牌未配置或不正确」，并按原版
//!   `shouldCloseConnection` 语义追加 `Connection: close`（HttpServer.kt:71-73）；
//! - 受保护 GET 面 = `PROTECTED_HTTP_LOG_READ_ROUTES`（仅 getHttpLog(s)，
//!   HttpServer.kt:259-262）；getBookSource(s)/getRssSource(s)/getReplaceRules/
//!   getJsSourceApiTokenRequired 均不在保护集合，**不要求令牌**。
//!   `getJsSourceApiTokenRequired` 本身恒放行（vue 以其返回值决定是否弹令牌
//!   输入框，vue assets index-toG2697L.js `Ye()`）。
//!
//! 登记差异：
//! - `jsSourceApiTokenRequired` 配置键由本实现按原版 PreferKey 名从 caches
//!   读取；Flutter 侧尚无写入入口（无 UI），缺省恒 true，行为与原版默认一致；
//! - `previewText`（原版 `ReplacePreviewConfig.withSamples` 从本地 SharedPreferences
//!   合并的编辑示例）Rust 侧无对应存储，规则 JSON 不含该字段（原版无样本时
//!   GSON 同样省略 null 字段，浏览器可见结果一致）。

use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, HeaderValue};
use axum::response::Response;
use serde_json::{json, Value};

use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::replace_rule_repository::ReplaceRuleRepository;
use legado_db::repository::rss_source_repository::RssSourceRepository;
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;

use super::http_log::{http_log_store, HttpLogRecord, HttpLogSummary, MAX_RECORDS};
use super::{origin_of, to_response, ReturnData};
use crate::server::matches_js_source_api_token;
use crate::state::AppState;

/// 令牌请求头（对齐 Kotlin `JS_SOURCE_TOKEN_HEADER`）
pub const JS_SOURCE_TOKEN_HEADER: &str = "x-legado-token";

/// caches 表配置键（对齐 `PreferKey.jsSourceApiToken` / `.jsSourceApiTokenRequired` /
/// `.recordHttpLog` 与 FFI `config_api::CONFIG_PREFIX` 约定）
pub const CONFIG_JS_SOURCE_API_TOKEN: &str = "config:jsSourceApiToken";
const CONFIG_JS_SOURCE_API_TOKEN_REQUIRED: &str = "config:jsSourceApiTokenRequired";
pub const CONFIG_RECORD_HTTP_LOG: &str = "config:recordHttpLog";

/// 令牌配置快照（对齐 `AppConfig.jsSourceApiToken` / `jsSourceApiTokenRequired`）
#[derive(Debug, Clone)]
pub struct JsSourceApiConfig {
    /// 是否强制校验（缺省 true）
    pub required: bool,
    /// 已配置令牌（None = 未配置）
    pub token: Option<String>,
}

impl JsSourceApiConfig {
    /// 对齐 `hasValidJsSourceApiToken(headers, configuredToken, tokenRequired)`
    pub fn has_valid_token(&self, headers: &HeaderMap) -> bool {
        if !self.required {
            return true;
        }
        let actual = headers
            .get(JS_SOURCE_TOKEN_HEADER)
            .and_then(|v| v.to_str().ok());
        matches_js_source_api_token(self.token.as_deref().unwrap_or(""), actual)
    }
}

/// 解析 `config:jsSourceApiTokenRequired` 存储值（对齐
/// `AppConfig.getPrefBoolean(key, true)` 语义：缺省/空串/其他值 → true）
///
/// 提取为生产函数供解析与单测共用，避免测试镜像闭包与实现漂移。
fn parse_required(raw: &str) -> bool {
    !matches!(raw.trim(), "false" | "0")
}

/// 从 caches 表读取令牌配置（`config:jsSourceApiToken` / `config:jsSourceApiTokenRequired`）
pub async fn load_js_source_api_config(state: &AppState) -> JsSourceApiConfig {
    let db = state.db.lock().await;
    let repo = CacheRepository::new(db.connection());
    let token = repo
        .get(CONFIG_JS_SOURCE_API_TOKEN)
        .ok()
        .flatten()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());
    let required = repo
        .get(CONFIG_JS_SOURCE_API_TOKEN_REQUIRED)
        .ok()
        .flatten()
        .map(|v| parse_required(&v))
        // 对齐 AppConfig.getPrefBoolean(key, true) 缺省 true
        .unwrap_or(true);
    JsSourceApiConfig { required, token }
}

/// `config:recordHttpLog`（对齐 `AppConfig.recordHttpLog`，缺省 false）
pub async fn record_http_log_enabled(state: &AppState) -> bool {
    let db = state.db.lock().await;
    CacheRepository::new(db.connection())
        .get(CONFIG_RECORD_HTTP_LOG)
        .ok()
        .flatten()
        .map(|v| matches!(v.trim(), "true" | "1"))
        .unwrap_or(false)
}

/// 令牌校验失败响应（对齐 HttpServer.kt:64-73：`ReturnData.setErrorMsg` +
/// `shouldCloseConnection`）
pub fn token_error_response(uri_path: &str, origin: Option<&str>) -> Response {
    let mut resp = to_response(
        &ReturnData::error("Web 书源访问令牌未配置或不正确"),
        uri_path,
        origin,
    );
    // 原版 response.closeConnection(true)（HttpServer.kt:205-207）：
    // HTTP/1.1 语义为 Connection: close（hyper 据此在响应后关闭连接）
    resp.headers_mut().insert(
        axum::http::header::CONNECTION,
        HeaderValue::from_static("close"),
    );
    resp
}

// ─── GET /getBookSource ─────────────────────────────────────────────────────

/// GET `/getBookSource?url=`（BookSourceController.getSource，:196-205）
pub async fn get_book_source(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getBookSource";
    let url = params.get("url").cloned().unwrap_or_default();
    if url.is_empty() {
        return to_response(
            &ReturnData::error("参数url不能为空，请指定源地址"),
            uri,
            origin.as_deref(),
        );
    }
    let rd = {
        let db = state.db.lock().await;
        match BookSourceRepository::new(db.connection()).find_by_url(&url) {
            Ok(Some(source)) => match serde_json::to_value(&source) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            },
            Ok(None) => ReturnData::error("未找到源，请检查书源地址"),
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getBookSources ────────────────────────────────────────────────────

/// GET `/getBookSources`（BookSourceController.sources，:28-35）
///
/// 取数对齐 `appDb.bookSourceDao.all`（全部书源，含停用，按 customOrder 升序）；
/// 空列表 → errorMsg「设备源列表为空」。
pub async fn get_book_sources(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getBookSources";
    let rd = {
        let db = state.db.lock().await;
        match BookSourceRepository::new(db.connection()).find_all() {
            Ok(sources) if sources.is_empty() => ReturnData::error("设备源列表为空"),
            Ok(sources) => match serde_json::to_value(&sources) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            },
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getRssSource ──────────────────────────────────────────────────────

/// GET `/getRssSource?url=`（RssSourceController.getSource，:57-66）
pub async fn get_rss_source(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getRssSource";
    let url = params.get("url").cloned().unwrap_or_default();
    if url.is_empty() {
        return to_response(
            &ReturnData::error("参数url不能为空，请指定书源地址"),
            uri,
            origin.as_deref(),
        );
    }
    let rd = {
        let db = state.db.lock().await;
        match RssSourceRepository::new(db.connection()).find_by_url(&url) {
            Ok(Some(source)) => match serde_json::to_value(&source) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            },
            Ok(None) => ReturnData::error("未找到源，请检查源地址"),
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getRssSources ─────────────────────────────────────────────────────

/// GET `/getRssSources`（RssSourceController.sources，:15-22）；空 → 「源列表为空」
pub async fn get_rss_sources(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getRssSources";
    let rd = {
        let db = state.db.lock().await;
        match RssSourceRepository::new(db.connection()).find_all() {
            Ok(sources) if sources.is_empty() => ReturnData::error("源列表为空"),
            Ok(sources) => match serde_json::to_value(&sources) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            },
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getReplaceRules ───────────────────────────────────────────────────

/// GET `/getReplaceRules`（ReplaceRuleController.allRules，:14-20）
///
/// **形态对齐**：原版 `setData(GSON.toJson(rules))` 把规则数组序列化成字符串后
/// 再 setData —— `data` 是「JSON 字符串」（双层编码），照抄该形态；空列表为
/// `"[]"` 字符串（原版同路径，不回错误）。
pub async fn get_replace_rules(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getReplaceRules";
    let rd = {
        let db = state.db.lock().await;
        match ReplaceRuleRepository::new(db.connection()).find_all() {
            Ok(rules) => match serde_json::to_string(&rules) {
                Ok(json) => ReturnData::success(Value::String(json)),
                Err(e) => ReturnData::error(e.to_string()),
            },
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getJsSourceApiTokenRequired ───────────────────────────────────────

/// GET `/getJsSourceApiTokenRequired`（BookSourceController.isJsSourceApiTokenRequired，
/// :189-194）——data 为裸布尔；本端点恒放行（vue 以其结果决定是否索要令牌）
pub async fn get_js_source_api_token_required(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getJsSourceApiTokenRequired";
    let config = load_js_source_api_config(&state).await;
    to_response(
        &ReturnData::success(Value::Bool(config.required)),
        uri,
        origin.as_deref(),
    )
}

// ─── GET /getHttpLogs · /getHttpLog（令牌保护） ─────────────────────────────

/// GET `/getHttpLogs?limit=`（HttpLogController.getLogs，:13-31；受
/// `PROTECTED_HTTP_LOG_READ_ROUTES` 令牌保护）
///
/// limit → 解析失败或缺省取 `MAX_RECORDS`(50)，成功值 `coerceIn(1, 50)`；
/// data = `{recording, logs:[summary...]}`。
pub async fn get_http_logs(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getHttpLogs";
    let config = load_js_source_api_config(&state).await;
    if !config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let recording = record_http_log_enabled(&state).await;
    // Kotlin `toIntOrNull()?.coerceIn(1, MAX_RECORDS) ?: MAX_RECORDS`：
    // 负数/0 夹到 1，非数字缺省 50（"-1" → 1 而非 50）
    let limit = params
        .get("limit")
        .and_then(|v| v.parse::<i64>().ok())
        .map(|v| v.clamp(1, MAX_RECORDS as i64) as usize)
        .unwrap_or(MAX_RECORDS);
    let logs: Vec<HttpLogSummary> = http_log_store()
        .latest(limit)
        .iter()
        .map(HttpLogRecord::summary)
        .collect();
    to_response(
        &ReturnData::success(json!({
            "recording": recording,
            "logs": logs,
        })),
        uri,
        origin.as_deref(),
    )
}

/// GET `/getHttpLog?id=`（HttpLogController.getLog，:33-39；令牌保护同上）
pub async fn get_http_log(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getHttpLog";
    let config = load_js_source_api_config(&state).await;
    if !config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let id = match params.get("id").and_then(|v| v.parse::<i64>().ok()) {
        Some(id) => id,
        None => return to_response(&ReturnData::error("参数id不能为空"), uri, origin.as_deref()),
    };
    let rd = match http_log_store().get(id) {
        Some(record) => match serde_json::to_value(&record) {
            Ok(value) => ReturnData::success(value),
            Err(e) => ReturnData::error(e.to_string()),
        },
        None => ReturnData::error(format!("未找到 HTTP 记录 #{id}")),
    };
    to_response(&rd, uri, origin.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 令牌判定（对齐 hasValidJsSourceApiToken 分支语义）
    #[test]
    fn test_js_source_api_config_token_semantics() {
        let mut headers = HeaderMap::new();
        // required=false 全放行（即便令牌缺失/头缺失）
        let config = JsSourceApiConfig {
            required: false,
            token: None,
        };
        assert!(config.has_valid_token(&headers));
        // required=true、未配置令牌 → 一律失败（matchesJsSourceApiToken expected 空）
        let config = JsSourceApiConfig {
            required: true,
            token: None,
        };
        assert!(!config.has_valid_token(&headers));
        headers.insert("x-legado-token", "secret".parse().unwrap());
        assert!(!config.has_valid_token(&headers));
        // required=true、令牌匹配 → 通过；头名大小写不敏感（axum HeaderMap 语义）
        let config = JsSourceApiConfig {
            required: true,
            token: Some("secret".to_string()),
        };
        assert!(config.has_valid_token(&headers));
        let mut upper = HeaderMap::new();
        upper.insert("X-Legado-Token", "secret".parse().unwrap());
        assert!(config.has_valid_token(&upper));
        assert!(!config.has_valid_token(&HeaderMap::new()));
    }

    /// 解析口径直接测生产函数（不再维护测试侧镜像闭包）
    #[test]
    fn test_required_config_default_true() {
        // 存储值形态：空串/true/其他 → true；"false"/"0" → false
        assert!(parse_required(""));
        assert!(parse_required("  "));
        assert!(parse_required("true"));
        assert!(!parse_required("false"));
        assert!(!parse_required(" 0 "));
        // 缺省（缓存无键）由 load_js_source_api_config 的 unwrap_or(true) 覆盖
    }
}
