// [设置批2a-1 | 2026-11-01] 护眼模式：默认值/强度矩阵/时段判定/持久化
// — 全栈工程师
//
// 语义基准（参考版 legado-with-MD3）：
// - EyeProtectionTest.kt：零强度=单位矩阵、强度钳制、跨零点/同日/起止相同/
//   解析失败退化为全天/Unicode 数字
// - ThemeSettings.kt:67-72 默认值；PreferKey.kt:489-495 键名
import 'package:flutter/material.dart' show ColorFilter;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/eye_protection.dart';
import 'package:flutter_legado/src/providers/theme/eye_protection_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('默认值与配置态（参考 ThemeSettings.kt:67-72）', () {
    test('默认六字段：关/50/关/关/22:00/07:00', () {
      const s = EyeProtectionSettings();
      expect(s.enabled, isFalse);
      expect(s.intensity, 50);
      expect(s.autoNight, isFalse);
      expect(s.schedule, isFalse);
      expect(s.startTime, '22:00');
      expect(s.endTime, '07:00');
      expect(s.isConfigured, isFalse);
    });

    test('isConfigured = 总开关 或 自动夜间（与参考 isEyeProtectionConfigured 一致）', () {
      expect(const EyeProtectionSettings(enabled: true).isConfigured, isTrue);
      expect(const EyeProtectionSettings(autoNight: true).isConfigured, isTrue);
      // 仅开启定时不算已配置（参考版强度/定时行仍隐藏）
      expect(const EyeProtectionSettings(schedule: true).isConfigured, isFalse);
    });
  });

  group('强度 → 颜色矩阵（参考 EyeProtection.matrixValuesForIntensity）', () {
    test('零强度/负强度返回单位矩阵（不改变颜色）', () {
      expect(
        EyeProtectionFilter.matrixForIntensity(0),
        EyeProtectionFilter.identityMatrix,
      );
      expect(
        EyeProtectionFilter.matrixForIntensity(-10),
        EyeProtectionFilter.identityMatrix,
      );
    });

    test('强度越界钳制：>100 与 100 相同', () {
      expect(
        EyeProtectionFilter.matrixForIntensity(101),
        EyeProtectionFilter.matrixForIntensity(100),
      );
    });

    test('强度 100 = 2596K：红 1、绿约 0.7232、蓝约 0.4588', () {
      expect(EyeProtectionFilter.temperatureForIntensity(100), 2596);
      final m = EyeProtectionFilter.matrixForIntensity(100);
      expect(m.length, 20);
      expect(m[0], 1.0);
      expect(m[6], closeTo(0.7232337, 1e-4));
      expect(m[12], closeTo(0.4587980, 1e-4));
    });

    test('强度 50 = 4048K：绿约 0.8526、蓝约 0.7152', () {
      expect(EyeProtectionFilter.temperatureForIntensity(50), 4048);
      final m = EyeProtectionFilter.matrixForIntensity(50);
      expect(m[6], closeTo(0.8526167, 1e-4));
      expect(m[12], closeTo(0.7152242, 1e-4));
    });

    test('强度越大暖色越重（绿/蓝系数单调下降）', () {
      var lastGreen = 1.0;
      var lastBlue = 1.0;
      for (var i = 1; i <= 100; i += 5) {
        final m = EyeProtectionFilter.matrixForIntensity(i);
        expect(m[6], lessThanOrEqualTo(lastGreen));
        expect(m[12], lessThanOrEqualTo(lastBlue));
        lastGreen = m[6];
        lastBlue = m[12];
      }
    });

    test('颜色滤镜始终为 4x5 矩阵（强度 0 亦挂载单位矩阵，语义同参考）', () {
      expect(
        EyeProtectionFilter.colorFilterForIntensity(0),
        isA<ColorFilter>(),
      );
      expect(
        EyeProtectionFilter.colorFilterForIntensity(50),
        isA<ColorFilter>(),
      );
    });
  });

  group('时段判定（参考 EyeProtection.isActiveAt）', () {
    EyeProtectionSettings s({
      bool enabled = true,
      bool autoNight = false,
      bool schedule = true,
      String start = '22:00',
      String end = '07:00',
    }) => EyeProtectionSettings(
      enabled: enabled,
      autoNight: autoNight,
      schedule: schedule,
      startTime: start,
      endTime: end,
    );

    bool activeAt(
      int hour, {
      int minute = 0,
      bool enabled = true,
      bool autoNight = false,
      bool isDark = false,
      bool schedule = true,
      String start = '22:00',
      String end = '07:00',
    }) {
      return EyeProtectionFilter.isActiveAt(
        settings: s(
          enabled: enabled,
          autoNight: autoNight,
          schedule: schedule,
          start: start,
          end: end,
        ),
        isDark: isDark,
        now: DateTime(2026, 1, 1, hour, minute),
      );
    }

    test('手动开关与深色自动独立决定候选生效', () {
      // 手动开启后浅色也生效
      expect(
        activeAt(3, enabled: true, autoNight: true, schedule: false),
        isTrue,
      );
      // 仅自动夜间：浅色不生效、深色生效
      expect(
        activeAt(
          3,
          enabled: false,
          autoNight: true,
          isDark: false,
          schedule: false,
        ),
        isFalse,
      );
      expect(
        activeAt(
          3,
          enabled: false,
          autoNight: true,
          isDark: true,
          schedule: false,
        ),
        isTrue,
      );
      // 仅手动开启：深浅色不参与
      expect(
        activeAt(
          3,
          enabled: true,
          autoNight: false,
          isDark: false,
          schedule: false,
        ),
        isTrue,
      );
    });

    test('自动夜间仍受定时时段约束', () {
      expect(activeAt(23, autoNight: true, isDark: true), isTrue);
      expect(activeAt(12, autoNight: true, isDark: true), isFalse);
    });

    test('总开关关闭且未开自动夜间时永不生效', () {
      expect(activeAt(23, enabled: false), isFalse);
      expect(activeAt(23, enabled: false, schedule: false), isFalse);
    });

    test('未启用定时时全天生效', () {
      expect(activeAt(3, schedule: false), isTrue);
      expect(activeAt(15, schedule: false), isTrue);
    });

    test('跨零点时段仅在窗口内（22:00 含 / 07:00 不含）', () {
      expect(activeAt(22), isTrue);
      expect(activeAt(23, minute: 30), isTrue);
      expect(activeAt(0, minute: 30), isTrue);
      expect(activeAt(6, minute: 59), isTrue);
      expect(activeAt(7), isFalse);
      expect(activeAt(12), isFalse);
      expect(activeAt(21, minute: 59), isFalse);
    });

    test('同日时段仅在窗口内（08:00 含 / 18:00 不含）', () {
      expect(activeAt(9, start: '08:00', end: '18:00'), isTrue);
      expect(activeAt(7, minute: 59, start: '08:00', end: '18:00'), isFalse);
      expect(activeAt(18, start: '08:00', end: '18:00'), isFalse);
    });

    test('时间无法解析时退化为按开关生效', () {
      expect(activeAt(12, start: 'bad', end: '07:00'), isTrue);
      expect(activeAt(12, start: '22:00', end: ''), isTrue);
      expect(
        activeAt(12, start: '7:00', end: '18:00'),
        isTrue,
        reason: 'LocalTime.parse 要求两位小时，7:00 非法 → 退化全天',
      );
      expect(
        activeAt(12, start: '24:00', end: '18:00'),
        isTrue,
        reason: '小时越界 → 非法 → 退化全天',
      );
    });

    test('定时时间兼容 Unicode 数字（阿拉伯-印度数字 ٢٢:٠٠）', () {
      expect(activeAt(23, start: '٢٢:٠٠', end: '٠٧:٠٠'), isTrue);
      expect(activeAt(12, start: '٢٢:٠٠', end: '٠٧:٠٠'), isFalse);
    });

    test('起止时间相同视为全天生效', () {
      expect(activeAt(3, start: '08:00', end: '08:00'), isTrue);
    });
  });

  group('parseClock', () {
    test('接受 HH:mm 与 HH:mm:ss', () {
      expect(EyeProtectionFilter.parseClock('22:05'), (hour: 22, minute: 5));
      expect(EyeProtectionFilter.parseClock(' 07:30:59 '), (
        hour: 7,
        minute: 30,
      ));
    });

    test('拒绝非法形态', () {
      for (final value in <String>[
        '',
        '22',
        '22:5',
        '2:05',
        '22:60',
        '24:00',
        'ab:cd',
        '22:05:',
        '-1:00',
      ]) {
        expect(
          EyeProtectionFilter.parseClock(value),
          isNull,
          reason: '应拒绝 "$value"',
        );
      }
    });
  });

  group('EyeProtectionNotifier 持久化（重启恢复）', () {
    late ProviderContainer container;

    void createContainer([Map<String, Object> values = const {}]) {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(values);
      container = ProviderContainer();
      addTearDown(container.dispose);
    }

    Future<void> pumpLoad() async {
      container.read(eyeProtectionProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    test('空存储：加载参考版默认值', () async {
      createContainer();
      expect(
        container.read(eyeProtectionProvider),
        const EyeProtectionSettings(),
      );
      await pumpLoad();
      expect(
        container.read(eyeProtectionProvider),
        const EyeProtectionSettings(),
      );
    });

    test('六键齐全：加载持久化值（越界强度收敛到 0..100）', () async {
      createContainer({
        PrefKeys.eyeProtectionEnabled: true,
        PrefKeys.colorTemperature: 300,
        PrefKeys.eyeProtectionAutoNight: true,
        PrefKeys.eyeProtectionSchedule: true,
        PrefKeys.eyeProtectionStartTime: '21:30',
        PrefKeys.eyeProtectionEndTime: '06:45',
      });
      await pumpLoad();
      final state = container.read(eyeProtectionProvider);
      expect(state.enabled, isTrue);
      expect(state.intensity, 100, reason: '越界强度读取即收敛');
      expect(state.autoNight, isTrue);
      expect(state.schedule, isTrue);
      expect(state.startTime, '21:30');
      expect(state.endTime, '06:45');
    });

    test('setter 落盘 + 新容器重启恢复（六键往返）', () async {
      createContainer();
      await pumpLoad();
      final notifier = container.read(eyeProtectionProvider.notifier);
      await notifier.setEnabled(true);
      await notifier.setIntensity(77);
      await notifier.setAutoNight(true);
      await notifier.setSchedule(true);
      await notifier.setStartTime('23:15');
      await notifier.setEndTime('06:10');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.eyeProtectionEnabled), isTrue);
      expect(prefs.getInt(PrefKeys.colorTemperature), 77);
      expect(prefs.getBool(PrefKeys.eyeProtectionAutoNight), isTrue);
      expect(prefs.getBool(PrefKeys.eyeProtectionSchedule), isTrue);
      expect(prefs.getString(PrefKeys.eyeProtectionStartTime), '23:15');
      expect(prefs.getString(PrefKeys.eyeProtectionEndTime), '06:10');

      // 模拟重启：新容器从同一存储加载
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      restarted.read(eyeProtectionProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        restarted.read(eyeProtectionProvider),
        const EyeProtectionSettings(
          enabled: true,
          intensity: 77,
          autoNight: true,
          schedule: true,
          startTime: '23:15',
          endTime: '06:10',
        ),
      );
    });

    test('setter 越界强度写入收敛值；空时间值被忽略', () async {
      createContainer();
      await pumpLoad();
      final notifier = container.read(eyeProtectionProvider.notifier);
      await notifier.setIntensity(-5);
      expect(container.read(eyeProtectionProvider).intensity, 0);
      await notifier.setIntensity(101);
      expect(container.read(eyeProtectionProvider).intensity, 100);

      await notifier.setStartTime('   ');
      expect(container.read(eyeProtectionProvider).startTime, '22:00');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.eyeProtectionStartTime), isNull);
    });

    test('reload 重读存储（备份恢复后同会话生效）', () async {
      createContainer();
      await pumpLoad();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PrefKeys.eyeProtectionEnabled, true);
      await prefs.setInt(PrefKeys.colorTemperature, 20);
      await container.read(eyeProtectionProvider.notifier).reload();
      final state = container.read(eyeProtectionProvider);
      expect(state.enabled, isTrue);
      expect(state.intensity, 20);
    });
  });
}
