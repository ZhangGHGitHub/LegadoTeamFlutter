# 留项详细开发评审（2026-08-06）

**报告日期**: 2026-08-06
**评审范围**: 批次0-3 修复完成后的 13 项留项（来源：[REFACTORING_AUDIT_REPORT_20260806.md](REFACTORING_AUDIT_REPORT_20260806.md) §7.3 与 [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) §5.9，两份清单已核对一致，互为镜像）
**报告定位**: 下一轮开发的逐项执行依据——现状证据（文件:行）、所需交付、跨轨依赖、实现方案要点、工作量、批次建议与风险
**方法**: 全部结论基于源码 grep/阅读实证与两份文档登记，不臆测；行号为 2026-08-06 工作区快照

> ✅ **状态更新（2026-08-07，Task #140）**：Rust 剩余项全批（R1-R10+R12）已闭合——留项 1（saveChapterContent，R5）/3（payAction，R6）/8 步骤2（bridge.rs DEPRECATED 标注，R12）/9（subContent+replaceRegex+server 正文+dict 规则引擎，R1-R4）已闭合；留项 11 Rust 大头已闭合（R7 缓存批量下载 + R8 导出参数，book_export 已支持四格式）；留项 13 QUIC 六件套改为**已移除**（用户决策，纯重构边界）。销记台账见 [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) §5.10。仍开放：留项 2/4/5/6/7（schema v102 保持触发型延后）/10/13 非 QUIC 部分（backupList/bookGroupSetShow/httpTtsSetEnabled）及留项 11 UI 侧部分；留项 12 已随 Task #131（2026-08-07）另行闭合。
>
> ✅ **Doc2（2026-08-13）**：§7「schema v102」已强制落地为 **SCHEMA_VERSION=104 / Migration103To104**；勿再按「触发型延后」排期。残留：rule_subs/dict_rules/keyboard_assists 表名（D1 分步；default_data 双建表已清）。权威开放项见 [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md)。
>
> ✅ **Doc4**：定时服务已 JobScheduler 双轨接通（非「仅应用内」）；F2 冷启动尽量 headless。
> ✅ **F9**：离线缓存导出模板/WebDAV 已接线（`335fcb11c`）。

---

## 1. 章节内容保存 FFI（saveChapterContent）

> ✅ **已闭合（2026-08-07，R5，Task #140）**：saveChapterContent FFI 新增（契约 §2.43.1），复用 CacheBookRepository 写侧，读写键与 cacheGetChapter 一致。

| 字段 | 内容 |
|------|------|
| **现状证据** | Flutter：`flutter_legado/lib/src/widgets/reader/reader_top_bar.dart` L212-245 编辑对话框已存在，L237-238 `TODO(留批次)`——保存按钮仅弹 SnackBar「编辑暂不持久化」。Rust：全工作区无 saveChapter/save_content 任何实现（grep 0 命中）；缓存系 FFI 只有读侧六件（`rust/legado-ffi/src/ffi.rs` L1118-1152：cache_get_size/cache_clear/cache_get_chapter/cache_get_book_count/cache_get_chapter_count/cache_clear_before）。**关键**：写侧仓储已就绪——`rust/legado-db/src/repository/cache_book_repository.rs` L19 `insert`（INSERT OR REPLACE）/ L40 `update` 均已实现并有测试。Kotlin 原版：`ReadBookViewModel.saveContent`（`app/src/main/java/io/legado/app/ui/book/read/ReadBookViewModel.kt` L434-442）→ `BookHelp.saveText`（`app/src/main/java/io/legado/app/help/book/BookHelp.kt` L181）；UI 为 `ContentEditDialog.kt` L37 |
| **所需交付** | 新 FFI（加法式，如 `cacheSaveChapter(book_url, chapter_index, content)`）+ BookApi 封装 + UI 接线 |
| **跨轨依赖** | Rust → UI 阻塞方向；须先在 API_CONTRACT.md §3 需求区冻结契约（双轨铁律） |
| **实现方案要点** | Rust 侧直接复用 CacheBookRepository.insert 暴露 FFI（键与 cacheGetChapter 读路径一致：book_url+chapter_index）；UI 侧保存成功后调 readerNotifier 重载当前章（对标原版 `ReadBook.loadContent(durChapterIndex, resetPageOffset=false)`）；本地书与在线书统一走 cached_chapters 表（Rust 轨存储口径，替代原版文件缓存） |
| **工作量估算** | 1-1.5 人日（Rust FFI+契约+测试 0.5-1d，UI 接线 0.5d） |
| **建议优先级与批次** | P1；波次4（阅读器闭环专项），契约先行 |
| **风险/注意事项** | 契约冻结约束；读写键格式必须与 cacheGetChapter 完全一致，否则「保存后重读仍是旧内容」；空内容保存按原版 `saveText` 语义直接返回（BookHelp.kt L186） |

## 2. 反转内容持久化

> ✅ **已闭合（2026-08-13 核销）**：`reader_top_bar._reverseContent` → runes 倒序 → `saveChapterContent` → `reloadChapterContent`。

| 字段 | 内容 |
|------|------|
| **现状证据** | ~~菜单仅 SnackBar~~ → 已接 saveChapterContent FFI |
| **所需交付** | 纯 UI/Dart 逻辑；**依赖留项 1 的 FFI**，无需新契约 |
| **跨轨依赖** | 已解 |
| **实现方案要点** | 已交付 |
| **工作量估算** | — |
| **建议优先级与批次** | 已完成 |
| **风险/注意事项** | — |

## 3. 章节购买 payAction

> ✅ **已闭合（2026-08-07，R6，Task #140）**：chapterPayAction FFI 新增（契约 §2.43.2），复用登录 V2 JS 执行设施，url/success/none 三态返回，本地书短路 kind=none。

| 字段 | 内容 |
|------|------|
| **现状证据** | Flutter：`flutter_legado/lib/src/widgets/reader/reader_bottom_bar.dart` L123-125 `case 'chapterPay'` `TODO(留批次)`——仅 SnackBar「需书源 payAction 支持，暂未实现」。Rust：无任何 payAction FFI；仅模型字段 `rust/legado-core/src/models/rule/content_rule.rs` L30-31 `pay_action: Option<String>` 已建模。Kotlin 原版：`ReadBookActivity.payAction()`（`app/src/main/java/io/legado/app/ui/book/read/ReadBookActivity.kt` L1592-1620）——读 `source.getContentRule().payAction`，经 `SourceLoginJsExtensions` + `runScriptWithContext` 执行 JS（put java/book 上下文）；菜单入口 `ReadMenu.kt` L118 `menu_chapter_pay`；书源编辑页含 payAction 字段（`BookSourceEditActivity.kt` L569/L795） |
| **所需交付** | 新 FFI（契约变更·加法式，如 `sourcePayAction(source_json, book_json, chapter_url)` → Rust 侧执行 payAction JS 返回结果 JSON）+ UI 接线 |
| **跨轨依赖** | Rust → UI 阻塞方向；契约先行 |
| **实现方案要点** | 复用登录 V2 同款 JS 执行基础设施（`source_login_action_v2` 已在 ffi.rs L313 交付，JS 上下文机制现成）；payAction 为空时按原版抛「no pay action」语义映射 BridgeError；UI 侧阅读器底栏源操作菜单接通并对齐原版执行后刷新章节 |
| **工作量估算** | 2-2.5 人日（Rust 1.5-2d 含 JS 上下文与测试，UI 0.5d） |
| **建议优先级与批次** | P2（依赖书源配置了 payAction，覆盖面有限）；波次5 |
| **风险/注意事项** | payAction 是「js 或含 {{js}} 的 url」两形态（ContentRule.kt L22 注释），url 形态需跳转呈现而非纯 JS 执行，方案需覆盖两分支；JS 书源兼容测试样本难构造 |

## 4. 段落级 TTS 切换起点（startReadAloud 偏移参数）

> ✅ **已闭合（2026-08-13 核销）**：`AudioNotifier.startReadAloud(startChapterPos:)` + 段落队列；`text_selection_panel`「朗读所选」传入 `chapterPos`。

| 字段 | 内容 |
|------|------|
| **现状证据** | ~~整章送读~~ → 段落管线 + startChapterPos |
| **所需交付** | 纯 Flutter |
| **跨轨依赖** | 无 |
| **实现方案要点** | 已交付 |
| **工作量估算** | — |
| **建议优先级与批次** | 已完成 |
| **风险/注意事项** | — |

## 5. 语速跟随系统实时通道

> ✅ **已闭合（2026-08-13）**：默认 true；config 键 `ttsFollowSys`；跟随=1.0x 默认语速（非系统实时通道）；旧 SP 键自动迁移。

| 字段 | 内容 |
|------|------|
| **现状证据** | 对齐原版 `ttsFlowSys` + `speechRatePlay` |
| **所需交付** | 纯 UI/配置 |
| **跨轨依赖** | 无 |
| **实现方案要点** | 已交付 |
| **工作量估算** | — |
| **建议优先级与批次** | 已完成 |
| **风险/注意事项** | — |

## 6. MoreConfig 其余项（显示标题/滚动条/音量键翻页等）

| 字段 | 内容 |
|------|------|
| **现状证据** | Flutter：`flutter_legado/lib/src/screens/reader_config_panel.dart` L695-696 `TODO(留批次)`——「更多配置」区现仅 2 项：简繁转换（L644-681）与两端对齐（L683-694）。Kotlin 原版：`MoreConfigDialog.kt` L35（PreferenceFragment 壳）+ `app/src/main/res/xml/pref_config_read.xml` 共约 28 项：屏幕方向/保持亮屏/隐藏状态栏/隐藏导航栏/简繁转换/刘海边距/双页横排/进度条行为(progressBarBehavior)/中文排版/两端对齐/悬挂标点/底部对齐/适配特殊样式/鼠标滚轮翻页/**音量键翻页(volumeKeyPage)**/朗读时音量键翻页/长按连续翻页/触摸灵敏度/点击灵敏度/自动换源/选择文本开关/亮度控件/无动画滚动/图片点击方式/高亮触发方式/优化渲染/点击区域配置/禁用返回键/自定义翻页键/选择菜单配置/**显示标题(showReadTitleAddition)**/工具栏跟随页面 |
| **所需交付** | 纯 UI 为主（config 存取 + 阅读器侧响应）；个别项需阅读器/平台能力配合 |
| **跨轨依赖** | 无跨轨阻塞（设置键走既有 getConfig/setConfig） |
| **实现方案要点** | 分两批：① 无平台依赖项先行——显示标题、进度条行为、工具栏跟随页面、无动画滚动、自动换源、选择文本开关、亮度控件、隐藏状态栏/导航栏、保持亮屏、屏幕方向等（每项对标原版 onSharedPreferenceChanged 事件语义，MoreConfigDialog.kt L113-175）；② 平台相关项——音量键翻页/鼠标滚轮/长按连续翻页需 HardwareKeyboard 监听，Windows 与 Android 分别验证，不适用平台按原版逻辑隐藏或禁用 |
| **工作量估算** | 2-3 人日（约 20 个可落地项，0.5d/3-4 项节奏 + 阅读器联动调试） |
| **建议优先级与批次** | P1；波次4 完成第①批，第②批随波次5 |
| **风险/注意事项** | 每项开关必须真实作用到阅读器渲染/行为（对标原版 EventBus UP_CONFIG 分发），只存配置不生效即属假对齐；音量键等在 Windows 桌面无意义的项需诚实处理而非强行模拟 |

## 7. schema v102 重建表（合并 schema 对齐专项）

> ✅ **已完成（2026-08-13）**：用户确认强制执行。代码版本号为 **SCHEMA_VERSION 103→104**（避开已占用的 v102/v103）。实现见 `rust/legado-db/src/migration/schema_align_v104.rs`；契约/台账销记见 API_CONTRACT 与 REFACTORING_REMAINING_PLAN §4.2.1。残留：rule_subs/dict_rules/keyboard_assists 表名未改。

| 字段 | 内容 |
|------|------|
| **现状证据** | 已落地：Migration103To104；legado-db 297 单测含 v103→v104 全链路 |
| **所需交付** | ✅ 结构对齐 5 项 + rssStars 主键 + search_keywords + coverRules |
| **跨轨依赖** | 无新 FFI；冷启动打开库升级即可 |
| **残留** | rule_subs/dict_rules/keyboard_assists 表名/列名 snake_case |

## 8. bridge.rs C ABI 三步废弃

> ✅ **步骤2 已完成（2026-08-07，R12，Task #140）**：bridge.rs 模块级 DEPRECATED 标注 + 冻结新增（新能力一律进 frb 主链路，本批 §2.43 七方法不在 C ABI 面暴露）；步骤3 物理移除仍挂下一大版本节点。

| 字段 | 内容 |
|------|------|
| **现状证据** | [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) §4.2.3 P2-1 决策记录（L650-653，Task #118）：决策为**保留 + 计划性废弃**。现状事实：`rust/legado-ffi/src/bridge.rs` 实测 2116 行、约 196 个 `ffi_*` extern "C" 导出；Rust 侧零调用点；Dart 全量走 frb 主链路（ffi.rs 166 函数 ↔ ffi.dart 166 绑定 100% 对齐）；移除前置条件 txt_search 迁 frb 已满足（Task #165）。三步走：① ✅ 决策记录（已完成）→ ② DEPRECATED 标注 + 冻结新增 → ③ 下一大版本物理移除 |
| **所需交付** | 步骤2：治理性标注（bridge.rs/lib.rs 模块文档 DEPRECATED + `#[deprecated]` + DEVELOPMENT.md 新增函数禁令）；步骤3：物理移除 + 台账/契约销记。均无功能变更 |
| **跨轨依赖** | 无阻塞；步骤3 前置需确认无外部 C 消费者（.so 导出符号面变更不可逆） |
| **实现方案要点** | 步骤2：模块级 doc 标注 DEPRECATED、冻结新增（新能力一律进 frb 主链路）、在 CI/lint 层加「bridge.rs 不得新增导出」检查约定；步骤3：大版本发布前审计 .so 导出符号消费方 → 删除 bridge.rs → `make gen` 重新生成 → 销记本台账 §4.2.3 与 API_CONTRACT.md |
| **工作量估算** | 步骤2：0.5 人日；步骤3：1-2 人日（含导出面验证与回归） |
| **建议优先级与批次** | P2；步骤2 随波次4/5 治理穿插，步骤3 挂下一大版本节点（不单独占波次） |
| **风险/注意事项** | 直接删除会改变 cdylib 导出符号面且不可逆（决策记录保留理由 L652）；步骤3 前必须确认历史 C ABI 接入方已不存在，宁可多留一个大版本 |

## 9. Rust P2 缺口（subContent、contentRule.replaceRegex、legado-server 正文桩、dict 18 词占位）

> ✅ **已闭合（2026-08-07，R1-R4，Task #140）**：① subContent 副内容（txt/http 分支）+ replaceRegex 全文替换真实实现（web_book.rs，对标 BookContent.kt L128-174）；② legado-server 正文接口接 RealBookSourceFetcher 真实链路；③ dict_api 重写为原版字典规则引擎（dict_rules 逐规则执行 + 表空注入原版默认 5 字典源 seed，不再自造静态表）。

| 字段 | 内容 |
|------|------|
| **现状证据** | ① **subContent/replaceRegex**：字段已建模（`rust/legado-core/src/models/rule/content_rule.rs` L9-10 `sub_content`、L21-22 `replace_regex`），但正文解析管线未应用——`rust/legado-ffi/src/api/web_book.rs` `parse_content_page`（L674-700）只做正文规则提取 + HtmlFormatter 净化 + nextContentUrl 分页（L594-653 `get_content`），全解析链无 sub_content/replace_regex 引用。Kotlin 原版对照：`app/src/main/java/io/legado/app/model/webBook/BookContent.kt` L128-165 subContent 副内容（在线 txt 追加 / http 二次请求 / 音频歌词 putLyric / 视频弹幕 putDanmaku）与 L166-174 replaceRegex 全文替换。② **legado-server 正文桩**：`rust/legado-server/src/handlers/reader.rs` L27-31 `get_chapter_content` 注释明示「暂返回章节元数据，后续可对接内容解析逻辑」；同 crate `handlers/web_book.rs` L91-96 已有 RealBookSourceFetcher 完整抓取器可复用。③ **dict 18 词占位**：`rust/legado-ffi/src/api/dict_api.rs` L35-56 `BUILTIN_DICT` 静态 18 词表（契约达标、数据覆盖为占位级，模块注释 L8-12 自述） |
| **所需交付** | Rust 核心逻辑补齐（无 FFI 加法、无契约变更——同函数行为增强）；dict 需先做数据源决策 |
| **跨轨依赖** | 不阻塞 UI（UI 已按现有契约消费）；Rust 轨独立推进 |
| **实现方案要点** | ① subContent/replaceRegex：在 `get_content` 分页拼接后追加两步处理，严格对标 BookContent.kt L128-174（subContent 分支：isOnLineTxt 直接追加 / http 开头走 AnalyzeUrl 二次请求 / audio 存 lyric / video 存 danmaku；replaceRegex：按 LF 分行 trim 后交 analyzeRule.getString 做全文替换）；② legado-server：`get_chapter_content` 接 RealBookSourceFetcher 正文链路（复用 handlers/web_book.rs 既有解析器）；③ dict：决策数据源——扩大内置静态表或接 dict_rules 在线规则统一查询（在线规则链路现已以 URL 跳转呈现，见 dict_api.rs 模块注释），**不得自造词典数据产品**（纯迁移边界） |
| **工作量估算** | subContent+replaceRegex 2-3d；server 正文接线 1d；dict 数据 0.5-1d；合计 3.5-5 人日 |
| **建议优先级与批次** | P2；波次5（Rust 轨批量），其中 subContent/replaceRegex 建议先行（用户可见的正文完整性收益） |
| **风险/注意事项** | subContent 涉及二次网络请求与歌词/弹幕存储字段（bookChapter 扩展），范围易膨胀，建议先实现 txt/http 两分支、音视频分支单独排期；replaceRegex 含 JS 形态（`##` 正则与 `<js>` 混合）需与 AnalyzeRule 口径一致 |

## 10. 定时服务后端（autoTask 后台执行）

| 字段 | 内容 |
|------|------|
| **现状证据** | Flutter：`flutter_legado/lib/src/screens/settings_screen.dart` L39-42、L166-168「定时服务无后端 FFI，仅持久化开关 + TODO」；`flutter_legado/lib/src/screens/auto_task_screen.dart` L179-182 开关仅切换 `isEnabled`。**口径修正（评审发现）**：执行 FFI 实际已交付并封装——Rust `rust/legado-ffi/src/ffi.rs` L1650-1662 `auto_task_execute`/`auto_task_execute_with_id`、L1691-1693 `auto_task_next_due_at`（cron 计算），BookApi 已封装（`book_api.dart` L815-845），`auto_task_notifier.dart` L239-270 `runNow` 已经 FFI 手动执行成功。**真实缺口 = Flutter 侧无调度器**：无 dueRules 批量执行、无到期自动触发、无后台执行。Kotlin 原版：`app/src/main/java/io/legado/app/service/AutoTaskJobService.kt`（JobService 双 job 槽 + retry，L25-79）+ AutoTaskScheduler + `AutoTaskRunner.runDueTasks`（AutoTaskRunner.kt L25-27：`dueRules(enabled, now)` 批量执行） |
| **所需交付** | Flutter 侧调度服务（纯 Dart：Timer 调度 + due 判定 + 批量执行）；真后台执行（应用退出后）需平台后台机制，属决策项 |
| **跨轨依赖** | 无 FFI 阻塞（执行/cron 计算 FFI 齐备）；若需批量「查询到期任务」FFI 可加法式补充，但用现有 autoTaskNextDueAt 逐任务计算亦可 |
| **实现方案要点** | ① 应用内调度器：应用启动/任务变更/开关开启时，按各任务 cron 经 autoTaskNextDueAt 计算最近到期时间，Timer 到点执行 `runDueTasks`（筛 isEnabled 且到期任务，逐个 autoTaskExecuteWithId，对齐原版 executionLock 串行 + 失败 retry 语义）；② 设置页开关联动调度器启停；③ 真后台执行（Android WorkManager / Windows 计划任务）需引入平台插件，超出纯迁移口径，单独决策立项 |
| **工作量估算** | 应用内调度器 2-3d；真后台执行（含插件接入与构建矩阵适配）另计 3-5d |
| **建议优先级与批次** | 应用内调度器 P1，波次5；真后台执行 P2 决策项，波次6+ |
| **风险/注意事项** | 任务执行含更新书源/书籍等长耗时网络操作，需隔离单任务失败不影响整批（原版 AutoTaskJobService L49-64 的 retry/jobFinished 语义）；引入 workmanager 类插件影响 CI 构建矩阵与包体，须先过决策 |

## 11. 书架缓存导出扩展项（缓存管理页/epub/pdf/模板/WebDAV）

> ✅ **Rust 大头已闭合（2026-08-07，R7/R8，Task #140）**：缓存批量下载 4 方法 FFI（契约 §2.43.3，内存任务表 + worker + 取消令牌）+ bookExportWithOptions 导出参数扩展（契约 §2.43.4，**book_export 已支持四格式**，格式/charset/章节范围/文件名模板透传）；剩余为缓存管理页 UI、模板/WebDAV 接线与进度/取消 UI。原「EPUB/PDF 为最大工作量」口径修正：导出引擎侧已随 R8 就绪。

| 字段 | 内容 |
|------|------|
| **现状证据** | Flutter：`flutter_legado/lib/src/screens/bookshelf_screen.dart` L719-725 `TODO(留批次)` 明细列出缺项——缓存管理独立页（书籍列表/缓存进度/单本导出入口）、缓存下载（download_after/download_all）、epub/pdf 导出类型、导出文件夹选择与文件名模板、自定义导出设置（charset/章节范围/不导出章节名）、导出进度与 WebDav；已交付部分：单本 TXT 正文导出（L719-721 注释：经 cacheGetChapter 逐章拼接 TXT，分享通道保存）。Kotlin 原版：`app/src/main/java/io/legado/app/ui/book/cache/CacheActivity.kt`（L70 cache/download 双功能页、L77 exportTypes = txt/epub/pdf、L85-98 导出目录选择持久化、L138-142 缓存下载菜单 download_after/download_all、L458-472 epub 分卷/范围参数）+ `app/src/main/java/io/legado/app/service/ExportBookService.kt`（L197，epublib 生成 EPUB，支持 txt/pdf、文件名模板、章节范围、charset） |
| **所需交付** | 混合：新 Rust 能力（EPUB/PDF 打包引擎）+ 新 FFI（契约加法：批量缓存下载、导出任务创建/进度/取消）+ 新 UI 页（缓存管理页） |
| **跨轨依赖** | Rust → UI 阻塞（EPUB/PDF 生成属内容处理，归 Rust 核心轨）；契约先行（API_CONTRACT.md §3 需求区登记导出任务契约） |
| **实现方案要点** | 拆分推进：① 缓存管理页 UI 可先行（书籍列表 + 缓存状态/进度 + 单本入口，复用现有 cache* FFI 与缓存下载走既有章节抓取链路）；② EPUB 导出为最大工作量——Rust 侧需 epub 打包（OPF/NCX/XHTML 章节资源 + 封面嵌入，对标 ExportBookService 的 epublib 用法），建议引入成熟 crate 而非自研；③ PDF 依赖渲染方案（文字排版 → PDF），原版经 Android 打印框架，Rust 轨需选型（如 printpdf/pdf-writer），工作量与风险最高；④ 文件名模板/charset/章节范围属导出参数透传；⑤ WebDAV 上传复用现有 WebDAV 设置通道（settings_screen 已有 webdavSettings 路由） |
| **工作量估算** | 缓存管理页 + 缓存下载 3-4d；EPUB 导出 4-6d；PDF 导出 3-5d；模板/设置/WebDAV 1-2d；合计 **11-17 人日**（建议拆 3 个子项分批） |
| **建议优先级与批次** | P2；波次6 起拆批：子项 A（缓存管理页+缓存下载+TXT/EPUB）先行，子项 B（PDF）与子项 C（模板/WebDAV）随后 |
| **风险/注意事项** | 工作量最重的一项，EPUB/PDF 涉及图片资源处理与进度/取消机制，易低估；PDF 渲染选型若无原版等价方案需登记为「平台差异决策」；导出大书时的内存与 IO 需分批写入 |

## 12. searchSource 分组过滤

| 字段 | 内容 |
|------|------|
| **现状证据** | Flutter：`flutter_legado/lib/src/screens/change_source_screen.dart` L341-360 `_showGroupPicker` `TODO(留批次)`（台账 §5.9 正式登记）——分组单选已实现且持久化 `searchGroup` config（L358 setConfig）并触发重搜（L360），**但过滤未生效**；`rust_api.dart` L435-440 `searchSource` → `bridge.sourceSwitchSearch(bookName, author)` 仅两参。Rust：`rust/legado-ffi/src/ffi.rs` L741-744 `source_switch_search(book_name, author)` 无分组参数，`api/source_switch::search_alternative_sources` 未读取 searchGroup config。Kotlin 原版：`app/src/main/java/io/legado/app/ui/book/changesource/ChangeBookSourceViewModel.kt` L197-203——`AppConfig.searchGroup` 非空时 `bookSourceDao.getEnabledPartByGroup(searchGroup)`，结果为空提示「是否切换到全部分组」（ChangeChapterSourceDialog.kt L90-97 同款对话框语义）；搜索调用亦带分组（L404-418） |
| **所需交付** | Rust 行为增强。两条路线：**(a) 推荐**——Rust 侧内部读取 `searchGroup` config 过滤候选源（UI 已持久化 config，零契约变更，与原版 AppConfig 读取方式一致）；(b) FFI 加可选 group 参数（契约加法，需冻结 + codegen） |
| **跨轨依赖** | Rust → UI 半阻塞（UI 已就位，只待过滤生效）；路线 (a) 无契约变更 |
| **实现方案要点** | SourceMatcher 选候选源阶段按 `book_source_group` 包含 searchGroup 过滤（对齐原版 `getEnabledPartByGroup` 的组内包含匹配 SQL 语义）；空分组（searchGroup 为空）= 全部启用源；过滤后零结果时 UI 弹「分组搜索结果为空，是否切换到全部分组」对话框（对标 ChangeChapterSourceDialog L90-97），确认后清空 searchGroup 重搜 |
| **工作量估算** | 1-1.5 人日（Rust 过滤 + 测试 0.5-1d，UI 空结果对话框 0.5d） |
| **建议优先级与批次** | P2 快赢；波次5 |
| **风险/注意事项** | 分组匹配语义须对齐原版（分组字段为逗号/空格分隔多组时的包含判定）；确认 searchGroup config 键在 Rust config 仓储中的读写路径已存在（UI 侧 setConfig 已通，风险低） |

## 13. 9 个待封装 bridge 绑定（QUIC 六件套 + backupList/bookGroupSetShow/httpTtsSetEnabled）

> ✅ **QUIC 部分已处置（2026-08-07，Task #140，用户授权）**：QUIC 客户端六件套连同总开关共 8+8 FFI 导出已从 Rust/FFI/Dart 全链路**移除**（用户决策，纯重构边界：QUIC 为 Rust 轨扩展、原版无对应能力），不再需要封装决策；剩余 backupList/bookGroupSetShow/httpTtsSetEnabled 3 项仍待 UI 封装。

| 字段 | 内容 |
|------|------|
| **现状证据** | [API_CONTRACT.md](API_CONTRACT.md) §3 待封装表（L586-602）：剩 9 项——QUIC 客户端六件套 `quicCreateClient/quicGet/quicPost/quicPerformanceTest/quicIsInitialized/quicCleanup`（L589-594）、`backupList`（L595）、`bookGroupSetShow`（L597）、`httpTtsSetEnabled`（L598）。Dart 绑定均已生成但未被 BookApi/UI 封装：`flutter_legado/lib/src/bridge/ffi/ffi.dart` L778（bookGroupSetShow）/L858（httpTtsSetEnabled）/L912（backupList）/L1173-1178（quicCreateClient/quicGet）。Rust 实现均在：ffi.rs L1084（book_group_set_show）/L1200（http_tts_set_enabled）/L1256（backup_list）/L1562 起（quic 系列）。消费侧现状：备份恢复为设置页底部弹窗（`settings_screen.dart` L424-436 `_showBackupSheet`，无备份文件列表）；朗读引擎页仅增删改无启停（`read_aloud_config_screen.dart` L18-142）；书架分组页无显示开关接线；QUIC 开关对（netSetQuicEnabled/netIsQuicEnabled）已封装（`book_api.dart` L556-560） |
| **所需交付** | 纯 UI 封装（FFI 全部已实现且契约已登记 §2.41，零契约变更） |
| **跨轨依赖** | 无阻塞，UI 轨独立消化 |
| **实现方案要点** | ① backupList → 备份恢复弹窗「恢复」流程列出本地备份文件供选择（对标原版 BackupConfigFragment 的文件选择）；② bookGroupSetShow → 书架分组管理加「显示/隐藏」开关（原版 BookGroup.show 语义）；③ httpTtsSetEnabled → 朗读引擎列表项加启用开关（原版 HttpTts.enabled 语义），未启用引擎不出现在朗读引擎选择中；④ QUIC 六件套为客户端诊断工具，**原版 Kotlin 无对应 UI**（QUIC 为 Rust 轨扩展），按纯迁移边界建议二选一：挂网络诊断入口（若既有设置项规划）或登记「无需封装」销记——需用户确认，不建议自造诊断页 |
| **工作量估算** | backupList 0.5d + bookGroupSetShow 0.5d + httpTtsSetEnabled 0.5d + QUIC 决策/销记 0.25d ≈ **2 人日** |
| **建议优先级与批次** | P2；波次5 接线批量（与留项 12 同批，均为小接线） |
| **风险/注意事项** | QUIC 六件套封装属「原版没有的功能 UI」嫌疑，先决策后动手；httpTtsSetEnabled 依赖 http_tts 表 enabled 列语义（该表为 schema 偏离表，v102 重建时一并确认列集） |

---

## 附录 A：P2 约 35 项观察项（简述）

来源：审计 §7.4 第 7 行（REFACTORING_AUDIT_REPORT_20260806.md L263）——「其余约 35 项零星菜单/行为细节」因审计当时未归档逐条明细，已**降级为观察项**，无逐条清单可评。处置约定：已随批次1/2 对应屏幕修复覆盖（873abea29/522e1c1be 覆盖阅读器/书架/书详/RSS/规则/换源/听书/设置），**残留分歧发现时单独立项登记**至台账 §5，不单独立批次。本轮不估算工时。

## 附录 B：评审中的三项口径修正（重要）

1. **留项 5 前提修正**：原版「语速跟随系统」不读系统实时语速，仅用默认语速常量（AppConfig.kt L393）——无需系统通道，纯配置修正即可对齐。
2. **留项 10 口径修正**：autoTask 执行 FFI（execute/executeWithId/nextDueAt）已交付且已封装，真实缺口是 Flutter 侧调度器，非「FFI 未移植」。
3. **留项 11 工作量口径**：EPUB/PDF 导出为全清单最重单项（11-17d），必须拆子项分批，避免单批超载。（**2026-08-07 补记**：Rust 侧导出大头已随 R7/R8 闭合，book_export 已支持四格式，剩余工作量降为 UI 页面与模板/WebDAV 接线。）

---

## 优先级排序总表（建议开发顺序）

| 序 | 留项 | 优先级 | 建议波次 | 人日 | 依赖/前置 |
|----|------|--------|----------|------|-----------|
| 1 | 1. saveChapterContent FFI | P1 | 波次4 | 1-1.5 | **契约先行**（API_CONTRACT §3） |
| 2 | 2. 反转内容持久化 | P1 | 波次4 | 0.5 | 依赖留项 1 |
| 3 | 5. 语速跟随系统语义对齐 | P2 快赢 | 波次4 | 0.5 | 无 |
| 4 | 4. 段落级 TTS 切换起点 | P1 | 波次4 | 2-3 | 无（纯 Flutter） |
| 5 | 6. MoreConfig 第①批（无平台依赖项） | P1 | 波次4 | 1.5-2 | 无 |
| 6 | 13a. backupList/bookGroupSetShow/httpTtsSetEnabled 封装 | P2 | 波次4-5 | 1.5 | 无（FFI 已齐） |
| 7 | 12. searchSource 分组过滤 | P2 快赢 | 波次5 | 1-1.5 | 推荐零契约路线 |
| 8 | 10a. 定时服务应用内调度器 | P1 | 波次5 | 2-3 | FFI 已齐 |
| 9 | 9a. subContent + replaceRegex | P2 | 波次5 | 2-3 | 无（Rust 轨） |
| 10 | 3. 章节购买 payAction | P2 | 波次5 | 2-2.5 | **契约先行** |
| 11 | 8a. bridge.rs 步骤2 DEPRECATED 标注 | P2 | 波次5 穿插 | 0.5 | 无 |
| 12 | 9b. legado-server 正文 + dict 数据 | P2 | 波次5 | 1.5-2 | dict 数据源决策 |
| 13 | 6. MoreConfig 第②批（平台相关项） | P1 | 波次5 | 0.5-1 | 平台键位验证 |
| 14 | 11a. 缓存管理页 + 缓存下载 + EPUB | P2 | 波次6 | 7-10 | **契约先行** |
| 15 | 7. schema v102 对齐专项 | P2 触发型 | 波次6（条件触发） | 3-5 | 触发条件见 §4.2.1 |
| 16 | 11b. PDF 导出 + 模板/WebDAV | P2 | 波次6-7 | 4-7 | 选型决策 |
| 17 | 10b. 真后台执行 | P2 决策型 | 波次7+ | 3-5 | 插件引入决策 |
| 18 | 8b. bridge.rs 步骤3 物理移除 | P2 | 下一大版本节点 | 1-2 | 外部 C 消费者审计 |

**总量核算**：
- **核心必做（序 1-13）**：约 **15.5-21.5 人日**，双轨并行约 3-4 周
- **专项/决策项（序 14-18）**：约 **18-29 人日**，按触发条件与决策结果分批排入
- **全量上限**：约 **33.5-50.5 人日**

**里程碑建议**：
- **M4（波次4 完成，约第 2 周末）**：阅读器编辑闭环（保存/反转）、段落级朗读起点、语速跟随对齐、MoreConfig 第①批——阅读器二级功能全闭合，8 处 `TODO(留批次)` 清零过半
- **M5（波次5 完成，约第 4-5 周末）**：Rust P2 解析缺口闭合、定时调度器上线、9 项封装清零、payAction 接通——留项主清单（13 项）实质清零
- **M6（波次6-7，触发/决策驱动）**：缓存导出专项、schema v102 专项、后台执行——按触发条件滚动排期，不承诺固定时间盒

**执行纪律提醒**（对齐 TWO_TRACK_DEV_SPEC.md）：
1. 新增 FFI（留项 1/3/11）一律先在 API_CONTRACT.md 冻结契约再实施，`make gen` 原子生成
2. 每波次完成后回写台账 §5.9 销记 + 审计 §7.3 留项表 + docs/README.md 状态
3. 提交信息使用中文，Rust 轨与 UI 轨提交分离，并行会话改动区（如书源管理页）精确 add

---

**编写者**: Alex（research agent，Task #124）
**日期**: 2026-08-06
**证据基线**: 2026-08-06 工作区快照（批次0-3 闭合后，版本 2.0.3+5）；行号引用以该快照为准
