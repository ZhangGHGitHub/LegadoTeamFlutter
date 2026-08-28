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

## 七、P0-1 实施记录（2026-08-28，进行中）

### 7.1 基线记录（对应 §六.4：实施前必须重新记录 HEAD / diff / 书源数据版本）

| 项 | 值 |
|---|---|
| HEAD | `3db639ddc`（full `3db639ddc03f1c470e2c802b0c67ddbc7a89ce62`） |
| 工作树未提交改动 | 7 files changed, 149 insertions(+), 52 deletions(-)：G4 书源 `concurrentRate` 固定窗口节流重构（新增 `rust/legado-ffi/src/api/source_rate_limit.rs`；`search_single_source` / `web_book.rs` / `source_switch.rs` 接入），换源并发 `buffer_unordered(32)` + 单源 60s 超时 + DB 键 `format_book_name/author` |
| 书源数据版本 | 仓库根目录**无规范脱敏快照 .db**（仅存在调试用 `tmp_*.db` / `.tmp_*_live.db`）；探针与 E2E 依赖从 emulator-5558 `run-as io.legado.app.debug` 拉取的 `legado.db`（见审计文档 §8）。**结论：P0-1 步骤 1–2 的固化夹具尚未落地，需在下一步建立。** |

### 7.2 P0-1 步骤 3：QuickJS feature「构建命令 / Cargo feature / 产物符号」三方一致性校验

| 校验腿 | 证据 | 结论 |
|---|---|---|
| 构建命令 | `rust/scripts/build-android.ps1` release/debug 均执行 `cargo build ... -p legado-ffi --features quickjs`；**但含静默回退**——quickjs 构建失败时重试「无 quickjs」并仍产出 .so（原脚本无任何标记） | 命令存在，但有降级路径 |
| Cargo feature | `rust/legado-js/Cargo.toml`：`quickjs` 为可选 feature（`default = []`），opt-in；rquickjs 0.9 编译 QuickJS C 代码 | 已定义、非默认 |
| 产物符号（当前 `flutter_legado/android/app/src/main/jniLibs/`） | 见下表 | **不一致** |

当前三个 ABI 的 `.so` 实测：

| ABI | contentHash | builtAt | rquickjs / js_execute 符号 | 体积 | quickjs？ |
|---|---|---|---|---|---|
| arm64-v8a | 1432806422 | 2026-08-27 | ✓ 存在 | 38.1 MB | 是 |
| x86_64 | 1432806422 | 2026-08-27 | ✓ 存在 | 38.0 MB | 是 |
| **armeabi-v7a** | **1734781793** | **2026-08-15** | **✗ 缺失** | **23.9 MB** | **否（陈旧）** |

**发现（S7 已证实，非推测）**：`armeabi-v7a/liblegado_ffi.so` 为**陈旧产物**——FRB `contentHash` 与其余两 ABI 不同、构建时间早 12 天、体积少约 14 MB，且二进制内无 `rquickjs` / `js_execute` 符号。即 v7 设备实际运行的是旧代码 + **无 JS 引擎**，`@js` 规则会静默返回空结果（正是 S7 描述的风险）。三方一致性校验对 armeabi-v7a **不通过**。

**整改动作（本轮）**：
1. `rust/scripts/build-android.ps1` 增加 `.meta.quickjs` 字段并逐 ABI 记录 `$QuickJsUsed`，使「产物是否含 quickjs」可机读、杜绝静默降级复发（已改，语法校验通过）。
2. 以加固后的脚本重建 armeabi-v7a（`--features quickjs`），使三 ABI 与当前代码一致 → P0-1.3 三方一致性达成。NDK `D:\Android\ndk\28.2.13676358` 已就绪，armv7 clang/llvm-ar 工具链确认存在。

**重建结果与根因（已证实）**：以加固脚本重建 armeabi-v7a 时，`--features quickjs` 构建在 **`rar` crate（v0.4.0）编译阶段失败**——32 位 armv7 上 `u64: ToUsize` 未实现（`nom::take::<u64>` 要求 size 类型可转 usize，32 位平台 u64 不满足）。脚本静默回退到「无 quickjs」并产出 .so。复验：新 armv7 `.meta` = `contentHash=1432806422`（已与其余两 ABI **一致**）、`quickjs=false`、无 `rquickjs`/`js_execute` 符号。

即根因不是「忘了重建」，而是：**当前 quickjs feature 集合含 `rar` crate，而 `rar` 无法在 32 位 armv7 编译 → armeabi-v7a 根本装不进 JS 引擎**；旧脚本的静默回退把这一平台限制掩盖成了「普通书源能搜到」。

- 佐证：Android 侧 RAR 本就桩化（`archive_utils.rs`：`import_rar_file`/`list_rar_book_files` 在 Android 直接返回 `Err("Android 平台暂不支持 RAR")`），故 `rar` crate 对 Android **无实际功能贡献**，却拖垮 32 位 JS 构建。
- **决策点（需确认，超出纯搜索范围，属书源/书籍格式依赖治理）**：① 将 `rar`（及同类非 JS 归档依赖）从 quickjs feature 拆出为独立可选 feature → armeabi-v7a 可装 JS 引擎；或 ② 接受并显式声明 armeabi-v7a 为「无 JS」遗留 ABI，甚至不再随 APK 分发 armeabi-v7a（现代设备多为 64 位）。任一方向都需双轨确认后改 `legado-js/Cargo.toml` feature 结构。

**状态**：P0-1.3 **三方一致性对 arm64/x86_64 通过、对 armeabi-v7a 不通过（根因已定位，属平台/依赖限制）**；降级已由 `.meta.quickjs` 机读化（不再静默）。P0-1 步骤 1–2（固化离线夹具）与步骤 4（双包基线）仍待实施。

### 7.3 P0-2 前置：纯离线可验证的 S2 行为已落地（2026-08-28，进行中）

**解锁判定**：§五.1 改主解析器的门槛为「未确认 QuickJS feature **或** 没有夹具时不改」。当前两者均已满足——QuickJS 已确认（P0-1.3）、规则一致性夹具已存在（`search.rs` 40 个既有单测覆盖解析器当前行为）。因此可**先行落地纯离线、无需网络/模拟器即可验证的 S2 行为**；而依赖网络的 S0 行为（loginCheckJs / 重定向最终 URL / 空列表详情页回退）仍须待 P0-1.4 双包基线后再并入主路径。

**已实现并验证（对齐 `BookList.kt`，逐条注明出处）**：

| 行为 | 类别 | 原版出处 | Rust 落地 | 验证 |
|---|---|---|---|---|
| bookList `-`/`+` 前缀（`-` 逆序、`+` 仅去前缀） | S2 | `BookList.kt:90-96,145-147` | `split_book_list_prefix()`：get_elements 前剥离、dedup 后按 reverse 反转 | 3 个单测（minus / plus / no-prefix） |
| 结果去重（LinkedHashSet 语义，保留首次出现） | S2 | `BookList.kt:142-144` | `dedup_search_results_keep_first()`：键 = 书源 + 书名 + bookUrl（同源同详情页视为重复，不同书名不误伤） | 2 个单测（保序 / 去重 / 空表） |
| intro 简介净化（块级标签→换行、删其他标签含 img、折叠空白） | S2 | `BookList.kt:260` + `HtmlFormatter.formatIntro` | `html_formatter::format_intro()`：9 步纯字符串净化，逐条对标原版 formatText；parse_search_response intro 字段套用 | 6 个单测（块级/内联标签/注释/换行折叠/nbsp/空） |
| kind 多标签逗号分隔 | S2 | `BookList.kt:230` `getStringList(...).joinToString(",")` | parse_search_response kind 字段将批量 `\n` 连接串换为 `,`（等价 joinToString(",")，**复用共享 CSS 解析、零额外 parse**） | 1 个单测（3 元素 → "科幻,都市,玄幻"） |
| source/cookie JS 上下文（搜索规则可用 `source.getKey()` 等） | S1 | `AnalyzeRule(ruleData, bookSource)` + `BaseSource.getKey()` | parse_search_response 顶层+元素级 AnalyzeRule 改用 `construct_analyzer_with_source_context`，注入 `book_source_js_setup_script(source)`（source/cookie/cache 绑定 + BookSource 方法）；复用发现页已验证构造器 | 1 个单测（name=`@js:String(source.getKey())` → bookSourceUrl，quickjs 下断言） |

**验证结果**：新增 13 个单测全绿——非 quickjs 构建 12 个（5 前缀+去重、6 intro 净化、1 kind 逗号分隔）+ quickjs 构建 1 个（S1 source 上下文）；既有解析器单测与异步并发/超时单测全绿，**quickjs 全量搜索+js_executor 66 测试零回归、非 quickjs 39 测试零回归**。

> 关键修正：kind join(",") 曾误判为「需移出共享 CSS 批量单独 parse、会回退 2026-08-18 提速」；实为 `css_vec_to_string` 已把多匹配以 `\n` 连接，直接重连分隔符即可，**零性能成本**。

**尚未并入主路径的 S0 行为（需真实响应/模拟器验证）**：
- bookUrlPattern 详情页判定 + getInfoItem（`BookList.kt:62-81`）
- 空列表详情页回退（`BookList.kt:100-108`）
- loginCheckJs / HTTP 重定向最终 URL

> 注：bookUrl 空值回退 `baseUrl`（`BookList.kt:282-284`）**早已实现**（parse_search_response 中 raw_book_url 为空时回退 `source.book_source_url`），非待办。

**状态**：P0-2 **纯离线可验证部分已全部落地并验证——S1（source/cookie JS 上下文）+ S2 字段级（前缀 + 去重 + intro 净化 + kind 逗号分隔）**；仅剩依赖真实响应的 S0 行为（详情页判定 / 空列表回退 / loginCheckJs / 重定向最终 URL）待 P0-1.4 双包基线解锁。整体计划仍开放。

### 7.4 P0-2：multi_source_search 委托统一执行器，三入口驱动器对齐（2026-08-28）

**关键发现**：三个 Rust 搜索入口的**解析器早已统一**——`search_books` / `run_multi_stream` / `multi_source_search` 全部经 `search_single_source` → `parse_search_response`（共享解析）。残留分叉仅在**驱动器层（S6）**：`multi_source_search` 曾走独立的 `MultiSourceSearcher`/`WebSourceSearcher`——10s **全局**超时、20 条/源截断、跨源去重 + 相关性排序；而 `search_books` / `run_multi_stream` 用 `drive_source_batches`（有界并发 32、每源 30s、无截断）。此分叉违反计划约束 #5（不得以全局 10s 替代每源 30s、不得引入未验证截断）。

**整改动作（已提交 `22a8df7d9`）**：

| 项 | 说明 |
|---|---|
| multi_source_search 委托 | 改为 `drive_source_batches` + `search_single_source`（与 search_books **同构**），移除独立驱动器与本地取消监听任务 |
| 聚合职责下沉 | 跨源去重 / 相关性排序下沉至 Flutter，对齐原版 `SearchModel`：Rust 出原始单源结果、UI 按 mergeItems 聚合 |
| FFI 契约 | `AnnotatedCandidate` JSON 字段结构**保持不变**；`relevance_score` 恒为 0.0（统一执行器不做跨源排序，聚合是 Flutter 职责） |
| 依赖清理 | 移除 search.rs 对 `MultiSourceSearcher` / `SearchConfig` 的 import（仅单测仍引用 `WebSourceSearcher`，保留其实现供测试） |

**验证**：`cargo build -p legado-ffi` 通过；legado-ffi lib 全量测试 **非 quickjs 309 passed / quickjs 367 passed，0 failed**（无回归）。Flutter analyze 在本环境启动挂起（工具/网络问题，与本次 Rust-only 改动无关）——本改动不改 Dart、不改 FFI 签名、不改 JSON 结构，Dart 侧契约不受影响。

**状态**：P0-2 **S6 驱动器层已对齐**（三入口共用 `drive_source_batches` + `search_single_source`）。仍未标记完成——按 §五.5 需 S0 网络行为（详情页判定 / 空列表回退 / loginCheckJs / 重定向最终 URL）+ 两级模拟器冒烟后方可关闭。整体计划仍开放。

*实施记录编写者：Reasonix ｜ 2026-08-28（P0-1.3 校验 + P0-2 离线可验证部分：S1 source 上下文 + S2 前缀/去重/intro/kind + S6 multi_source_search 驱动器对齐）*
