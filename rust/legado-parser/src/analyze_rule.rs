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

// ─── P2-9 ③：全局变量兜底读取器（进程级）──────────────────────────────────────
/// 全局变量兜底读取器（进程级，由 FFI 层注册，指向 `legado-js` 的
/// `host_api::variable_store` 全局 store）。
///
/// P2-9 ③：JS 宿主 `java.put`/`java.get` 读写的是**进程级全局**变量表
/// （`legado_js::host_api::variable_store`），而规则 `@get:{k}` 读的是
/// **analyzer 本地**变量（`AnalyzeRule::variables`）——两者此前无桥，导致
/// 「JS 写变量、规则 `@get` 读」的书源（小米阅读 / 就去看网 / 手机小说等）
/// `@get` 恒空（如 手机小说 `tocUrl` 回退 book_url → 错目录页）。
///
/// 设计：legado-parser 不能依赖 legado-js（循环依赖），故以 FFI 层注入的
/// 进程级读取器桥接。[`AnalyzeRule::get`] 在**本地查找（localBindings →
/// bookName/title 特例 → variables）全部失败后**才兜底读本读取器——不改动
/// 既有优先级，全局 store 仅作最后兜底（作用域语义取舍见交付报告 ③）。
///
/// 用 `Mutex<Option<...>>`（而非 `OnceLock`）以便测试注入/复位；生产由
/// FFI 层注册一次（幂等，最后一次为准）。
///
/// 读取器闭包类型（命中返回 `Some(value)`、未命中 `None`）抽出为别名，
/// 避免 `Arc<dyn Fn(...) + Send + Sync>` 在静态与函数签名两处触发
/// clippy::type_complexity。
pub type GlobalVariableReader = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

static GLOBAL_VAR_FALLBACK: Mutex<Option<GlobalVariableReader>> = Mutex::new(None);

/// 注册（或替换）全局变量兜底读取器；传 `None` 复位（测试用）。
///
/// 读取器签名 `Fn(&str) -> Option<String>`：命中返回 `Some(value)`，未命中返回
/// `None`（与既有优先级一致，空值在 `get` 内仍按「未命中」处理）。
pub fn set_global_variable_reader(reader: Option<GlobalVariableReader>) {
    if let Ok(mut guard) = GLOBAL_VAR_FALLBACK.lock() {
        *guard = reader;
    }
}

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
        // P2-9 ③：全局 store 兜底（最后 resort）——本地 localBindings /
        // bookName·title 特例 / variables 全部未命中（或本地值为空）后，才读
        // 进程级全局 store（JS `java.put` 写入处）。不改动既有优先级：全局
        // store 是最低优先级兜底，本地有非空值时永不落到此。
        if let Ok(guard) = GLOBAL_VAR_FALLBACK.lock() {
            if let Some(reader) = guard.as_ref() {
                if let Some(v) = reader(key) {
                    return v;
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
        let rule_after_get = if compiled.has_get_marker {
            self.expand_get_refs(&compiled.rule_no_put)
        } else {
            compiled.rule_no_put.clone()
        };
        // [A | 台账 0917] 模板形态判定基于「@get 展开后、JS 展开前」的规则：
        // JS 展开会把 `{{js}}` 参数替换掉，事后判定会漏掉已展开的模板规则。
        // 命中时单步路径在参数回填后按字面返回（上游 Mode.Regex → else -> rule），
        // 不再当选择器解析（拼好的 URL 被 CSS 解析 → 空）。
        // [P0-1 | 台账 0917] 含 JS 段（`@js:` / `<js>`，大小写不敏感）的规则
        // 永不进模板分支：JS 段代码内可合法出现 `{{…}}` 字符串字面量（书旗/
        // 米读/红薯等 52 规则），进模板分支会被参数回填 + 整段字面返回，
        // JS 不再执行（字段值变成 JS 源码）。`@js:` 与 `<js>` 经
        // rule_has_js_chain 同等对待（`<js>` 前缀虽已受 split_hash_replace
        // 保护，判定仍统一走 JS 链门）。
        // [P0-2 | 台账 0917] 判定域为**顶层拆分后的提取核心**
        // （split_hash_replace 跳过 `{{…}}` 跨度内的 `##`）：「选择器 + 跨度外
        // ## 替换（替换段含 `{{`）」（`.content@p@html##…{{book.name}}…`，21
        // 规则）按核心 `{{` 判定为否 → 走单步 + ## 替换（回填在展开期完成），
        // 而不是在未拆分整规则上误判为模板 → 整段当选择器 → 只返回规则文本。
        let template_shape = if rule_has_js_chain(&rule_after_get) {
            false
        } else {
            let (core_for_shape, spec_for_shape) = split_hash_replace(&rule_after_get);
            (core_for_shape.contains("{{") && single_step_template_literal(&core_for_shape))
            // [P1-A | 台账 0917] core 含 `{{` 且存在顶层 `##` 替换规格、且首个
            // 跨度位于 0 位（前无包装文字；`{{baseUrl}}` 这类单跨度 JS 表达式
            // 参数会被 single_step_template_literal 判否）→ 判为模板（上游首个
            // match 位于段首 → Mode.Regex，回填后按字面返回并应用 ## 替换）。
            // 不影响 G11/P1-4（`{{sel()}}.item`/`||`/`%%` 无顶层 ## → spec None）
            // 与 P0-2（`.content@p@html##…{{book.name}}…` 的 core 不含 `{{`）。
            || spec_for_shape.is_some()
                && double_brace_spans(core_for_shape.trim())
                    .first()
                    .is_some_and(|&(s, _)| s == 0)
        };
        // 2.5) 展开规则体内 `{{js}}`（非 $）内嵌 JS
        // [A | 台账 0917] 多步 JS 链只展开 **JS 段代码内** 的 `{{js}}`
        // （G11 语义、顶层绑定）；Extract 段的 `{{…}}` 原样保留，交由
        // eval_js_chain_steps 逐段按模板求值（参数相对前序步结果回填——
        // 正确绑定）。若此处整体展开，Extract 段 `{{result}}` 会被顶层
        // 内容（如元素 JSON）替换，拼出的 URL 错。
        let rule_expanded = if rule_after_get.contains("{{") && rule_has_js_chain(&rule_after_get) {
            self.expand_js_refs_in_js_segments(&rule_after_get)?
        } else if template_shape {
            // [P2-6d | 台账 0917] 模板命中：参数回填统一由
            // eval_template_segment（eval_template_param）完成；顶层
            // expand_js_refs 会对同一 JS 表达式参数**再执行一次**（此前
            // `{{js}}后缀` 规则 JS 被调 2 次）。G11 例外（整规则恰为单个
            // JS 表达式跨度、无包装）template_shape 判否，仍走下方展开
            // 路径，语义不变。
            rule_after_get.clone()
        } else {
            self.expand_js_refs(&rule_after_get)?
        };
        // G8：allInOne 正则 getElements 把捕获组编成 JSON 字符串数组；
        // 子规则 `$1`/`$2` 对齐 SourceRule.makeUpRule（result 为 List）回填，
        // 然后走 Mode.Regex 的 `else -> rule`（字面结果 + ## 替换）。
        if let Some(groups) = parse_regex_group_list(&self.content) {
            if rule_has_group_ref(&rule_expanded) {
                let assembled = makeup_group_refs(&rule_expanded, &groups);
                let (core, spec) = split_hash_replace(&assembled);
                let mut results = if core.is_empty() { vec![] } else { vec![core] };
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

        // 4) `<js>...</js>`（含 `$[*]` 复合，≤2 步）走单步专用路径，避免被
        //    通用 JS 链拆成 Js+Extract 后丢失 `$[*]` 拆解语义（51漫画）。
        //    ≥3 步（JS+提取+JS 交错）走链式逐步执行；其余 `extract@js:`
        //    同样走链式（神漫画 chapterUrl / Nhentai 正文）
        let mut results = if core_rule.trim_start().starts_with("<js>") && js_steps_owned.len() <= 2
        {
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
        } else if template_shape {
            // [A | 台账 0917] 单步模板：参数回填后按字面返回
            // （上游 makeUpRule 回填 → Mode.Regex → else -> rule）
            let literal = self.eval_template_segment(&core_rule, &self.content)?;
            if literal.trim().is_empty() {
                Vec::new()
            } else {
                vec![literal]
            }
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
                let json_suffix = suffix
                    .strip_prefix("@json:")
                    .or_else(|| suffix.strip_prefix("@JSON:"))
                    .unwrap_or(suffix);
                if json_suffix.starts_with("$") && !json_suffix.is_empty() {
                    // JS 结果为单元素（JSON/JSONP 解包字符串）或多元素，逐一按
                    // JSONPath 求值。必须兼容 `</js>\n@json:$..bookinfo[*]`
                    // （红薯小说 JSONP）以及既有 `</js>\n$[*]`（51漫画）。
                    let mut out = Vec::new();
                    for item in &js_result {
                        if let Ok(v) = self.json_parser.parse_jsonpath(item, json_suffix) {
                            out.extend(v);
                        }
                    }
                    return Ok(out);
                } else if !suffix.is_empty() {
                    // 非 JSONPath 后缀（CSS/XPath 等）：对齐原版 splitSourceRule
                    // 拆成 Js + Extract 两步——提取规则作用于 JS 输出。
                    // 包子漫画（优）chapterList `<js>java.t2s(result)</js>\n
                    // class.xxx comics-chapters`：JS 转简体后 CSS 选章节锚点；
                    // 此前此分支缺失 → 后缀被丢弃 → 整页 HTML 作为唯一「章节」。
                    let content = if js_result.len() == 1 {
                        js_result.into_iter().next().unwrap_or_default()
                    } else {
                        js_result.join("\n")
                    };
                    let mut sub = AnalyzeRule::new(content, self.base_url.clone());
                    self.share_variable_store_into(&mut sub);
                    if let Some(exec) = self.js_executor() {
                        sub.set_js_executor(exec);
                    }
                    for (n, v) in &self.js_bindings {
                        sub.add_js_binding(n, v);
                    }
                    return sub.get_strings_single_step(suffix);
                }
                // 无后缀：若 JS 返回 JSON 数组，展开为多元素
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
                    // [A | 台账 0917] 模板段（含 `{{…}}` / `@get:`）：按模板求值——
                    // 参数相对前序步结果（current_content）回填后整段是字面量
                    // （上游 Mode.Regex → else -> rule），不再当选择器解析；
                    // `##` 拆分在回填之后（eval_template_segment 内完成）。
                    // 此前选择器解析拼好的 URL（松鹤 bookUrl 尾段）→ 空 → 全链空。
                    // [P0-1 | 台账 0917] 含 JS 段（`@js:`/`<js>`，跨度内字面量
                    // 除外，P2-6f4；正常拆分下不会出现在 Extract 段，此处防御）
                    // 永不进模板分支。
                    // [P2-6f1 | 台账 0917] 判定域为**顶层拆分后的提取核心**
                    // （split_hash_replace 跳过 `{{…}}` 跨度内的 `##`），与
                    // get_strings_ex 单步判定（P0-2）统一：整段带 `##` 的段
                    // （`{{a}}##re##rep`）按核心 `{{a}}` 判定，顶层 `##` 规格
                    // 由 eval_template_segment 在回填后统一应用。
                    // [P2-6c | 台账 0917] 单跨度 JS 表达式参数带非空后缀/组合符
                    // （`.item`/`||`/`%%`）进模板分支（上游 Mode.Regex 字面返回），
                    // 仅整规则无包装的单跨度（G11 例外）保留展开路径。
                    let (core_for_template, _spec_for_template) = split_hash_replace(rule);
                    if (core_for_template.contains("{{")
                        && !rule_has_js_chain(rule)
                        && single_step_template_literal(&core_for_template))
                        || rule.to_ascii_lowercase().contains("@get:")
                    {
                        current_content = self.eval_template_segment(rule, &current_content)?;
                        last_is_js = false;
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

    /// [A | 台账 0917] 模板段求值（链式 Extract 步 / 单步模板字面量）：
    /// 逐个 `{{param}}` 回填——规则型参数（上游 isRule：`@`/`$.`/`$[`/`//`）
    /// 相对 `content`（链式：前序步结果；单步：当前内容）做单源规则回填，
    /// JS 表达式参数以 `content` 为 result 执行 JS；回填失败/为空 → 该参数
    /// 变空串（上游 makeUpRule `null -> Unit`）。`##` 拆分在回填**之后**
    /// （上游 makeUpRule 顺序；`{{…}}` 内层的 `##` 属于参数内层规则）。
    fn eval_template_segment(&self, rule: &str, content: &str) -> LegadoResult<String> {
        // @get:{k} 通常已由 get_strings_ex 展开，此处兜底
        let rule = self.expand_get_refs(rule);
        let mut out = String::with_capacity(rule.len());
        let mut i = 0usize;
        let bytes = rule.as_bytes();
        while i < bytes.len() {
            if bytes[i] == b'{' && bytes.get(i + 1) == Some(&b'{') {
                if let Some(full_len) = Self::find_double_brace_end(&rule[i..]) {
                    let inner = &rule[i + 2..i + full_len - 2];
                    out.push_str(&self.eval_template_param(inner, content));
                    i += full_len;
                    continue;
                }
            }
            let ch = rule[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
        // [P2-2 | 台账 0917] 单花括号 `{$.x}` 内嵌（与 process_inner_rules
        // 一致）：`https://x/{{$.a}}/{$.b}` 混合模板的单花括号部分须经
        // JSONPath 回填，否则残留字面量（`AA/{$.b}`）。双花括号已在上方
        // 回填，此处只处理 `{$`（process_inner_rules 内部对 `{{$` 幂等）。
        let out = if out.contains("{$") {
            let mut sub = AnalyzeRule::new(content.to_string(), self.base_url.clone());
            self.share_variable_store_into(&mut sub);
            if let Some(exec) = self.js_executor() {
                sub.set_js_executor(exec);
            }
            for (n, v) in &self.js_bindings {
                sub.add_js_binding(n, v);
            }
            sub.process_inner_rules(&out)?
        } else {
            out
        };
        // ## 拆分在回填之后（上游 makeUpRule 顺序）
        let (core, spec) = split_hash_replace(&out);
        Ok(spec.map(|s| apply_hash_replace(&core, &s)).unwrap_or(core))
    }

    /// 单个 `{{param}}` 回填（见 [`Self::eval_template_segment`]）
    fn eval_template_param(&self, expr: &str, content: &str) -> String {
        let expr = expr.trim();
        if expr.is_empty() {
            return String::new();
        }
        if template_param_is_rule(expr) {
            // [B | 台账 0917] 内层 `##` 属于参数内层规则
            // （上游单源规则 splitRegex 对参数串拆分）
            let (core, spec) = split_hash_replace(expr);
            let mut sub = AnalyzeRule::new(content.to_string(), self.base_url.clone());
            self.share_variable_store_into(&mut sub);
            if let Some(exec) = self.js_executor() {
                sub.set_js_executor(exec);
            }
            for (n, v) in &self.js_bindings {
                sub.add_js_binding(n, v);
            }
            let vals = sub.get_strings_single_step(&core).unwrap_or_default();
            let val = if vals.is_empty() {
                String::new()
            } else if vals.len() == 1 {
                vals.into_iter().next().unwrap()
            } else {
                vals.join("\n")
            };
            return spec.map(|s| apply_hash_replace(&val, &s)).unwrap_or(val);
        }
        // JS 表达式参数：以 content（前序步结果 / 当前内容）为 result 执行
        let mut sub = AnalyzeRule::new(content.to_string(), self.base_url.clone());
        self.share_variable_store_into(&mut sub);
        if let Some(exec) = self.js_executor() {
            sub.set_js_executor(exec);
        }
        for (n, v) in &self.js_bindings {
            sub.add_js_binding(n, v);
        }
        match sub.execute_js_rule(expr) {
            Ok(vals) if !vals.is_empty() => {
                if vals.len() == 1 {
                    vals.into_iter().next().unwrap()
                } else {
                    vals.join("\n")
                }
            }
            // 上游 null -> Unit：失败/为空 → 参数为空串
            _ => String::new(),
        }
    }

    /// 根据规则获取单个字符串（多个结果用换行连接）
    ///
    /// 默认 `unescape=true`（对齐原版 `getString` 默认重载）。
    /// 批量字段提取（搜索列表逐元素字段）：纯 CSS 规则共享一次 HTML 解析，
    /// 其余规则走原单规则路径。语义与逐个调用 `get_string` 完全一致，仅避免
    /// 同一内容被重复全量 parse（原版 AnalyzeByJSoup 对 Element 对象不重复
    /// parse；此前 100 条 × ~7 字段 ≈ 700 次解析 → yeudusk 35s 触发 30s 超时）。
    /// — 2026-08-18 搜索速度修复
    pub fn get_strings_batch(&self, rules: Vec<&str>) -> Vec<LegadoResult<String>> {
        let mut results: Vec<Option<LegadoResult<String>>> =
            (0..rules.len()).map(|_| None).collect();
        let mut css: Vec<(usize, String)> = Vec::new();

        for (i, rule) in rules.iter().enumerate() {
            if rule.is_empty() {
                continue;
            }
            if let Some(actual) = self.batchable_css_rule(rule) {
                css.push((i, actual));
            } else {
                results[i] = Some(self.get_string(rule));
            }
        }

        if !css.is_empty() {
            let refs: Vec<&str> = css.iter().map(|(_, a)| a.as_str()).collect();
            let batch = self.html_parser.get_multi(&self.content, &refs);
            for ((idx, _), res) in css.iter().zip(batch) {
                results[*idx] = Some(res.map(Self::css_vec_to_string));
            }
        }

        results
            .into_iter()
            .map(|r| r.unwrap_or_else(|| Ok(String::new())))
            .collect()
    }

    /// 判断规则能否并入 CSS 批量路径：须为纯 CSS 提取（无变量/替换/JS 链等
    /// 特殊语法），且解析后落到 CSS 分支。返回实际选择器（剥前缀后）。
    fn batchable_css_rule(&self, rule: &str) -> Option<String> {
        if rule.contains("@put:")
            || rule.contains("@get:")
            || rule.contains("##")
            || rule.contains("<js>")
            || rule.contains("@js:")
            || rule.contains("extract@js")
            || rule.contains("@webjs:")
            // [A | 台账 0917] `{{…}}` 模板规则按字面回填，不是 CSS 选择器
            || rule.contains("{{")
        {
            return None;
        }
        let (rule_type, actual) = Self::resolve_rule_type(rule);
        match rule_type {
            RuleType::Css => Some(actual.to_string()),
            RuleType::Auto if self.detect_rule_type_for_content(actual) == RuleType::Css => {
                Some(actual.to_string())
            }
            _ => None,
        }
    }

    /// CSS 选择结果 Vec→String（对齐 `get_string_ex(rule, is_url=false, unescape=true)`）：
    /// 单值取首元素、多值 `\n` 连接、含 `&` 时 HTML4 实体反转义。
    fn css_vec_to_string(v: Vec<String>) -> String {
        let mut result = if v.is_empty() {
            String::new()
        } else if v.len() == 1 {
            v.into_iter().next().unwrap()
        } else {
            v.join("\n")
        };
        if result.contains('&') {
            result = legado_core::html_formatter::unescape_html4(&result);
        }
        result
    }

    pub fn get_string(&self, rule: &str) -> LegadoResult<String> {
        self.get_string_ex(rule, false, true)
    }

    /// 获取单个字符串（对齐原版 `getString(rule, unescape)` / `getString(..., isUrl)`）
    ///
    /// - `unescape`：含 `&` 时做 HTML4 实体反转义
    /// - `is_url`：结果绝对化；空结果回退 `base_url`
    pub fn get_string_ex(&self, rule: &str, is_url: bool, unescape: bool) -> LegadoResult<String> {
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
        // 与 get_strings 对齐：`<js>...</js>`（含 `\n$[*]` 复合后缀，≤2 步）
        // 必须走单步路径。若先 split_js_chain_steps，会把 `$[*]` 拆成独立
        // Extract，对整页 HTML 做 JSONPath →「JSON parse error」；再被
        // web_book `get_elements(...).unwrap_or_default()` 吞成 0 章 →
        // 「暂无章节」（51漫画 chapterList 2026-08-11 复现：站点已无「目录」
        // 脚本，走 btn-read 回退本可出 1 章，却因链拆解整链失败）。— Reasonix
        // ≥3 步（JS+提取+JS 交错）落入下方通用链式逐步执行。
        let starts_js_tag = rule_no_put.trim_start().starts_with("<js>");
        let steps = split_js_chain_steps(&rule_no_put);
        if starts_js_tag && steps.len() <= 2 {
            return self.get_elements_single_step(&rule_no_put);
        }
        if steps.len() > 1 {
            // 链式 getElements：首段按元素规则提取，后续 JS 以拼接/单元素为 result
            let mut elems: Vec<String> = Vec::new();
            let mut pending_js: Vec<&str> = Vec::new();
            // [P2-6a | 台账 0917] 链内模板段状态（get_strings 路径模板语义
            // 移植到 getElements 链）：
            // - template_ctx：下一模板段的回填内容（= 前序步结果；初始为
            //   规则当前内容，或刚 flush 的 JS 步输出）；
            // - js_continuation：最近一次模板段产出的 JS 可执行字面结果——
            //   其后 JS 步以前序结果（而非元素列表）为 payload。
            let mut template_ctx = self.content.clone();
            let mut js_continuation: Option<String> = None;
            for step in &steps {
                match step {
                    JsChainStep::Extract(r) => {
                        let r = r.trim();
                        if r.is_empty() {
                            continue;
                        }
                        // [P2-6a | 台账 0917] 链内模板段（与 eval_js_chain_steps
                        // P0-2/P2-6f1 判定一致：判定域 = 顶层拆分后提取核心，
                        // 含 `{{`/`@get:`）：
                        // - 规则型参数（isRule 前缀）相对 template_ctx 单源规则回填；
                        // - JS 表达式参数以 template_ctx（前序步结果）为 result 执行；
                        // - 回填后整段字面（上游 Mode.Regex → else -> rule），
                        //   其结果作为后续段前序结果；
                        // - 含 `@js:`/`<js>`（P2-6f4 跨度感知判定）不进模板分支
                        //   （P0-1）；
                        // - 顶层 `##` 规格由 eval_template_segment 在回填后应用；
                        // - 本段前累积的 JS 步先按批次语义 flush（payload = 前序
                        //   结果/元素列表），模板段回填基准才是 JS 输出。
                        let (core_r, _spec_r) = split_hash_replace(r);
                        let is_template_seg = (core_r.contains("{{")
                            && !rule_has_js_chain(r)
                            && single_step_template_literal(&core_r))
                            || r.to_ascii_lowercase().contains("@get:");
                        if is_template_seg {
                            if !pending_js.is_empty() {
                                let payload = js_continuation.take().unwrap_or_else(|| {
                                    if elems.len() == 1 {
                                        elems[0].clone()
                                    } else {
                                        serde_json::to_string(&elems)
                                            .unwrap_or_else(|_| elems.join("\n"))
                                    }
                                });
                                let (_out, flushed_ctx) =
                                    self.run_js_steps_threaded(payload, &pending_js)?;
                                template_ctx = flushed_ctx;
                                pending_js.clear();
                            }
                            let literal = self.eval_template_segment(r, &template_ctx)?;
                            // 先 clone 供后续 JS 步作前序结果，再把原值 move 进元素列表
                            js_continuation = Some(literal.clone());
                            elems = if literal.trim().is_empty() {
                                Vec::new()
                            } else {
                                vec![literal]
                            };
                            continue;
                        }
                        // 非模板段：照旧按元素规则提取；后续 JS 以元素列表为
                        // 前序结果
                        elems = self.get_elements_single_step(r)?;
                        js_continuation = None;
                    }
                    JsChainStep::Js(code) => pending_js.push(code),
                }
            }
            if pending_js.is_empty() {
                return Ok(elems);
            }
            // 将元素列表交给 JS：单元素直接作 result；多元素 JSON 数组字符串；
            // 模板段之后取其结果作为前序步结果（P2-6a）
            let result_payload = js_continuation.take().unwrap_or_else(|| {
                if elems.len() == 1 {
                    elems[0].clone()
                } else {
                    serde_json::to_string(&elems).unwrap_or_else(|_| elems.join("\n"))
                }
            });
            let (last_out, _final_current) =
                self.run_js_steps_threaded(result_payload, &pending_js)?;
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

    /// [P2-6a | 台账 0917] 链式 getElements 的 JS 步批量执行：以 `current`
    /// 为子规则当前内容（execute_js_rule 注入 result/src），顺序执行各步，
    /// 每步输出（首个元素）作为下一步 content。返回 (末步输出, 最终内容)。
    fn run_js_steps_threaded(
        &self,
        mut current: String,
        codes: &[&str],
    ) -> LegadoResult<(Vec<String>, String)> {
        let mut last_out = Vec::new();
        for code in codes {
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
        Ok((last_out, current))
    }

    /// 单步 getElements（无 `@js:` 链）
    fn get_elements_single_step(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        // `<js>...</js>` 规则：JSONPath 后缀（`$[*]` / `@json:$…`）与无后缀统一
        // 走 get_strings——resolve_rule_type 可能把 `<js>` 前缀判定为 Auto/Css，
        // 导致误走 HTML 解析器 → 目录 0 章（51漫画 chapterList 实测）— Reasonix
        if rule.trim_start().starts_with("<js>") {
            // 非 JSONPath 后缀（CSS/XPath 等）：对齐原版 splitSourceRule 拆成
            // Js + Extract 两步，且提取必须按「元素」语义作用于 JS 输出——
            // chapterList 需要章节锚点的外层 HTML 供子规则取标题/href。
            // 包子漫画（优）chapterList `<js>java.t2s(result)</js>\nclass.xxx`：
            // JS 转简体后 CSS 选章节锚点；此前后缀被丢弃 → 整页 HTML 成为唯一
            // 「章节」→「目录获取失败」。
            if let Some(end) = rule.find("</js>") {
                let suffix = rule[end + "</js>".len()..].trim();
                let json_suffix = suffix
                    .strip_prefix("@json:")
                    .or_else(|| suffix.strip_prefix("@JSON:"))
                    .unwrap_or(suffix);
                if !suffix.is_empty() && !json_suffix.starts_with("$") {
                    let js_code = &rule["<js>".len()..end];
                    let js_result = self.execute_js_rule(js_code)?;
                    let content = if js_result.len() == 1 {
                        js_result.into_iter().next().unwrap_or_default()
                    } else {
                        js_result.join("\n")
                    };
                    let mut sub = AnalyzeRule::new(content, self.base_url.clone());
                    self.share_variable_store_into(&mut sub);
                    if let Some(exec) = self.js_executor() {
                        sub.set_js_executor(exec);
                    }
                    for (n, v) in &self.js_bindings {
                        sub.add_js_binding(n, v);
                    }
                    return sub.get_elements_single_step(suffix);
                }
            }
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
    ///
    /// P2-9 ④：value 走**完整 `get_strings` 管道**（而非旧的
    /// `get_strings_single_step` + 仅取首值）——上游 `AnalyzeRule.putRule` 的值
    /// 走完整 `getString` 管道（含 `##` 替换 / `||` 或合并 / `%%` 交叉 /
    /// 多值 join）。旧实现在 put 值上：
    /// - `##` 未处理 → 裸串（`#t@text##ab##XY`）整体被当 CSS 选择器 → 取空；
    /// - `||` / 多值 → `.next()` 只取首个，丢失后续值。
    ///
    /// 防递归（保留）：先 [`extract_put_rules`] 剥离 value_rule 内嵌 `@put`
    /// （嵌套 map 忽略），使 `cleaned` 不含 `@put`；随后 `get_strings` 内部
    /// `compile_source_rule_cached` 得到的 `put_map` 为空 → 其
    /// [`apply_put_map`] 为 no-op，不会递归炸栈。
    fn apply_put_map(&self, put_map: &HashMap<String, String>) -> LegadoResult<()> {
        for (key, value_rule) in put_map {
            // 剥离内嵌 @put（防递归）；嵌套 map 极少见，忽略。
            let (cleaned, _nested) = extract_put_rules(value_rule);
            let val = if cleaned.trim().is_empty() {
                String::new()
            } else {
                // 走完整管道：## 替换 / || 或合并 / %% 交叉 / 多值 均生效
                // （cleaned 已剥 @put，管道内 put_map 为空、无递归）。
                // 多值按上游 getString join 语义以 `\n` 连接（单值直接返回）。
                let vals = self.get_strings(&cleaned)?;
                if vals.is_empty() {
                    String::new()
                } else if vals.len() == 1 {
                    vals.into_iter().next().unwrap()
                } else {
                    vals.join("\n")
                }
            };
            self.put(key, &val);
        }
        Ok(())
    }

    /// 将规则中的 `@get:{key}` 替换为已存变量（对齐 makeUpRule getRuleType）
    fn expand_get_refs(&self, rule: &str) -> String {
        let re = re_get_ref();
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

    /// [A | 台账 0917] 仅展开多步 JS 链中 **JS 段代码内** 的 `{{js}}`
    /// （G11 语义：成功且非空替换、失败/为空保留原文；顶层绑定，复用
    /// [`Self::expand_js_refs`]）。Extract 段的 `{{…}}` 原样保留——其模板
    /// 求值延迟到 [`Self::eval_js_chain_steps`] 逐段进行（相对前序步结果，
    /// 即正确绑定）；若在此整体展开，Extract 段 `{{result}}` 会被顶层
    /// 内容（如元素 JSON）替换，拼出的 URL 错（松鹤 bookUrl 缺陷根因）。
    fn expand_js_refs_in_js_segments(&self, rule: &str) -> LegadoResult<String> {
        if !rule.contains("{{") {
            return Ok(rule.to_string());
        }
        let re = re_js_chain();
        let mut out = String::with_capacity(rule.len());
        let mut last = 0usize;
        for cap in re.captures_iter(rule) {
            let m = cap.get(0).unwrap();
            let full = &rule[m.start()..m.end()];
            let js_code = cap
                .get(2)
                .or_else(|| cap.get(1))
                .map(|g| g.as_str())
                .unwrap_or("");
            let expanded = self.expand_js_refs(js_code)?;
            out.push_str(&rule[last..m.start()]);
            if full.to_ascii_lowercase().starts_with("<js>") {
                // `<js>code</js>`（大小写任意，前缀均 4 字节）：只拼接 code 段，标签保留
                let code_start = m.start() + "<js>".len();
                out.push_str(&rule[m.start()..code_start]);
                out.push_str(&expanded);
                out.push_str(&rule[code_start + js_code.len()..m.end()]);
            } else {
                // `@js:code`（贪婪至规则末尾，前缀 4 字节）
                out.push_str(&full[..4]);
                out.push_str(&expanded);
            }
            last = m.end();
        }
        out.push_str(&rule[last..]);
        Ok(out)
    }

    // --- 内部方法 ---

    /// 执行 JS 规则
    ///
    /// 如果已注入 JsExecutor，则调用其执行 JS 代码；
    /// 否则降级返回空结果。
    fn execute_js_rule(&self, js_code: &str) -> LegadoResult<Vec<String>> {
        // JS 规则体中的 {{$.field}} / {$.field} 必须在 eval 前按当前 JSON
        // 元素展开。红薯小说 ruleBookUrl 使用 @js + {{$.bid}}；此前该
        // 占位符作为字符串字面量进入 JS，最终 bookUrl 保留 {{$.bid}}。
        let js_code_owned = if js_code.contains("{$") {
            self.process_inner_rules(js_code)?
        } else {
            js_code.to_string()
        };
        let js_code = js_code_owned.as_str();
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
            // P2-9 ③：原版 java.put 写会话变量表、@get 跨规则跨 JS/非JS 可读。
            // 此处覆盖后的 java.put/java.get 原本只写 __lgVars（eval 内临时
            // 对象，eval 结束即消失）→ 手机小说 init `java.put("url",…)` 的值
            // 对后续 tocUrl `@get:{url}` 永远不可见（目录页回退 book_url 根因）。
            // 桥接约定：引擎在 `java` 命名空间注册 `__lgStorePut`/`__lgStoreGet`
            //（legado-js QuickJS 挂载到进程级全局变量表，见 quickjs_impl
            // register_variable_apis）时，java.put 同步写全局表、java.get 本地
            // 未命中兜底读全局表；未注册的引擎（无 QuickJS）行为与改动前
            // 完全一致。
            // P3-a：空值语义与 AnalyzeRule::get 统一——本地（variables）值为
            // 空串视为未命中（fall through 读全局 store），与 Rust 侧
            // `AnalyzeRule::get` 对空本地值的穿透行为一致（此前 JS 侧
            // `v!=null` 判定把「已置空」当命中直接返回空串，与规则侧 @get
            // 读到 store 值形成 JS/规则双轨不一致）。
            if let Ok(guard) = self.variables.lock() {
                let vars_json = serde_json::to_string(&*guard).unwrap_or_else(|_| "{}".into());
                prologue.push_str(&format!(
                    "if (typeof java !== 'undefined') {{\n\
                     var __lgVars = {vars_json};\n\
                     java.put = function(k,v){{ k=String(k); var s=String(v==null?'':v); __lgVars[k]=s; if (typeof java.__lgStorePut==='function') {{ java.__lgStorePut(k,s); }} return s; }};\n\
                     java.get = function(k){{ k=String(k); var v=__lgVars[k]; if (v) {{ return String(v); }} if (typeof java.__lgStoreGet==='function') {{ var g=java.__lgStoreGet(k); if (g) {{ return String(g); }} }} return ''; }};\n\
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
                let code_json =
                    serde_json::to_string(js_code).unwrap_or_else(|_| "\"\"".to_string());
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
            let re = re_js_inner();
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
    let pre_hash = if has_get_marker || rule_no_put.trim().is_empty() || rule_no_put.contains("{{")
    {
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

/// [U4 模板串 | 台账 0917] 判定字符串是否含未渲染的书源模板变量残留
/// （`{{$.xxx}}` / `{$xxx}`：书源 JS 规则字符串拼接时模板变量未被替换，
/// 原样进入字段，如 kind = "9.9分|{{$.categoryInfoV4}}"，2.0.276 详情页
/// 标签行实锤渲染出 `{{$.categoryInfoV4}}`）。
///
/// 判据与 Dart 渲染层守卫 `hasUnrenderedTemplate`（`\{\{|\{\$`）对齐：
/// 出现 `{{` 或 `{$` 即未渲染模板残留（**成对与未闭合均算**——书源 JS
/// 规则截断可产出未闭合形 `{{$.categoryInfoV4`，2.0.277 瀚海书阁 kind
/// 实锤）。单 `{`、JSON 对象嵌套（`{"a":{"b":1}}` 无 `{{`/`{$` 序列）
/// 均不误判。`str::contains` 线性 O(n)、无逐调用正则编译（搜索解析热路径）。
fn contains_unrendered_template(s: &str) -> bool {
    s.contains("{{") || s.contains("{$")
}

/// 规范化 JS 执行器原始返回值（尚未展开数组）
///
/// - 空串 / `null` / `undefined` / `NaN` / 未渲染模板残留 → 空列表
/// - 其余 → 单元素列表（对象/数组已在引擎层 JSON.stringify）
fn normalize_js_rule_result(result: String) -> Vec<String> {
    let trimmed = result.trim();
    // [R-NaN 数据源清洗 | 2026-09-17] JS 求值结果为 NaN 数值时（书源规则
    // parseInt/算术对缺失字段产出 NaN，引擎字符串化为 "NaN"），与 null/undefined
    // 同为「无数据」：原样写进 author/kind/wordCount/intro 等字段 → 搜索结果
    // 渲染「NaN」/拼接出「NaN : NaN」（2.0.272 核图实锤，C1 UI 守卫只拦整串
    // 精确 "NaN"，拼接形漏判）。JS NaN 数值对任何书籍字段均无意义，归一为空。
    // 注意：JS 字符串字面量 "NaN"（源规则显式输出）与 NaN 数值在引擎出口
    // 不可区分，一并视为无数据（作者/分类/字数/简介字段不存在合法 "NaN" 值）。
    // [U4 模板串 | 台账 0917] 未渲染模板残留（{{$.xxx}} / {$xxx}）同为脏数据
    // 归一为空。JSON 数组字面量（首字符 '['）不在此拒收，改由
    // expand_js_json_array_result 逐元素过滤（单元素残留不致整数组丢有效项）。
    let template_residue = !trimmed.starts_with('[') && contains_unrendered_template(trimmed);
    if trimmed.is_empty()
        || trimmed == "null"
        || trimmed == "undefined"
        || trimmed == "NaN"
        || template_residue
    {
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
            // [U4 模板串 | 台账 0917] 字符串元素含未渲染模板残留（如
            // kind 数组混入 "{{$.categoryInfoV4}}"）按无数据剔除；
            // 序列化 JSON 对象/数字等非字符串元素不受影响
            let expanded: Vec<String> = arr
                .into_iter()
                .filter_map(|v| match v {
                    serde_json::Value::String(s) => {
                        if contains_unrendered_template(&s) {
                            None
                        } else {
                            Some(s)
                        }
                    }
                    other => Some(other.to_string()),
                })
                .collect();
            if expanded.is_empty() {
                Vec::new()
            } else {
                expanded
            }
        }
        _ => results,
    }
}

// ─── 规则编译热路径正则：进程级静态缓存 ────────────────────────────────
//
// 对齐原版 Kotlin `AnalyzeRule` 类级预编译正则常量。此前每次调用现场
// `Regex::new`，debug 构建实测 ~15ms/条 × 4 ≈ 60ms/规则 —— 搜索列表每条目
// 新建 analyzer → 7 字段全量重编译 → yeudusk 100 条目 ≈ 42s > 30s 超时。
// 缓存后首条之后 0ms（2026-08-15 探针 probe_re/probe_parse v5 数据）。

/// `@get:{key}` 引用展开正则
fn re_get_ref() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)@get:\{([^}]+)\}").unwrap())
}

/// `{{$.path}}` JsonPath 内嵌正则
fn re_js_inner() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"\{\{(\$[^}]*)\}\}").unwrap())
}

/// `@put:{...}` 剥离正则
fn re_put() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)@put:(\{[^}]+?\})").unwrap())
}

/// `<js>...</js>|@js:...` 链拆分正则（原版 JS_PATTERN）
fn re_js_chain() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)<js>([\s\S]*?)</js>|@js:([\s\S]*)").unwrap())
}

/// 神漫画 `$.chapter_name@put:{chapter_id:$.chapter_id}` 若不剥离，
/// JsonPath 整串失败 → 章名空 → get_chapters 跳过 → 目录为空。
fn extract_put_rules(rule: &str) -> (String, HashMap<String, String>) {
    let re = re_put();
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
    let re = re_js_chain();
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
    // [P1-1 | 台账 0917] `{{…}}` 跨度内的 `##` 属于参数内层规则（上游
    // SourceRule.init 的 evalPattern 把 `{{…}}` 整体当一个参数，makeUpRule
    // 只在参数回填**之后**才 split("##")）。顶层拆分**跳过**落在已闭合
    // `{{…}}` 跨度内的 `##` 位置（在查找循环中 continue，而非像旧版
    // all_hashes_inside_double_brace 的全有或全无守卫那样在混合形态
    // 「跨度内 + 跨度外 ##」下放弃整个拆分 → 半截垃圾）。与 FFI 层
    // split_rule_replace_parts 共用 split_top_level_hash，两入口一致。
    let parts = split_top_level_hash(rule, 4);
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
    }
    // [P2-6f3 | 台账 0917] 移除旧死分支「parts.len()==2 且 pattern 以 ###
    // 结尾 → 空替换 + replaceFirst」：`###` 自身含 `##` 拆分点（仅当落在
    // `{{…}}` 跨度内才不作顶层拆分点），而跨度内的 `###` 随段尾 `}}` 收尾
    // 不会使第二段以 `###` 结尾——该组合在可达输入下不可达（0 真实命中）。
    // 两段形态（`core##pat`）对齐上游 Kotlin `split("##")` size-2 语义：
    // 整段 pattern 全文替换、replacement 为空（而非旧「空替换 replaceFirst」），
    // 与 FFI split_rule_replace_parts（pattern/replacement/replace_first 全部
    // 直接取 parts、无特例）一致。
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
        // [P2-6b | 台账 0917] 非法正则回退对齐上游 + FFI 口径（此前返回原文，
        // 与两处入口不一致）：
        // - 上游 AnalyzeRule.replaceRegex（AnalyzeRule.kt L541-565）：正则
        //   编译失败时 replaceFirst 分支直接 `return replacement`（L557），
        //   全文替换分支降级为字面量字符串替换
        //   `result.replace(replaceRegex, replacement)`（L563，非正则替换）；
        // - FFI apply_regex_replace（web_book.rs L2566-2572）同语义。
        if spec.replace_first {
            return spec.replacement.clone();
        }
        return input.replace(&spec.pattern, &spec.replacement);
    };
    if spec.replace_first {
        // [B/P1-2 | 台账 0917] 上游 replaceRegex（AnalyzeRule.kt L546-556）
        // replaceFirst = `matcher.group(0).replaceFirst(…)`：仅首个匹配段
        // 参与替换、其余部分丢弃（Rust `re.replace` 是「替换首个匹配但保留
        // 其余」，会残留匹配段之后的尾巴，如 kind 标签
        // `{{$.categoryInfoV4##re##rep###}}` 结果多出 `…78`）。
        // **无匹配时上游返回 `""`**（L553-555 `else -> ""`），FFI
        // apply_regex_replace 与 FFI 锁定测试（test_apply_regex_replace_replace_first）
        // 同语义——本入口与 FFI 入口在此收敛为 `""`（此前误读为
        // 「无匹配原文不变」，已更正）。
        match re.find(input) {
            Some(m) => re
                .replace(&input[m.start()..m.end()], spec.replacement.as_str())
                .into_owned(),
            None => String::new(),
        }
    } else {
        re.replace_all(input, spec.replacement.as_str())
            .into_owned()
    }
}

// ─── [A/B | 台账 0917] 链内 `{{…}}` 模板求值 ─────────────────────────────
//
// 上游 `AnalyzeRule.SourceRule.init`：evalPattern（`@get:{…}` / `{{…}}`）
// 命中且位于规则前部时置 Mode.Regex，getString 走 `else -> rule`（字面返回）；
// 参数由 makeUpRule 回填（jsRuleType：isRule 参数走单源规则，否则 evalJS，
// 失败/为空 `null -> Unit` 即空串；getRuleType 走变量表），`##` 拆分发生在
// 回填**之后**。Rust 侧此前把链内 `{{…}}` 段当选择器解析 → 拼好的 URL 取空。

/// 规则的 `{{…}}` JS 链形态判定（对齐 JS_PATTERN 的 `(?i)<js>|@js:`）
///
/// [P2-6f4 | 台账 0917] 落在已闭合 `{{…}}` 跨度**内**的 `@js:` / `<js>`
/// 字面量是 JS 表达式参数文本（模板参数内容），不是链标记——跳过跨度内
/// 出现位置，仅跨度外出现才算含 JS 段。此前 `contains` 会把含此类字面量
/// 的模板规则误判为 JS 链 → 永不进模板分支（P0-1 门被误触发）。
fn rule_has_js_chain(rule: &str) -> bool {
    let lower = rule.to_ascii_lowercase();
    if !lower.contains("<js>") && !lower.contains("@js:") {
        return false;
    }
    let spans = double_brace_spans(&lower);
    let mut from = 0usize;
    while from < lower.len() {
        let Some(pos) = lower[from..]
            .match_indices("<js>")
            .map(|(i, _)| from + i)
            .chain(lower[from..].match_indices("@js:").map(|(i, _)| from + i))
            .min()
        else {
            break;
        };
        // 标记起点在已闭合 {{…}} 跨度内 → 参数文本，跳过继续找
        if !spans.iter().any(|&(s, e)| s <= pos && pos < e) {
            return true;
        }
        from = pos + 2;
    }
    false
}

/// 已闭合的 `{{…}}` 参数跨度（半开区间 [start, end)；未闭合尾段不算跨度）
fn double_brace_spans(rule: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let bytes = rule.as_bytes();
    let mut i = 0usize;
    while i + 1 < bytes.len() {
        if bytes[i] == b'{' && bytes[i + 1] == b'{' {
            if let Some(full_len) = AnalyzeRule::find_double_brace_end(&rule[i..]) {
                spans.push((i, i + full_len));
                i += full_len;
                continue;
            }
        }
        i += 1;
    }
    spans
}

/// [P1-1 | 台账 0917] 顶层 `##` 拆分（跳过 `{{…}}` 跨度内的 `##` 位置）
///
/// 语义同 `rule.splitn(max_parts, "##")`，但落在已闭合 `{{…}}` 跨度内的
/// `##` 不是拆分点（属于参数内层规则；上游 makeUpRule 只在参数回填之后
/// 才 split("##")）。旧的 `all_hashes_inside_double_brace` 全有或全无守卫
/// 在混合形态（跨度内 + 跨度外 `##`）下放弃整个拆分 → 半截垃圾；本函数
/// 在查找循环中跳过跨度内位置，两入口（解析器 `split_hash_replace` 与
/// FFI `split_rule_replace_parts`）共用，保证一致。
///
/// 无 `{{` 时退化为原生 `splitn`（零开销快路径）；`max_parts` 语义与
/// `str::splitn` 相同（最后一部分为剩余串，`usize::MAX` = 全量 split，
/// `0` = 空结果，[P2-6f2 | 台账 0917] 两路径一致）。
pub fn split_top_level_hash(rule: &str, max_parts: usize) -> Vec<&str> {
    // [P2-6f2 | 台账 0917] `max_parts == 0` 对齐 `str::splitn(0, …)` 返回空
    // （此前 `{{` 路径漏判：循环不执行后仍 `parts.push(&rule[start..])`
    // 返回 `[rule]`，与无 `{{` 快路径的 `splitn(0)` 空结果不一致）。
    if max_parts == 0 {
        return Vec::new();
    }
    if !rule.contains("{{") {
        return rule.splitn(max_parts, "##").collect();
    }
    let spans = double_brace_spans(rule);
    let mut parts: Vec<&str> = Vec::new();
    let mut start = 0usize;
    let mut count = 0usize; // 已消费的顶层 `##` 拆分点数
    let mut from = 0usize;
    while count + 1 < max_parts {
        let Some(rel) = rule[from..].find("##") else {
            break;
        };
        let p = from + rel;
        if spans.iter().any(|&(s, e)| s <= p && p + 2 <= e) {
            // 跨度内 `##`：跳过，不作拆分点（属于参数内层规则）
            from = p + 2;
            continue;
        }
        parts.push(&rule[start..p]);
        start = p + 2;
        from = start;
        count += 1;
    }
    parts.push(&rule[start..]);
    parts
}

/// 上游 `isRule`：`@` / `$.` / `$[` / `//` 前缀 → 单源规则回填
fn template_param_is_rule(expr: &str) -> bool {
    expr.starts_with('@')
        || expr.starts_with("$.")
        || expr.starts_with("$[")
        || expr.starts_with("//")
}

/// [A/P1-3/P2-6c | 台账 0917] 单步模板字面量判定
/// （作用于 **顶层拆分后的提取核心**，即 `split_hash_replace(…).0`，JS 展开前）：
/// - 首个 `{{…}}` 跨度**之前**存在非空白包装文字（URL 模板骨架等）→ 模板；
/// - 多跨度（跨度外仅空白/换行）→ 模板（P1-3：松鹤 kind 规则
///   `{{$.a##…}}\n{{$.b##…}}` 若判否会落入 `detect_rule_type_for_content`
///   把 `\d` 当正则 → 整规则编译 Err；多跨度纯模板必须识别）；
/// - 单跨度：
///   - **规则型参数**（上游 isRule：`@`/`$.`/`$[`/`//` 前缀）→ 模板；
///   - JS 表达式参数（`{{sel()}}`）：跨度位于 0 位且带**非空后缀/组合符**
///     （`.item` / `||` / `%%` / `&&` 等）→ 模板（[P2-6c] 对齐上游
///     `SourceRule.init`：首个 `{{` 位于段首 → Mode.Regex，makeUpRule 回填后
///     按 `else -> rule` 字面返回；旧 G11「展开后按选择器求值」会把拼好的
///     URL/组合符串当选择器解析 → 取空，如新龙小说 `{{baseUrl}}catalog/`、
///     清风小说网 `{{baseUrl}}##$##1/desc.html` 类「新书源未解析到任何章节」）；
///   - 整规则恰为该单跨度、无任何包装文字（G11 例外，如整规则 `{{sel()}}`）
///     → 判否，保留 `expand_js_refs` 展开 + 选择器求值路径。
///
/// 与 P0-1（含 JS 段规则在调用点先行排除，P2-6f4 跨度内字面量除外）、
/// P0-2（判定域=拆分后提取核心）、P1-3 自洽；P1-4 的 G11 保留范围由
/// 「单跨度 JS 表达式参数一律判否」收窄为「仅整规则无包装」一项
/// （P2-6c 决策，526 源 52 条候选规则逐条分析无规则依赖旧 G11 后缀行为）。
fn single_step_template_literal(rule: &str) -> bool {
    let t = rule.trim();
    if !t.contains("{{") {
        return false;
    }
    let spans = double_brace_spans(t);
    if spans.is_empty() {
        return false;
    }
    // 首个跨度之前存在非空白包装文字（URL 模板骨架等）→ 模板
    let (first_s, _) = spans[0];
    if !t[..first_s].trim().is_empty() {
        return true;
    }
    // [P1-3] 多跨度（跨度外仅空白/换行）也必须判为模板，避免落入
    // detect_rule_type_for_content 把 `\d` 当正则 → 整规则编译失败 Err
    if spans.len() >= 2 {
        return true;
    }
    // 单跨度：规则型参数进模板分支
    let (s, e) = spans[0];
    let param = t[s + 2..e - 2].trim();
    if template_param_is_rule(param) {
        return true;
    }
    // [P2-6c | 台账 0917] JS 表达式参数：跨度 0 位 + 非空后缀 → 模板
    // （上游 Mode.Regex 字面返回）；整规则无包装（G11 例外）→ 判否，
    // 保留 expand_js_refs 展开路径。
    !t[e..].trim().is_empty()
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
        assert_eq!(skip.get_string("$1").unwrap(), "/read/13.html");
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

    /// 计数 Mock JS 执行器：返回固定结果并记录调用次数
    /// （P0-1/7b 断言「JS 步必须被执行且恰好一次」）
    struct CountingJsExecutor {
        result: String,
        calls: std::sync::atomic::AtomicUsize,
    }

    impl CountingJsExecutor {
        fn new(result: &str) -> Self {
            Self {
                result: result.to_string(),
                calls: std::sync::atomic::AtomicUsize::new(0),
            }
        }

        fn call_count(&self) -> usize {
            self.calls.load(std::sync::atomic::Ordering::SeqCst)
        }
    }

    impl JsExecutor for CountingJsExecutor {
        fn execute_js(&self, _js_code: &str) -> Result<String, String> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(self.result.clone())
        }
    }

    /// [P2-6a] 脚本化 Mock JS 执行器：按**用户代码尾标**（`("{key}")`，与
    /// execute_js_rule 的 `new Function(…)(<code_json>)` 包装对应）匹配应答，
    /// 首条命中生效；未命中返回空串。同时完整记录包装后代码（调用方可
    /// 断言注入的 `globalThis.result` 载荷，验证模板段→JS 步的结果线程）。
    struct ScriptedJsExecutor {
        scripts: Vec<(String, String)>,
        calls: std::sync::Mutex<Vec<String>>,
    }

    impl ScriptedJsExecutor {
        fn new(scripts: Vec<(&str, &str)>) -> Self {
            Self {
                scripts: scripts
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
                calls: std::sync::Mutex::new(Vec::new()),
            }
        }

        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl JsExecutor for ScriptedJsExecutor {
        fn execute_js(&self, js_code: &str) -> Result<String, String> {
            self.calls.lock().unwrap().push(js_code.to_string());
            for (key, reply) in &self.scripts {
                let suffix = format!("({})", serde_json::to_string(key).unwrap());
                if js_code.ends_with(&suffix) {
                    return Ok(reply.clone());
                }
            }
            Ok(String::new())
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
        rule.get_strings("@js:var m = src.match(/漫画/); result")
            .unwrap();
        let recorded = executor.executed.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1);
        let code = &recorded[0];
        assert!(
            code.contains("globalThis.result = \"<html>漫画页</html>\";"),
            "result 注入: {code}"
        );
        assert!(
            code.contains("globalThis.src = \"<html>漫画页</html>\";"),
            "src 注入: {code}"
        );
        assert!(
            code.contains("globalThis.baseUrl = \"https://manga.example.com/chapter/1.html\";"),
            "baseUrl 注入: {code}"
        );
        assert!(
            code.contains("globalThis.source = \"https://manga.example.com\";"),
            "source 注入: {code}"
        );
        assert!(
            code.contains("globalThis.title = \"第一章\";"),
            "title 注入: {code}"
        );
        assert!(
            code.contains("globalThis.chapter = {\"title\": \"第一章\"};"),
            "chapter 注入: {code}"
        );
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
        rule.get_strings("@js:all = JSON.parse(result); all")
            .unwrap();
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
            code.contains(r#"globalThis.result = {"book_url":"https://x/1","source":"番茄小说"};"#),
            "元素模式 result 应按解析后的对象注入（键排序后）: {code}"
        );
        // src 仍为原始字符串
        assert!(
            code.contains(
                r#"globalThis.src = "{\"source\":\"番茄小说\",\"book_url\":\"https://x/1\"}";"#
            ),
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
            recorded[0].contains(", len,")
                || recorded[0].contains(" len,")
                || recorded[0].contains(", len;"),
            "prologue 须含 var len: {}",
            recorded[0]
        );
        assert!(
            recorded[0].contains(", jm,")
                || recorded[0].contains(" jm,")
                || recorded[0].contains(", jm;"),
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
        let rule = AnalyzeRule::with_js_executor("{}".to_string(), String::new(), executor);
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

    /// [U4 模板串 | 台账 0917] 未渲染模板残留判定（{{…}} / {$…}
    /// 成对与未闭合均判——书源 JS 截断可产出未闭合形）
    #[test]
    fn test_contains_unrendered_template() {
        // 未渲染模板变量残留 → 命中（成对形）
        assert!(contains_unrendered_template("{{$.categoryInfoV4}}"));
        assert!(contains_unrendered_template("9.9分|{{$.categoryInfoV4}}"));
        assert!(contains_unrendered_template("{$xxx}"));
        assert!(contains_unrendered_template("a {{$.b}} c {$d}"));
        // 未闭合形（JS 规则截断产物，2.0.277 瀚海书阁 kind 实锤）→ 命中
        assert!(contains_unrendered_template("{{$.unclosed"));
        assert!(contains_unrendered_template("{$unclosed"));
        // 合法数据不误判（单 {、嵌套 JSON 对象、空串均不命中）
        assert!(!contains_unrendered_template("9.9分"));
        assert!(!contains_unrendered_template("轻小说"));
        assert!(!contains_unrendered_template("{\"a\":{\"b\":1}}"));
        assert!(!contains_unrendered_template("{}"));
        assert!(!contains_unrendered_template("{abc"));
        assert!(!contains_unrendered_template(""));
    }

    /// [U4 模板串 | 台账 0917] normalize_js_rule_result 拒收模板残留
    /// （JSON 数组字面量除外——交由 expand 逐元素过滤）
    #[test]
    fn test_normalize_rejects_unrendered_template() {
        assert!(normalize_js_rule_result("{{$.x}}".into()).is_empty());
        assert!(normalize_js_rule_result("9.9分|{{$.x}}".into()).is_empty());
        assert!(normalize_js_rule_result("{$x}".into()).is_empty());
        // 既有 R-NaN 清洗判据保持
        assert!(normalize_js_rule_result("".into()).is_empty());
        assert!(normalize_js_rule_result("null".into()).is_empty());
        assert!(normalize_js_rule_result("undefined".into()).is_empty());
        assert!(normalize_js_rule_result("NaN".into()).is_empty());
        // 合法值 / JSON 数组字面量（元素级过滤归 expand）原样通过
        assert_eq!(
            normalize_js_rule_result("9.9分".into()),
            vec!["9.9分".to_string()]
        );
        assert_eq!(
            normalize_js_rule_result(r#"["ok","{{$.x}}"]"#.to_string()),
            vec![r#"["ok","{{$.x}}"]"#.to_string()]
        );
    }

    /// [U4 模板串 | 台账 0917] 数组展开逐元素剔除模板残留（混合数组
    /// 不整条丢弃；全残留归空；非字符串元素不受影响）
    #[test]
    fn test_expand_filters_template_residue_elements() {
        assert_eq!(
            expand_js_json_array_result(vec![r#"["ok","{{$.x}}"]"#.to_string()]),
            vec!["ok".to_string()]
        );
        assert!(expand_js_json_array_result(vec![r#"["{{$.x}}"]"#.to_string()]).is_empty());
        assert_eq!(
            expand_js_json_array_result(vec![r#"["a","b"]"#.to_string()]),
            vec!["a".to_string(), "b".to_string()]
        );
        // JSON 对象元素序列化原样保留
        assert_eq!(
            expand_js_json_array_result(vec![r#"[{"t":"1"}]"#.to_string()]),
            vec![r#"{"t":"1"}"#.to_string()]
        );
    }

    /// `<js>…</js>\n$[*]` 不得提前展开数组（否则 JsonPath 失根）
    #[test]
    fn test_js_tag_jsonpath_suffix_keeps_array_for_split() {
        let executor = Arc::new(MockJsExecutor {
            result: r#"[{"title":"第1话"},{"title":"第2话"}]"#.to_string(),
        });
        let rule =
            AnalyzeRule::with_js_executor("<html></html>".to_string(), String::new(), executor);
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

    /// `<js>...</js>\nclass.xxx` 复合规则：CSS 后缀按「元素」语义作用于 JS 输出
    ///
    /// 对齐包子漫画（优）chapterList（`<js>java.t2s(result)</js>\n
    /// class.pure-u-1-1 … comics-chapters`）：JS 转简体后 CSS 选章节锚点，
    /// get_elements 须返回锚点外层 HTML（供子规则取标题/href），
    /// get_strings 则返回各元素文本 — Reasonix
    #[test]
    fn test_js_tag_with_css_suffix() {
        let executor = Arc::new(MockJsExecutor {
            result: r#"<html><ul class="comics-chapters"><li><a class="pure-u-1-1 pure-u-sm-1-2 comics-chapters" href="/c/1">第1话</a></li><li><a class="pure-u-1-1 pure-u-sm-1-2 comics-chapters" href="/c/2">第2话</a></li></ul></html>"#
                .to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            "<html>原目录页（繁体，JS 转简体）</html>".to_string(),
            "https://baozi.example.com/comic/1".to_string(),
            executor,
        );
        let css_suffix_rule =
            "<js>java.t2s(result)</js>\nclass.pure-u-1-1 pure-u-sm-1-2 comics-chapters";
        // 元素语义：chapterList 需要章节锚点的外层 HTML
        let elems = rule.get_elements(css_suffix_rule).unwrap();
        assert_eq!(elems.len(), 2, "CSS 后缀应从 JS 输出提取 2 个章节锚点");
        assert!(
            elems[0].contains("href=\"/c/1\""),
            "元素应为外层 HTML: {}",
            elems[0]
        );
        // 文本语义：同一规则经 get_strings 返回各元素文本
        let texts = rule.get_strings(css_suffix_rule).unwrap();
        assert_eq!(texts, vec!["第1话", "第2话"]);
    }

    /// @js 规则中 {{$.field}} 必须在执行前按当前 JSON 元素展开。
    #[test]
    fn test_js_rule_expands_json_inner_placeholder() {
        let executor = Arc::new(RecordingJsExecutor::new());
        let rule = AnalyzeRule::with_js_executor(
            r#"{"bid":"116554"}"#.to_string(),
            String::new(),
            executor.clone(),
        );
        let _ = rule.execute_js_rule("'https://x/bid/{{$.bid}}'").unwrap();
        let executed = executor.executed.lock().unwrap().join("\n");
        assert!(executed.contains("116554"), "应展开 bid: {executed}");
        assert!(
            !executed.contains("{{$.bid}}"),
            "占位符不应残留: {executed}"
        );
    }

    /// JSONP/JSON 书源可在 <js> 解包后使用 @json: 后缀继续提取。
    #[test]
    fn test_js_tag_with_at_json_suffix() {
        let executor = Arc::new(MockJsExecutor {
            result: r#"{"bookinfo":[{"catename":"红薯书"},{"catename":"第二本"}]}"#.to_string(),
        });
        let rule = AnalyzeRule::with_js_executor("jsonp".to_string(), String::new(), executor);
        let result = rule
            .get_elements(
                "<js>unwrapJsonp(result)</js>
@json:$..bookinfo[*]",
            )
            .unwrap();
        assert_eq!(result.len(), 2);
        let first = AnalyzeRule::new(result[0].clone(), String::new());
        assert_eq!(first.get_string("$.catename").unwrap(), "红薯书");
    }

    /// `<js>` 无 JSONPath 后缀：保持原语义（直接返回 JS 结果）
    #[test]
    fn test_js_tag_without_suffix() {
        let executor = Arc::new(MockJsExecutor {
            result: "直接结果".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor("x".to_string(), String::new(), executor);
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
        assert_eq!(
            map.get("chapter_id").map(String::as_str),
            Some("$.chapter_id")
        );

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
        let rule = AnalyzeRule::new(r#"{"t":"A&amp;B&lt;C&gt;"}"#.into(), String::new());
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
        use std::sync::Arc;

        struct JsonArrayExec;
        impl JsExecutor for JsonArrayExec {
            fn execute_js(&self, _js_code: &str) -> Result<String, String> {
                Ok(
                    r#"[{"title":"第1话","url":"/ch/1"},{"title":"第2话","url":"/ch/2"}]"#
                        .to_string(),
                )
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
        assert!(
            els[0].contains("第1话") || els[0].contains("/ch/1"),
            "{}",
            els[0]
        );
    }

    /// `get_strings_batch` 与逐字段 `get_string` 结果必须一致（CSS 共享 parse + 非 CSS 回退）
    #[test]
    fn test_get_strings_batch_matches_per_field() {
        // HTML 元素（yeudusk 列表项形态）：纯 CSS 规则走共享 parse
        let elem = r#"<div class="c-row"><span class="c-subject">武动乾坤</span><ul class="c-tag"><li>玄幻魔法</li><li>连载</li><li>天蚕土豆</li></ul><a href="/book/123/"></a></div>"#;
        let rules: Vec<&str> = vec![
            "class.c-subject@text",
            "class.c-tag@li.0@text",
            "class.c-tag@li.2@text",
            ".c-row@a@href",
        ];

        // 旧路径：逐字段 get_string（每字段独立 parse）
        let mut old_rule = AnalyzeRule::new(String::new(), "http://example.com".into());
        old_rule.set_element_content(elem.to_string());
        let old_vals: Vec<String> = rules
            .iter()
            .map(|r| old_rule.get_string(r).unwrap_or_default())
            .collect();

        // 新路径：批量（一次 parse）
        let mut new_rule = AnalyzeRule::new(String::new(), "http://example.com".into());
        new_rule.set_element_content(elem.to_string());
        let new_vals: Vec<String> = new_rule
            .get_strings_batch(rules.clone())
            .into_iter()
            .map(|r| r.unwrap_or_default())
            .collect();

        assert_eq!(
            old_vals,
            vec!["武动乾坤", "玄幻魔法", "天蚕土豆", "/book/123/"]
        );
        assert_eq!(new_vals, old_vals, "batch 与逐字段结果必须一致");
    }

    /// `get_strings_batch` 对 JSON 内容 + JsonPath 规则走回退路径且结果正确
    #[test]
    fn test_get_strings_batch_json_fallback() {
        let content = r#"{"name":"斗破苍穹","author":"天蚕土豆","url":"/book/1"}"#;
        let rules: Vec<&str> = vec!["$.name", "$.author", "$.url"];

        let mut old_rule = AnalyzeRule::new(String::new(), String::new());
        old_rule.set_content(content.to_string());
        let old_vals: Vec<String> = rules
            .iter()
            .map(|r| old_rule.get_string(r).unwrap_or_default())
            .collect();

        let mut new_rule = AnalyzeRule::new(String::new(), String::new());
        new_rule.set_content(content.to_string());
        let new_vals: Vec<String> = new_rule
            .get_strings_batch(rules.clone())
            .into_iter()
            .map(|r| r.unwrap_or_default())
            .collect();

        assert_eq!(old_vals, vec!["斗破苍穹", "天蚕土豆", "/book/1"]);
        assert_eq!(new_vals, old_vals);
    }

    // ─── [A/B | 台账 0917] `{{…}}` 模板求值回归测试 ─────────────────────

    /// (a) 松鹤 bookUrl 完整三步链：`$.bid` → `<js>` → URL 模板。
    /// 修复前末段 `{{result}}` 被当 CSS 选择器解析 → 全链空 → B1.4 回退
    /// baseUrl → 详情全空 → tocUrl 空 → 0 章（「新书源未解析到任何章节」）。
    /// 修复后末段按模板回填（参数相对前序步结果），拼好的 URL 原样返回。
    #[test]
    fn test_template_chain_bookurl_full() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: "1100468021".to_string(),
        });
        // 元素 JSON（search 列表元素，set_element_content 语义）：`$.bid` → 468021
        let content = r#"{"bid":468021,"bookName":"松鹤庭沐"}"#;
        let base_url = "https://newopensearch.reader.qq.com/wechat?keyword=测试".to_string();
        let mut rule = AnalyzeRule::with_js_executor(String::new(), base_url, executor);
        rule.set_element_content(content.to_string());

        // (b) 首段选择器单独求值仍正确
        assert_eq!(rule.get_string("$.bid").unwrap(), "468021");

        let chain = "$.bid\n<js>1100000000+parseInt(result)</js>\nhttps://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{result}}";
        let out = rule.get_string(chain).unwrap();
        assert_eq!(
            out, "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1100468021",
            "全链 bookUrl: {out}"
        );
    }

    /// (c)/(e) 链末段模板单独求值：content = 前序步结果（JS 结果字符串）。
    /// `{{1+1}}` 按 JS 表达式求值（非字面、非选择器）；回填失败 → 参数空串
    /// （上游 makeUpRule `null -> Unit`），URL 骨架保留。
    #[test]
    fn test_template_url_segment_standalone() {
        use std::sync::Arc;
        let url_tpl = "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=";
        let executor = Arc::new(MockJsExecutor {
            result: "1100468021".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor("1100468021".to_string(), String::new(), executor);
        let out = rule
            .get_string(&format!("{url_tpl}{{{{result}}}}"))
            .unwrap();
        assert_eq!(
            out,
            format!("{url_tpl}1100468021"),
            "JS 表达式参数回填: {out}"
        );

        // (e) `{{1+1}}`：JS 表达式参数被执行（mock 返回 42 证明走了 JS 路径）
        let executor2 = Arc::new(MockJsExecutor {
            result: "42".to_string(),
        });
        let rule2 =
            AnalyzeRule::with_js_executor("1100468021".to_string(), String::new(), executor2);
        let out2 = rule2.get_string(&format!("{url_tpl}{{{{1+1}}}}")).unwrap();
        assert_eq!(
            out2,
            format!("{url_tpl}42"),
            "JS 表达式参数应被求值: {out2}"
        );

        // 回填失败 → 参数为空串，URL 骨架保留
        let rule3 = AnalyzeRule::with_js_executor(
            "1100468021".to_string(),
            String::new(),
            Arc::new(FailingJsExecutor),
        );
        let out3 = rule3
            .get_string(&format!("{url_tpl}{{{{result}}}}"))
            .unwrap();
        assert_eq!(out3, url_tpl, "回填失败参数应为空: {out3}");
    }

    /// (f) 反回归：纯选择器 + `@js:` 链（不含 `{{…}}`）行为不变。
    #[test]
    fn test_pure_selector_js_chain_unchanged() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: "1100468021".to_string(),
        });
        let content = r#"{"bid":468021}"#;
        let rule = AnalyzeRule::with_js_executor(content.to_string(), String::new(), executor);
        let out = rule
            .get_string("$.bid\n@js:1100000000+parseInt(result)")
            .unwrap();
        assert_eq!(out, "1100468021");
    }

    /// G11 反回归：`{{js}}` 整规则（无包装）仍走 expand_js_refs 展开后按
    /// 选择器求值（与 test_rule_inline_js_substitution 互为补充）。
    #[test]
    fn test_g11_whole_rule_js_param_keeps_selector_eval() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: "class.title".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            r#"<div class="title">正文</div>"#.to_string(),
            String::new(),
            executor,
        );
        assert_eq!(rule.get_strings("{{sel()}}").unwrap(), vec!["正文"]);
    }

    /// 2.5 路由：多步 JS 链只展开 **JS 段代码内** 的 `{{js}}`（G11），
    /// Extract 段 `{{…}}` 原样保留，交由 eval_js_chain_steps 逐段模板求值。
    #[test]
    fn test_expand_js_refs_in_js_segments_only() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: "V".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor("top".to_string(), String::new(), executor);
        let out = rule
            .expand_js_refs_in_js_segments("$.bid\n<js>{{foo()}}</js>\nhttps://x/?id={{result}}")
            .unwrap();
        assert_eq!(out, "$.bid\n<js>V</js>\nhttps://x/?id={{result}}");
        // 失败 → JS 段保留原文（G11）
        let rule2 = AnalyzeRule::with_js_executor(
            "top".to_string(),
            String::new(),
            Arc::new(FailingJsExecutor),
        );
        let out2 = rule2
            .expand_js_refs_in_js_segments("$.bid\n<js>{{foo()}}</js>\n{{result}}")
            .unwrap();
        assert_eq!(out2, "$.bid\n<js>{{foo()}}</js>\n{{result}}");
    }

    /// (B) `##` 落在 `{{…}}` 内属于参数内层规则：松鹤 kind 规则
    /// `{{$.categoryInfoV4##\d...##$1$2###}}` 修复前被顶层 `##` 拆分截断成
    /// `{{$.categoryInfoV4`（未闭合）→ get_string 空 → 标签字段丢失。
    /// 修复后：参数整体回填（内层 `##re##rep###` 按上游 group(0) replaceFirst）。
    #[test]
    fn test_template_param_inner_hash_replace() {
        let content = r#"{"categoryInfoV4":"12:34:56,78"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let kind = rule
            .get_string(r"{{$.categoryInfoV4##\d.*?\:(.*?)\:.*?(,|$)##$1$2###}}")
            .unwrap();
        assert_eq!(kind, "34,", "kind: {kind}");
        // 无 `##` 的单个规则型参数：字面回填
        let bare = rule.get_string("{{$.categoryInfoV4}}").unwrap();
        assert_eq!(bare, "12:34:56,78", "bare: {bare}");
    }

    /// (P1-1) 顶层 `##` 拆分单元：split_top_level_hash 跳过 `{{…}}` 跨度内的
    /// `##` 位置（解析器 split_hash_replace 与 FFI split_rule_replace_parts
    /// 共用，两入口一致）。
    #[test]
    fn test_split_top_level_hash_unit() {
        use super::split_top_level_hash;
        // 无 {{ → 原生 splitn 快路径
        assert_eq!(
            split_top_level_hash("a##b##c##d", 4),
            vec!["a", "b", "c", "d"]
        );
        assert_eq!(split_top_level_hash("a##b", 4), vec!["a", "b"]);
        assert_eq!(
            split_top_level_hash("$.x##re", usize::MAX),
            vec!["$.x", "re"]
        );
        // 全部 ## 在跨度内 → 不拆分（松鹤 kind 规则形态）
        assert_eq!(
            split_top_level_hash("{{$.x##re##rep###}}", 4),
            vec!["{{$.x##re##rep###}}"]
        );
        // 混合形态（P1-1）：跨度内 ## 跳过、跨度外 ## 正常拆分
        assert_eq!(
            split_top_level_hash("a##{{x##y}}##b", 4),
            vec!["a", "{{x##y}}", "b"]
        );
        // FFI 入口（全量 split，max_parts = usize::MAX）与解析器一致
        assert_eq!(
            split_top_level_hash("a##{{x##y}}##b", usize::MAX),
            vec!["a", "{{x##y}}", "b"]
        );
        // 未闭合 {{ 不算跨度（退化为普通 splitn）
        assert_eq!(split_top_level_hash("{{$.x##re", 4), vec!["{{$.x", "re"]);
        // splitn 语义：最后一段为剩余串
        assert_eq!(
            split_top_level_hash("a##b##c##d", 3),
            vec!["a", "b", "c##d"]
        );
        // [P2-6f2 | 台账 0917] max_parts == 0 对齐 str::splitn(0, …) 返回空
        // （{{ 路径此前漏判：循环不执行后仍返回 [rule]，与快路径不一致）
        assert_eq!(split_top_level_hash("a##b", 0), Vec::<&str>::new());
        assert_eq!(split_top_level_hash("{{x}}##a", 0), Vec::<&str>::new());
    }

    /// (P1-1) split_hash_replace 跨度感知：全部 `##` 在跨度内 → 整规则原样、
    /// 无替换规格；混合形态 → 跨度外拆分、跨度内随基础/参数保留。
    #[test]
    fn test_split_hash_replace_span_aware() {
        let (core, spec) = super::split_hash_replace("{{$.x##re##rep###}}");
        assert_eq!(core, "{{$.x##re##rep###}}");
        assert!(spec.is_none());
        // 混合形态（P1-1）：旧的「全有或全无」守卫会放弃整个拆分
        let (core2, spec2) = super::split_hash_replace("a##{{x##y}}##b");
        assert_eq!(core2, "a");
        let spec2 = spec2.expect("混合形态须有替换规格（跨度内 ## 属参数内层）");
        assert_eq!(spec2.pattern, "{{x##y}}");
        assert_eq!(spec2.replacement, "b");
        assert!(!spec2.replace_first);
        // 普通 `##` 替换规则不受影响
        let (core3, spec3) = super::split_hash_replace("$.x##re##rep");
        assert_eq!(core3, "$.x");
        let spec3 = spec3.expect("替换规格");
        assert_eq!(spec3.pattern, "re");
        assert!(!spec3.replace_first);
    }

    /// (B) 顶层 `##` 替换（跨度外）仍生效：`$.x##re##rep###` replaceFirst 走
    /// 上游 group(0) 语义（仅首匹配段参与替换，其余丢弃）。
    #[test]
    fn test_hash_replace_first_group0_semantics() {
        let content = r#"{"v":"12:34:56,78"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let out = rule
            .get_string(r#"$.v##\d.*?\:(.*?)\:.*?(,|$)##$1$2###"#)
            .unwrap();
        assert_eq!(out, "34,", "replaceFirst group(0) 语义: {out}");
        // 全文替换分支（无第四段）不受影响
        let out2 = rule.get_string(r#"$.v##[^0-9]"#).unwrap();
        assert_eq!(out2, "12345678", "全文替换: {out2}");
    }

    // ─── [P0-1 | 台账 0917] `@js:`/`<js>` 单步体内含 `{{…}}` ─────────────────
    // 回归：JS 步体内含 `{{…}}` 时整规则被误判为模板字面量 → JS 步未被执行、
    // 直接回退字面结果。现在体内（`{{…}}` 展开后）必须交给 executor 执行；
    // 体内 JSONPath 参数（`$` 起头）原样保留交由 JS 引擎，不触发顶层回填。

    /// P0-1：`@js:` 单步体内含 `{{…}}` → JS 必须被执行（executor 恰好 1 次），
    /// 结果为 executor 返回值（而非未执行的字面体）。
    #[test]
    fn test_atjs_step_body_with_template_executes_js() {
        use std::sync::Arc;
        let executor = Arc::new(CountingJsExecutor::new("JS_RAN"));
        let rule = AnalyzeRule::with_js_executor(
            r#"{"className":"a","bid":"b"}"#.to_string(),
            String::new(),
            executor.clone(),
        );
        let out = rule
            .get_string("@js:\nc = \"{{$.className||$.bid}}\";\ns = c; s")
            .unwrap();
        assert_eq!(out, "JS_RAN", "P0-1 @js: 体内 {{…}} 须走 JS 执行: {out}");
        assert_eq!(executor.call_count(), 1, "P0-1 executor 应恰好被调用 1 次");
    }

    /// P0-1：`<js>…</js>` 包裹体内含 `{{…}}` 同形 → JS 必须被执行（恰好 1 次）。
    #[test]
    fn test_js_tag_step_body_with_template_executes_js() {
        use std::sync::Arc;
        let executor = Arc::new(CountingJsExecutor::new("JS_RAN"));
        let rule = AnalyzeRule::with_js_executor(
            r#"{"className":"a"}"#.to_string(),
            String::new(),
            executor.clone(),
        );
        let out = rule
            .get_string("<js>c = \"{{$.className}}\"; c</js>")
            .unwrap();
        assert_eq!(out, "JS_RAN", "P0-1 <js> 体内 {{…}} 须走 JS 执行: {out}");
        assert_eq!(executor.call_count(), 1, "P0-1 executor 应恰好被调用 1 次");
    }

    // ─── [P0-2 | 台账 0917] 选择器 + 跨度外 `##` 替换段含 `{{…}}` ───────────

    /// P0-2：`.content@p@html##…{{book.name}}…` 替换段含 JS 参数（executor 回填），
    /// 无匹配 → 替换不生效、提取结果原样保留；回归版本曾错回整条规则
    /// `.content@p@html` 作为结果。
    #[test]
    fn test_hash_replace_outside_span_with_template_param() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: "松鹤庭沐".to_string(),
        });
        let content = "<div class=\"content\"><p>第一段正文</p>\n<p>第二段正文</p></div>";
        let rule = AnalyzeRule::with_js_executor(content.to_string(), String::new(), executor);
        let rule_str = ".content@p@html##.*请退出浏览器阅读模式.*|喜欢{{book.name}}.*请大家收藏{{book.name}}.*";
        let out = rule.get_strings(rule_str).unwrap();
        assert_eq!(
            out,
            vec!["<p>第一段正文</p>", "<p>第二段正文</p>"],
            "P0-2 提取结果不得被规则字面污染: {out:?}"
        );
        assert_eq!(
            rule.get_string(rule_str).unwrap(),
            "<p>第一段正文</p>\n<p>第二段正文</p>",
            "P0-2 get_string 合并形态"
        );
    }

    /// P0-2：`href##(.*)##$1/?shunt={{Get('shunt')}}` → replaceFirst + JS 参数回填；
    /// 回归版本 `href` 未被提取 → 错成 `"href/?shunt=OK"`。
    #[test]
    fn test_href_shunt_template_replace() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: "OK".to_string(),
        });
        let rule = AnalyzeRule::with_js_executor(
            "<a href=\"/comic/1/2\">章节</a>".to_string(),
            String::new(),
            executor,
        );
        let out = rule
            .get_string("href##(.*)##$1/?shunt={{Get('shunt')}}")
            .unwrap();
        assert_eq!(out, "/comic/1/2/?shunt=OK", "P0-2 shunt 回填: {out}");
    }

    // ─── [P1-3 | 台账 0917] 松鹤 kind 双跨度纯模板 ───────────────────────────

    /// P1-3：两个 `{{…}}` 跨度（真实换行分隔、跨度内含 `##` 内层替换）各自独立
    /// 回填后以换行拼接，且不得 Err；回归版本在顶层 `##` 处截断成半截模板。
    #[test]
    fn test_songhe_kind_two_span_template() {
        use std::sync::Arc;
        let executor = Arc::new(MockJsExecutor {
            result: String::new(),
        });
        let content = r#"{"categoryInfoV4":"12:34:56,78","updateInfo":"已更新至第100章"}"#;
        let rule = AnalyzeRule::with_js_executor(content.to_string(), String::new(), executor);
        let kind_rule = r"{{$.categoryInfoV4##\d.*?\:(.*?)\:.*?(,|$)##$1$2###}}".to_string()
            + "\n"
            + r"{{$.updateInfo##已更新至.*##连载中}}";
        let out = rule.get_string(&kind_rule).unwrap();
        assert_eq!(
            out, "34,\n连载中",
            "P1-3 kind 双跨度回填（换行分隔）: {out:?}"
        );
    }

    // ─── [P1-4 → P2-6c | 台账 0917] `{{sel()}}` + 后缀/组合符对齐上游字面返回 ──

    /// [P2-6c]（取代 P1-4 旧 G11 预期）：单跨度 JS 表达式参数带后缀/组合符时，
    /// 对齐上游 `SourceRule.init`（首个 `{{` 位于段首 → Mode.Regex）：makeUpRule
    /// 回填后按 `else -> rule` **字面返回**（`||`/`%%`/`&&` 组合符拆分只存在于
    /// Default/Json/XPath 分析器的 splitRule，Mode.Regex 分支不做组合符拆分）：
    /// (a) `{{sel()}}.item` → 字面 `div.title.item`；(b) `||` 组合 → 整段字面；
    /// (c) `%%` 交叉合并 → 整段字面（不再展开后按选择器取 `正文A`/`正文A\n小字`）。
    #[test]
    fn test_sel_template_with_suffix_and_combinators() {
        use std::sync::Arc;
        let html = r#"<div class="title item">正文A</div><small>小字</small>"#;
        let rule = AnalyzeRule::with_js_executor(
            html.to_string(),
            String::new(),
            Arc::new(MockJsExecutor {
                result: "div.title".to_string(),
            }),
        );
        assert_eq!(
            rule.get_string("{{sel()}}.item").unwrap(),
            "div.title.item",
            "P2-6c 后缀形态字面返回"
        );
        let rule = AnalyzeRule::with_js_executor(
            html.to_string(),
            String::new(),
            Arc::new(MockJsExecutor {
                result: "div.title".to_string(),
            }),
        );
        assert_eq!(
            rule.get_string("{{sel()}}||.fallback").unwrap(),
            "div.title||.fallback",
            "P2-6c || 组合符不做拆分、整段字面返回"
        );
        let rule = AnalyzeRule::with_js_executor(
            html.to_string(),
            String::new(),
            Arc::new(MockJsExecutor {
                result: "div.title".to_string(),
            }),
        );
        assert_eq!(
            rule.get_string("{{sel()}}%%small@text").unwrap(),
            "div.title%%small@text",
            "P2-6c %% 组合符不做拆分、整段字面返回"
        );
    }

    // ─── [P1-A | 台账 0917] `{{JS表达式}}##pattern##replacement` 判模板 ──────

    /// P1-A：首个 `{{…}}` 跨度位于 0 位且跨度外存在顶层 `##` 替换规格时
    /// （清风小说网 `ruleBookInfo.tocUrl = {{baseUrl}}##$##1/desc.html`），
    /// 对齐上游 AnalyzeRule.kt L699-703（首个 match 位于段首 → Mode.Regex，
    /// makeUpRule L819-829 回填后才 split `##`）：参数回填后按字面返回并
    /// 应用 `##` 替换，而不是走选择器路径取空（tocUrl 回退成详情页 URL）。
    /// 反回归（[P2-6c] 后收窄）：`{{sel()}}.item`（无顶层 `##`）单跨度 JS 表达式
    /// 参数带非空后缀 → 同样进模板分支字面返回 `div.title.item`（G11 例外仅剩
    /// 「整规则恰为单个 JS 表达式跨度、无包装」一项，见 test_g11_*）。
    #[test]
    fn test_js_param_with_top_level_hash_replace_is_template() {
        use std::sync::Arc;
        // 正例：清风小说网真实规则（JS 执行器注入 baseUrl 变量）
        let rule = AnalyzeRule::with_js_executor(
            String::new(),
            "https://www.qingfengxs.com/".to_string(),
            Arc::new(MockJsExecutor {
                result: "https://www.qingfengxs.com/".to_string(),
            }),
        );
        let out = rule
            .get_strings_ex("{{baseUrl}}##$##1/desc.html", true)
            .unwrap();
        assert_eq!(
            out,
            vec!["https://www.qingfengxs.com/1/desc.html"],
            "P1-A 顶层 ## 替换须应用而非取空: {out:?}"
        );
        // 反回归（P2-6c 后）：`{{sel()}}.item` 无顶层 ## 亦为模板字面返回
        // （G11 例外仅剩整规则无包装的单跨度形态，见 test_g11_*）
        let html = r#"<div class="title item">正文A</div>"#;
        let rule = AnalyzeRule::with_js_executor(
            html.to_string(),
            String::new(),
            Arc::new(MockJsExecutor {
                result: "div.title".to_string(),
            }),
        );
        assert_eq!(
            rule.get_string("{{sel()}}.item").unwrap(),
            "div.title.item",
            "P2-6c 单跨度 JS 表达式参数带后缀字面返回"
        );
    }

    // ─── [P1-2 | 台账 0917] replaceFirst 无匹配 → 空串 ──────────────────────

    /// P1-2：`$.v##zzz##REP###`（v=`abc`）replaceFirst 无匹配 → `""`
    /// （上游 group(0) replaceFirst 的 else 分支）；FFI 侧
    /// `apply_regex_replace` 同语义（见 web_book.rs 交叉断言单测）。
    #[test]
    fn test_replace_first_no_match_yields_empty() {
        let content = r#"{"v":"abc"}"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let out = rule.get_string("$.v##zzz##REP###").unwrap();
        assert_eq!(out, "", "P1-2 无匹配须返回空串而非原文: {out:?}");
    }

    // ─── [P1-1 | 台账 0917] 混合形态 `##` 不再产生半截垃圾 ──────────────────

    /// P1-1：跨度内 `##`（参数内层替换）+ 跨度外 `##`（规则级替换/收尾）共存时，
    /// 须正常回填、不得返回 `{{@@.mb-1@text` 之类的半截字符串。
    #[test]
    fn test_mixed_form_hash_replace_no_half_garbage() {
        let content =
            r#"<div class="mb-1">浏览：100</div><a href="/x/tag">标签</a><small>小字</small>"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let out = rule
            .get_strings(
                "{{@@.mb-1@text##浏览：(.*)##$1浏览###}}\n{{@@a[href$=\"tag\"]@text%%small@text##\\[|\\]}}\n###",
            )
            .unwrap();
        assert_eq!(
            out,
            vec!["100浏览\n标签\n小字\n"],
            "P1-1 混合形态回填: {out:?}"
        );
        assert!(
            !out.iter().any(|s| s.starts_with("{{")),
            "P1-1 不得返回半截模板串: {out:?}"
        );
    }

    /// P1-1：`{{…##内层##…}}` 跨度 + 跨度外 `##html##jpg` 全替换链，
    /// 不得返回 `{{@@a.0@href` 之类的半截字符串。
    #[test]
    fn test_mixed_form_nested_replace_chain() {
        let content = r#"<html><body><a href="book.html">x</a></body></html>"#;
        let rule = AnalyzeRule::new(content.to_string(), String::new());
        let out = rule
            .get_strings("{{@@a.0@href##book##images/cover}}##html##jpg")
            .unwrap();
        assert_eq!(out, vec!["images/cover.jpg"], "P1-1 嵌套替换链: {out:?}");
        assert!(
            !out.iter().any(|s| s.starts_with("{{")),
            "P1-1 不得返回半截模板串: {out:?}"
        );
    }

    // ─── [7b | 台账 0917] coverUrl 链（末段 `@js:`）结果不变 ────────────────

    /// 7b：`$.bid` → `@js:` 末段（消费前序步 `result`）→ 最终 URL 即 executor
    /// 返回值（JS 步恰好执行 1 次）；与既有 bookUrl 链测试互证「既有链不回归」。
    #[test]
    fn test_cover_url_js_tail_chain_unchanged() {
        use std::sync::Arc;
        let cover_url =
            "https://wfqqreader-1252317822.image.myqcloud.com/cover/468021/b_468021.jpg";
        let executor = Arc::new(CountingJsExecutor::new(cover_url));
        let rule = AnalyzeRule::with_js_executor(
            r#"{"bid":"468021"}"#.to_string(),
            String::new(),
            executor.clone(),
        );
        let out = rule
            .get_string("$.bid\n@js:\nvar s = result;\nreturn \"cover_\" + s;")
            .unwrap();
        assert_eq!(out, cover_url, "coverUrl 链结果不变: {out}");
        assert_eq!(executor.call_count(), 1, "JS 步应恰好执行 1 次");
    }

    // ─── [P2-6b | 台账 0917] 非法正则回退对齐上游 + FFI 口径 ────────────────

    /// 非法正则回退三处收敛：`apply_hash_replace`（解析器入口）此前对非法
    /// 正则返回**原文**，与上游 `AnalyzeRule.replaceRegex`（replaceFirst 分支
    /// `return replacement`；全文替换分支降级字面量 `input.replace`）及 FFI
    /// `apply_regex_replace` 不一致。本测试锁定三处统一口径。
    #[test]
    fn test_apply_hash_replace_invalid_regex_fallback() {
        // 单测：replaceFirst → replacement；全文替换 → 字面量字符串替换
        let spec_first = HashReplaceSpec {
            pattern: "(".to_string(),
            replacement: "REP".to_string(),
            replace_first: true,
        };
        assert_eq!(
            apply_hash_replace("abc(def", &spec_first),
            "REP",
            "非法正则 + replaceFirst 须返回 replacement（上游 L557）"
        );
        let spec_full = HashReplaceSpec {
            pattern: "(".to_string(),
            replacement: "REP".to_string(),
            replace_first: false,
        };
        assert_eq!(
            apply_hash_replace("(x)", &spec_full),
            "REPx)",
            "非法正则 + 全文替换 降级为字面量 str::replace（仅替换 `(`，上游 L563 / FFI）"
        );

        // e2e：`$.v##(##REP###`（len4 → replaceFirst）与 `$.v##(##REP`（len3 → 全文）
        let rule = AnalyzeRule::new(r#"{"v":"(x)"}"#.to_string(), String::new());
        assert_eq!(
            rule.get_string("$.v##(##REP###").unwrap(),
            "REP",
            "### 收尾 → replaceFirst，非法正则回退 replacement"
        );
        assert_eq!(
            rule.get_string("$.v##(##REP").unwrap(),
            "REPx)",
            "非 replaceFirst → 全文字面量替换（仅替换 `(`，区别于旧「返回原文」）"
        );
    }

    // ─── [P2-6a | 台账 0917] get_elements 链内模板段 → 后续 JS 结果线程 ─────

    /// 链内模板段（get_strings 模板语义移植到 getElements 链）：
    /// `{{baseUrl}}chapters@js:result` 中模板段回填的字面结果作为后续 JS 步
    /// 的前序结果（`globalThis.result`），而非元素列表。
    #[test]
    fn test_get_elements_chain_template_segment_threads_to_js() {
        use std::sync::Arc;
        let executor = Arc::new(ScriptedJsExecutor::new(vec![
            ("baseUrl", "https://m.example.com/"),
            ("result", "https://m.example.com/chapters"),
        ]));
        let rule = AnalyzeRule::with_js_executor(String::new(), String::new(), executor.clone());
        let out = rule.get_elements("{{baseUrl}}chapters@js:result").unwrap();
        assert_eq!(
            out,
            vec!["https://m.example.com/chapters"],
            "模板段字面结果作为 JS 步前序结果"
        );
        // 模板段回填的字面结果须线程进后续 JS 步的 globalThis.result
        let calls = executor.calls();
        let result_call = calls
            .iter()
            .find(|c| c.ends_with("(\"result\")"))
            .expect("result JS 步应被执行");
        assert!(
            result_call.contains("globalThis.result = \"https://m.example.com/chapters\";"),
            "模板段结果须作为后续 JS 的 result 注入: {result_call}"
        );
        assert_eq!(calls.len(), 2, "baseUrl 回填 + result 步 共 2 次 JS 执行");
    }

    /// JS+模板段+JS 交错的 flush 顺序：模板段前累积的 JS 步先按批次 flush
    /// （payload=元素列表 JSON），模板段回填基准才是 JS 输出；末段 JS 取模板
    /// 段字面结果为前序结果。
    #[test]
    fn test_get_elements_chain_js_template_js_flush_order() {
        use std::sync::Arc;
        let executor = Arc::new(ScriptedJsExecutor::new(vec![
            ("buildA", "A1"),
            ("baseUrl", "https://m.example.com/"),
            ("buildB", "B2"),
        ]));
        let rule = AnalyzeRule::with_js_executor(String::new(), String::new(), executor.clone());
        let out = rule
            .get_elements("<js>buildA</js>\n{{baseUrl}}chapters<js>buildB</js>")
            .unwrap();
        assert_eq!(out, vec!["B2"], "末段 JS 结果作为最终元素: {out:?}");
        let calls = executor.calls();
        // 模板段前的 buildA 先 flush（payload=空元素列表 JSON `[]`）
        let a = calls
            .iter()
            .find(|c| c.ends_with("(\"buildA\")"))
            .expect("buildA 步应被执行");
        assert!(
            a.contains("globalThis.result = \"[]\";"),
            "模板段前 JS 步以元素列表（空 → []）为 result flush: {a}"
        );
        // 模板段之后 buildB 取模板字面结果
        let b = calls
            .iter()
            .find(|c| c.ends_with("(\"buildB\")"))
            .expect("buildB 步应被执行");
        assert!(
            b.contains("globalThis.result = \"https://m.example.com/chapters\";"),
            "模板段字面结果须线程进 buildB 的 result: {b}"
        );
        assert_eq!(
            calls.len(),
            3,
            "buildA / baseUrl 回填 / buildB 共 3 次 JS 执行"
        );
    }

    // ─── [P2-6d | 台账 0917] 模板命中时 JS 表达式参数仅执行一次 ─────────────

    /// 模板命中（template_shape）时跳过顶层 expand_js_refs（模板路径会再执行
    /// 同一 JS 表达式参数），故 `{{js}}后缀` 的 JS 表达式参数**恰好执行 1 次**
    /// （此前 2 次）。含空结果场景（JS 返回空串 → 参数回填为空，仍只 1 次）。
    #[test]
    fn test_template_hit_js_param_executes_once() {
        use std::sync::Arc;
        // 非空结果：JS 恰好 1 次
        let executor = Arc::new(CountingJsExecutor::new("https://m.example.com/"));
        let rule = AnalyzeRule::with_js_executor(String::new(), String::new(), executor.clone());
        let out = rule.get_strings("{{baseUrl}}chapters").unwrap();
        assert_eq!(
            out,
            vec!["https://m.example.com/chapters"],
            "模板回填 + 后缀: {out:?}"
        );
        assert_eq!(
            executor.call_count(),
            1,
            "P2-6d 模板命中须跳过顶层展开，JS 参数仅执行 1 次"
        );
        // 空结果：JS 返回空串 → 参数回填为空 → 仅剩后缀，仍恰好 1 次
        let executor = Arc::new(CountingJsExecutor::new(""));
        let rule = AnalyzeRule::with_js_executor(String::new(), String::new(), executor.clone());
        let out = rule.get_strings("{{baseUrl}}chapters").unwrap();
        assert_eq!(
            out,
            vec!["chapters"],
            "空 JS 结果 → 参数为空仅剩后缀: {out:?}"
        );
        assert_eq!(executor.call_count(), 1, "空结果场景 JS 仍仅执行 1 次");
    }

    // ─── [P2-6c | 台账 0917] 单跨度 JS 表达式参数 + 后缀 → 模板字面返回 ─────

    /// 新龙小说类 `{{baseUrl}}catalog/`（526 源 8 条 tocUrl 后缀形态）：单跨度
    /// JS 表达式参数带非空后缀 → 对齐上游 `SourceRule.init`（首个 `{{` 位于段首
    /// → Mode.Regex，makeUpRule 回填后 `else -> rule` 字面返回），不再展开后
    /// 当选择器解析取空（旧 G11）。
    #[test]
    fn test_js_expr_single_span_with_suffix_is_template() {
        use std::sync::Arc;
        let rule = AnalyzeRule::with_js_executor(
            String::new(),
            String::new(),
            Arc::new(MockJsExecutor {
                result: "https://m.xlxs.com/".to_string(),
            }),
        );
        let out = rule.get_strings("{{baseUrl}}catalog/").unwrap();
        assert_eq!(
            out,
            vec!["https://m.xlxs.com/catalog/"],
            "P2-6c 单跨度 JS 表达式参数带后缀须字面返回（非选择器取空）: {out:?}"
        );
    }

    // ─── [P2-6f1 | 台账 0917] 链段模板判定域 = 顶层拆分后核心 ──────────────

    /// 链段模板判定统一为**顶层拆分后提取核心**（与 P0-2 一致）：
    /// `{{sel()}}##x##y` 整段（旧判定）会因 `##` 规格后缀判为模板，但拆分后
    /// 核心 `{{sel()}}` 是 G11 例外（整规则恰为单个 JS 表达式跨度、无包装）
    /// → 判否（非模板）。本测试锁定判定域边界。
    #[test]
    fn test_chain_template_judgment_uses_post_split_core() {
        let whole = "{{sel()}}##x##y";
        // 整段判定（修复前口径）：单跨度 JS 表达式参数 + 非空后缀 → 误判模板
        assert!(
            single_step_template_literal(whole),
            "整段判定：后缀 ##x##y 非空 → 判模板（旧口径）"
        );
        // 拆分后核心判定（P2-6f1 口径）：G11 无包装单跨度 → 判否
        let (core, spec) = split_hash_replace(whole);
        assert_eq!(core, "{{sel()}}", "核心 = 顶层拆分后提取核心");
        assert!(spec.is_some(), "## 规格存在");
        assert!(
            !single_step_template_literal(&core),
            "核心判定：G11 无包装单跨度 → 非模板（P2-6f1）"
        );
    }

    // ─── [P2-6f4 | 台账 0917] 已闭合 {{…}} 跨度内的 JS 标记是参数文本 ──────

    // ─── [P2-9 ③] 全局变量兜底读取器（get 最后 resort）──────────────────────

    /// 全局读取器是进程级状态：注册/复位类测试串行化，避免与同 crate 其它
    /// 调 `get()` 的测试并发交错（读取器按 key 命中，key 用独立前缀）
    static GLOBAL_READER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// P2-9 ③：`@get:{k}` 本地未命中 → 兜底读全局 store（FFI 层注入的
    /// 读取器）；本地有值时优先级不变（本地恒胜）；未注册读取器时维持
    /// 修复前行为（空串）。
    #[test]
    fn test_get_falls_back_to_global_reader() {
        let _lock = GLOBAL_READER_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        // 模拟 FFI 层接线：全局 store 读取器（命中 p29_global_k → 固定值）
        set_global_variable_reader(Some(std::sync::Arc::new(|key: &str| -> Option<String> {
            (key == "p29_global_k").then(|| "p29_global_v".to_string())
        })));
        struct ResetReader;
        impl Drop for ResetReader {
            fn drop(&mut self) {
                set_global_variable_reader(None);
            }
        }
        let _reset = ResetReader;

        // 本地变量表为空 → 兜底命中全局值
        let analyzer =
            AnalyzeRule::new("<div>x</div>".to_string(), "http://example.com".to_string());
        assert_eq!(analyzer.get("p29_global_k"), "p29_global_v");
        // 读取器未提供的 key → 空串（修复前语义不变）
        assert_eq!(analyzer.get("p29_never_exists"), "");
        // 本地优先级不变：本地变量非空恒胜全局 store
        analyzer.put("p29_global_k", "local_v");
        assert_eq!(analyzer.get("p29_global_k"), "local_v");

        // 复位读取器 → 本地未命中不再兜底（修复前行为）
        set_global_variable_reader(None);
        let analyzer2 = AnalyzeRule::new(String::new(), String::new());
        assert_eq!(analyzer2.get("p29_global_k"), "");
    }

    /// 已闭合 `{{…}}` 跨度**内**的 `@js:`/`<js>` 是 JS 表达式参数文本（模板
    /// 参数内容），不是链标记——`rule_has_js_chain` 须跳过跨度内出现位置，仅
    /// 跨度外出现才算含 JS 段（P0-1 门不应被此类字面量误触发）。
    #[test]
    fn test_rule_has_js_chain_skips_markers_inside_spans() {
        assert!(rule_has_js_chain("@js:code"), "顶层 @js: → JS 链");
        assert!(rule_has_js_chain("<js>code</js>"), "顶层 <js> → JS 链");
        assert!(rule_has_js_chain("x<JS>y</JS>"), "<js> 大小写不敏感");
        assert!(
            !rule_has_js_chain("{{a@js:b}}"),
            "跨度内 @js: 是参数文本，非链标记"
        );
        assert!(
            !rule_has_js_chain("{{<js>x</js>}}"),
            "跨度内 <js> 是参数文本，非链标记"
        );
        assert!(rule_has_js_chain("{{a}}@js:b"), "跨度外（后）@js: → JS 链");
        assert!(
            rule_has_js_chain("{{a}}<js>x</js>"),
            "跨度外（后）<js> → JS 链"
        );
    }

    // ─── [P2-9 ④] apply_put_map 走完整 get_strings 管道（##/||/%%/多值 join）───

    /// P2-9 ④：`@put` 值上的 `##` 替换生效（旧实现单步不处理 `##`，裸串被当
    /// CSS 选择器 → 变量为空；现走完整管道 `#t@text##ab##XY` → `"XY cd XY"`）。
    #[test]
    fn test_put_map_hash_replace_full_pipeline() {
        let html = "<div id=\"t\">ab cd ab</div>";
        let analyzer = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
        let res = analyzer
            .get_strings("@put:{y:#t@text##ab##XY}@get:{y}")
            .unwrap();
        assert_eq!(analyzer.get("y"), "XY cd XY", "## 替换须在 put 值上生效");
        assert_eq!(res, vec!["XY cd XY".to_string()]);
    }

    /// P2-9 ④：`@put` 值上的 `||` 取首个非空（`#zz` 不存在 → 落到 `#a`）。
    #[test]
    fn test_put_map_or_first_nonempty() {
        let html = "<div id=\"a\">hello</div>";
        let analyzer = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
        let res = analyzer
            .get_strings("@put:{x:#zz@text||#a@text}@get:{x}")
            .unwrap();
        assert_eq!(analyzer.get("x"), "hello", "|| 须取首个非空组");
        assert_eq!(res, vec!["hello".to_string()]);
    }

    /// P2-9 ④：`@put` 值多值按上游 join 语义以 `\n` 连接（旧 `.next()` 仅取首值）。
    #[test]
    fn test_put_map_multi_value_join() {
        let html = "<p class=\"a\">a1</p><p class=\"a\">a2</p>";
        let analyzer = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
        let res = analyzer.get_strings("@put:{x:.a@text}@get:{x}").unwrap();
        assert_eq!(
            analyzer.get("x"),
            "a1\na2",
            "多值须按 \\n join（对齐上游 getString）"
        );
        assert_eq!(res, vec!["a1\na2".to_string()]);
    }

    /// P2-9 ④ / P3-b：同一规则串内**并列**（sibling）的多个 `@put` 段均被
    /// 剥离并写入变量，`get_strings` 内部 `apply_put_map` 面对已剥离的规则为
    /// no-op，不会递归炸栈。
    ///
    /// 注（P3-b 改名）：原测试名 `nested_strip` 名不副实——本规则是
    /// `@put:{k:…}@put:{m:…}` **并列**两段，并非真嵌套 `@put:{a:@put:{b:…}}`。
    /// 真嵌套由 [`test_put_map_true_nested_brace_leak_registered`] 锁定。
    #[test]
    fn test_put_map_sibling_segments_strip_no_recursion() {
        // 并列 @put 段均被剥离，各自值 `#t@text` 正常求值
        let html = "<div id=\"t\">val</div>";
        let analyzer = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
        let res = analyzer
            .get_strings("@put:{k:#t@text}@put:{m:#t@text}@get:{m}")
            .unwrap();
        assert_eq!(analyzer.get("k"), "val");
        assert_eq!(analyzer.get("m"), "val");
        assert_eq!(res, vec!["val".to_string()]);
    }

    /// P3-b（登记已知限制）：**真嵌套** `@put:{a:@put:{b:…}}` 的现状锁定。
    ///
    /// 现状：剥离正则 `@put:(\{[^}]+?\})` 非贪心到**首个** `}` 为止 → 外层捕获
    /// `{a:@put:{b:…}`（内含未闭合的内层 `{`），内层 `@put` 值丢失闭合 `}`；
    /// `replace_all` 后主规则残留一个多余的 `}`（leak），后续 CSS/选择器解析
    /// 失败 → 外层值恒为空串；内层 `b` 从未写入。此行为与原版
    /// `splitPutRule` 的单层剥离一致（嵌套 map 在书源中极少见，原版同样忽略），
    /// 故登记为已知限制而非缺陷，本测试仅锁定现状防意外变更。
    #[test]
    fn test_put_map_true_nested_brace_leak_registered() {
        let html = "<div id=\"a\">va</div><div id=\"b\">vb</div>";
        let analyzer = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
        let res = analyzer
            .get_strings("@put:{a:@put:{b:#b@text}}#a@text")
            .unwrap();
        // 外层 a：值 `@put:{b:#b@text`（丢闭合 `}`）→ 内嵌剥离失败 → 按规则求值落空
        assert_eq!(analyzer.get("a"), "", "真嵌套外层值当前恒为空（已知限制）");
        // 内层 b：从未被写入变量表
        assert_eq!(analyzer.get("b"), "", "真嵌套内层键当前不写入（已知限制）");
        // 主规则残留多余 `}`（leak）→ 选择器解析失败 → 无输出
        assert!(
            res.is_empty(),
            "真嵌套主规则含 leak 大括号，解析落空: {res:?}"
        );
    }
}
