# 设备验收报告 — 批18「两线合并」（备份/恢复遗留三项 + TTS 体验四项 + MCP 令牌）

- 日期：2026-11-11
- 设备：MuMu 实例「Test测试」`192.168.100.62:5555`（SM-G9900 / Android 15 / SDK 35 / 1080x1920 / 480dpi）
- APK：`2.0.488+489`（versionName=2.0.488，versionCode=489）
  - 安装包 SHA-256 实测：`ace77250126ddf9b968fb608ffc8a29de69fe19d040659e8ad0f30c5cd6bcba2`（与任务给定值一致）
- 宿主：Windows，`192.168.100.52`；WsgiDAV 4.4.0（`0.0.0.0:8090`，anonymous）
- 测试书：`tmp_qb17_book`（3 章 TXT，本机导入）
- 截图/日志目录：`docs/materials_1111d/`

## 一、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 14 |
| FAIL | 1（B9） |
| BLOCKED（清单项） | 0 |

**结论：15 项验收中 14 项通过，1 项失败。** 失败项为 B9「停止朗读后媒体会话应无记录」：停止后 `dumpsys media_session` 仍保留一条新的 `legado_flutter_media` 会话记录（`active=true`、`state=null`，每次停止会话 id 递增），可稳定复现 4 次。其余备份/恢复、同步书库守卫、临时目录清扫、TTS 面板/持久化、MCP 令牌、稳定性与设备终态均符合预期。

> 环境限制单独说明：MuMu 无系统 TTS 引擎，**实际发声（合成/音频输出）无法验证，按约定记 BLOCKED（环境）**；本批清单中的引擎空态、滑条持久化、媒体会话生命周期均可测，未用环境限制豁免 B9。

## 二、逐项验收

### A. 备份/恢复（线1）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 配置 WebDAV（`http://192.168.100.52:8090/`，子目录 `/legado/`）→ 连接成功 | PASS | `tmp_qb18_05.png`；`wsgidav_b18.log` | 账号/密码填 `admin`，测试配置行显示「✓ 连接成功」+ SnackBar「连接成功」；宿主日志 `PROPFIND / … 207 Multi-Status` |
| 2 | 备份 →「备份至本地与网络」→ 成功，本地与服务器各新增文件 | PASS | `tmp_qb18_06.png`、`tmp_qb18_07.png`；`wsgidav_b18.log` | 先弹出 SAF 选择备份路径（选 `Download/legado_backup`）后自动继续；SnackBar：「备份成功：/storage/emulated/0/Download/legado_backup/legado_backup_1794384452536.json \| 已上传 WebDAV：backup_20261111_160732_544.json」。本地文件 3,772 B；服务器同名文件 3,772 B；宿主 `PUT /legado/backup_20261111_160732_544.json … 201 Created` |
| 3 | 恢复 →「网络恢复」→ 最新备份 → 确认覆盖 →「恢复成功」 | PASS | `tmp_qb18_08.png`、`tmp_qb18_09.png`、`tmp_qb18_11.png`；`wsgidav_b18.log` | 列表首项即最新备份（2026-11-11 16:07）；确认文案含「将下载远端备份…并覆盖本地书架」；点「恢复」后 SnackBar「恢复成功」；宿主 `GET /legado/backup_20261111_160732_544.json … 200 OK`。重复执行两次均成功；恢复后书架书籍仍在（`tmp_qb18_14.png`）。本次备份为 JSON（无密码 zip），验证的是密码 zip 之外的主路径，未回归 |
| 4 | 清空账号/密码只留地址 → ⋮ →「同步书库（合并）」→ 提示且不发请求 | PASS | `tmp_qb18_12.png`、`tmp_qb18_13.png`；`wsgidav_b18.log` | 账号/密码清空后 URL 保持；点菜单「同步书库（合并）」立即提示「同步书库需要账号密码，请先在 WebDAV 设置中填写」；宿主日志操作前后均为 23 行，最后一条请求仍是 16:08:36 的恢复 GET，16:09 之后无任何新请求 |
| 5 | 临时目录清扫（制造 `legado_webdav_only_test`，mtime 2 小时前，重启后清理） | PASS（路径口径修正，见 P3-1） | `a5_temp_cleanup_transcript.txt` | 任务给的 `/cache` 不是本 App 的 `Directory.systemTemp`；实际为 `/data/data/io.legado.flutter_legado/code_cache`（Flutter `PathUtils.getCacheDirectory()`→`getCodeCacheDir()`，`switches.cc` 将 `--cache-dir-path` 赋给 `temp_directory_path`）。在 `code_cache` 创建 `legado_webdav_only_test`（14:00）与 `legado_webdav_restore_test2`（14:00），另建 16:16 的 `legado_webdav_only_fresh` 对照；`am force-stop` + 冷启动 8 s 后两条旧目录均被删除，仅 16:16 对照目录保留。`cache` 下的同名旧目录未删（不在 systemTemp 范围），最终随 `pm clear` 清除 |

### B. TTS（线2，MuMu 无 TTS 引擎）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 6 | 阅读器菜单 → 朗读 → 听书页：面板出现「朗读引擎」行，点击显示空态 | PASS（含 P3-2 说明） | `tmp_qb18_16.png`、`tmp_qb18_21.png`、`tmp_qb18_22.png`、`tmp_qb18_32.png` | 默认（内置 3 个 HTTP 引擎）时，听书页设置面板「朗读引擎」行副标题为「系统 TTS（未检测到可用引擎）」，点开选择面板列出「系统默认」+ 3 个 HTTP 引擎；为验证全空态，临时删除 `httpTTS` 三条记录并重启，行副标题变为「未检测到可用语音引擎」，该行置灰不可点（实现即如此），无崩溃。听书页同时显示红色警示「未配置可用朗读引擎，将按估算节奏朗读」。上述 HTTP 引擎删除仅为测试数据，最终 `pm clear` 已清除 |
| 7 | 音调/音量滑条拖动 → 退出重进 → 值保持 | PASS | `tmp_qb18_24.png`、`tmp_qb18_28.png`、`tmp_qb18_32.png` | 音调拖到 `1.8`、音量拖到 `60%`；退出听书页再进（`tmp_qb18_28.png`）仍为 1.8 / 60%；应用 force-stop 冷启动后（`tmp_qb18_32.png`）仍为 1.8 / 60% |
| 8 | 语速滑条拖动 → 退出重进 → 保持；朗读条「跟随系统」标签与实际值一致 | PASS | `tmp_qb18_16.png`、`tmp_qb18_25.png`、`tmp_qb18_28.png`、`tmp_qb18_32.png` | 初始朗读条「语速:跟随系统」，实际显示 `1.0x`（无引擎时引擎默认 1.0，标签与值一致）；切到「语速:手动」后拖到 `1.7x`，退出重进仍 `1.7x`，冷启动后仍 `1.7x`，标签保持「语速:手动」 |
| 9 | 停止朗读 → `dumpsys media_session \| grep -i legado` → 应无输出 | **FAIL** | `mediasession_b9_after_stop.txt`、`mediasession_b9_full_dump.txt`、`logcat_b18.txt` | 停止后仍有 1 条 `legado_flutter_media io.legado.flutter_legado/legado_flutter_media/<id>` 记录；完整 dump：`active=true`、`controllers: 1`、`state=null`、`metadata: null`。重复停止 4 次，id 依次 9→10→11→14（每次停止都是「销毁旧会话 + 新建空会话」）。原生日志同一毫秒：`destroySessionLocked: record=…/8` → `addSession to bottom of stack | record=…/9` → `onSessionActiveStateChanged: record=…/9 playbackState=null`。详见第四节 P2-1 |
| 10 | 播放中退出听书页 → 仍有媒体会话记录（会话保留） | PASS | `mediasession_b10_playing_back.txt`、`tmp_qb18_29.png` | 播放中按 Back 离开听书页后，`dumpsys` 仍有 `legado_flutter_media … /13`，阅读器朗读条继续「正在朗读」，符合 `mediaButtonOnExit=true` 的保留语义 |
| 11 | 退出阅读器 → logcat 不应再有 `Bad state: Cannot use "ref" after the widget was disposed` | PASS | `logcat_b18.txt` | 退出阅读器前后 `grep -c` 均为 **0**；全会话 13,320 行日志中该模式计数 0 |

### C. MCP 令牌（线2 文档回销，确认未回归）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 12 | 开启 Web 服务 → `curl /mcp/call -d '{}'` → 未配置令牌被拒 | PASS | `mcp_c12_c13_transcript.txt` | HTTP 200，失败信封：`{"isSuccess":false,"errorMsg":"Web 书源访问令牌未配置或不正确","data":null}`（content-length 88） |
| 13 | `curl /mcp/tools` → 免令牌可访问 | PASS | `mcp_c12_c13_transcript.txt` | HTTP 200，`application/json`，content-length 6173，返回 20 个工具（`search_books`…`read_help_doc`） |

### D. 稳定性

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 14 | logcat 五项崩溃计数须为 0 | PASS | `logcat_b18.txt`（13,320 行） | `FATAL EXCEPTION=0`、`ANR in=0`、`E/flutter=0`、`overflowed=0`、`E AndroidRuntime=0`；另 `OutOfMemory=0`。另见 123 条 `Fatal signal` 均为 `uiautomator` 进程 Shutdown thread（测试工具，见 P3-3），含 `legado` 的 0 条 |
| 15 | 关闭 Web 服务、停止 wsgidav、`pm clear` 清理 + 截图终态 | PASS | `tmp_qb18_34.png`、`tmp_qb18_35.png` | Web 服务行恢复副标题「用浏览器写源或看书」，宿主 `curl :1122` 返回 `000`（拒绝连接）；wsgidav PID 112836 已终止，`netstat` 无 8090 监听；`pm clear` 返回 `Success`，应用数据目录已不存在；前台为 `com.microsoft.launcher/.Launcher`，截图 `tmp_qb18_35.png` |

## 三、问题分级

### P2-1（真实缺陷，本项验收失败）停止朗读后残留「空媒体会话」

- 现象：停止朗读后 `dumpsys media_session | grep -i legado` 仍有 1 条记录，且不是旧的 STOPPED 记录，而是**新建的空会话**（`active=true`、`state=null`、`metadata=null`、`controllers=1`）。
- 复现步骤：
  1. 打开书 → 菜单 →「朗读」（默认朗读界面=播放器）→ 确认「正在朗读」；
  2. 返回阅读器 → 点「停止朗读」；
  3. 等待 ≥15 s → `adb shell dumpsys media_session | grep -i legado`。
- 期望：无输出（停止即释放会话）。
- 实际：仍有 1 条 `legado_flutter_media` 记录；重复停止 4 次，会话 id 递增（9→10→11→14）。原生日志已捕获一次完整的「销毁旧会话 + 新建空会话」同毫秒序列（8→9），后续停止仅见新 id，形态一致。
- 证据：`docs/materials_1111d/mediasession_b9_after_stop.txt`、`mediasession_b9_full_dump.txt`；`logcat_b18.txt` 中 16:22:51.349–.353 的 destroy/add 日志。
- 影响：停止后系统仍登记一个无控制价值的空媒体会话（可能出现在系统媒体控制/媒体键路由中）；不崩溃、不影响其他验收项。
- 定位线索（未改代码，供开发确认）：`AudioNotifier.stop()` 在 `releaseMediaSession(force: true)` 之前有 `notifyListeners()` / 状态复位；原生 `release` 销毁旧会话的同一毫秒内出现新会话，提示释放后仍有在途 `_syncMediaSession`/`initMediaSession` 重建空会话。建议重点排查 `audio_notifier.dart` 的 `stop()`（2119–2160）、`_syncMediaSession()`（约 1520–1536）与播放启动路径的时序竞争。
- 分级依据：非崩溃、无数据丢失、可绕过，但与本批明确验收口径（停止后应无记录）冲突，且改变上一批 P3-2 的 STOPPED 形态为「空 active 会话」，按 P2 记录。

### P3-1（测试口径/文档偏差，非产品缺陷）A5 的临时目录不是 `/cache`

- 任务要求检查 `/data/data/io.legado.flutter_legado/cache`，但本 App 的 `Directory.systemTemp` 实际为 `code_cache`：
  - Flutter `PathUtils.getCacheDirectory()` 使用 `applicationContext.getCodeCacheDir()`，源码注释明确该路径用于设置 `dart:io Directory.systemTemp`；
  - engine `switches.cc` 将 `--cache-dir-path` 赋给 `settings.temp_directory_path`，FlutterLoader 传入 `--cache-dir-path=<engineCachesPath>`。
- 我们在 `cache` 与 `code_cache` 两处都做了对照：`cache` 下的旧目录不会被清扫（不在范围），`code_cache` 下的旧目录被正确清除。产品行为 PASS；建议后续验收文档把路径写成 `code_cache`。

### P3-2（观察项）B6「点击显示空态」的字面语义

- 默认安装会内置 3 个 HTTP 朗读引擎，因此「系统 TTS 引擎为空 + HTTP 引擎为空」的全空态默认不可达；默认状态下行为为「朗读引擎」行副标题「系统 TTS（未检测到可用引擎）」，点开选择面板列出 HTTP 引擎（正常）。
- 为验证全空态，测试中临时删除 `httpTTS` 三条记录并重启；此时行副标题为「未检测到可用语音引擎」，行置灰不可点（`clickable=false`），空态直接显示在行内，不存在「点击后才显示空态」的交互；无崩溃。删除仅作用于测试数据，最终 `pm clear` 已清除。
- 判定：符合实现设计，不构成缺陷；仅记录验收文案与实际交互的差异。

### P3-3（测试工具噪声）123 条 `Fatal signal` 均来自 uiautomator

- `logcat_b18.txt` 中 `Fatal signal` 共 123 条，逐条上下文均为 `uiautomator` 进程（`AndroidRuntime: Shutting down VM` 后的 `Shutdown thread`），包含 `legado` 关键字的 0 条；与历史批次的 uiautomator 噪声同源，不计入应用崩溃。

### 环境限制（BLOCKED，不计入清单失败）

- MuMu 实例无系统 TTS 引擎：`dumpsys`/界面提示「未配置可用朗读引擎，将按估算节奏朗读」，实际语音合成与音频输出无法验证，按约定记 BLOCKED（环境）。本批 B6–B8 验证的是引擎空态、滑条持久化与标签一致性，不依赖实际发声；B9/B10 验证媒体会话生命周期，亦不依赖 TTS 引擎。

## 四、设备终态

- Web 服务：已关闭（`/mcp/tools` 连接失败 `000`），入口副标题恢复「用浏览器写源或看书」；
- 宿主 WsgiDAV：进程已终止（PID 112836），8090 无监听；
- 应用数据：`pm clear io.legado.flutter_legado` 返回 `Success`，`/data/data/io.legado.flutter_legado` 已不存在（含 `cache`/`code_cache` 下全部测试目录）；
- 前台：`com.microsoft.launcher/.Launcher`；
- 终态截图：`docs/materials_1111d/tmp_qb18_35.png`。

## 五、门禁引用

- `AGENTS.md` 设备验证约定：第 65 行「每轮修复后的两级验证：子代理先在测试档模拟器测试…」；第 68 行「测试与用户实测验收统一使用 MuMu「Test测试」实例」；第 79 行「子代理自述（无独立证据）不构成验收依据」。
- 崩溃计数口径沿用批11–批16 设备验收的「五项」：`FATAL EXCEPTION` / `ANR in` / `E/flutter` / `overflowed` / `E AndroidRuntime`（见 `docs/DEVICE_ACCEPTANCE_20261110_BATCH11.md` 等）。
- B9 的会话基线参考 `docs/DEVICE_ACCEPTANCE_20261111_BATCH9B5C.md`（上一批记录「停止后残留 STOPPED 会话」为 P3-2；本批 P3 修复后验收要求「停止后无记录」）。

## 六、证据清单（`docs/materials_1111d/`）

| 文件 | 用途 |
| --- | --- |
| `tmp_qb18_01.png` … `tmp_qb18_35.png` | 逐项截图（05 连接成功；07 备份成功；08/09/11 网络恢复；13 同步书库守卫；16/21/22/32 TTS 引擎；24/25/28 滑条与标签；29/30 会话；34 关闭 Web 服务；35 终态） |
| `logcat_b18.txt` | 全流程 13,320 行；五项计数、ref disposed、Fatal signal 来源 |
| `wsgidav_b18.log` | 宿主 WebDAV 全量请求日志（PROPFIND/PUT/GET） |
| `mediasession_b10_playing_back.txt` | B10：播放中退出听书页后仍有会话 |
| `mediasession_b9_after_stop.txt` | B9：停止后仍有 1 条 legado 会话 |
| `mediasession_b9_full_dump.txt` | B9：完整 dump（active=true / state=null / controllers=1） |
| `a5_temp_cleanup_transcript.txt` | A5：`cache` 对照 + `code_cache` 实际清扫的命令/输出转录 |
| `mcp_c12_c13_transcript.txt` | C12/C13：`/mcp/call` 失败信封与 `/mcp/tools` 200/20 工具 |

## 九、回修与复验

- 日期：2026-11-11
- 版本：`2.0.488+489`（按任务要求不 bump 版本；同 versionCode 覆盖安装，`versionName=2.0.488` / `versionCode=489`）
- 回修 APK：`flutter build apk --release`（`LEGADO_SKIP_RUST_BUILD=1`，未改 Rust/FFI）退出码 0，210,933,032 B，sha256 `6f9febcc66f012d9476cfcea5bc9fb3f3b47e21b4ff4a2c99636f9659a26a5b1`
- 设备：MuMu「Test测试」`192.168.100.62:5555`，Android 15 / 1080x1920 / 480dpi
- 测试书：`tmp_qb15_book.txt`（19,486 B，3 章；`adb push` 后经书架「更多 → 添加本地」导入）
- 默认朗读界面：播放器（设置 → 朗读设置 → 常规 → 默认朗读界面）

### 9.1 根因定位（P2-1）

「空媒体会话」不是 `release` 本身清理失败，而是 `stop()` 的后续步骤把会话重新建了回来：

1. `stop()` 先 `releaseMediaSession(force: true)`，`AudioService.dispose()` 已在 await 之前把 `_initialized=false` 并释放原生会话；
2. 紧接着 `stop()` 执行 `unawaited(_releaseReadAloudWakeLock())`；
3. 旧 `AudioService.setWakeLock(false)` 只要 `_initialized == false` 就 `await init()`，于是释放完成后立即重新 `init` 原生 MediaSession；
4. 新会话尚未发布 playbackState，表现为 `active=true` / `state=null` / `metadata=null`，与会话日志 `destroySessionLocked(8)` → 同毫秒 `addSession(9)` 完全吻合。

### 9.2 修复内容

- `AudioService.setWakeLock`：仅 `enabled=true` 且未初始化时才 `init()`；`enabled=false` 且无会话直接返回，关闭唤醒锁不再创建会话。
- `AudioNotifier._releaseReadAloudWakeLock` / `_applyReadAloudWakeLock` / `setWakeLockEnabled`：`_audioService.isInitialized == false` 时跳过唤醒锁调用，杜绝 release 后重建。
- `AudioNotifier._syncMediaSession`：空闲态直接返回；入口快照 `_mediaSessionReleaseEpoch`，`initMediaSession`、焦点请求、元数据、`notifyPlaying`、持锁等每个 await 之后复检，释放/停止发生后立即中止。
- `AudioScreen` 首帧初始化回调补 `mounted` 门闩，快速进出页面不再在 dispose 后初始化会话。
- 测试：
  - `test/unit/audio_service_serialization_test.dart` 新增「释放会话后 `setWakeLock(false)` 不得自动 init」；
  - `test/unit/headset_media_button_service_test.dart` 新增「stop 后 `debugSyncMediaSession` + 播放完成回调 → `init` 调用 0 次、会话保持已释放」；
  - 原 2 个 init/release 串行化竞态用例保持通过。

### 9.3 设备复验（按原 B9 路径停止 4 次）

每轮操作：阅读器菜单 → 耳机图标「朗读」→ 进入播放器 → 返回阅读器 → 点朗读条「停止朗读」→ 等待 ≥15 s → `dumpsys media_session`。

| 轮次 | 停止前会话 id | 停止后 `dumpsys \| grep -i legado` | 停止后会话数 | 截图 |
| --- | --- | --- | --- | --- |
| 1 | 16 | 0 字节 | 0 | `tmp_qb18_fix_03.png` |
| 2 | 17 | 0 字节 | 0 | `tmp_qb18_fix_04.png` |
| 3 | 18 | 0 字节 | 0 | `tmp_qb18_fix_05.png` |
| 4 | 19 | 0 字节 | 0 | `tmp_qb18_fix_06.png` |

- **结果：4/4 PASS**。停止后 `dumpsys media_session` 均无任何 `legado_flutter_media` 记录，完整 dump 中 `Sessions Stack - have 0 sessions`。
- 修复前每轮停止均为「销毁旧会话 + 同毫秒新建空会话」；本轮日志每轮仅见 `destroySessionLocked`，之后无新增 `addSession`（最后一条：`16:52:01.206 destroySessionLocked …/19`）。
- 证据文件：`mediasession_b18fix_after_stop1..4.txt`、`mediasession_b18fix_after_stop1_full.txt`、`mediasession_b18fix_after_stop4_full.txt`、`logcat_b18fix.txt`、`tmp_qb18_fix_01..06.png`（01 播放器播放中、02 返回阅读器朗读条、03–06 四轮停止后）。

### 9.4 门禁

- `flutter analyze`：0 issues
- `flutter test`（全量）：5628 通过 + 1 跳过，exit 0
- `dart format --output=none --set-exit-if-changed` 本批 Dart 文件：0 changed
- 未改 Kotlin/Rust/FFI；未 bump 版本；未改 ACTIVE_PLAN；未触碰备份/恢复线文件
