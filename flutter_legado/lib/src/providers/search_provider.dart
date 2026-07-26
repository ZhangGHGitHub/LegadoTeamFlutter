import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/rust_api.dart';

/// 搜索状态管理
class SearchProvider extends ChangeNotifier {
  final RustApi _api;

  SearchProvider(this._api);

  String _keyword = '';
  List<SearchResult> _results = [];
  bool _loading = false;
  String? _error;
  final Set<String> _selectedSourceUrls = {};
  List<String> _searchHistory = [];

  // ===== Getters =====

  String get keyword => _keyword;
  List<SearchResult> get results => _results;
  bool get loading => _loading;
  String? get error => _error;
  Set<String> get selectedSourceUrls => _selectedSourceUrls;
  List<String> get searchHistory => _searchHistory;
  bool get hasResults => _results.isNotEmpty;
  bool get isEmpty => _results.isEmpty && !_loading && _keyword.isNotEmpty;

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
      final sourceUrls =
          _selectedSourceUrls.isEmpty ? null : _selectedSourceUrls.toList();
      _results = await _api.searchBooks(_keyword, sourceUrls: sourceUrls);
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
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
}
