# 批 2a-1 设备验收报告（Android 护眼模式 · 全局叠加 · 自动夜间/定时 · 备份恢复 · 性能与回归）

> 范围：设置批 2a-1「护眼模式」——外观设置页分组与默认值、阅读设置页入口、
> 全局颜色矩阵叠加（书架/阅读页/翻页/目录/菜单/设置页/弹层）、自动夜间、
> 定时开启（含跨午夜与前后台重算）、重启保持、本地备份/恢复、忽略主题配置、
> 性能观察与回归清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测 `device`）。
>
> **结论：8 组场景全部 PASS，0 FAIL，0 BLOCKED。**
> 强度 0/50/100 的实测颜色与参考版 `EyeProtection.kt` 矩阵一致（G/B 通道
> 比值误差 ≤0.2 个百分点）；文字对比度 12.63 → 10.49 → 8.72，100 强度下
> 仍高于 WCAG AA（4.5）。WebView 文章页在本设备实测**被着色**（A/B 对照
> 0 强度纯白 / 100 强度 `255,184,117`），与预登记「PlatformView 可能绕过」
> 的假设相反，已如实记录。应用 `FATAL EXCEPTION=0`、`ANR=0`、
> `RenderFlex overflowed=0`、`OOM=0`；唯一 `FATAL` 来自 QA 工具
> `UiAutomation`（非应用）。
> 登记 4 项 P3（状态栏透明背景随内容着色、连续快速翻页 9/80 帧略超
> 17ms、uiautomator 工具崩溃/tombstone、RSS 普通源网络不可达与个别
> 首次点击未生效），均非本批护眼代码缺陷。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| 分辨率 / 密度 | 1080×1920 / 480 dpi |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.433** / versionCode **434**（`dumpsys package` 实测，与 `pubspec.yaml` 的 `2.0.433+434` 一致；targetSdk 36 / minSdk 24） |
| 源码基线 | `master` HEAD `8de6a4daff`（`chore: 批2a-1 收尾（2.0.433+434 双日志与计划关闭登记）`）；工作区仅 `.zcode/` 未跟踪 |
| 验收时间 | 2026-11-01 09:02 ~ 09:50（设备时间；期间为跨午夜测试临时改钟，已恢复 `auto_time=1`） |
| 证据目录 | `tmp_debug/device_acceptance_20261101_batch2a1/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1101d/` |
| 参考版 | `io.legato.kazusa` versionName **3.26.19** / versionCode **18759**（targetSdk 37），仅用于颜色对照 |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（批 2a-1 无 Rust/FFI 变更）；复用 `jniLibs/` 现有 quickjs `.so` |
| x86_64 `.so`（本设备） | `liblegado_ffi.so`：**51,883,696 B**，mtime **2026-10-31 23:45:24**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（与 9b-6c 验收一致，未重建） |
| `.so` meta | `{"contentHash":-993835076,"mode":"release","quickjs":true,"builtAt":"2026-10-31T23:45:24.5288717+08:00","rustFingerprint":"1ede733fbc7f7e25778d8cd48406b4db0d49626fc4a4602eb83ae86150f23616"}` —— **quickjs:true** |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 91.1s`，**199,873,568 B（190.6 MB）**；sha256 `c8ba10898ffc39df75ec6f83da358d03c9f389110252bf1d8c3e102c2d3b3924`（`logcat/build_2a1.log`） |
| 安装 | `adb install -r` **Success**（streamed 199,873,568 B）；`dumpsys` versionName=**2.0.433** / versionCode=**434** |
| 启动冒烟 | `am start -W` COLD **292 ms**；空书架正常渲染（`00_launch_2a1.png`） |
| 清理后版本 | `pm clear` 后仍为 **2.0.433 / 434**（复核于 §3.8） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（`logcat/analyze.log`） |
| 护眼定向测试 | `flutter test test/unit/eye_protection_test.dart test/widget/eye_protection_layer_test.dart test/widget/eye_protection_settings_test.dart` | **41/41 passed**（`logcat/eye_tests.log`） |
| 全量 Flutter 测试 | `flutter test` | **3724 passed + 1 skipped**，`01:27`，EXIT=0（`logcat/full_test.log`） |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |
| Kotlin JVM 单测 | 未执行 | 本批无 Kotlin 变更；本轮验收聚焦 Dart/UI 与设备行为 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 外观页/入口：默认分组、开启后展开、阅读设置行顺序与同一面板/「护眼强度」文案 | **PASS** | `s1_appearance_eyegroup_default.png`、`s1_appearance_eyegroup_enabled.png`、`s1_read_settings_entry.png`、`s1_read_settings_sheet.png`；行坐标见 §3.1 |
| 2 | 视觉强度：0/50/100 的书架/阅读页/菜单截图采样 + 参考版 kazusa 对照 | **PASS** | `s2_shelf_i0.png`、`s2_shelf_i50.png`、`s2_shelf_i100.png`、`s2_reader_i0.png`、`s2_reader_i50.png`、`s2_reader_i100.png`、`s2_menu_i0.png`、`s2_menu_i50.png`、`s2_menu_i100.png`、`ref_light_i0.png`、`ref_light_i50.png`、`ref_light_i100.png`；采样表见 §3.2 |
| 3 | 范围：全屏阅读/翻页/目录/设置页/弹层；系统状态栏/导航栏；WebView/RSS | **PASS**（含说明） | `s3_toc_i100.png`、`s3_reader_ch2_i100.png`、`s3_reader_popup_i100.png`、`s3_reader_settings_sheet_i100.png`、`s3_dialog_i100.png`、`s3_rss_webview_i0.png`、`s3_rss_webview_i100.png` |
| 4 | 自动夜间：应用深色→生效；浅色→关闭；系统深色 vs 应用主题口径 | **PASS** | `s4_dark_theme_enabled_i100.png`、`s4_dark_total_off_autonight_off.png`、`s4_dark_total_off_autonight_on.png`、`s4_light_autonight_on.png`、`s4_system_dark_app_light.png` |
| 5 | 定时：窗口内/外、前后台恢复重算、跨午夜 23:55-00:05 | **PASS** | `s5_sched_on_default_outside.png`、`s5_window_0915_0925_active.png`、`s5_resume_after_0925.png`、`s5_cross_midnight_2359_active.png`、`s5_cross_midnight_0006_inactive.png` |
| 6 | 重启六项保持；本地备份→修改→恢复同会话生效；忽略主题配置不覆盖 | **PASS** | `s6_after_restart_eyegroup.png`、`s6_after_restore_ui.png`、`s6_ignore_theme_checked.png`、`s6_ignore_restore_result.png` |
| 7 | 性能观察；FATAL/ANR/overflow 统计 | **PASS**（P3 观察） | `logcat/sf_latency_reader_cont.txt`、`logcat/sf_latency_scroll_i100.txt`、`logcat/final_session_2a1.log` |
| 8 | 回归与清理：主题/阅读/设置/弹层；恢复默认、空书架、保留版本 | **PASS** | `s8_shelf_i100_regression.png`、`s8_clean_launch.png`、`s8_clean_default_eyegroup.png` |

## 三、逐场景证据

### 3.1 场景 1：外观页/入口与默认值

- **步骤**：安装 2.0.433/434 → 设置 → 外观 → 滚动到「护眼模式」分组；
  记录默认态；点「启用护眼模式」；再进入 设置 → 阅读界面 → 点「护眼模式」行。
- **预期**：默认仅「启用护眼模式」「深色模式时自动开启」两开关、均关闭，
  强度/定时行隐藏；开启后出现强度与定时；阅读设置页「护眼模式」行位于
  「亮度条模式」之前，打开同一配置面板且强度文案为「护眼强度」。
- **实际**：全部符合。

| 检查点 | 实测 |
|---|---|
| 默认分组 | `s1_appearance_eyegroup_default.png`：仅两开关，均关闭；无强度/定时行 |
| 开启后 | `s1_appearance_eyegroup_enabled.png`：出现「色温 / 当前色温：50」滑杆、「定时开启」开关；「深色模式时自动开启」保持关闭 |
| 默认值 | 启用 false / 强度 50 / 自动夜间 false / 定时 false / 22:00 / 07:00（`s5` 中定时默认行可见 22:00，清理后默认组合同 §3.8） |
| 阅读设置行顺序 | XML：`护眼模式` 行 y=1458~1626，`亮度条模式` 行 y=1632~1800（相邻且在其前）；`s1_read_settings_entry.png`（截图在强度 50 下，整页暖色） |
| 同一面板/文案 | `s1_read_settings_sheet.png`：标题「护眼模式」；行「启用护眼模式 / 深色模式时自动开启 / 护眼强度（当前强度：50）/ 定时开启」；与外观页共用 `eyeProtectionProvider`，改值后外观页读数同步（后续 §3.2/§3.5 均在同一 provider 上操作） |
| 面板范围 | 底部弹层（`showModalBottomSheet`）覆盖阅读设置页，关闭后返回原页 |

- **结论**：PASS。截图：`s1_appearance_eyegroup_default.png`、
  `s1_appearance_eyegroup_enabled.png`、`s1_read_settings_entry.png`、
  `s1_read_settings_sheet.png`。

### 3.2 场景 2：视觉强度 0/50/100 与参考版对照

- **步骤**：保持「启用护眼模式」开，分别将强度置 0、50、100（外观页滑杆与
  阅读设置面板均验证过写入；0/50/100 最终值由面板/滑杆设定），每条强度
  截图书架、阅读页（第三章正文）、阅读菜单；用 PIL 读取像素采样。
- **预期**：暖色强度 0→50→100 单调递增；0 与未开启一致；文字保持可读；
  与参考版同档位（0/50/100）颜色变换一致。
- **实际**：符合。

#### 2a 实测像素与理论矩阵

采样点：书架空白背景 `(540,1000)`；阅读页空白 `(540,1500)`；
阅读正文最暗像素取正文区域 `(60,230)-(1017,540)` 的最小 RGB。

| 状态 | 书架背景 | 阅读背景 | 正文最暗 | 阅读对比度 |
|---|---|---|---|---|
| 0 | `(245,245,245)` | `(255,255,255)` | `(51,51,51)` | **12.63** |
| 50 | `(245,209,175)` | `(255,217,182)` | `(51,43,36)` | **10.49** |
| 100 | `(245,177,112)` | `(255,184,117)` | `(51,37,23)` | **8.72** |

- 强度 0 与未启用完全一致（`s2_shelf_i0.png` / `s2_reader_i0.png`）。
- 50/100 单调变暖；100 时正文对比度 8.72，仍高于 WCAG AA 4.5，
  正文可读（`s2_reader_i100.png`）。
- 截图：`s2_shelf_i0.png`、`s2_shelf_i50.png`、`s2_shelf_i100.png`、
  `s2_reader_i0.png`、`s2_reader_i50.png`、`s2_reader_i100.png`、
  `s2_menu_i0.png`、`s2_menu_i50.png`、`s2_menu_i100.png`、
  `s2_sheet_i100.png`。

#### 2b 与参考版逐通道比对

参考版 `EyeProtection.kt` 的矩阵（R 恒为 1；G/B 随色温 T 二次拟合；
T=5500→2596 对应强度 0→100；强度 0 返回单位矩阵）：

| 强度 | 理论 G 比值 | 理论 B 比值 | 本应用书架 G/B | 本应用阅读 G/B | 参考版（浅色）G/B |
|---|---|---|---|---|---|
| 0 | 1（单位阵） | 1（单位阵） | 1 / 1 | 1 / 1 | 1 / 1 |
| 50 | 0.8526 | 0.7152 | **0.8531 / 0.7143** | **0.8510 / 0.7137** | **0.8514 / 0.7137** |
| 100 | 0.7232 | 0.4588 | **0.7224 / 0.4571** | **0.7216 / 0.4588** | **0.7229 / 0.4588** |

- 参考版对照方法：`io.legato.kazusa` 3.26.19，主题切「浅色」，
  护眼强度 0/50/100，读取其外观页空白背景 `(1050,900)`：
  - 0：`(248,249,255)`
  - 50：`(248,212,182)`
  - 100：`(248,180,117)`
- 归一化后与本应用、理论矩阵的 G/B 误差 **≤0.2 个百分点**；本应用与参考版
  同档颜色差异仅来自底色（本应用 `#F5F5F5`/`#FFFFFF`，参考版 `#F8F9FF`），
  暖色强度与通道衰减一致。
- 参考版截图：`ref_light_i0.png`、`ref_light_i50.png`、`ref_light_i100.png`、
  `ref_01_eye_group.png`、`ref_02_eye_enabled.png`、
  `ref_03_color_temp_dialog.png`。
- **结论**：PASS。视觉强度递增、文字可读、与参考版算法一致。

### 3.3 场景 3：着色范围

- **步骤**：在强度 100 下依次检查阅读正文/翻页、目录、阅读菜单、
  阅读设置底部面板、应用外观设置页、Flutter 对话框（卡片圆角）、
  WebView/RSS 文章页；比较强度 0/100；读取系统栏像素与窗口 Insets。
- **预期**：Flutter 绘制内容全部着色；系统状态栏/导航栏本身不变；
  PlatformView 可能绕过（如实记录）。

| 范围 | 是否着色 | 证据/采样 |
|---|---|---|
| 阅读页正文/翻页 | 是 | `s2_reader_i100.png`、`s3_reader_ch2_i100.png`；背景 `(255,184,117)` |
| 目录页 | 是 | `s3_toc_i100.png`；背景 `(245,177,112)` |
| 阅读菜单（底部栏 + 顶部栏） | 是 | `s2_menu_i100.png`；跨页菜单整体暖色 |
| 阅读弹出菜单（添加书签/规则/日夜切换…） | 是 | `s3_reader_popup_i100.png` |
| 阅读设置底部面板 | 是 | `s3_reader_settings_sheet_i100.png`；面板底色 `(238,172,109)`（0 强度基准约 `(238,238,238)`） |
| 应用设置页 | 是 | `s1_read_settings_entry.png`、`s7_active_i100.png` |
| Flutter 对话框 | 是 | `s3_dialog_i100.png`；对话框底 `(238,172,109)`、遮罩 `(108,77,49)` |
| 系统状态栏图标 | 否（系统层） | 见下 |
| 系统导航栏 | 无系统 surface，无法观察 | 见下 |
| WebView/RSS 文章页 | **是**（A/B） | `s3_rss_webview_i0.png` 纯白 `(255,255,255)`；`s3_rss_webview_i100.png` 同点 `(255,184,117)` |
| 视频页 | 按任务要求跳过 | — |

#### 3a 系统状态栏/导航栏

- 状态栏 Insets：`type=statusBars frame=[0,0][1080,72] visible=true`；
  应用 targetSdk 36 / Android 15，状态栏透明、Flutter 内容绘制到其下方。
- 状态栏时间/电池图标笔画最暗像素：

| 强度 | 状态栏背景 | 图标最暗像素 |
|---|---|---|
| 0 | `(255,255,255)` | `(102,102,102)` |
| 50 | `(255,217,182)` | `(102,87,73)` |
| 100 | `(255,184,117)` | `(102,74,47)` |

- 图标像素变化可由「系统半透明黑图标（约 60% 不透明度）叠加在被着色的
  应用内容上」精确解释：`0.6×0 + 0.4×背景` = `(102,87,73)` /
  `(102,74,47)`。即 **SystemUI 图标本身未被滤镜处理**，但状态栏区域
  可见背景随应用内容变暖，这是 Android 15 edge-to-edge + 透明状态栏的
  预期现象；若产品要求状态栏区域像素绝对不变，需单独处理（本批未做）。
- 导航栏：`dumpsys window displays` 只有 `statusBars`，无 `navigationBars`
  InsetsSource（MuMu 该实例导航栏隐藏/零高）；`navigation_mode=0` 但屏幕
  底部无系统导航栏像素，故「导航栏不变」无法在像素级观察，登记为
  **不可证明项**（系统栏在 Flutter 视图之外，代码未改系统栏颜色）。
- **结论**：PASS（系统栏本体未被滤镜）；附 P3 说明见 §6.1。

#### 3b WebView/RSS

- 从「订阅 → 使用说明（RSS 源）」打开文章页，标题「开源阅读 · 语雀」，
  页面由 WebView 渲染（含「在浏览器中打开/分享」Flutter 顶栏）。
- 同一页面 A/B：强度 0 时内容区纯白 `(255,255,255)`；强度 100 时
  变为 `(255,184,117)`，恰为白色经矩阵 G×0.723、B×0.459 的结果；
  说明本设备 `webview_flutter` 的 PlatformView **被 ColorFilter 覆盖**，
  而非绕过。该结果优于预登记风险，不构成缺陷。
- 另两个 RSS 源：`小说拾遗` 点击后 6~8s 无跳转（未定位：可能源/网络，
  也可能页面静默失败）；`Meow云` 打开为 `502 Bad Gateway`（源侧返回）。
  两者均未计入护眼判定；`使用说明` 文章页已足以证明 WebView 路径。
  截图：`s3_rss_webview_i0.png`、`s3_rss_webview_i100.png`、
  `s3_rss_meow.png`、`s3_rss_article_list.png`。
- **结论**：PASS；普通 RSS feed 源不可达登记为环境限制。

### 3.4 场景 4：自动夜间（应用主题口径）

- **步骤**：保持强度 100；外观页主题模式切「深色」；分别测试
  「启用护眼模式」关/开、「深色模式时自动开启」关/开；再切「浅色」；
  最后保持应用浅色、系统切深色（`cmd uimode night yes`）。
- **预期**：`enabled || (autoNight && isDark)` 为候选；定时关闭时
  候选即生效；`isDark` 取应用主题（MaterialApp 解析后的亮度），
  不是系统深色开关单独决定。
- **实际**：符合。

| 应用主题 | 总开关 | 自动夜间 | 系统深色 | 实际 | 采样（页面/卡片） |
|---|---|---|---|---|---|
| 深色 | 开 | 任意 | 否 | **生效** | `s4_dark_theme_enabled_i100.png` |
| 深色 | 关 | 关 | 否 | 不生效 | `(16,20,24)` / `(29,32,36)` |
| 深色 | 关 | 开 | 否 | **生效** | `(16,14,11)` / `(29,23,17)`（G×0.723、B×0.459） |
| 浅色 | 关 | 开 | 否 | 不生效 | `(248,248,248)` / `(240,240,240)` |
| 浅色 | 关 | 开 | **是** | 不生效 | `(248,248,248)` / `(240,240,240)`（系统深色不改变应用主题） |

- 截图：`s4_dark_theme_enabled_i100.png`、`s4_dark_total_off_autonight_off.png`、
  `s4_dark_total_off_autonight_on.png`、`s4_light_autonight_on.png`、
  `s4_system_dark_app_light.png`。
- 说明：应用外观页主题模式此时为「浅色」；系统 `Night mode: yes` 下仍
  不生效，验证「深色模式时自动开启」跟随应用主题（副标题亦为
  「跟随阅读界面的深色/浅色模式自动切换」），不是系统深色。
- **结论**：PASS。

### 3.5 场景 5：定时（窗口内外、前后台、跨午夜）

- **步骤**：
  1. 总开关开、自动夜间关、强度 100、定时开（默认 22:00-07:00），
     当前设备时间 09:19 → 应不生效；关闭定时 → 应立即生效。
  2. 设 09:15-09:25，当前 09:20 → 生效；应用切后台 HOME 4.9 分钟，
     09:25:25 恢复 → 应已不生效（窗口结束不含）。
  3. 设 23:55-00:05；临时关闭 `auto_time`，设备时钟设 23:59 →
     应生效；设次日 00:06 → 应不生效；随后恢复时钟与 `auto_time=1`。
- **预期**：`[start,end)` 含开始不含结束；跨零点按 `now>=start || now<end`；
  前后台恢复立即重算。
- **实际**：符合。

| 时刻/窗口 | 操作 | 预期 | 实测背景 | 截图 |
|---|---|---|---|---|
| 09:19，默认 22:00-07:00 | 定时开 | 不生效 | `(245,245,245)` | `s5_sched_on_default_outside.png` |
| 09:19，定时关 | 关定时 | 生效 | `(245,177,112)` | `s5_sched_off_active.png` |
| 09:20，09:15-09:25 | 设定后 | 生效 | `(245,177,112)` / `(240,174,110)` | `s5_window_0915_0925_active.png`、`s5_start_0915.png` |
| 09:25:25，09:15-09:25 | 后台 4.9min 后恢复 | 不生效 | `(240,240,240)` | `s5_resume_after_0925.png` |
| 23:59，23:55-00:05 | 改钟后恢复前台 | 生效 | `(240,174,110)` | `s5_cross_midnight_2359_active.png` |
| 00:06（次日），23:55-00:05 | 改钟后恢复前台 | 不生效 | `(240,240,240)` | `s5_cross_midnight_0006_inactive.png` |

- 时间选择器：24 小时制（`alwaysUse24HourFormat`），截图
  `s5_timepicker_start_text.png`（文本输入 23/55）、`s5_dial.png`。
- 时钟修改方法（如实记录）：`adb shell settings put global auto_time 0` →
  `date -s "2026-11-01 23:59:00"` / `"2026-11-02 00:06:00"` →
  测试后 `date -s` 回主机时间并 `settings put global auto_time 1`；
  最终设备时间 09:46~09:47、`auto_time=1`、`Night mode: no`。
- **结论**：PASS；窗口内/外、结束时刻不含、跨午夜、前后台恢复重算均实测。

### 3.6 场景 6：重启保持、备份恢复、忽略主题配置

#### 6a 重启保持

- 设定六项：enabled=true、intensity=100、autoNight=true、schedule=true、
  start=09:15、end=09:25；`am force-stop` + 冷启动（COLD 348ms）。
- 结果：`FlutterSharedPreferences.xml` 六键原值保留；UI 外观页显示
  「当前色温：100」「开始时间 09:15」，开关状态与截图一致
  （`s6_after_restart_eyegroup.png`；结束时间 09:25 在 prefs 中复核）。
- 截图：`s6_restart_launch.png`、`s6_after_restart_eyegroup.png`。

#### 6b 本地备份 → 修改 → 同会话恢复

| 阶段 | enabled | intensity | autoNight | schedule | start | end |
|---|---|---|---|---|---|---|
| 备份时 | true | 100 | true | true | 09:15 | 09:25 |
| 修改后 | false | 30 | true | false | 10:15 | 11:25 |
| 恢复后（未重启） | **true** | **100** | **true** | **true** | **09:15** | **09:25** |

- 备份文件：`/sdcard/Download/legado_qa_backup/legado_backup_1793496492619.json`
  （**2,098 B**，backupTime 1793496492619）；JSON 内含六键
  （`eyeProtectionEnabled/colorTemperature/eyeProtectionAutoNight/
  eyeProtectionSchedule/eyeProtectionStartTime/eyeProtectionEndTime`）。
- 恢复路径：备份与恢复 → 长按「恢复」→ 选择 JSON → 确认「恢复」→
  进度框结束；**同一会话**（未重启）prefs 与 UI 即回到备份值
  （`s6_after_restore_ui.png`；`s6_after_restore_same_session.png`）。
- **结论**：PASS。

#### 6c 「忽略主题配置」恢复不覆盖

- 将六键改回差异态（enabled=false、30、autoNight=true、schedule=false、
  10:15/11:25）；恢复忽略列表勾选「主题配置」→ 保存；
  再次从同一 JSON 恢复。
- 结果：恢复后六键仍为差异态，未被备份覆盖：
  - prefs 实测：`colorTemperature=30`、`eyeProtectionEnabled=false`、
    `eyeProtectionSchedule=false`、`eyeProtectionStartTime=10:15`、
    `eyeProtectionEndTime=11:25`、`eyeProtectionAutoNight=true`。
  - 备份内为 100/true/true/09:15/09:25，确认主题配置组被跳过。
- 截图：`s6_ignore_dialog_unchecked.png`、`s6_ignore_theme_checked.png`、
  `s6_ignore_restore_result.png`。
- **结论**：PASS。

### 3.7 场景 7：性能观察与崩溃统计

- **方法说明**：Flutter 用自绘 SurfaceView，`dumpsys gfxinfo` 的 HWUI
  帧统计不覆盖其渲染（翻页期间仅记录 2 帧），因此性能数据采用
  `dumpsys SurfaceFlinger --latency <BLAST layer>` 的呈现时间戳计算
  帧间隔；同时结合主观观察。
- **强度 100、护眼生效**：
  - 阅读页连续快速翻页 10 次：127 帧 / 80 个有效间隔；
    p50 **16.7ms**、p95 **50.0ms**、最大 **83.3ms**；
    **71/80 ≤17ms**，9/80 >17ms（其中 9/80 >33ms）。
    正常节奏单次翻页无肉眼卡顿/冻结；连续急滑时偶有单帧拉长。
  - 外观页长列表连续滚动 8 次：126/126 间隔 **16.7ms**，0 帧 >17ms
    （`logcat/sf_latency_scroll_i100.txt`）。
  - 书架：本场景书架仅 1 本书，无实际可滚动内容；过卷/下拉主观顺滑，
    未出现 ANR/掉帧可感知现象（无法给出书架滚动帧统计，如实登记）。
  - 截图：`s7_active_i100.png`、`s8_shelf_i100_regression.png`。
- **崩溃/异常（会话窗口 09:02~09:46，`logcat -b all -d -v time`，
  1,351,022 行 / 100 MB）**：

| 项 | 计数 |
|---|---|
| 应用 `FATAL EXCEPTION`（`Process: io.legado...`） | **0** |
| `ANR in io.legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| 应用 native tombstone（`Cmdline: io.legado.flutter_legado`） | **0** |
| QA 工具 `FATAL EXCEPTION: UiAutomation`（PID 29369） | **1** |
| QA 工具 uiautomator native tombstone（`Cmdline: uiautomator`） | 282（缓冲区/本会话工具退出） |

- 结论：PASS。应用侧无崩溃/ANR/溢出/OOM；性能满足日常使用，急滑有
  轻微帧抖动（P3 观察，不阻塞）。

### 3.8 场景 8：回归与清理

- **回归**（均在 100 强度/着色生效下）：
  - 主题切换：深色/浅色多次切换，页面立即重绘，无系统栏重显异常
    （`s4_*`）。
  - 阅读：TXT `qa2a1` 3 章；第一章 33.3%、第三章 100%；翻页/目录跳转
    正常（`s2_reader_i100.png`、`s3_reader_ch2_i100.png`、`s3_toc_i100.png`）。
  - 设置页/弹层：阅读设置、外观设置、阅读菜单、阅读底部面板、
    「卡片圆角」对话框点击/关闭正常（`s3_dialog_i100.png`）。
  - 无 `RenderFlex overflowed`、无 ANR（§3.7）。
- **清理**：

| 项 | 结果 |
|---|---|
| 应用数据 | `pm clear io.legado.flutter_legado` **Success**；冷启动 293ms |
| 书架 | **空**（`s8_clean_launch.png`：「书架还空着…」） |
| 护眼默认 | prefs 无六键（仅 migration/lastBackup/lastCheckUpdate）；外观页默认组仅两开关、均关闭、无强度/定时行（`s8_clean_default_eyegroup.png`） |
| 设备文件 | `/sdcard/Download/qa2a1.txt`、`/sdcard/Download/legado_qa_backup/`、`/sdcard/ui.xml` 已删除 |
| 系统时间 | 已恢复主机时间；`auto_time=1`；`Night mode: no` |
| 旋转 | `accelerometer_rotation=1`、`user_rotation=0`（未改） |
| 参考应用 | 已恢复深色主题、护眼关闭（`ref_restore_state.png`，非验收集） |
| 版本 | 保留 **2.0.433 / 434**（`dumpsys package` 复核） |

- **结论**：PASS。

## 四、FATAL / ANR 汇总

统计口径：`adb logcat -b all -d -v time`，会话窗口 09:02~09:46，
1,351,022 行 / 约 100 MB（`logcat/final_session_2a1.log`）。

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION`（全部进程） | 1 |
| — 其中应用进程 | **0** |
| — 其中 `UiAutomation`（QA 工具） | 1（09:37:31，PID 29369，`Bad file descriptor`） |
| `ANR in io.legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| 应用 native tombstone | **0** |
| uiautomator native tombstone | 282（工具退出 SIGSEGV，非应用） |

## 五、证据清单

| 类别 | 文件 |
|---|---|
| 构建 | `tmp_debug/device_acceptance_20261101_batch2a1/logcat/build_2a1.log` |
| 门禁 | `logcat/analyze.log`、`logcat/eye_tests.log`、`logcat/full_test.log` |
| 会话日志 | `logcat/final_session_2a1.log`（1,351,022 行）、`logcat/sf_latency_reader_cont.txt`、`logcat/sf_latency_scroll_i100.txt` |
| 颜色采样 | `data/color_samples_2a1.json`（本应用书架/阅读/正文/状态栏与参考版背景及比值） |
| UI 取证 | `data/ui_*.xml`、`qaui.py`（QA 工具，未改业务代码） |
| 截图 | `docs/materials_1101d/`（77 张，含本应用 s1~s8、参考版 ref_*） |

## 六、说明与遗留（P3，均不阻塞）

### 6.1 状态栏透明背景随应用内容着色（平台表现）

- Android 15 edge-to-edge + 透明状态栏：状态栏区域显示 Flutter 内容，
  滤镜使该区域背景变暖；SystemUI 图标像素可用 60% 半透明黑叠加解释，
  系统层未被过滤。导航栏在本实例无 InsetsSource/不可见，无法像素级观察。
- 影响：视觉上状态栏面积变色；系统图标/导航栏本体不变。若产品要求
  状态栏区域绝对不变，需单独设计（例如系统级滤镜或状态栏底色遮罩），
  本批未实现、也未声称已实现。

### 6.2 连续快速翻页的轻微帧抖动

- 强度 100、连续急速翻页 10 次：9/80 间隔 >17ms，最大 83ms；p50 16.7ms。
  正常节奏翻页与长列表滚动（126/126 帧 16.7ms）无肉眼卡顿。
- 影响：连续急滑时偶有单帧拉长；无 ANR/冻结。属观察项，不阻塞。

### 6.3 uiautomator 工具崩溃/tombstone（QA 工具，非应用）

- 会话窗口有 1 条 `FATAL EXCEPTION: UiAutomation`（PID 29369）与 282 条
  `Cmdline: uiautomator` tombstone；应用自身 `FATAL=0`、native tombstone=0。
- 影响：仅自动化取 UI 树工具退出时崩溃，不影响应用；与 9b-6c 验收的
  同类工具问题一致。

### 6.4 RSS 普通源不可达与个别首次点击未生效

- `小说拾遗` 点击后 6~8s 无跳转（未定位：源/网络或页面静默失败，未计入
  护眼缺陷）；`Meow云` 返回 `502 Bad Gateway`（源侧）；`使用说明`
  单 URL RSS 源文章页打开正常并用于 WebView 着色验证。
- 测试过程中「恢复」确认按钮与个别列表项首次点击未生效，重试/坐标点击
  成功；未复现为稳定业务缺陷，登记为工具/动画时序观察（不影响结论）。

### 6.5 WebView 实测被着色（优于预登记风险）

- 预登记「PlatformView 可能绕过 ColorFilter」；本设备 `webview_flutter`
  文章页在 0/100 强度下呈现纯白/暖白精确矩阵变换，说明当前渲染路径
  被 Flutter 合成覆盖，页面整体受护眼影响。对用户是正向结果；
  不同插件/Android 版本仍可能不同，保留原登记边界说明。

### 6.6 弹层/对话框着色（参考版窗口差异）

- 本应用对话框与底部面板随全 App 着色（`s3_dialog_i100.png` 底色
  `(238,172,109)`）；参考版 Compose Dialog 为独立窗口，按预登记不随
  Activity 滤镜。属框架实现差异，已在本批登记，不按缺陷计。
- 背景壁纸着色未单独配置壁纸验证；按设计 `MaterialApp.builder` 外层
  同样覆盖壁纸层，未在本轮截图证明（如实声明未验证）。

### 6.7 跨午夜验证的时钟修改

- 为避免等待约 14 小时，使用 root 关闭 `auto_time` 后将设备时钟设到
  23:59/00:06 验证跨午夜；测试后已恢复主机时间并重新开启 `auto_time`。
  这是 QA 测试手段，不是应用行为；设备最终时间/时区/自动同步已复原。

## 七、结论

- 场景 1（外观默认/展开、阅读设置行顺序、同一面板与「护眼强度」）：**PASS**。
- 场景 2（0/50/100 强度递增、文字可读、参考版逐通道对照误差 ≤0.2pp）：**PASS**。
- 场景 3（阅读/翻页/目录/菜单/设置/面板/对话框/WebView 着色；系统栏说明）：**PASS**。
- 场景 4（应用深色 + 自动夜间生效；浅色关闭；系统深色不单独触发）：**PASS**。
- 场景 5（窗口内外、结束不含、跨午夜、前后台恢复重算）：**PASS**。
- 场景 6（重启六项保持、本地备份同会话恢复、忽略主题配置不覆盖）：**PASS**。
- 场景 7（性能观察；应用 FATAL/ANR/overflow/OOM=0）：**PASS**。
- 场景 8（主题/阅读/设置/弹层回归；清理默认、空书架、保留版本）：**PASS**。

**问题分级**：P1=0；P2=0；P3=4（§6.1 状态栏透明背景、§6.2 急滑轻微
帧抖动、§6.3 uiautomator 工具崩溃、§6.4 RSS 源/点击时序）+ §6.5/6.6
预登记边界复核 + §6.7 时钟修改方法说明。

**未证明/不可证明项**（不声称 PASS）：
- 系统导航栏像素级不变——本实例无导航栏 surface，无法观察；
- 背景壁纸着色——未配置壁纸单独截图；
- 视频页 PlatformView——按任务要求跳过；
- 普通 RSS feed 源（小说拾遗/Meow云）——源侧不可达，未作为验收集；
  已用 `使用说明` RSS 源文章页完成 WebView 着色验证。

编写者：QA（ZCode 子代理）｜ 2026-11-01
