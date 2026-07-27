//! 书源事件回调 API
//!
//! 对应 Kotlin `SourceCallBack.kt`，在书源操作的开始/结束时
//! 通知 JS 引擎，触发书源自定义逻辑。

use std::collections::HashMap;
use std::fmt;

/// 回调事件类型
#[derive(Debug, Clone, PartialEq)]
pub enum SourceEvent {
    /// 书架刷新开始
    BookshelfRefreshStart,
    /// 书架刷新结束
    BookshelfRefreshEnd,
    /// 搜索开始（附带查询关键词）
    SearchStart(String),
    /// 搜索结束（附带查询关键词）
    SearchEnd(String),
    /// 章节加载开始（附带章节 URL）
    ChapterLoadStart(String),
    /// 章节加载结束（附带章节 URL）
    ChapterLoadEnd(String),
    /// 正文加载开始（附带章节 URL）
    ContentLoadStart(String),
    /// 正文加载结束（附带章节 URL）
    ContentLoadEnd(String),
}

impl fmt::Display for SourceEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SourceEvent::BookshelfRefreshStart => write!(f, "BookshelfRefreshStart"),
            SourceEvent::BookshelfRefreshEnd => write!(f, "BookshelfRefreshEnd"),
            SourceEvent::SearchStart(q) => write!(f, "SearchStart({q})"),
            SourceEvent::SearchEnd(q) => write!(f, "SearchEnd({q})"),
            SourceEvent::ChapterLoadStart(url) => write!(f, "ChapterLoadStart({url})"),
            SourceEvent::ChapterLoadEnd(url) => write!(f, "ChapterLoadEnd({url})"),
            SourceEvent::ContentLoadStart(url) => write!(f, "ContentLoadStart({url})"),
            SourceEvent::ContentLoadEnd(url) => write!(f, "ContentLoadEnd({url})"),
        }
    }
}

impl SourceEvent {
    /// 获取事件名称（不含参数）
    pub fn event_name(&self) -> &'static str {
        match self {
            SourceEvent::BookshelfRefreshStart => "onBookshelfRefreshStart",
            SourceEvent::BookshelfRefreshEnd => "onBookshelfRefreshEnd",
            SourceEvent::SearchStart(_) => "onSearchStart",
            SourceEvent::SearchEnd(_) => "onSearchEnd",
            SourceEvent::ChapterLoadStart(_) => "onChapterLoadStart",
            SourceEvent::ChapterLoadEnd(_) => "onChapterLoadEnd",
            SourceEvent::ContentLoadStart(_) => "onContentLoadStart",
            SourceEvent::ContentLoadEnd(_) => "onContentLoadEnd",
        }
    }

    /// 获取事件附带的参数（如果有）
    pub fn payload(&self) -> Option<&str> {
        match self {
            SourceEvent::BookshelfRefreshStart | SourceEvent::BookshelfRefreshEnd => None,
            SourceEvent::SearchStart(q)
            | SourceEvent::SearchEnd(q)
            | SourceEvent::ChapterLoadStart(q)
            | SourceEvent::ChapterLoadEnd(q)
            | SourceEvent::ContentLoadStart(q)
            | SourceEvent::ContentLoadEnd(q) => Some(q),
        }
    }
}

/// 事件处理器回调类型
type EventHandler = Box<dyn Fn(&SourceEvent) + Send + Sync>;

/// 事件处理器注册表
///
/// 按书源 URL 分组管理事件回调处理器。
pub struct SourceCallbackRegistry {
    handlers: HashMap<String, Vec<EventHandler>>,
}

impl SourceCallbackRegistry {
    pub fn new() -> Self {
        Self {
            handlers: HashMap::new(),
        }
    }

    /// 注册事件处理器
    ///
    /// 同一书源可注册多个处理器，按注册顺序依次调用。
    pub fn register(&mut self, source_url: &str, handler: Box<dyn Fn(&SourceEvent) + Send + Sync>) {
        self.handlers
            .entry(source_url.to_string())
            .or_default()
            .push(handler);
    }

    /// 触发事件
    ///
    /// 调用指定书源的所有已注册处理器。
    pub fn fire(&self, source_url: &str, event: &SourceEvent) {
        if let Some(handlers) = self.handlers.get(source_url) {
            for handler in handlers {
                handler(event);
            }
        }
    }

    /// 注销某书源的所有处理器
    pub fn unregister(&mut self, source_url: &str) {
        self.handlers.remove(source_url);
    }

    /// 获取某书源已注册的处理器数量
    pub fn handler_count(&self, source_url: &str) -> usize {
        self.handlers.get(source_url).map_or(0, |h| h.len())
    }

    /// 是否有任何已注册的处理器
    pub fn is_empty(&self) -> bool {
        self.handlers.is_empty()
    }

    /// 已注册的书源数量
    pub fn source_count(&self) -> usize {
        self.handlers.len()
    }
}

impl Default for SourceCallbackRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// JS 侧回调：书架刷新开始
pub fn on_bookshelf_refresh_start() -> String {
    String::new()
}

/// JS 侧回调：书架刷新结束
pub fn on_bookshelf_refresh_end() -> String {
    String::new()
}

/// JS 侧回调：搜索开始
pub fn on_search_start(query: &str) -> String {
    format!("search_start:{query}")
}

/// JS 侧回调：搜索结束
pub fn on_search_end(query: &str) -> String {
    format!("search_end:{query}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[test]
    fn test_source_event_display() {
        assert_eq!(
            SourceEvent::BookshelfRefreshStart.to_string(),
            "BookshelfRefreshStart"
        );
        assert_eq!(
            SourceEvent::SearchStart("斗破苍穹".to_string()).to_string(),
            "SearchStart(斗破苍穹)"
        );
        assert_eq!(
            SourceEvent::ChapterLoadEnd("https://a.com/1".to_string()).to_string(),
            "ChapterLoadEnd(https://a.com/1)"
        );
    }

    #[test]
    fn test_source_event_name_and_payload() {
        let ev = SourceEvent::SearchStart("test".to_string());
        assert_eq!(ev.event_name(), "onSearchStart");
        assert_eq!(ev.payload(), Some("test"));

        let ev2 = SourceEvent::BookshelfRefreshEnd;
        assert_eq!(ev2.event_name(), "onBookshelfRefreshEnd");
        assert_eq!(ev2.payload(), None);
    }

    #[test]
    fn test_registry_register_and_fire() {
        let mut registry = SourceCallbackRegistry::new();
        let counter = Arc::new(AtomicUsize::new(0));
        let counter_clone = counter.clone();

        registry.register(
            "https://source.com",
            Box::new(move |_event| {
                counter_clone.fetch_add(1, Ordering::SeqCst);
            }),
        );

        registry.fire("https://source.com", &SourceEvent::BookshelfRefreshStart);
        registry.fire("https://source.com", &SourceEvent::BookshelfRefreshEnd);

        assert_eq!(counter.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn test_registry_multiple_handlers() {
        let mut registry = SourceCallbackRegistry::new();
        let counter = Arc::new(AtomicUsize::new(0));

        for _ in 0..3 {
            let c = counter.clone();
            registry.register(
                "https://multi.com",
                Box::new(move |_| {
                    c.fetch_add(1, Ordering::SeqCst);
                }),
            );
        }

        assert_eq!(registry.handler_count("https://multi.com"), 3);
        registry.fire(
            "https://multi.com",
            &SourceEvent::SearchStart("q".to_string()),
        );
        assert_eq!(counter.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn test_registry_unregister() {
        let mut registry = SourceCallbackRegistry::new();
        registry.register("https://a.com", Box::new(|_| {}));
        registry.register("https://b.com", Box::new(|_| {}));

        assert_eq!(registry.source_count(), 2);

        registry.unregister("https://a.com");
        assert_eq!(registry.source_count(), 1);
        assert_eq!(registry.handler_count("https://a.com"), 0);
        assert_eq!(registry.handler_count("https://b.com"), 1);
    }

    #[test]
    fn test_registry_fire_nonexistent_source() {
        let registry = SourceCallbackRegistry::new();
        // 不应 panic
        registry.fire("https://nonexist.com", &SourceEvent::BookshelfRefreshStart);
    }

    #[test]
    fn test_registry_is_empty() {
        let mut registry = SourceCallbackRegistry::new();
        assert!(registry.is_empty());

        registry.register("https://x.com", Box::new(|_| {}));
        assert!(!registry.is_empty());
    }

    #[test]
    fn test_js_callback_functions() {
        assert_eq!(on_bookshelf_refresh_start(), "");
        assert_eq!(on_bookshelf_refresh_end(), "");
        assert_eq!(on_search_start("query"), "search_start:query");
        assert_eq!(on_search_end("done"), "search_end:done");
    }

    #[test]
    fn test_event_filtering_by_type() {
        let mut registry = SourceCallbackRegistry::new();
        let search_count = Arc::new(AtomicUsize::new(0));
        let sc = search_count.clone();

        registry.register(
            "https://filter.com",
            Box::new(move |event| {
                if matches!(
                    event,
                    SourceEvent::SearchStart(_) | SourceEvent::SearchEnd(_)
                ) {
                    sc.fetch_add(1, Ordering::SeqCst);
                }
            }),
        );

        registry.fire(
            "https://filter.com",
            &SourceEvent::SearchStart("a".to_string()),
        );
        registry.fire("https://filter.com", &SourceEvent::BookshelfRefreshStart);
        registry.fire(
            "https://filter.com",
            &SourceEvent::SearchEnd("a".to_string()),
        );

        assert_eq!(search_count.load(Ordering::SeqCst), 2);
    }
}
