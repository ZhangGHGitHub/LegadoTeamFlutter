// [批4b] PlatformBridgeService pageKey/recordKey 分发测试
//
// 编写：全栈工程师（批4b） ｜ 2026-11-04
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/platform_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = PlatformBridgeService.instance;
  final owner = Object();

  Future<void> emit(String method, Object? arguments) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'legado/reader_keys',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
  }

  setUp(() {
    bridge.volumeKeyCaptureOverride = true;
  });

  tearDown(() async {
    await bridge.releasePageKeyCapture(owner);
    bridge.unregisterVolumeKeyHandler();
    bridge.volumeKeyCaptureOverride = null;
  });

  test('pageKey 分发给活动 page owner（含 longPress/source）', () async {
    final received = <PageKeyEvent>[];
    await bridge.acquirePageKeyCapture(
      owner,
      prevKeys: '24,92',
      nextKeys: '25,93',
      volumeEnabled: true,
      hardcodedEnabled: true,
      onEvent: received.add,
    );

    await emit('pageKey', {
      'direction': 'down',
      'longPress': true,
      'source': 'custom',
    });
    await emit('pageKey', {
      'direction': 'up',
      'longPress': false,
      'source': 'hardcoded',
    });
    expect(received, hasLength(2));
    expect(received[0].direction, 'down');
    expect(received[0].longPress, isTrue);
    expect(received[0].source, 'custom');
    expect(received[1].source, 'hardcoded');
  });

  test('畸形 pageKey 忽略', () async {
    final received = <PageKeyEvent>[];
    await bridge.acquirePageKeyCapture(
      owner,
      prevKeys: '',
      nextKeys: '',
      volumeEnabled: true,
      hardcodedEnabled: true,
      onEvent: received.add,
    );
    await emit('pageKey', {'direction': 'left', 'longPress': false, 'source': 'custom'});
    await emit('pageKey', {'direction': 'up', 'longPress': 'yes', 'source': 'custom'});
    await emit('pageKey', {'direction': 'up', 'longPress': false, 'source': 'x'});
    await emit('pageKey', null);
    expect(received, isEmpty);
  });

  test('recordKey 广播到 pageKeyRecordStream', () async {
    final records = <int>[];
    final sub = bridge.pageKeyRecordStream.listen(records.add);
    addTearDown(sub.cancel);
    await bridge.acquirePageKeyCapture(
      owner,
      prevKeys: '',
      nextKeys: '',
      volumeEnabled: true,
      hardcodedEnabled: true,
      onEvent: (_) {},
    );
    await emit('recordKey', {'keyCode': 92});
    await emit('recordKey', {'keyCode': 4});
    await Future<void>.delayed(Duration.zero);
    expect(records, [92, 4]);
  });

  test('page 租约释放后，volume source 回退给 volume owner', () async {
    final pageEvents = <PageKeyEvent>[];
    final volumeEvents = <(String, bool)>[];
    await bridge.acquirePageKeyCapture(
      owner,
      prevKeys: '24',
      nextKeys: '',
      volumeEnabled: true,
      hardcodedEnabled: true,
      onEvent: pageEvents.add,
    );
    final volumeOwner = Object();
    addTearDown(() => bridge.releaseVolumeKeyCapture(volumeOwner));
    await bridge.acquireVolumeKeyCapture(
      volumeOwner,
      (direction, longPress) async {
        volumeEvents.add((direction, longPress));
      },
    );
    // page owner 在活动位，pageKey source=volume 仍走 page
    await emit('pageKey', {
      'direction': 'down',
      'longPress': false,
      'source': 'volume',
    });
    expect(pageEvents, hasLength(1));
    expect(volumeEvents, isEmpty);

    await bridge.releasePageKeyCapture(owner);
    await emit('pageKey', {
      'direction': 'down',
      'longPress': true,
      'source': 'volume',
    });
    expect(volumeEvents, [('down', true)]);
  });

  test('旧 volumeKey 协议：无 volume owner 时转交 page owner', () async {
    final received = <PageKeyEvent>[];
    await bridge.acquirePageKeyCapture(
      owner,
      prevKeys: '',
      nextKeys: '',
      volumeEnabled: true,
      hardcodedEnabled: true,
      onEvent: received.add,
    );
    await emit('volumeKey', {'direction': 'up', 'longPress': false});
    expect(received, hasLength(1));
    expect(received.single.source, 'volume');
    expect(received.single.direction, 'up');
  });

  test('page 租约清空但 volume owner 仍在：复位 native 且清除录制标记', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('legado/reader_keys'),
          (call) async {
            calls.add(call);
            return true;
          },
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('legado/reader_keys'),
            null,
          );
    });
    final volumeOwner = Object();
    addTearDown(() => bridge.releaseVolumeKeyCapture(volumeOwner));
    await bridge.acquirePageKeyCapture(
      owner,
      prevKeys: '24',
      nextKeys: '25',
      volumeEnabled: false,
      hardcodedEnabled: true,
      onEvent: (_) {},
    );
    await bridge.acquireVolumeKeyCapture(
      volumeOwner,
      (_, _) async {},
    );
    bridge.keyRecording.value = true;
    await bridge.releasePageKeyCapture(owner);
    expect(
      calls.any((c) => c.method == 'resetPageKeyConfig'),
      isTrue,
      reason: 'volume 租约仍在也要复位 custom/volumeEnabled 残留',
    );
    expect(bridge.keyRecording.value, isFalse);
  });

  test('setKeyRecording 更新 notifier；非 Android 不抛', () async {
    await bridge.setKeyRecording(true);
    expect(bridge.keyRecording.value, isTrue);
    await bridge.setKeyRecording(false);
    expect(bridge.keyRecording.value, isFalse);

    bridge.volumeKeyCaptureOverride = false;
    await bridge.setKeyRecording(true);
    expect(bridge.keyRecording.value, isTrue);
    await bridge.setKeyRecording(false);
  });
}
