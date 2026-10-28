/// Mock 高亮规则 scope 过滤测试（批34b P3-4）
///
/// 对齐 Rust `find_enabled_by_book` 的空串守卫：
/// `(?1 != '' AND instr(scope, ?1) > 0)` —— 空 bookName/origin 不得命中
/// 任何非空 scope（此前 `scope.contains('')` 恒真导致误命中）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MockBookApi 高亮规则 scope 过滤', () {
    test('空 bookName/origin 不命中非空 scope；命中 scope 才生效', () async {
      final api = MockBookApi();
      final id = await api.highlightRuleSave(
        ruleJson: jsonEncode({
          'name': '范围规则',
          'pattern': '关键词',
          'isRegex': false,
          'scope': '目标书',
          'isEnabled': true,
          'style': '{}',
          'sortOrder': 10,
          'applyToBody': true,
        }),
      );

      // 空书名/空源：非空 scope 规则不得命中（对齐 Rust 空串守卫）
      expect(jsonDecode(await api.highlightRuleMatch(text: '关键词')), isEmpty);
      expect(
        jsonDecode(
          await api.highlightRuleMatch(text: '关键词', bookName: '', origin: ''),
        ),
        isEmpty,
      );
      expect(
        jsonDecode(await api.highlightRuleFindEnabled(bookName: '', origin: '')),
        isEmpty,
      );

      // 命中 scope（书名或 origin 子串）→ 正常匹配
      final byName = jsonDecode(
        await api.highlightRuleMatch(text: '关键词', bookName: '目标书'),
      ) as List<dynamic>;
      expect(byName, hasLength(1));
      expect((byName.single as Map)['ruleId'], id);

      final byOrigin = jsonDecode(
        await api.highlightRuleMatch(text: '关键词', origin: '目标书'),
      ) as List<dynamic>;
      expect(byOrigin, hasLength(1));

      final enabled = jsonDecode(
        await api.highlightRuleFindEnabled(bookName: '目标书', origin: ''),
      ) as List<dynamic>;
      expect(enabled, hasLength(1));

      await api.highlightRuleDelete(id: id);
      expect(
        jsonDecode(
          await api.highlightRuleMatch(text: '关键词', bookName: '目标书'),
        ),
        isEmpty,
      );
    });

    test('全局规则（空 scope）对任意书生效，空书名亦然', () async {
      final api = MockBookApi();
      final id = await api.highlightRuleSave(
        ruleJson: jsonEncode({
          'name': '全局规则',
          'pattern': '全局词',
          'isRegex': false,
          'scope': '',
          'isEnabled': true,
          'style': '{}',
          'sortOrder': 1,
          'applyToBody': true,
        }),
      );

      expect(
        jsonDecode(await api.highlightRuleMatch(text: '全局词')),
        hasLength(1),
      );
      expect(
        jsonDecode(
          await api.highlightRuleMatch(text: '全局词', bookName: '任意书'),
        ),
        hasLength(1),
      );
      await api.highlightRuleDelete(id: id);
    });
  });
}
