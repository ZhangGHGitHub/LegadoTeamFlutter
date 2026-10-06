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
//! | GET `/getBookContent?url=&index=` | `BookController.getBookContent`（:198-246） | 缓存优先 → 本地文件 → 网络抓取，均经净化（includeTitle=false） |
//! | POST `/saveBookProgress` | `BookController.saveBookProgress`（:276-301） | 原版为 **POST**（HttpServer.kt:90；前端 `W.post` + `sendBeacon`），非 GET |
//! | GET `/getReadConfig` | `BookController.getWebReadConfig`（:346-351） | 无配置 errorMsg「没有配置」 |
//! | POST `/saveReadConfig` | `BookController.saveWebReadConfig`（:335-341） | 原样字符串入 `caches` 表（CacheManager「webReadConfig」键） |
//! | GET `/cover?path=` | `BookController.getCover`（:88-113） | 图片代理（网络 URL/本地文件直读） |
//! | GET `/image?path=&url=&width=` | `BookController.getImg`（:118-140） | 正文图片代理 |
//!
//! 未纳入本批（下一批 B3/B4）：`/saveBook`、`/deleteBook`、`/addLocalBook`
//! （写端点）、书源/订阅源/替换规则/HTTP 日志系列、`/refreshToc` 独立入口、
//! WebSocket（port+1）。
//!
//! 大列表响应：原版对 List 元素 > 3000 的响应走 chunked 流式 JSON
//! （HttpServer.kt:183-194）；axum 的 body 天然流式，本实现直接整包序列化，
//! 行为等价（登记）。

pub mod book_api;
pub mod book_json;

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, HeaderMap, HeaderValue};
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

/// 原版端点路由（顶层路径，非 `/api` 前缀）
pub fn legacy_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/getBookshelf", get(book_api::get_bookshelf))
        .route("/getChapterList", get(book_api::get_chapter_list))
        .route("/getBookContent", get(book_api::get_book_content))
        // 原版 saveBookProgress 为 POST（HttpServer.kt:90）；GET 在原版会落到
        // 静态资产分支（webAssets 无此文件 → 500），故不提供 GET 别名。
        .route("/saveBookProgress", post(book_api::save_book_progress))
        .route("/getReadConfig", get(book_api::get_read_config))
        .route("/saveReadConfig", post(book_api::save_read_config))
        .route("/cover", get(book_api::get_cover))
        .route("/image", get(book_api::get_image))
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
