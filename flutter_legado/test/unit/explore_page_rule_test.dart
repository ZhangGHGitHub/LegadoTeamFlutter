// 发现分类页码规则探测单元测试
//
// 对标参考版 AnalyzeUrl.supportsPageSelection：
// - 规则含 {{page}} / 表达式或脚本内引用 page 变量 → 支持页码；
// - 角度括号页码列表 <1,2> / <,2> 含逗号 → 支持页码；
// - 普通 URL / 仅 pageSize 等长名 → 不支持（页码按钮隐藏）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/explore_page_rule.dart';

void main() {
  group('exploreRuleSupportsPageSelection', () {
    test('空规则/null 不支持', () {
      expect(exploreRuleSupportsPageSelection(null), isFalse);
      expect(exploreRuleSupportsPageSelection(''), isFalse);
      expect(exploreRuleSupportsPageSelection('   '), isFalse);
    });

    test('普通 URL 不含页码 → 不支持', () {
      expect(
        exploreRuleSupportsPageSelection('https://site.com/rank/all'),
        isFalse,
      );
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list?type=hot'),
        isFalse,
      );
    });

    test('{{page}} 表达式 → 支持', () {
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/{{page}}.html'),
        isTrue,
      );
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list?p={{page}}'),
        isTrue,
      );
      // 表达式内引用 page 参与运算同样支持
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/{{page+1}}'),
        isTrue,
      );
    });

    test('角度括号页码列表含逗号 → 支持', () {
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/<1,2>'),
        isTrue,
      );
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/<,2.html>'),
        isTrue,
      );
      // 无逗号的角括号不是页码列表（参考版同为不支持）
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/<1>'),
        isFalse,
      );
    });

    test('<js> 脚本中引用 page 变量 → 支持；仅声明不参与其它用法时不误判相邻长名', () {
      expect(
        exploreRuleSupportsPageSelection(
          '<js>result = "https://site.com/list/" + page</js>',
        ),
        isTrue,
      );
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/list/<js>"?p=" + page</js>',
        ),
        isTrue,
      );
    });

    test('pageSize / obj.page 等长名或属性访问 → 不误判', () {
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/list?size={{pageSize}}',
        ),
        isFalse,
      );
      expect(
        exploreRuleSupportsPageSelection('<js>result = list.pageSize</js>'),
        isFalse,
      );
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/list?n={{obj.page}}',
        ),
        isFalse,
      );
    });

    test('@js: 尾段脚本引用 page → 支持', () {
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/list @js:"?page=" + page',
        ),
        isTrue,
      );
    });

    test('脚本内 XML/HTML 角括号不误判为页码列表', () {
      expect(
        exploreRuleSupportsPageSelection(
          '<js>result = "<a,b>"</js>https://site.com/list',
        ),
        isFalse,
      );
    });
  });
}
