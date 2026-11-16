// C4：RSS WebView `java.addBook` 真接线 + 书源匹配共用工具
//
// 覆盖：
// 1. `parseBookUrlOption` 复合 URL 解析（`,{json}` 后缀、origin 提取、坏数据 fail-closed）；
// 2. `bookUrlBase`（对齐 NetworkUtils.getBaseUrl：@js: 截断、仅 http/https、host 非空）；
// 3. `matchBookSourceForUrl` 四段匹配顺序（origin 精确 → 基地址 → bookUrlPattern(FFI)
//    → 主域名兜底），用 MockBookApi 的近似正则实现验证；
// 4. 源码守卫：RSS 详情页 `java.addBook` 不再只 debugPrint 跳过，且走共用匹配工具。

import 'dart:io';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/utils/book_source_match.dart';
import 'package:flutter_test/flutter_test.dart';

BookSource _source({
  required String url,
  String name = '源',
  String? pattern,
}) => BookSource(
  bookSourceUrl: url,
  bookSourceName: name,
  bookUrlPattern: pattern,
);

void main() {
  group('parseBookUrlOption（对齐 AnalyzeUrl.paramPattern）', () {
    test('无复合后缀：url 原样、origin 为 null', () {
      final opt = parseBookUrlOption('https://a.com/book/1');
      expect(opt.url, 'https://a.com/book/1');
      expect(opt.origin, isNull);
    });

    test('带 ,{json} 后缀：剥离后缀并提取 origin', () {
      final opt = parseBookUrlOption(
        'https://a.com/book/1,{"origin":"https://src.com"}',
      );
      expect(opt.url, 'https://a.com/book/1');
      expect(opt.origin, 'https://src.com');
    });

    test('后缀 JSON 非法：按纯 URL 处理（fail-closed，不抛错）', () {
      final opt = parseBookUrlOption('https://a.com/book/1,{not-json}');
      expect(opt.url, 'https://a.com/book/1');
      expect(opt.origin, isNull);
    });

    test('origin 非字符串/空串：视为未指定', () {
      expect(
        parseBookUrlOption('https://a.com/b,{"origin":123}').origin,
        isNull,
      );
      expect(
        parseBookUrlOption('https://a.com/b,{"origin":"   "}').origin,
        isNull,
      );
    });

    test('空输入返回空 url', () {
      expect(parseBookUrlOption('   ').url, '');
    });
  });

  group('bookUrlBase（对齐 NetworkUtils.getBaseUrl）', () {
    test('scheme://authority（保留端口）', () {
      expect(
        bookUrlBase('https://a.com:8443/book/1?x=1'),
        'https://a.com:8443',
      );
    });

    test('非 http(s) 返回 null', () {
      expect(bookUrlBase('ftp://a.com/x'), isNull);
      expect(bookUrlBase('file:///x'), isNull);
      expect(bookUrlBase('loc_book'), isNull);
    });

    test('@js: 之后的部分不计入传输地址', () {
      expect(
        bookUrlBase('https://a.com/book/1@js:result + "/x"'),
        'https://a.com',
      );
    });

    test('host 为空返回 null', () {
      expect(bookUrlBase('https:///book'), isNull);
    });
  });

  group('matchBookSourceForUrl 四段匹配顺序', () {
    late MockBookApi api;

    setUp(() => api = MockBookApi());

    test('1) preferredOrigin 精确命中优先', () async {
      final a = _source(url: 'https://a.com', name: 'A', pattern: 'a\\.com');
      final b = _source(url: 'https://b.com', name: 'B', pattern: 'a\\.com');
      final hit = await matchBookSourceForUrl(
        api,
        [a, b],
        'https://a.com/book/1',
        preferredOrigin: 'https://b.com',
      );
      expect(hit?.bookSourceName, 'B');
    });

    test('2) 基地址精确命中（去尾斜杠归一）', () async {
      final a = _source(url: 'https://a.com/', name: 'A');
      final hit = await matchBookSourceForUrl(
        api,
        [a],
        'https://a.com/book/1',
      );
      expect(hit?.bookSourceName, 'A');
    });

    test('3) bookUrlPattern 全匹配（搜索页不命中详情正则）', () async {
      final a = _source(
        url: 'https://src.com',
        name: 'A',
        pattern: r'https://m\.qibuge\.com/book/\d+',
      );
      expect(
        await matchBookSourceForUrl(
          api,
          [a],
          'https://m.qibuge.com/book/123',
        ),
        isNotNull,
      );
      // 同域搜索页：全匹配不命中，且主域名兜底也会命中（host 相同）
      // → 用不同 host 验证正则段本身未命中
      expect(
        await matchBookSourceForUrl(
          api,
          [a],
          'https://other.com/book/123',
        ),
        isNull,
      );
    });

    test('4) 主域名兜底（pattern 不命中但 host 相同）', () async {
      final a = _source(
        url: 'https://a.com',
        name: 'A',
        pattern: r'https://a\.com/book/\d+',
      );
      // 非详情页 URL：正则不命中 → host 兜底命中
      final hit = await matchBookSourceForUrl(
        api,
        [a],
        'https://a.com/other/page',
      );
      expect(hit?.bookSourceName, 'A');
    });

    test('无任何匹配返回 null', () async {
      final a = _source(
        url: 'https://a.com',
        name: 'A',
        pattern: r'https://a\.com/book/\d+',
      );
      expect(
        await matchBookSourceForUrl(api, [a], 'https://zzz.com/x'),
        isNull,
      );
    });

    test('空 URL / 空书源列表返回 null', () async {
      expect(await matchBookSourceForUrl(api, const [], 'https://a.com'), isNull);
      expect(
        await matchBookSourceForUrl(api, [_source(url: 'https://a.com')], '  '),
        isNull,
      );
    });
  });

  group('C4 源码守卫：RSS java.addBook 已真接线', () {
    final src = File(
      'lib/src/screens/rss_article_detail_screen.dart',
    ).readAsStringSync();

    test('不再只 debugPrint 跳过', () {
      expect(
        src.contains('java.addBook 未接线'),
        isFalse,
        reason: 'addBook 已接线，旧的「未接线」分支必须删除',
      );
    });

    test('走共用书源匹配工具与 webbookInfo 入库', () {
      expect(src.contains('matchBookSourceForUrl'), isTrue);
      expect(src.contains('parseBookUrlOption'), isTrue);
      expect(src.contains('api.addBook('), isTrue);
      expect(
        src.contains('api.webbookInfo('),
        isTrue,
        reason: '需抓详情再入库（对齐 AddToBookshelfDialog.getBookInfo）',
      );
    });
  });

  group('C7/C4 共用工具：书架不再重复实现匹配', () {
    final src = File('lib/src/screens/bookshelf_screen.dart').readAsStringSync();

    test('书架 _matchSource 委托共用工具', () {
      expect(src.contains('matchBookSourceForUrl'), isTrue);
      expect(
        src.contains('RegExp(pattern).hasMatch'),
        isFalse,
        reason: 'Dart 侧正则匹配已下沉 Rust',
      );
    });
  });
}
