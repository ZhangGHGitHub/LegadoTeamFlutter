# iOS 实机搜索失败清单——JS 引擎错误逐条定性报告

- 日期：2026-10-06
- 调研代理：调研员（只读调研）
- 判定基线：原版 Android Rhino 引擎（`app/src/main/java/io/legado/app/`，Rhino 语义 = 基线）vs 我方 QuickJS 引擎（`rust/legado-js/` + `rust/legado-ffi/src/`）
- 范围：iOS 实机（QuickJS 路径）搜索失败清单中剩余 19 个 JS engine error 的归并去重后的 15 条形态

---

## 一、结论摘要

15 条形态中：
- **引擎缺陷（需修复）**：3 条（1+2 号 source 绑定窗口、3 号 host API 严格入参转换、11 号 interrupted 时间预算语义差异）
- **平台限制（既有登记，保持现状）**：1 条（13 号 Packages.java.util.concurrent.locks）
- **语义差异但判书源问题（Rhino 宽容 vs 规范 TDZ，已登记）**：1 条（9 号）
- **书源质量问题（原版同样失败）**：10 条（4、5、6、7、8、10、12、14、15 号及 13 号的根因侧）

关键发现：
1. `source` 绑定在我方**两类上下文均已注入**（searchUrl 窗口 + bookList 规则窗口），但注入形态是 **globalThis 属性 + `Object.assign({}, sourceJson)` 快照对象**，与原版 Rhino 绑定 **Kotlin BaseSource 活对象**（支持任意 `source.xxx` 配置字段）存在覆盖面差异——书源若访问快照外的字段（如 `source.header`、`source.customOrder` 等 JSON 之外的运行时字段）仍可能 undefined。1/2 号的直接原因更可能是**书源在 searchUrl JS 顶层对 `source` 做 `let { source } = this` 解构或直接裸引用，而其实际报错点位（`<input>:12:139` / `<input>:1:19`）落在脚本中段**，属执行序问题：我方 jsLib eval 失败时「降级继续」，书源函数缺失后才轮到脚本裸引用 `source`；原版 jsLib 失败会直接抛「下载jsLib失败」。
2. `interrupted`：我方 QuickJS 有 **5 秒/次 eval 的 wall-clock 中断预算**（默认 SandboxConfig）；原版 Rhino **没有任何时间预算**，只有协程取消（instructionObserverThreshold=10000 观察点检查 `coroutineContext.ensureActive()`）+ 递归深度 10。**语义不对齐**：原版同一段死循环/正则回溯会永久挂起直到外层 30s 搜索超时，我方则 5s 即中断。11 号定性为「我方保护机制按设计触发」，但它把原版的「挂到超时」变成「中断报错」，**错误文案不可读**（裸 "interrupted"），建议改进文案而非调预算。

---

## 二、双侧行为对照（按上下文）

### 2.1 searchUrl JS 窗口的绑定集合

**原版**（`AnalyzeUrl.evalJS`，`app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt:377-406`）：

| 绑定名 | 值 | 行号 |
|---|---|---|
| `java` | AnalyzeUrl 实例（this） | :379 |
| `baseUrl` | baseUrl | :380 |
| `cookie` | CookieStore | :381 |
| `cache` | CacheManager | :382 |
| `page` | page | :383 |
| `key` | **搜索关键字** | :384 |
| `speakText` / `speakSpeed` | TTS 参数 | :385-386 |
| `book` | ruleData as? Book | :387 |
| `source` | **BaseSource 活对象** | :388 |
| `result` | 前段结果 | :389 |
| extraParams 逐项 + `infoMap` | :390-393 |

作用域链：`source.getShareScope()`（= jsLib 编译进共享 scope，`BaseSourceExtensions.kt:13-15`，`SharedJsScope.kt:103-124`）→ 无 jsLib 时退 `SharedJsScope.getCryptoScope()`（CryptoJS）→ 都无则 `RhinoScriptEngine.getRuntimeScope`（全新标准对象）。**jsLib 在 searchUrl JS 里可用（父作用域链）**。

**我方**：
- 变量注入：`legado-fetcher/src/js_adapter.rs:184-251`（`build_search_url_with_setup`）注入 `key/page/baseUrl/searchKey` 四个字面变量（:201-205）；`legado-parser/src/analyze_url.rs:1186-1207`（`js_variable_prologue`）以 `globalThis.<name> = <json>` 属性注入（#850 修复，不注册全局 var）。
- 书源上下文：`legado-js/src/executor.rs:61-203`（`QuickJsExecutor::execute_js`）每次执行先 eval jsLib（:82-145，失败**降级继续**并记台账 `record_jslib_load_failure`）再 eval setup（:146-153）。
- `source` 绑定：`legado-fetcher/src/source_setup.rs:70-74`——`globalThis.source = Object.assign({}, __srcData)`（BookSource 的 **serde JSON 快照**）、`globalThis.baseUrl/sourceUrl/loginUrl` 同处；`source.getKey()/key/put/get` 等方法面在 `__mountBookSourceApi`（:149-234）。
- searchUrl 主路径确实带 setup：`legado-ffi/src/api/search.rs:1197-1208`（`book_source_js_setup_script(source)` 传入 `build_search_url_with_setup`）。

**对照结论**：`source` 在两类上下文（searchUrl 窗口 + bookList 规则窗口，后者见 `web_book.rs:1599-1606` 与 `search.rs:1432-1439`）**均已注入**。绑定集合差异：
- 我方缺 `speakText/speakSpeed/chapter/rssArticle/title/src/nextChapterUrl` 等（原版 AnalyzeUrl.kt:385-386 与 AnalyzeRule.kt:895-911 的规则窗口绑定）——搜索场景影响面小。
- 我方 `source` 是 JSON 快照（字段仅限 BookSource 序列化字段）+ 手工方法面；原版是 Kotlin 活对象（可访问全部配置字段与方法）。
- 我方 jsLib eval 失败**降级继续**（executor.rs:111-144），原版 `SharedJsScope.evaluateJsLib` 失败**直接抛**（`SharedJsScope.kt:251`「下载jsLib-xx失败」/ :258 eval 异常上抛）→ 我方把失败推迟到脚本里某个 `source`/库函数引用点才爆出，**错误点位后移且文案失真**。

### 2.2 搜索结果列表规则 JS 窗口的绑定集合

**原版**（`AnalyzeRule.evalJS`，`AnalyzeRule.kt:893-932`）：`java/cookie/cache/source/book/result/baseUrl/chapter/title/src/nextChapterUrl/rssArticle/fromBookInfo`（:895-907）+ 局部 `paraIndex/paraData/page`（:908-910）。**`source` 在绑定里（:898）**；scope 同样链到 jsLib 共享作用域（:913-915）。

**我方**（`legado-parser/src/analyze_rule.rs:1561-1715` `execute_js_rule_inner`）：prologue 注入 `result/src/baseUrl`（:1639-1647）+ `js_bindings` 追加（:1649-1652）+ java.put/get 会话变量桥（:1668-1685）+ 裸赋值变量预置（:1602-1603）。`source` 经 `construct_analyzer_with_source_context`（`legado-fetcher/src/js_adapter.rs:83-96`）的 setup 脚本注入（同 2.1 的 source_setup.rs:74）。

---

## 三、逐条定性表

| # | 书源 | 错误形态 | 定性 | 依据（双侧行号） |
|---|---|---|---|---|
| 1 | 禁漫天堂API | `source is not defined (input:12:139)`，bookList JS | **引擎缺陷（轻）+ 书源依赖**：`source` 已注入（source_setup.rs:74），但为 JSON 快照；若脚本访问快照外成员（如 `source.getHeaderMap()` 等未挂载方法）或 jsLib 先行失败降级导致引用点后移，仍会 ReferenceError | 原版 AnalyzeRule.kt:898 绑活对象；我方 analyze_rule.rs:1649-1652 仅透传 js_bindings；jsLib 失败降级 executor.rs:111-144 vs 原版 SharedJsScope.kt:251 直接抛 |
| 2 | 雨鹿小说 | `source is not defined (input:1:19)`，searchUrl JS | 同上同性质：`<input>:1:19` 在行首附近，倾向 jsLib 加载失败降级后 `source` 引用点后移；**需实机台账（capability ledger `executor:<tag>`）确认 jsLib 是否加载失败** | search.rs:1197-1208 已带 setup；executor.rs:146-153 setup 失败也降级 |
| 3 | 晋江文学 | `Error converting from js 'array' into type 'string'` | **引擎缺陷**：rquickjs 宿主 API 严格 `String` 入参签名拒收数组；Rhino LiveConnect 对入参做 `Context.toString` 宽松转换（数组→逗号连接字符串） | 错误文本来源 rquickjs `Error::FromJs`（html_parse.rs:585-590 同构）；既有同类修复先例：quickjs_impl.rs:41-64（NullStr/NullBool 可空入参）、:1460、:4009、:5165（null 入参修复）；engine 层返回值已宽松（engine.rs:443-454 result_to_string：Object/Array→JSON.stringify）——**问题在宿主 API 入参方向** |
| 4 | 飛天小說 | `not a function (at getSign (eval_script:22:37))` | **书源问题**：`getSign` 已被找到并进入（有函数名栈帧），是函数体内 22 行 37 列的某个调用目标不是函数（多半是 Rhino 特有 API / Packages 成员被 sanit 截除或依赖 Java 类） | jsLib 已注入：executor.rs:82-145；Rhino 行清洗 js_adapter.rs:306-321（importClass/importPackage/Packages. 行首整行删除——**若 getSign 函数体内的 Packages 行被整行删除会改变行号与语义**，此处确有我方清洗策略引入的失真风险，定性「书源依赖 Java 能力，边界情况」） |
| 5 | 全本小说 | `cannot read property '1' of null (input:3:9)` | **书源问题**：对 null 取下标，Rhino 同样抛 `TypeError: Cannot read property "1" from null` | 原版无 null 宽容（Rhino 语义一致）；我方 engine.rs:539-544 原样上抛 |
| 6 | 笔趣阁/新落秋 | `cannot read property 'join' of null (input:8:8)` | **书源问题**：`null.join()`，原版同样抛 | 同上 |
| 7 | 夜寒书库 | `cannot read property '1' of null (input:6:5)` | **书源问题**：同 5 | 同上 |
| 8 | 艾格动漫 | `cannot read property 'select' of undefined (input:5:73)` | **书源问题**（对 undefined 取属性）；注：我方元素对象**已有** `select(sub)` 方法面（html_parse.rs:518-580 build_element_object），非缺口 | 原版 Rhino 元素为 Native Java Object 同样支持 select，但 undefined 本身无 select——两边一致 |
| 9 | 爱巴士 | `key is not initialized (input:5:26)` | **语义差异已登记 → 判书源问题**：书源 `let key = java.encodeURI(key)` 自引用 TDZ。Rhino 宽容（let 自引用读到绑定前的值/前置 key 绑定），QuickJS 是**规范 TDZ**。已在 `legado-ffi/tests/prologue_collision.rs:128-155`（#850）定案并修复引擎侧 redefinition 冲突，剩余 TDZ 为规范行为 | 原版 AnalyzeUrl.kt:384 `key` 绑定为 Rhino var 语义；我方 analyze_url.rs:1199-1203 属性注入 + Function-eval 隔离 |
| 10 | 繁星小说 | `sign is not defined (input:4:55)` | **书源问题（大概率）**：`sign` 未在任何绑定/jsLib 中定义；原版 Rhino 同样 ReferenceError。**需实机确认该书源 jsLib 是否定义 sign 且加载失败**（executor 台账） | 同 1/2 的 jsLib 降级链 |
| 11 | 八一中文网 | `interrupted (at exec (native) ... [Symbol.match] (native))` | **我方保护机制按设计触发，但语义与原版不对齐 + 文案不可读**：QuickJS 5s wall-clock 中断（engine.rs:379-387 + sandbox.rs:287-299 default 5s；书源路径 executor.rs:75-79 用 default+allow_script_run+64MB）；原版**无时间预算**（RhinoScriptEngine.kt:294 instructionObserverThreshold=10000 仅做协程取消检查点，RhinoContext.kt:336-343 ensureActive；:345-350 递归≤10）——原版会挂到外层 30s 搜索超时（原版 WebBook 搜索超时），不会中途报 interrupted。`[Symbol.match](native)` 说明正则回溯爆炸/超长串匹配被掐断 | 中断实现 engine.rs:345-426；预算 5s（sandbox.rs:290）；原版对比 RhinoScriptEngine.kt:314-318 |
| 12 | 宜搜小说 | `not a function (input:4:11)` | **书源问题（大概率）**：调用目标不是函数；`eval_script` 栈帧缺失说明非 jsLib 内（对比 4 号有 `getSign` 帧）→ 是书源 searchUrl/bookList JS 自身调了不存在的方法（或依赖我方未覆盖的 java.* 面——**需台账确认 reportUnknownSymbol**） | 同 4 的 jsLib 注入面；java.* 覆盖面 quickjs_impl.rs:73-130 |
| 13 | 69書吧 | `此书源需要 Java 脚本能力（Packages.java.util.concurrent.locks）` | **平台限制（既有登记）**：Packages 模拟层哨兵按设计抛出并登记台账（quickjs_impl.rs:537-565 makeUnknownClassSentinel + :539 文案 + java.reportUnknownSymbol）。`java.util.concurrent` 未在模拟层覆盖面（quickjs_impl.rs:587-... 仅 lang/部分类）。原版 Rhino 有完整 Java 桥（modules/rhino 全套 NativeJavaObject） | 哨兵：quickjs_impl.rs:537-565；台账：host_api/capability_ledger.rs（record_jslib_load_failure/reportUnknownSymbol）；**已是明确登记，无需新增** |
| 14 | 顾淮小说 | `cannot read property 'bid' of undefined` | **书源问题**：红薯系 `{{$.bid}}` 内嵌规则展开依赖 JSON 元素结构；元素无 bid 字段（站点返回空/改版）时 undefined。原版同样 undefined | `{$.bid}` 展开 analyze_rule.rs:1566-1574 + 测试 :3338-3344 |
| 15 | 猫眼看书 | `builder error for url (data:;base64,...)` | **书源问题 + 我方缺陷边缘**：searchUrl 为 `data:;base64,...`（**空 mime 形态**）。我方 data URI 解码逻辑在 fetch_page 优先分支（web_book.rs:1007-1024）要求 base64 可解码，解码失败抛 Internal；但错误文案「builder error for url」说明请求层把 data: URL 直接喂给了 reqwest（URL 不可解析 → reqwest builder error）。**疑点**：`data:;base64,`（无 mime）是否被 `is_data_uri`（analyze_url.rs:1560）正确识别——原版 `getByteArrayIfDataUri`（AnalyzeUrl.kt:666-677 + AppPattern.kt:20 `^data:.*?;base64,(.*)`）对空 mime 同样匹配；我方 analyze_url.rs:835-864 split 逻辑对 `data:;base64` 应该也命中（meta 含 base64）。若实机错误确实来自 reqwest，说明该形态在某个分支（如 searchUrl 模板→analyze_url 构建后 rule_url 判定）漏判——**列为待复现的低优先缺陷** | 原版 AnalyzeUrl.kt:666-677；我方 web_book.rs:1007-1024、analyze_url.rs:826-864；reqwest builder error 既有登记 misc_api.rs:141 |

### 3.1 定性汇总

- **引擎缺陷（值得修）**：3 号（host API 严格入参→按 Rhino 宽松转换）、11 号（interrupted 文案/预算语义登记，见下）、15 号（data:;base64 空 mime 形态，低优先待复现）
- **引擎缺口（登记性质，需数据佐证）**：1、2 号（source 快照覆盖面 + jsLib 降级链导致错误点位失真——修复方向是「jsLib 失败不再静默降级，而是带原因上抛」，工作量小）
- **书源问题**：4、5、6、7、8、10、12、13（根因侧）、14
- **语义差异已登记**：9 号（#850 TDZ，终审已定案）

---

## 四、`interrupted` 机制专项结论（任务 3）

- **预算值**：书源路径实际用 `SandboxConfig::default().with_allow_script_run(true).with_memory_limit(64MB)`（executor.rs:75-79），`max_execution_time` 保持 default = **5 秒**（sandbox.rs:287-299）。permissive() 是 30s（sandbox.rs:223-233）但书源主路径**未用**。
- **触发条件**：每次 eval 前 `reset_deadline`（engine.rs:417-426）设 `now+5s` 绝对 deadline；中断处理器在每条 JS 指令间检查 `elapsed > deadline`（engine.rs:379-387）→ 返回 true 中断 → QuickJS 抛错，rquickjs 侧错误对象非标准 Exception → `take_exception_message` 退化输出裸词 **"interrupted"**（engine.rs:520-545：非 Error 对象时取字符串表示，interrupt 中断的异常不是 Error 实例）。
- **与原版对比**：原版 Rhino **无任何时间预算**。中断只有两种：协程取消（`observeInstructionCount` 检查点 → `ensureActive`，RhinoScriptEngine.kt:294/314-318；阈值 10000 条指令一查）与递归深度 >10（RhinoContext.kt:345-350）。单源搜索挂死时由**外层协程超时**（原版搜索 30s 口径）兜底取消。
- **判定**：11 号书源的正则在 5s 内跑不完 → 我方按设计中断。**不是预算过紧**（5s 足够覆盖正常书源；原版同场景是无限挂起直到 30s 超时，体验更差）。**改进点**：① 中断错误文案不可读，建议在 engine.rs take_exception_message 检测 `interrupted` 标志（engine.rs:425 interrupted AtomicBool）时输出「JS 执行超时（5s），可能存在正则回溯爆炸/死循环」；② 若追求原版「让外层超时兜底」的语义，可将书源路径 timeout 提到 30s（permissive 同款），但会增加单源最坏挂起时间——建议只改文案，不改预算。

---

## 五、修复优先级建议

| 优先级 | 项 | 动作 | 涉及文件 | 预估 |
|---|---|---|---|---|
| P0 | 3 号 array→string | 宿主 API 入参统一走 `NullStr`/宽松 `FromJs` 收敛（数组→`join(',')` 或 `String(x)`，对齐 Rhino `Context.toString`）；先盘点 `quickjs_impl.rs` 中所有裸 `String` 入参签名 | rust/legado-js/src/host_api/quickjs_impl.rs（:41-64 模式推广）、register.rs | 0.5-1 天（含回归） |
| P0 | 1/2 号 jsLib 降级链 | jsLib/setup eval 失败改为「首次真 JS 求值时带原因上抛」而非静默降级（或至少把台账原因附加到最终错误文案） | rust/legado-js/src/executor.rs:111-153 | 0.5 天 |
| P1 | 11 号文案 | interrupted → 「JS 执行超时(5s)」可读文案；登记与原版的预算语义差异 | rust/legado-js/src/engine.rs:520-545 + interrupted 标志 | 2 小时 |
| P2 | 15 号 data:;base64 | 实机复现后修 `is_data_uri` 对空 mime 的判定/分支遗漏 | rust/legado-parser/src/analyze_url.rs:826-864,1552-1560 | 复现 0.5 天 + 修 2 小时 |
| 不修 | 5/6/7/8/12/14 号 | 书源健壮性问题，原版同样失败 | — | — |
| 不修 | 9 号 | TDZ 为规范行为，#850 已终审定案（prologue_collision.rs:128-155） | — | — |
| 不修 | 13 号 | 平台限制既有登记，哨兵+台账按设计工作 | quickjs_impl.rs:537-565 | — |

---

## 六、证据索引（关键文件）

原版：
- `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt`：evalJS 绑定 :377-406；key 参数 :84；data URI :666-677
- `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt`：evalJS 绑定 :893-932
- `app/src/main/java/io/legado/app/help/source/BaseSourceExtensions.kt`：getShareScope :13-15
- `app/src/main/java/io/legado/app/model/SharedJsScope.kt`：jsLib 加载 :103-124, :231-260（失败即抛 :251/:258）
- `app/src/main/java/io/legado/app/model/webBook/WebBook.kt`：搜索入口 :51-105
- `modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt`：无时间预算，观察点 :294, :314-318
- `modules/rhino/src/main/java/com/script/rhino/RhinoContext.kt`：ensureActive :336-343；checkRecursive :345-350

我方：
- `rust/legado-fetcher/src/js_adapter.rs`：build_search_url_with_setup :184-251；sanitize :306-321
- `rust/legado-fetcher/src/source_setup.rs`：source/baseUrl 注入 :70-74；__mountBookSourceApi :149-234
- `rust/legado-fetcher/src/web_book.rs`：search 主流程 :1506-1626；bookList JS 上抛包装 :4178-4195；data URI :1007-1024
- `rust/legado-ffi/src/api/search.rs`：searchUrl 带 setup :1197-1208；bookList 带 setup :1432-1439
- `rust/legado-js/src/executor.rs`：jsLib+setup 注入与降级 :61-203；沙箱选择 :74-79
- `rust/legado-js/src/engine.rs`：中断 :345-426；result_to_string :443-454；异常提取 :520-545
- `rust/legado-js/src/sandbox.rs`：预算 default 5s :287-299
- `rust/legado-js/src/host_api/quickjs_impl.rs`：NullStr :41-64；Packages 哨兵 :537-565
- `rust/legado-js/src/host_api/html_parse.rs`：元素对象 select :518-580
- `rust/legado-parser/src/analyze_url.rs`：变量 prologue :1186-1207；data URI :826-864
- `rust/legado-parser/src/analyze_rule.rs`：JS 规则执行 :1561-1715；{{$.bid}} :1566-1574
- `rust/legado-ffi/tests/prologue_collision.rs`：#850 爱巴士 TDZ 定案 :128-155

## 七、未决事项（需实机数据）

1. 1/2/10 号：拉取 `capability_ledger` 中 `executor:<source_tag>` 的 jslib_load_failure 记录，确认 jsLib 是否加载失败（决定 1/2 号最终归「引擎缺口」还是「书源问题」）。
2. 12 号：查台账 reportUnknownSymbol 是否有宜搜源的未覆盖 java.* 符号。
3. 15 号：需实机复现 `data:;base64,`（空 mime）形态在哪个分支漏判进 reqwest。
