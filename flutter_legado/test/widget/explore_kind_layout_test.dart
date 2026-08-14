// ExploreKindLayout widget 测试：style 驱动的 wide/cell 布局
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/widgets/explore_kind_layout.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.exploreInfoMapPut(any(), any(), any()))
        .thenAnswer((_) async {});
    when(() => mockApi.exploreInfoMapEnsureDefault(any(), any(), any()))
        .thenAnswer((_) async {});
  });

  Widget wrap(Widget child) => ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  const sourceUrl = 'https://explore-layout.test';
  const cellStyle = FlexChildStyle(
    layoutFlexGrow: 1,
    layoutFlexBasisPercent: 0.25,
  );
  const wideStyle = FlexChildStyle(
    layoutFlexGrow: 1,
    layoutFlexBasisPercent: 1,
  );

  testWidgets('cell 项按 flexBasisPercent 网格排布，wide 项独占一行', (tester) async {
    final categories = [
      const ExploreCategory(title: '推荐', url: '/rec', style: cellStyle),
      const ExploreCategory(title: '小说', url: '/novel', style: cellStyle),
      const ExploreCategory(title: '会员', url: '/vip', style: cellStyle),
      const ExploreCategory(title: '儿童', url: '/child', style: cellStyle),
      const ExploreCategory(title: '儿童分类', style: wideStyle),
      const ExploreCategory(title: '故事', url: '/story', style: cellStyle),
      const ExploreCategory(
        title: '排行榜',
        url: '/rank',
        style: wideStyle,
      ),
      const ExploreCategory(title: '音乐频道', style: wideStyle),
      const ExploreCategory(title: '流行', url: '/pop', style: cellStyle),
    ];

    await tester.pumpWidget(
      wrap(
        Center(
          child: SizedBox(
            width: 360,
            child: ExploreKindLayout(
              sourceUrl: sourceUrl,
              categories: categories,
            ),
          ),
        ),
      ),
    );

    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('儿童分类'), findsOneWidget);
    expect(find.text('音乐频道'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);

    expect(find.byIcon(Icons.chevron_right), findsNothing);

    Size cellSize(String title) => tester.getSize(find.ancestor(
          of: find.text(title),
          matching: find.byType(InkWell),
        ));
    final w0 = cellSize('推荐').width;
    final w1 = cellSize('小说').width;
    expect(w0, closeTo(w1, 1));
    expect(w0, closeTo(84.5, 2));

    final wideChip = find.ancestor(
      of: find.text('排行榜'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(wideChip).width, closeTo(360, 2));
  });

  testWidgets('可点击 cell 项触发 onCategoryTap', (tester) async {
    String? tappedTitle;
    await tester.pumpWidget(
      wrap(
        ExploreKindLayout(
          sourceUrl: sourceUrl,
          categories: const [
            ExploreCategory(
              title: '玄幻',
              url: '/xh',
              style: cellStyle,
            ),
          ],
          onCategoryTap: (title, url) => tappedTitle = title,
        ),
      ),
    );

    await tester.tap(find.text('玄幻'));
    await tester.pump();
    expect(tappedTitle, '玄幻');
  });
}
