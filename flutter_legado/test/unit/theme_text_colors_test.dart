// [批13 | 2026-11-10] App 主题 12 色槽（主要/次要字体色）单测 — 全栈工程师 + UI
//
// 覆盖任务书测试项：
// - 键名逐字对齐参考版 PreferKey.kt:258-267（含 secondaryText 历史键名
//   colorMD3OnPrimaryContainer）；
// - 默认值（未设置 → 0xFF1C1B1F/0xFF49454F）；
// - 夜间 0 逐字段继承日间；日间 0 回落默认常量；
// - 清除（设值 → 恢复默认 → 0，偏好键移除）；
// - 旧 JSON/旧 themeConfigList 缺字段按 0 处理不抛异常；
// - 备份 themePrefKeys 收录 4 新键并受「忽略主题配置」过滤；
// - AppTheme.palette 把字体色接入 ColorScheme 且未设置时不改变既有 role。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/theme_colors_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

const _dayPrimary = 0xFF112233;
const _daySecondary = 0xFF445566;
const _nightPrimary = 0xFF778899;
const _nightSecondary = 0xFFAABBCC;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> loadedContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(themeColorsProvider);
    await pumpEventQueue();
    return container;
  }

  group('偏好键与默认值', () {
    test('键名逐字对齐参考版 PreferKey.kt:258-267', () {
      expect(PrefKeys.cPrimaryText, 'colorMD3OnSurface');
      expect(PrefKeys.cSecondaryText, 'colorMD3OnPrimaryContainer');
      expect(PrefKeys.cNPrimaryText, 'colorMD3OnSurfaceNight');
      expect(PrefKeys.cNSecondaryText, 'colorMD3OnPrimaryContainerNight');
    });

    test('未设置时 effective 回落默认常量（日夜一致）', () {
      const state = ThemeColorsState();
      expect(ThemeColorsState.defaultPrimaryTextColor, 0xFF1C1B1F);
      expect(ThemeColorsState.defaultSecondaryTextColor, 0xFF49454F);
      for (final brightness in Brightness.values) {
        expect(
          state.effectivePrimaryTextColor(brightness),
          ThemeColorsState.defaultPrimaryTextColor,
        );
        expect(
          state.effectiveSecondaryTextColor(brightness),
          ThemeColorsState.defaultSecondaryTextColor,
        );
        // 未设置时 nullable 解析必须为 null：接入 ColorScheme 时不覆盖
        // 内置 palette role，既有视觉不变
        expect(state.primaryTextColorFor(brightness), isNull);
        expect(state.secondaryTextColorFor(brightness), isNull);
      }
    });
  });

  group('夜间继承与日间回落', () {
    test('夜间 0 逐字段继承日间', () {
      const state = ThemeColorsState(
        primaryTextColor: _dayPrimary,
        secondaryTextColor: _daySecondary,
      );
      expect(state.effectivePrimaryTextColor(Brightness.light), _dayPrimary);
      expect(
        state.effectiveSecondaryTextColor(Brightness.light),
        _daySecondary,
      );
      // 夜间两个槽位都是 0 → 各自继承日间（不是整组共用）
      expect(state.effectivePrimaryTextColor(Brightness.dark), _dayPrimary);
      expect(state.effectiveSecondaryTextColor(Brightness.dark), _daySecondary);
    });

    test('仅夜间设置时，日间回落默认常量', () {
      const state = ThemeColorsState(
        primaryTextColorNight: _nightPrimary,
        secondaryTextColorNight: _nightSecondary,
      );
      expect(
        state.effectivePrimaryTextColor(Brightness.light),
        ThemeColorsState.defaultPrimaryTextColor,
      );
      expect(
        state.effectiveSecondaryTextColor(Brightness.light),
        ThemeColorsState.defaultSecondaryTextColor,
      );
      expect(state.effectivePrimaryTextColor(Brightness.dark), _nightPrimary);
      expect(
        state.effectiveSecondaryTextColor(Brightness.dark),
        _nightSecondary,
      );
    });

    test('逐字段继承：只设夜间主要字体色，夜间次要字体色仍继承日间', () {
      const state = ThemeColorsState(
        primaryTextColor: _dayPrimary,
        secondaryTextColor: _daySecondary,
        primaryTextColorNight: _nightPrimary,
      );
      expect(state.effectivePrimaryTextColor(Brightness.dark), _nightPrimary);
      expect(state.effectiveSecondaryTextColor(Brightness.dark), _daySecondary);
      // 日间不受夜间值影响
      expect(state.effectivePrimaryTextColor(Brightness.light), _dayPrimary);
    });
  });

  group('Notifier 读写与清除', () {
    test('设值写偏好，恢复默认清除并回落默认常量', () async {
      final container = await loadedContainer();
      final notifier = container.read(themeColorsProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      await notifier.setColor(PrefKeys.cPrimaryText, 0xFF2196F3);
      expect(
        container.read(themeColorsProvider).primaryTextColor,
        0xFF2196F3,
        reason: '状态必须反映已选字体色',
      );
      expect(prefs.getInt(PrefKeys.cPrimaryText), 0xFF2196F3);

      await notifier.setColor(PrefKeys.cPrimaryText, null);
      final cleared = container.read(themeColorsProvider);
      expect(cleared.primaryTextColor, 0, reason: '0 = 未设置');
      expect(prefs.containsKey(PrefKeys.cPrimaryText), isFalse);
      expect(
        cleared.effectivePrimaryTextColor(Brightness.light),
        ThemeColorsState.defaultPrimaryTextColor,
      );

      // 显式传 0 同样按清除处理（参考版重置写透明 #00000000）
      await notifier.setColor(PrefKeys.cSecondaryText, 0xFF00AA55);
      await notifier.setColor(PrefKeys.cSecondaryText, 0);
      expect(container.read(themeColorsProvider).secondaryTextColor, 0);
      expect(prefs.containsKey(PrefKeys.cSecondaryText), isFalse);
    });

    test('启动加载 4 个新键（含夜间）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.cPrimaryText: _dayPrimary,
        PrefKeys.cSecondaryText: _daySecondary,
        PrefKeys.cNPrimaryText: _nightPrimary,
        PrefKeys.cNSecondaryText: _nightSecondary,
      });
      final container = await loadedContainer();
      final state = container.read(themeColorsProvider);
      expect(state.primaryTextColor, _dayPrimary);
      expect(state.secondaryTextColor, _daySecondary);
      expect(state.primaryTextColorNight, _nightPrimary);
      expect(state.secondaryTextColorNight, _nightSecondary);
      expect(state.effectivePrimaryTextColor(Brightness.dark), _nightPrimary);
    });

    test('旧数据无字体色字段：加载为 0，applyColors 不崩', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.cPrimary: 0xFF010203,
      });
      final container = await loadedContainer();
      final notifier = container.read(themeColorsProvider.notifier);
      expect(container.read(themeColorsProvider).primaryTextColor, 0);

      // 模拟旧 themeConfigList 条目/旧导入 JSON：只含 4 个历史颜色键
      await notifier.applyColors(<String, int?>{
        PrefKeys.cPrimary: 0xFF112233,
        PrefKeys.cNPrimary: 0xFF332211,
      });
      final state = container.read(themeColorsProvider);
      expect(state.primary, 0xFF112233);
      expect(state.primaryNight, 0xFF332211);
      expect(state.primaryTextColor, 0);
      expect(state.secondaryTextColor, 0);
      expect(state.primaryTextColorNight, 0);
      expect(state.secondaryTextColorNight, 0);
    });

    test('withValue 对字体色 null 归一化为 0，且不污染其它槽位', () {
      const state = ThemeColorsState(
        primaryTextColor: _dayPrimary,
        secondaryTextColor: _daySecondary,
      );
      final next = state.withValue(PrefKeys.cPrimaryText, null);
      expect(next.primaryTextColor, 0);
      expect(next.secondaryTextColor, _daySecondary);
      expect(next.withBgImage(day: '/tmp/a.png').primaryTextColor, 0);
    });

    test('valueOf 返回 0（未设置）与已选值', () {
      const state = ThemeColorsState(
        primaryTextColor: _dayPrimary,
        primaryTextColorNight: _nightPrimary,
      );
      expect(state.valueOf(PrefKeys.cPrimaryText), _dayPrimary);
      expect(state.valueOf(PrefKeys.cSecondaryText), 0);
      expect(state.valueOf(PrefKeys.cNPrimaryText), _nightPrimary);
      expect(state.valueOf(PrefKeys.cNSecondaryText), 0);
    });
  });

  group('备份键清单', () {
    test('themePrefKeys 收录 4 新键并受「忽略主题配置」过滤', () {
      const keys = <String>[
        PrefKeys.cPrimaryText,
        PrefKeys.cSecondaryText,
        PrefKeys.cNPrimaryText,
        PrefKeys.cNSecondaryText,
      ];
      for (final key in keys) {
        expect(
          RestoreIgnorePrefs.themePrefKeys,
          contains(key),
          reason: '$key 应归入主题配置组（参考版 BackupConfig.kt:303-307）',
        );
        expect(
          RestoreIgnorePrefs.keyIsNotIgnore(key, const {'themeConfig': true}),
          isFalse,
          reason: '$key 勾选「忽略主题配置」时不得恢复',
        );
        expect(
          RestoreIgnorePrefs.keyIsNotIgnore(key, const <String, bool>{}),
          isTrue,
          reason: '$key 默认应随备份往返',
        );
      }
    });
  });

  group('AppTheme ColorScheme 接入', () {
    test('未设置时完全保留内置 palette role（既有视觉不变）', () {
      final baseLight = md3LightScheme(Md3Palettes.def);
      final baseDark = md3DarkScheme(Md3Palettes.def);

      final light = AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.def,
      );
      final dark = AppTheme.palette(
        brightness: Brightness.dark,
        palette: Md3Palettes.def,
      );

      expect(light.colorScheme.onSurface, baseLight.onSurface);
      expect(light.colorScheme.onPrimary, baseLight.onPrimary);
      expect(light.colorScheme.onSurfaceVariant, baseLight.onSurfaceVariant);
      expect(dark.colorScheme.onSurface, baseDark.onSurface);
      expect(dark.colorScheme.onSurfaceVariant, baseDark.onSurfaceVariant);
      // 与生产入口 AppTheme.light/dark 一致
      expect(AppTheme.light.colorScheme.onSurface, baseLight.onSurface);
      expect(
        AppTheme.dark.colorScheme.onSurfaceVariant,
        baseDark.onSurfaceVariant,
      );
    });

    test('主要字体色映射 onSurface/onPrimary/onPrimaryContainer', () {
      const fontColor = Color(0xFF112233);
      final theme = AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.def,
        primaryTextColor: fontColor,
      );
      expect(theme.colorScheme.onSurface, fontColor);
      expect(theme.colorScheme.onPrimary, fontColor);
      expect(theme.colorScheme.onPrimaryContainer, fontColor);
      // 未设次要字体色 → onSurfaceVariant 保持内置 role
      expect(
        theme.colorScheme.onSurfaceVariant,
        md3LightScheme(Md3Palettes.def).onSurfaceVariant,
      );
    });

    test(
      '次要字体色映射 onSurfaceVariant/onSecondary/onSecondaryContainer/onTertiary',
      () {
        const fontColor = Color(0xFF445566);
        final dark = AppTheme.palette(
          brightness: Brightness.dark,
          palette: Md3Palettes.def,
          secondaryTextColor: fontColor,
        );
        expect(dark.colorScheme.onSurfaceVariant, fontColor);
        expect(dark.colorScheme.onSecondary, fontColor);
        expect(dark.colorScheme.onSecondaryContainer, fontColor);
        expect(dark.colorScheme.onTertiary, fontColor);
        expect(
          dark.colorScheme.onSurface,
          md3DarkScheme(Md3Palettes.def).onSurface,
        );
      },
    );

    test('字体色优先于强调色派生的 onPrimary 对比色', () {
      const fontColor = Color(0xFF112233);
      final theme = AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.def,
        accent: const Color(0xFF00FF00),
        primaryTextColor: fontColor,
      );
      expect(theme.colorScheme.onPrimary, fontColor);
      expect(theme.colorScheme.primary, const Color(0xFF00FF00));
    });
  });
}
