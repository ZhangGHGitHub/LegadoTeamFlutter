# 设备验收报告：9b-5c 朗读（TTS）真机复验

- 日期：2026-11-11
- 版本：2.0.486+487（`versionName=2.0.486`、`versionCode=487`），HEAD `aacd23a226`
- 设备：MuMu「Test测试」`192.168.100.62:5555`，Android 15（API 35），型号 SM-G9900，1080x1920 / 480dpi，竖屏（SurfaceOrientation=0）
- 安装包：`io.legado.flutter_legado`，APK sha256 `46c9226ba4015119e7c4f69307ae6cf21e9416a38e9b26423d3d6cb668ae653f`
- 验收范围：9b-5c 朗读（TTS）真机复验，只取证不改代码
- 测试书：本地 TXT `qa_b9b5c_book`（1.3 KB，3 章，章节名为第五章/第六章/第七章），经书架「更多 → 添加本地」导入；验收结束后已删除，应用数据已 `pm clear`

## 一、TTS 引擎探测（验收前置）

| 探测项 | 命令 | 结果 |
| --- | --- | --- |
| 默认合成引擎 | `adb shell settings get secure tts_default_synth` | `null` |
| 默认语言 | `adb shell settings get secure tts_default_locale` | `null` |
| TTS 相关包 | `adb shell pm list packages \| grep -i "tts\|speech\|texttospeech"` | 无输出（0 个包） |
| TTS 服务提供者 | `adb shell cmd package query-services -a android.intent.action.TTS_SERVICE` | `No services found` |
| 安装 TTS 数据入口 | `adb shell am start -a android.speech.tts.engine.INSTALL_TTS_DATA` | `Error: Activity not started, unable to resolve Intent` |
| 系统 TTS 命令 | `adb shell cmd texttospeech` | `No shell command implementation.` |
| flutter_tts 初始化 | `adb logcat` | `E TTS: Failed to initialize TextToSpeech with status: -1`（06:22:24.526、06:22:58.843） |
| 语言/音色/停止 | `adb logcat` | `W TextToSpeech: isLanguageAvailable failed: not bound to TTS engine`（06:24:22.350）、`getVoices failed: not bound to TTS engine`（06:24:40.688）、`stop failed: not bound to TTS engine`（06:25:44.175、06:27:15.156、06:27:49.742） |

结论：**该模拟器没有任何可用 TTS 引擎，也没有语言包/音色数据**，`INSTALL_TTS_DATA` 无接收 Activity，无法通过该入口安装。因此“真正调用引擎发声、音色切换、音调/音量实际听感、引擎切换后发声”均属环境限制，应记 **BLOCKED（环境无 TTS 引擎）**，不能记 FAIL。

应用侧行为与上述环境一致：阅读器朗读条与听书页均显示「未配置可用朗读引擎，将按估算节奏朗读」，并建立 MediaSession/前台通知，按估算节奏推进段落与章节。

## 二、总体结论计数

按 15 个可判定子项统计（D10 拆为本地书/在线书，D11 拆为引擎切换/语速切换）：

| 状态 | 数量 | 条目 |
| --- | --- | --- |
| PASS | 9 | A1、B3、B4、B5、C7、C8、C9、E12、E13 |
| FAIL | 1 | D11b（语速设置未生效，P2 真实缺陷） |
| BLOCKED | 5 | A2、C6、D10a、D10b、D11a（均因无 TTS 引擎或无在线书源） |
| 合计 | 15 | — |

- P1：0
- P2：1（D11b 语速被「跟随系统」默认覆盖）
- P3/观察项：3（阅读器 dispose 停止朗读异常日志、STOPPED 会话记录残留、听书页无内联引擎列表）
- 环境限制（BLOCKED）不计入 FAIL；本轮无因代码缺陷导致的崩溃或阻塞。

## 三、逐项结果

### A. 前置

#### 1. 设备 TTS 引擎与语言包探测 — PASS

- 已完成上表全部探测，结论为无引擎、无语言包、无音色。
- 证据：`docs/materials_1111c/logcat_b9b5c.txt`；本报告第一节命令输出。
- 判定：探测任务本身完成，结果作为后续 BLOCKED 依据。

#### 2. 尝试安装 TTS 数据 — BLOCKED（环境限制）

- `am start -a android.speech.tts.engine.INSTALL_TTS_DATA` 返回 `Error: Activity not started, unable to resolve Intent`，系统无接收方。
- flutter_tts 初始化直接失败：`Failed to initialize TextToSpeech with status: -1`。
- 判定：**BLOCKED（环境无 TTS 引擎）**，非应用缺陷。

### B. 入口与配置（无引擎也可验）

#### 3. 阅读器菜单朗读入口 — PASS

- 本地 TXT 导入成功（截图 `tmp_qb9b5c_06_imported.png`，SnackBar「已导入 1 本书籍」）。
- 打开书籍进入阅读器（`tmp_qb9b5c_07_reader.png`）；点按正文中部展开阅读器菜单，底栏存在「朗读」按钮（`tmp_qb9b5c_08_reader_menu.png`）。
- 点击「朗读」后出现经典朗读条：正在朗读、章/段进度、上一章/上一段/播放暂停/下一段/下一章、语速滑条、停止朗读、朗读设置、选择朗读引擎等（`tmp_qb9b5c_09_readaloud.png`）。
- 判定：入口存在且可进入。

#### 4. 听书页（播放器界面）控件 — PASS（引擎选择为间接入口）

- 将「默认朗读界面」切为「播放器」后，从阅读器点「朗读」进入听书页（`tmp_qb9b5c_17_audio_screen.png`）。
- 页面可见：书名、当前章、章进度「1 / 3」、上一章/播放暂停/下一章、章节列表、「后台播放已启用，支持媒体按钮控制」、无引擎提示。
- 点右上齿轮展开「朗读设置」面板（`tmp_qb9b5c_18_audio_settings.png`）：语速 1.0x、音调 1.0、音量 100%，以及「朗读设置（引擎/音色/语速与朗读行为）」入口。
- 听书页本身没有内联引擎列表；引擎选择经「朗读设置 → 引擎与音色」页完成（`tmp_qb9b5c_11_engine_tab.png`、`tmp_qb9b5c_31_global_engine_tab.png`），经典朗读条上另有「选择朗读引擎」图标按钮（`tmp_qb9b5c_09_readaloud.png`）。
- 判定：语速/音调/播放控制均显示；引擎选择可达但非内联，作为 P3 观察项记录，不判 FAIL。

#### 5. 设置 → 朗读设置（引擎/音色/播放行为） — PASS

- 路径：书架 → 我的 → 设置 → 朗读设置；入口副标题「朗读引擎、音色与播放行为」（`tmp_qb9b5c_29_settings_home.png`）。
- 页面三页签：常规 / 引擎与音色 / 角色与配乐（`tmp_qb9b5c_30_global_tts_settings.png`）。
- 引擎与音色页：系统 TTS 单选已选、HTTP 引擎列表（百度/阿里云/Next 等）、「管理朗读引擎」入口；滚动后见「音色：无可用音色（系统默认）」、语速/音调/音量滑条及说明（`tmp_qb9b5c_11_engine_tab.png`、`tmp_qb9b5c_12_engine_scroll.png`、`tmp_qb9b5c_31_global_engine_tab.png`、`tmp_qb9b5c_32_global_engine_scroll.png`）。
- 可改性验证：
  - 「默认朗读界面」从「经典」改为「播放器」，对话框与回显均更新（`tmp_qb9b5c_14_interface_dialog.png`、`tmp_qb9b5c_15_interface_player_set.png`；prefs `flutter.defaultReadAloudInterface=player`）。
  - 语速改为 1.5x（`tmp_qb9b5c_33_speed_changed.png`；prefs `flutter.ttsSpeechRate=10`，即 1.5x）。
  - 音调改为 1.2（`tmp_qb9b5c_42_pitch_changed2.png`；prefs `flutter.ttsPitch=12`）。
  - 音量 100%（默认，可拖动）。
- 音色实际切换：无可用音色，显示空态，属环境限制；配置项本身存在。
- 判定：PASS（音色实际可改性 BLOCKED 于无引擎）。

### C. 播放行为（有引擎时）

#### 6. 点击播放与 TTS 日志 — BLOCKED（环境无 TTS 引擎）

- 点击朗读后会话进入 PLAYING，界面显示「未配置可用朗读引擎，将按估算节奏朗读」；估算节奏会使章/段自动推进（实际观察到第五章 → 第六章，`tmp_qb9b5c_19_audio_playing.png`）。
- logcat 证据：
  - `E TTS: Failed to initialize TextToSpeech with status: -1`（06:22:24.526、06:22:58.843）
  - `W TextToSpeech: isLanguageAvailable failed: not bound to TTS engine`（06:24:22.350）
  - `W TextToSpeech: getVoices failed: not bound to TTS engine`（06:24:40.688）
  - `W TextToSpeech: stop failed: not bound to TTS engine`（多次）
- 未观察到 `speak` 成功日志或任何音频输出；失败原因是系统无引擎、无法绑定，不是应用异常。
- 判定：**BLOCKED（环境无 TTS 引擎）**；应用的“无引擎提示 + 估算推进”降级链可用。

#### 7. 媒体会话 / 通知栏 — PASS

- 播放中 `dumpsys media_session`：
  - `legado_flutter_media io.legado.flutter_legado/legado_flutter_media/2`
  - `mediaButtonReceiver=...io.legado.flutter.MediaButtonReceiver`
  - `state=PlaybackState {state=PLAYING(3), ...}`
- 通知：`NotificationRecord id=7776`，channel `legado_playback_foreground`（名称「听书播放」），flags `ONGOING_EVENT|FOREGROUND_SERVICE|NO_CLEAR|NO_DISMISS`。
- 判定：媒体会话与前台通知均出现，符合预期。

#### 8. 暂停/继续/停止/上一章/下一章 — PASS

| 操作 | 结果 | 证据 |
| --- | --- | --- |
| 暂停 | `MediaSessionService: playbackState=PAUSED(2)`（06:26:40.808） | `tmp_qb9b5c_20_paused.png` |
| 继续 | `state=PLAYING(3)` | 日志 06:26:4x |
| 下一章 | 从第六章 2/3 切到第七章 3/3，「下一章」置灰（末章） | `tmp_qb9b5c_21_next_chapter.png` |
| 上一章 | 从第七章 3/3 回到第六章 2/3 | `tmp_qb9b5c_22_prev_chapter.png` |
| 停止 | `TextToSpeech: stop failed: not bound` → `state=STOPPED(1)`（06:27:15.156/157）；通知 0、前台服务 0 | `tmp_qb9b5c_23_stopped.png` |

- 判定：控制链路与状态机均按预期响应；真正发声仍 BLOCKED。

#### 9. 退出听书页/退出阅读器 — PASS（含语义说明）

- 从听书页按返回：回到阅读器，经典朗读条继续显示且会话仍 `PLAYING(3)`（`tmp_qb9b5c_25_back_from_audio.png`）。这是返回阅读器继续朗读，不等于退出朗读上下文。
- 再退出阅读器回到书籍详情：会话 `state=STOPPED(1)`（06:27:49.743），通知 0、前台服务 0（`tmp_qb9b5c_26_exit_reader.png`）。
- 同时记录到既有非崩溃异常：`I/flutter: 阅读器 dispose 停止朗读失败（忽略）：Bad state: Cannot use "ref" after the widget was disposed.`（06:27:50.069），会话最终仍停止；列为 P3。
- 判定：按“退出阅读上下文即停止”的既有语义 PASS；若要求“仅退出听书页（返回阅读器）就必须停止”，当前实现不满足，但该行为与阅读器内继续朗读的设计一致，建议产品确认。

### D. 边界

#### 10a. 本地 TXT 朗读 — BLOCKED（环境无引擎；UI/会话链已验）

- 本地 TXT `qa_b9b5c_book` 导入、打开、朗读、估算推进、暂停/继续/切章/停止均走通（见 B3、C8）。
- DB 观察：该本地 TXT `books.type=0`，`readConfig.playSpeed=1.0`；`BookType.isLocalBook` 对 type=0 有 origin 兜底，UI 未受影响。记录为观察项，不作为本批缺陷。
- 实际发声：BLOCKED（无 TTS 引擎），不能证明“能听见声音”。

#### 10b. 在线书朗读 — BLOCKED（无在线书源）

- 当前干净环境 `book_sources` 表计数为 0，未配置任何在线书源；本机仅有本地 TXT。
- 未进行在线书朗读；判定 **BLOCKED（无在线书源/环境限制）**，不是 FAIL。

### E. 稳定性

#### 11a. 切换引擎 — BLOCKED（环境无引擎）

- 引擎与音色页只有「系统 TTS」一个可用系统引擎（已选中），音色列表为空；HTTP 引擎为模板项，无法在本机验证实际合成与切换后发声。
- 判定：引擎切换的实际效果 BLOCKED；UI 选项与持久化入口存在。

#### 11b. 切换语速后再播放 — FAIL（真实缺陷 P2）

- 复现步骤与证据见第四节 P2-1。
- 结论：全局语速 1.5x 已持久化且在设置页回显 1.5x，但新朗读会话的听书页面板显示 1.0x；冷启动/停止重播均复现。该问题与 TTS 引擎缺失无关（同一会话的音调 1.2 能正确读回）。
- 判定：FAIL（P2），不是环境 BLOCKED。

#### 12. logcat 五项崩溃计数 — PASS

- 文件：`docs/materials_1111c/logcat_b9b5c.txt`（6,162 行，覆盖 06:22–06:37 验收全过程）。
- 计数（应用维度）：

| 项 | 次数 |
| --- | --- |
| `FATAL EXCEPTION` | 0 |
| `ANR in` | 0 |
| `E/flutter` | 0 |
| `overflowed` | 0 |
| `E AndroidRuntime` | 0 |
| `OutOfMemory` | 0 |

- `logcat -b crash` 共 43 条崩溃记录，全部 `Cmdline: uiautomator`（验收工具自身的 dump 进程），`grep io.legado.flutter_legado` = 0；与应用无关。文件：`docs/materials_1111c/logcat_b9b5c_crash.txt`。

#### 13. pm clear 与设备终态 — PASS

- `adb shell pm clear io.legado.flutter_legado` → `Success`。
- 重新启动应用，书架空态（`tmp_qb9b5c_48_final_empty.png`），测试书已随应用数据清除。
- 终态检查：`dumpsys media_session` 中 `io.legado.flutter_legado` 记录 0；通知 id=7776 记录 0。
- 设备参数：`Physical size: 1080x1920`、`Physical density: 480`、`SurfaceOrientation: 0`。
- 版本仍为 2.0.486 / 487；`/sdcard/Download/qa_b9b5c_book.txt` 已删除。
- 仓库工作树无代码改动，仅新增本报告与 `docs/materials_1111c/` 证据。

## 四、问题分级

### P1（阻塞）
无。

### P2-1（真实缺陷）全局朗读语速被「跟随系统」默认值覆盖

- 现象：设置 → 朗读设置 → 引擎与音色把语速改为 1.5x，prefs 写入 `flutter.ttsSpeechRate=10`，设置页回显 1.5x；但阅读器启动朗读后，听书页「朗读设置」面板与朗读条均显示 1.0x；停止后重播、冷启动后重进均复现。
- 期望：全局语速设置应作用于新朗读会话（`TtsConfig.speed` 传入 `synthesizeToFile`/`audioSpeak`）；或在「跟随系统」开启时设置页明确提示并禁用/隐藏语速滑条，避免“设置成功但无效”的错觉。
- 实际：会话配置被强制回落到 1.0，语速设置不生效。
- 关键证据：
  - `tmp_qb9b5c_33_speed_changed.png`：设置页 1.5x。
  - `tmp_qb9b5c_37_cold_start_speed.png`：冷启动后听书页面板 1.0x。
  - `tmp_qb9b5c_43_restart_pitch_speed.png`：同一会话音调 1.2 正确读回、语速仍 1.0x，排除“无引擎导致全部参数不读回”。
  - `tmp_qb9b5c_45_bar_manual.png`：朗读条「语速:手动」；`tmp_qb9b5c_46_manual_speed_restart.png`：关闭跟随系统后重播显示 1.5x。
  - prefs：`flutter.ttsSpeechRate=10`；config：`ttsFollowSys=false`（切换后）。
- 定位线索（仅描述，不改代码）：`flutter_legado/lib/src/widgets/reader/read_aloud_bar.dart` 的 `_kFollowSystemDefaultSpeed=1.0`（:58），`_loadFollowSystem()` 缺省 `follow=true` 并在 :107/:115 调用 `updateConfig(speed: 1.0)`，手动切换处 :642 同样回落 1.0；听书页 `audio_screen.dart:657` 直接展示 `provider.config.speed`，因此显示 1.0。启动入口 `startReadAloud` 虽先读取 `ttsSpeechRate`，但朗读条挂载后的跟随系统逻辑又把它覆盖。
- 影响：默认配置下「朗读设置 → 语速」形同无效；用户需发现朗读条的「语速:跟随系统」并切到「手动」才生效。与 TTS 引擎缺失无关，属真实功能/交互缺陷。
- 严重度：P2（非阻塞、可绕过，但核心设置项默认失效且无提示）。

### P3-1（既有非崩溃异常）阅读器 dispose 停止朗读失败日志

- `I/flutter: 阅读器 dispose 停止朗读失败（忽略）：Bad state: Cannot use "ref" after the widget was disposed.`（06:27:50.069）。
- 会话最终 `STOPPED`、通知 0，无崩溃；与 9C 报告记录的既有问题一致，非本批引入。列为 P3，建议后续在 dispose 路径避免使用失效 `ref`。

### P3-2（观察项）停止后 MediaSession 记录仍存在

- 停止后 `dumpsys media_session` 仍能看到 `legado_flutter_media` 记录，但 state 为 `STOPPED(1)`，通知与前台服务均为 0。
- 与既有实现一致；若后续要支持“停止后媒体键重新启动朗读”，需确认该 STOPPED 会话的按键路由语义。

### P3-3（观察项）听书页无内联引擎列表

- 听书页只提供「朗读设置」入口，引擎/音色需进入三页签页选择；经典朗读条有「选择朗读引擎」按钮。
- 不影响功能，属入口层级/可发现性观察项。

### 其他观察

- 本地 TXT 导入后 `books.type=0`（非 4096）。`BookType.isLocalBook` 对 type=0 走 origin 兜底，本批未发现行为异常；建议后续核对本地导入 type 位写入一致性。
- 无引擎时估算节奏会真实推进章节（第五章自动到第六章），与“未配置可用朗读引擎，将按估算节奏朗读”提示一致，不是真实发声。

## 五、设备终态

- 应用数据：`pm clear io.legado.flutter_legado` 成功；测试书与导入缓存已清除。
- 界面：书架空态（`tmp_qb9b5c_48_final_empty.png`）。
- 会话/通知：`dumpsys media_session` 中 legado 记录 0；通知 id=7776 记录 0。
- 设备：1080x1920 / 480dpi / 竖屏；Android 15（API 35）。
- 应用：`io.legado.flutter_legado` 2.0.486（487）仍在装。
- 外部测试文件：`/sdcard/Download/qa_b9b5c_book.txt` 已删除。
- 仓库：无代码修改；仅新增 `docs/materials_1111c/` 与本报告。

## 六、门禁引用

- 工程版本：`flutter_legado/pubspec.yaml:4` → `2.0.486+487`；仓库 HEAD `aacd23a226`；验收期间未改代码。
- 安装包：`io.legado.flutter_legado` `versionName=2.0.486` / `versionCode=487`，sha256 `46c9226ba4015119e7c4f69307ae6cf21e9416a38e9b26423d3d6cb668ae653f`。
- 本轮为设备验收，未重跑 `flutter analyze`/`flutter test`，不引用未执行的工程门禁结果；设备侧门禁以本报告第一节探测、第三节逐项证据、第四节问题分级为准。
- 证据目录：`docs/materials_1111c/`
  - 截图：`tmp_qb9b5c_01_launch.png` ~ `tmp_qb9b5c_48_final_empty.png`（48 张，含入口、听书页、设置页、控制状态、退出与终态）。
  - 日志：`logcat_b9b5c.txt`（主日志，6,162 行）、`logcat_b9b5c_crash.txt`（crash buffer，43 条均为 uiautomator）。
- 关键复现命令：
  - `adb shell settings get secure tts_default_synth`
  - `adb shell pm list packages | grep -i tts`
  - `adb shell cmd package query-services -a android.intent.action.TTS_SERVICE`
  - `adb shell am start -a android.speech.tts.engine.INSTALL_TTS_DATA`
  - `adb shell dumpsys media_session`
  - `adb shell dumpsys notification --noredact`
  - `adb shell pm clear io.legado.flutter_legado`

## 七、结论

- **通过（不依赖引擎的 UI/配置/入口/退出停止/稳定性）**：入口、听书页控件、朗读设置三页签、引擎/音色空态、默认界面切换、语速/音调持久化、MediaSession/通知、暂停/继续/切章/停止、退出阅读器停止、崩溃计数 0、清理终态均验证通过。
- **阻塞（环境）**：MuMu 无任何 TTS 引擎与语言包，`INSTALL_TTS_DATA` 无接收方，实际发声、音色、音调听感、引擎切换后播放均无法验证，统一记 **BLOCKED（环境无 TTS 引擎）**，不记 FAIL。
- **真实缺陷**：D11b 全局语速被「语速:跟随系统」默认值覆盖（P2-1）；证据充分、可复现、可绕过，需回修或产品明确语义。
- **未闭环**：在线书朗读（无在线书源）BLOCKED；真实 TTS 发声需在有引擎的真机/模拟器上复验。

## 十、语速修复复验（2.0.487+488，提交 `a5e1fc016f`）

### 10.1 复验前置

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-11（07:08–07:20） |
| 安装包 | `io.legado.flutter_legado`，`versionName=2.0.487` / `versionCode=488` |
| APK sha256 | `28023ba15ddb28c23a2e02069f74607f20031712d002d9bb0c67335a13a9c073`（从设备 `base.apk` 拉取后本地计算，与派发值一致） |
| 仓库 | HEAD `db9c4adde7`，`flutter_legado/pubspec.yaml` = `2.0.487+488`；复验期间无代码改动 |
| 设备 | MuMu「Test测试」`192.168.100.62:5555`，Android 15（API 35），1080x1920 / 480dpi，竖屏（SurfaceOrientation=0） |
| 引擎环境 | `tts_default_synth=null`，无 TTS 包，`Failed to initialize TextToSpeech with status: -1`（07:13:57.019）；实际发声仍为环境 BLOCKED |
| 测试书 | 本地 TXT `qa_b9b5c_fix_book.txt`（488 B，导入后识别 7 章，章名含第五章/第六章/第七章），经「书架 → 更多 → 添加本地 → 搜索 qa_b9b5c」导入；复验后已删除文件并 `pm clear` |
| 方法 | `adb shell uiautomator dump` 读取 Flutter 语义节点（文本/SeekBar 百分比与倍速）定位并 `input tap/swipe`；`adb` 以 root 读取 `shared_prefs/FlutterSharedPreferences.xml` 佐证落库；截图存 `docs/materials_1111c/` |

说明：本构建语速持久化刻度为参考刻度 `ttsSpeechRate`，映射 `(speed*10-5)`，即 1.5x→10、2.0x→15；音调 `ttsPitch` 为 `pitch*10`，即 1.2→12。

### 10.2 逐项结果

| # | 项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| A1 | 设置 → 朗读设置 → 引擎与音色 → 语速改为 1.5x | PASS | `tmp_qb9b5c_fix_00_speed_1_0.png`（改前 1.0x）、`tmp_qb9b5c_fix_01_speed_set_1_5.png`（1.5x）；语义 `SeekBar "[desc] 40%, 1.5x"`；prefs `flutter.ttsSpeechRate=10` | 滑块 tap 至 40% 精确落在 1.5x，落库立即生效 |
| A2 | 阅读器朗读条显示 1.5x | PASS | `tmp_qb9b5c_fix_02_bar_1_5.png`；语义节点「语速 1.5x」、`SeekBar 40%, 1.5x` | 修复前该处显示 1.0x（见原 P2-1）；本轮为「跟随系统」模式直接显示 1.5x，核心缺陷不再复现 |
| A3 | 听书页显示 1.5x，与朗读条一致 | PASS | `tmp_qb9b5c_fix_03_audio_1_5.png`（侧栏 1.5x）、`tmp_qb9b5c_fix_04_audio_page.png`（整页） | 听书页设置面板 `SeekBar 40%, 1.5x`，与朗读条同值 |
| A4 | 停止 → 重播仍 1.5x | PASS | `tmp_qb9b5c_fix_05_replay_1_5.png` | 返回阅读器「停止朗读」后重新「朗读」，听书页面板仍 1.5x |
| A5 | `am force-stop` 冷启动后进听书页仍 1.5x | PASS | `tmp_qb9b5c_fix_06_cold_start_1_5.png`；force-stop 后 `pidof` 无进程，`am start` 重启 | 冷启动后重新进入听书页，`SeekBar 40%, 1.5x`；prefs `ttsSpeechRate=10` 仍在 |
| A6 | 切换章节仍 1.5x | PASS | `tmp_qb9b5c_fix_07_chapter_switch_1_5.png` | 在听书页点第 3 章（进度 3/7）后，面板仍 `40%, 1.5x` |
| B7 | 朗读条切「跟随系统」→ 保持 1.5x | PASS | `tmp_qb9b5c_fix_08_bar_manual_1_5.png`（切前「语速:手动」）→ `tmp_qb9b5c_fix_09_bar_follow_1_5.png`（「语速:跟随系统」） | 手动→跟随系统切换后语速仍 1.5x，未回落 1.0x；切换前手动态同为 1.5x |
| B8 | 切回「手动」→ 仍 1.5x | PASS | `tmp_qb9b5c_fix_08_bar_manual_1_5.png`；语义 `语速:手动` + `40%, 1.5x` | 手动模式保留用户值，不再重置 |
| B9 | 手动拖到 2.0x → 退出重进听书页仍 2.0x（落库） | PASS | `tmp_qb9b5c_fix_11_bar_2_0.png`（朗读条 2.0x）；prefs `flutter.ttsSpeechRate=15`；`tmp_qb9b5c_fix_12_audio_2_0.png`（重进听书页 2.0x） | 手动滑条写 prefs（15=2.0x），停止重播后听书页面板 `60%, 2.0x`；修复前对应回归断言为 Expected 15 / Actual 10，本轮实测 15 |
| C10 | 音调仍可设 1.2 并读回 | PASS | `tmp_qb9b5c_fix_14_settings_pitch_1_2_speed_2_0.png`（设置页 语速 2.0x / 音调 1.2）；prefs `flutter.ttsPitch=12`；`tmp_qb9b5c_fix_15_pitch_readback_1_2.png`（听书页读回 1.2） | 经设置页滑块设置并落库，新朗读会话听书页 `SeekBar 47%, 1.2`，语速同时保持 2.0x |
| C11 | 无引擎降级提示正常（不崩溃、有提示） | PASS | `tmp_qb9b5c_fix_02/03/04/05/06/07/09*.png` 均含红字「未配置可用朗读引擎，将按估算节奏朗读」 | 提示在朗读条与听书页均出现，会话按估算节奏继续推进；全流程无崩溃 |
| D12 | logcat 五项崩溃计数须 0 | PASS | `logcat_b9b5c_fix.txt`（7,238 行，07:08–07:19 全程）；`logcat_b9b5c_fix_crash.txt` | 见 10.3 计数表，六项全 0；crash buffer 75 条均为 `Cmdline: uiautomator`（验收工具），`grep io.legado.flutter_legado` = 0 |
| D13 | `pm clear` 清理 + 截图终态 | PASS | `tmp_qb9b5c_fix_16_final_empty.png`；`pm clear` 返回 `Success` | 书架空态；`dumpsys media_session` 中 legado 记录 0；无活动通知记录；prefs 仅剩应用自建迁移标记（无 ttsSpeechRate/ttsPitch）；`/sdcard/Download/qa_b9b5c_fix_book.txt` 已删除 |

### 10.3 logcat 崩溃计数（D12）

主日志 `docs/materials_1111c/logcat_b9b5c_fix.txt`：

| 项 | 次数 |
| --- | --- |
| `FATAL EXCEPTION` | 0 |
| `ANR in` | 0 |
| `E/flutter` | 0 |
| `overflowed` | 0 |
| `E AndroidRuntime` | 0 |
| `OutOfMemory` | 0 |

- `logcat -b crash`（`logcat_b9b5c_fix_crash.txt`，1,631 行）75 条 `F DEBUG` 全部为 `Cmdline: uiautomator`，与应用无关。
- 与本缺陷相关的日志仅为环境侧 TTS 绑定失败：`E TTS: Failed to initialize TextToSpeech with status: -1`（07:13:57.019）、`W TextToSpeech: isLanguageAvailable/getVoices/stop failed: not bound to TTS engine`；以及 force-stop 产生的系统级 `app died` 记录（07:13:52，测试步骤导致，非崩溃）。
- 本轮未出现上一轮记录的 `I/flutter: 阅读器 dispose 停止朗读失败…`；该 P3-1 观察项未复现（不据此宣称已修复，仅记录本轮未观察到）。

### 10.4 复验结论

- **结论：语速修复生效。**
- 计数：**PASS 13 / FAIL 0 / BLOCKED 1**（BLOCKED 仅为「实际发声」，环境无 TTS 引擎，与代码无关）。
- 原 P2-1（全局语速被「跟随系统」默认值覆盖）的四个关键场景均不再复现：设置页 1.5x → 新会话朗读条/听书页 1.5x；停止重播、force-stop 冷启动、切换章节均保持；「跟随系统/手动」来回切换不再重置；手动 2.0x 落库为 `ttsSpeechRate=15` 并可重进读回。
- 证据目录：`docs/materials_1111c/`，截图 `tmp_qb9b5c_fix_00` ~ `tmp_qb9b5c_fix_16`（17 张），日志 `logcat_b9b5c_fix.txt`、`logcat_b9b5c_fix_crash.txt`。
- 遗留观察（P3，不计失败，且非本修复引入）：
  1. 听书页「朗读设置」面板的音调/音量滑条只调用 `updateConfig` 修改当前会话配置，不写 `ttsPitch`/`ttsVolume`；音调持久化需经设置页（`read_aloud_settings_screen.dart`）。C10 已按设置页路径验证通过。
  2. 实际发声、音调/音量听感仍 BLOCKED（MuMu 无 TTS 引擎），需在有引擎真机复验。
