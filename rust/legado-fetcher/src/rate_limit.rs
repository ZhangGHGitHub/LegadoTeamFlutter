//! 书源 concurrentRate 固定窗口限流（G4，对齐 Kotlin ConcurrentRateLimiter）
//!
//! 原 `legado-ffi/src/api/source_rate_limit.rs` 的全局 `OnceLock` 限速表
//! 下沉为可注入的 [`RateLimiterRegistry`]：每源限流器按 `book_source_url`
//! 缓存，跨请求保持窗口状态。宿主（ffi）以进程级 OnceLock 持有单一注册表
//! 实例，语义与下沉前一致。
//!
//! 配置单写者（对齐上游 `ConcurrentRateLimiter` 的职责切分）：
//! - [`RateLimiterRegistry::refresh`]（宿主书源保存路径统一入口，对应上游
//!   `updateConcurrentRate` 的保存侧语义）：空 / `"0"`（忽略首尾空白）→
//!   [`RateLimiterRegistry::remove`]（对齐原版「空即不限流」，清掉既有
//!   limiter）；其余值转 [`RateLimiterRegistry::update`]。
//! - [`RateLimiterRegistry::update`] 是合法 rate 的配置写入者：已有 limiter
//!   时原地替换 `accessLimit / interval` 并保留当前窗口的 time / frequency；
//!   非法不改动；无既有记录不预创建。
//! - [`RateLimiterRegistry::remove`] 是清除原语：map 锁内移除条目；已取走
//!   `Arc` 的在途请求落在被移除实例上自然跑完，后续 acquire 按当前快照
//!   重新惰性创建。
//! - [`RateLimiterRegistry::acquire`] 只读既有配置，仅在 key 缺失时按当前
//!   快照惰性创建 limiter（对应上游 fetchStart 的 computeIfAbsent）。
//!
//! 为何 acquire 不得回写配置（竞态证据见测试
//! `stale_snapshot_acquire_does_not_revert_updated_config`）：acquire 收到的
//! `BookSource` 是调用时刻快照（一次请求/一次 flow 内固定，宿主 Flutter 还
//! 会缓存书源对象），保存路径与请求执行并发时「保存 update(新率) → 旧快照
//! acquire(旧率)」的先后顺序可达；若 acquire 也写配置，迟到的旧快照就会把
//! 已保存的新率覆盖回旧值。且 `BookSource` 无可靠版本字段，任何按快照内容
//! 比较的方案都无法为旧/新快照定序，故最小且与上游同构的方案是配置单写者。
//!
//! 已知残余（任务约束「未注册 key 更新不创建项」所致）：key 从未注册、
//! 编辑保存（合法值经 refresh → update 空转、不预创建）之后，若首个 acquire
//! 来自编辑前的旧快照，仍会以旧率创建 limiter（上游以 update 预建 record
//! 关闭该窗口）。关闭需增加「未建 limiter 的待用配置」小条目，与上述约束
//! 冲突，留待裁决。
//!
//! 锁序约定：registry 的 `limiters` map 锁（M）与 limiter 内部 `state` 锁
//! （S）从不嵌套——acquire / update / remove / refresh 均只在 M 内取出/插入/
//! 移除 `Arc` 并释放 M，之后才调用 limiter 方法（`acquire` / `update_rate`）。
//! limiter 不感知 M，两者互为叶子，无锁环；禁止在持 M 时调用任何 limiter 方法。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use legado_core::models::BookSource;
use legado_net::rate_limit::IntervalRateLimiter;

/// 每源限流器注册表
#[derive(Default)]
pub struct RateLimiterRegistry {
    limiters: Mutex<HashMap<String, Arc<IntervalRateLimiter>>>,
}

impl RateLimiterRegistry {
    /// 空注册表
    pub fn new() -> Self {
        Self {
            limiters: Mutex::new(HashMap::new()),
        }
    }

    /// 按书源 `concurrentRate` 获取访问许可（空/"0"/非法 → 立即返回）
    ///
    /// 只读既有 limiter 配置；key 缺失时按当前快照惰性创建。配置刷新由
    /// [`Self::update`]（宿主保存路径）负责，acquire 不得回写——否则旧
    /// `BookSource` 快照的迟到请求会覆盖已保存的新 concurrentRate。
    pub async fn acquire(&self, source: &BookSource) {
        let rate = source.concurrent_rate.as_deref().unwrap_or("").trim();
        if rate.is_empty() || rate == "0" {
            return;
        }
        let Some((access_limit, interval_ms)) = IntervalRateLimiter::parse_rate(rate) else {
            return;
        };
        let limiter = self.limiter_for(&source.book_source_url, access_limit, interval_ms);
        // map 锁已在 limiter_for 内释放，此处只可能持有 limiter 自身 state 锁
        limiter.acquire().await;
    }

    /// 书源 `concurrentRate` 编辑后刷新既有 limiter 配置（合法 rate 的配置写入者）
    ///
    /// 对齐上游 `ConcurrentRateLimiter.updateConcurrentRate(key, concurrentRate)`：
    /// - 已有该 key 的 limiter：原地更新 `accessLimit / interval`，保留当前
    ///   窗口的 time/frequency（不重置已用次数）；
    /// - 非法输入：不改动既有记录；
    /// - 无既有记录：不预创建 limiter（延迟到首次 [`Self::acquire`]）。
    pub fn update(&self, source_url: &str, concurrent_rate: &str) {
        let Some((access_limit, interval_ms)) = IntervalRateLimiter::parse_rate(concurrent_rate)
        else {
            return;
        };
        // 仅在 map 锁内取 Arc，释放后才更新 limiter 状态（锁不嵌套）
        let existing = {
            let guard = self.limiters.lock().unwrap_or_else(|p| p.into_inner());
            guard.get(source_url).map(Arc::clone)
        };
        if let Some(limiter) = existing {
            limiter.update_rate(access_limit, interval_ms);
        }
    }

    /// 移除指定 key 的 limiter（书源保存路径清空 `concurrentRate` 时调用）
    ///
    /// 对齐原版「空即不限流」：清掉既有窗口记录，使后续访问立即放行。
    /// 在 map 锁内 `remove` 后不再触碰该 limiter；被移除前已经取走 `Arc`
    /// 的在途请求落在原实例上自然跑完（窗口状态独立于注册表），下一次
    /// [`Self::acquire`] 会按当前快照重新惰性创建。未注册 key 为 no-op。
    pub fn remove(&self, source_url: &str) {
        let mut guard = self.limiters.lock().unwrap_or_else(|p| p.into_inner());
        guard.remove(source_url);
    }

    /// 书源保存路径的统一配置刷新入口（合法值更新 / 空值清除）
    ///
    /// - 空 / `"0"`（忽略首尾空白）→ [`Self::remove`]：对齐原版「空=不限流」，
    ///   清掉既有 limiter，避免编辑保存清空后仍沿用旧限速；
    /// - 其余值 → [`Self::update`]：合法率原地刷新并保留窗口，非法率不改动
    ///   （解析规则见 [`IntervalRateLimiter::parse_rate`]）。
    pub fn refresh(&self, source_url: &str, concurrent_rate: &str) {
        let rate = concurrent_rate.trim();
        if rate.is_empty() || rate == "0" {
            self.remove(source_url);
        } else {
            self.update(source_url, rate);
        }
    }

    /// 取（或按快照惰性创建）key 对应 limiter；返回时 map 锁已释放
    fn limiter_for(
        &self,
        key: &str,
        access_limit: u32,
        interval_ms: u64,
    ) -> Arc<IntervalRateLimiter> {
        let mut guard = self.limiters.lock().unwrap_or_else(|p| p.into_inner());
        Arc::clone(
            guard
                .entry(key.to_string())
                .or_insert_with(|| Arc::new(IntervalRateLimiter::new(access_limit, interval_ms))),
        )
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    /// 构造指定 URL / concurrentRate 的书源
    fn source(url: &str, concurrent_rate: Option<&str>) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            concurrent_rate: concurrent_rate.map(str::to_string),
            ..Default::default()
        }
    }

    /// 注册表当前缓存的 limiter 数
    fn tracked(registry: &RateLimiterRegistry) -> usize {
        registry
            .limiters
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .len()
    }

    /// 模拟宿主保存路径（update）后，后续 acquire 按新 accessLimit 立即生效
    #[tokio::test]
    async fn update_takes_effect_on_next_acquire() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-edit.example", Some("1/10000"));
        registry.acquire(&src).await; // 第 1 次放行，窗口已用 1 次

        registry.update(&src.book_source_url, "2/10000");
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(
            passed.is_ok(),
            "update 后的 accessLimit 必须对后续 acquire 立即生效"
        );
        assert_eq!(tracked(&registry), 1, "刷新必须原地更新，不得新建条目");
    }

    /// 竞态判别（危险时序）：保存 update(新率) 之后，携带编辑前旧快照的
    /// 迟到 acquire 不得把配置覆盖回旧率
    ///
    /// 旧「acquire 回写配置」实现下：这次 acquire 会写入旧率 1/10000，
    /// 已用 1 次即超限 → 等待约 10s → 超时断言失败。
    #[tokio::test]
    async fn stale_snapshot_acquire_does_not_revert_updated_config() {
        let registry = RateLimiterRegistry::new();
        let stale = source("https://rate-stale.example", Some("1/10000"));
        registry.acquire(&stale).await; // 旧率下窗口已用 1 次

        // 保存路径已写入新率（宿主保存入口后续接线，此处直接驱动契约）
        registry.update(&stale.book_source_url, "2/10000");

        // 迟到请求仍携带编辑前快照（旧率）
        let passed =
            tokio::time::timeout(Duration::from_millis(500), registry.acquire(&stale)).await;
        assert!(
            passed.is_ok(),
            "旧快照 acquire 不得把 update 写入的新率覆盖回旧值"
        );

        // 新率（2 次/窗口）已被上面这次访问用满 → 下一次仍受同一窗口约束
        let blocked =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&stale)).await;
        assert!(blocked.is_err(), "配置应保持为新率且窗口计数正常累计");
    }

    /// update 调整 accessLimit 时保留窗口已用次数：降额继续挡、升额立即放行
    #[tokio::test]
    async fn update_preserves_used_frequency_and_window() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-keep.example", Some("3/10000"));
        for _ in 0..3 {
            registry.acquire(&src).await; // 窗口已用 3 次
        }
        tokio::time::sleep(Duration::from_millis(50)).await;

        // 降额到 2：保留 frequency=3 → 仍被当前窗口挡住（若重建/清零会立即放行）
        registry.update(&src.book_source_url, "2/10000");
        let blocked =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&src)).await;
        assert!(
            blocked.is_err(),
            "已用次数保留时，降额后应继续等待当前窗口结束"
        );

        // 升额到 4：保留 frequency=3（本次为第 4 次）→ 立即放行
        registry.update(&src.book_source_url, "4/10000");
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(
            passed.is_ok(),
            "提高 accessLimit 后，已用次数保留应允许下一次访问立即放行"
        );
    }

    /// update 更换 interval 不得重启固定窗口（沿用原窗口起点计算等待）
    #[tokio::test]
    async fn update_of_interval_does_not_restart_current_window() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-window.example", Some("1/100"));
        registry.acquire(&src).await; // 窗口起点 t0，已用 1 次（100ms 窗口）
        tokio::time::sleep(Duration::from_millis(50)).await;

        // 拉长到 10s：窗口起点仍为 t0 → 等待约 9.95s（重建/清零会立即放行；
        // 若 acquire 回写旧率则只等约 50ms）
        registry.update(&src.book_source_url, "1/10000");
        let blocked =
            tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(
            blocked.is_err(),
            "更换 interval 不得重启固定窗口，应沿用原窗口起点"
        );

        // 恢复 100ms：t0+100ms 已过 → 窗口自然重置放行，记录仍可用
        registry.update(&src.book_source_url, "1/100");
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(passed.is_ok(), "窗口到期后应正常放行");
    }

    /// update 同值写入不得重置窗口（若 remove+重建，下一次 acquire 会立即放行）
    #[tokio::test]
    async fn same_value_update_does_not_reset_window() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-same.example", Some("1/10000"));
        registry.acquire(&src).await; // 窗口已用 1 次

        registry.update(&src.book_source_url, "1/10000");
        let blocked =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&src)).await;
        assert!(
            blocked.is_err(),
            "同值 update 必须保留当前窗口的 time/frequency"
        );
        assert_eq!(tracked(&registry), 1, "update 不得产生重复条目");
    }

    /// 非法 concurrentRate 的 update 不得改动既有记录（仍受旧限制约束）
    #[tokio::test]
    async fn update_with_invalid_rate_keeps_existing_limits() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-invalid.example", Some("2/10000"));
        registry.acquire(&src).await;
        registry.acquire(&src).await; // 窗口已用 2 次

        for invalid in [
            "", "0", "abc", "0/1000", "2/0", "-3", "2/abc", "3/-1", "1/2/3",
        ] {
            registry.update(&src.book_source_url, invalid);
        }

        let blocked =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&src)).await;
        assert!(
            blocked.is_err(),
            "非法 concurrentRate 不得改变既有记录（应仍受旧限制约束）"
        );
    }

    /// 非法 concurrentRate 的 acquire 单次立即放行，但不得重置既有记录
    #[tokio::test]
    async fn acquire_with_invalid_rate_keeps_existing_record() {
        let registry = RateLimiterRegistry::new();
        let mut src = source("https://rate-invalid-acq.example", Some("2/10000"));
        registry.acquire(&src).await;
        registry.acquire(&src).await; // 窗口已用 2 次

        src.concurrent_rate = Some("not-a-rate".to_string());
        let unlimited =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&src)).await;
        assert!(unlimited.is_ok(), "非法 concurrentRate 单次调用应立即返回");

        src.concurrent_rate = Some("2/10000".to_string());
        let blocked =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&src)).await;
        assert!(blocked.is_err(), "非法中间态不得重置既有窗口记录");
    }

    /// 未注册 key 的 update 不预创建 limiter
    #[tokio::test]
    async fn update_without_existing_record_does_not_create() {
        let registry = RateLimiterRegistry::new();
        registry.update("https://rate-absent.example", "5/60000");
        registry.update("https://rate-absent.example", "bad");
        registry.update("https://rate-absent.example", "");
        assert_eq!(
            tracked(&registry),
            0,
            "未注册 key 的更新不得预创建 limiter（延迟到首次 acquire）"
        );
    }

    /// 键语义保持 `book_source_url`：同 URL 复用同一条目，不同 URL 相互独立，
    /// 不限流来源（None/"0"/非法）不入表
    #[tokio::test]
    async fn registry_keys_by_book_source_url() {
        let registry = RateLimiterRegistry::new();
        registry
            .acquire(&source("https://rate-none.example", None))
            .await;
        registry
            .acquire(&source("https://rate-zero.example", Some("0")))
            .await;
        registry
            .acquire(&source("https://rate-bad.example", Some("abc")))
            .await;
        assert_eq!(tracked(&registry), 0, "不限流来源不应注册 limiter");

        registry
            .acquire(&source("https://rate-1.example", Some("5/60000")))
            .await;
        registry
            .acquire(&source("https://rate-2.example", Some("5/60000")))
            .await;
        registry
            .acquire(&source("https://rate-1.example", Some("5/60000")))
            .await;
        assert_eq!(tracked(&registry), 2, "不同 URL 各自独立，同 URL 复用条目");
        let guard = registry.limiters.lock().unwrap_or_else(|p| p.into_inner());
        assert!(guard.contains_key("https://rate-1.example"));
        assert!(guard.contains_key("https://rate-2.example"));
    }

    /// 真并发不变量：多路旧快照 acquire 与反复 update(新率) 在 4 线程运行时
    /// 并行执行，结束后配置必须仍为新率、窗口计数正常累计、无重复条目、
    /// 无死锁/panic
    ///
    /// 注：危险时序的**确定性**判别由顺序用例
    /// `stale_snapshot_acquire_does_not_revert_updated_config` 保证；本用例
    /// 在旧「acquire 回写」实现下是否翻转取决于写入交错（概率性），作用为
    /// 并发压力下的不变量验证。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_stale_acquires_and_update_keep_latest_config() {
        let registry = Arc::new(RateLimiterRegistry::new());
        // 旧率放宽到 4/10000：4 次访问（预热 1 + 并发 3）在 update 落地前
        // 也全部即时放行，用例不依赖 update 任务的调度先后
        let stale = source("https://rate-concurrent.example", Some("4/10000"));
        registry.acquire(&stale).await; // 旧率下窗口已用 1 次

        let mut tasks = Vec::new();
        for _ in 0..3 {
            let registry = Arc::clone(&registry);
            let stale = stale.clone();
            tasks.push(tokio::spawn(async move { registry.acquire(&stale).await }));
        }
        {
            let registry = Arc::clone(&registry);
            let url = stale.book_source_url.clone();
            tasks.push(tokio::spawn(async move {
                for _ in 0..20 {
                    registry.update(&url, "8/10000");
                }
            }));
        }
        for task in tasks {
            task.await.expect("并发任务不得 panic");
        }

        // 8/10000 的窗口足够容纳此前 1+3 次访问，结束后应仍能立即放行一次
        let passed =
            tokio::time::timeout(Duration::from_millis(1000), registry.acquire(&stale)).await;
        assert!(passed.is_ok(), "并发结束后配置必须保持为 update 写入的新率");
        assert_eq!(tracked(&registry), 1, "并发过程不得产生重复条目");
    }

    // ─── remove / refresh（保存路径空值清除语义） ─────────────────────────────

    /// remove 丢弃记录：下次 acquire 按当前快照重新惰性创建（新窗口立即放行）
    #[tokio::test]
    async fn remove_drops_record_and_next_acquire_recreates() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-remove.example", Some("1/10000"));
        registry.acquire(&src).await; // 窗口已用 1 次（继续访问会被挡）
        assert_eq!(tracked(&registry), 1);

        registry.remove(&src.book_source_url);
        assert_eq!(tracked(&registry), 0, "remove 必须丢弃既有条目");

        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(passed.is_ok(), "remove 后重新惰性创建，新窗口应立即放行");
        assert_eq!(tracked(&registry), 1, "重新 acquire 应重建条目");
    }

    /// remove 不影响在途 Arc：已取走的 limiter 实例按原窗口继续约束
    #[tokio::test]
    async fn remove_keeps_in_flight_arc_alive() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-remove-inflight.example", Some("1/10000"));
        registry.acquire(&src).await; // 窗口已用 1 次

        let inflight = {
            let guard = registry.limiters.lock().unwrap_or_else(|p| p.into_inner());
            Arc::clone(guard.get(&src.book_source_url).expect("已注册"))
        };
        registry.remove(&src.book_source_url);

        // 在途实例仍持原窗口：继续 acquire 被挡
        let blocked = tokio::time::timeout(Duration::from_millis(300), inflight.acquire()).await;
        assert!(
            blocked.is_err(),
            "在途 Arc 必须按原窗口继续约束，不受 remove 影响"
        );
        // 注册表侧已是新实例：立即放行
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(passed.is_ok(), "remove 后注册表应按快照重建新窗口");
    }

    /// remove 未注册 key 为 no-op（不 panic、不产生条目）
    #[tokio::test]
    async fn remove_unregistered_key_is_noop() {
        let registry = RateLimiterRegistry::new();
        registry.remove("https://rate-remove-absent.example");
        assert_eq!(tracked(&registry), 0);
    }

    /// refresh 分发：空 / `"0"`（含空白）→ 移除；非法 → 不改动既有记录；
    /// 合法 → 原地刷新且不新建条目
    #[tokio::test]
    async fn refresh_empty_or_zero_removes_and_invalid_keeps() {
        let registry = RateLimiterRegistry::new();
        let src = source("https://rate-refresh.example", Some("2/10000"));
        registry.acquire(&src).await;
        registry.acquire(&src).await; // 窗口已用满 2 次

        // 非法值不改动既有记录（仍受旧限制约束）
        registry.refresh(&src.book_source_url, "abc");
        let blocked =
            tokio::time::timeout(Duration::from_millis(300), registry.acquire(&src)).await;
        assert!(blocked.is_err(), "非法值 refresh 不得改变既有记录");

        // 空白串 → 移除（原版空即不限流）
        registry.refresh(&src.book_source_url, "  ");
        assert_eq!(tracked(&registry), 0, "空值 refresh 必须移除既有条目");
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(passed.is_ok(), "清除后应立即放行");

        // "0" → 同样移除
        registry.acquire(&src).await;
        registry.acquire(&src).await; // 2/10000 窗口再次用满
        registry.refresh(&src.book_source_url, "0");
        assert_eq!(tracked(&registry), 0, "\"0\" refresh 必须移除既有条目");
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(passed.is_ok(), "\"0\" 清除后应立即放行");

        // 合法值 → 既有记录被原地刷新且不新建条目
        registry.acquire(&src).await; // 重建条目（窗口已用 1 次）
        registry.refresh(&src.book_source_url, "3/10000");
        assert_eq!(tracked(&registry), 1, "合法值 refresh 必须原地刷新");
        let passed = tokio::time::timeout(Duration::from_millis(500), registry.acquire(&src)).await;
        assert!(passed.is_ok(), "升额到 3 且保留已用 1 次后应立即放行");
    }
}
