//! 换源「🏷松鹤庭沐·言璃」第二断点（详情 → 目录）只读诊断 example
//!
//! 背景：`bookUrl` 层已修复（搜索候选 = intro-info?bookid=1100468021），换源仍报
//! 「新书源未解析到任何章节，已保留原书源与目录」（source_switch.rs 中
//! `get_chapters_with_vars` 返回 Ok(vec![]) 的分支）。本 example 对齐
//! `switch_book_source_with` 的 2a/2b 步逐层取证：
//!
//!   ① 详情解析 `get_book_info_with_existing_and_vars` → 打印 `info.toc_url`
//!      （期望 `…all-chapter?bookId=1100468021`；若 `…bookId=`/空 → init 后
//!      `{{$.resourceID}}` 未求值）
//!   ② 手工复刻 `parse_book_info_from_body` 的 init → tocUrl 求值链，打印中间值
//!   ③ 目录抓取 `get_chapters_with_vars` → 实际章节数（0 = 复现症状）与首章
//!   ④ HTTP 对照实验：intro-info / all-chapter 在「带书源 header（UA+Referer）」
//!      与「不带」下的响应体前缀 → 判定目录请求是否透传书源头
//!
//! 运行（rust/ 目录下）：
//! `cargo run -p legado-ffi --example dbg_songhe_switch_break2 --features quickjs -- legado-ffi/tests/fixtures/songhe/source.json`
//! 或在 rust/legado-ffi 目录下不带参数运行（自动回退 tests/fixtures/songhe/source.json）。
//! 可选第 2 参数覆盖 bookUrl。
//!
//! 只读诊断：不修改任何既有源文件；仅新增本文件。

use legado_core::models::BookSource;
use legado_core::web_book::BookSourceFetcher;
use legado_ffi::api::web_book::RealBookSourceFetcher;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// 已确证的真实候选地址（bookId = 1100000000 + bid(468021)）
const BOOK_URL: &str =
    "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1100468021";

fn preview(s: &str, n: usize) -> String {
    let one_line = s.replace('\r', "").replace('\n', "\\n");
    let truncated: String = one_line.chars().take(n).collect();
    if one_line.chars().count() > n {
        format!("{truncated} …(总长 {})", s.len())
    } else {
        truncated
    }
}

fn read_source_text(arg: &str) -> (String, String) {
    for p in [
        arg,
        "tests/fixtures/songhe/source.json",
        "legado-ffi/tests/fixtures/songhe/source.json",
    ] {
        if Path::new(p).exists() {
            let text = fs::read_to_string(p).unwrap_or_else(|e| panic!("read {p}: {e}"));
            return (p.to_string(), text);
        }
    }
    panic!(
        "未找到书源 JSON（尝试过 {arg} / tests/fixtures/songhe/source.json / legado-ffi/tests/fixtures/songhe/source.json）"
    );
}

fn main() {
    let src_arg = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "tests/fixtures/songhe/source.json".into());
    let (src_path, source_text) = read_source_text(&src_arg);
    let source: BookSource = serde_json::from_str(&source_text).expect("parse BookSource");
    let book_url = std::env::args()
        .nth(2)
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| BOOK_URL.to_string());

    println!("############ 0. 输入与书源头 ############");
    println!("书源文件: {src_path}");
    println!(
        "书源: {} ({})",
        source.book_source_name, source.book_source_url
    );
    println!("bookUrl(候选): {book_url}");
    let raw_header = source.header.clone().unwrap_or_default();
    println!("书源 header 原文: {raw_header}");

    // 复刻 RealBookSourceFetcher::parse_source_headers 的静态部分（该函数私有，
    // 此处只做等价复刻：书源 header JSON → HashMap；login/JS Cookie 本机为空）
    let source_headers: HashMap<String, String> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok())
        .unwrap_or_default();
    println!("解析出的请求头（键=值）:");
    let mut keys: Vec<&String> = source_headers.keys().collect();
    keys.sort();
    for k in keys {
        println!("  {k} = {}", preview(&source_headers[k], 160));
    }
    let has_referer = source_headers.iter().any(|(k, v)| {
        k.eq_ignore_ascii_case("referer") && v.contains("bookshelf.html5.qq.com/qbread")
    });
    println!("含 Referer=https://bookshelf.html5.qq.com/qbread : {has_referer}");

    let toc_rule_raw = source
        .rule_book_info
        .as_ref()
        .and_then(|r| r.toc_url.clone())
        .unwrap_or_default();
    let init_rule_raw = source
        .rule_book_info
        .as_ref()
        .and_then(|r| r.init.clone())
        .unwrap_or_default();
    println!("ruleBookInfo.init    = {init_rule_raw:?}");
    println!("ruleBookInfo.tocUrl  = {toc_rule_raw:?}");
    println!(
        "ruleToc.chapterList  = {:?}",
        source
            .rule_toc
            .as_ref()
            .and_then(|r| r.chapter_list.clone())
            .unwrap_or_default()
    );

    let client = legado_ffi::http_state::shared_client().expect("shared client");

    // ─── ④ HTTP 对照（先做，取得原始响应用于 ② 的手工求值） ───────────────
    let toc_url_expected =
        "https://bookshelf.html5.qq.com/qbread/api/book/all-chapter?bookId=1100468021";
    println!("\n############ 4. HTTP 对照：带/不带书源头 ############");

    struct Probe {
        label: &'static str,
        url: String,
        with_headers: bool,
    }
    let probes = [
        Probe {
            label: "A intro-info  不给头",
            url: book_url.clone(),
            with_headers: false,
        },
        Probe {
            label: "B intro-info  给书源头",
            url: book_url.clone(),
            with_headers: true,
        },
        Probe {
            label: "C all-chapter 不给头",
            url: toc_url_expected.to_string(),
            with_headers: false,
        },
        Probe {
            label: "D all-chapter 给书源头",
            url: toc_url_expected.to_string(),
            with_headers: true,
        },
    ];
    let mut detail_body_with_headers = String::new();
    let mut detail_body_no_headers = String::new();
    let mut toc_body_with_headers = String::new();
    let mut toc_body_no_headers = String::new();
    for p in &probes {
        let headers = if p.with_headers {
            Some(source_headers.clone())
        } else {
            None
        };
        let resp = legado_ffi::runtime::block_on(async { client.get_raw(&p.url, headers).await });
        match resp {
            Ok(r) => {
                let body = String::from_utf8_lossy(&r.body).to_string();
                let rows = serde_json::from_str::<serde_json::Value>(&body)
                    .ok()
                    .and_then(|v| {
                        v.get("rows")
                            .map(|r| r.as_array().map(|a| a.len()).unwrap_or(0))
                    });
                println!(
                    "[{}] status={} bytes={} rows={:?}\n    body前200: {}",
                    p.label,
                    r.status,
                    r.body.len(),
                    rows,
                    preview(&body, 200)
                );
                match p.label {
                    l if l.starts_with('A') => detail_body_no_headers = body,
                    l if l.starts_with('B') => detail_body_with_headers = body,
                    l if l.starts_with('C') => toc_body_no_headers = body,
                    l if l.starts_with('D') => toc_body_with_headers = body,
                    _ => {}
                }
            }
            Err(e) => println!("[{}] 请求失败: {e}", p.label),
        }
    }
    println!(
        "[对照] 无头目录体==incorrect referer? {} / 有头目录体 rows≈? {}",
        toc_body_no_headers.trim() == "incorrect referer",
        preview(&toc_body_with_headers, 80)
    );

    // ─── ② 手工复刻详情 init → tocUrl 求值（含中间值） ─────────────────────
    println!("\n############ 2. 手工复刻 parse_book_info_from_body 的 init→tocUrl ############");
    let js_lib = source
        .js_lib
        .as_deref()
        .map(legado_ffi::api::source_js_bindings::sanitize_js_lib_for_quickjs);
    let setup = legado_ffi::api::source_js_bindings::book_source_js_setup_script(&source).ok();
    let make_analyzer = |body: String| {
        legado_ffi::js_executor::construct_analyzer_with_source_context(
            body,
            book_url.clone(),
            &source.book_source_url,
            js_lib.as_deref(),
            setup.clone(),
        )
    };

    for (tag, body) in [
        ("带书源头（B 响应体）", detail_body_with_headers.clone()),
        ("不带书源头（A 响应体）", detail_body_no_headers.clone()),
    ] {
        println!("--- ② {tag} ---");
        let mut analyzer = make_analyzer(body);
        let init_result = analyzer.get_string(&init_rule_raw).unwrap_or_default();
        println!(
            "init 规则 {init_rule_raw:?} 求值: len={} contains_resourceID={} 前120={}",
            init_result.len(),
            init_result.contains("\"resourceID\""),
            preview(&init_result, 120)
        );
        if !init_result.is_empty() {
            analyzer.set_element_content(init_result);
        }
        let direct_field = analyzer.get_string("$.resourceID").unwrap_or_default();
        println!("  set_element_content 后 $.resourceID = {direct_field:?}");
        let direct_tpl = analyzer.get_string("{{$.resourceID}}").unwrap_or_default();
        println!("  set_element_content 后 双花括号模板 $.resourceID = {direct_tpl:?}");
        let toc_val = analyzer.get_string(&toc_rule_raw).unwrap_or_default();
        println!("  tocUrl 规则整体求值 = {toc_val:?}");
    }

    // ─── ① 公开 API：详情解析 ─────────────────────────────────────────────
    println!("\n############ 1. 公开 API 详情解析（对齐换源 2a） ############");
    let fetcher = RealBookSourceFetcher::new().expect("fetcher new");
    let empty_vars = HashMap::new();
    let info = legado_ffi::runtime::block_on(async {
        fetcher
            .get_book_info_with_existing_and_vars(
                &source,
                &book_url,
                false,
                "既有书名",
                "既有作者",
                &empty_vars,
            )
            .await
    });
    let info = match info {
        Ok(i) => i,
        Err(e) => {
            println!("详情解析失败(Err): {e}");
            return;
        }
    };
    println!(
        "info: name={:?} author={:?} toc_url={:?}",
        info.name, info.author, info.toc_url
    );
    println!("info.word_count={:?} kind={:?}", info.word_count, info.kind);
    println!("info.variable={:?}", info.variable);
    let toc_ok = info.toc_url == toc_url_expected;
    println!("toc_url 是否符合期望（{toc_url_expected}）: {}", toc_ok);

    // 复刻 source_switch 2b 的 toc_url 选择逻辑
    let toc_url_for_chapters = if info.toc_url.trim().is_empty() {
        book_url.clone()
    } else {
        info.toc_url.clone()
    };
    println!("换源 2b 将使用的 toc_url = {toc_url_for_chapters}");

    // 该 toc_url 经 AnalyzeUrl::parse 后的请求形态（fetch_page 实际请求 URL）
    match legado_parser::AnalyzeUrl::parse(&toc_url_for_chapters, &empty_vars, 1) {
        Ok(au) => {
            println!(
                "AnalyzeUrl::parse → url={:?}\n                   method={:?} headers={:?}",
                au.url(),
                au.method(),
                au.headers()
            );
        }
        Err(e) => println!("AnalyzeUrl::parse 失败: {e}"),
    }

    // ─── ③ 公开 API：目录抓取 ─────────────────────────────────────────────
    println!("\n############ 3. 公开 API 目录抓取（对齐换源 2b） ############");
    let chapters = legado_ffi::runtime::block_on(async {
        fetcher
            .get_chapters_with_vars(&source, &toc_url_for_chapters, &empty_vars)
            .await
    });
    match chapters {
        Ok(list) => {
            println!("get_chapters_with_vars 返回章节数 = {}", list.len());
            for c in list.iter().take(3) {
                println!(
                    "  章[{}] title={:?} url={}",
                    c.index,
                    c.title,
                    preview(&c.url, 120)
                );
            }
        }
        Err(e) => println!("get_chapters_with_vars Err: {e}"),
    }

    // 对照组 1：直接指定已确证的 all-chapter URL（known_toc_url 路径）抓目录
    let control = legado_ffi::runtime::block_on(async {
        fetcher
            .get_chapters_with_hints(&source, &book_url, Some(toc_url_expected), None)
            .await
    });
    match control {
        Ok(list) => println!(
            "[对照1] get_chapters_with_hints(known_toc) 章节数 = {}",
            list.len()
        ),
        Err(e) => println!("[对照1] Err: {e}"),
    }

    // 对照组 2：把「详情页 URL」传给 get_chapters_with_vars。
    // [2026-09-17 方案 A 新契约] 入参按「已解析目录页 URL」直抓跑 ruleToc，
    // 不再走 bookUrl → init → tocUrl 重推。松鹤属目录/详情分离源（详情体
    // 无章节列表），此处返回 0 章为预期结果；目录内嵌详情页的源（详情体
    // 即目录体）传详情 URL 才能出章（见 toc_no_rederive_tests 同名回归）。
    let control2 = legado_ffi::runtime::block_on(async {
        fetcher
            .get_chapters_with_vars(&source, &book_url, &empty_vars)
            .await
    });
    match control2 {
        Ok(list) => println!(
            "[对照2] get_chapters_with_vars(详情页URL) 章节数 = {}",
            list.len()
        ),
        Err(e) => println!("[对照2] Err: {e}"),
    }

    // 手工复刻「失败调用」的 else 分支推导：入参=all-chapter URL 被当详情页，
    // init($.data.bookInfo) 在 all-chapter 体上取空 → tocUrl 规则在该体上重推
    println!("\n--- 手工复刻失败分支（入参 all-chapter URL 被当详情页） ---");
    {
        let mut a = make_analyzer(toc_body_with_headers.clone());
        let init_on_toc = a.get_string(&init_rule_raw).unwrap_or_default();
        println!(
            "在 all-chapter 响应体上跑 init {init_rule_raw:?}: len={} (期望 0，因无 data.bookInfo)",
            init_on_toc.len()
        );
        if !init_on_toc.is_empty() {
            a.set_element_content(init_on_toc);
        }
        let derived = a.get_string(&toc_rule_raw).unwrap_or_default();
        println!("在 all-chapter 响应体上重推 tocUrl 规则 = {derived:?}");
        println!(
            "  → 第二次抓取 URL = {}",
            legado_parser::AnalyzeUrl::get_absolute_url(&toc_url_for_chapters, &derived)
        );
    }
    // 该 `…bookId=`（空值）在服务端的实际响应
    {
        let bad_url = "https://bookshelf.html5.qq.com/qbread/api/book/all-chapter?bookId=";
        let resp = legado_ffi::runtime::block_on(async {
            client.get_raw(bad_url, Some(source_headers.clone())).await
        });
        match resp {
            Ok(r) => {
                let body = String::from_utf8_lossy(&r.body).to_string();
                let rows = serde_json::from_str::<serde_json::Value>(&body)
                    .ok()
                    .and_then(|v| {
                        v.get("rows")
                            .map(|x| x.as_array().map(|a| a.len()).unwrap_or(0))
                    });
                println!(
                    "all-chapter?bookId= 实测: status={} rows={:?} body前160={}",
                    r.status,
                    rows,
                    preview(&body, 160)
                );
            }
            Err(e) => println!("all-chapter?bookId= 请求失败: {e}"),
        }
    }

    // ─── 摘要 ────────────────────────────────────────────────────────────
    println!("\n############ 摘要 ############");
    println!(
        "详情 toc_url = {:?}（期望 bookId=1100468021）",
        info.toc_url
    );
    println!("换源 2b toc_url = {toc_url_for_chapters}");
    println!(
        "手工 init 求值（带书源头）len={}，init 后 $.resourceID={:?}",
        detail_body_with_headers.len(),
        {
            let mut a = make_analyzer(detail_body_with_headers.clone());
            let i = a.get_string(&init_rule_raw).unwrap_or_default();
            if !i.is_empty() {
                a.set_element_content(i);
            }
            a.get_string("$.resourceID").unwrap_or_default()
        }
    );
}
