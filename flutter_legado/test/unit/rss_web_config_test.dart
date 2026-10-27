// RSS WebView 阅读链纯逻辑单测（批15f）
//
// 覆盖：clHtml 样式/preloadJs 注入、startHtml+startJs、isTrue 口径、
// 主框架白/黑名单判定、shouldOverrideUrlLoading 脚本包装、console 日志解析。
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

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

  group('rssStripPageScripts（批21e P0：HTML5 DOM 解析剥离）', () {
    test('终审三类绕过：注释提前终止 / 伪注释引号失配 / 无引号属性含引号', () {
      const vectors = <String>[
        // ① <!--> / <!---> / --!> 注释提前终止
        '<p>a</p><!--><script>alert(1)</script><p>b</p>',
        '<p>a</p><!---><script>alert(2)</script><p>b</p>',
        '<p>a</p>--!><script>alert(3)</script><p>b</p>',
        // ② 伪注释内引号失配
        '<!x "><script>alert(4)</script><p>b</p>',
        '<?x "><script>alert(5)</script><p>b</p>',
        '<!DOCTYPE html "><script>alert(6)</script><p>b</p>',
        // ③ 无引号属性内含引号（浏览器在 > 结束标签）
        '<div x=a"><script>alert(7)</script></div><p>b</p>',
      ];
      for (final html in vectors) {
        final out = rssStripPageScripts(html);
        final audit = _auditSanitized(out);
        expect(audit.scripts, 0, reason: '渲染 DOM 仍有 script：$out');
        expect(out, isNot(contains('alert(')), reason: '脚本正文必须移除：$out');
      }
    });

    test('移除 script 标签（大小写/属性/自闭合/外链/未闭合）', () {
      const vectors = <String>[
        '<p>a</p><SCRIPT type="text/javascript">x()</SCRIPT>'
            '<script src="a.js"></script><script async/>'
            '<p>b</p>',
        '<p>前</p><script src="https://evil.test/x.js"><p>后</p>',
        '<sc<script>ript>alert(1)</script><p>a</p>',
        '<scr<script>ipt>alert(2)</script><p>b</p>',
        '<sc<script src=x>ript>alert(3)</script><p>c</p>',
        '<script/src="https://evil.test/x.js"><p>d</p>',
      ];
      for (final html in vectors) {
        final out = rssStripPageScripts(html);
        expect(_auditSanitized(out).scripts, 0,
            reason: '拆分重组/未闭合等向量仍存在 script：$out');
      }
      final external = rssStripPageScripts(vectors[1]);
      expect(external, contains('<p>前</p>'));
      expect(external, isNot(contains('evil.test')));
      expect(external, isNot(contains('<p>后</p>')),
          reason: 'HTML5 中未闭合的 <script src> 会把后续内容吞为脚本正文，'
              '浏览器同样不渲染（DOM 语义一致）');
    });

    test('实体/控制字符编码的 javascript: 与 vbscript:/危险 data: 一律移除属性', () {
      const html = '<a href="&#106;avascript:alert(1)">a</a>'
          '<a href="jav&#x61;script&#58;alert(2)">b</a>'
          '<a href="java&#9;script:alert(3)">c</a>'
          '<a href="Java&#x53;cript:alert(4)">d</a>'
          '<a href="vbscript:msgbox(1)">e</a>'
          '<a href="data:text/html;base64,PHNjcmlwdD4=">f</a>'
          '<a href="data:image/svg+xml;base64,AA">g</a>'
          '<a href="data:application/xhtml+xml,AA">h</a>'
          '<form action="java\tscript:alert(5)"></form>';
      final out = rssStripPageScripts(html);
      final audit = _auditSanitized(out);
      expect(audit.dangerousUrls, isEmpty, reason: out);
      expect(out, isNot(contains('href=')), reason: '危险 URL 属性必须整体移除');
      expect(out, isNot(contains('action=')), reason: out);
      // 正文文本仍保留
      for (final text in ['>a<', '>b<', '>c<', '>d<', '>e<', '>f<', '>g<', '>h<']) {
        expect(out, contains(text), reason: '$text 正文不得被删：$out');
      }
    });

    test('iframe srcdoc 属性移除（标签/正文保留）', () {
      const html = '<iframe srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;">'
          '</iframe><p>正文</p>';
      final out = rssStripPageScripts(html);
      expect(out.toLowerCase(), isNot(contains('srcdoc')));
      expect(out, isNot(contains('alert(1)')));
      expect(out, contains('<iframe'));
      expect(out, contains('<p>正文</p>'));
    });

    test('on* 内联事件（大小写/引号/无引号）与裸 javascript URL', () {
      const html = '<IMG SRC="x" ONERROR=alert(1)>'
          '<img src="y" onload=\'y()\' data-on="keep">'
          '<div onclick=go()>d</div>'
          '<a href=javascript:alert(2)>z</a>';
      final out = rssStripPageScripts(html);
      final audit = _auditSanitized(out);
      expect(audit.onAttributes, isEmpty, reason: out);
      expect(audit.dangerousUrls, isEmpty, reason: out);
      expect(out, contains('data-on="keep"'),
          reason: '非 on* 事件名（data-on）不得误删');
      expect(out.toLowerCase(), contains('<img src="x">'));
      expect(out, contains('<div>d</div>'));
      expect(out, isNot(contains('javascript:')));
    });

    test('属性值中的 <script> 文本不破坏正文/属性', () {
      const html = '<img alt="<script>x</script>" src="ok.png">'
          '<p>正文</p>';
      final out = rssStripPageScripts(html);
      expect(out, contains('alt="<script>x</script>"'),
          reason: '引号属性值必须原样保留：$out');
      expect(out, contains('src="ok.png"'));
      expect(out, contains('<p>正文</p>'));
      expect(_auditSanitized(out).scripts, 0);
    });

    test('rawtext/RCDATA 内字面 <script> 保留（style/title/textarea/noscript）', () {
      const html = '<style>a{content:"<script>x</script>"}</style>'
          '<title>t <script>y</script></title>'
          '<textarea><script>z</script></textarea>'
          '<noscript><p>no js</p><script>n</script></noscript>'
          '<p>正文</p>';
      final out = rssStripPageScripts(html);
      expect(_auditSanitized(out).scripts, 0,
          reason: 'rawtext/RCDATA 中的 <script> 不是元素：$out');
      expect(out, contains('<script>x</script>'),
          reason: 'style 内容按 rawtext 保留：$out');
      expect(out, contains('&lt;script&gt;y&lt;/script&gt;'),
          reason: 'title 内容按 RCDATA 转义保留：$out');
      expect(out, contains('&lt;script&gt;z&lt;/script&gt;'),
          reason: 'textarea 内容按 RCDATA 转义保留：$out');
      expect(out, contains('<p>no js</p>'), reason: 'noscript 内容保留：$out');
      expect(out, contains('<p>正文</p>'));
    });

    test('pre 内实体编码代码块保留；未转义 <script> 是真实元素仍删除（DOM 语义）', () {
      const escaped = '<pre><code>if (a &lt; b) { return "&lt;script&gt;"; }'
          '</code></pre><p>正文</p>';
      final escapedOut = rssStripPageScripts(escaped);
      expect(escapedOut, contains('&lt;script&gt;'), reason: escapedOut);
      expect(_auditSanitized(escapedOut).scripts, 0);

      const raw = '<pre><code><script>x</script></code></pre>';
      final rawOut = rssStripPageScripts(raw);
      expect(_auditSanitized(rawOut).scripts, 0,
          reason: 'pre 内未转义 <script> 在 HTML5 中是真实元素，浏览器同样执行');
    });

    test('data: 危险文档：全局拒绝 html/svg/xhtml；iframe/object/embed 拒绝全部 data:', () {
      const html = '<a href="data:image/svg+xml;base64,AA">a</a>'
          '<a href="data:application/xhtml+xml,AA">b</a>'
          '<a href="data:text/html;base64,AA">c</a>'
          '<a href="data:text/plain,ok">d</a>'
          '<iframe src="data:text/plain,hi"></iframe>'
          '<object data="data:image/png;base64,AA"></object>'
          '<embed src="data:application/pdf;base64,AA">';
      final out = rssStripPageScripts(html);
      final audit = _auditSanitized(out);
      expect(audit.dangerousUrls, isEmpty, reason: out);
      expect(out, isNot(contains('data:image/svg+xml')), reason: out);
      expect(out, isNot(contains('data:application/xhtml+xml')), reason: out);
      expect(out, isNot(contains('data:text/html')), reason: out);
      expect(out, isNot(contains('data:text/plain,hi')), reason: out);
      expect(out, isNot(contains('data:image/png')), reason: out);
      expect(out, isNot(contains('data:application/pdf')), reason: out);
      expect(out, contains('data:text/plain,ok'),
          reason: '普通链接的 data:text/plain 不是危险文档，保留');
    });

    test('注释节点删除；正常样式/链接/正文不受影响', () {
      const html = '<!-- 广告 --><style>a{color:red}</style>'
          '<a href="https://ok.test/a">ok</a>'
          '<p>javascript: 文本保留</p>'
          '<!--[if IE]><p>old</p><![endif]-->';
      final out = rssStripPageScripts(html);
      expect(_auditSanitized(out).comments, 0, reason: out);
      expect(out, contains('<style>a{color:red}</style>'));
      expect(out, contains('href="https://ok.test/a"'));
      expect(out, contains('javascript: 文本保留'));
    });

    test('空输入原样返回（不补全文档骨架）', () {
      expect(rssStripPageScripts(''), '');
    });

    test('性能：约 1MB / 10000 标签 < 200ms', () {
      final buffer = StringBuffer('<html><body>');
      for (var i = 0; i < 10000; i++) {
        buffer.write('<div class="c$i" data-i="$i">正文内容$i '
            '${'x' * 60}</div>');
      }
      buffer.write('</body></html>');
      final html = buffer.toString();
      expect(html.length, greaterThan(1000000), reason: '用例负载需达到 1MB');
      // 预热（JIT 与解析器缓存）
      rssStripPageScripts(html);
      final sw = Stopwatch()..start();
      rssStripPageScripts(html);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: 'DOM 剥离耗时 ${sw.elapsedMilliseconds}ms（1MB / 1 万标签）');
    });
  });
}

/// 用同一 HTML5 解析器审计剥离结果（oracle）
({
  int scripts,
  int comments,
  List<String> onAttributes,
  List<String> dangerousUrls,
}) _auditSanitized(String html) {
  final document = html_parser.parse(html);
  final onAttributes = <String>[];
  final dangerousUrls = <String>[];
  final embedded = <String>{'iframe', 'object', 'embed'};
  for (final element in document.querySelectorAll('*')) {
    for (final entry in element.attributes.entries) {
      final name = entry.key.toString().toLowerCase();
      final value = entry.value;
      if (name.length > 2 && name.startsWith('on')) {
        onAttributes.add('${element.localName}[$name=$value]');
      }
      if (name == 'srcdoc') {
        dangerousUrls.add('${element.localName}[srcdoc=$value]');
      }
      if (!<String>{
        'href',
        'src',
        'action',
        'formaction',
        'xlink:href',
        'data',
      }.contains(name)) {
        continue;
      }
      final normalized = value
          .replaceAll(RegExp(r'[\u0000-\u0020\u007f]+'), '')
          .toLowerCase();
      final bad = normalized.startsWith('javascript:') ||
          normalized.startsWith('vbscript:') ||
          normalized.startsWith('data:text/html') ||
          normalized.startsWith('data:image/svg+xml') ||
          normalized.startsWith('data:application/xhtml+xml') ||
          (embedded.contains(element.localName) &&
              normalized.startsWith('data:'));
      if (bad) {
        dangerousUrls.add('${element.localName}[$name=$value]');
      }
    }
  }
  var comments = 0;
  void count(dom.Node node) {
    for (final child in node.nodes) {
      if (child is dom.Comment) {
        comments++;
      } else if (child.nodes.isNotEmpty) {
        count(child);
      }
    }
  }

  count(document);
  return (
    scripts: document.querySelectorAll('script').length,
    comments: comments,
    onAttributes: onAttributes,
    dangerousUrls: dangerousUrls,
  );
}
