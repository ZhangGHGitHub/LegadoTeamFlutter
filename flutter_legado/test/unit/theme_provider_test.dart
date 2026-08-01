// ThemeNotifier 单元测试
//
// 验证 Phase 5.4 provider→Riverpod 迁移后的主题切换 + 全局字体缩放状态管理：
// - 主题模式（亮/暗/跟随系统）的加载、设置、持久化与通知
// - 全局字体缩放（对齐原版 PreferKey.fontScale：0=跟随系统，8~16→0.8x~1.6x）
//
// 注意：ThemeNotifier.build() 会通过微任务自动加载持久化设置，
// 测试中先经 pumpInit() 等待自动加载完成，再执行动作与断言，避免加载覆盖动作结果。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  /// 等待 build() 微任务（启动加载）完成
  ///
  /// 须先读取 provider 触发 build()（调度加载微任务），再冲刷微任务；
  /// 若先冲刷后读取，build() 未触发、加载微任务不存在，状态将停留默认值。
  Future<void> pumpInit() async {
    container.read(themeNotifierProvider);
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  /// 在给定持久化初始值下创建 container（须在读取 provider 前设置 mock 值）
  ///
  /// resetStatic() 清除 SharedPreferences 单例缓存，确保 setMockInitialValues
  /// 的新值在下次 getInstance() 时生效（否则跨测试复用首个缓存实例）。
  void createContainer([Map<String, Object> values = const {}]) {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(values);
    container = ProviderContainer();
    addTearDown(container.dispose);
  }

  ThemeState readState() => container.read(themeNotifierProvider);
  ThemeNotifier readNotifier() =>
      container.read(themeNotifierProvider.notifier);

  group('ThemeNotifier 初始状态', () {
    test('默认主题模式为 system', () {
      createContainer();
      expect(readState().themeMode, ThemeMode.system);
    });

    test('默认字体缩放原始值为 0（跟随系统）', () {
      createContainer();
      final state = readState();
      expect(state.fontScaleRaw, equals(0));
      expect(state.isSystemFontScale, isTrue);
      expect(state.fontScale, isNull);
      expect(state.fontScaleLabel, equals('跟随系统'));
    });
  });

  group('ThemeNotifier 加载持久化设置', () {
    test('build 自动读取已保存的主题模式与字体缩放', () async {
      createContainer({
        'app_theme_mode': 'dark',
        'app_font_scale': 12,
      });
      await pumpInit();

      final state = readState();
      expect(state.themeMode, ThemeMode.dark);
      expect(state.fontScaleRaw, equals(12));
      expect(state.fontScale, equals(1.2));
    });

    test('无持久化值时回退默认', () async {
      createContainer();
      await pumpInit();
      final state = readState();
      expect(state.themeMode, ThemeMode.system);
      expect(state.fontScaleRaw, equals(0));
    });
  });

  group('ThemeNotifier 主题模式', () {
    test('setThemeMode 更新状态并持久化', () async {
      createContainer();
      await pumpInit();
      await readNotifier().setThemeMode(ThemeMode.light);
      expect(readState().themeMode, ThemeMode.light);
      expect(await SettingsService().getThemeMode(), ThemeMode.light);
    });

    test('setThemeMode 触发状态变更通知', () async {
      createContainer();
      await pumpInit(); // 先完成自动加载，避免其通知计入
      var notified = 0;
      container.listen(themeNotifierProvider, (_, __) => notified++);
      await readNotifier().setThemeMode(ThemeMode.dark);
      expect(notified, equals(1));
    });

    test('setThemeMode 相同值不触发通知', () async {
      createContainer();
      await pumpInit();
      var notified = 0;
      container.listen(themeNotifierProvider, (_, __) => notified++);
      await readNotifier().setThemeMode(ThemeMode.system); // 与默认相同
      expect(notified, equals(0));
    });
  });

  group('ThemeNotifier 字体缩放', () {
    test('setFontScale 更新状态并持久化', () async {
      createContainer();
      await pumpInit();
      await readNotifier().setFontScale(14);
      expect(readState().fontScaleRaw, equals(14));
      expect(readState().fontScale, equals(1.4));
      expect(await SettingsService().getFontScale(), equals(14));
    });

    test('setFontScale 触发状态变更通知', () async {
      createContainer();
      await pumpInit();
      var notified = 0;
      container.listen(themeNotifierProvider, (_, __) => notified++);
      await readNotifier().setFontScale(10);
      expect(notified, equals(1));
    });

    test('setFontScale(0) 重置为跟随系统', () async {
      createContainer();
      await pumpInit();
      await readNotifier().setFontScale(12);
      await readNotifier().setFontScale(0);
      final state = readState();
      expect(state.isSystemFontScale, isTrue);
      expect(state.fontScale, isNull);
      expect(state.fontScaleLabel, equals('跟随系统'));
    });

    test('fontScale 边界值映射（8→0.8, 16→1.6）', () async {
      createContainer();
      await pumpInit();
      await readNotifier().setFontScale(8);
      expect(readState().fontScale, equals(0.8));
      await readNotifier().setFontScale(16);
      expect(readState().fontScale, equals(1.6));
    });

    test('fontScale 超出有效范围视为跟随系统', () async {
      createContainer();
      await pumpInit();
      await readNotifier().setFontScale(7);
      expect(readState().fontScale, isNull);
      await readNotifier().setFontScale(17);
      expect(readState().fontScale, isNull);
    });

    test('fontScaleLabel 展示当前倍数', () async {
      createContainer();
      await pumpInit();
      await readNotifier().setFontScale(10);
      expect(readState().fontScaleLabel, equals('当前字体大小：1.0'));
      await readNotifier().setFontScale(15);
      expect(readState().fontScaleLabel, equals('当前字体大小：1.5'));
    });
  });
}
