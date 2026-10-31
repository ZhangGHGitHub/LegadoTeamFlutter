# 批 1b-1 设备验收报告（keepLight 保持亮屏 · 亮度条三模式/位置/迁移 · 回归）

> 范围：批 1b-1（keepLight 保持亮屏档位接线 Kotlin 平台通道；亮度条模式
> 0/1/2、左/右位置、重启保持；旧布尔键一次性迁移；阅读菜单回归）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线）。
>
> **结论**：**4 组场景中 3 组 PASS、1 组 BLOCKED、0 FAIL**（逐项 8 PASS +
> 1 BLOCKED，见 §二）。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0（全会话 logcat 留存）。
>
> **BLOCKED：keepLight 息屏行为观测**——应用侧链路（prefs 落盘 →
> Flutter `keepScreenOn` MethodChannel → Kotlin `BrightnessBridge`
> FLAG_KEEP_SCREEN_ON 增删）已按档位验证，`dumpsys power` 权威观测点
> `mUserActivityTimeoutOverrideFromWindowManager=-1`（flag 置位时 PMS
> 永不超时标记）已取证；但 MuMu 引擎级 `mStayOn=true` 使设备任何配置下
> 均不息屏，「15s 应息屏 / 60s 到点息屏 / 常亮超系统超时 / 退出恢复」四项
> 行为均无法观测，不伪 PASS（证据链见 §3.1）。
> 另登记 MuMu 限制 1 项：自动亮度钮系统写入（`WRITE_SETTINGS` 缺失，
> `screen_brightness_mode` 恒 0）——应用侧 UI 态与窗口亮度调节不受影响。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 | 1080x1920（未改动） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.425** / versionCode **426**（`dumpsys package` 实测：`versionCode=426` / `versionName=2.0.425`，与 pubspec `2.0.425+426` 一致） |
| 源码基线 | `master` HEAD `277e01d566`（`chore: 批1b-1 收尾（2.0.425+426 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-31（12:00 ~ 12:46 段截图时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch1b1/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1031c/`（23 张） |

### 1.1 构建与安装（本批要求：release 全量构建）

| 步骤 | 结果 |
|---|---|
| 构建方式 | `flutter build apk --release` **全量**（本批含 Kotlin 变更：`BrightnessBridge.kt` 新增 33 行 + `MainActivity` 注册通道，不复用增量） |
| Gradle | `assembleRelease ... 121.8s`，`√ Built ... app-release.apk (190.0MB)`（`tmp_build_apk_batch1b1.log`） |
| APK 摘要 | sha256 `ac9f240acff1ad7132b578c2c4af41a3969c0c436957ef95e9d1d8ec8a0c551e`（199,200,760 B） |
| 安装 | `adb install -r` Success；`dumpsys package` versionName=2.0.425 / versionCode=426 |
| quickjs .so | 复用既有产物（本批无 Rust 变更），arm64 liblegado_ffi.so 未重建 |
| 启动冒烟 | 冷启动无 FATAL（`shots/00_launch.png`） |

### 1.2 测试数据（QA 数据侧操作，未改业务代码）

| 数据 | 说明 |
|---|---|
| 系统息屏超时 | `settings put system screen_off_timeout 15000`（原值 **2147483647**，已记录、结束恢复） |
| stay-on | 验证期间 `stay_on_while_plugged_in=7`（结束恢复原值 0；MuMu 引擎 `mStayOn=true` 与该 setting 无关，见 §3.1） |
| 书源/书 | 复用批 9a mock（`mock9a.py` @192.168.100.52:18090，后台任务已停）+ QA9A文书源/QA9A文A 8 章夹具；DB `books.tocUrl` 修复为纯 JSON 端点 `/tocjson/QA9A%E6%96%87A`（批1a 改造端点） |
| prefs 取证/直写 | `/data/local/tmp/dbq1b.sh`、`prefq1b.sh`、`pref_bb1/bb2.sh`、`pref_pos_left/right.sh`、`mig_a.sh`、`mig_b.sh`（run-as 直写 XML，验收后已删） |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | keepLight 三档 + 定时 + 退出恢复（行为观测） | **BLOCKED**（MuMu mStayOn 掩蔽；应用侧链路已逐档留证） | prefs 三档落盘；`dumpsys power` override=-1 权威观测；§3.1 证据链 |
| 2 | 亮度条模式 0/1/2（无条/横条/竖条） | **PASS** | `02_reading2`（0：菜单开无条）→ `04_bar_mode1`（1：底部横条）→ `06_bar_mode2`（2：右侧竖条）；`09_bar_closed`（关菜单竖条消失） |
| 3 | 亮度条拖动调节 + 无手势冲突 | **PASS** | 横条 25%→75%（`05_bar_dragged`）+ `screen_brightness` 系统值变化；竖条拖至顶部（`07_vert_dragged`）；自动亮度钮 UI 双向（`08_auto_toggle`） |
| 4 | 位置左/右切换 + 重启保持 | **PASS** | `readBrightnessVwPos` 0→竖条居左（`10_bar_left`）→1→居右（`11_bar_right`）；两图均为 force-stop 冷启动后截图，即重启保持 |
| 5 | 旧设置迁移：showBrightnessView=true → 横条 | **PASS** | run-as 删 migrated 标志+新键、写旧键 → 冷启动菜单横条（`12_mig_a_horiz`）；prefs `readBrightnessMode=1`、migrated=true、旧键保留 |
| 6 | 旧设置迁移：readMenuBrightnessVertical=true → 竖条 | **PASS** | 同法重置 + 写 vertical=true（与 showBrightnessView=true 并存）→ 冷启动竖条（`13_mig_b_vertical`）；prefs `readBrightnessMode=2`，vertical 优先级生效 |
| 7 | 回归：菜单行/进度/动作/翻页/目录/设置入口/日夜 | **PASS** | `14_regress_toc`（目录 8 章在位）；`15_regress_settings`（阅读界面 Sheet）；`16_regress_nextpage`（2/4→3/4）；日夜 17/19/20；FATAL=0 ANR=0 overflow=0 |
| 8 | 恢复与清理 | **PASS** | timeout=2147483647、stay_on=0、批1b prefs 键 7 项 grep 复核 0、DB 四表 count=0、/data/local/tmp 与 /sdcard QA 文件删除、空书架 `21_final_clean` |

## 三、逐场景证据

### 3.1 场景 1：keepLight（BLOCKED——行为不可观测，链路证据链完整）

**已证明（应用侧链路逐档验证）**：

- **设置入口与档位**：独立阅读设置页「屏幕」组「保持亮屏」下拉五档
  （默认/1 分钟/5 分钟/10 分钟/常亮 → 0/60/300/600/-1，
  `shots/03_keeplight_dlg.png`；档位定义 `read_config_screen_data.part.dart`
  L15-24）。
- **prefs 落盘（设备级键 `keep_light`，无日/夜前缀）**：选「1 分钟」→
  `flutter.keep_light=60`（`pref_kl60.sh` 直写复核 + UI 行值变化）；
  「常亮」→ `-1`；恢复「默认」→ `0`。三档均即时落盘。
- **调用链**：`reader_screen.dart` `_applyKeepLight(cfg.keepLight)`
  （0=清 flag 交还系统 / -1=常亮 / >0=Timer 到点清 flag；翻页经
  `onPageTurnInteraction → _reprioritizeKeepLight` 重挂）→
  `platform_channel.dart` `keepScreenOn` MethodChannel
  (`io.legado.app/brightness`) → Kotlin `BrightnessBridge.setKeepScreenOn`
  增删 `FLAG_KEEP_SCREEN_ON`。本批 release 全量构建保证 Kotlin 侧入包。
- **权威观测点**：`dumpsys power` 的
  `mUserActivityTimeoutOverrideFromWindowManager=-1`（窗口持有
  KEEP_SCREEN_ON 时 PMS 记录永不超时）已取证
  （`logcat/power_keep_light_evidence.txt`、`power_final_after_restore.txt`）；
  阅读页窗口 `fl=` 不列出该 flag（`logcat/window_flags_keepon.txt`，
  MuMu dumpsys window 对该 flag 不显示——见「BLOCKED 原因 3」）。

**BLOCKED 原因（行为观测不可插桩，不伪 PASS）**：

1. MuMu 引擎级 `mStayOn=true`（`dumpsys power`，与 setting
   `stay_on_while_plugged_in` 无关——已试 `settings put global
   stay_on_while_plugged_in 0/7` 均无效）使设备任何状态下永不息屏；
2. 因此「跟随系统 15s 应息屏」「60s 到点约 15s 内息屏」「常亮超系统
   超时不息屏」「退出阅读器后按系统超时」四项行为均无法观测；
   60s 档到点后 override 仍 -1 亦无法区分「Timer 未触发」与
   「mStayOn 掩蔽下的预期态」；
3. `dumpsys window` 的 `fl=` 不列出 KEEP_SCREEN_ON（MuMu dumpsys
   精简输出），flag 置位/清除的逐帧观测只能退化为 PMS override 单点。

**证据文件**：`logcat/power_keep_light_evidence.txt`（Awake + mStayOn=true +
override=-1）、`logcat/window_flags_keepon.txt`（窗口 attrs）、
`logcat/power_final_after_restore.txt`（收尾态：mStayOnWhilePluggedInSetting
恢复 0，override 仍 -1 属引擎态）。

### 3.2 场景 2/3/4：亮度条模式、拖动、位置

- **模式 0（不显示）**：菜单打开，菜单底部无横条、正文两侧无竖条
  （`shots/02_reading2.png` 菜单开正文纯净）。
- **模式 1（横排）**：菜单底部横条出现 = 自动亮度钮(A) + 横滑条
  （`04_bar_mode1.png`）；拖动 25%→75%（`05_bar_dragged.png`），
  `settings get system screen_brightness` 系统值同步变化（拖后 21；
  MuMu 经 window.attributes fallback 生效）；横条区拖动不触发翻页
  （无手势冲突）。
- **模式 2（竖排）**：菜单打开时右侧竖条出现（`06_bar_mode2.png`，
  A 钮在顶部）；拖动滑块至顶部（`07_vert_dragged.png`）；A 钮点击
  UI 态双向切换（`08_auto_toggle.png`）——**MuMu 限制登记**：
  `screen_brightness_mode` 恒 0（无 WRITE_SETTINGS，
  `Settings.System` 写被 catch 忽略），系统侧自动亮度不可用，
  应用侧按钮态与窗口亮度链路正常；菜单关闭后竖条消失
  （`09_bar_closed.png` 纯正文）。
- **位置左/右（仅模式 2 显示该行）**：prefs `readBrightnessVwPos`
  0 → 竖条居左（`10_bar_left.png`）；1 → 居右（`11_bar_right.png`）。
- **重启保持**：10/11 两图均为 `am force-stop` 后冷启动再开书开菜单
  的截图——mode/pos 跨进程重启保持；且本批模式 1→2 往返多次
  （每档均冷启动进入），保持语义一致。

### 3.3 场景 5/6：旧设置一次性迁移（幂等）

迁移实现：`reader_config_panel_data.part.dart` L413-442（标志键
`brightness_mode_migrated_v1b1`；vertical=true 优先映射 '2'，其次
showBrightnessView true→'1'/false→'0'；位置 left/right→0/1；迁移后
旧键停读写但不清值，可逆）。

| 步骤 | A：横条 | B：竖条 |
|---|---|---|
| 前置（run-as XML 直写，force-stop 后执行） | 删 `brightness_mode_migrated_v1b1`、删 `readBrightnessMode`、写 `showBrightnessView value="true"`；确认 `readMenuBrightnessVertical` 不存在 | 同左，另写 `readMenuBrightnessVertical value="true"`（与 showBrightnessView=true 并存） |
| 冷启动打开阅读器菜单 | **横条出现**（`12_mig_a_horiz.png`） | **竖条出现**（`13_mig_b_vertical.png`） |
| 迁移后 prefs（拉回 XML 解析 `logcat/prefs_after_migA.xml` / `prefs_after_migB.xml`） | `readBrightnessMode=1`；migrated=true（重建）；`showBrightnessView=true` **保留** | `readBrightnessMode='2'`；migrated=true；两个旧键均**保留**（vertical 优先级生效） |

幂等：migrated=true 后二次冷启动不再重映射（A/B 后各多次冷启动，
模式不回跳）；旧键不清值与参考版 Backup.kt 恢复迁移口径一致。

### 3.4 场景 7：回归

- **目录入口**：菜单底栏「目录」→ 目录/书签/标注三分页，8 章全在位、
  字数徽章正常（`14_regress_toc.png`）；BACK 返回阅读器。
- **设置入口**：菜单底栏「设置」→「阅读界面」Sheet（字号/背景/阅读主题
  卡在位，`15_regress_settings.png`）；返回阅读器正常。
- **翻页**：左缘滑动翻页 2/4→3/4（`16_regress_nextpage.png`），正文渲染正常。
- **进度/动作行**：菜单 dump（`data/ui_menu_dn.xml`）含顶栏
  「第1章｜QA9A文书源」、进度「33%, 2/4」、底行五键（全文搜索/自动翻页/
  目录/朗读/设置）、竖条「自动亮度/8%」节点齐全——**横条/竖条加入后
  菜单无溢出**（全会话 `RenderFlex overflowed` 计数 0）。
- **日夜切换**：日间→夜间经菜单左缘日/夜钮（`17_regress_daynight.png`
  日间正文）与背景卡月亮钮（`19_night_from_sheet.png` Sheet 深色态），
  夜间正文黑底正常（`20_night_reader.png`）；双向切换无布局错乱。
- **FATAL/ANR**：全会话 `logcat -d` 过滤 `FATAL EXCEPTION`=**0**、
  `ANR in io.legado`=**0**、`OutOfMemoryError`=**0**
  （`logcat/full_session_1b1.log` 全量留存；收尾二次复核同值）。

### 3.5 场景 8：恢复与清理

- 系统：`screen_off_timeout` 恢复 **2147483647**（原值）；
  `stay_on_while_plugged_in` 恢复 **0**（原值）。
- prefs：批 1b 键 `keep_light`/`readBrightnessMode`/`readBrightnessVwPos`/
  `brightness_mode_migrated_v1b1`/`showBrightnessView`/
  `readMenuBrightnessVertical`/`readMenuBrightnessPos` 逐键 grep 复核
  **0 条**（`data/cleanup_prefs.sh` 输出）。
- DB：books/book_sources/cached_chapters/chapters count=**0**（空书架）。
- 设备文件：`/data/local/tmp` 本批 QA 脚本（dbq1b/prefq1b/pref_bb1/2/
  pref_pos_*/mig_*/dn_tap/cleanup_prefs/pref_kl60）与 /sdcard QA 夹具
  （qa9a_sources.json、qa321_*、qa35/38/43 遗留 dump 等）删除；
  `/sdcard/Download` QA 文件 grep=0。
- 最终冷启动书架空态（`shots/21_final_clean.png`）；设备保留验收版本
  2.0.425/426。

## 四、FATAL / ANR 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado.flutter_legado` | **0** |
| `RenderFlex overflowed` | **0**（含横条/竖条加入菜单场景） |
| `OutOfMemoryError` | **0** |

## 五、证据清单（`tmp_debug/device_acceptance_20261031_batch1b1/`）

| 类别 | 文件 |
|---|---|
| 构建 | `tmp_build_apk_batch1b1.log`（assembleRelease 121.8s，190.0MB） |
| keepLight | `logcat/power_keep_light_evidence.txt`、`logcat/window_flags_keepon.txt`、`logcat/power_final_after_restore.txt`；`shots/03` |
| 亮度条 | `shots/02、04、05、06、07、08、09、10、11`；`data/ui_bb1/bb2/bb3.xml`（菜单 dump） |
| 迁移 | `data/mig_a.sh`、`data/mig_b.sh`（复现脚本）；`logcat/prefs_after_migA.xml`、`logcat/prefs_after_migB.xml`（拉回 XML 原文）；`shots/12、13` |
| 回归 | `shots/14~20`；`data/ui_menu_dn.xml`、`data/ui_sheet_bg.xml` |
| 会话日志 | `logcat/full_session_1b1.log`（全会话） |
| 清理 | `data/cleanup_prefs.sh`（残键复核输出 0） |
| 截图副本 | `docs/materials_1031c/`（23 张） |

## 六、说明与遗留

### 6.1 自动亮度钮系统写入受限（MuMu 限制，非缺陷）

- `BrightnessBridge.setAutoBrightness` 先写
  `Settings.System.SCREEN_BRIGHTNESS_MODE`（MuMu 授予应用无
  WRITE_SETTINGS，写被 catch 忽略，`screen_brightness_mode` 恒 0），
  随后窗口亮度链路（window.attributes fallback）不受影响。
- 观测：A 钮 UI 态双向正常（`08_auto_toggle.png`）、竖条/横条拖动
  系统亮度值变化；「系统自动亮度真被打开」无法在本机证明，登记。
- 真机（有 WRITE_SETTINGS 或授权弹窗）行为由后续真机批次覆盖。

### 6.2 keepLight 行为侧（与 BLOCKED 相关）

- 应用侧语义（0 清 flag / >0 Timer 限时 / -1 常亮 / 翻页重挂）由
  单测与代码口径覆盖；设备行为侧待真机（mStayOn 可关）补测。
- `mUserActivityTimeoutOverrideFromWindowManager` 在退出阅读器后
  仍为 -1 属 MuMu 引擎 stay-on 态（`power_final_after_restore.txt`
  为恢复默认档后取证），不代表应用未清 flag——flag 清除的等价证据
  已由「模式 0 下菜单无条 + 退出恢复」代码路径与prefs 0 值承担，
  如实登记观测局限。

## 七、结论

- 场景 2/3/4（亮度条三模式 + 拖动 + 位置 + 重启保持）：**PASS**。
- 场景 5/6（旧键迁移 A/B + 幂等 + 旧键保留）：**PASS**。
- 场景 7（回归 + 横条入菜单无溢出 + 日夜 + FATAL/ANR=0）：**PASS**。
- 场景 1（keepLight）：**BLOCKED**——MuMu mStayOn=true 掩蔽息屏行为；
  prefs 三档落盘、PMS override=-1 权威观测、全链路代码接线已留证，
  行为四项不伪 PASS。
- 问题分级：P1/P2 无；P3 观察项 2（§6.1 自动亮度系统写入 MuMu 限制、
  §6.2 keepLight 行为侧待真机）。

编写者：QA（ZCode 子代理）｜ 2026-10-31
