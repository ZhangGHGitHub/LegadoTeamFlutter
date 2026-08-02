//! 内容处理管线
//! 移植自 Kotlin ContentProcessor.kt (224行)
//!
//! 编排完整的内容后处理管线：
//! 去重复标题 → 段落重排 → 简繁转换 → 替换规则 → 段落缩进
//!
//! ## 替换规则引擎（P1-3 增强）
//!
//! 与 Android 原版 `RegexExtensions.kt` / `ReplaceRuleDao` 对齐，支持：
//! - `@js:` 表达式替换：`replacement` 以 `@js:` 开头时，对每个正则匹配调用
//!   JS 执行器（绑定 `result` = 当前匹配文本），以执行结果作为替换内容；
//! - Java 正则方言适配：`(?<=...)` / `(?<!...)` lookbehind、`\1` backreference、
//!   原子组等 regex crate 不支持的语法自动回退到 fancy-regex；
//!   `\uXXXX`、`\R`、`(?d)`/`(?c)`/`(?u)` 等 Java 专有语法做等价转换；
//! - 替换超时：每条规则在独立线程执行，超过 `timeoutMillisecond` 自动跳过；
//! - 作用域过滤：`scopeTitle`（仅标题）/ `scopeContent`（仅正文）/
//!   `excludeScope`（排除书名/书源）。

use std::sync::{mpsc, Arc};
use std::time::Duration;

use serde::{Deserialize, Serialize};

// ─── JS 执行器抽象 ─────────────────────────────────────────

/// 替换规则 JS 执行器抽象
///
/// 由上层注入具体实现（legado-ffi 层适配 legado-js 的 QuickJS 引擎池）。
/// legado-core 不依赖 legado-js（避免循环依赖），仅定义契约。
pub trait ReplaceJsExecutor: Send + Sync {
    /// 执行 `@js:` 替换表达式
    ///
    /// - `js_code`：去掉 `@js:` 前缀后的 JS 代码
    /// - `result`：当前正则匹配到的文本（对应 Kotlin `bindings["result"] = matcher.group()`）
    ///
    /// 返回 JS 执行结果字符串，将作为该匹配项的替换内容（字面插入，不做 `$` 展开）。
    fn eval(&self, js_code: &str, result: &str) -> Result<String, String>;
}

// ─── 作用域上下文 ──────────────────────────────────────────

/// 作用域上下文（书名 + 书源），用于 scope / excludeScope 匹配
///
/// 对应 Kotlin `ReplaceRuleDao.findEnabledByContentScope(name, origin)` 的两个参数。
#[derive(Debug, Clone, Default)]
pub struct ScopeContext {
    /// 书名（对应 DAO 的 :name）
    pub book_name: String,
    /// 书源（对应 DAO 的 :origin）
    pub book_origin: String,
}

impl ScopeContext {
    pub fn new(book_name: impl Into<String>, book_origin: impl Into<String>) -> Self {
        Self {
            book_name: book_name.into(),
            book_origin: book_origin.into(),
        }
    }
}

/// 作用域模式：标题规则 / 正文规则
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScopeMode {
    /// 标题规则（scopeTitle = true）
    Title,
    /// 正文规则（scopeContent = true）
    Content,
}

// ─── 管线配置 ──────────────────────────────────────────────

/// 处理管线配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessorConfig {
    /// 是否去除重复标题
    pub remove_duplicate_title: bool,
    /// 是否重新分段
    pub re_segment: bool,
    /// 简繁转换: None / "t2s" / "s2t"
    pub chinese_convert: Option<String>,
    /// 是否应用替换规则
    pub apply_replace_rules: bool,
    /// 段落首行缩进（空格数，0=不缩进）
    pub indent_spaces: usize,
    /// 是否去除多余空行
    pub trim_empty_lines: bool,
}

impl Default for ProcessorConfig {
    fn default() -> Self {
        Self {
            remove_duplicate_title: true,
            re_segment: true,
            chinese_convert: None,
            apply_replace_rules: true,
            indent_spaces: 2,
            trim_empty_lines: true,
        }
    }
}

/// 内容处理器
pub struct ContentProcessor {
    config: ProcessorConfig,
    /// 作用域上下文（可选）：设置后启用 scope / excludeScope 过滤
    scope_context: Option<ScopeContext>,
}

impl ContentProcessor {
    pub fn new(config: ProcessorConfig) -> Self {
        Self {
            config,
            scope_context: None,
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(ProcessorConfig::default())
    }

    /// 设置作用域上下文（启用 excludeScope 排除与 scope 匹配）
    pub fn with_scope_context(mut self, ctx: ScopeContext) -> Self {
        self.scope_context = Some(ctx);
        self
    }

    /// 获取当前配置
    pub fn config(&self) -> &ProcessorConfig {
        &self.config
    }

    /// 执行完整处理管线（无 JS 执行器版本，`@js:` 规则将被跳过）
    pub fn process(
        &self,
        content: &str,
        chapter_name: &str,
        replace_rules: &[ReplaceRuleEntry],
    ) -> String {
        self.process_with_js(content, chapter_name, replace_rules, None)
    }

    /// 执行完整处理管线（增强版：可注入 JS 执行器以支持 `@js:` 替换表达式）
    pub fn process_with_js(
        &self,
        content: &str,
        chapter_name: &str,
        replace_rules: &[ReplaceRuleEntry],
        js_executor: Option<Arc<dyn ReplaceJsExecutor>>,
    ) -> String {
        let mut result = content.to_string();

        // Step 1: 去除重复标题
        if self.config.remove_duplicate_title {
            result = self.remove_duplicate_title(&result, chapter_name);
        }

        // Step 2: 段落重排
        if self.config.re_segment {
            result = self.re_segment(&result, chapter_name);
        }

        // Step 3: 简繁转换
        if let Some(ref direction) = self.config.chinese_convert {
            result = self.chinese_convert(&result, direction);
        }

        // Step 4: 替换规则
        if self.config.apply_replace_rules && !replace_rules.is_empty() {
            result = self.apply_replace_rules(&result, replace_rules, js_executor);
        }

        // Step 5: 段落缩进
        if self.config.indent_spaces > 0 {
            result = self.add_indent(&result, self.config.indent_spaces);
        }

        // Step 6: 去除多余空行
        if self.config.trim_empty_lines {
            result = self.trim_empty_lines(&result);
        }

        result
    }

    /// 执行处理并返回统计信息
    pub fn process_with_stats(
        &self,
        content: &str,
        chapter_name: &str,
        replace_rules: &[ReplaceRuleEntry],
    ) -> (String, ProcessResult) {
        let original_length = content.len();
        let processed = self.process(content, chapter_name, replace_rules);
        let paragraphs_count = processed.lines().filter(|l| !l.trim().is_empty()).count();
        let rules_applied = if self.config.apply_replace_rules {
            replace_rules.len()
        } else {
            0
        };

        let stats = ProcessResult {
            original_length,
            processed_length: processed.len(),
            paragraphs_count,
            rules_applied,
        };
        (processed, stats)
    }

    /// 去除重复标题（章节内容开头的与标题相同的文本）
    fn remove_duplicate_title(&self, content: &str, chapter_name: &str) -> String {
        if chapter_name.is_empty() {
            return content.to_string();
        }
        let trimmed = content.trim_start();
        if let Some(after) = trimmed.strip_prefix(chapter_name) {
            // 去除标题后紧跟的空白和标点
            let after =
                after.trim_start_matches(|c: char| c.is_whitespace() || c == '\n' || c == '\r');
            after.to_string()
        } else {
            content.to_string()
        }
    }

    /// 段落重排（委托 content_help 模块）
    fn re_segment(&self, content: &str, chapter_name: &str) -> String {
        crate::content_help::re_segment(content, chapter_name)
    }

    /// 简繁转换
    fn chinese_convert(&self, content: &str, direction: &str) -> String {
        match direction {
            "t2s" => Self::traditional_to_simplified(content),
            "s2t" => Self::simplified_to_traditional(content),
            _ => content.to_string(),
        }
    }

    /// 繁体转简体
    fn traditional_to_simplified(content: &str) -> String {
        crate::chinese_convert::traditional_to_simplified(content)
    }

    /// 简体转繁体
    fn simplified_to_traditional(content: &str) -> String {
        crate::chinese_convert::simplified_to_traditional(content)
    }

    /// 应用替换规则（正文管线入口）
    fn apply_replace_rules(
        &self,
        content: &str,
        rules: &[ReplaceRuleEntry],
        js_executor: Option<Arc<dyn ReplaceJsExecutor>>,
    ) -> String {
        run_replace_rules(
            content,
            rules,
            js_executor,
            ScopeMode::Content,
            self.scope_context.as_ref(),
        )
    }

    /// 段落首行缩进
    fn add_indent(&self, content: &str, spaces: usize) -> String {
        // 使用全角空格进行缩进（与 Kotlin 版 ReadBookConfig.paragraphIndent 一致）
        let indent: String = " ".repeat(spaces);
        content
            .lines()
            .map(|line| {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    String::new()
                } else if trimmed.starts_with("  ") || trimmed.starts_with('\t') {
                    // 已有缩进，不重复添加
                    trimmed.to_string()
                } else {
                    format!("{}{}", indent, trimmed)
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// 去除多余空行（连续 3 个以上空行合并为 2 个）
    fn trim_empty_lines(&self, content: &str) -> String {
        let mut result = Vec::new();
        let mut empty_count = 0;

        for line in content.lines() {
            if line.trim().is_empty() {
                empty_count += 1;
                if empty_count <= 2 {
                    result.push(line.to_string());
                }
            } else {
                empty_count = 0;
                result.push(line.to_string());
            }
        }
        result.join("\n")
    }
}

// ─── 替换规则引擎（自由函数 API）───────────────────────────

/// 应用正文替换规则（增强版）
///
/// 仅应用 `scope_content = true` 的规则；支持 `@js:` 表达式替换、
/// Java 正则方言适配与逐规则超时保护。`js_executor` 为 `None` 时
/// `@js:` 规则被安全跳过。
pub fn apply_replace_rules(
    content: &str,
    rules: &[ReplaceRuleEntry],
    js_executor: Option<Arc<dyn ReplaceJsExecutor>>,
) -> String {
    run_replace_rules(content, rules, js_executor, ScopeMode::Content, None)
}

/// 应用标题替换规则（对应 Kotlin `titleReplaceRules` / `getDisplayTitle`）
///
/// 仅应用 `scope_title = true` 的规则。
pub fn apply_title_replace_rules(
    title: &str,
    rules: &[ReplaceRuleEntry],
    js_executor: Option<Arc<dyn ReplaceJsExecutor>>,
) -> String {
    run_replace_rules(title, rules, js_executor, ScopeMode::Title, None)
}

/// 按正文作用域过滤规则（对应 Kotlin `ReplaceRuleDao.findEnabledByContentScope`）
pub fn filter_content_rules<'a>(
    rules: &'a [ReplaceRuleEntry],
    ctx: &ScopeContext,
) -> Vec<&'a ReplaceRuleEntry> {
    rules
        .iter()
        .filter(|r| scope_allows(r, ScopeMode::Content, Some(ctx)))
        .collect()
}

/// 按标题作用域过滤规则（对应 Kotlin `ReplaceRuleDao.findEnabledByTitleScope`）
pub fn filter_title_rules<'a>(
    rules: &'a [ReplaceRuleEntry],
    ctx: &ScopeContext,
) -> Vec<&'a ReplaceRuleEntry> {
    rules
        .iter()
        .filter(|r| scope_allows(r, ScopeMode::Title, Some(ctx)))
        .collect()
}

/// 规则作用域判定（enabled + scopeTitle/scopeContent + scope + excludeScope）
fn scope_allows(rule: &ReplaceRuleEntry, mode: ScopeMode, ctx: Option<&ScopeContext>) -> bool {
    if !rule.is_enabled {
        return false;
    }
    let in_scope = match mode {
        ScopeMode::Title => rule.scope_title,
        ScopeMode::Content => rule.scope_content,
    };
    if !in_scope {
        return false;
    }
    if let Some(ctx) = ctx {
        if !scope_matches(rule.scope.as_deref(), ctx) {
            return false;
        }
        if is_excluded(rule.exclude_scope.as_deref(), ctx) {
            return false;
        }
    }
    true
}

/// scope 匹配（对应 DAO：`scope LIKE %name% OR scope LIKE %origin% OR scope IS NULL OR scope = ''`）
fn scope_matches(scope: Option<&str>, ctx: &ScopeContext) -> bool {
    match scope {
        None => true,
        Some("") => true,
        Some(s) => s.contains(&ctx.book_name) || s.contains(&ctx.book_origin),
    }
}

/// excludeScope 排除判定（对应 DAO：`excludeScope IS NULL OR (NOT LIKE %name% AND NOT LIKE %origin%)`）
fn is_excluded(exclude_scope: Option<&str>, ctx: &ScopeContext) -> bool {
    match exclude_scope {
        None => false,
        Some("") => false,
        Some(s) => s.contains(&ctx.book_name) || s.contains(&ctx.book_origin),
    }
}

/// 顺序应用规则（含作用域过滤 + 逐规则超时保护）
fn run_replace_rules(
    content: &str,
    rules: &[ReplaceRuleEntry],
    js_executor: Option<Arc<dyn ReplaceJsExecutor>>,
    mode: ScopeMode,
    ctx: Option<&ScopeContext>,
) -> String {
    let mut result = content.to_string();
    for rule in rules {
        if rule.pattern.is_empty() || !scope_allows(rule, mode, ctx) {
            continue;
        }
        result = apply_rule_with_timeout(&result, rule, &js_executor);
    }
    result
}

/// 在独立线程中应用单条规则，超时则跳过（保留原内容）
///
/// 对应 Kotlin `RegexExtensions.replace` 的 `onTimeout` 保护：
/// Android 版超时后禁用规则并重启应用；Rust 版采取保守策略——
/// 跳过该规则、保持内容不变，避免单条病态规则拖垮整个管线。
fn apply_rule_with_timeout(
    content: &str,
    rule: &ReplaceRuleEntry,
    js_executor: &Option<Arc<dyn ReplaceJsExecutor>>,
) -> String {
    let timeout_ms = rule.valid_timeout_millisecond() as u64;
    let content_owned = content.to_string();
    let rule_owned = rule.clone();
    let js_owned = js_executor.clone();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let replaced = apply_single_rule(&content_owned, &rule_owned, js_owned.as_deref());
        let _ = tx.send(replaced);
    });
    match rx.recv_timeout(Duration::from_millis(timeout_ms)) {
        // 替换成功
        Ok(Ok(new_content)) => new_content,
        // 规则执行出错（正则语法错误 / JS 执行失败）→ 跳过该规则
        Ok(Err(_e)) => content.to_string(),
        // 超时 → 跳过该规则
        Err(_timeout) => content.to_string(),
    }
}

/// 应用单条替换规则
///
/// - 非正则规则：字面量替换（与 Kotlin `mContent.replace(pattern, replacement)` 一致）；
/// - 正则规则 + `@js:` 替换内容：逐匹配调用 JS 执行器；
/// - 正则规则 + 普通替换内容：`$n` 组引用替换（Java/Rust 语法一致）。
fn apply_single_rule(
    content: &str,
    rule: &ReplaceRuleEntry,
    js_executor: Option<&dyn ReplaceJsExecutor>,
) -> Result<String, String> {
    if !rule.is_regex {
        return Ok(content.replace(&rule.pattern, &rule.replacement));
    }
    let compiled = compile_regex(&rule.pattern)?;
    match strip_js_prefix(&rule.replacement) {
        Some(js_code) => {
            // @js: 表达式替换（对应 Kotlin RegexExtensions.kt 的 isJs 分支）
            let executor = js_executor
                .ok_or_else(|| "@js: 替换表达式需要 JS 执行器，当前未注入".to_string())?;
            replace_with_js(&compiled, content, js_code, executor)
        }
        None => Ok(compiled.replace_all(content, &rule.replacement)),
    }
}

/// 判断替换内容是否为 `@js:` 表达式并提取 JS 代码
///
/// 对应 Kotlin：`replacement.startsWith("@js:")` → `replacement.substring(4)`
fn strip_js_prefix(replacement: &str) -> Option<&str> {
    replacement.strip_prefix("@js:")
}

/// 逐匹配执行 JS 并拼接结果
///
/// 对应 Kotlin `matcher.find()` 循环 + `bindings["result"] = matcher.group()`。
/// JS 结果字面插入（等价于 Kotlin `quoteReplacementJs` 转义后的 appendReplacement）。
fn replace_with_js(
    compiled: &CompiledRegex,
    content: &str,
    js_code: &str,
    executor: &dyn ReplaceJsExecutor,
) -> Result<String, String> {
    let ranges = compiled.find_ranges(content)?;
    let mut out = String::with_capacity(content.len());
    let mut last = 0;
    for (start, end) in ranges {
        out.push_str(&content[last..start]);
        let matched = &content[start..end];
        let js_result = executor.eval(js_code, matched)?;
        out.push_str(&js_result);
        last = end;
    }
    out.push_str(&content[last..]);
    Ok(out)
}

// ─── Java 正则方言适配 ─────────────────────────────────────

/// 编译后的正则（双引擎）：优先 regex crate（线性时间），
/// regex crate 不支持的 Java 方言语法回退到 fancy-regex。
enum CompiledRegex {
    /// regex crate 编译结果（高性能，不支持 lookaround/backreference）
    Fast(regex::Regex),
    /// fancy-regex 编译结果（支持 lookbehind/lookahead/backreference/原子组）
    Fancy(fancy_regex::Regex),
}

impl CompiledRegex {
    /// 收集所有匹配区间（用于 @js: 逐匹配替换）
    fn find_ranges(&self, content: &str) -> Result<Vec<(usize, usize)>, String> {
        match self {
            CompiledRegex::Fast(re) => Ok(re
                .find_iter(content)
                .map(|m| (m.start(), m.end()))
                .collect()),
            CompiledRegex::Fancy(re) => {
                let mut ranges = Vec::new();
                for m in re.find_iter(content) {
                    let m = m.map_err(|e| e.to_string())?;
                    ranges.push((m.start(), m.end()));
                }
                Ok(ranges)
            }
        }
    }

    /// 全量替换（`$n` 组引用语法，与 Java Matcher.appendReplacement 对齐）
    fn replace_all(&self, content: &str, replacement: &str) -> String {
        match self {
            CompiledRegex::Fast(re) => re.replace_all(content, replacement).into_owned(),
            CompiledRegex::Fancy(re) => re.replace_all(content, replacement).into_owned(),
        }
    }
}

/// 编译正则：Java 方言适配 → regex crate 优先 → fancy-regex 回退
fn compile_regex(pattern: &str) -> Result<CompiledRegex, String> {
    let adapted = adapt_java_regex(pattern);
    if let Ok(re) = regex::Regex::new(&adapted) {
        return Ok(CompiledRegex::Fast(re));
    }
    // regex crate 编译失败（lookbehind / backreference 等）→ 回退 fancy-regex
    fancy_regex::Regex::new(&adapted)
        .map(CompiledRegex::Fancy)
        .map_err(|e| e.to_string())
}

/// Java 正则方言适配：将 Java `Pattern` 专有语法转换为 Rust 正则等价形式
///
/// 处理的差异：
/// - `\uXXXX`（Java Unicode 转义）→ `\x{XXXX}`（Rust 语法）；
/// - `\R`（Java 任意 Unicode 换行）→ 显式换行字符交替组；
/// - `(?d)` UNIX_LINES / `(?c)` CANON_EQ / `(?u)` UNICODE_CHARACTER_CLASS
///   内联标志：Rust 不支持，直接移除（行为差异可忽略）；
/// - lookbehind `(?<=...)` / `(?<!...)`、backreference `\1`、原子组 `(?>...)`
///   保持原样，由 fancy-regex 回退路径支持。
pub fn adapt_java_regex(pattern: &str) -> String {
    let chars: Vec<char> = pattern.chars().collect();
    let len = chars.len();
    let mut out = String::with_capacity(pattern.len());
    let mut i = 0;
    while i < len {
        let c = chars[i];
        if c == '\\' && i + 1 < len {
            let next = chars[i + 1];
            match next {
                // Java \uXXXX → Rust \x{XXXX}
                'u' if i + 5 < len && chars[i + 2..i + 6].iter().all(|h| h.is_ascii_hexdigit()) => {
                    let hex: String = chars[i + 2..i + 6].iter().collect();
                    out.push_str("\\x{");
                    out.push_str(&hex);
                    out.push('}');
                    i += 6;
                }
                // Java \R（任意 Unicode 换行序列）→ 显式字符类
                'R' => {
                    out.push_str(r"(?:\r\n|[\n\r\u{000B}\u{000C}\u{0085}\u{2028}\u{2029}])");
                    i += 2;
                }
                // 其余转义原样保留
                _ => {
                    out.push('\\');
                    out.push(next);
                    i += 2;
                }
            }
        } else if c == '('
            && i + 3 < len
            && chars[i + 1] == '?'
            && matches!(chars[i + 2], 'd' | 'c' | 'u')
            && chars[i + 3] == ')'
        {
            // 移除 Rust 不支持的内联标志：(?d) / (?c) / (?u)
            i += 4;
        } else {
            out.push(c);
            i += 1;
        }
    }
    out
}

// ─── 替换规则条目 ──────────────────────────────────────────

/// 替换规则条目（供 ContentProcessor 使用，包含作用域与超时字段）
#[derive(Debug, Clone)]
pub struct ReplaceRuleEntry {
    /// 规则名称（用于日志/调试）
    pub name: String,
    /// 匹配模式（正则或字面量）
    pub pattern: String,
    /// 替换内容（以 `@js:` 开头时为 JS 表达式）
    pub replacement: String,
    /// 生效书籍范围（None/空 = 全局；否则按 书名/书源 子串匹配）
    pub scope: Option<String>,
    /// 是否作用于标题
    pub scope_title: bool,
    /// 是否作用于正文
    pub scope_content: bool,
    /// 排除范围（包含 书名/书源 时规则不生效）
    pub exclude_scope: Option<String>,
    /// 是否启用
    pub is_enabled: bool,
    /// 是否正则模式
    pub is_regex: bool,
    /// 超时时间（毫秒，<=0 时按 3000 处理）
    pub timeout_millisecond: i64,
}

impl Default for ReplaceRuleEntry {
    fn default() -> Self {
        Self {
            name: String::new(),
            pattern: String::new(),
            replacement: String::new(),
            scope: None,
            scope_title: false,
            scope_content: true,
            exclude_scope: None,
            is_enabled: true,
            is_regex: false,
            timeout_millisecond: 3000,
        }
    }
}

impl ReplaceRuleEntry {
    /// 从 models::ReplaceRule 转换
    pub fn from_replace_rule(rule: &crate::models::ReplaceRule) -> Self {
        Self {
            name: rule.name.clone(),
            pattern: rule.pattern.clone(),
            replacement: rule.replacement.clone(),
            scope: rule.scope.clone(),
            scope_title: rule.scope_title,
            scope_content: rule.scope_content,
            exclude_scope: rule.exclude_scope.clone(),
            is_enabled: rule.is_enabled,
            is_regex: rule.is_regex,
            timeout_millisecond: rule.timeout_millisecond,
        }
    }

    /// 批量从 models::ReplaceRule 转换
    pub fn from_replace_rules(rules: &[crate::models::ReplaceRule]) -> Vec<Self> {
        rules.iter().map(Self::from_replace_rule).collect()
    }

    /// 有效超时时间（对应 Kotlin `getValidTimeoutMillisecond`：<=0 → 3000）
    pub fn valid_timeout_millisecond(&self) -> i64 {
        if self.timeout_millisecond <= 0 {
            3000
        } else {
            self.timeout_millisecond
        }
    }
}

/// 处理结果统计
#[derive(Debug, Clone)]
pub struct ProcessResult {
    pub original_length: usize,
    pub processed_length: usize,
    pub paragraphs_count: usize,
    pub rules_applied: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── 测试辅助 ──────────────────────────────────────────

    fn no_rules() -> Vec<ReplaceRuleEntry> {
        vec![]
    }

    fn text_rule(pattern: &str, replacement: &str) -> ReplaceRuleEntry {
        ReplaceRuleEntry {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            is_regex: false,
            ..ReplaceRuleEntry::default()
        }
    }

    fn regex_rule(pattern: &str, replacement: &str) -> ReplaceRuleEntry {
        ReplaceRuleEntry {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            is_regex: true,
            ..ReplaceRuleEntry::default()
        }
    }

    /// 无处理配置（所有步骤关闭）
    fn noop_config() -> ProcessorConfig {
        ProcessorConfig {
            remove_duplicate_title: false,
            re_segment: false,
            chinese_convert: None,
            apply_replace_rules: false,
            indent_spaces: 0,
            trim_empty_lines: false,
        }
    }

    /// Mock JS 执行器：
    /// - 代码含 "fail" → 返回错误
    /// - 代码含 "upper" → 匹配文本转大写
    /// - 其他 → 返回 `<匹配文本>`
    struct MockJs;

    impl ReplaceJsExecutor for MockJs {
        fn eval(&self, code: &str, result: &str) -> Result<String, String> {
            if code.contains("fail") {
                return Err("mock js error".to_string());
            }
            if code.contains("upper") {
                return Ok(result.to_uppercase());
            }
            Ok(format!("<{}>", result))
        }
    }

    fn mock_js() -> Option<Arc<dyn ReplaceJsExecutor>> {
        Some(Arc::new(MockJs))
    }

    /// 慢速 JS 执行器（用于超时测试）
    struct SlowJs;

    impl ReplaceJsExecutor for SlowJs {
        fn eval(&self, _code: &str, result: &str) -> Result<String, String> {
            std::thread::sleep(Duration::from_millis(500));
            Ok(result.to_string())
        }
    }

    // ─── 既有管线测试 ──────────────────────────────────────

    #[test]
    fn test_default_pipeline() {
        let processor = ContentProcessor::with_defaults();
        let content = "第一章 开始\n这是正文内容。\n第二段内容。";
        let result = processor.process(content, "第一章 开始", &no_rules());
        // 标题被去除，段落被缩进
        assert!(!result.starts_with("第一章 开始"));
        assert!(result.contains("这是正文内容。"));
        assert!(result.contains("第二段内容。"));
    }

    #[test]
    fn test_remove_duplicate_title() {
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一章 测试\n正文内容";
        let result = processor.process(content, "第一章 测试", &no_rules());
        assert_eq!(result, "正文内容");
    }

    #[test]
    fn test_remove_duplicate_title_no_match() {
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "这是正文内容";
        let result = processor.process(content, "第一章 测试", &no_rules());
        assert_eq!(result, "这是正文内容");
    }

    #[test]
    fn test_remove_duplicate_title_empty_chapter_name() {
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "这是正文内容";
        let result = processor.process(content, "", &no_rules());
        assert_eq!(result, "这是正文内容");
    }

    #[test]
    fn test_replace_rules_text() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("广告", ""), text_rule("test", "测试")];
        let content = "这是广告内容test";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "这是内容测试");
    }

    #[test]
    fn test_replace_rules_regex() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![regex_rule(r"\d+", "NUM")];
        let content = "abc 123 def 456";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "abc NUM def NUM");
    }

    #[test]
    fn test_replace_rules_regex_group_ref() {
        // $n 组引用替换（Java/Rust 语法一致）
        let rules = vec![regex_rule(r"(\w+)@(\w+)", "$2.$1")];
        let result = apply_replace_rules("user@host", &rules, None);
        assert_eq!(result, "host.user");
    }

    #[test]
    fn test_replace_rules_invalid_regex_skipped() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![regex_rule(r"[invalid", "X")];
        let content = "hello world";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_replace_rules_empty_pattern_skipped() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("", "X")];
        let content = "hello";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_disabled_rule_skipped() {
        let rules = vec![ReplaceRuleEntry {
            pattern: "广告".to_string(),
            replacement: String::new(),
            is_regex: false,
            is_enabled: false,
            ..ReplaceRuleEntry::default()
        }];
        let result = apply_replace_rules("广告内容", &rules, None);
        assert_eq!(result, "广告内容");
    }

    #[test]
    fn test_add_indent() {
        let config = ProcessorConfig {
            indent_spaces: 2,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一段\n第二段";
        let result = processor.process(content, "", &no_rules());
        assert!(result.starts_with("  第一段"));
        assert!(result.contains("  第二段"));
    }

    #[test]
    fn test_add_indent_preserves_existing() {
        let config = ProcessorConfig {
            indent_spaces: 2,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "  已有缩进\n无缩进";
        let result = processor.process(content, "", &no_rules());
        // 已有全角空格缩进的不重复添加
        assert!(result.contains("已有缩进"));
        assert!(result.contains("  无缩进"));
    }

    #[test]
    fn test_trim_empty_lines() {
        let config = ProcessorConfig {
            trim_empty_lines: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一段\n\n\n\n\n第二段";
        let result = processor.process(content, "", &no_rules());
        // 连续5个空行应合并为2个
        let empty_count = result.lines().filter(|l| l.trim().is_empty()).count();
        assert_eq!(empty_count, 2);
    }

    #[test]
    fn test_trim_empty_lines_preserves_normal() {
        let config = ProcessorConfig {
            trim_empty_lines: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一段\n\n第二段";
        let result = processor.process(content, "", &no_rules());
        // 单个空行保留
        assert_eq!(result, "第一段\n\n第二段");
    }

    #[test]
    fn test_empty_content() {
        let processor = ContentProcessor::with_defaults();
        let result = processor.process("", "章节", &no_rules());
        assert!(result.is_empty() || result.trim().is_empty());
    }

    #[test]
    fn test_config_switches() {
        // 所有开关关闭时内容不变
        let processor = ContentProcessor::new(noop_config());
        let content = "第一章\n正文内容";
        let result = processor.process(content, "第一章", &no_rules());
        assert_eq!(result, content);
    }

    #[test]
    fn test_chinese_convert_t2s() {
        let config = ProcessorConfig {
            chinese_convert: Some("t2s".to_string()),
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "測試內容";
        let result = processor.process(content, "", &no_rules());
        // 繁体转简体
        assert_eq!(result, "测试内容");
    }

    #[test]
    fn test_chinese_convert_s2t() {
        let config = ProcessorConfig {
            chinese_convert: Some("s2t".to_string()),
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "测试内容";
        let result = processor.process(content, "", &no_rules());
        // 简体转繁体
        assert_eq!(result, "測試內容");
    }

    #[test]
    fn test_process_with_stats() {
        let config = ProcessorConfig {
            re_segment: false,
            ..ProcessorConfig::default()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("a", "b")];
        let content = "段落一\n段落二\n段落三";
        let (result, stats) = processor.process_with_stats(content, "", &rules);
        assert_eq!(stats.original_length, content.len());
        assert_eq!(stats.processed_length, result.len());
        assert_eq!(stats.paragraphs_count, 3);
        assert_eq!(stats.rules_applied, 1);
    }

    #[test]
    fn test_replace_rule_entry_from_model() {
        let rule = crate::models::ReplaceRule {
            pattern: "hello".to_string(),
            replacement: "world".to_string(),
            is_regex: false,
            ..crate::models::ReplaceRule::default()
        };
        let entry = ReplaceRuleEntry::from_replace_rule(&rule);
        assert_eq!(entry.pattern, "hello");
        assert_eq!(entry.replacement, "world");
        assert!(!entry.is_regex);
    }

    #[test]
    fn test_from_replace_rule_maps_all_fields() {
        let rule = crate::models::ReplaceRule {
            name: "规则A".to_string(),
            pattern: "p".to_string(),
            replacement: "@js:result".to_string(),
            scope: Some("书籍A".to_string()),
            scope_title: true,
            scope_content: false,
            exclude_scope: Some("书籍B".to_string()),
            is_enabled: false,
            is_regex: true,
            timeout_millisecond: 1500,
            ..crate::models::ReplaceRule::default()
        };
        let entry = ReplaceRuleEntry::from_replace_rule(&rule);
        assert_eq!(entry.name, "规则A");
        assert_eq!(entry.scope.as_deref(), Some("书籍A"));
        assert!(entry.scope_title);
        assert!(!entry.scope_content);
        assert_eq!(entry.exclude_scope.as_deref(), Some("书籍B"));
        assert!(!entry.is_enabled);
        assert_eq!(entry.timeout_millisecond, 1500);
        assert_eq!(entry.valid_timeout_millisecond(), 1500);
    }

    #[test]
    fn test_valid_timeout_fallback() {
        let entry = ReplaceRuleEntry {
            timeout_millisecond: 0,
            ..ReplaceRuleEntry::default()
        };
        assert_eq!(entry.valid_timeout_millisecond(), 3000);
        let entry = ReplaceRuleEntry {
            timeout_millisecond: -100,
            ..ReplaceRuleEntry::default()
        };
        assert_eq!(entry.valid_timeout_millisecond(), 3000);
    }

    #[test]
    fn test_full_pipeline_order() {
        // 验证管线执行顺序：去标题 → 替换 → 缩进 → 空行
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            re_segment: false,
            chinese_convert: None,
            apply_replace_rules: true,
            indent_spaces: 2,
            trim_empty_lines: true,
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("广告", "")];
        let content = "测试章节\n广告正文第一段\n\n\n\n\n正文第二段";
        let result = processor.process(content, "测试章节", &rules);
        // 标题去除
        assert!(!result.contains("测试章节"));
        // 替换生效
        assert!(!result.contains("广告"));
        // 缩进生效
        assert!(result.contains("  正文第一段"));
        // 空行修剪（不超过2个）
        let empty_count = result.lines().filter(|l| l.trim().is_empty()).count();
        assert!(empty_count <= 2);
    }

    // ─── @js: 表达式替换测试 ───────────────────────────────

    #[test]
    fn test_js_expression_replace() {
        // replacement 以 @js: 开头 → 逐匹配调用 JS 执行器（mock 返回 <匹配文本>）
        let rules = vec![regex_rule(r"[a-z]+", "@js:wrap")];
        let result = apply_replace_rules("foo 12 bar", &rules, mock_js());
        assert_eq!(result, "<foo> 12 <bar>");
    }

    #[test]
    fn test_js_expression_upper() {
        let rules = vec![regex_rule("hello", "@js:upper")];
        let result = apply_replace_rules("say hello!", &rules, mock_js());
        assert_eq!(result, "say HELLO!");
    }

    #[test]
    fn test_js_replace_no_executor_skipped() {
        // 未注入执行器时 @js: 规则安全跳过，内容不变
        let rules = vec![regex_rule(r"\d+", "@js:result")];
        let result = apply_replace_rules("a 12 b", &rules, None);
        assert_eq!(result, "a 12 b");
    }

    #[test]
    fn test_js_eval_error_skipped() {
        // JS 执行出错 → 跳过该规则，内容不变（对应 Kotlin catch 后保留原内容）
        let rules = vec![regex_rule(r"\d+", "@js:fail")];
        let result = apply_replace_rules("a 12 b", &rules, mock_js());
        assert_eq!(result, "a 12 b");
    }

    #[test]
    fn test_js_replace_in_pipeline() {
        // 经 ContentProcessor.process_with_js 注入执行器
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![regex_rule("广告\\d+", "@js:wrap")];
        let result = processor.process_with_js("正文广告1结束", "", &rules, mock_js());
        assert_eq!(result, "正文<广告1>结束");
    }

    #[test]
    fn test_js_prefix_only_on_replacement() {
        // @js: 判定在 replacement 上（与 Kotlin 一致），pattern 中的 @js: 是普通正则文本
        let rules = vec![regex_rule("@js:", "X")];
        let result = apply_replace_rules("a @js: b", &rules, None);
        assert_eq!(result, "a X b");
    }

    // ─── Java 正则方言测试 ─────────────────────────────────

    #[test]
    fn test_java_lookbehind() {
        // (?<=...) 正向后行断言：regex crate 不支持 → fancy-regex 回退
        let rules = vec![regex_rule(r"(?<=\$)\d+", "X")];
        let result = apply_replace_rules("$100 and 200", &rules, None);
        assert_eq!(result, "$X and 200");
    }

    #[test]
    fn test_java_negative_lookbehind() {
        let rules = vec![regex_rule(r"(?<!\d)abc", "X")];
        let result = apply_replace_rules("xabc 1abc", &rules, None);
        assert_eq!(result, "xX 1abc");
    }

    #[test]
    fn test_java_lookahead() {
        let rules = vec![regex_rule(r"abc(?=\d)", "X")];
        let result = apply_replace_rules("abc1 abcx", &rules, None);
        assert_eq!(result, "X1 abcx");
    }

    #[test]
    fn test_java_backreference() {
        // \1 反向引用：regex crate 不支持 → fancy-regex 回退
        let rules = vec![regex_rule(r"(\w+)=\1", "DUP")];
        let result = apply_replace_rules("aa=aa bb=cc", &rules, None);
        assert_eq!(result, "DUP bb=cc");
    }

    #[test]
    fn test_java_backreference_group_ref_replacement() {
        // 反向引用匹配 + $1 组引用替换
        let rules = vec![regex_rule(r"(\w+) \1", "$1")];
        let result = apply_replace_rules("go go stop", &rules, None);
        assert_eq!(result, "go stop");
    }

    #[test]
    fn test_adapt_java_regex_unicode_escape() {
        assert_eq!(adapt_java_regex(r"\u0041+"), r"\x{0041}+");
        // 转换后可正常编译匹配（\u0041 即 'A'）
        let rules = vec![regex_rule(r"\u0041+", "X")];
        let result = apply_replace_rules("AAA b", &rules, None);
        assert_eq!(result, "X b");
    }

    #[test]
    fn test_adapt_java_regex_strips_unsupported_flags() {
        assert_eq!(adapt_java_regex("(?d)(?i)abc"), "(?i)abc");
        assert_eq!(adapt_java_regex("(?c)x"), "x");
        assert_eq!(adapt_java_regex("(?u)y"), "y");
        // 支持的标志不受影响
        assert_eq!(adapt_java_regex("(?is)a(?m)"), "(?is)a(?m)");
    }

    #[test]
    fn test_adapt_java_regex_newline_r() {
        let adapted = adapt_java_regex(r"a\Rb");
        assert!(adapted.contains(r"\r\n"));
        // 转换后可匹配多种换行
        let rules = vec![regex_rule(r"a\Rb", "X")];
        assert_eq!(apply_replace_rules("a\nb", &rules, None), "X");
        assert_eq!(apply_replace_rules("a\r\nb", &rules, None), "X");
    }

    #[test]
    fn test_adapt_java_regex_preserves_normal_escape() {
        assert_eq!(adapt_java_regex(r"\d+\w"), r"\d+\w");
    }

    // ─── 超时保护测试 ──────────────────────────────────────

    #[test]
    fn test_replace_timeout_skips_rule() {
        // JS 执行超过 timeoutMillisecond → 规则被跳过，内容不变
        let rules = vec![ReplaceRuleEntry {
            pattern: r"\d+".to_string(),
            replacement: "@js:slow".to_string(),
            is_regex: true,
            timeout_millisecond: 100,
            ..ReplaceRuleEntry::default()
        }];
        let start = std::time::Instant::now();
        let result = apply_replace_rules("a 12 b", &rules, Some(Arc::new(SlowJs)));
        assert_eq!(result, "a 12 b");
        // 超时在 100ms 左右触发，远小于 JS 的 500ms 休眠
        assert!(start.elapsed() < Duration::from_millis(450));
    }

    #[test]
    fn test_fast_rule_within_timeout() {
        // 正常规则在超时窗口内完成
        let rules = vec![ReplaceRuleEntry {
            pattern: "abc".to_string(),
            replacement: "@js:upper".to_string(),
            is_regex: true,
            timeout_millisecond: 2000,
            ..ReplaceRuleEntry::default()
        }];
        let result = apply_replace_rules("x abc y", &rules, mock_js());
        assert_eq!(result, "x ABC y");
    }

    // ─── 作用域过滤测试 ────────────────────────────────────

    #[test]
    fn test_scope_content_false_skipped() {
        // scope_content=false 的规则不作用于正文
        let rules = vec![ReplaceRuleEntry {
            pattern: "广告".to_string(),
            replacement: String::new(),
            is_regex: false,
            scope_content: false,
            ..ReplaceRuleEntry::default()
        }];
        let result = apply_replace_rules("广告内容", &rules, None);
        assert_eq!(result, "广告内容");
    }

    #[test]
    fn test_title_rules_apply() {
        // apply_title_replace_rules 仅应用 scope_title=true 的规则
        let rules = vec![
            ReplaceRuleEntry {
                name: "标题规则".to_string(),
                pattern: "【广告】".to_string(),
                replacement: String::new(),
                is_regex: false,
                scope_title: true,
                scope_content: false,
                ..ReplaceRuleEntry::default()
            },
            ReplaceRuleEntry {
                name: "正文规则".to_string(),
                pattern: "正文".to_string(),
                replacement: "X".to_string(),
                is_regex: false,
                scope_title: false,
                scope_content: true,
                ..ReplaceRuleEntry::default()
            },
        ];
        let title = apply_title_replace_rules("【广告】第一章", &rules, None);
        assert_eq!(title, "第一章");
        // 正文管线不应用标题规则
        let content = apply_replace_rules("【广告】正文", &rules, None);
        assert_eq!(content, "【广告】X");
    }

    #[test]
    fn test_exclude_scope_skips_rule() {
        // excludeScope 包含书名 → 规则不生效
        let rules = vec![ReplaceRuleEntry {
            pattern: "广告".to_string(),
            replacement: String::new(),
            is_regex: false,
            exclude_scope: Some("书籍A,书籍B".to_string()),
            ..ReplaceRuleEntry::default()
        }];
        let processor = ContentProcessor::new(ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        })
        .with_scope_context(ScopeContext::new("书籍A", "https://src"));
        let result = processor.process("广告内容", "", &rules);
        assert_eq!(result, "广告内容");

        // 书名不在排除范围 → 规则生效
        let processor2 = ContentProcessor::new(ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        })
        .with_scope_context(ScopeContext::new("书籍C", "https://src"));
        let result2 = processor2.process("广告内容", "", &rules);
        assert_eq!(result2, "内容");
    }

    #[test]
    fn test_exclude_scope_by_origin() {
        // excludeScope 包含书源（对应 DAO：excludeScope LIKE %origin%）→ 规则不生效
        let rules = vec![ReplaceRuleEntry {
            pattern: "广告".to_string(),
            replacement: String::new(),
            is_regex: false,
            exclude_scope: Some("https://biquge.com".to_string()),
            ..ReplaceRuleEntry::default()
        }];
        let processor = ContentProcessor::new(ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        })
        .with_scope_context(ScopeContext::new("任意书籍", "https://biquge.com"));
        let result = processor.process("广告内容", "", &rules);
        assert_eq!(result, "广告内容");
    }

    #[test]
    fn test_scope_match_by_book_name() {
        // scope 指定书籍：匹配时生效
        let rules = vec![ReplaceRuleEntry {
            pattern: "广告".to_string(),
            replacement: String::new(),
            is_regex: false,
            scope: Some("书籍A".to_string()),
            ..ReplaceRuleEntry::default()
        }];
        let ctx = ScopeContext::new("书籍A", "origin");
        let filtered = filter_content_rules(&rules, &ctx);
        assert_eq!(filtered.len(), 1);

        let ctx2 = ScopeContext::new("书籍B", "origin");
        let filtered2 = filter_content_rules(&rules, &ctx2);
        assert!(filtered2.is_empty());
    }

    #[test]
    fn test_filter_content_rules() {
        let rules = vec![
            ReplaceRuleEntry {
                name: "正文全局".to_string(),
                scope_content: true,
                ..ReplaceRuleEntry::default()
            },
            ReplaceRuleEntry {
                name: "仅标题".to_string(),
                scope_title: true,
                scope_content: false,
                ..ReplaceRuleEntry::default()
            },
            ReplaceRuleEntry {
                name: "已禁用".to_string(),
                is_enabled: false,
                ..ReplaceRuleEntry::default()
            },
            ReplaceRuleEntry {
                name: "排除本书".to_string(),
                exclude_scope: Some("斗破苍穹".to_string()),
                ..ReplaceRuleEntry::default()
            },
        ];
        let ctx = ScopeContext::new("斗破苍穹", "https://src");
        let filtered = filter_content_rules(&rules, &ctx);
        let names: Vec<&str> = filtered.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["正文全局"]);
    }

    #[test]
    fn test_filter_title_rules() {
        let rules = vec![
            ReplaceRuleEntry {
                name: "标题规则".to_string(),
                scope_title: true,
                scope_content: false,
                ..ReplaceRuleEntry::default()
            },
            ReplaceRuleEntry {
                name: "正文规则".to_string(),
                scope_title: false,
                scope_content: true,
                ..ReplaceRuleEntry::default()
            },
        ];
        let ctx = ScopeContext::new("书名", "书源");
        let filtered = filter_title_rules(&rules, &ctx);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].name, "标题规则");
    }

    #[test]
    fn test_scope_global_when_empty() {
        // scope 为 None/空 → 全局生效
        let rules = vec![
            ReplaceRuleEntry {
                name: "无scope".to_string(),
                scope: None,
                ..ReplaceRuleEntry::default()
            },
            ReplaceRuleEntry {
                name: "空scope".to_string(),
                scope: Some(String::new()),
                ..ReplaceRuleEntry::default()
            },
        ];
        let ctx = ScopeContext::new("任意", "任意");
        assert_eq!(filter_content_rules(&rules, &ctx).len(), 2);
    }
}
