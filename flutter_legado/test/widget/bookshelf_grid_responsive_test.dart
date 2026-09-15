// [骨架对齐 2.0.260 | 台账 1-3] 书架网格固定 3 列（对齐参考 03b 有书态，
// [parity fix 2.0.264] 列数 2→3 修正：参考 03b 实为 3 列固定卡宽
// （卡宽≈屏宽 27%/列间距 20/左右边距 22），此前误读为 2 列）：
// 列数不再随窗口宽度分档（原 3/4/6 列响应式逻辑已按红线清理移除），
// 本套件验证任意宽度下均为 3 列、子项比例 5/7、间距 20，且窗口尺寸变化后不变。
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

  testWidgets('手机 360dp：书架网格固定 3 列（5/7，间距 20，对齐参考 03b）',
      (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.mainAxisSpacing, equals(20));
    expect(delegate.crossAxisSpacing, equals(20));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('平板 900dp：书架网格仍为 3 列（5/7）', (tester) async {
    setLogicalWidth(tester, 900);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('桌面 1300dp：书架网格仍为 3 列（5/7）', (tester) async {
    setLogicalWidth(tester, 1300);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio, closeTo(5 / 7, 0.001));
  });

  testWidgets('窗口尺寸变化后网格仍保持 3 列（固定列数不变）',
      (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());
    expect(gridDelegate(tester).crossAxisCount, equals(3));

    tester.view.physicalSize = const Size(1300 * 3, 900);
    await tester.pumpAndSettle();
    expect(gridDelegate(tester).crossAxisCount, equals(3));
  });
}
