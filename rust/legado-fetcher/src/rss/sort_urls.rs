//! RSS 分类 `sortUrl` 解析与脚本求值缓存（批15b）
//!
//! 逐行对齐原版 `RssSourceExtensions.kt:49-113`：
//!
//! ```text
//! parseRssSortUrls(value, sourceUrl)
//!   → value.split(Regex("(?:&&|\\r?\\n)+"))
//!   → 每段：url = substringAfter("::", "").trim()；url 空则丢弃
//!            name = substringBefore("::").trim()
//!   → 结果为空 → [("" to sourceUrl)]
//!
//! sortUrls()
//!   → sortUrl 以 @js: / <js> 开头才读写缓存（ACache 名 `rssSortUrl`）
//!   → 缓存键 = MD5(sourceUrl + sortUrl)
//!   → 无缓存才求值脚本；求值结果非空才写缓存
//! ```
//!
//! 缓存读写由宿主（FFI）经闭包注入：本 crate 不依赖 DB（同
//! `FetcherDeps` 的宿主注入原则）。DB 侧键格式为
//! `rssSortUrl_<md5>`，与「ACache 名 + MD5 键」的原版结构一一对应。

use legado_core::models::RssSource;

/// 分类项（`[{"name","url"}]` 契约元素）
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RssSortUrl {
    /// 分类名（无分隔符段为空串）
    pub name: String,
    /// 分类 URL（`AnalyzeUrl` 模板）
    pub url: String,
}

const JS_PREFIX: &str = "@js:";
const JS_TAG_PREFIX: &str = "<js>";
const JS_TAG_SUFFIX: &str = "</js>";

/// 是否为脚本形态的 `sortUrl`（`@js:` / `<js>` 前缀，对齐
/// `RssSourceExtensions.isRssSortScript`）
pub fn is_sort_script(value: &str) -> bool {
    value.starts_with(JS_PREFIX) || value.starts_with(JS_TAG_PREFIX)
}

/// 提取脚本正文（对齐 `extractRssSortScript`）
///
/// - `@js:` → 前缀后全部（全空白 → `None`）
/// - `<js>…</js>` → 首尾之间（`</js>` 缺失或位于 `<js>` 内 → `None`；
///   全空白 → `None`）
///
/// 与原版一致：脚本正文**不 trim**，只按 `isNotBlank` 判定空。
pub fn extract_sort_script(value: &str) -> Option<String> {
    if let Some(rest) = value.strip_prefix(JS_PREFIX) {
        return if rest.trim().is_empty() {
            None
        } else {
            Some(rest.to_string())
        };
    }
    if let Some(rest) = value.strip_prefix(JS_TAG_PREFIX) {
        let close = rest.rfind(JS_TAG_SUFFIX)?;
        let script = &rest[..close];
        return if script.trim().is_empty() {
            None
        } else {
            Some(script.to_string())
        };
    }
    None
}

/// 解析 `sortUrl` 配置为分类列表（对齐 `parseRssSortUrls`）
///
/// 分段正则 `(?:&&|\r?\n)+`；无 `::` 的段因 url 为空被丢弃；
/// 全部为空时回退 `[("", source_url)]`。
pub fn parse_sort_urls(value: Option<&str>, source_url: &str) -> Vec<RssSortUrl> {
    /// 与原版 `Regex("(?:&&|\\r?\\n)+")` 等价：连续分隔符合并
    /// （进程级编译一次；正则固定不会失败）
    static SEPARATOR: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let mut entries = Vec::new();
    if let Some(value) = value {
        let separator =
            SEPARATOR.get_or_init(|| regex::Regex::new(r"(?:&&|\r?\n)+").expect("固定正则"));
        for item in separator.split(value) {
            let Some((name, url)) = item.split_once("::") else {
                // substringAfter("::", "") → "" → url 为空 → 丢弃
                continue;
            };
            let url = url.trim();
            if url.is_empty() {
                continue;
            }
            entries.push(RssSortUrl {
                name: name.trim().to_string(),
                url: url.to_string(),
            });
        }
    }
    if entries.is_empty() {
        entries.push(RssSortUrl {
            name: String::new(),
            url: source_url.to_string(),
        });
    }
    entries
}

/// 分类脚本求值缓存键（对齐 `getSortUrlsKey` + ACache 名）
///
/// 原版：`MD5Utils.md5Encode(sourceUrl + sortUrl)`。Kotlin 中 `sortUrl`
/// 为 `String?`，为 null 时字符串拼接得到字面量 `"null"`——此处同样
/// 以 `"null"` 参与计算，保证键与原版口径一致。
pub fn sort_cache_key(source_url: &str, configured_sort_url: Option<&str>) -> String {
    let raw = format!("{}{}", source_url, configured_sort_url.unwrap_or("null"));
    format!("rssSortUrl_{:x}", md5::compute(raw.as_bytes()))
}

/// 解析分类列表（含脚本求值与缓存）
///
/// 语义逐条对齐原版 `sortUrls()`：
/// 1. 仅脚本形态配置读写缓存；
/// 2. 缓存命中且非空白 → 直接使用，不再求值；
/// 3. 缓存缺失 → 求值脚本（求值由调用方注入，失败返回 `None`）；
///    求值结果非空白才写缓存；
/// 4. 最终值交给 [`parse_sort_urls`]（空/失败回退 `[("", sourceUrl)]`）。
///
/// `cache_get` / `cache_put` / `evaluate` 均为宿主注入闭包：本函数不
/// 触碰 DB / JS 引擎，便于单测与跨宿主复用。
pub fn resolve_sort_urls_with_cache<G, P, E>(
    source_url: &str,
    configured_sort_url: Option<&str>,
    cache_get: G,
    cache_put: P,
    evaluate: E,
) -> Vec<RssSortUrl>
where
    G: FnOnce(&str) -> Option<String>,
    P: FnOnce(&str, &str),
    E: FnOnce(&str) -> Option<String>,
{
    let resolved = match configured_sort_url {
        Some(configured) if is_sort_script(configured) => {
            let key = sort_cache_key(source_url, configured_sort_url);
            let cached = cache_get(&key).filter(|v| !v.trim().is_empty());
            match cached {
                Some(value) => Some(value),
                None => {
                    let evaluated =
                        extract_sort_script(configured).and_then(|script| evaluate(&script));
                    if let Some(value) = evaluated.as_deref().filter(|v| !v.trim().is_empty()) {
                        cache_put(&key, value);
                    }
                    evaluated
                }
            }
        }
        other => other.map(str::to_string),
    };
    parse_sort_urls(resolved.as_deref(), source_url)
}

/// 源未入库时的分类解析（宿主兜底路径：等价原版 `RssSource(sourceUrl=url)`
/// 空配置 → `[("", sourceUrl)]`）
pub fn fallback_sort_urls(source_url: &str) -> Vec<RssSortUrl> {
    parse_sort_urls(None, source_url)
}

/// `@js:` / `<js>` 脚本求值（quickjs 构建；无引擎时返回 `None`）
///
/// 注入 RSS 源 jsLib 与 setup（`source`/`java` 绑定），对齐原版
/// `BaseSource.evalJS` 的 `java = source` / `source` 绑定语义。
#[cfg(feature = "quickjs")]
pub fn evaluate_sort_script(
    source: &RssSource,
    script: &str,
    setup_script: Option<String>,
) -> Option<String> {
    use legado_parser::JsExecutor;

    let js_lib = source
        .js_lib
        .as_deref()
        .map(crate::js_adapter::sanitize_js_lib_for_quickjs);
    let executor = legado_js::executor::QuickJsExecutor::new(&source.source_url)
        .with_js_lib(js_lib)
        .with_setup_script(setup_script);
    match executor.execute_js(script) {
        Ok(value) => Some(value),
        Err(e) => {
            // 对齐原版 `runCatching { ... }.getOrNull()`：求值失败静默回退，
            // 仅保留诊断日志（失败结果不写缓存）。
            eprintln!("[rss] sortUrl 脚本求值失败（{}）: {e}", source.source_url);
            None
        }
    }
}

/// 无 quickjs 构建：无 JS 执行器，脚本求值恒失败（登记 E7）
#[cfg(not(feature = "quickjs"))]
pub fn evaluate_sort_script(
    _source: &RssSource,
    _script: &str,
    _setup_script: Option<String>,
) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 换行 / `&&` / 混合分隔：`a::u\nb::v`、`&&` 两种写法都解析
    #[test]
    fn parse_newline_and_ampersand_separators() {
        let entries = parse_sort_urls(Some("科技::https://x/t\n文学::https://x/w"), "https://x");
        assert_eq!(
            entries,
            vec![
                RssSortUrl {
                    name: "科技".into(),
                    url: "https://x/t".into()
                },
                RssSortUrl {
                    name: "文学".into(),
                    url: "https://x/w".into()
                },
            ]
        );

        let entries = parse_sort_urls(Some("A::https://x/a&&B::https://x/b"), "https://x");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].name, "B");

        // CRLF 合并 + 连续分隔符 + 无 :: 段丢弃 + 空 url 段丢弃
        let entries = parse_sort_urls(
            Some("A::https://x/a\r\n\r\nB::https://x/b&&裸链接:: &&C::  "),
            "https://x",
        );
        assert_eq!(entries.len(), 2, "空 url / 无 url 段应丢弃: {entries:?}");
        assert_eq!(entries[0].name, "A");
        assert_eq!(entries[1].name, "B");
    }

    /// 空配置 / 空值回退 `[("", sourceUrl)]`
    #[test]
    fn parse_falls_back_to_source_url() {
        assert_eq!(
            parse_sort_urls(None, "https://x/feed"),
            vec![RssSortUrl {
                name: String::new(),
                url: "https://x/feed".into()
            }]
        );
        assert_eq!(
            parse_sort_urls(Some(""), "https://x/feed"),
            vec![RssSortUrl {
                name: String::new(),
                url: "https://x/feed".into()
            }]
        );
        // 无 `::` 的段被丢弃 → 同样回退
        assert_eq!(
            parse_sort_urls(Some("https://x/only-url"), "https://x/feed")[0].url,
            "https://x/feed"
        );
    }

    /// `@js:` / `<js>` 识别与脚本提取
    #[test]
    fn extract_script_forms() {
        assert!(is_sort_script("@js:1+1"));
        assert!(is_sort_script("<js>1+1</js>"));
        assert!(!is_sort_script("A::https://x"));

        assert_eq!(extract_sort_script("@js:1+1").as_deref(), Some("1+1"));
        assert_eq!(extract_sort_script("<js>1+1</js>").as_deref(), Some("1+1"));
        assert_eq!(
            extract_sort_script("<js>a</js><js>b</js>").as_deref(),
            Some("a</js><js>b"),
            "对齐 lastIndexOf(\"</js>\")：取最后一个闭合标签"
        );
        assert_eq!(extract_sort_script("@js:   "), None);
        assert_eq!(extract_sort_script("<js>   </js>"), None);
        assert_eq!(extract_sort_script("<js>no-close"), None);
        assert_eq!(extract_sort_script("A::https://x"), None);
    }

    /// 脚本配置：缓存命中不求值；miss 求值后写缓存；失败不写缓存
    #[test]
    fn resolve_uses_cache_and_writes_after_eval() {
        let configured = "@js:return 'A::https://x/a'";
        let key = sort_cache_key("https://x", Some(configured));

        // 缓存命中：evaluate 不得被调用
        let mut evaluated = false;
        let entries = resolve_sort_urls_with_cache(
            "https://x",
            Some(configured),
            |k| {
                assert_eq!(k, key);
                Some("缓存::https://x/cached".to_string())
            },
            |_, _| panic!("缓存命中不得写缓存"),
            |_| {
                evaluated = true;
                None
            },
        );
        assert!(!evaluated, "缓存命中不应求值脚本");
        assert_eq!(entries[0].name, "缓存");
        assert_eq!(entries[0].url, "https://x/cached");

        // 缓存缺失：求值并写入
        let mut written: Option<(String, String)> = None;
        let entries = resolve_sort_urls_with_cache(
            "https://x",
            Some(configured),
            |_| None,
            |k, v| written = Some((k.to_string(), v.to_string())),
            |script| {
                assert_eq!(script, "return 'A::https://x/a'");
                Some("求值::https://x/eval".to_string())
            },
        );
        assert_eq!(written, Some((key, "求值::https://x/eval".to_string())));
        assert_eq!(entries[0].name, "求值");

        // 求值失败：回退源 URL，且不写缓存
        let entries = resolve_sort_urls_with_cache(
            "https://x/feed",
            Some(configured),
            |_| None,
            |_, _| panic!("求值失败不得写缓存"),
            |_| None,
        );
        assert_eq!(entries[0].url, "https://x/feed");

        // 非脚本配置：不读写缓存
        let entries = resolve_sort_urls_with_cache(
            "https://x",
            Some("A::https://x/a"),
            |_| panic!("非脚本配置不得读缓存"),
            |_, _| panic!("非脚本配置不得写缓存"),
            |_| panic!("非脚本配置不得求值"),
        );
        assert_eq!(entries[0].url, "https://x/a");
    }

    /// 缓存键口径：MD5(sourceUrl + sortUrl)，null 拼字面量 "null"
    #[test]
    fn cache_key_matches_md5_concat() {
        let key = sort_cache_key("https://x", Some("@js:1"));
        assert_eq!(
            key,
            format!("rssSortUrl_{:x}", md5::compute("https://x@js:1".as_bytes()))
        );
        assert_eq!(key.len(), "rssSortUrl_".len() + 32);

        let null_key = sort_cache_key("https://x", None);
        assert_eq!(
            null_key,
            format!("rssSortUrl_{:x}", md5::compute("https://xnull".as_bytes())),
            "Kotlin null 拼接为字面量 \"null\""
        );
    }
}
