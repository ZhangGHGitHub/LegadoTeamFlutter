// [设置批2b-1b-2b | 2026-11-03] 项目（卡片）背景图偏好与全局卡片不透明度单测
// — 全栈工程师 + UI
//
// 覆盖任务书测试项：新键键名逐字对齐参考版 PreferKey、默认值/范围钳制、
// 持久化往返/清除、备份口径（不在 themePrefKeys，随 appPrefs 往返）、
// 恢复同会话重读、item_light/item_dark 槽位落盘（含 `.9.png` 双扩展名、
// 孤儿清理 keep 口径）、CardTheme 卡面 alpha（100/50/透明调色板不洗白）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/card_style.dart';

/// 1x1 透明 PNG（真实可解码）
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    uiSettingsListenable.value = const UiSettingsState();
    temp = await Directory.systemTemp.createTemp('legado_item_bg_');
    originalSupportDir = ThemeBackgroundImageStore.supportDir;
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
  });

  tearDown(() async {
    uiSettingsListenable.value = const UiSettingsState();
    ThemeBackgroundImageStore.supportDir = originalSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<ProviderContainer> containerWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(uiSettingsProvider.notifier).reload();
    return container;
  }

  group('键名与默认值', () {
    test('键名逐字对齐参考版 PreferKey.kt:272-276', () {
      expect(PrefKeys.itemBackgroundImageLight, 'itemBackgroundImageLight');
      expect(PrefKeys.itemBackgroundImageDark, 'itemBackgroundImageDark');
      expect(PrefKeys.glassCardBackgroundOpacity, 'glassCardBackgroundOpacity');
    });

    test('UiSettingsState 默认：项目图未设置、图片不透明度 100', () {
      const state = UiSettingsState();
      expect(state.itemBackgroundImageLight, isEmpty);
      expect(state.itemBackgroundImageDark, isEmpty);
      expect(state.glassCardBackgroundOpacity, 100);
    });

    test('空存储加载后保持默认值', () async {
      final state = (await containerWith(
        <String, Object>{},
      )).read(uiSettingsProvider);
      expect(state.itemBackgroundImageLight, isEmpty);
      expect(state.itemBackgroundImageDark, isEmpty);
      expect(state.glassCardBackgroundOpacity, 100);
    });
  });

  group('持久化往返与钳制', () {
    test('加载已存值（含 0..100 钳制）', () async {
      final container = await containerWith(<String, Object>{
        PrefKeys.itemBackgroundImageLight: 'theme_backgrounds/item_light/a.png',
        PrefKeys.itemBackgroundImageDark: 'theme_backgrounds/item_dark/b.png',
        PrefKeys.glassCardBackgroundOpacity: 35,
      });
      final state = container.read(uiSettingsProvider);
      expect(
        state.itemBackgroundImageLight,
        'theme_backgrounds/item_light/a.png',
      );
      expect(
        state.itemBackgroundImageDark,
        'theme_backgrounds/item_dark/b.png',
      );
      expect(state.glassCardBackgroundOpacity, 35);

      final clamped = await containerWith(<String, Object>{
        PrefKeys.glassCardBackgroundOpacity: 150,
      });
      expect(clamped.read(uiSettingsProvider).glassCardBackgroundOpacity, 100);
      final negative = await containerWith(<String, Object>{
        PrefKeys.glassCardBackgroundOpacity: -9,
      });
      expect(negative.read(uiSettingsProvider).glassCardBackgroundOpacity, 0);
    });

    test('setter 落盘并推送监听通道；选图不改变总开关', () async {
      final container = await containerWith(<String, Object>{});
      final notifier = container.read(uiSettingsProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      await notifier.setGlassCardBackgroundOpacity(40);
      expect(prefs.getInt(PrefKeys.glassCardBackgroundOpacity), 40);
      expect(uiSettingsListenable.value.glassCardBackgroundOpacity, 40);

      await notifier.setItemBackgroundImage(
        night: false,
        storedPath: 'theme_backgrounds/item_light/day.png',
      );
      await notifier.setItemBackgroundImage(
        night: true,
        storedPath: 'theme_backgrounds/item_dark/night.png',
      );
      expect(
        prefs.getString(PrefKeys.itemBackgroundImageLight),
        'theme_backgrounds/item_light/day.png',
      );
      expect(
        prefs.getString(PrefKeys.itemBackgroundImageDark),
        'theme_backgrounds/item_dark/night.png',
      );
      // 参考 setContainerBackground 只更新路径，不自动打开总开关
      expect(
        prefs.containsKey(PrefKeys.enableContainerBackgroundImage),
        isFalse,
      );
      expect(
        container.read(uiSettingsProvider).enableContainerBackgroundImage,
        isFalse,
      );

      // 越界 setter 同样钳制
      await notifier.setGlassCardBackgroundOpacity(1000);
      expect(prefs.getInt(PrefKeys.glassCardBackgroundOpacity), 100);
      await notifier.setGlassCardBackgroundOpacity(-8);
      expect(prefs.getInt(PrefKeys.glassCardBackgroundOpacity), 0);
    });

    test('清除项目图移除偏好键并同步状态', () async {
      final container = await containerWith(<String, Object>{
        PrefKeys.itemBackgroundImageLight: 'theme_backgrounds/item_light/a.png',
      });
      final notifier = container.read(uiSettingsProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      await notifier.setItemBackgroundImage(night: false, storedPath: '');
      expect(prefs.containsKey(PrefKeys.itemBackgroundImageLight), isFalse);
      expect(
        container.read(uiSettingsProvider).itemBackgroundImageLight,
        isEmpty,
      );
    });
  });

  group('备份口径（对齐参考版 BackupConfig.themePrefKeys）', () {
    test('新键默认进备份', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.itemBackgroundImageLight: 'theme_backgrounds/item_light/a.png',
        PrefKeys.itemBackgroundImageDark: 'theme_backgrounds/item_dark/b.png',
        PrefKeys.glassCardBackgroundOpacity: 55,
      });
      final out = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(
        out[PrefKeys.itemBackgroundImageLight],
        'theme_backgrounds/item_light/a.png',
      );
      expect(
        out[PrefKeys.itemBackgroundImageDark],
        'theme_backgrounds/item_dark/b.png',
      );
      expect(out[PrefKeys.glassCardBackgroundOpacity], 55);
    });

    test('忽略主题配置：项目图/图片不透明度仍往返（不在 themePrefKeys）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.itemBackgroundImageLight: 'theme_backgrounds/item_light/a.png',
        PrefKeys.glassCardBackgroundOpacity: 55,
      });
      final out = await RestoreIgnorePrefs.collectForBackup(const {
        'themeConfig': true,
      });
      expect(
        out[PrefKeys.itemBackgroundImageLight],
        'theme_backgrounds/item_light/a.png',
      );
      expect(out[PrefKeys.glassCardBackgroundOpacity], 55);
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.itemBackgroundImageLight,
          const {'themeConfig': true},
        ),
        isTrue,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.glassCardBackgroundOpacity,
          const {'themeConfig': true},
        ),
        isTrue,
      );
    });
  });

  group('恢复同会话生效', () {
    test('applyFromBackup 写入后 reload 立即反映到状态', () async {
      final container = await containerWith(<String, Object>{});
      await RestoreIgnorePrefs.applyFromBackup(<String, dynamic>{
        PrefKeys.itemBackgroundImageLight:
            'theme_backgrounds/item_light/restored.png',
        PrefKeys.glassCardBackgroundOpacity: 25,
      }, const {});
      await container.read(uiSettingsProvider.notifier).reload();

      final state = container.read(uiSettingsProvider);
      expect(
        state.itemBackgroundImageLight,
        'theme_backgrounds/item_light/restored.png',
      );
      expect(state.glassCardBackgroundOpacity, 25);
      expect(
        uiSettingsListenable.value.itemBackgroundImageLight,
        'theme_backgrounds/item_light/restored.png',
      );
      expect(uiSettingsListenable.value.glassCardBackgroundOpacity, 25);
    });
  });

  group('item_* 存储槽位', () {
    test('storeBytes 落盘 item_light/item_dark 相对标识', () async {
      final light = await ThemeBackgroundImageStore.storeBytes(
        _pngBytes,
        originalName: 'day.png',
        slot: ThemeBackgroundImageStore.itemLightSlot,
      );
      final dark = await ThemeBackgroundImageStore.storeBytes(
        _pngBytes,
        originalName: 'night.png',
        slot: ThemeBackgroundImageStore.itemDarkSlot,
      );
      expect(
        light,
        matches(RegExp(r'^theme_backgrounds/item_light/[0-9a-f]{32}\.png$')),
      );
      expect(
        dark,
        matches(RegExp(r'^theme_backgrounds/item_dark/[0-9a-f]{32}\.png$')),
      );
      expect(ThemeBackgroundImageStore.isUsableSync(light), isTrue);
      expect(ThemeBackgroundImageStore.isUsableSync(dark), isTrue);
    });

    test('`.9.png` 在 item 槽位保留双扩展名', () async {
      final stored = await ThemeBackgroundImageStore.storeBytes(
        _pngBytes,
        originalName: 'frame.9.png',
        slot: ThemeBackgroundImageStore.itemLightSlot,
      );
      expect(
        stored,
        matches(RegExp(r'^theme_backgrounds/item_light/[0-9a-f]{32}\.9\.png$')),
      );
      expect(ThemeBackgroundImageStore.isUsableSync(stored), isTrue);
    });

    test('cleanupOrphansSync 的 keep 含项目图时保留文件', () async {
      final keptItem = await ThemeBackgroundImageStore.storeBytes(
        _pngBytes,
        originalName: 'keep.png',
        slot: ThemeBackgroundImageStore.itemLightSlot,
      );
      final sep = Platform.pathSeparator;
      final itemDir = Directory(
        '${temp.path}$sep${ThemeBackgroundImageStore.subDir}'
        '${sep}item_light',
      );
      final orphan = File(
        '${itemDir.path}$sep${List<String>.filled(32, 'e').join()}.png',
      )..writeAsBytesSync(const <int>[1, 2, 3]);

      final removed = ThemeBackgroundImageStore.cleanupOrphansSync(
        keep: [keptItem],
      );
      expect(removed, 1, reason: '只清理未引用的自有项目图');
      expect(
        File(ThemeBackgroundImageStore.resolveSync(keptItem)).existsSync(),
        isTrue,
      );
      expect(orphan.existsSync(), isFalse);
    });
  });

  group('CardTheme 卡面 alpha（containerOpacity）', () {
    test('透明调色板乘原 alpha，不洗白', () {
      const transparent = Color(0x33FFFFFF);
      expect(resolveCardThemeColor(transparent, 100).a, closeTo(0.2, 0.001));
      expect(resolveCardThemeColor(transparent, 50).a, closeTo(0.1, 0.001));
      expect(resolveCardThemeColor(transparent, 0).a, 0.0);
      // 越界钳制
      expect(resolveCardThemeColor(transparent, 150).a, closeTo(0.2, 0.001));
      expect(resolveCardThemeColor(transparent, -1).a, 0.0);
    });

    test('AppTheme CardTheme：100% 保持原 role，50% 乘 alpha', () {
      uiSettingsListenable.value = const UiSettingsState();
      final light = AppTheme.light;
      expect(light.cardTheme.color, light.colorScheme.surfaceContainerLowest);
      final dark = AppTheme.dark;
      expect(dark.cardTheme.color, dark.colorScheme.surfaceContainerLow);

      uiSettingsListenable.value = const UiSettingsState(containerOpacity: 50);
      final light50 = AppTheme.light;
      expect(light50.cardTheme.color!.a, closeTo(0.5, 0.001));
      final dark50 = AppTheme.dark;
      expect(dark50.cardTheme.color!.a, closeTo(0.5, 0.001));

      uiSettingsListenable.value = const UiSettingsState(containerOpacity: 0);
      expect(AppTheme.light.cardTheme.color!.a, 0.0);
      expect(AppTheme.dark.cardTheme.color!.a, 0.0);
    });
  });
}
