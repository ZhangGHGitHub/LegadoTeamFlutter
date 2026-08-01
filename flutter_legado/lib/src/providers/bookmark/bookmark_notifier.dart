import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'bookmark_state.dart';

export 'bookmark_state.dart';

/// 书签 Riverpod Notifier
///
/// 职责严格限定（对齐原 BookmarkProvider 行为）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data 三态）
/// - 加载全部 / 按书名加载 / 搜索 / 增删书签
/// - 不自动加载（由界面在 initState 后主动调用 [loadAll]）
class BookmarkNotifier extends Notifier<BookmarkState> {
  @override
  BookmarkState build() {
    // 原实现不自动加载，保持惰性：由界面主动触发 loadAll/loadByBook
    return const BookmarkState();
  }

  /// 加载所有书签
  Future<void> loadAll() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final bookmarks = await api.getAllBookmarks();
      state = state.copyWith(bookmarks: bookmarks, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 按书名加载书签
  Future<void> loadByBook(String bookName) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final bookmarks = await api.getBookmarks(bookName);
      state = state.copyWith(bookmarks: bookmarks, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 添加书签（插入列表头部）
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
    final api = ref.read(bookApiProvider);
    final added = await api.addBookmark(bm);
    state = state.copyWith(bookmarks: [added, ...state.bookmarks]);
    return added;
  }

  /// 删除书签
  Future<void> deleteBookmark(int id) async {
    final api = ref.read(bookApiProvider);
    await api.deleteBookmark(id);
    state = state.copyWith(
      bookmarks: state.bookmarks.where((b) => b.id != id).toList(),
    );
  }

  /// 搜索书签（空关键词回退到加载全部）
  Future<void> search(String keyword) async {
    if (keyword.isEmpty) {
      await loadAll();
      return;
    }
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final bookmarks = await api.searchBookmarks(keyword);
      state = state.copyWith(bookmarks: bookmarks, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 统一错误映射（对齐原实现：BridgeError 取 message，其余 toString）
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书签 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(bookmarkNotifierProvider);
/// ref.read(bookmarkNotifierProvider.notifier).loadAll();
/// ```
final bookmarkNotifierProvider =
    NotifierProvider<BookmarkNotifier, BookmarkState>(
  BookmarkNotifier.new,
);
