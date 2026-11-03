// [批4a] 九宫格点击区域 Sheet / 入口测试
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/reader_tap_action.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/click_action_config_sheet.dart';
import 'package:flutter_legado/src/screens/read_config_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Sheet：9 格渲染，点格选动作后保存并刷新网格', (tester) async {
    ReaderAdvancedConfig? updated;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClickActionConfigSheet(
            config: ReaderAdvancedConfig(),
            onChanged: (cfg) => updated = cfg,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('点击区域设置'), findsOneWidget);
    for (var i = 0; i < 9; i++) {
      expect(find.byKey(ValueKey('click-action-cell-$i')), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('click-action-cell-4')),
        matching: find.text('菜单'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('click-action-cell-4')));
    await tester.pumpAndSettle();
    expect(find.text('选择动作'), findsOneWidget);
    expect(
      find.byType(RadioListTile<ReaderTapAction>),
      findsNWidgets(ReaderTapAction.values.length),
    );

    await tester.ensureVisible(find.text('全文搜索'));
    await tester.tap(find.text('全文搜索'));
    await tester.pumpAndSettle();
    expect(updated, isNotNull);
    expect(updated!.tapMiddleCenter, ReaderTapAction.search);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('click-action-cell-4')),
        matching: find.text('全文搜索'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('阅读器「更多」面板：单行入口打开同一 Sheet', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReaderConfigPanel(
                config: ReaderAdvancedConfig(),
                section: ReaderConfigSection.more,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final entry = find.byKey(const ValueKey('reader-click-action-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('click-action-sheet')), findsOneWidget);
    for (var i = 0; i < 9; i++) {
      expect(find.byKey(ValueKey('click-action-cell-$i')), findsOneWidget);
    }
  });

  testWidgets('独立阅读设置页「页面控制」：入口打开 Sheet', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
        child: const MaterialApp(home: ReadConfigScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('read-config-click-action-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('click-action-sheet')), findsOneWidget);
  });
}
