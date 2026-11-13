# 路 3 · Flutter UI 完整性审查报告（2026-11-13）

> 审查基线：HEAD `e26916c098`（版本 2.0.497+498）
> 审查对象：`flutter_legado/lib/`（Dart UI / providers / widgets / screens）
> 对照基线：`legado-with-MD3`（视觉与行为基准）、`legado-upstream`（上游）、本仓 `app/`（原版 Kotlin）
> 性质：**只读审查**。未修改任何业务代码，未提交。
> 编写：代码审核员（子代理）｜ 2026-11-13

---

## 一、摘要

### 1.1 范围与方法

本次按任务书要求，聚焦六条维度：

1. 状态管理正确性（Riverpod notifier / 派生状态 / 异步竞态 / 列表 identity）
2. UI 层职责边界（screens、widgets 是否承担应下沉 Rust/Bridge 的判断、解析、计算）
3. 错误处理与用户可见反馈（静默 catch、假成功、Loading 永挂、空态缺失、错误文案泄漏）
4. 布局健壮性（滚动容器、Row 溢出、键盘遮挡、textScaler、深色硬编码色）
5. 资源与性能（Controller/Timer 未释放、非 builder 列表、图片缓存、setState 高频）
6. 导航与返回栈（PopScope/canPop 语义、重复 push、返回后状态恢复）

方法：

- **全量结构扫描**：`lib/src` 下 357 个 Dart 文件（providers 100 + screens 129 + widgets 128）全部纳入 grep/AST 级模式扫描（脚本见 §五「方法可复现」）。
- **定向深读**：对 providers 全部 notifier 的 `build()`、状态写入口、异步分支逐段阅读；对 `reader_screen` / `bookshelf_screen` / `book_info_screen*` / `search_screen*` / `reader_comic_screen` / `video_screen` / `webdav_settings_screen` / `archive_import_dialog` / `import_screen` / `privacy_*` / `read_record_*` / `rss_*` / `theme_*` 关键函数逐行阅读。
- **交叉对照**：每条「与参考版有差异」的结论都给出 `legado-with-MD3` 文件:行号；无法判定谁对者单列「需用户裁决」。
- **反向验证**：所有「未接线 / 死代码 / 不生效」结论都用全仓裸名重搜（含 `lib/app.dart`、`lib/main.dart`，避免只搜 `lib/src` 的假阴性）。

### 1.2 覆盖面声明

| 目录 | 规模 | 本次覆盖 |
|---|---|---|
| `lib/src/providers/**` | 100 个 .dart（20,773 行，不含 freezed） | **全扫**：51 个 notifier 的 `build()` 与状态写入口逐段阅读；全部 `state = ...` 点做 grep 级核对；13 个中等体量 notifier 通读 |
| `lib/src/screens/**` | 129 个 .dart（77,604 行） | **结构全扫 + 重点深读**：错误处理、PopScope、Controller 生命周期、定时器、异步上下文为脚本全扫；`reader_screen`、`bookshelf_screen`（约 40%）、`book_info_screen*`、`search_screen*`、`webdav_settings_screen`、`archive_import_dialog`、`import_screen`、`read_record*`、`privacy_settings_screen`、`reader_comic_screen`（约 30%）深读；其余按模式命中点定点阅读 |
| `lib/src/widgets/**` | 128 个 .dart（48,479 行） | **结构全扫 + 抽样深读**：`privacy/*`、`reader/reader_page_view`、`reader/reader_top_bar`、`navigation/*`、`bottom_sheet_widget`、`book_cover`、`explore_source_content`、`md3_heatmap_calendar` 深读；`paragraph_layout_engine`（1,886 行）与 `page_flip_widget` 仅做接口与资源核对，未逐行审 |
| `lib/app.dart` / `main.dart` | 2 个文件 | 主题装配、`textScaler` 覆盖、隐私闸门挂载、调度器释放逐段核对 |
| 测试 | `flutter_legado/test/**` | 未逐条审；仅用其断言口径反查若干行为（如 `reader_review_summary_test`） |

**明确未深入**：`theme_config_screen.dart`（3,194 行）的视觉细节、`reader_comic_screen` 的图片解码器实现细节、`rss_article_detail_screen`（1,811 行）的 WebView 细节、`video_screen` 的弹幕层实现、`paragraph_layout_engine` 的排版算法本身。这些区域只覆盖了资源/错误/导航三类模式，未做逐行语义审查。

### 1.3 总体结论

**Flutter UI 轨的状态管理与隐私/返回键等高风险面质量显著高于一般项目**：freezed 状态写入口干净（无 in-place 变更、无 `state = state` 空写、`copyWith(field: null)` 清空语义正确）、build 期无同步状态写、返回键状态机与隐私闸门均为 fail-closed 且注释可追溯、键盘遮挡与 textScaler 覆盖到位。

本次未发现 P0（崩溃 / 数据丢失 / 主流程不可用）。发现 **1 条 P1**：压缩包批量导入把失败计数成「成功导入」，属于本项目最忌讳的「假成功」；另有 **8 条 P2**、**10 条 P3**。

缺陷计数：

| 等级 | 数量 |
|---|---|
| P0 | **0** |
| P1 | **1** |
| P2 | **8** |
| P3 | **10** |

---

## 二、缺陷清单

### P1（1 条）

#### P1-1 压缩包导入把「失败」计入「成功导入 N 本」——假成功 + 静默丢书

- **等级**：P1（功能错误 / 静默失败）
- **文件:行号**：
  - `flutter_legado/lib/src/screens/archive_import_dialog.dart:320-328`（逐本导入的 try/catch 与计数）
  - `flutter_legado/lib/src/screens/archive_import_dialog.dart:335-337`（结果 Toast）
- **问题**：循环体内 `await notifier.importLocalBook(filePath)` 抛出的异常被 `catch (_) {}` 吞掉（:322-324），但 `setState(() => _importDone++)`（:327）在 try/catch **之外**，无论成功失败都会自增；最终提示固定为 `'成功导入 $_importDone 本书籍'`（:336）。`_importDone` 统计的是「尝试数」而不是「成功数」。
- **触发路径与用户可见后果**：
  1. 书架「导入」→ 选择 zip/rar/7z 压缩包（含 N 本书）；
  2. 其中任一本因文件损坏 / 无读权限 / 同名书主键冲突 / DB 写入失败等原因让 `importLocalBook` 抛 `BridgeError`；
  3. 解压成功 → 进入逐本导入 → 失败异常被吞 → 仍然 `_importDone++`；
  4. 用户看到「**成功导入 10 本书籍**」，但书架只有 7 本，且**没有任何失败提示、没有失败书名**。用户无从知道哪 3 本没进来，也不会重试。
- **对照证据（同类实现均正确）**：
  - `screens/import_screen.dart:232-240`：逐本 `try/catch` 记录 `_ImportOutcome(success:false, error:...)`，结果页分别给出成功/失败/跳过数；
  - `screens/bookshelf_screen.dart:2753-2775`：`successCount` 与 `failures` 分开统计，Toast 形如「已导入 X 本；导入失败：书名：原因…」；
  - `screens/cover_album_manage_screen.dart:432-442`：`imported` / `duplicates` / `failures` 三路分开。
  三条同类路径都做到了「不假装成功」，只有压缩包导入这条漏了。
- **建议修法**：
  - 把 `_importDone++` 移入 try 的成功分支，另设 `_importFailed`/`List<String> _failures`；
  - 结果 Toast 改为「成功导入 X 本，Y 本失败：<首个失败名+原因>」；
  - 失败项保留在 `outputDir` 时给出可定位提示（或按项目约定清理）；
  - 补一条 widget 测试：注入 `importLocalBook` 抛错，断言提示不含「成功导入 N」且含失败计数。

---

### P2（8 条）

#### P2-1 段评摘要去重键在「成功前」就被消费，同章失败/竞态后永久不再加载（批25 修复的回修不彻底）

- **等级**：P2（功能错误 / 静默失败）
- **文件:行号**：
  - `flutter_legado/lib/src/screens/reader_screen.dart:186`（`String? _reviewLoadedKey`）
  - `flutter_legado/lib/src/screens/reader_screen.dart:865-866`（`if (key == _reviewLoadedKey) return; _reviewLoadedKey = key;`）
  - `flutter_legado/lib/src/screens/reader_screen.dart:873-889`（postFrame 复核，条件不满足直接 `return`）
  - `flutter_legado/lib/src/screens/reader_screen.dart:800-808`（`_loadReviewSummary` 的 catch 只清徽标、不清键）
  - `flutter_legado/lib/src/screens/reader_screen.dart:717`（`_loadReviewSummary` 起点）
- **问题**：`_maybeLoadReviewSummary` 在 build 期先无条件占位 `_reviewLoadedKey = key`，然后才在 postFrame 里复核 `current.isLoading / error / key 一致`。任何一次「键已占用但请求没发出去」或「请求发出但失败」都会让该章永久处于「已加载」假象：
  - 分支 A：postFrame 复核时 `current.isLoading == true`（例如同帧内触发了翻章恢复/刷新）→ 直接 return，键已占用，正文加载完成后 build 再跑也只会命中 `key == _reviewLoadedKey` 提前返回；
  - 分支 B：`reviewGetSummary` 抛错（弱网/书源超时/`ruleReview` 解析异常）→ catch 清空 `_reviewCounts/_reviewKeys/_reviewSourceJson`，但 `_reviewLoadedKey` 保留 → 同章不再重试。
- **触发路径与用户可见后果**：弱网下打开一本书 → 段评摘要请求失败 → 正文**没有段落段评徽标**、长按/点击段落**打不开段评面板**；切到下一章再切回来才恢复（新章 key 不同）。这与批25 刚修掉的「段评面板不可达」是同一类用户症状，只是触发条件从「从不加载」缩窄为「一次失败后不重试」。
- **建议修法**：
  - 把 `_reviewLoadedKey = key` 移到**请求成功**之后（成功路径 `setState` 处一并赋值）；
  - postFrame 复核不通过时显式 `_reviewLoadedKey = null`；
  - catch 分支同样重置 `_reviewLoadedKey = null`（并考虑失败计数上限，避免弱网无限重试）；
  - `reader_review_summary_test.dart` 增加「首次请求失败 → 下一次 build 会重试」用例。

#### P2-2 语言切换只覆盖约 85 条字符串，选 English 后界面中英混杂

- **等级**：P2（功能错误 / 半实现）
- **文件:行号**：
  - `flutter_legado/lib/src/l10n/app_strings.dart:2-6`（`_locale` + `_get(zh, en)`；文件内共 **161** 个 `static String get`）
  - `flutter_legado/lib/src/screens/other_settings_screen.dart:274-281`（「语言」入口）
  - `flutter_legado/lib/src/screens/other_settings_screen.dart:1191-1216`（`system / zh / en` 三选一并持久化 `app_locale`）
- **问题**：设置页提供「简体中文 / English / 跟随系统」，切换立即生效于 `AppStrings`；但 `screens/` + `widgets/` 中仍有 **约 1,600 处 `Text('中文…')` 硬编码、约 5,000 条含中文的字符串字面量（grep 统计，含调试文案）**，`AppStrings.` 仅 **85** 处引用（161 个 getter 中大量未被 UI 使用）。选 English 后只有底部导航/少量按钮变英文，其余全部中文。
- **触发路径与用户可见后果**：其他设置 → 语言 → English → 立即返回：底部导航「Bookshelf/Search/Settings」等少数文案变英文，书架、详情、阅读器菜单、设置项、对话框仍全中文；重启后依旧。用户会认为语言设置「坏了」。
- **对照证据**：参考版 `legado-with-MD3` 使用完整 Android 资源本地化（`app/src/main/res/values-en/strings.xml`），不存在半覆盖形态。
- **建议修法（三选一，建议提交用户裁决）**：
  1. 短期：`en` 选项置灰并标注「暂未完成」/从选择器移除，只保留「跟随系统/简体中文」；
  2. 中期：把 `AppStrings` 扩到覆盖 `screens/` 全部可见文案（工程量大，需分批）；
  3. 或登记为已知差异并在选择器内明示「部分界面仍为中文」。

#### P2-3 私密书「改名」后，阅读记录 / 书签的脱敏反查失效，原书名明文显示

- **等级**：P2（隐私脱敏被绕过；非参考版行为，需裁决修法）
- **文件:行号**：
  - `flutter_legado/lib/src/screens/edit_book_info_screen.dart:212-217`（编辑书籍信息直接 `book.copyWith(name: ..., author: ...)` 并 `updateBook`，改写 `books.name/author`）
  - `rust/legado-ffi/src/api/bookshelf.rs:156-163` → `rust/legado-db/src/repository/book_repository.rs:790-819`（`UPDATE books SET name=?4, author=?5 ...`，**无 readRecord/bookmark 级联**）
  - `flutter_legado/lib/src/providers/read_record/read_record_notifier.dart:197-210`（`ReadRecordShow.bookName` = `displayBookName`，`physicalBookName` = 该行的 `book_name`，即**写入当时**的书名；`with_display_metadata` 在未编辑时 `displayBookName = bookName`，见 `rust/legado-db/src/repository/read_record_repository.rs:103-127`）
  - `flutter_legado/lib/src/services/privacy_content_service.dart:185-190`（反查表以**当前** `book.name + book.author` 为键）
  - `flutter_legado/lib/src/services/privacy_content_service.dart:110-121`（`findBookByNameAuthor`：精确键不命中且作者非空 → 返回 null → 判非私密）
  - `flutter_legado/lib/src/screens/read_record_screen.dart:248-254`（列表脱敏只用 `physicalBookName ?? bookName` 反查）
  - `flutter_legado/lib/src/screens/bookmark_screen.dart:123`（书签侧以 `bookName + bookAuthor` 反查）
- **问题**：脱敏判定依赖「书名+作者」反查书籍的 `isPrivate`。改名后 `books.name` 变了，而 `readRecord/bookmark` 行仍持有旧名：列表侧用旧名反查 → 落空 → fail-open（不脱敏），把**旧书名**原样显示。同一文件 `_confirmDelete`（`read_record_screen.dart:328-340`）已经补了「物理名 + 显示名两次反查」的兜底，但**列表渲染路径没有补**，形成「删除确认脱敏、列表本身不脱敏」的不一致。
- **触发路径与用户可见后果**：
  1. 把一本书设为私密（单本或分组），并读过若干章（产生 readRecord 行）/加过书签；
  2. 详情页 ⋮ → 编辑书籍信息 → 修改书名（或作者）→ 保存；
  3. 打开「阅读记录」/「书签」：该书旧记录/旧书签**直接显示旧书名、作者、时长、章节名、真实封面**，无锁定/脱敏；
  4. 点这条记录：`_openRecord`（`read_record_screen.dart:291-309`）用 `physicalBookName`（旧名）调 `findBookByName`（`read_record_notifier.dart:156-162`，按 `b.name ==` 精确匹配）→ 找不到 → 跳转全局搜索并**把旧书名作为关键词**填入并提交（`arguments: item.bookName`）→ 旧书名进入对第三方书源的网络搜索请求。
- **参考版证据**：`legado-with-MD3` 的 `ui/book/readRecord/*` 与 `ui/book/bookmark/*` **没有**私密脱敏逻辑（未实现该能力），因此这不是「参考版也要做」的回归，而是我方自建能力的边界缺口。修法需裁决（见 §三）。
- **建议修法（候选）**：
  1. 根治：`readRecord` / `bookmark` 落库时附带 `bookUrl`（或书籍 id），脱敏走 URL 判定；需 Rust schema + 备份链配合；
  2. 过渡：`updateBook` 改名时级联 UPDATE 旧记录/书签（Rust 侧事务），保证反查键一致；
  3. 兜底：反查失败时按「同名唯一」放宽，或对 `markersUnavailable/反查未命中` 显式标注「标记不可用」（当前是静默 fail-open）。

#### P2-4 用户可见错误文案直接插值原始异常：`BridgeError` 无 `toString()`，用户看到「Instance of 'BridgeError'」

- **等级**：P2（错误反馈失效 / 泄漏内部细节）
- **文件:行号**（代表性站点，均已核实异常可为 `BridgeError` 或 FFI 错误）：
  - `screens/bookshelf_manage_screen.dart:609`（删除书 `deleteBook`）
  - `screens/book_group_screen.dart:212 / 236 / 246 / 265 / 593`（分组增删改/排序/分配）
  - `screens/bookshelf_screen.dart:3285`（`httpGet` 拉书单）
  - `screens/rss_source_manage_screen.dart:701 / 761 / 790 / 867 / 900 / 928 / 957 / 996`
  - `screens/other_settings_screen.dart:690 / 722 / 913 / 941 / 962 / 1002`
  - `screens/book_info_screen_builders.part.dart:313 / 1830 / 2053 / 2080 / 2367`
  - `screens/archive_import_dialog.dart:234 / 343`、`screens/app_log_screen.dart:109`、`screens/about_screen.dart:97 / 183 / 224`
  - `screens/bottom_bar_skin_screen.dart:204 / 301 / 341`、`screens/bottom_bar_skin_assign_screen.dart:148`
  - `screens/audio_screen.dart:1282`、`screens/js_source_edit_screen.dart:155 / 241`、`screens/offline_cache_screen.dart:187 / 200`、`screens/read_aloud_settings_screen.dart:297`
- **问题**：`BridgeError` 仅持有 `message`，**未重写 `toString()`**（`flutter_legado/lib/src/bridge/ffi.dart:16-31`），默认 `toString()` 为 `Instance of 'BridgeError'`。上述站点用 `'…：$e'` 直接拼接到 SnackBar/Toast，等于把有效错误信息替换成类型名。
- **触发路径与用户可见后果**：任意一次 FFI 写失败（DB 锁、源不存在、权限、书不存在…）→ Toast 显示「删除失败: Instance of 'BridgeError'」/「导入失败: Instance of 'BridgeError'」。用户无法据此判断原因，也无法自助修复。
- **项目内已有正确做法**：
  - `lib/src/utils/error_message.dart:55-59`（`errorMessage()`：剥离 `FFI error:`/`Network error:` 前缀并映射用户可读文案）；
  - `screens/bookshelf_screen.dart:517`（`e is BridgeError ? e.message : '$e'`）；
  - `screens/reader_comic_screen.dart:1205` 的注释已明确记录该坑（「BridgeError 无自定义 toString()，裸显会显示 "Instance of 'BridgeError'"」）。
- **建议修法**：把上述站点统一改为 `errorMessage(e)`（需要技术细节的面板可另用 `errorDetailMessage(e)`）；建议加一条 lint 级约定：`Text('…$e')` 在 `screens/` 禁止，或在 PR 检查里 grep `失败：\$e`。

#### P2-5 书架点击书籍无重入保护：等待书源匹配期间双击会压入两个阅读器/详情页

- **等级**：P2（导航错误 / 重复 push）
- **文件:行号**：
  - `flutter_legado/lib/src/screens/bookshelf_screen.dart:2580`（`_openBook` 起点）
  - `.../bookshelf_screen.dart:2606`（`await api.getBookSources()`）
  - `.../bookshelf_screen.dart:2622`（`await BookOpenUtils.refreshShowMangaUi()`）
  - `.../bookshelf_screen.dart:2637-2645`（`rootNavigator.pushNamed(route)`）
  - 同类：`flutter_legado/lib/src/utils/book_open_utils.dart:375-425`（`openBook` 内 `await getBookSources` / `await refreshShowMangaUi` 后 push，无 in-flight 锁）
- **问题**：`_openBook` 在 push 之前有两段 `await`（书源列表查询 + 漫画开关镜像刷新），期间没有任何 `_opening`/`Future` 去重。第二次点击会并行走完同样流程并再次 `pushNamed`。
- **触发路径与用户可见后果**：弱网/书源多（`getBookSources` 慢）时双击一本已读的在线书 → 打开阅读器 A，紧接着又 push 阅读器 B（`ReaderNotifier.openBook` 被调用两次，第二次覆盖状态）。用户按返回键时「退不出去」——回到的是另一个阅读器；随后章节加载可能错乱。
- **建议修法**：在 `_BookshelfScreenState` 增加 `bool _openingBook` / `String? _openingUrl` 守卫（`try/finally` 复位），或把去重下沉到 `BookOpenUtils.openBook`（static in-flight set，按 `bookUrl` 去重），两处入口（书架/发现/搜索）一起受益。

#### P2-6 WebDAV「同步书库（合并）」进度文案写成「恢复中…」，与动作方向相反

- **等级**：P2（误导性反馈）
- **文件:行号**：`flutter_legado/lib/src/screens/webdav_settings_screen.dart:606`（`_runWithProgress('恢复中…', ...)`，位于 `_doSyncLibrary`）
- **问题**：该动作经 `SyncNotifier.restoreFromWebDav` 实现，语义是「**上传本地书架覆盖远端 bookshelf.json**，再只回写远端书源」（见 `providers/sync/sync_notifier.dart:288-316` 与确认文案 `webdav_settings_screen.dart:534-553`）。进度条却写「恢复中…」；同文件其余三处「恢复中…」确实是恢复（:725/:913/:1107），只有这一处是上传。
- **触发路径与用户可见后果**：顶栏 ⋮ →「同步书库（合并）」→ 确认 → 进度提示「恢复中…」→ 用户以为正在把远端备份拉到本地（覆盖本地），实际是反方向。若此时强杀/断网，用户对「本地是否被覆盖」的认知是错的。
- **建议修法**：文案改为「同步中…（上传本地书架）」或按动作起两个不同标签；顺带把确认框里的「恢复/同步」术语与图标统一。

#### P2-7 远程书库批量导入：部分失败被静默，仍提示「成功导入 N 本」

- **等级**：P2（静默失败）
- **文件:行号**：
  - `flutter_legado/lib/src/providers/remote_book/remote_book_notifier.dart:466-471`：`error: ok == 0 ? (lastErr ?? '导入失败') : null`（部分失败时 `error` 被清空），`clearError: ok > 0`
  - `flutter_legado/lib/src/screens/remote_book_screen.dart:53-61`：只有 `count == 0` 才显示错误，否则固定「成功导入 $count 本」
- **问题**：逐本下载/导入循环里失败只记录 `lastErr`，循环结束若 `ok > 0` 就整体当成功；失败数量与文件名全部丢弃。
- **触发路径与用户可见后果**：远程书库勾选 5 本导入，2 本下载 404/权限失败 → Toast「成功导入 3 本」，**没有任何失败提示**。用户以为 5 本都在，缺的 2 本无感知、无重试入口。
- **对照证据**：参考版 `legado-with-MD3` `ui/book/import/remote/RemoteBookViewModel.kt:279-303` 用 `forEach` + 单一 `try`，任一失败直接整体报「导入出错」并 toast。参考版是「全有或全无」，我方是「部分成功但不说」——两种都不理想，但至少参考版不会让用户误以为全成功。
- **建议修法**：仿 `import_screen` 的三态统计，返回 `(ok, failures)`，Toast 形如「成功 3 本，失败 2 本（首个原因）」，并在列表行上标记失败项。

#### P2-8 自动任务批量导入：写入失败被静默，提示只统计成功数

- **等级**：P2（静默失败）
- **文件:行号**：`flutter_legado/lib/src/screens/auto_task_screen.dart:815-829`
- **问题**：`try { await notifier.createTaskRaw(...); count++; } catch (_) { /* 单条失败不阻断整体导入 */ }`；结果提示 `errors.isEmpty ? '已导入 $count 个任务' : '已导入 $count 个任务，跳过 ${errors.length} 个无效任务'`。其中 `errors` 是**解析阶段**收集的「无效任务」，与写入阶段的失败不是同一集合。
- **触发路径与用户可见后果**：从文件/扫码导入 6 个任务，2 个因 DB 写入失败（重名主键、字段超限）未落库 → Toast 只写「已导入 4 个任务」，**不提 2 个失败**；`errors` 为空时连「跳过」都不出现。用户在任务列表看不到那 2 条，无从判断是导入失败还是被解析丢弃。
- **建议修法**：写入失败单独收集 `writeFailures` 并在文案中区分「无效 N 个 / 写入失败 M 个（首个原因）」。

---

### P3（10 条）

#### P3-1 9 个页面的 `ScrollController` 从未 `dispose`

- **等级**：P3（资源卫生）
- **文件:行号**（脚本全扫 + 逐文件人工确认 `dispose()` 体内确实没有对应释放）：
  - `screens/bookmark_screen.dart:27`（`_fsController`，dispose 只释放 `_searchController`）
  - `screens/bookshelf_manage_screen.dart:38`（`_fsController`）
  - `screens/explore_screen.dart:58`（`_listController`，dispose 只 cancel `_debounceTimer` + `_searchController`）
  - `screens/highlight_rules_screen.dart:60`（`_fsController`）
  - `screens/read_record_screen.dart:42`（`_listController`）
  - `screens/replace_rules_screen.dart:52`（`_ruleListController`）
  - `screens/rss_source_manage_screen.dart:62`（`_fsController`）
  - `screens/search_content_screen.dart:123`（`_fsController`）
  - `screens/txt_toc_rules_screen.dart:36`（`_fsController`，**整个 State 无 dispose**）
- **问题**：`ScrollController` 持有 `ScrollPosition` 监听链；不 dispose 时每次进出页面积累一个 detached 控制器。功能上不会立刻可见，但会在 devtools 内存快照里持续增长，且与 `Md3FastScroller` 共享控制器时可能残留监听。
- **建议修法**：在各 `dispose()` 里补 `.dispose()`（`txt_toc_rules_screen` 需新增 `dispose` 覆写）。可顺手加一条测试基线（widget 测试 teardown 断言无未释放 controller）。

#### P3-2 `SearchNotifier` 无 `onDispose`：节流 `Timer` 与流订阅不随 provider 销毁取消

- **等级**：P3（潜在风险；当前 provider 全局常驻，实际影响低）
- **文件:行号**：`providers/search/search_notifier.dart:82`（`Timer? _resultsFlushTimer`）、`:259`（`_attachSearchStream` 赋值 `_searchSub`）、`:791-793`（provider 声明，无 `ref.onDispose`）
- **问题**：`searchNotifierProvider` 是普通 `NotifierProvider`（非 autoDispose），进程内不会销毁，所以当前不会触发「dispose 后写 state」。但 `_resultsFlushTimer` 回调里直接写 `state`（`_flushResults`），一旦未来改成 `autoDispose` 或加作用域容器（测试、多实例），定时器会在销毁后写 state。
- **建议修法**：在 `build()` 里加 `ref.onDispose(() { _resultsFlushTimer?.cancel(); _searchSub?.cancel(); });`，为后续改造留安全边界。

#### P3-3 死状态 / 死开关：加载并持久化、但全仓无消费者

- **等级**：P3（「看起来实现了但没生效」）
- **证据**：
  1. `providers/ui_settings/ui_settings_notifier.dart:250 / 253`（字段 `readMenuBrightnessVertical` / `readMenuBrightnessPos`）、`:308-309`（默认值）、`:359-360 / 424-427`（copyWith）、`:632-637`（加载）、`:915-928`（两个 setter）——全仓 `grep readMenuBrightness` 仅命中以上位置，**UI 无入口、无渲染消费者**，setter 无调用方。名字对应上游的「亮度条竖排/位置切换」（`legado-upstream/.../read/ReadMenu.kt:518-521`：`AppConfig.brightnessVwPos = !…`）；参考版 `legado-with-MD3` 无此控件，Flutter 移植也未实现，因此这两个键属于**预留但未接线的死设置**。
  2. `providers/sync/sync_state.dart:25`（`autoSync`）、`providers/sync/sync_notifier.dart:131`（加载）、`:142-146`（`toggleAutoSync`）——`toggleAutoSync` 全仓零调用、`getAutoSync()` 除 `loadConfig` 外零消费、无自动同步调度器（`services/` 下只有 auto_backup / auto_check_new_backup / auto_refresh_book / auto_task 四个调度器）。即「自动同步」开关在 UI 与执行链两头都缺失，只留下状态字段。
  3. 其余「仅定义、全仓零调用」的公开方法（脚本核对，排除 tear-off 误报）：
     `main_prefs_notifier.setShowHome / setShowDiscovery / setShowRss`（已被 `setTabVisible` 取代）、
     `source_notifier.exportAllSources`、`rss_notifier.importDefaultSources`、`association_notifier.setUrlInput`、
     `auto_task_notifier.canRefreshBookToc`、`explore_show_notifier.retryPreviousPage`（纯转调）、
     `audio_notifier.debugSyncMediaSession`、`sync_notifier.applyLegacyWebDavPrefsAfterRestore`（已被 `webdav_restore_service.dart:372` 直接调用取代）、
     `services/settings_service.dart` 的 `getBookshelfShowTag`（同一偏好键已由 `models/bookshelf_settings.dart:25 / 517` 消费，书架页读的是后者，见 `bookshelf_screen.dart:2155`）。
- **建议修法**：删除 `readMenuBrightness*` 与 `autoSync` 死链（连同 PrefKeys 常量），或在 ACTIVE_PLAN 登记「待接线」；其余方法按「无入口即删」清理，避免下一轮审计再次误判为「已实现」。

#### P3-4 `read_record_daily_view` 组日期时 `int.parse` 无保护（同源数据的另一处有 try/catch）

- **等级**：P3（防御性；当前数据源格式受 Rust 保证）
- **文件:行号**：`screens/read_record_daily_view.dart:92-101`
- **问题**：`final parts = date.split('-'); if (parts.length != 3) continue;` 之后直接 `int.parse(parts[0..2])`。若 `date` 形如 `2026-11-13T00:00:00`（仍 split 出 3 段）或含非数字（历史脏数据/手工改库/异常备份），`int.parse` 抛 `FormatException`，且该调用位于 `build`（`groupDailyByDay` 由 `build` 调用），**直接影响阅读记录页「按天」视图渲染**。
- **对照**：同一份 `readRecordDailyList` 数据在 `screens/read_record_screen.dart:580-590` 是包在 `try { ... } catch (e) { setState(_error=...) }` 里的，异常会降级为「每日时长加载失败」，不会崩页面。
- **建议修法**：抽一个共享的 `parseDailyDate(String) -> DateTime?`（try/catch + `DateTime.tryParse` 兜底），两处共用。

#### P3-5 `video_screen` / `reader_comic_screen` 异步分支 `setState` 缺 `mounted` 检查

- **等级**：P3（debug 断言 / release 静默丢帧）
- **文件:行号**：
  - `screens/video_screen.dart:447-500`（`_loadBookVideo`：`await api.getChapters` / `await api.refreshToc` 之后 `:470-473` 直接 `setState`，无 `mounted`）
  - `screens/video_screen.dart:553-600`（`_playChapter`：`:588` 前有 `mounted` 检查，但 `:563-565`、`:578-581` 的早期失败分支无）
  - `screens/reader_comic_screen.dart:1133-1215`（`_loadBook`：`:1146-1152`、`:1180-1184`、`:1209-1211` 直接 `setState`，仅外层 `catch` 有 `mounted`）
- **触发路径与用户可见后果**：进入视频书/漫画书 → 目录/正文抓取较慢（弱网 5–10s）→ 用户返回 → 迟到回调 `setState`：debug/设备验收包抛 `setState() called after dispose()`；release 下 `markNeedsBuild` 因 element 非 active 静默返回（不崩，但属于未处理生命周期）。
- **建议修法**：统一在每个 `setState` 前补 `if (!mounted) return;`（或改 `if (mounted) setState(...)`），与同文件其它分支保持一致。

#### P3-6 详情页传入空 `bookUrl` 且无 `Book` 参数时，永久 Loading，无错误/空态

- **等级**：P3（边缘；路由参数异常/深链才可达）
- **文件:行号**：
  - `screens/book_info_screen.dart:165`（`_pageLoading = widget.book == null && widget.effectiveBookUrl.isEmpty`）
  - `screens/book_info_screen_load.part.dart:63-110`（`url.isEmpty` → `dbBook=null`、`book=null` → `:110 _pageLoading = book == null` 保持 true）
  - `screens/book_info_screen_load.part.dart:287-292`（`else if (mounted)` 只清 `_tocLoading/_networkLoading`，不清 `_pageLoading`；`:340` 的 `_pageLoading=false` 只在 `catch` 分支）
  - `screens/book_info_screen.dart:556`（`body: _pageLoading || privacyPending ? 加载态 : 内容`）
- **问题**：`_loadData` 没有任何「book 为空」的终态分支；`_loadError` 只在 `catch` 里赋值。
- **触发路径与用户可见后果**：`/book_info` 路由被以空参数（`BookInfoScreen(bookUrl: '')`）打开（深链/外部 intent 参数缺失/旧调用方兼容路径）→ 页面永远转圈，用户只能返回。
- **建议修法**：`_loadData` 开头 `if (url.isEmpty && widget.book == null)` 直接 `setState(_pageLoading=false, _loadError='缺少书籍参数')`，或渲染空态。

#### P3-7 书架打开书时书源查询失败被静默吞，可能用错阅读器（文本/漫画/音频）

- **等级**：P3（边缘降级）
- **文件:行号**：
  - `screens/bookshelf_screen.dart:2599-2618`（`try { getBookSources() ... } catch (_) {}`，`typeBits` 保持原值）
  - 同类：`utils/book_open_utils.dart:395-410`（`catch (_) { // 书源匹配失败按书籍已有类型位继续 }`）
- **问题**：书籍的漫画/音频/视频「类型位」由书源规则补全；查询失败时沿用书籍已有 `bookType`（可能是旧值或 0）。
- **触发路径与用户可见后果**：多书源/DB 瞬时锁定时点开一本漫画书 → `getBookSources` 失败 → `typeBits` 未补 → 进**文本阅读器**（看到 `<img>` 标签或错误页），而正确行为是进漫画阅读器。无提示，用户只会认为「书坏了」。
- **建议修法**：失败时不要静默——至少 `debugPrint` + AppLog，并在 UI 层对该次打开给出「书源信息读取失败，已按默认方式打开」的轻提示；或重试一次。

#### P3-8 UI 层承担书源正则匹配（应下沉 Rust），且与 Rust 实现存在双份语义

- **等级**：P3（职责边界 / 未来漂移风险）
- **文件:行号**：
  - `screens/bookshelf_screen.dart:3196-3215`（`_matchSource`：Dart `RegExp(s.bookUrlPattern).hasMatch(url)` + host 兜底）
  - `utils/book_open_utils.dart:395-410`（同语义的第三份实现）
  - Rust 侧已有同一判定：`rust/legado-fetcher/src/web_book.rs:4296`（`pub fn matches_book_url_pattern`，含非法正则兜底测试 `:7333`）
- **问题**：`bookUrlPattern` 的匹配语义在 Rust 已有单一真源并带测试，但该函数未暴露 FFI；Dart 侧因此自行实现两份（书架「添加网址」、开书类型补全）。Dart `RegExp` 与 Rust `regex` 在部分语法（lookaround、`\p{...}`、命名组）上不等价，会导致「Rust 认为命中、Dart 认为不命中」的分叉。
- **触发路径与用户可见后果**：添加网址/开书时，某些书源的 pattern 在 Rust 侧能命中而在 Dart 侧抛错被 `catch` 忽略 → 落不到对应书源，退化为「网页书籍」裸入库或按错误类型打开。
- **建议修法**：新增 FFI `matchesBookUrlPattern(pattern, url) -> bool`（或 `matchBookSourceForUrl`），Dart 两处改为调用；短期至少在 `docs/API_CONTRACT.md` 登记「UI 侧正则匹配为临时实现」。

#### P3-9 隐私闸门在标记加载期间返回无任何指示的空白页

- **等级**：P3（首帧体验）
- **文件:行号**：`widgets/privacy/private_read_gate.dart:108-111`（`if (!privacy.loaded || !content.loaded) return const SizedBox.expand();`）
- **问题**：与 `PrivacyAppStartGate` 有专门的 `_SplashPlaceholder`（同文件 `widgets/privacy/privacy_app_start_gate.dart:463+`）不同，阅读器闸门在策略/标记未就绪时是**完全空白**（无 spinner、无锁图标）。
- **触发路径与用户可见后果**：冷启动深链直达 `/reader`，或刚恢复备份后立即打开书籍 → 首帧可能白屏 100–500ms（FFI 四连查：私密书籍、私密分组、书籍列表、分组列表），用户以为闪退/黑屏。
- **建议修法**：复用 `_SplashPlaceholder` 的样式（纯色 + 低透明度锁图标），避免「白屏 = 崩溃」的误判。

#### P3-10 字体导入重复选择同一字体时列表与偏好重复累积

- **等级**：P3（数据卫生）
- **文件:行号**：`screens/font_screen.dart:211-213`（`list.add('$family|$_fontSubDir/$family.ttf')`，`_customFonts.add(...)` 均无去重）
- **问题**：`family = 'Custom_$name'` 由文件名派生；同一文件重复导入时 `prefs` 的 `_keyCustomFonts` 列表与页面 `_customFonts` 都会追加重复项，且重复执行 `FontLoader(family)` 注册同名族（`FontLoader` 实例各自独立，不会抛错）。
- **触发路径与用户可见后果**：字体页 → 导入 → 再次选择同一 `.ttf` → 字体列表出现两条同名项（选中无差异）；`prefs` 列表随每次重复导入线性累积，没有删除入口清理。
- **建议修法**：导入前按 `family` 去重（已存在则覆盖文件并提示「已更新」），或在 `_keyCustomFonts` 写入前做 `set` 去重。

---

## 三、需用户裁决项

| 编号 | 议题 | 我方证据 | 参考版/上游证据 | 需裁决什么 |
|---|---|---|---|---|
| D-1 | **语言切换只完成约 85 条字符串**（P2-2） | `lib/src/l10n/app_strings.dart:2-6`；`screens/widgets` 内 1,617 处 `Text('中文')`、约 5,048 条中文字面量；入口 `other_settings_screen.dart:274-281 / 1191-1216` | `legado-with-MD3/app/src/main/res/values-en/strings.xml`（完整本地化） | 是「暂时隐藏 en 选项」、还是「投入补齐 1,600+ 条」、还是「保留并明示部分中文」？ |
| D-2 | **私密书改名后记录/书签脱敏失效**（P2-3） | `edit_book_info_screen.dart:212-217` 写 `books.name`；`privacy_content_service.dart:185-190` 以 name+author 建键；`rust/legado-ffi/src/api/bookshelf.rs:156-163` 无级联 | 参考版 `ui/book/readRecord/*` / `ui/book/bookmark/*` **无脱敏逻辑**（未实现该能力，非回归） | 修法三选：a) readRecord/bookmark 增 `bookUrl`（Rust schema + 备份链）；b) `updateBook` 改名级联（Rust 事务）；c) 承认此边界、登记为已知限制 |
| D-3 | **远程书库「部分成功」语义**（P2-7） | `remote_book_notifier.dart:466-471` + `remote_book_screen.dart:53-61` | `legado-with-MD3` `RemoteBookViewModel.kt:279-303`：任一失败整体报错（全有或全无） | 保持我方「部分成功 + 补失败提示」，还是对齐参考版「任一失败即整体失败」？ |
| D-4 | **WebDAV「同步书库」是否应保留上传语义**（P2-6） | `webdav_settings_screen.dart:534-606`（确认文案已如实说明上传，但进度写成「恢复中…」） | 参考版备份/恢复为两条独立入口（`BackupConfigFragment` + `Restore`），无「同步书库（合并）」概念 | 是否把该入口重命名/拆分为「上传覆盖远端」与「拉取覆盖本地」两条？ |
| D-5 | **UI 侧书源正则匹配是否下沉 FFI**（P3-8） | `bookshelf_screen.dart:3196-3215`、`book_open_utils.dart:395-410` | `rust/legado-fetcher/src/web_book.rs:4296`（已有真源，未暴露 FFI） | 是否新增契约项（涉及 ffi/server 两轨），还是登记为已知临时实现？ |

---

## 四、已核实无问题项

| 检查点 | 核实方式 | 结论 |
|---|---|---|
| `state` 更新漏 `copyWith` / 漏通知 | 全部 notifier 的 `state =` 点 grep + 51 个 `build()` 逐段阅读；`state = state;` 全仓 0 处 | 未发现空写。`Notifier` 与 `ChangeNotifier` 混用仅 `AudioNotifier`（`audio_notifier.dart:143`），其 UI 消费方 `audio_screen.dart:485-489` 同时 `ref.watch` + `ListenableBuilder(listenable: notifier)`，`_paragraphIndex` 等非 state 字段变化能重建 |
| `copyWith(field: null)` 是否真能清空（freezed 陷阱） | `providers/search/search_state.freezed.dart:119 / 237` 确认使用 `freezed` 哨兵（`Object? error = freezed`），显式 `null` 会写空 | 正确，无「错误清不掉」问题 |
| freezed List identity（历史勾选回弹坑） | 全仓 `identical(` 命中 3 处（`bookshelf_screen.dart:164` 路由对象、`association_import_dialog.dart:147` dialog state、`reader_comic_screen.dart:735` Future），均非集合 identity 判定；`didUpdateWidget` 全部按标量字段比较 | 未发现 identity 判定集合的写法 |
| build 内触发状态写入（历史「面板打不开」坑） | 脚本扫描所有 `Widget build(...)` 体内的 `ref.read(...notifier).method(`，命中 6 处全部位于 `onPressed/onSelected/onClear` 闭包（`explore_screen:130/148`、`read_record_screen:112`、`source_screen:123`、`private_read_gate:103`、`reader_toc_rule_dialog:221`）；`Future.microtask` / `addPostFrameCallback` 使用点逐一核对 | 未发现 build 期同步写 provider |
| 异步竞态：旧结果覆盖新结果 | 阅读器（`_openSeq` / `_loadSeq` / `_refreshing` / `_changeSourceFlowActive`，`reader_notifier.dart:53-90`）、搜索（`_searchSeq` + 批次 seq 守卫，`search_notifier.dart:190-460`）、RSS（`_requestId`，`rss_notifier.dart:130-340`）、发现（`_loadSeq`/`isLoading` 互斥，`explore_show_notifier.dart`）、书籍加载（`_generation`，`app_font_notifier.dart:96-140`）逐条核对 | 主要异步链均有代际/序号守卫 |
| dispose 后写 provider state | 全仓无 `autoDispose`（`explore_show_notifier` 除外，其为 family+autoDispose 且无异步写 server 风险）；其余 notifier 为全局常驻 | 当前不构成可见缺陷；`SearchNotifier` 记为 P3-2 潜在风险 |
| `ref.read` 在 await 之后使用（widget 侧） | 脚本扫描 101 处候选，人工核验重点：`reader_screen._onExitPop`（`context.mounted` 全分支）、`bookshelf_screen._openBook`（`context.mounted`）、`search_screen` 生命周期回调 | 未发现未保护的 `setState/context` 使用（`video/comic` 的 `setState` 已单列 P3-5） |
| `PopScope` / `canPop` 语义（历史 IME 吞返回键坑） | 12 处 `PopScope` 逐一核对：`home_screen:424`、`search_screen:309`、`reader_screen:1206`、`reader_comic_screen:2055`、`video_screen:1108`、`bookshelf_screen:421`、`source_screen:119`、`rss_articles_screen:1079`、`rss_source_manage_screen:177`、`rss_source_edit_screen:518`、`remote_book_screen:73`、`privacy_settings_screen:830`、`code_edit_screen:200`、`file_manage_screen:207` | 均有可达的显式退出路径；`search_screen.dart:66-80` 的 `_backUnfocusConsumed`/`_keyboardShownSinceFocus` 状态机正确解决了「第一次返回被 IME 消费」问题；`home_screen` 多栏/文件夹/发现内容三路返回分发正确 |
| 键盘遮挡输入框 | 脚本：含 `showModalBottomSheet` 且含 `TextField` 但无 `viewInsets` 的文件 = **0**；`bottom_sheet_widget.dart`（无输入项）不受影响 | 未见遮挡风险 |
| 大字号（textScaler）适配 | `book_grid_item.dart:119`、`book_display_tags_row.dart:41`、`explore_book_list.dart:503-504`、`reader_menu_panel.dart:1467/1591`、`reader_page_view.dart:921/1504`、`paragraph_layout_engine.dart:171-240` 均按 `MediaQuery.textScalerOf` 计算布局高度；`app.dart:597-637` 仅在用户显式设置时覆盖系统缩放（`fontScaleRaw=0` → 跟随系统） | 主要列表/阅读区已适配；`app.dart` 覆盖语义与原版 `PreferKey.fontScale` 一致 |
| 深色主题硬编码颜色 | `Colors.white/black` 全部命中位于漫画/视频播放器/二维码（必须黑白）或 `barrierColor`；`Color(0x...)` 66 处抽查为语义色（`qrcode_screen:352` 二维码底、`source_debug_screen:295` 代码块） | 未发现「浅色写死」类问题；主题色槽 0 归一在内存与持久化两侧一致（`theme_colors_notifier.dart:203-235` + `app.dart:474-475`） |
| 长列表非懒加载 | `ListView(`（非 builder）全部 50 处人工分类：设置页/有限项卡片；`read_record_daily_view` 的数据源为**当年**记录（最多 366 行，`read_record_screen.dart:56` 传 `DateTime.now().year`） | 无实际性能问题 |
| `Column` 直接包无界 `ListView`（垂直 viewport 无界崩溃） | 脚本扫描 `Column(` 后 8 行内出现 `ListView(` 且无 `shrinkWrap/Expanded/Flexible` = **0** | 未发现 |
| 图片缓存/尺寸约束 | `book_cover.dart` 有 `CoverAspectRatio.cached` + 显式宽高；漫画走 `ComicImageDecodeCache` + `imageRetainNum` 清理（`reader_comic_screen.dart:1136-1215`、`_retainComicImages`） | 主要图片链路有约束与清理 |
| 隐私闸门 fail-closed | `privacy_app_start_gate.dart:24-30`（`privacyGateBlocksApp`）、`:330-380`（锁页）、`:450-465`（键盘抬升）；`privacy_notifier.dart` 策略/凭据读取失败只显示错误+重试；书架/详情/读记录/书签/搜索均有脱敏路径（见 P2-3 的例外：改名边界） | 启动锁与阅读锁结构正确；唯一缺口是 P2-3 的反查键 |
| 主题 12 色槽接线 | `app.dart:456` watch `themeColorsProvider`；`:535-566` 把 `primaryTextColorFor/secondaryTextColorFor` 送入 `AppTheme.palette`；`:474-475` 0 归一 | 设置页与全局主题确实联动，非「只在设置页生效」 |
| 应用字体 / 启动图标接线 | `app.dart:458` watch `appFontProvider` → `ThemeData.fontFamily`；`theme_config_screen.dart:1783-1806` + `services/launcher_icon_service.dart`（Android/iOS 原生通道，失败返真实原因） | 接线完整 |

---

## 五、方法可复现（供复核）

以下为本次使用的只读检查（全部在 `flutter_legado` 根目录执行，未修改代码）：

1. **未释放资源扫描**：解析每个 `.dart` 的状态字段声明（`TextEditingController/ScrollController/AnimationController/PageController/TabController/FocusNode/Timer/StreamSubscription/...`），在文件全文内查找 `name.dispose(` / `name?.cancel(`（含 `..dispose()` 级联人工复核）。
2. **Loading 标志永挂扫描**：对每个方法体统计 `isLoading/loading/isBusy/busy: true` 与对应 `false`（含 `finally`），人工复核命中项。
3. **异步上下文扫描**：对每个 `Future/void x() async {}` 追踪「最近一次 `await` 之后是否出现 `setState` / `ref.read` / `context.*` 且中间无 `mounted|context.mounted|_disposed` 守卫」。
4. **build 期状态写扫描**：提取每个 `Widget build(BuildContext)` 的完整大括号体，匹配 `ref.read(X.notifier).method(`。
5. **死方法扫描**：提取 51 个 `*_notifier.dart` 的公开方法名，在 `lib/` 全量文本做裸名计数（`n <= 1` 判定为「仅定义」），再用 `git grep`/人工核 tear-off（`onChanged: notifier.setX`）排除误报。
6. **键盘遮挡扫描**：`showModalBottomSheet` 与 `TextField/TextFormField` 同文件出现、但无 `viewInsets` 的文件集合。
7. **无界列表扫描**：`Column(` 后 8 行内出现 `ListView(` 且无 `shrinkWrap/Expanded/Flexible`。
8. **文案量化**：`.dart` 内 `Text('…中文…')` 计数 1,617；含 CJK 的字符串字面量约 5,048；`AppStrings.` 引用 85。

---

## 六、建议批次切分（文件不重叠，可按 2 子代理并行）

> 原则：同一文件不出现在两个并行批次；每批可独立编译/测试；P1 优先。

### 并行轮 1

| 批次 | 内容 | 文件（不重叠） | 预估 |
|---|---|---|---|
| **A（P1）** | P1-1 压缩包导入假成功 + 失败提示；顺带该文件内 P2-4 的 `$e` 文案 | `screens/archive_import_dialog.dart`（+ `test/` 新增 1 个 widget 用例） | 小 |
| **B（P2 段评）** | P2-1 `_reviewLoadedKey` 成功后再置位 + catch 复位 + 失败重试 | `screens/reader_screen.dart`、`test/widget/reader_review_summary_test.dart` | 小 |

### 并行轮 2

| 批次 | 内容 | 文件（不重叠） | 预估 |
|---|---|---|---|
| **C（P2 导航）** | P2-5 开书重入保护；P3-7 书源查询失败提示；P3-8 书源匹配下沉/登记（仅动 UI 侧两处调用点） | `screens/bookshelf_screen.dart`、`utils/book_open_utils.dart` | 中 |
| **D（P2 错误文案 A）** | P2-4 前半：分组/书架管理/书单/日志/关于/底部皮肤 的 `$e` → `errorMessage(e)` | `screens/bookshelf_manage_screen.dart`、`screens/book_group_screen.dart`、`screens/app_log_screen.dart`、`screens/about_screen.dart`、`screens/bottom_bar_skin_screen.dart`、`screens/bottom_bar_skin_assign_screen.dart` | 小 |

### 并行轮 3

| 批次 | 内容 | 文件（不重叠） | 预估 |
|---|---|---|---|
| **E（P2 错误文案 B）** | P2-4 后半：RSS 源管理/其他设置/详情页 part/听书/JS 编辑/离线缓存/朗读设置 | `screens/rss_source_manage_screen.dart`、`screens/other_settings_screen.dart`、`screens/book_info_screen_builders.part.dart`、`screens/audio_screen.dart`、`screens/js_source_edit_screen.dart`、`screens/offline_cache_screen.dart`、`screens/read_aloud_settings_screen.dart` | 中 |
| **F（P2 导入/同步语义）** | P2-7 远程书库部分失败提示；P2-8 自动任务写入失败提示；P2-6 同步书库进度文案 | `providers/remote_book/remote_book_notifier.dart`、`screens/remote_book_screen.dart`、`screens/auto_task_screen.dart`、`screens/webdav_settings_screen.dart` | 中 |

### 并行轮 4（P3 卫生，可合并为一批）

| 批次 | 内容 | 文件（不重叠） |
|---|---|---|
| **G** | P3-1 9 个 ScrollController 释放 + P3-2 搜索 notifier `onDispose` | 9 个 screens（`bookmark/bookshelf_manage/explore/highlight_rules/read_record/replace_rules/rss_source_manage/search_content/txt_toc_rules`）+ `providers/search/search_notifier.dart` |
| **H** | P3-3 死状态/死方法清理；P3-4 日期解析共用；P3-5 setState mounted；P3-6 详情页空参终态；P3-9 闸门空白占位；P3-10 字体去重 | `providers/ui_settings/ui_settings_notifier.dart`、`providers/sync/sync_notifier.dart`、`providers/sync/sync_state.dart`、`providers/main_prefs_notifier.dart`、`providers/source/source_notifier.dart`、`providers/rss/rss_notifier.dart`、`providers/association/association_notifier.dart`、`providers/auto_task/auto_task_notifier.dart`、`providers/explore/explore_show_notifier.dart`、`providers/audio/audio_notifier.dart`、`screens/read_record_daily_view.dart`、`screens/video_screen.dart`、`screens/reader_comic_screen.dart`、`screens/book_info_screen_load.part.dart`、`widgets/privacy/private_read_gate.dart`、`screens/font_screen.dart` |

> 说明：D-1（i18n）、D-2（隐私改名）、D-5（正则下沉 FFI）在用户裁决前不排开发批次，避免返工。

---

## 七、与其它四路的边界说明

- 本报告只覆盖 **Flutter 侧（Dart）**。P2-3 的根治涉及 Rust `readRecord/bookmark` schema 与 `updateBook` 级联，需与「路 4 数据层」联合排期；P3-8 涉及 FFI/契约，需与「路 2 FFI 契约」联合排期。
- 本报告未复核任何 Web 服务端点、FFI 导出面、备份文件格式，这些属其它三路。
- 本报告未重复登记 `docs/REFACTORING_FULL_AUDIT_REPORT_20261113.md` 已收录的 P0/P1/P2（均为非 UI 轨）。

---

编写：代码审核员（子代理）｜ 2026-11-13
