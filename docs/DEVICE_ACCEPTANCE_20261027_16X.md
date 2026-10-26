# 批 8~16 合并设备验收报告（2026-10-27）

> 范围：批 8（备份/恢复扩展、原版 zip 备份）、批 9（原版 zip 恢复映射）、批 15（RSS 引擎）、
> 批 16（直链上传规则 16b / 导出目标 Sheet 16c / 关联导入 16d / 导出回修 16e / 备份 v4 与 zip 直链 16f）。
> 设备：Windows 宿主 + MuMu「Test测试」实例（Android 15 / x86_64）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb root` 已生效，adbd 以 root 运行） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15 / ABI `x86_64` |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 应用包名 | `io.legado.flutter_legado` |
| 安装版本 | **versionName 2.0.391 / versionCode 392**（安装时间 2026-10-27 05:44:15） |
| 源码基线 | `master` HEAD `88e922c614`（16e/16f 收尾） |
| 验收时间 | 2026-10-27 05:36 ~ 06:13（+08:00） |
| 宿主 mock 服务 | `127.0.0.1:18080`（`tmp_debug/device_acceptance_20261027/mock_server.py`），经 `adb reverse tcp:18080 tcp:18080` 由设备以 `127.0.0.1:18080` 访问 |

### 1.1 Rust Android 构建（`rust/scripts/build-android.ps1 -Mode release`）

退出码 **0**；三 ABI 全部产出并复制到 `flutter_legado/android/app/src/main/jniLibs/`。

| ABI | 大小 | mtime | quickjs（.meta） |
|---|---|---|---|
| arm64-v8a | 50,207,392 B | 2026-10-27 05:38:03 | true |
| armeabi-v7a | 33,195,944 B | 2026-10-27 05:39:01 | **false（回退）** |
| x86_64 | 50,339,528 B | 2026-10-27 05:39:52 | true |

- `.so` 构建证据：`tmp_debug/device_acceptance_20261027/build_so.txt`、`build_rust_full.log`。
- **构建侧发现（见 §五 D2）**：armv7 的 quickjs 构建失败（`rar` crate 编译错误 `E0277`），脚本按既有回退逻辑改为无 quickjs 构建，`.meta` 记录 `quickjs:false`；本设备为 x86_64，不影响本次验收结论。
- 版本源指纹：`d17bc33a5e5a1980c315a72eb56d4a70dba94a99d9b2c64ce0cd4161b48247be`，FRB contentHash `-1452309514`。

### 1.2 Flutter 发布包（`flutter build apk --release`）

| 项 | 值 |
|---|---|
| 退出码 | 0（`√ Built build\app\outputs\flutter-apk\app-release.apk (184.6MB)`） |
| 路径 | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk` |
| 大小 | 193,580,844 B（184.6 MB） |
| sha256 | `1bee3f4fb3c4f4efb90526bba1544a9e19c0f780ff460cb09f3050a2397619f0` |
| sha1（.sha1 文件） | `7f93002fc05f5716654cae843b5b0d8463118a7e` |
| 安装 | `adb install -r` 成功（覆盖 2.0.374，数据未清空：书架 15 本、书源 533 个保留） |

- 证据：`build_apk.txt`、`final_env.txt`、`screens/00_launched_bookshelf.png`。
- 启动方式注意：应用主 Activity 为 **`io.legado.flutter.MainActivity`**（非 `io.legado.flutter_legado.MainActivity`），
  `am start -n io.legado.flutter_legado/.MainActivity` 会报 `Activity class does not exist`。

### 1.3 mock 服务与连通性

- `POST /upload`：解析 multipart，记录请求头 / 字段 / 文件名 / Content-Type / 大小 / sha1 / 前 256 字节，返回 `{"url":"http://127.0.0.1:18080/files/<sha1前12位>"}`；完整文件体落盘 `files/<sha1>.bin`。
- `POST /upload-fail`：固定 500（失败路径）。
- `GET /rss.xml`：RSS 2.0，2 个 item（description 含 `<div class="content">正文一/正文二</div>`）；`/rss_article_1.html`、`/rss_article_2.html` 文章页。
- 设备侧连通性实测（`toybox nc` 经 reverse 隧道）：`screens/../device_fetch.txt` 中返回 `HTTP/1.1 200 OK` 与完整 RSS 正文。
- **坑位记录**：① 宿主 Python 服务须绑定 `0.0.0.0`（仅绑 `127.0.0.1` 时 adbd 侧连接被拒）；② `adb root` 会重启 adbd 并清空 reverse 映射，**每次 adb root 后必须重新 `adb reverse`**（本次因未重登导致首次「测试」报 Connection refused，已复测）；③ `toybox nc -q N` 会在发送前关闭连接，改用 `(cat req; sleep 2) | nc host port` 才能收到响应。

## 二、场景结论总览

| # | 场景 | 结论 | 关键证据 |
|---|---|---|---|
| A | 直链规则配置 + 测试（16b） | **PASS** | `screens/01A_test_success.png`、`upload_log.jsonl` 第 1 条、`db_directlink_rule.txt` |
| B-1 | 导出所选 → 上传直链（16c/16e） | **PASS** | `screens/02B_upload_success.png`、`upload_log.jsonl` 第 2/4 条 |
| B-2 | 导出所选 → 保存到本地（系统另存） | **FAIL（应用崩溃）** | `crash_save_local.log`、`screens/02B_after_save2.png` |
| C | 高亮规则导出 → 再导入（16e P1-1） | **PASS** | `HighlightRules_exported.json`、`screens/03C_import_dialog.png`、`screens/03C_import_done.png` |
| D | 备份 v4 往返（16f） | **PASS** | `backup_v4.json`、`screens/04D_backup_done.png`、`screens/04D_restore_done.png` |
| E | 原版 zip 备份导入直链规则（16f） | **PASS** | `legacy_backup_min.zip`、`screens/05E_zip_restore.png`、`screens/05E_rule_after_zip.png` |
| F | RSS 引擎（15） | **PASS** | `screens/06F_rss_articles.png`、`screens/06F_article_detail.png` |
| G | 外部 JSON 关联导入（16d） | **PASS** | `screens/07G_source_import_new.png`、`screens/07G_source_import_done.png` |
| H | 回归（关于页 / 阅读器 / Web 服务 / RSS 管理页） | **PASS** | `screens/08H_about.png`、`screens/08H_reader_page4.png`、`web_service_check.txt` |
| I | 失败路径 + 临时文件清理（可选） | **PASS** | `screens/09I_upload_fail.png`、`screens/09I_retry.png`、`cache_before.txt` / `cache_after.txt` |

## 三、逐场景明细

### A. 直链规则配置 + 测试（16b）——PASS

**操作**：我的 → 设置 → 高级（其他设置）→ 直链上传规则；填写并点「测试」，随后「确认」保存。

**实际**：
1. 首次以**裸 URL**（`http://127.0.0.1:18080/upload`，无 `,{...}` 选项）测试，返回
   `FFI error: 上传 URL 选项缺少 body（无法定位 fileRequest 文件字段）`。
   该行为**与原版语义一致**（原版 `AnalyzeUrl.upload` 对缺失 `body` 会 `!!` 抛 NPE，见 `app/.../AnalyzeUrl.kt:715-717`），
   我方给出可读错误而非崩溃，属可接受差异（原文提示前缀 `FFI error:` 见 §五 D4）。
2. 按原版默认规则格式补齐选项后（`uploadUrl = http://127.0.0.1:18080/upload,{"body":{"file":"fileRequest"}}`、
   `downloadUrlRule = $.url`、`summary = 验收`），点「测试」→ **测试结果**弹窗展示
   `http://127.0.0.1:18080/files/bf21a9e8fbc5`（由 `$.url` 解析得出）。

**宿主侧收到的 multipart**（`upload_log.jsonl` 第 1 条）：
```
POST /upload  content-type=multipart/form-data; boundary=----LegadoBoundary0000...
files: [{name: "file", filename: "test.json", content_type: "application/json",
         size: 2, sha1: bf21a9e8..., head256: "{}"}]
```
**持久化**：`caches` 表 `config:directLinkUploadRule` =
`{"uploadUrl":"http://127.0.0.1:18080/upload,{\"body\":{\"file\":\"fileRequest\"}}","downloadUrlRule":"$.url","summary":"验收","compress":false}`
（中文 summary 无乱码）。证据：`db_directlink_rule.txt`。

### B-1. 导出所选 → 上传直链（16c/16e）——PASS

**操作**：设置 → 书源管理 → 勾选 1 个源（`QA本地音频B2`）→ 底部「更多选项」→ 导出所选 → 导出 Sheet →「上传直链」。

**实际**：
- Sheet 展示「导出文件：`bookSource_QA本地音频B2.json`」（本地另存文件名）。
- 上传成功面板展示：摘要 `验收` + URL `http://127.0.0.1:18080/files/2515847fccb8`，含「复制链接」「完成」。
- 宿主收到 multipart：`filename=bookSource.json`、`content-type=application/json`、`size=2100`，
  body 为书源数组（首元素 `bookSourceUrl=http://127.0.0.1:18080`、`bookSourceName=QA本地音频B2`）。
  即**上传文件名与本地文件名不同**（`bookSource.json` vs `bookSource_QA本地音频B2.json`），与实现注释一致，非缺陷。

### B-2. 导出所选 → 保存到本地——**FAIL（应用崩溃，可稳定复现）**

**操作**：同上，Sheet 点「保存到本地」→ 系统另存对话框（预填 `bookSource_QA本地音频B2.json`）→ 点「保存」。

**实际**：系统另存返回后应用**进程崩溃**并弹出「阅读 屡次停止运行」；`/sdcard/Download/bookSource_QA本地音频B2.json` 被创建但**内容为 0 字节**。
换到 `Download/legado/` 子目录复测，**同样崩溃**并留下 0 字节文件（`/sdcard/Download/legado/bookSource_QA本地音频B2.json`）。

**崩溃栈**（`crash_save_local.log`，两次复现）：
```
java.lang.RuntimeException: Failure delivering result ResultInfo{who=null, request=51063, result=-1,
  data=Intent { dat=content://com.android.providers.downloads.documents/document/... flg=0x43 }}
  to activity {io.legado.flutter_legado/io.legado.flutter.MainActivity}:
java.lang.SecurityException: Permission Denial: writing
  com.android.providers.downloads.DownloadStorageProvider uri
  content://com.android.providers.downloads.documents/document/6 from pid=..., uid=10055
  requires android.permission.MANAGE_DOCUMENTS, or grantUriPermission()
    at android.content.ContentResolver.openOutputStream(ContentResolver.java:1548)
    at w4.c.onActivityResult(SourceFile:66)        ← file_picker 8.3.7 插件实现
    at H4.d.onActivityResult(SourceFile:72)
    at io.legado.flutter.MainActivity.onActivityResult(SourceFile:1)
```

**根因初判**：`ExportFileService._saveBytes` 走 `FilePicker.platform.saveFile(bytes: ...)`（`file_picker 8.3.7`）。
该插件在 `onActivityResult` 内用 `ContentResolver.openOutputStream(uri)` 写字节；Android 15 的
`DownloadStorageProvider` 对 Downloads 根与子目录返回的 document URI 要求 `MANAGE_DOCUMENTS` 或显式 `grantUriPermission`，
插件侧未处理且**未捕获异常**，异常穿透到 `Activity.onActivityResult` → 进程死亡。
影响面：所有使用「保存到本地」的导出入口（书源、高亮规则、RSS、词典、TXT 目录规则、替换规则等）在该 ROM/Android 15 上都会崩溃，
且会残留 0 字节文件。修复方向（不在本次范围）：改用自建平台通道写 URI（try/catch + 提示）或改走 MediaStore。

### C. 高亮规则导出 → 再导入（16e P1-1）——PASS

**操作**：我的 → 高亮标注 →「+」新增规则（名称 `验收高亮`、匹配模式 `关键词`、开启「应用到标题」）→ 保存
→ 更多操作 → 导出规则 → **上传直链**（因 B-2 的崩溃，本项刻意用上传链路取回导出文件，导出内容代码路径相同）
→ 宿主取回文件后 push 回 `/sdcard/Download/HighlightRules.json`
→ `am start -a android.intent.action.VIEW -d file:///sdcard/Download/HighlightRules.json -t application/json -n io.legado.flutter_legado/io.legado.flutter.MainActivity`。

**导出文件内容**（`HighlightRules_exported.json`，409 B，上传文件名 `highlightRule.json`）：
```json
{"type":"highlightRule","rules":[{"id":1,"uuid":"54b32a35-448f-4a25-92bb-369a72db86f9","name":"验收高亮",
 "pattern":"关键词","isRegex":false,"applyToTitle":true,"scope":null,"isEnabled":true,
 "style":"{\"textColor\":4294630099}","timeoutMillisecond":3000,"applyToBody":true,"order":0}]}
```
四项 P1-1 字段（`uuid` / `order` / `applyToBody` / `timeoutMillisecond`）**齐全**。

**导入结果**：VIEW 打开后弹出「导入高亮规则」关联确认，条目标注 `新增`（1/1）→ 确认 → **「导入完成：共 1 个高亮规则：成功 1」**，
**无「uuid 非法」**；库内落库 `id=2, uuid=54b32a35-…, timeoutMillisecond=3000, applyToTitle=1, applyToBody=1, sortOrder=0`
（uuid 与导出文件完全一致，删除后重导得到新 id 但 uuid 保留）。

### D. 备份 v4 往返（16f）——PASS

**操作与结果**：
1. 设置 → 备份与恢复 →「备份」（首次选择备份目录 `Download/legado`，系统 SAF 授权）→
   产出 `legado_backup_1793051898410.json`（4,287,249 B），备份路径写入首选项 `app_backup_path=/storage/emulated/0/Download/legado`。
2. 拉取并断言（`backup_v4.json`）：
   `version = 4`；键集含 `appPrefs/backupTime/bookGroups/bookSources/bookmarks/books/dictRules/`
   **`directLinkUploadRule`**`/highlightRules/highlights/httpTTS/keyboardAssists/readRecords/replaceRules/rssSources/rssStars/ruleSubs/searchHistory/servers/txtTocRules`；
   `directLinkUploadRule = {"uploadUrl":"http://127.0.0.1:18080/upload,{\"body\":{\"file\":\"fileRequest\"}}","downloadUrlRule":"$.url","summary":"验收","compress":false}`。
3. 通过 UI 把规则改为 `http://127.0.0.1:18080/upload-fail,...` 并保存（库内已变）。
4. 长按「恢复」→ 选择该备份 JSON → 确认恢复 → 库内 `config:directLinkUploadRule` **回到 `/upload`**（summary `验收`）。

### E. 原版 zip 备份导入直链规则（16f zip 映射）——PASS

**构造**：`legacy_backup_min.zip`（227 B，单条目 `directLinkUploadRule.json` =
`{"uploadUrl": "http://127.0.0.1:18080/legacy", "downloadUrlRule": "$.url", "summary": "legacy"}`，明文未加密），
push 到 `/sdcard/Download/legado/`，长按「恢复」→ 选择该 zip → 确认。

**结果**：恢复成功；`config:directLinkUploadRule` 变为
`{"uploadUrl": "http://127.0.0.1:18080/legacy", "downloadUrlRule": "$.url", "summary": "legacy"}`（原文照搬，含原空格格式），
再度进入「直链上传规则」Sheet 可见 `legacy` / `$.url` / `legacy`（`screens/05E_rule_after_zip.png`）。
**附加验证**：该最小 zip 不含书架/书源段，恢复后 `books=15 / book_sources=533 / rssSources=4 / highlightRules=1` **未被清空**
（`db_counts_after_zip_restore.txt`），符合「缺失字段不触碰库内数据」的兼容语义。

### F. RSS 引擎（15）——PASS

**操作**：订阅 → 订阅源管理 → 更多选项 → 新增订阅源；源名称 `MockRSS`、源 URL `http://127.0.0.1:18080/rss.xml`，其余规则留空 → 保存
（落库 `MockRSS|http://127.0.0.1:18080/rss.xml|enabled=1`）。

**结果**：
- 订阅页出现 `MockRSS` 入口（`screens/06F_rss_tab_list2.png`）。
- 进入后**默认解析出 2 篇文章**：
  `Mock 文章一：RSS 引擎解析验证`（Mon, 26 Oct 2026 10:00:00 +0800）、
  `Mock 文章二：分页与正文规则验证`（Tue, 27 Oct 2026 09:30:00 +0800），描述列显示原始 HTML 片段；列表底部「已经到底了~」。
- 进入文章详情：标题、时间、源名正常，正文渲染 `正文一`（取自 description 的 `div.content`），WebView 载体，无报错。

**观察**：新增源点「保存」后提示「订阅源已添加」且数据已落库，但**页面仍停留在编辑页**（`screens/06F_save_pop_check.png`），
按 `_save()` 实现应在成功后 `Navigator.pop(true)`，实际未返回列表。非本批清单场景，登记待复核（见 §五 D3）。

### G. 外部 JSON 关联导入（16d）——PASS

**操作**：用 B-1 导出的书源 JSON 派生一份（`bookSourceUrl` 加 `/qa-g` 后缀、名称 `QA本地音频B2-导入验收`）push 到
`/sdcard/Download/BookSource_QA2.json`，`am start -a android.intent.action.VIEW -d file:///sdcard/Download/BookSource_QA2.json -t application/json -n io.legado.flutter_legado/io.legado.flutter.MainActivity`。

**结果**：弹出「导入书源」关联确认，条目 `QA本地音频B2-导入验收(QA)` 标注 **新增**（1/1）→ 确认 →「导入完成：共 1 个书源：成功 1」；
库内 `book_sources` 出现 `QA本地音频B2-导入验收`，总数 533 → **534**。
（同一文件原样再导入时，对话框正确识别为「已存在」；未选条目时「确认（0）」为禁用态。）

### H. 回归——PASS

| 子项 | 结果 |
|---|---|
| 关于页 | 可打开，显示 **版本 2.0.391**（`screens/08H_about.png`） |
| 阅读器 | 书架点《斗罗大陆》→ 打开正文，底栏 `3/11 3.9%` → 左滑翻页 → `4/11`（`screens/08H_reader2.png`、`screens/08H_reader_page4.png`），无崩溃 |
| Web 服务 | 我的页开关打开后提示 `running on port 1122`（`screens/08H_web_running.png`）；`adb forward tcp:1122` 后 `GET /api/health` → `200 {"service":"legado-server","status":"ok","version":"0.2.0"}`；`GET /` → 200；`GET /getBookshelf` 返回 `{"isSuccess":true,...}`（`web_service_check.txt`）。验收后已关闭开关并移除 forward（恢复到原状态 `config:webService=false`） |
| RSS 管理页 | 列表/菜单/新建均可用，无崩溃（`screens/ui_rss_mgr.xml`、`ui_rss_mgr_menu.xml`） |

### I. 失败路径 + 临时文件清理（可选）——PASS

**操作**：把直链规则改为 `http://127.0.0.1:18080/upload-fail,{"body":{"file":"fileRequest"}}` → 书源导出 →「上传直链」。

**结果**：
- 面板显示「上传失败」+ 真实错误文本：`FFI error: 上传失败,{"error": "mock upload failure", "detail": "验收注入的 500"}`
  （宿主确实收到 `POST /upload-fail` 并返回 500），并提供「复制错误」「取消」「重试」。
- 点「重试」→ 宿主第 2 次收到 `POST /upload-fail`（`upload_log.jsonl` 第 5、6 条），失败态可重试。
- 点「取消」关闭面板后，`/data/data/io.legado.flutter_legado/cache` 下**无新增导出临时文件**
  （`cache_before.txt` / `cache_after.txt` 仅顺序差异，无新增条目）。
  注：本次走的是 content 模式（书源 JSON），不上生成临时文件；`.js`/`.zip` 的 filePath 模式未在本场景覆盖。

## 四、证据文件清单（`tmp_debug/device_acceptance_20261027/`）

| 文件 | 说明 |
|---|---|
| `mock_server.py` | 宿主 mock 服务（/upload、/upload-fail、/rss.xml、文章页、/files/*） |
| `server.log`、`server_stdout.log` | 服务启动与逐请求日志 |
| `upload_log.jsonl` | 6 次上传的完整元数据（文件名/类型/大小/sha1/前 256 字节/结果） |
| `files/*.bin`、`files/*.json` | 各次上传的完整文件体与元数据快照 |
| `HighlightRules_exported.json` | 高亮规则导出原文件（409 B） |
| `BookSource_QA.json` / `BookSource_QA2.json` | 导出的书源 JSON（原样 / 改名派生用于导入） |
| `backup_v4.json` | v4 备份拉取件（4.28 MB） |
| `legacy_backup_min.zip` | 构造的原版最小 zip 备份 |
| `build_so.txt`、`build_apk.txt`、`build_rust_full.log`、`build_armv7_quickjs_fallback.log` | 构建元数据与日志 |
| `crash_save_local.log` | 系统另存崩溃完整栈 |
| `db_directlink_rule.txt`、`db_counts_after_zip_restore.txt`、`final_env.txt` | 库内配置/计数/环境快照 |
| `web_service_check.txt`、`device_fetch.txt` | Web 服务与设备侧网络连通性 |
| `cache_before.txt` / `cache_after.txt` | 临时文件清理对比 |
| `screens/*.png` / `screens/ui_*.xml` | 各场景截图与 UI 树（共 40+ 张截图） |
| `ui.py` | 交互辅助（dump/tap/replace/shot） |

> 证据目录位于 `tmp_debug/`，按项目惯例**不入库**；本报告入库。

## 五、遗留问题与观察

### D1（P1，阻断发布）「保存到本地」在 Android 15 崩溃并残留 0 字节文件
> **回修状态**：已修复并真机复验（2026-10-27 第二批回修，见 §七）。原始记录保留作追溯。
- 现象/栈见 §三 B-2，两个目标目录均可复现，属**共享导出链路的系统性问题**。
- 根因初判：`file_picker 8.3.7` 在 `onActivityResult` 内对 `DownloadStorageProvider` URI 调
  `openOutputStream` 抛 `SecurityException`（Android 15 要求 `MANAGE_DOCUMENTS` / `grantUriPermission`），异常未捕获直穿 Activity。
- 建议：改用自建平台通道（接收 URI 后 try/catch 写流并回传错误）或改走 MediaStore；必要时升级/替换 `file_picker` 并补 Android 15 回归。
- 需注意：另存失败时已创建 0 字节文档，属用户可见副作用，修复时应一并处理（写入失败删除占位文档或提示）。

### D2（构建风险）armeabi-v7a 的 `.so` 无 quickjs
- `cargo build --features quickjs` 在 armv7 失败：`error: could not compile 'rar' (lib) due to 3 previous errors`（`E0277`，nom `ToUsize`），
  脚本回退到无 quickjs 构建，`.meta` 记录 `quickjs:false`（`build_armv7_quickjs_fallback.log`）。
- 影响：32 位 ARM 设备上打包进 APK 的 `.so` 无 JS 引擎，`@js:` 规则/JS 书源会失效。x86_64/arm64 不受影响（本次验收设备为 x86_64）。
- 属既有构建问题，非本批引入，建议单独立项。

### D3（观察，待复核）新增订阅源保存后未返回列表
- 「订阅源已添加」提示出现、数据已落库，但页面停留在编辑页（`screens/06F_save_pop_check.png`）；
  代码 `_save()` 在成功后执行 `Navigator.pop(true)`。非本批清单场景，建议单独复核（可能与本页 Navigator 栈/嵌套路由有关）。

### D4（体验）错误文案统一带 `FFI error:` 前缀
- 直链测试/上传失败、网络错误等以 `FFI error: …` / `Network error: …` 原文呈现给用户（含 `os error 111` 等底层串）。
  内容真实可诊断，但面向用户的措辞偏技术，建议后续在展示层做映射。

### 测试数据说明（保留未清理）
- 直链规则：`config:directLinkUploadRule` = `http://127.0.0.1:18080/upload,{"body":{"file":"fileRequest"}}` / `$.url` / `验收`（验收结束时已从 `/upload-fail`、`legacy` 复位）。
- 高亮规则：`验收高亮`（uuid `54b32a35-448f-4a25-92bb-369a72db86f9`）。
- RSS 源：`MockRSS`（正式验收用）、`MockRSS2`（复核保存返回行为时新增，URL 带 `?n=2`）。
- 书源：`QA本地音频B2-导入验收`（场景 G 导入）；书架、其余书源未改动。
- 文件：`/sdcard/Download/legado/`（备份 JSON、legacy zip、0 字节残留文件）、`/sdcard/Download/BookSource_QA*.json`、`/sdcard/Download/HighlightRules.json`。
- 设备侧状态：Web 服务已关闭（`config:webService=false`），`adb forward tcp:1122` 已移除；
  验收结束后 `adb reverse tcp:18080` 已移除、宿主 mock 服务已停止（需要复验时按 §1.3 重新启动并重登 reverse）。

## 六、结论

- 批 8~16 的**核心链路在真机（MuMu Android 15 / x86_64）上全部打通**：直链规则配置与测试上传、导出上传闭环、
  高亮规则导出→关联导入（P1-1 字段完整、无 uuid 非法）、备份 v4 往返、原版 zip 直链规则映射、RSS 引擎默认解析与文章详情、
  外部 JSON 关联导入、失败路径与可重试性均通过；阅读器/关于页/Web 服务/RSS 管理页回归正常。
- **唯一阻断项**是「保存到本地」（系统另存）在 Android 15 上崩溃并留下 0 字节文件（D1），
  该问题位于共享导出链路，影响所有使用系统另存的导出入口，建议列为下一批 P1 修复项后再做发布验收。
- 另有构建侧风险 D2（armv7 无 quickjs）与本批外的观察 D3、体验项 D4，建议单独立项跟踪。

编写者：QA 代理 ｜ 2026-10-27

## 七、D1 第二批回修与限制登记（2026-10-27）

> 范围：独立复核（1 P1 + 5 P2 + 6 P3）逐项修复。版本号/CHANGELOG/updateLog/ACTIVE_PLAN 由主代理统一收尾，本节只记录修复口径与证据。

### 7.1 修复项与验证方式

| 项 | 修法 | 验证 |
|---|---|---|
| P1-1 回退必须落在用户选择的子目录 | 回退前从 SAF 文档 uri 推导 `RELATIVE_PATH`：`raw:`/`primary:` 走路径归一化、`msf:<id>` 走 `MediaStore.Files` 按 `_id` 查询、本 ROM 的 legacy 数字 id 走「显示名 + 最新修改」查询；全部失败时回 `FALLBACK_PATH_UNKNOWN` 中文原因（「无法确定所选文件夹，请选择内部存储 > Download 或子文件夹后重试」），**绝不静默写「下载」根** | JVM 单测 + 真机（§7.3） |
| P2-1 回退读回严格校验 | SIZE 必须精确等于写入字节数，且首 8 字节一致（参照 `StorageBridge.verifyWritten`）；读不到（null/-1）即判 `SAVE_VERIFY_FAILED` 并清理本次 insert 行 | JVM 单测 + 真机 |
| P2-2 替换已有文件失败不删 | `openOutputStream` 前查 `COLUMN_SIZE`；仅 `preSize == 0` 允许删除，`preSize > 0`（用户选择「替换」）或未知（null）只报错不删 | JVM 单测 |
| P2-4 清理新建空文档 | 同上判定；回退成功/失败后依次尝试 DocumentsProvider 删除 → `ContentResolver.delete` → 删除对应 MediaStore 空行 | 真机 `ls -l` 对比：**未达成**（本 ROM provider 连删除也拒绝，见 §7.3.1） |
| P2-3 API<29 行为 | 见 §7.2（选择方案 ②：明确中文原因 + 本登记） | JVM 单测 + 本节登记 |
| P3-1 回退触发条件放宽 | `openOutputStream` 返回 null、`FileNotFoundException`/`EACCES`/`permission denied`/`operation not permitted` 均纳入回退候选（异常链逐层判定） | JVM 单测 |
| P3-3 `viaMediaStoreFallback` 死字段 | 原生成功回传新增 `relativeDir`（如 `Download/legado/`），成功提示改为「已保存到「下载/legado」：xxx.json」；回退到根时为「已保存到「下载」：xxx.json」 | Dart 单测 + 真机 |
| P3-4 错误映射锚定 | 「含中文即放行」改为「行首锚定底层前缀 + 整串形态匹配」；`Permission Denial … 中文文件名` 仍映射为「没有写入权限，请换一个保存位置」，中文业务前缀文案不被吞 | Dart 单测 |
| P3-5 `normalizeFileName` 口径 | Dart 侧补 `trim()`，与 Kotlin 对齐（替换非法字符 + 去首尾空白） | Dart/JVM 单测 |
| P3-6 超时后迟到结果 | 已回 `TIMEOUT` 后迟到的 `onActivityResult` 记 `W` 日志（含 `resultCode` 与 uri），不静默丢弃 | 代码审查 |

JVM 用例：`SaveFileBridgeTest` **30 例**（`./gradlew.bat :app:testDebugUnitTest --tests "*SaveFileBridge*"` 全绿），覆盖回退条件、`shouldDeleteAfterFailure`、相对路径推导、`reasonOf` 中文映射、读回大小严格校验。

### 7.2 限制登记（P2-3，API < 29）

- **结论**：`Build.VERSION.SDK_INT < Q` 时回退分支返回错误码 `LEGACY_NOT_SUPPORTED`，面向用户的中文原因为
  「Android 10 以下暂不支持保存到下载目录，请选择其他位置」；SAF 直写路径不受影响。
- **选择方案 ② 的理由**：
  1. 该分支只在 SAF 写流被拒时触发。本 ROM 的拒写（`MANAGE_DOCUMENTS`）是 Android 15 `DownloadStorageProvider` 的行为；API 24~28 的 SAF 直写不经过该限制，回退属极端异常路径。
  2. 实现 `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)` + 运行时 `WRITE_EXTERNAL_STORAGE` 需要 `MainActivity` 转发 `onRequestPermissionsResult`、后台线程等待权限回调并处理授权竞态；当前设备档（Test/Test2 两实例）均为 Android 15，**没有 API<29 设备可复验**，属不可验证代码。
  3. 按项目完成定义（证据判定）与其交付无法验证的权限流程，不如给出明确中文原因并引导用户换一个位置（SAF 直写仍可完成保存）。
- **后续**：若要支持 API<29 下载目录回退，建议单独立项，先准备 API 24~28 设备/实例，再实现并复验权限流程。

### 7.3 真机复验（证据：`tmp_debug/device_acceptance_20261027/d1_verify3/`）

- 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，Android 15 / x86_64 / 1080x1920）。
- APK：`app-release.apk` sha256 `e7740c26…56aa55`（`apk_sha256_final.txt`），`adb install -r` 成功（versionName 2.0.391 / versionCode 392，版本号由主代理收尾）。
- FATAL EXCEPTION = **0**；SecurityException = 12（全部为 DownloadsProvider 拒写/拒删，符合预期；`full_logcat.txt`）。

| 用例 | 结果 | 证据 |
|---|---|---|
| 书源导出 → 系统对话框「下载」根 → 保存 | **PASS**：提示「已保存到「下载」：bookSource_QA本地音频B2 (10).json」；落盘 2100 B，JSON list 长度 1（`bookSourceUrl`/`bookSourceName=QA本地音频B2`）；authority 仍为 DownloadsProvider，写流被拒后回退 MediaStore 行 1000001420，`relativeDir=Download/` | `case1_picker_root.png`、`case1_saved_root.png`、`d1v3_booksource_root.json` |
| 书源导出 → 「下载」→ `legado` 子目录 → 保存 | **PASS**：提示「已保存到「下载/legado」：bookSource_QA本地音频B2 (2).json」；落盘 `/sdcard/Download/legado/` 2100 B，JSON 可解析；`docId=raw:/storage/emulated/0/Download/legado/…` → `Download/legado/`，回退行 1000001421 | `case2_picker_legado.png`、`case2_saved_legado.png`、`d1v3_booksource_legado.json`、`ls_legado_after_case2.txt` |
| 高亮规则导出 → 「下载」→ `legado` 子目录 → 保存 | **PASS**：提示「已保存到「下载/legado」：HighlightRules (2).json」；落盘 409 B，`type=highlightRule`、`rules=1`，回退行 1000001423 | `case5_replace_confirm.png`、`d1v3_highlight_legado.json`、`ls_legado_after_case3.txt` |
| 取消另存（对话框返回） | **PASS**：回到高亮规则页，无提示、无崩溃、无新日志（`onActivityResult` 走取消分支） | `case4_picker_cancel.png`、`case4_after_cancel2.png` |
| 同名文件保存（替换语义） | **本 ROM 不可达**：`CREATE_DOCUMENT` 对同名文件不弹「替换」确认，而是自动去重（已有 `HighlightRules.json` → 新建 `HighlightRules (1).json`，输出 `HighlightRules (2).json`），因此 `preSize > 0` 分支无法通过系统对话框触发；该分支由 JVM 单测 `shouldDeleteAfterFailure` 覆盖 | `case5_replace_confirm.png` |

**JSON 校验**（宿主侧 Python `json.loads`）：

| 文件 | 大小 | 解析结果 |
|---|---|---|
| `d1v3_booksource_root.json` | 2100 B | list，len=1，`bookSourceName=QA本地音频B2` |
| `d1v3_booksource_legado.json` | 2100 B | list，len=1，`bookSourceName=QA本地音频B2` |
| `d1v3_highlight_legado.json` | 409 B | dict，键 `rules`/`type` |

#### 7.3.1 残留限制：0 字节 SAF 文档无法删除（P2-4 未达成）

- 现象：本轮 3 次保存各新增 1 个 0 字节 SAF 文档（根 `bookSource_QA本地音频B2 (9).json`、`legado/bookSource_QA本地音频B2 (1).json`、`legado/HighlightRules (1).json`），文件落盘基线见 `zero_before_files.txt`、`zero_after_all.txt`、`zero_legado_after_all.txt`。
- 根因：该 ROM 的 `DownloadStorageProvider` **对创建请求放行、对写入与删除一并拒绝**（同一 `MANAGE_DOCUMENTS` 限制）：
  ```
  DocumentsContract.deleteDocument 失败：Permission Denial: writing … DownloadStorageProvider
    uri content://…/document/raw:… requires android.permission.MANAGE_DOCUMENTS, or grantUriPermission()
  ContentResolver.delete 失败：同上
  ```
  代码随后按「显示名 + 0 字节 + 同目录」删除对应 MediaStore 行兜底，也查不到可删行（`未找到可删除的 MediaStore 空行`：该行属主为 NULL/DownloadsUI，非本应用）。
- 影响：每次在「下载」入口保存会留下一个同名 0 字节占位文档（用户可见，但无数据损失），重名计数持续递增。
- 现有代码已尽力：`shouldDeleteAfterFailure(preSize == 0)` 判定 → DocumentsProvider 删除 → `ContentResolver.delete` → MediaStore 空行删除，三层均失败只记日志、不影响已成功的保存。**这不是应用逻辑缺陷，而是该 ROM provider 的权限模型限制**。
- 建议后续（需用户裁决，属交互/权限变更）：
  1. 改用 `ACTION_OPEN_DOCUMENT_TREE` 选文件夹 + `DocumentsContract.createDocument` 自建文档（可完全掌控创建/写入/清理，同时可覆盖 API<29 回退），但保存对话框形态与原版/参考版不一致；
  2. 申请 `MANAGE_EXTERNAL_STORAGE`（可读写删，但对应用商店合规影响大）。
- 另注：`legacy` 数字文档 id 判定为「下载」根（§7.1 P1-1）依据本 ROM 实测语义：根目录新建返回 legacy downloads 行 id（`document/12`），子目录新建返回 `raw:/…/legado/…` 或 `msf:<id>`；该判定写 INFO 日志（`legacy downloads 行 id（12）仅对应「下载」根文档`）。若其他 ROM 对数字 id 采用不同语义，存在误判到根目录的风险（已记录为剩余风险）。

编写者：编码代理（Android SAF/MediaStore 回退）｜ 2026-10-27
