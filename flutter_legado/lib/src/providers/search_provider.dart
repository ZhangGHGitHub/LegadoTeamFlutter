import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/book_api.dart';
import '../services/rust_api.dart';
import '../bridge/ffi.dart';

/// 搜索状态管理
class SearchProvider extends ChangeNotifier {
  final BookApi _api;

  SearchProvider(this._api);

  String _keyword = '';
  List<SearchResult> _results = [];
  bool _loading = false;
  String? _error;
  final Set<String> _selectedSourceUrls = {};
  final Set<String> _selectedGroups = {};
  List<String> _searchHistory = [];

  // ===== Getters =====

  String get keyword => _keyword;
  List<SearchResult> get results => _results;
  bool get loading => _loading;
  String? get error => _error;
  Set<String> get selectedSourceUrls => _selectedSourceUrls;
  Set<String> get selectedGroups => _selectedGroups;
  List<String> get searchHistory => _searchHistory;
  bool get hasResults => _results.isNotEmpty;
  bool get isEmpty => _results.isEmpty && !_loading && _keyword.isNotEmpty;

  /// 是否有筛选条件（分组或书源）
  bool get hasFilter => _selectedSourceUrls.isNotEmpty || _selectedGroups.isNotEmpty;

  // ===== 操作 =====

  /// 加载搜索历史
  Future<void> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = prefs.getStringList('search_history') ?? [];
    notifyListeners();
  }

  /// 添加到搜索历史
  Future<void> addToHistory(String keyword) async {
    _searchHistory.remove(keyword);
    _searchHistory.insert(0, keyword);
    if (_searchHistory.length > 20) {
      _searchHistory = _searchHistory.sublist(0, 20);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('search_history', _searchHistory);
    notifyListeners();
  }

  /// 清空搜索历史
  Future<void> clearHistory() async {
    _searchHistory.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('search_history');
    notifyListeners();
  }

  Future<void> search(String keyword) async {
    if (keyword.trim().isEmpty) return;

    _keyword = keyword.trim();
    _loading = true;
    _error = null;
    await addToHistory(_keyword);
    notifyListeners();

    try {
      final sourceUrls = await _resolveSearchSources();
      // 有筛选条件但解析结果为空，说明所选分组/书源无有效书源
      if (sourceUrls != null && sourceUrls.isEmpty) {
        _error = '所选筛选范围内无有效书源，请调整筛选条件';
        return;
      }
      _results = await _api.searchBooks(_keyword, sourceUrls: sourceUrls);
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 解析搜索范围：将分组和书源选择合并为最终的 sourceUrls 列表
  /// 返回 null 表示搜索全部书源
  Future<List<String>?> _resolveSearchSources() async {
    // 无任何筛选条件时搜索全部
    if (_selectedSourceUrls.isEmpty && _selectedGroups.isEmpty) return null;

    final urls = <String>{};

    // 添加直接选中的书源
    urls.addAll(_selectedSourceUrls);

    // 将选中的分组解析为对应的书源 URL
    if (_selectedGroups.isNotEmpty) {
      try {
        final allSources = await _api.getEnabledBookSources();
        for (final source in allSources) {
          final group = source.bookSourceGroup;
          if (group != null && group.isNotEmpty) {
            // 书源分组可能包含多个组名（逗号分隔）
            final sourceGroups = group.split(RegExp(r'[,，]')).map((g) => g.trim());
            if (sourceGroups.any((g) => _selectedGroups.contains(g))) {
              urls.add(source.bookSourceUrl);
            }
          }
        }
      } catch (_) {
        // 分组解析失败时仅使用直接选中的书源
      }
    }

    // 有筛选条件但解析结果为空，返回空列表（而非 null）以区分“搜索全部”
    return urls.toList();
  }

  void clearResults() {
    _keyword = '';
    _results = [];
    _error = null;
    notifyListeners();
  }

  void toggleSource(String sourceUrl) {
    if (_selectedSourceUrls.contains(sourceUrl)) {
      _selectedSourceUrls.remove(sourceUrl);
    } else {
      _selectedSourceUrls.add(sourceUrl);
    }
    notifyListeners();
  }

  void clearSourceFilter() {
    _selectedSourceUrls.clear();
    notifyListeners();
  }

  // ===== 分组筛选 =====

  /// 切换分组选中状态
  void toggleGroup(String group) {
    if (_selectedGroups.contains(group)) {
      _selectedGroups.remove(group);
    } else {
      _selectedGroups.add(group);
    }
    notifyListeners();
  }

  /// 清除分组筛选
  void clearGroupFilter() {
    _selectedGroups.clear();
    notifyListeners();
  }

  /// 清除所有筛选（分组 + 书源）
  void clearAllFilter() {
    _selectedSourceUrls.clear();
    _selectedGroups.clear();
    notifyListeners();
  }
}
