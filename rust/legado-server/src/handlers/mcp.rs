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

/// 列出所有可用 MCP 工具（共 20 个：12 个原有 + 8 个对应上游 #452-#456 的 5 类新工具）
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
                    "book_url": {
                        "type": "string",
                        "description": "章节所属书籍的 bookUrl；提供时按 (book_url, chapter_url) 复合键精确定位缓存，避免多本书共用同 chapter_url 时串本；缺省时回退为仅按 chapter_url 单键查找"
                    },
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
            description: "Get bookmarks, optionally filtered by book name (and author)".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "book_name": { "type": "string", "description": "Optional: filter by book name" },
                    "book_author": { "type": "string", "description": "Optional: filter by book author (used together with book_name to avoid same-name book mixing, ledger §5.14-2)" }
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
        // ─── 上游 #452-#456 新增 5 类工具 ─────────────────────
        McpTool {
            name: "eval_js".to_string(),
            description: "在书源 JavaScript 环境执行脚本并返回求值结果（对齐 Kotlin eval_js 工具）。".to_string()
                + "可按 source_url 绑定已保存书源的运行时身份；不传时使用空白书源。",
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "js": { "type": "string", "description": "要执行的 JavaScript 脚本" },
                    "source_url": { "type": "string", "description": "可选的书源 bookSourceUrl" },
                    "timeout_sec": { "type": "integer", "description": "超时秒数，默认 60，范围 5..600" }
                },
                "required": ["js"]
            }),
        },
        McpTool {
            name: "get_cookies".to_string(),
            description: "非破坏性读取指定 URL 所属二级域名的持久层 Cookie（对齐 Kotlin get_cookies 工具）".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "URL 或域名" }
                },
                "required": ["url"]
            }),
        },
        McpTool {
            name: "clear_cookies".to_string(),
            description: "清除指定 URL 所属二级域名的持久层 Cookie（对齐 Kotlin clear_cookies 工具）".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "URL 或域名" }
                },
                "required": ["url"]
            }),
        },
        McpTool {
            name: "debug_source".to_string(),
            description: "注册书源调试会话并返回会话 ID（对齐 Kotlin debug_source 工具）。".to_string()
                + "Rust 侧暂无自动调试管线，逐步日志由外部注入，可用 get_debug_progress 查询进度。",
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "书源 bookSourceUrl" },
                    "key": { "type": "string", "description": "调试关键词或入口 URL" }
                },
                "required": ["url", "key"]
            }),
        },
        McpTool {
            name: "get_debug_progress".to_string(),
            description: "查询书源调试会话的进度与逐步日志（对齐 Kotlin 调试进度通知，简化为查询模式）".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "debug_source 返回的会话 ID" }
                },
                "required": ["session_id"]
            }),
        },
        McpTool {
            name: "check_sources".to_string(),
            description: "批量校验书源有效性并返回结果汇总（对齐 Kotlin check_source 工具）。单批最多 50 个。".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "urls": { "type": "array", "items": { "type": "string" }, "description": "要校验的 bookSourceUrl 列表，单批最多 50 个" },
                    "keyword": { "type": "string", "description": "可选搜索关键词，默认“我的”" }
                },
                "required": ["urls"]
            }),
        },
        McpTool {
            name: "list_help_docs".to_string(),
            description: "列出应用内帮助文档（对齐 Kotlin 帮助文档 resources，简化为工具形式）".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpTool {
            name: "read_help_doc".to_string(),
            description: "按名称读取应用内帮助文档内容（Markdown）".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "文档名称，见 list_help_docs" }
                },
                "required": ["name"]
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
                    // 上游 #452-#456 新增 5 类工具
                    "eval_js" => call_eval_js(&state, &arguments).await,
                    "get_cookies" => call_get_cookies(&state, &arguments).await,
                    "clear_cookies" => call_clear_cookies(&state, &arguments).await,
                    "debug_source" => call_debug_source(&state, &arguments).await,
                    "get_debug_progress" => call_get_debug_progress(&state, &arguments).await,
                    "check_sources" => call_check_sources(&state, &arguments).await,
                    "list_help_docs" => call_list_help_docs().await,
                    "read_help_doc" => call_read_help_doc(&arguments).await,
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
    // 匹配语义委托共享服务（P2-2，与 REST /api/search 同一实现）；
    // MCP 响应字段（origin/latest_chapter）保持本入口原有组装不变。
    let matched = legado_core::shelf_search::match_shelf_books(&all_books, query);

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

    // book_url 为可选参数（Task #19）：提供时按复合键精确查找，避免串本
    let book_url = args.get("book_url").and_then(|v| v.as_str()).unwrap_or("");

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::CacheBookRepository::new(conn);

    // 提供 book_url 时用 (book_url, chapter_url) 复合键；缺省时回退旧行为（仅按
    // chapter_url 单键）以兼容旧调用——此时若多本书共用同 chapter_url 会读到任意一本，
    // 调用方应尽量传入 book_url。
    let cached = if book_url.is_empty() {
        repo.get_by_chapter_url(chapter_url).map_err(db_err)?
    } else {
        repo.get_by_book_and_chapter_url(book_url, chapter_url)
            .map_err(db_err)?
    };

    match cached {
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
    let book_name = args.get("book_name").and_then(|v| v.as_str()).unwrap_or("");
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
    let book_author = args.get("book_author").and_then(|v| v.as_str());

    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::BookmarkRepository::new(conn);

    // 台账 §5.14-2（评审 S2）：显式传 book_author 时按书名+作者双键查询，
    // 规避同名异书书签混入；未传 author 时保持旧行为（仅按书名），
    // 对既有调用方加法式兼容。
    let bookmarks = match book_name {
        Some(name) if !name.is_empty() => match book_author {
            Some(author) => repo
                .get_by_book_and_author(name, author)
                .map_err(db_err)?,
            None => repo.get_by_book(name).map_err(db_err)?,
        },
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
    let book_name = args.get("book_name").and_then(|v| v.as_str()).unwrap_or("");
    if book_name.is_empty() {
        return Err(JsonRpcError {
            code: -32602,
            message: "book_name parameter is required".to_string(),
        });
    }

    let book_text = args.get("book_text").and_then(|v| v.as_str()).unwrap_or("");
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

// ─── 上游 #452-#456 新增 5 类工具实现 ─────────────────────

/// 文本截断上限（对齐 Kotlin McpFormat.truncate 默认值）
const MCP_TEXT_LIMIT: usize = 100_000;

/// 按字符数截断文本（对齐 Kotlin McpFormat.truncate）
fn truncate_text(text: &str, max_chars: usize) -> String {
    let count = text.chars().count();
    if count <= max_chars {
        text.to_string()
    } else {
        let mut out: String = text.chars().take(max_chars).collect();
        out.push_str("…[内容过长已截断]");
        out
    }
}

/// 从 URL 或域名提取二级域名（对齐 Kotlin NetworkUtils.getSubDomain）
///
/// 简化实现：去掉协议前缀与路径后取 host，再取最后两段作为二级域名。
fn get_sub_domain(url: &str) -> String {
    let without_scheme = url
        .split("://")
        .last()
        .unwrap_or(url)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .trim();
    let host = without_scheme.split('@').next_back().unwrap_or("");
    let host = host.split(':').next().unwrap_or("").trim();
    if host.is_empty() {
        return url.trim().to_string();
    }
    let parts: Vec<&str> = host.split('.').filter(|p| !p.is_empty()).collect();
    if parts.len() >= 2 {
        parts[parts.len() - 2..].join(".")
    } else {
        host.to_string()
    }
}

/// 将任意错误转换为业务级 JsonRpcError（code -32000）
fn rpc_err(message: impl Into<String>) -> JsonRpcError {
    JsonRpcError {
        code: -32000,
        message: message.into(),
    }
}

/// 执行书源脚本（#452，对齐 Kotlin eval_js）
///
/// 在书源 JavaScript 环境执行脚本并返回求值结果：
/// - 可按 source_url 绑定已保存书源的运行时身份（baseUrl/sourceUrl 绑定）
/// - 不传 source_url 时使用空白书源
/// - JS 执行经 spawn_blocking 包裹，避免阻塞 async runtime；
///   脚本级超时由沙箱 max_execution_time 强制中断
/// - 未启用 quickjs feature 时返回功能不可用提示（简化版）
async fn call_eval_js(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let js = args.get("js").and_then(|v| v.as_str()).unwrap_or("");
    if js.trim().is_empty() {
        return Err(rpc_err("参数 js 不能为空"));
    }
    if js.len() > 1024 * 1024 {
        return Err(rpc_err("脚本不能超过 1 MiB"));
    }
    let timeout_sec = args
        .get("timeout_sec")
        .and_then(|v| v.as_i64())
        .unwrap_or(60)
        .clamp(5, 600);

    // 解析书源身份：传 url 时要求书源存在，否则使用空白书源
    let source_url = args
        .get("source_url")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    if let Some(ref url) = source_url {
        let db = state.db.lock().await;
        let conn = db.connection();
        let repo = legado_db::BookSourceRepository::new(conn);
        if repo.find_by_url(url).map_err(db_err)?.is_none() {
            return Err(rpc_err("未找到书源，请检查书源地址"));
        }
    }
    let base_url = source_url.clone().unwrap_or_default();

    let js = js.to_string();
    let started = std::time::Instant::now();
    // spawn_blocking 包裹同步 JS 求值，避免阻塞/嵌套 runtime
    let outcome = tokio::task::spawn_blocking(move || eval_js_blocking(&js, &base_url, timeout_sec))
        .await
        .map_err(|e| rpc_err(format!("JS 求值任务异常: {e}")))?;
    let elapsed_ms = started.elapsed().as_millis();

    match outcome {
        Ok(value) => {
            let display = value.unwrap_or_else(|| "null".to_string());
            Ok(mcp_text(truncate_text(
                &format!("-- 结果 --\n{display}\n\n耗时 {elapsed_ms}ms"),
                MCP_TEXT_LIMIT,
            )))
        }
        Err(message) => Ok(serde_json::json!({
            "content": [{"type": "text", "text": truncate_text(&format!("-- 错误 --\n{message}"), MCP_TEXT_LIMIT)}],
            "isError": true
        })),
    }
}

/// JS 求值的阻塞线程实现（在 spawn_blocking 中执行）
#[cfg(not(feature = "quickjs"))]
fn eval_js_blocking(_js: &str, _base_url: &str, _timeout_sec: i64) -> Result<Option<String>, String> {
    Err("当前构建未启用 quickjs feature，无法执行 JS 脚本（简化版：请使用 cargo build --features quickjs）".to_string())
}

#[cfg(feature = "quickjs")]
fn eval_js_blocking(js: &str, base_url: &str, timeout_sec: i64) -> Result<Option<String>, String> {
    use legado_js::engine::JsEngine;
    use legado_js::sandbox::SandboxConfig;
    use legado_js::QuickJsEngine;

    // 沙箱配置：以 timeout_sec 作为脚本最大执行时间（超时后中断脚本）
    let sandbox = SandboxConfig {
        max_execution_time: std::time::Duration::from_secs(timeout_sec as u64),
        ..Default::default()
    };
    let engine =
        QuickJsEngine::new(sandbox).map_err(|e| format!("JS 引擎初始化失败: {e}"))?;
    // 绑定书源运行时身份（对齐 Kotlin 书源 evalJS 的环境变量）
    let bindings: Vec<(&str, legado_js::JsValue)> = vec![
        ("baseUrl", legado_js::JsValue::String(base_url.to_string())),
        ("sourceUrl", legado_js::JsValue::String(base_url.to_string())),
    ];
    let raw = engine
        .eval_with_bindings(js, &bindings)
        .map_err(|e| format!("{e}"))?;
    Ok(legado_js::JsSourceEngine::normalize_result(&raw))
}

/// 读取书源 Cookie（#453，对齐 Kotlin get_cookies）
///
/// 非破坏性读取指定 URL 所属二级域名的持久层 Cookie（cookies 表，
/// 已由 CookieRepository 接线持久化）。
/// 差距说明：Kotlin 端合并持久层与会话层；Rust server 无会话层 Cookie，
/// 仅返回持久层结果。
async fn call_get_cookies(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let url = args
        .get("url")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| rpc_err("参数 url 不能为空"))?;

    let domain = get_sub_domain(&url);
    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::CookieRepository::new(conn);
    let cookie = repo.get_by_tag(&domain).map_err(db_err)?.unwrap_or_default();

    let text = if cookie.trim().is_empty() {
        "（该域名没有 Cookie）".to_string()
    } else {
        truncate_text(&cookie, MCP_TEXT_LIMIT)
    };
    Ok(mcp_text(text))
}

/// 清除书源 Cookie（#453，对齐 Kotlin clear_cookies）
///
/// 清除指定 URL 所属二级域名的持久层 Cookie。
/// 差距说明：Kotlin 端同时清除持久、会话与 WebView Cookie；
/// Rust server 无会话/WebView 层，仅清除持久层。
async fn call_clear_cookies(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let url = args
        .get("url")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| rpc_err("参数 url 不能为空"))?;

    let domain = get_sub_domain(&url);
    let db = state.db.lock().await;
    let conn = db.connection();
    let repo = legado_db::CookieRepository::new(conn);
    repo.delete_by_tag(&domain).map_err(db_err)?;

    Ok(mcp_text("Cookie 已清除".to_string()))
}

/// 注册书源调试会话（#455，对齐 Kotlin debug_source，简化版）
///
/// 差距说明：Kotlin 端在工具调用内直接运行完整调试管线并以
/// logging/progress 通知推送逐步日志；Rust 侧尚无自动调试管线，
/// 本工具仅创建调试会话（复用 legado-core Debugger 基础设施），
/// 步骤日志可由 /api/debug/step 外部注入，进度用 get_debug_progress 查询。
async fn call_debug_source(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let url = args
        .get("url")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| rpc_err("参数 url 不能为空"))?;
    let key = args
        .get("key")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| rpc_err("参数 key 不能为空"))?;

    // 校验书源存在（对齐 Kotlin：未找到书源直接报错）
    let source_name = {
        let db = state.db.lock().await;
        let conn = db.connection();
        let repo = legado_db::BookSourceRepository::new(conn);
        match repo.find_by_url(&url).map_err(db_err)? {
            Some(source) => source.book_source_name.clone(),
            None => return Err(rpc_err("未找到书源，请检查书源地址")),
        }
    };

    let debugger = crate::handlers::debug::get_debugger();
    let session_id = debugger.create_session(&url, &source_name, &key);

    Ok(mcp_text(format!(
        "调试会话已创建：{session_id}\n书源：{source_name}（{url}）\n关键词：{key}\n\
         说明：Rust 侧暂无自动调试管线，步骤日志由外部注入，可用 get_debug_progress 查询进度"
    )))
}

/// 查询调试会话进度（#455，对齐 Kotlin 调试进度通知，简化为查询模式）
///
/// 返回会话状态、步骤数与格式化逐步日志。
/// 差距说明：Kotlin 端通过 MCP logging/progress 通知主动推送；
/// Rust 简化为客户端轮询查询。
async fn call_get_debug_progress(
    _state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let session_id = args
        .get("session_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| rpc_err("参数 session_id 不能为空"))?;

    let debugger = crate::handlers::debug::get_debugger();
    match debugger.get_session(&session_id) {
        Some(session) => {
            let log = debugger.get_log(&session_id);
            let text = format!(
                "session_id: {}\nstatus: {}\nsteps: {}\n\n{}",
                session.id,
                session.status,
                session.steps.len(),
                truncate_text(&log, MCP_TEXT_LIMIT)
            );
            Ok(mcp_text(text))
        }
        None => Err(rpc_err(format!("未找到调试会话: {session_id}"))),
    }
}

/// 批量校验书源（#456，对齐 Kotlin check_source）
///
/// 按 bookSourceUrl 批量触发书源校验（复用 legado-net source_checker），
/// 返回校验结果汇总；单批最多 50 个。
/// 差距说明：Kotlin 端校验完成后写回分组/错误备注/响应时间并推送进度通知；
/// Rust 简化版仅返回汇总结果，不写回 DB、不推送通知。
async fn call_check_sources(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    // 解析并去重 urls（对齐 Kotlin 参数处理）
    let mut urls: Vec<String> = Vec::new();
    if let Some(arr) = args.get("urls").and_then(|v| v.as_array()) {
        for item in arr {
            if let Some(s) = item.as_str() {
                let s = s.trim();
                if !s.is_empty() && !urls.iter().any(|u| u == s) {
                    urls.push(s.to_string());
                }
            }
        }
    }
    if urls.is_empty() {
        return Err(rpc_err("参数 urls 不能为空"));
    }
    if urls.len() > 50 {
        return Err(rpc_err("单批最多校验 50 个书源"));
    }
    let keyword = args
        .get("keyword")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    // 读取书源（任一 URL 未找到即报错，对齐 Kotlin）
    let sources = {
        let db = state.db.lock().await;
        let conn = db.connection();
        let repo = legado_db::BookSourceRepository::new(conn);
        let mut found = Vec::with_capacity(urls.len());
        for url in &urls {
            match repo.find_by_url(url).map_err(db_err)? {
                Some(source) => found.push(source),
                None => return Err(rpc_err(format!("未找到书源: {url}"))),
            }
        }
        found
    };

    // 构建校验器（复用 source_checker；失败时以错误结果兜底）
    let client = legado_net::client::LegadoClient::new(
        legado_net::client::LegadoClientConfig::default(),
    )
    .map_err(|e| rpc_err(format!("创建网络客户端失败: {e}")))?;
    let config = legado_net::source_checker::CheckerConfig {
        keyword: keyword.unwrap_or_else(|| "我的".to_string()),
        ..legado_net::source_checker::CheckerConfig::default()
    };
    let checker = legado_net::source_checker::SourceChecker::with_config(
        std::sync::Arc::new(client),
        config,
    );

    // 逐个校验（串行，避免并发对书源站点的压力；结果按输入顺序汇总）
    let mut lines = Vec::with_capacity(sources.len());
    let mut passed = 0usize;
    for source in &sources {
        let result = checker.check_full(source).await;
        let ok = result.search_ok && result.toc_ok && result.content_ok;
        if ok {
            passed += 1;
        }
        let mark = if ok { "✓" } else { "✗" };
        let mut line = format!(
            "[{}/{}] {} {} {} 耗时 {}ms",
            lines.len() + 1,
            sources.len(),
            mark,
            source.book_source_name,
            source.book_source_url,
            result.total_time_ms
        );
        if !ok {
            let errors: Vec<String> = [
                result.search_error.as_deref(),
                result.toc_error.as_deref(),
                result.content_error.as_deref(),
            ]
            .into_iter()
            .flatten()
            .filter(|e| !e.is_empty() && *e != "skipped")
            .map(|e| e.to_string())
            .collect();
            if !errors.is_empty() {
                line.push_str(&format!(" | {}", errors.join("; ")));
            }
        }
        lines.push(line);
    }

    let summary = format!(
        "校验完成：共 {} 个，通过 {}，失败 {}\n\n{}",
        sources.len(),
        passed,
        sources.len() - passed,
        lines.join("\n")
    );
    Ok(mcp_text(truncate_text(&summary, MCP_TEXT_LIMIT)))
}

/// 内置帮助文档（#454）
///
/// 内容来源确认：Kotlin 端通过 MCP resources 暴露 `assets/web/help/md/*.md`；
/// Rust 侧以 include_str! 编译期内嵌同一目录的文档，无需运行时资产访问。
const HELP_DOCS: &[(&str, &str)] = &[
    ("ExtensionContentType", include_str!("../../../../app/src/main/assets/web/help/md/ExtensionContentType.md")),
    ("SourceMBookHelp", include_str!("../../../../app/src/main/assets/web/help/md/SourceMBookHelp.md")),
    ("SourceMRssHelp", include_str!("../../../../app/src/main/assets/web/help/md/SourceMRssHelp.md")),
    ("appHelp", include_str!("../../../../app/src/main/assets/web/help/md/appHelp.md")),
    ("autoTaskHelp", include_str!("../../../../app/src/main/assets/web/help/md/autoTaskHelp.md")),
    ("debugHelp", include_str!("../../../../app/src/main/assets/web/help/md/debugHelp.md")),
    ("dictRuleHelp", include_str!("../../../../app/src/main/assets/web/help/md/dictRuleHelp.md")),
    ("httpTTSHelp", include_str!("../../../../app/src/main/assets/web/help/md/httpTTSHelp.md")),
    ("jsHelp", include_str!("../../../../app/src/main/assets/web/help/md/jsHelp.md")),
    ("readMenuHelp", include_str!("../../../../app/src/main/assets/web/help/md/readMenuHelp.md")),
    ("regexHelp", include_str!("../../../../app/src/main/assets/web/help/md/regexHelp.md")),
    ("replaceRuleHelp", include_str!("../../../../app/src/main/assets/web/help/md/replaceRuleHelp.md")),
    ("rssRuleHelp", include_str!("../../../../app/src/main/assets/web/help/md/rssRuleHelp.md")),
    ("ruleHelp", include_str!("../../../../app/src/main/assets/web/help/md/ruleHelp.md")),
    ("txtTocRuleHelp", include_str!("../../../../app/src/main/assets/web/help/md/txtTocRuleHelp.md")),
    ("webDavBookHelp", include_str!("../../../../app/src/main/assets/web/help/md/webDavBookHelp.md")),
    ("webDavHelp", include_str!("../../../../app/src/main/assets/web/help/md/webDavHelp.md")),
    ("xpathHelp", include_str!("../../../../app/src/main/assets/web/help/md/xpathHelp.md")),
];

/// 列出应用内帮助文档（#454，对齐 Kotlin 帮助文档 resources，简化为工具）
async fn call_list_help_docs() -> Result<serde_json::Value, JsonRpcError> {
    let names: Vec<&str> = HELP_DOCS.iter().map(|(name, _)| *name).collect();
    Ok(mcp_text(format!(
        "共 {} 篇帮助文档（用 read_help_doc 按名称读取）：\n{}",
        names.len(),
        names.join("\n")
    )))
}

/// 读取单篇帮助文档（#454，对齐 Kotlin legado://help/{name} resource）
async fn call_read_help_doc(args: &serde_json::Value) -> Result<serde_json::Value, JsonRpcError> {
    let name = args
        .get("name")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().trim_end_matches(".md").to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| rpc_err("参数 name 不能为空"))?;

    match HELP_DOCS.iter().find(|(doc_name, _)| *doc_name == name) {
        Some((_, content)) => Ok(mcp_text(truncate_text(content, MCP_TEXT_LIMIT))),
        None => Err(rpc_err(format!(
            "未找到帮助文档: {name}（用 list_help_docs 查看可用文档）"
        ))),
    }
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
        assert_eq!(tools.len(), 20);
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
        // 上游 #452-#456 新增 5 类工具
        assert!(names.contains(&"eval_js"));
        assert!(names.contains(&"get_cookies"));
        assert!(names.contains(&"clear_cookies"));
        assert!(names.contains(&"debug_source"));
        assert!(names.contains(&"get_debug_progress"));
        assert!(names.contains(&"check_sources"));
        assert!(names.contains(&"list_help_docs"));
        assert!(names.contains(&"read_help_doc"));
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
        assert_eq!(resp.0.len(), 20);
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
        assert_eq!(result.as_array().unwrap().len(), 20);
    }

    // ─── 上游 #452-#456 新工具执行逻辑测试 ───────────────────

    /// 构造一个 tools/call 请求的辅助函数
    fn make_call_req(name: &str, arguments: serde_json::Value) -> JsonRpcRequest {
        JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({ "name": name, "arguments": arguments })),
            id: Some(serde_json::json!(100)),
        }
    }

    /// 取 MCP 响应文本
    fn result_text(resp: &JsonRpcResponse) -> String {
        resp.result.as_ref().unwrap()["content"][0]["text"]
            .as_str()
            .unwrap()
            .to_string()
    }

    #[tokio::test]
    async fn test_eval_js_empty_param() {
        let state = make_test_state();
        let resp = call_tool(State(state), Json(make_call_req("eval_js", serde_json::json!({"js": "  "})))).await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("js"));
    }

    #[tokio::test]
    async fn test_eval_js_source_not_found() {
        let state = make_test_state();
        let resp = call_tool(
            State(state),
            Json(make_call_req("eval_js", serde_json::json!({"js": "1+1", "source_url": "https://missing.com"}))),
        )
        .await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("未找到书源"));
    }

    #[tokio::test]
    async fn test_eval_js_without_quickjs_returns_is_error() {
        // 未启用 quickjs feature 时返回 isError（简化版降级路径）；
        // 启用 quickjs 时返回真实求值结果，两条路径均为成功响应。
        let state = make_test_state();
        let resp = call_tool(
            State(state),
            Json(make_call_req("eval_js", serde_json::json!({"js": "1+1"}))),
        )
        .await;
        assert!(resp.0.error.is_none());
        let text = result_text(&resp.0);
        assert!(text.contains("-- 结果 --") || text.contains("-- 错误 --"));
    }

    #[tokio::test]
    async fn test_cookies_get_set_clear_roundtrip() {
        let state = make_test_state();
        // 预置持久层 Cookie（tag 为二级域名，与工具实现一致）
        {
            let db = state.db.lock().await;
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert("example.com", "session=abc123").unwrap();
        }

        // 读取（子域名 URL 应命中二级域名）
        let resp = call_tool(
            State(state.clone()),
            Json(make_call_req("get_cookies", serde_json::json!({"url": "https://www.example.com/book"}))),
        )
        .await;
        assert!(resp.0.error.is_none());
        assert!(result_text(&resp.0).contains("session=abc123"));

        // 清除
        let resp = call_tool(
            State(state.clone()),
            Json(make_call_req("clear_cookies", serde_json::json!({"url": "https://www.example.com"}))),
        )
        .await;
        assert!(resp.0.error.is_none());
        assert!(result_text(&resp.0).contains("Cookie 已清除"));

        // 再次读取应为空
        let resp = call_tool(
            State(state),
            Json(make_call_req("get_cookies", serde_json::json!({"url": "https://example.com"}))),
        )
        .await;
        assert!(result_text(&resp.0).contains("没有 Cookie"));
    }

    #[tokio::test]
    async fn test_cookies_missing_url_param() {
        let state = make_test_state();
        for tool in ["get_cookies", "clear_cookies"] {
            let resp = call_tool(State(state.clone()), Json(make_call_req(tool, serde_json::json!({})))).await;
            assert!(resp.0.error.is_some());
        }
    }

    #[tokio::test]
    async fn test_debug_source_and_progress() {
        let state = make_test_state();
        // 预置一个书源
        {
            let db = state.db.lock().await;
            let repo = legado_db::BookSourceRepository::new(db.connection());
            repo.insert(&legado_core::models::BookSource {
                book_source_url: "https://src-debug.com".to_string(),
                book_source_name: "调试源".to_string(),
                ..legado_core::models::BookSource::default()
            })
            .unwrap();
        }

        // 创建调试会话
        let resp = call_tool(
            State(state.clone()),
            Json(make_call_req("debug_source", serde_json::json!({"url": "https://src-debug.com", "key": "斗破苍穹"}))),
        )
        .await;
        assert!(resp.0.error.is_none());
        let text = result_text(&resp.0);
        assert!(text.contains("调试会话已创建"));
        let session_id = text
            .lines()
            .next()
            .unwrap()
            .trim_start_matches("调试会话已创建：")
            .to_string();

        // 查询进度（会话存在）
        let resp = call_tool(
            State(state),
            Json(make_call_req("get_debug_progress", serde_json::json!({"session_id": session_id}))),
        )
        .await;
        assert!(resp.0.error.is_none());
        let text = result_text(&resp.0);
        assert!(text.contains("status: running"));
        assert!(text.contains("调试源"));
    }

    #[tokio::test]
    async fn test_debug_source_not_found() {
        let state = make_test_state();
        let resp = call_tool(
            State(state),
            Json(make_call_req("debug_source", serde_json::json!({"url": "https://missing.com", "key": "k"}))),
        )
        .await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("未找到书源"));
    }

    #[tokio::test]
    async fn test_get_debug_progress_session_not_found() {
        let state = make_test_state();
        let resp = call_tool(
            State(state),
            Json(make_call_req("get_debug_progress", serde_json::json!({"session_id": "no_such_session"}))),
        )
        .await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("未找到调试会话"));
    }

    #[tokio::test]
    async fn test_check_sources_param_validation() {
        let state = make_test_state();

        // 空列表报错
        let resp = call_tool(
            State(state.clone()),
            Json(make_call_req("check_sources", serde_json::json!({"urls": []}))),
        )
        .await;
        assert!(resp.0.error.is_some());

        // 超过 50 个报错
        let urls: Vec<String> = (0..51).map(|i| format!("https://s{i}.com")).collect();
        let resp = call_tool(
            State(state.clone()),
            Json(make_call_req("check_sources", serde_json::json!({"urls": urls}))),
        )
        .await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("50"));

        // 未找到书源报错
        let resp = call_tool(
            State(state),
            Json(make_call_req("check_sources", serde_json::json!({"urls": ["https://missing.com"]}))),
        )
        .await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("未找到书源"));
    }

    #[tokio::test]
    async fn test_list_help_docs() {
        let state = make_test_state();
        let resp = call_tool(State(state), Json(make_call_req("list_help_docs", serde_json::json!({})))).await;
        assert!(resp.0.error.is_none());
        let text = result_text(&resp.0);
        assert!(text.contains("共 18 篇"));
        assert!(text.contains("jsHelp"));
        assert!(text.contains("ruleHelp"));
    }

    #[tokio::test]
    async fn test_read_help_doc_found_and_missing() {
        let state = make_test_state();

        // 存在（支持带 .md 后缀与不带）
        let resp = call_tool(
            State(state.clone()),
            Json(make_call_req("read_help_doc", serde_json::json!({"name": "debugHelp.md"}))),
        )
        .await;
        assert!(resp.0.error.is_none());
        assert!(!result_text(&resp.0).trim().is_empty());

        // 不存在
        let resp = call_tool(
            State(state),
            Json(make_call_req("read_help_doc", serde_json::json!({"name": "noSuchDoc"}))),
        )
        .await;
        assert!(resp.0.error.is_some());
        assert!(resp.0.error.unwrap().message.contains("未找到帮助文档"));
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
