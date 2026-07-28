import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/custom_progress.dart';

void main() {
  Widget buildTestWidget({
    double value = 0.5,
    Color? color,
    double height = 6,
    bool showLabel = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CustomProgress(
              value: value,
              color: color,
              height: height,
              showLabel: showLabel,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('CustomProgress renders progress indicator', (tester) async {
    await tester.pumpWidget(buildTestWidget(value: 0.7));

    expect(find.byType(CustomProgress), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('CustomProgress shows label when showLabel is true',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(value: 0.75, showLabel: true));

    expect(find.text('75%'), findsOneWidget);
  });

  testWidgets('CustomProgress hides label when showLabel is false',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(value: 0.75, showLabel: false));

    expect(find.text('75%'), findsNothing);
  });

  testWidgets('CustomProgress clamps value to 0-1 range', (tester) async {
    await tester.pumpWidget(buildTestWidget(value: 1.5, showLabel: true));

    // 1.5 should be clamped to 1.0, showing 100%
    expect(find.text('100%'), findsOneWidget);
  });
}
