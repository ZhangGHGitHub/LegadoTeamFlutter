# iOS 引擎错误修复批（4 提交）独立代码审查报告

- 日期：2026-10-06
- 审查代理：独立代码审查员（只读，不改被审代码；本报告为唯一产出文件）
- 审查对象：`70fe279b7b`（P0-A 宿主入参宽松转换）、`e73cf37d8f`（P0-B jsLib 失败上抛）、`ba8ad0694e`（P1-C interrupted 文案 + explore data URI）、`fd04ee1154`（data URI 空 mime 补漏）
- 语义基线：原版 Rhino（`app/src/main/java/io/legado/app/`）；分析依据 `docs/SEARCH_JS_ENGINE_ERROR_ANALYSIS_20261006.md`
- 验证方式：静态审读 + rquickjs 0.12.2 源码核对（cargo registry 本地源）+ **真实执行红绿双向验证**（git worktree 于改前 `599ceff71d` 实跑三测试文件 → 红；HEAD 实跑 → 绿；跑后 worktree 已清理，工作区恢复原状）

---

## Summary: pass（可合并，附 2 项建议修复 + 3 项可选）

未发现阻塞性（P0 级）缺陷。四批修复的机制、完整性与行为证据均经独立核实；有意偏差均有登记且方向为「比 Rhino 更宽容」。遗留问题为证据留存（Rhino 探针无仓库物证）与少量边缘语义，不构成合并阻塞。

---

## 一、重点项逐条结论（对应用户审查项 1–11）

### 1. Rhino 语义对齐的可靠性（P0-A）

**探针证据留存：未在仓库找到探针源码或原始输出，属代理自述 + 二次转述。**

- 已核查：`docs/SEARCH_JS_ENGINE_ERROR_ANALYSIS_20261006.md`（无探针记录，仅定性）、`docs/REFACTORING_ACTIVE_PLAN.md`、`docs/RHINO_INTEROP_ANALYSIS_20260920.md`、`.zcode/plans/`、`rust/`、`third_party/`——均未找到 JDK17 探针的 Java 源码或运行输出。
- 引擎 JAR 本身在仓库：`third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar`，即「探针所用引擎与原版一致」这一前提可复核，探针结果本身不可复核。
- 唯一留存物是 `rust/legado-js/src/host_api/coerce.rs:20-33` 的转换表（数组→join(',')、嵌套递归、`[object Object]`、自定义 toString、`undefined`→"undefined"、null→Java null）与 `rust/legado-js/tests/host_api_array_arg.rs` 的行为锁定。表内容与 Rhino LiveConnect 公认语义（ScriptRuntime.toString）一致，无反常识条目。
- 结论：语义表可信度尚可（与规范 ToString 语义吻合），但「探针实测」目前不可复核。**建议（P1）**：补交探针源码/输出入库或改为引用 Rhino 源码行号佐证。

**`coerce.rs` 实现与声称一致性：已逐行核实一致。**

- `RhinoStr` = `rquickjs::Coerced::<String>` 包装（coerce.rs:38-46）。Coerced\<String\> 内部走 `qjs::JS_ToString`（rquickjs-core-0.12.2 `src/value/convert/coerce.rs:32-41`），即 JS 规范 ToString——数组 `[1,2]`→"1,2"、对象→"[object Object]"、自定义 toString 会调用，与声称吻合。
- `RhinoOptStr`：null/undefined→None，其余 Coerced（coerce.rs:85-110），与声称一致。

### 2. 有意偏差的实际风险：低，判断成立

三处偏差（coerce.rs:35-37、quickjs_impl.rs:89-91）：

- 标量 null→`"null"`（Rhino 为 Java null→Kotlin 非空形参 NPE）：要造成行为差异，书源须**故意**传 null 给非空 String 形参并依赖其 NPE 分支。NPE 在 Rhino 中会以「Java 异常包装」冒泡终止本次规则求值——书源依赖它做分支几乎不可能（规则语言没有 try/catch NPE 的惯用法，且原版该路径就是失败）。既有先例 `tests/uri_component_coercion.rs`（`null→"null"`）已在生产运行一段时间，无回归记录。
- 数组元素 null/undefined→空串（Rhino 元素为 Java null/"undefined"）：偏差方向是宽容侧；最坏情形是把原版会失败的调用变成「多一个空 URL 条目」。空串 URL 在 `ajaxAll` 下游为请求失败条目（返回空响应体），不产生错误行为升级。
- 整体 null/undefined→空列表：同理，原版为 NPE/「方法不存在」失败。
- **判断**：三处偏差均只会把原版的「失败」变成「空/宽松成功」，不存在「原版成功 → 我方结果不同」的路径。风险评级 LOW，接受。

### 3. `RhinoOptStr` 只实现 `FromParam` 的正确性：机制成立，多参仍正确拒绝

对 rquickjs-core-0.12.2 源码逐点核实：

- 调用序：`Function::new` 闭包先 `params.check_params(F::param_requirements())` 再 `f.call`（`src/value/function.rs:50-54`）。arity 检查**先于**任何参数转换。
- `ParamRequirement::optional()` = `{min:0, max:1, exhaustive:false}`（params.rs:189-196）。
- 多参场景：函数 `(RhinoStr, RhinoOptStr)` 的合并 requirement 为 min=1、max=2。JS 传 3 参 → `check_params` 因 `max=2 < 3` 报 `Error::MissingArgs`？否——非 exhaustive 时超参**不报错**（params.rs:50-65 仅 exhaustive 分支检查 TooManyArgs），多余参数被静默丢弃。这与改前 `Opt<String>` 的行为**完全一致**（Opt 的 requirement 同为 optional），非本批引入的语义变化。
- 少参场景：`from_param` 内 `params.is_empty()` 为真时返回 None（coerce.rs:95-98），不触发 `arg()` 断言。若用 `FromJs` blanket impl（param_requirement=single，min=1），少参会报 `MissingArgs`("N argument(s) while M where expected")——代理对机制的解释与源码一致。
- 「吞掉参数个数错误」的路径：不存在新增路径。既有 `Opt<T>` 本来就是同款 optional 语义；`ParamsAccessor::arg()` 的 panic 路径（params.rs:145-151「arg called too many times」）被 `is_empty` 先行判断规避，且 requirement 合并约束下 from_params 的消耗次数 ≤ min+max ≤ 实参数，不可达。
- 结论：机制正确，无回归。唯一注意点见下「W-2」。

### 4. `LooseStrList` 与 Rhino `String[]` 形参的对照：自述存在一处内部张力，实现自洽

- 张力点：`quickjs_impl.rs:86-92` 自述「整体 `undefined`：探针为『方法不存在』错误」，而探针又称标量 `String` 形参收 undefined 是「"undefined" 字面量」。两者其实**不矛盾**：Rhino 对 `Array<String>`（非 String）形参的成员匹配规则与标量 String 不同——undefined 传给数组形参时 Rhino 的方法解析（对参数类型的 signature 匹配）会失败，报「方法不存在」；传给 String 形参才做 toString。这正是探针结论的合理解读，且原版 JsExtensions 只有 `ajaxAll(urlList: Array<String>)` 一个签名，undefined 实参在原版确实报「方法不存在」。
- 我方实现：整体 null/undefined→空列表（比原版的「方法不存在」更宽容，方向一致）；数组→元素逐项 ToString→JSON 数组文本（quickjs_impl.rs:96-116）。JSON 数组文本而非逗号串是**必要的内部适配**（`network::ajax_all` 以 `serde_json::from_str::<Vec<String>>` 消费，network.rs:725-741），文档已如实登记为内部表示差异。
- 遗留语义差（登记为可选观察）：书源传**逗号分隔字符串**给 ajaxAll 时，原版 Rhino 会因 String≠Array 报「方法不存在」，我方则透传该字符串→`serde_json` parse 失败→返回 `[ERROR] ajaxAll parse error: ...` 文本（quickjs_impl.rs:2658-2661 以 `[ERROR]` 前缀吞掉）。两者都失败，失败形态不同（错误文本 vs 异常），无行为升级。

### 5. P0-B 硬失败回归面

**a) sanitize 链路回归面：不成立（无真实回归面）。**
判据：`sanitize_js_lib_for_quickjs`（`rust/legado-fetcher/src/js_adapter.rs:306-321`）只做**行首** `importClass(`/`importPackage(`/`Packages.` 整行删除，其余逐行原样保留（含换行数不变）。三种后果逐一排除：

1. 删除行致语法错误：被删的是完整行，前后行独立成句时语法不变。若书源把 `Packages.` 行写成多行表达式的**续行**（前行以 `.` 或运算符结尾），删除会致语法错误——但该 jsLib 在原版语法合法、我方删除后语法错误会被 `check_syntax`→`jslib_normalize::normalize` 归一化兜底尝试；归一化不改「行缺失」类错误，最终走 `jsLib 求值失败` 上抛。此时**原版能跑（Rhino 有真 Java 桥）而我方硬失败**——这是理论回归面，但触发条件要求 jsLib 存在「以 Packages 行为续行的多行表达式」，属畸形写法；916 源语料既有的 sanitize 已按同一策略删除这些行（本批未改 sanitize），此前这些源在「降级继续」下同样用不了被删行之后的依赖。升级仅是「错误文案从引用点失真变为 jsLib 根因」，对用户是改善。**结论：sanitize 不会把「原版能过、我方此前也能过」的 jsLib 变成硬失败**——凡被 sanitize 改动语义的 jsLib，其被删行在 QuickJS 下本来就必然失败（importClass 是 QuickJS 未定义标识符）。
2. 删除行不产生语法错误：jsLib 其余部分完整 eval，与改前一致。
3. sanitize 后 eval 成功：js_lib_ok=Some(true)，上抛路径不可达。

另核实 `js_adapter.rs` sanitize 后才进 executor（web_book.rs:1321/1609/2124/2271/3510、explore_api.rs:609），executor 看到的已是清洗后文本，台账键与缓存键同源（`executor:<source_tag>`，executor.rs:104/132 vs capability_ledger.rs:89），`last_jslib_error` 取回的 reason 与 key 一致（capability_ledger.rs:112-117 同一 truncate 口径）。

**b) URL 映射 jsLib 路由修复：正确。**
- `parse_js_lib_url_map`（jslib_loader.rs:59-74）判定「JSON 对象且全部值为字符串」；非映射形态不受影响（`var x = 1;` → None，模块单测 ：239 锁定）。
- executor.rs:183-192 映射形态强制走 fresh；映射 JSON 不再进 `init_engine` 的原样 eval（engine_cache.rs:61-67 对 jsLib 无脑 eval，正是误报源）。
- 测试 `url_map_jslib_routes_to_fresh_path` 在改前基线实测红（`urlMapLib is not defined`——旧缓存路径把 JSON eval 失败降级，库函数缺失），改后绿，钉死该路由。
- 边缘：映射形态走 fresh 意味着**每次**求值重建引擎+重新拉取映射（进程缓存可挡重复网络）。语料中映射形态源极少（cap 3 专项），可接受。

**c) 硬失败整体回归面（非 sanitize 部分）**：jsLib 语法错误仍有 `jslib_normalize` 兜底（executor.rs:118-131、engine_cache.rs:86-103），运行时错误才上抛——与原版 `SharedJsScope.evaluateJsLib` 失败直接抛（SharedJsScope.kt:251/:258）同口径。B1 决策（脚本不用库函数也上抛）与原版一致且有显式测试锁定（jslib_failure_visible.rs:84-93）。**接受。**

### 6. P1-C：interrupted 文案与预算

- 文案：`interrupted_message`（engine.rs:533-539）+ `exception_message`（:543-547）按 `interrupted` AtomicBool 优先输出可读文案；三个 eval 入口（:598/:617/:632）全部接线。基线实测裸 `interrupted`，改后文案含「脚本执行超时被中断」「100 ms」——预算值运行时读 `SandboxConfig`，非硬编码。
- 预算未动：`SandboxConfig::default()` 的 `max_execution_time` 仍为既有值（sandbox.rs:210/236/249 三档，default=5s 书源路径、permissive=30s、restricted=3s），四个提交 diff 均未触碰。
- 误判风险：中断 handler 只在「now > deadline」时置位（engine.rs:381-388）；`reset_deadline` 每次 eval 前**复位标志**（engine.rs:425-427），故其它异常（TypeError 等）不会误标为超时；`check_syntax_in_ctx` 走独立 Runtime 无标志，不受影响（:542 注释与实现一致）。逻辑闭合。
- 一个理论瑕疵（未构成缺陷）：同一引擎实例上，若 eval A 超时中断后**未再 reset** 就读标志——实际所有 eval 路径都先 reset，不可达。

### 7. data URI 三批改动

- **`send_raw`/`send_text` 短路影响面**：全仓调用方 4 处——search.rs:1264（搜索，15 号直接受益）、web_book.rs:1050（hex 分支）/1079（raw 分支，经 fetch_page）、dict_api.rs:407。fetch_page 已有自身 data URI 优先分支（web_book.rs:1022-1037），在其之前返回，短路代码不改变 fetch_page 的 data URI 行为（重复但一致，见下）。dict_api 的 data URI 此前会 builder error，现在本地解码——是修复而非回归。「依赖 data: 走网络报错语义」的调用方：未找到（data: 进 reqwest 在我方历来是 builder error 缺陷，无任何分支依赖它）。
- **非法 data URI 报错口径**：解码失败统一 `Internal("data: URI 内容解码失败")`（analyze_request.rs data_uri_body / web_book.rs:1035 / explore 路径同），不退化进 reqwest，与 fetch_page 现状一致。
- **`urlOption.type` 非空→hex**：对齐上游 `getStrResponseAwait` 的 `type != null → HexUtil.encodeHexStr(getByteArrayAwait())`（AnalyzeUrl.kt:442-444，提交信息与 analyze_request.rs 模块注释登记），并有 `test_p2_15_send_raw_empty_mime_type_option_returns_hex` 钉死。
- **explore 路径（ba8ad0694e）与 fetch_page 既有分支关系**：`data_uri_content_of`（web_book.rs:858-874）由原 `fetch_data_uri_content` 提取泛化，**单一真源**；fetch_page 分支（:1022-1037）保留独立实现，两处语义当前一致（type→hex / 否则 UTF-8 / 失败 Internal）。属「重复但一致」而非冲突；fetch_page 未改为复用 `data_uri_content_of`（其输入是 AnalyzeUrl 同源，可复用）——可选优化，非缺陷。
- **status 200 参与 loginCheckJs**：explore_api.rs:497-501 本地解码合成 `status=200`。原版 `getStrResponseAwait` 对 data URI 同样返回合成成功响应，loginCheckJs 拿到 200 与原版一致。
- **空 mime 判定**（fd04ee1154）：parser 侧 `parse_data_uri`/`split_url_option` 对 `data:;base64,` 本就命中（fd04ee 提交自述与 6 条矩阵用例证实），真正的漏点在请求层直发——修复点选对了层。非 base64 data URI 不分离选项为已登记超集（analyze_url.rs:835-843 注释），矩阵用例 `test_p2_15_non_base64_documented_superset_behavior` 锁定。

### 8. 测试红绿验证（真实执行，非静态采信）

改前基线 `599ceff71d`（worktree + 拷入测试文件）实测：

| 测试文件 | 改前 | 改后（HEAD） |
|---|---|---|
| host_api_array_arg.rs（P0-A，5 例） | **5 红**（`Error converting from js 'array'/'null' into type 'string'`，与实机同文案） | 5 绿 |
| jslib_failure_visible.rs（P0-B，5 例） | **4 红**（缓存/fresh 静默返回 "2"/"42"、unused-lib 放行、URL 映射误判）| 5 绿 |
| interrupted_message.rs（P1-C，3 例） | **2 红**（裸 `interrupted` 文案）| 3 绿 |
| analyze_request.rs p2_15（6 例）| —（fd04ee 为首提交，前一提交亦红链）| 6 绿 |
| analyze_url.rs p2_15 矩阵（6 例）| — | 6 绿 |

断言均为具体值/具体文案（`assert_eq!(out,"[]")`、`contains("jsLib 求值失败")`+`contains("__probe_missing_jslib__")`、`assert_ne!(msg.trim(),"interrupted")` 等），非空洞断言；红态错误与实机报错文案同构。红绿声明**全部核实成立**。

### 9. 形参改动完整性抽查：通过

- 裸 String：`grep -E "move \|[a-z_]+: String[,)]"` 于 legado-js 全部 host_api 文件 = 0 残留；quickjs_impl.rs 191 个 `Function::new` 闭包入参全部为 RhinoStr/RhinoOptStr/NullStr/NullBool/LooseStrList/Coerced/数值类型。
- `Opt<String>`：quickjs_impl.rs 0 残留；html_parse.rs 仅剩 3 处 `Opt<String>` 为**非闭包**的内部 Rust 函数形参（get_string/get_strings/get_string_list 的 `m_content`，html_parse.rs:1159/1175/1201），不经过 JS 边界，不在缺陷面。
- `Rest<String>`：sandbox.rs 3 处（console.log/warn/error）已改 `Rest<rquickjs::Coerced<String>>`（:163/:177/:189），commit diff 确认为本批改动；legado-js 全包无其它 `Rest<String>` 残留。
- Coerced<String>（改前遗留先例，quickjs_impl.rs:1518 注释）与本批 RhinoStr 同口径（同走 JS_ToString），无双轨语义。

### 10. `coerce.rs` 与既有 `NullStr` 的关系

`NullStr`/`NullBool`（quickjs_impl.rs:41-64，2026-09-26 先例）保留在原处且 webView 继续使用（:4129）；`RhinoStr`/`RhinoOptStr` 为新增。功能上 `RhinoOptStr` 是 `NullStr` 的「宽松转换超集」（NullStr 的非 null 分支走严格 `String::from_js`，RhinoOptStr 走 Coerced）。 webView 未一并迁移到 RhinoOptStr——其入参由 JS 层垫片恒传 4 参（quickjs_impl.rs:1131-1145），null/undefined 已归一，迁移无增益。属「先例共存、语义兼容」而非遗留双轨；可选后续统一。

### 11. 提交卫生（交叉提交影响）

- 四提交均可独立编译（worktree 基线构建通过）；`ba8ad0694e` 混装的 P1-C（engine.rs）与 P2-15 explore（web_book/explore_api）两部分互不依赖、无半成品。`e73cf37d8f` 的 executor URL 映射路由部分与 P0-B 主体同文件互补，测试齐全。
- `git status`：rust/ 下无遗留未提交改动；仅 `.qoder/agents/*`（外来）与未跟踪 `.zcode/`——非本批产物。
- 结论：交叉提交未造成任何内容问题。

---

## Errors (blocking)

无。

## Warnings

- **W-1（P1，证据留存）**：Rhino 探针（JDK17 实测）无源码/输出入库，「探针实测」结论目前不可独立复核，仅有 coerce.rs 转换表与 host_api_array_arg.rs 行为锁定作间接证据。修法：补交探针 Java 源码 + 输出至 `docs/evidence/` 或在 coerce.rs 文档改引 Rhino `ScriptRuntime.toString` 源码行号。
- **W-2（P2，边缘语义）**：`RhinoOptStr` 承袭 `Opt` 的非 exhaustive 语义——多传实参被静默丢弃（rquickjs params.rs:50-65 仅 exhaustive 才查 TooManyArgs）。与改前 `Opt<String>` 行为一致、非本批引入，但若未来想对齐 Rhino「arity 错误即失败」，需全量显式 `Exhaustive` 标注。仅登记，不建议本批处理。

## 可选（P2，改进）

- **O-1**：`fetch_page` 的 data URI 分支（web_book.rs:1022-1037）可改为复用 `data_uri_content_of`，消除「重复但一致」的第二实现，防两处日后漂移。
- **O-2**：`ajaxAll` 收到非 JSON 字符串（如逗号分隔串）时报错形态为 `[ERROR] ajaxAll parse error: ...` 正文（quickjs_impl.rs:2658-2661），书源可能把错误文本当结果继续解析；可考虑改为抛 JS 错误或登记观察。
- **O-3**：URL 映射 jsLib 源每次 execute_js 走 fresh 全量重建引擎（executor.rs:183-192），映射条目多时开销线性放大；既有进程级 jslib 缓存已挡网络，引擎重建可作后续优化。

## 证据分级声明

- 「红→绿」「绿态」「arity 机制」「调用方影响面」「零残留」：真实执行 / 源码逐行核实（持久证明，可复现：`git worktree add @ 599ceff71d` + 拷贝三测试文件复跑）。
- 「Rhino 探针转换表」：采信为可信自述（与 JS 规范 ToString 语义一致），**非**可复核物证（non-claim：本报告未独立重跑 JDK17 探针）。
- 「偏差不影响原版可用书源」：基于行为方向分析的推断（原版失败路径 → 我方宽容成功），无语料反例；置信中高。
- Flutter 侧（2212 例）声明未在本审查复跑（DLL 级回归，超出本批 Rust diff 审查半径），以提交门禁记录为准。

## 处置决定

chat_only → promote_to_artifact（本报告入库 `docs/SEARCH_FIX_BATCH_CODE_REVIEW_20261006.md`）。修复批本体：**可合并**；W-1 建议在下一文档批次补证，不阻塞。
