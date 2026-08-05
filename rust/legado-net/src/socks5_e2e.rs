//! SOCKS5 凭据代理 e2e 测试（复核 #469）
//!
//! 内置最小 SOCKS5 测试服务器（RFC 1928 握手 + RFC 1929 用户名/密码认证），
//! 配合本地最小 HTTP 源站，验证 `LegadoClient` 经
//! `socks5://user:pass@127.0.0.1:port` 代理的完整链路：
//!
//! - 正确凭据：认证握手成功 → CONNECT 转发 → 请求到达源站并取回响应体
//! - 错误凭据：认证被拒（状态 0x01）→ 请求失败
//!
//! 纯测试代码（#[cfg(test)] 模块），不进入发布构建。

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

use crate::{LegadoClient, LegadoClientConfig, ProxyConfig};

/// SOCKS5 握手观测计数
#[derive(Default, Debug)]
struct Socks5Stats {
    /// 认证成功的连接数
    auth_ok: usize,
    /// 认证被拒的连接数（错误凭据）
    auth_rejected: usize,
    /// 完成 CONNECT 转发的连接数
    connected: usize,
}

/// 启动最小 SOCKS5 测试服务器（要求用户名/密码认证，RFC 1929）
///
/// 返回监听地址与共享统计。每个连接的处理流程：
/// 1. 方法协商：仅接受 0x02（用户名/密码），否则回 0xFF 断开
/// 2. 认证子协商：校验 user/pass，失败回 0x01 断开
/// 3. CONNECT 请求：解析目标地址（IPv4/域名/IPv6），建连后双向透传
async fn spawn_socks5_server(
    expected_user: &str,
    expected_pass: &str,
) -> (SocketAddr, Arc<Mutex<Socks5Stats>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let stats = Arc::new(Mutex::new(Socks5Stats::default()));
    let server_stats = Arc::clone(&stats);
    let user = expected_user.to_string();
    let pass = expected_pass.to_string();

    tokio::spawn(async move {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => break,
            };
            let stats = Arc::clone(&server_stats);
            let user = user.clone();
            let pass = pass.clone();
            tokio::spawn(async move {
                let _ = handle_socks5_conn(stream, &user, &pass, &stats).await;
            });
        }
    });

    (addr, stats)
}

/// 处理单个 SOCKS5 连接
async fn handle_socks5_conn(
    mut stream: TcpStream,
    user: &str,
    pass: &str,
    stats: &Mutex<Socks5Stats>,
) -> std::io::Result<()> {
    // ---- 方法协商（RFC 1928 §3）----
    let mut hdr = [0u8; 2];
    stream.read_exact(&mut hdr).await?;
    if hdr[0] != 0x05 {
        return Ok(()); // 非 SOCKS5，直接断开
    }
    let mut methods = vec![0u8; hdr[1] as usize];
    stream.read_exact(&mut methods).await?;
    if !methods.contains(&0x02) {
        // 客户端不支持用户名/密码认证 → 无可用方法
        stream.write_all(&[0x05, 0xFF]).await?;
        return Ok(());
    }
    stream.write_all(&[0x05, 0x02]).await?;

    // ---- 认证子协商（RFC 1929）----
    let mut ver = [0u8; 1];
    stream.read_exact(&mut ver).await?;
    let mut ulen = [0u8; 1];
    stream.read_exact(&mut ulen).await?;
    let mut uname = vec![0u8; ulen[0] as usize];
    stream.read_exact(&mut uname).await?;
    let mut plen = [0u8; 1];
    stream.read_exact(&mut plen).await?;
    let mut passwd = vec![0u8; plen[0] as usize];
    stream.read_exact(&mut passwd).await?;

    let ok = uname == user.as_bytes() && passwd == pass.as_bytes();
    stream
        .write_all(&[0x01, if ok { 0x00 } else { 0x01 }])
        .await?;
    if ok {
        stats.lock().await.auth_ok += 1;
    } else {
        stats.lock().await.auth_rejected += 1;
        return Ok(()); // 认证失败即断开
    }

    // ---- CONNECT 请求（RFC 1928 §4）----
    let mut req = [0u8; 4];
    stream.read_exact(&mut req).await?;
    if req[1] != 0x01 {
        // 仅支持 CONNECT
        stream.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        return Ok(());
    }
    let target = match req[3] {
        0x01 => {
            let mut ip = [0u8; 4];
            stream.read_exact(&mut ip).await?;
            format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
        }
        0x03 => {
            let mut dlen = [0u8; 1];
            stream.read_exact(&mut dlen).await?;
            let mut domain = vec![0u8; dlen[0] as usize];
            stream.read_exact(&mut domain).await?;
            String::from_utf8_lossy(&domain).into_owned()
        }
        0x04 => {
            let mut ip6 = [0u8; 16];
            stream.read_exact(&mut ip6).await?;
            std::net::Ipv6Addr::from(ip6).to_string()
        }
        _ => {
            stream.write_all(&[0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Ok(());
        }
    };
    let mut port = [0u8; 2];
    stream.read_exact(&mut port).await?;
    let target_addr = format!("{}:{}", target, u16::from_be_bytes(port));

    let mut upstream = match TcpStream::connect(&target_addr).await {
        Ok(s) => s,
        Err(_) => {
            stream.write_all(&[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Ok(());
        }
    };
    // 应答成功（BND 地址全零即可）
    stream.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
    stats.lock().await.connected += 1;

    // ---- 双向透传 ----
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut upstream).await;
    Ok(())
}

/// 启动最小 HTTP 源站：固定返回 200 与给定响应体
async fn spawn_http_origin(body: &'static str) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        loop {
            let (mut stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => break,
            };
            tokio::spawn(async move {
                // 读取请求直到头部结束（容错：连接异常即忽略）
                let mut buf = vec![0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });

    addr
}

/// e2e：正确凭据 —— 经 SOCKS5 代理请求本地源站成功
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_socks5_credentialed_proxy_e2e() {
    let (proxy_addr, stats) = spawn_socks5_server("alice", "s3cret").await;
    let origin_addr = spawn_http_origin("socks5-proxied-ok").await;

    // 标准 URI 凭据形式（对齐上游 HttpProxyConfig.kt 的 socks5://user:pass@host:port）
    let proxy_url = format!("socks5://alice:s3cret@{}", proxy_addr);
    let cfg = LegadoClientConfig {
        proxy: Some(ProxyConfig::from_url(proxy_url)),
        ..Default::default()
    };
    let client = LegadoClient::new(cfg).expect("构建代理客户端失败");

    let body = client
        .get_bytes(&format!("http://{}/hello", origin_addr), None)
        .await
        .expect("经 SOCKS5 代理的请求应成功");
    assert_eq!(body, b"socks5-proxied-ok");

    // 验证认证握手与 CONNECT 转发真实发生
    let stats = stats.lock().await;
    assert!(
        stats.auth_ok >= 1,
        "SOCKS5 服务器应记录至少一次认证成功，实际：{:?}",
        *stats
    );
    assert_eq!(stats.auth_rejected, 0, "正确凭据不应触发认证拒绝");
    assert!(stats.connected >= 1, "应完成至少一次 CONNECT 转发");
}

/// e2e：错误凭据 —— 认证被服务器拒绝，请求失败
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_socks5_wrong_credentials_rejected() {
    let (proxy_addr, stats) = spawn_socks5_server("alice", "s3cret").await;
    let origin_addr = spawn_http_origin("should-not-reach").await;

    let proxy_url = format!("socks5://alice:wrong-pass@{}", proxy_addr);
    let cfg = LegadoClientConfig {
        proxy: Some(ProxyConfig::from_url(proxy_url)),
        ..Default::default()
    };
    let client = LegadoClient::new(cfg).expect("构建代理客户端失败");

    let result = client
        .get_bytes(&format!("http://{}/hello", origin_addr), None)
        .await;
    assert!(
        result.is_err(),
        "错误凭据经 SOCKS5 代理的请求必须失败，实际：{:?}",
        result.ok().map(|b| String::from_utf8_lossy(&b).into_owned())
    );

    // 验证服务器确实拒绝了认证握手（而非连接未发生）
    let stats = stats.lock().await;
    assert!(
        stats.auth_rejected >= 1,
        "SOCKS5 服务器应记录至少一次认证拒绝，实际：{:?}",
        *stats
    );
    assert_eq!(stats.auth_ok, 0, "错误凭据不应认证成功");
    assert_eq!(stats.connected, 0, "认证失败后不应发生 CONNECT 转发");
}
