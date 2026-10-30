// TXT 目录规则编解码 / 选中判定 / Mock 单列写测试（批43）
//
// 对齐原版 `Book.tocUrl = rule + TextFile.spaceChars + replacement`：
// Flutter 侧只负责序列化与选中判定，真实解析/回退由 Rust 单测覆盖。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/utils/txt_toc_rule.dart';
import 'package:flutter_legado/src/widgets/reader/reader_toc_rule_dialog.dart'
    show isLocalTxtBook;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rule = TxtTocRule(
    id: 7,
    name: '方括号篇',
    rule: r'^【第.+篇】.*$',
    replacement: '',
    enable: true,
  );

  group('原版 tocUrl 编解码', () {
    test('规则 + spaceChars + replacement 存储形态', () {
      expect(
        txtTocRuleStorageValue(rule),
        '^【第.+篇】.*\$🫅🈳🏻',
        reason: '对齐原版 TextFile.spaceChars 分隔符',
      );
      expect(
        txtTocRuleStorageValue(
          rule.copyWith(replacement: 'result.replace("【","")'),
        ),
        '^【第.+篇】.*\$🫅🈳🏻result.replace("【","")',
      );
    });

    test('选中判定逐字比较（含 replacement）', () {
      expect(isTxtTocRuleSelected(txtTocRuleStorageValue(rule), rule), isTrue);
      expect(isTxtTocRuleSelected('', rule), isFalse);
      expect(
        isTxtTocRuleSelected(txtTocRuleStorageValue(rule), rule.copyWith(replacement: 'x')),
        isFalse,
      );
    });

    test('默认规则判定与自定义规则提取', () {
      expect(isDefaultTxtTocRule(''), isTrue);
      expect(isDefaultTxtTocRule('   '), isTrue);
      expect(isDefaultTxtTocRule(r'^第.+章$'), isFalse);

      expect(txtTocRuleRuleOf(''), isNull);
      // 无分隔符：整串视为正则（与 Rust split_toc_rule 同口径）
      expect(txtTocRuleRuleOf(r'^第.+章$'), r'^第.+章$');
      expect(txtTocRuleRuleOf(txtTocRuleStorageValue(rule)), rule.rule);
      expect(txtTocRuleRuleOf('🫅🈳🏻only-replacement'), isNull);
    });

    test('ruleJson 序列化（Rust setBookTocRule 入参）', () {
      final decoded = jsonDecode(encodeTxtTocRuleJson(rule))
          as Map<String, dynamic>;
      expect(decoded['name'], rule.name);
      expect(decoded['rule'], rule.rule);
      expect(decoded['replacement'], '');
    });
  });

  group('本地 TXT 判定', () {
    const base = Book(
      bookUrl: 'books/a.txt',
      origin: BookType.localTag,
      originName: 'a.txt',
    );
    test('本地 .txt/.text 命中', () {
      expect(isLocalTxtBook(base), isTrue);
      expect(
        isLocalTxtBook(base.copyWith(bookUrl: 'books/a.text', originName: 'a.text')),
        isTrue,
      );
    });

    test('在线书 / 本地 EPUB 不适用', () {
      expect(
        isLocalTxtBook(base.copyWith(origin: 'https://source.example')),
        isFalse,
      );
      expect(
        isLocalTxtBook(base.copyWith(
          bookUrl: 'books/a.epub',
          originName: 'a.epub',
        )),
        isFalse,
      );
    });
  });

  group('Mock 单列写语义（形状对齐 Rust）', () {
    test('设置规则写 tocUrl；null 清空恢复默认', () async {
      final api = MockBookApi();
      await api.addBook(const Book(
        bookUrl: 'books/mock.txt',
        name: 'Mock TXT',
        origin: BookType.localTag,
        originName: 'mock.txt',
      ));

      final updated = await api.setBookTocRule(
        'books/mock.txt',
        encodeTxtTocRuleJson(rule),
      );
      expect(updated.tocUrl, txtTocRuleStorageValue(rule));

      final cleared = await api.setBookTocRule('books/mock.txt', null);
      expect(cleared.tocUrl, '');

      final raw = await api.setBookTocRule('books/mock.txt', r'^第.+章$');
      expect(raw.tocUrl, r'^第.+章$');
    });

    test('书籍不存在抛错（不静默成功）', () async {
      final api = MockBookApi();
      await expectLater(
        api.setBookTocRule('books/missing.txt', r'^第.+章$'),
        throwsA(isA<StateError>()),
      );
    });

    test('非法 JSON / 空规则抛错', () async {
      final api = MockBookApi();
      await api.addBook(const Book(
        bookUrl: 'books/mock2.txt',
        origin: BookType.localTag,
        originName: 'mock2.txt',
      ));
      await expectLater(
        api.setBookTocRule('books/mock2.txt', '{not json'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        api.setBookTocRule('books/mock2.txt', '{"rule":"   "}'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
