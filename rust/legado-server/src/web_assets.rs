//! 原版 Web 静态资产（编译期嵌入）+ 静态服务
//!
//! 资产来源：`app/src/main/assets/web/**`（原版 67 文件 / 2.0MB，整目录拷入
//! `rust/legado-server/web-dist/`），由 `build.rs` 生成静态表
//! `$OUT_DIR/web_assets_table.rs`（`(路径, 内容, MIME)`）后经 `include!` 引入。
//!
//! 行为对齐原版（`app/src/main/java/io/legado/app/web/HttpServer.kt:161-167`
//! + `web/utils/AssetsWeb.kt`）：
//! - 请求路径归一化：`/+` 折叠为单斜杠、去掉前导斜杠后按表查找；
//! - 以 `/` 结尾的路径补 `index.html`（`/` → `index.html`、`/vue/` →
//!   `vue/index.html`）；
//! - 无目录列表、无 SPA 历史回退（Vue 前端为 hash 路由，未知路径不回落 index）；
//! - `Content-Type` 按扩展名；`X-Content-Type-Options: nosniff` 与
//!   `Access-Control-Allow-Origin`（回显 Origin）与原版 `addWebHeaders` 一致；
//! - `/vue/*.html` 追加 `Cache-Control: no-cache` + `VUE_CONTENT_SECURITY_POLICY`；
//! - `OPTIONS` 预检放行 `GET, POST` + `content-type, x-legado-token`。
//!
//! 登记差异（两处，均不改变浏览器可见结果）：
//! 1. 未知路径：原版 `assets.open` 抛 `FileNotFoundException` 被
//!    `HttpServer.serve` 的最外层 catch 兜成 **500** text/plain（原版未做
//!    404 映射）；本实现按 HTTP 语义返回 404。
//! 2. MIME：原版 MIME 表只有 5 条，png/woff/ttf/md 一律 `text/html`（浏览器
//!    靠嗅探容忍）；本实现按扩展名给正确类型，`.js` 保持原版
//!    `text/javascript`，未知扩展名 `application/octet-stream`。
//!
//! 服务顺序：**嵌入优先，磁盘兜底**。嵌入表命中即返回（设备与开发机同一
//! 代码路径，测试覆盖设备语义）；未命中再委托 [`ServeDir`] 读开发机磁盘
//! `web-dist`（新增/未嵌入资产可免重编译热加载）。设备上不存在 `web-dist`
//! 目录，ServeDir 恒 404 → 最终 404，因此「设备语义以嵌入为准」。

use axum::body::Body;
use axum::extract::Request;
use axum::http::{header, HeaderName, HeaderValue, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use tower::ServiceExt;
use tower_http::services::ServeDir;

// `build.rs` 生成的静态表：`(相对路径, 文件内容, MIME)`
include!(concat!(env!("OUT_DIR"), "/web_assets_table.rs"));

/// 对齐原版 `HttpServer.VUE_CONTENT_SECURITY_POLICY`（HttpServer.kt:233-238）
pub const VUE_CONTENT_SECURITY_POLICY: &str = "default-src 'self' data: blob:; \
script-src 'self'; style-src 'self' 'unsafe-inline'; \
img-src * data: blob:; font-src 'self' data: http: https:; \
connect-src * ws: wss:; frame-src 'self' http: https:; \
object-src 'none'; base-uri 'self'";

/// 资产键归一化：percent-decode → 补目录 index → 折叠重复斜杠/去前导斜杠
///
/// 与 `AssetsWeb.getResponse` 的 `(rootPath + path).replace("/+", separator)`
/// 等价（rootPath 固定 `web`，本实现以表键省略该前缀）。`..` 段不会匹配
/// 任何表键，天然免疫目录穿越。
pub fn normalized_asset_key(uri_path: &str) -> String {
    let decoded = urlencoding::decode(uri_path)
        .map(|c| c.into_owned())
        .unwrap_or_else(|_| uri_path.to_string());
    let with_index = if decoded.ends_with('/') {
        format!("{decoded}index.html")
    } else {
        decoded
    };
    with_index
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>()
        .join("/")
}

/// 按归一化键查嵌入表
pub fn lookup(key: &str) -> Option<(&'static [u8], &'static str)> {
    ASSETS
        .iter()
        .find(|(path, _, _)| *path == key)
        .map(|(_, bytes, mime)| (*bytes, *mime))
}

/// 读取请求的 `Origin` 头（原版回显 `Access-Control-Allow-Origin`）
pub fn origin_header(req: &Request) -> Option<String> {
    req.headers()
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

/// 原版 `addWebHeaders`（HttpServer.kt:265-278）：nosniff + Origin 回显 +
/// `/vue/*.html` 的 no-cache/CSP
pub fn with_web_headers(resp: &mut Response, header_path: &str, origin: Option<&str>) {
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
    if header_path.starts_with("/vue/") && header_path.ends_with(".html") {
        headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
        headers.insert(
            HeaderName::from_static("content-security-policy"),
            HeaderValue::from_static(VUE_CONTENT_SECURITY_POLICY),
        );
    }
}

/// 原版 API 响应追加的头（HttpServer.kt:203-204）
pub fn with_api_headers(resp: &mut Response, header_path: &str, origin: Option<&str>) {
    with_web_headers(resp, header_path, origin);
    resp.headers_mut().insert(
        HeaderName::from_static("access-control-allow-methods"),
        HeaderValue::from_static("GET, POST"),
    );
}

/// 顶层静态兜底：嵌入优先 + 磁盘 `/dev` 兜底（见模块注释）
pub async fn serve_static(req: Request) -> Response {
    let method = req.method().clone();
    let uri_path = req.uri().path().to_string();
    let origin = origin_header(&req);

    if method == Method::OPTIONS {
        return preflight_response(origin.as_deref());
    }

    let key = normalized_asset_key(&uri_path);
    let header_path = format!("/{key}");
    if let Some((bytes, mime)) = lookup(&key) {
        return asset_response(&header_path, bytes, mime, origin.as_deref(), &method);
    }

    // 开发机磁盘兜底：设备上无 web-dist 目录，ServeDir 恒 404 → 走下方 404
    match ServeDir::new("web-dist").oneshot(req).await {
        Ok(resp) if resp.status() != StatusCode::NOT_FOUND => {
            let mut resp = resp.map(Body::new);
            with_web_headers(&mut resp, &header_path, origin.as_deref());
            resp
        }
        _ => not_found_response(&header_path, origin.as_deref()),
    }
}

/// 未匹配路由上的方法兜底：`OPTIONS` 预检放行，其余 405
pub async fn method_not_allowed_or_preflight(req: Request) -> Response {
    if req.method() == Method::OPTIONS {
        let origin = origin_header(&req);
        return preflight_response(origin.as_deref());
    }
    (StatusCode::METHOD_NOT_ALLOWED, "Method Not Allowed").into_response()
}

/// 原版 `OPTIONS` 预检（HttpServer.kt:45-56）
pub fn preflight_response(origin: Option<&str>) -> Response {
    let mut resp = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .header(
            HeaderName::from_static("access-control-allow-methods"),
            HeaderValue::from_static("GET, POST"),
        )
        .header(
            HeaderName::from_static("access-control-allow-headers"),
            HeaderValue::from_static("content-type, x-legado-token"),
        )
        .body(Body::empty())
        .expect("预检响应构建失败");
    with_web_headers(&mut resp, "/", origin);
    resp
}

fn asset_response(
    header_path: &str,
    bytes: &'static [u8],
    mime: &'static str,
    origin: Option<&str>,
    method: &Method,
) -> Response {
    let body = if method == Method::HEAD {
        Body::empty()
    } else {
        Body::from(bytes)
    };
    let mut resp = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, mime)
        .body(body)
        .expect("静态资产响应构建失败");
    with_web_headers(&mut resp, header_path, origin);
    resp
}

fn not_found_response(header_path: &str, origin: Option<&str>) -> Response {
    let mut resp = (StatusCode::NOT_FOUND, format!("Not Found: {header_path}")).into_response();
    with_web_headers(&mut resp, header_path, origin);
    resp
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_asset_table_contains_original_entrypoints() {
        assert!(lookup("index.html").is_some(), "根导航页必须已嵌入");
        assert!(lookup("vue/index.html").is_some(), "Vue 入口页必须已嵌入");
        assert!(lookup("vue/assets/index-toG2697L.js").is_some());
        assert!(lookup("help/index.html").is_some());
        assert!(lookup("uploadBook/index.html").is_some());
        assert!(lookup("favicon.ico").is_some());
        assert!(ASSETS.len() >= 67, "原版 67 个文件应全部嵌入");
    }

    #[test]
    fn test_index_entry_mime_and_marker() {
        let (bytes, mime) = lookup("index.html").unwrap();
        assert_eq!(mime, "text/html");
        let html = std::str::from_utf8(bytes).unwrap();
        assert!(html.contains("Legado web 导航"));
    }

    #[test]
    fn test_js_mime_matches_assets_web() {
        let (_, mime) = lookup("vue/assets/index-toG2697L.js").unwrap();
        assert_eq!(mime, "text/javascript", "对齐 AssetsWeb.kt:38");
    }

    #[test]
    fn test_woff_ttf_png_mime_corrected() {
        assert_eq!(
            lookup("vue/assets/iconfont-PstzbNMW.woff").unwrap().1,
            "font/woff"
        );
        assert_eq!(
            lookup("vue/assets/popfont-WaOB0hHG.ttf").unwrap().1,
            "font/ttf"
        );
        assert_eq!(lookup("images/bg.jpg").unwrap().1, "image/jpg");
        assert_eq!(lookup("uploadBook/img/logo.png").unwrap().1, "image/png");
        assert_eq!(lookup("help/md/appHelp.md").unwrap().1, "text/markdown");
    }

    #[test]
    fn test_path_normalization() {
        assert_eq!(normalized_asset_key("/"), "index.html");
        assert_eq!(normalized_asset_key("/vue/"), "vue/index.html");
        assert_eq!(
            normalized_asset_key("/vue//assets///x.js"),
            "vue/assets/x.js"
        );
        assert_eq!(normalized_asset_key("/a%2Db.js"), "a-b.js");
        assert_eq!(normalized_asset_key("/../etc/passwd"), "../etc/passwd");
        assert!(lookup(&normalized_asset_key("/../etc/passwd")).is_none());
    }
}
