import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';

import '../mocks/mocks.dart';

/// 对比度审计：订阅页 + 发现页在真实 AppTheme 下渲染，
/// 逐个 Text 计算与背景的对比度，低对比即失败。
///
/// 回归背景：暗色下发现页顶部 FilterChip（“全部”）曾因 chipTheme
/// 未声明 label 色回退黑色，对比度仅 1.1（FIX 2026-09-04）。
void main() {
  setUpAll(registerFallbacks);

  double ratio(Color fg, Color bg) {
    final l1 = fg.computeLuminance();
    final l2 = bg.computeLuminance();
    final hi = l1 > l2 ? l1 : l2;
    final lo = l1 > l2 ? l2 : l1;
    return (hi + 0.05) / (lo + 0.05);
  }

  void audit(String page, WidgetTester tester) {
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    final bg = theme.scaffoldBackgroundColor;
    final found = find.byType(Text);
    var bad = 0;
    for (final el in found.evaluate()) {
      final w = el.widget as Text;
      final content = w.data ?? w.textSpan?.toPlainText() ?? '';
      if (content.trim().isEmpty) continue;
      final def = DefaultTextStyle.of(el);
      var fg = w.style?.color ?? def.style.color ?? Colors.black;
      fg = Color.alphaBlend(fg, bg);
      final size = w.style?.fontSize ?? def.style.fontSize ?? 14;
      final weight =
          w.style?.fontWeight ?? def.style.fontWeight ?? FontWeight.w400;
      final large = size >= 18 ||
          (size >= 14 && (weight == FontWeight.w700 ||
              weight == FontWeight.w800 ||
              weight == FontWeight.w900 ||
              weight == FontWeight.bold));
      final threshold = large ? 3.0 : 4.5;
      final r = ratio(fg, bg);
      if (r < threshold) {
        bad++;
        debugPrint(
            'LOW-CONTRAST [$page] "$content" fg=$fg size=$size ratio=${r.toStringAsFixed(2)} < $threshold');
      }
    }
    debugPrint('AUDIT-DONE [$page] texts=${found.evaluate().length} low=$bad');
    expect(bad, 0, reason: '[$page] 有 $bad 处文字对比度不达标，见上方 LOW-CONTRAST');
  }

  testWidgets('订阅页有数据亮色对比度审计', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getRssSources()).thenAnswer((_) async => const [
          RssSource(sourceUrl: 'u1', sourceName: '测试源一'),
          RssSource(sourceUrl: 'u2', sourceName: '测试源二', sourceGroup: '分组A'),
        ]);
    when(() => mockApi.importRssSources(any())).thenAnswer((_) async => 0);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(theme: AppTheme.light, home: const RssScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ErrorWidget), findsNothing);
    audit('rss-light', tester);
  });

  testWidgets('发现页有数据亮色对比度审计', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const [
          BookSource(
              bookSourceUrl: 'u1',
              bookSourceName: '书源一',
              enabledExplore: true,
              exploreUrl: 'https://a.test/x'),
          BookSource(
              bookSourceUrl: 'u2',
              bookSourceName: '书源二',
              bookSourceGroup: '分组A',
              enabledExplore: true,
              exploreUrl: 'https://b.test/y'),
        ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(theme: AppTheme.light, home: const ExploreScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ErrorWidget), findsNothing);
    audit('explore-light', tester);
  });

  testWidgets('订阅页有数据暗色对比度审计', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getRssSources()).thenAnswer((_) async => const [
          RssSource(sourceUrl: 'u1', sourceName: '测试源一'),
        ]);
    when(() => mockApi.importRssSources(any())).thenAnswer((_) async => 0);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(theme: AppTheme.dark, home: const RssScreen()),
      ),
    );
    // 暗色有常驻动画时 pumpAndSettle 超时，改 pump 固定时长
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(ErrorWidget), findsNothing);
    audit('rss-dark', tester);
  });

  testWidgets('发现页有数据暗色对比度审计', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const [
          BookSource(
              bookSourceUrl: 'u1',
              bookSourceName: '书源一',
              enabledExplore: true,
              exploreUrl: 'https://a.test/x'),
        ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child:
            MaterialApp(theme: AppTheme.dark, home: const ExploreScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ErrorWidget), findsNothing);
    audit('explore-dark', tester);
  });
}
