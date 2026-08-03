import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'rss_history_state.dart';

export 'rss_history_state.dart';

/// RSS 历史页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 已读记录列表经 `BookApi.rssListReadRecords` 委托 Rust（按阅读时间降序），
///   返回项经 [RssReadRecordRow.fromJson] 解析（snake_case 字段）。
/// - 清空经 `BookApi.rssClearReadRecords` 委托 Rust，成功后重新拉取列表。
class RssHistoryNotifier extends Notifier<RssHistoryState> {
  @override
  RssHistoryState build() => const RssHistoryState();

  /// 加载已读记录列表
  Future<void> load({int? limit}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final raw = await ref.read(bookApiProvider).rssListReadRecords(limit);
      final records = raw
          .whereType<Map<String, dynamic>>()
          .map(RssReadRecordRow.fromJson)
          .toList();
      state = state.copyWith(records: records, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 清空全部已读记录（成功后重新拉取列表）
  Future<void> clear() async {
    state = state.copyWith(isClearing: true, error: null);
    try {
      await ref.read(bookApiProvider).rssClearReadRecords();
      state = state.copyWith(isClearing: false);
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isClearing: false);
    }
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// RSS 历史 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(rssHistoryNotifierProvider);
/// ref.read(rssHistoryNotifierProvider.notifier).load();
/// ```
final rssHistoryNotifierProvider =
    NotifierProvider<RssHistoryNotifier, RssHistoryState>(
  RssHistoryNotifier.new,
);
