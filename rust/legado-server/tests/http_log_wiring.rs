//! HTTP 采集接线回归（legado-net 采集点 → legado-server 存储，批11）
//!
//! 独立测试二进制（与 lib 单测不同进程），避免全局开关/单槽与 lib 用例互相干扰。
//! 覆盖：安装存储实现 + 开关开启后，`LegadoClient` 请求落 ring，且 URL/路径
//! 按 `HttpLogSanitizer` 规则脱敏（`/token/abc` → `/token/[redacted]`）。

use legado_net::{LegadoClient, LegadoClientConfig};
use legado_server::legacy::http_log::{
    apply_recording_config, http_log_store, install_http_log_recorder,
};

/// 串行锁：开关为进程级状态，同二进制用例不得并发切换
static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[tokio::test]
async fn test_net_client_writes_sanitized_store_record() {
    let _g = TEST_LOCK.lock().await;
    install_http_log_recorder();
    apply_recording_config(Some("true"));
    let store = http_log_store();
    store.clear();

    async fn hello() -> &'static str {
        "wired"
    }

    let app = axum::Router::new().route("/token/abc", axum::routing::get(hello));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定回环端口");
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    // no_proxy=true：回环流量不得经系统/环境代理
    let client = LegadoClient::new(LegadoClientConfig {
        no_proxy: true,
        ..LegadoClientConfig::default()
    })
    .unwrap();
    let resp = client
        .get(&format!("http://{addr}/token/abc?page=2"), None)
        .await
        .expect("请求回环服务");
    assert_eq!(resp.body, "wired");

    let needle = addr.to_string();
    let record = store
        .latest(50)
        .into_iter()
        .find(|record| record.url.contains(&needle))
        .expect("采集实现应写入一条记录");
    assert_eq!(record.status_code, 200);
    assert_eq!(record.method, "GET");
    assert_eq!(record.response_body, "wired");
    assert_eq!(
        record.path, "/token/[redacted]",
        "敏感名路径段的下一段应脱敏（P2-4）"
    );
    assert!(
        !record.url.contains("abc"),
        "脱敏后的 url 不得含敏感段：{}",
        record.url
    );

    apply_recording_config(None);
    store.clear();
}

/// 开关关闭时 `LegadoClient` 不写任何记录（同进程内先开后关）
#[tokio::test]
async fn test_switch_off_stops_recording() {
    let _g = TEST_LOCK.lock().await;
    install_http_log_recorder();
    let store = http_log_store();
    store.clear();
    apply_recording_config(None);

    async fn hello() -> &'static str {
        "off"
    }

    let app = axum::Router::new().route("/off", axum::routing::get(hello));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定回环端口");
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    let client = LegadoClient::new(LegadoClientConfig {
        no_proxy: true,
        ..LegadoClientConfig::default()
    })
    .unwrap();
    client
        .get(&format!("http://{addr}/off"), None)
        .await
        .expect("请求回环服务");

    let needle = addr.to_string();
    assert!(
        store
            .latest(50)
            .iter()
            .all(|record| !record.url.contains(&needle)),
        "开关关闭时不得写入记录"
    );
}
