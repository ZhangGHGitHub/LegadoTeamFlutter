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

use std::collections::HashMap;
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

/// 是否应采集本次请求（开关开启且已注册实现）
fn should_record() -> bool {
    RECORDING.load(Ordering::SeqCst) && RECORDER.get().is_some()
}

/// 提交一条记录（开关关闭/未注册实现时静默丢弃）
fn submit(entry: HttpLogEntry) {
    if !RECORDING.load(Ordering::SeqCst) {
        return;
    }
    if let Some(recorder) = RECORDER.get() {
        recorder.record(entry);
    }
}

/// 单次请求的采集上下文（仅开关开启时创建，`Drop` 不自动提交）
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
}
