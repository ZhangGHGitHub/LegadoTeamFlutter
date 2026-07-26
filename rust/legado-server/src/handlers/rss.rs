//! RSS 文章获取端点
//!
//! 参考 Kotlin 实现 `RssSource.kt`，通过 `legado_net::rss` 解析 RSS/Atom Feed。

use axum::extract::{Path, State};
use axum::Json;
use serde::Serialize;
use std::sync::Arc;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::LegadoError;
use legado_net::rss::{fetch_feed, RssFeed};

/// RSS 源信息 + 文章列表
#[derive(Debug, Serialize)]
pub struct RssSourceResponse {
    pub feed: RssFeed,
}

/// GET /api/rss/articles — 获取 RSS 文章列表
///
/// 请求体为 JSON `{ "url": "https://..." }`。
pub async fn get_articles(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<RssFetchRequest>,
) -> Result<Json<RssFeed>, ApiError> {
    let client = legado_net::LegadoClient::new(Default::default()).map_err(ApiError)?;

    let feed = fetch_feed(&req.url, &client).await.map_err(ApiError)?;

    Ok(Json(feed))
}

/// GET /api/rss/{source_url}/articles — 通过路径参数获取 RSS 文章
///
/// `source_url` 为 URL 编码的 RSS 源地址。
pub async fn get_articles_by_path(
    State(_state): State<Arc<AppState>>,
    Path(encoded_url): Path<String>,
) -> Result<Json<RssFeed>, ApiError> {
    let url = urlencoding::decode(&encoded_url)
        .map_err(|e| ApiError(LegadoError::Parser(format!("Invalid URL encoding: {}", e))))?;

    let client = legado_net::LegadoClient::new(Default::default()).map_err(ApiError)?;

    let feed = fetch_feed(&url, &client).await.map_err(ApiError)?;

    Ok(Json(feed))
}

/// RSS 抓取请求体
#[derive(Debug, serde::Deserialize)]
pub struct RssFetchRequest {
    pub url: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rss_fetch_request_deserialize() {
        let json = r#"{"url": "https://example.com/feed.xml"}"#;
        let req: RssFetchRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.url, "https://example.com/feed.xml");
    }

    #[test]
    fn test_rss_source_response_serialize() {
        let feed = RssFeed {
            title: "Test Feed".to_string(),
            link: "https://example.com".to_string(),
            description: Some("A test feed".to_string()),
            articles: vec![legado_net::rss::RssArticle {
                title: "Article 1".to_string(),
                link: "https://example.com/1".to_string(),
                description: Some("First article".to_string()),
                pub_date: None,
                author: None,
                image_url: None,
                content: None,
                categories: vec![],
            }],
        };
        let resp = RssSourceResponse { feed };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("Test Feed"));
        assert!(json.contains("Article 1"));
    }

    #[test]
    fn test_url_decode_for_path() {
        let encoded = urlencoding::encode("https://example.com/feed.xml");
        let decoded = urlencoding::decode(&encoded).unwrap();
        assert_eq!(decoded, "https://example.com/feed.xml");
    }
}
