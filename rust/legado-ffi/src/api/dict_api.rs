//! 词典查询 API（Task #137：对齐 Android 原版字典规则体系）
//!
//! 提供词典查询（API_CONTRACT.md §3 需求 4：`dictLookup`）。
//!
//! ## 原版机制（`app/src/main/java/io/legado/app/`）
//!
//! Android 原版不使用静态词典，而是「字典规则（dict_rules）」体系：
//! - `data/entities/DictRule.kt`：规则实体（name 主键 / urlRule / showRule /
//!   enabled / sortNumber），`DictRule.search(word)` 执行查询：
//!   `AnalyzeUrl(urlRule, key = word)` 取响应 body → showRule 为空直接返回，
//!   否则 `AnalyzeRule.getString(showRule, mContent = body)` 解析；
//! - `data/dao/DictRuleDao.kt`：`enabled` 查询按 sortNumber 排序，
//!   阅读器字典弹窗（`ui/dict/DictViewModel`）逐条执行启用规则，每规则一个页签；
//! - `help/DefaultData.kt` + `assets/defaultData/dictRules.json`：
//!   内置默认 5 个字典源（海词中文 / 海词英文 / 有道 / 哔哩 / 百度汉语），
//!   版本升级时 `importDefaultDictRules` 写入。
//!
//! ## 本实现（Rust 轨）
//!
//! - 数据源为 `dict_rules` 表（`DictRuleRepository`）；表为空时注入原版默认
//!   5 源（`legado_db::DictRuleRepository::seed_default_rules`，
//!   对标 Kotlin `importDefaultDictRules`）；
//! - 查询链路复用项目既有能力：`legado_parser::AnalyzeUrl`（urlRule 模板/
//!   `{{key}}` 替换/请求选项/data: URI）+ `legado_net::LegadoClient`（HTTP）
//!   + `legado_parser::AnalyzeRule`（showRule CSS/XPath/JsonPath/正则）
//!   + `legado-js` QuickJS（`@js:` 规则，经 `JsExecutor` 注入，需 quickjs 特性）；
//! - JS 作用域对齐 Kotlin `AnalyzeUrl/AnalyzeRule.evalJS` 的绑定语义：
//!   以 `var key/word/result = <JSON 字符串字面量>` 前置注入
//!   （同 `js_executor::execute_login_check_js` 的 result 注入模式）；
//! - 各启用规则的结果逐条写入 `definitions`（前缀 `【规则名】` 区分来源，
//!   原版为每规则独立页签，本契约 DictEntry 为扁平列表）；规则执行失败
//!   （网络错误 / JS 报错）仅记日志并跳过，不中断整体查询；
//! - `phonetic` 恒为空字符串：原版规则产出 HTML 释义文本，无结构化音标
//!   （保留字段以兼容已冻结的 Dart `DictEntry` 模型）。
//!
//! ## 与原版的行为差异（已在 API_CONTRACT.md 登记）
//!
//! - 未启用任何规则 / 数据库未初始化：返回空 `definitions`（非异常，
//!   契约「未收录返回空列表」语义沿用）；
//! - 原版部分默认规则的 showRule 依赖 Rhino 专属能力
//!   （`JavaImporter`/`Packages.org.jsoup`/`cache.putMemory` 等），
//!   QuickJS 环境无法等价复现；规则数据以原版 JSON 为准不做改写，
//!   此类规则执行失败时按上述跳过策略处理；
//! - 入参仅 trim 归一化、不再小写：原版将选中文本原样传给规则
//!   （中文词不适用小写化）；
//! - 释义文本做了轻量 HTML → 纯文本转换（`DictEntry.definitions` 为纯文本列表，
//!   原版则在 WebView 中渲染 HTML）。

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use regex::Regex;
use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::{DictRule, DictRuleRepository};
use legado_parser::{AnalyzeRule, AnalyzeUrl, JsExecutor, RequestMethod};

use crate::db_state::with_database;

/// 单条字典规则的请求超时（秒）
///
/// 原版无显式超时（跟随全局 OkHttp 配置）；此处限制单规则耗时，
/// 避免离线场景下 5 个规则串行拖垮查询。
const DICT_RULE_TIMEOUT_SECS: u64 = 15;

/// 词典条目 DTO
///
/// 序列化字段对齐 Dart `DictEntry` 模型：`word` / `phonetic` / `definitions`。
#[derive(Debug, Clone, Serialize)]
pub struct DictEntry {
    /// 归一化后的单词（trim）
    pub word: String,
    /// 音标（字典规则链路无结构化音标，恒为空字符串）
    pub phonetic: String,
    /// 释义条目列表（每条对应一个启用字典规则的结果，前缀 `【规则名】`）
    pub definitions: Vec<String>,
}

/// 查询词典释义（字典规则引擎）
///
/// 对标 Kotlin `ui/dict/DictViewModel.initData + search`：
/// 加载全部启用规则（按 sortNumber 排序）→ 逐条执行 `DictRule.search(word)`。
///
/// - 数据库未初始化：降级返回空 `definitions`（保持旧版「非异常」语义）；
/// - 表为空：先注入原版默认 5 个字典源；
/// - 单规则失败（网络/JS 错误）仅记日志跳过。
pub fn dict_lookup(word: &str) -> LegadoResult<DictEntry> {
    let key = word.trim().to_string();

    if !crate::db_state::is_initialized() {
        // 数据库未初始化：与旧静态表时代的「无异常」语义保持一致
        return Ok(empty_entry(key));
    }

    let rules = with_database(|db| {
        let repo = DictRuleRepository::new(db.connection());
        // 对标 Kotlin DefaultData.importDefaultDictRules：表为空时注入原版默认 5 源
        repo.seed_default_rules()?;
        repo.find_enabled()
    })?;

    // 无启用规则：返回空 definitions（契约约定非异常）
    let mut definitions = Vec::new();
    for rule in rules {
        match search_dict_rule(&rule, &key) {
            Ok(text) => {
                let text = html_to_text(&text);
                if !text.trim().is_empty() {
                    definitions.push(format!("【{}】{}", rule.name, text.trim()));
                }
            }
            Err(e) => {
                // 原版在独立页签内展示单规则错误；本契约为扁平列表，失败仅记日志跳过
                log::warn!("字典规则 [{}] 查询「{}」失败: {}", rule.name, key, e);
            }
        }
    }

    Ok(DictEntry {
        word: key,
        phonetic: String::new(),
        definitions,
    })
}

/// 执行单条字典规则查询（对标 Kotlin `DictRule.search`）
///
/// 流程：`AnalyzeUrl(urlRule, key)` 构建请求（含 `@js:` / `{{key}}` /
/// data: URI / 请求选项解析）→ HTTP 或 data: URI 取 body →
/// showRule 为空直接返回 body，否则经 `AnalyzeRule` 链路解析。
pub(crate) fn search_dict_rule(rule: &DictRule, key: &str) -> Result<String, String> {
    // 1. 构建请求（对标 AnalyzeUrl(urlRule, key = word)）
    let analyze_url = build_request(rule, key)?;

    // 2. 取响应 body（单规则超时保护）
    let body = crate::runtime::block_on(async {
        match tokio::time::timeout(
            Duration::from_secs(DICT_RULE_TIMEOUT_SECS),
            fetch_body(&analyze_url),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(format!(
                "请求超时（>{DICT_RULE_TIMEOUT_SECS}s）: {}",
                analyze_url.url()
            )),
        }
    })?;

    // 3. showRule 解析（对标 AnalyzeRule.getString(showRule, mContent = body)）
    apply_show_rule(&rule.name, &rule.show_rule, &body, analyze_url.url(), key)
}

// ─── 请求构建 / 发送 ────────────────────────────────────────────

/// 构建字典规则请求
///
/// - quickjs 构建：`AnalyzeUrl::parse_with_js` 支持 `@js:` urlRule 与
///   `{{java.xxx()}}` 内嵌表达式（对齐 Kotlin `AnalyzeUrl.analyzeJs` +
///   `replaceKeyPageJs`，JS 作用域含 key 绑定）；
/// - 非 quickjs 构建：仅做变量替换的 `AnalyzeUrl::parse`，
///   依赖 JS 的规则将自然失败（跳过策略见 [`dict_lookup`]）。
fn build_request(rule: &DictRule, key: &str) -> Result<AnalyzeUrl, String> {
    let tag = engine_tag(&rule.name);
    // Kotlin AnalyzeUrl 构造时把 key 绑定进 JS 作用域，此处经前置注入等价实现
    let executor = DictScopeExecutor::new(base_js_executor(&tag), key, &rule.url_rule);
    let mut vars = HashMap::new();
    vars.insert("key".to_string(), key.to_string());
    vars.insert("word".to_string(), key.to_string());

    #[cfg(feature = "quickjs")]
    {
        AnalyzeUrl::parse_with_js(&rule.url_rule, &vars, 1, &executor).map_err(|e| e.to_string())
    }
    #[cfg(not(feature = "quickjs"))]
    {
        let _ = executor;
        AnalyzeUrl::parse(&rule.url_rule, &vars, 1).map_err(|e| e.to_string())
    }
}

/// 取响应 body：data: URI 直接解码，否则发起 HTTP 请求
async fn fetch_body(analyze_url: &AnalyzeUrl) -> Result<String, String> {
    // data: URI（如百度汉语规则的 data:;base64,{{...}}）无需网络
    if analyze_url.is_data_uri() {
        return analyze_url
            .get_byte_array_if_data_uri()
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
            .ok_or_else(|| "data: URI 解码失败".to_string());
    }

    let url = analyze_url.url();
    if url.is_empty() {
        return Err("AnalyzeUrl 解析后 URL 为空".to_string());
    }

    let client = crate::http_state::shared_client();
    let headers = if analyze_url.headers().is_empty() {
        None
    } else {
        Some(analyze_url.headers().clone())
    };

    let response = match analyze_url.method() {
        RequestMethod::Post => {
            client
                .post(url, analyze_url.body().unwrap_or(""), headers)
                .await
        }
        _ => client.get(url, headers).await,
    };
    let response = response.map_err(|e| format!("网络请求失败: {e}"))?;
    if !response.is_success() {
        return Err(format!("HTTP {}", response.status));
    }
    Ok(response.body)
}

// ─── showRule 解析 ──────────────────────────────────────────────

/// 应用 showRule（对标 Kotlin `AnalyzeRule.getString(showRule, mContent = body)`）
///
/// - 空规则：直接返回 body（对齐 `DictRule.search` 的 isBlank 分支）；
/// - 含 `@js:` 的规则：原版 `splitSourceRule` 将 `selector@js:code` 拆为
///   级联子规则逐级执行；此处实现单级拆分（选择器结果作为 JS 的 `result`
///   绑定后再执行，覆盖默认 5 源的规则形态）；
/// - 纯选择器规则：交 `AnalyzeRule` 自动路由（CSS/XPath/JsonPath/正则）。
fn apply_show_rule(
    rule_name: &str,
    show_rule: &str,
    body: &str,
    base_url: &str,
    key: &str,
) -> Result<String, String> {
    let rule = show_rule.trim();
    if rule.is_empty() {
        return Ok(body.to_string());
    }

    let tag = engine_tag(rule_name);
    match rule.find("@js:") {
        None => build_analyzer(body, base_url, &tag, key)
            .get_string(rule)
            .map_err(|e| format!("showRule 解析失败: {e}")),
        Some(idx) => {
            let selector = rule[..idx].trim();
            let js_code = &rule[idx + "@js:".len()..];

            // 前置选择器（若有）先解析，结果作为 JS 的 result 绑定
            let intermediate = if selector.is_empty() {
                body.to_string()
            } else {
                build_analyzer(body, base_url, &tag, key)
                    .get_string(selector)
                    .map_err(|e| format!("showRule 选择器解析失败: {e}"))?
            };

            let executor = DictScopeExecutor::new(base_js_executor(&tag), key, &intermediate);
            executor.execute_js(js_code)
        }
    }
}

/// 构建规则解析器（注入字典作用域 JS 执行器，使 showRule 中的
/// `result` / `key` 绑定可用；无 quickjs 时 JS 规则降级报错）
fn build_analyzer(content: &str, base_url: &str, tag: &str, key: &str) -> AnalyzeRule {
    let executor = DictScopeExecutor::new(base_js_executor(tag), key, content);
    AnalyzeRule::with_js_executor(content.to_string(), base_url.to_string(), Arc::new(executor))
}

// ─── JS 作用域执行器 ────────────────────────────────────────────

/// 引擎池缓存标签（按规则名分桶，同书源 URL 分桶模式）
fn engine_tag(rule_name: &str) -> String {
    format!("dict:{rule_name}")
}

/// 取底层 JS 执行器（quickjs 特性开启时为引擎池适配器，否则 None）
#[cfg(feature = "quickjs")]
fn base_js_executor(tag: &str) -> Option<Arc<dyn JsExecutor>> {
    Some(Arc::new(crate::js_executor::QuickJsExecutor::new(tag)))
}

#[cfg(not(feature = "quickjs"))]
fn base_js_executor(_tag: &str) -> Option<Arc<dyn JsExecutor>> {
    None
}

/// 字典规则 JS 作用域执行器
///
/// 对标 Kotlin `AnalyzeUrl.evalJS` / `AnalyzeRule.evalJS` 的脚本绑定
/// （`bindings["key"]` / `bindings["result"]` 等）：QuickJS 无等价
/// bindings 注入口，故以 `var key/word/result = <JSON 字面量>;` 前置
/// 注入后再执行（同 `js_executor::execute_login_check_js` 的既有模式）。
struct DictScopeExecutor {
    base: Option<Arc<dyn JsExecutor>>,
    prelude: String,
}

impl DictScopeExecutor {
    fn new(base: Option<Arc<dyn JsExecutor>>, key: &str, result: &str) -> Self {
        let prelude = format!(
            "var key = {};\nvar word = {};\nvar result = {};\n",
            js_string_literal(key),
            js_string_literal(key),
            js_string_literal(result),
        );
        Self { base, prelude }
    }
}

impl JsExecutor for DictScopeExecutor {
    fn execute_js(&self, js_code: &str) -> Result<String, String> {
        match &self.base {
            Some(base) => base.execute_js(&format!("{}{}", self.prelude, js_code)),
            None => Err("未启用 JS 引擎（quickjs 特性未编译），@js 规则不可用".to_string()),
        }
    }
}

/// 生成 JS 字符串字面量（JSON 字符串是合法的 JS 字符串字面量，
/// 天然处理引号/反斜杠/换行转义）
fn js_string_literal(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "''".to_string())
}

// ─── HTML → 纯文本 ──────────────────────────────────────────────

/// 块级标签（转换为换行）
static BLOCK_TAG_RE: OnceLock<Regex> = OnceLock::new();
/// 任意 HTML 标签（剥离）
static ANY_TAG_RE: OnceLock<Regex> = OnceLock::new();

/// 轻量 HTML → 纯文本转换
///
/// 原版在 WebView 中渲染规则产出的 HTML；本契约 `definitions` 为纯文本
/// 列表，故做保守转换：块级标签转换行 → 剥离剩余标签 → 解码常见实体。
/// 不追求完整 HTML 语义（非本层职责），仅保证释义可读。
fn html_to_text(html: &str) -> String {
    let block_re = BLOCK_TAG_RE.get_or_init(|| {
        Regex::new(r"(?i)<br\s*/?>|</(?:p|div|h[1-6]|li|ul|ol|tr|table|section|blockquote)>")
            .expect("块级标签正则编译失败")
    });
    let any_re = ANY_TAG_RE
        .get_or_init(|| Regex::new(r"<[^>]+>").expect("标签剥离正则编译失败"));

    let s = block_re.replace_all(html, "\n");
    let s = any_re.replace_all(&s, "");
    let s = decode_html_entities(&s);

    // 压缩多余空行并去除行首尾空白
    let mut out = String::with_capacity(s.len());
    let mut blank = false;
    for line in s.lines() {
        let line = line.trim();
        if line.is_empty() {
            if !blank && !out.is_empty() {
                out.push('\n');
                blank = true;
            }
        } else {
            if blank {
                out.push('\n');
            }
            if !out.is_empty() && !out.ends_with('\n') {
                out.push('\n');
            }
            out.push_str(line);
            blank = false;
        }
    }
    out
}

/// 解码常见 HTML 实体（&amp; 最后处理，避免二次解码）
fn decode_html_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

/// 空结果条目
fn empty_entry(word: String) -> DictEntry {
    DictEntry {
        word,
        phonetic: String::new(),
        definitions: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 清空 dict_rules 表（测试隔离；持 ensure_test_db 串行锁调用）
    fn clear_dict_rules() {
        with_database(|db| {
            let repo = DictRuleRepository::new(db.connection());
            repo.delete_all()
        })
        .unwrap();
    }

    /// 插入测试规则（启用）
    fn insert_rule(name: &str, url_rule: &str, show_rule: &str) -> i64 {
        with_database(|db| {
            let repo = DictRuleRepository::new(db.connection());
            repo.insert_record(&DictRule {
                id: 0,
                name: name.to_string(),
                url_rule: url_rule.to_string(),
                show_rule: show_rule.to_string(),
                is_enabled: true,
                sort_order: 100, // 避开默认 5 源的 0..4 排序区间
            })
        })
        .unwrap()
    }

    /// 规则查询路径：data: URI urlRule（免网络）+ 空 showRule 直返 body
    #[test]
    fn test_lookup_data_uri_rule() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_dict_rules();
        insert_rule(
            "本地测试",
            "data:text/plain;charset=utf-8,hello-{{key}}",
            "",
        );

        let entry = dict_lookup("  world  ").unwrap();
        assert_eq!(entry.word, "world"); // 仅 trim，不再小写
        assert!(entry.phonetic.is_empty());
        assert_eq!(entry.definitions.len(), 1);
        assert_eq!(entry.definitions[0], "【本地测试】hello-world");

        clear_dict_rules();
    }

    /// showRule CSS 选择器路径（data: URI HTML + 选择器提取）
    #[test]
    fn test_lookup_show_rule_css() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_dict_rules();
        insert_rule(
            "CSS测试",
            "data:text/html;charset=utf-8,<html><body><p id='def'>n. 测试释义</p></body></html>",
            "#def",
        );

        let entry = dict_lookup("word").unwrap();
        assert_eq!(entry.definitions.len(), 1);
        assert!(entry.definitions[0].contains("n. 测试释义"));

        clear_dict_rules();
    }

    /// 失败规则跳过：不可达规则不影响其余规则的结果
    #[test]
    fn test_lookup_failed_rule_skipped() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_dict_rules();
        insert_rule("不可达", "http://127.0.0.1:1/dict?q={{key}}", "");
        insert_rule("正常", "data:text/plain;charset=utf-8,ok", "");

        let entry = dict_lookup("x").unwrap();
        assert_eq!(entry.definitions.len(), 1);
        assert!(entry.definitions[0].starts_with("【正常】"));

        clear_dict_rules();
    }

    /// 无启用规则：返回空 definitions（非异常）
    #[test]
    fn test_lookup_no_enabled_rules() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_dict_rules();
        with_database(|db| {
            let repo = DictRuleRepository::new(db.connection());
            let id = repo.insert_record(&DictRule {
                id: 0,
                name: "禁用规则".into(),
                url_rule: "data:text/plain,unused".into(),
                show_rule: "".into(),
                is_enabled: false,
                sort_order: 1,
            })?;
            repo.set_enabled(id, false)
        })
        .unwrap();

        let entry = dict_lookup("anything").unwrap();
        assert!(entry.definitions.is_empty());

        clear_dict_rules();
    }

    /// 表为空时注入原版默认 5 源（对标 DefaultData.importDefaultDictRules）
    #[test]
    fn test_lookup_seeds_defaults_when_empty() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_dict_rules();

        let seeded = with_database(|db| {
            let repo = DictRuleRepository::new(db.connection());
            repo.seed_default_rules()
        })
        .unwrap();
        assert_eq!(seeded, 5);

        let names = with_database(|db| {
            let repo = DictRuleRepository::new(db.connection());
            Ok::<Vec<String>, legado_core::LegadoError>(
                repo.find_all().unwrap().into_iter().map(|r| r.name).collect(),
            )
        })
        .unwrap();
        assert_eq!(
            names,
            vec!["海词中文", "海词英文", "有道", "哔哩", "百度汉语"]
        );

        clear_dict_rules();
    }

    /// `@js:` urlRule + showRule 链路（quickjs 特性下验证 JS 作用域注入）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_lookup_js_rules() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_dict_rules();
        // urlRule 为纯 @js：返回 data: URI；showRule 为纯 @js：消费 result
        insert_rule(
            "JS测试",
            "@js:'data:text/plain;charset=utf-8,js-' + key",
            "@js:'jsdef:' + result",
        );

        let entry = dict_lookup("abc").unwrap();
        assert_eq!(entry.definitions.len(), 1);
        assert_eq!(entry.definitions[0], "【JS测试】jsdef:js-abc");

        clear_dict_rules();
    }

    /// 序列化字段对齐 Dart DictEntry 模型
    #[test]
    fn test_serialization_fields() {
        let entry = DictEntry {
            word: "book".into(),
            phonetic: "".into(),
            definitions: vec!["【测试】n. 书".into()],
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert!(json.get("word").is_some());
        assert!(json.get("phonetic").is_some());
        assert!(json.get("definitions").is_some());
        assert!(json["definitions"].is_array());
    }

    /// HTML → 纯文本转换
    #[test]
    fn test_html_to_text() {
        let html = "<h3>拼音</h3><br><p>释义一&nbsp;&amp;</p><script>x()</script>尾部";
        let text = html_to_text(html);
        assert!(text.contains("拼音"));
        assert!(text.contains("释义一 &"));
        assert!(!text.contains('<'));
        assert!(!text.contains("script"));
        assert!(text.contains("尾部"));
    }
}
