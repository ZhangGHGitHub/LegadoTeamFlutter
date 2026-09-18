//! WebBook FFI API
//!
//! 为 Flutter/Dart 提供书源驱动的搜索、目录、内容获取能力。
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。
//!
//! 使用 `RealBookSourceFetcher`（LegadoClient + AnalyzeUrl + AnalyzeRule）
//! 实现完整的搜索→详情→目录→正文链路。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use legado_core::models::BookSource;
use legado_core::models::{Book, BookChapter};
use legado_core::web_book::{
    BookSourceFetcher, WebBookEngine, WebBookInfo, WebChapter, WebSearchResult,
};
use legado_core::{LegadoError, LegadoResult};
use legado_js::js_source::js_source_book::JsSourceBookOrchestrator;
use legado_js::JsSourceConfig;
use legado_net::LegadoClient;
use legado_parser::{compile_regex_safe, AnalyzeUrl, RequestMethod};

/// 对齐原版 OkHttpUtils.ResponseBody.text：显式 charset 优先，随后 HTTP 头，最后 HTML meta。
fn decode_web_response(
    bytes: &[u8],
    headers: &HashMap<String, String>,
    explicit: Option<&str>,
) -> String {
    let charset = explicit
        .filter(|s| !s.trim().is_empty())
        .map(str::to_string)
        .or_else(|| charset_from_content_type(headers))
        .or_else(|| charset_from_html_meta(bytes));
    AnalyzeUrl::decode_response_bytes(bytes, charset.as_deref())
}

fn charset_from_content_type(headers: &HashMap<String, String>) -> Option<String> {
    let value = headers
        .iter()
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
    )
    .ok()?;
    for tag in meta_re.find_iter(&head).map(|m| m.as_str()) {
        let mut attrs: HashMap<String, String> = HashMap::new();
        for caps in attr_re.captures_iter(tag) {
            let name = caps
                .get(1)
                .map(|m| m.as_str().to_ascii_lowercase())
                .unwrap_or_default();
            let value = caps
                .get(2)
                .or_else(|| caps.get(3))
                .or_else(|| caps.get(4))
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
            attrs.insert(name, value);
        }
        if let Some(charset) = attrs.get("charset").filter(|v| !v.trim().is_empty()) {
            return Some(charset.trim().to_string());
        }
        let is_content_type = attrs
            .get("http-equiv")
            .is_some_and(|v| v.eq_ignore_ascii_case("content-type"));
        if is_content_type {
            if let Some(cs) = attrs
                .get("content")
                .and_then(|v| extract_charset_assignment(v))
            {
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
        self.entries
            .retain(|_, (t, _)| now.duration_since(*t) < PAGE_BODY_CACHE_TTL);
        self.entries.get(url).map(|(_, b)| b.clone())
    }

    fn put(&mut self, url: &str, body: String) {
        let now = Instant::now();
        self.entries
            .retain(|_, (t, _)| now.duration_since(*t) < PAGE_BODY_CACHE_TTL);
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
    page_body_cache().lock().ok().and_then(|mut c| c.get(url))
}

fn cache_put_page_body(url: &str, body: &str) {
    if let Ok(mut c) = page_body_cache().lock() {
        c.put(url, body.to_string());
    }
}

// ─── P2-9 ② book 绑定扩面：BookMeta 进程级缓存 ────────────────────────────────
//
/// book 绑定扩面元信息（P2-9 ②）
///
/// 对齐上游 `Book`/`BaseBook` 字段面（Book.kt:122/146-148/206-212、
/// BaseBook.kt:19-31）：无状态 FFI 无法跨调用携带 Book 对象，用 URL 键
/// 进程级缓存承接详情/目录阶段 → 正文阶段的元信息流转：
/// - `webbook_info` 记录详情信息（name/author/tocUrl/lastChapter/variable）
/// - `webbook_chapters` 记录目录（章节 URL → book URL 映射 + lastChapter）
/// - `webbook_content` 按章节 URL 反查 meta，构造带字段的 `book` 绑定
#[derive(Clone, Debug, Default)]
struct BookMeta {
    name: String,
    author: String,
    book_url: String,
    toc_url: String,
    last_chapter: String,
    /// 规则变量 JSON（Map<String,Any> 序列化字符串，如 `{"custom":"x"}`；
    /// 对齐 WebBookInfo.variable / Book.variable，RuleDataInterface.kt:7-34）
    variable: Option<String>,
}

/// book 元信息缓存容量（bookUrl 键；溢出即整体清空——降级 LRU 为全量
/// 淘汰，与 PageBodyCache 的简单淘汰策略一致）
const BOOK_META_CACHE_MAX: usize = 512;
/// 章节 URL → book URL 映射缓存容量（溢出整体清空）
const CHAPTER_BOOK_CACHE_MAX: usize = 8192;

fn book_meta_cache() -> &'static Mutex<HashMap<String, BookMeta>> {
    static CACHE: OnceLock<Mutex<HashMap<String, BookMeta>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn chapter_book_cache() -> &'static Mutex<HashMap<String, String>> {
    static CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 按字段合并写入：新值非空覆盖，空字段保留旧值（详情/目录两阶段各自
/// 只掌握部分字段，互不冲掉）
fn book_meta_merge_insert(map: &mut HashMap<String, BookMeta>, key: String, patch: BookMeta) {
    if map.len() >= BOOK_META_CACHE_MAX {
        map.clear();
    }
    let entry = map.entry(key).or_default();
    if !patch.name.is_empty() {
        entry.name = patch.name;
    }
    if !patch.author.is_empty() {
        entry.author = patch.author;
    }
    if !patch.book_url.is_empty() {
        entry.book_url = patch.book_url;
    }
    if !patch.toc_url.is_empty() {
        entry.toc_url = patch.toc_url;
    }
    if !patch.last_chapter.is_empty() {
        entry.last_chapter = patch.last_chapter;
    }
    if patch.variable.is_some() {
        entry.variable = patch.variable;
    }
}

/// webbook_info：详情解析完成后记录 book 元信息（键 = 入参 bookUrl 原样）
///
/// P1-1：variable 优先取 DB `books.variable`（用户书籍变量，Dart 书籍
/// 信息页可编辑、持久化）；DB 无值/为空时回退 `@put`/putVariable 导出值
/// （info.variable，书源规则分析期默认值）。优先级理由：用户显式设置
/// 覆盖书源默认导出。
fn record_book_meta_from_info(book_url: &str, info: &WebBookInfo) {
    if book_url.trim().is_empty() {
        return;
    }
    let variable = db_book_variable(book_url).or_else(|| info.variable.clone());
    let meta = BookMeta {
        name: info.name.trim().to_string(),
        author: info.author.trim().to_string(),
        book_url: if info.book_url.trim().is_empty() {
            book_url.to_string()
        } else {
            info.book_url.trim().to_string()
        },
        toc_url: info.toc_url.trim().to_string(),
        last_chapter: info.last_chapter.clone().unwrap_or_default(),
        variable,
    };
    if let Ok(mut map) = book_meta_cache().lock() {
        book_meta_merge_insert(&mut map, book_url.to_string(), meta);
    }
}

/// webbook_chapters：目录解析完成后记录 book 元信息 + 章节 → book 映射
///
/// `last_chapter` 取最后一个非卷章标题（对齐 Book.lastChapter 语义）；
/// 章节 URL 含空 URL 回退（= 目录页 URL）与卷章合成 URL，全部入映射，
/// 正文阶段按章节 URL 原样反查即可命中。
fn record_chapter_list_cache(
    book_url: &str,
    toc_url: &str,
    name: &str,
    author: &str,
    chapters: &[WebChapter],
) {
    if book_url.trim().is_empty() {
        return;
    }
    let last = chapters
        .iter()
        .rev()
        .find(|c| !c.is_volume)
        .map(|c| c.title.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_default();
    let meta = BookMeta {
        name: name.trim().to_string(),
        author: author.trim().to_string(),
        book_url: book_url.to_string(),
        toc_url: toc_url.trim().to_string(),
        last_chapter: last,
        // P1-1：目录阶段也按 bookUrl 补 DB 用户变量；DB 无值 → None，
        // merge 语义保留详情阶段已记录的 @put 导出值（不冲掉）
        variable: db_book_variable(book_url),
    };
    if let Ok(mut map) = book_meta_cache().lock() {
        book_meta_merge_insert(&mut map, book_url.to_string(), meta);
    }
    if let Ok(mut map) = chapter_book_cache().lock() {
        if map.len() >= CHAPTER_BOOK_CACHE_MAX {
            map.clear();
        }
        for ch in chapters {
            if !ch.url.trim().is_empty() {
                map.insert(ch.url.clone(), book_url.to_string());
            }
        }
    }
}

/// 按 bookUrl 原样查 book 元信息（目录解析前合并详情阶段的 variable 等字段）
fn lookup_book_meta_by_book_url(book_url: &str) -> Option<BookMeta> {
    book_meta_cache().lock().ok()?.get(book_url).cloned()
}

/// webbook_content：按章节 URL 反查 book 元信息
///
/// 章节 URL → book URL（目录阶段映射）→ BookMeta（详情/目录阶段记录）。
/// 未命中（未走详情/目录 FFI 调用，或缓存已淘汰）返回 None：正文阶段
/// 回退既有空 name 字面量绑定语义，不破坏既有书源。
fn lookup_book_meta_for_chapter(chapter_url: &str) -> Option<BookMeta> {
    let book_url = chapter_book_cache()
        .lock()
        .ok()?
        .get(chapter_url)
        .cloned()?;
    book_meta_cache().lock().ok()?.get(&book_url).cloned()
}

/// P1-1：按 bookUrl 读用户书籍变量（DB `books.variable`）
///
/// Dart 书籍信息页可编辑的书籍变量持久化在 `books.variable`（reader.rs
/// 规则变量合并有同一读回先例）；进程级 BookMeta 缓存只能承载规则分析期
/// `@put`/putVariable 导出的值，生产上拿不到用户值（`ruleBookInfo.init` 里
/// `book.getVariable(...)` 永远返回空 → 按变量分支的行为不可达）。
///
/// 优先级：DB（用户显式设置、持久）> `@put` 导出（书源规则默认值）——
/// 用户设置应覆盖书源默认。
///
/// [P2-12] 入参为「书籍页取址点」（Dart `BookOpenUtils.bookFetchUrl` /
/// Rust `book_page_fetch_url` 的产物：originBookUrl 优先、空回退 bookUrl）：
/// 未换源书 = bookUrl 原样（`find_by_url` 直接命中）；换源后 = originBookUrl
/// （稳定主键 bookUrl 仍为旧源 URL，`find_by_url` 漏查 → 按
/// `find_by_origin_book_url` 反查补上）。
///
/// DB 未初始化 / 无此书行 / 值为空 → None（优雅降级：FFI 详情/目录链路
/// 在未接库时依旧可用），调用方回退 `@put` 导出值。
fn db_book_variable(book_url: &str) -> Option<String> {
    crate::db_state::with_database(|db| {
        let repo = legado_db::BookRepository::new(db.connection());
        // 两路反查：先按稳定主键 bookUrl（未换源书直接命中），再按
        // originBookUrl（换源后书籍：Dart 取址点以 originBookUrl 优先传入，
        // 稳定主键 bookUrl 仍为旧源 URL，单路 find_by_url 会漏查）
        let found = match repo.find_by_url(book_url)? {
            Some(book) => Some(book),
            None => repo.find_by_origin_book_url(book_url)?,
        };
        Ok(found.and_then(|b| b.variable))
    })
    .ok()
    .flatten()
    .filter(|v| !v.trim().is_empty())
}

/// P2-9 ②：构造 `book` 绑定 JS 表达式（经 AnalyzeRule 前置注入
/// `globalThis.book = <expr>`）
///
/// - `Some(meta)`：IIFE 对象，字段面对齐上游 Book.kt:122/146-148/206-212
///   （name/author/bookUrl/tocUrl/lastChapter/variable）+ 方法面
///   （getVariable/putVariable/getCustomVariable/putCustomVariable 对齐
///   RuleDataInterface.kt:7-34；`setType` 为本扩展、上游无同名方法；
///   `setReverseToc` 为脚本内标志降级——不持久化到 Book 模型，已文档化）。
/// - `None`：逐字保留既有字面量语义（content 站点 `{"totalChapterNum":N,
///   "name":""}` / toc 站点 `{"name":…}`），不破坏未走详情/目录阶段的源。
fn book_binding_expr(
    meta: Option<&BookMeta>,
    fallback_name: &str,
    total_chapter_num: i32,
    content_site: bool,
) -> String {
    match meta {
        Some(m) => iife_book_expr(m, total_chapter_num),
        None if content_site => {
            format!("{{\"totalChapterNum\": {total_chapter_num}, \"name\": \"\"}}")
        }
        None => serde_json::json!({ "name": fallback_name }).to_string(),
    }
}

/// `book` 绑定 IIFE 模板（占位符替换；占位符串在正常书名/变量值中
/// 不可能出现，替换安全）
const BOOK_BINDING_IIFE: &str = r#"(function(){var b={name:__NAME__,author:__AUTHOR__,bookUrl:__BOOK_URL__,tocUrl:__TOC_URL__,lastChapter:__LAST__,variable:__VARIABLE__,totalChapterNum:__TOTAL__,type:0,reverseToc:false};b.getVariable=function(k){var m=null;try{if(b.variable){m=JSON.parse(b.variable)||{};}}catch(e){m=null;}if(!m){return '';}var v=m[k];return (v===undefined||v===null)?'':String(v);};b.putVariable=function(k,v){var m=null;try{if(b.variable){m=JSON.parse(b.variable)||{};}}catch(e){m=null;}if(m===null){m={};}if(v===null||v===undefined){delete m[k];}else{m[k]=(typeof v==='string')?v:JSON.stringify(v);}b.variable=JSON.stringify(m);return true;};b.putCustomVariable=function(v){return b.putVariable('custom',v);};b.getCustomVariable=function(){return b.getVariable('custom');};b.setType=function(t){b.type=t;};b.setReverseToc=function(f){b.reverseToc=!!f;};return b;})()"#;

fn iife_book_expr(meta: &BookMeta, total_chapter_num: i32) -> String {
    let json_str = |s: &str| serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string());
    let variable = match &meta.variable {
        Some(v) if !v.trim().is_empty() => {
            serde_json::to_string(v).unwrap_or_else(|_| "null".to_string())
        }
        _ => "null".to_string(),
    };
    BOOK_BINDING_IIFE
        .replace("__NAME__", &json_str(&meta.name))
        .replace("__AUTHOR__", &json_str(&meta.author))
        .replace("__BOOK_URL__", &json_str(&meta.book_url))
        .replace("__TOC_URL__", &json_str(&meta.toc_url))
        .replace("__LAST__", &json_str(&meta.last_chapter))
        .replace("__VARIABLE__", &variable)
        .replace("__TOTAL__", &total_chapter_num.to_string())
}

/// P2-9 ②：详情（ruleBookInfo）阶段 `book` 绑定表达式：meta 命中 → IIFE
/// 扩面（getVariable/putVariable 等依赖，如 聚合书库 `ruleBookInfo.init`
/// 的 `book.getVariable("custom")` 读用户设置的换源变量）；未命中 → 回退
/// 既有 `{"name": fallback_name}` 字面量（原 HEAD 详情阶段无 `book` 绑定，
/// JS `book.*` 引用抛 ReferenceError，init 规则被 `if let Ok` 静默跳过；
/// 字面量令引用本身合法、方法调用同样降级，执行路径与原先一致）。
fn detail_book_binding(book_url: &str, fallback_name: &str) -> String {
    let meta = lookup_book_meta_by_book_url(book_url);
    book_binding_expr(meta.as_ref(), fallback_name, 0, false)
}

/// P2-9 ①：把「顶层原始响应内容」以 JSON 字面量注入 JS 全局 `src`，使单参
/// `java.getStringList(rule)` / `java.getString(rule)` / `java.getElements(rule)`
/// 的 content 回退重解析**顶层 content**——对齐上游 `AnalyzeRule.evalJS` 的
/// `bindings["src"] = content`（AnalyzeRule.kt L893+）与单参
/// `getStringList(rule, null)` 的 `mContent ?: this.content`（L215/L319）：
/// 上游规则步循环只更新局部 `result`、从不改 `this.content`，故多步链
/// （CSS 行 + `@js:` 行）的 JS 子步里单参 java.* 仍重解析**原始响应体**
/// （艾格动漫 intro 规则靠它取 `.nav-pills…@text` 线路列表）。
///
/// 机制：解析器 prologue 先注入 `globalThis.src = <子分析器 content>`
/// （链式子步 = 中间产物），随后按 `js_bindings` 逐条注入
/// `globalThis.{name} = {value}`——本绑定排在 `src` 行之后、覆盖之；
/// 绑定随 `js_bindings` 传播到链上子分析器（`eval_js_chain_steps` /
/// `run_js_steps_threaded` 的 `sub.add_js_binding`），子步同样看到原始内容。
/// 非链式执行时两处同值，行为不变。
///
/// 仅用于 content 稳定的顶层分析器（详情 / 目录列表 / 目录分页 / 正文 /
/// 搜索响应体）；**逐章 elem_analyzer 不套用**——其顶层 content 即章节
/// 元素 JSON（prologue `src` 行已与上游等价），逐元素链式子步仍见中间
/// 产物，作为已文档化残差（见交付报告 ④）。
fn bind_orig_src(
    analyzer: legado_parser::AnalyzeRule,
    content: &str,
) -> legado_parser::AnalyzeRule {
    let json = serde_json::to_string(content).unwrap_or_default();
    analyzer.with_js_binding("src", &json)
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

use crate::api::source_rate_limit::acquire_source_rate_limit;

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
        Ok(self.fetch_page(analyze_url, source_headers).await?.body)
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
            body: decode_web_response(&response.body, &response.headers, analyze_url.charset()),
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
    pub(crate) fn execute_login_check(
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
                    Err(crate::js_executor::LoginCheckError::NotLoggedIn(_)) => {
                        Err(LegadoError::LoginRequired(
                            "书源需要登录，请先在书源菜单中登录后重试".into(),
                        ))
                    }
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
    pub(crate) fn parse_book_info_from_body(
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
        // P2-9 ②：book 绑定扩面（详情阶段）：meta 命中 → IIFE（getVariable/
        // putVariable 等依赖，见 detail_book_binding 注释）；未命中 → 既有
        // `{"name": existing_name}` 字面量（webbook_info 入参为 ""，换源
        // 路径带既有书名），执行路径与原 HEAD 一致
        analyzer = analyzer.with_js_binding("book", &detail_book_binding(book_url, existing_name));

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

        // P2-9 ①：src = 最终 content（原始 body 或 init 结果 setContent 后的
        // 新 content）；多步链子步里单参 java.* 重解析该 content（见
        // bind_orig_src 注释，对齐上游 this.content 不被链更新）
        let final_content = analyzer.content().to_string();
        analyzer = bind_orig_src(analyzer, &final_content);

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
            // [T3 | AnalyzeRule.putVariable] bookInfo 规则求值期间 @put/JS
            // putVariable 级联导出（与目录解析 web_book.rs 同一手法），随
            // WebBookInfo 返回供换源合并进 book.variable
            variable: analyzer.export_variables_json(),
        }
    }

    /// 获取章节列表（可选传入已知 tocUrl / 书名，跳过重复拉详情页）
    ///
    /// 变量表为空（搜索候选预览路径不携变量）；变量链（DB `books.variable`）
    /// 走 trait 方法 [`BookSourceFetcher::get_chapters_with_hints_and_vars`]
    /// （P2-12，2026-09-18 自第二具体 impl 块提升为 trait 方法后，本方法
    /// 恢复为薄委托）。
    pub async fn get_chapters_with_hints(
        &self,
        source: &BookSource,
        book_url: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
    ) -> LegadoResult<Vec<WebChapter>> {
        self.get_chapters_with_hints_and_vars(
            source,
            book_url,
            known_toc_url,
            book_name_hint,
            &std::collections::HashMap::new(),
        )
        .await
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
            let info =
                Self::parse_book_info_from_body(source, body, &base_url, &base_url, true, "", "");
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
        // P2-9 ①：src = 搜索响应体（bookList 顶层分析器；单参 java.* 回退
        // 重解析原始 body，见 bind_orig_src 注释）
        let body_src_json = serde_json::to_string(&body).unwrap_or_default();
        let analyzer = crate::js_executor::construct_analyzer_with_source_context(
            body.clone(),
            base_url.clone(),
            &source.book_source_url,
            search_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        )
        .with_js_binding("src", &body_src_json);

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
            let info =
                Self::parse_book_info_from_body(source, body, &base_url, &base_url, true, "", "");
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
        self.get_book_info_with_existing(source, book_url, true, "", "")
            .await
    }

    /// 带既有书籍上下文的详情获取（换源 T2，2026-09-03）
    ///
    /// `can_re_name` / `existing_name` / `existing_author` 透传给
    /// [`Self::parse_book_info_from_body`] 的 B2.1 双条件重命名门控：
    /// 原版 changeSource 的 getBookInfoAwait 传 canReName=false → 保留既有
    /// 书名/作者，仅 cover/intro/kind/lastChapter/wordCount 等按解析值更新。
    async fn get_book_info_with_existing(
        &self,
        source: &BookSource,
        book_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
    ) -> LegadoResult<WebBookInfo> {
        self.get_book_info_with_existing_and_vars(
            source,
            book_url,
            can_re_name,
            existing_name,
            existing_author,
            &std::collections::HashMap::new(),
        )
        .await
    }

    /// 带变量表的详情获取（换源变量链 R1，2026-09-06）
    ///
    /// 对齐原版 getBookInfoAwait：详情请求 AnalyzeUrl 以 `ruleData = book`
    /// 构建（WebBook.kt:225-231），bookUrl 的 `{{key}}` 模板与 `,{json}` 请求
    /// 选项用 book.variable 展开。换源调用方传入候选搜索期变量。
    async fn get_book_info_with_existing_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
        variables: &std::collections::HashMap<String, String>,
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
        let analyze_book = legado_parser::AnalyzeUrl::parse(book_url, variables, 1)
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

        // 2. 使用 bookInfo 规则解析（canReName/existing 由调用方决定：
        //    无状态入口传 true/空 → 解析值直接生效；换源传 false/既有值 → 门控）
        let t_parse = std::time::Instant::now();
        let info = Self::parse_book_info_from_body(
            source,
            body,
            book_url,
            book_url,
            can_re_name,
            existing_name,
            existing_author,
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

    /// 带变量表的目录获取（换源变量链 R1，2026-09-06）
    ///
    /// [方案 A 语义修订 2026-09-17] `toc_url` 是**已解析的真实目录页 URL**
    /// （如换源 2a 详情解析出的 toc_url；目录在详情页时可传详情 URL）：
    /// 直接经 AnalyzeUrl 抓取该目录页（保留「url,{json}」请求选项与
    /// `{{key}}` 变量模板展开），并对响应体跑 ruleToc；不再把入参当
    /// book_url 经 bookUrl → init → tocUrl 重推目录地址。
    ///
    /// 旧实现把入参当 book_url 走详情路径：入参为目录页 URL（换源场景）时
    /// 目录体上 ruleBookInfo.init 求值空 → tocUrl 规则重推出空值地址（如
    /// 松鹤 all-chapter?bookId=）→ 服务端 422 → 0 章 → 换源报「新书源
    /// 未解析到任何章节」（换源第二断点，2026-09-17 实测确证）。
    async fn get_chapters_with_vars(
        &self,
        source: &BookSource,
        toc_url: &str,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        self.get_chapters_from_known_toc_and_vars(source, toc_url, variables)
            .await
    }

    /// 带变量表 + 书名提示的目录获取（换源回归 P2-2，2026-09-17）
    ///
    /// 真实实现：hint 注入 `@js:[{title: book.name, …}]` 类 chapterList
    /// 规则的 `book` 绑定（上游 BookChapterList.kt:196 `AnalyzeRule(book,
    /// bookSource)` 语义）；None 退化为无 hint 行为。
    async fn get_chapters_with_vars_and_name_hint(
        &self,
        source: &BookSource,
        toc_url: &str,
        variables: &std::collections::HashMap<String, String>,
        book_name_hint: Option<&str>,
    ) -> LegadoResult<Vec<WebChapter>> {
        self.get_chapters_from_known_toc_and_vars_with_hint(
            source,
            toc_url,
            variables,
            book_name_hint,
        )
        .await
    }

    async fn get_content(&self, source: &BookSource, chapter: &WebChapter) -> LegadoResult<String> {
        acquire_source_rate_limit(source).await;
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求章节页面（章节 URL 可能是「url,{json}」带请求选项的格式，
        //    如七猫 qmGetUrl 生成 https://.../chapter/content?id=...,
        //    {"method":"GET","headers":{...}}：必须经 AnalyzeUrl 解析出
        //    url/method/headers，直接 GET 会把 ,{json} 拼进请求 → 正文失败）
        //    [T4 | AnalyzeUrl.kt:412-413] 变量表取自章节 variable（reader/audio
        //    链路已合并 book 级变量，章节优先）——空表会使 {{token}} 类变量
        //    无法展开，是换源后正文错误的内容链根因（R3）
        let url_vars = chapter_url_variables(chapter.variable.as_deref());
        let analyze_chapter = legado_parser::AnalyzeUrl::parse(&chapter.url, &url_vars, 1)
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
        let is_media = source.book_source_type
            == legado_core::models::book_source::book_source_type::AUDIO
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
        // P2-9 ②：反查详情/目录阶段记录的 book 元信息 → `book` 绑定扩面
        // （name/author/bookUrl/tocUrl/lastChapter/variable + 方法）；
        // 未命中时回退既有空 name 字面量（行为不变）
        let mut book_meta = lookup_book_meta_for_chapter(&chapter.url);
        // P1-1：缓存 meta 有值但 variable 缺失/为空（记录点未补到、或缓存
        // 早于用户后来设置的变量）→ 按 bookUrl 从 DB 补
        if let Some(m) = book_meta.as_mut() {
            if m.variable.as_deref().is_none_or(|v| v.trim().is_empty()) {
                m.variable = db_book_variable(&m.book_url);
            }
        }
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
            book_meta.as_ref(),
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
            book_meta.as_ref(),
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

    /// 带变量表的目录获取核心（换源变量链 R1，2026-09-06；trait 提升 P2-12，2026-09-18）
    ///
    /// 真实实现覆盖 [`BookSourceFetcher::get_chapters_with_hints_and_vars`]
    /// （原私有具体方法，2026-09-18 提升为 trait 方法使 `webbook_chapters`
    /// 规则路径与 `refresh_toc` 能经泛型/引擎注入 DB `books.variable`）。
    ///
    /// 对齐原版 getChapterListAwait：目录/详情请求 AnalyzeUrl 以 `ruleData = book`
    /// 构建（WebBook.kt:312-318），tocUrl/bookUrl 的 `{{key}}` 模板与 `,{json}`
    /// 请求选项用 book.variable（换源时=候选 ⊕ 详情导出合并值）展开。
    async fn get_chapters_with_hints_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
        variables: &std::collections::HashMap<String, String>,
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

        let mut book_name = book_name_hint.unwrap_or("").trim().to_string();

        // 对齐原版 WebBook.getChapterListAwait：直接使用 book.tocUrl 拉目录，
        // 不必每次都先解析详情页（发现/搜索带入 tocUrl 时可省一次 HTTP）。
        // 注意：known_toc_url == book_url（详情页 URL，发现列表 Book 未解析出
        // tocUrl 时的默认值）不算有效目录地址——七猫等书源的 tocUrl 由详情
        // 规则（qmBookInfo）动态生成，直接当目录请求会得到详情响应而非
        // chapter-list → qmToc 无 chapter_lists → 目录空（2026-08-15 用户反馈）。
        //
        // [方案 A 提取 2026-09-17] 两个分支体提取为
        // fetch_known_toc_body / fetch_detail_and_derive_toc_body，共享尾部
        // 提取为 parse_chapters_from_toc_body（同时供 get_chapters_with_vars
        // 的「已知目录页」路径复用）。
        let (toc_url, toc_body, book_author) =
            if let Some(raw_toc) = known_toc_url.filter(|u| !u.is_empty() && *u != book_url) {
                self.fetch_known_toc_body(
                    source,
                    book_url,
                    raw_toc,
                    variables,
                    source_headers.as_ref(),
                    js_lib_sanitized.as_deref(),
                    &mut book_name,
                    t0,
                )
                .await?
            } else {
                self.fetch_detail_and_derive_toc_body(
                    source,
                    book_url,
                    variables,
                    source_headers.as_ref(),
                    js_lib_sanitized.as_deref(),
                    &mut book_name,
                    t0,
                )
                .await?
            };

        // P2-9 ②：合并详情/目录阶段记录的 book 元信息（缓存里的
        // variable/last_chapter 等字段本次未产出时保留；本次非空字段优先）
        let mut book_meta = lookup_book_meta_by_book_url(book_url).unwrap_or_default();
        if !book_name.trim().is_empty() {
            book_meta.name = book_name.trim().to_string();
        }
        if !book_author.trim().is_empty() {
            book_meta.author = book_author.trim().to_string();
        }
        if !book_url.trim().is_empty() {
            book_meta.book_url = book_url.to_string();
        }
        if !toc_url.trim().is_empty() {
            book_meta.toc_url = toc_url.trim().to_string();
        }
        // P1-1：缓存无 book 变量（详情阶段未走过、@put 未导出、或缓存早于
        // 用户后来在书籍信息页设置的变量）→ 按 bookUrl 从 DB 补，使目录
        // 阶段 book 绑定 getVariable 能取到用户书籍变量
        if book_meta
            .variable
            .as_deref()
            .is_none_or(|v| v.trim().is_empty())
        {
            book_meta.variable = db_book_variable(book_url);
        }

        let chapters = self
            .parse_chapters_from_toc_body(
                source,
                source_headers.as_ref(),
                &toc_url,
                toc_body,
                &book_name,
                Some(&book_meta),
                js_lib_sanitized.as_deref(),
                t0,
            )
            .await?;
        // P2-9 ②：记录章节 URL → book 映射 + book 元信息（正文阶段反查用）
        record_chapter_list_cache(book_url, &toc_url, &book_name, &book_author, &chapters);
        Ok(chapters)
    }
}

impl RealBookSourceFetcher {
    /// [方案 A 2026-09-17] 已知目录页路径（带变量表）：入参 `toc_url` 是
    /// **已解析的真实目录页地址**（换源 2a 详情解析出的 toc_url；目录在
    /// 详情页时可传详情 URL）。
    ///
    /// 直接经 `AnalyzeUrl::parse(toc_url, variables, 1)` 抓取该目录页
    /// （目录地址可能带「url,{json}」请求选项与 `{{key}}` 模板，经变量表
    /// 展开，对齐原版 getChapterListAwait），再对响应体跑 ruleToc；不抓
    /// 详情页、不经 init → tocUrl 重推目录地址。
    ///
    /// 注意：`toc_url` 应为已可抓取的目录页地址（通常为绝对地址）；相对
    /// 地址无 base URL 可解析（本路径无 book_url 入参），不支持。
    async fn get_chapters_from_known_toc_and_vars(
        &self,
        source: &BookSource,
        toc_url: &str,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        self.get_chapters_from_known_toc_and_vars_with_hint(source, toc_url, variables, None)
            .await
    }

    /// [P2-1/P2-2 2026-09-17] 已知目录页路径（带书名 hint）
    ///
    /// `book_name_hint`：None 维持原行为（`book` 绑定 name 为空）；
    /// Some(name) 注入详情步解析出的书名（上游 BookChapterList.kt:196
    /// `AnalyzeRule(book, bookSource)` 下 `book.name` 可用），供
    /// `@js:[{title: book.name, url: …}]` 类 chapterList 规则读取书名，
    /// 避免直抓目录路径下标题退化。
    ///
    /// P2-1：抓目录体后、解析前执行 loginCheckJs——对齐上游
    /// WebBook.kt:346-352 顺序（get response → login check → parse；
    /// 旧详情路径均有此步，新路径此前缺失，`login_check_js="false"` 的
    /// 需登录源会错误地直接返回目录）。
    async fn get_chapters_from_known_toc_and_vars_with_hint(
        &self,
        source: &BookSource,
        toc_url: &str,
        variables: &std::collections::HashMap<String, String>,
        book_name_hint: Option<&str>,
    ) -> LegadoResult<Vec<WebChapter>> {
        acquire_source_rate_limit(source).await;
        let source_headers = Self::parse_source_headers(source);
        // 书山聚合等聚合源目录规则 `<js>` 脚本依赖 jsLib 函数（getServerHost
        // 等），jsLib 需 sanitize（去 Rhino 特有 Packages 行）后注入。
        let js_lib_sanitized = source
            .js_lib
            .as_deref()
            .map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
        let t0 = std::time::Instant::now();
        // P2-2：None 时 trim 后为空串（= 原 `String::new()` 行为）
        let book_name = book_name_hint.map(str::trim).unwrap_or("").to_string();

        // 目录 URL 可能是「url,{json}」带请求选项的格式（七猫四合一
        // qmGetUrl 生成 https://.../chapter/chapter-list?...,{...}）：必须
        // 经 AnalyzeUrl 解析出 url/method/headers 再请求，直接 GET 会把
        // ,{json} 拼进请求 → 目录接口 404/错误响应 → 「共 0 章」。
        let analyze_toc = legado_parser::AnalyzeUrl::parse(toc_url, variables, 1)
            .map_err(|e| LegadoError::Internal(format!("tocUrl 解析失败: {e}")))?;
        let toc_body = self
            .fetch_url(&analyze_toc, source_headers.as_ref())
            .await?;
        // P2-1：loginCheckJs 目录体登录检测（调用形态与详情路径各
        // execute_login_check 调用点一致；LegadoResult<()> → `?`）。
        // 无 loginCheckJs 配置时内部直接跳过，不影响既有源。
        Self::execute_login_check(source, &toc_body, toc_url, 200)?;
        eprintln!(
            "[web_book] get_chapters_from_known_toc fetched {} in {:?}",
            analyze_toc.url(),
            t0.elapsed()
        );

        // P2-9 ②：本路径无 bookUrl 入参（调用方未传入 book 上下文）→
        // book_meta 传 None：`book` 绑定回退既有 `{"name":…}` 字面量，
        // 且不记录章节→book 映射（正文阶段该路径的 book 绑定走降级面）。
        self.parse_chapters_from_toc_body(
            source,
            source_headers.as_ref(),
            toc_url,
            toc_body,
            &book_name,
            None,
            js_lib_sanitized.as_deref(),
            t0,
        )
        .await
    }

    /// 已知目录路径抓取目录响应体（原 get_chapters_with_hints_and_vars 的
    /// known_toc 分支，逐字迁移；`!= book_url` 守卫保留在调用点）。
    ///
    /// `raw_toc` 可为相对路径（相对 `book_url` 绝对化）。解析后目录地址
    /// 等于 `book_url`（如相对路径形态）时按 bookUrl 请求选项抓取并解析
    /// 书名；否则直接抓目录页（目录地址可能带请求选项，先经 AnalyzeUrl
    /// 解析）。返回（最终目录地址, 目录响应体）。
    #[allow(clippy::too_many_arguments)] // 逐字迁移原分支参数集，暂不拆结构体
    async fn fetch_known_toc_body(
        &self,
        source: &BookSource,
        book_url: &str,
        raw_toc: &str,
        variables: &std::collections::HashMap<String, String>,
        source_headers: Option<&HashMap<String, String>>,
        js_lib_sanitized: Option<&str>,
        book_name: &mut String,
        t0: std::time::Instant,
    ) -> LegadoResult<(String, String, String)> {
        let info_rule = source.rule_book_info.as_ref();
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
            let analyze_book = legado_parser::AnalyzeUrl::parse(book_url, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("bookUrl 解析失败: {e}")))?;
            let info_body = self.fetch_url(&analyze_book, source_headers).await?;
            Self::execute_login_check(source, &info_body, book_url, 200)?;
            // P2-9 ②：书名空或配了 author 规则时建解析器（名字仅在空时补，
            // author 取 ruleBookInfo.author，逐行 trim 取首非空行，同 name 模式）
            let author_rule = info_rule.and_then(|r| r.author.as_deref());
            let mut book_author = String::new();
            if book_name.is_empty() || author_rule.is_some() {
                let info_analyzer = crate::js_executor::construct_analyzer_with_source_context(
                    info_body.clone(),
                    book_url.to_string(),
                    &source.book_source_url,
                    js_lib_sanitized,
                    crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
                )
                // P2-9 ②：book 绑定扩面（详情阶段，见 detail_book_binding 注释）
                .with_js_binding("book", &detail_book_binding(book_url, book_name.as_str()))
                // P2-9 ①：src = 详情响应体（见 bind_orig_src 注释）
                .with_js_binding(
                    "src",
                    &serde_json::to_string(&info_body).unwrap_or_default(),
                );
                if book_name.is_empty() {
                    *book_name = info_rule
                        .and_then(|r| r.name.as_deref())
                        .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
                        .unwrap_or_default()
                        .lines()
                        .map(str::trim)
                        .find(|s| !s.is_empty())
                        .unwrap_or("")
                        .to_string();
                }
                if let Some(rule) = author_rule {
                    book_author = info_analyzer
                        .get_string(rule)
                        .unwrap_or_default()
                        .lines()
                        .map(str::trim)
                        .find(|s| !s.is_empty())
                        .unwrap_or("")
                        .to_string();
                }
            }
            Ok((toc_url, info_body, book_author))
        } else {
            // tocUrl 可能是「url,{json}」带请求选项的格式（七猫四合一
            // qmGetUrl 生成 https://.../chapter/chapter-list?...,
            // {"method":"GET","headers":{...}}）：必须经 AnalyzeUrl 解析出
            // url/method/headers 再请求，直接 GET 会把 ,{json} 拼进请求
            // → 目录接口 404/错误 → 「共 0 章」（2026-08-15 用户反馈）
            let analyze_toc = legado_parser::AnalyzeUrl::parse(&toc_url, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("tocUrl 解析失败: {e}")))?;
            let body = self.fetch_url(&analyze_toc, source_headers).await?;
            // P2-9 ②：纯目录页路径无详情字段，author 空（详情阶段记录可补）
            Ok((toc_url, body, String::new()))
        }
    }

    /// 详情页路径抓取目录响应体（原 get_chapters_with_hints_and_vars 的
    /// else 分支，逐字迁移）：抓详情页 → ruleBookInfo.init + tocUrl 规则
    /// 推导目录页地址（tocUrl 规则为空时目录地址=详情页 URL 并复用详情
    /// 响应体）。返回（最终目录地址, 目录响应体）。
    #[allow(clippy::too_many_arguments)] // 逐字迁移原分支参数集，暂不拆结构体
    async fn fetch_detail_and_derive_toc_body(
        &self,
        source: &BookSource,
        book_url: &str,
        variables: &std::collections::HashMap<String, String>,
        source_headers: Option<&HashMap<String, String>>,
        js_lib_sanitized: Option<&str>,
        book_name: &mut String,
        t0: std::time::Instant,
    ) -> LegadoResult<(String, String, String)> {
        let info_rule = source.rule_book_info.as_ref();
        // 1. 先获取详情页以确定 toc_url
        //    （bookUrl 可能带「url,{json}」请求选项，七猫发现列表 qmGetUrl 生成；
        //    经 AnalyzeUrl 解析出 url/method/headers 再请求，直接 GET 会 401/404）
        let analyze_book = legado_parser::AnalyzeUrl::parse(book_url, variables, 1)
            .map_err(|e| LegadoError::Internal(format!("bookUrl 解析失败: {e}")))?;
        let info_body = self.fetch_url(&analyze_book, source_headers).await?;
        eprintln!("[web_book] get_chapters info_body in {:?}", t0.elapsed());

        // 1.5 loginCheckJs 登录检测
        Self::execute_login_check(source, &info_body, book_url, 200)?;

        let mut info_analyzer = crate::js_executor::construct_analyzer_with_source_context(
            info_body.clone(),
            book_url.to_string(),
            &source.book_source_url,
            js_lib_sanitized,
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        );
        // P2-9 ②：book 绑定扩面（详情阶段）：init 规则的 `book.getVariable`
        // 等调用依赖（见 detail_book_binding 注释）；meta 未命中时字面量
        // 回退，执行路径与原 HEAD 一致
        info_analyzer = info_analyzer
            .with_js_binding("book", &detail_book_binding(book_url, book_name.as_str()));

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

        // P2-9 ①：src = 最终 content（body 或 init 结果，见 bind_orig_src 注释）
        let info_content = info_analyzer.content().to_string();
        info_analyzer = bind_orig_src(info_analyzer, &info_content);

        let raw_toc = info_rule
            .and_then(|r| r.toc_url.as_deref())
            .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();

        // 书名（供目录规则 `<js>` 中 `book.name` 使用，对齐原版
        // AnalyzeRule.evalJS 注入 book 绑定；51漫画等目录规则依赖）— Reasonix
        if book_name.is_empty() {
            *book_name = info_rule
                .and_then(|r| r.name.as_deref())
                .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
                .unwrap_or_default()
                .lines()
                .map(str::trim)
                .find(|s| !s.is_empty())
                .unwrap_or("")
                .to_string();
        }
        // P2-9 ②：author 规则（ruleBookInfo.author），行处理同 name；无规则
        // 时为 ""（不触发 JS 执行）
        let book_author = info_rule
            .and_then(|r| r.author.as_deref())
            .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default()
            .lines()
            .map(str::trim)
            .find(|s| !s.is_empty())
            .unwrap_or("")
            .to_string();
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
            let analyze_toc = legado_parser::AnalyzeUrl::parse(&toc_url, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("tocUrl 解析失败: {e}")))?;
            self.fetch_url(&analyze_toc, source_headers).await?
        };
        Ok((toc_url, toc_body, book_author))
    }

    /// 目录解析共享尾部（原 get_chapters_with_hints_and_vars 两分支之后的
    /// 共享段，2026-09-17 方案 A 提取；同时供已知目录页路径
    /// get_chapters_from_known_toc_and_vars 复用）：对目录页响应体跑
    /// ruleToc（chapterList → 章节循环、nextTocUrl 分页、去重/反转、
    /// formatJs），返回章节列表。
    /// `t0` 为整段流程起点（含抓目录耗时），仅用于 eprintln 计时日志。
    #[allow(clippy::too_many_arguments)] // 目录解析共享尾部参数集，暂不拆结构体
    async fn parse_chapters_from_toc_body(
        &self,
        source: &BookSource,
        source_headers: Option<&HashMap<String, String>>,
        toc_url: &str,
        toc_body: String,
        book_name: &str,
        book_meta: Option<&BookMeta>,
        js_lib_sanitized: Option<&str>,
        t0: std::time::Instant,
    ) -> LegadoResult<Vec<WebChapter>> {
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

        let mut analyzer = crate::js_executor::construct_analyzer_with_source_context(
            toc_body,
            toc_url.to_string(),
            &source.book_source_url,
            js_lib_sanitized,
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        );

        // P2-9 ②：meta 命中 → IIFE 扩面绑定；未命中 → 既有 `{"name":…}` 字面量
        let book_binding = book_binding_expr(book_meta, book_name, 0, false);
        analyzer = analyzer.with_js_binding("book", &book_binding);
        // P2-9 ①：src = 目录响应体（本分析器 content 稳定，见 bind_orig_src 注释）
        let toc_content = analyzer.content().to_string();
        analyzer = bind_orig_src(analyzer, &toc_content);

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
        // N5: 字数提取（对标原版 BookChapterList: updateTime 规则 info → AppPattern.wordCountRegex）
        let update_time_rule = toc_rule
            .and_then(|r| r.update_time.as_deref())
            .unwrap_or("");
        let word_count_re = word_count_regex();

        // 对齐原版 BookChapterList：单一 AnalyzeRule + setContent(item) 循环，
        // 复用 stringRuleCache / JsExecutor，避免每章新建解析器（数百章时差一个数量级）。
        let mut elem_analyzer = crate::js_executor::construct_analyzer_with_source_context(
            String::new(),
            toc_url.to_string(),
            &source.book_source_url,
            js_lib_sanitized,
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
        )
        // [P2-6h] 逐章解析器补 `book` 绑定（对齐原版 BookChapterList.kt:236-245：
        // 每章复用同一带 book 绑定的 analyzeRule）。此前只有 chapterList 层的
        // analyzer 有该绑定，导致 ruleToc.chapterName 里 `@js:book.name` /
        // `{{book.name}}` 取空（民间故事/涨姿势/华语中文/月亮小说/可阅文学 5 源）。
        // P2-9 ②：绑定表达式与 chapterList 层一致（meta 命中 → IIFE 扩面）
        ;
        elem_analyzer = elem_analyzer.with_js_binding("book", &book_binding);

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

            // N5: 字数（updateTime 规则 info → 正则提取，对标原版 BookChapterList）
            let word_count = if update_time_rule.is_empty() {
                None
            } else {
                let info = elem_analyzer
                    .get_string(update_time_rule)
                    .unwrap_or_default();
                word_count_re
                    .captures(&info)
                    .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
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
                    toc_url.to_string()
                }
            } else {
                AnalyzeUrl::get_absolute_url(toc_url, &raw_url)
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
                word_count,
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
                .filter(|u| !u.is_empty() && u != toc_url)
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
                let mut visited: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                visited.insert(toc_url.to_string());
                let mut next_url = next_urls.remove(0);
                while !next_url.is_empty() && visited.insert(next_url.clone()) {
                    let page_body = self
                        .fetch_simple_cached(&next_url, source_headers, true)
                        .await?;
                    // P2-9 ①：src = 本页响应体（先序列化再 move 进构造器）
                    let page_src_json = serde_json::to_string(&page_body).unwrap_or_default();
                    let page_analyzer = crate::js_executor::construct_analyzer_with_source_context(
                        page_body,
                        next_url.clone(),
                        &source.book_source_url,
                        js_lib_sanitized,
                        crate::api::source_js_bindings::book_source_js_setup_script(source).ok(),
                    )
                    .with_js_binding("src", &page_src_json);
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
                        let mut title = elem_analyzer.get_string(name_rule).unwrap_or_default();
                        let raw_url_probe = elem_analyzer.get_string(url_rule).unwrap_or_default();
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
                        // N5: 字数（同主循环，updateTime 规则 info → 正则提取）
                        let word_count = if update_time_rule.is_empty() {
                            None
                        } else {
                            let info = elem_analyzer
                                .get_string(update_time_rule)
                                .unwrap_or_default();
                            word_count_re
                                .captures(&info)
                                .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
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
                            word_count,
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
                let headers = source_headers;
                let source_url = source.book_source_url.clone();
                let js_lib = source.js_lib.clone();
                let list_rule = chapter_list_rule.to_string();
                let name_r = name_rule.to_string();
                let url_r = url_rule.to_string();
                let vip_r = vip_rule.to_string();
                let volume_r = volume_rule.to_string();
                let update_time_r = update_time_rule.to_string();
                let client = self.client.clone();

                let futs: Vec<_> = next_urls
                    .into_iter()
                    .map(|page_url| {
                        let source_url = source_url.clone();
                        let js_lib = js_lib.clone();
                        let list_rule = list_rule.clone();
                        let name_r = name_r.clone();
                        let url_r = url_r.clone();
                        let vip_r = vip_r.clone();
                        let volume_r = volume_r.clone();
                        let update_time_r = update_time_r.clone();
                        let client = client.clone();
                        // P2-9 ②：并发分页页内解析器同样带 `book` 绑定（对齐串行分页与
                        // chapterList 层；此前并发分支缺失，`@js:book.name` 在该路径取空）
                        let book_binding = book_binding.clone();
                        async move {
                            let body = {
                                if let Some(cached) = cache_get_page_body(&page_url) {
                                    cached
                                } else {
                                    let response = client.get(&page_url, headers.cloned()).await?;
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
                            // P2-9 ①：src = 本页响应体（先序列化再 move 进构造器）
                            let page_src_json = serde_json::to_string(&body).unwrap_or_default();
                            let mut page_analyzer =
                                crate::js_executor::construct_analyzer_with_js_lib(
                                    body,
                                    page_url.clone(),
                                    &source_url,
                                    js_lib.as_deref(),
                                );
                            // P2-9 ②：`book` 绑定扩面（meta 命中 → IIFE；未命中 → name 字面量）
                            page_analyzer = page_analyzer
                                .with_js_binding("book", &book_binding)
                                // P2-9 ①：src = 本页响应体（见 bind_orig_src 注释）
                                .with_js_binding("src", &page_src_json);
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
                            // P2-9 ②：逐章解析器同样带 `book` 绑定（与串行分页一致）
                            elem = elem.with_js_binding("book", &book_binding);
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
                                // N5: 字数（updateTime 规则 info → 正则提取）
                                let word_count = if update_time_r.is_empty() {
                                    None
                                } else {
                                    let info = elem.get_string(&update_time_r).unwrap_or_default();
                                    word_count_re
                                        .captures(&info)
                                        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
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
                                    word_count,
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
                let chapter_json = serde_json::to_string(&*ch).unwrap_or_else(|_| "{}".to_string());
                let title_json =
                    serde_json::to_string(&ch.title).unwrap_or_else(|_| "\"\"".to_string());
                let index_json = serde_json::to_string(&(i as i32 + 1)).unwrap();
                let mut fa = crate::js_executor::construct_analyzer_with_js_lib(
                    String::new(),
                    toc_url.to_string(),
                    &source.book_source_url,
                    js_lib_sanitized,
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
        // P2-9 ①：src = 正文响应体（见 bind_orig_src 注释）
        let body_src_json = serde_json::to_string(&body).unwrap_or_default();
        let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
            body.clone(),
            page_url.to_string(),
            source_url,
            js_lib,
        )
        .with_js_binding("src", &body_src_json);
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
    let url_re = regex::Regex::new(
        r#"(?i)(?:src|href|url)\s*=\s*["']([^"']+)["']|["'](https?://[^"']+)["']"#,
    )
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
/// [T4 | RuleDataInterface/AnalyzeRule.putVariable] 变量表合并：`overlay`
/// （章节级）同名键覆盖 `base`（书级），对齐原版 getVariable 的
/// chapter → book 级联优先级。两侧均空/均非 JSON 对象 → None。
pub(crate) fn merge_variables_json(base: Option<&str>, overlay: Option<&str>) -> Option<String> {
    let mut map = serde_json::Map::new();
    for src in [base, overlay] {
        if let Some(s) = src.map(str::trim).filter(|v| !v.is_empty()) {
            if let Ok(serde_json::Value::Object(m)) = serde_json::from_str::<serde_json::Value>(s) {
                for (k, v) in m {
                    map.insert(k, v);
                }
            }
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(serde_json::Value::Object(map).to_string())
    }
}

/// [T4 | AnalyzeUrl.kt:412-413] 章节 variable JSON → AnalyzeUrl 变量表
/// （值统一字符串化；非 JSON 对象容忍为空表）。章节 URL 模板/请求选项中的
/// `{{key}}` 取自该表，空表会使翻页 token 类变量无法展开。
pub(crate) fn chapter_url_variables(
    variable: Option<&str>,
) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    if let Some(s) = variable.map(str::trim).filter(|v| !v.is_empty()) {
        if let Ok(serde_json::Value::Object(m)) = serde_json::from_str::<serde_json::Value>(s) {
            for (k, v) in m {
                let val = match v {
                    serde_json::Value::String(t) => t,
                    other => other.to_string(),
                };
                map.insert(k, val);
            }
        }
    }
    map
}

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
        None, // chapter_variable_json：测试/旧调用无章节变量
        None, // book_meta：测试/旧调用无 book 元信息（降级空 name 字面量）
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
    book_meta: Option<&BookMeta>,
) -> (String, Vec<String>) {
    // 书山等聚合源正文规则依赖书源上下文（getSecretKey → source.getLoginHeader、
    // getServerHost/deviceType → jsLib）与 header 规则注入（java.ajax 携带
    // X-Novel-Token/X-Api-Key）；construct_analyzer_with_js_lib 仅有 jsLib 无
    // setup → source 绑定为 URL 字符串 → getSecretKey 取不到 loginHeader →
    // X-Api-Key 空 → 正文密文。— 书山正文修复（2026-08-17）
    let js_lib_sanitized = js_lib.map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
    // P2-9 ①：src = 正文响应体（先序列化再 move 进构造器，见 bind_orig_src 注释）
    let body_src_json = serde_json::to_string(&body).unwrap_or_default();
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
    // P2-9 ②：meta 命中时 `book` 绑定扩面为 IIFE 对象（字段 + 方法）；
    // 未命中保留既有空 name 字面量（不破坏未走详情/目录阶段的源）
    let total = book_total_chapter_num.unwrap_or(0);
    analyzer = analyzer.with_js_binding("book", &book_binding_expr(book_meta, "", total, true));
    // P2-9 ①：src = 正文响应体（见 bind_orig_src 注释）
    analyzer = analyzer.with_js_binding("src", &body_src_json);
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
    book_meta: Option<&BookMeta>,
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
                            book_meta,
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
                    book_meta,
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
    // P2-9 ①：src = 二次请求响应体（先序列化再 move 进构造器）
    let page_src_json = serde_json::to_string(&page_body).unwrap_or_default();
    let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
        page_body,
        page_url.to_string(),
        source_url,
        js_lib,
    )
    .with_js_binding("src", &page_src_json);
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
    // P2-9 ①：src = 拼接后正文（先序列化再 move 进构造器）
    let trimmed_src_json = serde_json::to_string(&trimmed).unwrap_or_default();
    let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
        trimmed,
        base_url.to_string(),
        source_url,
        js_lib,
    )
    .with_js_binding("src", &trimmed_src_json);
    eval_rule_string(&analyzer, replace_regex)
}

/// 拆分 Kotlin SourceRule 的 `##` 替换语法（对标 AnalyzeRule.makeUpRule L819-829）：
/// `rule##replaceRegex##replacement##第四段(仅存在即置 replaceFirst=true)`。
/// 返回（基础规则，可选替换三元组）。
///
/// [B/P1-1 | 台账 0917] `{{…}}` 参数内的 `##` 属于参数内层规则（上游
/// makeUpRule 只在参数回填**之后**才 `split("##")`）：顶层拆分**跳过**落在
/// 已闭合 `{{…}}` 跨度内的 `##` 位置（与解析器 `split_hash_replace` 共用
/// `legado_parser::split_top_level_hash`，两入口一致）——旧的「全部 `##` 都
/// 在跨度内才不拆」全有或全无守卫在混合形态（跨度内 + 跨度外 `##`）下
/// 放弃整个拆分 → 半截垃圾。跨度内 `##` 随基础规则原样交给解析器，由其
/// 模板路径完成参数回填与内层 `##` 替换。
pub(crate) fn split_rule_replace_parts(rule: &str) -> (&str, Option<(&str, &str, bool)>) {
    let parts = legado_parser::split_top_level_hash(rule, usize::MAX);
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
pub(crate) fn eval_rule_string(
    analyzer: &legado_parser::AnalyzeRule,
    rule: &str,
) -> LegadoResult<String> {
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

/// 正则替换（对标 Kotlin `AnalyzeRule.replaceRegex` L541-565）：
/// - replaceFirst 分支（`##match##replace##第四段`）：仅取首个匹配段文本做替换后返回
///   （对标 L548-555 `matcher.group(0).replaceFirst(regex, replacement)`）；
///   **无匹配时上游 L553-555 返回 `""`**（`else -> ""`）——本入口与解析器
///   `apply_hash_replace`（P1-2 收敛语义，见其注释）及锁定测试
///   `test_apply_regex_replace_replace_first` 三方一致；
/// - 全文替换分支：`result.replace(regex, replacement)`，replacement 支持 `$1` 捕获组引用；
/// - 正则非法/编译失败（含病态 pattern 栈溢出防护 compile_regex_safe）时降级字面量替换
///   （对标 L563 `result.replace(replaceRegex, replacement)`；
///   replaceFirst 分支正则非法时对标 L557 直接返回 replacement）。
pub(crate) fn apply_regex_replace(
    text: &str,
    pattern: &str,
    replacement: &str,
    replace_first: bool,
) -> String {
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
pub(crate) fn matches_book_url_pattern(pattern: &str, url: &str) -> bool {
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

/// N5: 章节字数正则（对标原版 `AppPattern.wordCountRegex`：
/// `(?:^|字数[：:、]?\s*|\s+)([0-9万千百\.]{1,6}字)`，取第 1 捕获组）
fn word_count_regex() -> &'static regex::Regex {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(r"(?:^|字数[：:、]?|\s+)([0-9万千百.]{1,6}字)").expect("wordCountRegex")
    })
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
                // N5: JS 书源章节可携带 wordCount 键
                word_count: v
                    .get("wordCount")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
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
pub(crate) fn build_js_orchestrator(
    source: &BookSource,
) -> LegadoResult<Option<JsSourceBookOrchestrator>> {
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
            tokio::task::spawn_blocking(move || orchestrator.search(&source_clone, &key, page))
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

/// webbook_info 核心（P2-12 变量链，2026-09-18；生产入口 [`webbook_info`]
/// 构建真实 fetcher 后委托本函数，单测可注入脚本化 fetcher）
///
/// 变量链：详情请求模板（bookUrl 的 `{{key}}` 与 `,{json}` 请求选项）回读
/// DB `books.variable`（`db_book_variable` 两路查找：bookUrl →
/// originBookUrl，兼容换源后 Dart 以 originBookUrl 作为取址点传入）。
/// 优先级：DB 持久化值（用户显式设置，换源时候选 ⊕ 详情导出已合并落库）
/// 覆盖书源 `@put` 默认导出——与换源链 P1-1 理由一致：用户显式值优先。
/// 原 get_book_info 链末端即 `get_book_info_with_existing_and_vars(…, 空表)`，
/// 故仅补变量表，其余语义（can_re_name=true / 空既有名）不变。
async fn webbook_info_with_fetcher<F: BookSourceFetcher>(
    source: &BookSource,
    book_url: &str,
    fetcher: &F,
) -> LegadoResult<WebBookInfo> {
    let variables = chapter_url_variables(db_book_variable(book_url).as_deref());
    fetcher
        .get_book_info_with_existing_and_vars(source, book_url, true, "", "", &variables)
        .await
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
            // JS 源 marshalled 详情暂不携带 variable（marshaller 未透出），
            // 换源变量以搜索候选与规则源详情导出为准
            variable: None,
        };
        // P2-9 ②：记录 book 元信息（目录/正文阶段 `book` 绑定扩面反查用）
        record_book_meta_from_info(book_url, &info);
        return serde_json::to_string(&info).map_err(LegadoError::Serialization);
    }

    // 规则书源路径（P2-12 变量链见 webbook_info_with_fetcher；
    // 注：JS 书源路径（上方早退分支）marshaller 不透出 variable，维持现状）
    let fetcher = RealBookSourceFetcher::new()?;
    let info: WebBookInfo =
        runtime::block_on(webbook_info_with_fetcher(&source, book_url, &fetcher))?;
    // P2-9 ②：记录 book 元信息（目录/正文阶段 `book` 绑定扩面反查用）
    record_book_meta_from_info(book_url, &info);
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
        // P2-9 ②：缓存记录用副本（url / toc / 书名随后被 move 进闭包）
        let url_for_cache = url.clone();
        let toc_for_cache = toc.clone();
        let name_for_cache = book_name_owned.clone();
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
        // P2-9 ②：记录章节 → book 映射 + 元信息（正文阶段反查用）；
        // JS 详情路径不导出 author（传 ""，规则源详情阶段 merge 写入可补）
        record_chapter_list_cache(
            &url_for_cache,
            &toc_for_cache,
            &name_for_cache,
            "",
            &chapters,
        );
        return serde_json::to_string(&chapters).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
    // 规则书源路径（P2-12 变量链见 webbook_chapters_with_fetcher）
    let fetcher = RealBookSourceFetcher::new()?;
    let chapters: Vec<WebChapter> = runtime::block_on(webbook_chapters_with_fetcher(
        &source,
        book_url,
        known_toc_opt,
        name_hint_opt,
        &fetcher,
    ))?;
    serde_json::to_string(&chapters).map_err(LegadoError::Serialization)
}

/// webbook_chapters 核心（P2-12 变量链，2026-09-18；生产入口
/// [`webbook_chapters`] 构建真实 fetcher 后委托本函数，单测可注入脚本化
/// fetcher）
///
/// 变量链：同 webbook_info——目录/详情请求模板经 DB `books.variable`
/// （两路查找 bookUrl → originBookUrl）展开，换源后重进详情拉目录亦带
/// 变量（与换源后语义一致；DB 值 > `@put` 默认导出）。
/// `get_chapters_with_hints` 即本方法空变量表特例，仅补变量表。
async fn webbook_chapters_with_fetcher<F: BookSourceFetcher>(
    source: &BookSource,
    book_url: &str,
    known_toc_url: Option<&str>,
    book_name_hint: Option<&str>,
    fetcher: &F,
) -> LegadoResult<Vec<WebChapter>> {
    let variables = chapter_url_variables(db_book_variable(book_url).as_deref());
    fetcher
        .get_chapters_with_hints_and_vars(
            source,
            book_url,
            known_toc_url,
            book_name_hint,
            &variables,
        )
        .await
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
        // P2-9 ②：反查详情/目录阶段记录的 book 元信息 → 填充 Book 模型字段
        // （JS 编排器 get_content 将 Book 整体序列化传给 getContent；缓存
        // 未命中时字段全空 = 既有行为，不破坏既有 JS 源）
        let mut book_meta = lookup_book_meta_for_chapter(&chapter.url);
        // P1-1：缓存 meta 有值但 variable 缺失/为空 → 按 bookUrl 从 DB 补
        if let Some(m) = book_meta.as_mut() {
            if m.variable.as_deref().is_none_or(|v| v.trim().is_empty()) {
                m.variable = db_book_variable(&m.book_url);
            }
        }
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
                    name: book_meta
                        .as_ref()
                        .map(|m| m.name.clone())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_default(),
                    author: book_meta
                        .as_ref()
                        .map(|m| m.author.clone())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_default(),
                    book_url: book_meta
                        .as_ref()
                        .map(|m| m.book_url.clone())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_default(),
                    toc_url: book_meta
                        .as_ref()
                        .map(|m| m.toc_url.clone())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_default(),
                    latest_chapter_title: book_meta
                        .as_ref()
                        .filter(|m| !m.last_chapter.trim().is_empty())
                        .map(|m| m.last_chapter.clone()),
                    variable: book_meta.and_then(|m| m.variable),
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
    #[cfg(feature = "quickjs")]
    fn test_shushan_real_toc_repro() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("sources_device.json 缺失，跳过");
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
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
        let book_url = format!(
            r#"data:detailsUrl;base64,{},{{"type":"susan"}}"#,
            b64_detail
        );
        // 真实番茄书（5556 模拟器书架导出）：验证登录后正文返回明文
        let real_book_url =
            std::fs::read_to_string("C:/Users/Public/real_bookurl.txt").unwrap_or_default();
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
        let login_out = match crate::api::source_login_v1_api::eval_login_v1(&source_json, "login")
        {
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
        // 目录回归（重试一次；连续两次失败判定为站点侧抖动并跳过）：
        // 上方登录断言是核心回归信号，保持严格；目录/正文 e2e 为次要覆盖，
        // 站点偶发返回异常响应（反爬抖动）时不应让 CI 变红。
        let mut chapters: Option<Vec<serde_json::Value>> = None;
        for attempt in 1..=2u32 {
            match webbook_chapters(&source_json, &book_url, "", "") {
                Ok(s) => {
                    let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                    eprintln!("[repro] 目录 {} 章（第 {attempt} 次尝试）", arr.len());
                    assert!(arr.len() > 5, "书山目录应 >5 章，实际 {}", arr.len());
                    chapters = Some(arr);
                    break;
                }
                Err(e) => {
                    eprintln!("[repro] 目录抓取第 {attempt} 次失败: {e}");
                    if attempt == 1 {
                        std::thread::sleep(std::time::Duration::from_secs(2));
                    } else {
                        eprintln!("[repro] 连续两次失败，判定为站点侧抖动，跳过（可手动重跑验证）");
                        return;
                    }
                }
            }
        }
        let chapters = chapters.expect("目录结果应在 break 前写入");
        // 正文回归：取第一章 data:chapterUrl 调 webbook_content
        let first = chapters.first().cloned().unwrap_or_default();
        let ch_url = first.get("url").and_then(|u| u.as_str()).unwrap_or("");
        eprintln!(
            "[repro] 第一章 url 前缀: {}",
            &ch_url[..ch_url.len().min(120)]
        );
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
                    eprintln!(
                        "[repro] 正文前120: {}",
                        c.chars().take(120).collect::<String>()
                    );
                    assert!(c.trim().len() > 50, "正文应非空，实际 {}", c.trim().len());
                }
                Err(e) => panic!("[repro] 书山正文失败: {e}"),
            }
        }
    }

    #[test]
    fn test_decode_web_response_gbk_meta_and_header() {
        let mut meta_headers = HashMap::new();
        let (html, _, _) = encoding_rs::GBK
            .encode(r#"<html><head><meta charset="gbk"></head><body>目录章节</body></html>"#);
        assert!(decode_web_response(&html, &meta_headers, None).contains("目录章节"));

        let mut header_headers = HashMap::new();
        header_headers.insert(
            "Content-Type".to_string(),
            "text/html; charset=gbk".to_string(),
        );
        let (plain, _, _) = encoding_rs::GBK.encode("正文内容");
        assert_eq!(
            decode_web_response(&plain, &header_headers, None),
            "正文内容"
        );

        meta_headers.insert(
            "Content-Type".to_string(),
            "text/html; charset=utf-8".to_string(),
        );
        assert_eq!(
            decode_web_response(&plain, &meta_headers, Some("gbk")),
            "正文内容"
        );

        let mut spaced_header = HashMap::new();
        spaced_header.insert(
            "content-type".to_string(),
            "text/html; Charset = GBK".to_string(),
        );
        assert_eq!(
            decode_web_response(&plain, &spaced_header, None),
            "正文内容"
        );

        let (single_quote, _, _) = encoding_rs::GBK
            .encode(r#"<html><head><meta charset='GBK'></head><body>单引号</body></html>"#);
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
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let mut scanned = 0;
        let mut ok = 0;
        let mut empty = 0;
        let mut failed = 0;
        for src in sources.iter() {
            let st = src
                .get("bookSourceType")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
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
                    eprintln!(
                        "[scan-fail] {} | {} | {}",
                        name,
                        url,
                        e.to_string().chars().take(120).collect::<String>()
                    );
                }
            }
            if scanned >= 120 {
                break;
            }
        }
        eprintln!(
            "[scan-summary] scanned={} ok={} empty={} failed={}",
            scanned, ok, empty, failed
        );
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
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
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
            let st = src
                .get("bookSourceType")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
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
                    let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
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

    /// 七步阁站点可达性探测：不可达或非 2xx 时返回 false（跳过）。
    /// 外部站状态不应让 CI 变红；站点恢复后 e2e 自动回归。
    fn qibuge_site_reachable() -> bool {
        let client = match crate::http_state::shared_client() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[qibuge] 共享客户端初始化失败: {e}，跳过 e2e");
                return false;
            }
        };
        let probe = crate::runtime::block_on(client.get("https://m.qibuge.com/s.php", None));
        match probe {
            Ok(resp) if resp.is_success() => true,
            Ok(resp) => {
                eprintln!(
                    "[qibuge] 站点不可用: HTTP {}，跳过 e2e（站点恢复后自动回归）",
                    resp.status
                );
                false
            }
            Err(e) => {
                eprintln!("[qibuge] 站点不可达: {e}，跳过 e2e");
                false
            }
        }
    }

    /// 七步阁 GBK POST 搜索回归（2026-08-17）：bookUrlPattern 全匹配修复
    /// （m.qibuge.com 正则不得命中 /s.php 搜索页 URL）
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_qibuge_search_diag() {
        if !qibuge_site_reachable() {
            return;
        }
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("七步阁"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup,
        );
        eprintln!("[qibuge] request_body: {:?}", au.request_body());
        eprintln!(
            "[qibuge] request_body={:?} encoded_form={:?} headers={:?}",
            au.request_body(),
            au.encoded_form(),
            au.headers()
        );
        eprintln!(
            "[qibuge] URL: {} method: {:?} body: {:?} charset: {:?}",
            au.url(),
            au.method(),
            au.body(),
            au.charset()
        );
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let headers = crate::api::web_book::RealBookSourceFetcher::parse_source_headers(&source);
        eprintln!("[qibuge] source_headers: {:?}", headers);
        let body =
            crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref())).unwrap_or_default();
        eprintln!(
            "[qibuge] 响应体前300: {}",
            body.chars().take(300).collect::<String>()
        );
        eprintln!("[qibuge] 长度: {}", body.len());
        eprintln!("[qibuge] has_sone: {}", body.contains("sone"));
        eprintln!(
            "[qibuge] 全文: {}",
            body.chars().take(1500).collect::<String>()
        );
        // 完整 search 链路验证
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[qibuge] search 结果数: {}", list.len());
                assert!(list.len() > 0, "七步阁搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(5) {
                    eprintln!(
                        "[qibuge]   -> {} | {} | {}",
                        it.name, it.author, it.book_url
                    );
                }
            }
            Err(err) => panic!("[qibuge] search 失败: {:?}", err),
        }
    }

    /// 七步阁 GBK 目录/正文回归：详情页 meta charset=gbk 必须在简单 GET 路径正确解码。
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_qibuge_catalog_and_content_gbk() {
        if !qibuge_site_reachable() {
            return;
        }
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("七步阁"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let search = webbook_search(&source_json, "一念", 1).expect("七步阁搜索失败");
        let books: Vec<serde_json::Value> = serde_json::from_str(&search).unwrap();
        let first = books.first().expect("七步阁搜索应有结果");
        let book_url = first
            .get("book_url")
            .and_then(|v| v.as_str())
            .expect("缺少 book_url");
        let book_name = first.get("name").and_then(|v| v.as_str()).unwrap_or("");
        assert!(!book_name.contains('�'), "搜索书名乱码: {book_name}");

        let info = webbook_info(&source_json, book_url).expect("七步阁详情失败");
        let info: serde_json::Value = serde_json::from_str(&info).unwrap();
        let toc_url = info.get("toc_url").and_then(|v| v.as_str()).unwrap_or("");
        let chapters =
            webbook_chapters(&source_json, book_url, toc_url, book_name).expect("七步阁目录失败");
        let chapters: Vec<serde_json::Value> = serde_json::from_str(&chapters).unwrap();
        let first_chapter = chapters.first().expect("七步阁目录应有章节");
        let chapter_title = first_chapter
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        assert!(
            !chapter_title.is_empty() && !chapter_title.contains('�'),
            "目录标题乱码: {chapter_title:?}"
        );

        let content =
            webbook_content(&source_json, &first_chapter.to_string()).expect("七步阁正文失败");
        assert!(
            content.chars().count() > 30,
            "正文过短: {}",
            content.chars().count()
        );
        assert!(
            !content.contains('�'),
            "正文乱码: {}",
            content.chars().take(120).collect::<String>()
        );
        eprintln!(
            "[qibuge-gbk] 书名={book_name}，目录首章={chapter_title}，正文前80={}",
            content.chars().take(80).collect::<String>()
        );
    }

    /// 77读书网 搜索诊断（2026-08-17）：站点返回 47KB 含结果，规则 class.BOX@tr!0 解析为 0
    // 依赖外部源站在线状态（2026-09-03 实测站点返回空页），与同文件其他
    // 外部源站诊断一致不入 CI 门禁，手工诊断时 --ignored 运行
    #[test]
    #[ignore = "外部源站网络诊断，非确定性 CI 测试"]
    fn test_77shuku_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("77读书"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup.clone(),
        );
        eprintln!(
            "[77] URL: {} method: {:?} headers: {:?}",
            au.url(),
            au.method(),
            au.headers()
        );
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let headers = crate::api::web_book::RealBookSourceFetcher::parse_source_headers(&source);
        let body =
            crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref())).unwrap_or_default();
        eprintln!(
            "[77] 长度: {} 含一念: {}",
            body.len(),
            body.contains("一念")
        );
        eprintln!(
            "[77] 含BOX: {} 含table: {} 含tr: {}",
            body.contains("BOX"),
            body.contains("<table"),
            body.contains("<tr")
        );
        let analyzer = crate::js_executor::construct_analyzer_with_source_context(
            body.clone(),
            au.url().to_string(),
            &source.book_source_url,
            None,
            setup.clone(),
        );
        for probe in [
            "class.BOX@tr!0",
            "table@tr!0",
            "table@tr",
            "css(table tr)",
            "css(tr)",
            "tr",
            "tag.tr",
            "class.BOX",
            "css(.BOX)",
            "css(table)",
            "class.BOX@tr",
            "class.BOX@table@tr",
            "table@tr!0@",
            "tag.table@tag.tr!0",
            "tag.table@tag.tr",
        ]
        .iter()
        {
            let n = analyzer.get_elements(probe).unwrap_or_default().len();
            eprintln!("[77] probe {probe:?} -> {n}");
        }
        if let Some(i) = body.find("BOX") {
            eprintln!(
                "[77] BOX 上下文: {:?}",
                body[i.saturating_sub(80)..(i + 300).min(body.len())]
                    .chars()
                    .collect::<String>()
            );
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
            for probe in [
                "tag.td.2@a@text",
                "tag.td@a@text",
                "td.2@a@text",
                "td@a@text",
                "tag.td.2",
                "css(td:eq(2) a)",
                "a.0@text",
                "css(a)",
                "tag.a@text",
                "tag.td@tag.a@text",
                "tag.td.2@tag.a@text",
            ] {
                let v = ea.get_string_ex(probe, false, false).unwrap_or_default();
                eprintln!(
                    "[77]   probe {probe:?} -> {:?}",
                    v.chars().take(30).collect::<String>()
                );
            }
            eprintln!(
                "[77] elem0 前200: {:?}",
                elem.chars().take(200).collect::<String>()
            );
        }
        assert!(
            elems77.len() > 0,
            "77读书网 bookList 应解析出元素，实际 {}",
            elems77.len()
        );
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
    #[cfg(feature = "quickjs")]
    fn test_taoxiaoshuo_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("淘小说"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
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
            .with_setup_script(
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
            );
        let js_code = source
            .search_url
            .as_deref()
            .unwrap_or("")
            .trim_start_matches("@js:")
            .trim_start();
        eprintln!(
            "[taoxs] js_code 前150: {:?}",
            js_code.chars().take(150).collect::<String>()
        );
        let vars = std::collections::HashMap::from([
            ("key".to_string(), "一念".to_string()),
            ("page".to_string(), "1".to_string()),
        ]);
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
        eprintln!(
            "[taoxs] method: {:?} headers: {:?}",
            au.method(),
            au.headers()
        );
        let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
        let headers = crate::api::web_book::RealBookSourceFetcher::parse_source_headers(&source);
        let body =
            crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref())).unwrap_or_default();
        eprintln!(
            "[taoxs] 响应长度: {} 前200: {:?}",
            body.len(),
            body.chars().take(200).collect::<String>()
        );
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
    #[cfg(feature = "quickjs")]
    fn test_qiexs_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("企鹅小说"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        // 直接构造 AnalyzeUrl 看中间态
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
            );
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
    #[cfg(feature = "quickjs")]
    fn test_xbqgxs_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| {
                    n.contains("新笔趣阁")
                        && s.get("bookSourceUrl")
                            .and_then(|u| u.as_str())
                            .is_some_and(|u| u.contains("xbqgxs"))
                })
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        // 直接执行 @js: 块看错误
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
            );
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
            Ok(u) => eprintln!(
                "[xbqgxs] parse_with_js OK: {}",
                u.url().chars().take(150).collect::<String>()
            ),
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
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        for needle in ["新落秋", "天悦小说", "笔趣阁zdzn"] {
            let Some(src) = sources.iter().find(|s| {
                s.get("bookSourceName")
                    .and_then(|n| n.as_str())
                    .is_some_and(|n| n.contains(needle))
            }) else {
                continue;
            };
            let source =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
            let fetcher = crate::api::web_book::RealBookSourceFetcher::new().unwrap();
            let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
            match results {
                Ok(list) => eprintln!("[jsnet] {} -> {} 条", needle, list.len()),
                Err(err) => eprintln!(
                    "[jsnet] {} -> 失败: {}",
                    needle,
                    err.to_string().chars().take(120).collect::<String>()
                ),
            }
        }
    }

    /// 得间小说 {{host}} 全局变量离线回归：jsLib 定义 host，{{host}} 需 JS 求值。
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_dejian_diag() {
        let source = BookSource {
            book_source_url: "https://wechat.idejian.com##".to_string(),
            book_source_name: "得间小说".to_string(),
            js_lib: Some(
                "type = 'wechat'; host = 'https://' + type + '.idejian.com/api/' + type;"
                    .to_string(),
            ),
            search_url: Some("{{host}}/search/do?keyword={{key}}&page={{page}}".to_string()),
            ..BookSource::default()
        };
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
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
            search_url: Some(
                r#"@js:
burl = source.getKey();
url = burl + "/e/search/";
body = "show=title%2Cnewstext&keyboard=" + key;
$ = java.post(url + "index.php", body, {}).headers();
uri = $.Location || $.location;
url += String(uri).replace('?', 'index.php?page=0&');"#
                    .to_string(),
            ),
            ..BookSource::default()
        };
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(),
            "一念",
            1,
            &source.book_source_url,
            None,
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert!(
            !au.url().contains("undefined"),
            "趣书 URL 不应含 undefined: {}",
            au.url()
        );
        assert!(
            !au.url().starts_with("legado-js-error://"),
            "趣书 JS 不应失败: {}",
            au.url()
        );
    }

    /// 趣书网吧人工实网诊断：依赖 fixture 与外部重定向；离线 result 绑定契约见 parser 测试。
    #[test]
    #[ignore = "外部源站/fixture 诊断，非确定性 CI 测试"]
    fn test_qushu123_connect_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceUrl")
                .and_then(|v| v.as_str())
                .is_some_and(|u| u.contains("qushu123.com"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        eprintln!("[qushu123] url={}", au.url());
        assert!(
            !au.url().contains("undefined"),
            "趣书 URL 不应含 undefined: {}",
            au.url()
        );
        assert!(
            !au.url().starts_with("legado-js-error://"),
            "趣书 JS 不应失败: {}",
            au.url()
        );
    }

    /// 天涯书库真实规则：source.key + java.post().header(location) 必须可构建搜索 URL。
    #[test]
    #[ignore = "外部重定向源诊断，离线 Response bridge 契约覆盖"]
    fn test_tianyashuku_search_url_diag() {
        let raw = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        ))
        .unwrap();
        let serde_json::Value::Array(sources) =
            serde_json::from_str::<serde_json::Value>(&raw).unwrap()
        else {
            return;
        };
        let src = sources
            .iter()
            .find(|s| {
                s.get("bookSourceUrl")
                    .and_then(|v| v.as_str())
                    .is_some_and(|u| u.contains("tianyashuku.net"))
            })
            .unwrap();
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert!(
            !au.url().contains("undefined"),
            "天涯 URL 不应含 undefined: {}",
            au.url()
        );
        assert!(
            !au.url().starts_with("legado-js-error://"),
            "天涯 JS 不应失败: {}",
            au.url()
        );
    }

    /// org.jsoup + java.post(connectNR) 回归：云霄/键盘/天涯书库 searchUrl @js
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_jsoup_post_redirect_search_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
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
            let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
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
    // 依赖外部源站在线状态（2026-09-03 实测请求超时），与同文件其他外部源站
    // 诊断一致不入 CI 门禁，手工诊断时 --ignored 运行
    #[test]
    #[ignore = "外部源站网络诊断，非确定性 CI 测试"]
    fn test_shushu_all_in_one_toc_diag() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
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
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let raw = std::fs::read_to_string(path).unwrap();
        let serde_json::Value::Array(sources) =
            serde_json::from_str::<serde_json::Value>(&raw).unwrap()
        else {
            return;
        };
        let src = sources
            .iter()
            .find(|s| {
                s.get("bookSourceUrl").and_then(|v| v.as_str()) == Some("https://g.hongshu.com/")
            })
            .unwrap();
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let result = webbook_search(&source_json, "一念", 1);
        eprintln!(
            "[hongshu] result={:?}",
            result
                .as_ref()
                .map(|s| s.chars().take(500).collect::<String>())
        );
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

    /// [P2-6h] 逐章解析器须带 `book` 绑定（对齐原版 `BookChapterList.kt:236-245`：
    /// 每章复用同一带 `book` 绑定的 analyzeRule）。此前只有 chapterList 层的
    /// analyzer 有该绑定 → `ruleToc.chapterName` 里的 `book.name` 取空
    /// （民间故事/涨姿势/华语中文/月亮小说/可阅文学 5 源）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_chapter_name_can_use_book_binding() {
        use crate::runtime;
        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://book.example.com",
            "bookSourceName": "示例源",
            "ruleToc": {
                "chapterList": "$.rows",
                "chapterName": "@js:book.name + '|' + result",
                "chapterUrl": "$.url"
            }
        }))
        .expect("source json");
        let body = r#"{"rows":[{"url":"/c/1","name":"第一章"}]}"#.to_string();
        let fetcher = RealBookSourceFetcher::new().expect("fetcher");
        let chapters = runtime::block_on(fetcher.parse_chapters_from_toc_body(
            &source,
            None,
            "https://book.example.com/toc",
            body,
            "测试书名",
            None, // book_meta：无元信息 → 既有 `{"name":"测试书名"}` 字面量
            None,
            std::time::Instant::now(),
        ))
        .expect("chapters");
        assert_eq!(chapters.len(), 1);
        assert!(
            chapters[0].title.contains("测试书名"),
            "chapterName 应能读到 book.name 绑定，实际标题: {}",
            chapters[0].title
        );
    }

    /// P2-9 ②：book 绑定 None 回退逐字保留既有字面量语义（不破坏未走
    /// 详情/目录阶段的源）
    #[test]
    fn test_book_binding_none_fallback_keeps_literal_semantics() {
        // content 站点：`{"totalChapterNum": N, "name": ""}`
        assert_eq!(
            book_binding_expr(None, "ignored", 42, true),
            r#"{"totalChapterNum": 42, "name": ""}"#
        );
        // toc 站点：`{"name": book_name}`
        assert_eq!(
            book_binding_expr(None, "测试书名", 0, false),
            r#"{"name":"测试书名"}"#
        );
    }

    /// P2-9 ②：详情阶段记录 meta → 目录阶段记录章节映射 + lastChapter
    /// 覆盖 → 正文阶段按章节 URL 反查；merge-on-write 语义验证
    ///（目录阶段 variable=None 不清空详情阶段已写入的 variable）
    #[test]
    fn test_book_meta_cache_record_and_lookup() {
        let book_url = "https://meta-cache-test.example.com/b/9";
        let info = WebBookInfo {
            name: "甲书".into(),
            author: "甲作者".into(),
            cover_url: None,
            intro: None,
            categories: vec!["小说".into()],
            last_chapter: Some("最新章节".into()),
            book_url: book_url.into(),
            toc_url: "https://meta-cache-test.example.com/toc/9".into(),
            word_count: None,
            kind: None,
            variable: Some(r#"{"a":"1"}"#.into()),
        };
        record_book_meta_from_info(book_url, &info);
        let chapters = vec![
            WebChapter {
                url: "https://meta-cache-test.example.com/c/1".into(),
                title: "第一章".into(),
                index: 0,
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            },
            WebChapter {
                url: "https://meta-cache-test.example.com/c/2".into(),
                title: "第二章".into(),
                index: 1,
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            },
        ];
        record_chapter_list_cache(
            book_url,
            "https://meta-cache-test.example.com/toc/9",
            "甲书",
            "甲作者",
            &chapters,
        );
        let meta = lookup_book_meta_for_chapter("https://meta-cache-test.example.com/c/2")
            .expect("章节 URL 应能反查到 meta");
        assert_eq!(meta.name, "甲书");
        assert_eq!(meta.author, "甲作者");
        // 目录阶段以最后一个非卷章标题覆盖详情阶段的 lastChapter
        assert_eq!(meta.last_chapter, "第二章");
        // 详情阶段写入的 variable 不被目录阶段（variable=None）清空
        assert_eq!(meta.variable, Some(r#"{"a":"1"}"#.into()));
        // 未注册章节 URL → None（回退既有空 name 字面量绑定）
        assert!(
            lookup_book_meta_for_chapter("https://meta-cache-test.example.com/unknown").is_none()
        );
    }

    /// P2-9 ②：meta 命中时 IIFE 绑定暴露字段面与方法面——逐方法
    /// `typeof book.X === 'function'` 断言（等价单测）+ getVariable/
    /// putVariable 往返 + getCustomVariable 语义
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_book_binding_iife_exposes_fields_and_methods() {
        let meta = BookMeta {
            name: "测试书名".into(),
            author: "测试作者".into(),
            book_url: "https://book.example.com/b/1".into(),
            toc_url: "https://book.example.com/toc/1".into(),
            last_chapter: "第一百章".into(),
            variable: Some(r#"{"custom":"custom-val","n":3}"#.into()),
        };
        let expr = book_binding_expr(Some(&meta), "", 42, true);
        let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
            "<html><body>正文</body></html>".to_string(),
            "https://book.example.com/c/1".to_string(),
            "",
            None,
        )
        .with_js_binding("book", &expr);
        let out = analyzer
            .get_string(
                "@js:(function(){var r=[typeof book.getVariable,typeof book.putVariable,typeof book.putCustomVariable,typeof book.getCustomVariable,typeof book.setType,typeof book.setReverseToc,book.name,book.author,book.bookUrl,book.tocUrl,book.lastChapter,String(book.totalChapterNum),book.getVariable('custom'),book.getVariable('missing'),String(book.putVariable('k2','v2')),book.getVariable('k2'),book.getCustomVariable()];return r.join('|');})()",
            )
            .expect("book 绑定 IIFE 方法探测应可执行");
        assert_eq!(
            out,
            "function|function|function|function|function|function|测试书名|测试作者|https://book.example.com/b/1|https://book.example.com/toc/1|第一百章|42|custom-val||true|v2|custom-val"
        );
    }

    /// P2-9 ② 详情阶段（ruleBookInfo.init）`book.getVariable` 补前/补后对比
    /// （对齐 聚合书库 等书源：init `<js>` 里 `book.getVariable("custom")`
    /// 读用户设置的换源变量，`JSON.stringify` 产出新 content 供字段规则解析）：
    /// - 补前（meta 未命中 → 回退既有 `{"name":…}` 字面量，等价原 HEAD 详情
    ///   阶段无 `book` 绑定的执行路径）：`book.getVariable` 非函数 → init 抛错
    ///   被 `if let Ok` 静默跳过 → 字段规则在原始响应体上求值 → 书名为空
    /// - 补后（同 bookUrl 的 meta 已入缓存 → IIFE 绑定）：init 取到变量值
    ///   → 产出 JSON → 字段规则正常解析
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_detail_phase_book_binding_before_after() {
        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://jhsu-binding-test.example.com",
            "bookSourceName": "详情绑定测试源",
            "ruleBookInfo": {
                "init": "<js>JSON.stringify({v: book.getVariable('custom'), n: book.name, a: book.author, l: book.lastChapter, t: 'https://jhsu-binding-test.example.com/toc/1'})</js>",
                "name": "$.n",
                "author": "$.a",
                "tocUrl": "$.t"
            }
        }))
        .expect("source json");
        let body = "<html><body>raw detail body</body></html>".to_string();

        // —— 补后：同 bookUrl 的 meta 已入缓存（等价进程内已走过
        // webbook_info/webbook_chapters 的状态），init 的 getVariable 取到变量
        let book_url_after = "https://jhsu-binding-test.example.com/b/after";
        record_book_meta_from_info(
            book_url_after,
            &WebBookInfo {
                name: "聚合书库测试书".into(),
                author: "测试作者".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: Some("最新章节".into()),
                book_url: book_url_after.to_string(),
                toc_url: "https://jhsu-binding-test.example.com/toc/1".into(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"3"}"#.into()),
            },
        );
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body,
            book_url_after,
            book_url_after,
            true,
            "",
            "",
        );
        assert_eq!(info.name, "聚合书库测试书", "补后：书名应来自 init 产出");
        assert_eq!(info.author, "测试作者");
        assert_eq!(info.toc_url, "https://jhsu-binding-test.example.com/toc/1");

        // —— 补前：未播种 bookUrl → 字面量绑定回退（等价 HEAD 执行路径）
        // → init 方法调用抛错被跳过 → 原始响应体上 $.n 为空
        let book_url_before = "https://jhsu-binding-test.example.com/b/before";
        let info2 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            "<html><body>raw detail body</body></html>".to_string(),
            book_url_before,
            book_url_before,
            true,
            "",
            "",
        );
        assert!(
            info2.name.is_empty(),
            "补前：init 失败应回退原始响应体（书名为空），实际: {:?}",
            info2.name
        );
    }

    /// P2-9 源级验证（补后，离线）：真实 📚聚合书库 书源
    /// （q9.db book_sources 逐字 JSON，fixture `jhsu_book4cc_source.json`）
    ///
    /// - **详情阶段命中**（项②）：`ruleBookInfo.init` 的
    ///   `book.getVariable("custom")` 驱动换源（custom=2 → origin[1]）
    ///   - 补后：meta 命中 → IIFE 绑定 → init 取到变量 → 字段正常解析
    ///   - 补前：未播种 bookUrl → 字面量回退（执行路径等价 HEAD 详情阶段
    ///     无 `book` 绑定，见 detail_book_binding 注释）→ init 方法调用
    ///     抛错被静默跳过 → 字段规则在原始响应体上求值 → 书名为空
    /// - **目录阶段命中**（项②新字段面）：`ruleToc.chapterList` 逐字规则
    ///   `book.bookUrl + $.file_name` + `` String(`${$.len}字`) ``（P1-2
    ///   修复 `RuleAnalyzer::inner_rule` 失败分支字符边界 panic 后改为逐字
    ///   执行，撤销原 ASCII-safe 合成规则绕行；`${$.len}` 内组在 toc 根
    ///   解析为空 → 原规则透传 → JS 模板串按 Array.from 回参 `$` 求值 →
    ///   info = "5200字"/"4300字"，经 updateTime 规则 + wordCountRegex
    ///   落 `WebChapter.word_count`）
    ///   - 补后：meta 命中 → bookUrl 可用 → 章节链接完整 + 字数
    ///   - 补前：字面量 `{"name":…}` 无 bookUrl → `undefined/…` 断链
    ///
    /// 注意：本用例的「补后」meta 为**单测专用播种**（`record_book_meta_from_info`
    /// 手工写入，模拟进程内已走过 webbook_info 的状态）；生产路径（DB
    /// `books.variable` 为书籍变量唯一来源、不依赖播种）由
    /// `test_book_variable_from_db_no_manual_seeding` 覆盖。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p29_real_jhsu_source_before_after() {
        let source: BookSource = serde_json::from_str(include_str!(
            "../../tests/fixtures/jhsu_book4cc_source.json"
        ))
        .expect("聚合书库书源 JSON（q9.db 逐字）");
        // 离线 fixture 详情页响应体：单行 `book={…}`（init 正则
        // `book=(\{.*\})` 不跨行）+ `.book-img img`（java.getString）
        // + `load_js('…')`（dir 规则）
        let body = "<html><head><title>聚合书库</title></head><body><div class=\"book-img\"><img src=\"https://img.book4.cc/cover/jhsu101.png\"></div><script>book={\"同书名作者其他阅读源\":[{\"book_name\":\"测试书\",\"author\":\"探针作者\",\"isok\":true,\"last_chapter_name\":\"第99章\",\"time_update\":\"2026-09-01 10:00\",\"intro\":\"简介一\",\"type_name\":\"男频\",\"book_yun_path\":\"/yun/1\"},{\"book_name\":\"测试书\",\"author\":\"探针作者\",\"isok\":false,\"last_chapter_name\":\"第98章\",\"time_update\":\"2026-09-02 11:00\",\"intro\":\"简介二\",\"type_name\":\"男频\",\"book_yun_path\":\"/yun/2\"}]};load_js('/js/load.js');</script></body></html>";

        // —— 补后：播种 meta（等价进程内已走过 webbook_info 且用户已设置
        // 书籍变量 {"custom":"2"} 的状态）→ IIFE 绑定 → init 换源 origin[1]
        let url_after = "https://book4.cc/AU文学/1/101";
        record_book_meta_from_info(
            url_after,
            &WebBookInfo {
                name: "聚合书库测试书".into(),
                author: "探针作者".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_after.into(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"2"}"#.into()),
            },
        );
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.to_string(),
            url_after,
            url_after,
            true,
            "",
            "",
        );
        assert_eq!(
            info.name, "测试书",
            "补后：init getVariable(\"custom\")=2 → origin[1].book_name"
        );
        assert_eq!(info.author, "探针作者");
        assert_eq!(
            info.last_chapter.as_deref(),
            Some("第98章•2026-09-02 11:00"),
            "补后：lastChapter 规则 $.last 取 origin[1]（custom=2 换源）"
        );
        assert_eq!(
            info.toc_url, "https://book4.cc/js/load.js/yun/2",
            "补后：tocUrl 规则 $.dir = load_js 前缀 + origin[1].book_yun_path"
        );
        assert_eq!(
            info.kind.as_deref(),
            Some("男频,2026-09-02 11:00"),
            "补后：kind 规则 $.kind = type_name,time_update"
        );
        assert_eq!(
            info.cover_url.as_deref(),
            Some("https://img.book4.cc/cover/jhsu101.png"),
            "补后：coverUrl 规则 $.cover = java.getString(\".book-img img@src\")"
        );
        let intro = info.intro.clone().unwrap_or_default();
        assert!(
            intro.contains("源列表（多个源可设置书籍变量更改接口）"),
            "补后：intro 应含 init 生成的源列表，实际: {intro}"
        );
        assert!(
            intro.contains("本书《聚合书库测试书》简介"),
            "补后：intro 模板应含 book.name（IIFE 字段面），实际: {intro}"
        );

        // —— 补前：未播种 bookUrl → 字面量回退（等价 HEAD 执行路径）
        // → init 的 book.getVariable 方法调用抛错被跳过 → 书名为空
        let url_before = "https://book4.cc/AU文学/1/102";
        let info2 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.to_string(),
            url_before,
            url_before,
            true,
            "",
            "",
        );
        assert!(
            info2.name.is_empty(),
            "补前：init 失败应回退原始响应体（$.book_name 为空），实际: {:?}",
            info2.name
        );

        // —— 目录阶段（P1-2 修复后逐字执行）：ruleToc.chapterList
        // `book.bookUrl + $.file_name` + `` String(`${$.len}字`) ``
        // 逐字规则含 `{$` 字节对（`${$.len}` 内组）：此前内组在 toc 根
        // 解析为空走失败分支，`pos += inner.len()` 落进多字节 `字` 中间
        // → 下一轮 `consume_to` 字符边界 panic（既有 bug）；P1-2 按字符
        // 边界安全前进修复后，内组未解析 → 原规则透传 JS → 模板串由
        // quickjs 求值（`$` 为 Array.from 回参）→ info = "5200字"
        let toc_url = "https://book4.cc/AU文学/1/101/toc/";
        let toc_body =
            "{\"chapter_list\":[{\"name\":\"第一章\",\"file_name\":\"/f/1.html\",\"len\":5200},{\"name\":\"第二章\",\"file_name\":\"/f/2.html\",\"len\":4300}]}";
        let fetcher = RealBookSourceFetcher::default();
        let meta = lookup_book_meta_by_book_url(url_after).expect("补后：meta 应已播种");
        let ch = crate::runtime::block_on_async(fetcher.parse_chapters_from_toc_body(
            &source,
            None,
            toc_url,
            toc_body.to_string(),
            "测试书",
            Some(&meta),
            None,
            std::time::Instant::now(),
        ))
        .expect("补后：目录解析应成功（逐字规则，不 panic）");
        assert_eq!(ch.len(), 2);
        assert_eq!(ch[0].title, "第一章");
        assert_eq!(
            ch[0].url, "https://book4.cc/AU文学/1/101/f/1.html",
            "补后：book.bookUrl 可用 → 章节链接完整"
        );
        assert_eq!(
            ch[0].word_count.as_deref(),
            Some("5200字"),
            "补后：updateTime 规则 info = JS 模板串 `${{$.len}}字` 求值结果"
        );
        assert_eq!(
            ch[1].word_count.as_deref(),
            Some("4300字"),
            "补后：第二章字数同理"
        );
        // 补前：无 meta → 字面量 {"name":…} → book.bookUrl undefined
        // → `undefined/f/1.html` 断链（HEAD 行为）
        let ch2 = crate::runtime::block_on_async(fetcher.parse_chapters_from_toc_body(
            &source,
            None,
            toc_url,
            toc_body.to_string(),
            "测试书",
            None,
            None,
            std::time::Instant::now(),
        ))
        .expect("补前：目录解析本身仍成功（规则无异常，仅字段缺失）");
        assert!(
            ch2[0].url.contains("undefined"),
            "补前：字面量无 bookUrl → 链接断为 undefined/…，实际: {}",
            ch2[0].url
        );
    }

    /// P1-1 生产路径验证（**不依赖手工播种 meta 缓存**）：
    /// 用户书籍变量的唯一生产来源是 DB `books.variable`（Dart 书籍信息页
    /// 可编辑、持久化）。生产流程 webbook_info：详情解析 →
    /// `record_book_meta_from_info`（P1-1 起按 bookUrl 读 DB 补 variable，
    /// DB 无值/为空回退 `@put` 导出）→ 同 URL 下一次详情/目录/正文调用
    /// 命中 meta 缓存 → book 绑定 IIFE → `ruleBookInfo.init` 里
    /// `book.getVariable` 取到用户值（修复前生产上永远拿不到，init 按
    /// 变量分支的行为不可达，只能靠手工播种 meta 的测试才过）。
    ///
    /// 断言口径：同一 URL 连续两次生产详情路径，第二次 init 的
    /// `book.getVariable("custom")` 等于 DB 值；并覆盖「DB 无变量 →
    /// 回退 @put 导出」两分支（无此行 / 行存在但 variable 为空）。
    /// 本用例唯一播种是 **DB 行**（即生产数据源本身）；meta 缓存由生产
    /// 函数 `record_book_meta_from_info` 写入，variable 字段不经手工注入。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_book_variable_from_db_no_manual_seeding() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 合成详情源（与 test_p29 同构）：init 读 book.getVariable("custom")
        // 产出 JSON，name 规则从 init 产出取 $.n
        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://jhsu-dbv.example.com",
            "bookSourceName": "DB书籍变量测试源",
            "ruleBookInfo": {
                "init": "<js>JSON.stringify({n: 'v=' + book.getVariable('custom')})</js>",
                "name": "$.n"
            }
        }))
        .expect("source json");
        let body = "<html><body>raw detail body</body></html>".to_string();

        // ── 主分支：DB variable 覆盖 @put 导出（用户设置 > 源规则默认）
        let url_db = "https://jhsu-dbv.example.com/b/db-wins";
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, author, variable) VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![url_db, "DB优先测试书", "测试", r#"{"custom":"db-val"}"#],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入 books 行（带 variable）");

        // 第一次详情（生产路径）：meta 尚未记录 → 字面量绑定回退 →
        // init 的 getVariable 非函数被跳过 → name 空
        let info1 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.clone(),
            url_db,
            url_db,
            true,
            "",
            "",
        );
        assert!(
            info1.name.is_empty(),
            "第一次：meta 未记录，name 应为空，实际: {:?}",
            info1.name
        );
        // 生产记录函数（P1-1 起内部按 bookUrl 读 DB；info.variable 模拟
        // @put 导出，应被 DB 值覆盖）
        record_book_meta_from_info(
            url_db,
            &WebBookInfo {
                name: "DB优先测试书".into(),
                author: "测试".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_db.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"put-export"}"#.into()),
            },
        );
        // 第二次详情（同 URL，生产路径）：meta 命中 → IIFE 绑定 →
        // init 的 getVariable("custom") = DB 值（而非 @put 导出值）
        let info2 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.clone(),
            url_db,
            url_db,
            true,
            "",
            "",
        );
        assert_eq!(
            info2.name, "v=db-val",
            "第二次：init 的 book.getVariable(\"custom\") 应等于 DB books.variable 值（DB 优先于 @put）"
        );

        // ── 回退分支 1：DB 无此书行 → 回退 @put 导出值
        let url_no = "https://jhsu-dbv.example.com/b/no-db";
        record_book_meta_from_info(
            url_no,
            &WebBookInfo {
                name: "回退测试书".into(),
                author: "测试".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_no.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"put-export"}"#.into()),
            },
        );
        let info3 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.clone(),
            url_no,
            url_no,
            true,
            "",
            "",
        );
        assert_eq!(info3.name, "v=put-export", "DB 无行：回退 @put 导出值");

        // ── 回退分支 2：DB 行存在但 variable 为空 → 同样回退 @put 导出值
        let url_empty = "https://jhsu-dbv.example.com/b/empty-var";
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, author) VALUES (?1, ?2, ?3)",
                    rusqlite::params![url_empty, "空变量测试书", "测试"],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入 books 行（variable 为 NULL）");
        record_book_meta_from_info(
            url_empty,
            &WebBookInfo {
                name: "空变量测试书".into(),
                author: "测试".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_empty.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"put-export"}"#.into()),
            },
        );
        let info4 = RealBookSourceFetcher::parse_book_info_from_body(
            &source, body, url_empty, url_empty, true, "", "",
        );
        assert_eq!(
            info4.name, "v=put-export",
            "DB 行 variable 为空：回退 @put 导出值"
        );

        // 清理：共享内存库，删除本用例插入的行，防跨测试污染
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "DELETE FROM books WHERE bookUrl IN (?1, ?2, ?3)",
                    rusqlite::params![url_db, url_no, url_empty],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("清理本用例插入的 books 行");
    }

    /// P2-9 源级验证（补后，离线）：真实 🎬艾格动漫 书源
    /// （q9.db book_sources 逐字 JSON，fixture `aigei_agedm_source.json`）
    ///
    /// **项①命中源**：`ruleBookInfo.intro` 3 处 `java.getStringList(...)`
    /// + `source.getVariable()`。补后 java 面已有 getStringList → intro
    /// 得到线路/集数列表；补前（HEAD，`git grep getStringList HEAD --
    /// rust/legado-js` 零命中）同一 JS 抛错、列表缺失 —— HEAD 侧原始
    /// 输出由 worktree 探针 p29_head_probe 捕获
    // （.tmp/p29_head_probe_out.log）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p29_real_aigei_source_getstringlist() {
        let source: BookSource =
            serde_json::from_str(include_str!("../../tests/fixtures/aigei_agedm_source.json"))
                .expect("艾格动漫书源 JSON（q9.db 逐字）");
        // 离线 fixture 详情页响应体：.nav-pills 线路列表 + 各线路
        // `id.xxx` 面板（供 getStringList 的 CSS 选择器）
        let body = "<html><head><title>测试动漫</title></head><body><div class=\"video_detail_desc\">一部悬疑与幽默并存的经典动画，剧情精彩。</div><ul class=\"nav nav-pills\"><li class=\"nav-item\"><a class=\"nav-link active\" data-bs-target=\"#line_a\">线路A</a></li><li class=\"nav-item\"><a class=\"nav-link\" data-bs-target=\"#line_b\">线路B</a></li></ul><div id=\"line_a\"><ul><li><a>第1集</a></li><li><a>第2集</a></li><li><a>第3集</a></li></ul></div><div id=\"line_b\"><ul><li><a>B线第1集</a></li></ul></div></body></html>";
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.to_string(),
            "https://www.agedm.org/detail/9",
            "https://www.agedm.org/detail/9",
            true,
            "",
            "",
        );
        let intro = info.intro.clone().unwrap_or_default();
        assert!(
            intro.contains("可以修改源变量查看不同线路，当前：1"),
            "补后：intro 应含源变量提示（source.getVariable 空 → 回退 1），实际: {intro}"
        );
        assert!(
            intro.contains("源名称：线路A，源变量：1，共：3集"),
            "补后：java.getStringList 应取到线路A 3 集，实际: {intro}"
        );
        assert!(
            intro.contains("源名称：线路B，源变量：2，共：1集"),
            "补后：java.getStringList 应取到线路B 1 集，实际: {intro}"
        );
        assert!(
            intro.contains("一部悬疑与幽默并存的经典动画"),
            "补后：多行规则末行 `str+result` 应追加 CSS 段（.video_detail_desc@text），实际: {intro}"
        );
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
                let hex_ok = body.len() % 2 == 0 && body.bytes().all(|b| b.is_ascii_hexdigit());
                eprintln!("合法 hex: {}", hex_ok);
            }
            other => eprintln!(
                "fetch_data_uri_content = {:?}",
                other.map(|r| r.map(|b| b.len()))
            ),
        }
    }

    #[test]
    fn test_webbook_content_empty_chapter_url_returns_error() {
        let chapter_json = serde_json::to_string(&WebChapter::new(0, "第一章", "")).unwrap();
        let err = webbook_content(&make_source_json(), &chapter_json).unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }

    // ─── [T3/T4/T5 换源变量链] 单测（2026-09-03）──────────────────────────

    /// T4：章节 variable JSON → AnalyzeUrl 变量表（值字符串化、坏输入容忍）
    #[test]
    fn test_chapter_url_variables() {
        let vars = chapter_url_variables(Some(r#"{"token":"abc","n":3}"#));
        assert_eq!(vars.get("token").map(String::as_str), Some("abc"));
        assert_eq!(vars.get("n").map(String::as_str), Some("3"));
        assert!(chapter_url_variables(Some("not-json")).is_empty());
        assert!(chapter_url_variables(Some("  ")).is_empty());
        assert!(chapter_url_variables(None).is_empty());
    }

    /// T4：变量合并——overlay（章节级）同名键覆盖 base（书级），均空 → None
    #[test]
    fn test_merge_variables_json_overlay_wins() {
        let base = r#"{"a":"1","b":"old"}"#;
        let overlay = r#"{"b":"new","c":true}"#;
        let merged = merge_variables_json(Some(base), Some(overlay)).unwrap();
        let v: serde_json::Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(v["a"], serde_json::json!("1"));
        assert_eq!(v["b"], serde_json::json!("new"));
        assert_eq!(v["c"], serde_json::json!(true));
        assert_eq!(merge_variables_json(None, None), None);
        assert_eq!(merge_variables_json(Some("not-json"), None), None);
        assert_eq!(
            merge_variables_json(Some(base), None).as_deref(),
            Some(base)
        );
    }

    /// T3：bookInfo 规则求值期间的 @put 级联导出为 WebBookInfo.variable
    #[test]
    fn test_parse_book_info_exports_put_variables() {
        use legado_core::models::rule::BookInfoRule;
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_book_info: Some(BookInfoRule {
                name: Some("class.name".to_string()),
                intro: Some("class.intro".to_string()),
                // intro 主规则求值后同元素上的 @put：token ← class.token 文本
                ..BookInfoRule::default()
            }),
            ..BookSource::default()
        };
        let body = "<html><body><div class='name'>解析书名</div><div class='intro'>简介</div><div class='token'>abc123</div></body></html>";
        // @put 挂在 intro 规则上：intro 主规则取文本，put 子规则 class.token
        // 对同一分析器内容求值（整 body），写入变量表
        let source = BookSource {
            rule_book_info: Some(BookInfoRule {
                name: Some("class.name".to_string()),
                intro: Some("class.intro@put:{token:class.token}".to_string()),
                ..BookInfoRule::default()
            }),
            ..source
        };
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            body.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            false,
            "旧名",
            "旧作者",
        );
        let variable = info.variable.expect("@put 变量应被导出");
        let v: serde_json::Value = serde_json::from_str(&variable).unwrap();
        assert_eq!(v["token"], serde_json::json!("abc123"));
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
        assert_eq!(
            info.categories,
            vec!["科幻".to_string(), "悬疑".to_string()]
        );
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
        let mpd =
            r#"<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period/></MPD>"#;
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
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = LegadoResult<String>> + Send>,
    > {
        move |url: String| {
            let body = pages.get(&url).cloned();
            Box::pin(
                async move { body.ok_or_else(|| LegadoError::Network(format!("404 for {url}"))) },
            )
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
            None, // book_meta：测试无 book 元信息（降级空 name 字面量）
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
            None, // book_meta：测试无 book 元信息（降级空 name 字面量）
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
            "<html><body><div class='content'><p>分卷B正文</p></div></body></html>".to_string(),
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
            None, // book_meta：测试无 book 元信息（降级空 name 字面量）
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
            None, // book_meta：测试无 book 元信息（降级空 name 字面量）
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
    fn test_apply_regex_replace_no_match_empty_cross() {
        // P1-2 交叉断言：与解析器 `apply_hash_replace` 的
        // `$.v##zzz##REP###`（v="abc" → ""）语义一致——replaceFirst 无匹配
        // 返回空串（对标 Kotlin group(0).replaceFirst 的 else 分支）。
        assert_eq!(apply_regex_replace("abc", "zzz", "REP", true), "");
        // 有匹配时仅取首匹配段做替换、其余丢弃（与解析器同语义）
        assert_eq!(apply_regex_replace("abc", "b", "X", true), "X");
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
    #[cfg(feature = "quickjs")]
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
    #[cfg(feature = "quickjs")]
    fn qmao_js_rule_extracts_m3u8_from_saved_html() {
        let html_path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/qmao_play_full.html"
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
            word_count: None,
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

    // N5: 字数正则（对标原版 AppPattern.wordCountRegex）
    #[test]
    fn word_count_regex_extraction() {
        let re = super::word_count_regex();
        // 纯前缀 / 字数前缀（含全半角冒号顿号）/ 空白前缀
        assert_eq!(
            re.captures("2510字")
                .and_then(|c| c.get(1))
                .map(|m| m.as_str()),
            Some("2510字")
        );
        assert_eq!(
            re.captures("字数：2510字")
                .and_then(|c| c.get(1))
                .map(|m| m.as_str()),
            Some("2510字")
        );
        assert_eq!(
            re.captures("字数: 3.2万字")
                .and_then(|c| c.get(1))
                .map(|m| m.as_str()),
            Some("3.2万字")
        );
        assert_eq!(
            re.captures(" 1200字")
                .and_then(|c| c.get(1))
                .map(|m| m.as_str()),
            Some("1200字")
        );
        // 无字数文本不匹配
        assert!(re.captures("2026-01-01").is_none());
        assert!(re.captures("").is_none());
    }

    // ─── [P2-12] 换源书重进详情/目录刷新变量链回归（2026-09-18） ─────────────

    /// [P2-12] 脚本化详情/目录 fetcher：捕获调用方传入的变量表，并按真实
    /// 请求构造（`AnalyzeUrl::parse`，`{{key}}` 简单名直接经变量表解析，
    /// 见 `replace_inner_expressions`）展开请求模板、记录最终请求 URL——
    /// 用于断言「DB books.variable 流入了请求」（修复前变量表恒空 →
    /// `?vid=` 空值 → 服务端 400 的回归点）
    struct P12VarFetcher {
        vars_received:
            std::sync::Arc<std::sync::Mutex<Vec<std::collections::HashMap<String, String>>>>,
        detail_urls: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
        toc_urls: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    }

    impl BookSourceFetcher for P12VarFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<WebBookInfo> {
            Err(LegadoError::Internal("mock: get_book_info unused".into()))
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            Err(LegadoError::Internal("mock: get_chapters unused".into()))
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }

        /// 详情变量表路径：仿真实请求构造——bookUrl 模板经变量表展开
        async fn get_book_info_with_existing_and_vars(
            &self,
            _source: &BookSource,
            book_url: &str,
            _can_re_name: bool,
            _existing_name: &str,
            _existing_author: &str,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<WebBookInfo> {
            self.vars_received
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            let req = AnalyzeUrl::parse(book_url, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("详情 URL 解析失败: {e}")))?;
            self.detail_urls
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(req.url().to_string());
            Ok(WebBookInfo {
                name: "R1换源验证书".to_string(),
                author: "测试".to_string(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: book_url.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: None,
            })
        }

        /// 目录变量表路径：已知目录页（或回退详情 URL）模板经变量表展开
        async fn get_chapters_with_hints_and_vars(
            &self,
            _source: &BookSource,
            book_url: &str,
            known_toc_url: Option<&str>,
            _book_name_hint: Option<&str>,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.vars_received
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            let template = known_toc_url.unwrap_or(book_url);
            let req = AnalyzeUrl::parse(template, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("目录 URL 解析失败: {e}")))?;
            self.toc_urls
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(req.url().to_string());
            Ok(vec![WebChapter {
                index: 0,
                title: "第一章".to_string(),
                url: format!("{}/c1", req.url()),
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            }])
        }
    }

    /// [P2-12] 换源书「回书架 → 重进详情/刷新目录」：请求模板必须用 DB
    /// `books.variable` 展开（回归：修复前重进/U7 路径变量表恒空 →
    /// `{{svid}}`/`{{tok}}` 展开为空 → mock 服务端对 `?vid=`/`?tok=` 400，
    /// 而换源主链（候选 ⊕ 详情导出）正确）
    ///
    /// 唯一播种点是 **DB 行**（生产数据源本身）：播种换源后书籍行
    /// （bookUrl = 旧源稳定主键、originBookUrl = 新源取址点、variable =
    /// 候选 ⊕ 详情导出合并持久值），请求链路的变量表不经手工注入——全部
    /// 来自 `db_book_variable` 两路查找（bookUrl → originBookUrl）的回读。
    #[test]
    fn test_p212_reenter_detail_expands_db_variables() {
        use std::sync::{Arc, Mutex};

        let _db_guard = crate::db_state::ensure_test_db();

        let old_book_url = "https://old-src.example.com/r1vb/detail?vid={{svid}}";
        let fetch_url = "https://r1vb.local/r1vb/detail?vid={{svid}}"; // originBookUrl（Dart 取址点）
        let toc_template = "https://r1vb.local/r1vb/toc?tok={{tok}}";
        let var_json = r#"{"svid":"VID123","tok":"TK777"}"#;

        // 播种换源后书籍行（唯一播种点；originBookUrl 非空 = 已换源）
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, originBookUrl, tocUrl, variable)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    rusqlite::params![
                        old_book_url,
                        "R1换源验证书",
                        fetch_url,
                        toc_template,
                        var_json
                    ],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入换源书籍行");

        // 两路反查：取址点（originBookUrl）命中 + 稳定主键（bookUrl）命中
        assert_eq!(
            db_book_variable(fetch_url).as_deref(),
            Some(var_json),
            "换源书按取址点（originBookUrl）须命中 books.variable"
        );
        assert_eq!(
            db_book_variable(old_book_url).as_deref(),
            Some(var_json),
            "稳定主键（bookUrl）亦须命中 books.variable"
        );

        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://r1vb.local",
            "bookSourceName": "P12变量链测试源",
        }))
        .expect("source json");

        let vars_received = Arc::new(Mutex::new(Vec::new()));
        let detail_urls = Arc::new(Mutex::new(Vec::new()));
        let toc_urls = Arc::new(Mutex::new(Vec::new()));
        let fetcher = P12VarFetcher {
            vars_received: Arc::clone(&vars_received),
            detail_urls: Arc::clone(&detail_urls),
            toc_urls: Arc::clone(&toc_urls),
        };

        // ① 重进详情（U7 取址点 = originBookUrl）：变量表来自 DB 回读
        let info = runtime::block_on(webbook_info_with_fetcher(&source, fetch_url, &fetcher))
            .expect("重进详情应成功");
        assert_eq!(info.name, "R1换源验证书");

        let detail = detail_urls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(
            detail,
            vec!["https://r1vb.local/r1vb/detail?vid=VID123".to_string()],
            "详情请求模板应按 DB 变量展开（修复前回归：?vid= 为空）"
        );
        let vars = vars_received
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(vars.len(), 1, "详情请求应恰好传入一次变量表");
        assert_eq!(
            vars[0].get("svid").map(String::as_str),
            Some("VID123"),
            "svid 应自 DB books.variable 回读（请求链无手工注入）"
        );
        assert_eq!(vars[0].get("tok").map(String::as_str), Some("TK777"));

        // ② 重拉目录（已知目录页模板含 {{tok}}）
        let chapters = runtime::block_on(webbook_chapters_with_fetcher(
            &source,
            fetch_url,
            Some(toc_template),
            Some("R1换源验证书"),
            &fetcher,
        ))
        .expect("目录抓取应成功");
        assert_eq!(chapters.len(), 1, "mock 目录应解析 1 章");

        let toc = toc_urls.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(
            toc,
            vec!["https://r1vb.local/r1vb/toc?tok=TK777".to_string()],
            "目录请求模板应按 DB 变量展开（修复前回归：?tok= 为空）"
        );

        // 清理：共享内存库，删除本用例插入的行，防跨测试污染
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "DELETE FROM books WHERE bookUrl = ?1",
                    rusqlite::params![old_book_url],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("清理本用例插入的 books 行");
    }

    /// [P2-12] 未换源书：取址点即 bookUrl（`find_by_url` 直接命中），
    /// 变量表同样来自 DB `books.variable` 回读（bookUrl 模板含 `{{key}}`
    /// 的存量书籍：重进详情/目录刷新须携 DB 变量，行为与换源书一致）
    #[test]
    fn test_p212_unswitched_book_route_hits_by_book_url() {
        use std::sync::{Arc, Mutex};

        let _db_guard = crate::db_state::ensure_test_db();

        let book_url = "https://plain.example.com/d/42?sid={{sid}}";
        let var_json = r#"{"sid":"S999"}"#;

        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, variable) VALUES (?1, ?2, ?3)",
                    rusqlite::params![book_url, "未换源变量书", var_json],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入未换源书籍行");

        // bookUrl 路命中（originBookUrl 为空的存量书）
        assert_eq!(db_book_variable(book_url).as_deref(), Some(var_json));

        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://plain.example.com",
            "bookSourceName": "P12未换源测试源",
        }))
        .expect("source json");

        let detail_urls = Arc::new(Mutex::new(Vec::new()));
        let fetcher = P12VarFetcher {
            vars_received: Arc::new(Mutex::new(Vec::new())),
            detail_urls: Arc::clone(&detail_urls),
            toc_urls: Arc::new(Mutex::new(Vec::new())),
        };
        let info = runtime::block_on(webbook_info_with_fetcher(&source, book_url, &fetcher))
            .expect("未换源书重进详情应成功");
        assert_eq!(info.name, "R1换源验证书", "mock 固定返回，仅验证链路打通");

        let detail = detail_urls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(
            detail,
            vec!["https://plain.example.com/d/42?sid=S999".to_string()],
            "未换源书详情模板应经 find_by_url 路命中 DB 变量展开"
        );

        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "DELETE FROM books WHERE bookUrl = ?1",
                    rusqlite::params![book_url],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("清理本用例插入的 books 行");
    }
}
