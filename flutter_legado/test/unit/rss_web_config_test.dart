// RSS WebView 阅读链纯逻辑单测（批15f）
//
// 覆盖：clHtml 样式/preloadJs 注入、startHtml+startJs、isTrue 口径、
// 主框架白/黑名单判定、shouldOverrideUrlLoading 脚本包装、console 日志解析。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/rss_web_config.dart';

void main() {
  group('rssClHtml（对齐 ReadRssViewModel.clHtml）', () {
    test('有 </style> 且 style 非空白：紧随其后插入', () {
      const content =
          '<html><head><style>a{}</style></head><body>x</body></html>';
      final html = rssClHtml(content, style: 'p{color:red}');
      expect(
        html,
        '<html><head><style>a{}</style><style>p{color:red}</style>'
        '</head><body>x</body></html>',
      );
    });

    test('有 </style> 且 style 空白：原样返回', () {
      const content =
          '<html><head><style>a{}</style></head><body>x</body></html>';
      expect(rssClHtml(content), content);
      expect(rssClHtml(content, style: '   '), content);
    });

    test('无 </style> 且 style 非空白：插入 </head> 前', () {
      const content = '<html><head></head><body>x</body></html>';
      expect(
        rssClHtml(content, style: 'p{}'),
        '<html><head><style>p{}</style></head><body>x</body></html>',
      );
    });

    test('无 </style> 且 style 空白：使用默认移动端样式', () {
      const content = '<html><head></head><body>x</body></html>';
      final html = rssClHtml(content);
      expect(html, contains('<style>$kRssDefaultContentStyle</style>'));
      expect(html.indexOf('<style>'), lessThan(html.indexOf('</head>')));
    });

    test('无 </head>：样式插到最前', () {
      expect(rssClHtml('正文', style: 'p{}'), '<style>p{}</style>正文');
      expect(
        rssClHtml('正文'),
        startsWith('<style>$kRssDefaultContentStyle</style>'),
      );
    });

    test('preloadJs：有 <head> 时紧跟其后内联脚本', () {
      const content =
          '<html><head><title>t</title></head><body>x</body></html>';
      final html = rssClHtml(content, preloadJs: 'window.x=1');
      expect(
        html,
        '<html><head><script>window.x=1</script><title>t</title>'
        '<style>$kRssDefaultContentStyle</style></head><body>x</body></html>',
        reason: '脚本紧跟 <head>；无 </style> 时默认样式插在 </head> 前',
      );
    });

    test('preloadJs：无 <head> 时补 head', () {
      final html = rssClHtml('<p>x</p>', preloadJs: 'var a=1');
      expect(
        html,
        startsWith(
          '<head><script>var a=1</script>'
          '<style>$kRssDefaultContentStyle</style></head>',
        ),
      );
      expect(html, endsWith('<p>x</p>'));
    });

    test('preloadJs 空白不注入', () {
      expect(
        rssClHtml('<p>x</p>', preloadJs: '  '),
        isNot(contains('<script>')),
      );
    });
  });

  group('rssInjectStartJs（对齐 loadStartHtml）', () {
    test('有 </body>：插在其前', () {
      const html = '<html><body><p>x</p></body></html>';
      expect(
        rssInjectStartJs(html, 'init()'),
        '<html><body><p>x</p><script>init()</script></body></html>',
      );
    });

    test('无 </body>：包装 body 并追加脚本', () {
      expect(
        rssInjectStartJs('<p>x</p>', 'init()'),
        '<body><p>x</p><script>init()</script></body>',
      );
    });

    test('startJs 空白：原样返回', () {
      const html = '<p>x</p>';
      expect(rssInjectStartJs(html, null), html);
      expect(rssInjectStartJs(html, '  '), html);
    });

    test('startJs 不 trim（对齐原版插入原文）', () {
      expect(
        rssInjectStartJs('x', ' a() '),
        contains('<script> a() </script>'),
      );
    });
  });

  group('rssIsTrue（对齐 StringExtensions.isTrue）', () {
    test('空/null 字面量 → false', () {
      expect(rssIsTrue(null), isFalse);
      expect(rssIsTrue(''), isFalse);
      expect(rssIsTrue('  '), isFalse);
      expect(rssIsTrue('null'), isFalse);
      expect(
        rssIsTrue(' NULL '),
        isTrue,
        reason: '原版只对字面量 "null" 短路（不 trim），其余按非 false 处理',
      );
    });

    test('false/no/not/0/0.0 → false，其余 → true', () {
      for (final value in ['false', 'FALSE', 'no', 'No', 'not', '0', '0.0']) {
        expect(rssIsTrue(value), isFalse, reason: value);
      }
      for (final value in ['true', '1', 'yes', 'blocked', '  true  ']) {
        expect(rssIsTrue(value), isTrue, reason: value);
      }
    });
  });

  group('rssNavigationRuleDecision（主框架白/黑名单）', () {
    test('无配置 → none', () {
      expect(
        rssNavigationRuleDecision(url: 'https://a.com/x'),
        RssNavigationRule.none,
      );
      expect(
        rssNavigationRuleDecision(
          url: 'https://a.com/x',
          whitelist: ' , ',
          blacklist: '',
        ),
        RssNavigationRule.none,
      );
    });

    test('黑名单命中（前缀 / 正则）→ block；未命中 → none 且不看白名单', () {
      expect(
        rssNavigationRuleDecision(
          url: 'https://ads.com/banner',
          blacklist: 'https://ads.com',
          whitelist: 'https://a.com',
        ),
        RssNavigationRule.block,
      );
      expect(
        rssNavigationRuleDecision(
          url: 'https://track.com/x.js',
          blacklist: r'^https://track\.com',
        ),
        RssNavigationRule.block,
      );
      expect(
        rssNavigationRuleDecision(
          url: 'https://a.com/page',
          blacklist: 'https://ads.com',
          whitelist: 'https://a.com',
        ),
        RssNavigationRule.none,
        reason: '黑名单存在时命中与否即终判，不再走白名单',
      );
    });

    test('仅白名单：命中 allow，未命中 block', () {
      expect(
        rssNavigationRuleDecision(
          url: 'https://a.com/page',
          whitelist: 'https://a.com, https://b.com',
        ),
        RssNavigationRule.allow,
      );
      expect(
        rssNavigationRuleDecision(
          url: 'https://c.com/page',
          whitelist: 'https://a.com',
        ),
        RssNavigationRule.block,
      );
    });

    test('非法正则忽略（不抛错）', () {
      expect(
        rssNavigationRuleDecision(
          url: 'https://a.com/page',
          blacklist: '[invalid(',
        ),
        RssNavigationRule.none,
      );
      expect(
        rssNavigationRuleDecision(
          url: 'https://a.com/page',
          whitelist: '[invalid(',
        ),
        RssNavigationRule.block,
      );
    });
  });

  group('rssShouldOverrideScript', () {
    test('绑定 url 与 java，并包含原脚本', () {
      final script = rssShouldOverrideScript(
        "return url.indexOf('ads') >= 0",
        'https://a.com/?x=1',
      );
      expect(script, contains('var url = "https://a.com/?x=1";'));
      expect(script, contains('var java = '));
      expect(script, contains("return url.indexOf('ads') >= 0"));
      expect(script, contains('eval('));
      expect(
        script,
        isNot(contains('return String(')),
        reason: 'P0-2：不得把结果转字符串（Android 会二次编码导致恒判 true）',
      );
      expect(
        script,
        contains('return (result === undefined) ? null : result;'),
        reason: '无返回值统一回 null',
      );
    });

    test('脚本中的引号被 JSON 转义（不破坏外层脚本）', () {
      final script = rssShouldOverrideScript(
        'return url === "https://a.com/\\"x\\""',
        'https://a.com/"x"',
      );
      expect(script, contains('https://a.com/\\"x\\"'));
    });
  });

  group('rssShouldOverrideResult（P0-2 返回结果归一）', () {
    test('bool/num 直判', () {
      expect(rssShouldOverrideResult(true), isTrue);
      expect(rssShouldOverrideResult(false), isFalse);
      expect(rssShouldOverrideResult(1), isTrue);
      expect(rssShouldOverrideResult(0), isFalse);
      expect(rssShouldOverrideResult(0.0), isFalse);
      expect(rssShouldOverrideResult(2.5), isTrue);
    });

    test('Android JSON 字面量先去引号再判定', () {
      expect(rssShouldOverrideResult('false'), isFalse);
      expect(
        rssShouldOverrideResult('"false"'),
        isFalse,
        reason: 'Android 插件返回含首尾引号的 JSON 字面量（审查 P0-2 根因）',
      );
      expect(rssShouldOverrideResult('true'), isTrue);
      expect(rssShouldOverrideResult('"true"'), isTrue);
      expect(rssShouldOverrideResult('"0"'), isFalse);
      expect(rssShouldOverrideResult('"1"'), isTrue);
    });

    test('null/undefined/空串 → 不拦截', () {
      expect(rssShouldOverrideResult(null), isFalse);
      expect(rssShouldOverrideResult(''), isFalse);
      expect(rssShouldOverrideResult('   '), isFalse);
      expect(rssShouldOverrideResult('null'), isFalse);
      expect(rssShouldOverrideResult('"null"'), isFalse);
      expect(rssShouldOverrideResult('undefined'), isFalse);
      expect(rssShouldOverrideResult('"undefined"'), isFalse);
    });

    test('数字字符串按 isTrue 口径', () {
      expect(rssShouldOverrideResult('0'), isFalse);
      expect(rssShouldOverrideResult('0.0'), isFalse);
      expect(rssShouldOverrideResult('1'), isTrue);
      expect(rssShouldOverrideResult('42'), isTrue);
    });
  });

  group('console 日志', () {
    test('console 钩子与回读脚本包含关键语句', () {
      expect(kRssConsoleHookScript, contains('__legadoConsoleLogs'));
      expect(kRssConsoleHookScript, contains("'error'"));
      expect(kRssConsoleHookScript, contains('splice'));
      expect(kRssConsoleFlushScript, contains('JSON.stringify'));
    });

    test('rssParseConsoleLogs：JSON 数组 / JSON 字面量 / 纯文本', () {
      expect(rssParseConsoleLogs('["log: a","error: b"]'), [
        'log: a',
        'error: b',
      ]);
      expect(
        rssParseConsoleLogs('"[\\"log: a\\"]"'),
        ['log: a'],
        reason: 'Android 返回 JSON 编码后的字符串字面量',
      );
      expect(rssParseConsoleLogs('raw line'), ['raw line']);
      expect(rssParseConsoleLogs(null), isEmpty);
      expect(rssParseConsoleLogs(''), isEmpty);
    });
  });

  group('rssStripPageScripts（批21c P0-2 桥模式脚本隔离）', () {
    test('移除 script 标签（大小写/属性/自闭合）', () {
      const html = '<p>a</p><SCRIPT type="text/javascript">x()</SCRIPT>'
          '<script src="a.js"></script><script async/>'
          '<p>b</p>';
      final out = rssStripPageScripts(html);
      expect(out, contains('<p>a</p>'));
      expect(out, contains('<p>b</p>'));
      expect(out.toLowerCase(), isNot(contains('<script')));
      expect(out, isNot(contains('x()')));
    });

    test('移除 on* 内联事件（引号/无引号）', () {
      const html = '<img src="x" onerror="alert(1)" onload=\'y()\'>'
          '<div onclick=go()>d</div>';
      final out = rssStripPageScripts(html);
      expect(out, contains('<img src="x"'));
      expect(out, isNot(contains('onerror')));
      expect(out, isNot(contains('onload')));
      expect(out, isNot(contains('onclick')));
      expect(out, contains('<div>d</div>'));
    });

    test('移除 javascript: URL（href/action，带引号与裸值）', () {
      const html = '<a href="javascript:alert(1)">a</a>'
          '<a href=\'javascript:alert(2)\'>b</a>'
          '<a href=javascript:alert(3)>c</a>'
          '<form action="javascript:alert(4)"></form>';
      final out = rssStripPageScripts(html);
      expect(out, isNot(contains('javascript:')));
      expect(out, contains('href="#"'));
      expect(out, contains('action="#"'));
    });

    test('不触碰样式/正常链接/正文文本', () {
      const html = '<style>a{color:red}</style>'
          '<a href="https://ok.test/a">ok</a><p>javascript: 文本保留</p>';
      final out = rssStripPageScripts(html);
      expect(out, contains('<style>a{color:red}</style>'));
      expect(out, contains('href="https://ok.test/a"'));
      expect(out, contains('javascript: 文本保留'));
    });
  });
}
