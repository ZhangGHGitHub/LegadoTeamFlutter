// HLS 播放支持定向测试（批 1，契约 §2.26 `getAudioChapterMedia.headers`）
//
// 真机批 47 结论（决定本批范围）：
// 1) `.m3u8` + query token → 能播出声（零改动）
// 2) 无扩展名 m3u8 → `UnrecognizedInputFormatException`（`Content-Type` 被
//    ExoPlayer 忽略，需 `formatHint: VideoFormat.hls`）
// 3) segment 需 Referer/UA → 403（`playUrl` 未传 `httpHeaders`，需补）
// 4) **关键**：无条件传 `formatHint: VideoFormat.hls` 会误伤普通 MP3
//    （MP3 被当 HLS 解析同样失败）→ 必须按 URL 后缀判定
//
// 覆盖：
// 1) `.m3u8` URL → 传 `formatHint: VideoFormat.hls`
// 2) 普通 `.mp3` URL → 不传 formatHint
// 3) 有 headers → 原样传入
// 4) 本地路径（§2.47 缓存命中）→ 不传 headers / formatHint
// 5) 回落取址路径的 headers 与地址同源
//
// [批1 | 2026-11-18] 新增。

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/stream_audio_player.dart';

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

  /// 单章音频书 + 可定制的取址桩
  void stubAudioBook({
    required String mediaUrl,
    Map<String, dynamic>? headers,
    int chapterCount = 1,
  }) {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => List<BookChapter>.generate(
        chapterCount,
        (i) => BookChapter(title: 'ch$i', index: i),
      ),
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer((_) async {
      return {
        'mediaUrl': mediaUrl,
        'isVolume': false,
        'headers': ?headers,
      };
    });
    when(() => mockApi.getAudioProgress(any(), any()))
        .thenAnswer((_) async => null);
    // 默认未命中音频缓存（走网络播放路径）
    when(
      () => mockApi.audioCacheGetFile(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
      ),
    ).thenAnswer((_) async => null);
  }

  Future<void> startStream() async {
    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  group('isHlsPlayUrl：URL 后缀判定（对齐 Rust is_hls_url 语义）', () {
    test('.m3u8 后缀 → true', () {
      expect(isHlsPlayUrl('https://cdn.example.com/a.m3u8'), isTrue);
    });

    test('.m3u 后缀 → true', () {
      expect(isHlsPlayUrl('https://cdn.example.com/a.m3u'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isHlsPlayUrl('https://cdn.example.com/A.M3U8'), isTrue);
    });

    test('截 ? 与 # 后判后缀（query token 不影响）', () {
      expect(isHlsPlayUrl('https://cdn.example.com/a.m3u8?token=t&e=1'), isTrue);
      expect(isHlsPlayUrl('https://cdn.example.com/a.m3u8#frag'), isTrue);
      expect(isHlsPlayUrl('https://cdn.example.com/a.mp3?x=.m3u8'), isFalse);
    });

    test('普通音频后缀 → false', () {
      expect(isHlsPlayUrl('https://cdn.example.com/a.mp3'), isFalse);
      expect(isHlsPlayUrl('https://cdn.example.com/a.m4a'), isFalse);
      expect(isHlsPlayUrl('https://cdn.example.com/a.flac'), isFalse);
    });

    test('无扩展名地址 → false（Content-Type 无法作为判据）', () {
      expect(isHlsPlayUrl('https://cdn.example.com/stream/abc123'), isFalse);
    });

    test('空串/空白 → false', () {
      expect(isHlsPlayUrl(''), isFalse);
      expect(isHlsPlayUrl('   '), isFalse);
    });
  });

  group('播放链：formatHint 按后缀判定', () {
    testWidgets('.m3u8 URL → 传 formatHint: VideoFormat.hls', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/ep0.m3u8?token=abc');

      await startStream();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.playedUrls, ['https://cdn.example.com/ep0.m3u8?token=abc']);
      expect(
        fakePlayer.playedUrlFormatHints.single,
        VideoFormat.hls,
        reason: '无扩展名/带 token 的 HLS 地址需 formatHint 才能被 ExoPlayer 识别',
      );
    });

    testWidgets('普通 .mp3 URL → 不传 formatHint（防误伤）', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/ep0.mp3');

      await startStream();

      expect(fakePlayer.playedUrls, ['https://cdn.example.com/ep0.mp3']);
      expect(
        fakePlayer.playedUrlFormatHints.single,
        isNull,
        reason: '无条件传 HLS hint 会把普通 MP3 当 HLS 解析（真机结论 ④）',
      );
    });

    testWidgets('无扩展名非 HLS 地址 → 不传 formatHint', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/stream/abc123');

      await startStream();

      expect(fakePlayer.playedUrlFormatHints.single, isNull);
    });
  });

  group('播放链：httpHeaders（防盗链）', () {
    testWidgets('有 headers → 原样传入 playUrl', (tester) async {
      stubAudioBook(
        mediaUrl: 'https://cdn.example.com/ep0.m3u8',
        headers: {
          'Referer': 'https://site.example/',
          'User-Agent': 'LegadoTest/1.0',
        },
      );

      await startStream();

      expect(
        fakePlayer.playedUrlHeaders.single,
        {
          'Referer': 'https://site.example/',
          'User-Agent': 'LegadoTest/1.0',
        },
      );
      expect(fakePlayer.playedUrlFormatHints.single, VideoFormat.hls);
    });

    testWidgets('无 headers 键 → 不传（null）', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/ep0.mp3');

      await startStream();

      expect(fakePlayer.playedUrlHeaders.single, isNull);
    });

    testWidgets('headers 空 Map → 视为未传', (tester) async {
      stubAudioBook(
        mediaUrl: 'https://cdn.example.com/ep0.mp3',
        headers: <String, dynamic>{},
      );

      await startStream();

      expect(fakePlayer.playedUrlHeaders.single, isNull);
    });

    testWidgets('headers 值非 String → 过滤后为空则视为未传', (tester) async {
      stubAudioBook(
        mediaUrl: 'https://cdn.example.com/ep0.mp3',
        headers: <String, dynamic>{'X-Bad': 123},
      );

      await startStream();

      expect(fakePlayer.playedUrlHeaders.single, isNull);
    });
  });

  group('播放链：本地缓存命中不传 headers/formatHint', () {
    testWidgets('§2.47 命中 → playLocalFile，且 headers/formatHint 都不传', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/ep0.m3u8');
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenAnswer((_) async => '/cache/audio/book_abc/00000_bc4b.mp3');

      await startStream();

      expect(fakePlayer.playedLocalFiles, hasLength(1));
      expect(
        fakePlayer.playedUrls,
        isEmpty,
        reason: '本地文件路径不得走 networkUrl（更不能传 headers/formatHint）',
      );
      expect(fakePlayer.playedUrlHeaders, isEmpty);
      expect(fakePlayer.playedUrlFormatHints, isEmpty);
      // 命中缓存时完全跳过取址
      verifyNever(() => mockApi.getAudioChapterMedia(any(), any()));
    });

    testWidgets('本地播放失败回落网络 → 回落地址按自身后缀判 formatHint', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/ep0.m3u8');
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenAnswer((_) async => '/cache/audio/gone.mp3');
      fakePlayer.playLocalError = StateError('本地文件不存在');

      await startStream();

      expect(fakePlayer.playedLocalFiles, isEmpty);
      expect(fakePlayer.playedUrls, ['https://cdn.example.com/ep0.m3u8']);
      expect(
        fakePlayer.playedUrlFormatHints.single,
        VideoFormat.hls,
        reason: '回落地址是 HLS，需 hint',
      );
    });
  });

  group('回落取址：headers 与地址同源', () {
    testWidgets('本地失败 → 现场补取址，headers 取该次返回', (tester) async {
      stubAudioBook(mediaUrl: 'https://cdn.example.com/ep0.mp3');
      when(
        () => mockApi.audioCacheGetFile(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
        ),
      ).thenAnswer((_) async => '/cache/audio/gone.mp3');
      fakePlayer.playLocalError = StateError('本地文件不存在');
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (_) async => {
          'mediaUrl': 'https://cdn.example.com/fallback-0.m3u8',
          'isVolume': false,
          'headers': {'Referer': 'https://site.example/'},
        },
      );

      await startStream();

      expect(fakePlayer.playedUrls, ['https://cdn.example.com/fallback-0.m3u8']);
      expect(
        fakePlayer.playedUrlHeaders.single,
        {'Referer': 'https://site.example/'},
      );
      expect(fakePlayer.playedUrlFormatHints.single, VideoFormat.hls);
    });
  });
}
