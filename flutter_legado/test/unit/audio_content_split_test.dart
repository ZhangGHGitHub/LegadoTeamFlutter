// 朗读内容划分接线测试（设置批5b）
//
// 覆盖：
// 1) paragraph/default：空行分段（整段单元，段内换行保留）；
// 2) symbols：按选中标点切分、空集合回退句末标点；
// 3) page：阅读器传入页首偏移时按页切分；无分页/切章后回退整段；
// 4) startChapterPos 仍按字符偏移映射到切分单元；
// 5) 段落间隔：0 立即推进；非 0 等待（真实播放与估算降级两条路径）；
//    stop 取消等待；
// 6) 设置页切模式后下一次起播按新粒度切分（内存镜像即时更新）。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/utils/read_aloud_content_split.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late FakeStreamAudioPlayer fakePlayer;
  late MockAudioService audioService;
  late ProviderContainer container;

  /// audioSpeak 入参 text（每用例清空）
  final speakTexts = <String>[];

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'httpTtsSeedVersion': 1});
    mockApi = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    audioService = MockAudioService();
    // startReadAloud 会初始化媒体会话：平台动作全部打成空实现，避免
    // flutter_tester 等待真实通道。
    when(() => audioService.init()).thenAnswer((_) async {});
    when(() => audioService.isInitialized).thenReturn(false);
    when(
      () => audioService.mediaButtonStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => audioService.audioFocusStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => audioService.playbackActiveStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => audioService.playbackActive).thenReturn(false);
    when(() => audioService.requestAudioFocus()).thenAnswer((_) async => true);
    when(() => audioService.abandonAudioFocus()).thenAnswer((_) async {});
    when(() => audioService.setWakeLock(any())).thenAnswer((_) async {});
    when(
      () => audioService.notifyPlaying(position: any(named: 'position')),
    ).thenAnswer((_) async {});
    when(
      () => audioService.notifyPaused(position: any(named: 'position')),
    ).thenAnswer((_) async {});
    when(() => audioService.notifyStopped()).thenAnswer((_) async {});
    when(
      () => audioService.updateMetadata(
        title: any(named: 'title'),
        artist: any(named: 'artist'),
        album: any(named: 'album'),
      ),
    ).thenAnswer((_) async {});
    when(() => audioService.dispose()).thenAnswer((_) async {});
    speakTexts.clear();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        audioServiceProvider.overrideWithValue(audioService),
      ],
    );
    addTearDown(container.dispose);
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  const bookUrl = 'https://example.com/book/split';
  const engineUrl = 'https://tts.example.com/?text={{text}}';

  void stubBooks({String chapter0 = '', String chapter1 = ''}) {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: '第一章', index: 0),
        const BookChapter(title: '第二章', index: 1),
      ],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(
      () => mockApi.getChapterContentFull(any(), 0),
    ).thenAnswer((_) async => chapter0);
    when(
      () => mockApi.getChapterContentFull(any(), 1),
    ).thenAnswer((_) async => chapter1);
  }

  void stubAudioSpeak() {
    when(
      () => mockApi.audioSpeak(
        text: any(named: 'text'),
        engineUrl: any(named: 'engineUrl'),
        speed: any(named: 'speed'),
        pitch: any(named: 'pitch'),
        volume: any(named: 'volume'),
        voiceName: any(named: 'voiceName'),
      ),
    ).thenAnswer((invocation) async {
      speakTexts.add(invocation.namedArguments[#text] as String);
      return '/tmp/tts/para_${speakTexts.length}.mp3';
    });
  }

  Future<void> startWith({
    required String chapter0,
    String chapter1 = '',
    List<int>? pageStarts,
    int? startChapterPos,
  }) async {
    stubBooks(chapter0: chapter0, chapter1: chapter1);
    stubAudioSpeak();
    await readNotifier().loadChapters(bookUrl);
    readNotifier().updateConfig(engineUrl: engineUrl);
    await readNotifier().startReadAloud(
      bookUrl: bookUrl,
      bookName: '测试书',
      chapterIndex: 0,
      pageStarts: pageStarts,
      startChapterPos: startChapterPos,
    );
  }

  group('划分模式接入选段', () {
    testWidgets('paragraph：空行分段，段内换行保留', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'paragraph',
      });
      await startWith(chapter0: '第一段\n第二行\n\n第二段');

      expect(readNotifier().paragraphCount, 2);
      expect(readNotifier().currentParagraphIndex, 0);
      expect(speakTexts, ['第一段\n第二行']);
      readNotifier().stop();
    });

    testWidgets('default：运行时按整段（与 paragraph 一致）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'default',
      });
      await startWith(chapter0: '甲\n乙\n\n丙');

      expect(readNotifier().paragraphCount, 2);
      expect(speakTexts, ['甲\n乙']);
      readNotifier().stop();
    });

    testWidgets('symbols：按选中标点切分并保留标点', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'symbols',
        PrefKeys.readAloudContentSplitSymbols: '。！',
      });
      await startWith(chapter0: '第一句。第二句！第三句');

      expect(readNotifier().paragraphCount, 3);
      expect(speakTexts, ['第一句。']);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readNotifier().currentParagraphIndex, 1);
      expect(speakTexts, ['第一句。', '第二句！']);
      readNotifier().stop();
    });

    testWidgets('symbols：空集合回退句末标点（不按逗号切分）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'symbols',
      });
      await startWith(chapter0: '甲，乙。丙！丁');

      expect(readNotifier().paragraphCount, 3);
      expect(speakTexts, ['甲，乙。']);
      readNotifier().stop();
    });

    testWidgets('page：按页首偏移切分', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'page',
      });
      await startWith(chapter0: '0123456789', pageStarts: const [0, 4, 8]);

      expect(readNotifier().readAloudPageStarts, [0, 4, 8]);
      expect(readNotifier().paragraphCount, 3);
      expect(speakTexts, ['0123']);
      readNotifier().stop();
    });

    testWidgets('page：无分页信息回退整段', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'page',
      });
      await startWith(chapter0: '甲\n\n乙');

      expect(readNotifier().readAloudPageStarts, isNull);
      expect(readNotifier().paragraphCount, 2);
      expect(speakTexts, ['甲']);
      readNotifier().stop();
    });

    testWidgets('page：切章清空页首，新章回退整段', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'page',
      });
      await startWith(
        chapter0: '0123456789',
        chapter1: '甲\n\n乙',
        pageStarts: const [0, 4, 8],
      );
      expect(readNotifier().paragraphCount, 3);

      await readNotifier().next();
      await tester.pump();

      expect(readState().currentIndex, 1);
      expect(readNotifier().readAloudPageStarts, isNull);
      expect(readNotifier().paragraphCount, 2);
      expect(speakTexts.last, '甲');
      readNotifier().stop();
    });

    testWidgets('startChapterPos 按字符偏移定位到页单元', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudContentSplitMode: 'page',
      });
      await startWith(
        chapter0: '0123456789',
        pageStarts: const [0, 4, 8],
        startChapterPos: 5,
      );

      expect(readNotifier().currentParagraphIndex, 1);
      expect(speakTexts, ['4567']);
      readNotifier().stop();
    });
  });

  group('段落间隔', () {
    testWidgets('间隔 0：上一段完成立即推进', (tester) async {
      await startWith(chapter0: '第一段\n\n第二段');
      expect(speakTexts, ['第一段']);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      expect(readNotifier().currentParagraphIndex, 1);
      expect(speakTexts, ['第一段', '第二段']);
      readNotifier().stop();
    });

    testWidgets('间隔非 0：真实播放完成后等待再推进', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.ttsParagraphInterval: 300,
      });
      await startWith(chapter0: '第一段\n\n第二段');
      expect(speakTexts, ['第一段']);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(readNotifier().currentParagraphIndex, 0, reason: '间隔未到不得推进');
      expect(speakTexts, ['第一段']);

      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(readNotifier().currentParagraphIndex, 1);
      expect(speakTexts, ['第一段', '第二段']);
      readNotifier().stop();
    });

    testWidgets('间隔非 0：估算降级路径同样遵守', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.ttsParagraphInterval: 300,
      });
      stubBooks(chapter0: '第一段\n\n第二段');
      when(
        () => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        ),
      ).thenThrow(StateError('引擎不可达'));
      await readNotifier().loadChapters(bookUrl);
      readNotifier().updateConfig(engineUrl: engineUrl);
      await readNotifier().startReadAloud(
        bookUrl: bookUrl,
        bookName: '测试书',
        chapterIndex: 0,
      );

      // 估算时长下限 800ms 到点后开始等待 300ms
      await tester.pump(const Duration(milliseconds: 850));
      expect(readNotifier().currentParagraphIndex, 0);
      await tester.pump(const Duration(milliseconds: 350));
      expect(readNotifier().currentParagraphIndex, 1);
      readNotifier().stop();
    });

    testWidgets('stop 取消等待，不再推进', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.ttsParagraphInterval: 1000,
      });
      await startWith(chapter0: '第一段\n\n第二段');

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      readNotifier().stop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(readState().state, PlayerState.idle);
      expect(readNotifier().currentParagraphIndex, 0);
      expect(speakTexts, ['第一段']);
    });
  });

  group('模式切换即时生效', () {
    testWidgets('设置页切到 symbols 后重新起播按新粒度切分', (tester) async {
      await startWith(chapter0: '甲。乙。\n\n丙');
      expect(
        readNotifier().contentSplitMode,
        ReadAloudContentSplitMode.defaultMode,
      );
      expect(readNotifier().paragraphCount, 2);
      expect(speakTexts, ['甲。乙。']);

      // 设置页会先持久化再更新内存镜像；play() 重新读回偏好
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PrefKeys.readAloudContentSplitMode,
        ReadAloudContentSplitMode.symbols.storageValue,
      );
      await prefs.setString(PrefKeys.readAloudContentSplitSymbols, '。');
      readNotifier().setContentSplitPreferences(
        mode: ReadAloudContentSplitMode.symbols,
        symbols: '。',
      );
      await readNotifier().play();
      await tester.pump();

      expect(readNotifier().paragraphCount, 3);
      expect(speakTexts.last, '甲。');
      readNotifier().stop();
    });
  });
}
