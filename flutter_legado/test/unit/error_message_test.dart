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

  // D4 最小映射：剥离底层前缀 + 连接类错误中文化（原始文本保留在
  // errorDetailMessage，供失败面板次要行/复制排障）
  group('errorMessage D4 展示层映射', () {
    test('剥离 FFI error 前缀，业务文案原样保留', () {
      const e = BridgeError(
        message: 'FFI error: 上传失败,{"error": "mock upload failure"}',
      );
      expect(errorMessage(e), '上传失败,{"error": "mock upload failure"}');
      expect(
        errorDetailMessage(e),
        'FFI error: 上传失败,{"error": "mock upload failure"}',
      );
    });

    test('连接被拒绝（os error 111 / connection refused）→ 无法连接服务器', () {
      const e = BridgeError(
        message:
            'Network error: Request failed: error sending request: connection '
            'refused (os error 111)',
      );
      expect(errorMessage(e), kConnectionRefusedMessage);
      expect(errorMessage(e), '无法连接服务器');
      expect(errorDetailMessage(e), contains('os error 111'));
    });

    test('无需映射的普通错误保持原样', () {
      expect(errorMessage(const BridgeError(message: '状态码 500')), '状态码 500');
      final raw = StateError('内部错误');
      expect(errorMessage(raw), raw.toString());
      expect(errorDetailMessage(raw), raw.toString());
    });

    test('重复前缀与中英文冒号均可剥离', () {
      expect(
        friendlyErrorMessage('FFI error: Network error：connection refused'),
        kConnectionRefusedMessage,
      );
      expect(friendlyErrorMessage('FFI error: FFI error: 操作失败'), '操作失败');
      expect(
        friendlyErrorMessage('Network error: Request failed: builder error'),
        'Request failed: builder error',
      );
      expect(friendlyErrorMessage('  '), kUnknownErrorMessage);
    });
  });
}
