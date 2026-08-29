# 搜索/换源结果数量与原版差异——深度对比审查报告（只读审计）

> 审计日期：2026-08-29
> 审计性质：只读，未改动任何代码
> 对比对象：重构轨 `rust/legado-ffi` + `flutter_legado` vs 原版 `app/src/main/java/io/legado/app`
> 原版关键文件：WebBook.kt / BookList.kt / SearchModel.kt / ChangeBookSourceViewModel.kt / SearchBookDao.kt / SearchScope.kt
> 关联文档：SEARCH_PARITY_REMEDIATION_PLAN_20260828.md、REFACTOR_DEFECT_AUDIT_20260828.md

## 审计方法

对「源集合 → 请求构建 → 单源解析 → 过滤 → 去重 → 聚合分桶 → 超时/取消 → 换源链路（网络/DB 双路径）」逐环节做双侧源码比对，每个差异点记录方向（更多/更少）与证据（file:line）。

---

## 一、结论（TL;DR）

主搜索链路经过 S0-E/阶段三修复后**语义高度对齐**，逐环节比对没有发现"单源解析丢条目"级的新分叉；**真正能造成"结果少于原版"的确凿代码缺陷集中在换源链路（D1/D2 两处）**，另有 3 处方向相反的分叉（我们比原版多，D4/D5/D6）和 1 个环境级嫌疑（E1 ARM32 无 JS 引擎）需要先排除。

"搜索正常、换源变少"的不对称现象与 D1 的代码分布完全吻合（主搜索分隔符正则完整、换源侧缺失）。

---

## 二、确凿的"结果变少"分叉（换源链路）

### D1【P1】换源分组过滤的分隔符缺陷——`;`/`；` 分组的书源被整源丢弃

- Dart 侧两处比原版少分隔符：
  - `flutter_legado/lib/src/providers/change_source/change_source_notifier.dart:84`：`g.split(RegExp(r'[,，]'))`——只有中英文逗号；
  - `flutter_legado/lib/src/screens/change_source_screen.dart:121`：`g.split(',')`——分组候选列表聚合同样只有英文逗号。
- 原版分隔符全集是 `,；，;`（`SearchBookDao.kt:13-32` SOURCE_GROUP_MEMBERSHIP_FILTER 递归 CTE、`AppPattern.splitGroupRegex`）。
- **后果**：书源分组写作 `"玄幻;都市"` 时，换源页分组下拉根本不出现"玄幻"；即使 Rust 侧 `source_group_contains`（source_switch.rs:404-424，四分隔符齐全）已正确实现，Dart 预过滤会先把这类源从 `sourceUrls` 里剔掉，Rust 的正确过滤被架空 → **分组换源网络搜索结果系统性少于原版**。
- 对照：主搜索侧的 `_splitGroupRegex = RegExp(r'[,;，；]')`（search_notifier.dart:15）是完整的，所以**主搜索不受此影响**。

### D2【P1·已登记的设计内偏离】换源候选剔除"无详情页 URL"条目

- `rust/legado-ffi/src/api/source_switch.rs:451-455`（Task #21 注释）：`filter(|r| !r.book_url.trim().is_empty())`。
- 原版 `getSearchItem` 对 bookUrl 空的条目**回退 baseUrl 后照常入列表**（BookList.kt:281-284），换源列表能看到它（点击切换才失败）。
- **后果**：解析 bookUrl 失败但书名命中的候选，我们直接从换源列表消失 → 行数必然 ≤ 原版。这是 Task #21 为防"空 URL 崩溃"有意为之，但它是数量差异的直接来源；如需严格对齐可改为"保留展示 + 点击时兜底报错"（本审计不改）。

### D3【P2】换源 DB 优先路径的覆盖面依赖主搜索落库完整性

- 两侧语义一致（原版 `getDbSearchBooks` ChangeBookSourceViewModel.kt:603-625 ↔ 我们 `try_load_change_source_from_db` source_switch.rs:163-226；SQL 的 name 精确等 / author LIKE / enabled=1 / 分组递归成员判断逐项对齐，`search_book_repository.rs:94-135`）。
- 但 Rust 一次性入口 `search_books`/`multi_source_search` **不落库**（只有 `run_multi_stream` 的 `persist_search_books`，search.rs:619-621），原版两个入口最终都走 SearchModel.onEach 落库。当前 UI 只用流式主路径所以无影响，任何改用一次性入口的调用方都会让换源 DB 缓存偏少。

---

## 三、方向相反的分叉（我们比原版多，不是"少"，但属 parity 偏离）

### D4【P2】JS 书源绕过 precision filter

`search.rs:1041` `if source.is_js_source() { return search_js_source(...) }` 在 precision 过滤之前返回；原版把 filter 传进了 `JsSourceBook.searchAwait`（WebBook.kt:47）。精准搜索开启时 JS 源会多出未过滤条目。

### D5【P3】换源筛选框语义更宽

原版只按 `searchBook.name.contains(screenKey)` 过滤（ChangeBookSourceViewModel.kt:184）；我们 `_filteredResults` 是 `sourceName.contains || bookName.contains`（change_source_screen.dart:478-486）。

### D6【P3】同名归一化更宽

`is_same_book_name` 剥首尾括号后比较（source_matcher.rs:178-215），原版 `fName == name` 字面全等（BookList filter）→ 带副标题括号的候选我们保留、原版丢弃。同理 DB 路径我们传 `format_book_name` 归一化后的名字查询，原版传原样 `book.name`。

---

## 四、环境级嫌疑（非代码分叉，但影响最致命，须先排除）

### E1【P0 关联】若对比发生在 ARM32 真机

v7a 的 `.so` 无 QuickJS（REFACTOR_DEFECT_AUDIT_20260828.md §一.1，`liblegado_ffi.so.meta "quickjs":false`）——所有依赖 `@js:` 规则/JS 构建搜索 URL 的书源**静默返回空**，搜索与换源（`search_single_source` 同链路）都会大幅少于原版。x86_64 模拟器对比不受影响。**两边对比前必须先确认 APK 的 ABI 与 quickjs 状态**，否则代码级对比结论无效。

### E2 书源库与配置基线

对比双方的书源库必须同源同快照、启用数一致、`precisionSearch`/`changeSourceCheckAuthor`/`searchGroup` 配置一致（原版换源还有 `changeSourceLoadInfo/Toc/WordCount` 三开关，开启时原版自己也会因详情页抓取失败丢候选）。

---

## 五、逐环节确认对齐的部分（防止误判）

| 环节 | 原版 | 重构 | 判定 |
|---|---|---|---|
| 源集合 | `allEnabledPart`（SearchScope.kt:108+） | `list_enabled_sources`（search.rs:1007） | ✅ |
| 单源超时 | `withTimeout(30000)`（SearchModel.kt:120）/换源 60s | `SEARCH_SOURCE_TIMEOUT=30s`/`SWITCH_SOURCE_TIMEOUT=60s` | ✅ |
| 失败隔离 | `mapParallelSafe` 吞异常（FlowExtensions.kt:59） | drive `catch_unwind` + Err 批次 | ✅ |
| bookUrlPattern 直连/空列表回退/loginCheckJs 双路径 | WebBook.kt:74-110、BookList.kt:62-108 | S0-E `4330acaf9`（parse_search_response_ex search.rs:1214-1312） | ✅ |
| `+`/`-` 前缀、按 bookUrl 去重、LinkedHashSet 保序 | BookList.kt:90-147 | split_book_list_prefix/dedup（search.rs:1496/1508） | ✅（dedup 键多了书名，方向=我们更多） |
| precision 三字段"或"语义 | SearchModel.kt:121-125 | precision_filter_match（search.rs:1455） | ✅（仅 JS 源漏，见 D4） |
| 聚合四分桶（equal/tags/contains/other）+ 桶内 name+author 合并 origins + origin 数排序 | SearchModel.kt:146-215 | _addToBuckets/_materializeResults（search_notifier.dart:386-369） | ✅，`_keepOther=!precision` |
| 规则语法 `||`/`&&`/`%%`/`##`/`@js:` | AnalyzeByJSoup.splitRule | html.rs:620 + analyze_rule.rs 批量回退单规则路径（analyze_rule.rs:626-671） | ✅ |
| HTTP：UA 默认、Cookie 持久化、重定向跟随、GBK 解码 | OkHttp | client.rs Policy::default + http_state DbCookiePersistence | ✅ |
| 换源排序 | bookScore→sourceScore→originOrder | source_matcher.rs:113-122（多了 match score 中间层） | ✅（仅序） |

---

## 六、建议的定位顺序（不改代码，先验证）

1. **先排除 E1/E2**：确认对比环境 ABI quickjs 状态、书源快照与配置一致。
2. **换源分组场景复现 D1**：找一个分组字段含 `;` 的书源，分组换源搜索，对比启用源数（Dart debugPrint `sourceUrls=...`（change_source_notifier.dart:100）会直接暴露被剔除的源）。
3. **换源全量场景复现 D2**：对比两侧"书名命中但 bookUrl 解析失败"的源——原版列表里有、我们没有。
4. 主搜索若仍少：用 `LEGADO_SEARCH_PHASE_TIMING=1` 分段计时看超时截断分布（30s 超时内未完成源与原版同丢，但若我们在 URL 构建/解析阶段耗时显著更长，等效于丢更多慢源）。

---

编写者：GLM-5.3-Flash ｜ 2026-08-29
