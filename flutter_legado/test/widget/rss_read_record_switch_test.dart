// RSS 阅读记录全局开关（批29）Widget 测试
//
// 对齐原版 `AppConfig.enableRssReadRecord`（默认 true）：
// - 默认开启：列表打开文章写入已读记录；
// - 关闭：列表打开不写入（已有记录保留），重新开启后恢复写入；
// - 阅读记录弹窗：开关切换持久化（SharedPreferences）+ 清空当前源记录。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  const sourceUrl = 'https://s.test';

  Map<String, dynamic> article(String title, String link) => <String, dynamic>{
        'title': title,
        'link': link,
        'sort': '',
        'type': 0,
      };

  String pageJson(List<Map<String, dynamic>> articles) => jsonEncode({
        'articles': articles,
        'nextUrl': null,
        'hasMore': false,
      });

  void stubSource(MockRustApi api, RssSource source) {
    when(() => api.rssSortUrls(source.sourceUrl)).thenAnswer(
      (_) async => jsonEncode([
        const RssSort(name: '', url: sourceUrl).toJson(),
      ]),
    );
    when(
      () => api.rssRefreshArticles(sourceUrl, '', sourceUrl, key: null),
    ).thenAnswer((_) async => pageJson([article('列表文章', '$sourceUrl/a')]));
    when(() => api.getRssSources()).thenAnswer((_) async => [source]);
    when(() => api.isStarred(any())).thenAnswer((_) async => false);
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    MockRustApi api,
    RssSource source,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(home: RssArticlesScreen(source: source)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openArticle(
    WidgetTester tester,
    MockRustApi api,
    RssSource source,
  ) async {
    await pumpScreen(tester, api, source);
    await tester.tap(find.text('列表文章'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('默认开启：列表打开文章写入已读记录', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSource(api, source);
    when(
      () => api.rssMarkRead(
        sourceUrl,
        '列表文章',
        link: '$sourceUrl/a',
        type: 0,
        sort: '',
        image: null,
        pubDate: null,
        durPos: null,
      ),
    ).thenAnswer((_) async {});

    await openArticle(tester, api, source);

    verify(
      () => api.rssMarkRead(
        sourceUrl,
        '列表文章',
        link: '$sourceUrl/a',
        type: 0,
        sort: '',
        image: null,
        pubDate: null,
        durPos: null,
      ),
    ).called(1);
  });

  testWidgets('关闭开关：列表打开不写入；重新开启后恢复写入', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.enableRssReadRecord: false,
    });
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSource(api, source);
    when(
      () => api.rssMarkRead(
        any(),
        any(),
        link: any(named: 'link'),
        type: any(named: 'type'),
        sort: any(named: 'sort'),
        image: any(named: 'image'),
        pubDate: any(named: 'pubDate'),
        durPos: any(named: 'durPos'),
      ),
    ).thenAnswer((_) async {});
    when(() => api.rssListReadRecordsByOrigin(sourceUrl, null))
        .thenAnswer((_) async => <Map<String, dynamic>>[]);

    await openArticle(tester, api, source);
    // 关闭态：写入入口直接短路
    verifyNever(
      () => api.rssMarkRead(
        any(),
        any(),
        link: any(named: 'link'),
        type: any(named: 'type'),
        sort: any(named: 'sort'),
        image: any(named: 'image'),
        pubDate: any(named: 'pubDate'),
        durPos: any(named: 'durPos'),
      ),
    );

    // 返回列表，打开阅读记录弹窗重新开启开关
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读记录'));
    await tester.pumpAndSettle();
    final switchTile = find.byType(SwitchListTile);
    expect(switchTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    await tester.tap(switchTile);
    await tester.pumpAndSettle();

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('列表文章'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    verify(
      () => api.rssMarkRead(
        any(),
        any(),
        link: any(named: 'link'),
        type: any(named: 'type'),
        sort: any(named: 'sort'),
        image: any(named: 'image'),
        pubDate: any(named: 'pubDate'),
        durPos: any(named: 'durPos'),
      ),
    ).called(1);
  });

  testWidgets('阅读记录弹窗：开关切换持久化 + 清空当前源记录', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    const source = RssSource(sourceUrl: sourceUrl, sourceName: '源A');
    stubSource(api, source);
    var cleared = false;
    when(() => api.rssListReadRecordsByOrigin(sourceUrl, null)).thenAnswer(
      (_) async => cleared
          ? <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[
              {
                'origin': sourceUrl,
                'title': '历史文章',
                'link': '$sourceUrl/article/1',
                'read_time': 1700000000000,
              },
            ],
    );
    when(() => api.rssClearReadRecords(origin: any(named: 'origin')))
        .thenAnswer((_) async {
      cleared = true;
    });

    await pumpScreen(tester, api, source);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读记录'));
    await tester.pumpAndSettle();

    final switchTile = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);
    // 切换开关并持久化
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.enableRssReadRecord), isFalse);

    // 清空当前源：确认框 → 按 origin 调用清空 → 列表刷新为空
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前源的 1 条阅读记录'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();

    verify(() => api.rssClearReadRecords(origin: sourceUrl)).called(1);
    expect(find.text('历史文章'), findsNothing);
    expect(find.text('暂无阅读记录'), findsOneWidget);
  });
}
