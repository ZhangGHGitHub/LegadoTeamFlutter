import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/rust_api.dart';
import '../bridge/ffi.dart';

/// RSS 状态管理
class RssProvider extends ChangeNotifier {
  final RustApi _api;

  RssProvider(this._api);

  List<RssSource> _sources = [];
  List<RssFeedArticle> _articles = [];
  RssSource? _selectedSource;
  bool _isLoadingSources = false;
  bool _isLoadingArticles = false;
  String? _error;

  // ===== Getters =====

  List<RssSource> get sources => _sources;
  List<RssFeedArticle> get articles => _articles;
  RssSource? get selectedSource => _selectedSource;
  bool get isLoadingSources => _isLoadingSources;
  bool get isLoadingArticles => _isLoadingArticles;
  bool get isLoading => _isLoadingSources || _isLoadingArticles;
  String? get error => _error;
  bool get isEmpty => _sources.isEmpty && !_isLoadingSources;

  // ===== 操作 =====

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
