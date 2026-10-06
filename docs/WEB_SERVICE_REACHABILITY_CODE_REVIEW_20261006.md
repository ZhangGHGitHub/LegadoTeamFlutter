# Web 服务可达性修复批 代码审查报告

- 审查对象：`09d648fe8d` fix(rust): Web 服务绑定前置与局域网可达（7 文件，+231/−27）
- 审查日期：2026-10-06
- 审查方式：只读审查 + 真实行为验证（cargo test 实跑 / repo 外探针工程实测 / flutter test 实跑）
- 根因依据：`docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md`（缺陷 A/B/C）
- 证据等级声明：静态结论均为源码逐行核验；行为结论区分「本机 Windows 实测」与「机制推理（未实测）」，逐条标注。

---

## Summary: needs changes

阻塞项 0 个；建议项 2 个（W-1 停止→同端口立即重启竞态、W-2 绑定失败句柄槽陈值未清）；可选 4 个。核心修复（缺陷 A/B/C）方向正确、语义等价成立、单池复用成立、既有回归零回归成立；停止路径的竞态为实测确证的既有缺陷暴露面（非本批引入），定级「建议修」而非「阻塞」。

---

## P0 逐项核验

### 1. serve_web(listener, db) 重构正确性 —— 通过

**语义等价**（`rust/legado-server/src/server.rs:73-89` vs 改前 `server.rs:52-70`，基线 `git show 09d648fe8d~1` 核对）：

| 步骤 | 改前 start_server_with_db | 改后 serve_web | 等价性 |
|---|---|---|---|
| AppState 构建 | Arc::new(AppState{db: Mutex::new(db), search_cancelled, download_manager: DownloadManager::new(3)}) | 逐字段相同 | 一致 |
| router | create_router(state) | 相同 | 一致 |
| 日志 | `tracing::info!("... listening on {}", addr)`，addr 来自 `format!("{host}:{port}").parse()` | addr 来自 `listener.local_addr()?` | 等价且更准（解析出的即绑定地址） |
| serve | `axum::serve(listener, router).await?` | 相同 | 一致 |

- 顺序变化无害：改前是「建 AppState → parse addr → bind」，改后 FFI 路径是「调用方 bind → 建 AppState」，独立二进制路径（`start_server_with_db`，`server.rs:58-66`）保留 parse→bind→委托，parse 错误类型（`SocketAddr` parse 的 `AddrParseError` → `Box<dyn Error>`）与改前一致。
- **行为不变性实测**：`cargo test -p legado-server` 实跑 182 单测 + 4 集成（integration_test.rs）+ 9（ws_test.rs，`ws_test.rs:25` 自行 bind 127.0.0.1:0 后走独立路径）全过，0 failed（本机 Windows 实测）。
- `start_server_with_db` 当前 workspace 内无其他调用者（grep 全 rust 目录仅 `server.rs:45` 的 `start_server` 内部调用），「保留给独立二进制」的说法与现状相符。
- **DB 单池**（S28 约束）：`server_api.rs` 新路径 `database_from_pool()`（`server_api.rs:140`，改后行号）从 `db_state` 全局池取连接后经 `serve_web` 注入 `AppState.db`，无第二次 `init_database`/建池；与改前共享同一取池入口，S28 修复未被破坏。实测 `server_shared_db.rs`（HTTP 写→ffi 读、ffi 写→HTTP 读双向）通过（本机实测）。

### 2. bind 前置的错误路径 —— 通过（含一处建议项 W-2）

`server_api.rs:137-141`（改后）：`runtime.block_on(TcpListener::bind(("0.0.0.0", port)))` 在 spawn **之前**，失败 `?` 提前返回 `LegadoError::Internal("Web 服务端口 {port} 绑定失败: {e}")`。

- 不置 `SERVER_RUNNING`：置位语句在 `server_api.rs:152`（spawn 与存句柄之后），bind 失败时执行不到。实测 `server_bind_conflict.rs` 断言 `server_status()` 为 `"running":false` 通过（本机实测）。
- 不写句柄槽：`*guard = Some(handle)` 在 bind 之后（`server_api.rs:149-151`），bind 失败时句柄槽保持旧值——见 W-2。
- 不泄漏 runtime/资源：listener 是 bind 失败时根本不存在、成功时 moved 进 spawn 闭包，失败路径无额外资源；runtime 本就是 `OnceLock` 常驻设计，非泄漏。
- 错误文案风格：与同文件 `mcp_start_internal` 的 `"独立 MCP 服务端口 {} 绑定失败: {e}"`（`server_api.rs:277-279`）同构，中文前缀 + 端口号 + 底层错误，风格一致。
- 失败后重试：探针实测（repo 外工程，循环 5 次：占端口→start 得 Err→释放→立即 start）——**5/5 次成功**，无状态残留阻塞重试（本机实测）。

### 3. 停止路径 —— 建议修（W-1，实测确证）

- 机制：`server_stop`（`server_api.rs:163-179`）abort JoinHandle；tokio abort 在任务任一 await 点取消，`axum::serve` 持 listener 且 accept 循环在 await 点，任务被 abort 即栈展开、listener drop、OS 关闭监听 socket。机制上端口随任务取消释放——成立。
- **但实测抓到竞态**（本机 Windows，repo 外探针，10 轮 stop→**立即**同端口 start）：第 2 轮即失败，`server_start` 返回 `Err(Internal("Web 服务端口 3361 绑定失败: …(os error 10048)"))`——abort 是异步的，`server_stop` 返回时旧任务可能尚未走完展开，立即重 bind 会撞 AddrInUse。加 200ms 延时后 10/10 轮全过。
- 定性：**既有缺陷**（改前 `server_stop` 同样只 abort 不等待），非本批引入；但本批把 bind 提前到 spawn 前，使该竞态从「异步 bind 静默死亡」变成「同步可见的启动失败」，暴露面变大（这是改进——错误至少可见了）。对照同文件 MCP 路径已有解法：`mcp_stop_internal`（`server_api.rs:312-324`）abort 后 `rt.block_on(handle)` 等待任务实际结束。
- 修法：仿 `mcp_stop_internal`，`server_stop` 在 abort 后 `let _ = rt.block_on(handle);` 等待完成（`server_api.rs:172-174` 处加一行）；顺带消除 UI「关闭后马上重开」场景的用户可见失败。

### 4. 0.0.0.0 对齐依据 —— 通过（证据链核实）

- 原版：`app/src/main/java/io/legado/app/web/HttpServer.kt:26` `class HttpServer(port: Int) : NanoHTTPD(port)`（行号核实为 26，调研文档写 25 系轻微笔误，不影响结论）。NanoHTTPD 单参构造 hostname 为 null → `ServerRunnerCluster` 绑 `InetSocketAddress(null即全部接口)`，即绑全接口——与提交口径一致。
- 我方 MCP 路径：`server_api.rs:274-276`（改后行号）`TcpListener::bind(("0.0.0.0", port as u16))`，注释 F5「对齐原版 McpService」——证据链成立。
- 调研文档 §一.3（`docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md:14`）明记 `server_api.rs:129` 硬编码 127.0.0.1 为缺陷 A，改前源码（`git show 09d648fe8d~1` 的 `server_api.rs:129`）核实属实。
- **安全面如实记录**：`create_router`（`legado-server/src/routes.rs:13-22`）无任何鉴权中间件（/api/* 全开放，`/mcp/*` 在 Web 端口挂载下亦未套 token 层——独立 MCP 端口的 token 层只在 `create_mcp_router`）。绑 0.0.0.0 后同 LAN 无鉴权可达。提交信息已声明此影响面并注明「与原版一致」，记录诚实、充分。原版 WebService 同样无 token（原版 MCP 才有 `McpAccess.TOKEN_HEADER`），口径对齐无误。

### 5. 测试可移植性 —— 通过（附边界说明）

**server_bind_all_interfaces.rs**（`rust/legado-ffi/tests/server_bind_all_interfaces.rs:36-45`）：
- IP 发现：UDP `connect("192.0.2.1:80")`（TEST-NET-1，RFC 5737 保留地址，不实际发包）触发内核路由选择后读 `local_addr()`——标准做法。
- 多网卡：只取默认路由出口 IP，单地址即足以判「非仅回环」，无需枚举全部网卡——设计上规避了多网卡复杂性。
- 仅 IPv6 主机（CI ubuntu runner 极少见，GitHub ubuntu-latest 始终有 IPv4）：`UdpSocket::bind("0.0.0.0:0")` 只能拿 IPv4 路由；无 IPv4 路由时 `connect` 失败 → `None` → 降级回环冒烟，不会误报。**注意降级方向是安全的**：降级只减弱覆盖强度，不产生假绿（假绿只会出现在「绑定回归成 127.0.0.1 且无 IPv4」的组合，此时回环冒烟仍过——该组合在 GitHub runner 不存在，风险可忽略，但标注为 partial proof）。
- 容器网络（docker/k8s eth0 内网 IP）：UDP 路由发现取到的容器 IP 同样非回环，`http_get` 经该 IP 连 0.0.0.0 监听者在本机内成立——稳健。
- 判据有效性：仅绑 127.0.0.1 时，经非回环本机 IP 连入必被拒（Linux/Windows/macOS 均如此，回环接口之外的源地址无法到达仅回环监听）——「红」的机制成立（改前红由提交记录声称，本机复跑为改后绿：`server_bind_all_interfaces` 1 passed 实测）。
- pick_free_port 用 `bind("0.0.0.0:0")` 后释放（`server_bind_all_interfaces.rs:48-53`）：与被测绑定同址族，端口释放竞态窗口理论上存在（同机并发测试抢占），但 CI 串行跑 cargo test 集成用例各自独立进程、端口随机，实际风险低——与既有 `server_shared_db.rs` 同款策略，一致性优先，可接受。

**server_bind_conflict.rs**（`server_bind_conflict.rs:37-39`）：占用者用 `bind("0.0.0.0:0")` 动态取随机端口（非固定端口），**无固定端口竞态**；且与被测绑定地址 0.0.0.0 同址族，AddrInUse 必然触发——设计正确。断言三件套（Err + 消息含「绑定失败」与端口号 + running:false）具体不空洞。

---

## P1 逐项核验

### 6. Dart 门控移除完整性 —— 通过

- `webServiceUnsupported` 残留：grep `flutter_legado/lib` + `flutter_legado/test` **零残留**（含 frb_generated.dart 等生成物）。
- foundation import 移除：`settings_screen.dart:1` 已删 `import 'package:flutter/foundation.dart'`；全文件再无 `kIsWeb`/`defaultTargetPlatform`/`TargetPlatform` 引用，无其它用法受影响。flutter analyze（提交记录 No issues found!）+ 本次实跑 `flutter test test/widget/settings_test.dart` 7 用例全过佐证。
- 副题/Switch 恢复：`settings_screen.dart:223-226` 副题三元回到 `enabled && _webServiceStatus.isNotEmpty ? _webServiceStatus : '用浏览器写源或看书'`；`:242-243` Switch `value: _webService` / `onChanged: _toggleWebService`——与其他平台统一形态，`_toggleWebService` 语义未动（`:81-104`，失败走 catch + SnackBar）。
- 登记闭环：注释（`settings_screen.dart:169-173`）与测试注释（`settings_test.dart:102-105`）均指向 `docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md`，「登记待修 → 本批已修复」闭环成立。
- 一个小缺口（P2 级，O-1）：iOS 上 `api.startServer()`（`rust_api_media_format.part.dart:71-73` → `server_start`）失败时 Dart 层 catch 弹 SnackBar——本批修复后 bind 失败会同步 Err，该路径**恰好因此新生效**，但 settings_test 无「iOS 启动失败→SnackBar」的用例；属测试覆盖建议，非缺陷。

### 7. plist 正确性 —— 通过

- 语法：python xml.dom.minidom 实测 parse 通过（PLIST_XML_OK），key/string 配对正确（`Info.plist:76-77`），注释位置合理（相机权限与 ATS 相关键之间，Runner 主表内）。
- 文案：`Web 服务需要在本地网络中供电脑浏览器访问，用于在局域网内写书源、看书与传书`——用途明确，符合用户可读要求。
- 不加 `NSBonjourServices` 的判断：**成立**。`NSBonjourServices` 仅当 App 使用 Bonjour/NWBrowser 做服务发现时才需要；本项目按 IP:port 直连（UI 无发现流程，Dart 侧也无 Bonjour 代码）。**iOS 局域网权限触发面核实**：iOS 14+ TCC 门控的触发条件是「本地网络内直接通信」（单播/组播/广播到 LAN 地址），**不要求** Bonjour 声明；`NSLocalNetworkUsageDescription` 是弹授权框的必要键（无键→不弹框→静默拒绝，与调研 §一.5 一致）。入站 TCP 连入监听 socket 亦在门控面内。本项判断正确。（标注：真机弹窗行为属设备侧验证，调研文档自己也标了「设备行为待验证」，本审查为静态 + 机制证据。）

### 8. settings 测试断言具体性 —— 通过

`settings_test.dart:106-132`（改后）：四重断言——① 副题文案 `用浏览器写源或看书` findsOneWidget；② 旧禁用文案 findsNothing；③ Switch `onChanged` isNotNull（reason 齐备）；④ 平台 override 用 try/finally 复位（框架约束遵守）。非空洞；且既有「非 iOS 维持原形态」用例（`:136-161`）保留，双平台形态各有钉子。实跑通过（本机实测）。

---

## P2 逐项核验

### 9. 提交卫生 + 既有回归 —— 通过

- 7 文件与提交主题全部相关：2 源码（server.rs / server_api.rs）、2 新测试、1 plist、2 Dart（screen/test）。无夹带。提交信息含根因编号、修法、先红后绿证据、门禁真实输出、安全影响面——质量高。
- 既有回归零改动核实：`git show 09d648fe8d` 未触碰 `server_start_requires_db.rs` / `server_shared_db.rs`；二者实跑通过（本机实测各 1 passed）。
- `server_start_requires_db` 零回归推理：该测试进程从不初始化 DB，`server_start` 在 DB 守卫（`server_api.rs:128-132`）就提前 Err，**根本走不到 bind**——绑定地址从 127.0.0.1 改 0.0.0.0 对其无影响，推理成立。
- `server_shared_db` 零回归推理：服务监听 0.0.0.0 时内核对 127.0.0.1 目的地址的连入照样接受（0.0.0.0 是全接口通配，含回环接口），测试内 `127.0.0.1:{port}` 的 HTTP 请求不受影响——推理成立且被实测证实。

---

## Errors (blocking)

无。

## Warnings（建议修，P1）

- **W-1（P1）停止→立即同端口重启竞态**：`rust/legado-ffi/src/api/server_api.rs:163-179` `server_stop` 只 `handle.abort()` 不等待任务展开完成；实测（Windows，10 轮 stop→立即 start）第 2 轮即 `Err(... os error 10048 AddrInUse)`，加 200ms 延时后 10/10 过。症状：期望 stop 后端口立即可复用，实际旧任务展开期间重 bind 失败。修法：仿同文件 `mcp_stop_internal`（`server_api.rs:312-324`），abort 后 `let _ = rt.block_on(handle);`。Proof：探针 `stop_then_restart_same_port_10_cycles`（repo 外，本报告归档）；修后可加一条 `server_stop_releases_port_immediately` 集成测试。
- **W-2（P2，随 W-1 一并处理）**：`server_api.rs:148-151` bind 成功但 spawn/存句柄前若 panic（`lock_handle_slot` 中毒已兜底，仅剩极端情形）或未来新增中途失败分支，句柄槽可能残留上一轮已 abort 的句柄——当前 `server_stop` 的 `guard.take()` 幂等性可容忍，但若加等待逻辑（W-1 修法），残留陈句柄会 block_on 一个早已结束的任务（无害但语义含混）。修法：W-1 补丁里在存新句柄前 `*guard = None` 归零。

## 可选改进（P2）

- **O-1**：`settings_test.dart` 补「iOS 上 startServer 抛错 → SnackBar 可见」用例（bind 同步失败错误路径首次对 Dart 层生效，值得钉住）。
- **O-2**：`server_bind_all_interfaces.rs:35` 注释可加一句「CI 无 IPv4 时降级回环冒烟，覆盖强度减弱」的明示，方便后人理解 partial-proof 语义。
- **O-3**：调研文档 `docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md:14` 引用 `HttpServer.kt:25`，实际类声明在 `:26`（核实所见），下次顺路更正，不影响结论。
- **O-4**：`server_api.rs` 的 Web 路径无并发启停互斥（MCP 路径有 `MCP_STATE_LOCK`，Web 路径仅靠 `SERVER_RUNNING` 原子布尔非抢先判定），两个线程同时 start 理论上可双 bind 双任务。现状调用方（Dart `_toggleWebService` 带 `_webServiceBusy` 门禁，`settings_screen.dart:82`）已挡住 UI 层并发，风险低；如后续出现其它调用方，建议补同款状态锁。

## 非声明（non_claims）

- 本审查未做 iOS 真机验证：`NSLocalNetworkUsageDescription` 弹窗行为、iOS 上 tokio bind 实际成功性，均属调研文档定义的设备侧取证范围，本报告只确认「键已正确加入 + 平台机制要求该键」。
- 「先红后绿」中改前红（bind_conflict 返回 Ok、非回环连接被拒）依据提交记录与机制推理，未在本机重放改前代码验证。
- 测试在 GitHub CI（ubuntu runner）的可移植性为机制分析（UDP 路由发现、0.0.0.0 语义、无 IPv4 降级路径），未实际在 CI 环境 repoduce。
- 覆盖强度：新增测试为「冒烟 + 单点回归」级别，非全部网络拓扑枚举。

## 处置决定

**convert_to_check**：W-1（停止后等待任务结束再返回）转 Active 计划检查项，修法已给（对齐 `mcp_stop_internal`）；O-1、O-2 随下次触碰该批文件时顺带处理；其余 chat_only。

---

## 附：本审查实测记录（本机 Windows，2026-10-06）

| 命令 | 结果 |
|---|---|
| `cargo test -p legado-ffi --test server_bind_conflict --test server_bind_all_interfaces --test server_start_requires_db --test server_shared_db` | 4 passed, 0 failed |
| `cargo test -p legado-server` | 182 + 4 + 9 passed, 0 failed |
| `flutter test test/widget/settings_test.dart` | 7 passed |
| python xml.dom.minidom parse Info.plist | PLIST_XML_OK |
| 探针：stop→立即同端口 start ×10 | **第 2 轮失败（os error 10048）** ← W-1 |
| 探针：stop→200ms→start ×10 | 10/10 过 |
| 探针：占端口→start Err→释放→立即重试 ×5 | 5/5 过（P0.2 重试成立） |
| grep webServiceUnsupported（lib+test） | 零残留 |
