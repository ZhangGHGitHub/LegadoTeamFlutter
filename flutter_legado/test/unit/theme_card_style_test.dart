// [设置批2b-1b-1 | 2026-11-01] 卡片圆角/边框/分隔线偏好与解析单测 — 全栈工程师
//
// 覆盖任务书测试项：键名逐字对齐参考版 PreferKey、默认值/范围钳制、持久化
// 往返、圆角优先级（disable > override > 16）、边框 0 色回落 outlineVariant、
// 分隔线 0 色回落灰色 30%、长度百分比几何、备份白名单与恢复同会话。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/theme/card_style.dart';

final _lightScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
final _darkScheme = ColorScheme.fromSeed(
  seedColor: Colors.blue,
  brightness: Brightness.dark,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  Future<ProviderContainer> containerWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(uiSettingsProvider.notifier).reload();
    return container;
  }

  group('键名与默认值', () {
    test('键名逐字对齐参考版 PreferKey.kt', () {
      expect(PrefKeys.overrideBaseCardBorder, 'overrideBaseCardBorder');
      expect(PrefKeys.baseCardBorderWidth, 'baseCardBorderWidth');
      expect(PrefKeys.baseCardBorderColor, 'baseCardBorderColor');
      expect(PrefKeys.baseCardBorderColorNight, 'baseCardBorderColorNight');
      expect(
        PrefKeys.disableSplicedColumnGroupCornerRadius,
        'disableSplicedColumnGroupCornerRadius',
      );
      expect(PrefKeys.itemDividerWidth, 'itemDividerWidth');
      expect(PrefKeys.itemDividerLength, 'itemDividerLength');
      expect(PrefKeys.itemDividerColor, 'itemDividerColor');
      // 既有三键不变
      expect(
        PrefKeys.overrideBaseCardCornerRadius,
        'overrideBaseCardCornerRadius',
      );
      expect(PrefKeys.baseCardCornerRadius, 'baseCardCornerRadius');
      expect(PrefKeys.enableItemDivider, 'enableItemDivider');
    });

    test('UiSettingsState 默认：参考版 ThemeSettings 同口径', () {
      const state = UiSettingsState();
      expect(state.overrideBaseCardCornerRadius, isFalse);
      expect(state.baseCardCornerRadius, 16);
      expect(state.overrideBaseCardBorder, isFalse);
      expect(state.baseCardBorderWidth, 1);
      expect(state.baseCardBorderColor, 0);
      expect(state.baseCardBorderColorNight, 0);
      expect(state.disableSplicedColumnGroupCornerRadius, isFalse);
      expect(state.enableItemDivider, isFalse);
      expect(state.itemDividerWidth, 1);
      expect(state.itemDividerLength, 80);
      expect(state.itemDividerColor, 0);
    });

    test('空存储加载后保持默认值', () async {
      final state = (await containerWith(
        <String, Object>{},
      )).read(uiSettingsProvider);
      expect(state.overrideBaseCardBorder, isFalse);
      expect(state.baseCardBorderWidth, 1);
      expect(state.disableSplicedColumnGroupCornerRadius, isFalse);
      expect(state.itemDividerWidth, 1);
      expect(state.itemDividerLength, 80);
      expect(state.itemDividerColor, 0);
    });
  });

  group('持久化往返与钳制', () {
    test('加载已存值（含越界钳制）', () async {
      final container = await containerWith(<String, Object>{
        PrefKeys.overrideBaseCardCornerRadius: true,
        PrefKeys.baseCardCornerRadius: 0,
        PrefKeys.overrideBaseCardBorder: true,
        PrefKeys.baseCardBorderWidth: 3,
        PrefKeys.baseCardBorderColor: 0xFF112233,
        PrefKeys.baseCardBorderColorNight: 0xFF445566,
        PrefKeys.disableSplicedColumnGroupCornerRadius: true,
        PrefKeys.enableItemDivider: true,
        PrefKeys.itemDividerWidth: 2,
        PrefKeys.itemDividerLength: 65,
        PrefKeys.itemDividerColor: 0xFF778899,
      });
      final state = container.read(uiSettingsProvider);
      expect(state.overrideBaseCardCornerRadius, isTrue);
      expect(state.baseCardCornerRadius, 0);
      expect(state.overrideBaseCardBorder, isTrue);
      expect(state.baseCardBorderWidth, 3);
      expect(state.baseCardBorderColor, 0xFF112233);
      expect(state.baseCardBorderColorNight, 0xFF445566);
      expect(state.disableSplicedColumnGroupCornerRadius, isTrue);
      expect(state.enableItemDivider, isTrue);
      expect(state.itemDividerWidth, 2);
      expect(state.itemDividerLength, 65);
      expect(state.itemDividerColor, 0xFF778899);

      final clamped = await containerWith(<String, Object>{
        PrefKeys.baseCardCornerRadius: 99,
        PrefKeys.baseCardBorderWidth: 9,
        PrefKeys.itemDividerWidth: -2,
        PrefKeys.itemDividerLength: 10,
      });
      final clampedState = clamped.read(uiSettingsProvider);
      expect(clampedState.baseCardCornerRadius, 40);
      expect(clampedState.baseCardBorderWidth, 5);
      expect(clampedState.itemDividerWidth, 0);
      expect(clampedState.itemDividerLength, 30);

      final clampedHigh = await containerWith(<String, Object>{
        PrefKeys.baseCardCornerRadius: -5,
        PrefKeys.itemDividerLength: 200,
      });
      final highState = clampedHigh.read(uiSettingsProvider);
      expect(highState.baseCardCornerRadius, 0);
      expect(highState.itemDividerLength, 100);
    });

    test('setter 落盘、钳制并推送监听通道', () async {
      final container = await containerWith(<String, Object>{});
      final notifier = container.read(uiSettingsProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      await notifier.setOverrideBaseCardBorder(true);
      await notifier.setBaseCardBorderWidth(4);
      await notifier.setBaseCardBorderColor(0xFFFF0000);
      await notifier.setBaseCardBorderColorNight(0xFF00FF00);
      await notifier.setDisableSplicedColumnGroupCornerRadius(true);
      await notifier.setItemDividerWidth(3);
      await notifier.setItemDividerLength(55);
      await notifier.setItemDividerColor(0xFF0000FF);

      expect(prefs.getBool(PrefKeys.overrideBaseCardBorder), isTrue);
      expect(prefs.getInt(PrefKeys.baseCardBorderWidth), 4);
      expect(prefs.getInt(PrefKeys.baseCardBorderColor), 0xFFFF0000);
      expect(prefs.getInt(PrefKeys.baseCardBorderColorNight), 0xFF00FF00);
      expect(
        prefs.getBool(PrefKeys.disableSplicedColumnGroupCornerRadius),
        isTrue,
      );
      expect(prefs.getInt(PrefKeys.itemDividerWidth), 3);
      expect(prefs.getInt(PrefKeys.itemDividerLength), 55);
      expect(prefs.getInt(PrefKeys.itemDividerColor), 0xFF0000FF);
      expect(uiSettingsListenable.value.overrideBaseCardBorder, isTrue);
      expect(uiSettingsListenable.value.itemDividerLength, 55);

      // 越界 setter 同样钳制
      await notifier.setBaseCardBorderWidth(99);
      await notifier.setItemDividerWidth(-1);
      await notifier.setItemDividerLength(999);
      await notifier.setBaseCardCornerRadius(-5);
      expect(prefs.getInt(PrefKeys.baseCardBorderWidth), 5);
      expect(prefs.getInt(PrefKeys.itemDividerWidth), 0);
      expect(prefs.getInt(PrefKeys.itemDividerLength), 100);
      expect(prefs.getInt(PrefKeys.baseCardCornerRadius), 0);
    });
  });

  group('解析器（参考版语义）', () {
    test('分组圆角优先级：disable > override > 16dp', () {
      expect(resolveSplicedGroupCornerRadius(const UiSettingsState()), 16);
      expect(
        resolveSplicedGroupCornerRadius(
          const UiSettingsState(
            overrideBaseCardCornerRadius: true,
            baseCardCornerRadius: 24,
          ),
        ),
        24,
      );
      expect(
        resolveSplicedGroupCornerRadius(
          const UiSettingsState(
            overrideBaseCardCornerRadius: true,
            baseCardCornerRadius: 24,
            disableSplicedColumnGroupCornerRadius: true,
          ),
        ),
        0,
        reason: 'disable 必须优先于 override（参考 SplicedColumnGroup.kt:50-53）',
      );
      expect(
        resolveSplicedGroupCornerRadius(
          const UiSettingsState(
            overrideBaseCardCornerRadius: true,
            baseCardCornerRadius: 0,
          ),
        ),
        0,
      );
    });

    test('全局 CardTheme 圆角：override → base，否则 20；disable 不影响', () {
      expect(resolveCardThemeCornerRadius(const UiSettingsState()), 20);
      expect(
        resolveCardThemeCornerRadius(
          const UiSettingsState(
            overrideBaseCardCornerRadius: true,
            baseCardCornerRadius: 12,
          ),
        ),
        12,
      );
      expect(
        resolveCardThemeCornerRadius(
          const UiSettingsState(disableSplicedColumnGroupCornerRadius: true),
        ),
        20,
        reason: 'disable 只作用于拼接分组（参考版同一链只在 SplicedColumnGroup）',
      );
    });

    test('边框：开关关/宽度 0 → null；0 色回落 outlineVariant', () {
      expect(
        resolveBaseCardBorderSide(
          const UiSettingsState(),
          _lightScheme,
          brightness: Brightness.light,
        ),
        isNull,
      );
      expect(
        resolveBaseCardBorderSide(
          const UiSettingsState(
            overrideBaseCardBorder: true,
            baseCardBorderWidth: 0,
          ),
          _lightScheme,
          brightness: Brightness.light,
        ),
        isNull,
      );

      final fallback = resolveBaseCardBorderSide(
        const UiSettingsState(
          overrideBaseCardBorder: true,
          baseCardBorderWidth: 2,
        ),
        _lightScheme,
        brightness: Brightness.light,
      )!;
      expect(fallback.width, 2);
      expect(fallback.color, _lightScheme.outlineVariant);

      final day = resolveBaseCardBorderSide(
        const UiSettingsState(
          overrideBaseCardBorder: true,
          baseCardBorderWidth: 1,
          baseCardBorderColor: 0xFF112233,
          baseCardBorderColorNight: 0xFF445566,
        ),
        _lightScheme,
        brightness: Brightness.light,
      )!;
      expect(day.color, const Color(0xFF112233));

      final night = resolveBaseCardBorderSide(
        const UiSettingsState(
          overrideBaseCardBorder: true,
          baseCardBorderWidth: 1,
          baseCardBorderColor: 0xFF112233,
          baseCardBorderColorNight: 0xFF445566,
        ),
        _darkScheme,
        brightness: Brightness.dark,
      )!;
      expect(night.color, const Color(0xFF445566));
      expect(night.color, isNot(_darkScheme.outlineVariant));
    });

    test('分隔线长度是可用宽度的百分比，不是 dp', () {
      expect(resolveItemDividerWidthFraction(80), closeTo(0.8, 0.0001));
      expect(resolveItemDividerWidthFraction(30), closeTo(0.3, 0.0001));
      expect(resolveItemDividerWidthFraction(100), 1.0);
      expect(resolveItemDividerWidthFraction(999), 1.0);
      expect(resolveItemDividerWidthFraction(-1), 0.0);
      expect(resolveItemDividerLength(80, 320), closeTo(256, 0.0001));
      expect(resolveItemDividerLength(50, 200), closeTo(100, 0.0001));
    });

    test('分隔线颜色：0 色回落灰色 30%，非 0 原样', () {
      final fallback = resolveItemDividerColor(0);
      expect(fallback.a, closeTo(0.3, 0.001));
      expect(fallback.r, closeTo(0x88 / 255, 0.001));
      expect(fallback.g, closeTo(0x88 / 255, 0.001));
      expect(fallback.b, closeTo(0x88 / 255, 0.001));
      expect(resolveItemDividerColor(0xFFFF0000), const Color(0xFFFF0000));
    });
  });

  group('备份白名单/忽略组', () {
    test('新键默认进备份', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.overrideBaseCardBorder: true,
        PrefKeys.baseCardBorderWidth: 2,
        PrefKeys.baseCardBorderColor: 0xFF112233,
        PrefKeys.baseCardBorderColorNight: 0xFF445566,
        PrefKeys.disableSplicedColumnGroupCornerRadius: true,
        PrefKeys.itemDividerWidth: 3,
        PrefKeys.itemDividerLength: 55,
        PrefKeys.itemDividerColor: 0xFF778899,
      });
      final out = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(out[PrefKeys.overrideBaseCardBorder], isTrue);
      expect(out[PrefKeys.baseCardBorderWidth], 2);
      expect(out[PrefKeys.baseCardBorderColor], 0xFF112233);
      expect(out[PrefKeys.baseCardBorderColorNight], 0xFF445566);
      expect(out[PrefKeys.disableSplicedColumnGroupCornerRadius], isTrue);
      expect(out[PrefKeys.itemDividerWidth], 3);
      expect(out[PrefKeys.itemDividerLength], 55);
      expect(out[PrefKeys.itemDividerColor], 0xFF778899);
    });

    test('新键不在参考版 themePrefKeys / readPrefKeys → 忽略主题/阅读仍往返', () {
      const keys = <String>[
        PrefKeys.overrideBaseCardBorder,
        PrefKeys.baseCardBorderWidth,
        PrefKeys.baseCardBorderColor,
        PrefKeys.baseCardBorderColorNight,
        PrefKeys.disableSplicedColumnGroupCornerRadius,
        PrefKeys.itemDividerWidth,
        PrefKeys.itemDividerLength,
        PrefKeys.itemDividerColor,
        PrefKeys.overrideBaseCardCornerRadius,
        PrefKeys.baseCardCornerRadius,
        PrefKeys.enableItemDivider,
      ];
      for (final key in keys) {
        expect(
          RestoreIgnorePrefs.keyIsNotIgnore(key, const {'themeConfig': true}),
          isTrue,
          reason: '$key 未列入参考版 BackupConfig.themePrefKeys（应始终往返）',
        );
        expect(
          RestoreIgnorePrefs.keyIsNotIgnore(key, const {'readConfig': true}),
          isTrue,
        );
      }
    });
  });

  group('恢复同会话生效', () {
    test('applyFromBackup 写入后 reload 立即反映到状态', () async {
      final container = await containerWith(<String, Object>{});
      await RestoreIgnorePrefs.applyFromBackup(<String, dynamic>{
        PrefKeys.overrideBaseCardCornerRadius: true,
        PrefKeys.baseCardCornerRadius: 8,
        PrefKeys.overrideBaseCardBorder: true,
        PrefKeys.baseCardBorderWidth: 2,
        PrefKeys.baseCardBorderColor: 0xFF123456,
        PrefKeys.disableSplicedColumnGroupCornerRadius: true,
        PrefKeys.enableItemDivider: true,
        PrefKeys.itemDividerWidth: 2,
        PrefKeys.itemDividerLength: 60,
        PrefKeys.itemDividerColor: 0xFF654321,
      }, const {});
      await container.read(uiSettingsProvider.notifier).reload();

      final state = container.read(uiSettingsProvider);
      expect(state.overrideBaseCardCornerRadius, isTrue);
      expect(state.baseCardCornerRadius, 8);
      expect(state.overrideBaseCardBorder, isTrue);
      expect(state.baseCardBorderWidth, 2);
      expect(state.baseCardBorderColor, 0xFF123456);
      expect(state.disableSplicedColumnGroupCornerRadius, isTrue);
      expect(state.enableItemDivider, isTrue);
      expect(state.itemDividerWidth, 2);
      expect(state.itemDividerLength, 60);
      expect(state.itemDividerColor, 0xFF654321);

      // 监听通道同步（IosGroup/AppTheme 立即可见）
      expect(uiSettingsListenable.value.baseCardBorderWidth, 2);
      expect(uiSettingsListenable.value.itemDividerLength, 60);
    });
  });
}
