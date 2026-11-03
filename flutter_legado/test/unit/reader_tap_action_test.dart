// [批4a] 九宫格点击动作模型 / 默认值 / 迁移 / 分区边界测试
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/reader_tap_action.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReaderTapAction 枚举 / 分区', () {
    test('动作代码与中文文案对齐参考 -1..13', () {
      expect(ReaderTapAction.none.code, -1);
      expect(ReaderTapAction.menu.code, 0);
      expect(ReaderTapAction.nextPage.code, 1);
      expect(ReaderTapAction.previousPage.code, 2);
      expect(ReaderTapAction.nextChapter.code, 3);
      expect(ReaderTapAction.previousChapter.code, 4);
      expect(ReaderTapAction.previousParagraph.code, 5);
      expect(ReaderTapAction.nextParagraph.code, 6);
      expect(ReaderTapAction.addBookmark.code, 7);
      expect(ReaderTapAction.editContent.code, 8);
      expect(ReaderTapAction.toggleReplace.code, 9);
      expect(ReaderTapAction.catalog.code, 10);
      expect(ReaderTapAction.search.code, 11);
      expect(ReaderTapAction.syncProgress.code, 12);
      expect(ReaderTapAction.toggleReadAloud.code, 13);
      expect(ReaderTapAction.fromCode(null), ReaderTapAction.none);
      expect(ReaderTapAction.fromCode(99), ReaderTapAction.none);
      expect(ReaderTapAction.fromCode(11), ReaderTapAction.search);
    });

    test('3×3 边界：x/y=1/3、2/3 ±1 归属正确', () {
      int at(double x, double y) => ReaderTapAction.zoneIndexAt(
        x: x,
        y: y,
        width: 300,
        height: 600,
      );

      expect(at(99, 10), 0);
      expect(at(100, 10), 1, reason: 'x=w/3 进中列');
      expect(at(199, 10), 1);
      expect(at(200, 10), 2, reason: 'x=2w/3 进右列');
      expect(at(10, 199), 0);
      expect(at(10, 200), 3, reason: 'y=h/3 进中行');
      expect(at(10, 399), 3);
      expect(at(10, 400), 6, reason: 'y=2h/3 进下行');
      expect(at(1, 1), 0);
      expect(at(299, 1), 2);
      expect(at(1, 599), 6);
      expect(at(299, 599), 8);
      expect(at(150, 300), 4);
    });

    test('越界坐标返回 -1', () {
      int at(double x, double y) => ReaderTapAction.zoneIndexAt(
        x: x,
        y: y,
        width: 300,
        height: 600,
      );
      expect(at(-1, 10), -1);
      expect(at(10, -1), -1);
      expect(at(301, 10), -1);
      expect(at(10, 601), -1);
      expect(
        ReaderTapAction.zoneIndexAt(x: 1, y: 1, width: 0, height: 600),
        -1,
      );
    });
  });

  group('ReaderAdvancedConfig 九宫格默认 / 读写', () {
    test('默认值对齐参考（TL/TC/ML/BL=2，MC=0，其余=1）', () async {
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.tapTopLeft, ReaderTapAction.previousPage);
      expect(cfg.tapTopCenter, ReaderTapAction.previousPage);
      expect(cfg.tapTopRight, ReaderTapAction.nextPage);
      expect(cfg.tapMiddleLeft, ReaderTapAction.previousPage);
      expect(cfg.tapMiddleCenter, ReaderTapAction.menu);
      expect(cfg.tapMiddleRight, ReaderTapAction.nextPage);
      expect(cfg.tapBottomLeft, ReaderTapAction.previousPage);
      expect(cfg.tapBottomCenter, ReaderTapAction.nextPage);
      expect(cfg.tapBottomRight, ReaderTapAction.nextPage);
    });

    test('九键保存后重新加载往返', () async {
      final cfg = await ReaderAdvancedConfig.load();
      cfg.setTapActionAt(0, ReaderTapAction.none);
      cfg.setTapActionAt(1, ReaderTapAction.addBookmark);
      cfg.setTapActionAt(2, ReaderTapAction.editContent);
      cfg.setTapActionAt(3, ReaderTapAction.toggleReplace);
      cfg.setTapActionAt(4, ReaderTapAction.catalog);
      cfg.setTapActionAt(5, ReaderTapAction.search);
      cfg.setTapActionAt(6, ReaderTapAction.syncProgress);
      cfg.setTapActionAt(7, ReaderTapAction.toggleReadAloud);
      cfg.setTapActionAt(8, ReaderTapAction.nextChapter);
      await cfg.save();

      final loaded = await ReaderAdvancedConfig.load();
      for (var i = 0; i < 9; i++) {
        expect(loaded.tapActionAt(i), cfg.tapActionAt(i), reason: 'zone $i');
      }
    });
  });

  group('旧三区整列迁移', () {
    const mapping = {
      TapAction.none: -1,
      TapAction.prevPage: 2,
      TapAction.nextPage: 1,
      TapAction.toggleControls: 0,
      TapAction.openCatalog: 10,
    };

    for (final entry in mapping.entries) {
      test('旧 ${entry.key.name} → ${entry.value}（三列整列）', () async {
        SharedPreferences.setMockInitialValues({
          'reader_adv_left_action': entry.key.index,
          'reader_adv_center_action': entry.key.index,
          'reader_adv_right_action': entry.key.index,
        });
        final cfg = await ReaderAdvancedConfig.load();
        for (var i = 0; i < 9; i++) {
          expect(cfg.tapActionAt(i).code, entry.value, reason: 'zone $i');
        }
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(PrefKeys.clickActionMigratedV2), isTrue);
        for (final key in [
          PrefKeys.clickActionTopLeft,
          PrefKeys.clickActionTopCenter,
          PrefKeys.clickActionTopRight,
          PrefKeys.clickActionMiddleLeft,
          PrefKeys.clickActionMiddleCenter,
          PrefKeys.clickActionMiddleRight,
          PrefKeys.clickActionBottomLeft,
          PrefKeys.clickActionBottomCenter,
          PrefKeys.clickActionBottomRight,
        ]) {
          expect(prefs.getInt(key), entry.value, reason: key);
        }
      });
    }

    test('迁移幂等：标记存在后不再读取旧三区', () async {
      SharedPreferences.setMockInitialValues({
        'reader_adv_left_action': TapAction.none.index,
        'reader_adv_center_action': TapAction.none.index,
        'reader_adv_right_action': TapAction.none.index,
      });
      final first = await ReaderAdvancedConfig.load();
      expect(first.tapMiddleCenter, ReaderTapAction.none);

      final prefs = await SharedPreferences.getInstance();
      // 清掉新键模拟「备份恢复未带新键」，但保留迁移标记
      for (final key in [
        PrefKeys.clickActionTopLeft,
        PrefKeys.clickActionTopCenter,
        PrefKeys.clickActionTopRight,
        PrefKeys.clickActionMiddleLeft,
        PrefKeys.clickActionMiddleCenter,
        PrefKeys.clickActionMiddleRight,
        PrefKeys.clickActionBottomLeft,
        PrefKeys.clickActionBottomCenter,
        PrefKeys.clickActionBottomRight,
      ]) {
        await prefs.remove(key);
      }
      await prefs.setInt(
        'reader_adv_middle_left_action',
        TapAction.openCatalog.index,
      );
      await prefs.setInt(
        'reader_adv_left_action',
        TapAction.openCatalog.index,
      );
      final second = await ReaderAdvancedConfig.load();
      expect(
        second.tapMiddleCenter,
        ReaderTapAction.menu,
        reason: '标记存在时缺失新键回落默认，不再按旧值迁移',
      );
    });

    test('任一新键存在时新键优先，不迁移旧三区', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.clickActionMiddleCenter: ReaderTapAction.search.code,
        'reader_adv_left_action': TapAction.none.index,
        'reader_adv_center_action': TapAction.none.index,
        'reader_adv_right_action': TapAction.none.index,
      });
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.tapMiddleCenter, ReaderTapAction.search);
      expect(cfg.tapTopLeft, ReaderTapAction.previousPage, reason: '新键缺失回落默认');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.clickActionMigratedV2), isNull);
    });
  });

  test('新键进入「忽略阅读配置」；迁移标记仅备份排除', () async {
    const keys = [
      PrefKeys.clickActionTopLeft,
      PrefKeys.clickActionTopCenter,
      PrefKeys.clickActionTopRight,
      PrefKeys.clickActionMiddleLeft,
      PrefKeys.clickActionMiddleCenter,
      PrefKeys.clickActionMiddleRight,
      PrefKeys.clickActionBottomLeft,
      PrefKeys.clickActionBottomCenter,
      PrefKeys.clickActionBottomRight,
    ];
    for (final key in keys) {
      expect(RestoreIgnorePrefs.readPrefKeys, contains(key));
    }
    expect(
      RestoreIgnorePrefs.backupExcludedKeys,
      contains(PrefKeys.clickActionMigratedV2),
    );
    SharedPreferences.setMockInitialValues({
      PrefKeys.clickActionMigratedV2: true,
      PrefKeys.clickActionMiddleCenter: 11,
    });
    final backup = await RestoreIgnorePrefs.collectForBackup(const {});
    expect(backup.containsKey(PrefKeys.clickActionMigratedV2), isFalse);
    expect(backup[PrefKeys.clickActionMiddleCenter], 11);
  });
}
