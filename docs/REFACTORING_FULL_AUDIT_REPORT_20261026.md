# Legado 重构全面审查报告（五路交叉对照）

> 日期：2026-10-26 ｜ 审查基线：HEAD `a3302a0cc8`
> 性质：**只读审查**——审查期间未修改任何业务代码、未运行任何构建；本文为唯一交付物。
> 对照基线（重构前源码）：本仓 `app/`（双轨保留原版）+ `D:\OH-WorkSpace\LegadoTeam\legado-upstream`（上游原版 Kotlin）+ `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（参考版/视觉与形态基准）。
> 方法：5 个只读子代理分路审查（① 引擎链路 ② FFI 契约+Web 服务 ③ Flutter UI 完整性 ④ 数据层 ⑤ 文档可靠性），主代理对**全部 P0/P1 关键证据逐条亲核**（标注「✓亲核」者为已复核原文）。每条发现均有双侧 file:line 证据；「缺失」类结论均经 git log -S 排除改名/移位。

---

## 〇、总结论

**重构主体质量扎实、完成度高：FFI 三方（契约/Rust/Dart）284↔284 严格闭合无功能缺口；原版 46 个 Activity/Fragment 屏幕除 1 条断链外全部对齐且无未授权新增；规则引擎语法面、JS 桥（约 140 函数）、迁移链 90→109、进度/readRecord 读写语义均与原版逐条对齐。**

薄弱面按严重度排序：**① 备份/恢复子系统（4 条 P1，均为「恢复即丢数据」）；② 引擎转换层字段丢失与规则未接线（3 条 P1）；③ Web 服务写端点/管理端点整批未实现（已登记 B3/B4/B5，非失控）；④ 1 条 P0：Server 书源更新链路丢全部规则与登录态。** 文档「不可靠」的形态是**正文滞后/旧结论未回销**，不是虚报：抽验 50 个登记提交 100% 真实、12 项代码落地抽验 100% 成立。

缺陷计数：**P0×1、P1×9、P2×16、P3/文档卫生×10 组、待核实×6**。

---

## 一、P0（1 条，静默数据丢失，用户可达）✓亲核

### P0-1 Web 端书源仓库更新丢掉书源全部规则与登录态

- **我方证据**：`rust/legado-db/src/import.rs:102-107` —— `RoomImporter` 对 `ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleReview/ruleExplore` 一律 `as_str()`，而标准书源 JSON 的规则是**嵌套对象**，必得 `None` → 落库 NULL；`import.rs:119-133` INSERT 列集（33 列）**不含 `variable`**，且用 `INSERT OR REPLACE`（会清空已登录书源登录态）。
- **调用链（用户可达）**：`rust/legado-server/src/handlers/source_update.rs:276-279` 把远端仓库原始 JSON 直接交给 `RoomImporter::import_book_sources`；路由 `/sources/repos/checkUpdates`、`/sources/repos/update` 已注册（`routes.rs:72-79`）。
- **旁证**：FFI 主路径 `rust/legado-ffi/src/api/source.rs:93-95` 注释明言**明知此缺陷而绕开**（"以免 FFI 线格式（规则为 JSON 对象）的规则与 variable 被静默丢弃"）——但 Server 侧没绕。
- **测试盲区**：`source_update.rs:563、700` 测试种子均不含规则键，单测假绿。
- **影响**：Web 端书源订阅/更新后书源即失效（无搜索/正文规则）；已存在书源被 REPLACE 后 `variable`（登录态）清空。

**【修复方向】**
1. 首选：`source_update.rs` 弃用 `RoomImporter::import_book_sources`，改走 `BookSourceRepository::insert_batch`（与 FFI `import_sources` 同一 serde 链路：lenient 反序列化、规则对象/variable 全量、整批事务）；写库成功后刷新 server registry 的既有逻辑保留。
2. 若保留 `RoomImporter` 作 Room 导出格式兼容入口：对 `Value::Object` 形态规则键先 `serde_json::to_string` 归一再入库，并在 INSERT 列集中补 `variable`。
3. 回归测试：①种子改用真实书源 JSON（规则为对象、variable 非空），断言落库后 `rule_search/rule_toc/variable` 非空且再导出等价；②对已存在书源（已带 variable）重跑更新，断言登录态不被清空；③给 `RoomImporter` 加「输入含对象形态规则键必须归一，否则显式报错」的防回归断言。
4. 验证：按 CI 口径 `cargo test -p legado-server -p legado-db`；再用真实仓库 URL 对 `/sources/repos/update` 做一次手工回归（见 §六-2）。

---

## 二、P1（9 条）

### 引擎（3 条，均✓亲核）

**P1-1 `refresh_toc` 落库硬编码 `is_volume:false`/`tag:None`，卷章标记与章节附加信息全链丢失**
- 我方：解析侧**正确**执行 `ruleToc.isVolume` 并写入 `WebChapter`（`rust/legado-fetcher/src/web_book.rs:2657-2660`；结构体 `rust/legado-core/src/web_book.rs:49-62` 有 `is_volume` 无 `tag`）；但转换点 `rust/legado-ffi/src/api/reader.rs:582,587,589` 硬编码 `is_volume:false/is_pay:false/tag:None`，丢弃 `wc.is_volume`。同族缺陷点：`reader.rs:810`（正文链构造 `WebChapter` 同样 `is_volume:false` → 卷章正文抓取无法豁免空内容检查 `web_book.rs:2047`）；`reader.rs:1582` 为测试夹具（无害）。对照组：换源链 `source_switch.rs:853-856` 正确透传，证明非架构约束。
- 原版：`app/src/main/java/io/legado/app/model/webBook/BookChapterList.kt:245-259`（`isVolume` → `bookChapter.isVolume=true` 且 `tag=info`）。
- 影响：卷章被当普通章抓正文报「章节正文为空」；音频源播到卷章直接报错不跳章（`audio_api.rs:164-176` 依赖该字段）；章节更新时间/字数余量信息不落库。

**【修复方向】**
1. `reader.rs:577-599` 转换改 `is_volume: wc.is_volume`；`reader.rs:810` 从 DB chapter 透传 `is_volume`（并顺带 `is_vip`）。
2. `WebChapter`（`legado-core/src/web_book.rs`）增加 `tag: Option<String>`；fetcher 目录解析侧把 wordCount 剥离后的 info 余量写入 tag（对照原版 `info.replaceFirst(match.value,"")` 语义）。
3. 与 P2-1（isPay）、P2-3（并发拉页双实现）**同批修**：目录解析统一补 `is_vip/is_volume/is_pay` 三规则 → `WebChapter` 增 `is_pay/tag` → 串行/并发两条路径**合并为单一转换函数**，消灭双实现漂移。
4. 回归：①卷章书源 fixture → 断言落库 `isVolume=true` 且正文链豁免空内容检查；②音频链卷章 → 断言跳下一章；③`tag` 落库断言。转换函数建议加「全字段透传断言」测试（源结构全字段非默认 → 目标逐字段相等），防同类回归（对应 §八-3 规定）。

**P1-2 `ruleContent.title`（正文标题覆盖）与标题内 `imgUrl` 提取未实现**
- 我方：`rust/legado-core/src/models/rule/content_rule.rs:13` 定义了 `title` 字段，但正文链（`web_book.rs` get_content）对 `content_rule` 的消费仅 `is_empty` 一处（✓亲核 rg）；`BookChapter.img_url` 无赋值来源。
- 原版：`BookContent.kt:171-196` —— `contentRule.title` 非空时抓标题，`AppPattern.imgRegex` 从标题解构 `imgUrl` 并以余量覆盖标题。
- 影响：依赖「标题段评图」「正文规则返回 `<img>标题` 形态自覆盖标题」的书源静默缺失。

**【修复方向】** 正文抓取成功后接 title 规则链：`analyze_rule.get_string(title)` → 移植 `AppPattern.imgRegex`（Java 正则语义等价，注意惰性匹配与属性顺序）→ 提取 `imgUrl` 写 `BookChapter.img_url`、余量覆盖章节标题。回归：含 title 规则 + 标题内 img 的 fixture 源，断言标题与 img_url 均正确。

**P1-3 `ruleBookInfo.downloadUrls` 未接线，type=3 文件类书源下载链断裂**
- 我方：`book_info_rule.rs:29` 定义 `download_urls`，fetcher 详情链零消费（✓亲核 rg）；配套 `rust/legado-net/src/direct_link_upload.rs` 全仓无调用者（死代码）。
- 原版：`BookInfo.kt:165-172`（`getStringList(infoRule.downloadUrls, isUrl=true)`）。
- 影响：知轩藏书类「文件」书源详情可出但无下载地址，后续下载/打开全断。

**【修复方向】** ①详情链补 `download_urls` 解析（isUrl=true 语义：相对转绝对 + 去重）→ `Book.download_urls` 落库；②接通 `direct_link_upload.rs::extract_download_url`；③UI 侧 type=3 书籍的下载/打开入口对齐原版语义（若本批不做 UI，至少引擎字段先落库并在 ACTIVE_PLAN 登记 UI 余项）。

### UI（2 条，P1-4 的断链证据✓亲核）

**P1-4 外部书籍文件打开断链（manifest 声明了但没实现）**
- 我方：`flutter_legado/android/app/src/main/AndroidManifest.xml:63-70` 注册 epub/txt/pdf 的 `VIEW` intent-filter（注释自称「处理外部书籍文件打开请求」）；`MainActivity.kt:185,198-201` 仅把 `intent.dataString` 当深链转发；Dart 侧 `deep_link_service.dart:75` `if (!LegadoDeepLink.isImportScheme(url)) return` → `content://` URI 被静默丢弃（全库无其他消费方）。
- 原版：`ui/association/FileAssociationActivity.kt` + `ui/file/HandleFileActivity.kt`。
- 影响：文件管理器「用阅读打开」→ 应用拉起后无任何反应。

**【修复方向】** 推荐 A：`MainActivity` 识别 VIEW intent（按 mimeType）→ 复用现有 platform channel 把 `content://` 拷至缓存路径 → Dart 走现有 ImportBook 导入链（弹确认）。备选 B（若近期不做）：删除 manifest 的 VIEW intent-filter，停止虚假声明。验证：MuMu「Test测试」实例用文件管理器对 txt/epub/pdf 各实测一次（按平台裁决口径，iOS 侧对应 document types 仅记编译验证）。

**P1-5 关于页「创建堆转储」常驻死菜单（原版有真实现）**
- 我方：`about_screen.dart:187-193`（固定弹「暂不可用」）、`:246-249`（用户可达）。
- 原版：`AboutFragment.kt:158-178`（`CrashHandler.doHeapDump` 真实现）。

**【修复方向】** 二选一需用户裁决：A) 实现真功能——Android 侧经 MethodChannel 调 `android.os.Debug.dumpHprofData` 落 app 目录并弹分享（对齐原版；iOS 无对应物，按平台裁决口径处理）；B) 低成本收敛——移除该菜单项或改为「复制诊断信息」（版本/设备/内存），待需要时再立项。不建议保留永远「暂不可用」的入口。

### 数据层备份/恢复（4 条，同族「恢复即丢数据」）

**P1-6 备份恢复 RSS 源只写 7 列，恢复即抹掉既有源全部规则数据**
- 我方：`rust/legado-ffi/src/api/backup_api.rs:456-473` 仅写 `sourceUrl/sourceName/sourceIcon/sourceGroup/enabled/customOrder/type` 且 `INSERT OR REPLACE`；备份文件本身是全列（`:419-453` `SELECT *`）——**数据在文件里、恢复时被丢**。
- 影响：恢复后所有 RSS 源 `ruleArticles/searchUrl/loginUrl/header/...` 回默认/NULL。

**【修复方向】** `insert_rss_source` 改走 `RssSourceRepository` 全列 upsert（serde 模型字段齐全）。回归：备份→清库→恢复→断言规则/登录字段与备份逐列一致（往返测试，对应 §八-5 规定）。

**P1-7 ReadRecord 恢复丢 deviceId/author/lastRead，且无原版「同设备取较新」合并**
- 我方：`backup_api.rs:234-246` 只调 `upsert(book_name, read_time)`；`read_record_repository.rs:105-116` 固定 `deviceId=''`、不写 author/lastRead；全字段版 `upsert_full`（`:121-138`）存在但未用。
- 原版：`Restore.kt:366-376` —— 非本机记录直接插入；本机记录仅当 `current.readTime < incoming.readTime` 才覆盖。

**【修复方向】** 恢复改 `upsert_full`；按 `(deviceId, bookName)` 实现较新者胜的合并；author 聚合复用 `insert_with_author`。回归：双设备 fixture（同书不同 readTime/deviceId）恢复断言保留较新且 deviceId 归属正确。

**P1-8 `RoomImporter::import_books` 对 `readConfig` 仅认字符串形态，原版书架导入静默丢阅读配置**
- 我方：`import.rs:268` `as_str()`；而原版 `bookshelf.json` 与我方 legacy web 导出（`legacy/book_json.rs:107-108`）的 `readConfig` 均为**嵌套对象**。
- 影响：从原版备份/legacy 导出再导入书架，`reverseToc/pageAnim/ttsEngine/delTag/音频片头片尾/manualReplaceRuleIds` 全部回默认，无报错。

**【修复方向】** 双形态归一：`Value::Object` → `serde_json::to_string` 再走既有解析（`backup_api` 路径已示范）。回归：对象形态 readConfig 的 bookshelf.json 导入断言上述字段落库。

**P1-9 备份/恢复覆盖面仅 6 类 vs 原版 19 类+配置；原版备份 zip 无恢复入口**
- 我方：`backup_api.rs:22-48` 仅 books/bookmarks/replaceRules/bookSources/rssSources/readRecords；原版 `Backup.kt:279-330` 另有 bookGroup/highlight/highlightRule/rssStar/searchHistory/ruleSub/txtTocRule/httpTTS/keyboardAssists/dictRule/autoTask/server(WebDAV)/cookies(AES)/runtimeCaches 及阅读配置快照；原版 zip（多文件）解析即失败。
- 缺口分级：`book_groups/rssStars/highlights/highlightRules/searchHistory/ruleSubs/txtTocRules/httpTTS/dictRules/keyboardAssists` **表已在库却全不备份**（扩 BackupData 成本低）；`servers/cookies` 无表无替代持久化。

**【修复方向】** 分两步：①低成本扩表批——上述在库表逐批加入 BackupData 与恢复器（每表一个往返测试）；②`servers/cookies` 持久化与「原版 zip 恢复器」**单独立项、范围需用户裁决**（是否承诺兼容原版备份）。同时给 `BackupData` 加 `version` 字段，旧备份恢复不崩（向前兼容），此后扩表不再破坏旧备份。

---

## 三、P2（16 条，修复方向附后）

| # | 域 | 缺失/缺陷 | 关键证据 | 修复方向 |
|---|---|---|---|---|
| P2-1 | 引擎 | `ruleToc.isPay` 未解析，`is_pay` 恒 false | `web_book.rs:2657-2658`；原版 `BookChapterList.kt:233,272-276` | 与 P1-1 同批：解析 + `WebChapter.is_pay` + 转换透传 |
| P2-2 | 引擎 | `@webjs` 无 WebView 订阅者时静默回退空串，无告警 | `analyze_rule.rs:1870-1938`（L1925-1927 返回空串） | 空回退改登记 capability_ledger 告警；批量场景错误可见（对齐 error_class 语义） |
| P2-3 | 引擎 | 目录并发拉页与串行是两份实现，字段一致性靠人肉 | `web_book.rs:2873-2930` vs `:2696-2753` | 与 P1-1 同批合并为单一转换函数 |
| P2-4 | 引擎 | zip/7z ByteArray 版 JS API 返回形态待核实（bytes 语义 or 字符串） | `quickjs_impl.rs:4552-4602` vs `JsExtensions.kt:876-899` | 先核实（§六-1）；不等价则改 `{base64,len}` 形态或专用 api，加密漫画源回归 |
| P2-5 | FFI | 死接线 3 个：`sourceLoginV1`/`verificationPending`/`webviewPending`（Rust 实现完好，Dart 零调用） | `ffi.dart:358,274,317`；`ffi.rs:572,464,521` | 裁决：契约 §1.6.1 登记「仅测试消费」转正，或随版本移除；V1 登录若 UI 有规划则接上 |
| P2-6 | FFI | `api::rss::import/export_rss_sources` Rust 已备未挂 FFI，Dart 逐条循环 | `api/rss.rs:79,95`；`rust_api_search_rss.part.dart:283,298-302` | 挂 frb 生成 + Dart 换批量调用 + 契约 §2.x 登记 + `api_contract_test` 计数同步 |
| P2-7 | FFI 文档 | 契约 §1.7 等价名只登记 15 对，约 109 对未登记（功能无缺口） | `API_CONTRACT.md` §1.7 | 一次性脚本生成补登记（机械工作，可派子代理） |
| P2-8 | FFI | Book 结构 Rust 有 Dart 无 4 字段（coverOrigin/downloadUrls/infoHtml/tocHtml，原版 @Ignore 运行时字段） | `book.rs:235-244` | 登记为「有意单向精简」；未来 Dart 侧做解析/导出增强前先补 |
| P2-9 | Web | 写端点 14、书源管理读+令牌 7、段评 legacy 6 未实现（B3/B4/B5 已登记开放项，与本次核实一致） | `legacy/mod.rs:21-23`；原版 `HttpServer.kt:128-180` | 按 ACTIVE_PLAN L804 口径派 B3→B4→B5 批次（**勿按 mod.rs 注释的 B3/B4 口径，编号已漂移**）；B3 首批做 saveBook/deleteBook/addLocalBook（解锁 vue 传书页）+ 图片缓存根注入白名单 |
| P2-10 | Web | WS 调试「有等价能力但路径/端口未对齐」：我方 `/ws/debug/*` 同端口 vs 原版 port+1 `/bookSourceDebug`——原版 vue 调试页接不上 | `routes.rs:211-218` | B5 批内加原版路径别名（或 port+1 监听），验收=原版 vue 书源调试页实测可用 |
| P2-11 | 数据 | `highlightRules` 缺 `uuid/applyToBody` 两列：**标题规则会被错误应用到正文**、导入无法按身份去重 | `schema.rs:629-642`；原版 `HighlightRule.kt:21,27,40` | 迁移加两列（存量 uuid 回填），模型/仓库补字段，正文匹配按 `applyToBody` 过滤，导入按 uuid 去重；建议升优先级紧随 P1 批 |
| P2-12 | 数据 | `servers` 表整表缺失，WebDAV 配置改道 Flutter prefs（原版备份 servers.json 无恢复入口） | `webdav_api.rs:65-89` | 需裁决：补表+迁移 prefs（一次性）并纳入备份；或登记「有意改道、不兼容原版 servers.json」 |
| P2-13 | 数据 | 恢复时已有书进度不落库（[B-3] 防回滚闸挡住恢复路径），与原版语义相反 | `book_repository.rs:569-579`；原版 `Restore.kt:286-288` 全列覆盖 | 需裁决：恢复路径开显式 `restore_overwrite_progress` 入口或恢复后统一 `update_progress`；交互上可在恢复弹窗询问「覆盖进度？」 |
| P2-14 | 数据 | 若支持拷 Room v104 库直开有两处断裂（ruleSubs 早退不补超集列；4 张自有表无懒建） | `room_align_v105.rs:151-158`；`connection.rs:168-176` | 先裁决「拷库迁移」是否产品范围（§六-5）；是则补列+懒建+用原版导出 schema json 逐版比对 90→99 |
| P2-15 | UI/安全 | 书源 JS `openUrl` 外跳无确认（原版一律走 `OpenUrlConfirmActivity`；确认组件已有但只接 RSS 一处） | `platform_bridge_service.dart:919-945`；原版 `JsExtensions.kt:1199-1216` | `_openUrl` 统一接 `open_url_confirm_dialog`（组件复用），并核查正文选中打开链接路径 |
| P2-16 | UI | `/cache_settings` 死路由（全库零入口）；页面含原版不存在的「自动过期策略」 | `routes.dart:90,197` ✓亲核 | 需裁决：删除路由+屏幕（推荐，符合重构红线）；或恢复入口（则构成白名单外新增，须先授权） |

---

## 四、P3 与文档卫生

**代码 P3**：正文全角缩进补齐待确认排版层是否补偿（`web_book.rs:3891` 注释自述；原版 `BookContent.kt:174-176`）；mobi LZMA 不支持（fail-closed，`mobi.rs:501-506`）；RAR Android 不可用（已知裁决边界，JS 调用有明确报错）；RateLimiter 旧快照竞态窗口（`rate_limit.rs:41-45`）；书签 `time` 非主键→重复恢复同一备份书签翻倍（`schema.rs:340-352`，建议 time 加 UNIQUE 或 insert 改 OR REPLACE）；若干索引/默认值差异（bookmarks/auto_task_rules/searchBooks 索引、txtTocRules serialNumber 默认 0 vs -1）；readRecord 查询不带 deviceId 过滤（多设备行混读风险）；`update_last_read` 死代码；`_todo()` 防御分支建议改断言（`book_info_screen_builders.part.dart:391-403`）。

**文档可靠性（用户「部分文档不可靠」判断量化成立；形态=滞后而非虚报）**：
1. `rust/PROGRESS.md` 冻结于 2026-08-07 自称 100%，仍被 `docs/DEVELOPMENT.md:105,296`、`docs/VERSION_CONTROL.md:124`、`rust/DEVELOPMENT.md:756` 共 4 处**活链引用**——活的第二状态源，违反唯一状态源规则。**修法**：文件头加失效横幅（"2026-08-07 冻结，历史文档，当前状态见 docs/REFACTORING_ACTIVE_PLAN.md"）+ 修正 4 处活链 + 移入过期文档或原地标注。
2. ACTIVE_PLAN **正文旧段与尾部日志新旧口径并存 8 条**：P2-19 正文标「未修」vs 尾部已修（L261 vs L743）；cookie sink「仍开放」vs 已落地（L265 vs L779，`41d0f7d1cc`）；clippy 三处债务已消（L697-698）；iOS「待外部测试能力」已被 10-06 实测恢复覆盖（L26 vs L791）；A5「振幅待验证」次日已验收（L802/L803）。**修法**：逐条回销正文状态。
3. 3 个批次「hash 待补记」欠账（实际均已提交）：`43a5096376`/`9c0bacffe0`/`f40601141c`（ACTIVE_PLAN L734/737/739）。**修法**：补记。
4. 双日志缺口：updateLog 缺 2.0.336（CHANGELOG 自述零用户可见，可在 updateLog 注明或补一行）；CHANGELOG 缺 2.0.200/2.0.203（pubspec 历史证实真实发版，`40234bc17e`/`db02ba0485`）。**修法**：从 git log 提取内容补登。
5. `AGENTS.md:71`「adbd 即 root」已被 2026-10-03 实测推翻（ACTIVE_PLAN L27）但未改。**修法**：按 L27 口径修订 AGENTS.md。
6. `legacy/mod.rs:21-23` 注释 B3/B4 口径与 ACTIVE_PLAN L804 的 B3/B4/B5 漂移。**修法**：注释对齐 L804。
7. 杂项：`docs/TASK_HANDOFF_CHANGE_SOURCE_FIX_20260903.md` 已完结仍留根目录无标注；ACTIVE_PLAN 开放项引用过期文档作先行契约（L640）；本地 ignored 杂物（根 `nul`、`tmp_*`、`rust/_p03_*`）已被 .gitignore 正确覆盖，仅本地清理项。

---

## 五、正面清单（重构完成度背书）

1. **FFI 主链路零缺口**：契约 296 项全部有着落（7 个名义差均为 Dart 有意本地实现）；Rust 284 ↔ Dart 284 一一对应；旧 C ABI 175 符号零悬空；核心结构 BookSource/BookChapter 无字段 drift。
2. **屏幕覆盖**：原版 46 Activity/Fragment 逐一对照，除 P1-4 断链外全部对齐（RSS 八屏、词典三入口、定时任务、漫画/视频/音频、验证码监听、深链导入等均实现且有入口）；**白名单外未发现未授权新增功能**。
3. **规则引擎**：AnalyzeRule 语法面（CSS/@@/@XPath/@Json/$.//正则/`<js>`链/`##`四段替换/@put/@get/{{}}/JSoup 伪类/JSONPath 过滤器/XPath 宽容兜底/净化/isUrl 绝对化去重）与 AnalyzeUrl 全选项（retry 语义精确对齐 OkHttpUtils、redirect 20、concurrentRate、charset、followRedirects/dnsIp/proxy/webViewDelayTime 等）均核对完整；JS 桥约 140 函数对照 JsExtensions **未发现静默空桩**（未知符号 fail-closed + capability_ledger）。
4. **数据层核心**：进度四列语义、readRecord 作者聚合、v104 结构对齐迁移、迁移注册表 90→109、书源 serde 导入主路径、caches 过期语义均逐条对齐且质量高；legado-db 无静默桩。
5. **Web**：原版 assets/web 6 目录编译期嵌入完整；legacy 只读端点对齐；/api 自研 REST 68 条为有意扩展。
6. **文档**：尾部修订日志与 git log 高度对齐（50 提交 100% 真实，12 项落地抽验 100% 成立）——**可信度排序：尾部日志 > 正文旧段 > rust/ 历史副本**。

---

## 六、待核实项（附方法）

1. zip/7z ByteArray 返回形态：读 `quickjs_impl.rs:4552` 实现比对 `JsExtensions.kt:876-899` bytes 语义。
2. P0-1 实际触发面：Web UI（vue 页/自研 REST 客户端）是否已暴露「书源仓库更新」入口；用真实仓库 URL 手工回归确认 ruleSearch 落 NULL。
3. `chapter.resourceUrl` 双侧均无写入者（原版仅 AudioPlay 读取）：对上游 `git log -S resourceUrl`，若历史有写入点被我方漏迁则升 P1。
4. AnalyzeUrl `speakText/speakSpeed` TTS 模板绑定：`rg 'speakText|speak_text' rust/legado-core/src/tts_speak.rs rust/legado-ffi/src/api/`。
5. 「拷原版 legado.db 直开」是否产品范围（P2-14 前提）：检索 Flutter/文档是否有拷库引导。
6. 原版 vue 打包页是否含替换规则管理入口（影响 B4 端点清单）：以原版 vue 源仓为准。

---

## 七、修复批次建议（优先级排布）

| 批次 | 内容 | 说明 |
|---|---|---|
| 批1（数据安全） | P0-1 + P1-6/7/8/9 + BackupData 版本化 | 「静默数据丢失」族同批收敛；全部附往返测试 |
| 批2（引擎字段） | P1-1/2/3 + P2-1/2/3 | 转换层字段透传 + 两条规则接线；串行/并发合并 |
| 批3（UI 断链与高亮） | P1-4/5 + P2-11 + P2-15 | 文件打开、堆转储（A/B 裁决后）、highlightRules 列、openUrl 确认 |
| 批4（Web B3/B4/B5） | P2-9/10 | 按 ACTIVE_PLAN L804 口径；B3 先做写端点+图片缓存根注入 |
| 批5（文档修整） | §四-文档 1~6 + P2-7 契约登记债 | 机械工作为主，可派子代理 |
| 待裁决清单 | P2-5/12/13/14/16、P1-5 A/B、原版 zip 恢复范围 | 用户裁决后归入相应批次 |

---

## 八、防复发规定建议（供纳入 docs/DEVELOPMENT_CONVENTIONS.md）

以下规定逐条对应本次缺陷的根因模式：

1. **单实现原则**（根因：RoomImporter 与 serde 链路分叉、目录串行/并发双实现）：同一数据的写库/转换语义只允许一个实现；新入口必须复用既有实现，不得旁路复制。代码审查 checklist 增加该项。
2. **禁止沉默空置**（根因：sourceLoginV1/rss 批量/downloadUrls 链/direct_link_upload 实现-不接线）：新增 Rust API 必须同批接 Dart 调用点，或在契约登记「预留（未接线）」状态及接线批次；禁止既不接也不登记。建议在 `api_contract_test.dart` 增加「绑定全库零调用检测」，自动列出死接线。
3. **转换层字段透传断言**（根因：is_volume/is_pay/tag 硬编码 false/None）：结构体转换禁止 `false/None` 兜底硬编码；每个跨层转换函数配「全字段透传测试」（源全字段非默认 → 目标逐字段相等）。
4. **形态不符必须显式**（根因：规则对象 as_str 得 None、readConfig 只认字符串、@webjs 静默空串）：解析外部格式时区分「合法缺省」与「形态不符」；后者必须报错或登记 capability_ledger 告警，禁止静默吞掉。
5. **往返测试义务**（根因：备份恢复 7 列、测试种子过干净）：导入/导出/备份类功能必须配「导出→清库→恢复→逐字段 diff」往返测试；fixture 必须用真实抓包 JSON（含嵌套对象形态），延续 Mock 数据真实 JSON 规范到测试种子。
6. **平台声明与实现同步**（根因：manifest VIEW intent-filter 无消费方）：manifest/Info.plist 声明的入口必须有对应处理链路与验证用例；下线功能必须同批删声明。
7. **文档回销义务**（根因：ACTIVE_PLAN 正文滞后 8 条、hash 欠账 3 个）：批次关闭时必须回查正文旧段是否需改状态（不得只追加尾部日志）；「hash 待补记」当批补齐，禁止跨批欠账；第二状态源（如 rust/PROGRESS.md）发现即加失效横幅。
8. **周期性零引用清理**（根因：direct_link_upload、cache_settings、update_last_read 死代码积累）：每 ~10 个批次跑一次零引用审计（判零引用须按裸名全仓重搜，含路由名/FFI 符号/manifest 声明三类）。
9. **备份格式版本化**（根因：BackupData 无版本，扩表会破坏旧备份）：备份结构必须携带版本字段，恢复器按版本兼容降级。
10. **双基准清单关门**（延续既有口径）：功能面缺口须同时核对原版与参考版两侧再关门（本次 RSS 屏幕「未做」传言即靠逐屏对照排除）。

---

## 九、重构计划（ACTIVE_PLAN 等）是否需要更新 —— 结论：**需要，共 5 处**

1. **新增本审查批次登记**（最重要）：将 P0-1 与 P1-1~9 登记为「已确认待修」（证据=本报告），P2-1~16 按表登记（其中 P2-5/12/13/14/16 标「待用户裁决」）；按 §七 排批次顺序。本报告即为证据源，登记时引用本文件路径即可，不必复制证据。
2. **回销正文旧段 8 条**：§四-文档 2 的清单（P2-19、cookie sink、clippy、iOS 状态等）。
3. **补记 3 个 hash**：`43a5096376`/`9c0bacffe0`/`f40601141c`（L734/737/739）。
4. **B3/B4/B5 段落精确化**：写入本次核实的端点清单（写 14 + 管理读+令牌 7 + 段评 6 + WS 路径别名要求），并把「WS 推送未做」的旧口径改为「等价能力已有、路径/端口未对齐」。
5. **不动项**：「待核验」媒体轨等历史登记维持原状（本次未涉及）；§六 待核实项核实后再决定是否立项。

> 说明：ACTIVE_PLAN 是唯一状态源，更新条目多且含裁决项，建议在用户对「待裁决清单」表态后，随批1任务书派发一并更新（避免本轮先改一半再改一半）。

---

## 十、过程记录

- 子代理通道中途出现 3 次秒级风控拦截（"request has been blocked due to unusual activity"），重启客户端后恢复；3 并行时触发服务端 `user concurrency limit`（子代理硬并发上限约 2），改为排队补派，未影响结果。
- 主代理亲核清单：P0-1（import.rs/source.rs/source_update.rs 原文）、P1-1/2/3（reader.rs:582/810/1582 上下文、content_rule 消费面 rg、download_urls rg）、P1-4（manifest+deep_link_service 原文）、P2-16（cacheSettings 全库 rg）。
- 审查覆盖统计：Rust 9 crate（parser/book/core/js/net/fetcher/db/ffi/server）、Flutter lib 全量（405 dart 文件）、原版 46 Activity/Fragment、Room 24 表 + 1 视图、Server 路由全量、docs 状态类文档。

---

编写：ZCode（主代理，负责拆解/派发/亲核/汇总）· 五路只读子代理交叉审查（引擎链路 / FFI 契约与 Web / Flutter UI / 数据层 / 文档可靠性）｜ 2026-10-26
