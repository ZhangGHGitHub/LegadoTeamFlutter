//! 朗读控制 API 端点
//!
//! 提供朗读状态机的 HTTP 控制接口：
//! - POST /api/read-aloud/start — 开始朗读
//! - POST /api/read-aloud/pause — 暂停
//! - POST /api/read-aloud/resume — 恢复
//! - POST /api/read-aloud/stop — 停止
//! - GET  /api/read-aloud/status — 获取朗读状态
//! - POST /api/read-aloud/next — 下一段
//! - POST /api/read-aloud/seek — 跳转

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::read_aloud::{ReadAloudConfig, ReadAloudState, ReadAloudStatus};

/// 朗读全局状态（嵌入 AppState 或独立共享）
pub type SharedReadAloudState = Arc<Mutex<ReadAloudState>>;

/// 创建默认朗读状态实例
pub fn create_read_aloud_state() -> SharedReadAloudState {
    Arc::new(Mutex::new(ReadAloudState::new(ReadAloudConfig::default())))
}

// ─── 请求/响应类型 ───────────────────────────────────────────────

/// 开始朗读请求
#[derive(Debug, Deserialize)]
pub struct StartRequest {
    /// 书籍 URL
    pub book_url: String,
    /// 起始章节索引
    pub chapter_index: i32,
    /// 章节文本内容
    pub chapter_text: String,
    /// 预加载的后续章节索引列表
    pub queue_chapters: Option<Vec<i32>>,
    /// TTS 引擎 URL（可选覆盖）
    pub engine_url: Option<String>,
    /// 语速（可选覆盖）
    pub speed: Option<f32>,
}

/// 跳转请求
#[derive(Debug, Deserialize)]
pub struct SeekRequest {
    /// 目标段落索引
    pub paragraph_index: usize,
}

/// 朗读状态响应
#[derive(Debug, Serialize)]
pub struct ReadAloudStatusResponse {
    /// 当前状态
    pub status: ReadAloudStatus,
    /// 当前章节
    pub current_chapter: i32,
    /// 当前段落索引
    pub current_paragraph: usize,
    /// 当前段落文本
    pub current_text: Option<String>,
    /// 总段落数
    pub total_paragraphs: usize,
    /// 朗读进度 (0.0 - 1.0)
    pub progress: f64,
    /// 是否活跃
    pub is_active: bool,
    /// 队列中待朗读章节数
    pub queued_chapters: usize,
}

/// 操作结果响应
#[derive(Debug, Serialize)]
pub struct ActionResponse {
    pub success: bool,
    pub message: String,
}

// ─── Handler 函数 ────────────────────────────────────────────────

/// POST /api/read-aloud/start — 开始朗读
pub async fn start(
    State(state): State<Arc<AppState>>,
    Json(req): Json<StartRequest>,
) -> Result<Json<ActionResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(start_inner(&ra_state, req).await))
}

/// POST /api/read-aloud/pause — 暂停朗读
pub async fn pause(State(state): State<Arc<AppState>>) -> Result<Json<ActionResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(pause_inner(&ra_state).await))
}

/// POST /api/read-aloud/resume — 恢复朗读
pub async fn resume(State(state): State<Arc<AppState>>) -> Result<Json<ActionResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(resume_inner(&ra_state).await))
}

/// POST /api/read-aloud/stop — 停止朗读
pub async fn stop(State(state): State<Arc<AppState>>) -> Result<Json<ActionResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(stop_inner(&ra_state).await))
}

/// GET /api/read-aloud/status — 获取朗读状态
pub async fn status(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ReadAloudStatusResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(status_inner(&ra_state).await))
}

/// POST /api/read-aloud/next — 前进到下一段
pub async fn next(State(state): State<Arc<AppState>>) -> Result<Json<ActionResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(next_inner(&ra_state).await))
}

/// POST /api/read-aloud/seek — 跳转到指定段落
pub async fn seek(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SeekRequest>,
) -> Result<Json<ActionResponse>, ApiError> {
    let ra_state = get_read_aloud_state(&state).await;
    Ok(Json(seek_inner(&ra_state, req).await))
}

// ─── 内部逻辑（可测试） ─────────────────────────────────────────

async fn start_inner(ra_state: &SharedReadAloudState, req: StartRequest) -> ActionResponse {
    let mut guard = ra_state.lock().await;

    // 应用可选配置覆盖
    if let Some(url) = &req.engine_url {
        guard.config.engine_url = Some(url.clone());
    }
    if let Some(speed) = req.speed {
        guard.config.speed = speed.clamp(0.5, 3.0);
    }

    // 加载章节
    guard.load_chapter(req.chapter_index, &req.chapter_text);

    // 添加后续章节到队列
    if let Some(chapters) = &req.queue_chapters {
        for &ch in chapters {
            guard.enqueue_chapter(ch);
        }
    }

    guard.play();

    ActionResponse {
        success: true,
        message: format!(
            "开始朗读章节 {}，共 {} 段",
            req.chapter_index,
            guard.paragraphs.len()
        ),
    }
}

async fn pause_inner(ra_state: &SharedReadAloudState) -> ActionResponse {
    let mut guard = ra_state.lock().await;

    if guard.status != ReadAloudStatus::Playing {
        return ActionResponse {
            success: false,
            message: "当前未在朗读中".to_string(),
        };
    }

    guard.pause();
    ActionResponse {
        success: true,
        message: "已暂停".to_string(),
    }
}

async fn resume_inner(ra_state: &SharedReadAloudState) -> ActionResponse {
    let mut guard = ra_state.lock().await;

    if guard.status != ReadAloudStatus::Paused {
        return ActionResponse {
            success: false,
            message: "当前未处于暂停状态".to_string(),
        };
    }

    guard.resume();
    ActionResponse {
        success: true,
        message: "已恢复朗读".to_string(),
    }
}

async fn stop_inner(ra_state: &SharedReadAloudState) -> ActionResponse {
    let mut guard = ra_state.lock().await;
    guard.stop();
    ActionResponse {
        success: true,
        message: "已停止朗读".to_string(),
    }
}

async fn status_inner(ra_state: &SharedReadAloudState) -> ReadAloudStatusResponse {
    let guard = ra_state.lock().await;
    let current_text = guard.current_text().map(|p| p.text.clone());

    ReadAloudStatusResponse {
        status: guard.status.clone(),
        current_chapter: guard.current_chapter,
        current_paragraph: guard.current_paragraph,
        current_text,
        total_paragraphs: guard.paragraphs.len(),
        progress: guard.progress(),
        is_active: guard.is_active(),
        queued_chapters: guard.chapter_queue.len(),
    }
}

async fn next_inner(ra_state: &SharedReadAloudState) -> ActionResponse {
    let mut guard = ra_state.lock().await;

    if !guard.is_active() {
        return ActionResponse {
            success: false,
            message: "朗读未激活".to_string(),
        };
    }

    let has_more = guard.advance();
    if has_more {
        let msg = if guard.paragraphs.is_empty() {
            format!("需要加载章节 {}", guard.current_chapter)
        } else {
            format!("前进到第 {} 段", guard.current_paragraph + 1)
        };
        ActionResponse {
            success: true,
            message: msg,
        }
    } else {
        ActionResponse {
            success: true,
            message: "朗读已全部完成".to_string(),
        }
    }
}

async fn seek_inner(ra_state: &SharedReadAloudState, req: SeekRequest) -> ActionResponse {
    let mut guard = ra_state.lock().await;

    if req.paragraph_index >= guard.paragraphs.len() {
        return ActionResponse {
            success: false,
            message: format!(
                "段落索引 {} 超出范围（共 {} 段）",
                req.paragraph_index,
                guard.paragraphs.len()
            ),
        };
    }

    guard.seek_to(req.paragraph_index);
    ActionResponse {
        success: true,
        message: format!("已跳转到第 {} 段", req.paragraph_index + 1),
    }
}

// ─── 内部辅助 ────────────────────────────────────────────────────

/// 从 AppState 扩展中获取朗读状态
///
/// 当前使用 lazy 初始化方式：首次访问时创建默认状态。
/// 后续可将 SharedReadAloudState 直接嵌入 AppState。
async fn get_read_aloud_state(_state: &AppState) -> SharedReadAloudState {
    // 简化实现：使用全局 OnceLock 保持单一实例
    use std::sync::OnceLock;
    static READ_ALOUD: OnceLock<SharedReadAloudState> = OnceLock::new();
    READ_ALOUD.get_or_init(create_read_aloud_state).clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::read_aloud::TtsEngineType;

    /// 创建独立的朗读状态（测试隔离）
    fn local_state() -> SharedReadAloudState {
        create_read_aloud_state()
    }

    #[tokio::test]
    async fn test_start_read_aloud() {
        let ra = local_state();
        let req = StartRequest {
            book_url: "https://example.com/book/1".to_string(),
            chapter_index: 0,
            chapter_text: "第一句话。第二句话。第三句话。".to_string(),
            queue_chapters: Some(vec![1, 2]),
            engine_url: None,
            speed: Some(1.5),
        };

        let resp = start_inner(&ra, req).await;
        assert!(resp.success);
        assert!(resp.message.contains("3 段"));
    }

    #[tokio::test]
    async fn test_pause_and_resume() {
        let ra = local_state();

        // 先开始朗读
        let req = StartRequest {
            book_url: "test".to_string(),
            chapter_index: 0,
            chapter_text: "测试文本。".to_string(),
            queue_chapters: None,
            engine_url: None,
            speed: None,
        };
        let _ = start_inner(&ra, req).await;

        // 暂停
        let resp = pause_inner(&ra).await;
        assert!(resp.success);

        // 恢复
        let resp = resume_inner(&ra).await;
        assert!(resp.success);
    }

    #[tokio::test]
    async fn test_stop() {
        let ra = local_state();
        let resp = stop_inner(&ra).await;
        assert!(resp.success);
        assert!(resp.message.contains("停止"));
    }

    #[tokio::test]
    async fn test_status_response() {
        let ra = local_state();

        // 先开始
        let req = StartRequest {
            book_url: "test".to_string(),
            chapter_index: 3,
            chapter_text: "段落A。段落B。".to_string(),
            queue_chapters: Some(vec![4]),
            engine_url: None,
            speed: None,
        };
        let _ = start_inner(&ra, req).await;

        let resp = status_inner(&ra).await;
        assert_eq!(resp.current_chapter, 3);
        assert_eq!(resp.total_paragraphs, 2);
        assert!(resp.is_active);
        assert_eq!(resp.queued_chapters, 1);
        assert_eq!(resp.current_text, Some("段落A".to_string()));
    }

    #[tokio::test]
    async fn test_seek_out_of_bounds() {
        let ra = local_state();

        // 先开始
        let req = StartRequest {
            book_url: "test".to_string(),
            chapter_index: 0,
            chapter_text: "仅一段。".to_string(),
            queue_chapters: None,
            engine_url: None,
            speed: None,
        };
        let _ = start_inner(&ra, req).await;

        // 越界跳转
        let resp = seek_inner(
            &ra,
            SeekRequest {
                paragraph_index: 99,
            },
        )
        .await;
        assert!(!resp.success);
        assert!(resp.message.contains("超出范围"));
    }

    #[tokio::test]
    async fn test_next_paragraph() {
        let ra = local_state();

        let req = StartRequest {
            book_url: "test".to_string(),
            chapter_index: 0,
            chapter_text: "句一。句二。句三。".to_string(),
            queue_chapters: None,
            engine_url: None,
            speed: None,
        };
        let _ = start_inner(&ra, req).await;

        let resp = next_inner(&ra).await;
        assert!(resp.success);
        assert!(resp.message.contains("第 2 段"));
    }

    #[tokio::test]
    async fn test_pause_when_not_playing() {
        let ra = local_state();
        let resp = pause_inner(&ra).await;
        assert!(!resp.success);
        assert!(resp.message.contains("未在朗读中"));
    }

    #[tokio::test]
    async fn test_next_when_idle() {
        let ra = local_state();
        let resp = next_inner(&ra).await;
        assert!(!resp.success);
        assert!(resp.message.contains("未激活"));
    }

    #[test]
    fn test_read_aloud_config_custom() {
        let cfg = ReadAloudConfig {
            engine_type: TtsEngineType::SystemTts,
            engine_url: None,
            speed: 2.0,
            pitch: 1.5,
            volume: 0.7,
            paragraph_delay_ms: 200,
        };
        let json = serde_json::to_string(&cfg).unwrap();
        assert!(json.contains("SystemTts"));
    }

    #[test]
    fn test_action_response_serialize() {
        let resp = ActionResponse {
            success: true,
            message: "ok".to_string(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"success\":true"));
    }
}
