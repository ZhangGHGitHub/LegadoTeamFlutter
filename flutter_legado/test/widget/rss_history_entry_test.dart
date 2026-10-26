// RSS 历史记录入口 Widget 测试（批15d 任务 3）
//
// 对齐上游 `ReadRss.readRss(record)`：历史记录点开文章时需按 record.origin
// 取源（规则正文抓取/收藏 origin 都依赖它）。本用例锁定：
// - 详情页收到 origin（sourceUrl）与源名；
// - 无链接（legacy 键）时不传 origin（避免以空 link 发正文请求）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  const origin = 'https://s.test';

  setUp(() {
    // 跳过首启默认源导入：避免 rootBundle.loadString 的跨测试缓存 Future
    // 在 FakeAsync 新 Zone 中不完成（表现为加载指示器常驻）
    SharedPreferences.setMockInitialValues({kRssSourceVersionKey: 6});
  });

  Future<void> pumpRssScreen(
    WidgetTester tester,
    MockRustApi api, {
    required List<Map<String, dynamic>> records,
  }) async {
    when(() => api.getRssSources()).thenAnswer(
      (_) async => const [RssSource(sourceUrl: origin, sourceName: '源A')],
    );
    when(() => api.importRssSources(any())).thenAnswer((_) async => 0);
    when(() => api.rssListReadRecords(null)).thenAnswer((_) async => records);
    when(() => api.rssListReadRecordsByOrigin(origin, null))
        .thenAnswer((_) async => records);
    when(() => api.isStarred(any())).thenAnswer((_) async => false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: RssScreen()),
      ),
    );
    // 逐帧推进到源列表就绪（避免加载指示器无限动画导致 pumpAndSettle 超时）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> openHistoryAndTapFirstRecord(WidgetTester tester) async {
    await tester.tap(find.byTooltip('阅读记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史文章'));
    await tester.pumpAndSettle();
  }

  testWidgets('历史记录点开文章：详情页收到 origin 与源名', (tester) async {
    final api = MockRustApi();
    await pumpRssScreen(
      tester,
      api,
      records: [
        {
          'origin': origin,
          'title': '历史文章',
          'link': '$origin/article/1',
          'read_time': 1700000000000,
        },
      ],
    );

    await openHistoryAndTapFirstRecord(tester);

    final detail = tester.widget<RssArticleDetailScreen>(
      find.byType(RssArticleDetailScreen),
    );
    expect(detail.sourceUrl, equals(origin));
    expect(detail.sourceName, equals('源A'));
    expect(detail.article.title, equals('历史文章'));
    expect(detail.article.url, equals('$origin/article/1'));
  });

  testWidgets('历史记录无链接（真实 legacy 伪主键）：不传 origin', (tester) async {
    final api = MockRustApi();
    await pumpRssScreen(
      tester,
      api,
      records: [
        {
          'origin': origin,
          'title': '历史文章',
          // Rust 仓库层对空 link 落库的真实形态（E4 维持）
          'link': 'legacy:$origin:历史文章',
          'read_time': 1700000000000,
        },
      ],
    );

    await openHistoryAndTapFirstRecord(tester);

    final detail = tester.widget<RssArticleDetailScreen>(
      find.byType(RssArticleDetailScreen),
    );
    expect(detail.sourceUrl, isEmpty);
    expect(detail.article.url, isEmpty);
    // 无链接时不显示浏览器打开入口
    expect(find.text('在浏览器中查看原文'), findsNothing);
  });
}
