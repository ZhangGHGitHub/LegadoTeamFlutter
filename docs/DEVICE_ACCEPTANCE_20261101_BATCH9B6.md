# 批 9b-6 设备验收报告（Web 服务唤醒锁双锁 · 开关/停服释放 · 生命周期/重建 · 进程退出 · 锁屏 LAN · 回归）

> 范围：批 9b-6（「Web 服务唤醒锁」真正接线）——Android 在 Web 服务运行且
> 偏好 `webServiceWakeLock` 开启时同时持有 `PARTIAL_WAKE_LOCK` 与
> `WIFI_MODE_FULL_HIGH_PERF` Wi-Fi 锁（tag 均为 `legado:WebService`）；
> 运行中切换开关即时生效；停止服务/关闭开关立即释放；进程级持有，
> Activity/引擎重建、旋转、自定义图标 Launcher1-6 切换不丢锁；设置页
> 初始化按运行态对账；force-stop 随进程退出释放；锁屏/切后台 LAN 可达性；
> 回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测 `device`）。
>
> **结论：7 PASS / 1 FAIL / 0 BLOCKED。**
> 场景 5「锁屏/切后台到局域网」判定 **FAIL**：双锁确实持有，但 Android
> 后台网络策略（`netpolicy` UID 10066 `effective=APP_BACKGROUND`）将应用
> 出网阻断，宿主 `curl` 在息屏后 13/13 次超时、亮屏切后台 30s 后同样超时；
> 本地回环 `127.0.0.1:1122` 仍 200，证明 Rust 服务未停，根因是无前台服务
> 导致的后台网络限制（详见 §3.5/§6.1）。其余 7 组场景 PASS。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0、OOM=0（全会话 logcat 28,307 行）。
> 登记 1 项 P2（上述 LAN 可达性）、4 项 P3 观察（镜像态、旋转后 Tab 不同步、
> dumpsys Wi-Fi 日志重复行、TXT 夹具目录规则误命中）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带；shell 实测 root） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.430** / versionCode **431**（`dumpsys package` 实测，与 pubspec `2.0.430+431` 一致；安装前旧版本为 2.0.429/430） |
| 源码基线 | `master` HEAD `088a81ba50`（`chore: 批9b-6 收尾（2.0.430+431 双日志与计划关闭登记）`；含 `e6be254e9c` 审查回修） |
| 验收时间 | 2026-11-01 02:29 ~ 02:56（构建、安装、截图、日志时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261101_batch9b6/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1101/`（16 张） |

### 1.1 构建产物（本批无 Rust 变更，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批仅 Kotlin/Dart，无 Rust/FFI 变更）；复用 `jniLibs/` 现有 quickjs `.so` |
| x86_64 `.so`（本设备） | `flutter_legado/android/app/src/main/jniLibs/x86_64/liblegado_ffi.so`：**51,883,696 B**，mtime **2026-10-31 23:45:24**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e` |
| arm64 `.so` | 51,630,176 B，mtime 2026-10-31 23:44，sha256 `c8c8aea52e09fe0101051327539dc9878ef1504801f4bb7f8d671c9e6cff3f38` |
| `.so` meta | `{"mode":"release","quickjs":true,"builtAt":"2026-10-31T23:45:24.5288717+08:00","rustFingerprint":"1ede733fbc7f7e25778d8cd48406b4db0d49626fc4a4602eb83ae86150f23616"}` —— **quickjs:true** |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 98.3s`，199,250,388 B（190.0 MB）；sha256 `11e9f5533be24192fd88a43e59504c0310e7c8213e4a220f1bc60b3328a07787` |
| 安装 | `adb install -r` **Success**；`dumpsys` versionName=**2.0.430** / versionCode=**431** |
| 启动冒烟 | 冷启动 `am start -W` 344~401ms；空书架正常渲染（`shots/00_launch.png`） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0 |
| 唤醒锁 Dart 单测 | `flutter test test/unit/web_service_wake_lock_service_test.dart` | **25/25 passed**（含运行中切换、停服兜底、部分持锁、引擎重建对账、同步竞态） |
| 设置页 Widget 测试 | `flutter test test/widget/settings_test.dart` | **27/27 passed**（含「运行中切换即时 acquire/release」「非 Android 开关禁用」） |
| Kotlin JVM 单测 | `gradlew :app:testDebugUnitTest --tests io.legado.flutter.WebServiceWakeLockSetTest --tests io.legado.flutter.WebServiceWakeLockBridgeArgumentTest` | **BUILD SUCCESSFUL**；10/10 passed（SetTest 6 + ArgumentTest 4），failures=0 |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 设置唤醒锁开 → 启动 Web 服务 → CPU/Wi-Fi 双锁 + `/api/health` | **PASS** | `Wake Locks: size=1` / `PARTIAL_WAKE_LOCK 'legado:WebService'`；`WifiLock{legado:WebService type=4 ... uid 10066}`；`GET /api/health` 200（0.0015s），UI `running on port 1122` |
| 2 | 运行中关开关 → 双锁消失；重开 → 出现；停服 → 消失；重复开停幂等 | **PASS** | 关开关：`size=0` + `releaseWifiLock`；重开：`acquireWifiLock`；停服：双清；2 轮 start/stop 均成对；偏好关时启动服务不持锁 |
| 3 | 旋转 / 自定义图标 Launcher1-6 / Activity 重建 / 设置页对账 | **PASS**（锁与对账）；后台窗口 LAN 见场景 5 | 旋转前后 ACQ 连续、无新 acquire；icon1/icon6 切换后 pid=62762 不变、双锁仍在；新引擎 My 页显示 running，无重复 acquire/误释放 |
| 4 | force-stop → 锁消失 | **PASS** | force-stop 后 `NO_PROCESS`、`Wake Locks: size=0`、无 `WifiLock{legado...}`、`/api/health` 000 |
| 5 | 锁屏 / 局域网 1/5 分钟 `curl` 可达性 | **FAIL（LAN 可达性）**；双锁持有本身 PASS | 息屏后 13/13 次宿主 curl 超时（`000/5.00s`）；同时 `Wake Locks: size=1`、Wi-Fi 锁在、进程在、本地回环 200；`netpolicy` UID 10066 `effective=APP_BACKGROUND` |
| 6 | 非 Android / 设置 UI 登记 | **PASS（静态/单测登记）** | 设置行副题「仅 Android 生效」（`shots/01`）；代码 `isSupported` 门控；Widget 测试「非 Android 开关禁用」通过 |
| 7 | 回归：Web 启停 / 设置页 / 书架 / 阅读 / FATAL/ANR | **PASS** | 多轮启停、设置多级往返、TXT 导入与阅读、目录 3 项；FATAL=0、ANR=0、overflow=0、OOM=0 |
| 8 | 清理与恢复 | **PASS** | 停服、关唤醒锁、图标回默认、旋转设置复原、`pm clear` 后 books/chapters/book_sources=0、prefs 无 webService、空书架；保留版本 2.0.430/431 |

## 三、逐场景证据

### 3.1 场景 1：锁获取（设置开 → 启动服务）

- **设置**：其他设置 → 「Web 服务唤醒锁」开关由默认关闭切到开
  （`shots/01_wakelock_on.png`）；prefs 实测
  `flutter.webServiceWakeLock=true`。
- **启动服务**：我的 → Web 服务卡片点击后副题变为 `running on port 1122`
  （`shots/02_webservice_running.png`）。
- **CPU 锁**（`dumpsys power`，02:34:03）：
  ```
  Wake Locks: size=1
    PARTIAL_WAKE_LOCK                 'legado:WebService' ACQ=-24s310ms (uid=10066 pid=62762)
  ```
  tag 与原版 `WebService.kt` 逐字一致；无超时（LONG）。
- **Wi-Fi 锁**（`dumpsys wifi` 02:34:03 + logcat）：
  ```
  WifiLock{legado:WebService type=4 uid=1000 workSource=WorkSource{10066 io.legado.flutter_legado}}
  11-01 02:33:38.233  I/WifiService: acquireWifiLock uid=10066 lockMode=3 packageName=io.legado.flutter_legado
  ```
  `type=4` 即 `WIFI_MODE_FULL_HIGH_PERF`；`lockMode=3` 对应 high-perf 路径。
- **健康检查**（宿主 → 设备）：
  ```
  curl -m 5 http://192.168.100.62:1122/api/health
  {"service":"legado-server","status":"ok","version":"0.2.0"}
  HTTP=200 time=0.001504
  ```
- **结论**：服务端口 1122、双锁 tag/类型/持有状态均符合预期，PASS。

### 3.2 场景 2：运行中开关 / 停服释放 / 幂等

| 操作 | 时间 | `dumpsys power` | Wi-Fi 锁 | 其他 |
|---|---|---|---|---|
| 运行中关唤醒锁开关 | 02:34:41~47 | `Wake Locks: size=0` | 无 `WifiLock{legado...}` | `releaseWifiLock uid=10066` 02:34:41.184；服务仍在运行 |
| 重新开启 | 02:34:52~58 | `size=1`，ACQ=-5s135ms | `WifiLock{legado:WebService...}` | `acquireWifiLock` 02:34:52.250 |
| 停止 Web 服务 | 02:35:14~22 | `size=0` | 无活动锁 | `releaseWifiLock` 02:35:14.680 |
| 第 1 轮启动→停止 | 02:35:28→35 | 启动 `size=1`；停止 `size=0` | 成对 acquire/release | 02:35:28.640 / 02:35:35.065 |
| 第 2 轮启动→停止 | 02:35:41→47 | 启动 `size=1`；停止 `size=0` | 成对 acquire/release | 02:35:41.466 / 02:35:47.880 |
| 偏好关 + 启动服务 | 02:36:58 | **`size=0`** | 无活动锁 | 服务 `running on port 1122`，无 acquire |
| 服务停止 + 偏好开 | 02:37:37 | `size=0` | 无活动锁 | 不误 acquire |

- 开关 UI 状态同步：关后 `chk=false`、开后 `chk=true`
  （`shots/03_wakelock_off_running.png`）。
- 快速连续开停两轮无崩溃、无 FATAL；每次 release 后均无残留单锁。
- **结论**：运行中切换、停服释放、偏好关闭时启动、服务停止时偏好开启
  四种组合均符合预期，PASS。

### 3.3 场景 3：旋转 / 自定义图标 / Activity 重建 / 对账

#### 3a 默认图标下旋转（MuMu 支持真实旋转）

- 设备物理 1080x1920；设置 `accelerometer_rotation=0` + `user_rotation=1`
  → 横屏（`shots/04_rotate_landscape.png`），再 `user_rotation=0` → 竖屏
  （`shots/05_rotate_portrait.png`）。
- `topResumedActivity` 始终为 `MainActivity`；锁在旋转前后连续持有：
  - 横屏（02:38:26）：`PARTIAL_WAKE_LOCK 'legado:WebService' ACQ=-16s356ms`
  - 竖屏（02:38:36）：`ACQ=-26s436ms`（同一 acquire，无重取）
  - 两次 `curl /api/health` 均 HTTP 200。
- **结论**：旋转不丢锁、不重取，PASS。

#### 3b 切换自定义桌面图标（icon1 / icon6）并重建 Activity

| 步骤 | 结果 |
|---|---|
| 外观 → 切换图标 → 图标 1 | prefs `flutter.launcherIcon=icon1`；`cmd package resolve-activity` 解析为 `Launcher1`；系统 `Force finishing` MainActivity（组件被禁用，符合预期） |
| 切图标后的进程/锁 | pid **62762** 不变；`Wake Locks: size=1`（ACQ=-2m39s383ms）；Wi-Fi 锁仍在；02:40:50 logcat `freezing 62762`（后台 cached 冻结） |
| 启动新图标 Launcher1 | `am start -W` **WARM 173ms**；02:41:03 `quick sync unfreeze 62762`；同 pid；锁 ACQ=-2m57s378ms；`/api/health` **200** |
| 新引擎设置页对账 | My 页副题 `running on port 1122`（`shots/08_launcher1_my_reconcile.png`）；wifi acquire 日志仍只有 02:38:09 一次，**无重复 acquire、无误释放**（ACQ 时间连续） |
| 切图标 6 + 启动 Launcher6 | prefs `icon6`；解析 `Launcher6`；`Force finishing` Launcher1；同 pid 62762；`am start -W` **WARM 145ms**；锁 ACQ=-3m48s839ms；`/api/health` **200** |

- 说明：图标切换会禁用当前 Activity 组件并触发系统 `Force finishing`，
  应用短暂无前台 Activity 时进程被 Android cached 冻结；进程、Rust server
  与双锁均未死亡，重新从新图标启动后服务立即恢复 200。
- **结论**：进程级锁 + 新引擎对账链路成立，PASS（后台窗口 LAN 不可达的
  同一根因归入场景 5，不重复计 FAIL）。

### 3.4 场景 4：force-stop 释放

- force-stop 前（02:53:28）：pid 62762；`Wake Locks: size=1`；Wi-Fi 锁在；
  `/api/health` 200。
- `adb shell am force-stop io.legado.flutter_legado` 后（02:53:37）：
  ```
  ps -A | grep io.legado  -> NO_PROCESS
  Wake Locks: size=0
  dumpsys wifi -> NO MATCH (no active legado lock)
  curl /api/health -> HTTP=000
  ```
- **结论**：锁随进程退出释放，PASS。

### 3.5 场景 5：锁屏 / 局域网可达性（**FAIL**）

#### 3.5a 真实息屏（mStayOn 未阻断）

- 基线：`dumpsys power` 中 `mStayOn=true`（MuMu 常亮设置）。
- `input keyevent 223`（KEYCODE_SLEEP）后 `mWakefulness=Asleep`、`mStayOn=true`
  仍为 true——**MuMu 的 mStayOn 不阻止按键息屏**，因此本项可以真测，
  不需要标 BLOCKED。

#### 3.5b 息屏后 1/5 分钟宿主可达性（13 次采样，02:42:20 ~ 02:49:25）

`logcat/s5_lock_screen_series.log` 全量（每 30s 一次，共 13 条）均为：

```
mWakefulness=Asleep; Wake Locks: size=1; wifi_lock_lines=1; proc=1; curl=000/5.00s
```

| 时间 | 唤醒态 | CPU 锁 | Wi-Fi 锁行 | 进程 | 宿主 curl |
|---|---|---|---|---|---|
| 02:42:20 | Asleep | size=1 | 1 | 1 | `000/5.001868` |
| 02:43:31 | Asleep | size=1 | 1 | 1 | `000/5.001312` |
| 02:44:42 | Asleep | size=1 | 1 | 1 | `000/5.001347` |
| 02:45:53 | Asleep | size=1 | 1 | 1 | `000/5.001797` |
| 02:47:03 | Asleep | size=1 | 1 | 1 | `000/5.002142` |
| 02:48:14 | Asleep | size=1 | 1 | 1 | `000/5.001919` |
| 02:49:25 | Asleep | size=1 | 1 | 1 | `000/5.001962` |

（表中为节选，13/13 全部超时；完整 13 条见证据文件。）

#### 3.5c 同刻服务未死：本地回环仍 200

息屏期间（02:44:58）在设备内执行：

```
printf 'GET /api/health HTTP/1.0\r\n\r\n' | timeout 5 nc 127.0.0.1 1122
HTTP/1.0 200 OK
{"service":"legado-server","status":"ok","version":"0.2.0"}
```

同时 `/proc/net/tcp` 显示 `00000000:0462 ... LISTEN`（uid 10066）。
→ Rust server 仍在监听并响应回环请求。

#### 3.5d 根因证据：Android 后台网络策略

息屏后（02:45 现场，服务运行中）`dumpsys netpolicy`：

```
UID=10066 state={procState=TPSL,seq=40918,cap=-------T}
  blocked_state={blocked=APP_BACKGROUND,allowed=NONE,effective=APP_BACKGROUND}
```

收尾后复核息屏复现同一 `blocked_state`（`logcat/netpolicy_screenoff_verify.txt`：
`procState=TPSL,seq=41878`、`effective=APP_BACKGROUND`；同刻
`mWakefulness=Asleep`）。

防火墙规则历史（同一份 dumpsys）：

```
2026-11-01T02:42:07:709 - Firewall rule changed: 10066-standby-default
2026-11-01T02:42:12:711 - Firewall rule changed: 10066-background-default
```

亮屏后：

```
UID=10066 state={procState=TOP,...}
  blocked_state={...,allowed=FOREGROUND|TOP|NOT_IN_BACKGROUND|METERED_FOREGROUND,effective=NONE}
2026-11-01T02:49:58:599 - Firewall rule changed: 10066-background-allow
```

→ 应用一旦离开前台（息屏或 HOME），UID 10066 即进入
`APP_BACKGROUND` 出网阻断；唤醒锁只保 CPU/Wi-Fi，**不改变进程前后台
/防火墙判定**。

#### 3.5e 亮屏但切后台同样不可达（对照）

- HOME 后 t+3s：`HTTP=200`（宽限期内）；t+30s：`HTTP=000/5.001270`。
- 同刻：`mWakefulness=Awake`、`Wake Locks: size=1`、Wi-Fi 锁在；
  `netpolicy` UID 10066 `procState=LAST, effective=APP_BACKGROUND`
  （现场输出；`logcat/netpolicy_background.txt` 收尾复测同为 LAST/APP_BACKGROUND）。
- 回到前台后 `curl` 立即恢复 200（`shots/10_back_foreground.png`）。

#### 3.5f 结论与分级

- **双锁持有：PASS**（息屏/后台全程 CPU+Wi-Fi 锁未释放）。
- **锁屏/后台 LAN 可达性：FAIL**（息屏 13/13 超时；亮屏后台 30s 超时）。
- 根因：本仓库 Web 服务是进程内 Rust server，无 Android 前台服务；
  Android 15 的后台网络策略按 UID 阻断，唤醒锁无法豁免。原版以
  `WebService` 前台服务保持前台进程，故不触发该阻断。
- 定级 **P2**（功能目的未达成，非崩溃/数据损坏）；修复方向为前台服务
  （或经产品裁决显式缩小「后台可用」承诺），不在本批代码内改。

### 3.6 场景 6：非 Android / 设置 UI（静态/单测登记）

- 设备 UI：其他设置行标题「Web 服务唤醒锁」、副题「仅 Android 生效」，
  Android 上开关可点（`shots/01_wakelock_on.png`）。
- 代码门控：`onChanged: WebServiceWakeLockService.instance.isSupported ? ... : null`
  （`other_settings_screen.dart` L316-334）；`isSupported => platformIsAndroid()`；
  非 Android 时 `WebServiceWakeLockService` 不触平台通道。
- 单测：`test/widget/settings_test.dart` 的
  「Web 服务唤醒锁：非 Android 开关禁用」通过（27/27）。
- 本设备为 Android，无法实测 iOS 静音保活与桌面端；按要求仅作静态/单测
  登记，PASS（不声称已在 iOS/桌面验证）。

### 3.7 场景 7：回归

- **Web 服务启停**：本会话共 6 次启动（含运行中开关切换、2 轮快速
  start/stop、偏好关时启动 1 次、force-stop 后冷启动再启停）；除 force-stop
  结束的 1 次外，均显式停止且双锁成对释放、端口释放、无崩溃；force-stop
  后冷启动再启动服务得到新 pid 2609，锁重新 acquire（02:54:22），停止
  release（02:54:38）。
- **设置页**：我的 → 设置 → 高级 → 其他设置、外观 → 主题/切换图标、
  阅读设置入口等多级往返，无异常。
- **书架/阅读**：`添加本地` 导入 169 B UTF-8 TXT（`qa9b6`），书架显示封面；
  打开阅读器，第 1 章正文正常渲染、进度 33.3%（`shots/11_reader_ch1.png`）；
  目录页显示 3 项（`第1章 唤醒测试`、`第2章 收尾`、`第二章内容，用于翻章与目录验证。`）。
  第 2/3 项无正文系夹具内容行以「第二章」开头、命中内置目录规则被当作
  标题（§6.5，非本批缺陷）。
- **OS 健康**：见 §四。
- **结论**：PASS。

### 3.8 场景 8：清理

| 项 | 结果 |
|---|---|
| Web 服务 | 已停止；`curl /api/health` → `HTTP=000` |
| 唤醒锁偏好 | 已关闭（prefs `flutter.webServiceWakeLock=false`） |
| 双锁 | `Wake Locks: size=0`；无 `WifiLock{legado...}` |
| 启动图标 | 已切回「默认」：prefs `launcherIcon=iconMain`；`resolve-activity` 为 `MainActivity`；Launcher1/6 已禁用 |
| 旋转设置 | `accelerometer_rotation=1`、`user_rotation=0`（恢复原值） |
| 应用数据 | `pm clear` 后：books=0、chapters=0、book_sources=0；prefs 无 `webService*`；空书架（`shots/15_clean_empty_shelf.png`） |
| 设备文件 | `/sdcard/Download/qa9b6.txt`、`/sdcard/ui.xml` 已删除 |
| 版本 | 保留 **2.0.430 / 431**（`dumpsys package` 复核） |

## 四、FATAL / ANR 汇总

统计口径：`logcat -b all -d -v time` 全会话 28,307 行（2026-10-28 21:33 起，
含本批 02:29~02:56 全部操作）。

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| `WebServiceWakeLock` 警告/失败日志 | **0** |
| `Force finishing ActivityRecord ... legado` | 3（均为图标组件切换/恢复禁用触发，非崩溃） |

## 五、证据清单（`tmp_debug/device_acceptance_20261101_batch9b6/`）

| 类别 | 文件 |
|---|---|
| 构建 | `../../build_9b6.log`（`flutter build apk --release` 全量输出，EXIT=0） |
| 会话日志 | `logcat/final_session_9b6.log`（28,307 行，FATAL/ANR/overflow/OOM 统计源） |
| 锁屏采样 | `logcat/s5_lock_screen_series.log`（13 条，02:42:20~02:49:25） |
| 网络策略 | `logcat/netpolicy_foreground.txt`、`logcat/netpolicy_background.txt`、`logcat/netpolicy_screenoff_verify.txt`（UID 10066 blocked_state / 防火墙规则历史）、`logcat/power_screenoff_verify.txt`（复核息屏 `mWakefulness=Asleep`） |
| dumpsys power | `logcat/power_s1_running.txt`、`power_s2_switch_off.txt`、`power_s2_switch_on_again.txt`、`power_s2_service_stopped.txt`、`power_s2_cycle1_on/off.txt`、`power_s2_cycle2_on/off.txt`、`power_s2_prefoff_running.txt`、`power_s3_started/landscape/portrait/my_reenter.txt`、`power_s3_icon_switch_home.txt`、`power_s3_launcher1_reopened/reconcile.txt`、`power_s3_launcher6_reopened.txt`、`power_s4_before_forcestop/after_forcestop/cold_start_no_service.txt`、`power_s7_reading/restart_service.txt`、`power_s8_service_stopped/final_clean.txt` |
| dumpsys wifi | 同名 `wifi_*.txt`（含 `WifiLock{legado:WebService type=4 ...}` 与 acquire/release 日志） |
| 进程状态 | `logcat/processes_s5_screenoff.txt`（isFrozen/blocked_state 对照） |
| UI 取证 | `data/ui_launch.xml`、`data/ui_current.xml`；`data/uia.py`、`data/locks.py`、`data/s5_probe.sh`（QA 工具，未改业务代码） |
| 截图 | `shots/00~15`（16 张）；副本 `docs/materials_1101/` |
| 回归夹具 | `data/qa9b6.txt`（169 B，已从设备删除；本地留存） |

## 六、说明与遗留

### 6.1 P2：锁屏/切后台 LAN 不可达（本批验收 FAIL 项）

- **可复现步骤**：Web 服务运行 + 唤醒锁开 → `input keyevent 223` 息屏（或
  按 HOME 切后台）→ 等待约 10s（息屏）/30s（HOME）→ 宿主
  `curl -m 5 http://192.168.100.62:1122/api/health`。
- **期望**：唤醒锁使服务在后台/锁屏仍可被局域网访问（原版前台服务语义）。
- **实际**：宿主连接超时（13/13）；设备内 `127.0.0.1:1122` 仍 200；
  `dumpsys netpolicy` 显示 UID 10066 `effective=APP_BACKGROUND`，防火墙
  规则切到 `10066-background-default`。
- **根因**：唤醒锁只影响 CPU/Wi-Fi 供电，不改变进程前后台/网络策略；
  本仓库无 Android 前台服务，应用转后台即被系统按 UID 阻断出网。原版
  `WebService.kt` 依赖前台服务保持前台进程。
- **影响**：Web 服务「在浏览器里用手机书源」的核心后台场景在锁屏/切后台
  后不可用；不影响前台使用与双锁持有语义。
- **建议**：后续批次评估前台服务（`FOREGROUND_SERVICE` + 常驻通知）或
  产品侧明确「仅前台可用」并在 UI 标注；本批不擅自改代码。

### 6.2 P3：进程退出后 Web 服务卡片镜像态（既有行为）

- force-stop 后冷启动，卡片显示开关 **checked=true**、副题 `stopped`
  （`_webService` 读 config 镜像 `webService=true`；`getServerStatus`
  为 stopped）。此时点一次是「关闭」，需再点一次才启动。
- 代码注释已将该镜像态登记为原版对齐行为（无自启/无前台服务），非本批
  唤醒锁回归；登记 P3，建议后续评估卡片在 `stopped` 时自动回落开关。

### 6.3 P3：旋转后底部 Tab 选中态与内容短暂不同步（1 次，未复测）

- 在 My 页旋转回竖屏后截到：底栏「我的」高亮但内容为「书架」
  （`shots/06_after_rotate_state.png`）；点「首页」再点「我的」后恢复。
- 属响应式布局/导航状态同步问题，未在本批改动范围内，且仅出现 1 次
  （后续未复测）；登记 P3，建议独立复测。

### 6.4 P3：dumpsys wifi 日志重复行（非真实双 acquire）

- `dumpsys wifi` 中同一时间戳的 `acquireWifiLock` 可能重复出现两行
  （如 02:35:28.640 两次）；`logcat` 中同一事件仅 1 行，且 `dumpsys power`
  `Wake Locks` 始终 size=1，`setReferenceCounted(false)` + `isHeld` 守卫
  生效——判定为 dumpsys Wi-Fi 日志输出重复，不是真实重复 acquire。

### 6.5 P3：回归夹具被内置目录规则误命中（测试数据问题）

- 169 B 夹具第 3 行「第二章内容，用于翻章与目录验证。」以「第二章」开头，
  命中内置 TXT 目录规则（`^\s{0,4}第[数字中文]+[章回节卷集部篇话]\s*.+$`），
  被解析为第 3 章标题，导致第 2/3 章正文为空。
- 这是夹具写法问题（与批 1b-3 报告 §6.5 同类），不是本批缺陷；第 1 章正文
  渲染正常，阅读链路本身 PASS。

### 6.6 环境说明：mStayOn 与真实息屏

- MuMu 基线 `mStayOn=true`，但 `KEYCODE_SLEEP` 可使 `mWakefulness=Asleep`
  （屏幕确实关闭），故场景 5 未标 BLOCKED，按可观测结果记 FAIL。
- 息屏后进程未被 freezer 冻结（`cgroup.freeze=0`、`isFrozen=false`），
  回环可响应；宿主不可达由网络策略解释，与 freezer 无关。

### 6.7 与原版的生命周期差异（既有登记）

- 原版唤醒锁依附 `WebService` 前台服务，退后台持续持有且不被后台网络
  策略阻断；本仓库为进程内 Rust server，无前台服务。文档已登记「进程被
  回收时锁随进程消失，后台存活不作保证」；本批实测进一步明确：**即使
  进程存活、双锁持有，后台网络仍被系统阻断**（§6.1）。

## 七、结论

- 场景 1（双锁获取 + `/api/health` 200）：**PASS**。
- 场景 2（运行中开关/停服释放/偏好关不持锁/快速开停幂等）：**PASS**。
- 场景 3（旋转、icon1/icon6 切换、Activity 重建、设置页对账）：**PASS**
  （锁与对账；后台窗口 LAN 见场景 5）。
- 场景 4（force-stop 锁消失）：**PASS**。
- 场景 5（锁屏/后台 LAN 可达性）：**FAIL**——双锁持有 PASS，但宿主
  `curl` 息屏 13/13 超时、亮屏后台 30s 超时；根因 Android 后台网络策略，
  无前台服务（P2）。
- 场景 6（非 Android / 设置 UI 静态与单测登记）：**PASS**。
- 场景 7（Web 启停/设置/书架/阅读回归）：**PASS**；FATAL=0、ANR=0、
  overflow=0、OOM=0。
- 场景 8（清理与恢复）：**PASS**；保留版本 2.0.430/431。

**问题分级**：P1=0；**P2=1**（§6.1 后台/锁屏 LAN 不可达）；P3=4（§6.2
镜像态、§6.3 旋转 Tab 同步、§6.4 dumpsys 重复日志、§6.5 夹具规则误命中）。

编写者：QA（ZCode 子代理）｜ 2026-11-01
