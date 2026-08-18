//! AnalyzeRule: 统一规则解析门面
//!
//! 参考 Kotlin `AnalyzeRule.kt`，实现统一调度，根据规则前缀或内容类型
//! 自动选择 HTML(CSS)、XPath、JsonPath、正则 解析引擎。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use legado_core::LegadoResult;

use crate::html::HtmlParser;
use crate::jsonpath::JsonPathParser;
use crate::regex_engine::RegexEngine;
use crate::rule_analyzer::RuleAnalyzer;
use crate::xpath::XPathParser;

/// JavaScript 执行器 trait
///
/// 由调用方注入具体实现（如 legado-js 的 QuickJS 引擎），
/// 解决 legado-parser 与 legado-js 之间的循环依赖问题。
pub trait JsExecutor: Send + Sync {
    /// 执行 JavaScript 代码，返回结果字符串
    fn execute_js(&self, js_code: &str) -> Result<String, String>;
}

/// 规则类型枚举
#[derive(Debug, Clone, PartialEq)]
pub enum RuleType {
    /// JSoup CSS 选择器
    Css,
    /// XPath
    Xpath,
    /// JsonPath
    Json,
    /// 正则表达式
    Regex,
    /// JavaScript 规则执行
    Js,
    /// WebView JS 规则（对齐原版 `Mode.WebJs` / `@webjs:`）
    ///
    /// 重构侧无平台 WebView 时以降级为无头 QuickJS（注入 result/src/html）。
    WebJs,
    /// 自动检测（根据 @前缀 或内容检测）
    Auto,
}

/// 统一规则解析器
pub struct AnalyzeRule {
    content: String,
    base_url: String,
    html_parser: HtmlParser,
    xpath_parser: XPathParser,
    json_parser: JsonPathParser,
    regex_engine: RegexEngine,
    /// 缓存的内容类型
    cached_content_type: Option<RuleType>,
    /// 内容是否为 JSON 的快速标志
    is_json: bool,
    /// 内容为「结构化列表元素」（JSONPath 元素循环写入）：
    /// execute_js_rule 注入 `result` 时按解析后的 JSON 对象注入
    /// （对齐原版 Kotlin getElements JSON 模式返回 Map 对象 →
    /// 规则 `result.source`/`result.book_url` 属性访问可用）。
    json_element_mode: bool,
    /// 可选的 JS 执行器（通过回调注入模式解决跨 crate 循环依赖）
    js_executor: Option<Arc<dyn JsExecutor>>,
    /// JS 执行时的注入上下文（对齐原版 AnalyzeRule.evalJS bindings：
    /// result/src/baseUrl 自动注入；chapter/title/source 等由调用方补充）
    js_bindings: Vec<(String, String)>,
    /// 规则变量表（对齐原版 chapter/book/ruleData.putVariable）
    ///
    /// `@put:{k:rule}` 写入、`@get:{k}` / `java.get` 读取；跨 get_string 调用共享。
    variables: Arc<Mutex<HashMap<String, String>>>,
    /// 本地绑定（对齐原版 `localBindings` / `setLocal`；优先于 variables）
    local_bindings: Arc<Mutex<HashMap<String, String>>>,
    /// 重定向后最终 URL（对齐原版 `AnalyzeRule.redirectUrl`）
    ///
    /// `isUrl` 绝对化时作为 base；默认等于 `base_url`，可由 `set_redirect_url` 更新。
    redirect_url: String,
    /// 对齐原版 `stringRuleCache`：规则字符串 → 编译后结构（put/##/js 链）
    string_rule_cache: Mutex<HashMap<String, Arc<CompiledSourceRule>>>,
}

impl AnalyzeRule {
    /// 创建新的规则解析器
    pub fn new(content: String, base_url: String) -> Self {
        let content_type = Self::detect_content_type(&content);
        let is_json = content_type == RuleType::Json;
        let redirect_url = base_url.clone();
        Self {
            content,
            base_url,
            html_parser: HtmlParser::new(),
            xpath_parser: XPathParser::new(),
            json_parser: JsonPathParser::new(),
            regex_engine: RegexEngine::new(),
            cached_content_type: Some(content_type),
            is_json,
            json_element_mode: false,
            js_executor: None,
            js_bindings: Vec::new(),
            variables: Arc::new(Mutex::new(HashMap::new())),
            local_bindings: Arc::new(Mutex::new(HashMap::new())),
            redirect_url,
            string_rule_cache: Mutex::new(HashMap::new()),
        }
    }

    /// 创建带有 JS 执行器的规则解析器
    pub fn with_js_executor(
        content: String,
        base_url: String,
        executor: Arc<dyn JsExecutor>,
    ) -> Self {
        let mut rule = Self::new(content, base_url);
        rule.js_executor = Some(executor);
        rule
    }

    /// 追加 JS 注入变量（对齐原版 evalJS bindings：chapter/title/source 等）
    ///
    /// `json_literal` 必须是合法 JSON 字面量：字符串用
    /// `serde_json::to_string(value)`（自动带引号），对象/数组直接传 JSON。
    pub fn with_js_binding(mut self, name: &str, json_literal: &str) -> Self {
        self.js_bindings
            .push((name.to_string(), json_literal.to_string()));
        self
    }

    /// 追加 JS 注入变量（可变版本）
    pub fn add_js_binding(&mut self, name: &str, json_literal: &str) {
        self.js_bindings
            .push((name.to_string(), json_literal.to_string()));
    }

    /// 保存变量（对齐原版 `AnalyzeRule.put`）
    pub fn put(&self, key: &str, value: &str) -> String {
        if let Ok(mut guard) = self.variables.lock() {
            guard.insert(key.to_string(), value.to_string());
        }
        value.to_string()
    }

    /// 读取变量（对齐原版 `AnalyzeRule.get`：localBindings → variables）
    pub fn get(&self, key: &str) -> String {
        if let Ok(guard) = self.local_bindings.lock() {
            if let Some(v) = guard.get(key) {
                return v.clone();
            }
        }
        // 特殊键：从 js_bindings 中的 book/chapter 对象取 name/title
        if key == "bookName" {
            if let Some((_, lit)) = self.js_bindings.iter().rev().find(|(n, _)| n == "book") {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(lit) {
                    if let Some(name) = v.get("name").and_then(|x| x.as_str()) {
                        return name.to_string();
                    }
                }
            }
        }
        if key == "title" {
            if let Some((_, lit)) = self.js_bindings.iter().rev().find(|(n, _)| n == "title") {
                if let Ok(s) = serde_json::from_str::<String>(lit) {
                    return s;
                }
            }
            if let Some((_, lit)) = self.js_bindings.iter().rev().find(|(n, _)| n == "chapter") {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(lit) {
                    if let Some(title) = v.get("title").and_then(|x| x.as_str()) {
                        return title.to_string();
                    }
                }
            }
        }
        if let Ok(guard) = self.variables.lock() {
            if let Some(v) = guard.get(key) {
                if !v.is_empty() {
                    return v.clone();
                }
            }
        }
        String::new()
    }

    /// 设置本地绑定（对齐原版 `AnalyzeRule.setLocal`）
    pub fn set_local(&self, key: &str, value: &str) {
        if let Ok(mut guard) = self.local_bindings.lock() {
            guard.insert(key.to_string(), value.to_string());
        }
    }

    /// 从 JSON 对象字符串注入变量（章节 `variable` 列 / 书变量）
    pub fn seed_variables_json(&self, json: &str) {
        let trimmed = json.trim();
        if trimmed.is_empty() {
            return;
        }
        if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(trimmed) {
            self.seed_variables(map);
        }
    }

    /// 批量注入变量
    pub fn seed_variables(&self, map: HashMap<String, String>) {
        if let Ok(mut guard) = self.variables.lock() {
            for (k, v) in map {
                guard.insert(k, v);
            }
        }
    }

    /// 导出当前变量表为 JSON（写入 BookChapter.variable）
    pub fn export_variables_json(&self) -> Option<String> {
        let guard = self.variables.lock().ok()?;
        if guard.is_empty() {
            return None;
        }
        serde_json::to_string(&*guard).ok()
    }

    /// 清空 @put 变量表（目录循环复用同一 AnalyzeRule 时，对齐原版每章独立 ruleData）
    pub fn clear_variables(&self) {
        if let Ok(mut guard) = self.variables.lock() {
            guard.clear();
        }
        if let Ok(mut guard) = self.local_bindings.lock() {
            guard.clear();
        }
    }

    /// 克隆变量 Arc 到子解析器（链式/子元素解析共享 put/get 状态）
    fn share_variable_store_into(&self, child: &mut AnalyzeRule) {
        child.variables = Arc::clone(&self.variables);
        child.local_bindings = Arc::clone(&self.local_bindings);
        child.redirect_url = self.redirect_url.clone();
    }

    /// 设置重定向 URL（对齐原版 `AnalyzeRule.setRedirectUrl`）
    ///
    /// data: URL 忽略；非法形态仅打日志并保留原值。返回当前 redirect_url。
    pub fn set_redirect_url(&mut self, url: &str) -> &str {
        let trimmed = url.trim();
        if trimmed.is_empty() {
            return &self.redirect_url;
        }
        if trimmed.to_ascii_lowercase().starts_with("data:") {
            return &self.redirect_url;
        }
        // 对齐原版 `URL(url)`：含 scheme 或 `//` 主机相对即接受
        let ok = trimmed.contains("://")
            || trimmed.starts_with("//")
            || trimmed.starts_with("http:")
            || trimmed.starts_with("https:");
        if ok {
            self.redirect_url = trimmed.to_string();
        } else {
            eprintln!("[AnalyzeRule] setRedirectUrl({trimmed}) 非法，忽略");
        }
        &self.redirect_url
    }

    /// 当前重定向 URL（供 isUrl 绝对化）
    pub fn redirect_url(&self) -> &str {
        &self.redirect_url
    }

    /// 设置 JS 执行器
    pub fn set_js_executor(&mut self, executor: Arc<dyn JsExecutor>) {
        self.js_executor = Some(executor);
    }

    /// 获取已注入的 JS 执行器（用于在子解析器间透传）
    pub fn js_executor(&self) -> Option<Arc<dyn JsExecutor>> {
        self.js_executor.clone()
    }

    /// 设置解析内容
    ///
    /// 设置内容后立即检测内容类型并缓存，清除解析器状态。
    pub fn set_content(&mut self, content: String) {
        self.content = content;
        // 检测并缓存内容类型
        let content_type = Self::detect_content_type(&self.content);
        self.is_json = content_type == RuleType::Json;
        self.cached_content_type = Some(content_type);
    }

    /// 设置「结构化列表元素」内容（对齐原版 Kotlin `getElements` JSON
    /// 模式返回 Map 对象后 `AnalyzeRule().setContent(item)` 的语义）
    ///
    /// 与 [`Self::set_content`] 相同，但额外标记元素模式：JS 规则执行时
    /// `result` 按**解析后的 JSON 对象**注入（对象/数组；解析失败或
    /// 非对象内容仍按字符串注入）——书山 bookUrl `<js>` 规则
    /// `result.source`/`result.book_url` 属性访问依赖对象语义，字符串
    /// 注入取不到字段 → detail={} → 所有书 bookUrl 相同 → 列表按
    /// bookUrl 去重折叠成 1 条。— DeepSeek Harness + Bridge（2026-08-14）
    pub fn set_element_content(&mut self, content: String) {
        self.json_element_mode = true;
        self.set_content(content);
    }

    /// 内容是否为 JSON
    pub fn is_json(&self) -> bool {
        self.is_json
    }

    /// 获取基础 URL
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// 设置基础 URL
    pub fn set_base_url(&mut self, base_url: String) {
        self.base_url = base_url;
    }

    /// 获取当前内容的引用
    pub fn content(&self) -> &str {
        &self.content
    }

    /// 根据规则获取字符串列表
    ///
    /// 支持:
    /// - `@css:`, `@xpath:`, `@json:`, `@regex:` 前缀指定解析类型
    /// - 自动检测规则类型
    /// - `&&`, `||`, `%%` 组合规则
    /// - `{$.rule}` 内嵌规则替换（JsonPath 场景）
    /// - `@put:{...}` 写入变量 + 剥离（对齐原版 `splitPutRule` + `putRule`）
    /// - `@get:{key}` 读取变量（对齐原版 SourceRule.makeUpRule）
    /// - 前缀/中缀 `extract@js:...` / `extract<js>...</js>` 链式（对齐
    ///   `AnalyzeRule.splitSourceRule` + JS_PATTERN；神漫画 chapterUrl、
    ///   Nhentai 正文 `//script@js:` 等）
    /// - `##regex##replacement` 结果替换（对齐原版 SourceRule.makeUpRule）
    pub fn get_strings(&self, rule: &str) -> LegadoResult<Vec<String>> {
        self.get_strings_ex(rule, false)
    }

    /// 获取字符串列表（对齐原版 `getStringList(..., isUrl)`）
    ///
    /// `is_url=true` 时将结果按 `redirect_url` 绝对化并去重。
    pub fn get_strings_ex(&self, rule: &str, is_url: bool) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        // 1) 编译缓存：put 剥离 +（无 @get 时）## / js 链预拆
        let compiled = self.compile_source_rule_cached(rule);
        self.apply_put_map(&compiled.put_map)?;

        // 纯 @put 规则（详情 init）：仅副作用，无主规则
        if compiled.rule_no_put.trim().is_empty() {
            return Ok(vec![]);
        }

        // 2) 展开 @get:{key}（对齐 makeUpRule getRuleType）
        let rule_expanded = if compiled.has_get_marker {
            self.expand_get_refs(&compiled.rule_no_put)
        } else {
            compiled.rule_no_put.clone()
        };
        // 2.5) 展开规则体内 `{{js}}`（非 $）内嵌 JS
        let rule_expanded = self.expand_js_refs(&rule_expanded)?;
        // G8：allInOne 正则 getElements 把捕获组编成 JSON 字符串数组；
        // 子规则 `$1`/`$2` 对齐 SourceRule.makeUpRule（result 为 List）回填，
        // 然后走 Mode.Regex 的 `else -> rule`（字面结果 + ## 替换）。
        if let Some(groups) = parse_regex_group_list(&self.content) {
            if rule_has_group_ref(&rule_expanded) {
                let assembled = makeup_group_refs(&rule_expanded, &groups);
                let (core, spec) = split_hash_replace(&assembled);
                let mut results = if core.is_empty() {
                    vec![]
                } else {
                    vec![core]
                };
                if let Some(spec) = spec.as_ref() {
                    results = results
                        .into_iter()
                        .map(|s| apply_hash_replace(&s, spec))
                        .collect();
                }
                return Ok(if is_url {
                    self.absolutize_url_list(results)
                } else {
                    results
                });
            }
        }
        // 纯 `@get:{k}` / `http:@get:{k}` 等：makeUpRule 后 Mode.Regex，
        // 求值走 `else -> rule` 直接返回拼装字符串，不再当选择器解析。
        if compiled.has_get_marker && !looks_like_extract_rule(&rule_expanded) {
            let raw = if rule_expanded.is_empty() {
                vec![]
            } else {
                vec![rule_expanded]
            };
            return Ok(if is_url {
                self.absolutize_url_list(raw)
            } else {
                raw
            });
        }

        // 3) ## / js 链：无 @get 命中预编译；有 @get 则对展开后规则现场拆
        let (core_rule, replace_spec, js_steps_owned) =
            if let Some(pre) = compiled.pre_hash.as_ref() {
                (
                    pre.core_rule.clone(),
                    pre.replace_spec.clone(),
                    pre.js_steps.clone(),
                )
            } else {
                let compiled_hash = compile_hash_and_chain(&rule_expanded);
                (
                    compiled_hash.core_rule,
                    compiled_hash.replace_spec,
                    compiled_hash.js_steps,
                )
            };

        // 4) `<js>...</js>`（含 `$[*]` 复合）走单步专用路径，避免被
        //    通用 JS 链拆成 Js+Extract 后丢失 `$[*]` 拆解语义（51漫画）
        //    其余 `extract@js:` 走链式（神漫画 chapterUrl / Nhentai 正文）
        let mut results = if core_rule.trim_start().starts_with("<js>") {
            self.get_strings_single_step(&core_rule)?
        } else if js_steps_owned.len() > 1 {
            let borrowed: Vec<JsChainStep<'_>> = js_steps_owned
                .iter()
                .map(|s| match s {
                    OwnedJsChainStep::Extract(e) => JsChainStep::Extract(e.as_str()),
                    OwnedJsChainStep::Js(j) => JsChainStep::Js(j.as_str()),
                })
                .collect();
            self.eval_js_chain_steps(&borrowed)?
        } else {
            self.get_strings_single_step(&core_rule)?
        };

        // 5) 应用 ## 替换
        if let Some(spec) = replace_spec.as_ref() {
            results = results
                .into_iter()
                .map(|s| apply_hash_replace(&s, spec))
                .collect();
        }
        if is_url {
            results = self.absolutize_url_list(results);
        }
        Ok(results)
    }

    /// 将相对 URL 列表按 redirect_url 绝对化并去重（对齐原版 isUrl 分支）
    fn absolutize_url_list(&self, items: Vec<String>) -> Vec<String> {
        use crate::analyze_url::AnalyzeUrl;
        let base = if self.redirect_url.is_empty() {
            self.base_url.as_str()
        } else {
            self.redirect_url.as_str()
        };
        let mut out = Vec::new();
        for item in items {
            // 原版：String 结果先按 `\n` 拆分
            for line in item.split('\n') {
                let abs = AnalyzeUrl::get_absolute_url(base, line.trim());
                if !abs.is_empty() && !out.contains(&abs) {
                    out.push(abs);
                }
            }
        }
        out
    }

    /// 单步规则（无 `@js:` 链、已剥离 `@put` / `##`）
    fn get_strings_single_step(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        // `<js>...</js>` 包裹的 JS 规则（对齐原版 RuleAnalyzer Mode.Js）：
        // 漫画/视频/音频源 ruleContent 常写作 `<js>代码</js>`（yckceo 书源
        // 大量用例），JS 结果直接作为提取结果，不再按 CSS/XPath 解析。
        // [UI-fix 2026-08-10 | Reasonix] 此前仅支持 `@js:` 前缀，`<js>` 标签
        // 落入 Auto/CSS 解析 → 正文为空（「搜到书但正文图片不显示/无法播放」）。
        // [UI-fix v2.0.23 | Reasonix] `<js>...</js>\n$[*]` 复合规则：JS 生成
        // JSON 数组字符串（如 51漫画 `JSON.stringify(d)`），`</js>` 后的
        // JSONPath 后缀将数组拆解为多个元素（每章一个对象），供子规则
        // `$.title`/`$.url` 解析 → 目录不再 0 章。
        if rule.trim_start().starts_with("<js>") {
            if let Some(end) = rule.find("</js>") {
                let js_code = &rule["<js>".len()..end];
                let js_result = self.execute_js_rule(js_code)?;
                // `</js>` 之后若有 JSONPath 后缀（如 `\n$[*]`），对 JS 结果拆解
                let suffix = rule[end + "</js>".len()..].trim();
                if suffix.starts_with("$") && !suffix.is_empty() {
                    // JS 结果为单元素（JSON 数组字符串）或多元素，逐一对
                    // JSONPath 求值后拼接（对齐原版 getElements 多元素语义）
                    // 注意：此处保留完整 JSON 数组字符串，勿提前 expand——
                    // `$[*]` 需对根数组求值（51漫画 chapterList）。
                    let mut out = Vec::new();
                    for item in &js_result {
                        if let Ok(v) = self.json_parser.parse_jsonpath(item, suffix) {
                            out.extend(v);
                        }
                    }
                    return Ok(out);
                }
                // 无 JSONPath 后缀：若 JS 返回 JSON 数组，展开为多元素
                // （对齐原版 Mode.Js → NativeArray 作为 List 语义）
                return Ok(expand_js_json_array_result(js_result));
            }
        }

        // `@webjs:...`（对齐原版 WebJS_PATTERN / Mode.WebJs）
        let trimmed = rule.trim_start();
        if let Some(rest) = trimmed
            .strip_prefix("@webjs:")
            .or_else(|| trimmed.strip_prefix("@webJs:"))
            .or_else(|| {
                // 仅 ASCII 前缀安全切片，避免 `@js:…中文` 踩 UTF-8 边界
                let bytes = trimmed.as_bytes();
                if bytes.len() >= 7 && bytes[..7].eq_ignore_ascii_case(b"@webjs:") {
                    Some(&trimmed[7..])
                } else {
                    None
                }
            })
        {
            let out = self.execute_web_js_rule(rest)?;
            return Ok(expand_js_json_array_result(vec![out]));
        }

        let (rule_type, actual_rule) = Self::resolve_rule_type(rule);

        match rule_type {
            RuleType::Css => self.html_parser.get_text(&self.content, actual_rule),
            RuleType::Xpath => self.xpath_parser.parse_xpath(&self.content, actual_rule),
            RuleType::Json => self.resolve_json_with_inner(actual_rule),
            RuleType::Regex => self.regex_extract(actual_rule),
            RuleType::Js => self.execute_js_rule_expanded(actual_rule),
            RuleType::WebJs => {
                let out = self.execute_web_js_rule(actual_rule)?;
                Ok(expand_js_json_array_result(vec![out]))
            }
            RuleType::Auto => {
                let detected = self.detect_rule_type_for_content(actual_rule);
                match detected {
                    RuleType::Json => self.resolve_json_with_inner(actual_rule),
                    RuleType::Xpath => self.xpath_parser.parse_xpath(&self.content, actual_rule),
                    RuleType::Regex => self.regex_extract(actual_rule),
                    _ => self.html_parser.get_text(&self.content, actual_rule),
                }
            }
        }
    }

    /// 执行 `extract@js:` / `extract<js>` 链（对齐原版 splitSourceRule 多 SourceRule）
    ///
    /// 前序提取结果按 `\n` 拼接后注入为下一段 JS 的 `result`（对齐
    /// `getString` 多值连接语义）；纯 JS 步可接在提取后。
    fn eval_js_chain_steps(&self, steps: &[JsChainStep<'_>]) -> LegadoResult<Vec<String>> {
        let mut current_content = self.content.clone();
        let mut last_is_js = false;
        let mut last_js_out = Vec::new();

        for (i, step) in steps.iter().enumerate() {
            match step {
                JsChainStep::Extract(rule) => {
                    let rule = rule.trim();
                    if rule.is_empty() {
                        continue;
                    }
                    // 临时以当前 content 解析（链式：后段基于前段结果文本）
                    let mut sub = AnalyzeRule::new(current_content.clone(), self.base_url.clone());
                    self.share_variable_store_into(&mut sub);
                    if let Some(exec) = self.js_executor() {
                        sub.set_js_executor(exec);
                    }
                    for (n, v) in &self.js_bindings {
                        sub.add_js_binding(n, v);
                    }
                    let extracted = sub.get_strings_single_step(rule)?;
                    current_content = if extracted.is_empty() {
                        String::new()
                    } else if extracted.len() == 1 {
                        extracted.into_iter().next().unwrap()
                    } else {
                        extracted.join("\n")
                    };
                    last_is_js = false;
                }
                JsChainStep::Js(code) => {
                    // 以当前结果为 content，使 execute_js_rule 注入 result/src
                    let mut sub = AnalyzeRule::new(current_content.clone(), self.base_url.clone());
                    self.share_variable_store_into(&mut sub);
                    if let Some(exec) = self.js_executor() {
                        sub.set_js_executor(exec);
                    }
                    for (n, v) in &self.js_bindings {
                        sub.add_js_binding(n, v);
                    }
                    let out = sub.execute_js_rule_expanded(code)?;
                    current_content = out.first().cloned().unwrap_or_default();
                    last_js_out = out;
                    last_is_js = true;
                    // 末段若仍有后缀提取（少见），继续
                    let _ = i;
                }
            }
        }

        if last_is_js {
            Ok(last_js_out)
        } else if current_content.is_empty() {
            Ok(vec![])
        } else {
            Ok(vec![current_content])
        }
    }

    /// 根据规则获取单个字符串（多个结果用换行连接）
    ///
    /// 默认 `unescape=true`（对齐原版 `getString` 默认重载）。
    pub fn get_string(&self, rule: &str) -> LegadoResult<String> {
        self.get_string_ex(rule, false, true)
    }

    /// 获取单个字符串（对齐原版 `getString(rule, unescape)` / `getString(..., isUrl)`）
    ///
    /// - `unescape`：含 `&` 时做 HTML4 实体反转义
    /// - `is_url`：结果绝对化；空结果回退 `base_url`
    pub fn get_string_ex(
        &self,
        rule: &str,
        is_url: bool,
        unescape: bool,
    ) -> LegadoResult<String> {
        let strings = self.get_strings_ex(rule, false)?;
        let mut result = if strings.is_empty() {
            String::new()
        } else if strings.len() == 1 || is_url {
            // G14：isUrl 单值取首元素（对齐原版 AnalyzeByJSoup.getString0）
            strings.into_iter().next().unwrap()
        } else {
            strings.join("\n")
        };
        if unescape && result.contains('&') {
            result = legado_core::html_formatter::unescape_html4(&result);
        }
        if is_url {
            if result.trim().is_empty() {
                return Ok(self.base_url.clone());
            }
            use crate::analyze_url::AnalyzeUrl;
            let base = if self.redirect_url.is_empty() {
                self.base_url.as_str()
            } else {
                self.redirect_url.as_str()
            };
            return Ok(AnalyzeUrl::get_absolute_url(base, result.trim()));
        }
        Ok(result)
    }

    /// 根据规则获取元素 HTML 列表
    ///
    /// CSS 规则返回元素 outerHtml；XPath/正则/JSON/JS 规则返回字符串列表
    /// （XPath 元素节点序列化为外层标记，供子规则二次解析，
    /// 对标原版 AnalyzeRule.getElements 按 Mode 分派）。
    ///
    /// 支持 `@put` 剥离与 `extract@js:` 链（Nhentai
    /// `//div.../a[1]@js:[result]` 等）。
    pub fn get_elements(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        let (rule_no_put, put_map) = extract_put_rules(rule);
        self.apply_put_map(&put_map)?;
        if rule_no_put.trim().is_empty() {
            return Ok(vec![]);
        }
        let rule_no_put = self.expand_get_refs(&rule_no_put);
        // 与 get_strings 对齐：`<js>...</js>`（含 `\n$[*]` 复合后缀）必须走
        // 单步路径。若先 split_js_chain_steps，会把 `$[*]` 拆成独立 Extract，
        // 对整页 HTML 做 JSONPath →「JSON parse error」；再被 web_book
        // `get_elements(...).unwrap_or_default()` 吞成 0 章 →「暂无章节」
        // （51漫画 chapterList 2026-08-11 复现：站点已无「目录」脚本，走
        // btn-read 回退本可出 1 章，却因链拆解整链失败）。— Reasonix
        if rule_no_put.trim_start().starts_with("<js>") {
            return self.get_elements_single_step(&rule_no_put);
        }
        let steps = split_js_chain_steps(&rule_no_put);
        if steps.len() > 1 {
            // 链式 getElements：首段按元素规则提取，后续 JS 以拼接/单元素为 result
            let mut elems: Vec<String> = Vec::new();
            let mut pending_js: Vec<&str> = Vec::new();
            for step in &steps {
                match step {
                    JsChainStep::Extract(r) => {
                        let r = r.trim();
                        if r.is_empty() {
                            continue;
                        }
                        elems = self.get_elements_single_step(r)?;
                    }
                    JsChainStep::Js(code) => pending_js.push(code),
                }
            }
            if pending_js.is_empty() {
                return Ok(elems);
            }
            // 将元素列表交给 JS：单元素直接作 result；多元素 JSON 数组字符串
            let result_payload = if elems.len() == 1 {
                elems[0].clone()
            } else {
                serde_json::to_string(&elems).unwrap_or_else(|_| elems.join("\n"))
            };
            let mut current = result_payload;
            let mut last_out = Vec::new();
            for code in pending_js {
                let mut sub = AnalyzeRule::new(current.clone(), self.base_url.clone());
                self.share_variable_store_into(&mut sub);
                if let Some(exec) = self.js_executor() {
                    sub.set_js_executor(exec);
                }
                for (n, v) in &self.js_bindings {
                    sub.add_js_binding(n, v);
                }
                last_out = sub.execute_js_rule(code)?;
                current = last_out.first().cloned().unwrap_or_default();
            }
            // JS 返回 JSON 数组时拆成多元素（`[result]` 包装场景）
            if last_out.len() == 1 {
                let s = last_out[0].trim();
                if s.starts_with('[') {
                    if let Ok(arr) = serde_json::from_str::<Vec<serde_json::Value>>(s) {
                        return Ok(arr
                            .into_iter()
                            .map(|v| match v {
                                serde_json::Value::String(x) => x,
                                other => other.to_string(),
                            })
                            .collect());
                    }
                }
            }
            return Ok(last_out);
        }

        self.get_elements_single_step(&rule_no_put)
    }

    /// 单步 getElements（无 `@js:` 链）
    fn get_elements_single_step(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        // `<js>...</js>` 规则（含 `$[*]` 复合）统一走 get_strings：
        // resolve_rule_type 可能把 `<js>` 前缀判定为 Auto/Css，导致
        // 误走 HTML 解析器 → 目录 0 章（51漫画 chapterList 实测）— Reasonix
        if rule.trim_start().starts_with("<js>") {
            return self.get_strings_single_step(rule);
        }

        // G10：`:` 前缀 allInOne 正则（对齐原版 splitSourceRule(allInOne=true)）
        // 有捕获组时序列化 [g0,g1,…] JSON，供 G8 `$n` 回填（书书小说等）
        if let Some(regex_rule) = rule.trim_start().strip_prefix(':') {
            return self.regex_extract_all_in_one(regex_rule.trim_start());
        }

        let (rule_type, actual_rule) = Self::resolve_rule_type(rule);

        match rule_type {
            RuleType::Css => self.html_parser.get_elements(&self.content, actual_rule),
            RuleType::Auto => {
                // 无显式前缀时按规则/内容特征检测（避免 `//*[...]` 等 XPath
                // 规则被误路由到 CSS 解析器）
                let detected = self.detect_rule_type_for_content(actual_rule);
                match detected {
                    RuleType::Css => self.html_parser.get_elements(&self.content, actual_rule),
                    _ => self.get_strings_single_step(rule),
                }
            }
            _ => self.get_strings_single_step(rule),
        }
    }

    /// 获取属性值（仅 CSS）
    pub fn get_attr(&self, rule: &str, attr: &str) -> LegadoResult<Vec<String>> {
        let (_, actual_rule) = Self::resolve_rule_type(rule);
        self.html_parser.get_attr(&self.content, actual_rule, attr)
    }

    /// 正则提取（含多级 `&&` 链，对齐 AnalyzeByRegex.getElement/getElements）
    ///
    /// `rule1&&rule2`：rule1 在原文上筛取全部完整匹配并拼接，再交给 rule2；
    /// 末级返回所有完整匹配（group 0）。单级时退化为普通 regex_match。
    fn regex_extract(&self, rule: &str) -> LegadoResult<Vec<String>> {
        let patterns: Vec<&str> = rule
            .split("&&")
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        if patterns.len() <= 1 {
            return self.regex_engine.regex_match(&self.content, rule);
        }
        let groups = self
            .regex_engine
            .regex_chain_match_all(&self.content, &patterns)?;
        Ok(groups
            .into_iter()
            .map(|g| g.first().cloned().unwrap_or_default())
            .collect())
    }

    /// allInOne 正则 getElements：对齐 AnalyzeByRegex.getElements
    ///
    /// 末级每个匹配产出 `[全文, $1, $2, …]`；多于一组捕获时编成 JSON
    /// 数组字符串，使后续 `get_string("$2")` 可跨步回填。无捕获组仍返回
    /// 全文（保持 G10 `test_all_in_one_regex_colon_prefix`）。
    fn regex_extract_all_in_one(&self, rule: &str) -> LegadoResult<Vec<String>> {
        let patterns: Vec<&str> = rule
            .split("&&")
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        let groups_list = if patterns.len() <= 1 {
            self.regex_engine.regex_match_groups(&self.content, rule)?
        } else {
            self.regex_engine
                .regex_chain_match_all(&self.content, &patterns)?
        };
        Ok(groups_list
            .into_iter()
            .map(|g| encode_regex_element_groups(&g))
            .filter(|s| !s.is_empty())
            .collect())
    }

    /// 正则匹配获取捕获组
    pub fn regex_match_groups(&self, pattern: &str) -> LegadoResult<Vec<Vec<String>>> {
        self.regex_engine.regex_match_groups(&self.content, pattern)
    }

    /// 多级正则匹配
    pub fn regex_chain(&self, patterns: &[&str]) -> LegadoResult<Option<Vec<String>>> {
        self.regex_engine.regex_chain_match(&self.content, patterns)
    }

    /// 执行 putMap（对齐原版 `putRule`：对每个 value 再 getString 后 put）
    fn apply_put_map(&self, put_map: &HashMap<String, String>) -> LegadoResult<()> {
        for (key, value_rule) in put_map {
            // 直接单步求值，避免 value_rule 内嵌 @put 时递归炸栈；
            // 常见值为 `$.chapter_id` / CSS 选择器，不含 @put。
            let (cleaned, nested) = extract_put_rules(value_rule);
            // 嵌套 @put 极少见；若有则先剥离再求值（嵌套 map 忽略）
            let _ = nested;
            let val = if cleaned.trim().is_empty() {
                String::new()
            } else {
                // 展开已有 @get，再单步提取（不走完整 get_strings，防 put 递归）
                let expanded = self.expand_get_refs(&cleaned);
                self.get_strings_single_step(&expanded)?
                    .into_iter()
                    .next()
                    .unwrap_or_default()
            };
            self.put(key, &val);
        }
        Ok(())
    }

    /// 将规则中的 `@get:{key}` 替换为已存变量（对齐 makeUpRule getRuleType）
    fn expand_get_refs(&self, rule: &str) -> String {
        let re = regex::Regex::new(r"(?i)@get:\{([^}]+)\}").unwrap();
        re.replace_all(rule, |caps: &regex::Captures| {
            let key = caps.get(1).map(|m| m.as_str()).unwrap_or("");
            self.get(key)
        })
        .into_owned()
    }

    /// 从 `{{` 起始的串里找匹配的 `}}` 结尾（返回含结尾 `}}` 的字节长度）
    fn find_double_brace_end(s: &str) -> Option<usize> {
        let bytes = s.as_bytes();
        if bytes.len() < 2 || bytes[0] != b'{' || bytes[1] != b'{' {
            return None;
        }
        let mut depth = 0i32;
        let mut i = 2usize;
        let mut quote: Option<u8> = None;
        while i < bytes.len() {
            let b = bytes[i];
            if let Some(q) = quote {
                if b == q {
                    quote = None;
                }
                i += 1;
                continue;
            }
            match b {
                b'"' | 39 => {
                    quote = Some(b);
                    i += 1;
                }
                b'{' => {
                    depth += 1;
                    i += 1;
                }
                b'}' => {
                    if depth == 0 && bytes.get(i + 1) == Some(&b'}') {
                        return Some(i + 2);
                    }
                    depth = depth.saturating_sub(1);
                    i += 1;
                }
                _ => {
                    i += 1;
                }
            }
        }
        None
    }

    /// 展开规则体内 `{{js}}`（非 `$`/`@` 开头的双花括号 JS 内嵌，
    /// 对齐 makeUpRule 的 jsRuleType 分支）
    ///
    /// `{{\$...}}` 是 Rust 新增的 JSONPath 内嵌语义，此处跳过，交给
    /// process_inner_rules；`@get:{k}` 已由 expand_get_refs 先行处理。
    fn expand_js_refs(&self, rule: &str) -> LegadoResult<String> {
        if !rule.contains("{{") {
            return Ok(rule.to_string());
        }
        let mut out = String::with_capacity(rule.len());
        let mut i = 0usize;
        let bytes = rule.as_bytes();
        while i < bytes.len() {
            if bytes[i] == b'{' && bytes.get(i + 1) == Some(&b'{') {
                if let Some(full_len) = Self::find_double_brace_end(&rule[i..]) {
                    let inner = rule[i + 2..i + full_len - 2].trim();
                    if inner.starts_with('$') || inner.starts_with('@') {
                        // JSONPath / 其它规则前缀：原样保留
                        out.push_str(&rule[i..i + full_len]);
                    } else {
                        // 仅在 eval 成功且结果非空时替换；失败/为空时**保留原文**——
                        // 恢复 G11 前的直通行为：模板可能依赖书源 jsLib/上下文或由
                        // 上层（URL 构建 / web_book）按正确绑定再解析，例如书山聚合
                        // ruleBookInfo 的 `{{getSecretKey()}}`、`{{"\n"+"\u200b"}}`
                        //（此前被替换成空串导致书籍详情/简介被破坏）。
                        match self.execute_js_rule(inner) {
                            Ok(js_result) if !js_result.is_empty() => {
                                let val = if js_result.len() == 1 {
                                    js_result[0].clone()
                                } else {
                                    js_result.join("\n")
                                };
                                out.push_str(&val);
                            }
                            _ => out.push_str(&rule[i..i + full_len]),
                        }
                    }
                    i += full_len;
                    continue;
                }
            }
            let ch = rule[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
        Ok(out)
    }

    // --- 内部方法 ---

    /// 执行 JS 规则
    ///
    /// 如果已注入 JsExecutor，则调用其执行 JS 代码；
    /// 否则降级返回空结果。
    fn execute_js_rule(&self, js_code: &str) -> LegadoResult<Vec<String>> {
        if let Some(executor) = &self.js_executor {
            // 注入原版 evalJS bindings 语义：result/src/baseUrl 自动注入，
            // 附加变量（chapter/title/source 等）按调用方补充。
            // [UI-fix 2026-08-10 | Reasonix] 此前零注入 → 视频源
            // `String(result)` 与漫画源 `src.match(...)` 全部 ReferenceError
            // → 正文为空（「搜到书但正文图片不显示/无法播放」根因）。
            let mut prologue = String::new();
            // 预声明常见裸赋值变量（var）：QuickJS eval 处于严格模式，书源
            // 规则里的 `d = ...`/`data = ...` 等未声明赋值抛 ReferenceError
            //（51漫画 chapterList 的 `d = c ? ... : [...]`）。var 预声明后
            // 赋值合法。注意：不可预声明书源可能用 const/let 声明的变量
            //（如 scripts/c/item 等，var 与 const 同名冲突）；此处仅覆盖
            // 书源惯用的裸赋值临时变量名，且 result/src/baseUrl/book 等已
            // 由下方 globalThis 注入，不重复声明（避免与 jsLib let/const
            // 冲突）— Reasonix
            // len/jm/from：影视频源 TOC/正文惯用裸赋值（榴莲 `len=java.getElements`
            // 、红牛 `jm=...`）。不预声明 start/end/host/i/url（书源常 let/const
            // 同名，var 预声明会 SyntaxError）— Reasonix
            prologue.push_str(
                "var d, data, json, list, arr, obj, tmp, index, num, comic_chapter, header, headers, chapter_domain, end_num, rule, pic, html, img_ext, all, len, jm, from;\n",
            );
            if let Ok(content_json) = serde_json::to_string(&self.content) {
                // 经 globalThis 属性赋值注入（对齐原版 ScriptableObject.put
                // 语义）：① 不能裸赋值 `result = ...`——QuickJS eval 处于
                // 严格模式，未声明变量赋值抛 ReferenceError（实测
                // "result is not defined"）；② 不能用 `var result = ...`——
                // 书源 jsLib 若已声明 let/const result，var 同名声明抛
                // SyntaxError（redeclaration）。globalThis 属性赋值两者
                // 皆可：严格模式合法、不构成重复声明 — Reasonix
                // ③ JSON 列表元素模式：result 按解析后的对象注入
                // （对齐原版 getElements 返回 Map 对象 → `result.source`
                // 属性访问；书山 bookUrl 等规则依赖，字符串注入取不到
                // 字段 → 所有书 bookUrl 相同 → 去重折叠成 1 条）。
                // — DeepSeek Harness + Bridge（2026-08-14 去重折叠修复）
                let result_literal = if self.json_element_mode {
                    match serde_json::from_str::<serde_json::Value>(&self.content) {
                        Ok(v) if v.is_object() || v.is_array() => {
                            serde_json::to_string(&v).unwrap_or_else(|_| content_json.clone())
                        }
                        _ => content_json.clone(),
                    }
                } else {
                    content_json.clone()
                };
                prologue.push_str(&format!("globalThis.result = {result_literal};\n"));
                prologue.push_str(&format!("globalThis.src = {content_json};\n"));
            }
            if let Ok(base_json) = serde_json::to_string(&self.base_url) {
                prologue.push_str(&format!("globalThis.baseUrl = {base_json};\n"));
            }
            for (name, value) in &self.js_bindings {
                // json_literal 已是合法 JSON 字面量，globalThis 属性赋值注入
                prologue.push_str(&format!("globalThis.{name} = {value};\n"));
            }
            // 对齐原版 java.put / java.get / java.setLocal（会话变量）
            if let Ok(guard) = self.variables.lock() {
                let vars_json = serde_json::to_string(&*guard).unwrap_or_else(|_| "{}".into());
                prologue.push_str(&format!(
                    "if (typeof java !== 'undefined') {{\n\
                     var __lgVars = {vars_json};\n\
                     java.put = function(k,v){{ __lgVars[k]=String(v==null?'':v); return __lgVars[k]; }};\n\
                     java.get = function(k){{ return (__lgVars[k]!=null)?String(__lgVars[k]):''; }};\n\
                     java.setLocal = function(k,v){{ __lgVars[k]=String(v==null?'':v); return java; }};\n\
                     }}\n"
                ));
            }
            let wrapped = {
                // 规则 JS 经 Function 内 eval 执行：**独立词法作用域**。
                // 规则顶层 `let/const` 声明（如书山 bookUrl 规则的
                // `let source = result.source`）此前与 jsLib/setup 预置的
                // 全局 `var`（var source/hosts 等）处于同一 QuickJS 全局
                // 词法环境 → "redeclaration of 'source'" SyntaxError →
                // 规则结果被 unwrap_or_default 吞成空 → bookUrl 回退
                // baseUrl → 列表按 bookUrl 去重折叠成 1 条（个性推荐
                // 只剩一本）。对齐 Rhino 每次 evalJS 独立作用域语义；
                // Function 体非严格，裸调用 this=globalThis 与顶层 eval
                // 一致（书山 jsLib getSessionId 等 `let { source } = this`）。
                // — DeepSeek Harness + Bridge（2026-08-14 书山去重折叠修复）
                let code_json = serde_json::to_string(js_code)
                    .unwrap_or_else(|_| "\"\"".to_string());
                format!(
                    "{prologue}\nnew Function('__legadoCode', 'return eval(__legadoCode);')({code_json})"
                )
            };
            match executor.execute_js(&wrapped) {
                Ok(result) => Ok(normalize_js_rule_result(result)),
                Err(e) => Err(legado_core::LegadoError::JsEngine(format!(
                    "JS 执行失败: {}",
                    e
                ))),
            }
        } else {
            // 无执行器时降级返回空结果
            Ok(vec![])
        }
    }

    /// 执行 JS 并将 JSON 数组展开为多元素（对齐原版 NativeArray List 语义）
    ///
    /// `<js>…</js>\n$[*]` 复合规则必须先拿完整数组字符串再 JsonPath，
    /// 故该路径调用 [`Self::execute_js_rule`]（不展开）；其余 `@js:` /
    /// 无后缀 `<js>` 走本方法。
    fn execute_js_rule_expanded(&self, js_code: &str) -> LegadoResult<Vec<String>> {
        Ok(expand_js_json_array_result(self.execute_js_rule(js_code)?))
    }

    /// 解析 JsonPath 规则，支持 `{$.rule}` 内嵌规则替换
    ///
    /// 神漫画 bookUrl/coverUrl：
    /// `https://...?comic_id={$.comic_id}&...` — 内嵌替换后得到完整 URL，
    /// **不得再当 JsonPath 求值**（否则空串 → 回退书源主页 → 目录失败）。
    fn resolve_json_with_inner(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.contains("{$") {
            let processed = self.process_inner_rules(rule)?;
            let trimmed = processed.trim();
            if trimmed.is_empty() {
                return Ok(vec![]);
            }
            if trimmed.starts_with('$') {
                return self.json_parser.parse_jsonpath(&self.content, trimmed);
            }
            // 整规则仅为 `{$.x}` / `{{$.x}}` 且替换后为裸字段名 → 再求 JsonPath
            // （`getString("{$.key}")` → 先得 name 再取 $.name → 张三）
            let only_inner = {
                let t = rule.trim();
                (t.starts_with('{') && t.ends_with('}') && !t[1..t.len() - 1].contains('{'))
                    || (t.starts_with("{{") && t.ends_with("}}"))
            };
            if only_inner
                && !trimmed.contains("://")
                && !trimmed.contains('/')
                && !trimmed.contains('?')
                && !trimmed.contains('&')
                && !trimmed.contains('=')
                && !trimmed.contains('\n')
            {
                let as_path = if trimmed.starts_with('$') {
                    trimmed.to_string()
                } else {
                    format!("$.{trimmed}")
                };
                if let Ok(v) = self.json_parser.parse_jsonpath(&self.content, &as_path) {
                    if !v.is_empty() {
                        return Ok(v);
                    }
                }
            }
            // URL/字面量模板：替换后不再当 JsonPath（神漫画 bookUrl 等）
            return Ok(vec![processed]);
        }
        self.json_parser.parse_jsonpath(&self.content, rule)
    }

    /// 处理规则中的 `{$.rule}` / `{{$.rule}}` 内嵌表达式
    ///
    /// 将 `{$.some.path}` 或 `{{$.some.path}}` 替换为其在当前内容上的解析结果。
    /// 双花括号形式见于丁斐/漫画人等书源：`...?comic_id={{$.comic_id}}&...`；
    /// 若只剥内层 `{$.x}` 会残留外层花括号变成 `comic_id={106209}` → TOC 422。— Reasonix
    fn process_inner_rules(&self, rule: &str) -> LegadoResult<String> {
        if !rule.contains("{$") {
            return Ok(rule.to_string());
        }

        let mut current = rule.to_string();

        // 1) 优先处理双花括号 {{$.path}}
        if current.contains("{{$") {
            let re = regex::Regex::new(r"\{\{(\$[^}]*)\}\}").unwrap();
            let mut out = String::with_capacity(current.len());
            let mut last = 0;
            for cap in re.captures_iter(&current) {
                let m = cap.get(0).unwrap();
                out.push_str(&current[last..m.start()]);
                let inner = cap.get(1).map(|g| g.as_str()).unwrap_or("");
                let replaced = self
                    .json_parser
                    .parse_jsonpath(&self.content, inner)
                    .ok()
                    .and_then(|v| {
                        if v.is_empty() {
                            None
                        } else if v.len() == 1 {
                            Some(v[0].clone())
                        } else {
                            Some(v.join("\n"))
                        }
                    })
                    .unwrap_or_default();
                out.push_str(&replaced);
                last = m.end();
            }
            out.push_str(&current[last..]);
            current = out;
        }

        // 2) 单花括号 {$.path}（神漫画等）
        if !current.contains("{$") {
            return Ok(current);
        }

        let mut analyzer = RuleAnalyzer::new(&current, true);
        let result = analyzer.inner_rule("{$", 1, 1, |inner_rule| {
            self.json_parser
                .parse_jsonpath(&self.content, inner_rule)
                .ok()
                .and_then(|v| {
                    if v.is_empty() {
                        None
                    } else if v.len() == 1 {
                        Some(v[0].clone())
                    } else {
                        Some(v.join("\n"))
                    }
                })
        });

        if result.is_empty() {
            Ok(current)
        } else {
            Ok(result)
        }
    }

    /// 解析规则前缀，返回 (规则类型, 去掉前缀后的规则)
    fn resolve_rule_type(rule: &str) -> (RuleType, &str) {
        // G7：@@ 前缀强制 Default(CSS) 并剥 2 字符（对齐原版 SourceRule.init）
        if let Some(r) = rule.strip_prefix("@@") {
            return (RuleType::Css, r);
        }
        let (prefix, actual_rule) = RuleAnalyzer::parse_rule_prefix(rule);
        let rule_type = match prefix {
            "css" => RuleType::Css,
            "xpath" => RuleType::Xpath,
            "json" => RuleType::Json,
            "regex" => RuleType::Regex,
            "js" => RuleType::Js,
            "webjs" => RuleType::WebJs,
            _ => RuleType::Auto,
        };
        (rule_type, actual_rule)
    }

    /// 执行 `@webjs:`（对齐原版 `getWebJsResult`）
    ///
    /// 优先：Flutter 已订阅时经 `webview_channel` 走真实 DOM（BackstageWebView 语义）；
    /// 回退：无头 QuickJS 注入 `result`/`src`/`html`/`baseUrl`。
    ///
    /// **边界**：DOM 路径提供 `document`/`window`/`window.result`；
    /// Android 页内经原生 Backstage 注入 `java`/`source`/`cache` JavascriptInterface
    ///（变量读写与精简同步 API；ajax 等网络类仍建议无头宿主）。
    fn execute_web_js_rule(&self, js_code: &str) -> LegadoResult<String> {
        // 1) DOM 通道（对齐 AnalyzeRule.getWebJsResult → BackstageWebView isRule）
        if legado_core::webview_channel::has_subscribers() {
            let result_json =
                serde_json::to_string(&self.content).unwrap_or_else(|_| "\"\"".into());
            let req = legado_core::webview_channel::WebViewRequest {
                key: String::new(),
                action: "webView".into(),
                html: self.content.clone(),
                url: self.base_url.clone(),
                js: js_code.to_string(),
                source_regex: String::new(),
                override_url_regex: String::new(),
                cache_first: true,
                delay_time: 0,
                is_rule: true,
                result: result_json,
                created_at_ms: 0,
            };
            match legado_core::webview_channel::request_and_wait(
                req,
                legado_core::webview_channel::RULE_WEBVIEW_TIMEOUT,
            ) {
                Ok(s) if !s.trim().is_empty() && !s.starts_with("[ERROR]") => {
                    return Ok(s);
                }
                Ok(_) | Err(_) => {
                    eprintln!("[AnalyzeRule] @webjs DOM 通道未得有效结果，回退无头");
                }
            }
        }

        // 2) 无头 QuickJS 近似
        let Some(executor) = self.js_executor.as_ref() else {
            return Ok(String::new());
        };
        let result_lit = serde_json::to_string(&self.content).unwrap_or_else(|_| "\"\"".into());
        let base_lit = serde_json::to_string(&self.base_url).unwrap_or_else(|_| "\"\"".into());
        let mut prologue = format!(
            "globalThis.result = {result_lit};\n\
             globalThis.src = {result_lit};\n\
             globalThis.html = {result_lit};\n\
             globalThis.baseUrl = {base_lit};\n"
        );
        for (name, lit) in &self.js_bindings {
            prologue.push_str(&format!("globalThis.{name} = {lit};\n"));
        }
        prologue.push_str(js_code);
        match executor.execute_js(&prologue) {
            Ok(s) => Ok(s),
            Err(e) => {
                eprintln!("[AnalyzeRule] @webjs 执行失败（无头近似）: {e}");
                Ok(String::new())
            }
        }
    }

    /// 根据规则特征和当前内容类型自动检测规则类型
    fn detect_rule_type_for_content(&self, rule: &str) -> RuleType {
        let rule = rule.trim();

        // 1. 根据规则自身特征推断
        if rule.starts_with('$') || rule.starts_with("$.") {
            return RuleType::Json;
        }
        if rule.starts_with('/') || rule.starts_with("//") {
            return RuleType::Xpath;
        }
        if rule.contains(r"\d")
            || rule.contains(r"\w")
            || rule.contains(r"\s")
            || (rule.starts_with('(') && rule.contains(')'))
        {
            return RuleType::Regex;
        }

        // 2. 根据缓存的内容类型推断（快速路径）
        // 对齐原版 AnalyzeRule.kt:680：isJSON → Mode.Json——JSON 内容下
        // 非显式 @CSS:/@@ 前缀的规则一律按 JsonPath 解析（丁丁小说 `.data[*]`、
        // 书旗 `.data` 等无 $ 前缀 JSON 列表规则依赖；此前误判 CSS → 空结果）。
        if self.is_json {
            return RuleType::Json;
        } else if let Some(ref ct) = self.cached_content_type {
            if *ct == RuleType::Xpath {
                return RuleType::Xpath;
            }
        }

        // 默认 CSS
        RuleType::Css
    }

    /// 判断规则是否形似 CSS 选择器（用于 JSON 内容下的规则类型仲裁）
    ///
    /// 仅依据强 CSS 特征判定，避免误伤无 `$` 前缀的 JsonPath 规则（如 `data.list`）：
    /// - 以 `.` 类选择器或 `#` ID 选择器开头
    /// - 含 Legado 取值后缀 `@text` / `@html` / `@href` / `@src`
    fn looks_like_css_selector(rule: &str) -> bool {
        let head = rule.split_whitespace().next().unwrap_or("");
        if matches!(head.chars().next(), Some('.') | Some('#')) {
            return true;
        }
        rule.contains("@text")
            || rule.contains("@html")
            || rule.contains("@href")
            || rule.contains("@src")
    }

    /// 获取缓存的内容类型
    pub fn content_type(&self) -> RuleType {
        if let Some(ref cached) = self.cached_content_type {
            return cached.clone();
        }
        Self::detect_content_type(&self.content)
    }

    /// 根据内容或规则特征自动检测规则类型（静态方法）
    pub fn detect_rule_type(rule: &str) -> RuleType {
        let rule = rule.trim();

        let (prefix, _) = RuleAnalyzer::parse_rule_prefix(rule);
        match prefix {
            "css" => return RuleType::Css,
            "xpath" => return RuleType::Xpath,
            "json" => return RuleType::Json,
            "regex" => return RuleType::Regex,
            "js" => return RuleType::Js,
            _ => {}
        }

        if rule.starts_with('$') || rule.starts_with("$.") {
            return RuleType::Json;
        }
        if rule.starts_with('/') || rule.starts_with("//") {
            return RuleType::Xpath;
        }
        if rule.contains(r"\d")
            || rule.contains(r"\w")
            || rule.contains(r"\s")
            || (rule.starts_with('(') && rule.contains(')'))
        {
            return RuleType::Regex;
        }

        RuleType::Css
    }

    /// 自动检测内容类型
    pub fn detect_content_type(content: &str) -> RuleType {
        let trimmed = content.trim();

        // JSON 内容
        if ((trimmed.starts_with('{') && trimmed.ends_with('}'))
            || (trimmed.starts_with('[') && trimmed.ends_with(']')))
            && serde_json::from_str::<serde_json::Value>(trimmed).is_ok()
        {
            return RuleType::Json;
        }

        // XML/XHTML 内容
        if trimmed.starts_with("<?xml") || trimmed.starts_with("<?XML") {
            return RuleType::Xpath;
        }

        // 默认为 HTML
        RuleType::Css
    }
}

// ─── 规则预处理：@put / @js 链 / ## 替换（对齐 AnalyzeRule.SourceRule）────────

/// 编译后的规则结构（对齐原版 `stringRuleCache` / `SourceRule` 列表）
///
/// 缓存 put 剥离、`##` 替换与 `@js`/`<js>` 链拆分，避免同一规则在列表解析
/// 中被反复正则拆解。`@get:{k}` 仍在求值期展开（依赖运行时变量）。
#[derive(Debug, Clone)]
struct CompiledSourceRule {
    put_map: HashMap<String, String>,
    /// 剥离 `@put` 后的主规则（仍可能含 `@get:`）
    rule_no_put: String,
    /// `rule_no_put` 在 `@get` 展开前是否含 `@get:`（大小写不敏感探测用原文）
    has_get_marker: bool,
    /// 若无 `@get`，可预拆 ## / js 链；有 `@get` 则在展开后再拆
    pre_hash: Option<CompiledHashAndChain>,
}

#[derive(Debug, Clone)]
struct CompiledHashAndChain {
    core_rule: String,
    replace_spec: Option<HashReplaceSpec>,
    /// 预拆的 js 链（owned）；单步时 steps 仅 Extract(core)
    js_steps: Vec<OwnedJsChainStep>,
}

#[derive(Debug, Clone)]
enum OwnedJsChainStep {
    Extract(String),
    Js(String),
}

impl AnalyzeRule {
    /// 对齐 `splitSourceRuleCacheString`：按规则原文取编译缓存
    fn compile_source_rule_cached(&self, rule: &str) -> Arc<CompiledSourceRule> {
        if let Ok(guard) = self.string_rule_cache.lock() {
            if let Some(hit) = guard.get(rule) {
                return Arc::clone(hit);
            }
        }
        let compiled = Arc::new(compile_source_rule(rule));
        if let Ok(mut guard) = self.string_rule_cache.lock() {
            // 限制体积，对齐 getOrPutLimit 量级（原版单条规则缓存无硬上限，
            // 此处防异常长会话膨胀）
            if guard.len() >= 256 {
                guard.clear();
            }
            guard.insert(rule.to_string(), Arc::clone(&compiled));
        }
        compiled
    }
}

fn compile_source_rule(rule: &str) -> CompiledSourceRule {
    let (rule_no_put, put_map) = extract_put_rules(rule);
    let has_get_marker = rule_no_put.to_ascii_lowercase().contains("@get:");
    // `{{js}}` 内嵌需在编译后运行时展开（依赖 JS executor），故含 `{{` 的
    // 规则不预拆 ##/js 链，留待 get_strings_ex 内 expand_js_refs 展开后再现场编译
    //（否则预拆得到的 core_rule 仍含未展开的 `{{js}}`，替换被丢弃）。
    let pre_hash = if has_get_marker || rule_no_put.trim().is_empty() || rule_no_put.contains("{{") {
        None
    } else {
        Some(compile_hash_and_chain(&rule_no_put))
    };
    CompiledSourceRule {
        put_map,
        rule_no_put,
        has_get_marker,
        pre_hash,
    }
}

fn compile_hash_and_chain(rule: &str) -> CompiledHashAndChain {
    let (core_rule, replace_spec) = split_hash_replace(rule);
    let js_steps = split_js_chain_steps(&core_rule)
        .into_iter()
        .map(|s| match s {
            JsChainStep::Extract(e) => OwnedJsChainStep::Extract(e.to_string()),
            JsChainStep::Js(j) => OwnedJsChainStep::Js(j.to_string()),
        })
        .collect();
    CompiledHashAndChain {
        core_rule,
        replace_spec,
        js_steps,
    }
}

/// JS 链步骤（对齐原版 `splitSourceRule` + `JS_PATTERN`）
enum JsChainStep<'a> {
    Extract(&'a str),
    Js(&'a str),
}

/// 规范化 JS 执行器原始返回值（尚未展开数组）
///
/// - 空串 / `null` / `undefined` → 空列表
/// - 其余 → 单元素列表（对象/数组已在引擎层 JSON.stringify）
fn normalize_js_rule_result(result: String) -> Vec<String> {
    let trimmed = result.trim();
    if trimmed.is_empty() || trimmed == "null" || trimmed == "undefined" {
        Vec::new()
    } else {
        vec![result]
    }
}

/// 将单元素 JSON 数组展开为多元素（对齐原版 Mode.Js → NativeArray）
///
/// - `["书名"]` → `["书名"]`（getString 得「书名」，不再是 `Array(0x…)`）
/// - `[{...},{...}]` → 每个对象的 JSON 字符串（目录/列表子规则可二次解析）
/// - 非数组或解析失败 → 原样返回
fn expand_js_json_array_result(results: Vec<String>) -> Vec<String> {
    if results.len() != 1 {
        return results;
    }
    let raw = &results[0];
    match serde_json::from_str::<serde_json::Value>(raw) {
        Ok(serde_json::Value::Array(arr)) => {
            if arr.is_empty() {
                return Vec::new();
            }
            arr.into_iter()
                .map(|v| match v {
                    serde_json::Value::String(s) => s,
                    other => other.to_string(),
                })
                .collect()
        }
        _ => results,
    }
}

/// 分离 `@put:{...}`（对齐 `splitPutRule` / `putPattern`）
///
/// 返回 (剥离后主规则, putMap)。putMap 的 value 仍是待求值规则字符串。
/// 神漫画 `$.chapter_name@put:{chapter_id:$.chapter_id}` 若不剥离，
/// JsonPath 整串失败 → 章名空 → get_chapters 跳过 → 目录为空。
fn extract_put_rules(rule: &str) -> (String, HashMap<String, String>) {
    let re = regex::Regex::new(r"(?i)@put:(\{[^}]+?\})").unwrap();
    let mut put_map = HashMap::new();
    for cap in re.captures_iter(rule) {
        if let Some(json_body) = cap.get(1) {
            for (k, v) in parse_put_json_object(json_body.as_str()) {
                put_map.insert(k, v);
            }
        }
    }
    let cleaned = re.replace_all(rule, "").into_owned();
    (cleaned, put_map)
}

/// 剥离 `@put:{...}`（兼容旧调用 / 单测）
#[cfg(test)]
fn strip_put_rules(rule: &str) -> String {
    extract_put_rules(rule).0
}

/// 展开后的规则是否仍像可解析规则（否则按字面量返回）
fn looks_like_extract_rule(rule: &str) -> bool {
    let t = rule.trim_start();
    if t.is_empty() {
        return false;
    }
    t.starts_with('$')
        || t.starts_with('@')
        || t.starts_with("//")
        || t.starts_with('<')
        || t.starts_with("@@")
        || t.contains("@js:")
        || t.contains("<js>")
}

/// allInOne 元素编码：有捕获组时为 JSON 字符串数组，否则全文
fn encode_regex_element_groups(groups: &[String]) -> String {
    if groups.len() <= 1 {
        return groups.first().cloned().unwrap_or_default();
    }
    serde_json::to_string(groups).unwrap_or_else(|_| groups[0].clone())
}

/// 从 allInOne 元素内容还原捕获组列表（必须是全字符串 JSON 数组）
fn parse_regex_group_list(content: &str) -> Option<Vec<String>> {
    let trimmed = content.trim();
    if !trimmed.starts_with('[') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(trimmed).ok()?;
    let arr = v.as_array()?;
    if arr.is_empty() || !arr.iter().all(|x| x.is_string()) {
        return None;
    }
    Some(
        arr.iter()
            .filter_map(|x| x.as_str().map(|s| s.to_string()))
            .collect(),
    )
}

/// 是否含跨步 `$n`（1-99）；排除 `$.` / `$[` / `${` JSONPath/模板
fn rule_has_group_ref(rule: &str) -> bool {
    let b = rule.as_bytes();
    let mut i = 0;
    while i + 1 < b.len() {
        if b[i] == b'$' && b[i + 1].is_ascii_digit() {
            return true;
        }
        i += 1;
    }
    false
}

/// 对齐 makeUpRule：`$n` 取前序正则捕获组（group 0 为全文）
fn makeup_group_refs(rule: &str, groups: &[String]) -> String {
    let mut out = rule.to_string();
    for n in (1..=99).rev() {
        let token = format!("${n}");
        if out.contains(&token) {
            let val = groups.get(n).map(|s| s.as_str()).unwrap_or("");
            out = out.replace(&token, val);
        }
    }
    out
}

/// 解析 `@put` 对象：兼容规范 JSON 与书源惯用非规范形态
/// `{chapter_id:$.chapter_id}` / `{n:"css",a:"css2"}`
fn parse_put_json_object(raw: &str) -> HashMap<String, String> {
    // 先尝试标准 JSON
    if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(raw) {
        return map;
    }
    // 宽松：去掉外层 {}，按顶层逗号拆（忽略引号内逗号）
    let inner = raw
        .trim()
        .trim_start_matches('{')
        .trim_end_matches('}')
        .trim();
    let mut map = HashMap::new();
    if inner.is_empty() {
        return map;
    }
    for part in split_top_level_commas(inner) {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let (key, value) = match part.split_once(':') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => continue,
        };
        let key = key.trim_matches('"').trim_matches('\'').to_string();
        let value = if (value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\''))
        {
            // 去掉引号并处理常见转义
            let unquoted = &value[1..value.len() - 1];
            unquoted.replace("\\\"", "\"").replace("\\n", "\n")
        } else {
            value.to_string()
        };
        if !key.is_empty() {
            map.insert(key, value);
        }
    }
    map
}

/// 按顶层逗号分割（不切开引号内的逗号）
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut in_quote: Option<char> = None;
    let mut depth = 0i32;
    for (i, ch) in s.char_indices() {
        match (ch, in_quote) {
            ('"' | '\'', None) => in_quote = Some(ch),
            (q, Some(oq)) if q == oq => in_quote = None,
            ('{', None) => depth += 1,
            ('}', None) => depth -= 1,
            (',', None) if depth == 0 => {
                parts.push(&s[start..i]);
                start = i + ch.len_utf8();
            }
            _ => {}
        }
    }
    if start <= s.len() {
        parts.push(&s[start..]);
    }
    parts
}

/// 按原版 `JS_PATTERN` 拆分：`<js>...</js>|@js:...`
///
/// `@js:` 贪婪吃到末尾（与 Java `[\w\W]*` 一致），故通常至多一段尾部 JS。
fn split_js_chain_steps(rule: &str) -> Vec<JsChainStep<'_>> {
    let re = regex::Regex::new(r"(?i)<js>([\s\S]*?)</js>|@js:([\s\S]*)").unwrap();
    let mut steps = Vec::new();
    let mut start = 0;
    for cap in re.captures_iter(rule) {
        let m = cap.get(0).unwrap();
        if m.start() > start {
            let prefix = rule[start..m.start()].trim();
            if !prefix.is_empty() {
                steps.push(JsChainStep::Extract(prefix));
            }
        }
        let js_code = cap
            .get(2)
            .or_else(|| cap.get(1))
            .map(|g| g.as_str())
            .unwrap_or("");
        steps.push(JsChainStep::Js(js_code));
        start = m.end();
    }
    if start == 0 {
        // 无 JS 段：整串作为提取
        steps.push(JsChainStep::Extract(rule));
    } else if start < rule.len() {
        let suffix = rule[start..].trim();
        if !suffix.is_empty() {
            steps.push(JsChainStep::Extract(suffix));
        }
    }
    steps
}

/// `##` 替换规格（对齐 SourceRule.makeUpRule 中 `rule.split("##")`）
#[derive(Debug, Clone)]
struct HashReplaceSpec {
    pattern: String,
    replacement: String,
    replace_first: bool,
}

fn split_hash_replace(rule: &str) -> (String, Option<HashReplaceSpec>) {
    // 避免拆开 URL 中的 ##；仅当 ## 后看起来像正则/替换时拆分
    // 原版无条件直接 split；书源 `$.x##regex` 极常见。
    if !rule.contains("##") {
        return (rule.to_string(), None);
    }
    // 保护：纯 `@js:` / `<js>` 整段内可能含 ##，若整串以 js 开头则不拆
    let trimmed = rule.trim_start();
    if trimmed.starts_with("@js:") || trimmed.starts_with("<js>") {
        return (rule.to_string(), None);
    }
    let parts: Vec<&str> = rule.splitn(4, "##").collect();
    let core = parts[0].to_string();
    if parts.len() == 1 {
        return (core, None);
    }
    let pattern = parts.get(1).unwrap_or(&"").to_string();
    let mut replacement = parts.get(2).unwrap_or(&"").to_string();
    let mut replace_first = false;
    if parts.len() > 3 {
        // ### → replaceFirst（原版：第三段后还有内容或以 ### 标记）
        replace_first = true;
        if replacement.ends_with('#') {
            replacement.pop();
        }
    } else if parts.len() == 2 {
        // `##regex###` 写法：第二段以 ### 结尾
        if let Some(stripped) = pattern.strip_suffix("###") {
            return (
                core,
                Some(HashReplaceSpec {
                    pattern: stripped.to_string(),
                    replacement: String::new(),
                    replace_first: true,
                }),
            );
        }
    }
    (
        core,
        Some(HashReplaceSpec {
            pattern,
            replacement,
            replace_first,
        }),
    )
}

fn apply_hash_replace(input: &str, spec: &HashReplaceSpec) -> String {
    if spec.pattern.is_empty() {
        return input.to_string();
    }
    let Ok(re) = regex::Regex::new(&spec.pattern) else {
        return input.to_string();
    };
    if spec.replace_first {
        re.replace(input, spec.replacement.as_str()).into_owned()
    } else {
        re.replace_all(input, spec.replacement.as_str())
            .into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_rule_type() {
        assert_eq!(AnalyzeRule::detect_rule_type("@css:div"), RuleType::Css);
        assert_eq!(
            AnalyzeRule::detect_rule_type("@xpath://div"),
            RuleType::Xpath
        );
        assert_eq!(
            AnalyzeRule::detect_rule_type("@json:$.name"),
            RuleType::Json
        );
        assert_eq!(
            AnalyzeRule::detect_rule_type("@regex:\\d+"),
            RuleType::Regex
        );
        assert_eq!(AnalyzeRule::detect_rule_type("$.store"), RuleType::Json);
        assert_eq!(AnalyzeRule::detect_rule_type("//div"), RuleType::Xpath);
        assert_eq!(AnalyzeRule::detect_rule_type("div.content"), RuleType::Css);
    }

    #[test]
    fn test_detect_content_type() {
        assert_eq!(
            AnalyzeRule::detect_content_type(r#"{"key": "value"}"#),
            RuleType::Json
        );
        assert_eq!(
            AnalyzeRule::detect_content_type("<?xml version='1.0'?><root/>"),
            RuleType::Xpath
        );
        assert_eq!(
            AnalyzeRule::detect_content_type("<html><body>test</body></html>"),
            RuleType::Css
        );
    }

    #[test]
    fn test_get_strings_json() {
        let rule = AnalyzeRule::new(
            r#"{"name": "test", "items": [1, 2, 3]}"#.to_string(),
            String::new(),
        );
        let result = rule.get_strings("@json:$.name").unwrap();
        assert_eq!(result, vec!["test"]);
    }

    #[test]
    fn test_regex_chain_get_strings() {
        let rule = AnalyzeRule::new("A1B A2B C3D".to_string(), String::new());
        // 多级正则链：先筛 A[0-9]B（只保留 A1B/A2B），再提取 [0-9]+
        let result = rule.get_strings(r"@regex:A[0-9]+B && [0-9]+").unwrap();
        assert_eq!(result, vec!["1", "2"]);
    }

    #[test]
    fn test_at_at_prefix_forces_css() {
        // G7：@@ 前缀剥 2 字符 + 强制 CSS
        let rule = AnalyzeRule::new(
            r#"<span class="item">test</span>"#.to_string(),
            String::new(),
        );
        let result = rule.get_strings("@@.item").unwrap();
        assert_eq!(result, vec!["test"]);
    }

    #[test]
    fn test_all_in_one_regex_colon_prefix() {
        // G10：: 前缀 allInOne 正则（getElements 路径）
        let rule = AnalyzeRule::new("a1b a2b c3d".to_string(), String::new());
        let result = rule.get_elements(":a[0-9]b").unwrap();
        assert_eq!(result, vec!["a1b", "a2b"]);
    }

    #[test]
    fn test_g8_all_in_one_group_refs() {
        // 书书小说：chapterList allInOne + chapterName=$2 + chapterUrl=$1##章节目录
        let html = r#"<dl><dd><a href="/read/12.html">第一章 开端</a></dd><dd><a href="/read/13.html">章节目录</a></dd></dl>"#;
        let rule = AnalyzeRule::new(html.to_string(), "http://www.shushun.cc".to_string());
        let elems = rule
            .get_elements(r#":<dd><a href="([^"]*)[^>]*>([^<]*)"#)
            .unwrap();
        assert_eq!(elems.len(), 2, "应匹配两章: {elems:?}");
        let mut item = AnalyzeRule::new(elems[0].clone(), "http://www.shushun.cc".to_string());
        item.set_element_content(elems[0].clone());
        assert_eq!(item.get_string("$2").unwrap(), "第一章 开端");
        assert_eq!(
            item.get_string_ex("$1##章节目录", true, true).unwrap(),
            "http://www.shushun.cc/read/12.html"
        );
        let mut skip = AnalyzeRule::new(elems[1].clone(), "http://www.shushun.cc".to_string());
        skip.set_element_content(elems[1].clone());
        assert_eq!(skip.get_string("$2").unwrap(), "章节目录");
        assert_eq!(
            skip.get_string("$1").unwrap(),
            "/read/13.html"
        );
    }

    #[test]
    fn test_is_url_takes_first_element() {
        // G14：isUrl 多匹配取首元素（对齐 getString0）
        let rule = AnalyzeRule::new(
            r#"<a href="/a">1</a><a href="/b">2</a>"#.to_string(),
            "http://x.com".to_string(),
        );
        let result = rule.get_string_ex("a@href", true, true).unwrap();
        assert_eq!(result, "http://x.com/a");
    }

    #[test]
    fn test_get_string() {
        let rule = AnalyzeRule::new(r#"{"title": "hello world"}"#.to_string(), String::new());
        let result = rule.get_string("@json:$.title").unwrap();
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_auto_detect_json_content() {
        let rule = AnalyzeRule::new(r#"{"name": "auto_detect_test"}"#.to_string(), String::new());
        // 内容是 JSON，规则以 $ 开头 → 自动使用 JsonPath
        let result = rule.get_strings("$.name").unwrap();
        assert_eq!(result, vec!["auto_detect_test"]);
    }

    #[test]
    fn test_inner_rule_replacement() {
        // 内嵌规则用于动态规则组合：规则中的 {$.path} 被替换为 JSON 中的值
        let rule = AnalyzeRule::new(
            r#"{"key": "name", "name": "张三"}"#.to_string(),
            String::new(),
        );
        // {$.key} 被解析后，内嵌规则 $.key 解析为 "name"
        // 替换后规则变为 "name"，作为 JsonPath 解析为 "张三"
        let result = rule.get_string("{$.key}").unwrap();
        assert_eq!(result, "张三");

        // 测试动态路径组合：{prefix}.name 中的 {prefix} 被替换
        let rule2 = AnalyzeRule::new(
            r#"{"idx": "0", "items": ["apple", "banana"]}"#.to_string(),
            String::new(),
        );
        // $.items[{idx}] 中无 {$} 所以不会触发内嵌替换，但 {$idx} 作为独立规则可以工作
        let result2 = rule2.get_string("@json:$.items[0]").unwrap();
        assert_eq!(result2, "apple");
    }

    #[test]
    fn test_get_strings_html() {
        let html = "<div><p class=\"title\">Hello</p><p class=\"body\">World</p></div>";
        let rule = AnalyzeRule::new(html.to_string(), String::new());
        let result = rule.get_strings("@css:p.title").unwrap();
        assert!(!result.is_empty());
        assert_eq!(result[0], "Hello");
    }

    #[test]
    fn test_set_content_caches_type() {
        let mut rule = AnalyzeRule::new(String::new(), String::new());
        assert!(!rule.is_json());

        rule.set_content(r#"{"key": "value"}"#.to_string());
        assert!(rule.is_json());

        rule.set_content("<html><body>test</body></html>".to_string());
        assert!(!rule.is_json());
    }

    #[test]
    fn test_set_content_clears_and_detects() {
        let mut rule = AnalyzeRule::new(r#"{"old": "data"}"#.to_string(), String::new());
        assert!(rule.is_json());

        // 切换到 XML 内容
        rule.set_content("<?xml version=\"1.0\"?><root><item>test</item></root>".to_string());
        assert!(!rule.is_json());
        // 自动检测应使用 XPath；元素节点返回外层标记（对标原版 getElements 语义）
        let result = rule.get_strings("//item").unwrap();
        assert!(!result.is_empty());
        assert_eq!(result[0], "<item>test</item>");
    }

    // --- JsExecutor 测试 ---

    /// Mock JS 执行器，简单返回固定结果
    struct MockJsExecutor {
        result: String,
    }

    impl JsExecutor for MockJsExecutor {
        fn execute_js(&self, _js_code: &str) -> Result<String, String> {
            Ok(self.result.clone())
        }
    }

    /// 记录注入前奏代码的 Mock（验证 result/src/baseUrl/chapter 变量注入）
    struct RecordingJsExecutor {
        executed: std::sync::Mutex<Vec<String>>,
    }

    impl RecordingJsExecutor {
        fn new() -> Self {
            Self {
                executed: std::sync::Mutex::new(Vec::new()),
            }
        }
    }

    impl JsExecutor for RecordingJsExecutor {
        fn execute_js(&self, js_code: &str) -> Result<String, String> {
            self.executed.lock().unwrap().push(js_code.to_string());
            Ok(String::new())
        }
    }

    /// 总是失败的 Mock JS 执行器
    struct FailingJsExecutor;

    impl JsExecutor for FailingJsExecutor {
        fn execute_js(&self, _js_code: &str) -> Result<String, String> {
            Err("模拟执行失败".to_string())
        }
    }

    #[test]
    fn test_js_rule_injects_bindings() {
        // 对齐原版 evalJS bindings：result/src/baseUrl 自动注入，
        // chapter/title/source 由调用方 with_js_binding 补充。
        // [UI-fix 2026-08-10 | Reasonix] 视频/漫画源正文 JS 依赖这些变量
        let executor = Arc::new(RecordingJsExecutor::new());
        let rule = AnalyzeRule::with_js_executor(
            "<html>漫画页</html>".to_string(),
            "https://manga.example.com/chapter/1.html".to_string(),
            executor.clone(),
        )
        .with_js_binding("source", "\"https://manga.example.com\"")
        .with_js_binding("title", "\"第一章\"")
        .with_js_binding("chapter", "{\"title\": \"第一章\"}");
        rule.get_strings("@js:var m = src.match(/漫画/); result").unwrap();
        let recorded = executor.executed.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        let code = &recorded[0];
        assert!(code.contains("globalThis.result = \"<html>漫画页</html>\";"), "result 注入: {code}");
        assert!(code.contains("globalThis.src = \"<html>漫画页</html>\";"), "src 注入: {code}");
        assert!(code.contains("globalThis.baseUrl = \"https://manga.example.com/chapter/1.html\";"), "baseUrl 注入: {code}");
        assert!(code.contains("globalThis.source = \"https://manga.example.com\";"), "source 注入: {code}");
        assert!(code.contains("globalThis.title = \"第一章\";"), "title 注入: {code}");
        assert!(code.contains("globalThis.chapter = {\"title\": \"第一章\"};"), "chapter 注入: {code}");
        assert!(
            code.contains("var d, data, json, list, arr, obj, tmp")
                && code.contains(", all,")
                && code.contains("len,"),
            "应预声明裸赋值变量 all/len（严格模式）: {code}"
        );
    }

    /// 回归：书源常用 `all = ...` 裸赋值，QuickJS 严格模式须预声明
    #[test]
    fn test_js_rule_predeclares_all_for_bare_assignment() {
        let executor = Arc::new(RecordingJsExecutor::new());
        let rule = AnalyzeRule::with_js_executor(
            r#"{"list":[]}"#.to_string(),
            "http://example.com/api.php/provide/vod/".to_string(),
            executor.clone(),
        );
        // 模拟 MacCMS/视频源惯用 `all = JSON.parse(result)`
        rule.get_strings("@js:all = JSON.parse(result); all").unwrap();
        let recorded = executor.executed.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        assert!(
            recorded[0].contains(", all;") || recorded[0].contains(" all,"),
            "prologue 须含 var all: {}",
            recorded[0]
        );
    }

    /// 元素模式下 result 按解析后的 JSON 对象注入（对齐原版 getElements
    /// JSON 模式返回 Map 对象 → 规则 `result.source` 属性访问可用；
    /// 书山 bookUrl `<js>` 规则依赖，字符串注入取不到字段）。
    #[test]
    fn test_set_element_content_injects_result_as_object() {
        let executor = Arc::new(RecordingJsExecutor::new());
        let mut rule = AnalyzeRule::with_js_executor(
            String::new(),
            "https://example.com".to_string(),
            executor.clone(),
        );
        rule.set_element_content(r#"{"source":"番茄小说","book_url":"https://x/1"}"#.to_string());
        rule.get_strings("@js:result.source").unwrap();
        let recorded = executor.executed.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        let code = &recorded[0];
        assert!(
            code.contains(
                r#"globalThis.result = {"book_url":"https://x/1","source":"番茄小说"};"#
            ),
            "元素模式 result 应按解析后的对象注入（键排序后）: {code}"
        );
        // src 仍为原始字符串
        assert!(
            code.contains(r#"globalThis.src = "{\"source\":\"番茄小说\",\"book_url\":\"https://x/1\"}";"#),
            "src 应保持字符串注入: {code}"
        );
    }

    /// 回归：榴莲影视等 `len=java.getElements(...).length` 裸赋值
    #[test]
    fn test_js_rule_predeclares_len_for_bare_assignment() {
        let executor = Arc::new(RecordingJsExecutor::new());
        let rule = AnalyzeRule::with_js_executor(
            "<html></html>".to_string(),
            "https://example.com/vod/".to_string(),
            executor.clone(),
        );
        rule.get_strings("@js:len=3; from='线路'; len").unwrap();
        let recorded = executor.executed.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        assert!(
            recorded[0].contains(", len,") || recorded[0].contains(" len,") || recorded[0].contains(", len;"),
            "prologue 须含 var len: {}",
            recorded[0]
        );
        assert!(
            recorded[0].contains(", jm,") || recorded[0].contains(" jm,") || recorded[0].contains(", jm;"),
            "prologue 须含 var jm: {}",
            recorded[0]
        );
    }

    /// JS 返回 JSON 数组字符串时展开为多元素（对齐 NativeArray）
    #[test]
    fn test_js_rule_expands_json_array_result() {
        let executor = Arc::new(MockJsExecutor {
            result: r#"["书名A","书名B"]"#.to_string(),
        });
        let rule =
            AnalyzeRule::with_js_executor("{}".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:['书名A','书名B']").unwrap();
        assert_eq!(result, vec!["书名A", "书名B"]);
        // getString：多字符串元素按换行连接（AnalyzeRule.get_string）
        assert_eq!(rule.get_string("@js:x").unwrap(), "书名A\n书名B");
        // 单元素字符串数组 → 展开后 getString 得裸书名（非 Array(0x…) / ["书名"]）
        assert_eq!(
            expand_js_json_array_result(vec![r#"["唯一书名"]"#.to_string()]),
            vec!["唯一书名"]
        );
        assert_eq!(
            AnalyzeRule::with_js_executor(
                "{}".into(),
                String::new(),
                Arc::new(MockJsExecutor {
                    result: r#"["唯一书名"]"#.to_string(),
                }),
            )
            .get_string("@js:['唯一书名']")
            .unwrap(),
            "唯一书名"
        );
    }

    /// `<js>…</js>\n$[*]` 不得提前展开数组（否则 JsonPath 失根）
    #[test]
    fn test_js_tag_jsonpath_suffix_keeps_array_for_split() {
        let executor = Arc::new(MockJsExecutor {
            result: r#"[{"title":"第1话"},{"title":"第2话"}]"#.to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            "<html></html>".to_string(),
            String::new(),
            executor,
        );
        let items = rule
            .get_strings("<js>JSON.stringify(d)</js>\n$[*]")
            .unwrap();
        assert_eq!(items.len(), 2);
        assert!(items[0].contains("第1话"));
        assert!(items[1].contains("第2话"));
    }

    #[test]
    fn test_js_rule_without_executor_returns_empty() {
        let rule = AnalyzeRule::new("some content".to_string(), String::new());
        let result = rule.get_strings("@js:result").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_js_rule_with_executor() {
        let executor = Arc::new(MockJsExecutor {
            result: "执行结果".to_string(),
        });
        let rule =
            AnalyzeRule::with_js_executor("some content".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:result").unwrap();
        assert_eq!(result, vec!["执行结果"]);
    }

    #[test]
    fn test_rule_inline_js_substitution() {
        // G11：规则体内 {{js}}（非 $）→ JS 结果拼进规则再求值
        let executor = Arc::new(MockJsExecutor {
            result: ".item".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            r#"<div class="item">正文</div>"#.to_string(),
            String::new(),
            executor,
        );
        let result = rule.get_strings("{{sel()}}").unwrap();
        assert_eq!(result, vec!["正文"]);
    }

    #[test]
    fn test_expand_js_refs_keeps_literal_on_failure() {
        // G11 回归：{{非$}} eval 失败/为空时必须保留原文（书山 ruleBookInfo
        // 的 {{getSecretKey()}} / {{"\n"+"\u200b"}} 依赖 jsLib 或上层再解析，
        // 不能被替换成空串破坏规则）
        let rule = AnalyzeRule::new("content".to_string(), String::new());
        // 无 JS 执行器 → execute_js_rule 返回空 → 保留字面量
        let out = rule.expand_js_refs("abc{{foo()}}def").unwrap();
        assert_eq!(out, "abc{{foo()}}def");
        // {{$...}} JSONPath 内嵌同样原样保留
        let out2 = rule.expand_js_refs("x={{$.book_url##[|]}}&y=1").unwrap();
        assert_eq!(out2, "x={{$.book_url##[|]}}&y=1");
    }

    /// `<js>...</js>\n$[*]` 复合规则：JS 返回 JSON 数组字符串，JSONPath 后缀拆解
    ///
    /// 对齐 51漫画 chapterList（`JSON.stringify(d)` + `$[*]`）：JS 结果
    /// `[{"title":"第1话","url":"/c/1"},...]` 经 `$[*]` 拆为每章一个对象，
    /// 供子规则 `$.title`/`$.url` 二次解析 — Reasonix
    #[test]
    fn test_js_tag_with_jsonpath_suffix() {
        let executor = Arc::new(MockJsExecutor {
            result: r#"[{"title":"第1话","url":"/c/1"},{"title":"第2话","url":"/c/2"}]"#
                .to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            "<html>51漫画目录页</html>".to_string(),
            "https://51acgs.com/comic/1".to_string(),
            executor,
        );
        let result = rule
            .get_strings("<js>JSON.stringify(d)</js>\n$[*]")
            .unwrap();
        assert_eq!(result.len(), 2, "JSONPath $[*] 应拆出 2 个章节对象");
        // 每个元素是对象 JSON 字符串，可继续用 $.title 解析
        let first = &result[0];
        let title_rule = AnalyzeRule::with_js_executor(
            first.clone(),
            String::new(),
            Arc::new(MockJsExecutor {
                result: String::new(),
            }),
        );
        let t = title_rule.get_string("$.title").unwrap();
        assert_eq!(t, "第1话");
    }

    /// `<js>` 无 JSONPath 后缀：保持原语义（直接返回 JS 结果）
    #[test]
    fn test_js_tag_without_suffix() {
        let executor = Arc::new(MockJsExecutor {
            result: "直接结果".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            "x".to_string(),
            String::new(),
            executor,
        );
        let result = rule.get_strings("<js>result</js>").unwrap();
        assert_eq!(result, vec!["直接结果"]);
    }

    #[test]
    fn test_js_rule_with_empty_result() {
        let executor = Arc::new(MockJsExecutor {
            result: String::new(),
        });
        let rule =
            AnalyzeRule::with_js_executor("some content".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:result").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_js_rule_with_failing_executor() {
        let executor = Arc::new(FailingJsExecutor);
        let rule =
            AnalyzeRule::with_js_executor("some content".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:result");
        assert!(result.is_err());
    }

    #[test]
    fn test_set_js_executor() {
        let mut rule = AnalyzeRule::new("some content".to_string(), String::new());
        // 无执行器时返回空
        assert!(rule.get_strings("@js:x").unwrap().is_empty());

        // 设置执行器后正常工作
        let executor = Arc::new(MockJsExecutor {
            result: "injected".to_string(),
        });
        rule.set_js_executor(executor);
        let result = rule.get_strings("@js:x").unwrap();
        assert_eq!(result, vec!["injected"]);
    }

    #[test]
    fn test_parse_put_json_and_apply() {
        let (cleaned, map) = extract_put_rules("$.chapter_name@put:{chapter_id:$.chapter_id}");
        assert_eq!(cleaned, "$.chapter_name");
        assert_eq!(map.get("chapter_id").map(String::as_str), Some("$.chapter_id"));

        let content = r#"{"chapter_name":"第1话","chapter_id":"99"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let step = rule.get_strings_single_step("$.chapter_id").unwrap();
        assert_eq!(step, vec!["99".to_string()], "single_step={step:?}");
        rule.apply_put_map(&map).unwrap();
        assert_eq!(rule.get("chapter_id"), "99", "after apply_put_map");
    }

    /// 神漫画 chapterName：`$.chapter_name@put:{...}` 必须剥离 @put 后 JsonPath 才命中，
    /// 且 chapter_id 写入变量可供后续 `@get:{chapter_id}` 读取
    #[test]
    fn test_strip_put_then_jsonpath() {
        let content = r#"{"chapter_name":"第1话","chapter_id":"99"}"#;
        let rule = AnalyzeRule::new(content.to_string(), "https://m.taomanhua.com/api".into());
        let title = rule
            .get_string("$.chapter_name@put:{chapter_id:$.chapter_id}")
            .unwrap();
        assert_eq!(title, "第1话");
        assert_eq!(strip_put_rules("$.a@put:{k:$.v}"), "$.a");
        assert_eq!(rule.get("chapter_id"), "99");
        assert_eq!(rule.get_string("@get:{chapter_id}").unwrap(), "99");
    }

    /// 详情 init 纯 `@put` + 字段 `@get`（夜寒书库形态）
    #[test]
    fn test_put_init_then_get_fields() {
        let content = r#"{"book_name":"书名A","author":"作者B"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let _ = rule
            .get_string(r#"@put:{n:"$.book_name",a:"$.author"}"#)
            .unwrap();
        assert_eq!(rule.get("n"), "书名A");
        assert_eq!(rule.get("a"), "作者B");
        assert_eq!(rule.get_string("@get:{n}").unwrap(), "书名A");
        assert_eq!(rule.get_string("http:@get:{a}").unwrap(), "http:作者B");
    }

    /// setLocal 优先于 put 变量
    #[test]
    fn test_set_local_overrides_get() {
        let rule = AnalyzeRule::new("{}".into(), String::new());
        rule.put("k", "from_put");
        rule.set_local("k", "from_local");
        assert_eq!(rule.get("k"), "from_local");
    }

    /// setRedirectUrl + isUrl 绝对化
    #[test]
    fn test_set_redirect_url_and_is_url() {
        let mut rule = AnalyzeRule::new(
            r#"{"path":"/ch/1.html"}"#.into(),
            "https://example.com/base/".into(),
        );
        assert_eq!(rule.redirect_url(), "https://example.com/base/");
        rule.set_redirect_url("https://cdn.example.com/");
        assert_eq!(rule.redirect_url(), "https://cdn.example.com/");
        // data: 忽略
        rule.set_redirect_url("data:text/html,hi");
        assert_eq!(rule.redirect_url(), "https://cdn.example.com/");

        let abs = rule.get_string_ex("$.path", true, true).unwrap();
        assert_eq!(abs, "https://cdn.example.com/ch/1.html");

        let list = rule.get_strings_ex("$.path", true).unwrap();
        assert_eq!(list, vec!["https://cdn.example.com/ch/1.html"]);
    }

    /// getString unescape 重载
    #[test]
    fn test_get_string_unescape() {
        let rule = AnalyzeRule::new(
            r#"{"t":"A&amp;B&lt;C&gt;"}"#.into(),
            String::new(),
        );
        let unescaped = rule.get_string_ex("$.t", false, true).unwrap();
        assert_eq!(unescaped, "A&B<C>");
        let raw = rule.get_string_ex("$.t", false, false).unwrap();
        assert_eq!(raw, "A&amp;B&lt;C&gt;");
    }

    /// @webjs 无头近似（注入 executor）
    #[test]
    fn test_webjs_headless() {
        struct EchoHtml;
        impl JsExecutor for EchoHtml {
            fn execute_js(&self, js_code: &str) -> Result<String, String> {
                if js_code.contains("globalThis.html") {
                    Ok("<p>from-webjs</p>".into())
                } else {
                    Err("unexpected".into())
                }
            }
        }
        let rule = AnalyzeRule::with_js_executor(
            "<html><body>x</body></html>".into(),
            "https://example.com".into(),
            std::sync::Arc::new(EchoHtml),
        );
        let out = rule.get_string("@webjs:return html;").unwrap();
        assert_eq!(out, "<p>from-webjs</p>");
    }

    /// 变量导出 / 注入 JSON（章节 variable 列）
    #[test]
    fn test_export_seed_variables_json() {
        let rule = AnalyzeRule::new("{}".into(), String::new());
        rule.put("chapter_id", "42");
        let json = rule.export_variables_json().unwrap();
        let rule2 = AnalyzeRule::new("{}".into(), String::new());
        rule2.seed_variables_json(&json);
        assert_eq!(rule2.get("chapter_id"), "42");
    }

    /// 神漫画 chapterUrl：`$.chapter_id@js:baseUrl+"&chapter_id="+result`
    #[test]
    fn test_jsonpath_then_js_chain() {
        struct EchoAfterBaseUrl;
        impl JsExecutor for EchoAfterBaseUrl {
            fn execute_js(&self, js_code: &str) -> Result<String, String> {
                // 从 prologue 注入的 globalThis 中无法在此读取；
                // Mock：检测链尾 JS 代码形态并拼出期望 URL
                if js_code.contains("baseUrl") && js_code.contains("chapter_id") {
                    // 简化：从 prologue 的 globalThis.result 字面量提取
                    if let Some(pos) = js_code.find("globalThis.result = ") {
                        let rest = &js_code[pos + "globalThis.result = ".len()..];
                        if let Some(end) = rest.find('\n') {
                            let lit = rest[..end].trim().trim_matches('"');
                            return Ok(format!(
                                "https://m.taomanhua.com/api/getcomicinfo_body/?comic_id=1&productname=smh&platformname=wap&chapter_id={lit}"
                            ));
                        }
                    }
                }
                Ok(String::new())
            }
        }
        let content = r#"{"chapter_id":"18465","chapter_name":"第1话"}"#;
        let rule = AnalyzeRule::with_js_executor(
            content.to_string(),
            "https://m.taomanhua.com/api/getcomicinfo_body/?comic_id=1&productname=smh&platformname=wap"
                .into(),
            Arc::new(EchoAfterBaseUrl),
        );
        let url = rule
            .get_string(r#"$.chapter_id@js:baseUrl+"&chapter_id="+result"#)
            .unwrap();
        assert!(
            url.contains("chapter_id=18465"),
            "链式 @js 应拼出 chapter_id，实际={url}"
        );
    }

    /// 词典 showRule `#def`：单 `#` ID 选择器不得被 ## 替换语法误拆
    #[test]
    fn test_dict_show_rule_def_id_selector() {
        let html = r#"<html><body><p id='def'>n. 测试释义</p></body></html>"#;
        let rule = AnalyzeRule::new(html.to_string(), String::new());
        let out = rule.get_string("#def").unwrap();
        assert_eq!(out, "n. 测试释义", "实际: {out:?}");
    }

    /// ## 替换：搜索 kind 等规则
    #[test]
    fn test_hash_replace_after_jsonpath() {
        let content = r#"{"comic_type":"热血Action"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let kind = rule.get_string(r#"$.comic_type##[a-zA-Z]"#).unwrap();
        assert_eq!(kind, "热血", "kind={kind}");
    }

    /// 神漫画 bookUrl：`https://...?comic_id={$.comic_id}&...` 内嵌替换后返回字面 URL
    #[test]
    fn test_url_template_with_inner_jsonpath() {
        let content = r#"{"comic_id":"12345","comic_name":"测试"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let url = rule
            .get_string(
                "https://m.taomanhua.com/api/getcomicinfo_body/?comic_id={$.comic_id}&productname=smh",
            )
            .unwrap();
        assert_eq!(
            url,
            "https://m.taomanhua.com/api/getcomicinfo_body/?comic_id=12345&productname=smh"
        );
        let cover = rule
            .get_string("http://image.mhxk.com/mh/{$.comic_id}.jpg-600x800.webp")
            .unwrap();
        assert_eq!(cover, "http://image.mhxk.com/mh/12345.jpg-600x800.webp");
        // 双花括号 {{$.x}}（丁斐/漫画人）不得残留外层 {}
        let url2 = rule
            .get_string(
                "http://comic.321mh.com/app_api/v5/getcomicinfo_body/?comic_id={{$.comic_id}}&from_page=search",
            )
            .unwrap();
        assert_eq!(
            url2,
            "http://comic.321mh.com/app_api/v5/getcomicinfo_body/?comic_id=12345&from_page=search"
        );
        assert!(!url2.contains("{12345}"), "不得残留花括号: {url2}");
    }

    /// `<js>...</js>\n$[*]` 必须经 get_elements 单步路径拆解，不能被 JS 链拆成
    /// Extract("$[*]") 对 HTML 误解析（51漫画目录回归）。
    #[test]
    fn test_get_elements_js_tag_with_jsonpath_suffix() {
        use crate::JsExecutor;
        use std::sync::Arc;

        struct JsonArrayExec;
        impl JsExecutor for JsonArrayExec {
            fn execute_js(&self, _js_code: &str) -> Result<String, String> {
                Ok(r#"[{"title":"第1话","url":"/ch/1"},{"title":"第2话","url":"/ch/2"}]"#
                    .to_string())
            }
        }

        let rule = concat!(
            "<js>\n",
            "d = [{ title: book.name, url: '/ch/1' }];\n",
            "JSON.stringify(d);\n",
            "</js>\n",
            "$[*]",
        );
        let mut analyzer = AnalyzeRule::new("<html></html>".into(), "https://example.com".into());
        analyzer.set_js_executor(Arc::new(JsonArrayExec));
        analyzer.add_js_binding("book", r#"{"name":"测试书"}"#);
        let els = analyzer.get_elements(rule).expect("get_elements");
        assert_eq!(els.len(), 2, "els={els:?}");
        assert!(els[0].contains("第1话") || els[0].contains("/ch/1"), "{}", els[0]);
    }
}
