// 回归守卫：debug 模式 RenderFlex 右溢（台账 P2-13 ②，设备 crash_log 右溢 12px）。
// 约定：360dp 画布（1080x1920 @ 3.0），MockBookApi + MockAudioService 覆写，
// 逐屏 pump 后断言无布局溢出异常（takeException == null）。
// 历史根因：home_tab_screen 统计卡内部 Row、browser_screen 卡片头 Row 的
// 文本未约束宽度（无 Flexible + ellipsis），内容变宽时右溢。
// 覆盖扩展（MuMu 冒烟 12px 右溢残留定位）：主屏幕 + 阅读器菜单类浮层 +
// 设置各页 + 搜索/换源/书源编辑/订阅/统计等。
// 排除（红线/已登记例外）：
//   - reader_screen.dart 与排版相关文件（承重区，命中先报告再改）
//   - reader_comic_screen / video_screen / 翻页自绘黑底体系（已登记例外）
//   - webview_login_screen（WebViewController 自绘登录浮层，平台通道依赖）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/models/rss_article.dart';
import 'package:flutter_legado/src/models/rss_source.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/screens/about_screen.dart';
import 'package:flutter_legado/src/screens/app_log_screen.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';
import 'package:flutter_legado/src/screens/auto_task_screen.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/screens/bookmark_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_manage_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/bottom_bar_skin_assign_screen.dart';
import 'package:flutter_legado/src/screens/bottom_bar_skin_screen.dart';
import 'package:flutter_legado/src/screens/browser_screen.dart';
import 'package:flutter_legado/src/screens/cache_download_screen.dart';
import 'package:flutter_legado/src/screens/cache_settings_screen.dart';
import 'package:flutter_legado/src/screens/change_cover_screen.dart';
import 'package:flutter_legado/src/screens/change_source_screen.dart';
import 'package:flutter_legado/src/screens/code_edit_screen.dart';
import 'package:flutter_legado/src/screens/dict_rule_screen.dart';
import 'package:flutter_legado/src/screens/dict_screen.dart';
import 'package:flutter_legado/src/screens/edit_book_info_screen.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';
import 'package:flutter_legado/src/screens/explore_show_screen.dart';
import 'package:flutter_legado/src/screens/file_manage_screen.dart';
import 'package:flutter_legado/src/screens/font_screen.dart';
import 'package:flutter_legado/src/screens/highlight_rules_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/home_tab_screen.dart';
import 'package:flutter_legado/src/screens/import_screen.dart';
import 'package:flutter_legado/src/screens/js_source_edit_screen.dart';
import 'package:flutter_legado/src/screens/offline_cache_screen.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/qrcode_screen.dart';
import 'package:flutter_legado/src/screens/read_aloud_config_screen.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/remote_book_screen.dart';
import 'package:flutter_legado/src/screens/replace_rules_screen.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';
import 'package:flutter_legado/src/screens/rss_favorites_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/screens/rss_source_debug_screen.dart';
import 'package:flutter_legado/src/screens/rss_source_edit_screen.dart';
import 'package:flutter_legado/src/screens/rss_source_manage_screen.dart';
import 'package:flutter_legado/src/screens/rule_sub_screen.dart';
import 'package:flutter_legado/src/screens/search_content_screen.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/source_debug_screen.dart';
import 'package:flutter_legado/src/screens/source_edit_screen.dart';
import 'package:flutter_legado/src/screens/source_login_screen.dart';
import 'package:flutter_legado/src/screens/source_screen.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';
import 'package:flutter_legado/src/screens/txt_toc_rules_screen.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/screens/welcome_config_screen.dart';
import 'package:flutter_legado/src/screens/welcome_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockBookApi api;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
    final mockAudio = MockAudioService();
    when(() => mockAudio.init()).thenAnswer((_) async {});
    when(() => mockAudio.isInitialized).thenReturn(false);
    when(() => mockAudio.dispose()).thenAnswer((_) async {});
    when(() => mockAudio.mediaButtonStream)
        .thenAnswer((_) => const Stream<MediaButtonEvent>.empty());
    when(() => mockAudio.audioFocusStream)
        .thenAnswer((_) => const Stream<AudioFocusEvent>.empty());
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        audioServiceProvider.overrideWithValue(mockAudio),
      ],
    );
    addTearDown(container.dispose);
  });

  /// 360dp 画布（1080x1920 @ 3.0）下 pump 屏幕并等待异步就绪
  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 扫描屏幕清单：（屏幕名, 360dp 画布下的 fixture）。
  /// 分组：主屏幕 → 设置各页/其它 → 搜索/换源/书源编辑/订阅/统计 → 阅读器菜单浮层。
  final screens = <(String, Widget)>[
    // ===== 主屏幕 =====
    ('HomeTabScreen', const HomeTabScreen()),
    (
      'BrowserScreen',
      const BrowserScreen(initialUrl: 'https://example.com'),
    ),
    ('BookshelfScreen', const BookshelfScreen()),
    ('SearchScreen', const SearchScreen()),
    ('SourceScreen', const SourceScreen()),
    ('ReadRecordScreen', const ReadRecordScreen()),
    (
      'ChangeSourceScreen',
      const ChangeSourceScreen(bookUrl: 'u'),
    ),
    ('WelcomeScreen', const WelcomeScreen()),
    ('AudioScreen', const AudioScreen()),
    ('BookshelfManageScreen', const BookshelfManageScreen()),
    ('RssScreen', const RssScreen()),
    ('DictScreen', const DictScreen()),
    ('ExploreScreen', const ExploreScreen()),
    ('HomeScreen', const HomeScreen()),
    // ===== 设置各页 / 其它 =====
    ('SettingsScreen', const SettingsScreen()),
    ('SettingsHomeScreen', const SettingsHomeScreen()),
    ('AboutScreen', const AboutScreen()),
    ('AppLogScreen', const AppLogScreen()),
    ('AutoTaskScreen', const AutoTaskScreen()),
    ('BookGroupScreen', const BookGroupScreen()),
    ('BookInfoScreen', const BookInfoScreen(bookUrl: 'u')),
    ('BookmarkScreen', const BookmarkScreen()),
    ('BottomBarSkinScreen', const BottomBarSkinScreen()),
    (
      'BottomBarSkinAssignScreen',
      const BottomBarSkinAssignScreen(sessionId: 's', preferredName: 'p'),
    ),
    ('CacheDownloadScreen', const CacheDownloadScreen()),
    ('CacheSettingsScreen', const CacheSettingsScreen()),
    (
      'ChangeCoverScreen',
      const ChangeCoverScreen(bookUrl: 'u', bookName: 'book'),
    ),
    ('CodeEditScreen', const CodeEditScreen(title: 't', initialText: '')),
    ('DictRuleScreen', const DictRuleScreen()),
    ('EditBookInfoScreen', EditBookInfoScreen(book: Book(bookUrl: 'u', name: 'x'))),
    ('ExploreShowScreen', const ExploreShowScreen()),
    ('FileManageScreen', const FileManageScreen()),
    ('FontScreen', const FontScreen()),
    ('HighlightRulesScreen', const HighlightRulesScreen()),
    ('ImportScreen', const ImportScreen()),
    ('OfflineCacheScreen', const OfflineCacheScreen()),
    ('OtherSettingsScreen', const OtherSettingsScreen()),
    ('QrcodeScreen', const QrcodeScreen()),
    ('ReadAloudConfigScreen', const ReadAloudConfigScreen()),
    ('RemoteBookScreen', const RemoteBookScreen()),
    ('ReplaceRulesScreen', const ReplaceRulesScreen()),
    ('RuleSubScreen', const RuleSubScreen()),
    ('ThemeConfigScreen', const ThemeConfigScreen()),
    ('TxtTocRulesScreen', const TxtTocRulesScreen()),
    ('WebDavSettingsScreen', const WebDavSettingsScreen()),
    ('WelcomeConfigScreen', const WelcomeConfigScreen()),
    // ===== 搜索 / 换源 / 书源编辑 / 订阅 / 统计 =====
    (
      'SearchContentScreen',
      const SearchContentScreen(bookUrl: 'u', bookName: 'book'),
    ),
    ('SourceEditScreen', const SourceEditScreen(sourceUrl: 'u')),
    ('JsSourceEditScreen', const JsSourceEditScreen(sourceUrl: 'u')),
    ('SourceDebugScreen', const SourceDebugScreen(sourceUrl: 'u')),
    (
      'SourceLoginScreen',
      const SourceLoginScreen(sourceUrl: 'u', sourceName: 'n'),
    ),
    ('RssSourceManageScreen', const RssSourceManageScreen()),
    ('RssSourceEditScreen', const RssSourceEditScreen()),
    ('RssSourceDebugScreen', const RssSourceDebugScreen(sourceUrl: 'u')),
    (
      'RssArticlesScreen',
      const RssArticlesScreen(
        source: RssSource(sourceUrl: 'u', sourceName: 'rss'),
      ),
    ),
    (
      'RssArticleDetailScreen',
      const RssArticleDetailScreen(
        article: RssFeedArticle(title: 't', url: 'u'),
        sourceName: 'rss',
        sourceUrl: 'u',
      ),
    ),
    ('RssFavoritesScreen', const RssFavoritesScreen()),
    ('TocScreen', TocScreen(book: Book(bookUrl: 'u', name: 'x'))),
    // ===== 阅读器菜单类浮层（红线：命中先报告再改）=====
    // 红线核查结论（2026-09-20）：面板在应用内恒经 ReaderConfigPanel.show →
    // showModalBottomSheet(isScrollControlled) + DraggableScrollableSheet
    // (maxChildSize: 0.92) + SingleChildScrollView 呈现（高度受限可滚动），
    // 无界高度直接 pump 产生的"底部溢出"是 fixture 假象而非实机溢出。
    // 故 fixture 按真实呈现形态模拟为「限高 588dp(=0.92*640dp) + 可滚动」，
    // 守卫继续验证其 360dp 横向溢出；面板源码（承重区）本次不改。
    (
      'ReaderConfigPanel',
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 588),
        child: SingleChildScrollView(
          child: ReaderConfigPanel(config: ReaderAdvancedConfig()),
        ),
      ),
    ),
  ];

  for (final (name, screen) in screens) {
    testWidgets('$name 360dp 无 RenderFlex 溢出', (tester) async {
      await pumpScreen(tester, screen);
      expect(tester.takeException(), isNull, reason: '$name 溢出');
    });
  }
}
