# 批 40 设备验收报告（WebDAV 备份上传 / 保留清理 / 自动备份 / 导入后自动上传）

> 范围：批 40 与 40b（`13932be3fe` 接线、`78be9dc81f` / `c5a4445fad` 审查回修、
> `1c4fbd50aa` / `08fc8d5582` 登记），版本 **2.0.420+421**。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，执行前实测在线，adbd `uid=0`）。
>
> **结论**：场景 1~6 全部 **PASS**；清理与恢复完成（附 1 项清理副作用，见 §七）。
> 全流程应用侧 FATAL=0、ANR=0。
>
> 验收方式：宿主独立 Python Mock WebDAV（Basic Auth / PUT / PROPFIND / DELETE / GET），
> 应用 release 包真实 UI 操作；未改动任何业务代码。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15 |
| 分辨率 / 密度 | 1080x1920 / 480dpi |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，可直接读写应用私有目录、DB 与偏好） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.418** / versionCode **419** |
| 验收版本 | versionName **2.0.420** / versionCode **421**（`dumpsys package` 确认） |
| 源码基线 | `master` HEAD `4e382549de`（`chore: 批40 收尾（2.0.420+421 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-30 04:36 ~ 05:18（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261029_batch40/`（`tmp_debug/` 不入库） |

### 1.1 构建与安装

| 步骤 | 命令 | 结果 |
|---|---|---|
| Rust FFI | `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release` | **EXIT=0**（40.39s，三 ABI 均产出并拷入 `jniLibs`），`build_rust.log` |
| Flutter APK | `cd flutter_legado && flutter build apk --release` | **EXIT=0**，`√ Built build\app\outputs\flutter-apk\app-release.apk (189.2MB)`，`build_apk.log` |
| APK 摘要 | `sha256sum app-release.apk` | `9a754644e4e6e31873bc2ea49f7ff435e709b8870d1c7f74e0ef6027864bc250`（198,380,824 字节），`apk_sha256.txt` |
| 安装 | `adb install -r .../app-release.apk` | `Success: streamed 198380824 bytes` |
| 版本确认 | `dumpsys package` | 2.0.420 / 421（`final_version.txt`） |

### 1.2 升级前备份与测试数据

| 数据 | 内容 / 路径 | 用途 |
|---|---|---|
| 升级前本地备份 | 应用 2.0.418「备份」生成的 `/sdcard/Download/legado/legado_backup_1793306323198.json`（6,850 B，含 96 条 `appPrefs`） | 升级前 DB/偏好备份；验收后经应用本地恢复回滚 |
| 根权限快照 | `/data/data/io.legado.flutter_legado/app_flutter/legado.db`（299,008 B）与 `shared_prefs/FlutterSharedPreferences.xml`（8,108 B） | 测试前状态留档（`pre_upgrade/raw_snapshot/`） |
| 测试书 | `/sdcard/Download/qa40_import{,2,3,4}.txt`（209 / 98 / 117 / 105 B，UTF-8，含中文正文） | 导入后自动上传四组用例 |
| 回滚备份 | `/sdcard/Download/qa40_preupgrade_restore.json`（即升级前备份副本） | §六 本地恢复与清理 |
| Mock WebDAV | `mock_webdav.py`（0.0.0.0:18082）；`mock_blackhole.py`（0.0.0.0:18083，接受连接后挂起） | 上传/列举/删除/保留清理/超时用例 |

- Mock 支持 Basic Auth（任意账号均接受，缺失 `Authorization` 返回 401）、`PUT`
  （写入 `mock/remote/` 并记录）、`PROPFIND`（207 + `d:href`/`displayname`/
  `getcontentlength`/`getlastmodified`/`getetag`/`resourcetype`，Depth 0/1）、
  `DELETE`、`GET`；请求日志 `mock/requests.log`（JSON 行），远端清单
  `mock/remote_manifest.txt`。
- 设备到宿主 LAN（`192.168.100.52:18082`）用 `toybox nc` 实测 207 可达；
  `adb reverse` 仅作备用，验收结束已移除。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | WebDAV 备份上传：在线成功 / 断开 mock 失败提示且 `lastBackup` 更新 | **PASS** | `07_s1_backup_snack.png`、`burst2/f33.png`、`mock/requests.log`（PUT 2 次） |
| 2 | 保留清理：keep=1 只留最新 / keep=0 不删 / 超范围 clamp | **PASS** | `mock/requests.log`（DELETE×4）、`11_s2_after3.png`、`13_s2_clamp_reject.png` |
| 3 | 自动备份：关闭不触发 / 1 天到期触发 / 本地失败不写 `lastBackup` / 恢复互斥 | **PASS** | `18_s3b_auto_trigger.png`、`21_s3d_busy_prompt.png`、`prefs` 直读 |
| 4 | 导入后自动上传：默认关 / 开启成功并回写 `webDav::` / 未配置跳过 / 失败不影响导入 | **PASS** | `30/35/36/37` 截图、DB `books.origin`、`mock/requests.log` |
| 5 | 超时/异常：不可达 15s、挂起 60s 内返回错误、可再次发起 | **PASS** | `burst3/b06.png`、`38_s5_retry_ok.png`、耗时记录 |
| 6 | 回归：本地备份/恢复、书架/阅读器/设置、FATAL=0、ANR=0 | **PASS** | `39_s6_reader.png`、`41_s6_restore_done.png`、`logcat_full.log` |
| 7 | 清理：恢复 DB/偏好、删除测试书与远端文件、停 mock/移除 reverse | **PASS（附 1 项副作用）** | `final_db_state.txt`、`final_prefs.xml`、`remote_archive/`；§七.1 |

## 三、场景明细

### 3.1 场景 1：WebDAV 备份上传

**在线成功（PASS）**

- 配置：URL `http://192.168.100.52:18082`、账号 `qa`、密码 `qa123456`、子目录
  `/legado/`；「测试配置」显示 `✓ 连接成功`（`06_test_config.png`，Mock 收到
  `PROPFIND / Depth:0` 207）。
- 04:42:35 点击「备份」：Mock 收到
  `PUT /legado/backup_20261030_044235_346.json`（7,179 B，`auth=qa:qa123456`，201）；
  本地生成 `/storage/emulated/0/Download/legado/legado_backup_1793306555341.json`
  （7,179 B）；SnackBar 同时显示「备份成功…」与「已上传 WebDAV：backup_20261030_044235_346.json」
  （`07_s1_backup_snack.png`）。远端文件为合法 JSON（含 99 条 `appPrefs`）。
- 保留数量为 0（默认）时上传后不发 PROPFIND/DELETE，符合设计。

**Mock 断开（PASS）**

- 停掉 18082 后点击「备份」：约 14~15s（连接超时上限 15s）后 SnackBar 显示
  「备份成功：…/legado_backup_XXXX.json」+「WebDAV 上传失败：error sending request for url
  (http://192.168.100.52:18082/legado/backup_…json)」（`burst2/f33.png`）；本地文件存在、
  远端无新增；`lastBackup` 由 `1793306555355` 更新为 `1793306660656`（随后两轮失败备份继续更新，
  直读 `shared_prefs` 取证）。

### 3.2 场景 2：保留清理

- **keep=1**：UI 设为 1 后连续备份 3 次（04:47:42 / 04:47:51 / 04:48:00）。每次流程为
  `PUT 新文件 → PROPFIND Depth:1 → DELETE 上一份`；最终远端仅剩
  `backup_20261030_044800_777.json`（当前文件，排除在删除集合之外）；DELETE 共 4 条
  （首轮删除此前积压 2 份，其后每轮 1 份）。
- **keep=0**：改回 0 后备份 1 次（04:48:57），只有 PUT，无 PROPFIND/DELETE，远端保留 2 份。
- **超范围**：
  - UI 输入 `1001` → SnackBar「请输入 0~1000 的整数」，值不落盘（`13_s2_clamp_reject.png`）；
  - 输入 `-1` → 同样拒绝；
  - 输入 `500` → 接受，副标题「500（仅保留最近 500 份）」，偏好值为 `500`；
  - 停机后直接把偏好写成 `5000` 再启动，页面显示「1000（仅保留最近 1000 份）」，
    证明读取侧 clamp 上限生效（`getWebDavBackupKeepCount`）。

### 3.3 场景 3：自动备份

- **间隔 0 / 关闭**：配置对话框不接受间隔 0，输入 0 提交显示内联错误
  「请输入大于 0 的整数」（`16_s3_interval0_reject.png`）；关闭入口是「启用自动备份」
  开关。关闭后清空 `lastBackup` 再启动，12s 内无新本地备份、无 PUT、`lastBackup` 仍不存在。
- **1 天到期触发**：开启自动备份（本地 + WebDAV，间隔 1 天）并清空 `lastBackup`
  后启动：04:52:37 自动生成 `legado_backup_1793307157349.json` 并
  `PUT /legado/backup_20261030_045237_347.json`（7,303 B），`lastBackup=1793307157347`；
  无任何 UI 打扰（`18_s3b_auto_trigger.png`）。
- **失败不写 `lastBackup`**：把备份路径改为不可写的 `/system/qa_batch40_invalid`、清空
  `lastBackup` 后启动；14s 后无新文件、无 PUT、`lastBackup` 仍不存在，应用未崩溃。
  （说明：本地备份成功后上传失败会写 `lastBackup`，是批 40 已登记的既有语义；
  本用例验证的是**本地备份失败**路径。）
- **恢复进行中不触发**：Mock 断开时发起 WebDAV 短按恢复（连接等待 15s+），恢复期间
  HOME→回前台触发调度；备份文件数保持 15、PUT 保持 7、`lastBackup` 不变（被 busy 跳过）。
  恢复结束后再次回前台作对照：文件数 15→16、`lastBackup` 更新，证明调度确实在运行。
- **互斥提示**：自动备份在途（Mock 断开、上传等待中）时手动点「备份」，立即出现
  「正在备份或恢复，请稍候」（`21_s3d_busy_prompt.png`）。

### 3.4 场景 4：导入后自动上传

- **默认关**：升级后 `webDavBookAutoUpload` 偏好键不存在（默认 false），开关行
  `checked=false`；导入 `qa40_import.txt` 成功、无 PUT、`books.origin=loc_book`。
- **开启 + 已配置**：打开开关（偏好写入 `true`）后导入 `qa40_import2.txt`：Mock 收到
  `PUT /legado/books/qa40_import2.txt`（98 B，201）；DB 回写
  `origin=webDav::http://192.168.100.52:18082/legado/books/qa40_import2.txt`（`35_s4_import2_autoupload.png`）。
- **未配置 WebDAV**：把 `servers` 默认行 URL 置空后导入 `qa40_import3.txt`：导入成功、
  无 PUT、`origin=loc_book`、无错误提示（`36_s4_import3_noconfig.png`）。
- **上传失败**：停 Mock 后导入 `qa40_import4.txt`：书籍立即出现在书架、19s 后
  `origin` 仍为 `loc_book`、无 PUT、应用无崩溃（自动上传失败仅日志）。

### 3.5 场景 5：超时/异常

| 形态 | 操作 | 结果 |
|---|---|---|
| 端口不可达（connect refused/被丢弃） | 停 Mock 后手动备份 | 约 14~15s 返回失败（连接超时 15s），本地备份成功，`lastBackup` 更新 |
| 接受连接但永不响应 | `mock_blackhole.py:18083`，手动备份 | 05:07:06 发起 → 05:08:06 返回失败（请求总超时 60s），本地成功、`lastBackup` 更新；`burst3/b06.png` 为失败提示 |
| 超时后恢复能力 | 切回 18082 立即再次备份 | 正常完成：`PUT /legado/backup_20261030_050903_182.json`（10,299 B，201），无锁残留（`38_s5_retry_ok.png`） |

- 书籍上传的 600s 传输超时未做「挂起满 10 分钟」实测（时间成本过高）；代码口径见
  `rust/legado-net/src/webdav.rs` 的 `TRANSFER_TIMEOUT`。不可达形态的上传失败已在场景 4 覆盖。

### 3.6 场景 6：回归

- 本地备份：本场景及前述共执行 10+ 次，均成功产出 JSON（7,179~10,299 B）。
- 本地恢复：长按「恢复」选择升级前备份并确认，恢复完成后 96 条 `appPrefs` 全部按备份值
  落地（逐键比对一致）；书籍按「存在则更新、不存在则插入」恢复（与原版
  `Restore.kt` 的 additive 语义一致，不删除备份外的书），应用未崩溃。
- 书架：升级前后书架均正常展示；测试书导入/删除后列表刷新正常（`30/35/36/37/42` 截图）。
- 阅读器：打开 `qa40_import2` 成功渲染「第一章 验证」正文（`39_s6_reader.png`）。
- 设置：外观/高级/备份与恢复/自动备份对话框/保留数量对话框/导入开关均可正常进入与操作。
- FATAL/ANR：`logcat_full.log`（04:36~05:18 全程）无 `FATAL EXCEPTION` / `ANR in
  io.legado.flutter_legado`；`logcat -b crash` 中应用进程 0 条（仅 `uiautomator`/`grep`
  工具自身 SIGSEGV，属既有工具噪声）；`dumpsys dropbox` 在 2026-10-30 无应用 crash/ANR
  记录（历史条目均为 2.0.391 旧版本，非本次验收）。

## 四、清理与恢复

| 项 | 结果 |
|---|---|
| DB 恢复 | 删除 4 本测试书及其 `chapters`/`readRecord` 行；`books=1`（`QA38验收本地书`）、`servers=0`（`final_db_state.txt`） |
| 偏好恢复 | 升级前备份的 96 条 `appPrefs` 经应用本地恢复写回；批 40 测试键（`webDavBackupKeepCount`/`webDavBookAutoUpload`/`autoBackup*`/`lastBackup`）已删除；最终页面 WebDAV 地址为空、保留数量 0、导入自动上传关（`43/44` 截图） |
| 设备测试文件 | 删除 `/sdcard/Download/qa40_import*.txt`、`qa40_preupgrade_restore.json`、`presnap_*`、本次产生的 `legado_backup_1793306xxx~1793480xxx` 等备份 |
| 远端文件 | 已归档到 `remote_archive/`（4 份备份 + `books/qa40_import2.txt` 与 manifest/请求日志），随后清空 `mock/remote/legado/` |
| Mock / 端口 | 18082、18083 均已停止；`adb reverse --remove-all` 已执行 |
| 最终启动 | 应用重启后书架仅 1 本 QA38 书；默认自动备份按预期在首次启动生成 1 份本地备份 `legado_backup_1793308643798.json` 并写入 `lastBackup`（新版本设备级键，属正常行为） |

## 五、遗留问题与说明

1. **清理副作用（需登记）**：清理脚本用设备 shell 做大整数比较（`[ ts -ge 1793306000000 ]`），
   该 ROM 的 shell 按 32 位截断，导致**升级前已存在的**
   `/sdcard/Download/legado/legado_backup_1793051898410.json`（2026-10-27 05:58，4,287,249 B）
   被误删，宿主无副本。该文件为上一轮 QA 备份产物（非用户书籍/进度数据），但仍属超出
   「只删测试文件」范围的副作用；后续清理脚本应改用宿主侧判断或规避大整数比较。
2. **保留数量 UI 语义**：超上限输入是**拒绝并提示**（0~1000），服务/读取侧才做 clamp；
   任务描述的「clamp」在用户输入路径表现为拒绝，读取路径（直接写入 5000 → 显示 1000）
   clamp 生效。
3. **自动备份「间隔 0」**：配置对话框不接受 0（提示 >0），关闭语义由独立开关承担；
   与任务文字「设置间隔 0（关）」不完全一致，行为本身安全（不会误触发）。
4. **上传失败写 `lastBackup`**：本地备份成功后上传失败仍写 `lastBackup`，续期到下一周期
   再补传；与批 40 已登记语义一致（非本批回归）。
5. **书籍上传 600s 超时**未做满时长实测；不可达/失败路径已覆盖。
6. 自动备份、导入后上传均为**应用内调度**，非系统后台任务；应用进程被杀后不会触发
   （批 40 已登记）。

## 六、证据文件索引

`tmp_debug/device_acceptance_20261029_batch40/`：

- 构建/版本：`build_rust.log`、`build_apk.log`、`apk_sha256.txt`、`final_version.txt`
- 升级前：`pre_upgrade/legado_backup_preupgrade_2.0.418.json`、`pre_upgrade/raw_snapshot/{legado.db,FlutterSharedPreferences.xml}`、`pre_upgrade/version_before.txt`
- Mock：`mock_webdav.py`、`mock_blackhole.py`、`mock/requests.log`（PROPFIND×10 / PUT×9 / DELETE×4）、`mock/put_manifest.log`、`remote_archive/`
- 截图：`06_test_config.png`、`07_s1_backup_snack.png`、`burst2/f33.png`、`11_s2_after3.png`、`13_s2_clamp_reject.png`、`16_s3_interval0_reject.png`、`18_s3b_auto_trigger.png`、`21_s3d_busy_prompt.png`、`30/35/36/37_s4_*.png`、`burst3/b06.png`、`38_s5_retry_ok.png`、`39_s6_reader.png`、`41_s6_restore_done.png`、`42_final_bookshelf.png`、`43_final_webdav_top.png`、`44_final_backup_section.png`
- 状态：`final_db_state.txt`、`final_prefs.xml`、`prefs_after_restore2.xml`、`logcat_full.log`
- 工具：`ui.py`（uiautomator dump + 坐标驱动，仅测试用）

编写者：QA ｜ 2026-10-30
