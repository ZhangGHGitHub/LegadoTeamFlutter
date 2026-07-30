import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/rust_api.dart';
import '../bridge/ffi.dart';

/// 书签状态管理
class BookmarkProvider extends ChangeNotifier {
  final RustApi _api;

  BookmarkProvider(this._api);

  List<Bookmark> _bookmarks = [];
  bool _loading = false;
  String? _error;

  List<Bookmark> get bookmarks => _bookmarks;
  bool get loading => _loading;
  String? get error => _error;

  /// 加载所有书签
  Future<void> loadAll() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _bookmarks = await _api.getAllBookmarks();
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

  /// 按书名加载书签
  Future<void> loadByBook(String bookName) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _bookmarks = await _api.getBookmarks(bookName);
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

  /// 添加书签
  Future<Bookmark> addBookmark({
    required String bookName,
    required String bookAuthor,
    required int chapterIndex,
    required int chapterPos,
    required String chapterName,
    String bookText = '',
    String content = '',
  }) async {
    final bm = Bookmark(
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      chapterPos: chapterPos,
      chapterName: chapterName,
      bookText: bookText,
      content: content,
    );
    final added = await _api.addBookmark(bm);
    _bookmarks.insert(0, added);
    notifyListeners();
    return added;
  }

  /// 删除书签
  Future<void> deleteBookmark(int id) async {
    await _api.deleteBookmark(id);
    _bookmarks.removeWhere((b) => b.id == id);
    notifyListeners();
  }

  /// 搜索书签
  Future<void> search(String keyword) async {
    if (keyword.isEmpty) {
      await loadAll();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _bookmarks = await _api.searchBookmarks(keyword);
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
}
