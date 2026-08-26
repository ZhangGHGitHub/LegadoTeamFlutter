//! WebBook FFI API
//!
//! 为 Flutter/Dart 提供书源驱动的搜索、目录、内容获取能力。
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。
//!
//! 使用 `RealBookSourceFetcher`（LegadoClient + AnalyzeUrl + AnalyzeRule）
//! 实现完整的搜索→详情→目录→正文链路。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use legado_core::models::BookSource;
use legado_core::models::{Book, BookChapter};
use legado_core::web_book::{
    BookSourceFetcher, WebBookEngine, WebBookInfo, WebChapter, WebSearchResult,
};
use legado_core::{LegadoError, LegadoResult};
use legado_js::js_source::js_source_book::JsSourceBookOrchestrator;
use legado_js::JsSourceConfig;
use legado_net::rate_limit::IntervalRateLimiter;
use legado_net::LegadoClient;
use legado_parser::{compile_regex_safe, AnalyzeUrl, RequestMethod};

/// 对齐原版 OkHttpUtils.ResponseBody.text：显式 charset 优先，随后 HTTP 头，最后 HTML meta。
fn decode_web_response(bytes: &[u8], headers: &HashMap<String, String>, explicit: Option<&str>) -> String {
    let charset = explicit.filter(|s| !s.trim().is_empty()).map(str::to_string)
        .or_else(|| charset_from_content_type(headers))
        .or_else(|| charset_from_html_meta(bytes));
    AnalyzeUrl::decode_response_bytes(bytes, charset.as_deref())
}

fn charset_from_content_type(headers: &HashMap<String, String>) -> Option<String> {
    let value = headers.iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("content-type"))
        .map(|(_, value)| value.as_str())?;
    extract_charset_assignment(value)
}

fn extract_charset_assignment(value: &str) -> Option<String> {
    let lower = value.to_ascii_lowercase();
    let start = lower.find("charset")? + 7;
    let tail = &value[start..];
    let equal = tail.find('=')?;
    let value = tail[equal + 1..].trim();
    let value = value.trim_start_matches(['"', '\'']);
    let charset = value.split([';', ' ', '"', '\'']).next().unwrap_or("");
    (!charset.is_empty()).then(|| charset.to_string())
}

fn charset_from_html_meta(bytes: &[u8]) -> Option<String> {
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(16 * 1024)]);
    let meta_re = regex::Regex::new(r##"(?is)<meta\b[^>]*>"##).ok()?;
    let attr_re = regex::Regex::new(
        r##"(?is)([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>]+))"##,
    ).ok()?;
    for tag in meta_re.find_iter(&head).map(|m| m.as_str()) {
        let mut attrs: HashMap<String, String> = HashMap::new();
        for caps in attr_re.captures_iter(tag) {
            let name = caps.get(1).map(|m| m.as_str().to_ascii_lowercase()).unwrap_or_default();
            let value = caps.get(2).or_else(|| caps.get(3)).or_else(|| caps.get(4))
                .map(|m| m.as_str().to_string()).unwrap_or_default();
            attrs.insert(name, value);
        }
        if let Some(charset) = attrs.get("charset").filter(|v| !v.trim().is_empty()) {
            return Some(charset.trim().to_string());
        }
        let is_content_type = attrs.get("http-equiv")
            .is_some_and(|v| v.eq_ignore_ascii_case("content-type"));
        if is_content_type {
            if let Some(cs) = attrs.get("content").and_then(|v| extract_charset_assignment(v)) {
                return Some(cs);
            }
        }
    }
    None
}
use crate::runtime;

/// 详情/目录短时 HTML 缓存（对齐原版 Book.infoHtml / Book.tocHtml 进程内复用）
///
/// Flutter 信息页串行 `webbookInfo` → `webbookChapters` 时，原版在 analyzeBookInfo
/// 后把 body 写入 tocHtml，目录阶段不再二次 HTTP。无状态 FFI 无法携带 Book，
/// 故用 URL 键短 TTL 缓存承接同一次进入详情的重复拉页。
const PAGE_BODY_CACHE_TTL: Duration = Duration::from_secs(45);
const PAGE_BODY_CACHE_MAX: usize = 32;

struct PageBodyCache {
    entries: HashMap<String, (Instant, String)>,
}

impl PageBodyCache {
    fn new() -> Self {
        Self {
            entries: HashMap::new(),
        }
    }

    fn get(&mut self, url: &str) -> Option<String> {
        let now = Instant::now();
        self.entries.retain(|_, (t, _)| now.duration_since(*t) < PAGE_BODY_CACHE_TTL);
        self.entries.get(url).map(|(_, b)| b.clone())
    }

    fn put(&mut self, url: &str, body: String) {
        let now = Instant::now();
        self.entries.retain(|_, (t, _)| now.duration_since(*t) < PAGE_BODY_CACHE_TTL);
        if self.entries.len() >= PAGE_BODY_CACHE_MAX {
            // 简单淘汰：丢掉最旧一条
            if let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, (t, _))| *t)
                .map(|(k, _)| k.clone())
            {
                self.entries.remove(&oldest);
            }
        }
        self.entries.insert(url.to_string(), (now, body));
    }
}

fn page_body_cache() -> &'static Mutex<PageBodyCache> {
    static CACHE: OnceLock<Mutex<PageBodyCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(PageBodyCache::new()))
}

fn cache_get_page_body(url: &str) -> Option<String> {
    page_body_cache()
        .lock()
        .ok()
        .and_then(|mut c| c.get(url))
}

fn cache_put_page_body(url: &str, body: &str) {
    if let Ok(mut c) = page_body_cache().lock() {
        c.put(url, body.to_string());
    }
}

// ─── Real Fetcher（真实网络请求 + 规则解析） ────────────────────────────────────

/// 真实书源数据抓取器
///
/// 字节数组 → 小写 hex 字符串（对齐 Kotlin HexUtil.encodeHexStr）
fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

/// 若 URL 是 data: URI（可能带 `,{...}` 请求选项，如书山
/// `data:detailsUrl;base64,<b64>,{"type":"susan"}`），返回其解码内容：
/// - type 非空 → hex 编码字节（书山 init JS 用 java.hexDecodeToString 还原）
/// - 否则 → UTF-8 文本
fn fetch_data_uri_content(url: &str) -> Option<LegadoResult<String>> {
    let parsed = AnalyzeUrl::parse(url, &std::collections::HashMap::new(), 1).ok()?;
    if !parsed.is_data_uri() {
        return None;
    }
    let bytes = parsed.get_byte_array_if_data_uri()?;
    if parsed.response_type().is_some() {
        Some(Ok(hex_encode(&bytes)))
    } else {
        Some(Ok(String::from_utf8_lossy(&bytes).to_string()))
    }
}

/// G4：每源固定窗口限流缓存（键=书源 URL，跨请求保持窗口状态）
static RATE_LIMITERS: OnceLock<Mutex<HashMap<String, Arc<IntervalRateLimiter>>>> =
    OnceLock::new();

/// 按书源 concurrentRate 获取访问许可（对齐 Kotlin ConcurrentRateLimiter.withLimit）
///
/// 每源限流器缓存在全局 map 中，跨请求保持固定窗口状态（否则窗口起点每次
/// 重置 = 永不生效）。
async fn acquire_source_rate_limit(source: &BookSource) {
    let rate = source.concurrent_rate.as_deref().unwrap_or("").trim();
    if rate.is_empty() || rate == "0" {
        return;
    }
    let Some(limiter) = IntervalRateLimiter::parse(rate) else {
        return;
    };
    let map = RATE_LIMITERS.get_or_init(|| Mutex::new(HashMap::new()));
    let limiter = {
        let mut guard = map.lock().unwrap();
        Arc::clone(
            guard
                .entry(source.book_source_url.clone())
                .or_insert_with(|| Arc::new(limiter)),
        )
    };
    limiter.acquire().await;
}

/// 基于 legado-net HTTP 客户端 + legado-parser 规则解析引擎，
/// 实现完整的搜索→详情→目录→正文链路（对标 Kotlin WebBook 对象）。
pub struct RealBookSourceFetcher {
    client: LegadoClient,
}

impl RealBookSourceFetcher {
    pub fn new() -> LegadoResult<Self> {
        // 复用进程共享的 HTTP 客户端单例（共享连接池与 CookieStore，clone 廉价）
        let client = crate::http_state::shared_client()?;
        Ok(Self { client })
    }

    /// 解析书源 header 字段为请求头（含登录头与 JS Cookie 合并）
    ///
    /// 对齐原版 `BaseSource.getHeaderMap(hasLoginHeader=true)`：
    /// 1. 书源静态 `header` 字段（JSON map）
    /// 2. 合并 `source_login_cache::get_login_header`（登录后保存的 loginHeader，
    ///    覆盖同名键，对齐原版 putAll 顺序 loginHeader 在后）
    /// 3. 合并 JS `java.setCookie` 写入的全局 Cookie（GLOBAL_COOKIES）——
    ///    仅当尚无 Cookie 头时设置，保证 JS 侧登录 Cookie 随请求发送
    ///    （对齐原版 CookieStore 单存储自动附加语义）— DeepSeek Harness + Bridge
    fn parse_source_headers(source: &BookSource) -> Option<HashMap<String, String>> {
        let mut headers: HashMap<String, String> = source
            .header
            .as_ref()
            .and_then(|h| serde_json::from_str(h).ok())
            .unwrap_or_default();

        if let Some(login_header_json) =
            crate::api::source_login_cache::get_login_header(&source.book_source_url)
        {
            if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(&login_header_json) {
                headers.extend(map);
            }
        }

        let js_cookie = legado_js::host_api::cookie_store::get_cookie(&source.book_source_url);
        if !js_cookie.is_empty() && !headers.contains_key("Cookie") {
            headers.insert("Cookie".to_string(), js_cookie);
        }

        if headers.is_empty() {
            None
        } else {
            Some(headers)
        }
    }

    /// 根据 AnalyzeUrl 解析结果发起 HTTP 请求，返回响应体文本
    #[allow(dead_code)] // 诊断测试仍走此包装；搜索主路径用 fetch_page
    async fn fetch_url(
        &self,
        analyze_url: &AnalyzeUrl,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<String> {
        Ok(self
            .fetch_page(analyze_url, source_headers)
            .await?
            .body)
    }

    /// 对齐 Kotlin `AnalyzeUrl.getStrResponseAwait`：正文 + 重定向后最终 URL（`StrResponse.url`）
    async fn fetch_page(
        &self,
        analyze_url: &AnalyzeUrl,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<FetchedPage> {
        let url = analyze_url.url();
        if url.is_empty() {
            return Err(LegadoError::Internal("AnalyzeUrl 解析后 URL 为空".into()));
        }

        // 合并请求头：书源全局 header + AnalyzeUrl 解析出的 header
        let mut headers = source_headers.cloned().unwrap_or_default();
        headers.extend(analyze_url.headers().clone());
        let headers_opt = if headers.is_empty() {
            None
        } else {
            Some(headers)
        };

        // data: URI 优先：不发起网络请求，直接解码内容（书山 bookUrl =
        // `data:detailsUrl;base64,<base64 JSON>,{"type":"susan"}` 形态）。
        // 对齐原版：data URI 请求返回其 base64 解码字节；type 非空时再 hex 编码
        //（书山 ruleBookInfo.init 用 java.hexDecodeToString(result) 还原 JSON）。
        if analyze_url.is_data_uri() {
            if let Some(bytes) = analyze_url.get_byte_array_if_data_uri() {
                let body = if analyze_url.response_type().is_some() {
                    hex_encode(&bytes)
                } else {
                    String::from_utf8_lossy(&bytes).to_string()
                };
                return Ok(FetchedPage {
                    body,
                    final_url: url.to_string(),
                });
            }
            return Err(LegadoError::Internal("data: URI 内容解码失败".into()));
        }

        // G12: response_type（如 "hex"）→ 原始字节 hex 编码返回（对齐原版
        // AnalyzeUrl.getStrResponse 的 type!=null 分支：HexUtil.encodeHexStr(getByteArrayAwait)）
        if analyze_url.response_type().is_some() {
            let raw = self.client.get_raw(url, headers_opt.clone()).await?;
            if !raw.is_success() {
                return Err(LegadoError::Network(format!(
                    "HTTP {} for {}",
                    raw.status, url
                )));
            }
            check_redirect_log(url, &raw.url);
            let final_url = if raw.url.is_empty() {
                url.to_string()
            } else {
                raw.url.clone()
            };
            return Ok(FetchedPage {
                body: hex_encode(&raw.body),
                final_url,
            });
        }

        // 原始字节响应：对齐原版 ResponseBody.text()，避免目录/正文 HTML 的
        // meta charset=gbk 在 reqwest UTF-8 默认解码后不可逆乱码（七步阁等）。
        let response = match analyze_url.method() {
            RequestMethod::Post => {
                self.client
                    .post_raw(url, analyze_url.request_body(), headers_opt)
                    .await?
            }
            _ => self.client.get_raw(url, headers_opt).await?,
        };

        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }
        // 对齐 Kotlin WebBook.checkRedirect（Debug.log 可观测性）
        check_redirect_log(url, &response.url);
        let final_url = if response.url.is_empty() {
            url.to_string()
        } else {
            response.url.clone()
        };

        Ok(FetchedPage {
            body: decode_web_response(
                &response.body,
                &response.headers,
                analyze_url.charset(),
            ),
            final_url,
        })
    }

    /// 直接 GET 一个 URL（用于章节内容等简单场景）
    ///
    /// `use_page_cache`：详情→目录同页复用时读/写短时缓存（对标 infoHtml/tocHtml）。
    async fn fetch_simple(
        &self,
        url: &str,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<String> {
        self.fetch_simple_cached(url, source_headers, false).await
    }

    async fn fetch_simple_cached(
        &self,
        url: &str,
        source_headers: Option<&HashMap<String, String>>,
        use_page_cache: bool,
    ) -> LegadoResult<String> {
        // data: URI（书山 bookUrl 形态）优先处理、不读缓存（缓存可能是修复前
        // 写入的旧 body，非 hex → hexDecodeToString 失败 → [ERROR]）
        if let Some(result) = fetch_data_uri_content(url) {
            return result;
        }
        if use_page_cache {
            if let Some(cached) = cache_get_page_body(url) {
                eprintln!("[web_book] page body cache hit: {url}");
                return Ok(cached);
            }
        }
        let headers_opt = source_headers.cloned();
        // 简单 GET 同样必须保留字节至 charset 检测结束：正文/目录 URL 通常
        // 没有显式 UrlOption.charset，只能依赖响应头或 HTML meta。
        let response = self.client.get_raw(url, headers_opt).await?;
        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }
        check_redirect_log(url, &response.url);
        let body = decode_web_response(&response.body, &response.headers, None);
        if use_page_cache {
            cache_put_page_body(url, &body);
        }
        Ok(body)
    }

    /// 执行 loginCheckJs 登录检测（规则路径增强）
    ///
    /// 参考 Kotlin WebBook.kt 四链路中的 loginCheckJs 双路径模式：
    /// - 成功路径：HTTP 响应正常时 evalJS(loginCheckJs)
    /// - 无配置时静默跳过，不影响现有逻辑
    fn execute_login_check(
        source: &BookSource,
        response_body: &str,
        response_url: &str,
        response_code: u16,
    ) -> LegadoResult<()> {
        let login_check_js = match &source.login_check_js {
            Some(js) if !js.trim().is_empty() => js,
            _ => return Ok(()), // 无 loginCheckJs 配置，跳过
        };

        // 对齐原版 Kotlin WebBook 双路径语义（WebBook.kt:226-250 等）：
        // - 成功路径：正常响应 eval，判定未登录（false/未登录/needLogin）
        //   → 构造 errResponse（HTTP 500）二次 eval（JS 可在此自动登录并返回新响应）
        //   → 仍判定未登录则上抛 LoginRequired（提示用户先登录书源）
        // - JS 环境不兼容（依赖 java.* 等 Android 运行时对象）→ 降级放行，
        //   避免阻断无需登录检测能力的书源获取
        match crate::js_executor::execute_login_check_js(
            login_check_js,
            response_body,
            response_url,
            response_code,
            &source.book_source_url,
        ) {
            Ok(()) => Ok(()),
            Err(crate::js_executor::LoginCheckError::NotLoggedIn(msg)) => {
                let err_body = format!("HTTP/1.1 500 Internal Server Error\n\n{msg}");
                match crate::js_executor::execute_login_check_js(
                    login_check_js,
                    &err_body,
                    response_url,
                    500,
                    &source.book_source_url,
                ) {
                    Ok(()) => Ok(()),
                    Err(crate::js_executor::LoginCheckError::NotLoggedIn(_)) => Err(
                        LegadoError::LoginRequired(
                            "书源需要登录，请先在书源菜单中登录后重试".into(),
                        ),
                    ),
                    Err(crate::js_executor::LoginCheckError::JsFailed(e)) => {
                        eprintln!(
                            "[web_book] loginCheckJs errResponse 路径执行失败（降级放行）: {e}"
                        );
                        Ok(())
                    }
                }
            }
            Err(crate::js_executor::LoginCheckError::JsFailed(e)) => {
                eprintln!("[web_book] loginCheckJs 执行失败（环境不兼容，降级放行）: {e}");
                Ok(())
            }
        }
    }

    /// 从详情页响应体解析书籍详情（可复用辅助方法）
    ///
    /// 同时服务于：
    /// - 详情路径 `get_book_info`
    /// - 搜索详情页直连 / 空列表回退（B1.1）
    ///
    /// 对标 Kotlin `BookInfo.analyzeBookInfo`：
    /// - **canReName 双条件门控**：仅当规则 `canReName` 非空且入参 `can_re_name` 为 true 时，
    ///   才允许以解析结果覆盖已有书名/作者（`mCanReName = canReName && !infoRule.canReName.isNullOrBlank()`）；
    ///   否则仅在原值为空时填充。
    /// - **coverUrl 绝对化**：基于 `redirect_url` 转绝对 URL。
    /// - **tocUrl**：绝对化，空时回退 `book_url`。
    /// - **kind / wordCount** 字段提取。
    fn parse_book_info_from_body(
        source: &BookSource,
        body: String,
        book_url: &str,
        redirect_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
    ) -> WebBookInfo {
        let info_rule = source.rule_book_info.as_ref();
        // 书山等聚合源 init 规则依赖 jsLib（getServerHost）与书源上下文 setup
        // （java.ajax 需携带 header 规则注入的 X-Novel-Token）；jsLib 须 sanitize
        //（去 Rhino Packages 行），否则 init 失败 → tocUrl 规则 result 缺
        // source/book_url → /catalog 请求「无效书源」。— 书山目录修复
        let js_lib_sanitized = source
            .js_lib
            .as_deref()
            .map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
        let mut analyzer = crate::js_executor::construct_analyzer_with_source_context(
            body,
            book_url.to_string(),
            &source.book_source_url,
            js_lib_sanitized.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        );

        // 详情页 init（对齐原版 BookInfo.analyzeBookInfo：执行 init 规则后
        // setContent(getElement(init)) —— init 结果作为后续字段规则的新 content。
        // 书山聚合 init 把 data:URI 的 hex detail JSON 转成 /details 响应（含
        // source/book_url/title），tocUrl 规则依赖该 result；仅执行不更新
        // content 会导致 tocUrl 产出 {"tab":"novel"} 空 catalog。— 书山目录修复
        if let Some(init_rule) = info_rule.and_then(|r| r.init.as_deref()) {
            let init_rule = init_rule.trim();
            if !init_rule.is_empty() {
                if let Ok(init_result) = analyzer.get_string(init_rule) {
                    if !init_result.is_empty() {
                        // 对象语义注入：tocUrl 等后续规则访问 result.source 等
                        // 字段需要 JSON 对象（对齐原版 getElements(init) Map）
                        analyzer.set_element_content(init_result);
                    }
                }
            }
        }

        // B2.1 canReName 双条件门控
        let rule_can_re_name = info_rule
            .and_then(|r| r.can_re_name.as_deref())
            .is_some_and(|v| !v.trim().is_empty());
        let m_can_re_name = can_re_name && rule_can_re_name;

        // 书名：对标 Kotlin `if (it.isNotEmpty() && (mCanReName || book.name.isEmpty()))`
        let parsed_name = info_rule
            .and_then(|r| r.name.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let name = if !parsed_name.is_empty() && (m_can_re_name || existing_name.is_empty()) {
            parsed_name
        } else {
            existing_name.to_string()
        };

        // 作者：与书名同门控
        let parsed_author = info_rule
            .and_then(|r| r.author.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let author = if !parsed_author.is_empty() && (m_can_re_name || existing_author.is_empty()) {
            parsed_author
        } else {
            existing_author.to_string()
        };

        // 分类：kind 原始字符串 + 拆分后的 categories
        let kind_raw = info_rule
            .and_then(|r| r.kind.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let (kind, categories) = if kind_raw.is_empty() {
            (None, Vec::new())
        } else {
            let cats = kind_raw
                .split([',', '，', ' '])
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            (Some(kind_raw), cats)
        };

        // B2 字数
        let word_count = info_rule
            .and_then(|r| r.word_count.as_deref())
            .and_then(|rule| optional_field(&analyzer, rule));

        let intro = info_rule
            .and_then(|r| r.intro.as_deref())
            .and_then(|rule| optional_field(&analyzer, rule));

        // 封面：基于 redirect_url 绝对化（对标 Kotlin NetworkUtils.getAbsoluteURL(redirectUrl, it)）
        let cover_url = info_rule
            .and_then(|r| r.cover_url.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(AnalyzeUrl::get_absolute_url(redirect_url, &v))
                }
            })
            .unwrap_or(None);

        let last_chapter = info_rule
            .and_then(|r| r.last_chapter.as_deref())
            .and_then(|rule| optional_field(&analyzer, rule));

        // 目录页 URL：绝对化 + 空时回退 book_url（对标 Kotlin `if (book.tocUrl.isEmpty()) book.tocUrl = baseUrl`）
        let raw_toc = info_rule
            .and_then(|r| r.toc_url.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let toc_url = if raw_toc.is_empty() {
            book_url.to_string()
        } else {
            AnalyzeUrl::get_absolute_url(book_url, &raw_toc)
        };

        WebBookInfo {
            name,
            author,
            cover_url,
            intro,
            categories,
            last_chapter,
            book_url: book_url.to_string(),
            toc_url,
            word_count,
            kind,
        }
    }
}

impl Default for RealBookSourceFetcher {
    fn default() -> Self {
        Self::new().unwrap_or_else(|e| panic!("shared HTTP client init: {e}"))
    }
}

impl BookSourceFetcher for RealBookSourceFetcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        acquire_source_rate_limit(source).await;
        let search_url = source.search_url.as_deref().unwrap_or("");
        if search_url.is_empty() {
            return Err(LegadoError::Internal("书源未配置 searchUrl".into()));
        }

        let source_headers = Self::parse_source_headers(source);

        // 1. 解析搜索 URL 模板（`{{JS表达式}}` / `@js:` 模板经 JS 引擎求值渲染，
        //    纯字面模板走旧版路径；见 js_executor::build_search_url_with_setup）
        //    必须携带 jsLib + 书源上下文 setup：searchUrl 里 `{{source.getKey()}}`
        //    （爱下电子）或 `{{url=source.getKey();...}}`（企鹅小说/笔下文学）
        //    依赖 source 绑定，缺 setup → 模板原样残留 → HTTP 404 误导
        //    （2026-08-17 批量扫描 120 源发现）
        let analyze_url = crate::js_executor::build_search_url_with_setup(
            search_url,
            query,
            page,
            &source.book_source_url,
            source.js_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        );
        if analyze_url.url().starts_with("legado-js-error://") {
            return Err(LegadoError::Internal(format!(
                "searchUrl JS 求值失败: {}",
                analyze_url.url()
            )));
        }

        // 2. 发起 HTTP 请求。baseUrl 必须用重定向后最终 URL
        //    （对齐 Kotlin WebBook.search → BookList.analyzeBookList(baseUrl = res.url)）。
        //    书书小说等会把搜索 302 到书籍页；若仍用请求 URL，bookList 空列表回退
        //    会把 search.php 当成 bookUrl，详情规则也解不出书名 → 搜索 0 条。
        let fetched = self
            .fetch_page(&analyze_url, source_headers.as_ref())
            .await?;
        let body = fetched.body;
        let request_url = analyze_url.url().to_string();
        let base_url = fetched.final_url;

        // 2.5 loginCheckJs 登录检测（规则路径增强）
        Self::execute_login_check(source, &body, &base_url, 200)?;

        let search_rule = source.rule_search.as_ref();

        // 3. bookUrlPattern 详情页直连（B1.1，对标 Kotlin BookList `baseUrl.matches(bookUrlPattern)`）
        //    若搜索结果页 URL 命中详情页正则，说明返回体本身就是详情页，按单条详情解析。
        let has_pattern = source
            .book_url_pattern
            .as_deref()
            .is_some_and(|p| !p.trim().is_empty());
        if has_pattern
            && matches_book_url_pattern(source.book_url_pattern.as_deref().unwrap_or(""), &base_url)
        {
            let info = Self::parse_book_info_from_body(
                source,
                body,
                &base_url,
                &base_url,
                true,
                "",
                "",
            );
            return Ok(if info.name.is_empty() {
                vec![]
            } else {
                vec![info_to_search_result(info, &source.book_source_url)]
            });
        }

        // 4. 使用搜索规则解析列表
        let book_list_rule = search_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("");

        // 书山等聚合源搜索规则依赖书源上下文（jsLib + setup：bookList/bookUrl
        // 的 @js: 块用 source.getKey 等）——对齐原版 BookList 的 AnalyzeRule
        // with source。此前仅 jsLib 无 setup → source 未定义 → 空结果。
        let search_lib = source
            .js_lib
            .as_deref()
            .map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
        let analyzer = crate::js_executor::construct_analyzer_with_source_context(
            body.clone(),
            base_url.clone(),
            &source.book_source_url,
            search_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        );

        let elements = if book_list_rule.is_empty() {
            vec![analyzer.content().to_string()]
        } else {
            analyzer.get_elements(book_list_rule).unwrap_or_default()
        };
        eprintln!(
            "[web_book] search request={request_url} base={base_url} elements={}",
            elements.len()
        );

        // 4.5 列表为空且未配置 bookUrlPattern 时，回退按详情页解析（对标 Kotlin BookList “列表为空,按详情页解析”）
        if elements.is_empty() && !has_pattern {
            let info = Self::parse_book_info_from_body(
                source,
                body,
                &base_url,
                &base_url,
                true,
                "",
                "",
            );
            return Ok(if info.name.is_empty() {
                vec![]
            } else {
                vec![info_to_search_result(info, &source.book_source_url)]
            });
        }

        // 5. 逐项提取字段（规则提到循环外，避免重复解析）
        let name_rule = search_rule.and_then(|r| r.name.as_deref()).unwrap_or("");
        let author_rule = search_rule.and_then(|r| r.author.as_deref()).unwrap_or("");
        let book_url_rule = search_rule
            .and_then(|r| r.book_url.as_deref())
            .unwrap_or("");
        let cover_url_rule = search_rule
            .and_then(|r| r.cover_url.as_deref())
            .unwrap_or("");
        let intro_rule = search_rule.and_then(|r| r.intro.as_deref()).unwrap_or("");
        let last_chapter_rule = search_rule
            .and_then(|r| r.last_chapter.as_deref())
            .unwrap_or("");
        let kind_rule = search_rule.and_then(|r| r.kind.as_deref()).unwrap_or("");
        let word_count_rule = search_rule
            .and_then(|r| r.word_count.as_deref())
            .unwrap_or("");

        let mut results = Vec::new();
        for elem in elements.iter().take(50) {
            let mut elem_analyzer = crate::js_executor::construct_analyzer_with_source_context(
                elem.clone(),
                base_url.clone(),
                &source.book_source_url,
                search_lib.as_deref(),
                crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
            );
            // 元素模式：JSON 列表元素按对象注入 result（`.data[*]` 等
            // 规则产出的元素为 JSON 对象，`name: novelName` 裸键访问依赖
            // result 对象语义；缺省字符串注入 → 字段取空 → 搜索 0 结果）
            elem_analyzer.set_element_content(elem.clone());

            let name = eval_rule_string(&elem_analyzer, name_rule).unwrap_or_default();
            if name.is_empty() {
                continue;
            }

            let author = eval_rule_string(&elem_analyzer, author_rule).unwrap_or_default();

            // B1.4 bookUrl 绝对化（对标 Kotlin getString(ruleBookUrl, isUrl=true)），空时回退 baseUrl
            let raw_book_url = eval_rule_string(&elem_analyzer, book_url_rule).unwrap_or_default();
            let book_url = if raw_book_url.is_empty() {
                base_url.clone()
            } else {
                AnalyzeUrl::get_absolute_url(&base_url, &raw_book_url)
            };

            // B1.4 coverUrl 绝对化（对标 Kotlin NetworkUtils.getAbsoluteURL(baseUrl, it)）
            let cover_url = {
                let v = eval_rule_string(&elem_analyzer, cover_url_rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(AnalyzeUrl::get_absolute_url(&base_url, &v))
                }
            };
            let intro = optional_field(&elem_analyzer, intro_rule);
            let latest_chapter = optional_field(&elem_analyzer, last_chapter_rule);
            // B1.2 kind / wordCount 输出字段
            let kind = optional_field(&elem_analyzer, kind_rule);
            let word_count = optional_field(&elem_analyzer, word_count_rule);

            results.push(WebSearchResult {
                name,
                author,
                book_url,
                cover_url,
                intro,
                latest_chapter,
                source_url: source.book_source_url.clone(),
                kind,
                word_count,
                // 类型位标记（对齐原版 BookType；漫画/听书/视频源分流）— A8
                book_type: crate::api::search::book_type_of_source(source.book_source_type),
            });
        }

        // B1.3 LinkedHashSet 去重：按 bookUrl 去重，保留首次出现顺序
        Ok(dedupe_by_book_url(results))
    }

    async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        acquire_source_rate_limit(source).await;
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求书籍详情页
        //    对标原版 Book.infoHtml / tocHtml：无状态 FFI 无法携带 Book，故用 URL 短 TTL 缓存。
        //    bookUrl 可能是「url,{json}」带请求选项的格式（七猫四合一发现列表 qmGetUrl 生成
        //    https://.../reader/detail?... ,{"method":"GET","headers":{...}}）：必须经
        //    AnalyzeUrl 解析出 url/method/headers 再请求，直接 GET 会把 ,{json} 拼进请求
        //    → HTTP 401/404（2026-08-15 用户反馈七猫目录/正文获取不到）
        let t_fetch = std::time::Instant::now();
        let analyze_book = legado_parser::AnalyzeUrl::parse(
            book_url,
            &std::collections::HashMap::new(),
            1,
        )
        .map_err(|e| LegadoError::Internal(format!("bookUrl 解析失败: {e}")))?;
        let body = self
            .fetch_url(&analyze_book, source_headers.as_ref())
            .await?;
        eprintln!(
            "[web_book] get_book_info fetch {} in {:?}",
            book_url,
            t_fetch.elapsed()
        );

        // 1.5 loginCheckJs 登录检测
        Self::execute_login_check(source, &body, book_url, 200)?;

        // 2. 使用 bookInfo 规则解析（无状态上下文无已有书名，canReName=true、existing 为空）
        let t_parse = std::time::Instant::now();
        let info = Self::parse_book_info_from_body(
            source, body, book_url, book_url, true, "", "",
        );
        eprintln!(
            "[web_book] get_book_info parse in {:?} name={}",
            t_parse.elapsed(),
            info.name
        );
        Ok(info)
    }

    async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        self.get_chapters_with_hints(source, book_url, None, None)
            .await
    }

    async fn get_content(&self, source: &BookSource, chapter: &WebChapter) -> LegadoResult<String> {
        acquire_source_rate_limit(source).await;
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求章节页面（章节 URL 可能是「url,{json}」带请求选项的格式，
        //    如七猫 qmGetUrl 生成 https://.../chapter/content?id=...,
        //    {"method":"GET","headers":{...}}：必须经 AnalyzeUrl 解析出
        //    url/method/headers，直接 GET 会把 ,{json} 拼进请求 → 正文失败）
        let analyze_chapter = legado_parser::AnalyzeUrl::parse(
            &chapter.url,
            &std::collections::HashMap::new(),
            1,
        )
        .map_err(|e| LegadoError::Internal(format!("章节 URL 解析失败: {e}")))?;
        let mut body = self
            .fetch_url(&analyze_chapter, source_headers.as_ref())
            .await?;
    
        // 1.5 loginCheckJs 登录检测
        Self::execute_login_check(source, &body, &chapter.url, 200)?;

        // 1.6 正文 webJs / sourceRegex（对齐 WebBook.getContent →
        // AnalyzeUrl.getStrResponseAwait(jsStr=webJs, sourceRegex=…)）
        let content_rule = source.rule_content.as_ref();
        body = apply_content_web_hooks(
            body,
            content_rule,
            &chapter.url,
            &source.book_source_url,
            source.js_lib.as_deref(),
        );

        // 2. 使用正文规则解析首页
        let content_rule_str = content_rule
            .and_then(|r| r.content.as_deref())
            .unwrap_or("");
        let next_url_rule = content_rule
            .and_then(|r| r.next_content_url.as_deref())
            .unwrap_or("");
        // R1/R2 规则（Task #134）：subContent 副内容 + replaceRegex 全文替换
        let sub_content_rule = content_rule
            .and_then(|r| r.sub_content.as_deref())
            .map(str::trim)
            .unwrap_or("");
        let replace_regex_rule = content_rule
            .and_then(|r| r.replace_regex.as_deref())
            .map(str::trim)
            .unwrap_or("");

        // 音频/视频书源获取的是链接，不需要 HTML 格式化
        let is_media = source.book_source_type == legado_core::models::book_source::book_source_type::AUDIO
            || source.book_source_type == legado_core::models::book_source::book_source_type::VIDEO;

        // R1（Task #134）：副内容基于首页响应体提取，分页前保留一份首页 body
        let first_page_body = if sub_content_rule.is_empty() {
            None
        } else {
            Some(body.clone())
        };

        // 神漫画等内容 JS 依赖 chapter.index + book.totalChapterNum
        let total_chapters = infer_total_chapter_num(&body, chapter);

        // 书山等聚合源正文依赖书源上下文 setup（header 规则注入 + loginHeader）
        let content_setup =
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok();
        let (first_content, next_urls) = parse_content_page_with_bindings(
            body,
            content_rule_str,
            next_url_rule,
            &chapter.url,
            Some(source),
            is_media,
            source.js_lib.as_deref(),
            content_setup.clone(),
            Some(&chapter.title),
            Some(chapter.index),
            Some(total_chapters),
            chapter.variable.as_deref(),
        );

        // 3. 缺口① nextContentUrl 分页抓取（审计 2026-08-06，加法式）
        let source_headers_clone = source_headers.clone();
        let chapter_title = chapter.title.clone();
        let chapter_index = chapter.index;
        let chapter_variable = chapter.variable.clone();
        let mut content = fetch_paginated_content(
            first_content,
            next_urls,
            &chapter.url,
            &source.book_source_url,
            content_rule_str,
            next_url_rule,
            is_media,
            source.js_lib.as_deref(),
            content_setup.clone(),
            Some(chapter_title.as_str()),
            Some(chapter_index),
            Some(total_chapters),
            chapter_variable.as_deref(),
            |url: String| {
                let headers = source_headers_clone.clone();
                async move { self.fetch_simple(&url, headers.as_ref()).await }
            },
        )
        .await;

        // 4. R1 subContent 副内容（Task #134）：分页循环完成后从首页提取副内容。
        if let Some(page_body) = first_page_body {
            let sub_headers = source_headers.clone();
            if let Some(sub) = fetch_sub_content(
                page_body,
                sub_content_rule,
                &chapter.url,
                &source.book_source_url,
                source.js_lib.as_deref(),
                |url: String| {
                    let headers = sub_headers.clone();
                    async move { self.fetch_simple(&url, headers.as_ref()).await }
                },
            )
            .await
            {
                merge_sub_content_into_body(&mut content, &sub, is_media);
            }
        }

        // 5. R2 contentRule.replaceRegex 全文替换（Task #134）
        if !replace_regex_rule.is_empty() {
            content = apply_content_replace_regex(
                content,
                replace_regex_rule,
                &chapter.url,
                &source.book_source_url,
                source.js_lib.as_deref(),
            )?;
        }

        // 6. 空内容检查（卷章豁免）
        if !chapter.is_volume && content.trim().is_empty() {
            return Err(LegadoError::ContentEmpty(format!(
                "章节 {} 正文为空",
                chapter.title
            )));
        }

        Ok(content)
    }
}

impl RealBookSourceFetcher {
    /// 获取章节列表（可选传入已知 tocUrl / 书名，跳过重复拉详情页）
    pub async fn get_chapters_with_hints(
        &self,
        source: &BookSource,
        book_url: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
    ) -> LegadoResult<Vec<WebChapter>> {
        acquire_source_rate_limit(source).await;
        let source_headers = Self::parse_source_headers(source);
        // 书山聚合等聚合源详情/目录 `<js>` 脚本依赖 jsLib 函数（getServerHost 等）
        // 与书源上下文 setup；jsLib 需 sanitize（去 Rhino 特有 Packages 行）后注入，
        // 否则 init 规则失败 → tocUrl 规则 result 缺 source/book_url → /catalog
        // 请求「无效书源」。— 书山目录修复
        let js_lib_sanitized = source
            .js_lib
            .as_deref()
            .map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
        let t0 = std::time::Instant::now();

        let info_rule = source.rule_book_info.as_ref();
        let mut book_name = book_name_hint.unwrap_or("").trim().to_string();

        // 对齐原版 WebBook.getChapterListAwait：直接使用 book.tocUrl 拉目录，
        // 不必每次都先解析详情页（发现/搜索带入 tocUrl 时可省一次 HTTP）。
        // 注意：known_toc_url == book_url（详情页 URL，发现列表 Book 未解析出
        // tocUrl 时的默认值）不算有效目录地址——七猫等书源的 tocUrl 由详情
        // 规则（qmBookInfo）动态生成，直接当目录请求会得到详情响应而非
        // chapter-list → qmToc 无 chapter_lists → 目录空（2026-08-15 用户反馈）。
        let (toc_url, toc_body) =
            if let Some(raw_toc) = known_toc_url.filter(|u| !u.is_empty() && *u != book_url) {
            let toc_url = if raw_toc.starts_with("http://") || raw_toc.starts_with("https://") {
                raw_toc.to_string()
            } else {
                AnalyzeUrl::get_absolute_url(book_url, raw_toc)
            };
            eprintln!(
                "[web_book] get_chapters use known tocUrl={} skip info in {:?}",
                toc_url,
                t0.elapsed()
            );
            if toc_url == book_url {
                // bookUrl 同样可能带「url,{json}」请求选项（七猫），经 AnalyzeUrl 解析
                let analyze_book = legado_parser::AnalyzeUrl::parse(
                    book_url,
                    &std::collections::HashMap::new(),
                    1,
                )
                .map_err(|e| {
                    LegadoError::Internal(format!("bookUrl 解析失败: {e}"))
                })?;
                let info_body = self
                    .fetch_url(&analyze_book, source_headers.as_ref())
                    .await?;
                Self::execute_login_check(source, &info_body, book_url, 200)?;
                if book_name.is_empty() {
                    let info_analyzer =
                        crate::js_executor::construct_analyzer_with_source_context(
                            info_body.clone(),
                            book_url.to_string(),
                            &source.book_source_url,
                            js_lib_sanitized.as_deref(),
                            crate::api::source_js_bindings::book_source_js_setup_script(source)
                                .ok(),
                        );
                    book_name = info_rule
                        .and_then(|r| r.name.as_deref())
                        .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
                        .unwrap_or_default()
                        .lines()
                        .map(str::trim)
                        .find(|s| !s.is_empty())
                        .unwrap_or("")
                        .to_string();
                }
                (toc_url, info_body)
            } else {
                // tocUrl 可能是「url,{json}」带请求选项的格式（七猫四合一
                // qmGetUrl 生成 https://.../chapter/chapter-list?...,
                // {"method":"GET","headers":{...}}）：必须经 AnalyzeUrl 解析出
                // url/method/headers 再请求，直接 GET 会把 ,{json} 拼进请求
                // → 目录接口 404/错误 → 「共 0 章」（2026-08-15 用户反馈）
                let analyze_toc = legado_parser::AnalyzeUrl::parse(
                    &toc_url,
                    &std::collections::HashMap::new(),
                    1,
                )
                .map_err(|e| {
                    LegadoError::Internal(format!("tocUrl 解析失败: {e}"))
                })?;
                let body = self
                    .fetch_url(&analyze_toc, source_headers.as_ref())
                    .await?;
                (toc_url, body)
            }
        } else {
            // 1. 先获取详情页以确定 toc_url
            //    （bookUrl 可能带「url,{json}」请求选项，七猫发现列表 qmGetUrl 生成；
            //    经 AnalyzeUrl 解析出 url/method/headers 再请求，直接 GET 会 401/404）
            let analyze_book = legado_parser::AnalyzeUrl::parse(
                book_url,
                &std::collections::HashMap::new(),
                1,
            )
            .map_err(|e| LegadoError::Internal(format!("bookUrl 解析失败: {e}")))?;
            let info_body = self
                .fetch_url(&analyze_book, source_headers.as_ref())
                .await?;
            eprintln!(
                "[web_book] get_chapters info_body in {:?}",
                t0.elapsed()
            );

            // 1.5 loginCheckJs 登录检测
            Self::execute_login_check(source, &info_body, book_url, 200)?;

            let mut info_analyzer = crate::js_executor::construct_analyzer_with_source_context(
                info_body.clone(),
                book_url.to_string(),
                &source.book_source_url,
                js_lib_sanitized.as_deref(),
                crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
            );

            // 1.6 详情页 init（对齐原版 analyzeBookInfo：init 结果 setContent 后
            // 再解析字段；书山聚合 init 把 data:URI hex detail JSON 转为
            // /details 响应，tocUrl 规则依赖其中的 source/book_url/title）
            if let Some(init_rule) = info_rule.and_then(|r| r.init.as_deref()) {
                let init_rule = init_rule.trim();
                if !init_rule.is_empty() {
                    if let Ok(init_result) = info_analyzer.get_string(init_rule) {
                        if !init_result.is_empty() {
                            info_analyzer.set_element_content(init_result);
                        }
                    }
                }
            }

            let raw_toc = info_rule
                .and_then(|r| r.toc_url.as_deref())
                .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
                .unwrap_or_default();

            // 书名（供目录规则 `<js>` 中 `book.name` 使用，对齐原版
            // AnalyzeRule.evalJS 注入 book 绑定；51漫画等目录规则依赖）— Reasonix
            if book_name.is_empty() {
                book_name = info_rule
                    .and_then(|r| r.name.as_deref())
                    .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
                    .unwrap_or_default()
                    .lines()
                    .map(str::trim)
                    .find(|s| !s.is_empty())
                    .unwrap_or("")
                    .to_string();
            }
            let toc_url = if raw_toc.is_empty() {
                book_url.to_string()
            } else {
                AnalyzeUrl::get_absolute_url(book_url, &raw_toc)
            };

            // 2. B3.1 tocHtml 缓存复用：当 tocUrl == bookUrl 时复用详情页响应体，避免重复请求
            let toc_body = if toc_url == book_url {
                info_body
            } else {
                // 同 known-tocUrl 路径：tocUrl 可能带「url,{json}」请求选项（七猫），
                // 经 AnalyzeUrl 解析出 url/method/headers 再请求
                let analyze_toc = legado_parser::AnalyzeUrl::parse(
                    &toc_url,
                    &std::collections::HashMap::new(),
                    1,
                )
                .map_err(|e| {
                    LegadoError::Internal(format!("tocUrl 解析失败: {e}"))
                })?;
                self.fetch_url(&analyze_toc, source_headers.as_ref())
                    .await?
            };
            (toc_url, toc_body)
        };

        // 3. B3.4 反转标记：chapterList 规则以 "-" 前缀表示倒序，"+" 前缀仅为标记（对标 Kotlin BookChapterList）
        let toc_rule = source.rule_toc.as_ref();
        let raw_list_rule = toc_rule
            .and_then(|r| r.chapter_list.as_deref())
            .unwrap_or("");
        let mut reverse = false;
        let mut chapter_list_rule = raw_list_rule;
        if let Some(stripped) = chapter_list_rule.strip_prefix('-') {
            reverse = true;
            chapter_list_rule = stripped;
        }
        if let Some(stripped) = chapter_list_rule.strip_prefix('+') {
            chapter_list_rule = stripped;
        }

        let analyzer = crate::js_executor::construct_analyzer_with_source_context(
            toc_body,
            toc_url.clone(),
            &source.book_source_url,
            js_lib_sanitized.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        )
        .with_js_binding(
            "book",
            &serde_json::json!({ "name": book_name }).to_string(),
        );

        let t_list = std::time::Instant::now();
        let elements = if chapter_list_rule.is_empty() {
            vec![analyzer.content().to_string()]
        } else {
            // 勿 unwrap_or_default：规则失败（JS/JSONPath）被吞成空列表后，
            // refresh_toc 只能报「未解析到任何章节」，掩盖真实引擎错误
            // （51漫画 `<js>+$[*]` 链拆解回归）。— Reasonix
            analyzer.get_elements(chapter_list_rule)?
        };
        eprintln!(
            "[web_book] get_chapters elements={} in {:?}",
            elements.len(),
            t_list.elapsed()
        );

        // 规则提到循环外
        let name_rule = toc_rule
            .and_then(|r| r.chapter_name.as_deref())
            .unwrap_or("");
        let url_rule = toc_rule
            .and_then(|r| r.chapter_url.as_deref())
            .unwrap_or("");
        let vip_rule = toc_rule.and_then(|r| r.is_vip.as_deref()).unwrap_or("");
        let volume_rule = toc_rule.and_then(|r| r.is_volume.as_deref()).unwrap_or("");

        // 对齐原版 BookChapterList：单一 AnalyzeRule + setContent(item) 循环，
        // 复用 stringRuleCache / JsExecutor，避免每章新建解析器（数百章时差一个数量级）。
        let mut elem_analyzer =
            crate::js_executor::construct_analyzer_with_source_context(
                String::new(),
                toc_url.clone(),
                &source.book_source_url,
                js_lib_sanitized.as_deref(),
                crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
            );

        let t_parse = std::time::Instant::now();
        let mut chapters = Vec::with_capacity(elements.len());
        for (index, elem) in elements.iter().enumerate() {
            elem_analyzer.clear_variables();
            elem_analyzer.set_element_content(elem.clone());

            let mut title = elem_analyzer.get_string(name_rule).unwrap_or_default();
            let raw_url_probe = elem_analyzer.get_string(url_rule).unwrap_or_default();
            // 对齐原版 BookChapterList：空标题仍保留；仅标题与 URL 皆空时跳过。
            if title.is_empty() && raw_url_probe.is_empty() {
                continue;
            }
            if title.is_empty() {
                title = "无标题".to_string();
            }

            let is_vip = if vip_rule.is_empty() {
                false
            } else {
                let v = elem_analyzer.get_string(vip_rule).unwrap_or_default();
                v == "true" || v == "1"
            };

            // B3.2 isVolume 标记（卷章）
            let is_volume = if volume_rule.is_empty() {
                false
            } else {
                let v = elem_analyzer.get_string(volume_rule).unwrap_or_default();
                v == "true" || v == "1"
            };

            // B3.3 空 URL 回退 + 绝对化（对标 Kotlin BookChapterList）
            //    - 卷章 url 空：用 `title + index` 替代（合成唯一标识，不绝对化）
            //    - 普通章 url 空：回退 baseUrl（目录页 url）
            //    - 非空 url：基于 toc_url 绝对化
            let raw_url = raw_url_probe;
            let url = if raw_url.is_empty() {
                if is_volume {
                    format!("{}{}", title, index)
                } else {
                    toc_url.clone()
                }
            } else {
                AnalyzeUrl::get_absolute_url(&toc_url, &raw_url)
            };

            // @put 变量写入章节（对齐 BookChapter.putVariable → variable JSON）
            let variable = elem_analyzer.export_variables_json();

            chapters.push(WebChapter {
                index: index as i32,
                title,
                url,
                is_vip,
                is_volume,
                variable,
            });
        }
        eprintln!(
            "[web_book] get_chapters parse {} chapters in {:?} (total {:?})",
            chapters.len(),
            t_parse.elapsed(),
            t0.elapsed()
        );

        // B3.5 nextTocUrl 分页（对标 Kotlin BookChapterList）：
        // - 0：无分页
        // - 1：串行跟下一页（每页再取 next）
        // - >1：并发拉取各分页（思路客等 JS 展开全部分页 URL）
        let next_toc_rule = toc_rule
            .and_then(|r| r.next_toc_url.as_deref())
            .unwrap_or("")
            .trim();
        if !next_toc_rule.is_empty() {
            let t_next = std::time::Instant::now();
            let mut next_urls: Vec<String> = analyzer
                .get_strings_ex(next_toc_rule, true)
                .unwrap_or_default()
                .into_iter()
                .filter(|u| !u.is_empty() && u != &toc_url)
                .collect();
            // 去重保序
            {
                let mut seen = std::collections::HashSet::new();
                next_urls.retain(|u| seen.insert(u.clone()));
            }
            eprintln!(
                "[web_book] get_chapters nextTocUrl pages={} in {:?}",
                next_urls.len(),
                t_next.elapsed()
            );

            if next_urls.len() == 1 {
                let mut visited = std::collections::HashSet::new();
                visited.insert(toc_url.clone());
                let mut next_url = next_urls.remove(0);
                while !next_url.is_empty() && visited.insert(next_url.clone()) {
                    let page_body = self
                        .fetch_simple_cached(&next_url, source_headers.as_ref(), true)
                        .await?;
                    let page_analyzer =
                        crate::js_executor::construct_analyzer_with_source_context(
                            page_body,
                            next_url.clone(),
                            &source.book_source_url,
                            js_lib_sanitized.as_deref(),
                            crate::api::source_js_bindings::book_source_js_setup_script(source)
                                .ok(),
                        );
                    let page_elements = if chapter_list_rule.is_empty() {
                        vec![page_analyzer.content().to_string()]
                    } else {
                        page_analyzer
                            .get_elements(chapter_list_rule)
                            .unwrap_or_default()
                    };
                    let base = next_url.clone();
                    let start_idx = chapters.len();
                    for (i, elem) in page_elements.iter().enumerate() {
                        elem_analyzer.clear_variables();
                        elem_analyzer.set_base_url(base.clone());
                        elem_analyzer.set_element_content(elem.clone());
                        let mut title =
                            elem_analyzer.get_string(name_rule).unwrap_or_default();
                        let raw_url_probe =
                            elem_analyzer.get_string(url_rule).unwrap_or_default();
                        if title.is_empty() && raw_url_probe.is_empty() {
                            continue;
                        }
                        if title.is_empty() {
                            title = "无标题".to_string();
                        }
                        let is_vip = if vip_rule.is_empty() {
                            false
                        } else {
                            let v = elem_analyzer.get_string(vip_rule).unwrap_or_default();
                            v == "true" || v == "1"
                        };
                        let is_volume = if volume_rule.is_empty() {
                            false
                        } else {
                            let v = elem_analyzer.get_string(volume_rule).unwrap_or_default();
                            v == "true" || v == "1"
                        };
                        let index = start_idx + i;
                        let url = if raw_url_probe.is_empty() {
                            if is_volume {
                                format!("{}{}", title, index)
                            } else {
                                base.clone()
                            }
                        } else {
                            AnalyzeUrl::get_absolute_url(&base, &raw_url_probe)
                        };
                        chapters.push(WebChapter {
                            index: index as i32,
                            title,
                            url,
                            is_vip,
                            is_volume,
                            variable: elem_analyzer.export_variables_json(),
                        });
                    }
                    let more = page_analyzer
                        .get_strings_ex(next_toc_rule, true)
                        .unwrap_or_default();
                    next_url = more
                        .into_iter()
                        .find(|u| !u.is_empty() && !visited.contains(u))
                        .unwrap_or_default();
                }
            } else if next_urls.len() > 1 {
                // 并发拉页（对齐 mapAsync(threadCount)）
                let headers = source_headers.clone();
                let source_url = source.book_source_url.clone();
                let js_lib = source.js_lib.clone();
                let list_rule = chapter_list_rule.to_string();
                let name_r = name_rule.to_string();
                let url_r = url_rule.to_string();
                let vip_r = vip_rule.to_string();
                let volume_r = volume_rule.to_string();
                let client = self.client.clone();

                let futs: Vec<_> = next_urls
                    .into_iter()
                    .map(|page_url| {
                        let headers = headers.clone();
                        let source_url = source_url.clone();
                        let js_lib = js_lib.clone();
                        let list_rule = list_rule.clone();
                        let name_r = name_r.clone();
                        let url_r = url_r.clone();
                        let vip_r = vip_r.clone();
                        let volume_r = volume_r.clone();
                        let client = client.clone();
                        async move {
                            let body = {
                                if let Some(cached) = cache_get_page_body(&page_url) {
                                    cached
                                } else {
                                    let response = client.get(&page_url, headers).await?;
                                    if !response.is_success() {
                                        return Err(LegadoError::Network(format!(
                                            "HTTP {} for {}",
                                            response.status, page_url
                                        )));
                                    }
                                    cache_put_page_body(&page_url, &response.body);
                                    response.body
                                }
                            };
                            let page_analyzer =
                                crate::js_executor::construct_analyzer_with_js_lib(
                                    body,
                                    page_url.clone(),
                                    &source_url,
                                    js_lib.as_deref(),
                                );
                            let page_elements = if list_rule.is_empty() {
                                vec![page_analyzer.content().to_string()]
                            } else {
                                page_analyzer.get_elements(&list_rule).unwrap_or_default()
                            };
                            let mut elem = crate::js_executor::construct_analyzer_with_js_lib(
                                String::new(),
                                page_url.clone(),
                                &source_url,
                                js_lib.as_deref(),
                            );
                            let mut page_chs = Vec::with_capacity(page_elements.len());
                            for (i, el) in page_elements.iter().enumerate() {
                                elem.clear_variables();
                                elem.set_element_content(el.clone());
                                let mut title = elem.get_string(&name_r).unwrap_or_default();
                                let raw = elem.get_string(&url_r).unwrap_or_default();
                                if title.is_empty() && raw.is_empty() {
                                    continue;
                                }
                                if title.is_empty() {
                                    title = "无标题".to_string();
                                }
                                let is_vip = if vip_r.is_empty() {
                                    false
                                } else {
                                    let v = elem.get_string(&vip_r).unwrap_or_default();
                                    v == "true" || v == "1"
                                };
                                let is_volume = if volume_r.is_empty() {
                                    false
                                } else {
                                    let v = elem.get_string(&volume_r).unwrap_or_default();
                                    v == "true" || v == "1"
                                };
                                let url = if raw.is_empty() {
                                    if is_volume {
                                        format!("{}{}", title, i)
                                    } else {
                                        page_url.clone()
                                    }
                                } else {
                                    AnalyzeUrl::get_absolute_url(&page_url, &raw)
                                };
                                page_chs.push(WebChapter {
                                    index: i as i32,
                                    title,
                                    url,
                                    is_vip,
                                    is_volume,
                                    variable: elem.export_variables_json(),
                                });
                            }
                            Ok::<_, LegadoError>(page_chs)
                        }
                    })
                    .collect();
                let all = futures::future::join_all(futs).await;
                for page in all {
                    match page {
                        Ok(chs) => chapters.extend(chs),
                        Err(e) => eprintln!("[web_book] toc page fetch failed: {e}"),
                    }
                }
            }
            eprintln!(
                "[web_book] get_chapters after nextTocUrl total_chapters={} in {:?}",
                chapters.len(),
                t0.elapsed()
            );
        }

        // 重编号
        for (i, ch) in chapters.iter_mut().enumerate() {
            ch.index = i as i32;
        }

        // B3.4 去重 + 反转管线（对标 Kotlin BookChapterList 双反转去重逻辑，去重键为 url）
        let mut chapters = if reverse {
            // "-" 前缀：先去重（保留首次），再反转
            let mut deduped = dedupe_first_by_url(chapters);
            deduped.reverse();
            deduped
        } else {
            // 默认：等价于 Kotlin reverse→去重→reverse，即去重保留最后一次出现、保持原顺序
            dedupe_last_by_url(chapters)
        };

        // B3.5 formatJs 标题格式化（对齐 Kotlin BookChapterList.analyzeChapterList：
        //      对每章以 bindings {index(1-based)/title/chapter/gInt=0} eval(formatJs)，
        //      结果改写 bookChapter.title）
        let format_js = toc_rule
            .and_then(|r| r.format_js.as_deref())
            .unwrap_or("")
            .trim();
        if !format_js.is_empty() && !chapters.is_empty() {
            for (i, ch) in chapters.iter_mut().enumerate() {
                let chapter_json =
                    serde_json::to_string(&*ch).unwrap_or_else(|_| "{}".to_string());
                let title_json = serde_json::to_string(&ch.title)
                    .unwrap_or_else(|_| "\"\"".to_string());
                let index_json = serde_json::to_string(&(i as i32 + 1)).unwrap();
                let mut fa = crate::js_executor::construct_analyzer_with_js_lib(
                    String::new(),
                    toc_url.clone(),
                    &source.book_source_url,
                    js_lib_sanitized.as_deref(),
                );
                fa.add_js_binding("index", &index_json);
                fa.add_js_binding("title", &title_json);
                fa.add_js_binding("chapter", &chapter_json);
                fa.add_js_binding("gInt", "0");
                let new_title = fa
                    .get_string(&format!("@js:{format_js}"))
                    .unwrap_or_default();
                if !new_title.is_empty() {
                    ch.title = new_title;
                }
            }
        }

        Ok(chapters)
    }
}

/// 推断 book.totalChapterNum（神漫画等内容 JS 依赖）
///
/// 优先从正文 JSON 的 `data.comic_chapter` 对象/数组长度推断；
/// 否则退回 `chapter.index + 1`。
fn infer_total_chapter_num(body: &str, chapter: &WebChapter) -> i32 {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
        if let Some(cc) = v.pointer("/data/comic_chapter") {
            if let Some(obj) = cc.as_object() {
                return obj.len() as i32;
            }
            if let Some(arr) = cc.as_array() {
                return arr.len() as i32;
            }
        }
    }
    chapter.index.saturating_add(1)
}

/// 抓取结果：响应体 + 最终 URL（对标 Kotlin `StrResponse.body` / `StrResponse.url`）
struct FetchedPage {
    body: String,
    final_url: String,
}

/// 对齐 Kotlin `WebBook.checkRedirect`：请求 URL 与最终 URL 不同时打日志
fn check_redirect_log(request_url: &str, final_url: &str) {
    if final_url.is_empty() || request_url == final_url {
        return;
    }
    // 对齐 Kotlin WebBook.checkRedirect → Debug.log
    eprintln!("[WebBook] ≡检测到重定向");
    eprintln!("[WebBook] ┌重定向后地址");
    eprintln!("[WebBook] └{final_url}");
}

/// 正文抓取后 webJs / sourceRegex 钩子
///
/// 对齐原版 `AnalyzeUrl.getStrResponseAwait(jsStr=webJs, sourceRegex=…)`：
/// - `sourceRegex`：无头嗅探 HTML/正文中匹配的 URL（近似 `SnifferWebClient.onLoadResource`）；
///   Flutter 已订阅时优先 DOM 嗅探（`webViewGetSource`）
/// - `webJs`：优先 DOM 通道（BackstageWebView）；失败回退无头 `@js:`
fn apply_content_web_hooks(
    body: String,
    content_rule: Option<&legado_core::models::rule::ContentRule>,
    page_url: &str,
    source_url: &str,
    js_lib: Option<&str>,
) -> String {
    let source_regex = content_rule
        .and_then(|r| r.source_regex.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let web_js = content_rule
        .and_then(|r| r.web_js.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty());

    if source_regex.is_none() && web_js.is_none() {
        return body;
    }

    // sourceRegex：DOM 嗅探优先，否则无头 URL 扫描
    if let Some(re_str) = source_regex {
        if legado_core::webview_channel::has_subscribers() {
            let req = legado_core::webview_channel::WebViewRequest {
                key: String::new(),
                action: "webViewGetSource".into(),
                html: body.clone(),
                url: page_url.to_string(),
                js: String::new(),
                source_regex: re_str.to_string(),
                override_url_regex: String::new(),
                cache_first: false,
                delay_time: 0,
                is_rule: false,
                result: String::new(),
                created_at_ms: 0,
            };
            if let Ok(hit) = legado_core::webview_channel::request_and_wait(
                req,
                legado_core::webview_channel::DEFAULT_WEBVIEW_TIMEOUT,
            ) {
                if !hit.trim().is_empty() && !hit.starts_with("[ERROR]") {
                    return hit;
                }
            }
        }
        if let Some(hit) = sniff_source_regex_url(&body, re_str) {
            return hit;
        }
    }

    // webJs：DOM 优先（对齐 AnalyzeUrl + BackstageWebView），再无头 QuickJS
    if let Some(js) = web_js {
        if legado_core::webview_channel::has_subscribers() {
            let req = legado_core::webview_channel::WebViewRequest {
                key: String::new(),
                action: "webView".into(),
                html: body.clone(),
                url: page_url.to_string(),
                js: js.to_string(),
                source_regex: String::new(),
                override_url_regex: String::new(),
                cache_first: false,
                delay_time: 0,
                is_rule: false,
                result: String::new(),
                created_at_ms: 0,
            };
            if let Ok(out) = legado_core::webview_channel::request_and_wait(
                req,
                legado_core::webview_channel::DEFAULT_WEBVIEW_TIMEOUT,
            ) {
                if !out.trim().is_empty() && !out.starts_with("[ERROR]") {
                    return out;
                }
            }
        }
        let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
            body.clone(),
            page_url.to_string(),
            source_url,
            js_lib,
        );
        match analyzer.get_string(&format!("@js:{js}")) {
            Ok(out) if !out.trim().is_empty() => return out,
            Ok(_) => {}
            Err(e) => eprintln!("[web_book] contentRule.webJs 执行失败（回退原文）: {e}"),
        }
    }

    body
}

/// 从 HTML/文本中嗅探匹配 sourceRegex 的 URL
fn sniff_source_regex_url(body: &str, source_regex: &str) -> Option<String> {
    let re = regex::Regex::new(source_regex).ok()?;
    // 1) 整段 body 即 URL
    let trimmed = body.trim();
    if !trimmed.contains('<') && re.is_match(trimmed) {
        return Some(trimmed.to_string());
    }
    // 2) 引号内 URL / src|href 属性
    let url_re =
        regex::Regex::new(r#"(?i)(?:src|href|url)\s*=\s*["']([^"']+)["']|["'](https?://[^"']+)["']"#)
            .ok()?;
    for cap in url_re.captures_iter(body) {
        let candidate = cap
            .get(1)
            .or_else(|| cap.get(2))
            .map(|m| m.as_str())
            .unwrap_or("");
        if !candidate.is_empty() && re.is_match(candidate) {
            return Some(candidate.to_string());
        }
    }
    // 3) 裸 http(s) 子串
    let bare = regex::Regex::new(r#"https?://[^\s"'<>]+"#).ok()?;
    for m in bare.find_iter(body) {
        let u = m.as_str().trim_end_matches([')', ']', ',', ';']);
        if re.is_match(u) {
            return Some(u.to_string());
        }
    }
    None
}

/// 构建 WebBookEngine（使用真实 HTTP + 规则解析实现）
pub fn build_engine() -> LegadoResult<WebBookEngine<RealBookSourceFetcher>> {
    Ok(WebBookEngine::new(RealBookSourceFetcher::new()?))
}

/// 缺口① nextContentUrl 分页最大页数保护（审计 2026-08-06，加法式）
///
/// Kotlin 原版无显式上限（依赖 nextUrl 重复/空终止），
/// Rust 轨加法式加固以防恶意/异常规则导致死循环。
const MAX_CONTENT_PAGES: usize = 99;

/// 解析单页正文，返回（净化后正文，下一页 URL 列表）
///
/// 缺口① nextContentUrl 分页（审计 2026-08-06，加法式）：
/// 对标 Kotlin `BookContent.analyzeContent`（私有重载）单页处理：
/// - 正文规则提取 + HtmlFormatter 净化管线（音视频源跳过格式化）
/// - next_url_rule 非空时解析下一页 URL 列表（对标 Kotlin
///   `analyzeRule.getStringList(nextUrlRule, isUrl = true)`），并基于本页 URL 绝对化
/// 无 jsLib 版本（测试与旧调用兼容；生产正文解析走
/// [`parse_content_page_with_js_lib`] 注入书源 jsLib）
#[cfg(test)]
fn parse_content_page(
    body: String,
    content_rule_str: &str,
    next_url_rule: &str,
    page_url: &str,
    source_url: &str,
    is_media: bool,
) -> (String, Vec<String>) {
    parse_content_page_with_js_lib(
        body,
        content_rule_str,
        next_url_rule,
        page_url,
        source_url,
        is_media,
        None,
        None,
    )
}

/// [UI-fix 2026-08-10 | Reasonix] 正文解析注入书源 jsLib：漫画/视频/音频源
/// ruleContent 常以 `<js>`/`@js:` 引用 jsLib 定义的函数（Reload/getHosts 等），
/// 此前不注入 → 正文 JS 抛错 → 正文为空（「搜到书但正文图片不显示/无法播放」）。
#[cfg(test)]
fn parse_content_page_with_js_lib(
    body: String,
    content_rule_str: &str,
    next_url_rule: &str,
    page_url: &str,
    _source_url: &str,
    is_media: bool,
    js_lib: Option<&str>,
    chapter_title: Option<&str>,
) -> (String, Vec<String>) {
    parse_content_page_with_bindings(
        body,
        content_rule_str,
        next_url_rule,
        page_url,
        None,
        is_media,
        js_lib,
        None, // setup_script：测试/旧调用无书源上下文
        chapter_title,
        None,
        None,
        None,
    )
}

/// 正文解析（可注入 chapter.index / book.totalChapterNum）
///
/// 神漫画等内容规则依赖：
/// `index=parseInt(chapter.index); num=parseInt(book.totalChapterNum);`
/// 此前仅注入 title → ReferenceError/NaN → 正文空。— Reasonix
#[allow(clippy::too_many_arguments)] // 分页解析参数集与 Kotlin analyzeContent 对齐，暂不拆结构体
fn parse_content_page_with_bindings(
    body: String,
    content_rule_str: &str,
    next_url_rule: &str,
    page_url: &str,
    source: Option<&BookSource>,
    is_media: bool,
    js_lib: Option<&str>,
    setup_script: Option<String>,
    chapter_title: Option<&str>,
    chapter_index: Option<i32>,
    book_total_chapter_num: Option<i32>,
    chapter_variable_json: Option<&str>,
) -> (String, Vec<String>) {
    // 书山等聚合源正文规则依赖书源上下文（getSecretKey → source.getLoginHeader、
    // getServerHost/deviceType → jsLib）与 header 规则注入（java.ajax 携带
    // X-Novel-Token/X-Api-Key）；construct_analyzer_with_js_lib 仅有 jsLib 无
    // setup → source 绑定为 URL 字符串 → getSecretKey 取不到 loginHeader →
    // X-Api-Key 空 → 正文密文。— 书山正文修复（2026-08-17）
    let js_lib_sanitized = js_lib
        .map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
    let mut analyzer = if let Some(src) = source {
        crate::js_executor::construct_analyzer_with_source_context(
            body,
            page_url.to_string(),
            &src.book_source_url,
            js_lib_sanitized.as_deref(),
            setup_script,
        )
    } else {
        // 无书源上下文（测试/分页降级）：退回旧行为（仅 jsLib）
        crate::js_executor::construct_analyzer_with_js_lib(
            body,
            page_url.to_string(),
            "",
            js_lib_sanitized.as_deref(),
        )
    };
    // 注入原版 evalJS bindings：chapter/title/book（result/src/baseUrl 由
    // AnalyzeRule.execute_js_rule 自动注入）——漫画/视频书源正文 JS 依赖这些变量
    // （如 `chapter.title`、`chapter.index`、`book.totalChapterNum`）。
    let title = chapter_title.unwrap_or("");
    let t_json = serde_json::to_string(title).unwrap_or_else(|_| "\"\"".to_string());
    let idx = chapter_index.unwrap_or(0);
    analyzer = analyzer
        .with_js_binding(
            "chapter",
            &format!("{{\"title\": {t_json}, \"index\": {idx}}}"),
        )
        .with_js_binding("title", &t_json);
    let total = book_total_chapter_num.unwrap_or(0);
    analyzer = analyzer.with_js_binding(
        "book",
        &format!("{{\"totalChapterNum\": {total}, \"name\": \"\"}}"),
    );
    // 种子章节 @put 变量（对齐 AnalyzeRule.setChapter → getVariable）
    if let Some(vars) = chapter_variable_json {
        analyzer.seed_variables_json(vars);
    }

    let raw_content = if content_rule_str.is_empty() {
        analyzer.content().to_string()
    } else {
        analyzer.get_string(content_rule_str).unwrap_or_default()
    };

    // 正文净化管线（对标 Kotlin BookContent.analyzeContent）
    let content = if is_media {
        // 视频/音频：跳过 HTML 净化（MPD XML 以 `<` 开头，format_keep_img 会剥标签破坏清单）。
        // 轻量接通 VideoPlayerState::normalize_content：空正文对齐 ContentEmptyException；
        // Url vs Mpd 分类仍返回原文 String（保持 FFI 契约），UI 播放前应再调
        // `VideoPlayerState::normalize_content` / `is_mpd_content` 写临时文件；
        // 相对 URL 绝对化由 UI 轨处理（本处不改视频卷/弹幕核心）。
        match legado_core::video_state::VideoPlayerState::normalize_content(&raw_content) {
            None => String::new(),
            Some(legado_core::video_state::VideoContent::Mpd(_))
            | Some(legado_core::video_state::VideoContent::Url(_)) => raw_content,
        }
    } else {
        // HtmlFormatter.formatKeepImg（保留 img 标签 + 按本页 URL 绝对化）
        let cleaned = legado_core::html_formatter::format_keep_img(&raw_content, page_url);
        // unescapeHtml4（实体反转义）
        legado_core::html_formatter::unescape_html4(&cleaned)
    };

    // 解析下一页 URL 规则
    let next_urls = if next_url_rule.is_empty() {
        Vec::new()
    } else {
        analyzer
            .get_strings(next_url_rule)
            .unwrap_or_default()
            .into_iter()
            .map(|u| u.trim().to_string())
            .filter(|u| !u.is_empty())
            .map(|u| AnalyzeUrl::get_absolute_url(page_url, &u))
            .collect()
    };

    (content, next_urls)
}

/// nextContentUrl 分页循环（抓取后续页并按页拼接）
///
/// 缺口① nextContentUrl 分页（审计 2026-08-06，加法式），对标 Kotlin
/// `BookContent.analyzeContent` 分页循环：
/// - 单个下一页 URL：串行循环直到为空/重复（对标 `while (nextUrl.isNotEmpty()
///   && !nextUrlList.contains(nextUrl))`）
/// - 多个下一页 URL：逐页抓取且不再继续分页（对标原版并发分支
///   `getNextPageUrl = false`，此处降级串行）
/// - 防死循环保护：已访问 URL 去重（含首章 URL）+ 最大页数上限
///
/// `fetch_page` 可注入，便于单测以脚本化响应验证多页拼接（不走真实网络）。
#[allow(clippy::too_many_arguments)] // 分页抓取参数集与正文解析链对齐，暂不拆结构体
async fn fetch_paginated_content<F, Fut>(
    first_content: String,
    next_urls: Vec<String>,
    chapter_url: &str,
    _source_url: &str,
    content_rule_str: &str,
    next_url_rule: &str,
    is_media: bool,
    js_lib: Option<&str>,
    setup_script: Option<String>,
    chapter_title: Option<&str>,
    chapter_index: Option<i32>,
    book_total_chapter_num: Option<i32>,
    chapter_variable_json: Option<&str>,
    mut fetch_page: F,
) -> String
where
    F: FnMut(String) -> Fut,
    Fut: std::future::Future<Output = LegadoResult<String>>,
{
    let mut content_list = vec![first_content];

    if !next_url_rule.is_empty() && !next_urls.is_empty() {
        let mut visited = std::collections::HashSet::new();
        visited.insert(chapter_url.to_string());

        if next_urls.len() > 1 {
            // 对标 Kotlin `contentData.second.size > 1` 分支：仅解析正文，不递归分页
            for raw_url in next_urls {
                if content_list.len() >= MAX_CONTENT_PAGES {
                    break;
                }
                if !visited.insert(raw_url.clone()) {
                    continue;
                }
                match fetch_page(raw_url.clone()).await {
                    Ok(next_body) => {
                        let (page_content, _) = parse_content_page_with_bindings(
                            next_body,
                            content_rule_str,
                            "", // getNextPageUrl = false
                            &raw_url,
                            None,
                            is_media,
                            js_lib,
                            setup_script.clone(),
                            chapter_title,
                            chapter_index,
                            book_total_chapter_num,
                            chapter_variable_json,
                        );
                        content_list.push(page_content);
                    }
                    Err(e) => {
                        eprintln!("[web_book] 分页正文抓取失败 {raw_url}: {e}");
                    }
                }
            }
        } else {
            let mut next_url = next_urls.into_iter().next().unwrap_or_default();
            while !next_url.is_empty()
                && visited.insert(next_url.clone())
                && content_list.len() < MAX_CONTENT_PAGES
            {
                let next_body = match fetch_page(next_url.clone()).await {
                    Ok(b) => b,
                    Err(e) => {
                        eprintln!("[web_book] 分页正文抓取失败 {next_url}: {e}");
                        break;
                    }
                };
                let (page_content, following) = parse_content_page_with_bindings(
                    next_body,
                    content_rule_str,
                    next_url_rule,
                    &next_url,
                    None,
                    is_media,
                    js_lib,
                    setup_script.clone(),
                    chapter_title,
                    chapter_index,
                    book_total_chapter_num,
                    chapter_variable_json,
                );
                content_list.push(page_content);
                // 仅在获得单个下一页时继续串行（对标 Kotlin size==1 分支）；
                // 命中下一章 URL 的截断判定因无状态签名不可得 nextChapterUrl，
                // 由 URL 去重与页数上限兜底
                next_url = if following.len() == 1 {
                    following.into_iter().next().unwrap_or_default()
                } else {
                    String::new()
                };
            }
        }
    }

    // 按页拼接（对标 Kotlin `contentList.joinToString("\n")`）
    content_list.join("\n")
}

// ─── R1 subContent 副内容（Task #134） ──────────────────────────────────────

/// R1 副内容提取与二次请求（Task #134）
///
/// 对标 Kotlin `BookContent.kt` L128-165 的 subContent 处理：
/// - 在首页 analyzer 上以 subContent 规则提取原始副内容
///   （对标 `analyzeRule.getString(subContentRule)`）；
/// - 提取结果 trim 后以 http 开头（不区分大小写，对标
///   `it.startsWith("http", true)`）：发起二次 HTTP 请求取响应体作为副内容；
/// - 否则直接以规则提取结果作为副内容。
/// - 对标 Kotlin `runCatching`：任何失败仅记日志，不影响主正文返回。
///
/// 对齐差异说明：提取逻辑对齐原版；是否拼进正文由调用方按 `is_media`
/// 决定（见 [merge_sub_content_into_body]）。另原版 isOnLineTxt 跳过 http
/// 二次请求，此处统一执行二次请求判定。
async fn fetch_sub_content<F, Fut>(
    page_body: String,
    sub_rule: &str,
    page_url: &str,
    source_url: &str,
    js_lib: Option<&str>,
    fetch: F,
) -> Option<String>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = LegadoResult<String>>,
{
    let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
        page_body,
        page_url.to_string(),
        source_url,
        js_lib,
    );
    let raw = match eval_rule_string(&analyzer, sub_rule) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[web_book] subContent 规则解析失败（已忽略）: {e}");
            return None;
        }
    };
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if raw.to_ascii_lowercase().starts_with("http") {
        // 对标 Kotlin AnalyzeUrl(mUrl = it).getStrResponseAwait().body
        match fetch(raw.to_string()).await {
            Ok(body) => Some(body),
            Err(e) => {
                eprintln!("[web_book] subContent 二次请求失败（已忽略）: {e}");
                None
            }
        }
    } else {
        Some(raw.to_string())
    }
}

/// 副内容是否写入正文（对标 BookContent.kt L128-165）
///
/// - 文本：拼进 contentList（此处简化为追加）
/// - 音频/视频：原版 putLyric / putDanmaku，**禁止**拼进播放链接正文
fn merge_sub_content_into_body(content: &mut String, sub: &str, is_media: bool) {
    if is_media || sub.is_empty() {
        return;
    }
    content.push('\n');
    content.push_str(sub);
}

// ─── R2 replaceRegex 全文替换（Task #134） ──────────────────────────────────

/// R2 正文全文替换（Task #134），对标 Kotlin `BookContent.kt` L166-175：
/// 1. replaceRegex 非空时先按换行拆分、逐行 trim 再拼回
///    （对标 `contentStr.split(AppPattern.LFRegex).joinToString("\n") { it.trim() }`）；
/// 2. 以拼接后正文为内容执行替换规则
///    （对标 `analyzeRule.getString(replaceRegex, contentStr)`）。
///
/// 对齐差异说明：原版 isOnLineTxt 书籍替换后每行前缀全角空格缩进
/// （`"　　$it"`），Rust 侧 FFI 无状态签名无书籍类型上下文，未实现该缩进。
fn apply_content_replace_regex(
    content: String,
    replace_regex: &str,
    base_url: &str,
    source_url: &str,
    js_lib: Option<&str>,
) -> LegadoResult<String> {
    let trimmed = content
        .split('\n')
        .map(|line| line.trim())
        .collect::<Vec<_>>()
        .join("\n");
    let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
        trimmed,
        base_url.to_string(),
        source_url,
        js_lib,
    );
    eval_rule_string(&analyzer, replace_regex)
}

/// 拆分 Kotlin SourceRule 的 `##` 替换语法（对标 AnalyzeRule.makeUpRule L819-829）：
/// `rule##replaceRegex##replacement##第四段(仅存在即置 replaceFirst=true)`。
/// 返回（基础规则，可选替换三元组）。
pub(crate) fn split_rule_replace_parts(rule: &str) -> (&str, Option<(&str, &str, bool)>) {
    let parts: Vec<&str> = rule.split("##").collect();
    let base = parts.first().copied().unwrap_or("").trim();
    if parts.len() <= 1 {
        return (base, None);
    }
    let pattern = parts.get(1).copied().unwrap_or("");
    let replacement = parts.get(2).copied().unwrap_or("");
    let replace_first = parts.len() > 3;
    (base, Some((pattern, replacement, replace_first)))
}

/// 执行规则字符串并应用 `##` 替换部分
///
/// 对标 Kotlin `AnalyzeRule.getString` + `SourceRule.replaceRegex` 组合语义：
/// - 基础规则为空：直接以当前内容为替换对象（replaceRegex 纯替换规则场景）；
/// - 基础规则非空：先按规则提取，再对提取结果应用替换；
/// - 替换部分：`apply_regex_replace`（对标 AnalyzeRule.replaceRegex L539-563）。
pub(crate) fn eval_rule_string(analyzer: &legado_parser::AnalyzeRule, rule: &str) -> LegadoResult<String> {
    let (base_rule, replace) = split_rule_replace_parts(rule);
    let mut result = if base_rule.is_empty() {
        analyzer.content().to_string()
    } else {
        analyzer.get_string(base_rule)?
    };
    if let Some((pattern, replacement, replace_first)) = replace {
        result = apply_regex_replace(&result, pattern, replacement, replace_first);
    }
    Ok(result)
}

/// 正则替换（对标 Kotlin `AnalyzeRule.replaceRegex` L539-563）：
/// - replaceFirst 分支（`##match##replace##第四段`）：仅取首个匹配段文本做替换后返回
///   （对标 `matcher.group(0).replaceFirst(regex, replacement)`，无匹配返回空串）；
/// - 全文替换分支：`result.replace(regex, replacement)`，replacement 支持 `$1` 捕获组引用；
/// - 正则非法/编译失败（含病态 pattern 栈溢出防护 compile_regex_safe）时降级字面量替换
///   （对标 Kotlin runCatching 回退 `result.replace(replaceRegex, replacement)`；
///   replaceFirst 分支正则非法时对标原版直接返回 replacement）。
pub(crate) fn apply_regex_replace(text: &str, pattern: &str, replacement: &str, replace_first: bool) -> String {
    match compile_regex_safe(pattern) {
        Some(re) => {
            if replace_first {
                match re.find(text) {
                    Some(m) => re
                        .replacen(&text[m.start()..m.end()], 1, replacement)
                        .into_owned(),
                    None => String::new(),
                }
            } else {
                re.replace_all(text, replacement).into_owned()
            }
        }
        None => {
            if replace_first {
                replacement.to_string()
            } else {
                text.replace(pattern, replacement)
            }
        }
    }
}

// ─── 规则路径增强辅助函数（B1-B3） ─────────────────────────────

/// 提取可选字段：规则为空或解析结果为空时返回 None
///
/// 规则经 `eval_rule_string` 执行，支持 Kotlin SourceRule 的 `##` 替换语法。
fn optional_field(analyzer: &legado_parser::AnalyzeRule, rule: &str) -> Option<String> {
    if rule.is_empty() {
        return None;
    }
    let v = eval_rule_string(analyzer, rule).unwrap_or_default();
    if v.is_empty() {
        None
    } else {
        Some(v)
    }
}

/// 判断 URL 是否命中 bookUrlPattern 正则（对标 Kotlin `baseUrl.matches(it.toRegex())`）
///
/// Kotlin `String.matches(regex)` 要求整个字符串匹配正则，等价于将书源正则
/// 锚定为 `^(?:pattern)$`；Rust `Regex::is_match` 是部分匹配（find 语义），
/// 会把 `m.qibuge.com/s.php` 误判为命中 `(https?://)?(www.)?m.qibuge.com`
/// 而错误进入"详情页直连"分支，导致搜索结果页被当详情页解析 → 搜索 0 结果。
/// 修复：锚定后全匹配（与 Kotlin matches 语义一致）。
///
/// 正则非法/编译失败（compile_regex_safe 栈溢出防护）时静默返回 false，不影响主流程。
fn matches_book_url_pattern(pattern: &str, url: &str) -> bool {
    let anchored = format!("^(?:{})$", pattern);
    compile_regex_safe(&anchored)
        .map(|re| re.is_match(url))
        .unwrap_or(false)
}

/// 将 WebBookInfo 转为 WebSearchResult（详情页直连搜索项，对标 Kotlin `Book.toSearchBook()`）
fn info_to_search_result(info: WebBookInfo, source_url: &str) -> WebSearchResult {
    WebSearchResult {
        name: info.name,
        author: info.author,
        book_url: info.book_url,
        cover_url: info.cover_url,
        intro: info.intro,
        latest_chapter: info.last_chapter,
        book_type: 0, // 详情页直连：类型由书架 Book 决定 — A8
        source_url: source_url.to_string(),
        kind: info.kind,
        word_count: info.word_count,
    }
}

/// 搜索结果按 bookUrl 去重，保留首次出现顺序（对标 Kotlin `LinkedHashSet(bookList)`）
fn dedupe_by_book_url(results: Vec<WebSearchResult>) -> Vec<WebSearchResult> {
    let mut seen = std::collections::HashSet::new();
    results
        .into_iter()
        .filter(|r| seen.insert(r.book_url.clone()))
        .collect()
}

/// 章节去重（保留首次出现），去重键为 url
///
/// 对标 Kotlin `BookChapter.equals/hashCode`（基于 url）+ `LinkedHashSet(chapterList)`。
fn dedupe_first_by_url(chapters: Vec<WebChapter>) -> Vec<WebChapter> {
    let mut seen = std::collections::HashSet::new();
    chapters
        .into_iter()
        .filter(|c| seen.insert(c.url.clone()))
        .collect()
}

/// 章节去重（保留最后一次出现、保持原顺序）
///
/// 等价于 Kotlin 默认路径的 reverse→去重（保留首次）→reverse 双反转逻辑。
fn dedupe_last_by_url(chapters: Vec<WebChapter>) -> Vec<WebChapter> {
    let mut reversed = chapters;
    reversed.reverse();
    let mut deduped = dedupe_first_by_url(reversed);
    deduped.reverse();
    deduped
}

// ─── JS 书源分派辅助 ──────────────────────────────────────────────────────────

/// 将 JS 编排器搜索结果（serde_json::Value）转换为 WebSearchResult 列表
pub(crate) fn convert_js_search_results(
    values: Vec<serde_json::Value>,
    source_url: &str,
) -> Vec<WebSearchResult> {
    values
        .into_iter()
        .filter_map(|v| {
            let name = v.get("name")?.as_str()?.to_string();
            let book_url = v.get("bookUrl")?.as_str()?.to_string();
            if name.is_empty() || book_url.is_empty() {
                return None;
            }
            let author = v
                .get("author")
                .and_then(|a| a.as_str())
                .unwrap_or_default()
                .to_string();
            let cover_url = v
                .get("coverUrl")
                .and_then(|c| c.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let intro = v
                .get("intro")
                .and_then(|i| i.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let latest_chapter = v
                .get("latestChapter")
                .or_else(|| v.get("lastChapter"))
                .and_then(|l| l.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let kind = v
                .get("kind")
                .and_then(|k| k.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let word_count = v
                .get("wordCount")
                .and_then(|w| w.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            Some(WebSearchResult {
                name,
                author,
                book_url,
                cover_url,
                intro,
                latest_chapter,
                source_url: source_url.to_string(),
                kind,
                word_count,
                // JS 书源类型位：脚本可显式返回 type（兼容），缺省 0 — A8
                book_type: v
                    .get("type")
                    .and_then(|t| t.as_i64())
                    .map(|t| t as i32)
                    .unwrap_or(0),
            })
        })
        .collect()
}

/// 将 JS 编排器章节列表（serde_json::Value）转换为 WebChapter 列表
fn convert_js_chapters(values: Vec<serde_json::Value>) -> Vec<WebChapter> {
    values
        .into_iter()
        .enumerate()
        .map(|(i, v)| {
            let index = v
                .get("index")
                .and_then(|idx| idx.as_i64())
                .unwrap_or(i as i64) as i32;
            let title = v
                .get("title")
                .and_then(|t| t.as_str())
                .unwrap_or_default()
                .to_string();
            let url = v
                .get("url")
                .and_then(|u| u.as_str())
                .unwrap_or_default()
                .to_string();
            let is_vip = v
                .get("isVip")
                .and_then(|vip| vip.as_bool())
                .unwrap_or(false);
            WebChapter {
                index,
                title,
                url,
                is_vip,
                is_volume: false,
                variable: v
                    .get("variable")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string()),
            }
        })
        .collect()
}

/// 构建 JS 书源编排器
///
/// 从 BookSource 的 mainJs 字段创建 JsSourceEngine 并包装为编排器。
/// quickjs 启用时使用真实 QuickJS 引擎，否则使用占位引擎。
/// mainJs 为空时返回 None（非 JS 源）。
pub(crate) fn build_js_orchestrator(source: &BookSource) -> LegadoResult<Option<JsSourceBookOrchestrator>> {
    let main_js = match source.main_js.as_deref() {
        Some(js) if !js.trim().is_empty() => js.to_string(),
        _ => return Ok(None),
    };

    let mut config = JsSourceConfig::new(source.book_source_url.clone(), main_js);
    if let Some(lib) = &source.js_lib {
        config = config.with_js_lib(lib.clone());
    }

    #[cfg(feature = "quickjs")]
    let engine = legado_js::JsSourceEngine::new_quickjs(config)?;
    #[cfg(not(feature = "quickjs"))]
    let engine = legado_js::JsSourceEngine::new_stub(config);

    Ok(Some(JsSourceBookOrchestrator::new(engine)))
}

// ─── 公开 API 函数 ─────────────────────────────────────────────────────────────

/// 搜索书籍
///
/// `source_json` — BookSource JSON 字符串
/// `query` — 搜索关键词
/// `page` — 页码（从 1 开始）
///
/// 返回 `WebSearchResult` JSON 数组字符串
pub fn webbook_search(source_json: &str, query: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // JS 书源分派：spawn_blocking 避免嵌套 runtime 死锁（R1）
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let key = query.to_string();
        let values = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                orchestrator.search(&source_clone, &key, page)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 搜索任务异常: {e}")))?
        })?;
        let results = convert_js_search_results(values, &source.book_source_url);
        return serde_json::to_string(&results).map_err(LegadoError::Serialization);
    }

    // 规则书源路径（现有逻辑不变）
    let engine = build_engine()?;
    let results: Vec<WebSearchResult> =
        runtime::block_on(async { engine.search(&source, query, page).await })?;
    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

/// 获取书籍详情
///
/// `source_json` — BookSource JSON 字符串
/// `book_url` — 书籍详情页 URL
///
/// 返回 `WebBookInfo` JSON 字符串
pub fn webbook_info(source_json: &str, book_url: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // JS 书源分派
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let url = book_url.to_string();
        let js_info = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let book = Book {
                    book_url: url.clone(),
                    origin: source_clone.book_source_url.clone(),
                    ..Book::default()
                };
                orchestrator.get_book_info(&source_clone, &book, true)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 详情任务异常: {e}")))?
        })?;
        // 将 MarshalledBookInfo 转换为 WebBookInfo
        let categories = js_info
            .kind
            .as_deref()
            .map(|k| {
                k.split([',', '，', ' '])
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let info = WebBookInfo {
            name: js_info.name,
            author: js_info.author.unwrap_or_default(),
            cover_url: js_info.cover_url,
            intro: js_info.intro,
            categories,
            last_chapter: js_info.latest_chapter_title,
            book_url: book_url.to_string(),
            toc_url: js_info.toc_url.unwrap_or_else(|| book_url.to_string()),
            word_count: js_info.word_count,
            kind: js_info.kind,
        };
        return serde_json::to_string(&info).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
    let engine = build_engine()?;
    let info: WebBookInfo =
        runtime::block_on(async { engine.get_book_info(&source, book_url).await })?;
    serde_json::to_string(&info).map_err(LegadoError::Serialization)
}

/// 获取章节列表
///
/// `source_json` — BookSource JSON 字符串
/// `book_url` — 书籍详情页 URL
///
/// 返回 `WebChapter` JSON 数组字符串
pub fn webbook_chapters(
    source_json: &str,
    book_url: &str,
    toc_url: &str,
    book_name: &str,
) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let known_toc = toc_url.trim();
    let known_toc_opt = if known_toc.is_empty() {
        None
    } else {
        Some(known_toc)
    };
    let name_hint = book_name.trim();
    let name_hint_opt = if name_hint.is_empty() {
        None
    } else {
        Some(name_hint)
    };

    // JS 书源分派
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let url = book_url.to_string();
        let toc = known_toc_opt
            .map(|s| s.to_string())
            .unwrap_or_else(|| url.clone());
        let book_name_owned = name_hint.to_string();
        let values = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let book = Book {
                    book_url: url.clone(),
                    toc_url: toc,
                    name: book_name_owned,
                    origin: source_clone.book_source_url.clone(),
                    ..Book::default()
                };
                orchestrator.get_chapter_list(&source_clone, &book)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 目录任务异常: {e}")))?
        })?;
        let chapters = convert_js_chapters(values);
        return serde_json::to_string(&chapters).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
    let fetcher = RealBookSourceFetcher::new()?;
    let chapters: Vec<WebChapter> = runtime::block_on(async {
        fetcher
            .get_chapters_with_hints(&source, book_url, known_toc_opt, name_hint_opt)
            .await
    })?;
    serde_json::to_string(&chapters).map_err(LegadoError::Serialization)
}

/// 获取章节内容
///
/// `source_json` — BookSource JSON 字符串
/// `chapter_json` — WebChapter JSON 字符串
///
/// 返回章节正文文本
pub fn webbook_content(source_json: &str, chapter_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let chapter: WebChapter = serde_json::from_str(chapter_json)?;

    // JS 书源分派
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let web_ch = chapter.clone();
        return runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let book_chapter = BookChapter {
                    url: web_ch.url,
                    title: web_ch.title,
                    index: web_ch.index,
                    is_vip: web_ch.is_vip,
                    ..BookChapter::default()
                };
                let book = Book {
                    origin: source_clone.book_source_url.clone(),
                    ..Book::default()
                };
                orchestrator.get_content(&source_clone, &book_chapter, &book, None)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 正文任务异常: {e}")))?
        });
    }

    // 规则书源路径
    let engine = build_engine()?;
    runtime::block_on(async { engine.get_content(&source, &chapter).await })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::book_source::book_source_type;

    /// 书山聚合目录回归：真实书源 + 真实 data: URI bookUrl 调 webbook_chapters。
    /// 覆盖链路：data:URI hex 解码 → init 规则 java.ajax(/details)（带书源
    /// header 规则 X-Novel-Token + JSON Content-Type）→ tocUrl 规则产出
    /// catalogUrl → chapterList java.ajax(/catalog) → 章节列表。
    /// — 书山目录修复（2026-08-17）
    #[test]
    fn test_shushan_real_toc_repro() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("sources_device.json 缺失，跳过");
            return;
        };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("书山"))
        }) else {
            eprintln!("未找到书山聚合源，跳过");
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        use base64::Engine;
        // 书库阁书（目录+正文链路回归；正文为 VIP 提示文本，非空即可）
        let detail_url = "http://www.shukuge.com/book/117256/";
        let b64_url = base64::engine::general_purpose::STANDARD.encode(detail_url);
        let detail = serde_json::json!({
            "source": "书库阁",
            "url": b64_url,
            "name": "一念永恒测试",
        });
        let b64_detail = base64::engine::general_purpose::STANDARD.encode(detail.to_string());
        let book_url = format!(r#"data:detailsUrl;base64,{},{{"type":"susan"}}"#, b64_detail);
        // 真实番茄书（5556 模拟器书架导出）：验证登录后正文返回明文
        let real_book_url = std::fs::read_to_string("C:/Users/Public/real_bookurl.txt")
            .unwrap_or_default();
        let book_url = if !real_book_url.trim().is_empty() {
            real_book_url.trim().to_string()
        } else {
            book_url
        };
        let source_json = serde_json::to_string(&source).unwrap();
        // 注入设备 ID（对齐 Flutter 启动时 RustApi._injectDeviceId）
        legado_js::host_api::device_id::set_device_id("62d8d4fb53e19733");
        // V1 登录回归：书山 login() 在书源上下文执行 → putLoginHeader(api_key)
        // → sync 落库 → 正文请求携带 X-Api-Key 返回明文
        crate::api::source_login_cache::put_login_info(
            &source.book_source_url,
            r#"{"邮箱":"512824117@qq.com","密码":"zgh5201214"}"#,
        )
        .unwrap();
        let login_out = match crate::api::source_login_v1_api::eval_login_v1(&source_json, "login") {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[repro] V1 登录执行错误: {e}");
                String::new()
            }
        };
        eprintln!(
            "[repro] V1 登录结果: {}",
            login_out.chars().take(80).collect::<String>()
        );
        let lh = crate::api::source_login_cache::get_login_header(&source.book_source_url)
            .unwrap_or_default();
        eprintln!(
            "[repro] loginHeader: {}",
            lh.chars().take(60).collect::<String>()
        );
        assert!(
            !lh.is_empty() && lh != "null",
            "书山 V1 登录应写入 loginHeader(api_key): {lh:?}"
        );
        let result = webbook_chapters(&source_json, &book_url, "", "");
        let chapters: Vec<serde_json::Value> = match result {
            Ok(s) => {
                let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                eprintln!("[repro] 目录 {} 章", arr.len());
                assert!(arr.len() > 5, "书山目录应 >5 章，实际 {}", arr.len());
                arr
            }
            Err(e) => panic!("[repro] 书山目录失败: {e}"),
        };
        // 正文回归：取第一章 data:chapterUrl 调 webbook_content
        let first = chapters.first().cloned().unwrap_or_default();
        let ch_url = first.get("url").and_then(|u| u.as_str()).unwrap_or("");
        eprintln!("[repro] 第一章 url 前缀: {}", &ch_url[..ch_url.len().min(120)]);
        if !ch_url.is_empty() {
            let ch_json = serde_json::json!({
                "url": ch_url,
                "title": first.get("title").and_then(|t| t.as_str()).unwrap_or(""),
                "index": 0,
                "is_vip": false,
            })
            .to_string();

            let content = webbook_content(&source_json, &ch_json);
            match content {
                Ok(c) => {
                    eprintln!("[repro] 正文前120: {}", c.chars().take(120).collect::<String>());
                    assert!(c.trim().len() > 50, "正文应非空，实际 {}", c.trim().len());
                }
                Err(e) => panic!("[repro] 书山正文失败: {e}"),
            }
        }
    }

    #[test]
    fn test_decode_web_response_gbk_meta_and_header() {
        let mut meta_headers = HashMap::new();
        let (html, _, _) = encoding_rs::GBK.encode(r#"<html><head><meta charset="gbk"></head><body>目录章节</body></html>"#);
        assert!(decode_web_response(&html, &meta_headers, None).contains("目录章节"));

        let mut header_headers = HashMap::new();
        header_headers.insert("Content-Type".to_string(), "text/html; charset=gbk".to_string());
        let (plain, _, _) = encoding_rs::GBK.encode("正文内容");
        assert_eq!(decode_web_response(&plain, &header_headers, None), "正文内容");

        meta_headers.insert("Content-Type".to_string(), "text/html; charset=utf-8".to_string());
        assert_eq!(decode_web_response(&plain, &meta_headers, Some("gbk")), "正文内容");

        let mut spaced_header = HashMap::new();
        spaced_header.insert("content-type".to_string(), "text/html; Charset = GBK".to_string());
        assert_eq!(decode_web_response(&plain, &spaced_header, None), "正文内容");

        let (single_quote, _, _) = encoding_rs::GBK.encode(
            r#"<html><head><meta charset='GBK'></head><body>单引号</body></html>"#,
        );
        assert!(decode_web_response(&single_quote, &HashMap::new(), None).contains("单引号"));

        let (http_equiv, _, _) = encoding_rs::GBK.encode(
            r#"<html><head><meta http-equiv="Content-Type" content="text/html; charset = gbk"></head><body>兼容声明</body></html>"#,
        );
        assert!(decode_web_response(&http_equiv, &HashMap::new(), None).contains("兼容声明"));

        let fake = b"<html><body><script>var charset = gbk;</script>plain utf8</body></html>";
        assert_eq!(charset_from_html_meta(fake), None);
    }

    /// 批量搜索扫描（2026-08-17）：人工实网诊断，不作为 CI 回归门禁。
    /// fixture/源站网络波动时只输出统计；需手工运行并对照原版。
    #[test]
    #[ignore = "外部 fixture 与源站网络诊断，非确定性 CI 测试"]
    fn test_batch_search_scan_text_sources() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("sources_device.json 缺失，跳过");
            return;
        };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let mut scanned = 0;
        let mut ok = 0;
        let mut empty = 0;
        let mut failed = 0;
        for src in sources.iter() {
            let st = src.get("bookSourceType").and_then(|v| v.as_i64()).unwrap_or(0);
            if st != 0 { continue; }
            let name = src.get("bookSourceName").and_then(|n| n.as_str()).unwrap_or("");
            let url = src.get("bookSourceUrl").and_then(|n| n.as_str()).unwrap_or("");
            if !url.contains("://") { continue; }
            let Ok(source) =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap())
            else {
                continue;
            };
            if source.rule_search.as_ref().and_then(|r| r.book_list.as_deref()).unwrap_or("").is_empty() {
                continue;
            }
            scanned += 1;
            let source_json = serde_json::to_string(&source).unwrap();
            match webbook_search(&source_json, "一念", 1) {
                Ok(s) => {
                    let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                    if arr.is_empty() {
                        empty += 1;
                        eprintln!("[scan-empty] {} | {}", name, url);
                    } else {
                        ok += 1;
                    }
                }
                Err(e) => {
                    failed += 1;
                    eprintln!("[scan-fail] {} | {} | {}", name, url, e.to_string().chars().take(120).collect::<String>());
                }
            }
            if scanned >= 120 { break; }
        }
        eprintln!("[scan-summary] scanned={} ok={} empty={} failed={}", scanned, ok, empty, failed);
    }

    /// 扩展扫描：跳过前 120 个 type-0，再扫 200 个，供人工对照原版。
    #[test]
    #[ignore = "外部源站批量诊断，非确定性 CI 测试"]
    fn test_batch_search_scan_extended_wave2() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let out_path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_parity/scan_wave2.jsonl"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("sources_device.json 缺失，跳过");
            return;
        };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let mut skip = 0usize;
        let mut scanned = 0usize;
        let mut ok = 0usize;
        let mut empty = 0usize;
        let mut failed = 0usize;
        let mut lines: Vec<String> = Vec::new();
        for src in sources.iter() {
            let st = src.get("bookSourceType").and_then(|v| v.as_i64()).unwrap_or(0);
            if st != 0 {
                continue;
            }
            let name = src
                .get("bookSourceName")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            let url = src
                .get("bookSourceUrl")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            if !url.contains("://") {
                continue;
            }
            let Ok(source) =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap())
            else {
                continue;
            };
            if source
                .rule_search
                .as_ref()
                .and_then(|r| r.book_list.as_deref())
                .unwrap_or("")
                .is_empty()
            {
                continue;
            }
            if skip < 120 {
                skip += 1;
                continue;
            }
            scanned += 1;
            let source_json = serde_json::to_string(&source).unwrap();
            let (status, detail, count) = match webbook_search(&source_json, "一念", 1) {
                Ok(s) => {
                    let arr: Vec<serde_json::Value> =
                        serde_json::from_str(&s).unwrap_or_default();
                    if arr.is_empty() {
                        empty += 1;
                        ("empty", String::new(), 0usize)
                    } else {
                        ok += 1;
                        ("ok", String::new(), arr.len())
                    }
                }
                Err(e) => {
                    failed += 1;
                    (
                        "fail",
                        e.to_string().chars().take(160).collect::<String>(),
                        0usize,
                    )
                }
            };
            if status != "ok" {
                eprintln!("[wave2-{}] {} | {} | {}", status, name, url, detail);
            }
            lines.push(
                serde_json::json!({
                    "status": status,
                    "name": name,
                    "url": url,
                    "count": count,
                    "detail": detail,
                })
                .to_string(),
            );
            if scanned >= 200 {
                break;
            }
        }
        let _ = std::fs::write(out_path, lines.join("\n"));
        eprintln!(
            "[wave2-summary] scanned={} ok={} empty={} failed={} out={}",
            scanned, ok, empty, failed, out_path
        );
    }

    /// 七步阁 GBK POST 搜索回归（2026-08-17）：bookUrlPattern 全匹配修复
    /// （m.qibuge.com 正则不得命中 /s.php 搜索页 URL）
    #[test]
    fn test_qibuge_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains("七步阁"))
        }) else { return; };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup =
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup,
        );
        eprintln!("[qibuge] request_body: {:?}", au.request_body());
        eprintln!("[qibuge] request_body={:?} encoded_form={:?} headers={:?}", au.request_body(), au.encoded_form(), au.headers());
        eprintln!("[qibuge] URL: {} method: {:?} body: {:?} charset: {:?}",
            au.url(), au.method(), au.body(), au.charset());
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let headers = crate::api::web_book::RealBookSourceFetcher::parse_source_headers(&source);
        eprintln!("[qibuge] source_headers: {:?}", headers);
        let body = crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref()))
            .unwrap_or_default();
        eprintln!("[qibuge] 响应体前300: {}", body.chars().take(300).collect::<String>());
        eprintln!("[qibuge] 长度: {}", body.len());
        eprintln!("[qibuge] has_sone: {}", body.contains("sone"));
        eprintln!("[qibuge] 全文: {}", body.chars().take(1500).collect::<String>());
        // 完整 search 链路验证
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[qibuge] search 结果数: {}", list.len());
                assert!(list.len() > 0, "七步阁搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(5) {
                    eprintln!("[qibuge]   -> {} | {} | {}", it.name, it.author, it.book_url);
                }
            }
            Err(err) => panic!("[qibuge] search 失败: {:?}", err),
        }
    }

    /// 七步阁 GBK 目录/正文回归：详情页 meta charset=gbk 必须在简单 GET 路径正确解码。
    #[test]
    fn test_qibuge_catalog_and_content_gbk() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains("七步阁"))
        }) else { return; };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let search = webbook_search(&source_json, "一念", 1).expect("七步阁搜索失败");
        let books: Vec<serde_json::Value> = serde_json::from_str(&search).unwrap();
        let first = books.first().expect("七步阁搜索应有结果");
        let book_url = first.get("book_url").and_then(|v| v.as_str()).expect("缺少 book_url");
        let book_name = first.get("name").and_then(|v| v.as_str()).unwrap_or("");
        assert!(!book_name.contains('�'), "搜索书名乱码: {book_name}");

        let info = webbook_info(&source_json, book_url).expect("七步阁详情失败");
        let info: serde_json::Value = serde_json::from_str(&info).unwrap();
        let toc_url = info.get("toc_url").and_then(|v| v.as_str()).unwrap_or("");
        let chapters = webbook_chapters(&source_json, book_url, toc_url, book_name).expect("七步阁目录失败");
        let chapters: Vec<serde_json::Value> = serde_json::from_str(&chapters).unwrap();
        let first_chapter = chapters.first().expect("七步阁目录应有章节");
        let chapter_title = first_chapter.get("title").and_then(|v| v.as_str()).unwrap_or("");
        assert!(!chapter_title.is_empty() && !chapter_title.contains('�'), "目录标题乱码: {chapter_title:?}");

        let content = webbook_content(&source_json, &first_chapter.to_string()).expect("七步阁正文失败");
        assert!(content.chars().count() > 30, "正文过短: {}", content.chars().count());
        assert!(!content.contains('�'), "正文乱码: {}", content.chars().take(120).collect::<String>());
        eprintln!("[qibuge-gbk] 书名={book_name}，目录首章={chapter_title}，正文前80={}", content.chars().take(80).collect::<String>());
    }

    /// 77读书网 搜索诊断（2026-08-17）：站点返回 47KB 含结果，规则 class.BOX@tr!0 解析为 0
    #[test]
    fn test_77shuku_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains("77读书"))
        }) else { return; };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup =
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup.clone(),
        );
        eprintln!("[77] URL: {} method: {:?} headers: {:?}", au.url(), au.method(), au.headers());
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let headers = crate::api::web_book::RealBookSourceFetcher::parse_source_headers(&source);
        let body = crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref()))
            .unwrap_or_default();
        eprintln!("[77] 长度: {} 含一念: {}", body.len(), body.contains("一念"));
        eprintln!("[77] 含BOX: {} 含table: {} 含tr: {}",
            body.contains("BOX"), body.contains("<table"), body.contains("<tr"));
        let analyzer = crate::js_executor::construct_analyzer_with_source_context(
            body.clone(),
            au.url().to_string(),
            &source.book_source_url,
            None,
            setup.clone(),
        );
        for probe in ["class.BOX@tr!0", "table@tr!0", "table@tr", "css(table tr)", "css(tr)", "tr", "tag.tr", "class.BOX", "css(.BOX)", "css(table)", "class.BOX@tr", "class.BOX@table@tr", "table@tr!0@", "tag.table@tag.tr!0", "tag.table@tag.tr"].iter() {
            let n = analyzer.get_elements(probe).unwrap_or_default().len();
            eprintln!("[77] probe {probe:?} -> {n}");
        }
        if let Some(i) = body.find("BOX") {
            eprintln!("[77] BOX 上下文: {:?}", body[i.saturating_sub(80)..(i + 300).min(body.len())].chars().collect::<String>());
        }
        // 字段级诊断：第一个元素的 name/author/bookUrl 提取
        let elems77 = analyzer.get_elements("class.BOX@tr!0").unwrap_or_default();
        if let Some(elem) = elems77.get(0) {
            let mut ea = crate::js_executor::construct_analyzer_with_source_context(
                elem.clone(),
                au.url().to_string(),
                &source.book_source_url,
                None,
                setup.clone(),
            );
            ea.set_element_content(elem.clone());
            let rn = ea.get_string_ex("tag.td.2@a@text", false, false);
            let rb = ea.get_string_ex("tag.td.2@a@href", true, false);
            eprintln!("[77] elem0 name={:?} bookUrl={:?}", rn, rb);
            for probe in ["tag.td.2@a@text", "tag.td@a@text", "td.2@a@text", "td@a@text", "tag.td.2", "css(td:eq(2) a)", "a.0@text", "css(a)", "tag.a@text", "tag.td@tag.a@text", "tag.td.2@tag.a@text"] {
                let v = ea.get_string_ex(probe, false, false).unwrap_or_default();
                eprintln!("[77]   probe {probe:?} -> {:?}", v.chars().take(30).collect::<String>());
            }
            eprintln!("[77] elem0 前200: {:?}", elem.chars().take(200).collect::<String>());
        }
        assert!(elems77.len() > 0, "77读书网 bookList 应解析出元素，实际 {}", elems77.len());
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[77] search 结果数: {}", list.len());
                assert!(list.len() > 0, "77读书网搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(3) {
                    eprintln!("[77]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[77] search 失败: {:?}", err),
        }
    }

    /// 淘小说 @js md5 签名搜索诊断（2026-08-17）
    #[test]
    fn test_taoxiaoshuo_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains("淘小说"))
        }) else { return; };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup =
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup,
        );
        eprintln!("[taoxs] URL: {}", au.url());
        // 直接测试 @js: 块执行（绕过静默回退）
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(crate::api::source_js_bindings::book_source_js_setup_script(&source).ok());
        let js_code = source.search_url.as_deref().unwrap_or("").trim_start_matches("@js:").trim_start();
        eprintln!("[taoxs] js_code 前150: {:?}", js_code.chars().take(150).collect::<String>());
        let vars = std::collections::HashMap::from([("key".to_string(), "一念".to_string()), ("page".to_string(), "1".to_string())]);
        let parsed = crate::legado_parser::AnalyzeUrl::parse_with_js(
            source.search_url.as_deref().unwrap_or(""),
            &vars,
            1,
            &exec,
        );
        match parsed {
            Ok(u) => eprintln!("[taoxs] parse_with_js OK: {}", u.url()),
            Err(err) => eprintln!("[taoxs] parse_with_js ERR: {:?}", err),
        }
        eprintln!("[taoxs] method: {:?} headers: {:?}", au.method(), au.headers());
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let headers = crate::api::web_book::RealBookSourceFetcher::parse_source_headers(&source);
        let body = crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref()))
            .unwrap_or_default();
        eprintln!("[taoxs] 响应长度: {} 前200: {:?}", body.len(), body.chars().take(200).collect::<String>());
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[taoxs] search 结果数: {}", list.len());
                assert!(list.len() > 0, "淘小说搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(3) {
                    eprintln!("[taoxs]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[taoxs] search 失败: {:?}", err),
        }
    }


    /// 企鹅小说 setup 依赖搜索验证（2026-08-17）：searchUrl 用
    /// `{{url=source.getKey();...}}`，缺 setup 时模板残留 → HTTP 404
    #[test]
    fn test_qiexs_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains("企鹅小说"))
        }) else { return; };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        // 直接构造 AnalyzeUrl 看中间态
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(crate::api::source_js_bindings::book_source_js_setup_script(&source).ok());
        let vars = std::collections::HashMap::from([
            ("key".to_string(), "一念".to_string()),
            ("page".to_string(), "1".to_string()),
            ("baseUrl".to_string(), source.book_source_url.clone()),
            ("searchKey".to_string(), "一念".to_string()),
        ]);
        let parsed = crate::legado_parser::AnalyzeUrl::parse_with_js(
            source.search_url.as_deref().unwrap_or(""),
            &vars,
            1,
            &exec,
        );
        match &parsed {
            Ok(u) => eprintln!("[qiexs] parse_with_js OK: {}", u.url()),
            Err(err) => eprintln!("[qiexs] parse_with_js ERR: {:?}", err),
        }
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[qiexs] search 结果数: {}", list.len());
                assert!(list.len() > 0, "企鹅小说搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(3) {
                    eprintln!("[qiexs]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[qiexs] search 失败: {:?}", err),
        }
    }

    /// 新笔趣阁 @js: 重定向拦截搜索验证（2026-08-17）：searchUrl 用
    /// java.get(su,{}).headers('Location')[0] 需 jsoup Response 语义桥
    #[test]
    fn test_xbqgxs_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains("新笔趣阁") && s.get("bookSourceUrl").and_then(|u| u.as_str()).is_some_and(|u| u.contains("xbqgxs")))
        }) else { return; };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        // 直接执行 @js: 块看错误
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(crate::api::source_js_bindings::book_source_js_setup_script(&source).ok());
        let vars = std::collections::HashMap::from([
            ("key".to_string(), "一念".to_string()),
            ("page".to_string(), "1".to_string()),
            ("baseUrl".to_string(), source.book_source_url.clone()),
        ]);
        let parsed = crate::legado_parser::AnalyzeUrl::parse_with_js(
            source.search_url.as_deref().unwrap_or(""),
            &vars,
            1,
            &exec,
        );
        match &parsed {
            Ok(u) => eprintln!("[xbqgxs] parse_with_js OK: {}", u.url().chars().take(150).collect::<String>()),
            Err(err) => eprintln!("[xbqgxs] parse_with_js ERR: {:?}", err),
        }
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[xbqgxs] search 结果数: {}", list.len());
                assert!(list.len() > 0, "新笔趣阁搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(3) {
                    eprintln!("[xbqgxs]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[xbqgxs] search 失败: {:?}", err),
        }
    }

    /// 新落秋/笔趣阁zdzn/天悦小说人工实网诊断：源站存在 IP 限频/WAF，不作为 CI 回归。
    #[test]
    #[ignore = "外部源站限频/WAF，手工诊断专用"]
    fn test_js_network_sources_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else { return; };
        for needle in ["新落秋", "天悦小说", "笔趣阁zdzn"] {
            let Some(src) = sources.iter().find(|s| {
                s.get("bookSourceName").and_then(|n| n.as_str()).is_some_and(|n| n.contains(needle))
            }) else { continue; };
            let source =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
            let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
            let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
            match results {
                Ok(list) => eprintln!("[jsnet] {} -> {} 条", needle, list.len()),
                Err(err) => eprintln!("[jsnet] {} -> 失败: {}", needle, err.to_string().chars().take(120).collect::<String>()),
            }
        }
    }



    /// 得间小说 {{host}} 全局变量离线回归：jsLib 定义 host，{{host}} 需 JS 求值。
    #[test]
    fn test_dejian_diag() {
        let source = BookSource {
            book_source_url: "https://wechat.idejian.com##".to_string(),
            book_source_name: "得间小说".to_string(),
            js_lib: Some("type = 'wechat'; host = 'https://' + type + '.idejian.com/api/' + type;".to_string()),
            search_url: Some("{{host}}/search/do?keyword={{key}}&page={{page}}".to_string()),
            ..BookSource::default()
        };
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(), "一念", 1, &source.book_source_url,
            source.js_lib.as_deref(), crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert_eq!(
            au.url(),
            "https://wechat.idejian.com/api/wechat/search/do?keyword=%E4%B8%80%E5%BF%B5&page=1"
        );
    }

    /// java.connect StrResponse.raw().request().url() 实网诊断：趣书源站重定向不稳定。
    #[test]
    #[ignore = "外部源站重定向，离线契约由 legado-js bridge test 覆盖"]
    fn test_connect_str_response_search_url_no_undefined() {
        let source = BookSource {
            book_source_url: "https://qubook.org".to_string(),
            book_source_name: "趣书".to_string(),
            search_url: Some(r#"@js:
burl = source.getKey();
url = burl + "/e/search/";
body = "show=title%2Cnewstext&keyboard=" + key;
$ = java.post(url + "index.php", body, {}).headers();
uri = $.Location || $.location;
url += String(uri).replace('?', 'index.php?page=0&');"#.to_string()),
            ..BookSource::default()
        };
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(), "一念", 1, &source.book_source_url,
            None, crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert!(!au.url().contains("undefined"), "趣书 URL 不应含 undefined: {}", au.url());
        assert!(!au.url().starts_with("legado-js-error://"), "趣书 JS 不应失败: {}", au.url());
    }

    /// 趣书网吧人工实网诊断：依赖 fixture 与外部重定向；离线 result 绑定契约见 parser 测试。
    #[test]
    #[ignore = "外部源站/fixture 诊断，非确定性 CI 测试"]
    fn test_qushu123_connect_search_diag() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tmp_debug/e2e_5558/sources_device.json");
        let Ok(raw) = std::fs::read_to_string(path) else { return; };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw) else { return; };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceUrl").and_then(|v| v.as_str()).is_some_and(|u| u.contains("qushu123.com"))
        }) else { return; };
        let source = serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""), "一念", 1, &source.book_source_url,
            source.js_lib.as_deref(), crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        eprintln!("[qushu123] url={}", au.url());
        assert!(!au.url().contains("undefined"), "趣书 URL 不应含 undefined: {}", au.url());
        assert!(!au.url().starts_with("legado-js-error://"), "趣书 JS 不应失败: {}", au.url());
    }

    /// 天涯书库真实规则：source.key + java.post().header(location) 必须可构建搜索 URL。
    #[test]
    #[ignore = "外部重定向源诊断，离线 Response bridge 契约覆盖"]
    fn test_tianyashuku_search_url_diag() {
        let raw = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../tmp_debug/e2e_5558/sources_device.json")).unwrap();
        let serde_json::Value::Array(sources) = serde_json::from_str::<serde_json::Value>(&raw).unwrap() else { return; };
        let src = sources.iter().find(|s| s.get("bookSourceUrl").and_then(|v| v.as_str()).is_some_and(|u| u.contains("tianyashuku.net"))).unwrap();
        let source = serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(), "一念", 1, &source.book_source_url,
            source.js_lib.as_deref(), crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert!(!au.url().contains("undefined"), "天涯 URL 不应含 undefined: {}", au.url());
        assert!(!au.url().starts_with("legado-js-error://"), "天涯 JS 不应失败: {}", au.url());
    }

    /// org.jsoup + java.post(connectNR) 回归：云霄/键盘/天涯书库 searchUrl @js
    #[test]
    fn test_jsoup_post_redirect_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let needles = ["云霄小说", "键盘小说", "天涯书库", "玄幻文学"];
        for needle in needles {
            let Some(src) = sources.iter().find(|s| {
                s.get("bookSourceName")
                    .and_then(|n| n.as_str())
                    .is_some_and(|n| n.contains(needle))
            }) else {
                eprintln!("[jsoup-diag] 未找到书源: {needle}");
                continue;
            };
            let source =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
            let setup =
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
            let au = crate::js_executor::build_search_url_with_setup(
                source.search_url.as_deref().unwrap_or(""),
                "一念",
                1,
                &source.book_source_url,
                source.js_lib.as_deref(),
                setup,
            );
            eprintln!("[{needle}] URL: {}", au.url());
            assert!(
                !au.url().contains("@js:") && !au.url().contains("<js>"),
                "{needle} searchUrl JS 未渲染: {}",
                au.url()
            );
            assert!(
                !au.url().starts_with("legado-js-error://"),
                "{needle} JS 求值失败: {}",
                au.url()
            );
            assert!(
                !au.url().ends_with("/null") && !au.url().contains("/null?"),
                "{needle} Location 拦截失败落 /null: {}",
                au.url()
            );
            let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
            match crate::runtime::block_on(fetcher.search(&source, "一念", 1)) {
                Ok(list) => eprintln!("[{needle}] search 结果数: {}", list.len()),
                Err(err) => eprintln!(
                    "[{needle}] search 失败: {}",
                    err.to_string().chars().take(160).collect::<String>()
                ),
            }
        }
    }

    /// 书书小说 allInOne `$1/$2` 目录回归（G8）
    #[test]
    fn test_shushu_all_in_one_toc_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) =
            serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("书书小说"))
        }) else {
            eprintln!("[shushu] 未找到书源");
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        match webbook_search(&source_json, "斗破", 1) {
            Ok(s) => {
                let books: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                eprintln!("[shushu] 搜索 {} 条", books.len());
                if let Some(first) = books.first() {
                    eprintln!(
                        "[shushu] 首条 name={} url={}",
                        first.get("name").and_then(|v| v.as_str()).unwrap_or(""),
                        first.get("book_url").and_then(|v| v.as_str()).unwrap_or("")
                    );
                }
                assert!(
                    !books.is_empty(),
                    "书书小说搜索「斗破」应有列表结果，实际 {}",
                    books.len()
                );
            }
            Err(e) => panic!("书书搜索失败: {e}"),
        }
        // 目录/正文仍走已知 allInOne 书页（与搜索关键词无关）
        let book_url = String::from("http://www.shushun.cc/read_81/");
        let book_name = String::from("一念永恒");
        eprintln!("[shushu] 书={book_name} url={book_url}");
        let info = webbook_info(&source_json, &book_url).unwrap_or_default();
        let info: serde_json::Value = serde_json::from_str(&info).unwrap_or_default();
        let toc_url = info.get("toc_url").and_then(|v| v.as_str()).unwrap_or("");
        let chapters = webbook_chapters(&source_json, &book_url, toc_url, &book_name)
            .expect("书书小说目录应成功");
        let chapters: Vec<serde_json::Value> = serde_json::from_str(&chapters).unwrap();
        eprintln!("[shushu] 目录 {} 章", chapters.len());
        assert!(
            chapters.len() >= 2,
            "书书小说 allInOne $n 目录过少: {}",
            chapters.len()
        );
        let first_ch = chapters.first().unwrap();
        let title = first_ch.get("title").and_then(|v| v.as_str()).unwrap_or("");
        assert!(!title.is_empty() && title != "$2", "章名未回填: {title}");
        let ch_url = first_ch.get("url").and_then(|v| v.as_str()).unwrap_or("");
        assert!(
            !ch_url.is_empty() && !ch_url.contains("$1"),
            "章 URL 未回填: {ch_url}"
        );
        match webbook_content(&source_json, &first_ch.to_string()) {
            Ok(c) => eprintln!(
                "[shushu] 正文 {} 字 前80={}",
                c.chars().count(),
                c.chars().take(80).collect::<String>()
            ),
            Err(e) => eprintln!(
                "[shushu] 正文失败: {}",
                e.to_string().chars().take(160).collect::<String>()
            ),
        }
    }

    /// 红薯小说 JSONP 人工实网诊断：离线 @json 后缀和 JSON 占位符回归覆盖核心语义。
    #[test]
    #[ignore = "外部源站 JSONP 诊断，非确定性 CI 测试"]
    fn test_hongshu_jsonp_search_diag() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tmp_debug/e2e_5558/sources_device.json");
        let raw = std::fs::read_to_string(path).unwrap();
        let serde_json::Value::Array(sources) = serde_json::from_str::<serde_json::Value>(&raw).unwrap() else { return; };
        let src = sources.iter().find(|s| s.get("bookSourceUrl").and_then(|v| v.as_str()) == Some("https://g.hongshu.com/")).unwrap();
        let source = serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let result = webbook_search(&source_json, "一念", 1);
        eprintln!("[hongshu] result={:?}", result.as_ref().map(|s| s.chars().take(500).collect::<String>()));
        assert!(result.is_ok(), "红薯搜索请求失败: {:?}", result.err());
    }

    use legado_core::models::rule::ContentRule;

    fn make_source_json() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_content: Some(ContentRule {
                content: Some("css(.content).html".to_string()),
                ..ContentRule::default()
            }),
            ..BookSource::default()
        })
        .unwrap()
    }

    #[test]
    fn test_siluke_full_rules_next_toc() {
        use std::time::Instant;
        let source_json = include_str!("../../tests/fixtures/siluke_rules.json");
        let book_url = "http://www.silukezw.com/135/135188/";
        let t0 = Instant::now();
        let _ = webbook_info(source_json, book_url);
        let t1 = Instant::now();
        let ch = webbook_chapters(source_json, book_url, "", "").expect("chapters");
        let arr: Vec<serde_json::Value> = serde_json::from_str(&ch).unwrap();
        eprintln!(
            "[timing-full] chapters={} toc={:?} total={:?}",
            arr.len(),
            t1.elapsed(),
            t0.elapsed()
        );
        // 思路客分页：首页约100，全量应明显更多（若 nextTocUrl 生效）
        assert!(arr.len() >= 100, "got {}", arr.len());
    }

    #[test]
    fn test_siluke_book_info_chapters_timing_and_cache() {
        use std::time::Instant;
        let source = serde_json::json!({
            "bookSourceUrl": "http://www.silukezw.com",
            "bookSourceName": "思路客#2",
            "bookSourceType": 0,
            "ruleBookInfo": {
                "name": "[property=\"og:title\"]@content",
                "author": "meta[property=\"og:novel:author\"]@content",
                "intro": "#intro@text",
                "coverUrl": "meta[property=\"og:image\"]@content",
                "tocUrl": "",
                "lastChapter": "meta[property=\"og:novel:latest_chapter_name\"]@content"
            },
            "ruleToc": {
                "chapterList": ".book_list2 li a",
                "chapterName": "text",
                "chapterUrl": "href"
            }
        });
        let source_json = source.to_string();
        let book_url = "http://www.silukezw.com/135/135188/";

        let t0 = Instant::now();
        let info = webbook_info(&source_json, book_url);
        let info_ms = t0.elapsed();
        assert!(info.is_ok(), "info err: {:?}", info.err());
        eprintln!("[timing] webbook_info {:?}", info_ms);

        let t1 = Instant::now();
        let ch = webbook_chapters(&source_json, book_url, "", "");
        let ch_ms = t1.elapsed();
        match &ch {
            Ok(s) => {
                let arr: Vec<serde_json::Value> = serde_json::from_str(s).unwrap_or_default();
                eprintln!(
                    "[timing] webbook_chapters {} chapters in {:?} (after info)",
                    arr.len(),
                    ch_ms
                );
                assert!(arr.len() > 20, "思路客首页应有多章，实际 {}", arr.len());
            }
            Err(e) => panic!("chapters err: {e}"),
        }
        eprintln!("[timing] sequential total {:?}", t0.elapsed());
        // 目录阶段应命中详情页短时缓存；解析复用 AnalyzeRule 后通常远快于二次 HTTP
        assert!(
            ch_ms < info_ms + std::time::Duration::from_secs(8),
            "chapters after info unexpectedly slow: info={info_ms:?} chapters={ch_ms:?}"
        );
    }

    #[test]
    fn test_webbook_search_invalid_source_json() {
        let err = webbook_search("not valid json", "关键词", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_info_invalid_source_json() {
        let err = webbook_info("invalid", "https://example.com/book/1").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_chapters_invalid_source_json() {
        let err = webbook_chapters("bad json", "https://example.com/book/1", "", "").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_content_invalid_chapter_json() {
        let err = webbook_content(&make_source_json(), "not json").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_build_engine_creates_real_fetcher() {
        // 验证 build_engine 能正常构建（不 panic）
        let _engine = build_engine().expect("build_engine");
    }

    #[test]
    fn test_real_fetcher_default() {
        // 验证 Default trait 实现
        let _fetcher = RealBookSourceFetcher::default();
    }

    #[test]
    fn test_webbook_search_empty_query_returns_error() {
        // 空关键词应返回解析错误（engine 层校验）
        let err = webbook_search(&make_source_json(), "", 1).unwrap_err();
        assert!(err.to_string().contains("搜索关键词不能为空"));
    }

    #[test]
    fn test_fetch_data_uri_shushan_format() {
        use base64::Engine;
        let detail = r#"{"source":"书山聚合","url":"https://v1.vossc.com/detail?book_id=123"}"#;
        let b64 = base64::engine::general_purpose::STANDARD.encode(detail);
        let url = format!(r#"data:detailsUrl;base64,{},{{"type":"susan"}}"#, b64);
        let result = fetch_data_uri_content(&url);
        match result {
            Some(Ok(body)) => {
                eprintln!("body 前 120: {}", &body[..body.len().min(120)]);
                // 验证是否合法 hex（仅 0-9a-f 且长度为偶数）
                let hex_ok = body.len() % 2 == 0
                    && body.bytes().all(|b| b.is_ascii_hexdigit());
                eprintln!("合法 hex: {}", hex_ok);
            }
            other => eprintln!("fetch_data_uri_content = {:?}", other.map(|r| r.map(|b| b.len()))),
        }
    }

    #[test]
    fn test_webbook_content_empty_chapter_url_returns_error() {
        let chapter_json = serde_json::to_string(&WebChapter::new(0, "第一章", "")).unwrap();
        let err = webbook_content(&make_source_json(), &chapter_json).unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }

    // ─── B1-B3 规则路径增强测试 ───────────────────────────────

    /// 构造带 bookInfo 规则的书源（canReName 可选）
    fn make_info_source(can_re_name: Option<&str>) -> BookSource {
        use legado_core::models::rule::BookInfoRule;
        BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_book_info: Some(BookInfoRule {
                name: Some(".name".to_string()),
                author: Some(".author".to_string()),
                kind: Some(".kind".to_string()),
                word_count: Some(".wc".to_string()),
                cover_url: Some(".cover".to_string()),
                can_re_name: can_re_name.map(|s| s.to_string()),
                ..BookInfoRule::default()
            }),
            ..BookSource::default()
        }
    }

    const INFO_HTML: &str = "<html><body>\
<div class='name'>解析书名</div>\
<div class='author'>解析作者</div>\
<div class='kind'>科幻,悬疑</div>\
<div class='wc'>200万字</div>\
<div class='cover'>/covers/1.jpg</div>\
</body></html>";

    #[test]
    fn test_matches_book_url_pattern() {
        assert!(matches_book_url_pattern(
            r"https://example\.com/book/\d+",
            "https://example.com/book/123"
        ));
        assert!(!matches_book_url_pattern(
            r"https://example\.com/book/\d+",
            "https://example.com/search?q=x"
        ));
        // 非法正则静默返回 false
        assert!(!matches_book_url_pattern("[invalid", "https://example.com"));
    }

    #[test]
    fn test_dedupe_by_book_url_keeps_first() {
        let results = vec![
            WebSearchResult::new("书A", "作者A", "url1", "src"),
            WebSearchResult::new("书A重复", "作者A", "url1", "src"),
            WebSearchResult::new("书B", "作者B", "url2", "src"),
        ];
        let deduped = dedupe_by_book_url(results);
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].name, "书A"); // 保留首次出现
        assert_eq!(deduped[1].book_url, "url2");
    }

    #[test]
    fn test_dedupe_first_by_url() {
        let chapters = vec![
            WebChapter::new(0, "章1", "u1"),
            WebChapter::new(1, "章1重复", "u1"),
            WebChapter::new(2, "章2", "u2"),
        ];
        let deduped = dedupe_first_by_url(chapters);
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].title, "章1");
    }

    #[test]
    fn test_dedupe_last_by_url_keeps_last_preserves_order() {
        let chapters = vec![
            WebChapter::new(0, "章1", "u1"),
            WebChapter::new(1, "章2", "u2"),
            WebChapter::new(2, "章1重复", "u1"),
        ];
        let deduped = dedupe_last_by_url(chapters);
        assert_eq!(deduped.len(), 2);
        // 保留最后一次出现，且保持原相对顺序 → [章2, 章1重复]
        assert_eq!(deduped[0].title, "章2");
        assert_eq!(deduped[1].title, "章1重复");
    }

    #[test]
    fn test_info_to_search_result() {
        let mut info = WebBookInfo::new("三体", "刘慈欣", "url1", "toc1");
        info.kind = Some("科幻".to_string());
        info.word_count = Some("200k".to_string());
        let r = info_to_search_result(info, "https://src");
        assert_eq!(r.name, "三体");
        assert_eq!(r.kind.as_deref(), Some("科幻"));
        assert_eq!(r.word_count.as_deref(), Some("200k"));
        assert_eq!(r.source_url, "https://src");
    }

    #[test]
    fn test_parse_book_info_can_rename_gating() {
        // 规则 canReName 为空 + 已有书名非空 → 不覆盖（保留已有）
        let source = make_info_source(None);
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "已有书名",
            "已有作者",
        );
        assert_eq!(info.name, "已有书名");
        assert_eq!(info.author, "已有作者");

        // 规则 canReName 非空 + can_re_name=true + 已有非空 → 覆盖
        let source2 = make_info_source(Some("true"));
        let info2 = RealBookSourceFetcher::parse_book_info_from_body(
            &source2,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "已有书名",
            "已有作者",
        );
        assert_eq!(info2.name, "解析书名");
        assert_eq!(info2.author, "解析作者");

        // 已有书名为空 → 无论 canReName 均填充
        let info3 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "",
            "",
        );
        assert_eq!(info3.name, "解析书名");
    }

    #[test]
    fn test_parse_book_info_fields_and_absolutize() {
        let source = make_info_source(None);
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "",
            "",
        );
        // kind 原始字符串 + 拆分 categories
        assert_eq!(info.kind.as_deref(), Some("科幻,悬疑"));
        assert_eq!(info.categories, vec!["科幻".to_string(), "悬疑".to_string()]);
        // wordCount
        assert_eq!(info.word_count.as_deref(), Some("200万字"));
        // coverUrl 绝对化
        assert_eq!(
            info.cover_url.as_deref(),
            Some("https://example.com/covers/1.jpg")
        );
        // tocUrl 规则为空时回退 book_url
        assert_eq!(info.toc_url, "https://example.com/book/1");
    }

    #[test]
    fn test_parse_book_info_og_property_suffix() {
        use legado_core::models::rule::BookInfoRule;
        let source = BookSource {
            book_source_url: "http://www.shushun.cc".into(),
            rule_book_info: Some(BookInfoRule {
                name: Some("[property$=book_name]@content".into()),
                author: Some("[property$=author]@content".into()),
                ..BookInfoRule::default()
            }),
            ..BookSource::default()
        };
        let html = r#"<html><head>
<meta property="og:novel:book_name" content="一念永恒">
<meta property="og:novel:author" content="耳根">
</head></html>"#;
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            html.into(),
            "http://www.shushun.cc/read_81/",
            "http://www.shushun.cc/read_81/",
            true,
            "",
            "",
        );
        assert_eq!(info.name, "一念永恒");
        assert_eq!(info.author, "耳根");
        assert_eq!(info.book_url, "http://www.shushun.cc/read_81/");
    }

    // ─── 缺口① nextContentUrl 分页测试（审计 2026-08-06） ─────────────

    const PAGE1_HTML: &str = "<html><body>\
<div class='content'><p>第一页正文</p></div>\
<a class='next' href='/chap/1_2.html'>下一页</a>\
</body></html>";

    const PAGE2_HTML: &str = "<html><body>\
<div class='content'><p>第二页正文</p></div>\
<a class='next' href='/chap/1_3.html'>下一页</a>\
</body></html>";

    /// 第三页 next 指回第一页（构造循环，验证去重终止）
    const PAGE3_HTML: &str = "<html><body>\
<div class='content'><p>第三页正文</p></div>\
<a class='next' href='/chap/1.html'>下一页</a>\
</body></html>";

    /// 首页返回两个下一页 URL（验证多页分支且不递归）
    const PAGE_MULTI_HTML: &str = "<html><body>\
<div class='content'><p>多页首屏正文</p></div>\
<a class='next' href='/chap/2_a.html'>下一页</a>\
<a class='alt' href='/chap/2_b.html'>下一页</a>\
</body></html>";

    #[test]
    fn test_parse_content_page_single_next_url() {
        let (content, next_urls) = parse_content_page(
            PAGE1_HTML.to_string(),
            ".content@html",
            ".next@href",
            "https://example.com/chap/1.html",
            "https://example.com",
            false,
        );
        assert!(content.contains("第一页正文"));
        // 相对 URL 基于本页 URL 绝对化
        assert_eq!(
            next_urls,
            vec!["https://example.com/chap/1_2.html".to_string()]
        );
    }

    #[test]
    fn test_parse_content_page_empty_next_rule() {
        let (_, next_urls) = parse_content_page(
            PAGE1_HTML.to_string(),
            ".content@html",
            "",
            "https://example.com/chap/1.html",
            "https://example.com",
            false,
        );
        assert!(next_urls.is_empty());
    }

    #[test]
    fn test_parse_content_page_media_skips_formatting() {
        // 音视频源：正文原样返回，不走 HTML 净化
        let raw = "https://media.example.com/audio/1.mp3";
        let (content, _) = parse_content_page(
            raw.to_string(),
            "",
            "",
            "https://example.com/chap/1.html",
            "https://example.com",
            true,
        );
        assert_eq!(content, raw);
    }

    /// 视频 MPD 清单：以 `<` 开头须原文透传（normalize_content 识别为 Mpd，不剥标签）
    #[test]
    fn test_parse_content_page_media_mpd_passthrough() {
        let mpd = r#"<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period/></MPD>"#;
        let (content, _) = parse_content_page(
            mpd.to_string(),
            "",
            "",
            "https://example.com/chap/1.html",
            "https://example.com",
            true,
        );
        assert_eq!(content, mpd);
        assert!(
            matches!(
                legado_core::video_state::VideoPlayerState::normalize_content(&content),
                Some(legado_core::video_state::VideoContent::Mpd(_))
            ),
            "钩子：UI 可用 normalize_content 识别 MPD"
        );
    }

    /// 视频空正文：normalize_content 接通后返回空串
    #[test]
    fn test_parse_content_page_media_empty() {
        let (content, _) = parse_content_page(
            "   ".to_string(),
            "",
            "",
            "https://example.com/chap/1.html",
            "https://example.com",
            true,
        );
        assert!(content.is_empty());
    }

    /// 回归（Task #24）：真实 95590 章节页 + 真实书源 ruleContent `.entry-content@html`。
    /// 该书源在实机报「正文为空」，此测试固定真实页面证明解析管线本身能抽到非空正文，
    /// 从而将「正文为空」根因锁定为数据/换源匹配错书（章节 URL 指向异书），而非解析代码 bug。
    #[test]
    fn test_parse_content_page_real_95590_entry_content() {
        let html = include_str!("../../tests/fixtures_95590_ch9.html");
        let (content, _next) = parse_content_page(
            html.to_string(),
            ".entry-content@html",
            "a[rel='next']@href",
            "https://www.95590.org/2014/05/55.html",
            "https://www.95590.org",
            false,
        );
        // 解析管线（CSS `.entry-content@html` + format_keep_img + unescape）应产出非空正文
        assert!(
            !content.trim().is_empty(),
            "真实页面经解析管线不应为空：说明解析代码正常"
        );
        // 校验确实抽到了正文段落文本
        assert!(
            content.contains("陈庆蓉") || content.contains("侯卫东"),
            "应抽取到章节正文段落文本"
        );
    }

    /// 脚本化响应的抓取闭包（离线模拟多页，不走真实网络）
    fn scripted_fetch(
        pages: std::collections::HashMap<String, String>,
    ) -> impl FnMut(
        String,
    )
        -> std::pin::Pin<Box<dyn std::future::Future<Output = LegadoResult<String>> + Send>>
    {
        move |url: String| {
            let body = pages.get(&url).cloned();
            Box::pin(async move {
                body.ok_or_else(|| LegadoError::Network(format!("404 for {url}")))
            })
        }
    }

    fn pagination_pages() -> std::collections::HashMap<String, String> {
        let mut pages = std::collections::HashMap::new();
        pages.insert(
            "https://example.com/chap/1_2.html".to_string(),
            PAGE2_HTML.to_string(),
        );
        pages.insert(
            "https://example.com/chap/1_3.html".to_string(),
            PAGE3_HTML.to_string(),
        );
        pages
    }

    #[test]
    fn test_next_content_url_pagination_concatenates_pages() {
        // 首页解析出下一页 → 串行拓三页（第三页 next 指回首页，去重终止）
        let (first_content, next_urls) = parse_content_page(
            PAGE1_HTML.to_string(),
            ".content@html",
            ".next@href",
            "https://example.com/chap/1.html",
            "https://example.com",
            false,
        );
        let result = runtime::block_on(fetch_paginated_content(
            first_content,
            next_urls,
            "https://example.com/chap/1.html",
            "https://example.com",
            ".content@html",
            ".next@href",

              false,
              None,
              None, // setup_script
              None,
              None,
              None,
              None,
              scripted_fetch(pagination_pages()),
          ));
          // 多页拼接（顺序 + \n 连接）
          let parts: Vec<&str> = result.split('\n').collect();
          assert_eq!(parts.len(), 3);
          assert!(parts[0].contains("第一页正文"));
          assert!(parts[1].contains("第二页正文"));
          assert!(parts[2].contains("第三页正文"));
          // 循环终止：首页正文仅出现一次（next 指回自身被去重拦截）
          assert_eq!(result.matches("第一页正文").count(), 1);
      }

      #[test]
      fn test_pagination_empty_next_rule_stops_at_first_page() {
          let (first_content, next_urls) = parse_content_page(
              PAGE1_HTML.to_string(),
              ".content@html",
              "", // 无 nextContentUrl 规则 → 单页行为不变
              "https://example.com/chap/1.html",
              "https://example.com",
              false,
          );
          let result = runtime::block_on(fetch_paginated_content(
              first_content,
              next_urls,
              "https://example.com/chap/1.html",
              "https://example.com",
              ".content@html",
              "",

              false,
              None,
              None, // setup_script
              None,
              None,
              None,
              None,
              scripted_fetch(pagination_pages()),
          ));
        assert!(result.contains("第一页正文"));
        assert!(!result.contains("第二页正文"));
    }

    #[test]
    fn test_pagination_multi_next_urls_fetch_each_without_recursion() {
        // 首页解析出两个下一页 URL → 各抓一页且不递归（对标原版并发分支 getNextPageUrl=false）
        let mut pages = std::collections::HashMap::new();
        pages.insert(
            "https://example.com/chap/2_a.html".to_string(),
            "<html><body><div class='content'><p>分卷A正文</p></div><a class='next' href='/chap/2_c.html'>下一页</a></body></html>"
                .to_string(),
        );
        pages.insert(
            "https://example.com/chap/2_b.html".to_string(),
            "<html><body><div class='content'><p>分卷B正文</p></div></body></html>"
                .to_string(),
        );
        // 若递归则需抓 2_c.html，此处故意不提供（验证不递归）

        let (first_content, next_urls) = parse_content_page(
            PAGE_MULTI_HTML.to_string(),
            ".content@html",
            ".next@href&&.alt@href",
            "https://example.com/chap/2.html",
            "https://example.com",
            false,
        );
        assert_eq!(next_urls.len(), 2);

        let result = runtime::block_on(fetch_paginated_content(
            first_content,
            next_urls,
            "https://example.com/chap/2.html",
            "https://example.com",
            ".content@html",
            ".next@href&&.alt@href",

            false,
            None,
            None, // setup_script
            None,
            None,
            None,
            None,
            scripted_fetch(pages),
        ));
        let parts: Vec<&str> = result.split('\n').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts[0].contains("多页首屏正文"));
        assert!(parts[1].contains("分卷A正文"));
        assert!(parts[2].contains("分卷B正文"));
    }

    #[test]
    fn test_pagination_max_pages_guard() {
        // 每页 next 都指向新的唯一 URL，验证页数上限保护终止（不死循环）
        let mut pages = std::collections::HashMap::new();
        for i in 1..=(MAX_CONTENT_PAGES + 5) {
            pages.insert(
                format!("https://example.com/p/{i}.html"),
                format!(
                    "<html><body><div class='content'><p>P{i}</p></div><a class='next' href='/p/{}.html'>next</a></body></html>",
                    i + 1
                ),
            );
        }
        let (first_content, next_urls) = parse_content_page(
            "<html><body><div class='content'><p>P0</p></div><a class='next' href='/p/1.html'>next</a></body></html>"
                .to_string(),
            ".content@html",
            ".next@href",
            "https://example.com/p/0.html",
            "https://example.com",
            false,
        );
        let result = runtime::block_on(fetch_paginated_content(
            first_content,
            next_urls,
            "https://example.com/p/0.html",
            "https://example.com",
            ".content@html",
            ".next@href",

            false,
            None,
            None, // setup_script
            None,
            None,
            None,
            None,
            scripted_fetch(pages),
        ));
        let parts: Vec<&str> = result.split('\n').collect();
        assert_eq!(
            parts.len(),
            MAX_CONTENT_PAGES,
            "页数上限保护应截断于 {MAX_CONTENT_PAGES} 页"
        );
    }

    // ─── R1 subContent 单测（Task #134，对标 BookContent.kt L128-165） ─────

    #[test]
    fn test_fetch_sub_content_text_rule_appends_directly() {
        // 规则提取结果非 URL → 直接作为副内容返回，不发起二次请求
        let body = "<html><body><div class='content'>正文</div>\
                    <div class='sub'>作者有话说</div></body></html>";
        let result = runtime::block_on(fetch_sub_content(
            body.to_string(),
            ".sub@html",
            "https://example.com/chap/1.html",
            "https://example.com",
            None,
            |_url: String| async { panic!("文本副内容不应触发二次请求") },
        ));
        assert_eq!(
            result.as_deref(),
            Some("<div class=\"sub\">作者有话说</div>")
        );
    }

    #[test]
    fn test_fetch_sub_content_url_rule_triggers_second_request() {
        // 规则提取结果以 http 开头 → 发起二次请求，以响应体作为副内容
        // （对标 Kotlin AnalyzeUrl(mUrl = it).getStrResponseAwait().body）
        let body = "<html><body><div class='content'>正文</div>\
                    <a class='sublink' href='https://example.com/sub.html'>副</a></body></html>";
        let result = runtime::block_on(fetch_sub_content(
            body.to_string(),
            ".sublink@href",
            "https://example.com/chap/1.html",
            "https://example.com",
            None,
            |url: String| async move {
                assert_eq!(url, "https://example.com/sub.html");
                Ok("远程副内容正文".to_string())
            },
        ));
        assert_eq!(result.as_deref(), Some("远程副内容正文"));
    }

    #[test]
    fn test_fetch_sub_content_second_request_failure_ignored() {
        // 二次请求失败 → 返回 None（对标 Kotlin runCatching：不影响主正文）
        let body = "<html><body><a class='sublink' href='https://example.com/sub.html'>副</a></body></html>";
        let result = runtime::block_on(fetch_sub_content(
            body.to_string(),
            ".sublink@href",
            "https://example.com/chap/1.html",
            "https://example.com",
            None,
            |_url: String| async { Err(LegadoError::Network("500".into())) },
        ));
        assert!(result.is_none());
    }

    #[test]
    fn test_fetch_sub_content_empty_extract_returns_none() {
        // 规则提取结果为空 → 返回 None（无副内容可追加）
        let body = "<html><body><div class='content'>正文</div></body></html>";
        let result = runtime::block_on(fetch_sub_content(
            body.to_string(),
            ".nonexist@html",
            "https://example.com/chap/1.html",
            "https://example.com",
            None,
            |_url: String| async { panic!("空副内容不应触发二次请求") },
        ));
        assert!(result.is_none());
    }

    #[test]
    fn test_merge_sub_content_skips_media_to_protect_play_url() {
        // 视频/音频：副内容不得拼进正文（对齐 putDanmaku / putLyric）
        let mut video_body = "https://cdn.example/v.mp4".to_string();
        merge_sub_content_into_body(&mut video_body, "{\"danmaku\":[]}", true);
        assert_eq!(video_body, "https://cdn.example/v.mp4");

        let mut text_body = "第一章正文".to_string();
        merge_sub_content_into_body(&mut text_body, "作者有话说", false);
        assert_eq!(text_body, "第一章正文\n作者有话说");
    }

    // ─── R2 replaceRegex 单测（Task #134，对标 BookContent.kt L166-175） ────

    #[test]
    fn test_split_rule_replace_parts_syntax() {
        // 对标 AnalyzeRule.makeUpRule L819-829 的 ## 四段拆分
        let (base, rep) = split_rule_replace_parts(".content@html");
        assert_eq!(base, ".content@html");
        assert!(rep.is_none());

        let (base, rep) = split_rule_replace_parts("##广告##");
        assert_eq!(base, "");
        assert_eq!(rep, Some(("广告", "", false)));

        let (_, rep) = split_rule_replace_parts(".c@html##pat##rep");
        assert_eq!(rep, Some(("pat", "rep", false)));

        // 第四段存在（即使为空）→ replaceFirst=true
        let (_, rep) = split_rule_replace_parts("##pat##rep##");
        assert_eq!(rep, Some(("pat", "rep", true)));
    }

    #[test]
    fn test_apply_regex_replace_full_text() {
        // 全文替换分支（对标 result.replace(regex, replacement)）
        assert_eq!(
            apply_regex_replace("广告1正文广告2", "广告\\d", "", false),
            "正文"
        );
    }

    #[test]
    fn test_apply_regex_replace_capture_group() {
        // replacement 支持 $1 捕获组引用
        assert_eq!(
            apply_regex_replace("第1章 第2章", "第(\\d+)章", "Chapter $1", false),
            "Chapter 1 Chapter 2"
        );
    }

    #[test]
    fn test_apply_regex_replace_replace_first() {
        // replaceFirst 分支：仅取首个匹配段做替换
        // （对标 matcher.group(0).replaceFirst(regex, replacement)）
        assert_eq!(apply_regex_replace("aa bb aa", "aa", "X", true), "X");
        // 无匹配 → 返回空串
        assert_eq!(apply_regex_replace("bb cc", "aa", "X", true), "");
    }

    #[test]
    fn test_apply_regex_replace_invalid_regex_fallback() {
        // 正则非法降级字面量替换（对标 Kotlin runCatching 回退）
        assert_eq!(
            apply_regex_replace("a[unclosed b", "[unclosed", "X", false),
            "aX b"
        );
        // replaceFirst + 正则非法 → 直接返回 replacement（对标原版）
        assert_eq!(apply_regex_replace("abc", "[bad", "X", true), "X");
    }

    #[test]
    fn test_apply_content_replace_regex_trims_lines_then_replaces() {
        // 对标 BookContent.kt：先逐行 trim 再执行替换规则
        let result = apply_content_replace_regex(
            "  第一行  \n  第二行广告  ".to_string(),
            "##广告##",
            "https://example.com/c.html",
            "https://example.com",
            None,
        )
        .unwrap();
        assert_eq!(result, "第一行\n第二行");
    }

    #[test]
    fn test_apply_content_replace_regex_with_base_rule() {
        // 基础规则非空：先按规则提取再替换（纯替换规则场景基础规则为空见上例）
        let result = apply_content_replace_regex(
            "广告前<div class='c'>正文广告</div>广告后".to_string(),
            ".c@text##广告##",
            "https://example.com/c.html",
            "https://example.com",
            None,
        )
        .unwrap();
        assert_eq!(result, "正文");
    }

    // ─── jsLib 注入正文链路（2026-08-10 | Reasonix） ─────────────────────
    // 漫画/视频源 ruleContent 常以 `<js>eval(String(Reload('...')))</js>` 引用
    // jsLib 定义的函数；正文解析必须注入 jsLib，否则 JS 抛错 → 正文为空。

    #[test]
    fn test_parse_content_page_with_js_lib_resolves_lib_function() {
        // 原版语义：jsLib 的 Reload(url) 网络加载远端 JS 代码串并返回，
        // 模板 `<js>eval(String(Reload('...')))</js>` 执行该代码取回 URL 字面量
        let js_lib = "function Reload(u) { return 'String(\"https://img.example.com/p1.jpg\")'; }";
        let rule = "<js>eval(String(Reload('https://cdn.example.com/loader.js')))</js>";
        let (content, _) = parse_content_page_with_js_lib(
            "<html><body>忽略</body></html>".to_string(),
            rule,
            "",
            "https://manga.example.com/chapter/1.html",
            "https://manga.example.com",
            false,
            Some(js_lib),
            None,
        );
        assert!(
            content.contains("https://img.example.com/p1.jpg"),
            "jsLib 注入后应解析出图片地址，实际: {content}"
        );
    }

    #[test]
    fn test_parse_content_page_without_js_lib_degrades() {
        // 无 jsLib（旧行为）时库函数未定义 → 模板求值失败 → 无库调用结果。
        // 注意：source_tag 须与注入测试不同（引擎按 tag 复用，jsLib 副作用残留）
        let rule = "<js>eval(String(Reload('https://img.example.com/p1.jpg')))</js>";
        let (content, _) = parse_content_page_with_js_lib(
            "<html><body>忽略</body></html>".to_string(),
            rule,
            "",
            "https://manga.example.com/chapter/1.html",
            "no_js_lib_tag.example.com",
            false,
            None,
            None,
        );
        assert!(
            !content.contains("img.example.com"),
            "无 jsLib 时不应解析出库函数结果，实际: {content}"
        );
    }

    /// 离线：伪七猫 play HTML + @js 规则应抽出 m3u8
    #[test]
    fn qmao_js_rule_extracts_m3u8_from_saved_html() {
        let html_path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../flutter_legado/_debug_db/qmao_play_full.html"
        );
        let html = std::fs::read_to_string(html_path).expect("qmao_play_full.html");
        let json = include_str!("../../tests/fixtures/qmao_min_source.json");
        let source: BookSource = serde_json::from_str(json).unwrap();
        let rule = source
            .rule_content
            .as_ref()
            .and_then(|r| r.content.as_deref())
            .unwrap();
        let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
            html,
            "https://www.qmao.net/vodplay/27017-1-1.html".into(),
            "https://www.qmao.net",
            None,
        );
        let out = match analyzer.get_string(rule) {
            Ok(s) => s,
            Err(e) => panic!("get_string err: {e}"),
        };
        eprintln!("offline js out={out}");
        assert!(
            out.contains(".m3u8") || out.contains(".mp4"),
            "js rule should extract media url, got: {out}"
        );
    }

    /// 网络冒烟：伪七猫 play 页 @js 抽出 m3u8（验证 VIDEO 正文不被污染）
    #[test]
    #[ignore = "network smoke: qmao video content"]
    fn qmao_video_content_smoke() {
        let json = include_str!("../../tests/fixtures/qmao_min_source.json");
        let source: BookSource = serde_json::from_str(json).expect("source json");
        assert_eq!(source.book_source_type, book_source_type::VIDEO);

        let chapter = WebChapter {
            index: 0,
            title: "第1集".into(),
            url: "https://www.qmao.net/vodplay/27017-1-1.html".into(),
            is_vip: false,
            is_volume: false,
            variable: None,
        };
        let content = webbook_content(json, &serde_json::to_string(&chapter).unwrap())
            .expect("webbook_content");
        eprintln!(
            "qmao content len={} head={}",
            content.len(),
            &content[..content.len().min(180)]
        );
        let first = content.lines().next().unwrap_or("").trim();
        assert!(
            first.contains(".m3u8") || first.contains(".mp4"),
            "expected media url first line, got: {content}"
        );
        assert!(
            !content.contains("player_aaaa"),
            "raw html must not leak into play content"
        );
    }

    #[test]
    fn test_sniff_source_regex_url_from_html() {
        let html = r#"<html><body>
            <script src="/player.js"></script>
            <video src="https://cdn.example.com/a.m3u8?token=1"></video>
            </body></html>"#;
        let hit = sniff_source_regex_url(html, r".*\.m3u8.*").expect("should sniff");
        assert!(hit.contains(".m3u8"), "hit={hit}");
    }

    #[test]
    fn test_apply_content_web_hooks_source_regex() {

        let html = r#"<a href="https://cdn.example.com/v.mp4">play</a>"#;
        let rule = ContentRule {
            source_regex: Some(r".*\.mp4.*".into()),
            ..ContentRule::default()
        };
        let out = apply_content_web_hooks(
            html.into(),
            Some(&rule),
            "https://example.com/c",
            "https://example.com",
            None,
        );
        assert_eq!(out, "https://cdn.example.com/v.mp4");
    }
}
