// [V-B3 审查收口 W1/W2/W4] 视频页悬浮窗移交行为回归：
// - W1：移交原生前确定性暂停 Flutter 播放器（消除双播放器并行发声窗口）；
// - W2：非 Android 隐藏悬浮窗按钮（桌面降级全屏页）；
// - W2/W4：启动失败按原因分流提示（权限引导 / FGS 后台受限 / 其他）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/video_screen.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/video_float_window.dart';
import 'package:flutter_legado/src/utils/video_progress.dart';
import 'package:flutter_legado/src/widgets/video_float_window_button.dart';
import 'package:flutter_legado/src/widgets/video_settings_dialog.dart';

/// 最小 Fake 视频平台：记录 play/pause 调用，创建时投递 initialized 事件。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<int> playCalls = [];
  final List<int> pauseCalls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final controller = StreamController<VideoEvent>();
    _events[id] = controller;
    controller.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 60),
        size: const Size(16, 9),
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
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls.add(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Color(0xFF000000));
}

/// 假悬浮窗桥：记录 show / requestOverlayPermission 调用，可注入失败错误码。
class _FakeFloatBridge extends VideoFloatWindowBridge {
  final List<VideoFloatWindowState> shown = [];
  final List<String> calls = [];
  bool showResult = true;
  String? errorCode;

  /// 测试环境无平台通道应答，基类实现会永久等待：显式返回「无活动悬浮窗」
  @override
  Future<VideoFloatWindowState?> getState() async => null;

  @override
  Future<bool> show(VideoFloatWindowState state) async {
    shown.add(state);
    calls.add('show');
    if (showResult) {
      lastShowError = null;
      return true;
    }
    lastShowError = errorCode;
    return false;
  }

  @override
  Future<void> requestOverlayPermission() async {
    calls.add('requestOverlayPermission');
  }
}

class _FakeBookApi implements BookApi {
  /// config/caches 键值（直链 progress 走 video_pos_ 逻辑键）
  final Map<String, String> configs = {};

  /// updateReadingProgress 的 chapterPos 序列（书籍模式进度写回记录）
  final List<int> progressWrites = [];

  @override
  Future<String?> getConfig(String key) async => configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    configs[key] = value;
  }

  @override
  Future<void> deleteConfig(String key) async {
    configs.remove(key);
  }

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => [
        BookChapter(
          url: 'https://cdn.example/ch1',
          title: '第1集',
          index: 0,
          bookUrl: bookUrl,
        ),
      ];

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async =>
      'https://cdn.example/v1.m3u8';

  @override
  Future<String?> getVideoDanmaku({
    required String bookUrl,
    required int chapterIndex,
  }) async =>
      null;

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    progressWrites.add(chapterPos);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVideoPlayerPlatform platform;
  late _FakeFloatBridge bridge;
  late _FakeBookApi api;
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    bridge = _FakeFloatBridge()..supportedOverride = true;
    VideoFloatWindowBridge.instance = bridge;
    VideoFloatWindowCoordinator.instance =
        VideoFloatWindowCoordinator(bridge: bridge);
    api = _FakeBookApi();
    navKey = GlobalKey<NavigatorState>();
  });

  /// 推入指定 VideoScreen 并等待起播完成。
  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    await tester.pumpAndSettle();
  }

  /// 推入一个直链 VideoScreen 并等待起播完成。
  /// [preset] true = 悬浮窗回全屏（presetUrl 已解析）；false = 常规首播
  /// （走 resolveVideoPlayTarget，默认悬浮窗判定在此路径触发）。
  Future<void> pumpVideoScreen(WidgetTester tester, {bool preset = true}) {
    return pumpScreen(
      tester,
      preset
          ? const VideoScreen(
              videoUrl: 'https://cdn.example/v.m3u8',
              title: '测试视频',
              presetUrl: 'https://cdn.example/v.m3u8',
            )
          : const VideoScreen(
              videoUrl: 'https://cdn.example/v.m3u8',
              title: '测试视频',
            ),
    );
  }

  testWidgets('W1 移交悬浮窗前暂停 Flutter 播放器', (tester) async {
    await pumpVideoScreen(tester);

    // 前置：控制器已起播（否则本测试无意义）
    expect(platform.playCalls, isNotEmpty);
    // 注意：video_player 初始化时内部会对未播放态调用一次平台 pause，
    // 故此处记录基线，只断言「移交动作本身」新增的暂停
    final pausesBefore = platform.pauseCalls.length;

    await tester.tap(find.byType(VideoFloatWindowButton));
    await tester.pumpAndSettle();

    // 移交已发生，且移交前播放器已确定性暂停
    expect(bridge.shown, hasLength(1));
    expect(platform.pauseCalls.length, greaterThan(pausesBefore));
  });

  testWidgets('W2 非 Android 不渲染悬浮窗按钮（降级全屏页）', (tester) async {
    bridge.supportedOverride = false;
    await pumpVideoScreen(tester);

    expect(find.byType(VideoFloatWindowButton), findsNothing);
  });

  testWidgets('W2/W4 无权限失败：引导系统设置页', (tester) async {
    bridge
      ..showResult = false
      ..errorCode = 'no_overlay_permission';
    await pumpVideoScreen(tester);

    await tester.tap(find.byType(VideoFloatWindowButton));
    await tester.pumpAndSettle();

    expect(bridge.shown, hasLength(1));
    expect(bridge.calls, contains('requestOverlayPermission'));
    expect(find.text('请允许「显示在其他应用上层」后重试'), findsOneWidget);
  });

  testWidgets('W2/W4 FGS 后台受限：提示回应用重试且不再引导权限', (tester) async {
    bridge
      ..showResult = false
      ..errorCode = 'background_start_rejected';
    await pumpVideoScreen(tester);

    await tester.tap(find.byType(VideoFloatWindowButton));
    await tester.pumpAndSettle();

    expect(bridge.shown, hasLength(1));
    expect(bridge.calls, isNot(contains('requestOverlayPermission')));
    expect(find.text('请回到应用内后重试'), findsOneWidget);
    expect(find.text('请允许「显示在其他应用上层」后重试'), findsNothing);
  });

  testWidgets('其他失败：中性提示（不误导为权限问题）', (tester) async {
    bridge
      ..showResult = false
      ..errorCode = 'start_service_failed';
    await pumpVideoScreen(tester);

    await tester.tap(find.byType(VideoFloatWindowButton));
    await tester.pumpAndSettle();

    expect(bridge.calls, isNot(contains('requestOverlayPermission')));
    expect(find.text('悬浮窗启动失败，请重试'), findsOneWidget);
  });

  // ===== [V-B3 补丁] defaultFloatWindow=true 首播：控制器创建前移交 =====
  // 对齐原版 VideoPlayerActivity.kt:177-193：Activity 不建播放器，直接把
  // Intent 转发 VideoPlayService（:229-248 isNew → startPlay），位置取持久化
  // 进度（video_pos_ / durChapterPos，VideoPlay.kt:143/166），播放态取
  // autoPlay（VideoPlay.kt:157 if (autoPlay) startPlayLogic()）。

  testWidgets('默认悬浮窗首播：控制器未创建即移交（不崩溃；进度/播放态取持久化）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      VideoPlaySettings.defaultFloatWindowKey: true,
    });
    api.configs[videoPosKey('https://cdn.example/v.m3u8')] = encodeVideoPos(
      30 * 1000,
      savedAt: DateTime.now(),
    );

    await pumpVideoScreen(tester, preset: false);

    expect(find.text('视频加载失败'), findsNothing);
    expect(bridge.shown, hasLength(1));
    final state = bridge.shown.single;
    expect(state.url, 'https://cdn.example/v.m3u8');
    // 控制器未创建：位置回退持久化进度（原版 seekOnStart 语义）
    expect(state.positionMs, 30 * 1000);
    expect(state.playing, isTrue);
    // 页面未创建本地播放器，且已移交退出
    expect(platform.playCalls, isEmpty);
    expect(find.byType(VideoScreen), findsNothing);
  });

  testWidgets('默认悬浮窗首播：移交失败降级本页播放（悬浮窗是优化非必须）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      VideoPlaySettings.defaultFloatWindowKey: true,
    });
    bridge
      ..showResult = false
      ..errorCode = 'start_service_failed';

    await pumpVideoScreen(tester, preset: false);

    expect(bridge.calls, contains('show'));
    expect(find.text('视频加载失败'), findsNothing);
    // 移交失败后正常起播本页播放器
    expect(platform.playCalls, isNotEmpty);
    expect(find.text('悬浮窗启动失败，请重试'), findsOneWidget);
  });

  testWidgets('默认悬浮窗首播：autoPlay=false 移交不自动播放（对齐原版 if(autoPlay)）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      VideoPlaySettings.defaultFloatWindowKey: true,
      VideoPlaySettings.autoPlayKey: false,
    });

    await pumpVideoScreen(tester, preset: false);

    expect(bridge.shown, hasLength(1));
    expect(bridge.shown.single.playing, isFalse);
  });

  testWidgets('默认悬浮窗首播（书籍）：移交位置落库，退出不覆盖成 0', (tester) async {
    SharedPreferences.setMockInitialValues({
      VideoPlaySettings.defaultFloatWindowKey: true,
    });

    await pumpScreen(
      tester,
      VideoScreen(
        videoUrl: 'https://cdn.example/v.m3u8',
        title: '测试视频',
        book: const Book(
          bookUrl: 'book://1',
          name: '测试书',
          origin: 'src://1',
          durChapterIndex: 0,
          durChapterPos: 30 * 1000,
        ),
      ),
    );

    expect(find.text('视频加载失败'), findsNothing);
    expect(bridge.shown, hasLength(1));
    expect(bridge.shown.single.positionMs, 30 * 1000);
    // 移交前落库 30000；退出时不得再以「无控制器」的 0 覆盖
    expect(api.progressWrites, [30 * 1000]);
  });
}
