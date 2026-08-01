import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
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
/// - 管理分页状态（page/hasMore/loading/error）
/// - 禁止包含业务计算（书籍抓取/解析由 Rust 完成）
class ExploreShowNotifier
    extends AutoDisposeFamilyNotifier<ExploreShowState, ExploreShowArgs> {
  @override
  ExploreShowState build(ExploreShowArgs arg) {
    // 延迟到 build() 返回后执行首次加载
    Future.microtask(fetchBooks);
    return ExploreShowState(
      source: arg.source,
      categoryName: arg.categoryName,
      categoryUrl: arg.categoryUrl,
    );
  }

  /// 抓取当前页书籍并累积去重（对标 Android ExploreShowViewModel.explore）
  ///
  /// 加载当前页数据并累积到列表中，成功后 page++；
  /// 返回空列表时认为没有更多数据（hasMore = false）。
  Future<void> fetchBooks() async {
    if (state.isLoading || !state.hasMore) return;
    final source = state.source;
    if (source == null || state.categoryUrl.isEmpty) return;

    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final sourceJson = jsonEncode(source.toJson());
      final newBooks = await api.exploreFetchBooks(
        sourceJson,
        state.categoryUrl,
        state.page,
      );

      // 去重添加（对标 Android books LinkedHashSet）
      final existingUrls = state.books.map((b) => b.bookUrl).toSet();
      final merged = [...state.books];
      for (final book in newBooks) {
        if (!existingUrls.contains(book.bookUrl)) {
          merged.add(book);
          existingUrls.add(book.bookUrl);
        }
      }

      state = state.copyWith(
        books: merged,
        isLoading: false,
        hasMore: newBooks.isNotEmpty,
        page: newBooks.isEmpty ? state.page : state.page + 1,
      );
    } catch (e) {
      state = state.copyWith(
        error: '加载失败：${_mapError(e)}',
        isLoading: false,
        hasMore: false,
      );
    }
  }

  /// 刷新（清空重新加载，对标 Android 下拉刷新）
  Future<void> refresh() async {
    state = state.copyWith(books: [], page: 1, hasMore: true, error: null);
    await fetchBooks();
  }

  /// 加载下一页（上滑触底时调用）
  Future<void> loadMore() => fetchBooks();

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
