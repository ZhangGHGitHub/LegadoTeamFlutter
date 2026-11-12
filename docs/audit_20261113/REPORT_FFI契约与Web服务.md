# FFI 契约与 Web 服务审查报告（2026-11-13）

> 审查基线：HEAD `7c15e82252`（版本 2.0.491+492）
> 审查范围：`rust/legado-ffi`、`rust/legado-server`、`flutter_legado/lib/src/services/rust_api*`、`flutter_legado/lib/src/services/book_api.dart`、`flutter_legado/lib/src/services/mock_book_api*`、`docs/API_CONTRACT.md`
> 性质：只读审查。未修改任何业务代码，未运行 `cargo build/test`、`flutter test` 等构建/测试命令；全部结论来自源码、文档与 git 只读检索。
> 环境提示：审查期间（2026-11-13 01:16 左右）工作区出现并发修改（`flutter_legado/lib/src/screens/bookmark_screen.dart`、`flutter_legado/lib/src/screens/settings_screen.dart`、`flutter_legado/lib/src/widgets/navigation/my_pane_scope.dart`）；本报告未修改也未依赖这些文件，结论基于 HEAD `7c15e82252` 的已跟踪内容。
> 对照：本仓 `app/`（双轨原版）、`D:\OH-WorkSpace\LegadoTeam\legado-upstream`、`D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`

---

## 结论摘要

**计数闭合（均为程序化提取，非人工统计）**

| 口径 | 实测 | 文档声明 | 结论 |
|---|---|---|---|
| §2.x 方法行合计（附录 50 行之和） | 340 | 340 | 一致 |
| 方法章节数 / 每节声明数 == 实际行数 | 50 节，0 处不符 | — | 一致 |
| `BookApi` 抽象方法数（`book_api.dart`） | 338 | 338（`API_CONTRACT.md:436`） | 一致 |
| `MockBookApi` 公共方法数 | 338（另有 18 个 `_` 私有辅助） | 338 | 一致 |
| §1.7 表 A / 表 B / 等价对总数 | 16 / 174 / 190 | 16 / 174 / 190 | 一致 |
| `ffi.rs` `pub fn` 导出面 | 328 unique（329 条声明，`js_eval` 为 quickjs/non-quickjs 两 cfg 变体）；其中 16 个 `pub async fn` | 未在测试中计数 | 人工闭合，见附录 A |
| `BookApi` / `MockBookApi` / `RustApi` 公共额外方法 | 0 / 0 / 2（`toString`、`refreshReadBookConfig`） | 测试钉死同值 | 一致 |

> 任务书给出的计数基线「附录 340 / BookApi 337 / 表 B 173 / 等价 189 / 模块 50」是**批20 之前**的快照。批20（2026-11-12）加法式新增 `evalImageAction` 后，文档已同步为 340 / 338 / 174 / 190 / 50（`docs/API_CONTRACT.md:12`、`:436`）；批21 只扩展了返回值信封、未改签名与方法数，故**没有新增漂移**。

**发现计数：P0 × 1、P1 × 3、P2 × 2、P3 × 4、待核实 × 3。**

最严重的三条：

1. **P0-1**：自研 REST 端点 `/api/webbook/*`（4 条）把请求体中的完整 `BookSource` 直接交给 `legado-fetcher`，`mainJs`/`@js:` 规则在 QuickJS 中真实执行，且**不在** `PROTECTED_SOURCE_WRITE_ROUTES` 或任何鉴权层内。Web 服务绑 `0.0.0.0`（LAN 可达）时，同网段攻击者无需令牌即可执行任意 JS（可发起网络请求/SSRF），等于绕过批17 给 `/mcp/call` 加的令牌守卫。
2. **P1-1**：自研 REST 的 `/api/sources`（POST/PUT/DELETE）与 `/api/sources/update` 完全绕过原版源写令牌面。`POST /api/sources` 对已存在 URL 走 `INSERT OR REPLACE` 全列覆盖，**会用默认实体清空该书源的全部规则/jsLib/variable**；`/api/sources/update` 可让设备请求任意 `repo_url` 并整批导入源（SSRF + 源注入）。
3. **P1-2**：原版属于 `PROTECTED_HTTP_LOG_READ_ROUTES` 的 `GET /getBookSourcesForManagement` 与 `GET /getBookSourceCheckStates` 在 Rust legacy 实现中**没有令牌校验**，同 LAN 可读全量书源（含 `variable` 登录态）与检验会话 token；且两条响应缺少原版的 `Cache-Control: no-store`。

---

## 一、正向核验（未回潮/未断裂项）

### 1.1 FFI 三方闭合与死接线

- **BookApi ↔ RustApi ↔ MockBookApi**：`BookApi` 338 个方法全部在 `RustApi`、`MockBookApi` 有实现；`RustApi` 公共额外方法恰为 `{toString, refreshReadBookConfig}`，`MockBookApi` 无公共额外方法。与 `flutter_legado/test/unit/api_contract_test.dart:231-271` 的钉死值一致。
- **§2.x 行 ↔ BookApi**：340 行中仅 2 行不是 `BookApi` 同名方法：`rssUpdateSource`（由 `updateRssSource` 封装，`rust_api_search_rss.part.dart:246-247`）与 `chapterPayAction`（纯 FFI，未封装），与附录口径（`API_CONTRACT.md:437`、`:1949`）一致。
- **Rust 导出面**：328 个 unique 导出全部能在 `flutter_legado/lib/src/bridge/ffi/ffi.dart` 找到生成的 Dart wrapper；`rust_api*.dart` 中 320 个 `bridge.<fn>` 调用全部能在 wrapper 表中找到，**没有「Dart 调用但 Rust 已删」**。
- **死接线**：业务代码（`lib/` 去掉 `bridge/`）中从未调用的 wrapper 仅 3 个，且均为契约 §1.6.1 已登记的预留项：`sourceLoginV1`、`verificationPending`、`webviewPending`。`verificationPending`/`webviewPending` 仅测试消费，与登记一致。
- **批20/21 新符号消费面**：
  - `evalImageAction`：`reader_image_dominant_body.dart:270`、`reader_page_view.dart:1643` 真实调用；Mock/测试齐备。
  - `replace_rule_reorder`：`ffi.rs:1980` → `rust_api_reader_data.part.dart:206` → `replace_rule_notifier.dart:165`，真实落库路径。
  - `invalidate_image_action_engine`：非 FFI 导出，是 `legado-js` 内部函数；FFI 源写路径 `source.rs:76`（新增）、`:95`（更新）、`:106`（删除）、`:159`（导入）均调用，另有 `replace_rule_js.rs:465` 锁中毒兜底。真实消费成立（Web 源写路径的差异见 P3-3）。

### 1.2 契约语义

- **§2.21 信封**：Rust `image_action_envelope` 仅在 `actions` 非空时输出 `{"_lgActions":true,"result":...,"actions":[...]}`（`rust/legado-ffi/src/api/image_action_api.rs:73-85`）；Dart `ImageActionOutcome.parse` 只在 `_lgActions == true`、`result` 为 String、`actions` 为非空 List 时拆包，否则按纯字符串处理（`flutter_legado/lib/src/services/image_action_outcome.dart:56-88`）。与契约 `API_CONTRACT.md:981` 一致。动作抛错/超时降级为空串、无 quickjs 明确报错、无书源时 `source={}` 均与契约一致。
- **§2.8 替换规则作用域/配置面**：Web `purify_content` 已读取与 App 相同的持久化配置（`sameTitleRemoved`/`chineseConverterType`/`reSegment`/`replaceEnableDefault`），正文 `scope` 统一走 `legado_core::content_processor::book_scope_matches`（`rust/legado-server/src/legacy/book_api.rs:629-675`、`rust/legado-ffi/src/api/reader.rs:1663-1670`）；`excludeScope` 只在标题路径参与（`content_processor.rs:602-626`）；契约登记的「Web 仍传 `ScopeContext`、App 不传」差异仍成立（`book_api.rs:766` vs `reader.rs:1689-1690`），`remove_duplicate_title` 确实使用 `scope_context.book_name`（`content_processor.rs:290-300`）。批20-B 的登记**未回潮**。
- **§2.21 缓存语义**：LRU 上限 4（`replace_rule_js.rs:132`），按 `bookSourceUrl` 键、`jsLib` 字符串签名校验（`:212-232`），降级引擎不入缓存（`:233-241`），无源 URL 不缓存（`:218-223`）。与契约一致。

### 1.3 Web 路由与批次交付面

- `legacy_routes()` 注册 40 条原版路径（`rust/legado-server/src/legacy/mod.rs:212-307`），B3/B4/B5/B6/B11 交付项均在：`/saveBook`、`/deleteBook`、`/addLocalBook`、管理读 7 条、段评 6 条、B6 源写 10 条、批30 检验 4 条、`/refreshToc`。
- 自研 `/api` 注册 68 条（`routes.rs:37-196`），与 2026-10-07 调研记录的 68 条一致；`/mcp/tools`、`/mcp/call` 同时挂在主路由器与独立 MCP 路由器。
- B5 原版 WS 在 `port+1` 独立监听注册 `/bookSourceDebug`、`/rssSourceDebug`（`ws/original.rs:354-366`），子协议令牌校验仍完整（`ws/original.rs:254-310`）。
- `PROTECTED_SOURCE_WRITE_ROUTES` 长度 13（`source_write_api.rs:164-178`），`/mcp/call` 在内；主路由器在 `serve_web_with_injected_paths` 统一套 `attach_source_write_token_guard`（`server.rs:125`、`:189-195`），请求路径精确匹配、令牌常量时间比较（`server.rs:267-284`）。

### 1.4 P0-1（2026-10-26 审查）修复未回潮

- Web 书源仓库更新链仍走 serde 主链 + `BookSourceRepository::insert_batch_with_check_state`，**不再引用 RoomImporter**：`rust/legado-server/src/handlers/source_update.rs:279-287`；`rg RoomImporter rust/legado-server/src` 零命中。FFI 导入链同样走 `insert_batch_with_check_state`（`rust/legado-ffi/src/api/source.rs:151-160`）。

### 1.5 FRB 生成物与三 ABI `.so`

- content hash 三处一致：`frb_generated.rs:40` = `-905874848`；`frb_generated.dart:68` = `-905874848`；三个 `liblegado_ffi.so.meta` 的 `contentHash` 均为 `-905874848`。
- FRB 版本：`pubspec.yaml:15` = `2.11.1`，`pubspec.lock` = `2.11.1`，生成文件头 `@generated by flutter_rust_bridge@ 2.11.1` 一致。
- 本地 `.so` 构建时间：arm64-v8a `2026-11-12 20:32:58`、armeabi-v7a `2026-11-12 20:33:41`、x86_64 `2026-11-12 20:34:29`；均晚于最后一条 Rust 代码提交 `54eb20e2f9`（`2026-11-12 20:15:39`）。`.so.meta` 记录 `mode=release`，`quickjs` 分别为 true / **false（v7a）** / true，与 `build-android.ps1:23-25` 的 v7a 预跳过策略一致。三 ABI 均非批19 之前旧物。
- 注：`flutter_legado/android/app/src/main/jniLibs/` 被 `.gitignore:37` 忽略，上述为本地构建产物证据；无法仅凭仓库证明发布 APK 内嵌同一文件，见「待核实 3」。

---

## 二、发现清单

> 证据口径说明：P0-1、P1-1、P1-2、P1-3、P2-1、P3-4 给出我方 + 原版/参考版双侧证据；P2-2、P3-1、P3-2、P3-3 属于我方契约/测试基建项，原版/参考版无对应实现或门禁（不适用），已在各条注明。

### P0-1 自研 `/api/webbook/*` 未鉴权执行请求体中的任意书源 JS（令牌面绕过）

**分级：P0（安全 / 远程代码执行面）**

**我方证据**

- 路由注册：`rust/legado-server/src/routes.rs:84-87` 注册 `POST /api/webbook/search|info|chapters|content`，均挂 `handlers::web_book::{search_books,get_book_info,get_chapters,get_content}`。
- 请求体直接携带完整 `BookSource`：`rust/legado-server/src/handlers/web_book.rs:69-72`、`:80-83`、`:89-92`、`:98-101`（`pub source: BookSource`）。
- handler 把请求体源序列化后交给自由入口：`handlers/web_book.rs:382-387`（search）、`:413-417`（info）、`:432-436`（chapters）、`:460-464`（content）。
- 自由入口无「源必须已入库/已启用/已校验」门槛：`rust/legado-fetcher/src/web_book.rs:4622-4644` 反序列化 `source_json` 后，`build_js_orchestrator(&source)`（`:4634`）直接执行 `mainJs`；`build_js_orchestrator` 见 `web_book.rs:4591-4610`（`main_js` 非空即 `JsSourceEngine::new_quickjs`）。
- 令牌面未覆盖：`PROTECTED_SOURCE_WRITE_ROUTES` 仅 13 条（`legacy/source_write_api.rs:164-178`），`source_write_token_guard` 对非名单路径直接放行（`:195-205`）；主路由器唯一鉴权层就是它（`server.rs:125`、`:189-195`），`create_router` 无全局中间件（`routes.rs:20-36`）。
- LAN 可达：FFI `server_start` 在 spawn 前同步 bind `0.0.0.0`（`rust/legado-ffi/src/api/server_api.rs:239-244`）。
- 项目自身的安全口径：批17 把 Web 端 `/mcp/call` 纳入令牌面，理由正是「可执行任意 JS」——`docs/API_CONTRACT.md:11`；`source_write_api.rs:169-172` 同款注释。
- 已知面区分：`docs/WEB_SERVICE_REACHABILITY_CODE_REVIEW_20261006.md:57` 已记录「`create_router` 无鉴权、`/api/*` 全开放」并判定与原版一致；当时 `/api` 尚无「请求体自带 source 执行规则」的证据。本条是新升级面：`/api/webbook/*` 的任意 JS 执行能力超出原版 Web 端点能力集。

**原版/参考版证据**

- 原版对 JS/源写入面要求令牌：`app/src/main/java/io/legado/app/web/HttpServer.kt:60-68`（`saveJsSource` 独立校验链）、`:251-265`（`PROTECTED_SOURCE_WRITE_ROUTES` 13 条）。原版没有任何「请求体自带 source 并执行规则」的 HTTP 端点；正文/搜索链路使用 DB 内已保存的书源。

**影响**

- Web 服务开启且同 LAN 可达时，攻击者无需 `x-legado-token`，即可向 `/api/webbook/search` POST 一个带 `mainJs` 的 `BookSource`，在设备进程内执行任意 JS。QuickJS 沙箱虽默认 `allow_file_access=false`（`rust/legado-js/src/sandbox.rs:15`、`:261`），但 `java.ajax`/`java.getCookie`/`java.*` 宿主 API 仍可发起网络请求（SSRF 到内网/MCP/本机服务）、读写源作用域变量；在 arm64/x86_64（quickjs=true）上成立，v7a 降级为 stub。
- 这是对 `/mcp/call` 令牌守卫的等价绕过：同样的「任意 JS 执行」能力换了一个未保护的路径。
- 跨站面：服务端 OPTIONS 预检放行 `GET, POST` + `content-type, x-legado-token`（`rust/legado-server/src/web_assets.rs:173-188`），并按请求 Origin 回显 `Access-Control-Allow-Origin`（`web_assets.rs:96-106`），因此恶意网页可尝试跨站 POST 该端点（是否被浏览器 Private Network Access 拦截取决于浏览器版本/网络环境）。

**修复方向**

- 将 `/api/webbook/*` 纳入与 `/mcp/call` 相同的令牌前置守卫（或对所有 `/api` 中「执行源规则/写入源」的端点建立统一鉴权层）；若该组端点仅为本地调试设计，应默认只绑回环或显式关闭，不能随主 Web 服务暴露到 `0.0.0.0`。
- 补一条路由级测试：未带 `x-legado-token` 的 `/api/webbook/search` 必须 401/令牌失败信封，且不读取 body。

---

### P1-1 自研 `/api/sources` 与 `/api/sources/update` 绕过源写令牌面：可静默清空书源规则/注入源/SSRF

**分级：P1（安全 + 静默数据丢失；若 Web UI 或第三方客户端使用该面，应按 P0 处理）**

**我方证据**

- 路由注册：`routes.rs:59-66`（`POST /api/sources`、`PUT/DELETE /api/sources/{id}`）、`:78-80`（`POST /api/sources/update`）。
- `POST /api/sources` 用请求体局部字段构造 `BookSource { ..Default::default() }`，随后 `insert_with_check_state`：`handlers/source.rs:79-101`。
- `insert_with_check_state` 走 `Repository::insert`，SQL 为 **INSERT OR REPLACE 全列**：`legado-db/src/repository/book_source_repository.rs:255-265`、`:363-373`。对已存在 `bookSourceUrl` 的请求会用默认实体覆盖整行 → 规则 `ruleExplore/ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleReview`、`jsLib`、`variable`、`header` 等全部清空。
- `PUT /api/sources/{id}` 存在同类路径：先按 path 查行，未命中则 `unwrap_or_default()`，再以 body 的 `book_source_url` 调用 `update_with_check_state`（`handlers/source.rs:136-164`）；body URL 命中另一行时同样可整行覆盖。
- `DELETE /api/sources/{id}` 直接 `repo.delete`（`handlers/source.rs:176-183`）。
- `/api/sources/update` 接受任意 `repo_url` 并整批导入：`handlers/source_update.rs:202-218`（`reqwest.get(&req.repo_url)`）、`:279-287`（`insert_batch_with_check_state`）；`UpdateRequest.repo_url` 无白名单/协议/内网校验（`:86-91`），且客户端 `danger_accept_invalid_certs(true)`（`:206-210`）。
- 令牌面未覆盖：唯一守卫只认 13 条 legacy 路径（`source_write_api.rs:164-178`、`:195-205`），`/api/*` 全部放行；`create_router` 无全局鉴权（`routes.rs:20-36`）。
- 追加注入面：`POST /api/sources` 可设置 `search_url`；`RealBookSourceFetcher::search` 会对 `searchUrl` 做 `{{JS}}`/`@js:` 模板求值（`rust/legado-fetcher/src/web_book.rs:1714-1727`）。攻击者可先写入 `enabled=true` 的源，等用户搜索时执行 JS（持久化注入）。
- 同组旁路：`POST /api/sources/check|check-batch` 接受任意 `BookSource` 并发起网络请求（`handlers/source_check.rs:52-120`），构成无鉴权 SSRF 面（不落库，风险低于 update）。

**原版/参考版证据**

- 原版对书源写入强制令牌：`app/src/main/java/io/legado/app/web/HttpServer.kt:251-265` 中 `/saveBookSource`、`/saveBookSources`、`/deleteBookSources` 均在 `PROTECTED_SOURCE_WRITE_ROUTES`，`:65-68` 统一校验 `hasValidJsSourceApiToken`。原版没有 `PUT/DELETE /api/sources` 或「按 repo_url 整批导入」的无鉴权等价面。

**影响**

- 同 LAN 攻击者可在用户不知情时覆盖/清空书源（静默数据丢失，用户下次搜索/阅读才暴露），或导入任意远程源（含 JS 规则）达成持久化 JS 执行；`repo_url` 还可作为 SSRF 探针。
- 这条与 P0-1 同根：自研 `/api` 写/执行面没有继承原版源写令牌模型。

**修复方向**

- 把 `/api/sources` 的 POST/PUT/DELETE、`/api/sources/update`（以及 `/api/webbook/*`）统一纳入令牌守卫；或在路由层加一个「写/执行类 `/api` 前缀」鉴权中间件。
- `POST /api/sources` 改为「已存在 URL 时报冲突」或先读旧行做字段级 mutate，禁止 `default + INSERT OR REPLACE` 整行覆盖；`/api/sources/update` 的 `repo_url` 增加协议/内网地址/重定向校验，并去掉无条件的 `danger_accept_invalid_certs(true)`（或仅在显式设置下启用）。

---

### P1-2 `GET /getBookSourcesForManagement` / `GET /getBookSourceCheckStates` 缺失令牌校验（原版受保护读面）

**分级：P1（安全 / 敏感读暴露）**

**我方证据**

- `GET /getBookSourcesForManagement` 只取 `headers` 用于回显 Origin，**没有任何 `has_valid_token`/`token_rejection`**：`rust/legado-server/src/legacy/source_check_api.rs:376-380`；返回完整 `Vec<BookSource>` + 状态（`:421-433`）。
- `GET /getBookSourceCheckStates` 同样只取 Origin，并返回 `sessionToken`：`source_check_api.rs:481-487`。
- `BookSource` 的 `variable` 字段为普通 String 并随 JSON 序列化（`rust/legado-core/src/models/book_source.rs:117`），登录态/脚本变量可能在其中。
- 模块文档与契约把这个差异写成了「无令牌」：`source_check_api.rs:7-8`、`legacy/mod.rs:95-96`、`docs/API_CONTRACT.md:1805-1806`；`source_api.rs:22-25` 还错误概括为「受保护 GET 面仅 getHttpLog(s)」。
- `Cache-Control: no-store` 白名单同样漏了两条：`rust/legado-server/src/web_assets.rs:126-133` 仅 `getHttpLogs/getHttpLog/getJsSourceApiTokenRequired`。

**原版/参考版证据**

- 原版把这两条 GET 放进 `PROTECTED_HTTP_LOG_READ_ROUTES` 并在 GET 分支统一校验令牌：`app/src/main/java/io/legado/app/web/HttpServer.kt:266-271`（集合含 `getBookSourceCheckStates`、`getBookSourcesForManagement`）、`:125-128`（校验分支）。
- 原版对同一集合追加 `Cache-Control: no-store`：`HttpServer.kt:278-282`。

**影响**

- 同 LAN 未鉴权客户端可拉取全量书源（含 `variable` 登录态）与检验状态/会话 token；原版的令牌面在这里被绕过。`no-store` 缺失还会让中间缓存保留敏感响应。

**修复方向**

- 两条 handler 增加与 `get_http_logs` 同款的 `load_js_source_api_config(...).has_valid_token(&headers)` 前置；或把「受保护读」路由也纳入路由级前置中间件（参考 `PROTECTED_HTTP_LOG_READ_ROUTES` 建常量）。
- `with_api_headers` 的 no-store 列表补两条；同步修正 `source_check_api.rs`、`legacy/mod.rs`、`API_CONTRACT.md` §4.1 的令牌列与 `source_api.rs:22-25` 的注释。
- 嵌入式 vue 前端对 `getBookSourcesForManagement` 仍会带 token（`source_check_api.rs:7` 注释），`getBookSourceCheckStates` 需按原版前端 `SourceCheckControls` 的请求头再核对；从原版实现看两条都在受保护集合内，前端应同链携带。

---

### P1-3 `ruleSubApplyUpdate` / `/api/rule-update/apply` 只回写版本号，未应用任何规则（UI 显示成功计数）

**分级：P1（用户可见功能缺陷 / 静默失败）**

**我方证据**

- FFI 实现 `apply_sub_update_db` 拉取远程后调用 `merge_subscription("[]", ...)`，只使用 `mr.added/updated/removed` 与 `mr.merged_json` 的长度，随后仅 `repo.update_version(...)`；**没有**任何 `book_sources/replace_rules/rss_sources` 的 insert/update：`rust/legado-ffi/src/api/rule_sub_api.rs:191-250`（关键行 `:221` 合并、`:226` 仅更新版本）。
- Web 同源实现同样只 `update_version`：`rust/legado-server/src/handlers/rule_update.rs:202-216`（`:202` 合并、`:216` 仅版本）。
- UI 明确暴露「应用更新」并展示「更新完成：新增 N、更新 N、移除 N」：`flutter_legado/lib/src/screens/rule_sub_screen.dart:203`（菜单）、`:251-281`（处理与成功提示）；入口链路 `rss_source_manage_screen.dart:314-321`、`routes.dart:114/239`。
- 现有单测只覆盖「未找到/不可达」两条失败分支，没有断言落库：`rust/legado-ffi/src/api/rule_sub_api.rs:359-392`。

**原版/参考版证据**

- 原版 `RuleUpdate.cacheSource` 在拉取后按 `sub_type` 真正写库：书源 `SourceHelp.insertBookSource`（`legado-upstream/app/src/main/java/io/legado/app/model/RuleUpdate.kt:26-117`，关键 `:60`）、RSS 源 `SourceHelp.insertRssSource`（`:79`）、替换规则 `appDb.replaceRuleDao.insert`（`:88-113`）。非 silent 模式先缓存再供用户确认后应用，最终仍会落库。

**影响**

- 用户点「应用更新」后看到成功与新增数量，但实际上书架/替换规则/RSS 源没有任何变化；且因合并时本地固定传 `[]`，`itemsAdded` 恒等于远程条数、`itemsUpdated` 恒 0，UI 的计数与真实库状态无关。订阅版本号被推进后，下次检查还会显示「已是最新」，形成**静默功能失效**。这是规则订阅页（用户可达）的主操作之一。

**修复方向**

- 按 `sub_type` 将 `mr.merged_json` 反序列化为 `BookSource`/`ReplaceRule`/`RssSource`，走既有单实现（`BookSourceRepository::insert_batch_with_check_state` / `ReplaceRuleRepository` / `RssSourceRepository`）在单事务内落库，再写版本号；或若产品决定不做实际应用，则移除「应用更新」菜单与成功计数文案，并在契约 §2.39 明示「仅检查/仅版本」。
- 补往返测试：本地空库 + 远程 2 条 → apply 后 DB 真有 2 行、`version` 更新、失败时零写入。

---

### P2-1 段评两条写端点未纳入路由级令牌中间件（与上游 13 条集合不一致）

**分级：P2（边界缺陷 / 防御纵深）**

**我方证据**

- `PROTECTED_SOURCE_WRITE_ROUTES` 13 条不含 `/openLegacyReview`、`/runLegacyReview`：`rust/legado-server/src/legacy/source_write_api.rs:164-178`；测试还显式断言 `!is_protected_source_write_route("/openLegacyReview")`（`:1336`）。
- 两条 handler 内部有令牌检查：`rust/legado-server/src/legacy/review_api.rs:1130-1140`、`:1212-1222`；但请求体由 `body: String` 提取器在读 handler 前已缓冲，未做到 P2-2 的「未授权不读 body」。
- 上游集合包含这两条：`app/src/main/java/io/legado/app/web/HttpServer.kt:251-265`。

**影响**

- 未授权请求可让服务端读取最多 axum 默认 2MB body；安全语义仍由 handler 兜底，但与本项目批10 P2-2 的统一前置目标不一致，且 13 条名单与上游 13 条并非同一集合（我们以 `/saveJsSource`、`/mcp/call` 替换了 review 两条）。

**修复方向**

- 把 review 两条加入 `PROTECTED_SOURCE_WRITE_ROUTES`（并补测试），保留 handler 内校验作纵深防御；或在 review 路由上单独挂 `source_write_token_guard`。

---

### P2-2 契约门禁缺少「Rust FFI 导出面」这第三边，三方闭合只能靠人工

**分级：P2（测试不变量缺口）**

**原版/参考版证据**：不适用（我方 CI 契约门禁，原版无对应物）。

**我方证据**

- `flutter_legado/test/unit/api_contract_test.dart:4-10` 声明的 6 项校验覆盖：BookApi ⊆ RustApi/Mock、额外方法钉死、每方法在契约登记、§2.x 声明数、附录双射、BookApi 总数。**没有任何一项读取 `rust/legado-ffi/src/ffi.rs` 的 `pub fn` 面**。
- 因此 `Rust pub fn` 与 `BookApi`/契约之间的漂移（例如新增导出但忘记 codegen/封装，或删除导出但测试仍绿）不会被 `flutter test` 的契约门禁发现；构建期也只有 FRB content hash 校验（`flutter_legado/android/app/build.gradle.kts:115-155`），它只比对生成物与 `.so`，**不覆盖「新增导出但未 codegen」**（新 `pub fn` 不进 `frb_generated.rs` 也能编译通过，hash 不变）。

**影响**

- 本次人工核对 328 unique 导出全部有 wrapper、全部有契约归属；但该结论没有可重复的 CI 门禁，后续批次的 FFI 面扩张仍可能静默漂移。

**修复方向**

- 在 `api_contract_test.dart` 增加第 7 项：解析 `ffi.rs`（含 `pub mod ffi` 内的 `pub fn`/`pub async fn`）与 `bridge/ffi/ffi.dart` 的 wrapper 集合，做双向差集；允许名单仅保留 §1.6/§1.6.1/§1.7 已登记项（含 3 个预留）。

---

### P3-1 §2.21 模块注释/契约日志级别漂移

**原版/参考版证据**：不适用（我方契约文本/代码注释）。

**我方证据**

- `rust/legado-ffi/src/api/image_action_api.rs:47-50` 的模块注释写「有 action 时返回 `{"result":"...","actions":[...]}`」，**缺少 `_lgActions` 判别标记**；同文件 `:68-80` 的函数注释与代码 `image_action_envelope`（`:73-85`）才带 `_lgActions`。
- 模块注释 `:13` 与契约 `docs/API_CONTRACT.md:981` 写「`log::debug!`」；实际失败/空动作走 `log::warn!`（`image_action_api.rs:121`、`:129`、`:204`）。
- `image_action_api.rs:45` 又写「记 warn 日志」，与 `:13` 自相矛盾。

**影响**：纯文档/注释漂移，不影响运行；但会让后续审计误判信封格式与日志等级。

**修复方向**：统一为契约口径（含 `_lgActions`、实际日志级别），并在 §2.21 注中明确「动作空串/失败 warn」。

---

### P3-2 §1.6/§1.6.1 非 Result 导出表不完整

**原版/参考版证据**：不适用（我方契约文本/实现登记）。

**我方证据**

- §1.6 声明「以下 9 个 `ffi.rs` 导出刻意不包 Result」，并写「其余新增 FFI 仍遵循 Result 铁律」（`docs/API_CONTRACT.md:178-194`）。
- 实际另有 5 个非 Result 导出未登记：
  - `set_cache_dir`（void 注入，`ffi.rs:142`；§1.6.1 表 6 行未列，仅在 `set_image_cache_dir` 描述中提及）
  - `search_cancel`/`search_pause`/`search_resume`（void，`ffi.rs:756-758`、`:797-804`）
  - `apply_replace_rules_to_source`（返回 `String`，`ffi.rs:1992`）
- `§1.6.1` 标题写「以下 6 个」，实际注入型 void 导出为 7 个（含 `set_cache_dir`）。

**影响**：契约豁免面与实现不一致，后续「Result 铁律」检查会出现假阳性/假阴性。

**修复方向**：补登 5 项并修正 6→7；或在 §1.6 明确「本节仅历史 9 项，新增非 Result 逐条登记在对应 §2.x 方法行」。

---

### P3-3 Web 源写路径未调用 `invalidate_image_action_engine`（契约文字过宽，功能无回归）

**原版/参考版证据**：不适用（批20/21 新增能力的我方契约精度问题；参考版 `SharedJsScope` 按源求值，无此 LRU 缓存）。

**我方证据**

- 契约 §2.21 注写「书源新增/更新/删除/导入调用 `invalidate_image_action_engine` 失效」（`docs/API_CONTRACT.md:981`）。
- FFI 路径确有调用：`rust/legado-ffi/src/api/source.rs:76`、`:95`、`:106`、`:159`。
- Web 源写路径未调用：`legacy/source_write_api.rs:285-350`（saveBookSource/saveBookSources）、`:372-397`（deleteBookSources）、`:473-592`（saveJsSource）；`handlers/source_update.rs:279-287`（仓库更新）；`handlers/source.rs:79-101`（/api/sources）。
- 缓存自身会比对 `jsLib` 字符串签名（`replace_rule_js.rs:212-232`），且 source/book 绑定每次点击重放（`:467-482`），因此**不会产生旧规则执行**；未失效仅导致旧 `Arc<Mutex<QuickJsEngine>>` 在 LRU 淘汰前继续驻留（内存/首次重建延迟）。

**影响**：无用户可见功能缺陷；属于契约文字与实现的精度差异，以及 Web 写路径的内存回收延迟。

**修复方向**：在 Web 源写成功路径补 `legado_js::replace_rule_js::invalidate_image_action_engine(&url)`（与 FFI 对齐），或把契约文字改为「FFI 源写路径主动失效，其余路径由 jsLib 签名兜底」。

---

### P3-4 Web 敏感读响应头/注释卫生

**我方证据**

- `GET /getBookSourcesForManagement`、`GET /getBookSourceCheckStates` 缺少 `Cache-Control: no-store`（`web_assets.rs:126-133`；上游 `HttpServer.kt:278-282` 包含这两条）。
- `server.rs:124` 注释仍写「源写 12 条路由」，实际常量 13 条（`source_write_api.rs:164-178`）。
- `source_api.rs:22-25` 注释称「受保护 GET 面仅 getHttpLog(s)」，与上游 `PROTECTED_HTTP_LOG_READ_ROUTES` 四条不符（另两条即 P1-2 的对象）。

**影响**：文档/响应头卫生，易误导后续维护与验收；`no-store` 缺失有轻微缓存泄露风险（与 P1-2 同域）。

**修复方向**：补 no-store、修正注释与 §4.1 令牌列；与 P1-2 一并处理。

---

## 三、待核实（附核实方法）

1. **图片动作 `java.webView`/`refreshBookInfo`/`copyText` 等副作用是否应回放**
   现状：Rust `ui_action_queue` 会把 `webView`/`refreshBookInfo`/`refreshBookToc`/`refreshContent`/`copyText`/`clearTtsCache`/`openVideoPlayer` 等入队（`rust/legado-js/src/host_api/ui_action_queue.rs:136-151`、`platform.rs:12-17`）；Dart `replayImageActionSideEffects` 只回放 toast/longToast/showBrowser/openBrowser/startBrowser/openUrl，其余仅 debug 日志（`flutter_legado/lib/src/utils/image_action_replay.dart:68-110`）；若只有未回放 action，`outcome.actions.isNotEmpty` 还会抑制静态 toast 提示（`reader_page_view.dart:1650-1665`）。参考版 `clickImg` 绑定的是 `SourceLoginJsExtensions`，其 `java` 具备 `webView` 等能力（`legado-upstream/app/src/main/java/io/legado/app/help/JsExtensions.kt:125`（接口）、`:279-291`（`webView`））。
   核实方法：扫描真实书源语料中 `<img>` 的 `click`/`js` 动作是否使用 `java.webView`/`java.refreshBookInfo` 等；若有，按参考版补回放或在 §2.21 明确「仅支持 toast/浏览器类」。
2. **`flutter_legado/lib/src/bridge/ffi/ffi.dart` 的注释级改动是 codegen 还是手工同步**
   现状：`git log` 显示 `4a4d2ea7ab`（docs）、`9bef0efc85`（fix UI）、`08fc8d5582`（docs）三个提交对 `bridge/ffi/ffi.dart` 只有注释级 diff，且未同步改动 `frb_generated.rs/.dart`；可能是 codegen 只刷新注释，也可能是手工同步。未见生成代码逻辑段手改。
   核实方法：在允许构建的环境执行 `cd flutter_legado && dart run flutter_rust_bridge_codegen generate` 后 `git diff --exit-code`；若零 diff 则为 codegen 产物，否则为手工改动（下次 codegen 会覆盖）。
3. **发布 APK 内嵌 `.so` 是否与本地三 ABI 产物一致**
   现状：`jniLibs/` 被 `.gitignore:37` 忽略；本地文件 mtime/hash 已核对（见 1.5），但无法从仓库证明用户安装包内嵌同一文件。
   核实方法：从发布 APK 解包 `lib/arm64-v8a/liblegado_ffi.so` 与本地文件比 sha256，并核对同目录 `.so.meta` 的 `contentHash/builtAt/quickjs`。

---

## 四、修复优先级建议

1. **先修 P0-1 + P1-1**：给 `/api/webbook/*`、`/api/sources*`、`/api/sources/update` 加统一令牌前置；`POST /api/sources` 禁止 default+REPLACE 覆盖既有行；`/api/sources/update` 校验 `repo_url` 并去掉无条件跳过证书校验。两项共用一套「/api 写/执行面鉴权」中间件，改动集中、回归面清晰。
2. **再修 P1-2**：两条 check GET 加令牌 + no-store，并修正 §4.1/模块注释；嵌入式 vue 前端已带 token，兼容性风险低。
3. **P1-3**：按 `sub_type` 落库或下线「应用更新」入口；补真实落库往返测试。
4. **P2/P3**：契约门禁补第三边、review 路由入中间件、文档/注释回销；P3-3 可与下次 Web 源写批次搭车。

---

## 附录 A：计数与检索口径

- **BookApi/MockBookApi/RustApi 计数**：用与 `flutter_legado/test/unit/api_contract_test.dart` 相同的行扫描规则（两空格缩进 + 含 `(` + 类型 token 前导），拼接 `part` 文件后提取；结果 BookApi 338、MockBookApi 356（含 18 个 `_` 私有）、RustApi 357（公共额外 2）。
- **FFI 导出**：解析 `rust/legado-ffi/src/ffi.rs` `pub mod ffi` 内 `^\s{4}pub (async )?fn`，得 329 条声明；`js_eval` 在 `#[cfg(feature="quickjs")]`/`#[cfg(not(...))]` 下各一条，unique 328；16 条 `pub async fn`。
- **契约结构**：`### 2.x ...（N 个方法）` 50 节，逐节声明数 == 行数（0 处不符）；附录 50 行、和 340；§1.7 表 A 16 行、表 B 174 行、合计 190。
- **差集**：§2.x 行 − BookApi − §1.7 表 A = {`rssUpdateSource`, `chapterPayAction`}；FFI unique 导出 − BookApi camel 同名 − 表 B = 26 项，全部落入 §1.6.1 注入 7 / 预留 3 / §1.7 改名 15 / 纯 FFI 1。
- **死接线**：`bridge.<fn>(` 业务调用（排除 `lib/src/bridge/`）覆盖 325 个 wrapper，未调用 3 个（`sourceLoginV1`、`verificationPending`、`webviewPending`）；`ffi.dart` 328 个 wrapper 覆盖全部 328 unique 导出。
- **只读命令**：`git log --oneline`、`git log -S <symbol>`、`git show --stat`、`rg -n`、`rg -n --encoding utf-8`、Python 3.11 行扫描（仅读文件，无写操作）、`stat` 读 `.so` mtime。
- **未运行**：`cargo build/test`、`flutter test/analyze`、`gradlew` 等构建/测试命令（任务书禁止）。

---

— FFI 契约与 Web 服务审查子代理 ｜ 2026-11-13
