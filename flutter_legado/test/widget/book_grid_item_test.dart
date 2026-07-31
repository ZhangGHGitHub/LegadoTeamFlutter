import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';

void main() {
  Widget buildTestWidget({
    String title = '斗破苍穹',
    String? coverUrl,
    String? author,
    double? progress,
    VoidCallback? onTap,
    VoidCallback? onCoverLongPress,
    VoidCallback? onInfoLongPress,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 120,
          height: 200,
          child: BookGridItem(
            title: title,
            coverUrl: coverUrl,
            author: author,
            progress: progress,
            onTap: onTap,
            onCoverLongPress: onCoverLongPress,
            onInfoLongPress: onInfoLongPress,
          ),
        ),
      ),
    );
  }

  testWidgets('BookGridItem renders title', (tester) async {
    await tester.pumpWidget(buildTestWidget(title: '完美世界'));

    expect(find.text('完美世界'), findsOneWidget);
    expect(find.byType(BookGridItem), findsOneWidget);
  });

  testWidgets('BookGridItem renders author when provided', (tester) async {
    await tester.pumpWidget(buildTestWidget(author: '天蚕土豆'));

    expect(find.text('天蚕土豆'), findsOneWidget);
  });

  testWidgets('BookGridItem shows progress bar when progress provided',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(progress: 0.5));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('BookGridItem onTap callback works', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTestWidget(onTap: () => tapped = true));

    // 点击封面区域触发 onTap
    await tester.tap(find.byIcon(Icons.menu_book));
    expect(tapped, isTrue);
  });

  testWidgets('BookGridItem cover long press triggers onCoverLongPress',
      (tester) async {
    var coverLongPressed = false;
    await tester.pumpWidget(
      buildTestWidget(onCoverLongPress: () => coverLongPressed = true),
    );

    // 长按封面区域（占位图标）
    await tester.longPress(find.byIcon(Icons.menu_book));
    expect(coverLongPressed, isTrue);
  });

  testWidgets('BookGridItem info long press triggers onInfoLongPress',
      (tester) async {
    var infoLongPressed = false;
    await tester.pumpWidget(
      buildTestWidget(
        title: '测试书籍',
        onInfoLongPress: () => infoLongPressed = true,
      ),
    );

    // 长按标题区域
    await tester.longPress(find.text('测试书籍'));
    expect(infoLongPressed, isTrue);
  });

  testWidgets('BookGridItem shows placeholder icon without cover',
      (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.byIcon(Icons.menu_book), findsOneWidget);
  });
}
