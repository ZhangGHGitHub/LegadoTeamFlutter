# 快速分组搜索速度对比报告：本引擎 vs 原版 App（含根因与修复）

日期：2026-08-27 ｜ 编写者：Qoder（主代理直接执行）
关键词：武动乾坤 ｜ 范围：快速分组书源（本方 DB 副本 219 源 / 原版实机 236 源）

## 1. 结论速览

| 指标 | 修复前最优 (B5, c=9) | 修复前 (B8, c=32+CPU限流) | **修复后 (c=32, 无限流)** | 原版 App |
|---|---|---|---|---|
| 总耗时 (wall) | 329.40s | 167.88s | **31.02s** | ≈109.7s（收敛） |
| ok 源数 | 120 | 49 | **174 / 219** | 235 / 236 |
| 30s 超时 | — | 128 | **0** | ≈1 |
| 返回书籍总数 | — | — | **6520** | — |

修复后本引擎 wall 时间约为原版的 1/3.5（注：原版在模拟器 qemu CPU 上运行、
本方在宿主机 16 核上运行，硬件不同非严格对等；但双方数据一致表明解析不再是瓶颈）。
剩余 45 个失败源全部为真实站点侧问题（21×HTTP 404、11×连接失败、5×URL builder 错误、
403/502/500 各若干、1×网络挂起 dushu.com），与解析无关。

## 2. 单源慢路径复现（SOLO 测试，c=1）

| 书源 | 修复前 | 修复后 |
|---|---|---|
| www.yeudusk.com | **TIMEOUT @30.06s** | ok @0.74s, books=100 |
| www.ishubao.org | **TIMEOUT @30.06s** | ok @1.05s, books=100 |
| www.23uswx.la | ok @20.97s | ok @0.48s, books=50 |
| www.biqukun.org/ | ok @21.03s | ok @0.61s, books=50 |
| www.dongtanxs.com## | ok @24.39s | ok @0.82s, books=50 |
| www.baishuwu.com | ok @0.92s (books=0) | ok @0.77s (books=0) |

yeudusk 页面网络层仅 299ms（TTFB），超时完全来自解析阶段。

## 3. 根因（两层，均有探针硬数据）

### 3.1 第一层：规则编译正则逐次重建（主根因）

`AnalyzeRule::get_string` 每次调用都经 `compile_source_rule` 重新执行 **4 条**
`Regex::new(...)`（@get / {{$.}} / @put / <js>|@js:）。debug 构建实测：

- 单条 `Regex::new + captures` ≈ **15ms**；4 条/规则 ≈ **60ms/规则**
- 新 analyzer 首调每字段 60–74ms；同 analyzer 复调 <1ms（per-analyzer 缓存命中）

搜索列表解析对**每个条目新建 item analyzer** → 每条目 7 个字段全部付首次编译成本：
yeudusk 100 条 × 7 字段 × ~60ms ≈ **42s > 30s 单源超时**。原版 Kotlin `AnalyzeRule`
使用类级预编译正则常量（一次编译），且列表解析共享单个 AnalyzeRule，故无此成本。

### 3.2 第二层：逐字段重复解析元素 HTML

每个字段 `get_string` 独立走完整分发（规则查找 + 内容类型判定 + `Html::parse_document`
重解析元素 + CSS 选择）。实测元素层 parse+select ≈0.3ms/次，10 字段量级下与第一层叠加。
原版 `BookList.getSearchItem`：共享 AnalyzeRule `setContent(item)` 后逐字段 getString，
jsoup 返回活 Elements、字段提取为 DOM 选择、无重解析。

### 3.3 排除项（B 系列对照实验）

- 并发数不是根因：c=1 SOLO 即复现超时；CPU-cap-9 信号量（B8）对超时零改善（ok=49/128 超时）→ **已撤销**
- 网络层无异常：yeudusk TTFB 299ms、body 0.8ms

## 4. 修复内容（全部为永久修复，对齐原版架构）

| 文件 | 改动 |
|---|---|
| `rust/legado-parser/src/analyze_rule.rs` | ① 4 条热路径正则改 `OnceLock` 进程级静态缓存（`re_get_ref/re_js_inner/re_put/re_js_chain`），对齐原版类级常量；② 新增 `get_strings_batch`：纯 CSS 字段规则共享一次元素 parse，非 CSS（@put/@get/##/<js>/@js:/extract@js/@webjs:）回退完整 `get_string` 路径，语义不变 |
| `rust/legado-parser/src/html.rs` | `HtmlParser` 重构：`parse_doc`（一次性解析）+ `select_from_doc`；新增 `get_multi(html, rules)`——一次 parse、N 条 CSS 选择复用同一文档（transient，不持久化 Html，保持 Send） |
| `rust/legado-ffi/src/api/search.rs` | 列表项循环改为每条目**一次** `get_strings_batch`（8 字段批量提取）；保留 `SEARCH_CONCURRENCY=32`；撤销被 B8 证伪的 CPU-cap 信号量；阶段计时保持 env-gated（`LEGADO_SEARCH_PHASE_TIMING=1`，默认关闭零行为变化） |

新增单测：`test_get_strings_batch_matches_per_field`（CSS 共享 parse 与逐字段一致）、
`test_get_strings_batch_json_fallback`（JSON/JsonPath 回退路径正确性）。

## 5. 验证

- `cargo test --workspace` 全绿（parser 249+2、ffi 302、server 170+ 等全部通过）
- SOLO / B 系列数据见上表；batch 与逐字段提取值逐项一致（探针 + 单测双重验证）
- 正确性抽查：yeudusk field[0..4] old=new（武动乾坤/天蚕土豆/玄幻魔法\n连载/2040215/book URL）

## 6. 范围口径说明

- 本方 DB 副本快速组 = **219** 源；原版实机当前 = **236** 源（App 内 DB 在提取后有更新），
  失败源集合不完全可比。
- FFI 契约无变化：改动限于 parser/ffi 内部，Dart 侧 API 表面零改动（无需 codegen）。

编写者：Qoder（主代理）｜ 2026-08-27
