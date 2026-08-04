import 'dart:math' as math;

import '../models/models.dart';

/// 书架进度/未读数计算（对标原版 BookExtensions.kt / Book.kt）

/// 未读章节数（对标 Book.getUnreadChapterNum）
int unreadChapterNum(Book book) {
  return math.max(book.totalChapterNum - book.durChapterIndex - 1, 0);
}

/// 阅读进度（0.0~1.0，对标 Book.readProgress）
///
/// 返回 null 表示无阅读记录（durChapterIndex==0 且 durChapterPos==0）。
double? bookReadProgress(Book book) {
  if (book.durChapterIndex == 0 && book.durChapterPos == 0) return null;
  final chapterCount = book.totalChapterNum;
  if (chapterCount <= 1) return 1.0;
  final lastChapterIndex = chapterCount - 1;
  return (book.durChapterIndex / lastChapterIndex).clamp(0.0, 1.0);
}
