// [TTS P3 回修 | 2026-11-11] AudioService init/release 串行化回归
//
// 背景：旧实现 `dispose()` 在 `await release` 返回后才置 `_initialized=false`，
// `init()` 又用 `_initialized` 短路，导致两种半状态：
// a) release 与在途 initMediaSession 交错：release 空转，旧 init 完成后
//    重新把会话标为就绪，STOPPED 记录残留；
// b) release 在途时立即重播：init() 误判仍已初始化直接返回，随后 release
//    置 false → Dart 认为就绪但原生已释放。
//
// 本文件直接对 AudioService 单例 + MethodChannel 打桩，断言最终状态只能
// 收敛为「已释放」或「已就绪」，不出现半状态。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('legado/media_session');

  late List<String> calls;
  Completer<void>? initGate;
  Completer<void>? releaseGate;

  setUp(() {
    calls = <String>[];
    initGate = null;
    releaseGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'init':
              final gate = initGate;
              if (gate != null) await gate.future;
              return true;
            case 'release':
              final gate = releaseGate;
              if (gate != null) await gate.future;
              return null;
            case 'requestAudioFocus':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() async {
    // 放开可能挂起的闸门，保证 tearDown 不悬挂
    if (initGate != null && !initGate!.isCompleted) {
      initGate!.complete();
    }
    if (releaseGate != null && !releaseGate!.isCompleted) {
      releaseGate!.complete();
    }
    await AudioService.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('release 在途时 init 必须等待释放完成后再初始化（最终就绪）', () async {
    final service = AudioService.instance;
    await service.init();
    expect(service.isInitialized, isTrue);
    expect(calls, ['init']);

    releaseGate = Completer<void>();
    final releaseFuture = service.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(service.isInitialized, isFalse, reason: 'release 未返回前也应先落未初始化');

    final initFuture = service.init();
    await Future<void>.delayed(Duration.zero);
    expect(calls, [
      'init',
      'release',
    ], reason: 'release 在途时 init 不得抢跑发送原生 init');

    releaseGate!.complete();
    await releaseFuture;
    await initFuture;

    expect(calls, ['init', 'release', 'init']);
    expect(service.isInitialized, isTrue, reason: '释放完成后重播应最终就绪');
  });

  test('init 在途时 release：旧 init 完成不得把服务重新标为就绪（最终已释放）', () async {
    final service = AudioService.instance;
    initGate = Completer<void>();
    final initFuture = service.init();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['init']);

    final releaseFuture = service.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(service.isInitialized, isFalse, reason: 'dispose 应先落未初始化');

    initGate!.complete();
    await initFuture;
    await releaseFuture;

    expect(service.isInitialized, isFalse, reason: '旧 init 不得覆盖新 release');
    expect(calls, ['init', 'release']);
  });

  test('释放会话后 setWakeLock(false) 不得自动 init（不重建空会话）', () async {
    final service = AudioService.instance;
    await service.init();
    await service.dispose();
    calls.clear();

    await service.setWakeLock(false);

    expect(calls, isEmpty, reason: '关闭唤醒锁不需要会话，不得发送 init/release');
    expect(service.isInitialized, isFalse);
  });
}
