/// errorMessage 统一错误文案提取器单元测试
///
/// [2026-10-06 iOS 实测修复] Rust FFI 以 BridgeError 抛错，裸插值 `$e` 只会
/// 得到 "Instance of 'BridgeError'"（iOS 实测：「MCP 服务切换失败: Instance of
/// BridgeError」）。本测锁定：提取 message、空 message 兜底、非 BridgeError
/// 保持 toString 三条语义。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/services/file_save_channel.dart';
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

  // P3-1：映射改为「整串形态锚定」——含中文的业务文案一律不改写，
  // 避免「上传超时(timeout)」被吞成「网络连接超时」。
  group('errorMessage D4 锚定匹配（P3-1）', () {
    test('业务文案含 timeout 不被吞（中文业务前缀跳过映射）', () {
      expect(
        friendlyErrorMessage('上传超时，请重试（timeout）'),
        '上传超时，请重试（timeout）',
      );
      expect(
        errorMessage(const BridgeError(message: 'Network error: 上传超时(timeout)，请重试')),
        '上传超时(timeout)，请重试',
      );
      expect(
        friendlyErrorMessage('下载失败：connection refused，请检查网络'),
        '下载失败：connection refused，请检查网络',
      );
    });

    test('纯 ASCII 低层连接错误仍按整串形态映射', () {
      expect(
        friendlyErrorMessage(
          'error sending request for url (http://127.0.0.1:1/api): '
          'error trying to connect: tcp connect error: Connection refused '
          '(os error 111)',
        ),
        kConnectionRefusedMessage,
      );
      expect(
        friendlyErrorMessage('operation timed out (os error 110)'),
        kConnectionTimeoutMessage,
      );
    });

    test('英文业务文案不命中低层标记时原样保留', () {
      expect(
        friendlyErrorMessage('Request failed: builder error'),
        'Request failed: builder error',
      );
    });
  });

  // P2-3：权限拒绝/系统另存失败的主文案为中文短句，技术详情可复制
  group('errorMessage 权限与另存失败（P2-3）', () {
    test('Permission Denial / SecurityException → 没有写入权限', () {
      expect(
        friendlyErrorMessage(
          'Permission Denial: writing com.android.providers.downloads.'
          'DownloadStorageProvider uri content://com.android.providers.'
          'downloads.documents/document/7 from pid=1, uid=2 requires '
          'android.permission.MANAGE_DOCUMENTS, or grantUriPermission()',
        ),
        kPermissionDeniedMessage,
      );
      expect(
        friendlyErrorMessage('java.lang.SecurityException: nope'),
        kPermissionDeniedMessage,
      );
    });

    test('FileSaveException：主文案中文，技术详情走 errorDetailMessage', () {
      const e = FileSaveException(
        code: 'SAVE_FAILED',
        message: '无法写入所选位置，请换一个文件夹重试',
        detail: 'Permission Denial: requires '
            'android.permission.MANAGE_DOCUMENTS',
      );
      expect(errorMessage(e), '无法写入所选位置，请换一个文件夹重试');
      expect(errorDetailMessage(e), contains('MANAGE_DOCUMENTS'));
      expect(errorDetailMessage(e), isNot(contains('无法写入')));
    });

    test('FileSaveException 无 detail 时详情回落到中文文案', () {
      const e = FileSaveException(
        code: 'EMPTY_BYTES',
        message: '导出内容为空，未创建文件',
      );
      expect(errorMessage(e), '导出内容为空，未创建文件');
      expect(errorDetailMessage(e), '导出内容为空，未创建文件');
    });
  });
}
