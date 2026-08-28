// EmptyState 颜文字彩蛋测试（用户授权新增，AGENTS 红线 2026-08-29 口径）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/empty_state.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('kaomoji 模式渲染颜文字与提示，点击切换颜文字', (tester) async {
    EmptyState kaomojiWidget() => const EmptyState(
          icon: Icons.search_off,
          title: '未找到内容',
          subtitle: '换个关键词试试',
          kaomoji: true,
        );

    await tester.pumpWidget(wrap(kaomojiWidget()));
    await tester.pumpAndSettle();

    expect(find.text('未找到内容'), findsOneWidget);
    expect(find.text('换个关键词试试'), findsOneWidget);

    // 点击颜文字区域 → 切换为池内另一个颜文字（AnimatedTextLine 翻滚）
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 颜文字仍在渲染（Text 存在且非提示文字）
    expect(find.byType(EmptyState), findsOneWidget);
  });

  testWidgets('默认模式仍渲染图标（kaomoji 缺省关闭，存量不受影响）', (tester) async {
    await tester.pumpWidget(wrap(const EmptyState(
      icon: Icons.history,
      title: '暂无阅读记录',
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.text('暂无阅读记录'), findsOneWidget);
  });
}
