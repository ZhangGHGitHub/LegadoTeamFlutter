import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/services/bottom_bar_skin_format.dart';

void main() {
  group('BottomBarSkinFormat', () {
    test('parseEntryName 识别槽位', () {
      expect(
        BottomBarSkinFormat.parseEntryName('bookshelf_selected.png'),
        (slot: 'bookshelf', selected: true),
      );
      expect(
        BottomBarSkinFormat.parseEntryName('home_normal.jpg'),
        (slot: 'home', selected: false),
      );
      expect(BottomBarSkinFormat.parseEntryName('foo_selected.png'), isNull);
      expect(BottomBarSkinFormat.parseEntryName('home.png'), isNull);
    });

    test('uniqueName / sanitize', () {
      expect(BottomBarSkinFormat.sanitize('a/b:c'), 'a_b_c');
      expect(BottomBarSkinFormat.uniqueName('猫', ['猫']), '猫 (2)');
      expect(
        BottomBarSkinFormat.uniqueName('猫', ['猫', '猫 (2)']),
        '猫 (3)',
      );
      expect(BottomBarSkinFormat.isValidSkinName('底栏图集'), isTrue);
      expect(BottomBarSkinFormat.isValidSkinName('../skin'), isFalse);
    });

    test('uniqueImageName 重名追加后缀', () {
      final used = <String>{};
      expect(
        BottomBarSkinFormat.uniqueImageName('icon.png', used),
        'icon.png',
      );
      expect(
        BottomBarSkinFormat.uniqueImageName('icon.png', used),
        'icon (2).png',
      );
      expect(
        BottomBarSkinFormat.uniqueImageName('ICON.PNG', used),
        'ICON (3).PNG',
      );
    });

    test('slotLabels 覆盖四槽', () {
      expect(BottomBarSkinFormat.slotLabels.keys.toList(),
          BottomBarSkinFormat.mappedSlots);
    });
  });
}
