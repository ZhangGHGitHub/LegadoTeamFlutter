// A2/A3 听书偏好持久化与进度写入测试（音频轨道 A2/A3 批）
//
// A2：
// - setMode → audioWithPlayMode FFI 合并 readConfig（保留既有字段）→ updateBook
// - updateConfig(speed) → 防抖合并后写 ReadConfig.playSpeed → updateBook
// - applyBookPreferences：打开听书页/切书读回播放模式与语速（含越界容错）
// A3：
// - 流媒体播放中按位置增量 ≥5s 节流写 audio_progress
// - 章节播完自动切章前 / stop / pause / 容器销毁时写进度
// - TTS 模式不写流媒体进度键（键语义为毫秒播放位置）
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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

  /// 两章音频书 + 流媒体播放启动
  Future<void> startStream() async {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: 'ch1', index: 0),
        const BookChapter(title: 'ch2', index: 1),
      ],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getAudioChapterMedia(any(), any()))
        .thenAnswer((invocation) async {
      final index = invocation.positionalArguments[1] as int;
      return {
        'mediaUrl': 'https://cdn.example.com/$index.mp3',
        'isVolume': false,
      };
    });
    when(() => mockApi.getAudioProgress(any(), any()))
        .thenAnswer((_) async => null);
    when(() => mockApi.saveAudioProgress(any(), any(), any()))
        .thenAnswer((_) async {});

    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  group('A2 播放模式/语速持久化', () {
    testWidgets('setMode 经 audioWithPlayMode 合并 readConfig 并 updateBook', (tester) async {
      Map<String, dynamic>? mergedJson;
      Book? savedBook;
      when(() => mockApi.audioWithPlayMode(
            readConfig: any(named: 'readConfig'),
            playMode: any(named: 'playMode'),
          )).thenAnswer((invocation) async {
        final raw = invocation.namedArguments[#readConfig] as String?;
        final map = raw == null || raw.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        map['playMode'] = invocation.namedArguments[#playMode];
        mergedJson = map;
        return jsonEncode(map);
      });
      when(() => mockApi.updateBook(any())).thenAnswer((invocation) async {
        savedBook = invocation.positionalArguments[0] as Book;
      });

      readNotifier().bindBook(const Book(
        bookUrl: 'url',
        name: '测试书',
        readConfig: ReadConfig(playMode: 0, openCredits: 15),
      ));

      await readNotifier().setMode(AudioPlayMode.shuffle);

      expect(readState().mode, AudioPlayMode.shuffle);
      expect(mergedJson?['playMode'], 2);
      // 既有 readConfig 字段不得被合并覆盖丢失
      expect(mergedJson?['openCredits'], 15);
      expect(savedBook?.readConfig?.playMode, 2);
      expect(savedBook?.readConfig?.openCredits, 15);
      verify(() => mockApi.audioWithPlayMode(
            readConfig: any(named: 'readConfig'),
            playMode: 2,
          )).called(1);
      verify(() => mockApi.updateBook(any())).called(1);
    });

    testWidgets('updateConfig(speed) 防抖合并后写 ReadConfig.playSpeed', (tester) async {
      Book? savedBook;
      when(() => mockApi.updateBook(any())).thenAnswer((invocation) async {
        savedBook = invocation.positionalArguments[0] as Book;
      });

      readNotifier().bindBook(const Book(bookUrl: 'url', name: '测试书'));

      readNotifier().updateConfig(speed: 1.5);
      readNotifier().updateConfig(speed: 2.0);
      // 防抖窗口内不写库（合并同一次拖动）
      await tester.pump(const Duration(milliseconds: 300));
      verifyNever(() => mockApi.updateBook(any()));

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      verify(() => mockApi.updateBook(any())).called(1);
      expect(savedBook?.readConfig?.playSpeed, 2.0);
    });

    test('applyBookPreferences 读回播放模式与语速', () async {
      await readNotifier().applyBookPreferences(const Book(
        bookUrl: 'url',
        name: '测试书',
        readConfig: ReadConfig(playMode: 2, playSpeed: 1.5),
      ));

      expect(readState().mode, AudioPlayMode.shuffle);
      expect(readState().config.speed, 1.5);
    });

    test('applyBookPreferences 无 Book 对象时经 getBook 读回', () async {
      when(() => mockApi.getBook('url')).thenAnswer(
        (_) async => const Book(
          bookUrl: 'url',
          name: '测试书',
          readConfig: ReadConfig(playMode: 1, playSpeed: 2.0),
        ),
      );

      await readNotifier().applyBookPreferences(null, fallbackBookUrl: 'url');

      expect(readState().mode, AudioPlayMode.singleLoop);
      expect(readState().config.speed, 2.0);
    });

    test('applyBookPreferences 越界 playMode 回退 sequential（兼容原版 LIST_LOOP=3）', () async {
      await readNotifier().applyBookPreferences(const Book(
        bookUrl: 'url',
        name: '测试书',
        readConfig: ReadConfig(playMode: 3),
      ));

      expect(readState().mode, AudioPlayMode.sequential);
    });
  });

  group('A3 流媒体进度写入', () {
    testWidgets('播放中按位置增量 ≥5s 节流写库', (tester) async {
      await startStream();

      fakePlayer.emitProgress(
        const Duration(seconds: 2),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 2000)).called(1);

      // 增量不足 5s：不写（上一次 verify 已消费记录，此后不得有新的写调用）
      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verifyNever(() => mockApi.saveAudioProgress('url', 0, any()));

      // 增量超过 5s：写
      fakePlayer.emitProgress(
        const Duration(seconds: 8),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 8000)).called(1);

      readNotifier().stop();
    });

    testWidgets('章节播完自动切章前写当前章进度，不写新章脏进度', (tester) async {
      await startStream();

      fakePlayer.emitProgress(
        const Duration(seconds: 2),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 2000)).called(1);

      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(minutes: 3),
      );
      await tester.pump();

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      expect(readState().currentIndex, 1);
      verify(() => mockApi.saveAudioProgress('url', 0, 4000)).called(1);
      verifyNever(() => mockApi.saveAudioProgress('url', 1, any()));

      readNotifier().stop();
    });

    testWidgets('stop 前写入当前进度', (tester) async {
      await startStream();

      fakePlayer.emitProgress(
        const Duration(seconds: 6),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 6000)).called(1);

      fakePlayer.emitProgress(
        const Duration(seconds: 7),
        const Duration(minutes: 3),
      );
      await tester.pump();

      readNotifier().stop();
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 7000)).called(1);
    });

    testWidgets('pause 前写入当前进度（既有行为回归）', (tester) async {
      await startStream();

      fakePlayer.emitProgress(
        const Duration(seconds: 3),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 3000)).called(1);

      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(minutes: 3),
      );
      await tester.pump();

      readNotifier().pause();
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 4000)).called(1);
    });

    testWidgets('容器销毁（onDispose）尽力写入当前进度', (tester) async {
      await startStream();

      fakePlayer.emitProgress(
        const Duration(seconds: 3),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 3000)).called(1);

      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(minutes: 3),
      );
      await tester.pump();

      container.dispose();
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 4000)).called(1);
    });

    testWidgets('TTS 模式完成/停止不写流媒体进度键（键语义为毫秒）', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0)],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((_) async => '第一段文本内容。');
      when(() => mockApi.audioSpeak(
            text: any(named: 'text'),
            engineUrl: any(named: 'engineUrl'),
            speed: any(named: 'speed'),
            pitch: any(named: 'pitch'),
            volume: any(named: 'volume'),
            voiceName: any(named: 'voiceName'),
          )).thenAnswer((_) async => '/tmp/tts/para.mp3');

      await readNotifier().loadChapters('url');
      readNotifier()
          .updateConfig(engineUrl: 'https://tts.example.com/{{text}}');
      await readNotifier().play();

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      readNotifier().stop();
      await tester.pump();

      verifyNever(() => mockApi.saveAudioProgress(any(), any(), any()));
    });
  });
}
