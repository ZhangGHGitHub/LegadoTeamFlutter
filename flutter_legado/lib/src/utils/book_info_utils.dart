import '../models/models.dart';

/// 详情页「自动更新」菜单切换（对齐原版 BookInfoActivity menu_can_update）
///
/// 在架且关闭自动更新时额外清除 [BookType.updateError] 位，避免书架仍显示
/// 更新失败态（对标 Kotlin `removeType(BookType.updateError)`）。
/// — Cursor UI
Book applyBookInfoCanUpdateToggle(Book book, {required bool inBookshelf}) {
  final toggled = book.copyWith(canUpdate: !book.canUpdate);
  if (inBookshelf && !toggled.canUpdate) {
    return toggled.copyWith(
      bookType: toggled.bookType & ~BookType.updateError,
    );
  }
  return toggled;
}
