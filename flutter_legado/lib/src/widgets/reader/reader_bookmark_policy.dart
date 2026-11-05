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

/// 单页字符区间：行级可见区间（跨页长段落不得退化为整段）。
///
/// 排版引擎刻意保留整段 [ParagraphInfo.startIndex]/[endIndex]（跨页长段
/// 的每个分片都指向整段），故页范围必须取首行/末行的章节全局偏移：
/// start = 首行 [LineInfo.chapterStartIndex]；
/// end = 末行 chapterStartIndex + 末行可见长度（剔除缩进 [highlightSkip]）。
/// 行缺失或未建立映射时回落段落偏移（手工构造/旧路径）。
ReaderBookmarkRange readerBookmarkRangeForPage(PageInfo? page) {
  if (page == null || page.paragraphs.isEmpty) return ReaderBookmarkRange.empty;
  final firstPara = page.paragraphs.first;
  final lastPara = page.paragraphs.last;

  var start = firstPara.startIndex;
  if (firstPara.lines.isNotEmpty && firstPara.lines.first.highlightMapped) {
    start = firstPara.lines.first.chapterStartIndex;
  }

  var end = lastPara.endIndex;
  if (lastPara.lines.isNotEmpty && lastPara.lines.last.highlightMapped) {
    final lastLine = lastPara.lines.last;
    final visibleLength =
        lastLine.endIndex - lastLine.startIndex - lastLine.highlightSkip;
    if (visibleLength > 0) {
      end = lastLine.chapterStartIndex + visibleLength;
    }
  }

  if (end <= start) return ReaderBookmarkRange.empty;
  return ReaderBookmarkRange(start, end);
}

/// 当前章各页页首字符偏移（朗读按页划分，设置批5b）
///
/// 复用 [readerBookmarkRangeForPage] 的行级可见区间：跨页长段落的页首取
/// 首行 `chapterStartIndex`，不会退化为整段偏移。始终包含 0，章末由朗读
/// 切分函数补齐；空分页/空正文返回空列表。
List<int> readerPageStartsForPages(List<PageInfo> pages, int contentLength) {
  if (pages.isEmpty || contentLength <= 0) return const [];
  final starts = <int>{0};
  for (final page in pages) {
    final range = readerBookmarkRangeForPage(page);
    if (range.isEmpty) continue;
    if (range.start > 0 && range.start < contentLength) {
      starts.add(range.start);
    }
  }
  final sorted = starts.toList()..sort();
  return List<int>.unmodifiable(sorted);
}

/// 当前屏字符区间（双页按屏首左页对齐后取并集；单页同单页区间）
ReaderBookmarkRange readerBookmarkRangeForScreen(
  List<PageInfo> pages,
  int pageIndex, {
  bool doublePage = false,
}) {
  if (pages.isEmpty) return ReaderBookmarkRange.empty;
  // 双页一屏固定从偶数页起（_buildSpread = screenIndex*2），奇数索引
  // 可能来自历史进度/恢复路径，先对齐屏首再合并，避免只算右页。
  final screenStart = doublePage ? (pageIndex ~/ 2) * 2 : pageIndex;
  final left = screenStart.clamp(0, pages.length - 1);
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
/// 后旧列表误供给当前页。区间内可能有多条（历史书签/页内新增），按
/// [referencePos]（默认页首）取最近一条，对齐参考 minBy(abs) 语义；
/// 不再依赖列表顺序返回第一条。
Bookmark? readerBookmarkInRange(
  List<Bookmark> bookmarks, {
  required String bookName,
  required String bookAuthor,
  required int chapterIndex,
  required ReaderBookmarkRange range,
  int? referencePos,
}) {
  if (range.isEmpty) return null;
  final reference = referencePos ?? range.start;
  Bookmark? best;
  var bestDistance = 1 << 62;
  for (final bookmark in bookmarks) {
    if (bookmark.bookName != bookName ||
        bookmark.bookAuthor != bookAuthor ||
        bookmark.chapterIndex != chapterIndex) {
      continue;
    }
    if (!range.contains(bookmark.chapterPos)) continue;
    final distance = (bookmark.chapterPos - reference).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = bookmark;
    }
  }
  return best;
}

/// 页首可见正文：行级区间映射回章节文本；行缺失/未映射回落段落；无段落空串
String readerBookmarkPageStartText({
  required PageInfo? page,
  required String chapterContent,
}) {
  if (page == null || page.paragraphs.isEmpty) return '';
  final first = page.paragraphs.first;
  var start = first.startIndex;
  var end = first.endIndex;
  if (first.lines.isNotEmpty && first.lines.first.highlightMapped) {
    final line = first.lines.first;
    final visibleLength = line.endIndex - line.startIndex - line.highlightSkip;
    if (visibleLength > 0) {
      start = line.chapterStartIndex;
      end = start + visibleLength;
    }
  }
  final safeStart = start.clamp(0, chapterContent.length);
  final safeEnd = end.clamp(safeStart, chapterContent.length);
  return chapterContent.substring(safeStart, safeEnd);
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
