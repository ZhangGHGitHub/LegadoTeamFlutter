// [批1b-2a 审查回修 P3-4 | 2026-11-01] 音量键事件参数解析单测 —
// 全栈工程师
//
// 背景：ReaderKeysBridge 事件形状由旧 String 升级为
// `{direction, longPress}`（批1b-2a），Dart 侧
// PlatformBridgeService.registerVolumeKeyHandler 必须：
// 1. 兼容旧 String（升级期原生/Dart 混装）；
// 2. 解析新 Map 的 direction/longPress；
// 3. 畸形参数（null/非字符串/未知方向/错类型）静默忽略，不回调、
//    不抛异常（MethodChannel 边界不能让坏数据影响阅读器）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/platform_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = PlatformBridgeService.instance;
  late List<(String, bool)> calls;

  Future<void> emit(Object? arguments) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'legado/reader_keys',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('volumeKey', arguments),
          ),
          (_) {},
        );
  }

  setUp(() {
    calls = <(String, bool)>[];
    // 测试宿主（Windows）Platform.isAndroid=false：经分派覆写走 Android 分支
    bridge.volumeKeyCaptureOverride = true;
    bridge.registerVolumeKeyHandler(
      (direction, longPress) async => calls.add((direction, longPress)),
    );
  });

  tearDown(() {
    bridge.unregisterVolumeKeyHandler();
    bridge.volumeKeyCaptureOverride = null;
  });

  group('[P3-4] 音量键事件参数解析', () {
    test('旧 String 形态向后兼容：up/down → longPress=false', () async {
      await emit('up');
      await emit('down');
      expect(calls, [('up', false), ('down', false)]);
    });

    test('新 Map 形态：direction + longPress 原样解析', () async {
      await emit({'direction': 'down', 'longPress': true});
      await emit({'direction': 'up', 'longPress': false});
      expect(calls, [('down', true), ('up', false)]);
    });

    test('Map 缺 longPress：按短按兜底', () async {
      await emit({'direction': 'up'});
      expect(calls, [('up', false)]);
    });

    test('畸形参数静默忽略（不回调、不抛异常）', () async {
      await emit(null);
      await emit('left');
      await emit(42);
      await emit(<Object?>[]);
      await emit({'direction': 'left'});
      await emit({'direction': 'up', 'longPress': 'yes'});
      await emit({'direction': 'up', 'longPress': 1});
      await emit({'longPress': true});
      await emit({'direction': 1, 'longPress': true});
      expect(calls, isEmpty, reason: '非法方向/类型一律不触发翻页回调');
    });

    test('非 volumeKey 方法名忽略', () async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'legado/reader_keys',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('otherMethod', 'up'),
            ),
            (_) {},
          );
      expect(calls, isEmpty);
    });
  });
}
