//! 网络请求中间件框架
//!
//! 提供可组合的中间件链，用于在请求发送前后执行通用逻辑（如重试、限流、日志等）。

use std::sync::Arc;

use legado_core::{LegadoError, LegadoResult};
use reqwest::{RequestBuilder, Response};

/// 中间件 trait
///
/// 每个中间件可以在请求发送前后执行逻辑，并决定是否将请求传递给下一个中间件。
#[async_trait::async_trait]
pub trait Middleware: Send + Sync {
    /// 中间件名称，用于日志和调试
    fn name(&self) -> &str;

    /// 处理请求
    ///
    /// - `request`: 待发送的请求构建器
    /// - `next`: 调用链中的下一个处理器
    ///
    /// 返回响应或错误。
    async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response>;
}

/// 下一个处理器（类型擦除的 future）
pub type Next = Arc<
    dyn Fn(RequestBuilder) -> futures_core::future::BoxFuture<'static, LegadoResult<Response>>
        + Send
        + Sync,
>;

/// 中间件链
///
/// 按注册顺序依次执行中间件，最后一个处理器为实际发送请求。
pub struct MiddlewareChain {
    middlewares: Vec<Arc<dyn Middleware>>,
}

impl MiddlewareChain {
    /// 创建空的中间件链
    pub fn new() -> Self {
        Self {
            middlewares: Vec::new(),
        }
    }

    /// 添加中间件到链尾
    pub fn add<M: Middleware + 'static>(&mut self, middleware: M) -> &mut Self {
        self.middlewares.push(Arc::new(middleware));
        self
    }

    /// 添加 Arc 包裹的中间件
    pub fn add_arc(&mut self, middleware: Arc<dyn Middleware>) -> &mut Self {
        self.middlewares.push(middleware);
        self
    }

    /// 返回中间件数量
    pub fn len(&self) -> usize {
        self.middlewares.len()
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.middlewares.is_empty()
    }

    /// 执行中间件链
    ///
    /// 从第一个中间件开始，依次调用 `next` 直到最终发送请求。
    pub async fn execute(
        &self,
        request: RequestBuilder,
        final_handler: Next,
    ) -> LegadoResult<Response> {
        if self.middlewares.is_empty() {
            return final_handler(request).await;
        }

        // 从后往前构建调用链
        let mut chain: Next = final_handler;

        for mw in self.middlewares.iter().rev() {
            let mw = Arc::clone(mw);
            let inner_chain = Arc::clone(&chain);
            chain = Arc::new(move |req: RequestBuilder| {
                let mw = Arc::clone(&mw);
                let inner = Arc::clone(&inner_chain);
                Box::pin(async move { mw.handle(req, inner).await })
            });
        }

        chain(request).await
    }
}

impl Default for MiddlewareChain {
    fn default() -> Self {
        Self::new()
    }
}

/// 创建最终的请求发送处理器
pub fn make_send_handler(_client: reqwest::Client) -> Next {
    Arc::new(move |req: RequestBuilder| {
        Box::pin(async move {
            req.send().await.map_err(|e| {
                if e.is_timeout() {
                    LegadoError::Timeout(format!("Request timeout: {}", e))
                } else if e.is_connect() {
                    LegadoError::Network(format!("Connection failed: {}", e))
                } else {
                    LegadoError::Network(format!("Request failed: {}", e))
                }
            })
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// 测试用中间件：记录执行顺序
    struct OrderTracker {
        id: usize,
        counter: Arc<AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl Middleware for OrderTracker {
        fn name(&self) -> &str {
            "OrderTracker"
        }

        async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
            // 记录进入顺序
            let seq = self.counter.fetch_add(1, Ordering::SeqCst);
            assert_eq!(seq, self.id, "Middleware executed out of order");
            next(request).await
        }
    }

    /// 测试用中间件：添加请求头
    #[allow(dead_code)]
    struct HeaderAdder {
        name: String,
        value: String,
    }

    #[async_trait::async_trait]
    impl Middleware for HeaderAdder {
        fn name(&self) -> &str {
            "HeaderAdder"
        }

        async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
            let req = request.header(&self.name, &self.value);
            next(req).await
        }
    }

    #[test]
    fn test_middleware_chain_new() {
        let chain = MiddlewareChain::new();
        assert!(chain.is_empty());
        assert_eq!(chain.len(), 0);
    }

    #[test]
    fn test_middleware_chain_add() {
        let counter = Arc::new(AtomicUsize::new(0));
        let mut chain = MiddlewareChain::new();
        chain.add(OrderTracker {
            id: 0,
            counter: counter.clone(),
        });
        assert_eq!(chain.len(), 1);
        assert!(!chain.is_empty());
    }

    #[test]
    fn test_middleware_chain_default() {
        let chain = MiddlewareChain::default();
        assert!(chain.is_empty());
    }

    #[tokio::test]
    async fn test_middleware_chain_execution_order() {
        let counter = Arc::new(AtomicUsize::new(0));
        let mut chain = MiddlewareChain::new();

        chain.add(OrderTracker {
            id: 0,
            counter: counter.clone(),
        });
        chain.add(OrderTracker {
            id: 1,
            counter: counter.clone(),
        });
        chain.add(OrderTracker {
            id: 2,
            counter: counter.clone(),
        });

        // 模拟最终处理器（不实际发送请求）
        let final_handler: Next = Arc::new(|_req: RequestBuilder| {
            Box::pin(async move { Err(LegadoError::Network("test sentinel".to_string())) })
        });

        let client = reqwest::Client::new();
        let req = client.get("http://example.com");

        let result = chain.execute(req, final_handler).await;
        // 最终处理器返回错误
        assert!(result.is_err());
        // 三个中间件都已执行
        assert_eq!(counter.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn test_empty_chain_calls_final_handler() {
        let chain = MiddlewareChain::new();

        let called = Arc::new(AtomicUsize::new(0));
        let called_clone = called.clone();
        let final_handler: Next = Arc::new(move |_req: RequestBuilder| {
            let c = called_clone.clone();
            Box::pin(async move {
                c.fetch_add(1, Ordering::SeqCst);
                Err(LegadoError::Network("final".to_string()))
            })
        });

        let client = reqwest::Client::new();
        let req = client.get("http://example.com");

        let _ = chain.execute(req, final_handler).await;
        assert_eq!(called.load(Ordering::SeqCst), 1);
    }
}
