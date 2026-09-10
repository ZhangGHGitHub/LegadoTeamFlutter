/// 规则语法帮助弹层测试
///
/// 覆盖差异清单 C9：JS 书源编辑页顶栏帮助入口可点，
/// 弹层包含三块静态帮助（源规则说明 / @规则语法 / jsLib 与内置变量）。
/// — full-stack-engineer + UI | 2026-09-09
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/js_source_edit_screen.dart';

import '../mocks/mocks.dart';

void main() {
  testWidgets('JS 书源编辑页：帮助入口可点且弹层含三块标题', (tester) async {
    final mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: JsSourceEditScreen()),
      ),
    );
    await tester.pump();

    // 顶栏入口
    expect(find.byTooltip('规则语法帮助'), findsOneWidget);
    await tester.tap(find.byTooltip('规则语法帮助'));
    await tester.pumpAndSettle();

    // 三块帮助标题
    expect(find.text('阅读 3.0 源规则说明'), findsOneWidget);
    expect(find.text('@规则语法'), findsOneWidget);
    expect(find.text('jsLib 与内置变量'), findsOneWidget);

    // 分块内容抽样：规则名、@ 前缀与内置函数
    expect(find.textContaining('searchUrl'), findsWidgets);
    expect(find.textContaining('@XPath:'), findsWidgets);
    expect(find.textContaining('java.ajax(url)'), findsOneWidget);
  });
}
