// 缺陷回归（设备验收 2026-11-11 批9B5C P2-1）：全局朗读语速被「跟随系统」覆盖
//
// 修复前链路：设置 → 朗读设置把语速改为 1.5x（prefs flutter.ttsSpeechRate=10），
// startReadAloud / initMediaSession 已把会话语速读回 1.5x；朗读条挂载后
// _loadFollowSystem 缺省 follow=true 并强制 updateConfig(speed: 1.0)，把会话
// 语速覆盖回 1.0x，听书页（同一 provider.config.speed）随之显示 1.0x。
//
// 本文件断言修复后语义：
// a) follow=true + prefs 1.5x → 有效语速 1.5x；未设置 prefs 才用引擎默认 1.0x；
// b) follow=false（手动）+ prefs 1.5x → 1.5x；
// c) 切换「跟随系统/手动」不重置语速；
// d) 手动调整语速落库，重建朗读条（冷启动等价）仍保持；
// e) 朗读条与听书页展示同一配置值（不得一处 1.5 一处 1.0）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';
import 'package:flutter_legado/src/services/system_tts_service.dart';
import 'package:flutter_legado/src/widgets/reader/read_aloud_bar.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  setUp(() {
    // 设置页「语速 1.5x」的持久化形态（参考刻度 10）
    SharedPreferences.setMockInitialValues({PrefKeys.ttsSpeechRate: 10});
    api = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
      ],
    );
    addTearDown(container.dispose);

    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(
      () => api.getChapters(any()),
    ).thenAnswer((_) async => [const BookChapter(title: '第一章', index: 0)]);
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  Widget barHost(ProviderContainer c) => UncontrolledProviderScope(
    container: c,
    child: Scaffold(
      body: Stack(
        children: [
          ReadAloudBar(
            onDismiss: () {},
            onOpenCatalog: () {},
            onBackstage: () {},
          ),
        ],
      ),
    ),
  );

  Future<void> pumpBar(
    WidgetTester tester, {
    ProviderContainer? withContainer,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: barHost(withContainer ?? container)),
    );
    await tester.pumpAndSettle();
  }

  Slider speedSlider(WidgetTester tester) =>
      tester.widget<Slider>(find.byType(Slider));

  group('朗读条「语速:跟随系统」不得覆盖用户语速', () {
    testWidgets('follow=true + prefs 1.5x → 配置/滑条/数值均 1.5x（修复前 1.0x）', (
      tester,
    ) async {
      await pumpBar(tester);

      expect(
        readState().config.speed,
        1.5,
        reason: '跟随系统应使用设置页显式设置过的语速，而不是强制 1.0',
      );
      expect(speedSlider(tester).value, 1.5);
      expect(find.text('1.5x'), findsOneWidget);
      expect(find.text('语速:跟随系统'), findsOneWidget);
    });

    testWidgets('follow=true + 未设置 prefs → 引擎默认 1.0x', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 会话内残留的非默认值（例如上一次手动调整）不得被当成用户设置
      readNotifier().updateConfig(speed: 2.0);

      await pumpBar(tester);

      expect(readState().config.speed, kEngineDefaultTtsSpeed);
      expect(speedSlider(tester).value, kEngineDefaultTtsSpeed);
    });

    testWidgets('follow=false（手动）+ prefs 1.5x → 1.5x', (tester) async {
      when(
        () => api.getConfig('ttsFollowSys'),
      ).thenAnswer((_) async => 'false');

      await pumpBar(tester);

      expect(readState().config.speed, 1.5);
      expect(speedSlider(tester).value, 1.5);
      expect(find.text('语速:手动'), findsOneWidget);
    });

    testWidgets('切换「跟随系统/手动」不把语速重置为 1.0', (tester) async {
      await pumpBar(tester);
      expect(readState().config.speed, 1.5);

      // 跟随系统 → 手动：保持 1.5
      await tester.tap(find.text('语速:跟随系统'));
      await tester.pumpAndSettle();
      expect(readState().config.speed, 1.5, reason: '切到手动不得重置语速');
      expect(find.text('语速:手动'), findsOneWidget);
      verify(() => api.setConfig('ttsFollowSys', 'false')).called(1);

      // 手动 → 跟随系统：仍为设置页语速 1.5（修复前回落到 1.0）
      await tester.tap(find.text('语速:手动'));
      await tester.pumpAndSettle();
      expect(readState().config.speed, 1.5, reason: '切回跟随系统应为用户语速');
      expect(find.text('语速:跟随系统'), findsOneWidget);
    });

    testWidgets('手动调整语速落库，重建朗读条（冷启动等价）保持 2.0x', (tester) async {
      when(
        () => api.getConfig('ttsFollowSys'),
      ).thenAnswer((_) async => 'false');
      await pumpBar(tester);

      final slider = speedSlider(tester);
      slider.onChanged!(2.0);
      slider.onChangeEnd?.call(2.0);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(PrefKeys.ttsSpeechRate),
        ttsSpeechRateFromSpeed(2.0),
        reason: '手动语速应落库，冷启动/停止重播才能保持',
      );

      // 冷启动等价：先卸载旧朗读条（销毁 State），再用全新容器挂载
      await tester.pumpWidget(const SizedBox());
      final restarted = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          streamAudioPlayerProvider.overrideWithValue(FakeStreamAudioPlayer()),
        ],
      );
      addTearDown(restarted.dispose);
      await pumpBar(tester, withContainer: restarted);
      expect(restarted.read(audioNotifierProvider).config.speed, 2.0);
    });
  });

  group('朗读条与听书页同源显示', () {
    testWidgets('会话读回 1.5x → 朗读条 1.5x → 听书页面板 1.5x（修复前 1.0x）', (tester) async {
      // 会话入口读回设置页语速（startReadAloud / initMediaSession 链路结果）
      readNotifier().updateConfig(speed: 1.5);
      expect(readState().config.speed, 1.5);

      await pumpBar(tester);
      expect(readState().config.speed, 1.5, reason: '朗读条挂载后不得覆盖会话读回的语速');

      // 听书页展示 provider.config.speed（TTS 书，非流媒体）。
      // 画布需足够高，避免设置面板与章节列表在 800x600 下溢出。
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AudioScreen(
              book: Book(bookUrl: 'url', name: '测试书'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('1.5x'), findsOneWidget);
      expect(find.text('1.0x'), findsNothing);
    });
  });
}
