/// 书源探索提供者（ExploreProvider）
///
/// 参考 Android 原版 ExploreFragment.kt 实现
/// 核心功能：
/// 1. 显示已安装的书源列表
/// 2. 支持实时搜索过滤
/// 3. 按分组筛选书源
/// 4. 一键安装/卸载书源（CRUD 操作）
library;
import 'package:flutter/foundation.dart';

import '../models/book_source.dart';
import '../services/book_api.dart';
class ExploreProvider extends ChangeNotifier {
  final BookApi _api;

  ExploreProvider(this._api);

  List<BookSource> _bookSources = [];
  bool _loading = false;
  String? _error;
  
  // 搜索关键词
  String _searchKeyword = '';
  
  // 当前选中的分组
  String _selectedGroup = '';
  
  // 所有分组列表（动态获取）
  Set<String> _groups = {};

  // ===== Getters =====
  List<BookSource> get bookSources => _bookSources;
  bool get loading => _loading;
  String? get error => _error;
  String get searchKeyword => _searchKeyword;
  String get selectedGroup => _selectedGroup;
  Set<String> get groups => _groups;

  /// 加载已安装书源
  Future<void> loadBookSources() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final sources = await _api.getBookSources();
      // 对齐 Android 原版 ExploreFragment：仅保留启用发现且 exploreUrl 非空的书源
      _bookSources = sources.where((s) => 
        s.enabledExplore && 
        (s.exploreUrl != null && s.exploreUrl!.trim().isNotEmpty)
      ).toList();
      
      // 收集所有分组
      _groups = _bookSources
          .map((s) => s.groupName ?? '未分类')
          .toSet();
    } catch (e) {
      _error = '加载书源失败：$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 设置搜索关键词
  void setSearchKeyword(String keyword) {
    _searchKeyword = keyword;
    notifyListeners();
  }

  /// 清除搜索关键词
  void clearSearch() {
    _searchKeyword = '';
    notifyListeners();
  }

  /// 设置选中分组
  void selectGroup(String group) {
    _selectedGroup = group;
    notifyListeners();
  }

  /// 获取过滤后的书源列表
  List<BookSource> get filteredBookSources {
    var list = List<BookSource>.from(_bookSources);
    
    // 按搜索关键词过滤
    if (_searchKeyword.isNotEmpty) {
      final kw = _searchKeyword.toLowerCase();
      list.removeWhere((source) {
        final name = source.bookSourceName.toLowerCase();
        final url = source.bookSourceUrl.toLowerCase();
        return !name.contains(kw) && !url.contains(kw);
      });
    }
    
    // 按分组过滤
    if (_selectedGroup.isNotEmpty) {
      list.removeWhere((source) {
        return source.groupName != _selectedGroup;
      });
    }
    
    return list;
  }

  /// 卸载书源
  Future<bool> uninstallSource(String sourceUrl) async {
    try {
      await _api.deleteBookSource(sourceUrl);
      
      // 从本地列表移除
      _bookSources.removeWhere((source) {
        return source.bookSourceUrl == sourceUrl;
      });
      
      notifyListeners();
      return true;
    } catch (e) {
      _error = '卸载失败：$e';
      notifyListeners();
      return false;
    }
  }

  /// 刷新书源列表
  Future<void> refreshBookSources() async {
    await loadBookSources();
  }
}
