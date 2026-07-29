import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/rust_api.dart';
import '../bridge/ffi.dart';
import '../services/settings_service.dart';

/// 书籍分组模式
enum GroupMode { none, bySource, byGroup }

/// 书架状态管理
class BookshelfProvider extends ChangeNotifier {
  final RustApi _api;
  final SettingsService _settings = SettingsService();

  BookshelfProvider(this._api);

  List<Book> _books = [];
  bool _loading = false;
  String? _error;
  bool _isGridView = true;
  GroupMode _groupMode = GroupMode.none;
  bool _showRecentReading = true;
  bool _showStats = true;

  // ===== Getters =====

  List<Book> get books => _books;
  bool get loading => _loading;
  String? get error => _error;
  bool get isGridView => _isGridView;
  bool get isEmpty => _books.isEmpty && !_loading;
  GroupMode get groupMode => _groupMode;
  bool get showRecentReading => _showRecentReading;
  bool get showStats => _showStats;

  /// 分组后的书籍，用于展示分组头
  Map<String, List<Book>> get groupedBooks {
    if (_groupMode == GroupMode.none) {
      return {'全部': _books};
    }
    final map = <String, List<Book>>{};
    for (final book in _books) {
      final key = _getGroupKey(book);
      map.putIfAbsent(key, () => []).add(book);
    }
    return map;
  }

  String _getGroupKey(Book book) {
    switch (_groupMode) {
      case GroupMode.bySource:
        return book.originName.isNotEmpty ? book.originName : '本地';
      case GroupMode.byGroup:
        return book.group > 0 ? '分组 ${book.group}' : '默认';
      default:
        return '全部';
    }
  }

  // ===== 操作 =====

  /// 加载持久化的书架偏好设置
  Future<void> loadSettings() async {
    _showRecentReading = await _settings.getShowBookshelfRecentReading();
    _showStats = await _settings.getShowBookshelfStats();
    notifyListeners();
  }

  Future<void> loadBooks() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _books = await _api.getBooks();
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

  Future<void> addBook(Book book) async {
    try {
      await _api.addBook(book);
      _books = [..._books, book];
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

  /// 导入本地书籍到书架（EPUB/TXT/MOBI/PDF/UMD）
  ///
  /// 成功后将返回的书籍加入列表并通知 UI；
  /// 失败时异常向上抛出，由 UI 层负责提示。
  Future<Book> importLocalBook(String filePath) async {
    final book = await _api.importLocalBook(filePath);
    _books = [
      ..._books.where((b) => b.bookUrl != book.bookUrl),
      book,
    ];
    notifyListeners();
    return book;
  }

  Future<void> removeBook(String bookUrl) async {
    try {
      await _api.deleteBook(bookUrl);
      _books = _books.where((b) => b.bookUrl != bookUrl).toList();
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

  void toggleViewMode() {
    _isGridView = !_isGridView;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void setGroupMode(GroupMode mode) {
    _groupMode = mode;
    notifyListeners();
  }

  /// 拖拽排序：将书籍从 oldIndex 移动到 newIndex
  void reorderBook(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _books.length) return;
    if (newIndex < 0 || newIndex > _books.length) return;
    // 调整 newIndex，因为移除后索引会变化
    if (newIndex > oldIndex) newIndex--;
    final book = _books.removeAt(oldIndex);
    _books.insert(newIndex, book);
    // 更新 order 字段
    for (var i = 0; i < _books.length; i++) {
      _books[i] = _books[i].copyWith(order: i);
    }
    notifyListeners();
  }

  Future<void> toggleShowRecentReading() async {
    _showRecentReading = !_showRecentReading;
    await _settings.setShowBookshelfRecentReading(_showRecentReading);
    notifyListeners();
  }

  Future<void> toggleShowStats() async {
    _showStats = !_showStats;
    await _settings.setShowBookshelfStats(_showStats);
    notifyListeners();
  }
}
