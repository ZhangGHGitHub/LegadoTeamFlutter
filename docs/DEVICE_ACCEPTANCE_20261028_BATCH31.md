# 批 31 设备验收报告（书源书籍数 + 目录显示反转）

> 范围：批 31（DB schema v115→v116 登记、`BookSource.bookshelfCount` 派生字段、
> `Book.readConfig.reverseTocDisplay`、书源管理「显示书籍数量」偏好、目录页/阅读器
> 「目录显示反转」、服务端 `/getBookshelf` 投影与 `/saveBook` 往返）。
> 设备：MuMu「Test测试」实例（guest 直连 `192.168.100.62:5555`，实测在线，adbd root）。
>
> **结论**：场景 1~7 全部 **PASS**。未发现功能缺陷；2 项环境观察（uiautomator 噪声
> 崩溃、备份目录 SAF 选择）与 1 项已登记边界（整书写回仅携带 Dart 建模字段）记录在 §四。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例 index=1「Test测试」，`is_android_started=true`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15 / `x86_64` |
| 分辨率 / 密度 | 1080x1920 / 480dpi |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，`uid=0`） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.406** / versionCode **407**（`dumpsys package`） |
| 验收版本 | versionName **2.0.408** / versionCode **409**（`dumpsys package` + 关于页实测） |
| 源码基线 | `master` HEAD `0fe493dee1`（`chore: 批31 收尾（2.0.408+409 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-29 00:50 ~ 01:45（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261028_batch31/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 升级前备份

- 设备 DB（v114，290,816 字节）+ 偏好 XML 于安装前完整拉取：
  `db/legado_pre_upgrade_2.0.406.db`、`prefs/FlutterSharedPreferences_pre_upgrade.xml`。
- 备份后向库中注入批 31 验收数据（`db/seed_batch31.db`；脚本 `seed_batch31.py`）：
  4 个书源（QA源A/B/C + 既有批25源）、4 本书（A1 25 章 / A2 3 章 / B1 5 章 /
  1 本 notShelf 临时书 type=1024）、35 章目录与缓存正文。

### 1.2 Rust Android 构建

`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`
退出码 **0**；三个 ABI 的 `liblegado_ffi.so` 更新并复制到
`flutter_legado/android/app/src/main/jniLibs/`（arm64-v8a 00:51 / armeabi-v7a 00:52 /
x86_64 00:53）。日志：`logcat/rust_build_batch31.log`。

- **既有环境项（非本批引入）**：armv7 目标编译 `rar` 失败（`3 previous errors`），
  脚本按既有逻辑 `quickjs build failed; retrying without quickjs ...` 回退后成功；
  本机设备为 x86_64，不受影响。

### 1.3 Flutter 发布包

`cd flutter_legado && flutter build apk --release` 退出码 **0**，产物
`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`
（196,766,092 字节 / 187.7 MB，sha1 `558004bfc154b706ed112c452f19c028efecc526`），
`adb install -r` 成功。日志：`logcat/flutter_build_batch31.log`、`logcat/apk_sha1.txt`。

- APK badging / 设备 `dumpsys` 均实测 `versionName=2.0.408`、`versionCode=409`；
  关于页显示「版本 2.0.408」（`shots/49_about_version.png`）。
- 升级后首次启动 DB 自动迁移到 `PRAGMA user_version=116`，注入数据行数保持
  （books=4、book_sources=4），书架显示 A1/A2/B1，notShelf 临时书不显示
  （`shots/01_after_upgrade_shelf.png`）。

## 二、验收场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 书源书籍数（开关、多源/零本计数一致、关闭隐藏、重启保持、备份 JSON） | **PASS** | `shots/02~06`、`db/scene1_counts_vs_shelf.txt`、`prefs/pref_states.txt`、`backup/backup_prefs_assertions.txt` |
| 2 | 目录显示反转（单开反序、章节跳转、当前章高亮与进度） | **PASS** | `shots/11~15`、`db/scene2_baseline_readconfig.txt`、`db/scene2_readconfig_after_toggle.txt` |
| 3 | 组合语义（双开回原序、单开倒序目录反序） | **PASS** | `shots/16~17`、`db/scene3_readconfig_double_on.txt`、`db/scene3_readconfig_reverseToc_only.txt` |
| 4 | 持久化回写（返回阅读器重开、改字号后重开、详情页往返） | **PASS** | `shots/18~27`、`shots/30~34`、`db/scene4_*.txt` |
| 5 | 网页端 `/getBookshelf` 含 `reverseTocDisplay`、`/saveBook` 后 App 内仍生效 | **PASS** | `web/getBookshelf.json`、`web/saveBook_payload.json`、`web/saveBook_response.json`、`db/scene5_after_web_save.txt`、`shots/36~37` |
| 6 | 回归（书架/阅读器/发现/订阅/设置/关于）+ FATAL/ANR | **PASS** | `shots/38~46`、`shots/49`、`logcat/logcat_full_session.log`、`logcat/fatal_anr_counts.txt` |
| 7 | 清理（恢复 DB/偏好、停止 Web 服务、移除测试数据） | **PASS** | `db/scene7_cleanup_verify.txt`、`db/scene7_config_after_cleanup.txt`、`shots/47~48` |

## 三、逐场景说明

### 场景 1：书源书籍数 — PASS

1. **默认关**：进入「我的 → 书源管理」，列表仅显示源名/分组/开启状态，无计数
   （`shots/02_source_list_default.png`）；打开右上「更多选项」，「显示书籍数量」
   复选框为未勾选（`shots/03_source_menu.png`）。
2. **开启后计数与书架一致**：勾选后 4 个源行分别显示
   「书架：2 本 / 书架：1 本 / 书架：0 本 / 书架：0 本」
   （`shots/04_source_count_on.png`）。DB 口径核对（`db/scene1_counts_vs_shelf.txt`）：
   - QA源A：A1、A2 两本在架（type=0）→ 2；同源 notShelf 临时书（type=1024）被排除；
   - QA源B：B1 一本 → 1；
   - QA源C 与既有批25源无书 → 0。
   书架实际展示 A1/A2/B1 三本（`shots/01_after_upgrade_shelf.png`），与计数口径一致。
3. **关闭后隐藏**：再次勾选取消后列表计数消失，偏好实测 `showSourceBookshelfCount=false`。
4. **重启保持**：重新开启后 `force-stop` 并重启应用，书源列表仍显示「书架：N 本」，
   菜单复选框实测 `checked=true`，偏好 XML 为 `showSourceBookshelfCount=true`
   （`shots/05_source_count_after_restart.png`、`shots/06_source_menu_checked_after_restart.png`、
   `prefs/pref_states.txt`）。
5. **备份 JSON**：应用内「备份与恢复 → 备份」生成 v5 备份
   （设备 `legado_backup_1793206912690.json`，已拉取为 `backup/legado_backup_batch31.json`），
   `appPrefs.showSourceBookshelfCount = true`，断言见 `backup/backup_prefs_assertions.txt`。

### 场景 2：目录显示反转（单开） — PASS

- 基线：A1 的 `readConfig={"reverseToc":false,"reverseTocDisplay":false}`
  （`db/scene2_baseline_readconfig.txt`）；打开目录显示 5/25，列表按原始顺序，
  视口定位当前章第 5 章（`shots/11_toc_normal.png`）。
- 勾选「目录显示反转」后列表整体反序（视口自动定位到当前章第 5 章，顶部 5/25），
  DB 落库 `reverseTocDisplay=true`（`shots/13_toc_reversed.png`、
  `db/scene2_readconfig_after_toggle.txt`）。
- 点击「第10章」正确跳转：阅读器正文为第 10 章、进度 40%，DB
  `durChapterIndex=9 / durChapterTitle=第10章 QA-QA批31书A1-10`（`shots/14_jump_ch10.png`）。
- 重开目录：顶部「第10章… 10 / 25」，反序列表中第 10 章行粉色高亮
  （`shots/15_toc_current_ch10_reversed.png`）。

### 场景 3：组合语义 — PASS

- **双开回原序**：同时勾选「倒序目录」+「目录显示反转」，列表回到原始正序
  （第10、11、12…），当前章仍为 10/25（`shots/16_toc_double_reverse.png`），
  DB `reverseToc=true, reverseTocDisplay=true`（`db/scene3_readconfig_double_on.txt`）。
- **单开倒序目录**：取消「目录显示反转」保留「倒序目录」，数据反序
  （第11、10、9…）（`shots/17_toc_reverseToc_only.png`），DB
  `reverseToc=true, reverseTocDisplay=false`（`db/scene3_readconfig_reverseToc_only.txt`）。
- 全程点击/高亮按真实章节 index 工作，展示顺序不改变章节身份。

### 场景 4：持久化回写 — PASS

1. **目录页勾选 → 返回阅读器 → 重开目录**：设置为仅「目录显示反转」后返回阅读器，
   再次打开目录仍为反序且菜单「目录显示反转」为勾选态
   （`shots/18~20`）；阅读器「更多」菜单实测 `checked=true`
   （`shots/21_reader_more_menu_after_toc.png`），说明返回时阅读器已按 DB 重读
   `readConfig`（批 31b P1 修复生效）。
2. **阅读器改字号后重开目录**：阅读界面字号 20 → 22 并保存
   （`shots/22~26`），重开目录仍反序、DB
   `reverseTocDisplay=true` 未被还原（`shots/27_toc_after_font_change.png`、
   `db/scene4_after_font_change.txt`）。
3. **书籍详情页往返**：书架长按 A1 进入详情 → 查看目录，改为
   「倒序目录开 / 目录显示反转关」（`shots/30~31`、`db/scene4_detail_toc_config.txt`）；
   返回详情再进目录，列表仍为反序且菜单状态一致
   （`shots/32~34`，复选框实测 `倒序目录=true / 目录显示反转=false`）。

### 场景 5：网页端 — PASS

- 「我的 → Web 服务」开启，状态显示 `running on port 1122`（`shots/36_web_service_on.png`），
  设备监听 `0.0.0.0:1122 LISTEN`。
- `curl http://192.168.100.62:1122/getBookshelf` HTTP **200**、`isSuccess=true`，
  4 本书均带 `readConfig`；A1 为 `reverseToc=true / reverseTocDisplay=true`
  （`web/getBookshelf.json`）。
- 网页端保存往返：取 A1 JSON 修改 `customTag=qa-web-save-批31` 后
  `POST /saveBook` HTTP **200**、`isSuccess=true`（`web/saveBook_payload.json`、
  `web/saveBook_response.json`）。DB 实测 `customTag` 已更新且
  `readConfig` 仍为 `reverseToc=true, reverseTocDisplay=true`
  （`db/scene5_after_web_save.txt`）。
- App 内复查：详情 → 目录菜单两项仍均为勾选（`shots/37_toc_menu_after_web_save.png`），
  设置未被网页保存还原。

### 场景 6：回归与稳定性 — PASS

- 书架、阅读器（打开/翻页/退出、字数与缓存状态）、发现页、订阅页（空态正常）、
  我的/设置、备份与恢复、关于页均正常：`shots/38~46`、`shots/49_about_version.png`。
- 全量 logcat（00:53 安装启动 ~ 01:11，含验收操作；`logcat/logcat_full_session.log`）：
  - `FATAL EXCEPTION` = **0**；
  - `ANR in` = **0**；
  - `E/flutter|W/flutter` = **0**；
  - `io.legado` 相关行 127 行单独留档 `logcat/logcat_app_lines.txt`。
- dropbox 崩溃记录最近一条为 2026-10-28 21:33（本会话前），会话期间无
  `data_app_crash` / `data_app_anr`（`logcat/dropbox_crash_anr.txt`）。
- **环境噪声**：crash buffer 中多条 `Cmdline: uiautomator` 的 SIGSEGV 来自本验收
  反复调用的 `uiautomator dump` 进程自杀（AGENTS.md 已登记该 MuMu 噪声），
  无一条属于 `io.legado.flutter_legado`（`logcat/crash_buffer_uiautomator_noise.log`）。

### 场景 7：清理 — PASS

- 设备 DB 已恢复为升级前原始文件（290,816 字节，v114 → 启动后自动迁移到 v116），
  WAL/SHM 删除；启动复核：books=0、chapters=0、cached_chapters=0、book_sources=1，
  无 `qa.local` 残留（`db/scene7_cleanup_verify.txt`、`shots/48_after_cleanup_restore.png`）。
- 偏好恢复为升级前 5 键集合，`showSourceBookshelfCount` 已移除
  （`db/scene7_cleanup_verify.txt`、`prefs/pref_states.txt`）。
- Web 服务已在 UI 关闭，`config:webService` 不存在、1122 端口关闭
  （`db/scene7_config_after_cleanup.txt`、`shots/47_web_service_off.png`）。
- 已删除设备临时文件：`/data/local/tmp/pre_upgrade.db`、`pre_upgrade_prefs.xml`、
  `qa_seed_batch31.db`、`/sdcard/qa_ui.xml`，以及本次验收生成的 2 个备份 JSON；
  `adb reverse --list` 为空。

## 四、发现、限制与观察

| 类型 | 项 | 说明 | 影响 |
|---|---|---|---|
| 环境 | uiautomator 噪声崩溃 | crash buffer 中 `uiautomator` 进程 SIGSEGV 为 MuMu 已知行为，与应用无关；主 logcat FATAL/ANR 为 0 | 不阻塞 |
| 环境 | 备份目录 SAF 选择 | Android 15 禁止直接使用 Download 根目录，需进入子目录（`Download/legado`）并授权；首次授权对话框停留需二次点击 | 不阻塞，备份成功 |
| 已登记边界 | `updateBook` 整书写回仅携带 Dart 建模字段 | 目录页勾选后 DB `readConfig` 被重写为 Dart 建模子集（`tocExpanded`/`manualReplaceRuleIds` 等未建模键不落盘）；本次种子数据未含这些键，未观察到用户数据丢失 | 批 31b 已登记，建议后续单键 FFI `bookUpdateReadConfigField` |
| 观察 | 计数非实时 | 「书架：N 本」只在 `loadSources` 时刷新，验收期间新建/移书后需重进书源管理才更新 | 契约已登记（仅 loadSources 刷新） |

未发现批 31 相关功能缺陷。

## 五、结论

批 31 设备验收 **通过**：书源列表「书架：N 本」计数与书架实际在架书源书籍数一致，
开关可隐藏/重启保持且随偏好备份 JSON 往返；目录显示反转为纯展示反序，章节跳转、
当前章高亮与进度保持真实 index；与「倒序目录」组合语义正确（双开回原序）；
目录页配置回写阅读器/详情页均持久化，改字号与网页端 `/saveBook` 后不被还原；
`/getBookshelf` 正确投影 `reverseTocDisplay`。全流程应用 FATAL/ANR 为 0，
设备数据与偏好已恢复，Web 服务已停止，测试文件已清理。

— QA（ZCode） 2026-10-29
