//! 宿主注入面（P5 子批 2a）
//!
//! 共享 crate 不持有任何宿主（ffi/server）状态：HTTP 客户端、限流注册表、
//! 登录头缓存、DB 书籍变量、explore snapshot 驱动的书源 setup 脚本全部经
//! [`FetcherDeps`] 注入。字段为 `None` 时对应能力关闭（测试/最小宿主可用
//! `FetcherDeps::new` 起步）；ffi 与 server 两宿主均已全量注入（server 侧
//! 见 `handlers/web_book.rs::server_deps`，数据面为 AppState DB）。

use std::sync::Arc;

use legado_core::models::BookSource;
use legado_net::LegadoClient;

use crate::rate_limit::RateLimiterRegistry;

/// 登录头查询闭包（source_url → loginHeader JSON）
pub type LoginHeaderLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// 书籍变量查询闭包（书籍取址点 → variable JSON）
pub type BookVariableLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// 书源 JS setup 脚本生成闭包（source → setup script）
pub type SourceContextBuilder = Arc<dyn Fn(&BookSource) -> Option<String> + Send + Sync>;

/// 媒体副内容捕获闭包（bookUrl, sourceUrl, chapterUrl, key, value）
///
/// 契约 §2.49 写入侧：视频/音频书源的内容规则副内容（`contentRule.subContent`）
/// 在抓取链内捕获后交宿主落库（对齐原版 `BookContent.kt:138-155`
/// 音频 `putLyric` / 视频 `putDanmaku`）。`bookUrl` 为 `None` 表示抓取链
/// 未解析到书籍取址点（详情/目录阶段 meta 缓存未命中，如 `refreshToc`
/// 目录链）——宿主可据 `sourceUrl` + `chapterUrl` 走 DB 兜底反查后落库。
/// 共享 crate 不直接触库——本闭包是唯一落库出口（同 `book_variable` 注入先例）。
pub type MediaSubContentSink = Arc<dyn Fn(Option<&str>, &str, &str, &str, &str) + Send + Sync>;

/// 宿主注入载体
///
/// - `client`：HTTP 客户端（ffi 传进程共享单例 `http_state::shared_client()`，
///   与 JS 宿主 cookie 池同源；测试传独立默认客户端）；
/// - `rate_limiter`：书源 `concurrentRate` 限流注册表（进程级共享，按书源 URL
///   缓存窗口状态）；
/// - `login_header`：按书源 URL 取登录头 JSON（ffi=`source_login_cache`）；
/// - `book_variable`：按书籍取址点读用户书籍变量 JSON（ffi=`books.variable`
///   两路反查 bookUrl → originBookUrl）；
/// - `source_context`：按书源生成 JS setup 脚本（ffi=`source_js_bindings::
///   book_source_js_setup_script`，依赖 explore_info_map snapshot + 登录缓存）；
/// - `media_sub_content`：媒体副内容落库（ffi=`video_api::put_media_sub_content`，
///   章节 variable / 大数据文件分流，契约 §2.49）。
#[derive(Clone)]
pub struct FetcherDeps {
    /// HTTP 客户端
    pub client: LegadoClient,
    /// 书源限流注册表
    pub rate_limiter: Arc<RateLimiterRegistry>,
    /// 登录头查询（source_url → loginHeader JSON）
    pub login_header: Option<LoginHeaderLookup>,
    /// 书籍变量查询（书籍取址点 → variable JSON）
    pub book_variable: Option<BookVariableLookup>,
    /// 书源 JS setup 脚本生成（source → setup script）
    pub source_context: Option<SourceContextBuilder>,
    /// 媒体副内容捕获（bookUrl, chapterUrl, key, value）
    pub media_sub_content: Option<MediaSubContentSink>,
}

impl FetcherDeps {
    /// 仅注入客户端（其余能力为 None：登录头/书籍变量/书源 setup/副内容捕获全关闭）
    pub fn new(client: LegadoClient) -> Self {
        Self {
            client,
            rate_limiter: Arc::new(RateLimiterRegistry::new()),
            login_header: None,
            book_variable: None,
            source_context: None,
            media_sub_content: None,
        }
    }

    /// [`Self::new`] 别名（可读性：以客户端为最小注入面）
    pub fn with_client(client: LegadoClient) -> Self {
        Self::new(client)
    }

    /// 注入限流注册表
    pub fn with_rate_limiter(mut self, rate_limiter: Arc<RateLimiterRegistry>) -> Self {
        self.rate_limiter = rate_limiter;
        self
    }

    /// 注入登录头查询
    pub fn with_login_header(mut self, f: LoginHeaderLookup) -> Self {
        self.login_header = Some(f);
        self
    }

    /// 注入书籍变量查询
    pub fn with_book_variable(mut self, f: BookVariableLookup) -> Self {
        self.book_variable = Some(f);
        self
    }

    /// 注入书源 JS setup 脚本生成
    pub fn with_source_context(mut self, f: SourceContextBuilder) -> Self {
        self.source_context = Some(f);
        self
    }

    /// 注入媒体副内容捕获（契约 §2.49 写入侧；未注入 → 捕获点仅日志）
    pub fn with_media_sub_content_sink(mut self, f: MediaSubContentSink) -> Self {
        self.media_sub_content = Some(f);
        self
    }

    /// 捕获媒体副内容交宿主落库（对齐原版 `BookChapter.putLyric/putDanmaku`）
    ///
    /// 返回是否已交给宿主 sink。未注入 sink 或 `book_url` 未知（详情/目录
    /// 阶段 meta 缓存未命中）时仅记日志——副内容是增强层，任何缺失/失败
    /// 均不得阻断正文返回（对齐原版 `runCatching` 仅记日志语义）；宿主
    /// sink 可据 `source_url` + `chapter_url` 走 DB 兜底反查书籍取址点。
    pub fn capture_media_sub_content(
        &self,
        book_url: Option<&str>,
        source_url: &str,
        chapter_url: &str,
        key: &str,
        value: &str,
    ) -> bool {
        let Some(sink) = self.media_sub_content.as_ref() else {
            eprintln!(
                "[web_book] 媒体副内容（{key}）未落库：宿主未注入捕获 sink\
                 （book={book_url:?}，chapter={chapter_url}）"
            );
            return false;
        };
        let book_url = book_url.filter(|u| !u.trim().is_empty());
        if book_url.is_none() {
            // 抓取链 meta 未命中 → 交宿主兜底反查（sourceUrl + chapterUrl）
            eprintln!(
                "[web_book] 媒体副内容（{key}）书本取址点未命中 meta 缓存，\
                 转宿主 DB 兜底（source={source_url}，chapter={chapter_url}）"
            );
        }
        sink(book_url, source_url, chapter_url, key, value);
        true
    }

    /// 按书源 URL 取登录头 JSON（未注入 → None）
    pub fn login_header_for(&self, source_url: &str) -> Option<String> {
        self.login_header.as_ref().and_then(|f| f(source_url))
    }

    /// 按书籍取址点取用户书籍变量（未注入/空值 → None；空串过滤与原
    /// `db_book_variable` 语义一致）
    pub fn book_variable_for(&self, book_url: &str) -> Option<String> {
        self.book_variable
            .as_ref()
            .and_then(|f| f(book_url))
            .filter(|v| !v.trim().is_empty())
    }

    /// 按书源生成 JS setup 脚本（未注入 → None，等价无书源上下文）
    pub fn setup_script_for(&self, source: &BookSource) -> Option<String> {
        self.source_context.as_ref().and_then(|f| f(source))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 捕获调用记录：(bookUrl, sourceUrl, chapterUrl, key, value)
    type CapturedCalls = Arc<Mutex<Vec<(String, String, String, String, String)>>>;

    fn test_client() -> LegadoClient {
        LegadoClient::new(legado_net::LegadoClientConfig {
            no_proxy: true,
            ..legado_net::LegadoClientConfig::default()
        })
        .expect("test http client")
    }

    /// [V-B1 §2.49] 注入 sink 且 bookUrl 已知 → 闭包收到完整五元组
    #[test]
    fn test_capture_media_sub_content_calls_sink() {
        let got: CapturedCalls = Arc::new(Mutex::new(Vec::new()));
        let sink_got = Arc::clone(&got);
        let deps = FetcherDeps::new(test_client()).with_media_sub_content_sink(Arc::new(
            move |book, source, chapter, key, value| {
                sink_got.lock().unwrap().push((
                    book.unwrap_or_default().to_string(),
                    source.to_string(),
                    chapter.to_string(),
                    key.to_string(),
                    value.to_string(),
                ));
            },
        ));

        assert!(deps.capture_media_sub_content(
            Some("https://b.example/book"),
            "https://b.example",
            "https://b.example/ch/1",
            "danmaku",
            "<i><d p=\"1\"/></i>"
        ));
        let got = got.lock().unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, "https://b.example/book");
        assert_eq!(got[0].1, "https://b.example");
        assert_eq!(got[0].2, "https://b.example/ch/1");
        assert_eq!(got[0].3, "danmaku");
        assert_eq!(got[0].4, "<i><d p=\"1\"/></i>");
    }

    /// [V-B1 §2.49] 未注入 sink → 返回 false 且不 panic；bookUrl 未知时
    /// 仍调用 sink（宿主走 DB 兜底反查），book 参数为 None
    #[test]
    fn test_capture_media_sub_content_degrades_without_sink_or_book() {
        // 未注入 sink → false（降级仅日志，不阻断正文）
        let deps = FetcherDeps::new(test_client());
        assert!(!deps.capture_media_sub_content(
            Some("https://b.example/book"),
            "https://b.example",
            "https://b.example/ch/1",
            "danmaku",
            "x"
        ));

        // 注入 sink 但 bookUrl 未知 → 仍交宿主（sourceUrl 供兜底反查）
        let seen: Arc<Mutex<Vec<Option<String>>>> = Arc::new(Mutex::new(Vec::new()));
        let sink_seen = Arc::clone(&seen);
        let deps = FetcherDeps::new(test_client()).with_media_sub_content_sink(Arc::new(
            move |book, _, _, _, _| {
                sink_seen.lock().unwrap().push(book.map(str::to_string));
            },
        ));
        assert!(deps.capture_media_sub_content(
            None,
            "https://b.example",
            "https://b.example/ch/1",
            "lyric",
            "x"
        ));
        assert!(deps.capture_media_sub_content(
            Some("  "),
            "https://b.example",
            "https://b.example/ch/1",
            "lyric",
            "x"
        ));
        assert_eq!(
            seen.lock().unwrap().as_slice(),
            &[None, None],
            "bookUrl 未知/空白时应以 None 交宿主兜底"
        );
    }
}
