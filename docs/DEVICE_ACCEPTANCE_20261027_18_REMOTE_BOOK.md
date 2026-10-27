# 批 18a/18b 远程书库服务器迁移设备验收报告（2026-10-27）

> 范围：批 18a（远程书库服务器列表 `remote_servers` 旧偏好 → `servers` 表迁移、服务器 CRUD、
> 原版 zip `servers.json` 恢复可见性）与批 18b（WebDAV 书籍 origin 对齐原版 `webDav::` 并兼容存量 `dav:`）。
> 设备：Windows 宿主 + MuMu「Test测试」实例。
>
> **结论**：场景 1 / 2 / 4 / 5 / 7 / 8 **PASS**；场景 3 **BLOCKED**（被一个预置 P0 缺陷阻断）；
> 场景 6 **FAIL**（交互缺陷）。共发现 1 个阻断级缺陷、1 个 P2 交互缺陷、2 个 P3 观察项。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（实测在线；`adb shell id` = `uid=0(root)`，设备自带 `sqlite3 3.44.3`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15 / ABI `x86_64` |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 应用包名 | `io.legado.flutter_legado` |
| 验收前版本 | versionName 2.0.391 / versionCode 392 |
| 验收版本 | **versionName 2.0.394 / versionCode 395**（`dumpsys package` 实测） |
| 源码基线 | `master` HEAD `ac1c297306`（`chore: 批18b 收尾（2.0.394+395 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-27 11:10 ~ 11:45（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261027_remote_book/`（`/tmp_*` 已在 `.gitignore`，不入库） |

### 1.1 Rust Android 构建

`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release` 退出码 **0**，
三 ABI 产出并复制到 `flutter_legado/android/app/src/main/jniLibs/`。

- 既有环境项：armv7 的 `rar` crate 编译失败 → 脚本按既有逻辑回退「无 quickjs」；x86_64 目标构建成功，不影响本批结论。

### 1.2 Flutter 发布包

`flutter build apk --release` 退出码 **0**，产物 `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`
（184.8 MB，2026-10-27 11:13），`adb install -r` 成功，`dumpsys` 确认 2.0.394/395。

### 1.3 Mock WebDAV 与端点偏差

- 宿主 Python `ThreadingHTTPServer` 监听 **`0.0.0.0:18081`**，提供 `/dav/`、`/dav/books/`、
  `/dav/books/txt-sample.txt`、`/dav/books/txt-default.txt`，支持 `PROPFIND(Depth 0/1)`、`GET/HEAD/PUT/DELETE`，
  Basic Auth 接受任意凭据，逐请求写 `dav_requests.log`。脚本：`mock_webdav.py`。
- **偏差**：本实例 `adb reverse tcp:18081 tcp:18081` 不可靠（仅一次成功，之后设备 `nc 127.0.0.1:18081` 无响应；
  `reverse --list` 正常、宿主监听正常、设备→宿主 `192.168.100.52:18081` 的 `nc` 可通）。为保证验收推进，
  应用内服务器 URL 使用**宿主 LAN 地址 `http://192.168.100.52:18081/dav/`**。
  该偏差只影响 URL 主机部分，不影响 origin 格式判定（`webDav::<服务器 URL>+相对路径[,{"serverID":N}]`）。

## 二、验收场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 服务器新增/列表/编辑/删除（DB 源） | **PASS** | `evidence/05_add_dialog.png` ~ `14_after_refresh.png`、`30_delete_confirm.png`、`31_after_delete.png`、`evidence/db_servers_final.txt` |
| 2 | 旧 prefs 迁移（正 id + -1，幂等） | **PASS** | `evidence/prefs_migration_input.xml`、`32_after_migration_launch.png`、`33_after_migration_restart.png`、`34_migrated_server_visible.png` |
| 3 | 浏览与导入（自定义/默认服务器）+ origin 校验 | **BLOCKED** | `evidence/15_custom_root_listing.png`、`17/19/27_*.png`、`evidence/28_runtime_handle_bug_repro.txt`、`dav_requests.log` |
| 4 | 原版 zip 恢复 `servers.json` 可见性 | **PASS** | `servers_restore_test.zip`、`37_restore_confirm.png`、`38_after_restore.png`、`39_restored_server_visible.png` |
| 5 | 旧 `dav:` 书兼容（显示/打开） | **PASS** | `evidence/40_shelf_with_dav_book.png`、`41_dav_book_reader.png`（相对路径）/`42_dav_book_reader_abs.png`（绝对路径）、`44_back_state.png`、`evidence/db_dav_books.txt` |
| 6 | 失败提示内联（URL 清空保存） | **FAIL** | `evidence/09_url_cleared.png`、`10_empty_url_save_result.png` |
| 7 | 回归（版本/书架/阅读器/同步设置/FATAL/ANR） | **PASS** | `evidence/43_backup_page_scrolled.png`、`45_sync_settings_id_minus1.png`、`51_cleanup_shelf.png`、`evidence/logcat_fatal_anr_counts.txt` |
| 8 | （可选）v3 备份强制迁移 | **PASS** | `v3_legacy_remote.json`、`47_picker_retry.png`、`48_json_restore_confirm.png`、`50_final_server_list.png` |

## 三、逐场景说明

### 场景 1：服务器新增/列表/编辑/删除（DB 源）— PASS

1. 远程书籍页 → 「服务器配置」→ `+` 新增：名称「验收服务器」、URL、用户名 `u`、密码 `p`。
2. 保存后 DB 出现 `id=1793070940707`、`type=WEBDAV`、`config={"url":"http://192.168.100.52:18081/dav/","username":"u","password":"p"}`；
   Sheet 列表出现该服务器（`07_server_saved.png`）。
3. 编辑：名称改为「验收服务器-改」、URL 去掉尾斜杠 → 保存后 DB 主键不变、名称/URL 为新值、
   `sortNumber` 保持 0；关闭 Sheet 后点刷新再打开，列表显示新名称（`14_after_refresh.png`）。
4. 删除：确认框 → 删除后 UI 列表仅剩「默认」，DB 仅剩 `id=-1`（`31_after_delete.png`）。

### 场景 2：旧 prefs 迁移 — PASS

因 adbd 为 root，无需 debug 变体/`run-as`：force-stop 后直接改写
`/data/data/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml`。

输入（`evidence/prefs_migration_input.xml`）：
- `flutter.remote_servers` = 2 条：`id=123456`（密码 `legacy-pass`）与 `id=-1`；
- `flutter.remote_server_id` = `123456`；
- 删除 `flutter.remote_servers_migrated`。

启动一次后：
- `servers` 表新增 `123456|旧偏好服务器|WEBDAV|{"url":...,"username":"u","password":"legacy-pass"}`（密码保留）；
- `-1` 未被旧偏好覆盖（仍为本机既有配置）；
- `flutter.remote_servers_migrated` 置 `true`，`remote_server_id` 保持 `123456`；
- 远程页 Sheet 显示「旧偏好服务器」且被选中，`-1` 不展示（`34_migrated_server_visible.png`）。

再次 force-stop + 启动：`servers` 仍为 2 行（无重复），迁移幂等（`33_after_migration_restart.png`）。

### 场景 3：浏览与导入（自定义/默认服务器）— BLOCKED（P0 预置缺陷）

现象：选择自定义服务器（`http://192.168.100.52:18081/dav/`）或默认 WebDAV（`.../dav//books/`）后，
页面内联报错：

```
error sending request for url (http://192.168.100.52:18081/dav/)
```

宿主 mock 的 `dav_requests.log` **未收到任何来自应用进程的 PROPFIND**；设备 `/proc/net/tcp` 亦无到 18081 的连接。

排除过程（均为独立证据）：
1. 宿主同款 `WebDavClient`（含 `custom_hosts` resolver）直连 mock：成功列出 2 项；
2. 交叉编译同代码的 x86_64 Android 探针，在设备上以 shell UID 与 **UID 10055** 运行：均成功 PROPFIND；
3. 应用内「备份与恢复 → 测试配置」使用 Dart `http` 发 `PROPFIND`：**连接成功**，mock 记录
   `[11:28:40] PROPFIND /dav/ depth=0 user=u 207`；
4. 仅在应用进程内、且仅 WebDAV Rust FFI 路径失败。

**根因（已用宿主最小复现确认）**：`rust/legado-ffi/src/api/webdav_api.rs:15-26`

```rust
fn webdav_runtime_handle() -> LegadoResult<tokio::runtime::Handle> {
    if let Ok(handle) = tokio::runtime::Handle::try_current() { return Ok(handle); }
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map(|rt| rt.handle().clone())   // ← Runtime 在此函数返回时被 drop
        ...
}
```

该函数构建 `Runtime` 后只返回 `rt.handle().clone()`，**局部 `Runtime` 随即被 drop**；随后
`webdav_api.rs` 各方法对已关闭的运行时执行 `rt.block_on(...)`，请求在建立连接前即失败，
错误即 `Network error: error sending request for url (...)`（与页面文案一致）。

最小复现（宿主，`evidence/28_runtime_handle_bug_repro.txt`）：

```
ERR: Network error: error sending request for url (http://127.0.0.1:18081/dav/)
```

同一 mock、同一 `WebDavClient`，在正常 `#[tokio::main]` 下返回 `OK 2 entries`。

影响：所有经 `webdav_runtime_handle()` 的 WebDAV FFI（列目录、下载/上传、同步等）在应用内均不可用；
本批的「浏览 → 下载导入 → origin 校验 → 远程页显示已在书架」无法执行，`books.origin` 的
`webDav::<url>,{"serverID":<id>}` 与默认服务器无后缀格式**未能设备实证**（已由仓库单测覆盖）。

建议修复（本次按任务要求**未改业务代码**）：改用 `crate::runtime::get_runtime().block_on(...)`
（`runtime.rs` 已有 `enable_all` 的静态 `Runtime`），或将兜底 `Runtime` 存入 `OnceLock` 保活；
同时避免 `Handle::try_current()` 命中后在同线程 `block_on` 的 panic 风险。

### 场景 4：原版 zip 恢复 `servers.json` 可见性 — PASS

构造 `servers_restore_test.zip`（仅含明文 `servers.json`，1 条
`{"id":123456789,"name":"恢复可见性","type":"WEBDAV","config":"{\"url\":\"http://127.0.0.1:18081/dav/\",...}","sortNumber":0}`），
推送至 `/sdcard/Download/`，在「备份与恢复」长按「恢复」→ 选择 zip → 确认恢复。

- DB 新增 `123456789|恢复可见性|WEBDAV|{"url": "http://127.0.0.1:18081/dav/", ...}`；
- 远程书库 Sheet 出现「恢复可见性」（此前不可见），证明恢复侧 `servers.json` 接入生效（`39_restored_server_visible.png`）。

### 场景 5：旧 `dav:` 书兼容 — PASS

设备书架原无 `webDav::`/`dav:` 书。force-stop 后写入本地 TXT（`app_flutter/books/dav_legacy_test.txt`）
并插入一条 `books` 行：`origin='dav:http://127.0.0.1:18081/dav/books/txt-sample.txt'`、`originName='txt-sample.txt'`。

- 书架「全部」正常显示「DAV旧前缀测试书」（未被误判/过滤），章节标题正确（`40_shelf_with_dav_book.png`）；
- 点开进入阅读器，正文正常渲染（`42_dav_book_reader_abs.png`）；
- 书籍详情页显示「来源：txt-sample.txt」「已在书架」（`44_back_state.png`）。

观察项：`bookUrl` 使用相对标识 `books/dav_legacy_test.txt` 时打开报
`Book parsing error: 无法打开文件: No such file or directory (os error 2)`；改为绝对路径即正常。
Android 本地导入写入绝对路径，故不阻断本批；相对标识路径解析问题记为 P3（见第四节）。

### 场景 6：失败提示内联 — FAIL

编辑服务器 → 清空 URL → 点「保存」：**对话框保持打开、无任何错误文案、DB 未变化**
（`09_url_cleared.png`、`10_empty_url_save_result.png`）。

根因：`flutter_legado/lib/src/screens/remote_book_screen.dart:490-492`

```dart
void _save() {
  final url = _urlCtrl.text.trim();
  if (url.isEmpty) return;   // 静默返回，无内联提示
```

Sheet 内联错误行（`state.serverError`）只在 `ServerService.saveServer/deleteServer` 抛异常时渲染；
空 URL 在对话框层被拦截，永远到不了该路径，因此「Sheet 内出现错误文案」的验收点不成立。
修复后（重新填入 URL）保存成功、DB 更新，符合「修复后保存成功」的后半段。

### 场景 7：回归 — PASS

- 关于页/包信息：versionName **2.0.394**、versionCode 395。
- 书架：清理后 15 本，原书籍显示正常（`51_cleanup_shelf.png`）。
- 阅读器：本地 TXT 正常打开渲染（`42_dav_book_reader_abs.png`）。
- 同步设置：`servers` 表 `id=-1` 账号 URL/账号/密码/子目录均保留，未被远程书库 CRUD 影响
  （`45_sync_settings_id_minus1.png`）。
- logcat：`FATAL EXCEPTION = 0`、`ANR in = 0`、`am_anr = 0`（`evidence/logcat_fatal_anr_counts.txt`）；
  应用进程全程存活。

### 场景 8（可选）：v3 备份强制迁移 — PASS

构造 v3 JSON：`servers` 仅 `id=-1`，`appPrefs.remote_servers` 携带 2 条旧偏好（含正 id 123456）。
先删除 DB 中 `123456`（模拟迁移前状态），再本地恢复该 JSON：

- 恢复侧应用 `appPrefs` 后，`ServerService.backupNeedsLegacyRemoteServerMigration` 判定为旧格式，
  触发 `forceMigrateAfterRestore()`；
- `servers` 表重新出现 `123456|旧偏好服务器`，证明强制迁移链路生效（`50_final_server_list.png`）。
- 注：该条密码显示为 `p` 而非备份中的 `legacy-pass`——`mergeRemoteServersFromBackup` 按
  「URL+用户名」端点匹配本机既有密码（此时 `-1` 行同端点密码为 `p`），属既有密码保留策略，非缺陷。

## 四、缺陷与根因汇总

| 级别 | 问题 | 位置 | 说明 |
|---|---|---|---|
| **P0（阻断）** | WebDAV FFI 运行时句柄失效：构建 `Runtime` 后仅返回 `Handle`，`Runtime` 立即 drop | `rust/legado-ffi/src/api/webdav_api.rs:15-26` | 应用内所有 WebDAV 请求在连接前失败；阻断场景 3 及 origin 设备实证。建议改用 `runtime::get_runtime()` 或静态保活 |
| **P2** | 空 URL 保存静默无提示 | `flutter_legado/lib/src/screens/remote_book_screen.dart:490-492` | 与场景 6 期望不符；应在对话框内联报错或禁用保存 |
| P3 | 远程目录列表会把服务器自身（collection self 项）显示为文件夹 | `flutter_legado/lib/src/providers/remote_book/remote_book_notifier.dart:281` 附近 | 宿主探针对 `/dav/` 返回 2 项（`dav` + `books`）；原版 Kotlin `WebDav.listFiles()` 用 `it.path != path` 过滤自身。因 P0 未在设备 UI 复现，建议补过滤 |
| P3 | 本地书相对标识 `books/x.txt` 解析失败 | `rust/legado-ffi/src/db_state.rs:53-73` / 阅读链路 | 绝对路径正常；Android 导入写绝对路径，不阻断本批，建议排查 `current_db_path()` 在该路径下是否为空 |

环境观察（非代码缺陷）：
- 本实例 `adb reverse` 不稳定，改用宿主 LAN IP 访问 mock（见 §1.3）。
- Rust 构建 armv7 `rar` crate 失败后按既有逻辑回退无 quickjs；x86_64 正常。

## 五、清理与恢复

- `servers` 表：删除测试行 `123456`、`123456789` 与测试用 `-1`，最终 **0 行**（恢复验收前状态）。
- `books` 表：删除注入的「DAV旧前缀测试书」，最终 **15 行**；删除 `app_flutter/books/dav_legacy_test.txt`。
- prefs：删除 `flutter.remote_servers`、`flutter.sync_webdav_remote_dir`、`flutter.sync_webdav_device_name`；
  `remote_server_id` 复位 `-1`；保留 `remote_servers_migrated=true`（验收前即为 true）。
- 已删除 `/sdcard/Download/v3_legacy_remote.json`、`/sdcard/Download/servers_restore_test.zip`、
  `/data/local/tmp/{webdav_probe,setuid_helper,prefs_migration_input.xml}`。
- 已 `adb reverse --remove-all`，停止宿主 mock 服务，删除临时 Rust 探针示例
  （`rust/legado-net/examples/webdav_probe.rs`、`webdav_handle_probe.rs`）。
- 最终远程页恢复为「请先在备份设置中配置默认 WebDAV，或在「服务器配置」中添加服务器」
  （`52_cleanup_remote.png`，与验收初始 `02_remote_page_initial.png` 一致）。

## 六、遗留问题

1. **P0 必须先修**，否则批 18a/18b 的「浏览/导入/origin 写入」无法在设备上验收；修复后需补跑场景 3
   的 origin 查询（`books.origin` 自定义服务器带 `,{"serverID":<id>}`、默认服务器无后缀）与「已在书架」显示。
2. 场景 6 的空 URL 交互需产品/UI 侧确认期望（内联错误 vs 保存按钮禁用）。
3. P3 列表自身项过滤、相对本地书路径解析建议单独登记。

编写：ZCode ｜ 2026-10-27

## 七、回修复验（批18c，2026-10-27）

> 本节为缺陷回修后的复验记录，**不改变第二~四节的原始结论**；原始 FAIL/BLOCKED
> 判定保留在原文。复验证据目录：`tmp_debug/device_acceptance_20261027_remote_book/verify2/`
> （`tmp_*` 已在 `.gitignore`，不入库）。

### 7.1 回修提交

| 提交 | 内容 |
|---|---|
| `d0772ac074` `fix(rust)` | **P0**：WebDAV FFI 改用 `crate::runtime::block_on`（复用 `runtime.rs` 全局 Runtime），删除自建 Runtime/Handle |
| `87b46eae5e` `fix(rust)` | **P3-1** 目录自身项过滤；**P3-2** `get_chapter_content_full` 相对路径解析；**origin** 本地书→WebDAV 写入（B-2 合并例外） |
| `9e305a0efc` `fix(ui)` | **P2**：空名称/地址保存对话框内联报错 |
| 本节文档提交 | 回修复验记录 |

### 7.2 P0 根因与修法（红→绿）

**根因**（与 §三 场景 3 一致）：`webdav_runtime_handle()` 在函数内构建 `Runtime` 后只返回
`rt.handle().clone()`，局部 `Runtime` 返回即 drop，IO driver 关闭；后续 `Handle::block_on`
的请求在建立连接前失败，错误即 `error sending request for url (...)`。

**修法**：删除 `webdav_runtime_handle()`，全部 WebDAV FFI（列目录/上传/下载/删除/建目录/
全量/增量同步）改用既有 `crate::runtime::block_on`（`runtime.rs` 的 `OnceLock<Runtime>`，
`enable_all`，全仓统一模式）。

**红→绿证据**（新增回环 WebDAV 用例 `test_webdav_list_dir_loopback_runtime_alive`）：

- 修复前（`verify2/01_p0_red_before_fix.txt`）：
  `Network("error sending request for url (http://127.0.0.1:<port>/dav/)")` —— 与设备页面文案完全一致；
- 修复后（`verify2/02_p0_green_after_fix.txt`）：`test ... ok`（1 passed）。

### 7.3 场景 3 复验 — PASS

**构建与安装**（`verify2/05b_*`、`06b_*`、`41_install_identity_final.txt`）：
Rust Android 三 ABI 构建退出码 0（armv7 的 quickjs 仍按既有逻辑回退，`rar` crate 已知问题）；
`flutter build apk --release` 退出码 0（185.1 MB）；`adb install -r` 成功。
安装包内 `lib/x86_64/liblegado_ffi.so` CRC32 = **`3b992d13`**，与宿主 `app-release.apk`
完全一致（确认设备跑的是回修后产物）。

**自定义服务器**（URL `http://192.168.100.52:18081/dav/`，`id=1793070940707`）：

1. 进入远程书籍页即收到 `PROPFIND /dav/`（`38_dav_requests_final.log`，12:14:19）——
   P0 修复生效；根目录只显示 `books`（自身项 `dav` 已过滤，`20_remote_root_after_fix.png`）；
2. 进入 `books/` → 选择 `txt-sample.txt` → 「加入书架」：mock 收到
   `GET /dav/books/txt-sample.txt 200 bytes=919`（12:14:34）；
3. 列表该行显示「已在书架」勾选（`21_after_import_custom_fixed.png`）；
4. `books.origin` 原始字符串（`22_db_origin_custom_fixed.txt`）：

```
webDav::http://192.168.100.52:18081/dav/books/txt-sample.txt,{"serverID":1793070940707}
```

**默认服务器**（同步账号 `id=-1`，remote_dir `/legado/`）：

1. 服务器 Sheet 切到「默认」后收到 `PROPFIND /dav//legado/books/` 207（`27_default_list_ok.png`）；
   默认服务器根 = 同步账号 url + `remote_dir` + `books/`，对齐原版
   `AppWebDav.rootWebDavUrl` + `"books/"`；
2. 选择 `txt-default.txt` 导入：`GET /dav//legado/books/txt-default.txt 200 bytes=405`（12:16:55）；
3. 显示「已在书架」（`28_after_import_default.png`）；
4. `books.origin` 原始字符串（`29_db_origin_default.txt`，**无 serverID 后缀**）：

```
webDav::http://192.168.100.52:18081/dav/legado/books/txt-default.txt
```

> 环境说明：本机 `adb reverse` 仍不可靠（与 §1.3 一致），全程使用宿主 LAN
> `192.168.100.52:18081`；mock 在验收用文件基础上补充了默认服务器路径
> `/dav/legado/books/`（仅测试数据，不涉及产品代码）。

**回修中发现并修复的关联缺陷（origin 写入）**：设备首次复验时导入成功但
`books.origin` 仍为 `loc_book`。根因是 `bookshelf::update_book` 的 B-2 防回退合并
（`merge_source_fields`）把「库内既有非空 origin」无条件覆盖入参；远程书库导入
先落 `loc_book` 再改写 `webDav::`，于是改写被撤销。修法：合并仅在库内为**在线书源**
地址时生效，本地（`loc_book`）与 WebDAV 存储 origin 允许入参覆盖；B-2 在线换源
语义由新增回归用例 `test_update_book_keeps_online_origin_against_stale_snapshot`
与既有 `reading_flow_rust_defects` 固化。

### 7.4 场景 6 复验 — PASS

编辑服务器 → 清空 URL → 「保存」：对话框保持打开，字段下方显示红色内联文案
「名称和地址不能为空」（`33_empty_url_save_inline_error.png`）；`servers` 表未变化
（`34_db_servers_after_empty_save.txt`，URL 原样保留）。Widget 用例
`空 URL 保存：对话框内联提示且不调用保存（批18c P2）` 覆盖同一行为。

### 7.5 P3 复验

- **P3-1 目录自身项**：自定义服务器根只显示 `books`/`legado`，不再出现自身 `dav`
  （`20_remote_root_after_fix.png`、`26_server_sheet_again.png`）；默认服务器 `books/`
  只显示文件（`27_default_list_ok.png`）。Rust 单测覆盖自身项与百分号编码目录名。
- **P3-2 相对路径本地书**：注入 `bookUrl='books/rel_verify.txt'`（文件位于
  `app_flutter/books/rel_verify.txt`），书架显示并可打开，正文正常渲染
  （`35_shelf_with_rel_book.png`、`36_rel_book_reader.png`）。根因是
  `get_chapter_content_full` 的本地分支缺少 `resolve_local_book_path`，已补齐。

### 7.6 门禁数字

| 项 | 结果 | 证据 |
|---|---|---|
| `cargo test -p legado-ffi` | lib **545 passed / 0 failed / 21 ignored**；全部集成测试通过 | `03b_cargo_test_legado_ffi_final.txt` |
| `cargo clippy -p legado-ffi -p legado-net --all-targets` | 无 warning/error | 会话记录 |
| `cargo fmt --all -- --check` | 通过 | 会话记录 |
| `flutter analyze` | **No issues found!** | 会话记录 |
| `flutter test`（全量） | **2645 passed / 0 failed** | `04_flutter_test_all.txt` |
| 设备 logcat | `FATAL EXCEPTION=0`、`ANR in=0`、`am_anr=0`，进程存活 | `37_logcat_fatal_anr.txt` |

> 门禁备注：`test/ffi/direct_link_upload_runtime_test.dart` 的 `@js:` 用例依赖
> **quickjs 档** 的 Windows debug DLL（`cargo build -p legado-ffi --features quickjs`）。
> 直接跑 `cargo test -p legado-ffi` 会用默认档重建 `legado_ffi.dll`，导致该用例
> 出现 `BridgeError`；按 quickjs 档重建后 4/4 通过，属构建档位差异，与本批改动无关。

### 7.7 清理与最终状态

- `servers` 表恢复 **0 行**（删除 `-1` 与 `1793070940707`）；
- `books` 表恢复 **15 行**，`webDav::`/`dav:` 书 **0 行**；删除 `app_flutter/books/rel_verify.txt`
  与 `code_cache/legado_remote_books/`；
- prefs 恢复验收前内容（`remote_server_id=-1`，移除 `sync_webdav_remote_dir`）；
- 停止宿主 mock（18081 已释放）、无 `adb reverse` 残留、删除 `/data/local/tmp` 注入文件；
- 远程页恢复为「请先在备份设置中配置默认 WebDAV，或在「服务器配置」中添加服务器」
  （`39_cleanup_remote.png`，与验收初始 `02_remote_page_initial.png` 一致）。

编写：ZCode ｜ 2026-10-27（批18c 回修复验）
