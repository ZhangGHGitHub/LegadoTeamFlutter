import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/source_card.dart';

void main() {
  Widget buildTestWidget({
    String name = '笔趣阁',
    String url = 'https://www.biquge.com',
    bool isEnabled = true,
    String? group,
    VoidCallback? onTap,
    VoidCallback? onToggle,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            SourceCard(
              name: name,
              url: url,
              isEnabled: isEnabled,
              group: group,
              onTap: onTap,
              onToggle: onToggle,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('SourceCard renders name and url', (tester) async {
    await tester.pumpWidget(buildTestWidget(
      name: '起点中文网',
      url: 'https://www.qidian.com',
    ));

    expect(find.text('起点中文网'), findsOneWidget);
    expect(find.text('https://www.qidian.com'), findsOneWidget);
  });

  testWidgets('SourceCard shows group tag when provided', (tester) async {
    await tester.pumpWidget(buildTestWidget(group: '玄幻'));

    expect(find.text('玄幻'), findsOneWidget);
  });

  testWidgets('SourceCard has switch widget', (tester) async {
    await tester.pumpWidget(buildTestWidget());

    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('SourceCard onToggle callback works', (tester) async {
    var toggled = false;
    await tester.pumpWidget(buildTestWidget(onToggle: () => toggled = true));

    await tester.tap(find.byType(Switch));
    expect(toggled, isTrue);
  });

  testWidgets('SourceCard onTap callback works', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTestWidget(onTap: () => tapped = true));

    await tester.tap(find.byType(SourceCard));
    expect(tapped, isTrue);
  });
}
