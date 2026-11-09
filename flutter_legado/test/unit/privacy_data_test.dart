/// 隐私与私密标记数据层测试（契约 §2.53，批9a）
///
/// 覆盖：Book/BookGroup isPrivate 缺省与 JSON 往返；
/// PrivacyApiJson 数组形态/元素类型校验；
/// MockBookApi 密码生命周期、私密书/组 CRUD 与实例隔离。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/privacy_api_json.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Book.isPrivate', () {
    test('缺键默认 false', () {
      final book = Book.fromJson(const {'bookUrl': 'https://a/1'});
      expect(book.isPrivate, isFalse);
    });

    test('camelCase 往返与 copyWith', () {
      const book = Book(bookUrl: 'https://a/1', isPrivate: true);
      final json = book.toJson();
      expect(json['isPrivate'], isTrue);
      expect(json.containsKey('is_private'), isFalse);
      expect(Book.fromJson(json).isPrivate, isTrue);
      expect(book.copyWith(isPrivate: false).isPrivate, isFalse);
    });

    test('相等语义包含 isPrivate', () {
      const a = Book(bookUrl: 'https://a/1', isPrivate: true);
      const b = Book(bookUrl: 'https://a/1', isPrivate: true);
      const c = Book(bookUrl: 'https://a/1');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('BookGroup.isPrivate', () {
    test('缺键默认 false', () {
      final group = BookGroup.fromJson(const {'groupId': 4});
      expect(group.isPrivate, isFalse);
    });

    test('camelCase 往返与 copyWith', () {
      const group = BookGroup(groupId: 4, groupName: '私密组', isPrivate: true);
      final json = group.toJson();
      expect(json['isPrivate'], isTrue);
      expect(BookGroup.fromJson(json).isPrivate, isTrue);
      expect(group.copyWith(isPrivate: false).isPrivate, isFalse);
    });
  });

  group('PrivacyApiJson', () {
    test('合法字符串数组解码', () {
      expect(PrivacyApiJson.decodeBookUrls('["b","a"]'), <String>[
        'b',
        'a',
      ], reason: '解码不重排，稳定排序由 Rust 保证');
      expect(PrivacyApiJson.decodeBookUrls('[]'), isEmpty);
    });

    test('合法整数数组解码', () {
      expect(PrivacyApiJson.decodeGroupIds('[16,4,1]'), <int>[16, 4, 1]);
      expect(PrivacyApiJson.decodeGroupIds('[]'), isEmpty);
    });

    test('非数组抛 FormatException', () {
      expect(
        () => PrivacyApiJson.decodeBookUrls('{"x":1}'),
        throwsFormatException,
      );
      expect(
        () => PrivacyApiJson.decodeGroupIds('null'),
        throwsFormatException,
      );
    });

    test('元素类型不符抛 FormatException（不静默跳过）', () {
      expect(
        () => PrivacyApiJson.decodeBookUrls('["ok",42]'),
        throwsFormatException,
      );
      expect(
        () => PrivacyApiJson.decodeGroupIds('[1,"2"]'),
        throwsFormatException,
      );
    });

    // ===== [批9d] 生物识别状态 JSON =====

    test('生物状态：configured true 带 envelope/iv', () {
      final state = PrivacyApiJson.decodeBiometricState(
        '{"configured":true,"envelope":"ZW52","iv":"aXY="}',
      );
      expect(state.configured, isTrue);
      expect(state.envelope, 'ZW52');
      expect(state.iv, 'aXY=');
      expect(state.toString(), isNot(contains('ZW52')), reason: 'toString 脱敏');
    });

    test('生物状态：未配置时 envelope/iv 为 null', () {
      final state = PrivacyApiJson.decodeBiometricState(
        '{"configured":false,"envelope":null,"iv":null}',
      );
      expect(state.configured, isFalse);
      expect(state.envelope, isNull);
      expect(state.iv, isNull);
    });

    test('生物状态：形态/类型不符抛 FormatException', () {
      expect(
        () => PrivacyApiJson.decodeBiometricState('[]'),
        throwsFormatException,
      );
      expect(
        () => PrivacyApiJson.decodeBiometricState('{"configured":"yes"}'),
        throwsFormatException,
      );
      expect(
        () => PrivacyApiJson.decodeBiometricState(
          '{"configured":false,"envelope":1,"iv":null}',
        ),
        throwsFormatException,
      );
      expect(
        () => PrivacyApiJson.decodeBiometricState(
          '{"configured":true,"envelope":null,"iv":null}',
        ),
        throwsFormatException,
        reason: 'configured=true 必须同时有信封与 IV',
      );
    });
  });

  group('MockBookApi 隐私密码', () {
    late MockBookApi api;

    setUp(() {
      api = MockBookApi();
    });

    test('无凭据 has/verify 均为 false', () async {
      expect(await api.privacyHasPassword(), isFalse);
      expect(await api.privacyVerifyPassword('x'), isFalse);
      expect(await api.privacyVerifyPassword(''), isFalse);
    });

    test('设置→校验→错误旧密拒绝→改密→清除', () async {
      expect(await api.privacySetPassword('first-pass'), isTrue);
      expect(await api.privacyHasPassword(), isTrue);
      expect(await api.privacyVerifyPassword('first-pass'), isTrue);
      expect(await api.privacyVerifyPassword('wrong'), isFalse);

      // 已有凭据：缺旧密/错旧密 → false，旧密仍有效
      expect(await api.privacySetPassword('second-pass'), isFalse);
      expect(
        await api.privacySetPassword('second-pass', oldPassword: 'bad'),
        isFalse,
      );
      expect(await api.privacyVerifyPassword('first-pass'), isTrue);

      expect(
        await api.privacySetPassword('second-pass', oldPassword: 'first-pass'),
        isTrue,
      );
      expect(await api.privacyVerifyPassword('second-pass'), isTrue);
      expect(await api.privacyVerifyPassword('first-pass'), isFalse);

      await api.privacyClearPassword();
      expect(await api.privacyHasPassword(), isFalse);
      expect(await api.privacyVerifyPassword('second-pass'), isFalse);
      // 重复清除 no-op
      await api.privacyClearPassword();
    });

    test('新密码 trim 后非空且不超过 128 字符', () async {
      expect(await api.privacySetPassword(''), isFalse);
      expect(await api.privacySetPassword('   '), isFalse);
      expect(await api.privacySetPassword('x' * 129), isFalse);
      expect(await api.privacyHasPassword(), isFalse);

      expect(await api.privacySetPassword('x' * 128), isTrue);
      expect(await api.privacyVerifyPassword('x' * 128), isTrue);
    });
  });

  group('MockBookApi 私密标记', () {
    late MockBookApi api;

    setUp(() {
      api = MockBookApi();
    });

    test('批量书籍私密标记：命中数/不存在不计数/空列表/重复去重', () async {
      await api.addBook(
        const Book(
          bookUrl: 'https://mock/privacy/a',
          name: '隐私A',
          author: '批9a',
        ),
      );
      await api.addBook(
        const Book(
          bookUrl: 'https://mock/privacy/b',
          name: '隐私B',
          author: '批9a',
        ),
      );

      expect(await api.setBooksPrivate(const [], true), 0);
      expect(
        await api.setBooksPrivate(const [
          'https://mock/privacy/a',
          'https://mock/privacy/b',
          'https://mock/privacy/a',
          'https://mock/privacy/missing',
        ], true),
        2,
        reason: '重复 URL 去重、不存在的 URL 不计数',
      );
      expect(await api.getPrivateBookUrls(), const [
        'https://mock/privacy/a',
        'https://mock/privacy/b',
      ]);
      final books = await api.getBooks();
      expect(
        books.firstWhere((b) => b.bookUrl.endsWith('/a')).isPrivate,
        isTrue,
      );

      expect(
        await api.setBooksPrivate(const ['https://mock/privacy/b'], false),
        1,
      );
      expect(await api.getPrivateBookUrls(), const ['https://mock/privacy/a']);
      expect(
        (await api.getBooks())
            .firstWhere((b) => b.bookUrl.endsWith('/b'))
            .isPrivate,
        isFalse,
      );
    });

    test('分组私密标记：命中/未命中/列表升序', () async {
      expect(await api.setBookGroupPrivate(1, true), isTrue);
      expect(await api.setBookGroupPrivate(2, true), isTrue);
      expect(await api.setBookGroupPrivate(999999, true), isFalse);
      expect(await api.getPrivateGroupIds(), const [1, 2]);

      final groups = await api.getBookGroups();
      expect(groups.firstWhere((g) => g.groupId == 1).isPrivate, isTrue);
      expect(groups.firstWhere((g) => g.groupId == 2).isPrivate, isTrue);

      expect(await api.setBookGroupPrivate(1, false), isTrue);
      expect(await api.getPrivateGroupIds(), const [2]);
    });

    test('新建分组强制非私密；更新分组保留旧私密标记', () async {
      final created = await api.addBookGroup(
        const BookGroup(groupId: 99, groupName: '新组', isPrivate: true),
      );
      expect(created.isPrivate, isFalse, reason: '新分组 isPrivate 只能经单独接口设置');
      expect(
        (await api.getBookGroups())
            .firstWhere((g) => g.groupId == created.groupId)
            .isPrivate,
        isFalse,
      );

      expect(await api.setBookGroupPrivate(1, true), isTrue);
      final current = (await api.getBookGroups()).firstWhere(
        (g) => g.groupId == 1,
      );
      // 模拟 UI 持陈旧快照（isPrivate=false）更新名称
      await api.updateBookGroup(
        current.copyWith(groupName: '科幻改名', isPrivate: false),
      );
      final updated = (await api.getBookGroups()).firstWhere(
        (g) => g.groupId == 1,
      );
      expect(updated.groupName, '科幻改名');
      expect(updated.isPrivate, isTrue, reason: '更新分组不得清除私密标记');
    });

    test('实例隔离：两个 MockBookApi 的私密状态互不影响', () async {
      await api.privacySetPassword('p1');
      await api.setBookGroupPrivate(1, true);

      final other = MockBookApi();
      expect(await other.privacyHasPassword(), isFalse);
      expect(await other.getPrivateGroupIds(), isEmpty);
    });
  });

  // ===== [批9d] 生物识别快捷解锁（Mock 契约） =====

  group('MockBookApi 生物识别', () {
    late MockBookApi api;
    final token = base64Encode(List<int>.filled(32, 3));
    final otherToken = base64Encode(List<int>.filled(32, 4));
    final envelope = base64Encode(List<int>.filled(64, 9));
    final iv = base64Encode(List<int>.filled(12, 5));

    setUp(() {
      api = MockBookApi();
    });

    test('必须已有密码；无密码 set false 且状态未配置', () async {
      expect(await api.privacyBiometricSet(token, envelope, iv), isFalse);
      final state = PrivacyApiJson.decodeBiometricState(
        await api.privacyBiometricStateGet(),
      );
      expect(state.configured, isFalse);
      expect(state.envelope, isNull);
      expect(state.iv, isNull);
      expect(await api.privacyBiometricVerify(token), isFalse);
    });

    test('设置→状态→校验→清除 往返；状态 JSON 不含摘要', () async {
      await api.privacySetPassword('pw');
      expect(await api.privacyBiometricSet(token, envelope, iv), isTrue);

      final raw = await api.privacyBiometricStateGet();
      expect(raw, isNot(contains('token_hash')));
      final state = PrivacyApiJson.decodeBiometricState(raw);
      expect(state.configured, isTrue);
      expect(state.envelope, envelope);
      expect(state.iv, iv);

      expect(await api.privacyBiometricVerify(token), isTrue);
      expect(await api.privacyBiometricVerify(otherToken), isFalse);
      expect(await api.privacyBiometricVerify('not-base64!!'), isFalse);

      await api.privacyBiometricClear();
      expect(
        PrivacyApiJson.decodeBiometricState(
          await api.privacyBiometricStateGet(),
        ).configured,
        isFalse,
      );
      expect(await api.privacyBiometricVerify(token), isFalse);
      // 重复清除 no-op
      await api.privacyBiometricClear();
    });

    test('长度/编码校验：token 31/33B、iv 11/13B、envelope 空/4097B', () async {
      await api.privacySetPassword('pw');
      final cases = <(String, String, String)>[
        (base64Encode(List.filled(31, 3)), envelope, iv),
        (base64Encode(List.filled(33, 3)), envelope, iv),
        (token, envelope, base64Encode(List.filled(11, 5))),
        (token, envelope, base64Encode(List.filled(13, 5))),
        (token, '', iv),
        (token, base64Encode(List.filled(4097, 9)), iv),
        ('', envelope, iv),
        ('not-base64!!', envelope, iv),
        (token, 'not-base64!!', iv),
        (token, envelope, 'not-base64!!'),
      ];
      for (final (t, e, i) in cases) {
        expect(
          await api.privacyBiometricSet(t, e, i),
          isFalse,
          reason: '非法长度/编码必须拒绝（env=${e.length}）',
        );
      }
      expect(
        PrivacyApiJson.decodeBiometricState(
          await api.privacyBiometricStateGet(),
        ).configured,
        isFalse,
      );
      // 边界合法：1B / 4096B 信封
      expect(
        await api.privacyBiometricSet(token, base64Encode([1]), iv),
        isTrue,
      );
      expect(
        await api.privacyBiometricSet(
          token,
          base64Encode(List.filled(4096, 9)),
          iv,
        ),
        isTrue,
      );
    });

    test('改密/清密清空生物凭据', () async {
      await api.privacySetPassword('first');
      expect(await api.privacyBiometricSet(token, envelope, iv), isTrue);

      // 失败改密不清空
      expect(
        await api.privacySetPassword('second', oldPassword: 'bad'),
        isFalse,
      );
      expect(await api.privacyBiometricVerify(token), isTrue);

      // 成功改密 → 清空
      expect(
        await api.privacySetPassword('second', oldPassword: 'first'),
        isTrue,
      );
      expect(await api.privacyBiometricVerify(token), isFalse);
      expect(
        PrivacyApiJson.decodeBiometricState(
          await api.privacyBiometricStateGet(),
        ).configured,
        isFalse,
      );

      // 重新配置后清密 → 清空
      expect(await api.privacyBiometricSet(token, envelope, iv), isTrue);
      await api.privacyClearPassword();
      expect(await api.privacyBiometricVerify(token), isFalse);
    });
  });
}
