//! HTTP 请求日志采集接口（对齐原版 `HttpLogInterceptor` 的可插拔采集点）
//!
//! ## 依赖方向（硬约束）
//!
//! `legado-net` 不依赖 `legado-server` / `legado-db`：本模块只定义采集数据结构
//! [`HttpLogEntry`]、采集实现 trait [`HttpLogRecorder`] 与进程级注册/开关，具体
//! 存储（环形 50 条、脱敏、截断）由上层实现（`legado-server::legacy::http_log`
//! 的 `HttpLogStore`），在进程启动时经 [`install_recorder`] 注入。
//!
//! ## 语义对齐（原版 `help/http/HttpLogInterceptor.kt`）
//!
//! - 拦截器在**每次调用**（而非每次网络重试/每一跳重定向）记录一条：本实现
//!   在 [`crate::LegadoClient`] 的统一发送出口于**最终结果**处提交一次，重试
//!   与重定向链都不会产生重复记录；
//! - 开关 `enabled()` 在请求开始时判定一次——关闭时不构建任何采集上下文
//!   （等价原版 `if (!enabled()) return chain.proceed(...)`）；
//! - 记录字段：方法、原始请求 URL（对齐原版 `request.url`，非重定向最终 URL）、
//!   请求头/请求体、响应状态码、响应头/响应体、耗时、失败摘要（成功为 None）；
//! - 失败分支：statusCode=-1、响应字段为空、error=异常摘要（原版取异常类名，
//!   本实现取错误 `Display`，登记差异——信息量更大且同为单行摘要）。
//!
//! ## 已知登记差异
//!
//! - 请求头取**调用方显式传入**的 header map（已剔除内部 `CookieJar` 标记头），
//!   不含客户端默认头（Keep-Alive/Connection/Cache-Control）与 DB Cookie 合并
//!   结果；原版记录 okhttp 实际发送头。差异登记：默认头不参与脱敏判定、Cookie
//!   合并串不入日志；
//! - 流式响应（[`crate::LegadoClient::send_stream`]）无法在消费前 peep 响应体，
//!   响应体字段留空（原版 `peekBody(8192)` 不消费 body；reqwest 无等价 API）。
//!
//! ## 调试会话内请求观测（批13：WS 书源调试请求级日志）
//!
//! 全局 [`RECORDER`] 是 first-wins 单槽（进程级存储实现只有一个，不能按会话
//! 切换）；WS 调试通道需要**仅本会话**的请求流，故另设任务局部观测槽
//! [`DEBUG_SINK`]：
//!
//! - [`scope_debug_request_sink`] 把回调注入当前任务的 `task_local` 作用域，
//!   `LegadoClient` 在同一任务内同步调用，故请求采集上下文经
//!   [`HttpLogCapture::start`] 建立、[`submit`] 提交时能读到该回调；
//! - 观测槽**独立于全局开关**：`recordHttpLog` 关闭时调试会话仍能拿到请求
//!   事件（原版 `Debug` 与 `HttpLogInterceptor` 本来就是两套机制）；
//! - 两者互不干扰：全局开关打开时，同一条记录既进全局存储、也进调试回调；
//! - `tokio::spawn` 出的**新任务不继承**该作用域（与 `task_local` 语义一致），
//!   书源规则链的抓取全部在同任务内 `await`，无遗漏（JS 书源走
//!   `spawn_blocking`，本身不经 `LegadoClient`，不在采集面内——登记）。

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Instant;

/// 一条 HTTP 请求日志（采集侧中间形态；字段与 `legado-server` 的
/// `HttpLogRecord` 一一对应，由上层实现做脱敏/截断后落存储）
#[derive(Debug, Clone)]
pub struct HttpLogEntry {
    /// 请求方法（GET/POST/HEAD/…）
    pub method: String,
    /// 原始请求 URL（重定向前；对齐原版 `request.url`）
    pub url: String,
    /// 调用方显式传入的请求头（不含内部 `CookieJar` 标记头）
    pub request_headers: HashMap<String, String>,
    /// 请求体文本（无请求体为空串）
    pub request_body: String,
    /// 响应状态码；请求异常为 -1（对齐原版拦截器异常分支）
    pub status_code: i32,
    /// 响应头（失败时为空 map）
    pub response_headers: HashMap<String, String>,
    /// 响应体文本（流式路径为空串；失败时为空串）
    pub response_body: String,
    /// 响应 `Content-Type`（用于二进制体判定；失败时为 None）
    pub response_content_type: Option<String>,
    /// 请求耗时（毫秒）
    pub duration_ms: i64,
    /// 失败摘要；成功为 None
    pub error: Option<String>,
}

/// HTTP 日志采集实现（由上层注册；进程级单例）
///
/// 实现方负责脱敏（`HttpLogSanitizer` 等价规则）、单条截断与环形容量上限；
/// 本 trait 在请求路径上同步调用，实现必须**快速返回且不得 panic**。
pub trait HttpLogRecorder: Send + Sync {
    /// 提交一条采集记录
    fn record(&self, entry: HttpLogEntry);
}

/// 进程级采集实现单槽（对齐原版 `HttpLogStore` 单例；first-wins）
static RECORDER: OnceLock<Arc<dyn HttpLogRecorder>> = OnceLock::new();

/// 调试会话请求观测回调类型（由 WS 调试通道注入，逐请求同步调用）
///
/// 参数为本次调用的最终采集记录（重试/重定向链只提交一次），实现方可按需
/// 取 URL/方法/状态码/耗时/响应体大小；实现必须快速返回且不得 panic。
pub type DebugRequestSink = Arc<dyn Fn(HttpLogEntry) + Send + Sync>;

tokio::task_local! {
    /// 任务局部调试请求观测槽（与进程级 [`RECORDER`] 相互独立）
    ///
    /// 仅在 [`scope_debug_request_sink`] 作用域内存在；作用域外读取返回
    /// `AccessError`（按无观测者处理，不 panic）。
    static DEBUG_SINK: DebugRequestSink;
}

/// 在 `future` 的任务作用域内注入调试请求观测回调
///
/// 对齐原版 `Debug.Callback`（`WebSocket` 连接即回调宿主）的「会话内可见」
/// 语义：只有本任务（含其内部 `await` 链）产生的 `LegadoClient` 请求会被
/// 回调，进程内其他并发任务不受影响，也不会与全局 [`RECORDER`] 抢占单槽。
pub fn scope_debug_request_sink<F, T>(sink: DebugRequestSink, future: F) -> impl Future<Output = T>
where
    F: Future<Output = T>,
{
    DEBUG_SINK.scope(sink, future)
}

/// 取当前任务的调试观测回调（作用域外为 None）
fn current_debug_sink() -> Option<DebugRequestSink> {
    // `try_with` 在作用域外返回 Err（不 panic），对齐「无观测者」语义
    DEBUG_SINK.try_with(Arc::clone).ok()
}

/// 运行期开关（对齐原版 `AppConfig.recordHttpLog`，缺省 false）
static RECORDING: AtomicBool = AtomicBool::new(false);

/// 注册采集实现（幂等：重复注册保留首次注册者并忽略后续）
pub fn install_recorder(recorder: Arc<dyn HttpLogRecorder>) {
    let _ = RECORDER.set(recorder);
}

/// 是否已注册采集实现（测试/诊断用）
pub fn recorder_installed() -> bool {
    RECORDER.get().is_some()
}

/// 设置运行期开关（对齐 `AppConfig.recordHttpLog` 的 setter）
///
/// 开关由宿主（FFI `setHttpLogRecording` / 服务启动读库）注入；关闭时请求
/// 路径不构建采集上下文，零额外开销。
pub fn set_recording_enabled(enabled: bool) {
    RECORDING.store(enabled, Ordering::SeqCst);
}

/// 运行期开关当前值
pub fn is_recording_enabled() -> bool {
    RECORDING.load(Ordering::SeqCst)
}

/// 是否应采集本次请求
///
/// 两路独立触发（任一成立即建立采集上下文）：
/// - 全局开关开启且已注册存储实现（原版 `AppConfig.recordHttpLog` 语义）；
/// - 当前任务处于调试会话观测作用域（WS 调试通道请求级日志，见模块文档）。
fn should_record() -> bool {
    (RECORDING.load(Ordering::SeqCst) && RECORDER.get().is_some()) || current_debug_sink().is_some()
}

/// 提交一条记录（无全局开关/无观测者时静默丢弃）
///
/// 两路消费方互不排斥：调试会话观测槽先收（原样记录），全局存储后收
/// （自行脱敏/截断/入环）。
fn submit(entry: HttpLogEntry) {
    if let Some(sink) = current_debug_sink() {
        sink(entry.clone());
    }
    if RECORDING.load(Ordering::SeqCst) {
        if let Some(recorder) = RECORDER.get() {
            recorder.record(entry);
        }
    }
}

/// 单次请求的采集上下文（仅开关开启或处于调试观测作用域时创建，
/// `Drop` 不自动提交）
///
/// 用法：请求开始处 [`HttpLogCapture::start`] 取 `Option<Self>`，最终结果处
/// [`Self::finish_success`] / [`Self::finish_failure`] 提交一次；中途提前返回
/// 而忘记提交时不会被记录（避免半成品日志）。
pub struct HttpLogCapture {
    method: String,
    url: String,
    request_headers: HashMap<String, String>,
    request_body: String,
    started: Instant,
}

impl HttpLogCapture {
    /// 开启采集上下文（开关关闭/未注册实现时返回 None）
    ///
    /// `request_headers` 为调用方显式传入的头；内部 `CookieJar` 标记头在
    /// 此处剔除（对齐原版拦截器 `removeHeader(cookieJarHeader)` 后不再外发）。
    pub fn start(
        method: &str,
        url: &str,
        request_headers: Option<&HashMap<String, String>>,
        request_body: &str,
    ) -> Option<Self> {
        if !should_record() {
            return None;
        }
        let request_headers = request_headers
            .map(|headers| {
                headers
                    .iter()
                    .filter(|(name, _)| {
                        !name.eq_ignore_ascii_case(crate::client::COOKIE_JAR_HEADER)
                    })
                    .map(|(name, value)| (name.clone(), value.clone()))
                    .collect()
            })
            .unwrap_or_default();
        Some(Self {
            method: method.to_string(),
            url: url.to_string(),
            request_headers,
            request_body: request_body.to_string(),
            started: Instant::now(),
        })
    }

    /// 提交成功记录（HTTP 非 2xx 也走此分支，状态码原样，对齐原版）
    pub fn finish_success(
        self,
        status_code: i32,
        response_headers: &HashMap<String, String>,
        response_body: &str,
        response_content_type: Option<&str>,
    ) {
        submit(HttpLogEntry {
            method: self.method,
            url: self.url,
            request_headers: self.request_headers,
            request_body: self.request_body,
            status_code,
            response_headers: response_headers.clone(),
            response_body: response_body.to_string(),
            response_content_type: response_content_type.map(str::to_string),
            duration_ms: self.started.elapsed().as_millis() as i64,
            error: None,
        });
    }

    /// 提交失败记录（statusCode=-1、响应字段为空、error=错误摘要）
    pub fn finish_failure(self, error: impl Into<String>) {
        submit(HttpLogEntry {
            method: self.method,
            url: self.url,
            request_headers: self.request_headers,
            request_body: self.request_body,
            status_code: -1,
            response_headers: HashMap::new(),
            response_body: String::new(),
            response_content_type: None,
            duration_ms: self.started.elapsed().as_millis() as i64,
            error: Some(error.into()),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 串行锁：开关与单槽为进程级状态，用例间不得并发切换
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    /// 测试用采集实现：把记录追加到进程级 Vec
    #[derive(Default)]
    struct VecRecorder {
        entries: Mutex<Vec<HttpLogEntry>>,
    }

    impl HttpLogRecorder for VecRecorder {
        fn record(&self, entry: HttpLogEntry) {
            self.entries.lock().unwrap().push(entry);
        }
    }

    fn global_recorder() -> &'static Arc<VecRecorder> {
        static RECORDER: OnceLock<Arc<VecRecorder>> = OnceLock::new();
        RECORDER.get_or_init(|| {
            let recorder = Arc::new(VecRecorder::default());
            install_recorder(recorder.clone());
            recorder
        })
    }

    fn matching(recorder: &VecRecorder, needle: &str) -> Vec<HttpLogEntry> {
        recorder
            .entries
            .lock()
            .unwrap()
            .iter()
            .filter(|entry| entry.url.contains(needle))
            .cloned()
            .collect()
    }

    #[test]
    fn test_capture_disabled_returns_none_and_submits_nothing() {
        let _g = TEST_LOCK.lock().unwrap();
        let recorder = global_recorder();
        set_recording_enabled(false);
        assert!(HttpLogCapture::start("GET", "https://disabled.example/", None, "").is_none());
        set_recording_enabled(false);
        assert!(matching(recorder, "disabled.example").is_empty());
    }

    #[test]
    fn test_capture_enabled_records_once_and_strips_cookie_jar_marker() {
        let _g = TEST_LOCK.lock().unwrap();
        let recorder = global_recorder();
        set_recording_enabled(true);
        let mut headers = HashMap::new();
        headers.insert("CookieJar".to_string(), "1".to_string());
        headers.insert("X-Trace".to_string(), "visible".to_string());
        let capture = HttpLogCapture::start(
            "GET",
            "https://capture.example/token/abc?page=2",
            Some(&headers),
            "",
        )
        .expect("开关开启时应建立采集上下文");
        capture.finish_success(
            200,
            &HashMap::new(),
            "ok",
            Some("text/plain; charset=utf-8"),
        );
        set_recording_enabled(false);

        let entries = matching(recorder, "capture.example");
        assert_eq!(entries.len(), 1, "一次采集上下文只提交一条");
        assert_eq!(entries[0].status_code, 200);
        assert_eq!(entries[0].response_body, "ok");
        assert_eq!(
            entries[0]
                .request_headers
                .get("X-Trace")
                .map(String::as_str),
            Some("visible")
        );
        assert!(
            !entries[0].request_headers.contains_key("CookieJar"),
            "内部 CookieJar 标记头不得进入日志"
        );
        assert!(entries[0].error.is_none());
    }

    #[test]
    fn test_capture_failure_shape() {
        let _g = TEST_LOCK.lock().unwrap();
        let recorder = global_recorder();
        set_recording_enabled(true);
        let capture = HttpLogCapture::start("POST", "https://failure.example/x", None, "body")
            .expect("开关开启时应建立采集上下文");
        capture.finish_failure("Connection failed: refused");
        set_recording_enabled(false);

        let entries = matching(recorder, "failure.example");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status_code, -1);
        assert!(entries[0].response_headers.is_empty());
        assert!(entries[0].response_body.is_empty());
        assert_eq!(entries[0].request_body, "body");
        assert_eq!(
            entries[0].error.as_deref(),
            Some("Connection failed: refused")
        );
    }

    /// 会话观测槽：全局开关关闭时仍采集，且只回调本任务作用域内的请求
    ///
    /// `allow(await_holding_lock)`：串行锁保护的是**进程级**开关/单槽，
    /// 必须覆盖整个 `async` 用例体（用例各跑在独立 current_thread runtime 上，
    /// 不存在同 runtime 其他任务被该锁阻塞的情形）。
    #[allow(clippy::await_holding_lock)]
    #[tokio::test]
    async fn test_debug_sink_captures_inside_scope_only() {
        let _g = TEST_LOCK.lock().unwrap();
        let recorder = global_recorder();
        set_recording_enabled(false);

        #[derive(Default)]
        struct Seen(Mutex<Vec<HttpLogEntry>>);
        let seen = Arc::new(Seen::default());
        let seen_for_sink = Arc::clone(&seen);
        let sink: DebugRequestSink = Arc::new(move |entry| {
            seen_for_sink.0.lock().unwrap().push(entry);
        });

        scope_debug_request_sink(Arc::clone(&sink), async {
            let capture =
                HttpLogCapture::start("GET", "https://scope.example/token/abc?page=2", None, "")
                    .expect("调试作用域内应建立采集上下文（与全局开关无关）");
            capture.finish_success(200, &HashMap::new(), "ok", Some("text/plain"));
        })
        .await;

        let entries = seen.0.lock().unwrap().clone();
        assert_eq!(entries.len(), 1, "作用域内一次请求应回调一条");
        assert_eq!(entries[0].method, "GET");
        assert_eq!(entries[0].status_code, 200);
        // 观测槽拿到的是原始记录（未脱敏），供调试通道原样展示
        assert_eq!(
            entries[0].url, "https://scope.example/token/abc?page=2",
            "观测槽记录应为原始请求 URL"
        );
        assert!(
            matching(recorder, "scope.example").is_empty(),
            "全局开关关闭时不得写入全局存储"
        );

        // 作用域结束后不再观测（同任务内顺序调用）
        assert!(
            HttpLogCapture::start("GET", "https://after.example/", None, "").is_none(),
            "作用域外且开关关闭时不应创建采集上下文"
        );
        assert_eq!(seen.0.lock().unwrap().len(), 1);
    }

    /// 会话观测槽与全局开关并存：一条记录两路各收一次，互不吞并
    ///
    /// `allow(await_holding_lock)`：同 [`test_debug_sink_captures_inside_scope_only`]
    /// 的理由——串行锁保护进程级开关/单槽，需覆盖整个用例体。
    #[allow(clippy::await_holding_lock)]
    #[tokio::test]
    async fn test_debug_sink_and_global_recorder_coexist() {
        let _g = TEST_LOCK.lock().unwrap();
        let recorder = global_recorder();
        set_recording_enabled(true);

        let seen = Arc::new(Mutex::new(Vec::<HttpLogEntry>::new()));
        let seen_for_sink = Arc::clone(&seen);
        let sink: DebugRequestSink = Arc::new(move |entry| {
            seen_for_sink.lock().unwrap().push(entry);
        });

        scope_debug_request_sink(sink, async {
            let capture = HttpLogCapture::start("POST", "https://coexist.example/x", None, "body")
                .expect("开关开启时应建立采集上下文");
            capture.finish_failure("boom");
        })
        .await;
        set_recording_enabled(false);

        let scoped = seen.lock().unwrap().clone();
        assert_eq!(scoped.len(), 1, "观测槽应收到一条");
        assert_eq!(scoped[0].error.as_deref(), Some("boom"));
        let stored = matching(recorder, "coexist.example");
        assert_eq!(stored.len(), 1, "全局存储应同时收到一条");
        assert_eq!(stored[0].error.as_deref(), Some("boom"));
    }
}
