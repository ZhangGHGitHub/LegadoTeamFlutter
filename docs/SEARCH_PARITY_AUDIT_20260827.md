# 搜索速度与搜索结果差异 — 深度源码对比审计

**日期**：2026-08-27  
**对比基准**：原版 `com.legado.app.release` 3.26080322；重构 `2.0.109+113`（本批修复后）  
**编写者**：Cursor Agent

---

## 1. 执行摘要

| 现象 | 主因（按优先级） | 本批动作 |
|------|------------------|----------|
| 顶条同源徽标低（例 120 vs 50） | Rust 单源搜索命中率低；非 UI 聚合缺失 | 探针脚本 + `concurrentRate` 接入 |
| 总搜索结果行数少 | 同上 + 分桶拆散（contains 桶） | 探针归因；书名 format 键统一 |
| 换源「再搜一遍」 | DB `name` 精确匹配失败 / 主搜索未落库 | `format_book_name` 换源键 + 可观测日志 |
| 搜索体感慢 | 封面 FFI、换源无并发上限、单源超时 | 换源复用 `drive_source_batches`；换源超时 60s |

**关键结论**：[`search_notifier._addToBuckets`](flutter_legado/lib/src/providers/search/search_notifier.dart) 与 [`source_switch.try_load_change_source_from_db`](rust/legado-ffi/src/api/source_switch.rs) **设计已对齐原版**；差距主因在 **引擎层单源命中** 与 **换源 DB 键一致性**。

---

## 2. 端到端数据流对比

| 环节 | 原版 | 重构 | 对齐度 |
|------|------|------|--------|
| 分组范围 | `SearchScope.getBookSourceParts` + `searchGroup` | `_resolveSearchSources` + config | 已对齐 |
| 多源并发 | `mapParallelSafe(32)` | `SEARCH_CONCURRENCY=32` | 已对齐 |
| 单源超时 | 30s | 30s | 已对齐 |
| 同书聚合 | `mergeItems` + `addOrigin` | `_addToBuckets` + `withAddedOrigin` | 已对齐 |
| 落库 | `searchBookDao.insert` | `persist_search_books` | 已对齐 |
| 换源首屏 | `getDbSearchBooks` 非空不搜 | `forceRefresh=false` → DB 优先 | 已对齐（本批加固键） |
| concurrentRate | `ConcurrentRateLimiter` | **本批接入** `rate_limit.rs` | 修复中→已接 |
| 换源并发 | `mapParallel(threadCount)` | **本批** 复用 `drive_source_batches` | 修复中→已接 |

---

## 3. 根因矩阵（R1–R7）

| ID | 根因 | 影响 | 本批处理 |
|----|------|------|----------|
| R1 | Rust 单源失败率高 | 同源数、总行数 | `scripts/search_probe.ps1` 探针 |
| R2 | `concurrentRate` 未消费 | 封禁/空结果 | `legado-net` 请求前节流 |
| R3 | DB 换源 `name` 精确匹配失败 | 二次全量搜 | 换源读库用 `format_book_name` |
| R4 | searchGroup 不一致 | 少源、换源空 | 已有 config 持久化；探针校验 |
| R5 | 书名进 contains 桶 | 顶条徽标偏低 | 探针统计 equal vs contains |
| R6 | 搜索列表封面 FFI | UI 卡顿 | 已有 CoverDecodeLoader；非本批 |
| R7 | 换源 spawn 无上限 | 换源慢 | `source_switch` 复用批次驱动 |

---

## 4. 复测表格模板

在 **emulator-5558** 双包、分组「快速书源」下填写：

### 4.1 主搜索

| 关键词 | 包 | total_count | 顶条书名 | 顶条 origins | 列表总行数 | 搜索耗时(s) | DB 行数 `name=关键词` | DB 去重 origin |
|--------|-----|-------------|----------|--------------|------------|-------------|----------------------|----------------|
| 斗破苍穹 | 原版 | | | | | | N/A | N/A |
| 斗破苍穹 | 重构 | | | | | | | |
| 一人之下 | 原版 | | | | | | N/A | N/A |
| 一人之下 | 重构 | | | | | | | |

### 4.2 换源首屏

| 关键词 | 包 | forceRefresh | 首屏耗时(ms) | 首屏条数 | 是否出现全量 loading | 备注 |
|--------|-----|--------------|--------------|----------|----------------------|------|
| 斗破苍穹 | 重构 | false | | | | 应先 DB |
| 斗破苍穹 | 重构 | true | | | | 强制网络 |

### 4.3 探针（重构 Rust）

| 分类 | 源数 | 占比 |
|------|------|------|
| ok（有结果） | | |
| empty | | |
| http_error | | |
| timeout | | |
| js_error | | |
| parser_error | | |

---

## 5. 验证命令

```powershell
# 子代理冒烟（5556）
.\scripts\emulator_smoke_test.ps1 -Device emulator-5556

# 用户验收（5558）
.\scripts\emulator_smoke_test.ps1 -Device emulator-5558 -SkipBuild

# 搜索探针（快速书源 + 斗破苍穹，需 release .so）
.\scripts\search_probe.ps1 -Keyword "斗破苍穹" -Group "快速书源" -MaxSources 0

# 重构库 searchBooks 统计（需 adb root 或 run-as）
adb -s emulator-5558 shell run-as io.legado.app.debug sqlite3 databases/legado.db "SELECT COUNT(*), COUNT(DISTINCT origin) FROM searchBooks WHERE name='斗破苍穹';"
```

---

## 6. 本批代码变更索引

- `rust/legado-net/src/rate_limit.rs` — `concurrent_rate` 间隔节流
- `rust/legado-ffi/src/api/search.rs` — 搜索请求前 `acquire_rate_limit`
- `rust/legado-ffi/src/api/source_switch.rs` — 换源 `drive_source_batches` + 60s 超时 + DB 键 format
- `rust/legado-db/src/repository/search_book_repository.rs` — `change_source_by_group` 支持格式化书名
- `scripts/search_probe.ps1` — 批量探针
- `scripts/e2e_search_compare.ps1` — 5558 双包复测辅助

---

## 7. 与中断子代理 5eac2fab 的关系

同源聚合与换源 DB 复用**代码早已存在**；用户仍见 120 vs 50 是因为 **~70 源引擎未返回精确书名命中**。本批从 R2/R3/R7 缩小体验差距，R1 需持续按探针迭代 parser。

---

## 8. 实施完成记录（2026-08-27）

| 待办 | 状态 | 交付物 |
|------|------|--------|
| 审计文档 | 完成 | 本文档 |
| 探针脚本 | 完成 | `scripts/search_probe.ps1` + `scripts/search_probe_filter.py` |
| E2E 模板 | 完成 | `scripts/e2e_search_compare.ps1` |
| R2 concurrentRate | 完成 | `source_rate_limit.rs` + `search_single_source` |
| R3 换源 DB 键 | 完成 | `format_book_name/author` + 读库日志 |
| R7 换源并发 | 完成 | `buffer_unordered(32)` + 60s 超时 |

**版本**：`2.0.109+113`

**探针前提**：需有效 `legado.db`（从 5558 `run-as` 拉取）；仓库内 `legado_orig.db` 非有效 SQLite 时探针会报错。

**5558 人工项**：顶条 origins、换源首屏是否 loading 须双包同分组搜索后填入 §4 表格。

---

*本报告为 SEARCH_PARITY 审计权威文档；计划正文见 `.cursor/plans/搜索差异根因审计_ea1cd36d.plan.md`（只读引用，不修改）。*
