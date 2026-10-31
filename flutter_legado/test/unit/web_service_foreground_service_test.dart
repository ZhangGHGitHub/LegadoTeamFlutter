// [批9b-6c | Web 服务前台服务] WebServiceForegroundService 单测
//
// 语义基准：原版 `WebService.kt:50-57,101-169,254-295`（参考版同构）——
// Web 服务启动成功即前台服务运行；停止即撤前台。本仓库差异：Rust server
// 在 Flutter 进程内，Service 只做进程提权，故 `START_NOT_STICKY`、任务移除
// 不停 FGS/server（审查回修 P2）、通知点击仅打开 App（见 Kotlin
// `WebServerForegroundService` 文档）。
//
// 覆盖：
// 1. 平台门控：非 Android 不触通道（iOS 由 WebKeepAliveService 负责）；
// 2. start / stop / isRunning / ensureStarted 正常路径 + 启动短延时确认；
// 3. 重复 start / stop 幂等（镜像确认后不重复下发）；
// 4. 原生返回 false 视为失败（审查回修 P3：`_invoke` 检查 bool）；
// 5. 通道异常（MissingPluginException / PlatformException / 其他异常）不崩；
// 6. 新引擎/回前台对账：isRunning 已运行 → 不重复 start；forceQuery 强制
//    查询并在已停止时重新拉起；
// 7. 通知权限：查询/请求/ensure 语义与异常降级（Android 13+）。
//
// 平台标志经 WebServiceForegroundService.platformIsAndroid 测试缝隙注入
//（对齐 WebServiceWakeLockService 既有做法，测试后恢复）；启动确认延时
// 在测试中置零，避免挂起计时器。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/web_service_foreground_service.dart';

/// 模拟原生前台服务（start/stop/isRunning + 通知权限）
class _MockForegroundPlatform {
  _MockForegroundPlatform();

  /// 原生服务运行态（isRunning 返回值；start 成功后由原生 onCreate 置 true）
  bool running = false;

  /// 原生 start 是否抛错（模拟 Android 12+ 后台启动限制）
  bool failStart = false;

  /// 原生 stop 是否抛错
  bool failStop = false;

  /// 原生 isRunning 查询是否抛错
  bool failQuery = false;

  /// 原生 start 返回 false（实现异常，不抛错）
  bool startReturnsFalse = false;

  /// 原生 start 回 true 但服务实际未运行（模拟前台化失败后 stopSelf）
  bool startAcceptedButNotRunning = false;

  /// 通知权限是否已授予
  bool notificationGranted = true;

  /// 权限对话框结果（与 [notificationGranted] 独立建模）
  bool requestGranted = true;

  /// 权限查询/请求是否抛错
  bool failPermission = false;

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
          if (startReturnsFalse) return false;
          if (!startAcceptedButNotRunning) running = true;
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
        case 'hasNotificationPermission':
          if (failPermission) {
            throw PlatformException(
              code: 'notification_permission_query_failed',
              message: '查询失败',
            );
          }
          return notificationGranted;
        case 'requestNotificationPermission':
          if (failPermission) {
            throw PlatformException(
              code: 'notification_permission_request_failed',
              message: '请求失败',
            );
          }
          notificationGranted = requestGranted;
          return notificationGranted;
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
    // 启动确认延时置零：单测不验证真实时序，避免每个用例多等 200ms
    WebServiceForegroundService.startConfirmDelay = Duration.zero;
  });

  tearDown(() {
    WebServiceForegroundService.platformIsAndroid = () => Platform.isAndroid;
    WebServiceForegroundService.startConfirmDelay = const Duration(
      milliseconds: 200,
    );
    WebServiceForegroundService.instance.debugReset();
    messenger.setMockMethodCallHandler(
      WebServiceForegroundService.channel,
      null,
    );
  });

  group('平台门控', () {
    test('非 Android：start/stop/isRunning/ensureStarted/权限均不触通道', () async {
      WebServiceForegroundService.platformIsAndroid = () => false;

      await WebServiceForegroundService.instance.start();
      await WebServiceForegroundService.instance.stop();
      await WebServiceForegroundService.instance.isRunning();
      await WebServiceForegroundService.instance.ensureStarted();
      await WebServiceForegroundService.instance.hasNotificationPermission();
      await WebServiceForegroundService.instance
          .requestNotificationPermission();
      await WebServiceForegroundService.instance.ensureNotificationPermission();

      expect(platform.calls, isEmpty, reason: '非 Android 应一律 no-op');
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('通道契约与原生桥一致（跨层断言）', () {
      expect(
        WebServiceForegroundService.channel.name,
        'legado/web_service_foreground',
      );
      expect(
        WebServiceForegroundService.channel,
        isA<MethodChannel>(),
        reason: '通道名须与 Kotlin WebServiceForegroundBridge.CHANNEL 一致',
      );
    });
  });

  group('启动', () {
    test('start 成功 → start + 短延时 isRunning 确认', () async {
      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isTrue);
      expect(platform.calls, ['start', 'isRunning'], reason: '启动后须查询确认');
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });

    test('重复 start 幂等：已确认运行时不重复触通道', () async {
      await WebServiceForegroundService.instance.start();
      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isTrue);
      expect(platform.calls, [
        'start',
        'isRunning',
      ], reason: '第二次 start 应被镜像短路');
    });

    test('原生 start 返回 false → 视为失败（不假定调用成功）', () async {
      platform.startReturnsFalse = true;

      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isFalse);
      expect(platform.calls, ['start'], reason: '原生未明确 true 不得继续确认');
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('start 受理但确认时服务未运行 → 返回 false（前台化失败）', () async {
      platform.startAcceptedButNotRunning = true;

      final ok = await WebServiceForegroundService.instance.start();

      expect(ok, isFalse);
      expect(platform.calls, ['start', 'isRunning']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('start 抛 PlatformException → 返回 false 不崩', () async {
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

    test('重复 stop 仍下发原生 stop（幂等，兜底晚到 FGS）', () async {
      await WebServiceForegroundService.instance.start();
      await WebServiceForegroundService.instance.stop();
      platform.calls.clear();

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isTrue);
      expect(platform.calls, [
        'stop',
      ], reason: '镜像 false 也不得短路：原生 stopService 幂等，必须始终下发');
    });

    test('镜像未知（引擎重建）→ 仍下发一次 stop 清理遗留服务', () async {
      platform.running = true; // 原生仍在跑，Dart 镜像为 null

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isTrue);
      expect(platform.calls, ['stop']);
      expect(platform.running, isFalse);
    });

    test('start 确认失败后原生晚到 running → stop 仍下发并清理', () async {
      // 模拟审查场景：start 受理但 200ms 确认窗口内服务未就绪 → _running=false；
      // 之后原生 onCreate 晚到使 FGS 实际运行。stop 不得因镜像 false 短路。
      platform.startAcceptedButNotRunning = true;
      final started = await WebServiceForegroundService.instance.start();
      expect(started, isFalse);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);

      platform.running = true; // 原生晚到：FGS 实际已运行
      platform.calls.clear();

      final stopped = await WebServiceForegroundService.instance.stop();

      expect(stopped, isTrue);
      expect(platform.calls, ['stop'], reason: '镜像 false 也必须下发 stop');
      expect(platform.running, isFalse);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
    });

    test('stop 抛 PlatformException → 返回 false 不崩，镜像置未知可重试', () async {
      await WebServiceForegroundService.instance.start();
      platform.failStop = true;
      platform.calls.clear();

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isFalse);
      expect(platform.calls, ['stop']);
      // 未确认停止：镜像置未知（下次 stop 仍会下发，且 init 对账先查询）
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);

      platform.failStop = false;
      platform.calls.clear();
      expect(await WebServiceForegroundService.instance.stop(), isTrue);
      expect(platform.calls, ['stop'], reason: '失败后必须可重试');
    });

    test('原生 stop 返回 false → 视为失败且镜像置未知', () async {
      await WebServiceForegroundService.instance.start();
      messenger.setMockMethodCallHandler(
        WebServiceForegroundService.channel,
        (call) async => call.method == 'stop' ? false : true,
      );
      platform.calls.clear();

      final ok = await WebServiceForegroundService.instance.stop();

      expect(ok, isFalse);
      expect(WebServiceForegroundService.instance.isRunningMirror, isFalse);
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

    test('ensureStarted：原生未运行 → 下发 start 并确认', () async {
      platform.running = false;

      await WebServiceForegroundService.instance.ensureStarted();

      expect(platform.calls, ['isRunning', 'start', 'isRunning']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });

    test('ensureStarted：镜像已运行 → 不触通道', () async {
      await WebServiceForegroundService.instance.start();
      platform.calls.clear();

      await WebServiceForegroundService.instance.ensureStarted();

      expect(platform.calls, isEmpty);
    });

    test('ensureStarted(forceQuery)：镜像 true 但原生已停 → 重新拉起', () async {
      await WebServiceForegroundService.instance.start();
      platform.running = false; // 系统在后台停止 FGS
      platform.calls.clear();

      await WebServiceForegroundService.instance.ensureStarted(
        forceQuery: true,
      );

      expect(platform.calls, ['isRunning', 'start', 'isRunning']);
      expect(WebServiceForegroundService.instance.isRunningMirror, isTrue);
    });
  });

  group('通知权限（Android 13+）', () {
    test('hasNotificationPermission 回传原生值', () async {
      platform.notificationGranted = false;

      expect(
        await WebServiceForegroundService.instance.hasNotificationPermission(),
        isFalse,
      );
      platform.notificationGranted = true;
      expect(
        await WebServiceForegroundService.instance.hasNotificationPermission(),
        isTrue,
      );
    });

    test('requestNotificationPermission：授权/拒绝均回传对话框结果', () async {
      platform.requestGranted = false;
      expect(
        await WebServiceForegroundService.instance
            .requestNotificationPermission(),
        isFalse,
      );

      platform.requestGranted = true;
      expect(
        await WebServiceForegroundService.instance
            .requestNotificationPermission(),
        isTrue,
      );
    });

    test('ensureNotificationPermission：已授予不弹框，仅查询', () async {
      platform.notificationGranted = true;

      final granted = await WebServiceForegroundService.instance
          .ensureNotificationPermission();

      expect(granted, isTrue);
      expect(platform.calls, ['hasNotificationPermission']);
    });

    test('ensureNotificationPermission：未授予才请求', () async {
      platform.notificationGranted = false;
      platform.requestGranted = false;

      final granted = await WebServiceForegroundService.instance
          .ensureNotificationPermission();

      expect(granted, isFalse);
      expect(platform.calls, [
        'hasNotificationPermission',
        'requestNotificationPermission',
      ]);
    });

    test('权限通道异常 → 静默降级 false', () async {
      platform.failPermission = true;

      expect(
        await WebServiceForegroundService.instance.hasNotificationPermission(),
        isFalse,
      );
      expect(
        await WebServiceForegroundService.instance
            .requestNotificationPermission(),
        isFalse,
      );
    });
  });
}
