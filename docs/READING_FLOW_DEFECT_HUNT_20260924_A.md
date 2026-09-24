# 阅读主流程缺陷猎捕 —— 视角 A：Dart 侧状态机 / 生命周期（2026-09-24）

- 视角：**A（状态机 / 生命周期）**，猎捕模式（只找缺陷，不改生产代码）
- 范围：找书/开书/目录/读正文/换源/离线缓存/阅读设置/退出重进 的主流程 Dart 侧状态与生命周期
- 门禁：`flutter analyze` 全绿；`flutter test`（既有用例全绿，新增 7 个复现用例全红 —— 红即缺陷证据）
- 结论：**needs changes**（4 条主流程级 + 2 条边缘，均有红态复现或代码级证据）

---

## 1. 缺陷清单

| 编号 | 分级 | 一句话现象 | 触发路径（入口→操作） | 文件:行号 | 最小复现 | 证据（红态摘录） | 建议方向 |
|---|---|---|---|---|---|---|---|
| F1 | 【主流程重扰】 | `ReaderState.currentBook` 的进度字段（durChapterIndex/Pos/Title）**只要读就永不更新**；所有把它当权威快照的调用点都拿到「打开书那一刻」的进度 | 阅读器 → 连续翻章（任意入口）→（a）某章加载失败点「重试」（b）改书籍设置（替换规则/重新分段/图片样式）（c）开目录（d）自动换源 | `providers/reader/reader_notifier.dart:580-594`（`_saveProgress` 只写库不回写 state）、`:423-425`（`updateCurrentBook` 仅显式调用）<br>受害点：`widgets/reader/reader_page_view.dart:651-657`、`widgets/reader/reader_top_bar.dart:355-371`、`screens/reader_screen.dart:892-902`、`screens/reader_screen.dart:619-623` | `test/unit/reading_flow_state_machine_hunt_test.dart` → `[F1a] [F1b] [F1c]` | `[F1a] Expected: <2> Actual: <0>`；`[F1b] 重试把用户从第三章扔回第一章`；`[F1c] 送进 DB 的快照带的是打开时进度（0）` | 进度写入处同步回写 `state.currentBook` 的进度字段（或让消费点统一走 `currentChapterIndex`）；对 DB 的全行 `updateBook` 改用只改 readConfig 的单列/保留式更新 |
| F2 | 【主流程重扰】 | 连续翻章（连点/自动翻页叠加）时旧章的迟到正文覆盖新章正文 → **章标题是第 N 章、正文还是第 N-1 章**，且进度按第 N 章存库 | 阅读器章末连点两次「下一页」（首次点击已完成动画 → 已触发 `nextChapter`；冻结帧期间再点，章末判定用的仍是冻结的 pageIndex/pageCount → 再次触发）；**或** 开启自动翻页后每个 tick 都触发一次（网络慢于间隔时同样并发） | `providers/reader/reader_notifier.dart:193-204`（nextChapter 无 in-flight 守卫）、`:644-657`（`_loadChapterContent` 无序列守卫，无 currentBook/索引校验） | 同名文件 → `[F2]` | `Expected: 'CH2' Actual: 'CH1'`（`currentChapterIndex=2`，`chapterContent` 为第 1 章） | 加请求序号/世代守卫（仅最新一次加载可写 state），或加载前比对发起时的章节索引 |
| F4 | 【主流程重扰】 | 章级加载 `error` **粘滞**：任一次失败后，后续成功的章加载不清 `error` → 正文已就绪但阅读页永久停在全屏 ErrorView（目录选章也救不回来） | 阅读中一次网络抖动 → 章加载失败 → ErrorView → 点中心唤出菜单 →「目录」→ 选任意章（`goToChapter` 成功） | `providers/reader/reader_notifier.dart:644-657`（成功分支 `copyWith(chapterContent:)` 不清 error）、`:439-474`（刷新正文失败同样置 error）<br>消费点：`widgets/reader/reader_page_view.dart:643-668`（`error != null` 优先于正文渲染） | 同名文件 → `[F4]` | `Expected: null Actual: 'Bad state: 抓取失败：第 0 章'`，同时 `chapterContent` 已是 `CH1` | 成功的章加载清 `error`；「刷新正文」失败不要把整页降级为 ErrorView（保留旧正文 + 局部提示） |
| F3 | 【主流程重扰】 | 详情页「加书架/移出书架」写库失败仍报成功（`BookshelfNotifier` 吞异常正常返回，详情页无条件弹成功 + 翻本地状态） | 书架/搜索 → 点书进详情 → 点「加书架」（`addBook` 抛错时） | `providers/bookshelf/bookshelf_notifier.dart:118-126 / 147-157`（catch 后仅 `state.error`，不抛出）、`screens/book_info_screen_builders.part.dart:1711-1719`（加）/`:1703-1708`（移出） | `test/widget/reading_flow_shelf_false_success_hunt_test.dart` → `[F3]` | `Expected: no matching candidates / Actual: Found 1 widget with text "《测试书》已加入书架"`（同时 DB 写入抛 `StateError: DB 写入失败`） | Notifier 失败对调用方可感知（抛出或返回结果），详情页按结果分支提示；书架非空时也要呈现 `state.error` |
| F6 | 【边缘】 | `prevChapter` 的 `-1` 章内位置哨兵被**持久化写入 DB**（Rust 侧不钳制），语义依赖读取侧约定 | 阅读器 → 上一章 | `providers/reader/reader_notifier.dart:208-224`（置 -1 → `_saveProgress`；`resetChapterPos` 要等分页后才延迟调用） | 同名文件 → `[F6]` | `实测写入序列：[0, -1]` | 哨兵不要落库：保存前把 -1 归一（或改为「加载完成后按页数定位再保存」） |
| F5 | 【边缘】 | 「预载相邻章」对在线书是**空转**：走的是只返回 `{need_fetch:true}` JSON 桩的 `getChapterContent`（同仓另一处已改 `getChapterContentFull` 并注明该 API 会挂住） | 阅读器翻章（每章一次，命中 `_lastPreloadedIndex` 门）——该调用还发生在 `build()` 内 | `screens/reader_screen.dart:330-369`；对照 `widgets/reader/reader_page_view.dart:890-895` 注释与 `rust/legado-ffi/src/api/reader.rs:302-313` | 无测试（需 FFI 真机/集成环境；Dart 单测下 Mock 不暴露该语义） | 代码级：Rust 在线书分支直接 `Ok(json!({"chapter_url":..., "need_fetch": true}))`（reader.rs:312），不取网不写缓存；Dart 侧 `unawaited(getChapterContent(...).catchError(...))` 结果被丢弃 | 改为 `getChapterContentFull`（或删掉该重复预载，统一由 ReaderPageView 的预载承担） |

补充（同一 F1 根因的下游影响，未单列编号）：`screens/reader_screen.dart:892-902` 自动换源后 `openBook(updated)` 同样用陈旧 `durChapterIndex`，会把用户从书中间丢回开头；`screens/toc_screen.dart:515 / 647 / 763` 用传入 Book 的 `durChapterIndex` 做「当前章」高亮与定位（首开目录时会指向会话开始时的章节）。

---

## 2. 疑似（未复现）

| 编号 | 现象 | 缺什么证据 |
|---|---|---|
| S1 | 自动换源的 3 次上限守不住「失败→成功换源→再失败」循环：`_autoSwitchAttempts` 在换源成功后清零，而 `_autoSwitchBookUrl` 因 `bookUrl` 为稳定主键不变化 | 需要真机/集成 trace：同一本书连续触发 ≥4 轮 autoChangeSource 的日志（`[BookOpen]`/SnackBar 计数）。ReaderScreen 依赖路由与全局 provider 较多，widget 级复现成本高，未做 |
| S2 | 首页「最近阅读」卡进度滞留：`BookshelfNotifier.refreshBook` 只在 `bookshelf_screen._openBook` 两处接线；`home_tab_screen._openBook`（:411-430）与 `offline_cache_screen._openBook`（:262-291）从阅读器返回后不刷新该书 | 需要 widget/e2e：从首页卡进阅读器→翻章→返回，断言卡上进度文案变化。当前证据仅为代码路径比对（同仓 ⑫ P3 已在书架接线，说明问题类型成立） |
| S3 | 阅读器退出时的进度保存是 fire-and-forget 且失败完全静默：`PopScope.onPopInvokedWithResult → unawaited(notifier.saveProgress())`（`reader_screen.dart:409-415`），`_saveProgress` 内 `catch (_) {}`（`reader_notifier.dart:591-593`） | 需要「杀进程/网络写库失败」场景的实证。Dart 单测能证明吞异常，但无法证明「用户可见性」这一层面（是否必须有提示属口径判断），故不列为确定缺陷 |
| S4 | 阅读模式（`PageTurnMode.scroll`）从不写 `currentChapterPos`（无 `updatePosition` 调用），退出重进只能回到章首 | 需要产品口径确认「滚动模式是否要求章内位置恢复」；未找到规格文档明确要求 |

---

## 3. 检查过但未发现问题（供后续视角跳过）

- `reader_config_panel` 简繁转换 → `reloadChapterContent()`：Rust 侧「读取时净化」（`apply_content_processing_inner` 从 `current_chinese_convert_direction()` 取方向），缓存命中路径也会重放转换 → 配置变更确实生效（与 `reader_settings_sheet.dart` 注释一致）。
- 阅读设置（字号/行高/字重/字距/字体/边距/背景/翻页模式）：`_paginateIfNeeded` 缓存键覆盖面完整（含 content/sysPadding/pageChrome），字体族异步加载有 `mounted` 守卫。
- `reader_screen._reviewLoadSummary` 的 token 守卫、`_reviewCounts` 写入：完整（每次 `setState` 前校验 `mounted && token == _reviewLoadToken`）。
- `reader_screen` 的自动翻页定时器：`dispose` 取消 + 回调 `mounted` 校验；主题切换 `didChangeDependencies` 重建定时器；`_syncAutoTimer` 间隔 clamp(3,120)。
- `SearchNotifier`：`_searchSeq` 守卫覆盖流回调/onError/onDone/节流 flush；节流定时器在 search/loadNextPage/stop/clearResults 处取消并可被 seq 失效（`resetForOpen` 未显式取消但受 seq 守卫）。
- `ChangeSourceNotifier`：`_searchSeq` 守卫 + `isLoading`/`isApplying` 重入守卫；`change_source_screen._applySource` 有 `mounted` 校验与失败 SnackBar（换源主流程反馈闭环完整）。
- 单章换源 `change_chapter_source_sheet._applyChapter`：`_applying` 重入守卫 + fetch/getCachedChapter/兜底 + save + reload，失败有提示。
- `TocScreen`：`didPopNext` 刷新进度、`_debounce` 取消、TabController 释放；`_loadChapters` 从 `_handleMenu` 的异步路径进入时缺 `mounted` 守卫属窄路径，未列为确定缺陷（见下注）。
- `ReaderTurnView` / `PageTurnController`：快照缓存有 generation 守卫、位图 dispose 完整、手势冲突时以「后一次 turn 中断前一次」收敛（同章内连点表现为一次翻页，未构成错配）。
- `AudioNotifier`（TTS）：`_disposed` + `_playToken` 守卫 + `ref.onDispose` 取消 `_paragraphTimer` 与订阅。
- `ReaderPageView._refreshFontFamily` / `_preloadAdjacent`：异步后均有 `mounted` + 章节索引比对守卫。
- 离线缓存页 / 阅读记录页 / 欢迎页 的 `openBook` 调用：传参链无缺字段覆盖 DB 的问题（对比 P2-8 已修的 `originBookUrl` 类）。

> 注（未立项）：`toc_screen._loadChapters()` 入口 `setState` 无 `mounted` 守卫，`_handleMenu('splitLongChapter')` 的 `await _updateBook(...)` 之后调用它；若用户在写库期间退出本页则会 `setState() called after dispose()`。可达性窄（需 getBook/updateBook 抛错 + 立即退出），未做 widget 复现，故只登记。

---

## 4. 门禁与原始输出

### 4.1 `flutter analyze`（全绿）

```
cd flutter_legado && flutter analyze
Analyzing flutter_legado...
No issues found! (ran in 6.2s)
```

### 4.2 `flutter test`（全量）

```
cd flutter_legado && flutter test
00:40 +1643 -7: Some tests failed.

Failing tests:
  .../test/unit/reading_flow_state_machine_hunt_test.dart: F1 陈旧状态 / currentBook 进度快照 [F1a] ...
  .../test/unit/reading_flow_state_machine_hunt_test.dart: F1 陈旧状态 / currentBook 进度快照 [F1b] ...
  .../test/unit/reading_flow_state_machine_hunt_test.dart: F1 陈旧状态 / currentBook 进度快照 [F1c] ...
  .../test/unit/reading_flow_state_machine_hunt_test.dart: F2 章级加载竞态 [F2] ...
  ... and 3 more（F4 / F6 / widget [F3]）
```

口径说明（务必区分）：

- **既有测试全绿**：`+1643` 通过，失败项 7 条**全部**来自本次新增的两个复现文件
  （`reading_flow_state_machine_hunt_test.dart` 6 条 + `reading_flow_shelf_false_success_hunt_test.dart` 1 条）。
  单独复跑可核对：`flutter test test/unit/reading_flow_state_machine_hunt_test.dart` → `+0 -6`；
  `flutter test test/widget/reading_flow_shelf_false_success_hunt_test.dart` → `+0 -1`。
- **新增复现测试红（预期）**：红 = 缺陷复现证据，**未** skip、未删除、未改生产代码。
- 注意：由于命令经管道 `| tail`，shell 退出码为管道末端的退出码（0），**不代表测试通过**；
  以 Flutter 自身的 `Some tests failed` 行为准。

### 4.3 `git status --short`

```
?? docs/READING_FLOW_DEFECT_HUNT_20260924_A.md          （本报告，允许写的唯一 md）
?? docs/READING_FLOW_DEFECT_HUNT_PLAN_20260924.md      （他人计划的既有文件，未改动）
?? flutter_legado/test/unit/reading_flow_state_machine_hunt_test.dart
?? flutter_legado/test/widget/reading_flow_shelf_false_success_hunt_test.dart
```

无 modified/staged 项 ⇒ 未 commit、未 push、未改生产代码、未动 `docs/parity_shots/**`。

---

## 5. 状态与改动边界

- 未 commit / 未 push；未修改任何生产代码。
- 新增文件（仅测试与本报告）：
  - `flutter_legado/test/unit/reading_flow_state_machine_hunt_test.dart`（6 条，全红）
  - `flutter_legado/test/widget/reading_flow_shelf_false_success_hunt_test.dart`（1 条，红）
  - `docs/READING_FLOW_DEFECT_HUNT_20260924_A.md`（本文件）
- 未触碰 `docs/parity_shots/**`，未改动既有测试（无 skip、无删除）。

---

## 6. 遗留证据等级声明（non-claims）

- 本报告只证明「Dart 侧状态/生命周期在给定调用序下产生上述可观测结果（Mock API 级）」。
- F1 中「DB 进度被陈旧快照覆盖」的结论依据**代码级证据**（Rust `BookRepository::update` 为 37 列全行 UPDATE，
  `rust/legado-db/src/repository/book_repository.rs:503-520` 含 `durChapterIndex=?21/durChapterPos=?24/durChapterTitle=?20`；
  同仓 P2-1 注释已把该模式登记为「丢更新窗口」），未做真机/端到端 DB 断面验证。
- 未覆盖：iOS/Android 真机行为、Rust 侧并发写库时序、多进程/自动任务并发场景。

