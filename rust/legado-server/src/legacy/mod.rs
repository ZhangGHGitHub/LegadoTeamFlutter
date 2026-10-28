//! 原版 Web API（原版路径 + `ReturnData` 信封）
//!
//! 本模块提供 `HttpServer.kt` 路由表中 **书架/阅读主链路** 的原版端点，
//! 与我方自研 `/api/*` 并存互不影响。响应统一为
//! `ReturnData{isSuccess, errorMsg, data}`（`app/src/main/java/io/legado/app/api/ReturnData.kt`），
//! HTTP 状态恒 200（与原版一致；原版仅在未捕获异常时返回 500）。
//!
//! 本批（B2）实现范围与依据：
//!
//! | 端点 | 原版实现 | 备注 |
//! |---|---|---|
//! | GET `/getBookshelf` | `BookController.bookshelf`（:65-83） | 空书架 errorMsg「还没有添加小说」；排序默认分支 durChapterTime 降序 |
//! | GET `/getChapterList?url=` | `BookController.getChapterList`（:182-193） | 空目录回退 refreshToc（含本地书解析 / 网络抓取） |
//! | GET `/getBookContent?url=&index=` | `BookController.getBookContent`（:198-246） | 缓存优先 → 本地文件 → 网络抓取，均经净化（includeTitle=false；替换规则按 `Book.getUseReplaceRule()` 门控） |
//! | POST `/saveBookProgress` | `BookController.saveBookProgress`（:276-301） | 原版为 **POST**（HttpServer.kt:90；前端 `W.post` + `sendBeacon`），非 GET |
//! | GET `/getReadConfig` | `BookController.getWebReadConfig`（:346-351） | 无配置 errorMsg「没有配置」 |
//! | POST `/saveReadConfig` | `BookController.saveWebReadConfig`（:335-341） | 原样字符串入 `caches` 表（CacheManager「webReadConfig」键） |
//! | GET `/cover?path=` | `BookController.getCover`（:88-113） | 图片代理（网络 URL 直取；本地路径经白名单：目录 + 扩展名 + 魔数） |
//! | GET `/image?path=&url=&width=` | `BookController.getImg`（:118-140） | 正文图片代理（本地路径同 `/cover` 白名单） |
//!
//! B3 批（2026-10-26）新增写端点：
//!
//! | 端点 | 原版实现 | 备注 |
//! |---|---|---|
//! | POST `/saveBook` | `BookController.saveBook`（:251-259） | Book JSON upsert（`Book.save()` Book.kt:467-473）；**无令牌**（HttpServer.kt:246-258 保护清单不含） |
//! | POST `/deleteBook` | `BookController.deleteBook`（:264-271） | 按主键删行（章节外键级联）；**无令牌** |
//! | POST `/addLocalBook` | `BookController.addLocalBook`（:306-330） | multipart（fileName+fileData）→ 落盘 → importFile 链；**无令牌**；安全封堵登记见 book_api.rs |
//!
//! B4 批（2026-10-26，ACTIVE_PLAN L804「管理读+令牌 7 + 段评 legacy 6」）：
//!
//! | 端点 | 原版实现 | 备注 |
//! |---|---|---|
//! | GET `/getBookSource?url=` | `BookSourceController.getSource`（:196-205） | url 缺失/未命中错误文案对齐；**无令牌** |
//! | GET `/getBookSources` | `BookSourceController.sources`（:28-35） | 全量书源；空 → 「设备源列表为空」；**无令牌** |
//! | GET `/getRssSource?url=` | `RssSourceController.getSource`（:57-66） | **无令牌** |
//! | GET `/getRssSources` | `RssSourceController.sources`（:15-22） | 空 → 「源列表为空」；**无令牌** |
//! | GET `/getReplaceRules` | `ReplaceRuleController.allRules`（:14-20） | data 为规则数组的 **JSON 字符串**（`setData(GSON.toJson)` 双层编码）；**无令牌** |
//! | GET `/getJsSourceApiTokenRequired` | `BookSourceController.isJsSourceApiTokenRequired`（:189-194） | data 裸布尔；恒放行；`Cache-Control: no-store` |
//! | GET `/getHttpLogs?limit=` `/getHttpLog?id=` | `HttpLogController.getLogs/getLog`（:13-39） | **令牌保护**（`PROTECTED_HTTP_LOG_READ_ROUTES`，HttpServer.kt:259-262）；limit clamp(1,50)；no-store |
//! | GET `/getReviewSummary` `/getReviewDetail` `/getReviewReplies` | `ReviewController.getSummary/getDetail/getReplies`（:181-398） | 规则书源 AnalyzeUrl+parser、JS 书源编排器；detail 分页游标 64 槽；JS 书源 replies 走 getReviewReplies 编排器（2026-10-26 批12 补齐；函数缺失按原版 callOptionalFunction 空页） |
//! | POST `/openLegacyReview` `/runLegacyReview` | `ReviewController.openLegacyReview/runLegacyReview`（:400-456） | **令牌保护**（PROTECTED_SOURCE_WRITE_ROUTES）；会话 16 槽 / 2h TTL |
//! | GET `/legacyReviewPage?id=&nonce=` | `HttpServer.legacyReviewPageResponse`（:280-310） | HTML+桥接注入+CSP；未命中 404「旧评论会话无效或已过期」 |
//!
//! 令牌实现（`source_api.rs`）：`x-legado-token` vs caches `config:jsSourceApiToken`
//! 字节级相等（复用 server.rs MCP 同一比较实现）；`config:jsSourceApiTokenRequired`
//! 缺省 true；失败文案「Web 书源访问令牌未配置或不正确」+ `Connection: close`。
//!
//! B6 批（2026-10-26，ACTIVE_PLAN「Web 写端点 9 条」登记项；实为 10 条路径，
//! 与 `PROTECTED_SOURCE_WRITE_ROUTES` 逐条核对）：
//!
//! | 端点 | 原版实现 | 备注 |
//! |---|---|---|
//! | POST `/saveBookSource` | `BookSourceController.saveSource`（:37-52） | **令牌保护**；REPLACE upsert；成功 data="" |
//! | POST `/saveBookSources` | `BookSourceController.saveSources`（:54-70） | **令牌保护**；单事务批量（原版逐条，登记）；返回成功数组 |
//! | POST `/deleteBookSources` | `BookSourceController.deleteSources`（:207-216） | **令牌保护**；数组去重删行 + sourceVariable 缓存 |
//! | POST `/saveJsSource` | `BookSourceController.saveJsSource`（:72-96） | **令牌保护 + 独立校验链**（:98-129）；text/plain；保留用户态/冲突校验 |
//! | POST `/saveRssSource` | `RssSourceController.saveSource`（:24-38） | **令牌保护** |
//! | POST `/saveRssSources` | `RssSourceController.saveSources`（:40-55） | **令牌保护**；单事务批量 |
//! | POST `/deleteRssSources` | `RssSourceController.deleteSources`（:68-76） | **令牌保护**；删源 + 文章 + 缓存变量 |
//! | POST `/saveReplaceRule` | `ReplaceRuleController.saveRule`（:23-45） | **令牌保护**；sortOrder 缺省 → max+1；成功返回显式成功信封（批23 用户裁决，原版未 setData） |
//! | POST `/deleteReplaceRule` | `ReplaceRuleController.delete`（:48-59） | **令牌保护**；成功同上 |
//! | POST `/testReplaceRule` | `ReplaceRuleController.testRule`（:68-107） | **令牌保护**；不落库；复用 content_processor 单实现；空 pattern 只返回错误（批23） |
//!
//! B10 批（2026-10-26，ACTIVE_PLAN「/refreshToc 独立入口 + HTTP 采集接线」）：
//!
//! | 端点 | 原版实现 | 备注 |
//! |---|---|---|
//! | GET `/refreshToc?url=` | `BookController.refreshToc`（:145-177） | 复用 `refresh_toc` 单实现（本地书解析 / 网络书详情补全 + 目录抓取 + 删旧插新）；返回刷新后的章节列表；**无令牌**（不在两个 PROTECTED 集合内） |
//!
//! HTTP 采集：`legado-net` 统一请求出口新增可插拔采集点（trait + 运行期开关），
//! 本 crate 的 `legacy::http_log::StoreHttpLogRecorder` 注册为进程级实现，
//! `/getHttpLogs`、`/getHttpLog` 读取面零改动。
//!
//! B5 批（2026-10-26，ACTIVE_PLAN「WS 原版路径别名」登记项）：
//! 原版 WebSocket 调试通道已在**主服务 port+1** 的独立监听上落地
//! （[`crate::ws::original`]），路径 `/bookSourceDebug`、`/rssSourceDebug`，
//! 子协议令牌鉴权与关闭码逐条对齐 `WebSocketServer.kt`；主服务同端口的
//! 自研 `/ws/*` 通道保持不动。未纳入：原版 `/searchBook`（我方既有
//! `/ws/search` 保留，路径/端口差异登记）；RSS 规则解析引擎与发现页引擎
//! 在 Rust 侧无可达实现，按可达层级显式降级（见 `ws/original.rs` 文档）。
//!
//! 图片缓存根注入白名单（ACTIVE_PLAN「FFI 图片缓存根注入白名单」登记项）：
//! `/cover`、`/image` 本地白名单纳入宿主注入的 FFI 图片缓存根
//! （[`crate::state::InjectedPaths`]，构造期注入），FFI 侧已于
//! `ae444743eb` 改调 [`crate::server::serve_web_with_injected_paths`] 完成接线。
//!
//! 大列表响应：原版对 List 元素 > 3000 的响应走 chunked 流式 JSON
//! （HttpServer.kt:183-194）；axum 的 body 天然流式，本实现直接整包序列化，
//! 行为等价（登记）。
//!
//! B11 批（2026-10-28，批30「书源检验状态 + 原版 web-dist 同步」）：
//!
//! | 端点 | 原版实现 | 令牌 | 备注 |
//! |---|---|---|---|
//! | GET `/getBookSourcesForManagement?urls=` | `BookSourceCheckController.sources`（:22-43） | 无 | `{sources, states}`；`urls` 为 JSON 数组字符串，坏 JSON →「书源地址参数无效」 |
//! | GET `/getBookSourceCheckStates` | `BookSourceCheckController.states`（:15-20） | 无 | `{states, sessionToken}`；无会话时 `sessionToken: null` |
//! | POST `/startBookSourceCheck` | `BookSourceCheckController.start`（:48-85） | **有** | `{sources, keyword}` → `{sessionToken, sourceRevisions}`；提交源须与库内 `checkContent()` 一致 |
//! | POST `/stopBookSourceCheck` | `BookSourceCheckController.stop`（:87-96） | **有** | `{sessionToken}`；不匹配 →「检验会话已结束或已更换」 |
//!
//! 实现见 [`source_check_api`]；状态表见 `legado-db` v115。发现页校验引擎
//! 不可达（同 B5 降级）等差异在模块文档逐条登记。

pub mod book_api;
pub mod book_json;
pub mod http_log;
pub mod review_api;
pub mod source_api;
pub mod source_check_api;
pub mod source_write_api;

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, HeaderMap, HeaderName, HeaderValue};
use axum::response::Response;
use axum::routing::{get, post};
use axum::Router;
use serde::Serialize;
use serde_json::Value;

use crate::state::AppState;
use crate::web_assets;

/// 原版 `ReturnData` 信封（字段顺序即 Gson 声明顺序）
#[derive(Debug, Serialize)]
pub struct ReturnData {
    #[serde(rename = "isSuccess")]
    pub is_success: bool,
    #[serde(rename = "errorMsg")]
    pub error_msg: String,
    pub data: Value,
}

impl ReturnData {
    /// `setData(data)`：isSuccess=true、errorMsg=""
    pub fn success(data: impl Into<Value>) -> Self {
        Self {
            is_success: true,
            error_msg: String::new(),
            data: data.into(),
        }
    }

    /// `setErrorMsg(msg)`：isSuccess=false、data=null
    pub fn error(msg: impl Into<String>) -> Self {
        Self {
            is_success: false,
            error_msg: msg.into(),
            data: Value::Null,
        }
    }
}

/// 请求 `Origin`（原版回显 `Access-Control-Allow-Origin`）
pub fn origin_of(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

/// ReturnData → HTTP 响应：200 + `application/json; charset=utf-8` + 原版 Web 头
///
/// 原版 `GSON` 开了 `setPrettyPrinting()`（美化输出）与 `disableHtmlEscaping()`；
/// 本实现输出紧凑 JSON（内容等价，浏览器端仅做 JSON 解析），登记差异。
pub fn to_response(rd: &ReturnData, uri_path: &str, origin: Option<&str>) -> Response {
    let body = serde_json::to_vec(rd).unwrap_or_else(|_| b"{}".to_vec());
    let mut resp = Response::builder()
        .status(200)
        .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
        .body(Body::from(body))
        .expect("ReturnData 响应构建失败");
    web_assets::with_api_headers(&mut resp, uri_path, origin);
    resp
}

/// 二进制响应（`/cover`、`/image` 成功路径）
pub fn bytes_response(
    bytes: Vec<u8>,
    mime: &str,
    uri_path: &str,
    origin: Option<&str>,
) -> Response {
    let mime =
        HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream"));
    let mut resp = Response::builder()
        .status(200)
        .header(header::CONTENT_TYPE, mime)
        .body(Body::from(bytes))
        .expect("二进制响应构建失败");
    web_assets::with_api_headers(&mut resp, uri_path, origin);
    resp
}

/// 原版 `addWebHeaders`（HttpServer.kt:265-278）在非静态路径上的应用：
/// nosniff + Origin 回显（`/legacyReviewPage` 专用；其 CSP/no-store 等
/// 特有头由 review_api 内设置）
pub fn web_headers_for_legacy_page(resp: &mut Response, origin: Option<&str>) {
    let headers = resp.headers_mut();
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    if let Some(origin) = origin {
        if let Ok(value) = HeaderValue::from_str(origin) {
            headers.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
        }
    }
}

/// 原版端点路由（顶层路径，非 `/api` 前缀）
pub fn legacy_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/getBookshelf", get(book_api::get_bookshelf))
        .route("/getChapterList", get(book_api::get_chapter_list))
        // B10：独立目录刷新入口（原版 GET /refreshToc，无令牌）
        .route("/refreshToc", get(book_api::refresh_toc_endpoint))
        .route("/getBookContent", get(book_api::get_book_content))
        // 原版 saveBookProgress 为 POST（HttpServer.kt:90）；GET 在原版会落到
        // 静态资产分支（webAssets 无此文件 → 500），故不提供 GET 别名。
        .route("/saveBookProgress", post(book_api::save_book_progress))
        .route("/getReadConfig", get(book_api::get_read_config))
        .route("/saveReadConfig", post(book_api::save_read_config))
        .route("/cover", get(book_api::get_cover))
        .route("/image", get(book_api::get_image))
        // B3 写端点（无令牌，对齐原版 PROTECTED_SOURCE_WRITE_ROUTES 不含三者）
        .route("/saveBook", post(book_api::save_book))
        .route("/deleteBook", post(book_api::delete_book))
        // B4 管理读+令牌（source_api.rs；getHttpLog(s) 受令牌保护）
        .route("/getBookSource", get(source_api::get_book_source))
        .route("/getBookSources", get(source_api::get_book_sources))
        .route("/getRssSource", get(source_api::get_rss_source))
        .route("/getRssSources", get(source_api::get_rss_sources))
        .route("/getReplaceRules", get(source_api::get_replace_rules))
        .route(
            "/getJsSourceApiTokenRequired",
            get(source_api::get_js_source_api_token_required),
        )
        .route("/getHttpLogs", get(source_api::get_http_logs))
        .route("/getHttpLog", get(source_api::get_http_log))
        // B11 书源管理读（source_check_api.rs；两条 GET 无令牌，对齐原版）
        .route(
            "/getBookSourcesForManagement",
            get(source_check_api::get_book_sources_for_management),
        )
        .route(
            "/getBookSourceCheckStates",
            get(source_check_api::get_book_source_check_states),
        )
        // B4 段评 legacy（review_api.rs；open/run 受令牌保护）
        .route("/getReviewSummary", get(review_api::get_review_summary))
        .route("/getReviewDetail", get(review_api::get_review_detail))
        .route("/getReviewReplies", get(review_api::get_review_replies))
        .route("/legacyReviewPage", get(review_api::legacy_review_page))
        .route("/openLegacyReview", post(review_api::open_legacy_review))
        .route("/runLegacyReview", post(review_api::run_legacy_review))
        // B6 源写端点（source_write_api.rs 10 条 + 批30 检验会话 2 条，
        // 共 12 条全部受令牌保护）。
        // 单独挂载以放宽请求体上限（axum 默认 2MB 会拒收大批量源推送）
        .merge(
            Router::new()
                .route("/saveBookSource", post(source_write_api::save_book_source))
                .route(
                    "/saveBookSources",
                    post(source_write_api::save_book_sources),
                )
                .route(
                    "/deleteBookSources",
                    post(source_write_api::delete_book_sources),
                )
                // B11 检验会话两条（同属原版 PROTECTED_SOURCE_WRITE_ROUTES；
                // start 请求体含全部选中源，沿用放宽后的 16MB 上限）
                .route(
                    "/startBookSourceCheck",
                    post(source_check_api::start_book_source_check),
                )
                .route(
                    "/stopBookSourceCheck",
                    post(source_check_api::stop_book_source_check),
                )
                .route("/saveJsSource", post(source_write_api::save_js_source))
                .route("/saveRssSource", post(source_write_api::save_rss_source))
                .route("/saveRssSources", post(source_write_api::save_rss_sources))
                .route(
                    "/deleteRssSources",
                    post(source_write_api::delete_rss_sources),
                )
                .route(
                    "/saveReplaceRule",
                    post(source_write_api::save_replace_rule),
                )
                .route(
                    "/deleteReplaceRule",
                    post(source_write_api::delete_replace_rule),
                )
                .route(
                    "/testReplaceRule",
                    post(source_write_api::test_replace_rule),
                )
                .layer(axum::extract::DefaultBodyLimit::max(
                    source_write_api::SOURCE_WRITE_MAX_BODY_BYTES,
                )),
        )
        // addLocalBook 单独挂载以放宽 body 上限（axum 默认 2MB 会拒传书；
        // 上限 = 500MB 文件上限 + 1MB multipart 开销余量）
        .merge(
            Router::new()
                .route("/addLocalBook", post(book_api::add_local_book))
                .layer(axum::extract::DefaultBodyLimit::max(
                    book_api::UPLOAD_MAX_BYTES as usize + 1024 * 1024,
                )),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_return_data_success_shape() {
        let rd = ReturnData::success(Value::String("x".to_string()));
        let value = serde_json::to_value(&rd).unwrap();
        // serde_json 默认 Map 为 BTreeMap（键序字典序，非 Gson 声明序）；
        // 键集与取值与原版一致，浏览器端只做 JSON 解析，键序无语义
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        assert_eq!(keys, vec!["data", "errorMsg", "isSuccess"]);
        assert_eq!(value["isSuccess"], Value::Bool(true));
        assert_eq!(value["errorMsg"], Value::String(String::new()));
        assert_eq!(value["data"], Value::String("x".to_string()));
    }

    #[test]
    fn test_return_data_error_shape() {
        let rd = ReturnData::error("还没有添加小说");
        let value = serde_json::to_value(&rd).unwrap();
        assert_eq!(value["isSuccess"], Value::Bool(false));
        assert_eq!(
            value["errorMsg"],
            Value::String("还没有添加小说".to_string())
        );
        assert!(value["data"].is_null());
    }
}
