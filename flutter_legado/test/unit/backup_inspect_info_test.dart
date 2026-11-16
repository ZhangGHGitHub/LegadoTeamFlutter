/// BackupInspectInfo（契约 §2.11 `backupInspect`）解析单元测试
///
/// 钉住：正常形态解析、坏 JSON / 非对象 / 字段类型不符的明确错误。
/// 解析只在数据层完成，UI 不解析 JSON。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';

void main() {
  group('BackupInspectInfo.decode', () {
    test('zip + 需要密码 + 受保护文件列表', () {
      final info = BackupInspectInfo.decode(
        '{"format":"zip","passwordRequired":true,'
        '"passwordProtectedFiles":["servers.json","cookies.json"]}',
      );

      expect(info.format, BackupFormat.zip);
      expect(info.isZip, isTrue);
      expect(info.passwordRequired, isTrue);
      expect(info.passwordProtectedFiles, ['servers.json', 'cookies.json']);
    });

    test('json + 无需密码 + 空列表', () {
      final info = BackupInspectInfo.decode(
        '{"format":"json","passwordRequired":false,'
        '"passwordProtectedFiles":[]}',
      );

      expect(info.format, BackupFormat.json);
      expect(info.isZip, isFalse);
      expect(info.passwordRequired, isFalse);
      expect(info.passwordProtectedFiles, isEmpty);
    });

    test('坏 JSON → FormatException（明确原因）', () {
      expect(
        () => BackupInspectInfo.decode('{not-json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('JSON 无法解析'),
          ),
        ),
      );
    });

    test('JSON 非对象 → FormatException', () {
      expect(
        () => BackupInspectInfo.decode('[]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('不是对象'),
          ),
        ),
      );
    });

    test('未知 format → FormatException', () {
      expect(
        () => BackupInspectInfo.decode(
          '{"format":"7z","passwordRequired":false,'
          '"passwordProtectedFiles":[]}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('未知的备份格式'),
          ),
        ),
      );
    });

    test('passwordRequired 非布尔 → FormatException', () {
      expect(
        () => BackupInspectInfo.decode(
          '{"format":"zip","passwordRequired":"yes",'
          '"passwordProtectedFiles":[]}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('passwordRequired 不是布尔值'),
          ),
        ),
      );
    });

    test('passwordProtectedFiles 非数组/含非字符串 → FormatException', () {
      expect(
        () => BackupInspectInfo.decode(
          '{"format":"zip","passwordRequired":true,'
          '"passwordProtectedFiles":"servers.json"}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('passwordProtectedFiles 不是数组'),
          ),
        ),
      );

      expect(
        () => BackupInspectInfo.decode(
          '{"format":"zip","passwordRequired":true,'
          '"passwordProtectedFiles":["servers.json",1]}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('第 1 项不是字符串'),
          ),
        ),
      );
    });
  });

  // ─── 批44：自有 JSON 备份的字段级加密标记 ─────────────────────────

  group('BackupInspectInfo.decode（批44 JSON 加密标记）', () {
    test('加密 JSON：passwordRequired + 两个受保护字段 + encryption 标记', () {
      final info = BackupInspectInfo.decode(
        '{"format":"json","passwordRequired":true,'
        '"passwordProtectedFiles":["servers.json","directLinkUploadRule.json"],'
        '"encryption":"aes-ecb-md5"}',
      );

      expect(info.format, BackupFormat.json);
      expect(info.isZip, isFalse);
      expect(info.passwordRequired, isTrue);
      expect(info.passwordProtectedFiles, [
        'servers.json',
        'directLinkUploadRule.json',
      ]);
      expect(info.encryption, 'aes-ecb-md5');
    });

    test('明文 JSON：无 encryption 键 → encryption 为 null', () {
      final info = BackupInspectInfo.decode(
        '{"format":"json","passwordRequired":false,'
        '"passwordProtectedFiles":[]}',
      );

      expect(info.encryption, isNull);
    });

    test('encryption 非字符串/空串 → 视为缺失（纯诊断字段不阻断恢复）', () {
      final nonString = BackupInspectInfo.decode(
        '{"format":"json","passwordRequired":false,'
        '"passwordProtectedFiles":[],"encryption":123}',
      );
      expect(nonString.encryption, isNull);

      final empty = BackupInspectInfo.decode(
        '{"format":"json","passwordRequired":false,'
        '"passwordProtectedFiles":[],"encryption":""}',
      );
      expect(empty.encryption, isNull);
    });
  });
}
