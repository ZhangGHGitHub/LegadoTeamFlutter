# 批26 系统另存 SAF 目录树设备验收报告（2026-10-27）

> 范围：系统「保存到本地」由 `ACTION_CREATE_DOCUMENT` 改为 SAF 目录树
> （`ACTION_OPEN_DOCUMENT_TREE` + `DocumentsContract.createDocument`，对齐原版
> `HandleFileViewModel.saveToLocal`），首次选文件夹并记住、之后直接写入；
> 消除 MuMu Android 15 `DownloadStorageProvider` 拒写导致的 0 字节占位。
> 设备：Windows 宿主 + MuMu「Test测试」实例（Android 15 / x86_64，adbd 以 root 运行）。
>
> 设备端点：`192.168.100.62:5555`（实测在线）
> 源码基线：`master` HEAD `d9706448e2`（批25 测试提交）+ 本批未提交改动
> 验收时间：2026-10-27 00:55 ~ 01:05（+08:00，设备日志时区）
> 证据目录：`tmp_debug/device_acceptance_20261027_export_tree/`（`tmp_*` 已被 `.gitignore` 忽略）

## 一、构建与安装

| 项 | 值 |
|---|---|
| 命令 | `flutter build apk --release` |
| 退出码 | 0（`√ Built build\app\outputs\flutter-apk\app-release.apk (188.0MB)`，Gradle `assembleRelease` 88.8s） |
| APK 大小 | 197,093,176 B |
| sha256 | `d4fd9d8ca707a55ee805db13a8e254a72761bc2d4f7aeb665f9a499fbcec68b6` |
| 安装 | `adb install -r` → `Success: streamed 197093176 bytes`（数据保留） |
| 版本 | **versionName 2.0.401 / versionCode 402**（`dumpsys package` 实测，版本号由主代理收尾） |
| ABI | x86_64（本设备） |

证据：`logs/build_apk.log`、`logs/apk_sha256.txt`、`logs/install_apk.txt`、`logs/version_info.txt`、`logs/launch.txt`。

- Rust 无改动，未重跑 `cargo`；Gradle `preBuild` 的 FFI content hash 校验通过（构建成功即证明 `.so/.meta` 一致）。
- 应用入口：`io.legado.flutter_legado/io.legado.flutter.MainActivity`。
- 安装前设备存量：书架 0 本、书源 1 个（`批25口令源`），用于导出链路。

## 二、结论总览

| # | 场景 | 结论 | 关键证据 |
|---|---|---|---|
| 1 | 首次「保存到本地」：弹目录选择器，选 `Download/legado` 并授权 | **PASS** | `screens/05_picker_first.png`、`06_picker_download.png`、`07_picker_legado.png`、`08_picker_allow.png` |
| 2 | 首次保存落盘：树内建文件 + 写入 + 校验成功 | **PASS**：`bookSource_批25口令源.json` 1710 B，JSON 可解析 | `screens/09_saved_first.png`、`logs/d1_booksource_first.json`、`logs/log_chain_final.txt` |
| 3 | 第二次保存：沿用记住目录，**不再弹选择器**，直接写入 | **PASS**：提示「已保存到「下载/legado」：bookSource_批25口令源 (1).json」 | `screens/10_sheet_remembered.png`、`11_saved_second.png`、`logs/d2_booksource_second.json` |
| 4 | 「换个保存位置」：新建 `Download/legado/legado2` 并切过去 | **PASS**：Sheet 文案更新为「保存到「下载/legado/legado2」」，保存落到新目录 | `screens/12_change_location_picker.png`、`13_new_folder.png`、`14_after_change_location.png`、`15_saved_new_tree.png` |
| 5 | 「换个保存位置」取消（返回键退出选择器） | **PASS**：回到 Sheet，位置不变、无错误提示、无崩溃 | `screens/16_change_then_cancel.png` ~ `20_after_cancel_change4.png` |
| 6 | 记住目录被删除后保存：自动清除记录并重选一次 | **PASS**：`TREE_UNAVAILABLE` → 清记录 → 自动弹选择器；取消后回列表无提示 | `screens/21_missing_tree_repick.png`、`23_after_cancel_repick.png`、`logs/prefs_after_clear.xml` |
| 7 | 写入失败（provider 拒绝）：错误面板 + 「换个位置」重试 | **PASS**：显示「无法写入所选文件夹，请换一个文件夹重试」+ 原始错误 `Parent document isn't a directory`；换位置后自动重试成功 | `screens/25_tree_write_failure.png`、`26_retry_after_change.png`、`logs/log_chain_final.txt` |
| 8 | 高亮规则导出 → 保存到记住目录 | **PASS**：提示「已保存到「下载/legado」：HighlightRules (3).json」；397 B，JSON 可解析（`type`/`rules`，规则名 QA26） | `screens/29_highlight_list.png`、`32_highlight_sheet.png`、`33_highlight_saved.png`、`logs/d7_highlight_tree.json` |
| 9 | 0 字节占位对比（验收前后 `find -size 0`） | **PASS**：**无新增**（`diff` 为空） | `logs/zero_before_files.txt`、`logs/zero_after_all2.txt` |
| 10 | 崩溃口径 | **PASS**：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`SecurityException`=0；进程存活（pid 6017） | `logs/logcat_final2.txt` |

**总体判定：通过。** 目录树主路径、记住目录直存、换目录、删除目录恢复、写入失败面板、
取消语义均符合预期；验收全程未新增 0 字节文件，且不再出现 `MANAGE_DOCUMENTS` 拒写。

## 三、逐用例明细

### 3.1 首次保存（选择文件夹）

**操作**：我的 → 书源管理 → 全选（1/1）→ 底部「更多选项」→「导出所选」→ Sheet
「保存到本地」→ 选择器进入 `Download` → `legado` →「使用此文件夹」→「允许」。

**实际**：
- Sheet 首次状态（`04_export_sheet.png`）：「保存到本地 / 首次保存需选择保存文件夹，之后沿用」、
  「换个保存位置 / 选择文件保存到哪个文件夹」。
- 选择器落到 `Download/legado`，出现系统授权确认「要允许阅读访问 legado 中的文件吗？」。
- 授权后应用回到书源列表，日志链（`logs/log_chain_final.txt`）：

```
已记住保存目录：uri=content://com.android.externalstorage.documents/tree/primary%3ADownload%2Flegado,
  display=下载/legado, authority=com.android.externalstorage.documents
目录树建文件：.../document/primary%3ADownload%2Flegado%2FbookSource_批25口令源.json
目录树写入成功：name=bookSource_批25口令源.json, display=下载/legado
```

- 落盘：`/sdcard/Download/legado/bookSource_批25口令源.json` **1710 B**；宿主 `json.loads` 通过
  （list，len=1，`bookSourceName=批25口令源`），证据 `logs/d1_booksource_first.json`。
- 记住的目录持久化在原生 SharedPreferences（`/data/data/io.legado.flutter_legado/shared_prefs/legado_file_save.xml`）。

### 3.2 第二次保存（记住目录，不弹框）

**操作**：重复导出 → Sheet 显示「保存到「下载/legado」」/「当前：下载/legado · 点击重新选择文件夹」
（`10_sheet_remembered.png`）→「保存到本地」。

**实际**：**未出现任何系统对话框**，直接写入；提示「已保存到「下载/legado」：
bookSource_批25口令源 (1).json」（`11_saved_second.png`）。日志只有建文件 + 写入成功，无
`已记住保存目录`（未重新选择）。落盘 1710 B，JSON 可解析（`logs/d2_booksource_second.json`）。
重名 `(1)` 由 provider 自动追加，实际文件名经查询回传并用于提示。

### 3.3 换个保存位置（新建文件夹）

**操作**：Sheet「换个保存位置」→ 选择器以记住目录为初始位置（`12_change_location_picker.png`，
`EXTRA_INITIAL_URI` 生效）→「新建文件夹」输入 `legado2` → 自动进入 →「使用此文件夹」→「允许」。

**实际**：Sheet 立即更新为「保存到「下载/legado/legado2」」（`14_after_change_location.png`）；
点「保存到本地」后直接写入新目录，提示「已保存到「下载/legado/legado2」：bookSource_批25口令源.json」
（`15_saved_new_tree.png`）；`/sdcard/Download/legado/legado2/` 落盘 1710 B。
旧目录的持久授权在换目录时释放（日志无异常）。

### 3.4 取消语义（两处）

- **换位置取消**：Sheet →「换个保存位置」→ 返回键逐级退出选择器 → 回到 Sheet，位置仍是
  `下载/legado/legado2`，无错误面板、无崩溃（`screens/16_*` ~ `20_*`）。
- **保存时取消（记住目录失效后自动重选）**：见 3.5；取消后 Sheet 关闭、无提示、无写入。

### 3.5 记住目录被删除：清除 + 自动重选一次

**操作**：`adb shell mv /sdcard/Download/legado/legado2 /sdcard/Download/legado/legado2_gone`（等效删除）
→ Sheet「保存到本地」。

**实际**：原生 `createDocument` 抛 `Missing file for primary:Download/legado/legado2 ...`，判定
`TREE_UNAVAILABLE` → 清除记住目录（`logs/prefs_after_clear.xml` 为 `<map />`）→ **自动弹一次**
目录选择器（`21_missing_tree_repick.png`）。在自动弹出的选择器按返回取消：回到书源列表，
无提示、无错误、无新增文件（`23_after_cancel_repick.png`）。随后重新选择 `Download/legado`
保存成功（提示 `(2)`，1710 B）。

### 3.6 写入失败（provider 拒绝）与「换个位置」重试

**说明**：本 ROM 的 `/sdcard` 为 FUSE，`chmod 555` 不生效（`stat` 仍为 777），无法构造真正的
「只读目录」。改用等效的真实 provider 写失败：把记住的目录 `Download/legado` 临时替换为同名
**普通文件**（`mv legado legado_bak && touch legado`），使 `createDocument` 的父文档不是目录。

**实际**：错误面板（`25_tree_write_failure.png`）展示：

```
保存失败
无法写入所选文件夹，请换一个文件夹重试
原始错误：Parent document isn't a directory
[换个位置] [复制错误] [取消] [重试]
```

日志：`目录树保存失败（TREE_WRITE_FAILED）... detail=Parent document isn't a directory`，
`java.lang.IllegalArgumentException: Parent document isn't a directory`。**未创建任何 0 字节文档**
（失败发生在 `createDocument` 阶段，`created=null`）。
恢复真实目录后点「换个位置」→ 重选 `Download/legado` → 自动重试保存成功，提示
「已保存到「下载/legado」：bookSource_批25口令源 (3).json」（`26_retry_after_change.png`，1710 B）。

### 3.7 高亮规则导出 → 保存到记住目录

**操作**：我的 → 高亮标注 →「+」新增规则（名称 `QA26`、匹配模式 `QA26`）→ 保存；
右上「更多操作」→「导出规则」→ Sheet（显示「保存到「下载/legado」」）→「保存到本地」。

**实际**：未弹任何对话框，直接写入；提示「已保存到「下载/legado」：HighlightRules (3).json」
（`33_highlight_saved.png`）。落盘 397 B，宿主 `json.loads` 通过（dict，`type`/`rules`，
规则名 `QA26`），证据 `logs/d7_highlight_tree.json`。说明不同导出内容（单书源 / 高亮规则）
共用同一目录树链路，行为一致。

### 3.8 保存失败面板与取消/重试按钮

失败面板同时保留「复制错误 / 取消 / 重试」，重试走同一保存参数（不重复弹选择器）；
「换个位置」只在 Android 保存失败时展示，上传失败不展示（widget 测试覆盖）。

## 四、0 字节残留对比

| 项 | 值 |
|---|---|
| 验收前 0 字节文件 | 11 个（9 个历史 D1 残留 json + 2 个 manga jpg），`logs/zero_before_files.txt` |
| 验收后 0 字节文件 | 11 个，`logs/zero_after_all2.txt` |
| `diff` 结果 | **空（无新增、无减少）** |
| 本轮新增文件 | `bookSource_批25口令源.json`、`(1)`、`(2)`、`(3)` 各 **1710 B**；`HighlightRules (3).json` **397 B**（另有已删除的 `legado2/` 内 1 个 1710 B） |

- 对比命令：`adb shell find /sdcard/Download -maxdepth 3 -type f -size 0 | sort`。
- 本轮日志中 `目录树写入成功` 共 **6 条**（首次/记住直存/新目录/重选后/失败重试/高亮规则），
  `目录树保存失败` 两条均为受控失败（`TREE_UNAVAILABLE` 1 次、`TREE_WRITE_FAILED` 1 次），
  完整链路见 `logs/log_chain_final.txt`。
- 结论：**目录树写入不再产生 0 字节占位**；旧 `ACTION_CREATE_DOCUMENT` 链路仍保留在代码中作回退
  （`useTree: false`），本轮未从 UI 触发。

## 五、门禁与测试

| 项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found!**（10.8s） |
| `flutter test`（全量） | **2925 通过，1 跳过**（All tests passed!） |
| Android JVM 单测 | `:app:testDebugUnitTest --tests "io.legado.flutter.SaveFileBridgeTest"` → **41 例全绿** |
| Android 构建/安装 | `flutter build apk --release` 成功；`adb install -r` 成功；启动正常 |

新增/更新的用例：
- Dart：`test/unit/export_file_service_save_channel_test.dart`（tree 参数透传、chooseTree/savedTree、
  目录提示文案、MethodChannel 参数与回传解析、错误码中文映射）；`test/widget/export_file_sheet_test.dart`
  （当前位置展示、「换个保存位置」、失败面板换位置重试、保存成功回显实际目录）。
- Kotlin：`SaveFileBridgeTest` 新增 `treeDisplayPath`（下载根/primary/raw/内部存储/越界）、
  `isTreeUnavailable`（授权回收/目录缺失/磁盘满不误判）、新错误码中文映射。

## 六、限制与残余风险

1. **Android 15 无法选择「下载」根 / 内部存储根**：DocumentsUI 对根目录显示「无法使用此文件夹」
   （`screens/05_picker_first.png`、`06_picker_download.png`、`18_after_cancel_change2.png`），
   属系统平台限制（Android 11+ SAF 收紧），非本应用可绕过。因此验收实际使用 `Download/legado`
   与 `Download/legado/legado2`；提示文案与授权均正常。原版应用同样受此限制。
2. **个别 ROM 的目录树差异**：`ACTION_OPEN_DOCUMENT_TREE` 无处理者时自动回退
   `ACTION_CREATE_DOCUMENT` 并记 W 日志；`takePersistableUriPermission` 被拒时仅本次临时授权生效，
   下次保存会因目录不可用而重选（已由纯函数 `isTreeUnavailable` 与真机删除目录路径覆盖）。
3. **重名后缀由 provider 决定**：ExternalStorageProvider 自动追加 ` (N)`（本轮实测 `(1)~(3)`）；
   提示文案使用查询到的实际文件名，不假设命名规则。
4. **MediaStore 回退**：仅保留在旧 `useTree=false` 链路（tree 不可用/显式回退），tree 模式不写
   MediaStore；本轮未从 UI 触发该链路（Dart/Kotlin 单测覆盖参数与错误映射）。
5. **测试夹具残留**：为验证只读目录曾创建空目录 `/sdcard/Download/legado_ro`，该 ROM 的 FUSE
   对 `rmdir` 返回 `Operation not permitted`/`Text file busy`（root 亦无法删除），目录为空、不影响
   文件与 0 字节口径。
6. **并发语义**：保存请求仍为单飞（`ALREADY_PENDING`），目录树直存期间同样拒绝并发请求；
   Activity 销毁时的直存线程不在 `dispose` 内回复（系统对话框路径仍会回 `ACTIVITY_DESTROYED`），
   属极端时序，未见真机触发。

## 七、证据清单

| 类别 | 文件 |
|---|---|
| 构建/安装 | `logs/build_apk.log`、`logs/apk_sha256.txt`、`logs/install_apk.txt`、`logs/version_info.txt`、`logs/launch.txt` |
| 首次保存 | `screens/04_export_sheet.png`、`05_picker_first.png`、`06_picker_download.png`、`07_picker_legado.png`、`08_picker_allow.png`、`09_saved_first.png`、`logs/d1_booksource_first.json` |
| 记住直存 | `screens/10_sheet_remembered.png`、`11_saved_second.png`、`logs/d2_booksource_second.json` |
| 换目录 | `screens/12_change_location_picker.png`、`13_new_folder.png`、`14_after_change_location.png`、`15_saved_new_tree.png` |
| 取消 | `screens/16_change_then_cancel.png` ~ `20_after_cancel_change4.png` |
| 删除目录恢复 | `screens/21_missing_tree_repick.png`、`23_after_cancel_repick.png`、`logs/prefs_after_clear.xml` |
| 失败面板 | `screens/25_tree_write_failure.png`、`26_retry_after_change.png`、`logs/d6_booksource_after_retry.json` |
| 高亮规则 | `screens/29_highlight_list.png`、`30_highlight_edit.png`、`31_highlight_saved.png`、`32_highlight_sheet.png`、`33_highlight_saved.png`、`logs/d7_highlight_tree.json` |
| 0 字节对比 | `logs/zero_before_files.txt`、`logs/zero_after_all2.txt`、`logs/zero_before_root.txt`、`logs/zero_before_legado.txt` |
| 日志 | `logs/logcat_final2.txt`、`logs/log_chain_final.txt` |
| 持久化 | `logs/prefs_before_delete.xml`、`logs/prefs_after_final.xml` |

## 八、批26b 审查回修复验（2026-10-28）

> 范围：审查 needs changes（1 P1 + 4 P2 + P3）逐项回修；不改版本号、
> `CHANGELOG.md`、`assets/updateLog.md`、`REFACTORING_ACTIVE_PLAN.md`。
> 源码基线：`master` HEAD `d73ed41744` + 本批未提交改动。
> 证据目录：`tmp_debug/device_acceptance_20261027_export_tree/verify2/`、
> `tmp_debug/batch26b_red_green/`（`tmp_*` 已被 `.gitignore` 忽略）。

### 8.1 P1-1：SIZE 未知误判失败并删除已写文件（红→绿）

- **根因**：`SaveFileBridge.verifyWritten` 用 `isReadbackSizeValid` 严格校验
  `COLUMN_SIZE`；SAF 允许 provider 不报大小（null/负数）→ 判失败 →
  `writeViaTree` 删除刚写成功的文档。
- **修复**：新增纯函数 `readbackSizeVerdict` / `verifyReadback`：SIZE 为
  null/负数时降级为 `openInputStream` 全文读取字节数比对 + 首字节校验；
  只有 SIZE 已知且确实不等才失败。已知相等时仍只校验首 8 字节（性能不变）。
- **红**：临时把 `readbackSizeVerdict` 的未知分支改回 `MISMATCH`（旧行为），
  `SaveFileBridgeTest > unknown size with matching content passes readback
  verification` 失败：`1 test completed, 1 failed`，`AssertionError` at
  `SaveFileBridgeTest.kt:460`（`batch26b_red_green/p1_red.log`）。
- **绿**：恢复实现后同一用例通过（`p1_green_after_red.log`，
  `BUILD SUCCESSFUL`）。
- **覆盖**：size=null/-1 + 内容/首字节一致 → 成功；全文长度不等、首字节
  不一致、已知大小不等 → 失败。

### 8.2 P2-1：clearTree 释放持久授权（设备检查）

- **修复**：`clearTree` 在清 prefs 前按记录 URI 调用
  `releasePersistableUriPermission(READ|WRITE)`（try/catch 记日志）；换目录
  释放旧授权的逻辑抽为 `releaseTreePermission` 共用。
- **设备复验**：把记住目录 `Download/legado` 改名（等效删除）后保存，
  日志链（`verify2/p2_1_clear_tree_release.txt`）：

```
目录树保存失败（TREE_UNAVAILABLE）：... Missing file for primary:Download/legado ...
记住的保存目录不可用，清除后重选一次：content://.../tree/primary%3ADownload%2Flegado
已释放目录持久授权（清除记住目录）：content://.../tree/primary%3ADownload%2Flegado
已清除记住的保存目录
```

- **授权对比**：清除前 `dumpsys activity permissions`（UID 10062）持有
  `legado2` 与 `legado` 两条 persisted grant；清除后仅剩历史 `legado2`
  一条，`legado` 已被释放。随后恢复目录（`mv` 回原名）。
- **说明**：本 ROM 的 `dumpsys uri_grants` 输出为空（0 字节，已留证
  `verify2/dumpsys_uri_grants_after_restart.txt`），故以同源的
  `dumpsys activity permissions` 中 `persisted=0x3` 记录作为授权证据。
  历史 `legado2` grant 是本批修复前的累积，已无记录指向，无法按 URI 释放；
  清除应用数据可一并回收，不影响后续行为。

### 8.3 P2-2：take flags 与只读目录

- **修复**：`persistTree` 改为接收系统回传的 `Intent.flags`，经纯函数
  `persistableFlags` 仅取 `READ|WRITE`；`treeGrantErrorCode` 要求必须含
  WRITE。无 WRITE 或 `takePersistableUriPermission` 失败时**不写 prefs**、
  回 `TREE_NOT_WRITABLE`，中文「该文件夹不可写，请换一个」（Kotlin
  `reasonOf` 与 Dart `errorReasons` 同文案）。
- **单测**：`persistable flags only keep read and write grants`、
  `tree grant requires write permission` 覆盖只读 flags、0 flags、READ|WRITE
  三种输入；无 WRITE 返回 `TREE_NOT_WRITABLE`。
- **设备**：回修后首次选择目录成功持久化（`persisted=0x3`），重启后直接
  保存成功（见 8.4），证明正常 flags 路径未被误伤。

### 8.4 P2-3：进程重启后仍记住目录（设备复验）

| 步骤 | 证据 |
|---|---|
| 保存一次（重启前）：pid **7927**，落盘 `bookSource_批25口令源 (4).json` 1710 B | `verify2/p2_3_restart_pid.txt` |
| `am force-stop` 后 pid 为空，重启后新 pid **8190** | `verify2/p2_3_restart_pid.txt` |
| 重启后 Sheet 仍显示「保存到「下载/legado」」，未弹目录选择器 | `verify2/07_after_restart_sheet.png` |
| 直接保存：pid **8190** 写入 `(5).json` 1710 B；`topResumedActivity` 始终为本应用 | `verify2/p2_3_second_save.txt`、`08_after_second_save.png` |
| 日志：`目录树建文件` → `目录树写入成功 ... display=下载/legado` | `verify2/p2_3_second_save.txt` |
| 内容校验：宿主 `json.loads` 通过（list，len=1，`bookSourceName=批25口令源`） | `verify2/d2_after_restart.json` |
| 持久授权：UID 10062 `mode=0x3 ... persisted=0x3 persistedCreate=1793120523036` | `verify2/uri_grants_after_restart.txt` |

结论：目录记录在进程重启后仍生效，新 pid 不弹选择器直接写入成功。

### 8.5 P2-4：createDocument 成功后写失败清理

- **设备侧限制**：本 ROM 的 ExternalStorageProvider 写流正常，FUSE 下
  `chmod` 不生效，无法构造「create 成功、openOutputStream 抛异常」且不
  破坏设备的场景；自定义 DocumentsProvider/Instrumentation 成本高，本批
  未引入。
- **已覆盖**：纯逻辑用例 `created document is cleaned when write stream
  throws` 锁定 `shouldDeleteAfterFailure(opened=false, preSize=0)=true`
  （create 刚建 0 字节文档）与 `preSize>0` 不删；代码路径
  `writeViaTree` catch → `created?.let { deleteDocument }` 未改动。
- **登记**：设备级「create 成功后写失败 -> 文档被删且无 0 字节」列为未覆盖
  项，留待具备可注入失败 provider 的环境补证；本批以纯逻辑 + 原 §3.6
  （create 阶段失败无 0 字节）作为回归护栏。

### 8.6 门禁与测试（本批）

| 项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found!**（8.1s） |
| `flutter test`（全量） | **2964 通过，1 跳过**（All tests passed!） |
| Android JVM | `:app:testDebugUnitTest --tests "io.legado.flutter.SaveFileBridgeTest"` → **49 例全绿** |
| APK 构建 | `flutter build apk --release` 成功（Gradle 94.9s，188.0MB APK） |
| APK 大小 / sha256 | 197,093,216 B / `02508295e49591ec60e871301ba85c87c1902cb5b7f799dbf75ef9f5ab355605` |
| 安装 | `adb install -r` → `Success: streamed 197093216 bytes` |
| 设备版本 | versionName **2.0.401** / versionCode **402**（`verify2/version_info.txt`） |
| 0 字节对比 | 11 个，与本批前清单 `diff` **为空**（`verify2/zero_after_all.txt`） |

新增/更新用例：
- Kotlin `SaveFileBridgeTest`：P1-1 读回降级（3 例）、P2-2 flags（2 例）、
  P2-4 清理（1 例）、外置卷/Downloads 子目录展示（2 例）、
  `TREE_NOT_WRITABLE` 中文映射（1 例）。
- Dart：`test/unit/file_save_error_codes_test.dart`（读取 Kotlin 源逐条
  比对错误码表）；`test/widget/export_file_sheet_test.dart`（
  `displayPath` 缺失用「已选文件夹」、失败面板「改用系统另存对话框」
  透传 `useTree=false`）。

### 8.7 P3 低成本项

1. `createDocument` 返回本次新建文档的假设已写入 Kotlin `writeViaTree`
   注释与 Dart `FileSaveChannel.saveFile` 契约注释；
2. `dispose` 保守复位 `writeInFlight` 并注释迟到回调幂等；
3. 旧 `ACTION_CREATE_DOCUMENT` 后台写线程也置 `writeInFlight`，
   `isBusy()` 口径统一（拒绝并发另存）；
4. 保存失败面板新增「改用系统另存对话框」（`useTree=false`）入口；
5. `displayPath` 缺失时副标题显示「已选文件夹」，不再回显裸 URI；
6. `treeDisplayPath` 增补外置卷子目录、`Downloads` 非标准目录单测；
7. Kotlin `reasonOf` 与 Dart `errorReasons` 通过源码表比对测试保证一致。

编写者：编码代理（Android SAF 目录树另存）｜ 2026-10-27
批26b 回修：编码代理（SAF 目录树审查回修）｜ 2026-10-28

