import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'search_state.dart';

export 'search_state.dart';

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

  @override
  SearchState build() {
    // 延迟到 build() 返回后加载历史
    Future.microtask(loadHistory);
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

    state = state.copyWith(
      keyword: trimmed,
      isLoading: true,
      error: null,
      results: const [],
      searchedCount: 0,
      totalCount: 0,
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
      final seen = <String>{};
      final accumulated = <SearchResult>[];
      _searchSub = ref
          .read(bookApiProvider)
          .searchMultiStream(trimmed, sourceUrls: sourceUrls)
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
              .map((e) => SearchResult.fromSearchBook(SearchBook.fromJson(e)));
          // 按 书名+作者 去重追加（对齐原版 mergeItems 同名同作者合并语义）
          for (final r in books) {
            final key = '${r.book.name}|${r.book.author}';
            if (seen.add(key)) accumulated.add(r);
          }
          // [UI-fix v2.0.10 | 2026-08-10] 分桶排序在批次回调内一次性完成
          //（对齐原版 mergeItems 每次批次合并后排序），展示层直接读
          // state.results，避免 build 时全量分桶导致精准搜索卡顿 — Reasonix
          final sorted = applyPrecisionSearch(
            accumulated,
            trimmed,
            keepOther: _keepOther,
          );
          state = state.copyWith(
            results: sorted,
            searchedCount: (batch['finished_count'] as int?) ?? 0,
            totalCount: (batch['total_count'] as int?) ?? 0,
          );
        },
        onError: (Object e) {
          if (seq != _searchSeq) return;
          state = state.copyWith(error: _mapError(e), isLoading: false);
        },
        onDone: () {
          if (seq != _searchSeq) return;
          _searchSub = null;
          state = state.copyWith(isLoading: false);
        },
      );
    } catch (e) {
      if (seq != _searchSeq) return;
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
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

  /// 解析搜索范围：将分组和书源选择合并为最终的 sourceUrls 列表
  /// 返回 null 表示搜索全部书源
  Future<List<String>?> _resolveSearchSources() async {
    // 无任何筛选条件时搜索全部
    if (state.selectedSourceUrls.isEmpty && state.selectedGroups.isEmpty) {
      return null;
    }

    final urls = <String>{...state.selectedSourceUrls};

    // 将选中的分组解析为对应的书源 URL
    if (state.selectedGroups.isNotEmpty) {
      try {
        final allSources =
            await ref.read(bookApiProvider).getEnabledBookSources();
        for (final source in allSources) {
          final group = source.bookSourceGroup;
          if (group != null && group.isNotEmpty) {
            // 书源分组可能包含多个组名（逗号分隔）
            final sourceGroups =
                group.split(RegExp(r'[,，]')).map((g) => g.trim());
            if (sourceGroups.any(state.selectedGroups.contains)) {
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

    // 有筛选条件但解析结果为空，返回空列表（而非 null）以区分"搜索全部"
    return urls.toList();
  }

  /// 清空关键词与结果（同时取消进行中的搜索）
  void clearResults() {
    _searchSeq++;
    _searchSub?.cancel();
    _searchSub = null;
    _keepOther = true;
    state = state.copyWith(
      keyword: '',
      results: [],
      error: null,
      isLoading: false,
      searchedCount: 0,
      totalCount: 0,
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
    state = state.copyWith(
      keyword: '',
      inputText: '',
      results: [],
      error: null,
      isLoading: false,
      searchedCount: 0,
      totalCount: 0,
    );
  }

  // ===== 书源筛选 =====

  /// 切换书源选中状态
  void toggleSource(String sourceUrl) {
    final next = {...state.selectedSourceUrls};
    if (next.contains(sourceUrl)) {
      next.remove(sourceUrl);
    } else {
      next.add(sourceUrl);
    }
    state = state.copyWith(selectedSourceUrls: next);
  }

  /// 清除书源筛选
  void clearSourceFilter() {
    state = state.copyWith(selectedSourceUrls: {});
  }

  // ===== 分组筛选 =====

  /// 切换分组选中状态
  void toggleGroup(String group) {
    final next = {...state.selectedGroups};
    if (next.contains(group)) {
      next.remove(group);
    } else {
      next.add(group);
    }
    state = state.copyWith(selectedGroups: next);
  }

  /// 清除分组筛选
  void clearGroupFilter() {
    state = state.copyWith(selectedGroups: {});
  }

  /// 清除所有筛选（分组 + 书源）
  void clearAllFilter() {
    state = state.copyWith(selectedSourceUrls: {}, selectedGroups: {});
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
