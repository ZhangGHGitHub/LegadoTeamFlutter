// [漫画设置作用域 2026-10-01] ReadConfig 书级字段 JSON 兼容回归
//
// 取证（参考版 legado-with-MD3）：
// - data/entities/Book.kt L488-489：`var mangaScrollMode: Int? = null` /
//   `var webtoonSidePaddingDp: Int? = null`（可空 = 未覆盖，跟随全局）；
// - MangaReaderViewModel.kt L1332-1334：
//   `book?.scrollMode ?: settings.scrollMode`（书级非空优先，否则全局）。
//
// 本测试锁定：
// 1. 旧书 JSON（无书级字段）解析为 null —— 存量库兼容，回退全局；
// 2. 键名与参考版一致（mangaScrollMode / webtoonSidePaddingDp）且可往返；
// 3. copyWith(null) 可显式清除书级覆盖（不写入默认值冒充清除）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';

void main() {
  group('[漫画设置作用域] ReadConfig 书级字段', () {
    test('旧 JSON 无书级字段：解析为 null（存量库兼容，回退全局）', () {
      final config = ReadConfig.fromJson(<String, dynamic>{
        'reverseToc': true,
        'dailyChapters': 7,
      });

      expect(config.mangaScrollMode, isNull);
      expect(config.webtoonSidePaddingDp, isNull);
      // 既有字段不受影响
      expect(config.reverseToc, isTrue);
      expect(config.dailyChapters, 7);
    });

    test('书级字段按参考版键名解析（mangaScrollMode / webtoonSidePaddingDp）',
        () {
      final config = ReadConfig.fromJson(<String, dynamic>{
        'mangaScrollMode': 3,
        'webtoonSidePaddingDp': 20,
      });

      expect(config.mangaScrollMode, 3);
      expect(config.webtoonSidePaddingDp, 20);
    });

    test('toJson 使用参考版键名并保留既有字段', () {
      const config = ReadConfig(
        reverseToc: true,
        playSpeed: 1.5,
        mangaScrollMode: 2,
        webtoonSidePaddingDp: 15,
      );

      final json = config.toJson();
      expect(json['mangaScrollMode'], 2);
      expect(json['webtoonSidePaddingDp'], 15);
      expect(json['reverseToc'], isTrue);
      expect(json['playSpeed'], 1.5);
    });

    test('copyWith(mangaScrollMode: null) 显式清除覆盖且保留其他字段', () {
      const config = ReadConfig(
        reverseToc: true,
        dailyChapters: 7,
        mangaScrollMode: 2,
        webtoonSidePaddingDp: 10,
      );

      final cleared = config.copyWith(mangaScrollMode: null);

      expect(cleared.mangaScrollMode, isNull, reason: '清除 = 键值置 null');
      expect(cleared.webtoonSidePaddingDp, 10, reason: '未目标字段不得被清除');
      expect(cleared.reverseToc, isTrue);
      expect(cleared.dailyChapters, 7);
    });

    test('copyWith 未目标字段保持原值（webtoonSidePaddingDp 显式置空同理）',
        () {
      const config = ReadConfig(mangaScrollMode: 5, webtoonSidePaddingDp: 10);

      final cleared = config.copyWith(webtoonSidePaddingDp: null);

      expect(cleared.webtoonSidePaddingDp, isNull);
      expect(cleared.mangaScrollMode, 5);
    });
  });
}
