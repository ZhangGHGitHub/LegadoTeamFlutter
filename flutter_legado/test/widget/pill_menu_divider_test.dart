import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/pill_divider.dart';

/// PillMenuDivider（弹窗菜单项间分隔）与 PillDivider 接线测试
///
/// 对标参考版 `PillDivider()` 在 RoundDropdownMenuItem 之间的用法
/// （PillDivider.kt 被 13 文件引用，均为弹窗菜单项分隔）；
/// 本文件验证 PopupMenu 内分隔由 PopupMenuDivider 切换为胶囊线形态。
void main() {
  test('PillMenuDivider 高度与 PopupMenuDivider 一致（16dp）', () {
    const entry = PillMenuDivider<int>();
    expect(entry.height, 16);
    expect(entry.represents(null), isFalse);
  });

  testWidgets('PillMenuDivider 渲染为 PillDivider（20% 胶囊线）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PillMenuDivider<void>())),
      ),
    );
    expect(find.byType(PillDivider), findsOneWidget);
    final divider = tester.widget<PillDivider>(find.byType(PillDivider));
    expect(divider.widthFraction, 0.2);
    expect(divider.enabled, isTrue);
  });

  testWidgets('PopupMenu 打开后菜单项间分隔为 PillDivider 而非 PopupMenuDivider',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PopupMenuButton<int>(
              itemBuilder: (context) => const [
                PopupMenuItem(value: 1, child: Text('第一项')),
                PillMenuDivider(),
                PopupMenuItem(value: 2, child: Text('第二项')),
              ],
              child: const Text('打开菜单'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(PillDivider), findsNothing);

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();

    expect(find.text('第一项'), findsOneWidget);
    expect(find.text('第二项'), findsOneWidget);
    expect(find.byType(PillMenuDivider<int>), findsOneWidget);
    expect(find.byType(PillDivider), findsOneWidget);
    expect(find.byType(PopupMenuDivider), findsNothing);
  });

  testWidgets('PillDivider enabled=false 时不渲染（与既有语义一致）',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PillDivider(enabled: false))),
      ),
    );
    expect(find.byType(FractionallySizedBox), findsNothing);
  });
}
