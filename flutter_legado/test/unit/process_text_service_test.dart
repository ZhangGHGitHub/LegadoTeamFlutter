// 「文字操作显示搜索」（process_text）单测
//
// 覆盖：Android 通道调用（isEnabled/setEnabled 参数与返回值）；
// 偏好 → 原生组件同步；非 Android 平台不调用通道、可用性为 unsupported；
// 原生桥未注册时可用性为 bridgeUnavailable 且 setEnabled 返回 null；
// manifest 结构：PROCESS_TEXT 由独立 activity-alias 承载（可独立启停）且
// 主 Activity 不再内嵌（避免系统菜单出现重复项）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/process_text_service.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('legado/process_text');
  late List<MethodCall> calls;
  late bool platformEnabled;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void installBridge() {
    messenger().setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isEnabled':
          return platformEnabled;
        case 'setEnabled':
          final enabled = (call.arguments as Map)['enabled'] as bool;
          platformEnabled = enabled;
          return enabled;
        default:
          return null;
      }
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    platformEnabled = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('Android 通道接线', () {
    test('isEnabled 读取原生组件状态', () async {
      installBridge();
      expect(await ProcessTextMenuService.isEnabled(), isTrue);

      platformEnabled = false;
      expect(await ProcessTextMenuService.isEnabled(), isFalse);
      expect(calls.map((c) => c.method), ['isEnabled', 'isEnabled']);
    });

    test('setEnabled 下发 enabled 参数并回传实际状态', () async {
      installBridge();

      expect(await ProcessTextMenuService.setEnabled(false), isFalse);
      expect(platformEnabled, isFalse);
      expect(calls.single.method, 'setEnabled');
      expect(calls.single.arguments, {'enabled': false});

      expect(await ProcessTextMenuService.setEnabled(true), isTrue);
      expect(platformEnabled, isTrue);
    });

    test('原生返回 null → setEnabled 返回 null（调用方回滚开关）', () async {
      messenger().setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      expect(await ProcessTextMenuService.setEnabled(false), isNull);
      expect(calls.single.method, 'setEnabled');
    });

    test('syncFromPref 把偏好值应用到原生组件', () async {
      installBridge();
      SharedPreferences.setMockInitialValues({PrefKeys.processText: false});

      await ProcessTextMenuService.syncFromPref(SettingsService());

      expect(platformEnabled, isFalse);
      expect(calls.single.method, 'setEnabled');
      expect(calls.single.arguments, {'enabled': false});
    });

    test('syncFromPref 缺省（未设置）按开启处理', () async {
      installBridge();
      platformEnabled = false;
      SharedPreferences.setMockInitialValues({});

      await ProcessTextMenuService.syncFromPref(SettingsService());

      expect(platformEnabled, isTrue);
    });

    test(
      '原生桥未注册 → availability=bridgeUnavailable，setEnabled 返回 null',
      () async {
        expect(
          await ProcessTextMenuService.availability(),
          ProcessTextAvailability.bridgeUnavailable,
        );
        expect(await ProcessTextMenuService.isEnabled(), isFalse);
        expect(await ProcessTextMenuService.setEnabled(false), isNull);
        expect(calls, isEmpty);
      },
    );
  });

  group('非 Android 平台', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });

    test('isSupported=false，不调用原生通道', () async {
      installBridge();

      expect(ProcessTextMenuService.isSupported, isFalse);
      expect(
        await ProcessTextMenuService.availability(),
        ProcessTextAvailability.unsupportedPlatform,
      );
      expect(await ProcessTextMenuService.isEnabled(), isFalse);
      expect(await ProcessTextMenuService.setEnabled(true), isNull);
      expect(calls, isEmpty);
    });

    test('syncFromPref 直接跳过', () async {
      installBridge();
      SharedPreferences.setMockInitialValues({PrefKeys.processText: false});

      await ProcessTextMenuService.syncFromPref(SettingsService());

      expect(calls, isEmpty);
    });
  });

  group('Android manifest 结构（开关能真正影响系统菜单）', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    test('PROCESS_TEXT 由独立 activity-alias 承载且指向 MainActivity', () {
      final alias = RegExp(
        r'<activity-alias[\s\S]*?android:name="\.ProcessTextAlias"[\s\S]*?</activity-alias>',
      ).firstMatch(manifest);
      expect(alias, isNotNull, reason: '缺少 .ProcessTextAlias 组件');
      final block = alias!.group(0)!;
      expect(block, contains('android:targetActivity=".MainActivity"'));
      expect(block, contains('android.intent.action.PROCESS_TEXT'));
      expect(block, contains('android:mimeType="text/plain"'));
      // 默认启用 = 行为与接线前一致（ProcessTextBridge 负责动态启停）
      expect(block, contains('android:enabled="true"'));
    });

    test('MainActivity 不再内嵌 PROCESS_TEXT（避免系统菜单重复项）', () {
      final start = manifest.indexOf('android:name=".MainActivity"');
      expect(start, greaterThanOrEqualTo(0));
      final end = manifest.indexOf('</activity>', start);
      expect(end, greaterThan(start));
      final mainActivityBlock = manifest.substring(start, end);
      expect(
        mainActivityBlock,
        isNot(contains('android.intent.action.PROCESS_TEXT')),
      );
    });
  });
}
