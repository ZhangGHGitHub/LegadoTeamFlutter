import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'rss_state.dart';

export 'rss_state.dart';

/// RSS Riverpod Notifier
///
/// 迁移自原 RssProvider（ChangeNotifier）：忠实保留全部方法与错误处理语义，
/// 仅将 `notifyListeners()` 替换为 `state = state.copyWith(...)`。
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理源/文章加载状态（loading/error/data）
/// - 管理分组筛选（对齐安卓 RssFragment）
class RssNotifier extends Notifier<RssState> {
  @override
  RssState build() {
    // 原 RssProvider 构造时不自动加载，源列表由页面 initState 调用 loadSources 触发
    return const RssState();
  }

  // ===== 操作 =====

  /// 设置分组筛选；null 表示「全部」
  void setGroup(String? group) {
    state = state.copyWith(selectedGroup: group);
  }

  /// 加载所有 RSS 源列表
  Future<void> loadSources() async {
    state = state.copyWith(isLoadingSources: true, error: null);

    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getRssSources();
      state = state.copyWith(sources: sources, isLoadingSources: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoadingSources: false);
    }
  }

  /// 选择源并加载文章
  Future<void> selectSource(RssSource source) async {
    state = state.copyWith(
      selectedSource: source,
      isLoadingArticles: true,
      error: null,
      articles: [],
    );

    try {
      final api = ref.read(bookApiProvider);
      final articles = await api.getRssArticles(source.sourceUrl);
      state = state.copyWith(articles: articles, isLoadingArticles: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoadingArticles: false);
    }
  }

  /// 刷新当前选中源的文章
  Future<void> refreshArticles() async {
    final source = state.selectedSource;
    if (source == null) return;
    await selectSource(source);
  }

  /// 清除已选源（返回源列表）
  void clearSelectedSource() {
    state = state.copyWith(selectedSource: null, articles: []);
  }

  /// 添加 RSS 源
  Future<void> addSource(String name, String url) async {
    state = state.copyWith(error: null);

    try {
      final newSource = RssSource(
        sourceUrl: url,
        sourceName: name,
      );
      final api = ref.read(bookApiProvider);
      final added = await api.addRssSource(newSource);
      state = state.copyWith(sources: [...state.sources, added]);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 删除 RSS 源
  Future<void> removeSource(String sourceUrl) async {
    state = state.copyWith(error: null);

    try {
      final api = ref.read(bookApiProvider);
      await api.deleteRssSource(sourceUrl);
      var next = state.copyWith(
        sources:
            state.sources.where((s) => s.sourceUrl != sourceUrl).toList(),
      );
      if (state.selectedSource?.sourceUrl == sourceUrl) {
        // 对齐原 clearSelectedSource：清除选中源与文章
        next = next.copyWith(selectedSource: null, articles: []);
      }
      state = next;
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 清除错误
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 统一错误映射（对齐原 BridgeError 优先取 message）
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// RSS Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(rssNotifierProvider);
/// ref.read(rssNotifierProvider.notifier).loadSources();
/// ```
final rssNotifierProvider = NotifierProvider<RssNotifier, RssState>(
  RssNotifier.new,
);
