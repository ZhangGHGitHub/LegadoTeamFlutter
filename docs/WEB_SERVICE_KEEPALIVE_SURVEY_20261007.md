# Web 服务后台保活机制调研（原版 Android 基线 → iOS 方案设计）

- 日期：2026-10-07
- 调研方式：Windows 本机静态分析（只读），未操作设备
- 背景：我方 Web 服务已绑 `0.0.0.0`、iOS 实机局域网可达（`docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md` 缺陷 A/B 修复后）；但 iOS 切后台进程挂起、监听 socket 停止服务（用户实测 Safari 打不开）。用户指示：先看原版怎么做，再定 iOS 方案。

---

## 一、结论摘要

1. **原版 Android 的「一直可用」由三层叠成**：前台服务（系统不死 + 常驻通知展示地址）+ 可选 WakeLock/WifiLock（防 CPU/Wi-Fi 睡眠，默认关）+ NetworkChangedListener（IP 变化时刷新通知与 hostAddress）。
2. **原版没有开机自启、没有应用启动自拉起**：`webService` 偏好只是 UI 镜像运行状态，服务完全靠用户手动开；用户从最近任务划掉 App 时服务**主动自杀**（`onTaskRemoved → stopSelf`）。
3. **`serve()` 续锁机制**：每个 HTTP 请求 / WebSocket 握手都会重发 start intent 重新 acquire 锁——开了 WakeLock 后锁的实际有效期是「最后一次请求之后无限期」（无超时 acquire）。
4. **iOS 无前台服务概念**，原版三层中可平移的只有「防挂起」这一目的 → 对应物是 `UIBackgroundModes: audio` + 静音播放（方案 C），我方该基础设施已就绪但未用于 Web 服务。
5. **推荐：方案 C（静音音频保活）+ 方案 A（UI 明示）兜底**。自用签名无上架审核风险；核心机制（audio 后台模式、playback 会话、NowPlayingBridge）已存在，工作量集中在「退后台启静音循环、回前台即停」的接线。所有时长/系统行为均为经验值，须按 §五真机实测。

---

## 二、原版保活机制五要素（file:line 证据）

基线文件：`app/src/main/java/io/legado/app/service/WebService.kt`（下称 WS）；`app/src/main/java/io/legado/app/base/BaseService.kt`（下称 BS）。

### 1. 前台服务

- **类型**：`WebService : BaseService`（WS:42），Manifest 声明 `android:foregroundServiceType="dataSync"`（`app/src/main/AndroidManifest.xml:521-523`）。Android 15 起 dataSync 有 6 小时限额，超时走 `onTimeout → stopSelf`（BS:85-89）。
- **startForeground 时机**：`BaseService.onStartCommand`（BS:52-64）——`isForeground` 为假即调 `tryStartForegroundNotification()`（BS:132-146，失败且属 FGS-start-denied 则 `stopSelfResult` 并返回 `START_NOT_STICKY`，BS:58-59）。WS 覆写 `startForegroundNotification()`（WS:254-257）→ `startForeground(NotificationId.WebService, ...)`。即**首次 start intent 一到就转前台，先于服务器启动**（`upWebServer()` 在 WS:148 之后才跑）。
- **返回值语义**：正常路径 `super.onStartCommand`（BS:63）；`LifecycleService` 未改写返回值，落到 `android.app.Service` 默认 **START_STICKY**（SDK 既定行为）；仅前台启动被拒分支显式 `START_NOT_STICKY`（BS:59）。
- **通知内容**（`createNotification`，WS:259-295）：渠道 `AppConst.channelIdWeb`、`VISIBILITY_PUBLIC`、`setOngoing(!terminal)`；标题「Web已开启」（`values-zh/strings.xml:300`）；正文为 `notificationList` 逐行拼接——每行 `http://<ip>:<port>`（格式串 `http_ip` = `http://%1$s:%2$d`，`values/non_translat.xml:9`；端口取 `PreferKey.webPort`，越界回退 1122，WS:243-249）。点通知复制地址（action `copyHostAddress`，WS:138、269-271），带「取消」action（WS:285-290）。
- **onDestroy**（WS:154-169）：取消终态任务、置 stopping、释放锁、注销网络监听、停 HTTP/WS 服务器、清 hostAddress、发空 `EventBus.WEB_SERVICE`、更新快捷磁贴。
- **onTaskRemoved**（BS:67-71）：**`stopSelf()`**——用户划掉任务卡即停服务，原版不做挣扎。
- **正常停止**（`stopServiceWithNotification`，WS:171-191）：停服务器后仍以前台形态展示 4.5s 终态通知（`TERMINAL_NOTIFICATION_DURATION`，WS:45）再 `stopSelf`。

### 2. WakeLock（可选项，默认关）

- **语义与默认值**：`useWakeLock = getPrefBoolean(PreferKey.webServiceWakeLock, false)`（WS:76）——**默认 false**。设置项文案（`values/strings.xml:1365-1366`）：「wake-up lock is enabled when the web service is enabled, and some phones will be killed when the wake-up lock is enabled」；键 `PreferKey.webServiceWakeLock`（`constant/PreferKey.kt:186`），纳入备份键表（`help/storage/BackupConfig.kt:112`）。
- **锁类型与持有**：`PARTIAL_WAKE_LOCK "legado:WebService"` + `setReferenceCounted(false)`（WS:77-82）；WifiLock `WIFI_MODE_FULL_HIGH_PERF "legado:WebService"`（WS:83-89，仅部分机型 wifiManager 为空则无）。**`acquire()` 无超时**（`@SuppressLint("WakelockTimeout")`，WS:100-107）。
- **获取时机**：`onCreate`（WS:104-107）与 `onStartCommand` action=="serve"（WS:139-142）。
- **serve() 续锁链**：`HttpServer.serve()` 每个请求（`web/HttpServer.kt:30`）与 `WebSocketServer.openWebSocket` 每次握手（`web/WebSocketServer.kt:34`）都调 `WebService.serve()`（WS:69-73）→ 重发 start intent → 重新 acquire。效果：只要还有一个请求进来过，锁就一直持有到 onDestroy。
- **释放时机**：仅 `onDestroy`（WS:159-162）。

### 3. 网络变化（只刷新地址，不重绑）

- `NetworkChangedListener`（`receiver/NetworkChangedListener.kt`）：API 24+ 走 `registerDefaultNetworkCallback`（:57-60），`onAvailable` 即触发回调（:35-37）；旧版本走 `CONNECTIVITY_ACTION` 广播（:80-91）。
- WS.onCreate 注册（WS:110），回调（WS:111-131）：重新枚举 `NetworkUtils.getLocalIPAddress()` → 重建 notificationList（每个 IPv4 一行 `http://ip:port`）→ `hostAddress = notificationList.first()` → 重发前台通知 → postEvent。**不重启服务器**——服务器绑 0.0.0.0 全接口，IP 变化不需要重绑，只需刷新展示。

### 4. 持久化与自启

- 开关：`PreferKey.webService`（`constant/PreferKey.kt:74`）。UI 在「我的」页（`ui/main/my/MyFragment.kt`）：变更回调（:161-167）开 → `WebService.start(context)`、关 → `WebService.stop(context)`。
- **webService 偏好不是自启开关**：`MyPreferenceFragment.onCreatePreferences` 里 `putPrefBoolean(PreferKey.webService, WebService.isRun)`（MyFragment:85）——它只是把「当前是否在跑」写进偏好供 UI 恢复显示。全库 grep `PreferKey.webService` 消费点仅 MyFragment 三处，**未找到任何 Application/Activity 启动时依据该偏好自动拉起 WebService 的代码**。
- **无开机自启**：Manifest 声明了 `RECEIVE_BOOT_COMPLETED`（AndroidManifest.xml:7），但 grep 全源码**未找到 BOOT_COMPLETED 的 receiver**（唯一 receiver 是耳机键 `MediaButtonReceiver`，AndroidManifest.xml:565-571）；该权限在 Web 服务维度无消费者。Android 13+ 新增的 `WebTileService`（快捷磁贴，AndroidManifest.xml:529-533、`service/WebTileService.kt:62,74`）也只是手动拉起入口。
- `onStartCommand` intent 语义（WS:135-152）：`IntentAction.stop` → 终态停机；`copyHostAddress` → 复制地址；`serve` → 续锁；**null/其他（即 `WebService.start`/`startForeground` 的普通 start）→ 取消终态任务 + `upWebServer()` 启动/重启服务器**。

### 5. 地址展示

- 计算：`NetworkUtils.getLocalIPAddress()`（`utils/NetworkUtils.kt:245-267`）——枚举 `NetworkInterface` 全部非回环 IPv4，**不做多网卡择优，全部列出**；`hostAddress` 取通知列表第一条（WS:123、228）。
- 展示位置（四处）：前台通知正文（WS:268）；「我的」页 Web 服务开关 summary——`observeEventSticky(WEB_SERVICE)` 把 `WebService.hostAddress` 写进 summary（MyFragment:101-110）；点通知复制（WS:138）；长按开关弹「复制地址 / 浏览器打开」（MyFragment:88-96）。

---

## 三、我方现状核对（iOS/Android 共用 Rust server）

- 服务本体：`rust/legado-ffi/src/api/server_api.rs:155-200` `server_start`——spawn 前 `block_on` 同步 bind `("0.0.0.0", port)`（:167-170），失败同步 Err；`legado_server::server::serve_web(listener, db)` 在独立 tokio runtime 任务里（:174-181）。**无任何保活/生命周期感知逻辑**。
- Flutter 开关：`flutter_legado/lib/src/screens/settings_screen.dart:119-153`（`_toggleWebService` → `api.startServer(port)` + `setConfig('webService')`）；设置页进入时按偏好回显状态（:57-84），**但不自动重启 server**。注释已明示：`webServiceWakeLock` 仅持久化未接线（:118；`other_settings_screen.dart:292-295`；键定义 `pref_keys.dart:221`）。
- iOS 音频基础设施（可复用）：
  - `Info.plist` 已声明 `UIBackgroundModes: audio`（`flutter_legado/ios/Runner/Info.plist` UIBackgroundModes 数组，`audio`）；
  - `AppDelegate.swift:13-19` 已把 `AVAudioSession` 设为 `.playback` + `.spokenAudio` 并 `setActive(true)`（为听书所设，未加 mixWithOthers，独占语义对齐 Android）;
  - `NowPlayingBridge.swift` 提供 Now Playing / 远程命令 / 中断桥（通道 `legado/media_session`）；`setWakeLock` 为空实现并注释「后台保活由音频会话承担」（:72-74）。**结论：C 方案的会话层前提全部就绪，缺的只是「Web 服务专用静音播放循环」与其生命周期接线**。
  - pubspec 无 audio_service / just_audio（grep 无结果），不能指望现成保活插件。
- Android 侧：`webServiceWakeLock` 同样未接线（同上注释），与「Android 未接保活」背景一致。

---

## 四、iOS 方案对照（设计，不实施）

| 方案 | 机制 | 能撑多久 | 代价 | 上架/自用风险 | 工作量（我方落点） |
|---|---|---|---|---|---|
| **A 纯前台（现状）** | 仅前台可服务；退后台进程挂起 | 退后台即刻起不可达（实测 Safari 打不开） | 无 | 无 | 0；仅 UI 文案：「Web 服务仅在本应用处于前台时可用，请保持应用打开」（建议同时展示 `http://<IP>:<port>`） |
| **B beginBackgroundTask** | 退后台时向系统申请后台执行预算收尾 | 经验值 ~30s（iOS 13+，**待实测**；iOS 6 时代的 180s 不再适用） | 极小 | 无 | 小（AppDelegate 生命周期包一层）；**覆盖不了「切出去浏览器看几眼」**，只能保已建立连接完成响应 |
| **C 静音音频保活（推荐）** | Web 服务开启且退后台时，启动静音/近静音音频循环，让系统因 audio 后台模式不挂起进程 | 理论无限（锁屏也活）；经验上纯数字静音可能在锁屏数分钟后被系统掐，用极低音量 PCM 或短暂非静音帧更稳（**全部待实测**） | 耗电略增（阻止 SoC 深睡 + 播放器空转）；控制中心可能出现播放卡片 | 自用签名无 2.5.4 审核风险；上架则属「声明 audio 却无可感知内容」，有被拒风险 | 小-中：Swift 侧新增 KeepAliveBridge 或扩展 `legado/media_session` 通道加 `setWebKeepAlive{enabled}`；Dart 侧在 `_toggleWebService` 与 App 生命周期（`didChangeAppLifecycleState`）接线：退后台+服务在跑 → 启，回前台 → 停。与听书共存：同一 `.playback` 会话，听书时天然保活，可跳过静音循环 |
| **D 其它** | BGAppRefreshTask：系统择机唤醒一次、秒级预算——**根本不适用于持续监听**（时机不可控、不保活 socket）。PushKit/定位/NetworkExtension：需服务器资质/always 权限/过重，均不适用 | — | — | — | — |

**推荐与理由**：
- **首选 C + 兜底 A**。理由：① 目的对齐——原版 WakeLock 的目的就是「防 CPU 睡眠」，iOS 的等价物就是 audio 后台模式保活；② 基础设施已就绪（§三），增量最小；③ 与听书场景自然融合（听书时本就活着）；④ 自用签名无审核代价。
- **已知代价/待验证**（实现前须真机确认）：锁屏后静音循环是否被系统掐（决定用「真静音」还是「-40dB 近静音」）；控制中心/状态栏是否出现播放指示；保活播放器与 TTS 听书的会话互斥行为（当前独占类别下应可共存，建议同一 session 内实现）。
- B 不单独作为方案，可作为 C 的辅助：退后台瞬间包一个 backgroundTask，给「最后一个在途请求」留收尾窗口。

---

## 五、验收口径（真机）

**前置**：iPhone 与 PC 同一局域网；设置允许 App「本地网络」（Info.plist 已有 `NSLocalNetworkUsageDescription`，Info.plist:76-77）；Web 服务开启（端口 1122）。

**步骤**：
1. 基线：App 前台，PC 执行 `curl -m 5 -o /dev/null -s -w "%{http_code}\n" http://<iPhoneIP>:1122/`，应返回 HTTP 状态码（非 000）。
2. 切后台（按 Home），在 10s / 30s / 1min / 3min / 5min / 10min 各执行一次同上 curl，记录结果。
3. 锁屏状态重复第 2 步口径。
4. 对照组：听书播放中切后台重复第 2 步（音频占用下预期长期可达，验证会话机制本身有效）。

**判据**：
- **A（现状）对照预期**：切后台后约 10-30s 内 curl 变为超时（exit 28，表现为 SYN 无响应而非拒绝）——此即缺陷基线。
- **C 通过标准**：切后台 + 锁屏两条路径下，**10 分钟内每次 curl（-m 5）均返回 HTTP 状态码**，连续 3 轮全过。建议 N=10 分钟：覆盖「切出去用 PC 浏览器写几条源」的真实使用窗口。
- 回归口径：保活开启时回前台关闭 Web 服务，静音循环必须随之停止（控制中心无残留播放指示）。

---

## 六、未找到 / 待验证清单

- 未找到：原版任何 BOOT_COMPLETED receiver（权限声明为遗留或他用途，Web 服务维度无消费者）。
- 未找到：原版应用启动时自动拉起 WebService 的代码路径。
- 待实测（iOS 经验值）：B 的后台预算时长；C 纯静音被系统掐断的时点与条件；控制中心播放卡片是否出现；保活循环与 TTS 的会话行为。
- 未核实：我方听书 iOS 侧发声实现（pubspec 无 audio_service/just_audio，未深查 TTS 通道——与 C 的共存设计需实现前补查）。
