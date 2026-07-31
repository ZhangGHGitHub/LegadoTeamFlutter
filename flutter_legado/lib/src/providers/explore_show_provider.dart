/// 发现分类书籍提供者（ExploreShowProvider）
///
/// 参考 Android 原版 ExploreShowViewModel.kt 实现
/// 核心功能：
/// 1. 根据分类 URL 抓取书籍列表
/// 2. 支持分页加载（上滑加载更多）
/// 3. 累积书籍列表（对标 Android LinkedHashSet 去重逻辑）
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/book_api.dart';

/// 发现分类书籍状态
class ExploreShowProvider extends ChangeNotifier {
  final BookApi _api;

  ExploreShowProvider(this._api);

  // ─── 状态字段 ─────────────────────────────────────────────

  /// 当前书源
  BookSource? _source;

  /// 分类名称（用于标题显示）
  String _categoryName = '';

  /// 分类 URL
  String _categoryUrl = '';

  /// 已加载的书籍列表（累积，对标 Android books LinkedHashSet）
  final List<SearchBook> _books = [];

  /// 当前页码（从 1 开始）
  int _page = 1;

  /// 是否正在加载
  bool _loading = false;

  /// 是否还有更多数据
  bool _hasMore = true;

  /// 错误信息
  String? _error;

  // ─── Getters ──────────────────────────────────────────────

  BookSource? get source => _source;
  String get categoryName => _categoryName;
  String get categoryUrl => _categoryUrl;
  List<SearchBook> get books => List.unmodifiable(_books);
  int get page => _page;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  String? get error => _error;

  /// 标题显示：分类名 - 书源名（对标 Android titleBar.title = exploreName）
  String get title {
    if (_source == null) return _categoryName;
    return '$_categoryName - ${_source!.bookSourceName}';
  }

  // ─── 初始化 ───────────────────────────────────────────────

  /// 初始化数据（对标 Android ExploreShowViewModel.initData）
  ///
  /// [source] — 书源对象
  /// [categoryName] — 分类名称
  /// [categoryUrl] — 分类 URL
  void initData({
    required BookSource source,
    required String categoryName,
    required String categoryUrl,
  }) {
    _source = source;
    _categoryName = categoryName;
    _categoryUrl = categoryUrl;
    _books.clear();
    _page = 1;
    _hasMore = true;
    _error = null;
    notifyListeners();

    // 首次加载
    fetchBooks();
  }

  // ─── 数据加载 ─────────────────────────────────────────────

  /// 抓取书籍（对标 Android ExploreShowViewModel.explore()）
  ///
  /// 加载当前页数据并累积到列表中，成功后 page++
  Future<void> fetchBooks() async {
    if (_loading || !_hasMore) return;
    final source = _source;
    if (source == null || _categoryUrl.isEmpty) return;

    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final sourceJson = jsonEncode(source.toJson());
      final newBooks = await _api.exploreFetchBooks(
        sourceJson,
        _categoryUrl,
        _page,
      );

      // 去重添加（对标 Android books.addAll(searchBooks)）
      final existingUrls = _books.map((b) => b.bookUrl).toSet();
      for (final book in newBooks) {
        if (!existingUrls.contains(book.bookUrl)) {
          _books.add(book);
          existingUrls.add(book.bookUrl);
        }
      }

      // 判断是否还有更多：如果返回数量少于预期，认为没有更多
      if (newBooks.isEmpty) {
        _hasMore = false;
      } else {
        _page++;
      }
    } catch (e) {
      _error = '加载失败：$e';
      _hasMore = false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 刷新（清空重新加载，对标 Android 下拉刷新）
  Future<void> refresh() async {
    _books.clear();
    _page = 1;
    _hasMore = true;
    _error = null;
    notifyListeners();
    await fetchBooks();
  }

  /// 加载下一页（上滑触底时调用）
  Future<void> loadMore() async {
    await fetchBooks();
  }

  /// 判断书籍是否在书架中（对标 Android isInBookShelf）
  ///
  /// 当前简化实现：始终返回 false
  /// 后续可对接书架数据
  bool isInBookshelf(SearchBook book) {
    // TODO: 对接书架数据
    return false;
  }
}
