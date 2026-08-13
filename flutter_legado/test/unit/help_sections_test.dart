import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/help/help_sections.dart';

void main() {
  group('parseHelpSections', () {
    test('按 ## 标题切分', () {
      const md = '''
# 帮助

## 第一节
内容 A

## 第二节
内容 B
''';
      final sections = parseHelpSections(md);
      expect(sections.length, 2);
      expect(sections[0].title, '第一节');
      expect(sections[1].title, '第二节');
    });

    test('单节时不切分', () {
      const md = '''
# 帮助

## 唯一节
内容
''';
      expect(parseHelpSections(md), isEmpty);
    });
  });
}
