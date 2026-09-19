// 回归守卫：debug 模式 RenderFlex 右溢（台账 P2-13 ②，设备 crash_log 右溢 12px）。
// 约定：360dp 画布（1080x1920 @ 3.0），MockBookApi + MockAudioService 覆写，
// 逐屏 pump 后断言无布局溢出异常（takeException == null）。
// 历史根因：home_tab_screen 统计卡内部 Row、browser_screen 卡片头 Row 的
// 文本未约束宽度（无 Flexible + ellipsis），内容变宽时右溢。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_manage_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/browser_screen.dart';
import 'package:flutter_legado/src/screens/change_source_screen.dart';
import 'package:flutter_legado/src/screens/dict_screen.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';
import 'package:flutter_legado/src/screens/home_tab_screen.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';
import 'package:flutter_legado/src/screens/source_screen.dart';
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

  testWidgets('HomeTabScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const HomeTabScreen());
    expect(tester.takeException(), isNull, reason: 'HomeTabScreen 溢出');
  });

  testWidgets('BrowserScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(
        tester, const BrowserScreen(initialUrl: 'https://example.com'));
    expect(tester.takeException(), isNull, reason: 'BrowserScreen 溢出');
  });

  testWidgets('BookshelfScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const BookshelfScreen());
    expect(tester.takeException(), isNull, reason: 'BookshelfScreen 溢出');
  });

  testWidgets('SearchScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const SearchScreen());
    expect(tester.takeException(), isNull, reason: 'SearchScreen 溢出');
  });

  testWidgets('SourceScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const SourceScreen());
    expect(tester.takeException(), isNull, reason: 'SourceScreen 溢出');
  });

  testWidgets('ReadRecordScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const ReadRecordScreen());
    expect(tester.takeException(), isNull, reason: 'ReadRecordScreen 溢出');
  });

  testWidgets('ChangeSourceScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const ChangeSourceScreen(bookUrl: 'u'));
    expect(tester.takeException(), isNull, reason: 'ChangeSourceScreen 溢出');
  });

  testWidgets('WelcomeScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const WelcomeScreen());
    expect(tester.takeException(), isNull, reason: 'WelcomeScreen 溢出');
  });

  testWidgets('AudioScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const AudioScreen());
    expect(tester.takeException(), isNull, reason: 'AudioScreen 溢出');
  });

  testWidgets('BookshelfManageScreen 360dp 无 RenderFlex 溢出',
      (tester) async {
    await pumpScreen(tester, const BookshelfManageScreen());
    expect(tester.takeException(), isNull,
        reason: 'BookshelfManageScreen 溢出');
  });

  testWidgets('RssScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const RssScreen());
    expect(tester.takeException(), isNull, reason: 'RssScreen 溢出');
  });

  testWidgets('DictScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const DictScreen());
    expect(tester.takeException(), isNull, reason: 'DictScreen 溢出');
  });

  testWidgets('ExploreScreen 360dp 无 RenderFlex 溢出', (tester) async {
    await pumpScreen(tester, const ExploreScreen());
    expect(tester.takeException(), isNull, reason: 'ExploreScreen 溢出');
  });
}
