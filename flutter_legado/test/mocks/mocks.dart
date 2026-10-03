/// 单元测试 Mock 定义
///
/// 使用 mocktail 生成 RustApi / AudioService / http.Client 的 mock 实例，
/// 供 Providers / Services 层测试使用。
library;

import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/stream_audio_player.dart';
import 'package:flutter_legado/src/models/models.dart';

/// RustApi 的 mock 实现
class MockRustApi extends Mock implements RustApi {}

/// AudioService 的 mock 实现
class MockAudioService extends Mock implements AudioService {}

/// StreamAudioPlayer 的 Fake 实现（A1 批 TTS 本地播放链测试）
///
/// 记录网络/本地播放调用，由测试经 [completePlayback] 手动触发完成回调，
/// 便于验证「完成回调驱动段落推进」而非估算 Timer。
class FakeStreamAudioPlayer implements StreamAudioPlayer {
  final List<String> playedUrls = [];
  final List<({String path, double speed})> playedLocalFiles = [];
  int stopCount = 0;
  int pauseCount = 0;
  int resumeCount = 0;
  int disposeCount = 0;
  int seekCount = 0;
  Duration? lastSeekPosition;

  @override
  bool isInitialized = false;
  @override
  bool isPlaying = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  @override
  String? currentUrl;
  @override
  void Function(Object? tag)? onCompleted;
  @override
  void Function(Duration position, Duration duration, Object? tag)? onProgress;

  /// 当前装载绑定的归属标识（模拟真实播放器闭包捕获的 tag，stop 后清空）
  Object? currentTag;

  /// 每次 playUrl/playLocalFile 绑定的归属标识（供测试取旧章 tag 模拟迟到回调）
  final List<Object?> playedTags = [];

  /// 置为非零后，playUrl/playLocalFile 时模拟播放器已解析出的媒体时长
  Duration loadedDuration = Duration.zero;

  /// 置为非空后 [playLocalFile] 抛出该异常（模拟本地文件播放失败）
  Object? playLocalError;

  /// 置为非空后 [playUrl] 抛出该异常（模拟网络流播放失败）
  Object? playUrlError;

  @override
  Future<void> playUrl(String url, {double speed = 1.0, Object? tag}) async {
    final err = playUrlError;
    if (err != null) throw err;
    playedUrls.add(url);
    playedTags.add(tag);
    currentTag = tag;
    duration = loadedDuration;
    isPlaying = true;
    isInitialized = true;
    currentUrl = url;
  }

  @override
  Future<void> playLocalFile(
    String path, {
    double speed = 1.0,
    Object? tag,
  }) async {
    final err = playLocalError;
    if (err != null) throw err;
    playedLocalFiles.add((path: path, speed: speed));
    playedTags.add(tag);
    currentTag = tag;
    duration = loadedDuration;
    isPlaying = true;
    isInitialized = true;
    currentUrl = path;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    isPlaying = false;
  }

  @override
  Future<void> resume() async {
    resumeCount++;
    isPlaying = true;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> seek(Duration position) async {
    seekCount++;
    lastSeekPosition = position;
    this.position = position;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    isPlaying = false;
    isInitialized = false;
    currentUrl = null;
    currentTag = null;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    isPlaying = false;
    isInitialized = false;
  }

  /// 模拟当前音频自然播完（video_player 完成事件 → onCompleted 回调，
  /// 携带本次装载的归属标识）
  void completePlayback() {
    isPlaying = false;
    onCompleted?.call(currentTag);
  }

  /// 模拟迟到的旧章完成回调（携带旧章归属标识，不改变当前归属）
  void completePlaybackForTag(Object? tag) {
    isPlaying = false;
    onCompleted?.call(tag);
  }

  /// 模拟播放器上报进度（video_player 位置回调 → onProgress，
  /// 携带本次装载的归属标识）
  void emitProgress(Duration position, Duration duration) {
    this.position = position;
    this.duration = duration;
    onProgress?.call(position, duration, currentTag);
  }

  /// 模拟迟到的旧章进度回调（携带旧章归属标识，不改变当前归属）
  void emitProgressForTag(Object? tag, Duration position, Duration duration) {
    this.position = position;
    this.duration = duration;
    onProgress?.call(position, duration, tag);
  }
}

/// http.Client 的 mock 实现
class MockHttpClient extends Mock implements http.Client {}

/// http.Response 的 mock 实现
class MockHttpResponse extends Mock implements http.Response {}

/// Book 的 Fake 实现（用于 registerFallbackValue）
class FakeBook extends Fake implements Book {}

/// RssSource 的 Fake 实现
class FakeRssSource extends Fake implements RssSource {}

/// HttpTts 的 Fake 实现（D3 种子导入测试的 any() fallback）
class FakeHttpTts extends Fake implements HttpTts {}

/// BookSource 的 Fake 实现
class FakeBookSource extends Fake implements BookSource {}

/// Bookmark 的 Fake 实现
class FakeBookmark extends Fake implements Bookmark {}

/// ReplaceRule 的 Fake 实现
class FakeReplaceRule extends Fake implements ReplaceRule {}

/// Uri 的 Fake 实现
class FakeUri extends Fake implements Uri {}

/// 注册所有 fallback 值（在 setUpAll 中调用）
void registerFallbacks() {
  registerFallbackValue(FakeBook());
  registerFallbackValue(FakeRssSource());
  registerFallbackValue(FakeHttpTts());
  registerFallbackValue(FakeBookSource());
  registerFallbackValue(FakeBookmark());
  registerFallbackValue(FakeReplaceRule());
  registerFallbackValue(const BookGroup());
  registerFallbackValue(FakeUri());
}
