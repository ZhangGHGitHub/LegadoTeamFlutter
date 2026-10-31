// [批9b-6 | Web 服务唤醒锁] WebServiceWakeLockService 状态机单测
//
// 语义基准：原版 `WebService.kt:76-78,105,140,160`（参考版同实现）
// —— 偏好 `webServiceWakeLock`（默认 false）开且 Web 服务运行 → 同时持
// `PARTIAL_WAKE_LOCK` + 同 tag 的 `WifiLock`；服务停止 / 开关关 → 释放。
//
// 审查回修后覆盖：
// 1. 平台门控：非 Android 不触通道（iOS 由 WebKeepAliveService 负责）；
// 2. 启动 + 开关开 → acquire；启动 + 开关关 → 不下发；停止 → release；
// 3. 重复 start/stop 幂等；服务重启且偏好已关 → 释放；
// 4. 运行中切换开关 → 即时 acquire/release；服务未运行时切换不触通道；
// 5. 通道异常（MissingPluginException / PlatformException / 其他异常 /
//    isHeld 查询异常）不崩溃、状态可重试；
// 6. 同步竞态：延迟 acquire 时快速 true→false 仍补发 release（修前会丢）；
// 7. 引擎重建：Dart 状态归零后先经原生 isHeld 对账——已持有不重复下发、
//    偏好关/服务停时释放遗留锁。
//
// 平台标志经 WebServiceWakeLockService.platformIsAndroid 测试缝隙注入
//（对齐 WebKeepAliveService.platformIsIOS 既有做法，测试后恢复）。
//
// — 全栈工程师 ｜ 2026-11-01

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/web_service_wake_lock_service.dart';

/// 模拟原生侧进程级锁状态（跨 Dart 引擎重建仍然保留）
class _MockWakeLockPlatform {
  _MockWakeLockPlatform();

  /// 原生当前是否持有（对应 Kotlin 单例的 WakeLock/WifiLock）
  bool held = false;

  /// 仅 setEnabled 调用（断言 acquire/release 序列）
  final List<MethodCall> setEnabledCalls = <MethodCall>[];

  /// 全部通道调用（含 isHeld 查询）
  final List<MethodCall> allCalls = <MethodCall>[];

  void install(TestDefaultBinaryMessenger messenger) {
    messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
      call,
    ) async {
      allCalls.add(call);
      switch (call.method) {
        case 'isHeld':
          return held;
        case 'setEnabled':
          setEnabledCalls.add(call);
          held = (call.arguments as Map)['enabled'] as bool;
          return held;
        default:
          return null;
      }
    });
  }

  List<bool> get enabledArgs => setEnabledCalls
      .map((c) => (c.arguments as Map)['enabled'] as bool)
      .toList(growable: false);

  int get queryCount => allCalls.where((c) => c.method == 'isHeld').length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = WebServiceWakeLockService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _MockWakeLockPlatform platform;

  setUp(() {
    platform = _MockWakeLockPlatform();
    platform.install(messenger);
    // 模拟 Android（测试缝隙）
    WebServiceWakeLockService.platformIsAndroid = () => true;
    service.debugReset();
  });

  tearDown(() {
    WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
    service.debugReset();
    messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, null);
  });

  group('平台门控（非 Android 不触通道）', () {
    test('非 Android：启动/停止/切换偏好均不触通道', () async {
      WebServiceWakeLockService.platformIsAndroid = () => false;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        calls.add(call);
        return false;
      });

      await service.onServiceStarted(keepAwake: true);
      await service.onPreferenceChanged(false);
      await service.onPreferenceChanged(true);
      await service.onServiceStopped();

      expect(service.isSupported, isFalse);
      expect(service.isHeld, isFalse);
      expect(calls, isEmpty, reason: '非 Android 平台不得触碰唤醒锁通道');
    });
  });

  group('启动/停止 ↔ acquire/release', () {
    test('启动 + 开关开 → setEnabled(true)', () async {
      await service.onServiceStarted(keepAwake: true);

      expect(platform.enabledArgs, [true]);
      expect(platform.setEnabledCalls.single.method, 'setEnabled');
      expect(service.isHeld, isTrue);
      expect(platform.held, isTrue);
    });

    test('启动 + 开关关 → 不 acquire', () async {
      await service.onServiceStarted(keepAwake: false);

      expect(platform.enabledArgs, isEmpty, reason: '偏好关闭时服务运行也不得持锁');
      expect(service.isHeld, isFalse);
    });

    test('停止 → setEnabled(false)', () async {
      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      await service.onServiceStopped();

      expect(platform.enabledArgs, [true, false]);
      expect(service.isHeld, isFalse);
      expect(platform.held, isFalse);
    });

    test('重复 start/stop 幂等（不重复下发）', () async {
      await service.onServiceStarted(keepAwake: true);
      await service.onServiceStarted(keepAwake: true);
      expect(platform.enabledArgs, [true], reason: '重复 start 不应重复 acquire');

      await service.onServiceStopped();
      await service.onServiceStopped();
      await service.onServiceStopped();
      expect(platform.enabledArgs, [
        true,
        false,
      ], reason: '重复 stop 不应重复 release');
    });

    test('服务重启且偏好已关 → 释放（重复 start 以最新偏好为准）', () async {
      await service.onServiceStarted(keepAwake: true);
      await service.onServiceStarted(keepAwake: false);

      expect(platform.enabledArgs, [true, false]);
      expect(service.isHeld, isFalse);
    });

    test('原生持有态只查询一次（同一次 Dart 生命周期内不反复查询）', () async {
      await service.onServiceStarted(keepAwake: true);
      await service.onPreferenceChanged(false);
      await service.onPreferenceChanged(true);
      await service.onServiceStopped();

      expect(platform.queryCount, 1);
    });
  });

  group('运行中切换偏好即时生效', () {
    test('服务运行中：开 → acquire，关 → release', () async {
      await service.onServiceStarted(keepAwake: false);
      expect(platform.enabledArgs, isEmpty);

      await service.onPreferenceChanged(true);
      expect(platform.enabledArgs, [true]);
      expect(service.isHeld, isTrue);

      // 同值重复下发不重复触通道
      await service.onPreferenceChanged(true);
      expect(platform.enabledArgs, [true]);

      await service.onPreferenceChanged(false);
      expect(platform.enabledArgs, [true, false]);
      expect(service.isHeld, isFalse);
    });

    test('服务未运行时切换偏好：只更新偏好，不触通道；下次启动生效', () async {
      await service.onPreferenceChanged(true);
      expect(platform.enabledArgs, isEmpty, reason: '服务未运行不得 acquire');

      await service.onServiceStarted(keepAwake: true);
      expect(platform.enabledArgs, [true], reason: '启动时按传入偏好 acquire');
    });
  });

  group('通道异常降级（不崩溃）', () {
    test('MissingPluginException：启动不抛异常，通道就绪后可重试', () async {
      messenger.setMockMethodCallHandler(
        WebServiceWakeLockService.channel,
        null,
      );

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isFalse, reason: '平台调用失败不应标记为持有');

      platform.install(messenger);
      await service.onServiceStarted(keepAwake: true);
      expect(platform.enabledArgs, [true]);
      expect(service.isHeld, isTrue);
    });

    test('原生 acquire 失败（result.error）：不抛异常，状态保持并可重试', () async {
      var failAcquire = true;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return false;
        calls.add(call);
        final enabled = (call.arguments as Map)['enabled'] as bool;
        if (enabled && failAcquire) {
          throw PlatformException(
            code: 'wake_lock_failed',
            message: 'Web 服务唤醒锁获取失败：模拟失败',
          );
        }
        return enabled;
      });

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isFalse, reason: 'acquire 失败不得标记为持有');

      failAcquire = false;
      await service.onServiceStarted(keepAwake: true);
      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true, true],
        reason: '失败后下次同步应重试 acquire',
      );
      expect(service.isHeld, isTrue);
    });

    test('原生 release 失败（result.error）：保持持有态，下次同步重试', () async {
      var failRelease = true;
      var nativeHeld = false;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return nativeHeld;
        calls.add(call);
        final enabled = (call.arguments as Map)['enabled'] as bool;
        if (!enabled && failRelease) {
          throw PlatformException(
            code: 'wake_lock_failed',
            message: 'Web 服务唤醒锁释放失败：模拟失败',
          );
        }
        nativeHeld = enabled;
        return enabled;
      });

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      // 停止时平台异常：静默保留「仍持有」状态，不向调用方抛
      await service.onServiceStopped();
      expect(service.isHeld, isTrue, reason: '释放失败时状态保持，等待重试');

      failRelease = false;
      await service.onServiceStopped();
      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true, false, false],
        reason: '失败后再次停止应重试 release',
      );
      expect(service.isHeld, isFalse);
    });

    test('isHeld 查询异常：按期望态强制同步一次', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') {
          throw PlatformException(code: 'query_failed', message: '查询失败');
        }
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });

      await service.onServiceStarted(keepAwake: true);

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true],
        reason: '查询失败也要按期望态下发，避免遗留锁无法释放',
      );
      expect(service.isHeld, isTrue);
    });

    test('任意异常（非 PlatformException）：不抛出、状态保持未持有', () async {
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        throw StateError('unexpected');
      });

      await expectLater(service.onServiceStarted(keepAwake: true), completes);
      expect(service.isHeld, isFalse);
    });
  });

  group('同步竞态（审查 P2）', () {
    test('延迟 acquire 时快速 true→false：最终补发 release', () async {
      final gate = Completer<void>();
      final acquireStarted = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'isHeld':
            return false;
          case 'setEnabled':
            calls.add(call);
            final enabled = (call.arguments as Map)['enabled'] as bool;
            if (enabled) {
              if (!acquireStarted.isCompleted) acquireStarted.complete();
              // 挂起 acquire，模拟平台调用耗时
              await gate.future;
            }
            return enabled;
          default:
            return null;
        }
      });

      await service.onServiceStarted(keepAwake: false);

      // acquire 已开始且未返回时立刻关闭开关
      final acquireFuture = service.onPreferenceChanged(true);
      await acquireStarted.future;
      final releaseFuture = service.onPreferenceChanged(false);
      gate.complete();
      await Future.wait(<Future<void>>[acquireFuture, releaseFuture]);

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true, false],
        reason: '串行化后第二次同步必须补发 release（修前会因旧 _held 丢失）',
      );
      expect(service.isHeld, isFalse);
    });
  });

  group('Activity/引擎重建后对账（审查 P1-2/P2-5）', () {
    test('原生仍持有 + 偏好开：重新确认持有，不重复下发 acquire', () async {
      platform.held = true;
      // 模拟新引擎：Dart 状态归零，但同进程原生锁仍在
      service.debugReset();

      await service.onServiceStarted(keepAwake: true);

      expect(service.isHeld, isTrue);
      expect(platform.held, isTrue);
      expect(platform.queryCount, 1, reason: '新引擎首次同步应先查询原生态');
      expect(platform.enabledArgs, isEmpty, reason: '原生已持有则不应重复 acquire（幂等）');
    });

    test('原生仍持有 + 偏好关：按运行态释放遗留锁', () async {
      platform.held = true;
      service.debugReset();

      await service.onServiceStarted(keepAwake: false);

      expect(platform.queryCount, 1);
      expect(platform.enabledArgs, [false]);
      expect(service.isHeld, isFalse);
      expect(platform.held, isFalse);
    });

    test('原生仍持有 + 服务未运行（设置页初始化对账）：释放遗留锁', () async {
      platform.held = true;
      service.debugReset();

      await service.onServiceStopped();

      expect(platform.enabledArgs, [false]);
      expect(platform.held, isFalse);
    });

    test('原生未持有 + 偏好开：新引擎重新 acquire', () async {
      platform.held = false;
      service.debugReset();

      await service.onServiceStarted(keepAwake: true);

      expect(platform.enabledArgs, [true]);
      expect(platform.held, isTrue);
      expect(service.isHeld, isTrue);
    });
  });
}
