//! JS 单文件书源配置工具
//!
//! 移植自 Kotlin `JsSourceConfig.kt`（247 行），提供三项能力：
//! - [`extract`]：执行 JS 书源脚本并提取顶层 `config`（兼容旧版 `source`）
//!   配置对象，归一化后产出 [`BookSource`]（对齐 Kotlin `extract`）
//! - [`stamp_last_update_time`]：在书源 mainJs 中把顶层配置对象的
//!   `lastUpdateTime` 值（数字字面量或 `Date.now()`）替换为新时间戳
//!   （对齐 Kotlin `stampLastUpdateTime`，#208/#515）
//! - [`syntax_check`]：JS 语法检查（#479），quickjs 构建下使用
//!   `QuickJsEngine::check_syntax`（compile-only，只编译不执行）；
//!   非 quickjs 构建降级为括号平衡基础检查

// 非 quickjs 构建下，仅供 quickjs 路径使用的辅助函数/常量不参与编译用途
#![cfg_attr(not(feature = "quickjs"), allow(dead_code))]

#[cfg(feature = "quickjs")]
use legado_core::models::book_source::book_source_type;
use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};
use serde_json::Value;

/// 顶层配置对象属性名（新版）
const CONFIG_PROPERTY: &str = "config";
/// 顶层配置对象属性名（旧版兼容）
const LEGACY_CONFIG_PROPERTY: &str = "source";

/// 普通书源必备函数（对齐 Kotlin requiredFunctions）
pub const REQUIRED_FUNCTIONS: &[&str] = &["search", "getChapters", "getContent"];
/// 文件类书源必备函数（对齐 Kotlin fileSourceRequiredFunctions）
const FILE_SOURCE_REQUIRED_FUNCTIONS: &[&str] = &["search", "getBookInfo"];

/// 提取时需剥离的键（规则体由 mainJs 承载，对齐 Kotlin strippedKeys）
const STRIPPED_KEYS: &[&str] = &[
    "mainJs",
    "ruleSearch",
    "ruleExplore",
    "ruleBookInfo",
    "ruleToc",
    "ruleContent",
    "ruleReview",
];

/// loginUi 函数模式标记（对齐 Kotlin LoginUiV2.MARKER）
const LOGIN_UI_MARKER: &str = r#"{"version":2}"#;

/// 语法检查结果（序列化为 JSON 后经 FFI 返回）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SyntaxCheckResult {
    /// 语法是否合法
    pub valid: bool,
    /// 说明信息（错误描述或检查方式说明）
    pub message: String,
    /// 错误行号（QuickJS 报错时可解析出；无则 None）
    pub line: Option<u32>,
}

// ─────────────────────────────────────────────────────────────
// extract：JS 单文件书源配置提取
// ─────────────────────────────────────────────────────────────

/// 提取 JS 单文件书源配置（对齐 Kotlin `JsSourceConfig.extract`）
///
/// 流程：eval 脚本 → 读取顶层 `config`/`source` 对象 → 剥离规则键 →
/// 归一化 exploreUrl/loginUi → 反序列化为 BookSource → 校验必备字段与函数配对
/// → `mainJs` 回填完整脚本。
///
/// 未启用 `quickjs` feature 时返回错误（JS 执行能力缺失）。
#[cfg(feature = "quickjs")]
pub fn extract(text: &str) -> LegadoResult<BookSource> {
    extract_quickjs(text)
}

/// 未启用 quickjs 时的降级实现：无法执行 JS，直接报错
#[cfg(not(feature = "quickjs"))]
pub fn extract(_text: &str) -> LegadoResult<BookSource> {
    Err(LegadoError::JsEngine(
        "JS源配置提取需要 QuickJS 引擎，请使用 --features quickjs 构建".to_string(),
    ))
}

/// 配置提取表达式：读取顶层 config/source，返回信封 JSON
///
/// 返回值约定：
/// - `{"missing":true}` — config 与 source 均不存在
/// - `{"name":"config|source","json":null}` — 配置对象无法序列化
/// - `{"name":"config|source","json":"..."}` — 配置 JSON 文本
const EXTRACT_EXPR: &str = r#"(function(){
  function complete(v){
    return !!v && typeof v === 'object'
      && typeof v.bookSourceUrl === 'string' && v.bookSourceUrl.trim() !== ''
      && typeof v.bookSourceName === 'string' && v.bookSourceName.trim() !== '';
  }
  try {
    var hasConfig = (typeof config !== 'undefined') && config !== null;
    var hasLegacy = (typeof source !== 'undefined') && source !== null;
    if (!hasConfig && !hasLegacy) return '{"missing":true}';
    var pick, name;
    if (hasConfig && (!hasLegacy || complete(config))) { pick = config; name = 'config'; }
    else { pick = source; name = 'source'; }
    var json = null;
    if (typeof pick === 'string') json = pick;
    else if (pick && typeof pick === 'object') {
      try { json = JSON.stringify(pick); } catch (e2) { json = null; }
    }
    return JSON.stringify({name: name, json: json});
  } catch (e) { return '{"missing":true}'; }
})()"#;

/// 顶层函数探测表达式：对每个约定函数返回 fn / val / none 三态
const PROBE_EXPR: &str = r#"(function(){
  function st(t){ return t === 'function' ? 'fn' : (t === 'undefined' ? 'none' : 'val'); }
  return JSON.stringify({
    search: st(typeof search),
    getChapters: st(typeof getChapters),
    getContent: st(typeof getContent),
    getBookInfo: st(typeof getBookInfo),
    explore: st(typeof explore),
    loginUiFn: st(typeof loginUi),
    login: st(typeof login),
    loginAction: st(typeof loginAction),
    getReviewSummary: st(typeof getReviewSummary),
    getReviewDetail: st(typeof getReviewDetail)
  });
})()"#;

#[cfg(feature = "quickjs")]
fn extract_quickjs(text: &str) -> LegadoResult<BookSource> {
    use crate::engine::{JsEngine, QuickJsEngine};
    use crate::sandbox::SandboxConfig;

    if text.trim().is_empty() {
        return Err(LegadoError::JsEngine("JS源脚本为空".to_string()));
    }

    // 独立沙箱引擎：默认配置（禁文件/禁 eval）+ 适度放宽超时（脚本顶层可能做初始化）
    let sandbox = SandboxConfig::default().with_timeout(std::time::Duration::from_secs(10));
    let engine = QuickJsEngine::new(sandbox)?;

    // 1. 执行书源脚本（定义 config 与函数；对齐 Kotlin RhinoScriptEngine.eval）
    engine
        .eval(text)
        .map_err(|e| LegadoError::JsEngine(format!("JS源脚本执行失败: {}", e)))?;

    // 2. 提取配置信封（对齐 Kotlin findConfig + isCompleteConfig）
    let envelope = engine
        .eval(EXTRACT_EXPR)
        .map_err(|e| LegadoError::JsEngine(format!("JS源配置探测失败: {}", e)))?;
    let env: Value = serde_json::from_str(&envelope)
        .map_err(|_| LegadoError::JsEngine("JS源配置对象无法解析".to_string()))?;
    if env.get("missing") == Some(&Value::Bool(true)) {
        return Err(LegadoError::JsEngine(
            "JS源缺少顶层 config 配置对象（兼容旧版 source）".to_string(),
        ));
    }
    let config_name = env
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or(CONFIG_PROPERTY)
        .to_string();
    let raw_json = env.get("json").and_then(|v| v.as_str()).ok_or_else(|| {
        LegadoError::JsEngine(format!("{} 配置对象无法解析", config_name))
    })?;

    // 3. 解析配置 JSON（对齐 Kotlin GSON.fromJson(json, JsonObject)）
    let mut value: Value = serde_json::from_str(raw_json)
        .map_err(|_| LegadoError::JsEngine(format!("{} 配置对象不是合法对象", config_name)))?;
    let obj = value.as_object_mut().ok_or_else(|| {
        LegadoError::JsEngine(format!("{} 配置对象不是合法对象", config_name))
    })?;

    // 4. 剥离规则键（mainJs 由本流程回填，规则体不进入 BookSource 字段）
    for key in STRIPPED_KEYS {
        obj.remove(*key);
    }

    // 5. 归一化 exploreUrl / loginUi（对齐 Kotlin normalizeExploreUrl/normalizeLoginUi）
    normalize_explore_url(obj)?;
    normalize_login_ui(obj)?;

    // 6. 反序列化为 BookSource（lenient 解析，兼容字符串数字等宽松格式）
    let mut source: BookSource = serde_json::from_value(value).map_err(|_| {
        LegadoError::JsEngine(format!("{} 配置对象字段类型不符", config_name))
    })?;

    // 7. 必备字段校验
    if source.book_source_url.trim().is_empty() {
        return Err(LegadoError::JsEngine(format!(
            "JS源 {}.bookSourceUrl 不能为空",
            config_name
        )));
    }
    if source.book_source_name.trim().is_empty() {
        return Err(LegadoError::JsEngine(format!(
            "JS源 {}.bookSourceName 不能为空",
            config_name
        )));
    }

    // 8. 顶层函数探测与配对校验
    let probe_raw = engine
        .eval(PROBE_EXPR)
        .map_err(|e| LegadoError::JsEngine(format!("JS源函数探测失败: {}", e)))?;
    let probe: Value = serde_json::from_str(&probe_raw)
        .map_err(|_| LegadoError::JsEngine("JS源函数探测结果解析失败".to_string()))?;
    let probe_of = |name: &str| -> String {
        probe
            .get(name)
            .and_then(|v| v.as_str())
            .unwrap_or("none")
            .to_string()
    };

    // 必备函数（文件类书源用 getBookInfo 替代 getChapters/getContent）
    let required = if source.book_source_type == book_source_type::FILE {
        FILE_SOURCE_REQUIRED_FUNCTIONS
    } else {
        REQUIRED_FUNCTIONS
    };
    for name in required {
        if probe_of(name) != "fn" {
            return Err(LegadoError::JsEngine(format!(
                "JS源缺少必备函数 {}",
                name
            )));
        }
    }

    // exploreUrl 与 explore 函数配对
    let has_explore_url = source
        .explore_url
        .as_ref()
        .is_some_and(|s| !s.trim().is_empty());
    if has_explore_url && probe_of("explore") != "fn" {
        return Err(LegadoError::JsEngine(
            "JS源声明了 exploreUrl,缺少配对的 explore 函数".to_string(),
        ));
    }

    // loginUi 函数 / loginUi 数据二选一及配对
    if probe_of("loginUiFn") == "fn" {
        if source.login_ui.as_ref().is_some_and(|s| !s.trim().is_empty()) {
            return Err(LegadoError::JsEngine(
                "loginUi 函数与 config.loginUi 数据只能二选一".to_string(),
            ));
        }
        if probe_of("loginAction") != "fn" {
            return Err(LegadoError::JsEngine(
                "JS源声明了 loginUi 函数,缺少配对的 loginAction 函数".to_string(),
            ));
        }
        source.login_ui = Some(LOGIN_UI_MARKER.to_string());
    } else if source.login_ui.as_ref().is_some_and(|s| !s.trim().is_empty())
        && probe_of("login") != "fn"
    {
        return Err(LegadoError::JsEngine(
            "JS源声明了 loginUi,缺少配对的 login 函数".to_string(),
        ));
    }

    // 书评函数配对（声明则必须是函数，且 summary/detail 成对出现）
    let summary = probe_of("getReviewSummary");
    let detail = probe_of("getReviewDetail");
    let declares_summary = summary != "none";
    let declares_detail = detail != "none";
    if declares_summary && summary != "fn" {
        return Err(LegadoError::JsEngine(
            "JS源 getReviewSummary 必须是函数".to_string(),
        ));
    }
    if declares_detail && detail != "fn" {
        return Err(LegadoError::JsEngine(
            "JS源 getReviewDetail 必须是函数".to_string(),
        ));
    }
    if declares_summary && !declares_detail {
        return Err(LegadoError::JsEngine(
            "JS源声明了 getReviewSummary,缺少配对的 getReviewDetail 函数".to_string(),
        ));
    }
    if declares_detail && !declares_summary {
        return Err(LegadoError::JsEngine(
            "JS源声明了 getReviewDetail,缺少配对的 getReviewSummary 函数".to_string(),
        ));
    }

    // 9. mainJs 回填完整脚本
    source.main_js = Some(text.to_string());
    Ok(source)
}

/// 归一化 exploreUrl（对齐 Kotlin normalizeExploreUrl）
///
/// 数组形式：校验每项 title 非空后转为 JSON 字符串；空数组移除该键。
fn normalize_explore_url(
    obj: &mut serde_json::Map<String, Value>,
) -> LegadoResult<()> {
    let element = match obj.get("exploreUrl") {
        Some(v) => v.clone(),
        None => return Ok(()),
    };
    if let Value::Array(arr) = &element {
        if arr.is_empty() {
            obj.remove("exploreUrl");
            return Ok(());
        }
        for (index, item) in arr.iter().enumerate() {
            let title = item
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if title.trim().is_empty() {
                return Err(LegadoError::JsEngine(format!(
                    "exploreUrl 第 {} 项缺少 title",
                    index + 1
                )));
            }
        }
        let serialized = serde_json::to_string(arr)
            .map_err(|e| LegadoError::JsEngine(format!("exploreUrl 序列化失败: {e}")))?;
        obj.insert("exploreUrl".to_string(), Value::String(serialized));
    }
    Ok(())
}

/// 归一化 loginUi（对齐 Kotlin normalizeLoginUi）
///
/// 字符串 `"[]"` 或空数组移除该键；数组形式校验每项 name 后转 JSON 字符串。
fn normalize_login_ui(
    obj: &mut serde_json::Map<String, Value>,
) -> LegadoResult<()> {
    let element = match obj.get("loginUi") {
        Some(v) => v.clone(),
        None => return Ok(()),
    };
    match &element {
        Value::String(s) => {
            let compact: String = s.chars().filter(|c| !c.is_whitespace()).collect();
            if compact == "[]" {
                obj.remove("loginUi");
            }
        }
        Value::Array(arr) => {
            if arr.is_empty() {
                obj.remove("loginUi");
                return Ok(());
            }
            for (index, item) in arr.iter().enumerate() {
                let name = item.get("name").and_then(|v| v.as_str()).unwrap_or("");
                if name.trim().is_empty() {
                    return Err(LegadoError::JsEngine(format!(
                        "loginUi 第 {} 项缺少 name",
                        index + 1
                    )));
                }
            }
            let serialized = serde_json::to_string(arr)
                .map_err(|e| LegadoError::JsEngine(format!("loginUi 序列化失败: {e}")))?;
            obj.insert("loginUi".to_string(), Value::String(serialized));
        }
        _ => {}
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────
// syntax_check：JS 语法检查（#479）
// ─────────────────────────────────────────────────────────────

/// JS 语法检查入口
///
/// - quickjs 构建：调用 [`crate::engine::QuickJsEngine::check_syntax`]
///   （compile-only，只编译不执行），错误信息含行号线索
/// - 非 quickjs 构建：降级为括号平衡基础检查
pub fn syntax_check(text: &str) -> SyntaxCheckResult {
    if text.trim().is_empty() {
        return SyntaxCheckResult {
            valid: false,
            message: "JS源内容为空".to_string(),
            line: None,
        };
    }

    #[cfg(feature = "quickjs")]
    {
        use crate::engine::QuickJsEngine;
        use crate::sandbox::SandboxConfig;
        match QuickJsEngine::new(SandboxConfig::default()) {
            Ok(engine) => match engine.check_syntax(text) {
                Ok(()) => SyntaxCheckResult {
                    valid: true,
                    message: "语法检查通过".to_string(),
                    line: None,
                },
                Err(msg) => SyntaxCheckResult {
                    line: parse_error_line(&msg),
                    message: msg,
                    valid: false,
                },
            },
            // 引擎创建失败时降级为基础检查
            Err(_) => fallback_bracket_check(text),
        }
    }

    #[cfg(not(feature = "quickjs"))]
    {
        fallback_bracket_check(text)
    }
}

/// 从 QuickJS 错误信息中解析行号
///
/// 错误信息含栈帧（格式 `<文件名>:<行号>:<列号>`），依次尝试
/// `source.js` / `<input>`（Function 构造器编译产物，行号需减 2 修正
/// `function anonymous(\n)` 包装前缀偏移）/ `<anonymous>` / `<eval>`。
fn parse_error_line(msg: &str) -> Option<u32> {
    for (candidate, offset) in [
        ("source.js:", 0i64),
        ("<input>:", 2),
        ("<anonymous>:", 2),
        ("<eval>:", 0),
    ] {
        if let Some(idx) = msg.find(candidate) {
            let rest = &msg[idx + candidate.len()..];
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(line) = digits.parse::<i64>() {
                return Some((line - offset).max(1) as u32);
            }
        }
    }
    None
}

/// 非 quickjs 降级检查：括号平衡（跳过字符串与注释）
fn fallback_bracket_check(text: &str) -> SyntaxCheckResult {
    let b = text.as_bytes();
    let mut i = 0usize;
    let mut stack: Vec<u8> = Vec::new();
    while i < b.len() {
        match b[i] {
            b'"' | b'\'' => i = skip_string(b, i),
            b'`' => i = skip_template(b, i),
            b'/' if i + 1 < b.len() && b[i + 1] == b'/' => i = skip_line_comment(b, i),
            b'/' if i + 1 < b.len() && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            b'{' | b'[' | b'(' => {
                stack.push(b[i]);
                i += 1;
            }
            b'}' | b']' | b')' => {
                let expected = match b[i] {
                    b'}' => b'{',
                    b']' => b'[',
                    _ => b'(',
                };
                match stack.pop() {
                    Some(open) if open == expected => {}
                    _ => {
                        return SyntaxCheckResult {
                            valid: false,
                            message: format!(
                                "括号不匹配（基础检查，未启用 QuickJS）：位置 {}",
                                i
                            ),
                            line: None,
                        }
                    }
                }
                i += 1;
            }
            _ => i += 1,
        }
    }
    if stack.is_empty() {
        SyntaxCheckResult {
            valid: true,
            message: "括号平衡检查通过（未启用 QuickJS，仅基础检查）".to_string(),
            line: None,
        }
    } else {
        SyntaxCheckResult {
            valid: false,
            message: "括号未闭合（基础检查，未启用 QuickJS）".to_string(),
            line: None,
        }
    }
}

// ─────────────────────────────────────────────────────────────
// stamp_last_update_time：更新时间写回
// ─────────────────────────────────────────────────────────────

/// 在 JS 源脚本中写回 lastUpdateTime（对齐 Kotlin `stampLastUpdateTime`）
///
/// 定位顶层 `var/let/const config|source = {...}` 对象字面量中
/// `lastUpdateTime` 属性，且值为数字字面量或 `Date.now()` 的位置，
/// 替换为给定时间戳。找不到可替换位置时返回 `None`。
pub fn stamp_last_update_time(text: &str, stamp: i64) -> Option<String> {
    let mut ranges = find_update_time_ranges(text);
    if ranges.is_empty() {
        return None;
    }
    // 从后向前替换，避免偏移量失效
    ranges.sort_by_key(|(start, _)| std::cmp::Reverse(*start));
    let stamp_str = stamp.to_string();
    let mut result = text.to_string();
    for (start, end) in ranges {
        result.replace_range(start..end, &stamp_str);
    }
    Some(result)
}

/// 扫描脚本，收集所有可替换的 lastUpdateTime 值区间（字节偏移）
fn find_update_time_ranges(text: &str) -> Vec<(usize, usize)> {
    let b = text.as_bytes();
    let n = b.len();
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let mut i = 0usize;
    let mut depth = 0usize; // 大括号嵌套深度（字符串/注释不计）
    while i < n {
        match b[i] {
            b'"' | b'\'' => i = skip_string(b, i),
            b'`' => i = skip_template(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'/' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            b'{' => {
                depth += 1;
                i += 1;
            }
            b'}' => {
                depth = depth.saturating_sub(1);
                i += 1;
            }
            _ if depth == 0 && is_ident_start(b[i]) => {
                let start = i;
                while i < n && is_ident_char(b[i]) {
                    i += 1;
                }
                let word = &text[start..i];
                if word == "var" || word == "let" || word == "const" {
                    i = scan_declaration(b, text, i, &mut ranges);
                }
            }
            _ => i += 1,
        }
    }
    ranges
}

/// 扫描 var/let/const 声明列表，寻找 `config|source = {...}` 并收集区间
fn scan_declaration(
    b: &[u8],
    text: &str,
    mut i: usize,
    ranges: &mut Vec<(usize, usize)>,
) -> usize {
    let n = b.len();
    loop {
        i = skip_trivia(b, i);
        if i >= n || !is_ident_start(b[i]) {
            return i;
        }
        let start = i;
        while i < n && is_ident_char(b[i]) {
            i += 1;
        }
        let name = &text[start..i];
        i = skip_trivia(b, i);
        if i < n && b[i] == b'=' {
            i = skip_trivia(b, i + 1);
            if i < n && b[i] == b'{' {
                if name == CONFIG_PROPERTY || name == LEGACY_CONFIG_PROPERTY {
                    let (end, found) = scan_config_object(b, text, i);
                    ranges.extend(found);
                    i = end;
                } else {
                    i = skip_balanced(b, i);
                }
            } else if i < n && b[i] == b'[' {
                i = skip_balanced(b, i);
            } else {
                i = skip_initializer(b, i);
            }
        }
        i = skip_trivia(b, i);
        if i < n && b[i] == b',' {
            i += 1;
            continue;
        }
        return i;
    }
}

/// 扫描 config/source 对象字面量，收集一级属性中可替换的 lastUpdateTime 值区间
///
/// 返回（对象结束后的位置，收集到的区间列表）
fn scan_config_object(
    b: &[u8],
    text: &str,
    start: usize,
) -> (usize, Vec<(usize, usize)>) {
    let n = b.len();
    let mut found: Vec<(usize, usize)> = Vec::new();
    let mut i = start + 1; // 跳过 '{'
    let mut rel = 1usize; // 相对该对象的嵌套深度
    while i < n && rel > 0 {
        i = skip_trivia(b, i);
        if i >= n {
            break;
        }
        // 一级深度：尝试解析属性键（标识符或字符串字面量）
        if rel == 1 {
            let mut key: Option<String> = None;
            if b[i] == b'"' || b[i] == b'\'' {
                if let Some((content, end)) = read_string(b, i) {
                    key = Some(content);
                    i = end;
                } else {
                    i += 1;
                    continue;
                }
            } else if is_ident_start(b[i]) {
                let s = i;
                while i < n && is_ident_char(b[i]) {
                    i += 1;
                }
                key = Some(text[s..i].to_string());
            }
            if let Some(k) = key {
                let j = skip_trivia(b, i);
                if j < n && b[j] == b':' {
                    i = skip_trivia(b, j + 1);
                    if k == "lastUpdateTime" {
                        if let Some((vs, ve)) = read_supported_value(b, i) {
                            found.push((vs, ve));
                            i = ve;
                            continue;
                        }
                    }
                    i = skip_value(b, i);
                    continue;
                }
                continue;
            }
        }
        match b[i] {
            b'{' | b'[' => {
                rel += 1;
                i += 1;
            }
            b'}' | b']' => {
                rel -= 1;
                i += 1;
            }
            b'"' | b'\'' => i = skip_string(b, i),
            b'`' => i = skip_template(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'/' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            _ => i += 1,
        }
    }
    (i, found)
}

/// 读取受支持的值：数字字面量或 `Date.now()` 调用（对齐 Kotlin isSupportedValue）
///
/// 返回值的字节区间；不支持的值返回 None。
/// 数字字面量后必须是 `,`/`}`/`]`，避免误替换表达式（如 `1 + 2`）。
fn read_supported_value(b: &[u8], i: usize) -> Option<(usize, usize)> {
    let n = b.len();
    if i >= n {
        return None;
    }
    // 数字字面量（含 0x/0o/小数/指数形式，字符集按字面量合法字符宽松消费）
    if b[i].is_ascii_digit() || (b[i] == b'.' && i + 1 < n && b[i + 1].is_ascii_digit()) {
        let s = i;
        let mut j = i;
        while j < n && (b[j].is_ascii_alphanumeric() || b[j] == b'.' || b[j] == b'_') {
            j += 1;
        }
        // 指数符号：1e+10 / 1e-10
        if j < n && (b[j] == b'+' || b[j] == b'-') {
            let prev = b[j - 1];
            if prev == b'e' || prev == b'E' {
                j += 1;
                while j < n && b[j].is_ascii_digit() {
                    j += 1;
                }
            }
        }
        let after = skip_trivia(b, j);
        if after < n && matches!(b[after], b',' | b'}' | b']') {
            return Some((s, j));
        }
        return None;
    }
    // Date.now() 调用
    if i + 8 <= n && &b[i..i + 8] == b"Date.now" {
        let mut j = skip_trivia(b, i + 8);
        if j < n && b[j] == b'(' {
            j = skip_trivia(b, j + 1);
            if j < n && b[j] == b')' {
                let after = skip_trivia(b, j + 1);
                if after < n && matches!(b[after], b',' | b'}' | b']') {
                    return Some((i, j + 1));
                }
            }
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────
// 词法辅助（字节级扫描，ASCII 安全；非 ASCII 字节视为标识符字符）
// ─────────────────────────────────────────────────────────────

fn is_ident_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_' || c == b'$' || c >= 0x80
}

fn is_ident_char(c: u8) -> bool {
    is_ident_start(c) || c.is_ascii_digit()
}

/// 跳过空白与注释，返回新位置
fn skip_trivia(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    loop {
        while i < n && (b[i] as char).is_ascii_whitespace() {
            i += 1;
        }
        if i + 1 < n && b[i] == b'/' && b[i + 1] == b'/' {
            i = skip_line_comment(b, i);
        } else if i + 1 < n && b[i] == b'/' && b[i + 1] == b'*' {
            i = skip_block_comment(b, i);
        } else {
            return i;
        }
    }
}

/// 跳过单行注释（i 指向第一个 '/'），返回换行符或末尾位置
fn skip_line_comment(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    while i < n && b[i] != b'\n' {
        i += 1;
    }
    i
}

/// 跳过块注释（i 指向第一个 '/'），返回 '*/' 之后位置
fn skip_block_comment(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    i += 2;
    while i + 1 < n {
        if b[i] == b'*' && b[i + 1] == b'/' {
            return i + 2;
        }
        i += 1;
    }
    n
}

/// 跳过字符串字面量（i 指向引号），返回闭引号之后位置；
/// 支持反斜杠转义；未闭合时返回末尾
fn skip_string(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    let quote = b[i];
    i += 1;
    while i < n {
        if b[i] == b'\\' {
            i += 2;
            continue;
        }
        if b[i] == quote {
            return i + 1;
        }
        if b[i] == b'\n' {
            return i; // 非模板字符串不跨行，防御未闭合
        }
        i += 1;
    }
    n
}

/// 读取字符串字面量内容（i 指向引号），返回 (内容, 闭引号之后位置)
fn read_string(b: &[u8], i: usize) -> Option<(String, usize)> {
    let n = b.len();
    let quote = b[i];
    let mut j = i + 1;
    let mut content = Vec::new();
    while j < n {
        if b[j] == b'\\' && j + 1 < n {
            content.push(b[j + 1]); // 简化：转义字符按字面收录（键名比较足够）
            j += 2;
            continue;
        }
        if b[j] == quote {
            return Some((String::from_utf8_lossy(&content).to_string(), j + 1));
        }
        if b[j] == b'\n' {
            return None;
        }
        content.push(b[j]);
        j += 1;
    }
    None
}

/// 跳过模板字符串（i 指向反引号），返回闭反引号之后位置。
/// 注：`${}` 内嵌表达式按普通内容处理（不做嵌套模板解析），
/// 对配置区域的扫描场景影响可忽略。
fn skip_template(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    i += 1;
    while i < n {
        if b[i] == b'\\' {
            i += 2;
            continue;
        }
        if b[i] == b'`' {
            return i + 1;
        }
        i += 1;
    }
    n
}

/// 跳过成对括号块（i 指向 '{'/'['/'('），返回闭括号之后位置
fn skip_balanced(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    let open = b[i];
    let close = match open {
        b'{' => b'}',
        b'[' => b']',
        _ => b')',
    };
    let mut d = 0usize;
    while i < n {
        match b[i] {
            b'"' | b'\'' => i = skip_string(b, i),
            b'`' => i = skip_template(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'/' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            c if c == open => {
                d += 1;
                i += 1;
            }
            c if c == close => {
                d -= 1;
                i += 1;
                if d == 0 {
                    return i;
                }
            }
            _ => i += 1,
        }
    }
    i
}

/// 跳过非对象/数组初始化表达式，停在顶层 ',' 或 ';' 处
fn skip_initializer(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    while i < n {
        match b[i] {
            b'"' | b'\'' => i = skip_string(b, i),
            b'`' => i = skip_template(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'/' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            b'{' | b'[' | b'(' => i = skip_balanced(b, i),
            b',' | b';' => return i,
            _ => i += 1,
        }
    }
    i
}

/// 跳过一个值表达式：停在一级 ',' '}' ']' ';' 前（括号内不判定）
fn skip_value(b: &[u8], mut i: usize) -> usize {
    let n = b.len();
    let mut d = 0usize;
    while i < n {
        match b[i] {
            b'"' | b'\'' => i = skip_string(b, i),
            b'`' => i = skip_template(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'/' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            b'{' | b'[' | b'(' => {
                d += 1;
                i += 1;
            }
            b'}' | b']' => {
                if d == 0 {
                    return i;
                }
                d -= 1;
                i += 1;
            }
            b')' => {
                d = d.saturating_sub(1);
                i += 1;
            }
            b',' | b';' if d == 0 => return i,
            _ => i += 1,
        }
    }
    i
}

// ─────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── stamp_last_update_time：更新时间写回 ──

    #[test]
    fn stamp_replaces_top_level_number_literal() {
        let text = "var config = {\n  bookSourceUrl: 'u',\n  lastUpdateTime: 123,\n};";
        let out = stamp_last_update_time(text, 999).expect("应替换成功");
        assert!(out.contains("lastUpdateTime: 999,"), "{}", out);
        assert!(!out.contains("123"));
    }

    #[test]
    fn stamp_replaces_date_now_call() {
        let text = "var config = { lastUpdateTime: Date.now() };";
        let out = stamp_last_update_time(text, 42).unwrap();
        assert!(out.contains("lastUpdateTime: 42"), "{}", out);
        assert!(!out.contains("Date.now"));
    }

    #[test]
    fn stamp_replaces_legacy_source_variable() {
        let text = "var source = { bookSourceUrl: 'u', lastUpdateTime: 7 };";
        let out = stamp_last_update_time(text, 42).unwrap();
        assert!(out.contains("lastUpdateTime: 42"), "{}", out);
    }

    #[test]
    fn stamp_skips_nested_objects() {
        let text = "var config = {\n  ruleSearch: { lastUpdateTime: 111 },\n  lastUpdateTime: 222\n};";
        let out = stamp_last_update_time(text, 999).unwrap();
        assert!(out.contains("lastUpdateTime: 111"), "嵌套不应替换: {}", out);
        assert!(out.contains("lastUpdateTime: 999"), "顶层应替换: {}", out);
    }

    #[test]
    fn stamp_ignores_expression_values() {
        // 非字面量/非 Date.now() 的值不替换（对齐 Kotlin isSupportedValue）
        let text = "var config = { lastUpdateTime: 1 + 2 };";
        assert!(stamp_last_update_time(text, 9).is_none());
    }

    #[test]
    fn stamp_returns_none_without_match() {
        assert!(stamp_last_update_time("var config = { foo: 1 };", 9).is_none());
        assert!(stamp_last_update_time("var x = { lastUpdateTime: 5 };", 9).is_none());
    }

    #[test]
    fn stamp_handles_multi_declaration() {
        let text = "var a = 1, config = { lastUpdateTime: 5 };";
        let out = stamp_last_update_time(text, 88).unwrap();
        assert!(out.contains("lastUpdateTime: 88"), "{}", out);
        assert!(out.contains("var a = 1"));
    }

    #[test]
    fn stamp_ignores_keys_inside_strings_and_comments() {
        let text = "// lastUpdateTime: 111\nvar config = { note: \"lastUpdateTime: 222\", lastUpdateTime: 333 };";
        let out = stamp_last_update_time(text, 7).unwrap();
        assert!(out.contains("note: \"lastUpdateTime: 222\""), "{}", out);
        assert!(out.contains("lastUpdateTime: 7"), "{}", out);
        assert!(out.contains("// lastUpdateTime: 111"), "注释不应被改动: {}", out);
    }

    // ── syntax_check：语法检查 ──

    #[test]
    fn syntax_check_empty_input() {
        let r = syntax_check("   ");
        assert!(!r.valid);
        assert!(r.message.contains("为空"));
    }

    #[test]
    fn syntax_check_balanced_brackets_fallback_accepts() {
        // 无论是否启用 quickjs，合法代码均应通过
        let r = syntax_check("var a = 1;\nfunction f(x) { return x + 1; }");
        assert!(r.valid, "{}", r.message);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn syntax_check_quickjs_rejects_invalid_script() {
        let r = syntax_check("var a = 1;\nvar b = ;\n");
        assert!(!r.valid, "{}", r.message);
        // QuickJS 报错栈含行号线索，应定位到第 2 行
        assert_eq!(r.line, Some(2), "message={:?}", r.message);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn syntax_check_quickjs_does_not_execute_code() {
        // compile-only：即使代码运行时必抛异常，语法检查也应通过
        let r = syntax_check("throw new Error('boom');\nvar a = nonexistent_symbol;");
        assert!(r.valid, "{}", r.message);
    }

    // ── extract：配置提取（仅 quickjs 构建）──

    #[cfg(feature = "quickjs")]
    const FULL_SOURCE: &str = "var config = {\n  bookSourceUrl: 'https://example.com',\n  bookSourceName: '测试书源',\n  bookSourceType: 0,\n  lastUpdateTime: 1700000000000,\n  ruleSearch: { bookList: 'li.book' },\n  mainJs: 'OLD_JS'\n};\nfunction search(key) { return key; }\nfunction getChapters() { return []; }\nfunction getContent() { return ''; }";

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_full_source() {
        let src = extract(FULL_SOURCE).expect("提取应成功");
        assert_eq!(src.book_source_url, "https://example.com");
        assert_eq!(src.book_source_name, "测试书源");
        // mainJs 回填完整脚本（剥离旧值）
        assert_eq!(src.main_js.as_deref(), Some(FULL_SOURCE));
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_legacy_source_variable() {
        let text = "var source = { bookSourceUrl: 'https://legacy.com', bookSourceName: '旧版' };\n\
                    function search(k) { return k; }\n\
                    function getChapters() { return []; }\n\
                    function getContent() { return ''; }";
        let src = extract(text).expect("旧版 source 应兼容");
        assert_eq!(src.book_source_url, "https://legacy.com");
        assert_eq!(src.book_source_name, "旧版");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_missing_required_function_fails() {
        let text = "var config = { bookSourceUrl: 'u', bookSourceName: 'n' };\nfunction search(k) { return k; }";
        let err = extract(text).unwrap_err();
        assert!(err.to_string().contains("getChapters"), "{}", err);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_missing_config_fails() {
        let text = "function search(k) { return k; }";
        let err = extract(text).unwrap_err();
        assert!(err.to_string().contains("config"), "{}", err);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_empty_fails() {
        assert!(extract("  ").is_err());
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_normalizes_explore_url_array() {
        let text = "var config = {\n  bookSourceUrl: 'u',\n  bookSourceName: 'n',\n\
                    exploreUrl: [ { title: '热门', url: '/hot' } ]\n};\n\
                    function search(k) { return k; }\n\
                    function getChapters() { return []; }\n\
                    function getContent() { return ''; }\n\
                    function explore() { return []; }";
        let src = extract(text).expect("提取应成功");
        let explore = src.explore_url.expect("exploreUrl 应保留");
        assert!(explore.starts_with('['), "应为 JSON 数组字符串: {}", explore);
        assert!(explore.contains("热门"), "{}", explore);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_explore_url_without_function_fails() {
        let text = "var config = { bookSourceUrl: 'u', bookSourceName: 'n', exploreUrl: '/e' };\n\
                    function search(k) { return k; }\n\
                    function getChapters() { return []; }\n\
                    function getContent() { return ''; }";
        let err = extract(text).unwrap_err();
        assert!(err.to_string().contains("explore"), "{}", err);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_login_ui_function_sets_marker() {
        let text = "var config = { bookSourceUrl: 'u', bookSourceName: 'n' };\n\
                    function search(k) { return k; }\n\
                    function getChapters() { return []; }\n\
                    function getContent() { return ''; }\n\
                    function loginUi() { return []; }\n\
                    function loginAction() { return ''; }";
        let src = extract(text).expect("提取应成功");
        assert_eq!(src.login_ui.as_deref(), Some(LOGIN_UI_MARKER));
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_login_ui_function_conflicts_with_data() {
        let text = "var config = { bookSourceUrl: 'u', bookSourceName: 'n', loginUi: '[]x' };\n\
                    function search(k) { return k; }\n\
                    function getChapters() { return []; }\n\
                    function getContent() { return ''; }\n\
                    function loginUi() { return []; }\n\
                    function loginAction() { return ''; }";
        let err = extract(text).unwrap_err();
        assert!(err.to_string().contains("loginUi"), "{}", err);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn extract_normalizes_empty_login_ui() {
        // "[]" 字符串形式的 loginUi 应移除，无需 login 函数配对
        let text = "var config = { bookSourceUrl: 'u', bookSourceName: 'n', loginUi: '[]' };\n\
                    function search(k) { return k; }\n\
                    function getChapters() { return []; }\n\
                    function getContent() { return ''; }";
        let src = extract(text).expect("提取应成功");
        assert!(
            src.login_ui.as_ref().map_or(true, |s| s.trim().is_empty()),
            "空 loginUi 应被移除"
        );
    }
}
