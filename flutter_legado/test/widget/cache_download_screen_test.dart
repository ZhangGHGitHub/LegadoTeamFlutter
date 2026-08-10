import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/cache_download_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

/// 缓存下载队列页测试（[UI-fix v2.0.16 | 2026-08-10] 新增页 — Reasonix）
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
      ],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  testWidgets('缓存下载队列 无任务时显示空态', (tester) async {
    when(() => mockApi.cacheDownloadList())
        .thenAnswer((_) async => '[]');

    await tester.pumpWidget(wrap(const CacheDownloadScreen()));
    await tester.pump();

    expect(find.text('缓存下载队列'), findsOneWidget);
    expect(find.text('暂无缓存下载任务'), findsOneWidget);
  });

  testWidgets('缓存下载队列 渲染任务列表（状态/进度/取消按钮）', (tester) async {
    when(() => mockApi.cacheDownloadList()).thenAnswer((_) async =>
        '[{"taskId":1,"bookUrl":"https://example.com/book1","status":"running","total":10,"completed":4,"failed":0},'
        '{"taskId":2,"bookUrl":"https://example.com/book2","status":"completed","total":5,"completed":5,"failed":0}]');

    await tester.pumpWidget(wrap(const CacheDownloadScreen()));
    await tester.pump();

    expect(find.text('https://example.com/book1'), findsOneWidget);
    expect(find.text('https://example.com/book2'), findsOneWidget);
    expect(find.textContaining('下载中 · 4/10'), findsOneWidget);
    expect(find.textContaining('已完成 · 5/5'), findsOneWidget);
    // running 任务有取消按钮，completed 无
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
  });
}
