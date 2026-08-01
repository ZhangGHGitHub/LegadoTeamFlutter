import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/settings_service.dart';
import '../providers.dart';
import 'bookshelf_state.dart';

export 'bookshelf_state.dart';

/// 书架 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §3.2 铁律）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data 三态）
/// - 管理展示层变换（网格/列表切换、分组模式）
/// - 禁止包含业务计算（排序/过滤/规则解析由 Rust 完成）
class BookshelfNotifier extends Notifier<BookshelfState> {
  final SettingsService _settings = SettingsService();

  @override
  BookshelfState build() {
    // 初始化时异步加载设置和书籍
    _loadSettings();
    _loadBooks();
    return const BookshelfState();
  }

  /// 加载持久化的书架偏好设置
  Future<void> _loadSettings() async {
    final showRecentReading = await _settings.getShowBookshelfRecentReading();
    final showStats = await _settings.getShowBookshelfStats();
    state = state.copyWith(
      showRecentReading: showRecentReading,
      showStats: showStats,
    );
  }

  /// 调用 Rust API 获取书籍列表
  ///
  /// Notifier 不做任何数据处理，Rust 负责排序/过滤
  Future<void> _loadBooks() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final books = await api.getBooks();
      state = state.copyWith(books: books, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 刷新书架
  Future<void> refresh() => _loadBooks();

  /// 添加书籍到书架
  Future<void> addBook(Book book) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.addBook(book);
      state = state.copyWith(books: [...state.books, book]);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 导入本地书籍到书架（EPUB/TXT/MOBI/PDF/UMD）
  ///
  /// 成功后将返回的书籍加入列表；
  /// 失败时异常向上抛出，由 UI 层负责提示。
  Future<Book> importLocalBook(String filePath) async {
    final api = ref.read(bookApiProvider);
    final book = await api.importLocalBook(filePath);
    state = state.copyWith(
      books: [
        ...state.books.where((b) => b.bookUrl != book.bookUrl),
        book,
      ],
    );
    return book;
  }

  /// 删除书籍：调用 Rust API 后同步本地 UI 状态
  ///
  /// 注意：where 过滤是「UI 状态同步」而非「业务逻辑」
  Future<void> removeBook(String bookUrl) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.deleteBook(bookUrl);
      state = state.copyWith(
        books: state.books.where((b) => b.bookUrl != bookUrl).toList(),
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  // ===== 展示层状态切换（不涉及数据内容变更） =====

  /// 切换网格/列表视图
  void toggleViewMode() {
    state = state.copyWith(isGridView: !state.isGridView);
  }

  /// 设置分组模式
  void setGroupMode(GroupMode mode) {
    state = state.copyWith(groupMode: mode);
  }

  /// 清除错误状态
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 拖拽排序：将书籍从 oldIndex 移动到 newIndex
  ///
  /// 注意：这是 UI 层拖拽交互的视觉反馈，
  /// 持久化排序由后续调用 BookApi 完成（TODO: Phase 1.5）
  void reorderBook(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.books.length) return;
    if (newIndex < 0 || newIndex > state.books.length) return;
    if (newIndex > oldIndex) newIndex--;

    final books = List<Book>.from(state.books);
    final book = books.removeAt(oldIndex);
    books.insert(newIndex, book);
    // 更新 order 字段（UI 状态同步）
    final reordered = [
      for (var i = 0; i < books.length; i++) books[i].copyWith(order: i),
    ];
    state = state.copyWith(books: reordered);
  }

  /// 切换「显示最近阅读」偏好
  Future<void> toggleShowRecentReading() async {
    final newValue = !state.showRecentReading;
    state = state.copyWith(showRecentReading: newValue);
    await _settings.setShowBookshelfRecentReading(newValue);
  }

  /// 切换「显示阅读统计」偏好
  Future<void> toggleShowStats() async {
    final newValue = !state.showStats;
    state = state.copyWith(showStats: newValue);
    await _settings.setShowBookshelfStats(newValue);
  }

  // ===== 内部工具 =====

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书架 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(bookshelfNotifierProvider);
/// ref.read(bookshelfNotifierProvider.notifier).refresh();
/// ```
final bookshelfNotifierProvider =
    NotifierProvider<BookshelfNotifier, BookshelfState>(
  BookshelfNotifier.new,
);
