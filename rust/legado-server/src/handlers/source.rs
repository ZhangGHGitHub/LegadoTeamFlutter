//! 书源管理处理器

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Deserializer};
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::models::BookSource;
use legado_db::repository::book_source_repository::BookSourceRepository;
use legado_db::repository::Repository;

use crate::error::ApiError;
use crate::state::AppState;

/// 创建书源请求体
#[derive(Debug, Deserialize)]
pub struct CreateSourceRequest {
    pub book_source_url: String,
    pub book_source_name: String,
    pub book_source_group: Option<String>,
    pub book_source_type: Option<i32>,
    pub enabled: Option<bool>,
    pub search_url: Option<String>,
    /// 并发率：缺键/null → None；空串（含纯空白）→ 按 None 处理
    /// （对齐原版「空=不限流」）；合法串 → 保存。
    #[serde(default)]
    pub concurrent_rate: Option<String>,
}

/// 更新书源请求体
///
/// `concurrent_rate` 需要区分三种 JSON 形态，故与 create 分开：
/// - 缺键 → 保留数据库原值且不刷新限速注册表；
/// - 显式 `null` 或空串 → 清除（库内置 None 并移除该 key 的 limiter）；
/// - 有值 → 入库并刷新。
///
/// 裸 `Option<Option<String>>` 的 serde 默认语义会把「缺键」和「显式 null」
/// 都折叠为外层 `None`；这里用 [`deserialize_present_option_string`] 在键存在
/// 时再包一层 `Some`：缺键走 `#[serde(default)]` → 外层 None，null →
/// `Some(None)`，空串 → `Some(Some(""))`。
#[derive(Debug, Deserialize)]
pub struct UpdateSourceRequest {
    pub book_source_url: String,
    pub book_source_name: String,
    pub book_source_group: Option<String>,
    pub book_source_type: Option<i32>,
    pub enabled: Option<bool>,
    pub search_url: Option<String>,
    #[serde(default, deserialize_with = "deserialize_present_option_string")]
    pub concurrent_rate: Option<Option<String>>,
}

/// 键存在时反序列化为 `Some(Option<String>)`；键缺省由 `#[serde(default)]` 处理
fn deserialize_present_option_string<'de, D>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Some)
}

/// 把创建请求的 concurrent_rate 规整为入库值：空串/纯空白 → None
fn normalize_concurrent_rate(rate: Option<String>) -> Option<String> {
    rate.filter(|r| !r.trim().is_empty())
}

/// GET /api/sources — 获取全部书源
pub async fn list_sources(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookSourceRepository::new(db.connection());
    let sources = repo.find_all()?;
    Ok(Json(json!({ "sources": sources, "total": sources.len() })))
}

/// POST /api/sources — 创建书源
pub async fn create_source(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSourceRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let source = BookSource {
        book_source_url: req.book_source_url,
        book_source_name: req.book_source_name,
        book_source_group: req.book_source_group,
        book_source_type: req.book_source_type.unwrap_or(0),
        enabled: req.enabled.unwrap_or(true),
        search_url: req.search_url,
        concurrent_rate: normalize_concurrent_rate(req.concurrent_rate),
        ..BookSource::default()
    };

    {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        repo.insert(&source)?;
    }
    // 写库成功后才刷新进程级限速注册表（写库失败经 `?` 提前返回，不触发刷新）：
    // 空值 → 移除既有 limiter（空=不限流），合法值 → 原位刷新。
    crate::handlers::web_book::refresh_source_rate_limit(
        &source.book_source_url,
        source.concurrent_rate.as_deref().unwrap_or(""),
    );

    Ok((StatusCode::CREATED, Json(json!(source))))
}

/// PUT /api/sources/:id — 更新书源
pub async fn update_source(
    State(state): State<Arc<AppState>>,
    Path(source_url): Path<String>,
    Json(req): Json<UpdateSourceRequest>,
) -> Result<Json<Value>, ApiError> {
    // concurrentRate 三态：缺键保留 / 显式 null 或空串清除 / 有值更新
    enum RateChange {
        Keep,
        Clear,
        Set(String),
    }
    let rate_change = match req.concurrent_rate {
        None => RateChange::Keep,
        Some(None) => RateChange::Clear,
        Some(Some(raw)) => {
            if raw.trim().is_empty() {
                RateChange::Clear
            } else {
                RateChange::Set(raw)
            }
        }
    };

    let source = {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        // 先按 path 取完整实体做字段级 mutate：DTO 未暴露的字段（规则/header/
        // jsLib/variable 等）保持库内原值，不再用 `BookSource::default()` 构造
        // （全列 upsert 会清掉这些字段）。path 不存在时维持原有 INSERT OR
        // REPLACE 语义（以默认实体补齐），不改为 404；URL 冲突时保持现有
        // 「按 path 查找、写 body URL」行为（以 body URL 为准替换该行）。
        let mut source = repo.find_by_url(&source_url)?.unwrap_or_default();
        source.book_source_url = req.book_source_url;
        source.book_source_name = req.book_source_name;
        source.book_source_group = req.book_source_group;
        source.book_source_type = req.book_source_type.unwrap_or(0);
        source.enabled = req.enabled.unwrap_or(true);
        source.search_url = req.search_url;
        match &rate_change {
            RateChange::Keep => {}
            RateChange::Clear => source.concurrent_rate = None,
            RateChange::Set(value) => source.concurrent_rate = Some(value.clone()),
        }
        repo.update(&source)?;
        source
    };

    // 写库成功后才刷新限速注册表：缺键不刷新；清除 → 移除 limiter；有值 → 刷新
    match &rate_change {
        RateChange::Keep => {}
        RateChange::Clear => {
            crate::handlers::web_book::refresh_source_rate_limit(&source.book_source_url, "")
        }
        RateChange::Set(value) => {
            crate::handlers::web_book::refresh_source_rate_limit(&source.book_source_url, value)
        }
    }

    Ok(Json(json!(source)))
}

/// DELETE /api/sources/:id — 删除书源
pub async fn delete_source(
    State(state): State<Arc<AppState>>,
    Path(source_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookSourceRepository::new(db.connection());
    repo.delete(&source_url)?;
    Ok(Json(json!({ "deleted": true, "source_url": source_url })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use std::time::Duration;
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;
    use legado_core::models::rule::{ContentRule, SearchRule};
    use legado_fetcher::rate_limit::RateLimiterRegistry;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    /// 构造 JSON 请求（Content-Type: application/json）
    fn json_request(method: Method, uri: &str, body: &Value) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("Content-Type", "application/json")
            .body(Body::from(serde_json::to_string(body).unwrap()))
            .unwrap()
    }

    /// 读取响应体 JSON
    async fn response_json(resp: axum::response::Response) -> Value {
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    /// 读库内书源
    async fn find_source(state: &Arc<AppState>, url: &str) -> Option<BookSource> {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(url).unwrap()
    }

    /// 进程级限速注册表（测试用唯一 key，避免并行互扰）
    fn rate_registry() -> Arc<RateLimiterRegistry> {
        crate::handlers::web_book::rate_limiter()
    }

    /// 构造限速快照（acquire 用）
    fn rate_snapshot(url: &str, rate: &str) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            concurrent_rate: Some(rate.to_string()),
            ..BookSource::default()
        }
    }

    /// 向库内播种完整书源（含 DTO 未暴露字段）
    async fn seed_source(state: &Arc<AppState>, source: BookSource) {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        repo.insert(&source).unwrap();
    }

    #[tokio::test]
    async fn test_list_sources_empty() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/sources")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_source() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "book_source_url": "https://source.example.com",
            "book_source_name": "测试书源",
            "enabled": true
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/sources")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    #[tokio::test]
    async fn test_delete_source() {
        let state = make_test_state();

        // 先插入一个书源
        {
            let db = state.db.lock().await;
            let repo = BookSourceRepository::new(db.connection());
            let src = BookSource {
                book_source_url: "src1".to_string(),
                book_source_name: "test".to_string(),
                ..BookSource::default()
            };
            repo.insert(&src).unwrap();
        }

        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/sources/src1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    // ─── concurrentRate：create 带值/缺省、update 三态、未暴露字段保留 ───────

    /// create 带合法 concurrentRate：入库并按保存路径刷新既有 limiter
    /// （旧率 1/10000 窗口已用 1 次，刷新为新率 3/10000 后旧快照立即放行）
    #[tokio::test]
    async fn test_create_source_with_concurrent_rate_stores_and_refreshes() {
        let state = make_test_state();
        let url = "https://rest-rate-create-value.example";
        let registry = rate_registry();
        registry.acquire(&rate_snapshot(url, "1/10000")).await; // 旧率窗口已用 1 次

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({
                    "book_source_url": url,
                    "book_source_name": "限速创建源",
                    "concurrent_rate": "3/10000"
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);

        assert_eq!(
            find_source(&state, url)
                .await
                .unwrap()
                .concurrent_rate
                .as_deref(),
            Some("3/10000"),
            "create 必须保存 concurrentRate"
        );
        let passed = tokio::time::timeout(
            Duration::from_millis(500),
            registry.acquire(&rate_snapshot(url, "1/10000")),
        )
        .await;
        assert!(
            passed.is_ok(),
            "写库成功后 refresh 必须生效（旧快照应立即放行）"
        );
    }

    /// create 缺省 / 空串 concurrentRate：入库 None（空=不限流），
    /// 并清除既有 limiter（旧窗口已用 1 次，若沿用旧记录下一次 acquire 会被挡）
    #[tokio::test]
    async fn test_create_source_without_concurrent_rate_clears_limiter() {
        let state = make_test_state();
        let url = "https://rest-rate-create-none.example";
        let registry = rate_registry();
        registry.acquire(&rate_snapshot(url, "1/10000")).await; // 旧窗口已用 1 次

        let app = create_router(Arc::clone(&state));
        // 缺键 → 按 None 处理
        let resp = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({
                    "book_source_url": url,
                    "book_source_name": "无限速创建源"
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        assert!(find_source(&state, url)
            .await
            .unwrap()
            .concurrent_rate
            .is_none());
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            registry.acquire(&rate_snapshot(url, "1/10000")),
        )
        .await;
        assert!(passed.is_ok(), "缺省 concurrentRate 必须清除既有 limiter");

        // 显式空串 → 同样按 None 入库，响应不输出 concurrentRate 键
        let resp = app
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({
                    "book_source_url": url,
                    "book_source_name": "无限速创建源",
                    "concurrent_rate": ""
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        assert!(
            find_source(&state, url)
                .await
                .unwrap()
                .concurrent_rate
                .is_none(),
            "空串应按 None 入库（空=不限流）"
        );
        let body = response_json(resp).await;
        assert!(
            body.get("concurrentRate").is_none(),
            "空值不应序列化 concurrentRate 键"
        );
    }

    /// update 缺 concurrent_rate 键：保留库内原值、保留全部未暴露字段、
    /// 且不刷新 limiter（旧率旧窗口仍生效，下一次 acquire 应继续被挡）
    #[tokio::test]
    async fn test_update_source_missing_rate_keeps_value_fields_and_limiter() {
        let state = make_test_state();
        let key = "rest-rate-update-missing";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "旧名".to_string(),
                book_source_group: Some("旧分组".to_string()),
                concurrent_rate: Some("1/10000".to_string()),
                js_lib: Some("js-lib-body".to_string()),
                header: Some("{\"X-Test\":\"1\"}".to_string()),
                variable: "user=abc".to_string(),
                book_source_comment: Some("备注".to_string()),
                search_url: Some("https://keep.example/search?q={key}".to_string()),
                rule_search: Some(SearchRule {
                    book_list: Some("class.result".to_string()),
                    ..SearchRule::default()
                }),
                rule_content: Some(ContentRule {
                    content: Some("class.content@text".to_string()),
                    ..ContentRule::default()
                }),
                ..BookSource::default()
            },
        )
        .await;
        let registry = rate_registry();
        registry.acquire(&rate_snapshot(key, "1/10000")).await; // 窗口已用 1 次

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_url": key, "book_source_name": "新名" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let found = find_source(&state, key).await.expect("行仍存在");
        assert_eq!(found.book_source_name, "新名");
        assert_eq!(
            found.concurrent_rate.as_deref(),
            Some("1/10000"),
            "缺键必须保留库内原值"
        );
        // DTO 未暴露字段必须完整保留（旧实现 default 构造会清空）
        assert_eq!(found.js_lib.as_deref(), Some("js-lib-body"));
        assert_eq!(found.header.as_deref(), Some("{\"X-Test\":\"1\"}"));
        assert_eq!(found.variable, "user=abc");
        assert_eq!(found.book_source_comment.as_deref(), Some("备注"));
        assert_eq!(
            found
                .rule_search
                .as_ref()
                .and_then(|r| r.book_list.as_deref()),
            Some("class.result")
        );
        assert_eq!(
            found
                .rule_content
                .as_ref()
                .and_then(|r| r.content.as_deref()),
            Some("class.content@text")
        );

        // 未刷新：旧率窗口（已用 1 次）仍在，下一次 acquire 继续被挡
        let blocked = tokio::time::timeout(
            Duration::from_millis(300),
            registry.acquire(&rate_snapshot(key, "1/10000")),
        )
        .await;
        assert!(blocked.is_err(), "缺键不得刷新/清除既有 limiter");
    }

    /// update 显式 null：库内置 None 并移除既有 limiter（满窗后立即放行）
    #[tokio::test]
    async fn test_update_source_explicit_null_clears_rate_and_limiter() {
        let state = make_test_state();
        let key = "rest-rate-update-null";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "旧名".to_string(),
                concurrent_rate: Some("2/10000".to_string()),
                ..BookSource::default()
            },
        )
        .await;
        let registry = rate_registry();
        registry.acquire(&rate_snapshot(key, "2/10000")).await;
        registry.acquire(&rate_snapshot(key, "2/10000")).await; // 窗口已用满

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({
                    "book_source_url": key,
                    "book_source_name": "新名",
                    "concurrent_rate": null
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        assert!(
            find_source(&state, key)
                .await
                .unwrap()
                .concurrent_rate
                .is_none(),
            "显式 null 必须清空库内值"
        );
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            registry.acquire(&rate_snapshot(key, "2/10000")),
        )
        .await;
        assert!(passed.is_ok(), "清除路径必须移除既有 limiter");
    }

    /// update 空串：与显式 null 等价（清空库内值 + 移除 limiter）
    #[tokio::test]
    async fn test_update_source_empty_string_clears_rate_and_limiter() {
        let state = make_test_state();
        let key = "rest-rate-update-empty";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "旧名".to_string(),
                concurrent_rate: Some("2/10000".to_string()),
                ..BookSource::default()
            },
        )
        .await;
        let registry = rate_registry();
        registry.acquire(&rate_snapshot(key, "2/10000")).await;
        registry.acquire(&rate_snapshot(key, "2/10000")).await; // 窗口已用满

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({
                    "book_source_url": key,
                    "book_source_name": "新名",
                    "concurrent_rate": ""
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        assert!(
            find_source(&state, key)
                .await
                .unwrap()
                .concurrent_rate
                .is_none(),
            "空串必须清空库内值"
        );
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            registry.acquire(&rate_snapshot(key, "2/10000")),
        )
        .await;
        assert!(passed.is_ok(), "空串清除路径必须移除既有 limiter");
    }

    /// update 合法 concurrentRate：入库并原位刷新既有 limiter（保留已用次数）
    ///
    /// 刷新判据：旧率 1/10000 窗口已用 1 次，改为 3/10000 后旧快照立即放行，
    /// 其后两次访问仍放行、第四次被挡（若未刷新则第一次就被挡；若被
    /// remove+重建则不会挡——以此区分「原位置换」与「清除重建」）
    #[tokio::test]
    async fn test_update_source_valid_rate_updates_db_and_refreshes() {
        let state = make_test_state();
        let key = "rest-rate-update-value";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "旧名".to_string(),
                concurrent_rate: Some("1/10000".to_string()),
                ..BookSource::default()
            },
        )
        .await;
        let registry = rate_registry();
        registry.acquire(&rate_snapshot(key, "1/10000")).await; // 窗口已用 1 次

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({
                    "book_source_url": key,
                    "book_source_name": "新名",
                    "concurrent_rate": "3/10000"
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            find_source(&state, key)
                .await
                .unwrap()
                .concurrent_rate
                .as_deref(),
            Some("3/10000"),
            "合法值必须入库"
        );

        let stale = rate_snapshot(key, "1/10000");
        let first =
            tokio::time::timeout(Duration::from_millis(500), registry.acquire(&stale)).await;
        assert!(first.is_ok(), "刷新为新率后旧快照应立即放行");
        let second =
            tokio::time::timeout(Duration::from_millis(500), registry.acquire(&stale)).await;
        assert!(second.is_ok(), "新率 3/10000 的窗口额度应继续放行");
        let third =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&stale)).await;
        assert!(third.is_err(), "额度用满且原窗口保留（未重建）时应继续等待");
    }

    /// update path 不存在时维持原有 INSERT OR REPLACE 语义（不返回 404）
    #[tokio::test]
    async fn test_update_source_unknown_path_upserts() {
        let state = make_test_state();
        let key = "rest-rate-update-absent";
        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_url": key, "book_source_name": "不存在则插入" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let found = find_source(&state, key).await.expect("应按 body URL 插入");
        assert_eq!(found.book_source_name, "不存在则插入");
        assert!(found.concurrent_rate.is_none());
    }
}
