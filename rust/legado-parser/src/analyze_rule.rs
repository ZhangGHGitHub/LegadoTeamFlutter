//! AnalyzeRule: 统一规则解析门面
//!
//! 参考 Kotlin `AnalyzeRule.kt`，实现统一调度，根据规则前缀或内容类型
//! 自动选择 HTML(CSS)、XPath、JsonPath、正则 解析引擎。

use std::sync::Arc;

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
    /// 可选的 JS 执行器（通过回调注入模式解决跨 crate 循环依赖）
    js_executor: Option<Arc<dyn JsExecutor>>,
    /// JS 执行时的注入上下文（对齐原版 AnalyzeRule.evalJS bindings：
    /// result/src/baseUrl 自动注入；chapter/title/source 等由调用方补充）
    js_bindings: Vec<(String, String)>,
}

impl AnalyzeRule {
    /// 创建新的规则解析器
    pub fn new(content: String, base_url: String) -> Self {
        let content_type = Self::detect_content_type(&content);
        let is_json = content_type == RuleType::Json;
        Self {
            content,
            base_url,
            html_parser: HtmlParser::new(),
            xpath_parser: XPathParser::new(),
            json_parser: JsonPathParser::new(),
            regex_engine: RegexEngine::new(),
            cached_content_type: Some(content_type),
            is_json,
            js_executor: None,
            js_bindings: Vec::new(),
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
    /// - `@put:{...}` 剥离（对齐原版 `splitPutRule`；神漫画 chapterName 等）
    /// - 前缀/中缀 `extract@js:...` / `extract<js>...</js>` 链式（对齐
    ///   `AnalyzeRule.splitSourceRule` + JS_PATTERN；神漫画 chapterUrl、
    ///   Nhentai 正文 `//script@js:` 等）
    /// - `##regex##replacement` 结果替换（对齐原版 SourceRule.makeUpRule）
    pub fn get_strings(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        // 1) 剥离 @put:{...}（变量写入后续可扩展；先保证主规则可解析）
        let rule_no_put = strip_put_rules(rule);

        // 2) 拆分 ## 替换段（主规则 ## 匹配 ## 替换 / ### 仅首匹配）
        let (core_rule, replace_spec) = split_hash_replace(&rule_no_put);

        // 3) `<js>...</js>`（含 `$[*]` 复合）走单步专用路径，避免被
        //    通用 JS 链拆成 Js+Extract 后丢失 `$[*]` 拆解语义（51漫画）
        //    其余 `extract@js:` 走链式（神漫画 chapterUrl / Nhentai 正文）
        let mut results = if core_rule.trim_start().starts_with("<js>") {
            self.get_strings_single_step(&core_rule)?
        } else {
            let steps = split_js_chain_steps(&core_rule);
            if steps.len() > 1 {
                self.eval_js_chain_steps(&steps)?
            } else {
                self.get_strings_single_step(&core_rule)?
            }
        };

        // 4) 应用 ## 替换
        if let Some(spec) = replace_spec.as_ref() {
            results = results
                .into_iter()
                .map(|s| apply_hash_replace(&s, spec))
                .collect();
        }
        Ok(results)
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
                    let mut out = Vec::new();
                    for item in &js_result {
                        if let Ok(v) = self.json_parser.parse_jsonpath(item, suffix) {
                            out.extend(v);
                        }
                    }
                    return Ok(out);
                }
                return Ok(js_result);
            }
        }

        let (rule_type, actual_rule) = Self::resolve_rule_type(rule);

        match rule_type {
            RuleType::Css => self.html_parser.get_text(&self.content, actual_rule),
            RuleType::Xpath => self.xpath_parser.parse_xpath(&self.content, actual_rule),
            RuleType::Json => self.resolve_json_with_inner(actual_rule),
            RuleType::Regex => self.regex_engine.regex_match(&self.content, actual_rule),
            RuleType::Js => self.execute_js_rule(actual_rule),
            RuleType::Auto => {
                let detected = self.detect_rule_type_for_content(actual_rule);
                match detected {
                    RuleType::Json => self.resolve_json_with_inner(actual_rule),
                    RuleType::Xpath => self.xpath_parser.parse_xpath(&self.content, actual_rule),
                    RuleType::Regex => self.regex_engine.regex_match(&self.content, actual_rule),
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
                    if let Some(exec) = self.js_executor() {
                        sub.set_js_executor(exec);
                    }
                    for (n, v) in &self.js_bindings {
                        sub.add_js_binding(n, v);
                    }
                    let out = sub.execute_js_rule(code)?;
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
    pub fn get_string(&self, rule: &str) -> LegadoResult<String> {
        let strings = self.get_strings(rule)?;
        if strings.is_empty() {
            return Ok(String::new());
        }
        if strings.len() == 1 {
            return Ok(strings.into_iter().next().unwrap());
        }
        Ok(strings.join("\n"))
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

        let rule_no_put = strip_put_rules(rule);
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

    /// 正则匹配获取捕获组
    pub fn regex_match_groups(&self, pattern: &str) -> LegadoResult<Vec<Vec<String>>> {
        self.regex_engine.regex_match_groups(&self.content, pattern)
    }

    /// 多级正则匹配
    pub fn regex_chain(&self, patterns: &[&str]) -> LegadoResult<Option<Vec<String>>> {
        self.regex_engine.regex_chain_match(&self.content, patterns)
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
            prologue.push_str(
                "var d, data, json, list, arr, obj, tmp, index, num, comic_chapter, header, headers, chapter_domain, end_num, rule, pic, html, img_ext;\n",
            );
            if let Ok(content_json) = serde_json::to_string(&self.content) {
                // 经 globalThis 属性赋值注入（对齐原版 ScriptableObject.put
                // 语义）：① 不能裸赋值 `result = ...`——QuickJS eval 处于
                // 严格模式，未声明变量赋值抛 ReferenceError（实测
                // "result is not defined"）；② 不能用 `var result = ...`——
                // 书源 jsLib 若已声明 let/const result，var 同名声明抛
                // SyntaxError（redeclaration）。globalThis 属性赋值两者
                // 皆可：严格模式合法、不构成重复声明 — Reasonix
                prologue.push_str(&format!("globalThis.result = {content_json};\n"));
                prologue.push_str(&format!("globalThis.src = {content_json};\n"));
            }
            if let Ok(base_json) = serde_json::to_string(&self.base_url) {
                prologue.push_str(&format!("globalThis.baseUrl = {base_json};\n"));
            }
            for (name, value) in &self.js_bindings {
                // json_literal 已是合法 JSON 字面量，globalThis 属性赋值注入
                prologue.push_str(&format!("globalThis.{name} = {value};\n"));
            }
            let wrapped = format!("{prologue}{js_code}");
            match executor.execute_js(&wrapped) {
                Ok(result) => {
                    if result.is_empty() {
                        Ok(vec![])
                    } else {
                        Ok(vec![result])
                    }
                }
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

    /// 解析 JsonPath 规则，支持 `{$.rule}` 内嵌规则替换
    ///
    /// 神漫画 bookUrl/coverUrl：
    /// `https://...?comic_id={$.comic_id}&...` — 内嵌替换后得到完整 URL，
    /// **不得再当 JsonPath 求值**（否则空串 → 回退书源主页 → 目录失败）。
    fn resolve_json_with_inner(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.contains("{$") {
            let processed = self.process_inner_rules(rule)?;
            let trimmed = processed.trim_start();
            if !trimmed.starts_with('$') && !trimmed.is_empty() {
                return Ok(vec![processed]);
            }
            if trimmed.is_empty() {
                return Ok(vec![]);
            }
            return self.json_parser.parse_jsonpath(&self.content, &processed);
        }
        self.json_parser.parse_jsonpath(&self.content, rule)
    }

    /// 处理规则中的 `{$.rule}` 内嵌表达式
    ///
    /// 将 `{$.some.path}` 替换为其在当前内容上的解析结果
    fn process_inner_rules(&self, rule: &str) -> LegadoResult<String> {
        if !rule.contains("{$") {
            return Ok(rule.to_string());
        }

        let mut analyzer = RuleAnalyzer::new(rule, true);
        let result = analyzer.inner_rule("{$", 1, 1, |inner_rule| {
            // 递归解析内嵌规则
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
            // inner_rule 返回空表示没有成功替换任何内嵌规则
            Ok(rule.to_string())
        } else {
            Ok(result)
        }
    }

    /// 解析规则前缀，返回 (规则类型, 去掉前缀后的规则)
    fn resolve_rule_type(rule: &str) -> (RuleType, &str) {
        let (prefix, actual_rule) = RuleAnalyzer::parse_rule_prefix(rule);
        let rule_type = match prefix {
            "css" => RuleType::Css,
            "xpath" => RuleType::Xpath,
            "json" => RuleType::Json,
            "regex" => RuleType::Regex,
            "js" => RuleType::Js,
            _ => RuleType::Auto,
        };
        (rule_type, actual_rule)
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
        if self.is_json {
            // 内容是 JSON，规则看起来不像 CSS 时，使用 JsonPath
            // （以标签名/类名/ID 选择器开头的规则仍按 CSS 处理，
            // 避免 `span.user@text` 等 CSS 规则被误路由到 JsonPath）
            if !rule.contains('<') && !rule.contains('>') && !Self::looks_like_css_selector(rule)
            {
                return RuleType::Json;
            }
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

/// JS 链步骤（对齐原版 `splitSourceRule` + `JS_PATTERN`）
enum JsChainStep<'a> {
    Extract(&'a str),
    Js(&'a str),
}

/// 剥离 `@put:{...}`（对齐 `splitPutRule` / `putPattern`）
///
/// 神漫画 `$.chapter_name@put:{chapter_id:$.chapter_id}` 若不剥离，
/// JsonPath 整串失败 → 章名空 → get_chapters 跳过 → 目录为空。
fn strip_put_rules(rule: &str) -> String {
    // (?i)@put:(\{[^}]+?\})
    let re = regex::Regex::new(r"(?i)@put:(\{[^}]+?\})").unwrap();
    re.replace_all(rule, "").into_owned()
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

    /// 神漫画 chapterName：`$.chapter_name@put:{...}` 必须剥离 @put 后 JsonPath 才命中
    #[test]
    fn test_strip_put_then_jsonpath() {
        let content = r#"{"chapter_name":"第1话","chapter_id":"99"}"#;
        let rule = AnalyzeRule::new(content.to_string(), "https://m.taomanhua.com/api".into());
        let title = rule
            .get_string("$.chapter_name@put:{chapter_id:$.chapter_id}")
            .unwrap();
        assert_eq!(title, "第1话");
        assert_eq!(strip_put_rules("$.a@put:{k:$.v}"), "$.a");
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
    }
}
