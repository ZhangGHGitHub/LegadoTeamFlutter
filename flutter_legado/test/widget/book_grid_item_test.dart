import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';

void main() {
  Widget buildTestWidget({
    String title = '斗破苍穹',
    String? coverUrl,
    int unreadNum = 0,
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
            unreadNum: unreadNum,
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

  testWidgets('BookGridItem renders unread badge when unreadNum > 0',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(unreadNum: 5));

    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('BookGridItem hides unread badge when unreadNum is 0',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(unreadNum: 0));

    expect(find.text('0'), findsNothing);
  });

  testWidgets('BookGridItem caps unread badge at 99+', (tester) async {
    await tester.pumpWidget(buildTestWidget(unreadNum: 120));

    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('BookGridItem shows progress bar when progress provided',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(progress: 0.5));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('BookGridItem onTap callback works', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTestWidget(onTap: () => tapped = true));

    // 点击封面区域触发 onTap（无封面 → 默认封面图，对标原版 image_cover_default）
    // [UI-fix | 2026-08-24] 占位符由 Icon 改为默认封面图 — Qoder UI
    await tester.tap(find.byType(Image));
    expect(tapped, isTrue);
  });

  testWidgets('BookGridItem cover long press triggers onCoverLongPress',
      (tester) async {
    var coverLongPressed = false;
    await tester.pumpWidget(
      buildTestWidget(onCoverLongPress: () => coverLongPressed = true),
    );

    // 长按封面区域（默认封面图，对标原版 image_cover_default）
    // [UI-fix | 2026-08-24] 占位符由 Icon 改为默认封面图 — Qoder UI
    await tester.longPress(find.byType(Image));
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

  testWidgets('BookGridItem shows default cover image without cover',
      (tester) async {
    await tester.pumpWidget(buildTestWidget());

    // 无封面 → 默认封面图（对标原版 image_cover_default.jpg）
    // [UI-fix | 2026-08-24] 占位符由 Icon 改为默认封面图 — Qoder UI
    final img = tester.widget<Image>(find.byType(Image));
    expect(
      img.image,
      const AssetImage('assets/images/default_book_cover.jpg'),
    );
  });
}
