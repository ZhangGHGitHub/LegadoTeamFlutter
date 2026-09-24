// [iOS 视角F B1] SystemBrightness iOS 分支单测
//
// 背景：`io.legado.app/brightness` 通道仅 Android 注册。iOS 上未注册时
// MethodChannel.invokeMethod 抛 MissingPluginException（不是
// PlatformException，`on PlatformException` 捕获不住）→ 未捕获异常
// 上抛调用方（阅读器底栏亮度行整行被静默吞掉）。
//
// 本组测试用 mock MethodChannel（handler 一律抛 MissingPluginException，
// 模拟未注册插件）断言：
// 1. iOS 语义下 isAutoBrightness / setAutoBrightness 完全不调通道、
//    不抛异常（固定 false / no-op）；
// 2. iOS 语义下 isSupported / getBrightness 不抛（fallback 语义）；
// 3. Android 语义下两方法仍按原契约走通道（回归防 iOS 分支改变既有行为）。
//
// 平台标志经 SystemBrightness.platformIsIOS 测试缝隙注入，测试后恢复。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/system_brightness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.legado.app/brightness');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 模拟 iOS（平台标志缝隙），teardown 恢复
  void simulateIOS() {
    SystemBrightness.platformIsIOS = () => true;
    addTearDown(() => SystemBrightness.platformIsIOS = () => Platform.isIOS);
  }

  /// 模拟 Android（平台标志缝隙），teardown 恢复
  void simulateAndroid() {
    SystemBrightness.platformIsIOS = () => false;
    addTearDown(() => SystemBrightness.platformIsIOS = () => Platform.isIOS);
  }

  /// 安装通道 mock：记录调用，默认抛 MissingPluginException
  ///（模拟 iOS 未注册插件）。返回调用记录。
  List<MethodCall> mockChannel() {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // MethodCall 不持有 channel 名；本 SDK 的 MissingPluginException
      // 构造器仅接受可选 message（无 channelName/methodName 命名参数）
      throw MissingPluginException(
        'No implementation found for ${call.method}',
      );
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });
    return calls;
  }

  group('iOS 分支（B1：通道未注册不抛异常）', () {
    test('isAutoBrightness 不触碰未注册通道，固定返回 false', () async {
      simulateIOS();
      final calls = mockChannel();
      expect(await SystemBrightness.isAutoBrightness(), isFalse);
      expect(calls, isEmpty, reason: 'iOS 不得调用未注册的亮度通道');
    });

    test('setAutoBrightness 为 no-op，不抛异常', () async {
      simulateIOS();
      final calls = mockChannel();
      await SystemBrightness.setAutoBrightness(true);
      expect(calls, isEmpty, reason: 'iOS 不得调用未注册的亮度通道');
    });

    test('isSupported 返回 true，getBrightness 回落 0.5 不抛', () async {
      simulateIOS();
      mockChannel();
      expect(await SystemBrightness.isSupported(), isTrue);
      // ScreenBrightness 通道同样无 handler → 内部 catch 回落 0.5
      expect(await SystemBrightness.getBrightness(), 0.5);
    });
  });

  group('Android 通道回归（iOS 分支不得改变既有语义）', () {
    test('isAutoBrightness 仍走通道并透传结果', () async {
      simulateAndroid();
      final calls = mockChannel();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      expect(await SystemBrightness.isAutoBrightness(), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'isAutoBrightness');
    });

    test('setAutoBrightness 仍走通道并透传参数', () async {
      simulateAndroid();
      final calls = mockChannel();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await SystemBrightness.setAutoBrightness(true);
      expect(calls, hasLength(1));
      // MethodCall 未覆写 operator ==（identity 语义），须逐项断言
      expect(calls.single.method, 'setAutoBrightness');
      expect(calls.single.arguments, isTrue);
    });

    test('getBrightness 通道值 0-255 换算为 0.0-1.0', () async {
      simulateAndroid();
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getSystemBrightness':
            return 128;
          case 'isBrightnessSupported':
            return true;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await SystemBrightness.getBrightness(), closeTo(128 / 255.0, 1e-9));
      expect(await SystemBrightness.isSupported(), isTrue);
    });
  });
}
