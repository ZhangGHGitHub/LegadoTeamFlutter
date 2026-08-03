import 'package:freezed_annotation/freezed_annotation.dart';

part 'remote_book_state.freezed.dart';

/// 远程书籍导入页状态
///
/// 由 [RemoteBookNotifier] 管理：书籍链接批量导入经 `BookApi.importBooks`
/// 委托 Rust（对标安卓原版 RemoteBookActivity，
/// REFACTORING_REMAINING_PLAN §4.3 P2-2④）。
@freezed
class RemoteBookState with _$RemoteBookState {
  const factory RemoteBookState({
    /// 正在导入
    @Default(false) bool isImporting,

    /// 最近一次成功导入的数量（null 表示尚未导入）
    int? importedCount,

    /// 错误信息
    String? error,
  }) = _RemoteBookState;
}
