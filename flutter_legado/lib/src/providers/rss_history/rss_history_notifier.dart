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
///   返回项经 [RssReadRecordRow.fromJson] 解析（`read_time` snake_case；
///   扩展字段 camelCase（`pubDate` / `durPos`））。
/// - 清空经 `BookApi.rssClearReadRecords` 委托 Rust，成功后重新拉取列表。
class RssHistoryNotifier extends Notifier<RssHistoryState> {
  @override
  RssHistoryState build() => const RssHistoryState();

  /// 加载已读记录列表；[origin] 非空时走按源查询（F3-17）
  Future<void> load({int? limit, String? origin}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final raw = origin != null
          ? await api.rssListReadRecordsByOrigin(origin, limit)
          : await api.rssListReadRecords(limit);
      final records = raw
          .whereType<Map<String, dynamic>>()
          .map(RssReadRecordRow.fromJson)
          .toList();
      state = state.copyWith(records: records, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 清空已读记录（[origin] 非空时只清空该源；成功后按同范围重新拉取列表）
  ///
  /// 批29：对齐原版 `ReadRecordDialog` 的「清空」——按当前源
  /// `RssReadRecordDao.deleteAllRecord(origin)`；不传参数清空全部（旧行为）。
  Future<void> clear({String? origin}) async {
    state = state.copyWith(isClearing: true, error: null);
    try {
      await ref.read(bookApiProvider).rssClearReadRecords(origin: origin);
      state = state.copyWith(isClearing: false);
      await load(origin: origin);
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
