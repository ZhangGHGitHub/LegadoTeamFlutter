import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
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

  // [UI-fix v2.0.2 | 2026-08-06] 批量换源（对标 Kotlin
  // BookshelfManageViewModel.changeSource，复用单本 switchSource FFI） — Qoder
  ///
  /// 逐本：目标源内搜同名书 → switchSource；跳过本地书与已是目标源的书。
  /// [onProgress] 回推进度（done/total/当前书名），供 UI 对话框渲染；
  /// 返回 (成功数, 候选总数)。
  Future<(int, int)> switchSelectedSource(
    String targetSourceUrl, {
    void Function(int done, int total, String bookName)? onProgress,
  }) async {
    final selected = state.selectedUrls;
    final targets = state.books
        .where((b) => selected.contains(b.bookUrl))
        .where((b) =>
            b.origin != BookType.localTag &&
            !b.origin.startsWith(BookType.webDavTag) &&
            b.origin != targetSourceUrl)
        .toList();
    if (targets.isEmpty) return (0, 0);
    state = state.copyWith(isBusy: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      var success = 0;
      for (var i = 0; i < targets.length; i++) {
        final book = targets[i];
        onProgress?.call(i + 1, targets.length, book.name);
        try {
          final results = await api.searchBooks(
            book.name,
            sourceUrls: [targetSourceUrl],
          );
          // 对标 Kotlin preciseSearch：仅取同名书，作者相等优先
          Book? best;
          for (final r in results) {
            if (r.book.name != book.name) continue;
            if (book.author.isEmpty || r.book.author == book.author) {
              best = r.book;
              break;
            }
            best ??= r.book;
          }
          if (best == null) continue;
          await api.switchSource(
            book.bookUrl,
            targetSourceUrl,
            best.bookUrl,
          );
          success++;
        } catch (_) {
          // 单本失败不中断批次（对齐原版批间容错）
        }
      }
      state = state.copyWith(isBusy: false);
      await load();
      return (success, targets.length);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isBusy: false);
      return (0, targets.length);
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
