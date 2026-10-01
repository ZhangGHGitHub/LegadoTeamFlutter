//! 宿主注入面（P5 子批 2a）
//!
//! 共享 crate 不持有任何宿主（ffi/server）状态：HTTP 客户端、限流注册表、
//! 登录头缓存、DB 书籍变量、explore snapshot 驱动的书源 setup 脚本全部经
//! [`FetcherDeps`] 注入。字段为 `None` 时对应能力关闭——行为等于「旧 server
//! 版能力起点」（server 下批接入时以 `|_| None` 起步，再按需补齐）。

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
///   book_source_js_setup_script`，依赖 explore_info_map snapshot + 登录缓存）。
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
}

impl FetcherDeps {
    /// 仅注入客户端（其余能力为 None：登录头/书籍变量/书源 setup 全关闭）
    pub fn new(client: LegadoClient) -> Self {
        Self {
            client,
            rate_limiter: Arc::new(RateLimiterRegistry::new()),
            login_header: None,
            book_variable: None,
            source_context: None,
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
