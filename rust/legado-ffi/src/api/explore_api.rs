//! 发现页（Explore）FFI API
//!
//! 为 Flutter/Dart 提供发现页分类解析和书籍抓取能力。
//! 对标 Android 端 ExploreShowActivity / ExploreShowViewModel。
//!
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。

use std::collections::HashMap;

use legado_core::explore::{parse_explore_url, ExploreCategory};
use legado_core::models::BookSource;
use legado_core::web_book::WebSearchResult;
use legado_core::{LegadoError, LegadoResult};
use legado_parser::AnalyzeUrl;
use serde::Serialize;

use crate::api::explore_info_map;
use crate::runtime;

/// 发现控件 action 执行结果（camelCase JSON）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExploreEvalActionResult {
    pub raw: String,
    pub actions: Vec<serde_json::Value>,
    pub refresh_explore: bool,
}

/// 执行发现页 button/toggle/select/text 的 action JS（对标 Android evalButtonClick）
pub fn explore_eval_action(source_json: &str, action_js: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    #[cfg(feature = "quickjs")]
    {
        let result = eval_explore_action_js(action_js, &source)?;
        return serde_json::to_string(&result).map_err(LegadoError::Serialization);
    }
    #[cfg(not(feature = "quickjs"))]
    {
        let _ = (source_json, action_js, source);
        Err(LegadoError::JsEngine(
            "QuickJS engine not enabled. Build with --features quickjs".into(),
        ))
    }
}

/// 执行发现页 viewName 动态标题 JS（对标 Android evalUiJs）
pub fn explore_eval_ui_js(source_json: &str, js_str: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    #[cfg(feature = "quickjs")]
    {
        return eval_explore_ui_js(js_str, &source);
    }
    #[cfg(not(feature = "quickjs"))]
    {
        let _ = (source_json, js_str, source);
        Err(LegadoError::JsEngine(
            "QuickJS engine not enabled. Build with --features quickjs".into(),
        ))
    }
}

/// 写入发现 infoMap 键值（对标 Android ExploreAdapter toggle/select）
pub fn explore_info_map_put(source_url: &str, key: &str, value: &str) -> LegadoResult<()> {
    explore_info_map::put(source_url, key, value)
}

/// 初始化发现 infoMap 默认值（键不存在时写入）
pub fn explore_info_map_ensure_default(
    source_url: &str,
    key: &str,
    default_value: &str,
) -> LegadoResult<()> {
    explore_info_map::ensure_default(source_url, key, default_value)
}

/// 解析 exploreUrl 为分类列表
///
/// `explore_url` — 书源的 exploreUrl 字段
/// `source_json` — BookSource JSON（`@js:` / `<js>` exploreUrl 必填；纯文本可为空）
///
/// 返回 `ExploreCategory` JSON 数组字符串
pub fn explore_parse_url(explore_url: &str, source_json: &str) -> LegadoResult<String> {
    let source = parse_source_for_explore_optional(source_json)?;
    let rule_str = resolve_explore_rule_str(explore_url, source_json, source.as_ref())?;
    let categories: Vec<ExploreCategory> = parse_explore_url(&rule_str);
    if let Some(src) = source.as_ref() {
        init_info_map_defaults(&src.book_source_url, &categories);
    }
    serde_json::to_string(&categories).map_err(LegadoError::Serialization)
}

/// 为 toggle/select 分类初始化 infoMap 默认值
fn init_info_map_defaults(source_url: &str, categories: &[ExploreCategory]) {
    for cat in categories {
        if cat.r#type != "toggle" && cat.r#type != "select" {
            continue;
        }
        let chars: Vec<&str> = cat
            .chars
            .as_ref()
            .map(|list| {
                list.iter()
                    .filter_map(|v| v.as_deref())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        if chars.is_empty() {
            continue;
        }
        let default = cat
            .default_value
            .as_deref()
            .filter(|s| !s.is_empty())
            .unwrap_or(chars[0]);
        let _ = explore_info_map::ensure_default(source_url, &cat.title, default);
    }
}

/// 抓取发现分类的书籍列表
///
/// 对标 Android WebBook.exploreBookAwait：
/// 1. 使用 AnalyzeUrl 解析分类 URL（替换页码占位符）
/// 2. 发起 HTTP 请求获取页面内容
/// 3. 使用 ruleExplore 规则解析书籍列表
///
/// # 参数
/// - `source_json`: BookSource JSON 字符串
/// - `url`: 分类 URL（可能含页码占位符）
/// - `page`: 页码（从 1 开始）
///
/// # 返回
/// `WebSearchResult` JSON 数组字符串
pub fn explore_fetch_books(source_json: &str, url: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    if url.is_empty() {
        return Err(LegadoError::Internal("发现分类 URL 为空".into()));
    }

    // JS 书源分派：spawn_blocking 避免嵌套 runtime 死锁（R1）
    if source.is_js_source() {
        let source_clone = source.clone();
        let url_clone = url.to_string();
        let values = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let mut orchestrator = crate::api::web_book::build_js_orchestrator(&source_clone)?
                    .ok_or_else(|| LegadoError::Internal("JS 书源缺少 mainJs".into()))?;
                orchestrator.explore(&source_clone, &url_clone, page)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 发现任务异常: {e}")))?
        })?;
        let results = crate::api::web_book::convert_js_search_results(
            values,
            &source.book_source_url,
        );
        return serde_json::to_string(&results).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
    let results: Vec<WebSearchResult> =
        runtime::block_on(async { explore_books_async(&source, url, page).await })?;

    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

// ─── exploreUrl @js: 解析 ─────────────────────────────────────────────────────

/// 将 exploreUrl 解析为可分类的规则字符串（对标 Android exploreKinds）
fn resolve_explore_rule_str(
    explore_url: &str,
    source_json: &str,
    source: Option<&BookSource>,
) -> LegadoResult<String> {
    let trimmed = explore_url.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }

    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("@js:") {
        let js_code = trimmed.get(4..).unwrap_or("").trim();
        if js_code.is_empty() {
            return Ok(String::new());
        }
        let source = match source.cloned() {
            Some(s) => s,
            None => parse_source_for_explore(source_json)?,
        };
        return eval_explore_js(js_code, &source);
    }

    if lower.starts_with("<js>") {
        let js_code = extract_js_tag_body(trimmed);
        if js_code.is_empty() {
            return Ok(String::new());
        }
        let source = match source.cloned() {
            Some(s) => s,
            None => parse_source_for_explore(source_json)?,
        };
        return eval_explore_js(&js_code, &source);
    }

    Ok(trimmed.to_string())
}

fn parse_source_for_explore_optional(source_json: &str) -> LegadoResult<Option<BookSource>> {
    if source_json.trim().is_empty() {
        return Ok(None);
    }
    serde_json::from_str(source_json)
        .map(Some)
        .map_err(LegadoError::Serialization)
}

fn parse_source_for_explore(source_json: &str) -> LegadoResult<BookSource> {
    if source_json.trim().is_empty() {
        return Err(LegadoError::Internal(
            "@js: exploreUrl 需要书源 JSON 上下文".into(),
        ));
    }
    serde_json::from_str(source_json).map_err(LegadoError::Serialization)
}

fn extract_js_tag_body(s: &str) -> String {
    let lower = s.to_ascii_lowercase();
    if let Some(start) = lower.find("<js>") {
        let content_start = start + "<js>".len();
        if let Some(end) = lower.rfind("</js>") {
            if end >= content_start {
                return s[content_start..end].trim().to_string();
            }
        }
        return s[content_start..].trim().to_string();
    }
    String::new()
}

/// 执行 exploreUrl 内嵌 JS（对标 Android runScriptWithContext + evalJS + infoMap）
#[cfg(feature = "quickjs")]
fn eval_explore_js(js_code: &str, source: &BookSource) -> LegadoResult<String> {
    use legado_js::JsEngine;
    use legado_js::host_api::current_source::with_current_source_tag;

    let tag = source.book_source_url.clone();
    let engine = crate::js_executor::fresh_engine(&tag)?;
    let guard = engine
        .lock()
        .map_err(|e| LegadoError::JsEngine(format!("JS 引擎加锁失败: {e}")))?;

    with_current_source_tag(&tag, || {
        bootstrap_explore_js_context(&guard, source)?;

        let encoded = serde_json::to_string(js_code)
            .map_err(|e| LegadoError::JsEngine(format!("exploreUrl 脚本编码失败: {e}")))?;
        // eval 对标 Android Rhino：多语句时返回最后一条表达式的值
        let wrapped = format!(
            r#"(function() {{
var __r = eval({encoded});
if (__r === null || __r === undefined) return '';
if (typeof __r === 'string') return String(__r).trim();
try {{ return JSON.stringify(__r); }} catch (e) {{ return String(__r); }}
}})()"#,
            encoded = encoded
        );

        let result = guard
            .eval(&wrapped)
            .map_err(|e| LegadoError::JsEngine(format!("exploreUrl JS 执行失败: {e}")))?;

        sync_login_cache_from_js(&tag);
        sync_info_map_from_js(&*guard, &tag)?;

        Ok(result.trim().to_string())
    })
}

/// 加载 jsLib / mainJs 并注入 explore 上下文（source/infoMap/java 对齐 Android evalJS）
#[cfg(feature = "quickjs")]
fn bootstrap_explore_js_context(
    guard: &legado_js::QuickJsEngine,
    source: &BookSource,
) -> LegadoResult<()> {
    use legado_js::JsEngine;

    crate::api::source_js_bindings::load_js_lib_for_explore(guard, source.js_lib.as_deref());

    // JS 单文件书源：exploreUrl @js: 常调用 mainJs 内定义的函数
    if source.is_js_source() {
        if let Some(main_js) = source.main_js.as_deref() {
            let main_js = main_js.trim();
            if !main_js.is_empty() {
                if let Err(e) = guard.eval(main_js) {
                    eprintln!("[explore] mainJs 加载失败: {e}");
                    return Err(LegadoError::JsEngine(format!(
                        "exploreUrl mainJs 加载失败: {e}"
                    )));
                }
            }
        }
    }

    let setup = crate::api::source_js_bindings::book_source_js_setup_script(source)?;
    guard
        .eval(&setup)
        .map_err(|e| LegadoError::JsEngine(format!("exploreUrl 上下文初始化失败: {e}")))?;
    Ok(())
}

/// explore JS 执行后把 variable_store 中的登录缓存写回 DB
/// （公共实现见 [`crate::api::source_login_cache::sync_login_cache_from_js`]）
#[cfg(feature = "quickjs")]
fn sync_login_cache_from_js(source_url: &str) {
    crate::api::source_login_cache::sync_login_cache_from_js(source_url);
}

/// action 执行后将 JS infoMap 写回 Rust 存储
#[cfg(feature = "quickjs")]
fn sync_info_map_from_js(
    guard: &legado_js::QuickJsEngine,
    source_url: &str,
) -> LegadoResult<()> {
    use legado_js::JsEngine;
    let sync_script = r#"
(function() {
  try {
    if (typeof infoMap !== 'object' || infoMap === null) return '{}';
    var out = {};
    for (var k in infoMap) {
      if (!Object.prototype.hasOwnProperty.call(infoMap, k)) continue;
      if (typeof infoMap[k] === 'function') continue;
      out[k] = String(infoMap[k]);
    }
    return JSON.stringify(out);
  } catch (e) {
    return '{}';
  }
})()
"#;
    let json = guard
        .eval(sync_script)
        .map_err(|e| LegadoError::JsEngine(format!("infoMap 同步失败: {e}")))?;
    let map: std::collections::HashMap<String, String> =
        serde_json::from_str(json.trim()).unwrap_or_default();
    for (k, v) in map {
        let _ = explore_info_map::put(source_url, &k, &v);
    }
    Ok(())
}

#[cfg(feature = "quickjs")]
fn eval_explore_action_js(
    action_js: &str,
    source: &BookSource,
) -> LegadoResult<ExploreEvalActionResult> {
    use legado_js::JsEngine;
    use legado_js::host_api::current_source::with_current_source_tag;
    use legado_js::host_api::ui_action_queue;

    let tag = source.book_source_url.clone();
    let engine = crate::js_executor::fresh_engine(&tag)?;
    let guard = engine
        .lock()
        .map_err(|e| LegadoError::JsEngine(format!("JS 引擎加锁失败: {e}")))?;

    ui_action_queue::begin_collect();
    let result = (|| -> LegadoResult<ExploreEvalActionResult> {
        with_current_source_tag(&tag, || {
            bootstrap_explore_js_context(&guard, source)?;

            let raw = guard
                .eval(action_js)
                .map_err(|e| LegadoError::JsEngine(format!("explore action JS 执行失败: {e}")))?;

            sync_info_map_from_js(&*guard, &tag)?;
            sync_login_cache_from_js(&tag);

            let refresh_explore = ui_action_queue::take_refresh_explore_requested();
            let actions = ui_action_queue::end_collect();
            Ok(ExploreEvalActionResult {
                raw,
                actions,
                refresh_explore,
            })
        })
    })();

    match result {
        Ok(v) => Ok(v),
        Err(e) => {
            ui_action_queue::discard_collect();
            ui_action_queue::take_refresh_explore_requested();
            Err(e)
        }
    }
}

#[cfg(feature = "quickjs")]
fn eval_explore_ui_js(js_str: &str, source: &BookSource) -> LegadoResult<String> {
    use legado_js::JsEngine;
    use legado_js::host_api::current_source::with_current_source_tag;

    let tag = source.book_source_url.clone();
    let engine = crate::js_executor::fresh_engine(&tag)?;
    let guard = engine
        .lock()
        .map_err(|e| LegadoError::JsEngine(format!("JS 引擎加锁失败: {e}")))?;

    with_current_source_tag(&tag, || {
        bootstrap_explore_js_context(&guard, source)?;

        guard
            .eval(js_str)
            .map(|s| s.trim().to_string())
            .map_err(|e| LegadoError::JsEngine(format!("explore ui JS 执行失败: {e}")))
    })
}

#[cfg(not(feature = "quickjs"))]
fn eval_explore_js(_js_code: &str, _source: &BookSource) -> LegadoResult<String> {
    Err(LegadoError::JsEngine(
        "QuickJS engine not enabled. Build with --features quickjs".into(),
    ))
}

// ─── 内部异步实现 ─────────────────────────────────────────────────────────────

/// 异步抓取发现分类书籍（内部实现）
async fn explore_books_async(
    source: &BookSource,
    url: &str,
    page: i32,
) -> LegadoResult<Vec<WebSearchResult>> {
    // 解析书源 header（对齐原版 getHeaderMap(hasLoginHeader=true)：
    // 静态 header + loginHeader 覆盖 + JS setCookie 全局 Cookie 兜底）— DeepSeek Harness + Bridge
    let mut source_headers: HashMap<String, String> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok())
        .unwrap_or_default();
    if let Some(login_header_json) =
        crate::api::source_login_cache::get_login_header(&source.book_source_url)
    {
        if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(&login_header_json) {
            source_headers.extend(map);
        }
    }
    let js_cookie = legado_js::host_api::cookie_store::get_cookie(&source.book_source_url);
    if !js_cookie.is_empty() && !source_headers.contains_key("Cookie") {
        source_headers.insert("Cookie".to_string(), js_cookie);
    }
    let source_headers = if source_headers.is_empty() {
        None
    } else {
        Some(source_headers)
    };

    // 规则书源路径
    let info_map = explore_info_map::snapshot(&source.book_source_url).unwrap_or_default();
    let analyze_url = crate::js_executor::build_explore_url(
        url,
        page,
        &source.book_source_url,
        &info_map,
        source.js_lib.as_deref(),
    );

    let final_url = analyze_url.url().to_string();
    if final_url.is_empty() {
        return Err(LegadoError::Internal("解析后发现 URL 为空".into()));
    }

    // 发起 HTTP 请求（复用进程共享客户端单例）
    let client = crate::http_state::shared_client()?;

    // 合并请求头：书源全局 header + AnalyzeUrl 解析出的 header
    let mut headers = source_headers.clone().unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    let response = client
        .get(&final_url, headers_opt)
        .await
        .map_err(|e| LegadoError::Network(format!("请求发现页失败: {e}")))?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "HTTP {} for {}",
            response.status, final_url
        )));
    }

    // loginCheckJs 登录检测（对齐原版 WebBook.exploreBookAwait:148-172 +
    // web_book::RealBookSourceFetcher::execute_login_check 双路径）：
    // 未登录上抛 LoginRequired，由 UI 引导登录，避免把登录页/验证页当正常内容解析。
    // — DeepSeek Harness + Bridge（2026-08-14 发现页修复 R3）
    explore_login_check(source, &response.body, &response.url, response.status)?;

    let body = response.body;

    // 对齐原版 BookList：explore.bookList 为空时回退 search 规则
    let explore_rule = source.rule_explore.as_ref();
    let search_rule = source.rule_search.as_ref();
    let use_search_fallback = explore_rule
        .and_then(|r| r.book_list.as_deref())
        .unwrap_or("")
        .is_empty();

    let book_list_rule = if use_search_fallback {
        search_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("")
    } else {
        explore_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("")
    };

    // `-`/`+` 前缀（对齐原版 BookList.kt:90-96）：`-` 反转结果、`+` 剥离前缀 — A6
    let mut reverse = false;
    let mut book_list_rule = book_list_rule.to_string();
    if book_list_rule.starts_with('-') {
        reverse = true;
        book_list_rule = book_list_rule[1..].to_string();
    } else if book_list_rule.starts_with('+') {
        book_list_rule = book_list_rule[1..].to_string();
    }

    // 重定向后的最终 URL 作为 base（对齐原版 WebBook.kt:173-181 用 res.url）— A5
    let base_url = response.url.clone();
    let t_parse = std::time::Instant::now();
    let analyzer =
        crate::js_executor::construct_analyzer(body, base_url.clone(), &source.book_source_url);

    let elements = if book_list_rule.is_empty() {
        vec![analyzer.content().to_string()]
    } else {
        analyzer
            .get_elements(&book_list_rule)
            .unwrap_or_default()
    };

    // 规则提到循环外；单一 AnalyzeRule + setContent 复用（对齐原版 BookList）
    let name_rule = if use_search_fallback {
        search_rule.and_then(|r| r.name.as_deref()).unwrap_or("")
    } else {
        explore_rule.and_then(|r| r.name.as_deref()).unwrap_or("")
    };
    let author_rule = if use_search_fallback {
        search_rule.and_then(|r| r.author.as_deref()).unwrap_or("")
    } else {
        explore_rule.and_then(|r| r.author.as_deref()).unwrap_or("")
    };
    let book_url_rule = if use_search_fallback {
        search_rule.and_then(|r| r.book_url.as_deref()).unwrap_or("")
    } else {
        explore_rule.and_then(|r| r.book_url.as_deref()).unwrap_or("")
    };
    let cover_url_rule = if use_search_fallback {
        search_rule.and_then(|r| r.cover_url.as_deref()).unwrap_or("")
    } else {
        explore_rule.and_then(|r| r.cover_url.as_deref()).unwrap_or("")
    };
    let intro_rule = if use_search_fallback {
        search_rule.and_then(|r| r.intro.as_deref()).unwrap_or("")
    } else {
        explore_rule.and_then(|r| r.intro.as_deref()).unwrap_or("")
    };
    let last_chapter_rule = if use_search_fallback {
        search_rule
            .and_then(|r| r.last_chapter.as_deref())
            .unwrap_or("")
    } else {
        explore_rule
            .and_then(|r| r.last_chapter.as_deref())
            .unwrap_or("")
    };
    let kind_rule = if use_search_fallback {
        search_rule.and_then(|r| r.kind.as_deref()).unwrap_or("")
    } else {
        explore_rule.and_then(|r| r.kind.as_deref()).unwrap_or("")
    };
    let word_count_rule = if use_search_fallback {
        search_rule
            .and_then(|r| r.word_count.as_deref())
            .unwrap_or("")
    } else {
        explore_rule
            .and_then(|r| r.word_count.as_deref())
            .unwrap_or("")
    };

    let mut elem_analyzer =
        crate::js_executor::construct_analyzer(String::new(), base_url.clone(), &source.book_source_url);

    let mut results = Vec::with_capacity(elements.len().min(50));
    for elem in elements.iter() {
        elem_analyzer.set_content(elem.clone());

        let name = elem_analyzer.get_string(name_rule).unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        // 书名/作者清洗（对齐原版 BookHelp.formatBookName/formatBookAuthor）— A2
        let name = format_book_name(&name);
        if name.is_empty() {
            continue;
        }
        let author = format_book_author(&elem_analyzer.get_string(author_rule).unwrap_or_default());
        let book_url_raw = elem_analyzer.get_string(book_url_rule).unwrap_or_default();
        // bookUrl 规则解析为空时回退当前页（对齐原版 BookList.kt:282-284 +
        // AnalyzeRule.kt:369-375 的 isUrl=true 空值回退 baseUrl；与 search.rs:934-938 一致）— A4
        let book_url = if book_url_raw.is_empty() {
            base_url.clone()
        } else {
            AnalyzeUrl::get_absolute_url(&base_url, &book_url_raw)
        };
        let cover_url = {
            let v = elem_analyzer.get_string(cover_url_rule).unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                Some(AnalyzeUrl::get_absolute_url(&base_url, &v))
            }
        };
        let intro = {
            let v = elem_analyzer.get_string(intro_rule).unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                // 简介净化（对齐原版 HtmlFormatter.formatIntro 去标签）— A3
                Some(format_intro(&v))
            }
        };
        let latest_chapter = {
            let v = elem_analyzer
                .get_string(last_chapter_rule)
                .unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        };
        let kind = {
            let v = elem_analyzer.get_string(kind_rule).unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                // 多段 kind（如 dd.2:3）get_string 以 \n 拼接，对齐原版 join(",")
                Some(
                    v.split('\n')
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(","),
                )
            }
        };

        // 字数格式化（对齐原版 wordCountFormat；与搜索路径一致）— A7
        let word_count = {
            let v = elem_analyzer
                .get_string(word_count_rule)
                .unwrap_or_default();
            super::search::word_count_format(&v)
        };

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
            // 书籍类型位标记（对齐原版 BookType；漫画/听书/视频源分流）— A8
            book_type: super::search::book_type_of_source(source.book_source_type),
        });
    }
    // `-` 前缀反转（对齐原版 BookList.kt:145-147）— A6
    if reverse {
        results.reverse();
    }
    eprintln!(
        "[explore] parse {} books from {} elements in {:?}",
        results.len(),
        elements.len(),
        t_parse.elapsed()
    );

    Ok(results)
}

/// explore 链路 loginCheckJs 登录检测（双路径）
///
/// 对齐原版 `WebBook.exploreBookAwait`（WebBook.kt:148-172）与
/// `web_book::RealBookSourceFetcher::execute_login_check`：
/// - 成功路径：正常响应 eval 判定未登录 → 构造 errResponse(500) 二次 eval
///   （JS 可自动登录并返回新响应）→ 仍未登录则上抛 `LoginRequired`
/// - JS 环境不兼容（依赖 java.* 等）→ 降级放行，避免阻断
/// — DeepSeek Harness + Bridge（2026-08-14 发现页修复 R3）
fn explore_login_check(
    source: &BookSource,
    response_body: &str,
    response_url: &str,
    response_code: u16,
) -> LegadoResult<()> {
    let login_check_js = match &source.login_check_js {
        Some(js) if !js.trim().is_empty() => js,
        _ => return Ok(()), // 无 loginCheckJs 配置，跳过
    };

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
                        "[explore] loginCheckJs errResponse 路径执行失败（降级放行）: {e}"
                    );
                    Ok(())
                }
            }
        }
        Err(crate::js_executor::LoginCheckError::JsFailed(e)) => {
            eprintln!("[explore] loginCheckJs 执行失败（环境不兼容，降级放行）: {e}");
            Ok(())
        }
    }
}

// ─── 字段清洗（对齐原版 BookHelp / HtmlFormatter） ────────────────────────────

/// 书名清洗（对齐原版 `BookHelp.formatBookName`：去「 作者xxx」「 xx 著」后缀）— A2
fn format_book_name(name: &str) -> String {
    let re = regex::Regex::new(r"\s+作\s*者.*|\s+\S+\s+著");
    let cleaned = match re {
        Ok(re) => re.replace_all(name, "").into_owned(),
        Err(_) => name.to_string(),
    };
    cleaned.trim().to_string()
}

/// 作者清洗（对齐原版 `BookHelp.formatBookAuthor`：去「作者:xxx」前缀、「 xx 著」后缀）— A2
fn format_book_author(author: &str) -> String {
    let re = regex::Regex::new(r"^\s*作\s*者[:：\s]+|\s+著");
    let cleaned = match re {
        Ok(re) => re.replace_all(author, "").into_owned(),
        Err(_) => author.to_string(),
    };
    cleaned.trim().to_string()
}

/// 简介净化（对齐原版 `HtmlFormatter.formatIntro` 的可见行为：去 HTML 标签、
/// 解码常见实体、压缩空白）— A3
fn format_intro(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    // 去标签（含 <br>/<p> 等块级转空格）
    let no_tag = regex::Regex::new(r"<[^>]+>")
        .map(|re| re.replace_all(raw, " ").into_owned())
        .unwrap_or_else(|_| raw.to_string());
    // 常见实体解码
    let decoded = no_tag
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    // 压缩空白
    decoded.split_whitespace().collect::<Vec<_>>().join(" ")
}

// ─── 字段清洗 / 登录检测测试（发现页修复 R3/A2/A3/A6） ────────────────────────

#[cfg(test)]
mod field_clean_tests {
    use super::*;

    #[test]
    fn test_format_book_name_strips_author_suffix() {
        assert_eq!(format_book_name("斗破苍穹 作者天蚕土豆"), "斗破苍穹");
        assert_eq!(format_book_name("凡人修仙传 忘语 著"), "凡人修仙传");
        assert_eq!(format_book_name("  神墓  "), "神墓");
    }

    #[test]
    fn test_format_book_author_strips_prefix_suffix() {
        assert_eq!(format_book_author("作者:天蚕土豆"), "天蚕土豆");
        assert_eq!(format_book_author("作者： 忘语"), "忘语");
        assert_eq!(format_book_author("天蚕土豆 著"), "天蚕土豆");
        assert_eq!(format_book_author("  猫腻  "), "猫腻");
    }

    #[test]
    fn test_format_intro_strips_html() {
        assert_eq!(
            format_intro("<p>简介内容</p><br/>第二段 &amp; 特殊字符"),
            "简介内容 第二段 & 特殊字符"
        );
        assert_eq!(format_intro(""), "");
    }

    #[test]
    fn test_reverse_prefix_flag_semantics() {
        // `-` 前缀剥离 + reverse 标记（A6）
        let mut rule = "-.list@css:li".to_string();
        let mut reverse = false;
        if rule.starts_with('-') {
            reverse = true;
            rule = rule[1..].to_string();
        }
        assert!(reverse);
        assert_eq!(rule, ".list@css:li");

        // `+` 前缀仅剥离
        let mut rule2 = "+.list@css:li".to_string();
        let mut reverse2 = false;
        if rule2.starts_with('-') {
            reverse2 = true;
            rule2 = rule2[1..].to_string();
        } else if rule2.starts_with('+') {
            rule2 = rule2[1..].to_string();
        }
        assert!(!reverse2);
        assert_eq!(rule2, ".list@css:li");
    }
}

#[cfg(all(test, feature = "quickjs"))]
mod login_check_tests {
    use super::*;
    use legado_core::models::BookSource;

    fn source_with_login_check(js: &str) -> BookSource {
        serde_json::from_str::<BookSource>(&serde_json::json!({
            "bookSourceUrl": "https://login-explore.example.com",
            "bookSourceName": "登录探索测试",
            "loginCheckJs": js,
        }).to_string())
        .unwrap()
    }

    #[test]
    fn test_explore_login_check_not_logged_in_raises() {
        // loginCheckJs 返回 "false"（未登录）→ 二次 errResponse(500) eval 仍 false
        // → 上抛 LoginRequired
        let source = source_with_login_check("false;");
        let err = explore_login_check(&source, "<html>登录页</html>", "https://a.com/explore", 200)
            .unwrap_err();
        assert!(matches!(err, LegadoError::LoginRequired(_)));
    }

    #[test]
    fn test_explore_login_check_no_config_skips() {
        let source = BookSource::default();
        let r = explore_login_check(&source, "<html>x</html>", "https://a.com", 200);
        assert!(r.is_ok(), "无 loginCheckJs 配置应跳过检测");
    }

    #[test]
    fn test_explore_login_check_logged_in_ok() {
        let source = source_with_login_check("true;");
        let r = explore_login_check(&source, "<html>正常页</html>", "https://a.com/explore", 200);
        assert!(r.is_ok(), "已登录应放行");
    }
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_explore_parse_url_text() {
        let json = explore_parse_url("玄幻::https://a.com\n都市::https://b.com", "").unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 2);
        assert_eq!(categories[0].title, "玄幻");
    }

    #[test]
    fn test_explore_parse_url_empty() {
        let json = explore_parse_url("", "").unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert!(categories.is_empty());
    }

    #[test]
    fn test_explore_parse_url_json_with_style() {
        let input = r#"[{"title":"都市","url":"http://example.com/a","style":{"layout_flexGrow":1,"layout_flexBasisPercent":1}},{"title":"玄幻","url":"http://example.com/b","style":{"layout_flexGrow":1,"layout_flexBasisPercent":0.25}}]"#;
        let json = explore_parse_url(input, "").unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 2);
        assert_eq!(categories[0].title, "都市");
        assert_eq!(
            categories[0].url,
            Some("http://example.com/a".to_string())
        );
        let style0 = categories[0].style.as_ref().unwrap();
        assert!((style0.layout_flex_basis_percent - 1.0).abs() < f32::EPSILON);
        let style1 = categories[1].style.as_ref().unwrap();
        assert!((style1.layout_flex_basis_percent - 0.25).abs() < f32::EPSILON);
    }

    #[test]
    fn test_explore_parse_url_text_without_source_json() {
        let json = explore_parse_url("玄幻::https://a.com\n都市::https://b.com", "").unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 2);
        assert_eq!(categories[0].title, "玄幻");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_parse_url_js_returns_json_array() {
        let source = BookSource {
            book_source_url: "https://explore-js.test".to_string(),
            book_source_name: "JS测试".to_string(),
            ..BookSource::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let explore_url = "@js:[{title:'热门',url:'/hot'},{title:'新书',url:'/new'}]";
        let json = explore_parse_url(explore_url, &source_json).unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 2);
        assert_eq!(categories[0].title, "热门");
        assert_eq!(categories[0].url, Some("/hot".to_string()));
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_parse_url_js_source_get_put() {
        let source = BookSource {
            book_source_url: "https://explore-get.test".to_string(),
            book_source_name: "get/put".to_string(),
            ..BookSource::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let explore_url = r#"@js:
source.put('k','v');
if(source.get('k')!=='v'){throw new Error('source.get/put failed');}
[{title:'OK',url:'/ok'}]"#;
        let json = explore_parse_url(explore_url, &source_json).unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 1);
        assert_eq!(categories[0].title, "OK");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_parse_url_js_java_get_put() {
        let source = BookSource {
            book_source_url: "https://explore-java.test".to_string(),
            book_source_name: "java.get".to_string(),
            ..BookSource::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let explore_url = r#"@js:
java.put('mode','audio');
if(java.get('mode')!=='audio'){throw new Error('java.get failed');}
if(source.get('mode')!=='audio'){throw new Error('source.get failed');}
[{title:'线路',type:'select',url:'',style:{layout_flexBasisPercent:0.5}}]"#;
        let json = explore_parse_url(explore_url, &source_json).unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 1);
        assert_eq!(categories[0].title, "线路");
        assert_eq!(categories[0].r#type, "select");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_parse_url_js_aggregate_explore_kinds() {
        use crate::api::source_login_cache;
        let main_js = r#"
function exploreKinds() {
  var mode = java.get('mode') || '小说';
  var header = source.getLoginHeader();
  if (header) java.put('hasHeader', '1');
  infoMap['模式'] = mode;
  return [
    {title: '线路', type: 'select', chars: ['线路A','线路B'], style: {layout_flexBasisPercent: 0.5}},
    {title: '模式', type: 'select', chars: ['小说','听书'], url: ''},
    {title: '登录番茄', type: 'button', action: "java.refreshExplore()"},
    {title: mode + '榜', type: 'url', url: '/rank/hot'}
  ];
}
"#;
        let source = BookSource {
            book_source_url: "https://dahuiwolf.test".to_string(),
            book_source_name: "大灰狼模拟".to_string(),
            main_js: Some(main_js.to_string()),
            login_url: Some("function login(){return true;}".to_string()),
            ..BookSource::default()
        };
        source_login_cache::put_login_header(
            &source.book_source_url,
            r#"{"Authorization":"Bearer x"}"#,
        )
        .unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let json = explore_parse_url("@js:exploreKinds()", &source_json).unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert!(categories.len() >= 4, "categories: {json}");
        assert_eq!(categories[0].title, "线路");
        assert_eq!(categories[0].r#type, "select");
        assert_eq!(categories[2].title, "登录番茄");
        assert_eq!(categories[2].r#type, "button");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_parse_url_js_host_from_jslib() {
        let js_lib = r#"var host = ['https://api.dahuiwolf.test','https://backup.test'];
function getArguments(open_argument, key) {
  try { open_argument = JSON.parse(open_argument); } catch (e) { open_argument = { server: host[0] }; }
  return key ? open_argument[key] : open_argument;
}
function createFilter(title, chars, current, key, flex) {
  return { title: title, type: 'select', chars: chars, url: '', style: { layout_flexBasisPercent: flex } };
}"#;
        let explore_url = r#"<js>
var open_argument = source.getVariable();
if (!open_argument || open_argument == '') {
  var initData = { tab: '小说', server: host[0], sources: '番茄' };
  source.setVariable(JSON.stringify(initData));
}
var base_url = getArguments(open_argument, 'server') || host[0];
var qtsj = [];
qtsj.push(createFilter('线路', host, base_url, 'server', 1));
JSON.stringify(qtsj.concat([{title: base_url + '榜', url: '/rank'}]));
</js>"#;
        let source = BookSource {
            book_source_url: "大灰狼融合VIP5.0".to_string(),
            book_source_name: "大灰狼模拟".to_string(),
            js_lib: Some(js_lib.to_string()),
            explore_url: Some(explore_url.to_string()),
            ..BookSource::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let json = explore_parse_url(explore_url, &source_json).unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert!(
            categories.len() >= 2,
            "应解析出 selector + 榜单，实际: {json}"
        );
        assert_eq!(categories[0].title, "线路");
        assert_eq!(categories[0].r#type, "select");
        assert!(
            categories[1].title.contains("https://api.dahuiwolf.test"),
            "榜单标题应含 host[0]: {}",
            categories[1].title
        );
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_parse_url_dahuiwolf_from_env() {
        let Ok(explore_url) = std::env::var("DAHUI_EXPLORE_URL") else {
            return;
        };
        let Ok(source_json) = std::env::var("DAHUI_SOURCE_JSON") else {
            return;
        };
        let json = explore_parse_url(&explore_url, &source_json).unwrap_or_else(|e| {
            panic!("大灰狼 explore 解析失败: {e}");
        });
        assert!(
            !json.contains("host is not defined"),
            "不应含 host 错误: {json}"
        );
        let categories: Vec<ExploreCategory> =
            serde_json::from_str(&json).unwrap_or_else(|e| panic!("JSON 解析失败: {e} | {json}"));
        assert!(!categories.is_empty(), "分类为空: {json}");
        if let Some(err) = categories.iter().find(|c| c.title == "ERROR") {
            panic!(
                "ERROR 分类: {}",
                err.url.as_deref().unwrap_or("")
            );
        }
        let has_selector = categories.iter().any(|c| {
            c.title.contains("线路")
                || c.title.contains("模式")
                || c.r#type == "select"
        });
        if !has_selector {
            let login_only = !categories.is_empty()
                && categories
                    .iter()
                    .all(|c| c.title.contains("登录") || c.url.as_deref().unwrap_or("").contains("startBrowser"));
            assert!(
                login_only,
                "应含 selector/线路/模式，或未登录时的登录入口，实际: {json}"
            );
        }
    }

    #[test]
    fn test_explore_parse_url_js_requires_source_json() {
        let err = explore_parse_url("@js:[]", "").unwrap_err();
        assert!(err.to_string().contains("书源 JSON"));
    }

    #[test]
    fn test_explore_fetch_books_invalid_source_json() {
        let err = explore_fetch_books("not valid json", "https://example.com", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_explore_fetch_books_empty_url() {
        let source_json = serde_json::to_string(&BookSource::default()).unwrap();
        let err = explore_fetch_books(&source_json, "", 1).unwrap_err();
        assert!(err.to_string().contains("URL 为空"));
    }

    /// 发现页 URL 组装：`{{page}}` 须展开为页码，禁止误伤成字面量 `{1}`（思路客回归）
    #[test]
    fn test_explore_analyze_url_double_brace_page() {
        let analyze = AnalyzeUrl::new(
            "/list1/{{page}}.html",
            None,
            Some(1),
            "http://www.silukezw.com",
            None,
        );
        assert_eq!(analyze.url(), "http://www.silukezw.com/list1/1.html");
        assert!(!analyze.url().contains('{'), "URL 不得残留花括号占位: {}", analyze.url());
    }

    /// 网络回归：思路客发现「玄幻」页码展开后应 HTTP 成功并解析到书名
    #[test]
    fn test_explore_fetch_siluke_xuanhuan_live() {
        let source = serde_json::json!({
            "bookSourceUrl": "http://www.silukezw.com",
            "bookSourceName": "思路客#2",
            "bookSourceType": 0,
            "ruleExplore": {
                "bookList": "",
                "name": "",
                "author": "",
                "bookUrl": "",
                "coverUrl": ""
            },
            "ruleSearch": {
                "bookList": ".col-md-6@dl",
                "name": "h3@a@text##.*\\]|小说全文阅读|小说全集",
                "author": "dd.1@span.0@text",
                "bookUrl": "a.0@href",
                "coverUrl": "img@src",
                "kind": "dd.2:3@text##.*：|.*：",
                "lastChapter": "dd.4@a@text"
            }
        });
        let source_json = source.to_string();
        let result = explore_fetch_books(&source_json, "/list1/{{page}}.html", 1);
        match result {
            Ok(json) => {
                assert!(!json.contains("{1}"), "响应不得含未替换占位: {json}");
                let books: Vec<serde_json::Value> =
                    serde_json::from_str(&json).expect("应为书籍 JSON 数组");
                eprintln!("siluke explore books={}", books.len());
                let empty_url = books
                    .iter()
                    .filter(|b| {
                        b.get("bookUrl")
                            .or_else(|| b.get("book_url"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .is_empty()
                    })
                    .count();
                assert!(
                    books.len() >= 5,
                    "思路客玄幻发现应有多本书，实际 {} 本: {json}",
                    books.len()
                );
                assert!(
                    empty_url < books.len() / 2,
                    "多数书籍 bookUrl 为空会导致 Flutter 按 URL 去重后只剩 1 本: {json}"
                );
            }
            Err(e) => {
                let msg = e.to_string();
                assert!(
                    !msg.contains("{1}"),
                    "失败信息不得含未替换占位 {{1}}: {msg}"
                );
                assert!(
                    !msg.contains("404"),
                    "页码未替换导致的 404 回归: {msg}"
                );
                panic!("网络/解析失败（非占位符问题）: {msg}");
            }
        }
    }
}
