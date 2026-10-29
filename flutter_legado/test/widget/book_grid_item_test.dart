import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/book_display_tags_row.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';

void main() {
  Widget buildTestWidget({
    String title = '斗破苍穹',
    String? coverUrl,
    int unreadNum = 0,
    double? progress,
    List<String> tags = const [],
    bool reserveTagRow = false,
    VoidCallback? onTap,
    VoidCallback? onCoverLongPress,
    VoidCallback? onInfoLongPress,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 120,
          height: 240,
          child: BookGridItem(
            title: title,
            coverUrl: coverUrl,
            unreadNum: unreadNum,
            progress: progress,
            tags: tags,
            reserveTagRow: reserveTagRow,
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

  // ===== [批35] 展示标签行 =====

  testWidgets('传入标签时书卡渲染标签条', (tester) async {
    await tester.pumpWidget(
      buildTestWidget(tags: const ['仙侠', '12万字']),
    );

    expect(find.text('仙侠'), findsOneWidget);
    expect(find.text('12万字'), findsOneWidget);
    expect(find.byType(BookDisplayTagsRow), findsOneWidget);
  });

  testWidgets('空标签且未预留行高时不渲染标签条', (tester) async {
    await tester.pumpWidget(
      buildTestWidget(tags: const [], reserveTagRow: false),
    );

    expect(find.byType(BookDisplayTagsRow), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });

  testWidgets('预留行高时无标签书卡也占等高空行（兄弟卡片封面等高）', (tester) async {
    await tester.pumpWidget(
      buildTestWidget(tags: const [], reserveTagRow: true),
    );

    // 空行由固定高度的 SizedBox 承担
    final boxes = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((b) => b.height == BookGridItem.tagRowHeight);
    expect(boxes, isNotEmpty);
    expect(find.byType(BookDisplayTagsRow), findsNothing);
  });

  // ===== [批35b P3-4] 无障碍缩放下的标签行高 =====

  testWidgets('textScaleFactor 2.0 时标签行按 textScaler 抬升且不裁切', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      buildTestWidget(tags: const ['仙侠'], reserveTagRow: true),
    );

    // 紧凑卡字号 10sp、行高系数 1.2、垂直内边距 4：缩放 2.0 需 ≥ 28dp
    const minScaledHeight = 10.0 * 2.0 * 1.2 + 4;
    final rowHeight = tester.getSize(find.byType(BookDisplayTagsRow)).height;
    expect(
      rowHeight,
      greaterThanOrEqualTo(minScaledHeight),
      reason: '固定 20dp 会裁切 2 倍字号标签，行高必须按 textScaler 抬升',
    );
    expect(tester.takeException(), isNull, reason: '大字号下不得出现布局溢出');
  });

  testWidgets('默认字号下标签行保持设计高度 20dp', (tester) async {
    await tester.pumpWidget(buildTestWidget(tags: const ['仙侠']));

    expect(
      tester.getSize(find.byType(BookDisplayTagsRow)).height,
      BookGridItem.tagRowHeight,
      reason: '默认字号不改变既有视觉行高',
    );
  });
}
