# 搜索页 parity 批次 B 设计草案（跨轨 FFI）

**日期**: 2026-08-22 ｜ **编写者**: Qoder（主代理）
**状态**: 批次 A/B 已落地（A=2.0.99+101 commit `3a866106c`；B=2.0.99+103，G-B-01~05 全部实施）。缺口编号以 `docs/SEARCH_PAGE_PARITY_REPORT_2026-08-23.md` §3 规范号为准

## 1. 范围（缺口 G-B-01..G-B-05，跨轨部分；规范号见 SEARCH_PAGE_PARITY_REPORT_2026-08-23.md §3）

| # | 能力 | 原版参照（已核验 file:line） |
|---|------|------------------------------|
| G-B-01 | 分页 page 参数透传：searchPage++（新 key → page=1） | SearchModel.kt L73-75；SearchActivity fb_start_stop L284-298 |
| G-B-02 | hasMore 判定 + FAB play 态（idle+hasMore → 下一页） | SearchModel.kt L40/L81/L122；SearchActivity searchFinally L429-449 |
| G-B-03 | 滚动到底自动加载下一页（纯 UI 接线，与 G-B-01/02 同 FFI 能力） | SearchActivity L260-281；scrollToBottom L362-372 |
| G-B-04 | 暂停/恢复：软暂停 workingState 门控（状态保留、进度保留） | SearchModel.kt L45/L98/L227-233；SearchActivity L330-338 |
| G-B-05 | 书架实时搜索 + 在架绿点 + 在架同名仅填充分支（输入帮助层与结果项标记） | SearchActivity upHistory L389-424、L516-532；SearchViewModel isInBookShelf L90-116 |

## 2. 原版语义要点（实现基准）

1. **hasMore**：每次 startSearch() 内 hasMore = hasMore || items.isNotEmpty()——任一书源当页返回非空即 true；无 lastPage 规则依赖。
2. **分页推进**：同一 searchId → searchPage++，结果追加进累积列表（mergeItems），onSearchSuccess 推全量；新 key → page 重置 1。
3. **pause**：仅门控「尚未派发」的书源（flow emit 前 workingState.first{it}）；已派发任务继续完成；进度/状态全部保留。resume = workingState.value=true。
4. **stop**（批次 A 已交付，FFI cancel_search 既有）：硬取消 + mSearchId 重置。

## 3. Rust 侧改动点（本轮调研定位）

文件：rust/legado-ffi/src/api/search.rs、src/ffi.rs、src/bridge.rs

| 改动 | 位置 | 说明 |
|------|------|------|
| page 透传 | search_single_source L791-833（现硬编码 page=1 @L826） | 加 page: i32 参数 → build_search_url_with_setup 第 3 参；JS 书源路径同步 |
| 流式搜索签名 | ffi.rs search_multi_stream（L565 附近）+ bridge 导出 | 加 page: i32 入参（**破坏性变更**，双轨评审：本重构双轨同属我方 + 用户已批 B 范围） |
| pause/resume | 新增 SEARCH_PAUSED: AtomicBool；drive_source_batches L504-541 spawn 任务内在 permit 获取后、search_one 前加暂停门（while paused { yield }） | 语义对齐：已派发继续、未派发挂起；新增 ffi_pause_search / ffi_resume_search 导出（加法式） |
| has_more 终态事件 | drive_source_batches on_source(SourceBatchOutcome) 末批事件附加 has_more: bool（任一批次非空） | **加法式字段**，Dart 侧 SearchBook 批次模型同步 |

## 4. Dart 侧改动点

- rust_api.rs codegen 重新生成（FRB）+ BookApi / MockBookApi 抽象与假实现（契约三处同步铁律）
- search_notifier：searchPage/hasMore/isPaused 状态；FAB play 态接线（批次 A 已留停止态，play 态本批补）；滚动到底自动触发下一页（G-B-03，纯 UI）
- 输入帮助层书架前缀查询 + 在架绿点：**已确认纯 UI，无新 FFI**。BookApi.getBooks()（book_api.dart L21）已有全量书架。原版匹配语义（SearchViewModel.kt L90-116 已核验）：书架键集 = 每本 isNotShelf=false 的书生成 {「name-author」, name, bookUrl} 三键；搜索结果 isInBookShelf = (author 非空 ? 「name-author」 : name) ∈ 键集 || bookUrl ∈ 键集。Flutter 侧：getBooks() 构建 Set<String>，前缀联想按 name/author startsWith 过滤

## 5. 契约变更分类（API_CONTRACT.md 并入时）

- **破坏性**：search_multi_stream 签名 +page → 双轨评审记录（本条目）
- **加法式**：pause_search / resume_search / 批次事件 has_more 字段 /（视调研）bookshelfSearchPrefix
- 附录计数与 api_contract_test.dart 声明数同轮同步

## 6. 执行顺序（批次 B 轮）

1. API_CONTRACT.md 并入 §2.x 搜索组条目 + 更新记录行 → 冻结
2. Rust：page 透传 + pause/resume + has_more；cargo test 三门（workspace/js/ffi quickjs）
3. codegen → Dart 接线 → flutter analyze/test
4. 冒烟 5556 → commit/push → 5558 用户实测

编写者：Qoder ｜ 2026-08-22
