// [批9b-6c | Web 服务前台服务] WebServiceForegroundService 单测
//
// 语义基准：原版 `WebService.kt:50-57,101-169,254-295`（参考版同构）——
// Web 服务启动成功即前台服务运行；停止即撤前台。本仓库差异：Rust server
// 在 Flutter 进程内，Service 只做进程提权，故 `START_NOT_STICKY`、通知点击
// 仅打开 App（见 Kotlin `WebServerForegroundService` 文档）。
//
// 覆盖：
// 1. 平台门控：非 Android 不触通道（iOS 由 WebKeepAliveService 负责）；
// 2. start / stop / isRunning / ensureStarted 正常路径；
// 3. 重复 start / stop 幂等（镜像确认后不重复下发）；
// 4. 通道异常（MissingPluginException / PlatformException / 其他异常）不崩、
//    可重试；
// 5. 新引擎对账：isRunning 已运行 → ensureStarted 不重复 start；
//    未运行 → 下发 start。
//
// 平台标志经 WebServiceForegroundService.platformIsAndroid 测试缝隙注入
//（对齐 WebServiceWakeLockService 既有做法，测试后恢复）。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/web_service_foreground_service.dart';

/// 模拟原生前台服务（Android 侧只有 start/stop/isRunning 三个方法）
class _MockForegroundPlatform {
  _MockForegroundPlatform();

  /// 原生服务运行态（isRunning 返回值；start 后由原生 onCreate 置 true）
  bool running = false;

  /// 原生 start 是否抛错（模拟 Android 12+ 后台启动限制 / startForeground 失败）
  bool failStart = false;

  /// 原生 stop 是否抛错
  bool failStop = false;

  /// 原生 isRunning 查询是否抛错
  bool failQuery = false;

  /// 收到的全部方法名（按调用顺序）
  final List<String> calls = <String>[];

  void install(TestDefaultBinaryMessenger messenger) {
    messenger.setMockMethodCallHandler(WebServiceForegroundService.channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'start':
          if (failStart) {
            throw PlatformException(
              code: 'web_foreground_start_failed',
              message: '后台启动限制',
            );
          }
          running = true;
          return true;
        case 'stop':
          if (failStop) {
            throw PlatformException(
              code: 'web_foreground_stop_failed',
              message: '停止失败',
            );
          }
          running = false;
          return true;
        case 'isRunning':
          if (failQuery) {
            throw PlatformException(
              code: 'web_foreground_query_failed',
              message: '查询失败',
            );
          }
          return running;
        default:
          return null;
      }
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  late _MockForegroundPlatform platform;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    platform = _MockForegroundPlatform();
    platform.install(messenger);
    WebServiceForegroundService.instance.debugReset();
    WebServiceForegroundService.platformIsAndroid = () => true;
  });

  tearDown(() {
    WebServiceForegroundService.platformIsAndroid = () => Platform.isAndroid;
    WebServiceForegroundService.instance.debugReset();
    messenger.setMockMethodCallHandler(WebServiceForegroundService.channel, null);
  });

  group('平台门控', () {
    test('非 Android：start/stop/isRunning/ensureStarted 均不触通道', () async {
      WebServiceForegroundService.platformIsAndroid = () => false;

      await WebServiceForegroundService.instance.start();
      await WebServiceForegroundService.instance.stop();
      await WebServiceForegroundService.instance.isRunning();
      await WebServiceForegroundService.instance.ensureStarted();

      expect(platform.calls, isEmpty, reason: '非 Android 应一律 no-op');
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });
  });

  group('启动', () {
    test('start 成功 → 下发一次 start 并确认镜像', () async {
      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isTrue);
      expect(platform.calls, ['start']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });

    test('重复 start 幂等：已确认运行时不重复触通道', () async {
      await WebServiceForegroundService.instance.start();
      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isTrue);
      expect(platform.calls, ['start'], reason: '第二次 start 应被镜像短路');
    });

    test('start 抛 PlatformException → 返回 false 不崩，镜像保持未知', () async {
      platform.failStart = true;

      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isFalse);
      expect(platform.calls, ['start']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('通道未注册（MissingPluginException）→ 静默', () async {
      messenger.setMockMethodCallHandler(
        WebServiceForegroundService.channel,
        null,
      );

      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isFalse);
    });
  });

  group('停止', () {
    test('stop 成功 → 下发 stop 并清除镜像', () async {
      await WebServiceForegroundService.instance.start();
      platform.calls.clear();

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isTrue);
      expect(platform.calls, ['stop']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('重复 stop 幂等：已确认停止后不再下发', () async {
      await WebServiceForegroundService.instance.start();
      await WebServiceForegroundService.instance.stop();
      platform.calls.clear();

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isTrue);
      expect(platform.calls, isEmpty);
    });

    test('镜像未知（引擎重建）→ 仍下发一次 stop 清理遗留服务', () async {
      platform.running = true; // 原生仍在跑，Dart 镜像为 null

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isTrue);
      expect(platform.calls, ['stop']);
      expect(platform.running, isFalse);
    });

    test('stop 抛 PlatformException → 返回 false 不崩，镜像保持运行中可重试', () async {
      await WebServiceForegroundService.instance.start();
      platform.failStop = true;
      platform.calls.clear();

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isFalse);
      expect(platform.calls, ['stop']);
      // 未确认停止：镜像仍为运行中，下一次 stop 会重试
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });
  });

  group('状态查询与初始化对账', () {
    test('isRunning 返回原生运行态并回写镜像', () async {
      platform.running = true;

      final running = await WebServiceForegroundService.instance.isRunning();

      expect(running, isTrue);
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });

    test('isRunning 查询失败 → 返回 false、镜像未知', () async {
      platform.failQuery = true;

      final running = await WebServiceForegroundService.instance.isRunning();

      expect(running, isFalse);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('ensureStarted：原生已运行 → 只查询不重复 start', () async {
      platform.running = true;

      await WebServiceForegroundService.instance.ensureStarted();

      expect(platform.calls, ['isRunning'], reason: '运行中不得重复拉起');
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });

    test('ensureStarted：原生未运行 → 下发 start', () async {
      platform.running = false;

      await WebServiceForegroundService.instance.ensureStarted();

      expect(platform.calls, ['isRunning', 'start']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });

    test('ensureStarted：镜像已运行 → 不触通道', () async {
      await WebServiceForegroundService.instance.start();
      platform.calls.clear();

      await WebServiceForegroundService.instance.ensureStarted();

      expect(platform.calls, isEmpty);
    });
  });
}
