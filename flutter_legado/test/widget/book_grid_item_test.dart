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
    VoidCallback? onLongPress,
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
            onLongPress: onLongPress,
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

    await tester.tap(find.byType(BookGridItem));
    expect(tapped, isTrue);
  });

  testWidgets('BookGridItem shows placeholder icon without cover',
      (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.byIcon(Icons.menu_book), findsOneWidget);
  });
}
