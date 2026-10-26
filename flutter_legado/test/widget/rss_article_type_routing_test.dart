// RSS 阅读分流（type 1 图片 / type 0 网页）组件测试（批15f）
//
// 说明：桌面测试环境不支持 WebView（`_isWebViewSupported == false`），
// 因此 type 0 只断言进入详情页（正文降级纯文本）；type 2 视频播放依赖
// 原生播放器插件，不在单测覆盖（由 Rust 类型透传测试 + 代码审查兜底）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
  });

  Future<void> pumpOpener(
    WidgetTester tester, {
    required RssFeedArticle article,
    required RssSource source,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => openRssArticle(
                  context,
                  ref,
                  article: article,
                  source: source,
                  sourceName: source.sourceName,
                  sourceUrl: source.sourceUrl,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  testWidgets('type=1：打开全屏图片查看器（缩放容器）', (tester) async {
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '图源',
      rssType: 1,
    );
    await pumpOpener(
      tester,
      article: const RssFeedArticle(
        title: '图片文章',
        url: 'https://s.test/pic.jpg',
      ),
      source: source,
    );

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('保存图片'), findsOneWidget);
  });

  testWidgets('type=0：进入详情页（桌面降级纯文本）', (tester) async {
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '网页源',
    );
    await pumpOpener(
      tester,
      article: const RssFeedArticle(
        title: '网页文章',
        url: 'https://s.test/a',
        description: '<p>正文</p>',
      ),
      source: source,
    );
    await tester.pumpAndSettle();

    expect(find.byType(RssArticleDetailScreen), findsOneWidget);
    expect(find.text('网页文章'), findsWidgets);
  });
}
