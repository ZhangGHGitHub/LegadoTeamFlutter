# 设备验收报告 — 批21「图片动作引擎缓存 + UI action 回传 + 文件访问门控收紧」

- 验收日期：2026-11-12（21:04 结束）
- 验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
- 验收对象：APK `2.0.491+492`（versionName=2.0.491，versionCode=492）
- 依据：
  - `docs/API_CONTRACT.md:981`（§2.21 `evalImageAction`：批21-A 返回值扩展为 UI action 信封、按书源 LRU 缓存引擎、degraded 不入缓存）
  - `rust/legado-js/src/host_api/fs_policy.rs:1-38`（批21-B：`allow_file_access=false` 下 archive/font 本地路径白名单与显式错误语义）
  - 提交：`b3be067491`（perf：按书源缓存图片动作 JS 引擎并复用 jsLib）、`4409394785`（degraded 不缓存/锁加固）、`263734adde`（UI 副作用回传 Dart 并按类型回放）、`f679ff145f`（外链改走桥接策略 + scheme 白名单）、`80864857d8`（allow_file_access=false 收紧 archive/font 本地路径）、`54eb20e2f9`（RAR 条目路径收紧 + 字体 file:// 预检）、`7686a14eed`（契约）、`67853e0de1`（2.0.491+492 收尾）

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器 **`192.168.100.63:5555`**（`adb devices` 状态 `device`） |
| 设备地址变更 | 任务指定新地址 `.63`；**旧地址 `192.168.100.62:5555` 已不可用，本报告全部取证均基于 `.63`** |
| 机型 / 系统 | `SM-G9900`（MuMu 模拟，厂商 Samsung），Android 15（API 35） |
| 分辨率 / 密度 | `1080x1920`，`480dpi`（360dp 宽） |
| ABI | `x86_64`（`primaryCpuAbi=x86_64`） |
| 被测包 | `io.legado.flutter_legado` 2.0.491+492，`minSdk=24`、`targetSdk=36`，`lastUpdateTime=2026-11-12 20:38:31` |
| APK 路径 / SHA-256 | `/data/app/~~FUILbJr5EgLPYvK-SVYPVw==/io.legado.flutter_legado-Fq9UI0LXZAhFGkZ0Ig7nBQ==/base.apk`；实测 `e3c92219f1d18536102bdbd4d753302742c8f6c5636e72789d423835cbf0a31c`（与任务给定值一致） |
| 宿主 | Windows，局域网 `192.168.100.52/24`（设备 `ping` 实测可达，0% 丢包） |
| 宿主 HTTP | `python -m http.server 8091 --bind 0.0.0.0`，文档根 `C:/Users/admin/AppData/Local/Temp/qa_b21/http`（夹具已复制到 `docs/materials_1112b/fixtures/`） |
| Web 服务 | 应用内开关开启后监听 `192.168.100.63:1122`，`/api/health` 返回 `{"service":"legado-server","status":"ok","version":"0.2.0"}`（仅用于种书/拉章，结束已关闭） |
| 测试书源 A | `QA批21图片动作源A`：`bookSourceUrl=http://192.168.100.52:8091/qa21a`，7 章；`jsLib` 为 URL 映射 `{"qa21lib":"http://192.168.100.52:8091/lib.js"}`（lib.js 720,071 B） |
| 测试书源 B | `QA批21图片动作源B`：`bookSourceUrl=.../qa21b`，1 章；无 `jsLib`；动作使用同名全局计数（验证多源隔离） |
| 测试书源 C | `QA批21图片动作源C`：`bookSourceUrl=.../qa21c`，1 章；**内联 jsLib 含 20,000,000 次循环**（首次加载实测 566ms，用于量化“首次 vs 缓存”） |
| 图片动作形状 | `<img src="http://192.168.100.52:8091/t.png,{"click":"<js>"}">`；各章见 `fixtures/qa21a/ch*.html` |
| 证据目录 | `docs/materials_1112b/`（83 个文件；截图 `tmp_qb21_00…67`、日志 `logcat_b21*.txt`、crash/exitinfo、夹具） |
| 设备显示 | 应用挂在 MuMu 独立逻辑 display 上；**每次 force-stop 后 logical/SF display id 变化**（本次依次 2→3→5→6），截图用 `screencap -p -d <SF id>`、输入用 `input -d <logical id>` |

**验收前设备非空**：验收开始时设备已有 **916 个书源**与 3 本书（`tmp_qb21_00_initial.png`、`tmp_qb21_01_source_mgmt.png`）。本批在宿主构造 3 个 QA 源并导入（A/B 导入后书源计数 916→918，`tmp_qb21_08_both_sources.png`；C 导入后书源列表可见 3 个 QA 源），验证结束后按任务要求执行 `pm clear`，上述预置数据被一并清除（见「六、设备终态」）。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 12 |
| FAIL | 0 |
| BLOCKED | 0 |
| 合计 | 12 |

**结论：批21 设备验收 12 项全部通过，无 P0/P1/P2 问题。**

- **引擎缓存（A）**：同源连点 3 次（实际 4 次）toast 计数 `#1→#4` 递增、`libAge` 从 1ms 增至 38,663ms，证明**同一引擎跨点击复用、jsLib 只加载一次**；大 jsLib 源实测首次加载 **566ms**，缓存点击不再支付该开销（`LOADMS` 恒 566、`AGE` 持续增大）；源 B 首次点击计数为 `#1`，多源隔离成立。
- **UI action 回传（B）**：`java.toast('A'+'B')` 实际弹出 **`AB`**（动态拼接值，非静态字面量）；`java.openUrl('https://example.com')` 弹出「跳转确认 / 正在请求跳转链接/应用，是否跳转？」+ URL，**不是静默跳转**；`java.openUrl('javascript:alert(1)')` 被白名单拒绝，**无弹窗、无跳转**，logcat 命中拒绝日志。
- **文件访问门控（C）**：`getRarStringContent(<RAR hex>,'../../etc/passwd')` 返回 `[ERROR] RAR 条目名非法（含非普通路径组件）`；`queryTTF('file:///etc/hosts')` 返回 `valid=false` + `文件访问被拒绝`；合法 `http` 字体返回 `valid=true type=url`（不回归）。
- **稳定性（D）**：主会话/终态日志五项崩溃计数与 `OutOfMemory` 均为 0；crash buffer 无 legado 进程；exit-info 仅有 USER REQUESTED（主动 force-stop）与 PACKAGE UPDATED。Web 服务、宿主 HTTP 均已关闭，`pm clear` 后回到空书架首启态。

## 三、逐项验收

### A. 图片动作引擎缓存（性能）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 构造/导入含图片 action 的 QA 书源 | PASS | `tmp_qb21_05_import_a.png`、`tmp_qb21_07_import_b_preview.png`、`tmp_qb21_08_both_sources.png`、`tmp_qb21_38_picker3.png`、`fixtures/qa21*_source.json` | 设备原无 QA 源（但有 916 个既有源）；经「书源管理 → 更多 → 本地导入」导入 A/B/C 三源，均显示「新增 → 导入完成」并处于开启态；A 源章节经 `/getChapterList` 返回 7 章（`tmp_qb21_66_api_snapshots.txt` §3），第 1 章正文含 `click` action（§4） |
| 2 | 打开图片章节，连续点击同一图片 3 次，每次出现 `ACTION-CLICK-OK` toast | PASS | `tmp_qb21_13_click1.png`、`tmp_qb21_14_click2.png`、`tmp_qb21_15_click3.png` | 源 A 第 1 章同图连点：toast 依次 `ACTION-CLICK-OK #1 libAge=1ms`、`#2 libAge=12398ms`、`#3 libAge=24377ms`；第 4 次误触点图仍正常（UI dump 捕获 `#4 libAge=38663ms`） |
| 3 | 首次点击有引擎创建耗时、后续点击明显更低（有日志则佐证） | PASS（附观测性说明） | `tmp_qb21_43_heavy_first_s1.png`、`tmp_qb21_44_heavy_first_s2.png`、`tmp_qb21_46_heavy_retry.png`、`tmp_qb21_49_cached_seq1.png`、`tmp_qb21_49_cached_seq3.png`、`tmp_qb21_67_click_timeline.txt` | **构建中成功路径无“图片动作”耗时日志**（批20 的 `图片动作收集到…` 日志已随信封回传移除），故用源 C 大 jsLib 直接量化：首次点击引擎创建阶段加载 jsLib **566ms**（`__loadMs()`），+386ms 截图尚无 toast；缓存点击 `LOADMS` 恒 566、`AGE` 33.7s→75.3s，toast 在 +425ms 内可见。3 次普通点击主观均即时响应、无可见卡顿。观测性缺口登记为 P3-1 |
| 4 | 切换到另一书源图片章节点击仍正常（多源隔离） | PASS | `tmp_qb21_33_bookB_ch1.png`、`tmp_qb21_34_sourceB_click.png` | 源 B 第 1 章点击得 `SOURCE-B ACTION-CLICK-OK #1`；此时源 A 计数已到 #4，且源 B 未加载 A 的 jsLib，证明不同 `bookSourceUrl` 各自独立引擎、互不复用 |

### B. UI action 回传（动态消息）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 5 | action `java.toast('A'+'B')` 点击应弹出 **AB** | PASS | `tmp_qb21_30_dynamic_toast_AB.png` | 源 A 第 2 章点击，SnackBar 文案精确为 `AB`（非 `'A'+'B'` 字面量），证明动作期间的动态消息经 Rust `ui_action_queue` 回传并由 Dart 回放 |
| 6 | `java.openUrl('https://example.com')` 应走统一链接策略，不静默跳转 | PASS | `tmp_qb21_19_openurl_https.png` | 源 A 第 3 章点击弹出「跳转确认 / 正在请求跳转链接/应用，是否跳转？ / https://example.com」+「取消 / 跳转」；点击「取消」后停留阅读页（`tmp_qb21_20_after_cancel.png`），未静默外跳 |
| 7 | 危险 scheme `javascript:alert(1)` 应无跳转、无弹窗，仅日志 | PASS | `tmp_qb21_21_openurl_javascript.png`（全量会话）、`tmp_qb21_57_fresh_openurl_js.png`（pm clear 后复验）、`logcat_b21_b7.txt:7` | 两轮点击后阅读页无任何弹窗/跳转；logcat 实测 `I/flutter: [image-action] openUrl 拒绝非白名单 URL（scheme=javascript）：javascript:alert(1)`（`logcat_b21_b7.txt` 第 7 行；时间 21:02:06.163） |

### C. 文件访问门控

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 8 | `getRarStringContent(<rarUrl>,'../../etc/passwd')` 应返回 `[ERROR]`/明确拒绝，不返回文件内容 | PASS | `tmp_qb21_23_rar_traversal.png`、`tmp_qb21_59_fresh_rar_traversal.png`、`fixtures/regression.rar` | 两轮（全量会话 + pm clear 后复验）toast 均为 `RAR[[ERROR] RAR 条目名非法（含非普通路径组件）]`；未返回任何文件内容。测试用 RAR4 十六进制样本（104B），`rar_entry_bytes` 在解析归档前先校验条目名，RAR 版本不影响该安全断言 |
| 9 | `queryTTF('file:///etc/hosts')` 应 `valid=false` + error，不读取 | PASS | `tmp_qb21_25_ttf_file_rejected.png`、`tmp_qb21_60_fresh_ttf_file.png` | 两轮 toast 均为 `TTFFILE valid=false err=文件访问被拒绝： /etc/h`（截断前 14 字符）；句柄 JSON 带 `valid:false` 与 `error` |
| 10 | 合法 http 字体 url 仍工作（不回归） | PASS | `tmp_qb21_27_ttf_http_ok.png`、`tmp_qb21_61_fresh_ttf_http.png` | 两轮 toast 均为 `TTFHTTP valid=true type=url`；字体为宿主提供的 `number.ttf`（6,000 B，含 cmap/glyf，来自 `app/src/main/assets/font/number.ttf`） |

### D. 稳定性与终态

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 11 | logcat 五项崩溃计数 = 0 + `OutOfMemory` = 0 | PASS | `logcat_b21.txt`（1,895 行，20:49:48–20:57:44）、`logcat_b21_terminal.txt`（终态）、`logcat_b21_fresh.txt`、`crash_b21.txt`、`crash_b21_terminal.txt`、`exitinfo_b21.txt`、`exitinfo_b21_terminal.txt` | 三份日志实测均为：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`RenderFlex overflowed`=0、`E AndroidRuntime`=0、`OutOfMemory`=0；crash buffer 中 `Cmdline: io.legado…`=0；exit-info 仅 `USER REQUESTED`（主动 force-stop）/`PACKAGE UPDATED`，无 crash/ANR 记录 |
| 12 | 关闭 Web 服务、停止宿主 HTTP、`pm clear` 清理 + 终态截图 | PASS | `tmp_qb21_51_web_service_off.png`、`tmp_qb21_63_web_service_off_check.txt`、`tmp_qb21_64_host_http_off_check.txt`、`tmp_qb21_62_terminal_final.png` | Web 服务关闭后开关回灰、副标题恢复「用浏览器写源或看书」；宿主 `curl http://192.168.100.63:1122/api/health` exit **7**，设备 `/proc/net/tcp{,6}` 中 `:1122` LISTEN 计数 0；宿主 8091 服务停止后 `curl` exit **7**；`pm clear io.legado.flutter_legado` 返回 `Success`，重启后空书架首启态（新 PID 6271），`/sdcard/Download` 的 qa21* 测试文件已删除，`font_scale=1.0` |

## 四、关键取证摘要

### 4.1 引擎缓存（A）

源 A 第 1 章动作：

```js
globalThis.__qa21_clicks=(globalThis.__qa21_clicks||0)+1;
var __age=(typeof __qa21_lib_ts==='number')?(Date.now()-__qa21_lib_ts):-1;
java.toast('ACTION-CLICK-OK #'+globalThis.__qa21_clicks+' libAge='+__age+'ms')
```

实测 toast（三次截图）：

```
ACTION-CLICK-OK #1 libAge=1ms
ACTION-CLICK-OK #2 libAge=12398ms
ACTION-CLICK-OK #3 libAge=24377ms
```

`libAge` 是 jsLib 顶层 `var __qa21_lib_ts = Date.now()` 到本次动作执行的毫秒差。若每次点击都重建引擎并重载 jsLib，该值应恒为 ~0ms；实测持续增大，同时点击计数连续递增 → **引擎与 jsLib 均被复用**。

源 C（内联 jsLib 含 `for (var i=0;i<20000000;i++)`）实测：

```
（首次点击，+211ms / +386ms 截图无 toast；由第二次点击 AGE 反推 __loadedAt≈20:55:59.879）
HEAVY LOADMS=566 AGE=33674ms result=566     ← 第二次点击（20:56:33）
HEAVY LOADMS=566 AGE=75301ms result=566     ← 第三次点击（20:57:15，+425ms 截图可见）
```

即首次点击在引擎创建阶段支付 **566ms** jsLib 加载开销，后续点击不再支付；`AGE` 随真实时间增长、`LOADMS` 恒定。

### 4.2 UI action 信封与回放（B）

- 动态 toast：`java.toast('A'+'B')` → SnackBar `AB`（`tmp_qb21_30_dynamic_toast_AB.png`）。该消息只能来自 Rust 信封 `{"_lgActions":true,"result":"...","actions":[{"action":"toast","message":"AB"}]}`，Dart 静态字面量提取无法得到 `AB`。
- 外链策略：`https://example.com` → 「跳转确认」对话框（`tmp_qb21_19_openurl_https.png`）；`javascript:alert(1)` → 白名单拒绝，阅读页不变（`tmp_qb21_57_fresh_openurl_js.png`），日志 `logcat_b21_b7.txt:7`。

### 4.3 文件门控（C）

| 调用 | 实际返回（toast 可见部分） | 期望 |
| --- | --- | --- |
| `getRarStringContent(<RAR hex>, '../../etc/passwd')` | `[ERROR] RAR 条目名非法（含非普通路径组件）` | 拒绝、不返回文件内容 |
| `queryTTF('file:///etc/hosts')` | `valid=false err=文件访问被拒绝： /etc/h…` | valid=false + error |
| `queryTTF('http://192.168.100.52:8091/number.ttf')` | `valid=true type=url` | 正常（不回归） |

### 4.4 稳定性数值

| 检查项 | `logcat_b21.txt` | `logcat_b21_terminal.txt` | `logcat_b21_fresh.txt` |
| --- | --- | --- | --- |
| `FATAL EXCEPTION` | 0 | 0 | 0 |
| `ANR in` | 0 | 0 | 0 |
| `E/flutter` | 0 | 0 | 0 |
| `RenderFlex overflowed` | 0 | 0 | 0 |
| `E AndroidRuntime` | 0 | 0 | 0 |
| `OutOfMemory` | 0 | 0 | 0 |
| crash buffer `Cmdline: io.legado…` | 0（`crash_b21.txt`） | 0（`crash_b21_terminal.txt`） | — |

## 五、问题分级

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| P0（阻塞） | 0 | — |
| P1（严重） | 0 | — |
| P2（重要） | 0 | — |
| P3（观察/环境） | 4 | 见下 |

1. **P3 观测性｜成功路径无“图片动作”运行时日志**：批21 起动作成功不再输出批20 的 `图片动作收集到 N 个 UI 副作用` 日志，`图片动作` 关键字只用于空动作/执行失败。设备上无法直接看到“引擎创建/缓存命中”事件，本批改用动作内时间戳与 `globalThis` 计数完成证明。建议后续补一条 debug 级缓存创建/命中日志（不影响本次验收）。
2. **P3 工具环境｜逻辑 display id 在 force-stop 后漂移**：本次应用 display 依次为 logical 2 / 3 / 5 / 6。用旧 SF display id 截图会返回 `Failed to take screenshot. Status: -2`（56 B 文件），必须每次重启后重查 `dumpsys window windows` 与 `dumpsys display`。属 MuMu 既有环境特性（`AGENTS.md` 已登记），非产品缺陷。
3. **P3 环境行为｜Web 服务开关为进程内状态**：force-stop 后 `/api/health` 从 ok 变为 exit 7；为刷新 `/saveBook` 种入的书架而重启应用后需重新开启。本次取证因此多了一次开关操作，属既有实现，不是本批缺陷。
4. **P3 范围边界｜验收前设备非空且终态被 pm clear**：设备原有 916 个书源、3 本书（`tmp_qb21_01_source_mgmt.png`、`tmp_qb21_11_shelf_after_seed.png`）。按 D12 执行 `pm clear` 后这些本地数据一并清除；另有一次主动 force-stop（20:45:58，USER REQUESTED，用于刷新书架）与 pm clear 后的复验轮次，均如实记录，不计为崩溃。

## 六、设备终态

| 项目 | 终态 |
| --- | --- |
| Web 服务 | 已关闭；宿主 `curl http://192.168.100.63:1122/api/health` exit 7；设备 `:1122` LISTEN 计数 0（`tmp_qb21_63_web_service_off_check.txt`） |
| 宿主 HTTP 8091 | 已停止；`curl http://192.168.100.52:8091/t.png` exit 7（`tmp_qb21_64_host_http_off_check.txt`） |
| 应用数据 | `pm clear io.legado.flutter_legado` → `Success`；重启后空书架首启态（`tmp_qb21_62_terminal_final.png`），`pidof` 新 PID 6271 |
| 外部测试文件 | `/sdcard/Download/qa21a_source.json`、`qa21b_source.json`、`qa21c_source.json` 已删除（`ls | grep qa21` 无匹配） |
| 字体缩放 | `font_scale=1.0` |
| 崩溃计数 | 五项与 OOM 均为 0（主会话/复验轮/终态日志一致） |
| 应用安装态 | `io.legado.flutter_legado` 2.0.491+492 仍安装，`primaryCpuAbi=x86_64`，APK SHA-256 与验收开始时一致 |
| 设备预置数据 | 原 916 个书源 + 3 本书已随 `pm clear` 清除（任务要求，见 P3-4） |

## 七、门禁引用

- `AGENTS.md:20-23`：Flutter 门禁为 `flutter_legado/` 下 `flutter analyze && flutter test`（CI：`.github/workflows/flutter-ci.yml`）。本批为 CI 覆盖不到的设备验收（真机 UI 交互、书源 action、字体/压缩包本地路径门控），未改代码，不重复静态门禁。
- `AGENTS.md:65`：每轮修复后两级验证（测试档模拟器 → 用户验收档）；本次在 MuMu「Test测试」实例执行。
- `AGENTS.md:77`：CI 能覆盖的验证以 CI 结果为准；角色只用于实机冒烟、UI 交互、跨模块手动复现。
- `AGENTS.md:79`：子代理自述（无独立证据）不构成验收依据；本报告每项均附截图/命令输出/日志路径。
- 契约口径：`docs/API_CONTRACT.md:981`（`evalImageAction` 返回值信封 `_lgActions`、按书源 LRU 缓存、degraded 不缓存）；`rust/legado-js/src/host_api/fs_policy.rs:1-38`（`allow_file_access=false` 下 archive/font 白名单与失败语义）。
- 崩溃五项口径沿用批11–批20 设备验收：`FATAL EXCEPTION` / `ANR in` / `E/flutter` / `RenderFlex overflowed` / `E AndroidRuntime`，并加 `OutOfMemory`。
- APK 指纹与任务给定值一致（`e3c92219…0a31c`），确认验收对象正确。

## 八、复现命令（摘要）

```bash
export PATH="$PATH:/d/Program Files/MuMuPlayer/nx_main"; export MSYS_NO_PATHCONV=1
ADB="adb -s 192.168.100.63:5555"
$ADB devices -l
# 宿主：启动夹具 HTTP（文档根含 t.png/number.ttf/lib.js/qa21a|b|c）
cd C:/Users/admin/AppData/Local/Temp/qa_b21/http && python -m http.server 8091 --bind 0.0.0.0
# 设备：导入书源（UI：我的 → 书源管理 → 右上角更多 → 本地导入）
$ADB push fixtures/qa21a_source.json /sdcard/Download/
# 首次安装/清理后，建议先开启应用内 Web 服务再种书：
curl -s -X POST http://192.168.100.63:1122/saveBook -H "Content-Type: application/json" --data-binary @fixtures/save_book_a.json
curl -s -G http://192.168.100.63:1122/getChapterList --data-urlencode "url=http://192.168.100.52:8091/qa21a/book.html"
curl -s -G http://192.168.100.63:1122/getBookContent --data-urlencode "url=http://192.168.100.52:8091/qa21a/book.html" --data-urlencode "index=0"
# 每次 force-stop 后重查 display：
$ADB shell "dumpsys window windows | grep -A 2 'io.legado.flutter_legado/io.legado.flutter.MainActivity' | head -3"
$ADB shell "dumpsys display | grep -o \"displayId=[0-9]*, uniqueId='local:[0-9]*'\""
$ADB shell "input -d <logicalId> tap 540 760"                       # 点图
$ADB exec-out screencap -p -d <SF displayId> > tmp_qb21_xx.png
# 终态
curl -s http://192.168.100.63:1122/api/health; echo "exit=$?"        # 期望非 0
$ADB shell pm clear io.legado.flutter_legado
```

## 九、证据清单（`docs/materials_1112b/`）

| 文件 | 用途 |
| --- | --- |
| `tmp_qb21_00_initial.png` | 基线：设备既有书架（3 本）与 916 个书源状态 |
| `tmp_qb21_01_source_mgmt.png` | 书源管理（既有 916 源） |
| `tmp_qb21_05_import_a.png`、`tmp_qb21_07_import_b_preview.png`、`tmp_qb21_08_both_sources.png` | 源 A/B 本地导入预览、两源导入完成（918 源） |
| `tmp_qb21_38_picker3.png` | 源 C 导入文件选择 |
| `tmp_qb21_11_shelf_after_seed.png` | `/saveBook` 种入 QA 书 A/B 后书架 |
| `tmp_qb21_12_bookA_ch1.png`、`tmp_qb21_13_click1.png`、`tmp_qb21_14_click2.png`、`tmp_qb21_15_click3.png` | 源 A 第 1 章首开、同图点击 #1/#2/#3 的 `ACTION-CLICK-OK` toast |
| `tmp_qb21_16_reader_menu.png`、`tmp_qb21_17_reader_menu.png`、`tmp_qb21_18_ch2.png`、`tmp_qb21_22_menu_check.png` | 阅读菜单/章节导航（第 3、5 章定位过程） |
| `tmp_qb21_19_openurl_https.png`、`tmp_qb21_20_after_cancel.png` | `openUrl(https)` 跳转确认框、取消后停留 |
| `tmp_qb21_21_openurl_javascript.png` / `tmp_qb21_57_fresh_openurl_js.png` | `javascript:` scheme 被拒（全量轮 / pm clear 后复验） |
| `tmp_qb21_23_rar_traversal.png` / `tmp_qb21_59_fresh_rar_traversal.png` | RAR 越界 entry 返回 `[ERROR]`（两轮） |
| `tmp_qb21_25_ttf_file_rejected.png` / `tmp_qb21_60_fresh_ttf_file.png` | `queryTTF(file:///etc/hosts)` 返回 `valid=false`（两轮） |
| `tmp_qb21_27_ttf_http_ok.png` / `tmp_qb21_61_fresh_ttf_http.png` | `queryTTF(http)` 返回 `valid=true type=url`（两轮） |
| `tmp_qb21_29_ch2_ready.png`、`tmp_qb21_30_dynamic_toast_AB.png` | 源 A 第 2 章就绪、动态 toast `AB` |
| `tmp_qb21_33_bookB_ch1.png`、`tmp_qb21_34_sourceB_click.png` | 源 B 第 1 章、`SOURCE-B ACTION-CLICK-OK #1`（多源隔离） |
| `tmp_qb21_42/43/44/46/49_*` | 源 C 大 jsLib 首次点击无 toast（+211/+386ms）、复点 `LOADMS=566 AGE=33674ms`、缓存点击 `AGE=75301ms`（+425ms 可见） |
| `tmp_qb21_51_web_service_off.png`、`tmp_qb21_62_terminal_final.png` | Web 服务关闭态、`pm clear` 后空书架终态 |
| `tmp_qb21_53…56` | pm clear 后复验轮：我的页、书架、第 4 章 |
| `tmp_qb21_63_web_service_off_check.txt`、`tmp_qb21_64_host_http_off_check.txt` | Web 服务 / 宿主 HTTP 关闭后的 curl exit 7 |
| `tmp_qb21_65_device_apk.txt` | 设备型号/系统/ABI/版本/APK SHA-256 |
| `tmp_qb21_66_api_snapshots.txt` | Web API health/saveBook/getChapterList/getBookContent 运行时输出摘录 |
| `tmp_qb21_67_click_timeline.txt` | 点击时刻、截图时刻与 toast 观测时间线 |
| `logcat_b21.txt` / `logcat_b21_terminal.txt` / `logcat_b21_fresh.txt` | 主会话 / 终态 / pm clear 后复验轮 logcat |
| `logcat_b21_b7.txt` | `javascript:` scheme 拒绝日志（第 7 行） |
| `crash_b21.txt` / `crash_b21_terminal.txt` / `exitinfo_b21*.txt` | crash buffer 与 process exit-info |
| `fixtures/` | 源 A/B/C JSON、saveBook JSON、章节 HTML、夹具生成脚本、`regression.rar` |

---

编写者：QA 子代理 ｜ 2026-11-12
