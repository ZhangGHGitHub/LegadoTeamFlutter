// [设置批2b-1a | 2026-11-01] 容器外观偏好单测 — 全栈工程师
//
// 覆盖（任务书测试项）：键名逐字对齐参考版 PreferKey、默认值/范围钳制、
// 持久化往返、清除、备份白名单与「忽略主题配置」分组口径、恢复同会话重读。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    uiSettingsListenable.value = const UiSettingsState();
    ThemeBackgroundImageStore.resetWarmCache();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
    ThemeBackgroundImageStore.resetWarmCache();
  });

  Future<ProviderContainer> containerWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 等待 build() 的 microtask 加载并显式重读一次（确定性）
    await container.read(uiSettingsProvider.notifier).reload();
    return container;
  }

  group('键名与默认值', () {
    test('键名逐字对齐参考版 PreferKey.kt', () {
      expect(PrefKeys.containerOpacity, 'containerOpacity');
      expect(
        PrefKeys.largeContainerBackgroundImageLight,
        'largeContainerBackgroundImageLight',
      );
      expect(
        PrefKeys.largeContainerBackgroundImageDark,
        'largeContainerBackgroundImageDark',
      );
      expect(PrefKeys.bgImageBlurring, 'backgroundImageBlurring');
      expect(PrefKeys.bgImageNBlurring, 'backgroundImageNightBlurring');
    });

    test('UiSettingsState 默认：不透明度 100、虚化 0、无容器背景图', () {
      const state = UiSettingsState();
      expect(state.containerOpacity, 100);
      expect(state.bgImageBlurring, 0);
      expect(state.bgImageDarkBlurring, 0);
      expect(state.largeContainerBackgroundImageLight, isEmpty);
      expect(state.largeContainerBackgroundImageDark, isEmpty);
    });

    test('空存储加载后保持默认值', () async {
      final container = await containerWith(<String, Object>{});
      final state = container.read(uiSettingsProvider);
      expect(state.containerOpacity, 100);
      expect(state.bgImageBlurring, 0);
      expect(state.bgImageDarkBlurring, 0);
      expect(state.largeContainerBackgroundImageLight, isEmpty);
      expect(state.largeContainerBackgroundImageDark, isEmpty);
    });
  });

  group('持久化往返与钳制', () {
    test('加载已存值（含越界钳制到 0..100）', () async {
      final container = await containerWith(<String, Object>{
        PrefKeys.containerOpacity: 40,
        PrefKeys.bgImageBlurring: 12,
        PrefKeys.bgImageNBlurring: 34,
        PrefKeys.largeContainerBackgroundImageLight:
            'theme_backgrounds/large_light/a.png',
        PrefKeys.largeContainerBackgroundImageDark:
            'theme_backgrounds/large_dark/b.png',
      });
      final state = container.read(uiSettingsProvider);
      expect(state.containerOpacity, 40);
      expect(state.bgImageBlurring, 12);
      expect(state.bgImageDarkBlurring, 34);
      expect(
        state.largeContainerBackgroundImageLight,
        'theme_backgrounds/large_light/a.png',
      );
      expect(
        state.largeContainerBackgroundImageDark,
        'theme_backgrounds/large_dark/b.png',
      );

      final clamped = await containerWith(<String, Object>{
        PrefKeys.containerOpacity: 150,
        PrefKeys.bgImageBlurring: -5,
        PrefKeys.bgImageNBlurring: 999,
      });
      final clampedState = clamped.read(uiSettingsProvider);
      expect(clampedState.containerOpacity, 100);
      expect(clampedState.bgImageBlurring, 0);
      expect(clampedState.bgImageDarkBlurring, 100);
    });

    test('setter 落盘并推送监听通道', () async {
      final container = await containerWith(<String, Object>{});
      final notifier = container.read(uiSettingsProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      await notifier.setContainerOpacity(35);
      expect(prefs.getInt(PrefKeys.containerOpacity), 35);
      expect(uiSettingsListenable.value.containerOpacity, 35);

      await notifier.setBgImageBlurring(night: false, value: 18);
      await notifier.setBgImageBlurring(night: true, value: 26);
      expect(prefs.getInt(PrefKeys.bgImageBlurring), 18);
      expect(prefs.getInt(PrefKeys.bgImageNBlurring), 26);
      expect(uiSettingsListenable.value.bgImageBlurring, 18);
      expect(uiSettingsListenable.value.bgImageDarkBlurring, 26);

      await notifier.setLargeContainerBackgroundImage(
        night: false,
        storedPath: 'theme_backgrounds/large_light/d.png',
      );
      await notifier.setLargeContainerBackgroundImage(
        night: true,
        storedPath: 'theme_backgrounds/large_dark/e.png',
      );
      expect(
        prefs.getString(PrefKeys.largeContainerBackgroundImageLight),
        'theme_backgrounds/large_light/d.png',
      );
      expect(
        prefs.getString(PrefKeys.largeContainerBackgroundImageDark),
        'theme_backgrounds/large_dark/e.png',
      );

      // 越界 setter 同样钳制
      await notifier.setContainerOpacity(1000);
      expect(prefs.getInt(PrefKeys.containerOpacity), 100);
      await notifier.setBgImageBlurring(night: false, value: -3);
      expect(prefs.getInt(PrefKeys.bgImageBlurring), 0);
    });

    test('清除容器背景图移除偏好键并同步状态', () async {
      final container = await containerWith(<String, Object>{
        PrefKeys.largeContainerBackgroundImageLight:
            'theme_backgrounds/large_light/a.png',
      });
      final notifier = container.read(uiSettingsProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      await notifier.setLargeContainerBackgroundImage(
        night: false,
        storedPath: '',
      );
      expect(
        prefs.containsKey(PrefKeys.largeContainerBackgroundImageLight),
        isFalse,
      );
      expect(
        container.read(uiSettingsProvider).largeContainerBackgroundImageLight,
        isEmpty,
      );
    });
  });

  group('备份白名单/忽略组（对齐参考版 BackupConfig.themePrefKeys）', () {
    test('三个主题键默认进备份', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.containerOpacity: 40,
        PrefKeys.bgImageBlurring: 12,
        PrefKeys.bgImageNBlurring: 34,
        PrefKeys.largeContainerBackgroundImageLight:
            'theme_backgrounds/large_light/a.png',
        PrefKeys.largeContainerBackgroundImageDark:
            'theme_backgrounds/large_dark/b.png',
      });
      final out = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(out[PrefKeys.containerOpacity], 40);
      expect(out[PrefKeys.bgImageBlurring], 12);
      expect(out[PrefKeys.bgImageNBlurring], 34);
      expect(
        out[PrefKeys.largeContainerBackgroundImageLight],
        'theme_backgrounds/large_light/a.png',
      );
      expect(
        out[PrefKeys.largeContainerBackgroundImageDark],
        'theme_backgrounds/large_dark/b.png',
      );
    });

    test('忽略主题配置：不透明度/虚化被过滤，容器背景图键仍往返', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PrefKeys.containerOpacity: 40,
        PrefKeys.bgImageBlurring: 12,
        PrefKeys.bgImageNBlurring: 34,
        PrefKeys.largeContainerBackgroundImageLight:
            'theme_backgrounds/large_light/a.png',
      });
      final out = await RestoreIgnorePrefs.collectForBackup(
        const {'themeConfig': true},
      );
      // 参考版 themePrefKeys 含 containerOpacity / bgImageBlurring / bgImageNBlurring
      expect(out.containsKey(PrefKeys.containerOpacity), isFalse);
      expect(out.containsKey(PrefKeys.bgImageBlurring), isFalse);
      expect(out.containsKey(PrefKeys.bgImageNBlurring), isFalse);
      // 参考版 themePrefKeys 不含 largeContainerBackgroundImage* → 始终往返
      expect(
        out[PrefKeys.largeContainerBackgroundImageLight],
        'theme_backgrounds/large_light/a.png',
      );
    });

    test('旧字面量 bgImageBlurring 不再是有效过滤键（修正为真实键名）', () {
      // 旧实现误把参考版常量名当键名；真实键应被过滤
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'backgroundImageBlurring',
          const {'themeConfig': true},
        ),
        isFalse,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          'bgImageBlurring',
          const {'themeConfig': true},
        ),
        isTrue,
      );
    });
  });

  group('恢复同会话生效', () {
    test('applyFromBackup 写入后 reload 立即反映到状态', () async {
      final container = await containerWith(<String, Object>{});
      await RestoreIgnorePrefs.applyFromBackup(
        <String, dynamic>{
          PrefKeys.containerOpacity: 22,
          PrefKeys.bgImageBlurring: 45,
          PrefKeys.bgImageNBlurring: 55,
          PrefKeys.largeContainerBackgroundImageLight:
              'theme_backgrounds/large_light/restored.png',
        },
        const {},
      );
      // 恢复只写 prefs；模拟 _reloadPrefsAfterRestore 的重读
      await container.read(uiSettingsProvider.notifier).reload();

      final state = container.read(uiSettingsProvider);
      expect(state.containerOpacity, 22);
      expect(state.bgImageBlurring, 45);
      expect(state.bgImageDarkBlurring, 55);
      expect(
        state.largeContainerBackgroundImageLight,
        'theme_backgrounds/large_light/restored.png',
      );
      expect(uiSettingsListenable.value.containerOpacity, 22);
    });

    test('忽略主题配置恢复时不覆盖本机不透明度/虚化', () async {
      final container = await containerWith(<String, Object>{
        PrefKeys.containerOpacity: 80,
        PrefKeys.bgImageBlurring: 5,
      });
      await RestoreIgnorePrefs.applyFromBackup(
        <String, dynamic>{
          PrefKeys.containerOpacity: 10,
          PrefKeys.bgImageBlurring: 90,
          PrefKeys.largeContainerBackgroundImageLight:
              'theme_backgrounds/large_light/from-backup.png',
        },
        const {'themeConfig': true},
      );
      await container.read(uiSettingsProvider.notifier).reload();

      final state = container.read(uiSettingsProvider);
      expect(state.containerOpacity, 80);
      expect(state.bgImageBlurring, 5);
      // 容器背景图键不在主题忽略组 → 恢复
      expect(
        state.largeContainerBackgroundImageLight,
        'theme_backgrounds/large_light/from-backup.png',
      );
    });
  });
}
