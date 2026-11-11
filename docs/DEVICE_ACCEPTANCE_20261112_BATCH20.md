# 设备验收报告 — 批20「图片 action 执行 + 净化语义统一」

- 验收日期：2026-11-12
- 验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
- 验收对象：APK `2.0.490+491`（versionName=2.0.490，versionCode=491）
- 依据：
  - `docs/API_CONTRACT.md:12`（批20：图片 click/js action 执行通道 + Web/App 净化语义统一，§2.21 新增 `evalImageAction`）
  - `docs/API_CONTRACT.md:981`（§2.21 `evalImageAction` 语义：source/book/chapter/result/baseUrl/java 绑定）
  - `docs/API_CONTRACT.md:759-765`（批20-B：Web 与 App 正文净化配置面统一到 App 侧，保留去重标题既有差异）
  - 提交：`1e4007e95a`（Rust 图片动作预载 jsLib/收集 UI 副作用/源作用域）、`8f1b5ff8a3`（UI 完整 src + toast 可见提示）、`7130012255`（2.0.490+491 双日志）

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器 `192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | `SM-G9900`（MuMu 模拟），Android 15（API 35） |
| 分辨率 / 密度 | `1080x1920`，`480dpi`（360dp 宽） |
| ABI | `x86_64`（`primaryCpuAbi=x86_64`） |
| 被测包 | `io.legado.flutter_legado` 2.0.490+491，`minSdk=24`、`targetSdk=36`，`lastUpdateTime=2026-11-12 03:11:54` |
| APK 路径 / SHA-256 | `/data/app/~~rdQ59oXvjRG6sPllihbK8g==/io.legado.flutter_legado-Z37FB8fC7IxhaCnLKp230A==/base.apk`；实测 `47a71a456e7bc74078e60082c01e3dca4fa1bf34dbbd6802ae9853ccb742a067`（与任务给定值一致） |
| 宿主 | Windows，局域网 `192.168.100.52/24`，与设备同网段（设备 `ping` 实测可达） |
| 宿主 HTTP | `python -m http.server 8091 --bind 0.0.0.0`，文档根 `C:/Users/admin/AppData/Local/Temp/qa_b20/http`（放 `t.png` 等夹具） |
| Web 服务 | 应用内开关开启后监听 `0.0.0.0:1122`，`/api/health` 从宿主可达 |
| 测试书（本地） | `tmp_qb20_book.txt`（307 B，UTF-8，2 章）；第 1 章含 `<img src="http://192.168.100.52:8091/t.png">`，第 1/2 章含 `12 34 56`、`100 200 300`、`7 8 9`、`0 与 2` 等数字样本 |
| 测试书（在线） | 宿主夹具 `book1.html` + `chapter1.html`，章节图 src 携带复合动作：`t.png,{"click":"java.put('qa20_action_ran','yes'); java.toast('ACTION-CLICK-OK')"}` |
| 测试书源 | `qa_b20_source.json`（设备原无书源，本批构造本地 QA 源：`bookSourceUrl=http://192.168.100.52:8091`，`ruleToc`/`ruleContent` 指向本地夹具；经「书源管理 → 本地导入」导入） |
| 测试替换规则 | `JS double B20`：正则 `(\d+)` → `@js:String(Number(result)*2)`，仅「正文」，正则勾选，启用 |
| 证据目录 | `docs/materials_1112a/`（截图 `tmp_qb20_00.png` … `tmp_qb20_39.png`；日志 `logcat_b20.txt`、`logcat_b20_terminal.txt`、`crash_b20.txt`、`exitinfo_b20.txt`；curl 输出与夹具） |
| 输入法 | 取证期间临时启用 `com.android.adbkeyboard/.AdbIME` 以 Base64 广播输入 `(\d+)` 等符号；结束已恢复 Sogou 并禁用 AdbIME |

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 18 |
| FAIL | 0 |
| BLOCKED（清单项） | 0 |
| 合计 | 18 |

**结论：批20 设备验收 18 项全部通过。**

- 图片 action 通道在真实书源上下文下跑通：`<img src="...,{click:...}">` 点击后 Rust 日志记录 `图片动作收集到 1 个 UI 副作用：[{"action":"toast","message":"ACTION-CLICK-OK"}]`，App 同时弹出 `ACTION-CLICK-OK` SnackBar；档位 0/2 单击执行、档位 4 仅双击执行、档位 1 预览优先、档位 3 点击穿透，五档语义与 `resolveClickImgTap` 矩阵一致。
- 净化语义两端一致：同一条 `@js:String(Number(result)*2)` 规则下，本地书 App 正文为 `24 68 112 / 200 400 600 / 400 800 1200`，Web `/getBookContent` 返回逐字相同的数字；关闭「默认启用替换净化」后两端同时恢复原文 `12 34 56 / 100 200 300`。
- 全会话五项崩溃计数与 `OutOfMemory` 均为 0；Web 服务、宿主 HTTP 已关闭；`pm clear` 后应用回到空书架首启态。

验收边界（不构成失败）：

- 设备验收开始前**没有任何书源**（`tmp_qb20_01_book_sources.png`「暂无书源」）。为完成「真实 action」验证，本批在宿主起本地夹具并构造、导入了 QA 书源（加载真实书源行 + 书籍 + 章节 + JS 执行器链路），**不是**用真实互联网书源验证；该构造过程与结果均如实记录，未记 BLOCKED。
- 本地 TXT 无书源、`click`/`js` 为空，按任务口径只验证「不崩溃 + 回退预览/穿透」，不期望 action 执行。
- 取证期间为刷新书架做过一次 `am force-stop` + 冷启动（`03:22:52`，USER REQUESTED），不属于崩溃；`exitinfo_b20.txt` 无 crash/ANR 记录。

## 三、逐项验收

### A. 图片 action 执行（核心）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 导入含 `<img>` 的本地 TXT，图片可渲染、点图不崩溃 | PASS | `tmp_qb20_02_imported.png`、`tmp_qb20_06_local_book_chapter1.png`、`logcat_b20.txt` | 书架「更多 → 添加本地」导入 `tmp_qb20_book.txt`，Toast「已导入 1 本书籍」；第 1 章图片经宿主 `http://192.168.100.52:8091/t.png` 正常加载（QA-B20 样图，400x300）；打开/翻页/点图全程无崩溃 |
| 2 | 设置 → 阅读界面 →「点击图片方式」五档可切换 | PASS | `tmp_qb20_03_click_img_way_default.png`、`tmp_qb20_04_click_img_way_options.png` | 默认值「兼容旧版」；下拉完整展示「默认行为 / 预览图片 / 兼容旧版 / 关闭点击 / 双击生效」五档，逐档选中后行副标题同步更新（`05/08/18/21/25`） |
| 3 | 档位 1（预览图片）：本地书点图弹出预览 | PASS | `tmp_qb20_05_way1_selected.png`、`tmp_qb20_07_way1_preview.png` | 点图弹出全屏预览（关闭/保存图片），无动作执行；本地书无书源时按预期回退预览 |
| 4 | 档位 1（预览图片）：在线书含 action 仍预览优先 | PASS | `tmp_qb20_23_way1_selected_online.png`、`tmp_qb20_24_way1_online_preview.png`、`logcat_b20.txt` | 点图只弹预览；动作日志计数在点击前后保持 2 → 2，未执行 action |
| 5 | 档位 3（关闭点击）：点图无预览/无动作（穿透） | PASS | `tmp_qb20_08_way3_selected.png`、`tmp_qb20_09_way3_tap_no_preview.png` | 点图后无预览弹窗、无 action；点击穿透给页面，阅读菜单出现（原版 handled=false 语义） |
| 6 | 档位 2（兼容旧版）：在线书点击执行 action | PASS | `tmp_qb20_21_way2_selected.png`、`tmp_qb20_22_way2_action_toast.png`、`logcat_b20.txt` | 点击图片弹出 `ACTION-CLICK-OK` SnackBar；`03:24:41.866` Rust warn 记录 1 个 toast UI 副作用 |
| 7 | 档位 0（默认行为）：在线书点击执行 action | PASS | `tmp_qb20_18_way0_selected.png`、`tmp_qb20_20_way0_action_toast.png`、`logcat_b20.txt` | 点击图片弹出 `ACTION-CLICK-OK`；`03:23:51.436` Rust warn 记录执行 |
| 8 | 档位 4（双击生效）：单击消费不动作、双击执行 action | PASS | `tmp_qb20_25_way4_selected.png`、`tmp_qb20_26_way4_single_tap.png`、`tmp_qb20_27_way4_double_tap_action.png`、`logcat_b20.txt` | 单击后日志 2 → 2、无 Toast；双击后 2 → 3、弹出 `ACTION-CLICK-OK`（`03:26:20.049`），符合双击档矩阵 |
| 9 | 真实书源 action 执行通道（执行与 UI 副作用） | PASS | `tmp_qb20_10_source_imported.png`、`tmp_qb20_11_source_saved.png`、`tmp_qb20_20_way0_action_toast.png`、`logcat_b20.txt` | 设备原无书源；构造 QA 源导入后，经 `/saveBook` 种书、`/getChapterList` 拉目录（`tmp_qb20_15_curl_chapterlist.txt`）、`/getBookContent` 取正文（`tmp_qb20_16_curl_content_online.txt`，返回含 click action 的 img），App 阅读器点击图片触发 `evalImageAction`，Rust 日志记录 UI 副作用（§4.1）。说明：设备侧证明「执行链路 + java 命名空间 + 副作用收集」；`source/book/chapter/result/baseUrl` 逐字段绑定由 Rust 单测覆盖，本次未在设备上逐字段断言 |

### B. 净化语义统一（Web vs App）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 10 | 创建 `(\d+)` → `@js:String(Number(result)*2)` 正文替换规则并启用 | PASS | `tmp_qb20_28_replace_rules_page.png`、`tmp_qb20_29b_rule_filled_scope.png`、`tmp_qb20_30_rule_saved.png` | 规则名 `JS double B20`；表单实测 `(\d+)` / `@js:String(Number(result)*2)`，「正文」chip 选中、正则勾选；保存后列表项开关为启用态 |
| 11 | App 阅读本地书：数字翻倍 | PASS | `tmp_qb20_31_app_reader_rule_on.png` | 正文实测：`批40图片点击测试正文。数字样本一：24 68 112。`；`数值 200 400 600，期望变为 400 800 1200`；第 2 章 `另一段起始数值 14 16 18`、`结尾数值 0 与 4，期望为 0 与 8` |
| 12 | Web `/getBookContent`：数字翻倍 | PASS | `tmp_qb20_32_curl_web_rule_on.txt` | 返回：`批40图片点击测试正文。数字样本一：24 68 112。…图片下方段落：数值 200 400 600，期望变为 400 800 1200。` |
| 13 | App 与 Web 两端结果一致 | PASS | `tmp_qb20_31_app_reader_rule_on.png` + `tmp_qb20_32_curl_web_rule_on.txt` | 两端数字逐字一致（`24 68 112` / `200 400 600` / `400 800 1200`）；规则执行侧同为共享 `legado-js` 执行器 |
| 14 | 关闭「默认启用替换净化」后 App 恢复原文 | PASS | `tmp_qb20_34_replace_default_on.png`、`tmp_qb20_35_replace_default_off.png`、`tmp_qb20_37_app_reader_rule_off.png` | 设置 → 高级 → 其他设置 →「默认启用替换净化」由开转关；重新打开本地书显示原文 `12 34 56`、`100 200 300`、`7 8 9`、`0 与 2` |
| 15 | 同一时刻 Web 也恢复原文 | PASS | `tmp_qb20_36_curl_web_rule_off.txt` | 同一 `bookUrl`/`index=0` 返回原文 `数字样本一：12 34 56。`、`数值 100 200 300…`，与 App 一致 |

### C. 稳定性与终端状态

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 16 | logcat 五项崩溃计数=0、OutOfMemory=0 | PASS | `logcat_b20.txt`（13,011 行）、`logcat_b20_terminal.txt`（13,931 行）、`crash_b20.txt`、`exitinfo_b20.txt` | 两份日志实测均为：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`RenderFlex overflowed`=0、`E AndroidRuntime`=0、`OutOfMemory`=0；crash buffer 中 `Cmdline: io.legado…`=0（145 条 tombstone 全为 `Cmdline: uiautomator`）；exit-info 仅 USER REQUESTED（主动 force-stop）与 PACKAGE UPDATED，无 crash/ANR |
| 17 | 关闭 Web 服务 + 停止宿主 HTTP | PASS | `tmp_qb20_38_web_service_off_check.txt`、`tmp_qb20_33_web_service_state.png` | 应用内开关关闭后行恢复「用浏览器写源或看书」；宿主 `curl http://192.168.100.62:1122/api/health` exit 7（连接拒绝），设备 `/proc/net/tcp{,6}` 无 `:1122` LISTEN；宿主 8091 服务停止后 `curl` exit 28（超时） |
| 18 | `pm clear` 清理 + 终态截图 | PASS | `tmp_qb20_39_terminal.png` | `pm clear io.legado.flutter_legado` 返回 `Success`；重新启动后书架为空态「书架还空着，先去搜索书籍或从发现里添加吧！」，`pidof` 新 PID `23455`；`/sdcard/Download` 测试文件已删除；`font_scale=1.0`；输入法已恢复 Sogou |

## 四、关键取证摘要

### 4.1 图片 action 真实执行（核心）

测试图片的复合 src：

```
http://192.168.100.52:8091/t.png,{"click":"java.put('qa20_action_ran','yes'); java.toast('ACTION-CLICK-OK')"}
```

Rust 侧 `evalImageAction` 执行后 logcat（tag `legado-rust`）实测三行（分别对应档位 0、2、4 双击）：

```
11-12 03:23:51.436 W/legado-rust(20971): [legado_ffi::api::image_action_api] 图片动作收集到 1 个 UI 副作用（契约未回传，仅日志）：[{"action":"toast","message":"ACTION-CLICK-OK"}]
11-12 03:24:41.866 W/legado-rust(20971): [legado_ffi::api::image_action_api] 图片动作收集到 1 个 UI 副作用（契约未回传，仅日志）：[{"action":"toast","message":"ACTION-CLICK-OK"}]
11-12 03:26:20.049 W/legado-rust(20971): [legado_ffi::api::image_action_api] 图片动作收集到 1 个 UI 副作用（契约未回传，仅日志）：[{"action":"toast","message":"ACTION-CLICK-OK"}]
```

App 侧同时弹出 `ACTION-CLICK-OK` SnackBar（`tmp_qb20_20_way0_action_toast.png`、`tmp_qb20_22_way2_action_toast.png`、`tmp_qb20_27_way4_double_tap_action.png`）。注意：SnackBar 文案来自 `clickImgToastHint` 静态提取，**执行证明以 Rust warn 日志为准**；两者同时出现，且单击（档位 4）/预览（档位 1）时日志计数不增加，形成对照。

### 4.2 五档矩阵实际行为

| 档位 | 在线书（有 action，实测） | 本地 TXT（无 action） |
| --- | --- | --- |
| 0 默认行为 | 单击执行 action（toast + 日志） | 未单独实测（代码矩阵为无 action → 穿透） |
| 1 预览图片 | 单击预览（不执行 action） | 单击预览（实测） |
| 2 兼容旧版 | 在线文本且 click 非空 → 执行 action | 未单独实测（代码矩阵为非在线文本 → 穿透） |
| 3 关闭点击 | 穿透（阅读菜单出现） | 穿透（阅读菜单出现，实测） |
| 4 双击生效 | 单击消费无动作；双击执行 action | 未单独实测（代码矩阵为单击消费、双击无 click → 预览） |

### 4.3 净化一致性（原文对照）

规则开启（App 与 Web 同文）：

```
App : 批40图片点击测试正文。数字样本一：24 68 112。
Web : 批40图片点击测试正文。数字样本一：24 68 112。
App : 图片下方段落：数值 200 400 600，期望变为 400 800 1200。
Web : 图片下方段落：数值 200 400 600，期望变为 400 800 1200。
```

规则总开关关闭后（App 与 Web 同文）：

```
App : 批20图片点击测试正文。数字样本一：12 34 56。
Web : 批20图片点击测试正文。数字样本一：12 34 56。
App : 图片下方段落：数值 100 200 300，期望变为 200 400 600。
Web : 图片下方段落：数值 100 200 300，期望变为 200 400 600。
```

### 4.4 稳定性数值

| 检查项 | `logcat_b20.txt` | `logcat_b20_terminal.txt` |
| --- | --- | --- |
| `FATAL EXCEPTION` | 0 | 0 |
| `ANR in` | 0 | 0 |
| `E/flutter` | 0 | 0 |
| `RenderFlex overflowed` | 0 | 0 |
| `E AndroidRuntime` | 0 | 0 |
| `OutOfMemory` | 0 | 0 |
| crash buffer `Cmdline: io.legado…` | — | 0（`crash_b20.txt`，145 条均为 uiautomator） |

## 五、问题分级

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| P0（阻塞） | 0 | — |
| P1（严重） | 0 | — |
| P2（重要） | 0 | — |
| P3（观察/登记） | 5 | 见下 |

1. **P3 环境边界｜设备无既有书源，action 验证依赖构造源**：验收前「我的 → 书源管理」为空（`tmp_qb20_01_book_sources.png`）。本批构造了本地 QA 书源（夹具 HTML + `qa_b20_source.json`）并完成真实执行链路；不是真实互联网书源。若后续需要真实站点覆盖，需另行提供可用书源与网络环境。
2. **P3 测试素材｜广域数字正则同时改写 img URL/动作 JSON**：规则 `(\d+)` 作用于整段正文，图片 URL 中的 `192.168.100.52:8091` 在净化后变为 `384.336.200.104:16182`（App/Web 一致），动作文案 `qa20_action_ran` 变为 `qa40_action_ran`。这是规则作用域与测试素材共同决定的预期现象（任务指定的规则本身如此），非产品缺陷；实际使用中应通过更精确的正则或规则作用域避免误伤 URL。
3. **P3 工具环境｜Git Bash 会转换 `--data-urlencode "url=/data/..."` 的前导斜杠**：未设置 `MSYS_NO_PATHCONV=1` 时，Web `/getChapterList`/`/getBookContent` 对本地书返回「未在数据库找到对应书籍」；设置该环境变量后同一请求返回 `isSuccess=true` 与正确章节/正文。属取证工具问题，非产品缺陷，记录以免复测踩坑。
4. **P3 工具噪声｜uiautomator tombstone**：`crash_b20.txt` 中 145 条 tombstone 均为 `Cmdline: uiautomator`（shell UID 2000），无 legado 进程；与批17/19 记录一致，不计入崩溃。
5. **P3 误触记录｜MCP 服务未配置令牌的预期失败提示**：导航时误触「MCP 服务」行，界面提示「MCP 服务切换失败…请先在设置 → 高级 → 其他设置配置 Web 书源访问令牌」；属未配置令牌时的既有防御行为，与本批图片 action/净化无关，未影响验收。

## 六、设备终态

| 项目 | 终态 |
| --- | --- |
| Web 服务 | 已关闭；宿主 `curl http://192.168.100.62:1122/api/health` exit 7（连接拒绝）；设备无 `:1122` LISTEN（`tmp_qb20_38_web_service_off_check.txt`） |
| 宿主 HTTP 8091 | 已停止；`curl http://192.168.100.52:8091/t.png` exit 28（超时），无响应 |
| 应用数据 | `pm clear io.legado.flutter_legado` → `Success`；重新启动后空书架首启态（`tmp_qb20_39_terminal.png`），`pidof` 新 PID 23455 |
| 外部测试文件 | `/sdcard/Download/tmp_qb20_book.txt` 与 `qa_b20_source.json` 已删除 |
| 字体缩放 | `font_scale=1.0` |
| 输入法 | 已恢复 `com.sohu.inputmethod.sogou.chuizi/...SogouIME`；`com.android.adbkeyboard/.AdbIME` 已禁用 |
| 崩溃计数 | 五项与 OOM 均为 0（`logcat_b20.txt`、`logcat_b20_terminal.txt` 复核一致） |
| 应用安装态 | `io.legado.flutter_legado` 2.0.490+491 仍安装，`primaryCpuAbi=x86_64` |

## 七、门禁引用

- `AGENTS.md:23`：Flutter 门禁为 `flutter_legado/` 下 `flutter analyze && flutter test`（CI：`.github/workflows/flutter-ci.yml`）。本批为 CI 覆盖不到的设备验收（真机 UI 交互、书源 action、Web 服务实网请求），未改代码，不重复静态门禁。
- `AGENTS.md:65`：每轮修复后两级验证（测试档模拟器 → 用户验收档）；本次在 MuMu「Test测试」实例执行。
- `AGENTS.md:77`：CI 能覆盖的验证以 CI 结果为准；角色只用于实机冒烟、UI 交互、跨模块手动复现。
- `AGENTS.md:79`：子代理自述（无独立证据）不构成验收依据；本报告每项均附截图/命令输出/日志路径。
- 契约口径：`docs/API_CONTRACT.md:981`（`evalImageAction` 绑定与失败降级）、`docs/API_CONTRACT.md:759-765`（批20-B 配置面统一与既有去重标题差异）。
- 崩溃五项口径沿用批11–批19 设备验收：`FATAL EXCEPTION` / `ANR in` / `E/flutter` / `RenderFlex overflowed` / `E AndroidRuntime`（并加 `OutOfMemory`）。
- APK 指纹与任务给定值一致（`47a71a45…b742a067`），确认验收对象正确。

## 八、复现命令（摘要）

```bash
export PATH="$PATH:/d/Program Files/MuMuPlayer/nx_main"; export MSYS_NO_PATHCONV=1
ADB="adb -s 192.168.100.62:5555"
$ADB logcat -c
# 宿主：启动夹具 HTTP（文档根含 t.png/book1.html/chapter1.html/qa_b20_source.json）
cd C:/Users/admin/AppData/Local/Temp/qa_b20/http && python -m http.server 8091 --bind 0.0.0.0
# 设备：导入本地书/书源（UI：书架→更多→添加本地；我的→书源管理→更多→本地导入）
$ADB push tmp_qb20_book.txt /sdcard/Download/
$ADB push qa_b20_source.json /sdcard/Download/
# 种在线书并拉目录/正文（Web 服务需先在「我的 → Web 服务」开启）
curl -s -X POST http://192.168.100.62:1122/saveBook -H "Content-Type: application/json" --data-binary @save_book_b20.json
curl -s -G http://192.168.100.62:1122/getChapterList --data-urlencode "url=http://192.168.100.52:8091/book1.html"
curl -s -G http://192.168.100.62:1122/getBookContent --data-urlencode "url=http://192.168.100.52:8091/book1.html" --data-urlencode "index=0"
# 净化一致性：本地书 bookUrl 从 /getBookshelf 取，注意 MSYS_NO_PATHCONV=1
curl -s -G http://192.168.100.62:1122/getBookContent --data-urlencode "url=/data/user/0/io.legado.flutter_legado/cache/file_picker/<ts>/tmp_qb20_book.txt" --data-urlencode "index=0"
# 终态
curl -s http://192.168.100.62:1122/api/health; echo "exit=$?"   # 期望非 0（连接拒绝）
$ADB shell pm clear io.legado.flutter_legado
```

## 九、证据清单（`docs/materials_1112a/`）

| 文件 | 用途 |
| --- | --- |
| `tmp_qb20_00_initial.png` | 基线：空书架、无书源 |
| `tmp_qb20_01_book_sources.png` | 书源管理空态（设备无既有书源） |
| `tmp_qb20_02_imported.png` | 本地 TXT 导入成功（已导入 1 本书籍） |
| `tmp_qb20_03/04/05` | 点击图片方式默认值、五档下拉、档位 1 选中 |
| `tmp_qb20_06/07` | 本地书图片渲染、档位 1 预览弹窗 |
| `tmp_qb20_08/09` | 档位 3 选中、点图穿透（无预览） |
| `tmp_qb20_10/11` | QA 书源导入预览、导入后列表 |
| `tmp_qb20_12` | Web 服务通知权限弹窗（开启流程） |
| `tmp_qb20_13`–`17` | health / saveBook / getChapterList / 在线正文 / 书架 curl 输出 |
| `tmp_qb20_18/20` | 档位 0 选中、点击 action Toast |
| `tmp_qb20_19` | 在线书章节（图片 + 正文） |
| `tmp_qb20_21/22` | 档位 2 选中、点击 action Toast |
| `tmp_qb20_23/24` | 档位 1（在线含 action）选中、预览优先 |
| `tmp_qb20_25/26/27` | 档位 4 选中、单击无动作、双击 action Toast |
| `tmp_qb20_28/28b/29/29b/30` | 替换规则空态、表单填写、正文范围选中、保存后启用 |
| `tmp_qb20_31` | App 阅读：数字翻倍 |
| `tmp_qb20_32` | Web `/getBookContent`：数字翻倍 |
| `tmp_qb20_33` | Web 服务关闭态 |
| `tmp_qb20_34/35` | 「默认启用替换净化」开/关 |
| `tmp_qb20_36` | Web 规则关闭后恢复原文 |
| `tmp_qb20_37` | App 规则关闭后恢复原文 |
| `tmp_qb20_38_web_service_off_check.txt` | Web 服务关闭后的 curl exit 7 |
| `tmp_qb20_39_terminal.png` | `pm clear` 后空书架终态 |
| `logcat_b20.txt` / `logcat_b20_terminal.txt` | 全会话/终态 logcat |
| `crash_b20.txt` / `exitinfo_b20.txt` | crash buffer 与 exit-info |
| `tmp_qb20_book.txt` / `qa_b20_source.json` / `save_book_b20.json` / `t.png` | 测试夹具（可复现） |

---

编写者：QA 子代理 ｜ 2026-11-12
