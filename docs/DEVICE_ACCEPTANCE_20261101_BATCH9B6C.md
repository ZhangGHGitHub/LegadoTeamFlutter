# 批 9b-6c 设备验收报告（Android Web 前台服务 · 锁屏/后台/任务移除 LAN · 通知权限拒绝 · 回归）

> 范围：批 9b-6c「Android Web 前台服务保活」——Web 服务运行期间由
> `WebServerForegroundService`（`foregroundServiceType=specialUse`）把进程
> 提升为前台服务，修正批 9b-6 验收 FAIL（唤醒锁无法改变 `APP_BACKGROUND`
> 网络策略）。覆盖：首次 Android 13+ 通知权限弹框、前台服务建立与常驻通知、
> 锁屏 10s/1min/5min 宿主可达性、切后台 HOME、最近任务划掉（stopWithTask=false）、
> 停服/重启、通知权限拒绝降级、回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测 `device`）。
>
> **结论：8 组场景全部 PASS、0 FAIL、0 BLOCKED。**
> 上一轮 FAIL 项（锁屏/后台 LAN 不可达）**已复验通过**：息屏 12 个采样点
> ×3 次宿主 `curl` 共 **36/36 HTTP 200**（04:20:29~04:25:33，覆盖 10s/
> 1min/5min），切后台 HOME 后 5s/35s/70s 均 200；同刻 `netpolicy` UID 10066
> `procState=FGS`、`effective=NONE`（上一轮为 `APP_BACKGROUND` 阻断）。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0、OOM=0（全会话 logcat 30,557 行）。
> 登记 3 项 P3 观察（前台服务通知延迟展示约 10s、`pm revoke` 触发系统杀进程、
> uiautomator 工具退出崩溃遗留 tombstone），均非本批代码缺陷。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.431** / versionCode **432**（`dumpsys package` 实测，与 pubspec `2.0.431+432` 一致；targetSdk 36 / minSdk 24） |
| 源码基线 | `master` HEAD `1f168883ce`（`chore: 批9b-6c 收尾（2.0.431+432 双日志与计划关闭登记）`；含 `1379f00b65` 审查回修、`653b9509f0` 权限顺序与回滚兜底） |
| 验收时间 | 2026-11-01 04:15 ~ 04:37（构建、安装、截图、日志时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261101_batch9b6c/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1101b/`（32 张） |

### 1.1 构建产物（本批无 Rust 变更，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（批 9b-6c 仅 Kotlin/Dart，无 Rust/FFI 变更）；复用 `jniLibs/` 现有 quickjs `.so` |
| x86_64 `.so`（本设备） | `liblegado_ffi.so`：**51,883,696 B**，mtime **2026-10-31 23:45:24**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（与 9b-6 验收一致，未重建） |
| arm64 `.so` | 51,630,176 B，mtime 2026-10-31 23:44，sha256 `c8c8aea52e09fe0101051327539dc9878ef1504801f4bb7f8d671c9e6cff3f38` |
| `.so` meta | `{"contentHash":-993835076,"mode":"release","quickjs":true,"builtAt":"2026-10-31T23:45:24.5288717+08:00","rustFingerprint":"1ede733fbc7f7e25778d8cd48406b4db0d49626fc4a4602eb83ae86150f23616"}` —— **quickjs:true** |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 39.6s`，**199,267,072 B（190.0 MB）**；sha256 `d142b61886003d49b152f19202ff0376a5e7706279eca57f937f77e78c86d818`（日志 `build_9b6c.log`） |
| 安装 | `adb install -r` **Success**；`dumpsys` versionName=**2.0.431** / versionCode=**432**（安装前旧版本 2.0.430/431） |
| 启动冒烟 | `am start -W` COLD **314~346ms**；空书架正常渲染（`00_launch.png`） |
| 合并 Manifest | `build/app/intermediates/merged_manifests/release/.../AndroidManifest.xml`：`WebServerForegroundService` `foregroundServiceType="specialUse"`、`stopWithTask="false"`、`PROPERTY_SPECIAL_USE_FGS_SUBTYPE="Local web server for LAN access"` |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0 |
| 前台服务 Dart 单测 | `flutter test test/unit/web_service_foreground_service_test.dart` | **25/25 passed** |
| 设置页前台服务 Widget 测试 | `flutter test test/widget/settings_web_foreground_service_test.dart` | **10/10 passed**（含权限拒绝仍运行、回前台对账、回滚停服、与唤醒锁解耦） |
| 设置页回归 Widget 测试 | `flutter test test/widget/settings_test.dart` | **27/27 passed** |
| Kotlin JVM 单测 | `gradlew :app:testDebugUnitTest --tests io.legado.flutter.WebServerForegroundServiceTest --tests io.legado.flutter.LegadoNotificationIdsTest`（`--rerun-tasks`） | **BUILD SUCCESSFUL**；**11/11 passed**（服务 8 + 通知 ID 3），failures=0/errors=0 |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 前台服务建立（权限弹框→允许；FGS specialUse；通知栏；双锁按开关；health） | **PASS** | 权限框「要允许“阅读”向您发送通知吗？」→允许；`ServiceRecord{...WebServerForegroundService}` `isForeground=true foregroundId=7778 types=0x40000000`；通知 `id=7778 channel=legado_web_server` 标题「Web 服务运行中」；开关关 `Wake Locks: size=0`、开 `PARTIAL_WAKE_LOCK 'legado:WebService'` + `WifiLock{...type=4}`；`/api/health` 200 |
| 2 | 锁屏 LAN 10s/1min/5min（**复验上一轮 FAIL**） | **PASS** | 12 采样 ×3 curl = **36/36 HTTP 200**（04:20:29~04:25:33，`mWakefulness=Asleep`）；12/12 采样 `isForeground=true`、`Wake Locks: size=1`、Wi-Fi 锁在、pid 不变；回环 11/12 200；`netpolicy` UID 10066 `procState=FGS effective=NONE` |
| 3 | 切后台 HOME 30s/1min | **PASS** | 04:26:26 HOME 后 t+5s / t+35s / t+70s 各 3 次 curl **均 200**；`topResumedActivity=com.microsoft.launcher`，FGS 仍在，`procState=FGS effective=NONE` |
| 4 | 最近任务划掉（stopWithTask=false） | **PASS** | 04:27:51 划掉后 `dumpsys activity recents` 本包任务 **0**；pid 4889 存活、FGS `isForeground=true`、通知 `id=7778` 在栏（`13_notif_after_task_removal.png`）；curl 即时 3/3 + 45s 后 3/3 均 200；重开 WARM 160ms 同 pid，**未重复拉起 FGS** |
| 5 | 停止服务/再启动 | **PASS** | 停服：服务 `(nothing)`、通知记录 0、`curl=000`、`Wake Locks: size=0`、Wi-Fi 锁 0；重启：FGS specialUse 恢复、通知 7778 恢复、curl 200、PARTIAL 锁重新 acquire |
| 6 | 通知权限拒绝（revoke → 启动 → 不允许） | **PASS** | `pm revoke` 后启动：FGS `isForeground=true types=specialUse`、LAN 200×3、通知记录 **0**（通知栏「无通知」）、副题「通知权限未授予，前台通知不可见」+ SnackBar；`pm grant` 后重启恢复通知与正常副题 |
| 7 | 回归（Web 启停/设置页/书架阅读/TXT/OS 健康） | **PASS** | 4 次 FGS start / 4 次 stop 均成对；TXT 1,757 B 导入书架、阅读第 1 章 33.3%、目录 3 章、第 3 章 100.0%；FATAL=0、ANR=0、overflow=0、OOM=0 |
| 8 | 清理与恢复 | **PASS** | 停服、关唤醒锁、权限复原（随后 `pm clear` 归默认）、图标默认、旋转 1/0、`pm clear` 后 prefs 默认、空书架；保留 **2.0.431/432** |

## 三、逐场景证据

### 3.1 场景 1：前台服务建立（权限 → FGS → 通知 → 双锁 → health）

- **预期**：首次开启 Web 服务请求 Android 13+ 通知权限；允许后 FGS
  `specialUse` 处于前台、通知栏可见「Web 服务运行中」、双锁随开关、
  `/api/health` 200。
- **实际**：全部符合（见 1a~1d）。

#### 1a 首次通知权限弹框（Android 13+）

- 安装后 `POST_NOTIFICATIONS: granted=false`（全新状态）。
- 我的 → Web 服务卡片（`用浏览器写源或看书`，`checked=false`）点击后
  系统弹框（04:16:2x）：
  ```
  com.android.permissioncontroller: 要允许“阅读”向您发送通知吗？
  允许 [147,1014][933,1182] / 不允许 [147,1194][933,1362]
  ```
  （`02_perm_dialog.png`）；点「允许」后
  `POST_NOTIFICATIONS: granted=true, flags=[USER_SET|...]`。

#### 1b 前台服务与通知（04:20:12 采集）

```
ServiceRecord{d4c2bf8 u0 io.legado.flutter_legado/io.legado.flutter.WebServerForegroundService}
  intent={act=io.legado.flutter.action.WEB_SERVER_START ...}
isForeground=true foregroundId=7778 types=0x40000000
  foregroundNoti=Notification(channel=legado_web_server flags=ONGOING_EVENT|ONLY_ALERT_ONCE|NO_CLEAR|FOREGROUND_SERVICE vis=PUBLIC)
createTime=-3m13s885ms createdFromFg=true
startRequested=true stopIfKilled=true callStart=true lastStartId=1
```

- `types=0x40000000` 即 `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`；合并 Manifest 同步确认
  `foregroundServiceType="specialUse"`、`stopWithTask="false"`。
- 通知记录（`dumpsys notification --noredact`）：
  ```
  NotificationRecord(... pkg=io.legado.flutter_legado id=7778 ...)
    android.title=String (Web 服务运行中)
    android.text=String (局域网可访问)
  ```
  通知栏实测可见（`05_notification_shade.png`）：应用「阅读」、标题
  「Web 服务运行中」、正文「局域网可访问」、无声音/无震动（LOW 渠道）。

#### 1c 双锁按开关（UI 开关即时生效）

| 状态 | 时间 | `dumpsys power` | `dumpsys wifi` |
|---|---|---|---|
| 唤醒锁偏好 **关**（运行中，开关开启前） | 04:20 前 | `Wake Locks: size=0` | 无 `WifiLock{legado...}` |
| 打开「Web 服务唤醒锁」（其他设置） | 04:20:05 | `size=1`，`PARTIAL_WAKE_LOCK 'legado:WebService' ACQ=-2s183ms (uid=10066 pid=4889)` | `WifiLock{legado:WebService type=4 ...}`；log `acquireWifiLock uid=10066 lockMode=3` |
| 关闭开关（清理时） | 04:35 | `size=0`；prefs `flutter.webServiceWakeLock=false` | 无活动锁 |

#### 1d 健康检查与 UI

- UI 副题：`running on port 1122`（`04_webservice_running.png`）。
- 宿主 → 设备：
  ```
  curl -m 5 http://192.168.100.62:1122/api/health
  {"service":"legado-server","status":"ok","version":"0.2.0"}
  HTTP=200 time=0.001585
  ```

### 3.2 场景 2：锁屏 LAN（上一轮 FAIL 复验，12 采样/36 次 curl）

- **预期**：息屏后 10s/1min/5min 宿主与回环均 200，`netpolicy` 不再为纯
  `APP_BACKGROUND` 阻断。
- **实际**：12/12 采样、36/36 宿主请求 200；回环 11/12（1 次工具空输出）；
  `procState=FGS effective=NONE`。

- 04:20:26 `input keyevent 223`（KEYCODE_SLEEP）；t+3s 起
  `mWakefulness=Asleep`（截屏全黑 `08_lockscreen_hold.png`）。
- 采样脚本 `data/s2_lockscreen.sh` 每点记录：唤醒态 / `Wake Locks` /
  CPU 锁行数 / Wi-Fi 锁行数 / FGS 状态 / pid / **3 次宿主 curl** / 回环。

| 时间 | 距息屏 | 唤醒态 | CPU 锁 | Wi-Fi 锁 | FGS | pid | 宿主 curl ×3 |
|---|---|---|---|---|---|---|---|
| 04:20:29 | t+3s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:20:37 | t+10s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:20:48 | t+20s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:20:58 | t+30s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:21:09 | t+40s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:21:19 | t+50s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:21:30 | t+60s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:22:01 | t+90s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:22:31 | t+120s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:23:32 | t+180s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:24:33 | t+240s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |
| 04:25:33 | t+300s | Asleep | size=1 | 1 | true | 4889 | **200/200/200** |

- 汇总：**12/12 采样、36/36 宿主请求 HTTP 200**（全量
  `logcat/s2_lockscreen_series.log`）。
- 设备内回环：11/12 次返回
  `{"service":"legado-server","status":"ok","version":"0.2.0"}`；
  t+50s 一次 `nc` 输出为空（同刻宿主 3 次均 200，判定为 `nc`/超时竞态，
  非服务中断，见 §6.4）。
- 息屏期间（收尾采样：`mWakefulness=Asleep`、`PARTIAL_WAKE_LOCK ACQ=-6m12s777ms`）`dumpsys netpolicy`：
  ```
  UID=10066 state={procState=FGS ,seq=42338,cap=---NFUAT}
    blocked_state={blocked=APP_BACKGROUND,
      allowed=FOREGROUND|TOP|NOT_IN_BACKGROUND|METERED_FOREGROUND,
      effective=NONE}
  ```
  防火墙历史：04:15:58 首次启动时记录 `10066-background-allow`（允许）；
  息屏 04:20~04:25 期间**无新增** `10066-background-default` 阻断记录
  （对比上一轮 02:42 出现的 `10066-standby-default` / `10066-background-default`）。
- **与上一轮对比**：9b-6 息屏 13/13 `000/5.00s`、`effective=APP_BACKGROUND`；
  本轮 36/36 `200`、`procState=FGS effective=NONE` → **FAIL 项修复**。

### 3.3 场景 3：切后台 HOME（30s/1min）

- **预期**：按 HOME 后 30s/1min 宿主 curl 仍 200。
- **实际**：5s/35s/70s 各 3 次均 200，FGS 保持。

- 04:26:26 `input keyevent 3`（HOME）；`topResumedActivity` 变为
  `com.microsoft.launcher/.Launcher`（MuMu 桌面）。

| 时间 | 距 HOME | 宿主 curl ×3 | FGS | pid | netpolicy |
|---|---|---|---|---|---|
| 04:26:31 | t+5s | **200/200/200** | true | 4889 | — |
| 04:27:03 | t+35s | **200/200/200** | true | 4889 | `procState=FGS effective=NONE` |
| 04:27:37 | t+~70s | **200/200/200** | true | 4889 | `procState=FGS effective=NONE` |

（`logcat/s3_background_series.log`；`10_home_background.png`。首行 t+30s
采样因 QA shell 引号导致 adb 字段缺失，curl 仍 3/3 200，已在 t+35s 重采样补齐。）

### 3.4 场景 4：最近任务划掉（stopWithTask=false）

- **预期**：划掉任务后 FGS 与通知保留（`stopWithTask=false`），进程存活时
  宿主 curl 继续 200；若进程被杀则如实记录。
- **实际**：任务已移除、进程/FGS/通知均保留、curl 200；进程未被杀。

- 04:27:51 在最近任务中上滑划掉「阅读 Legado」卡片。
- 划掉后：
  - `dumpsys activity recents` 含本包任务数 **0**（`grep -c` = 0）；
  - `pidof io.legado.flutter_legado` = **4889**（进程存活）；
  - `dumpsys activity services`：`WebServerForegroundService`
    `isForeground=true foregroundId=7778`，`lastActivity` 未重置；
  - 通知记录 `id=7778 channel=legado_web_server` 仍在；通知栏可见
    「Web 服务运行中 / 局域网可访问」（`13_notif_after_task_removal.png`）；
  - 宿主 curl 划掉后即时 **3/3 200**，45s 后 **3/3 200**；
  - `netpolicy` UID 10066 `procState=FGS effective=NONE`。
- 重开 App：`am start -W` **WARM 160ms**、pid 仍 4889、FGS 仍 foreground；
  logcat 在 04:16:59 与 04:29:39 之间**无新的 FGS start 记录** →
  Dart `ensureStarted` 对账只查询、不重复拉起（`14_reopen_after_task_removal.png`）。

### 3.5 场景 5：停止服务 / 再启动

- **预期**：停服后 FGS/通知消失、端口关闭；再次启动恢复 FGS 与 LAN。
- **实际**：停服 `(nothing)`/通知 0/`curl=000`；重启 FGS+通知+200 恢复。

| 操作 | 时间 | 服务 | 通知 | 端口 | 锁 |
|---|---|---|---|---|---|
| 回 App 点卡片关闭 | 04:29:19 | `dumpsys activity services` → `(nothing)` | 记录 0（渠道定义保留，Android 预期） | `curl=000` ×3 | `Wake Locks: size=0`；Wi-Fi 锁 0 |
| 再次打开 | 04:29:40 | `isForeground=true foregroundId=7778 types=0x40000000` | `id=7778` 恢复，通知栏可见（`18_notif_shade_retry.png`） | `curl=200` ×3 | `PARTIAL_WAKE_LOCK 'legado:WebService' ACQ=-3s970ms` |

- UI 同步：关闭后副题回落「用浏览器写源或看书」`checked=false`；
  重启后 `running on port 1122` `checked=true`（`15/16` 截图）。
- logcat 配对：`am_foreground_service_start` 04:29:39.405 →
  `am_foreground_service_stop` 04:30:26.295；`acquireWifiLock`
  04:29:39.607 → `releaseWifiLock` 04:30:26.293。

### 3.6 场景 6：通知权限拒绝（降级仍可 LAN）

- **预期**：撤销/拒绝 `POST_NOTIFICATIONS` 后 FGS 仍运行、LAN 可达、通知不可见、
  UI 有提示；恢复权限后通知恢复。
- **实际**：全部符合（见 6a~6c）。

#### 6a 撤销权限（测试方法说明）

- `pm revoke io.legado.flutter_legado android.permission.POST_NOTIFICATIONS`
  后 `granted=false`；**系统随即杀死应用进程**：
  ```
  04:30:29.377 I/ActivityManager: Killing 4889:io.legado.flutter_legado/u0a66 (adj 0): permissions revoked
  ```
  （撤销运行时权限是 Android 平台行为，非应用崩溃；撤权前 Web 服务已停止，
  无孤儿 FGS。见 §6.2。）

#### 6b 拒绝路径（04:31:38 启动）

- 冷启动 314ms → Web 服务卡片（checked=false）→ 系统再次弹框
  （`20_perm_dialog_deny.png`）→ 点「不允许」。
- 结果（04:31:5x）：
  - FGS：`isForeground=true foregroundId=7778 types=0x40000000`（specialUse）；
  - LAN：宿主 `curl` **200/200/200**（0.0013/0.0011/0.0121s）；
  - 通知：`dumpsys notification` 中 `channel=legado_web_server` 记录 **0**；
    通知栏显示「无通知」（`22_shade_denied_no_notif.png`）；
  - UI 降级提示（`21_denied_running.png`）：
    副题 `running on port 1122 · 通知权限未授予，前台通知不可见`；
    SnackBar「通知权限未授予：Web 服务前台通知不可见（局域网访问不受影响）」；
  - 原生降级日志：`W/WebServerFgs: POST_NOTIFICATIONS 未授予：前台服务继续运行，通知仅见系统任务管理器（降级）`。

#### 6c 恢复权限（04:32）

- `pm grant ... POST_NOTIFICATIONS` → `granted=true`；停服（04:32:06）→
  重启（04:32:10）：通知 `id=7778` 恢复、通知栏可见
  （`23_shade_restored.png`）、副题恢复 `running on port 1122`
  （降级提示消失）、curl 200 ×3。

### 3.7 场景 7：回归

- **预期**：Web 启停、设置页、书架/阅读/TXT 正常；FATAL/ANR/overflow/OOM=0。
- **实际**：全部正常；四项计数均为 0（见 §四）。

- **Web 服务启停**：本会话 4 次 FGS start（04:16:59 / 04:29:39 / 04:31:46 /
  04:32:10）与 4 次 stop（04:29:19 / 04:30:26 / 04:32:06 / 04:34:31）成对；
  Wi-Fi 锁 acquire/release 逐对匹配；无重复 startForeground、无残留锁。
- **设置页**：我的 → 设置 → 高级（`OtherSettingsScreen`）→
  滚动至「Web 服务唤醒锁」开/关各一次；多级页面往返无异常。
- **书架/阅读/TXT**：`qa9b6c.txt`（1,757 B，UTF-8，3 章）经「添加本地」导入，
  书架显示 `qa9b6c`（`25_shelf_with_txt.png`）；打开阅读器第 1 章正文正常、
  进度 33.3%（`26_reader_ch1.png`）；目录页 3 章正确（`27_toc.png`）；
  跳转第 3 章 100.0%（`28_reader_ch3.png`）；返回书架正常
  （`29_shelf_after_reading.png`）。
- **OS 健康**：见 §四。

### 3.8 场景 8：清理与恢复

- **预期**：停服、释放锁、恢复权限/图标/旋转、prefs 默认、空书架，保留验收版本。
- **实际**：全部完成，版本保留 2.0.431/432。

| 项 | 结果 |
|---|---|
| Web 服务 | 04:34:31 已停止；`dumpsys activity services` → `(nothing)`；`curl=000` |
| 唤醒锁偏好 | 已关闭（`flutter.webServiceWakeLock=false`）；`Wake Locks: size=0` |
| 前台服务/通知 | 服务无；Web 渠道通知记录 0 |
| 通知权限 | 恢复后经 `pm clear` 归默认（`granted=false`，与全新安装一致） |
| 启动图标 | 未变更：`resolve-activity` → `io.legado.flutter.MainActivity` |
| 旋转设置 | `accelerometer_rotation=1`、`user_rotation=0`（原值，未改） |
| 应用数据 | `pm clear` **Success**；重启后 prefs 271 B 且无 `webService*`/`launcherIcon` 等键（默认值）；书架空（`31_clean_empty_shelf.png`） |
| 设备文件 | `/sdcard/Download/qa9b6c.txt`、`/sdcard/ui.xml` 已删除 |
| 版本 | 保留 **2.0.431 / 432**（`dumpsys package` 复核） |

## 四、FATAL / ANR 汇总

统计口径：`logcat -b all -d -v time` 全缓冲区 **30,557 行**（最早 10-28 21:33
起；含本批 04:15 构建安装至 04:37 清理的全部操作）。

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| 应用 native tombstone（`Cmdline: io.legado.flutter_legado`） | **0** |
| QA 工具 uiautomator tombstone（`Cmdline: uiautomator`） | 56（本会话；工具退出期 SIGSEGV，非应用，见 §6.3） |
| 进程非崩溃退出 | 3 次：installPackageLI（04:15:34）、`permissions revoked`（04:30:29）、`clear data`（04:35:26）——均为 QA 操作触发 |

## 五、证据清单（`tmp_debug/device_acceptance_20261101_batch9b6c/`）

| 类别 | 文件 |
|---|---|
| 构建 | `build_9b6c.log`（`flutter build apk --release` 全量输出，EXIT=0） |
| 会话日志 | `logcat/final_session_9b6c.log`（30,557 行，FATAL/ANR/overflow/OOM 统计源）、`full_session_9b6c.log`、`full_session_9b6c_partial.log` |
| 锁屏采样 | `logcat/s2_lockscreen_series.log`（12 条，04:20:29~04:25:33，含每点 3 次 curl/回环/锁/FGS） |
| 后台采样 | `logcat/s3_background_series.log`（HOME 后 t+30/35/70s） |
| 网络策略 | `logcat/netpolicy_screenoff.txt`（息屏 UID 10066 `procState=FGS effective=NONE`、防火墙历史） |
| dumpsys power | `logcat/power_s1_running.txt`、`power_screenoff.txt` |
| dumpsys wifi | `logcat/wifi_s1_running.txt`（`WifiLock{legado:WebService type=4}`） |
| dumpsys services | `logcat/s1_services.txt`、`s1_services_full.txt`、`services_screenoff.txt` |
| 通知 | `logcat/notif_after_restart.txt`、`notif_restored.txt`、`package_dump.txt` |
| UI 取证 | `data/ui_*.xml`（launch/my/settings/other/sc6/toc/reader 等）、`data/s2_lockscreen.sh`、`data/probe.sh`（QA 工具，未改业务代码） |
| 截图 | `shots/00~31`（32 张，含 `19_after_pm_revoke_process_killed.png`）；副本 `docs/materials_1101b/` |
| 回归夹具 | `data/qa9b6c.txt`（1,757 B，已从设备删除；本地留存） |

## 六、说明与遗留

### 6.1 P3：前台服务通知延迟约 10s 展示（系统侧，非本批缺陷）

- **现象**：每次 `startForegroundService` 后，`isForeground=true` 与 LAN 访问
  立即生效，但通知在通知栏出现约 **10.0s** 后。
- **证据**（3/3 均精确 10.0s，`logcat/final_session_9b6c.log`）：

| FGS start（`am_foreground_service_start`） | 通知入队（`notification_enqueue`） | 差值 |
|---|---|---|
| 04:16:59.009 | 04:17:09.016 | 10.007s |
| 04:29:39.405 | 04:29:49.412 | 10.007s |
| 04:32:10.038 | 04:32:20.046 | 10.008s |

  通知记录的 `when=1793478579404`（04:29:39.404）与 startForeground 调用
  同时刻，说明应用侧已即时提交；延迟发生在系统通知入队/展示侧。三次均在
  应用前台触发、固定 +10.0s，**推断**为系统侧「前台服务通知延迟展示」策略
  （具体以 Android 版本行为为准，本次未改代码验证）。
- **影响**：不影响 FGS 提权、锁屏/后台 LAN、停服清理；仅「通知栏可见」有
  ~10s 滞后。本轮截图均在服务启动 10s 后采集，可见性已证实。
- **建议**：如需「立即可见」，可产品侧评估是否需要改为非延迟的通知渠道
  策略；不阻塞本批验收。

### 6.2 P3：`pm revoke` 通知权限导致系统杀进程（平台行为）

- 04:30:29 `pm revoke POST_NOTIFICATIONS` 立即触发
  `Killing 4889 ... permissions revoked`（Android 撤销危险权限的标准行为）。
- 该操作发生在 Web 服务已停止之后，未产生孤儿 FGS；随后冷启动重新验证
  拒绝路径（§3.6）。记录此现象以免误判为崩溃（logcat FATAL=0）。
- 真实用户经系统设置撤销通知权限时同样会杀进程，但 FGS/服务随进程退出，
  无残留通知/锁（清理路径已由场景 5/8 覆盖）。

### 6.3 P3：uiautomator 工具 tombstone 56 条（QA 工具，非应用）

- `logcat -b crash` 中 191 条 `Cmdline: uiautomator`（其中本会话 04:xx 共
  56 条），均为 uiautomator 退出时 `__cxa_finalize`/`exit` 的 SIGSEGV；
  同期所有 `uiautomator dump` 均成功产出 XML。
- 应用自身 native tombstone **0**；FATAL EXCEPTION **0**。属 MuMu 环境
  uiautomator 工具问题，登记不计入应用缺陷。

### 6.4 P3：回环 `nc` 单次空输出（测试工具竞态）

- 息屏 t+50s 采样中设备内 `nc 127.0.0.1 1122` 输出为空；同刻宿主 3 次
  curl 全 200、FGS/锁/进程均正常，其余 11 个采样回环均 200。
- 判定为并发 dumpsys + nc 在 5s 超时内的工具竞态，不是服务中断；已如实
  记录，不按 PASS 覆盖该次空输出。

### 6.5 specialUse 上架申报义务（登记）

- 服务类型用 `specialUse`（规避 Android 15 `dataSync` 累计 6 小时限制），
  代码注释已登记：上架 Google Play 需在 Play Console 申报该用途；
  本地侧载/企业分发不受影响。本批未因此阻塞。

### 6.6 与上一轮（9b-6）FAIL 的对照

| 项 | 9b-6（2.0.430/431） | 9b-6c（2.0.431/432） |
|---|---|---|
| 息屏宿主 curl | 13/13 `000/5.00s` | **36/36 `200`** |
| 息屏 netpolicy | UID 10066 `effective=APP_BACKGROUND` | `procState=FGS effective=NONE` |
| 切后台 30s | `000/5.00s` | `200`（5s/35s/70s） |
| 机制 | 仅 CPU+Wi-Fi 唤醒锁 | 前台服务 specialUse + 唤醒锁 |
| 结论 | FAIL（P2） | **PASS** |

## 七、结论

- 场景 1（权限弹框→允许、FGS specialUse、通知可见、双锁按开关、health 200）：**PASS**。
- 场景 2（锁屏 10s/1min/5min LAN，36/36 200；回环；netpolicy FGS/允许）：**PASS**（上一轮 FAIL 修复）。
- 场景 3（HOME 后台 5s/35s/70s 均 200）：**PASS**。
- 场景 4（任务划掉：任务 0、进程/FGS/通知保留、curl 200、无重复拉起）：**PASS**。
- 场景 5（停服撤 FGS/通知、端口关闭、重启恢复）：**PASS**。
- 场景 6（通知权限拒绝：FGS/LAN 正常、通知不可见、UI 提示、恢复权限）：**PASS**。
- 场景 7（启停/设置/书架阅读/TXT；FATAL=0、ANR=0、overflow=0、OOM=0）：**PASS**。
- 场景 8（停服、关锁、权限/图标/旋转复原、prefs 默认、空书架、保留版本）：**PASS**。

**问题分级**：P1=0；P2=0；P3=3（§6.1 通知延迟 10s 展示、§6.2 `pm revoke`
杀进程、§6.3 uiautomator tombstone）+ 1 项工具竞态记录（§6.4）。

编写者：QA（ZCode 子代理）｜ 2026-11-01
