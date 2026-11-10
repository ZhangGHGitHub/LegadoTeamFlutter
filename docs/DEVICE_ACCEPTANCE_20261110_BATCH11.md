# 批11 备份/恢复选择式 Sheet — 设备验收报告

验收日期：2026-11-10
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改仓库代码）
证据目录：`D:/OH-WorkSpace/LegadoTeam/legado/docs/materials_1110b/`

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu「Test测试」，`192.168.100.62:5555`，状态 `device` |
| 机型 / 系统 | SM-G9900（MuMu 模拟），Android 15（API 36） |
| 分辨率 / 密度 | 1080x1920，480dpi |
| 被测包 | `io.legado.flutter_legado`（另有 `com.legado.app.release` 未触碰） |
| APK 路径 | `D:/OH-WorkSpace/LegadoTeam/legado/flutter_legado/build/app/outputs/flutter-apk/app-release.apk` |
| APK 大小 / 构建时间 | 210,440,436 字节 / 2026-11-10 12:06 |
| APK sha256 | `d3674b01dcb3e7b4ef8196217d67416be3ceeb52eaa96fcafa0a9b8bb32e1aac` |
| APK badging（aapt2 36.1.0） | `versionCode='480' versionName='2.0.479'` |
| 设备实测版本（dumpsys） | `versionCode=480 versionName=2.0.479` |
| 声明目标版本 | `2.0.480+481`（`flutter_legado/pubspec.yaml` 第 4 行） |
| 宿主 WebDAV | wsgidav 4.4.0 / Cheroot 11.1.2，`http://0.0.0.0:8090`，匿名可写，根目录 `C:/Users/admin/AppData/Local/Temp/legado_dav` |
| 设备侧 WebDAV 配置 | 地址 `http://192.168.100.52:8090/`，账号/密码留空，子目录 `/legado/`（匿名回归） |
| 本地备份路径 | `/storage/emulated/0/Download/legado_b11` |

> 版本说明：构建产物实际为 `2.0.479+480`，与任务声明的 `2.0.480+481` 不一致（见问题 1）。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 15 |
| FAIL | 0 |
| BLOCKED | 1（第 14 项忙碌态） |
| 合计 | 16 |

结论：批11「备份/恢复选择式 Sheet」在设备上功能主路径全部通过；未发现崩溃、ANR、Flutter error 或布局溢出。存在 1 项中等级构建版本不一致、1 项中等级禁用逻辑不一致、1 项低等级陈旧状态展示；忙碌态（第 14 项）无法取证，记为 BLOCKED，不声明通过。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1110b/`） | 说明 |
| --- | --- | --- | --- |
| A1 备份 Sheet 结构与关闭 | PASS | `tmp_qb11_18_backup_sheet.png`、`tmp_qb11_19_backup_sheet_dismiss_mask.png`、`tmp_qb11_20_backup_sheet_dismiss_back.png` | 标题「备份」；三项顺序为 备份至本地 / 备份至网络 / 备份至本地与网络；无取消按钮；点遮罩、按返回均关闭成功 |
| A2 备份至本地 | PASS | `tmp_qb11_21_backup_local_toast.png`、`tmp_qb11_22_backup_local_after.png` | Toast「备份成功: /storage/emulated/0/Download/legado_b11/legado_backup_1794283914123.json」；目录出现 `legado_backup_*.json`（747B） |
| A3 备份至网络 | PASS | `tmp_qb11_23_backup_network_toast.png`、`tmp_qb11_24_backup_network_after.png`、`wsgidav_b11.log` | Toast「备份成功: 已上传 WebDAV: backup_20261110_121211_429.json」；本地目录无新增；服务器新增 747B 文件；wsgidav 记录 PUT 201 |
| A4 备份至本地与网络 | PASS | `tmp_qb11_25_backup_both_toast.png`、`tmp_qb11_26_backup_both_after.png`、`wsgidav_b11.log` | 合并 Toast 同时列出本地文件与 WebDAV 文件；本地 `legado_backup_1794283949895.json` 与服务器 `backup_20261110_121229_900.json` 均新增（本地受「仅保留最新备份」影响替换旧文件） |
| A5 长按备份行 | PASS | `tmp_qb11_27_backup_longpress_toast.png`、`tmp_qb11_28_backup_longpress_after.png`、`wsgidav_b11.log` | 长按直接执行本地+网络，无 Sheet；本地 `legado_backup_1794283970658.json`、服务器 `backup_20261110_121250_663.json` 均生成 |
| B6 恢复 Sheet 结构与关闭 | PASS | `tmp_qb11_30_restore_sheet.png`、`tmp_qb11_31_restore_sheet_dismiss_mask.png`、`tmp_qb11_32_restore_sheet_dismiss_back.png` | 标题「恢复」；四项顺序为 本地恢复 / 网络恢复 / 本地最新 / 远端最新；无取消按钮；遮罩与返回均可关闭 |
| B7 网络恢复 | PASS | `tmp_qb11_33_remote_list.png`、`tmp_qb11_34_restore_confirm.png`、`tmp_qb11_35_restore_success_toast.png`、`tmp_qb11_36_restore_after.png`、`tmp_qb11_71_bookshelf_after_restore.png`、`wsgidav_b11.log` | 远端列表标题「选择远端备份」，按名称降序（121250 > 121229 > 121211 > 035000 …）且显示时间；选择最新项后弹「确认恢复吗？」（含文件名与覆盖说明）；确认后 Toast「恢复成功」；返回书架可见恢复后的空书架状态，页面正常刷新 |
| B8 本地最新 | PASS | `tmp_qb11_37_local_latest_confirm.png`、`tmp_qb11_38_local_latest_toast.png`、`tmp_qb11_39_local_latest_after.png` | 直接选中本地最新备份并弹确认；确认后 Toast「恢复成功」 |
| B9 远端最新 | PASS | `tmp_qb11_40_remote_latest_confirm.png`、`tmp_qb11_41_remote_latest_toast.png`、`tmp_qb11_42_remote_latest_after.png`、`wsgidav_b11.log` | 确认框明确显示最新远端文件 `backup_20261110_121250_663.json`；确认后 Toast「恢复成功」；wsgidav 记录对应该文件 GET 200 |
| B10 本地恢复 | PASS | `tmp_qb11_43_local_restore_picker.png` | 打开系统文件选择器，定位 `Download/legado_b11` 并可见 `legado_backup_*.json`；未完成恢复（按清单要求） |
| B11 长按恢复行 | PASS | `tmp_qb11_45_restore_longpress_picker.png` | 长按恢复行同样直接弹出系统文件选择器（快捷保留），无 Sheet |
| C12 未配置 WebDAV | PASS（含 1 项观察） | `tmp_qb11_50_addr_empty_saved.png`、`tmp_qb11_54_backup_sheet_disabled.png`、`tmp_qb11_55_restore_sheet_disabled.png`、`tmp_qb11_56_backup_both_no_webdav.png`、`tmp_qb11_57_backup_both_no_webdav_after.png` | 清空地址后：备份 Sheet「备份至网络」置灰并显示「请先配置 WebDAV」；恢复 Sheet「网络恢复」「远端最新」置灰并显示「请先配置 WebDAV」。**但「备份至本地与网络」未置灰**，点击后静默只做本地备份（仅提示本地成功，无网络原因说明），见问题 2 |
| C13 仅填地址（匿名回归） | PASS | `tmp_qb11_59_addr_reset.png`、`tmp_qb11_68_backup_sheet_enabled.png`、`tmp_qb11_69_restore_sheet_enabled.png`、`tmp_qb11_70_remote_list_enabled.png` | 仅填 `http://192.168.100.52:8090/`（账号/密码空）后，备份 Sheet 网络项与恢复 Sheet 两个网络项全部恢复可用；点「网络恢复」成功加载远端列表 |
| C14 忙碌态 | BLOCKED | 无 | 备份/恢复均在约 1 秒内完成，截图命令本身约 1 秒延迟，无法稳定捕获忙碌/进行中状态；详见问题 5。不声明通过 |
| D15 稳定性 logcat | PASS | `logcat_b11.txt`、`logcat_b11_after_clear.txt` | 验收结束抓取 19,317 行；`FATAL EXCEPTION=0`、`ANR in=0`、`E/flutter=0`、`overflowed=0`、`E AndroidRuntime=0`；清理后冷启动再抓 19,231 行，五项仍全为 0 |
| D16 清理与空书架启动 | PASS | `tmp_qb11_72_after_clear_empty_shelf.png` | `pm clear` 返回 Success；`am start -W` 返回 `Status: ok / COLD / TotalTime 392ms`；截图确认空书架可正常启动 |

## 四、发现的问题（分级）

### 问题 1（中）：构建产物版本与声明不一致
- 现象：任务声明被测版本为 `2.0.480+481`，实际 APK badging 与设备安装版本均为 `versionName=2.0.479 / versionCode=480`；仓库 `pubspec.yaml` 为 `2.0.480+481`。
- 影响：无法严格证明验收对象就是声明的目标构建；本批功能点在当前产物上均可见，但版本溯源存在缺口。
- 复现：`aapt2 dump badging app-release.apk | head -1`；`adb shell dumpsys package io.legado.flutter_legado | grep version`。
- 建议：确认构建流水线版本注入/时间戳；如需目标版本，重新构建后复验并更新 sha256。
- 证据：报告环境表；`tmp_qb11_evidence_listing.txt` 第一节。

### 问题 2（中）：未配置 WebDAV 时「备份至本地与网络」未置灰且静默跳过网络
- 现象：清空 WebDAV 地址后，备份 Sheet 中「备份至网络」正确置灰并提示「请先配置 WebDAV」，但「备份至本地与网络」保持可用；点击后仅生成本地备份，Toast 仅显示本地成功，未提示网络部分被跳过。
- 期望：与「备份至网络」一致地置灰并显示原因，或在点击时明确提示「网络未配置，已仅备份到本地」。
- 实际：`tmp_qb11_56_backup_both_no_webdav.png` / `tmp_qb11_57_backup_both_no_webdav_after.png`；本地新增 `legado_backup_1794284348193.json`，服务器无新增（对照 `tmp_qb11_evidence_listing.txt`）。
- 证据：`tmp_qb11_54_backup_sheet_disabled.png`（该项未置灰）、`tmp_qb11_56...png`、`tmp_qb11_57...png`。

### 问题 3（低）：清空地址后「测试配置」仍显示陈旧的「✓ 连接成功」
- 现象：WebDAV 地址清空并保存后，「测试配置」行仍保留上一次测试的「✓ 连接成功」状态，可能误导用户以为当前配置可用。
- 证据：`tmp_qb11_50_addr_empty_saved.png`；对比有地址时的 `tmp_qb11_48_top.png`。
- 建议：地址/账号/密码变更时重置测试配置状态为「未测试」。

### 问题 4（观察，不计缺陷）：本地/远端备份文件命名与保留策略
- 本地为 `legado_backup_<epochMillis>.json`，远端为 `backup_YYYYMMDD_HHMMSS_mmm.json`，与清单预期 `legado_backup_*.json` / `backup_*.json` 相符。
- 「仅保留最新备份」默认开启，本地目录始终只保留 1 个文件（观察到旧文件被替换），属预期行为，非缺陷。

### 问题 5（BLOCKED，第 14 项）：忙碌态无法取证
- 原因：备份/恢复在测试数据量下约 1 秒内完成，`adb exec-out screencap` 自身耗时约 1 秒，无法在同一命令序列中稳定捕获 Sheet 的忙碌/禁用中间态；未发现持续可见的忙碌指示控件。
- 影响：无法证明忙碌态 UI 正确性；该项不声明通过。
- 建议：在可注入延迟的 debug 构建中复验，或使用屏幕录制（`screenrecord`）截取执行过程。

### 补充观察（非缺陷）
- Android SAF 选择器禁止直接使用 `Download` 根目录（提示「无法使用此文件夹」），需选择子目录；本次已使用 `Download/legado_b11`，属系统限制。
- 恢复确认框文案、Toast 文案与清单一致；无遮罩误触导致的异常。

## 五、设备终态

| 项目 | 状态 |
| --- | --- |
| 应用数据 | 已 `pm clear io.legado.flutter_legado` 清理（Success） |
| 应用进程 | 冷启动成功，`Status: ok`，`TotalTime 392ms`，显示空书架 |
| 安装包 | 仍安装 `io.legado.flutter_legado` 2.0.479 (480)；`com.legado.app.release` 未触碰 |
| 设备连接 | `adb devices` 显示 `192.168.100.62:5555 device` |
| WebDAV 服务 | 已停止（taskkill PID 88848，端口 8090 不再监听） |
| 测试残留 | 设备本地 `Download/legado_b11/legado_backup_1794284348193.json`（720B）；宿主 WebDAV 目录保留 4 个原文件 + 3 个本批测试备份（见 `tmp_qb11_evidence_listing.txt`） |
| 证据 | `docs/materials_1110b/`：76 张截图（`tmp_qb11_*.png`）、`logcat_b11.txt`、`logcat_b11_after_clear.txt`、`wsgidav_b11.log`、`tmp_qb11_evidence_listing.txt` |

## 六、门禁引用

- 本次为设备运行时验收，输入为 release APK；**未执行** `dart analyze` / `flutter test` / 构建门禁（不在本任务范围），因此不声明静态分析、单元测试或构建门禁通过。
- 运行时证据按「验证反馈回路与证据固化」要求留存：逐项截图 + logcat 稳定性统计 + WebDAV 服务端访问日志 + 本地/远端目录清单。
- 未验证或无法插桩的项（第 14 项忙碌态）已如实标记 BLOCKED，未计入 PASS。

## 八、回修与复验

回修提交：`703b4b1bd0 fix(ui): 未配置 WebDAV 时禁用本地与网络备份并复位测试状态`
复验日期：2026-11-10（MuMu「Test测试」，`192.168.100.62:5555`）
复验 APK：`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，210,440,576 字节，
sha256 `b1479dcefaf72f326c39e4a113ac09afb42646fddb0ad78c42d1654153bd6d2f`，
`aapt2 badging` 与设备 `dumpsys` 均为 `versionName=2.0.480 / versionCode=481`（问题 1 已消除）。

| 项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- |
| F1 未配置时「备份至本地与网络」置灰（问题 2） | PASS | `tmp_qb11_fix_04_addr_cleared_status_reset.png`、`tmp_qb11_fix_05_backup_sheet_disabled.png` | 清空地址并保存后打开备份 Sheet，「备份至网络」与「备份至本地与网络」均灰显，副标题同为「请先配置 WebDAV」；点按不执行、Sheet 不关闭 |
| F2 长按备份行不再静默降级（问题 2 补充） | PASS | `tmp_qb11_fix_06_longpress_abort.png` | 未配置时长期按「备份」行，Toast 明确提示「未配置 WebDAV，已取消备份」，未创建本地备份（旧行为为静默只做本地） |
| F3 清空地址后「测试配置」复位（问题 3） | PASS | `tmp_qb11_fix_03_test_success.png`、`tmp_qb11_fix_04_addr_cleared_status_reset.png` | 先对 `http://192.168.100.52:8090/` 测试成功显示「✓ 连接成功」；清空地址保存后立即变为「未测试」，不再残留陈旧成功 |
| F4 配置后三项均可用 | PASS | `tmp_qb11_fix_08_backup_sheet_enabled.png` | 重新填入地址后备份 Sheet 三项均无禁用原因，可点 |
| F5 「备份至本地与网络」成功（本地+服务器） | PASS | `tmp_qb11_fix_09_backup_both_success.png`、`tmp_qb11_fix_evidence_listing.txt`、`wsgidav_fix.log` | Toast 同时给出本地文件与远端文件名；本地目录由旧文件替换为 `legado_backup_1794285677151.json`（747B），服务器新增 `backup_20261110_124117_161.json`（747B），wsgidav 记录 `PUT ... -> 201 Created` |
| F6 静态与测试门禁 | PASS | 提交 `703b4b1bd0` | `flutter analyze` 0 issue；`flutter test` 5419 通过 + 1 skipped；本批 6 个文件 `dart format` 0 changed；未改 Rust/FFI/契约/版本号/CHANGELOG/ACTIVE_PLAN |
| F7 logcat 五项崩溃计数 | PASS | `logcat_b11_fix.txt`（18,115 行） | `FATAL EXCEPTION=0`、`ANR in=0`、`E/flutter=0`、`overflowed=0`、`E AndroidRuntime=0` |
| F8 清理与终态 | PASS | `tmp_qb11_fix_10_final_cleared.png` | `pm clear` 返回 Success；`am start -W` 返回 `Status: ok / COLD / TotalTime 415ms`；空书架正常显示 |

复验结论：问题 2、问题 3 均已按期望修复并在设备上取证通过；问题 1（版本不一致）由本次重建
APK 消除，APK 与设备安装版本均为 `2.0.480+481`。本轮回修未引入崩溃、ANR、Flutter error
或布局溢出。WebDAV 服务已停止，应用数据已清理。

— full-stack-engineer ｜ 2026-11-10
