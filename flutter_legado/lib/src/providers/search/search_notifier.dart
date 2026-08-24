import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'search_state.dart';

export 'search_state.dart';

/// 书源分组拆分正则（对标原版 AppPattern.splitGroupRegex：[,;，；]）
final _splitGroupRegex = RegExp(r'[,;，；]');

/// 搜索页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律 与 SearchViewModel.kt）：
/// - 调用 BookApi.searchBooks → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/results 三态）
/// - 管理精准搜索筛选（书源/分组选择 → 解析为 sourceUrls）
/// - 管理搜索历史（经 BookApi 持久化至 Rust search_keywords 表）
/// - 管理输入联想（客户端前缀过滤，对标原版 flowSearch）
/// - 禁止包含搜索匹配/合并逻辑（由 Rust searchBooks 完成）
///
/// 说明：原版 Android 为逐源流式搜索 + x/y 进度（协程 flow），
/// 当前 Rust FFI searchBooks 为一次性返回，故进度仅表现为加载态；
/// 渐进搜索需 Rust 轨提供 Stream API（见交接文档跨轨需求）。
class SearchNotifier extends Notifier<SearchState> {
  /// 历史保留上限（UI 展示截断，对标原版）
  static const _maxHistory = 20;

  /// 当前流式搜索订阅（新搜索/清空时取消，对齐原版 cancelSearch）
  StreamSubscription<Map<String, dynamic>>? _searchSub;

  /// 搜索序号（使旧搜索的迟到批次/回调失效，对齐原版 searchID）
  int _searchSeq = 0;

  /// 精准搜索开关对应的 other 桶保留策略（true=默认保留，false=精准丢弃）
  /// [UI-fix v2.0.10 | 2026-08-10] 分桶排序移至批次回调内一次性完成，
  /// build 层直接消费 state.results，避免每帧全量分桶卡顿 — Reasonix
  bool _keepOther = true;

  /// 会话级原始累积表（跨页去重；批次B G-B-01：同关键词续页 APPEND，
  /// 新关键词/清空时重置）— Cursor UI
  final _accumulated = <SearchResult>[];

  /// 会话级去重键集（书名+作者+书源，与 [_accumulated] 同步维护）— Cursor UI
  final _seenKeys = <String>{};

  /// 结果列表节流重建间隔（2026-08-24：修复逐批次全量重聚合 + 全量替换
  /// 导致的搜索卡顿；对齐原版增量渲染语义）
  static const _flushInterval = Duration(milliseconds: 150);

  /// 结果列表节流重建定时器（至多每 [_flushInterval] 触发一次全量
  /// applyPrecisionSearch + state 回写）— Qoder UI
  Timer? _resultsFlushTimer;

  /// 待回写的进度字段（批次仅追加累积表，由 [_flushResults] 批量回写，
  /// 避免每批次一次 state 通知引发整页重建）— Qoder UI
  int _pendingSearchedCount = 0;
  int _pendingTotalCount = 0;
  bool? _pendingHasMore;

  @override
  SearchState build() {
    // 延迟到 build() 返回后加载历史 + 恢复搜索范围（对齐原版 AppConfig.searchScope）
    Future.microtask(() async {
      await loadHistory();
      await _restoreSearchScope();
    });
    return const SearchState();
  }

  // ===== 搜索历史 =====

  /// 加载搜索历史（经 BookApi.getSearchHistory 从 Rust 读取，取关键词列表）
  Future<void> loadHistory() async {
    try {
      final keywords = await ref.read(bookApiProvider).getSearchHistory();
      state = state.copyWith(
        searchHistory: keywords.map((k) => k.word).toList(),
      );
    } catch (e) {
      // 历史加载失败不阻断搜索主流程，保持空历史
      // [审计修复 §4.1] debugPrint 留痕 — Qoder
      debugPrint('搜索历史加载失败: $e');
    }
  }

  /// 添加到搜索历史（客户端去重置顶 + 截断 20 条，并经 BookApi 持久化）
  ///
  /// 客户端维护去重/截断后的展示列表（即时 UI 反馈，且 Mock/真实后端行为一致）；
  /// Rust `addSearchKeyword` 负责持久化（真实后端按 keyword 去重）。
  Future<void> addToHistory(String keyword) async {
    final history = [...state.searchHistory];
    history.remove(keyword);
    history.insert(0, keyword);
    final trimmed =
        history.length > _maxHistory ? history.sublist(0, _maxHistory) : history;
    state = state.copyWith(searchHistory: trimmed);
    try {
      await ref.read(bookApiProvider).addSearchKeyword(keyword, '');
    } catch (e) {
      // 持久化失败不阻断 UI 历史展示
      // [审计修复 §4.1] debugPrint 留痕 — Qoder
      debugPrint('搜索历史持久化失败: $e');
    }
  }

  /// 清空搜索历史（同步清本地状态并经 BookApi 清后端）
  Future<void> clearHistory() async {
    state = state.copyWith(searchHistory: []);
    try {
      await ref.read(bookApiProvider).clearSearchHistory();
    } catch (e) {
      // 后端清空失败不阻断 UI
      // [审计修复 §4.1] debugPrint 留痕 — Qoder
      debugPrint('搜索历史后端清空失败: $e');
    }
  }

  /// 删除单条搜索历史（对齐原版 HistoryKeyAdapter 长按删除）
  Future<void> deleteHistoryItem(String keyword) async {
    final history = [...state.searchHistory]..remove(keyword);
    state = state.copyWith(searchHistory: history);
    try {
      await ref.read(bookApiProvider).deleteSearchKeyword(keyword);
    } catch (e) {
      debugPrint('删除搜索历史项失败: $e');
    }
  }

  /// 更新输入框实时文本（驱动联想过滤，见 [SearchState.suggestions]）
  void setInput(String text) {
    if (state.inputText == text) return;
    state = state.copyWith(inputText: text);
  }

  /// 设置精准搜索开关（对齐原版 SearchActivity 菜单 precision_search：
  /// 切换后重新搜索，见 search_screen 调用处）
  void setPrecision(bool precision) {
    _keepOther = !precision;
  }

  // ===== 搜索 =====

  /// 执行搜索（对齐 SearchViewModel/SearchModel：关键词非空 → 记录历史 →
  /// 逐源流式搜索）
  ///
  /// 使用 Rust `searchMultiStream` 逐源渐进渲染（对齐原版 flow 逐源
  /// onSearchSuccess + x/y 进度语义）；发起前取消上一次搜索
  /// （对齐原版 `searchModel.cancelSearch`）。
  Future<void> search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;

    await _cancelActiveSearch();
    final seq = ++_searchSeq;

    // G-B-01：新关键词 → 会话重置（页码归 1、累积表清空）；
    // G-B-02：hasMore 乐观置 true（对齐原版 SearchViewModel L135，
    // 首页完成后由批次 has_more 覆写）；isManualStop 复位（原版 onQueryTextSubmit L203）
    _accumulated.clear();
    _seenKeys.clear();
    // [2026-08-24] 重置节流状态（防旧批次定时器/待写字段泄漏进新搜索）— Qoder UI
    _resultsFlushTimer?.cancel();
    _resultsFlushTimer = null;
    _pendingHasMore = null;
    state = state.copyWith(
      keyword: trimmed,
      isLoading: true,
      error: null,
      results: const [],
      searchedCount: 0,
      totalCount: 0,
      searchPage: 1,
      hasMore: true,
      isPaused: false,
      isManualStop: false,
    );
    await addToHistory(trimmed);
    if (seq != _searchSeq) return;

    try {
      final sourceUrls = await _resolveSearchSources();
      if (seq != _searchSeq) return;
      // 有筛选条件但解析结果为空，说明所选分组/书源无有效书源
      if (sourceUrls != null && sourceUrls.isEmpty) {
        state = state.copyWith(
          error: '所选筛选范围内无有效书源，请调整筛选条件',
          isLoading: false,
        );
        return;
      }
      _attachSearchStream(trimmed, 1, sourceUrls, seq);
    } catch (e) {
      if (seq != _searchSeq) return;
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 加载下一页（批次B G-B-01/G-B-02：对齐原版 SearchActivity FAB play +
  /// scrollToBottom → viewModel.search("")，同 searchId → page++）
  ///
  /// 守卫：非加载中、非手动停止、hasMore 为真、关键词非空；
  /// 结果 APPEND（不清空累积表），对齐原版同会话跨页累积语义。
  Future<void> loadNextPage() async {
    final s = state;
    if (s.isLoading || s.isManualStop || !s.hasMore) return;
    final keyword = s.keyword.trim();
    if (keyword.isEmpty) return;

    // G-B-01：同关键词续页 → page++（原版 SearchModel.searchPage++）
    final nextPage = s.searchPage + 1;
    final seq = ++_searchSeq;
    // [2026-08-24] 续页流重置节流状态（旧定时器不得占用新页调度槽位；
    // _pendingHasMore 归 null → 无新批次信息时保持 state.hasMore 旧语义）— Qoder UI
    _resultsFlushTimer?.cancel();
    _resultsFlushTimer = null;
    _pendingHasMore = null;
    state = state.copyWith(
      searchPage: nextPage,
      isLoading: true,
      error: null,
    );

    try {
      final sourceUrls = await _resolveSearchSources();
      if (seq != _searchSeq) return;
      if (sourceUrls != null && sourceUrls.isEmpty) {
        state = state.copyWith(
          error: '所选筛选范围内无有效书源，请调整筛选条件',
          isLoading: false,
        );
        return;
      }
      _attachSearchStream(keyword, nextPage, sourceUrls, seq);
    } catch (e) {
      if (seq != _searchSeq) return;
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 订阅逐源流（新搜索 / 续页共用；批次B：page 参数透传 Rust 侧）
  void _attachSearchStream(
    String keyword,
    int page,
    List<String>? sourceUrls,
    int seq,
  ) {
    _searchSub = ref
        .read(bookApiProvider)
        .searchMultiStream(keyword, sourceUrls: sourceUrls, page: page)
        .listen(
        (batch) {
          if (seq != _searchSeq) return;
          // [UI-fix v2.0.11 | 2026-08-10] 消费批次 error（对齐原版 SearchModel：
          // 单源失败静默不弹 UI、仅 AppLog.put 留痕，失败源不阻断整体搜索，
          // 不再产生任何「异常书源」弹窗提示路径）— Reasonix
          final batchError = batch['error'] as String?;
          if (batchError != null && batchError.isNotEmpty) {
            final srcName = (batch['source_name'] as String?) ?? '未知书源';
            // 日志写入失败不阻断搜索主流程（对齐原版 AppLog.put 尽力而为语义）
            unawaited(ref
                .read(bookApiProvider)
                .appLogPush(level: 'error', message: '书源搜索出错\n$srcName: $batchError')
                .catchError((_) {}));
          }
          final books = (batch['books'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map((e) => SearchResult.fromSearchBook(
                    SearchBook.fromJson(e),
                    // Rust 流式批次附加 hasReadRecord（#424）
                    hasReadRecord: e['hasReadRecord'] == true,
                  ));
          // 按 书名+作者+书源 去重后进入会话级累积表（批次B：跨页 APPEND，
          // 键集不清空直至新关键词/清空）；展示前由 applyPrecisionSearch
          // 按书名+作者聚合多 origin（对齐原版 mergeItems.addOrigin）
          for (final r in books) {
            final key = '${r.book.name}|${r.book.author}|${r.book.origin}';
            if (_seenKeys.add(key)) _accumulated.add(r);
          }
          // [2026-08-24] 节流重建：批次仅追加累积表 + 记录待写进度字段，
          // results 列表至多每 150ms 重建一次（修复逐批次全量重聚合 +
          // 全量替换导致的 UI 卡顿），流结束做最终全量聚合 — Qoder UI
          _pendingSearchedCount = (batch['finished_count'] as int?) ?? 0;
          _pendingTotalCount = (batch['total_count'] as int?) ?? 0;
          final hasMoreField = batch['has_more'] as bool?;
          if (hasMoreField != null) _pendingHasMore = hasMoreField;
          _scheduleResultsFlush(seq);
        },
        onError: (Object e) {
          if (seq != _searchSeq) return;
          state = state.copyWith(error: _mapError(e), isLoading: false);
        },
        onDone: () {
          if (seq != _searchSeq) return;
          _searchSub = null;
          // [2026-08-24] 流结束：取消挂起的节流定时器并做最终全量聚合
          // （保证最后一批结果不丢失于节流窗口）— Qoder UI
          _resultsFlushTimer?.cancel();
          _resultsFlushTimer = null;
          _flushResults();
          // 流结束（含挂起期间已派发任务全部完成）→ 清软挂起态
          state = state.copyWith(isLoading: false, isPaused: false);
        },
      );
  }

  /// 节流调度结果列表重建（2026-08-24：修复逐批次全量重聚合 + 全量替换
  /// 导致的搜索卡顿；对齐原版增量渲染语义）
  ///
  /// 逐源批次仅追加 [_accumulated] 并记录待写进度字段；至多每
  /// [_flushInterval] 触发一次全量 applyPrecisionSearch + state 回写，
  /// 流结束时由 onDone 做最终聚合。seq 守卫使旧搜索的挂起定时器失效。
  void _scheduleResultsFlush(int seq) {
    if (_resultsFlushTimer != null) return; // 已有挂起调度，复用
    _resultsFlushTimer = Timer(_flushInterval, () {
      _resultsFlushTimer = null;
      if (seq == _searchSeq) _flushResults();
    });
  }

  /// 将累积表 + 待写进度字段回写 state（节流窗口内至多一次全量聚合）— Qoder UI
  void _flushResults() {
    final sorted = applyPrecisionSearch(
      _accumulated,
      state.keyword,
      keepOther: _keepOther,
    );
    state = state.copyWith(
      results: sorted,
      searchedCount: _pendingSearchedCount,
      totalCount: _pendingTotalCount,
      // G-B-02：消费批次 has_more（Rust 侧当前页非空批次的累积 OR）；
      // 无新批次信息时保持 state.hasMore
      hasMore: _pendingHasMore ?? state.hasMore,
    );
  }

  /// 取消进行中的搜索（对齐原版 searchModel.cancelSearch）
  Future<void> _cancelActiveSearch() async {
    _searchSeq++;
    await _searchSub?.cancel();
    _searchSub = null;
    try {
      await ref.read(bookApiProvider).cancelSearch();
    } catch (e) {
      // 取消失败不阻断新搜索
      debugPrint('取消搜索失败: $e');
    }
  }

  /// 停止搜索（对齐原版 SearchViewModel.stop / fb_start_stop）
  ///
  /// 保留已出结果，仅取消后台搜索并将 [isLoading] 置 false；
  /// 同时置 [isManualStop]（原版 isManualStopSearch：抑制 play FAB 与
  /// 滚动自动加载，直至新关键词搜索复位）。
  Future<void> stop() async {
    if (!state.isLoading) return;
    // [2026-08-24] 取消前先做最终聚合：_cancelActiveSearch 会自增 seq，
    // 使挂起的节流定时器守卫失效——不在此处手动 flush，节流窗口内
    // 最后一批结果将丢失于 state.results（违背「保留已出结果」语义）— Qoder UI
    _resultsFlushTimer?.cancel();
    _resultsFlushTimer = null;
    _flushResults();
    await _cancelActiveSearch();
    state = state.copyWith(isLoading: false, isManualStop: true);
  }

  /// 软暂停搜索（批次B G-B-04：对齐原版 repeatOnLifecycle(RESUMED) →
  /// viewModel.pause()，app 退后台时调用）
  ///
  /// Rust 侧仅门控未派发书源，已派发任务继续跑完；进度/状态保留。
  Future<void> pauseSearch() async {
    if (!state.isLoading || state.isPaused) return;
    try {
      await ref.read(bookApiProvider).pauseSearch();
    } catch (e) {
      // bridge 失败 → Rust 实际未暂停，不回写 isPaused（防 UI/Rust 状态漂移）
      debugPrint('暂停搜索失败: $e');
      return;
    }
    state = state.copyWith(isPaused: true);
  }

  /// 恢复软暂停的搜索（对齐原版 viewModel.resume()，app 回前台时调用）
  Future<void> resumeSearch() async {
    if (!state.isPaused) return;
    try {
      await ref.read(bookApiProvider).resumeSearch();
    } catch (e) {
      // bridge 失败 → Rust 实际仍暂停，不回写 isPaused（防 UI/Rust 状态漂移）
      debugPrint('恢复搜索失败: $e');
      return;
    }
    state = state.copyWith(isPaused: false);
  }

  /// 解析搜索范围：将分组和书源选择合并为最终的 sourceUrls 列表
  /// 返回 null 表示搜索全部书源
  Future<List<String>?> _resolveSearchSources() async {
    // 无任何筛选条件时搜索全部
    if (state.selectedSourceUrls.isEmpty && state.selectedGroups.isEmpty) {
      debugPrint('搜索范围: 全部书源（无筛选）');
      return null;
    }

    final urls = <String>{...state.selectedSourceUrls};
    final groups = {...state.selectedGroups};

    // 将选中的分组解析为对应的书源 URL
    if (groups.isNotEmpty) {
      try {
        final allSources =
            await ref.read(bookApiProvider).getEnabledBookSources();
        for (final source in allSources) {
          final group = source.bookSourceGroup;
          if (group != null && group.isNotEmpty) {
            // 书源分组可能包含多个组名（对标原版 AppPattern.splitGroupRegex）
            final sourceGroups =
                group.split(_splitGroupRegex).map((g) => g.trim());
            if (sourceGroups.any(groups.contains)) {
              urls.add(source.bookSourceUrl);
            }
          }
        }
      } catch (e) {
        // 分组解析失败时仅使用直接选中的书源
        // [审计修复 §4.1] debugPrint 留痕 — Qoder
        debugPrint('书源分组解析失败: $e');
      }
    }

    debugPrint(
      '搜索范围: groups=$groups sourceUrls=${urls.length} '
      '(selectedUrls=${state.selectedSourceUrls.length})',
    );
    // 有筛选条件但解析结果为空，返回空列表（而非 null）以区分"搜索全部"
    return urls.toList();
  }

  /// 从 AppConfig 恢复搜索范围（对齐原版 SearchScope / searchScope 持久化）
  Future<void> _restoreSearchScope() async {
    try {
      final api = ref.read(bookApiProvider);
      final scope = (await api.getConfig('searchScope'))?.trim() ?? '';
      if (scope.isEmpty) return;
      // 单书源格式 name::url —— 原版不持久化到下次，此处忽略
      if (scope.contains('::')) return;
      final groups = scope
          .split(',')
          .map((g) => g.trim())
          .where((g) => g.isNotEmpty)
          .toSet();
      if (groups.isEmpty) return;
      state = state.copyWith(selectedGroups: groups, selectedSourceUrls: {});
      debugPrint('已恢复搜索范围分组: $groups');
    } catch (e) {
      debugPrint('恢复搜索范围失败: $e');
    }
  }

  /// 持久化搜索范围（对齐原版 SearchScope.save → AppConfig.searchScope/searchGroup）
  Future<void> _persistSearchScope() async {
    try {
      final api = ref.read(bookApiProvider);
      final groups = state.selectedGroups.toList()..sort();
      final urls = state.selectedSourceUrls;
      String scope;
      String searchGroup;
      if (groups.isEmpty && urls.isEmpty) {
        scope = '';
        searchGroup = '';
      } else if (groups.isEmpty && urls.length == 1) {
        // 单书源不写入 searchGroup（对齐原版 isSource 不缓存为分组）
        final url = urls.first;
        scope = '::$url';
        searchGroup = '';
      } else if (groups.isNotEmpty && urls.isEmpty) {
        scope = groups.join(',');
        searchGroup = groups.length == 1 ? groups.first : '';
      } else {
        // 混合多选：以分组为主写入 scope；searchGroup 仅单分组时有值
        scope = groups.isNotEmpty ? groups.join(',') : '';
        searchGroup = groups.length == 1 ? groups.first : '';
      }
      await api.setConfig('searchScope', scope);
      await api.setConfig('searchGroup', searchGroup);
    } catch (e) {
      debugPrint('持久化搜索范围失败: $e');
    }
  }

  /// 清空关键词与结果（同时取消进行中的搜索）
  void clearResults() {
    _searchSeq++;
    _searchSub?.cancel();
    _searchSub = null;
    // [2026-08-24] 清空时同步重置节流状态（旧定时器已被 seq 守卫失效，显式取消避免悬挂）— Qoder UI
    _resultsFlushTimer?.cancel();
    _resultsFlushTimer = null;
    _pendingHasMore = null;
    // 异步取消 Rust 侧孤儿搜索，失败不阻断 UI — Cursor UI
    unawaited(ref.read(bookApiProvider).cancelSearch().catchError((e) {
      debugPrint('清空结果取消搜索失败: $e');
    }));
    _keepOther = true;
    // 批次B：会话级累积表与分页态随清空重置
    _accumulated.clear();
    _seenKeys.clear();
    state = state.copyWith(
      keyword: '',
      results: [],
      error: null,
      isLoading: false,
      searchedCount: 0,
      totalCount: 0,
      searchPage: 1,
      hasMore: false,
      isPaused: false,
      isManualStop: false,
    );
  }

  /// 打开搜索页时重置为默认态（对齐原版：每次打开 = 新 ViewModel）
  ///
  /// 原版 SearchActivity 每次打开新建 SearchViewModel：results/searchKey 空、
  /// **不自动执行上次搜索**，仅显示搜索框 + 历史建议；
  /// Flutter 侧 notifier 为全局单例，若不重置则重开页面默认残留上次结果。
  /// 历史与筛选范围保留（原版历史读 DB、searchScope 经 AppConfig 持久化）。
  void resetForOpen() {
    _searchSeq++;
    _searchSub?.cancel();
    _searchSub = null;
    _keepOther = true;
    // 批次B：会话级累积表与分页态随页面重开重置（新 ViewModel 语义）
    _accumulated.clear();
    _seenKeys.clear();
    state = state.copyWith(
      keyword: '',
      inputText: '',
      results: [],
      error: null,
      isLoading: false,
      searchedCount: 0,
      totalCount: 0,
      searchPage: 1,
      hasMore: false,
      isPaused: false,
      isManualStop: false,
    );
  }

  // ===== 书源筛选 =====

  /// 切换书源选中状态（单选：对齐原版 SearchScopeDialog rb_source + RadioButton）
  void toggleSource(String sourceUrl) {
    if (state.selectedSourceUrls.contains(sourceUrl)) {
      state = state.copyWith(selectedSourceUrls: {});
    } else {
      state = state.copyWith(
        selectedSourceUrls: {sourceUrl},
        selectedGroups: {},
      );
    }
    unawaited(_persistSearchScope());
  }

  /// 清除书源筛选
  void clearSourceFilter() {
    state = state.copyWith(selectedSourceUrls: {});
    unawaited(_persistSearchScope());
  }

  // ===== 分组筛选 =====

  /// 切换分组选中状态（多选累加；菜单单选请用 [selectGroupExclusive]）
  void toggleGroup(String group) {
    final next = {...state.selectedGroups};
    if (next.contains(group)) {
      next.remove(group);
    } else {
      next.add(group);
    }
    state = state.copyWith(selectedGroups: next);
    unawaited(_persistSearchScope());
  }

  /// 单选替换分组（对齐原版 menu_group_2 → SearchScope.update(title)）
  ///
  /// 原子写入 selectedGroups={group} 并清空书源多选，避免 clear+toggle 两步
  /// 中间态被并发 search 读到空分组而回退全量源（分组粘性根因之一）。
  void selectGroupExclusive(String group) {
    state = state.copyWith(
      selectedGroups: {group},
      selectedSourceUrls: {},
    );
    unawaited(_persistSearchScope());
  }

  /// 批量设置分组选择（对齐原版 SearchScopeDialog rb_group CheckBox「确定」）
  ///
  /// 原子写入 selectedGroups 并清空书源筛选，避免多次 toggleGroup
  /// 的中间态被并发 search 读到（与 [selectGroupExclusive] 同根因防护）。
  void setGroups(List<String> groups) {
    state = state.copyWith(
      selectedGroups: {...groups},
      selectedSourceUrls: {},
    );
    unawaited(_persistSearchScope());
  }

  /// 清除分组筛选
  void clearGroupFilter() {
    state = state.copyWith(selectedGroups: {});
    unawaited(_persistSearchScope());
  }

  /// 清除所有筛选（分组 + 书源）
  void clearAllFilter() {
    state = state.copyWith(selectedSourceUrls: {}, selectedGroups: {});
    unawaited(_persistSearchScope());
  }

  /// 清除错误状态
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 搜索页 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(searchNotifierProvider);
/// ref.read(searchNotifierProvider.notifier).search('关键词');
/// ```
final searchNotifierProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);
