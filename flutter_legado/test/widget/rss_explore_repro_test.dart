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

import '../mocks/mocks.dart';

/// 报障复现：订阅页（有数据）+ 发现页（有数据）真实渲染抓异常
///
/// 背景：用户报订阅页报错、发现页顶部文字看不清；logcat Dart 层无报错，
/// 需在测试环境复设有数据状态的渲染，确认有无 ErrorWidget/断言。
void main() {
  setUpAll(registerFallbacks);

  Widget wrap(Widget child, MockRustApi mockApi) {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
      child: MaterialApp(home: child),
    );
  }

  testWidgets('订阅页有数据渲染无异常', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getRssSources()).thenAnswer((_) async => const [
          RssSource(sourceUrl: 'u1', sourceName: '源一'),
          RssSource(sourceUrl: 'u2', sourceName: '源二', sourceGroup: '分组A'),
        ]);
    when(() => mockApi.importRssSources(any())).thenAnswer((_) async => 0);
    await tester.pumpWidget(wrap(const RssScreen(), mockApi));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('源一'), findsOneWidget);
    expect(find.text('源二'), findsOneWidget);
    expect(find.text('规则订阅'), findsOneWidget);
  });

  testWidgets('发现页有数据渲染无异常', (tester) async {
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
    await tester.pumpWidget(wrap(const ExploreScreen(), mockApi));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('书源一'), findsOneWidget);
    expect(find.text('书源二'), findsOneWidget);
    // L3 新增 FilterChip 横滑条
    expect(find.text('全部'), findsOneWidget);
  });
}
