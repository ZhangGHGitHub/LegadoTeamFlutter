// ExploreKindLayout widget 测试：style 驱动的 wide/cell 布局
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/widgets/explore_kind_layout.dart';

void main() {
  const cellStyle = FlexChildStyle(
    layoutFlexGrow: 1,
    layoutFlexBasisPercent: 0.25,
  );
  const wideStyle = FlexChildStyle(
    layoutFlexGrow: 1,
    layoutFlexBasisPercent: 1,
  );

  testWidgets('cell 项按行分组，wide 项独占全宽行', (tester) async {
    final categories = [
      const ExploreCategory(title: '推荐', url: '/rec', style: cellStyle),
      const ExploreCategory(title: '小说', url: '/novel', style: cellStyle),
      const ExploreCategory(title: '会员', url: '/vip', style: cellStyle),
      const ExploreCategory(title: '儿童', url: '/child', style: cellStyle),
      const ExploreCategory(title: '儿童分类', style: wideStyle),
      const ExploreCategory(title: '故事', url: '/story', style: cellStyle),
      const ExploreCategory(title: '音乐频道', style: wideStyle),
      const ExploreCategory(title: '流行', url: '/pop', style: cellStyle),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreKindLayout(categories: categories),
        ),
      ),
    );

    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('儿童分类'), findsOneWidget);
    expect(find.text('音乐频道'), findsOneWidget);

    // wide 行应占满可用宽度（Container width: infinity）
    final wideFinder = find.ancestor(
      of: find.text('儿童分类'),
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == double.infinity,
      ),
    );
    expect(wideFinder, findsOneWidget);
  });

  testWidgets('可点击 cell 项触发 onCategoryTap', (tester) async {
    String? tappedTitle;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreKindLayout(
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
      ),
    );

    await tester.tap(find.text('玄幻'));
    await tester.pump();
    expect(tappedTitle, '玄幻');
  });
}
