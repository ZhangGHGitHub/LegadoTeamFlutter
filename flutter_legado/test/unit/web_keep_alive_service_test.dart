// [iOS Web 服务后台保活 | 2026-10-07] WebKeepAliveService 状态机单测
//
// 覆盖：
// 1. 非 iOS 平台：start/stop 均为 no-op（不触碰 `legado/web_keepalive` 通道）；
// 2. iOS：服务 start/stop ↔ 通道 setEnabled(true/false) 的调用序列与幂等；
// 3. 与听书/TTS 共存：真实音频播放中启动服务 → 保活暂缓（不下发），
//    真实音频停止 → 保活恢复；已激活时真实音频开始 → 静音音轨让位（false），
//    停止后再次恢复（true）。真实音频状态经 AudioService 单例的
//    notifyPlaying/notifyPaused 驱动（与生产同一数据源，验证流接线本身）；
// 4. 平台失败（返回 false / MissingPluginException / PlatformException）
//    → 降级 failed、不抛异常（方案 A 兜底：不阻断 Web 服务）。
//
// 平台标志经 WebKeepAliveService.platformIsIOS 测试缝隙注入
//（对齐 SystemBrightness.platformIsIOS 既有做法，测试后恢复）。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/web_keep_alive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = WebKeepAliveService.instance;
  final audio = AudioService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 安装通道 mock：记录调用并按 [result] 应答（true=平台成功）
  List<MethodCall> mockChannel({bool result = true}) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(WebKeepAliveService.channel, (
      call,
    ) async {
      calls.add(call);
      return result;
    });
    return calls;
  }

  /// 驱动真实音频播放态（与生产同一入口：AudioService 的播放态汇聚点）
  Future<void> emitRealAudio(bool playing) async {
    if (playing) {
      await audio.notifyPlaying();
    } else {
      await audio.notifyPaused();
    }
    await pumpEventQueue();
  }

  setUp(() {
    // 模拟 iOS 平台（测试缝隙）
    WebKeepAliveService.platformIsIOS = () => true;
    service.debugReset();
    addTearDown(() async {
      await audio.notifyStopped();
      await pumpEventQueue();
      WebKeepAliveService.platformIsIOS = () => Platform.isIOS;
      service.debugReset();
      messenger.setMockMethodCallHandler(WebKeepAliveService.channel, null);
    });
  });

  /// setEnabled 调用的负载断言辅助
  List<bool> enabledArgs(List<MethodCall> calls) =>
      calls.map((c) => (c.arguments as Map)['enabled'] as bool).toList();

  group('平台门控（非 iOS no-op）', () {
    test('非 iOS：start/stop 不触碰通道', () async {
      WebKeepAliveService.platformIsIOS = () => false;
      final calls = mockChannel();

      expect(await service.start(), WebKeepAliveStatus.notApplicable);
      expect(await service.stop(), WebKeepAliveStatus.notApplicable);

      expect(calls, isEmpty, reason: '非 iOS 平台保活应为 no-op');
      expect(service.isActive, isFalse);
    });
  });

  group('iOS 服务 start/stop ↔ 保活启停', () {
    test('start → setEnabled(true)；stop → setEnabled(false)', () async {
      final calls = mockChannel();

      expect(await service.start(), WebKeepAliveStatus.active);
      expect(service.isActive, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setEnabled');
      expect(enabledArgs(calls), [true]);

      expect(await service.stop(), WebKeepAliveStatus.idle);
      expect(service.isActive, isFalse);
      expect(enabledArgs(calls), [true, false], reason: '停止必须下发 setEnabled(false)');
    });

    test('start 幂等：已激活时重复 start 不重复下发', () async {
      final calls = mockChannel();

      await service.start();
      expect(await service.start(), WebKeepAliveStatus.active);

      expect(calls, hasLength(1), reason: '幂等 start 不应重复启动静音音轨');
    });

    test('stop 幂等：未激活时 stop 不下发', () async {
      final calls = mockChannel();

      expect(await service.stop(), WebKeepAliveStatus.idle);
      expect(calls, isEmpty);
    });
  });

  group('TTS/听书共存策略', () {
    test('真实音频播放中 start → 暂缓（不下发）；音频停止 → 恢复保活', () async {
      final calls = mockChannel();

      await emitRealAudio(true);
      expect(
        await service.start(),
        WebKeepAliveStatus.deferredByRealAudio,
        reason: '真实音频本身维持存活，静音音轨暂缓',
      );
      expect(calls, isEmpty, reason: 'TTS 播放中不得启动静音音轨');

      await emitRealAudio(false);

      expect(enabledArgs(calls), [true], reason: 'TTS 停止后应恢复保活');
      expect(service.status, WebKeepAliveStatus.active);
    });

    test('保活已激活时真实音频开始 → 音轨让位；停止 → 再次恢复', () async {
      final calls = mockChannel();

      await service.start();
      expect(enabledArgs(calls), [true]);

      await emitRealAudio(true);
      expect(enabledArgs(calls), [true, false], reason: '真实音频开始时静音音轨暂停');
      expect(service.status, WebKeepAliveStatus.deferredByRealAudio);
      expect(service.isActive, isFalse);

      await emitRealAudio(false);
      expect(enabledArgs(calls), [true, false, true], reason: '真实音频停止后恢复保活');
      expect(service.isActive, isTrue);
    });

    test('stop 之后的真实音频事件不再触碰通道', () async {
      final calls = mockChannel();

      await service.start();
      await service.stop();
      expect(enabledArgs(calls), [true, false]);

      await emitRealAudio(true);
      await emitRealAudio(false);

      expect(enabledArgs(calls), [true, false], reason: '服务已停，保活订阅不应再生效');
    });
  });

  group('方案 A 兜底（失败降级、不阻断）', () {
    test('平台返回 false → failed，不抛异常', () async {
      final calls = mockChannel(result: false);

      expect(await service.start(), WebKeepAliveStatus.failed);
      expect(service.isActive, isFalse);
      expect(enabledArgs(calls), [true]);

      // 失败后 stop 仍是安全 no-op
      expect(await service.stop(), WebKeepAliveStatus.idle);
      expect(enabledArgs(calls), [true]);
    });

    test('通道未注册（MissingPluginException）→ failed，不抛异常', () async {
      messenger.setMockMethodCallHandler(WebKeepAliveService.channel, (
        call,
      ) async {
        throw MissingPluginException('No implementation found');
      });

      expect(await service.start(), WebKeepAliveStatus.failed);
    });

    test('通道 PlatformException → failed，不抛异常', () async {
      messenger.setMockMethodCallHandler(WebKeepAliveService.channel, (
        call,
      ) async {
        throw PlatformException(code: 'ACTIVATION_FAILED');
      });

      expect(await service.start(), WebKeepAliveStatus.failed);
    });

    test('失败后真实音频停止 → 自动重试恢复（自愈）', () async {
      // 首次失败（模拟会话被通话占用），音频事件后重试成功
      var result = false;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(WebKeepAliveService.channel, (
        call,
      ) async {
        calls.add(call);
        return result;
      });

      expect(await service.start(), WebKeepAliveStatus.failed);

      result = true;
      await emitRealAudio(true);
      await emitRealAudio(false);

      expect(enabledArgs(calls), [true, true], reason: '音频停止后重试保活并成功');
      expect(service.status, WebKeepAliveStatus.active);
    });
  });
}
