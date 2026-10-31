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
///
/// [cpuHeld]/[wifiHeld]/[wifiTracked] 分离建模（审查 P2）：
/// Wi-Fi 获取失败但旧实现仍缓存句柄时，`isHeld=false` 而 CPU 锁实际持有；
/// 新契约要求失败句柄为 null（[wifiTracked]=false），CPU-only 仍算持有。
class _MockWakeLockPlatform {
  _MockWakeLockPlatform();

  /// CPU 唤醒锁原生持有态
  bool cpuHeld = false;

  /// Wi-Fi 锁原生持有态
  bool wifiHeld = false;

  /// Wi-Fi 句柄是否已缓存（旧实现 acquire 失败仍缓存 → isHeld 漏看 CPU）
  bool wifiTracked = false;

  /// 模拟 Wi-Fi 获取失败：CPU 成功、Wi-Fi 未持有且句柄被缓存（旧契约）
  bool wifiAcquireFails = false;

  /// 模拟 Wi-Fi 释放失败：CPU 锁被保留（不产生单锁）
  bool failWifiRelease = false;

  /// 模拟 CPU 释放失败：Wi-Fi 已释放、CPU 仍持有 → isHeld=true
  bool failCpuRelease = false;

  /// 原生完整持有态（与 Kotlin `isHeld` 语义一致）
  bool get isHeld => cpuHeld && (!wifiTracked || wifiHeld);

  /// 便捷整体持有（正常路径 CPU+Wi-Fi 同进同出；测试注入用）
  bool get held => cpuHeld && wifiHeld;

  set held(bool value) {
    cpuHeld = value;
    wifiHeld = value;
    wifiTracked = value;
  }

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
          return isHeld;
        case 'setEnabled':
          setEnabledCalls.add(call);
          return _applyEnabled((call.arguments as Map)['enabled'] as bool);
        default:
          return null;
      }
    });
  }

  /// 模拟原生 setEnabled：返回 isHeld；失败抛 PlatformException（result.error）
  bool _applyEnabled(bool enabled) {
    if (!enabled) {
      // 原生释放顺序：先 Wi-Fi 后 CPU
      if (failWifiRelease) {
        throw PlatformException(
          code: 'wake_lock_failed',
          message: 'Wi-Fi 锁释放失败',
        );
      }
      wifiHeld = false;
      wifiTracked = false; // 释放成功后句柄置 null
      if (failCpuRelease) {
        throw PlatformException(
          code: 'wake_lock_failed',
          message: 'CPU 唤醒锁释放失败',
        );
      }
      cpuHeld = false;
      return isHeld;
    }
    cpuHeld = true;
    if (wifiAcquireFails) {
      wifiHeld = false;
      wifiTracked = true; // 旧实现：先缓存再生效，失败后 isHeld 漏看 CPU
    } else {
      wifiHeld = true;
      wifiTracked = true;
    }
    return isHeld;
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

    test('服务未运行时切换偏好：只更新偏好、不 acquire（仅查询原生态）', () async {
      await service.onPreferenceChanged(true);
      expect(platform.enabledArgs, isEmpty, reason: '服务未运行不得 acquire');
      expect(platform.queryCount, 1, reason: '原生态未知时仍需查询一次（避免新引擎遗留锁）');

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

    test('CPU release 失败（result.error）：isHeld=true，保持持有并下次重试', () async {
      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      // 原生先释放 Wi-Fi、CPU 释放失败：isHeld 仍 true，Dart 保留持有态
      platform.failCpuRelease = true;
      await service.onServiceStopped();
      expect(service.isHeld, isTrue, reason: 'CPU 释放失败时状态保持，等待重试');
      expect(platform.cpuHeld, isTrue);
      expect(platform.wifiHeld, isFalse, reason: 'Wi-Fi 已释放但 CPU 仍持有');

      platform.failCpuRelease = false;
      await service.onServiceStopped();
      expect(platform.enabledArgs, [
        true,
        false,
        false,
      ], reason: '失败后再次停止应重试 release');
      expect(service.isHeld, isFalse);
      expect(platform.cpuHeld, isFalse);
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

  group('部分持锁（审查 P2）', () {
    test('Wi-Fi 获取失败（CPU-only、isHeld=false 旧契约）：停止仍下发 release', () async {
      // 模拟旧实现：Wi-Fi 获取失败但句柄已缓存 → isHeld=false，CPU 锁不可见
      platform.wifiAcquireFails = true;

      await service.onServiceStarted(keepAwake: true);
      expect(platform.cpuHeld, isTrue);
      expect(platform.isHeld, isFalse, reason: '旧契约下 isHeld 漏看 CPU 锁');
      expect(service.isHeld, isFalse);

      // 运行中关开关：查询同样返回 false，镜像认为「未持有」（问题现场）
      await service.onPreferenceChanged(false);
      expect(platform.enabledArgs, [true]);

      // 停服必须强制 release，否则真实 CPU 锁残留
      await service.onServiceStopped();
      expect(platform.enabledArgs, [
        true,
        false,
      ], reason: '停服不得仅凭 isHeld=false 跳过 release');
      expect(platform.cpuHeld, isFalse);
      expect(service.isHeld, isFalse);
    });

    test('Wi-Fi 释放失败：保留 CPU 锁（isHeld=true），下次重试释放', () async {
      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue);

      platform.failWifiRelease = true;
      await service.onServiceStopped();
      expect(service.isHeld, isTrue, reason: 'Wi-Fi 失败时 CPU 锁保留');
      expect(platform.cpuHeld, isTrue);
      expect(platform.wifiHeld, isTrue);
      expect(platform.enabledArgs, [true, false]);

      platform.failWifiRelease = false;
      await service.onServiceStopped();
      expect(platform.enabledArgs, [true, false, false]);
      expect(platform.cpuHeld, isFalse);
      expect(platform.wifiHeld, isFalse);
      expect(service.isHeld, isFalse);
    });

    test('Wi-Fi 获取失败（新契约 CPU-only、isHeld=true）：运行中关开关即 release', () async {
      // 新契约：Wi-Fi 句柄未缓存（wifiTracked=false）→ isHeld 只看 CPU
      platform
        ..cpuHeld = true
        ..wifiHeld = false
        ..wifiTracked = false;

      await service.onServiceStarted(keepAwake: true);
      expect(service.isHeld, isTrue, reason: 'CPU-only 应视为持有');
      expect(platform.enabledArgs, isEmpty, reason: '原生已持有，不重复 acquire');

      await service.onPreferenceChanged(false);
      expect(platform.enabledArgs, [false], reason: '运行中关开关必须释放 CPU 锁');
      expect(platform.cpuHeld, isFalse);
      expect(service.isHeld, isFalse);
    });
  });

  group('原生回传态对账（审查边界 4）', () {
    test('acquire 回传与期望不一致（部分失败）：保持未知，下次先查询校正', () async {
      var nativeHeld = false;
      var setEnabledCalls = 0;
      var lieOnFirstAcquire = true;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return nativeHeld;
        setEnabledCalls++;
        final enabled = (call.arguments as Map)['enabled'] as bool;
        nativeHeld = enabled;
        if (enabled && lieOnFirstAcquire) {
          lieOnFirstAcquire = false;
          // 原生实际已持有，但回传与期望不一致（视作部分失败）
          return false;
        }
        return nativeHeld;
      });

      await service.onServiceStarted(keepAwake: true);

      expect(setEnabledCalls, 1);
      expect(service.isHeld, isFalse, reason: '镜像按原生回传值更新');

      // 下次同步先查询原生真实态（已持有）→ 与期望一致，不再重复下发
      await service.onServiceStarted(keepAwake: true);

      expect(setEnabledCalls, 1, reason: '查询发现已持有 → 不重复 acquire');
      expect(service.isHeld, isTrue);
    });

    test('release 回传与期望不一致：标记未知，下次查询校正', () async {
      var nativeHeld = true;
      var setEnabledCalls = 0;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return nativeHeld;
        setEnabledCalls++;
        nativeHeld = (call.arguments as Map)['enabled'] as bool;
        // 释放实际生效，但回传不一致（模拟部分失败，恒回 true）
        return true;
      });

      await service.onServiceStopped();

      expect(setEnabledCalls, 1);
      expect(service.isHeld, isTrue, reason: '镜像按原生回传值更新（回传 true）');

      // 下次同步先查询原生真实态（已释放）→ 与期望一致，不再重复下发
      await service.onServiceStopped();

      expect(setEnabledCalls, 1, reason: '查询发现已释放 → 不再重复 release');
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

    test('新引擎服务未运行 + 关开关：查询并释放原生遗留锁（审查边界 1）', () async {
      platform.held = true;
      service.debugReset();

      await service.onPreferenceChanged(false);

      expect(platform.queryCount, 1);
      expect(platform.enabledArgs, [false]);
      expect(service.isHeld, isFalse);
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
