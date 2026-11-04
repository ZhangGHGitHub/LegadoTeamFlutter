// 阅读器书签纯策略（批4d）
//
// 参考：
// - PullBookmarkGesture.kt:12-19/58-78（80dp 激活、1.5 纵向优势、最大
//   偏移 0.6 页高、抬手用最终位移判定）
// - ReaderBookmarkState.kt:36-47（chapterPos 落在 [start, end) 即页内有书签）
//
// 与 UI/Provider 解耦，便于单元测试边界值与双页合并范围。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
import 'dart:ui' show Offset;

import '../../models/models.dart';
import '../paragraph_layout_engine.dart';

/// 页/屏内字符区间（章节全局 UTF-16 偏移，右开区间）
class ReaderBookmarkRange {
  final int start;
  final int end;

  const ReaderBookmarkRange(this.start, this.end);

  static const empty = ReaderBookmarkRange(0, 0);

  bool get isEmpty => end <= start;

  bool contains(int chapterPos) =>
      !isEmpty && chapterPos >= start && chapterPos < end;
}

/// 单页字符区间：取首个段落起点到末个段落终点；无段落回落 0
ReaderBookmarkRange readerBookmarkRangeForPage(PageInfo? page) {
  if (page == null || page.paragraphs.isEmpty) return ReaderBookmarkRange.empty;
  return ReaderBookmarkRange(
    page.paragraphs.first.startIndex,
    page.paragraphs.last.endIndex,
  );
}

/// 当前屏字符区间（双页取左右两页并集；单页同 [readerBookmarkRangeForPage]）
ReaderBookmarkRange readerBookmarkRangeForScreen(
  List<PageInfo> pages,
  int pageIndex, {
  bool doublePage = false,
}) {
  if (pages.isEmpty) return ReaderBookmarkRange.empty;
  final left = pageIndex.clamp(0, pages.length - 1);
  final leftRange = readerBookmarkRangeForPage(pages[left]);
  if (!doublePage || left + 1 >= pages.length) return leftRange;
  final rightRange = readerBookmarkRangeForPage(pages[left + 1]);
  if (leftRange.isEmpty) return rightRange;
  if (rightRange.isEmpty) return leftRange;
  return ReaderBookmarkRange(leftRange.start, rightRange.end);
}

/// 在指定章节区间内查找书签（书键不一致视为无书签）
///
/// 参考快照按 bookName + bookAuthor + chapterIndex 过滤，避免同名书/换书
/// 后旧列表误供给当前页。
Bookmark? readerBookmarkInRange(
  List<Bookmark> bookmarks, {
  required String bookName,
  required String bookAuthor,
  required int chapterIndex,
  required ReaderBookmarkRange range,
}) {
  if (range.isEmpty) return null;
  for (final bookmark in bookmarks) {
    if (bookmark.bookName != bookName ||
        bookmark.bookAuthor != bookAuthor ||
        bookmark.chapterIndex != chapterIndex) {
      continue;
    }
    if (range.contains(bookmark.chapterPos)) return bookmark;
  }
  return null;
}

/// 页首段落正文：章节全局偏移区间映射回章节文本；无段落返回空串
String readerBookmarkPageStartText({
  required PageInfo? page,
  required String chapterContent,
}) {
  if (page == null || page.paragraphs.isEmpty) return '';
  final first = page.paragraphs.first;
  final start = first.startIndex.clamp(0, chapterContent.length);
  final end = first.endIndex.clamp(start, chapterContent.length);
  return chapterContent.substring(start, end);
}

/// 下滑书签手势单帧结果
class ReaderBookmarkPullDrag {
  final bool isCandidate;
  final double pageOffset;
  final bool isArmed;

  const ReaderBookmarkPullDrag({
    required this.isCandidate,
    required this.pageOffset,
    required this.isArmed,
  });

  static const none = ReaderBookmarkPullDrag(
    isCandidate: false,
    pageOffset: 0,
    isArmed: false,
  );
}

/// 下滑书签手势策略（对齐 PullBookmarkGesture.drag / shouldToggleOnRelease）
abstract final class ReaderBookmarkPullGesture {
  static const double activationDistance = 80;
  static const double verticalDominanceRatio = 1.5;
  static const double maxPageOffsetRatio = 0.6;
  static const double hintContentTopMargin = 8;
  static const int hintFadeMillis = 120;
  static const double hintCornerRadius = 24;
  static const int returnDurationMillis = 180;

  static ReaderBookmarkPullDrag drag({
    required Offset delta,
    required double pageHeight,
    required bool enabled,
    required bool pagedMode,
    required bool selectionActive,
  }) {
    final candidate =
        enabled &&
        pagedMode &&
        !selectionActive &&
        delta.dy > 0 &&
        delta.dy.abs() > delta.dx.abs() * verticalDominanceRatio;
    if (!candidate || pageHeight <= 0) return ReaderBookmarkPullDrag.none;
    final offset = delta.dy.clamp(0.0, pageHeight * maxPageOffsetRatio);
    return ReaderBookmarkPullDrag(
      isCandidate: true,
      pageOffset: offset,
      isArmed: delta.dy >= activationDistance,
    );
  }

  /// 抬手必须用指针最终位移，而不是最后一个 MOVE 采样
  static bool shouldToggleOnRelease({
    required bool wasDragging,
    required ReaderBookmarkPullDrag finalDrag,
  }) => wasDragging && finalDrag.isCandidate && finalDrag.isArmed;
}
