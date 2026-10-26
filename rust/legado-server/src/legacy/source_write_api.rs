//! 原版书源 / RSS 源 / 替换规则写端点（B6，10 条）
//!
//! 原版依据（upstream）：
//!
//! | 端点 | 原版实现 | 备注 |
//! |---|---|---|
//! | POST `/saveBookSource` | `BookSourceController.saveSource`（:37-52） | 单条 JSON；`insert` 为 REPLACE upsert；成功 `setData("")` |
//! | POST `/saveBookSources` | `BookSourceController.saveSources`（:54-70） | JSON 数组；逐条跳过空名/空 URL；返回成功写入数组（原版非事务，本实现单事务，见登记） |
//! | POST `/deleteBookSources` | `BookSourceController.deleteSources`（:207-216） | JSON 数组；按 URL 删行 + `sourceVariable_` 缓存；成功 `setData("已执行")` |
//! | POST `/saveJsSource` | `BookSourceController.saveJsSource`（:72-96）+ `validateJsSourceRequest`（:98-129） | `text/plain` 原始脚本；独立校验链（令牌 → Transfer-Encoding → Content-Type → Content-Length）；`JsSourceUpsert.save` 冲突/保留用户态语义 |
//! | POST `/saveRssSource` | `RssSourceController.saveSource`（:24-38） | 单条 JSON；解析失败文案拼接 Gson 消息 |
//! | POST `/saveRssSources` | `RssSourceController.saveSources`（:40-55） | JSON 数组；逐条跳过空名/空 URL |
//! | POST `/deleteRssSources` | `RssSourceController.deleteSources`（:68-76） | 数组；删源 + 文章 + 缓存变量 |
//! | POST `/saveReplaceRule` | `ReplaceRuleController.saveRule`（:23-45） | 单条 JSON；`sortOrder` 缺省/MIN → `MAX(sortOrder)+1` |
//! | POST `/deleteReplaceRule` | `ReplaceRuleController.delete`（:48-59） | 按 id 删除；不存在亦成功 |
//! | POST `/testReplaceRule` | `ReplaceRuleController.testRule`（:68-107） | `{rule, text}`；不落库；正则/字面量/@js: 替换 |
//!
//! 令牌面：以上 10 条全部在 `HttpServer.kt:246-258` 的
//! `PROTECTED_SOURCE_WRITE_ROUTES` 内（该集合另含 B4 已实现的
//! `/openLegacyReview`、`/runLegacyReview`），复用
//! [`super::source_api::JsSourceApiConfig::has_valid_token`]（与
//! `BookSourceController.hasValidJsSourceApiToken` 同一判定）与
//! [`super::source_api::token_error_response`]（原版失败文案 +
//! `Connection: close`）。`saveJsSource` 的专项校验链在令牌之后依序执行，
//! 文案逐条对齐 `validateJsSourceRequest`。
//!
//! 请求体形态：原版 NanoHTTPD 在 `parseBody` 中以 UTF-8 解码后
//! `trim()`，空串不会写入 `files["postData"]`（即控制器收到 `null`）。
//! 本实现用 [`post_data`] 复刻该语义：两侧空白剥除，空串视为缺参。
//! 各控制器对「缺参」与「坏 JSON」的文案不同，均逐条照抄。
//!
//! 登记差异（均不改变浏览器可见语义或为安全增强）：
//! 1. 批量写/删使用单事务（防复发「批量原子性」）——原版 Book/RSS 批量
//!    写逐条 Room insert 无外层事务；失败时本实现整批回滚并返回
//!    `errorMsg`（原版为未捕获异常 → HTTP 500）。删除链路原版即
//!    `runInTransaction`，本实现同事务；
//! 2. Gson 解析失败文案（`localizedMessage`）为英文动态消息，本实现
//!    `deleteBookSources` 统一回退文案「数据格式错误」（原版
//!    `localizedMessage ?: "数据格式错误"` 的回退分支），其余端点常量文案
//!    逐字对齐；
//! 3. `ReplacePreviewConfig.saveImportedSamples/removeSample`
//!    （SharedPreferences 预览样本）Rust 侧无对应存储，按既有
//!    `/getReplaceRules` 口径不落库（该字段本就不在规则 JSON 中）；
//! 4. `SourceConfig.removeSource` / `clearExploreKindsCache` /
//!    `SharedJsScope.remove` 属 Android 进程内配置与 Rhino 作用域缓存，
//!    Web 服务无对应物（登记，不影响落库结果）；
//! 5. `saveJsSource` 删除旧行与写入新行置于同一事务（原版为两次独立
//!    Room 操作，插入失败会丢旧行）；`@js:` 替换在 quickjs 构建下真实
//!    执行，非 quickjs 构建返回错误文本（原版恒可执行）；
//! 6. `saveReplaceRule` / `deleteReplaceRule` 成功路径原版**未调用
//!    `setData`**，返回 `ReturnData` 默认值（`isSuccess=false` +
//!    「未知错误,请联系开发者!」）；本实现按 1:1 行为保留（见
//!    [`upstream_default_envelope`]），不擅自修正。
//! 7. `ReplaceRule` 新增行由 SQLite rowid 分配（`ReplaceRuleRepository::insert`
//!    单实现不写 id）；原版 Room REPLACE 使用请求携带的 id。编辑既有行
//!    （id 命中）走 `update`，语义与 REPLACE 等价。

use std::collections::HashMap;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::Response;
use serde_json::{Map, Value};

use legado_core::content_processor::{preview_single_rule, ReplaceRuleEntry};
use legado_core::models::{BookSource, ReplaceRule, RssSource};
use legado_core::LegadoError;
use legado_db::connection::in_transaction;
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::replace_rule_repository::ReplaceRuleRepository;
use legado_db::repository::rss_article_repository::RssArticleRepository;
use legado_db::repository::rss_source_repository::RssSourceRepository;
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;

use super::source_api::{load_js_source_api_config, token_error_response};
use super::{origin_of, to_response, ReturnData};
use crate::state::AppState;

/// JS 源脚本上限（对齐 `JsSourceUpsert.MAX_SOURCE_BYTES` = 1 MiB）
const JS_SOURCE_MAX_BYTES: i64 = 1024 * 1024;

/// `saveJsSource` 保存超时（对齐 `JS_SOURCE_SAVE_TIMEOUT_MILLIS = 30_000`）
const JS_SOURCE_SAVE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// 写端点请求体上限（原版 NanoHTTPD 无显式上限；axum 默认 2MB 会拒收
/// 大批量书源推送，故放宽到 16MB，仅覆盖本模块 10 条路由）
pub const SOURCE_WRITE_MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

/// 原版 `ReturnData` 构造默认值（`isSuccess=false` /
/// `errorMsg="未知错误,请联系开发者!"` / `data=null`）
///
/// 用于 `saveReplaceRule` / `deleteReplaceRule` 成功路径：原版控制器
/// 不调用 `setData`，信封保持默认值（见模块文档登记差异 6）。
fn upstream_default_envelope() -> ReturnData {
    ReturnData {
        is_success: false,
        error_msg: "未知错误,请联系开发者!".to_string(),
        data: Value::Null,
    }
}

/// 复刻 NanoHTTPD `parseBody` 的 `postData` 语义：UTF-8 解码 + `trim()`，
/// 空串不写入 `files`（控制器收到 `null`）。
fn post_data(body: &Bytes) -> Option<String> {
    let text = String::from_utf8_lossy(body);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// 令牌校验（`PROTECTED_SOURCE_WRITE_ROUTES` 通用面）
async fn token_rejection(
    state: &AppState,
    headers: &HeaderMap,
    uri: &str,
    origin: Option<&str>,
) -> Option<Response> {
    let config = load_js_source_api_config(state).await;
    if config.has_valid_token(headers) {
        None
    } else {
        Some(token_error_response(uri, origin))
    }
}

/// 校验失败响应（原版 `shouldCloseConnection = true`：`ReturnData.setErrorMsg`
/// + `Connection: close`；`saveJsSource` 专项校验链使用）
fn close_error_response(uri: &str, origin: Option<&str>, message: &str) -> Response {
    let mut resp = to_response(&ReturnData::error(message), uri, origin);
    resp.headers_mut()
        .insert(header::CONNECTION, HeaderValue::from_static("close"));
    resp
}

/// 未捕获异常响应（原版 `HttpServer.kt:218-225`：500 + `text/plain` +
/// Web 头 + `Connection: close`）
fn internal_error_response(message: &str, origin: Option<&str>) -> Response {
    let mut resp = Response::builder()
        .status(StatusCode::INTERNAL_SERVER_ERROR)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .body(Body::from(message.to_string()))
        .expect("500 响应构建失败");
    super::web_headers_for_legacy_page(&mut resp, origin);
    resp.headers_mut()
        .insert(header::CONNECTION, HeaderValue::from_static("close"));
    resp
}

// ─── POST /saveBookSource ───────────────────────────────────────────────────

/// POST `/saveBookSource`（BookSourceController.saveSource，:37-52）
///
/// 语义：缺参 →「数据不能为空」；解析失败/`null` →「转换源失败」；
/// 名称或 URL 为空（`TextUtils.isEmpty`，空白串不算空）→
/// 「源名称和URL不能为空」；成功 REPLACE upsert 后 `setData("")`。
pub async fn save_book_source(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/saveBookSource";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("数据不能为空"),
        Some(text) => match serde_json::from_str::<BookSource>(&text) {
            Err(_) => ReturnData::error("转换源失败"),
            Ok(source) => {
                if source.book_source_name.is_empty() || source.book_source_url.is_empty() {
                    ReturnData::error("源名称和URL不能为空")
                } else {
                    let db = state.db.lock().await;
                    match BookSourceRepository::new(db.connection()).insert(&source) {
                        Ok(()) => ReturnData::success(Value::String(String::new())),
                        Err(e) => ReturnData::error(e.to_string()),
                    }
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── POST /saveBookSources ──────────────────────────────────────────────────

/// POST `/saveBookSources`（BookSourceController.saveSources，:54-70）
///
/// 语义：缺参 →「数据为空」；解析失败或空数组 →「转换源失败」；逐条跳过
/// `bookSourceName`/`bookSourceUrl` 为空白（`isNotBlank`）的条目，返回成功
/// 写入的源数组。原版逐条 insert 非事务；本实现经
/// [`BookSourceRepository::insert_batch`] 单事务写入（整批失败回滚）。
pub async fn save_book_sources(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/saveBookSources";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("数据为空"),
        Some(text) => match serde_json::from_str::<Vec<BookSource>>(&text) {
            Err(_) => ReturnData::error("转换源失败"),
            Ok(sources) if sources.is_empty() => ReturnData::error("转换源失败"),
            Ok(sources) => {
                let ok_sources: Vec<BookSource> = sources
                    .into_iter()
                    .filter(|s| {
                        !s.book_source_name.trim().is_empty()
                            && !s.book_source_url.trim().is_empty()
                    })
                    .collect();
                let db = state.db.lock().await;
                match BookSourceRepository::new(db.connection()).insert_batch(&ok_sources) {
                    Ok(()) => match serde_json::to_value(&ok_sources) {
                        Ok(value) => ReturnData::success(value),
                        Err(e) => ReturnData::error(e.to_string()),
                    },
                    Err(e) => ReturnData::error(e.to_string()),
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── POST /deleteBookSources ────────────────────────────────────────────────

/// POST `/deleteBookSources`（BookSourceController.deleteSources，:207-216）
///
/// 语义：缺参 → 原版 `GSON.fromJsonArray(null)` 抛「解析字符串为空」；
/// 坏 JSON →「数据格式错误」（原版取 `localizedMessage` 回退值）；成功按
/// URL 去重删除源行 + `sourceVariable_{url}` 缓存（对齐
/// `SourceHelp.deleteBookSource`），返回「已执行」。
pub async fn delete_book_sources(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/deleteBookSources";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("解析字符串为空"),
        Some(text) => match serde_json::from_str::<Vec<BookSource>>(&text) {
            Err(_) => ReturnData::error("数据格式错误"),
            Ok(sources) => {
                let mut urls: Vec<String> =
                    sources.into_iter().map(|s| s.book_source_url).collect();
                urls.sort();
                urls.dedup();
                let db = state.db.lock().await;
                let conn = db.connection();
                match in_transaction(conn, "批量删除书源", |conn| {
                    let repo = BookSourceRepository::new(conn);
                    let cache = CacheRepository::new(conn);
                    for url in &urls {
                        repo.delete(url)?;
                        cache.delete(&format!("sourceVariable_{url}"))?;
                    }
                    Ok(())
                }) {
                    Ok(()) => ReturnData::success(Value::String("已执行".to_string())),
                    Err(e) => ReturnData::error(e.to_string()),
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── POST /saveJsSource ─────────────────────────────────────────────────────

/// `validateJsSourceRequest` 专项校验链（令牌之后依序执行）
///
/// 返回 `Some(errorMsg)` 表示校验失败（原版 `shouldCloseConnection = true`）。
fn validate_js_source_headers(headers: &HeaderMap) -> Option<&'static str> {
    // 1. Transfer-Encoding（原版 headers.header 大小写不敏感）
    if headers.contains_key("transfer-encoding") {
        return Some("JS源请求不支持 Transfer-Encoding");
    }
    // 2. Content-Type 必须 text/plain（`substringBefore(';')` 后忽略大小写比较）
    let content_type_ok = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(';').next().unwrap_or_default().trim())
        .is_some_and(|v| v.eq_ignore_ascii_case("text/plain"));
    if !content_type_ok {
        return Some("JS源请求 Content-Type 必须为 text/plain");
    }
    // 3. Content-Length 必须存在且可解析
    let content_length = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<i64>().ok());
    let content_length = match content_length {
        Some(value) => value,
        None => return Some("JS源请求必须提供 Content-Length"),
    };
    // 4. 0 <= Content-Length <= 1 MiB（负数与超限同文案）
    if !(0..=JS_SOURCE_MAX_BYTES).contains(&content_length) {
        return Some("JS源脚本不能超过 1 MiB");
    }
    None
}

/// 从 `LegadoError` 提取「localizedMessage」形态的文案
/// （原版 `error.localizedMessage ?: "JS源保存失败"`）
fn js_source_error_message(error: LegadoError) -> String {
    match error {
        LegadoError::JsEngine(message) => message,
        other => other.to_string(),
    }
}

/// POST `/saveJsSource`（BookSourceController.saveJsSource，:72-96）
///
/// 请求：`text/plain` 原始脚本 + 查询参数 `openedSourceUrl`（vue
/// `saveJsSource(e,t)` → `params:{openedSourceUrl:t}`）。
///
/// 流程：令牌 → 专项头校验 → payload 空/超限 → QuickJS 提取配置
/// （30s 超时，对齐 `JS_SOURCE_SAVE_TIMEOUT_MILLIS`）→ `JsSourceUpsert.save`
/// 语义（`openedSourceUrl` 存在性/目标冲突校验、保留用户状态、时间戳写回、
/// 旧 URL 行删除）→ 返回保存后的源。
pub async fn save_js_source(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/saveJsSource";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    if let Some(message) = validate_js_source_headers(&headers) {
        return close_error_response(uri, origin.as_deref(), message);
    }
    let Some(text) = post_data(&body) else {
        return to_response(&ReturnData::error("数据不能为空"), uri, origin.as_deref());
    };
    match legado_js::js_source::js_source_upsert::JsSourceUpsert::validate_payload(&text) {
        Some(legado_js::js_source::js_source_upsert::PayloadIssue::Empty) => {
            return to_response(&ReturnData::error("数据不能为空"), uri, origin.as_deref());
        }
        Some(legado_js::js_source::js_source_upsert::PayloadIssue::TooLarge) => {
            return to_response(
                &ReturnData::error("JS源脚本不能超过 1 MiB"),
                uri,
                origin.as_deref(),
            );
        }
        None => {}
    }

    // 脚本执行是 CPU 密集阻塞操作：移交 blocking 线程池，并套 30s 上限
    // （原版 withTimeout；超时后后台线程结果丢弃，登记）
    let extract_task =
        tokio::task::spawn_blocking(move || legado_js::js_source::js_source_config::extract(&text));
    let extracted = match tokio::time::timeout(JS_SOURCE_SAVE_TIMEOUT, extract_task).await {
        Err(_) => {
            return to_response(&ReturnData::error("JS源保存超时"), uri, origin.as_deref());
        }
        Ok(Err(join_error)) => {
            return to_response(
                &ReturnData::error(format!("JS源保存失败: {join_error}")),
                uri,
                origin.as_deref(),
            );
        }
        Ok(Ok(Err(error))) => {
            return to_response(
                &ReturnData::error(js_source_error_message(error)),
                uri,
                origin.as_deref(),
            );
        }
        Ok(Ok(Ok(source))) => source,
    };

    let opened_source_url = params
        .get("openedSourceUrl")
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());
    let rd = save_js_source_into_db(state.clone(), extracted, opened_source_url).await;
    to_response(&rd, uri, origin.as_deref())
}

/// `JsSourceUpsert.save` 的落库部分（冲突校验 → 保留用户态 → 时间戳 →
/// 旧行清理 → 写入）
async fn save_js_source_into_db(
    state: Arc<AppState>,
    mut source: BookSource,
    opened_source_url: Option<String>,
) -> ReturnData {
    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = BookSourceRepository::new(conn);

    let opened_source = match opened_source_url.as_deref() {
        Some(url) => match repo.find_by_url(url) {
            Ok(Some(found)) => Some(found),
            Ok(None) => {
                return ReturnData::error("原书源已不存在，请重新打开后保存");
            }
            Err(e) => return ReturnData::error(e.to_string()),
        },
        None => None,
    };
    let target_source = match repo.find_by_url(&source.book_source_url) {
        Ok(found) => found,
        Err(e) => return ReturnData::error(e.to_string()),
    };
    // hasTargetConflict：打开的是 A、保存目标 URL 为 B、且 B 已存在
    if let Some(opened) = opened_source.as_ref() {
        if opened.book_source_url != source.book_source_url && target_source.is_some() {
            return ReturnData::error("目标书源URL已存在，请先删除目标书源");
        }
    }
    let old = opened_source.or(target_source);
    let changed = prepare_for_save(&mut source, old.as_ref());
    if !changed {
        if let Some(old) = old {
            // 未变化：原版直接返回旧对象（不写库、不动时间戳）
            return match serde_json::to_value(&old) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            };
        }
    }
    let old_url_to_delete = old
        .as_ref()
        .map(|o| o.book_source_url.clone())
        .filter(|url| *url != source.book_source_url);
    let source_to_save = source;
    let saved = in_transaction(conn, "保存 JS 源", |conn| {
        let repo = BookSourceRepository::new(conn);
        if let Some(old_url) = old_url_to_delete.as_ref() {
            // SourceHelp.deleteBookSource：删行 + 清 sourceVariable_ 缓存
            repo.delete(old_url)?;
            CacheRepository::new(conn).delete(&format!("sourceVariable_{old_url}"))?;
        }
        repo.insert(&source_to_save)?;
        Ok(source_to_save)
    });
    match saved {
        Ok(source) => match serde_json::to_value(&source) {
            Ok(value) => ReturnData::success(value),
            Err(e) => ReturnData::error(e.to_string()),
        },
        Err(e) => ReturnData::error(e.to_string()),
    }
}

/// `JsSourceUpsert.preserveUserState`（:119-129）
fn preserve_user_state(source: &mut BookSource, old: &BookSource) {
    source.enabled = old.enabled;
    source.enabled_explore = old.enabled_explore;
    source.custom_order = old.custom_order;
    source.weight = old.weight;
    source.respond_time = old.respond_time;
    if source
        .book_source_group
        .as_deref()
        .is_none_or(|group| group.trim().is_empty())
    {
        source.book_source_group = old.book_source_group.clone();
    }
}

/// `JsSourceUpsert.prepareForSave`（:91-110）：返回是否发生变化
fn prepare_for_save(source: &mut BookSource, old: Option<&BookSource>) -> bool {
    if let Some(old) = old {
        preserve_user_state(source, old);
    }
    let changed = match old {
        None => true,
        Some(old) => !sources_equivalent(source, old),
    };
    if changed {
        let stamp = current_time_millis();
        source.last_update_time = stamp;
        if let Some(main_js) = source.main_js.as_deref() {
            if let Some(stamped) =
                legado_js::js_source::js_source_config::stamp_last_update_time(main_js, stamp)
            {
                source.main_js = Some(stamped);
            }
        }
    } else if let Some(old) = old {
        source.last_update_time = old.last_update_time;
        source.main_js = old.main_js.clone();
    }
    changed
}

/// 当前毫秒时间戳（对齐 Kotlin `System.currentTimeMillis()`）
fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// `JsSourceUpsert.equalIgnoringManagedUpdateTime`（:112-122）
///
/// 对齐 Kotlin `BookSource.equal` 的字段集合（:245-273）：
/// - 不比较 `lastUpdateTime` / `respondTime` / `weight` / `variable`
///   （`variable` 在原版是 CacheManager 键而非实体字段）；
/// - 顶层字符串字段 `null` 与空串等价；
/// - `ruleSearch`/`ruleExplore`/`ruleBookInfo`/`ruleToc`/`ruleContent`
///   经 `getXxxRule()` 取默认空规则，即 `null` ≡ 空对象；
/// - `exploreScreen` 以 `orEmpty()` 比较；
/// - `ruleReview`/`eventListener`/`customButton` 直接比较。
fn sources_equivalent(left: &BookSource, right: &BookSource) -> bool {
    comparable_source(left) == comparable_source(right)
}

/// 归一化后的比较视图（见 [`sources_equivalent`]）
fn comparable_source(source: &BookSource) -> Value {
    let mut value = match serde_json::to_value(source) {
        Ok(value) => value,
        Err(_) => return Value::Null,
    };
    let Some(object) = value.as_object_mut() else {
        return value;
    };
    // 不参与 Kotlin equal 的字段
    for key in ["lastUpdateTime", "respondTime", "weight", "variable"] {
        object.remove(key);
    }
    // mainJs 的 lastUpdateTime 字面量归一化（stamp=0）
    if let Some(script) = source.main_js.as_deref() {
        let normalized = legado_js::js_source::js_source_config::stamp_last_update_time(script, 0)
            .unwrap_or_else(|| script.to_string());
        object.insert("mainJs".to_string(), Value::String(normalized));
    }
    // 顶层可空字符串：null 与空串等价
    for key in [
        "bookSourceGroup",
        "bookUrlPattern",
        "bookSourceComment",
        "variableComment",
        "concurrentRate",
        "jsLib",
        "mainJs",
        "header",
        "loginUrl",
        "loginUi",
        "loginCheckJs",
        "coverDecodeJs",
        "exploreUrl",
        "searchUrl",
    ] {
        if object.get(key).is_none_or(Value::is_null) {
            object.insert(key.to_string(), Value::String(String::new()));
        }
    }
    // getXxxRule() 默认空规则：null 与空对象等价
    for key in [
        "ruleSearch",
        "ruleExplore",
        "ruleBookInfo",
        "ruleToc",
        "ruleContent",
    ] {
        if object.get(key).is_none_or(Value::is_null) {
            object.insert(key.to_string(), Value::Object(Map::new()));
        }
    }
    // exploreScreen.orEmpty()
    if object.get("exploreScreen").is_none_or(Value::is_null) {
        object.insert("exploreScreen".to_string(), Value::String(String::new()));
    }
    value
}

// ─── POST /saveRssSource · /saveRssSources ──────────────────────────────────

/// POST `/saveRssSource`（RssSourceController.saveSource，:24-38）
///
/// 语义：缺参 →「数据不能为空」；解析失败 →「转换源失败{localizedMessage}」
/// （原版字符串拼接，无分隔符）；名称为空或 URL 为空 →「源名称和URL不能为空」；
/// 成功 REPLACE upsert 后 `setData("")`。
pub async fn save_rss_source(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/saveRssSource";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("数据不能为空"),
        Some(text) => match serde_json::from_str::<RssSource>(&text) {
            Err(error) => ReturnData::error(format!("转换源失败{error}")),
            Ok(source) => {
                if source.source_name.is_empty() || source.source_url.is_empty() {
                    ReturnData::error("源名称和URL不能为空")
                } else {
                    let db = state.db.lock().await;
                    match RssSourceRepository::new(db.connection()).insert(&source) {
                        Ok(_) => ReturnData::success(Value::String(String::new())),
                        Err(e) => ReturnData::error(e),
                    }
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

/// POST `/saveRssSources`（RssSourceController.saveSources，:40-55）
///
/// 语义：缺参 →「数据不能为空」；解析失败或空数组 →「转换源失败」；逐条
/// 跳过名称为空白（`isBlank`）或 URL 为空的条目；返回成功写入数组。
/// 本实现单事务写入（原版逐条 Room insert，登记差异 1）。
pub async fn save_rss_sources(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/saveRssSources";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("数据不能为空"),
        Some(text) => match serde_json::from_str::<Vec<RssSource>>(&text) {
            Err(_) => ReturnData::error("转换源失败"),
            Ok(sources) if sources.is_empty() => ReturnData::error("转换源失败"),
            Ok(sources) => {
                let ok_sources: Vec<RssSource> = sources
                    .into_iter()
                    .filter(|s| !s.source_name.trim().is_empty() && !s.source_url.trim().is_empty())
                    .collect();
                let db = state.db.lock().await;
                let conn = db.connection();
                let written = in_transaction(conn, "批量写入 RSS 源", |conn| {
                    let repo = RssSourceRepository::new(conn);
                    for source in &ok_sources {
                        repo.insert(source).map_err(LegadoError::Database)?;
                    }
                    Ok(())
                });
                match written {
                    Ok(()) => match serde_json::to_value(&ok_sources) {
                        Ok(value) => ReturnData::success(value),
                        Err(e) => ReturnData::error(e.to_string()),
                    },
                    Err(e) => ReturnData::error(e.to_string()),
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

/// POST `/deleteRssSources`（RssSourceController.deleteSources，:68-76）
///
/// 语义：缺参 →「没有传递数据」；坏 JSON →「格式不对」；成功按源删除
/// RSS 源行、该源文章（`rssArticles`）与 `sourceVariable_` 缓存
/// （对齐 `SourceHelp.deleteRssSources`），返回「已执行」。
pub async fn delete_rss_sources(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/deleteRssSources";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("没有传递数据"),
        Some(text) => match serde_json::from_str::<Vec<RssSource>>(&text) {
            Err(_) => ReturnData::error("格式不对"),
            Ok(sources) => {
                let db = state.db.lock().await;
                let conn = db.connection();
                match in_transaction(conn, "批量删除 RSS 源", |conn| {
                    let repo = RssSourceRepository::new(conn);
                    let articles = RssArticleRepository::new(conn);
                    let cache = CacheRepository::new(conn);
                    for source in &sources {
                        repo.delete(&source.source_url)
                            .map_err(LegadoError::Database)?;
                        articles.delete_by_source(&source.source_url)?;
                        cache.delete(&format!("sourceVariable_{}", source.source_url))?;
                    }
                    Ok(())
                }) {
                    Ok(()) => ReturnData::success(Value::String("已执行".to_string())),
                    Err(e) => ReturnData::error(e.to_string()),
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── POST /saveReplaceRule · /deleteReplaceRule · /testReplaceRule ──────────

/// 解析替换规则 JSON（返回解析后的规则与 `sortOrder` 是否缺省）
fn parse_replace_rule(text: &str) -> Option<(ReplaceRule, bool)> {
    let value: Value = serde_json::from_str(text).ok()?;
    let order_missing = value
        .get("sortOrder")
        .is_none_or(|v| v.as_i64() == Some(i64::from(i32::MIN)));
    let rule: ReplaceRule = serde_json::from_value(value).ok()?;
    Some((rule, order_missing))
}

/// POST `/saveReplaceRule`（ReplaceRuleController.saveRule，:23-45）
///
/// 语义：缺参 →「数据不能为空」；坏 JSON →「格式不对」；
/// `sortOrder` 缺省（Gson 实体默认 `Int.MIN_VALUE`）或显式 `Int.MIN_VALUE`
/// → `MAX(sortOrder)+1`；id 命中既有行走全列 update（等价 Room REPLACE），
/// 否则插入新行。
///
/// **返回值形态**：原版成功路径未调用 `setData`，信封保持构造默认
/// （见 [`upstream_default_envelope`]）。
pub async fn save_replace_rule(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/saveReplaceRule";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("数据不能为空"),
        Some(text) => match parse_replace_rule(&text) {
            None => ReturnData::error("格式不对"),
            Some((mut rule, order_missing)) => {
                let db = state.db.lock().await;
                let repo = ReplaceRuleRepository::new(db.connection());
                match repo.find_all() {
                    Err(e) => ReturnData::error(e.to_string()),
                    Ok(rules) => {
                        if order_missing || rule.order == i32::MIN {
                            let max_order = rules.iter().map(|r| r.order).max().unwrap_or(0);
                            rule.order = max_order.wrapping_add(1);
                        }
                        let exists = rule.id != 0 && rules.iter().any(|r| r.id == rule.id);
                        let written = if exists {
                            repo.update(&rule)
                        } else {
                            repo.insert(&rule).map(|_| ())
                        };
                        match written {
                            Ok(()) => upstream_default_envelope(),
                            Err(e) => ReturnData::error(e.to_string()),
                        }
                    }
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

/// POST `/deleteReplaceRule`（ReplaceRuleController.delete，:48-59）
///
/// 语义：缺参 →「数据不能为空」；坏 JSON →「格式不对」；按 id 删除
/// （不存在亦成功）。成功路径同样保持原版默认信封。
pub async fn delete_replace_rule(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/deleteReplaceRule";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let rd = match post_data(&body) {
        None => ReturnData::error("数据不能为空"),
        Some(text) => match parse_replace_rule(&text) {
            None => ReturnData::error("格式不对"),
            Some((rule, _)) => {
                let db = state.db.lock().await;
                match ReplaceRuleRepository::new(db.connection()).delete(rule.id) {
                    Ok(()) => upstream_default_envelope(),
                    Err(e) => ReturnData::error(e.to_string()),
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

/// POST `/testReplaceRule`（ReplaceRuleController.testRule，:68-107）
///
/// 请求：`{"rule": ReplaceRule | JSON字符串, "text": "待处理文本"}`。
/// 语义：
/// - 缺参 →「数据不能为空」；坏 JSON / `rule` 缺失或类型不符 →
///   「格式不对」；
/// - `pattern` 为空时原版先 `setErrorMsg("替换规则不能为空")` 但**不返回**，
///   随后 `setData` 覆盖为成功——照抄该流程（空 pattern 按
///   `String.replace("", ...)` 在每个字符边界插入替换内容）；
/// - 正则/字面量替换复用
///   [`legado_core::content_processor::preview_single_rule`]（单实现：
///   Java 方言适配 + 超时保护 + `@js:` 执行）；规则级错误按原版
///   `catch → e.stackTraceStr → setData` 作为成功数据返回；
/// - `text` 缺失或非字符串时原版抛未捕获异常 → HTTP 500（见
///   [`internal_error_response`]）。
pub async fn test_replace_rule(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/testReplaceRule";
    if let Some(resp) = token_rejection(&state, &headers, uri, origin.as_deref()).await {
        return resp;
    }
    let Some(text) = post_data(&body) else {
        return to_response(&ReturnData::error("数据不能为空"), uri, origin.as_deref());
    };
    let map = match serde_json::from_str::<Map<String, Value>>(&text) {
        Ok(map) => map,
        Err(_) => return to_response(&ReturnData::error("格式不对"), uri, origin.as_deref()),
    };
    let rule = match map.get("rule") {
        Some(Value::String(json)) => serde_json::from_str::<ReplaceRule>(json).ok(),
        Some(value @ Value::Object(_)) => serde_json::from_value::<ReplaceRule>(value.clone()).ok(),
        _ => None,
    };
    let Some(rule) = rule else {
        return to_response(&ReturnData::error("格式不对"), uri, origin.as_deref());
    };
    // 原版 `map["text"] as String`：缺失/非字符串 → ClassCastException /
    // NullPointerException → HttpServer 外层 catch → 500
    let Some(Value::String(text)) = map.get("text") else {
        return internal_error_response(
            "替换测试文本缺失或类型不符（text 必须为字符串）",
            origin.as_deref(),
        );
    };
    let output = apply_test_replace_rule(text, &rule);
    to_response(
        &ReturnData::success(Value::String(output)),
        uri,
        origin.as_deref(),
    )
}

/// 对给定文本应用单条替换规则（空 pattern 分支对齐原版
/// `setErrorMsg` 后继续执行并被 `setData` 覆盖的行为）
fn apply_test_replace_rule(text: &str, rule: &ReplaceRule) -> String {
    if rule.pattern.is_empty() {
        // 原版 `String.replace("", replacement)` / `"".toRegex()`：在每个
        // 字符边界插入替换内容
        if rule.is_regex {
            return match regex::Regex::new("") {
                Ok(compiled) => compiled
                    .replace_all(text, rule.replacement.as_str())
                    .into_owned(),
                Err(_) => text.to_string(),
            };
        }
        return text.replace("", &rule.replacement);
    }
    let entry = ReplaceRuleEntry::from_replace_rule(rule);
    match preview_single_rule(text, &entry, &test_rule_js_executor()) {
        Ok(output) => output,
        // 原版 catch 分支把 `e.stackTraceStr` 作为 data 返回（success）
        Err(error) => error,
    }
}

/// `@js:` 替换执行器（quickjs 构建下真实执行；否则返回错误文本）
fn test_rule_js_executor() -> Option<Arc<dyn legado_core::content_processor::ReplaceJsExecutor>> {
    #[cfg(feature = "quickjs")]
    {
        Some(Arc::new(QuickJsReplaceExecutor))
    }
    #[cfg(not(feature = "quickjs"))]
    {
        None
    }
}

/// 替换规则 `@js:` 执行器适配（对齐 `ReplaceJsExecutor` 契约）
#[cfg(feature = "quickjs")]
struct QuickJsReplaceExecutor;

#[cfg(feature = "quickjs")]
impl legado_core::content_processor::ReplaceJsExecutor for QuickJsReplaceExecutor {
    fn eval(&self, js_code: &str, result: &str) -> Result<String, String> {
        use legado_js::engine::JsEngine;

        let sandbox = legado_js::sandbox::SandboxConfig::default()
            .with_timeout(std::time::Duration::from_secs(3));
        let engine = legado_js::QuickJsEngine::new(sandbox).map_err(|e| e.to_string())?;
        engine
            .eval_with_bindings(js_code, &[("result", legado_js::JsValue::from(result))])
            .map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `post_data`：两侧空白剥除；全空白/空体视为 `None`（NanoHTTPD 语义）
    #[test]
    fn test_post_data_trims_and_treats_blank_as_none() {
        assert_eq!(
            post_data(&Bytes::from_static(b"  {\"a\":1}\n")),
            Some("{\"a\":1}".to_string())
        );
        assert_eq!(post_data(&Bytes::from_static(b"")), None);
        assert_eq!(post_data(&Bytes::from_static(b" \r\n\t ")), None);
    }

    /// `validateJsSourceHeaders` 校验链顺序与文案
    #[test]
    fn test_validate_js_source_headers_chain() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/plain; charset=utf-8"),
        );
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("12"));
        assert_eq!(validate_js_source_headers(&headers), None);

        // Transfer-Encoding 优先于 Content-Type
        headers.insert("transfer-encoding", HeaderValue::from_static("chunked"));
        assert_eq!(
            validate_js_source_headers(&headers),
            Some("JS源请求不支持 Transfer-Encoding")
        );
        headers.remove("transfer-encoding");

        // Content-Type 必须是 text/plain（大小写不敏感、忽略参数）
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("TEXT/PLAIN;charset=utf-8"),
        );
        assert_eq!(validate_js_source_headers(&headers), None);
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        assert_eq!(
            validate_js_source_headers(&headers),
            Some("JS源请求 Content-Type 必须为 text/plain")
        );

        // Content-Length 缺失/非法
        headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
        headers.remove(header::CONTENT_LENGTH);
        assert_eq!(
            validate_js_source_headers(&headers),
            Some("JS源请求必须提供 Content-Length")
        );
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("abc"));
        assert_eq!(
            validate_js_source_headers(&headers),
            Some("JS源请求必须提供 Content-Length")
        );

        // 负数/超限同文案
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("-1"));
        assert_eq!(
            validate_js_source_headers(&headers),
            Some("JS源脚本不能超过 1 MiB")
        );
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("1048577"));
        assert_eq!(
            validate_js_source_headers(&headers),
            Some("JS源脚本不能超过 1 MiB")
        );
    }

    /// 空 pattern 的替换与原版 `String.replace("", ...)` 一致（逐字符边界插入）
    #[test]
    fn test_apply_test_replace_rule_empty_pattern() {
        let rule = ReplaceRule {
            pattern: String::new(),
            replacement: "X".to_string(),
            is_regex: false,
            ..ReplaceRule::default()
        };
        assert_eq!(apply_test_replace_rule("ab", &rule), "XaXbX");

        let regex_rule = ReplaceRule {
            pattern: String::new(),
            replacement: "X".to_string(),
            is_regex: true,
            ..ReplaceRule::default()
        };
        assert_eq!(apply_test_replace_rule("ab", &regex_rule), "XaXbX");
    }

    /// 字面量/正则替换（不依赖 JS 引擎）
    #[test]
    fn test_apply_test_replace_rule_literal_and_regex() {
        let literal = ReplaceRule {
            pattern: "abc".to_string(),
            replacement: "X".to_string(),
            is_regex: false,
            ..ReplaceRule::default()
        };
        assert_eq!(apply_test_replace_rule("abcabc", &literal), "XX");

        let regex_rule = ReplaceRule {
            pattern: "a(b+)c".to_string(),
            replacement: "$1".to_string(),
            is_regex: true,
            ..ReplaceRule::default()
        };
        assert_eq!(apply_test_replace_rule("abbbc", &regex_rule), "bbb");
    }

    /// 非法正则：原版 catch 分支把错误文本作为成功数据返回
    #[test]
    fn test_apply_test_replace_rule_invalid_regex_returns_error_text() {
        let rule = ReplaceRule {
            pattern: "(".to_string(),
            replacement: "x".to_string(),
            is_regex: true,
            ..ReplaceRule::default()
        };
        let output = apply_test_replace_rule("text", &rule);
        assert!(!output.is_empty());
        assert_ne!(output, "text");
    }

    /// 用户态保留：enabled/enabledExplore/customOrder/weight/respondTime
    /// 与空分组回填
    #[test]
    fn test_preserve_user_state() {
        let old = BookSource {
            book_source_url: "https://a".to_string(),
            book_source_group: Some("old-group".to_string()),
            enabled: false,
            enabled_explore: false,
            custom_order: 7,
            weight: 9,
            respond_time: 123,
            ..BookSource::default()
        };
        let mut source = BookSource {
            book_source_url: "https://a".to_string(),
            book_source_group: Some("   ".to_string()),
            enabled: true,
            ..BookSource::default()
        };
        preserve_user_state(&mut source, &old);
        assert!(!source.enabled);
        assert!(!source.enabled_explore);
        assert_eq!(source.custom_order, 7);
        assert_eq!(source.weight, 9);
        assert_eq!(source.respond_time, 123);
        assert_eq!(source.book_source_group.as_deref(), Some("old-group"));
    }

    /// 未变化判定：忽略 lastUpdateTime/weight/variable 与 mainJs 时间戳字面量
    #[test]
    fn test_sources_equivalent_ignores_managed_fields() {
        let left = BookSource {
            book_source_url: "https://a".to_string(),
            book_source_name: "源".to_string(),
            last_update_time: 1,
            weight: 1,
            variable: "x".to_string(),
            main_js: Some("var config = { lastUpdateTime: 111 };".to_string()),
            ..BookSource::default()
        };
        let right = BookSource {
            book_source_url: "https://a".to_string(),
            book_source_name: "源".to_string(),
            last_update_time: 2,
            weight: 2,
            variable: "y".to_string(),
            main_js: Some("var config = { lastUpdateTime: 222 };".to_string()),
            ..BookSource::default()
        };
        assert!(sources_equivalent(&left, &right));

        let mut changed = right;
        changed.book_source_name = "新名字".to_string();
        assert!(!sources_equivalent(&left, &changed));
    }
}
