# 换源修复开发任务书（Rust 轨交接）

> 编制日期：2026-09-03
> 编制者：GLM-5.3-Flash（只读根因定位 + 方案整合）
> 依据：`REFACTOR_CONSOLIDATED_AUDIT_20260903.md` §五 + 2026-09-03 换源专项根因定位
> 基线：HEAD `6fb495aa3b`（master）
> 红线：**严格对齐原版语义**（基准 com.legado.app.release 3.26081008）；FFI/契约变更先冻结 `docs/API_CONTRACT.md`；禁止引入原版不存在的功能与自创容错。

---

## 〇、执行状态（2026-09-03，Rust 轨收口）

> 核实结论：R1/R2/R3 在基线代码中**全部属实**（逐条对照 source_switch.rs/reader.rs/web_book.rs 确认）；U1 属 UI 侧。

| 项 | 状态 | 交付 |
|---|---|---|
| 批次 1 T1+T2（R1/R2 止血） | ✅ **已修** | 提交 `3a78afc049`：switch 接入 get_book_info_with_existing（canReName=false 门控）→ 真实 tocUrl 取目录 → 失败即失败保留旧源；章节转换保留 variable/is_volume 解析值；BookSourceFetcher 加默认退化方法（零 Mock 影响）；mock 单测 2 项（目录页独立源主路径 / 失败保留旧源） |
| 批次 2 T3（book 级变量导出） | ✅ **已修** | `WebBookInfo.variable`（serde additive）+ parse_book_info_from_body 尾部 `export_variables_json` 导出（与目录解析同一机制）；单测 test_parse_book_info_exports_put_variables |
| 批次 2 T4（内容链变量注入） | ✅ **已修** | `get_content` 章节 URL 的 AnalyzeUrl 变量表取自章节 variable（此前恒空表）；reader/audio 链路 `merge_variables_json(book, chapter)`（章节同名键优先，对齐原版 chapter → book 级联）合并进 WebChapter；helper `chapter_url_variables`/`merge_variables_json`（web_book.rs，含单测） |
| 批次 2 T5（候选透传与合并） | ✅ **已修** | `SearchResult`/`AnnotatedCandidate`/`SearchCandidate`/`SourceMatch` 加 `variable`（serde additive）；元素级解析导出 + `result_to_search_book` 落库 + JS 源 JSON 透传；`searchSource` matches 与读库路径均带出；`switchSource` 内按 searchBooks 行 (new_book_url, origin) 取候选变量 ⊕ 详情导出变量合并（详情页后写入者优先）→ `book.variable`；扩展 mock 单测断言合并语义 |
| 契约（T3/T5） | ✅ **已冻结并落地** | `API_CONTRACT.md` 变更记录 2026-09-03 条 + §2.4 注记（零签名变更，全部 additive 字段） |
| 批次 3 T6（换源搜索流式化） | ⏸ **未实施（UI 侧）** | 跨轨：Rust StreamSink 改造须与 Dart 逐源渐显（change_source_notifier/screen）成对交付；本次仅做 Rust 轨，按用户指令 T6 留给 UI 轨批次，契约注记已为流式化预留说明空间。U1 卡顿缓解可先用「换源高级选项默认关 loadInfo/loadToc/loadWordCount」降低首批延迟（UI 侧可独立操作） |
| U1（UI 侧体验） | ➡️ 移交 UI 轨 | 不在本任务书 Rust 轨范围 |

验证：cargo fmt 0 diff / clippy 双段 0 warning / `cargo test --workspace` 全绿 / quickjs 两段门禁 / mock 变量链单测 6 项 + 换源链单测 4 项。

---

## 一、问题与根因（均已定位，带证据）

用户实测：① 换源界面卡；② 换源后大部分源不可用（正文错误 / 获取不到目录）。

| 编号 | 根因 | 证据 |
|---|---|---|
| R1【P0】 | `switch_book_source` 跳过 `get_book_info`：`toc_url` 写死为搜索详情页 URL、`book.variable` 保留旧源旧值、name/author/cover/intro/kind/lastChapter 不更新 | `source_switch.rs:300-365`（更新字段清单 ：357-362） |
| R2【P0】 | 章节落库写死 `variable: None` / `is_volume: false`，丢弃已解析值 → 章节级 `@put` 变量（翻页 token 类）全丢 → 正文错误 | `source_switch.rs:321-340`；`web_book.rs:1277/1386/1493`（`export_variables_json` 已解析进 `WebChapter`） |
| R3【P1·全局】 | 内容链缺 book/source 级变量：reader 主链仅传 `chapter.variable`；`get_content` 构建请求用空变量表 | `reader.rs:507-515/681`；`web_book.rs:861`（`AnalyzeUrl::parse(url, &HashMap::new(), 1)`）；`audio_api.rs` 链路无 book 上下文 |
| U1【体验】 | 换源搜索一次性阻塞返回、无逐源进度：全量源 × 32 并发 × 60s/源全跑完才返回，UI 仅转圈 | `source_switch.rs:58-158`（`block_on` + `buffer_unordered(32)`）；`change_source_screen.dart:776/729` |

## 二、原版基准（必须对齐的语义）

1. **换源执行链**（ChangeBookSourceViewModel.kt:718-731 `getToc`）：
   `if (book.tocUrl.isEmpty()) WebBook.getBookInfoAwait(source, book)` → `WebBook.getChapterListAwait(source, book)`——**先解析真实 tocUrl，再用它取目录**。
2. **失败语义**：`getToc(book).getOrThrow()` → `changeSource` 走 `onError` → `SourceChangeResult.Error` → **换源失败、保留旧源**。禁止拿 new_book_url 硬闯目录（此前的"失败回退"方案已修正废止）。
3. **variable 机制**（AnalyzeRule.kt:857-859、AnalyzeUrl.kt:412-413、RuleDataInterface.kt）：
   规则/JS 中 `@put:{...}` / `putVariable(key,value)` **自动级联写入**，优先级 `chapter → book → ruleData`；**没有专用 variable 规则字段**；`SearchBook.toBook()` 显式复制 `variable`（SearchBook.kt:134）——搜索期变量随候选进入换源。
4. **流式与进度**：`mapParallel(threadCount)` + `onEachIndexed` 逐源回调，`searchSuccess` 逐条刷列表 + `_changeSourceProgress` x/y 进度。

---

## 三、任务拆解（三批，按依赖顺序执行；批次 1 与批次 3 可并行）

### 批次 1：止血（Rust 内部，零 FFI 签名变更）

- **T1（=A.2）** `switch_book_source` 章节转换保留解析值：`variable: wc.variable`、`is_volume: wc.is_volume`（source_switch.rs:321-340 两行）。
- **T2（=A.1·已修正版）** `switch_book_source` 在取目录前接入 `get_book_info(source, new_book_url)`：
  - `toc_url = info.toc_url`（ruleBookInfo 解析的真实目录页 URL），`get_chapters` 改用 `info.toc_url`；
  - 更新 name/author/cover_url/intro/kind/last_chapter/word_count（对齐原版换源允许重命名 canReName 语义）；
  - **`get_book_info` 或 `get_chapters` 失败 → 整个换源失败返回可读错误（含书源名），保留旧源**（单事务回滚已有）。**不得自创"回退 new_book_url"容错**。
- 验收：cargo test + 新增 mock 夹具单测（"目录页独立于详情页"的源换源后目录正确）；5556 冒烟。

### 批次 2：变量链（T3→T4→T5 一根链，**一个提交簇整体交付，不可拆**）

- **T3（=B.4·已修正实现口径）** `parse_book_info_from_body` 导出 book 级变量：
  - 原版无"variable 规则字段"，变量来自 bookInfo 规则执行期间的 `@put`/JS `putVariable` 级联——实现 = bookInfo 规则求值后 `export_variables_json` 收集（**与目录解析 web_book.rs:1277 同一手法，复用现有 put_map/seed_variables 机制，不要新发明**）；
  - `WebBookInfo` 新增 `variable: Option<String>`（serde additive，向后兼容）。
- **T4（=A.3）** 内容链注入 book/source 变量：
  - `reader.rs fetch_chapter_content_inner`：从 DB 读 `book.variable`，与 `chapter.variable` 一并注入 analyzer 上下文与 AnalyzeUrl 变量表（上下文优先级对齐原版 `chapter → book`）；
  - `web_book.rs get_content`（含 AnalyzeUrl 构建与 webJs 钩子）：核对/补齐 `source.variable` 暴露（source_js_bindings 已有 source 绑定，确认 `getVariable` 可达）；
  - `audio_api.rs` 链路同步核对。
- **T5（=B.5）** 候选透传：`SearchCandidate`/`SourceMatch`/switch 响应 JSON 增加 `variable` 字段（additive）；`search_for_switch` 从搜索解析结果带出（若 `SearchResult` 层无 variable，在元素级解析处导出）；`switch_book_source` 以候选 variable 为初值、与详情页导出变量合并（**详情页后写入者优先，对齐原版覆盖语义**）。
  - **契约**：T3/T5 均为 additive 字段，先更新 `docs/API_CONTRACT.md` 再实施。
- 验收：变量依赖源单测（mock 夹具：详情页 `@put` token → 正文请求 header/参数带 token）；cargo 全量门禁 + flutter analyze/test。

### 批次 3：换源搜索流式化（跨轨，契约先行，可与批次 1 并行）

- **T6（=C）** `search_alternative_sources` 改流式：对齐主搜索 `run_multi_stream` 的 StreamSink 模式——逐源完成即推（候选批次 + `searched/total` 进度 + 单源错误），旧一次性 API 按契约标记废弃或保留兼容；
  - enrich（loadInfo/loadToc/loadWordCount）改流内后置或仅对展示项懒加载，**不得阻塞首批到达**；
  - Dart 侧 `change_source_notifier`/`change_source_screen` 逐源渐显 + x/y 进度（对齐原版 `_changeSourceProgress`）；
  - **契约**：新流 API 先冻结 `docs/API_CONTRACT.md`（FRB StreamSink 链路已验证可行，见 Active 计划 P1-1）。
- 验收：500+ 源规模**首个候选到达 <5s**；进度计数准确；flutter test + 5556/5558 冒烟。

### 可选对齐点（低优先，批次 2 内顺手做）

- 原版用 `tocMap[book.primaryStr()]` 复用搜索阶段已抓的详情/目录（loadToc 开启时切换零重复请求）。批次 2 的 T5 可把 enrich 阶段拿到的 `info.variable/toc_url` 一并缓存进候选，切换时直接复用——既对齐原版又减少切换等待。

---

## 四、全局约束

- 每批独立提交：约定式提交中文描述，`fix` 正文写根因；验证通过立即 commit。
- 跨轨改动（T5/T6）先契约后实施；`fix(rust)` 提交脚注关联任务编号。
- 完成后同步：`REFACTOR_CONSOLIDATED_AUDIT_20260903.md`（§五 状态）、`REFACTORING_ACTIVE_PLAN.md`（开放项台账）。

## 五、用户复测清单（交付验收）

1. 四类源换源实测：①目录独立页源；②variable 依赖源（token/host 类）；③普通源；④JS 源——逐个检查目录章节数与正文首段；
2. 探针抽查：换源后 `book.variable` = 新源值（非旧源残留）、`book_chapters.variable` 非 NULL 抽样、`toc_url` 为解析后目录页；
3. UI：首候选到达时间、x/y 进度、失败源的报错文案（应含书源名且不换源）。

---

编写者：GLM-5.3-Flash ｜ 2026-09-03
