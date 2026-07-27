//! 书源调试器
//!
//! 移植自 Kotlin Debug.kt，提供逐步规则执行和调试日志收集。

use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

/// 调试步骤类型
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DebugStepType {
    /// 搜索规则
    Search,
    /// 目录规则
    Toc,
    /// 正文规则
    Content,
    /// JS 执行
    JsEval,
    /// HTTP GET 请求
    HttpGet,
    /// HTTP POST 请求
    HttpPost,
}

/// 调试步骤状态
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DebugStepStatus {
    Pending,
    Running,
    Success,
    Failed(String),
    Skipped,
}

/// 单个调试步骤
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebugStep {
    pub step_type: DebugStepType,
    pub status: DebugStepStatus,
    pub input: String,
    pub output: String,
    /// 使用的规则表达式
    pub rule: Option<String>,
    pub duration_ms: u64,
    pub timestamp: i64,
    pub error: Option<String>,
}

impl DebugStep {
    /// 创建一个新的调试步骤（初始状态为 Pending）
    pub fn new(step_type: DebugStepType, input: &str) -> Self {
        Self {
            step_type,
            status: DebugStepStatus::Pending,
            input: input.to_string(),
            output: String::new(),
            rule: None,
            duration_ms: 0,
            timestamp: now_millis(),
            error: None,
        }
    }

    /// 标记步骤成功完成
    pub fn mark_success(&mut self, output: &str, duration_ms: u64) {
        self.status = DebugStepStatus::Success;
        self.output = output.to_string();
        self.duration_ms = duration_ms;
    }

    /// 标记步骤失败
    pub fn mark_failed(&mut self, error: &str, duration_ms: u64) {
        self.status = DebugStepStatus::Failed(error.to_string());
        self.error = Some(error.to_string());
        self.duration_ms = duration_ms;
    }

    /// 设置规则表达式
    pub fn with_rule(mut self, rule: &str) -> Self {
        self.rule = Some(rule.to_string());
        self
    }
}

/// 调试会话
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebugSession {
    pub id: String,
    pub source_url: String,
    pub source_name: String,
    pub search_key: String,
    pub steps: Vec<DebugStep>,
    /// "running", "completed", "failed"
    pub status: String,
    pub started_at: i64,
    pub completed_at: Option<i64>,
}

impl DebugSession {
    /// 会话总耗时（毫秒）
    pub fn total_duration_ms(&self) -> u64 {
        self.steps.iter().map(|s| s.duration_ms).sum()
    }

    /// 是否所有步骤都成功
    pub fn all_steps_ok(&self) -> bool {
        self.steps
            .iter()
            .all(|s| s.status == DebugStepStatus::Success || s.status == DebugStepStatus::Skipped)
    }
}

/// 调试器 — 管理多个调试会话
pub struct Debugger {
    sessions: Arc<Mutex<Vec<DebugSession>>>,
}

impl Default for Debugger {
    fn default() -> Self {
        Self::new()
    }
}

impl Debugger {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// 创建新调试会话，返回会话 ID
    pub fn create_session(&self, source_url: &str, source_name: &str, search_key: &str) -> String {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let seq = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = format!("debug_{}_{}", now_millis(), seq);
        let session = DebugSession {
            id: id.clone(),
            source_url: source_url.to_string(),
            source_name: source_name.to_string(),
            search_key: search_key.to_string(),
            steps: Vec::new(),
            status: "running".to_string(),
            started_at: now_millis(),
            completed_at: None,
        };
        self.sessions.lock().unwrap().push(session);
        id
    }

    /// 添加调试步骤
    pub fn add_step(&self, session_id: &str, step: DebugStep) {
        if let Some(session) = self
            .sessions
            .lock()
            .unwrap()
            .iter_mut()
            .find(|s| s.id == session_id)
        {
            session.steps.push(step);
        }
    }

    /// 完成调试会话
    pub fn complete_session(&self, session_id: &str, status: &str) {
        if let Some(session) = self
            .sessions
            .lock()
            .unwrap()
            .iter_mut()
            .find(|s| s.id == session_id)
        {
            session.status = status.to_string();
            session.completed_at = Some(now_millis());
        }
    }

    /// 获取调试会话
    pub fn get_session(&self, session_id: &str) -> Option<DebugSession> {
        self.sessions
            .lock()
            .unwrap()
            .iter()
            .find(|s| s.id == session_id)
            .cloned()
    }

    /// 获取调试日志（格式化输出）
    pub fn get_log(&self, session_id: &str) -> String {
        let sessions = self.sessions.lock().unwrap();
        if let Some(session) = sessions.iter().find(|s| s.id == session_id) {
            let mut log = format!("=== Debug Session: {} ===\n", session.source_name);
            log.push_str(&format!("Source: {}\n", session.source_url));
            log.push_str(&format!("Search: {}\n\n", session.search_key));

            for (i, step) in session.steps.iter().enumerate() {
                let status_icon = match &step.status {
                    DebugStepStatus::Success => "✓",
                    DebugStepStatus::Failed(_) => "✗",
                    DebugStepStatus::Running => "⟳",
                    DebugStepStatus::Pending => "○",
                    DebugStepStatus::Skipped => "⊘",
                };
                log.push_str(&format!(
                    "[{}] Step {}: {:?} {}\n",
                    status_icon,
                    i + 1,
                    step.step_type,
                    format_status(&step.status)
                ));
                if !step.input.is_empty() {
                    log.push_str(&format!("  Input: {}\n", truncate(&step.input, 200)));
                }
                if !step.output.is_empty() {
                    log.push_str(&format!("  Output: {}\n", truncate(&step.output, 200)));
                }
                if let Some(ref err) = step.error {
                    log.push_str(&format!("  Error: {}\n", err));
                }
                log.push_str(&format!("  Duration: {}ms\n\n", step.duration_ms));
            }
            log
        } else {
            "Session not found".to_string()
        }
    }

    /// 列出所有调试会话
    pub fn list_sessions(&self) -> Vec<DebugSession> {
        self.sessions.lock().unwrap().clone()
    }

    /// 删除指定会话
    pub fn remove_session(&self, session_id: &str) -> bool {
        let mut sessions = self.sessions.lock().unwrap();
        let len_before = sessions.len();
        sessions.retain(|s| s.id != session_id);
        sessions.len() < len_before
    }

    /// 清除所有已完成的会话
    pub fn clear_completed(&self) -> usize {
        let mut sessions = self.sessions.lock().unwrap();
        let len_before = sessions.len();
        sessions.retain(|s| s.status == "running");
        len_before - sessions.len()
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let truncated: String = s.chars().take(max).collect();
        format!("{}...", truncated)
    } else {
        s.to_string()
    }
}

fn format_status(status: &DebugStepStatus) -> String {
    match status {
        DebugStepStatus::Pending => "Pending".to_string(),
        DebugStepStatus::Running => "Running".to_string(),
        DebugStepStatus::Success => "Success".to_string(),
        DebugStepStatus::Failed(msg) => format!("Failed({})", msg),
        DebugStepStatus::Skipped => "Skipped".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_session() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://example.com", "TestSource", "斗破苍穹");
        assert!(id.starts_with("debug_"));

        let session = debugger.get_session(&id).unwrap();
        assert_eq!(session.source_url, "https://example.com");
        assert_eq!(session.source_name, "TestSource");
        assert_eq!(session.search_key, "斗破苍穹");
        assert_eq!(session.status, "running");
        assert!(session.steps.is_empty());
        assert!(session.completed_at.is_none());
    }

    #[test]
    fn test_add_step() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://example.com", "Src", "key");

        let step = DebugStep::new(DebugStepType::Search, "search?q=test");
        debugger.add_step(&id, step);

        let session = debugger.get_session(&id).unwrap();
        assert_eq!(session.steps.len(), 1);
        assert_eq!(session.steps[0].step_type, DebugStepType::Search);
        assert_eq!(session.steps[0].input, "search?q=test");
    }

    #[test]
    fn test_add_step_nonexistent_session() {
        let debugger = Debugger::new();
        let step = DebugStep::new(DebugStepType::Toc, "toc_url");
        // Should not panic
        debugger.add_step("nonexistent_id", step);
    }

    #[test]
    fn test_complete_session() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://example.com", "Src", "key");
        debugger.complete_session(&id, "completed");

        let session = debugger.get_session(&id).unwrap();
        assert_eq!(session.status, "completed");
        assert!(session.completed_at.is_some());
    }

    #[test]
    fn test_complete_session_failed() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://example.com", "Src", "key");
        debugger.complete_session(&id, "failed");

        let session = debugger.get_session(&id).unwrap();
        assert_eq!(session.status, "failed");
    }

    #[test]
    fn test_get_session_not_found() {
        let debugger = Debugger::new();
        assert!(debugger.get_session("no_such_id").is_none());
    }

    #[test]
    fn test_get_log_format() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://example.com", "MySource", "test");

        let mut step = DebugStep::new(DebugStepType::HttpGet, "https://example.com/api");
        step.mark_success("<html>result</html>", 150);
        step.rule = Some("css:.book-name".to_string());
        debugger.add_step(&id, step);

        let log = debugger.get_log(&id);
        assert!(log.contains("=== Debug Session: MySource ==="));
        assert!(log.contains("Source: https://example.com"));
        assert!(log.contains("Search: test"));
        assert!(log.contains("[✓] Step 1: HttpGet Success"));
        assert!(log.contains("Input: https://example.com/api"));
        assert!(log.contains("Output: <html>result</html>"));
        assert!(log.contains("Duration: 150ms"));
    }

    #[test]
    fn test_get_log_not_found() {
        let debugger = Debugger::new();
        let log = debugger.get_log("nonexistent");
        assert_eq!(log, "Session not found");
    }

    #[test]
    fn test_get_log_failed_step() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://src.com", "FailSrc", "kw");

        let mut step = DebugStep::new(DebugStepType::Content, "chapter_url");
        step.mark_failed("connection timeout", 5000);
        debugger.add_step(&id, step);

        let log = debugger.get_log(&id);
        assert!(log.contains("[✗] Step 1: Content Failed(connection timeout)"));
        assert!(log.contains("Error: connection timeout"));
        assert!(log.contains("Duration: 5000ms"));
    }

    #[test]
    fn test_list_sessions() {
        let debugger = Debugger::new();
        debugger.create_session("https://a.com", "A", "k1");
        debugger.create_session("https://b.com", "B", "k2");
        debugger.create_session("https://c.com", "C", "k3");

        let sessions = debugger.list_sessions();
        assert_eq!(sessions.len(), 3);
    }

    #[test]
    fn test_remove_session() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://a.com", "A", "k");
        assert!(debugger.remove_session(&id));
        assert!(debugger.get_session(&id).is_none());
        assert!(!debugger.remove_session(&id)); // already removed
    }

    #[test]
    fn test_clear_completed() {
        let debugger = Debugger::new();
        let id1 = debugger.create_session("https://a.com", "A", "k1");
        let _id2 = debugger.create_session("https://b.com", "B", "k2");
        debugger.complete_session(&id1, "completed");

        let cleared = debugger.clear_completed();
        assert_eq!(cleared, 1);
        assert_eq!(debugger.list_sessions().len(), 1);
    }

    #[test]
    fn test_debug_step_with_rule() {
        let step =
            DebugStep::new(DebugStepType::JsEval, "$.data.books").with_rule("$.data.books[*]");
        assert_eq!(step.rule, Some("$.data.books[*]".to_string()));
        assert_eq!(step.step_type, DebugStepType::JsEval);
    }

    #[test]
    fn test_session_total_duration() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://x.com", "X", "q");

        let mut s1 = DebugStep::new(DebugStepType::Search, "in1");
        s1.mark_success("out1", 100);
        let mut s2 = DebugStep::new(DebugStepType::Toc, "in2");
        s2.mark_success("out2", 250);
        debugger.add_step(&id, s1);
        debugger.add_step(&id, s2);

        let session = debugger.get_session(&id).unwrap();
        assert_eq!(session.total_duration_ms(), 350);
    }

    #[test]
    fn test_session_all_steps_ok() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://x.com", "X", "q");

        let mut s1 = DebugStep::new(DebugStepType::Search, "in1");
        s1.mark_success("out1", 50);
        let mut s2 = DebugStep::new(DebugStepType::Toc, "in2");
        s2.status = DebugStepStatus::Skipped;
        debugger.add_step(&id, s1);
        debugger.add_step(&id, s2);

        let session = debugger.get_session(&id).unwrap();
        assert!(session.all_steps_ok());
    }

    #[test]
    fn test_session_not_all_ok_on_failure() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://x.com", "X", "q");

        let mut s1 = DebugStep::new(DebugStepType::Search, "in1");
        s1.mark_success("out1", 50);
        let mut s2 = DebugStep::new(DebugStepType::Content, "in2");
        s2.mark_failed("parse error", 200);
        debugger.add_step(&id, s1);
        debugger.add_step(&id, s2);

        let session = debugger.get_session(&id).unwrap();
        assert!(!session.all_steps_ok());
    }

    #[test]
    fn test_truncate_short_string() {
        assert_eq!(truncate("hello", 10), "hello");
    }

    #[test]
    fn test_truncate_long_string() {
        let long = "a".repeat(300);
        let result = truncate(&long, 200);
        assert!(result.ends_with("..."));
        assert_eq!(result.chars().count(), 203); // 200 chars + "..."
    }

    #[test]
    fn test_truncate_unicode() {
        let s = "中".repeat(250);
        let result = truncate(&s, 200);
        assert!(result.ends_with("..."));
        // 200 Chinese chars + "..."
        assert_eq!(result.chars().count(), 203);
    }

    #[test]
    fn test_debugger_default() {
        let debugger = Debugger::default();
        assert!(debugger.list_sessions().is_empty());
    }

    #[test]
    fn test_step_serialization() {
        let step = DebugStep::new(DebugStepType::HttpPost, "body_data");
        let json = serde_json::to_string(&step).unwrap();
        let deserialized: DebugStep = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.step_type, DebugStepType::HttpPost);
        assert_eq!(deserialized.input, "body_data");
    }

    #[test]
    fn test_session_serialization() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://s.com", "Src", "key");
        let session = debugger.get_session(&id).unwrap();

        let json = serde_json::to_string(&session).unwrap();
        let deserialized: DebugSession = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.source_name, "Src");
        assert_eq!(deserialized.status, "running");
    }

    #[test]
    fn test_multiple_steps_ordering() {
        let debugger = Debugger::new();
        let id = debugger.create_session("https://m.com", "Multi", "k");

        let types = [
            DebugStepType::HttpGet,
            DebugStepType::Search,
            DebugStepType::Toc,
            DebugStepType::Content,
        ];
        for (i, t) in types.iter().enumerate() {
            let mut step = DebugStep::new(t.clone(), &format!("input_{}", i));
            step.mark_success(&format!("output_{}", i), (i as u64 + 1) * 10);
            debugger.add_step(&id, step);
        }

        let session = debugger.get_session(&id).unwrap();
        assert_eq!(session.steps.len(), 4);
        assert_eq!(session.steps[0].step_type, DebugStepType::HttpGet);
        assert_eq!(session.steps[3].step_type, DebugStepType::Content);
        assert_eq!(session.total_duration_ms(), 100); // 10+20+30+40
    }
}
