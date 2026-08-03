import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'bookshelf_manage_state.freezed.dart';

/// 书架管理页状态
///
/// 由 [BookshelfManageNotifier] 管理：书籍列表经 `BookApi.getBooks` 委托 Rust，
/// 批量删除/移动分组/置顶分别经 `deleteBook`/`setBookGroup`/`topBook` 契约
///（对标安卓原版 BookshelfManageActivity，REFACTORING_REMAINING_PLAN §4.3 P2-2）。
@freezed
class BookshelfManageState with _$BookshelfManageState {
  const factory BookshelfManageState({
    /// 书架书籍列表
    @Default([]) List<Book> books,

    /// 已勾选书籍的 bookUrl 集合
    @Default({}) Set<String> selectedUrls,

    /// 正在加载
    @Default(false) bool isLoading,

    /// 正在执行批量操作
    @Default(false) bool isBusy,

    /// 错误信息
    String? error,
  }) = _BookshelfManageState;
}
