# 批 M2「我的」页设备验收报告（Web 服务标准开关行 · 运行中动作行 · 视觉对齐）

> 范围：版本 **2.0.439+440**（HEAD `c2ba5f5f16`）「我的」页 M2 视觉与交互对齐：
> Web 服务块改为无标题分组内标准开关行（裸图标/标题/副题/行内开关）、
> 运行中地址与「复制地址」「在浏览器中打开」动作行（右对齐、组外贴邻）、
> busy 态、深色/大字体、容器背景/边框组合、360×640 小屏、回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`），Android 15 / SDK 35 / x86_64。
> 参考版：`io.legato.kazusa` **3.26.19**（versionCode 18759），同机对照；
> 另装原版 `com.legado.app.release`（本批未使用）。
>
> **结论：8 组场景全部 PASS（P1=0、P2=0、P3=3 登记）。**
> 目标行为逐项实测成立：Web 服务为组内标准开关行（无整卡描边/图标槽）；
> 运行中显示局域网地址与右对齐动作行；复制/打开不切换开关、不停服；
> 停止后动作行收起；busy 期行禁用且前置 spinner（启动帧已捕获）；
> 深色 + 字体 1.3/1.6 整页滚动 overflow=0；容器背景图 + 自定义边框/圆角下
> 动作行位于分组边框之外（M2 已登记偏差，默认主题无视觉差异）；
> 360×640 运行/停止无溢出、按钮不误触；断网回落 `127.0.0.1（本机）`、
> 恢复网络后刷新回局域网地址；FATAL=0、ANR=0、overflow=0、E/flutter=0。
> P3 项为图标语义差异、动作行组外（已登记、建议 M3 决策）、超大字体换行排版。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（3x，即 **360×640 dp**） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备 root | `adb shell id` = `uid=0(root)`（可读取 `shared_prefs` 取证） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.439** / versionCode **440**（安装后与清理后各复核） |
| 源码基线 | `master` HEAD **`c2ba5f5f1678da31692acb35ede3698602f51fc4`**（`chore: M2 我的页收尾（2.0.439+440 双日志与计划登记）`） |
| 参考版 | `io.legato.kazusa` 3.26.19（18759），同机 |
| 验收时间 | 2026-11-03 10:47 ~ 11:10（宿主时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_m2/`（logcat/data/scripts/shots，不入库） |
| 截图 | `docs/materials_1105/`（47 张：`m2_01`~`m2_41`、`ref_kazusa_*`） |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（`data/so_info.txt`） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 50.5s`，**200,271,412 B（191.0 MB）**；sha256 **`90a2c807bf2df9d3f715ac42805239a4145b1197d671fb321624cc75680a7ecf`**（`logcat/build_release.log`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200271412 bytes**（`logcat/install.log`）；安装后设备侧 `base.apk` sha256 与构建产物**一致**（`data/apk_sha256_installed.txt`） |
| 通知权限 | `POST_NOTIFICATIONS: granted=true`（沿用 M1 授权，未再弹窗，`data/notification_permission.txt`） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（13.0s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/widget/my_page_m1_test.dart test/widget/settings_test.dart test/widget/settings_service_toggle_error_test.dart test/widget/settings_web_foreground_service_test.dart test/widget/settings_home_container_test.dart test/widget/theme_container_settings_test.dart` | **90/90 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量 Flutter 测试 | `flutter test` | **3953 passed + 1 skipped**，EXIT=0（1:40，`logcat/full_tests.log`） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success（见 §1.1） |

> 门禁与构建串行执行，避免 `flutter test` 与 `flutter build` 并发触发
> `GeneratedPluginRegistrant.java` 竞态；设备操作与 `flutter test` 并行（互不干扰）。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | Web 服务标准开关行：顶部无标题分组，裸图标/标题/副题/行内开关；与 kazusa 同机对照 | **PASS**（图标 P3-1） | `m2_01`、`m2_14`、`ref_kazusa_my_top`、`ref_kazusa_running`；`data/01_my_top.xml`、`data/25_my_dark_top.xml` |
| 2 | 运行中动作行：地址显示；「复制地址」「在浏览器中打开」贴邻开关行下方、右对齐；点按不切换开关/不停服；停止收起 | **PASS** | `m2_04b`、`m2_05`、`m2_06`、`m2_08`、`m2_10`、`m2_11`、`m2_13`；`data/06_web_running.xml`、`07_after_copy.xml`、`17_after_browser_back.xml`、`18_web_stopped.xml` |
| 3 | busy 态：启动中行禁用 + 前置 spinner；完成后恢复；不崩溃 | **PASS** | `m2_04a_busy_150ms`；`data/05_web_busy_early.xml`；日志无异常 |
| 4 | 深色 + 系统字体 1.3/1.6：整页滚动无溢出；运行态地址/按钮换行正常 | **PASS**（1.6 换行排版 P3-3） | `m2_14`、`m2_15`、`m2_16`、`m2_17`、`m2_18`、`m2_19`；`logcat/font13.log`、`font16.log`（overflow=0） |
| 5 | 容器背景图 + 自定义边框/圆角：动作行在组外、不被分组边框包裹；符合参考版评估 | **PASS（已登记偏差 P3-2）** | `m2_23`、`m2_25`；`data/45_radius_on.xml`、`46_my_container_combo.xml` |
| 6 | 360×640：运行态/停止态无溢出；按钮不误触 | **PASS** | `m2_27`、`m2_39`；`data/52_360_running.xml`、`53_after_gap_tap.xml`、`71_final_stopped.xml` |
| 7 | 回归：复制/打开/地址刷新、AI 占位、字典、服务与工具、返回键；FATAL/ANR/overflow=0 | **PASS** | `m2_28`、`m2_30`~`m2_35`、`m2_37`、`m2_38_after_resume_lan`；`logcat/session_final.log`、`crash_final.log` |
| 8 | 清理：停服务、恢复外观/主题默认、空书架、保留版本 | **PASS** | `m2_39`、`m2_40`、`m2_41`；`data/prefs_final.xml`、`version_final.txt` |

## 三、逐场景证据

### 3.1 场景 1：Web 服务标准开关行（PASS）

- **步骤**：安装后冷启动 → 底栏「我的」→ 语义树 dump + 截图；随后切深色复截。
- **预期**：顶部无标题分组内是「Web 服务」标准开关行：裸图标（24dp 量级）、
  标题、副题「用浏览器写源或看书」、行内开关；无 48dp 图标槽、无整卡描边/
  Ink 底色。
- **实际**（`m2_01`、`data/01_my_top.xml`）：
  - 语义树仅有单一合并节点 `[48,552][1032,768]`，描述
    「Web 服务\n用浏览器写源或看书」，`clickable=true`；开关与整行同属
    一个语义目标（`MergeSemantics`），行内无 chevron。
  - 行高 216 px（72dp），与参考版 224 px（74.7dp）同量级；行内是裸地球图标
    （24dp），无图标槽底色。
  - 运行/停止切换使用标准 MD3 Switch；行容器为 `surfaceContainerLow` 圆角行卡，
    与其余分组行一致。
- **参考版对照**（`ref_kazusa_my_top`、`ref_kazusa_running`，同机同分辨率）：
  - 同一「顶部无标题分组 + 单开关行」形态，图标/标题/状态副题/行内开关一致；
  - 差异：参考版图标为浏览器窗口语义（`ic_web`），我方为地球
    （`Symbols.language_rounded`）→ **P3-1**；
  - 参考版文案「拷贝 URL」「浏览器打开」，我方按本批验收单用
    「复制地址」「在浏览器中打开」→ 文案差异，非缺陷；
  - 顶栏：参考版为 Flexible 大标题无帮助，我方保留 LargeTitle + 帮助按钮
    （2026-11-03 用户裁决 #3 保留）→ 预期差异。
- **结论**：PASS（图标语义差异登记 P3-1）。

### 3.2 场景 2：运行中地址与动作行（PASS）

| 步骤 | 预期 | 实际 / 证据 |
|---|---|---|
| 点「Web 服务」行 | 开启服务 | 行 `chk=true`；通知权限已授予，无弹窗（`data/06_web_running.xml`） |
| 开启后行副题 | 显示设备局域网地址 | **`http://192.168.100.62:1122`**；与 `ip -4 addr` 的 `192.168.100.62/24` 一致；宿主 `curl` → **HTTP 200**（`data/curl_web.txt`） |
| 动作行位置 | 贴邻开关行下方、右对齐 | 开关行 `[48,552][1032,768]`；动作行 `复制地址 [159,780][490,924]`、`在浏览器中打开 [526,780][984,924]`，右缘 984 px，与参考版右对齐一致；行间隔 4dp（`m2_05`） |
| 点「复制地址」 | 剪贴板=显示地址；开关不变 | Toast **「已复制访问地址」**（`m2_06`）；剪贴板经应用内搜索框长按粘贴读取为 **`http://192.168.100.62:1122`**（`m2_08`、`data/11_pasted.xml`）；开关仍 `chk=true`（`data/07_after_copy.xml`） |
| 点「在浏览器中打开」 | 浏览器打开且服务可达 | 打开 Chrome（安全提示页→继续）显示 **Legado web 导航**（书架/书源/传书/订阅源，`m2_10`、`data/16_browser.xml`） |
| 从浏览器返回 | 开关仍开、地址保持、服务不停 | `data/17_after_browser_back.xml`：`chk=true`、地址不变、动作行仍在；宿主 `curl` **HTTP 200**（`m2_11`） |
| 点开关行停止 | 地址/动作行消失、服务停止 | 副题回「用浏览器写源或看书」，动作节点消失（`m2_13`、`data/18_web_stopped.xml`）；宿主 `curl` **连接失败（000）**；`dumpsys activity services` 无 `WebServerForegroundService` |
| FGS | 运行中有前台服务 | `WebServerForegroundService isForeground=true foregroundId=7778`（`dumpsys`） |

- **说明**：`service call clipboard 6` 在本机返回异常 Parcel（非可读文本），
  故改用真实用户路径（应用内搜索框长按→粘贴）取证，语义树文本即剪贴板内容。
- **文案说明（O-2）**：本批验收单写作「在浏览器打开」，实际按钮文案为
  「在浏览器中打开」；参考版为「浏览器打开」。仅为措辞差异，不影响功能。
- **结论**：PASS（复制/打开均不切换开关、不停服）。

### 3.3 场景 3：busy 态（PASS）

- **步骤**：点开关行后 150 ms / 400 ms 连续截图；dump 语义树；观察完成后恢复。
- **实际**：
  - **150 ms 帧**（`m2_04a_busy_150ms.png`）：整行底色转为禁用态、开关灰置，
    leading 图标位替换为 **轻量 CircularProgressIndicator（可见部分弧）**，
    副题仍为默认文案 —— 行禁用 + 前置 spinner 成立；
  - **400 ms 帧**（`m2_04b_busy_400ms.png`）：服务已启动，副题显示地址、
    动作行展开、开关恢复可交互（`data/05_web_busy_early.xml` 为已完成态）；
  - 停止方向：120 ms/420 ms 帧（`m2_12a`/`m2_12b`）显示停止动作在
    <120 ms 内完成，未捕获到稳定的停止 busy 帧；停止完成后行恢复默认、
    动作行收起（`m2_13`）。**结论按「启动 busy 已证、停止 busy 未直接观测」记录。**
  - 全程无 FATAL/ANR（见 §3.7）。
- **结论**：PASS（启动 busy 已捕获；停止 busy 因耗时过短未捕获，不伪造截图）。

### 3.4 场景 4：深色 / 大字体（PASS，P3-3）

| 子项 | 步骤 | 实际 / 证据 |
|---|---|---|
| 深色 | 设置→外观→深色（prefs `app_theme_mode=dark`）→ 我的运行态 | 整页深色正确，行卡/开关/动作行对比度正常（`m2_14`、`data/25_my_dark_top.xml`） |
| 字体 1.6 | `settings put system font_scale 1.6` → 我的页顶部 + 中段 + 底部 | 地址自动换行为 3 行、两按钮上下两行右对齐（`m2_15`）；中段/底部整页可达（`m2_16`、`m2_17`）；`overflowed by`=**0**（`logcat/font16.log`） |
| 字体 1.3 | `font_scale 1.3` → 我的页顶部 + 滚动到底 | 地址单行、两按钮换行为上下两行右对齐（`m2_18`、`m2_19`）；滚动全程 `overflowed by`=**0**（`logcat/font13.log`） |
| 恢复 | `font_scale 1.0` | 清理阶段已恢复 |

- **P3-3 说明**：大字体下按钮因 `TextButton.icon` 内边距较大在 1.3 即换行，
  1.6 时地址断词为 `http://` / `192.168.100.62:112` / `2`。无溢出、可操作，
  但排版观感一般，建议 M3 评估地址是否改为可选中单行省略或允许横向滚动。
- **结论**：PASS。

### 3.5 场景 5：容器背景图 + 自定义边框/圆角（PASS，已登记偏差 P3-2）

- **步骤**（真实用户路径）：外观→容器设置→开「容器背景图」→
  「容器背景图片（日间）」→ 系统 SAF 选择 `/sdcard/Download/qa_m2_bg.png`
  → 开「覆盖卡片边框」（宽度 1dp）→ 开「覆盖卡片圆角」→ 返回「我的」。
- **实际**：
  - 图片选取成功并落盘：`theme_backgrounds/large_light/5d8bbabf2cc9a51eda3cafa8543937a9.png`
    （`m2_21`、`m2_22`、`data/39_saf_picker.xml`、`40_after_pick.xml`）；
  - 「我的」页（`m2_25`、`data/46_my_container_combo.xml`）：
    **Web 服务行被分组边框/圆角包裹（单行分组），动作行位于该分组边框之外**，
    为独立的右对齐文字按钮区，未被圆角裁剪、未被边框环绕；
  - 分组行缝可见容器背景图（本测试图是深色截图，故 2dp 行缝呈深色横线，
    属图片内容透过行缝，非渲染缺陷）；
  - 参考版动作行 Row 位于分组 Column 内（`MyScreen.kt` / M2 计划依据；截图中
    按钮本身无独立卡片，见 `ref_kazusa_running`），因此参考版在开启容器背景/
    边框时动作行会被包在容器内。
- **符合性评估**：默认外观（无容器背景/边框）下二者视觉一致（§3.1/§3.2）；
  仅自定义容器风格叠加时出现可见差异。**判为可接受的 M2 登记偏差**：
  动作行在组外、贴邻 4dp、右对齐，功能与点击区域正确；
  若要完全对齐参考版，需 `IosGroup` 支持「无卡片 child」后无损回移组内（建议 M3）。
- **恢复**：验证后 `am force-stop` → prefs 关闭三项开关、移除图片键并删除
  `files/theme_backgrounds/` → 重启复核（`data/prefs_restored.xml`、
  `m2_26`；重启后行样式恢复正常）。
- **结论**：PASS（差异已登记 P3-2）。

### 3.6 场景 6：360×640 运行态/停止态（PASS）

- **基线**：1080×1920 / 480 dpi = **360×640 dp**（设备默认，即验收口径小屏）。
- **运行态**（`m2_27`、`data/52_360_running.xml`）：地址单行、动作行单行右对齐；
  开关行 `[552,768]` 与动作行 `[780,924]` 之间存在 12 px（4dp）间隙。
- **不误触**：点击该间隙 `(300,774)` 后，开关仍 `chk=true`、服务仍 `HTTP 200`、
  动作行仍存在（`data/53_after_gap_tap.xml`）；点击「复制地址」亦不改变开关
  （§3.2）。动作行与开关行无重叠点击区域。
- **停止态**（`m2_39`、`data/71_final_stopped.xml`）：副题回默认、动作行消失，
  页面滚动到底无溢出（`overflowed by`=0）。
- **结论**：PASS。

### 3.7 场景 7：回归（PASS）

| 检查点 | 实测 | 证据 |
|---|---|---|
| 复制地址 | Toast + 剪贴板 `http://192.168.100.62:1122`，开关不变 | §3.2；`m2_06`、`m2_08` |
| 浏览器打开 | Chrome 显示 Legado web 导航；返回后状态不变、服务不停 | §3.2；`m2_10`、`m2_11` |
| 地址刷新（断网） | `MuMuManager sh -v 1 -c "svc wifi disable"` → Home → `am start` 冷启 → 副题 **`http://127.0.0.1:1122（本机）`**，动作行仍在 | `m2_37`（离线时 `screencap` 经 MuMuManager 取出）、`data/69_after_net_restore.xml` |
| 地址刷新（恢复） | `svc wifi enable` → Home/回前台 → 副题刷新回 **`http://192.168.100.62:1122`**；宿主 `curl` **200** | `m2_38_after_resume_lan`、`data/70_after_resume_lan.xml` |
| 后台返回 | 运行中 Home → 重新进入，地址/动作行保持 | `data/54_after_resume.xml`、`m2_28` |
| FGS/保活 | 应用退出前台期间服务仍 `HTTP 200`；`WebServerForegroundService` 运行 | §3.2、`dumpsys activity services` |
| AI 聊天占位 | 入口「AI 聊天 / 暂未支持，待 Rust 能力接入」→ 页面「AI 聊天暂未支持 / 待 Rust 能力接入后开放」，无输入框，可返回 | `m2_30`、`data/56_ai_chat.xml` |
| 字典规则 | 单入口进入「字典规则管理」（海词中文/英文/有道/哔哩/百度汉语），顶栏「字典查询」可达 | `m2_31`、`data/60_dict_rule.xml` |
| 服务与工具 | 定时任务页可达（空态）；运行定时任务开关关闭状态复核 | `m2_32`、`data/63_auto_tasks.xml`、`64_autotask_off.xml` |
| MCP 前置提示 | 点按弹 SnackBar「MCP 服务切换失败: ... 请先配置...Web 书源访问令牌」，开关保持关、不崩溃 | `m2_34`、`data/66_mcp_tap.xml` |
| 返回键 | 「我的」返回 → 书架（应用不退出，`topResumedActivity` 仍为 MainActivity） | `m2_35`、`data/67_back_from_my.xml` |
| 稳定性 | 最终窗口 **6,195 行：FATAL EXCEPTION=0、ANR in io.legado=0、RenderFlex overflowed=0、E/flutter=0**；crash buffer 948 行中 `io.legado` **0** 条 | `logcat/session_final.log`、`crash_final.log` |

- **说明**：断网期间 adb 走 wlan0 一并断开，改用 `MuMuManager.exe sh -v 1 -c`
  执行 `input keyevent 3`/`am start`/`screencap`；恢复网络后 `adb pull` 取证，
  截图二进制校验为 1080×1920 PNG。恢复后 IP 一致（`192.168.100.62/24`）。
- **既有缺陷**：本批未复测 M1 登记的 P3 项（Web 服务配置镜像、书架删除刷新、
  关联导入错误态、外部 `legado://dict*` 深链），均非 M2 改动范围。
- **结论**：PASS。

### 3.8 场景 8：清理（PASS）

| 步骤 | 结果 | 证据 |
|---|---|---|
| 停 Web 服务 | 副题回默认、动作行消失、`HTTP 000`、FGS 计数 0 | `m2_39`、`data/71_final_stopped.xml` |
| 恢复主题 | 设置→外观→跟随系统；prefs `app_theme_mode=system`；界面回浅色 | `m2_40`、`data/73_theme_system.xml`、`prefs_final.xml` |
| 恢复外观 | `enableContainerBackgroundImage=false`、`overrideBaseCardBorder=false`、`overrideBaseCardCornerRadius=false`；`files/theme_backgrounds/` 已删除 | `data/prefs_final.xml` |
| 字体 | `font_scale` 恢复 **1.0** | `settings get system font_scale` |
| 定时任务 | 「运行定时任务」复核为关（`checked=false`） | `data/64_autotask_off.xml` |
| 书架 | 空书架（本批未导入书籍） | `data/67_back_from_my.xml` |
| 删除测试文件 | `/sdcard/Download/qa_m2_bg.png`、`/sdcard/qa_netoff.png`、`/sdcard/qa_ui.xml` 已删；本批未遗留 | adb `ls` 无匹配（`/sdcard/` 根目录其他历史截图非本批产物，未动） |
| 版本保留 | **2.0.439 / 440** | `data/version_final.txt` |

## 四、与参考版视觉对照结论（kazusa 3.26.19 同机）

> 对照方法：截取 kazusa 停止态（`ref_kazusa_my_top`）与运行态
> （`ref_kazusa_running`）各一张；运行态通过临时开启其 Web 服务取得，截图后
> 已关闭恢复停止态，未修改其主题/布局等设置（仅滚动位置变化）。

| 维度 | 参考版 | 本版 M2 | 判定 |
|---|---|---|---|
| 顶部结构 | 无标题分组内单开关行 | 同 | 一致 |
| 图标 | 浏览器窗口语义（`ic_web`） | 地球（`Symbols.language_rounded`） | 差异 P3-1（建议对齐） |
| 标题/副题 | Web 服务 / 用浏览器写源或看书 | 同 | 一致 |
| 开关 | 行内 MD3 Switch（开态带勾） | 行内 MD3 Switch | 基本一致（表达差异极小） |
| 运行中地址 | `http://IP:1122` 副题 | 同（含 `（本机）` 回落标注） | 一致（我方多回落标注，M1 已有） |
| 动作行 | 「拷贝 URL」「浏览器打开」，右对齐 | 「复制地址」「在浏览器中打开」，右对齐、带图标 | 文案按本批验收单，位置/对齐一致 |
| 动作行容器归属 | 分组 Column 内（非卡片） | 分组外贴邻（`IosGroup` 限制） | 默认主题无差异；容器背景/边框下可见差异 → P3-2 |
| 顶栏 | Flexible 大标题、无帮助 | LargeTitle + 帮助按钮 | 预期差异（用户裁决 #3） |
| 分组/图标 | 规则 5 项 + 其它 8 项 | 规则 5 项 + 服务与工具 3 项 + 其他 8 项 | 信息架构差异（M1 已裁决保留原版能力） |

## 五、问题清单与分级

| 级别 | 编号 | 描述 | 复现步骤 / 证据 | 归属 |
|---|---|---|---|---|
| P1 | — | 无 | — | — |
| P2 | — | 无 | — | — |
| P3 | P3-1 | **Web 服务行图标语义与参考版不同**：我方地球，参考版浏览器窗口 | 我的页顶部对比 `m2_01` vs `ref_kazusa_my_top` | 视觉细节，建议对齐参考版 `ic_web` 语义 |
| P3 | P3-2 | **动作行位于分组外**（M2 已登记）：默认主题无差异；开启容器背景图 + 自定义边框/圆角后，按钮不被分组圆角/边框包裹，参考版在容器内 | 外观→容器设置三项开启 → 我的页（`m2_25`）；恢复后正常（`m2_26`） | M2 已知限制（`IosGroup` 强制行卡），建议 M3 提供「无卡片 child」后回移 |
| P3 | P3-3 | **大字体下动作行换行/地址断词**：1.3 时两按钮分两行；1.6 时地址断为 3 行（`…112` / `2`），无溢出 | `font_scale 1.3/1.6` → `m2_18`/`m2_15` | 排版优化，建议 M3 评估地址单行省略/可选中等宽度布局 |
| 观察 | O-1 | 「覆盖卡片边框」开启时，测试用深色容器图从 2dp 行缝透出形成深色横线 | `m2_23`、`m2_25` | 非缺陷：图片按设计只在行缝/圆角处可见，测试图本身为深色截图 |
| 观察 | O-2 | 动作按钮文案与验收单/参考版措辞不同：我方「在浏览器中打开」，验收单「在浏览器打开」，参考版「浏览器打开」 | `m2_05` vs `ref_kazusa_running` | 措辞差异，非功能缺陷；如需逐字对齐请统一文案表 |
| 未观测 | U-1 | 停止方向的 busy 帧未捕获（停止 <120 ms 完成） | `m2_12a`/`m2_12b` | 非失败项；启动 busy 已证，停止链路无异常 |

## 六、结论与建议

- **功能结论**：M2 视觉与交互对齐达成验收目标（8/8 场景 PASS）。Web 服务已从
  「大卡」变为顶部无标题分组内的标准开关行；运行中地址 + 右对齐动作行；
  两个操作不切换开关、不停服；停止后动作行收起；busy 期禁用 + spinner；
  深色/大字体/小屏无溢出；断网/恢复地址刷新正确。
- **视觉结论**：默认外观与参考版结构一致；差异集中在图标语义（P3-1）、
  动作行组外（P3-2，仅在自定义容器风格下可见）与大字体换行（P3-3），
  均不阻塞 M2 验收，建议 M3 收敛。
- **稳定性结论**：最终日志窗口 FATAL=0、ANR=0、RenderFlex overflow=0、
  E/flutter=0；crash buffer 无 `io.legado` 记录。
- **门禁结论**：`flutter analyze` 0；定向 90/90；全量 3953 passed + 1 skipped；
  release 构建 EXIT=0；安装成功；版本 2.0.439+440。
- **建议**：
  1. **P3-1**：Web 服务行图标改为参考版浏览器窗口语义（或 `Symbols.web_rounded`），
     保持 24dp 裸图标；
  2. **P3-2**：为 `IosGroup` 增加「无卡片 child」能力，把动作行无损移回分组内，
     使容器背景/边框组合与参考版完全一致；在此之前保持组外贴邻并在计划中留痕；
  3. **P3-3**：大字体下地址显示考虑单行省略 + 长按复制，或按宽度自适应两行
     且不在端口号中间断词；
  4. M1 遗留 P2-1（外部 `legado://dict*` 深链）仍待产品/开发确认口径，非 M2 范围。
- **证据路径**：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261103_M2_MY_PAGE.md`
  - 截图（47 张）：`docs/materials_1105/`（`m2_01`~`m2_41`、`ref_kazusa_*`）
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261103_m2/`
    - `logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
      `build_release.log`、`install.log`、`session_main.log`、`session_final.log`、
      `crash_final.log`、`font13.log`、`font16.log`
    - `data/version_installed.txt`、`version_final.txt`、`apk_sha256.txt`、
      `so_info.txt`、`notification_permission.txt`、`curl_web.txt`、
      `prefs_combo.xml`、`prefs_restored.xml`、`prefs_final.xml`
    - `data/01_my_top.xml` ~ `74_final_my.xml`（逐步骤语义树）
    - `scripts/ui.py`（本轮 UI dump/点击/截图辅助脚本）

编写：ZCode QA 子代理 ｜ 2026-11-03
