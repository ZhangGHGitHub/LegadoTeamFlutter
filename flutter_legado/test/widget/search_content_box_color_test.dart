// [PARITY A6 | ⑦b 已裁决 2026-09-21] 正文搜索输入盒配色回归测试
//
// 裁决依据：docs/parity_shots/ref_dark_20260921/RECAPTURE_20260921.md §3
// 「项三 A6 搜索输入盒」——参考版 composeEngine=material 已确认，SearchBar
// 填充槽 = surfaceContainerLow（透明板深色 = 0x00FFFFFF 全透明透现，
// 标准板 12 板 dark sCL 均为深色）。据此：
//   - 输入盒 backgroundColor 统一取 surfaceContainerLow（删除在途的
//     深色态 onSurface 分支）；
//   - 深色态 hint 与 leading 图标 = onSurface（参考 hint 实测 #EDE6FF
//     = 透明板 dark onSurface 角色）；亮色态维持框架默认（hint 走
//     onSurfaceVariant 派生、图标 onSurfaceVariant）。
//
// 断言策略：用可辨识的哨兵色覆写 ColorScheme.surfaceContainerLow，
// 断言 SearchBar 实际取色 == 哨兵色（即取色来自 sCL 槽），
// 与具体调色板数值解耦；装配模式复用 screens_overflow_regress_test。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/search_content_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

import '../mocks/mocks.dart';

void main() {
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
    );
    addTearDown(container.dispose);
  });

  /// 以 M3 生成 scheme 为底、仅把 surfaceContainerLow 覆写为 [scl]
  /// 哨兵色：断言命中哨兵即证明输入盒取色来自 sCL 槽
  ThemeData themeWithScl(Brightness brightness, Color scl) {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4A5A6A),
      brightness: brightness,
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: base.copyWith(surfaceContainerLow: scl),
    );
  }

  Future<void> pumpScreen(WidgetTester tester, ThemeData theme) async {
    // 对齐 MuMu Test 实例：1080 物理宽 @ dpr3 = 360dp 逻辑宽
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: const SearchContentScreen(bookUrl: 'u', bookName: 'book'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('深色态：输入盒填充 = sCL 槽，hint/leading 图标 = onSurface',
      (tester) async {
    const sentinel = Color(0xFF010203);
    final theme = themeWithScl(Brightness.dark, sentinel);
    await pumpScreen(tester, theme);
    expect(tester.takeException(), isNull);

    final bar = tester.widget<SearchBar>(find.byType(SearchBar));
    // 填充槽 = sCL（哨兵命中即证明取色自 surfaceContainerLow 而非
    // onSurface/其它槽位）
    expect(bar.backgroundColor!.resolve(const {}), sentinel);
    // 深色态 hint = onSurface（参考 hint 实测 #EDE6FF 角色）
    expect(bar.hintStyle!.resolve(const {})!.color,
        theme.colorScheme.onSurface);
    // 深色态 leading 搜索图标 = onSurface
    final icon = tester.widget<Icon>(find.byIcon(Symbols.search_rounded));
    expect(icon.color, theme.colorScheme.onSurface);
  });

  testWidgets('亮色态：输入盒填充 = sCL 槽（原行为不变），hint 维持框架默认',
      (tester) async {
    const sentinel = Color(0xFF030201);
    final theme = themeWithScl(Brightness.light, sentinel);
    await pumpScreen(tester, theme);
    expect(tester.takeException(), isNull);

    final bar = tester.widget<SearchBar>(find.byType(SearchBar));
    // 亮色填充同样取 sCL 槽（原行为：surfaceContainerLow 不变）
    expect(bar.backgroundColor!.resolve(const {}), sentinel);
    // 亮色 hint 解析为 null（源码传 WidgetStatePropertyAll(null)，
    // 即未指定样式 = 框架 onSurfaceVariant 派生默认）
    expect(bar.hintStyle!.resolve(const {}), isNull);
    // 亮色 leading 图标维持 onSurfaceVariant（框架默认）
    final icon = tester.widget<Icon>(find.byIcon(Symbols.search_rounded));
    expect(icon.color, theme.colorScheme.onSurfaceVariant);
  });
}
