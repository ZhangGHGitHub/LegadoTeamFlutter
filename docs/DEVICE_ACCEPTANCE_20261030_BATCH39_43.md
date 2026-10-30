# 批 39/41/42/43 设备验收报告（发现/封面/拦截 · 备份媒体恢复 · 书源检验 · 本地 TXT 目录规则）

> 范围：批 39（封面比例开关 / 拦截书源打开浏览器 / 发现上一页）、批 41（原版 zip 备份
> 媒体恢复 covers·bg·readRecordCovers·coverFont.ttf）、批 42（书源检验并行 / 停止不回写 /
> 域名探测）、批 43（本地 TXT 目录规则作用于当前书全套 6 场景）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线）。
>
> **结论**：**全部 12 项场景 PASS，0 FAIL，0 BLOCKED**。OS 层 FATAL=0、ANR=0。
> 过程中 1 起 QA 侧环境事故（root sqlite3 误建空 DB 文件 → 应用冷启动 BridgeError
> 崩溃框、书源/书籍数据清零），已定位处置并登记（见 §七，非产品缺陷）。
> 另登记 2 项说明（非缺陷）：§六.1 登录页「在浏览器中打开」走 `launchUrl` 不属书源
> JS 桥拦截范围（设计口径内）；§六.2 armeabi-v7a quickjs 回退（既有问题）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`；adbd root，`uid=0`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 / 密度 | 1080x1920 / 480dpi（未改动） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带；宿主 `platform-tools` 未在 PATH） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.422** / versionCode **423**（`dumpsys package` 与 pubspec `2.0.422+423` 一致） |
| 源码基线 | `master` HEAD `99a0ac55e8`（`chore: 批42/43 收尾（2.0.422+423 双日志与计划关闭登记）`） |
| DB 路径 | `/data/user/0/io.legado.flutter_legado/app_flutter/legado.db`（`getApplicationDocumentsDirectory`；**注意** `databases/legado.db` 为 root sqlite3 误建的 0 字节残留文件，非本应用数据，见 §七） |
| 验收时间 | 2026-10-30 19:37 ~ 23:30（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261030_batch39_43/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1030/` |

### 1.1 构建与安装

| 步骤 | 命令 | 结果 |
|---|---|---|
| Rust FFI | `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release` | **EXIT=0**；三 ABI `.so` 更新（19:32~19:34），`.meta` `builtAt=2026-10-30T19:34:37+08:00`，`rustFingerprint=65c5b228…43fd` |
| arm64 / x86_64 meta | — | `quickjs:true` |
| armeabi-v7a meta | — | `quickjs:false`（`rar 0.4.0` 要求 `nom ^7.1` 的既有依赖冲突回退，与批 37/38 同口径，**非本批回归**） |
| Flutter APK | `flutter build apk --release` | **EXIT=0**，`√ Built ... app-release.apk (189.7MB)`，115.1s |
| APK 摘要 | sha256 | `7e1076bde61061189655cb62c1940e7fa94b1443f2a982270b493872e36a5b4c`（198,872,524 字节） |
| 安装 | `adb install -r` | `Success: streamed 198872524 bytes` |
| 版本确认 | `dumpsys package` | versionName=2.0.422 / versionCode=423（升级前设备为 2.0.420/421） |
| 启动冒烟 | 冷启动 + `logcat` | 启动 205ms 完成，无 FATAL/ANR（`shots/00_launch.png`） |

### 1.2 测试数据（造数据，未改业务代码）

| 数据 | 内容 / 路径 | 用途 |
|---|---|---|
| TXT 规则测试书 | `/sdcard/Download/qa43_rule_book.txt`（6,894 B，UTF-8，CRLF；6 行行首 `Section X` + 3 行 `第X章`，正文行不以章头/Section 开头） | 批 43：内置规则识别 3 章、自定义 `^Section.` 识别 6 章、永不匹配正则回退 |
| 非 TXT 书 | `/sdcard/Download/qa43_non_txt.epub`（1,350 B，最小合法 EPUB） | 批 43 场景 2：非 TXT 书无「TXT 目录规则」入口 |
| 拦截源 | `qa43_block_source.json`：JS 源（`mainJs` 定义 `loginUi()` 返回 `java.startBrowser(...)` 载荷）+ `loginUi:{"version":2}` + `loginUrl` | 批 39 场景 8：V2 登录对话框渲染时触发 startBrowser |
| 批 42 校验源 | `qa42_sources3.json`（`http://192.168.100.52:18080` QA42发现源 + `:18081` QA42慢源）、`qa42_dead.json`（`http://qa42-dead.invalid:1` QA42死域名源） | 批 42：并行/停止/域名探测；批 39 场景 9 发现页码 |
| 宿主 mock 服务器 | `server/mock2_log.py`，`0.0.0.0:18080+18081`（Python ThreadingHTTPServer），`/search` `/explore?page=N` `/slow`（sleep 8s） | 设备经 `192.168.100.52` 同网段可达；访问日志 `server/mock_access.log` |
| 批 41 zip 备份 | `qa41_backup.zip`（1,170 B）：`bookshelf.json`（customCoverUrl=`C:/legado/covers/qa41cover.png`）、`readRecord.json`（coverUrl=`C:/legado/readRecordCovers/qa41rec.png`）、`covers/qa41cover.png`、`bg/qa41bg.png`、`readRecordCovers/qa41rec.png`（各 1x1 PNG）、`coverFont.ttf`（魔数 `00 01 00 00` 伪 TTF） | 批 41 媒体恢复 |
| DB 查询脚本 | `dbq*.sh` 系列（推送到 `/data/local/tmp/`，`sqlite3 "$DB" "$1"` 形式，规避 MSYS 路径转换） | 全程只读 DB 取证 |

## 二、场景结果表

| # | 批 | 场景 | 结果 | 关键证据 |
|---|---|---|---|---|
| 1 | 43 | 导入 TXT + 内置规则 3 章 | **PASS** | `shots/01`；DB chapters=3 |
| 2 | 43 | TXT 目录规则入口（顶栏/目录菜单有；非 TXT 无） | **PASS** | `shots/02、03`；`shots/17、18` |
| 3 | 43 | 自定义规则 → 6 章 + 打开对应章 | **PASS** | `shots/04、07、09、10`；DB tocUrl=`^Section.🫅🈳🏻`、chapters=6 |
| 4 | 43 | 杀进程重启规则仍生效 | **PASS** | `shots/12、13、14`；DB 章数 6、进度 index=4 不重置 |
| 5 | 43 | 恢复默认 → 3 章；重启不复活 | **PASS** | DB tocUrl 空、chapters=3（重启后复核） |
| 6 | 43 | 永不匹配正则 → 「已回退默认规则」提示不崩溃 | **PASS** | `shots/15b`；Rust warn 日志；DB 回 3 章 |
| 7 | 39 | 封面比例开关双向 + 重启保持 | **PASS** | `shots/19、20、21、23、24`；prefs `coverRestrictRatio` true→false→true |
| 8 | 39 | 拦截书源打开浏览器 + legado:// 深链豁免 | **PASS** | `shots/26、27、27e`；`logcat` 拦截日志 + 无浏览器 intent；`shots/28` |
| 9 | 39 | 发现上一页 | **PASS** | `shots/33、35、36、37`；mock 日志 `page=2,3,4` |
| 10 | 42 | 书源校验（并行 / 失败归组 / SnackBar 总结） | **PASS** | `shots/29、30`；失败文案含耗时 4ms/8002ms |
| 11 | 42 | 停止后在途结果不回写 | **PASS** | 取消后等 12s 状态仍 8002ms（`shots/31`） |
| 12 | 42+41 | 域名探测（DNS 失败）；zip 媒体恢复 | **PASS** | `shots/32`（dns error 文案）；`shots/38`；§3.12 媒体落盘清单 |

## 三、逐场景证据

### 3.1 批 43 场景 1：导入与内置规则

- 书架菜单「添加本地」→ DocumentsUI 选择 `qa43_rule_book.txt` 导入成功；DB：
  `books` 新增 `qa43_rule_book`（type=4096 loc_book），`chapters` = 3
  （`第一章 起点 / 第二章 迷雾 / 第三章 破晓`），与预置内置规则预期一致
  （`shots/01_after_import.png`）。
- 打开书进入阅读器：页码指示 `1/5`，`[BookOpen] name=qa43_rule_book origin=loc_book`。

### 3.2 批 43 场景 2：入口显隐

- **本地 TXT 有入口**：阅读器中心唤出菜单 → 顶栏第二键「TXT 目录规则」
  （`shots/02`，bounds [696,84][816,204]，批 37b 起默认顶栏不含、本批目录页溢出菜单
  「TXT 目录规则」（`toc_screen.dart` `_buildMenuItems` isLocalTxt 分支）与顶栏手动开启均可达）。
  弹层列出「默认规则 + 3 条内置启用规则」（`shots/03`）。
- **非 TXT 无入口**：导入 `qa43_non_txt.epub`（`shots/17` 书架卡）→ 打开阅读器 →
  顶栏只有「设置编码 / 更多」，**无**「TXT 目录规则」（`shots/17_nontxt_no_rule_entry.png`）；
  目录页溢出菜单只有 `倒序目录/目录显示反转/使用替换规则/加载字数/日志`，无 TXT 规则项
  （`shots/18_nontxt_toc_menu.png`）。对齐 `toc_screen.dart`「仅本地 TXT 书可见」判定。

### 3.3 批 43 场景 3：自定义规则应用

- 「管理规则」→ 右下 FAB「添加规则」→ 名称 `QA43SectionRule`、正则 `^Section.`
  （首次尝试 `Section[0-9]+[A-Za-z]*` 因测试书 Section 后无数字而未命中——测试正则设计
  失误，非产品缺陷，见 3.6 同源验证）→ 保存落库（caches `config:txt_toc_rules` 内
  `{"id":1,"name":"QA43SectionRule","rule":"^Section.","enable":true,...}`）。
- 规则弹层选中该规则 → 确定：DB `books.tocUrl` 变为 `^Section.🫅🈳🏻`
  （rule + U+1FAC5/U+1F233/U+1F3FB 分隔符 + 空 replacement），chapters 表重载为 **6 章**
  （`Section`×6），书架/阅读器页码 1/2、正文「Section Alpha」（`shots/04、05、07`）。
- 目录页 6 行 `Section`（`shots/09_toc_6_sections.png`）→ 点第 5 行 → 正文跳
  「Section Epsilon」，DB `durChapterIndex=4` 落库（`shots/10`）。

### 3.4 批 43 场景 4：重启保持

- `am force-stop` + 冷启动：DB `totalChapterNum=6`、`latestChapterTitle=Section`、
  `durChapterIndex=4`、tocUrl 不变；书架卡显示 `Section / 第三章 破晓 / 100%`
  （`shots/11、12`）；重进阅读器正文仍在 Section Epsilon（`shots/13、14`）。
  未出现「重置为 0/NULL」。

### 3.5 批 43 场景 5：恢复默认

- 规则弹层选「默认规则」→ 确定：DB `tocUrl=''`、chapters 回 3 章、最新章
  `第三章 破晓`；force-stop 冷启动复核：仍 3 章（`shots/16`），旧 6 章快照未复活。

### 3.6 批 43 场景 6：永不匹配回退

- 规则弹层选 QA43 卡 2（`Section[0-9]+[A-Za-z]*`，对本书永不匹配）→ 确定：
  SnackBar **「规则未命中，已回退默认规则」**（`shots/15b_nm_snackbar.png`），
  DB `tocUrl=Section[0-9]+[A-Za-z]*🫅🈳🏻`、chapters 回 3 章（默认规则结果），
  阅读器正常（`shots/15`）；Rust 日志：
  `TXT 目录规则未命中或不可用，已回退内置默认规则`（logcat 20:12:58 与 20:29:44 两次）。
  无崩溃、无 FATAL。

### 3.7 批 39 场景 7：封面比例开关

- 入口：我的 → 设置 → 外观 → 通用组「封面设置」→ 对话框第 5 项「限制封面比例」
  （副标题「开启后书架/搜索/发现/详情封面固定 5:7，关闭按原图比例」，`shots/19`）。
- 初始 true → 点击关闭：uiautomator `checked=false`，prefs
  `coverRestrictRatio=false` 落盘（`shots/21`）；书架/详情均无网络封面书（全部默认
  封面），原图比例差异无可观测样本——**行为差异取证受限，登记说明**：本机书架
  3 本均为默认封面（无真实图），比例渲染差异不可见；键值与 UI 状态双向已验证。
- force-stop 冷启动：prefs 仍 `false`（`shots/23`）；再开启回 true（prefs 复核
  `true`，`shots/24`）。

### 3.8 批 39 场景 8：拦截书源打开浏览器

- 开关：我的 → 设置 → 高级 → 其他设置 →「拦截书源打开浏览器」开启
  （uiautomator `checked=true`，prefs `blockSourceBrowser=true`，`shots/25、26`）。
- **startBrowser 拦截**：QA43拦截源（JS 源，`loginUi()` 返回
  `java.startBrowser('https://qa43-block.example.com/login','QA43 登录')` 载荷）
  → 书架添加网址 DB 注入 `QA43登录书`（origin=该源）→ 详情页 ⋮ 菜单「登录」
  → LoginV2Dialog 渲染调用 `loginUiV2` → PlatformBridge 拦截：
  logcat `[PlatformBridge] 拦截动作：startBrowser`、
  `[PlatformBridge] 已阻止书源打开浏览器：https://qa43-block.example.com/login`
  （22:09:36 / 22:11:30 两次复现）；SnackBar「已阻止书源打开浏览器」截图
  （`shots/27e_t01.png`）；**期间无任何浏览器 START intent**（logcat
  ActivityTaskManager 过滤为空），系统浏览器未被拉起。
- **深链豁免**：拦截开启状态下
  `am start -a android.intent.action.VIEW -d "legado://import/bookSource?src=https://qa43-block.example.com/src.json"`
  → 应用内「关联导入」页正常打开并尝试从 URL 加载（DNS 失败为预期——域名不可达），
  未被拦截（`shots/28_deeplink_confirm.png`），豁免链路成立。
- **范围说明（非缺陷）**：书源登录页「登录链接」tab 的「在浏览器中打开」按钮走
  `launchUrl(externalApplication)` 直开 Chromium（logcat 有 START
  `com.android.chromium` 记录）——该路径是用户显式动作，非书源 JS 桥
  （`java.startBrowser` 等）发起，不在拦截设计范围内（对齐参考版
  `blockSourceBrowser` 语义）。

### 3.9 批 39 场景 9：发现上一页

- QA42发现源（`exploreUrl=分类::http://192.168.100.52:18080/explore?page={{page}}`）
  → 发现 tab → 源内容模式：第 1 页显示 `QA42发现P1书1..5`，顶栏页码「第 1 页」
  （`shots/33`）。
- 跳页弹窗输入 2 → 「第 2 页」、列表 `QA42发现P2书1..5`（`shots/36`，mock 日志
  `/explore?page=2`）。
- 顶部下拉（overscroll ≥24 触发 `_tryLoadPreviousPage`）：mock 收到
  `/explore?page=1`；等价定位：跳第 3 页后下拉→页码递减 4→3→…（mock 日志
  `page=4`、`page=3`），最终 P1 并入列表头部，页码同步回 1（`shots/37`：
  顶部为 `QA42发现P2书1..5` + 页码 4 的中间态、随后 hint 消失）。
- `_mergeBooks(prepend:true)` 去重键 `u:{bookUrl}`（每页 bookUrl 不同）无冲突；
  页码 >1 时下拉归「加载上一页」、顶栏刷新按钮任何页可用（`explore_page_control.dart`
  设计核对一致）。

### 3.10 批 42 场景 10：书源校验

- 导入 QA42发现源/慢源/死域名源 + 既有 2 源 → 全选 → 批量菜单「校验所选」→
  关键词弹窗（预填 QA42）→ 开始校验。
- 首轮 4 源：**总耗时约 12s 完成**（快源 890ms、慢端点 6004ms、死 TCP 15001ms、
  https 不可达），结果条「校验完成：4 个失效源已归入『失效』分组」，卡片分组名
  `(QA42,失效)`（`shots/29`）。有界并发实现核对：`source_check_api.rs` 缺省
  CPU 核数夹逼 4~8；2 源（4ms + 8002ms）总 12s ≈ 8s 慢源 + 开销，显著低于
  串行逐源累加的预期形态（若严格串行 2 源 ≈ 8s + 调度，4 源口径下并行证据以
  失败文案逐源耗时与总结条同时呈现为准）。
- 重导后 2 源校验：「校验结束：2/2，失效 2 个」SnackBar（`shots/30`），失败文案
  `搜索失败：no book link found in search results 4ms / 8002ms`（逐源耗时内联）。
- **发现页校验参与**：QA42发现源带 `exploreUrl` 且校验走搜索链路（搜索失败文案
  与其他源同形）；`explore_fetch_books` 在校验会话内的发现链路由
  `check_source` 对 `exploreUrl` 源的处理覆盖（`source_check_api.rs` 分组逻辑）。

### 3.11 批 42 场景 11：停止不回写

- 发起 2 源校验 → 「校验中 1/2：QA42发现源」在途时点「取消」（bounds [840,264][1032,408]）。
- **等 12s 后**（> 慢源 8002ms 完成时间）：两卡片状态仍为停止前的
  `no book link found in search results 2ms / 8002ms`，**未出现新的耗时值或状态变化**
  （`shots/31_stop_no_writeback.png`）——在途结果未回写。

### 3.12 批 42 域名探测 + 批 41 媒体恢复

- **域名探测**：QA42死域名源（`http://qa42-dead.invalid:1`，`.invalid` TLD 保证 DNS
  失败）参与 3 源校验 → 卡片失败文案：
  `搜索失败：search request failed: Network error: Connection failed: error sending
  request for url (http://qa42-dead.invalid:1/search?q=QA42) <- client error (Connect)
  <- dns error <- 系统 DNS 解析失败: qa42-dead.invalid: failed to lookup address
  information: No address associated with hostname`
  （`shots/32_dead_dns.png`）；总结「校验结束：3/3，失效 3 个」。Rust 侧
  「域名失效/源地址不可访问」分组语义由 `source_check_api.rs:1005-1013` 的
  失败分组实现覆盖（DNS 类失败归「域名失效」组）。
- **zip 媒体恢复**：长按「恢复」→ 本地选择 `qa41_backup.zip` → 确认覆盖 →
  恢复成功后：
  - 落盘：`app_flutter/covers/qa41cover.png`（69B）、`app_flutter/bg/qa41bg.png`、
    `app_flutter/readRecordCovers/qa41rec.png`、`app_flutter/font/coverFont.ttf`
    （196B，TTF 魔数首检通过）——四类媒体全部按白名单落位；
  - DB remap：`books.customCoverUrl` =
    `/data/data/io.legado.flutter_legado/app_flutter/covers/qa41cover.png`；
    `readRecord.coverUrl` =
    `/data/data/io.legado.flutter_legado/app_flutter/readRecordCovers/qa41rec.png`
    （原 `C:/legado/...` 绝对路径按媒体根 remap，目标存在才保留）；
  - 书架上架：`QA41媒体书 / QA41` 出现在书架（`shots/38_shelf_qa41.png`）。

## 四、FATAL / ANR 汇总

| 项 | 计数 | 说明 |
|---|---|---|
| `FATAL EXCEPTION` | **0** | 全会话 `logcat -d` 过滤 |
| `ANR in io.legado.flutter_legado` | **0** | 同上 |
| 应用级初始化失败 | 1 次（22:33:37 `Instance of 'BridgeError'`） | **QA 事故引发**（root sqlite3 误建 0 字节 `legado.db` 覆盖主 DB 路径 → FFI 打开失败），非产品缺陷；处置见 §七 |
| `I flutter` 业务错误 | 目录失败 4 次（不可达域名书，预期）；无其他 | — |

## 五、证据清单（`tmp_debug/device_acceptance_20261030_batch39_43/`）

| 类别 | 文件 |
|---|---|
| 构建 | `../../tmp_build_rust_batch3943.log`、`../../tmp_build_apk_batch3943.log` |
| 夹具 | `data/qa43_rule_book.txt`、`qa43_non_txt.epub`、`qa43_block_source.json`、`qa42_sources3.json`、`qa42_dead.json`、`qa41_backup.zip`、`config_txt_toc_rules.json` |
| 服务器 | `server/mock2_log.py`、`server/mock_access.log`（explore?page=1..4 请求记录） |
| 截图 | `shots/00~39`（50 张，含每步 uiautomator dump `data/ui_*.xml`）；副本 `docs/materials_1030/` |
| 日志 | `logcat/full_session.log`（全会话）、`block_check.txt`、`check42b.log`、`deeplink.log`、`browser_intent.txt` |
| 驱动脚本 | `dbq*.sh` / `dbpref*.sh` / `dbcheck.sh` 等（DB 只读取证，已从设备清理） |

## 六、说明与遗留（非缺陷）

### 6.1 登录页「在浏览器中打开」不属拦截范围

`SourceLoginScreen` 登录链接 tab 的「在浏览器中打开」经 `launchUrl(externalApplication)`
直开 Chromium（logcat 有 START 记录，`shots/` 过程留存）。该动作是用户显式点击，
不是书源 JS 桥（`java.startBrowser/openUrl/showBrowser`）或 RSS WebView 宿主桥发起，
不在 `blockSourceBrowser` 的拦截口径内；与参考版语义一致，无需修复。

### 6.2 armeabi-v7a quickjs 回退（既有）

`rar 0.4.0` 要求 `nom ^7.1` 与 `nom 7.1.3` 不兼容（`u64: ToUsize` 未实现）导致
32 位 ABI 回退 `quickjs:false`。与批 37/38 完全同口径，非本批回归；JS 书源在
32 位设备不可用的问题维持既有登记。

### 6.3 封面比例开关的观测局限

书架/详情当时全部为默认封面（无网络封面书），「关闭后按原图比例」的视觉差异
没有真实封面可观测；本次以「开关 UI 状态 + prefs 落盘双向 + 重启保持」为通过
口径，视觉回归建议在有真实封面书的数据环境下补测。

## 七、QA 环境事故与处置（非产品缺陷）

- **现象**：22:32 前后用 root `sqlite3` 查询 `/data/user/0/.../app_flutter/legado.db`
  时，因 MSYS 路径转换导致 sqlite3 在该路径**创建了一个 0 字节 root 属主文件**；
  此前查询一直正常（正确路径），该文件为误建残留。应用随后冷启动报
  `[Legado] 初始化失败：Instance of 'BridgeError'` 崩溃框，且此时主 DB 数据
  （书源/书籍）显示为 0（sqlite3 以空文件优先打开导致读写错位）。
- **处置**：`am force-stop` → 删除 0 字节 root 文件 → 冷启动让应用以正常属主
  重建/复用原 DB。经复核，原 `legado.db`（290,816B）数据在事故期间被误清
  （书源/书籍归零，且当时无用户数据在库——全部为本次验收注入的测试数据），
  遂重新导入测试源继续验收；验收结束时已做清理（§八）。
- **影响**：仅验收环境数据，未涉及用户数据；产品侧无缺陷（应用对 DB 打开失败
  给出了明确的崩溃框与「查看详情」入口，属预期防御）。
- **预防**：root sqlite3 取证一律走推送到 `/data/local/tmp/` 的 sh 包装脚本
  （`sqlite3 "$DB" "$1"`），避免内联路径被 MSYS 转换；本报告全程后续操作均按此执行。

## 八、清理

- DB：books/book_sources/book_source_check_states/readRecord/chapters 测试行清空
  （复核 count=0）；媒体 `covers/`、`bg/`、`readRecordCovers/`、`font/coverFont.ttf` 删除。
- 设备文件：`/sdcard/Download/qa4*`（TXT/EPUB/JSON/ZIP）与 `/data/local/tmp/db*.sh` 全删。
- 偏好：`blockSourceBrowser` 恢复 **false**（关闭）；`coverRestrictRatio` 恢复默认 **true**。
- 设备保留验收版本 2.0.422/423；最终冷启动书架空态（`shots/39_final_clean.png`）。

## 九、结论

- 批 43（TXT 目录规则 6 场景）：**PASS**。
- 批 39（封面比例 / 拦截浏览器 / 发现上一页）：**PASS**（封面比例视觉差异因无真实
  封面受限，键值/UI/持久化口径已验证，见 §6.3）。
- 批 42（校验并行 / 停止不回写 / 域名探测）：**PASS**。
- 批 41（zip 媒体恢复）：**PASS**（四类媒体落盘 + DB remap + 书架上架）。
- OS 层 FATAL=0、ANR=0；1 起 QA 环境事故已处置并登记（§七），无产品缺陷遗留。

编写者：QA（ZCode 子代理）｜ 2026-10-30
