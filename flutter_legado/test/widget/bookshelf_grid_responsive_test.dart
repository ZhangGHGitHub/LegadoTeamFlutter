import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

/// 书架网格多尺寸渲染验证（REFACTORING_REMAINING_PLAN §4.3 P2-3④）
///
/// 真实渲染 BookshelfScreen，在不同窗口宽度下断言网格 delegate 的
/// 列数与宽高比，与 Responsive 断点规则一一对应。
void main() {
  setUpAll(registerFallbacks);

  Future<void> pumpBookshelf(WidgetTester tester, MockRustApi mockApi) async {
    SharedPreferences.setMockInitialValues({});
    when(() => mockApi.getBooks()).thenAnswer((_) async => const [
          Book(bookUrl: 'u1', name: '书一'),
          Book(bookUrl: 'u2', name: '书二'),
          Book(bookUrl: 'u3', name: '书三'),
        ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  SliverGridDelegateWithFixedCrossAxisCount gridDelegate(WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    return grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  }

  void setLogicalWidth(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width * 3, 900);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('手机 360dp：书架网格 3 列竖卡（0.65，对齐原版默认列数）', (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio, equals(0.65));
  });

  testWidgets('手机大屏 500dp：书架网格 3 列竖卡（0.65）', (tester) async {
    setLogicalWidth(tester, 500);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio, equals(0.65));
  });

  testWidgets('平板 900dp：书架网格 4 列横卡（0.75）', (tester) async {
    setLogicalWidth(tester, 900);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(4));
    expect(delegate.childAspectRatio, equals(0.75));
  });

  testWidgets('桌面 1300dp：书架网格 6 列横卡（0.75）', (tester) async {
    setLogicalWidth(tester, 1300);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(6));
    expect(delegate.childAspectRatio, equals(0.75));
  });

  testWidgets('窗口尺寸变化后网格列数自适应重算', (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());
    expect(gridDelegate(tester).crossAxisCount, equals(3));

    // 模拟窗口拉宽到桌面尺寸
    tester.view.physicalSize = const Size(1300 * 3, 900);
    await tester.pumpAndSettle();
    expect(gridDelegate(tester).crossAxisCount, equals(6));
  });
}
