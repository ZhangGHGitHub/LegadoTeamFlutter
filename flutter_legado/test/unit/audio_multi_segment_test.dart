// 多段音频（JSON 数组 playUrl）播放支持测试（批3）
//
// 缺陷背景：`_playAudioBookStream` 此前把 `mediaUrl` 当单一 URL 交给
// `StreamAudioPlayer.playUrl` → `Uri.parse`，形如
// `["http://a/1.mp3","http://a/2.mp3"]` 的数组地址必然解析失败。
//
// 原版：`AudioPlayService.kt:307-317` 有 `requestUrl.isJsonArray()` 分支 →
// `ExoPlayerHelper.getMediaSource`（`ExoPlayerHelper.kt:158-169`）拼
// `ConcatenatingMediaSource2`。我方播放器无媒体源拼接能力，改为逐段串播：
// 段完成 → 间隙 → 下一段。
//
// 覆盖：
// 1) 地址解析（数组 / 单 URL / 段内 UrlOption / 畸形数组）
// 2) 3 段依次播放，顺序正确
// 3) 段间间隙（间隙内不起播，到点才起播）
// 4) 中途暂停 → 不继续；恢复从下一段续播（不重播）
// 5) 中途停止 → 不继续
// 6) 中途切章 → 旧串播链终止，新章正常起播
// 7) 单 URL（非数组）行为不变（防回归）
// 8) 每段 headers / formatHint 正确传递
// 9) 跨段进度按章累计（不倒退到段首）
//
// [批3 | 2026-11-19] 新增。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/utils/audio_segments.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
  });

  // ===== 1. 地址解析（纯函数）=====
  group('parseAudioPlaySegments / isJsonArrayPlayUrl', () {
    test('isJsonArrayPlayUrl：对齐原版 trim 后首尾 [ ] 判定', () {
      expect(isJsonArrayPlayUrl('["a"]'), isTrue);
      expect(isJsonArrayPlayUrl('  ["a","b"]  '), isTrue);
      expect(isJsonArrayPlayUrl('https://cdn/a.mp3'), isFalse);
      expect(isJsonArrayPlayUrl('[]x'), isFalse);
      expect(isJsonArrayPlayUrl(''), isFalse);
      expect(isJsonArrayPlayUrl('[not json]'), isTrue, reason: '只做形态判定');
    });

    test('单 URL → 长度 1 的段列表（行为不变）', () {
      final segments = parseAudioPlaySegments('https://cdn.example.com/a.mp3');
      expect(segments, hasLength(1));
      expect(segments.single.url, 'https://cdn.example.com/a.mp3');
      expect(segments.single.headers, isEmpty);
    });

    test('JSON 数组 → 按序解析为多段', () {
      final segments = parseAudioPlaySegments(
        jsonEncode([
          'https://cdn.example.com/1.mp3',
          'https://cdn.example.com/2.mp3',
          'https://cdn.example.com/3.mp3',
        ]),
      );
      expect(segments.map((s) => s.url), [
        'https://cdn.example.com/1.mp3',
        'https://cdn.example.com/2.mp3',
        'https://cdn.example.com/3.mp3',
      ]);
    });

    test('数组元素带 ,{json} UrlOption → 段内 headers 生效', () {
      final segments = parseAudioPlaySegments(
        jsonEncode([
          'https://cdn.example.com/1.mp3',
          'https://cdn.example.com/2.m3u8,{"headers":{"Referer":"https://x/"}}',
        ]),
      );
      expect(segments, hasLength(2));
      expect(segments[0].headers, isEmpty);
      expect(segments[1].url, 'https://cdn.example.com/2.m3u8');
      expect(segments[1].headers, {'Referer': 'https://x/'});
    });

    test('章级 headers 叠加到每段，段内选项优先', () {
      final segments = parseAudioPlaySegments(
        jsonEncode([
          'https://cdn.example.com/1.mp3',
          'https://cdn.example.com/2.mp3,{"headers":{"Referer":"https://x/"}}',
        ]),
        chapterHeaders: {'User-Agent': 'UA', 'Referer': 'https://chapter/'},
      );
      expect(segments[0].headers, {
        'User-Agent': 'UA',
        'Referer': 'https://chapter/',
      });
      expect(segments[1].headers, {
        'User-Agent': 'UA',
        'Referer': 'https://x/',
      });
    });

    test('数组内非字符串/空串元素被丢弃', () {
      final segments = parseAudioPlaySegments(
        jsonEncode(['https://cdn/1.mp3', '', 42, '  ', 'https://cdn/2.mp3']),
      );
      expect(segments.map((s) => s.url), [
        'https://cdn/1.mp3',
        'https://cdn/2.mp3',
      ]);
    });

    test('形似数组但语法非法 → 空列表（调用方报「未获取到资源链接」）', () {
      expect(parseAudioPlaySegments('[not json]'), isEmpty);
      expect(parseAudioPlaySegments('[""]'), isEmpty);
      expect(parseAudioPlaySegments('[]'), isEmpty);
      expect(parseAudioPlaySegments(''), isEmpty);
    });
  });

  // ===== 2. 串播状态机（播放链）=====
  group('串播链：多段音频播放', () {
    late MockRustApi mockApi;
    late FakeStreamAudioPlayer fakePlayer;
    late ProviderContainer container;

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

    /// 音频书取址桩：第 0 章为多段/单段由 [mediaUrls] 决定，其余章单段
    void stubAudioBook({
      required List<String> mediaUrls,
      Map<String, dynamic>? headers,
      int chapterCount = 2,
    }) {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => List<BookChapter>.generate(
          chapterCount,
          (i) => BookChapter(title: 'ch$i', index: i),
        ),
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer((
        invocation,
      ) async {
        final index = invocation.positionalArguments[1] as int;
        if (index == 0) {
          return {
            'mediaUrl': mediaUrls.length == 1
                ? mediaUrls.single
                : jsonEncode(mediaUrls),
            'isVolume': false,
            'headers': ?headers,
          };
        }
        return {
          'mediaUrl': 'https://cdn.example.com/ch$index.mp3',
          'isVolume': false,
        };
      });
      when(() => mockApi.getAudioProgress(any(), any()))
          .thenAnswer((_) async => null);
      when(
        () => mockApi.saveAudioProgress(any(), any(), any()),
      ).thenAnswer((_) async {});
    }

    Future<void> startStream() async {
      await readNotifier().loadChapters('url');
      readNotifier().setAudioBookMode(true);
      await readNotifier().play();
    }

    const urls = [
      'https://cdn.example.com/1.mp3',
      'https://cdn.example.com/2.mp3',
      'https://cdn.example.com/3.mp3',
    ];

    testWidgets('3 段依次播放，顺序正确；未到末段不切章', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.playedUrls, [urls[0]]);

      // 第 1 段播完 → 进入间隙（不立即起播）
      fakePlayer.completePlayback();
      await tester.pump();
      expect(fakePlayer.playedUrls, [urls[0]], reason: '间隙内不得起播下一段');

      await tester.pump(const Duration(milliseconds: kMultiSegmentAudioGapMs));
      await tester.pump();
      expect(fakePlayer.playedUrls, [urls[0], urls[1]]);
      expect(readState().currentIndex, 0, reason: '多段未播完不得切章');

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: kMultiSegmentAudioGapMs));
      await tester.pump();
      expect(fakePlayer.playedUrls, urls);
      expect(readState().currentIndex, 0);
      expect(readState().state, PlayerState.playing);

      // 末段播完 → 走章末流程（切下一章）
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readState().currentIndex, 1);
      expect(fakePlayer.playedUrls.last, 'https://cdn.example.com/ch1.mp3');
    });

    testWidgets('段间间隙为 3000ms（2999ms 不起播，3000ms 起播）', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump(
        const Duration(milliseconds: kMultiSegmentAudioGapMs - 1),
      );
      expect(fakePlayer.playedUrls, hasLength(1), reason: '未到间隙终点');

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(fakePlayer.playedUrls, hasLength(2));
    });

    testWidgets('间隙中暂停 → 不继续；恢复从下一段续播（不重播第 1 段）', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();

      fakePlayer.completePlayback();
      await tester.pump();
      expect(readState().state, PlayerState.playing);

      readNotifier().pause();
      await tester.pump();
      expect(readState().state, PlayerState.paused);

      await tester.pump(const Duration(seconds: 5));
      expect(fakePlayer.playedUrls, hasLength(1), reason: '暂停后不得起播下一段');

      await readNotifier().resumeOrPlay();
      await tester.pump();
      expect(fakePlayer.playedUrls, [urls[0], urls[1]]);
      expect(readState().state, PlayerState.playing);
    });

    testWidgets('播放中暂停 → 不推进；恢复沿用播放器 resume（同段）', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();

      readNotifier().pause();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(fakePlayer.playedUrls, hasLength(1));

      await readNotifier().resumeOrPlay();
      await tester.pump();
      expect(fakePlayer.playedUrls, hasLength(1), reason: '同段恢复不重新装载');
      expect(fakePlayer.resumeCount, 1);
    });

    testWidgets('间隙中停止 → 不继续', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();

      fakePlayer.completePlayback();
      await tester.pump();
      readNotifier().stop();
      await tester.pump();

      await tester.pump(const Duration(seconds: 5));
      expect(fakePlayer.playedUrls, hasLength(1));
      expect(readState().state, PlayerState.idle);
    });

    testWidgets('间隙中切章 → 旧串播链终止，新章正常起播', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();

      fakePlayer.completePlayback();
      await tester.pump();

      await readNotifier().next();
      await tester.pump();
      expect(readState().currentIndex, 1);
      expect(fakePlayer.playedUrls.last, 'https://cdn.example.com/ch1.mp3');

      final countAfterSwitch = fakePlayer.playedUrls.length;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(
        fakePlayer.playedUrls,
        hasLength(countAfterSwitch),
        reason: '旧章第 2 段不得在新章起播',
      );
      expect(readState().currentIndex, 1);
    });

    testWidgets('播放中切章（未进间隙）→ 旧段完成回调被丢弃', (tester) async {
      stubAudioBook(mediaUrls: urls);
      await startStream();
      final oldTag = fakePlayer.currentTag;

      await readNotifier().next();
      await tester.pump();
      expect(readState().currentIndex, 1);

      final countAfterSwitch = fakePlayer.playedUrls.length;
      // 旧段完成事件迟到送达
      fakePlayer.completePlaybackForTag(oldTag);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(fakePlayer.playedUrls, hasLength(countAfterSwitch));
      expect(readState().currentIndex, 1);
    });

    testWidgets('单 URL（非数组）行为不变：不进入串播、完成即切章', (tester) async {
      stubAudioBook(mediaUrls: ['https://cdn.example.com/single.mp3']);
      await startStream();

      expect(fakePlayer.playedUrls, ['https://cdn.example.com/single.mp3']);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readState().currentIndex, 1, reason: '单段完成应直接走章末流程');
      expect(fakePlayer.playedUrls.last, 'https://cdn.example.com/ch1.mp3');
    });

    testWidgets('每段 headers / formatHint 正确传递', (tester) async {
      stubAudioBook(
        mediaUrls: [
          'https://cdn.example.com/1.m3u8',
          'https://cdn.example.com/2.mp3,{"headers":{"Referer":"https://seg/"}}',
        ],
        headers: {'User-Agent': 'LegadoTest/1.0'},
      );
      await startStream();

      expect(fakePlayer.playedUrls.first, 'https://cdn.example.com/1.m3u8');
      expect(fakePlayer.playedUrlFormatHints.first, VideoFormat.hls);
      expect(fakePlayer.playedUrlHeaders.first, {
        'User-Agent': 'LegadoTest/1.0',
      });

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: kMultiSegmentAudioGapMs));
      await tester.pump();

      expect(fakePlayer.playedUrls.last, 'https://cdn.example.com/2.mp3');
      expect(
        fakePlayer.playedUrlFormatHints.last,
        isNull,
        reason: '普通 mp3 不得传 HLS hint',
      );
      expect(fakePlayer.playedUrlHeaders.last, {
        'User-Agent': 'LegadoTest/1.0',
        'Referer': 'https://seg/',
      });
    });

    testWidgets('畸形数组地址 → error 态 + 用户可见提示', (tester) async {
      stubAudioBook(mediaUrls: ['[not json]']);
      await startStream();

      expect(readState().state, PlayerState.error);
      expect(readState().errorMessage, '未获取到资源链接');
      expect(fakePlayer.playedUrls, isEmpty);
    });

    testWidgets('跨段进度按章累计（不倒退到段首）', (tester) async {
      stubAudioBook(mediaUrls: urls);
      fakePlayer.loadedDuration = const Duration(seconds: 10);
      await startStream();

      // 第 1 段播到 4s
      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(seconds: 10),
      );
      await tester.pump();
      expect(readState().positionMs, 4000);

      // 第 1 段播完 → 累计 10s
      fakePlayer.completePlayback();
      await tester.pump();
      expect(readState().positionMs, 10000);

      await tester.pump(const Duration(milliseconds: kMultiSegmentAudioGapMs));
      await tester.pump();

      // 第 2 段播到 2s → 章累计 12s
      fakePlayer.emitProgress(
        const Duration(seconds: 2),
        const Duration(seconds: 10),
      );
      await tester.pump();
      expect(readState().positionMs, 12000);
      expect(
        readState().durationMs,
        20000,
        reason: '时长下界估计 = 已播完段累计(10s) + 当前段时长(10s)，随段推进单调增长',
      );
    });

    testWidgets('间隙中暂停写进度不双计（播放器仍停在已累计的上一段）', (tester) async {
      stubAudioBook(mediaUrls: urls);
      fakePlayer.loadedDuration = const Duration(seconds: 10);
      await startStream();

      fakePlayer.completePlayback();
      await tester.pump();

      // 播放器位置仍是上一段末尾（10s），累计已含该段 → 写库不得变成 20s
      fakePlayer.position = const Duration(seconds: 10);
      readNotifier().pause();
      await tester.pump();
      await tester.pump();

      final saved = verify(
        () => mockApi.saveAudioProgress('url', 0, captureAny()),
      ).captured.cast<int>();
      expect(saved, isNotEmpty);
      expect(
        saved.last,
        10000,
        reason: '间隙暂停不得把上一段末尾重复计入进度',
      );
    });

    testWidgets('多段章节不恢复存量进度，恒从第 1 段起播', (tester) async {
      stubAudioBook(mediaUrls: urls);
      when(() => mockApi.getAudioProgress(any(), any())).thenAnswer(
        (_) async => {'position': 20000},
      );
      await startStream();

      expect(fakePlayer.playedUrls, [urls[0]]);
      expect(fakePlayer.seekCount, 0, reason: '多段不 seek 到存量位置');
    });
  });
}
