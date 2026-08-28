# P0-2 S0 搜索 parity 专项审计结果与修复计划

**审计日期**：2026-08-28
**审计范围**：`docs/SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` 第 7.6 节及其双包搜索汇报、脚本和附件证据
**审计结论**：P0-1.4 双包基线未完成；P0-2 S0 通用搜索路径不能标记为通过；不允许据此关闭 P0-2 或解锁后续阶段。
**代码变更**：本审计未修改任何代码。

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

本节是后续实现建议，不代表本轮已实施。改动前必须冻结夹具预期和 FFI 影响范围；任何一项失败都不得切换 Flutter 主入口。

#### 1. 收敛为唯一的单源规则执行器

目标是让 `run_multi_stream`、`search_books`、`multi_source_search` 和换源场景共享同一个单源语义，而不是复制 `WebBook` 的业务分支。

建议在 `rust/legado-ffi/src/api/search.rs` 所在 crate 内抽取私有执行器，例如：

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
2. `web_book.rs` 中已验证的纯规则逻辑应下沉为无状态私有帮助函数，或由新执行器复用；不要把 `RealBookSourceFetcher`、缓存和详情页 I/O 整体耦合进批量搜索。
3. 解析结果必须保留真实 `source_url`、`book_url`、`origin_order`、最终 `base_url` 和错误分类；禁止 UI 用默认值推测来源或详情 URL。
4. `run_multi_stream` 仍是 Flutter 的唯一生产入口。`search_books`、`multi_source_search` 若保留，只允许调整批次收集方式，不能覆盖单源结果、超时、去重或排序语义。

#### 2. 严格实现原版 S0 行为顺序

针对每个单源搜索请求，建议固定以下顺序并通过夹具锁定：

1. 以书源上下文构建 `searchUrl`，保留请求方法、请求体、headers、charset 和 cookie。
2. 发起请求并保存请求 URL、HTTP 状态、响应字节和最终 URL；非 2xx 不能被无条件折叠为“空结果”。
3. 对成功响应和原版等价的错误/登录响应运行 `loginCheckJs`；区分“无需登录”“需要登录”“JS 执行失败”“网络失败”。
4. 使用最终 URL 作为解析 `baseUrl`。封面、详情、分页和相对链接都必须相对于最终 URL 绝对化。
5. 若最终 URL 命中 `bookUrlPattern`，按详情页规则生成单条搜索结果，不再强行按列表解析。
6. 否则按 `ruleSearch.bookList` 提取元素，并先处理 `+`/`-` 前缀，再解析字段、规范化 URL 和按单源 `bookUrl` 保序去重。
7. 当列表为空且未配置或未命中 `bookUrlPattern` 时，按详情页规则尝试一次；详情关键字段不足时返回明确的 `empty` 或 `parser_error`，不得伪造书籍。
8. 只有单源语义完成后，才由 Flutter 按原版 `mergeItems` 做跨源聚合；Rust 不得重新引入相关性排序或跨源截断。

#### 3. 错误分类、取消和超时建议

现有“返回空 `Vec`”的路径应逐步收敛为可观察结果，建议内部使用：

```text
SourceSearchOutcome
  results: Vec<SearchResult>
  status: ok | empty | http_error | timeout | login_required |
          js_error | parser_error | cancelled
  request_url: String
  final_url: Option<String>
  timings: { url_build, http, login_check, parse, total }
```

该结构可以保持 crate 内私有；只有必要的进度、结果和诊断摘要才经 FFI 输出。这样既不改变 Flutter 的展示职责，也能避免把 `login_required`、JS 错误和真实空结果混为一类。

取消建议与 S0 改造分开提交：会话创建时生成独立取消令牌；调度器只维护受控数量在飞任务；获取并发许可后再次检查取消；取消时终止排队任务，并阻止在飞任务向 Stream、数据库和 UI 继续写入。单源 30 秒超时与限流等待是否计入超时必须显式配置并以原版实测为准，不能依赖全局 10 秒总超时。

#### 4. FFI、Flutter 和数据层边界

1. P0-2 S0 原则上不新增 Flutter 业务逻辑。Flutter 只接收批次、单源状态和标准化结果，继续负责加载态、停止操作、同书聚合与渲染。
2. 若为错误分类、最终 URL 或诊断字段扩展 FFI DTO，必须先更新 `docs/API_CONTRACT.md`，列明字段是否对 UI 可见、兼容默认值和旧 APK/旧数据库迁移策略，再生成绑定。
3. `searchBooks` 持久化前应保存真实 `origin`、`originOrder`、`bookUrl`；不要以书名精确匹配的单表计数代替最终聚合统计。
4. 封面加载必须从搜索关键路径分离。是否下载封面、何时解码、是否命中缓存应有独立计时，不能作为“原版搜索慢”的推测性归因。

#### 5. 夹具、单元测试和双包验收的落地顺序

建议将样本固定在 `rust/legado-ffi/tests/fixtures/search_s0/`，每个场景使用同名目录：

```text
<scenario>/
  source.json             # 最小脱敏书源
  request.json            # keyword、page、headers、初始 URL
  response.bin            # 保留原始编码的响应
  redirect_chain.json     # 无跳转时为空数组
  expected_original.json  # 原版抓取的标准化预期
  manifest.json           # SHA-256、编码、来源时间、脱敏说明
```

每个夹具至少有三类断言：

1. Rust 单元测试：主搜索单源执行器输出字段、条数、`status`、最终 URL 和保序去重与 `expected_original.json` 相同。
2. Rust 集成测试：`run_multi_stream`、`search_books`、`multi_source_search` 在相同输入下得到同一最终集合与来源数；流式只允许到达时间不同。
3. Flutter 测试：模拟 Rust 流最后一批和错误分类，断言不丢批、不把 `login_required` 渲染为成功空列表，聚合后来源数与夹具一致。

随后再做两台模拟器验收：先在 5556 运行改造 APK，再在 5558 原版运行相同书源快照和关键词。两端均到终态后导出同一结构的 JSON/CSV；比较程序应直接读取该结构并输出差异，而不是通过截图和人工转录决定是否通过。

#### 6. 提交拆分、回退和验收门

建议按以下顺序分提交，避免网络行为、调度和 UI 同时变化导致不可定位：

1. `test(rust)`：加入脱敏响应夹具和原版预期，先让当前主路径暴露差异；
2. `refactor(rust)`：抽取唯一单源执行器，不改变 FFI JSON；
3. `fix(rust)`：依次接入最终 URL、`loginCheckJs`、`bookUrlPattern`、空列表详情回退，每项附对应夹具；
4. `test(rust)`：三入口一致性、取消和错误分类测试；
5. 必要时单独提交 `docs` 与 FFI 契约、生成绑定、Flutter 展示调整。

每个步骤的最低门槛是：相关夹具测试为绿、既有 Rust QuickJS/非 QuickJS 测试无回归、Flutter `analyze`/`test` 通过、5556 冒烟通过。涉及用户验收前，再执行 5558 冒烟和双包终态对比。任何字段、条数、错误分类或排序发生未解释差异时，立即保留旧主入口或通过 feature gate 回退，不将差异归因于网络后继续关闭事项。

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

**编写者**：主 Agent 代码审查
**日期**：2026-08-28
