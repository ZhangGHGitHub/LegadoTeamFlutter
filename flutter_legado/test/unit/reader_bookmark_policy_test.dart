// [批4d] 阅读器书签纯策略单元测试
//
// 覆盖：
// 1. 页/屏字符区间（单页、双页并集、空页回落）；
// 2. 书签命中（书键/章节/区间边界：start 含、end 不含）；
// 3. 页首正文映射（章节全局偏移 clamp）；
// 4. 下滑书签手势策略（分页/滚动、选区、方向优势、80dp 激活、
//    0.6 页高上限、抬手用最终位移判定）。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bookmark_policy.dart';

PageInfo _page(int start, int end) => PageInfo(
  paragraphs: [
    ParagraphInfo(
      lines: const [],
      totalHeight: 20,
      startIndex: start,
      endIndex: end,
    ),
  ],
  totalHeight: 20,
);

Bookmark _bookmark({
  String bookName = '书',
  String bookAuthor = '作者',
  int chapterIndex = 0,
  int chapterPos = 0,
}) => Bookmark(
  id: 1,
  bookName: bookName,
  bookAuthor: bookAuthor,
  chapterIndex: chapterIndex,
  chapterPos: chapterPos,
);

void main() {
  group('页范围', () {
    test('null/无段落 → 空区间', () {
      expect(readerBookmarkRangeForPage(null).isEmpty, isTrue);
      expect(
        readerBookmarkRangeForPage(
          const PageInfo(paragraphs: [], totalHeight: 0),
        ).isEmpty,
        isTrue,
      );
    });

    test('首段起点 → 末段终点', () {
      final range = readerBookmarkRangeForPage(
        PageInfo(
          paragraphs: [
            ParagraphInfo(
              lines: const [],
              totalHeight: 10,
              startIndex: 5,
              endIndex: 20,
            ),
            ParagraphInfo(
              lines: const [],
              totalHeight: 10,
              startIndex: 20,
              endIndex: 48,
            ),
          ],
          totalHeight: 20,
        ),
      );
      expect(range.start, 5);
      expect(range.end, 48);
      expect(range.contains(5), isTrue, reason: '起点包含');
      expect(range.contains(47), isTrue);
      expect(range.contains(48), isFalse, reason: '终点为右开区间');
      expect(range.contains(4), isFalse);
    });

    test('双页屏取左右并集；右页缺失/空时回落左页', () {
      final pages = [_page(0, 100), _page(100, 180)];
      final merged = readerBookmarkRangeForScreen(
        pages,
        0,
        doublePage: true,
      );
      expect((merged.start, merged.end), (0, 180));

      final single = readerBookmarkRangeForScreen(pages, 0);
      expect((single.start, single.end), (0, 100));

      final lastLeft = readerBookmarkRangeForScreen(
        pages,
        1,
        doublePage: true,
      );
      expect((lastLeft.start, lastLeft.end), (100, 180));

      final emptyRight = readerBookmarkRangeForScreen(
        [_page(0, 100), const PageInfo(paragraphs: [], totalHeight: 0)],
        0,
        doublePage: true,
      );
      expect((emptyRight.start, emptyRight.end), (0, 100));
    });

    test('越界页索引夹逼；空列表空区间', () {
      final pages = [_page(0, 100)];
      expect(
        readerBookmarkRangeForScreen(pages, 9).start,
        0,
        reason: '索引夹逼到末页',
      );
      expect(
        readerBookmarkRangeForScreen(const [], 0).isEmpty,
        isTrue,
      );
    });
  });

  group('书签命中', () {
    const range = ReaderBookmarkRange(100, 200);

    test('书键+章节+区间全匹配才命中', () {
      final hit = readerBookmarkInRange(
        [_bookmark(chapterPos: 100)],
        bookName: '书',
        bookAuthor: '作者',
        chapterIndex: 0,
        range: range,
      );
      expect(hit, isNotNull, reason: 'start 边界命中');

      expect(
        readerBookmarkInRange(
          [_bookmark(chapterPos: 200)],
          bookName: '书',
          bookAuthor: '作者',
          chapterIndex: 0,
          range: range,
        ),
        isNull,
        reason: 'end 为右开区间',
      );
      expect(
        readerBookmarkInRange(
          [_bookmark(chapterPos: 150)],
          bookName: '另一本',
          bookAuthor: '作者',
          chapterIndex: 0,
          range: range,
        ),
        isNull,
        reason: '同名书不同作者/书名不得混入',
      );
      expect(
        readerBookmarkInRange(
          [_bookmark(chapterPos: 150)],
          bookName: '书',
          bookAuthor: '作者',
          chapterIndex: 1,
          range: range,
        ),
        isNull,
        reason: '章节不一致不命中',
      );
    });

    test('空区间永不命中', () {
      expect(
        readerBookmarkInRange(
          [_bookmark()],
          bookName: '书',
          bookAuthor: '作者',
          chapterIndex: 0,
          range: ReaderBookmarkRange.empty,
        ),
        isNull,
      );
    });
  });

  group('页首正文', () {
    test('取首个段落正文；越界 clamp', () {
      const content = '第一章正文内容';
      final text = readerBookmarkPageStartText(
        page: _page(2, 4),
        chapterContent: content,
      );
      expect(text, '章正');

      expect(
        readerBookmarkPageStartText(
          page: _page(0, 999),
          chapterContent: content,
        ),
        content,
        reason: '章节文本较短时 clamp 到末尾',
      );
      expect(
        readerBookmarkPageStartText(page: null, chapterContent: content),
        '',
      );
    });
  });

  group('下滑书签手势策略', () {
    ReaderBookmarkPullDrag drag(
      Offset delta, {
      bool enabled = true,
      bool pagedMode = true,
      bool selectionActive = false,
      double pageHeight = 600,
    }) => ReaderBookmarkPullGesture.drag(
      delta: delta,
      pageHeight: pageHeight,
      enabled: enabled,
      pagedMode: pagedMode,
      selectionActive: selectionActive,
    );

    test('常量对齐参考（80dp/1.5/0.6/180ms）', () {
      expect(ReaderBookmarkPullGesture.activationDistance, 80);
      expect(ReaderBookmarkPullGesture.verticalDominanceRatio, 1.5);
      expect(ReaderBookmarkPullGesture.maxPageOffsetRatio, 0.6);
      expect(ReaderBookmarkPullGesture.returnDurationMillis, 180);
    });

    test('开关关闭/滚动模式/选区中 → 不成为候选', () {
      const delta = Offset(0, 120);
      expect(drag(delta, enabled: false).isCandidate, isFalse);
      expect(drag(delta, pagedMode: false).isCandidate, isFalse);
      expect(drag(delta, selectionActive: true).isCandidate, isFalse);
    });

    test('向上/横向/纵向优势不足 → 不成为候选', () {
      expect(drag(const Offset(0, -120)).isCandidate, isFalse);
      expect(drag(const Offset(-120, 0)).isCandidate, isFalse);
      expect(
        drag(const Offset(60, 85)).isCandidate,
        isFalse,
        reason: '85 不大于 60*1.5=90 的纵向优势',
      );
      expect(
        drag(const Offset(60, 95)).isCandidate,
        isTrue,
        reason: '120 > 90 满足 1.5 纵向优势',
      );
    });

    test('80dp 激活阈值与 0.6 页高位移上限', () {
      final below = drag(const Offset(0, 79));
      expect(below.isCandidate, isTrue);
      expect(below.isArmed, isFalse, reason: '未达 80dp');

      final at = drag(const Offset(0, 80));
      expect(at.isArmed, isTrue, reason: '恰好 80dp 即激活');

      final capped = drag(const Offset(0, 600), pageHeight: 600);
      expect(capped.pageOffset, 360, reason: '0.6×600=360');
      expect(capped.isArmed, isTrue);
    });

    test('pageHeight 非法 → 不进入候选', () {
      expect(drag(const Offset(0, 120), pageHeight: 0).isCandidate, isFalse);
    });

    test('抬手判定使用最终位移：未拖动/未激活/候选失效均不切换', () {
      final armed = drag(const Offset(0, 120));
      expect(
        ReaderBookmarkPullGesture.shouldToggleOnRelease(
          wasDragging: true,
          finalDrag: armed,
        ),
        isTrue,
      );
      expect(
        ReaderBookmarkPullGesture.shouldToggleOnRelease(
          wasDragging: false,
          finalDrag: armed,
        ),
        isFalse,
      );
      expect(
        ReaderBookmarkPullGesture.shouldToggleOnRelease(
          wasDragging: true,
          finalDrag: drag(const Offset(0, 60)),
        ),
        isFalse,
      );
      expect(
        ReaderBookmarkPullGesture.shouldToggleOnRelease(
          wasDragging: true,
          finalDrag: ReaderBookmarkPullDrag.none,
        ),
        isFalse,
      );
    });
  });
}
