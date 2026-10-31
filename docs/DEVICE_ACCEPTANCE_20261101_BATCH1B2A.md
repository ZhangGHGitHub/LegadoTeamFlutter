# 批 1b-2a 设备验收报告（文本阅读器音量键长按连翻 · 600ms 节流 · 菜单/子路由门控 · 漫画路径 · 朗读门控 · 回归）

> 范围：批 1b-2a「音量键长按翻页」——`keyPageOnLongPress` 设置接线；
> 文本阅读器长按 repeat 连翻 / 关闭时长按只翻一页 / 600ms 同方向节流；
> 音量键被应用消费（系统音量不变化）；阅读菜单展开与目录子路由门控；
> 漫画阅读器逐次翻页与事件 Map 协议；朗读时音量键门控；回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，`adb devices` 实测 `device`）。
>
> **结论：场景 2/3/5/6 PASS；场景 1 FAIL（P1：冷启动/FlutterView 未聚焦时文本阅读器收不到音量键）；
> 场景 4 BLOCKED（设备无 TTS 引擎，仅估算节奏朗读，真实 TTS 门控不可验）。**
> OS 层 FATAL EXCEPTION=0、ANR=0、RenderFlex overflow=0、OOM=0（回归窗口 652 行 logcat）。
> 关键发现：文本阅读器音量键依赖 Flutter 视图焦点；同机同冷启动下漫画原生桥路径可正常消费音量键，
> 证明事件可到达应用，**「MuMu 音频层全局截走」的归因不完整**；文本路径未走原生桥，属应用侧 P1。
> 上一轮批 1a 将音量键不生效归因于 MuMu 系统层截走；本轮原生桥对照实验表明事件可达 Activity，
> 文本路径失败是 Flutter 焦点/路由问题（见 §3.1e）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| 分辨率 / 密度 | 1080x1920 / 480dpi（全程未改） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带；guest 内 `id` 为 uid=0 root，可 `sendevent`） |
| 应用包名 / 入口 | `io.legado.flutter_legado` / `io.legado.flutter.MainActivity` |
| 验收版本 | versionName **2.0.432** / versionCode **433**（`dumpsys package` 实测；`lastUpdateTime=2026-11-01 05:57:21`） |
| 源码基线 | `master` HEAD `605aac90d7`（`chore: 批1b-2a 收尾（2.0.432+433 双日志与计划关闭登记）`） |
| 验收时间 | 2026-11-01 05:57 ~ 06:32（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261101_batch1b2a/`（`shots/`、`xml/`、`logcat/`、`fixtures/`；`tmp_debug/` 不入库）；截图副本 `docs/materials_1101c/`（47 张） |

### 1.1 构建与安装（本批仅 Dart/Kotlin，复用 quickjs `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（批 1b-2a 无 Rust/FFI 变更）；复用 `jniLibs/` 现有 quickjs `.so` |
| x86_64 `.so`（本设备） | `liblegado_ffi.so`：**51,883,696 B**，mtime **2026-10-31 23:45:24**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e` |
| arm64 `.so` | **51,630,176 B**，mtime **2026-10-31 23:44**，sha256 `c8c8aea52e09fe0101051327539dc9878ef1504801f4bb7f8d671c9e6cff3f38` |
| `.so` meta | `{"contentHash":-993835076,"mode":"release","quickjs":true,"builtAt":"2026-10-31T23:45:24.5288717+08:00","rustFingerprint":"1ede733fbc7f7e25778d8cd48406b4db0d49626fc4a4602eb83ae86150f23616"}` —— **quickjs:true** |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 94.2s`，**199,267,168 B（190.0 MB）**；sha256 `1ba164602aa4e6ba7d30eac5c39e9c314a37037fdda78e328cbac0e04bfc158d`（日志 `logcat/build_1b2a.log`） |
| 安装 | `adb install -r` **Success**；安装前旧版本 2.0.431/432 → 安装后 **2.0.432/433** |
| 启动冒烟 | `am start -W` COLD **298~339ms**；空书架正常渲染（`25_final_empty_shelf.png`） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0 |
| 音量键逻辑单测 | `flutter test test/unit/volume_key_page_gate_test.dart test/unit/reader_keys_event_parse_test.dart test/unit/read_config_1b2a_key_page_long_press_test.dart test/widget/reader_volume_key_long_press_test.dart` | **28/28 passed**（含 P1 红→绿「50ms repeat 连续 1s：cover 动画中继续翻页 ≥3」、600ms 节流、菜单/子路由门控、dispose reset） |
| Kotlin 桥接单测 | `gradlew.bat :app:testDebugUnitTest --tests io.legado.flutter.ReaderKeysBridgeArgumentTest` | **BUILD SUCCESSFUL**（59s）；`tests="5" skipped="0" failures="0" errors="0"` |
| 全量 Flutter 测试 | 未重跑（CI 覆盖；本批提交自述 3672 passed） | 以 CI 为准，本报告不重复计入 |

### 1.3 测试数据（QA 数据侧；验收后已删）

| 数据 | 说明 |
|---|---|
| `qa1b2a_read.txt` | 96,431 B，单章「第1章 音量键长按验收」，400 段；阅读器实测 **200 页**，用于文本长按/连点/页号取证 |
| `qa1b2a_comic.cbz` | 220,590 B，8 张 900x1600 PNG（页内大字 P1..P8）；本地 cbz 恒走漫画阅读器；实测 **1/8** |
| `qa1b2a_2ch.txt` | 15,538 B，两章「第2章 跨章验收第2章」，每章 60 段；实测每章 **20 页**，用于跨章回归 |
| 导入方式 | 书架「更多 → 添加本地」→ DocumentsUI 选择；三本均导入成功 |
| 注入方式 | 文本/漫画按键：`adb shell sendevent /dev/input/event5 1 114 {1|2|0}`（MuMu `Xiaomi Keyboard` 支持 `KEY_VOLUMEDOWN=114`；value=2 模拟内核自动重复，value=1/0 为按下/抬起）；`input keyevent 25/24` 另作系统注入对照 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | **文本阅读器音量键长按翻页（重点）** | **FAIL（P1，见 1e）**；语义子项在 FlutterView 聚焦后 PASS | ON 长按 **9/200 → 16/200**（+7 页）、音量 6→6；OFF 长按 **12→13**（仅 +1）；OFF 快速连点 **10→11**（仅 +1）；OFF 间隔后 **11→12**；冷启动 9/200 不变、音量 10→9 / 8→7→6（两次）；聚焦后 9→10、音量 8→8 |
| 1a | 设置 ON：长按连续翻页 ≥3 | **PASS**（聚焦后） | 20 次 repeat：**9/200 → 16/200**（+7），音量 6→6（`11/12_on_longpress_*`） |
| 1b | 设置 OFF：同样长按只翻 1 页 | **PASS**（聚焦后） | 8 次 repeat：**12/200 → 13/200**（仅 +1），音量 8→8（`10_off_longpress_only_one*`） |
| 1c | OFF：600ms 内快速连点 2-3 次只翻 1 页 | **PASS**（聚焦后） | 3 次按下（<100ms）：**10/200 → 11/200**（仅 +1）（`08_off_rapid3*`） |
| 1d | OFF：间隔 >600ms 再按可翻 | **PASS**（聚焦后） | 等待后单按：**11/200 → 12/200**（`09_off_after_600ms*`） |
| 1e | **冷启动/未聚焦：音量键达应用并由应用消费** | **FAIL（P1）** | 冷启动两次：9/200 **不变**，系统音量 10→9、8→7→6；同机同冷启动漫画原生桥 1/8→2/8 且音量 10→10（对照证明事件可达应用） |
| 1f | 「按键长按翻页」设置行接线 | **PASS** | 默认 checked=false；UI 开→prefs `keyPageOnLongPress=true`；UI 关→`false`；`pm clear` 后键缺失（默认 false） |
| 2 | 菜单/子路由门控 | **PASS**（前置：FlutterView 已聚焦，见 1e） | 菜单展开：16/200 不变、音量 6→5（系统音量条出现，按原版语义交还系统）；目录子页：音量 5→4、返回阅读器仍 **16/200** |
| 3 | 漫画路径逐次翻页 | **PASS** | 单键 1/8→2/8→3/8→2/8；repeat 3/8→5/8；设置 ON 时 1/8→2/8→4/8；音量保持（首轮 1→1、ON 复测 4→4）；冷启动 1/8→2/8、音量 10→10；无崩溃 |
| 4 | 朗读门控 | **BLOCKED**（无 TTS 引擎）；估算节奏模式有观测 | `tts_default_synth=null`、无 `TTS_SERVICE`；朗读栏红字「未配置可用朗读引擎，将按估算节奏朗读」；onplay=true 时 17/200→18/200、音量 1→1；onplay=false+聚焦时音量 1→0；另一采样点朗读栏展开时音量 10→10（播放/暂停态无法确证，不纳入结论） |
| 5 | 回归 | **PASS** | 手势滑动 16→17→16；跨章 20/20 → 第2章 1/20；点击/滑动/菜单/设置往返正常；FATAL=0、ANR=0、overflow=0、OOM=0 |
| 6 | 清理与恢复 | **PASS** | `pm clear`；DB books/book_sources/chapters **0/0/0**；prefs 键缺失（默认）；测试文件全删；空书架；保留 **2.0.432/433** |

## 三、逐场景证据

### 3.1 场景 1：文本阅读器音量键长按翻页（重点）

- **预期**：设置 ON 时长按音量下键连续翻页（≥3 页）；OFF 时长按只翻 1 页、600ms 内同方向连点只翻 1 页、间隔 >600ms 可再翻；正常阅读时音量键被应用消费（系统音量不变、无音量条）。
- **实际**：**在 FlutterView 已获得焦点时全部符合**（1a~1d）；**冷启动直接进阅读器时按键不达文本阅读器、系统音量变化（1e）**。

#### 1a 设置 ON：长按 repeat 连续翻页

- 设置行：阅读设置 → 页面控制 →「按键长按翻页」开（`02_setting_on.png`；prefs `flutter.keyPageOnLongPress=true`）。
- 阅读页 9/200（`11_on_longpress_before_crop.png`）→ 注入 20 次 `EV_KEY 114 value=2`（60ms 间隔，约 1.2s）→ **16/200**（`12_on_longpress_after_crop.png`），**+7 页**。
- 系统音量 6→6（`settings get system volume_music_speaker`），阅读页无音量条：应用消费 ✓。
- 说明：P1 修复（动画中继续翻页）在设备上成立；连续翻页未被动画 settle 吞掉。

#### 1b/1c/1d 设置 OFF：长按只 1 页、600ms 节流

| 子项 | 操作 | 页面 | 音量 |
|---|---|---|---|
| 1b | 8 次 repeat（约 0.6s） | **12/200 → 13/200（+1）**（`10_off_longpress_only_one_crop.png`） | 8→8 |
| 1c | 3 次按下，间隔 <100ms | **10/200 → 11/200（+1）**（`08_off_rapid3_crop.png`） | 8→8 |
| 1d | 等待 >600ms 后单按 | **11/200 → 12/200（+1）**（`09_off_after_600ms_crop.png`） | 8→8 |

- 1b 只 +1 与「长按 repeat 被忽略」一致；1c/1d 与「同方向 600ms leading 节流」一致。
- 设备注入说明：`input keyevent 25` 不产生 `repeatCount>0`（仅单 down/up），故长按用 evdev `value=2` 模拟内核自动重复；`KeyRepeatEvent` 分支另有 widget 测试 `[批1b-2a] true：长按 repeat 逐次翻页` 与 `[P1 红→绿] 50ms repeat 连续 1s` 覆盖。

#### 1e **【P1】冷启动/未聚焦时文本阅读器收不到音量键**

**复现步骤**（两次独立复现）：

1. `adb shell am force-stop io.legado.flutter_legado` → `am start`（COLD 298~339ms）；
2. 书架点 `qa1b2a_read` 进入文本阅读器，停留 6s；
3. 注入音量下键（物理等价 `sendevent`，或 `input keyevent 25`）；
4. 观察页号与系统音量。

**结果**：

| 轮次 | 操作 | 页面 | 系统音量 |
|---|---|---|---|
| 冷启动 #1 | 单次 down/up | **9/200 不变**（`04/05_cold_start_key_*`） | **10 → 9** |
| 冷启动 #2 | 单次 down/up | **9/200 不变**（`05b/05c_cold2_*`） | **8 → 7** |
| 冷启动 #2 | 8 次 repeat | **9/200 不变**（`05d_cold2_after_repeat_crop.png`） | **7 → 6** |

**对照实验（同机、同冷启动、同一注入）**：

- 冷启动后直接开 `qa1b2a_comic`：`页数1/8` → 按键 → **`页数2/8`**，音量 **10→10**（`xml/ui_cold_comic2.xml`）。
- 结论：音量键**能到达 Activity 并被应用消费**；不能把文本路径的不生效归因于「MuMu 音频层在应用之前全局截走」——至少原生桥路径不受该限制。
- 文本路径失败原因（证据链推断）：文本阅读器仅注册 `HardwareKeyboard.instance.addHandler(_onHardwareKey)`（`reader_screen.dart:378`），依赖 FlutterView 收到按键；冷启动时 FlutterView 未获得 Android 按键焦点，按键落到 `MainActivity.onKeyDown` → `super.onKeyDown` → 系统音量。漫画阅读器走了 `ReaderKeysBridge` 原生捕获（`reader_comic_screen.dart:482 setVolumeKeyCapture(true)`），不依赖 FlutterView 焦点，因此在冷启动也正常。

**聚焦后恢复的证明**：进入书架搜索页 → 点搜索框 → `input keyboard keyevent 29` 输入 `a`（Flutter 文本框获得焦点；`xml/ui_search3.xml` 显示 `text=a`）→ 返回书架 → 打开同一本书 → 按键：**9/200 → 10/200**，音量 **8→8**（`06_focus_key_before_crop.png` / `07_focus_key_after_crop.png`）；第二轮同样 **9→10**、音量 **6→6**（`07b_focus2_before_crop.png` / `07c_focus2_after_crop.png`）。
即：同一台设备、同一安装、同一注入方式，**唯一变量是 FlutterView 是否获得焦点**。

**影响**：用户正常冷启动直接阅读时，「音量键翻页」与新增的「按键长按翻页」均不生效，且系统音量被改变；必须先使用一次文本输入（如搜索）才恢复。该路径是常规入口，故判 **P1 FAIL**，不是 BLOCKED。

**修复建议（供实现侧评估）**：

1. 文本阅读器复用漫画同一原生桥：`PlatformBridgeService.registerVolumeKeyHandler` + `setVolumeKeyCapture(true)`，在 `ReaderScreen` 生命周期内按 `volumeKeyPage`/菜单/路由状态开关；长按 repeat 与 600ms 节流仍在 Dart 侧 `VolumeKeyPageGate`（或原生传 `repeatCount`，Dart 消费），可同时解决焦点与冷启动；
2. 或至少在阅读器进入时确保 FlutterView 获得焦点（需验证 MuMu/Flutter 3.44.8 下可行性；原生桥是更稳妥方案）；
3. 菜单/子路由门控需在原生捕获路径同样生效（当前文本 Dart 层门控逻辑可作为语义基准）。

#### 1f 设置行接线

- 默认：阅读设置 → 页面控制 →「按键长按翻页」`checked=false`（`01_setting_row_default_off.png`）。
- UI 开：`checked=true` → prefs `flutter.keyPageOnLongPress=true`（`02_setting_on.png`）。
- UI 关：`checked=false` → prefs `false`（`03_setting_off.png`）。
- 清理后（`pm clear`）：键不存在，回落默认 false。

### 3.2 场景 2：菜单/子路由门控（PASS，前置：FlutterView 已聚焦）

- **菜单展开**：阅读页 16/200，点中间展开菜单（`13b_menu_before_key.png`）→ 音量下键 → 页面仍 **16/200**，系统音量 **6→5**，顶部出现系统音量条（`13_menu_open_key.png`）。
  - 语义对齐原版 `ReadBookActivity.onKeyDown`：`menuLayoutIsVisible` 时 `return super.onKeyDown`，即交还系统；「不翻页」满足，音量变化是预期行为。
- **目录子路由**：菜单 →「目录」→ 目录页（`14b_toc_before.png`）→ 音量下键 → 系统音量 **5→4**（`14_toc_key.png`）→ 返回阅读器 → 页面仍 **16/200**（`15_after_toc_back_crop.png`），无后台翻页。
- 说明：该门控在冷启动未聚焦时无法观测（音量键根本不达应用），与 1e 同一缺陷；本次为聚焦后验证。

### 3.3 场景 3：漫画路径（PASS）

- 打开 `qa1b2a_comic`（本地 cbz → 漫画阅读器）：`页数1/8`（`16_comic_open.png`）。
- 单键：`1/8 → 2/8 → 3/8`；首轮音量 1→1（`settings` 采样）；再按上键 `3/8 → 2/8`。
- 长按 repeat（10 次 value=2）：`3/8 → 5/8`（`17_comic_repeat.png`），音量 1→1。
- 设置 ON 时复测：`1/8 → 2/8`（单键）、`2/8 → 4/8`（repeat）（`18_comic_on_tests.png`），音量 4→4；证明漫画路径不区分 `keyPageOnLongPress`（对齐原版 `ReadMangaActivity.onKeyDown` 每个 keydown 都翻页）。
- 冷启动对照：`1/8 → 2/8`，音量 10→10（`xml/ui_cold_comic2.xml`），见 1e 对照。
- 事件 Map 协议：页面变化即证明 `{direction, longPress}` 新负载被 Dart 正确解析（`reader_keys_event_parse_test` 另覆盖旧 String 形态与畸形负载）；无 `FATAL EXCEPTION`/`ANR`/崩溃。

### 3.4 场景 4：朗读门控（BLOCKED：无 TTS 引擎）

- 设备无可用 TTS：`settings get secure tts_default_synth=null`；`pm list packages` 无 TTS 包；`cmd package query-services -a android.intent.action.TTS_SERVICE` **No services found**。
- 应用侧启动朗读后显示红字「**未配置可用朗读引擎，将按估算节奏朗读**」，朗读栏可暂停/停止（`20_tts_no_engine.png`）。
- 已观测（**不作为真实 TTS 门控验收**）：
  - `volumeKeyPageOnPlay=true` + 朗读栏活跃 + 聚焦：音量下键 → **17/200 → 18/200**，音量 **1→1**（`21_reading_onplay_true_crop.png`）；
  - `volumeKeyPageOnPlay=false` + 朗读栏活跃 + 聚焦：音量下键 → 音量 **1→0**（应用未消费，`22_reading_false_system_volume.png`）；
  - 另一采样点（朗读栏展开、播放/暂停态无法确证）：音量 **10→10**，不作为门控结论。
- 结论：**BLOCKED 登记**——无真实 TTS 引擎，估算节奏模式的 `audioNotifier.isPlaying` 语义无法与真实朗读等价确认；不据此判 PASS。若后续安装 TTS 引擎，应按 `volumeKeyPageOnPlay` 开/关复测。

### 3.5 场景 5：回归（PASS）

| 项 | 操作 | 结果 |
|---|---|---|
| 翻页动画 | ON 长按 20 次 repeat | 9→16/200 连续翻页，无卡死/Completer 悬挂（1a） |
| 手势滑动 | 左滑/右滑 | **16→17→16/200**（`28/29_swipe_*_crop.png`） |
| 点击翻页 | 右侧点击 / 章末点击 | 正常翻页；章末 `20/20` 点击 → 第2章 `1/20` |
| 跨章 | 第1章末页 20/20 → 下一章 | 标题「第2章 跨章验收第2章」、页 `1/20`、书进度 100%（`26/27_ch*_crop.png`） |
| 退出阅读器后系统音量恢复 | 退出漫画到书架 → 音量下键 | 音量 **4→3**；无阅读器页面、无捕获残留（`19_after_comic_exit.png`） |
| 文本退出后系统音量 | 冷启动测试中退出/冷启动 | 系统音量正常变化（见 1e） |
| 设置/书架往返 | 我的→设置→阅读设置→书架→开书 | 正常，无异常 |
| OS 健康（回归窗口 652 行 logcat） | `logcat/full_session_1b2a.log` | `FATAL EXCEPTION`=**0**、`ANR in io.legado`=**0**、`RenderFlex overflowed`=**0**、`OutOfMemoryError`=**0** |

- 噪声说明：logcat 内 3 条 `Fatal signal 11 (SIGSEGV) ... in tid/pid (Shutdown thread)`（pid 14782/14820/14862）为 `uiautomator dump` 退出时工具自身崩溃（MuMu 已知行为），**不是应用进程**（应用 pid=14692），已排除，不计入应用 FATAL。

### 3.6 场景 6：清理与恢复（PASS）

- `adb shell pm clear io.legado.flutter_legado` → **Success**。
- DB 复核（`sqlite3 /data/data/io.legado.flutter_legado/app_flutter/legado.db`）：`books=0`、`book_sources=0`、`chapters=0`。
- prefs 复核：`keyPageOnLongPress`/`volumeKeyPageOnPlay` 键缺失（回落默认 false）；其余批 1a/1b 键未残留。
- 设备文件：`/sdcard/Download/qa1b2a_read.txt`、`qa1b2a_comic.cbz`、`qa1b2a_2ch.txt` 全删（`ls | grep qa1b2a` 无输出）；未创建 `/data/local/tmp` 脚本。
- 系统音量恢复 8；冷启动空书架（`25_final_empty_shelf.png`）；保留验收版本 **2.0.432/433**。

## 四、FATAL / ANR 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION`（应用） | **0** |
| `ANR in io.legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| `uiautomator` 工具 `Fatal signal 11`（Shutdown thread，非应用） | 3（噪声，已排除） |

## 五、问题分级与建议

| 级别 | 问题 | 证据 | 建议 |
|---|---|---|---|
| **P1** | 冷启动/FlutterView 未聚焦时，文本阅读器收不到音量键；「音量键翻页」与新增「按键长按翻页」均不生效，系统音量被改变 | §3.1e：冷启动 9/200 不变、音量 10→9（两次）；聚焦搜索框后 9→10、音量不变；同冷启动漫画 1→2、音量不变 | 文本阅读器复用 `ReaderKeysBridge` 原生捕获（按 `volumeKeyPage`/菜单/路由开关），或确保阅读器进入时 FlutterView 获得焦点；菜单/子路由门控在原生路径同步 |
| P3 | 设备无 TTS 引擎，朗读为估算节奏；真实 `volumeKeyPageOnPlay` 门控不可验 | §3.4：`tts_default_synth=null`、No TTS services、红字提示 | 登记 BLOCKED；安装 TTS 引擎后补测 |
| P3 | `uiautomator dump` 退出时工具 SIGSEGV（Shutdown thread） | §3.5 噪声说明 | 已知 MuMu 工具行为，非应用缺陷；后续可用 `exec-out uiautomator dump /dev/tty` 或忽略 |
| P3 | 菜单展开/目录子页时音量键交还系统，系统音量条出现 | `13_menu_open_key.png`、`14_toc_key.png` | 符合原版 `menuLayoutIsVisible → super.onKeyDown` 语义，非缺陷；若产品要求「菜单内也拦截音量」，需另行裁决 |

## 六、结论

- **场景 1：FAIL（P1）**。长按连翻、OFF 只翻 1 页、600ms 节流、音量消费四项语义**在 FlutterView 聚焦后均 PASS**（设备级页号/音量双证）；但**冷启动常规入口 FAIL**，且对照实验表明不能归因于 MuMu 音频层全局截走，而是文本阅读器未走原生音量键捕获路径（FlutterView 焦点依赖）。本批「按键长按翻页」在冷启动场景不可用，不能判整体 PASS。
- **场景 2：PASS**（聚焦后；菜单/目录门控符合原版语义）。
- **场景 3：PASS**（漫画冷启动也可用，原生桥路径正确，无崩溃）。
- **场景 4：BLOCKED**（无 TTS 引擎；估算节奏模式的消费行为仅作旁证，不判 PASS）。
- **场景 5：PASS**（滑动/点击/跨章/退出恢复；FATAL/ANR/overflow/OOM 全 0）。
- **场景 6：PASS**（数据/prefs/文件清理，空书架，保留 2.0.432/433）。
- **总体**：**不通过（1 项 P1）**。建议修复 1e 后复验场景 1（冷启动直达阅读器、无需文本输入）与场景 2；场景 4 待 TTS 引擎可用后补测。

## 七、证据路径

- 报告截图：`docs/materials_1101c/`（01~29，含冷启动/聚焦/ON/OFF/菜单/目录/漫画/朗读/回归/清理）。
- 原始证据：`tmp_debug/device_acceptance_20261101_batch1b2a/`
  - `logcat/build_1b2a.log`（构建日志，EXIT=0）
  - `logcat/full_session_1b2a.log`（回归窗口 652 行）
  - `shots/`（全部原始截图，含未入 docs 的冷启动 #2、焦点 #2、滑动/跨章原图）
  - `xml/`（`ui_cold_comic2.xml`、`ui_search3.xml`、`ui_reader_*`、`ui_menu_*`、`ui_toc.xml`、`ui_final.xml` 等 uiautomator dump）
  - `fixtures/`（三份测试素材，仅本地留存）

编写者：QA（ZCode 子代理）｜ 2026-11-01

---

# 八、回修复验（P1 冷启动音量键 · 2026-11-01 07:05 ~ 07:35）

> 背景：§五 P1「冷启动/FlutterView 未聚焦时文本阅读器收不到音量键」由提交
> `12262dd3e4 fix(ui): 批1b-2a 文本阅读器音量键改原生捕获` 修复
> （文本阅读器改走 `PlatformBridgeService` 音量键捕获租约 + 原生
> `ReaderKeysBridge`，与 Flutter 视图焦点无关；漫画改用同一租约 API）。
> 本节为同一设备、同一 APK 版本上的回修复验，覆盖原 P1 复现路径与关联回归。
> 版本保持不变：**2.0.432+433**（未改版本/双日志/Rust）。

## 8.1 环境与产物（本次实测）

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`；guest `id` 为 uid=0 root） |
| 设备 | SM-G9900（MuMu 伪装）/ Android 15 / x86_64 / 1080x1920 / 480dpi |
| 源码基线 | `master` HEAD **`12262dd3e4f605727ea0a17d035a59550c6d6751`** |
| 版本 | versionName **2.0.432** / versionCode **433**（`dumpsys package`；`lastUpdateTime=2026-11-01 07:05:36`） |
| Rust | **未重建**（本批无 Rust）；复用 `flutter_legado/android/app/src/main/jniLibs/x86_64/liblegado_ffi.so`：51,883,696 B，mtime 2026-10-31 23:45:24，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e` |
| APK | `flutter build apk --release` **EXIT=0**（`assembleRelease 4.1s`，增量复用，构建日志 `logcat/build_reverify.log`）；产物 199,283,552 B（190.1 MB），mtime `2026-11-01 07:05:27`，sha256 `f1aca26a2c0475896e8e24ec2a01c5488f755f09209883a1d5b2e1fd9f760d5e` |
| 安装 | `adb install -r` **Success**（199,283,552 bytes streamed）；安装后 2.0.432/433 |
| 启动冒烟 | 冷启动 `am start -W` COLD **315~369ms**；空书架正常渲染 |

> APK 体积由基线 199,267,168 B 变为 199,283,552 B（+16,384 B），与
> `reader_screen` / `platform_bridge_service` / `reader_comic_screen` 三处
> Dart 改动规模一致；`.so` 未变（本批无 Rust）。

### 8.1.1 交付门禁（本次 QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!**（EXIT=0） |
| 音量键单测/组件测试 | `flutter test test/unit/volume_key_page_gate_test.dart test/unit/reader_keys_event_parse_test.dart test/unit/read_config_1b2a_key_page_long_press_test.dart test/widget/reader_volume_key_long_press_test.dart` | **37/37 passed**（含本批新增「Android 文本阅读器原生音量键捕获」组：进入→capture true 一次/dispose→false、原生 Map 短按/长按、Android 不注册 HardwareKeyboard、菜单/子路由释放与恢复、volumeKeyPage=false 不捕获、桌面仍翻页、切书、文本↔漫画租约不冲突） |
| Kotlin 桥接单测 | 未重跑（本批无 Kotlin 改动；基线 §1.2 已 5/5） | 以基线为准 |
| 全量 Flutter 测试 | 未重跑（CI 覆盖） | 以 CI 为准 |

### 8.1.2 测试数据与注入方法（本次）

| 项 | 说明 |
|---|---|
| 素材 | 复用基线三件套：`qa1b2a_read.txt`（96,431 B，单章 200 页）、`qa1b2a_comic.cbz`（8 页）、`qa1b2a_2ch.txt`（两章各 20 页）；经 `adb push` + 书架「更多 → 添加本地」导入 |
| 单次按键 | **`adb shell input keyevent 25`**（KEYCODE_VOLUME_DOWN，走 InputManager→窗口焦点→`MainActivity.onKeyDown`）；全程未触碰搜索框/文本输入 |
| 长按 repeat | `sendevent /dev/input/event5 1 114 {1,2,0}` 且**每条事件后补 `sendevent /dev/input/event5 0 0 0`（SYN_REPORT）**；20 次 value=2、间隔 60ms（约 1.2s） |
| 音量观测 | `settings get system volume_music_speaker`（键按下后 AudioService 会回写，可作为「是否被应用消费」判据；本次全程未用 `settings put` 干预，除最终恢复外） |
| 页号观测 | 截图阅读器底部页脚 + `uiautomator dump`（漫画 `content-desc` 含「页数x/8」） |

> **注入方法学修正（重要）**：本机 `input keyevent --longpress 25` **不产生
> `repeatCount>0`**（仅单次 down/up），ON 态也只翻 1 页；真实长按 repeat 必须用
> evdev `value=2`。另 evdev `sendevent` **不补 SYN_REPORT 时事件会被内核缓冲、
> 在后续某个 SYN 时成批投递**（实测书架无捕获时：同一命令 down+up 不补 SYN
> 音量不变；补 SYN 后一次按键使音量 6→4，即把此前缓冲的一对事件一并冲入）。
> 因此本次长按证据全部使用「逐事件补 SYN」的注入；单次按键证据全部使用
> `input keyevent 25`。基线报告中部分 sendevent 单键结论受此影响，建议后续
> 设备任务统一此口径。

## 8.2 修复前 / 修复后对照（原 P1 同一复现路径）

| 观测项 | 修复前（基线 §3.1e，HEAD 605aac90d7） | 修复后（HEAD 12262dd3e4） | 结论 |
|---|---|---|---|
| 路径 | force-stop → 冷启动 → 书架点 `qa1b2a_read` → **不点搜索框/不输入** | 同左（shelf 点书直达阅读器） | 同条件 |
| 起始页 | 9/200 | **1/200**（数据清空后重新导入） | — |
| 单次音量下键·页号 | **9/200 不变** | **1/200 → 2/200（+1）** | 修复 |
| 单次音量下键·系统音量 | **10 → 9**（另一次 8 → 7） | **8 → 8（不变，未出现音量条）** | 修复 |
| 长按 repeat（20 次 value=2）·OFF | **9/200 不变**、音量 7→6 | **3/200 → 4/200（+1，符合 OFF 语义）**、音量 8→8 | 修复 |
| 长按 repeat（20 次 value=2）·ON | 未验（受焦点阻塞） | **12/200 → 18/200（+6）**、音量 7→7 | 修复 |
| 同参数受控对照 | — | OFF：1→2（+1）；ON：2→8（**+6**），两次音量均不变 | 语义正确 |
| 依赖条件 | 必须先点搜索框获得焦点才生效 | **无需任何文本输入/焦点操作** | P1 根因（焦点依赖）已消除 |

## 8.3 逐场景结果（本次实测）

| # | 场景 | 结果 | 关键证据（页号 + 音量 + 截图） |
|---|---|---|---|
| 1 | **冷启动直达文本阅读器（P1 核心）** | **PASS** | 单键 1/200→2/200、音量 8→8（`r_01`/`r_02`）；OFF 长按 2→3、音量 8→8（`r_03`/`r_04`）；ON 冷启动 12→18（+6）、音量 7→7（`r_10`/`r_11`）；受控同参数 OFF +1 / ON +6、音量 4→4（`r_28`~`r_32`） |
| 2 | **OFF 节流** | **PASS** | 600ms 内 3 连点 4→5（+1，`r_05`）；间隔 >600ms 单键 5→6（`r_06`）；两次间隔 1.2s 按 6→8（+2，`r_07`）；全程音量 8→8 |
| 3 | **菜单 / 子路由门控** | **PASS** | 菜单展开：8→7、7→6（系统音量条出现，页号不变，`r_08`/`r_13`）；目录子页：6→5、3→2（页号不变，`r_14`）；返回阅读器并收起菜单后 20→21、音量 2→2（`r_16`） |
| 4 | **文本 ↔ 漫画** | **PASS** | 漫画冷启动 1/8→2/8、音量 1→1（`r_18`/`r_19`）；返回文本 21→22→23，**每键严格 +1（无双翻页）**、音量 1→1（`r_20`~`r_22`） |
| 5 | **退出阅读器后恢复系统音量** | **PASS** | 书架（退出文本后）音量 2→1（`r_17`）；批量清理后书架按键仍调系统音量（音量 8→0 的异常由 §8.6 注 4 的 `settings put` 失同步造成，非应用缺陷，已用音量键恢复到 8） |
| 6 | **回归（动画/滑动/跨章/健康）** | **PASS** | 滑动 23→24→23（`r_23`/`r_24`）；跨章 第1章 20/20 → 第2章 1/20、100%（`r_25`/`r_26`）；ON 长按连翻动画无卡死；logcat 7,059 行：FATAL=0、ANR=0、RenderFlex overflow=0、OOM=0、`E/flutter`/未捕获异常=0 |
| 7 | **清理与恢复** | **PASS** | `pm clear` Success（DB/prefs 目录消失）；`/sdcard/Download/qa1b2a_read.txt` 已删（`grep qa1b2a` 无输出）；prefs 无 `keyPageOnLongPress`（回落默认）；系统音量 8（`dumpsys audio` streamVolume=8）；冷启动空书架（`r_27`/`r_33`）；保留 **2.0.432/433** |

### 8.3.1 场景 1 细化（冷启动，全程未触碰搜索框/未文本输入）

| 子项 | 操作 | 页号 | 系统音量 | 截图 |
|---|---|---|---|---|
| 1a | 冷启动后单次音量下键（`input keyevent 25`，OFF 默认） | **1/200 → 2/200** | **8 → 8** | `r_01` / `r_02` |
| 1b | OFF：`input keyevent --longpress 25` | 2/200 → 3/200（+1） | 8 → 8 | `r_03` |
| 1c | OFF：evdev repeat 20 次（未补 SYN，初测） | 3/200 → 4/200（+1） | 8 → 8 | `r_04` |
| 1d | ON（UI 开关开启，prefs `flutter.keyPageOnLongPress=true`）：冷启动单键 | 18/200 → 19/200 | 7 → 7 | `r_12` |
| 1e | ON：冷启动 evdev repeat 20 次（逐事件 SYN） | **12/200 → 18/200（+6）** | 7 → 7 | `r_10` / `r_11` |
| 1f | 受控对照·OFF（冷启动，逐事件 SYN，同一 burst） | **1/200 → 2/200（+1）** | 4 → 4 | `r_28` / `r_29` |
| 1g | 受控对照·ON（UI 开启后再次冷启动，同一 burst） | **2/200 → 8/200（+6）** | 4 → 4 | `r_31` / `r_32` |
| 1h | 设置行接线 | UI 开 → `checked=true`、prefs `true` | — | `r_09` / `r_30` |

- 1f/1g 为**同参数受控对照**：同一台设备、同一冷启动路径、同一 burst（20 次
  repeat、60ms、逐事件 SYN），唯一变量为 `keyPageOnLongPress`，结果 +1 vs +6，
  证明长按连翻语义在冷启动（原生捕获）路径成立。
- 1e 的 +6（20 次 repeat 中约 6 次触发翻页）与翻页动画节拍一致；基线「聚焦后
  +7」同量级，未见异常。

### 8.3.2 场景 3 细化（菜单 / 子路由）

| 子项 | 操作 | 页号 | 系统音量 | 截图 |
|---|---|---|---|---|
| 3a | 阅读菜单展开 → 音量下键 | 19/200 不变 | **8 → 7**（音量条出现） | `r_08` |
| 3b | 阅读菜单展开（ON 态复测） | 19/200 不变 | **7 → 6** | `r_13` |
| 3c | 目录子页（TOC）→ 音量下键 | 不变（TOC 无页号） | **6 → 5** | `r_14` |
| 3d | TOC 再测（音量条消失后） | 不变 | **3 → 2** | — |
| 3e | 返回阅读器（菜单自动展开）→ 收起菜单 → 音量下键 | **20/200 → 21/200** | **2 → 2** | `r_15` / `r_16` |

> 观测（非本批回归）：从目录返回阅读器时阅读菜单会保持展开，此时音量键仍交还
> 系统（符合「菜单展开 → 交还系统」语义）；收起菜单后翻页恢复。上一版未就此点
> 取证，登记为 P3 观察项，是否调整由产品裁决。

### 8.3.3 场景 4 细化（文本 ↔ 漫画）

| 步骤 | 操作 | 结果 | 截图 |
|---|---|---|---|
| 4a | 书架冷启动打开 `qa1b2a_comic` | 页数 **1/8** | `r_18` |
| 4b | 音量下键（漫画按原版语义逐 keydown 翻页，不区分长按） | **2/8**，音量 1→1 | `r_19` |
| 4c | 退出漫画 → 打开 `qa1b2a_read` | 恢复至 **21/200** | `r_20` |
| 4d | 连续两次音量下键 | **22/200 → 23/200**（每次严格 +1，无双翻页），音量 1→1 | `r_21` / `r_22` |

> 说明：正常 UI 无「文本阅读器未退出即叠入漫画」的入口，设备侧按「文本 → 漫画 →
> 文本」顺序验证捕获归属；`PlatformBridgeService` 租约 owner 栈的叠栈仲裁由本批
> widget 测试（文本→模拟漫画→返回文本 capture 不冲突）覆盖，设备侧未构造叠栈。

### 8.3.4 场景 6 细化（回归）

| 项 | 结果 | 截图 |
|---|---|---|
| 翻页动画 | ON 长按 repeat 连续 6 页无卡死/无 Completer 悬挂 | `r_11` |
| 滑动手势 | 左滑 23→24、右滑 24→23 | `r_23` / `r_24` |
| 点击翻页 | 逐页点击至 20/20 正常 | `r_25` |
| 跨章 | 第1章 20/20 → 第2章 1/20、100% | `r_26` |
| 退出恢复 | 阅读器退出后系统音量键 2→1 | `r_17` |
| OS 健康（本次窗口 7,059 行） | `FATAL EXCEPTION`=**0**、`ANR in io.legado`=**0**、`RenderFlex overflowed`=**0**、`OutOfMemoryError`=**0**、`E/flutter`/未捕获异常=**0** | `logcat/full_session_reverify.log` |

## 8.4 问题分级（本次）

| 级别 | 项 | 证据 | 处置 |
|---|---|---|---|
| **P1（原）** | 冷启动直达文本阅读器音量键不生效、系统音量被改 | 基线 §3.1e | **已关闭**：本次冷启动直接路径 1→2 页 / 音量不变；OFF +1、ON +6 受控对照成立 |
| P3 | 注入方法：`input keyevent --longpress` 不产生 repeat；evdev 不补 SYN 会延迟成批投递 | §8.1.2 注 | 测试方法学约束，非应用缺陷；后续设备任务统一「单键 keyevent、长按 evdev+SYN」 |
| P3 | 从目录返回后阅读菜单保持展开，菜单期间音量键交还系统 | §8.3.2 注 | 与「菜单展开交还系统」语义一致；是否改为返回即收起菜单由产品裁决 |
| P3 | 基线 TTS 朗读门控 BLOCKED（设备无 TTS 引擎） | 基线 §3.4 | 本次未复测，**状态不变（BLOCKED）**；安装 TTS 后需补测 |

## 8.5 结论

- **P1 关闭**：在 `12262dd3e4` 上，冷启动（未聚焦、未文本输入）直达文本阅读器时，
  音量下键由应用消费（页号 +1、系统音量不变）；`keyPageOnLongPress` 开/关在同参数
  长按 burst 下分别 +6 / +1，语义正确；菜单展开与目录子页正确交还系统音量，返回并
  收起菜单后恢复翻页；文本↔漫画顺序切换无双翻页、无音量误拦截；退出后系统音量恢复。
- **本批复验 6/6 场景 PASS**（冷启动、OFF 节流、菜单/子路由、文本↔漫画、退出恢复、
  回归），清理与版本保留 PASS；无新增 P0/P1/P2 缺陷。
- 未验证项（不判 PASS）：① TTS 朗读门控（设备无引擎，沿用 BLOCKED）；② 阅读器
  叠栈（文本未退出即进入漫画）无正常 UI 入口，仅有 widget 测试覆盖；③
  `volumeKeyPage=false` 的设备级不捕获未单独构造（本批 widget 测试覆盖）。

## 8.6 证据路径（回修复验）

- 报告截图：`docs/materials_1101c/reverify/`（`r_01`~`r_33`，33 张）
- 原始证据：`tmp_debug/device_acceptance_20261101_batch1b2a_reverify/`
  - `logcat/build_reverify.log`（`flutter build apk --release` EXIT=0）
  - `logcat/full_session_reverify.log`（7,059 行，健康计数全 0）
  - `shots/`（全部原图，含未入 docs 的注入排查过程图）
  - `xml/`（书架/设置/阅读器/目录/漫画界面 uiautomator dump）
- 关键截图索引：`r_01`~`r_07` 冷启动与 OFF 节流；`r_08`~`r_16` 菜单/子路由；
  `r_17` 退出恢复；`r_18`~`r_22` 漫画与文本往返；`r_23`~`r_26` 回归；`r_27`/`r_33`
  清理后空书架；`r_28`~`r_32` ON/OFF 受控对照。

> 注 4（§8.3 场景 5 引用）：收尾恢复音量时先用 `settings put system
> volume_music_speaker 8` 写入持久值，而 AudioService 内存态仍为 0，二者失同步；
> 随后按键使 AudioService 回写 0（外观上为「8→0」）。已改用音量上键恢复到 8
> （`settings`=8、`dumpsys audio` streamVolume=8）。该现象为 QA 操作副作用，
> 不涉及应用代码。

编写者：QA（ZCode 子代理）｜ 2026-11-01（回修复验）
