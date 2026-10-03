// P1 竞态修复测试（真机验收缺陷：章末切章时旧 position 写入新章进度键）
//
// 证据：.tmp/audio_qa/cascade_evidence.txt —— 第 N 章自然播完后，第 N+1 章
// 播放器启动 37-60ms 即被释放，DB 中 audio_progress 各章键全部等于第 1 章
// 结束位置（29913ms）。
// 机制：切章后 state.currentIndex 先切到新章，而旧播放器在 stop 前仍会回传
// 最终进度（position≈旧章时长）；该回调若按 state.currentIndex 归属，会写进
// 新章进度键，恢复逻辑读到 >1500ms 便 seek 到章尾 → 秒完 → 再切章，自持级联。
//
// 覆盖：
// a) 取址窗口内旧章最终 position 回调被丢弃（不写新章键、不刷新 UI）
// b) 切章后新章进度正常写新章键；旧章 tag 迟到回调仍被丢弃
// c) 恢复遇到接近章尾的历史污染值不 seek（从头播）；正常值仍 seek；
//    时长未知时保持既有恢复行为
// d) 迟到的旧章完成回调被丢弃，不误停新章
// e) 单曲循环清零逻辑回归（A3/A4 批行为不被破坏）
import 'dart:async';

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

  void stubTwoChapters() {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: 'ch1', index: 0),
        const BookChapter(title: 'ch2', index: 1),
      ],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer((
      invocation,
    ) async {
      final index = invocation.positionalArguments[1] as int;
      return {
        'mediaUrl': 'https://cdn.example.com/$index.mp3',
        'isVolume': false,
      };
    });
    when(
      () => mockApi.getAudioProgress(any(), any()),
    ).thenAnswer((_) async => null);
    when(
      () => mockApi.saveAudioProgress(any(), any(), any()),
    ).thenAnswer((_) async {});
  }

  Future<void> startStream() async {
    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  testWidgets('a) 切章取址窗口内旧章最终 position 回调被丢弃（不写新章键）', (tester) async {
    stubTwoChapters();
    // 第 2 章取址挂起：精确复现真机「currentIndex 已切新章、旧播放器仍存活」
    // 的取址窗口
    final ch2Media = Completer<Map<String, dynamic>>();
    when(
      () => mockApi.getAudioChapterMedia(any(), 1),
    ).thenAnswer((_) => ch2Media.future);

    await startStream();
    final oldTag = fakePlayer.currentTag;
    expect(oldTag, isNotNull);

    fakePlayer.emitProgress(
      const Duration(seconds: 2),
      const Duration(seconds: 30),
    );
    await tester.pump();
    verify(() => mockApi.saveAudioProgress('url', 0, 2000)).called(1);

    // 第 1 章自然播完 → 自动切章；第 2 章取址尚未返回
    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();
    expect(readState().currentIndex, 1);
    expect(fakePlayer.playedUrls, ['https://cdn.example.com/0.mp3']);

    // 旧播放器 stop 前的最终回调（position≈旧章时长）迟到送达
    fakePlayer.emitProgressForTag(
      oldTag,
      const Duration(milliseconds: 29913),
      const Duration(seconds: 30),
    );
    await tester.pump();

    verifyNever(() => mockApi.saveAudioProgress('url', 1, any()));
    // UI 位置未被旧章污染（取址窗口内仍为上一回调值 2000，而非 29913）
    expect(readState().positionMs, 2000);

    // 放行第 2 章取址：新章正常启动并可写入新章键
    ch2Media.complete({
      'mediaUrl': 'https://cdn.example.com/1.mp3',
      'isVolume': false,
    });
    await tester.pump();
    await tester.pump();
    expect(fakePlayer.playedUrls.last, 'https://cdn.example.com/1.mp3');

    fakePlayer.emitProgress(
      const Duration(seconds: 3),
      const Duration(seconds: 30),
    );
    await tester.pump();
    verify(() => mockApi.saveAudioProgress('url', 1, 3000)).called(1);

    readNotifier().stop();
  });

  testWidgets('b) 切章后新章进度写新章键；旧章 tag 迟到回调仍被丢弃', (tester) async {
    stubTwoChapters();
    await startStream();
    final oldTag = fakePlayer.currentTag;
    expect(oldTag, (bookUrl: 'url', chapterIndex: 0));

    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();
    expect(readState().currentIndex, 1);
    expect(fakePlayer.currentTag, (bookUrl: 'url', chapterIndex: 1));

    // 新章已启动后旧章 tag 的回调（防御性：真实播放器 stop 后不再回传）
    fakePlayer.emitProgressForTag(
      oldTag,
      const Duration(milliseconds: 29913),
      const Duration(seconds: 30),
    );
    await tester.pump();
    verifyNever(() => mockApi.saveAudioProgress('url', 1, 29913));

    fakePlayer.emitProgress(
      const Duration(seconds: 3),
      const Duration(seconds: 30),
    );
    await tester.pump();
    verify(() => mockApi.saveAudioProgress('url', 1, 3000)).called(1);

    readNotifier().stop();
  });

  testWidgets('c1) 恢复遇到接近章尾的历史污染值：不 seek，从头播', (tester) async {
    stubTwoChapters();
    fakePlayer.loadedDuration = const Duration(seconds: 30);
    // 污染值：与 QA 证据一致（第 1 章完成位置 29913 落到其它章键）
    when(
      () => mockApi.getAudioProgress('url', 0),
    ).thenAnswer((_) async => {'position': 29913, 'chapterIndex': 0});

    await startStream();

    expect(fakePlayer.seekCount, 0);
    expect(readState().positionMs, 0);

    readNotifier().stop();
  });

  testWidgets('c2) 恢复遇到章中正常进度：保持既有 seek 行为', (tester) async {
    stubTwoChapters();
    fakePlayer.loadedDuration = const Duration(seconds: 30);
    when(
      () => mockApi.getAudioProgress('url', 0),
    ).thenAnswer((_) async => {'position': 10000, 'chapterIndex': 0});

    await startStream();

    expect(fakePlayer.seekCount, 1);
    expect(fakePlayer.lastSeekPosition, const Duration(seconds: 10));

    readNotifier().stop();
  });

  testWidgets('c3) 时长未知时不判定接近章尾，保持既有恢复行为', (tester) async {
    stubTwoChapters();
    // loadedDuration 保持 0：模拟播放器未解析出时长
    when(
      () => mockApi.getAudioProgress('url', 0),
    ).thenAnswer((_) async => {'position': 29913, 'chapterIndex': 0});

    await startStream();

    expect(fakePlayer.seekCount, 1);
    expect(fakePlayer.lastSeekPosition, const Duration(milliseconds: 29913));

    readNotifier().stop();
  });

  testWidgets('d) 迟到的旧章完成回调被丢弃，不误停新章', (tester) async {
    stubTwoChapters();
    await startStream();
    final oldTag = fakePlayer.currentTag;

    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();
    expect(readState().currentIndex, 1);
    expect(readState().state, PlayerState.playing);

    // 旧章完成回调迟到：不得触发 _onStreamCompleted 把新章停掉
    fakePlayer.completePlaybackForTag(oldTag);
    await tester.pump();

    expect(readState().currentIndex, 1);
    expect(readState().state, PlayerState.playing);

    readNotifier().stop();
  });

  testWidgets('e) 单曲循环：章末清零当前章进度并从头重播（A3 行为回归）', (tester) async {
    stubTwoChapters();
    await startStream();
    readNotifier().setMode(AudioPlayMode.singleLoop);

    fakePlayer.emitProgress(
      const Duration(seconds: 21),
      const Duration(seconds: 30),
    );
    await tester.pump();

    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();

    // 清零 + 重播同一章
    verify(() => mockApi.saveAudioProgress('url', 0, 0)).called(1);
    expect(readState().currentIndex, 0);
    expect(readState().state, PlayerState.playing);
    expect(fakePlayer.playedUrls.length, 2);

    readNotifier().stop();
  });
}
