# 批 M1「我的」页设备验收报告（信息架构 · Web 服务块 · AI 占位 · 字典单入口）

> 范围：版本 **2.0.438+439**（HEAD `ffef0896db`）「我的」页 M1 信息架构与 Web 服务块：
> Web 服务置顶（地址 / 复制地址 / 在浏览器中打开 / 停止）、规则组 5 项、
> 服务与工具组、设置并入其他、AI 聊天占位、字典规则单入口、
> 主题模式移出「我的」、地址刷新与断网回落、小屏/大字体、回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`），Android 15 / SDK 35 / x86_64。
>
> **结论：主链路通过（10 组场景中 9 组 PASS）；场景 5 的「外部 `/dict`、`/dict_rule`
> 深链」子项 FAIL（P2-1）。P1=0、P2=1、P3=3（均为既有行为/非 M1 引入，登记备查）。**
> 逐项目标行为实测成立：Web 服务置顶、运行地址为设备局域网地址、复制内容与
> 显示一致、浏览器可达、停止后地址/按钮消失、操作按钮不切换开关；断网回落
> `127.0.0.1（本机）`、恢复网络后刷新回局域网地址；AI 占位页无输入框；
> 字典规则单入口默认管理页且「字典查询」页内可达；主题模式仅在设置内且
> 深色重启保持；定时任务/MCP 前置提示正常；360×640dp + 大字体/窄屏无溢出、
> 两按钮可换行；FATAL=0、ANR=0、overflow=0。
> **未达标项**：`adb shell am start -d "legado://dict_rule"`（及 `legado://dict`
> 等变体）不会进入字典页面，而是打开「关联导入」弹窗（见 §四 P2-1）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM_G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（3x，即 **360×640 dp**） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备 root | `adb shell id` = `uid=0(root)`（可读取 `shared_prefs`、`dumpsys` 取证） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.438** / versionCode **439**（安装后与最终清理后各复核，`data/version_final.txt`） |
| 源码基线 | `master` HEAD **`ffef0896db`**（`chore: M1 我的页收尾（2.0.438+439 双日志与计划登记）`） |
| 验收时间 | 2026-11-03 02:31 ~ 02:56（宿主时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_m1/`（logcat/data/scripts/shots，不入库） |
| 截图 | `docs/materials_1104/`（34 张，`m1_01` ~ `m1_34`） |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（`data/so_info.txt`） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 70.5s`，**200,269,596 B（191.0 MB）**，构建时间 **2026-11-03 02:33:37**；sha256 **`2ea1962c4e81b667790166b07ab647b47b12f519870ab8a699404f8361494c20`**（`logcat/build_release.log`、`data/apk_info.txt`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200269596 bytes** |
| 冷启动 | 417 / 321 / 313 / 353 ms（`am start -W` TotalTime，含深色主题重启后一次） |
| 通知权限 | `POST_NOTIFICATIONS: granted=true`（开关开启时系统弹窗点「允许」，`data/notification_permission.txt`） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（15.7s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/widget/my_page_m1_test.dart test/widget/settings_test.dart test/widget/settings_service_toggle_error_test.dart test/widget/settings_web_foreground_service_test.dart test/widget/dict_rule_screen_test.dart` | **80/80 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量 Flutter 测试 | `flutter test` | **3948 passed + 1 skipped**，EXIT=0（1:35，`logcat/full_tests.log`） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success（见 §1.1） |

> 门禁与构建串行执行，避免 `flutter test` 与 `flutter build` 并发触发
> `GeneratedPluginRegistrant.java` 竞态。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 结构：Web 服务置顶 → 规则 5 项 → 服务与工具 3 项 → 其他 8 项；无独立设置组、无主题模式行；大标题+帮助保留 | **PASS** | `m1_01`、`m1_02`、`m1_03`、`m1_04`；`data/01_my_top.xml`、`03_my_mid.xml`、`04_my_bottom.xml`、`05_my_rules.xml` |
| 2 | Web 服务：开启（通知允许）→ 局域网地址 → 复制地址 → 浏览器打开 → 停止 → 按钮不切换开关 | **PASS** | `m1_05`~`m1_11`；`data/07_web_running.xml`、`25_my_before_copy.xml`、`32_settings_paste.xml`、`36_after_browser_back.xml`、`96_stopped_final.xml` |
| 3 | 地址刷新：后台返回、断网→`127.0.0.1（本机）`、恢复网络→与 `ip addr` 一致 | **PASS** | `m1_12`、`m1_22`、`m1_23`；`data/39_after_resume.xml`、`41_network_off.png`、`70_network_restored.xml`、`data/ip_*.txt` |
| 4 | AI 聊天占位：明确「暂未支持」、无输入框、可返回 | **PASS** | `m1_13`；`data/42_ai_chat.xml` |
| 5 | 字典规则：单入口默认管理页；页内「字典查询」可达；旧 `/dict`、`/dict_rule` 外部深链可达 | **FAIL（外部深链）/ PASS（应用内）**，P2-1 | `m1_14`、`m1_15`、`m1_16`；`data/44_dict_rule.xml`、`45_dict_query.xml`、`47_deeplink_*.xml` |
| 6 | 主题：My 无主题模式行；设置→外观→主题模式切深色并生效/重启保持 | **PASS** | `m1_17`、`m1_18`、`m1_19`；`data/35_appearance.xml`、`36_dark_appearance.xml`、`37_restart_dark.xml` |
| 7 | 服务与工具：定时任务页可达；运行开关持久化；MCP 未配置 token 前置提示 | **PASS** | `m1_20`、`m1_21`；`data/59_auto_tasks.xml`、`62_autotask_after_restart*.xml`、`64_mcp_tap.xml` |
| 8 | 小屏/大字体：360×640dp + 字体 1.3；窄屏 300dp 下按钮换行、滚动到底无溢出 | **PASS** | `m1_24`、`m1_25`、`m1_26`；`data/71_font13_top.xml`、`72_font13_bottom.xml`、`74_narrow_web.xml` |
| 9 | 回归：前台服务/唤醒锁/保活、返回键、首页导航、书架/阅读；FATAL/ANR/overflow=0 | **PASS**（O-2 既有缺陷登记） | `m1_27`~`m1_31`；`logcat/session_final.log`、`crash_final.log` |
| 10 | 清理：停 Web 服务、恢复主题/导航默认、空书架、保留版本 | **PASS** | `m1_32`、`m1_33`、`m1_34`；`data/version_final.txt` |

## 三、逐场景证据

### 3.1 场景 1：结构（PASS）

- **步骤**：安装后冷启动 → 点底栏「我的」→ 截图并 dump 语义树 → 分段滚动到底。
- **预期**：Web 服务块置顶；规则组 5 项；服务与工具组 3 项；其他组 8 项；
  无独立「设置」组、无「主题模式」行；保留大标题「我的」+ 帮助按钮。
- **实际**（语义树顺序，`data/01_my_top.xml` ~ `05_my_rules.xml`）：
  1. 大标题「我的」+ 右上「帮助」（`[960,114][1068,222]`）。
  2. **Web 服务**块：`[48,528][1032,819]`，副题「用浏览器写源或看书」。
  3. **规则**：书源管理 → 替换净化 → TXT 目录规则 → 字典规则 → 高亮标签规则。
  4. **服务与工具**：定时任务 → 运行定时任务 → MCP 服务。
  5. **其他**：AI 聊天 → 设置 → 书签 → 阅读记录 → 缓存管理 → 文件管理 → 关于 → 退出。
- **否定证据**：4 个页面分段 dump 中 `主题模式` 出现次数均为 **0**；无独立
  「设置」分组标题；「设置」行位于「其他」组卡片内（`m1_02`/`m1_03` 同一
  IosGroup 容器连续排列）。
- **结论**：PASS。

### 3.2 场景 2：Web 服务（PASS）

| 步骤 | 预期 | 实际 / 证据 |
|---|---|---|
| 点 Web 服务卡开启 | 系统通知权限弹窗 | 弹窗「要允许“阅读”向您发送通知吗？」→ 点「允许」（`m1_05`；`data/07_after_enable_tap.xml`） |
| 开启后卡片 | 显示设备局域网 IP:端口 | 副题 **`http://192.168.100.62:1122`**；`chk=true`；与 `ip addr wlan0` 的 `192.168.100.62/24` 一致（`m1_06`、`data/08_web_running.xml`） |
| 服务可达性 | 服务真实可访问 | 宿主 `curl http://192.168.100.62:1122/` → **HTTP/1.1 200 OK**，`<title>Legado web 导航</title>` |
| 点「复制地址」 | 剪贴板=显示地址；开关不变 | Toast **「已复制访问地址」**（`m1_07`）；随后 `service call clipboard 6` → `hasPrimaryClip=1`；在系统设置搜索框粘贴，语义树文本 **`http://192.168.100.62:1122`**（`m1_08`、`data/32_settings_paste.xml`；截图因输入框光标在末尾只显示尾部，完整值以 XML 为准）；卡片仍 `chk=true` |
| 点「在浏览器中打开」 | 系统浏览器打开且服务可达 | logcat `START ... dat=http://192.168.100.62:1122/ ... cmp=com.android.chromium/...ChromeTabbedActivity`；Chrome 先显示 HTTP 安全提示（`m1_09`），点「继续访问网站」后显示 **Legado web 导航**（书架/书源/传书/订阅源，`m1_10`） |
| 从浏览器返回 App | 开关仍开启、地址保持 | `data/36_after_browser_back.xml`：`chk=true`、副题地址不变——**复制/打开按钮未切换开关** |
| 点卡片停止 | 地址/按钮消失、服务停止 | 副题回「用浏览器写源或看书」，`复制地址`/`在浏览器中打开` 节点消失（`m1_11`、`data/96_stopped_final.xml`）；`dumpsys activity services` 无 `WebServerForegroundService`；宿主 `curl` 连接拒绝 |
| 通知/前台服务 | 运行中有 FGS 通知 | `WebServerForegroundService isForeground=true foregroundId=7778`；通知标题「Web 服务运行中」，channel `legado_web_server` |

- **结论**：PASS。

### 3.3 场景 3：地址刷新（PASS）

| 子项 | 步骤 | 实际 / 证据 |
|---|---|---|
| 后台返回 | 运行中按 Home → `am start` 回 App | 地址仍 **`http://192.168.100.62:1122`**（`m1_12`、`data/39_after_resume.xml`） |
| 断网 | `svc wifi disable` → `ip -4 addr` 仅剩 `lo 127.0.0.1` → Home → 回 App | 卡片显示 **`http://127.0.0.1:1122（本机）`**（`m1_22`、`data/41_network_off.png`）；两按钮仍在；「（本机）」标注表明仅本机可访问 |
| 恢复网络 | `svc wifi enable` → 回 App | 地址刷新回 **`http://192.168.100.62:1122`**（`m1_23`、`data/70_network_restored.xml`）；此时 `ip addr` `192.168.100.62/24`，二者一致（`data/ip_before.txt` / `ip_after_restore.txt`） |

- **说明**：断网期间 adb 走 Wi-Fi 也断开，改用 MuMuManager guest shell 触发
  `input keyevent 3`/`am start` 并 `screencap`，恢复网络后 `adb pull` 取证；
  断网截图二进制经 base64 转出后校验为 1080×1920 PNG。
- **结论**：PASS（含无网回落标注）。

### 3.4 场景 4：AI 聊天占位（PASS）

- **步骤**：「我的」→ 其他 → AI 聊天。
- **预期**：占位页「暂未支持」、无输入框、可返回。
- **实际**：页面标题「AI 聊天」，正文 **「AI 聊天暂未支持 / 待 Rust 能力接入后开放」**，
  语义树无 EditText/输入框节点，仅有 Back（`m1_13`、`data/42_ai_chat.xml`）；
  返回后回到「我的」原滚动位置。
- **结论**：PASS。

### 3.5 场景 5：字典规则与深链（应用内 PASS / 外部深链 FAIL）

- **应用内路径（PASS）**：
  - 「我的」→「字典规则」→ 默认进入 **「字典规则管理」**（顶栏「字典查询」，
    列表：海词中文/海词英文/有道/哔哩/百度汉语，右下「新增规则」）；
  - 顶栏「字典查询」→ **「字典查询」** 页（「查询」按钮、输入提示、返回管理页入口）；
  - 证据：`m1_14`、`m1_15`、`data/44_dict_rule.xml`、`45_dict_query.xml`。
- **外部深链（FAIL）**：
  - 执行 `adb shell am start -a android.intent.action.VIEW -d "legado://dict_rule"`、
    `legado:///dict_rule`、`legado://dict`、`legado:///dict` 四次，均在应用前台
    打开 **「关联导入」** 弹窗（并显示「剪贴板为空」），未进入字典管理/查询页；
  - logcat 确认 `com.llfbandit.app_links: Handled intent ... data: legado://dict_rule`，
    但应用侧 `LegadoDeepLink` 仅将 `legado://` 链接作为「导入」处理，
    `deep_link_service.dart` 的 `handleUrl` 对非导入 scheme 直接返回；
  - 证据：`m1_16`、`data/46_deeplink_dictrule.xml`（`legado://dict_rule`）与
    `data/47_deeplink_legado___*.xml` / `47_deeplink_legado____*.xml`（其余变体）；
  - 结论：**外部 `/dict`、`/dict_rule` 深链不可达**，与应用内路由保留的字面
    预期不一致，登记 **P2-1**，需开发确认「深链」是否指外部 `legado://` URI；
    若产品要求外部可达，应补 scheme→route 映射与回归测试。
- **场景判定**：应用内 PASS，外部深链 FAIL；场景 5 不整体判 PASS。

### 3.6 场景 6：主题模式（PASS）

- **步骤**：确认「我的」无主题模式行；设置 → 外观 → 主题模式 → 深色；
  截图；`am force-stop` + 冷启动复核。
- **实际**：
  - 「我的」页 4 段 dump 均无「主题模式」；该行仅出现在
    **设置 → 外观**（`m1_17`、`data/35_appearance.xml`）；
  - 点「深色」后界面立即切黑（`m1_18`），prefs
    `app_theme_mode=dark`；
  - 冷启动后首页/我的仍为深色（`m1_19`、`data/37_restart_dark.xml`），持久化成立；
  - 清理阶段恢复「跟随系统」（`m1_33`，prefs `app_theme_mode=system`）。
- **结论**：PASS。

### 3.7 场景 7：服务与工具（PASS）

| 子项 | 步骤 | 实际 / 证据 |
|---|---|---|
| 定时任务页 | 我的 → 服务与工具 → 定时任务 | 打开「定时任务」页，空态「暂无定时任务 / 点击右下角按钮添加新任务」（`m1_20`、`data/59_auto_tasks.xml`） |
| 运行定时任务持久化 | 打开开关 → 重启 → 复核 | 开关 `chk=true`；重启后仍 `chk=true`（`data/61_autotask_on.xml`、`62_autotask_after_restart2.xml`）；恢复为关 |
| MCP 前置提示 | token 未配置时点 MCP | 副题「需先配置「Web 书源访问令牌」（设置 → 高级 → 其他设置）」；点按后 SnackBar「MCP 服务切换失败: ... 请先在「设置 → 高级 → 其他设置」配置「Web 书源访问令牌」（config:jsSourceApiToken）」；开关保持关（`m1_21`、`data/64_mcp_tap.xml`） |

- **结论**：PASS。

### 3.8 场景 8：小屏 / 大字体（PASS）

- **基线**：1080×1920 / 480 dpi = **360×640 dp**（已满足小屏口径）。
- **大字体**：`settings put system font_scale 1.3` → 「我的」滚动到底：
  设置/书签/阅读记录/缓存管理/文件管理/关于/退出全部可见（`m1_24`、`m1_25`），
  日志 `overflowed by` 计数 **0**。
- **窄屏**：`wm size 900x1600`（300×533 dp）+ 字体 1.3，Web 运行态：
  - 地址自动换行为两行（`http://192.168 / .100.62:1122`）；
  - `复制地址` 与 `在浏览器中打开` 由一行 **换行为上下两行**，右对齐，无遮挡；
  - `data/74_narrow_web.xml`、`m1_26`；日志 overflow=0。
- **清理**：`wm size reset`、`font_scale 1.0`，重启后恢复 1080×1920。
- **结论**：PASS（窄屏地址折行属可接受排版，无溢出）。

### 3.9 场景 9：回归（PASS，O-2 既有缺陷登记）

| 检查点 | 实测 | 证据 |
|---|---|---|
| Web 前台服务 | 开启后 `WebServerForegroundService isForeground=true`；通知「Web 服务运行中」 | `dumpsys activity services` / `dumpsys notification` |
| 唤醒锁 | 开启「Web 服务唤醒锁」：prefs=true；`dumpsys power` 出现 `PARTIAL_WAKE_LOCK 'legado:WebService'`；`dumpsys wifi` 出现 `WifiLock{legado:WebService type=4}`；关闭后 REL、prefs=false | §3.2、`data/evidence_notes.txt` |
| 返回键 | 我的 → 返回 → 书架（不退出应用） | `data/91_back_from_my.xml` |
| 首页导航 | 首页/发现/订阅/书架逐页可达（首页统计、发现空态、订阅分组） | `data/92_tab_*.xml`、`m1_31` |
| 本地 TXT 导入与阅读 | file VIEW 导入确认 → 书架出现 `qa_m1_novel` → 阅读页 `1/9` → 左滑翻页 → 返回书详 → 书架 | `m1_27`~`m1_30`、`data/84_file_import.xml`~`88_after_reader_back.xml` |
| 稳定性 | 最终窗口 3,692 行：**FATAL EXCEPTION=0、ANR in io.legado=0、RenderFlex overflowed=0、E/flutter=0**；crash buffer 751 行中 `io.legado` **0** 条（其余为 `Shutdown thread`/uiautomator 噪声） | `logcat/session_final.log`、`logcat/crash_final.log` |

- **既有缺陷复现（O-2，非 M1 引入）**：书架管理删除书籍后，返回书架主界面
  仍显示已删书籍封面；重启后消失（`data/105_shelf_empty.xml` 仍显示书，
  `data/106_shelf_after_restart.xml` 为空）。与 2026-11-02 批 2b-2a 报告
  §六 O-2 一致，本批未改 `bookshelf_screen.dart`，不计入 M1 结论。
- **结论**：PASS（限见上）。

### 3.10 场景 10：清理与版本保留（PASS）

| 步骤 | 结果 | 证据 |
|---|---|---|
| 停 Web 服务 | 副题回默认文案、地址/两按钮消失、FGS 消失、宿主 curl 连接拒绝 | `m1_32`、`data/96_stopped_final.xml` |
| 恢复主题 | 设置→外观→跟随系统；prefs `app_theme_mode=system`，界面回浅色 | `m1_33`、`data/98_theme_system.xml` |
| 恢复导航 | 本批未改导航配置（prefs 无 `show*/mainNavigationOrder` 键），无需恢复 | `data/evidence_notes.txt` |
| 删除测试书 | 书架管理删除 `qa_m1_novel`；重启后空书架（删除后主界面不即时刷新，见 O-2） | `m1_34`、`data/106_shelf_after_restart.xml` |
| 删除测试文件 | `/sdcard/Download/qa_m1_novel.txt`、`/sdcard/qa_ui*.xml`、`/sdcard/x.xml`、`/sdcard/qa_off.png` 全部删除 | adb `ls` 无匹配 |
| 版本保留 | **2.0.438 / 439** | `data/version_final.txt` |

## 四、问题清单与分级

| 级别 | 编号 | 描述 | 复现步骤 / 证据 | 归属 |
|---|---|---|---|---|
| P1 | — | 无 | — | — |
| P2 | P2-1 | **旧 `/dict`、`/dict_rule` 外部深链不可达**：`adb shell am start -d "legado://dict_rule"`（以及 `legado://dict`、三斜杠变体）均打开「关联导入」弹窗，不进入字典管理/查询页；应用内入口正常 | ① 应用在前台；② `adb shell am start -a android.intent.action.VIEW -d "legado://dict_rule" io.legado.flutter_legado`；③ 实测显示「关联导入」+「剪贴板为空」，未进入字典页（`m1_16`、`data/47_deeplink_*.xml`）；logcat `app_links: Handled intent ... data: legado://dict_rule`。期望：进入 `AppRoutes.dictRule`（或查询页），或明确说明仅支持应用内路由 | 代码/契约缺口（深链 scheme 未映射到路由）；需开发确认 |
| P3 | P3-1 | **进程重启后 Web 服务开关镜像为开、副题为 `stopped`**：`webService=true` 持久化但进程内 server 不自动启动，用户需先关再开；界面「开 + stopped」略易误解 | `am force-stop` → 冷启动 → 我的页 `chk=true`、副题 `stopped`（`data/37_restart_dark.xml`、`75_my_state`）；代码注释已说明「仅 UI 镜像、不自动 startServer」 | 既有语义（非 M1 引入），登记 |
| P3 | P3-2 | **书架管理删除书籍后主界面不即时刷新**（删除成功后仍显示封面，重启消失） | 书架管理删除 `qa_m1_novel` → 返回书架仍显示（`data/105_shelf_empty.xml`）→ 重启后空书架（`data/106_shelf_after_restart.xml`）；与批 2b-2a O-2 相同，非本批文件 | 既有缺陷，待独立修复 |
| P3 | P3-3 | **关联导入弹窗读取剪贴板失败后，关闭再打开仍停留在「剪贴板为空」错误态，「重试」禁用**（需点「重置」或重启才能回到输入态） | 空剪贴板点「从剪贴板」→ 错误态；关闭后经深链/入口重开，仍为错误态且 `重试 en=false`（`data/21_assoc_clipboard.xml`、`28_assoc_fast.xml`、`46_deeplink_dictrule.xml`） | 既有 UI 状态问题（非 M1 改动），登记 |

> 说明：P2-1 是本批验收单「旧 `/dict`、`/dict_rule` 深链仍可达」子项的唯一
> 未达标项；应用内 `/dict_rule` 与 `/dict` 路由均可达（管理页顶栏「字典查询」）。
> 若产品/开发确认「深链」仅指应用内命名路由，可将该项降级为 P3 并补充口径；
> 本报告按验收单字面预期判 FAIL。

## 五、结论与建议

- **功能结论**：M1 信息架构与 Web 服务主链路达成验收目标（场景 1/2/3/4/6/7/8/9/10
  PASS）。Web 服务置顶、局域网地址、复制/浏览器打开、停止、按钮不误触开关、
  断网回落与恢复刷新均实测成立；AI 占位、字典单入口、主题模式移出 My、
  服务与工具、小屏/大字体均符合预期。
- **未达标**：场景 5 外部深链（P2-1）。这是验收单明确要求的子项，未伪造 PASS。
- **稳定性结论**：最终日志窗口 FATAL=0、ANR=0、RenderFlex overflow=0、E/flutter=0；
  crash buffer 无 `io.legado` 记录。Web 前台服务、唤醒锁、WifiLock 均实测
  按开关注入/释放。
- **门禁结论**：`flutter analyze` 0；定向 80/80；全量 3948 passed + 1 skipped；
  release 构建 EXIT=0；安装成功；版本 2.0.438+439。
- **建议**：
  1. **P2-1**：在 `DeepLinkService.handleUrl` 或原生 `MainActivity` 增加
     `legado://dict_rule` / `legado://dict` → `AppRoutes.dictRule` /
     `AppRoutes.dict` 的显式映射（冷启动与热启动），并补设备/单测；
     若确认不需要，请更新验收单与计划中的「深链」口径。
  2. P3-1：评估进程重启后是否自动启动 Web 服务；若不自动启动，建议开关
     同步为关或副题明确「未运行（需手动开启）」，避免「开 + stopped」歧义。
  3. P3-2（既有）：书架管理删除后刷新书架列表，避免残留封面。
  4. P3-3（既有）：关联导入弹窗在错误态关闭/重开时应重置到空闲态，或允许
     「重试」回到输入态。
- **证据路径**：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261103_M1_MY_PAGE.md`
  - 截图（34 张）：`docs/materials_1104/m1_01` ~ `m1_34`
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261103_m1/`
    - `logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
      `build_release.log`、`session_final.log`、`crash_final.log`
    - `data/version_final.txt`、`apk_info.txt`、`apk_sha256.txt`、`so_info.txt`、
      `evidence_notes.txt`、`ip_before.txt`、`ip_after_restore.txt`、
      `notification_permission.txt`
    - `data/ui_*.xml` / `01_my_top.xml` ~ `106_shelf_after_restart.xml`（逐步骤语义树）
    - `scripts/ui.py`（本轮 UI dump/点击/截图辅助脚本）

编写：ZCode QA 子代理 ｜ 2026-11-03
