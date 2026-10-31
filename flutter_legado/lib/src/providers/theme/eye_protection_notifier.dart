// [设置批2a-1 | 2026-11-01] 护眼模式偏好状态（全局单一真源）— 全栈工程师
//
// 语义基准（参考版 legado-with-MD3）：
// - 字段/默认值：`ThemeSettings.kt:67-72`、`FeatureSettingsRepositories.kt:421-426`
// - 键名：`PreferKey.kt:489-495`
// - 写入路径：`ThemeSettingsGateway.update`（外观设置页与阅读设置/阅读菜单共用
//   同一份值）；本 Notifier 对应同一语义：设置页写、全局叠加层读同一 state，
//   经 SharedPreferences 持久化（重启恢复）。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../constants/pref_keys.dart';
import '../../models/eye_protection.dart';
import '../../services/settings_service.dart';

/// 护眼模式 Notifier
///
/// - [build] 同步返回参考版默认值，随后微任务读取 SharedPreferences；
/// - 加载期间发生的用户动作使本次加载作废（与 ThemeNotifier/UiSettingsNotifier
///   同一代数机制），避免启动早期改值被旧持久化值覆盖；
/// - 所有 setter 先更新内存 state（全局即时生效）再落盘；读写失败由
///   SettingsService 捕获并 debugPrint，UI 不抛出、不阻断交互。
class EyeProtectionNotifier extends Notifier<EyeProtectionSettings> {
  final SettingsService _settings = SettingsService();

  /// 用户设置动作计数（代数）：使进行中的异步加载作废
  int _mutationGeneration = 0;

  @override
  EyeProtectionSettings build() {
    final generation = _mutationGeneration;
    Future.microtask(() => _load(generation));
    return const EyeProtectionSettings();
  }

  Future<void> _load(int generation) async {
    try {
      final enabled = await _settings.getBoolPref(
        PrefKeys.eyeProtectionEnabled,
        defaultValue: EyeProtectionSettings.defaultEnabled,
      );
      final intensity = await _settings.getIntPref(
        PrefKeys.colorTemperature,
        defaultValue: EyeProtectionSettings.defaultIntensity,
      );
      final autoNight = await _settings.getBoolPref(
        PrefKeys.eyeProtectionAutoNight,
        defaultValue: EyeProtectionSettings.defaultAutoNight,
      );
      final schedule = await _settings.getBoolPref(
        PrefKeys.eyeProtectionSchedule,
        defaultValue: EyeProtectionSettings.defaultSchedule,
      );
      final startTime = await _settings.getStringPref(
        PrefKeys.eyeProtectionStartTime,
        defaultValue: EyeProtectionSettings.defaultStartTime,
      );
      final endTime = await _settings.getStringPref(
        PrefKeys.eyeProtectionEndTime,
        defaultValue: EyeProtectionSettings.defaultEndTime,
      );
      if (generation != _mutationGeneration) return;
      state = EyeProtectionSettings(
        enabled: enabled,
        intensity: _clampIntensity(intensity),
        autoNight: autoNight,
        schedule: schedule,
        startTime: startTime,
        endTime: endTime,
      );
    } catch (e) {
      // 失败静默：保持默认值，不阻断启动/设置页
      debugPrint('EyeProtectionNotifier 加载失败（保持默认值）: $e');
    }
  }

  /// 重新读取持久化值（备份恢复后调用，使同会话内即时生效）
  Future<void> reload() async {
    _mutationGeneration++;
    await _load(_mutationGeneration);
  }

  Future<void> setEnabled(bool value) async {
    if (state.enabled == value) return;
    _mutationGeneration++;
    state = state.copyWith(enabled: value);
    await _settings.setBoolPref(PrefKeys.eyeProtectionEnabled, value);
  }

  /// 设置强度（0..100，越界值收敛；参考版颜色矩阵对越界值同样 clamp）
  Future<void> setIntensity(int value) async {
    final clamped = _clampIntensity(value);
    if (state.intensity == clamped) return;
    _mutationGeneration++;
    state = state.copyWith(intensity: clamped);
    await _settings.setIntPref(PrefKeys.colorTemperature, clamped);
  }

  Future<void> setAutoNight(bool value) async {
    if (state.autoNight == value) return;
    _mutationGeneration++;
    state = state.copyWith(autoNight: value);
    await _settings.setBoolPref(PrefKeys.eyeProtectionAutoNight, value);
  }

  Future<void> setSchedule(bool value) async {
    if (state.schedule == value) return;
    _mutationGeneration++;
    state = state.copyWith(schedule: value);
    await _settings.setBoolPref(PrefKeys.eyeProtectionSchedule, value);
  }

  Future<void> setStartTime(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty || state.startTime == normalized) return;
    _mutationGeneration++;
    state = state.copyWith(startTime: normalized);
    await _settings.setStringPref(PrefKeys.eyeProtectionStartTime, normalized);
  }

  Future<void> setEndTime(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty || state.endTime == normalized) return;
    _mutationGeneration++;
    state = state.copyWith(endTime: normalized);
    await _settings.setStringPref(PrefKeys.eyeProtectionEndTime, normalized);
  }

  static int _clampIntensity(int value) {
    return value.clamp(
      EyeProtectionFilter.minIntensity,
      EyeProtectionFilter.maxIntensity,
    );
  }
}

/// 护眼模式 Provider（设置页与全局叠加层共用）
final eyeProtectionProvider =
    NotifierProvider<EyeProtectionNotifier, EyeProtectionSettings>(
      EyeProtectionNotifier.new,
    );
