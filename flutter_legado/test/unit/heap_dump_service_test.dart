import 'package:flutter/services.dart';
import 'package:flutter_legado/src/services/crash_log_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// P1-5 关于页堆转储真实现 —— 服务层分支单测
///
/// 覆盖：
/// 1. 非支持平台（iOS/桌面）归一为 UnsupportedError（明确文案）；
/// 2. Android 成功路径：原生通道返回落盘路径；
/// 3. Android 通道缺失（MissingPluginException）归一为 UnsupportedError；
/// 4. 通道返回空路径报 StateError。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('legado/heap_dump');

  tearDown(() {
    CrashLogService.platformIsAndroidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('CrashLogService.createHeapDump', () {
    test('非 Android 平台抛 UnsupportedError 且带明确文案', () async {
      CrashLogService.platformIsAndroidOverride = false;
      await expectLater(
        CrashLogService.instance.createHeapDump(),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            '当前平台不支持创建堆转储',
          ),
        ),
      );
    });

    test('Android 成功路径返回原生落盘路径', () async {
      CrashLogService.platformIsAndroidOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'dump');
        return '/cache/heapDump/heap-dump-manually-123.hprof';
      });
      final path = await CrashLogService.instance.createHeapDump();
      expect(path, '/cache/heapDump/heap-dump-manually-123.hprof');
    });

    test('通道缺失（iOS 漏实现）归一为 UnsupportedError', () async {
      CrashLogService.platformIsAndroidOverride = true;
      // 不注册 mock handler → MissingPluginException
      await expectLater(
        CrashLogService.instance.createHeapDump(),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('通道返回空路径报 StateError', () async {
      CrashLogService.platformIsAndroidOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => '');
      await expectLater(
        CrashLogService.instance.createHeapDump(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
