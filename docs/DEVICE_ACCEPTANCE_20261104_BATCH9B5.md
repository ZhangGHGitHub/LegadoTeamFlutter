# 设备验收报告：设置批9b-5「耳机媒体键」

- 日期：2026-11-04
- 版本：2.0.449+450（versionCode 450），HEAD `cd3a6a37dc`
- 设备：MuMu「Test测试」`192.168.100.62:5555`，Android 15（API 35），1080x1920 / 480dpi，root 可用
- 安装包：`io.legado.flutter_legado` 2.0.449
- APK sha256：`b1c68408ddf98e1b7800e94f70a1dcb33d57fb18a1026f9a55180c398799e0cf`
  （与仓库 `flutter_legado/build/app/outputs/flutter-apk/app-release.apk` 一致，未重建）
- 环境限制：
  - 本机无 TTS 引擎（`settings get secure tts_default_synth` = null；`pm list packages` 无 TTS 包），按要求未安装第三方 TTS。
  - 无音频书源，仅本地 TXT。
  - `adb shell input keyevent 85/87/88` 在本模拟器上既不进入静态接收器、也不进入 MediaSession（`dumpsys media_session`：`Media button session is null`；logcat 无任何投递记录）。为真实触发 `MediaButtonReceiver.onReceive`，验收期间安装了一个仅用于测试的最小注入 APK（显式向 `io.legado.flutter.MediaButtonReceiver` 发送携带 `EXTRA_KEY_EVENT` 的 `ACTION_MEDIA_BUTTON` 广播），**验收结束后已卸载**；未修改被验收应用代码。

## 结论统计

| 状态 | 数量 | 条目 |
| --- | --- | --- |
| PASS | 8 | 1、2、3、4、6、7、8、9 |
| PASS（含观察项） | 1 | 5 |
| BLOCKED | 1 | 10 |
| FAIL | 0 | — |

- P1：无
- P2：2 项（见下）
- P3：4 项（见下）
- 未闭环项：本地 TXT 书 type 缺 text 位导致媒体键“从最近阅读启动朗读”被过滤；停止朗读后陈旧 MediaSession 抑制静态接收器（无音频环境下按键丢失，需真机 TTS 复验）。

## 逐项结果

### 1. 静态接收器注册 — PASS

证据：
- `dumpsys package io.legado.flutter_legado`：`android.intent.action.MEDIA_BUTTON` → `io.legado.flutter_legado/io.legado.flutter.MediaButtonReceiver`。
- APK manifest（`aapt2 dump xmltree`）：`receiver android:name="io.legado.flutter.MediaButtonReceiver" android:exported=true`，intent-filter 仅 `android.intent.action.MEDIA_BUTTON`，无 priority。
- 会话活跃时 `dumpsys media_session` 显示 `mediaButtonReceiver=...MediaButtonReceiver`，证明系统登记正确。
- 证据文件：`docs/materials_1104c/media_button_evidence.md` 第 1 节。

### 2. 设置入口与持久化 — PASS（入口位置与任务描述不同）

- 实际入口：书架 → 我的 → 设置 → 高级 → 其他设置（对齐原版 `OtherConfigFragment`），**不在「阅读设置」**；文案为「全程响应耳机按键」「耳机按键启动朗读」。
- 两开关存在、可切换；默认值分别 true / false。
- 切换为 onExit=false、readAloud=true 后 `am force-stop` 重启，UI 与 `FlutterSharedPreferences.xml` 均保持（`flutter.mediaButtonOnExit=false`、`flutter.readAloudByMediaButton=true`）。
- 截图：`02_mine.png`、`10_media_switches.png`、`12_media_switches3.png`、`13_switches_toggled.png`、`20_switches_after_restart.png`、`22_switches_after_restart3.png`、`47_onExit_on2.png`、`62_readaloud_off.png`。

### 3. 前台阅读、无播放会话 — PASS

- readAloudByMediaButton=true：
  - 注入 85 → 接收器转发（`转发耳机键到 Flutter（keyCode=85）`），阅读页启动朗读，界面明确提示「未配置可用朗读引擎，将按估算节奏朗读」，无崩溃。
  - 87、88 → `无播放会话，忽略上一首/下一首键`，页面保持 2/6，无异常翻页。
- readAloudByMediaButton=false：
  - 85 → `未开启「耳机按键启动朗读」，且当前无播放，忽略`；87/88 → `无播放会话，忽略上一首/下一首键`；无朗读启动、页面不变（2/6）。
- 截图：`50_reader_85_start.png`、`49_reader_8788.png`、`66_reader_off_keys.png`。
- 说明：无引擎时应用采用“估算节奏”回退并建立会话/前台服务，属既有设计；不是实际发声。

### 4. 后台、无播放会话 — PASS（默认本地书存在数据面缺陷，见 P2-1）

- readAloud=true、mediaButtonOnExit=false：注入 85 → `[耳机按键] 已退出且未开启「全程响应耳机按键」，忽略`；无会话、无 FGS、无通知、应用保持后台。
- readAloud=true、mediaButtonOnExit=true（默认：本地导入 TXT，DB `type=4096` 仅 local 位）：注入 85 → `[耳机按键] 书架无最近阅读的文本，忽略启动朗读`，**未尝试启动**（P2-1）。
- 将测试书 `type` 临时补为 4104（local|text）后同场景：`[耳机按键] 从最近阅读启动朗读：qa_9b5_book`；MediaSession session 6 `PLAYING`，`PlaybackForegroundService` 后台启动成功（`Background started FGS: Allowed ... ACTIVITY_VISIBILITY_GRACE_PERIOD`），应用仍停留桌面（launcher 为 topResumedActivity），无崩溃；无引擎 → 估算节奏回退 + 通知。
- 证据：`media_button_evidence.md` 第 4 节；logcat 片段见 `logcat_final.txt`。

### 5. 阅读器内退出后按键 — PASS（记录到陈旧会话观察项，见 P2-2）

- 退出阅读器后（返回键先到书籍详情页，再返回书架；两个位置都做了按键验证）：
  - mediaButtonOnExit=false、readAloud=false：注入 85 → `未开启「耳机按键启动朗读」…忽略`，无响应。
  - mediaButtonOnExit=true、readAloud=true：注入 85 → `媒体会话活跃，交会话处理（keyCode=85）`，**未尝试拉起**。原因：停止朗读后 `MediaSession` 仍 `active=true`（idle），静态接收器据此不转发；无实际音频时系统亦不把按键路由到会话（`Media button session is null`）。
- 证据：`51_stop_then_85.png`、`52_reader_exit.png`、`media_button_evidence.md` 第 5 节。

### 6. 进程被杀 — PASS

- `am force-stop` 后注入/系统按键：`pidof` 为空、无进程启动、launcher 保持前台、无 FATAL。
- `am kill`（后台进程被杀但未进入 stopped）后注入：系统为广播启动进程并实例化接收器：
  `转发耳机键到 Flutter（keyCode=85）` → `收到耳机键但 Flutter 引擎未就绪，忽略（keyCode=85）`；无崩溃、未拉起 Flutter UI。
- 证据：`media_button_evidence.md` 第 6 节；`39_killed_inject.png`。

### 7. 通知 / 前台服务 — PASS

- 朗读回退会话运行中：仅 1 条 `NotificationRecord`（id=7776，channel `legado_playback_foreground`），`PlaybackForegroundService isForeground=true foregroundId=7776`；无重复通知。
- 停止朗读后：NotificationRecord 0 条、PlaybackForegroundService 0 个。
- `am force-stop` 后：进程 0、会话 0、通知 0、服务 0。
- 证据：`media_button_evidence.md` 第 7 节。

### 8. 快速连按去抖 — PASS

- 1 秒内 5×85（间隔 150ms）：接收器 5 次转发；Dart 侧第 1/3/5 次进入决策、第 2/4 次命中 `去抖窗口内重复事件（HeadsetMediaKey.toggle）`；无 FATAL、无会话残留（media_session 0、FGS 0）。
- 说明：去抖窗口 250ms 且以“上次处理时间”为基准，150ms 间隔会呈现“处理-忽略-处理”交替（P3-2）。
- 证据：`media_button_evidence.md` 第 8 节。

### 9. 回归 — PASS

- 阅读翻页（2/6→3/6→返回）、目录（3 章、当前章定位）、切章（第一章/第二章/第三章）、阅读器朗读入口（无引擎提示「未配置可用朗读引擎，将按估算节奏朗读」）、阅读器退出回书架均正常。
- 统计（最终 logcat 775 行 + 回归阶段单独缓冲）：`FATAL EXCEPTION` 0、`ANR in io.legado` 0、`E/flutter` 0、`RenderFlex overflowed` 0；今日 dropbox 无 legado 崩溃记录。
- 截图：`67_regression_reader.png`、`68_page_next.png`、`70_toc.png`、`71_chapter2.png`、`75_readaloud_ui_entry.png`、`77_regression_toc.png`、`78_regression_readaloud.png`、`79_regression_end.png`。

### 10. TTS 实际播放/暂停、切段、流媒体切章、会话保留 — BLOCKED

- 依据：
  - 无 TTS 引擎（`tts_default_synth=null`，无 TTS 包）→ 无实际音频；
  - 无音频书源 → 无法验证流媒体切章；
  - 无音频时 `dumpsys media_session` 的 `Media button session` 为 null，`input keyevent` / `cmd media_session dispatch` 均无法驱动会话或静态接收器；
  - 应用只能进入“估算节奏”回退（界面提示），不能证明真实 TTS 播放/暂停、上一/下一首切段与 MediaSession 音频延续。
- 未伪造 PASS；需在有 TTS 引擎的真机上补测。

## 问题清单

### P1
无。

### P2
1. **本地导入 TXT 的 `book.type` 缺少 text 位，导致媒体键“从最近阅读启动朗读”被过滤**
   - 复现：导入本地 TXT（DB `books.type=4096`，仅 `local`）→ 开启「耳机按键启动朗读」→ 退到后台按媒体键 85。
   - 期望：从最近阅读书启动朗读（无引擎时应安全回退/提示）。
   - 实际：`[耳机按键] 书架无最近阅读的文本，忽略启动朗读`，不启动。
   - 定位：`lib/src/services/headset_media_button_service.dart` `_startFromLastReadBook` 过滤 `(book.bookType & BookType.text) != 0`；本地导入记录缺该位（原版本地书为 `text|local`）。
   - 验证：临时将 `type` 改为 4104 后，同场景日志变为 `从最近阅读启动朗读：qa_9b5_book`，后台启动成功。
   - 影响：本地 TXT 用户（常见场景）媒体键启动朗读失效。

2. **停止朗读后陈旧 MediaSession 抑制静态接收器，无音频环境下媒体键丢失（待真机复验）**
   - 复现：阅读器内媒体键/按钮启动朗读 → 点停止 → 再按媒体键。
   - 期望（决策表）：无播放会话 + readAloud=true + 阅读页前台 → 重新启动朗读。
   - 实际：`MediaSession active=true`（idle）→ 接收器 `媒体会话活跃，交会话处理（keyCode=85）`；因 `Media button session is null`，按键未到达会话回调，朗读不重启。
   - 定位线索：`AudioNotifier.stop()` 不释放会话；`MediaButtonReceiver.handleIntent` 仅判断 `hasActiveSession()`（未区分会话是否在播放）；退出阅读器亦不触发 `releaseMediaSession`（仅听书页 dispose / 后台生命周期）。
   - 风险：真机有 TTS 时，停止后系统可能仍将会话保留为媒体键目标，行为需复验；若同样丢失则升级为 P2 确认缺陷。

### P3
1. 设置入口实际位于「设置 → 高级 → 其他设置」，与任务描述的「阅读设置」不同（对齐原版，非缺陷，文档需同步）。
2. 去抖以“上次处理时间”为基准（250ms），150ms 间隔连按会放行第 1/3/5 次；本次均为忽略分支无副作用，启动场景可能出现多次决策（其余被会话抑制）。
3. 无 TTS 引擎时进入“估算节奏”回退并创建 MediaSession/前台服务/通知，属设计内行为，验收时需避免误认为真实朗读。
4. 本模拟器无音频时系统媒体键不会投递到静态接收器或会话（`Media button session is null`），系统级耳机键真实路径需真机复验。

## logcat 统计

| 指标 | 结果 |
| --- | --- |
| 最终缓冲行数 | 775 |
| FATAL EXCEPTION | 0 |
| ANR in io.legado | 0 |
| E/flutter | 0 |
| RenderFlex overflowed | 0 |
| 今日 dropbox legado 崩溃 | 0 |
| 允许的无引擎提示 | 「未配置可用朗读引擎，将按估算节奏朗读」 |

证据：`docs/materials_1104c/logcat_final.txt`、`docs/materials_1104c/logcat_regression.txt`、`docs/materials_1104c/media_button_evidence.md`。

## 设备清理与终态

- 书架：空（测试书 `qa_9b5_book` 已从 DB 删除 `books/chapters/readRecord` 对应记录，截图 `81_final_shelf.png`）。
- 文件：`/sdcard/Download/qa_9b5_book.txt`、`cache/file_picker/...`、`files/external_import/...` 已删除。
- 测试注入器：`io.legado.qa.mediakey` 已卸载。
- 设置恢复默认：`flutter.readAloudByMediaButton=false`、`flutter.mediaButtonOnExit=true`（误触的「默认启用替换净化」已恢复 ON）。
- 设备参数：font_scale 1.0、accelerometer_rotation 1、user_rotation 0、1080x1920/480dpi（与验收前一致）。
- 应用：2.0.449 保持安装并运行在书架页。

## 证据目录

`docs/materials_1104c/`
- 截图：`01_start.png` … `81_final_shelf.png`（关键：`12/13/20/22/47/62` 设置；`49/50/66` 前台；`51/52` 退出/陈旧会话；`39` 进程被杀；`67-79` 回归；`81` 终态）。
- 日志：`logcat_final.txt`、`logcat_regression.txt`、`media_button_evidence.md`。
