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

    test('missing src returns null', () {
      expect(LegadoDeepLink.tryParse('legado://import/bookSource'), isNull);
    });
  });
}
