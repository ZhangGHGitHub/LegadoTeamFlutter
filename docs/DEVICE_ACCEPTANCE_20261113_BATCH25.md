# 批25 设备验收报告：P2 三条回修（段评写端点令牌守卫 / FFI 门禁 / 回归）

- 验收日期：2026-11-13
- 验收执行：QA 子代理（仅设备取证与证据归档，未修改任何产品代码）
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`，HEAD `404ff6ff43`（`docs(api): 登记批25 三条 P2 回修`）
- 被验修复：`2054b83167`（P2-1 段评写端点纳入路由级令牌前置）、`09452186d9`（FFI 契约门禁补双向校验）
- 验收对象：`io.legado.flutter_legado` 2.0.495（versionCode 496），release 变体
- 结论摘要：**7 PASS / 0 FAIL / 1 BLOCKED**；设备崩溃五项计数 0；C2 段评面板未能通过 UI 触达，登记 P2 观察项待研发确认

## 一、环境与对象

| 项目 | 实测值 |
|---|---|
| 设备端点 | **`192.168.100.63:5555`**（`adb devices -l` 在线；`MuMuManager.exe info -v all` 判定 index 0「Test2」`is_android_started=true`、`is_process_started=true`） |
| 模拟器 | MuMu 实例 index 0「Test2」，Android 15，1080x1920 / density 480 |
| 多显示 | 本次会话 App 落在 logical display 30→32→33→34 多次变化；`screencap -d <logicalId>` 返回 `Status: -2`，截图统一按 `dumpsys SurfaceFlinger --display-id` 的 physical uniqueId 抓取（与批24 口径一致） |
| 安装包 | `io.legado.flutter_legado` versionName **2.0.495** / versionCode **496**；`lastUpdateTime=2026-11-13 06:38:23` |
| APK sha256 | **`7be30684ec2b6f594fcaf82c425a1cd8f8e7f0e5462d28d896e228b694907b8b`**（设备端 `base.apk` 实测，与任务给定值一致） |
| Web 服务 | `http://192.168.100.63:1122`（「我的 → Web 服务」开关开启；`/api/health` 返回 `{"service":"legado-server","status":"ok","version":"0.2.0"}`） |
| 令牌基线 | 未配置（「设置 → 高级 → 其他设置 → Web 书源访问令牌」副标题仅为说明文案，无「已配置」；`b25_token_empty.png` / `ui_b25_advanced5.xml`） |
| 正对照令牌 | 临时配置 `testtoken123`（保存后副标题变为「已配置」；`b25_token_set.png` / `ui_b25_token_saved.xml`）；周期结束 `pm clear` 已清除 |
| 段评夹具 | 宿主 mock 源站 `http://192.168.100.52:8925`（`qa_b25_mock_server.py`，6 章；书源 `QA25 段评源` 带 `ruleReview`）；`pm clear` 已清除 |
| 取证方式 | 宿主 `curl`、`adb shell input -d <logicalDisplay>`、`uiautomator dump --display <logicalDisplay>`、`screencap -d <physicalUniqueId>`、`logcat -d` |

## 二、总体结论

| 指标 | 数量 |
|---|---|
| 验收项总数 | **8** |
| PASS | **7** |
| FAIL | **0** |
| BLOCKED | **1**（C2 段评面板） |
| 设备崩溃五项（FATAL / AndroidRuntime / ANR / OOM / Low memory） | **0** |
| crash buffer 中 legado 引用 | **0**（14 次 SIGSEGV 全部为 `Cmdline: uiautomator`） |
| 问题分级 | P2 × 1（C2，待研发确认）、P3 × 2（环境/工具） |

**核心结论**：未配置令牌时，`/openLegacyReview`、`/runLegacyReview` 均返回原版令牌失败信封（HTTP 200 + `connection: close` + 88 字节固定体）。**1 MiB / 20 MiB 大 body 在 1.6–11.6 ms 内返回令牌错误，且上传字节数为 0 或仅为内核缓冲的 128–196 KiB（始终小于 body 总量），未出现 413，证明守卫在 body 提取之前拒绝，未读取完整请求体**。配置令牌并携带 `x-legado-token` 后，两条端点均越过守卫进入 handler（返回业务参数错误）。Web UI 正常渲染并连接服务，本地 FFI 契约测试 11 项全通过。

## 三、逐项结果

| # | 验收项 | 结果 | 关键证据 | 说明 |
|---|---|---|---|---|
| 1 | A1 未配置令牌：`/openLegacyReview`、`/runLegacyReview` 返回令牌错误 + `Connection: close` | PASS | `curl_b25_unauth_openreview.txt`、`curl_b25_unauth_runreview.txt` | 两条均 `HTTP 200`、`connection: close`、`content-length: 88`、`{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}` |
| 2 | A2 未读 body：1 MiB（及 20 MiB 加强）大 body 快速返回令牌错误而非 413 | PASS | `b25_1mb_timing.txt`、`b25_1mb_noexpect_timing.txt`、`b25_20mb_timing.txt`、`b25_20mb_noexpect_timing.txt`、`b25_runreview_1mb_timing.txt` | 1 MiB 实测 **1.706 ms**（默认 Expect）/ **1.750 ms**（禁用 Expect，仅上传 196,451 B）；20 MiB 实测 **11.648 ms** / **1.684 ms**（仅上传 130,914 B）；响应均为 200 令牌错误 + 88 B |
| 3 | A3 配置令牌后带 `x-legado-token` 重试，进入 handler | PASS | `curl_b25_auth_openreview.txt`、`curl_b25_auth_runreview.txt`、`curl_b25_wrongtoken_openreview.txt`、`curl_b25_afterconfig_notoken_openreview.txt` | `openLegacyReview` → `{"isSuccess":false,"errorMsg":"参数 url 不能为空"}`；`runLegacyReview` → `{"isSuccess":false,"errorMsg":"旧评论脚本为空或过长"}`；错误令牌/缺令牌仍返回令牌错误 + `connection: close` |
| 4 | B FFI 门禁：`flutter test test/unit/api_contract_test.dart` | PASS | `flutter_test_api_contract_b25.txt` | `00:00 +11: All tests passed!`，EXIT=0；含「第 7 项：Rust FFI 导出面 ↔ Dart wrapper 双向闭合」 |
| 5 | C1 Web 界面书架正常加载（令牌未破坏 UI） | PASS | `b25_web_ui.png`、`curl_b25_web_index.txt`、`curl_b25_bookshelf.txt` | `/` 返回 200（标题「Legado web 导航」）；Vue 阅读页渲染并显示「已连接 http://192.168.100.63:1122」「暂无阅读记录」；`/getBookshelf` 返回正常空书架信封「还没有添加小说」；随后导入测试书后 App 书架正常显示（`b25_shelf_with_book.png`） |
| 6 | C2 段评面板可打开 | **BLOCKED** | `curl_b25_review_summary.txt`、`qa_b25_mock_access.log`、`b25_reader.png`、`b25_ch5.png`、`b25_after_refresh.png` | 已构造带 `ruleReview` 的书源与书（服务端 `/getReviewSummary` 返回 `counts={"1":7,"2":3}`），阅读器正文正常渲染；但 App 端从未向 mock 源站发出 `/review/summary` 请求，段落无数量徽标，无法点开 `ReviewDetailSheet`。详见 4.4 |
| 7 | D1 logcat 五项崩溃计数为 0 | PASS | `logcat_b25.txt`、`logcat_crash_b25.txt`、`logcat_counts_b25.txt` | FATAL EXCEPTION 0、E/AndroidRuntime 0、ANR 0、OutOfMemory 0、Low on memory 0；crash buffer 310 行中 14 次 SIGSEGV 全部 `Cmdline: uiautomator`，legado 引用 0 |
| 8 | D2 关闭 Web 服务、`pm clear`、终态截图 | PASS | `b25_web_off.png`、`final_state_b25.txt`、`b25_final.png` | 开关 OFF 后 `curl /api/health` 退出码 7（连接被拒）；`pm clear` 返回 `Success`；重启后 version 2.0.495+496、sha256 不变、书架空、端口仍关闭 |

## 四、关键证据

### 4.1 未授权请求的原始响应（令牌未配置）

命令（原文）：

```bash
curl -s -i -X POST http://192.168.100.63:1122/openLegacyReview \
  -H "Content-Type: application/json" -d '{"a":1}'
curl -s -i -X POST http://192.168.100.63:1122/runLegacyReview -d '{"a":1}'
```

两条响应同形（`curl_b25_unauth_openreview.txt` / `curl_b25_unauth_runreview.txt`）：

```http
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
x-content-type-options: nosniff
access-control-allow-methods: GET, POST
connection: close
content-length: 88

{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}
```

### 4.2 未读 body：大请求体耗时与实际上传量

| 端点 | body | `Expect` | HTTP | `time_total` | `size_upload` | 响应 |
|---|---|---|---:|---:|---:|---|
| `/openLegacyReview` | 1 MiB | 默认（curl 自动 100-continue） | 200 | **0.001706 s** | 0 B | 88 B 令牌错误 |
| `/openLegacyReview` | 1 MiB | 显式禁用 `Expect:` | 200 | **0.001750 s** | 196,451 B（18.7%） | 88 B 令牌错误 |
| `/openLegacyReview` | 20 MiB | 默认 | 200 | **0.011648 s** | 0 B | 88 B 令牌错误 |
| `/openLegacyReview` | 20 MiB | 显式禁用 `Expect:` | 200 | **0.001684 s** | 130,914 B（0.62%） | 88 B 令牌错误 |
| `/runLegacyReview` | 1 MiB | 显式禁用 `Expect:` | 200 | **0.001636 s** | 130,916 B（12.5%） | 88 B 令牌错误 |

判定依据：

1. 五组均返回 **HTTP 200 + 令牌错误**，**未出现 413**（若守卫失效，axum 默认 2 MiB 限额会先返回 413 或缓冲完整 body）。
2. 禁用 `Expect:` 后 curl 立即开始写 body，但服务端仅接收了 128–196 KiB（本机 socket 发送/接收缓冲量级）后即返回并关闭连接；**上传量始终远小于 body 总量**，说明 handler 未消费请求体。
3. 20 MiB 默认组 11.6 ms 略高于 1 MiB 组，但 `size_upload=0`，耗时来自 100-continue 往返与连接建立，与 body 大小无关；禁用 Expect 的 20 MiB 组反而 1.68 ms。

### 4.3 配置令牌后的正/负对照

配置令牌 `testtoken123`（「已配置」，`b25_token_set.png`）后：

| 请求 | HTTP | 响应要点 | 是否令牌错误 |
|---|---|---|---|
| `POST /openLegacyReview` + `x-legado-token: testtoken123`，body `{"a":1}` | 200 | `{"isSuccess":false,"errorMsg":"参数 url 不能为空","data":null}`（68 B，无 `connection: close`） | 否（已进入 handler） |
| `POST /runLegacyReview` + 正确令牌，body `{"a":1}` | 200 | `{"isSuccess":false,"errorMsg":"旧评论脚本为空或过长","data":null}`（75 B） | 否（已进入 handler） |
| `POST /openLegacyReview` + `x-legado-token: wrongtoken` | 200 | 令牌错误信封 + `connection: close` | 是 |
| `POST /openLegacyReview` 不带令牌（已配置令牌状态） | 200 | 令牌错误信封 + `connection: close` | 是 |

结论：守卫按预期放行正确令牌、拒绝错误/缺失令牌；两条写端点的 handler 内校验仍保留（负对照仍拦截）。

### 4.4 C2 段评面板：构造过程与阻塞点

构造步骤（均可复现）：

1. 宿主启动 `qa_b25_mock_server.py 8925`，提供书页 `/book1.html`（6 章目录）、章节正文、`/review/summary`（`{"data":[{"idx":1,"cnt":7,"token":"p1"},{"idx":2,"cnt":3,"token":"p2"}]}`）、`/review/detail`。
2. 通过 `POST /saveBookSource`（带令牌）导入 `qa_b25_review_source.json`：`ruleReview.enabled=true`，`reviewSummaryUrl=http://192.168.100.52:8925/review/summary`，`summaryListRule=$.data`、`summaryParagraphIndexRule=$.idx`、`summaryCountRule=$.cnt`，详情规则齐备。
3. 通过 `POST /api/books` 添加书 `QA25 段评书`（origin 与书源 URL 一致），`/refreshToc` 得到 6 章；`/getBookContent?url=<book>&index=0` 返回 4 段正文。
4. App 书架显示该书（`b25_shelf_with_book.png`），点击进入阅读器，正文正常渲染（`b25_reader.png`），可切章（`b25_now.png` 为第二章）。

服务端段评链路已验证可用（`curl_b25_review_summary.txt`）：

```json
{"isSuccess":true,"errorMsg":"","data":{"counts":{"1":7,"2":3},"keys":{"1":"p1","2":"p2"}}}
```

但在 App 侧：

- mock 源站访问日志（`qa_b25_mock_access.log`）记录了 `/book1.html`、`/chapter1.html`、`/chapter2.html` 等正文请求，**从未出现 `/review/summary` 或 `/review/detail`**（覆盖首次打开、刷新正文、目录切章多种路径）。
- 阅读器 4 段正文均无段评数量徽标（`b25_reader.png`），因此没有可点击入口，`ReviewDetailSheet` 无法打开。
- 已确认书源在 App 书源列表中可见且「开启」（`b25_sources_list.png` / `ui_b25_sources.xml`），排除「书源未入库/未启用」。

初步定位（待研发确认，非本批改动）：`flutter_legado/lib/src/screens/reader_screen.dart` 的 `_loadReviewSummary()` 仅由 `_maybePreloadAdjacentChapters()` 在 `_wasLoading && !state.isLoading` 的载入状态跃迁时调用；当前开书路径存在内容预取/缓存命中，阅读器首帧即 `isLoading=false`，可能从未触发摘要加载。该逻辑属于既有 P2-9 段评功能，与本批 P2-1 路由守卫改动无交集。

### 4.5 本地门禁

```bash
cd flutter_legado
flutter test test/unit/api_contract_test.dart
```

结果（`flutter_test_api_contract_b25.txt`）：`00:00 +11: All tests passed!`，EXIT=0。其中第 11 项为「第 7 项：Rust FFI 导出面 ↔ Dart wrapper 双向闭合」，对 P2-2 的 FFI 导出面门禁形成直接证据。

P2-1 的 Rust 侧验证引用修复提交 `2054b83167` 自带结论（本次未重复执行，设备无关）：`cargo test -p legado-server` 320 lib + 82 legacy_web、`--features quickjs` 322 + 90、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo fmt --all -- --check` 均 EXIT=0；新增集成测试覆盖「无令牌 + 1 GiB Content-Length + 一旦轮询即 panic 的 body 流」。

## 五、问题分级

| 级别 | 问题 | 影响 | 建议 |
|---|---|---|---|
| **P2（待研发确认）** | 段评摘要未加载：带 `ruleReview` 的书源在阅读器中不发起 `/review/summary`，段落无数量徽标，段评面板无法打开（复现：导入 `qa_b25_review_source.json` → 添加书 → 阅读第一章；服务端 `/getReviewSummary` 同时可用） | 段评功能在设备上不可达；不影响本批 P2-1 令牌守卫结论 | 排查 `_loadReviewSummary` 的触发条件（首帧 `isLoading` 恒为 false / 预取路径），补充「开书后主动加载当前章摘要」或在 `chapterContent` 变化时触发；补一条 Reader 组件测试断言徽标出现 |
| P3（环境） | MuMu 多显示下 logical display 与可截图 physical display 不一致，`screencap -d <logicalId>` 返回 `Status: -2`，且每次重启 App 可能新建 display | 仅影响自动化取证方式 | 沿用 `dumpsys SurfaceFlinger --display-id` 的 physical uniqueId 抓图；报告已登记本次 display 30→32→33→34 的漂移 |
| P3（工具） | crash buffer 中 14 次 `Fatal signal 11 (SIGSEGV)` 均来自 `uiautomator` | 与 App 无关 | 后续统计 crash buffer 时先按 `Cmdline` 过滤工具进程 |

## 六、设备终态

| 项目 | 终态 |
|---|---|
| Web 服务 | **OFF**（`b25_web_off.png` 显示「用浏览器写源或看书」）；`curl http://192.168.100.63:1122/api/health` 退出码 **7**（连接被拒） |
| 应用数据 | `pm clear io.legado.flutter_legado` 返回 **Success**；令牌、书源、测试书、日志开关均被清除 |
| 版本 | versionName **2.0.495** / versionCode **496**；APK sha256 **`7be30684…907b8b`** 与验收前一致 |
| 界面 | 书架空（`b25_final.png`）；进程 PID 28564 |
| 夹具清理 | 宿主 mock 源站已停止；临时书源/书随 `pm clear` 清除 |

## 七、证据索引（`docs/materials_1113d/`）

| 类别 | 文件 |
|---|---|
| A1 未授权 | `curl_b25_unauth_openreview.txt`、`curl_b25_unauth_runreview.txt` |
| A2 大 body | `b25_body_1mb.bin`、`b25_1mb_{timing,headers,body}.txt`、`b25_1mb_noexpect_{timing,headers,body}.txt`、`b25_20mb_{timing,headers,body}.txt`、`b25_20mb_noexpect_{timing,headers,body}.txt`、`b25_runreview_1mb_{timing,headers,body}.txt` |
| A3 带令牌 | `curl_b25_auth_openreview.txt`、`curl_b25_auth_runreview.txt`、`curl_b25_wrongtoken_openreview.txt`、`curl_b25_afterconfig_notoken_openreview.txt` |
| 令牌界面 | `b25_token_empty.png`、`b25_token_filled.png`、`b25_token_set.png`、`ui_b25_advanced5.xml`、`ui_b25_token_dialog.xml`、`ui_b25_token_saved.xml` |
| B 门禁 | `flutter_test_api_contract_b25.txt` |
| C1 Web UI | `b25_web_ui.png`、`curl_b25_web_index.txt`、`curl_b25_bookshelf.txt`、`b25_shelf_with_book.png` |
| C2 段评 | `qa_b25_mock_server.py`、`qa_b25_review_source.json`、`qa_b25_book.json`、`qa_b25_mock_access.log`、`curl_b25_review_summary.txt`、`curl_b25_book_content.txt`、`curl_b25_refresh_toc2.txt`、`b25_reader.png`、`b25_now.png`、`b25_ch5.png`、`b25_after_refresh.png`、`b25_sources_list.png`、`ui_b25_reader*.xml`、`ui_b25_toc*.xml` |
| D 稳定性/终态 | `logcat_b25.txt`、`logcat_crash_b25.txt`、`logcat_counts_b25.txt`、`b25_web_off.png`、`final_state_b25.txt`、`b25_final.png` |
