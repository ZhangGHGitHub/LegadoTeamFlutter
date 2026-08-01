import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'bookshelf_state.freezed.dart';

/// 书架分组模式 —— 纯展示层概念，仅决定 UI 如何分块显示
enum GroupMode { none, bySource, byGroup }

/// 书架 UI 状态（immutable）
///
/// 职责边界说明（对齐 UI_RESTRUCTURE_PLAN.md §0.3）：
/// - [books]：Rust API 返回的原始数据（已排序），Notifier 不做任何业务处理
/// - [isLoading] / [error]：API 调用状态
/// - [isGridView] / [groupMode]：展示层变换，仅改变呈现形式
/// - [showRecentReading] / [showStats]：用户偏好开关，持久化到 SharedPreferences
@freezed
class BookshelfState with _$BookshelfState {
  const factory BookshelfState({
    /// Rust 返回的书籍列表（已排序，UI 层不做排序）
    @Default([]) List<Book> books,

    /// 是否正在加载
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,

    /// 展示层：网格/列表视图模式
    @Default(true) bool isGridView,

    /// 展示层：分组显示模式
    @Default(GroupMode.none) GroupMode groupMode,

    /// 用户偏好：是否显示最近阅读区域
    @Default(true) bool showRecentReading,

    /// 用户偏好：是否显示阅读统计
    @Default(true) bool showStats,
  }) = _BookshelfState;
}

/// 分组展示扩展 —— 纯展示层变换，不改变数据内容
extension BookshelfStateGrouping on BookshelfState {
  /// 书籍是否为空且不在加载中
  bool get isEmpty => books.isEmpty && !isLoading;

  /// 分组后的书籍，用于展示分组头
  ///
  /// 仅改变呈现形式（按来源/分组分块显示），不改变数据本身
  Map<String, List<Book>> get groupedBooks {
    if (groupMode == GroupMode.none) {
      return {'全部': books};
    }
    final map = <String, List<Book>>{};
    for (final book in books) {
      final key = _getGroupKey(book);
      map.putIfAbsent(key, () => []).add(book);
    }
    return map;
  }

  String _getGroupKey(Book book) {
    switch (groupMode) {
      case GroupMode.bySource:
        return book.originName.isNotEmpty ? book.originName : '本地';
      case GroupMode.byGroup:
        return book.group > 0 ? '分组 ${book.group}' : '默认';
      default:
        return '全部';
    }
  }
}
