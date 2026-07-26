//! 来源验证并发去重注册表
//!
//! 当多个书源同时触发验证（浏览器登录/验证码）时，
//! 对相同 sourceUrl 的请求进行去重，避免重复弹出 WebView。

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{oneshot, Mutex};

/// 验证结果
pub enum VerificationResult {
    /// 直接响应（验证成功）
    Response { code: String, cookie: String },
    /// 需要重新获取（之前的验证失败了）
    Refetch,
}

/// 验证请求航班注册表
pub struct VerificationFlightRegistry {
    flights: Arc<Mutex<HashMap<String, Vec<oneshot::Sender<VerificationResult>>>>>,
}

impl VerificationFlightRegistry {
    pub fn new() -> Self {
        Self {
            flights: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 尝试加入已有的验证航班
    /// 返回 Some(receiver) 表示成功加入，None 表示需要自己发起验证
    pub async fn try_join(
        &self,
        source_url: &str,
    ) -> Option<oneshot::Receiver<VerificationResult>> {
        let mut flights = self.flights.lock().await;
        if flights.contains_key(source_url) {
            let (tx, rx) = oneshot::channel();
            flights.get_mut(source_url).unwrap().push(tx);
            Some(rx)
        } else {
            None
        }
    }

    /// 注册新的验证航班
    pub async fn register(&self, source_url: &str) -> oneshot::Receiver<VerificationResult> {
        let mut flights = self.flights.lock().await;
        let (tx, rx) = oneshot::channel();
        flights
            .entry(source_url.to_string())
            .or_insert_with(Vec::new)
            .push(tx);
        rx
    }

    /// 完成验证，通知所有等待者
    pub async fn complete(&self, source_url: &str, result: VerificationResult) {
        let mut flights = self.flights.lock().await;
        if let Some(senders) = flights.remove(source_url) {
            // 第一个得到完整结果，后续得到 Refetch 信号
            let mut first = true;
            for sender in senders {
                if first {
                    let _ = sender.send(result.clone_result());
                    first = false;
                } else {
                    let _ = sender.send(VerificationResult::Refetch);
                }
            }
        }
    }

    /// 检查是否可以加入验证航班
    pub async fn can_join(&self, source_url: &str) -> bool {
        let flights = self.flights.lock().await;
        flights.contains_key(source_url)
    }
}

impl Default for VerificationFlightRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl VerificationResult {
    fn clone_result(&self) -> Self {
        match self {
            VerificationResult::Response { code, cookie } => VerificationResult::Response {
                code: code.clone(),
                cookie: cookie.clone(),
            },
            VerificationResult::Refetch => VerificationResult::Refetch,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_try_join_no_existing_flight() {
        let registry = VerificationFlightRegistry::new();
        let result = registry.try_join("https://example.com").await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_register_and_join() {
        let registry = VerificationFlightRegistry::new();
        // Register a flight
        let _rx1 = registry.register("https://example.com").await;
        // Now try_join should succeed
        let rx2 = registry.try_join("https://example.com").await;
        assert!(rx2.is_some());
    }

    #[tokio::test]
    async fn test_can_join() {
        let registry = VerificationFlightRegistry::new();
        assert!(!registry.can_join("https://example.com").await);
        let _rx = registry.register("https://example.com").await;
        assert!(registry.can_join("https://example.com").await);
    }

    #[tokio::test]
    async fn test_complete_notifies_waiters() {
        let registry = Arc::new(VerificationFlightRegistry::new());
        let rx1 = registry.register("https://example.com").await;
        let rx2 = registry.try_join("https://example.com").await.unwrap();

        let registry_clone = Arc::clone(&registry);
        tokio::spawn(async move {
            registry_clone
                .complete(
                    "https://example.com",
                    VerificationResult::Response {
                        code: "200".to_string(),
                        cookie: "session=abc".to_string(),
                    },
                )
                .await;
        });

        let result1 = rx1.await.unwrap();
        let result2 = rx2.await.unwrap();

        // First waiter gets the full result
        match result1 {
            VerificationResult::Response { code, cookie } => {
                assert_eq!(code, "200");
                assert_eq!(cookie, "session=abc");
            }
            VerificationResult::Refetch => panic!("Expected Response, got Refetch"),
        }

        // Second waiter gets Refetch
        match result2 {
            VerificationResult::Refetch => {}
            VerificationResult::Response { .. } => panic!("Expected Refetch, got Response"),
        }
    }
}
