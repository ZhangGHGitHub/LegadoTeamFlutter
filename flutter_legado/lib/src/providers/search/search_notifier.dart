import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../providers.dart';
import 'search_state.dart';

export 'search_state.dart';

/// 搜索页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律 与 SearchViewModel.kt）：
/// - 调用 BookApi.searchBooks → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/results 三态）
/// - 管理精准搜索筛选（书源/分组选择 → 解析为 sourceUrls）
/// - 管理搜索历史（SharedPreferences 持久化）
/// - 禁止包含搜索匹配/合并逻辑（由 Rust searchBooks 完成）
///
/// 说明：原版 Android 为逐源流式搜索 + x/y 进度（协程 flow），
/// 当前 Rust FFI searchBooks 为一次性返回，故进度仅表现为加载态；
/// 渐进搜索需 Rust 轨提供 Stream API（见交接文档跨轨需求）。
class SearchNotifier extends Notifier<SearchState> {
  static const _historyKey = 'search_history';
  static const _maxHistory = 20;

  @override
  SearchState build() {
    // 延迟到 build() 返回后加载历史
    Future.microtask(loadHistory);
    return const SearchState();
  }

  // ===== 搜索历史 =====

  /// 加载搜索历史
  Future<void> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_historyKey) ?? [];
    state = state.copyWith(searchHistory: history);
  }

  /// 添加到搜索历史（去重置顶，限 20 条，持久化）
  Future<void> addToHistory(String keyword) async {
    final history = [...state.searchHistory];
    history.remove(keyword);
    history.insert(0, keyword);
    final trimmed =
        history.length > _maxHistory ? history.sublist(0, _maxHistory) : history;
    state = state.copyWith(searchHistory: trimmed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, trimmed);
  }

  /// 清空搜索历史
  Future<void> clearHistory() async {
    state = state.copyWith(searchHistory: []);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  // ===== 搜索 =====

  /// 执行搜索（对齐 SearchViewModel：关键词非空 → 记录历史 → 调用 searchBooks）
  Future<void> search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;

    state = state.copyWith(keyword: trimmed, isLoading: true, error: null);
    await addToHistory(trimmed);

    try {
      final sourceUrls = await _resolveSearchSources();
      // 有筛选条件但解析结果为空，说明所选分组/书源无有效书源
      if (sourceUrls != null && sourceUrls.isEmpty) {
        state = state.copyWith(
          error: '所选筛选范围内无有效书源，请调整筛选条件',
          isLoading: false,
        );
        return;
      }
      final results = await ref.read(bookApiProvider).searchBooks(
            trimmed,
            sourceUrls: sourceUrls,
          );
      state = state.copyWith(results: results, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
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
      } catch (_) {
        // 分组解析失败时仅使用直接选中的书源
      }
    }

    // 有筛选条件但解析结果为空，返回空列表（而非 null）以区分"搜索全部"
    return urls.toList();
  }

  /// 清空关键词与结果
  void clearResults() {
    state = state.copyWith(keyword: '', results: [], error: null);
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
