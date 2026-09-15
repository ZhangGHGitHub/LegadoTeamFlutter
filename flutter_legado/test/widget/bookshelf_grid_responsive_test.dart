// [骨架对齐 2.0.260 | 台账 1-3] 书架网格固定 3 列（对齐参考 03b 有书态，
// [parity fix 2.0.264] 列数 2→3 修正：参考 03b 实为 3 列固定卡宽
// （卡宽≈屏宽 27%/列间距 20/左右边距 22），此前误读为 2 列）：
// 列数不再随窗口宽度分档（原 3/4/6 列响应式逻辑已按红线清理移除），
// 本套件验证任意宽度下均为 3 列、间距 20，且窗口尺寸变化后不变。
// [parity fix 2.0.264 补修] cell 宽高比不再锁 5/7：cell = 封面（5:7）+
// 书名行 40dp，aspect 随交叉轴宽动态计算（cellW/(cellW×7/5+40)），
// 固定 5/7 会把 Expanded 封面压成 ≈1:0.97 方形（复审指出）。
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

  /// 与 _bookshelfGridCellAspectRatio 同式（左右 padding 22×2、
  /// 列间距 20×2、cellW×7/5 封面 + 40 标题行）
  double expectedCellAspectRatio(double logicalWidth) {
    final cellW = (logicalWidth - 44 - 40) / 3;
    return cellW / (cellW * 7 / 5 + 40);
  }

  void setLogicalWidth(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width * 3, 900);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      '手机 360dp：书架网格固定 3 列（cell aspect 随宽动态/封面 5:7，间距 20，对齐参考 03b）',
      (tester) async {
    setLogicalWidth(tester, 360);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.mainAxisSpacing, equals(20));
    expect(delegate.crossAxisSpacing, equals(20));
    expect(delegate.childAspectRatio,
        closeTo(expectedCellAspectRatio(360), 1e-6));
  });

  testWidgets('平板 900dp：书架网格仍为 3 列（cell aspect 随宽动态）',
      (tester) async {
    setLogicalWidth(tester, 900);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio,
        closeTo(expectedCellAspectRatio(900), 1e-6));
  });

  testWidgets('桌面 1300dp：书架网格仍为 3 列（cell aspect 随宽动态）',
      (tester) async {
    setLogicalWidth(tester, 1300);
    await pumpBookshelf(tester, MockRustApi());

    final delegate = gridDelegate(tester);
    expect(delegate.crossAxisCount, equals(3));
    expect(delegate.childAspectRatio,
        closeTo(expectedCellAspectRatio(1300), 1e-6));
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
