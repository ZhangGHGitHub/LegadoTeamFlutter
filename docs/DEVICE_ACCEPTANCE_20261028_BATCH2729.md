# 批 27~29 合并设备验收报告（2026-10-28）

> 范围：批 27（DB schema v112→113：readRecord 13 列 + author 主键、book_memos；备份 v5）、
> 批 28（schema v113→114：highlightRules.group、rssSources.enableReadRecord；规则字段往返）、
> 批 29（登录头同站门控、RSS 阅读记录全局开关、按源清空）。
> 设备：MuMu「Test测试」实例（guest 直连 `192.168.100.62:5555`，实测在线）。
>
> **结论**：场景 1~8 全部 **PASS**。未发现阻断或失败项；2 项范围外实测观察、1 项 UI 不可达
> 负例（由单元测试覆盖）、1 项构建环境既有项，均记录在 §四。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例 index=1「Test测试」，`is_android_started=true`；guest wlan0 = 192.168.100.62/24） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15 / `x86_64` |
| adb | `D:\Android\platform-tools\adb.exe`（adbd 以 root 运行） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.401** / versionCode **402**（旧 DB `PRAGMA user_version=112`） |
| 验收版本 | versionName **2.0.406** / versionCode **407**（`dumpsys package` + 关于页实测） |
| 源码基线 | `master` HEAD `7e3caa61c0`（`chore: 批29 收尾（2.0.406+407 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-28 21:30 ~ 22:20（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261028_batch2729/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 Rust Android 构建

`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`
退出码 **0**，三个 ABI 的 `liblegado_ffi.so` 均更新并复制到
`flutter_legado/android/app/src/main/jniLibs/`（arm64-v8a 21:37 / armeabi-v7a 21:39 /
x86_64 21:41）。

- **既有环境项（非本批引入）**：armv7 目标编译 `rar 0.4.0` 失败
  （`u64: ToUsize` 不满足），脚本按既有逻辑 `quickjs build failed; retrying without quickjs ...`
  回退后成功；本机设备为 x86_64，不受影响。日志：`logcat/rust_build.log`。

### 1.2 Flutter 发布包

`cd flutter_legado && flutter build apk --release` 退出码 **0**，产物
`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`（197,830,940 字节，
188.7 MB，sha1 `cb053ef481697f64166426b55a0f16861c6bae3e`），`adb install -r` 成功。
日志：`logcat/flutter_build.log`。

### 1.3 设备数据准备

- 升级前先将 `/data/data/io.legado.flutter_legado/app_flutter/legado.db`（v112，274,432 字节）
  完整拉取备份：`db/legado_pre_upgrade_2.0.401.db`（+ wal/shm）。
- 为验证迁移，先在 v112 库中造旧数据（`db/seed_v112.db`）：3 本书、1 个书源、2 条阅读记录
  （其中 1 条为旧合并作者串 `\u001Eauthors:["作者B","作者C"]`）、1 个 RSS 源、1 条高亮规则；
  再覆盖安装 2.0.406。
- 升级前旧版 UI 正常显示 3 本书：`screenshots/00_pre_upgrade_shelf_2.0.401.png`。

## 二、验收场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 升级迁移（v112→v114、13 列/PK/新表字段、旧数据行数） | **PASS** | `db/scene1_migration_check.txt`、`screenshots/01_after_upgrade_shelf.png`、`db/legado_pre_upgrade_2.0.401.db` |
| 2 | 阅读记录（新增/更新、同名不同作者、旧合并作者串） | **PASS** | `db/scene2_read_record_delta.txt`、`screenshots/06_read_record_page.png`、`screenshots/68_read_record_final.png` |
| 3 | 备份 v5（13 字段/bookMemos）与 v5/v4 恢复 | **PASS** | `backup/backup_v5_assertions.txt`、`backup/backup_v5_with_memo_assertions.txt`、`db/scene3_restore_v5_db.txt`、`db/scene3_restore_v4_db.txt`、`screenshots/32_restore_confirm.png`、`33_restore_v5_done.png`、`35_picker_v4.png`、`36_restore_v4_done.png` |
| 4 | RSS 阅读记录全局开关 + 按源清空 | **PASS** | `screenshots/40_rss_record_dialog_default_on.png`、`43_rss_switch_off.png`、`47_rss_article2_open_switch_on.png`、`55_rss_clear_confirm_final.png`、`56_rss_after_clear.png`、`57_rss_b_records_kept.png`、`db/scene4_rss_clear_db.txt` |
| 5 | 登录头同站门控（mock 书源） | **PASS** | `mock/scene5_login_header_evidence.txt`、`mock/mock_requests.log`、`screenshots/08_reader_qa_book.png` |
| 6 | 规则字段往返（contentBatch/maxBatchSize、nextContentUrl） | **PASS** | `db/scene6_book_source_rule_fields.txt`、`db/scene6_rss_next_content_url.txt`、`screenshots/60_source_editor_view.png`、`63_rss_source_editor.png` |
| 7 | 回归（书架/阅读器/RSS/设置/关于、FATAL/ANR） | **PASS** | `screenshots/67_about_version.png`、`logcat/fatal_anr_counts.txt`、`logcat/logcat_full_session.txt` |
| 8 | 清理（恢复原 DB/prefs、移除测试数据与 mock） | **PASS** | `db/scene8_cleanup_verify.txt`、`screenshots/69_after_cleanup_restore.png` |

## 三、逐场景说明

### 场景 1：升级迁移 — PASS

覆盖安装后启动，书架正常显示旧书 3 本（`01_after_upgrade_shelf.png`）。DB 实测
（`db/scene1_migration_check.txt`）：

- `PRAGMA user_version = 114`；
- `readRecord` **13 列**，主键列 = `deviceId, bookName, author`（顺序一致）；
- `book_memos` 存在（列 `bookUrl/content/updatedAt`）；
- `highlightRules.group` 存在，存量行落 `''`；`rssSources.enableReadRecord` 存在，存量行落 `1`；
- 索引 `index_readRecord_snapshot`、`index_readRecord_bookName_author` 均存在；
- 旧数据行数不变：books=3、book_sources=1、readRecord=2、rssSources=1、highlightRules=1、book_memos=0；
- 迁移行原样保留：`('', '旧书一', '作者甲', 3600, …)` 与
  `('', '合并作者书', '\u001Eauthors:["作者B","作者C"]', 1800, …)`；
  两条 `displayBookName/displayAuthor` 已按上游口径回填。

### 场景 2：阅读记录 — PASS

**展示（升级后、阅读前）**：`screenshots/06_read_record_page.png`
- 同名书两行独立展示：`QA登录头书 / 作者Y 3 分 20 秒`、`QA登录头书 / 作者X 1 分 40 秒`
  （200000ms / 100000ms，未合并、未覆写）；
- 旧合并作者串显示为 **「作者B、作者C」**（`screenshots/06_read_record_page.png` 中「合并作者书」行），
  未显示控制符原文；汇总累计 5 分 5 秒 = 3:20 + 1:40 + 1.8s + 3.6s。

**写入与去重累加**：阅读 `QA登录头书` 第一章 21:51:37 → 21:52:22（约 45 秒）后
（`db/scene2_read_record_delta.txt`）：
- 作者Y：200000 → **244839**（+44839ms ≈ 44.8s），作者X：**100000 不变**；
- `readRecordDaily` 当日 +44 秒；
- 主记录选取与写回口径一致，未把同名其他作者时长叠加进本行。

**最终页复核**：`screenshots/68_read_record_final.png`（作者Y 4 分 45 秒 / 作者X 1 分 40 秒 /
合并作者书「作者B、作者C」）。

### 场景 3：备份 v5 与 v4 恢复 — PASS

1. **创建备份**（`screenshots/19_backup_section.png` → `20_backup_done.png`）：
   产物 `legado_backup_1793195735114.json`（`backup/legado_backup_v5_20261028.json`）。
   断言（`backup/backup_v5_assertions.txt`）：
   - `version = 5`；
   - 顶层含 `bookMemos`；
   - `readRecords` 5 条，13 字段并集完全一致（`deviceId/bookName/author/readTime/lastRead/
     lastChapterTitle/lastChapterIndex/lastChapterPos/coverUrl/resolvedAuthor/
     displayBookName/displayAuthor/metadataEditedAt`）。
2. **备忘往返**：DB 写入 `book_memos(bookUrl=…/book/1, content=QA备忘-批27-29)` 后再次备份
   （`backup/legado_backup_v5_with_memo.json`，`backup/backup_v5_with_memo_assertions.txt`
   显示 `bookMemos` 1 条）。随后删除备忘并把 `旧书一.readTime` 改为 1，经 UI
   长按「恢复」选择该备份并确认（`screenshots/26_restore_picker.png`、
   `32_restore_confirm.png`、`33_restore_v5_done.png`）。恢复后
   （`db/scene3_restore_v5_db.txt`）：备忘恢复为 1 条、`旧书一.readTime` 回到 3600、
   其余阅读记录保持。
3. **v4 旧备份不清空备忘**：以 v5 备份构造 v4 格式文件（`version=4`、删除 `bookMemos` 键、
   `旧书一.readTime=777000`）并放入设备 Download（`backup/qa_v4_legacy_backup.json`）。
   DB 额外写入 `V4-KEEP-备忘` 后经 UI 恢复该 v4 文件
   （`screenshots/35_picker_v4.png`、`36_restore_v4_done.png`）。
   恢复后（`db/scene3_restore_v4_db.txt`）：`旧书一.readTime=777000`（证明恢复确实执行），
   `book_memos` 两条（`QA备忘-批27-29` 与 `V4-KEEP-备忘`）**均保留**，未被清空。

### 场景 4：RSS 阅读记录开关与按源清空 — PASS

- **默认开**：首次打开 QA RSS A 的「阅读记录」对话框，开关为开（`screenshots/40_rss_record_dialog_default_on.png`），
  两条历史记录可见。
- **关闭后不新增**：关闭开关（prefs 实测 `flutter.enableRssReadRecord=false`，
  `screenshots/43_rss_switch_off.png`），打开文章 RSS文章一（`44_rss_article_open_switch_off.png`），
  DB 中 A 源记录数保持 **2**。
- **重开恢复写入**：重新开启（prefs 回 `true`），打开 RSS文章二（`47_rss_article2_open_switch_on.png`），
  A 源记录数变为 **3**。
- **按源清空**：确认框文案为「清空阅读记录 / **确定清空当前源的全部阅读记录？**」，
  不含条数（`screenshots/55_rss_clear_confirm_final.png`）。确认后
  （`db/scene4_rss_clear_db.txt`）：A 源记录 **0**、B 源记录 **1**；对话框列表刷新为
  「暂无阅读记录」（`56_rss_after_clear.png`）；切换到 QA RSS B，其记录仍在
  （`57_rss_b_records_kept.png`）。
- **空 origin 负例**：UI 无「空 origin」入口，无法在设备上触发；改由单元测试覆盖并通过：
  - `cargo test -p legado-ffi test_clear_by_origin_none_some_and_blank` → **1 passed**
    （`logcat/unit_empty_origin_ffi.log`：空串/纯空白删除 0 行，两个源均保留）；
  - `cargo test -p legado-db test_clear_by_origin_trims_and_blank_deletes_nothing` → **1 passed**
    （`logcat/unit_empty_origin_db.log`）。

### 场景 5：登录头同站门控 — PASS

Mock：`mock/mock_booksource.py`（宿主 `0.0.0.0:18080` 书源站点 + `0.0.0.0:18081` 另一端口；
跨站域名 `192-168-100-52.nip.io` 由 DNS 解析到同一宿主 IP，host 不同）。书源 URL
`http://192.168.100.52:18080`，登录头经 `caches.loginHeader_<url>` 注入
`{"X-Login-Token":"qa-token-27-29"}`（模拟登录成功后的缓存状态）。

实测请求头（`mock/scene5_login_header_evidence.txt`、`mock_requests.log`）：

| 请求 | 目标 | X-Login-Token |
|---|---|---|
| `/book/1` | 同站 `192.168.100.52:18080` | **qa-token-27-29** |
| `/chapter/1` | 同站 | **qa-token-27-29** |
| `/chapter/2`（首次） | 同站 | **qa-token-27-29** |
| `/chapter/2`（改为 `192-168-100-52.nip.io:18081`） | 跨站 | **absent** |
| `/img/cover.png` | 跨站 `192-168-100-52.nip.io:18081` | **absent** |

- 同站正文/详情请求均带登录头；跨站章节请求不带（eTLD+1 门控生效）。
- **实际行为记录**：文本阅读器把 `#content@html` 的 `<img>` 标签按纯文本渲染
  （`screenshots/08_reader_qa_book.png`），正文内图片 URL 未触发下载；封面图片链路的跨域请求
  实测不携带源登录头（图片下载不继承书源登录头）。二者均按任务要求记录实际行为。

### 场景 6：规则字段往返 — PASS

- **书源**：DB 造 `http://qa.local/rules`，`ruleContent =
  {"content":"#content@html","contentBatch":"java.getContentBatch()","maxBatchSize":3}`。
  经「我的 → 书源管理 → 编辑」打开并保存（`screenshots/60_source_editor_view.png` →
  `61_source_saved.png`），DB 保存后（`db/scene6_book_source_rule_fields.txt`）仍为
  `{"content":"#content@html","contentBatch":"java.getContentBatch()","maxBatchSize":3}`。
- **RSS 源**：DB 置 `QA RSS B.nextContentUrl='div.next@href'`，经 RSS 页「编辑源」打开并保存
  （`screenshots/63_rss_source_editor.png` → `65_rss_editor_after_save_tap.png`），
  DB 仍为 `div.next@href`（`db/scene6_rss_next_content_url.txt`）。

### 场景 7：回归与稳定性 — PASS

- 书架（含升级前后）、阅读器打开/翻章/退出、RSS 订阅列表/文章详情、设置主页/备份页、
  关于页均正常；关于页版本 **2.0.406**（`screenshots/67_about_version.png`）。
- 全量 logcat（21:48 安装启动 ~ 22:13，约 25 分钟，3.3GB）扫描
  （`logcat/fatal_anr_counts.txt`）：
  - `FATAL EXCEPTION` = **0**；
  - `ANR in` = **0**；
  - `E/flutter|W/flutter` = **0**；
  - `io.legado` 相关行 359 行已单独留档 `logcat/logcat_app_lines.txt`。
- 恢复原始 DB 后再次启动也无 FATAL/ANR（`logcat/logcat_cleanup_launch.txt`）。

### 场景 8：清理 — PASS

- 设备 DB 已恢复为升级前原始文件（274,432 字节，原 1 个书源/1 条高亮规则），
  WAL/SHM 已删除；启动一次后自动迁移到 v114 验证可用
  （`db/scene8_cleanup_verify.txt`：`user_version=114`，books=0、readRecord=0、
  book_sources=1、book_memos=0；`screenshots/69_after_cleanup_restore.png`）。
- 偏好恢复为原始 5 键集合（移除验收新增的 `app_backup_path`/`enableRssReadRecord`/
  `source_rule_help_shown`）。
- 已删除设备上的 `qa_v5_backup.json`、`qa_v4_backup.json`、应用备份目录内容、
  `/data/local/tmp` 下全部临时 DB/seed/prefs 文件；`adb reverse --list` 为空。
- Mock 服务已停止（任务 `exec_3a876679` 已 kill），本地无残留监听。

## 四、发现、限制与观察

| 类型 | 项 | 说明 | 影响 |
|---|---|---|---|
| 观察 | 图片链路不携带源登录头 | 跨域封面请求 `X-Login-Token=<absent>`；正文按文本渲染未触发正文图片下载 | 与批 29 登录头门控无冲突；记录实际行为，未判失败 |
| 观察 | RSS 列表/正文请求未附登录头 | 本批只为书源 URL 注入 `loginHeader_`；RSS 源登录头未在本批范围（按源 URL 独立缓存） | 范围外，未判失败 |
| 限制 | 空 origin 按源清空负例 | UI 无空 origin 入口，设备不可触发；已由 Rust 单元测试两条覆盖并通过 | 已证明，不阻塞 |
| 限制 | v4 备份样本来源 | 用 v5 备份删除 `bookMemos`、版本改 4 构造，非设备历史真实 v4 文件 | 语义与 v4 一致（缺键=不清空） |
| 环境 | armv7 `rar` 编译失败 | 既有环境项，构建脚本自动回退无 quickjs；x86_64 设备不受影响 | 不阻塞 |

未发现迁移、备份、登录头相关的功能缺陷。

## 五、结论

批 27~29 合并验收 **通过**：升级迁移（v112→v114）结构/数据完整，阅读记录按作者分行且时长不串行，
备份 v5 十三字段与 `bookMemos` 往返正确、v4 旧备份不清空备忘，RSS 记录开关与按源清空行为符合契约，
登录头同站门控实测生效，规则字段（`contentBatch`/`maxBatchSize`/`nextContentUrl`）保存不丢失，
全流程 FATAL/ANR 为 0。设备已恢复原始数据与偏好，测试数据/文件/mock 均已清理。

— QA（ZCode） 2026-10-28
