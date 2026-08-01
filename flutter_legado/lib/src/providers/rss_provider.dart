import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/book_api.dart';
import '../services/rust_api.dart';
import '../bridge/ffi.dart';

/// RSS 状态管理
class RssProvider extends ChangeNotifier {
  final BookApi _api;

  RssProvider(this._api);

  List<RssSource> _sources = [];
  List<RssFeedArticle> _articles = [];
  RssSource? _selectedSource;
  bool _isLoadingSources = false;
  bool _isLoadingArticles = false;
  String? _error;

  /// 当前选中的分组筛选；null 表示「全部」
  String? _selectedGroup;

  /// 安卓端 AppPattern.splitGroupRegex：[,;，；]
  /// 一个源的 sourceGroup 可能是逗号/分号分隔的多个分组
  static final RegExp _splitGroupRegex = RegExp(r'[,;，；]');

  // ===== Getters =====

  List<RssSource> get sources => _sources;
  List<RssFeedArticle> get articles => _articles;
  RssSource? get selectedSource => _selectedSource;
  bool get isLoadingSources => _isLoadingSources;
  bool get isLoadingArticles => _isLoadingArticles;
  bool get isLoading => _isLoadingSources || _isLoadingArticles;
  String? get error => _error;
  bool get isEmpty => _sources.isEmpty && !_isLoadingSources;

  /// 当前选中的分组（null 表示全部）
  String? get selectedGroup => _selectedGroup;

  /// 聚合所有源的分组，去重并保持插入顺序
  /// 对齐安卓 RssFragment 的 linkedSetOf 语义
  List<String> get groups {
    // Dart 的 Set 字面量即 LinkedHashSet，保持插入顺序
    final set = <String>{};
    for (final source in _sources) {
      set.addAll(_splitGroups(source.sourceGroup));
    }
    return set.toList();
  }

  /// 按当前选中分组过滤后的源列表；selectedGroup 为 null 时返回全部
  List<RssSource> get filteredSources {
    final group = _selectedGroup;
    if (group == null) return _sources;
    return _sources
        .where((s) => _splitGroups(s.sourceGroup).contains(group))
        .toList();
  }

  /// 将 sourceGroup 字符串按 [,;，；] 拆分、trim、去空
  List<String> _splitGroups(String? sourceGroup) {
    if (sourceGroup == null || sourceGroup.isEmpty) return const [];
    return sourceGroup
        .split(_splitGroupRegex)
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  // ===== 操作 =====

  /// 设置分组筛选；null 表示「全部」
  void setGroup(String? group) {
    _selectedGroup = group;
    notifyListeners();
  }

  /// 加载所有 RSS 源列表
  Future<void> loadSources() async {
    _isLoadingSources = true;
    _error = null;
    notifyListeners();

    try {
      _sources = await _api.getRssSources();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _isLoadingSources = false;
      notifyListeners();
    }
  }

  /// 选择源并加载文章
  Future<void> selectSource(RssSource source) async {
    _selectedSource = source;
    _isLoadingArticles = true;
    _error = null;
    _articles = [];
    notifyListeners();

    try {
      _articles = await _api.getRssArticles(source.sourceUrl);
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _isLoadingArticles = false;
      notifyListeners();
    }
  }

  /// 刷新当前选中源的文章
  Future<void> refreshArticles() async {
    if (_selectedSource == null) return;
    await selectSource(_selectedSource!);
  }

  /// 清除已选源（返回源列表）
  void clearSelectedSource() {
    _selectedSource = null;
    _articles = [];
    notifyListeners();
  }

  /// 添加 RSS 源
  Future<void> addSource(String name, String url) async {
    _error = null;
    notifyListeners();

    try {
      final newSource = RssSource(
        sourceUrl: url,
        sourceName: name,
      );
      final added = await _api.addRssSource(newSource);
      _sources = [..._sources, added];
      notifyListeners();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      notifyListeners();
    }
  }

  /// 删除 RSS 源
  Future<void> removeSource(String sourceUrl) async {
    _error = null;
    notifyListeners();

    try {
      await _api.deleteRssSource(sourceUrl);
      _sources = _sources.where((s) => s.sourceUrl != sourceUrl).toList();
      if (_selectedSource?.sourceUrl == sourceUrl) {
        clearSelectedSource();
      }
      notifyListeners();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      notifyListeners();
    }
  }

  /// 清除错误
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
