//! 阅读统计 API
//!
//! 提供今日统计、每日统计、书籍统计、热力图等端点。

use axum::extract::{Query, State};
use axum::Json;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

use legado_db::repository::reading_stats_repository::ReadingStatsRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// 获取当前 UTC 时间的今日零点毫秒时间戳
fn today_start_ms() -> i64 {
    // 使用 SystemTime 获取当前时间
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs() as i64;
    // 对齐到 UTC 零点
    let day_secs = secs - (secs % 86400);
    day_secs * 1000
}

/// GET /api/stats/today — 今日阅读统计
pub async fn get_today_stats(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = ReadingStatsRepository::new(db.connection());

    let start = today_start_ms();
    let end = start + 86_400_000; // 今日结束

    let sessions = repo.get_sessions_by_date_range(start, end)?;

    let total_time_ms: i64 = sessions
        .iter()
        .map(|s| s.end_time.map(|e| (e - s.start_time).max(0)).unwrap_or(0))
        .sum();
    let total_words: i64 = sessions.iter().map(|s| s.word_count as i64).sum();
    let session_count = sessions.len();

    let mut books: Vec<String> = sessions.iter().map(|s| s.book_url.clone()).collect();
    books.sort();
    books.dedup();

    Ok(Json(json!({
        "total_time_ms": total_time_ms,
        "total_words": total_words,
        "session_count": session_count,
        "books_read": books,
    })))
}

/// GET /api/stats/daily?days=7 — 每日阅读统计
pub async fn get_daily_stats(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let days: i32 = params
        .get("days")
        .and_then(|d| d.parse().ok())
        .unwrap_or(7)
        .clamp(1, 365);

    let db = state.db.lock().await;
    let repo = ReadingStatsRepository::new(db.connection());

    let summaries = repo.get_daily_summaries(days)?;

    Ok(Json(json!({
        "days": days,
        "summaries": summaries,
    })))
}

/// GET /api/stats/books — 各书籍阅读统计
pub async fn get_books_stats(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = ReadingStatsRepository::new(db.connection());

    // 获取所有会话（使用大范围查询）
    let sessions = repo.get_sessions_by_date_range(0, i64::MAX)?;

    // 按书籍分组
    let mut book_map: HashMap<String, Vec<&legado_core::reading_stats::ReadingSession>> =
        HashMap::new();
    for session in &sessions {
        book_map.entry(session.book_url.clone()).or_default().push(session);
    }

    let books_stats: Vec<Value> = book_map
        .iter()
        .map(|(book_url, book_sessions)| {
            let total_time_ms: i64 = book_sessions
                .iter()
                .map(|s| s.end_time.map(|e| (e - s.start_time).max(0)).unwrap_or(0))
                .sum();
            let total_words: i64 = book_sessions.iter().map(|s| s.word_count as i64).sum();
            let session_count = book_sessions.len();

            json!({
                "book_url": book_url,
                "total_time_ms": total_time_ms,
                "total_words": total_words,
                "session_count": session_count,
            })
        })
        .collect();

    Ok(Json(json!({
        "books": books_stats,
        "total": books_stats.len(),
    })))
}

/// GET /api/stats/heatmap?days=30 — 阅读热力图
pub async fn get_heatmap(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let days: i32 = params
        .get("days")
        .and_then(|d| d.parse().ok())
        .unwrap_or(30)
        .clamp(1, 365);

    let db = state.db.lock().await;
    let repo = ReadingStatsRepository::new(db.connection());

    let summaries = repo.get_daily_summaries(days)?;

    // 转换为热力图格式：[{ date, time_ms }]
    let heatmap: Vec<Value> = summaries
        .iter()
        .map(|s| {
            json!({
                "date": s.date,
                "time_ms": s.total_time_ms,
            })
        })
        .collect();

    Ok(Json(json!({
        "days": days,
        "heatmap": heatmap,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn make_test_router() -> axum::Router {
        let db = legado_db::init_in_memory_database().unwrap();
        let state = Arc::new(AppState {
            db: tokio::sync::Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        });
        crate::routes::create_router(state)
    }

    #[tokio::test]
    async fn test_stats_today_endpoint() {
        let app = make_test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/stats/today")
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
        assert!(json.get("total_time_ms").is_some());
        assert!(json.get("total_words").is_some());
        assert!(json.get("session_count").is_some());
        assert!(json.get("books_read").is_some());
    }

    #[tokio::test]
    async fn test_stats_daily_endpoint() {
        let app = make_test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/stats/daily?days=7")
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
        assert_eq!(json["days"], 7);
        assert!(json.get("summaries").is_some());
    }

    #[tokio::test]
    async fn test_stats_daily_default_days() {
        let app = make_test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/stats/daily")
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
        assert_eq!(json["days"], 7); // 默认 7 天
    }

    #[tokio::test]
    async fn test_stats_books_endpoint() {
        let app = make_test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/stats/books")
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
        assert!(json.get("books").is_some());
        assert!(json.get("total").is_some());
    }

    #[tokio::test]
    async fn test_stats_heatmap_endpoint() {
        let app = make_test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/stats/heatmap?days=30")
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
        assert_eq!(json["days"], 30);
        assert!(json.get("heatmap").is_some());
    }

    #[tokio::test]
    async fn test_stats_heatmap_default_days() {
        let app = make_test_router();
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/stats/heatmap")
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
        assert_eq!(json["days"], 30); // 默认 30 天
    }

    #[test]
    fn test_today_start_ms_alignment() {
        let start = today_start_ms();
        // 应该是 86400000 的整数倍（UTC 零点对齐）
        assert_eq!(start % 86_400_000, 0);
    }
}
