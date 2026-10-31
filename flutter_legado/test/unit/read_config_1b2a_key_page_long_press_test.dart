// [批1b-2a | 2026-11-01] keyPageOnLongPress 配置往返 + 备份白名单单测 —
// 全栈工程师
//
// 依据：
// - 原版 AppConfig.kt:856-857 `getPrefBoolean(PreferKey.keyPageOnLongPress,
//   false)`；pref_config_read.xml android:defaultValue="false"
// - 参考版 ReadSettings 默认 false（与 1b-1/1b-3 同口径）
// - 键属阅读界面偏好，需登记 RestoreIgnorePrefs.readPrefKeys（勾选
//   「忽略阅读配置」时恢复备份不覆盖本机）
//
// 覆盖：
// 1. 构造器/load 默认 false；
// 2. save → load 往返（true/false 双向往返）；
// 3. copy() 携带新字段且与原实例隔离；
// 4. SharedPreferences 键名直写断言；
// 5. readPrefKeys 白名单命中 + keyIsNotIgnore 过滤语义。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReaderAdvancedConfig.keyPageOnLongPress', () {
    test('默认 false（原版 AppConfig / pref_config_read.xml 口径）', () async {
      expect(
        ReaderAdvancedConfig().keyPageOnLongPress,
        isFalse,
        reason: '构造器默认对齐原版 defaultValue=false',
      );
      final loaded = await ReaderAdvancedConfig.load();
      expect(loaded.keyPageOnLongPress, isFalse, reason: '空存储 load 默认 false');
    });

    test('save → load 往返幂等（true → false 可逆）', () async {
      final cfg = await ReaderAdvancedConfig.load()
        ..keyPageOnLongPress = true;
      await cfg.save();

      final reloaded = await ReaderAdvancedConfig.load();
      expect(reloaded.keyPageOnLongPress, isTrue, reason: '开启值应可读回');

      final cfg2 = await ReaderAdvancedConfig.load()
        ..keyPageOnLongPress = false;
      await cfg2.save();
      expect(
        (await ReaderAdvancedConfig.load()).keyPageOnLongPress,
        isFalse,
        reason: '关闭值应可读回（不能沿用旧 true）',
      );
    });

    test('copy() 携带新字段且与原实例隔离', () {
      final cfg = ReaderAdvancedConfig()..keyPageOnLongPress = true;
      final copied = cfg.copy();
      expect(copied.keyPageOnLongPress, isTrue);

      cfg.keyPageOnLongPress = false;
      expect(copied.keyPageOnLongPress, isTrue, reason: 'copy 为独立实例，不被后续修改影响');
    });

    test('持久化键名对齐原版 PreferKey（直接读 SharedPreferences 断言）', () async {
      final cfg = await ReaderAdvancedConfig.load()
        ..keyPageOnLongPress = true;
      await cfg.save();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('keyPageOnLongPress'),
        isTrue,
        reason: '键名必须为原版 PreferKey.keyPageOnLongPress',
      );
    });
  });

  group('备份忽略白名单（readPrefKeys）', () {
    test('keyPageOnLongPress 命中 readPrefKeys', () {
      expect(
        RestoreIgnorePrefs.readPrefKeys.contains('keyPageOnLongPress'),
        isTrue,
        reason: '键必须在 readPrefKeys 白名单（勾选「忽略阅读配置」被过滤）',
      );
    });

    test('勾选 readConfig 后该键被过滤（keyIsNotIgnore 语义）', () {
      const ignore = {'readConfig': true};
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('keyPageOnLongPress', ignore),
        isFalse,
        reason: '忽略阅读配置时恢复备份不覆盖本机 keyPageOnLongPress',
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('someOtherKey', ignore),
        isTrue,
        reason: '非阅读键不受影响',
      );
    });
  });
}
