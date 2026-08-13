import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/help/help_markdown_builders.dart';
import 'package:flutter_legado/src/widgets/help/help_markdown_styles.dart';

Widget _helpMarkdownHarness(String data) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Scaffold(
          body: Markdown(
            data: data,
            styleSheet: helpMarkdownStyleSheet(theme),
            builders: helpMarkdownBuilders(theme),
          ),
        );
      },
    ),
  );
}

void main() {
  group('helpMarkdownBuilders', () {
    testWidgets('h2 标题下渲染可见分隔线', (tester) async {
      await tester.pumpWidget(_helpMarkdownHarness('## 新人必读\n\n正文内容'));

      expect(find.text('新人必读'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
    });

    testWidgets('h1 标题下渲染可见分隔线', (tester) async {
      await tester.pumpWidget(_helpMarkdownHarness('# 帮助文档\n\n正文'));

      expect(find.text('帮助文档'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
    });
  });
}
