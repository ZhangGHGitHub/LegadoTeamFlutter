//! RuleAnalyzer: 规则字符串的词法分析器
//!
//! 参考 Kotlin `RuleAnalyzer.kt`，实现零拷贝切片的高效规则拆分。
//! 支持操作符 `&&`（与）、`||`（或）、`%%`（排除），
//! 支持 `@` 前缀标识解析类型，以及 `{...}` 嵌套规则。

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
                // 不平衡，回退并继续
                break;
            }

            if end <= self.pos {
                break;
            }
        }

        self.start = self.pos;
        self.split_rule_inner(splits)
    }

    fn split_rule_next(&mut self) -> Vec<&'a str> {
        let end = self.pos;
        self.pos = self.start;

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
                break;
            }

            if end <= self.pos {
                break;
            }
        }

        self.start = self.pos;

        if !self.consume_to(self.elements_type) {
            self.rule.push(&self.queue[self.start_x..]);
            self.rule.clone()
        } else {
            self.split_rule_next()
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
}
