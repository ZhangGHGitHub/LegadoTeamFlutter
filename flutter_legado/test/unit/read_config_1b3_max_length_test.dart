// [批1b-3 | 2026-10-31] 「无目录时每章字数」设置项单元测试：
// 模型默认值/改值往返/夹逼 + 备份白名单 — 全栈工程师
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderAdvancedConfig maxLengthWithNoToc', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('默认值对齐参考版（3000）', () async {
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.maxLengthWithNoToc, 3000, reason: '参考版 ReadSettings 默认 3000');
    });

    test('save → load 幂等（改值往返一致）', () async {
      final cfg = await ReaderAdvancedConfig.load()..maxLengthWithNoToc = 50000;
      await cfg.save();

      final reloaded = await ReaderAdvancedConfig.load();
      expect(reloaded.maxLengthWithNoToc, 50000);

      // 写回默认再读：可逆
      final cfg2 = await ReaderAdvancedConfig.load()..maxLengthWithNoToc = 3000;
      await cfg2.save();
      final reloaded2 = await ReaderAdvancedConfig.load();
      expect(reloaded2.maxLengthWithNoToc, 3000);
    });

    test('load 夹逼：越界值收敛到 3000..100000（对齐参考版 coerceIn）', () async {
      // 越界下限
      SharedPreferences.setMockInitialValues({'maxLengthWithNoToc': 100});
      var cfg = await ReaderAdvancedConfig.load();
      expect(cfg.maxLengthWithNoToc, 3000, reason: '越界下限夹逼到 3000');

      // 越界上限
      SharedPreferences.setMockInitialValues({'maxLengthWithNoToc': 200000});
      cfg = await ReaderAdvancedConfig.load();
      expect(cfg.maxLengthWithNoToc, 100000, reason: '越界上限夹逼到 100000');

      // 边界值原样
      SharedPreferences.setMockInitialValues({'maxLengthWithNoToc': 100000});
      cfg = await ReaderAdvancedConfig.load();
      expect(cfg.maxLengthWithNoToc, 100000);
    });

    test('持久化键名对齐参考版 PreferKey（直接读 SharedPreferences 断言）',
        () async {
      final cfg = await ReaderAdvancedConfig.load()..maxLengthWithNoToc = 42000;
      await cfg.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('maxLengthWithNoToc'), 42000);
    });

    test('copy() 携带新字段（推送 provider 的副本不丢值）', () async {
      final cfg = await ReaderAdvancedConfig.load()..maxLengthWithNoToc = 60000;
      final copied = cfg.copy();
      expect(copied.maxLengthWithNoToc, 60000);
    });

    test('copy() 修改不影响原实例（隔离性）', () async {
      final cfg = await ReaderAdvancedConfig.load();
      final copied = cfg.copy()..maxLengthWithNoToc = 70000;
      expect(cfg.maxLengthWithNoToc, 3000);
      expect(copied.maxLengthWithNoToc, 70000);
    });
  });

  group('备份忽略白名单（readPrefKeys）', () {
    test('maxLengthWithNoToc 命中 readPrefKeys', () {
      expect(
        RestoreIgnorePrefs.readPrefKeys.contains('maxLengthWithNoToc'),
        isTrue,
        reason: '键 maxLengthWithNoToc 必须在 readPrefKeys 白名单'
            '（勾选「忽略阅读配置」被过滤）',
      );
    });

    test('勾选 readConfig 后键被过滤（keyIsNotIgnore 语义）', () {
      const ignore = {'readConfig': true};
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('maxLengthWithNoToc', ignore),
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
