// [批9b-6 | Web 服务唤醒锁] WebServiceWakeLockService 状态机单测
//
// 语义基准：原版 `WebService.kt:76-78,104,139,159`（参考版同实现）
// —— 偏好 `webServiceWakeLock`（默认 false）开且 Web 服务运行 → 持
// `PARTIAL_WAKE_LOCK`（tag `legado:WebService`）；服务停止 / 开关关 → 释放。
//
// 覆盖：
// 1. 平台门控：非 Android 不触通道（iOS 由 WebKeepAliveService 负责）；
// 2. 启动 + 开关开 → acquire；启动 + 开关关 → 不下发；
// 3. 停止 → release（幂等，重复 stop 不重复下发）；
// 4. 运行中切换开关 → 即时 acquire/release；服务未运行时切换不触通道；
// 5. 通道异常（MissingPluginException / PlatformException / 其他异常）
//    不崩溃、不抛异常，状态可重试；
// 6. dispose/detached 兜底 release（含未持有时空操作、detached 事件驱动）。
//
// 平台标志经 WebServiceWakeLockService.platformIsAndroid 测试缝隙注入
//（对齐 WebKeepAliveService.platformIsIOS 既有做法，测试后恢复）。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/web_service_wake_lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = WebServiceWakeLockService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 安装通道 mock：记录调用并默认成功
  List<MethodCall> mockChannel() {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    return calls;
  }

  /// setEnabled 调用的 enabled 参数序列（断言 acquire/release 顺序）
  List<bool> enabledArgs(List<MethodCall> calls) => calls
      .map((c) => (c.arguments as Map)['enabled'] as bool)
      .toList(growable: false);

  setUp(() {
    // 模拟 Android（测试缝隙）
    WebServiceWakeLockService.platformIsAndroid = () => true;
    service.debugReset();
    messenger.setMockMethodCallHandler(
      WebServiceWakeLockService.channel,
      null,
    );
  });

  tearDown(() {
    WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
    service.debugReset();
    messenger.setMockMethodCallHandler(
      WebServiceWakeLockService.channel,
      null,
    );
  });

  group('平台门控（非 Android 不触通道）', () {
    test('非 Android：启动/停止/切换偏好均不触通道', () async {
      WebServiceWakeLockService.platformIsAndroid = () => false;
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: true);
      await service.onPreferenceChanged(false);
      await service.onPreferenceChanged(true);
      await service.onServiceStopped();
      await service.releaseOnProcessDetach();

      expect(service.isSupported, isFalse);
      expect(service.isHeld, isFalse);
      expect(calls, isEmpty, reason: '非 Android 平台不得触碰唤醒锁通道');
    });
  });

  group('启动/停止 ↔ acquire/release', () {
    test('启动 + 开关开 → setEnabled(true)', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: true);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'setEnabled');
      expect(enabledArgs(calls), [true]);
      expect(service.isHeld, isTrue);
    });

    test('启动 + 开关关 → 不 acquire', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: false);

      expect(calls, isEmpty, reason: '偏好关闭时服务运行也不得持锁');
      expect(service.isHeld, isFalse);
    });

    test('停止 → setEnabled(false)', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      await service.onServiceStopped();

      expect(enabledArgs(calls), [true, false]);
      expect(service.isHeld, isFalse);
    });

    test('重复 start/stop 幂等（不重复下发）', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: true);
      await service.onServiceStarted(keepAwake: true);
      expect(enabledArgs(calls), [true], reason: '重复 start 不应重复 acquire');

      await service.onServiceStopped();
      await service.onServiceStopped();
      await service.onServiceStopped();
      expect(enabledArgs(calls), [true, false], reason: '重复 stop 不应重复 release');
    });

    test('服务重启且偏好已关 → 释放（重复 start 以最新偏好为准）', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: true);
      await service.onServiceStarted(keepAwake: false);

      expect(enabledArgs(calls), [true, false]);
      expect(service.isHeld, isFalse);
    });
  });

  group('运行中切换偏好即时生效', () {
    test('服务运行中：开 → acquire，关 → release', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: false);
      expect(calls, isEmpty);

      await service.onPreferenceChanged(true);
      expect(enabledArgs(calls), [true]);
      expect(service.isHeld, isTrue);

      // 同值重复下发不重复触通道
      await service.onPreferenceChanged(true);
      expect(enabledArgs(calls), [true]);

      await service.onPreferenceChanged(false);
      expect(enabledArgs(calls), [true, false]);
      expect(service.isHeld, isFalse);
    });

    test('服务未运行时切换偏好：只更新偏好，不触通道；下次启动生效', () async {
      final calls = mockChannel();

      await service.onPreferenceChanged(true);
      expect(calls, isEmpty, reason: '服务未运行不得 acquire');

      await service.onServiceStarted(keepAwake: true);
      expect(enabledArgs(calls), [true], reason: '启动时按传入偏好 acquire');
    });
  });

  group('通道异常降级（不崩溃）', () {
    test('MissingPluginException：启动不抛异常，通道就绪后可重试', () async {
      // 未注册 handler → invokeMethod 抛 MissingPluginException
      await service.onServiceStarted(keepAwake: true);

      expect(service.isHeld, isFalse, reason: '平台调用失败不应标记为持有');

      final calls = mockChannel();
      await service.onPreferenceChanged(true);
      expect(enabledArgs(calls), [true]);
      expect(service.isHeld, isTrue);
    });

    test('PlatformException：释放失败不抛异常，下次状态变化可重试', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        calls.add(call);
        final enabled = (call.arguments as Map)['enabled'] as bool;
        if (!enabled) {
          throw PlatformException(code: 'release_failed', message: '释放失败');
        }
        return null;
      });

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      // 停止时平台异常：静默保留「仍持有」状态，不向调用方抛
      await service.onServiceStopped();
      expect(service.isHeld, isTrue, reason: '释放失败时状态保持，等待重试');

      // 恢复平台成功后，再次启动（偏好关）触发重试释放
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      await service.onServiceStarted(keepAwake: false);

      expect(enabledArgs(calls), [true, false, false]);
      expect(service.isHeld, isFalse);
    });

    test('任意异常（非 PlatformException）：不抛出、状态保持未持有', () async {
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        throw StateError('unexpected');
      });

      await expectLater(
        service.onServiceStarted(keepAwake: true),
        completes,
      );
      expect(service.isHeld, isFalse);
    });
  });

  group('dispose / detached 兜底释放', () {
    test('releaseOnProcessDetach：持有 → 释放；重复调用不重复下发', () async {
      final calls = mockChannel();

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      await service.releaseOnProcessDetach();
      expect(enabledArgs(calls), [true, false]);
      expect(service.isHeld, isFalse);

      await service.releaseOnProcessDetach();
      expect(enabledArgs(calls), [true, false], reason: '未持有时兜底应为空操作');
    });

    test('未持有唤醒锁时 dispose 兜底不触通道', () async {
      final calls = mockChannel();

      await service.releaseOnProcessDetach();

      expect(calls, isEmpty);
      expect(service.isHeld, isFalse);
    });

    test('attachLifecycleFallback + detached 事件 → 自动释放', () async {
      final calls = mockChannel();

      service.attachLifecycleFallback();
      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      // 触发 App 状态变为 detached（等价引擎/应用卸载）
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.detached,
      );
      await pumpEventQueue();

      expect(enabledArgs(calls), [true, false]);
      expect(service.isHeld, isFalse);

      // 复位测试 binding 的生命周期态，防影响后续用例
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
    });
  });
}
