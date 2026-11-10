# 批17 Web 阅读端 `@js:` 对齐 — 设备验收报告

验收日期：2026-11-11
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
证据目录：`docs/materials_1111b/`
验收依据：
- `docs/REFACTORING_ACTIVE_PLAN.md:1233`（批17 排期：`legado-server/src/legacy/book_api.rs` 的 `purify_content` 仍 `process(None)`，Web 阅读端替换规则 `@js:` 不执行；批17 复用批15 的共享执行器接入 Web 链路，并补 App/Web 一致性用例）
- `docs/API_CONTRACT.md:756`（批17 回修登记：两轨共用 `legado-js::replace_rule_js` 执行器与绑定构造；`legado-ffi` 透传 `legado-server/quickjs`；配置/作用域差异前提；`/mcp/call` 纳入写源令牌守卫与工作线程上限）
- 回归用例：`rust/legado-ffi/tests/replace_rule_js_web_parity.rs`（含 `/testReplaceRule` 预览执行与 `/mcp/call` 令牌守卫）
- 版本收尾提交：`b45e52f792`（2.0.486+487 双日志），修复链 `217e2c3dcb` → `feebd44f41` → `5ffd06d1d9` → `41b5d1fd0a`

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器，`192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | `ro.product.model=SM-G9900`（MuMu 模拟），Android 15（API 35） |
| 分辨率 / 密度 | `Physical size: 1080x1920`，`Physical density: 480`（360dp 宽） |
| 系统字体缩放 | `font_scale=1.0` |
| ABI | `x86_64` |
| 被测包 | `io.legado.flutter_legado`（同机另有 `com.legado.app.release` 3.26082823、`io.legato.kazusa` 3.26.19，均未参与本批） |
| 设备实测版本 | `versionName=2.0.486`，`versionCode=487`，`lastUpdateTime=2026-11-11 06:08:12` |
| 设备路径 / APK sha256 | `/data/app/~~Auk3zrH5izvGXrv1_ECOUw==/io.legado.flutter_legado-dFq3oxM9KMYOGmTVC7r9jw==/base.apk`；设备内 `sha256sum` 实测 `46c9226ba4015119e7c4f69307ae6cf21e9416a38e9b26423d3d6cb668ae653f`（与任务给定值一致） |
| 原生库 | APK 内 `lib/{arm64-v8a,armeabi-v7a,x86_64}/liblegado_ffi.so` 均存在（`unzip -l` 实测） |
| 宿主 | Windows，局域网 `192.168.100.52/24`，与设备同网段 |
| Web 服务 | 应用内开启后监听 `0.0.0.0:1122`，`/api/health` 从宿主可达 |
| 测试书 | `tmp_qb17_book.txt`（420 B，UTF-8），`adb push` 至 `/sdcard/Download/` 后经书架「更多 → 添加本地」导入；应用内 3 章 |
| 测试规则 | `JS double`（ASCII 名称）：正则 `(\d+)` → `@js:String(Number(result)*2)`，作用范围仅「正文」，勾选「使用正则表达式」，启用，超时 3000ms |
| 前置状态 | 验收开始前应用数据为空（书架空态截图 `tmp_qb17_00_initial.png`）；`logcat -c` 后开始全程取证 |

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 11 |
| FAIL | 0 |
| BLOCKED | 0 |
| 合计 | 11 |

结论：批17 的核心目标——**Web 阅读端与 App 阅读端对同一条替换规则的 `@js:` 表达式执行结果一致**——已在设备上完整跑通。Web `/getBookContent` 返回正文中的数字为翻倍值（`12 34 56` → `24 68 112`），与 App 阅读器逐字一致；规则关闭后两端同时恢复原文；规则编辑页预览 `12 → 24`（真实执行，非「需要 JS 执行器」）；`/mcp/call` 在未配置令牌时返回失败信封、配置令牌后带 `x-legado-token` 进入 handler 且 `eval_js` 返回 `2`（同时证明 App 构建已透传 server 独有 quickjs 路径）；全程五项崩溃计数与 `OutOfMemory` 均为 0，`pm clear` 后设备回到桌面。

本报告仅覆盖**设备运行时取证**；静态分析/单元测试/Rust 门禁不在本批取证范围，未在本轮运行，相关结论以仓库 CI 与用例口径为准（见 §八）。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1111b/`） | 说明 |
| --- | --- | --- | --- |
| A1 导入本地 TXT 并建 `@js:` 替换规则 | PASS | `tmp_qb17_02_imported.png`、`tmp_qb17_03_rule_add.png`、`tmp_qb17_04_rule_filled.png`、`tmp_qb17_08_rule_saved.png`、`tmp_qb17_book.txt` | 书架「更多 → 添加本地」经系统选择器导入 `tmp_qb17_book.txt`，Toast「已导入 1 本书籍」；规则表单实测填写：名称 `JS double`、匹配规则 `(\d+)`、替换为 `@js:String(Number(result)*2)`、仅「正文」chip 选中、正则勾选；保存后列表项可见且开关为启用态 |
| A2 开启 Web 服务并探测路由 | PASS | `tmp_qb17_09b_after_notif.png`、`tmp_qb17_10_curl_health_shelf.txt` | 我的页 Web 服务开关打开后展示 `http://192.168.100.62:1122`；宿主 `GET /api/health` → `HTTP/1.1 200`、`{"service":"legado-server","status":"ok","version":"0.2.0"}`；`GET /getBookshelf` 返回 `isSuccess=true` 且含本书 `bookUrl` |
| B3 Web 正文 `@js:` 生效（数字翻倍） | PASS | `tmp_qb17_12_curl_content_rule_on.txt` | `GET /getBookContent?url=<bookUrl>&index=0` 返回 `数字样本一：24 68 112。…段落标记乙：数值 200 400 600，期望变为 400 800 1200。`；`index=2` 返回 `结尾数值 0 与 2，期望为 0 与 4。`——全部数字为翻倍值而非原文 |
| B4 关闭规则后 Web 恢复原文 | PASS | `tmp_qb17_13_rule_off.png`、`tmp_qb17_14_curl_content_rule_off.txt` | 列表开关关闭（灰/左）后同一 URL 返回 `数字样本一：12 34 56。…数值 100 200 300，期望变为 200 400 600。` |
| C5 规则编辑页预览 `12 → 24` | PASS | `tmp_qb17_06_preview_12.png`、`tmp_qb17_07_preview_multi.png` | 预览区为输入即刷新的实时预览（无独立「测试」按钮）：输入 `12` → 输出 `24`；继续追加输入后 `1212 34 56` → `2424 68 112`（每个数字串均翻倍）。未见「需要 JS 执行器」提示 |
| D6 未配置令牌时 `/mcp/call` 被拒绝 | PASS | `tmp_qb17_15_mcp_no_token.txt` | `POST /mcp/call -d '{}'`（无头、带任意错误头各一次）均返回失败信封 `{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}` + `Connection: close`，无 handler 结果 |
| D7 配置令牌后带 `x-legado-token` 进入 handler | PASS | `tmp_qb17_16_other_settings.png`、`tmp_qb17_18_token_typed.png`、`tmp_qb17_19_token_saved.png`、`tmp_qb17_20_mcp_with_token.txt` | 「设置 → 高级 → 其他设置 → Web 书源访问令牌」保存后条目显示「已配置」；无令牌/错误令牌仍被拒；正确令牌调用 `eval_js 1+1` 返回正常 JSON-RPC 信封 `{"jsonrpc":"2.0","result":{"content":[{"text":"-- 结果 --\n2\n\n耗时 2ms","type":"text"}]},"error":null,"id":1}` |
| E8 App 内阅读数字仍翻倍 | PASS | `tmp_qb17_22_app_reader_rule_on.png` | 书架打开本书：`数字样本一：24 68 112。`、`数值 200 400 600，期望变为 400 800 1200。`——与 B3 Web 返回逐字一致 |
| E9 关闭规则后 App 与 Web 均恢复原文 | PASS | `tmp_qb17_23_rule_off_for_e9.png`、`tmp_qb17_24_app_reader_rule_off.png`、`tmp_qb17_25_curl_content_rule_off_e9.txt` | 关闭规则并重新打开书籍：App 显示 `数字样本一：12 34 56。`、`数值 100 200 300…`；同一时刻 Web 返回同一原文 |
| F10 logcat 五项崩溃计数 | PASS | `logcat_b17.txt`（3,542 行，06:10:16.964–06:17:11.247）、`logcat_b17_terminal.txt` | `FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0；`OutOfMemory`=0；`logcat -b crash` 空；清理前实测 PID `43674`，取证期间无重启记录 |
| F11 关闭 Web 服务、清理与终态 | PASS | `tmp_qb17_27_web_service_off.png`、`tmp_qb17_28_terminal.png` | 我的页开关关闭（截图）；宿主 curl 连接失败（exit 7），设备 `/proc/net/tcp` 无 `:1122` LISTEN；`pm clear io.legado.flutter_legado` 返回 `Success`；`pidof` 无输出；前台为 `com.microsoft.launcher/.Launcher`；截图显示桌面；`font_scale=1.0`；输入法恢复 Sogou、AdbIME 已禁用 |

补充取证（非清单项，仅作增强证据）：`POST /testReplaceRule` 带正确令牌返回 `{"isSuccess":true,"data":"24 68 112"}`、无令牌返回失败信封（`tmp_qb17_26_curl_test_replace_rule.txt`、`tmp_qb17_test_replace_body.json`）——证明 Web 侧规则预览同样走共享执行器真实执行 `@js:`。

## 四、测试素材与构造

**测试书 `tmp_qb17_book.txt`（420 B，UTF-8，3 章）**

```
第一章 数字校验

数字样本一：12 34 56。

这一段用于对照，正文中的纯数字应被替换规则翻倍。段落标记甲。

段落标记乙：数值 100 200 300，期望变为 200 400 600。

第二章 数字对照二

第二章节起始数值 7 8 9。

段落标记丙：继续验证脚本替换在 Web 与 App 两端输出一致。

段落标记丁：结尾数值 0 与 1，期望为 0 与 2。
```

- 期望映射：`12 34 56` → `24 68 112`；`100 200 300` → `200 400 600`；`0 与 1` → `0 与 2`。
- 目录解析实测 3 章：`第一章 数字校验`（0–215）、`第二章 数字对照二`（215–242）、`第二章节起始数值 7 8 9。`（242–420）。第 3 章为 TXT 目录规则把正文行中的「第二章」识别成章节标题所致，属测试素材产物（与批16 报告同类记录），不影响本批判定。
- `bookUrl` = `/data/user/0/io.legado.flutter_legado/cache/file_picker/1794348658540/tmp_qb17_book.txt`。

**规则**：名称 `JS double`；`isRegex=true`；`pattern=(\d+)`；`replacement=@js:String(Number(result)*2)`；`scopeContent=true`（仅正文）；`isEnabled=true`。

**可复现命令**

```
export PATH="$PATH:/d/Program Files/MuMuPlayer/nx_main"; export MSYS_NO_PATHCONV=1
adb -s 192.168.100.62:5555 logcat -c
adb -s 192.168.100.62:5555 push tmp_qb17_book.txt /sdcard/Download/tmp_qb17_book.txt
# 书架 → 更多 → 添加本地 → 选择文件；我的 → 替换净化 → + → 填规则 → 保存
# 我的 → Web 服务（开关打开，端口 1122）

curl -s http://192.168.100.62:1122/api/health
curl -s http://192.168.100.62:1122/getBookshelf
curl -s "http://192.168.100.62:1122/getBookContent?url=%2Fdata%2Fuser%2F0%2Fio.legado.flutter_legado%2Fcache%2Ffile_picker%2F1794348658540%2Ftmp_qb17_book.txt&index=0"
curl -s -X POST http://192.168.100.62:1122/mcp/call -H 'Content-Type: application/json' -d '{}'
curl -s -X POST http://192.168.100.62:1122/mcp/call -H 'Content-Type: application/json' \
  -H 'x-legado-token: qa17token' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval_js","arguments":{"js":"1+1"}}}'
```

UI 输入说明：设备原生输入法无法直接输入 `(\d+)`/`@js:` 等符号，本轮临时启用系统内已安装的 `com.android.adbkeyboard/.AdbIME`，以 Base64 广播输入；验收结束已恢复默认输入法并禁用该 IME。

## 五、关键取证摘要

### 5.1 规则与 Web 服务（A1/A2）

- `tmp_qb17_02_imported.png`：书架出现封面书「tmp_qb17_book」，底部 Toast「已导入 1 本书籍」。
- `tmp_qb17_04_rule_filled.png`：规则表单三个字段实测值（`JS double` / `(\d+)` / `@js:String(Number(result)*2)`），「正文」chip 高亮，正则勾选。
- `tmp_qb17_08_rule_saved.png`：列表项「JS double　正则: (\d+) → @j…」，开关为启用态。
- `tmp_qb17_09b_after_notif.png`：我的页展示 `Web 服务 http://192.168.100.62:1122` 与「复制地址 / 在浏览器中打开」，说明服务处于运行态。

### 5.2 Web 阅读正文（B3/B4）— 核心

开启规则：

```
GET /getBookContent?url=...&index=0
{"isSuccess":true,"errorMsg":"","data":"数字样本一：24 68 112。\n\n这一段用于对照，正文中的纯数字应被替换规则翻倍。段落标记甲。\n\n段落标记乙：数值 200 400 600，期望变为 400 800 1200。"}
```

```
GET /getBookContent?url=...&index=2
{"isSuccess":true,"errorMsg":"","data":"段落标记丙：继续验证脚本替换在 Web 与 App 两端输出一致。\n\n段落标记丁：结尾数值 0 与 2，期望为 0 与 4。"}
```

关闭规则后同一请求：

```
{"isSuccess":true,"errorMsg":"","data":"数字样本一：12 34 56。\n\n这一段用于对照，正文中的纯数字应被替换规则翻倍。段落标记甲。\n\n段落标记乙：数值 100 200 300，期望变为 200 400 600。"}
```

判定：Web 正文链路对正则匹配逐次执行 `@js:`（`result` 绑定为匹配文本），输出为翻倍值；规则关闭即恢复原文，两者互为对照。

### 5.3 规则编辑页预览（C5）

- `tmp_qb17_06_preview_12.png`：预览输入 `12`、预览输出 `24`。
- `tmp_qb17_07_preview_multi.png`：追加输入后为 `1212 34 56` → `2424 68 112`（`1212×2=2424`、`34×2=68`、`56×2=112`，逐匹配执行正确）。
- 两图均无「需要 JS 执行器 / 规则执行超时」类提示，输出区随输入实时刷新。

### 5.4 MCP 令牌（D6/D7）

未配置令牌（`tmp_qb17_15_mcp_no_token.txt`）：

```
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
connection: close
content-length: 88

{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}
```

带任意错误令牌同样返回上述失败信封。说明：受保护路由按原版 `ReturnData` 语义返回失败信封（HTTP 200 + `Connection: close`），不是 HTTP 401/403；本轮按任务口径「失败信封」判定 PASS。

配置令牌（其他设置显示「已配置」）后：

```
POST /mcp/call  (无令牌 / 错误令牌)
{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}

POST /mcp/call  (x-legado-token: qa17token)
HTTP/1.1 200 OK
{"jsonrpc":"2.0","result":{"content":[{"text":"-- 结果 --\n2\n\n耗时 2ms","type":"text"}]},"error":null,"id":1}
```

判定：令牌前置守卫生效（未授权不进入 handler），正确令牌可执行 `eval_js`；`eval_js` 返回 `2` 同时证明本 APK 已透传 `legado-server/quickjs`（server 独有 JS 路径未降级）。

### 5.5 App 阅读端一致性（E8/E9）

- 开启规则（`tmp_qb17_22_app_reader_rule_on.png`）：语义树与截图一致显示
  `　　数字样本一：24 68 112。` / `　　这一段用于对照，正文中的纯数字应被替换规则翻倍。段落标记甲。` / `　　段落标记乙：数值 200 400 600，期望变为 400 800 1200。`
- 关闭规则后重新打开（`tmp_qb17_24_app_reader_rule_off.png`）：
  `　　数字样本一：12 34 56。` / `　　段落标记乙：数值 100 200 300，期望变为 200 400 600。`
- App 与 Web 在两种状态下的文本逐字一致；页脚显示 `1/1 33.3%`（3 章中第 1 章）。

### 5.6 稳定性与终态（F10/F11）

- `logcat_b17.txt` 覆盖 06:10:16.964–06:17:11.247（导入、建规则、预览、开服、两组 curl、阅读器开关规则全流程），3,542 行。
- 五项：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0；`OutOfMemory`=0；`logcat -b crash` 无输出。
- 清理前 `pidof` 实测 PID 43674；日志中无该应用的 `Start proc` / `Process … died` / `Force stopping` 记录，说明取证期间应用进程未重启。日志中的 tombstone 均为 `UID 2000`（shell，`uiautomator dump` 调用产生），`NativeTombstoneManager` 输出 `Tombstone's UID (2000) not an app, ignoring`，与应用无关。
- 关闭 Web 服务后宿主 `curl` 返回 exit 7（连接被拒），设备 `/proc/net/tcp` 无 `:1122` LISTEN 项；`pm clear` 返回 `Success`，进程消失，前台回到 `com.microsoft.launcher/.Launcher`（`tmp_qb17_28_terminal.png`）。

## 六、问题分级

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| P1（阻塞） | 0 | — |
| P2（重要） | 0 | — |
| P3（观察/登记） | 5 | 见下 |

1. **P3 观察｜TXT 目录规则把正文行识别为章节**：`第二章节起始数值 7 8 9。` 被切成第 3 章（共 3 章而非 2 章）。属测试素材构造产物，与本批 `@js:` 链路无关（批16 报告有同类记录），不判缺陷。
2. **P3 登记｜受保护路由的拒绝形态是 HTTP 200 + 失败信封**：`/mcp/call`、`/testReplaceRule` 未授权时返回 `{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确"}` 且 `Connection: close`，对齐原版 `ReturnData`/`shouldCloseConnection` 语义。若后续需要 HTTP 401/403 语义，应另立契约变更，不能在批17 内视为回归。
3. **P3 登记｜`/getBookContent` 无鉴权**：与 `docs/API_CONTRACT.md:762` 批17 三审登记一致（`/getBookContent` 无鉴权，`@js:` 净化有进程级信号量上限 4、blocking 池 8 槽）；本批未改变该暴露面，设备验收未发现异常，但该风险仍以契约为准。
4. **P3 环境｜logcat 中周期性 tombstone 噪音**：取证期间出现多条 `E tombstoned: Tombstone written to: tombstone_NN`，UID 均为 2000（shell），与 `uiautomator dump` 调用同频，`NativeTombstoneManager` 明确忽略；不构成应用崩溃，五项计数按应用维度均为 0。
5. **P3 工具｜Web `/testReplaceRule` 请求体需合法 JSON 转义**：首版取证脚本把正则写成单反斜杠 `(\d+)`（JSON 非法转义）导致返回「格式不对」；改为 `(\\d+)` 后返回 `24 68 112`。属取证脚本构造问题，非产品缺陷，记录以免复测踩坑（修正后请求体已归档为 `tmp_qb17_test_replace_body.json`）。

## 七、设备终态

| 项目 | 终态 |
| --- | --- |
| Web 服务 | 已关闭；宿主 `curl http://192.168.100.62:1122/api/health` 连接失败（exit 7）；设备无 `:1122` LISTEN |
| 应用数据 | `pm clear io.legado.flutter_legado` → `Success`；`pidof` 无输出 |
| 前台 | `com.microsoft.launcher/com.microsoft.launcher.Launcher`（桌面，`tmp_qb17_28_terminal.png`） |
| 字体缩放 | `1.0` |
| 输入法 | 已恢复 `com.sohu.inputmethod.sogou.chuizi/...SogouIME`；`com.android.adbkeyboard/.AdbIME` 已禁用 |
| 崩溃计数 | FATAL/ANR/E-flutter/overflow/E-AndroidRuntime 均 0，OOM 0（`logcat_b17_terminal.txt` 复核同样为 0） |

## 八、门禁引用与结论

- 本批设备判据来自任务清单 A–F 共 11 项，结果 **11 PASS / 0 FAIL / 0 BLOCKED**。
- 代码侧一致性口径见 `docs/API_CONTRACT.md:756`（共享执行器、quickjs 透传、默认配置 + 全局作用域前提、`/mcp/call` 守卫与并发上限）与回归用例 `rust/legado-ffi/tests/replace_rule_js_web_parity.rs`；本次设备结果与该口径一致（默认净化配置、正文作用域、App 构建 quickjs 可用）。
- 本次**未运行** `flutter analyze` / `flutter test` / `cargo test` / clippy / fmt，也未重新构建 APK；静态与单元门禁以仓库 CI 及对应批次收尾记录为准（版本 `2.0.486+487`，提交 `b45e52f792`）。
- 证据清单：`docs/materials_1111b/` 共 37 个文件——截图 23 张、HTTP 请求/响应文本 9 份（7 份 curl 记录 + 2 份 MCP 记录）、logcat 2 份、输入素材 2 份（测试书 `tmp_qb17_book.txt`、请求体 `tmp_qb17_test_replace_body.json`）、环境快照 1 份；关键文件见 §三逐项表。
