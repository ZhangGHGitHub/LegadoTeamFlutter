/// 生物识别平台通道测试（契约 §2.53 批9d）
///
/// 覆盖：通道协议解析（getStatus/enable/unlock/deleteKey）、原生错误码
/// 映射、MissingPlugin/PlatformException 降级、桌面平台直接 unsupported、
/// 32B 令牌生成器。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/privacy_biometric_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    MethodChannelPrivacyBiometricService.channelName,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 测试显式声明平台可用，绕过 Windows/CI 宿主判定
  const service = MethodChannelPrivacyBiometricService(platformSupported: true);

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('错误码', () {
    test('fromCode 与原生字符串对齐；未知码回落 failed', () {
      expect(
        PrivacyBiometricErrorCode.fromCode('no_hardware'),
        PrivacyBiometricErrorCode.noHardware,
      );
      expect(
        PrivacyBiometricErrorCode.fromCode('permanently_locked_out'),
        PrivacyBiometricErrorCode.permanentlyLockedOut,
      );
      expect(
        PrivacyBiometricErrorCode.fromCode('key_invalidated'),
        PrivacyBiometricErrorCode.keyInvalidated,
      );
      expect(
        PrivacyBiometricErrorCode.fromCode('timeout'),
        PrivacyBiometricErrorCode.timeout,
      );
      expect(
        PrivacyBiometricErrorCode.fromCode('something_else'),
        PrivacyBiometricErrorCode.failed,
      );
      expect(
        PrivacyBiometricErrorCode.fromCode(null),
        PrivacyBiometricErrorCode.failed,
      );
    });

    test('命令错误中文文案非空且区分取消/失效', () {
      for (final value in PrivacyBiometricCommandError.values) {
        expect(value.message, isNotEmpty);
      }
      expect(
        PrivacyBiometricCommandError.fromCode(
          PrivacyBiometricErrorCode.keyInvalidated,
        ),
        PrivacyBiometricCommandError.keyInvalidated,
      );
      expect(PrivacyBiometricCommandError.cancelled.message, contains('取消'));
    });
  });

  group('令牌生成', () {
    test('标准 Base64 且解码恰 32B，两次不同', () {
      final a = generatePrivacyBiometricToken();
      final b = generatePrivacyBiometricToken();
      expect(base64Decode(a).length, 32);
      expect(base64Decode(b).length, 32);
      expect(a, isNot(b));
    });
  });

  group('桌面/未支持平台', () {
    test('默认构造在 Windows 测试宿主直接返回 unsupported（不触通道）', () async {
      const desktop = MethodChannelPrivacyBiometricService();
      final status = await desktop.getStatus();
      expect(status.available, isFalse);
      expect(status.reason, PrivacyBiometricErrorCode.unsupported);
      await expectLater(
        desktop.enable(generatePrivacyBiometricToken()),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.unsupported,
          ),
        ),
      );
    });
  });

  group('getStatus', () {
    test('available/hasKey/reason 解析', () async {
      mockChannel((call) async {
        expect(call.method, 'getStatus');
        return <String, Object?>{
          'available': false,
          'hasKey': true,
          'reason': 'not_enrolled',
        };
      });
      final status = await service.getStatus();
      expect(status.available, isFalse);
      expect(status.hasKey, isTrue);
      expect(status.reason, PrivacyBiometricErrorCode.notEnrolled);
      expect(status.unavailableMessage, contains('尚未录入'));
    });

    test('available=true 时 reason 恒 null', () async {
      mockChannel(
        (call) async => <String, Object?>{
          'available': true,
          'hasKey': true,
          'reason': 'failed',
        },
      );
      final status = await service.getStatus();
      expect(status.available, isTrue);
      expect(status.reason, isNull);
      expect(status.unavailableMessage, isEmpty);
    });

    test('通道 null/异常 → unavailable（不抛给 UI）', () async {
      mockChannel((call) async => null);
      var status = await service.getStatus();
      expect(status.available, isFalse);
      expect(status.reason, PrivacyBiometricErrorCode.unsupported);

      mockChannel((call) async => throw PlatformException(code: 'locked_out'));
      status = await service.getStatus();
      expect(status.available, isFalse);
      expect(status.reason, PrivacyBiometricErrorCode.lockedOut);
    });
  });

  group('enable', () {
    test('传递 token 并解析 envelope/iv', () async {
      final token = generatePrivacyBiometricToken();
      mockChannel((call) async {
        expect(call.method, 'enable');
        expect((call.arguments as Map)['token'], token);
        return <String, Object?>{'envelope': 'ZW52', 'iv': 'aXY='};
      });
      final envelope = await service.enable(token);
      expect(envelope.envelope, 'ZW52');
      expect(envelope.iv, 'aXY=');
    });

    test('返回缺 envelope/iv → failed 异常', () async {
      mockChannel((call) async => <String, Object?>{'envelope': 'ZW52'});
      await expectLater(
        service.enable(generatePrivacyBiometricToken()),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.failed,
          ),
        ),
      );
    });

    test('PlatformException 错误码透传（cancelled/key_invalidated）', () async {
      mockChannel(
        (call) async => throw PlatformException(code: 'key_invalidated'),
      );
      await expectLater(
        service.enable(generatePrivacyBiometricToken()),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.keyInvalidated,
          ),
        ),
      );
    });
  });

  group('unlock', () {
    test('传递 envelope/iv 并返回令牌', () async {
      final token = generatePrivacyBiometricToken();
      mockChannel((call) async {
        expect(call.method, 'unlock');
        final args = call.arguments as Map;
        expect(args['envelope'], 'ZW52');
        expect(args['iv'], 'aXY=');
        return token;
      });
      expect(await service.unlock(envelope: 'ZW52', iv: 'aXY='), token);
    });

    test('空令牌 → failed', () async {
      mockChannel((call) async => '');
      await expectLater(
        service.unlock(envelope: 'ZW52', iv: 'aXY='),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.failed,
          ),
        ),
      );
    });

    test('PlatformException 错误码透传', () async {
      mockChannel(
        (call) async => throw PlatformException(code: 'permanently_locked_out'),
      );
      await expectLater(
        service.unlock(envelope: 'ZW52', iv: 'aXY='),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.permanentlyLockedOut,
          ),
        ),
      );
    });
  });

  group('认证超时', () {
    const shortTimeout = MethodChannelPrivacyBiometricService(
      platformSupported: true,
      authTimeout: Duration(milliseconds: 20),
    );

    test('enable 无响应 → timeout 异常', () async {
      mockChannel((call) => Completer<Object?>().future);
      await expectLater(
        shortTimeout.enable(generatePrivacyBiometricToken()),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.timeout,
          ),
        ),
      );
    });

    test('unlock 无响应 → timeout 异常', () async {
      mockChannel((call) => Completer<Object?>().future);
      await expectLater(
        shortTimeout.unlock(envelope: 'ZW52', iv: 'aXY='),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.timeout,
          ),
        ),
      );
    });

    test('deleteKey 无响应 → 1s 后 timeout 异常（不拖死改密/清密）', () async {
      mockChannel((call) => Completer<Object?>().future);
      await expectLater(
        service.deleteKey(),
        throwsA(
          isA<PrivacyBiometricException>().having(
            (e) => e.code,
            'code',
            PrivacyBiometricErrorCode.timeout,
          ),
        ),
      );
    });
  });

  group('deleteKey', () {
    test('调用通道方法', () async {
      var called = 0;
      mockChannel((call) async {
        expect(call.method, 'deleteKey');
        called++;
        return null;
      });
      await service.deleteKey();
      expect(called, 1);
    });

    test('PlatformException 向上抛（由 Notifier 记录不阻断）', () async {
      mockChannel((call) async => throw PlatformException(code: 'failed'));
      await expectLater(
        service.deleteKey(),
        throwsA(isA<PrivacyBiometricException>()),
      );
    });
  });
}
