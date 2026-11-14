// P3-10 字体导入去重：同 family 条目原位覆盖，不重复累积
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/font_screen.dart';

void main() {
  group('upsertCustomFontEntry', () {
    test('同 family 重复导入：原位覆盖且返回 false', () {
      final entries = <String>['Custom_A|fonts/Custom_A.ttf'];

      final isNew = upsertCustomFontEntry(
        entries,
        'Custom_A|fonts/Custom_A.ttf',
      );

      expect(isNew, isFalse);
      expect(entries, hasLength(1));
      expect(entries.single, 'Custom_A|fonts/Custom_A.ttf');
    });

    test('新 family：追加并返回 true', () {
      final entries = <String>['Custom_A|fonts/Custom_A.ttf'];

      final isNew = upsertCustomFontEntry(
        entries,
        'Custom_B|fonts/Custom_B.ttf',
      );

      expect(isNew, isTrue);
      expect(entries, [
        'Custom_A|fonts/Custom_A.ttf',
        'Custom_B|fonts/Custom_B.ttf',
      ]);
    });

    test('同 family 条目路径变化：原位更新为最新路径', () {
      final entries = <String>['Custom_A|fonts/old.ttf'];

      final isNew = upsertCustomFontEntry(
        entries,
        'Custom_A|fonts/Custom_A.ttf',
      );

      expect(isNew, isFalse);
      expect(entries, ['Custom_A|fonts/Custom_A.ttf']);
    });
  });
}
