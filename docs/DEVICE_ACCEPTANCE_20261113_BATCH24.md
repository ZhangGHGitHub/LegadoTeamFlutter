# 批24 设备验收报告：P1 安全与数据修复（令牌守卫 / 书源 409 数据保护 / 订阅应用落库）

- 验收日期：2026-11-13
- 验收执行：QA 子代理（仅设备取证与证据归档，未修改任何代码）
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`，HEAD `0d50b61c23`（`chore: 批24 收尾（2.0.494+495 双日志）`）
- 修复提交：`d72105dbf1`（P1-1 令牌守卫 + TLS）、`ebb794f9d4`（P1-2 PUT 部分更新）、`381ec8c152`（P1-3 订阅按 `lastUpdateTime` 门控）、`60b6b50e9a`/`3efbfc5986`（P1-3 落库与仅 upsert）
- 验收对象：`io.legado.flutter_legado` 2.0.494（versionCode 495），release 变体
- 结论摘要：**12 PASS / 0 FAIL / 0 BLOCKED**；设备崩溃五项计数 0；3 个 P3 级观察项均非产品缺陷

## 一、环境与对象

| 项目 | 实测值 |
|---|---|
| 设备端点 | **`192.168.100.63:5555`**（`adb devices -l` 直接在线；`MuMuManager.exe info -v all` 判定 index 0「Test2」`is_android_started=true`、`is_process_started=true`；`127.0.0.1:16384` 未使用） |
| 模拟器 | MuMu 实例 index 0「Test2」，Android 15，Android 版本字符串 `15` |
| 屏幕 | 1080x1920，density 480；多显示（本次启动落在 logical display 28，`pm clear` 重启后落在 logical display 29）。本 ROM `screencap -d <logicalId>` 返回 `Status: -2`，截图统一按 `dumpsys display` 的 physical uniqueId 抓取；UI 注入使用 `input -d <logicalId>` |
| 安装包 | `io.legado.flutter_legado` versionName **2.0.494** / versionCode **495**；`lastUpdateTime=2026-11-13 05:59:59` |
| APK sha256 | **`a1c841d0daa36bc75129953499b7d07532fce3574d57f53e006dd4a2dd7f2daa`**（设备端 `base.apk` 实测，与任务给定值一致；212,113,628 bytes） |
| Web 服务 | `http://192.168.100.63:1122`（「我的 → Web 服务」开关开启；默认端口 1122） |
| 令牌基线 | 未配置（「设置 → 高级 → 其他设置 → Web 书源访问令牌」输入框为空，仅占位提示；`b24_token_empty.png` / `ui_b24_token_empty.xml`） |
| 正对照令牌 | 临时配置 `testtoken123`（界面显示「已配置」/ Toast「Token 已保存」，`b24_token_set.png`）；周期结束 `pm clear` 已清除 |
| 订阅宿主 | 宿主 `python -I -m http.server 8899 --bind 0.0.0.0`（Python 3.11.9），提供 `http://192.168.100.52:8899/qa24_sub.json`（2 条书源；测试后已停止） |
| 测试固件 | 富书源 `https://qa24.example.com/source/rich`（jsLib/变量/四组规则）；本地保留源 `https://qa24.example.com/source/keep-local`；订阅源 `sub-a`/`sub-b`。均随 `pm clear` 清除 |
| 取证方式 | `adb shell input -d <logicalDisplay>` 注入、`uiautomator dump` 读节点、`screencap -d <physicalUniqueId>` 截图；宿主 `curl` |

## 二、总体结论

| 指标 | 数量 |
|---|---|
| 验收项总数 | **12** |
| PASS | **12** |
| FAIL | **0** |
| BLOCKED | **0** |
| 设备崩溃五项（FATAL / AndroidRuntime / ANR / OOM / Low memory） | **0** |
| crash buffer 中 legado 引用 | **0**（43 条 SIGSEGV 全部为 `uiautomator` 工具进程） |
| 附加观察项 | 3 个 P3（见第五节） |

**核心结论**：未配置令牌时，`/api/rule-update/apply` 与两条受保护读面均返回原版令牌失败信封并带 `Connection: close`，两条读面同时带 `Cache-Control: no-store`；配置令牌后同一批端点不再返回令牌错误。`POST /api/sources` 对已存在 URL 返回 **409**，富书源的 340 字节 `jsLib`、`variable`、`header`、搜索/详情/目录/正文规则在冲突请求后逐字段保持不变。规则订阅「应用更新」真实把 2 条订阅书源写入库（书源总数 2→4），本地无关书源保留，二次应用返回「新增 0、更新 0、移除 0」且无重复行。

## 三、逐项结果

| # | 验收项 | 结果 | 关键证据 | 说明 |
|---|---|---|---|---|
| 1 | 开启 Web 服务、不配置令牌：`apply` + 两条管理读面均返回令牌错误 + `Connection: close` | PASS | `curl_b24_unauth_apply.txt`、`curl_b24_unauth_mgmt.txt`、`curl_b24_unauth_states.txt` | 三条均 `HTTP 200` + `connection: close` + `{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}` |
| 2 | 配置令牌后带 `x-legado-token` 重试三条，不再出现令牌错误 | PASS | `curl_b24_auth_apply_empty.txt`、`curl_b24_auth_apply_valid.txt`、`curl_b24_auth_mgmt.txt`、`curl_b24_auth_states.txt` | `apply` 传 `{}` 时已通过守卫、进入 body 反序列化返回 **422 missing field `url`**（非令牌错误）；传合法 `url` 返回 `200 {"error":"未找到订阅: ...","success":false}`；两条读面 `200 isSuccess=true` |
| 3 | 受保护读面响应头带 `Cache-Control: no-store` | PASS | 同上三条 curl 响应头 | 未授权与授权两次请求中，`getBookSourcesForManagement` / `getBookSourceCheckStates` 均返回 `cache-control: no-store`（失败与成功一致） |
| 4 | 导入含 jsLib/变量/规则的书源并记录内容 | PASS | `qa24_rich_source.json`、`curl_b24_seed_sources.txt`、`curl_b24_rich_baseline.json`、`b24_baseline_rich_meta.txt` | `jsLib_len=340`（含 `QA24_JSLIB_MARKER_9f3c`）；`variable="{\"qa24Var\":\"QA24_VARIABLE_MARKER_7b21\",...}"`；`ruleSearch` 9 键、`ruleBookInfo` 5 键、`ruleToc` 3 键、`ruleContent` 2 键；书源总数 2 |
| 5 | 用 `/api/sources` POST 同一 `bookSourceUrl`（带令牌）→ 409 | PASS | `curl_b24_duplicate_409.txt`、`qa24_dup_body.json` | `HTTP/1.1 409 Conflict`，`{"error":"书源 URL 已存在：https://qa24.example.com/source/rich；如需修改请使用 PUT /api/sources/{id}"}`；不带令牌的同 URL POST 则返回令牌错误（`curl_b24_duplicate_notoken.txt`） |
| 6 | 回 App 书源管理确认规则/jsLib/变量仍在 | PASS | `b24_sources_list.png`、`b24_rich_jslib.png`、`b24_rich_var.png`、`b24_after409_compare.txt`、`curl_b24_rich_after409.json` | 列表显示「QA24 富书源」仍在；编辑页可见 `jsLib` 全文（含 marker）、`header`、`variableComment`、搜索规则各字段；`variable` 值经 `/getBookSource` 复核原文一致（本轮编辑页未定位到 variable 值输入项，见 P3-3） |
| 7 | 添加规则订阅（宿主 HTTP 提供 2 条书源）并点「应用更新」 | PASS | `b24_sub_added.png`、`curl_b24_subs_initial.json`、`b24_sub_applied.png` | 订阅 `id=1`、`name=QA24-Sub`、`sub_type=bookSource`、`url=http://192.168.100.52:8899/qa24_sub.json`；应用后 Toast「更新完成：新增 2、更新 0、移除 0」 |
| 8 | 书源列表真的多了订阅书源，提示计数与实际一致 | PASS | `b24_sub_applied.png`、`b24_sources_list.png`、`curl_b24_mgmt_after_apply1.json`、`b24_after_apply1_compare.txt` | 书源总数 2→**4**；新增 `QA24 订阅源A`（sub-a）与 `QA24 订阅源B`（sub-b），各自带 jsLib/变量；与「新增 2」一致；订阅版本写为 `1800000001000-content-9170287e2abab812` |
| 9 | 不在订阅内的本地书源应用后仍存在 | PASS | 同上 + `curl_b24_mgmt_after_apply1.json` | `QA24 本地保留书源`（keep-local）仍在，`variable` 中 `QA24_LOCAL_KEEP_VALUE` 完好，验证「仅新增/更新、不删除本地条目」 |
| 10 | 再次应用更新应幂等 | PASS | `b24_sub_applied2.png`、`curl_b24_mgmt_after_apply2.json`、`b24_after_apply2_compare.txt` | Toast「更新完成：新增 0、更新 0、移除 0」；总数仍 4、unique URL 4、无重复 URL；富书源与本地保留源内容不变 |
| 11 | logcat 五项崩溃计数为 0 | PASS | `logcat_b24.txt`、`logcat_crash_b24.txt`、`logcat_counts_b24.txt` | FATAL EXCEPTION 0、E/AndroidRuntime 0、ANR 0、OutOfMemory 0、Low on memory 0；crash buffer 43 条 `Fatal signal 11 (SIGSEGV)` 全部 `Cmdline: uiautomator`，legado 引用 0 |
| 12 | 关闭 Web 服务、`pm clear`、终态截图 | PASS | `b24_web_off.png`、`final_state_b24.txt`、`b24_final.png` | 开关 OFF 后 `curl /api/health` 退出码 7（连接被拒）；`pm clear` 返回 `Success`；重启后 PID 25030、version 2.0.494+495 不变、书架空、端口仍关闭 |

## 四、关键证据

### 4.1 未授权请求的实际响应体（令牌未配置）

命令（原文，`apply` 使用任务给定的空对象 body）：

```bash
curl -s -i -X POST http://192.168.100.63:1122/api/rule-update/apply \
  -H "Content-Type: application/json" -d '{}'
curl -s -i http://192.168.100.63:1122/getBookSourcesForManagement
curl -s -i http://192.168.100.63:1122/getBookSourceCheckStates
```

三条响应完全同形（`curl_b24_unauth_apply.txt` / `curl_b24_unauth_mgmt.txt` / `curl_b24_unauth_states.txt`）：

```http
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
x-content-type-options: nosniff
access-control-allow-methods: GET, POST
cache-control: no-store          # 仅两条受保护读面有；apply 为 POST 写面
connection: close
content-length: 88

{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}
```

| 端点 | HTTP | `isSuccess` | `errorMsg` | `data` | `connection: close` | `cache-control` |
|---|---|---|---|---|---|---|
| `POST /api/rule-update/apply` | 200 | false | Web 书源访问令牌未配置或不正确 | null | 有 | 无（写面，不要求） |
| `GET /getBookSourcesForManagement` | 200 | false | 同上 | null | 有 | `no-store` |
| `GET /getBookSourceCheckStates` | 200 | false | 同上 | null | 有 | `no-store` |

配置令牌 `testtoken123` 后（`curl_b24_auth_*.txt`）：

| 端点 / body | HTTP | 响应要点 | 是否仍为令牌错误 |
|---|---|---|---|
| `POST /api/rule-update/apply` `{}` | 422 | `missing field \`url\``（已通过守卫，进入 body 反序列化） | 否 |
| `POST /api/rule-update/apply` `{"url":"http://192.168.100.63:8899/sub.json"}` | 200 | `{"error":"未找到订阅: ...","success":false}` | 否 |
| `GET /getBookSourcesForManagement` | 200 | `{"isSuccess":true,...,"data":{"sources":[],"states":[]}}` + `no-store` | 否 |
| `GET /getBookSourceCheckStates` | 200 | `{"isSuccess":true,...,"data":{"sessionToken":null,"states":[]}}` + `no-store` | 否 |

### 4.2 409 后书源内容是否完好

```bash
curl -s -i -X POST http://192.168.100.63:1122/api/sources \
  -H "Content-Type: application/json" -H "x-legado-token: testtoken123" \
  --data-binary @qa24_dup_body.json
```

实际响应（`curl_b24_duplicate_409.txt`）：

```http
HTTP/1.1 409 Conflict
content-type: application/json
content-length: 117

{"error":"书源 URL 已存在：https://qa24.example.com/source/rich；如需修改请使用 PUT /api/sources/{id}"}
```

409 前后逐字段对比（`b24_after409_compare.txt`，基线 `curl_b24_rich_baseline.json`，复测 `curl_b24_rich_after409.json`）：

| 字段 | 结果 | 409 后实测 |
|---|---|---|
| `bookSourceUrl` / `bookSourceName` / `bookSourceGroup` | SAME | 未被覆盖为「OverwriteAttemptShouldFail」 |
| `jsLib` | SAME | 长度 340，`QA24_JSLIB_MARKER_9f3c` 仍在 |
| `variable` | SAME | `{"qa24Var":"QA24_VARIABLE_MARKER_7b21",...}` 原文 |
| `header` / `searchUrl` | SAME | `{"User-Agent":"QA24-UA/1.0"}` / `https://qa24.example.com/search?q={key}` |
| `ruleSearch` / `ruleBookInfo` / `ruleToc` / `ruleContent` | SAME | 四组规则键值逐项一致 |
| 书源总数 | 2 → 2 | 未产生重复行 |

App 侧人工核对：`b24_sources_list.png`（列表仍为 4 条，富书源在列）、`b24_rich_jslib.png`（编辑页 jsLib 全文、header、variableComment）、`b24_rich_var.png`（搜索规则 `.qa24-book`/`.qa24-name` 等字段完整）。

### 4.3 订阅应用后的书源数量变化与幂等

| 阶段 | 书源总数 | 明细 | 证据 |
|---|---|---|---|
| 应用前 | 2 | 富书源、本地保留书源 | `curl_b24_mgmt_baseline.json` |
| 第一次应用后 | **4** | + `QA24 订阅源A`、`QA24 订阅源B`；本地保留源与富书源未变 | `curl_b24_mgmt_after_apply1.json`、`b24_after_apply1_compare.txt`、`b24_sub_applied.png` |
| 第二次应用后 | 4 | unique URL 4，重复 URL `[]`；Toast「新增 0、更新 0、移除 0」 | `curl_b24_mgmt_after_apply2.json`、`b24_after_apply2_compare.txt`、`b24_sub_applied2.png` |

订阅记录版本：`1800000001000-content-9170287e2abab812`（数组取最大 `lastUpdateTime` + 内容指纹），`last_update=1794521251228`（`curl_b24_subs_after_apply1.json`）。

### 4.4 logcat 计数

采集命令：

```bash
adb -s 192.168.100.63:5555 logcat -d -v time > logcat_b24.txt
adb -s 192.168.100.63:5555 logcat -b crash -d -v time > logcat_crash_b24.txt
```

| 计数项 | 值 |
|---|---|
| `FATAL EXCEPTION` | 0 |
| `E/AndroidRuntime` | 0 |
| `ANR in` | 0 |
| `OutOfMemory` | 0 |
| `Low on memory` | 0 |
| crash buffer 行数 / SIGSEGV | 948 / 43（全部 `Cmdline: uiautomator`） |
| crash buffer 中 `io.legado` 引用 | 0 |

## 五、问题分级

### P3-1（环境/工具问题，非应用缺陷）：uiautomator 原生 SIGSEGV

- 现象：crash buffer 中 43 条 `Fatal signal 11 (SIGSEGV)`，`Cmdline` 全部为 `uiautomator`，0 条引用 `io.legado.flutter_legado`（`logcat_crash_b24.txt`）。
- 影响：本轮 `uiautomator dump` 与截图流程均成功，不影响验收结论；若门禁把 crash buffer 任意 SIGSEGV 计为设备崩溃，需排除工具进程。五项应用崩溃计数为 0。
- 同类观察见批23报告 P3-2。

### P3-2（验收口径说明，非缺陷）：带令牌后 `apply {}` 返回 422

- 现象：配置令牌后重发任务给定的 `-d '{}'` 得到 `422 Unprocessable Entity: missing field \`url\``，而非 200。
- 定位：这是守卫放行后进入 `ApplyUpdateRequest` 反序列化的正常结果（`rust/legado-server/src/handlers/rule_update.rs:56`，`url` 为必填），证明请求已越过令牌层；使用合法 `url` 时返回 `200 {"error":"未找到订阅: ...","success":false}`。
- 结论：非产品缺陷；验收判断以「不再返回令牌错误」为准。

### P3-3（UI 观察项，非缺陷）：书源编辑页本轮未定位到 `variable` 值输入项

- 现象：编辑页「基本信息」可见 `variableComment`，滚动过的区域未找到 `variable` 内容输入项；`jsLib`、`header`、规则字段均可见。
- 影响：变量完整性通过 `GET /getBookSource?url=`（公共读面）与 `GET /getBookSourcesForManagement`（令牌读面）逐字复核，均为原文；不影响数据保护结论。
- 建议：后续确认 `variable` 的编辑/只读展示入口（非本批阻塞）。

## 六、设备终态

| 项目 | 终态 |
|---|---|
| Web 服务 | OFF（`b24_web_off.png`）；`curl http://192.168.100.63:1122/api/health` 退出码 7（连接被拒） |
| `pm clear` | `Success` |
| 应用进程 | 重启后 PID 25030 |
| 版本 | 2.0.494 / versionCode 495（`lastUpdateTime=2026-11-13 05:59:59`） |
| 数据 | 书架空（`b24_final.png`）；令牌、书源、订阅均已被 `pm clear` 清除 |
| 宿主订阅服务 | 已停止 |

## 七、门禁引用与证据清单

### 7.1 代码/契约门禁

- `docs/API_CONTRACT.md` 2026-11-13 两条批24 登记：`/api/sources` 写面纳入令牌守卫、重复 POST 409、受保护读面 `no-store`、订阅 apply 真实 upsert 且不删除本地条目、按 `lastUpdateTime` 门控。
- `rust/legado-server/src/legacy/source_write_api.rs`：`PROTECTED_SOURCE_WRITE_ROUTES` 共 23 条，含 `/api/rule-update/{check,apply}` 方法级条目与 `/api/sources` 四条。
- `rust/legado-server/src/handlers/source.rs`：`create_source` 先 `find_by_url` 命中即 `StatusCode::CONFLICT`；`update_source` 部分更新。
- `rust/legado-server/src/handlers/rule_update.rs`：`apply_update` 调用 `legado_db::apply_rule_subscription`，返回 `items_added/items_updated/items_removed`。
- `rust/legado-server/src/legacy/source_check_api.rs`：`getBookSourcesForManagement` / `getBookSourceCheckStates` handler 前置 `has_valid_token`，`no-store` 由 `web_assets::with_api_headers` 追加。
- `rust/legado-db/src/rule_sub_apply.rs`：订阅 upsert 单实现（事务、仅新增/更新、不删除）。

### 7.2 证据文件（均在 `docs/materials_1113c/`）

- 未授权/授权 curl：`curl_b24_unauth_apply.txt`、`curl_b24_unauth_mgmt.txt`、`curl_b24_unauth_states.txt`、`curl_b24_auth_apply_empty.txt`、`curl_b24_auth_apply_valid.txt`、`curl_b24_auth_mgmt.txt`、`curl_b24_auth_states.txt`
- 令牌界面：`b24_token_empty.png`、`b24_token_set.png`、`ui_b24_token_empty.xml`、`ui_b24_token2.xml`（对话框与输入框节点）
- 书源基线/409：`qa24_rich_source.json`、`qa24_local_keep_source.json`、`qa24_seed_sources.json`、`curl_b24_seed_sources.txt`、`curl_b24_rich_baseline.json`、`b24_baseline_rich_meta.txt`、`qa24_dup_body.json`、`curl_b24_duplicate_409.txt`、`curl_b24_duplicate_notoken.txt`、`curl_b24_rich_after409.json`、`curl_b24_mgmt_after409.json`、`b24_after409_compare.txt`
- App 书源管理：`b24_sources_list.png`、`b24_rich_editor2.png`、`b24_rich_jslib.png`、`b24_rich_var.png`
- 订阅：`host_http/qa24_sub.json`、`b24_sub_added.png`、`curl_b24_subs_initial.json`、`b24_sub_applied.png`、`b24_sub_applied2.png`、`curl_b24_mgmt_after_apply1.json`、`curl_b24_mgmt_after_apply2.json`、`curl_b24_subs_after_apply1.json`、`b24_after_apply1_compare.txt`、`b24_after_apply2_compare.txt`
- 稳定性/终态：`logcat_b24.txt`、`logcat_crash_b24.txt`、`logcat_counts_b24.txt`、`b24_web_off.png`、`final_state_b24.txt`、`b24_final.png`
- UI dump：`ui_b24_*.xml`（关键节点与坐标留痕）

### 7.3 复现命令速查

```bash
# 未授权
curl -s -i -X POST http://192.168.100.63:1122/api/rule-update/apply \
  -H "Content-Type: application/json" -d '{}'
curl -s -i http://192.168.100.63:1122/getBookSourcesForManagement
curl -s -i http://192.168.100.63:1122/getBookSourceCheckStates

# 授权
curl -s -i -X POST http://192.168.100.63:1122/api/rule-update/apply \
  -H "Content-Type: application/json" -H "x-legado-token: testtoken123" \
  -d '{"url":"http://192.168.100.63:8899/sub.json"}'
curl -s -i -H "x-legado-token: testtoken123" \
  http://192.168.100.63:1122/getBookSourcesForManagement

# 重复创建
curl -s -i -X POST http://192.168.100.63:1122/api/sources \
  -H "Content-Type: application/json" -H "x-legado-token: testtoken123" \
  --data-binary @qa24_dup_body.json

# 崩溃计数
adb -s 192.168.100.63:5555 logcat -d -v time | grep -c 'FATAL EXCEPTION'
adb -s 192.168.100.63:5555 logcat -d -v time | grep -c 'E/AndroidRuntime'
adb -s 192.168.100.63:5555 logcat -d -v time | grep -c 'ANR in'
adb -s 192.168.100.63:5555 logcat -d -v time | grep -ci 'OutOfMemory'
adb -s 192.168.100.63:5555 logcat -d -v time | grep -ci 'Low on memory'
```

**验收结论：批24 三项 P1 修复在真实设备上全部达到验收标准（12/12 PASS），无失败、无阻塞；设备已恢复干净终态。**
