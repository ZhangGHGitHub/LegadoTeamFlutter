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
    // 延迟到 build() 返回后执行（state 初始化完成后才能访问）
    Future.microtask(() {
      _loadSettings();
      _loadBooks();
      _loadGroups();
    });
    return const BookshelfState();
  }

  /// 加载持久化的书架偏好设置
  Future<void> _loadSettings() async {
    final showRecentReading = await _settings.getShowBookshelfRecentReading();
    final showStats = await _settings.getShowBookshelfStats();
    final isGridView = await _settings.getBookshelfLayout();
    state = state.copyWith(
      showRecentReading: showRecentReading,
      showStats: showStats,
      isGridView: isGridView,
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
  Future<void> refresh() async {
    await Future.wait([_loadBooks(), _loadGroups()]);
  }

  /// 加载书籍分组（对标原版 BookshelfFragment1.initBookGroupData）
  Future<void> _loadGroups() async {
    try {
      final api = ref.read(bookApiProvider);
      final groups = await api.getBookGroups();
      final visible = groups.where((g) => g.show).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      // 对标原版 upGroup：始终保证「全部」组存在并置顶；
      // 无自定义分组时仅单一「全部」组（此时 UI 不显示 TabBar）
      final allGroup = const BookGroup(groupId: BookGroupId.all, groupName: '全部');
      final hasAll = visible.any((g) => g.groupId == BookGroupId.all);
      final list = hasAll ? visible : [allGroup, ...visible];
      final lastIndex = await _settings.getBookshelfTabPosition();
      state = state.copyWith(
        groups: list,
        selectedGroupIndex: lastIndex.clamp(0, list.length - 1),
      );
    } catch (e) {
      // 分组加载失败不阻断书架展示
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 切换分组 Tab（对标原版 onTabSelected → AppConfig.saveTabPosition）
  Future<void> selectGroup(int index) async {
    if (index < 0 || index >= state.groups.length) return;
    state = state.copyWith(selectedGroupIndex: index);
    await _settings.setBookshelfTabPosition(index);
  }

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

  /// 切换网格/列表视图（对标原版书架布局切换，持久化到 AppConfig.bookshelfLayout）
  Future<void> toggleViewMode() async {
    final newValue = !state.isGridView;
    state = state.copyWith(isGridView: newValue);
    await _settings.setBookshelfLayout(newValue);
  }

  /// 设置分组模式
  void setGroupMode(GroupMode mode) {
    state = state.copyWith(groupMode: mode);
  }

  /// 清除错误状态
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 拖拽排序：将书籍从 oldIndex 移动到 newIndex 并持久化 order
  Future<void> reorderBook(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.books.length) return;
    if (newIndex < 0 || newIndex > state.books.length) return;
    if (newIndex > oldIndex) newIndex--;

    final books = List<Book>.from(state.books);
    final book = books.removeAt(oldIndex);
    books.insert(newIndex, book);
    final reordered = [
      for (var i = 0; i < books.length; i++) books[i].copyWith(order: i),
    ];
    state = state.copyWith(books: reordered);
    try {
      await ref.read(bookApiProvider).reorderBooks([
        for (final b in reordered) {'bookUrl': b.bookUrl, 'order': b.order},
      ]);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      await _loadBooks();
    }
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
