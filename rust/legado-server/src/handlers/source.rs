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

/// 更新书源请求体（**部分更新**语义，批24 回修 P1-2）
///
/// 所有字段均可缺省：**仅写入请求中出现的键，未出现 = 保持库内原值**。
/// 修复前 `book_source_group`/`search_url` 缺键被写成 `None`、
/// `book_source_type` 缺键被重置为 `0`、`enabled` 缺键被重新置为 `true`，
/// 按 create 形状发 PUT 会清空分组/searchUrl 并重新启用停用源。
///
/// 三态字段（`book_source_group` / `search_url` / `concurrent_rate`）：
/// - 缺键 → 保留数据库原值（`concurrent_rate` 同时不刷新限速注册表）；
/// - 显式 `null` → 清除（可空字段入库 None；`concurrent_rate` 移除 limiter）；
/// - 有值 → 写入（`concurrent_rate` 空串等价于清除并刷新）。
///
/// 裸 `Option<Option<String>>` 的 serde 默认语义会把「缺键」和「显式 null」
/// 都折叠为外层 `None`；这里用 [`deserialize_present_option_string`] 在键存在
/// 时再包一层 `Some`：缺键走 `#[serde(default)]` → 外层 None，null →
/// `Some(None)`，空串 → `Some(Some(""))`。
///
/// `book_source_type` / `enabled` 为非空标量，缺键与显式 `null` 均视为
/// 「不修改」。
#[derive(Debug, Deserialize)]
pub struct UpdateSourceRequest {
    /// 缺省 → 沿用 path 中的源 URL；有值 → 重命名（目标已存在时 409）
    #[serde(default)]
    pub book_source_url: Option<String>,
    #[serde(default)]
    pub book_source_name: Option<String>,
    #[serde(default, deserialize_with = "deserialize_present_option_string")]
    pub book_source_group: Option<Option<String>>,
    #[serde(default)]
    pub book_source_type: Option<i32>,
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default, deserialize_with = "deserialize_present_option_string")]
    pub search_url: Option<Option<String>>,
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
///
/// 审查批 P1-1：已存在同 URL 时返回 **409 Conflict**，不再走
/// `INSERT OR REPLACE` 全列覆盖。旧实现用 `BookSource { ..Default::default() }`
/// 构造实体后写入，重复 URL 会用默认实体清空已存在书源的规则 / `jsLib` /
/// `variable`（登录态）等 DTO 未暴露字段——静默数据丢失。字段级修改请走
/// `PUT /api/sources/{id}`（保留未暴露字段）。
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
        // P1-1：先查重，禁止 REPLACE 整行覆盖（含规则/jsLib/variable）
        if repo.find_by_url(&source.book_source_url)?.is_some() {
            return Ok((
                StatusCode::CONFLICT,
                Json(json!({
                    "error": format!(
                        "书源 URL 已存在：{}；如需修改请使用 PUT /api/sources/{{id}}",
                        source.book_source_url
                    )
                })),
            ));
        }
        // 批30b P2-1：INSERT OR REPLACE 触发外键级联删状态行，必须同事务重建
        // 检验状态（对齐原版 BookSourceDao.insert 的 saveCheckStates）
        repo.insert_with_check_state(&source)?;
    }
    // 写库成功后才刷新进程级限速注册表（写库失败经 `?` 提前返回，不触发刷新）：
    // 空值 → 移除既有 limiter（空=不限流），合法值 → 原位刷新。
    crate::handlers::web_book::refresh_source_rate_limit(
        &source.book_source_url,
        source.concurrent_rate.as_deref().unwrap_or(""),
    );

    Ok((StatusCode::CREATED, Json(json!(source))))
}

/// PUT /api/sources/:id — 更新书源（部分更新）
///
/// 审查批 P1-1：
/// - path 指向的书源不存在 → **404**（旧实现 `unwrap_or_default()` 会以默认
///   实体 upsert，相当于静默创建一条空规则书源）；
/// - body URL 指向另一条已存在书源 → **409 Conflict**（拒绝整行覆盖他行）；
/// - 命中本行时做字段级 mutate：DTO 未暴露的规则/`jsLib`/`variable` 等字段
///   保留库内原值。
///
/// 批24 回修 P1-2：**未出现的键一律不动**（见 [`UpdateSourceRequest`]）。
/// 修复前缺键会被写成默认值（分组/searchUrl 清空、类型归 0、停用源被重新
/// 启用），按 create 形状发 PUT 即触发静默数据丢失。
pub async fn update_source(
    State(state): State<Arc<AppState>>,
    Path(source_url): Path<String>,
    Json(req): Json<UpdateSourceRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
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
        // P1-1：先按 path 取完整实体做字段级 mutate：DTO 未暴露的字段（规则/
        // header/jsLib/variable 等）保持库内原值，不再用 `BookSource::default()`
        // 构造（全列 upsert 会清掉这些字段）。path 不存在 → 404，禁止以默认
        // 实体 upsert 出空规则书源；body URL 命中另一行 → 409，禁止整行覆盖。
        let mut source = match repo.find_by_url(&source_url)? {
            Some(source) => source,
            None => {
                return Ok((
                    StatusCode::NOT_FOUND,
                    Json(json!({
                        "error": format!("书源不存在：{source_url}")
                    })),
                ));
            }
        };
        // 部分更新：仅出现的键参与修改（P1-2）
        let target_url = req
            .book_source_url
            .clone()
            .unwrap_or_else(|| source_url.clone());
        if target_url != source_url && repo.find_by_url(&target_url)?.is_some() {
            return Ok((
                StatusCode::CONFLICT,
                Json(json!({
                    "error": format!(
                        "目标书源 URL 已存在：{target_url}；请先删除目标书源或改用对应 id"
                    )
                })),
            ));
        }
        source.book_source_url = target_url;
        if let Some(name) = req.book_source_name {
            source.book_source_name = name;
        }
        if let Some(group) = req.book_source_group {
            // 外层 Some = 键存在；内层 None = 显式 null → 清空分组
            source.book_source_group = group;
        }
        if let Some(book_source_type) = req.book_source_type {
            source.book_source_type = book_source_type;
        }
        if let Some(enabled) = req.enabled {
            source.enabled = enabled;
        }
        if let Some(search_url) = req.search_url {
            // 外层 Some = 键存在；内层 None = 显式 null → 清空 searchUrl
            source.search_url = search_url;
        }
        match &rate_change {
            RateChange::Keep => {}
            RateChange::Clear => source.concurrent_rate = None,
            RateChange::Set(value) => source.concurrent_rate = Some(value.clone()),
        }
        // 批30b P2-1：REPLACE upsert 会级联删状态行；改走
        // update_with_check_state——规则内容变化重建状态，仅改名称/启用等保留
        repo.update_with_check_state(&source)?;
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

    Ok((StatusCode::OK, Json(json!(source))))
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
    use crate::server::attach_source_write_token_guard;
    use crate::state::AppState;
    use legado_core::models::rule::{ContentRule, SearchRule};
    use legado_db::repository::cache_repository::CacheRepository;
    use legado_fetcher::rate_limit::RateLimiterRegistry;
    use tokio::sync::Mutex;

    /// 令牌错误文案（对齐原版 `hasValidJsSourceApiToken` 失败文案）
    const TOKEN_ERROR: &str = "Web 书源访问令牌未配置或不正确";

    /// 写入 caches 配置（令牌开关/令牌值）
    async fn seed_config(state: &Arc<AppState>, key: &str, value: &str) {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put(key, value, 0)
            .unwrap();
    }

    /// 构造带 Origin/令牌头的 JSON 请求
    fn json_request_with_token(
        method: Method,
        uri: &str,
        body: &Value,
        token: Option<&str>,
    ) -> Request<Body> {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("Content-Type", "application/json");
        if let Some(token) = token {
            builder = builder.header("x-legado-token", token);
        }
        builder
            .body(Body::from(serde_json::to_string(body).unwrap()))
            .unwrap()
    }

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
            source_check: Default::default(),
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

    /// 读库内检验状态（批30b P2-1：写路径必须维护状态行）
    async fn find_check_state(
        state: &Arc<AppState>,
        url: &str,
    ) -> Option<legado_core::models::BookSourceCheckState> {
        let db = state.db.lock().await;
        legado_db::BookSourceCheckStateRepository::new(db.connection())
            .find_by_url(url)
            .unwrap()
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

    /// 批30b P2-1：REST 创建书源必须同事务建检验状态行
    ///
    /// 修复前 `Repository::insert`（INSERT OR REPLACE）在无旧行时也能写成功，
    /// 但不建状态 → `getBookSourceCheckStates` 缺该源，网页端把源当「未知状态」。
    #[tokio::test]
    async fn test_create_source_creates_check_state() {
        let state = make_test_state();
        let app = create_router(Arc::clone(&state));
        let url = "https://rest-state-create.example.com";

        let resp = app
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({ "book_source_url": url, "book_source_name": "状态源" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);

        let state_row = find_check_state(&state, url)
            .await
            .expect("创建书源应同时建检验状态行");
        assert_eq!(state_row.status, "NEEDS_CHECK");
        assert_eq!(state_row.checked_at, 0);
        assert!(state_row.detail.is_empty());
        assert!(!state_row.revision.is_empty());
        assert!(!state_row.source_revision.is_empty());
    }

    /// 批30b P2-1：REST 更新规则内容重建状态，内容不变保留状态
    #[tokio::test]
    async fn test_update_source_maintains_check_state() {
        let state = make_test_state();
        let key = "rest-state-update";
        {
            let db = state.db.lock().await;
            BookSourceRepository::new(db.connection())
                .insert_with_check_state(&BookSource {
                    book_source_url: key.to_string(),
                    book_source_name: "旧名".to_string(),
                    search_url: Some("https://old.example/search?q={key}".to_string()),
                    ..BookSource::default()
                })
                .unwrap();
        }
        let before = find_check_state(&state, key).await.expect("种子状态");

        let app = create_router(Arc::clone(&state));

        // 第一次更新：body 只改名称 → 规则内容变化（`checkContent()` 只忽略
        // customOrder/enabled/enabledExplore/lastUpdateTime/respondTime/weight，
        // 名称参与指纹；批24 P1-2 起未出现的 search_url 保持原值）→ 重建状态
        let resp = app
            .clone()
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_url": key, "book_source_name": "新名" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let rebuilt = find_check_state(&state, key)
            .await
            .expect("更新后状态行仍在");
        assert_eq!(rebuilt.status, "NEEDS_CHECK");
        assert_ne!(
            rebuilt.revision, before.revision,
            "规则变化应生成新 revision"
        );

        // 第二次更新：提交完全相同的字段 → 内容不变 → 保留 revision
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_url": key, "book_source_name": "新名" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let kept = find_check_state(&state, key)
            .await
            .expect("二次更新后状态行仍在");
        assert_eq!(
            kept.revision, rebuilt.revision,
            "内容不变应保留状态 revision"
        );
        assert_eq!(kept.source_revision, rebuilt.source_revision);
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
        // （P1-1 起重复 URL POST 返回 409，此处用独立 URL 验证空串处理）
        let empty_url = "https://rest-rate-create-empty.example";
        let resp = app
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({
                    "book_source_url": empty_url,
                    "book_source_name": "无限速创建源",
                    "concurrent_rate": ""
                }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        assert!(
            find_source(&state, empty_url)
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

    /// P1-1：PUT path 不存在时返回 404（旧实现以默认实体 upsert）
    #[tokio::test]
    async fn test_update_source_unknown_path_returns_404() {
        let state = make_test_state();
        let key = "rest-rate-update-absent";
        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_url": key, "book_source_name": "不存在则不插入" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        assert!(
            find_source(&state, key).await.is_none(),
            "404 不得以默认实体写出新行"
        );
    }

    /// P1-1（关键数据丢失防护）：重复 URL POST → 409，且原行规则/jsLib/
    /// variable 等未暴露字段一个都不能少
    #[tokio::test]
    async fn test_create_source_conflict_preserves_existing_rules() {
        let state = make_test_state();
        let url = "https://rest-conflict-keep.example";
        let original = BookSource {
            book_source_url: url.to_string(),
            book_source_name: "原书源".to_string(),
            book_source_group: Some("原分组".to_string()),
            concurrent_rate: Some("1/10000".to_string()),
            js_lib: Some("js-lib-body".to_string()),
            header: Some("{\"X-Test\":\"1\"}".to_string()),
            variable: "user=login-token".to_string(),
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
        };
        seed_source(&state, original.clone()).await;

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({ "book_source_url": url, "book_source_name": "覆盖尝试" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CONFLICT);

        let found = find_source(&state, url).await.expect("原行必须仍在");
        assert_eq!(found.book_source_name, "原书源", "冲突请求不得改写名称");
        assert_eq!(found.book_source_group.as_deref(), Some("原分组"));
        assert_eq!(
            found.concurrent_rate.as_deref(),
            Some("1/10000"),
            "冲突请求不得清空 concurrentRate"
        );
        // 关键断言：旧实现（default + INSERT OR REPLACE）会把下列字段全部清空
        assert_eq!(found.js_lib.as_deref(), Some("js-lib-body"));
        assert_eq!(found.header.as_deref(), Some("{\"X-Test\":\"1\"}"));
        assert_eq!(found.variable, "user=login-token");
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
    }

    /// P1-1：PUT body URL 命中另一行 → 409，且目标行原值不被整行覆盖
    #[tokio::test]
    async fn test_update_source_body_url_collision_returns_409() {
        let state = make_test_state();
        let a = "https://rest-collision-a.example";
        let b = "https://rest-collision-b.example";
        seed_source(
            &state,
            BookSource {
                book_source_url: a.to_string(),
                book_source_name: "A".to_string(),
                js_lib: Some("a-js-lib".to_string()),
                ..BookSource::default()
            },
        )
        .await;
        seed_source(
            &state,
            BookSource {
                book_source_url: b.to_string(),
                book_source_name: "B".to_string(),
                variable: "b-login".to_string(),
                js_lib: Some("b-js-lib".to_string()),
                ..BookSource::default()
            },
        )
        .await;

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                "/api/sources/https%3A%2F%2Frest-collision-a.example",
                &json!({ "book_source_url": b, "book_source_name": "改到 B" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CONFLICT);

        let target = find_source(&state, b).await.expect("B 行仍在");
        assert_eq!(target.book_source_name, "B", "B 行不得被覆盖");
        assert_eq!(target.variable, "b-login", "B 的登录态不得被清空");
        assert_eq!(target.js_lib.as_deref(), Some("b-js-lib"));
        let origin = find_source(&state, a).await.expect("A 行仍在");
        assert_eq!(origin.book_source_name, "A", "A 行不得被改写");
    }

    // ── 批24 P1-2：PUT 部分更新（只写出现的键） ─────────────────────────

    /// 只传 name：分组/类型/启用状态/searchUrl/concurrentRate/variable 全部保留
    #[tokio::test]
    async fn test_update_source_only_name_keeps_other_fields() {
        let state = make_test_state();
        let key = "rest-partial-update-name";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "旧名".to_string(),
                book_source_group: Some("旧分组".to_string()),
                book_source_type: 3,
                enabled: false,
                search_url: Some("https://keep.example/search?q={key}".to_string()),
                concurrent_rate: Some("1/10000".to_string()),
                variable: "user=login-token".to_string(),
                js_lib: Some("js-lib-body".to_string()),
                ..BookSource::default()
            },
        )
        .await;

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_name": "新名" }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let found = find_source(&state, key).await.expect("行仍存在");
        assert_eq!(found.book_source_name, "新名");
        assert_eq!(
            found.book_source_group.as_deref(),
            Some("旧分组"),
            "缺键不得清空分组"
        );
        assert_eq!(found.book_source_type, 3, "缺键不得把类型重置为 0");
        assert!(!found.enabled, "缺键不得把停用源重新启用");
        assert_eq!(
            found.search_url.as_deref(),
            Some("https://keep.example/search?q={key}"),
            "缺键不得清空 searchUrl"
        );
        assert_eq!(found.concurrent_rate.as_deref(), Some("1/10000"));
        assert_eq!(found.variable, "user=login-token");
        assert_eq!(found.js_lib.as_deref(), Some("js-lib-body"));
    }

    /// 只传 enabled=false：名称/分组/searchUrl 等全部保留
    #[tokio::test]
    async fn test_update_source_only_enabled_keeps_other_fields() {
        let state = make_test_state();
        let key = "rest-partial-update-enabled";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "保留名称".to_string(),
                book_source_group: Some("保留分组".to_string()),
                book_source_type: 2,
                enabled: true,
                search_url: Some("https://keep.example/search?q={key}".to_string()),
                ..BookSource::default()
            },
        )
        .await;

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "enabled": false }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let found = find_source(&state, key).await.expect("行仍存在");
        assert!(!found.enabled);
        assert_eq!(found.book_source_name, "保留名称");
        assert_eq!(found.book_source_group.as_deref(), Some("保留分组"));
        assert_eq!(found.book_source_type, 2);
        assert_eq!(
            found.search_url.as_deref(),
            Some("https://keep.example/search?q={key}")
        );
    }

    /// 显式 null 才清空可空字段；未出现字段继续保留
    #[tokio::test]
    async fn test_update_source_explicit_null_clears_only_that_field() {
        let state = make_test_state();
        let key = "rest-partial-update-null";
        seed_source(
            &state,
            BookSource {
                book_source_url: key.to_string(),
                book_source_name: "旧名".to_string(),
                book_source_group: Some("旧分组".to_string()),
                search_url: Some("https://old.example/search?q={key}".to_string()),
                ..BookSource::default()
            },
        )
        .await;

        let app = create_router(Arc::clone(&state));
        let resp = app
            .oneshot(json_request(
                Method::PUT,
                &format!("/api/sources/{key}"),
                &json!({ "book_source_group": null, "search_url": null }),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let found = find_source(&state, key).await.expect("行仍存在");
        assert_eq!(found.book_source_name, "旧名", "未出现字段保持原值");
        assert_eq!(found.book_source_group, None, "显式 null 应清空分组");
        assert_eq!(found.search_url, None, "显式 null 应清空 searchUrl");
    }

    // ── P1-1：令牌前置守卫（生产入口同构） ──────────────────────────────

    /// 无令牌的 `POST /api/sources` 必须在读取请求体之前被拒：
    /// 3 MiB body（超过 axum 默认 2 MiB 上限）仍返回原版令牌失败信封，
    /// 而不是 413；且库内不得产生任何行。
    #[tokio::test]
    async fn test_source_rest_write_requires_token_before_reading_body() {
        let state = make_test_state();
        seed_config(&state, "config:jsSourceApiToken", "secret").await;
        let app =
            attach_source_write_token_guard(create_router(Arc::clone(&state)), Arc::clone(&state));
        let big = format!(
            "{{\"book_source_url\":\"https://guard.example\",\"padding\":\"{}\"}}",
            "x".repeat(3 * 1024 * 1024)
        );

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/sources")
                    .header("Content-Type", "application/json")
                    .body(Body::from(big))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "守卫应在 body 提取前拒绝（不能是 413）"
        );
        assert_eq!(
            resp.headers()
                .get(axum::http::header::CONNECTION)
                .and_then(|v| v.to_str().ok()),
            Some("close"),
            "令牌失败应关闭连接（原版 shouldCloseConnection）"
        );
        let body = response_json(resp).await;
        assert_eq!(body["isSuccess"], false, "{body}");
        assert_eq!(body["errorMsg"], TOKEN_ERROR, "{body}");
        assert!(
            find_source(&state, "https://guard.example").await.is_none(),
            "未授权请求不得落库"
        );

        // PUT/DELETE /api/sources/{id} 同样受令牌面保护（未命中行也先拒令牌）
        for method in [Method::PUT, Method::DELETE] {
            let resp = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method(method.clone())
                        .uri("/api/sources/https%3A%2F%2Fguard.example")
                        .header("Content-Type", "application/json")
                        .body(Body::from(
                            r#"{"book_source_url":"https://guard.example","book_source_name":"x"}"#,
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK, "{method}");
            let body = response_json(resp).await;
            assert_eq!(body["errorMsg"], TOKEN_ERROR, "{method} {body}");
        }
    }

    /// 带正确令牌后写面正常；GET 读取面保持免令牌
    #[tokio::test]
    async fn test_source_rest_read_public_and_write_with_token() {
        let state = make_test_state();
        seed_config(&state, "config:jsSourceApiToken", "secret").await;
        let app =
            attach_source_write_token_guard(create_router(Arc::clone(&state)), Arc::clone(&state));

        // 无令牌 POST → 拒绝
        let resp = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/api/sources",
                &json!({ "book_source_url": "https://token-write.example", "book_source_name": "带令牌" }),
            ))
            .await
            .unwrap();
        let body = response_json(resp).await;
        assert_eq!(body["errorMsg"], TOKEN_ERROR, "{body}");

        // 带令牌 POST → 201
        let resp = app
            .clone()
            .oneshot(json_request_with_token(
                Method::POST,
                "/api/sources",
                &json!({ "book_source_url": "https://token-write.example", "book_source_name": "带令牌" }),
                Some("secret"),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        assert!(find_source(&state, "https://token-write.example")
            .await
            .is_some());

        // GET /api/sources 不在令牌面内（读取面保持原行为）
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
}
