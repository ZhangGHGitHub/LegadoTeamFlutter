// ThemeProvider 单元测试
//
// 验证 Phase 4.5 主题切换 + 全局字体缩放状态管理：
// - 主题模式（亮/暗/跟随系统）的加载、设置、持久化与通知
// - 全局字体缩放（对齐原版 PreferKey.fontScale：0=跟随系统，8~16→0.8x~1.6x）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/theme_provider.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = ThemeProvider();
  });

  group('ThemeProvider 初始状态', () {
    test('默认主题模式为 system', () {
      expect(provider.themeMode, ThemeMode.system);
    });

    test('默认字体缩放原始值为 0（跟随系统）', () {
      expect(provider.fontScaleRaw, equals(0));
      expect(provider.isSystemFontScale, isTrue);
      expect(provider.fontScale, isNull);
      expect(provider.fontScaleLabel, equals('跟随系统'));
    });
  });

  group('ThemeProvider 加载持久化设置', () {
    test('load 读取已保存的主题模式与字体缩放', () async {
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'app_font_scale': 12,
      });
      provider = ThemeProvider();
      await provider.load();

      expect(provider.themeMode, ThemeMode.dark);
      expect(provider.fontScaleRaw, equals(12));
      expect(provider.fontScale, equals(1.2));
    });

    test('load 无持久化值时回退默认', () async {
      await provider.load();
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.fontScaleRaw, equals(0));
    });
  });

  group('ThemeProvider 主题模式', () {
    test('setThemeMode 更新状态并持久化', () async {
      await provider.setThemeMode(ThemeMode.light);
      expect(provider.themeMode, ThemeMode.light);
      expect(await SettingsService().getThemeMode(), ThemeMode.light);
    });

    test('setThemeMode 触发通知', () async {
      var notified = 0;
      provider.addListener(() => notified++);
      await provider.setThemeMode(ThemeMode.dark);
      expect(notified, equals(1));
    });

    test('setThemeMode 相同值不触发通知', () async {
      var notified = 0;
      provider.addListener(() => notified++);
      await provider.setThemeMode(ThemeMode.system); // 与默认相同
      expect(notified, equals(0));
    });
  });

  group('ThemeProvider 字体缩放', () {
    test('setFontScale 更新状态并持久化', () async {
      await provider.setFontScale(14);
      expect(provider.fontScaleRaw, equals(14));
      expect(provider.fontScale, equals(1.4));
      expect(await SettingsService().getFontScale(), equals(14));
    });

    test('setFontScale 触发通知', () async {
      var notified = 0;
      provider.addListener(() => notified++);
      await provider.setFontScale(10);
      expect(notified, equals(1));
    });

    test('setFontScale(0) 重置为跟随系统', () async {
      await provider.setFontScale(12);
      await provider.setFontScale(0);
      expect(provider.isSystemFontScale, isTrue);
      expect(provider.fontScale, isNull);
      expect(provider.fontScaleLabel, equals('跟随系统'));
    });

    test('fontScale 边界值映射（8→0.8, 16→1.6）', () async {
      await provider.setFontScale(8);
      expect(provider.fontScale, equals(0.8));
      await provider.setFontScale(16);
      expect(provider.fontScale, equals(1.6));
    });

    test('fontScale 超出有效范围视为跟随系统', () async {
      await provider.setFontScale(7);
      expect(provider.fontScale, isNull);
      await provider.setFontScale(17);
      expect(provider.fontScale, isNull);
    });

    test('fontScaleLabel 展示当前倍数', () async {
      await provider.setFontScale(10);
      expect(provider.fontScaleLabel, equals('当前字体大小：1.0'));
      await provider.setFontScale(15);
      expect(provider.fontScaleLabel, equals('当前字体大小：1.5'));
    });
  });
}
