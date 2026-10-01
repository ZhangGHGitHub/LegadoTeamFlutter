//! WebBook FFI API（P5 子批 2a：抓取本体下沉 `legado-fetcher` 后的宿主包装层）
//!
//! 为 Flutter/Dart 提供书源驱动的搜索、目录、内容获取能力：本层保留**同名
//! 同步入口**（`runtime::block_on` 驱动；ffi.rs 调用点零改动），抓取本体
//! （`RealBookSourceFetcher`、进程级缓存、入口编排）位于 `legado-fetcher`。
//!
//! 本层职责：
//! - 宿主注入面组装（共享 HTTP 客户端 / 登录头缓存 / DB 书籍变量 / 书源 setup）；
//! - 兄弟模块引用收口（re-export 纯函数与进程级状态，路径与原实现同名）；
//! - 依赖宿主态的回归测试（DB / 网络探针 / test_support；其余纯逻辑测试
//!   已随迁 `legado-fetcher`）。

use std::sync::Arc;

use legado_core::models::BookSource;
use legado_core::web_book::{WebBookEngine, WebBookInfo};
use legado_core::LegadoResult;
use legado_fetcher::deps::FetcherDeps;

use crate::runtime;

pub use legado_fetcher::web_book::RealBookSourceFetcher;

// ─── 兄弟模块引用收口（re-export：原 `api::web_book` 路径与签名不变）──────────
pub(crate) use legado_fetcher::web_book::{
    begin_book_flow, book_var_overlay_map, build_js_orchestrator, bump_toc_fetch_epoch,
    chapter_url_variables, convert_js_search_results, matches_book_url_pattern,
    merge_variables_json, record_next_chapter_map,
};

// ─── 宿主注入面组装 ───────────────────────────────────────────────────────────

/// 按 bookUrl 读用户书籍变量（DB `books.variable`，P1-1 两路反查）
///
/// 先按稳定主键 bookUrl（未换源书直接命中），再按 originBookUrl（换源后书籍：
/// Dart 取址点以 originBookUrl 优先传入，稳定主键 bookUrl 仍为旧源 URL，
/// 单路 `find_by_url` 会漏查）。DB 未初始化/无此书行/值为空 → None
/// （优雅降级：未接库时抓取链路依旧可用）。
pub(crate) fn db_book_variable(book_url: &str) -> Option<String> {
    crate::db_state::with_database(|db| {
        let repo = legado_db::BookRepository::new(db.connection());
        let found = match repo.find_by_url(book_url)? {
            Some(book) => Some(book),
            None => repo.find_by_origin_book_url(book_url)?,
        };
        Ok(found.and_then(|b| b.variable))
    })
    .ok()
    .flatten()
    .filter(|v| !v.trim().is_empty())
}

/// 组装 ffi 宿主注入面（共享客户端 + 进程级限流注册表 + 登录头/DB 变量/setup）
pub(crate) fn ffi_deps() -> LegadoResult<FetcherDeps> {
    Ok(FetcherDeps {
        client: crate::http_state::shared_client()?,
        rate_limiter: crate::api::source_rate_limit::registry(),
        login_header: Some(Arc::new(|url: &str| {
            crate::api::source_login_cache::get_login_header(url)
        })),
        book_variable: Some(Arc::new(db_book_variable)),
        source_context: Some(Arc::new(|source: &BookSource| {
            crate::api::source_js_bindings::book_source_js_setup_script(source).ok()
        })),
    })
}

/// 真实 fetcher（共享客户端 + 全量注入；下沉前 `RealBookSourceFetcher::new()`
/// 的 ffi 侧替身）
///
/// `pub`：source_switch/toc 回归测试与 `examples/` 诊断脚本复用同一注入面
/// （登录头 / DB 书籍变量 / 书源 setup 全量；避免各调用点自建 FetcherDeps
/// 造成注入面漂移）。
pub fn real_fetcher() -> LegadoResult<RealBookSourceFetcher> {
    Ok(RealBookSourceFetcher::with_deps(ffi_deps()?))
}

/// 构建 WebBookEngine（共享客户端注入；reader/pre_update/audio_api 等复用）
pub fn build_engine() -> LegadoResult<WebBookEngine<RealBookSourceFetcher>> {
    Ok(legado_fetcher::web_book::build_engine(ffi_deps()?))
}

/// 详情解析（宿主注入面；供 search.rs 列表解析的 bookUrlPattern 详情直连路径）
pub(crate) fn parse_book_info_from_body(
    source: &BookSource,
    body: String,
    book_url: &str,
    redirect_url: &str,
    can_re_name: bool,
    existing_name: &str,
    existing_author: &str,
) -> LegadoResult<WebBookInfo> {
    Ok(real_fetcher()?.parse_book_info_from_body(
        source,
        body,
        book_url,
        redirect_url,
        can_re_name,
        existing_name,
        existing_author,
    ))
}

// ─── 公开入口：同步包装（ffi.rs:1280-1336 调用点零改动）──────────────────────

/// 搜索书籍（书源规则驱动，返回 JSON 数组字符串）
pub fn webbook_search(source_json: &str, query: &str, page: i32) -> LegadoResult<String> {
    let deps = ffi_deps()?;
    runtime::block_on(legado_fetcher::web_book::webbook_search(
        deps,
        source_json,
        query,
        page,
    ))
}

/// 获取书籍详情（返回 WebBookInfo JSON 字符串）
pub fn webbook_info(source_json: &str, book_url: &str) -> LegadoResult<String> {
    let deps = ffi_deps()?;
    runtime::block_on(legado_fetcher::web_book::webbook_info(
        deps,
        source_json,
        book_url,
    ))
}

/// 获取章节列表（返回 WebChapter JSON 数组字符串）
pub fn webbook_chapters(
    source_json: &str,
    book_url: &str,
    toc_url: &str,
    book_name: &str,
) -> LegadoResult<String> {
    let deps = ffi_deps()?;
    runtime::block_on(legado_fetcher::web_book::webbook_chapters(
        deps,
        source_json,
        book_url,
        toc_url,
        book_name,
    ))
}

/// 获取章节正文内容（返回正文文本）
pub fn webbook_content(source_json: &str, chapter_json: &str) -> LegadoResult<String> {
    let deps = ffi_deps()?;
    runtime::block_on(legado_fetcher::web_book::webbook_content(
        deps,
        source_json,
        chapter_json,
    ))
}

// ─── 宿主态测试助手（仅测试编译：包装层测试经宿主注入面驱动）──────────────────

/// 以宿主注入面走「变量链」详情获取（单测可注入脚本化 fetcher）
#[cfg(test)]
pub(crate) async fn webbook_info_with_fetcher<F: legado_core::web_book::BookSourceFetcher>(
    source: &BookSource,
    book_url: &str,
    fetcher: &F,
) -> LegadoResult<WebBookInfo> {
    let deps = ffi_deps()?;
    legado_fetcher::web_book::webbook_info_with_fetcher(&deps, source, book_url, fetcher).await
}

/// 以宿主注入面走「变量链」目录获取（单测可注入脚本化 fetcher）
#[cfg(test)]
pub(crate) async fn webbook_chapters_with_fetcher<F: legado_core::web_book::BookSourceFetcher>(
    source: &BookSource,
    book_url: &str,
    known_toc_url: Option<&str>,
    book_name_hint: Option<&str>,
    fetcher: &F,
) -> LegadoResult<Vec<legado_core::web_book::WebChapter>> {
    let deps = ffi_deps()?;
    legado_fetcher::web_book::webbook_chapters_with_fetcher(
        &deps,
        source,
        book_url,
        known_toc_url,
        book_name_hint,
        fetcher,
    )
    .await
}

/// 以宿主注入面记录 book 元信息（回归测试播种/断言用）
///
/// 仅 quickjs 门控的宿主态回归测试引用（默认档无调用者）。
#[cfg(test)]
#[allow(dead_code)]
pub(crate) fn record_book_meta_from_info(book_url: &str, info: &WebBookInfo) {
    if let Ok(deps) = ffi_deps() {
        legado_fetcher::web_book::record_book_meta_from_info(&deps, book_url, info);
    }
}

/// 以宿主注入面解析书源请求头（P2-19 口径回归测试用）
#[cfg(test)]
pub(crate) fn parse_source_headers(
    source: &BookSource,
) -> Option<std::collections::HashMap<String, String>> {
    real_fetcher()
        .ok()
        .and_then(|f| f.parse_source_headers(source))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::GLOBAL_STORE_TEST_LOCK;
    use legado_core::models::book_source::book_source_type;
    use legado_core::web_book::{BookSourceFetcher, WebBookInfo, WebChapter, WebSearchResult};
    use legado_core::LegadoError;
    use legado_js::host_api::variable_store;
    use legado_parser::AnalyzeUrl;

    /// 生产入口（ffi 包装层）同名解析助手：展开 Result 供断言直接使用
    ///
    /// 仅 quickjs 门控的宿主态回归测试引用（默认档无调用者）。
    #[allow(dead_code)]
    fn parse_info(
        source: &BookSource,
        body: String,
        book_url: &str,
        redirect_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
    ) -> WebBookInfo {
        parse_book_info_from_body(
            source,
            body,
            book_url,
            redirect_url,
            can_re_name,
            existing_name,
            existing_author,
        )
        .expect("parse_book_info_from_body")
    }

    /// 书山聚合目录回归：真实书源 + 真实 data: URI bookUrl 调 webbook_chapters。
    /// 覆盖链路：data:URI hex 解码 → init 规则 java.ajax(/details)（带书源
    /// header 规则 X-Novel-Token + JSON Content-Type）→ tocUrl 规则产出
    /// catalogUrl → chapterList java.ajax(/catalog) → 章节列表。
    /// — 书山目录修复（2026-08-17）
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_shushan_real_toc_repro() {
        // webbook_chapters / webbook_content 会触发 P2-9 ③ 全局变量桥
        // （begin_book_flow / ensure_global_variable_bridge），串行防串表
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("书山"))
        }) else {
            eprintln!("未找到书山聚合源，跳过");
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        use base64::Engine;
        // 书库阁书（目录+正文链路回归；正文为 VIP 提示文本，非空即可）
        let detail_url = "http://www.shukuge.com/book/117256/";
        let b64_url = base64::engine::general_purpose::STANDARD.encode(detail_url);
        let detail = serde_json::json!({
            "source": "书库阁",
            "url": b64_url,
            "name": "一念永恒测试",
        });
        let b64_detail = base64::engine::general_purpose::STANDARD.encode(detail.to_string());
        let book_url = format!(
            r#"data:detailsUrl;base64,{},{{"type":"susan"}}"#,
            b64_detail
        );
        // 真实番茄书（5556 模拟器书架导出）：验证登录后正文返回明文
        let real_book_url =
            std::fs::read_to_string("C:/Users/Public/real_bookurl.txt").unwrap_or_default();
        let book_url = if !real_book_url.trim().is_empty() {
            real_book_url.trim().to_string()
        } else {
            book_url
        };
        let source_json = serde_json::to_string(&source).unwrap();
        // 注入设备 ID（对齐 Flutter 启动时 RustApi._injectDeviceId）
        legado_js::host_api::device_id::set_device_id("62d8d4fb53e19733");
        // V1 登录回归：书山 login() 在书源上下文执行 → putLoginHeader(api_key)
        // → sync 落库 → 正文请求携带 X-Api-Key 返回明文
        crate::api::source_login_cache::put_login_info(
            &source.book_source_url,
            r#"{"邮箱":"512824117@qq.com","密码":"zgh5201214"}"#,
        )
        .unwrap();
        let login_out = match crate::api::source_login_v1_api::eval_login_v1(&source_json, "login")
        {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[repro] V1 登录执行错误: {e}");
                String::new()
            }
        };
        eprintln!(
            "[repro] V1 登录结果: {}",
            login_out.chars().take(80).collect::<String>()
        );
        let lh = crate::api::source_login_cache::get_login_header(&source.book_source_url)
            .unwrap_or_default();
        eprintln!(
            "[repro] loginHeader: {}",
            lh.chars().take(60).collect::<String>()
        );
        assert!(
            !lh.is_empty() && lh != "null",
            "书山 V1 登录应写入 loginHeader(api_key): {lh:?}"
        );
        // 目录回归（重试一次；连续两次失败判定为站点侧抖动并跳过）：
        // 上方登录断言是核心回归信号，保持严格；目录/正文 e2e 为次要覆盖，
        // 站点偶发返回异常响应（反爬抖动）时不应让 CI 变红。
        let mut chapters: Option<Vec<serde_json::Value>> = None;
        for attempt in 1..=2u32 {
            match webbook_chapters(&source_json, &book_url, "", "") {
                Ok(s) => {
                    let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                    eprintln!("[repro] 目录 {} 章（第 {attempt} 次尝试）", arr.len());
                    assert!(arr.len() > 5, "书山目录应 >5 章，实际 {}", arr.len());
                    chapters = Some(arr);
                    break;
                }
                Err(e) => {
                    eprintln!("[repro] 目录抓取第 {attempt} 次失败: {e}");
                    if attempt == 1 {
                        std::thread::sleep(std::time::Duration::from_secs(2));
                    } else {
                        eprintln!("[repro] 连续两次失败，判定为站点侧抖动，跳过（可手动重跑验证）");
                        return;
                    }
                }
            }
        }
        let chapters = chapters.expect("目录结果应在 break 前写入");
        // 正文回归：取第一章 data:chapterUrl 调 webbook_content
        let first = chapters.first().cloned().unwrap_or_default();
        let ch_url = first.get("url").and_then(|u| u.as_str()).unwrap_or("");
        eprintln!(
            "[repro] 第一章 url 前缀: {}",
            &ch_url[..ch_url.len().min(120)]
        );
        if !ch_url.is_empty() {
            let ch_json = serde_json::json!({
                "url": ch_url,
                "title": first.get("title").and_then(|t| t.as_str()).unwrap_or(""),
                "index": 0,
                "is_vip": false,
            })
            .to_string();

            let content = webbook_content(&source_json, &ch_json);
            match content {
                Ok(c) => {
                    eprintln!(
                        "[repro] 正文前120: {}",
                        c.chars().take(120).collect::<String>()
                    );
                    assert!(c.trim().len() > 50, "正文应非空，实际 {}", c.trim().len());
                }
                Err(e) => panic!("[repro] 书山正文失败: {e}"),
            }
        }
    }

    /// 批量搜索扫描（2026-08-17）：人工实网诊断，不作为 CI 回归门禁。
    /// fixture/源站网络波动时只输出统计；需手工运行并对照原版。
    #[test]
    #[ignore = "外部 fixture 与源站网络诊断，非确定性 CI 测试"]
    fn test_batch_search_scan_text_sources() {
        // 调 webbook_search（入口执行 begin_book_flow 切 flow scope）→ 触碰全局
        // store，持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("sources_device.json 缺失，跳过");
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let mut scanned = 0;
        let mut ok = 0;
        let mut empty = 0;
        let mut failed = 0;
        for src in sources.iter() {
            let st = src
                .get("bookSourceType")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            if st != 0 {
                continue;
            }
            let name = src
                .get("bookSourceName")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            let url = src
                .get("bookSourceUrl")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            if !url.contains("://") {
                continue;
            }
            let Ok(source) =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap())
            else {
                continue;
            };
            if source
                .rule_search
                .as_ref()
                .and_then(|r| r.book_list.as_deref())
                .unwrap_or("")
                .is_empty()
            {
                continue;
            }
            scanned += 1;
            let source_json = serde_json::to_string(&source).unwrap();
            match webbook_search(&source_json, "一念", 1) {
                Ok(s) => {
                    let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                    if arr.is_empty() {
                        empty += 1;
                        eprintln!("[scan-empty] {} | {}", name, url);
                    } else {
                        ok += 1;
                    }
                }
                Err(e) => {
                    failed += 1;
                    eprintln!(
                        "[scan-fail] {} | {} | {}",
                        name,
                        url,
                        e.to_string().chars().take(120).collect::<String>()
                    );
                }
            }
            if scanned >= 120 {
                break;
            }
        }
        eprintln!(
            "[scan-summary] scanned={} ok={} empty={} failed={}",
            scanned, ok, empty, failed
        );
    }

    /// 扩展扫描：跳过前 120 个 type-0，再扫 200 个，供人工对照原版。
    #[test]
    #[ignore = "外部源站批量诊断，非确定性 CI 测试"]
    fn test_batch_search_scan_extended_wave2() {
        // P2-9 ③ / P1-2：入口 begin_book_flow 切 flow scope（只清旧 scope
        // 前缀，持久裸键不受影响），与 ③ 桥测试串行
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        // 输出目标：改用系统临时目录，避免写仓库内/仓库根 tmp_parity/ 被 git 跟踪的路径
        let out_dir = std::env::temp_dir().join("legado_parity");
        let _ = std::fs::create_dir_all(&out_dir);
        let out_path = out_dir.join("scan_wave2.jsonl");
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("sources_device.json 缺失，跳过");
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let mut skip = 0usize;
        let mut scanned = 0usize;
        let mut ok = 0usize;
        let mut empty = 0usize;
        let mut failed = 0usize;
        let mut lines: Vec<String> = Vec::new();
        for src in sources.iter() {
            let st = src
                .get("bookSourceType")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            if st != 0 {
                continue;
            }
            let name = src
                .get("bookSourceName")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            let url = src
                .get("bookSourceUrl")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            if !url.contains("://") {
                continue;
            }
            let Ok(source) =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap())
            else {
                continue;
            };
            if source
                .rule_search
                .as_ref()
                .and_then(|r| r.book_list.as_deref())
                .unwrap_or("")
                .is_empty()
            {
                continue;
            }
            if skip < 120 {
                skip += 1;
                continue;
            }
            scanned += 1;
            let source_json = serde_json::to_string(&source).unwrap();
            let (status, detail, count) = match webbook_search(&source_json, "一念", 1) {
                Ok(s) => {
                    let arr: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                    if arr.is_empty() {
                        empty += 1;
                        ("empty", String::new(), 0usize)
                    } else {
                        ok += 1;
                        ("ok", String::new(), arr.len())
                    }
                }
                Err(e) => {
                    failed += 1;
                    (
                        "fail",
                        e.to_string().chars().take(160).collect::<String>(),
                        0usize,
                    )
                }
            };
            if status != "ok" {
                eprintln!("[wave2-{}] {} | {} | {}", status, name, url, detail);
            }
            lines.push(
                serde_json::json!({
                    "status": status,
                    "name": name,
                    "url": url,
                    "count": count,
                    "detail": detail,
                })
                .to_string(),
            );
            if scanned >= 200 {
                break;
            }
        }
        let _ = std::fs::write(&out_path, lines.join("\n"));
        eprintln!(
            "[wave2-summary] scanned={} ok={} empty={} failed={} out={}",
            scanned,
            ok,
            empty,
            failed,
            out_path.display()
        );
    }

    /// 七步阁站点可达性探测：不可达或非 2xx 时返回 false（跳过）。
    /// 外部站状态不应让 CI 变红；站点恢复后 e2e 自动回归。
    // 仅被 quickjs 门控的 test_qibuge_search_diag 调用：默认档下调用方
    // 不编译 → 函数随之门控，免 dead_code
    #[cfg(feature = "quickjs")]
    fn qibuge_site_reachable() -> bool {
        let client = match crate::http_state::shared_client() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[qibuge] 共享客户端初始化失败: {e}，跳过 e2e");
                return false;
            }
        };
        let probe = crate::runtime::block_on(client.get("https://m.qibuge.com/s.php", None));
        match probe {
            Ok(resp) if resp.is_success() => true,
            Ok(resp) => {
                eprintln!(
                    "[qibuge] 站点不可用: HTTP {}，跳过 e2e（站点恢复后自动回归）",
                    resp.status
                );
                false
            }
            Err(e) => {
                eprintln!("[qibuge] 站点不可达: {e}，跳过 e2e");
                false
            }
        }
    }

    /// 七步阁 GBK POST 搜索回归（2026-08-17）：bookUrlPattern 全匹配修复
    /// （m.qibuge.com 正则不得命中 /s.php 搜索页 URL）
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_qibuge_search_diag() {
        // P2-1：fixture 存在时 webbook_search 会执行 begin_book_flow（切
        // flow scope）→ 与其它 store 测试串行
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        if !qibuge_site_reachable() {
            return;
        }
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("七步阁"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup,
        );
        eprintln!("[qibuge] request_body: {:?}", au.request_body());
        eprintln!(
            "[qibuge] request_body={:?} encoded_form={:?} headers={:?}",
            au.request_body(),
            au.encoded_form(),
            au.headers()
        );
        eprintln!(
            "[qibuge] URL: {} method: {:?} body: {:?} charset: {:?}",
            au.url(),
            au.method(),
            au.body(),
            au.charset()
        );
        let fetcher = crate::api::web_book::real_fetcher().unwrap();
        let headers = crate::api::web_book::parse_source_headers(&source);
        eprintln!("[qibuge] source_headers: {:?}", headers);
        let body =
            crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref())).unwrap_or_default();
        eprintln!(
            "[qibuge] 响应体前300: {}",
            body.chars().take(300).collect::<String>()
        );
        eprintln!("[qibuge] 长度: {}", body.len());
        eprintln!("[qibuge] has_sone: {}", body.contains("sone"));
        eprintln!(
            "[qibuge] 全文: {}",
            body.chars().take(1500).collect::<String>()
        );
        // 完整 search 链路验证
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[qibuge] search 结果数: {}", list.len());
                assert!(!list.is_empty(), "七步阁搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(5) {
                    eprintln!(
                        "[qibuge]   -> {} | {} | {}",
                        it.name, it.author, it.book_url
                    );
                }
            }
            Err(err) => panic!("[qibuge] search 失败: {:?}", err),
        }
    }

    /// 七步阁 GBK 目录/正文回归：详情页 meta charset=gbk 必须在简单 GET 路径正确解码。
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_qibuge_catalog_and_content_gbk() {
        // P2-9 ③ / P1-2：入口 begin_book_flow 切 flow scope（只清旧 scope
        // 前缀，持久裸键不受影响），与 ③ 桥测试串行
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        if !qibuge_site_reachable() {
            return;
        }
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("七步阁"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let search = webbook_search(&source_json, "一念", 1).expect("七步阁搜索失败");
        let books: Vec<serde_json::Value> = serde_json::from_str(&search).unwrap();
        let first = books.first().expect("七步阁搜索应有结果");
        let book_url = first
            .get("book_url")
            .and_then(|v| v.as_str())
            .expect("缺少 book_url");
        let book_name = first.get("name").and_then(|v| v.as_str()).unwrap_or("");
        assert!(!book_name.contains('�'), "搜索书名乱码: {book_name}");

        let info = webbook_info(&source_json, book_url).expect("七步阁详情失败");
        let info: serde_json::Value = serde_json::from_str(&info).unwrap();
        let toc_url = info.get("toc_url").and_then(|v| v.as_str()).unwrap_or("");
        let chapters =
            webbook_chapters(&source_json, book_url, toc_url, book_name).expect("七步阁目录失败");
        let chapters: Vec<serde_json::Value> = serde_json::from_str(&chapters).unwrap();
        let first_chapter = chapters.first().expect("七步阁目录应有章节");
        let chapter_title = first_chapter
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        assert!(
            !chapter_title.is_empty() && !chapter_title.contains('�'),
            "目录标题乱码: {chapter_title:?}"
        );

        let content =
            webbook_content(&source_json, &first_chapter.to_string()).expect("七步阁正文失败");
        assert!(
            content.chars().count() > 30,
            "正文过短: {}",
            content.chars().count()
        );
        assert!(
            !content.contains('�'),
            "正文乱码: {}",
            content.chars().take(120).collect::<String>()
        );
        eprintln!(
            "[qibuge-gbk] 书名={book_name}，目录首章={chapter_title}，正文前80={}",
            content.chars().take(80).collect::<String>()
        );
    }

    /// 77读书网 搜索诊断（2026-08-17）：站点返回 47KB 含结果，规则 class.BOX@tr!0 解析为 0
    // 依赖外部源站在线状态（2026-09-03 实测站点返回空页），与同文件其他
    // 外部源站诊断一致不入 CI 门禁，手工诊断时 --ignored 运行
    #[test]
    #[ignore = "外部源站网络诊断，非确定性 CI 测试"]
    fn test_77shuku_search_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("77读书"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup.clone(),
        );
        eprintln!(
            "[77] URL: {} method: {:?} headers: {:?}",
            au.url(),
            au.method(),
            au.headers()
        );
        let fetcher = crate::api::web_book::real_fetcher().unwrap();
        let headers = crate::api::web_book::parse_source_headers(&source);
        let body =
            crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref())).unwrap_or_default();
        eprintln!(
            "[77] 长度: {} 含一念: {}",
            body.len(),
            body.contains("一念")
        );
        eprintln!(
            "[77] 含BOX: {} 含table: {} 含tr: {}",
            body.contains("BOX"),
            body.contains("<table"),
            body.contains("<tr")
        );
        let analyzer = crate::js_executor::construct_analyzer_with_source_context(
            body.clone(),
            au.url().to_string(),
            &source.book_source_url,
            None,
            setup.clone(),
        );
        for probe in [
            "class.BOX@tr!0",
            "table@tr!0",
            "table@tr",
            "css(table tr)",
            "css(tr)",
            "tr",
            "tag.tr",
            "class.BOX",
            "css(.BOX)",
            "css(table)",
            "class.BOX@tr",
            "class.BOX@table@tr",
            "table@tr!0@",
            "tag.table@tag.tr!0",
            "tag.table@tag.tr",
        ]
        .iter()
        {
            let n = analyzer.get_elements(probe).unwrap_or_default().len();
            eprintln!("[77] probe {probe:?} -> {n}");
        }
        if let Some(i) = body.find("BOX") {
            eprintln!(
                "[77] BOX 上下文: {:?}",
                body[i.saturating_sub(80)..(i + 300).min(body.len())]
                    .chars()
                    .collect::<String>()
            );
        }
        // 字段级诊断：第一个元素的 name/author/bookUrl 提取
        let elems77 = analyzer.get_elements("class.BOX@tr!0").unwrap_or_default();
        if let Some(elem) = elems77.first() {
            let mut ea = crate::js_executor::construct_analyzer_with_source_context(
                elem.clone(),
                au.url().to_string(),
                &source.book_source_url,
                None,
                setup.clone(),
            );
            ea.set_element_content(elem.clone());
            let rn = ea.get_string_ex("tag.td.2@a@text", false, false);
            let rb = ea.get_string_ex("tag.td.2@a@href", true, false);
            eprintln!("[77] elem0 name={:?} bookUrl={:?}", rn, rb);
            for probe in [
                "tag.td.2@a@text",
                "tag.td@a@text",
                "td.2@a@text",
                "td@a@text",
                "tag.td.2",
                "css(td:eq(2) a)",
                "a.0@text",
                "css(a)",
                "tag.a@text",
                "tag.td@tag.a@text",
                "tag.td.2@tag.a@text",
            ] {
                let v = ea.get_string_ex(probe, false, false).unwrap_or_default();
                eprintln!(
                    "[77]   probe {probe:?} -> {:?}",
                    v.chars().take(30).collect::<String>()
                );
            }
            eprintln!(
                "[77] elem0 前200: {:?}",
                elem.chars().take(200).collect::<String>()
            );
        }
        assert!(
            !elems77.is_empty(),
            "77读书网 bookList 应解析出元素，实际 {}",
            elems77.len()
        );
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[77] search 结果数: {}", list.len());
                assert!(
                    !list.is_empty(),
                    "77读书网搜索应有结果，实际 {}",
                    list.len()
                );
                for it in list.iter().take(3) {
                    eprintln!("[77]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[77] search 失败: {:?}", err),
        }
    }

    /// 淘小说 @js md5 签名搜索诊断（2026-08-17）
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_taoxiaoshuo_search_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("淘小说"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup,
        );
        eprintln!("[taoxs] URL: {}", au.url());
        // 直接测试 @js: 块执行（绕过静默回退）
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
            );
        let js_code = source
            .search_url
            .as_deref()
            .unwrap_or("")
            .trim_start_matches("@js:")
            .trim_start();
        eprintln!(
            "[taoxs] js_code 前150: {:?}",
            js_code.chars().take(150).collect::<String>()
        );
        let vars = std::collections::HashMap::from([
            ("key".to_string(), "一念".to_string()),
            ("page".to_string(), "1".to_string()),
        ]);
        let parsed = crate::legado_parser::AnalyzeUrl::parse_with_js(
            source.search_url.as_deref().unwrap_or(""),
            &vars,
            1,
            &exec,
        );
        match parsed {
            Ok(u) => eprintln!("[taoxs] parse_with_js OK: {}", u.url()),
            Err(err) => eprintln!("[taoxs] parse_with_js ERR: {:?}", err),
        }
        eprintln!(
            "[taoxs] method: {:?} headers: {:?}",
            au.method(),
            au.headers()
        );
        let fetcher = crate::api::web_book::real_fetcher().unwrap();
        let headers = crate::api::web_book::parse_source_headers(&source);
        let body =
            crate::runtime::block_on(fetcher.fetch_url(&au, headers.as_ref())).unwrap_or_default();
        eprintln!(
            "[taoxs] 响应长度: {} 前200: {:?}",
            body.len(),
            body.chars().take(200).collect::<String>()
        );
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[taoxs] search 结果数: {}", list.len());
                assert!(!list.is_empty(), "淘小说搜索应有结果，实际 {}", list.len());
                for it in list.iter().take(3) {
                    eprintln!("[taoxs]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[taoxs] search 失败: {:?}", err),
        }
    }

    /// 企鹅小说 setup 依赖搜索验证（2026-08-17）：searchUrl 用
    /// `{{url=source.getKey();...}}`，缺 setup 时模板残留 → HTTP 404
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_qiexs_search_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("企鹅小说"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        // 直接构造 AnalyzeUrl 看中间态
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
            );
        let vars = std::collections::HashMap::from([
            ("key".to_string(), "一念".to_string()),
            ("page".to_string(), "1".to_string()),
            ("baseUrl".to_string(), source.book_source_url.clone()),
            ("searchKey".to_string(), "一念".to_string()),
        ]);
        let parsed = crate::legado_parser::AnalyzeUrl::parse_with_js(
            source.search_url.as_deref().unwrap_or(""),
            &vars,
            1,
            &exec,
        );
        match &parsed {
            Ok(u) => eprintln!("[qiexs] parse_with_js OK: {}", u.url()),
            Err(err) => eprintln!("[qiexs] parse_with_js ERR: {:?}", err),
        }
        let fetcher = crate::api::web_book::real_fetcher().unwrap();
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[qiexs] search 结果数: {}", list.len());
                assert!(
                    !list.is_empty(),
                    "企鹅小说搜索应有结果，实际 {}",
                    list.len()
                );
                for it in list.iter().take(3) {
                    eprintln!("[qiexs]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[qiexs] search 失败: {:?}", err),
        }
    }

    /// 新笔趣阁 @js: 重定向拦截搜索验证（2026-08-17）：searchUrl 用
    /// java.get(su,{}).headers('Location')[0] 需 jsoup Response 语义桥
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_xbqgxs_search_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| {
                    n.contains("新笔趣阁")
                        && s.get("bookSourceUrl")
                            .and_then(|u| u.as_str())
                            .is_some_and(|u| u.contains("xbqgxs"))
                })
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        // 直接执行 @js: 块看错误
        let exec = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(
                crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
            );
        let vars = std::collections::HashMap::from([
            ("key".to_string(), "一念".to_string()),
            ("page".to_string(), "1".to_string()),
            ("baseUrl".to_string(), source.book_source_url.clone()),
        ]);
        let parsed = crate::legado_parser::AnalyzeUrl::parse_with_js(
            source.search_url.as_deref().unwrap_or(""),
            &vars,
            1,
            &exec,
        );
        match &parsed {
            Ok(u) => eprintln!(
                "[xbqgxs] parse_with_js OK: {}",
                u.url().chars().take(150).collect::<String>()
            ),
            Err(err) => eprintln!("[xbqgxs] parse_with_js ERR: {:?}", err),
        }
        let fetcher = crate::api::web_book::real_fetcher().unwrap();
        let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
        match results {
            Ok(list) => {
                eprintln!("[xbqgxs] search 结果数: {}", list.len());
                assert!(
                    !list.is_empty(),
                    "新笔趣阁搜索应有结果，实际 {}",
                    list.len()
                );
                for it in list.iter().take(3) {
                    eprintln!("[xbqgxs]   -> {} | {}", it.name, it.book_url);
                }
            }
            Err(err) => panic!("[xbqgxs] search 失败: {:?}", err),
        }
    }

    /// 新落秋/笔趣阁zdzn/天悦小说人工实网诊断：源站存在 IP 限频/WAF，不作为 CI 回归。
    #[test]
    #[ignore = "外部源站限频/WAF，手工诊断专用"]
    fn test_js_network_sources_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        for needle in ["新落秋", "天悦小说", "笔趣阁zdzn"] {
            let Some(src) = sources.iter().find(|s| {
                s.get("bookSourceName")
                    .and_then(|n| n.as_str())
                    .is_some_and(|n| n.contains(needle))
            }) else {
                continue;
            };
            let source =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
            let fetcher = crate::api::web_book::real_fetcher().unwrap();
            let results = crate::runtime::block_on(fetcher.search(&source, "一念", 1));
            match results {
                Ok(list) => eprintln!("[jsnet] {} -> {} 条", needle, list.len()),
                Err(err) => eprintln!(
                    "[jsnet] {} -> 失败: {}",
                    needle,
                    err.to_string().chars().take(120).collect::<String>()
                ),
            }
        }
    }

    /// java.connect StrResponse.raw().request().url() 实网诊断：趣书源站重定向不稳定。
    #[test]
    #[ignore = "外部源站重定向，离线契约由 legado-js bridge test 覆盖"]
    fn test_connect_str_response_search_url_no_undefined() {
        // JS 书源搜索诊断：JS 内 source./java. 绑定读写全局变量表
        // → 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let source = BookSource {
            book_source_url: "https://qubook.org".to_string(),
            book_source_name: "趣书".to_string(),
            search_url: Some(
                r#"@js:
burl = source.getKey();
url = burl + "/e/search/";
body = "show=title%2Cnewstext&keyboard=" + key;
$ = java.post(url + "index.php", body, {}).headers();
uri = $.Location || $.location;
url += String(uri).replace('?', 'index.php?page=0&');"#
                    .to_string(),
            ),
            ..BookSource::default()
        };
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(),
            "一念",
            1,
            &source.book_source_url,
            None,
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert!(
            !au.url().contains("undefined"),
            "趣书 URL 不应含 undefined: {}",
            au.url()
        );
        assert!(
            !au.url().starts_with("legado-js-error://"),
            "趣书 JS 不应失败: {}",
            au.url()
        );
    }

    /// 趣书网吧人工实网诊断：依赖 fixture 与外部重定向；离线 result 绑定契约见 parser 测试。
    #[test]
    #[ignore = "外部源站/fixture 诊断，非确定性 CI 测试"]
    fn test_qushu123_connect_search_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceUrl")
                .and_then(|v| v.as_str())
                .is_some_and(|u| u.contains("qushu123.com"))
        }) else {
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap_or(""),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        eprintln!("[qushu123] url={}", au.url());
        assert!(
            !au.url().contains("undefined"),
            "趣书 URL 不应含 undefined: {}",
            au.url()
        );
        assert!(
            !au.url().starts_with("legado-js-error://"),
            "趣书 JS 不应失败: {}",
            au.url()
        );
    }

    /// 天涯书库真实规则：source.key + java.post().header(location) 必须可构建搜索 URL。
    #[test]
    #[ignore = "外部重定向源诊断，离线 Response bridge 契约覆盖"]
    fn test_tianyashuku_search_url_diag() {
        // tmp_debug 夹具启用时执行 JS 书源搜索（入口 begin_book_flow，JS 绑定
        // 可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let raw = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        ))
        .unwrap();
        let serde_json::Value::Array(sources) =
            serde_json::from_str::<serde_json::Value>(&raw).unwrap()
        else {
            return;
        };
        let src = sources
            .iter()
            .find(|s| {
                s.get("bookSourceUrl")
                    .and_then(|v| v.as_str())
                    .is_some_and(|u| u.contains("tianyashuku.net"))
            })
            .unwrap();
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let au = crate::js_executor::build_search_url_with_setup(
            source.search_url.as_deref().unwrap(),
            "一念",
            1,
            &source.book_source_url,
            source.js_lib.as_deref(),
            crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
        );
        assert!(
            !au.url().contains("undefined"),
            "天涯 URL 不应含 undefined: {}",
            au.url()
        );
        assert!(
            !au.url().starts_with("legado-js-error://"),
            "天涯 JS 不应失败: {}",
            au.url()
        );
    }

    /// org.jsoup + java.post(connectNR) 回归：云霄/键盘/天涯书库 searchUrl @js
    #[test]
    #[ignore = "外部夹具 tmp_debug/e2e_5558/sources_device.json（仓库外，已于 2026-09-20 删除，无法复跑）+ 实网诊断（需真实登录/网络），非确定性 CI 测试"]
    #[cfg(feature = "quickjs")]
    fn test_jsoup_post_redirect_search_diag() {
        // P2-1：fixture 存在时 webbook_search 会执行 begin_book_flow（切
        // flow scope）→ 与其它 store 测试串行
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            panic!("夹具缺失: {path}（仓库外，已于 2026-09-20 删除）——请重新导出后再跑");
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let needles = ["云霄小说", "键盘小说", "天涯书库", "玄幻文学"];
        for needle in needles {
            let Some(src) = sources.iter().find(|s| {
                s.get("bookSourceName")
                    .and_then(|n| n.as_str())
                    .is_some_and(|n| n.contains(needle))
            }) else {
                eprintln!("[jsoup-diag] 未找到书源: {needle}");
                continue;
            };
            let source =
                serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
            let setup = crate::api::source_js_bindings::book_source_js_setup_script(&source).ok();
            let au = crate::js_executor::build_search_url_with_setup(
                source.search_url.as_deref().unwrap_or(""),
                "一念",
                1,
                &source.book_source_url,
                source.js_lib.as_deref(),
                setup,
            );
            eprintln!("[{needle}] URL: {}", au.url());
            assert!(
                !au.url().contains("@js:") && !au.url().contains("<js>"),
                "{needle} searchUrl JS 未渲染: {}",
                au.url()
            );
            assert!(
                !au.url().starts_with("legado-js-error://"),
                "{needle} JS 求值失败: {}",
                au.url()
            );
            assert!(
                !au.url().ends_with("/null") && !au.url().contains("/null?"),
                "{needle} Location 拦截失败落 /null: {}",
                au.url()
            );
            let fetcher = crate::api::web_book::real_fetcher().unwrap();
            match crate::runtime::block_on(fetcher.search(&source, "一念", 1)) {
                Ok(list) => eprintln!("[{needle}] search 结果数: {}", list.len()),
                Err(err) => eprintln!(
                    "[{needle}] search 失败: {}",
                    err.to_string().chars().take(160).collect::<String>()
                ),
            }
        }
    }

    /// 书书小说 allInOne `$1/$2` 目录回归（G8）
    // 依赖外部源站在线状态（2026-09-03 实测请求超时），与同文件其他外部源站
    // 诊断一致不入 CI 门禁，手工诊断时 --ignored 运行
    #[test]
    #[ignore = "外部源站网络诊断，非确定性 CI 测试"]
    fn test_shushu_all_in_one_toc_diag() {
        // P2-9 ③ / P1-2：入口 begin_book_flow 切 flow scope（只清旧 scope
        // 前缀，持久裸键不受影响），与 ③ 桥测试串行
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(serde_json::Value::Array(sources)) = serde_json::from_str::<serde_json::Value>(&raw)
        else {
            return;
        };
        let Some(src) = sources.iter().find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains("书书小说"))
        }) else {
            eprintln!("[shushu] 未找到书源");
            return;
        };
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        match webbook_search(&source_json, "斗破", 1) {
            Ok(s) => {
                let books: Vec<serde_json::Value> = serde_json::from_str(&s).unwrap_or_default();
                eprintln!("[shushu] 搜索 {} 条", books.len());
                if let Some(first) = books.first() {
                    eprintln!(
                        "[shushu] 首条 name={} url={}",
                        first.get("name").and_then(|v| v.as_str()).unwrap_or(""),
                        first.get("book_url").and_then(|v| v.as_str()).unwrap_or("")
                    );
                }
                assert!(
                    !books.is_empty(),
                    "书书小说搜索「斗破」应有列表结果，实际 {}",
                    books.len()
                );
            }
            Err(e) => panic!("书书搜索失败: {e}"),
        }
        // 目录/正文仍走已知 allInOne 书页（与搜索关键词无关）
        let book_url = String::from("http://www.shushun.cc/read_81/");
        let book_name = String::from("一念永恒");
        eprintln!("[shushu] 书={book_name} url={book_url}");
        let info = webbook_info(&source_json, &book_url).unwrap_or_default();
        let info: serde_json::Value = serde_json::from_str(&info).unwrap_or_default();
        let toc_url = info.get("toc_url").and_then(|v| v.as_str()).unwrap_or("");
        let chapters = webbook_chapters(&source_json, &book_url, toc_url, &book_name)
            .expect("书书小说目录应成功");
        let chapters: Vec<serde_json::Value> = serde_json::from_str(&chapters).unwrap();
        eprintln!("[shushu] 目录 {} 章", chapters.len());
        assert!(
            chapters.len() >= 2,
            "书书小说 allInOne $n 目录过少: {}",
            chapters.len()
        );
        let first_ch = chapters.first().unwrap();
        let title = first_ch.get("title").and_then(|v| v.as_str()).unwrap_or("");
        assert!(!title.is_empty() && title != "$2", "章名未回填: {title}");
        let ch_url = first_ch.get("url").and_then(|v| v.as_str()).unwrap_or("");
        assert!(
            !ch_url.is_empty() && !ch_url.contains("$1"),
            "章 URL 未回填: {ch_url}"
        );
        match webbook_content(&source_json, &first_ch.to_string()) {
            Ok(c) => eprintln!(
                "[shushu] 正文 {} 字 前80={}",
                c.chars().count(),
                c.chars().take(80).collect::<String>()
            ),
            Err(e) => eprintln!(
                "[shushu] 正文失败: {}",
                e.to_string().chars().take(160).collect::<String>()
            ),
        }
    }

    /// 红薯小说 JSONP 人工实网诊断：离线 @json 后缀和 JSON 占位符回归覆盖核心语义。
    #[test]
    #[ignore = "外部源站 JSONP 诊断，非确定性 CI 测试"]
    fn test_hongshu_jsonp_search_diag() {
        // P2-9 ③ / P1-2：入口 begin_book_flow 切 flow scope（只清旧 scope
        // 前缀，持久裸键不受影响），与 ③ 桥测试串行
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tmp_debug/e2e_5558/sources_device.json"
        );
        let raw = std::fs::read_to_string(path).unwrap();
        let serde_json::Value::Array(sources) =
            serde_json::from_str::<serde_json::Value>(&raw).unwrap()
        else {
            return;
        };
        let src = sources
            .iter()
            .find(|s| {
                s.get("bookSourceUrl").and_then(|v| v.as_str()) == Some("https://g.hongshu.com/")
            })
            .unwrap();
        let source =
            serde_json::from_str::<BookSource>(&serde_json::to_string(src).unwrap()).unwrap();
        let source_json = serde_json::to_string(&source).unwrap();
        let result = webbook_search(&source_json, "一念", 1);
        eprintln!(
            "[hongshu] result={:?}",
            result
                .as_ref()
                .map(|s| s.chars().take(500).collect::<String>())
        );
        assert!(result.is_ok(), "红薯搜索请求失败: {:?}", result.err());
    }

    use legado_core::models::rule::ContentRule;

    fn make_source_json() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_content: Some(ContentRule {
                content: Some("css(.content).html".to_string()),
                ..ContentRule::default()
            }),
            ..BookSource::default()
        })
        .unwrap()
    }

    /// P1-1 生产路径验证（**不依赖手工播种 meta 缓存**）：
    /// 用户书籍变量的唯一生产来源是 DB `books.variable`（Dart 书籍信息页
    /// 可编辑、持久化）。生产流程 webbook_info：详情解析 →
    /// `record_book_meta_from_info`（P1-1 起按 bookUrl 读 DB 补 variable，
    /// DB 无值/为空回退 `@put` 导出）→ 同 URL 下一次详情/目录/正文调用
    /// 命中 meta 缓存 → book 绑定 IIFE → `ruleBookInfo.init` 里
    /// `book.getVariable` 取到用户值（修复前生产上永远拿不到，init 按
    /// 变量分支的行为不可达，只能靠手工播种 meta 的测试才过）。
    ///
    /// 断言口径：同一 URL 连续两次生产详情路径，第二次 init 的
    /// `book.getVariable("custom")` 等于 DB 值；并覆盖「DB 无变量 →
    /// 回退 @put 导出」两分支（无此行 / 行存在但 variable 为空）。
    /// 本用例唯一播种是 **DB 行**（即生产数据源本身）；meta 缓存由生产
    /// 函数 `record_book_meta_from_info` 写入，variable 字段不经手工注入。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_book_variable_from_db_no_manual_seeding() {
        // 合成详情源 init 读 book.getVariable（DB 变量经全局变量表桥接）→
        // 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();

        // 合成详情源（与 test_p29 同构）：init 读 book.getVariable("custom")
        // 产出 JSON，name 规则从 init 产出取 $.n
        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://jhsu-dbv.example.com",
            "bookSourceName": "DB书籍变量测试源",
            "ruleBookInfo": {
                "init": "<js>JSON.stringify({n: 'v=' + book.getVariable('custom')})</js>",
                "name": "$.n"
            }
        }))
        .expect("source json");
        let body = "<html><body>raw detail body</body></html>".to_string();

        // ── 主分支：DB variable 覆盖 @put 导出（用户设置 > 源规则默认）
        let url_db = "https://jhsu-dbv.example.com/b/db-wins";
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, author, variable) VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![url_db, "DB优先测试书", "测试", r#"{"custom":"db-val"}"#],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入 books 行（带 variable）");

        // 第一次详情（生产路径）：meta 尚未记录 → 字面量绑定回退 →
        // init 的 getVariable 非函数被跳过 → name 空
        let info1 = parse_info(&source, body.clone(), url_db, url_db, true, "", "");
        assert!(
            info1.name.is_empty(),
            "第一次：meta 未记录，name 应为空，实际: {:?}",
            info1.name
        );
        // 生产记录函数（P1-1 起内部按 bookUrl 读 DB；info.variable 模拟
        // @put 导出，应被 DB 值覆盖）
        record_book_meta_from_info(
            url_db,
            &WebBookInfo {
                name: "DB优先测试书".into(),
                author: "测试".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_db.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"put-export"}"#.into()),
                book_type: 0,
            },
        );
        // 第二次详情（同 URL，生产路径）：meta 命中 → IIFE 绑定 →
        // init 的 getVariable("custom") = DB 值（而非 @put 导出值）
        let info2 = parse_info(&source, body.clone(), url_db, url_db, true, "", "");
        assert_eq!(
            info2.name, "v=db-val",
            "第二次：init 的 book.getVariable(\"custom\") 应等于 DB books.variable 值（DB 优先于 @put）"
        );

        // ── 回退分支 1：DB 无此书行 → 回退 @put 导出值
        let url_no = "https://jhsu-dbv.example.com/b/no-db";
        record_book_meta_from_info(
            url_no,
            &WebBookInfo {
                name: "回退测试书".into(),
                author: "测试".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_no.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"put-export"}"#.into()),
                book_type: 0,
            },
        );
        let info3 = parse_info(&source, body.clone(), url_no, url_no, true, "", "");
        assert_eq!(info3.name, "v=put-export", "DB 无行：回退 @put 导出值");

        // ── 回退分支 2：DB 行存在但 variable 为空 → 同样回退 @put 导出值
        let url_empty = "https://jhsu-dbv.example.com/b/empty-var";
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, author) VALUES (?1, ?2, ?3)",
                    rusqlite::params![url_empty, "空变量测试书", "测试"],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入 books 行（variable 为 NULL）");
        record_book_meta_from_info(
            url_empty,
            &WebBookInfo {
                name: "空变量测试书".into(),
                author: "测试".into(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: url_empty.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: Some(r#"{"custom":"put-export"}"#.into()),
                book_type: 0,
            },
        );
        let info4 = parse_info(&source, body, url_empty, url_empty, true, "", "");
        assert_eq!(
            info4.name, "v=put-export",
            "DB 行 variable 为空：回退 @put 导出值"
        );

        // 清理：共享内存库，删除本用例插入的行，防跨测试污染
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "DELETE FROM books WHERE bookUrl IN (?1, ?2, ?3)",
                    rusqlite::params![url_db, url_no, url_empty],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("清理本用例插入的 books 行");
    }

    #[test]
    #[ignore = "requires network access"]
    fn test_siluke_full_rules_next_toc() {
        // P2-9 ③ / P1-2：入口 begin_book_flow 切 flow scope（只清旧 scope
        // 前缀，持久裸键不受影响），与 ③ 桥测试串行
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        use std::time::Instant;
        let source_json = include_str!("../../tests/fixtures/siluke_rules.json");
        let book_url = "http://www.silukezw.com/135/135188/";
        let t0 = Instant::now();
        let _ = webbook_info(source_json, book_url);
        let t1 = Instant::now();
        let ch = webbook_chapters(source_json, book_url, "", "").expect("chapters");
        let arr: Vec<serde_json::Value> = serde_json::from_str(&ch).unwrap();
        eprintln!(
            "[timing-full] chapters={} toc={:?} total={:?}",
            arr.len(),
            t1.elapsed(),
            t0.elapsed()
        );
        // 思路客分页：首页约100，全量应明显更多（若 nextTocUrl 生效）
        assert!(arr.len() >= 100, "got {}", arr.len());
    }

    #[test]
    #[ignore = "requires network access"]
    fn test_siluke_book_info_chapters_timing_and_cache() {
        // P2-9 ③ / P1-2：入口 begin_book_flow 切 flow scope（只清旧 scope
        // 前缀，持久裸键不受影响），与 ③ 桥测试串行
        let _global_store_lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        use std::time::Instant;
        let source = serde_json::json!({
            "bookSourceUrl": "http://www.silukezw.com",
            "bookSourceName": "思路客#2",
            "bookSourceType": 0,
            "ruleBookInfo": {
                "name": "[property=\"og:title\"]@content",
                "author": "meta[property=\"og:novel:author\"]@content",
                "intro": "#intro@text",
                "coverUrl": "meta[property=\"og:image\"]@content",
                "tocUrl": "",
                "lastChapter": "meta[property=\"og:novel:latest_chapter_name\"]@content"
            },
            "ruleToc": {
                "chapterList": ".book_list2 li a",
                "chapterName": "text",
                "chapterUrl": "href"
            }
        });
        let source_json = source.to_string();
        let book_url = "http://www.silukezw.com/135/135188/";

        let t0 = Instant::now();
        let info = webbook_info(&source_json, book_url);
        let info_ms = t0.elapsed();
        assert!(info.is_ok(), "info err: {:?}", info.err());
        eprintln!("[timing] webbook_info {:?}", info_ms);

        let t1 = Instant::now();
        let ch = webbook_chapters(&source_json, book_url, "", "");
        let ch_ms = t1.elapsed();
        match &ch {
            Ok(s) => {
                let arr: Vec<serde_json::Value> = serde_json::from_str(s).unwrap_or_default();
                eprintln!(
                    "[timing] webbook_chapters {} chapters in {:?} (after info)",
                    arr.len(),
                    ch_ms
                );
                assert!(arr.len() > 20, "思路客首页应有多章，实际 {}", arr.len());
            }
            Err(e) => panic!("chapters err: {e}"),
        }
        eprintln!("[timing] sequential total {:?}", t0.elapsed());
        // 目录阶段应命中详情页短时缓存；解析复用 AnalyzeRule 后通常远快于二次 HTTP
        assert!(
            ch_ms < info_ms + std::time::Duration::from_secs(8),
            "chapters after info unexpectedly slow: info={info_ms:?} chapters={ch_ms:?}"
        );
    }

    #[test]
    fn test_webbook_search_invalid_source_json() {
        let err = webbook_search("not valid json", "关键词", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_info_invalid_source_json() {
        let err = webbook_info("invalid", "https://example.com/book/1").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_chapters_invalid_source_json() {
        let err = webbook_chapters("bad json", "https://example.com/book/1", "", "").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_content_invalid_chapter_json() {
        let err = webbook_content(&make_source_json(), "not json").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_build_engine_creates_real_fetcher() {
        // 验证 build_engine 能正常构建（不 panic）
        let _engine = build_engine().expect("build_engine");
    }

    #[test]
    fn test_real_fetcher_constructs() {
        // 验证 ffi 包装层可构造真实 fetcher（共享客户端 + 全量注入）
        let _fetcher = real_fetcher().expect("real fetcher");
    }

    #[test]
    fn test_webbook_search_empty_query_returns_error() {
        // P2-1：webbook_search 在空关键词校验前已执行 begin_book_flow
        // （切 flow scope，清旧前缀）→ 触碰全局 store 状态，须与其它
        // store 测试串行；结尾复位 flow scope 防污染后续测试
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        variable_store::clear_flow_scope().expect("复位 flow scope");
        // 空关键词应返回解析错误（engine 层校验）
        let err = webbook_search(&make_source_json(), "", 1).unwrap_err();
        assert!(err.to_string().contains("搜索关键词不能为空"));
        variable_store::clear_flow_scope().expect("复位 flow scope");
    }

    #[test]
    fn test_webbook_content_empty_chapter_url_returns_error() {
        // webbook_content 入口无条件 ensure_global_variable_bridge（注册全局
        // 读取器）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let chapter_json = serde_json::to_string(&WebChapter::new(0, "第一章", "")).unwrap();
        let err = webbook_content(&make_source_json(), &chapter_json).unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }

    /// 网络冒烟：伪七猫 play 页 @js 抽出 m3u8（验证 VIDEO 正文不被污染）
    #[test]
    #[ignore = "network smoke: qmao video content"]
    fn qmao_video_content_smoke() {
        // 走 webbook_content（book./java. 绑定 + 全局变量桥）→ 持 crate 级
        // test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let json = include_str!("../../tests/fixtures/qmao_min_source.json");
        let source: BookSource = serde_json::from_str(json).expect("source json");
        assert_eq!(source.book_source_type, book_source_type::VIDEO);

        let chapter = WebChapter {
            index: 0,
            title: "第1集".into(),
            url: "https://www.qmao.net/vodplay/27017-1-1.html".into(),
            is_vip: false,
            is_volume: false,
            variable: None,
            word_count: None,
        };
        let content = webbook_content(json, &serde_json::to_string(&chapter).unwrap())
            .expect("webbook_content");
        eprintln!(
            "qmao content len={} head={}",
            content.len(),
            &content[..content.len().min(180)]
        );
        let first = content.lines().next().unwrap_or("").trim();
        assert!(
            first.contains(".m3u8") || first.contains(".mp4"),
            "expected media url first line, got: {content}"
        );
        assert!(
            !content.contains("player_aaaa"),
            "raw html must not leak into play content"
        );
    }

    // ─── [P2-12] 换源书重进详情/目录刷新变量链回归（2026-09-18） ─────────────

    /// [P2-12] 脚本化详情/目录 fetcher：捕获调用方传入的变量表，并按真实
    /// 请求构造（`AnalyzeUrl::parse`，`{{key}}` 简单名直接经变量表解析，
    /// 见 `replace_inner_expressions`）展开请求模板、记录最终请求 URL——
    /// 用于断言「DB books.variable 流入了请求」（修复前变量表恒空 →
    /// `?vid=` 空值 → 服务端 400 的回归点）
    struct P12VarFetcher {
        vars_received:
            std::sync::Arc<std::sync::Mutex<Vec<std::collections::HashMap<String, String>>>>,
        detail_urls: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
        toc_urls: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    }

    impl BookSourceFetcher for P12VarFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<WebBookInfo> {
            Err(LegadoError::Internal("mock: get_book_info unused".into()))
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            Err(LegadoError::Internal("mock: get_chapters unused".into()))
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }

        /// 详情变量表路径：仿真实请求构造——bookUrl 模板经变量表展开
        async fn get_book_info_with_existing_and_vars(
            &self,
            _source: &BookSource,
            book_url: &str,
            _can_re_name: bool,
            _existing_name: &str,
            _existing_author: &str,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<WebBookInfo> {
            self.vars_received
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            let req = AnalyzeUrl::parse(book_url, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("详情 URL 解析失败: {e}")))?;
            self.detail_urls
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(req.url().to_string());
            Ok(WebBookInfo {
                name: "R1换源验证书".to_string(),
                author: "测试".to_string(),
                cover_url: None,
                intro: None,
                categories: Vec::new(),
                last_chapter: None,
                book_url: book_url.to_string(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                variable: None,
                book_type: 0,
            })
        }

        /// 目录变量表路径：已知目录页（或回退详情 URL）模板经变量表展开
        async fn get_chapters_with_hints_and_vars(
            &self,
            _source: &BookSource,
            book_url: &str,
            known_toc_url: Option<&str>,
            _book_name_hint: Option<&str>,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.vars_received
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            let template = known_toc_url.unwrap_or(book_url);
            let req = AnalyzeUrl::parse(template, variables, 1)
                .map_err(|e| LegadoError::Internal(format!("目录 URL 解析失败: {e}")))?;
            self.toc_urls
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(req.url().to_string());
            Ok(vec![WebChapter {
                index: 0,
                title: "第一章".to_string(),
                url: format!("{}/c1", req.url()),
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            }])
        }
    }

    /// [P2-12] 换源书「回书架 → 重进详情/刷新目录」：请求模板必须用 DB
    /// `books.variable` 展开（回归：修复前重进/U7 路径变量表恒空 →
    /// `{{svid}}`/`{{tok}}` 展开为空 → mock 服务端对 `?vid=`/`?tok=` 400，
    /// 而换源主链（候选 ⊕ 详情导出）正确）
    ///
    /// 唯一播种点是 **DB 行**（生产数据源本身）：播种换源后书籍行
    /// （bookUrl = 旧源稳定主键、originBookUrl = 新源取址点、variable =
    /// 候选 ⊕ 详情导出合并持久值），请求链路的变量表不经手工注入——全部
    /// 来自 `db_book_variable` 两路查找（bookUrl → originBookUrl）的回读。
    #[test]
    fn test_p212_reenter_detail_expands_db_variables() {
        use std::sync::{Arc, Mutex};

        let _db_guard = crate::db_state::ensure_test_db();

        let old_book_url = "https://old-src.example.com/r1vb/detail?vid={{svid}}";
        let fetch_url = "https://r1vb.local/r1vb/detail?vid={{svid}}"; // originBookUrl（Dart 取址点）
        let toc_template = "https://r1vb.local/r1vb/toc?tok={{tok}}";
        let var_json = r#"{"svid":"VID123","tok":"TK777"}"#;

        // 播种换源后书籍行（唯一播种点；originBookUrl 非空 = 已换源）
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, originBookUrl, tocUrl, variable)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    rusqlite::params![
                        old_book_url,
                        "R1换源验证书",
                        fetch_url,
                        toc_template,
                        var_json
                    ],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入换源书籍行");

        // 两路反查：取址点（originBookUrl）命中 + 稳定主键（bookUrl）命中
        assert_eq!(
            db_book_variable(fetch_url).as_deref(),
            Some(var_json),
            "换源书按取址点（originBookUrl）须命中 books.variable"
        );
        assert_eq!(
            db_book_variable(old_book_url).as_deref(),
            Some(var_json),
            "稳定主键（bookUrl）亦须命中 books.variable"
        );

        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://r1vb.local",
            "bookSourceName": "P12变量链测试源",
        }))
        .expect("source json");

        let vars_received = Arc::new(Mutex::new(Vec::new()));
        let detail_urls = Arc::new(Mutex::new(Vec::new()));
        let toc_urls = Arc::new(Mutex::new(Vec::new()));
        let fetcher = P12VarFetcher {
            vars_received: Arc::clone(&vars_received),
            detail_urls: Arc::clone(&detail_urls),
            toc_urls: Arc::clone(&toc_urls),
        };

        // ① 重进详情（U7 取址点 = originBookUrl）：变量表来自 DB 回读
        let info = runtime::block_on(webbook_info_with_fetcher(&source, fetch_url, &fetcher))
            .expect("重进详情应成功");
        assert_eq!(info.name, "R1换源验证书");

        let detail = detail_urls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(
            detail,
            vec!["https://r1vb.local/r1vb/detail?vid=VID123".to_string()],
            "详情请求模板应按 DB 变量展开（修复前回归：?vid= 为空）"
        );
        let vars = vars_received
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(vars.len(), 1, "详情请求应恰好传入一次变量表");
        assert_eq!(
            vars[0].get("svid").map(String::as_str),
            Some("VID123"),
            "svid 应自 DB books.variable 回读（请求链无手工注入）"
        );
        assert_eq!(vars[0].get("tok").map(String::as_str), Some("TK777"));

        // ② 重拉目录（已知目录页模板含 {{tok}}）
        let chapters = runtime::block_on(webbook_chapters_with_fetcher(
            &source,
            fetch_url,
            Some(toc_template),
            Some("R1换源验证书"),
            &fetcher,
        ))
        .expect("目录抓取应成功");
        assert_eq!(chapters.len(), 1, "mock 目录应解析 1 章");

        let toc = toc_urls.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(
            toc,
            vec!["https://r1vb.local/r1vb/toc?tok=TK777".to_string()],
            "目录请求模板应按 DB 变量展开（修复前回归：?tok= 为空）"
        );

        // 清理：共享内存库，删除本用例插入的行，防跨测试污染
        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "DELETE FROM books WHERE bookUrl = ?1",
                    rusqlite::params![old_book_url],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("清理本用例插入的 books 行");
    }

    /// [P2-12] 未换源书：取址点即 bookUrl（`find_by_url` 直接命中），
    /// 变量表同样来自 DB `books.variable` 回读（bookUrl 模板含 `{{key}}`
    /// 的存量书籍：重进详情/目录刷新须携 DB 变量，行为与换源书一致）
    #[test]
    fn test_p212_unswitched_book_route_hits_by_book_url() {
        use std::sync::{Arc, Mutex};

        let _db_guard = crate::db_state::ensure_test_db();

        let book_url = "https://plain.example.com/d/42?sid={{sid}}";
        let var_json = r#"{"sid":"S999"}"#;

        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "INSERT INTO books (bookUrl, name, variable) VALUES (?1, ?2, ?3)",
                    rusqlite::params![book_url, "未换源变量书", var_json],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("插入未换源书籍行");

        // bookUrl 路命中（originBookUrl 为空的存量书）
        assert_eq!(db_book_variable(book_url).as_deref(), Some(var_json));

        let source: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://plain.example.com",
            "bookSourceName": "P12未换源测试源",
        }))
        .expect("source json");

        let detail_urls = Arc::new(Mutex::new(Vec::new()));
        let fetcher = P12VarFetcher {
            vars_received: Arc::new(Mutex::new(Vec::new())),
            detail_urls: Arc::clone(&detail_urls),
            toc_urls: Arc::new(Mutex::new(Vec::new())),
        };
        let info = runtime::block_on(webbook_info_with_fetcher(&source, book_url, &fetcher))
            .expect("未换源书重进详情应成功");
        assert_eq!(info.name, "R1换源验证书", "mock 固定返回，仅验证链路打通");

        let detail = detail_urls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(
            detail,
            vec!["https://plain.example.com/d/42?sid=S999".to_string()],
            "未换源书详情模板应经 find_by_url 路命中 DB 变量展开"
        );

        crate::db_state::with_database(|db| {
            db.connection()
                .execute(
                    "DELETE FROM books WHERE bookUrl = ?1",
                    rusqlite::params![book_url],
                )
                .map_err(|e| LegadoError::Database(e.to_string()))
        })
        .expect("清理本用例插入的 books 行");
    }

    // ─── P2-19 分裂点修复（2026-09-23 上游同步后改写）：FFI HTTP 取数路径
    // Cookie 查找口径统一为「请求 URL 属域」────────────────────────────────
    //
    // 上游同步（用户裁决）后：JS 写 cookie 的键归一为 `getSubDomain(url)` 等价
    // 域名键，读侧（FFI `fetch_page` 兜底 / JS `java.ajax`）统一按**请求 URL**
    // 属域取（`cookie_store::cookies_for_url`），cookie 属于域名而非书源；
    // 不相关域名的 cookie 绝不携带（P2-19 核心不变式保留）。注入点从
    // `parse_source_headers`（书源维度）下沉到 `fetch_page`（请求 URL 维度）。
    // 本组用例按新口径钉死（改前 ① 的「parse_source_headers 不再注入」断言与
    // 同域共享断言应红，改造后全绿）。

    /// 分裂点修复（①，上游同步改写）：FFI HTTP 路径按**请求 URL 属域**携带
    /// ETLD+1 域名键 cookie；注入点已从 `parse_source_headers` 下沉到
    /// `fetch_page`（按 `cookies_for_url(request_url)` 兜底）。断言分两层：
    /// a) `parse_source_headers` 不再注入 JS Cookie（行为变化，改前红）；
    /// b) `cookies_for_url`（fetch_page 兜底的取数层）命中域名键写入形态的
    ///    cookie（含历史原始串键兼容）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_ffi_http_path_carries_domain_key_cookie() {
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        use legado_js::host_api::cookie_store;
        const TAG: &str = "https://www.p219ffd.example.com/search";
        // ETLD+1：host www.p219ffd.example.com 的可注册域为 example.com
        // （末两段），而非 www.p219ffd.example.com
        const DOMAIN_KEY: &str = "example.com";
        cookie_store::clear_cookies(TAG);
        cookie_store::clear_cookies(DOMAIN_KEY);
        // 域名键写入形态（非 URL 串自键 = 历史原始串键；读侧归一键 + 原始串键
        // 双命中，兼容无迁移负担）
        cookie_store::set_cookie(DOMAIN_KEY, "p219_ffi_dk", "dk-val-ffi");
        let source = BookSource {
            book_source_url: TAG.to_string(),
            ..Default::default()
        };
        // a) 注入点已下沉：parse_source_headers 不再注入 JS Cookie
        let headers = parse_source_headers(&source);
        let cookie = headers.as_ref().and_then(|h| h.get("Cookie").cloned());
        assert!(
            cookie.as_deref().unwrap_or("").is_empty(),
            "JS Cookie 注入已下沉 fetch_page（按请求 URL 属域兜底），parse_source_headers 不得再注入: {cookie:?}"
        );
        // b) fetch_page 兜底取数层（cookies_for_url）：该域请求必须命中域名键 cookie
        let carried = cookie_store::cookies_for_url(TAG);
        assert!(
            carried.contains("p219_ffi_dk=dk-val-ffi"),
            "FFI HTTP 路径（fetch_page 兜底）必须携带 ETLD+1 域名键 cookie（分裂点修复 + 原始串键兼容），实际: {carried}"
        );
        cookie_store::clear_cookies(TAG);
        cookie_store::clear_cookies(DOMAIN_KEY);
    }

    /// 异域不泄漏（②，原「跨源不泄漏」用例按上游语义改写，2026-09-23 用户裁决
    /// 同步上游：cookie 属于域名，不再属于书源）：A 域写入的 cookie 绝不得
    /// 出现在 B **域**的请求中。旧用例的 TAG_A/TAG_B（example.com 同域两子域）
    /// 在新语义下属**同域共享**（不再泄漏），故异域对改用不同可注册域
    ///（leak-src-a.example.com vs leak-src-b.other-site.net）。
    /// 双档用例（无 quickjs 门控）：异域不携带不变式在两档均成立——默认档
    /// 归一为原始串自键（无 ETLD+1），跨域同样不命中；同域共享部分依赖
    /// ETLD+1，见下方 quickjs 门控用例。
    #[test]
    fn test_p219_ffi_cross_domain_no_leak() {
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        use legado_js::host_api::cookie_store;
        const TAG_A: &str = "https://p219ffa-a.leak-src-a.example.com/";
        const TAG_B: &str = "https://p219ffb-b.leak-src-b.other-site.net/";
        cookie_store::clear_cookies(TAG_A);
        cookie_store::clear_cookies(TAG_B);
        cookie_store::set_cookie(TAG_A, "p219_ffi_a", "A-VAL-ffi");
        // B 域请求（fetch_page 兜底取数层）不得携带 A 域 cookie
        let carried = cookie_store::cookies_for_url(TAG_B);
        assert!(
            !carried.contains("p219_ffi_a"),
            "不相关域名的 cookie 绝不携带（P2-19 不变式），B 域请求实际: {carried}"
        );
        // fetch_page 注入层同口径（parse_source_headers 已不再注入 JS Cookie）
        let source_b = BookSource {
            book_source_url: TAG_B.to_string(),
            ..Default::default()
        };
        let headers = parse_source_headers(&source_b);
        let cookie = headers
            .as_ref()
            .and_then(|h| h.get("Cookie").cloned())
            .unwrap_or_default();
        assert!(
            !cookie.contains("p219_ffi_a"),
            "B 域书源请求头不得携带 A 域 cookie: {cookie}"
        );
        cookie_store::clear_cookies(TAG_A);
        cookie_store::clear_cookies(TAG_B);
    }

    /// 同域跨书源共享（②'，上游语义新增正例，quickjs 档依赖 ETLD+1）：
    /// 同一可注册域（example.com）下两个不同书源（不同子域），A 写的 cookie
    /// B 域请求必须携带（cookie 属于域名，跨书源共享）。依据：2026-09-23
    /// 用户裁决同步上游 `CookieManager.loadRequest`（按请求 URL 属域取）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_ffi_same_domain_cross_source_shared() {
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        use legado_js::host_api::cookie_store;
        // 两书源子域同属 example.com（ETLD+1 末两段）
        const TAG_A: &str = "https://a.p219share.example.com/";
        const TAG_B: &str = "https://b.p219share.example.com/";
        cookie_store::clear_cookies(TAG_A);
        cookie_store::clear_cookies(TAG_B);
        cookie_store::clear_cookies("p219share.example.com");
        cookie_store::set_cookie(TAG_A, "p219_ffi_share", "SH-VAL-ffi");
        let carried = cookie_store::cookies_for_url(TAG_B);
        assert!(
            carried.contains("p219_ffi_share=SH-VAL-ffi"),
            "同域跨书源必须共享 cookie（上游语义：cookie 属于域名），B 域请求实际: {carried}"
        );
        cookie_store::clear_cookies(TAG_A);
        cookie_store::clear_cookies(TAG_B);
        cookie_store::clear_cookies("p219share.example.com");
    }

    /// 多段 TLD / IP 字面量键一致（③，上游同步改写）：FFI HTTP 路径（fetch_page
    /// 兜底取数层）与 HTTP 层同一套键规则（单一真源 `domain_key_from_host`）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_ffi_multi_tld_and_ip_key_consistency() {
        let _lock = GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        use legado_js::host_api::cookie_store;
        // .com.cn 多段 TLD：域名键取末三段（ETLD+1 = book.com.cn）
        const TAG_CN: &str = "https://a.b.book.com.cn/search";
        const DK_CN: &str = "book.com.cn";
        cookie_store::clear_cookies(TAG_CN);
        cookie_store::clear_cookies(DK_CN);
        // 域名键写入形态（原始串自键）；读侧按请求 URL 归一域名键命中
        cookie_store::set_cookie(DK_CN, "p219_cn", "cn-val");
        let cookie_cn = cookie_store::cookies_for_url(TAG_CN);
        assert!(
            cookie_cn.contains("p219_cn=cn-val"),
            ".com.cn 域名键 cookie 必须携带: {cookie_cn}"
        );
        cookie_store::clear_cookies(TAG_CN);
        cookie_store::clear_cookies(DK_CN);
        // IP 字面量（含 :port）：域名键为 IP 自身
        const TAG_IP: &str = "http://192.168.77.9:8080/api";
        const DK_IP: &str = "192.168.77.9";
        cookie_store::clear_cookies(TAG_IP);
        cookie_store::clear_cookies(DK_IP);
        cookie_store::set_cookie(DK_IP, "p219_ip", "ip-val");
        let cookie_ip = cookie_store::cookies_for_url(TAG_IP);
        assert!(
            cookie_ip.contains("p219_ip=ip-val"),
            "IP 字面量键 cookie 必须携带: {cookie_ip}"
        );
        cookie_store::clear_cookies(TAG_IP);
        cookie_store::clear_cookies(DK_IP);
    }

    /// P2-9 源级验证（补后，离线）：真实 🎬艾格动漫 书源
    /// （q9.db book_sources 逐字 JSON，fixture `aigei_agedm_source.json`）
    ///
    /// **项①命中源**：`ruleBookInfo.intro` 3 处 `java.getStringList(...)`
    /// + `source.getVariable()`。补后 java 面已有 getStringList → intro
    ///   得到线路/集数列表；补前（HEAD，`git grep getStringList HEAD --
    /// rust/legado-js` 零命中）同一 JS 抛错、列表缺失 —— HEAD 侧原始
    ///   输出由 worktree 探针 p29_head_probe 捕获
    // （.tmp/p29_head_probe_out.log）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p29_real_aigei_source_getstringlist() {
        // 真实书源 JS（java.getStringList 等绑定读写全局变量表）→ 持 crate
        // 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let source: BookSource =
            serde_json::from_str(include_str!("../../tests/fixtures/aigei_agedm_source.json"))
                .expect("艾格动漫书源 JSON（q9.db 逐字）");
        // 离线 fixture 详情页响应体：.nav-pills 线路列表 + 各线路
        // `id.xxx` 面板（供 getStringList 的 CSS 选择器）
        let body = "<html><head><title>测试动漫</title></head><body><div class=\"video_detail_desc\">一部悬疑与幽默并存的经典动画，剧情精彩。</div><ul class=\"nav nav-pills\"><li class=\"nav-item\"><a class=\"nav-link active\" data-bs-target=\"#line_a\">线路A</a></li><li class=\"nav-item\"><a class=\"nav-link\" data-bs-target=\"#line_b\">线路B</a></li></ul><div id=\"line_a\"><ul><li><a>第1集</a></li><li><a>第2集</a></li><li><a>第3集</a></li></ul></div><div id=\"line_b\"><ul><li><a>B线第1集</a></li></ul></div></body></html>";
        let info = parse_info(
            &source,
            body.to_string(),
            "https://www.agedm.org/detail/9",
            "https://www.agedm.org/detail/9",
            true,
            "",
            "",
        );
        let intro = info.intro.clone().unwrap_or_default();
        assert!(
            intro.contains("可以修改源变量查看不同线路，当前：1"),
            "补后：intro 应含源变量提示（source.getVariable 空 → 回退 1），实际: {intro}"
        );
        assert!(
            intro.contains("源名称：线路A，源变量：1，共：3集"),
            "补后：java.getStringList 应取到线路A 3 集，实际: {intro}"
        );
        assert!(
            intro.contains("源名称：线路B，源变量：2，共：1集"),
            "补后：java.getStringList 应取到线路B 1 集，实际: {intro}"
        );
        assert!(
            intro.contains("一部悬疑与幽默并存的经典动画"),
            "补后：多行规则末行 `str+result` 应追加 CSS 段（.video_detail_desc@text），实际: {intro}"
        );
    }
}
