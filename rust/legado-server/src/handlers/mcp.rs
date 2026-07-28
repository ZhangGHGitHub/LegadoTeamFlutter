//! MCP (Model Context Protocol) Server
//!
//! 暴露书架/搜索/阅读能力给 AI 助手。
//! 基于 JSON-RPC 2.0 协议。

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::state::AppState;
use legado_db::repository::Repository;

/// JSON-RPC 请求
#[derive(Debug, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub method: String,
    pub params: Option<serde_json::Value>,
    pub id: Option<serde_json::Value>,
}

/// JSON-RPC 响应
#[derive(Debug, Serialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub result: Option<serde_json::Value>,
    pub error: Option<JsonRpcError>,
    pub id: Option<serde_json::Value>,
}

/// JSON-RPC 错误对象
#[derive(Debug, Serialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
}

/// MCP 工具定义
#[derive(Debug, Clone, Serialize)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

/// 列出所有可用 MCP 工具（共 12 个）
pub fn list_tools() -> Vec<McpTool> {
    vec![
        McpTool {
            name: "search_books".to_string(),
            description: "Search for books by name or author across all enabled sources"
                .to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Search query (book name or author)" },
                    "source_urls": { "type": "array", "items": { "type": "string" }, "description": "Optional: specific source URLs to search" }
                },
                "required": ["query"]
            }),
        },
        McpTool {
            name: "get_chapters".to_string(),
            description: "Get chapter list for a book from a specific source".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "book_url": { "type": "string" },
                    "source_url": { "type": "string" }
                },
                "required": ["book_url"]
            }),
        },
        McpTool {
            name: "read_chapter".to_string(),
            description: "Read the content of a specific chapter".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "chapter_url": { "type": "string" },
                    "source_url": { "type": "string" }
                },
                "required": ["chapter_url"]
            }),
        },
        McpTool {
            name: "get_bookshelf".to_string(),
            description: "Get all books on the bookshelf".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpTool {
            name: "add_to_bookshelf".to_string(),
            description: "Add a book to the bookshelf".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "book_url": { "type": "string" },
                    "book_name": { "type": "string" },
                    "author": { "type": "string" },
                    "source_url": { "type": "string" }
                },
                "required": ["book_url", "book_name", "source_url"]
            }),
        },
        McpTool {
            name: "list_sources".to_string(),
            description: "List all book sources".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "enabled_only": { "type": "boolean", "description": "If true, only return enabled sources" }
                }
            }),
        },
        McpTool {
            name: "get_source".to_string(),
            description: "Get details of a single book source by URL".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "source_url": { "type": "string", "description": "The book source URL" }
                },
                "required": ["source_url"]
            }),
        },
        McpTool {
            name: "update_source".to_string(),
            description: "Update a book source configuration".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "source_url": { "type": "string", "description": "The book source URL to update" },
                    "name": { "type": "string", "description": "New source name" },
                    "enabled": { "type": "boolean", "description": "Enable or disable the source" },
                    "group": { "type": "string", "description": "Source group" }
                },
                "required": ["source_url"]
            }),
        },
        McpTool {
            name: "get_reading_progress".to_string(),
            description: "Get reading progress for a book".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "book_url": { "type": "string", "description": "The book URL" }
                },
                "required": ["book_url"]
            }),
        },
        McpTool {
            name: "get_bookmarks".to_string(),
            description: "Get bookmarks, optionally filtered by book name".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "book_name": { "type": "string", "description": "Optional: filter by book name" }
                }
            }),
        },
        McpTool {
            name: "add_bookmark".to_string(),
            description: "Add a bookmark".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "book_name": { "type": "string" },
                    "book_author": { "type": "string" },
                    "chapter_index": { "type": "integer" },
                    "chapter_pos": { "type": "integer" },
                    "chapter_name": { "type": "string" },
                    "book_text": { "type": "string", "description": "The highlighted text" },
                    "content": { "type": "string", "description": "Bookmark note" }
                },
                "required": ["book_name", "chapter_index", "book_text"]
            }),
        },
        McpTool {
            name: "get_replace_rules".to_string(),
            description: "Get all replace rules".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "enabled_only": { "type": "boolean", "description": "If true, only return enabled rules" }
                }
            }),
        },
    ]
}

/// GET /mcp/tools — 列出可用工具
pub async fn get_tools() -> Json<Vec<McpTool>> {
    Json(list_tools())
}

/// POST /mcp/call — 调用工具（JSON-RPC 2.0）
pub async fn call_tool(
    State(state): State<Arc<AppState>>,
    Json(req): Json<JsonRpcRequest>,
) -> Json<JsonRpcResponse> {
    let result = match req.method.as_str() {
        "tools/list" => Ok(serde_json::to_value(list_tools()).unwrap()),
        "tools/call" => {
            if let Some(params) = &req.params {
                let tool_name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
                let arguments = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);

                match tool_name {
                    "search_books" => call_search_books(&state, &arguments).await,
                    "get_chapters" => call_get_chapters(&state, &arguments).await,
                    "read_chapter" => call_read_chapter(&state, &arguments).await,
                    "get_bookshelf" => call_get_bookshelf(&state).await,
                    "add_to_bookshelf" => call_add_to_bookshelf(&state, &arguments).await,
                    "list_sources" => call_list_sources(&state, &arguments).await,
                    "get_source" => call_get_source(&state, &arguments).await,
                    "update_source" => call_update_source(&state, &arguments).await,
                    "get_reading_progress" => call_get_reading_progress(&state, &arguments).await,
                    "get_bookmarks" => call_get_bookmarks(&state, &arguments).await,
                    "add_bookmark" => call_add_bookmark(&state, &arguments).await,
                    "get_replace_rules" => call_get_replace_rules(&state, &arguments).await,
                    _ => Err(JsonRpcError {
                        code: -32601,
                        message: format!("Unknown tool: {}", tool_name),
                    }),
                }
            } else {
                Err(JsonRpcError {
                    code: -32602,
                    message: "Missing params".to_string(),
                })
            }
        }
        _ => Err(JsonRpcError {
            code: -32601,
            message: format!("Unknown method: {}", req.method),
        }),
    };

    match result {
        Ok(value) => Json(JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            result: Some(value),
            error: None,
            id: req.id,
        }),
        Err(err) => Json(JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            result: None,
            error: Some(err),
            id: req.id,
        }),
    }
}

// ─── 辅助函数 ─────────────────────────────────────────────

/// 将结果序列化为 MCP content 格式
fn mcp_text(text: String) -> serde_json::Value {
    serde_json::json!({
        "content": [{"type": "text", "text": text}]
    })
}

/// 将错误转换为 JsonRpcError
fn db_err(e: legado_core::LegadoError) -> JsonRpcError {
    JsonRpcError {
        code: -32000,
        message: format!("Database error: {e}"),
    }
}

// ─── 工具实现 ─────────────────────────────────────────────

/// 搜索书籍：在书架中按名称/作者模糊搜索
async fn call_search_books(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let query = args.get("query").and_then(|v| v.as_str()).unwrap_or("");
    if query.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "query parameter is required".to_string(),
        });
    }

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookRepository::new(conn);

    let all_books = repo.find_all().map_err(db_err)?;
    let query_lower = query.to_lowercase();
    let matched: Vec<&legado_core::models::Book> = all_books
        .iter()
        .filter(|b| {
            b.name.to_lowercase().contains(&query_lower)
                || b.author.to_lowercase().contains(&query_lower)
        })
        .collect();

    let results: Vec<serde_json::Value> = matched
        .iter()
        .map(|b| {
            serde_json::json!({
                "book_url": b.book_url,
                "name": b.name,
                "author": b.author,
                "origin": b.origin,
                "latest_chapter": b.latest_chapter_title,
            })
        })
        .collect();

    let text = if results.is_empty() {
        format!("No books found matching: {}", query)
    } else {
        serde_json::to_string_pretty(&results).unwrap_or_default()
    };

    Ok(mcp_text(text))
}

/// 获取章节列表：查询 chapters 表
async fn call_get_chapters(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let book_url = args.get("book_url").and_then(|v| v.as_str()).unwrap_or("");
    if book_url.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "book_url parameter is required".to_string(),
        });
    }

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookChapterRepository::new(conn);

    let chapters = repo.find_by_book_url(book_url).map_err(db_err)?;

    let results: Vec<serde_json::Value> = chapters
        .iter()
        .map(|ch| {
            serde_json::json!({
                "index": ch.index,
                "title": ch.title,
                "url": ch.url,
                "is_volume": ch.is_volume,
            })
        })
        .collect();

    let text = if results.is_empty() {
        format!("No chapters found for book: {}", book_url)
    } else {
        serde_json::to_string_pretty(&results).unwrap_or_default()
    };

    Ok(mcp_text(text))
}

/// 阅读章节内容：从缓存中读取
async fn call_read_chapter(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let chapter_url = args
        .get("chapter_url")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if chapter_url.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "chapter_url parameter is required".to_string(),
        });
    }

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::CacheBookRepository::new(conn);

    match repo.get_by_chapter_url(chapter_url).map_err(db_err)? {
        Some(cached) => {
            let text = format!("【{}】\n\n{}", cached.chapter_title, cached.content);
            Ok(mcp_text(text))
        }
        None => Ok(mcp_text(format!(
            "Chapter content not cached: {}",
            chapter_url
        ))),
    }
}

/// 获取书架：查询 books 表所有书籍
async fn call_get_bookshelf(state: &AppState) -> Result<serde_json::Value, JsonRpcError> {
    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookRepository::new(conn);

    let books = repo.find_all().map_err(db_err)?;

    let results: Vec<serde_json::Value> = books
        .iter()
        .map(|b| {
            serde_json::json!({
                "book_url": b.book_url,
                "name": b.name,
                "author": b.author,
                "origin": b.origin,
                "total_chapters": b.total_chapter_num,
                "latest_chapter": b.latest_chapter_title,
                "dur_chapter_index": b.dur_chapter_index,
                "dur_chapter_title": b.dur_chapter_title,
            })
        })
        .collect();

    let text = if results.is_empty() {
        "Bookshelf is empty".to_string()
    } else {
        serde_json::to_string_pretty(&results).unwrap_or_default()
    };

    Ok(mcp_text(text))
}

/// 添加到书架：INSERT 到 books 表
async fn call_add_to_bookshelf(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let book_url = args.get("book_url").and_then(|v| v.as_str()).unwrap_or("");
    let book_name = args
        .get("book_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let author = args.get("author").and_then(|v| v.as_str()).unwrap_or("");
    let source_url = args
        .get("source_url")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if book_url.is_empty() || book_name.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "book_url and book_name are required".to_string(),
        });
    }

    let book = legado_core::models::Book {
        book_url: book_url.to_string(),
        name: book_name.to_string(),
        author: author.to_string(),
        origin: source_url.to_string(),
        ..legado_core::models::Book::default()
    };

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookRepository::new(conn);
    repo.insert(&book).map_err(db_err)?;

    Ok(mcp_text(format!(
        "Book '{}' added to bookshelf successfully",
        book_name
    )))
}

/// 列出所有书源
async fn call_list_sources(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let enabled_only = args
        .get("enabled_only")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookSourceRepository::new(conn);

    let sources = if enabled_only {
        repo.find_enabled().map_err(db_err)?
    } else {
        repo.find_all().map_err(db_err)?
    };

    let results: Vec<serde_json::Value> = sources
        .iter()
        .map(|s| {
            serde_json::json!({
                "url": s.book_source_url,
                "name": s.book_source_name,
                "group": s.book_source_group,
                "type": s.book_source_type,
                "enabled": s.enabled,
            })
        })
        .collect();

    let text = if results.is_empty() {
        "No book sources found".to_string()
    } else {
        serde_json::to_string_pretty(&results).unwrap_or_default()
    };

    Ok(mcp_text(text))
}

/// 获取单个书源详情
async fn call_get_source(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let source_url = args
        .get("source_url")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if source_url.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "source_url parameter is required".to_string(),
        });
    }

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookSourceRepository::new(conn);

    match repo.find_by_url(source_url).map_err(db_err)? {
        Some(source) => {
            let json = serde_json::to_string_pretty(&source).unwrap_or_default();
            Ok(mcp_text(json))
        }
        None => Ok(mcp_text(format!("Source not found: {}", source_url))),
    }
}

/// 更新书源配置
async fn call_update_source(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let source_url = args
        .get("source_url")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if source_url.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "source_url parameter is required".to_string(),
        });
    }

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookSourceRepository::new(conn);

    let mut source = repo
        .find_by_url(source_url)
        .map_err(db_err)?
        .ok_or_else(|| JsonRpcError {
            code: -32000,
            message: format!("Source not found: {}", source_url),
        })?;

    if let Some(name) = args.get("name").and_then(|v| v.as_str()) {
        source.book_source_name = name.to_string();
    }
    if let Some(enabled) = args.get("enabled").and_then(|v| v.as_bool()) {
        source.enabled = enabled;
    }
    if let Some(group) = args.get("group").and_then(|v| v.as_str()) {
        source.book_source_group = Some(group.to_string());
    }

    repo.update(&source).map_err(db_err)?;

    Ok(mcp_text(format!(
        "Source '{}' updated successfully",
        source.book_source_name
    )))
}

/// 获取阅读进度
async fn call_get_reading_progress(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let book_url = args.get("book_url").and_then(|v| v.as_str()).unwrap_or("");
    if book_url.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "book_url parameter is required".to_string(),
        });
    }

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookRepository::new(conn);

    match repo.find_by_url(book_url).map_err(db_err)? {
        Some(book) => {
            let progress = serde_json::json!({
                "book_url": book.book_url,
                "name": book.name,
                "author": book.author,
                "dur_chapter_index": book.dur_chapter_index,
                "dur_chapter_title": book.dur_chapter_title,
                "dur_chapter_pos": book.dur_chapter_pos,
                "total_chapters": book.total_chapter_num,
                "latest_chapter_title": book.latest_chapter_title,
            });
            Ok(mcp_text(
                serde_json::to_string_pretty(&progress).unwrap_or_default(),
            ))
        }
        None => Ok(mcp_text(format!("Book not found: {}", book_url))),
    }
}

/// 获取书签列表
async fn call_get_bookmarks(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let book_name = args.get("book_name").and_then(|v| v.as_str());

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookmarkRepository::new(conn);

    let bookmarks = match book_name {
        Some(name) if !name.is_empty() => repo.get_by_book(name).map_err(db_err)?,
        _ => repo.find_all().map_err(db_err)?,
    };

    let results: Vec<serde_json::Value> = bookmarks
        .iter()
        .map(|bm| {
            serde_json::json!({
                "id": bm.id,
                "book_name": bm.book_name,
                "book_author": bm.book_author,
                "chapter_index": bm.chapter_index,
                "chapter_name": bm.chapter_name,
                "book_text": bm.book_text,
                "content": bm.content,
                "time": bm.time,
            })
        })
        .collect();

    let text = if results.is_empty() {
        "No bookmarks found".to_string()
    } else {
        serde_json::to_string_pretty(&results).unwrap_or_default()
    };

    Ok(mcp_text(text))
}

/// 添加书签
async fn call_add_bookmark(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let book_name = args
        .get("book_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if book_name.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "book_name parameter is required".to_string(),
        });
    }

    let book_text = args
        .get("book_text")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if book_text.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "book_text parameter is required".to_string(),
        });
    }

    let bookmark = legado_core::models::Bookmark {
        book_name: book_name.to_string(),
        book_author: args
            .get("book_author")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        chapter_index: args
            .get("chapter_index")
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32,
        chapter_pos: args
            .get("chapter_pos")
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32,
        chapter_name: args
            .get("chapter_name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        book_text: book_text.to_string(),
        content: args
            .get("content")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        time: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
        ..legado_core::models::Bookmark::default()
    };

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookmarkRepository::new(conn);

    let id = repo.insert(&bookmark).map_err(db_err)?;

    Ok(mcp_text(format!(
        "Bookmark added successfully (id: {})",
        id
    )))
}

/// 获取替换规则
async fn call_get_replace_rules(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let enabled_only = args
        .get("enabled_only")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::ReplaceRuleRepository::new(conn);

    let rules = if enabled_only {
        repo.get_enabled_rules().map_err(db_err)?
    } else {
        repo.find_all().map_err(db_err)?
    };

    let results: Vec<serde_json::Value> = rules
        .iter()
        .map(|r| {
            serde_json::json!({
                "id": r.id,
                "name": r.name,
                "group": r.group,
                "pattern": r.pattern,
                "replacement": r.replacement,
                "is_enabled": r.is_enabled,
                "is_regex": r.is_regex,
                "scope": r.scope,
            })
        })
        .collect();

    let text = if results.is_empty() {
        "No replace rules found".to_string()
    } else {
        serde_json::to_string_pretty(&results).unwrap_or_default()
    };

    Ok(mcp_text(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: Mutex::new(legado_core::download_manager::DownloadManager::new(3)),
        })
    }

    #[test]
    fn test_list_tools_count() {
        let tools = list_tools();
        assert_eq!(tools.len(), 12);
    }

    #[test]
    fn test_list_tools_names() {
        let tools = list_tools();
        let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        assert!(names.contains(&"search_books"));
        assert!(names.contains(&"get_chapters"));
        assert!(names.contains(&"read_chapter"));
        assert!(names.contains(&"get_bookshelf"));
        assert!(names.contains(&"add_to_bookshelf"));
        assert!(names.contains(&"list_sources"));
        assert!(names.contains(&"get_source"));
        assert!(names.contains(&"update_source"));
        assert!(names.contains(&"get_reading_progress"));
        assert!(names.contains(&"get_bookmarks"));
        assert!(names.contains(&"add_bookmark"));
        assert!(names.contains(&"get_replace_rules"));
    }

    #[test]
    fn test_tool_input_schema_has_required() {
        let tools = list_tools();
        let search_tool = tools.iter().find(|t| t.name == "search_books").unwrap();
        let required = search_tool.input_schema.get("required").unwrap();
        assert!(required
            .as_array()
            .unwrap()
            .contains(&serde_json::json!("query")));
    }

    #[tokio::test]
    async fn test_get_tools_handler() {
        let resp = get_tools().await;
        assert_eq!(resp.0.len(), 12);
    }

    #[tokio::test]
    async fn test_call_tool_tools_list() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/list".to_string(),
            params: None,
            id: Some(serde_json::json!(1)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert_eq!(resp.0.jsonrpc, "2.0");
        assert!(resp.0.result.is_some());
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        assert_eq!(result.as_array().unwrap().len(), 12);
    }

    #[tokio::test]
    async fn test_call_tool_get_bookshelf_empty() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_bookshelf",
                "arguments": {}
            })),
            id: Some(serde_json::json!(5)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("empty"));
    }

    #[tokio::test]
    async fn test_call_tool_add_and_get_bookshelf() {
        let state = make_test_state();

        // Add a book
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "add_to_bookshelf",
                "arguments": { "book_url": "https://example.com/b1", "book_name": "斗破苍穹", "author": "天蚕土豆", "source_url": "https://src.com" }
            })),
            id: Some(serde_json::json!(1)),
        };
        let resp = call_tool(State(state.clone()), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("斗破苍穹"));

        // Get bookshelf
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_bookshelf",
                "arguments": {}
            })),
            id: Some(serde_json::json!(2)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("斗破苍穹"));
        assert!(text.contains("天蚕土豆"));
    }

    #[tokio::test]
    async fn test_call_tool_search_books() {
        let state = make_test_state();

        // Add a book first
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "add_to_bookshelf",
                "arguments": { "book_url": "https://example.com/b1", "book_name": "斗破苍穹", "author": "天蚕土豆", "source_url": "https://src.com" }
            })),
            id: Some(serde_json::json!(1)),
        };
        let _ = call_tool(State(state.clone()), Json(req)).await;

        // Search
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "search_books",
                "arguments": { "query": "斗破苍穹" }
            })),
            id: Some(serde_json::json!(2)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("斗破苍穹"));
    }

    #[tokio::test]
    async fn test_call_tool_search_books_no_results() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "search_books",
                "arguments": { "query": "不存在的书" }
            })),
            id: Some(serde_json::json!(2)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("No books found"));
    }

    #[tokio::test]
    async fn test_call_tool_get_chapters_empty() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_chapters",
                "arguments": { "book_url": "https://example.com/book1" }
            })),
            id: Some(serde_json::json!(3)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("No chapters found"));
    }

    #[tokio::test]
    async fn test_call_tool_read_chapter_not_cached() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "read_chapter",
                "arguments": { "chapter_url": "https://example.com/ch1" }
            })),
            id: Some(serde_json::json!(4)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("not cached"));
    }

    #[tokio::test]
    async fn test_call_tool_list_sources_empty() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "list_sources",
                "arguments": {}
            })),
            id: Some(serde_json::json!(10)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("No book sources"));
    }

    #[tokio::test]
    async fn test_call_tool_get_source_not_found() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_source",
                "arguments": { "source_url": "https://nonexistent.com" }
            })),
            id: Some(serde_json::json!(11)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("not found"));
    }

    #[tokio::test]
    async fn test_call_tool_update_source_not_found() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "update_source",
                "arguments": { "source_url": "https://nonexistent.com", "name": "new" }
            })),
            id: Some(serde_json::json!(12)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_some());
        let err = resp.0.error.unwrap();
        assert_eq!(err.code, -32000);
    }

    #[tokio::test]
    async fn test_call_tool_get_reading_progress_not_found() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_reading_progress",
                "arguments": { "book_url": "https://nonexistent.com" }
            })),
            id: Some(serde_json::json!(13)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("not found"));
    }

    #[tokio::test]
    async fn test_call_tool_get_bookmarks_empty() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_bookmarks",
                "arguments": {}
            })),
            id: Some(serde_json::json!(14)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("No bookmarks"));
    }

    #[tokio::test]
    async fn test_call_tool_add_bookmark() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "add_bookmark",
                "arguments": {
                    "book_name": "Test Book",
                    "chapter_index": 0,
                    "book_text": "some highlighted text",
                    "content": "my note"
                }
            })),
            id: Some(serde_json::json!(15)),
        };
        let resp = call_tool(State(state.clone()), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("Bookmark added"));

        // Verify it exists
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_bookmarks",
                "arguments": { "book_name": "Test Book" }
            })),
            id: Some(serde_json::json!(16)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("some highlighted text"));
    }

    #[tokio::test]
    async fn test_call_tool_get_replace_rules_empty() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_replace_rules",
                "arguments": {}
            })),
            id: Some(serde_json::json!(17)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("No replace rules"));
    }

    #[tokio::test]
    async fn test_call_tool_unknown_method() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "nonexistent/method".to_string(),
            params: None,
            id: Some(serde_json::json!(7)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.result.is_none());
        let err = resp.0.error.unwrap();
        assert_eq!(err.code, -32601);
        assert!(err.message.contains("Unknown method"));
    }

    #[tokio::test]
    async fn test_call_tool_unknown_tool() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "nonexistent_tool",
                "arguments": {}
            })),
            id: Some(serde_json::json!(8)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.result.is_none());
        let err = resp.0.error.unwrap();
        assert_eq!(err.code, -32601);
        assert!(err.message.contains("Unknown tool"));
    }

    #[tokio::test]
    async fn test_call_tool_missing_params() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: None,
            id: Some(serde_json::json!(9)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.result.is_none());
        let err = resp.0.error.unwrap();
        assert_eq!(err.code, -32602);
        assert!(err.message.contains("Missing params"));
    }

    #[test]
    fn test_json_rpc_request_deserialize() {
        let json_str = r#"{"jsonrpc":"2.0","method":"tools/list","id":1}"#;
        let req: JsonRpcRequest = serde_json::from_str(json_str).unwrap();
        assert_eq!(req.jsonrpc, "2.0");
        assert_eq!(req.method, "tools/list");
        assert!(req.params.is_none());
        assert_eq!(req.id, Some(serde_json::json!(1)));
    }

    #[test]
    fn test_json_rpc_response_serialize() {
        let resp = JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            result: Some(serde_json::json!({"ok": true})),
            error: None,
            id: Some(serde_json::json!(42)),
        };
        let val = serde_json::to_value(&resp).unwrap();
        assert_eq!(val["jsonrpc"], "2.0");
        assert_eq!(val["result"]["ok"], true);
        assert!(val["error"].is_null());
        assert_eq!(val["id"], 42);
    }
}
