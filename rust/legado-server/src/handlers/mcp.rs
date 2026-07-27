//! MCP (Model Context Protocol) Server
//!
//! 暴露书架/搜索/阅读能力给 AI 助手。
//! 基于 JSON-RPC 2.0 协议。

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::state::AppState;

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

/// 列出所有可用 MCP 工具
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
                "required": ["book_url", "source_url"]
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
                "required": ["chapter_url", "source_url"]
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

/// 搜索书籍工具（桩实现）
async fn call_search_books(
    _state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let query = args.get("query").and_then(|v| v.as_str()).unwrap_or("");
    Ok(serde_json::json!({
        "content": [{"type": "text", "text": format!("Search results for: {}", query)}]
    }))
}

/// 获取章节列表工具（桩实现）
async fn call_get_chapters(
    _state: &AppState,
    _args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    Ok(serde_json::json!({
        "content": [{"type": "text", "text": "Chapter list"}]
    }))
}

/// 阅读章节内容工具（桩实现）
async fn call_read_chapter(
    _state: &AppState,
    _args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    Ok(serde_json::json!({
        "content": [{"type": "text", "text": "Chapter content"}]
    }))
}

/// 获取书架工具（桩实现）
async fn call_get_bookshelf(_state: &AppState) -> Result<serde_json::Value, JsonRpcError> {
    Ok(serde_json::json!({
        "content": [{"type": "text", "text": "Bookshelf"}]
    }))
}

/// 添加到书架工具（桩实现）
async fn call_add_to_bookshelf(
    _state: &AppState,
    _args: &serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    Ok(serde_json::json!({
        "content": [{"type": "text", "text": "Book added"}]
    }))
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
        assert_eq!(tools.len(), 5);
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
        assert_eq!(resp.0.len(), 5);
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
        assert_eq!(result.as_array().unwrap().len(), 5);
    }

    #[tokio::test]
    async fn test_call_tool_search_books() {
        let state = make_test_state();
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
    async fn test_call_tool_get_chapters() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "get_chapters",
                "arguments": { "book_url": "https://example.com/book1", "source_url": "https://src.com" }
            })),
            id: Some(serde_json::json!(3)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        assert_eq!(result["content"][0]["text"], "Chapter list");
    }

    #[tokio::test]
    async fn test_call_tool_read_chapter() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "read_chapter",
                "arguments": { "chapter_url": "https://example.com/ch1", "source_url": "https://src.com" }
            })),
            id: Some(serde_json::json!(4)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        assert_eq!(result["content"][0]["text"], "Chapter content");
    }

    #[tokio::test]
    async fn test_call_tool_get_bookshelf() {
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
        assert_eq!(result["content"][0]["text"], "Bookshelf");
    }

    #[tokio::test]
    async fn test_call_tool_add_to_bookshelf() {
        let state = make_test_state();
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "add_to_bookshelf",
                "arguments": { "book_url": "https://example.com/b", "book_name": "Test", "source_url": "https://s.com" }
            })),
            id: Some(serde_json::json!(6)),
        };
        let resp = call_tool(State(state), Json(req)).await;
        assert!(resp.0.error.is_none());
        let result = resp.0.result.unwrap();
        assert_eq!(result["content"][0]["text"], "Book added");
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
