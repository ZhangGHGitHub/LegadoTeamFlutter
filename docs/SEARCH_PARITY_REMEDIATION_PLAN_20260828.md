# 搜索速度与结果一致性修复计划

**状态**：开放，未实施

**优先级**：P0（结果缺失与核心搜索链路分叉）、P1（稳定性和排序）、P2（性能观测）

**依据**：`docs/SEARCH_PARITY_AUDIT_20260827.md`、2026-08-28 当前工作树源码审查

**范围**：Rust 搜索引擎、Flutter 搜索状态层、FFI 契约、测试夹具与双模拟器验收。Android 原版仅作为行为基准，不修改。
**非目标**：不新增原版不存在的搜索功能；不以降低书源数、缩短超时或任意截断结果掩盖问题。

## 一、问题定义与证据边界

当前 Flutter 搜索页实际调用链为：

```text
SearchNotifier.search
  -> BookApi.searchMultiStream
  -> ffi.search_multi_stream
  -> run_multi_stream
  -> drive_source_batches
  -> search_single_source
  -> parse_search_response
```

原版链路为：

```text
SearchModel.startSearch
  -> WebBook.searchBookAwait
  -> BookList.analyzeBookList
  -> SearchModel.mergeItems
```

已证实的差异如下：

| 编号 | 当前问题 | 原版行为 | 影响 | 证据 |
|---|---|---|---|---|
| S0 | 主路径未复用完整规则搜索器 | 搜索后执行 `loginCheckJs`、重定向处理、`bookUrlPattern` 和空列表详情页回退 | 部分书源为 0 条或详情链接错误 | `search.rs:1002-1142`；`WebBook.kt:74-110`；`BookList.kt:62-109` |
| S1 | 主路径仅加载 `jsLib`，未建立 `source/cookie` JS 上下文 | `AnalyzeRule(ruleData, bookSource)` 持有书源语境 | 依赖 `source.getKey()`、cookie 或 jsLib 上下文的规则失败 | `search.rs:1012-1019`；`js_executor.rs:65-85` |
| S2 | 未处理 `bookList` 的 `+`/`-` 前缀、详情页回退和按 `bookUrl` 去重 | 原版完整处理三者 | 单源数量和顺序不一致 | `search.rs:1021-1028`；`BookList.kt:89-148` |
| S3 | 精准过滤在 Flutter 聚合之后才表现 | 原版在字段解析中途过滤 | 无关条目仍完整解析、跨 FFI 传输和落库 | `SearchModel.kt:102-124`；`BookList.kt:220-286` |
| S4 | `origin_order` 固定为 0 | 原版写入 `customOrder` | 缓存、换源和稳定排序偏离 | `search.rs:639-663`；`BookList.kt:211-215` |
| S5 | 取消仅停止收集，不终止已排队的任务 | 原版取消 Job 和搜索池 | 下一次搜索被旧任务抢占并发、连接和限流额度 | `search.rs:551-632`；`SearchModel.kt:235-246` |
| S6 | 三个 Rust 搜索入口各有不同超时、去重和排序规则 | 原版仅一套主搜索语义 | 调用方不同即结果不同，无法建立可靠验收 | `search.rs:146-188`、`253-310`、`423-503`；`search_engine.rs:144-220` |
| S7 | `quickjs` 默认 feature 关闭 | Android 原版始终提供 JS 引擎 | 若 APK 未启用 feature，`@js` 规则将静默空结果 | `Cargo.toml:32-34`；`js_executor.rs:54-62` |

本计划不把网络波动、书源失效或站点反爬误判为源码缺陷。任何运行时结论必须记录：APK 版本、Rust `.so` feature、书源快照、关键词、时间窗、网络、成功/失败源列表和原始响应摘要。

## 二、目标架构与不可变约束

目标是让所有生产搜索 API 共享同一个“单源搜索语义”，而不是继续维护三套近似实现。

```text
统一单源执行器
  输入：BookSource、keyword、page、precision、取消令牌
  过程：URL 构建 -> 请求/重定向/登录检查 -> 规则解析 -> 原版同等过滤与单源去重
  输出：带 sourceUrl、sourceName、originOrder 的标准 SearchBook

统一批次驱动器
  过程：有界调度 -> 真实取消 -> 每源 30 秒 -> 完成即发批次
  输出：原始单源结果和进度

Flutter 展示层
  过程：按原版 mergeItems 规则聚合同书来源，并仅负责展示状态
```

约束：

1. `run_multi_stream` 是 Flutter 搜索页的唯一生产入口；它必须成为验收优先对象。
2. `search_books`、`multi_source_search` 不得继续拥有独立的解析、超时、去重或排序规则。保留时必须委托统一执行器，或明确弃用并移除调用方。
3. Rust/Dart FFI 入参与结果字段有变化时，先更新 `docs/API_CONTRACT.md`，经双轨确认后才写代码或生成绑定。
4. `bookUrl`、`originOrder`、原始 source URL 是数据契约字段，不能用 UI 推测或默认值补齐。
5. 不以全局 10 秒总超时替代原版的每源 30 秒超时；不引入未经原版验证的每源 50 条截断。

## 三、实施阶段

### P0-1：冻结基线与构建能力

**目的**：先确认“比较的是同一批书源和同一类 JS 能力”，否则后续数字没有解释价值。

1. 导出并固化一份脱敏书源 SQLite/JSON 快照，覆盖静态 HTML、JSON、重定向详情页、`loginCheckJs`、`@js`、jsLib/source 上下文、`concurrentRate` 和 JS 书源各至少一个。
2. 为每个夹具保存原始 HTTP 响应、最终 URL、预期书籍字段和原版结果；网络夹具只用于规则一致性，不用于实时站点可用性判断。
3. 在 Android release `.so` 中验证 `quickjs` feature：构建命令、Cargo feature、产物符号/运行时探针三者必须一致。未启用时，此项阻塞 P0-2，不允许以“普通书源能搜到”关闭。
4. 在原版与重构版使用同一书源快照、同一关键词、同一搜索范围运行基线。记录首批时间、每源完成时间、原始单源条数、最终聚合行数、每本 `origins` 和失败分类。

**关闭条件**：夹具可离线复现；JS feature 有可验证证据；双包基线不再混用不同书源数据库或不同范围。

### P0-2：统一主路径的单源规则语义

**目的**：消除 `search_single_source` 与 `RealBookSourceFetcher::search` 的解析分叉。

1. 设计一个 crate 内可复用的单源执行器，由流式搜索和一次性搜索共同调用；先画清 DTO 边界，避免 `SearchResult` 与 `WebSearchResult` 双向复制后再次漂移。
2. 按原版固定顺序实现并为每项建立夹具测试：搜索 URL 构建、HTTP 最终 URL、`loginCheckJs` 成功/失败双路径、`bookUrlPattern`、空列表详情回退、`bookList` 的 `+`/`-`、`splitSourceRule`/替换规则、字段独立容错、URL 绝对化和按 `bookUrl` 去重。
3. 解析器必须使用书源上下文构造器。对上下文不兼容的 JS 规则，保留可诊断错误码和书源标识，不得静默降为“无结果”。
4. JS 书源继续沿用 `JsSourceBookOrchestrator`，但须使用同一输出标准化、过滤、来源顺序和错误分类管线。
5. 在替换主路径前，逐源比较新旧 Rust 结果；对有意修正的差异建立原版夹具证据后再切换。

**关闭条件**：S0、S1、S2 的每个夹具均与原版字段和条数一致；Flutter 流式主路径不再直接持有简化解析逻辑。

### P0-3：取消、超时与并发的正确性

**目的**：防止旧搜索残留，确保“32 并发”表示可观察、可取消的有效工作。

1. 将全局静态取消标志改为搜索会话级取消令牌；新搜索、停止、页面销毁和 Stream sink 关闭均必须取消同一会话。
2. 调度器只创建受控数量的在飞任务，或在取消时显式 abort 已创建的 JoinHandle；获得 semaphore 后必须二次检查取消状态。
3. 保留每源 30 秒超时，并明确限流等待是否计入该超时，随后与原版实测对齐。不得让被取消的任务继续消耗 `concurrentRate` 窗口。
4. 增加压力测试：搜索 A 后立即搜索 B，断言 A 不再产生 HTTP/批次，B 的首批时间不受 A 的排队任务影响。

**关闭条件**：取消后的排队源不发请求；在飞任务被终止或其结果绝不再进入状态、落库或流；压力测试稳定通过。

### P1-1：统一过滤、聚合、排序和持久化契约

**前置**：若把 `precision` 传入 Rust，先更新 `API_CONTRACT.md` 并完成双轨确认。

1. 把原版精准过滤前移到单源字段解析阶段：先 name/author/kind，再判定是否保留，之后才取其余字段。
2. 明确两层去重：单源按 `bookUrl`；跨源按格式化后的 name+author 并合并 origins。两层均需保持首次出现与原版一致。
3. 每项结果写入真实 `source.customOrder`；不得在 DTO 转换中回写为 0。
4. 明确 UI 仅负责流状态和渲染。若保留 Flutter 分桶，必须使用与原版完全相同的 key、桶规则和稳定平局排序；更优选择是把可纯化的聚合规则下沉并用跨端夹具校验。
5. `search_books`、`search_multi`、`search_multi_stream` 写出一致性测试：同输入的最终集合、来源数和排序应相同；流式仅允许到达时间不同。

**关闭条件**：同一离线夹具在三入口得到一致结果；DB 的 `originOrder`、结果条数和 origins 与原版一致。

### P1-2：性能优化只在语义一致后进行

1. 为 URL 构建、HTTP、登录检查、列表提取、字段解析、序列化、FFI、Flutter 首次绘制分别记录耗时；日志必须可按 search session 和 source URL 关联。
2. 复用规则预拆分和可复用解析器，避免每列表元素重复构造 JS 执行器或重复编译规则；优化后以夹具断言字段不变。
3. 审查请求重试、cookie、header、charset、重定向和每次 HTTP 的 `concurrentRate` 接入点，逐项与 Android 对齐。
4. 150ms UI 节流仅可作为渲染去抖，不能延迟 Rust 批次发送或改变首个完成源的顺序；记录网络完成与首次可见的两类时间。

**关闭条件**：夹具输出零回归；性能报告可拆分定位慢源是网络、规则、JS、FFI 还是 UI；不使用结果截断取得性能数字。

### P2：可观测性与长期防回归

1. 给每源结果统一分类：ok、empty、http_error、timeout、login_required、js_error、parser_error、cancelled；UI 维持原版的单源静默失败表现，诊断写入日志/探针。
2. 保留命令行探针，但探针调用必须明确选用与 Flutter 相同的流式执行器，避免以 `multi_source_search` 的 10 秒语义冒充主搜索结果。
3. 每次修改解析规则执行器、JS feature、FFI 搜索 DTO 或调度器时，强制跑离线夹具和双模拟器搜索验收。

## 四、验收矩阵

| 层级 | 必测项 | 通过标准 |
|---|---|---|
| Rust 单元 | URL、重定向、登录检查、详情页回退、前缀、替换、URL 去重、取消 | 每项针对原版已捕获响应断言字段、条数与错误分类 |
| Rust 集成 | 三搜索入口一致性、会话取消、32 并发、有界排队 | 最终集合、origins、排序、originOrder 一致；取消无残留请求 |
| Flutter | 流批次、精准开关、同书聚合、首批展示、翻页 | 不丢最后批；最终展示与原版分桶/来源数一致 |
| Android 5556 | 子代理冒烟及搜索基准 | `emulator_smoke_test.ps1 -Device emulator-5556` 退出码 0；记录对比表 |
| Android 5558 | 用户验收前回归 | `emulator_smoke_test.ps1 -Device emulator-5558 -SkipBuild -CheckUI` 退出码 0；同库同网双包复测 |

运行时比较不得只看“总条数”。每个关键词至少比较：启用源数、完成源数、各失败分类、首批网络完成时间、首批可见时间、最终原始条数、最终聚合行数、前 20 项 name/author、每项 origins 数和结果稳定顺序。

## 五、交付顺序与风险控制

1. 先完成 P0-1，再进行 P0-2；未确认 QuickJS feature 或没有夹具时，不改主搜索解析器。
2. P0-2 通过语义夹具后才实施 P0-3；避免调度优化掩盖解析失败。
3. P1-1 涉及 FFI 时先冻结契约；不得让 Flutter 用展示层过滤替代底层语义。
4. P1-2 只接受有性能剖面和零语义回归的优化。
5. 每个阶段独立提交，提交前执行对应 Rust 测试、Flutter `analyze`/`test` 和两级模拟器冒烟；失败项不得标记完成。

## 六、本次审查不作出的结论

- 未直接运行原版与重构版的同网络搜索，故不宣称具体快慢倍数或固定少多少条。
- 未检查最终 APK 的 Cargo feature，故 QuickJS 为高风险待证实项，不是已确认线上故障。
- 当前工作树含未提交搜索改动；后续实施前必须重新记录 HEAD、diff 和书源数据版本。

编写者：Codex ｜ 2026-08-28
