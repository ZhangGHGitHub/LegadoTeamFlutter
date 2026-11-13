//! 书源有效性检查器
//!
//! 参考 Kotlin `CheckSource.kt` 与 `SourceVerificationHelp.kt`，实现书源搜索/目录/内容的有效性检查。
//! 通过 `LegadoClient` 发起 HTTP 请求，验证书源规则是否可正常工作。
//! 增强功能：验证码识别、重定向详情检测（对齐 `SourceVerificationHelp`）。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use legado_core::models::BookSource;

use crate::client::LegadoClient;
use crate::response::LegadoResponse;

/// 验证码检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptchaInfo {
    /// 是否检测到验证码
    pub detected: bool,
    /// 验证码类型描述（如 "图片验证码"、"滑动验证" 等）
    pub captcha_type: Option<String>,
    /// 匹配到的关键词/元素
    pub matched_keyword: Option<String>,
}

impl CaptchaInfo {
    /// 未检测到验证码
    fn none() -> Self {
        Self {
            detected: false,
            captcha_type: None,
            matched_keyword: None,
        }
    }
}

/// 重定向检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedirectInfo {
    /// 是否发生了重定向
    pub redirected: bool,
    /// 原始请求 URL
    pub original_url: String,
    /// 最终 URL（重定向后的地址）
    pub final_url: String,
    /// 是否重定向到登录/验证页面
    pub is_login_redirect: bool,
}

impl RedirectInfo {
    /// 未发生重定向
    fn none(url: &str) -> Self {
        Self {
            redirected: false,
            original_url: url.to_string(),
            final_url: url.to_string(),
            is_login_redirect: false,
        }
    }
}

/// 书源有效性检查结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    /// 书源 URL
    pub source_url: String,
    /// 搜索是否成功
    pub search_ok: bool,
    /// 目录是否成功
    pub toc_ok: bool,
    /// 内容是否成功
    pub content_ok: bool,
    /// 搜索阶段错误信息
    pub search_error: Option<String>,
    /// 目录阶段错误信息
    pub toc_error: Option<String>,
    /// 内容阶段错误信息
    pub content_error: Option<String>,
    /// 总耗时（毫秒）
    pub total_time_ms: i64,
    /// 验证码检测结果
    pub captcha: Option<CaptchaInfo>,
    /// 重定向检测结果
    pub redirect: Option<RedirectInfo>,
    /// 是否被用户主动取消（P1-5）
    ///
    /// `true` 表示校验在完成前收到取消请求（[`CancelToken`]），此时
    /// 各步错误字段为 `"cancelled"` / `"skipped: cancelled"`，**不表示
    /// 书源不可用**。批量校验流遇到该结果会静默结束，不再回推后续进度。
    #[serde(default)]
    pub cancelled: bool,
}

impl CheckResult {
    /// 创建全部失败的检查结果
    #[allow(dead_code)]
    fn all_failed(source_url: &str, error: &str) -> Self {
        Self {
            source_url: source_url.to_string(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: Some(error.to_string()),
            toc_error: Some("skipped".to_string()),
            content_error: Some("skipped".to_string()),
            total_time_ms: 0,
            captcha: None,
            redirect: None,
            cancelled: false,
        }
    }

    /// 所有检查是否都通过
    pub fn all_ok(&self) -> bool {
        !self.cancelled && self.search_ok && self.toc_ok && self.content_ok
    }

    /// 校验是否被用户主动取消
    ///
    /// 取消态不是「书源不可用」：批量校验不应把它计入失败统计/清源依据。
    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }

    /// 搜索检查是否通过
    pub fn is_search_ok(&self) -> bool {
        self.search_ok
    }

    /// 是否检测到验证码
    pub fn has_captcha(&self) -> bool {
        self.captcha.as_ref().is_some_and(|c| c.detected)
    }

    /// 是否发生了重定向
    pub fn has_redirect(&self) -> bool {
        self.redirect.as_ref().is_some_and(|r| r.redirected)
    }

    /// 书源是否可用（快速判断：未取消、搜索通过且无验证码阻断）
    ///
    /// P3-1：`cancelled` 必须排除——搜索请求成功但后续被用户取消时，
    /// 结果不是「书源可用」，与 [`Self::all_ok`] 的判定口径保持一致。
    pub fn is_available(&self) -> bool {
        !self.cancelled && self.search_ok && !self.has_captcha()
    }

    /// 收尾：写入总耗时
    fn finish_at(mut self, start: Instant) -> Self {
        self.total_time_ms = start.elapsed().as_millis() as i64;
        self
    }

    /// 收尾：标记用户取消并写入总耗时
    fn finish_cancelled(mut self, start: Instant) -> Self {
        self.cancelled = true;
        self.finish_at(start)
    }
}

/// 默认搜索关键词（对应 Kotlin `CheckSource.keyword`）
const DEFAULT_KEYWORD: &str = "我的";

/// 取消标志轮询间隔
///
/// 「停止校验」的响应上界：即使请求正卡在网络上，`select!` 也会在
/// 一个轮询周期内丢弃请求 future 返回（远小于用户可感知的 1s）。
const CANCEL_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);

/// 单步超时下界（防御 0 值配置：避免每次请求立即失败）
const MIN_STEP_TIMEOUT_MS: u64 = 100;

/// 单步/整源超时上界（防御异常配置：避免 `Instant` 加法溢出）
const MAX_STEP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(24 * 60 * 60);

/// 步骤超时标记（写入 `search_error` / `toc_error` / `content_error`）
pub const STEP_TIMEOUT_ERROR: &str = "timeout";

/// 步骤被用户取消的标记
pub const STEP_CANCELLED_ERROR: &str = "cancelled";

/// 因用户取消而跳过的后续步骤标记
pub const STEP_SKIPPED_CANCELLED: &str = "skipped: cancelled";

/// 单步执行结果（P1-5：区分超时、用户取消与业务失败）
enum StepOutcome<T> {
    /// 步骤完成
    Done(T),
    /// 步骤业务失败（网络错误、状态码/空响应、规则匹配失败等）
    Failed(String),
    /// 步骤超过 `step_timeout_ms`（或整源总预算耗尽）
    TimedOut,
    /// 用户主动取消（不计为书源不可用）
    Cancelled,
}

/// 等待取消令牌置位（`None` 表示无取消能力：永不返回）
async fn wait_for_cancel(token: Option<CancelToken>) {
    match token {
        Some(token) => {
            while !token.is_cancelled() {
                tokio::time::sleep(CANCEL_POLL_INTERVAL).await;
            }
        }
        None => std::future::pending::<()>().await,
    }
}

/// 标记「本步被取消 / 后续步骤因取消跳过」，未启用的步骤直接置为通过
fn mark_cancelled_step(
    error: &mut Option<String>,
    enabled: bool,
    ok: &mut bool,
    at_this_step: bool,
) {
    if !enabled {
        *ok = true;
        return;
    }
    let message = if at_this_step {
        STEP_CANCELLED_ERROR
    } else {
        STEP_SKIPPED_CANCELLED
    };
    *error = Some(message.to_string());
}

/// 校验取消令牌（批量校验共享，对齐 Kotlin `CheckSource.stop`）
///
/// 由调用方（如 legado-ffi 的批量校验流）创建并经
/// [`SourceChecker::with_cancel_token`] 注入。检查器在每个网络步骤的
/// `select!` 中轮询该标志；置位后当前请求立即被丢弃，`CheckResult`
/// 以 [`CheckResult::cancelled`] 标记返回，而不是记为书源失败。
#[derive(Debug, Clone, Default)]
pub struct CancelToken {
    flag: Arc<AtomicBool>,
}

impl CancelToken {
    /// 创建未取消的令牌
    pub fn new() -> Self {
        Self::default()
    }

    /// 置位取消（幂等；可由任意线程/上下文调用）
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
    }

    /// 是否已取消
    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// 复位为未取消
    ///
    /// 仅用于**复用同一令牌**的调用方。批量校验已改为会话级新令牌
    ///（legado-ffi `source_check_api`），不再依赖 reset。
    pub fn reset(&self) {
        self.flag.store(false, Ordering::SeqCst);
    }
}

/// 书源检查器配置
#[derive(Debug, Clone)]
pub struct CheckerConfig {
    /// 搜索关键词
    pub keyword: String,
    /// 单步超时（毫秒，默认 180_000）
    ///
    /// 每个网络步骤（搜索 / 详情 / 目录 / 正文）独立计时；整源总预算为
    /// `step_timeout_ms × 启用步数`（见 [`SourceChecker::check_full`]）。
    /// 超时记为该步失败（`"timeout"`）而非放弃整源。防御性夹取
    /// 100ms~24h。
    pub step_timeout_ms: u64,
    /// 是否检查搜索
    pub check_search: bool,
    /// 是否检查目录
    pub check_toc: bool,
    /// 是否检查内容
    pub check_content: bool,
    /// 是否启用验证码检测
    pub detect_captcha: bool,
    /// 是否启用重定向检测
    pub detect_redirect: bool,
}

impl Default for CheckerConfig {
    fn default() -> Self {
        Self {
            keyword: DEFAULT_KEYWORD.to_string(),
            step_timeout_ms: 180_000,
            check_search: true,
            check_toc: true,
            check_content: true,
            detect_captcha: true,
            detect_redirect: true,
        }
    }
}

/// 书源检查器
///
/// 使用 `LegadoClient` 对书源的搜索、目录、内容规则进行有效性检查。
pub struct SourceChecker {
    client: Arc<LegadoClient>,
    config: CheckerConfig,
    /// 取消令牌（批量校验注入；单本校验为 `None`，仅受超时约束）
    cancel: Option<CancelToken>,
}

impl SourceChecker {
    /// 使用默认配置创建检查器
    pub fn new(client: Arc<LegadoClient>) -> Self {
        Self {
            client,
            config: CheckerConfig::default(),
            cancel: None,
        }
    }

    /// 使用自定义配置创建检查器
    pub fn with_config(client: Arc<LegadoClient>, config: CheckerConfig) -> Self {
        Self {
            client,
            config,
            cancel: None,
        }
    }

    /// 注入取消令牌（批量校验「停止」用）
    pub fn with_cancel_token(mut self, token: CancelToken) -> Self {
        self.cancel = Some(token);
        self
    }

    /// 当前生效的检查配置（供上层断言 DTO → 配置链路）
    pub fn config(&self) -> &CheckerConfig {
        &self.config
    }

    /// 取消标志是否已置位
    fn is_cancelled(&self) -> bool {
        self.cancel.as_ref().is_some_and(CancelToken::is_cancelled)
    }

    /// 生效的单步超时（契约字段 [`CheckerConfig::step_timeout_ms`]）
    ///
    /// 防御性夹取：`0` 会使每次请求立即失败，下限取 [`MIN_STEP_TIMEOUT_MS`]；
    /// 上限取 [`MAX_STEP_TIMEOUT`]（24h），避免 `Instant` 加法溢出。
    fn effective_step_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.config.step_timeout_ms.max(MIN_STEP_TIMEOUT_MS))
            .min(MAX_STEP_TIMEOUT)
    }

    /// 整源总预算的步数（仅统计启用的步骤，至少 1）
    fn enabled_step_count(&self) -> u32 {
        let mut count = 0;
        if self.config.check_search {
            count += 1;
        }
        if self.config.check_toc {
            count += 1;
        }
        if self.config.check_content {
            count += 1;
        }
        count.max(1)
    }

    /// 整源总上限：`step_timeout_ms × 步数`
    ///
    /// 防多步叠加无界：每步预算取 `min(step_timeout, 距离 deadline 的剩余)`
    /// （见 [`Self::run_step`]），整源耗时不会超过该值。
    fn total_deadline(&self, start: Instant, steps: u32) -> Instant {
        start + self.effective_step_timeout() * steps.max(1)
    }

    /// 执行单个网络步骤：单步超时 + 取消可中断
    ///
    /// - 超时 → [`StepOutcome::TimedOut`]（记 `"timeout"`，继续由调用方
    ///   决定后续步骤的跳过语义）；
    /// - 取消 → [`StepOutcome::Cancelled`]（用户主动，返回前丢弃请求 future，
    ///   在 [`CANCEL_POLL_INTERVAL`] 内生效）；
    /// - 业务失败 → [`StepOutcome::Failed`]（保留原错误文案）。
    ///
    /// 整源总预算耗尽时不再发起请求，直接返回 `TimedOut`。
    ///
    /// # 取消是协作式的（P3-2）
    ///
    /// `select!` 只能在本函数内部的 await 点（`step` 的 HTTP future）抢占。
    /// `step` 内部若含**同步 CPU 段**——例如 [`Self::do_search_check`] 返回后
    /// 的响应体正则提取（`extract_first_book_url`），以及 [`Self::quick_check`]
    /// 在 `run_step` 之外对响应体做的验证码关键词全量扫描与重定向判定——
    /// 这些段会一口气执行完才回到 `select!`。因此「取消在 100ms 内生效」
    /// 是对**网络等待**成立的上界；响应体极大（数十 MB 级）时，CPU 解析
    /// 可能晚于 1s 才观察到取消。该延迟受单步 `step_timeout_ms` 与整源
    /// 总预算约束，不会无界。
    async fn run_step<T, F>(&self, step: F, deadline: Instant) -> StepOutcome<T>
    where
        F: std::future::Future<Output = Result<T, String>>,
    {
        // 取消优先于预算判定：已在取消态时立即返回
        if self.is_cancelled() {
            return StepOutcome::Cancelled;
        }
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return StepOutcome::TimedOut;
        };
        let budget = self.effective_step_timeout().min(remaining);

        tokio::select! {
            biased;
            _ = wait_for_cancel(self.cancel.clone()) => StepOutcome::Cancelled,
            outcome = tokio::time::timeout(budget, step) => match outcome {
                Ok(Ok(value)) => StepOutcome::Done(value),
                Ok(Err(message)) => StepOutcome::Failed(message),
                Err(_) => StepOutcome::TimedOut,
            },
        }
    }

    /// 完整检查（搜索 + 目录 + 内容 + 验证码检测 + 重定向检测）
    ///
    /// 1. 用默认关键词搜索
    /// 2. 取第一个结果的详情页 URL
    /// 3. 获取目录列表
    /// 4. 获取第一章内容
    /// 5. 验证码检测（每步响应体）
    /// 6. 重定向检测（对比请求/响应 URL）
    /// 7. 记录每步成功/失败
    pub async fn check_full(&self, source: &BookSource) -> CheckResult {
        let start = Instant::now();
        // 整源总上限 = 单步超时 × 启用步数（防多步叠加无界）
        let deadline = self.total_deadline(start, self.enabled_step_count());

        let mut result = CheckResult {
            source_url: source.book_source_url.clone(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 0,
            captcha: None,
            redirect: None,
            cancelled: false,
        };

        // 入口即取消：不发起任何请求（不计为书源失败）
        if self.is_cancelled() {
            mark_cancelled_step(
                &mut result.search_error,
                self.config.check_search,
                &mut result.search_ok,
                true,
            );
            mark_cancelled_step(
                &mut result.toc_error,
                self.config.check_toc,
                &mut result.toc_ok,
                true,
            );
            mark_cancelled_step(
                &mut result.content_error,
                self.config.check_content,
                &mut result.content_ok,
                true,
            );
            return result.finish_cancelled(start);
        }

        // Step 1: 搜索检查
        let search_result = if self.config.check_search {
            match self.run_step(self.do_search_check(source), deadline).await {
                StepOutcome::Done(first_book_url) => {
                    result.search_ok = true;
                    Some(first_book_url)
                }
                StepOutcome::Failed(e) => {
                    result.search_error = Some(e);
                    None
                }
                StepOutcome::TimedOut => {
                    result.search_error = Some(STEP_TIMEOUT_ERROR.to_string());
                    None
                }
                StepOutcome::Cancelled => {
                    mark_cancelled_step(
                        &mut result.toc_error,
                        self.config.check_toc,
                        &mut result.toc_ok,
                        false,
                    );
                    mark_cancelled_step(
                        &mut result.content_error,
                        self.config.check_content,
                        &mut result.content_ok,
                        false,
                    );
                    result.search_error = Some(STEP_CANCELLED_ERROR.to_string());
                    return result.finish_cancelled(start);
                }
            }
        } else {
            result.search_ok = true;
            None
        };

        // Step 2: 目录检查（需要搜索结果中的书籍 URL）
        let toc_result = if self.config.check_toc {
            if let Some(ref book_url) = search_result {
                match self
                    .run_step(self.do_toc_check(source, book_url), deadline)
                    .await
                {
                    StepOutcome::Done(first_chapter_url) => {
                        result.toc_ok = true;
                        Some(first_chapter_url)
                    }
                    StepOutcome::Failed(e) => {
                        result.toc_error = Some(e);
                        None
                    }
                    StepOutcome::TimedOut => {
                        result.toc_error = Some(STEP_TIMEOUT_ERROR.to_string());
                        None
                    }
                    StepOutcome::Cancelled => {
                        mark_cancelled_step(
                            &mut result.content_error,
                            self.config.check_content,
                            &mut result.content_ok,
                            false,
                        );
                        result.toc_error = Some(STEP_CANCELLED_ERROR.to_string());
                        return result.finish_cancelled(start);
                    }
                }
            } else if result.search_error.is_some() {
                result.toc_error = Some("skipped: search failed".to_string());
                None
            } else {
                result.toc_error = Some("skipped: no book url from search".to_string());
                None
            }
        } else {
            result.toc_ok = true;
            None
        };

        // Step 3: 内容检查（需要目录结果中的章节 URL）
        if self.config.check_content {
            if let Some(ref chapter_url) = toc_result {
                match self
                    .run_step(self.do_content_check(source, chapter_url), deadline)
                    .await
                {
                    StepOutcome::Done(()) => {
                        result.content_ok = true;
                    }
                    StepOutcome::Failed(e) => {
                        result.content_error = Some(e);
                    }
                    StepOutcome::TimedOut => {
                        result.content_error = Some(STEP_TIMEOUT_ERROR.to_string());
                    }
                    StepOutcome::Cancelled => {
                        result.content_error = Some(STEP_CANCELLED_ERROR.to_string());
                        return result.finish_cancelled(start);
                    }
                }
            } else if result.toc_error.is_some() {
                result.content_error = Some("skipped: toc failed".to_string());
            } else {
                result.content_error = Some("skipped: no chapter url from toc".to_string());
            }
        } else {
            result.content_ok = true;
        }

        result.finish_at(start)
    }

    /// 快速检查（仅搜索 + 验证码/重定向检测）
    ///
    /// 简化校验流程，快速判断书源是否可用。
    pub async fn check_search(&self, source: &BookSource) -> CheckResult {
        let start = Instant::now();
        let deadline = self.total_deadline(start, 1);

        let mut result = CheckResult {
            source_url: source.book_source_url.clone(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: None,
            toc_error: Some("skipped".to_string()),
            content_error: Some("skipped".to_string()),
            total_time_ms: 0,
            captcha: None,
            redirect: None,
            cancelled: false,
        };

        if self.is_cancelled() {
            result.search_error = Some(STEP_CANCELLED_ERROR.to_string());
            return result.finish_cancelled(start);
        }

        match self.run_step(self.do_search_check(source), deadline).await {
            StepOutcome::Done(_) => {
                result.search_ok = true;
            }
            StepOutcome::Failed(e) => {
                result.search_error = Some(e);
            }
            StepOutcome::TimedOut => {
                result.search_error = Some(STEP_TIMEOUT_ERROR.to_string());
            }
            StepOutcome::Cancelled => {
                result.search_error = Some(STEP_CANCELLED_ERROR.to_string());
                return result.finish_cancelled(start);
            }
        }

        result.finish_at(start)
    }

    /// 快速有效性检查（对齐 Kotlin `CheckSource` 简化流程）
    ///
    /// 仅发起搜索请求，检测验证码和重定向，快速判断书源是否可用。
    /// 不执行目录/内容检查，适用于批量快速筛查。
    pub async fn quick_check(&self, source: &BookSource) -> CheckResult {
        let start = Instant::now();
        let deadline = self.total_deadline(start, 1);

        let mut result = CheckResult {
            source_url: source.book_source_url.clone(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: None,
            toc_error: Some("skipped".to_string()),
            content_error: Some("skipped".to_string()),
            total_time_ms: 0,
            captcha: None,
            redirect: None,
            cancelled: false,
        };

        if self.is_cancelled() {
            result.search_error = Some(STEP_CANCELLED_ERROR.to_string());
            return result.finish_cancelled(start);
        }

        // 构建搜索 URL
        let Some(search_url) = source.search_url.as_ref() else {
            result.search_error = Some("no searchUrl defined".to_string());
            return result.finish_at(start);
        };

        let url = self.build_search_url(search_url, &self.effective_keyword(source));

        // 发起请求（受单步超时与取消约束）
        let request = async {
            self.client
                .get(&url, source_request_headers(source))
                .await
                .map_err(|e| format!("search request failed: {}", e))
        };
        let resp = match self.run_step(request, deadline).await {
            StepOutcome::Done(resp) => resp,
            StepOutcome::Failed(e) => {
                result.search_error = Some(e);
                return result.finish_at(start);
            }
            StepOutcome::TimedOut => {
                result.search_error = Some(STEP_TIMEOUT_ERROR.to_string());
                return result.finish_at(start);
            }
            StepOutcome::Cancelled => {
                result.search_error = Some(STEP_CANCELLED_ERROR.to_string());
                return result.finish_cancelled(start);
            }
        };

        // 重定向检测
        if self.config.detect_redirect {
            result.redirect = Some(self.detect_redirect(&resp, &url));
        }

        // 验证码检测
        if self.config.detect_captcha {
            result.captcha = Some(self.detect_captcha(&resp.body));
        }

        // 判断搜索是否成功
        if resp.is_success() && !resp.body.is_empty() {
            result.search_ok = true;
        } else if !resp.is_success() {
            result.search_error = Some(format!("search returned status {}", resp.status));
        } else {
            result.search_error = Some("search returned empty body".to_string());
        }

        result.finish_at(start)
    }

    // ---- 内部检查步骤 ----

    /// 搜索检查：构造搜索 URL 并请求
    async fn do_search_check(&self, source: &BookSource) -> Result<String, String> {
        let search_url = source
            .search_url
            .as_ref()
            .ok_or_else(|| "no searchUrl defined".to_string())?;

        // 替换搜索关键词占位符（优先书源 checkKeyWord，回落默认）
        let url = self.build_search_url(search_url, &self.effective_keyword(source));

        let resp = self
            .client
            .get(&url, source_request_headers(source))
            .await
            .map_err(|e| format!("search request failed: {}", e))?;

        if !resp.is_success() {
            return Err(format!("search returned status {}", resp.status));
        }

        if resp.body.is_empty() {
            return Err("search returned empty body".to_string());
        }

        // 尝试从响应体中提取第一个书籍链接
        let book_url = self.extract_first_book_url(&resp.body, source)?;
        Ok(book_url)
    }

    /// 目录检查：请求书籍详情页并提取目录
    async fn do_toc_check(&self, source: &BookSource, book_url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(book_url, source_request_headers(source))
            .await
            .map_err(|e| format!("toc request failed: {}", e))?;

        if !resp.is_success() {
            return Err(format!("toc page returned status {}", resp.status));
        }

        if resp.body.is_empty() {
            return Err("toc page returned empty body".to_string());
        }

        // 尝试从详情页提取第一个章节链接
        let chapter_url = self.extract_first_chapter_url(&resp.body, source)?;
        Ok(chapter_url)
    }

    /// 内容检查：请求章节内容
    async fn do_content_check(&self, source: &BookSource, chapter_url: &str) -> Result<(), String> {
        let resp = self
            .client
            .get(chapter_url, source_request_headers(source))
            .await
            .map_err(|e| format!("content request failed: {}", e))?;

        if !resp.is_success() {
            return Err(format!("content page returned status {}", resp.status));
        }

        if resp.body.is_empty() {
            return Err("content page returned empty body".to_string());
        }

        Ok(())
    }

    /// 书源校验关键字（对齐 Kotlin BookSource.getCheckKeyword）
    ///
    /// 优先用书源 `ruleSearch.checkKeyWord`（排除空白/URL/规则符），
    /// 否则回落配置默认关键字。
    fn effective_keyword(&self, source: &BookSource) -> String {
        if let Some(kw) = source
            .rule_search
            .as_ref()
            .and_then(|r| r.check_key_word.as_deref())
        {
            let kw = kw.trim();
            if !kw.is_empty()
                && !kw.contains("http")
                && !kw.contains("::")
                && !kw.contains("++")
                && !kw.contains("--")
            {
                return kw.to_string();
            }
        }
        self.config.keyword.clone()
    }

    /// 构造搜索 URL：替换 {key} 和 {searchKey} 占位符
    fn build_search_url(&self, template: &str, keyword: &str) -> String {
        let encoded = urlencoding::encode(keyword);
        template
            .replace("{{key}}", &encoded)
            .replace("{key}", &encoded)
            .replace("{searchKey}", &encoded)
    }

    /// 从搜索结果页提取第一个书籍链接
    fn extract_first_book_url(&self, body: &str, source: &BookSource) -> Result<String, String> {
        // 如果有 bookUrlPattern，用正则提取（书源可控 pattern，走统一安全入口）
        if let Some(ref pattern) = source.book_url_pattern {
            if let Some(re) = legado_core::regex_safe::compile_regex_safe(pattern) {
                if let Some(m) = re.find(body) {
                    return Ok(m.as_str().to_string());
                }
            }
            return Err("bookUrlPattern did not match any result".to_string());
        }

        // 回退：尝试提取第一个 href 链接
        extract_first_href(body).ok_or_else(|| "no book link found in search results".to_string())
    }

    /// 从详情页提取第一个章节链接
    fn extract_first_chapter_url(
        &self,
        body: &str,
        _source: &BookSource,
    ) -> Result<String, String> {
        // 简化实现：提取第一个 href 链接作为章节 URL
        extract_first_href(body).ok_or_else(|| "no chapter link found in detail page".to_string())
    }

    // ---- 验证码/重定向检测（对齐 SourceVerificationHelp） ----

    /// 验证码检测：检测 HTML 中是否包含常见验证码元素/关键词
    ///
    /// 参考 Kotlin `SourceVerificationHelp.getVerificationResult`，
    /// 检测图片验证码、滑动验证、点击字符等常见反爬机制。
    pub fn detect_captcha(&self, html: &str) -> CaptchaInfo {
        if html.is_empty() {
            return CaptchaInfo::none();
        }

        let lower = html.to_lowercase();

        // 图片验证码关键词
        const IMAGE_CAPTCHA_KEYWORDS: &[&str] = &[
            "captcha",
            "验证码",
            "verifycode",
            "verify_code",
            "checkcode",
            "check_code",
            "authcode",
            "vcode",
            "seccode",
            "imagecode",
        ];

        // 滑动验证关键词
        const SLIDE_CAPTCHA_KEYWORDS: &[&str] = &[
            "滑动验证",
            "slide",
            "slider",
            "geetest",
            "极验",
            "drag",
            "swipe",
            "拼图验证",
        ];

        // 点击验证关键词
        const CLICK_CAPTCHA_KEYWORDS: &[&str] = &[
            "点击验证",
            "clickcaptcha",
            "textcaptcha",
            "点选",
            "点击字符",
            "recaptcha",
            "hcaptcha",
            "turnstile",
        ];

        // 通用反爬/人机验证关键词
        const ANTI_BOT_KEYWORDS: &[&str] = &[
            "人机验证",
            "robot",
            "机器人",
            "are you a human",
            "human verification",
            "请完成验证",
            "安全验证",
            "access denied",
            "cloudflare",
            "cf-challenge",
        ];

        // 按优先级检测各类验证码
        for &kw in IMAGE_CAPTCHA_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("图片验证码".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        for &kw in SLIDE_CAPTCHA_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("滑动验证".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        for &kw in CLICK_CAPTCHA_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("点击验证".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        for &kw in ANTI_BOT_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("人机验证".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        CaptchaInfo::none()
    }

    /// 重定向检测：检查响应是否发生了重定向
    ///
    /// 对比请求 URL 与响应最终 URL，判断是否被重定向（如 302 到登录页）。
    /// 参考 Kotlin `SourceVerificationHelp` 中对重定向到验证页面的处理。
    pub fn detect_redirect(&self, response: &LegadoResponse, original_url: &str) -> RedirectInfo {
        let final_url = &response.url;

        // URL 相同表示未重定向
        if final_url == original_url || final_url.is_empty() {
            return RedirectInfo::none(original_url);
        }

        // 提取域名对比（忽略路径差异，只关注跨域重定向）
        let original_host = extract_host(original_url);
        let final_host = extract_host(final_url);

        // 判断是否重定向到登录/验证页面
        let is_login_redirect = is_login_or_verify_url(final_url);

        RedirectInfo {
            redirected: true,
            original_url: original_url.to_string(),
            final_url: final_url.clone(),
            // 跨域重定向或重定向到登录页视为异常
            is_login_redirect: is_login_redirect || original_host != final_host,
        }
    }
}

/// 从 HTML 中提取第一个 href 链接
fn extract_first_href(html: &str) -> Option<String> {
    let re = regex::Regex::new(r#"href=["']([^"']+)["']"#).ok()?;
    re.captures(html).map(|c| c[1].to_string())
}

/// 解析书源 header 字段为 HashMap
fn parse_headers(header: Option<&str>) -> Option<std::collections::HashMap<String, String>> {
    let header_str = header?;
    if header_str.is_empty() {
        return None;
    }
    // 尝试 JSON 解析
    if let Ok(map) = serde_json::from_str::<std::collections::HashMap<String, String>>(header_str) {
        return Some(map);
    }
    // 回退：按行解析 "Key: Value" 格式
    let mut map = std::collections::HashMap::new();
    for line in header_str.lines() {
        if let Some((k, v)) = line.split_once(':') {
            map.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

/// 书源请求头 + 写侧 CookieJar 门控标记（批 2）
///
/// `enabled_cookie_jar == Some(true)` 时在 [`parse_headers`] 结果上补
/// [`crate::client::COOKIE_JAR_HEADER`]（只补不覆盖；`Some(false)`/`None`
/// 不补，对齐上游 `source?.enabledCookieJar == true`）。该头由写侧
/// （[`crate::client::LegadoClient`]）消费并在发送前剥离（绝不出网）；
/// 读侧按域 cookie 注入无条件，不受影响。
fn source_request_headers(
    source: &BookSource,
) -> Option<std::collections::HashMap<String, String>> {
    let mut headers = parse_headers(source.header.as_deref()).unwrap_or_default();
    if source.enabled_cookie_jar == Some(true)
        && !headers
            .keys()
            .any(|k| k.eq_ignore_ascii_case(crate::client::COOKIE_JAR_HEADER))
    {
        headers.insert(
            crate::client::COOKIE_JAR_HEADER.to_string(),
            "1".to_string(),
        );
    }
    if headers.is_empty() {
        None
    } else {
        Some(headers)
    }
}

/// 从 URL 提取主机名（用于重定向检测对比）
fn extract_host(url: &str) -> String {
    // 尝试使用 url crate 解析
    if let Ok(parsed) = url::Url::parse(url) {
        if let Some(host) = parsed.host_str() {
            return host.to_lowercase();
        }
    }
    // 回退：简单字符串截取
    let without_scheme = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    without_scheme
        .split('/')
        .next()
        .unwrap_or("")
        .split(':')
        .next()
        .unwrap_or("")
        .to_lowercase()
}

/// 判断 URL 是否为登录/验证页面
fn is_login_or_verify_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    const LOGIN_KEYWORDS: &[&str] = &[
        "login",
        "signin",
        "sign-in",
        "auth",
        "verify",
        "verification",
        "captcha",
        "challenge",
        "登录",
        "验证",
    ];
    LOGIN_KEYWORDS.iter().any(|&kw| lower.contains(kw))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::{LegadoClient, LegadoClientConfig};

    fn make_checker() -> SourceChecker {
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        SourceChecker::new(Arc::new(client))
    }

    fn make_test_source() -> BookSource {
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "Test Source".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            book_url_pattern: Some(r#"https://example\.com/book/\d+"#.to_string()),
            ..BookSource::default()
        }
    }
    #[test]
    fn test_check_result_all_failed() {
        let result = CheckResult::all_failed("https://example.com", "test error");
        assert!(!result.search_ok);
        assert!(!result.toc_ok);
        assert!(!result.content_ok);
        assert!(!result.all_ok());
        assert_eq!(result.search_error, Some("test error".to_string()));
    }

    #[test]
    fn test_check_result_all_ok() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: None,
            redirect: None,
            cancelled: false,
        };
        assert!(result.all_ok());
        assert!(result.is_search_ok());
        assert!(!result.has_captcha());
        assert!(!result.has_redirect());
        assert!(result.is_available());
    }

    #[test]
    fn test_build_search_url() {
        let checker = make_checker();
        let source = make_test_source();
        let url =
            checker.build_search_url(source.search_url.as_ref().unwrap(), &checker.config.keyword);
        assert!(url.contains("search?q="));
        assert!(url.contains(urlencoding::encode(DEFAULT_KEYWORD).as_ref()));
    }

    #[test]
    fn test_build_search_url_double_brace() {
        let checker = make_checker();
        let url = checker.build_search_url("https://example.com/search?q={{key}}", "hello");
        assert!(url.contains("search?q=hello"));
    }

    #[test]
    fn test_build_search_url_search_key() {
        let checker = make_checker();
        let url = checker.build_search_url("https://example.com/search?q={searchKey}", "world");
        assert!(url.contains("search?q=world"));
    }

    #[test]
    fn test_extract_first_href() {
        let html = r#"<div><a href="https://example.com/book/123">Book</a></div>"#;
        let url = extract_first_href(html);
        assert_eq!(url, Some("https://example.com/book/123".to_string()));
    }

    #[test]
    fn test_extract_first_href_single_quotes() {
        let html = r#"<a href='https://example.com/book/456'>Link</a>"#;
        let url = extract_first_href(html);
        assert_eq!(url, Some("https://example.com/book/456".to_string()));
    }

    #[test]
    fn test_extract_first_href_none() {
        let html = "<div>no links here</div>";
        let url = extract_first_href(html);
        assert!(url.is_none());
    }

    #[test]
    fn test_parse_headers_json() {
        let json = r#"{"User-Agent": "TestBot/1.0", "Accept": "text/html"}"#;
        let headers = parse_headers(Some(json));
        assert!(headers.is_some());
        let map = headers.unwrap();
        assert_eq!(map.get("User-Agent").unwrap(), "TestBot/1.0");
    }

    #[test]
    fn test_parse_headers_line_format() {
        let text = "User-Agent: TestBot/1.0\nAccept: text/html";
        let headers = parse_headers(Some(text));
        assert!(headers.is_some());
        let map = headers.unwrap();
        assert_eq!(map.get("User-Agent").unwrap(), "TestBot/1.0");
    }

    #[test]
    fn test_parse_headers_none() {
        assert!(parse_headers(None).is_none());
        assert!(parse_headers(Some("")).is_none());
    }

    /// 批 2 写侧门控：书源校验请求头按 `enabledCookieJar` 补标记
    ///（开 → 补；false/None → 不补；规则已有同名键 → 只补不覆盖）
    #[test]
    fn test_source_request_headers_cookie_jar_gate() {
        // 开：Some(true) 且无其他 header → 仅标记头
        let source = BookSource {
            book_source_url: "https://gate-on.test".to_string(),
            enabled_cookie_jar: Some(true),
            ..BookSource::default()
        };
        let headers = source_request_headers(&source).expect("开启源应产出标记头");
        assert_eq!(
            headers
                .get(crate::client::COOKIE_JAR_HEADER)
                .map(String::as_str),
            Some("1")
        );

        // 关：Some(false) / None → 无标记（无其他 header → None）
        for gate in [Some(false), None] {
            let source = BookSource {
                book_source_url: "https://gate-off.test".to_string(),
                enabled_cookie_jar: gate,
                ..BookSource::default()
            };
            assert!(
                source_request_headers(&source).is_none(),
                "关闭/NULL 源不得补标记"
            );
        }

        // 规则已有同名键 → 只补不覆盖（值保持原样）
        let source = BookSource {
            book_source_url: "https://gate-rule.test".to_string(),
            enabled_cookie_jar: Some(true),
            header: Some(r#"{"CookieJar":"rule-val"}"#.to_string()),
            ..BookSource::default()
        };
        let headers = source_request_headers(&source).expect("应保留规则头");
        assert_eq!(
            headers
                .get(crate::client::COOKIE_JAR_HEADER)
                .map(String::as_str),
            Some("rule-val"),
            "规则 header 优先：标记头只补不覆盖"
        );
    }

    #[tokio::test]
    async fn test_check_search_no_search_url() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "No Search".to_string(),
            search_url: None,
            ..BookSource::default()
        };
        let result = checker.check_search(&source).await;
        assert!(!result.search_ok);
        assert!(result.search_error.unwrap().contains("no searchUrl"));
    }

    #[tokio::test]
    async fn test_check_full_no_search_url() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            search_url: None,
            ..BookSource::default()
        };
        let result = checker.check_full(&source).await;
        assert!(!result.search_ok);
        assert!(!result.toc_ok);
        assert!(!result.content_ok);
        assert!(result.total_time_ms >= 0);
    }

    #[test]
    fn test_checker_config_default() {
        let cfg = CheckerConfig::default();
        assert_eq!(cfg.keyword, DEFAULT_KEYWORD);
        assert_eq!(cfg.step_timeout_ms, 180_000);
        assert!(cfg.check_search);
        assert!(cfg.check_toc);
        assert!(cfg.check_content);
        assert!(cfg.detect_captcha);
        assert!(cfg.detect_redirect);
    }

    #[test]
    fn test_checker_with_config() {
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        let config = CheckerConfig {
            keyword: "自定义".to_string(),
            check_toc: false,
            check_content: false,
            ..CheckerConfig::default()
        };
        let checker = SourceChecker::with_config(Arc::new(client), config);
        assert_eq!(checker.config.keyword, "自定义");
        assert!(!checker.config.check_toc);
    }

    #[test]
    fn test_effective_keyword_uses_source_override() {
        use legado_core::models::rule::SearchRule;
        let checker = make_checker();

        // 无 checkKeyWord → 回落默认
        let default_src = make_test_source();
        assert_eq!(
            checker.effective_keyword(&default_src),
            checker.config.keyword
        );

        // 有效 checkKeyWord → 覆盖默认
        let mut src = make_test_source();
        src.rule_search = Some(SearchRule {
            check_key_word: Some("斗破苍穹".to_string()),
            ..SearchRule::default()
        });
        assert_eq!(checker.effective_keyword(&src), "斗破苍穹");

        // 含 http / 规则符 → 视为无效，回落默认
        for bad in ["http://x", "a::b", "a++b", "a--b", ""] {
            let mut s = make_test_source();
            s.rule_search = Some(SearchRule {
                check_key_word: Some(bad.to_string()),
                ..SearchRule::default()
            });
            assert_eq!(checker.effective_keyword(&s), checker.config.keyword);
        }
    }

    #[test]
    fn test_extract_first_book_url_with_pattern() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_url_pattern: Some(r#"https://example\.com/book/\d+"#.to_string()),
            ..BookSource::default()
        };
        let body = "Visit https://example.com/book/12345 for details";
        let result = checker.extract_first_book_url(body, &source);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "https://example.com/book/12345");
    }

    #[test]
    fn test_extract_first_book_url_no_match() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_url_pattern: Some(r#"https://other\.com/\d+"#.to_string()),
            ..BookSource::default()
        };
        let body = "no matching url here";
        let result = checker.extract_first_book_url(body, &source);
        assert!(result.is_err());
    }

    // ---- 验证码检测测试 ----

    #[test]
    fn test_detect_captcha_image() {
        let checker = make_checker();
        let html = r#"<div><img src="/captcha.jpg"><input name="verifycode"></div>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("图片验证码".to_string()));
        assert!(info.matched_keyword.is_some());
    }

    #[test]
    fn test_detect_captcha_slide() {
        let checker = make_checker();
        let html = r#"<div class="geetest-slider">请拖动滑块完成验证</div>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("滑动验证".to_string()));
    }

    #[test]
    fn test_detect_captcha_click() {
        let checker = make_checker();
        let html = r#"<div>请依次点击字符: 春 风</div>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("点击验证".to_string()));
    }

    #[test]
    fn test_detect_captcha_anti_bot() {
        let checker = make_checker();
        let html = r#"<html><body>Access Denied - Cloudflare Challenge</body></html>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("人机验证".to_string()));
    }

    #[test]
    fn test_detect_captcha_none() {
        let checker = make_checker();
        let html = r#"<html><body><h1>正常小说内容</h1><p>第一章</p></body></html>"#;
        let info = checker.detect_captcha(html);
        assert!(!info.detected);
        assert!(info.captcha_type.is_none());
    }

    #[test]
    fn test_detect_captcha_empty() {
        let checker = make_checker();
        let info = checker.detect_captcha("");
        assert!(!info.detected);
    }

    // ---- 重定向检测测试 ----

    #[test]
    fn test_detect_redirect_no_redirect() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://example.com/search?q=test".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search?q=test");
        assert!(!info.redirected);
        assert!(!info.is_login_redirect);
    }

    #[test]
    fn test_detect_redirect_same_domain() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://example.com/result".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search");
        assert!(info.redirected);
        assert!(!info.is_login_redirect); // 同域重定向不视为异常
    }

    #[test]
    fn test_detect_redirect_cross_domain() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://other-site.com/page".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search");
        assert!(info.redirected);
        assert!(info.is_login_redirect); // 跨域重定向视为异常
    }

    #[test]
    fn test_detect_redirect_to_login() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://example.com/login?redirect=/search".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search");
        assert!(info.redirected);
        assert!(info.is_login_redirect); // 重定向到登录页
    }

    // ---- 辅助函数测试 ----

    #[test]
    fn test_extract_host() {
        assert_eq!(extract_host("https://example.com/path"), "example.com");
        assert_eq!(
            extract_host("http://sub.example.com:8080/"),
            "sub.example.com"
        );
        assert_eq!(extract_host("https://EXAMPLE.COM"), "example.com");
    }

    #[test]
    fn test_is_login_or_verify_url() {
        assert!(is_login_or_verify_url("https://example.com/login"));
        assert!(is_login_or_verify_url("https://example.com/auth/callback"));
        assert!(is_login_or_verify_url("https://example.com/verify"));
        assert!(is_login_or_verify_url("https://example.com/captcha"));
        assert!(!is_login_or_verify_url("https://example.com/book/123"));
        assert!(!is_login_or_verify_url("https://example.com/search?q=test"));
    }

    // ---- CheckResult 新方法测试 ----

    #[test]
    fn test_check_result_with_captcha() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: Some(CaptchaInfo {
                detected: true,
                captcha_type: Some("图片验证码".to_string()),
                matched_keyword: Some("captcha".to_string()),
            }),
            redirect: None,
            cancelled: false,
        };
        assert!(result.has_captcha());
        assert!(!result.is_available()); // 有验证码时不可用
    }

    /// P3-1：已取消的结果即使搜索成功也不得判为「可用」
    ///
    /// 修复前 `is_available()` 只看 `search_ok && !has_captcha()`，
    /// 与 `all_ok()`（含 `!cancelled`）口径冲突：搜索成功后被取消的
    /// 结果会被上层当成可用书源。
    #[test]
    fn test_cancelled_result_is_not_available() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: None,
            redirect: None,
            cancelled: true,
        };
        assert!(result.is_search_ok());
        assert!(!result.is_available(), "已取消的结果不得判为可用");
        assert!(!result.all_ok());
    }

    #[test]
    fn test_check_result_with_redirect() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: None,
            redirect: Some(RedirectInfo {
                redirected: true,
                original_url: "https://example.com".to_string(),
                final_url: "https://login.example.com".to_string(),
                is_login_redirect: true,
            }),
            cancelled: false,
        };
        assert!(result.has_redirect());
    }

    // ---- P1-5：单步超时 / 整体预算 / 取消可中断 ----

    use std::time::Duration;

    /// 测试用最小 HTTP 服务器：按（端口, 路径）返回（延迟, 响应体）。
    ///
    /// 延迟在回包前生效，用于模拟「慢站点」；`Duration::from_secs(60)`
    /// 即等价于请求卡死。后台任务随测试运行时析构自动中止。
    async fn spawn_http_server<F>(respond: F) -> u16
    where
        F: Fn(u16, &str) -> (Duration, String) + Send + Sync + 'static,
    {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定测试端口");
        let port = listener.local_addr().unwrap().port();
        let respond = Arc::new(respond);
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    break;
                };
                let respond = Arc::clone(&respond);
                tokio::spawn(async move {
                    // 读到请求头结束即可判定路径
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        match sock.read(&mut byte).await {
                            Ok(0) | Err(_) => return,
                            Ok(_) => head.push(byte[0]),
                        }
                        if head.len() > 16 * 1024 {
                            return;
                        }
                    }
                    let head = String::from_utf8_lossy(&head).to_string();
                    let path = head.split_whitespace().nth(1).unwrap_or("/").to_string();
                    let (delay, body) = respond(port, &path);
                    if !delay.is_zero() {
                        tokio::time::sleep(delay).await;
                    }
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = sock.write_all(response.as_bytes()).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        port
    }

    /// 构造走本地回环、禁用系统代理的检查器（附取消令牌）
    fn make_checker_with(
        read_timeout: Duration,
        config: CheckerConfig,
    ) -> (SourceChecker, CancelToken) {
        let client = Arc::new(
            LegadoClient::new(LegadoClientConfig {
                read_timeout,
                no_proxy: true,
                ..LegadoClientConfig::default()
            })
            .unwrap(),
        );
        let token = CancelToken::new();
        (
            SourceChecker::with_config(client, config).with_cancel_token(token.clone()),
            token,
        )
    }

    fn source_with_search_url(url: String) -> BookSource {
        BookSource {
            book_source_url: "http://127.0.0.1".to_string(),
            book_source_name: "Timeout Test".to_string(),
            search_url: Some(url),
            ..BookSource::default()
        }
    }

    /// 单步 300ms + 站端 2s 慢响应：该步必须在 ~300ms 记为 timeout，
    /// 而不是等到 2s 后成功（修复前：2s 且 search_ok=true）。
    #[tokio::test]
    async fn test_step_timeout_applies_to_slow_search() {
        let port = spawn_http_server(|_port, _path| {
            (
                Duration::from_secs(2),
                "<html><body>slow</body></html>".to_string(),
            )
        })
        .await;

        let (checker, _token) = make_checker_with(
            Duration::from_secs(10),
            CheckerConfig {
                step_timeout_ms: 300,
                ..CheckerConfig::default()
            },
        );
        let source = source_with_search_url(format!("http://127.0.0.1:{port}/search?q={{key}}"));

        let started = Instant::now();
        let result = checker.check_search(&source).await;
        let elapsed = started.elapsed();

        assert!(
            elapsed < Duration::from_secs(1),
            "单步超时 300ms 应在 1s 内返回，实际 {elapsed:?}"
        );
        assert!(!result.search_ok, "超时不得记为成功");
        assert_eq!(
            result.search_error.as_deref(),
            Some("timeout"),
            "超时应以 timeout 标记，而非网络错误或成功"
        );
        assert!(!result.cancelled);
    }

    /// `quick_check` 与 `check_search` 共用同一条超时链路
    #[tokio::test]
    async fn test_quick_check_step_timeout() {
        let port = spawn_http_server(|_port, _path| {
            (
                Duration::from_secs(2),
                "<html><body>slow</body></html>".to_string(),
            )
        })
        .await;

        let (checker, _token) = make_checker_with(
            Duration::from_secs(10),
            CheckerConfig {
                step_timeout_ms: 300,
                ..CheckerConfig::default()
            },
        );
        let source = source_with_search_url(format!("http://127.0.0.1:{port}/search?q={{key}}"));

        let started = Instant::now();
        let result = checker.quick_check(&source).await;
        let elapsed = started.elapsed();

        assert!(
            elapsed < Duration::from_secs(1),
            "quick_check 单步超时应在 1s 内返回，实际 {elapsed:?}"
        );
        assert!(!result.search_ok);
        assert_eq!(result.search_error.as_deref(), Some("timeout"));
    }

    /// 搜索成功、目录超时：超时只记该步失败，后续步骤按既有依赖语义
    /// 标 skipped，不整源放弃；整源耗时受总预算（3 × 300ms）约束。
    #[tokio::test]
    async fn test_timeout_marks_step_failed_and_keeps_existing_skip_semantics() {
        let port = spawn_http_server(|port, path| {
            if path.starts_with("/search") {
                (
                    Duration::ZERO,
                    format!(r#"<a href="http://127.0.0.1:{port}/book/1">book</a>"#),
                )
            } else {
                (Duration::from_secs(2), "<html>toc</html>".to_string())
            }
        })
        .await;

        let (checker, _token) = make_checker_with(
            Duration::from_secs(10),
            CheckerConfig {
                step_timeout_ms: 300,
                ..CheckerConfig::default()
            },
        );
        let mut source =
            source_with_search_url(format!("http://127.0.0.1:{port}/search?q={{key}}"));
        source.book_url_pattern = Some(format!(r"http://127\.0\.0\.1:{port}/book/\d+"));

        let started = Instant::now();
        let result = checker.check_full(&source).await;
        let elapsed = started.elapsed();

        assert!(result.search_ok, "搜索应成功");
        assert!(!result.toc_ok, "目录慢响应应超时");
        assert_eq!(result.toc_error.as_deref(), Some("timeout"));
        assert_eq!(
            result.content_error.as_deref(),
            Some("skipped: toc failed"),
            "正文沿用既有依赖跳过语义"
        );
        assert!(
            elapsed < Duration::from_millis(1_500),
            "目录超时应在 ~300ms 生效，实际 {elapsed:?}"
        );
        assert!(
            result.total_time_ms <= 1_000,
            "整源总预算（3 × 300ms）应约束耗时上界，实际 {}ms",
            result.total_time_ms
        );
        assert!(!result.cancelled);
    }

    /// 卡死请求 + 200ms 后取消：必须在 1s 内返回，且标记为「已取消」
    /// 而非「书源失败」（修复前：等满客户端 read_timeout=3s 才返回）。
    #[tokio::test]
    async fn test_cancel_interrupts_hanging_request_within_one_second() {
        let port = spawn_http_server(|_port, _path| (Duration::from_secs(60), String::new())).await;
        let (checker, token) = make_checker_with(Duration::from_secs(3), CheckerConfig::default());
        let source = source_with_search_url(format!("http://127.0.0.1:{port}/search?q={{key}}"));

        let canceller = {
            let token = token.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(200)).await;
                token.cancel();
            })
        };

        let started = Instant::now();
        let result = checker.check_full(&source).await;
        let elapsed = started.elapsed();
        canceller.await.unwrap();

        assert!(
            elapsed < Duration::from_secs(1),
            "取消应在 1s 内返回，实际 {elapsed:?}"
        );
        assert!(result.cancelled, "取消必须标记 cancelled");
        assert!(!result.search_ok);
        assert_eq!(
            result.search_error.as_deref(),
            Some("cancelled"),
            "取消不得计为超时或网络失败"
        );
        assert_eq!(result.toc_error.as_deref(), Some("skipped: cancelled"));
        assert_eq!(result.content_error.as_deref(), Some("skipped: cancelled"));
    }

    /// 入口即已取消：不发起任何网络请求，直接返回取消态
    #[tokio::test]
    async fn test_cancel_before_start_skips_all_requests() {
        let port = spawn_http_server(|_port, _path| (Duration::from_secs(60), String::new())).await;
        let (checker, token) = make_checker_with(Duration::from_secs(3), CheckerConfig::default());
        token.cancel();
        let source = source_with_search_url(format!("http://127.0.0.1:{port}/search?q={{key}}"));

        let started = Instant::now();
        let result = checker.check_full(&source).await;
        let elapsed = started.elapsed();

        assert!(
            elapsed < Duration::from_millis(200),
            "已取消应在入口直接返回，实际 {elapsed:?}"
        );
        assert!(result.cancelled);
        assert_eq!(result.search_error.as_deref(), Some("cancelled"));
        assert_eq!(result.toc_error.as_deref(), Some("cancelled"));
        assert_eq!(result.content_error.as_deref(), Some("cancelled"));
    }
}
