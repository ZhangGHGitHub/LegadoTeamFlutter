import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'explore_show_state.dart';

export 'explore_show_state.dart';

/// 发现分类书籍 Riverpod Notifier（family + autoDispose）
///
/// 以 [ExploreShowArgs] 为 family key，每个分类页面拥有独立状态实例，
/// 页面销毁（pop）时自动释放（对标原 ExploreShowProvider 每屏独立实例语义）。
///
/// 职责严格限定（对齐 ExploreShowViewModel.kt）：
/// - 调用 BookApi.exploreFetchBooks → 接收纯数据 → 累积去重更新 State
/// - 管理分页状态（page/displayPage/hasMore/loading/error）
/// - 禁止包含业务计算（书籍抓取/解析由 Rust 完成）
class ExploreShowNotifier
    extends AutoDisposeFamilyNotifier<ExploreShowState, ExploreShowArgs> {
  @override
  ExploreShowState build(ExploreShowArgs arg) {
    // 延迟到 build() 返回后执行首次加载
    Future.microtask(() => fetchBooks());
    return ExploreShowState(
      source: arg.source,
      categoryName: arg.categoryName,
      categoryUrl: arg.categoryUrl,
    );
  }

  /// 抓取当前 [state.page] 页书籍（对标 Android ExploreShowViewModel.explore）
  ///
  /// [prepend] 为 true 时将新页插入列表头部（上滑加载上一页）；
  /// [replace] 为 true 时替换整表（跳页后首次加载）。
  Future<void> fetchBooks({bool prepend = false, bool replace = false}) async {
    if (state.isLoading || !state.hasMore) return;
    final source = state.source;
    if (source == null || state.categoryUrl.isEmpty) return;

    final fetchPage = state.page;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final sourceJson = jsonEncode(source.toJson());
      final newBooks = await api.exploreFetchBooks(
        sourceJson,
        state.categoryUrl,
        fetchPage,
      );

      final merged = _mergeBooks(
        state.books,
        newBooks,
        prepend: prepend,
        replace: replace,
      );

      state = state.copyWith(
        books: merged,
        isLoading: false,
        hasMore: newBooks.isNotEmpty,
        displayPage: newBooks.isEmpty ? state.displayPage : fetchPage,
        page: newBooks.isEmpty ? fetchPage : fetchPage + 1,
      );
    } catch (e) {
      state = state.copyWith(
        error: '加载失败：${_mapError(e)}',
        isLoading: false,
        hasMore: false,
      );
    }
  }

  /// 加载指定上一页（对标 Android scrollToTop → explore(oldPage)）
  Future<void> loadPreviousPage() async {
    if (state.isLoading || state.displayPage <= 1) return;
    final prevPage = state.displayPage - 1;
    state = state.copyWith(page: prevPage, hasMore: true, error: null);
    await fetchBooks(prepend: true);
  }

  /// 跳转到指定页（对标 Android skipPage + explore）
  Future<void> skipToPage(int targetPage) async {
    if (targetPage <= 0 || state.isLoading) return;
    state = state.copyWith(
      books: [],
      page: targetPage,
      displayPage: targetPage,
      hasMore: true,
      error: null,
    );
    await fetchBooks(replace: true);
  }

  /// 刷新（清空重新加载，对标 Android 下拉刷新）
  Future<void> refresh() async {
    state = state.copyWith(
      books: [],
      page: 1,
      displayPage: 0,
      hasMore: true,
      error: null,
    );
    await fetchBooks(replace: true);
  }

  /// 加载下一页（上滑触底时调用）
  Future<void> loadMore() => fetchBooks();

  List<SearchBook> _mergeBooks(
    List<SearchBook> existing,
    List<SearchBook> incoming, {
    required bool prepend,
    required bool replace,
  }) {
    if (replace) {
      return List<SearchBook>.from(incoming);
    }

    final keys = <String>{};
    final merged = <SearchBook>[];

    void addBook(SearchBook book, int index) {
      final key = exploreBookDedupeKey(book, listIndex: index);
      if (keys.add(key)) merged.add(book);
    }

    if (prepend) {
      for (var i = 0; i < incoming.length; i++) {
        addBook(incoming[i], i);
      }
      for (var i = 0; i < existing.length; i++) {
        addBook(existing[i], incoming.length + i);
      }
    } else {
      for (var i = 0; i < existing.length; i++) {
        addBook(existing[i], i);
      }
      for (var i = 0; i < incoming.length; i++) {
        addBook(incoming[i], existing.length + i);
      }
    }
    return merged;
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 发现分类书籍 Notifier Provider（family + autoDispose）
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(exploreShowNotifierProvider(args));
/// ref.read(exploreShowNotifierProvider(args).notifier).loadMore();
/// ```
final exploreShowNotifierProvider = AutoDisposeNotifierProviderFamily<
    ExploreShowNotifier, ExploreShowState, ExploreShowArgs>(
  ExploreShowNotifier.new,
);
