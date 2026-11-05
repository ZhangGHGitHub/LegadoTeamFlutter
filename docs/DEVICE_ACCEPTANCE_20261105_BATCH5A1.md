# 批5a-1 设备验收报告：朗读设置页 + 系统 TTS + 常规核心

- 验收日期：2026-11-05
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`
- 代码基线：`70dc015b3b`（chore: 批5a-1 收尾（2.0.458+459 双日志与计划登记））
- 版本：`2.0.458+459`（pubspec）→ APK versionName 2.0.458 / versionCode 459
- 证据目录：`docs/materials_1105a/`
- 验收角色：设备验收代理（只测不改代码，未修改 `lib/` 任何文件）

## 一、环境

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例 index 1，`adb -s 192.168.100.62:5555`（`adb devices` 状态 device） |
| 系统 | Android 15（`ro.build.version.release=15`），机型伪装 SM-G9900 |
| 屏幕 | 物理 1080x1920，density 480，`SurfaceOrientation: 0`（竖屏） |
| 显示 | 应用位于主 display（`mCurrentFocus=io.legado.flutter_legado/...MainActivity`），单屏操作，无需 `-d` |
| TTS 引擎 | **无**：`settings get secure tts_default_synth` = `null`；`pm list packages | grep -iE 'tts|speech'` 无结果 |
| 构建 | `cd flutter_legado && flutter build apk --release`（无 Rust 改动，未重建 .so），构建耗时 155.7s，产物 192.5MB |
| 安装 | `adb install -r build/app/outputs/flutter-apk/app-release.apk` → Success |
| 测试书 | 本地 UTF-8 TXT（25.7KB，5 章 × 20 段），经系统文件选择器「添加本地」导入 |

### APK 指纹

```
sha256 704c327680f9a11548f8a1c66aa9a61d478fcc47e2a4adf819b623354e8483b5
path   flutter_legado/build/app/outputs/flutter-apk/app-release.apk
size   201,896,076 bytes (2026-11-05 18:04)
```

## 二、逐项结果

结论口径：PASS=实测符合；FAIL=实测不符且可复现；BLOCKED=设备能力缺失无法验证（附证据）。

### A. 入口与页面

| 项 | 结果 | 证据 |
|---|---|---|
| A1 设置主页有「朗读设置」入口；打开后三页签「常规 / 引擎与音色 / 角色与配乐」；标题与返回正常 | **PASS** | `A1_settings_home.png`（设置主页第 4 项「朗读设置 / 朗读引擎、音色与播放行为」）、`A1_read_aloud_general.png`（标题「朗读设置」+ 左上返回 + 三页签）、`A1_tab_engine.png`、`A1_tab_role.png` |
| A2 常规页项齐全 | **PASS** | `A2_general_s1.png`、`A2_general_s2.png`、`A1_read_aloud_general.png` |
| A2 置灰项不可点、无假开关 | **PASS** | `A2_disabled_noop.png`（连点「显示朗读胶囊」「自动收缩朗读胶囊」后开关仍为灰色关闭态） |
| A3「其他设置」页不再有「忽略音频焦点」行（无双入口） | **PASS** | `A3_advanced_top/s1/s2/bottom.png` 全页逐屏滚动检索，全程无「忽略音频焦点」；`grep -rn "忽略音频焦点" lib/` 仅命中 `read_aloud_settings_screen.dart` |

A2 实测清单（顺序与页面一致）：

- 界面：默认朗读界面（经典）、播放器背景（纯色）、显示朗读胶囊（置灰「暂未支持」）、自动收缩朗读胶囊（置灰）、重置朗读胶囊位置（置灰）
- 播放：忽略音频焦点、朗读唤醒锁、来电时暂停朗读（置灰「需电话权限，暂未支持」）、退出阅读时继续朗读、媒体键上一首/下一首翻章、安卓媒体控制兼容（置灰）、流式朗读（置灰）、后台保活 / 电池优化（右侧箭头）
- 缓存：TTS 缓存（0 个文件 · 0 B）

### B. 常规行为

| 项 | 结果 | 证据 |
|---|---|---|
| B1 默认朗读界面 classic/player 可切换并重启保持；player 下从阅读器启动朗读进入听书播放器 | **PASS** | `B1_dialog_interface.png`（经典/播放器两项）、`B1_B2_values_set.png`（行值变为「播放器」）、`E1_after_restart_general.png`（重启后仍为「播放器」）、`B1_player_interface.png`（阅读器点朗读后进入听书播放器，无引擎时显示「未配置可用朗读引擎，将按估算节奏朗读」，不崩溃） |
| B2 播放器背景 solid/transparent 切换；听书页背景随之变化；模糊/流光置灰不可选 | **PASS** | `B2_dialog_background.png`（纯色/透明可选，模糊/流光置灰；点击置灰项无任何状态变化）、`B1_player_interface.png`（透明 → 播放器页黑底）、`B2_player_solid.png`（纯色 → 跟随主题浅色底，差异明显） |
| B3 唤醒锁开关切换/重启保持（无马达/无 TTS 下只验状态与无崩溃） | **PASS** | `B3_B5_toggles_on.png`（三项开启）、`E1_after_restart_toggles.png`（force-stop 重启后仍为开）；本次未做 dumpsys wakelock 级验证（见 BLOCKED） |
| B4 退出阅读继续朗读：**关 → 停止** | **FAIL（P1）** | 见下文「三、缺陷」 |
| B4 退出阅读继续朗读：**开 → 保持** | **PASS** | `B4_on_keep_playing.png`（keep=true 退出阅读器后书架页，通知仍为「正在朗读: batch5a1_test」，`dumpsys media_session` state=PLAYING(3)） |
| B5 媒体键上一首/下一首翻章开关切换/重启保持（行为 BLOCKED 仅验 gate/无崩溃） | **PASS（gate）** | `B3_B5_toggles_on.png` → `E1_after_restart_toggles.png`（重启保持）；`B5_media_next_on.png` 与操作前画面一致（未切章，见 BLOCKED） |
| B6 系统 TTS 设置 / 电池优化按钮有系统页面或明确提示，不崩溃 | **PASS** | `B6_system_tts_settings.png`（跳转 `com.android.settings/.Settings$TextToSpeechSettingsActivity`「文字转语音输出」）；`B6_battery_tap2.png`（跳转 `com.android.settings/.spa.SpaActivity`「应用的电池使用情况」） |

### C. 引擎与音色

| 项 | 结果 | 证据 |
|---|---|---|
| C1 引擎列表含「系统 TTS」+ HTTP 引擎；MuMu 无引擎时系统 TTS 行可选，引擎/音色为空态提示，不崩溃 | **PASS** | `C2_engine_list_top.png`（系统 TTS / Next引擎 / 1.百度 / 2.阿里云语音）、`C1_engine_mid.png`（系统引擎「系统未安装 TTS 引擎」、音色「无可用音色」，两行置灰不可点） |
| C2 选择系统 TTS 与 HTTP 引擎切换，重启保持 | **PASS** | `C2_selected_baidu.png`（选中百度，Toast「已切换朗读引擎」）→ `E1_engine_after_restart.png`（force-stop 重启后仍选中百度） |
| C2 系统 TTS 设置失败时不出现「已切换」假提示 | **PASS（无失败路径可触发）** | 无引擎时「系统引擎 / 音色」两行置灰，无法选中不存在的引擎；切换「系统 TTS」这一**引擎类型**本身成功（`C2_select_systemtts_noengine.png`，Toast「已切换为系统 TTS」），引擎类型切换属实，非假提示 |
| C3 语速 0.5–3.0、音调 0.5–2.0、音量 0–1 滑块可调并持久化 | **PASS** | `C3_sliders_default.png` → `C3_sliders_set.png`（2.0x / 1.5 / 50%）→ `C3_sliders_final.png`（1.5x / 1.2 / 60%）；边界实测：语速左端 0.5x、右端 3.0x；音调左端 0.5、右端 2.0；音量左端 0%；重启后仍为 1.5x / 1.2 / 60%（见 E1） |
| C3 只拖音量不改语速 | **PASS** | `C3_volume_only.png`（音量 100%→50%，语速仍 1.0x、音调仍 1.0） |
| C4 TTS 缓存行显示大小/文件数，清理按钮可用（无文件时提示 0/空） | **PASS** | `C4_cache_dialog.png`（「系统 TTS 合成缓存：0 个文件，共 0 B」+ 取消/清理）、`C4_cache_cleared.png`（Toast「已清理 0 个缓存文件」） |

### D. 朗读主链路回归（无引擎）

| 项 | 结果 | 证据 |
|---|---|---|
| D1 无引擎时给一次提示并按估算推进，不卡死/不永久「合成中」；停止/切段/退出正常 | **PASS** | `D1_readaloud_start.png`（面板「正在朗读 第1章 1/5 ·段1/20」+「未配置可用朗读引擎，将按估算节奏朗读」）；15s 后段1→段2（估算推进）；`D1_next_segment.png`（点「下一段」段2→段4）；停止后通知计数归 0、`media_session` state=STOPPED |
| D2 快速切换朗读/停止/再开始 3 次，无崩溃/无卡死 | **PASS** | `D2_rapid_cycle.png`、`D2_after_3cycles.png`（3 轮 0.4–0.6s 间隔 start/stop 后界面可正常 dump、`topResumedActivity` 仍为本应用；logcat 无 FATAL/ANR/E flutter） |
| D3 朗读设置页返回后阅读器仍正常；FATAL/ANR/E.flutter/overflow = 0 | **PASS** | `D3_panel_with_settings.png` → `D3_back_to_reader.png`（从面板进入设置页再返回，朗读继续 段2/20，正文可读）；`logcat_full_20261105.txt` 中上述四类关键字计数 **0** |

补充观察（HTTP 引擎失败降级路径，正面结论）：将引擎切到「百度」后朗读，面板按段提示「朗读音频不可用，本段按估算时长继续：Bad state: TTS 合成未返回音频文件（引擎或缓存异常）」，仍按估算推进、可停止，无崩溃 —— 合成失败不会卡在「合成中」。

### E. 持久化与备份

| 项 | 结果 | 证据 |
|---|---|---|
| E1 三页签关键偏好杀进程重启保持 | **PASS** | 两次 `am force-stop` + 重启后：默认界面=播放器、背景=透明/纯色、唤醒锁=开、退出保持=开、媒体键翻章=开、语速 1.5x / 音调 1.2 / 音量 60%、引擎=百度 —— 见 `E1_after_restart_general.png`、`E1_after_restart_toggles.png`、`E1_engine_after_restart.png` |
| E2 备份 JSON 含新键（至少 5 个） | **PASS** | `backup_20261105_1830.json` 的 `appPrefs` 实测含 7 个：`defaultReadAloudInterface='player'`、`readAloudPlayerBackground='solid'`、`keepReadAloudOnExit=true`、`mediaButtonPerNext=true`、`ttsSpeechRate=10`(→1.5x)、`ttsPitch=12`(→1.2)、`ttsVolume=60` |
| E2 恢复后同会话生效 | **PASS** | 先改语速 1.0 → 长按「恢复」选本地 JSON（`E2_restore_picker.png`、`E2_restore_dialog.png`）→ 确认（`E2_restore_done.png`）→ 同会话内语速回到 1.5x、音调 1.2、音量 60%，默认界面=播放器、背景=纯色、退出保持=开、媒体键=开 |

`readAloudWakeLock` **不在**备份 JSON 中：该键列于 `lib/src/services/restore_ignore_prefs.dart` 的 `alwaysIgnoreKeys`（与 `audioPlayWakeLock`、Web 服务唤醒锁同组，属设备级偏好，设计上不随备份往返）。故 E2「至少 5 个」按实际可备份键计为 7 个达标；若验收口径要求唤醒锁必须入备份，需产品侧另行裁决（本次不改代码）。

### F. 清理与环境恢复

| 项 | 结果 | 证据 |
|---|---|---|
| F1 恢复默认 | **PASS** | 最终备份 `backup_20261105_1843_after_cleanup.json`：`defaultReadAloudInterface='classic'`、`readAloudPlayerBackground='solid'`、`keepReadAloudOnExit=false`、`mediaButtonPerNext=false`、`ttsSpeechRate=5`(→1.0x)、`ttsPitch=10`(→1.0)、`ttsVolume=100`、`books=0`；`readAloudWakeLock` 缺省=关；引擎=系统 TTS（`F1_cleanup_engine_systemtts.png`）；界面见 `F1_final_general_defaults.png`、`F1_final_general_defaults2.png` |
| F1 删除测试书 / 书架空 | **PASS** | `F1_bookshelf_empty.png`（空态「(つ﹏⊂) 书架还空着…」）；备份 `books=0` |
| F1 font_scale 1.0 | **PASS（默认值）** | `app_font_scale` 未写入偏好（全程未改动），即默认 1.0 |
| F1 1080x1920 / 480 / 竖屏 | **PASS** | `wm size` = Physical 1080x1920；`wm density` = 480；`SurfaceOrientation: 0` |
| 测试文件清理 | **PASS** | 已删除 `/sdcard/Download/batch5a1_test.txt`、`/sdcard/Download/qa5a1_restore.json` 及本次生成的 3 个备份 JSON（保留会话前已存在的 `legado_backup_1793873079273.json`） |

## 三、缺陷与风险

### P1-1（阻塞项）`keepReadAloudOnExit=false` 时退出阅读器不停止朗读

- 现象：常规页「退出阅读时继续朗读」为**关**（默认）时，从阅读器发起朗读后退出阅读器，朗读不停止：
  - 退出后仍存在前台通知「正在朗读: batch5a1_test」（`dumpsys notification` 命中，`legado_playback_foreground`）；
  - `dumpsys media_session` 仍为 `state=PLAYING(3)`；
  - 离开阅读器约 40s 后重新进入，面板显示「正在朗读 · 段4/20」（退出时为 段1/20），证明估算推进在后台持续。
- 复现：**2 次**（18:15 与 18:38 两轮，均 classic 界面、引擎分别为 系统TTS / 百度），第二次 段2→段4。
- 对照：同条件下把该开关置**开**，退出后确实保持播放（B4-开 PASS），说明开关本身读取正确、问题只在「关」分支的停止动作未生效。
- 证据：`B4_off_exit_reader.png`（退出阅读器后已离开阅读页）、`B4_off_retest_after_exit.png`（复测退出后停在书架）、`B4_off_still_playing_after_exit.png`（重进阅读器仍「正在朗读 段4/20」）、`B4_on_keep_playing.png`（开启时保持，对照）。
- 建议排查方向（供修复侧参考，本次未改代码）：`lib/src/screens/reader_screen.dart` 在 `dispose()` 内 `unawaited(ref.read(audioNotifierProvider.notifier).onReaderExit())` 被 `try/catch` **静默吞异常**——若 `ref` 在 dispose 阶段已不可用（Riverpod 常见），异常被吞后整条清理链失效且无日志；另外 `onReaderExit` 首行 `if (!_startedFromReader) return;` 若标记被其它路径复位也会直接跳过。建议加日志/改在路由 pop 前（PopScope）调用并回归验证。

### P2-1（待核实）恢复备份后「朗读唤醒锁」被重置为关

- 现象：18:33 首次从本地 JSON 恢复后，常规页「朗读唤醒锁」由开变为关（`E2_after_restore_toggles.png` 与恢复前 `B3_B5_toggles_on.png` 对比）；该键在 `alwaysIgnoreKeys` 中，按设计不应被恢复影响。
- 复测：18:36 再次置开并重复同一次恢复，**未复现**（仍为开）。故暂记为「疑似恢复期偏好读取/写入竞态或首次恢复清空」，不作为确定性缺陷定性，建议修复侧核查恢复流程对 `alwaysIgnoreKeys` 的保留实现（是否先清空后回写）。
- 证据：`E2_after_restore_toggles.png`、`E2_restore_done.png`。

### P3 观察项

1. **HTTP 引擎失败提示逐段重复**：引擎为「百度」时，每个段落都弹出「朗读音频不可用，本段按估算时长继续：Bad state: TTS 合成未返回音频文件（引擎或缓存异常）」，提示文案直接暴露内部异常字符串，且无「仅提示一次」去重（`D3_panel_with_settings.png`）。功能不阻塞，但建议改为一次提示 + 面板状态位。
2. **HTTP 引擎行的无障碍语义缺失**：`uiautomator` 语义树中引擎列表只有「系统 TTS」「Next引擎」两行，`1.百度`「2.阿里云语音」两行未出现（截图中可见），说明长文本行未暴露 content-desc，影响无障碍与自动化定位（`C2_engine_list_top.png`）。
3. **阅读器面板「朗读设置」按钮目标页与设置主页入口不同**：阅读器朗读面板内的「朗读设置」打开的是标题为「朗读引擎」的 HTTP 引擎管理页，而非三页签「朗读设置」页（`D3_panel_with_settings.png`）。是否预期需产品/设计确认。
4. **`crash_last_crash=true` 遗留标记**：三次备份的 `appPrefs` 中均为 `crash_last_crash=true`，但本次会话 `logcat` 与 `logcat -b crash` 中**无本应用**的 FATAL（crash buffer 23 条全为 `uiautomator`）。判断为覆盖安装保留的历史标记，建议核查是否应在正常退出后清理，避免误弹崩溃提示。
5. **B5 媒体键未触发翻章**：`mediaButtonPerNext=true` 时 `input keyevent 87` 与 `cmd media_session dispatch next/previous` 均未改变章节（`B5_media_next_on.png` 与操作前一致）。无音频源下按验收口径记为 BLOCKED，但建议确认媒体键回调是否真正接到 gate 分支。

## 四、BLOCKED 清单

| 项 | 原因 | 证据 |
|---|---|---|
| 系统 TTS 真实出声、音色可选、音调/音量实际生效 | MuMu 无任何 TTS 引擎：`settings get secure tts_default_synth`=`null`，`pm list packages` 无 tts/speech 包；页面正确呈现空态「系统未安装 TTS 引擎 / 无可用音色」 | `C1_engine_mid.png`、`B6_system_tts_settings.png`（系统页「首选引擎」为空） |
| 朗读唤醒锁 dumpsys 级验证（是否真正持锁） | 无 TTS 引擎，朗读仅走估算模式；仅验证了开关状态与重启保持、以及停止路径 `_releaseReadAloudWakeLock` 无异常 | `B3_B5_toggles_on.png`、`E1_after_restart_toggles.png` |
| 媒体键上一首/下一首实际翻章/切段行为 | 无 TTS 音频源，媒体会话虽为 PLAYING 但按键/派发未产生章节变化（见 P3-5） | `B5_media_next_on.png` |
| 系统 TTS 音色/引擎选择（系统引擎行） | 无引擎 → 行置灰，无可选项 | `C1_engine_mid.png` |

## 五、FATAL / 稳定性统计

- `logcat_full_20261105.txt`（1732 行，threadtime）：`FATAL EXCEPTION` / `ANR in io.legado` / `E/flutter` / `A RenderFlex overflowed` 关键字计数 **0**。
- `logcat_crash_20261105.txt`：崩溃 23 条，`Cmdline:` 统计 **全部为 `uiautomator`**（工具自身退出段错误，按项目约定不计入应用缺陷）。
- 全程 `topResumedActivity` 始终为 `io.legado.flutter_legado/.io.legado.flutter.MainActivity`（除 B6 主动跳系统设置页）；无应用被杀/重启。

## 六、设备终态

| 项 | 终态 |
|---|---|
| 书架 | 空（测试书已删除，含源文件） |
| 朗读设置 | 经典 / 纯色 / 唤醒锁关 / 退出保持关 / 媒体键关 / 语速 1.0x / 音调 1.0 / 音量 100% / 引擎=系统 TTS / 系统引擎与音色空态 |
| 朗读会话 | 已停止：前台通知 0 条；`media_session` `state=STOPPED(1)` |
| 屏幕 | 1080x1920 / 480dpi / 竖屏（rotation 0） |
| 字体缩放 | `app_font_scale` 未写入 = 默认 1.0 |
| 备份目录 | 仅保留会话前已存在的 `legado_backup_1793873079273.json`；本次测试产物已删除 |
| 设备端临时文件 | `/sdcard/Download/batch5a1_test.txt`、`qa5a1_restore.json` 已删除 |

## 七、结论汇总

- **PASS**：A1、A2（含置灰不可点）、A3、B1、B2、B3、B4（开）、B5（gate）、B6、C1、C2、C3、C4、D1、D2、D3、E1、E2、F1
- **FAIL**：**B4（关）** —— P1，`keepReadAloudOnExit=false` 时退出阅读器朗读不停止，可复现 2 次
- **待核实**：P2（恢复后唤醒锁被重置为关，未稳定复现）
- **BLOCKED**：系统 TTS 出声/音色/音调音量实际效果、唤醒锁 dumpsys、媒体键实际翻章（均因 MuMu 无 TTS 引擎/无音频源）
- **建议**：批5a-1 其余项可放行；B4「关」分支须修复后再验收，P2/P3 建议同批或紧随修复

---

编写者：设备验收代理 ｜ 2026-11-05

---

## 八、P1 回修复验（2.0.459+460）

> 本章为 P1-1 回修后的增量复验。第一至七章为 `2.0.458+459` 的原始验收结论，保持不变；原始结论中的「B4（关）FAIL」在本版本已不成立（见 8.2 / 8.7）。

### 8.0 回修基线与方法

| 项 | 值 |
|---|---|
| 代码基线 | `d3bcfcc2c2`（fix `e86babc679` + test `d57df03835`） |
| 版本 | pubspec `2.0.459+460`；设备 `versionName=2.0.459` / `versionCode=460`，`lastUpdateTime=2026-11-05 18:58:36` |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`；sha256 `a1825ea58a31a90cdfdad44cdfb5918d16a0cf4e05771f96050fcb6166febc3e`；设备 `/data/app/.../base.apk` 同 hash |
| 设备 | MuMu「Test测试」`192.168.100.62:5555`，Android 15，1080x1920 / 480dpi / 竖屏 |
| 引擎 | 无 TTS 引擎，朗读走估算节奏（约 19–20s/段）；以通知、`media_session`、前台服务、朗读条段位判定 |
| 测试书 | `/sdcard/Download/batch5a1b_test.txt`（UTF-8，5 章 × 20 段），导入书架 |
| 改码 | 无（QA 只测不改 `lib/`） |

判定口径：
- **退出即停**：`dumpsys media_session` 非 PLAYING + `dumpsys notification` 无 `pkg=io.legado.flutter_legado` + `dumpsys activity services` 无 `PlaybackForegroundService` + 重进阅读器无朗读条。
- **keep=true 保持**：退出后 PLAYING / 通知 / 前台服务持续，且 45s 后朗读条段位前进。
- 证据新增于 `docs/materials_1105b/12_*`–`52_*`；日志 `logcat_qa5a1b_session1.txt`、`logcat_qa5a1b_cycle3.txt`、`logcat_qa5a1b_final.txt`、`qa5a1b_evidence.txt`。

### 8.1 逐项结果

| # | 复验项 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | `keepReadAloudOnExit=false`，顶栏返回退出即停 | **PASS** | `14`→`15`→`16`；19:25:02 media STOPPED、通知 0；45s 后仍 0；`17` 重进无朗读条 |
| 2 | `keep=false`，系统返回键退出即停 | **PASS** | `18`→`19`→`20`；19:26:57 STOPPED、通知 0；45s 后仍 0 |
| 3 | `keep=true` 退出保持并继续推进 | **PASS** | `28`/`29`；19:33:54 退出后 PLAYING + 通知；45s 后仍 PLAYING；`30` 重进朗读条 段19/20（退出前 段14/20） |
| 4 | 听书页来源会话不被阅读器退出误停 | **PASS**（构造方法见 8.3） | `33`→`36`→`37`→`38`/`39`；退出阅读器后 PLAYING + 通知保持 |
| 5 | 两个「朗读设置」入口 → 三页签新页 | **PASS** | `41`（阅读器朗读条入口）、`43`→`44`（听书页入口） |
| 6 | 连续进出 3 次只停一次、无残留/无崩溃 | **PASS** | 3 轮退出均 STOPPED + 通知 0；TTS stop 日志 1→2→3；logcat 377 行错误标记 0 |
| 7 | 清理：恢复默认/删书/空书架/竖屏 | **PASS** | `48`/`50`/`51`；`49`/`52` 空书架；竖屏 0；测试文件已删 |

### 8.2 项 1/2：`keep=false` 退出停止（P1 主项）

项 1（顶栏返回）：
1. 常规页确认「退出阅读时继续朗读」为**关**（`13_keep_off.png`，Switch `checked=false`）。
2. 阅读器启动朗读：面板「正在朗读 第1章 1/5 ·段1/20」，通知「正在朗读: batch5a1b_test」，media_session `PLAYING(3)`，`PlaybackForegroundService isForeground=true`（`14_p1a_start_reading.png`）。
3. 收起朗读面板 → 顶栏返回（`15_p1a_before_topbar_exit.png`），19:25:02 退出：
   ```
   W TextToSpeech: stop failed: not bound to TTS engine
   D MediaSessionService: ... playbackState=PlaybackState {state=STOPPED(1), ...}
   I flutter : 阅读器 dispose 停止朗读失败（忽略）: Bad state: Cannot use "ref" after the widget was disposed.
   ```
   退出后 `media_session` STOPPED、通知记录 0、前台服务 0，落点书架（`16_p1a_after_topbar_exit.png`）。
4. 45s 采样（19:25:10/20/30/40/50）恒为 STOPPED + 通知 0。
5. 19:26:12 重进阅读器（logcat `[BookOpen] ... route=/reader`）：无朗读条/段位语义，正文仍 第1章 1/10（`17_p1a_reenter_after_45s.png`），不存在后台段位推进。

> 日志中的 `阅读器 dispose 停止朗读失败…ref after disposed` 即旧缺陷根因现场（dispose 阶段 ref 已失效）；本版本已在 pop 前调用 `_notifyReadAloudExit()` 完成停止，该条仅为兜底失败的 debugPrint，不影响结果。

项 2（系统返回键）：19:26:40 启动（段1/20，`18_p1b_start_reading.png`）→ 19:26:57 系统返回 → STOPPED/通知 0（落点书籍详情，`19_p1b_sysback_exit.png`）→ 45s 采样仍 STOPPED/0 → 重进无朗读条（`20_p1b_reenter_after_45s.png`）。

### 8.3 项 3/4：`keep=true` 与来源隔离

项 3（`keep=true`，`21_keep_on.png`）：
- 19:28:44 启动朗读（段1/20，`22_keep_on_start.png`）；19:32:20 主动展开面板时 段14/20（`26_keep_on_panel_before_exit.png`，暂停态，19:33:34 恢复 PLAYING）。
- 19:33:54 系统返回退出阅读器 → media `PLAYING(3)`、通知仍在、前台服务在（`28_keep_on_after_sysback_exit.png`）。
- 19:34:54（45s 后）仍 `PLAYING(3)`、通知 2 条（`29_keep_on_45s_still_playing.png`）。
- 19:35:1x 重进阅读器，朗读条显示「正在朗读 第1章 1/5 ·段19/20」（`30_keep_on_reenter_toolbar.png`）——段14→段19，后台推进成立。
- 19:35:35 面板「停止朗读」清理 → STOPPED、通知 0（`31_keep_on_stopped_cleanup.png`）。

项 4（来源隔离，完整构造方法）：
1. 常规页把「默认朗读界面」改为**播放器**（`32_interface_player_keep_off.png`，同时确认「退出阅读时继续朗读」为关）。
2. 阅读器点「朗读」→ 按设计自动进入听书播放器页（`33_isolation_player_page.png`），此时会话由阅读器发起（fromReader=true）。
3. 在听书页用「定时停止 → 按章停止 1 章」（`34_isolation_chapter_stop_set.png`）；19:45:33 章末自然停止，触发 `AudioNotifier.stop()` 清空 `_startedFromReader`（`35_isolation_page_session_stopped.png`，STOPPED/通知 0）。
4. 停留在听书页点播放：走听书页 `play() → _playTtsParagraphs`（非 `startReadAloud` 路径，见 `audio_notifier.dart:768`）重新起播，19:45:55 `PLAYING(3)`（`36_isolation_audiopage_started.png`）——该会话来源为听书页（fromReader=false）。
5. 返回阅读器，会话保持 PLAYING（`37_isolation_back_to_reader.png`）；19:46:04 系统返回退出阅读器（keep=false），19:46:08 仍 `PLAYING(3)`、通知在、前台服务在（`38_isolation_after_reader_exit.png`）；19:46:30 复核仍 PLAYING/通知 2（`39_isolation_after_exit_15s.png`）→ **未被误停**。

> 直接「书架/我的 → 听书页」在 UI 上无入口：`AudioScreen` 仅由阅读器「播放器界面」push，或由 audio 类型书经 `BookOpenUtils` 打开；本次测试书为本地 TXT（无 audio 位）。故按任务允许的「阅读器启动后进入播放器」路径构造，并在听书页内重新发起播放，使其成为听书页来源会话；该构造已在设备完整跑通，非 BLOCKED。

### 8.4 项 5：两个「朗读设置」入口

- 阅读器朗读条「朗读设置」：点击后标题「朗读设置」+ 三页签「常规 / 引擎与音色 / 角色与配乐」（`41_test5_reader_settings_entry.png`），不再落旧「朗读引擎」页。
- 听书页：右上齿轮展开设置区 →「朗读设置 / 引擎/音色/语速与朗读行为」→ 同一三页签页（`43_test5_audio_settings_sheet.png`、`44_test5_audio_settings_entry.png`）。

### 8.5 项 6：连续进出 3 次

- 清空 logcat（19:48:24）后执行 3 轮：进阅读器 → 启动朗读 → 退出（系统返回）。退出时刻约 19:48:29 / 19:49:0x / 19:49:3x；每轮退出后 `media_session=STOPPED(1)`、通知 0、前台服务 0（`45`/`46`/`47_cycle1..3_after_exit.png`）。
- 「只停一次」证据：`TextToSpeech: stop failed`（无引擎环境下每次 `stop()` 必打一条）累计 **1 → 2 → 3**，即每轮退出仅触发一次停止；`onReaderExit` 幂等（首次调用后 `_startedFromReader=false`，重复调用直接 return）。
- 稳定性：该段 logcat 377 行，`FATAL EXCEPTION` / `ANR in io.legado` / `E/flutter` / `RenderFlex overflowed` 计数均为 **0**；`logcat -b crash` 中本应用 0 条；全程 `mCurrentFocus` 保持本应用。

### 8.6 项 7：清理与设备终态

- 朗读设置：默认界面=经典、背景=纯色、唤醒锁=关、退出保持=关、媒体键=关（`50`/`51`）；语速 1.0x / 音调 1.0 / 音量 100%（`48_cleanup_sliders_defaults.png`）。
- 书架：空（选择模式删除 1 本，Toast「已删除 1 本书籍」，`49_cleanup_empty_shelf.png`；终态 `52_device_final_shelf.png`）。
- 设备文件：`/sdcard/Download/batch5a1b_test.txt` 已删除（`ls` 返回 No such file）；`/sdcard/Download/legado_backup/` 仅保留会话前已存在的 `legado_backup_1793873079273.json`。
- 屏幕：`Physical size 1080x1920`、`Physical density 480`、`SurfaceOrientation: 0`（竖屏）。
- 会话：`media_session state=STOPPED(1)`、通知 0、PlaybackForegroundService 0。
- 稳定性终检：`logcat_qa5a1b_final.txt`（1511 行）四类关键字均 0；crash buffer 本应用 0。

### 8.7 结论

- **P1-1 回修有效**：`keepReadAloudOnExit=false` 下，顶栏返回与系统返回键退出都会在退出瞬间停止朗读（通知消失、media_session STOPPED、前台服务结束），45s 后重进无朗读条、无后台段位推进；`keep=true` 退出保持且 45s 后段位推进。
- **来源隔离成立**：听书页发起的会话不因随后进入/退出阅读器被误停。
- 两个「朗读设置」入口均落到三页签新页。
- 连续 3 次进出无残留、无崩溃；设备已恢复默认并清空测试数据。
- 原报告 **B4（关）FAIL 在本版本改判 PASS**；P2/P3 观察项不在本次回修范围，未重新验证，结论保持原样。

---

复验者：设备验收代理 ｜ 2026-11-05（2.0.459+460）
