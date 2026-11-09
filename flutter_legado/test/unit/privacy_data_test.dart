/// 隐私与私密标记数据层测试（契约 §2.53，批9a）
///
/// 覆盖：Book/BookGroup isPrivate 缺省与 JSON 往返；
/// PrivacyApiJson 数组形态/元素类型校验；
/// MockBookApi 密码生命周期、私密书/组 CRUD 与实例隔离。
library;

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
}
