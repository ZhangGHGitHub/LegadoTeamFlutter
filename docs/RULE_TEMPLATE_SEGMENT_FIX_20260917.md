# 换源「新书源未解析到任何章节」根因报告（规则模板段 + 目录参数语义 双层）

- **日期**：2026-09-17 ~ 2026-09-18
- **版本**：2.0.283+284 → **2.0.284+285**
- **影响文件**：`rust/legado-parser/src/analyze_rule.rs`、`rust/legado-parser/src/lib.rs`、`rust/legado-parser/src/html.rs`（仅测试）、`rust/legado-ffi/src/api/web_book.rs`、`rust/legado-ffi/src/api/source_switch.rs`（报错文案）
- **触发**：用户报告「同一个书源（松鹤庭沐·言璃），目标风格版可以搜到且切换到这个书源，重构版的不行」

## 1. 现象与失败点定位

实机复现（MuMu 实例 `192.168.1.19:5555`，`io.legado.flutter_legado`）：

1. 书籍详情页（斗罗大陆）点「换源」→ 列表**能搜到**「🏷松鹤庭沐·言璃」（显示「最新：已完结 / 298.6万字」）；
2. 点该行 → 确认弹窗点「切换」→ 底部弹出 **`换源失败: Parser error: 换源失败：新书源未解析到任何章节，已保留原书源与目录`**，来源仍为「🧭无极书院」。

截图：`docs/parity_shots/songhe_template_fix_20260917/ours_01_changesource.png`（搜到了）、`ours_04_after_t4.png`（失败原文）、`ours_06_after_back.png`（未切换）。
**结论**：失败不在「搜」，而在「切换」；且**不是发现页/导入/搜索**问题（发现页 `exploreUrl` 解析实测正常，85 条分类）。

## 2. 根因链（逐环实测）

| # | 环节 | 实测事实 |
|---|---|---|
| 1 | 书源数据 | 两版库中该源**完全一致**：`enabled=1`、`enabledExplore=1`、`exploreUrl` 逐字节相同（sha256 前 16 位 `1513eed9dd91ceed`） |
| 2 | 搜索阶段 | 候选落库的 `bookUrl` 竟是**搜索页地址** `https://newopensearch.reader.qq.com/wechat?keyword=…&amp%3Bstart=0…`，而 `coverUrl`/`name`/`author`/`wordCount` 均正确 |
| 3 | 代码 | `rust/legado-ffi/src/api/web_book.rs:763-768` 仅在 `eval_rule_string(bookUrl 规则)` **返回空**时才回退 `base_url` → 说明规则求值取空 |
| 4 | 规则求值 | 该 `bookUrl` 为多行 JS 链 `$.bid` ⏎ `<js>1100000000+parseInt(result)</js>` ⏎ `…intro-info?bookid={{result}}`；**链末段（非 JS 段）被当 CSS 选择器**去解析上一段的文本（`1100468021`）→ 空串 |
| 5 | 下游连锁 | bookUrl 是搜索页 URL → 详情 `init: $.data.bookInfo` 取不到（不报错、字段全空）→ `tocUrl` 的 `{{$.resourceID}}` 为空 → 请求 `…all-chapter?bookId=`（curl 实测 `ret:422`、**无 `rows`**）→ 0 章 → 上述报错 |
| 6 | 正确链路对照 | curl 实测：搜索 `bid=468021` → `1100000000+468021=1100468021` → `intro-info?bookid=1100468021` 返回 `resourceID=1100468021` → `all-chapter?bookId=1100468021` 返回 **712 章**（接口与书源均健康） |

**判定性反证**：同一书源的 `coverUrl` 是**同结构多行链**，唯一区别是末段用 `@js:` 而非 `{{result}}` 模板 —— 它解析**完全正确**（`…/cover/21/468021/b_468021.jpg`）。同一条链机制只有模板尾段失败 ⇒ 差异点只能是 `{{…}}` 段的处理。

## 2b. 第二层根因：换源目录抓取的参数语义错位（独立于规则缺陷，已实测确证）

修好第一层后 `ruleSearch.bookUrl` 已正确（实机重搜后候选地址 = `…intro-info?bookid=1100468021`），但换源**仍然失败**。离线用真实源跑「详情 → 目录」链路，定位到第二个断点：

| 环节 | 实测事实 |
|---|---|
| 详情解析 | ✓ 成功：`toc_url = https://bookshelf.html5.qq.com/qbread/api/book/all-chapter?bookId=1100468021`（`init` 与 `{{$.resourceID}}` 求值均正常） |
| 目录抓取 | ✗ `get_chapters_with_vars(source, toc_url, vars)`（`web_book.rs:907-915`）把**已解析好的目录页 URL** 放进 `book_url` 形参且 `known_toc_url=None` |
| 连锁 1 | known-toc 守卫（`web_book.rs:1121-1122`）未命中 → 走「详情页」else 分支，把**目录页当详情页抓取** |
| 连锁 2 | 在该响应体（all-chapter JSON）上跑 `ruleBookInfo.init = $.data.bookInfo` → 取空；重推 `tocUrl` → `{{$.resourceID}}` 空 → 得到 `…?bookId=`（空 bookId） |
| 连锁 3 | 二次抓取 `…bookId=` → 服务端 `ret:422`（实测）→ `$.rows` 0 元素 → 返回 `Ok(vec![])` |
| 报错 | `source_switch.rs:667-671` 命中空数组分支 → 报「新书源未解析到任何章节」（把「目录页被当详情页」误报成「未解析到章节」） |

**对照实测（同一源、同一 URL、同一 header 路径）**：`get_chapters_with_hints(known_toc=该目录 URL)` → **712 章**；`get_chapters_with_vars(详情页 URL)` → **712 章**；`get_chapters_with_vars(目录页 URL)` → **0 章**（复现症状）。

**影响面**：该缺陷对换源链路 100% 触发，但只有「tocUrl 规则依赖详情响应体」的源会真正炸（松鹤 `{{$.resourceID}}` 属此类）；tocUrl 为静态字符串的源会因重推得到同一地址而侥幸通过（多一次无谓请求）。函数注释宣称的「对齐原版 getChapterListAwait」与本实现相反——恰恰是「目录页与详情页不同」的源被打挂。

**修复方向**：让 `get_chapters_with_vars` 的语义 = 「入参就是已解析的真实目录页」，直接抓取该地址并套 `ruleToc`，不再经 bookUrl → init → tocUrl 重推导；并让报错文案带上目录地址便于排查。

## 3. 上游参考实现（本仓 `app/…/analyzeRule/AnalyzeRule.kt`）

| 上游锚点 | 语义 |
|---|---|
| `AppPattern.kt:7` | `JS_PATTERN = <js>([\w\W]*?)</js>|@js:([\w\W]*)` —— 一条规则按 JS 段拆成「文本段 / JS 段」链 |
| `AnalyzeRule.kt:590 splitSourceRule` | 拆段生成 `SourceRule` 列表 |
| `AnalyzeRule.kt:699-707`（`SourceRule.init`） | 段内含 `@get:{…}`/`{{…}}`（`evalPattern`，`:1020`）且位于段首或 `##` 之前 → **mode = Mode.Regex** |
| `AnalyzeRule.kt:341-347` | 链式执行：每段前 `makeUpRule(result)`，`result` 逐段传递 |
| `AnalyzeRule.kt:773-832 makeUpRule` | `{{expr}}`：`isRule`（`:834`，前缀 `@`/`$.`/`$[`/`//`）→ 走单源规则；否则 `evalJS(expr, result)`（**result = 上一步结果**）；失败 `null -> Unit`（空串）；**`:821` 才 `split("##")`** |
| `AnalyzeRule.kt:355` | `getString` 的 `when(mode)` 落 `else -> rule`：Regex 模式把回填后的**字面串原样返回**（不做选择器解析） |
| `AnalyzeRule.kt:546-556 replaceRegex` | replaceFirst = `matcher.group(0)!!.replaceFirst(regex, replacement)`；**无匹配 `return ""`** |
| `BookList.kt:281-284` | `searchBook.bookUrl = analyzeRule.getString(ruleBookUrl, isUrl=true)`，**空则回退 `baseUrl`**（我方 `web_book.rs:763-768` 即此写法） |
| `BookList.kt:230` | kind = `getStringList(ruleKind)?.joinToString(",")` |

## 4. 修复内容

1. **链内/单步模板段按模板求值后字面返回**（`eval_js_chain_steps` 的 Extract 段 + 单步 `template_shape` 分支）：
   - 规则型参数走单源规则（`content` 为上下文）；JS 表达式参数以**前序步结果**为 `result` 执行 JS；`@get:{k}` 走变量表；回填失败 = 该参数空串（对齐 `null -> Unit`）。
2. **模板判定域 = 拆分后的提取核心**（`split_hash_replace(...).0`）——避免「选择器 + 跨度外 `##`（替换段含 `{{`）」被误判为模板。
3. **含 `@js:`/`<js>` 的规则永不进模板分支**——JS 体内可合法出现 `{{…}}`（52 条规则/26 源依赖）。
4. **`##` 拆分改为 span 感知**（`split_top_level_hash`，parser 与 FFI `split_rule_replace_parts` 共用）：跳过落在 `{{…}}` 跨度内的 `##`，而非「全部在跨度内才保护」。
5. **多跨度纯模板判为模板**（松鹤 kind `{{…##…}}\n{{…}}`）；单跨度仅规则型参数进模板（**保留既有 G11 语义**）。
6. **replaceFirst 无匹配 → `""`**，与上游及 FFI `apply_regex_replace` 三处口径统一。
7. 模板段内单花括号 `{$.x}` 复用 `process_inner_rules` 回填。

## 5. 回归风险与两轮代码审查

- 首轮审查（`code-reviewer`）判定 **不可合入**，发现本改动引入的真实回归：
  - **P0-1** `@js:` 单步体内含 `{{…}}` → JS 不执行、字段变成 JS 源码文本（52 条规则 / 26 源）；
  - **P0-2** 「选择器 + 跨度外 `##` 替换段含 `{{`」被整条判为模板 → 抽取结果变成选择器文本（21 条 / 20 源，**其中正文 10 条**）；
  - **P1-1** 混合形态 `##` 守卫整体失效（82 条）；**P1-2** replaceFirst 无匹配口径不一致；**P1-3** 多 span 纯模板未识别（松鹤 kind 反而 `Err`）；**P1-4** G11 被顺带翻转（16 条）。
- 按上述意见逐项收敛后复审（结论见提交正文）；首轮审查同时校正了一处对上游的误读（replaceFirst 无匹配应是空串）。

## 6. 回归测试索引

`rust/legado-parser/src/analyze_rule.rs`：`test_template_chain_bookurl_full`（目标缺陷）、`test_template_url_segment_standalone`、`test_pure_selector_js_chain_unchanged`、`test_g11_whole_rule_js_param_keeps_selector_eval`、`test_expand_js_refs_in_js_segments_only`、`test_template_param_inner_hash_replace`、`test_split_top_level_hash_unit`、`test_split_hash_replace_span_aware`、`test_hash_replace_first_group0_semantics`、`test_atjs_step_body_with_template_executes_js`、`test_js_tag_step_body_with_template_executes_js`、`test_hash_replace_outside_span_with_template_param`、`test_href_shunt_template_replace`、`test_songhe_kind_two_span_template`、`test_sel_template_with_suffix_and_combinators`、`test_replace_first_no_match_yields_empty`、`test_mixed_form_hash_replace_no_half_garbage`、`test_mixed_form_nested_replace_chain`、`test_cover_url_js_tail_chain_unchanged`；`rust/legado-ffi/src/api/web_book.rs`：`test_apply_regex_replace_no_match_empty_cross`。

真实书源 fixture 回归（`cargo run -p legado-ffi --example dbg_songhe_bookurl --features quickjs -- legado-ffi/tmp_songhe.json legado-ffi/tmp_songhe_search.json`）：完整 bookUrl 链 `空串 → …intro-info?bookid=1100468021`；coverUrl 链不变。

## 7. 遗留项

已登记 `docs/REFACTORING_ACTIVE_PLAN.md` **P2-6**：`get_elements` 链内模板段未同步（当前 0 条真实规则命中）、非法正则回退口径三处不齐（旧账）、`{{js}}`+选择器后缀/组合符的语义取舍需单独评审（本批保持 G11 不动）。

## 8. 影响面

- 本次修复的直接受益书源（`bookUrl` 同形写法）：**2 个**（「🏷松鹤庭沐·言璃」「🏷QQ浏览器」）；
- 标签字段半截串（`{{$.categoryInfoV4` 之类）：**9 个书源 / 67 条候选**（由 span 感知拆分修复）。

## 9. 验收证据

**门禁（本机，提交前复跑）**
- `cargo test -p legado-parser` → **275 passed / 0 failed**（含 10+ 条模板回归测试）
- `cargo test -p legado-ffi` → **356 passed / 0 failed / 19 ignored**（含 `toc_no_rederive_tests` 锁「不得把入参当详情页」）
- `cargo test -p legado-core` → 792 passed / 0 failed；`cargo test --workspace` → **exit 0，零失败**
- `cargo clippy -p legado-parser --all-targets` → 0 告警（ffi 新增代码 0 告警）

**真实书源 fixture（离线，quickjs）**
- `cargo run -p legado-ffi --example dbg_songhe_bookurl --features quickjs -- …`：完整 bookUrl 链 `空串 → https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1100468021`
- `cargo run -p legado-ffi --example dbg_songhe_switch_break2 --features quickjs -- legado-ffi/tmp_songhe.json`：`get_chapters_with_vars 返回章节数` 由 **0 → 712**；对照 `get_chapters_with_hints(同 URL)` = 712

**实机（MuMu `192.168.1.19:5555`，release APK 2.0.284+285）**
- 修复前：`换源失败: Parser error: 换源失败：新书源未解析到任何章节…`（`docs/parity_shots/songhe_template_fix_20260917/ours_04_after_t4.png`、QA `fail1_close_4.png`）
- 重搜后候选地址已正确（`…intro-info?bookid=1100468021`）
- **切换成功**：详情页「来源」变为 `🏷松鹤庭沐…`、「共 712 章」、最新章刷新（`docs/parity_shots/songhe_template_fix_20260917/v3_06_t8.png`）
- 落库实测（含 `-wal` 一并拉取）：`originName = 🏷松鹤庭沐·言璃` ✓、`chapters` 表 **712 行** ✓、`tocUrl` 落库为 `…all-chapter?bookId=`（**丢 bookId**，见 §7 遗留项 (g)）

编写者：主代理（ZCode）｜ 全栈工程师子代理 ｜ 2026-09-18
