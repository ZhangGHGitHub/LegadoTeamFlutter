# 批23 设备验收报告：`/api/webbook/*` 令牌守卫（P0-1）

- 验收日期：2026-11-13
- 验收执行：QA 子代理（仅设备取证与证据归档，未修改任何代码）
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`，HEAD `6611002b1e`（`chore: 批23 收尾（2.0.493+494 双日志）`）
- 修复提交：`6ce1189059`（`fix(rust): /api/webbook/* 纳入源写令牌前置守卫（P0-1）`）、`ac8f1567ca`（契约登记）
- 验收对象：`io.legado.flutter_legado` 2.0.493（versionCode 494），release 变体
- 结论摘要：**12 PASS / 0 FAIL / 0 BLOCKED**；设备崩溃五项计数 0；代码级 P0-1 单测 1 passed；附加 2 个 P3 观察项（验收脚本字段名、uiautomator 工具崩溃），均非产品缺陷

## 一、环境与对象

| 项目 | 实测值 |
|---|---|
| 设备端点 | **`192.168.100.63:5555`**（`adb devices` 直接在线；`MuMuManager.exe info -v all` 判定 index 0「Test2」`is_android_started=true`、`is_process_started=true`；`127.0.0.1:16384` 未使用） |
| 模拟器 | MuMu 实例 index 0「Test2」，Android 15，Android 版本字符串 `15` |
| 屏幕 | 1080x1920，density 480；MuMu 多显示（冷启动分别落在 logical 25/26/27；`screencap -d <logicalId>` 在本 ROM 返回 `Status: -2`，截图改用物理 display id） |
| 安装包 | `io.legado.flutter_legado` versionName **2.0.493** / versionCode **494**；`lastUpdateTime=2026-11-13 03:59:54` |
| APK sha256 | **`5330ae65dd9ffb86b986ebf76517d5e1caf87698840bb6be2235202b62ef93b8`**（设备端 `base.apk` 实测，与任务给定值一致；211,720,256 bytes） |
| Web 服务 | `http://192.168.100.63:1122`（「我的 → Web 服务」开关开启；默认端口 1122） |
| 令牌基线 | 未配置（「设置 → 高级 → 其他设置 → Web 书源访问令牌」对话框输入框为空，仅显示占位提示） |
| 正对照令牌 | 临时配置 `testtoken123`（截图显示「已配置」/ Toast「Token 已保存」）；验收结束由 `pm clear` 清除 |
| 测试固件 | `QA23 Token Regression`（`https://example.com/qa23/book1`），仅用于 Web UI 书架回归；`pm clear` 后已不存在 |
| 取证方式 | `adb shell input -d <logicalDisplay>` 注入、`uiautomator dump` 读节点、`screencap` 按物理 display id 截图；宿主 `curl`；宿主 Chrome headless 渲染 Web UI |

## 二、总体结论

| 指标 | 数量 |
|---|---|
| 验收项总数 | **12** |
| PASS | **12** |
| FAIL | **0** |
| BLOCKED | **0** |
| 设备崩溃五项（FATAL / AndroidRuntime / ANR / OOM / Low memory） | **0** |
| 代码级 P0-1 单测 | **1 passed / 0 failed**（305 filtered out，0.21s） |
| 附加观察项 | 2 个 P3（见第五节） |

**核心结论**：在「令牌未配置」与「令牌已配置但请求不带令牌」两种真实设备状态下，`/api/webbook/{search,info,chapters,content}` 四条端点均返回原版失败信封 `isSuccess=false`、`errorMsg="Web 书源访问令牌未配置或不正确"`、`data=null`，响应头带 `Connection: close`，且四条响应中 **`EXECUTED` 出现次数均为 0**；配置正确令牌后同一 search 请求返回 `results[0].name="EXECUTED"`，证明 JS 引擎确实可执行、拒绝层是真拦截而非引擎失效。

## 三、逐项结果

| # | 验收项 | 结果 | 关键证据 | 说明 |
|---|---|---|---|---|
| 1 | 打开应用 → 我的 → 开启 Web 服务 → 记录端口 | PASS | `tmp_qb23_04.png`、`ui23_04.xml` | 开关 ON，页面展示 `http://192.168.100.63:1122`、复制地址/在浏览器中打开；端口 1122 |
| 2 | 宿主 `curl /api/health` 确认可达 | PASS | 实测输出 | `HTTP/1.1 200 OK`，`{"service":"legado-server","status":"ok","version":"0.2.0"}` |
| 3 | 确认未配置访问令牌 | PASS | `tmp_qb23_07.png`、`ui23_10.xml` | 打开「Web 书源访问令牌」，对话框标题「JS 书源 API Token」，`EditText` 为空（仅占位提示），未保存任何值 |
| 4 | 未授权 curl 四条端点（不带令牌），返回失败信封且不执行 JS | PASS | `curl_b23_unauth_search.txt`、`curl_b23_unauth_info.txt`、`curl_b23_unauth_chapters.txt`、`curl_b23_unauth_content.txt` | 四条均 `HTTP 200` + `connection: close` + `{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}`；`grep -c EXECUTED` 均为 0 |
| 5 | 截图 + 保存 curl 输出 | PASS | `tmp_qb23_07.png`、上述 4 个 curl 文本 | 令牌空态截图与四条 curl 原始响应（含响应头）已归档 |
| 6 | 设置访问令牌（`testtoken123`） | PASS | `tmp_qb23_09.png`、`ui23_12.xml` | 设置项副标题变为「已配置」，Toast「Token 已保存」 |
| 7 | 带 `x-legado-token: testtoken123` 重发 search → 成功且含 `EXECUTED` | PASS | `curl_b23_auth_search.txt` | `HTTP 200`，`{"results":[{"name":"EXECUTED",...}],"total":1,"query":"test","page":1}` |
| 8 | 保存正对照输出 | PASS | `curl_b23_auth_search.txt`、`curl_b23_auth_search_keyfield.txt` | 正确字段 `query` 的成功响应已保存；任务原 body 的 `key` 字段差异见 P3-1 |
| 9 | 带令牌访问既有读端点 `/api/books` | PASS | `curl_b23_regression_api_books_with_token.txt`、`curl_b23_regression_api_books_no_token.txt`、`curl_b23_regression_getBookshelf_after.txt` | 带/不带令牌均 `200`；创建固件书后 `/api/books` 返回 `total=1`，`/getBookshelf` 返回 `isSuccess=true` 且含 `bookUrl` |
| 10 | 浏览器打开 Web UI，书架仍正常加载 | PASS | `tmp_qb23_webui.png`、`tmp_qb23_webui_bookshelf.png`、`tmp_qb23_webui_bookshelf_withbook.png`、`webui_*_dom.html` | 宿主 Chrome headless 渲染：首页正常；`/vue/index.html` 显示「已连接 http://192.168.100.63:1122」，加入固件书后页面显示 `QA23 Token Regression` |
| 11 | logcat 五项崩溃计数 | PASS | `logcat_b23_final.txt`、`logcat_counts_b23.txt`、`logcat_crash_b23.txt` | FATAL EXCEPTION 0、E/AndroidRuntime 0、ANR 0、OutOfMemory 0、Low on memory 0；crash buffer 仅 12 条 `uiautomator` 工具 SIGSEGV，0 条 legado 引用 |
| 12 | 关闭 Web 服务、`pm clear`、终态截图 | PASS | `tmp_qb23_11_web_off.png`、`tmp_qb23_12_final.png`、`final_state_b23.txt` | 开关 OFF、1122 连接被拒（`curl_exit=7`）；`pm clear` 返回 `Success`；书架为空；重新启动后 PID 21831、version 2.0.493+494 不变 |

## 四、关键证据：未授权请求的实际响应体

命令（与任务给定 body 一致，`key` 字段原样保留）：

```bash
curl -s -i -X POST http://192.168.100.63:1122/api/webbook/search \
  -H "Content-Type: application/json" \
  -d '{"source":{"bookSourceUrl":"x","bookSourceName":"x","mainJs":"function search(k,p){return JSON.stringify([{name:\"EXECUTED\"}])}"},"key":"test"}'
```

实际响应（`curl_b23_unauth_search.txt`，`info/chapters/content` 四条完全同形）：

```http
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
x-content-type-options: nosniff
access-control-allow-methods: GET, POST
connection: close
content-length: 88

{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}
```

四条端点结果汇总：

| 端点 | HTTP | `isSuccess` | `errorMsg` | `data` | 响应含 `EXECUTED` |
|---|---|---|---|---|---|
| `/api/webbook/search` | 200 | false | Web 书源访问令牌未配置或不正确 | null | 否（count=0） |
| `/api/webbook/info` | 200 | false | Web 书源访问令牌未配置或不正确 | null | 否（count=0） |
| `/api/webbook/chapters` | 200 | false | Web 书源访问令牌未配置或不正确 | null | 否（count=0） |
| `/api/webbook/content` | 200 | false | Web 书源访问令牌未配置或不正确 | null | 否（count=0） |

**令牌已配置但请求不带令牌**时复测四条（合法 `query`/`book_url`/`chapter` body，文件 `curl_b23_notoken_configured_*.txt`），四条仍全部返回上述失败信封且 `connection: close`，`EXECUTED` 计数均为 0。**错误令牌**（`x-legado-token: wrongtoken`）同样被拒（`curl_b23_wrongtoken_search.txt`）。

**正对照**（配置 `testtoken123`，正确字段 `query`）：

```http
HTTP/1.1 200 OK
content-type: application/json

{"results":[{"name":"EXECUTED","author":"qa","book_url":"https://example.com/b/1","cover_url":null,"intro":null,"latest_chapter":null,"source_url":"x"}],"total":1,"query":"test","page":1}
```

结论：拒绝路径没有执行请求体中的 `mainJs`（否则 `EXECUTED` 会出现在结果中）；放行路径确实执行了 JS 并返回其产物，守卫拦截层与执行引擎两端均被独立证明。

## 五、问题分级

### P3-1（验收脚本字段名与 API 契约不一致，非产品缺陷）

- 现象：任务给出的 search body 使用 `"key":"test"`；带正确令牌重发该 body 时返回 `422 Unprocessable Entity`：`Failed to deserialize the JSON body into the target type: missing field \`query\` at line 1 column 144`（`curl_b23_auth_search_keyfield.txt`）。
- 定位：`/api/webbook/search` 的请求结构为 `WebBookSearchRequest { source, query, page }`（`rust/legado-server/src/handlers/web_book.rs:69`，字段名 `query`）；P0-1 单测同样使用 `"query": "三体"`（`web_book.rs` 约 1300 行）。
- 影响：不影响安全结论——未授权请求在 body 提取前即被令牌守卫拒绝，因此 `key` body 仍返回令牌错误而非 422；当前仅影响「带令牌正对照」的脚本复现。建议把验收脚本字段改为 `query`（可选保留 `page`）。
- 证据：`curl_b23_auth_search_keyfield.txt`（422）、`curl_b23_auth_search.txt`（`query` 成功且含 `EXECUTED`）。

### P3-2（环境/工具问题，非应用缺陷）：uiautomator 原生 SIGSEGV

- 现象：`logcat -b crash` 中出现 12 条 `Fatal signal 11 (SIGSEGV)`，全部 `Cmdline: uiautomator`、`uid: 2000`，其中 0 条引用 `io.legado.flutter_legado`（`logcat_crash_b23.txt`）。
- 影响：`uiautomator dump`/截图流程未受影响（后续 dump 均成功）。但若门禁把 crash buffer 任何 SIGSEGV 都计为「设备崩溃」，需将工具进程排除或换用 `uiautomator` 稳定版本；本报告的五项应用崩溃计数为 0。
- 证据：`logcat_counts_b23.txt`（crash buffer cmdline 统计：`uiautomator: 12`，legado 引用 0）。

### P3-3（命名观察项，非缺陷）

- 设置列表项文案为「Web 书源访问令牌」，弹窗标题为「JS 书源 API Token」；两者指向同一配置（`config:jsSourceApiToken`）。不影响功能，建议后续统一用户可见文案。

### 安全边界说明（非问题）

- 本次守卫范围是「源写/执行」17 条路由（`PROTECTED_SOURCE_WRITE_ROUTES`），包含 `/mcp/call` 与自研 `/api/webbook/*` 四条；`/api/books`、`/getBookshelf` 等读端点按原版语义不要求令牌。本次回归确认读端点仍正常，符合设计；令牌不用于保护只读面。

## 六、代码级门禁引用

| 项目 | 内容 |
|---|---|
| 目标单测 | `cargo test -p legado-server test_webbook_endpoints_reject_without_token_and_do_not_execute_js -- --nocapture` |
| 结果 | `test handlers::web_book::tests::test_webbook_endpoints_reject_without_token_and_do_not_execute_js ... ok`；`1 passed; 0 failed; 305 filtered out; finished in 0.21s` |
| 日志 | `docs/materials_1113b/cargo_test_p0_1_b23.txt` |
| 守卫实现 | `rust/legado-server/src/legacy/source_write_api.rs`（`PROTECTED_SOURCE_WRITE_ROUTES` 17 条 + `source_write_token_guard`，body 提取前拒绝） |
| 生产挂载 | `rust/legado-server/src/server.rs::attach_source_write_token_guard`（`serve_web_with_injected_paths` 统一套用） |
| 令牌语义 | `rust/legado-server/src/legacy/source_api.rs`（`x-legado-token` vs `config:jsSourceApiToken`；`jsSourceApiTokenRequired` 缺省 true；常量时间比较） |
| 路由登记 | `rust/legado-server/src/routes.rs:85-90`（`/webbook/{search,info,chapters,content}`） |
| 回归用例 | `rust/legado-server/src/handlers/web_book.rs`（P0-1：四端点无令牌拒绝 + 标记服务连接数 0；quickjs 档另有 required=false 放行用例） |

## 七、设备终态

- Web 服务：**OFF**（「我的」页开关关闭，副标题恢复「用浏览器写源或看书」；`tmp_qb23_11_web_off.png`）；`http://192.168.100.63:1122/api/health` 连接被拒（`curl_exit=7`）。
- 数据清理：`pm clear io.legado.flutter_legado` 返回 **`Success`**；令牌 `testtoken123`、固件书 `QA23 Token Regression`、Web 服务偏好全部清除。
- 应用状态：清理后重新启动 `io.legado.flutter_legado/io.legado.flutter.MainActivity`，PID 21831；书架为空（`tmp_qb23_12_final.png`）。
- 版本：仍为 versionName 2.0.493 / versionCode 494，APK sha256 未变（`5330ae65...93b8`）。
- 设备崩溃：五项计数 0；无 CRASH/ANR/LOW_MEMORY 的 `ApplicationExitInfo`（仅有历史 `USER REQUESTED/FORCE STOP` 与 `PACKAGE UPDATED`）。
- 遗留测试数据：无（固件书、令牌、临时服务均已清除）。

## 八、证据清单（`docs/materials_1113b/`）

| 文件 | 内容 |
|---|---|
| `tmp_qb23_01.png` | 应用冷启动书架初始态 |
| `tmp_qb23_02.png` | 「我的」页 |
| `tmp_qb23_03.png` | 通知权限弹窗 |
| `tmp_qb23_04.png` | Web 服务 ON，`http://192.168.100.63:1122` |
| `tmp_qb23_05.png` | 设置页 |
| `tmp_qb23_06.png` | 高级 → 其他设置（滚动至令牌项） |
| `tmp_qb23_07.png` | **令牌空态对话框**（输入框为空） |
| `tmp_qb23_08.png` | 输入 `testtoken123` 后、保存前 |
| `tmp_qb23_09.png` | **令牌已配置** + Toast「Token 已保存」 |
| `tmp_qb23_10.png` | 关闭 Web 服务前的「我的」页（服务 ON） |
| `tmp_qb23_11_web_off.png` | **Web 服务 OFF** |
| `tmp_qb23_12_final.png` | **`pm clear` 后终态：书架为空** |
| `tmp_qb23_webui.png` | Web UI 首页（Chrome headless 渲染） |
| `tmp_qb23_webui_bookshelf.png` | Web UI `/vue/index.html` 空书架 + 已连接 |
| `tmp_qb23_webui_bookshelf_withbook.png` | Web UI 书架显示固件书 + 已连接 |
| `curl_b23_unauth_search.txt` / `_info` / `_chapters` / `_content` | **四条未授权端点原始响应（含响应头）** |
| `curl_b23_notoken_configured_*.txt` | 令牌已配置但不带头，四条端点复测 |
| `curl_b23_wrongtoken_search.txt` | 错误令牌拒绝 |
| `assert_no_executed_b23.txt` | 9 份拒绝响应逐一断言 `EXECUTED=0` |
| `curl_b23_auth_search.txt` | **带令牌 search 成功，含 `EXECUTED`** |
| `curl_b23_auth_search_keyfield.txt` | 任务原 `key` body 带令牌 → 422（P3-1） |
| `curl_b23_regression_api_books_with_token.txt` / `_no_token` / `_after` | `/api/books` 回归 |
| `curl_b23_regression_getBookshelf_after.txt` | `/getBookshelf` 回归 |
| `logcat_b23.txt` / `logcat_b23_final.txt` | 设备 logcat |
| `logcat_crash_b23.txt` / `logcat_counts_b23.txt` | crash buffer 与五项计数 |
| `exit_info_b23.txt` | `dumpsys activity exit-info` |
| `cargo_test_p0_1_b23.txt` | 目标 Rust 单测输出 |
| `final_state_b23.txt` | `pm clear`、版本、端口探测、PID |
| `ui23_*.xml` | 关键页面 uiautomator dump |
| `webui_*_dom.html` / `webui_*_chrome.log` | Web UI 渲染 DOM 与 Chrome 日志 |
| `book_fixture.json` | Web UI 回归固件书请求体 |
