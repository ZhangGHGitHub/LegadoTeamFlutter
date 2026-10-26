// RSS 源 header 静态解析单测（批15f）
//
// 覆盖：JSON 对象、逐行 Key: Value、非法 JSON 回退、User-Agent 大小写。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/rss_header.dart';

void main() {
  group('parseRssHeaderMap', () {
    test('空/null → 空 map', () {
      expect(parseRssHeaderMap(null), isEmpty);
      expect(parseRssHeaderMap('   '), isEmpty);
    });

    test('JSON 对象（值转字符串）', () {
      expect(
        parseRssHeaderMap('{"Referer":"https://a.com","User-Agent":123}'),
        {'Referer': 'https://a.com', 'User-Agent': '123'},
      );
    });

    test('逐行 Key: Value（首个冒号拆分，兼容 URL 值）', () {
      expect(
        parseRssHeaderMap('Referer: https://a.com/x\nCookie: a=1; b=2'),
        {'Referer': 'https://a.com/x', 'Cookie': 'a=1; b=2'},
      );
      expect(parseRssHeaderMap('无冒号行\nReferer: https://a.com'), {
        'Referer': 'https://a.com',
      });
    });

    test('以 { 开头但 JSON 非法 → 回退逐行解析', () {
      expect(
        parseRssHeaderMap('{bad}\nReferer: https://a.com'),
        {'Referer': 'https://a.com'},
      );
    });

    test('JSON 数组形态 → 回退逐行解析（非对象）', () {
      expect(parseRssHeaderMap('["a"]'), isEmpty);
    });

    test('动态 header（@js: / <js>）不解析', () {
      expect(parseRssHeaderMap('@js:java.getHeader()'), isEmpty);
      expect(parseRssHeaderMap('<js>return {"a":"b"}</js>'), isEmpty);
    });
  });

  group('rssHeaderUserAgent', () {
    test('大小写不敏感命中', () {
      expect(
        rssHeaderUserAgent({'user-agent': 'UA1'}),
        'UA1',
      );
      expect(
        rssHeaderUserAgent({'User-Agent': 'UA2'}),
        'UA2',
      );
    });

    test('空值跳过，未配置返回 null', () {
      expect(rssHeaderUserAgent({'User-Agent': '  '}), isNull);
      expect(rssHeaderUserAgent({'Referer': 'x'}), isNull);
      expect(rssHeaderUserAgent(const {}), isNull);
    });
  });
}
