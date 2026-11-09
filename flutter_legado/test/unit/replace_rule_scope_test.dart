/// 替换规则 scope / 生效谓词单测（批7c-1 审查 P1-2/P3）
///
/// 复刻 Rust `process_content_with_rules_inner` 的 6 个 scope 口径：
/// global/空串全局、多分隔符、空书名、子串不命中、空白 scope、大写 Global。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/widgets/reader/reader_action_helpers.dart';

ReplaceRule rule({
  String pattern = '广告',
  String? scope,
  bool scopeContent = true,
  bool isEnabled = true,
}) {
  return ReplaceRule(
    name: 'r',
    pattern: pattern,
    scope: scope,
    scopeContent: scopeContent,
    isEnabled: isEnabled,
  );
}

void main() {
  group('replaceRuleScopeMatchesBook（Rust 口径）', () {
    test('global / 空串为全局；大写 Global 不是全局', () {
      expect(replaceRuleScopeMatchesBook(null, '任意书'), isTrue);
      expect(replaceRuleScopeMatchesBook('', '任意书'), isTrue);
      expect(replaceRuleScopeMatchesBook('global', '任意书'), isTrue);
      expect(replaceRuleScopeMatchesBook('Global', '任意书'), isFalse);
    });

    test('多分隔符拆分后精确匹配', () {
      const scope = '书A，书B;书C';
      expect(replaceRuleScopeMatchesBook(scope, '书B'), isTrue);
      expect(replaceRuleScopeMatchesBook(scope, '书C'), isTrue);
      expect(replaceRuleScopeMatchesBook(scope, '书D'), isFalse);
    });

    test('空书名时 scoped 规则不生效', () {
      expect(replaceRuleScopeMatchesBook('某书籍', ''), isFalse);
    });

    test('子串不误命中，精确书名命中', () {
      expect(replaceRuleScopeMatchesBook('斗破苍穹', '斗破'), isFalse);
      expect(replaceRuleScopeMatchesBook('斗破苍穹', '斗破苍穹'), isTrue);
    });

    test('空白 scope 不是全局（仅空串全局）', () {
      expect(replaceRuleScopeMatchesBook('   ', '任意书'), isFalse);
      expect(replaceRuleScopeMatchesBook('   ', ''), isFalse);
    });

    test('scope 不整体 trim，书名不 trim', () {
      // scope 首尾空白不裁掉，拆分项 trim 后仍可匹配书名
      expect(replaceRuleScopeMatchesBook(' 书A , 书B ', '书B'), isTrue);
      // 书名带空白不 trim → 不匹配
      expect(replaceRuleScopeMatchesBook('书A', '书A '), isFalse);
    });
  });

  group('isReplaceRuleEffectiveForBook', () {
    const book = Book(name: '书A', readConfig: ReadConfig());

    test('总开关关闭 → 任何规则不生效', () {
      expect(
        isReplaceRuleEffectiveForBook(
          rule: rule(scope: '书A'),
          book: book,
          globalReplaceDefault: false,
        ),
        isFalse,
      );
    });

    test('图片书即使全局默认开也不生效', () {
      final imageBook = book.copyWith(bookType: BookType.image);
      expect(
        isReplaceRuleEffectiveForBook(
          rule: rule(scope: '书A'),
          book: imageBook,
          globalReplaceDefault: true,
        ),
        isFalse,
      );
    });

    test('空 pattern / 停用 / scopeContent=false 不生效', () {
      expect(
        isReplaceRuleEffectiveForBook(
          rule: rule(pattern: '', scope: '书A'),
          book: book,
          globalReplaceDefault: true,
        ),
        isFalse,
      );
      expect(
        isReplaceRuleEffectiveForBook(
          rule: rule(scope: '书A', isEnabled: false),
          book: book,
          globalReplaceDefault: true,
        ),
        isFalse,
      );
      expect(
        isReplaceRuleEffectiveForBook(
          rule: rule(scope: '书A', scopeContent: false),
          book: book,
          globalReplaceDefault: true,
        ),
        isFalse,
      );
    });

    test('启用 + scopeContent + scope 匹配 → 生效', () {
      expect(
        isReplaceRuleEffectiveForBook(
          rule: rule(scope: '书A'),
          book: book,
          globalReplaceDefault: true,
        ),
        isTrue,
      );
    });
  });
}
