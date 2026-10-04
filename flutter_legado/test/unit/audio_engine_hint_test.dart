// A4 无可用朗读引擎一次性提示测试（音频轨道 A4 批）
//
// 覆盖：
// 1) 无可用引擎进入朗读链 → errorMessage 温和提示（复用既有展示面，不新造 UI）
// 2) 一次性语义：同一次朗读会话内多段推进不重复刷提示
// 3) 用户配置引擎（engineUrl 非空）→ 提示自动清除
// 4) 无正文/未进入朗读链 → 不误报
// 5) startReadAloud（种子导入后仍无兼容引擎）路径同样提示
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    // 种子版本门控置 1：跳过种子导入（本文件不验证导入，避免噪声）
    SharedPreferences.setMockInitialValues({'httpTtsSeedVersion': 1});
    mockApi = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
      ],
    );
    addTearDown(container.dispose);
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  void stubChapter({String content = '第一段文本内容。\n\n第二段文本内容。'}) {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [const BookChapter(title: '第一章', index: 0)],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getChapterContentFull(any(), any()))
        .thenAnswer((_) async => content);
  }

  group('A4 无可用引擎提示', () {
    testWidgets('无引擎朗读：出现一次性提示且段落推进不重复刷', (tester) async {
      stubChapter();
      await readNotifier().loadChapters('url');

      var hintTransitions = 0;
      container.listen(audioNotifierProvider, (prev, next) {
        if (prev?.errorMessage != kNoUsableEngineHint &&
            next.errorMessage == kNoUsableEngineHint) {
          hintTransitions++;
        }
      });

      await readNotifier().play();
      expect(readState().errorMessage, kNoUsableEngineHint);
      expect(hintTransitions, 1);

      // 第一段完成 → 第二段（仍无引擎）：提示不得重复出现
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readNotifier().currentParagraphIndex, 1);
      expect(hintTransitions, 1);

      // 末段完成 → stop，提示仍为同一条
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readState().errorMessage, kNoUsableEngineHint);
      expect(hintTransitions, 1);
    });

    testWidgets('无正文不进入朗读链：不误报无引擎提示', (tester) async {
      stubChapter(content: '');
      await readNotifier().loadChapters('url');
      await readNotifier().play();
      expect(readState().errorMessage, isNull);
    });

    testWidgets('配置引擎后提示自动清除', (tester) async {
      stubChapter();
      await readNotifier().loadChapters('url');
      await readNotifier().play();
      expect(readState().errorMessage, kNoUsableEngineHint);

      readNotifier()
          .updateConfig(engineUrl: 'https://tts.example.com/{{text}}');
      expect(readState().errorMessage, isNull);
      // 取消估算推进定时器（用例结束无 pending timer）
      readNotifier().stop();
    });

    testWidgets('startReadAloud 无兼容引擎（种子列表为空）→ 提示出现', (tester) async {
      // 真实 AudioService.init 走平台通道，在 FakeAsync 下不会完成：本用例
      // 需注入 Mock（其余用例不 await 媒体会话初始化，不受影响）
      final audioService = MockAudioService();
      when(() => audioService.init()).thenAnswer((_) async {});
      when(() => audioService.isInitialized).thenReturn(false);
      when(() => audioService.mediaButtonStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => audioService.audioFocusStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => audioService.notifyStopped()).thenAnswer((_) async {});
      when(() => audioService.abandonAudioFocus()).thenAnswer((_) async {});
      when(() => audioService.dispose()).thenAnswer((_) async {});
      final localContainer = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(mockApi),
          streamAudioPlayerProvider.overrideWithValue(fakePlayer),
          audioServiceProvider.overrideWithValue(audioService),
        ],
      );
      addTearDown(localContainer.dispose);

      when(() => mockApi.getHttpTts()).thenAnswer((_) async => []);
      stubChapter();

      final notifier = localContainer.read(audioNotifierProvider.notifier);
      await notifier.startReadAloud(bookUrl: 'url', bookName: '测试书');

      expect(localContainer.read(audioNotifierProvider).state,
          PlayerState.playing);
      expect(localContainer.read(audioNotifierProvider).errorMessage,
          kNoUsableEngineHint);
      notifier.stop();
    });
  });
}
