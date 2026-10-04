// 朗读引擎书级/全局双持久化测试（2026-10-04，对齐原版 SpeakEngineDialog）
//
// 原版依据：
// - 解析：ReadAloud.kt:41 `ttsEngine = ReadBook.book?.getTtsEngine()
//   ?: AppConfig.ttsEngine`（书级优先、空则全局回退）；
// - 书级：Book.setTtsEngine/getTtsEngine（Book.kt:267-272 → config.ttsEngine
//   :501），随书持久化；
// - 全局：AppConfig.ttsEngine（AppConfig.kt:506-509，PreferKey.ttsEngine =
//   "appTtsEngine"，PreferKey.kt:46）；
// - 「书」按钮（SpeakEngineDialog.kt:164-170）只写书级，不改全局；
// - 「全局」按钮（:171-177）= setTtsEngine(null) 清书级 + 写全局。
//
// 本文件钉住：书级优先/全局回退/书级+全局并存取书级/清书级回退/写库字段
// 保留（copyWith 不丢既有 readConfig 字段）/全局键持久化与重启读回。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/audio/http_tts_seed.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi api;
  late MockAudioService audioService;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  /// audioSpeak 收到的 engineUrl（按调用序）
  final receivedEngineUrls = <String>[];

  /// updateBook 收到的 Book（按调用序）
  final savedBooks = <Book>[];

  /// config 存储内容（getConfig/setConfig 共享）
  final configStore = <String, String>{};

  const urlA = 'http://book-a.example/tts?text={{text}}';
  const urlB = 'http://book-b.example/tts?text={{text}}';
  const urlG = 'http://global.example/tts?text={{text}}';
  const urlP = 'http://persisted.example/tts?text={{text}}';

  setUpAll(registerFallbacks);

  setUp(() {
    // 版本已最新：跳过 httpTTS 种子导入，聚焦引擎解析与持久化
    SharedPreferences.setMockInitialValues({
      kHttpTtsSeedVersionKey: kHttpTtsSeedVersion,
    });
    api = MockRustApi();
    audioService = MockAudioService();
    fakePlayer = FakeStreamAudioPlayer();
    receivedEngineUrls.clear();
    savedBooks.clear();
    configStore.clear();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        audioServiceProvider.overrideWithValue(audioService),
      ],
    );
    addTearDown(container.dispose);

    // startReadAloud 会 await initMediaSession：真实 AudioService 走平台通道
    // 在 FakeAsync 下不完成（既有 http_tts_seed/audio_online 测试同款处理）
    when(() => audioService.init()).thenAnswer((_) async {});
    when(() => audioService.isInitialized).thenReturn(false);
    when(() => audioService.mediaButtonStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => audioService.audioFocusStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => audioService.notifyStopped()).thenAnswer((_) async {});
    when(() => audioService.abandonAudioFocus()).thenAnswer((_) async {});
    when(() => audioService.dispose()).thenAnswer((_) async {});

    when(() => api.getChapters(any())).thenAnswer(
      (_) async => [const BookChapter(title: '第一章', index: 0)],
    );
    when(() => api.getChapterContentFull(any(), any()))
        .thenAnswer((_) async => '第一段正文内容。');
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.getConfig(any())).thenAnswer((invocation) async {
      final key = invocation.positionalArguments[0] as String;
      return configStore[key];
    });
    when(() => api.setConfig(any(), any())).thenAnswer((invocation) async {
      final key = invocation.positionalArguments[0] as String;
      final value = invocation.positionalArguments[1] as String;
      configStore[key] = value;
    });
    when(() => api.updateBook(any())).thenAnswer((invocation) async {
      savedBooks.add(invocation.positionalArguments[0] as Book);
    });
    when(() => api.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        )).thenAnswer((invocation) async {
      receivedEngineUrls
          .add(invocation.namedArguments[#engineUrl] as String);
      return '/tmp/tts/para.mp3';
    });
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  group('解析层级（书级优先、空则全局回退）', () {
    testWidgets('书级引擎生效：该书用书级、全局内存值不被改写', (tester) async {
      when(() => api.getBook('book-a')).thenAnswer(
        (_) async => const Book(
          bookUrl: 'book-a',
          name: 'A',
          readConfig: ReadConfig(ttsEngine: urlA),
        ),
      );
      readNotifier().updateConfig(engineUrl: urlG);

      await readNotifier().startReadAloud(bookUrl: 'book-a', bookName: 'A');

      expect(receivedEngineUrls, [urlA]);
      // 「书」路径不改全局值（原版 :164-170 只写书级）
      expect(readState().config.engineUrl, urlG);
      verifyNever(() => api.updateBook(any()));
      readNotifier().stop();
    });

    testWidgets('其他书不受影响：无书级时走全局（自动选默认仅作最后兜底）', (tester) async {
      when(() => api.getBook('book-a')).thenAnswer(
        (_) async => const Book(
          bookUrl: 'book-a',
          name: 'A',
          readConfig: ReadConfig(ttsEngine: urlA),
        ),
      );
      when(() => api.getBook('book-b')).thenAnswer(
        (_) async => const Book(bookUrl: 'book-b', name: 'B'),
      );
      when(() => api.getHttpTts()).thenAnswer(
        (_) async => [const HttpTts(id: 1, name: 'G', url: urlG)],
      );

      await readNotifier().startReadAloud(bookUrl: 'book-a', bookName: 'A');
      expect(receivedEngineUrls.last, urlA);

      await readNotifier().startReadAloud(bookUrl: 'book-b', bookName: 'B');
      // B 无书级 → 全局回退（此处全局为空，经自动选默认引擎补位）
      expect(receivedEngineUrls.last, urlG);
      readNotifier().stop();
    });

    testWidgets('书级 + 全局都有：书级赢', (tester) async {
      when(() => api.getBook('book-a')).thenAnswer(
        (_) async => const Book(
          bookUrl: 'book-a',
          name: 'A',
          readConfig: ReadConfig(ttsEngine: urlA),
        ),
      );
      readNotifier().updateConfig(engineUrl: urlG);

      await readNotifier().startReadAloud(bookUrl: 'book-a', bookName: 'A');

      expect(receivedEngineUrls, [urlA]);
      readNotifier().stop();
    });

    testWidgets('只设全局：所有书用全局，书级不被写', (tester) async {
      when(() => api.getBook('book-b')).thenAnswer(
        (_) async => const Book(bookUrl: 'book-b', name: 'B'),
      );
      readNotifier().updateConfig(engineUrl: urlG);

      await readNotifier().startReadAloud(bookUrl: 'book-b', bookName: 'B');

      expect(receivedEngineUrls, [urlG]);
      verifyNever(() => api.updateBook(any()));
      readNotifier().stop();
    });

    testWidgets('持久化全局值读回：无书级且内存为空时用 config 键 appTtsEngine',
        (tester) async {
      configStore[kTtsEngineConfigKey] = urlP;
      when(() => api.getBook('book-c')).thenAnswer(
        (_) async => const Book(bookUrl: 'book-c', name: 'C'),
      );
      // 若持久化值读回成功，不应再走自动选默认引擎
      when(() => api.getHttpTts()).thenAnswer(
        (_) async => [const HttpTts(id: 1, name: 'G', url: urlG)],
      );

      await readNotifier().startReadAloud(bookUrl: 'book-c', bookName: 'C');

      expect(receivedEngineUrls, [urlP]);
      expect(readState().config.engineUrl, urlP);
      verifyNever(() => api.getHttpTts());
      readNotifier().stop();
    });
    testWidgets('听书页 TTS 入口（play 直调）：全局为空时读回持久化全局值',
        (tester) async {
      configStore[kTtsEngineConfigKey] = urlP;

      await readNotifier().loadChapters('book-d');
      await readNotifier().play();

      expect(receivedEngineUrls, [urlP]);
      expect(readState().config.engineUrl, urlP);
      readNotifier().stop();
    });
  });

  group('写库（书级 readConfig.ttsEngine / 全局 config 键）', () {
    test('setBookTtsEngine：写书级且保留既有 readConfig 字段（不丢字段）', () async {
      readNotifier().bindBook(const Book(
        bookUrl: 'url',
        name: '书',
        readConfig: ReadConfig(
          ttsEngine: urlB,
          playSpeed: 1.5,
          playMode: 1,
          openCredits: 3,
        ),
      ));

      final ok = await readNotifier().setBookTtsEngine(urlA);

      expect(ok, isTrue);
      expect(savedBooks, hasLength(1));
      expect(savedBooks.single.readConfig?.ttsEngine, urlA);
      // 既有字段保留（copyWith 不整体替换）
      expect(savedBooks.single.readConfig?.playSpeed, 1.5);
      expect(savedBooks.single.readConfig?.playMode, 1);
      expect(savedBooks.single.readConfig?.openCredits, 3);
      // 全局值不受「书」写影响
      expect(readState().config.engineUrl, isEmpty);
    });

    test('setBookTtsEngine：历史「名称,URL」形态按裸 URL 落库', () async {
      readNotifier().bindBook(const Book(bookUrl: 'url', name: '书'));

      await readNotifier().setBookTtsEngine('本地引擎,$urlA');

      expect(savedBooks.single.readConfig?.ttsEngine, urlA);
    });

    test('setBookTtsEngine：无当前书返回 false 且不写库（原版空安全语义）', () async {
      final ok = await readNotifier().setBookTtsEngine(urlA);

      expect(ok, isFalse);
      expect(savedBooks, isEmpty);
    });

    test('clearBookTtsEngine：清书级并保留其他字段，解析回退全局', () async {
      readNotifier().bindBook(const Book(
        bookUrl: 'url',
        name: '书',
        readConfig: ReadConfig(ttsEngine: urlA, playSpeed: 1.5),
      ));
      readNotifier().updateConfig(engineUrl: urlG);
      expect(readNotifier().resolveTtsEngineUrl(), urlA);

      await readNotifier().clearBookTtsEngine();

      expect(savedBooks.single.readConfig?.ttsEngine, isNull);
      expect(savedBooks.single.readConfig?.playSpeed, 1.5);
      expect(readNotifier().resolveTtsEngineUrl(), urlG);
    });

    test('setGlobalTtsEngine：清书级 + 写全局（内存与 config 键双写）', () async {
      readNotifier().bindBook(const Book(
        bookUrl: 'url',
        name: '书',
        readConfig: ReadConfig(ttsEngine: urlA),
      ));

      await readNotifier().setGlobalTtsEngine(urlG);

      // 原版「全局」按钮：先 setTtsEngine(null)（:172）再写 AppConfig（:173）
      expect(savedBooks.single.readConfig?.ttsEngine, isNull);
      expect(configStore[kTtsEngineConfigKey], urlG);
      expect(readState().config.engineUrl, urlG);
      expect(readNotifier().resolveTtsEngineUrl(), urlG);
    });

    test('setGlobalTtsEngine：无书级可清时只写全局，不产生空写库', () async {
      readNotifier().bindBook(const Book(bookUrl: 'url', name: '书'));

      await readNotifier().setGlobalTtsEngine(urlG);

      expect(savedBooks, isEmpty);
      expect(configStore[kTtsEngineConfigKey], urlG);
      expect(readState().config.engineUrl, urlG);
    });

    test('loadEffectiveTtsEngineUrl：书级 > 内存全局 > 持久化全局', () async {
      readNotifier().bindBook(const Book(
        bookUrl: 'url',
        name: '书',
        readConfig: ReadConfig(ttsEngine: urlA),
      ));
      readNotifier().updateConfig(engineUrl: urlG);
      configStore[kTtsEngineConfigKey] = urlP;
      expect(await readNotifier().loadEffectiveTtsEngineUrl(), urlA);

      await readNotifier().clearBookTtsEngine();
      expect(await readNotifier().loadEffectiveTtsEngineUrl(), urlG);
    });

    test('hasCurrentBook：无书为 false，绑定后为 true', () {
      expect(readNotifier().hasCurrentBook, isFalse);
      readNotifier().bindBook(const Book(bookUrl: 'url', name: '书'));
      expect(readNotifier().hasCurrentBook, isTrue);
    });
  });
}
