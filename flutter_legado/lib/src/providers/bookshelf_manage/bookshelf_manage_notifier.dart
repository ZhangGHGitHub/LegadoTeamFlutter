import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../providers.dart';
import 'bookshelf_manage_state.dart';

export 'bookshelf_manage_state.dart';

/// 书架管理页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 书籍列表经 `BookApi.getBooks` 委托 Rust。
/// - 批量删除经 `BookApi.deleteBook`（逐本调用，失败即止并记录错误）。
/// - 移动分组经 `BookApi.setBookGroup`（逐本调用）。
/// - 置顶经 `BookApi.topBook`（逐本调用）。
/// - 所有批量操作完成后重新拉取列表，保证与 Rust 数据源一致。
class BookshelfManageNotifier extends Notifier<BookshelfManageState> {
  @override
  BookshelfManageState build() => const BookshelfManageState();

  /// 加载书架书籍列表
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final books = await ref.read(bookApiProvider).getBooks();
      state = state.copyWith(
        books: books,
        selectedUrls: const {},
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 切换单本书勾选状态
  void toggleSelect(String bookUrl) {
    final selected = {...state.selectedUrls};
    if (!selected.add(bookUrl)) {
      selected.remove(bookUrl);
    }
    state = state.copyWith(selectedUrls: selected);
  }

  /// 全选
  void selectAll() {
    state = state.copyWith(
      selectedUrls: state.books.map((b) => b.bookUrl).toSet(),
    );
  }

  /// 取消全选
  void deselectAll() {
    state = state.copyWith(selectedUrls: const {});
  }

  /// 批量删除已勾选书籍（成功后重新拉取列表）
  Future<void> removeSelected() async {
    final urls = state.selectedUrls.toList();
    if (urls.isEmpty) return;
    state = state.copyWith(isBusy: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      for (final url in urls) {
        await api.deleteBook(url);
      }
      state = state.copyWith(isBusy: false);
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isBusy: false);
    }
  }

  /// 将已勾选书籍移动到指定分组（成功后重新拉取列表）
  Future<void> moveSelectedToGroup(int groupId) async {
    final urls = state.selectedUrls.toList();
    if (urls.isEmpty) return;
    state = state.copyWith(isBusy: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      for (final url in urls) {
        await api.setBookGroup(url, groupId);
      }
      state = state.copyWith(isBusy: false);
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isBusy: false);
    }
  }

  /// 置顶已勾选书籍（成功后重新拉取列表）
  Future<void> pinSelected() async {
    final urls = state.selectedUrls.toList();
    if (urls.isEmpty) return;
    state = state.copyWith(isBusy: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      for (final url in urls) {
        await api.topBook(url);
      }
      state = state.copyWith(isBusy: false);
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isBusy: false);
    }
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书架管理 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(bookshelfManageNotifierProvider);
/// ref.read(bookshelfManageNotifierProvider.notifier).load();
/// ```
final bookshelfManageNotifierProvider =
    NotifierProvider<BookshelfManageNotifier, BookshelfManageState>(
  BookshelfManageNotifier.new,
);
