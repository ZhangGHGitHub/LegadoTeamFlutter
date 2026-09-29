//! [P4-1 C5 | 2026-09-29] 漫画内容链离线 fixture 测试矩阵（纯测试，零行为变更）
//!
//! P2-17 纪律：全部网络请求打 127.0.0.1 回环 mock（std TcpListener，与
//! `toc_redirect_final_url.rs` 同模式：内存 DB + NO_PROXY + 共享客户端重置 +
//! 逐连接线程 + 读到 `\r\n\r\n` 即应答 + `Connection: close`），
//! 不硬断言任何真实网站。
//!
//! 覆盖（任务 STAGE-UI-P41B · C5 Rust 侧，夹具 `tests/fixtures/comic_source.json`
//! （favcomic 书源）复用）：
//!
//! 1. **content 链图片书断言**（quickjs 档，真实 favcomic 规则 + jsLib 离线三连
//!    detail/toc/content）：
//!    - toc 规则 `.right_box:nth-child(2)@a` 解析 3 章（章节 URL 相对→绝对化）
//!    - content 规则 `<js>`（`src.match(/"images":.../)` → 每行
//!      `<img src="https://ccdeoo.ykxbo.cn/file/e-media/app...">`）产出图片 URL 行
//!    - 逐章不同图片列表（第 2 章 2 图 / 第 3 章 1 图）证明规则按章执行
//! 2. **「content 规则空 → 回退章节 URL」行为固化**（默认档，无 JS；C4 语义
//!    对齐事实的 Rust 侧现状，`docs/API_CONTRACT.md` §2.17 ℹ️ 补记的同款事实）：
//!    - 漫画书源（bookSourceType=2，非 JS 源）`ruleContent.content` 为空时，
//!      `get_chapter_content_full` **不请求章节页**、直接返回章节 URL 字符串
//!      （`WebBookEngine::get_content` 短路，对齐原版 Kotlin
//!      `WebBook.kt:429-433`「正文规则为空,使用章节链接」——两侧语义一致，
//!      见 API_CONTRACT 补记）。`parse_content_page_with_bindings` 的
//!      「body 直用」分支对非 JS 源经引擎路径不可达（包装层先短路）
//! 3. **coverDecode → imageDecode JSON 映射**（默认档，纯 JSON；镜像 Dart 侧
//!    `CoverDecodeLoader.patchSourceJsonForCoverDecode` 的转换：
//!    `coverDecodeJs` 非空 → 写入 `ruleContent.imageDecode`，补丁后 JSON 仍是
//!    合法的 `BookSource` 形态（`fetchImageWithDecode` 的 `source_json` 入参））
//! 4. **`fetchImageWithDecode` 离线 fixture 用例**：
//!    - （quickjs 档）**imageDecode 解码路径命中**：回环服务 XOR 0xFF 密文，
//!      jsLib `decode(result)`（`^0xFF`）解出明文 PNG（逐字节一致）
//!    - （quickjs 档）**复合 URL `url,{json headers}` 内嵌 header 合并**：
//!      服务端录制 `X-Embed` / 内嵌 `Referer` 覆盖默认 Referer 的证据
//!    - （quickjs 档）**解码后仍非图片 → Err**（密文不得当成功回传的不变式）
//!    - （默认档）**无 imageDecode 规则 → 原样 base64 透传**（base64/len 精确比对）
//!    - （默认档）**HTTP 失败 → `LegadoError::Network`**（`图片下载失败: HTTP 404`）
//!
//! 档位说明：1/4a-4c 依赖 QuickJS 执行（content `<js>` 规则 / jsLib / imageDecode
//! JS），`#[cfg(feature = "quickjs")]` 门控；2/3/4d/4e 纯 JSON/网络/魔数逻辑，
//! 默认档（无 quickjs）即跑。门禁：`cargo test -p legado-ffi`（默认档）+
//! `cargo test -p legado-ffi --features quickjs`（全量）。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex, MutexGuard, Once};

use base64::Engine as _;
use legado_ffi::legado_core::models::Book;
use legado_ffi::legado_db::repository::Repository;
use legado_ffi::legado_db::BookRepository;

static TEST_LOCK: Mutex<()> = Mutex::new(());
static ENV_INIT: Once = Once::new();

fn lock_test() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
    std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
    legado_ffi::http_state::reset_shared_client();
}

// ─── 回环 mock 服务器（P2-17 同纪律）────────────────────────────────────────

/// 路由表：path → (status, 响应头, 二进制 body)
#[derive(Clone)]
struct Route {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

type Routes = Arc<HashMap<String, Route>>;
type Hits = Arc<Mutex<HashMap<String, u32>>>;
/// 按 path 记录最后一次请求头（header 名小写）——复合 URL header 合并的证据
type HeaderLog = Arc<Mutex<HashMap<String, HashMap<String, String>>>>;

fn spawn_mock_server(routes: Routes) -> (u16, Hits, HeaderLog) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环 mock 服务器");
    let port = listener.local_addr().expect("取端口").port();
    let hits: Hits = Arc::new(Mutex::new(HashMap::new()));
    let header_log: HeaderLog = Arc::new(Mutex::new(HashMap::new()));
    let listener = Arc::new(listener);
    let h_hits = Arc::clone(&hits);
    let h_log = Arc::clone(&header_log);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let routes = Arc::clone(&routes);
            let hits = Arc::clone(&h_hits);
            let log = Arc::clone(&h_log);
            std::thread::spawn(move || {
                handle_conn(&mut sock, &routes, &hits, &log);
            });
        }
    });
    (port, hits, header_log)
}

fn handle_conn(
    stream: &mut std::net::TcpStream,
    routes: &Routes,
    hits: &Hits,
    header_log: &HeaderLog,
) {
    let mut buf: Vec<u8> = Vec::new();
    let mut one = [0u8; 1];
    // 读完整请求头（到空行）：防 Windows RST flaky（与 toc_redirect_final_url 同注释）
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut one) {
            Ok(1) => buf.push(one[0]),
            _ => return,
        }
        if buf.len() > 16 * 1024 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let path = head
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .split('?')
        .next()
        .unwrap_or("/")
        .to_string();

    // 记录本次请求头（name 小写）
    {
        let mut rec: HashMap<String, String> = HashMap::new();
        for line in head.lines().skip(1) {
            if let Some((k, v)) = line.split_once(':') {
                rec.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }
        header_log.lock().unwrap().insert(path.clone(), rec);
    }

    let (status, headers, body) = routes
        .get(&path)
        .map(|r| (r.status, r.headers.clone(), r.body.clone()))
        .unwrap_or_else(|| (404u16, Vec::new(), b"not found".to_vec()));
    {
        let mut h = hits.lock().unwrap();
        *h.entry(path).or_insert(0) += 1;
    }
    let reason = match status {
        200 => "OK",
        404 => "Not Found",
        _ => "Error",
    };
    let mut resp: Vec<u8> = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    )
    .into_bytes();
    for (k, v) in &headers {
        resp.extend(format!("{k}: {v}\r\n").into_bytes());
    }
    resp.extend_from_slice(b"\r\n");
    resp.extend_from_slice(&body);
    let _ = stream.write_all(&resp);
    let _ = stream.flush();
}

fn html_route(status: u16, body: &str) -> Route {
    Route {
        status,
        headers: vec![(
            "Content-Type".to_string(),
            "text/html; charset=utf-8".to_string(),
        )],
        body: body.as_bytes().to_vec(),
    }
}

fn binary_route(status: u16, body: Vec<u8>) -> Route {
    Route {
        status,
        headers: vec![("Content-Type".to_string(), "image/webp".to_string())],
        body,
    }
}

/// 最小 PNG 明文（魔数 + 4 字节负载）：解码命中 / 透传用例的期望值
fn min_png() -> Vec<u8> {
    vec![
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03,
    ]
}

/// 夹具路径（与 51manga 密文夹具同约定：CARGO_MANIFEST_DIR/tests/fixtures/）
fn comic_source_fixture_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/comic_source.json")
}

// ─── 1. favcomic 离线 detail/toc/content 链（quickjs 档）────────────────────

/// favcomic 夹具书源（真实 jsLib + 真实 content `<js>` 规则）跑离线
/// detail/toc/content 链：toc 规则出 3 章、content 规则出每行 img URL。
#[cfg(feature = "quickjs")]
#[test]
fn test_favcomic_comic_chain_detail_toc_content_offline() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    // 夹具书源：仅把 bookSourceUrl/searchUrl 指向回环，规则面（jsLib /
    // ruleToc / ruleContent）保持 favcomic 原样——离线断言真实规则行为
    let raw =
        std::fs::read_to_string(comic_source_fixture_path()).expect("读取 comic_source.json 夹具");
    let arr: serde_json::Value = serde_json::from_str(&raw).expect("夹具 JSON 数组解析");
    let mut map = arr[0].clone();

    let (port, hits, _log) = {
        let mut routes: HashMap<String, Route> = HashMap::new();
        // 详情页（兼目录页，夹具 ruleBookInfo 无 tocUrl 规则 → 详情页即目录页）：
        // 第 2 个 .right_box 子节点是章节列表（对齐 favcomic 真实页面结构意图）
        routes.insert(
            "/book/1".to_string(),
            html_route(
                200,
                "<html><body>\
                 <div class=\"right_box\"><a href=\"/nav\">首页</a></div>\
                 <div class=\"right_box\">\
                   <a class=\"title\" href=\"/ch/1\">第1话</a>\
                   <a class=\"title\" href=\"/ch/2\">第2话</a>\
                   <a class=\"title\" href=\"/ch/3\">第3话</a>\
                 </div>\
                 </body></html>",
            ),
        );
        // 章节页：内嵌 "images" 数组（favcomic 真实章节页 data 形态），
        // 各章图片列表不同（证明 content 规则按章执行）
        for (n, imgs) in [
            (
                1,
                vec![
                    "/comic/9001/01.webp",
                    "/comic/9001/02.webp",
                    "/comic/9001/03.webp",
                ],
            ),
            (2, vec!["/comic/9001/04.webp", "/comic/9001/05.webp"]),
            (3, vec!["/comic/9001/06.webp"]),
        ] {
            let images_json: Vec<String> = imgs.iter().map(|s| format!("\"{s}\"")).collect();
            routes.insert(
                format!("/ch/{n}"),
                html_route(
                    200,
                    &format!(
                        "<html><body><div id=\"content\"><script type=\"text/javascript\">var chapterData = {{\"webtoon\":1,\"images\":[{}]}};</script></div></body></html>",
                        images_json.join(",")
                    ),
                ),
            );
        }
        let routes = Arc::new(routes);
        spawn_mock_server(Arc::clone(&routes))
    };

    let source_url = format!("http://127.0.0.1:{port}/src");
    let book_url = format!("http://127.0.0.1:{port}/book/1");
    map["bookSourceUrl"] = serde_json::json!(source_url.clone());
    map["searchUrl"] = serde_json::json!(format!("{source_url}/search?keyword={{key}}"));
    let source_json = serde_json::to_string(&map).expect("夹具书源 JSON 序列化");

    // 夹具事实断言（字段层面）：imageDecode 与 coverDecodeJs 同为 decode 规则
    assert_eq!(
        map["ruleContent"]["imageDecode"].as_str(),
        Some("decode(result);"),
        "夹具 imageDecode 事实"
    );
    assert_eq!(
        map["coverDecodeJs"].as_str(),
        Some("decode(result);"),
        "夹具 coverDecodeJs 事实（Dart 封面解码路径映射源）"
    );

    legado_ffi::api::source::add_source(&source_json)
        .expect("夹具书源写入（bookSourceUrl 指向回环）");

    let book = Book {
        book_url: book_url.clone(),
        origin: source_url.clone(),
        origin_name: "（favcomic）喜漫漫画（离线夹具）".to_string(),
        ..Book::default()
    };
    legado_ffi::db_state::with_database(|db| BookRepository::new(db.connection()).insert(&book))
        .expect("书行写入");

    // ① 目录链：toc 规则 `.right_box:nth-child(2)@a` 解析 3 章
    let resp = legado_ffi::api::reader::refresh_toc(&book_url, &source_url)
        .expect("favcomic 夹具目录刷新不应失败（全离线回环）");
    assert_eq!(resp.total, 3, "toc 规则应解析出 3 章");
    let ch1 = resp.chapters.first().expect("章节列表非空");
    assert_eq!(ch1.title, "第1话");
    assert_eq!(
        ch1.url,
        format!("http://127.0.0.1:{port}/ch/1"),
        "相对章节链接应基于详情页绝对化"
    );

    // ② content 链：content `<js>` 规则（src.match "images" → img 行）
    let content0 =
        legado_ffi::api::reader::get_chapter_content_full(&book_url, 0).expect("第 1 章正文抓取");
    for item in [
        "https://ccdeoo.ykxbo.cn/file/e-media/app/comic/9001/01.webp",
        "https://ccdeoo.ykxbo.cn/file/e-media/app/comic/9001/02.webp",
        "https://ccdeoo.ykxbo.cn/file/e-media/app/comic/9001/03.webp",
    ] {
        assert!(
            content0.contains(&format!("<img src=\"{item}\">")),
            "content 规则应产出 img 行 {item}，实际正文头部：{:?}",
            &content0[..content0.len().min(200)]
        );
    }
    // 脚本噪音不得残留（body 已被规则输出替代）
    assert!(
        !content0.contains("chapterData"),
        "content 规则输出应替代原始 body"
    );

    // ③ 第 2 章不同图片列表（2 图），证明规则按章执行而非缓存串章
    let content1 =
        legado_ffi::api::reader::get_chapter_content_full(&book_url, 1).expect("第 2 章正文抓取");
    assert!(content1.contains("https://ccdeoo.ykxbo.cn/file/e-media/app/comic/9001/04.webp"));
    assert!(content1.contains("https://ccdeoo.ykxbo.cn/file/e-media/app/comic/9001/05.webp"));
    assert!(
        !content1.contains("comic/9001/01.webp"),
        "第 2 章不得串入第 1 章图片"
    );

    // 请求轨迹证据
    let hits = hits.lock().unwrap();
    let get = |p: &str| hits.get(p).copied().unwrap_or(0);
    eprintln!(
        "[p41b-favcomic] total={} /book/1={} /ch/1={} /ch/2={}",
        resp.total,
        get("/book/1"),
        get("/ch/1"),
        get("/ch/2")
    );
    assert!(get("/book/1") >= 1, "详情页应被请求");
    assert!(get("/ch/1") >= 1, "第 1 章页应被请求");
    assert!(get("/ch/2") >= 1, "第 2 章页应被请求");
}

// ─── 2. 空 content 规则 → 回退章节 URL（默认档，C4 对齐事实固化）────────────

/// 「content 规则空 → 回退章节 URL 字符串」行为固化（C4 对齐事实的 Rust 侧现状）：
/// 漫画书源（bookSourceType=2，非 JS 源）`ruleContent.content` 为空时，
/// content 链**不请求章节页**、直接返回章节 URL 字符串（`WebBookEngine::get_content`
/// 短路，对齐原版 Kotlin `WebBook.kt:429-433`「正文规则为空,使用章节链接」，
/// 两侧语义一致——见 API_CONTRACT.md §2.17 ℹ️ 补记）。本用例以
/// 「章节页路由已注册但零命中」固化该短路行为，防止后续误改回「body 直用」。
/// 默认档可跑（空规则零 JS 执行）。
#[test]
fn test_empty_content_rule_returns_chapter_url_like_original() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    let mut routes: HashMap<String, Route> = HashMap::new();
    routes.insert(
        "/book/1".to_string(),
        html_route(
            200,
            "<html><body>\
             <div class=\"info_box\"><h1>C4 对齐书</h1></div>\
             <div class=\"chapter-item\"><a href=\"/ch/1\">第1章</a></div>\
             <div class=\"chapter-item\"><a href=\"/ch/2\">第2章</a></div>\
             </body></html>",
        ),
    );
    // 章节页路由刻意注册（内容含 img/文本）：断言「零命中」依赖其存在
    routes.insert(
        "/ch/1".to_string(),
        html_route(
            200,
            "<html><body><p>第一章正文。</p><img src=\"/img/01.webp\"></body></html>",
        ),
    );
    routes.insert(
        "/ch/2".to_string(),
        html_route(
            200,
            "<html><body><p>第二章正文。</p><img src=\"/img/02.webp\"></body></html>",
        ),
    );
    let (port, hits, _log) = spawn_mock_server(Arc::new(routes));

    let source_url = format!("http://127.0.0.1:{port}/src");
    let book_url = format!("http://127.0.0.1:{port}/book/1");
    // 漫画书源：ruleContent 空对象（content 规则为空），toc 纯 CSS（两档一致）
    let source_json = format!(
        r#"{{"bookSourceUrl":"{source_url}","bookSourceName":"C4 对齐源","bookSourceType":2,"searchUrl":"{source_url}/search","ruleSearch":{{"bookList":".x"}},"ruleToc":{{"chapterList":"class.chapter-item","chapterName":"tag.a@text","chapterUrl":"tag.a@href"}},"ruleContent":{{}}}}"#
    );
    legado_ffi::api::source::add_source(&source_json).expect("夹具书源写入");

    let book = Book {
        book_url: book_url.clone(),
        origin: source_url.clone(),
        origin_name: "C4 对齐源".to_string(),
        ..Book::default()
    };
    legado_ffi::db_state::with_database(|db| BookRepository::new(db.connection()).insert(&book))
        .expect("书行写入");

    let resp =
        legado_ffi::api::reader::refresh_toc(&book_url, &source_url).expect("目录刷新不应失败");
    assert_eq!(resp.total, 2, "toc 规则应解析出 2 章");
    let chapter_url = resp.chapters.first().expect("章节非空").url.clone();

    // 空 content 规则（非 JS 源）：content 链回退章节 URL 字符串（原版语义），
    // 且不请求章节页
    let content =
        legado_ffi::api::reader::get_chapter_content_full(&book_url, 0).expect("正文抓取不应失败");
    let hits = hits.lock().unwrap();
    let get = |p: &str| hits.get(p).copied().unwrap_or(0);
    eprintln!(
        "[p41b-c4] chapter_url={} content_eq_url={} /book/1={} /ch/1={}",
        chapter_url,
        content == chapter_url,
        get("/book/1"),
        get("/ch/1")
    );
    assert_eq!(
        content, chapter_url,
        "空 content 规则（非 JS 源）应回退章节 URL 字符串（对齐原版 Kotlin WebBook.kt:429-433）"
    );
    assert_eq!(
        get("/ch/1"),
        0,
        "空 content 规则不得请求章节页（包装层短路）"
    );
    assert!(get("/book/1") >= 1, "目录刷新应请求详情页");
}

// ─── 3. coverDecode → imageDecode JSON 映射（默认档，镜像 Dart 转换）────────

/// Dart 侧 `CoverDecodeLoader.patchSourceJsonForCoverDecode` 的 Rust 镜像断言：
/// `coverDecodeJs` 非空 → 映射写入 `ruleContent.imageDecode`，补丁后 JSON 仍
/// 是合法的 `BookSource`（即 `fetchImageWithDecode` 的 `source_json` 入参形态）；
/// 无 `coverDecodeJs` 的源 → 无需补丁（Dart 侧返回空串语义）。
#[test]
fn test_cover_decode_js_maps_to_image_decode_on_favcomic_fixture() {
    let _lock = lock_test();

    let raw =
        std::fs::read_to_string(comic_source_fixture_path()).expect("读取 comic_source.json 夹具");
    let arr: serde_json::Value = serde_json::from_str(&raw).expect("夹具 JSON 数组解析");
    let map = arr[0].clone();

    // 事实：favcomic 夹具两个字段值相同（同一 decode 规则的两条消费路径）
    let cover_decode = map["coverDecodeJs"]
        .as_str()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    assert_eq!(cover_decode.as_deref(), Some("decode(result);"));

    // 镜像 Dart 转换：coverDecodeJs → ruleContent.imageDecode
    let mut patched = map.clone();
    let mut rule_content = patched["ruleContent"]
        .as_object()
        .cloned()
        .expect("夹具 ruleContent 为对象");
    rule_content.insert(
        "imageDecode".to_string(),
        serde_json::Value::String(cover_decode.unwrap()),
    );
    patched["ruleContent"] = serde_json::Value::Object(rule_content);

    // 补丁后 JSON 须能反序列化为 BookSource（FFI 入参契约）
    let src: legado_ffi::legado_core::models::BookSource =
        serde_json::from_value(patched).expect("补丁后 JSON 应仍是合法 BookSource");
    assert_eq!(
        src.rule_content
            .as_ref()
            .and_then(|c| c.image_decode.as_deref()),
        Some("decode(result);"),
        "imageDecode 应被 coverDecodeJs 覆盖写入"
    );

    // 负向：无 coverDecodeJs 的源 → Dart 侧 patchSourceJsonForCoverDecode 返回空串
    // （无需走 FFI decode）；Rust 侧对应「字段缺省/空 → 不产生补丁」
    let minimal: legado_ffi::legado_core::models::BookSource = serde_json::from_str(
        r#"{"bookSourceUrl":"https://a.example.com","bookSourceName":"t","bookSourceType":0}"#,
    )
    .expect("最小书源解析");
    assert!(
        minimal
            .cover_decode_js
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty(),
        "无 coverDecodeJs 的源无需封面解码补丁"
    );
}

// ─── 4. fetchImageWithDecode 离线 fixture 用例 ───────────────────────────────

/// XOR 0xFF jsLib 解码命中（quickjs 档）：回环服务密文，`fetchImageWithDecode`
/// 下载 → jsLib `decode(result)` 解出明文 PNG（逐字节一致）；复合 URL
/// `url,{json headers}` 的内嵌 header 经服务端录制验证合并（X-Embed 透传 +
/// 内嵌 Referer 覆盖默认 Referer）。
#[cfg(feature = "quickjs")]
#[test]
fn test_fetch_image_with_decode_xor_decode_hit_and_composite_headers() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    let plain = min_png();
    let cipher: Vec<u8> = plain.iter().map(|b| 0xFF - b).collect();
    let mut routes: HashMap<String, Route> = HashMap::new();
    routes.insert("/img/xor.png".to_string(), binary_route(200, cipher));
    let (port, _hits, log) = spawn_mock_server(Arc::new(routes));

    let source_json = format!(
        r#"{{"bookSourceUrl":"http://127.0.0.1:{port}/src","bookSourceName":"XOR 解码源","bookSourceType":2,"jsLib":"function decode(b){{var o=new Uint8Array(b.length);for(var i=0;i<b.length;i++){{o[i]=b[i]^0xFF;}}return o;}}","ruleContent":{{"content":".x","imageDecode":"decode(result);"}}}}"#
    );

    // ① 解码路径命中：密文下载 → XOR 解出明文 PNG
    let url = format!("http://127.0.0.1:{port}/img/xor.png");
    let out = legado_ffi::api::image_api::fetch_image_with_decode(&url, &source_json)
        .expect("XOR 解码后应为有效图片（明文 PNG）");
    let v: serde_json::Value = serde_json::from_str(&out).expect("结果 JSON 解析");
    assert_eq!(v["len"].as_u64(), Some(plain.len() as u64));
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(v["base64"].as_str().expect("base64 字段"))
        .expect("base64 解码");
    assert_eq!(decoded, plain, "XOR 解码结果应逐字节等于明文 PNG");

    // ② 复合 URL：内嵌 header 合并（服务端录制证据）
    let composite = format!(
        "{url},{{\"headers\":{{\"X-Embed\":\"fav\",\"Referer\":\"https://embed.example/\"}}}}"
    );
    let out2 = legado_ffi::api::image_api::fetch_image_with_decode(&composite, &source_json)
        .expect("复合 URL 解码不应失败");
    let decoded2 = base64::engine::general_purpose::STANDARD
        .decode(
            serde_json::from_str::<serde_json::Value>(&out2).unwrap()["base64"]
                .as_str()
                .expect("base64 字段"),
        )
        .expect("base64 解码");
    assert_eq!(decoded2, plain, "复合 URL 拆分后仍走同一解码路径");

    // 服务端录制的最后一次 /img/xor.png 请求头（复合 URL 调用）：
    // X-Embed 透传 + 内嵌 Referer 覆盖默认 Referer（书源主页兜底不再生效）
    let headers = log
        .lock()
        .unwrap()
        .get("/img/xor.png")
        .cloned()
        .expect("服务端应记录请求头");
    assert_eq!(
        headers.get("x-embed").map(|s| s.as_str()),
        Some("fav"),
        "复合 URL 内嵌 X-Embed 必须透传到请求"
    );
    assert_eq!(
        headers.get("referer").map(|s| s.as_str()),
        Some("https://embed.example/"),
        "内嵌 Referer 应覆盖默认 Referer"
    );
    assert_eq!(
        headers.get("user-agent").map(|s| s.as_str()),
        Some(legado_ffi::legado_net::client::DEFAULT_USER_AGENT),
        "无内嵌 UA 时注入全仓缺省 UA"
    );
}

/// 解码后仍非图片 → Err（quickjs 档）：明文 PNG 被 XOR 规则「解」成非图片字节，
/// 「密文不得当成功回传」不变式（`fetch_image_with_decode` L246-259 语义）。
#[cfg(feature = "quickjs")]
#[test]
fn test_fetch_image_with_decode_non_image_result_is_error() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    // 服务明文 PNG（魔数 89 50 4E 47）——XOR 规则作用后变为 74 AF B1 F8（非图片）
    let plain = min_png();
    let mut routes: HashMap<String, Route> = HashMap::new();
    routes.insert("/img/plain.png".to_string(), binary_route(200, plain));
    let (port, _hits, _log) = spawn_mock_server(Arc::new(routes));

    let source_json = format!(
        r#"{{"bookSourceUrl":"http://127.0.0.1:{port}/src","bookSourceName":"XOR 解码源","bookSourceType":2,"jsLib":"function decode(b){{var o=new Uint8Array(b.length);for(var i=0;i<b.length;i++){{o[i]=b[i]^0xFF;}}return o;}}","ruleContent":{{"content":".x","imageDecode":"decode(result);"}}}}"#
    );
    let url = format!("http://127.0.0.1:{port}/img/plain.png");
    let err = legado_ffi::api::image_api::fetch_image_with_decode(&url, &source_json)
        .expect_err("解码后非图片魔数必须报错，不得当成功回传");
    assert!(
        err.to_string().contains("imageDecode"),
        "错误信息应指向 imageDecode 解码结果非有效图片，实际：{err}"
    );
}

/// 无 imageDecode 规则 → 原样 base64 透传（默认档，无 JS 执行）：
/// 回环服务 PNG 明文，`fetchImageWithDecode` 返回的 base64/len 与原文逐字节一致。
#[test]
fn test_fetch_image_without_decode_rule_passes_through() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    let plain = min_png();
    let plain_len = plain.len();
    let mut routes: HashMap<String, Route> = HashMap::new();
    routes.insert(
        "/img/plain.png".to_string(),
        binary_route(200, plain.clone()),
    );
    let (port, _hits, _log) = spawn_mock_server(Arc::new(routes));

    let source_json = format!(
        r#"{{"bookSourceUrl":"http://127.0.0.1:{port}/src","bookSourceName":"透传源","bookSourceType":2,"ruleContent":{{}}}}"#
    );
    let url = format!("http://127.0.0.1:{port}/img/plain.png");
    let out = legado_ffi::api::image_api::fetch_image_with_decode(&url, &source_json)
        .expect("无解码规则的透传不应失败");
    let v: serde_json::Value = serde_json::from_str(&out).expect("结果 JSON 解析");
    assert_eq!(v["len"].as_u64(), Some(plain_len as u64));
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(v["base64"].as_str().expect("base64 字段"))
        .expect("base64 解码");
    assert_eq!(
        decoded, plain,
        "无 imageDecode 时应原样透传（base64 精确一致）"
    );
}

/// HTTP 失败 → `LegadoError::Network`（默认档）：404 响应不得当成功回传。
#[test]
fn test_fetch_image_http_error_is_network_error() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    let mut routes: HashMap<String, Route> = HashMap::new();
    routes.insert("/img/plain.png".to_string(), binary_route(200, min_png()));
    let (port, _hits, _log) = spawn_mock_server(Arc::new(routes));

    let source_json = format!(
        r#"{{"bookSourceUrl":"http://127.0.0.1:{port}/src","bookSourceName":"透传源","bookSourceType":2,"ruleContent":{{}}}}"#
    );
    // 未注册路由 → 404
    let url = format!("http://127.0.0.1:{port}/img/missing.png");
    let err = legado_ffi::api::image_api::fetch_image_with_decode(&url, &source_json)
        .expect_err("HTTP 404 必须报错");
    assert!(
        err.to_string().contains("HTTP 404"),
        "错误信息应含 HTTP 状态，实际：{err}"
    );
}
