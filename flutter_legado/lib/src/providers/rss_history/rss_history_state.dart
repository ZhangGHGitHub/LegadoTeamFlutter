import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'rss_history_state.freezed.dart';

/// RSS 历史页状态
///
/// 由 [RssHistoryNotifier] 管理：已读记录经 `BookApi.rssListReadRecords`
/// 委托 Rust（按阅读时间降序，契约见 API_CONTRACT.md §2.35）。
@freezed
class RssHistoryState with _$RssHistoryState {
  const factory RssHistoryState({
    /// 已读记录列表（按阅读时间降序）
    @Default([]) List<RssReadRecordRow> records,

    /// 正在加载
    @Default(false) bool isLoading,

    /// 正在清空
    @Default(false) bool isClearing,

    /// 错误信息
    String? error,
  }) = _RssHistoryState;
}
