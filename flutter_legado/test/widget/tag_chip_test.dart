import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_legado/src/widgets/tag_chip.dart';

void main() {
  Widget buildTestWidget({
    String label = '测试标签',
    Color? color,
    VoidCallback? onDeleted,
    VoidCallback? onTap,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: TagChip(
            label: label,
            color: color,
            onDeleted: onDeleted,
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  testWidgets('TagChip renders label text', (tester) async {
    await tester.pumpWidget(buildTestWidget(label: '玄幻'));

    expect(find.text('玄幻'), findsOneWidget);
    expect(find.byType(TagChip), findsOneWidget);
  });

  testWidgets('TagChip shows delete icon when onDeleted provided',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(onDeleted: () {}));

    expect(find.byIcon(Symbols.close_rounded), findsOneWidget);
  });

  testWidgets('TagChip hides delete icon when onDeleted is null',
      (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.byIcon(Symbols.close_rounded), findsNothing);
  });

  testWidgets('TagChip onTap callback works', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTestWidget(onTap: () => tapped = true));

    await tester.tap(find.byType(TagChip));
    expect(tapped, isTrue);
  });

  testWidgets('TagChip onDeleted callback works', (tester) async {
    var deleted = false;
    await tester.pumpWidget(buildTestWidget(onDeleted: () => deleted = true));

    await tester.tap(find.byIcon(Symbols.close_rounded));
    expect(deleted, isTrue);
  });
}

