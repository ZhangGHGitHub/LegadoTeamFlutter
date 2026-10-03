// D1 真机缺陷回归：底层 media3 播放器不得与 MediaSessionBridge 抢音频焦点。
//
// 背景（QA 证据 .tmp/tts_qa/logcat_focus_conflict.txt）：
//   MediaSessionBridge 先 requestAudioFocus(CONTENT_TYPE_MUSIC)，
//   video_player 的 media3 ExoPlayer 播放本地文件时再次 requestAudioFocus
//   (CONTENT_TYPE_MOVIE) → 同应用两个焦点客户端互抢 → 桥收到
//   onAudioFocusChange(-1)[LOSS] → Dart 误判外部抢占 pause()，播放 20ms 即停。
//
// 修复契约：StreamAudioPlayer 为每个控制器传
// `VideoPlayerOptions(mixWithOthers: true)`；video_player Android 实现将其
// 映射为 `ExoPlayer.setAudioAttributes(attrs, handleAudioFocus=false)`
// （见 video_player_android VideoPlayer.setAudioAttributes）。
// 本测试用 Fake VideoPlayerPlatform 截获真实的 setMixWithOthers 平台调用，
// 钉住「网络流 + 本地文件两条路径都不会让底层播放器接管焦点」。
//
// 注：直接 import platform_interface 仅用于测试 Fake（transitive 依赖，
// 非 pubspec 直接声明，按惯例 ignore lint）。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:flutter_legado/src/screens/video_screen.dart';
import 'package:flutter_legado/src/services/stream_audio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVideoPlayerPlatform fakePlatform;

  setUp(() {
    fakePlatform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakePlatform;
  });

  test('playbackOptions 关闭底层播放器焦点处理（mixWithOthers=true）', () {
    expect(StreamAudioPlayer.playbackOptions.mixWithOthers, isTrue);
  });

  test('视频页显式恢复底层播放器焦点处理（mixWithOthers=false）', () {
    // video_player 的 mixWithOthers 是插件级 sharedOptions（全局），
    // 听书/TTS 置 true 后，视频页必须显式置 false 才能保持默认焦点语义。
    expect(videoPlaybackOptions.mixWithOthers, isFalse);
  });

  test('playLocalFile：底层播放器收到 mixWithOthers=true（不抢焦点）', () async {
    final player = StreamAudioPlayer();
    await player.playLocalFile('/tmp/tts/para_1.wav');
    await player.dispose();

    expect(fakePlatform.mixWithOthersCalls, [true]);
    expect(fakePlatform.createdCount, 1);
  });

  test('playUrl（听书流模式同链路）：底层播放器收到 mixWithOthers=true', () async {
    final player = StreamAudioPlayer();
    await player.playUrl('https://cdn.example.com/ch1.mp3');
    await player.dispose();

    expect(fakePlatform.mixWithOthersCalls, [true]);
    expect(fakePlatform.createdCount, 1);
  });
}

/// 记录 setMixWithOthers / createWithOptions 的最小 Fake 平台实现。
///
/// initialize() 需要 initialized 事件才能完成，这里在创建时向单订阅
/// controller 预写一个 initialized 事件（listen 时缓冲投递）。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<bool> mixWithOthersCalls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  int createdCount = 0;
  int _nextId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {
    mixWithOthersCalls.add(mixWithOthers);
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    createdCount++;
    final id = _nextId++;
    final controller = StreamController<VideoEvent>();
    _events[id] = controller;
    controller.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 1),
        size: const Size(16, 16),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _events[playerId]?.stream ?? const Stream<VideoEvent>.empty();

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
}
