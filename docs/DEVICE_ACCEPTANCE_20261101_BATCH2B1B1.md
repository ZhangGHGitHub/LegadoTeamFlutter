# 批 2b-1b-1 设备验收报告（卡片圆角 · 卡片边框 · 设置行分隔线）

> 范围：设置批 2b-1b-1「容器设置」三项卡片视觉覆盖——覆盖卡片圆角（0-40dp）、
> 关闭设置分组圆角（优先于覆盖）、覆盖卡片边框（0-5dp / 日间与夜间色）、
> 显示分隔线（0-5dp / 30-100% / 颜色 0=灰 30%）；含 flat 分组、末行无分隔线、
> 覆盖范围对照（默认 Card vs 显式 shape）、重启保持、备份恢复与「忽略主题配置」、
> 横竖屏颜色对话框、回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`）。
>
> **结论：通过（可选修复 4 项 P3 文案/登记项）。** 8 组场景全部 PASS；
> P1=0、P2=0、P3=4（均为文案不精确或已登记行为，不影响功能）。
> 关键量化：默认 16dp 圆角实测 47.0px（15.7dp，阈值法系统性低约 2%）、行间
> 6px=2dp、无分割线；覆盖圆角 0/12/24/40 实测 0 / 34.1~35.8 / 70.7 / 119.0px；
> 边框 1/3dp 实测 3/9px 且卡片外框 `x=48..1031` 不变；分隔线 50/80/100%
> 实测 492/786/983px（对 984px 外宽 = 50.0/79.9/99.9%），0 色回落
> `(207,207,207)`。会话内应用 FATAL/ANR/OOM/overflow 均 0。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（3x） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| **设备 root 状态** | **`adb shell id` = `uid=0(root)`**（与 `docs/REFACTORING_ACTIVE_PLAN.md` 中「非 root、需 run-as」的旧表述不同；本轮直接读取 `/data/data/<pkg>/shared_prefs/FlutterSharedPreferences.xml` 取证） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.435** / versionCode **436**（安装后与清理后 `dumpsys package` 各复核一次） |
| 源码基线 | `master` HEAD `e41ec854b3`（`chore: 批2b-1b-1 收尾（2.0.435+436 双日志与计划登记）`）；工作区仅 `.zcode/` 与本报告/证据目录未跟踪 |
| 验收时间 | 2026-11-01 22:54 ~ 23:47（设备时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261101_batch2b1b1/`（日志/数据/脚本，不入库）；截图 `docs/materials_1101f/`（81 张） |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（与 2b-1a 验收一致，未重建） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 69.0s`，**200,053,980 B（190.8 MB）**；sha256 `a0bbea90a796114ca601b351ccc2c0bf87cf1e19bebde7468c3c1a00ac88c270`；构建时间 2026-11-01 22:56:21（`logcat/build_2b1b1_retry.log`） |
| 首次构建失败 | 第一次 `flutter build apk --release` **EXIT=1**：`GeneratedPluginRegistrant.java:54` 引用 `dev.flutter.plugins.integration_test`（dev 依赖）导致 `compileReleaseJavaWithJavac` 失败。原因：该文件被**并发的 `flutter test`** 以 debug 插件集重新生成后参与 release 编译（竞态）。单独重跑即 EXIT=0（`logcat/build_2b1b1.log` 失败、`build_2b1b1_retry.log` 通过）。**属构建流程/环境问题**（`flutter test` 与 `flutter build` 不可并发），非源码缺陷 |
| 安装 | `adb install -r` **Success: streamed 200053980 bytes** |
| 冷启动 | 安装后 `am start -W` **324 ms**；后续 386/343/328/406 ms |
| 清理后版本 | `pm clear` 后仍为 **2.0.435 / 436** |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（13.8s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/unit/color_hex_test.dart test/widget/ios_group_card_style_test.dart test/widget/setting_switch_row_test.dart test/widget/theme_card_style_settings_test.dart test/widget/ios_group_container_test.dart test/widget/theme_container_settings_test.dart` | **56/56 passed**，EXIT=0（`logcat/card_style_tests.log`） |
| 全量 Flutter 测试 | 未执行 | 本轮以设备验收为主；定向 56 项覆盖 HEX 解析、IosGroup 卡片样式、开关行、外观页设置 |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |
| Kotlin JVM 单测 | 未执行 | 本批无 Kotlin 变更 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 默认：三项开关默认关；分组卡 16dp 圆角、无边框、行间 2dp、无分割线 | **PASS** | `01_default_container_top.png`、`02_default_container_bottom.png`、`76_clean_container_defaults.png` |
| 2 | 圆角覆盖 0/12/24/40 随之变化；关闭恢复 16；「关闭设置分组圆角」优先；重启保持 | **PASS** | `03`~`06`、`07`、`08`、`09`、`10` |
| 3 | 边框宽 1/3、日间预设+HEX、夜间 HEX（深色）、0 色回落描边、不改尺寸/文字位置、关闭无边框 | **PASS** | `11`、`12`、`14`~`15`、`19`~`21` |
| 4 | 分隔线宽 1/3、长度 50/80/100%、颜色（预设/HEX/0=灰 30%）、卡片+flat 均生效、末行无线、关闭行为、宽 0 不画 | **PASS** | `23`~`37`、`35`、`36` |
| 5 | 覆盖范围：默认 Card 变化；显式 shape（首页/阅读器内阅读界面）不覆盖；副标题说明 | **PASS（含 P3-1 文案偏差）** | `45`、`46`、`47`、`48`、`02` |
| 6 | 重启保持；本地备份→改值→同会话恢复；「忽略主题配置」不保护新键 | **PASS** | `50`、`53`、`54`、`55`、`56`、`data/backup_before.json`、`data/prefs_after_restart.xml` |
| 7 | 回归：阅读/主题切换/容器背景图/护眼/横屏颜色对话框；FATAL/ANR/overflow | **PASS** | `43`、`48`、`63`、`64`、`71`、`72`、`59`、`60`、`logcat/session_2b1b1.log` |
| 8 | 清理：恢复默认、空书架、设备文件、系统设置、版本保留 | **PASS** | `73`、`74`、`76`、`data/prefs_final_clean.xml` |

## 三、逐场景证据

### 3.1 场景 1：默认态（16dp / 2dp / 无边框 / 无分割线）

- **步骤**：`pm clear` 后冷启动 → 我的 → 设置 → 外观 → 滚动到「容器设置」；记录开关默认值、
  分组卡边缘/行间距/是否有分隔线；同一状态另测「设置」首页卡片几何。
- **预期**：三项开关默认关；分组卡 16dp 圆角、无边框；行间 2dp；无分割线。
- **实际**：符合。以下为像素实测量（3x，1dp = 3px）。

| 检查点 | 实测（截图像素） | 换算 |
|---|---|---|
| 分组卡左/右边界 | `x=48 .. 1031`（宽 984px） | 328dp 宽，左右各 16dp 外边距 |
| 圆角（圆拟合，阈值法） | **47.0px** | **15.7dp ≈ 16dp**（算法系统性低 ~2%） |
| 行间距（组卡底色 `(238,238,238)` 条带） | **6px** × 3 处（y=529/910/1243） | **2dp** |
| 分割线 | 间隙内无任何线（纯组卡底色） | 无 |
| 边框 | 页面 `(245,245,245)` → 卡面 `(238,238,238)` 直接过渡，无描边色 | 无 |
| 页面底色 / 行卡底色 | `(245,245,245)` / `(240,240,240)` | 草野浅色调色板 |
| 「设置」首页卡片（`77_settings_home_default.png`） | 圆角 **47.8px（15.9dp）**、无边框、无分割线；**卡间距 30px=10dp** | 16dp 圆角成立；间距不是 2dp |

- **说明（登记，非本批缺陷）**：「设置」首页（`settings_home_screen.dart:62-67`）卡片是
  手写 `Material(color: surfaceContainerLow, borderRadius: 16)` + `SliverList.separated(10)`，
  既不是 `Card` 也不参与 `IosGroup`，因此①行间距为 10dp 而非 2dp；②本批三项覆盖对它无效。
  「行间 2dp」只在「外观」等 `IosGroup` 分组内成立。
- **结论**：PASS（外观页默认形态完全符合；首页差异见 P3-4）。
  截图：`01_default_container_top.png`、`02_default_container_bottom.png`、
  `76_clean_container_defaults.png`、`77_settings_home_default.png`。

### 3.2 场景 2：圆角覆盖 0/12/24/40、恢复 16、禁用分组圆角优先、重启保持

- **步骤**：开「覆盖卡片圆角」→ 滑杆依次置 0/12/24/40（每次读 UI 数值并截图）；
  关闭开关复核恢复；开「关闭设置分组圆角」在 12dp 覆盖下复核；`am force-stop` 冷启动复核。
- **预期**：卡片圆角随数值变化；关闭恢复 16；禁用分组圆角=0 且优先；重启保持。
- **实际**：全部符合。测量对象为视口内完整分组的左上角（圆拟合）。

| 设置值 | UI 读数 | 实测圆角(px) | 换算 dp | 截图 |
|---|---|---|---|---|
| 默认（未开覆盖） | — | 47.0 | 15.7 ≈ 16 | `01_default_container_top.png` |
| 覆盖 0 | 0dp | **0**（直角） | 0 | `03_radius_override_0.png` |
| 覆盖 12 | 12dp | 34.1 / 35.8 | 11.4 / 11.9 ≈ 12 | `04_radius_override_12.png`、`08` |
| 覆盖 24 | 24dp | 70.7 | 23.6 ≈ 24 | `05_radius_override_24.png` |
| 覆盖 40 | 40dp | 119.0 | 39.7 ≈ 40 | `06_radius_override_40.png` |
| 关闭覆盖 | — | 47.3 | 15.8 ≈ 16 | `10_override_off_default16.png` |
| 禁用分组圆角 ON（覆盖 12） | 开关开 | **0** | 0（覆盖被压制） | `07_disable_group_corner_on_override12.png` |
| 再关禁用 | 开关关 | 35.8 | 11.9 ≈ 12（覆盖恢复） | `08_disable_group_corner_off_override12.png` |
| 重启后（覆盖 12） | 12dp | 34.7 | 11.6 ≈ 12 | `09_restart_persist_corner12.png` |

- **优先级证据**：`07` 中「关闭设置分组圆角」= 开、「覆盖卡片圆角」= 12dp，实测分组卡为直角（0），
  页面截图中「容器设置」「模糊效果」两个分组均为方角；`08` 关闭该开关后立刻回到 12dp 圆角。
- **重启保持**：重启后 `dumpsys`/UI 读数 `卡片圆角 12dp`、开关开、禁用关；像素圆角 34.7px。
- **结论**：PASS。截图：`03`~`10`。

### 3.3 场景 3：边框（宽度 / 日夜色 / HEX / 0 色回落 / 尺寸不变 / 关闭）

- **步骤**：开「覆盖卡片边框」（宽度默认 1dp、颜色默认 0）→ 置 3dp；分别在浅色观察默认色；
  用「日间边框颜色」对话框输入 `#FF3366`；「夜间边框颜色」输入 `#3366FF` 后切深色主题；
  关闭开关复核无边框；记录卡片外框与文字绝对坐标。
- **预期**：宽度 1/3dp 生效；日间预设与 HEX 生效；夜间色仅在深色生效；0 色回落主题描边；
  边框不改变卡片尺寸与文字位置；关闭无边框。
- **实际**：全部符合。

| 检查点 | 实测 | 截图 |
|---|---|---|
| 宽 1dp | 左/右/上边框各 **3px**，颜色 `(216,196,190)` | `11_border_w1_default_color.png` |
| 宽 3dp | 左/右/上边框各 **9px**（8 solid + 1 AA） | `12_border_w3_default_color.png` |
| 0 色回落 | `(216,196,190)` = 主题 `outlineVariant`（非黑色/透明） | `11`、`12` |
| 日间 HEX `#FF3366` | 边框像素 **精确 `(255,51,102)`**，色值条显示 `#FFFF3366`（ARGB） | `13`、`13b`、`14`、`15` |
| 夜间 HEX `#3366FF`（深色） | 边框像素 **精确 `(51,102,255)`**；全图该色像素 54,312 | `17`、`18`、`19`、`20` |
| 卡片尺寸 | 开/关边框、1dp/3dp 时外框均为 `x=48..1031`（984px，328dp） | `11`、`12`、`20`、`21` |
| 文字位置 | 同一分组标题首行文字绝对 y：w1/w3/改色后 **均为 365** | `11`、`12`、`15` |
| 关闭边框 | 全图无 `(255,51,102)`/`(51,102,255)` 边框像素（红=0、蓝=0），行间距回到 2dp | `21_border_off_dark_measure.png`、`35` |
| 无效 HEX | 输入 `12` → 内联提示「请输入 6/8 位十六进制颜色」，确定按钮禁用 | `31_divider_hex_invalid.png`（同组件） |

- **HEX 显示口径（登记）**：输入 `#FF3366` 后行副标题显示 `#FFFF3366`（8 位 ARGB，`argbToHex`
  不补前导 0）；`#3366FF` → `#FF3366FF`。功能正确，但与「6 位 HEX」习惯不同（见 P3-3）。
- **结论**：PASS。截图：`11`~`15`、`17`~`21`。

### 3.4 场景 4：分隔线（宽度 / 长度 / 颜色 / 卡片与 flat 分组 / 末行 / 关闭 / 宽 0）

- **步骤**：开「显示分隔线」（默认宽 1dp、长 80%、色 0）→ 长度 50 / 80 / 100 → 宽度 3 / 0 →
  颜色「预设（青）」「HEX #FF3366」「恢复默认(0)」；另在「高级 → 其他设置」（`IosGroup(flat:true)`）
  验证同一组参数；关闭开关复核卡片分组与 flat 分组。
- **预期**：宽度、长度百分比、颜色三参数生效；卡片与 flat 分组均生效；末行无线；
  关闭后卡片分组 2dp、flat 分组保留细线；宽度 0 不画线。
- **实际**：全部符合。

| 检查点 | 实测 | 换算/说明 | 截图 |
|---|---|---|---|
| 宽 1dp | 线高 **3px**（2 solid + AA），色 `(207,207,207)` | 1dp；0 色 = 灰 30%（`0.3*136+0.7*238≈207`） | `23`、`33` |
| 宽 3dp | 线高 **9px**（1px AA + 8px 实色 `(207,207,207)` + 1px AA） | 3dp | `26` |
| 宽 0 | 全屏无分隔线像素（>100px 灰度行 = 0） | 不画线 | `27` |
| 长度 80% | `x=147..932` = **786px** | 786/984 = **79.9%** | `23` |
| 长度 50% | `x=294..785` = **492px**（居中） | **50.0%** | `24` |
| 长度 100% | `x=49..1031` = **983px** | **99.9%** | `25b` |
| 颜色预设（青） | `(0,150,136)` = `#009688` | 精确 | `30` |
| 颜色 HEX `#FF3366` | `(255,51,102)` | 精确 | `32` |
| 颜色 0（恢复默认） | `(207,207,207)` 灰 30% | 精确 | `33` |
| 卡片分组末行 | 「容器设置」最后一行（分隔线颜色）之后无任何线，卡底 4dp 后结束 | 末行无线 | `28`、`33` |
| flat 分组（其他设置）开 · 100% | 5 条线，`x=48..1031` = **984px**，色 `(207,207,207)` | flat 生效、用外宽 | `34` |
| flat 分组 开 · 50% | 1 条线 `x=295..784` = **490px**（居中） | 50% 生效 | `37` |
| 关闭 · 卡片分组 | 灰度分隔线 0 条；行间隙回到 6px=2dp | 2dp | `35` |
| 关闭 · flat 分组 | 保留既有细线：`x=96..1031`、色 `(216,196,190)`（dividerColor）、约 1.5px | 0.5dp 左缩进细线 | `36` |
| 宽 0 时行距（登记） | 2dp+0+2dp → 实测 11~13px（≈4dp） | 见 P3-2 | `27` |

- **结论**：PASS。截图：`23`~`37`。

### 3.5 场景 5：覆盖范围（默认 Card vs 显式 shape）

- **步骤**：保持「关闭设置分组圆角=开、覆盖圆角=0、覆盖边框=3dp/#FF3366、显示分隔线=开」，
  依次观察 ①书籍信息编辑页（`Card` 无 shape）、②首页 Tab（显式 shape）、
  ③独立「阅读设置」页、④阅读器内「阅读界面」面板。
- **预期**：默认样式卡片被覆盖；显式 shape 卡片不覆盖；副标题说明清晰。
- **实际**：①②④符合；③**被覆盖**，与副标题文案「阅读设置…不覆盖」不一致（P3-1）。

| 页面 | 组件来源 | 实测 | 判定 |
|---|---|---|---|
| 书籍信息编辑 | `edit_book_info_screen` 的 `Card()`（无 shape） | 直角（角点像素即边框色）+ 3dp 红框 `(255,51,102)`；红像素 54,810 | **被覆盖 ✓** |
| 首页 Tab | `home_tab_screen.dart:426` 显式 shape | 无边框（红=0）；自带圆角 **71.7px ≈ 24dp** | **不覆盖 ✓** |
| 独立「阅读设置」 | `read_config_screen.dart` 用 `IosGroup` | 3dp 红框 + 直角（角点=边框色） | **被覆盖**（与文案不符） |
| 阅读器内「阅读界面」面板 | `reader_config_panel.dart:167-175` 显式 `Card(shape: 16dp)` | 面板分组无红框、保持自身圆角 | **不覆盖 ✓** |

- **副标题现状**（`02`、`76`）：「覆盖使用默认卡片样式的卡片；自定义形状卡片（字典/首页/阅读设置等）不覆盖」
  与「0 色跟随主题描边」两段说明本身可读、可理解；但把「阅读设置」整体归入「不覆盖」不准确。
- **结论**：PASS（覆盖范围行为符合设计），文案偏差见 P3-1。截图：`45`、`46`、`47`、`48`。

### 3.6 场景 6：重启保持 / 本地备份→改值→恢复 / 忽略主题配置

- **步骤**：①`am force-stop` 冷启动后读 UI 与 prefs；②备份到
  `/storage/emulated/0/Download/qa2b1b1_backup`（SAF 新建目录并允许访问）→ 点「备份」；
  将 卡片圆角 0→40、边框宽度 3→1；长按「恢复」选该 JSON → 确认 → 不重启读 UI；
  ③再改 卡片圆角→40，勾选「恢复忽略列表 → 主题配置」后再次恢复，读 UI。
- **预期**：重启保持；备份含本批 11 键；恢复后同会话回到备份值；「忽略主题配置」不保护本批新键。
- **实际**：符合。

| 阶段 | 卡片圆角 | 边框宽度 | 分隔线长度 |
|---|---|---|---|
| 备份时（JSON 内） | 0 | 3 | 50% |
| 修改后 | **40** | **1** | 50% |
| 恢复后（同会话） | **0** | **3** | 50% |
| 修改后（第二次） | **40** | 3 | 50% |
| 勾选「主题配置」后恢复 | **0**（仍被覆盖） | 3 | 50% |

- **备份文件**：`/sdcard/Download/qa2b1b1_backup/legado_backup_1793547113915.json` **2,299 B**；
  `appPrefs` 含 17 键，本批 11 键齐全：`overrideBaseCardCornerRadius=true`、
  `baseCardCornerRadius=0`、`overrideBaseCardBorder=true`、`baseCardBorderWidth=3`、
  `baseCardBorderColor=4294914918(0xFFFF3366)`、`baseCardBorderColorNight=4281558783(0xFF3366FF)`、
  `disableSplicedColumnGroupCornerRadius=true`、`enableItemDivider=true`、
  `itemDividerWidth=1`、`itemDividerLength=50`、`itemDividerColor=0`
  （`data/backup_before.json`）。
- **重启保持（prefs 实测）**：`data/prefs_after_restart.xml` 中 11 键全部在盘，值与 UI 一致
  （`baseCardCornerRadius=0`、`baseCardBorderWidth=3`、`itemDividerLength=50`、
  `disableSplicedColumnGroupCornerRadius=true` 等）。
- **忽略主题配置（代码 + 设备双证）**：`restore_ignore_prefs.dart:186-196` 明确注释本批
  键**刻意不加入** `themePrefKeys`（与参考版 `BackupConfig.themePrefKeys` 一致），
  因此任何忽略组合下都随 `appPrefs` 完整往返；设备侧勾选「主题配置」后恢复仍把
  卡片圆角 40→0，证明未被忽略。
- **结论**：PASS。截图：`50`~`56`；数据：`data/backup_before.json`、`data/prefs_after_restart.xml`。

### 3.7 场景 7：回归与稳定性

| 子项 | 实测 | 证据 |
|---|---|---|
| 阅读 | 导入 `qa2b1b1.txt`（354 B）→ 打开正文、章节名/进度正常；阅读器内「阅读界面」面板可开 | `43_reader_open.png`、`48_reader_settings_sheet.png` |
| 主题切换 | 浅色↔深色多次切换，分组卡/边框/分隔线即时重绘；夜间边框色仅深色生效 | `18`、`19`、`22` |
| 容器背景图 | 选图（`e7b23e26…png`，红白棋盘）后 100% 时图片**完全被卡面覆盖**（棋盘红 `(204,39,41)` 像素 **0**，卡面采样 `(240,240,240)`，2b-1a 的缝隙漏图未复现）；置不透明度 50 后图片透出（半强度混合色 `(221,138,139)` 像素 **42,730**），且**红框 3dp、50% 居中分隔线、方角裁剪同时正确**，文字可读 | `71`、`72` |
| 护眼模式 | 开：页面 `(245,209,175)`（暖色）；关：`(245,245,245)`；开关立即生效，边框/分隔线不变形 | `63`、`64` |
| 颜色对话框横屏 | 1920×1080 下对话框可滚动，标题滚出后调色板/按钮正常，无溢出；竖屏同理 | `59`、`60` |
| 设置页进出/长滚动 | 外观页长列表多次滚动无卡死；`uiautomator` 偶发取不到 dump（工具侧）但界面正常 | 全程 |
| 无效 HEX | 内联错误 +「确定」禁用（见 §3.3） | `31` |

**FATAL / ANR / 崩溃统计**

| 项 | 计数 | 口径 |
|---|---|---|
| 应用 `FATAL EXCEPTION` | **0** | `logcat -b all -d`（会话窗口 23:36~23:44，6,700 行） |
| `Process: io.legado.flutter_legado` / `E/flutter` | **0 / 0** | 同上 |
| `ANR in io.legado` | **0** | 同上 |
| `RenderFlex overflowed` | **0** | 同上 |
| `OutOfMemoryError` | **0** | 同上 |
| 应用 native tombstone | **0** | `logcat -b crash -d`（749 行，全部 `Cmdline: uiautomator` 工具退出，共 34 条） |
| dropbox `data_app_crash`（本版本） | **0** | `dumpsys dropbox`：仅 2 条 **11:54:26 / 11:56:19** 的 `Package: io.legado.flutter_legado v435 (2.0.434)`，属**上一批 2b-1a 基线**的伪图片崩溃，早于本会话（22:54 起、版本 2.0.435/436） |

- **说明**：为测试横屏，23:36 执行过 `logcat -b all -c`，因此 22:54~23:36 的普通日志不在
  会话文件内；该段以 `logcat -b crash`（未清）与 `dumpsys dropbox`（跨 logcat 清理仍保留）
  为界，均无本版本崩溃记录。
- **结论**：PASS（FATAL/ANR/OOM/overflow = 0）。

### 3.8 场景 8：清理

| 项 | 结果 |
|---|---|
| 应用数据 | `pm clear io.legado.flutter_legado` **Success**，冷启动 **328 ms** |
| 书架 | **空**（`74_final_clean_shelf.png`：「书架还空着…」） |
| 三项开关 | 全部默认关（`76_clean_container_defaults.png`：关闭设置分组圆角/覆盖卡片圆角/覆盖卡片边框/显示分隔线 均关，无「卡片圆角」行） |
| prefs | 清理后仅 3 键，**无任何本批键**（`data/prefs_final_clean.xml`） |
| 容器背景图 | 随 `pm clear` 复位（开关关、无图） |
| 设备文件 | `/sdcard/Download/qa2b1b1.txt`、`qa_day_red.png` 已删；`qa2b1b1_backup/`（含子目录 `crash`）先改名再逐层 `rmdir` 清除（SAF/文档服务占用时 `rm -rf` 报 Text file busy） |
| 系统设置 | `accelerometer_rotation=1`、`user_rotation=0`（横屏测试后已还原，`dumpsys` 复核 ROTATION_0） |
| 版本 | 保留 **2.0.435 / 436**（`dumpsys package` 复核） |

## 四、问题清单与分级

### P3-1 「覆盖卡片边框/圆角」副标题把「阅读设置」整体列为不覆盖，与实际不符

- **复现**：外观 → 容器设置 → 开「覆盖卡片圆角」（0dp）与「覆盖卡片边框」（3dp 红）→
  我的 → 设置 → 阅读界面。
- **期望（按文案）**：独立「阅读设置」页卡片不被覆盖。
- **实际**：该页分组卡变成**直角 + 3dp `#FF3366` 边框**（`47_read_config_explicit_shape.png`，
  红像素 36,018、角点即边框色）。只有**阅读器内**「阅读界面」面板
  （`reader_config_panel.dart:167-175` 显式 `Card(shape: 16dp)`）不覆盖。
- **定位**：`read_config_screen.dart:103-111` 使用 `IosGroup`（受覆盖），文案却按
  「阅读设置=显式 shape」表述。
- **影响**：用户按文案预期「阅读设置不变」时会看到变化；不影响功能。
- **建议**：副标题改为「自定义形状卡片（字典/首页等）不覆盖」或加注「阅读器内设置面板不覆盖」。
- **分级**：P3（文案不精确）。

### P3-2 分隔线开关开且宽度=0 时，行距由 2dp 变 4dp

- 宽 0 时 `PillDivider` 不画线（正确），但外层仍插入两个 2dp `SizedBox`，
  实测行隙 11~13px（≈4dp）而非 2dp（`27_divider_w0.png`）。
- 与参考版 `Column(spacedBy(2)) + 零高度分隔线子项` 同构，属实现一致性；
  需求只要求「宽度 0 不画线」，该项满足。建议在文案标注或按 0 宽时收敛为单侧间距。
- **分级**：P3（登记行为）。

### P3-3 颜色行副标题以 8 位 ARGB 显示用户输入的 6 位 HEX

- 输入 `#FF3366` → 显示 `#FFFF3366`；`#3366FF` → `#FF3366FF`；`0` → 「默认（…）」。
  与参考版 `Integer.toHexString` 形态一致，且代码注释已登记「不补前导 0」，
  但普通用户可能误读为不同颜色。建议 6 位输入回显 6 位。
- **分级**：P3（可读性）。

### P3-4 「设置」首页卡片不是 Card，行距 10dp 且不受本批覆盖

- `settings_home_screen.dart:62-67` 手写 `Material(radius 16)` + `SliverList.separated(10)`：
  16dp 圆角、无边框、无分割线符合预期，但**行距 10dp**（任务描述为 2dp），
  且三项覆盖对其无效（它既非 `Card` 也非 `IosGroup`）。
- 若产品期望设置首页也参与覆盖/2dp 密度，需在 2b-1b-2 迁移。
- **分级**：P3/范围登记。

### 环境类记录（非缺陷）

1. **`flutter build` 与 `flutter test` 不可并发**：并发运行会让 `GeneratedPluginRegistrant.java`
   带上 dev 依赖 `integration_test`，release 编译报 `程序包 dev.flutter.plugins.integration_test 不存在`。
   单独重跑即通过。
2. **MediaStore 残留**：上一批删除的 `qa_day_red_3000x2000.png` 仍在媒体库，系统照片选择器
   显示缩略图但选中后 `FilePickerUtils: open failed: ENOENT`（应用捕获 `PlatformException`，
   不崩溃、不写入）。重新推送新图并 `MEDIA_SCANNER_SCAN_FILE` 后选择正常。
3. **Android 11+ SAF 限制**：`Download` 根目录「无法使用此文件夹」，需新建子目录
   （本批使用 `qa2b1b1_backup`）。

## 五、证据清单

| 类别 | 文件 |
|---|---|
| 构建（失败/重试） | `tmp_debug/device_acceptance_20261101_batch2b1b1/logcat/build_2b1b1.log`、`build_2b1b1_retry.log` |
| 门禁 | `logcat/analyze.log`、`logcat/card_style_tests.log`（56/56） |
| 会话日志 | `logcat/session_2b1b1.log`（6,700 行）、`logcat/crash_2b1b1.log`（749 行） |
| prefs 快照 | `data/prefs_s1_default.xml`、`prefs_s2_corner12.xml`、`prefs_after_restart.xml`、`prefs_final_clean.xml` |
| 备份样本 | `data/backup_before.json`（2,299 B，17 键含本批 11 键） |
| 分析脚本 | `scripts/img.py`、`radius2.py`、`measure_group.py`、`text_offset.py`、`scroll_to.py`、`shot.sh`、`ui.sh` |
| 截图 | `docs/materials_1101f/`（81 张；场景对应见 §二/§三） |

## 六、未证明 / 不可证明项

- **小屏**颜色对话框：MuMu 固定 1080×1920，未做 `wm size` 覆盖；以横屏
  360dp 高度（等效小屏高度）验证滚动不溢出，未覆盖真正的小屏设备。
- **字典页**显式 shape 未逐一实机对照（入口需阅读器内查词）；本轮以「首页」「阅读器内阅读界面」
  两个显式 shape 样本 + 计划文档登记（2b-1b-2 的 18 处清单）作为依据。
- **默认样式 Card 的样本**仅取了「书籍信息编辑」一页（`bookmark_screen` 等需用户数据）；
  未覆盖全部无 shape 的 `Card` 页面。
- 本批未重跑全量 `flutter test`（仅定向 56 项）；未做 SurfaceFlinger 帧时间测量
  （本批为静态样式开关，无动画/逐帧变化）。
- 本批未重新安装参考版 kazusa 做逐项对照，参考语义取自代码注释与既有文档。

## 七、结论

| 场景 | 判定 |
|---|---|
| 1 默认（16dp / 2dp / 无边框 / 无分割线） | **PASS**（首页 10dp 间距见 P3-4） |
| 2 圆角覆盖 0/12/24/40、恢复 16、禁用优先、重启保持 | **PASS** |
| 3 边框宽度/日夜色/HEX/0 色回落/尺寸不变/关闭 | **PASS** |
| 4 分隔线宽度/长度/颜色/卡片+flat/末行/关闭/宽 0 | **PASS**（宽 0 间距见 P3-2） |
| 5 覆盖范围（默认 Card vs 显式 shape） | **PASS**（文案见 P3-1） |
| 6 重启保持 / 备份恢复 / 忽略主题配置 | **PASS** |
| 7 回归（阅读/主题/容器背景/护眼/横屏）+ 崩溃统计 | **PASS**（FATAL/ANR/OOM/overflow 均 0） |
| 8 清理与版本保留 | **PASS** |

**问题分级：P1=0；P2=0；P3=4**（副标题「阅读设置」表述、宽 0 行距 4dp、HEX 8 位回显、
设置首页非 Card 且 10dp 间距）。

**总判定：通过。** 三项覆盖（圆角/边框/分隔线）在设备上的数值、几何与优先级均与
参考语义一致；未发现功能性缺陷或崩溃。4 项 P3 为文案/登记项，可并入 2b-1b-2 或文案修订，
不阻塞本批关闭。

编写者：QA（ZCode 子代理）｜ 2026-11-01
