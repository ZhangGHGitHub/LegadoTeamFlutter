//! 真实书源「🏷松鹤庭沐·言璃」`ruleSearch.bookUrl` 多行 JS 链取值空离线复现
//!
//! 用法（rust/ 目录下）：
//! `cargo run -p legado-ffi --example dbg_songhe_bookurl --features quickjs`
//! 默认读 cwd 下 `tmp_songhe.json`（BookSource 导出）与
//! `tmp_songhe_search.json`（真实搜索响应）；可传参覆盖：
//! `-- <booksource.json> <search_response.json>`
//!
//! 逐段对比求值并原样打印（空串显式标注）：
//!   (a) 完整 bookUrl 多行链（content = booklist[0] 元素，element 模式）
//!   (b) 单行 `$.bid`（同上 content）
//!   (c) 仅末尾模板段 `https://…?bookid={{result}}`（content = "1100468021"，
//!       即第 2 段 JS 步的产出，模拟链内子解析器状态）
//!   (d) 完整 coverUrl 多行链（content = booklist[0]，对照可正常取值的字段）
//!   (e)-(h) 最小变体：确认失效机制
//!   - (e) 末尾段 `{{result}}` → `{{1+1}}`
//!   - (f) 末尾段改 `@js:` 前缀（JS 末段，结果直出）
//!   - (g) 无 `{{}}` 的纯字面 URL 规则
//!   - (h) 末尾模板段 + content = 元素 JSON（观察 `{{result}}` 预展开落点）

use legado_core::models::BookSource;
use legado_ffi::js_executor::construct_analyzer_with_source_context;
use std::fs;

/// 与真实请求一致的 base_url（web_book.rs 中 base_url = 实际请求/重定向 URL）
const BASE_URL: &str = "https://newopensearch.reader.qq.com/wechat?keyword=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86&start=0&end=19";

/// 末尾模板段原文（bookUrl 第 3 段）
const TAIL_TPL: &str =
    "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{result}}";

/// 与 web_book.rs 一致地构造元素解析器并求值单条规则，原样打印结果
fn eval_case(
    label: &str,
    source: &BookSource,
    content: &str,
    element_mode: bool,
    rule: &str,
) -> String {
    let search_lib = source
        .js_lib
        .as_deref()
        .map(legado_ffi::api::source_js_bindings::sanitize_js_lib_for_quickjs);
    let mut analyzer = construct_analyzer_with_source_context(
        content.to_string(),
        BASE_URL.to_string(),
        &source.book_source_url,
        search_lib.as_deref(),
        legado_ffi::api::source_js_bindings::book_source_js_setup_script(source).ok(),
    );
    if element_mode {
        analyzer.set_element_content(content.to_string());
    } else {
        analyzer.set_content(content.to_string());
    }

    let rule_disp = rule.replace('\n', "\\n");
    match analyzer.get_string(rule) {
        Ok(v) if v.is_empty() => {
            println!("[{label}] rule: {rule_disp:?}\n        => [空串]\n");
            String::new()
        }
        Ok(v) => {
            let shown: String = v.chars().take(300).collect();
            let more = if v.len() > 300 {
                format!(" …(共 {} 字符)", v.len())
            } else {
                String::new()
            };
            println!("[{label}] rule: {rule_disp:?}\n        => {shown}{more}\n");
            v
        }
        Err(e) => {
            println!("[{label}] rule: {rule_disp:?}\n        => [Err: {e}]\n");
            String::new()
        }
    }
}

fn main() {
    let src_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "tmp_songhe.json".to_string());
    let search_path = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "tmp_songhe_search.json".to_string());

    let source_text = fs::read_to_string(&src_path).expect("read booksource json");
    let source: BookSource = serde_json::from_str(&source_text).expect("parse BookSource");
    let search_rule = source
        .rule_search
        .as_ref()
        .expect("rule_search missing in tmp_songhe.json");
    let book_url_rule = search_rule.book_url.clone().unwrap_or_default();
    let cover_url_rule = search_rule.cover_url.clone().unwrap_or_default();

    println!(
        "=== 书源: {} ({}) ===",
        source.book_source_name, source.book_source_url
    );
    println!(
        "jsLib: {}",
        if source.js_lib.as_ref().is_some_and(|s| !s.trim().is_empty()) {
            "present"
        } else {
            "absent"
        }
    );
    println!(
        "\n--- ruleSearch.bookUrl 原文 ---\n{book_url_rule}\n--- ruleSearch.coverUrl 原文 ---\n{cover_url_rule}\n"
    );

    // 元素内容：真实搜索响应 booklist[0]（web_book.rs get_elements 产物为 JSON 对象串）
    let search_text = fs::read_to_string(&search_path).expect("read search response json");
    let search: serde_json::Value = serde_json::from_str(&search_text).expect("parse search json");
    let elem = search
        .get("booklist")
        .and_then(|b| b.get(0))
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    let elem_json = serde_json::to_string(&elem).expect("serialize element");
    println!(
        "=== 元素 booklist[0]: bid={} title={} ===\n",
        elem.get("bid").and_then(|v| v.as_str()).unwrap_or("?"),
        elem.get("title").and_then(|v| v.as_str()).unwrap_or("?")
    );

    // 第 2 段 JS 步 `1100000000+parseInt(result)` 的产出（result = "468021"）
    const JS_OUT: &str = "1100468021";

    // (a) 完整 bookUrl 多行链 —— 复现生产取值空
    println!("===== (a) 完整 bookUrl 链（content=元素JSON, element模式） =====");
    let full_book_url = eval_case("a 完整bookUrl", &source, &elem_json, true, &book_url_rule);

    // (b) 单行第一段
    println!("===== (b) 单行 `$.bid` =====");
    eval_case("b $.bid", &source, &elem_json, true, "$.bid");

    // (c) 仅末尾模板段，content = 第 2 段 JS 产出（模拟链内子解析器）
    println!("===== (c) 末尾模板段（content=\"{JS_OUT}\"） =====");
    eval_case("c 末尾模板", &source, JS_OUT, false, TAIL_TPL);

    // (d) 完整 coverUrl 链（对照：生产可正常取值）
    println!("===== (d) 完整 coverUrl 链（content=元素JSON, element模式） =====");
    let cover_url = eval_case("d 完整coverUrl", &source, &elem_json, true, &cover_url_rule);

    // ---- 最小变体（确认机制） ----
    println!("===== (e) 末尾段 {{result}} → {{1+1}}（content=\"{JS_OUT}\"） =====");
    eval_case(
        "e {{1+1}}",
        &source,
        JS_OUT,
        false,
        "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{1+1}}",
    );

    println!("===== (f) 末尾段改 @js: 前缀（JS 末段，content=\"{JS_OUT}\"） =====");
    eval_case(
        "f @js:末段",
        &source,
        JS_OUT,
        false,
        "@js:\n\"https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=\" + result",
    );

    println!("===== (g) 纯字面 URL（无 {{}}，content=\"{JS_OUT}\"） =====");
    eval_case(
        "g 字面URL",
        &source,
        JS_OUT,
        false,
        "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1100468021",
    );

    println!("===== (h) 末尾模板段 + content=元素JSON（观察 {{result}} 预展开落点） =====");
    eval_case("h 模板+元素", &source, &elem_json, true, TAIL_TPL);

    // ---- 结论摘要 ----
    println!("================ 摘要 ================");
    println!(
        "(a) 完整 bookUrl => {}",
        if full_book_url.is_empty() {
            "[空串]"
        } else {
            "非空"
        }
    );
    println!(
        "(d) 完整 coverUrl => {}",
        if cover_url.is_empty() {
            "[空串]"
        } else {
            "非空"
        }
    );
}
