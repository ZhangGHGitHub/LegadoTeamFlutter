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

import 'package:flutter_legado/src/constants/pref_keys.dart';
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

  /// 打开历史对话框并点击指定记录
  ///
  /// [settle] 为 false 时只推进固定帧：记录带封面图会触发
  /// `CachedNetworkImage` 持续动画，`pumpAndSettle` 会超时。
  Future<void> openHistoryAndTapFirstRecord(
    WidgetTester tester, {
    String title = '历史文章',
    bool settle = true,
  }) async {
    await tester.tap(find.byTooltip('阅读记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
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
          // 批20：扩展字段应透传到文章 DTO
          'type': 0,
          'sort': '科技',
          'image': '$origin/cover.jpg',
          'pubDate': '2026-10-27',
          'durPos': 12,
        },
      ],
    );

    await openHistoryAndTapFirstRecord(tester, settle: false);

    final detail = tester.widget<RssArticleDetailScreen>(
      find.byType(RssArticleDetailScreen),
    );
    expect(detail.sourceUrl, equals(origin));
    expect(detail.sourceName, equals('源A'));
    expect(detail.article.title, equals('历史文章'));
    expect(detail.article.url, equals('$origin/article/1'));
    expect(detail.article.sort, equals('科技'));
    expect(detail.article.imageUrl, equals('$origin/cover.jpg'));
    expect(detail.article.pubDate, equals('2026-10-27'));
    expect(detail.article.type, isZero);
  });

  testWidgets('历史记录 type=1：以记录 type 为准打开图片查看器（源 type 仅兜底）',
      (tester) async {
    final api = MockRustApi();
    await pumpRssScreen(
      tester,
      api,
      records: [
        {
          'origin': origin,
          'title': '历史图片',
          'link': '$origin/pic.jpg',
          'read_time': 1700000000000,
          // 源为网页源（rssType=0），记录 type=1 应优先
          'type': 1,
          'sort': '',
          'image': '$origin/pic.jpg',
          'pubDate': '2026-10-27',
          'durPos': 0,
        },
      ],
    );

    await openHistoryAndTapFirstRecord(tester, title: '历史图片', settle: false);

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('保存图片'), findsOneWidget);
    expect(find.byType(RssArticleDetailScreen), findsNothing);
  });

  testWidgets('全局阅读记录弹窗：记录开关默认开启，切换后持久化（批29）', (tester) async {
    final api = MockRustApi();
    await pumpRssScreen(tester, api, records: const []);

    await tester.tap(find.byTooltip('阅读记录'));
    await tester.pumpAndSettle();

    final switchTile = find.byType(SwitchListTile);
    expect(switchTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);

    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.enableRssReadRecord), isFalse);
  });

  testWidgets('全局清空确认框不显示条数（批29b 审查 P2-1）', (tester) async {
    final api = MockRustApi();
    // 全局列表只加载最近 100 条，而清空删的是全部记录 → 文案收敛为
    // 「确定清空全部阅读记录？」（改前「确定要删除？\nN 条阅读记录」会低报）
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

    await tester.tap(find.byTooltip('阅读记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清除'));
    await tester.pumpAndSettle();

    expect(find.text('确定清空全部阅读记录？'), findsOneWidget);
    expect(
      find.textContaining('条阅读记录'),
      findsNothing,
      reason: '全局清空确认框不得显示已加载条数',
    );

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
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
