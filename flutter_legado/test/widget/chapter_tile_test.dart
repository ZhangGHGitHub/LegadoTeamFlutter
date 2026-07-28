import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/chapter_tile.dart';

void main() {
  Widget buildTestWidget({
    String title = '第一章 开始',
    bool isRead = false,
    bool isCurrent = false,
    VoidCallback? onTap,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ChapterTile(
              title: title,
              isRead: isRead,
              isCurrent: isCurrent,
              onTap: onTap,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('ChapterTile renders title', (tester) async {
    await tester.pumpWidget(buildTestWidget(title: '第一百章 大结局'));

    expect(find.text('第一百章 大结局'), findsOneWidget);
    expect(find.byType(ChapterTile), findsOneWidget);
  });

  testWidgets('ChapterTile shows play icon when isCurrent', (tester) async {
    await tester.pumpWidget(buildTestWidget(isCurrent: true));

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('ChapterTile hides play icon when not current', (tester) async {
    await tester.pumpWidget(buildTestWidget(isCurrent: false));

    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('ChapterTile onTap callback works', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTestWidget(onTap: () => tapped = true));

    await tester.tap(find.byType(ChapterTile));
    expect(tapped, isTrue);
  });
}
