// [批31] 目录「显示反转」模型回归
//
// 取证（原版 gedoor/legado `531f9fbf07`）：
// - `Book.kt:502`：`var reverseTocDisplay: Boolean = false`；
// - `BookDao.kt:361-362`：`updateReverseTocDisplay` 仅改写 readConfig JSON
//   的 `reverseTocDisplay` 键；
// - `TocViewModel.kt:75-79` / `ChapterListFragment.kt:193-194`：
//   `reverseOrder = book.getReverseToc()` → `reverseDisplay =
//   book.getReverseTocDisplay()`（先数据反转、再显示反转）。
//
// 本测试锁定：
// 1. 旧书 JSON 缺键 → 默认 false（存量库兼容）；
// 2. 键名与原版逐字一致且可往返；
// 3. copyWith 两开关互相独立（显示反转不得改动数据反转）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';

void main() {
  group('[批31] ReadConfig.reverseTocDisplay', () {
    test('旧 JSON 缺键默认 false，既有字段不受影响', () {
      final config = ReadConfig.fromJson(<String, dynamic>{
        'reverseToc': true,
        'dailyChapters': 7,
      });

      expect(config.reverseTocDisplay, isFalse);
      expect(config.reverseToc, isTrue);
      expect(config.dailyChapters, 7);
    });

    test('按原版键名解析并往返（reverseToc / reverseTocDisplay 独立）', () {
      final config = ReadConfig.fromJson(<String, dynamic>{
        'reverseToc': true,
        'reverseTocDisplay': true,
      });

      expect(config.reverseToc, isTrue);
      expect(config.reverseTocDisplay, isTrue);

      final json = config.toJson();
      expect(json['reverseToc'], isTrue);
      expect(json['reverseTocDisplay'], isTrue);
    });

    test('copyWith 切换显示反转不影响数据反转', () {
      const config = ReadConfig(reverseToc: true);
      final toggled = config.copyWith(reverseTocDisplay: true);

      expect(toggled.reverseToc, isTrue, reason: '数据反转保持');
      expect(toggled.reverseTocDisplay, isTrue);

      final back = toggled.copyWith(reverseTocDisplay: false);
      expect(back.reverseToc, isTrue);
      expect(back.reverseTocDisplay, isFalse);
    });
  });
}
