# 2026-11-13 全面审查 · 路 4：数据层报告

> 审查基线：HEAD `7c15e82252`（2.0.491+492）
> 对照基线：`app/`（原版 Kotlin）、`D:\OH-WorkSpace\LegadoTeam\legado-upstream`（上游）、`D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（参考版，HEAD `701943e`，2026-10-28）
> 性质：**只读审查**。未修改业务代码、未运行构建/测试；仅使用 git log/rg/Read/Select-String。
> 路径约定：下文「我方」路径均相对 `D:\OH-WorkSpace\LegadoTeam\legado\`；「参考版」= `legado-with-MD3`；「上游」= `legado-upstream`。
> 口径：P0=用户可达的静默数据丢失/崩溃/安全；P1=用户可见功能缺陷/契约违反；P2=技术债/边界缺陷/不一致；P3=文档卫生/小毛病。

---

## 一、结论摘要

| 级别 | 数量 | 条目 |
|---|---|---|
| P0 | 0 | — |
| P1 | 1 | P1-1 |
| P2 | 9 | P2-1 ~ P2-9 |
| P3 | 4 | P3-1 ~ P3-4 |
| 待核实 | 6 | 见 §五 |

**最严重 3 条**

1. **P1-1 `book_marks`（用户划线/笔记）不在任何备份/恢复链**：自有 JSON 备份不收集；原版 zip 恢复既不映射也不告警（静默丢弃）。参考版自 2026-09-28 起明确备份 `bookMarking.json`，文档「与参考版一致不纳入备份」的前提不成立。
2. **P2-1 封面规则（coverRules）未备份**：功能有表、有 FFI、有 UI，`backup_create` 不收集；zip 恢复把 `coverRule.json` 当「无对应配置面」跳过。上游与参考版都备份该文件。
3. **P2-3/P2-8 规则库实际存于 caches config（`txt_toc_rules` / `dict_rules`），备份只覆盖同名的（半）死表**：换机恢复后 TXT 目录规则库为空、词典 chips 列表为空或陈旧；zip 恢复写表但 UI 不读表。

---

## 二、P1

### P1-1 `book_marks`（划线/笔记）双链缺失：自有备份不收集、原版 zip 恢复静默丢弃

**我方证据**

- 表与功能实现完整：`rust/legado-db/src/schema.rs:81-88`（v118 迁移注释）、`:540-573`（`book_marks` DDL）；`rust/legado-db/src/repository/book_marking_repository.rs:1-147`；`rust/legado-ffi/src/api/book_marking_api.rs`（§2.52 五个方法）。
- `BackupData` 19 个字段中**没有** bookMarks：`rust/legado-ffi/src/api/backup_api.rs:240-347`；`backup_create` 的收集清单 `:528-734`、构造处 `:691-717` 无 book_marks。
- zip 恢复白名单 22 个文件**不含** `bookMarking.json`：`rust/legado-ffi/src/api/backup_api.rs:1007-1033`；「已知但未映射」清单 6 个文件也不含它：`:1041-1048`，因此连 `:2508-2511` 的 warn 都不会触发——**完全静默**。
- 落库恢复体无 book_marks 分支：`rust/legado-ffi/src/api/backup_api.rs:2939-3324`。
- 文档/注释把「不备份」写成「与参考版一致」：`rust/legado-db/src/schema.rs:556-557`、`docs/API_CONTRACT.md:1626`、`docs/REFACTORING_ACTIVE_PLAN.md:1135、1160`。

**参考版证据（前提被证伪）**

- 文件名清单：`legado-with-MD3/app/src/main/java/io/legado/app/help/storage/Backup.kt:70-71`（`"bookmark.json", "bookMarking.json"`）。
- 写出：`Backup.kt:155-158`（`writeListToJson(appDb.bookMarkingDao.all, "bookMarking.json", ...)`）。
- 恢复：`Restore.kt:155-166`（`fileToListT<BookMarking>(path, "bookMarking.json")` → `bookMarkingDao.insert`）。
- 该能力在参考版 `488a375`（2026-09-28）已存在，早于我方 7b 立项（2026-11-09）。

**改名/移位排除**（`git log -S`）

- `git log -S "book_marks" -- rust/legado-ffi/src/api/backup_api.rs` → 空
- `git log -S "bookMarks" -- rust/legado-ffi/src/api/backup_api.rs` → 空
- 结论：该字段从未在备份 API 中出现过，不是改名或移位。

**影响**

- 用户划线/高亮笔记（7b 批交付的用户内容）在「自有 JSON 备份 → 换机恢复」丢失；
- 从参考版/新版原版导出的 zip 中 `bookMarking.json` 数据**在包里、恢复时被丢**，且无任何提示（与上次 P1-6「数据在文件里、恢复时被丢」同型，且更隐蔽）。

**修复方向**

1. `BackupData` 升 v6，新增 `bookMarks` 段（整行 12 列）；`backup_create` 走 `BookMarkingRepository`（需补 `list_all`），空表写空数组。
2. zip 分支：`ZIP_DATA_FILES` 增 `bookMarking.json`，字段名与本方模型一致（id/bookUrl/bookName/bookAuthor/chapterIndex/anchorJson/styleJson/note/chapterName/enabled/createdAt/updatedAt）；按主键 `id` REPLACE 恢复（参考版 `insert` 语义），或在恢复前按 `(bookUrl, chapterIndex)` 合并去重。
3. 同步修正 `API_CONTRACT.md:1626`、`ACTIVE_PLAN` 7b 行、`schema.rs:556-557` 的错误「参考版一致」表述，并补往返测试（备份→清库→恢复→逐字段断言）。
4. 若产品决定继续不备份，需用户裁决并在契约中删除「与参考版一致」的错误依据（不建议）。

---

## 三、P2

### P2-1 封面规则 `coverRules` 未进备份；zip 恢复把 `coverRule.json` 误判为「无对应配置面」

**我方证据**

- 表：`rust/legado-db/src/schema.rs:713-721`；活跃功能：`rust/legado-ffi/src/api/cover_api.rs:69-150`（`get_cover_rule`/`save_cover_rule`/`delete_cover_rule`，读写 `coverRules` 表）；UI：`flutter_legado/lib/src/widgets/cover_rule_config_dialog.dart:1-120`、`flutter_legado/lib/src/screens/cover_settings_screen.dart`（入口）。
- 备份不收集：`backup_api.rs:240-347`（无字段）、`:528-734`（无收集）、`:1041-1048`（`coverRule.json` 在 UNMAPPED 清单）、`:2508-2511` warn 文案「当前版本无对应配置面（已跳过）」。

**上游/参考版证据**

- 参考版 `app/src/main/java/io/legado/app/model/BookCover.kt:52`（`configFileName = "coverRule.json"`）；`Backup.kt:97、251-256`（写 `BookCover.configFileName`）；`Restore.kt:337-344`（读回 `BookCover.saveCoverRule`）。
- 上游 `app/src/main/java/io/legado/app/help/storage/Backup.kt:79、345-346`；`Restore.kt:435-439`。

**影响**：封面搜索 URL/正则/启用开关属用户配置；换机恢复丢失。zip 恢复日志文案与实际能力矛盾（我方已有等价配置面），会误导排障。

**修复方向**：v6 增 `coverRules`（与表同形）；zip 映射 `coverRule.json` → `coverRules`（单主配置行，`enable/searchUrl/coverRule/enabledCookieJar` 与我方 `CoverRuleConfig` 同形）；从 `ZIP_UNMAPPED_FILES` 移除该项。

### P2-2 `autoTasks`（定时任务）只支持 zip 恢复，自有 JSON 备份永不收集

**我方证据**

- 字段注释自述「我方 `backup_create` 尚未收集该表」：`rust/legado-ffi/src/api/backup_api.rs:310-317`；创建处硬编码空数组：`:712`；测试还断言自有备份形状不得出现 `autoTasks`：`:5016-5017`。
- 恢复侧已支持：`backup_api.rs:1026`（`ZIP_DATA_FILES` 含 `autoTask.json`）、`:3285-3303`（按 id REPLACE 落库）。
- 功能真实存在：`rust/legado-ffi/src/api/auto_task_api.rs:148-190`（DB CRUD）、`flutter_legado/lib/src/routes.dart:125,319`（定时任务页）、`flutter_legado/lib/src/providers/auto_task/auto_task_notifier.dart`。

**上游证据**：`legado-upstream/app/src/main/java/io/legado/app/help/storage/Backup.kt:76、306`（写 `autoTask.json`）；`Restore.kt:263、628-629`（恢复并刷新调度）。

**影响**：定时任务（书籍更新/清理等）换机自恢复后全部丢失，且无提示；同格式 zip 却能恢复，形成不一致。

**修复方向**：`backup_create` 增 `AutoTaskRepository::find_all()`；保留 `skip_serializing_if` 以免改变旧形状（或 v6 明确写空数组）。

### P2-3 TXT 目录规则库实际存 caches `config:txt_toc_rules`，备份只覆盖业务死表 `txtTocRules`

**我方证据**

- 真实存储：`flutter_legado/lib/src/providers/txt_toc_rules/txt_toc_rules_notifier.dart:43`（`api.getConfig('txt_toc_rules')`）、`:56、64、79-86`（`setConfig`）；页面注释自述「规则经 Notifier 持久化到 Rust 配置库」：`flutter_legado/lib/src/screens/txt_toc_rules_screen.dart:25`；关联导入同样写 config：`flutter_legado/lib/src/providers/association/association_notifier.dart:750-770`。
- `txtTocRules` 表零业务读：全仓 rg 仅见 schema/迁移/`txt_toc_rule_repository.rs`/`backup_api.rs`/`default_data.rs`/测试；无 FFI CRUD、无阅读链读取（`rust/legado-book/src/txt.rs` 只消费 `books.tocUrl` 里的规则串，见 `:38-53`）。
- 备份收集/恢复的是该表：`backup_api.rs:649-654`、`:3185-3194`；zip 也映射到该表：`:1021、:2569`。
- 版本标记 `txtTocRuleVersion` 未列入备份排除清单（`restore_ignore_prefs.dart:24-72`），会随 `appPrefs` 恢复；新机恢复后 `version>=1` → 不再播种（`txt_toc_rules_notifier.dart:79-86`），config 为空 → 规则库显示为空。

**上游证据**：`app/src/main/java/io/legado/app/help/storage/Backup.kt:76`（`txtTocRule.json`）；`Restore.kt:228-235`（写 `txtTocRuleDao`，UI 从 DB 读取）。

**影响**

- 自有 JSON 备份不含用户自定义 TXT 目录规则库 → 换机后丢失（书内已应用的规则因写在 `books.tocUrl` 而保留，属于部分幸存）；
- 原版 zip 恢复把 `txtTocRule.json` 写进表，但 UI 读 config → **恢复"成功"但用户看不到规则**；
- 同机恢复时 config 保留本机旧值，与备份内容不一致。

**修复方向**（需先定口径）：A) 把 TXT 目录规则库迁回 `txtTocRules` 表（补 §2.45 式 FFI CRUD，UI/导入改走表，备份即自然覆盖）；B) 维持 config 存储，则 `backup_create/restore` 增 `txt_toc_rules` 段并把 `txtTocRuleVersion` 加入 `alwaysIgnoreKeys`。两条都需同步处理 zip `txtTocRule.json` 的落点。

### P2-4 `readRecordDaily`（热力图/按天统计）不进备份，恢复后统计与累计时长自相矛盾

**我方证据**

- 懒建表：`rust/legado-db/src/repository/read_record_repository.rs:519-532`；写路径 `:534-560`；恢复明确不触碰：`:335-350`（注释「恢复不产生阅读时长」）。
- `BackupData` 无该字段：`backup_api.rs:240-347`；创建/恢复均无（`git log -S "readRecordDaily" -- rust/legado-ffi/src/api/backup_api.rs` → 空）。
- 消费面：`readRecordDailyList`（`rust/legado-ffi/src/api/read_record_api.rs` 导出、`flutter_legado/lib/src/widgets/md3_heatmap_calendar.dart:5`、`read_record_daily_view`）。

**参考版证据**：`Backup.kt:78-79`（`readRecordDetail.json` / `readRecordSession.json`）；`Restore.kt:283-303`（逐条恢复 + `reconcileRestoredReadRecordTotals()` 重算，防重复导入翻倍）。

**影响**：换机恢复后 `readRecord.readTime` 恢复而每日统计为空；热力图/按天视图与「累计时长/成就卡」不一致，属静默数据缺失。

**修复方向**：v6 增 `readRecordDaily: [{date, seconds}]`，恢复按 `max` 合并；或恢复后按会话表重算（我方无会话表，只能直接备份）。

### P2-5 替换规则恢复丢弃原 `id`：重复恢复翻倍、`manualReplaceRuleIds` 关联断裂

**我方证据**

- `ReplaceRuleRepository::insert` 的 SQL 不含 `id`：`rust/legado-db/src/repository/replace_rule_repository.rs:21-51`；恢复走该 `insert`：`backup_api.rs:3031-3041`。
- 模型有 id：`rust/legado-core/src/models/misc.rs:80-115`。

**上游证据**：`legado-upstream/app/src/main/java/io/legado/app/data/dao/ReplaceRuleDao.kt:154-155`（`@Insert(onConflict = REPLACE)`，实体自带 id → 保 id）；`Restore.kt:349-352`。

**影响**

- 同一备份恢复两次 → 规则数翻倍（首次恢复的 id 与备份 id 无关，第二次再插入新行）；
- 依赖规则 id 的 `readConfig.manualReplaceRuleIds`（原版导入/后续批次消费）在恢复后指向错行；
- 与 P2-3 相同，属「恢复非幂等」。

**修复方向**：仿 `ServerRepository::restore_upsert_preserving_id`（`backup_api.rs:3239-3253` 已用同一先例）增 `restore_upsert_preserving_id`，恢复时保留 id 并 REPLACE。

### P2-6 「清空阅读记录」不清理 `readRecordDaily`，按天/热力图数据残留

**我方证据**

- Rust：`clear_read_records` → `ReadRecordRepository::clear_all` 仅 `DELETE FROM readRecord`：`rust/legado-ffi/src/api/read_record_api.rs:137-144`、`rust/legado-db/src/repository/read_record_repository.rs:493-500`。
- UI：`flutter_legado/lib/src/providers/read_record/read_record_notifier.dart:145-153`（clearAll 后仅 reload 记录列表）；热力图/按天视图数据源 `readRecordDailyList` 不随之清空。

**上游对照**：上游无每日聚合表（其统计由 `ReadRecordDetail/Session` 派生，删除记录时按书/全量清理）。参考版 `Restore.kt` 也会重算汇总。

**影响**：用户点「清空」后，书单与累计时长清零，但热力图/按天视图仍显示历史时长，属用户可见的不一致（非崩溃/非数据丢失）。

**修复方向**：`clear_read_records` 同步 `DELETE FROM readRecordDaily`（全量清空语义）；单本删除无法反推每日贡献，维持不清并登记。

### P2-7 恢复旧备份/原版 zip 会静默清除 `isPrivate` / `disableReadRecord` / `originBookUrl`

**我方证据**

- 书籍恢复直接 `serde_json::from_value::<Book>` + `insert`：`backup_api.rs:2967-2999`；缺键时 serde 取默认：`rust/legado-core/src/models/book.rs:269-276`（isPrivate=false）、`:185-186`（originBookUrl=''）、`:263-270`（disableReadRecord=false）。
- 整行写入包含这些列：`rust/legado-db/src/repository/book_repository.rs:806-862`；分组同理（`core BookGroup` 的 `isPrivate` 缺键 false，`from_core_book_group` 原样写入）。
- 同仓已存在「缺键保留」先例：Web `/saveBook` 缺 `isPrivate` 时回读库内值保留（`rust/legado-server/src/legacy/book_api.rs:1435-1455`）；`update_book` 对缺 `disableReadRecord` 保留（`rust/legado-ffi/src/api/bookshelf.rs:94-118`）。

**基线事实**：上游 Room 113 的 `books` 无 `isPrivate`/`disableReadRecord`（`legado-upstream/app/schemas/io.legado.app.data.AppDatabase/113.json` entities 列集）；因此**任何上游/旧版 zip 都不含这两个键**。参考版自有 zip 含 `isPrivate`（其 `Book.kt` 有该列）。

**影响**

- 用户标记为私密的书/分组，在恢复上游 zip 或 pre-9a 自有备份后被静默解除私密（隐私面回归，且无提示）；
- 单本「关闭阅读记录」被重置为 false（重新开始计时）；
- 换源书的 `originBookUrl` 清空（详情页/目录抓取回退旧 `bookUrl`，可能抓不到）。

**修复方向**：恢复体在解析前检查原始 JSON 键是否存在（`value.get("isPrivate")` 等），缺键时读库内旧值合并（复用 `saveBook`/`merge_missing_user_switches` 手法）；为 zip/JSON 两入口补「缺键不清隐私标记」用例。

### P2-8 词典规则双存储漂移：`dictRules` 表（查询/管理页/备份）vs `config:dict_rules`（词典页弹窗/关联导入）

**我方证据**

- 查询引擎用表：`rust/legado-ffi/src/api/dict_api.rs:91-110`（`DictRuleRepository::find_enabled`）。
- 管理页用表：`flutter_legado/lib/src/screens/dict_rule_screen.dart:137-144`（`dictRuleList`）。
- 词典页「词典规则管理」弹窗用 config：`flutter_legado/lib/src/providers/dict/dict_notifier.dart:42、59、124-130`（`getConfig/setConfig('dict_rules')`）；弹窗入口 `flutter_legado/lib/src/screens/dict_screen.dart:82、299-374`。
- 关联导入写 config：`flutter_legado/lib/src/providers/association/association_notifier.dart:695-720`。
- 备份只收集表：`backup_api.rs:663-668`；config 不备份。
- 版本标记 `dictRuleVersion`（`dict_notifier.dart:17-18、68-74`）随 appPrefs 恢复；新机恢复后 `version>=1` → 不播种，config 为空 → chips 列表为空。

**上游/参考版**：单存储（`dictRule.json` ↔ `DictRuleDao`）。

**影响**：两套「词典规则管理」入口行为不同——弹窗/关联导入新增的规则**不参与词典查询**；chips 列表不随备份迁移；换机后 chips 可能为空。属用户可见功能缺陷，同时是数据面不一致（与 P2-3 同族）。

**修复方向**：把弹窗与关联导入统一改走 §2.45 FFI（`dictRuleAdd/Update/Delete/Import`），删除 `config:dict_rules` 旧存储；迁移期把 config 值一次性导入表并清键。

### P2-9 同名同作者换 URL 时 `book_memos` 未迁移（备忘孤儿化）

**我方证据**

- `BookRepository::insert` 的冲突重映射只搬 `chapters/highlights/cached_chapters/download_tasks`：`rust/legado-db/src/repository/book_repository.rs:662-701`；**不含 `book_memos`**。
- `add_book` 走 `update` →（0 行）`insert_replace`：`rust/legado-ffi/src/api/bookshelf.rs:141-153`、`rust/legado-db/src/repository/book_repository.rs:864-871`；REPLACE 触发 `(name,author)` 唯一索引替换旧行。
- 备忘按 `bookUrl` 单键、UI 按当前 `bookUrl` 查询（`book_memo_repository.rs:142-163` inner join）。

**上游证据**：`legado-upstream/app/src/main/java/io/legado/app/data/dao/BookDao.kt:228-239`——`insert` 包装在 REPLACE 前用 `getReplacedMemoBookUrl(name, author, newUrl)` 找到旧 URL，`copyNewerMemo` 迁移到新 URL 后再 `deleteMemo`。

**影响**：用户从另一书源加入同名同作者书（或导入/恢复触发同名替换）时，旧书备忘从 UI 消失（行仍在表中但 `inner join` 不可见），属用户内容丢失；存量面（非本增量引入），上次审查未报告。

**修复方向**：在 `remap_book_url_preserving_chapters` 与 `insert_replace` 前按上游语义迁移 `book_memos`（按 `updatedAt` 取新者、旧键删除）。

---

## 四、P3

### P3-1 恢复「忽略本地书」生成的临时明文 JSON 不在启动清扫范围

- 我方：`_writeJsonSkippingLocalBooks` 在系统临时目录**直接**创建文件 `legado_restore_no_local_<micros>.json`：`flutter_legado/lib/src/services/webdav_restore_service.dart:430-437`；正常路径由 `finally` 删除（`:394-404`），进程被杀则残留。
- 清扫器只遍历**目录**且只认两个前缀：`flutter_legado/lib/src/services/temp_dir_cleaner.dart:37-40、64-66、86-93`；`_deleteTempDir` 里的 `legado_restore_no_local_` 分支永远不会命中该文件（`:451-467`）。
- 影响：孤儿文件永久残留在 `code_cache`/系统 temp（Android 系统可回收，桌面多用户 temp 可被同机用户读取）；内容是一份剔除本地书后的完整备份（含私密书与阅读记录）。
- 修复：清扫器扩展为「文件 + 目录」并加入该前缀；或把过滤文件放进 `legado_webdav_restore_*` 目录内。
- **对任务书特别关注点的回答**：孤儿**目录**有启动清扫兜底（>1h，目录与最新直接子项 mtime 取大者，边界用例已测：`temp_dir_cleaner.dart:95-117`、`flutter_legado/test/unit/temp_dir_cleaner_test.dart:81-101`）；孤儿**文件**无兜底。

### P3-2 死表 / 死列

| 对象 | 证据 | 现状 |
|---|---|---|
| `download_tasks` 表 + `DownloadTaskRepository` | `rust/legado-db/src/schema.rs:748-765`；`rust/legado-db/src/repository/download_task_repository.rs`（仅自身测试调用）；`rust/legado-db/src/lib.rs:57` 导出；全仓生产代码零读写（`rust/legado-ffi/src/api/pre_update.rs:109` 仅注释提及；`book_repository.rs:687-690` 仅换 URL 时 UPDATE） | 表在、仓储死、FFI 零导出；下载功能实际走内存 `DownloadManager` |
| `books.infoHtml` / `books.tocHtml` | schema `rust/legado-db/src/schema.rs:210-211`；模型 `rust/legado-core/src/models/book.rs:292-298`；Rust/Dart 均零写入零读取（写入路径只有整行 `None` 透传） | 恒为 NULL 的死列（上游为 `@Ignore` 运行时字段，本不该落库） |
| `books.coverOrigin` | `schema.rs:213`；`book.rs:301-304`；零读写（`rg "\.cover_origin"` 仅仓储读写全行） | 恒 NULL 死列（上游为计算属性，非列） |
| `txtTocRules` 表 | 见 P2-3 | 业务死表（仅备份/旧数据导入写） |

> 注：`books.downloadUrls` **不是**死列——Dart `BookOpenUtils.mergeWebInfo` 写入（`flutter_legado/lib/src/utils/book_open_utils.dart:521-595`）、`loadWebFile` 消费（`:711-716`），Rust 仅透传。

### P3-3 v104 迁移临时表名无 `IF NOT EXISTS`，跨语句崩溃后不可重入

- `rust/legado-db/src/migration/schema_align_v104.rs:72-91`（`CREATE TABLE rssArticles_v104`，无 IF NOT EXISTS）；同类 `rssStars_v104`/`readRecord_v104`/`rssReadRecords_v104`/`rssSources_v104`/`search_keywords_v104` 均同。
- 迁移注册表逐条执行且**不包事务**：`rust/legado-db/src/migration.rs:128-144`（每条 `up` 后写 `user_version`）。
- 影响：迁移中断电/被杀（CREATE 后、DROP/RENAME 前）→ 残留 `*_v104` 表；下次开库重跑 v103→104 报 "table already exists"，开库失败直至人工清理。属低概率高影响。
- 修复：临时表统一 `DROP TABLE IF EXISTS` + `CREATE TABLE IF NOT EXISTS`；或把 `migrate_to` 的每条迁移包进 `in_transaction`（`connection.rs:235-265`）。

### P3-4 重复恢复同一备份时书签翻倍（存量 P3，本次复核仍在）

- `BookmarkRepository::insert` 不含 `id`：`rust/legado-db/src/repository/bookmark_repository.rs:20-35`；恢复逐条 insert：`backup_api.rs:3020-3029`。
- 上游/参考版按实体 id 插入并捕获约束（`Restore.kt:155-162`），重复恢复不翻倍。
- 影响：同一备份恢复两次 → 书签翻倍；与 P2-5 同族。
- 修复：保留 id + REPLACE，或按 `(bookName, bookAuthor, chapterIndex, chapterPos, time)` 去重。

---

## 五、待核实（附核实方法）

1. **`keyboardAssists` 恢复策略口径漂移**：我方「文件存在即清空再写」`backup_api.rs:3220-3237`，与上游一致（`legado-upstream/.../Restore.kt:368-371` deleteAll）；但当前参考版改为 insert-only（`legado-with-MD3/.../Restore.kt:250-256`）。核实方法：向用户确认基准侧；若以参考版为准，去掉 deleteAll（否则恢复会删除本机额外键盘辅助规则）。
2. **`book_groups` 恢复是否应全量替换**：我方 upsert-only `backup_api.rs:3096-3106`；上游 insert-only（`Restore.kt:326-333`）；参考版 `replaceAll`（`BookGroupDao.kt:48-56`、`Restore.kt:160-162`）。核实方法：确认「恢复后是否应删除备份外新建分组」；当前行为不删。
3. **逐表备份/恢复忽略（dbIgnore）未实现**：我方只有 8 个偏好类忽略键（`flutter_legado/lib/src/services/settings_service.dart:1180-1189`）；参考版有 `BackupConfig.dbIsNotIgnored` 逐表门控。核实方法：在参考版备份设置页确认「数据库内容」分组项是否为产品范围（`docs/SETTINGS_GAP_SCOPE_20261030.md:64` 记为 P1 需 Rust 过滤）。
4. **`readRecord` 查询无 `deviceId` 过滤（存量 P3）**：`read_record_repository.rs:415-420`（primary_record 仅按 bookName）、`:444-449`、`:469-483`（find_all 全量）。实际写入恒 `device_id=""`（`:321-333`）且 zip 恢复归一空串（`backup_api.rs:2667-2701`），风险低。核实方法：构造两条不同 deviceId 行后走记录页，观察是否混读。
5. **自研 `chapter_reviews` 本地表不进备份**：`schema.rs:644-656`；服务端写入口 `rust/legado-server/src/routes.rs:127-130` + `handlers/review.rs:44-67`。核实方法：检索 Vue 前端是否有 `POST /api/reviews` 调用（当前 rg 零命中）；若无真实用户写入面则不构成数据丢失。
6. **caches 中其他 `config:` 键的备份面**：`userAgent`/`threadCount` 有 prefs 双源且恢复后显式回写（`flutter_legado/lib/src/providers/backup_restore_refresh.dart:55-76`）；`config:theme` 等键是否有独立消费方待核（`rust/legado-ffi/src/api/config_api.rs:174-188`）。核实方法：逐键 rg `config:<key>` 的读写方。

---

## 六、上次审查项回销核查（不重复报告，仅确认无回潮）

| 上次项 | 现状 | 证据 |
|---|---|---|
| P1-6 RSS 恢复丢列 | 未回潮：全 46 列模型化写入 | `rust/legado-db/src/repository/rss_source_repository.rs:116-183`；`backup_api.rs:3056-3077` |
| P1-7 ReadRecord 恢复丢 deviceId/合并 | 未回潮：13 列 + `merge_restored_read_record` 与上游 `ReadRecordMerge.kt` 逐分支一致 | `read_record_repository.rs:161-222`、`:335-350`；上游 `app/.../entities/ReadRecordMerge.kt` 全文 |
| P1-8 `readConfig` 双形态 | 未回潮：`normalize_dual_form` 仍在 import 主链并有红→绿用例 | `rust/legado-db/src/import.rs:28、335-348`、测试 `:881-1027` |
| P1-9 备份覆盖面 6→19 类 | 已扩展；但 `autoTasks` 仍空、`book_marks/coverRules/readRecordDaily` 不在（见 P1-1/P2-1/P2-2/P2-4） | `backup_api.rs:240-347、691-717` |
| P2-13 恢复进度被防回滚闸挡 | 已修复：恢复显式 `overwrite_progress_for_restore` | `book_repository.rs:517-546`；`backup_api.rs:2982-2994` |
| P2-11 uuid/applyToBody | 已落地且往返测试在库 | `backup_api.rs:4561-4716`；`highlight_rule_repository.rs:18-107` |
| 恢复体事务（P1-A） | 已包裹单事务，嵌套事务安全 | `backup_api.rs:945-963`；`connection.rs:235-265` |

---

## 七、必查点逐条结论

### 7.1 schema 迁移链（90→119）

- **无跳号**：注册表连续 29 条（90→91 … 118→119），`migration.rs:62-92`；测试断言 29 条且首条为 90→91：`migration.rs:322-330`。
- **幂等性**：新增列走 `add_column_if_not_exists`；建表走 `CREATE TABLE IF NOT EXISTS`；`readRecord` 重建用 `DROP TABLE IF EXISTS readRecord_v113` + 事务（`read_record_v113.rs:137-176`）；`privacy_flags_v119`/`book_marks_v118`/`source_check_state_v115` 均幂等（各自测试覆盖）。
- **唯一例外**：v103→104 临时表名（P3-3）。
- **测试覆盖**：每个迁移节点均有「补列/建表 + 重复执行 + 注册表推进 + 缺表跳过」用例；`integration_test.rs:297-360` 从 v90 迁到最新并断言数据保留。
- **开库自愈**：`repair_legacy_columns` 覆盖 books/chapter_groups/rssSources/highlightRules/replace_rules/readRecord/book_memos/book_source_check_states/book_marks（`migrations.rs:60-158`）；`ensure_schema_integrity` 每次开库执行（`connection.rs:178-192`）。

### 7.2 备份覆盖面（BackupData vs 原版 19 类）

| 上游 19 类 | 我方状态 |
|---|---|
| bookshelf / bookmark / bookGroup / bookSource / rssSources / rssStar / replaceRule / readRecord / searchHistory / sourceSub / txtTocRule / httpTTS / keyboardAssists / dictRule / highlight / highlightRule / server / directLinkUploadRule | ✅ 均在（`backup_api.rs:240-347`） |
| autoTask | ⚠️ 字段在、创建不收集（P2-2） |
| cookies / runtimeSourceCache | 自有 JSON 不含（代码注释登记；仅 zip 恢复） |
| 参考版额外项 | `bookMarking` ❌（P1-1，且我方有该功能）；`coverRule.json` ❌（P2-1）；`readRecordDetail/Session` 我方无该功能，对应数据为 `readRecordDaily` ❌（P2-4）；`homepageModules/homepageCustomSets/highlightTagRule/tagGroupRule/httpTtsVoices` 我方无对应功能，不构成缺口 |

- `BackupData.version` 已引入（`BACKUP_VERSION=5`，`backup_api.rs:236`），满足上次 §八-9 建议。
- 恢复即丢数据新成员核查：`highlightRules.uuid/applyToBody` ✅、`books.isPrivate` ✅（正常备份）、`book_groups.isPrivate` ✅、`replace_rules.sortOrder` ✅（仅 id 问题 P2-5）；`book_marks` ❌（P1-1）、`coverRules` ❌（P2-1）、`readRecordDaily` ❌（P2-4）；`theme 12 槽` ✅（`restore_ignore_prefs.dart:267-334` 的 themePrefKeys 全在 appPrefs）；`appFontPath` **有意排除**（`restore_ignore_prefs.dart:61-65`、`app_font_store.dart:15-17`，用户 2026-11-11 裁决一致；参考版只备份会悬空的绝对路径，我方选择更稳）。

### 7.3 隐私数据外流面（与 2026-11-11 裁决一致性）

- `books.isPrivate` / `book_groups.isPrivate` 随备份与 Web 输出：`book.rs:269-276`、`misc.rs:448-452`、`legacy/book_json.rs:103-104,160`；用户裁决为「维持参考口径」，并在隐私页明示：`flutter_legado/lib/src/screens/privacy_settings_screen.dart:430-441`。
- 进度同步（`webdavFullSync`）上传全部书架书（含私密）：`flutter_legado/lib/src/providers/sync/sync_notifier.dart:325-334`，与参考口径一致。
- 隐私密码凭据（caches `config:private_password_*`）不进备份：`restore_ignore_prefs.dart:42-71`；`private_enabled` 设备级排除。
- 结论：**与裁决一致，无需改动**；P2-7 是「旧备份缺键清标记」的恢复缺陷，不改变「是否排除」口径。

### 7.4 恢复语义

- 事务：恢复体单事务（`backup_api.rs:945-963`），条目级失败 warn 跳过、未捕获错误整体回滚；cookie 在主事务提交后落库（`:3255-3260`）。
- 进度：恢复路径显式覆盖 4 列（`book_repository.rs:517-546`），普通 `update` 仍结构性排除（`:790-819`），防回滚闸未被绕过。
- `readRecord` 合并：与上游 `mergeRestoredReadRecord` 一致（含 `localDevice` 分支、`metadataEditedAt` 选择、`coverUrl` 回退）。
- `readConfig` 双形态：import 链仍工作（P1-8 无回潮）。
- 缺口：见 P2-5/P2-6/P2-7。

### 7.5 双 DB / S28

- App 内 Web 服务与 MCP 均从 `db_state` 全局池取连接：`rust/legado-ffi/src/api/server_api.rs:234、410`；`legado-server/src/server.rs:44` 的 `init_database` 仅用于独立二进制/测试入口（注释 `:53-56`）。
- 未发现双写/漂移回潮。

### 7.6 多设备 / 并发 / 防回滚

- 详情见 §五-4（查询无 deviceId 过滤，存量 P3、实际风险低）。
- `update_progress` 防回滚闸仅在恢复路径被显式绕过（合法），其余整书回写均不写进度列。

### 7.7 批 18 线 1 临时目录清扫

- 目录兜底：`TempDirCleaner` 启动首帧后异步清扫，>1h（严格大于）删除；时间口径为「目录 mtime 与最新直接子项 mtime 取大者」；测试覆盖边界/文件不碰/失败继续（`temp_dir_cleaner.dart:57-117`；`test/unit/temp_dir_cleaner_test.dart:55-142`）。
- 边缘 case：孤儿**文件**（P3-1）无兜底；`systemTemp` 在 Android 映射 `code_cache` 而非 `cache`（已登记于批 18 设备报告）；多实例/桌面共享 temp 的极小误删风险已在代码注释登记（`temp_dir_cleaner.dart:16-18`）。

### 7.8 死字段 / 死表

- 见 P3-2；`rg` 裸名核查已覆盖 `download_tasks`、`infoHtml`、`tocHtml`、`coverOrigin`、`txtTocRules`；`downloadUrls` 经 Dart 消费链确认非死列。

---

## 八、修复批次建议（供 §七 排批）

1. **批 A（备份链 P1/P2，建议最高优先级）**：`BackupData` v6 + 4 个新段（`bookMarks`/`coverRules`/`autoTasks`/`readRecordDaily`）+ `replace_rules` 保 id + 旧备份缺键保留隐私开关 + zip 映射 `bookMarking.json`/`coverRule.json`。每项一个往返测试（备份→清库→恢复→逐字段断言）。
2. **批 B（规则库存储统一，需先裁决）**：TXT 目录规则库与词典规则库二选一存储（表或 config）并打通备份；决定后同步 UI/关联导入/zip 恢复三入口。
3. **批 C（数据卫生 P3）**：清空阅读记录清每日表、临时文件清扫扩展、v104 迁移幂等加固、死表/死列清理（删列需授权）。
4. **批 D（口径裁决项）**：keyboardAssists/book_groups 恢复策略、逐表忽略开关、`chapter_reviews` 是否纳入备份。

---

> 审查方法备注：所有「缺失」结论均以 `git log -S`（book_marks/bookMarks/coverRules/readRecordDaily/auto_tasks）排除改名/移位；所有「死字段/死表」均以裸名 rg 覆盖 rust/ + flutter_legado/lib（.g.dart/.freezed.dart 视为生成物）确认零生产读写。

— 数据层审查子代理 ｜ 2026-11-13
