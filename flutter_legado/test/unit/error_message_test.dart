/// errorMessage 统一错误文案提取器单元测试
///
/// [2026-10-06 iOS 实测修复] Rust FFI 以 BridgeError 抛错，裸插值 `$e` 只会
/// 得到 "Instance of 'BridgeError'"（iOS 实测：「MCP 服务切换失败: Instance of
/// BridgeError」）。本测锁定：提取 message、空 message 兜底、非 BridgeError
/// 保持 toString 三条语义。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/utils/error_message.dart';

void main() {
  group('errorMessage', () {
    test('BridgeError 提取 message（不再是 Instance of）', () {
      const e = BridgeError(
        message: '独立 MCP 服务启动失败：请先在「设置 → 高级 → 其他设置」配置'
            '「Web 书源访问令牌」（config:jsSourceApiToken）',
      );

      final text = errorMessage(e);

      expect(text, contains('MCP 服务启动失败'));
      expect(text, contains('Web 书源访问令牌'));
      expect(text, isNot(contains('Instance of')));
    });

    test('BridgeError message 为空/全空白 → 兜底文案（不留空文案）', () {
      expect(errorMessage(const BridgeError(message: '')), kUnknownErrorMessage);
      expect(
        errorMessage(const BridgeError(message: '   ')),
        kUnknownErrorMessage,
      );
    });

    test('非 BridgeError 异常保持 toString（含类型信息，便于排障）', () {
      expect(errorMessage(StateError('boom')), contains('boom'));
      expect(errorMessage(const FormatException('bad')), contains('bad'));
      expect(errorMessage('plain'), 'plain');
    });

    test('空 message 兜底文案本身非空且不含 Instance of', () {
      expect(kUnknownErrorMessage.trim(), isNotEmpty);
      expect(kUnknownErrorMessage, isNot(contains('Instance of')));
    });
  });
}
