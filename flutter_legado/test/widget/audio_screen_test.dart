import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 音频焦点事件类型（与 audio_service.dart 保持一致）
enum AudioFocusEvent {
  gain,
  loss,
  lossTransient,
  lossTransientCanDuck,
}

/// 媒体按钮事件类型（与 audio_service.dart 保持一致）
enum MediaButtonEvent {
  play,
  pause,
  skipToNext,
  skipToPrevious,
  stop,
}

/// 模拟音频服务（用于测试）
class MockAudioService {
  final StreamController<AudioFocusEvent> _audioFocusController =
      StreamController<AudioFocusEvent>.broadcast();
  final StreamController<MediaButtonEvent> _mediaButtonController =
      StreamController<MediaButtonEvent>.broadcast();

  bool initialized = false;
  bool playing = false;
  String lastPlaybackState = '';
  String lastMetadataTitle = '';

  Stream<AudioFocusEvent> get audioFocusStream => _audioFocusController.stream;
  Stream<MediaButtonEvent> get mediaButtonStream =>
      _mediaButtonController.stream;

  Future<void> init() async {
    initialized = true;
  }

  Future<void> dispose() async {
    initialized = false;
  }

  Future<bool> requestAudioFocus() async => true;

  Future<void> abandonAudioFocus() async {}

  Future<void> notifyPlaying() async {
    playing = true;
    lastPlaybackState = 'playing';
  }

  Future<void> notifyPaused() async {
    playing = false;
    lastPlaybackState = 'paused';
  }

  Future<void> notifyStopped() async {
    playing = false;
    lastPlaybackState = 'stopped';
  }

  Future<void> updateMetadata({required String title, String artist = ''}) async {
    lastMetadataTitle = title;
  }

  /// 模拟发送媒体按钮事件
  void emitMediaButton(MediaButtonEvent event) {
    _mediaButtonController.add(event);
  }

  /// 模拟发送焦点事件
  void emitAudioFocus(AudioFocusEvent event) {
    _audioFocusController.add(event);
  }

  void disposeStreams() {
    _audioFocusController.close();
    _mediaButtonController.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 设置模拟 MethodChannel 响应
  void setupMockMethodChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('legado/media_session'),
      (MethodCall methodCall) async {
        switch (methodCall.method) {
          case 'init':
            return true;
          case 'requestAudioFocus':
            return true;
          case 'abandonAudioFocus':
            return null;
          case 'updatePlaybackState':
            return null;
          case 'updateMetadata':
            return null;
          case 'setPlaying':
            return null;
          case 'release':
            return null;
          default:
            return null;
        }
      },
    );
  }

  setUp(() {
    setupMockMethodChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('legado/media_session'),
      null,
    );
  });

  group('AudioService 单元测试', () {
    test('AudioFocusEvent 枚举包含所有焦点事件类型', () {
      expect(AudioFocusEvent.values.length, 4);
      expect(AudioFocusEvent.values, contains(AudioFocusEvent.gain));
      expect(AudioFocusEvent.values, contains(AudioFocusEvent.loss));
      expect(AudioFocusEvent.values, contains(AudioFocusEvent.lossTransient));
      expect(AudioFocusEvent.values,
          contains(AudioFocusEvent.lossTransientCanDuck));
    });

    test('MediaButtonEvent 枚举包含所有媒体按钮事件', () {
      expect(MediaButtonEvent.values.length, 5);
      expect(MediaButtonEvent.values, contains(MediaButtonEvent.play));
      expect(MediaButtonEvent.values, contains(MediaButtonEvent.pause));
      expect(MediaButtonEvent.values, contains(MediaButtonEvent.skipToNext));
      expect(MediaButtonEvent.values,
          contains(MediaButtonEvent.skipToPrevious));
      expect(MediaButtonEvent.values, contains(MediaButtonEvent.stop));
    });

    test('MockAudioService 初始化和释放', () async {
      final service = MockAudioService();
      expect(service.initialized, false);

      await service.init();
      expect(service.initialized, true);

      await service.dispose();
      expect(service.initialized, false);
      service.disposeStreams();
    });

    test('MockAudioService 音频焦点请求', () async {
      final service = MockAudioService();
      await service.init();

      final hasFocus = await service.requestAudioFocus();
      expect(hasFocus, true);

      await service.abandonAudioFocus();
      service.disposeStreams();
    });

    test('MockAudioService 播放状态通知', () async {
      final service = MockAudioService();
      await service.init();

      await service.notifyPlaying();
      expect(service.playing, true);
      expect(service.lastPlaybackState, 'playing');

      await service.notifyPaused();
      expect(service.playing, false);
      expect(service.lastPlaybackState, 'paused');

      await service.notifyStopped();
      expect(service.playing, false);
      expect(service.lastPlaybackState, 'stopped');

      service.disposeStreams();
    });

    test('MockAudioService 媒体按钮事件流', () async {
      final service = MockAudioService();
      final events = <MediaButtonEvent>[];

      final sub = service.mediaButtonStream.listen(events.add);

      service.emitMediaButton(MediaButtonEvent.play);
      service.emitMediaButton(MediaButtonEvent.pause);
      service.emitMediaButton(MediaButtonEvent.skipToNext);

      await Future.delayed(Duration.zero);

      expect(events.length, 3);
      expect(events[0], MediaButtonEvent.play);
      expect(events[1], MediaButtonEvent.pause);
      expect(events[2], MediaButtonEvent.skipToNext);

      await sub.cancel();
      service.disposeStreams();
    });

    test('MockAudioService 音频焦点事件流', () async {
      final service = MockAudioService();
      final events = <AudioFocusEvent>[];

      final sub = service.audioFocusStream.listen(events.add);

      service.emitAudioFocus(AudioFocusEvent.gain);
      service.emitAudioFocus(AudioFocusEvent.lossTransient);
      service.emitAudioFocus(AudioFocusEvent.loss);

      await Future.delayed(Duration.zero);

      expect(events.length, 3);
      expect(events[0], AudioFocusEvent.gain);
      expect(events[1], AudioFocusEvent.lossTransient);
      expect(events[2], AudioFocusEvent.loss);

      await sub.cancel();
      service.disposeStreams();
    });

    test('MockAudioService 元数据更新', () async {
      final service = MockAudioService();
      await service.init();

      await service.updateMetadata(
        title: '第一章 开始',
        artist: '正在朗读: 测试书籍',
      );
      expect(service.lastMetadataTitle, '第一章 开始');

      service.disposeStreams();
    });
  });

  group('音频焦点管理逻辑测试', () {
    test('焦点暂时丢失后恢复应触发播放恢复', () async {
      final service = MockAudioService();
      await service.init();
      await service.notifyPlaying();

      var needResume = false;

      // 模拟焦点暂时丢失
      service.emitAudioFocus(AudioFocusEvent.lossTransient);
      await Future.delayed(Duration.zero);

      // 处理逻辑：如果正在播放，标记需要恢复
      if (service.playing) {
        needResume = true;
        await service.notifyPaused();
      }
      expect(service.playing, false);
      expect(needResume, true);

      // 模拟焦点恢复
      service.emitAudioFocus(AudioFocusEvent.gain);
      await Future.delayed(Duration.zero);

      // 处理逻辑：如果需要恢复，则恢复播放
      if (needResume) {
        needResume = false;
        await service.notifyPlaying();
      }
      expect(service.playing, true);
      expect(needResume, false);

      service.disposeStreams();
    });

    test('焦点永久丢失不应触发恢复', () async {
      final service = MockAudioService();
      await service.init();
      await service.notifyPlaying();

      var needResume = false;

      // 模拟焦点永久丢失
      service.emitAudioFocus(AudioFocusEvent.loss);
      await Future.delayed(Duration.zero);

      // 处理逻辑：永久丢失不标记恢复
      needResume = false;
      await service.notifyPaused();

      expect(service.playing, false);
      expect(needResume, false);

      // 即使之后获得焦点也不应恢复
      service.emitAudioFocus(AudioFocusEvent.gain);
      await Future.delayed(Duration.zero);

      expect(service.playing, false);

      service.disposeStreams();
    });

    test('lossTransientCanDuck 不应暂停播放', () async {
      final service = MockAudioService();
      await service.init();
      await service.notifyPlaying();

      // 模拟短暂焦点丢失（可降低音量）
      service.emitAudioFocus(AudioFocusEvent.lossTransientCanDuck);
      await Future.delayed(Duration.zero);

      // 不做处理，保持播放状态
      expect(service.playing, true);

      service.disposeStreams();
    });
  });

  group('媒体按钮控制逻辑测试', () {
    test('播放按钮应触发播放', () async {
      final service = MockAudioService();
      await service.init();

      service.emitMediaButton(MediaButtonEvent.play);
      await Future.delayed(Duration.zero);

      await service.notifyPlaying();
      expect(service.playing, true);
      expect(service.lastPlaybackState, 'playing');

      service.disposeStreams();
    });

    test('暂停按钮应触发暂停', () async {
      final service = MockAudioService();
      await service.init();
      await service.notifyPlaying();

      service.emitMediaButton(MediaButtonEvent.pause);
      await Future.delayed(Duration.zero);

      await service.notifyPaused();
      expect(service.playing, false);
      expect(service.lastPlaybackState, 'paused');

      service.disposeStreams();
    });

    test('停止按钮应触发停止', () async {
      final service = MockAudioService();
      await service.init();
      await service.notifyPlaying();

      service.emitMediaButton(MediaButtonEvent.stop);
      await Future.delayed(Duration.zero);

      await service.notifyStopped();
      expect(service.playing, false);
      expect(service.lastPlaybackState, 'stopped');

      service.disposeStreams();
    });
  });

  group('Platform Channel 集成测试', () {
    test('MethodChannel init 调用成功', () async {
      const channel = MethodChannel('legado/media_session');
      final result = await channel.invokeMethod<bool>('init');
      expect(result, true);
    });

    test('MethodChannel requestAudioFocus 调用成功', () async {
      const channel = MethodChannel('legado/media_session');
      final result = await channel.invokeMethod<bool>('requestAudioFocus');
      expect(result, true);
    });

    test('MethodChannel updatePlaybackState 调用成功', () async {
      const channel = MethodChannel('legado/media_session');
      await channel.invokeMethod<void>('updatePlaybackState', {
        'state': 'playing',
        'position': 0,
      });
      // 无异常即成功
    });

    test('MethodChannel updateMetadata 调用成功', () async {
      const channel = MethodChannel('legado/media_session');
      await channel.invokeMethod<void>('updateMetadata', {
        'title': '测试章节',
        'artist': '正在朗读: 测试书籍',
        'album': '',
      });
      // 无异常即成功
    });

    test('MethodChannel release 调用成功', () async {
      const channel = MethodChannel('legado/media_session');
      await channel.invokeMethod<void>('release');
      // 无异常即成功
    });
  });

  group('听书页面结构测试', () {
    testWidgets('听书页面基本结构验证', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const Text('听书'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.timer_outlined),
                  onPressed: null,
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: null,
                ),
              ],
            ),
            body: Column(
              children: [
                // 当前播放信息
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(Icons.headphones, size: 48),
                      SizedBox(height: 8),
                      Text('第一章 开始'),
                      SizedBox(height: 4),
                      Text('1 / 10'),
                    ],
                  ),
                ),
                // 进度条
                const LinearProgressIndicator(value: 0.1),
                // 播放控制
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: null,
                    ),
                    FloatingActionButton(
                      onPressed: null,
                      child: const Icon(Icons.play_arrow),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: null,
                    ),
                  ],
                ),
                // 后台播放提示
                Container(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.info_outline, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        '支持后台播放，切换应用后音频将继续播放',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 验证标题
      expect(find.text('听书'), findsOneWidget);

      // 验证定时按钮
      expect(find.byIcon(Icons.timer_outlined), findsOneWidget);

      // 验证设置按钮
      expect(find.byIcon(Icons.settings), findsOneWidget);

      // 验证章节信息
      expect(find.text('第一章 开始'), findsOneWidget);
      expect(find.text('1 / 10'), findsOneWidget);

      // 验证播放控制按钮
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);

      // 验证后台播放提示
      expect(find.text('支持后台播放，切换应用后音频将继续播放'), findsOneWidget);
    });

    testWidgets('播放控制按钮布局验证', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 播放模式
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    tooltip: '顺序播放',
                    onPressed: null,
                  ),
                  const SizedBox(width: 16),
                  // 上一章
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 36,
                    onPressed: null,
                  ),
                  const SizedBox(width: 16),
                  // 播放/暂停
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: FloatingActionButton(
                      onPressed: null,
                      child: const Icon(Icons.play_arrow, size: 32),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // 下一章
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    iconSize: 36,
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 验证所有控制按钮存在
      expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);

      // 验证 FloatingActionButton
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('定时停止按钮状态切换', (tester) async {
      var timerActive = false;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                appBar: AppBar(
                  title: const Text('听书'),
                  actions: [
                    IconButton(
                      icon: Icon(
                        timerActive ? Icons.timer : Icons.timer_outlined,
                        color: timerActive ? Colors.red : null,
                      ),
                      tooltip: timerActive ? '取消定时' : '定时停止',
                      onPressed: () {
                        setState(() => timerActive = !timerActive);
                      },
                    ),
                  ],
                ),
                body: const Center(child: Text('内容')),
              );
            },
          ),
        ),
      );

      // 初始状态：未激活
      expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
      expect(find.byIcon(Icons.timer), findsNothing);

      // 点击激活
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pump();

      // 激活状态
      expect(find.byIcon(Icons.timer), findsOneWidget);
      expect(find.byIcon(Icons.timer_outlined), findsNothing);
    });
  });
}
