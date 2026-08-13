import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'change_source_state.dart';

export 'change_source_state.dart';

/// 换源页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 调用 BookApi.searchSource → 接收 Rust 已评分排序的候选列表 → 更新 immutable State
/// - 调用 BookApi.switchSource 完成书源切换并回写 Rust
/// - 管理 UI 状态（loading/error/results/applying 四态）
/// - 禁止包含匹配/评分/排序逻辑（由 Rust SourceMatcher 完成）
class ChangeSourceNotifier extends Notifier<ChangeSourceState> {
  @override
  ChangeSourceState build() => const ChangeSourceState();

  /// 搜索可替换书源
  ///
  /// Rust 返回已按评分降序的候选列表，Dart 侧仅做反序列化，不重排。
  ///
  /// [UI-fix v2.0.3 | 2026-08-06] 留项#12（Task #131）：新增 [group] 参数，
  /// 非空时用 getEnabledBookSources() 内存过滤出该分组源 URL 列表传给
  /// searchSource（对齐原版 AppConfig.searchGroup 分组搜索）；
  /// 分组下无启用源时直接返回空结果，不误搜全部 — Qoder
  Future<void> search(
    String bookName,
    String author, {
    String group = '',
    bool loadInfo = false,
    bool loadToc = false,
    bool loadWordCount = false,
  }) async {
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      List<String>? sourceUrls;
      if (group.isNotEmpty) {
        final sources =
            await ref.read(bookApiProvider).getEnabledBookSources();
        sourceUrls = sources
            .where((s) {
              final g = s.bookSourceGroup ?? '';
              if (g.trim().isEmpty) return false;
              return g
                  .split(RegExp(r'[,，]'))
                  .map((e) => e.trim())
                  .contains(group);
            })
            .map((s) => s.bookSourceUrl)
            .toList();
        if (sourceUrls.isEmpty) {
          // 所选分组无启用书源：直接空结果（不误搜全部）
          state = state.copyWith(results: [], isLoading: false);
          return;
        }
      }
      final api = ref.read(bookApiProvider);
      final raw = sourceUrls == null
          ? await api.searchSource(
              bookName,
              author,
              loadInfo: loadInfo,
              loadToc: loadToc,
              loadWordCount: loadWordCount,
            )
          : await api.searchSource(
              bookName,
              author,
              sourceUrls: sourceUrls,
              loadInfo: loadInfo,
              loadToc: loadToc,
              loadWordCount: loadWordCount,
            );
      final matches = raw.map(SourceMatch.fromJson).toList();
      state = state.copyWith(results: matches, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 应用选中的书源，返回切换后的新 bookUrl
  ///
  /// 经 [BookApi.switchSource] 回写 Rust；解析返回 JSON 取出新 bookUrl，
  /// 解析失败时回退到候选项 [SourceMatch.bookUrl]。切换失败时抛出异常，
  /// 由 UI 侧展示错误提示。
  Future<String> applySource(
    SourceMatch match, {
    required String bookUrl,
  }) async {
    if (state.isApplying) {
      throw StateError('已有换源操作进行中');
    }
    state = state.copyWith(applyingUrl: match.sourceUrl);
    try {
      final updatedJson = await ref.read(bookApiProvider).switchSource(
            bookUrl,
            match.sourceUrl,
            match.bookUrl,
          );
      var newBookUrl = match.bookUrl;
      try {
        final decoded = jsonDecode(updatedJson);
        if (decoded is Map<String, dynamic>) {
          final url = decoded['bookUrl'] as String?;
          if (url != null && url.isNotEmpty) newBookUrl = url;
        }
      } catch (_) {
        // 解析失败时回退到候选项的 bookUrl
      }
      state = state.copyWith(applyingUrl: null);
      return newBookUrl;
    } catch (e) {
      state = state.copyWith(applyingUrl: null);
      rethrow;
    }
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 换源页 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(changeSourceNotifierProvider);
/// ref.read(changeSourceNotifierProvider.notifier).search(bookName, author);
/// ```
final changeSourceNotifierProvider =
    NotifierProvider<ChangeSourceNotifier, ChangeSourceState>(
  ChangeSourceNotifier.new,
);
