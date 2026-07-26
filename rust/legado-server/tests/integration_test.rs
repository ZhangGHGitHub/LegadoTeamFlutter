//! legado-server 集成测试
//! 启动真实 HTTP 服务 → 发送请求 → 验证响应

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use serde_json::json;
use tokio::sync::Mutex;
use tower::ServiceExt;

use legado_core::download_manager::DownloadManager;
use legado_server::routes::create_router;
use legado_server::state::AppState;

/// 测试辅助：构建共享状态（内存数据库）
fn make_test_state() -> Arc<AppState> {
    let db = legado_db::init_in_memory_database().unwrap();
    Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
    })
}

// ---------------------------------------------------------------------------
// 健康检查
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_health_endpoint() {
    let state = make_test_state();
    let app = create_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["status"], "ok");
    assert_eq!(json["service"], "legado-server");
    assert!(json.get("version").is_some());
}

// ---------------------------------------------------------------------------
// 书架 CRUD 完整流程
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_bookshelf_crud() {
    let state = make_test_state();
    let app = create_router(state);

    // 1. POST /api/books — 添加书籍
    let create_body = serde_json::to_string(&json!({
        "book_url": "https://example.com/integration-book",
        "name": "集成测试书籍",
        "author": "测试作者"
    }))
    .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/books")
                .header("Content-Type", "application/json")
                .body(Body::from(create_body))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let book: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(book["name"], "集成测试书籍");
    assert_eq!(book["author"], "测试作者");

    // 2. GET /api/books — 获取书籍列表
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/books")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let list: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(list["total"], 1);
    assert_eq!(list["books"][0]["name"], "集成测试书籍");

    // 3. GET /api/books/:id — 获取单本书籍（URL 编码）
    let encoded_url = urlencoding::encode("https://example.com/integration-book");
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/books/{encoded_url}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let detail: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(detail["name"], "集成测试书籍");

    // 4. PUT /api/books/:id — 更新书籍信息
    let update_body = serde_json::to_string(&json!({
        "book_url": "https://example.com/integration-book",
        "name": "更新后书名",
        "author": "新作者"
    }))
    .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::PUT)
                .uri(format!("/api/books/{encoded_url}"))
                .header("Content-Type", "application/json")
                .body(Body::from(update_body))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let updated: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(updated["name"], "更新后书名");
    assert_eq!(updated["author"], "新作者");

    // 5. DELETE /api/books/:id — 删除书籍
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::DELETE)
                .uri(format!("/api/books/{encoded_url}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let deleted: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(deleted["deleted"], true);

    // 6. 验证删除后列表为空
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/books")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let list: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(list["total"], 0);
}

// ---------------------------------------------------------------------------
// 搜索端点
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_search_endpoint() {
    let state = make_test_state();

    // 先插入测试数据
    {
        let db = state.db.lock().await;
        let repo = legado_db::repository::book_repository::BookRepository::new(db.connection());
        use legado_core::models::Book;
        use legado_db::repository::Repository;
        repo.insert(&Book {
            book_url: "u1".to_string(),
            name: "三体".to_string(),
            author: "刘慈欣".to_string(),
            ..Book::default()
        })
        .unwrap();
        repo.insert(&Book {
            book_url: "u2".to_string(),
            name: "活着".to_string(),
            author: "余华".to_string(),
            ..Book::default()
        })
        .unwrap();
    }

    let app = create_router(state);

    // POST /api/search — 搜索"三体"
    let search_body = serde_json::to_string(&json!({
        "keyword": "三体"
    }))
    .unwrap();

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/search")
                .header("Content-Type", "application/json")
                .body(Body::from(search_body))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let result: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(result["total"], 1);
    assert_eq!(result["keyword"], "三体");
    let results = result["results"].as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["name"], "三体");
    assert_eq!(results[0]["author"], "刘慈欣");
}

// ---------------------------------------------------------------------------
// 未知路由返回 404
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_unknown_route_returns_404() {
    let state = make_test_state();
    let app = create_router(state);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/nonexistent")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
