// 书架网格布局响应式（设置批6a-1）
//
// 对齐参考版 `BookshelfScreen.kt:1372-1410`：
// - 竖屏默认网格 3 列、横屏默认网格 7 列（bookshelfLayoutGrid*）；
// - 内容左右边距 8、列间距 8；
// - 单格高 = 封面高 + 书名区（12sp × 1.25 × 行数 + 10）；
// - 封面宽 = min(bookshelfGridCoverWidth, cellWidth)（默认 120）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  Future<void> pumpBookshelf(
    WidgetTester tester,
    MockRustApi mockApi, {
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
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

  SliverGridDelegateWithFixedCrossAxisCount gridDelegate(
      WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid).first);
    return grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  }

  /// 与 `_gridMetrics` 同式（左右 padding 8×2、列间距 8、默认封面比例
  /// 5:7、书名区 12sp×1.25×2 + 10）
  double expectedCellAspectRatio(
    double logicalWidth, {
    int columns = 3,
    int gridCoverWidth = 120,
    int titleLines = 2,
  }) {
    const padding = 8.0;
    const spacing = 8.0;
    final cellW =
        (logicalWidth - padding * 2 - spacing * (columns - 1)) / columns;
    final coverW = cellW < gridCoverWidth ? cellW : gridCoverWidth.toDouble();
    final coverH = coverW * 7 / 5;
    final titleH = 12.0 * 1.25 * titleLines + 10;
    return cellW / (coverH + titleH);
  }

  void setViewport(WidgetTester tester, double width, double height) {
    tester.view.physicalSize = Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('竖屏 360dp：默认网格 3 列（间距 8，cell aspect 按封面宽动态）',
      (tester) async {
    setViewport(tester, 360, 800);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.mainAxisSpacing, equals(8));
    expect(delegate.crossAxisSpacing, equals(8));
    expect(delegate.childAspectRatio,
        closeTo(expectedCellAspectRatio(360), 1e-6));
  });

  testWidgets('横屏 900dp：默认网格 7 列（横屏独立配置）', (tester) async {
    setViewport(tester, 900, 400);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(7));
    expect(delegate.childAspectRatio,
        closeTo(expectedCellAspectRatio(900, columns: 7), 1e-6));
  });

  testWidgets('竖屏自定义 5 列 + 封面宽 60dp：cell aspect 按封面宽收缩',
      (tester) async {
    setViewport(tester, 360, 800);
    await pumpBookshelf(tester, MockRustApi(), prefs: {
      BookshelfSettings.keyBookshelfLayoutGridPortrait: 5,
      BookshelfSettings.keyBookshelfGridCoverWidth: 60,
    });

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(5));
    expect(
      delegate.childAspectRatio,
      closeTo(expectedCellAspectRatio(360,
          columns: 5, gridCoverWidth: 60), 1e-6),
    );
  });

  testWidgets('窗口尺寸变化 + 方向翻转后列数随横竖屏配置切换', (tester) async {
    setViewport(tester, 360, 800);
    await pumpBookshelf(tester, MockRustApi());
    expect(gridDelegate(tester).crossAxisCount, equals(3));

    tester.view.physicalSize = const Size(900 * 3, 400 * 3);
    await tester.pumpAndSettle();
    expect(gridDelegate(tester).crossAxisCount, equals(7));
  });
}
