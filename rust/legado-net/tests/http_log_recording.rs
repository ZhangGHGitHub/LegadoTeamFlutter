//! HTTP 日志采集点回归（legado-net 统一请求入口）
//!
//! 覆盖：
//! 1. 开关关闭 → 零记录；
//! 2. 开启 → 成功请求记录一条（含响应体/状态码/耗时），重定向链只记一条；
//! 3. 失败 → statusCode=-1、error 非空、响应字段为空；
//! 4. 客户端级重试 → 只在最终结果处记录一条（不按尝试次数重复）；
//! 5. `followRedirects=false` 派生客户端 → 原样记录 302。
//!
//! 说明：采集实现（单槽）与开关均为进程级状态，本文件的用例以
//! [`TEST_LOCK`] 串行；断言按 mock 服务端口过滤，避免同二进制其他
//! 用例的并发请求混入。

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use legado_net::{
    install_recorder, set_recording_enabled, HttpLogEntry, HttpLogRecorder, LegadoClient,
    LegadoClientConfig, RetryConfig,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// 串行锁（开关为进程级状态）
static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 测试用采集实现
#[derive(Default)]
struct TestRecorder {
    entries: Mutex<Vec<HttpLogEntry>>,
}

impl HttpLogRecorder for TestRecorder {
    fn record(&self, entry: HttpLogEntry) {
        self.entries.lock().unwrap().push(entry);
    }
}

/// 进程级唯一测试采集实现（注册一次）
fn recorder() -> &'static Arc<TestRecorder> {
    static RECORDER: OnceLock<Arc<TestRecorder>> = OnceLock::new();
    RECORDER.get_or_init(|| {
        let recorder = Arc::new(TestRecorder::default());
        install_recorder(recorder.clone());
        recorder
    })
}

/// 清空记录（串行锁内调用）
fn clear_records() {
    recorder().entries.lock().unwrap().clear();
}

/// 取命中指定端口的记录
fn entries_for(addr: SocketAddr) -> Vec<HttpLogEntry> {
    let needle = addr.to_string();
    recorder()
        .entries
        .lock()
        .unwrap()
        .iter()
        .filter(|entry| entry.url.contains(&needle))
        .cloned()
        .collect()
}

/// 一次性回环 mock：按请求序号交给 handler 决定 `(状态码, 额外响应头, 响应体)`
async fn spawn_mock<F>(handler: F) -> (SocketAddr, Arc<AtomicUsize>)
where
    F: Fn(&str, usize) -> (u16, Vec<(String, String)>, String) + Send + Sync + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_for_server = Arc::clone(&hits);
    let handler = Arc::new(handler);
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let index = hits_for_server.fetch_add(1, Ordering::SeqCst);
            let handler = Arc::clone(&handler);
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]);
                let path = head
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/")
                    .to_string();
                let (status, headers, body) = handler(&path, index);
                let mut response = format!(
                    "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n",
                    body.len()
                );
                for (name, value) in headers {
                    response.push_str(&format!("{name}: {value}\r\n"));
                }
                response.push_str("\r\n");
                response.push_str(&body);
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (addr, hits)
}

/// 回环测试客户端（禁用系统代理，避免环境代理劫持 127.0.0.1）
fn client() -> LegadoClient {
    LegadoClient::new(LegadoClientConfig {
        no_proxy: true,
        ..LegadoClientConfig::default()
    })
    .expect("构建测试客户端")
}

#[tokio::test]
async fn test_recording_disabled_does_not_record() {
    let _g = TEST_LOCK.lock().await;
    clear_records();
    set_recording_enabled(false);

    let (addr, _) = spawn_mock(|_path, _idx| (200, Vec::new(), "ok".to_string())).await;
    client()
        .get(&format!("http://{addr}/off"), None)
        .await
        .unwrap();
    assert!(entries_for(addr).is_empty(), "开关关闭时不得记录任何请求");
}

#[tokio::test]
async fn test_success_and_redirect_chain_record_single_entry() {
    let _g = TEST_LOCK.lock().await;
    clear_records();
    set_recording_enabled(true);

    let (addr, _) = spawn_mock(|path, _idx| {
        if path == "/start" {
            (
                302,
                vec![("Location".to_string(), "/final".to_string())],
                String::new(),
            )
        } else {
            (200, Vec::new(), "hello-log".to_string())
        }
    })
    .await;

    let mut headers = HashMap::new();
    headers.insert("X-Trace".to_string(), "visible".to_string());
    let resp = client()
        .get(&format!("http://{addr}/start?token=abc"), Some(headers))
        .await
        .unwrap();
    assert_eq!(resp.status, 200, "重定向应被跟随到最终响应");
    assert_eq!(resp.body, "hello-log");

    let entries = entries_for(addr);
    assert_eq!(
        entries.len(),
        1,
        "一次调用（含重定向链）只记录一条（对齐原版应用拦截器语义）: {entries:?}"
    );
    let entry = &entries[0];
    assert_eq!(entry.method, "GET");
    assert!(
        entry.url.contains("/start?token=abc"),
        "记录原始请求 URL（非重定向最终 URL）: {}",
        entry.url
    );
    assert_eq!(entry.status_code, 200);
    assert_eq!(entry.response_body, "hello-log");
    assert_eq!(
        entry.request_headers.get("X-Trace").map(String::as_str),
        Some("visible")
    );
    assert!(entry.error.is_none());
    assert!(entry.duration_ms >= 0);
    set_recording_enabled(false);
}

#[tokio::test]
async fn test_failure_records_status_minus_one() {
    let _g = TEST_LOCK.lock().await;
    clear_records();
    set_recording_enabled(true);

    // 先占用端口再释放，保证连接被拒绝
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);

    let err = client()
        .get(&format!("http://{addr}/boom"), None)
        .await
        .expect_err("连接被拒绝应返回错误");
    let entries = entries_for(addr);
    assert_eq!(entries.len(), 1, "失败请求应记录一条: {entries:?}");
    assert_eq!(entries[0].status_code, -1);
    assert!(entries[0].response_headers.is_empty());
    assert!(entries[0].response_body.is_empty());
    assert!(
        entries[0]
            .error
            .as_deref()
            .is_some_and(|e| e.contains("Connection failed") || e.contains("Request failed")),
        "失败摘要应携带错误原因: {:?}",
        entries[0].error
    );
    assert!(!err.to_string().is_empty());
    set_recording_enabled(false);
}

#[tokio::test]
async fn test_retry_records_once_with_final_status() {
    let _g = TEST_LOCK.lock().await;
    clear_records();
    set_recording_enabled(true);

    let (addr, hits) = spawn_mock(|_path, index| {
        if index == 0 {
            (500, Vec::new(), "first-fail".to_string())
        } else {
            (200, Vec::new(), "after-retry".to_string())
        }
    })
    .await;

    let client = LegadoClient::new(LegadoClientConfig {
        no_proxy: true,
        retry: Some(RetryConfig {
            max_retries: 1,
            initial_delay_ms: 1,
            ..RetryConfig::default()
        }),
        ..LegadoClientConfig::default()
    })
    .unwrap();
    let resp = client
        .get(&format!("http://{addr}/retry"), None)
        .await
        .unwrap();
    assert_eq!(resp.status, 200);
    assert_eq!(
        hits.load(Ordering::SeqCst),
        2,
        "mock 应收到两次请求（重试）"
    );

    let entries = entries_for(addr);
    assert_eq!(
        entries.len(),
        1,
        "重试只在最终结果处记录一条，不得按尝试次数重复: {entries:?}"
    );
    assert_eq!(entries[0].status_code, 200);
    assert_eq!(entries[0].response_body, "after-retry");
    set_recording_enabled(false);
}

#[tokio::test]
async fn test_no_redirect_variant_records_302() {
    let _g = TEST_LOCK.lock().await;
    clear_records();
    set_recording_enabled(true);

    let (addr, _) = spawn_mock(|_path, _idx| {
        (
            302,
            vec![("Location".to_string(), "/final".to_string())],
            String::new(),
        )
    })
    .await;

    let client = client();
    let variant = client.no_redirect_variant().unwrap();
    let resp = variant
        .get(&format!("http://{addr}/direct"), None)
        .await
        .unwrap();
    assert_eq!(resp.status, 302, "不跟随重定向变体应原样返回 302");

    let entries = entries_for(addr);
    assert_eq!(entries.len(), 1, "变体请求同样只记录一条: {entries:?}");
    assert_eq!(entries[0].status_code, 302);
    set_recording_enabled(false);
}
