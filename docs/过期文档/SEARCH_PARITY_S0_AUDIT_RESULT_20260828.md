# P0-2 S0 搜索 parity 专项审计结果与修复计划

**审计日期**：2026-08-28
**审计范围**：`docs/SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` 第 7.6 节及其双包搜索汇报、脚本和附件证据
**审计结论**：P0-1.4 双包基线未完成；P0-2 S0 通用搜索路径不能标记为通过；不允许据此关闭 P0-2 或解锁后续阶段。
**代码变更**：本审计未修改任何代码。

## 重构对齐原则

本项目是 Android 原版的 Rust + Flutter 重构。本文件的“修改方向”只允许把原版已存在的搜索行为迁移到当前生产调用链；不允许借搜索修复新增产品功能、改变页面结构或自创排序、推荐、统计、筛选和提示语义。

| 重构对象 | Android 原版基准 | 当前重构落点 | 允许的修改 | 明确禁止 |
|---|---|---|---|---|
| 单源请求及登录检查 | `WebBook.kt:50-99` | `search.rs:936-1069` | 复用相同的 URL 构建、请求、成功/错误响应 `loginCheckJs` 与最终 URL 语义 | 新建另一套登录流程、UI 登录提示或更改原版错误吞吐规则 |
| 详情页/列表判定 | `BookList.kt:62-109` | `search.rs:1086-1165` | 移植 `bookUrlPattern` 命中详情、空列表详情回退 | 自定义启发式详情识别、以结果数猜测详情页 |
| 列表解析与单源去重 | `BookList.kt:84-147` | `search.rs:1111-1165` | 对齐 `+`/`-` 前缀、字段规则、首次保留去重和逆序 | 修改书源规则含义、引入每源截断或相关性排序 |
| 搜索调度与进度 | `SearchModel.kt:79-140` | `search.rs:586-935`、Flutter `search_notifier.dart:169-320` | 对齐每源 30 秒、取消、逐源完成和静默单源失败 | 全局短超时、缩减源数、用 UI 停止渲染替代取消请求 |
| 跨源聚合与展示 | `SearchModel.kt:144` 起的 `mergeItems` | `search_notifier.dart:297-312` | 保持现有 Flutter 分桶/聚合向原版收敛 | 在 Rust 引入新的推荐/评分/相关性策略，或增加原版没有的 UI 功能 |

若原版没有可定位的源码行为、原始响应夹具或用户明确的双轨确认，该项不得写入 P0-2 的实现范围。

## 一、结论摘要

本轮材料最多证明：重构版在 `emulator-5556` 上曾完成一次真实关键词搜索，且现场观察到“斗破苍穹”、作者、部分简介和章节信息。它不能证明以下任一项：

- 原版与重构版的搜索均已完成；
- 两端使用了相同的书源快照、启用范围和实际源 URL 集；
- 最终原始结果数、聚合结果数、来源数和稳定排序一致；
- 首批可见时间、搜索完成时间或逐源耗时具有可比性；
- `loginCheckJs`、HTTP 重定向、`bookUrlPattern`、空列表详情回退已在 Flutter 主搜索路径中与原版一致。

因此，7.6 节应按“重构端单包端到端观察完成，双包基线未完成”管理。四个 S0 子项可以保持 `DEFERRED`，但不能同时写成“重构版已对齐”或“P0-2 其余部分关闭”。

## 二、证据核验

### 2.1 计划自身的验收要求

计划第 149 行要求每个关键词至少记录：启用源数、完成源数、各失败分类、首批网络完成时间、首批可见时间、最终原始条数、最终聚合行数、前 20 项 `name/author`、每项 `origins` 数及稳定顺序。

7.6 节只给出重构版 `1556 条`，原版仍为“搜索中”且总数为空，缺少上述双端字段。因此不满足计划第 85、87、99、149 行定义的双包基线及关闭条件。

### 2.2 双包状态与结果表

7.6 节的结果表明确记录原版仍在搜索。未提供：

- 原版最终总数和最终完成时间；
- 两端完成源数、失败源及失败分类；
- 前 20 条完整结果及 `origin/bookUrl`；
- 每条聚合结果的来源数和稳定排序；
- 进度 `231/236` 的原始 UI/XML 或可机读日志。

“两端命中约 236 源集”也没有对应的逐端源 URL 清单或集合哈希，无法排除启用范围、缓存数据库或源顺序不同。

### 2.3 脚本能力边界

`scripts/e2e_search_compare.ps1` 的自动部分只尝试查询 `searchBooks` 表中精确名称为关键词的行数和 distinct `origin`；原版包名、数据库路径、`run-as` 可用性没有成功证据。其余字段在脚本中是“人工填写”模板，脚本不会操作搜索、等待完成、导出逐源状态或比较两端排序。

因此，脚本输出不能替代 P0-1.4 基线报告，也不能生成速度结论。

### 2.4 截图与 UI XML

- `.shot_refactored_5556.png`：重构版书架页面；
- `.shot_original_5558.png`：原版书架页面上的更新日志弹窗；
- `.ui_refactored.xml`：重构版书架 UI 层级；
- `.ui_original.xml`：原版更新日志弹窗 UI 层级。

上述附件均不是“斗破苍穹”搜索结果页，不能复核 `1556`、`231/236`、详情字段或来源徽标。它们只能作为应用启动/页面可显示的旁证，不能作为搜索 parity 证据。

### 2.5 书源快照

`.s0_booksource.json` 可复核信息如下：

| 项目 | 值 |
|---|---:|
| 源总数 | 996 |
| `enabled=true` | 996 |
| 含 `loginCheckJs` | 28 |
| 含 `bookUrlPattern` | 211 |
| SHA-256 | `05FC9DC0E337EEA455D43211C49A9084BB86509F227B86BCD6051D6055CCA03C` |

该文件本身不能证明两端已导入同一快照，也不能证明搜索时实际启用的源集合与此文件一致。两端必须分别导出导入后源 URL 集合、启用状态和顺序，并保存哈希。

## 三、源码与结论边界

Flutter 主搜索链为：

```text
SearchNotifier
  -> searchMultiStream
  -> run_multi_stream
  -> drive_source_batches
  -> search_single_source
  -> parse_search_response
```

`search_single_source` 在 `rust/legado-ffi/src/api/search.rs:936-1070` 负责 URL、HTTP 和简化列表解析；完整 `WebBook` 路径中才可见登录检查、重定向最终 URL、`bookUrlPattern` 详情判定和空列表详情回退，例如 `rust/legado-ffi/src/api/web_book.rs:644-720`。因此，完整实现存在于另一执行器并不等于 Flutter 主生产路径已覆盖。

目前四个 S0 子项仍缺少各自的原版响应夹具和跨端断言：

| S0 子项 | 当前审计状态 | 必须补的证明 |
|---|---|---|
| `loginCheckJs` 成功/失败双路径 | 未关闭 | 成功响应、失败响应、JS 返回值/异常、错误分类和原版结果 |
| HTTP 重定向最终 URL | 未关闭 | 初始 URL、每次跳转、最终 URL、解析使用的 `baseUrl` |
| `bookUrlPattern` 详情判定 | 未关闭 | 命中/不命中样本、详情字段和 `bookUrl` |
| 空列表详情回退 | 未关闭 | 空 `bookList` 响应、详情规则结果和空结果边界 |

## 四、修复与复测计划

### P0-2-S0-A：纠正状态和证据台账

1. 将 7.6 节状态改为“进行中：重构端单包观察完成，双包基线未完成”。
2. 保留 `DEFERRED`，删除“重构版已对齐”“P0-2 其余部分关闭”等未经夹具证明的表述。
3. 将现有 PNG/XML 标为启动/页面旁证，不再作为搜索结果证据。
4. 记录测试 HEAD、APK 版本、Rust `.so` content hash、QuickJS 状态、书源快照 SHA-256、设备、网络时间窗和数据库来源。

### P0-2-S0-B：建立四类离线响应夹具

每类夹具至少包含：脱敏原始请求参数、原始响应字节、响应编码、初始 URL、最终 URL、书源 JSON、原版预期 JSON、失败分类和夹具 SHA-256。四类最小样本为：

1. `loginCheckJs` 成功与失败各一例，覆盖正常 HTTP 响应和错误/登录页响应；
2. 至少一次 3xx 跳转，断言解析基准 URL 使用最终 URL；
3. `bookUrlPattern` 命中详情页和不命中列表页各一例；
4. `bookList` 为空但详情规则可解析，以及确实无法解析的空结果各一例。

夹具必须同时由原版行为基准和 Rust 主生产执行器消费，不能只测试 `web_book` 辅助路径。

### P0-2-S0-C：执行逐源和跨端对比

对同一关键词至少执行一次冷缓存、一次热缓存；两端必须等待终态（完成或明确停止），不得以一端仍搜索中的中间状态做结论。报告至少包含：

| 维度 | 重构版 | 原版 |
|---|---|---|
| 启用源数/搜索范围 |  |  |
| 完成源数 |  |  |
| `ok/empty/http_error/timeout/login_required/js_error/parser_error/cancelled` |  |  |
| 首批网络完成时间（单调时钟） |  |  |
| 首批 UI 可见时间（单调时钟） |  |  |
| 搜索终态时间 |  |  |
| 原始单源条数 |  |  |
| 最终聚合行数 |  |  |
| 前 20 项 `name/author/kind/bookUrl` |  |  |
| 每项 `origins` 数与来源 URL |  |  |
| 稳定排序指纹 |  |  |

“同一核心书籍”只有在 `name/author/bookUrl/origin` 对齐，并且聚合来源数和顺序可解释时才能成立。分类差异必须单独标记为字段差异，不能用“可能不同源”代替定位。

### P0-2-S0-D：速度归因和复现门槛

不得使用“原版逐源下载封面导致慢”作为已证实根因，除非两端都记录以下分段耗时：URL 构建、HTTP、重定向、登录检查、列表提取、字段解析、序列化/FFI、封面请求、Flutter 首次绘制。所有时间必须绑定 search session 和 source URL。

性能报告应同时给出中位数、P95、完成源数和失败分类；不得通过减少源数、缩短超时、只统计首批或截断结果制造性能数字。

### P0-2-S0-E：主搜索路径的具体改造方向

本节是后续实现建议，不代表本轮已实施。每一项均以“原版已有语义 + 当前重构缺口”为前提；改动前必须冻结夹具预期和 FFI 影响范围。任何一项失败都不得切换 Flutter 主入口。

#### 1. 收敛为唯一的单源规则执行器

原版基准是 `SearchModel.startSearch` 对每个书源调用唯一的 `WebBook.searchBookAwait`，再由 `BookList.analyzeBookList` 完成单源语义。本轮目标仅是让当前 `run_multi_stream`、`search_books`、`multi_source_search` 和换源场景复用这套既有语义，不是创造新的搜索框架，也不是复制整个 Android `WebBook` 对象。

建议在 `rust/legado-ffi/src/api/search.rs` 所在 crate 内，将当前 `search_single_source` 补齐为唯一的私有单源执行器；可复用 `web_book.rs` 已有的纯解析辅助逻辑，但不得改变外部搜索 API。例如：

```text
execute_search_source(client, source, keyword, page, session)
  -> build_search_url_with_setup
  -> fetch_search_response
  -> apply_login_check
  -> resolve_final_base_url
  -> classify_direct_detail_or_list
  -> parse_list_or_fallback_to_detail
  -> normalize_and_dedup_single_source
  -> SourceSearchOutcome { results, status, timings }
```

具体约束：

1. `search_single_source` 只保留限流、会话取消、单源超时和对该执行器的调用；不得继续直接调用简化的 `parse_search_response` 形成第二套规则语义。
2. `web_book.rs` 中已存在且与原版一一对应的纯规则逻辑可下沉为无状态私有帮助函数，或由主执行器复用；不要把 `RealBookSourceFetcher`、缓存和详情页 I/O 整体耦合进批量搜索。
3. 解析结果必须保留真实 `source_url`、`book_url`、`origin_order`、最终 `base_url` 和错误分类；禁止 UI 用默认值推测来源或详情 URL。
4. `run_multi_stream` 仍是 Flutter 的唯一生产入口。`search_books`、`multi_source_search` 若保留，只允许调整批次收集方式，不能覆盖单源结果、超时、去重或排序语义。

#### 2. 严格实现原版 S0 行为顺序

以下顺序直接来自 `WebBook.searchBookAwait` 的请求/登录/重定向顺序与 `BookList.analyzeBookList` 的详情/列表/回退顺序，建议逐步移植并通过夹具锁定：

1. 以书源上下文构建 `searchUrl`，保留请求方法、请求体、headers、charset 和 cookie。
2. 发起请求并保存请求 URL、HTTP 状态、响应字节和最终 URL；非 2xx 不能被无条件折叠为“空结果”。
3. 对成功响应和原版等价的错误/登录响应运行 `loginCheckJs`；区分“无需登录”“需要登录”“JS 执行失败”“网络失败”。
4. 使用最终 URL 作为解析 `baseUrl`。封面、详情、分页和相对链接都必须相对于最终 URL 绝对化。
5. 若最终 URL 命中 `bookUrlPattern`，按详情页规则生成单条搜索结果，不再强行按列表解析。
6. 否则按 `ruleSearch.bookList` 提取元素，并先处理 `+`/`-` 前缀，再解析字段、规范化 URL 和按单源 `bookUrl` 保序去重。
7. 当列表为空且未配置或未命中 `bookUrlPattern` 时，按详情页规则尝试一次；详情关键字段不足时返回明确的 `empty` 或 `parser_error`，不得伪造书籍。
8. 只有单源语义完成后，才由 Flutter 按原版 `mergeItems` 做跨源聚合；Rust 不得重新引入相关性排序或跨源截断。

#### 3. 错误分类、取消和超时建议

现有“返回空 `Vec`”的路径应逐步收敛为可观察结果。为避免把诊断能力误做成产品功能，建议仅在 Rust crate 内以内部结果记录状态和耗时；不要求新增页面、用户提示、统计功能或新的公开 FFI 模型。例如：

```text
SourceSearchOutcome
  results: Vec<SearchResult>
  status: ok | empty | http_error | timeout | login_required |
          js_error | parser_error | cancelled
  request_url: String
  final_url: Option<String>
  timings: { url_build, http, login_check, parse, total }
```

该结构可以保持 crate 内私有；默认沿用原版“单源失败静默、日志留痕”的展示语义。只有现有批次字段能够承载且确有原版等价物时，才经 FFI 输出诊断摘要。这样既不改变 Flutter 的展示职责，也能避免把 `login_required`、JS 错误和真实空结果混为一类。

取消建议与 S0 改造分开提交：会话创建时生成独立取消令牌；调度器只维护受控数量在飞任务；获取并发许可后再次检查取消；取消时终止排队任务，并阻止在飞任务向 Stream、数据库和 UI 继续写入。单源 30 秒超时与限流等待是否计入超时必须显式配置并以原版实测为准，不能依赖全局 10 秒总超时。

#### 4. FFI、Flutter 和数据层边界

1. P0-2 S0 不新增 Flutter 业务逻辑。Flutter 继续只接收既有搜索流批次，负责原版已有的加载态、停止操作、同书聚合与渲染；不得为诊断字段添加新的用户入口、弹窗或统计页。
2. 若为错误分类、最终 URL 或诊断字段扩展 FFI DTO，必须先更新 `docs/API_CONTRACT.md`，列明字段是否对 UI 可见、兼容默认值和旧 APK/旧数据库迁移策略，再生成绑定。
3. `searchBooks` 持久化前应保存真实 `origin`、`originOrder`、`bookUrl`；不要以书名精确匹配的单表计数代替最终聚合统计。
4. 封面加载必须从搜索关键路径分离。是否下载封面、何时解码、是否命中缓存应有独立计时，不能作为“原版搜索慢”的推测性归因。

#### 5. 夹具、单元测试和双包验收的落地顺序

建议将仅用于还原原版行为的脱敏样本固定在 `rust/legado-ffi/tests/fixtures/search_s0/`，每个场景使用同名目录：

```text
<scenario>/
  source.json             # 最小脱敏书源
  request.json            # keyword、page、headers、初始 URL
  response.bin            # 保留原始编码的响应
  redirect_chain.json     # 无跳转时为空数组
  expected_original.json  # 原版抓取的标准化预期
  manifest.json           # SHA-256、编码、来源时间、脱敏说明
```

每个夹具至少有三类断言。断言以原版已抓取的标准化结果为唯一基准，不以重构版当前输出反推期望：

1. Rust 单元测试：主搜索单源执行器输出字段、条数、`status`、最终 URL 和保序去重与 `expected_original.json` 相同。
2. Rust 集成测试：`run_multi_stream`、`search_books`、`multi_source_search` 在相同输入下得到同一最终集合与来源数；流式只允许到达时间不同。
3. Flutter 测试：模拟 Rust 流最后一批和错误分类，断言不丢批、不把 `login_required` 渲染为成功空列表，聚合后来源数与夹具一致。

随后再做两台模拟器验收：先在 5556 运行改造 APK，再在 5558 原版运行相同书源快照和关键词。两端均到终态后导出同一结构的 JSON/CSV；比较程序应直接读取该结构并输出差异，而不是通过截图和人工转录决定是否通过。

#### 6. 提交拆分、回退和验收门

建议按以下顺序分提交，避免网络行为、调度和 UI 同时变化导致不可定位。每个提交只补一个原版已有语义：

1. `test(rust)`：加入脱敏响应夹具和原版预期，先让当前主路径暴露差异；
2. `refactor(rust)`：抽取唯一单源执行器，不改变 FFI JSON；
3. `fix(rust)`：依次接入最终 URL、`loginCheckJs`、`bookUrlPattern`、空列表详情回退，每项附对应夹具；
4. `test(rust)`：三入口一致性、取消和错误分类测试；
5. 必要时单独提交 `docs` 与 FFI 契约、生成绑定、Flutter 展示调整。

每个步骤的最低门槛是：相关夹具测试为绿、既有 Rust QuickJS/非 QuickJS 测试无回归、Flutter `analyze`/`test` 通过、5556 冒烟通过。涉及用户验收前，再执行 5558 冒烟和双包终态对比。任何字段、条数、错误分类或排序发生未解释差异时，立即保留旧主入口或通过 feature gate 回退，不将差异归因于网络后继续关闭事项。没有原版源码与夹具依据的“优化”必须移出本专项，另行审查。

## 五、关闭条件

P0-2 S0 只有同时满足以下条件才可关闭：

1. 四类响应夹具均可离线复现，且原版预期与 Rust 主生产路径的字段、条数、错误分类一致；
2. 原版与重构版使用同一书源快照、同一搜索范围、同一关键词，并均达到终态；
3. 双端完成源、失败分类、首批/终态时间、原始/聚合行数、前 20 项、`origins` 和稳定排序均有可机读证据；
4. `loginCheckJs` 成功/失败、最终重定向 URL、`bookUrlPattern`、空列表详情回退各有独立断言；
5. 失败项不得标绿，未完成项继续保留 `DEFERRED`；
6. 复测结果、命令、设备和提交 HEAD 写入计划，并与实际提交记录一致。

在上述条件满足前，P0-3 的取消/并发压力验收可以独立准备，但不得宣称 P0-2 S0 已关闭或以本次通用搜索观察替代专项夹具验证。

## 六、当前状态台账

| 项目 | 状态 | 说明 |
|---|---|---|
| 重构版真实搜索可启动并产生结果 | 观察到 | 当前附件不足以独立复核 UI 数字 |
| 原版同关键词搜索完成 | 未证明 | 记录仍为搜索中 |
| P0-1.4 双包基线 | 阻塞 | 缺双端终态和必需指标 |
| S0 通用路径 parity | 未关闭 | 只能作为待验证假设 |
| `loginCheckJs` 双路径 | DEFERRED | 缺定向夹具 |
| HTTP 最终重定向 URL | DEFERRED | 缺定向夹具 |
| `bookUrlPattern` | DEFERRED | 缺定向夹具 |
| 空列表详情回退 | DEFERRED | 缺定向夹具 |
| 速度根因“逐源下载封面” | 未证实 | 缺分段计时 |

## 七、P0-3 取消、超时与并发专项复审（2026-08-28）

**审计对象**：`07bd63089`（会话级取消/暂停与 `drive_source_batches` 改造）、`6a7d8e8b4`（P0-3 完成记录）。

**审计结论**：会话级令牌替换全局静态标志的根因修复方向正确，且没有 FFI 签名变更；但 P0-3 当前只能标记为“代码部分完成、待修复和复测”，不能满足原计划的关闭条件，也不能标为完成。

本审计在当前工作树执行了针对性测试：

```text
cargo test -p legado-ffi test_search_session_isolation_a_then_b --lib
结果：1 passed，0 failed（当前工作树另有 328 项被过滤）
```

该测试通过仅证明“预先取消的会话不会执行 `search_one`，独立的新会话可以执行”；它不证明真实的重叠搜索、任务中止或旧结果隔离。

### 7.1 已确认的正向改动

1. `SearchSession { cancel, paused }` 与 `CURRENT_SEARCH_SESSION` 消除了旧全局 `SEARCH_CANCELLED/SEARCH_PAUSED` 被新搜索重置的直接根因。`search_books`、`multi_source_search`、`run_multi_stream` 均在启动时注册新会话并取消旧会话。
2. `drive_source_batches` 在派发前和获得许可后均检查会话级取消标志。对尚未真正执行 `search_one` 的排队源，这是必要的防请求保障。
3. 单源超时继续采用每源 `30s`，与 Android 原版 `SearchModel.startSearch` 的 `withTimeout(30000L)` 对齐；单源异常仍不会中断其他源。
4. `SWITCH_SOURCE_TIMEOUT` 被 `source_switch.rs` 使用，语义属于换源的原版 `60s` 超时对齐，不是 P0-3 的功能性回归；但它不应与 P0-3 取消改动混在同一原子提交中。

### 7.2 P0 阻塞问题：取消不会终止已创建任务

`drive_source_batches` 在 `search.rs:613-674` 为所有书源立即调用 `tokio::spawn`，只是让它们在 semaphore 上排队。取消或 sink 关闭后，`search.rs:682-710` 仅 `break` 收集循环；代码没有调用 `JoinHandle::abort`、`JoinSet::abort_all` 或等价机制。

丢弃 `FuturesUnordered<JoinHandle<_>>` 不会取消 Tokio 已 `spawn` 的任务，而是分离它们。结果是：

- 大书源包仍会创建与书源数相同的排队任务，不符合原计划“只创建受控数量在飞任务，或取消时显式 abort 已创建任务”；
- sink 关闭后，排队任务仍会继续等待 semaphore；虽然二次检查通常阻止它们发 HTTP，但任务和等待链没有被真正清理；
- 暂停时，已拿到 permit 的任务会在 `while paused` 中持有并发许可，和原版 `SearchModel.kt:88-102` 在调度前等待 `workingState` 的门控位置不一致。

**修改意见（按原版调度语义做最小重构）**：不要继续“每源一个 `tokio::spawn` + semaphore 排队”。将 `sources` 作为待派发队列，仅保持最多 `SEARCH_CONCURRENCY` 个 `JoinHandle`/future：每有一个完成才派下一个。取消、sink 关闭或会话被替换时，显式 `abort_all` 并 drain 已启动 handle；暂停检查应发生在派出下一个源之前，不应让未请求源占用 permit。此项仅收敛资源与取消语义，不改变原版的并发数、30 秒超时、逐源回调或 UI 行为。

### 7.3 P0 阻塞问题：现有压力测试未覆盖报告声称的根因

`test_search_session_isolation_a_then_b` 在 `search.rs:1984-2057` 中先将 A 的 `cancel` 设为 `true`，完整等待 A 返回后才创建并运行 B。测试没有：

- 调用 `register_current_session` 或 `run_multi_stream`，因此没有验证当前会话注册表；
- 让 A 已有至少一个在飞/排队任务时启动 B；
- 断言 B 启动后 A 的排队源没有请求、在飞源被中止或其结果被丢弃；
- 验证 A 的结果不会进入 Stream、`searchBooks` 或 Flutter 状态。

它验证的是“预取消”而不是“搜索 A 被搜索 B 取代”，不能作为该提交所述根因的压力回归测试。

**修改意见**：新增真实重叠测试，顺序必须固定为：

1. 启动 A，使用可控 `search_one` 使第一批源进入阻塞点，同时保留其余源排队；
2. 通过生产入口或等价会话注册逻辑启动 B，断言 A 的会话被取消；
3. 放开 A 的在飞源，断言 A 不再产生回调、流事件、持久化写入，且 A 后续排队源的请求计数为 `0`；
4. 断言 B 全部源按自身会话执行，结果与 A 的来源/进度不混杂；
5. 重复覆盖显式停止、sink 回调返回 `Err`、页面销毁等三种取消入口。

### 7.4 P1 风险：取消检查与落库/推流之间存在竞争窗口

驱动器只在取到完成任务后于 `search.rs:682-685` 检查一次取消。若在该检查之后、新搜索注册会话之前或 `on_source` 执行期间发生取消，`run_multi_stream` 的回调仍可能在 `search.rs:536-559` 调用 `persist_search_books` 并向 sink 写入旧批次。

另一个一次性入口风险更直接：`search_books` 即使驱动器因取消退出，仍会在 `search.rs:223-230` 对已累积的旧结果批量 `persist_search_books`。新搜索已经启动时，这会污染供换源复用的 `searchBooks` 数据。

**修改意见**：

1. 将会话身份传入/闭包捕获至落库与推流前的最后一道门；在序列化、持久化、`sink.add` 前再次确认“该会话未取消且仍为当前会话”。
2. 一次性入口在 `drive_source_batches` 返回后、任何 `annotate_results` 和 `persist_search_books` 前检查会话状态；已取消则直接返回取消结果或丢弃累积结果，语义以原版取消后不再接收结果为准。
3. 先以纯内存持久化替身写回归测试，证明 B 注册后 A 的写入次数为 `0`，再接真实数据库集成测试。

### 7.5 P1 风险：当前会话注册表没有生命周期清理

`CURRENT_SEARCH_SESSION` 只在启动新搜索时覆盖，正常结束、加载源失败、HTTP 客户端创建失败或取消结束时都没有“仅当仍是自己才清空”的清理。完成后的无参 `cancel_search/pause_search/resume_search` 因而仍指向已结束会话，调试和后续状态判断会失真。

**修改意见**：新增 `clear_current_session_if_same(&session)`，以 `Arc::ptr_eq` 防止 A 结束时误清除已启动的 B；在三个生产入口的所有退出路径执行。补充 A 完成后 B 已启动、A 的清理不会清掉 B 的测试。

### 7.6 提交范围与文档更正

1. `SWITCH_SOURCE_TIMEOUT` 是 G4/换源范围，建议在尚未对外集成时从 `07bd63089` 拆出到独立 `fix(rust)` 或 `refactor(rust)` 提交；保留其已有消费者，不得为了整理提交而破坏 `source_switch.rs` 编译。
2. `6a7d8e8b4` 中“P0-3 已完成”的状态应更正为“待修复：会话级令牌已落地，取消任务中止、竞态隔离与真实重叠压力测试未通过验收”。
3. 同一文档内关于 P0-1.4/P0-2 S0“验证通过”的表述继续与本审计第 1 至 6 节冲突，必须一并更正为“单包观察完成、双包基线与四项 S0 仍未关闭”。
4. `source_rate_limit` 相关未暂存改动与 P0-3 提交应继续隔离；后续任何 P0-3 验证须记录所测 HEAD，避免把当前工作树 G4 行为归因给 `07bd63089`。

### 7.7 P0-3 重新关闭条件

P0-3 仅在以下条件全部满足时才可关闭：

1. 调度器在任何时刻只维持受控数量的在飞任务，或取消/sink 关闭时显式终止并等待已创建任务；
2. A 运行中被 B 替换的压力测试证明：A 的排队源不请求、在飞结果不进入流/状态/数据库，B 不受 A 污染；
3. 显式停止、sink 关闭、页面销毁三条取消入口均有同等断言；
4. 暂停不会让未请求源占用并发许可，并与原版调度前 `workingState` 门控一致；
5. 注册表生命周期清理不会误清新会话；
6. Rust 非 QuickJS/QuickJS 全量门禁、Flutter `analyze`/`test`、5556 冒烟通过；再完成“搜索中停止并立即重新搜索”的 5556 实机验证。用户验收前按项目流程在 5558 执行同样的取消与重搜场景。

**当前 P0-3 状态**：阻塞，待上述修复和复测；不得推进为“已完成”。

**编写者**：主 Agent 代码审查
**日期**：2026-08-28
