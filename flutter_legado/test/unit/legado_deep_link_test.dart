import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/providers/association/association_state.dart';
import 'package:flutter_legado/src/utils/legado_deep_link.dart';

void main() {
  group('LegadoDeepLink', () {
    test('parses bookSource import path', () {
      final link = LegadoDeepLink.tryParse(
        'legado://import/bookSource?src=https://example.com/sources.json',
      );
      expect(link, isNotNull);
      expect(link!.srcUrl, 'https://example.com/sources.json');
      expect(link.importType, ImportType.bookSource);
    });

    test('parses yuedu rssSource', () {
      final link = LegadoDeepLink.tryParse(
        'yuedu://import/rssSource?src=https://example.com/rss.json',
      );
      expect(link!.importType, ImportType.rssSource);
    });

    test('parses httpTTS path', () {
      final link = LegadoDeepLink.tryParse(
        'legado://import/httpTTS?src=https://example.com/tts.json',
      );
      expect(link!.importType, ImportType.httpTts);
    });

    test('parses dictRule path', () {
      final link = LegadoDeepLink.tryParse(
        'legado://import/dictRule?src=https://example.com/dict.json',
      );
      expect(link!.importType, ImportType.dictRule);
    });

    // P2-8：补齐 highlightRule / autoTask 深链映射
    test('parses highlightRule path', () {
      final link = LegadoDeepLink.tryParse(
        'legado://import/highlightRule?src=https://example.com/highlight.json',
      );
      expect(link, isNotNull);
      expect(link!.pathKey, 'highlightRule');
      expect(link.importType, ImportType.highlightRule);
    });

    test('parses autoTask path', () {
      final link = LegadoDeepLink.tryParse(
        'legado://import/autoTask?src=https://example.com/auto_task.json',
      );
      expect(link, isNotNull);
      expect(link!.pathKey, 'autoTask');
      expect(link.importType, ImportType.autoTask);
    });

    test('missing src returns null', () {
      expect(LegadoDeepLink.tryParse('legado://import/bookSource'), isNull);
    });
  });

  // [M3 我的页 | 2026-11-03] 外部路由深链：legado://dict / dict_rule
  group('LegadoDeepLink.tryParseRoute', () {
    test('host 级 dict / dict_rule', () {
      expect(
        LegadoDeepLink.tryParseRoute('legado://dict'),
        LegadoRouteDeepLink.dict,
      );
      expect(
        LegadoDeepLink.tryParseRoute('legado://dict_rule'),
        LegadoRouteDeepLink.dictRule,
      );
    });

    test('yuedu:// 与大小写不敏感', () {
      expect(
        LegadoDeepLink.tryParseRoute('yuedu://dict'),
        LegadoRouteDeepLink.dict,
      );
      expect(
        LegadoDeepLink.tryParseRoute('Yuedu://DICT_RULE'),
        LegadoRouteDeepLink.dictRule,
      );
    });

    test('带/不带三斜杠、末尾斜杠、query 忽略', () {
      expect(
        LegadoDeepLink.tryParseRoute('legado:///dict'),
        LegadoRouteDeepLink.dict,
      );
      expect(
        LegadoDeepLink.tryParseRoute('legado:///dict_rule?src=https://a/b'),
        LegadoRouteDeepLink.dictRule,
      );
      expect(
        LegadoDeepLink.tryParseRoute('legado://dict/'),
        LegadoRouteDeepLink.dict,
      );
      expect(
        LegadoDeepLink.tryParseRoute('  legado://dict?foo=bar  '),
        LegadoRouteDeepLink.dict,
      );
    });

    test('导入深链与未知 host / 额外路径不识别（交回导入分流）', () {
      expect(
        LegadoDeepLink.tryParseRoute(
          'legado://import/dictRule?src=https://example.com/dict.json',
        ),
        isNull,
      );
      expect(
        LegadoDeepLink.tryParseRoute('legado://import/bookSource'),
        isNull,
      );
      expect(LegadoDeepLink.tryParseRoute('legado://mystery'), isNull);
      expect(LegadoDeepLink.tryParseRoute('legado://dict/child'), isNull);
      expect(LegadoDeepLink.tryParseRoute('https://example.com/dict'), isNull);
      expect(LegadoDeepLink.tryParseRoute(''), isNull);
    });
  });
}
