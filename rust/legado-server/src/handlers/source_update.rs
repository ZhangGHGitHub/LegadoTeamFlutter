//! 书源在线更新处理器
//!
//! 提供书源仓库管理与在线更新能力：
//! - GET /api/sources/repos — 获取书源仓库列表
//! - GET /api/sources/updates — 检查书源更新
//! - POST /api/sources/update — 执行更新

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use legado_core::models::BookSource;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;

use legado_db::repository::book_source_repository::BookSourceRepository;
use legado_db::repository::Repository;

use crate::error::ApiError;
use crate::state::AppState;

/// 书源仓库信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceRepo {
    /// 仓库名称
    pub name: String,
    /// 仓库 URL（指向书源 JSON 文件）
    pub url: String,
    /// 仓库描述
    pub description: String,
}

/// 默认书源仓库列表
fn default_repos() -> Vec<SourceRepo> {
    vec![
        SourceRepo {
            name: "Legado 官方书源".to_string(),
            url: "https://raw.githubusercontent.com/gedoor/legado/master/app/src/main/assets/defaultData/bookSource.json".to_string(),
            description: "Legado 官方默认书源集合".to_string(),
        },
        SourceRepo {
            name: "网络精品书源".to_string(),
            url: "https://cdn.jsdelivr.net/gh/XIU2/Yuedu@master/bookSource.json".to_string(),
            description: "社区维护的精品书源合集".to_string(),
        },
    ]
}

/// 书源更新信息
#[derive(Debug, Clone, Serialize)]
pub struct SourceUpdateInfo {
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 本地最后更新时间
    pub local_update_time: i64,
    /// 远程最后更新时间
    pub remote_update_time: i64,
    /// 是否需要更新
    pub need_update: bool,
}

/// 更新检查结果
#[derive(Debug, Serialize)]
pub struct UpdateCheckResult {
    /// 仓库名称
    pub repo_name: String,
    /// 仓库 URL
    pub repo_url: String,
    /// 远程书源总数
    pub remote_total: usize,
    /// 需要更新的书源列表
    pub updates: Vec<SourceUpdateInfo>,
    /// 新增书源数（本地不存在）
    pub new_count: usize,
    /// 检查是否成功
    pub success: bool,
    /// 错误信息
    pub error: Option<String>,
}

/// 执行更新请求体
#[derive(Debug, Deserialize)]
pub struct UpdateRequest {
    /// 仓库 URL（从哪个仓库更新）
    pub repo_url: String,
    /// 是否仅更新已有书源（false 则同时导入新书源）
    #[serde(default)]
    pub only_update_existing: bool,
}

/// 更新执行结果
#[derive(Debug, Serialize)]
pub struct UpdateResult {
    /// 更新成功的书源数
    pub updated: usize,
    /// 新增的书源数
    pub added: usize,
    /// 跳过的书源数
    pub skipped: usize,
    /// 失败的书源数
    pub failed: usize,
    /// 错误信息列表
    pub errors: Vec<String>,
}

/// GET /api/sources/repos — 获取书源仓库列表
pub async fn list_repos() -> Json<Value> {
    let repos = default_repos();
    Json(json!({ "repos": repos, "total": repos.len() }))
}

/// 测试专用：`check_updates` 使用的仓库列表覆盖（离线化外部抓取）
///
/// 生产行为不变：未设置覆盖时 [`active_repos`] 返回 [`default_repos`]。
/// 测试经 [`set_test_repos`] 注入本地回环仓库（Drop 守卫自动还原，
/// panic 亦不泄漏到并行用例），把原本对 raw.githubusercontent.com /
/// cdn.jsdelivr.net 的真联网检查变成确定性回环检查。
#[cfg(test)]
static TEST_REPOS_OVERRIDE: std::sync::Mutex<Option<Vec<SourceRepo>>> = std::sync::Mutex::new(None);

/// 测试专用守卫：离开作用域（含 panic）自动还原仓库覆盖
#[cfg(test)]
struct TestReposGuard;

#[cfg(test)]
impl Drop for TestReposGuard {
    fn drop(&mut self) {
        *TEST_REPOS_OVERRIDE.lock().unwrap() = None;
    }
}

/// 测试专用：覆盖 `check_updates` 使用的仓库列表，返回 Drop 守卫
#[cfg(test)]
fn set_test_repos(repos: Vec<SourceRepo>) -> TestReposGuard {
    *TEST_REPOS_OVERRIDE.lock().unwrap() = Some(repos);
    TestReposGuard
}

/// `check_updates` 使用的仓库列表：测试覆盖优先，生产恒为默认仓库
fn active_repos() -> Vec<SourceRepo> {
    #[cfg(test)]
    if let Some(repos) = TEST_REPOS_OVERRIDE.lock().unwrap().clone() {
        return repos;
    }
    default_repos()
}

/// 仓库 URL 是否指向本地回环（127.0.0.1 / localhost，测试注入的本地 mock）
fn is_loopback_repo_url(url: &str) -> bool {
    url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost")
}

/// GET /api/sources/updates — 检查书源更新
///
/// 从所有仓库获取远程书源列表，与本地对比，返回需要更新的书源。
pub async fn check_updates(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let repos = active_repos();
    // 回环仓库（本地测试服务）不经系统/环境变量代理路由：reqwest 默认客户端
    // 在 HTTP_PROXY 存在时连 127.0.0.1 也走代理，死代理环境下回环流量会被
    // 劫持（P2-17 约定 cda70a0c54）。真实仓库集合沿用默认客户端，生产行为不变。
    let builder = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .danger_accept_invalid_certs(true)
        .dns_resolver(legado_net::custom_hosts::resolver());
    let client = (if repos.iter().all(|r| is_loopback_repo_url(&r.url)) {
        builder.no_proxy()
    } else {
        builder
    })
    .build()
    .map_err(|e| legado_core::LegadoError::Network(format!("创建 HTTP 客户端失败: {e}")))?;

    // 获取本地书源列表
    let local_sources = {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        repo.find_all()?
    };

    let mut results: Vec<UpdateCheckResult> = Vec::new();

    for repo_info in &repos {
        let result = check_repo_updates(&client, repo_info, &local_sources).await;
        results.push(result);
    }

    let total_updates: usize = results.iter().map(|r| r.updates.len()).sum();
    let total_new: usize = results.iter().map(|r| r.new_count).sum();

    Ok(Json(json!({
        "results": results,
        "total_updates": total_updates,
        "total_new": total_new,
    })))
}

/// POST /api/sources/update — 执行更新
///
/// 从指定仓库下载书源并合并到本地数据库。
pub async fn execute_update(
    State(state): State<Arc<AppState>>,
    Json(req): Json<UpdateRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .danger_accept_invalid_certs(true)
        .dns_resolver(legado_net::custom_hosts::resolver())
        .build()
        .map_err(|e| legado_core::LegadoError::Network(format!("创建 HTTP 客户端失败: {e}")))?;

    // 下载远程书源
    let response = client
        .get(&req.repo_url)
        .send()
        .await
        .map_err(|e| legado_core::LegadoError::Network(format!("请求仓库失败: {e}")))?;

    if !response.status().is_success() {
        return Err(ApiError(legado_core::LegadoError::Network(format!(
            "仓库请求失败，状态码: {}",
            response.status()
        ))));
    }

    let body = response
        .text()
        .await
        .map_err(|e| legado_core::LegadoError::Network(format!("读取响应失败: {e}")))?;

    // 解析远程书源 JSON（审查批1 P0-1）：改走与 FFI `import_sources` 同一
    // serde 主链（`BookSource` 模型 lenient 反序列化，规则嵌套对象与
    // `variable` 全量透传），不再经 `RoomImporter::import_book_sources`——
    // 其按 Room 导出格式把规则字段当字符串读取（`as_str`），标准书源仓库
    // JSON 的嵌套对象规则必得 None 落 NULL，且 INSERT 列集不含 `variable`
    // （REPLACE 清空登录态）。证据：docs/REFACTORING_FULL_AUDIT_REPORT_20261026.md
    // §一 P0-1。形态不符在此显式报错（防复发规定 4），整批拒绝而非静默丢字段。
    let remote_sources: Vec<BookSource> = serde_json::from_str(&body)
        .map_err(|e| legado_core::LegadoError::Internal(format!("解析书源 JSON 失败: {e}")))?;

    // 获取本地书源 URL 集合
    let local_urls: std::collections::HashSet<String> = {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        let sources = repo.find_all()?;
        sources.into_iter().map(|s| s.book_source_url).collect()
    };

    let mut updated = 0usize;
    let mut added = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;
    let mut errors: Vec<String> = Vec::new();

    // 筛选需要导入的书源
    let sources_to_import: Vec<BookSource> = remote_sources
        .iter()
        .filter(|item| {
            if item.book_source_url.is_empty() {
                skipped += 1;
                return false;
            }
            let exists = local_urls.contains(&item.book_source_url);
            if exists {
                true // 更新已有
            } else if req.only_update_existing {
                skipped += 1;
                false // 跳过新增
            } else {
                true // 导入新增
            }
        })
        .cloned()
        .collect();

    if !sources_to_import.is_empty() {
        let db = state.db.lock().await;
        // 落库与 FFI import_sources 共用同一批量方法：`insert_batch` 单事务
        // 原子写入，底层 `Repository::insert` 为 INSERT OR REPLACE 全列
        // upsert——**以导入为准覆盖**（含 `variable`），与 FFI 主路径、原版
        // Room REPLACE 语义一致；任一条失败整批回滚，调用方看到 Err 时库内
        // 零改动。不新增旁路写实现（防复发规定 1：单实现原则）。
        match BookSourceRepository::new(db.connection()).insert_batch(&sources_to_import) {
            Ok(()) => {
                // 整批写库成功后按本次实际导入书源（含 concurrentRate）刷新
                // server registry；写库失败不刷新（避免未落库配置提前生效）
                // ——43a5096376 引入的刷新语义原样保留
                for item in &sources_to_import {
                    crate::handlers::web_book::refresh_source_rate_limit(
                        &item.book_source_url,
                        item.concurrent_rate.as_deref().unwrap_or(""),
                    );
                }
                // 区分新增和更新
                for item in &sources_to_import {
                    if local_urls.contains(&item.book_source_url) {
                        updated += 1;
                    } else {
                        added += 1;
                    }
                }
            }
            Err(e) => {
                failed = sources_to_import.len();
                errors.push(format!("批量导入失败: {e}"));
            }
        }
    }

    let result = UpdateResult {
        updated,
        added,
        skipped,
        failed,
        errors,
    };

    Ok((StatusCode::OK, Json(json!(result))))
}

/// 检查单个仓库的更新
async fn check_repo_updates(
    client: &reqwest::Client,
    repo_info: &SourceRepo,
    local_sources: &[legado_core::models::BookSource],
) -> UpdateCheckResult {
    // 下载远程书源
    let response = match client.get(&repo_info.url).send().await {
        Ok(resp) => resp,
        Err(e) => {
            return UpdateCheckResult {
                repo_name: repo_info.name.clone(),
                repo_url: repo_info.url.clone(),
                remote_total: 0,
                updates: vec![],
                new_count: 0,
                success: false,
                error: Some(format!("请求失败: {e}")),
            };
        }
    };

    if !response.status().is_success() {
        return UpdateCheckResult {
            repo_name: repo_info.name.clone(),
            repo_url: repo_info.url.clone(),
            remote_total: 0,
            updates: vec![],
            new_count: 0,
            success: false,
            error: Some(format!("HTTP 状态码: {}", response.status())),
        };
    }

    let body = match response.text().await {
        Ok(b) => b,
        Err(e) => {
            return UpdateCheckResult {
                repo_name: repo_info.name.clone(),
                repo_url: repo_info.url.clone(),
                remote_total: 0,
                updates: vec![],
                new_count: 0,
                success: false,
                error: Some(format!("读取响应失败: {e}")),
            };
        }
    };

    // 解析远程书源
    let remote_sources: Vec<Value> = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            return UpdateCheckResult {
                repo_name: repo_info.name.clone(),
                repo_url: repo_info.url.clone(),
                remote_total: 0,
                updates: vec![],
                new_count: 0,
                success: false,
                error: Some(format!("解析 JSON 失败: {e}")),
            };
        }
    };

    // 构建本地书源 URL -> lastUpdateTime 映射
    let local_map: std::collections::HashMap<&str, i64> = local_sources
        .iter()
        .map(|s| (s.book_source_url.as_str(), s.last_update_time))
        .collect();

    let mut updates: Vec<SourceUpdateInfo> = Vec::new();
    let mut new_count = 0usize;

    for item in &remote_sources {
        let url = item
            .get("bookSourceUrl")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if url.is_empty() {
            continue;
        }

        let name = item
            .get("bookSourceName")
            .and_then(|v| v.as_str())
            .unwrap_or("未知书源")
            .to_string();
        let remote_time = item
            .get("lastUpdateTime")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);

        match local_map.get(url) {
            Some(&local_time) => {
                // 本地存在，比较更新时间
                if remote_time > local_time {
                    updates.push(SourceUpdateInfo {
                        source_url: url.to_string(),
                        source_name: name,
                        local_update_time: local_time,
                        remote_update_time: remote_time,
                        need_update: true,
                    });
                }
            }
            None => {
                // 本地不存在，计为新增
                new_count += 1;
            }
        }
    }

    UpdateCheckResult {
        repo_name: repo_info.name.clone(),
        repo_url: repo_info.url.clone(),
        remote_total: remote_sources.len(),
        updates,
        new_count,
        success: true,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use std::io::{Read, Write};
    use tower::ServiceExt;

    use crate::routes::create_router;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
            injected_paths: Default::default(),
            legacy_review: Default::default(),
        })
    }

    /// 测试播种：与 FFI `import_sources` / 生产 `execute_update` 同一 serde
    /// 链路写入书源（审查批1 P0-1 后本文件不再引用 RoomImporter，防复发
    /// 规定 1：测试与生产走同一写实现，杜绝种子旁路掩盖链路缺陷）。
    fn seed_book_sources(db: &legado_db::Database, json: &str) {
        let sources: Vec<BookSource> =
            serde_json::from_str(json).expect("测试种子应可解析为 BookSource 数组");
        BookSourceRepository::new(db.connection())
            .insert_batch(&sources)
            .expect("测试播种应写入成功");
    }

    /// 直读书源 TEXT 单列（断言落库值用）
    fn read_source_column(db: &legado_db::Database, url: &str, column: &str) -> Option<String> {
        // 列名由本文件测试常量传入（非外部输入），白名单校验防误用
        assert!(
            [
                "ruleSearch",
                "ruleToc",
                "ruleContent",
                "ruleBookInfo",
                "variable",
                "concurrentRate"
            ]
            .contains(&column),
            "不允许查询列: {column}"
        );
        db.connection()
            .query_row(
                &format!("SELECT {column} FROM book_sources WHERE bookSourceUrl = ?1"),
                [url],
                |row| row.get(0),
            )
            .unwrap_or_else(|e| panic!("读取 {url}.{column} 失败: {e}"))
    }

    #[tokio::test]
    async fn test_list_repos() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/sources/repos")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert!(json["repos"].is_array());
        assert!(json["total"].as_u64().unwrap() > 0);
    }

    /// 测试专用：本地回环书源仓库 mock（`default_repos` 两个外部仓库的确定性替身）
    ///
    /// 在指定路径提供 bookSource JSON 数组（200），其余路径 404。
    /// std `TcpListener` 模式（与 legado-ffi/legado-js 的 cookie 回显服务器、
    /// legado-js 的 `spawn_httpbin_mock` 同款；测试不引入 tokio-net 依赖）。
    fn spawn_source_repo_mock(
        max_conns: usize,
        routes: Vec<(String, String)>,
    ) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    if sock.read_exact(&mut byte).is_err() {
                        break;
                    }
                    head.push(byte[0]);
                    if head.len() > 65_536 {
                        break;
                    }
                }
                let head_str = String::from_utf8_lossy(&head);
                let target = head_str
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/");
                let (status, body) = routes
                    .iter()
                    .find(|(path, _)| path.as_str() == target)
                    .map(|(_, body)| ("200 OK", body.as_str()))
                    .unwrap_or_else(|| ("404 Not Found", r#"{"error":"not found"}"#));
                let resp = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
                    len = body.len()
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// `check_updates` 检查逻辑对本地回环仓库生效（确定性硬断言）
    ///
    /// 原本例真联网抓 raw.githubusercontent.com / cdn.jsdelivr.net（仅断言
    /// 「非 404」——外网断线/仓库变更时检查静默失败，用例假绿）。现改为：
    /// 本地库播种 + `set_test_repos` 注入两个本地回环仓库（Drop 守卫还原），
    /// 响应各字段（success / remote_total / updates / new_count / 总量）逐项硬断言。
    #[tokio::test]
    async fn test_check_updates_route_exists() {
        let state = make_test_state();

        // 本地库播种：Mock A lastUpdateTime=1000 < 远程 2000 → 应判定需更新；
        // Mock New1 / Mock New2 本地不存在 → 应计为新增
        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                r#"[{"bookSourceUrl":"https://mock-a.example/","bookSourceName":"Mock A","lastUpdateTime":1000}]"#,
            );
        }

        let repo1 = json!([
            {"bookSourceUrl": "https://mock-a.example/", "bookSourceName": "Mock A", "lastUpdateTime": 2000},
            {"bookSourceUrl": "https://mock-new1.example/", "bookSourceName": "Mock New1", "lastUpdateTime": 3000}
        ])
        .to_string();
        let repo2 = json!([
            {"bookSourceUrl": "https://mock-new2.example/", "bookSourceName": "Mock New2", "lastUpdateTime": 4000}
        ])
        .to_string();
        let addr = spawn_source_repo_mock(
            8,
            vec![
                ("/repo1.json".to_string(), repo1),
                ("/repo2.json".to_string(), repo2),
            ],
        );
        let _repos_guard = set_test_repos(vec![
            SourceRepo {
                name: "本地仓库一".to_string(),
                url: format!("http://{addr}/repo1.json"),
                description: "测试回环仓库".to_string(),
            },
            SourceRepo {
                name: "本地仓库二".to_string(),
                url: format!("http://{addr}/repo2.json"),
                description: "测试回环仓库".to_string(),
            },
        ]);

        let app = create_router(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/sources/updates")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "本地回环仓库可达，检查应返回 200"
        );

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        let results = json["results"].as_array().expect("results 应为数组");
        assert_eq!(results.len(), 2, "应检查注入的两个仓库");
        for r in results {
            assert_eq!(
                r["success"], true,
                "仓库检查应成功（回环 mock 可达）: error={}",
                r["error"]
            );
            assert!(
                r["remote_total"].as_u64().expect("remote_total") > 0,
                "远程书源数应 > 0: {r}"
            );
        }
        let r1 = results
            .iter()
            .find(|r| r["repo_name"] == "本地仓库一")
            .expect("仓库一结果");
        let r2 = results
            .iter()
            .find(|r| r["repo_name"] == "本地仓库二")
            .expect("仓库二结果");
        // 仓库一：Mock A（本地 1000 < 远程 2000）需更新；Mock New1 本地不存在 → 新增
        assert_eq!(r1["remote_total"], 2);
        assert_eq!(r1["new_count"], 1);
        let updates = r1["updates"].as_array().expect("仓库一 updates 应为数组");
        assert_eq!(updates.len(), 1, "仅 Mock A 应判定需更新");
        assert_eq!(updates[0]["source_url"], "https://mock-a.example/");
        assert_eq!(updates[0]["need_update"], true);
        assert_eq!(updates[0]["local_update_time"], 1000);
        assert_eq!(updates[0]["remote_update_time"], 2000);
        // 仓库二：Mock New2 本地不存在 → 新增
        assert_eq!(r2["remote_total"], 1);
        assert_eq!(r2["new_count"], 1);
        assert_eq!(r2["updates"].as_array().expect("仓库二 updates").len(), 0);
        // 汇总量
        assert_eq!(json["total_updates"], 1);
        assert_eq!(json["total_new"], 2);
    }

    #[tokio::test]
    async fn test_execute_update_invalid_url() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "repo_url": "http://invalid.localhost.test/nonexistent.json",
            "only_update_existing": false
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 应该返回错误（网络不可达），但不是 404
        assert_ne!(resp.status(), StatusCode::NOT_FOUND);
    }

    /// execute_update 批量导入后刷新本次书源：
    /// 既有 limiter 由旧率 1/10000 更新为远端新率 3/10000，旧快照 acquire 立即放行
    /// （未刷新会沿用旧率等满 10s 窗口 → 300ms 超时失败）
    #[tokio::test]
    async fn test_execute_update_refreshes_rate_limiter() {
        use std::time::Duration;

        use legado_core::models::BookSource;

        let state = make_test_state();
        let url = "https://server-ratelimit-batch.example/";

        // 本地已有旧率书源（含嵌套规则的真实形态种子），并让 server registry
        // 对其建立 limiter（窗口已用 1 次）
        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                &json!([{
                    "bookSourceUrl": url,
                    "bookSourceName": "旧书源",
                    "concurrentRate": "1/10000",
                    "variable": "{\"old\":\"local\"}",
                    "ruleSearch": {"bookList": "class.old", "name": "tag.h3@text"}
                }])
                .to_string(),
            );
        }
        let stale = BookSource {
            book_source_url: url.to_string(),
            concurrent_rate: Some("1/10000".to_string()),
            ..BookSource::default()
        };
        crate::handlers::web_book::rate_limiter()
            .acquire(&stale)
            .await;

        // 回环仓库返回同 URL 新率 3/10000（只更新已有书源；真实形态含嵌套规则）
        let remote = json!([{
            "bookSourceUrl": url,
            "bookSourceName": "新书源",
            "concurrentRate": "3/10000",
            "variable": "{\"new\":\"remote\"}",
            "ruleSearch": {"bookList": "class.new", "name": "tag.h4@text"},
            "lastUpdateTime": 9999
        }])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state);
        let body = serde_json::to_string(&json!({
            "repo_url": format!("http://{addr}/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "回环仓库可达，更新应成功");

        // 刷新后：旧快照 acquire 立即放行
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            crate::handlers::web_book::rate_limiter().acquire(&stale),
        )
        .await;
        assert!(
            passed.is_ok(),
            "execute_update 批量导入成功后必须刷新 server registry"
        );
    }

    /// 审查批1 P0-1 回归①：真实形态书源 JSON（规则为嵌套对象 + variable
    /// 非空 + enabledCookieJar 混合形态）经 /api/sources/update 落库后，
    /// ruleSearch/ruleToc/ruleContent/variable 非空且与种子一致——旧链路
    /// （RoomImporter `as_str()`）会把嵌套对象规则静默丢成 NULL。
    #[tokio::test]
    async fn test_execute_update_persists_nested_rules_and_variable() {
        let state = make_test_state();

        let rule_search = json!({
            "bookList": "class.result||class.bookbox",
            "name": "tag.h3@text",
            "author": "tag.span.0@text",
            "bookUrl": "tag.a.0@href"
        });
        let rule_toc = json!({
            "chapterList": "class.chapter",
            "chapterName": "text",
            "chapterUrl": "href"
        });
        let rule_content = json!({"content": "id.content@textNodes"});
        let variable = "{\"token\":\"abc123\",\"user\":\"tester\"}";
        let remote = json!([
            {
                "bookSourceUrl": "https://real-form-a.example/",
                "bookSourceName": "真实形态A",
                "bookSourceGroup": "审查批1",
                "bookSourceType": 0,
                "enabled": true,
                "enabledCookieJar": true,
                "concurrentRate": "2/10000",
                "lastUpdateTime": 1729900000000i64,
                "respondTime": 180000,
                "variable": variable,
                "searchUrl": "https://real-form-a.example/search?q={{key}}",
                "ruleSearch": rule_search,
                "ruleToc": rule_toc,
                "ruleContent": rule_content
            },
            {
                "bookSourceUrl": "https://real-form-b.example/",
                "bookSourceName": "真实形态B",
                "enabledCookieJar": false
            }
        ])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "repo_url": format!("http://{addr}/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "回环仓库可达，更新应成功");

        // 落库断言：规则为 JSON 字符串且与种子对象语义相等；variable 原样；
        // enabledCookieJar 混合形态（true/false）各自落对
        let db = state.db.lock().await;
        let stored_search = read_source_column(&db, "https://real-form-a.example/", "ruleSearch")
            .expect("ruleSearch 应落库（旧链路此处为 NULL）");
        assert_eq!(
            serde_json::from_str::<Value>(&stored_search).unwrap(),
            rule_search,
            "ruleSearch 落库值应与种子对象一致"
        );
        let stored_toc = read_source_column(&db, "https://real-form-a.example/", "ruleToc")
            .expect("ruleToc 应落库");
        assert_eq!(
            serde_json::from_str::<Value>(&stored_toc).unwrap(),
            rule_toc
        );
        let stored_content = read_source_column(&db, "https://real-form-a.example/", "ruleContent")
            .expect("ruleContent 应落库");
        assert_eq!(
            serde_json::from_str::<Value>(&stored_content).unwrap(),
            rule_content
        );
        assert_eq!(
            read_source_column(&db, "https://real-form-a.example/", "variable").unwrap(),
            variable,
            "variable（登录态）应原样落库"
        );
        let read_jar = |conn_url: &str| -> i64 {
            db.connection()
                .query_row(
                    "SELECT enabledCookieJar FROM book_sources WHERE bookSourceUrl = ?1",
                    [conn_url],
                    |row| row.get(0),
                )
                .unwrap()
        };
        assert_eq!(read_jar("https://real-form-a.example/"), 1, "显式 true → 1");
        assert_eq!(
            read_jar("https://real-form-b.example/"),
            0,
            "显式 false → 0"
        );
    }

    /// 审查批1 P0-1 回归②：对已存在书源（本地 variable/concurrentRate/规则）
    /// 重跑仓库更新——覆盖语义与 FFI `import_sources` 一致（`insert_batch`
    /// 全列 INSERT OR REPLACE：**以导入为准覆盖**，含 variable），且
    /// server registry 刷新发生（43a5096376 语义不回归）。
    #[tokio::test]
    async fn test_execute_update_reimport_overwrites_existing_like_ffi() {
        use std::time::Duration;

        let state = make_test_state();
        let url = "https://reimport.example/";

        // 本地存量：登录态 variable + 旧限速 + 旧规则
        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                &json!([{
                    "bookSourceUrl": url,
                    "bookSourceName": "存量书源",
                    "concurrentRate": "1/10000",
                    "variable": "{\"token\":\"local-login\"}",
                    "ruleSearch": {"bookList": "class.old", "name": "tag.old@text"}
                }])
                .to_string(),
            );
        }

        // 预先在 registry 建立旧率 limiter 并用掉窗口（复用确定性断言模式：
        // 未刷新则旧快照 acquire 需等满 10s 窗口，300ms 内必超时）
        let stale = BookSource {
            book_source_url: url.to_string(),
            concurrent_rate: Some("1/10000".to_string()),
            ..BookSource::default()
        };
        crate::handlers::web_book::rate_limiter()
            .acquire(&stale)
            .await;

        // 远端同 URL：variable / concurrentRate / 规则全部为新值
        let rule_search_remote = json!({"bookList": "class.fresh", "name": "tag.fresh@text"});
        let remote = json!([{
            "bookSourceUrl": url,
            "bookSourceName": "更新书源",
            "concurrentRate": "2/5000",
            "variable": "{\"token\":\"remote-login\"}",
            "ruleSearch": rule_search_remote,
            "lastUpdateTime": 8888
        }])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "repo_url": format!("http://{addr}/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "回环仓库可达，更新应成功");

        let resp_body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&resp_body).unwrap();
        assert_eq!(result["updated"], 1, "同 URL 应回计为 updated");
        assert_eq!(result["failed"], 0);

        // 覆盖语义断言：以导入为准（与 FFI import_sources / 原版 Room REPLACE 同语义）
        let db = state.db.lock().await;
        assert_eq!(
            read_source_column(&db, url, "variable").unwrap(),
            "{\"token\":\"remote-login\"}",
            "远端带 variable 时应以导入为准覆盖本地登录态（FFI 同语义）"
        );
        assert_eq!(
            read_source_column(&db, url, "concurrentRate").unwrap(),
            "2/5000"
        );
        let stored = read_source_column(&db, url, "ruleSearch").unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&stored).unwrap(),
            rule_search_remote,
            "规则应整体被远端覆盖"
        );
        drop(db);

        // registry 刷新断言：旧率快照 acquire 立即放行（未刷新会等满旧窗口）
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            crate::handlers::web_book::rate_limiter().acquire(&stale),
        )
        .await;
        assert!(passed.is_ok(), "更新成功后必须刷新 server registry");
    }

    /// 审查批1 P0-1 语义锁定：远端 JSON 不带 variable 键时与 FFI
    /// `import_sources` 既有行为一致——反序列化缺键得空串（lenient_string），
    /// 全列覆盖后本地 variable 清空；不发明「保留本地登录态」的新语义。
    #[tokio::test]
    async fn test_execute_update_variable_absent_clears_local_like_ffi() {
        let state = make_test_state();
        let url = "https://no-var.example/";

        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                &json!([{
                    "bookSourceUrl": url,
                    "bookSourceName": "有登录态",
                    "variable": "{\"token\":\"keep-me\"}"
                }])
                .to_string(),
            );
        }

        let remote = json!([{
            "bookSourceUrl": url,
            "bookSourceName": "无变量远端",
            "lastUpdateTime": 6666
        }])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "repo_url": format!("http://{addr}/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let db = state.db.lock().await;
        assert_eq!(
            read_source_column(&db, url, "variable").unwrap(),
            "",
            "远端缺 variable 键 → 清空（与 FFI import_sources 同语义）"
        );
    }

    #[test]
    fn test_default_repos_not_empty() {
        let repos = default_repos();
        assert!(!repos.is_empty());
        for repo in &repos {
            assert!(!repo.name.is_empty());
            assert!(!repo.url.is_empty());
        }
    }

    #[test]
    fn test_source_update_info_serialization() {
        let info = SourceUpdateInfo {
            source_url: "https://example.com".to_string(),
            source_name: "测试书源".to_string(),
            local_update_time: 1000,
            remote_update_time: 2000,
            need_update: true,
        };
        let json = serde_json::to_value(&info).unwrap();
        assert_eq!(json["source_url"], "https://example.com");
        assert_eq!(json["need_update"], true);
    }

    #[test]
    fn test_update_result_serialization() {
        let result = UpdateResult {
            updated: 5,
            added: 3,
            skipped: 2,
            failed: 0,
            errors: vec![],
        };
        let json = serde_json::to_value(&result).unwrap();
        assert_eq!(json["updated"], 5);
        assert_eq!(json["added"], 3);
    }
}
