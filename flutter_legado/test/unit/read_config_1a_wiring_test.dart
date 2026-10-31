// [批1a | 2026-10-31] 阅读设置新三项（sliderVibrator/selectVibrator/
// disableReturnKey）+ 阅读设置页键白名单单元测试 — 全栈工程师
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderAdvancedConfig 新三项往返幂等', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('默认值对齐参考版（均 false）', () async {
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.sliderVibrator, isFalse, reason: '参考版 compatDsValue 默认 false');
      expect(cfg.selectVibrator, isFalse, reason: '参考版 compatDsValue 默认 false');
      expect(cfg.disableReturnKey, isFalse, reason: '原版 XML 默认 false');
    });

    test('save → load 幂等（三键全量写读一致）', () async {
      final cfg = await ReaderAdvancedConfig.load();
      cfg
        ..sliderVibrator = true
        ..selectVibrator = true
        ..disableReturnKey = true;
      await cfg.save();

      final reloaded = await ReaderAdvancedConfig.load();
      expect(reloaded.sliderVibrator, isTrue);
      expect(reloaded.selectVibrator, isTrue);
      expect(reloaded.disableReturnKey, isTrue);

      // 再写回 false 再读：可逆
      final cfg2 = await ReaderAdvancedConfig.load();
      cfg2
        ..sliderVibrator = false
        ..selectVibrator = false
        ..disableReturnKey = false;
      await cfg2.save();
      final reloaded2 = await ReaderAdvancedConfig.load();
      expect(reloaded2.sliderVibrator, isFalse);
      expect(reloaded2.selectVibrator, isFalse);
      expect(reloaded2.disableReturnKey, isFalse);
    });

    test('copy() 携带新三项（推送 provider 的副本不丢值）', () async {
      final cfg = await ReaderAdvancedConfig.load()
        ..sliderVibrator = true
        ..selectVibrator = true
        ..disableReturnKey = true;
      final copied = cfg.copy();
      expect(copied.sliderVibrator, isTrue);
      expect(copied.selectVibrator, isTrue);
      expect(copied.disableReturnKey, isTrue);
    });

    test('copy() 修改不影响原实例（隔离性）', () {
      final cfg = ReaderAdvancedConfig();
      final copied = cfg.copy()..disableReturnKey = true;
      expect(cfg.disableReturnKey, isFalse);
      expect(copied.disableReturnKey, isTrue);
    });

    test('持久化键名对齐参考版 PreferKey（直接读 SharedPreferences 断言）',
        () async {
      final cfg = await ReaderAdvancedConfig.load()..disableReturnKey = true;
      await cfg.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('disableReturnKey'), isTrue);
      expect(prefs.getBool('sliderVibrator'), isFalse,
          reason: 'save 全量写：未改值写默认');
      expect(prefs.getBool('selectVibrator'), isFalse);
    });
  });

  group('备份忽略白名单（readPrefKeys）', () {
    test('阅读设置页全部键命中 readPrefKeys', () {
      const readConfigPageKeys = <String>[
        'screenOrientation',
        'keep_light',
        'hideStatusBar',
        'hideNavigationBar',
        'paddingDisplayCutouts',
        'readBodyToLh',
        'showBrightnessView',
        'doubleHorizontalPage',
        'progressBarBehavior',
        'useZhLayout',
        'textFullJustify',
        'hangingPunctuation',
        'pageTouchClick',
        'pageTouchSlop',
        'mouseWheelPage',
        'volumeKeyPage',
        'volumeKeyPageOnPlay',
        // [批1b-2a] 按键长按翻页（键名=原版 PreferKey）
        'keyPageOnLongPress',
        'noAnimScrollPage',
        'autoChangeSource',
        'selectText',
        'showReadTitleAddition',
        'readBarStyleFollowPage',
        // 本批新三项
        'sliderVibrator',
        'selectVibrator',
        'disableReturnKey',
      ];
      for (final key in readConfigPageKeys) {
        expect(
          RestoreIgnorePrefs.readPrefKeys.contains(key),
          isTrue,
          reason: '键 $key 必须在 readPrefKeys 白名单（勾选「忽略阅读配置」被过滤）',
        );
      }
    });

    test('勾选 readConfig 后键被过滤（keyIsNotIgnore 语义）', () {
      const ignore = {'readConfig': true};
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('sliderVibrator', ignore),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('selectVibrator', ignore),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('disableReturnKey', ignore),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('showReadTitleAddition', ignore),
        isFalse,
      );
      // 非阅读键不受影响
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('someOtherKey', ignore),
        isTrue,
      );
    });
  });
}
