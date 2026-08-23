# 搜索页原版 vs Flutter 功能对齐对比报告与实现计划

**日期**: 2026-08-23 ｜ **编写者**: Qoder（主代理）
**状态**: 规范版——汇总本会话早前对比结论（细粒度 46 项 / 缺口 21 个），缺口结论不变，编号规范化为 G-A / G-B / G-D

## 1. 对比基准

| 侧 | 版本 | 主要文件 |
|---|---|---|
| 原版 Android | `com.legado.app.release` 3.26081008 | `app/src/main/java/io/legado/app/ui/book/search/SearchActivity.kt`（全文 580 行，本轮全量重验）、`SearchViewModel.kt`、`SearchModel.kt`、`SearchScopeDialog.kt` |
| Flutter | 2.0.99+101（commit `3a866106c`） | `flutter_legado/lib/src/screens/search_screen.dart`、`providers/search/search_notifier.dart`、`widgets/search_filter_panel.dart` |

对比方法：以原版 SearchActivity 全文 + ViewModel/Model 语义为基准逐功能枚举，逐项核对 Flutter 现状；证据均为 file:line，可复核。

## 2. 功能对比总表（30 项）

| # | 功能 | 原版证据（file:line） | Flutter 现状 | 状态 |
|---|------|----------------------|--------------|------|
| 1 | 搜索输入框 + 箭头提交按钮 | SearchActivity L86-88、L195-200 | TextField(autofocus) + IconButton(Icons.arrow_forward) | ✅ 对齐（既有） |
| 2 | 提交：失焦 + 存历史 + 搜索 + 隐藏帮助层 | L200-210 | onSubmitted → unfocus + search；帮助层随聚焦监听自动隐藏 | ✅ 对齐（A-3/A-11） |
| 3 | 输入变更：停上一轮 + 隐藏 FAB + 更新历史 | L212-217 | onChanged → stop() + setInput（历史 chips 实时更新） | ✅ 对齐（A-2） |
| 4 | 帮助层聚焦叠显逻辑 | L219-227 | `_updateInputHelpVisibility`：`!loading && !(unfocused && hasResults && nonBlank)`，与原版语义完全一致 | ✅ 对齐（A-3） |
| 5 | 进度条（总数/进行中） | L320-324（searchProgressLiveData） | LinearProgressIndicator(value=searched/total, minHeight 2) | ✅ 对齐（A-9） |
| 6 | x/y 计数文本 | L323（tvSearchProgress） | FAB 旁浮动 chip「searched/total」 | ✅ 对齐（A-9） |
| 7 | FAB 停止态（搜索中 → isManualStopSearch + stop） | L290-294 | `_buildStopFab` → notifier.stop()（保留已出结果） | ✅ 对齐（A-1） |
| 8 | FAB play 态（idle && hasMore → 下一页） | L294-296；searchFinally L429-449 | 未实现（批次 A 仅留停止态） | ❌ G-B-02（批次 B） |
| 9 | 滚动到底自动加载下一页 | L260-281；scrollToBottom L362-372 | 未实现 | ❌ G-B-03（批次 B，补充枚举） |
| 10 | 新批次插入头部时滚顶 | L245-259（AdapterDataObserver） | results 变化 → animateTo(0, 200ms easeOut) | ✅ 对齐（A-10） |
| 11 | 结果列表渲染 | L241-244（recyclerView + SearchAdapter） | ListView.separated + 结果项 | ✅ 对齐（既有） |
| 12 | 历史关键词流（rvHistoryKey） | L238-240；upHistory L389-424 | 历史 chips（SearchKeyword 模型） | ✅ 对齐（既有） |
| 13 | 历史项长按删除 | L537-539（deleteHistory 回调） | onLongPress → deleteHistoryItem + SnackBar | ✅ 对齐（A-4） |
| 14 | 清空历史按钮 + 二次确认 | L299；alertClearHistory L550-558 | `_confirmClearHistory` AlertDialog（取消/确定） | ✅ 对齐（A-5） |
| 15 | 书架实时搜索（rvBookshelfSearch 即时出架上书） | L236-237；upHistory 书架分支 | 未实现 | ❌ G-B-05（批次 B） |
| 16 | 历史项进入：填充 + 搜索；在架同名 → 仅填充不搜索 | L516-532 | 现统一为填充 + 搜索（无「仅填充」分支） | ⚠️ 部分缺口 → 并入 G-B-05 子项 |
| 17 | 精准搜索开关 + 持久化 | L111-119（PreferKey.precisionSearch） | 菜单 CheckedPopupMenuItem + prefs('precisionSearch') | ✅ 对齐（A-13） |
| 18 | 显示阅读记录开关 + 持久化 + 结果橙点 | L94、L121-159；upAdapterLiveData | `_showReadRecord`（search_screen L49-50/98/336-338/366）+ 渲染（L539） | ✅ 对齐（既有） |
| 19 | 溢出菜单：当前范围单选组 / 其他分组多选组 | L141-147（setGroupCheckable group_1/group_2） | 菜单：全部书源清除 + 分组多勾 + 书源单选入口 | ✅ 对齐（A-6/A-7） |
| 20 | SearchScopeDialog rb_group：CheckBox 多选 | L155、L202-216（selectGroups add/remove） | toggleGroup 累加多选 | ✅ 对齐（A-6） |
| 21 | SearchScopeDialog rb_source：RadioButton 单选 | L156、L219-232（selectSource 替换） | RadioGroup<String?> 单选（选新替换旧） | ✅ 对齐（A-7） |
| 22 | 范围变更后帮助层隐藏时以当前关键词自动重搜 | L303-309（stateLiveData observer） | 空结果引导 / 组源切换 → 自动 re-search(kw) | ✅ 对齐（A-8） |
| 23 | 菜单：书源管理 / 日志入口 | menu_log → AppLogDialog；BookSourceActivity | 菜单「书源管理」（L369）+「日志」（L371，AppLogScreen） | ✅ 对齐（既有） |
| 24 | 生命周期暂停/恢复（RESUMED→resume / 退出→pause） | L330-338；SearchModel L98、L227-233 | 未实现 | ❌ G-B-04（批次 B） |
| 25 | 返回先失焦（hasFocus → clearFocus，不退出） | finish() L560-566 | PopScope(canPop=!hasFocus) + pop 时 unfocus | ✅ 对齐（A-12） |
| 26 | Intent 参数：key + searchScope（初始分组） | receiptIntent L345-357 | routes args['groups'] → initialGroups + query 参数 | ✅ 对齐（A-15） |
| 27 | 结果项点击 → 书籍信息页（name/author/bookUrl） | L484-504（showBookInfo） | onTap → BookInfo 路由 | ✅ 对齐（既有） |
| 28 | 在架绿点标记（isInBookShelf 三键匹配） | SearchViewModel L90-116 | 未实现 | ❌ G-B-05（批次 B） |
| 29 | 仅 WiFi 加载封面（loadCoverOnlyWifi） | 原版书籍封面配置项 | 暂缓（依赖网络状态包，本批不新增依赖） | ⏸️ G-D-01 暂缓 |
| 30 | clearResults 补 Rust 取消（自洽修复，无原版对应） | —（Flutter 侧缺陷） | unawaited(cancelSearch) + catchError | ✅ 对齐（A-14） |

**状态统计**：总表 30 项功能。对比时点缺口 21 个 = 批次 A 15 + 批次 B 5 + 暂缓 1；批次 A 的 15 项已于 `3a866106c` 落地（对应表中 A-x 标注行），剩余缺口 = G-B-01..05（5）+ G-D-01（1）。

## 3. 缺口详情与实现计划

### 3.1 批次 A（15 项）——已交付 ✅

commit `3a866106c`（2.0.99+101），纯 UI + 既有 FFI，无契约变更：

| # | 项 | 原版参照 |
|---|----|----------|
| A-1 | 搜索中停止 FAB（stop() 保留已出结果） | L290-294 |
| A-2 | 输入变更停搜 | L212-217 |
| A-3 | 聚焦叠显帮助层 | L219-227 |
| A-4 | 历史项长按删除 | L537-539 |
| A-5 | 清空历史二次确认 | L550-558 |
| A-6 | 分组多选（组源互斥清除） | L141-147、L202-216 |
| A-7 | 书源改单选（选新替换旧） | L156、L219-232 |
| A-8 | 空结果智能引导弹窗并自动重搜 | L457-477 |
| A-9 | 顶部进度条 + FAB 旁 x/y | L320-324 |
| A-10 | 新结果自动滚顶 | L245-259 |
| A-11 | 提交后收起键盘（unfocus） | L200-210 |
| A-12 | 返回先失焦 | L560-566 |
| A-13 | 精准搜索偏好持久化 | L111-119 |
| A-14 | clearResults 补 Rust 取消（自洽修复） | — |
| A-15 | initialGroups 路由参数 | L345-357 |

**验证链**：flutter analyze 0 issues；flutter test 全绿（含单选断言重写，+1217）；冒烟 emulator-5556 PASSED（FFI hash 28124110 / 构建 / 安装 / 无崩溃）；已推送 fork。

### 3.2 批次 B（G-B-01..05）——跨轨 FFI，已设计待实施

设计文档：`docs/SEARCH_PARITY_BATCH_B_DESIGN.md`。契约分类：**1 项破坏性**（search_multi_stream +page，双轨评审记录在案）+ **加法式**（pause/resume 导出、批次事件 has_more 字段）。

| # | 缺口 | 原版语义（已核验） | 实现要点 |
|---|------|--------------------|----------|
| G-B-01 | 分页 page 参数透传 | 同 searchId → searchPage++；新 key → page=1 + close()（SearchModel L73-75） | Rust：search_single_source L826 硬编码 page=1 → 加 `page: i32` 参；search_multi_stream 签名（ffi.rs ~L565，**破坏性**）→ codegen |
| G-B-02 | hasMore 判定 + FAB play 态 | 每次 startSearch：hasMore = hasMore \|\| items.isNotEmpty()（无 lastPage 规则）；idle+hasMore → FAB play → search("") 下一页（L294-296、L429-449） | Rust：末批 SourceBatchOutcome 事件附 `has_more`（**加法式**）；Dart：FAB play 态接线 + 下一页触发 |
| G-B-03 | 滚动到底自动加载下一页 | OnScrollListener → scrollToBottom()：!isManualStopSearch && !searching && hasMore → search("")（L260-281、L362-372） | **纯 UI 接线**，与 G-B-01/02 同 FFI 能力；本轮重验补充枚举（原对比并入分页缺口，未单列） |
| G-B-04 | 生命周期暂停/恢复 | repeatOnLifecycle(RESUMED)：进入 resume()、退出 pause()（L330-338）；pause = workingState.first{it} 门控「尚未派发」书源（SearchModel L98），已派发继续完成，进度/状态全保留 | Rust：SEARCH_PAUSED AtomicBool + pause/resume FFI（**加法式**）；drive_source_batches permit 获取后加暂停门；Dart：AppLifecycleListener → notifier |
| G-B-05 | 书架实时搜索 + 在架绿点 + 在架同名仅填充分支 | rvBookshelfSearch（L236-237）即时出架上书；upHistory L389-424；isInBookShelf = {name-author, name, bookUrl} 三键集匹配（SearchViewModel L90-116）；历史项在架同名 → setQuery(false) 仅填充不搜索（L516-532） | **已确认纯 UI，无新 FFI**：BookApi.getBooks()（book_api.dart L21）已有全量书架；前缀联想按 name/author startsWith 过滤 |

### 3.3 暂缓 G-D-01（loadCoverOnlyWifi，原审计 #20）

依赖网络状态检测能力；本批不新增依赖，待独立决策轮处理。

## 4. 编号对照

- 原会话对比使用顺序编号 #1–#21（其中 #3/#4/#6/#8/#14 = 批次 B 范围、#20 = G-D-01）；本表为规范编号（G-A/G-B/G-D）。
- `docs/SEARCH_PARITY_BATCH_B_DESIGN.md` 中原审计号引用已同步更新为本节规范 ID。

## 5. 执行顺序（批次 B 轮，承接设计文档 §6）

1. API_CONTRACT.md 并入搜索组条目 + 更新记录行 → 冻结
2. Rust：page 透传 + pause/resume + has_more；cargo test 三门（workspace / js quickjs / ffi quickjs）
3. codegen → Dart 接线（notifier searchPage/hasMore/isPaused、FAB play 态、滚动到底触发、书架实时搜索与绿点）→ flutter analyze/test
4. 冒烟 emulator-5556 → commit/push → 5558 用户实测验收

编写者：Qoder ｜ 2026-08-23