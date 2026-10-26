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
}
