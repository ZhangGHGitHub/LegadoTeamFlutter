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
  /// [replace] 为 true 时替换整表（跳页/刷新后首次加载）；否则追加到表尾并
  /// 推进页码。加载上一页走独立的 [loadPreviousPage]（prepend 合并）。
  Future<void> fetchBooks({bool replace = false}) async {
    if (state.isLoading || state.isLoadingPrevious || !state.hasMore) return;
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
        prepend: false,
        replace: replace,
      );

      // 无新书（空页或整页全重复）→ 没有更多（对齐原版 adapter 数不变即 noMore）；
      // 有增量 → 推进页码 — 发现页修复 C2
      final noNew = replace ? newBooks.isEmpty : merged.length == state.books.length;
      state = state.copyWith(
        books: merged,
        isLoading: false,
        hasMore: !noNew,
        displayPage: noNew ? state.displayPage : fetchPage,
        page: noNew ? fetchPage : fetchPage + 1,
      );
    } catch (e) {
      // 错误后保留 hasMore，使「点击重试」可用（对齐原版 fail() 不清 hasMore，
      // 可滚动/点击重试）— 发现页修复 C1
      final mapped = _mapError(e);
      state = state.copyWith(
        error: mapped,
        isLoading: false,
      );
    }
  }

  /// 加载上一页（对齐 Android ExploreShowActivity.scrollToTop
  /// → `viewModel.explore(oldPage - 1)`）
  ///
  /// 与 [fetchBooks] 的增量路径完全分离：
  /// - 页码取 [ExploreShowState.displayPage] - 1（顶部页号），
  ///   成功后把新页 prepend 到表头并只回写 [ExploreShowState.displayPage]；
  /// - [ExploreShowState.page]（下一待抓取页）与
  ///   [ExploreShowState.hasMore] 保持不变，避免倒灌脏加载更多游标；
  /// - 与首屏/加载更多/跳页互斥（[ExploreShowState.isLoading] 或本方法在途
  ///   时直接忽略）；失败只写 [ExploreShowState.previousError]，顶部条内联重试。
  Future<void> loadPreviousPage() async {
    if (state.isLoading || state.isLoadingPrevious) return;
    if (state.displayPage <= 1) return;
    final source = state.source;
    if (source == null || state.categoryUrl.isEmpty) return;

    final prevPage = state.displayPage - 1;
    state = state.copyWith(isLoadingPrevious: true, previousError: null);
    try {
      final api = ref.read(bookApiProvider);
      final newBooks = await api.exploreFetchBooks(
        jsonEncode(source.toJson()),
        state.categoryUrl,
        prevPage,
      );
      final merged = _mergeBooks(
        state.books,
        newBooks,
        prepend: true,
        replace: false,
      );
      state = state.copyWith(
        books: merged,
        isLoadingPrevious: false,
        // 对齐原版 pageLiveData.value = request.page：顶部页号同步为已加载页
        displayPage: prevPage,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingPrevious: false,
        previousError: _mapError(e),
      );
    }
  }

  /// 加载上一页失败后的顶部条重试
  ///
  /// [批39 审查回修] 删除原「无失败记录时置 previousError=null」的空分支：
  /// [loadPreviousPage] 入口本身就会清空 [ExploreShowState.previousError]，
  /// 该分支不改变任何行为。
  Future<void> retryPreviousPage() => loadPreviousPage();

  /// 跳转到指定页（对标参考版 jumpToPage / Android skipPage + explore）
  ///
  /// 页码跳转仅对「规则支持页码」的分类开放（`state.canJumpPage`：
  /// 规则含 `{{page}}` 或 `<,>` 页码列表）；跳页与加载更多互斥——
  /// 加载中直接忽略跳页请求，跳页后清空列表并按目标页结果重建
  /// `hasMore`（目标页为空 → 没有更多；有数据 → 可继续加载下一页）。
  ///
  /// 跳页失败时 [ExploreShowState.displayPage] 回退到跳转前的页码
  /// （顶栏不展示未成功加载的页），[ExploreShowState.page] 保留目标页，
  /// 由 [retry] 重放该目标页。
  Future<void> skipToPage(int targetPage) async {
    if (targetPage <= 0 || state.isLoading || state.isLoadingPrevious) return;
    if (!state.canJumpPage) return;
    final previousDisplayPage = state.displayPage;
    state = state.copyWith(
      books: [],
      page: targetPage,
      displayPage: targetPage,
      // 先置 true 以放行本次抓取，最终 hasMore 由目标页结果决定
      hasMore: true,
      error: null,
      previousError: null,
    );
    await fetchBooks(replace: true);
    if (state.error != null) {
      state = state.copyWith(displayPage: previousDisplayPage);
    }
  }

  /// 失败重试（错误视图「重试」按钮）
  ///
  /// 列表为空时说明首屏或跳页整体失败：重放 [ExploreShowState.page]
  ///（跳页失败后仍为目标页，避免重试悄悄退回第 1 页）；
  /// 列表非空时说明只是「加载更多」失败：继续抓取下一页。
  Future<void> retry() async {
    if (state.isLoading || state.isLoadingPrevious) return;
    if (state.source == null || state.categoryUrl.isEmpty) return;
    if (state.books.isEmpty) {
      state = state.copyWith(error: null, hasMore: true);
      await fetchBooks(replace: true);
      return;
    }
    await fetchBooks();
  }

  /// 刷新（清空重新加载，对标 Android 下拉刷新）
  ///
  /// 与加载上一页/加载更多互斥：在途时忽略刷新（两条链路都会改写 books）。
  /// 返回本次是否被接受——被忽略时调用方（下拉刷新/顶栏刷新入口）据此
  /// 给出提示，避免「下拉了没反应」。
  Future<bool> refresh() async {
    if (state.isLoading || state.isLoadingPrevious) return false;
    state = state.copyWith(
      books: [],
      page: 1,
      displayPage: 0,
      hasMore: true,
      error: null,
      previousError: null,
    );
    await fetchBooks(replace: true);
    return true;
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

    // [批39 审查回修] 先按合并顺序拼出候选序列，再一次性生成去重键
    // （无 URL/无作者书按「同名出现序」分配稳定 ordinal）；prepend 后
    // 已有书的键不因列表下标后移而漂移（渲染键/锚点键与 Notifier 同源）。
    final sequence = prepend
        ? <SearchBook>[...incoming, ...existing]
        : <SearchBook>[...existing, ...incoming];
    final keys = exploreBookDedupeKeys(sequence);
    final seen = <String>{};
    final merged = <SearchBook>[];
    for (var i = 0; i < sequence.length; i++) {
      if (seen.add(keys[i])) merged.add(sequence[i]);
    }
    return merged;
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) {
      // 登录错误（Rust 1012 LoginRequired）：标记前缀供 UI 提供「去登录」引导 — R4
      final msg = e.message;
      if (msg.contains('需要登录') ||
          msg.contains('LoginRequired') ||
          msg.contains('未登录')) {
        return 'LOGIN_REQUIRED:$msg';
      }
      // 去掉 Rust LegadoError::Internal 的「Internal error: 」前缀，
      // 文案直接面向用户（懒人听书未配置会话 → 「分类加载失败：…请先登录…」）
      var clean = msg.replaceFirst('Internal error: ', '');
      final atIdx = clean.indexOf(' (at ');
      if (atIdx > 0) clean = clean.substring(0, atIdx);
      return clean;
    }
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
