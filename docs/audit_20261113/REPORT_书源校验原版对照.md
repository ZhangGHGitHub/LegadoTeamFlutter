# 书源校验（Check Source）原版语义对照调查报告

- 调查日期：2026-11-15
- 调查范围：仓内 Android Kotlin 原版、`legado-upstream` 上游、`legado-with-MD3` 参考版、我方 Rust/Flutter 实现
- 调查方式：只读静态核验（逐行读代码 + `grep`/`diff`），未运行 `cargo test`、未做设备验收
- 版本基线：
  - 仓内 Kotlin 的 `CheckSourceService.kt`、`CheckSource.kt`、`CheckSourceConfig.kt`、`BookSourceDao.kt`、`BookSource.kt`、`BookSourceActivity.kt` 与 `legado-upstream` 当前 HEAD `531f9fbf07`（2026-10-22）对应文件**逐字节一致**（`diff -q` 无输出）。
  - 参考版 `legado-with-MD3` 当前 HEAD `701943e`（2026-10-28，同步参考版 main@bba5c64）。
  - 我方实现以当前工作区 Rust/Flutter 代码为准。

---

## 一、结论摘要

### 硬结论 1：原版执行的是完整书源规则链，不是 URL 探测

原版 `CheckSourceService` 在单源校验中依次调用：

- `WebBook.searchBookAwait`（搜索，内部构造 `AnalyzeUrl` 并调用 `BookList.analyzeBookList`）
- `WebBook.exploreBookAwait`（发现）
- `WebBook.getBookInfoAwait`（详情，内部 `AnalyzeUrl` + `BookInfo.analyzeBookInfo`）
- `WebBook.getChapterListAwait`（目录，内部 `AnalyzeUrl` + `BookChapterList.analyzeChapterList`）
- `WebBook.getContentAwait`（正文，内部 `AnalyzeUrl` + `BookContent.analyzeContent`）

因此它确实执行 `AnalyzeUrl`（@js、POST、header、编码、相对地址等）与 `AnalyzeRule`（searchList/bookUrl/toc/content 等规则），不是“替换 searchUrl 后 GET 一下”的连通性探测。关键证据见 §2.3、§2.6。

### 硬结论 2：原版校验结果只“标记”，不自动禁用、不自动删除书源

原版把结果写入：

- `book_source_check_states` 表：`status`（`NEEDS_CHECK`/`PASSED`/`FAILED`/`UNCHECKABLE`）、`detail`、`checkedAt`；以 `(bookSourceUrl, revision, status='NEEDS_CHECK')` 做 CAS 写回。
- `book_sources.respondTime`：失败时写入 `timeout + 实际耗时`，其余写实际耗时（用于“响应时间”排序）。

书源管理页只做三件事：展示状态/详情、按状态筛选、刷新列表。**没有任何从 `checkStatus` 到 `enabled` 或 `delete` 的代码路径**；`enable(false)` 与 `delete` 只出现在用户主动的批量菜单/编辑页动作中。详见 §3。

> 因此：如果我方存在“按校验结果自动禁用/删除书源（清源）”的行为，它属于自创语义，不是原版行为。

### 其他关键结论

1. **关键词**：默认 `"我的"`；若书源 `ruleSearch.checkKeyWord` 非空且不含 `http`/`::`/`++`/`--`，则用书源自带关键词覆盖。关键词只在内存中保存（`CheckSource.keyword`），不写入 `CacheManager`。
2. **超时**：默认 `180000 ms`，按“单个书源整条链”计时（`withTimeout`），不是按步骤计时；设置对话框以“秒”为单位，必须大于 0。
3. **并发**：原版是**并行**校验，`mapParallel(threadCount)`，并发上限取全局“更新和搜索线程数”（默认 32）；协程调度线程池大小又被 `AppConst.MAX_THREAD = 9` 夹到 9。
4. **原版不持久化“失效分组/错误注释”**：`source.addGroup` / `addErrorComment` 只修改内存实体，用于拼 `detail`；服务只写检查状态表与 `respondTime`，没有 `updateSources(source)`。
5. **参考版改了架构但保留规则级语义**：Compose 底部弹窗 + 前台 Service + `BookSourceCheckGateway`/`BookSourceCheckRepository`，仍走 `WebBook.*Await` 完整规则链；但取消了域名可达性检查，检查结果只存在内存 `StateFlow`，不写 `book_source_check_states`；同时会把失效分组/错误注释持久化回书源（`updateSources`）。
6. **我方当前实现是简化连通性探测**：`legado-net/src/source_checker.rs` 只做 searchUrl 占位符替换 + GET + 取首个 `href`，不执行 `AnalyzeUrl`/`AnalyzeRule`；FFI 批量校验还是串行。仓内已有一份完整的规则级实现 `rust/legado-server/src/legacy/source_check_api.rs`，可复用/下沉。

---

## 二、原版流程证据

### 2.1 触发与排队

- 书源管理页批量选择后，菜单“校验所选”进入 `checkSource()`：
  - `app/src/main/res/menu/book_source_sel.xml:55-60`（`menu_check_source`，标题 `check_select_source`）
  - `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceActivity.kt:563-570`（菜单分发）
  - `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceActivity.kt:606-647`（关键词弹窗、取选中书源、`Debug.tryStartCheckSession()`、`CheckSource.start`）
- `CheckSource.start` 先准备调试会话、调用 `BookSourceDao.beginCheck` 重置状态并生成 revision，再启动前台服务：
  - `app/src/main/java/io/legado/app/model/CheckSource.kt:33-54`
  - `app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt:308-321`（`beginCheck`）
- 服务启动后，逐个复核“书源是否已删除/已变更”，只对未变更的源发起校验：
  - `app/src/main/java/io/legado/app/service/CheckSourceService.kt:177-204`

### 2.2 并发与超时

- 并发：
  - `CheckSourceService.kt:80-82`：`threadCount = AppConfig.threadCount`，调度器为 `Executors.newFixedThreadPool(min(threadCount, AppConst.MAX_THREAD))`。
  - `CheckSourceService.kt:210`：`mapParallel(threadCount)`；`app/src/main/java/io/legado/app/utils/FlowExtensions.kt:52-56` 用 `flatMapMerge(concurrency)` 并行执行。
  - `app/src/main/java/io/legado/app/help/config/AppConfig.kt:416-419`：`threadCount` 默认 32。
  - `app/src/main/java/io/legado/app/constant/AppConst.kt:29`：`MAX_THREAD = 9`。
  - 结论：实际是“并发校验”，并发度目标为 `threadCount`（默认 32）；底层调度线程池最多 9 条线程。
- 单源超时：
  - `CheckSourceService.kt:273-282`：`withTimeout(CheckSource.timeout) { doCheckSource(...) }`。
  - `CheckSource.kt:23`：`timeout = CacheManager.getLong("checkSourceTimeout") ?: 180000L`。
  - 即超时作用于“单个书源的整条规则链”，不是单个网络步骤。

### 2.3 单源校验步骤（`doCheckSource`）

入口：`app/src/main/java/io/legado/app/service/CheckSourceService.kt:320-379`。

1. **清理旧失效标记**
   - `source.removeInvalidGroups()`（`:323`；实现见 `BookSource.kt:198-200`）
   - `source.removeErrorComment()`（`:324-326`；实现见 `BookSource.kt:202-208`）

2. **源地址可访问性（可选，默认关闭）**
   - 开关：`CheckSource.checkDomain` 默认 `false`（`CheckSource.kt:25`）。
   - 解析 `bookSourceUrl`：非 http(s)/不可解析 → 标记 `domainUnchecked = true`（`:330-332`）。
   - TCP 探测：`withTimeout(2000)` + `socket.connect(..., 1600)`（`:308-318`）。
   - 不可达 → 分组“域名失效”并抛 `NoStackTraceException("源地址不可访问")`（`:333-338`）。

3. **搜索校验**
   - 开关：`CheckSource.checkSearch` 默认 `true`（`CheckSource.kt:26`）。
   - 关键词：`source.getCheckKeyword(CheckSource.keyword)`（`:342`；实现见 `BookSource.kt:216-223`）。
   - 条件：JS 单文件源或 `searchUrl` 非空；否则抛“搜索链接规则为空”。
   - 调用 `WebBook.searchBookAwait(source, searchWord)`（`:345`）。
   - 结果为空 → 分组“搜索失效”（不立即抛出）；非空 → 取第一本 `toBook()` 交给 `checkBook`（`:346-351`）。

4. **发现校验**
   - 开关：`CheckSource.checkDiscovery` 默认 `true`（`CheckSource.kt:27`）。
   - 仅当 `exploreUrl` 非空时执行（`:357`）。
   - 取第一个非空分类 URL；为空 → 抛“发现规则为空”（`:358-362`）。
   - 调用 `WebBook.exploreBookAwait(source, url)`（`:365`）。
   - 结果为空 → 分组“发现失效”；非空 → 第一本交给 `checkBook`（`:366-371`）。

5. **详情 / 目录 / 正文（`checkBook`）**
   - 开关：`CheckSource.checkInfo` 默认 `true`（`CheckSource.kt:28`）；关闭则直接返回（`CheckSourceService.kt:386-388`）。
   - 详情：若 `book.tocUrl` 为空，调用 `WebBook.getBookInfoAwait(source, book)`（`:390-392`）。
   - 目录：若 `checkCategory` 为 false 或书源类型为 `file`，跳过；否则 `WebBook.getChapterListAwait(source, book).getOrThrow()`，再用 `selectCheckSourceChapter` 取前两个可读章节（`:393-400`；章节选择见 `app/src/main/java/io/legado/app/service/CheckSourceChapterSelection.kt:11-24`）。
   - 正文：若 `checkContent` 为 false，跳过；否则 `WebBook.getContentAwait(..., needSave = false)`（`:401-411`）。
   - 空目录/空正文异常映射：
     - `ContentEmptyException` → “搜索正文失效”/“发现正文失效”
     - `TocEmptyException` → “搜索目录失效”/“发现目录失效”
     - 其他异常继续上抛（`:412-423`）。
     - 空内容/空目录的抛出点：`app/src/main/java/io/legado/app/model/webBook/BookContent.kt:207`、`app/src/main/java/io/legado/app/model/webBook/BookChapterList.kt:122`。

6. **汇总判定**
   - `source.getInvalidGroupNames()`：收集所有包含“失效”或等于“校验超时”的分组（`BookSource.kt:225-229`）。
   - 非空 → 抛 `NoStackTraceException(分组串)`（`CheckSourceService.kt:374-377`）。
   - 全部通过且 `domainUnchecked` → `UNCHECKABLE`；否则 `PASSED`（`:296-299`）。

### 2.4 判定标准（通过 / 失败 / 不可校验）

| 结果 | 触发条件 | 证据 |
|---|---|---|
| `PASSED` | `doCheckSource` 正常返回、无失效分组、无异常 | `CheckSourceService.kt:273-306`、`:374-378` |
| `FAILED` | 任意异常：超时、脚本异常、搜索为空、目录为空、正文为空、域名不可达、搜索/发现规则为空等 | `:283-295`（异常分类）、`:345-354`、`:365-377`、`:412-423` |
| `UNCHECKABLE` | 开启 `checkDomain`，但 `bookSourceUrl` 无法解析为 http(s)，其余检查全部通过 | `:296-299`、`:330-332` |
| `NOT_COMPLETED` | 书源已删除，或校验期间源/revision 已变更，结果不写回 | `:179-204`、`:231-250` |

失败分组的具体映射：

- 超时（`TimeoutCancellationException`）→ “校验超时”
- 脚本异常（`ScriptException` / `WrappedException`）→ “js失效”
- 其他非 `NoStackTraceException` 异常 → “网站失效”
- 域名 TCP 不可达 → “域名失效”
- 搜索无结果 → “搜索失效”
- 发现无结果 → “发现失效”
- 目录为空 → “搜索目录失效” / “发现目录失效”
- 正文为空 → “搜索正文失效” / “发现正文失效”
- 搜索规则为空 → 直接抛“搜索链接规则为空”
- 发现规则为空 → 直接抛“发现规则为空”

证据：`CheckSourceService.kt:283-295`、`:328-338`、`:346-354`、`:357-373`、`:412-423`。

> 注意：`PASSED` 并不要求详情/目录/正文的字段“非空”被单独断言；它们是“解析结果为空则抛对应异常/分组”。例如目录列表为空由 `BookChapterList.kt:122` 抛 `TocEmptyException`，正文为空由 `BookContent.kt:207` 抛 `ContentEmptyException`。

`respondTime` 写入口径：

- 成功（PASSED/UNCHECKABLE）→ 实际耗时
- 失败（FAILED）→ `CheckSource.timeout + 实际耗时`
- 证据：`CheckSourceService.kt:300-305`、`app/src/main/java/io/legado/app/model/Debug.kt:283-287`。

### 2.5 关键词与配置

- 默认关键词：`CheckSource.keyword = "我的"`（`CheckSource.kt:20`）。
- 书源级覆盖：`BookSource.getCheckKeyword`（`BookSource.kt:216-223`）：
  - `ruleSearch.checkKeyWord` 非空、且不含 `http`、`::`、`++`、`--` 时使用它；否则回落默认关键词。
- UI 关键词：校验开始弹窗预填 `CheckSource.keyword`，确认后只更新内存字段（`BookSourceActivity.kt:606-619`）；没有写入 `CacheManager`。
- 超时：`CheckSource.timeout`（默认 180000ms），配置对话框以秒保存（`CheckSourceConfig.kt:86`、`:99-117`、`CheckSource.putConfig` 在 `CheckSource.kt:69-78`）。
- 检查项开关与默认值（`CheckSource.kt:24-30`）：
  - `wSourceComment = true`（详情中附加 `// Error:` 注释行）
  - `checkDomain = false`
  - `checkSearch = true`
  - `checkDiscovery = true`
  - `checkInfo = true`
  - `checkCategory = true`
  - `checkContent = true`
- 并发数不在校验设置里单独配置，复用全局“线程数”（见 §2.2）。

### 2.6 规则链证据（关键代码段）

`WebBook.searchBookAwait`：

```kotlin
val analyzeUrl = AnalyzeUrl(
    mUrl = searchUrl,
    key = key,
    page = page,
    baseUrl = bookSource.bookSourceUrl,
    source = bookSource,
    ruleData = ruleData,
    coroutineContext = currentCoroutineContext()
)
...
BookList.analyzeBookList(
    bookSource = bookSource,
    ruleData = ruleData,
    analyzeUrl = analyzeUrl,
    baseUrl = res.url,
    body = res.body,
    isSearch = true,
    ...
)
```

证据：`app/src/main/java/io/legado/app/model/webBook/WebBook.kt:53-110`（`AnalyzeUrl` 在 `:68-76`，`BookList.analyzeBookList` 在 `:103-110`）。

`WebBook.getBookInfoAwait`：

```kotlin
val analyzeUrl = AnalyzeUrl(
    mUrl = book.bookUrl,
    baseUrl = bookSource.bookSourceUrl,
    source = bookSource,
    ruleData = book,
    coroutineContext = currentCoroutineContext()
)
...
BookInfo.analyzeBookInfo(
    bookSource = bookSource,
    book = book,
    baseUrl = book.bookUrl,
    redirectUrl = res.url,
    body = res.body,
    canReName = canReName
)
```

证据：`WebBook.kt:202-265`（`AnalyzeUrl` 在 `:222-228`，`BookInfo.analyzeBookInfo` 在 `:255-262`）。

`WebBook.getChapterListAwait`：

```kotlin
val analyzeUrl = AnalyzeUrl(
    mUrl = book.tocUrl,
    baseUrl = book.bookUrl,
    source = bookSource,
    ruleData = book,
    coroutineContext = currentCoroutineContext()
)
...
BookChapterList.analyzeChapterList(
    bookSource = bookSource,
    book = book,
    baseUrl = book.tocUrl,
    redirectUrl = res.url,
    body = res.body,
    ...
)
```

证据：`WebBook.kt:297-360`（`AnalyzeUrl` 在 `:322-328`，`BookChapterList.analyzeChapterList` 在 `:355-360` 起）。

`WebBook.getContentAwait`：

```kotlin
val analyzeUrl = AnalyzeUrl(
    mUrl = bookChapter.getAbsoluteURL(),
    baseUrl = book.tocUrl,
    source = bookSource,
    ruleData = book,
    chapter = bookChapter,
    coroutineContext = currentCoroutineContext()
)
...
BookContent.analyzeContent(
    bookSource = bookSource,
    book = book,
    bookChapter = bookChapter,
    baseUrl = bookChapter.getAbsoluteURL(),
    redirectUrl = res.url,
    body = res.body,
    nextChapterUrl = nextChapterUrl,
    needSave = false
)
```

证据：`WebBook.kt:395-495`（`AnalyzeUrl` 在 `:448-455`，`BookContent.analyzeContent` 在 `:485-494`）。

> 这些方法还包含 `loginCheckJs`、`checkRedirect`、`AnalyzeUrl.getStrResponseAwait()` 等完整请求语义（header、超时、重定向、JS、编码），进一步证明不是简单 GET。

---

## 三、原版结果使用方式（标记 vs 删源）

### 3.1 写回数据库：只写状态与响应时间

`CheckSourceService.onEach` 对每个完成的源调用：

```kotlin
val updated = appDb.bookSourceDao.completeCheck(
    selected, outcome.status.name, detail, source.respondTime,
)
```

证据：`app/src/main/java/io/legado/app/service/CheckSourceService.kt:223-250`。

`BookSourceDao.completeCheck`：

```kotlin
@Query("""update book_source_check_states set status = :status, detail = :detail,
    checkedAt = :checkedAt where bookSourceUrl = :url and revision = :revision and status = 'NEEDS_CHECK'""")
fun finishCheck(...): Int

@Query("update book_sources set respondTime = :respondTime where bookSourceUrl = :url")
fun updateRespondTime(url: String, respondTime: Long)

@Transaction
fun completeCheck(selected: BookSourcePart, status: String, detail: String, respondTime: Long): Boolean {
    val updated = finishCheck(selected.bookSourceUrl, selected.checkRevision, status, detail, System.currentTimeMillis())
    if (updated == 0) return false
    updateRespondTime(selected.bookSourceUrl, respondTime)
    return true
}
```

证据：`app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt:323-337`。

状态枚举与实体：

- `app/src/main/java/io/legado/app/data/entities/BookSourceCheckState.kt:20-34`：`NEEDS_CHECK` / `PASSED` / `FAILED` / `UNCHECKABLE`。
- `app/src/main/java/io/legado/app/data/entities/BookSourcePart.kt:16-31`：管理页视图 `left join book_source_check_states` 读取 `checkStatus` / `checkRevision` / `sourceRevision` / `checkedAt` / `checkDetail`。

### 3.2 UI：展示与筛选，不删不禁用

- 状态显示：`app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceAdapter.kt:276-289`（`PASSED/FAILED/UNCHECKABLE/else` + `checkDetail`）。
- 状态筛选：
  - 下拉列表：`BookSourceActivity.kt:126-129`（空、`NEEDS_CHECK`、`PASSED`、`FAILED`、`UNCHECKABLE`）
  - 初始化/切换：`BookSourceActivity.kt:185-198`
  - 过滤应用：`BookSourceActivity.kt:426-427`
- 显示开关：`app/src/main/res/menu/book_source.xml:149-152`（`menu_show_source_check_status`）与 `BookSourceActivity.kt:334-349`（写入 `AppConfig.showSourceCheckStatus`）。默认关闭（`AppConfig.kt:38-40`）。

### 3.3 没有“按结果禁用/删除”的代码路径

- `CheckSourceService.kt` 中没有 `enable(`、`delete(`、`updateSources(` 调用；只调用 `completeCheck`。
- 书源启用/禁用只出现在用户主动操作：
  - `BookSourceActivity.kt:563-570`（菜单“启用所选/禁用所选”分发）
  - `BookSourceViewModel.kt:75-92`（`enableSelection` / `disableSelection`）
  - `BookSourceAdapter.kt:160-170`（单项开关回调）
- 书源删除只出现在用户主动操作/编辑页：
  - `app/src/main/java/io/legado/app/ui/book/source/edit/BookSourceEditViewModel.kt:71`
  - 批量删除由管理页的选择菜单触发（`book_source_sel.xml` 的删除项）。
- 全仓 `checkStatus` 的消费点只有：DAO、`BookSourcePart`、管理页适配器/筛选、Web 端状态接口；没有 `checkStatus -> enabled` 或 `checkStatus -> delete` 的分支（`grep -rn "checkStatus" app/src/main/java/io/legado/app` 结果可复核）。

### 3.4 分组与错误注释：原版只用于拼 detail，不落库

- `doCheckSource` / `checkBook` 中的 `source.addGroup(...)`、`source.addErrorComment(...)` 只修改内存中的 `BookSource` 对象：
  - `BookSource.kt:172-181`（`addGroup`）、`:210-217`（`addErrorComment`）、`:198-200`（`removeInvalidGroups`）。
- `completeCheck` 只更新 `book_source_check_states` 与 `book_sources.respondTime`，没有 `updateSources(source)`。
- 分组仅用于拼 `detail`：
  - `CheckSourceService.kt:223-227`：`source.getInvalidGroupNames()` + `outcome.message` + `// Error:` 行。
- 因此原版**不会**把“搜索失效/目录失效/域名失效”等分组持久化到 `bookSourceGroup`，也不会把错误注释持久化到 `bookSourceComment`。

### 3.5 调试/HTTP 通道

- 校验会话由 `Debug.tryStartCheckSession()` 单会话占用；结果同时供调试窗口读取：
  - `app/src/main/java/io/legado/app/model/Debug.kt:16-35`（状态枚举/结果/快照）
  - `app/src/main/java/io/legado/app/api/controller/BookSourceCheckController.kt:17-84`（Web 端 `getBookSourcesForManagement` / `getBookSourceCheckStates` / `startBookSourceCheck` / `stopBookSourceCheck`）
- 这些接口同样只读写状态表，不做删除/禁用。

---

## 四、参考版证据

### 4.1 参考版有没有这个功能

有，且已用 Compose 重写。关键文件：

- `legado-with-MD3/app/src/main/java/io/legado/app/service/BookSourceCheckService.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/data/repository/BookSourceCheckRepository.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/domain/gateway/BookSourceCheckGateway.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/domain/gateway/CheckSourceSettingsGateway.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/data/repository/CheckSourceSettingsRepository.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceScreen.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/source/manage/CheckSourceBottomSheet.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceViewModel.kt`

### 4.2 参考版流程

1. 书源管理页选择菜单“校验书源”：
   - `BookSourceScreen.kt:513-518`（菜单动作，设置 `checkSourceIds`、打开 `CheckSheet.Run`）
2. 关键词弹窗 + 设置入口：
   - `BookSourceScreen.kt:333-351`（`CheckBookSourceSheet` 与 `CheckSourceBottomSheet`）
   - `BookSourceScreen.kt:781-830`（`CheckBookSourceSheet`：默认关键词取字符串资源 `book_source_check_default_keyword`，确认后回调 `StartCheck`）
3. 前台服务 + Gateway：
   - `BookSourceCheckService.kt:28-49`（`start/stop`）
   - `BookSourceCheckService.kt:114-146`（`onStartCommand`，调用 `StartBookSourceCheckUseCase`）
   - `BookSourceViewModel.kt:295-306`（`StartCheck` → 发出 `BookSourceEffect.StartCheck`）
   - `BookSourceScreen.kt:110-118`（effect → `BookSourceCheckService.start`）
4. 校验核心（规则级）：
   - `BookSourceCheckRepository.kt:40-96`（启动、并发、结果状态）
   - `BookSourceCheckRepository.kt:98-158`（单源超时、失败分组、保存）
   - `BookSourceCheckRepository.kt:184-214`（`WebBook.searchBookAwait` / `WebBook.exploreBookAwait`）
   - `BookSourceCheckRepository.kt:216-244`（`WebBook.getBookInfoAwait` / `getChapterListAwait` / `getContentAwait`）

### 4.3 参考版与原版的差异

| 维度 | 原版 Kotlin | 参考版 Compose |
|---|---|---|
| 规则链 | 完整 `WebBook.*Await` | 完整 `WebBook.*Await`（`:193`、`:205`、`:220`、`:222`、`:225`） |
| 域名可达性检查 | 有（`checkDomain`，默认关） | **无**（`CheckSourceSettingsGateway.kt:5-11` 无该字段；`BookSourceCheckRepository.checkSource` 无探测） |
| 检查项 | domain/search/discovery/info/category/content + wSourceComment | search/discovery/info/category/content（`CheckSourceBottomSheet.kt:84-130`） |
| 超时 | 单源整链 180s（可配） | 单源整链 `timeoutMillis`（默认 180_000，`CheckSourceSettingsGateway.kt:5-11`；`BookSourceCheckRepository.kt:116`） |
| 并发 | `mapParallel(threadCount)`（默认 32，调度池 9） | `Executors.newFixedThreadPool(threadCount)` + `async/awaitAll`（全局线程数，`BookSourceCheckRepository.kt:49-69`） |
| 结果存储 | 持久化 `book_source_check_states` + `respondTime` | **仅内存 `StateFlow`**（`BookSourceCheckRepository.kt:38-39`；全仓无 `book_source_check_states` 引用） |
| 失效分组/错误注释 | 仅内存，用于拼 detail，不落库 | 通过 `bookSourceRepository.updateSources(source)` **持久化**（`BookSourceCheckRepository.kt:129-133`） |
| 结果驱动禁用/删除 | **无** | **无**（结果只用于展示/通知/计数；`Delete`/`SetEnabled` 仅用户动作，`BookSourceViewModel.kt:275-277`、`:363-367`） |
| UI 设置入口 | “其他设置 → 校验书源”独立对话框 | 校验流程底部弹窗内的设置页（超时滑杆 0-300s + 5 个复选框） |
| 关键词默认 | `"我的"` | 字符串资源 `book_source_check_default_keyword`（中文为“我的”） |
| 关键词持久化 | 内存字段，不落配置 | 内存（`BookSourceCheckRepository.kt:57` 的 `ifBlank { "我的" }`），不落配置 |

参考版源码位置补充：

- `BookSourceCheckRepository.kt:49-51`：线程池大小取 `downloadCacheSettingsGateway.currentSettings.threadCount`。
- `BookSourceCheckRepository.kt:55-69`：对每个源 `async` 并发校验。
- `BookSourceCheckRepository.kt:116`：`withTimeout(settingsGateway.currentSettings.timeoutMillis)`。
- `BookSourceCheckRepository.kt:125-131`：与原版相同的 `校验超时`/`js失效`/`网站失效` 分组和 `respondTime` 语义。
- `BookSourceCheckRepository.kt:133`：`bookSourceRepository.updateSources(source)` 持久化源（含分组/注释）。
- `CheckSourceBottomSheet.kt:70-77`：超时滑杆默认 180 秒、范围 0-300。
- `BookSourceViewModel.kt:218-242`：`checkMessage` 来自内存 `check.results`，`checkOptions` 来自 settings。
- `BookSourceViewModel.kt:91-104`：校验结束只发 Snackbar 统计，不做清理。

### 4.4 参考版是否删源/禁用

没有。参考版 `BookSourceCheckRepository` 不调用 `setEnabled`/`delete`；`BookSourceViewModel` 的 `SetEnabled`/`Delete` 均来自用户菜单动作（`BookSourceViewModel.kt:275-277`、`:363-367`，以及 `BookSourceScreen.kt:513-540` 的批量动作区）。校验结束后的唯一次生副作用是：在 `BookSourceCheckRepository.checkOne` 中把源实体（含 `addGroup`/`addErrorComment` 修改）保存回库（`:129-133`）。

---

## 五、对我方裁决项的启示

### 5.1 我方现状（已确认事实）

当前应用侧书源校验走 FFI：

- 契约：`docs/API_CONTRACT.md:553-555`（`checkSource` / `checkSourcesStream` / `cancelCheckSources`）；`docs/API_CONTRACT.md:576` 明确核心实现是 `legado-ffi/src/api/source_check_api.rs` 包装 `legado-net::source_checker::SourceChecker`。
- FFI：
  - `rust/legado-ffi/src/api/source_check_api.rs:29`（引入 `SourceChecker`）
  - `:133-142`（`CheckerConfigDto`：`keyword` / `step_timeout_ms` / `check_search` / `check_toc` / `check_content` / `detect_captcha` / `detect_redirect`）
  - `:170-182`（创建 checker，使用共享客户端）
  - `:192-200`（单源 `check_full`）
  - `:272-330`（批量流；`:308` 注释明确“串行逐个校验”）
- 简化检查器：
  - `rust/legado-net/src/source_checker.rs:808-815`：`build_search_url` 只替换 `{{key}}`/`{key}`/`{searchKey}`。
  - `:717-743`：`do_search_check` 直接 `client.get(&url, ...)`。
  - `:817-831`：`extract_first_book_url` 仅用 `bookUrlPattern` 或首个 `href`。
  - `:833-841`：`extract_first_chapter_url` 注释自述“简化实现”，取首个 `href`。
  - `:981-985`：`extract_first_href` 正则取第一个链接。
  - `:767-783`：`do_content_check` 只判断 HTTP 成功 + body 非空。
  - `:435-587`：`check_full` 为 search → toc → content 三步（“详情页”实际就是 `book_url` 的目录页，没有独立 `webbook_info`）。
  - `:638-712`：`quick_check` 只做搜索请求 + 验证码/重定向检测。
  - 规则引擎使用情况：`rust/legado-net/src/source_checker.rs` 没有 `AnalyzeUrl`/`AnalyzeRule` 的实际调用（`source.rule_search` 只用于 `check_key_word`，`:785-806`）。
- Flutter：
  - 入口：`flutter_legado/lib/src/screens/source_screen_actions.part.dart:242-243`、`:269-306`（关键词弹窗 → `checkNotifier.start`）。
  - 配置：`flutter_legado/lib/src/screens/other_settings_screen.dart:1018-1031`（摘要）、`:1033-1089`（调用与字段映射）、`:1260-1420`（对话框控件：关键词、超时、搜索/目录/正文、验证码、重定向）。
  - 结果消费：`flutter_legado/lib/src/providers/source_check/check_source_notifier.dart:228-265`；全部完成后把失败源加入“失效”分组并持久化（`:256-264` → `source_notifier.dart:586-622`）。
  - 展示：`flutter_legado/lib/src/screens/source_screen_builders.part.dart:406-527`（进度条/完成提示）、`:625-630`、`:700-710`、`:815-880`（列表项消息）。

### 5.2 与原版的差距（语义级，不是参数级）

| 维度 | 原版 | 我方当前 |
|---|---|---|
| 搜索 | `AnalyzeUrl` + `BookList.analyzeBookList`（@js/POST/header/编码/规则） | 字符串替换 + GET + 首个 href/`bookUrlPattern` |
| 详情 | `WebBook.getBookInfoAwait`（`AnalyzeUrl` + `InfoRule`） | 无独立详情步骤 |
| 目录 | `WebBook.getChapterListAwait`（`AnalyzeUrl` + `TocRule`） | GET 书籍 URL + 首个 href |
| 正文 | `WebBook.getContentAwait`（`AnalyzeUrl` + `ContentRule`） | GET 章节 URL + 判空 |
| 发现 | `WebBook.exploreBookAwait` + 分类 URL 求值 | 无发现校验 |
| 域名可达性 | 可选 TCP 探测 | 无 |
| 检查项开关 | domain/search/discovery/info/category/content | search/toc/content + 验证码/重定向 |
| 超时 | 单源整链 180s | 单步 `step_timeout_ms` + 整源预算 |
| 并发 | 并行（`mapParallel(threadCount)`） | FFI 批量串行 |
| 结果存储 | `book_source_check_states` + `respondTime` | 仅内存消息；Flutter 额外写“失效”分组 |
| 结果驱动清源 | 无 | 无删除/禁用；有自动“失效”分组副作用 |
| UI | 管理页“校验所选” + 设置页“校验书源” | 管理页“校验所选” + 设置页“校验书源配置” |

结论：差距是“是否执行书源规则”的语义级差距；仅调整参数无法对齐。

### 5.3 “结果驱动清源逻辑”事实核查

- 原版：**只标记，不删源**（§3.3）。
- 参考版：**只展示/通知，不删源**（§4.4）。
- 我方当前：没有按结果删除或禁用书源的代码；唯一自动副作用是校验完成后把失败源追加到“失效”分组并持久化（`check_source_notifier.dart:256-264`、`source_notifier.dart:586-622`）。原版不做这个持久化（只拼 `detail`），因此“自动打失效分组”本身也已经偏离原版；如果进一步“按校验结果自动删除/禁用”，则是双重自创。
- 建议：把“标记失效分组”也纳入裁决项；若保留，应明确它是产品增强并写入文档/契约，而不是声称对齐原版。

### 5.4 已存在的可复用完整实现

`rust/legado-server/src/legacy/source_check_api.rs`（2013 行）已经实现了与原版高度对齐的规则级校验：

- 配置键与默认值：
  - `:127-138`（caches 键名）
  - `:199-215`（默认 180s、`checkDomain=false`、search/discovery/info/category/content 全开、并发按 CPU 夹逼 4~8）
  - `:225-248`（读取 caches 配置）
- 会话与启动：
  - `:549-692`（`start_book_source_check`：令牌、快照一致性、单会话、逐源重置 revision、后台任务）
  - `:823-905`（`run_check_session`：有界并发 worker + `JoinSet` + 取消）
  - `:908-965`（`check_one_source`：快照复核、`tokio::time::timeout(config.timeout_ms)` 整源超时）
- 单源检查：
  - `:1020-1166`（`check_source`：域名探测 `:1031-1041`；搜索 `:1049-1075`；搜索书详情/目录/正文 `:1077-1090`；发现 `:1092-1156`；汇总 `:1158-1165`）
  - `:1202-1254`（`check_book`：`webbook_info` `:1216-1219`、`webbook_chapters` `:1226-1234`、`webbook_content` `:1246-1249`）
  - `:1471-1478`（`select_check_chapter`）
- 结果写回：
  - `:973-1010`（`write_back_check_result`：取消丢弃、`finish_check` CAS、`update_respond_time`）

底层规则能力来自 `legado-fetcher`，FFI 侧已具备同样的注入面：

- `rust/legado-fetcher/src/web_book.rs:4810-4837`（`webbook_search`，内部 `build_engine(deps)` → `engine.search`）
- `:4858-...`（`webbook_explore_first_book`）
- `:5089-...`（`webbook_info`）
- `:5168-...`（`webbook_chapters`）
- `:5283-...`（`webbook_content`）
- `:3632-3634`（`build_engine` → `WebBookEngine<RealBookSourceFetcher>`）
- `legado-core/src/web_book.rs:553-613`（`WebBookEngine` 的 `search`/`get_book_info` 入口）
- `legado-fetcher/src/web_book.rs:3`、`:26`（模块自述依赖 `AnalyzeUrl + AnalyzeRule`；实际 `AnalyzeUrl::parse` 在 `:2038`、`:2158`、`:2607`、`:2898` 等）
- `rust/legado-ffi/src/api/web_book.rs:55-87`（`ffi_deps()`：共享客户端、限流、登录头、书籍变量、setup、媒体 sink）
- `rust/legado-ffi/src/api/web_book.rs:95-102`（`real_fetcher()` / `build_engine()`）
- `rust/legado-ffi/Cargo.toml:15`（`legado-fetcher` 已是 FFI 依赖）

结论：**已有完整实现可复用**。它不是“从零写规则引擎”，而是把 `legacy/source_check_api.rs` 中的检查核心（`check_source` / `check_book` / 会话与写回）从 `legado-server` 的 `AppState` 依赖中剥离，改为接收 `FetcherDeps` + `BookSource` + `CheckConfig`，即可被 FFI 直接调用。`legado-server` 侧继续使用 `server_deps`，FFI 侧使用 `ffi_deps`，两边共享同一份检查核心。

### 5.5 改成规则级需要的前置条件

1. **先定语义裁决（用户/产品）**
   - 是“对齐原版规则级校验”，还是“保留连通性冒烟但改名”？这决定是否修改 UI 文案、契约字段和状态含义。
   - 是否保留我方已有的每步超时/取消增强（原版是整源超时；我方当前是每步超时 + 整源预算，属于更细的语义），需要明确。
   - 是否保留“校验完成自动加失效分组”（原版不持久化分组），需要明确。
2. **契约先行（AGENTS.md 要求）**
   - 当前契约 §2.3（`docs/API_CONTRACT.md:553-555`、`:576`）冻结的 `CheckerConfig` 字段是 `keyword/step_timeout_ms/check_search/check_toc/check_content/detect_captcha/detect_redirect`。
   - 规则级对齐需要 `check_domain/check_search/check_discovery/check_info/check_category/check_content` 以及 `wSourceComment` 等配置面；要么加法式新增字段并保留旧字段兼容，要么做一次明确的契约变更（需更新 `docs/API_CONTRACT.md` 并协调 Dart/Rust 双轨）。
   - 结果字段也可能需要从 `search_ok/toc_ok/content_ok` 扩展为 `info_ok/discovery_ok/domain_ok` 或统一的 `steps` 结构；这会改变 Flutter 展示与落库口径。
3. **检查核心下沉**
   - 把 `legacy/source_check_api.rs` 的 `check_source`/`check_book`/`select_check_chapter`/`write_back_check_result` 及 `CheckOutcome`/`CheckConfig` 抽到共享 crate（例如 `legado-fetcher::source_check` 或独立 `legado-check`）。
   - 依赖只保留 `FetcherDeps`、`BookSource`、`BookSourceCheckStateRepository`（若保留状态写回）或回调；不要依赖 `legado-server::AppState`。
   - FFI 侧用 `ffi_deps()` 构造 `FetcherDeps`，直接调用共享检查核心；server 侧用 `server_deps` 调用同一核心。
4. **状态与写回语义决策**
   - 若对齐原版：FFI 批量校验需要在开始时 `begin_check`、完成时 `finish_check` CAS 写回 `book_source_check_states` + `respond_time`；UI 需要读取状态并支持筛选。
   - 若对齐参考版：只保留内存结果，不写状态表；但要接受“重启/重进页面后结果消失”的差异，并明确不宣称与原版状态语义一致。
5. **UI 对齐**
   - 增加/调整检查项：域名、发现、详情、目录、正文；保持“详情关闭→目录/正文禁用，目录关闭→正文禁用”的级联（原版 `CheckSourceConfig.kt:33-83`）。
   - 关键词默认“我的”、书源 `checkKeyWord` 覆盖、超时单位秒、提示文案、失败分组展示（原版 `detail` = 分组 + 消息 + `// Error:` 行）。
   - 并发数是否暴露为校验项：原版没有，复用全局线程数；我方若要暴露，需作为增强登记。
6. **行为边界**
   - 必须保留“校验只标记、不删源”的原版语义。若产品确实需要“清源”，应作为独立的、需用户确认的动作（例如“按状态筛选后手动删除”），不能把删除挂在 `checkSourcesStream` 的完成回调里。
7. **测试门禁**
   - 规则级用例：JS 单文件源、POST 搜索、`bookUrlPattern`、搜索列表为空、详情解析失败、目录为空、正文为空、发现分类为空、域名不可达、`checkKeyWord` 覆盖、无 `searchUrl`。
   - 超时/取消：单源卡死 + 取消 1s 内返回、整源超时、批量中途取消、结果不写回。
   - 状态机：`NEEDS_CHECK -> PASSED/FAILED/UNCHECKABLE` 的 CAS、源变更/删除导致结果丢弃。
   - 可复用 `legado-server` 已有测试：`rust/legado-server/tests/source_check_api_test.rs`，以及 `legacy/source_check_api.rs` 内置测试（`compose_detail`、`select_check_chapter`、`effective_keyword`、`session_guard` 等）。

### 5.6 建议

- **建议 A（推荐，语义对齐）**：本轮裁决按“规则级校验”处理，复用 `legacy/source_check_api.rs` 的完整实现；先冻结契约变更，再下沉核心到共享 crate，FFI 与 server 同源；UI 补齐检查项；保留“只标记不删源”。
- **建议 B（保守，改名）**：若产品明确只需要连通性快速筛查，则把功能/字段/UI 文案改为“连通性检查”（例如 `reachable_ok`），并在契约中删除“对齐 Kotlin CheckSource”的表述；不要用 `search_ok/toc_ok/content_ok` 误导用户。
- **不建议 C**：在现有简化实现上继续加“结果驱动清源”。原版和参考版都没有该行为，且简化结果假阳/假阴都高，会把好源误删。

---

## 附录 A：关键文件索引

### 原版（仓内 Kotlin，与上游逐字节一致）

- `app/src/main/java/io/legado/app/service/CheckSourceService.kt`
- `app/src/main/java/io/legado/app/model/CheckSource.kt`
- `app/src/main/java/io/legado/app/model/webBook/WebBook.kt`
- `app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt`
- `app/src/main/java/io/legado/app/data/entities/BookSource.kt`
- `app/src/main/java/io/legado/app/data/entities/BookSourcePart.kt`
- `app/src/main/java/io/legado/app/data/entities/BookSourceCheckState.kt`
- `app/src/main/java/io/legado/app/ui/config/CheckSourceConfig.kt`
- `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceActivity.kt`
- `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceAdapter.kt`
- `app/src/main/java/io/legado/app/api/controller/BookSourceCheckController.kt`
- `app/src/main/res/menu/book_source_sel.xml`、`app/src/main/res/menu/book_source.xml`
- `app/src/main/res/xml/pref_config_other.xml`
- `app/src/main/res/layout/dialog_check_source_config.xml`

### 参考版

- `legado-with-MD3/app/src/main/java/io/legado/app/service/BookSourceCheckService.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/data/repository/BookSourceCheckRepository.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/domain/gateway/BookSourceCheckGateway.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/domain/gateway/CheckSourceSettingsGateway.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/data/repository/CheckSourceSettingsRepository.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceScreen.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/source/manage/CheckSourceBottomSheet.kt`
- `legado-with-MD3/app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceViewModel.kt`

### 我方

- `rust/legado-net/src/source_checker.rs`
- `rust/legado-ffi/src/api/source_check_api.rs`
- `rust/legado-server/src/legacy/source_check_api.rs`
- `rust/legado-fetcher/src/web_book.rs`
- `rust/legado-core/src/web_book.rs`
- `rust/legado-ffi/src/api/web_book.rs`
- `flutter_legado/lib/src/providers/source_check/check_source_notifier.dart`
- `flutter_legado/lib/src/providers/source/source_notifier.dart`
- `flutter_legado/lib/src/screens/source_screen_actions.part.dart`
- `flutter_legado/lib/src/screens/source_screen_builders.part.dart`
- `flutter_legado/lib/src/screens/other_settings_screen.dart`
- `docs/API_CONTRACT.md`

## 附录 B：复核命令

```bash
# 原版与上游是否一致
cd D:/OH-WorkSpace/LegadoTeam
diff -q legado-upstream/app/src/main/java/io/legado/app/service/CheckSourceService.kt \
        legado/app/src/main/java/io/legado/app/service/CheckSourceService.kt

# 原版是否执行规则链
grep -n "AnalyzeUrl\|searchBookAwait\|getBookInfoAwait\|getChapterListAwait\|getContentAwait" \
  legado/app/src/main/java/io/legado/app/service/CheckSourceService.kt \
  legado/app/src/main/java/io/legado/app/model/webBook/WebBook.kt

# 原版是否按结果删源/禁用
grep -rn "checkStatus\|completeCheck" legado/app/src/main/java/io/legado/app

# 我方当前实现
grep -n "extract_first_href\|build_search_url\|client.get" \
  legado/rust/legado-net/src/source_checker.rs

# 可复用的规则级实现
grep -n "webbook_search\|webbook_info\|webbook_chapters\|webbook_content" \
  legado/rust/legado-server/src/legacy/source_check_api.rs
```

---

## 声明

- 本报告为静态代码核验，未运行 Rust/Kotlin/Flutter 测试，未在模拟器上验证 UI 行为；行号以当前工作区文件为准。
- “原版不存在自动删源”是对当前 `legado-upstream` HEAD 和仓内 Kotlin 的代码事实判断；不排除未来上游新增该行为。
- 报告只陈述证据与差异，不对产品语义做最终裁决；§5.6 的 A/B 选项需要用户/主代理确认。
