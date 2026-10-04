// P0 缺陷回归：在线书 TTS 朗读合成文本为章节 URL JSON 元数据（2026-10-03）
//
// 根因：在线书走 BookApi.getChapterContent（Rust get_chapter_content 在线分支）
// 只返回 {chapter_url, base_url, title, need_fetch:true} 占位 JSON，AudioNotifier
// 把它当正文段落送进 audioSpeak——合成的是 JSON 而非正文。修复：朗读消费端
// 对在线书改走 getChapterContentFull（DB 缓存 → 联网抓取 → 净化，始终纯正文，
// FFI 契约与实现均不变）；本地书保持 getChapterContent（Rust full 的本地分支
// 不做「相对可迁移标识 → 真实路径」还原，行为不完全一致，不切换）。
//
// 覆盖：
// 1) 在线书：送进合成的 text 是纯正文，不含 chapter_url/need_fetch 等 JSON 键；
//    不触发 getChapterContent，章节缓存写回纯正文。
// 2) 本地书（.epub 等扩展名）：维持 getChapterContent 链路，不触发 full。
// 3) 在线抓取失败：error 态 + errorMessage 用户可见提示（不静默）。
// 4) 并发/竞态：同一章在途抓取去重（只联网一次）；快速切章后旧章迟到结果
//    不进入新章朗读、只写回自己章号缓存。
// 5) 选段朗读：startParagraphText 在纯正文上能命中对应段落起播。
import 'dart:async';

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

  /// audioSpeak 入参 text 记录（每用例清空）
  final speakTexts = <String>[];

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'httpTtsSeedVersion': 1});
    mockApi = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    speakTexts.clear();
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

  void stubChapters() {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: '第一章', index: 0),
        const BookChapter(title: '第二章', index: 1),
      ],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
  }

  void stubAudioSpeak() {
    when(() => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        )).thenAnswer((invocation) async {
      speakTexts.add(invocation.namedArguments[#text] as String);
      return '/tmp/tts/para_${speakTexts.length}.mp3';
    });
  }

  const onlineBookUrl = 'https://example.com/book/12345';
  const engineUrl = 'https://tts.example.com/?text={{text}}';

  group('在线书朗读取纯正文（P0）', () {
    testWidgets('在线书：送合成的是纯正文，不读 URL JSON、不触发旧链路', (tester) async {
      stubChapters();
      stubAudioSpeak();
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((_) async => '第一段正文内容。\n\n第二段正文内容。');

      await readNotifier().loadChapters(onlineBookUrl);
      readNotifier().updateConfig(engineUrl: engineUrl);
      await readNotifier().play();

      expect(speakTexts, ['第一段正文内容。']);
      for (final text in speakTexts) {
        expect(text, isNot(contains('chapter_url')));
        expect(text, isNot(contains('need_fetch')));
        expect(text, isNot(contains('base_url')));
      }
      // 章节缓存写回的是纯正文
      expect(readState().chapters[0].text, '第一段正文内容。\n\n第二段正文内容。');
      verify(() => mockApi.getChapterContentFull(onlineBookUrl, 0)).called(1);
      verifyNever(() => mockApi.getChapterContent(any(), any()));

      readNotifier().stop();
    });

    testWidgets('本地书：维持 getChapterContent 链路（行为不变）', (tester) async {
      stubChapters();
      stubAudioSpeak();
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '本地正文甲。\n\n本地正文乙。');

      await readNotifier().loadChapters('books/demo.epub');
      readNotifier().updateConfig(engineUrl: engineUrl);
      await readNotifier().play();

      expect(speakTexts, ['本地正文甲。']);
      verify(() => mockApi.getChapterContent('books/demo.epub', 0)).called(1);
      verifyNever(() => mockApi.getChapterContentFull(any(), any()));

      readNotifier().stop();
    });

    testWidgets('在线抓取失败：error 态 + 用户可见提示（不静默）', (tester) async {
      stubChapters();
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenThrow(Exception('网络连接超时'));

      await readNotifier().loadChapters(onlineBookUrl);
      await readNotifier().play();

      expect(readState().state, PlayerState.error);
      expect(readState().errorMessage, contains('章节正文获取失败'));
      expect(readState().errorMessage, contains('网络连接超时'));

      readNotifier().stop();
    });
  });

  group('并发与竞态（P0 附带防重入）', () {
    testWidgets('同一章快速连点：在途抓取去重，只联网一次', (tester) async {
      stubChapters();
      stubAudioSpeak();
      final gate = Completer<String>();
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((_) => gate.future);

      await readNotifier().loadChapters(onlineBookUrl);
      readNotifier().updateConfig(engineUrl: engineUrl);
      final first = readNotifier().play();
      final second = readNotifier().play();

      gate.complete('并发去重正文。');
      await tester.pump();
      await first;
      await second;

      verify(() => mockApi.getChapterContentFull(onlineBookUrl, 0)).called(1);
      expect(speakTexts, ['并发去重正文。']);

      readNotifier().stop();
    });

    testWidgets('快速切章：旧章迟到结果不进入新章朗读、只写回自己章号缓存', (tester) async {
      stubChapters();
      stubAudioSpeak();
      final ch0Gate = Completer<String>();
      when(() => mockApi.getChapterContentFull(any(), 0))
          .thenAnswer((_) => ch0Gate.future);
      when(() => mockApi.getChapterContentFull(any(), 1))
          .thenAnswer((_) async => '新章正文。');

      await readNotifier().loadChapters(onlineBookUrl);
      readNotifier().updateConfig(engineUrl: engineUrl);
      final pendingOldChapter = readNotifier().play(); // 第 0 章抓取挂起
      await tester.pump();

      // 切到第 1 章朗读：新章正文先起播
      await readNotifier().jumpTo(1);
      expect(speakTexts, ['新章正文。']);

      // 旧章抓取迟到返回：不得再触发合成、不得污染新章
      ch0Gate.complete('旧章迟到的正文。');
      await tester.pump();
      await pendingOldChapter;

      expect(speakTexts, ['新章正文。']);
      expect(readState().currentIndex, 1);
      expect(readState().chapters[0].text, '旧章迟到的正文。');
      expect(readState().chapters[1].text, '新章正文。');

      readNotifier().stop();
    });
  });

  group('选段朗读起点定位', () {
    testWidgets('startParagraphText 命中第二段并从该段起播', (tester) async {
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

      stubChapters();
      stubAudioSpeak();
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((_) async => '第一段正文内容。\n\n第二段正文内容。');

      final notifier = localContainer.read(audioNotifierProvider.notifier);
      await notifier.loadChapters(onlineBookUrl);
      notifier.updateConfig(engineUrl: engineUrl);
      await notifier.startReadAloud(
        bookUrl: onlineBookUrl,
        bookName: '测试书',
        chapterIndex: 0,
        startParagraphText: '第二段正文内容。',
      );

      final state = localContainer.read(audioNotifierProvider);
      expect(state.state, PlayerState.playing);
      expect(notifier.currentParagraphIndex, 1);
      expect(speakTexts, ['第二段正文内容。']);

      notifier.stop();
    });
  });
}
