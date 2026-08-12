import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/review_column.dart';

void main() {
  testWidgets('ReviewColumnBadge 仅在 count>0 时展示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ReviewColumnBadge(count: 0)),
      ),
    );
    expect(find.text('0'), findsNothing);

    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewColumnBadge(
            count: 12,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    expect(find.text('12'), findsOneWidget);
    await tester.tap(find.text('12'));
    expect(tapped, isTrue);
  });

  test('ParagraphInfo 携带章内段序号与段末标记', () {
    const para = ParagraphInfo(
      lines: [],
      totalHeight: 0,
      startIndex: 0,
      endIndex: 0,
      chapterParagraphIndex: 3,
      isParagraphEnd: true,
    );
    expect(para.chapterParagraphIndex, 3);
    expect(para.isParagraphEnd, isTrue);
  });
}
