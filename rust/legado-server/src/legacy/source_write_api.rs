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
//! | POST `/saveReplaceRule` | `ReplaceRuleController.saveRule`（:23-45） | 单条 JSON；插入时 `sortOrder` 缺省/MIN → `MAX(sortOrder)+1`；既有行更新不改排序 |
//! | POST `/deleteReplaceRule` | `ReplaceRuleController.delete`（:48-59） | 按 id 删除；不存在亦成功 |
//! | POST `/testReplaceRule` | `ReplaceRuleController.testRule`（:68-107） | `{rule, text}`；不落库；正则/字面量/@js: 替换 |
//!
//! 令牌面：本模块 10 条端点全部受保护，但分属两条链（`HttpServer.kt:58-73`）：
//! - **9 条**在原版 `PROTECTED_SOURCE_WRITE_ROUTES`（HttpServer.kt:246-258，该集合
//!   共 11 条，另含 B4 已实现的 `/openLegacyReview`、`/runLegacyReview`）内，
//!   由 `hasValidJsSourceApiToken` 统一判定；
//! - **`saveJsSource` 不在该集合**：由独立 [`validate_js_source_headers`] 链
//!   保护（HttpServer.kt:60-62），该链第一步即令牌校验（对齐
//!   `BookSourceController.validateJsSourceRequest`），之后才检查
//!   Transfer-Encoding / Content-Type / Content-Length。
//!
//! 本轨 [`PROTECTED_SOURCE_WRITE_ROUTES`] 常量把上述 9 条 + `saveJsSource` +
//! 批30 检验会话两条（`/startBookSourceCheck`、`/stopBookSourceCheck`）合并为
//! 12 条，供路由级前置中间件统一使用（原版集合本就包含检验两条）；批17 三审
//! 再追加 Web 端口 `/mcp/call`（可执行任意 JS 的 MCP 工具调用面）为第 13 条；
//! 审查批 P0-1（2026-11-13）再追加自研 `/api/webbook/{search,info,chapters,
//! content}` 四条（请求体自带完整书源，`mainJs`/`@js:` 在 QuickJS 中真实执行，
//! 属同等级任意 JS 执行面）为第 14–17 条；审查批 P1-1（2026-11-13）再追加
//! 自研 REST 源写面四条（方法限定）为第 18–21 条：`POST /api/sources`、
//! `PUT|DELETE /api/sources/{id}`、`POST /api/sources/update`。
//!
//! 两侧共用 [`super::source_api::JsSourceApiConfig::has_valid_token`]（与
//! `BookSourceController.hasValidJsSourceApiToken` 同一判定）与
//! [`super::source_api::token_error_response`]（原版失败文案 +
//! `Connection: close`）。P2-2 起另有路由级中间件
//! [`source_write_token_guard`] 在 body 提取前前置校验（未授权不读 body），
//! handler 内校验保留为纵深防御。
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
//!    「未知错误,请联系开发者!」）——网页端因此把成功显示为未知错误。
//!    批23 按用户裁决**不再 1:1 保留**：成功返回显式信封
//!    `isSuccess=true` / `errorMsg=""` / `data=""`；`testReplaceRule`
//!    空 `pattern` 亦改为只返回「替换规则不能为空」错误、不写结果区
//!    （原版 `setErrorMsg` 后被 `setData` 覆盖）。
//! 7. `ReplaceRule` 新增行由 SQLite rowid 分配（`ReplaceRuleRepository::insert`
//!    单实现不写 id）；原版 Room REPLACE 使用请求携带的 id。编辑既有行
//!    （id 命中）走 `update`，语义与 REPLACE 等价。
//!
//! 批10 审查修复项（2026-10-26）：
//! - **P1-1** `ReplaceRule` JSON 输入同时接受原版 `order` 键与本轨既有
//!   `sortOrder` 键（模型 `#[serde(alias = "order")]`；输出仍为 `sortOrder`），
//!   [`parse_replace_rule`] 的「排序缺省」判定两键均识别；
//! - **P1-2** 源删除 / JS 源换 URL 保存清缓存由「仅 `sourceVariable_{url}`」
//!   改为原版 5 族（`v_{url}_%` / `userInfo_` / `loginHeader_` /
//!   `sourceVariable_` / `infoMap_`，`CacheDao.kt:35-42`）+ 内存 5 族清理
//!   （`AppCacheManager.clearSourceVariables`，`CacheManager.kt:35-46`）；
//! - **P1-3** `testReplaceRule` 的替换执行移交 `spawn_blocking`，规则超时
//!   clamp 到服务端上限 [`TEST_REPLACE_RULE_MAX_TIMEOUT_MS`]，避免请求携带
//!   超大 `timeoutMillisecond` 长期占用 tokio worker / 阻塞线程；
//! - **P2-1** 令牌面文档修正（见上：9 条集合 + saveJsSource 独立链）；
//! - **P2-2** [`source_write_token_guard`] 路由级令牌前置（未授权不读 body）；
//! - **P2-3** 令牌比较改常量时间（`crate::server::matches_js_source_api_token`）。
//!
//! 批10 审查登记（P2，暂不修，均为已知边界）：
//! - **P2-5** `@js:` 替换执行器已统一为 `legado-js` 共享实现（批17 回修：
//!   绑定 `result`/`chapter`/`book`，预览上下文下 chapter/book 为空对象），
//!   但仍未提供原版 Rhino 的 `java.*` 宿主对象；依赖 `java.*` 的替换脚本
//!   会报「未定义」而非原版可执行。属 JS 宿主面能力缺口，需先定绑定白名单；
//! - **P2-6** 单条写库失败（如 SQLITE 约束）本实现返回 HTTP 200 +
//!   `errorMsg`，原版未捕获异常 → HTTP 500（批量面已按防复发「批量原子性」
//!   统一为 200 + errorMsg；单条面沿用同一信封以便 vue 展示）；
//! - **P2-7（批23 已修复）** 空 `pattern` 原按原版 `setErrorMsg` 后继续
//!   执行并被 `setData` 覆盖；现改为直接返回错误、不执行替换（用户裁决）；
//! - **P2-8** 正则/字面量方言差异：Rust `regex` 不支持反向引用、后行断言、
//!   占有量词等 Java 特性；`$n` 组引用语义与 Java 基本一致但 `$0`/命名组
//!   写法不同。命中差异时原版正常替换、本实现返回错误文本（预览可见）；
//! - **P2-9** 请求体形态：原版 NanoHTTPD `parseBody` 支持
//!   `application/x-www-form-urlencoded` 与 multipart 并取 `postData` 字段；
//!   本实现直接 UTF-8 解码原始 body（vue 只发原始 JSON/text，浏览器可见
//!   语义一致；表单形态客户端不兼容）；
//! - **P2-10** Gson 宽松转换：原版接受数字/布尔字符串互转、单引号、注释等
//!   宽松 JSON；serde 严格解析，此类载荷会得到「格式不对/转换源失败」；
//! - **P2-11** `openedSourceUrl` 查询参数本实现 `trim()` 后空串视为缺省；
//!   原版直接使用（未 trim），仅带首尾空白的异常 URL 会有差异；
//! - **P2-12** `ReturnData.data` 为 `null` 时本实现显式序列化 `"data":null`
//!   （与原版 Gson 默认输出一致）；`saveBookSource`/`saveRssSource` 成功
//!   的 `data:""` 亦照抄，未做省略优化；
//! - **P2-13** 请求体超过 [`SOURCE_WRITE_MAX_BODY_BYTES`] 时 axum 返回
//!   HTTP 413（plain text，非 `ReturnData` 信封）；原版 NanoHTTPD 无显式
//!   上限。放宽上限与 413 形态均为防 OOM 的安全增强。

use std::collections::HashMap;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{Query, Request, State};
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode};
use axum::middleware::Next;
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
// [批17 回修 P1] 预览/正文共用 legado-js 单一 `@js:` 执行器（禁止第二份适配）
use legado_js::replace_rule_js::ReplaceRuleJsExecutor;

use super::source_api::{load_js_source_api_config, token_error_response, JsSourceApiConfig};
use super::{origin_of, to_response, ReturnData};
use crate::state::AppState;

/// JS 源脚本上限（对齐 `JsSourceUpsert.MAX_SOURCE_BYTES` = 1 MiB）
const JS_SOURCE_MAX_BYTES: i64 = 1024 * 1024;

/// `saveJsSource` 保存超时（对齐 `JS_SOURCE_SAVE_TIMEOUT_MILLIS = 30_000`）
const JS_SOURCE_SAVE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// 写端点请求体上限（原版 NanoHTTPD 无显式上限；axum 默认 2MB 会拒收
/// 大批量书源推送，故放宽到 16MB，覆盖该挂载组 12 条路由：本模块 10 条 +
/// 批30 检验会话 `/startBookSourceCheck`、`/stopBookSourceCheck`）
pub const SOURCE_WRITE_MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

/// 受保护源写路由表（P2-2，路由级令牌前置中间件使用）
///
/// 每条为 `(路径模式, 方法限定)`：
/// - 方法限定 `None`：该路径**全部方法**受保护——对齐原版
///   `PROTECTED_SOURCE_WRITE_ROUTES`（HttpServer.kt:246-258）的裸路径集合语义；
/// - 方法限定 `Some("POST")` 等：仅该方法受保护——用于自研 `/api/sources`
///   这类读写共用同一路径的 REST 端点（GET 读取面保持免令牌）；
/// - 路径模式末段 `{id}` 匹配**单个**路径段（对齐 axum `{id}` 路径参数；
///   注意查询串不参与匹配，路径参数为百分号编码时原样按段匹配）。
///
/// 与原版 `PROTECTED_SOURCE_WRITE_ROUTES`（HttpServer.kt:246-258）中本模块
/// 的 9 条 + 独立链保护的 `/saveJsSource`（HttpServer.kt:60-62）一致；
/// 批30 追加检验会话两条 `/startBookSourceCheck`、`/stopBookSourceCheck`
/// （同属原版集合，HttpServer.kt:251-254）。
///
/// [批17 三审 P2] 追加 `/mcp/call`：Web 端口该路由可执行任意 JS
/// （`eval_js`，timeout 5..600s），与源写端点同为高成本副作用面，纳入同一
/// 令牌前置守卫；独立 MCP 端口（`serve_mcp`）已有自己的 token 中间件。
///
/// [审查批 P0-1] 追加自研 `/api/webbook/{search,info,chapters,content}`
/// 四条：这些端点接受请求体中的完整 `BookSource`，对 `mainJs` 书源真实执行
/// QuickJS（`java.*` 宿主 API 可发起任意网络请求）。原版无对应端点（原版
/// 正文/搜索链只使用 DB 内已保存书源），故不在原版 13 条集合内；但「请求体
/// 自带 source 并执行规则」的执行面与 `/mcp/call` 等价，必须纳入同一令牌
/// 前置守卫，否则 LAN 可达时同网段攻击者无需令牌即可执行任意 JS。
///
/// [审查批 P1-1] 追加自研 REST 源写面四条（方法限定；GET 读取面保持
/// 免令牌）：`POST /api/sources`（创建/写库）、`PUT|DELETE /api/sources/{id}`
/// （改/删）、`POST /api/sources/update`（按任意 `repo_url` 整批导入源）。
/// 这些端点在原版无等价面（原版写面为 `/saveBookSource(s)`、
/// `/deleteBookSources`），此前完全绕过令牌面；其中 `POST /api/sources`
/// 旧实现 `INSERT OR REPLACE` 还会用默认实体清空已存在 URL 的全部规则。
pub const PROTECTED_SOURCE_WRITE_ROUTES: [(&str, Option<&str>); 21] = [
    ("/startBookSourceCheck", None),
    ("/stopBookSourceCheck", None),
    ("/saveBookSource", None),
    ("/saveBookSources", None),
    ("/deleteBookSources", None),
    ("/saveJsSource", None),
    ("/saveRssSource", None),
    ("/saveRssSources", None),
    ("/deleteRssSources", None),
    ("/saveReplaceRule", None),
    ("/deleteReplaceRule", None),
    ("/testReplaceRule", None),
    ("/mcp/call", None),
    ("/api/webbook/search", None),
    ("/api/webbook/info", None),
    ("/api/webbook/chapters", None),
    ("/api/webbook/content", None),
    ("/api/sources", Some("POST")),
    ("/api/sources/{id}", Some("PUT")),
    ("/api/sources/{id}", Some("DELETE")),
    ("/api/sources/update", Some("POST")),
];

/// 请求（方法 + 路径）是否命中受保护源写面
///
/// 方法比较大小写不敏感（`Method::as_str()` 为大写）；
/// 路径模式含 `{id}` 时只匹配单段，避免把 `/api/sources/repos` 等读取
/// 子路由误判为 `PUT/DELETE /api/sources/{id}`（其方法本身也不匹配，
/// 双保险）。
pub fn is_protected_source_write_request(method: &Method, path: &str) -> bool {
    PROTECTED_SOURCE_WRITE_ROUTES
        .iter()
        .any(|(pattern, allowed_method)| {
            allowed_method.is_none_or(|allowed| allowed.eq_ignore_ascii_case(method.as_str()))
                && route_pattern_matches(pattern, path)
        })
}

/// 路径模式匹配：末段 `{id}` 匹配单个非空路径段，其余精确匹配
fn route_pattern_matches(pattern: &str, path: &str) -> bool {
    match pattern.strip_suffix("/{id}") {
        Some(prefix) => path
            .strip_prefix(prefix)
            .and_then(|rest| rest.strip_prefix('/'))
            .is_some_and(|id| !id.is_empty() && !id.contains('/')),
        None => pattern == path,
    }
}

/// 路由级令牌前置中间件（P2-2，批10 审查）
///
/// 在 handler 提取 `Bytes` / `Query` **之前**校验令牌：未授权请求直接返回
/// 原版失败信封 + `Connection: close`，不读取请求体（超大
/// `Content-Length` 不会拖住连接、不会触发 axum 默认 2MB body 限制的 413）。
/// handler 内的 [`token_rejection`] 保留为纵深防御。
///
/// 只对 [`PROTECTED_SOURCE_WRITE_ROUTES`]（21 条，含自研 `/api/webbook/*`
/// 四条与 `/api/sources` 方法限定的四条）生效；其余路径原样放行。
/// 挂载点：`crate::server::attach_source_write_token_guard`（生产入口在
/// `serve_web_with_injected_paths` 组装路由后统一套用）。
pub async fn source_write_token_guard(
    State(state): State<Arc<AppState>>,
    request: Request,
    next: Next,
) -> Response {
    let method = request.method().clone();
    // 路径在移动 request 前取自有副本（令牌失败响应需要 uri 字符串）
    let uri = request.uri().path().to_string();
    if !is_protected_source_write_request(&method, &uri) {
        return next.run(request).await;
    }
    let headers = request.headers().clone();
    let origin = origin_of(&headers);
    if let Some(resp) = token_rejection(&state, &headers, &uri, origin.as_deref()).await {
        return resp;
    }
    next.run(request).await
}

/// `testReplaceRule` 规则超时服务端上限（毫秒）
///
/// 原版 `ReplaceRule.getValidTimeoutMillisecond()` 只把 `<=0` 归一到 3000，
/// **无上限**；Web 端点接受请求携带的任意值，恶意/误配的超大
/// `timeoutMillisecond` 会让一次替换独占阻塞线程数小时。P1-3 起服务端
/// clamp 到 5s（登记为安全增强，不改变正常规则的可见结果）。
pub const TEST_REPLACE_RULE_MAX_TIMEOUT_MS: i64 = 5_000;

/// 测试替换规则端点「替换规则不能为空」错误文案
///
/// 原版 `ReplaceRuleController.testRule` 先 `setErrorMsg` 但不返回，随后
/// `setData` 把错误覆盖成成功；批23 按用户裁决改为**错误时只返回错误**，
/// 结果区不写入（见 [`test_replace_rule`]）。
const EMPTY_REPLACE_PATTERN_MESSAGE: &str = "替换规则不能为空";

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
    warn_if_token_enforcement_disabled(&config);
    if config.has_valid_token(headers) {
        None
    } else {
        Some(token_error_response(uri, origin))
    }
}

/// 令牌校验被显式关闭时的一次性告警（`config:jsSourceApiTokenRequired=false`）
///
/// 语义（对齐原版 `AppConfig.jsSourceApiTokenRequired`）：显式关闭后
/// [`PROTECTED_SOURCE_WRITE_ROUTES`] 全部免令牌放行——包括自研
/// `/api/webbook/*` 的任意 JS 执行面。这是用户显式 opt-out，行为保持与既有
/// 源写端点/`/mcp/call` 一致；但必须留下安全可见性告警。用 [`Once`] 避免
/// 每个请求刷日志（首次命中的请求即足以提示运维）。
static TOKEN_DISABLED_WARNED: std::sync::Once = std::sync::Once::new();

fn warn_if_token_enforcement_disabled(config: &JsSourceApiConfig) {
    if config.required {
        return;
    }
    TOKEN_DISABLED_WARNED.call_once(|| {
        tracing::warn!(
            "源写/执行类端点令牌校验已显式关闭（config:jsSourceApiTokenRequired=false）：\
             PROTECTED_SOURCE_WRITE_ROUTES 无令牌放行，其中 /api/webbook/* 与 /mcp/call \
             可在设备进程内执行任意 JS；请仅在可信网络使用"
        );
    });
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
                    match BookSourceRepository::new(db.connection())
                        .insert_with_check_state(&source)
                    {
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
                match BookSourceRepository::new(db.connection())
                    .insert_batch_with_check_state(&ok_sources)
                {
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
                        // P1-2：对齐 CacheDao.deleteSourceVariables 的 5 族
                        cache.delete_source_variables(url)?;
                    }
                    Ok(())
                }) {
                    Ok(()) => {
                        // 对齐 SourceHelp.deleteBookSourceKeys：非空删除且事务成功后
                        // 整体清内存 5 族（AppCacheManager.clearSourceVariables；
                        // 原版空 keys 早退，不做内存清理）
                        if !urls.is_empty() {
                            let _ = legado_js::host_api::variable_store::clear_source_variables();
                        }
                        ReturnData::success(Value::String("已执行".to_string()))
                    }
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
    let removed_old_source = old_url_to_delete.is_some();
    let source_to_save = source;
    let saved = in_transaction(conn, "保存 JS 源", |conn| {
        let repo = BookSourceRepository::new(conn);
        if let Some(old_url) = old_url_to_delete.as_ref() {
            // SourceHelp.deleteBookSource：删行 + 清 5 族缓存（P1-2）
            repo.delete(old_url)?;
            CacheRepository::new(conn).delete_source_variables(old_url)?;
        }
        repo.insert_with_check_state(&source_to_save)?;
        Ok(source_to_save)
    });
    match saved {
        Ok(source) => {
            if removed_old_source {
                // 对齐 SourceHelp.deleteBookSource：删源后整体清内存 5 族
                let _ = legado_js::host_api::variable_store::clear_source_variables();
            }
            match serde_json::to_value(&source) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            }
        }
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
                        // P1-2：对齐 CacheDao.deleteSourceVariables 的 5 族
                        cache.delete_source_variables(&source.source_url)?;
                    }
                    Ok(())
                }) {
                    Ok(()) => {
                        // 对齐 SourceHelp.deleteRssSources：事务成功后整体清
                        // 内存 5 族（AppCacheManager.clearSourceVariables）
                        let _ = legado_js::host_api::variable_store::clear_source_variables();
                        ReturnData::success(Value::String("已执行".to_string()))
                    }
                    Err(e) => ReturnData::error(e.to_string()),
                }
            }
        },
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── POST /saveReplaceRule · /deleteReplaceRule · /testReplaceRule ──────────

/// 解析替换规则 JSON（返回解析后的规则与排序值是否缺省）
///
/// P1-1：排序键兼容原版 `order`（Gson 契约）与本轨既有 `sortOrder`；
/// 两键皆缺或值等于 `Int.MIN_VALUE` 时视为缺省（端点层补 `MAX+1`）。
fn parse_replace_rule(text: &str) -> Option<(ReplaceRule, bool)> {
    let value: Value = serde_json::from_str(text).ok()?;
    let order_missing = value
        .get("sortOrder")
        .or_else(|| value.get("order"))
        .is_none_or(|v| v.as_i64() == Some(i64::from(i32::MIN)));
    let rule: ReplaceRule = serde_json::from_value(value).ok()?;
    Some((rule, order_missing))
}

/// POST `/saveReplaceRule`（ReplaceRuleController.saveRule，:23-45）
///
/// 语义：缺参 →「数据不能为空」；坏 JSON →「格式不对」；排序键（原版
/// `order` / 本轨 `sortOrder`，P1-1）缺省（Gson 实体默认 `Int.MIN_VALUE`）
/// 或显式 `Int.MIN_VALUE` → `MAX(sortOrder)+1`（**仅插入新行时生效**）；
/// id 命中既有行只更新内容字段——批12 P2 起 `update` 不写 `sortOrder`，
/// 排序只经 `reorderReplaceRules` 全量重排，避免旧快照覆盖新排序。
///
/// **返回值形态**：原版成功路径未调用 `setData`，信封保持构造默认
/// （`isSuccess=false` +「未知错误,请联系开发者!」），Web 页因此把成功
/// 显示为未知错误。批23 按用户裁决改为**显式成功信封**
/// （`isSuccess=true` / `errorMsg=""` / `data=""`，与
/// `saveBookSource` 等写端点成功形态一致）。
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
                        let exists = rule.id != 0 && rules.iter().any(|r| r.id == rule.id);
                        // 批12 P2：排序只在插入新行时补 MAX+1；既有行 update
                        // 不写 sortOrder（排序由 reorderReplaceRules 独占）
                        if !exists && (order_missing || rule.order == i32::MIN) {
                            let max_order = rules.iter().map(|r| r.order).max().unwrap_or(0);
                            rule.order = max_order.wrapping_add(1);
                        }
                        let written = if exists {
                            repo.update(&rule)
                        } else {
                            repo.insert(&rule).map(|_| ())
                        };
                        match written {
                            // 批23：显式成功信封（原版未 setData 导致前端误报）
                            Ok(()) => ReturnData::success(Value::String(String::new())),
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
/// （不存在亦成功）。成功路径按批23 用户裁决返回显式成功信封
/// （原版未 `setData`，见 [`save_replace_rule`] 说明）。
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
                    Ok(()) => ReturnData::success(Value::String(String::new())),
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
///   随后 `setData` 覆盖为成功，错误提示被结果区冲掉；批23 按用户裁决
///   改为**直接返回错误**（`isSuccess=false`，`data=null`），不执行替换、
///   不写结果区；
///   例外说明（批23b 审查 P3）：空 `pattern` 检查**先于** `text` 类型校验，
///   因此 `text` 缺失/非字符串与空 `pattern` 同时出现时，返回「替换规则
///   不能为空」错误信封，而不是 `text` 校验对应的 HTTP 500（空规则优先
///   报告；边界用例见 `legacy_web_test::test_b6_test_replace_rule_semantics`）；
/// - 正则/字面量替换复用
///   [`legado_core::content_processor::preview_single_rule`]（单实现：
///   Java 方言适配 + 超时保护 + `@js:` 执行）；规则级错误按原版
///   `catch → e.stackTraceStr → setData` 作为成功数据返回；
/// - P1-3：替换在 blocking 线程池执行，规则超时 clamp 到
///   [`TEST_REPLACE_RULE_MAX_TIMEOUT_MS`]（服务端 5s 上限）；
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
    // 批23：空 pattern 只返回错误，不执行替换、不写结果区（原版被
    // setData 覆盖，前端错误提示不可见）
    if rule.pattern.is_empty() {
        return to_response(
            &ReturnData::error(EMPTY_REPLACE_PATTERN_MESSAGE),
            uri,
            origin.as_deref(),
        );
    }
    // 原版 `map["text"] as String`：缺失/非字符串 → ClassCastException /
    // NullPointerException → HttpServer 外层 catch → 500
    let Some(Value::String(text)) = map.get("text") else {
        return internal_error_response(
            "替换测试文本缺失或类型不符（text 必须为字符串）",
            origin.as_deref(),
        );
    };
    let text = text.clone();
    // P1-3：替换执行是 CPU 密集阻塞操作（病态正则 / @js: 脚本），经
    // [`spawn_test_replace_rule`] 移交 blocking 线程池，避免独占 tokio worker
    let output = match spawn_test_replace_rule(text, rule).await {
        Ok(output) => output,
        Err(message) => return internal_error_response(&message, origin.as_deref()),
    };
    to_response(
        &ReturnData::success(Value::String(output)),
        uri,
        origin.as_deref(),
    )
}

/// 在 blocking 线程池执行单条替换（P1-3 单实现：handler 与并发测试共用）
///
/// 超时先经 [`clamp_test_replace_rule_timeout`] 收敛到服务端上限；`Err`
/// 仅在 blocking 任务 panic/cancel 时返回（对齐原版未捕获异常 → 500）。
async fn spawn_test_replace_rule(text: String, mut rule: ReplaceRule) -> Result<String, String> {
    clamp_test_replace_rule_timeout(&mut rule);
    run_replace_in_blocking(move || apply_test_replace_rule(&text, &rule)).await
}

/// 把替换闭包移交 `spawn_blocking`（P1-3）
///
/// 独立成泛型便于测试直接验证「任务确在 worker 线程之外执行」与
/// 「并发数可超过 tokio worker 数」；生产路径经
/// [`spawn_test_replace_rule`] 复用同一入口。
async fn run_replace_in_blocking<T, F>(f: F) -> Result<T, String>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|join_error| format!("替换测试执行失败: {join_error}"))
}

/// 规则超时 clamp 到服务端上限（P1-3）
///
/// 先保留原版 `getValidTimeoutMillisecond` 的 `<=0 → 3000` 归一，再以
/// [`TEST_REPLACE_RULE_MAX_TIMEOUT_MS`] 封顶。
fn clamp_test_replace_rule_timeout(rule: &mut ReplaceRule) {
    let valid = if rule.timeout_millisecond <= 0 {
        3000
    } else {
        rule.timeout_millisecond
    };
    rule.timeout_millisecond = valid.min(TEST_REPLACE_RULE_MAX_TIMEOUT_MS);
}

/// 对给定文本应用单条替换规则（空 pattern 已在 handler 前置拦截，
/// 不会进入本函数）
fn apply_test_replace_rule(text: &str, rule: &ReplaceRule) -> String {
    let entry = ReplaceRuleEntry::from_replace_rule(rule);
    match preview_single_rule(text, &entry, &test_rule_js_executor()) {
        Ok(output) => output,
        // 原版 catch 分支把 `e.stackTraceStr` 作为 data 返回（success）
        Err(error) => error,
    }
}

/// `@js:` 替换执行器（与 App 预览/正文共用 `legado-js` 单一实现）
///
/// [批17 回修 P1] 行为由 `legado-js` 的 `quickjs` feature 决定（不再按
/// `legado-server` 自身 feature 分支）：
/// - 启用：真实执行，绑定 `result`（预览无章节/书籍上下文，`chapter`/`book`
///   为空对象，字段为空串/0）；
/// - 未启用：`eval` 返回可读 `Err`，预览按规则级错误展示 `⚠️` 文本，不 panic。
///
/// 原 `QuickJsReplaceExecutor`（只绑 `result`、3s 独立沙箱、每次新建引擎）
/// 已删除——App 内嵌 Web 与独立 server 必须与正文净化共用同一执行器。
fn test_rule_js_executor() -> Option<Arc<dyn legado_core::content_processor::ReplaceJsExecutor>> {
    Some(Arc::new(ReplaceRuleJsExecutor::without_context()))
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

    // ── P1-1：原版 `order` 键 ────────────────────────────────────────────

    /// P1-1：按原版契约发 `{"id":9,"order":5}` 必须保留排序 5，
    /// 不得被识别为「排序缺省」而改写为 MAX+1。
    #[test]
    fn test_parse_replace_rule_accepts_upstream_order_key() {
        let (rule, order_missing) = parse_replace_rule(r#"{"id":9,"order":5}"#).unwrap();
        assert_eq!(rule.id, 9);
        assert_eq!(rule.order, 5, "order 键输入必须保留排序（P1-1）");
        assert!(!order_missing, "显式 order 不视为缺省");

        // 本轨既有键继续有效
        let (rule, order_missing) = parse_replace_rule(r#"{"id":9,"sortOrder":6}"#).unwrap();
        assert_eq!(rule.order, 6);
        assert!(!order_missing);

        // 两键皆缺 → 缺省（端点层补 MAX+1）
        let (rule, order_missing) = parse_replace_rule(r#"{"id":9}"#).unwrap();
        assert_eq!(rule.order, 0);
        assert!(order_missing);

        // 原版实体默认 Int.MIN_VALUE → 缺省
        let (_, order_missing) = parse_replace_rule(r#"{"id":9,"order":-2147483648}"#).unwrap();
        assert!(order_missing, "Int.MIN_VALUE 视为缺省");

        // 坏 JSON
        assert!(parse_replace_rule("not-json").is_none());
        // 两键同时出现：别名冲突按「格式不对」拒绝，不静默取其一
        assert!(parse_replace_rule(r#"{"order":1,"sortOrder":2}"#).is_none());
    }

    // ── P1-3：blocking 线程池 + 超时 clamp ───────────────────────────────

    /// P1-3：`<=0` 沿用原版 3000ms 归一；超大值封顶到服务端常数
    #[test]
    fn test_clamp_test_replace_rule_timeout() {
        let mut huge = ReplaceRule {
            timeout_millisecond: 600_000,
            ..ReplaceRule::default()
        };
        clamp_test_replace_rule_timeout(&mut huge);
        assert_eq!(huge.timeout_millisecond, TEST_REPLACE_RULE_MAX_TIMEOUT_MS);

        let mut non_positive = ReplaceRule {
            timeout_millisecond: -1,
            ..ReplaceRule::default()
        };
        clamp_test_replace_rule_timeout(&mut non_positive);
        assert_eq!(non_positive.timeout_millisecond, 3000);

        let mut normal = ReplaceRule {
            timeout_millisecond: 500,
            ..ReplaceRule::default()
        };
        clamp_test_replace_rule_timeout(&mut normal);
        assert_eq!(normal.timeout_millisecond, 500, "正常值不改写");
    }

    /// P1-3：替换闭包必须离开 tokio worker 线程执行
    #[tokio::test(flavor = "current_thread")]
    async fn test_replace_runs_off_worker_thread() {
        let worker_thread = std::thread::current().id();
        let blocking_thread = run_replace_in_blocking(std::thread::current).await.unwrap();
        assert_ne!(
            blocking_thread.id(),
            worker_thread,
            "替换必须移交 blocking 线程池，不得占用 tokio worker"
        );
    }

    /// P1-3：并发数超过 worker 数（current_thread = 1 worker）时，
    /// 8 个 120ms 的阻塞任务仍应并发完成（串行 ≥960ms，断言 <800ms）
    #[tokio::test(flavor = "current_thread")]
    async fn test_blocking_replace_concurrency_exceeds_worker_count() {
        use std::time::{Duration, Instant};
        let started = Instant::now();
        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(tokio::spawn(run_replace_in_blocking(|| {
                std::thread::sleep(Duration::from_millis(120));
            })));
        }
        for handle in handles {
            handle.await.unwrap().unwrap();
        }
        let elapsed = started.elapsed();
        assert!(
            elapsed < Duration::from_millis(800),
            "blocking 池应并发执行，实际 {elapsed:?}"
        );
    }

    /// P2-2 / P0-1 / P1-1：受保护路由表（21 条：批30 检验会话两条 +
    /// 批17 三审 `/mcp/call` + P0-1 自研 `/api/webbook/*` 四条 + P1-1 自研
    /// REST 源写面四条）与方法限定匹配语义
    #[test]
    fn test_protected_source_write_routes() {
        assert_eq!(PROTECTED_SOURCE_WRITE_ROUTES.len(), 21);
        for path in [
            "/startBookSourceCheck",
            "/stopBookSourceCheck",
            "/saveBookSource",
            "/saveBookSources",
            "/deleteBookSources",
            "/saveJsSource",
            "/saveRssSource",
            "/saveRssSources",
            "/deleteRssSources",
            "/saveReplaceRule",
            "/deleteReplaceRule",
            "/testReplaceRule",
            "/mcp/call",
            "/api/webbook/search",
            "/api/webbook/info",
            "/api/webbook/chapters",
            "/api/webbook/content",
        ] {
            // 裸路径条目不限方法：任取 POST 均应命中
            assert!(
                is_protected_source_write_request(&Method::POST, path),
                "{path}"
            );
        }
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/getBookshelf"
        ));
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/saveBook"
        ));
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/openLegacyReview"
        ));
        // 只保护可执行 JS 的 call；tools 列表无副作用，保持免令牌
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/mcp/tools"
        ));
        // 相邻但非执行面：/api/search 走 DB 内书源，/api/webbook 前缀的未知
        // 子路径不匹配既有路由（精确匹配，不做前缀放行）
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/api/search"
        ));
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/api/webbook/search/extra"
        ));

        // ── P1-1：自研 REST 源写面（方法限定） ───────────────────────────
        assert!(is_protected_source_write_request(
            &Method::POST,
            "/api/sources"
        ));
        assert!(is_protected_source_write_request(
            &Method::POST,
            "/api/sources/update"
        ));
        // PUT/DELETE 的 {id} 为单段（URL 通常百分号编码，段内不含 '/'）
        assert!(is_protected_source_write_request(
            &Method::PUT,
            "/api/sources/https%3A%2F%2Fexample.com"
        ));
        assert!(is_protected_source_write_request(
            &Method::DELETE,
            "/api/sources/https%3A%2F%2Fexample.com"
        ));
        // 读取面保持免令牌：GET /api/sources、/sources/{id} 与只读子路由
        assert!(!is_protected_source_write_request(
            &Method::GET,
            "/api/sources"
        ));
        assert!(!is_protected_source_write_request(
            &Method::GET,
            "/api/sources/repos"
        ));
        assert!(!is_protected_source_write_request(
            &Method::GET,
            "/api/sources/updates"
        ));
        // 非写方法不命中 {id} 条目
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/api/sources/https%3A%2F%2Fexample.com"
        ));
        // 多段路径不匹配单段 {id}
        assert!(!is_protected_source_write_request(
            &Method::PUT,
            "/api/sources/a/b"
        ));
        // 其它只读/检查端点不因前缀相同被误纳入
        assert!(!is_protected_source_write_request(
            &Method::POST,
            "/api/sources/check"
        ));
        assert!(!is_protected_source_write_request(
            &Method::GET,
            "/api/sources/https%3A%2F%2Fexample.com"
        ));
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
