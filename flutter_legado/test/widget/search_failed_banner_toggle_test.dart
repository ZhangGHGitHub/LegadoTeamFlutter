// 失败横幅展开/收起与结果可见性回归（2026-09-26 真机验收实测）
//
// 用户实测（2.0.311）：搜索完成结果可见后，点开失败横幅（展开）结果在
// 下方可见；点击收起后**结果消失**——展开/收起两个 build 之间结果区被
// 输入帮助层（或空态）顶掉。本测试复现该序列并锁定回归：横幅任意
// 展开态下，完成态结果必须始终可见。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/search/search_notifier.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
        .thenAnswer((_) async => []);
    when(() => mockApi.addSearchKeyword(any(), any()))
        .thenAnswer((_) async {});
    when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
    when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.getEnabledBookSources()).thenAnswer((_) async => []);
    // 错误批次路径先 appLogPush 再记账——不打桩回调会在记账前抛异常
    when(() => mockApi.appLogPush(
            level: any(named: 'level'), message: any(named: 'message')))
        .thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  Map<String, dynamic> makeBatch(List<Map<String, dynamic>> books,
          {bool isLast = false, String? error, String name = '笔趣阁'}) =>
      {
        'source_index': 0,
        'source_url': 'https://a.com',
        'source_name': name,
        'books': books,
        'error': error,
        'finished_count': 1,
        'total_count': 1,
        'is_last': isLast,
      };

  List<Map<String, dynamic>> makeBooks(int count, {String prefix = '书'}) =>
      List.generate(
          count,
          (i) => {
                'origin': 'https://a.com',
                'originName': '笔趣阁',
                'name': '$prefix ${i + 1}',
                'author': '作者$i',
                'bookUrl': 'https://a.com/b/$i',
              });

  testWidgets('失败横幅展开→收起全程结果可见（回归：收起后结果消失）',
      (tester) async {
    final events = StreamController<Map<String, dynamic>>();
    when(() => mockApi.searchMultiStream(any(),
            sourceUrls: any(named: 'sourceUrls'), page: any(named: 'page')))
        .thenAnswer((_) => events.stream);

    await tester.pumpWidget(wrap(SearchScreen(initialQuery: '重生高考前99天')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 成功批次（20 条结果）+ 失败批次（横幅来源）+ 收尾
    events.add(makeBatch(makeBooks(20)));
    await tester.pump(const Duration(milliseconds: 400));
    // 两条失败（≥2 走「N 个书源搜索失败」计数文案；单条为单数文案）
    events.add(makeBatch(const [], error: 'Timeout: Request timeout', name: '坏源一'));
    events.add(makeBatch(const [],
        isLast: true, error: 'Login required: 需要登录', name: '坏源二'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 完成态：结果可见
    expect(find.text('书 1'), findsOneWidget,
        reason: '搜索完成后结果必须可见');
    // ignore: avoid_print
    print('DBG failedSources=${container.read(searchNotifierProvider).failedSources} isLoading=${container.read(searchNotifierProvider).isLoading}');

    // 展开失败横幅
    final banner = find.textContaining('个书源搜索失败');
    expect(banner, findsOneWidget, reason: '失败横幅应存在');
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.text('书 1'), findsOneWidget,
        reason: '横幅展开后结果仍须可见（用户实测：展开时结果在下方可见）');

    // 收起失败横幅 —— 用户实测回归点：收起后结果消失
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.text('书 1'), findsOneWidget,
        reason: '横幅收起后结果必须仍可见（用户实测：收起后结果消失）');

    events.close();
  });
}
