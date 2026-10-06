# iOS 实机「Web 服务」开启不可用 —— 根因调研报告

- 日期：2026-10-06
- 调研方式：Windows 本机静态分析（只读），无 Mac/iPhone，未操作设备
- 报障现象（登记口径）：iOS 实机设置内开启 Web 服务不可用；App 内已加「iOS 暂不可用」门控（`settings_screen.dart:170-176`）
- 参考基线：`docs/S28_DUAL_DB_AUDIT_20261004.md` §二.8 / §五（server_start 前置守卫修复）

---

## 一、结论摘要

1. **调用链静态完整、iOS 构建包含 server**：Dart 开关 → FRB（funcId 218）→ `ffi_server_start` → `server_api::server_start` → `legado_server::server::start_server_with_db`，全链无任何 `cfg(target_os)`/feature 门控；iOS CI 用 `cargo rustc -p legado-ffi --lib --crate-type staticlib` 构建，`legado-server` 是 `legado-ffi` 的普通 path 依赖（`Cargo.toml:18`），必然编入静态库。**「server 被 cfg 掉」候选不成立（已证伪）**。
2. **S28 守卫在 iOS 无时序问题（静态反证）**：`db_open` 在 `main()` 阻塞门控中完成（`main.dart:43-62`），应用能进入设置页 ⇒ `db_state::is_initialized()` 必为 true ⇒ 守卫不可能报「数据库未初始化」。iOS 与 Android 走**同一条** db_open 路径（`rust_api.dart:390-396` 同为 Documents/legado.db），无 iOS 专属分支。**候选①仅在用户看到「数据库未初始化」SnackBar 文案时才成立**（见 §五判据）。
3. **静态确证缺陷 A —— Web 服务绑定 127.0.0.1（仅回环）**：`server_api.rs:129` 硬编码 `"127.0.0.1"`（MCP 独立服务为 `0.0.0.0`，`server_api.rs:271`；原版阅读 WebService 亦绑 0.0.0.0）。**任何平台**上局域网设备（PC 浏览器）都连不上 `http://<iPhone-IP>:1122`。这是「开了也没法用」的确定性缺陷，与 iOS 无关但在 iOS 实机上直接表现为「开启不可用」。
4. **静态确证缺陷 B —— bind/serve 失败被吞（错误不可见）**：`server_start` 在 spawn **前**返回 `Ok("Server started on port {port}")`（`server_api.rs:128-144`）；真正的 `TcpListener::bind` 在 spawn 后的异步任务里（`server.rs:70`），失败只 `eprintln!`（`server_api.rs:129-131`）。UI 无异常、无 SnackBar，开关显示开启，实际服务可能已死。对照：MCP 路径在 spawn 前 `block_on` 同步 bind、失败即 Err（`server_api.rs:270-272`）。这就是记忆线索③「错误信息未透出」的确证形态。
5. **静态确证缺口 C —— Info.plist 缺本地网络隐私键**：全 `flutter_legado/ios` 递归搜索 `NSLocalNetworkUsageDescription` / `NSBonjourServices`：**未找到**。现网 127.0.0.1 绑定下不触发；一旦按原版对齐改绑 0.0.0.0，iOS 14+ 本地网络隐私会把「局域网设备连入」置于权限门控下，缺键时**系统无法弹授权框、外部连接被静默拒绝**（平台已知行为，设备侧待验证）。
6. **tokio/kqueue 在 iOS 失败（候选②）无任何静态证据支持**：绑定回环端口不需要 entitlement；tokio 在 apple 目标用 kqueue，属常规支持面。该候选保留但降级，且有设备侧反证方法（§五）。

**根因判定**：无法（也不应）用静态分析单一定罪为单一 iOS 专属根因；静态可确证的是**缺陷 A+B 叠加**构成「开启不可用/开了也用不了」的完整解释链：bind 若失败 → 静默假成功（B）；bind 若成功 → 只监听回环、外部设备永远连不上（A）。二者均为全平台缺陷，iOS 实测只是首次暴露面。设备侧一轮取证（§五清单）可定案。

---

## 二、调用链证据（Dart → FFI → server）

| 步 | 位置 | 内容 |
|---|---|---|
| 1 | `flutter_legado/lib/src/screens/settings_screen.dart:82-113` | `_toggleWebService(true)` → `await api.startServer()`（:88）→ `getServerStatus()` → `setConfig('webService','true')`；catch 显示 SnackBar「Web 服务切换失败: $e」（:105-109） |
| 2 | `flutter_legado/lib/src/services/book_api.dart:1108` | 抽象 `startServer({int port = 1122})`（默认 1122，设置页调用**不传端口**） |
| 3 | `flutter_legado/lib/src/services/rust_api_media_format.part.dart:71-73` | `await bridge.serverStart(port: port)` |
| 4 | `flutter_legado/lib/src/bridge/ffi/ffi.dart:1748-1749` | FRB 生成：`RustLib.instance.api.crateFfiFfiServerStart(port: port)` |
| 5 | `flutter_legado/lib/src/bridge/frb_generated.dart:8155-8166` | `pdeCallFfi(... funcId: 218 ...)`；错误经 `decodeErrorData: sse_decode_bridge_error` 回传 Dart（异常会进 SnackBar） |
| 6 | `rust/legado-ffi/src/frb_generated.rs:7575-7607`（:7601） | wire 实现 → `crate::ffi::ffi::server_start(api_port)`，`transform_result_sse::<_, BridgeError>` 同步透传 Err |
| 7 | `rust/legado-ffi/src/ffi.rs:2244-2247` | `server_start(port) -> Result<String, BridgeError>` → `server_api::server_start(port)?` |
| 8 | `rust/legado-ffi/src/api/server_api.rs:106-145` | 前置守卫 + 全局池取连接 + **spawn 异步任务**，spawn 前返回 Ok |
| 9 | `rust/legado-server/src/server.rs:54-74`（:67-71） | `format!("{host}:{port}").parse()` → `TcpListener::bind(addr).await?` → `axum::serve`（**全在 spawn 后的异步任务内**） |

`server_start` 关键段（`server_api.rs:106-144`）：

- `:115-119` S28 守卫：`!db_state::is_initialized()` → 同步 `Err(Internal("Web 服务启动失败：数据库未初始化，请先调用 db_open"))`；
- `:123-124` `db_state::database_from_pool()` 失败 → 同步 Err；
- `:128-134` `runtime.spawn(async move { start_server_with_db("127.0.0.1", port, db) ... Err 仅 eprintln! })`；
- `:141-144` 置 `SERVER_RUNNING=true` 后返回 `Ok("Server started on port {port}")`。

生产实现注入确认：`providers.dart:15-18`（USE_MOCK 默认 false → `RustApi()`）；`main.dart:50-56` 真实 FFI 初始化。

---

## 三、「iOS 构建是否包含 server」核对（候选「被 cfg 掉」已证伪）

1. `rust/legado-ffi/Cargo.toml:6-18`：`crate-type = ["cdylib","staticlib","rlib"]`，`legado-server = { path = "../legado-server" }` 为**无条件依赖**；`[features]`（:48-52）仅 `quickjs` 透传，与 server 无关。
2. `rust/legado-server/Cargo.toml`：无 target 门控；源码内 `cfg(` 仅 `#[cfg(test)]`（grep 证实）。
3. `.github/workflows/ios-build.yml:64-78`（真机）/ `:80-93`（模拟器）：`cargo rustc --release --target aarch64-apple-ios -p legado-ffi --lib --crate-type staticlib --features quickjs` —— 整棵依赖树（含 legado-server）编入 `liblegado_ffi.a`，拷入 `flutter_legado/ios/RustFFI/`。
4. 符号可达性：`ios/RustFFI/RustFFI.podspec` 用 `-force_load` 全量载入 + `DEAD_CODE_STRIPPING=NO` + `STRIP_INSTALLED_PRODUCT=NO`；Dart 侧 iOS 用 `ExternalLibrary.process()`（`rust_api.dart:321-329`）查进程符号；CI 有 PDE 分发器符号 nm 校验（yml:113-127）。`frb_generated.rs:10501` funcId 218 → server_start 分发在库内。
5. 结论：**若包内缺 server_start 导出则候选 X** 的前提不成立——静态上符号必然在；设备侧仍可用一条命令复核（§五取证 #4）。

## 四、平台约束与错误可见性核对

### 4.1 db_open 时序（候选①反证）

- `main.dart:43-62`：`realApi.initialize()` 在 `runApp` 之前 await，失败则整 App 停在 `_FfiErrorApp`，**不可能进设置页**。
- `rust_api.dart:54-62`：`initialize()` 内 `bridge.dbOpen(path)`；`:390-396` `_defaultDbPath()`：Android/iOS 同为 `getApplicationDocumentsDirectory()/legado.db`，无 iOS 专属分支。
- `ffi.rs:171-203`：`db_open` → `record_db_path` + `init_database`（:179-181）→ 顺带 `restore_mcp_port`（:201）。
- `db_state.rs:91-93,104-109`：`is_initialized` / `database_from_pool`。
- **推论**：能操作开关 ⇒ 守卫必通过 ⇒ 「数据库未初始化」SnackBar 在现行代码下不可能出现；若用户见过该文案，说明装机版本不含 main 门控或 FFI 初始化曾以降级态放行（需取证定案）。

### 4.2 iOS 沙箱 / 本地网络 / 后台

- 回环监听（127.0.0.1）无需任何 entitlement——iOS 允许 App 绑定回环端口；此为平台常识性结论，设备侧可由取证 #2 一并验证。
- **本地网络隐私**：`flutter_legado/ios/Runner/Info.plist` 全文核对——有 `NSAppTransportSecurity(NSAllowsArbitraryLoadsInWebContent)`、`UIBackgroundModes=[audio]`、相机/图标/URL Scheme 等键；**没有** `NSLocalNetworkUsageDescription`、**没有** `NSBonjourServices`（全 `flutter_legado/ios` 递归 grep 未找到，`flutter_legado` 全目录亦未找到）。影响形态：改绑 0.0.0.0 后，局域网设备发起连接受 iOS 14+ TCC 门控，缺键=不弹窗+静默拒绝（平台已知行为，标注：设备行为待验证）。
- ATS 不约束本场景：ATS 管的是 App 自己的 URLSession/WKWebView 出站请求，Rust 裸 socket 监听与 PC 端浏览器均不受 ATS 管辖（Info.plist 注释块亦明示「App 侧真实网络走 Rust reqwest+rustls（裸 socket，不受 ATS 管辖）」）。
- 后台挂起：设置页前台操作开关，不涉及；服务长驻需前台/后台策略另行处理（非本次根因面）。

### 4.3 错误可见性

- 同步错误（守卫/取连接/runtime 构建）→ `BridgeError` → Dart 异常 → SnackBar 可见（`settings_screen.dart:105-109`；错误文案 S28 已加「数据库未初始化」，`server_api.rs:117`）。
- **异步错误（bind/serve）不可见**：`server_api.rs:129-131` 仅 `eprintln!`（iOS 上 stderr 进系统日志，Windows 侧无 Mac 难以捞取）；UI 侧 `startServer` 已 Ok 返回、`getServerStatus()` 立即查询存在竞态（可能短暂显示 `running on port 1122`），任务死后 `SERVER_RUNNING` 被置 false（`server_api.rs:133`）——重进设置页时 `initState` 重新拉状态（`settings_screen.dart:69-73`）会显示 `stopped`。用户观感即「开了但不可用/开关自己掉回去」。
- 对照组（同文件内正确写法）：MCP 独立服务在 spawn 前 `runtime.block_on(TcpListener::bind("0.0.0.0", port))`，失败同步 Err「独立 MCP 服务端口 {} 绑定失败」（`server_api.rs:270-272`）。

### 4.4 顺带发现的潜在缺陷（非 iOS 专属，登记不展开）

- `other_settings_screen.dart:693` `setServerPort` 持久化 `server_port`，但 Dart 侧 `startServer()` 固定默认 1122、Rust 侧无任何 `server_port` 读取者（双侧 grep 未找到读者）——用户自定义端口不生效。
- Web 服务绑定 127.0.0.1 意味着 Android 上同样「PC 连不上」，此前未暴露大概率因 Android 侧未实测跨设备访问。

---

## 五、根因判定与证伪判据（按可能性排序）

| 序 | 候选 | 状态 | 判据（设备侧一条动作） | 证伪方法 |
|---|---|---|---|---|
| 1 | **Web 绑定 127.0.0.1 → 局域网设备永远连不上**（缺陷 A） | 静态确证（`server_api.rs:129`） | iPhone 本机 Safari 打开 `http://127.0.0.1:1122/`（或 `/get_books`）：能打开=服务在跑、仅外部不可达 | 本机 Safari 也打不开 → 排除本候选，看 2/3 |
| 2 | **bind/serve 异步失败被吞**（缺陷 B，含 tokio-on-iOS 异常情形） | 机制静态确证；具体失败原因需取证 | 开关开启后等 10 秒，杀 App 重进设置页：状态副题变 `stopped` = spawn 后任务已死 | 状态持续 `running on port 1122` 且候选 1 成立 → 本候选排除 |
| 3 | S28 守卫 db_open 时序误报（记忆线索①） | 静态反证（§4.1） | SnackBar 文案逐字是「…数据库未初始化，请先调用 db_open」才成立 | 文案不是该句 → 排除 |
| 4 | tokio/kqueue 在 iOS 沙箱整体不可用（记忆线索②） | 无静态证据 | 开「独立 MCP 服务」（配置 jsSourceApiToken 后切开关）：MCP 能 running → tokio 监听本身没问题 | MCP 同样起不来 → 升级为主要候选 |
| 5 | 本地网络隐私拦截（Info.plist 缺键） | 缺键静态确证；拦截行为待设备验证 | 仅在改绑 0.0.0.0 后相关：PC 连接时 iPhone 是否弹「本地网络」授权、设置>隐私>本地网络里 App 是否被拒 | 弹窗且允许后可连 → 排除 |
| 6 | iOS 包内缺 server_start 符号 | 静态证伪（§三） | 如需复核：`.a`/Runner 上 `nm -g \| grep -c server_start`（有 Mac 时） | CI nm 校验 PDE 符号已过 → 基本排除 |

## 六、最小修复方案（本轮不实施，交主代理裁决）

静态确证的缺陷 A、B 均可零 FFI 契约修复（`ffi_server_start(port)` 签名不动，S28 §5.3 同款约束）：

1. **修缺陷 B（同步 bind，~15 行）**：`rust/legado-ffi/src/api/server_api.rs` 的 `server_start` 仿照 `mcp_start_internal`（:270-272）在 spawn 前 `runtime.block_on(TcpListener::bind(...))`，失败即 `Err(Internal("Web 服务端口 {port} 绑定失败: {e}"))` 不置 RUNNING；`rust/legado-server/src/server.rs` 照 `serve_mcp`（:134-153）加一个收 listener 的 `serve_web(listener, db)` 变体，`start_server`/`start_server_with_db` 原样保留给独立二进制/测试。
2. **修缺陷 A（绑定 0.0.0.0，~1 行 + plist）**：bind 地址改 `"0.0.0.0"`（对齐原版 WebService 与本项目 MCP F5 语义，`server_api.rs:197-198` 注释即此口径）；同步在 `flutter_legado/ios/Runner/Info.plist` 增补 `NSLocalNetworkUsageDescription`（文案说明「与电脑互传书源/书籍」）；`NSBonjourServices` 仅在后续做 Bonjour 广播时才需要，本期可不加。
3. **本地可验证程度（Windows）**：
   - `cargo test -p legado-ffi --test server_start_requires_db`、`--test server_shared_db`（既有回归，保证守卫与回环全链不破）；
   - 新增 bind 冲突测试（先占端口再 `server_start`，断言 Err 且消息含「绑定失败」、`server_status()=="running:false"`）——Windows 可跑，覆盖缺陷 B；
   - `flutter analyze` / 既有 widget 测试不受影响（UI 无改动）。
4. **CI**：`ios-build.yml` 构建步骤无需变更（依赖树不变、plist 由 flutter build 校验）；修复后可移除 `settings_screen.dart:175-176` 门控并回归「iOS 暂不可用」文案。
5. **设备侧验证指令（用户有 iPhone，1-2 条）**：
   - 装修复包后：设置页开 Web 服务 → iPhone Safari 打开 `http://127.0.0.1:1122/` 应出现服务页；再从同 Wi-Fi PC 执行 `curl -m 5 http://<iPhone的IP>:1122/get_books`，首次应触发 iOS「本地网络」授权弹窗，允许后返回书架 JSON；
   - 若仍失败：把开关开后重进设置页的状态副题文本（`running on port 1122` / `stopped`）与 SnackBar 全文抄回，即可按 §五表定案。

### 下次 iOS 实测取证清单（若先取证再修）

1. 开关开启瞬间是否弹 SnackBar，逐字记录文案（区分候选 3 与 2）；
2. 开关开启后等 10 秒 → 杀 App → 重进设置页，记录状态副题（`running on port 1122` / `stopped`）（区分候选 2）；
3. iPhone 本机 Safari 访问 `http://127.0.0.1:1122/`（区分候选 1/2：能开=在跑，打不开=任务已死）；
4. （可选，有 Mac 时）`xcrun devicectl device info` 或 Console.app 过滤 Runner 进程 stderr，找 `Server error: ...` 行——即被吞的 bind/serve 原始错误；
5. PC 同网段 `curl http://<iPhone-IP>:1122/get_books` 记录现象（预期失败，佐证候选 1）。

## 七、未找到 / 未实测事项

- `NSLocalNetworkUsageDescription` / `NSBonjourServices`：未找到（搜过 `flutter_legado/ios` 递归与 `flutter_legado` 全目录）。
- `server_port` 配置的任何读者（Rust/Dart 侧）：未找到（搜过 `rust/legado-ffi/src`、`rust/legado-server/src`、`flutter_legado/lib`）。
- 把 server 在 iOS cfg 掉的 feature/cfg/脚本：未找到（搜过两个 Cargo.toml、`rust/scripts/*.ps1|.sh`、`ios-build.yml`、legado-server 全源码 `cfg(`）。
- iOS 专属 db_open 分支：未找到（`rust_api.dart`、`ffi.rs`、`bridge.rs` 无 `target_os=ios` 差异路径）。
- tokio 在 iOS 实机的运行时行为、TCC 弹窗实际形态：未实测（无设备），均已标注待验证。
- iOS 真机结论口径：本报告全部为静态证据 + 本地可验证项，未宣称「iOS 真机已通过」。
