import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'explore_state.dart';

export 'explore_state.dart';

/// 发现页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §3.2 铁律 与 ExploreFragment.kt）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data 三态）
/// - 管理展示层过滤（实时搜索关键词、分组筛选）
/// - 分类解析缓存（调用 Rust exploreParseUrl）
/// - 书源卸载（CRUD 透传）
/// - 禁止包含业务计算（分类解析/书籍抓取由 Rust 完成）
class ExploreNotifier extends Notifier<ExploreState> {
  @override
  ExploreState build() {
    // 延迟到 build() 返回后执行（state 初始化完成后才能访问）
    Future.microtask(_loadBookSources);
    return const ExploreState();
  }

  /// 加载已安装发现书源
  ///
  /// 对齐 Android ExploreFragment：仅保留启用发现且 exploreUrl 非空的书源
  Future<void> _loadBookSources() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      final exploreSources = sources
          .where((s) =>
              s.enabledExplore &&
              (s.exploreUrl != null && s.exploreUrl!.trim().isNotEmpty))
          .toList();
      state = state.copyWith(bookSources: exploreSources, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        error: '加载书源失败：${_mapError(e)}',
        isLoading: false,
      );
    }
  }

  /// 刷新书源列表
  Future<void> refresh() => _loadBookSources();

  /// 设置搜索关键词（实时过滤，对齐 SearchView onQueryTextChange）
  void setSearchKeyword(String keyword) {
    state = state.copyWith(searchKeyword: keyword);
  }

  /// 清除搜索关键词
  void clearSearch() {
    state = state.copyWith(searchKeyword: '');
  }

  /// 设置选中分组（对齐 menu_group_text 选择）
  void selectGroup(String group) {
    state = state.copyWith(selectedGroup: group);
  }

  /// 解析并缓存指定书源的分类列表（调用 Rust exploreParseUrl）
  ///
  /// 对齐 Android ExploreAdapter 分类标签加载逻辑。
  /// 已缓存或正在加载时直接返回，避免重复请求。
  /// [force] 为 true 时强制重新解析（对标 refreshExplore / clearExploreKindsCache）
  Future<void> loadCategories(BookSource source, {bool force = false}) async {
    final url = source.bookSourceUrl;
    final exploreUrl = source.exploreUrl;
    // 无 exploreUrl：缓存空分类，避免重复判断
    if (exploreUrl == null || exploreUrl.trim().isEmpty) {
      if (!state.categoriesCache.containsKey(url)) {
        state = state.copyWith(categoriesCache: {
          ...state.categoriesCache,
          url: const [],
        });
      }
      return;
    }
    // 已缓存（非空）或正在加载：幂等返回；空缓存允许重试（对齐 Android 可刷新发现）
    final cached = state.categoriesCache[url];
    if (!force &&
        (state.loadingCategories.contains(url) ||
            (cached != null && cached.isNotEmpty))) {
      return;
    }
    state = state.copyWith(
      loadingCategories: {...state.loadingCategories, url},
    );
    try {
      final api = ref.read(bookApiProvider);
      final categories = await api.exploreParseUrl(
        exploreUrl,
        sourceJson: jsonEncode(source.toJson()),
      );
      await _initExploreInfoMapDefaults(api, source.bookSourceUrl, categories);
      state = state.copyWith(
        categoriesCache: {...state.categoriesCache, url: categories},
        loadingCategories: {...state.loadingCategories}..remove(url),
      );
    } catch (_) {
      // 解析失败：缓存空分类（对齐原实现静默失败）
      state = state.copyWith(
        categoriesCache: {...state.categoriesCache, url: const []},
        loadingCategories: {...state.loadingCategories}..remove(url),
      );
    }
  }

  /// 强制刷新书源发现分类（对标 Android refreshExplore + clearExploreKindsCache）
  Future<void> reloadCategories(BookSource source) async {
    final url = source.bookSourceUrl;
    state = state.copyWith(
      categoriesCache: Map<String, List<ExploreCategory>>.from(
        state.categoriesCache,
      )..remove(url),
    );
    await loadCategories(source, force: true);
  }

  /// 卸载书源（对齐 ExploreFragment.deleteSource，CRUD 透传）
  ///
  /// 注意：where 过滤是「UI 状态同步」而非「业务逻辑」
  Future<bool> uninstallSource(String sourceUrl) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.deleteBookSource(sourceUrl);
      state = state.copyWith(
        bookSources: state.bookSources
            .where((s) => s.bookSourceUrl != sourceUrl)
            .toList(),
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: '卸载失败：${_mapError(e)}');
      return false;
    }
  }

  /// 清除错误状态
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }

  /// 为 toggle/select 控件初始化 infoMap 默认值（对标 Android ExploreAdapter）
  Future<void> _initExploreInfoMapDefaults(
    BookApi api,
    String sourceUrl,
    List<ExploreCategory> categories,
  ) async {
    for (final category in categories) {
      if (category.type != 'toggle' && category.type != 'select') continue;
      final chars = category.chars;
      if (chars == null || chars.isEmpty) continue;
      final defaultValue = category.defaultValue ?? chars.first;
      await api.exploreInfoMapEnsureDefault(
        sourceUrl,
        category.title,
        defaultValue,
      );
    }
  }
}

/// 发现页 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(exploreNotifierProvider);
/// ref.read(exploreNotifierProvider.notifier).refresh();
/// ```
final exploreNotifierProvider =
    NotifierProvider<ExploreNotifier, ExploreState>(
  ExploreNotifier.new,
);
