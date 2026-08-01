import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'bookmark_state.freezed.dart';

/// 书签页 UI 状态（immutable）
///
/// 职责边界（对齐原 BookmarkProvider 可观察字段）：
/// - [bookmarks]：当前展示的书签列表（全部 / 按书名 / 搜索结果的快照）
/// - [isLoading]：API 调用加载态
/// - [error]：错误信息（null 表示无错误）
@freezed
class BookmarkState with _$BookmarkState {
  const factory BookmarkState({
    /// 书签列表
    @Default([]) List<Bookmark> bookmarks,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,
  }) = _BookmarkState;
}

/// 书签展示扩展 —— 纯展示层派生逻辑，不改变数据内容
extension BookmarkStateDerived on BookmarkState {
  /// 书签为空且不在加载中
  bool get isEmpty => bookmarks.isEmpty && !isLoading;
}
