//! 请求限流器
//!
//! 基于令牌桶（Token Bucket）的限流器，支持：
//! - 全局并发限制
//! - 按域名（host）隔离的并发限制

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use legado_core::{LegadoError, LegadoResult};
use reqwest::{RequestBuilder, Response};
use tokio::sync::Semaphore;

use crate::middleware::{Middleware, Next};

/// 基于信号量的并发限流器
///
/// 内部使用 `tokio::sync::Semaphore` 控制最大并发请求数。
#[derive(Debug)]
pub struct RateLimiter {
    permits: Arc<Semaphore>,
    max_concurrent: usize,
}

impl RateLimiter {
    /// 创建新的限流器，允许最多 `max_concurrent` 个并发请求
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(max_concurrent)),
            max_concurrent,
        }
    }

    /// 获取当前最大并发数
    pub fn max_concurrent(&self) -> usize {
        self.max_concurrent
    }

    /// 获取当前可用许可数
    pub fn available_permits(&self) -> usize {
        self.permits.available_permits()
    }

    /// 等待获取许可
    ///
    /// 如果当前并发已满，将阻塞直到有许可可用或超时。
    pub async fn acquire(&self) -> LegadoResult<SemaphorePermit<'_>> {
        self.permits
            .acquire()
            .await
            .map(SemaphorePermit)
            .map_err(|e| LegadoError::Network(format!("Rate limiter closed: {}", e)))
    }

    /// 尝试获取许可，不阻塞
    pub fn try_acquire(&self) -> Option<SemaphorePermit<'_>> {
        self.permits.try_acquire().ok().map(SemaphorePermit)
    }

    /// 带超时的许可获取（返回 OwnedSemaphorePermit，可跨任务使用）
    pub async fn acquire_timeout(&self, timeout: Duration) -> LegadoResult<OwnedSemaphorePermit> {
        tokio::time::timeout(timeout, self.permits.clone().acquire_owned())
            .await
            .map_err(|_| LegadoError::Timeout("Rate limit: acquire timeout".into()))?
            .map(OwnedSemaphorePermit)
            .map_err(|e| LegadoError::Network(format!("Rate limiter closed: {}", e)))
    }
}

/// 许可持有者，Drop 时自动释放
#[allow(dead_code)]
pub struct SemaphorePermit<'a>(tokio::sync::SemaphorePermit<'a>);

/// 按域名的限流管理器
///
/// 每个域名维护独立的 `RateLimiter`，新域名按需创建。
pub struct DomainRateLimiter {
    limiters: Arc<Mutex<HashMap<String, RateLimiter>>>,
    default_concurrent: usize,
}

impl DomainRateLimiter {
    /// 创建新的域名限流管理器
    ///
    /// - `default_concurrent`: 每个域名默认的最大并发数
    pub fn new(default_concurrent: usize) -> Self {
        Self {
            limiters: Arc::new(Mutex::new(HashMap::new())),
            default_concurrent,
        }
    }

    /// 获取或创建指定域名的限流器
    pub fn get_or_create(&self, domain: &str) -> Arc<DomainSlot> {
        let mut map = self.limiters.lock().unwrap();
        let limiter = map
            .entry(domain.to_string())
            .or_insert_with(|| RateLimiter::new(self.default_concurrent));
        Arc::new(DomainSlot {
            permits: Arc::clone(&limiter.permits),
        })
    }

    /// 获取当前已跟踪的域名数量
    pub fn domain_count(&self) -> usize {
        self.limiters.lock().unwrap().len()
    }

    /// 获取默认并发数
    pub fn default_concurrent(&self) -> usize {
        self.default_concurrent
    }

    /// 为特定域名设置自定义并发限制
    pub fn set_concurrent(&self, domain: &str, max_concurrent: usize) {
        let mut map = self.limiters.lock().unwrap();
        map.insert(domain.to_string(), RateLimiter::new(max_concurrent));
    }
}

/// 域名级别的许可槽位，用于异步获取许可
pub struct DomainSlot {
    permits: Arc<Semaphore>,
}

impl DomainSlot {
    /// 异步获取许可
    pub async fn acquire(&self) -> LegadoResult<OwnedSemaphorePermit> {
        self.permits
            .clone()
            .acquire_owned()
            .await
            .map(OwnedSemaphorePermit)
            .map_err(|e| LegadoError::Network(format!("Domain rate limiter closed: {}", e)))
    }
}

/// 所有权许可，Drop 时自动释放
#[allow(dead_code)]
pub struct OwnedSemaphorePermit(tokio::sync::OwnedSemaphorePermit);

/// 从 URL 中提取域名
pub fn extract_domain(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_string()))
        .unwrap_or_else(|| "unknown".to_string())
}

/// 将 DomainRateLimiter 包装为中间件
pub struct DomainRateLimitMiddleware {
    limiter: Arc<DomainRateLimiter>,
}

impl DomainRateLimitMiddleware {
    pub fn new(limiter: Arc<DomainRateLimiter>) -> Self {
        Self { limiter }
    }
}

#[async_trait::async_trait]
impl Middleware for DomainRateLimitMiddleware {
    fn name(&self) -> &str {
        "DomainRateLimit"
    }

    async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
        // 尝试从请求中提取 URL（需要先 build 请求）
        // 由于 RequestBuilder 在 build() 后被消费，这里无法直接获取 URL
        // 因此使用全局域名 "global" 作为后备
        // 实际使用时应通过 LegadoClient 在发送前获取域名
        let domain = "global";
        let slot = self.limiter.get_or_create(domain);
        let _permit = slot.acquire().await?;
        next(request).await
    }
}

/// 固定窗口间隔限流器（对齐 Kotlin ConcurrentRateLimiter）
///
/// 解析书源 `concurrentRate` 字段：
/// - `"N/interval"`：每 `interval` 毫秒窗口内最多 `N` 次访问
/// - 纯 `"N"`：每 `N` 毫秒最多 1 次（accessLimit=1, interval=N）
/// - 空 / `"0"` / 非法 → 不限流（`parse` 返回 None）
#[derive(Debug)]
pub struct IntervalRateLimiter {
    state: Mutex<IntervalState>,
}

#[derive(Debug)]
struct IntervalState {
    window_start: Option<std::time::Instant>,
    frequency: u32,
    access_limit: u32,
    interval: Duration,
}

impl IntervalRateLimiter {
    /// 按 concurrentRate 字符串解析；空/"0"/非法返回 None
    pub fn parse(concurrent_rate: &str) -> Option<Self> {
        let rate = concurrent_rate.trim();
        if rate.is_empty() || rate == "0" {
            return None;
        }
        if let Some(idx) = rate.find('/') {
            let access_limit: u32 = rate[..idx].trim().parse().ok()?;
            let interval_ms: u64 = rate[idx + 1..].trim().parse().ok()?;
            if access_limit == 0 || interval_ms == 0 {
                return None;
            }
            Some(Self::new(access_limit, interval_ms))
        } else {
            let interval_ms: u64 = rate.parse().ok()?;
            if interval_ms == 0 {
                return None;
            }
            Some(Self::new(1, interval_ms))
        }
    }

    /// 直接以 access_limit / interval 毫秒构造
    pub fn new(access_limit: u32, interval_ms: u64) -> Self {
        Self {
            state: Mutex::new(IntervalState {
                window_start: None,
                frequency: 0,
                access_limit,
                interval: Duration::from_millis(interval_ms),
            }),
        }
    }

    /// 计算本次访问需等待的毫秒（0=放行），并推进固定窗口状态
    fn next_wait_ms(&self) -> u64 {
        let mut s = self.state.lock().unwrap();
        let now = std::time::Instant::now();
        match s.window_start {
            None => {
                s.window_start = Some(now);
                s.frequency = 1;
                0
            }
            Some(start) => {
                if now >= start + s.interval {
                    // 窗口已结束 → 重置
                    s.window_start = Some(now);
                    s.frequency = 1;
                    0
                } else if s.frequency < s.access_limit {
                    s.frequency += 1;
                    0
                } else {
                    // 超限 → 等待到窗口结束
                    (start + s.interval)
                        .saturating_duration_since(now)
                        .as_millis() as u64
                }
            }
        }
    }

    /// 异步获取访问许可（超限时 sleep 直到放行）
    pub async fn acquire(&self) {
        loop {
            let wait_ms = self.next_wait_ms();
            if wait_ms == 0 {
                return;
            }
            tokio::time::sleep(Duration::from_millis(wait_ms)).await;
        }
    }

    /// 同步获取访问许可（阻塞线程直到放行）
    pub fn acquire_blocking(&self) {
        loop {
            let wait_ms = self.next_wait_ms();
            if wait_ms == 0 {
                return;
            }
            std::thread::sleep(Duration::from_millis(wait_ms));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rate_limiter_creation() {
        let limiter = RateLimiter::new(5);
        assert_eq!(limiter.max_concurrent(), 5);
        assert_eq!(limiter.available_permits(), 5);
    }

    #[test]
    fn test_interval_limiter_parse() {
        assert!(IntervalRateLimiter::parse("").is_none());
        assert!(IntervalRateLimiter::parse("0").is_none());
        assert!(IntervalRateLimiter::parse("abc").is_none());
        assert!(IntervalRateLimiter::parse("0/1000").is_none());
        let l = IntervalRateLimiter::parse("5/1000").unwrap();
        {
            let s = l.state.lock().unwrap();
            assert_eq!(s.access_limit, 5);
            assert_eq!(s.interval, Duration::from_millis(1000));
        }
        let l = IntervalRateLimiter::parse("500").unwrap();
        {
            let s = l.state.lock().unwrap();
            assert_eq!(s.access_limit, 1);
            assert_eq!(s.interval, Duration::from_millis(500));
        }
    }

    #[test]
    fn test_interval_limiter_window_throttles() {
        let l = IntervalRateLimiter::new(3, 10_000);
        assert_eq!(l.next_wait_ms(), 0); // 第 1 次放行
        assert_eq!(l.next_wait_ms(), 0); // 第 2 次放行
        assert_eq!(l.next_wait_ms(), 0); // 第 3 次放行
        assert!(l.next_wait_ms() > 0); // 第 4 次超限需等待
    }

    #[tokio::test]
    async fn test_rate_limiter_acquire_release() {
        let limiter = RateLimiter::new(2);
        assert_eq!(limiter.available_permits(), 2);

        let p1 = limiter.acquire().await.unwrap();
        assert_eq!(limiter.available_permits(), 1);

        let p2 = limiter.acquire().await.unwrap();
        assert_eq!(limiter.available_permits(), 0);

        drop(p1);
        assert_eq!(limiter.available_permits(), 1);

        drop(p2);
        assert_eq!(limiter.available_permits(), 2);
    }

    #[test]
    fn test_rate_limiter_try_acquire() {
        let limiter = RateLimiter::new(1);
        let p1 = limiter.try_acquire();
        assert!(p1.is_some());

        let p2 = limiter.try_acquire();
        assert!(p2.is_none());

        drop(p1);
        let p3 = limiter.try_acquire();
        assert!(p3.is_some());
    }

    #[tokio::test]
    async fn test_rate_limiter_acquire_timeout() {
        let limiter = Arc::new(RateLimiter::new(1));

        // 占满许可
        let _p1 = limiter.acquire().await.unwrap();

        // 超时获取
        let l2 = Arc::clone(&limiter);
        let result =
            tokio::spawn(async move { l2.acquire_timeout(Duration::from_millis(50)).await })
                .await
                .unwrap();

        assert!(result.is_err());
    }

    #[test]
    fn test_domain_rate_limiter_creation() {
        let drl = DomainRateLimiter::new(10);
        assert_eq!(drl.default_concurrent(), 10);
        assert_eq!(drl.domain_count(), 0);
    }

    #[test]
    fn test_domain_rate_limiter_get_or_create() {
        let drl = DomainRateLimiter::new(5);
        assert_eq!(drl.domain_count(), 0);

        let _slot1 = drl.get_or_create("example.com");
        assert_eq!(drl.domain_count(), 1);

        let _slot2 = drl.get_or_create("example.com");
        assert_eq!(drl.domain_count(), 1); // 同一域名不重复创建

        let _slot3 = drl.get_or_create("other.com");
        assert_eq!(drl.domain_count(), 2);
    }

    #[test]
    fn test_domain_rate_limiter_set_concurrent() {
        let drl = DomainRateLimiter::new(5);
        drl.set_concurrent("api.example.com", 20);
        assert_eq!(drl.domain_count(), 1);
    }

    #[tokio::test]
    async fn test_domain_slot_acquire() {
        let drl = Arc::new(DomainRateLimiter::new(2));
        let slot = drl.get_or_create("test.com");

        let p1 = slot.acquire().await;
        assert!(p1.is_ok());

        let p2 = slot.acquire().await;
        assert!(p2.is_ok());

        // 此时许可已满，try 应失败（通过另一个 slot 引用）
        let slot2 = drl.get_or_create("test.com");
        let p3 = slot2.try_acquire_inner();
        assert!(p3.is_none());
    }

    #[test]
    fn test_extract_domain() {
        assert_eq!(extract_domain("https://example.com/path"), "example.com");
        assert_eq!(
            extract_domain("http://api.test.org:8080/v1"),
            "api.test.org"
        );
        assert_eq!(extract_domain("not-a-url"), "unknown");
    }

    #[tokio::test]
    async fn test_domain_isolation() {
        let drl = Arc::new(DomainRateLimiter::new(1));

        // 域名 A 占满许可
        let slot_a = drl.get_or_create("a.com");
        let _pa = slot_a.acquire().await.unwrap();

        // 域名 B 应独立获取许可
        let slot_b = drl.get_or_create("b.com");
        let pb = slot_b.acquire().await;
        assert!(pb.is_ok(), "Different domains should have isolated limits");
    }

    // Helper for test_domain_slot_acquire
    impl DomainSlot {
        fn try_acquire_inner(&self) -> Option<tokio::sync::OwnedSemaphorePermit> {
            self.permits.clone().try_acquire_owned().ok()
        }
    }
}
