import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RestoreIgnorePrefs.keyIsNotIgnore', () {
    test('默认全部可备份', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.showRss, const {}),
        isTrue,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('reader_font_size', const {}),
        isTrue,
      );
    });

    test('alwaysIgnore 永远跳过', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.launcherIcon, const {}),
        isFalse,
      );
      // 本地密码属于设备级秘密，任何 ignore 组合下都不得进备份
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.localPassword, const {}),
        isFalse,
      );
    });

    test('勾选 readConfig 跳过阅读键', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'reader_font_size',
          {'readConfig': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.showRss,
          {'readConfig': true},
        ),
        isTrue,
      );
    });

    test('勾选 themeMode / showRss / threadCount / bookshelfLayout', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          RestoreIgnorePrefs.themeModeStorageKey,
          {'themeMode': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.showRss,
          {'showRss': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.threadCount,
          {'threadCount': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          RestoreIgnorePrefs.bookshelfLayoutStorageKey,
          {'bookshelfLayout': true},
        ),
        isFalse,
      );
    });

    test('勾选 themeConfig / coverConfig', () {
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.cPrimary,
          {'themeConfig': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.coverShowName,
          {'coverConfig': true},
        ),
        isFalse,
      );
    });
  });

  group('RestoreIgnorePrefs collect/apply', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        PrefKeys.showRss: false,
        PrefKeys.threadCount: 8,
        'reader_font_size': 20.0,
        PrefKeys.launcherIcon: 'icon_a',
        PrefKeys.localPassword: '1234',
      });
    });

    test('collect 按 ignore 过滤并跳过 alwaysIgnore', () async {
      final collected = await RestoreIgnorePrefs.collectForBackup({
        'readConfig': true,
      });
      expect(collected.containsKey(PrefKeys.showRss), isTrue);
      expect(collected[PrefKeys.showRss], isFalse);
      expect(collected[PrefKeys.threadCount], 8);
      expect(collected.containsKey('reader_font_size'), isFalse);
      expect(collected.containsKey(PrefKeys.launcherIcon), isFalse);
      // 本地密码不写入备份 appPrefs（避免明文口令随备份文件外流）
      expect(collected.containsKey(PrefKeys.localPassword), isFalse);
    });

    test('本地密码不被备份值覆盖', () async {
      await RestoreIgnorePrefs.applyFromBackup(
        {PrefKeys.localPassword: 'backup-password'},
        const {},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PrefKeys.localPassword),
        '1234',
        reason: '本机既有本地密码必须保持不变',
      );
    });

    test('apply 尊重 ignore 不覆盖本地项', () async {
      await RestoreIgnorePrefs.applyFromBackup(
        {
          PrefKeys.showRss: true,
          PrefKeys.threadCount: 32,
          'reader_font_size': 14.0,
        },
        {
          'showRss': true,
          'readConfig': false,
        },
      );
      final prefs = await SharedPreferences.getInstance();
      // showRss 忽略 → 保持 mock 初始 false
      expect(prefs.getBool(PrefKeys.showRss), isFalse);
      expect(prefs.getInt(PrefKeys.threadCount), 32);
      expect(prefs.getDouble('reader_font_size'), 14.0);
    });
  });
}
