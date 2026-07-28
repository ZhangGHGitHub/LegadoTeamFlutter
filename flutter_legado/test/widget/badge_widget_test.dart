import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/badge_widget.dart';

void main() {
  Widget buildTestWidget({
    int count = 0,
    Color? color,
    bool showZero = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: BadgeWidget(
            count: count,
            color: color,
            showZero: showZero,
            child: const Icon(Icons.notifications, size: 32),
          ),
        ),
      ),
    );
  }

  testWidgets('BadgeWidget renders child widget', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.byIcon(Icons.notifications), findsOneWidget);
    expect(find.byType(BadgeWidget), findsOneWidget);
  });

  testWidgets('BadgeWidget shows badge when count > 0', (tester) async {
    await tester.pumpWidget(buildTestWidget(count: 5));

    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('BadgeWidget hides badge when count is 0 and showZero false',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(count: 0, showZero: false));

    expect(find.text('0'), findsNothing);
  });

  testWidgets('BadgeWidget shows badge when count is 0 and showZero true',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(count: 0, showZero: true));

    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('BadgeWidget shows 99+ for count > 99', (tester) async {
    await tester.pumpWidget(buildTestWidget(count: 150));

    expect(find.text('99+'), findsOneWidget);
  });
}
