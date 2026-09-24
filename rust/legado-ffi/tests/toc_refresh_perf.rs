//! [性能专项 2026-09-24] 换源后重载耗时 ≈10 分钟：量化 + 优化验收实验（回环 mock）
//!
//! 背景：用户实测换源（斗破苍穹，1663/999/1663 章三源）后「正在更换书源…」
//! 耗时 10:00 / 10:48 / 10:04（docs/parity_shots/verify_ui_20260922/p29c_*）。
//! 代码路径审查定位的放大因子：
//! 1. 串行 nextTocUrl 链（web_book.rs 分页 while 循环）：每页 1 次 HTTP，
//!    总耗时 ≈ 页数 × 每页延迟 —— 线性放大；
//! 2. 并行分支 `join_all` 无并发上限（上游 mapAsync(threadCount=32) 有界）；
//! 3. 单页 HTTP 失败：串行整刷失败（上游 body-null 截断保留前缀）、
//!    并行静默丢章（上游 `res.body!!` 整刷失败）；
//! 4. 无失效保护：新刷新无法让在途旧链停止（上游 ensureActive 语义）；
//! 5. 无界新 URL 链（每页 next 都不同）无页数上限（上游仅靠 visited 去重）。
//!
//! 本文件用 127.0.0.1 多连接（每连接一线程）HTTP mock 书源驱动**生产入口**
//! `refresh_toc`，度量 N=10/50/200 目录页 × 每页延迟 D 的耗时曲线，并把
//! 每页成本拆成两部分：
//! - `D=0`：纯我方成本（HTTP 回环 + 每页解析器构造 + JS setup 脚本 +
//!   逐章解析 + 批量写库）；
//! - `D>0`：模拟慢站点响应延迟（真实 10 分钟重载的主因项）。
//!
//! 基建（与 tests/three_entry_parity.rs 同纪律）：
//! - 内存 DB + 全局连接池（OnceLock first-wins）+ `NO_PROXY=127.0.0.1,localhost`
//!   + `reset_shared_client()`（防宿主代理劫持回环流量）；
//! - 全部测试持 `TEST_LOCK` 串行（共享全局 DB / HTTP 客户端 / 进程级
//!   PageBodyCache 45s TTL / 流作用域）；
//! - 每个场景自起服务器（随机端口 → URL 唯一，规避跨场景 PageBodyCache
//!   串键污染）；
//! - 书源规则**纯 CSS**（无 JS）：两档 feature（默认 / quickjs）行为一致，
//!   不依赖 QuickJS 引擎即可验证分页链路。
//!
//! 场景分类：
//! 1. 量化（优化前后都必须保持成立的不变量，提供「分阶段耗时表」数据）：
//!    - `perf_serial_timing_matrix`：串行链 N × D 线性放大（N=10/50，
//!      N=200 需 `TOC_PERF_FULL=1`，约 60s）；
//!    - `perf_serial_cycle_stop`：nextTocUrl 成环时 visited 判停。
//! 2. 优化验收（优化前 RED、优化后 GREEN，先红后绿）：
//!    - `perf_parallel_bounded`：并行拉页有并发上限（对齐上游 32）；
//!    - `perf_parallel_failure_no_silent_loss`：并行分支单页失败 → 整刷失败
//!      （对齐上游 `res.body!!`，不可静默丢章）；
//!    - `perf_serial_failure_truncates`：串行分支单页 HTTP 非 2xx → 截断保留
//!      前缀（对齐上游 body-null 语义，而非整刷失败）；
//!    - `perf_serial_unbounded_chain_guarded`：无界新 URL 链按 MAX_TOC_PAGES
//!      上限判停（防 600 页 × 每页 10s 的失控链）；
//!    - `perf_stale_refresh_cancelled`：新刷新代数抢占在途旧刷新（换源场景
//!      取消在途抓取）。
//!
//! 运行完整矩阵（N=200 × D=300ms）：
//! `TOC_PERF_FULL=1 cargo test -p legado-ffi --test toc_refresh_perf`

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Once};
use std::time::{Duration, Instant};

use legado_ffi::legado_db::repository::Repository;

/// 全部测试串行：共享全局内存 DB、HTTP 客户端单例、进程级 PageBodyCache
/// 与 `NO_PROXY` 环境变量（与 three_entry_parity.rs 同一动机）
static TEST_LOCK: Mutex<()> = Mutex::new(());
static ENV_INIT: Once = Once::new();

/// 毒锁容忍：任一测试 panic 会毒化 TEST_LOCK，若 `.unwrap()` 则其余测试
/// 全部以 PoisonError 失败（先红阶段的验收测试各自需独立失败、暴露真实
/// 断言消息）；场景间无共享可变状态（每场景独立端口/书源/书行，DB 仅追加），
/// 直接 `into_inner` 接管即可安全继续。
fn lock_test() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// 每个 TOC 页的章节数（mock 固定值，用于「总章数 = 页数 × 20」断言）
const CH_PER_PAGE: u32 = 20;
/// 优化后的串行目录页上限（含首抓页；与实现常量保持一致的测试侧期望值）
const EXPECTED_MAX_TOC_PAGES: u32 = 512;
/// 并行拉页并发上限（对齐上游 `AppConfig.threadCount` 默认 32）
const EXPECTED_PAGE_CONCURRENCY: usize = 32;

// ─── 环境装配（与 three_entry_parity.rs 的 setup_env 同纪律）────────────────

fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    // 仅首次调用生效（OnceLock first-wins），后续测试复用同一池
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
    // 夹具流量全走 127.0.0.1 回环：reqwest 构建时读 NO_PROXY，重置单例令其生效
    std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
    legado_ffi::http_state::reset_shared_client();
}

// ─── 多连接 mock 服务器 ─────────────────────────────────────────────────────

/// 目录页拓扑与注入参数
#[derive(Clone, Copy)]
struct ServerCfg {
    /// TOC 页数（/toc/1..=N 或 /run/1..=N）
    pages: u32,
    /// 并行列表模式：第 1 页带 N-1 条 next 链接（/toc/2..=N），其余页无 next
    parallel_list: bool,
    /// 成环模式：/toc/c1 ↔ /toc/c2 互指（visited 判停验证）
    cycle: bool,
    /// 失控链模式：页 URL 为 /run/{k}（全新 URL，无重复可去重）
    runaway: bool,
    /// 第 fail_page 页返回 HTTP 500（None = 不注入）
    fail_page: Option<u32>,
    /// 每请求模拟站点延迟（ms）
    delay_ms: u64,
}

impl ServerCfg {
    fn serial(pages: u32, delay_ms: u64, fail_page: Option<u32>) -> Self {
        Self {
            pages,
            parallel_list: false,
            cycle: false,
            runaway: false,
            fail_page,
            delay_ms,
        }
    }

    fn parallel_list(pages: u32, delay_ms: u64, fail_page: Option<u32>) -> Self {
        Self {
            pages,
            parallel_list: true,
            cycle: false,
            runaway: false,
            fail_page,
            delay_ms,
        }
    }

    fn cycle(delay_ms: u64) -> Self {
        Self {
            pages: 2,
            parallel_list: false,
            cycle: true,
            runaway: false,
            fail_page: None,
            delay_ms,
        }
    }

    fn runaway(pages: u32, delay_ms: u64) -> Self {
        Self {
            pages,
            parallel_list: false,
            cycle: false,
            runaway: true,
            fail_page: None,
            delay_ms,
        }
    }
}

/// 服务器侧统计：并发水位（验证有界并行）+ 各路径命中数（验证判停/截断）
struct ServerStats {
    in_flight: AtomicUsize,
    max_in_flight: AtomicUsize,
    path_hits: Mutex<HashMap<String, u32>>,
}

impl ServerStats {
    fn new() -> Self {
        Self {
            in_flight: AtomicUsize::new(0),
            max_in_flight: AtomicUsize::new(0),
            path_hits: Mutex::new(HashMap::new()),
        }
    }
}

/// 多连接服务器：每连接一线程（reqwest 对 Connection: close 不复用连接，
/// 单连接服务器会让 200 页串行排队 → 测不出并行度）
fn spawn_toc_server(cfg: ServerCfg) -> (u16, Arc<ServerStats>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环 mock 服务器");
    let port = listener.local_addr().expect("取端口").port();
    let stats = Arc::new(ServerStats::new());
    let stats_thread = Arc::clone(&stats);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let (cfg, stats) = (cfg, Arc::clone(&stats_thread));
            std::thread::spawn(move || handle_toc_conn(&mut s, cfg, &stats));
        }
    });
    (port, stats)
}

fn handle_toc_conn(stream: &mut std::net::TcpStream, cfg: ServerCfg, stats: &ServerStats) {
    let mut buf = Vec::new();
    let mut one = [0u8; 1];
    // 必须读完整个请求头（到空行为止）：GET 请求虽无 body，但请求头是
    // 多行（Host/User-Agent/…）；只读请求行的话，剩余头字节留在接收
    // 缓冲区，socket 关闭时 Windows 会发 RST（abortive close）而非 FIN，
    // 响应尚未读完的对端会看到连接重置（reqwest 报 "error sending
    // request"）——时序相关的 flaky 根因（与 three_entry_parity 的
    // handle_conn 读法一致）。
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

    stats.in_flight.fetch_add(1, Ordering::SeqCst);
    let cur = stats.in_flight.load(Ordering::SeqCst);
    stats.max_in_flight.fetch_max(cur, Ordering::SeqCst);
    if cfg.delay_ms > 0 {
        std::thread::sleep(Duration::from_millis(cfg.delay_ms));
    }
    let (status, body) = route(&path, &cfg);
    {
        let mut hits = stats.path_hits.lock().unwrap();
        *hits.entry(path).or_insert(0) += 1;
    }
    let reason = if status < 400 { "OK" } else { "ERR" };
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
    stats.in_flight.fetch_sub(1, Ordering::SeqCst);
}

/// 目录页 HTML：`CH_PER_PAGE` 个章节条目 + next 链接（按拓扑模式）
fn page_html(page_key: &str, next_links: &[String]) -> String {
    let mut s = String::from("<html><body><div id=\"list-chapterAll\">");
    for i in 0..CH_PER_PAGE {
        s.push_str(&format!(
            "<div class=\"chapter-item\"><a href=\"/ch/{page_key}-{i}\">第{page_key}_{i}章</a></div>"
        ));
    }
    s.push_str("</div>");
    for (j, link) in next_links.iter().enumerate() {
        let n = j + 1;
        s.push_str(&format!("<a class=\"next\" href=\"{link}\">下一页{n}</a>"));
    }
    s.push_str("</body></html>");
    s
}

fn route(path: &str, cfg: &ServerCfg) -> (u16, String) {
    // 详情页：书名 + toc-start 链接（详情 → 目录取址）
    if path == "/book/1" {
        let toc1 = if cfg.cycle {
            "/toc/c1"
        } else if cfg.runaway {
            "/run/1"
        } else {
            "/toc/1"
        };
        return (
            200,
            format!(
                "<html><body><h1 class=\"bookname\">回环性能测试书</h1><a class=\"toc-start\" href=\"{toc1}\">目录</a></body></html>"
            ),
        );
    }

    // 成环模式：c1 ↔ c2 互指（每页 20 章）
    if cfg.cycle {
        return match path {
            "/toc/c1" => (200, page_html("c1", &["/toc/c2".to_string()])),
            "/toc/c2" => (200, page_html("c2", &["/toc/c1".to_string()])),
            _ => (404, "not found".to_string()),
        };
    }

    // 失控链模式：/run/{k}，k < pages 时 next → /run/{k+1}（全部全新 URL）
    if cfg.runaway {
        if let Some(k) = path.strip_prefix("/run/") {
            let k: u32 = match k.parse() {
                Ok(v) => v,
                Err(_) => return (404, "not found".to_string()),
            };
            if k == 0 || k > cfg.pages {
                return (404, "not found".to_string());
            }
            if let Some(fp) = cfg.fail_page {
                if k == fp {
                    return (500, "injected failure".to_string());
                }
            }
            let next = (k < cfg.pages)
                .then(|| format!("/run/{}", k + 1))
                .into_iter()
                .collect::<Vec<_>>();
            return (200, page_html(&k.to_string(), &next));
        }
        return (404, "not found".to_string());
    }

    // 常规模式：/toc/{k}
    if let Some(k) = path.strip_prefix("/toc/") {
        let k: u32 = match k.parse() {
            Ok(v) => v,
            Err(_) => return (404, "not found".to_string()),
        };
        if k == 0 || k > cfg.pages {
            return (404, "not found".to_string());
        }
        if let Some(fp) = cfg.fail_page {
            if k == fp {
                return (500, "injected failure".to_string());
            }
        }
        let next: Vec<String> = if cfg.parallel_list {
            if k == 1 {
                (2..=cfg.pages).map(|v| format!("/toc/{v}")).collect()
            } else {
                Vec::new()
            }
        } else {
            (k < cfg.pages)
                .then(|| format!("/toc/{}", k + 1))
                .into_iter()
                .collect()
        };
        return (200, page_html(&k.to_string(), &next));
    }

    (404, "not found".to_string())
}

// ─── 场景装配：起服务器 + 写书源 + 写书行 ──────────────────────────────────

/// 装配一个独立场景（独立端口 → URL 唯一 → PageBodyCache 不跨场景串键）。
/// 书源规则纯 CSS（无 JS）：两档 feature 行为一致。
fn setup_scenario(cfg: ServerCfg) -> (String, String, Arc<ServerStats>) {
    ENV_INIT.call_once(setup_env);
    let (port, stats) = spawn_toc_server(cfg);
    let source_url = format!("http://127.0.0.1:{port}/src");
    let book_url = format!("http://127.0.0.1:{port}/book/1");
    let source_json = format!(
        r#"{{"bookSourceUrl":"{source_url}","bookSourceName":"回环性能源","ruleBookInfo":{{"name":"h1.bookname@text","tocUrl":"class.toc-start@href"}},"ruleToc":{{"chapterList":"class.chapter-item","chapterName":"tag.a@text","chapterUrl":"tag.a@href","nextTocUrl":"class.next@href"}}}}"#
    );
    // add_source 接受单个 BookSource JSON 对象
    legado_ffi::api::source::add_source(&source_json).expect("夹具书源写入");
    // 书行（换源场景：book_url 稳定主键；toc_url 空 → 取址回退书籍页路径；
    // origin 指向本场景书源，book_type 打 NOT_SHELF 对齐占位落库语义）
    let book = legado_ffi::legado_core::models::Book {
        book_url: book_url.clone(),
        origin: source_url.clone(),
        origin_name: "回环性能源".to_string(),
        book_type: legado_ffi::legado_core::models::book::book_type::NOT_SHELF,
        ..legado_ffi::legado_core::models::Book::default()
    };
    legado_ffi::db_state::with_database(|db| {
        let repo = legado_ffi::legado_db::BookRepository::new(db.connection());
        repo.insert(&book)?;
        Ok(())
    })
    .expect("书行写入");
    (source_url, book_url, stats)
}

/// 驱动生产入口并计时（毫秒）
fn run_refresh(
    book_url: &str,
    source_url: &str,
) -> (
    Result<
        legado_ffi::api::reader::ChapterListResponse,
        legado_ffi::legado_core::error::LegadoError,
    >,
    u128,
) {
    let t = Instant::now();
    let r = legado_ffi::api::reader::refresh_toc(book_url, source_url);
    (r, t.elapsed().as_millis())
}

// ─── 1. 量化（优化前后不变量：提供分阶段耗时表数据）────────────────────────

/// 串行 nextTocUrl 链的耗时曲线：N=10/50（+N=200 需 TOC_PERF_FULL=1）×
/// D=0/D=300ms。D=0 度量纯我方每页成本；D=300 度量「页数 × 站点延迟」的
/// 线性放大（真实 10 分钟重载的主因形态）。
#[test]
fn perf_serial_timing_matrix() {
    let _lock = lock_test();
    let ns: Vec<u32> = if std::env::var("TOC_PERF_FULL").is_ok() {
        vec![10, 50, 200]
    } else {
        vec![10, 50]
    };
    eprintln!("[perf] 串行 nextTocUrl 链（详情页 + 首抓页 + N-1 后续页 = N+1 次请求；每页 {CH_PER_PAGE} 章）:");
    for &n in &ns {
        // D=0：纯我方成本
        let (src, book, stats) = setup_scenario(ServerCfg::serial(n, 0, None));
        let (resp, ms0) = run_refresh(&book, &src);
        let total = resp
            .unwrap_or_else(|e| panic!("N={n} D=0 刷新失败: {e}"))
            .total;
        assert_eq!(total as u32, n * CH_PER_PAGE, "N={n} D=0 章数不符");

        // D=300ms：模拟慢站点
        let (src2, book2, _stats2) = setup_scenario(ServerCfg::serial(n, 300, None));
        let (resp2, ms300) = run_refresh(&book2, &src2);
        let total2 = resp2
            .unwrap_or_else(|e| panic!("N={n} D=300 刷新失败: {e}"))
            .total;
        assert_eq!(total2 as u32, n * CH_PER_PAGE, "N={n} D=300 章数不符");

        // 线性放大下界：(N+1) 次请求 × 300ms（90% 容差，吸收时钟/调度抖动）
        let lower = (n as u128 + 1) * 300 * 9 / 10;
        assert!(
            ms300 >= lower,
            "N={n} D=300 总耗时 {ms300}ms < 下界 {lower}ms（应 ≈ (N+1)×D 线性放大）"
        );
        // 上界健全性：排除意外 O(N²)/重试风暴级劣化（3× 延迟 + 60s 固定项）
        let upper = (n as u128 + 1) * 300 * 3 + 60_000;
        assert!(
            ms300 <= upper,
            "N={n} D=300 总耗时 {ms300}ms > 上界 {upper}ms（存在超线性放大？需复查）"
        );

        // 我方每页成本 ≈ (D=0 总耗时) / (N+1)；站点延迟占比 ≈ 300ms/(每页成本)
        let reqs = n as u128 + 1;
        let per_page_ours = ms0 / reqs;
        let per_page_delay = (ms300 - ms0) / reqs;
        let detail_hits = stats
            .path_hits
            .lock()
            .unwrap()
            .get("/book/1")
            .copied()
            .unwrap_or(0);
        eprintln!(
            "[perf]   N={n:<4} D=0: {ms0:>8} ms（每页我方成本 ≈ {per_page_ours} ms，详情命中 {detail_hits} 次）\
             | D=300: {ms300:>8} ms（每页实测延迟 ≈ {per_page_delay} ms；站点延迟占每页成本 ≈ {}%）",
            if per_page_ours > 0 {
                (300 * 100 / per_page_delay.max(1)).min(999)
            } else {
                999
            }
        );
    }
}

/// 判停不变量：nextTocUrl 成环（c1 ↔ c2）时 visited 去重必须判停，
/// 各页恰好命中 1 次（优化前后都必须成立，防止优化破坏既有判停）。
#[test]
fn perf_serial_cycle_stop() {
    let _lock = lock_test();
    let (src, book, stats) = setup_scenario(ServerCfg::cycle(0));
    let (resp, ms) = run_refresh(&book, &src);
    let total = resp.expect("成环场景刷新失败").total;
    assert_eq!(total as u32, 2 * CH_PER_PAGE, "成环应判停在 2 页（40 章）");
    assert!(ms < 10_000, "成环判停不应有长耗时（实测 {ms}ms）");
    let hits = stats.path_hits.lock().unwrap();
    assert_eq!(*hits.get("/toc/c1").unwrap_or(&0), 1, "c1 应恰好命中 1 次");
    assert_eq!(*hits.get("/toc/c2").unwrap_or(&0), 1, "c2 应恰好命中 1 次");
}

// ─── 2. 优化验收（优化前 RED、优化后 GREEN）────────────────────────────────

/// 并行拉页（>1 个 nextTocUrl）必须有并发上限（对齐上游 mapAsync(threadCount=32)）。
/// 优化前 `join_all` 无界 → N=200 时 ≈199 个并发连接打爆站点/本地回环；
/// 优化后按 32 一波推进，总耗时 ≈ ceil((N-1)/32)×D。
#[test]
fn perf_parallel_bounded() {
    let _lock = lock_test();
    let n = 200u32;
    let (src, book, stats) = setup_scenario(ServerCfg::parallel_list(n, 300, None));
    let (resp, ms) = run_refresh(&book, &src);
    let total = resp.expect("并行刷新失败").total;
    assert_eq!(
        total as u32,
        n * CH_PER_PAGE,
        "并行章数必须全量（不可静默丢章），实际 {total}"
    );
    let max_in_flight = stats.max_in_flight.load(Ordering::SeqCst);
    // 优化前 RED：max_in_flight ≈ N-1 = 199（无界）
    assert!(
        max_in_flight <= EXPECTED_PAGE_CONCURRENCY,
        "并行拉页并发无上限：实测最大并发 {max_in_flight}（要求 ≤{EXPECTED_PAGE_CONCURRENCY}，对齐上游 threadCount=32）"
    );
    // 总耗时 ≈ 波数 × D：优化前 ≈ 1 波（D+详情 ≈ 900ms < 下界）→ RED
    let waves = (n - 1).div_ceil(EXPECTED_PAGE_CONCURRENCY as u32) as u128;
    let lower = waves * 300 * 9 / 10;
    assert!(
        ms >= lower,
        "并行总耗时 {ms}ms < 下界 {lower}ms（应有界推进 ≈ {waves} 波 × 300ms）"
    );
    let upper = waves * 300 * 2 + 20_000;
    assert!(
        ms <= upper,
        "并行总耗时 {ms}ms > 上界 {upper}ms（波次串行化过慢？）"
    );
    eprintln!("[perf] 并行 N={n} D=300ms：总 {ms}ms，最大并发 {max_in_flight}，波数 {waves}");
}

/// 并行分支单页失败必须整刷失败（对齐上游 `res.body!!` NPE 语义）——
/// 不可静默丢章。优化前 `eprintln + 跳过` → Ok(80 章) → RED。
#[test]
fn perf_parallel_failure_no_silent_loss() {
    let _lock = lock_test();
    // 5 页并行列表：第 1 页带 /toc/2..=5 四条 next，注入第 3 页 500
    let (src, book, stats) = setup_scenario(ServerCfg::parallel_list(5, 0, Some(3)));
    let (resp, _ms) = run_refresh(&book, &src);
    assert!(
        resp.is_err(),
        "并行分支单页 HTTP 失败必须整刷失败（对齐上游 res.body!!，不可静默丢章）；实际 Ok({:?})",
        resp.as_ref().map(|r| r.total)
    );
    // 失败页确实被请求过（排除「根本没发请求」的假通过）
    let hits = stats.path_hits.lock().unwrap();
    assert!(hits.contains_key("/toc/3"), "失败页 /toc/3 应已被请求");
}

/// 串行分支单页 HTTP 非 2xx 应截断保留前缀（对齐上游 `res.body?.let`
/// body-null 判停语义）——而非整刷失败。优化前 `fetch_simple_cached(...)?`
/// 硬失败 → Err → RED。
#[test]
fn perf_serial_failure_truncates() {
    let _lock = lock_test();
    // 10 页串行链：注入第 5 页 500 → 应保留前 4 页（80 章）
    let (src, book, stats) = setup_scenario(ServerCfg::serial(10, 0, Some(5)));
    let (resp, _ms) = run_refresh(&book, &src);
    let r = resp
        .expect("串行分支单页 HTTP 失败应截断保留前缀（对齐上游 body-null 判停），而非整刷失败");
    assert_eq!(
        r.total as u32,
        4 * CH_PER_PAGE,
        "截断点 = 失败页之前（4 页 × {CH_PER_PAGE} 章），实际 {}",
        r.total
    );
    // 失败页之后的页不应再被请求（判停生效）
    let hits = stats.path_hits.lock().unwrap();
    assert_eq!(
        *hits.get("/toc/6").unwrap_or(&0),
        0,
        "失败页之后的页不应被请求"
    );
}

/// 无界新 URL 链（每页 next 都不同，visited 去重失效）必须按 MAX_TOC_PAGES
/// 上限判停。优化前 600 页全抓（12000 章）→ RED；优化后 512 页（10240 章）。
#[test]
fn perf_serial_unbounded_chain_guarded() {
    let _lock = lock_test();
    let (src, book, stats) = setup_scenario(ServerCfg::runaway(600, 0));
    let (resp, ms) = run_refresh(&book, &src);
    let r = resp.expect("失控链场景刷新失败");
    assert_eq!(
        r.total as u32,
        EXPECTED_MAX_TOC_PAGES * CH_PER_PAGE,
        "无界新 URL 链应按 MAX_TOC_PAGES={EXPECTED_MAX_TOC_PAGES} 判停（{EXPECTED_MAX_TOC_PAGES}×{CH_PER_PAGE} 章），实际 {}（未设上限会抓到 600 页 = 12000 章）",
        r.total
    );
    let toc_hits: u32 = stats
        .path_hits
        .lock()
        .unwrap()
        .iter()
        .filter(|(p, _)| p.starts_with("/run/"))
        .map(|(_, v)| *v)
        .sum();
    assert_eq!(
        toc_hits, EXPECTED_MAX_TOC_PAGES,
        "失控链实际抓取的页数 = {toc_hits}（应 = MAX_TOC_PAGES）"
    );
    assert!(ms < 60_000, "失控链判停后总耗时应有限（实测 {ms}ms）");
    eprintln!("[perf] 失控链 600 页 → 判停在 {toc_hits} 页，总耗时 {ms}ms");
}

/// 换源/重复刷新抢占：在途旧刷新的目录分页链应被新刷新代数取消
/// （对齐上游 `ensureActive()` 判活语义；无状态 FFI 用进程级代数计数器）。
/// 优化前旧刷新跑完全程（≈4.4s 后 Ok 返回）→ RED。
#[test]
fn perf_stale_refresh_cancelled() {
    let _lock = lock_test();
    let (src, book, _stats) = setup_scenario(ServerCfg::serial(10, 400, None));
    // 旧刷新（线程 A）：10 页 × 400ms ≈ 4.4s 串行链
    let a_src = src.clone();
    let a_book = book.clone();
    let a = std::thread::spawn(move || run_refresh(&a_book, &a_src));
    // 在途（约第 3~4 页）时发起新刷新（代数 +1 → 旧链应在下一页边界中止）
    std::thread::sleep(Duration::from_millis(1600));
    // 注意参数序：run_refresh(book_url, source_url)
    let (b_res, b_ms) = run_refresh(&book, &src);
    eprintln!(
        "[perf] B 刷新结果: {}",
        match &b_res {
            Ok(r) => format!("Ok(total={})", r.total),
            Err(e) => format!("Err({e})"),
        }
    );
    assert!(b_res.is_ok(), "新刷新应正常完成（b 耗时 {b_ms}ms）");
    let (a_res, a_ms) = a.join().expect("旧刷新线程 join");
    // 优化前 RED：A 跑完全程 ≈4.4s 且 Ok
    assert!(
        a_res.is_err(),
        "旧刷新应被新代数抢占（在途分页链中止并报错），实际仍正常完成（{a_ms}ms）——10 分钟在途链换源时无法取消的根因"
    );
    assert!(
        a_ms < 3000,
        "旧刷新应在新代数发起后约 1 页边界内中止（≤3s），实际 {a_ms}ms"
    );
    eprintln!("[perf] 取消抢占：旧刷新 {a_ms}ms 中止（Err），新刷新 {b_ms}ms 完成");
}
