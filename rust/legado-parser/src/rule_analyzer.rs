//! RuleAnalyzer: 规则字符串的词法分析器
//!
//! 参考 Kotlin `RuleAnalyzer.kt`，实现零拷贝切片的高效规则拆分。
//! 支持操作符 `&&`（与）、`||`（或）、`%%`（排除），
//! 支持 `@` 前缀标识解析类型，以及 `{...}` 嵌套规则。
//!
//! ## 栈安全（任务 #62）
//!
//! 原版 Kotlin `splitRule` 标注 `tailrec`（编译为循环），遇未平衡括号
//! `throw Error("...后未平衡")` 由上层处理。Rust 移植版曾为直接尾递归，
//! 且 `chomp_balanced` 失败后**零前进重试**（`foo[bar&&baz` 类输入：
//! 未闭合 `[` + 分隔符 → 每层递归状态完全相同）造成数万层压栈爆栈。
//! 现修复为：
//! - 自递归全部改写为 `loop` 迭代（O(1) 栈，对齐原版 tailrec）；
//! - 平衡组扫描失败时不再原状态重试，将剩余串作为单条规则压入并返回
//!   （对齐原版 throw 语义的跨 FFI 优雅降级，不 panic）；
//! - 迭代次数防御上限（`queue.len() + 1`），双保险兜底。

const ESC: char = '\\';

/// 规则分析器，对输入字符串进行词法级别的拆分
pub struct RuleAnalyzer<'a> {
    queue: &'a str,
    pos: usize,
    start: usize,
    start_x: usize,
    rule: Vec<&'a str>,
    step: usize,
    /// 当前分隔符类型（如 "&&", "||", "%%"）
    pub elements_type: &'a str,
    /// 是否使用代码平衡组（用于 json/JS），否则使用规则平衡组
    code: bool,
}

impl<'a> RuleAnalyzer<'a> {
    /// 创建新的规则分析器
    /// - `data`: 规则字符串
    /// - `code`: 是否使用代码平衡组模式（JSON/JS 场景设为 true）
    pub fn new(data: &'a str, code: bool) -> Self {
        Self {
            queue: data,
            pos: 0,
            start: 0,
            start_x: 0,
            rule: Vec::new(),
            step: 0,
            elements_type: "",
            code,
        }
    }

    /// 修剪当前规则之前的 `@` 或空白符
    pub fn trim(&mut self) {
        let bytes = self.queue.as_bytes();
        if self.pos < bytes.len() && (bytes[self.pos] == b'@' || bytes[self.pos] < b'!') {
            self.pos += 1;
            while self.pos < bytes.len() && (bytes[self.pos] == b'@' || bytes[self.pos] < b'!') {
                self.pos += 1;
            }
            self.start = self.pos;
            self.start_x = self.pos;
        }
    }

    /// 将 pos 重置为 0，方便复用
    pub fn reset_pos(&mut self) {
        self.pos = 0;
        self.start_x = 0;
    }

    // --- 内部工具方法 ---

    /// 从剩余字串中查找 `seq` 的位置，将 pos 移到匹配处
    fn consume_to(&mut self, seq: &str) -> bool {
        self.start = self.pos;
        if let Some(offset) = self.queue[self.pos..].find(seq) {
            self.pos += offset;
            true
        } else {
            false
        }
    }

    /// 从剩余字串中查找任一 `seqs` 中字符串，返回是否找到
    fn consume_to_any(&mut self, seqs: &[&str]) -> bool {
        let mut p = self.pos;
        let remaining = &self.queue[p..];

        while p < self.queue.len() {
            let sub = &self.queue[p..];
            for &s in seqs {
                if sub.starts_with(s) {
                    self.step = s.len();
                    self.pos = p;
                    return true;
                }
            }
            // 按字符步进
            if let Some(ch) = remaining[p - self.pos..].chars().next() {
                p += ch.len_utf8();
            } else {
                break;
            }
        }
        false
    }

    /// 从剩余字串中查找任一字符，返回位置（字节偏移），未找到返回 None
    fn find_to_any(&self, chars: &[char]) -> Option<usize> {
        let mut p = self.pos;
        while p < self.queue.len() {
            if let Some(ch) = self.queue[p..].chars().next() {
                for &c in chars {
                    if ch == c {
                        return Some(p);
                    }
                }
                p += ch.len_utf8();
            } else {
                break;
            }
        }
        None
    }

    /// 拉出一个代码平衡组（支持转义），用于 JSON/JS
    fn chomp_code_balanced(&mut self, open: char, close: char) -> bool {
        let mut p = self.pos;
        let mut depth: i32 = 0;
        let mut other_depth: i32 = 0;
        let mut in_single_quote = false;
        let mut in_double_quote = false;

        loop {
            if p >= self.queue.len() {
                break;
            }
            let ch = self.queue[p..].chars().next().unwrap();
            p += ch.len_utf8();

            if ch != ESC {
                if ch == '\'' && !in_double_quote {
                    in_single_quote = !in_single_quote;
                } else if ch == '"' && !in_single_quote {
                    in_double_quote = !in_double_quote;
                }

                if in_single_quote || in_double_quote {
                    continue;
                }

                if ch == '[' {
                    depth += 1;
                } else if ch == ']' {
                    depth -= 1;
                } else if depth == 0 {
                    if ch == open {
                        other_depth += 1;
                    } else if ch == close {
                        other_depth -= 1;
                    }
                }
            } else {
                // 跳过转义字符后的下一个字符
                if p < self.queue.len() {
                    let next = self.queue[p..].chars().next().unwrap();
                    p += next.len_utf8();
                }
            }

            if depth <= 0 && other_depth <= 0 {
                break;
            }
        }

        if depth > 0 || other_depth > 0 {
            false
        } else {
            self.pos = p;
            true
        }
    }

    /// 拉出一个规则平衡组（引号内转义字符无效），用于 CSS/XPath
    fn chomp_rule_balanced(&mut self, open: char, close: char) -> bool {
        let mut p = self.pos;
        let mut depth: i32 = 0;
        let mut in_single_quote = false;
        let mut in_double_quote = false;

        loop {
            if p >= self.queue.len() {
                break;
            }
            let ch = self.queue[p..].chars().next().unwrap();
            p += ch.len_utf8();

            if ch == '\'' && !in_double_quote {
                in_single_quote = !in_single_quote;
            } else if ch == '"' && !in_single_quote {
                in_double_quote = !in_double_quote;
            }

            if in_single_quote || in_double_quote {
                continue;
            } else if ch == '\\' {
                // 不在引号中的转义字符跳过下一个字符
                if p < self.queue.len() {
                    let next = self.queue[p..].chars().next().unwrap();
                    p += next.len_utf8();
                }
                continue;
            }

            if ch == open {
                depth += 1;
            } else if ch == close {
                depth -= 1;
            }

            if depth <= 0 {
                break;
            }
        }

        if depth > 0 {
            false
        } else {
            self.pos = p;
            true
        }
    }

    /// 根据 `code` 标志选择平衡组函数
    fn chomp_balanced(&mut self, open: char, close: char) -> bool {
        if self.code {
            self.chomp_code_balanced(open, close)
        } else {
            self.chomp_rule_balanced(open, close)
        }
    }

    // --- 公共 API ---

    /// 拆分规则字符串，支持多种分隔符（如 `&&`, `||`, `%%`）
    ///
    /// 返回拆分后的规则片段列表，`elements_type` 字段记录使用的分隔符类型。
    pub fn split_rule(&mut self, splits: &[&'a str]) -> Vec<&'a str> {
        self.rule.clear();
        self.elements_type = "";
        self.split_rule_inner(splits)
    }

    fn split_rule_inner(&mut self, splits: &[&'a str]) -> Vec<&'a str> {
        if splits.len() == 1 {
            self.elements_type = splits[0];
            if !self.consume_to(self.elements_type) {
                self.rule.push(&self.queue[self.start_x..]);
                return self.rule.clone();
            }
            self.step = self.elements_type.len();
            return self.split_rule_next();
        }

        // 迭代上限双保险：每次有效迭代 pos 至少前进 1 字节，
        // queue.len()+1 为理论上限（对齐原版 tailrec 的循环语义）
        let mut budget = self.queue.len() + 1;

        loop {
            if budget == 0 {
                // 防御兜底：剩余串作为单条规则返回（优雅降级，不 panic）
                self.rule.push(&self.queue[self.start_x..]);
                return self.rule.clone();
            }
            budget -= 1;

            if !self.consume_to_any(splits) {
                self.rule.push(&self.queue[self.start_x..]);
                return self.rule.clone();
            }

            let end = self.pos;
            self.pos = self.start;

            loop {
                let st = self.find_to_any(&['[', '(']);

                if st.is_none() {
                    // 没有筛选器，直接按分隔符拆分
                    self.rule = vec![&self.queue[self.start_x..end]];
                    self.elements_type = &self.queue[end..end + self.step];
                    self.pos = end + self.step;

                    while self.consume_to(self.elements_type) {
                        self.rule.push(&self.queue[self.start..self.pos]);
                        self.pos += self.step;
                    }
                    self.rule.push(&self.queue[self.pos..]);
                    return self.rule.clone();
                }

                let st = st.unwrap();

                if st > end {
                    // 分隔符不在选择器中
                    self.rule = vec![&self.queue[self.start_x..end]];
                    self.elements_type = &self.queue[end..end + self.step];
                    self.pos = end + self.step;

                    while self.consume_to(self.elements_type) && self.pos < st {
                        self.rule.push(&self.queue[self.start..self.pos]);
                        self.pos += self.step;
                    }

                    if self.pos > st {
                        self.start_x = self.start;
                        // 原版此处调用 split_rule_next（已改写为迭代，
                        // O(1) 栈且有预算上限），保持原语义
                        return self.split_rule_next();
                    } else {
                        self.rule.push(&self.queue[self.pos..]);
                        return self.rule.clone();
                    }
                }

                self.pos = st;
                let ch = self.queue.as_bytes()[self.pos] as char;
                let next = if ch == '[' { ']' } else { ')' };

                if !self.chomp_balanced(ch, next) {
                    // 未平衡（原版 RuleAnalyzer.kt L228/L285 此处 throw Error
                    // "...后未平衡" 由上层处理）：跨 FFI 不能 panic，
                    // 优雅降级——剩余串作为单条规则压入并返回。
                    // 关键：不再原状态重试（chomp 失败不推进 pos，
                    // 重试会构成零前进无限递归/循环）
                    self.rule.push(&self.queue[self.start_x..]);
                    return self.rule.clone();
                }

                if end <= self.pos {
                    // 分隔符在平衡组内，越过该组继续找下一个分隔符
                    break;
                }
            }

            self.start = self.pos;
        }
    }

    fn split_rule_next(&mut self) -> Vec<&'a str> {
        // 原自递归改写为迭代（对齐原版 Kotlin tailrec，O(1) 栈）；
        // 迭代上限双保险：每次有效迭代 pos 至少越过一个分隔符（前进
        // step 字节），queue.len()+1 远超理论上限
        let mut budget = self.queue.len() + 1;

        loop {
            if budget == 0 {
                // 防御兜底：剩余串作为单条规则返回（优雅降级，不 panic）
                self.rule.push(&self.queue[self.start_x..]);
                return self.rule.clone();
            }
            budget -= 1;

            let end = self.pos;
            self.pos = self.start;

            // 内层循环标记：Some(true) = 分隔符在平衡组内，需越过该组继续；
            // Some(false) = 进入下一迭代继续拆分；None = 已返回
            let mut crossed_balanced: Option<bool> = None;

            loop {
                let st = self.find_to_any(&['[', '(']);

                if st.is_none() {
                    self.rule.push(&self.queue[self.start_x..end]);
                    self.pos = end + self.step;

                    while self.consume_to(self.elements_type) {
                        self.rule.push(&self.queue[self.start..self.pos]);
                        self.pos += self.step;
                    }
                    self.rule.push(&self.queue[self.pos..]);
                    return self.rule.clone();
                }

                let st = st.unwrap();

                if st > end {
                    self.rule.push(&self.queue[self.start_x..end]);
                    self.pos = end + self.step;

                    while self.consume_to(self.elements_type) && self.pos < st {
                        self.rule.push(&self.queue[self.start..self.pos]);
                        self.pos += self.step;
                    }

                    if self.pos > st {
                        self.start_x = self.start;
                        // 原自递归点（L350）：改写为外层 loop 迭代
                        // （pos > st >= end，严格前进）
                        crossed_balanced = Some(false);
                        break;
                    } else {
                        self.rule.push(&self.queue[self.pos..]);
                        return self.rule.clone();
                    }
                }

                self.pos = st;
                let ch = self.queue.as_bytes()[self.pos] as char;
                let next = if ch == '[' { ']' } else { ')' };

                if !self.chomp_balanced(ch, next) {
                    // 未平衡（原版此处 throw Error 由上层处理）：
                    // 跨 FFI 优雅降级——剩余串作为单条规则压入并返回。
                    // 关键：chomp 失败不推进 pos，原 break→consume_to 会
                    // 再次命中同一分隔符构成零前进无限递归（任务 #62 真凶）
                    self.rule.push(&self.queue[self.start_x..]);
                    return self.rule.clone();
                }

                if end <= self.pos {
                    crossed_balanced = Some(true);
                    break;
                }
            }

            self.start = self.pos;

            if crossed_balanced == Some(true) {
                // 分隔符在平衡组内：越过平衡组后继续找下一个分隔符
                if !self.consume_to(self.elements_type) {
                    self.rule.push(&self.queue[self.start_x..]);
                    return self.rule.clone();
                }
                // 原自递归点（L376）：continue 进入下一迭代
                // （consume_to 成功 ⇒ pos 越过分隔符，严格前进）
            }
        }
    }

    /// 替换内嵌规则 `{...}`
    ///
    /// - `inner`: 内嵌规则的起始标志，如 `"{$."`
    /// - `start_step`: 不属于规则部分的前置字符长度
    /// - `end_step`: 不属于规则部分的后置字符长度
    /// - `resolver`: 解析内嵌规则内容的回调函数
    pub fn inner_rule<F>(
        &mut self,
        inner: &str,
        start_step: usize,
        end_step: usize,
        resolver: F,
    ) -> String
    where
        F: Fn(&str) -> Option<String>,
    {
        let mut result = String::new();

        while self.consume_to(inner) {
            let pos_pre = self.pos;
            if self.chomp_code_balanced('{', '}') {
                let content_start = pos_pre + start_step;
                let content_end = self.pos.saturating_sub(end_step);
                if content_start <= content_end {
                    if let Some(frv) = resolver(&self.queue[content_start..content_end]) {
                        result.push_str(&self.queue[self.start_x..pos_pre]);
                        result.push_str(&frv);
                        self.start_x = self.pos;
                        continue;
                    }
                }
            }
            self.pos += inner.len();
        }

        if self.start_x == 0 {
            String::new()
        } else {
            result.push_str(&self.queue[self.start_x..]);
            result
        }
    }

    /// 替换内嵌规则（使用开始/结束字符串匹配）
    pub fn inner_rule_delimited<F>(&mut self, start_str: &str, end_str: &str, resolver: F) -> String
    where
        F: Fn(&str) -> Option<String>,
    {
        let mut result = String::new();

        while self.consume_to(start_str) {
            self.pos += start_str.len();
            let pos_pre = self.pos;
            if self.consume_to(end_str) {
                if let Some(frv) = resolver(&self.queue[pos_pre..self.pos]) {
                    result.push_str(&self.queue[self.start_x..pos_pre - start_str.len()]);
                    result.push_str(&frv);
                    self.pos += end_str.len();
                    self.start_x = self.pos;
                }
            }
        }

        if self.start_x == 0 {
            self.queue.to_string()
        } else {
            result.push_str(&self.queue[self.start_x..]);
            result
        }
    }

    /// 获取拆分出的规则片段
    pub fn rules(&self) -> &[&'a str] {
        &self.rule
    }

    /// 解析规则前缀，识别 `@css:`, `@xpath:`, `@json:`, `@regex:` 类型标记
    ///
    /// 返回 `(前缀类型, 去掉前缀后的规则)`。
    /// 前缀类型为 `"css"` / `"xpath"` / `"json"` / `"regex"` / `""`（无标记）。
    pub fn parse_rule_prefix(rule: &str) -> (&str, &str) {
        let lower = rule.to_ascii_lowercase();
        if lower.starts_with("@css:") {
            ("css", &rule[5..])
        } else if lower.starts_with("@xpath:") {
            ("xpath", &rule[7..])
        } else if lower.starts_with("@json:") {
            ("json", &rule[6..])
        } else if lower.starts_with("@regexp:") {
            ("regex", &rule[8..])
        } else if lower.starts_with("@regex:") {
            ("regex", &rule[7..])
        } else if lower.starts_with("@js:") {
            ("js", &rule[4..])
        } else if lower.starts_with("@webjs:") {
            ("webjs", &rule[7..])
        } else {
            ("", rule)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_split() {
        let mut ra = RuleAnalyzer::new("a&&b&&c", false);
        let rules = ra.split_rule(&["&&", "||", "%%"]);
        assert_eq!(rules, vec!["a", "b", "c"]);
        assert_eq!(ra.elements_type, "&&");
    }

    #[test]
    fn test_or_split() {
        let mut ra = RuleAnalyzer::new("a||b", false);
        let rules = ra.split_rule(&["&&", "||", "%%"]);
        assert_eq!(rules, vec!["a", "b"]);
        assert_eq!(ra.elements_type, "||");
    }

    #[test]
    fn test_single_rule() {
        let mut ra = RuleAnalyzer::new("div.content", false);
        let rules = ra.split_rule(&["&&", "||", "%%"]);
        assert_eq!(rules, vec!["div.content"]);
    }

    #[test]
    fn test_bracket_balanced() {
        let mut ra = RuleAnalyzer::new("div[a&&b]&&c", false);
        let rules = ra.split_rule(&["&&", "||", "%%"]);
        assert_eq!(rules, vec!["div[a&&b]", "c"]);
    }

    #[test]
    fn test_parse_rule_prefix() {
        assert_eq!(
            RuleAnalyzer::parse_rule_prefix("@css:div.content"),
            ("css", "div.content")
        );
        assert_eq!(
            RuleAnalyzer::parse_rule_prefix("@XPath://div"),
            ("xpath", "//div")
        );
        assert_eq!(
            RuleAnalyzer::parse_rule_prefix("@json:$.name"),
            ("json", "$.name")
        );
        assert_eq!(
            RuleAnalyzer::parse_rule_prefix("@regex:\\d+"),
            ("regex", "\\d+")
        );
        assert_eq!(
            RuleAnalyzer::parse_rule_prefix("div.content"),
            ("", "div.content")
        );
    }

    #[test]
    fn test_inner_rule() {
        let mut ra = RuleAnalyzer::new("prefix{$.name}suffix", true);
        let result = ra.inner_rule("{$", 1, 1, |inner| Some(format!("[{}]", inner)));
        assert_eq!(result, "prefix[$.name]suffix");
    }

    #[test]
    fn test_inner_rule_delimited() {
        let mut ra = RuleAnalyzer::new("before{{js_code}}after", false);
        let result = ra.inner_rule_delimited("{{", "}}", |inner| Some(format!("({})", inner)));
        assert_eq!(result, "before(js_code)after");
    }

    // ─── 任务 #62：零前进无限递归根治回归 ─────────────────────

    /// 病态输入不挂死不崩溃：未闭合括号 + 分隔符（原零前进递归真凶）。
    /// 原版 Kotlin 此处 throw Error("...后未平衡")，Rust 侧跨 FFI
    /// 优雅降级：返回非空结果（剩余串作为单条规则）。
    #[test]
    fn test_pathological_unbalanced_inputs_terminate() {
        let pathological = [
            "foo[bar&&baz",
            "a(b||c",
            "@@.arcurl@textNodes",
            ".*状态：|\\s.* {{@@.arcurl@textNodes",
            "[",
            "((((",
            "a[&&b[c&&d",
            "x(y&&z[",
            "class.bookname&&[未闭合",
        ];
        for input in pathological {
            let mut ra = RuleAnalyzer::new(input, false);
            let rules = ra.split_rule(&["&&", "||", "%%"]);
            assert!(!rules.is_empty(), "降级应返回非空结果: {input}");
            // 单分隔符路径（split_rule_next 直达）同样不挂死
            let mut ra2 = RuleAnalyzer::new(input, false);
            let rules2 = ra2.split_rule(&["&&"]);
            assert!(!rules2.is_empty(), "单分隔符路径应返回非空结果: {input}");
        }
    }

    /// 实际致崩规则的拆分路径：`@` 分隔（html.rs 调用方）下的未闭合括号
    #[test]
    fn test_pathological_at_split_path() {
        let input = ".*状态：|\\s.* {{@@.arcurl@textNodes";
        let mut ra = RuleAnalyzer::new(input, false);
        let rules = ra.split_rule(&["@"]);
        assert!(!rules.is_empty());
        // 单分隔符 + 未闭合 `[` 的组合（split_rule → split_rule_next 直达）
        let mut ra2 = RuleAnalyzer::new("foo[bar@baz", false);
        let rules2 = ra2.split_rule(&["@"]);
        assert!(!rules2.is_empty());
    }

    /// 在 2MB / 512KB 小栈线程上跑病态用例：验证迭代改写后 O(1) 栈，
    /// 即使旧递归实现存在数万层压栈场景也不爆栈
    #[test]
    fn test_pathological_on_small_stack_threads() {
        for stack_size in [2usize << 20, 512 << 10] {
            let handle = std::thread::Builder::new()
                .stack_size(stack_size)
                .spawn(|| {
                    let input = "foo[bar&&baz";
                    let mut ra = RuleAnalyzer::new(input, false);
                    let rules = ra.split_rule(&["&&", "||", "%%"]);
                    assert!(!rules.is_empty());
                    // 长串深嵌套未闭合构造：旧实现递归深度随输入长度线性增长
                    let deep = format!("{}&&tail", "[a".repeat(500));
                    let mut ra2 = RuleAnalyzer::new(&deep, false);
                    let rules2 = ra2.split_rule(&["&&", "||", "%%"]);
                    assert!(!rules2.is_empty());
                })
                .expect("spawn 失败");
            handle.join().expect("小栈线程上病态输入不应崩溃");
        }
    }

    /// 合法输入行为不变：平衡括号规则内分隔符不拆（既有基线回归）
    #[test]
    fn test_legal_inputs_behavior_unchanged() {
        // %% / 混合分隔符
        let mut ra = RuleAnalyzer::new("a%%b%%c", false);
        assert_eq!(ra.split_rule(&["&&", "||", "%%"]), vec!["a", "b", "c"]);
        assert_eq!(ra.elements_type, "%%");
        // 括号内分隔符保护 + 括号后继续拆分
        let mut ra = RuleAnalyzer::new("div[a||b]&&span.c", false);
        assert_eq!(ra.split_rule(&["&&", "||", "%%"]), vec!["div[a||b]", "span.c"]);
        // 圆括号平衡组
        let mut ra = RuleAnalyzer::new("fn(a&&b)||c", false);
        assert_eq!(ra.split_rule(&["&&", "||", "%%"]), vec!["fn(a&&b)", "c"]);
        // 嵌套平衡组
        let mut ra = RuleAnalyzer::new("x[a[b&&c]]&&y", false);
        assert_eq!(ra.split_rule(&["&&", "||", "%%"]), vec!["x[a[b&&c]]", "y"]);
        // @js: 前缀语义不受影响
        assert_eq!(RuleAnalyzer::parse_rule_prefix("@js:result"), ("js", "result"));
        // 无分隔符单规则
        let mut ra = RuleAnalyzer::new("class.content", false);
        assert_eq!(ra.split_rule(&["&&", "||", "%%"]), vec!["class.content"]);
    }
}
