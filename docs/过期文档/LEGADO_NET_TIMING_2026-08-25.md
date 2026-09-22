# legado-net 逐请求分段计时诊断（2026-08-25）

## 一、目的

根因报告 `docs/SEARCH_SPEED_COUNT_ROOT_CAUSE_2026-08-25.md` §二已判定：搜索结果慢的主因是我方 Rust 网络栈逐请求延迟偏高（而非书源数量或 JS 规则）。本文提供**实测分段数据**，定位具体卡点（DNS / TCP / TLS / TTFB / body），支撑下一步修复决策。

## 二、机制

新增 `legado-net::timing` 模块，由环境变量 **`LEGADO_NET_TIMING=1`** 门控：

| 计时点 | 位置 | 说明 |
|---|---|---|
| DNS | `custom_hosts.rs` resolver | 命中自定义 hosts 映射记 0ms（纯内存查表）；回落系统 DNS 时计 `lookup_host` 耗时并记录地址族分布 |
| TTFB / body | `client.rs` 请求包装 | ttfb=发送到收到响应头（含 DNS+connect+TLS+服务端首包）；body=收头到读完响应体 |
| TCP v4/v6 | `timing::probe_tcp_connect` | 独立连接探针，按地址族各测一次 `TcpStream::connect`（5s 超时），用于区分「IPv6 黑洞等待」与正常连接 |

**零开销设计**：所有计时点先经 `timing_enabled()`（`OnceLock` 缓存环境变量判定），未开启时仅一次原子读，几乎无额外开销；生产构建默认关闭。

对端地址取自 `reqwest::Response::remote_addr()`，可直接判断实际走 IPv4 还是 IPv6。

## 三、实测数据（视频源组搜索「一人之下」）

运行：`cargo run --example timing_video_search -- <db_copy> 一人之下 [urls_json]`
总墙钟 **19.47s**，11 个批次共 140 本书。

### 3.1 逐请求分段（REQUEST_TIMING）

| host | dns_ms | v4/v6 | ttfb_ms | body_ms | total_ms | remote |
|---|---|---|---|---|---|---|
| api5-sinfonlinec.novelfm.com | 32.783 | 9/9 | 104.527 | 0.100 | 104.627 | v6 [2408:…] |
| api.bilibili.com (nav) | 37.482 | 15/8 | 156.350 | 2.057 | 158.407 | v6 [2408:…] |
| 66yy.net | 15.522 | 1/0 | 185.090 | 5.520 | 190.610 | v4 103.215.78.71 |
| 23.225.142.42 (http:80) | na | – | 402.844 | 0.488 | 403.332 | v4 |
| manwane.cc | 16.305 | 3/0 | 704.611 | 0.363 | 704.974 | v4 104.17.62.130 |
| silidm.com | 36.435 | 2/2 | 704.035 | 0.489 | 704.524 | v6 [2606:…] (Cloudflare) |
| api.bilibili.com (wbi search) | 0.215* | 15/8 | 629.910 | 1.713 | 631.622 | v6 [2408:…] |
| www.qmao.net | 21.837 | 1/0 | 1261.296 | 0.362 | 1261.659 | v4 45.134.173.117 |
| wm.your0tube.com | 26.011 | 2/2 | 1889.650 | **180.854** | 2070.504 | v6 [2606:…] |
| ukuzy.com | 23.899 | 2/2 | 2248.588 | 0.673 | 2249.261 | v6 [2606:…] |
| 23.224.101.30 (http:80) | na | – | **2440.176** | 0.553 | 2440.729 | v4 |
| hongniuziyuan.com | 10.546 | 2/2 | 2168.183 | 3.287 | 2171.470 | v6 [2606:…] |

\* 同 host 第二次请求，hyper 内部 DNS 缓存命中（原解析 37.5ms）。

### 3.2 TCP 连接探针（分族）

| host | v4_ms | v6_ms |
|---|---|---|
| api5-sinfonlinec.novelfm.com | 9.1 | 7.9 |
| api.bilibili.com | 27.1 | 30.3 |
| 66yy.net | 35.1 | none（DNS 无 v6） |
| 23.225.142.42:80 | 212.3 | none |
| manwane.cc | 208.3 | none |
| silidm.com | 229.9 | 222.5 |
| www.qmao.net | 220.0 | none |
| wm.your0tube.com | 211.8 | 226.3 |
| ukuzy.com | 246.0 | 192.6 |
| hongniuziyuan.com | 225.8 | 204.8 |

## 四、分析

1. **DNS 不是瓶颈**：系统 DNS 首解 10–37ms，重复请求 ~0.2ms（hyper 缓存），自定义 hosts 命中为 0。
2. **TTFB 是绝对主因**：单请求总耗时中 TTFB 占 >99%；body 读取普遍 <6ms（唯一例外 wm.your0tube.com 180ms，响应体大）。
3. **IPv6 路径真实在用且无黑洞**：12 个请求中 7 个实际连到 IPv6（[2408:…] 移动骨干 / [2606:…] Cloudflare v6）；TCP 探针显示 v4/v6 连接耗时同量级（9–246ms），不存在「IPv6 黑洞等待」。
4. **慢源画像**：TTFB >2s 的四个源（23.224.101.30 / ukuzy.com / hongniuziyuan.com / wm.your0tube.com）+ qmao.net 1.26s，均为远端服务端慢；最快 novelfm 104ms。bilibili wbi search API 自身 TTFB ~630ms。
5. **http:80 明文源**：两个 Ares 系 IP 直连（port 80）TTFB 403/2440ms，无 TLS 开销仍慢 → 服务端问题。

## 五、下一步候选

- ~~验证 reqwest 连接池跨批次复用情况~~ → **已验证**：搜索链路统一走 `http_state::shared_client()` 进程级单例（Phase 1b），keep-alive 生效；hermetic 回归测试见 §七。
- ~~对 TTFB 持续 >5s 的源评估超时上限与并发度调优~~ → **已评估，无需改动**：`SEARCH_CONCURRENCY=9`、`SEARCH_SOURCE_TIMEOUT=30s`，实测全部源在 19.5s 内完成（未触超时）；>2s TTFB 为远端服务端延迟，客户端侧无可压缩空间。
- 慢源清单可反馈书源质量分（非代码问题，属数据侧治理）。

## 六、验证状态

- `cargo clippy -p legado-net -- -D warnings` ✅
- `cargo test -p legado-net`：230 passed（含 timing 模块 4 个单测）✅
- `cargo check -p legado-ffi --features quickjs --examples`（timing_video_search 示例）✅

## 七、连接池复用验证与 hosts 陈旧连接修复（同日追加）

### 7.1 复用链路确认

搜索链路（`run_multi_stream` / `multi_source_search` / 单源搜索）统一经
`http_state::shared_client()` 取进程级共享 `LegadoClient`（Phase 1b 单例，Arc clone、
同一 reqwest 连接池 + CookieStore）。因此**重复搜索同 host 时 keep-alive 连接可复用**，
省去 connect + TLS 握手（实测 TCP 探针量级：27–30ms）。

### 7.2 Hermetic 回归测试

`legado-net::client::tests::test_connection_pool_reuses_keep_alive`：本地最小 HTTP/1.1
监听器统计 accept 次数——同一客户端对同 host 发两次顺序请求，断言**仅 1 次 accept**
（第二请求复用池内 keep-alive 连接）。防止未来配置变更悄悄破坏复用。

### 7.3 hosts × 连接池陈旧连接修复

**根因**：reqwest 池按 **host 名**缓存空闲连接。运行时 `set_custom_hosts` 改某域名 IP 后，
pool 中旧连接仍指向旧 IP（直至空闲超时），期间请求打到错误地址——resolver 虽实时读全局映射，
但只对**新连接**生效。

**修复**：`net_api::set_custom_hosts` 在 `apply_custom_hosts` 成功后调用
`http_state::reset_shared_client()` 重建客户端与连接池。在途请求持有旧客户端 Arc clone 不受影响；
CookieStore 重建时从 DB（持久层）重载，无丢失。回归测试：
`test_set_custom_hosts_rebuilds_shared_client`。

编写者：主代理 ｜ 2026-08-25
