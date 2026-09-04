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
/// [LAYOUT_MOTION_AUDIT L3] 网格比例统一 5/7（HapeLee 封面 aspect，
/// 不再分竖卡/横卡双比例）
/// 默认布局为列表；本套件强制网格布局后断言响应式列数。
void main() {
  setUpAll(registerFallbacks);

  Future<void> pumpBookshelf(WidgetTester tester, MockRustApi mockApi) async {
    // 强制网格（SettingsService._keyBookshelfLayout）
    SharedPreferences.setMockInitialValues({'bookshelf_layout': true});
    when(() => mockApi.getBooks()).thenAnswer((_) async => const [
          Book(bookUrl: 'u1', name: '书一'),
          Book(bookUrl: 'u2', name: '书二'),
          Book(bookUrl: 'u3', name: '书三'),
        ]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
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

  testWidgets('手机 360dp：书架网格 3 列（5/7，对齐 HapeLee 封面比例）', (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('手机大屏 500dp：书架网格 3 列（5/7）', (tester) async {
    setLogicalWidth(tester, 500);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('平板 900dp：书架网格 4 列（5/7）', (tester) async {
    setLogicalWidth(tester, 900);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(4));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('桌面 1300dp：书架网格 6 列（5/7）', (tester) async {
    setLogicalWidth(tester, 1300);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(6));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('窗口尺寸变化后网格列数自适应重算', (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());
    expect(gridDelegate(tester).crossAxisCount, equals(3));

    tester.view.physicalSize = const Size(1300 * 3, 900);
    await tester.pumpAndSettle();
    expect(gridDelegate(tester).crossAxisCount, equals(6));
  });
}
