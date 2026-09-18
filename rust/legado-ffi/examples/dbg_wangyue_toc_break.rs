//! P2-7(a)「📂网阅小说」换源后目录只出 1 条垃圾章节 —— 只读诊断 example
//!
//! 症状（q7.db 实机快照）：书籍《斗罗大陆》换源到「📂网阅小说」后 `chapters`
//! 表只剩 **1 行**：
//!   url   = https://book15.net/books/details3735.html   （= 详情页本身）
//!   title = 第688章 大结局，最后一个条件（全书完）        （= 目录最后一条）
//!   index = 687                                          （= 688 条里的最后一条）
//! 且 `books.latestChapterTitle` 变成整页 `<meta>` content 拼接（keywords +
//! description + … + latest_chapter_url，共 19 行）。
//!
//! 本 example 按证据链逐层取证（全部只读）：
//!   1. 书源规则静态打印（ruleBookInfo / ruleToc / header / searchUrl）
//!   2. 公开 API 详情解析 → 该源无 ruleBookInfo.tocUrl → toc_url 回退 bookUrl
//!   3. 四个候选响应体逐一实测（详情页 / m 站详情 / 陈旧 QQ 搜索页 / 站内搜索页）：
//!      - CSS `.d-chapter-list dd a` 命中数
//!      - 复刻 parse_chapters_from_toc_body 的逐元素循环 → 章节数 / 首尾章 /
//!        url 去重数 / url 回退 toc_url 的条数
//!   4. 公开 API 目录抓取（权威路径）→ 章节数、首尾章
//!   5. 内存 sqlite 复刻 `chapters` 表主键 (url,bookUrl) + INSERT OR REPLACE：
//!      验证「688 条 url 全部相同 → 坍缩成 1 行（最后一条）」是否解释 q7 现状
//!   6. CSS 属性选择器回归探针（`meta[property="og:novel:…"]@content` 等）
//!
//! 运行（rust/ 目录下）：
//! `cargo run -p legado-ffi --example dbg_wangyue_toc_break --features quickjs -- legado-ffi/tmp_diag/wangyue_source.json`
//! 或在 rust/legado-ffi 目录下不带参数运行（自动回退同路径）。
//!
//! 只读诊断：不修改任何既有源文件；仅新增本文件。

use legado_core::models::BookSource;
use legado_core::web_book::BookSourceFetcher;
use legado_ffi::api::web_book::RealBookSourceFetcher;
use legado_parser::HtmlParser;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// 真实详情页（= searchBooks 中 📂网阅小说/斗罗大陆 的 bookUrl）
const DETAIL_URL: &str = "https://book15.net/books/details3735.html";
/// m 站详情页（桌面页 meta mobile-agent 指向）
const MOBILE_URL: &str = "https://m.book15.net/books/details3735.html";
/// q7.db books.bookUrl 现值：陈旧 QQ 搜索页 URL（松鹤庭沐源的 searchUrl 形态）
const STALE_BOOK_URL: &str = "https://newopensearch.reader.qq.com/wechat?keyword=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86&amp%3Bstart=0&amp%3Bend=19";
/// 站内搜索页（ruleSearch 的落点）
const SEARCH_PAGE_URL: &str =
    "https://book15.net/books/search.html?kw=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86";

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
        "rust/legado-ffi/tmp_diag/wangyue_source.json",
        "legado-ffi/tmp_diag/wangyue_source.json",
        "tmp_diag/wangyue_source.json",
    ] {
        if Path::new(p).exists() {
            let text = fs::read_to_string(p).unwrap_or_else(|e| panic!("read {p}: {e}"));
            return (p.to_string(), text);
        }
    }
    panic!("未找到书源 JSON（尝试过 {arg} 及 tmp_diag/wangyue_source.json 系列路径）");
}

/// 复刻 `RealBookSourceFetcher::parse_source_headers` 的静态部分（该函数私有）
fn source_headers_of(source: &BookSource) -> HashMap<String, String> {
    source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok())
        .unwrap_or_default()
}

/// 逐元素复刻 `parse_chapters_from_toc_body` 主循环（不含 nextTocUrl 分页）
#[derive(Debug, Clone)]
struct ParsedChapter {
    index: usize,
    title: String,
    url: String,
}

fn parse_toc_body_like_engine(
    source: &BookSource,
    body: &str,
    toc_url: &str,
    js_lib: Option<&str>,
    setup: Option<String>,
    limit: usize,
) -> (usize, Vec<ParsedChapter>, String) {
    let chapter_list_rule = source
        .rule_toc
        .as_ref()
        .and_then(|r| r.chapter_list.as_deref())
        .unwrap_or("");
    let name_rule = source
        .rule_toc
        .as_ref()
        .and_then(|r| r.chapter_name.as_deref())
        .unwrap_or("");
    let url_rule = source
        .rule_toc
        .as_ref()
        .and_then(|r| r.chapter_url.as_deref())
        .unwrap_or("");

    let analyzer = legado_ffi::js_executor::construct_analyzer_with_source_context(
        body.to_string(),
        toc_url.to_string(),
        &source.book_source_url,
        js_lib,
        setup.clone(),
    )
    .with_js_binding(
        "book",
        &serde_json::json!({ "name": "斗罗大陆" }).to_string(),
    );

    let elements = analyzer.get_elements(chapter_list_rule).unwrap_or_default();
    let elem_total = elements.len();

    let mut elem_analyzer = legado_ffi::js_executor::construct_analyzer_with_source_context(
        String::new(),
        toc_url.to_string(),
        &source.book_source_url,
        js_lib,
        setup,
    )
    .with_js_binding(
        "book",
        &serde_json::json!({ "name": "斗罗大陆" }).to_string(),
    );

    let mut out = Vec::new();
    for (index, elem) in elements.iter().enumerate() {
        if index >= limit {
            break;
        }
        elem_analyzer.clear_variables();
        elem_analyzer.set_element_content(elem.clone());
        let mut title = elem_analyzer.get_string(name_rule).unwrap_or_default();
        let raw_url = elem_analyzer.get_string(url_rule).unwrap_or_default();
        if title.is_empty() && raw_url.is_empty() {
            continue;
        }
        if title.is_empty() {
            title = "无标题".to_string();
        }
        let url = if raw_url.is_empty() {
            toc_url.to_string()
        } else {
            legado_parser::AnalyzeUrl::get_absolute_url(toc_url, &raw_url)
        };
        out.push(ParsedChapter { index, title, url });
    }
    (elem_total, out, chapter_list_rule.to_string())
}

fn main() {
    let src_arg = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "rust/legado-ffi/tmp_diag/wangyue_source.json".into());
    let (src_path, source_text) = read_source_text(&src_arg);
    let source: BookSource = serde_json::from_str(&source_text).expect("parse BookSource");
    let headers = source_headers_of(&source);
    let client = legado_ffi::http_state::shared_client().expect("shared client");
    let empty_vars = HashMap::new();
    let js_lib = source
        .js_lib
        .as_deref()
        .map(legado_ffi::api::source_js_bindings::sanitize_js_lib_for_quickjs);
    let setup = legado_ffi::api::source_js_bindings::book_source_js_setup_script(&source).ok();

    println!("############ 1. 书源与规则（来自 q7.db book_sources） ############");
    println!("书源文件: {src_path}");
    println!(
        "书源: {} ({})",
        source.book_source_name, source.book_source_url
    );
    println!(
        "ruleBookInfo: {:?}",
        source.rule_book_info.as_ref().map(|r| {
            format!(
                "name={:?} author={:?} intro={:?} kind={:?} lastChapter={:?} coverUrl={:?} tocUrl={:?} init={:?}",
                r.name, r.author, r.intro, r.kind, r.last_chapter, r.cover_url, r.toc_url, r.init
            )
        })
    );
    println!(
        "ruleToc: {:?}",
        source.rule_toc.as_ref().map(|r| format!(
            "chapterList={:?} chapterName={:?} chapterUrl={:?} nextTocUrl={:?} formatJs={:?}",
            r.chapter_list, r.chapter_name, r.chapter_url, r.next_toc_url, r.format_js
        ))
    );
    println!("searchUrl: {:?}", source.search_url);
    println!("header: {}", source.header.clone().unwrap_or_default());

    // ── 2. 详情解析（公开 API，对齐换源 2a） ───────────────────────────────
    println!("\n############ 2. 公开 API 详情解析（tocUrl 推导） ############");
    let fetcher = RealBookSourceFetcher::new().expect("fetcher new");
    let info = legado_ffi::runtime::block_on(async {
        fetcher
            .get_book_info_with_existing_and_vars(
                &source,
                DETAIL_URL,
                false,
                "既有书名",
                "既有作者",
                &empty_vars,
            )
            .await
    });
    match info {
        Ok(i) => {
            println!(
                "info: name={:?} author={:?} kind={:?}",
                i.name, i.author, i.kind
            );
            println!(
                "info.toc_url = {:?}   （该源 ruleBookInfo.tocUrl 缺失 → 回退 bookUrl？ {}）",
                i.toc_url,
                i.toc_url == DETAIL_URL
            );
            println!(
                "info.cover_url = {}",
                preview(i.cover_url.as_deref().unwrap_or(""), 140)
            );
            println!(
                "info.last_chapter (len={}) = {}",
                i.last_chapter.as_deref().unwrap_or("").len(),
                preview(i.last_chapter.as_deref().unwrap_or(""), 160)
            );
            println!(
                "  ↑ 期望 `meta[property=\"og:novel:latest_chapter_name\"]@content` = 「大结局，最后一个条件（全书完）」；\n    若为多行 meta 拼接 = 属性选择器被误判为索引区间（见第 6 节探针）"
            );
        }
        Err(e) => println!("详情解析 Err: {e}"),
    }
    match legado_parser::AnalyzeUrl::parse(DETAIL_URL, &empty_vars, 1) {
        Ok(au) => println!(
            "AnalyzeUrl::parse(DETAIL_URL) → url={:?} method={:?} headers={:?}",
            au.url(),
            au.method(),
            au.headers()
        ),
        Err(e) => println!("AnalyzeUrl::parse 失败: {e}"),
    }

    // ── 3. 四个候选响应体逐一实测 ─────────────────────────────────────────
    println!("\n############ 3. 候选响应体 × chapterList 实测 ############");
    let cases: [(&str, &str); 4] = [
        ("A 详情页(DETAIL_URL)", DETAIL_URL),
        ("B 移动站(m.book15.net)", MOBILE_URL),
        ("C 陈旧 bookUrl(QQ 搜索页)", STALE_BOOK_URL),
        ("D 站内搜索页", SEARCH_PAGE_URL),
    ];
    let mut detail_parsed: Vec<ParsedChapter> = Vec::new();
    let mut detail_elem_total = 0usize;
    let mut detail_hrefs: Vec<String> = Vec::new();
    for (label, url) in cases {
        println!("\n--- [{label}] {url} ---");
        let resp = legado_ffi::runtime::block_on(async {
            client.get_raw(url, Some(headers.clone())).await
        });
        let body = match resp {
            Ok(r) => {
                println!("HTTP status={} bytes={}", r.status, r.body.len());
                String::from_utf8_lossy(&r.body).to_string()
            }
            Err(e) => {
                println!("请求失败: {e}");
                continue;
            }
        };
        println!("响应体前200: {}", preview(&body, 200));

        // CSS 命中数（HtmlParser 直测）
        let hp = HtmlParser::new();
        let css_hits = hp
            .get_elements(&body, ".d-chapter-list dd a")
            .unwrap_or_default();
        println!("[CSS] `.d-chapter-list dd a` 命中 = {}", css_hits.len());
        if let Some(first) = css_hits.first() {
            println!("[CSS] 首元素: {}", preview(first, 160));
        }

        // 复刻引擎解析
        let (elem_total, parsed, rule) =
            parse_toc_body_like_engine(&source, &body, url, js_lib.as_deref(), setup.clone(), 1000);
        println!(
            "[引擎复刻] chapterList={rule:?} 元素数={elem_total} 产出章节数={}",
            parsed.len()
        );
        let mut distinct: Vec<&str> = parsed.iter().map(|c| c.url.as_str()).collect();
        distinct.sort();
        distinct.dedup();
        let fallback_cnt = parsed.iter().filter(|c| c.url == url).count();
        println!(
            "[引擎复刻] url 去重数={} ；url==toc_url 的条数={}",
            distinct.len(),
            fallback_cnt
        );
        for c in parsed.iter().take(3) {
            println!("   章[{}] title={:?} url={}", c.index, c.title, c.url);
        }
        if let Some(last) = parsed.last() {
            println!(
                "   末章[{}] title={:?} url={}",
                last.index, last.title, last.url
            );
        }
        if label.starts_with('A') {
            detail_elem_total = elem_total;
            detail_parsed = parsed;
            // 详情页 CSS 元素的真实 href（用于第 5 节「假设①」对照：引擎若正确取 href 会得到 688 条不同 url）
            detail_hrefs = css_hits
                .iter()
                .filter_map(|el| {
                    let i = el.find("href=\"")?;
                    let rest = &el[i + 6..];
                    let j = rest.find('"')?;
                    Some(rest[..j].to_string())
                })
                .collect();
        }
    }
    println!("\n[对照结论] 详情页元素数={detail_elem_total}；q7.db 里落库的 chapter.title=「第688章 大结局，最后一个条件（全书完）」= 目录最后一条，index=687 = 最后一条下标");

    // ── 3.5 元素级探针：chapterUrl 规则 `@href` 为何取不到值 ───────────────
    println!("\n############ 3.5 chapterUrl=@href 元素级探针（详情页） ############");
    {
        let resp = legado_ffi::runtime::block_on(async {
            client.get_raw(DETAIL_URL, Some(headers.clone())).await
        });
        if let Ok(r) = resp {
            let body = String::from_utf8_lossy(&r.body).to_string();
            let hp = HtmlParser::new();
            let els = hp
                .get_elements(&body, ".d-chapter-list dd a")
                .unwrap_or_default();
            let mut ea = legado_ffi::js_executor::construct_analyzer_with_source_context(
                String::new(),
                DETAIL_URL.to_string(),
                &source.book_source_url,
                js_lib.as_deref(),
                setup.clone(),
            );
            for idx in [0usize, 687usize] {
                if let Some(el) = els.get(idx) {
                    ea.clear_variables();
                    ea.set_element_content(el.clone());
                    println!("--- 元素[{idx}] HTML 前缀: {}", preview(el, 120));
                    for rule in [
                        "@text",
                        "@href",
                        "href",
                        "a@href",
                        "a.0@href",
                        ".d-chapter-list dd a@href",
                    ] {
                        let v = ea.get_string(rule).unwrap_or_default();
                        println!("      {rule:<28} → {:?}", preview(&v, 90));
                    }
                }
            }
            // 合成最小用例：叶子 <a> 元素 + 裸 @href / a@href
            let synth = r#"<a href="https://book15.net/chapter/index3735-4353910.html" title="x">第1章 引子</a>"#;
            let mut sa = legado_ffi::js_executor::construct_analyzer_with_source_context(
                synth.to_string(),
                DETAIL_URL.to_string(),
                &source.book_source_url,
                js_lib.as_deref(),
                setup.clone(),
            );
            sa.set_element_content(synth.to_string());
            println!("--- 合成用例 content={synth}");
            for rule in ["@text", "text", "@href", "href", "a@href"] {
                let v = sa.get_string(rule).unwrap_or_default();
                println!("      {rule:<10} → {v:?}");
            }
        }
    }

    // ── 3.6 其它入口：普通刷新路径 get_chapters（非换源） ─────────────────
    println!("\n############ 3.6 get_chapters_with_hints(source, DETAIL_URL, None) ############");
    let normal = legado_ffi::runtime::block_on(async {
        fetcher
            .get_chapters_with_hints(&source, DETAIL_URL, None, None)
            .await
    });
    match normal {
        Ok(list) => {
            println!("章节数={}", list.len());
            for c in list.iter().take(2) {
                println!("   章[{}] title={:?} url={}", c.index, c.title, c.url);
            }
        }
        Err(e) => println!("Err: {e}"),
    }

    // ── 4. 公开 API 目录抓取（权威） ──────────────────────────────────────
    println!("\n############ 4. 公开 API get_chapters_with_vars（权威路径） ############");
    for (label, url) in [
        ("DETAIL_URL", DETAIL_URL),
        ("STALE_BOOK_URL(q7 books.bookUrl)", STALE_BOOK_URL),
    ] {
        let chapters = legado_ffi::runtime::block_on(async {
            fetcher
                .get_chapters_with_vars(&source, url, &empty_vars)
                .await
        });
        match chapters {
            Ok(list) => {
                let mut urls: Vec<&str> = list.iter().map(|c| c.url.as_str()).collect();
                urls.sort();
                urls.dedup();
                let eq_toc = list.iter().filter(|c| c.url == url).count();
                println!(
                    "[{label}] 章节数={} url 去重数={} url==入参 的条数={}",
                    list.len(),
                    urls.len(),
                    eq_toc
                );
                for c in list.iter().take(2) {
                    println!(
                        "   章[{}] title={:?} url={}",
                        c.index,
                        c.title,
                        preview(&c.url, 100)
                    );
                }
                if let Some(last) = list.last() {
                    println!(
                        "   末章[{}] title={:?} url={}",
                        last.index,
                        last.title,
                        preview(&last.url, 100)
                    );
                }
            }
            Err(e) => println!("[{label}] Err: {e}"),
        }
    }

    // ── 5. 内存 sqlite 复刻 chapters 主键 (url,bookUrl) + INSERT OR REPLACE ──
    println!("\n############ 5. chapters 主键 (url,bookUrl) 坍缩实验 ############");
    println!("q7.db 实际 DDL: PRIMARY KEY(url, bookUrl)（见 schema）；下面用内存库复刻两种假设：");
    let simulate = |tag: &str, chapters: &[ParsedChapter], force_url: Option<&str>| {
        let conn = rusqlite::Connection::open_in_memory().expect("memory db");
        conn.execute_batch(
            r#"CREATE TABLE chapters (
                 url TEXT NOT NULL, title TEXT NOT NULL, baseUrl TEXT NOT NULL,
                 bookUrl TEXT NOT NULL, "index" INTEGER NOT NULL,
                 PRIMARY KEY(url, bookUrl));"#,
        )
        .expect("create table");
        for c in chapters {
            let url = force_url.unwrap_or(&c.url);
            conn.execute(
                r#"INSERT OR REPLACE INTO chapters(url,title,baseUrl,bookUrl,"index")
                   VALUES (?1,?2,?3,?4,?5)"#,
                rusqlite::params![url, c.title, STALE_BOOK_URL, STALE_BOOK_URL, c.index as i64],
            )
            .expect("insert");
        }
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM chapters", [], |r| r.get(0))
            .unwrap();
        let row: Option<(String, String, i64)> = conn
            .query_row(r#"SELECT url,title,"index" FROM chapters"#, [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .ok();
        println!(
            "[{tag}] 写入 {} 条 → 表内行数 {}；唯一行={:?}",
            chapters.len(),
            n,
            row
        );
    };
    if !detail_parsed.is_empty() {
        // 假设①：chapterUrl `@href` 正常 → 688 个不同绝对 url
        let proper: Vec<ParsedChapter> = detail_hrefs
            .iter()
            .enumerate()
            .map(|(i, h)| ParsedChapter {
                index: i,
                title: format!("第{i}章"),
                url: if h.starts_with("http") {
                    h.clone()
                } else {
                    format!("https://book15.net{h}")
                },
            })
            .collect();
        simulate(
            &format!("假设① @href 正常（{} 个不同 url）", proper.len()),
            &proper,
            None,
        );
        simulate(
            "假设② @href 取空 → 688 章 url 全部回退成 toc_url（详情页）",
            &detail_parsed,
            Some(DETAIL_URL),
        );
    }
    println!(
        "引擎实测（第 4 节）：parse_chapters_from_toc_body 已按 url 去重（dedupe_last_by_url，保留最后一次出现）\n  → 688 章同 url 在引擎内先坍缩为 1 章（index=687 第688章）；DB 再原样落库 1 行。\n  q7.db 现状行 = (url=详情页, title=第688章, index=687) 与「假设② + 引擎 url 去重」完全一致。"
    );

    // ── 6. CSS 属性选择器回归探针 ────────────────────────────────────────
    println!("\n############ 6. CSS 属性选择器探针（在详情页响应体上） ############");
    let resp = legado_ffi::runtime::block_on(async {
        client.get_raw(DETAIL_URL, Some(headers.clone())).await
    });
    if let Ok(r) = resp {
        let body = String::from_utf8_lossy(&r.body).to_string();
        let a = legado_ffi::js_executor::construct_analyzer_with_source_context(
            body,
            DETAIL_URL.to_string(),
            &source.book_source_url,
            js_lib.as_deref(),
            setup.clone(),
        );
        for (tag, rule) in [
            (
                "ruleBookInfo.lastChapter（属性值含冒号 og:novel:…）",
                r#"meta[property="og:novel:latest_chapter_name"]@content"#,
            ),
            (
                "对照：属性值含冒号（og:type）",
                r#"meta[property="og:type"]@content"#,
            ),
            (
                "对照：属性值不含冒号（name=keywords）→ 期望仅 1 行 keywords",
                r#"meta[name="keywords"]@content"#,
            ),
            (
                "对照：*=（author）",
                r#".d-info-panel a[href*=author]@text"#,
            ),
            (
                "对照：无 [ ] 的 class+后代选择器",
                ".d-info-panel .nowrap-3@text",
            ),
        ] {
            let v = a.get_string(rule).unwrap_or_default();
            println!(
                "[{tag}]\n    rule={rule}\n    len={} lines={}\n    值={}",
                v.len(),
                v.lines().count(),
                preview(&v, 200)
            );
        }
        println!("↑ 含冒号的 = 属性选择器全部退化为「仅标签名」全选（19 行 meta content），");
        println!("  与 q7.db books.latestChapterTitle 的 19 行拼接逐行一致 → 属同一处 [ ] 误判为索引区间的解析缺陷。");
    }

    // ── 7. 摘要 ─────────────────────────────────────────────────────────
    println!("\n############ 7. 摘要 ############");
    println!(
        "- 详情页 CSS `.d-chapter-list dd a` 命中 {detail_elem_total} 条（选择器与页面本身没问题）"
    );
    println!("- 源无 ruleBookInfo.tocUrl → toc_url = bookUrl = 详情页（详情即目录，同页）");
    println!("- chapterUrl 规则 `@href` 在「元素本身就是 <a>」时取空 → 每章 url 回退 toc_url");
    println!("- parse_chapters_from_toc_body 的 dedupe_last_by_url（去重键=url）把 688 章坍缩成 1 章（保留最后一条）");
    println!("- 以上三点叠加 = q7.db（1 行 / index=687 / title=第688章 / url=详情页）");
    println!("- latestChapterTitle 的 19 行 meta 拼接 = 第 6 节 `[property=\"…:…\"]` 属性选择器误判为索引区间");
}
