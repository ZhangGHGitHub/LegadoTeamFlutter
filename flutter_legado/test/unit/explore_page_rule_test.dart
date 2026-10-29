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

    test('字符串与注释里的 page 不算引用（对齐参考版 AST 判定）', () {
      // 纯字符串
      expect(
        exploreRuleSupportsPageSelection("@js: 'https://site.com/page'"),
        isFalse,
      );
      // 注释
      expect(
        exploreRuleSupportsPageSelection(
          "@js: /* page */ 'https://site.com/list'",
        ),
        isFalse,
      );
      // 行注释
      expect(
        exploreRuleSupportsPageSelection(
          '@js: // page\n"https://site.com/list"',
        ),
        isFalse,
      );
      // 表达式里的字符串
      expect(
        exploreRuleSupportsPageSelection("https://site.com/{{'page'}}"),
        isFalse,
      );
    });

    test(r'模板字符串 ${page} 表达式仍算引用', () {
      expect(
        exploreRuleSupportsPageSelection(
          r'@js: `https://site.com/list?page=${page}`',
        ),
        isTrue,
      );
    });

    test('局部变量/函数形参遮蔽全局 page → 不支持', () {
      expect(
        exploreRuleSupportsPageSelection(
          "@js: var page = 1; 'https://site.com/list?page=' + page",
        ),
        isFalse,
      );
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/{{(function(page) { return page; })(1)}}',
        ),
        isFalse,
      );
    });

    test('对象属性键位 page 不误判（{page:1}.page）', () {
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/{{({page: 1}).page}}',
        ),
        isFalse,
      );
    });

    test('Rust 引擎支持的 {page} / {page,a,b} 花括号页码 → 支持', () {
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/{page}.html'),
        isTrue,
      );
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/list/{page,1,2,3}.html',
        ),
        isTrue,
      );
      // 花括号里没有 page 键的普通占位不算页码
      expect(
        exploreRuleSupportsPageSelection('https://site.com/list/{id}.html'),
        isFalse,
      );
    });

    test('@Header JSON 字符串中的 page 不误判', () {
      expect(
        exploreRuleSupportsPageSelection(
          'https://site.com/list,{"headers":{"Referer":"https://site.com/page"}}',
        ),
        isFalse,
      );
    });
  });
}
