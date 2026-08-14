# 解析引擎对齐缺口(G1-G15)修复进度与 A* 验收矩阵

> 性质：进度 + 交接文档。本文记录「书源解析规则接入验收」发现的 15 项对齐缺口（G1-G15）的修复进度、剩余项精确诊断，以及 A* 实网验收测试矩阵。
> 编写者：DeepSeek Harness ｜ 2026-08-15

## 一、结论速览

- 已完成 **10/15**，全部通过 `cargo test -p legado-ffi --features quickjs`（337/0 基线）逐项回归。
- 分支：`feature/rust-parser-gap-fix`，8 个提交（约定式提交 `fix(rust):`）。
- 剩余 5 项（G4/G5/G8/G11/G12）均为**深层机制或受并发文件制约**，非单点替换，见 §三精确诊断。

## 二、已完成（10/15）

| 编号 | 内容 | 提交 | 测试 |
|---|---|---|---|
| G1 | JsonPath 完整语义（换 jsonpath-rust 0.7.5：过滤器/递归/引号键/切片步长 + 负索引预处理） | 735b65df3 | legado-parser 224 |
| G2 | jsoup 伪类十类（:contains/:containsOwn/:matches/:matchesOwn/:has/:eq/:lt/:gt/:first/:last） | 2d8e638cb | legado-parser 229 |
| G3 | 正则 `&&` 多级链（regex_extract） | 2cabc1713 | legado-parser 225 |
| G6 | 书源校验 ruleSearch.checkKeyWord（effective_keyword） | 01b324821 | legado-net 32 |
| G7 | `@@` 前缀剥 2 字符强制 CSS | d08fa47d4 | legado-parser 232 |
| G9 | HTML `[..]` 括号/区间索引（[n]/[n,m]/[!n]/[a:b:step]/[-1:0] 反向） | 53b0ce482 | legado-parser 234 |
| G10 | `:` 前缀 allInOne 正则（getElements 路径） | d08fa47d4 | legado-parser 232 |
| G13 | `html` 提取剥离 script/style + `all` 关键字修正 | 34c11fcc4 | legado-parser 233 |
| G14 | isUrl 多匹配取首元素（对齐 getString0） | d08fa47d4 | legado-parser 232 |
| G15 | AES/ECB/NoPadding 加解密 | dce9a252a | legado-core 全绿 |

## 三、剩余 5 项精确诊断

### G4 concurrentRate（P1，legado-net）
- **语义**：原版 `ConcurrentRateLimiter(source)` 解析 `"N/毫秒"`（访问数/间隔）做**节流**，或纯 `N` 做并发上限；`withLimit{}` 包裹请求（AnalyzeUrl.getStrResponse + JsExtensions.http/api/ajax）。
- **现状**：Rust `rate_limit.rs` 的 `RateLimiter`/判 DomainRateLimiter 只做 **semaphore 并发上限**，无 `N/毫秒` 节流；`concurrent_rate` 仅字段落库零消费。
- **改法**：rate_limit.rs 新增间隔节流器 + 在 AnalyzeUrl/请求构建处把 `source.concurrent_rate` 接入（请求构建在 web_book.rs，见 G5 冲突说明）。

### G5 formatJs（P1，web_book.rs —— 并发未提交改动）
- **语义（纠正）**：原版 `BookChapterList.kt:138-160` 的 `formatJs` 是**章节标题格式化 JS**：对每章以 bindings `{gInt=0, index, chapter, title}` `eval(formatJs)`，结果**改写 bookChapter.title**（非「chapterUrl 变换」）。用于去"第X章"前缀/重编号等。
- **改法**：web_book.rs 章节解析循环后加一轮，用 JS executor 注入 bindings 逐章 eval 并回写 title。
- **冲突**：`web_book.rs` 有另一 agent 2026-08-15 未提交的「七猫 url,{json} 请求选项」修复（改 get_book_info/get_content/get_chapters 的请求抓取段，不碰章节解析段）；同一文件不可混合提交，需先收口。

### G8 $n 分组引用（P2，analyze_rule.rs）
- **语义**：`SourceRule.splitRegex` 把规则按 `$1..$99` 拆成「字面片段 + 分组引用」，`makeUpRule(result)` 逆行重建时用**前序 SourceRule 的捕获组 List** 代入 `result[n]`。
- **现状**：Rust 无 `ruleType/ruleParam` 多段重建运行时，`$n` 全仓零命中。
- **改法**：需移植 splitRegex 分解 + makeUpRule 重建（含 JS/getRuleType 分支），属小架构级补全，非单点替换。

### G11 规则内 `{{expr}}`（P2，analyze_rule.rs）
- **语义**：`makeUpRule` 的 jsRuleType 分支：`{{js}}` → evalJS（引用 result）。
- **风险**：Rust 已为丁斐/漫画人书源新增 `{{$.path}}` JSONPath 语义；需精确区分 `{{$...}}`（JSONPath，保留）与 `{{非$...}}`（JS eval，新增）。

### G12 URL `type` hex 响应（P2，analyze_url.rs + 网络层 + web_book.rs）
- **语义**：原版 `AnalyzeUrl` 的 `type` 选项（如 `"hex"`）→ 响应体为**字节数组 hex 编码**（`HexUtil.encodeHexStr(getByteArrayAwait())`），非文本。
- **现状**：Rust 把 `"type"` 错读入 `content_type`；`response_type` 字段全仓零消费，且 hex 字节编码消费端在网络层完全未实现。
- **改法**：① `"type"`→`response_type`；② 网络层/抓取路径按 response_type 对字节做 hex 编码（消费端在 web_book.rs 请求链路，撞 G5 冲突）。

## 四、A* 实网验收测试矩阵（每项映射到已验证/待修缺口）

| 书源类型 | 验证点 | 关联缺口 |
|---|---|---|
| 文本 HTML 源（思路客/55 文学） | `@css` 选择器链、`@text/@html/@href`、点号/括号索引、`##` 替换 | G7/G9/G13/G14 |
| JSON API 源（漫画/听书/影视） | `@json`/`$..name`/`[?(@.x==..)]`/`$['key']`/`[-1]` | G1 |
| 伪类文本源 | `:contains/:has/:eq` 过滤 | G2 |
| 正则多级源 | `rule1&&rule2` 链取数 | G3 |
| AES 密文源（51漫画/七猫） | `AES/CBC/NoPadding`/`AES/ECB/NoPadding` 解密 | G15 |
| 需 checkKeyWord 源 | 源校验搜索关键字 | G6 |
| formatJs 源 | 目录标题格式化 | G5（待修） |
| concurrentRate 源 | 每源请求节流防封 | G4（待修） |
| $n/{{js}}/type:hex 源 | 分组引用/规则内 JS/hex 响应 | G8/G11/G12（待修） |

## 五、下一步建议

1. 先收口 `web_book.rs` 并发改动（七猫 url,{json}），再修 **G5**（标题 formatJs，自包含于章节解析段）与 **G12**（hex 消费端）。
2. G4 / G8 / G11 建议派独立的 `full-stack-engineer` 子代理（上下文隔离、可并行、文件已排序不重叠）分头实现并各自补单测。
3. 全部 15 项落地后，执行 A* 实网验收（真实书源矩阵 + 双模拟器 5556/5558 冒烟）。
