// [批4b] 自定义翻页键 keyCode 串解析/归一化测试
//
// 编写：全栈工程师（批4b） ｜ 2026-11-04
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/utils/page_key_codes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PageKeyCodes', () {
    test('逗号/空白分割、去重保序、非法与 BACK/DEL 忽略', () {
      expect(PageKeyCodes.parse('24,25, 4,67,abc,-1,24,92'), [24, 25, 92]);
      expect(PageKeyCodes.parse('  \n '), isEmpty);
      expect(PageKeyCodes.parse(null), isEmpty);
      expect(PageKeyCodes.parse('0,4,67'), isEmpty);
    });

    test('normalize/append/remove', () {
      expect(PageKeyCodes.normalize('24, 24,67,abc,25'), '24,25');
      expect(PageKeyCodes.append('24', 25), '24,25');
      expect(PageKeyCodes.append('24', 24), '24', reason: '去重');
      expect(PageKeyCodes.append('24', 67), '24', reason: 'DEL 不追加');
      expect(PageKeyCodes.remove('24,25,92', 25), '24,92');
    });

    test('ReaderAdvancedConfig 加载/保存往返', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.prevKeyCodes: '24, 92,4,abc',
        PrefKeys.nextKeyCodes: '25,93',
      });
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.prevKeyCodes, '24,92');
      expect(cfg.nextKeyCodes, '25,93');

      cfg.prevKeyCodes = '19,20';
      cfg.nextKeyCodes = '21';
      await cfg.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.prevKeyCodes), '19,20');
      expect(prefs.getString(PrefKeys.nextKeyCodes), '21');

      final loaded = await ReaderAdvancedConfig.load();
      expect(loaded.prevKeyCodes, '19,20');
      expect(loaded.nextKeyCodes, '21');
    });

    test('prev/next 键进入「忽略阅读配置」', () {
      for (final key in [PrefKeys.prevKeyCodes, PrefKeys.nextKeyCodes]) {
        expect(RestoreIgnorePrefs.readPrefKeys, contains(key));
        expect(
          RestoreIgnorePrefs.keyIsNotIgnore(key, const {'readConfig': true}),
          isFalse,
        );
        expect(RestoreIgnorePrefs.keyIsNotIgnore(key, const {}), isTrue);
      }
    });
  });
}
