//! Rhino 宽容语法归一化（jsLib/setup/mainJs 预处理）。
//!
//! 原版应用用 corejs-Rhino 解析书源 jsLib，其容忍若干 V8/QuickJS 拒绝的松散语法：
//! 1. 函数体内 let/const 重声明参数名（如 B 站源的
//!    function showCom(bu){ let bu = ... }）——V8/QuickJS 报
//!    "invalid redefinition of parameter name"；
//! 2. 代码上下文中的双点笔误（如 data..item_null）——V8/QuickJS 报
//!    "expecting field name"。
//!
//! 本模块只在严格引擎解析失败时被调用（见 crate::engine_cache），对合法脚本零影响：
//! - 第 1 类：把影子声明及其后续引用改名为 <参数名>_shim；
//!   **初始化值窗口除外**：`let P = P || d` 自引用初始化式中，右侧
//!   `P` 按作者（Rhino 宽容）意图解析为**参数**而非影子绑定（Rhino 无
//!   TDZ）→ 改名后必须保留参数名，否则 QuickJS 自引用 TDZ 运行时报错
//!   （书旗 #26 `let sourceUrl = sourceUrl || "https://..."` 实证）；
//!   声明后（初始化值语句结束处起）的引用全部改名为 <参数名>_shim；
//! - 第 2 类：在字符串/模板/注释感知的前提下，把代码上下文中恰好两个连续的点折叠为一个。
//!
//! 纯 Rust 实现（无外部依赖），不启用 quickjs feature 也可编译与单测。

/// 对脚本做 Rhino 宽容语法归一化，返回 (归一化文本, 是否发生改动)。
pub fn normalize(src: &str) -> (String, bool) {
    let pass1 = collapse_double_dots(src);
    let pass2 = rename_shadowed_params(&pass1);
    let changed = pass2 != src;
    (pass2, changed)
}

// ─────────────────────────── 第 2 类：双点折叠 ───────────────────────────

/// 在字符串/模板/注释/正则感知的前提下，把代码上下文中恰好两个连续的点折叠为一个。
///
/// 仅当前一有效字符是标识符字符或 )/]（成员访问形态）时才折叠，
/// 避免误伤数字序列等无关内容；三个及以上的点（展开运算符）不处理。
fn collapse_double_dots(src: &str) -> String {
    let chars: Vec<char> = src.chars().collect();
    let n = chars.len();
    let mut out = String::with_capacity(n);

    // 上下文栈：Code{depth} 表示代码（depth 为模板表达式内的大括号深度），TplText 表示模板文本。
    #[derive(Clone, Copy)]
    enum Ctx {
        Code(usize),
        TplText,
    }
    let mut stack: Vec<Ctx> = vec![Ctx::Code(0)];
    // 上一个有效代码字符（用于双点折叠的前置判断与正则判定）
    let mut last_code_char: Option<char> = None;

    let mut i = 0usize;
    while i < n {
        let c = chars[i];
        let top = *stack.last().unwrap();

        if matches!(top, Ctx::TplText) {
            // 模板文本：原样输出，识别转义、反引号收尾与美元花括号进入表达式
            if c == '\\' && i + 1 < n {
                out.push(c);
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '\u{60}' {
                out.push(c);
                stack.pop();
                i += 1;
                continue;
            }
            if c == '$' && i + 1 < n && chars[i + 1] == '{' {
                out.push(c);
                out.push(chars[i + 1]);
                stack.push(Ctx::Code(0));
                i += 2;
                continue;
            }
            out.push(c);
            i += 1;
            continue;
        }

        // ── 代码上下文 ──
        let depth = match top {
            Ctx::Code(d) => d,
            _ => unreachable!(),
        };

        // 行注释 / 块注释：原样吞到结束
        if c == '/' && i + 1 < n {
            if chars[i + 1] == '/' {
                let mut j = i;
                while j < n && chars[j] != '\n' {
                    out.push(chars[j]);
                    j += 1;
                }
                i = j;
                continue;
            }
            if chars[i + 1] == '*' {
                out.push(c);
                out.push(chars[i + 1]);
                let mut j = i + 2;
                loop {
                    if j + 1 < n && chars[j] == '*' && chars[j + 1] == '/' {
                        out.push(chars[j]);
                        out.push(chars[j + 1]);
                        j += 2;
                        break;
                    }
                    out.push(chars[j]);
                    j += 1;
                    if j >= n {
                        break;
                    }
                }
                i = j;
                continue;
            }
        }

        // 字符串字面量：原样吞到收尾引号
        if c == '\'' || c == '"' {
            let quote = c;
            out.push(c);
            i += 1;
            while i < n {
                if chars[i] == '\\' && i + 1 < n {
                    out.push(chars[i]);
                    out.push(chars[i + 1]);
                    i += 2;
                    continue;
                }
                out.push(chars[i]);
                if chars[i] == quote {
                    i += 1;
                    break;
                }
                i += 1;
            }
            last_code_char = Some(quote);
            continue;
        }

        // 模板字面量开始：压栈进入模板文本
        if c == '\u{60}' {
            out.push(c);
            stack.push(Ctx::TplText);
            last_code_char = Some('\u{60}');
            i += 1;
            continue;
        }

        // 正则字面量（启发式）：上一有效字符属于“表达式之前”集合时，/ 开启正则
        if c == '/' && is_regex_start(last_code_char) {
            out.push(c);
            i += 1;
            let mut in_class = false;
            while i < n {
                if chars[i] == '\\' && i + 1 < n {
                    out.push(chars[i]);
                    out.push(chars[i + 1]);
                    i += 2;
                    continue;
                }
                let ch = chars[i];
                if in_class {
                    out.push(ch);
                    if ch == ']' {
                        in_class = false;
                    }
                    i += 1;
                    continue;
                }
                if ch == '[' {
                    in_class = true;
                    out.push(ch);
                    i += 1;
                    continue;
                }
                if ch == '/' {
                    out.push(ch);
                    i += 1;
                    break;
                }
                if ch == '\n' {
                    // 正则不能跨行；换行说明不是正则（保守回退）
                    out.push(ch);
                    i += 1;
                    break;
                }
                out.push(ch);
                i += 1;
            }
            last_code_char = Some('/');
            continue;
        }

        // 大括号深度维护（模板表达式内）
        if c == '{' {
            out.push(c);
            let d2 = depth + 1;
            let len = stack.len();
            stack[len - 1] = Ctx::Code(d2);
            last_code_char = Some('{');
            i += 1;
            continue;
        }
        if c == '}' {
            out.push(c);
            if depth > 0 || stack.len() > 1 {
                if depth > 0 {
                    let len = stack.len();
                    stack[len - 1] = Ctx::Code(depth - 1);
                } else {
                    // 模板表达式的收尾大括号：弹回模板文本
                    stack.pop();
                }
            }
            // 顶层多余的大括号（畸形脚本）：原样输出，不弹根上下文，避免栈空
            last_code_char = Some('}');
            i += 1;
            continue;
        }

        // 双点折叠：代码上下文中，恰好两个点且前一有效字符为字母/下划线/$ 或 )/]
        if c == '.' && chars.get(i + 1) == Some(&'.') {
            let third = chars.get(i + 2);
            let prev_ok = last_code_char.is_some_and(|p| p.is_alphabetic() || p == '_' || p == '$');
            if third != Some(&'.') && prev_ok {
                // 折叠：输出一个点，跳过第二个点
                out.push('.');
                i += 2;
                last_code_char = Some('.');
                continue;
            }
        }

        out.push(c);
        if !c.is_whitespace() {
            last_code_char = Some(c);
        }
        i += 1;
    }
    out
}

/// “/” 是否为正则字面量起始：上一有效字符属于表达式前导集合。
fn is_regex_start(last: Option<char>) -> bool {
    match last {
        None => true,
        Some(c) => {
            c == '('
                || c == ','
                || c == '='
                || c == ':'
                || c == '['
                || c == '!'
                || c == '&'
                || c == '|'
                || c == '?'
                || c == '{'
                || c == '}'
                || c == ';'
                || c == '+'
                || c == '-'
                || c == '*'
                || c == '%'
                || c == '~'
                || c == '^'
                || c == '<'
                || c == '>'
        }
    }
}

// ──────────────────── 第 1 类：let/const 参数影子重命名 ────────────────────

/// 把函数体内用 let/const 重声明的参数名改名为 <name>_shim，
/// 并同步改名该影子声明之后（至函数体结束）的全部引用；
/// 初始化值窗口 [init_start, init_end) 内的同名引用**不改**（按作者
/// Rhino 意图解析为参数本身，见模块头注释）。
/// 单个影子改名计划：(影子声明位置, 参数名, 所属函数体结束下标,
/// 初始化值窗口起止；无初始化值时窗口为空区间)。
#[derive(Clone)]
struct ShadowPlan {
    decl_pos: usize,
    name: String,
    body_end: usize,
    /// 初始化值起点（'=' 下标；无初始化值 = 声明名结束下标，窗口空）
    init_start: usize,
    /// 初始化值终点（语句结束 ';'/'\n' 下标或 ASI 终止下标；
    /// 多声明列表取整条语句末尾——后续项初始化值中的同名引用
    /// 同样按参数处理，保守不动）
    init_end: usize,
}

fn rename_shadowed_params(src: &str) -> String {
    let chars: Vec<char> = src.chars().collect();
    let n = chars.len();

    // 收集所有影子计划
    let mut plans: Vec<ShadowPlan> = Vec::new();

    let mut i = 0usize;
    while i < n {
        // 跳过字符串与注释，避免在字面量内容里误找 function
        if chars[i] == '\'' || chars[i] == '"' {
            let quote = chars[i];
            i += 1;
            while i < n && chars[i] != quote {
                if chars[i] == '\\' {
                    i += 1;
                }
                i += 1;
            }
            i += 1;
            continue;
        }
        if chars[i] == '/' && i + 1 < n {
            if chars[i + 1] == '/' {
                while i < n && chars[i] != '\n' {
                    i += 1;
                }
                continue;
            }
            if chars[i + 1] == '*' {
                i += 2;
                while i + 1 < n && !(chars[i] == '*' && chars[i + 1] == '/') {
                    i += 1;
                }
                i += 1;
                continue;
            }
        }

        if chars[i] == 'f' && at_keyword(&chars, i, "function") {
            // function [name] ( params ) { body }
            let mut j = i + "function".len();
            while j < n && chars[j].is_whitespace() {
                j += 1;
            }
            // 可选函数名
            if j < n && (chars[j].is_alphabetic() || chars[j] == '_' || chars[j] == '$') {
                while j < n && (chars[j].is_alphanumeric() || chars[j] == '_' || chars[j] == '$') {
                    j += 1;
                }
                while j < n && chars[j].is_whitespace() {
                    j += 1;
                }
            }
            if j >= n || chars[j] != '(' {
                i += 1;
                continue;
            }
            // 参数列表（括号配平，感知字符串）
            let params_start = j + 1;
            let mut depth = 1usize;
            let mut k = params_start;
            while k < n && depth > 0 {
                match chars[k] {
                    '(' | '[' => depth += 1,
                    ')' | ']' => {
                        if (chars[k] == ')') && depth == 1 {
                            break;
                        }
                        depth -= 1;
                    }
                    '\'' | '"' => {
                        let quote = chars[k];
                        k += 1;
                        while k < n && chars[k] != quote {
                            if chars[k] == '\\' {
                                k += 1;
                            }
                            k += 1;
                        }
                    }
                    _ => {}
                }
                k += 1;
            }
            let params_end = k.min(n); // 指向 ')'（或末尾）
            let param_text: String = chars[params_start..params_end].iter().collect();
            let param_names = split_param_names(&param_text);

            // 找函数体 '{'
            let mut m = params_end + 1;
            while m < n && chars[m].is_whitespace() {
                m += 1;
            }
            if m >= n || chars[m] != '{' {
                i += 1;
                continue;
            }
            // 函数体结束：大括号配平（感知字符串/注释）
            let body_start = m + 1;
            let body_end = find_block_end(&chars, m);

            if !param_names.is_empty() && body_end > body_start {
                scan_shadows(&chars, body_start, body_end, &param_names, &mut plans);
            }
            i += 1;
        } else {
            i += 1;
        }
    }

    if plans.is_empty() {
        return src.to_string();
    }

    // 上下文感知地应用改名：只改代码上下文（含模板表达式内）的整词命中，
    // 字符串/注释/正则内容一律原样保留。
    apply_renames(&chars, &plans)
}

/// 上下文感知的改名应用：与 collapse_double_dots 相同的走查结构
/// （上下文栈 + 字符串/注释/模板/正则识别），仅在代码上下文中改名。
fn apply_renames(chars: &[char], plans: &[ShadowPlan]) -> String {
    let n = chars.len();
    let mut out = String::with_capacity(n);

    #[derive(Clone, Copy)]
    enum Ctx {
        Code(usize),
        TplText,
    }
    let mut stack: Vec<Ctx> = vec![Ctx::Code(0)];
    let mut last_code_char: Option<char> = None;

    let mut i = 0usize;
    while i < n {
        let c = chars[i];
        let top = *stack.last().unwrap();

        if matches!(top, Ctx::TplText) {
            // 模板文本：原样输出（内部不改名），识别转义、反引号收尾与美元花括号进入表达式
            if c == '\\' && i + 1 < n {
                out.push(c);
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '\u{60}' {
                out.push(c);
                stack.pop();
                i += 1;
                continue;
            }
            if c == '$' && i + 1 < n && chars[i + 1] == '{' {
                out.push(c);
                out.push(chars[i + 1]);
                stack.push(Ctx::Code(0));
                i += 2;
                continue;
            }
            out.push(c);
            i += 1;
            continue;
        }

        // ── 代码上下文 ──
        let depth = match top {
            Ctx::Code(d) => d,
            _ => unreachable!(),
        };

        // 行注释 / 块注释：原样吞到结束（内部不改名）
        if c == '/' && i + 1 < n {
            if chars[i + 1] == '/' {
                let mut j = i;
                while j < n && chars[j] != '\n' {
                    out.push(chars[j]);
                    j += 1;
                }
                i = j;
                continue;
            }
            if chars[i + 1] == '*' {
                out.push(c);
                out.push(chars[i + 1]);
                let mut j = i + 2;
                loop {
                    if j + 1 < n && chars[j] == '*' && chars[j + 1] == '/' {
                        out.push(chars[j]);
                        out.push(chars[j + 1]);
                        j += 2;
                        break;
                    }
                    out.push(chars[j]);
                    j += 1;
                    if j >= n {
                        break;
                    }
                }
                i = j;
                continue;
            }
        }

        // 字符串字面量：原样吞到收尾引号（内部不改名）
        if c == '\'' || c == '"' {
            let quote = c;
            out.push(c);
            i += 1;
            while i < n {
                if chars[i] == '\\' && i + 1 < n {
                    out.push(chars[i]);
                    out.push(chars[i + 1]);
                    i += 2;
                    continue;
                }
                out.push(chars[i]);
                if chars[i] == quote {
                    i += 1;
                    break;
                }
                i += 1;
            }
            last_code_char = Some(quote);
            continue;
        }

        // 模板字面量开始：压栈进入模板文本
        if c == '\u{60}' {
            out.push(c);
            stack.push(Ctx::TplText);
            last_code_char = Some('\u{60}');
            i += 1;
            continue;
        }

        // 正则字面量（启发式）：原样吞到收尾斜杠（内部不改名）
        if c == '/' && is_regex_start(last_code_char) {
            out.push(c);
            i += 1;
            let mut in_class = false;
            while i < n {
                if chars[i] == '\\' && i + 1 < n {
                    out.push(chars[i]);
                    out.push(chars[i + 1]);
                    i += 2;
                    continue;
                }
                let ch = chars[i];
                if in_class {
                    out.push(ch);
                    if ch == ']' {
                        in_class = false;
                    }
                    i += 1;
                    continue;
                }
                if ch == '[' {
                    in_class = true;
                    out.push(ch);
                    i += 1;
                    continue;
                }
                if ch == '/' {
                    out.push(ch);
                    i += 1;
                    break;
                }
                if ch == '\n' {
                    // 正则不能跨行；换行说明不是正则（保守回退）
                    out.push(ch);
                    i += 1;
                    break;
                }
                out.push(ch);
                i += 1;
            }
            last_code_char = Some('/');
            continue;
        }

        // 大括号深度维护（模板表达式内）
        if c == '{' {
            out.push(c);
            let d2 = depth + 1;
            let len = stack.len();
            stack[len - 1] = Ctx::Code(d2);
            last_code_char = Some('{');
            i += 1;
            continue;
        }
        if c == '}' {
            out.push(c);
            if depth > 0 || stack.len() > 1 {
                if depth > 0 {
                    let len = stack.len();
                    stack[len - 1] = Ctx::Code(depth - 1);
                } else {
                    // 模板表达式的收尾大括号：弹回模板文本
                    stack.pop();
                }
            }
            // 顶层多余的大括号（畸形脚本）：原样输出，不弹根上下文，避免栈空
            last_code_char = Some('}');
            i += 1;
            continue;
        }

        // 标识符词首：检查改名命中（仅代码上下文）；初始化值窗口
        // [init_start, init_end) 内的同名引用保留参数名（空窗口无排除）
        if let Some(id) = identifier_at(chars, i) {
            let hit = plans.iter().find(|p| {
                p.name == id
                    && i >= p.decl_pos
                    && i < p.body_end
                    && !(i >= p.init_start && i < p.init_end)
            });
            if let Some(p) = hit {
                out.push_str(&p.name);
                out.push('_');
                out.push('s');
                out.push('h');
                out.push('i');
                out.push('m');
                let mut tok_end = i + 1;
                while tok_end < n
                    && (chars[tok_end].is_alphanumeric()
                        || chars[tok_end] == '_'
                        || chars[tok_end] == '$')
                {
                    tok_end += 1;
                }
                // 标识符不在正则起始集合中：置为词首字符等价于不更新
                last_code_char = Some(chars[i]);
                i = tok_end;
                continue;
            }
        }

        out.push(c);
        if !c.is_whitespace() {
            last_code_char = Some(c);
        }
        i += 1;
    }
    out
}

/// pos 处若为完整标识符的词首则返回其文本，否则 None。
fn identifier_at(chars: &[char], pos: usize) -> Option<String> {
    let is_part = |c: char| c.is_alphanumeric() || c == '_' || c == '$';
    if pos >= chars.len() || !is_part(chars[pos]) {
        return None;
    }
    // 向前后扩展取整词；pos 必须是词首
    let mut a = pos;
    while a > 0 && is_part(chars[a - 1]) {
        a -= 1;
    }
    if a != pos {
        return None;
    }
    let mut b = pos + 1;
    while b < chars.len() && is_part(chars[b]) {
        b += 1;
    }
    Some(chars[a..b].iter().collect())
}

/// 在 pos 处判断是否为关键字 keyword 的完整词（前后不接标识符字符）。
fn at_keyword(chars: &[char], pos: usize, keyword: &str) -> bool {
    if pos + keyword.len() > chars.len() {
        return false;
    }
    let kw: Vec<char> = keyword.chars().collect();
    for k in 0..keyword.len() {
        if chars[pos + k] != kw[k] {
            return false;
        }
    }
    let is_part = |c: char| c.is_alphanumeric() || c == '_' || c == '$';
    let before_ok = pos == 0 || !is_part(chars[pos - 1]);
    let after = pos + keyword.len();
    let after_ok = after >= chars.len() || !is_part(chars[after]);
    before_ok && after_ok
}

/// 从 block_open（指向 '{'）找配平收尾，返回收尾 '}' 的下标。
fn find_block_end(chars: &[char], open: usize) -> usize {
    let n = chars.len();
    let mut depth = 0usize;
    let mut i = open;
    while i < n {
        match chars[i] {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return i;
                }
            }
            '\'' | '"' => {
                let quote = chars[i];
                i += 1;
                while i < n && chars[i] != quote {
                    if chars[i] == '\\' {
                        i += 1;
                    }
                    i += 1;
                }
            }
            '/' => {
                if i + 1 < n && chars[i + 1] == '/' {
                    while i < n && chars[i] != '\n' {
                        i += 1;
                    }
                    continue;
                }
                if i + 1 < n && chars[i + 1] == '*' {
                    i += 2;
                    while i + 1 < n && !(chars[i] == '*' && chars[i + 1] == '/') {
                        i += 1;
                    }
                    i += 1;
                    continue;
                }
            }
            _ => {}
        }
        i += 1;
    }
    n // 未配平：保守取末尾
}

/// 拆分参数列表为参数名（只处理简单标识符参数；解构/复杂默认值跳过）。
fn split_param_names(param_text: &str) -> Vec<String> {
    let mut names = Vec::new();
    for part in param_text.split(',') {
        let t = part.trim();
        if t.is_empty() {
            continue;
        }
        // 简单参数：标识符，或 “标识符 = 默认值”
        let name = t.split('=').next().unwrap_or("").trim();
        let is_ident = !name.is_empty()
            && name
                .chars()
                .all(|c| c.is_alphanumeric() || c == '_' || c == '$');
        if is_ident {
            names.push(name.to_string());
        }
    }
    names
}

/// 在 [start, end) 内找 let/const <参数名> 影子声明，追加到 plans。
///
/// 按“声明项”解析：每个名称 ∈ param_names 的项生成一个改名计划——
/// 声明名本身与初始化值结束之后（至函数体结束）的引用改名为
/// `<name>_shim`；初始化值窗口 [init_start, init_end) 内的同名引用
/// **保留参数名**：`let P = P || ...` 自引用初始化式右侧的 P 按作者
/// （Rhino 宽容、无 TDZ）意图解析为**参数**（书旗 #26 实证），改名
/// 会触发 QuickJS 自引用 TDZ 运行时报错。
/// - 多声明列表（`let a, x = 1`）中初始化值窗口天然延伸过顶层逗号
///   至整条语句结束（后续项初始化值中的同名引用同样按参数处理）；
///   无初始化值项在多声明列表中窗口同样保守延伸至语句结束；
/// - 解构声明 / 项首非标识符：放弃整条语句。
fn scan_shadows(
    chars: &[char],
    start: usize,
    end: usize,
    param_names: &[String],
    plans: &mut Vec<ShadowPlan>,
) {
    let n = chars.len();
    let mut i = start;
    while i < end {
        // 跳过字符串与注释，避免误匹配
        match chars[i] {
            '\'' | '"' => {
                let quote = chars[i];
                i += 1;
                while i < n && chars[i] != quote {
                    if chars[i] == '\\' {
                        i += 1;
                    }
                    i += 1;
                }
                i += 1;
                continue;
            }
            '/' => {
                if i + 1 < n && chars[i + 1] == '/' {
                    while i < n && chars[i] != '\n' {
                        i += 1;
                    }
                    continue;
                }
                if i + 1 < n && chars[i + 1] == '*' {
                    i += 2;
                    while i + 1 < n && !(chars[i] == '*' && chars[i + 1] == '/') {
                        i += 1;
                    }
                    i += 1;
                    continue;
                }
            }
            _ => {}
        }

        let is_let = chars[i] == 'l' && at_keyword(chars, i, "let");
        let is_const = chars[i] == 'c' && at_keyword(chars, i, "const");
        if is_let || is_const {
            let kw_len = if is_let { 3 } else { 5 };
            // 只接受“简单声明名”：每个逗号分隔项的首个标识符（无解构模式）。
            // 解构声明（const {a} = ...）无法可靠处理，整条语句放弃。
            let mut j = i + kw_len;
            while j < end && chars[j].is_whitespace() {
                j += 1;
            }
            if j < end && (chars[j] == '{' || chars[j] == '[') {
                // 解构声明（const {a} = ...）：无法可靠处理，整条语句放弃
                i = j;
                continue;
            }
            // 逐项解析：(名称位置, 名称, 初始化值起点, 项后位置, 是否有初始化值)。
            // 初始化值起点 = '=' 下标（无初始化值 = 名后空白结束处，窗口空）；
            // 项后位置 = 初始化值走查结束处（语句终止符下标，走查不停顿于多声明
            // 列表的顶层逗号）或逗号/终止符下标。
            let mut items: Vec<(usize, String, usize, usize, bool)> = Vec::new();
            let mut k = j;
            let mut multi = false;
            while k < end {
                let ch = chars[k];
                if ch == ',' {
                    k += 1;
                    multi = true;
                    while k < end && chars[k].is_whitespace() {
                        k += 1;
                    }
                    continue;
                }
                if ch == ';' || ch == '\n' {
                    k += 1;
                    break;
                }
                if ch == '{' || ch == '[' {
                    // 解构模式：放弃本条语句
                    while k < end && chars[k] != ';' && chars[k] != '\n' {
                        k += 1;
                    }
                    items.clear();
                    break;
                }
                let Some(name) = identifier_at(chars, k) else {
                    // 项首非标识符：放弃本条语句
                    items.clear();
                    k = end;
                    break;
                };
                let name_pos = k;
                k += name.chars().count();
                // 声明名之后只允许非换行空白（换行触发 ASI/语法错误）
                let mut ws = k;
                while ws < end && chars[ws].is_whitespace() && chars[ws] != '\n' {
                    ws += 1;
                }
                let (init_start, post_pos, has_init) = if ws < end && chars[ws] == '=' {
                    let s = ws;
                    let mut w = ws + 1;
                    let mut d = 0usize;
                    while w < end {
                        let c2 = chars[w];
                        // 字符串字面量整体吞掉：串内括号不计深度（防止
                        // "a(" 之类不平衡串内字符拖宽窗口）
                        if c2 == '\'' || c2 == '"' {
                            let q = c2;
                            w += 1;
                            while w < end && chars[w] != q {
                                if chars[w] == '\\' {
                                    w += 1;
                                }
                                w += 1;
                            }
                            w += 1;
                            continue;
                        }
                        if c2 == '/' && w + 1 < end {
                            if chars[w + 1] == '/' {
                                while w < end && chars[w] != '\n' {
                                    w += 1;
                                }
                                continue;
                            }
                            if chars[w + 1] == '*' {
                                w += 2;
                                while w + 1 < end && !(chars[w] == '*' && chars[w + 1] == '/') {
                                    w += 1;
                                }
                                w += 1;
                                continue;
                            }
                        }
                        match c2 {
                            '(' | '[' | '{' => d += 1,
                            ')' | ']' | '}' => d = d.saturating_sub(1),
                            _ => {}
                        }
                        // 深度 0 的语句终止符结束走查；多声明列表的顶层
                        // ',' 不终止：窗口延伸过后续项直至语句末尾
                        if (c2 == ';' || c2 == '\n') && d == 0 {
                            break;
                        }
                        w += 1;
                    }
                    (s, w, true)
                } else {
                    // 无初始化值（let a, / let a ASI）：窗口空，项结束于
                    // 逗号/终止符/函数体末
                    (ws, ws, false)
                };
                items.push((name_pos, name, init_start, post_pos, has_init));
                k = post_pos;
            }
            // 循环结束时 k = 语句终止符之后（或函数体末）
            let stmt_end = k;
            for (name_pos, name, init_start, post_pos, has_init) in items {
                if !param_names.contains(&name) {
                    continue;
                }
                // 初始化值窗口 [init_start, init_end)：窗口内同名引用保留
                // 参数名（按作者 Rhino 意图，见模块头注释），声明名与
                // 窗口外引用改名。
                let init_end = if has_init {
                    post_pos
                } else if multi {
                    stmt_end
                } else {
                    init_start // 单声明无初始化值：空窗口
                };
                plans.push(ShadowPlan {
                    decl_pos: name_pos,
                    name,
                    body_end: end,
                    init_start,
                    init_end,
                });
            }
        }
        i += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── 第 2 类：双点折叠 ──

    #[test]
    fn double_dot_collapsed_in_code() {
        let (out, changed) = normalize("return data..item_null.text");
        assert_eq!(out, "return data.item_null.text");
        assert!(changed);
    }

    #[test]
    fn double_dot_in_string_untouched() {
        let src = "let s = 'a..b';";
        let (out, changed) = normalize(src);
        assert_eq!(out, src);
        assert!(!changed);
    }

    #[test]
    fn triple_dot_spread_untouched() {
        let src = "let x = f(...args);";
        let (out, changed) = normalize(src);
        assert_eq!(out, src);
        assert!(!changed);
    }

    #[test]
    fn double_dot_in_template_expression_collapsed() {
        // JS 模板字面量：let t = `x ${data..item} y`;（反引号以 \u{60} 表示）
        let src = "let t = \u{60}x ${data..item} y\u{60};";
        let (out, _) = normalize(src);
        assert!(out.contains("data.item"));
    }

    #[test]
    fn block_comment_untouched() {
        // 块注释必须原样保留（含内部的双点与参数名）
        let src = "let a = 1; /* x..y bu */ let b = 2;";
        let (out, changed) = normalize(src);
        assert_eq!(out, src);
        assert!(!changed);
    }

    #[test]
    fn rename_skips_strings_comments_regex() {
        // 改名只发生在代码上下文：字符串、正则、注释内容一律不动
        let src = "function f(bu){ let bu = 1; return s + '..' + /bu/ + 'x bu y'; }";
        let (out, _) = normalize(src);
        assert!(out.contains("let bu_shim = 1;"));
        assert!(out.contains("'..'"));
        assert!(out.contains("/bu/"));
        assert!(out.contains("'x bu y'"));
    }

    #[test]
    fn destructuring_reference_is_not_shadow() {
        // 解构赋值中出现的参数名是引用不是声明，不得改名（bili Map/getHeaderMap 案例）
        let src = "function Map(e,that){ const { source } = that || this; return getHeaderMap(that||this)[e]; }";
        let (out, changed) = normalize(src);
        assert_eq!(out, src);
        assert!(!changed);
    }

    #[test]
    fn multi_decl_list_still_detected() {
        // 多声明列表 let a, x = 1：a 仍是真影子
        let src = "function f(a){ let a, x = 1; return a + x; }";
        let (out, _) = normalize(src);
        assert!(out.contains("let a_shim, x = 1;"));
        assert!(out.contains("return a_shim + x;"));
    }

    #[test]
    fn number_range_not_collapsed() {
        // 数字前的双点不折叠（保守）
        let src = "let r = 1..2;";
        let (out, _) = normalize(src);
        assert_eq!(out, src);
    }

    // ── 第 1 类：参数影子重命名 ──

    #[test]
    fn let_param_shadow_renamed() {
        let src = "function showCom(bu){\n let bu = 'x';\n return bu;\n}";
        let (out, changed) = normalize(src);
        assert!(changed);
        assert!(out.contains("let bu_shim ="));
        // 声明后的引用同步改名
        assert!(out.contains("return bu_shim;"));
    }

    #[test]
    fn normal_param_untouched() {
        let src = "function f(bu){ return bu; }";
        let (out, changed) = normalize(src);
        assert_eq!(out, src);
        assert!(!changed);
    }

    // ── 第 1 类：自引用初始化值窗口（书旗 #26 实证）──

    #[test]
    fn self_referencing_initializer_keeps_param() {
        // #26 书旗形态：`let P = P || "d"` 自引用初始化式——右侧 P 按作者
        // （Rhino 宽容、无 TDZ）意图解析为参数，必须保留参数名；声明名与
        // 声明后的引用改名。旧实现把右侧也改名 → `P_shim || "d"` 自引用
        // TDZ（QuickJS 运行时 "is not initialized"）。
        let src = "function GetUrl(path, params, sourceUrl){\n\
                   let sourceUrl = sourceUrl || \"https://shuqi.example/\";\n\
                   return sourceUrl;\n}";
        let (out, changed) = normalize(src);
        assert!(changed);
        assert!(
            out.contains("let sourceUrl_shim = sourceUrl ||"),
            "实际: {out}"
        );
        // 声明后（初始化值语句结束处起）的引用改名
        assert!(out.contains("return sourceUrl_shim;"), "实际: {out}");
        // 右侧参数引用保留
        assert!(
            out.contains("= sourceUrl || \"https://shuqi.example/\";"),
            "实际: {out}"
        );
    }

    #[test]
    fn self_referencing_initializer_no_initializer_ref_after() {
        // 初始化值之后的语句引用改名、初始化值内保留：
        // `let P = f(P)` 函数调用形态同理。
        let src = "function f(x){ let x = x || 1; return x; }";
        let (out, _) = normalize(src);
        assert!(out.contains("let x_shim = x || 1;"), "实际: {out}");
        assert!(out.contains("return x_shim;"), "实际: {out}");
    }

    #[test]
    fn initializer_window_string_parens_safe() {
        // 初始化值内不平衡串内括号不得拖宽窗口：
        // `let a = "(" + a; return a;` 的 `return a` 必须改名。
        let src = "function f(a){ let a = \"(\" + a; return a; }";
        let (out, _) = normalize(src);
        assert!(out.contains("let a_shim = \"(\" + a;"), "实际: {out}");
        assert!(out.contains("return a_shim;"), "实际: {out}");
    }

    #[test]
    fn multi_decl_no_init_item_window_extends() {
        // 多声明列表无初始化值项：`let a, x = a;` 后续项初始化值中的 a
        // 保守按参数处理（保留参数名），声明后引用改名。
        let src = "function f(a){ let a, x = a; return a + x; }";
        let (out, _) = normalize(src);
        assert!(out.contains("let a_shim, x = a;"), "实际: {out}");
        assert!(out.contains("return a_shim + x;"), "实际: {out}");
    }

    #[test]
    fn no_initializer_single_decl_still_renamed_after() {
        // 单声明无初始化值（`let a;`）：窗口空，声明后引用照常改名。
        let src = "function f(a){ let a; a = 1; return a; }";
        let (out, _) = normalize(src);
        assert!(out.contains("let a_shim;"), "实际: {out}");
        assert!(out.contains("a_shim = 1;"), "实际: {out}");
        assert!(out.contains("return a_shim;"), "实际: {out}");
    }

    // ── 综合：B 站 jsLib 的两个真实病灶（最小复现）──

    #[test]
    fn bili_style_combined_fix() {
        let src = "function showCom(bu){\n const {java} = this;\n let bu = book?String(book.tocUrl):'';\n return bu;\n}\nfunction p(){ return data..item_null.text }";
        let (out, changed) = normalize(src);
        assert!(changed);
        assert!(out.contains("let bu_shim"));
        assert!(out.contains("data.item_null"));
    }
}
