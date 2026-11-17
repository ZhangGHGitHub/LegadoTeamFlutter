// 播放链读音频缓存定向测试（P0，契约 §2.47 `audioCacheGetFile`）
//
// 缺陷背景：`_playAudioBookStream` 此前解析出 `mediaUrl` 后直接 `playUrl`，
// `audioCacheQuery` 全仓唯一调用点只有听书页批量预下载的跳过判定 → **预下载
// 产物永远不会被播放使用**。原版 `AudioPlay.kt:388-423` 播放第一步
// `AudioCacheManager.getCachedAudio(...)`，命中即完全跳网络。
//
// 覆盖：
// 1) 命中缓存 → `playLocalFile`（且不发网络取址请求）
// 2) 未命中 → 原网络路径 `playUrl`
// 3) 命中但本地文件播放失败 → 回落 `playUrl`（缓存是加速器不是数据源）
// 4) 查询缓存抛异常 → 按未命中处理，走网络路径（不阻断播放）
//
// [P0 | 2026-11-18] 新增。

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

  /// 单章音频书 + 网络取址桩（默认两章，便于验证切章链路）
  void stubAudioBook({int chapterCount = 1}) {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => List<BookChapter>.generate(
        chapterCount,
        (i) => BookChapter(title: 'ch$i', index: i),
      ),
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
  }

  Future<void> startStream() async {
    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  group('播放链读音频缓存（契约 §2.47 audioCacheGetFile）', () {
    testWidgets('命中缓存 → playLocalFile，且完全不发网络取址', (tester) async {
      stubAudioBook();
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenAnswer((_) async => '/cache/audio/book_abc/00000_bc4b.mp3');

      await startStream();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.playedLocalFiles, hasLength(1));
      expect(
        fakePlayer.playedLocalFiles.first.path,
        '/cache/audio/book_abc/00000_bc4b.mp3',
      );
      expect(fakePlayer.playedUrls, isEmpty, reason: '命中缓存不得走网络播放');
      verifyNever(() => mockApi.getAudioChapterMedia(any(), any()));
      // 归属标识仍绑定本章（进度/完成回调依赖）
      expect(
        fakePlayer.playedTags.single,
        (bookUrl: 'url', chapterIndex: 0),
      );
    });

    testWidgets('未命中缓存 → 原网络路径 playUrl', (tester) async {
      stubAudioBook();
      // MockRustApi 默认实现已返回 null（未命中），此处显式钉死语义
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenAnswer((_) async => null);

      await startStream();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.playedUrls, ['https://cdn.example.com/0.mp3']);
      expect(fakePlayer.playedLocalFiles, isEmpty);
    });

    testWidgets('命中但本地播放失败 → 现场补取址并回落 playUrl', (tester) async {
      stubAudioBook();
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenAnswer((_) async => '/cache/audio/gone.mp3');
      // 缓存文件在查询与播放之间被清理/损坏
      fakePlayer.playLocalError = StateError('本地文件不存在');
      when(() => mockApi.getAudioChapterMedia(any(), any()))
          .thenAnswer((invocation) async {
        final index = invocation.positionalArguments[1] as int;
        return {
          'mediaUrl': 'https://cdn.example.com/fallback-$index.mp3',
          'isVolume': false,
        };
      });

      await startStream();

      // playLocalFile 抛错不记录成功播放；随后现场取址并走网络播放
      expect(fakePlayer.playedLocalFiles, isEmpty);
      expect(
        fakePlayer.playedUrls,
        ['https://cdn.example.com/fallback-0.mp3'],
        reason: '本地播放失败须回落网络，不得中断播放',
      );
      expect(readState().state, PlayerState.playing);
      expect(readState().errorMessage, isNull);
      expect(readState().mediaUrl, 'https://cdn.example.com/fallback-0.mp3');
    });

    testWidgets('查询缓存抛异常 → 按未命中处理，仍可正常播放', (tester) async {
      stubAudioBook();
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenThrow(StateError('FFI 未初始化'));

      await startStream();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.playedUrls, ['https://cdn.example.com/0.mp3']);
      expect(fakePlayer.playedLocalFiles, isEmpty);
    });

    testWidgets('逐章判定：第 0 章命中、第 1 章未命中', (tester) async {
      stubAudioBook(chapterCount: 2);
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: 0,
        ),
      ).thenAnswer((_) async => '/cache/audio/ch0.mp3');
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: 1,
        ),
      ).thenAnswer((_) async => null);

      await startStream();
      expect(fakePlayer.playedLocalFiles, hasLength(1));
      expect(fakePlayer.playedUrls, isEmpty);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      expect(readState().currentIndex, 1);
      expect(fakePlayer.playedUrls, ['https://cdn.example.com/1.mp3']);
      expect(fakePlayer.playedLocalFiles, hasLength(1));
    });
  });
}
