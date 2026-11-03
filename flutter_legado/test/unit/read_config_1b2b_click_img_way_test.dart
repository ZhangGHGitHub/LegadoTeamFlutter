// [批1b-2b | 2026-11-04] clickImgWay 配置往返 + 备份白名单单测 —
// 全栈工程师
//
// 依据：
// - 原版 `PreferKey.kt:242` clickImgWay / `pref_config_read.xml:228-235`
//   （五档 values 0..4，参考版默认 "2"=兼容旧版）
// - 键属阅读界面偏好，需登记 RestoreIgnorePrefs.readPrefKeys（勾选
//   「忽略阅读配置」时恢复备份不覆盖本机）
//
// 覆盖：
// 1. 构造器/load 默认 "2"；
// 2. save → load 五档往返；
// 3. 非法存量值 load 钳制回 "2"；
// 4. copy() 携带新字段且与原实例隔离；
// 5. SharedPreferences 键名直写断言；
// 6. readPrefKeys 白名单命中 + keyIsNotIgnore 过滤语义。
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

  group('ReaderAdvancedConfig.clickImgWay', () {
    test('默认 "2"（参考版口径）', () async {
      expect(
        ReaderAdvancedConfig().clickImgWay,
        '2',
        reason: '构造器默认对齐参考版默认 "2"=兼容旧版',
      );
      final loaded = await ReaderAdvancedConfig.load();
      expect(loaded.clickImgWay, '2', reason: '空存储 load 默认 "2"');
    });

    test('save → load 五档往返幂等', () async {
      for (final way in ['0', '1', '2', '3', '4']) {
        final cfg = await ReaderAdvancedConfig.load()..clickImgWay = way;
        await cfg.save();
        expect(
          (await ReaderAdvancedConfig.load()).clickImgWay,
          way,
          reason: '档位 $way 应可读回',
        );
      }
    });

    test('save 前钳制：非法值落盘为 "2"', () async {
      final cfg = await ReaderAdvancedConfig.load()..clickImgWay = '9';
      await cfg.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('clickImgWay'), '2');
      expect((await ReaderAdvancedConfig.load()).clickImgWay, '2');
    });

    test('load 钳制：存量非法值回落 "2"', () async {
      SharedPreferences.setMockInitialValues({'clickImgWay': 'bogus'});
      expect((await ReaderAdvancedConfig.load()).clickImgWay, '2');
    });

    test('copy() 携带新字段且与原实例隔离', () {
      final cfg = ReaderAdvancedConfig()..clickImgWay = '4';
      final copied = cfg.copy();
      expect(copied.clickImgWay, '4');

      cfg.clickImgWay = '1';
      expect(copied.clickImgWay, '4', reason: 'copy 为独立实例，不被后续修改影响');
    });

    test('持久化键名对齐原版 PreferKey（直接读 SharedPreferences 断言）', () async {
      final cfg = await ReaderAdvancedConfig.load()..clickImgWay = '1';
      await cfg.save();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('clickImgWay'),
        '1',
        reason: '键名必须为原版 PreferKey.clickImgWay',
      );
    });
  });

  group('备份忽略白名单（readPrefKeys）', () {
    test('clickImgWay 命中 readPrefKeys', () {
      expect(
        RestoreIgnorePrefs.readPrefKeys.contains('clickImgWay'),
        isTrue,
        reason: '键必须在 readPrefKeys 白名单（勾选「忽略阅读配置」被过滤）',
      );
    });

    test('勾选 readConfig 后该键被过滤（keyIsNotIgnore 语义）', () {
      const ignore = {'readConfig': true};
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('clickImgWay', ignore),
        isFalse,
        reason: '忽略阅读配置时恢复备份不覆盖本机 clickImgWay',
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('someOtherKey', ignore),
        isTrue,
        reason: '非阅读键不受影响',
      );
    });
  });
}
