import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/screens/reader_config_panel.dart';

/// [N4 偏好迁移 | 2.0.271 | 子代理] 一次性默认值迁移单测：
/// C2 批（2.0.262）改新默认（状态行四开关关、tipFooterLeft=7 书名），
/// 已装设备存量旧值需一次性迁移。语义：
///   存量 == 旧默认 → 改写新默认；存量 != 旧默认（用户手动改过）→ 不动；
///   迁移标记 settingsMigrated_v271 置位后幂等（不再执行）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const markerKey = 'settingsMigrated_v271';
  const statusKeys = <String>[
    'reader_adv_show_battery',
    'reader_adv_show_time',
    'reader_adv_show_progress',
    'reader_adv_show_chapter_name',
  ];

  /// 旧默认存量：状态行四键全开（true）+ tipFooterLeft=1（章节名）
  Map<String, Object> legacyDefaults() => {
        for (final k in statusKeys) k: true,
        'tipFooterLeft': 1,
      };

  group('N4 一次性偏好迁移', () {
    test('存量=旧默认 → 迁移为新默认并置标记', () async {
      SharedPreferences.setMockInitialValues(legacyDefaults());
      final cfg = await ReaderAdvancedConfig.load();

      // 配置对象：新默认生效
      expect(cfg.showBattery, isFalse);
      expect(cfg.showTime, isFalse);
      expect(cfg.showProgress, isFalse);
      expect(cfg.showChapterName, isFalse);
      expect(cfg.tipFooterLeft, 7);

      // 存储层：存量键被改写
      final prefs = await SharedPreferences.getInstance();
      for (final k in statusKeys) {
        expect(prefs.getBool(k), isFalse, reason: '$k 应迁移为 false');
      }
      expect(prefs.getInt('tipFooterLeft'), 7, reason: 'tipFooterLeft 应迁移为 7');
      // 迁移标记已置位
      expect(prefs.getBool(markerKey), isTrue);
    });

    test('存量=自定义值（用户手动改过）→ 不动，仅置标记', () async {
      // 用户手动关闭了时间/章节行、tipFooterLeft 手动选了 3（页码）
      SharedPreferences.setMockInitialValues({
        'reader_adv_show_battery': true, // 未动过（仍=旧默认）
        'reader_adv_show_time': false,
        'reader_adv_show_progress': true,
        'reader_adv_show_chapter_name': false,
        'tipFooterLeft': 3,
      });
      final cfg = await ReaderAdvancedConfig.load();

      // 存量 != 旧默认的键保持原值
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('reader_adv_show_time'), isFalse);
      expect(prefs.getBool('reader_adv_show_chapter_name'), isFalse);
      expect(prefs.getInt('tipFooterLeft'), 3, reason: '用户自定义值不得被覆盖');
      // 存量 == 旧默认的键正常迁移
      expect(prefs.getBool('reader_adv_show_battery'), isFalse);
      expect(prefs.getBool('reader_adv_show_progress'), isFalse);
      expect(cfg.showTime, isFalse);
      expect(cfg.tipFooterLeft, 3);
      expect(prefs.getBool(markerKey), isTrue);
    });

    test('已置标记 → 幂等（存量旧值不再被改写）', () async {
      // 标记存在时即使存量仍是旧值也不迁移（尊重标记后的现状）
      SharedPreferences.setMockInitialValues({
        ...legacyDefaults(),
        markerKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await ReaderAdvancedConfig.load();

      expect(prefs.getBool('reader_adv_show_time'), isTrue,
          reason: '标记存在 → 跳过迁移，存量保持');
      expect(prefs.getInt('tipFooterLeft'), 1,
          reason: '标记存在 → 跳过迁移，存量保持');
    });

    test('全新安装（无存量键）→ 新默认生效并置标记', () async {
      SharedPreferences.setMockInitialValues({});
      final cfg = await ReaderAdvancedConfig.load();

      expect(cfg.showBattery, isFalse);
      expect(cfg.showTime, isFalse);
      expect(cfg.showProgress, isFalse);
      expect(cfg.showChapterName, isFalse);
      expect(cfg.tipFooterLeft, 7);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(markerKey), isTrue);
    });

    test('重复 load → 迁移仅执行一次（幂等）', () async {
      SharedPreferences.setMockInitialValues(legacyDefaults());
      await ReaderAdvancedConfig.load();
      // 第二次 load：标记已置位，存储值不再变化
      final prefs1 = await SharedPreferences.getInstance();
      final before = <String, Object>{
        for (final k in statusKeys) k: prefs1.getBool(k)!,
        'tipFooterLeft': prefs1.getInt('tipFooterLeft')!,
      };
      final cfg2 = await ReaderAdvancedConfig.load();
      final prefs2 = await SharedPreferences.getInstance();
      for (final k in statusKeys) {
        expect(prefs2.getBool(k), before[k]);
      }
      expect(prefs2.getInt('tipFooterLeft'), before['tipFooterLeft']);
      expect(cfg2.tipFooterLeft, 7);
      expect(cfg2.showTime, isFalse);
    });
  });
}
