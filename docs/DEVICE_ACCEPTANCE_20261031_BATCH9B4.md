# 批 9b-4 设备验收报告（全局 UserAgent 生效 · 显式书源 UA 优先 · 启动同步 · 空白/控制字符 · 备份恢复同步 · 回归）

> 范围：批 9b-4——全局「浏览器标识（UserAgent）」设置经 `setConfig`
> 同步到 Rust 网络层（`config:userAgent` + 进程级默认 UA），请求期对
> **未显式设置 UA** 的书源请求注入；显式书源 header UA 始终优先；启动
> 时 SharedPreferences → Rust 同步；空白/控制字符回落内置；备份恢复后
> 同会话回写；顺带回归网络书源搜索/阅读、RSS、封面图片。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测 `device`）。
>
> **结论**：**7 组场景全部 PASS、0 FAIL、0 BLOCKED**。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0、OOM=0；全会话 mock 请求
> 日志 0 次重复 UA、0 次含换行头出网。
> 登记 4 项非缺陷观察（§6.1 armv7 quickjs 回退、§6.2 封面请求 UA、
> §6.3 TOC 夹具形状迭代、§6.4 恢复夹具构造方式）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM_G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带；shell 实测 uid=0） |
| 取证权限 | release 包非 debuggable，`run-as` 报 `package not debuggable`；DB/prefs 证据经 MuMu root shell 直读（只读与场景 7 清理，未改业务代码） |
| 应用包名 | `io.legado.flutter_legado`（启动入口 `io.legado.flutter.MainActivity`） |
| 验收版本 | versionName **2.0.428** / versionCode **429**（`dumpsys package` 实测，与 pubspec `2.0.428+429` 一致） |
| 源码基线 | `master` HEAD `41f0e1587f`（`chore: 批9b-4 收尾`；含 `40159be63c` 审查回修、`916851e8bf` 测试） |
| 验收时间 | 2026-10-31 21:11 ~ 21:40（截图/日志时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch9b4/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1031f/`（15 张） |

### 1.1 Rust .so 重建（本批有 Rust 变更：先 Rust 后 Flutter）

| 步骤 | 结果 |
|---|---|
| 构建命令 | `pwsh -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`（pwsh 7.6.6） |
| 结果 | EXIT=0，`=== Build complete! ===`，三 ABI 均复制到 `flutter_legado/android/app/src/main/jniLibs/` |
| arm64-v8a | `liblegado_ffi.so` 51,676,968 B，mtime **21:13:08**，sha256 `94d561375e48…47019eb8ab`；meta **quickjs:true** |
| armeabi-v7a | 34,333,684 B，mtime 21:14:07，sha256 `9f6a4eea398b…47e0d709c`；meta **quickjs:false**（32 位回退，§6.1） |
| **x86_64（本设备）** | **51,863,520 B，mtime 21:14:57，sha256 `59fa3deec26b…d7ebaeb696`；meta quickjs:true** |
| .so meta | `contentHash=-993835076`、`rustFingerprint=d6090e3288950244…5e758e4c`、`builtAt=2026-10-31T21:14:58`。构建前旧 meta 指纹为 `2b1ec3e0…`（19:15 构建），与 HEAD 指纹不一致，本次重建已刷新 |
| Flutter APK | `flutter build apk --release` EXIT=0，`assembleRelease 103.2s`，199,364,852 B（190.1MB）；sha256 `4ce3c0e0a301b1f5f0386189f00fef485127ea45a7b2b04d0e244cbf5e68d25f` |
| 安装 | `adb uninstall`（清空旧数据）→ `adb install` Success；`dumpsys` versionName=2.0.428 / versionCode=429 |
| 启动冒烟 | 冷启动 COLD TotalTime 434ms；空书架正常渲染（`shots/00_launch.png`） |

### 1.2 静态分析与定向单测（交付前门禁）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0 |
| 启动同步单测 | `flutter test test/unit/startup_user_agent_sync_test.dart` | **7/7 passed**（写一次 / 相同不写 / 空清除 / 双空不写 / USE_MOCK / 读失败静默 / 写失败静默） |
| Rust UA 轮换/全局 | `cargo test -p legado-net --lib user_agent::tests` | **11/11 passed**（含控制字符拒绝、空白归一化、并发读写） |
| Rust 请求期注入 | `cargo test -p legado-net --lib test_global_user_agent_applied_when_header_missing` 等 3 项 | **各 1 passed**（全局注入 / 显式优先 / 空白回落内置） |
| FFI config | `cargo test -p legado-ffi --lib config_api::tests` | **3/3 passed**（setConfig 即时更新运行期 / restore 回填 / CRUD） |
| FFI search | `cargo test -p legado-ffi --lib api::search::tests::test_ensure_default_user_agent` | **3/3 passed**（缺省补全局 / 全局设置生效且不覆盖书源 UA） |

### 1.3 测试夹具（宿主 mock + 两个书源 + RSS 源）

| 项 | 说明 |
|---|---|
| Mock 服务 | `tmp_debug/device_acceptance_20261031_batch9b4/server/mock9b4.py`，监听 **0.0.0.0:18090**（宿主 IP `192.168.100.52`），GET 全路径记录 `路径 + User-Agent`；重复 UA 头以 `" \| "` 连接（用于检测重复头） |
| 请求日志 | `server/mock_access9b4.log`（48 行，含启动探针与全部业务请求）；`logcat/mock9b4_run.log` |
| 书源 A | `QA9B4-A`，base `/a`，**不设 header UA**；搜索/详情/目录/正文全链走 `/a/*` |
| 书源 B | `QA9B4-B`，base `/b`，header `{"User-Agent":"ExplicitSourceUA/1.0"}`；全链走 `/b/*` |
| 源 JSON | `data/qa9b4_sources.json`（导入预览显示「QA9B4-A 新增 / QA9B4-B 新增」） |
| RSS 源 | `QA9B4-RSS`（`data/qa9b4_rss_sources.json`，规则 `//item`），feed `/rss` 返回 2 篇文章 |
| 封面 | `/cover/*.png` 返回 40x60 纯色 PNG；搜索列表可见蓝色封面（`shots/12_search_covers.png`） |
| 设备可达性 | 宿主 `curl` 与设备 `toybox nc` 双向验证 `/health` 200；日志记录 `HostProbe/1.0`、`DeviceProbe/1.0` |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 全局 UA 生效：设置 `GlobalUA/9.9` → 冷启动 → A 源搜索/详情/目录/正文 | **PASS** | 四步请求全部 `UA=GlobalUA/9.9`（21:21:07 / 21:21:22 / 21:22:16）；设置页与 DB 均为 GlobalUA/9.9 |
| 2 | 显式 UA 优先：B 源 header `ExplicitSourceUA/1.0` 走同链 | **PASS** | 搜索/详情/目录/正文全部 `UA=ExplicitSourceUA/1.0`；无 GlobalUA、无重复头（`grep " \| "`=0） |
| 3 | 启动同步：冷启动保持 GlobalUA；清空回落内置；重启仍内置 | **PASS** | 分叉注入冷启动日志「已同步到 Rust：GlobalUA/9.9」+ DB 更新 + 请求 GlobalUA；清空后请求/重启均为内置 Chrome UA（记录原值） |
| 4 | 空白/控制字符：清空值、含换行值保存后回落内置、不崩溃/不发非法头 | **PASS** | 空白：prefs 键删除、DB 空串、请求内置；换行：prefs `&#10;`、DB hex 含 `0A`、请求内置、结果 2/2、无 400/断连 |
| 5 | 备份恢复同步：备份 → 改 UA → 恢复 → 同会话请求用恢复值 | **PASS** | 恢复前请求 `ChangedUA/5.5` → 恢复（备份值 `BackupUA/7.7`）→ 未重启请求 `BackupUA/7.7`；prefs/DB 同步一致 |
| 6 | 回归：网络书源搜索/阅读、RSS、封面、FATAL/ANR | **PASS** | A/B 搜索 2 本、详情、目录 3 章、正文渲染；RSS 2 篇 + 文章详情；封面 PNG 显示；FATAL=0、ANR=0、overflow=0、OOM=0 |
| 7 | 清理：停 mock、删测试源/书/文件、prefs 默认、空书架 | **PASS** | book_sources=0、books=0、chapters=0、rssSources=4（默认）、caches=2（默认）、prefs 无 userAgent；端口 18090 无监听；版本保留 2.0.428/429 |

## 三、逐场景证据

### 3.1 场景 1：全局 UA 生效（A 源全链）

- **设置**：其他设置 → 用户代理 → 输入 `GlobalUA/9.9` → 确定。prefs
  `flutter.userAgent=GlobalUA/9.9`，DB `config:userAgent=GlobalUA/9.9`
  （`shots/08_settings_ua_global.png`；直读证据 `data/prefs_db_evidence_9b4.txt`）。
- **冷启动**：force-stop 后 `am start -W` COLD TotalTime 324ms；
  logcat「[启动] UserAgent 同步耗时：0ms」（prefs 与 Rust 同值，按设计不写库）。
- **请求链**（mock 日志）：

| 时间 | 路径 | UA |
|---|---|---|
| 21:21:07 | `/a/search?q=qa9b4` | `GlobalUA/9.9` |
| 21:21:22 | `/a/book/QA9B4A-1` | `GlobalUA/9.9` |
| 21:21:22 | `/a/toc/QA9B4A-1` | `GlobalUA/9.9` |
| 21:22:16 | `/a/content/QA9B4A-1/1` | `GlobalUA/9.9` |
| 21:22:16 | `/a/content/QA9B4A-1/2` | `GlobalUA/9.9` |
| 21:22:16 | `/a/content/QA9B4A-1/3` | `GlobalUA/9.9` |

- **UI 实证**：搜索结果 2 本（`shots/12_search_covers.png`）；A 详情
  「共 3 章 / 在读 · 第1章」（`shots/04_detail_a_toc.png`）；阅读器第 1 章
  正文渲染（`shots/05_reader_a_global_ua.png`）。
- **结论**：搜索→详情→目录→正文每一步均携带全局 UA，PASS。

### 3.2 场景 2：显式书源 UA 优先（B 源全链）

- **源配置**：B 源 `header` 字段为 JSON
  `{"User-Agent":"ExplicitSourceUA/1.0"}`（导入预览 `shots/01_sources_imported.png`）。
- **请求链**（同一全局 `GlobalUA/9.9` 下）：

| 时间 | 路径 | UA |
|---|---|---|
| 21:21:07 | `/b/search?q=qa9b4` | `ExplicitSourceUA/1.0` |
| 21:22:43 | `/b/book/QA9B4B-1` | `ExplicitSourceUA/1.0` |
| 21:22:43 | `/b/toc/QA9B4B-1` | `ExplicitSourceUA/1.0` |
| 21:22:53 | `/b/content/QA9B4B-1/1` | `ExplicitSourceUA/1.0` |
| 21:22:54 | `/b/content/QA9B4B-1/2` | `ExplicitSourceUA/1.0` |
| 21:22:54 | `/b/content/QA9B4B-1/3` | `ExplicitSourceUA/1.0` |

- **重复头检查**：mock 对每个请求读取 `get_all('User-Agent')` 并以 `" | "`
  连接；全会话 48 行日志中 `" | "` 出现 **0** 次——无全局/显式双 UA。
- **UI 实证**：B 详情「来源：QA9B4-B / 共 3 章」
  （`shots/06_detail_b_explicit_ua.png`）；阅读器正文
  （`shots/07_reader_b_explicit_ua.png`）。
- **结论**：显式 header UA 覆盖全局，且不产生重复 UA，PASS。

### 3.3 场景 3：启动同步 / 清空回落 / 重启保持

- **3a 正常冷启动保持**：场景 1 的冷启动（21:20:49）后请求仍为
  `GlobalUA/9.9`，说明设置值跨进程存活。
- **3b 启动同步分支实证（分叉注入）**：为覆盖「prefs 与 Rust 不一致」
  的同步分支，在 app 停止时用 root 将 prefs 改为 `GlobalUA/9.9`，而
  Rust caches 保持 `CtrlUA/1.0\nEvilTail`。冷启动 logcat：
  `[启动] UserAgent 已同步到 Rust：GlobalUA/9.9`；DB 随即变为
  `config:userAgent=GlobalUA/9.9`；21:26:46 请求
  `UA=GlobalUA/9.9`——启动同步链路完整生效。
- **3c 清空回落**：设置页用户代理清空 → 确定。prefs `userAgent` 键删除，
  DB `config:userAgent` 为空串；21:24:48 A 源搜索请求 UA 回落内置：

```
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
```

  （`shots/09_settings_ua_cleared.png`）
- **3d 重启仍内置**：force-stop + 冷启动（21:24:57，TotalTime 364ms），
  不改设置再搜索（21:25:05），UA 仍为上述内置 Chrome 值；启动日志无
  「已同步到 Rust」（双空不写库），PASS。

### 3.4 场景 4：空白 / 控制字符

- **空白**：见 §3.3 3c；值清空后 prefs 键删除、DB 空串，请求回落内置，
  无崩溃。
- **含换行**：用户代理对话框 `maxLines: 3` 支持换行；输入
  `CtrlUA/1.0` + Enter + `EvilTail`，编辑框实测文本
  `'CtrlUA/1.0\nEvilTail'`（`data/ui_ua_ctrl_typed.xml`），确定保存后：
  - prefs：`<string name="flutter.userAgent">CtrlUA/1.0&#10;EvilTail</string>`
  - DB：`config:userAgent|4374726C55412F312E300A4576696C5461696C`
    （`0A` 即 LF，原样落库）
  - 请求：21:26:17 B 源显式 UA 正常；21:26:18 A 源回落内置 Chrome UA；
    搜索结果 2/2 正常（`data/ui_search_ctrl.xml`）；mock 未收到含换行
    头/畸形请求，无 400、无断连。
- **代码/单测口径**：`legado_net::set_default_user_agent` 对 trim 后空串
  或含 `char::is_control` 的值一律清除覆盖（回落内置），
  `test_set_default_user_agent_rejects_control_chars` 通过。
- **结论**：空白与控制字符均安全回落，PASS。

### 3.5 场景 5：备份恢复同步（同会话）

- **备份**：备份与恢复 → 备份路径 `/storage/emulated/0/Download/legado`
  → 备份成功，生成 `legado_backup_1793453305113.json`（2,955 B）。其
  `appPrefs.userAgent` 实测为 `GlobalUA/9.9`。
- **构造区分值**：将备份副本 `qa9b4_backup_restoreUA.json` 的
  `appPrefs.userAgent` 改为 `BackupUA/7.7`（其余内容原样），push 回设备。
- **改当前 UA**：设置页改为 `ChangedUA/5.5`（prefs/DB 均更新），
  21:29:59 搜索请求实测 `UA=ChangedUA/5.5`。
- **恢复**：备份与恢复 → 长按「恢复」→ 文件选择器选中
  `qa9b4_backup_restoreUA.json` → 确认「恢复」；21:32:08 文件选择器
  加载该文件（logcat `FilePickerUtils: File loaded ...`），恢复完成后：
  - prefs `flutter.userAgent=BackupUA/7.7`
  - DB `config:userAgent=BackupUA/7.7`
  - **未重启**的同会话搜索（21:32:23）`UA=BackupUA/7.7`，B 源仍为
    `ExplicitSourceUA/1.0`
- 恢复同时带回书源 A/B（同会话搜索仍 2/2）。
- **结论**：恢复后 `_reloadPrefsAfterRestore` 的 UA → Rust 同写生效，PASS。

### 3.6 场景 6：回归

- **网络书源搜索/阅读**：A/B 搜索「qa9b4」结果 2 · 进度 2/2；A/B 详情、
  3 章目录、正文渲染均正常（`shots/03~07`）。
- **RSS**：导入 `QA9B4-RSS` → 打开订阅源，`/rss` 请求携带
  `UA=BackupUA/7.7`，列表显示「QA9B4 RSS 文章一/二」；打开文章详情显示
  标题、时间、来源与摘要（`shots/11_rss_article.png`）。
- **封面图片**：搜索结果蓝色封面来自 `/cover/QA9B4A-1.png`、
  `/cover/QA9B4B-1.png`，PNG 正常解码显示
  （`shots/12_search_covers.png`）。
- **稳定性**：全会话 logcat 5,482 行，`FATAL EXCEPTION`=0、
  `ANR in io.legado`=0、`RenderFlex overflowed`=0、`OutOfMemoryError`=0；
  无 `builder error`/非法 header 记录。

### 3.7 场景 7：清理与恢复

- **应用内数据**：书源管理全选删除 2 个测试源 →「已删除所选书源」，
  列表「暂无书源」；RSS 源管理删除 `QA9B4-RSS`（余 4 个默认源）。
- **DB 复核**：`books=0`、`book_sources=0`、`chapters=0`、
  `rssSources=4`、`caches=2`（`config:recordHttpLog=false`、
  `config:autoTaskService=true`，均为默认）。
- **prefs 复核**：`userAgent`、`app_backup_path`、`rssSourceImportUrls`、
  `lastBackup` 键已删除；高级设置「用户代理」行显示「默认」
  （`shots/13_settings_ua_default_final.png`）。
- **设备文件**：`/sdcard/Download/legado/legado_backup_1793453305113.json`
  与 `qa9b4_backup_restoreUA.json` 已删除（`ls` 无匹配）。
- **mock**：进程已停止，`netstat` 无 18090 监听；`/health` 不可达。
- **保留版本**：dumpsys 仍为 2.0.428/429；冷启动空书架
  （`shots/99_final_empty_shelf.png`）。

## 四、FATAL / ANR 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado.flutter_legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| mock 重复 User-Agent 头 | **0** |

## 五、证据清单（`tmp_debug/device_acceptance_20261031_batch9b4/`）

| 类别 | 文件 |
|---|---|
| 构建 | `logcat/rust_build_9b4.log`（三 ABI + quickjs 回退记录）、`logcat/flutter_build_9b4.log`、`data/build_meta_9b4.txt` |
| .so/.meta | `flutter_legado/android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/liblegado_ffi.so(.meta)`（哈希/时间见 §1.1） |
| 夹具 | `server/mock9b4.py`、`server/mock_access9b4.log`、`server/qa_ui.py`、`data/qa9b4_sources.json`、`data/qa9b4_rss_sources.json`、`data/backup_orig.json`（真实备份）、`data/qa9b4_backup_restoreUA.json`（恢复夹具） |
| UA 取证 | `data/ua_evidence_9b4.txt`（逐场景请求行）、`data/prefs_db_evidence_9b4.txt`（prefs/caches 直读） |
| UI dump | `data/ui_*.xml`（导入预览/UA 对话框/详情/目录/搜索/控制字符/恢复选择器等） |
| 单测/分析 | `logcat/dart_analyze_9b4.log`、`logcat/flutter_test_ua.log`、`logcat/cargo_test_net_ua.log`、`logcat/cargo_test_ffi_config_ua.log`、`logcat/cargo_test_ffi_search_ua.log` |
| 会话日志 | `logcat/full_session_9b4.log`（5,482 行）、`logcat/final_cleanup.log` |
| 截图副本 | `docs/materials_1031f/`（15 张：00~13、99） |

## 六、说明与遗留（非缺陷）

### 6.1 armeabi-v7a quickjs 回退（既有环境项）

- 构建日志显示 armv7 的 quickjs 编译失败（`rar` crate `u64: ToUsize`
  不满足 32 位目标），脚本自动回退无 quickjs；meta 为 `quickjs:false`。
  与批 9b-1 报告 §6.2 同源，非本批引入；本设备 ABI 为 x86_64，
  验收所用 .so `quickjs:true`，不影响本批结论。

### 6.2 封面图片请求 UA（观察项）

- 书源搜索/详情/目录/正文均按预期使用全局/显式 UA；封面缩略图请求
  `/cover/*.png` 使用 `Dart/3.12 (dart:io)`（Flutter 图片加载器自身 UA），
  不读取全局 UA。本批场景口径仅要求「封面图片加载」回归（已正常显示），
  若后续要求封面域名也遵循全局 UA，需单独评估图片加载链路。

### 6.3 TOC 夹具形状迭代（验收夹具修正）

- 首次详情请求时 mock `/toc` 返回裸数组而书源规则为 `$.chapters[*]`，
  目录为空；将 mock 改为 `{"chapters":[...]}` 后重新打开详情
  （21:22:06）目录 3 章正常。该次空目录为夹具形状问题，非应用缺陷；
  修正后的整链证据见 §3.1/§3.2。

### 6.4 备份恢复场景的夹具构造

- 备份由应用真实生成（含 appPrefs.userAgent=GlobalUA/9.9）；为使恢复值
  可与恢复前值区分，QA 在宿主将备份副本的 `userAgent` 改为
  `BackupUA/7.7` 后推回设备再走应用内长按恢复。恢复链路（含
  `_reloadPrefsAfterRestore` 的 UA → Rust 同步）为真实执行，未修改应用
  代码或 DB。

### 6.5 启动同步分叉注入（场景 3b 方法说明）

- 正常 UI 保存会同时更新 prefs 与 Rust，二者一致，无法自然产生分叉；
  为覆盖 `syncUserAgentOnStartup` 的「值不同才写」分支，在 app 停止时
  用 root 直改 prefs 为 GlobalUA 而保留 Rust 旧值，冷启动观察同步日志与
  DB 更新。该注入只改测试夹具状态，不修改应用代码。

## 七、结论

- 场景 1（全局 UA 对 A 源搜索/详情/目录/正文全链生效）：**PASS**。
- 场景 2（B 源显式 UA 优先、无重复头）：**PASS**。
- 场景 3（冷启动保持、启动同步分支、清空回落内置、重启仍内置）：**PASS**。
- 场景 4（空白/换行控制字符安全回落、无非法头、无崩溃）：**PASS**。
- 场景 5（备份恢复后同会话 UA 同步）：**PASS**。
- 场景 6（网络书源搜索/阅读、RSS、封面回归；FATAL/ANR=0）：**PASS**。
- 场景 7（清理恢复空书架、prefs 默认、mock 停止、保留版本）：**PASS**。
- 问题分级：P1/P2 无；P3 观察项 4（§6.1~§6.4，均不阻断本批验收）。

编写者：QA（ZCode 子代理）｜ 2026-10-31
