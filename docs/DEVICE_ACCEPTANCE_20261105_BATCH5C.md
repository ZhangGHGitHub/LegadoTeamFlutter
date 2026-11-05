# 批5c 设备验收报告：统一定时 Sheet + 读完本章 + 定时持久化 + TTS 缓存保留

- 验收日期：2026-11-06
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`
- 代码基线：`a29cc75816dd9e8c5428de004b80a8e96f1899ca`（chore: 批5c 收尾（2.0.461+462 双日志与计划登记））
- 版本：pubspec `2.0.461+462` → 设备 `versionName=2.0.461` / `versionCode=462`
- 证据目录：`docs/materials_1105d/`
- 验收角色：设备验收代理（只测不改代码，未修改 `lib/`、`rust/`、`app/` 任何文件）

## 一、环境

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例 index 1，`adb -s 192.168.100.62:5555`（状态 `device`） |
| 系统 | Android 15（`ro.build.version.release=15`），机型伪装 SM-G9900 |
| 屏幕 | 1080x1920，density 480，`SurfaceOrientation: 0`（竖屏） |
| 显示 | 应用位于主 display，单屏操作，未使用 `-d` |
| TTS 引擎 | **无**：朗读走估算节奏（`text.length / 5` 秒/段）；以朗读条段位、自动推进、通知/media_session 判定，不要求出声 |
| 构建 | `cd flutter_legado && flutter build apk --release`，Gradle `assembleRelease` 91.3s；无 Rust 改动，未重建 `.so` |
| 安装 | `adb install -r build/app/outputs/flutter-apk/app-release.apk` → Success；随后 `pm clear` 清空应用数据后开始验收 |
| 测试书 | 3 本 UTF-8 无 BOM TXT：①`5c_long_chapter` 单章 6 段（528 字，估算约 144s）；②`5c_multi_chapter` 3 章、每章 2 段（约 48s/章）；③`5c_chapter_end` 单章 7 段（397 字，估算约 70s）。push 到 `/sdcard/Download/` 后经「添加本地」导入 |

### APK 指纹

```
sha256  61ed499f478d8ea8396568bc688c9c8492aef81e790f9e84c4bd70aec6e17609
path    flutter_legado/build/app/outputs/flutter-apk/app-release.apk
size    202,010,908 bytes（2026-11-05 23:55）
aapt    package=io.legado.flutter_legado versionCode=462 versionName=2.0.461
```

构建与安装证据：`docs/materials_1105d/apk_info.txt`。

## 二、逐项结果

结论口径：PASS=实测符合；FAIL=实测不符且可复现；BLOCKED=设备能力缺失无法验证（附证据）。

### A. 统一定时 Sheet

| 项 | 结果 | 证据 |
|---|---|---|
| A1 阅读器朗读条「定时」与听书页「定时」打开同一 Sheet：标题、分钟/章节 tabs、预设、滑块、读完本章开关（仅分钟）、开始/取消/停止、运行中剩余量 | **PASS**（按钮文案为「停止定时」，语义为停止计时） | 阅读器入口 `01_reader_timer_sheet_minute.png`、`02_reader_timer_sheet_chapter.png`；听书页入口 `10_audio_timer_sheet_minute.png`、`11_audio_timer_sheet_minute_tab.png`；运行中剩余量 `12_active_timer_sheet.png`（剩余 00:44）、`17_b4_paused_remaining47.png`（剩余 00:47）、`25_active_chapter_3.png`（剩余 1 章）；读完本章等待态通知见 B2 |
| A2 分钟预设 0/10/20/30/60/90/120/180、章节 0/1/2/3/5/10/20/50；滑块 0–180/0–50；切换 tab 互斥 | **FAIL**（预设集合与验收口径不一致；滑块与互斥通过） | 分钟实际预设：关闭、10、15、20、25、30、45、60、90、120、180（多 15/25/45，`01`）；章节实际预设：关闭、1、2、3、5、8、10、15、20（缺 50，多 8/15，`02`）；50 章仅可经滑块到达：`04_chapter_slider_max.png`「100%, 50 章」；分钟滑块上限 180：`03_minute_slider_max.png`「100%, 180 分钟」；互斥：先启动按章 1 章（`25`「剩余 1 章」），切分钟页启动 10 分钟 → Sheet 活动状态变为「剩余 09:55」，章状态被替换 |
| A3 320dp + 1.6 字体：Sheet 可滚动、按钮不溢出 | **PASS** | 设 `wm size 720x1280`、`wm density 360`（320dp 宽）、`settings system font_scale 1.6` 后重启：分钟页内容超出屏幕但可滚动，滚动后「取消 / 开始」可见（`22_a3_narrow_top.png`、`23_a3_narrow_bottom.png`）；章节页预设/滑块/说明/按钮同屏（`24_a3_narrow_chapter_top.png`）；logcat `RenderFlex overflowed` 计数 0 |

说明：A2 的偏差为预设集合与任务书不一致，可能是实现沿用参考版扩展预设；请主代理对照参考版 `ReadAloudTimerSheet.kt` 最终裁决。50 章可经滑块设置，功能上可达。

### B. 定时行为（估算模式）

| 项 | 结果 | 证据 |
|---|---|---|
| B1 1 分钟定时到点停止（state idle / media_session STOPPED / 通知消失） | **PASS** | 通过备份注入 `ttsTimer=1`（`prefs_backup_seed_1min.json`）；t0=`1793894707.9`，t0+16s Sheet 显示「剩余 00:44」，t0+60.1s `state=STOPPED(1)`、通知记录 0；误差 ≤1s（采样间隔 5s）。见 `12`、`13`、`timing_log_5c.txt` |
| B2 1 分钟 + 读完本章：到点未完章则继续到章末再停 | **PASS** | t0=`1793894872`；t0+59s PLAYING「剩余 1 分钟」；t0+64s PLAYING「正在朗读(读完本章后停止)」；t0+90s 仍 PLAYING；t0+95s STOPPED、通知消失（章末停止，距到点约 30s）。见 `15_b2_stopped_at_chapter_end.png`、`timing_log_5c.txt`。补充：TTS/估算路径 `_isAtChapterEnd()` 仅在无段落时为真，末段估算窗口不提前判定，因此「已在章末立即停」在本路径不构成独立可观测分支（仅流媒体按播放位置判定）；本次验证的是「未播完则续读到章末再停」 |
| B3 按章 1 章：自然播完 1 章后停止，不进入下一章 | **PASS** | t0=`1793895020`，通知「正在朗读(剩余 1 章)」；t0+16s STOPPED（开始计时前已朗读约 28s，第 1 章自然播完）；界面仍为「第一章 初见 1/3」，未进入第二章。见 `16_b3_stopped_chapter1.png`、`timing_log_5c.txt` |
| B4 暂停冻结：暂停 >60s 不停止；恢复后剩余时间继续，最终停止 | **PASS** | t0=`1793895079`；t0+13s 暂停（PAUSED），暂停 65s 后（`1793895163`）仍 PAUSED、Sheet「剩余 00:47」（仅扣 13s）；`1793895180` 恢复，`1793895232`（约 52s 后）STOPPED，累计播放约 60s。见 `17_b4_paused_remaining47.png`、`timing_log_5c.txt` |
| B5 停止/取消：停止定时后计时清空、朗读继续；通知标题剩余量/「读完本章后停止」正确 | **FAIL（部分）** | 「停止定时」：Sheet 关闭、通知标题恢复「正在朗读: 5c_long_chapter」、`state=PLAYING`，计时清空（`18_b5_stop_timer_keeps_playing.png`）；「取消」：Sheet 关闭后通知仍为「正在朗读(剩余 1 分钟)」，计时**未**清空（`19_b5_cancel_sheet_timer_kept.png`），与验收项「停止/取消后计时清空」不符；通知标题「剩余 1 分钟」「剩余 1 章」「读完本章后停止」均正确（B1/B2/B3 证据） |

### C. 持久化

| 项 | 结果 | 证据 |
|---|---|---|
| C1 设置 10 分钟/章节 3/读完本章开 → 杀进程重启 → Sheet 回显、不自动倒计时、无运行中通知 | **PASS** | 设置后 `am force-stop` → 重启：`dumpsys notification` 无本应用 NotificationRecord、`dumpsys media_session` 无 PlaybackState、无服务；打开 Sheet：章节 tab 选中「3 章」（`20_c1_restart_chapter_tab.png`），分钟 tab「10 分钟」+ 读完本章开（`21_c1_restart_minute_tab.png`），无「剩余」活动状态、无「停止定时」按钮（未自动开始倒计时） |
| C2 定时键在 prefs/备份中的形态记录 | **PASS** | 最终备份 `prefs_backup_after_c1.json` 的 `appPrefs`：`readAloudTimerMode='minute'`（String）、`ttsTimer=10`（Int）、`readAloudTimerChapters=3`（Int）、`finishCurrentChapterAfterTimer=true`（Bool）；缓存键 `audioCacheCleanTime=1440`（Int）。四项定时键均随备份 `appPrefs` 往返；备份键名与任务书一致。另有 `prefs_backup_before_c1.json`（ttsTimer=19、chapters=50、finish 缺省）与 `prefs_backup_seed_1min.json`（ttsTimer=1）作为过程证据 |

说明：prefs 实际存储形态以应用生成的备份 `appPrefs` 为证据（release 包不可 `run-as`，无法直读 `/data/data/.../shared_prefs`）。

### D. 缓存保留

| 项 | 结果 | 证据 |
|---|---|---|
| D1 「缓存保留时间」0/10/60/1440/10080 可选，0=即听即焚文案；重启保持 | **PASS** | 对话框预设：即听即焚、10 分钟、1 小时、1 天、7 天 + 滑块（`05_cache_retention_dialog.png`）；选 0 时「当前：即听即焚」（`06_cache_retention_zero.png`）；选 1 天后经多次 force-stop 重启，设置页行仍「1 天」（`31_d3_cache_section.png`）；重置后默认回落「10 分钟」（`33_final_cache_default_10min.png`） |
| D2 TTS 缓存对话框显示大小/文件数/当前保留值，清理按钮可点并提示 | **PASS**（实际缓存文件见 BLOCKED） | `07_tts_cache_dialog.png`：「系统 TTS 合成缓存：0 个文件，共 0 B」「当前保留：1 天（在「缓存保留时间」行设置）」；点「清理」后 toast「已清理 0 个缓存文件」（`08_tts_cache_cleared_toast.png`） |
| D3 两个缓存入口不重复滑块；无假开关 | **PASS** | 缓存区仅两行：`缓存保留时间`（打开含滑块的独立对话框）与 `TTS 缓存`（只读统计+清理，无滑块、提示到保留时间行设置），`31_d3_cache_section.png`、`07`；两行均实际可点，无占位/假开关 |

### E. 回归与稳定性

| 项 | 结果 | 证据 |
|---|---|---|
| E1 朗读/切章/暂停/停止/退出停止（5a-1）正常；翻页/目录/书签正常；FATAL/ANR/E.flutter/overflow=0 | **PASS** | 切章：阅读器朗读条「下一章」由第一章 1/3 → 第二章 2/3，通知 text 同步（`android.text=第二章 再会`）；暂停：朗读条中央按钮 → `PAUSED(2)`、面板「已暂停」；恢复 → `PLAYING(3)`；停止朗读：→ `STOPPED(1)`、通知记录 0（`26_e1_stop_readaloud.png`）；退出阅读停止：播放中系统返回 → 2s 后 STOPPED、10s 后仍 STOPPED、无通知（`27_e1_exit_reader_stopped.png`）；目录：三章列表正常（`28_e1_toc.png`）；书签：长按正文 →「书签」→ toast「已添加书签」（`29`）；翻页：长书 1/4 → 2/4、正文变化（`30`）；日志见下节 |

### F. 清理

| 项 | 结果 | 证据 |
|---|---|---|
| F1 恢复默认（分钟模式/0/0/读完本章关/保留 10 分钟）、删除测试书、font_scale 1.0、1080x1920/480、竖屏、空书架、无朗读会话/通知 | **PASS** | `pm clear io.legado.flutter_legado` 重置应用数据（同时删除 3 本测试书、书签、定时与缓存偏好）；重启后书架空态（`32_final_empty_shelf.png`、`34_final_shelf_empty.png`）；朗读设置缓存行「保留 10 分钟」（`33`）；定时默认值以首次打开 Sheet 证据 `01_reader_timer_sheet_minute.png`（关闭/0/读完本章关）与代码默认 `minute/0/0/false` 佐证；`wm size=1080x1920`、`wm density=480`、`font_scale=1.0`、`SurfaceOrientation=0`；`dumpsys notification` 本应用记录 0、`dumpsys media_session` PlaybackState 0、无服务 |

## 三、缺陷与风险

### P2

1. **A2 预设集合与验收口径不一致**（用户可见）
   - 实际分钟预设：关闭、10、15、20、25、30、45、60、90、120、180；任务要求 0/10/20/30/60/90/120/180（多 15/25/45）。
   - 实际章节预设：关闭、1、2、3、5、8、10、15、20；任务要求 0/1/2/3/5/10/20/50（缺 50，多 8/15）；50 章只能通过滑块设置。
   - 复现：阅读器朗读条或听书页 →「定时」→ 分别查看分钟/章节 tabs（`01`/`02`）。
   - 期望：与任务书/参考版预设集合一致；实际：集合不同。若参考版即当前实现，请裁决验收口径。

2. **B5「取消」不清空计时**
   - 复现：启动 1 分钟定时 → 打开定时 Sheet → 点「取消」→ Sheet 关闭，但通知仍显示「正在朗读(剩余 1 分钟)」，计时继续。
   - 期望（按任务书）：停止/取消后计时清空；实际：只有「停止定时」会清空计时，「取消」仅关闭 Sheet。`19_b5_cancel_sheet_timer_kept.png`。
   - 补充：Sheet 中「停止定时」只停止计时、朗读继续；没有直接停止朗读的按钮（停止朗读在朗读条）。

### P3

1. **运行中切换 tab 混合展示**：按章定时运行中切到分钟 tab，活动状态仍显示「剩余 1 章」（实际值正确，但页签与状态语义不匹配）。该现象已在 Active 计划登记项 ⑨，本次复现。
2. **播放/暂停按钮无 content-desc**：听书页中央播放按钮、阅读器朗读条中央暂停按钮无可访问语义，自动化/无障碍只能按坐标定位（5b 已登记，本批仍在）。
3. **通知剩余量分钟粒度**：分钟模式通知固定显示「剩余 1 分钟」，Sheet 内为秒级「剩余 00:44」；两者精度不同，属设计取舍。

无 P1。

## 四、BLOCKED 清单

| 项 | 原因 | 证据 |
|---|---|---|
| TTS 缓存实际文件生成、按保留时间清理、0=即听即焚删除、清理不删播放中文件 | MuMu 无 TTS 引擎，缓存目录始终 0 个文件/0 B；只能验证设置项、统计展示、清理按钮与提示 | `07_tts_cache_dialog.png`、`08_tts_cache_cleared_toast.png` |
| 朗读真实出声/音色/音量 | 无 TTS 引擎，全部走估算推进 | 听书页红色提示「未配置可用朗读引擎，将按估算节奏朗读」 |
| 真实音频回调驱动的段完成/章末到点判定（非估算路径） | 无音频完成回调，章末/段完成由估算时钟驱动 | `timing_log_5c.txt` |

## 五、FATAL / 稳定性统计

- `logcat_full_20261106.txt`（23,603 行，threadtime）：`FATAL EXCEPTION` / `ANR in io.legado` / `E/flutter` / `RenderFlex overflowed` 计数 **0 / 0 / 0 / 0**。
- `logcat_crash_20261106.txt`（7,490 行）：339 条崩溃记录，`Cmdline:` 统计 **全部为 `uiautomator`**（工具自身退出段错误，按项目约定不计入应用缺陷）。
- 全程 `topResumedActivity` 为本应用；无应用被杀/重启（`pm clear`、`force-stop` 为验收主动操作）。

## 六、设备终态

| 项 | 终态 |
|---|---|
| 书架 | 空（`34_final_shelf_empty.png`，空态文案「书架还空着，先去搜索书籍或从发现里添加吧！」） |
| 应用数据 | 已 `pm clear`；测试书、书签、定时/缓存偏好均清除 |
| 缓存保留 | 默认 10 分钟（`33_final_cache_default_10min.png`） |
| 定时设置 | 默认分钟模式 / 0 分钟 / 0 章 / 读完本章关（首次 Sheet 证据 `01`） |
| 朗读会话 | 无：`NotificationRecord` 0、`PlaybackState` 0、无前台服务 |
| 显示 | `wm size` 1080x1920、`wm density` 480、`font_scale=1.0`、`SurfaceOrientation=0`（竖屏） |
| 临时文件 | 设备端 `/sdcard/Download/5c_*.txt` 与本次生成的 `legado_backup_1793894636614.json`、`legado_backup_1793895540505.json`、`backup_seed_1min.json` 已删除；保留会话前已有的 `legado_backup_1793873079273.json` |

## 七、结论

- A1/A3、B1–B4、C1/C2、D1–D3、E1、F1：**PASS**。
- A2：**FAIL**（预设集合与验收口径不一致，P2）。
- B5：**FAIL（部分）**（「取消」不清空计时，P2）。
- 无 P1；无应用 FATAL/ANR/E.flutter/overflow。
- 真实 TTS 缓存文件与朗读出声：**BLOCKED**（设备无 TTS 引擎）。
- 综合判定：**不通过（2 项 P2 待裁决/修复）**；若任务书预设集合与「取消」语义以参考版为准，可将 A2/B5 降级为口径差异后再复核。

---

编写者：QA 设备验收代理 ｜ 2026-11-06
