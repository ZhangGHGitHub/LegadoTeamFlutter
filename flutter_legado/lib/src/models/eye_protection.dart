// [设置批2a-1 | 2026-11-01] 护眼模式配置与叠加层算法 — 全栈工程师
//
// 语义基准：参考版 `legado-with-MD3`
// - 配置模型：`domain/model/settings/ThemeSettings.kt:67-72`（六字段）
// - 键名：`constant/PreferKey.kt:489-495`
// - 算法：`ui/book/read/EyeProtection.kt:17-96`（色温→RGB 矩阵、时段判定）
// - 全局叠加：`base/BaseComposeActivity.kt:89-106`（整个 Activity 内容统一
//   叠加颜色矩阵；仅影响绘制，不改变点击/手势）
//
// 本文件不依赖 Flutter widget 层，便于单元测试；颜色矩阵用 dart:ui 的
// [ColorFilter] 表达，与参考版 Compose `ColorFilter.colorMatrix` 等价。
import 'dart:ui' show ColorFilter;

/// 护眼模式配置（不可变；字段与参考版 ThemeSettings 一一对应）
class EyeProtectionSettings {
  /// 总开关（参考版 `eyeProtectionEnabled`，默认 false）
  final bool enabled;

  /// 护眼强度 / 色温（参考版 `colorTemperature`，0..100，默认 50）
  ///
  /// 值越大色温越低（5500K→2596K）、暖色越重；0 = 不改变颜色。
  final int intensity;

  /// 深色模式时自动开启（参考版 `eyeProtectionAutoNight`，默认 false）
  ///
  /// 跟随应用主题的深/浅色（MaterialApp themeMode 解析结果），不跟随系统
  /// 单独设置；与定时开启同时启用时取交集（参考版 isActiveAt 语义）。
  final bool autoNight;

  /// 定时开启（参考版 `eyeProtectionSchedule`，默认 false）
  final bool schedule;

  /// 定时开始时间（HH:mm，默认 22:00；支持跨零点）
  final String startTime;

  /// 定时结束时间（HH:mm，默认 07:00；结束时刻不含）
  final String endTime;

  /// 参考版默认值（ThemeSettings.kt:67-72 / FeatureSettingsRepositories.kt:421-426）
  static const bool defaultEnabled = false;
  static const int defaultIntensity = 50;
  static const bool defaultAutoNight = false;
  static const bool defaultSchedule = false;
  static const String defaultStartTime = '22:00';
  static const String defaultEndTime = '07:00';

  const EyeProtectionSettings({
    this.enabled = defaultEnabled,
    this.intensity = defaultIntensity,
    this.autoNight = defaultAutoNight,
    this.schedule = defaultSchedule,
    this.startTime = defaultStartTime,
    this.endTime = defaultEndTime,
  });

  /// 是否已配置（参考版 ThemeSettings.isEyeProtectionConfigured：
  /// 总开关或自动夜间任一开启时，强度/定时行才显示）
  bool get isConfigured => enabled || autoNight;

  EyeProtectionSettings copyWith({
    bool? enabled,
    int? intensity,
    bool? autoNight,
    bool? schedule,
    String? startTime,
    String? endTime,
  }) {
    return EyeProtectionSettings(
      enabled: enabled ?? this.enabled,
      intensity: intensity ?? this.intensity,
      autoNight: autoNight ?? this.autoNight,
      schedule: schedule ?? this.schedule,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is EyeProtectionSettings &&
        other.enabled == enabled &&
        other.intensity == intensity &&
        other.autoNight == autoNight &&
        other.schedule == schedule &&
        other.startTime == startTime &&
        other.endTime == endTime;
  }

  @override
  int get hashCode =>
      Object.hash(enabled, intensity, autoNight, schedule, startTime, endTime);

  @override
  String toString() {
    return 'EyeProtectionSettings(enabled: $enabled, intensity: $intensity, '
        'autoNight: $autoNight, schedule: $schedule, '
        'startTime: $startTime, endTime: $endTime)';
  }
}

/// 护眼叠加层算法（逐行对齐参考版 `EyeProtection.kt`）
class EyeProtectionFilter {
  EyeProtectionFilter._();

  /// 强度范围（参考版 MIN_INTENSITY / MAX_INTENSITY）
  static const int minIntensity = 0;
  static const int maxIntensity = 100;

  /// 色温范围（参考版 MIN_FILTER_TEMPERATURE / MAX_FILTER_TEMPERATURE）
  static const int minTemperature = 2596;
  static const int maxTemperature = 5500;

  /// 参考版 `EyeProtection.coefficients`（RGB 三个二次拟合系数）
  static const List<double> _coefficients = <double>[
    0,
    0,
    1,
    -9.623533e-9,
    1.5304548e-4,
    0.39078277,
    -1.8935904e-8,
    3.024122e-4,
    -0.1986509,
  ];

  /// 单位矩阵（参考版 IDENTITY_MATRIX，4x5 行主序）
  static const List<double> identityMatrix = <double>[
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  /// 强度 → 色温（参考版 temperatureForIntensity：线性映射 5500→2596K）
  static int temperatureForIntensity(int intensity) {
    final normalized = intensity.clamp(minIntensity, maxIntensity);
    return (maxTemperature -
            (maxTemperature - minTemperature) * normalized / maxIntensity)
        .toInt();
  }

  /// 强度 → 颜色矩阵（参考版 matrixValuesForIntensity）
  ///
  /// 强度 <= 0 返回单位矩阵（不改变颜色）；越界值按 0..100 收敛。
  static List<double> matrixForIntensity(int intensity) {
    final normalized = intensity.clamp(minIntensity, maxIntensity);
    if (normalized <= minIntensity) {
      return List<double>.of(identityMatrix);
    }
    final cct = temperatureForIntensity(normalized).toDouble();
    final cctSquared = cct * cct;
    final red =
        cctSquared * _coefficients[0] +
        cct * _coefficients[1] +
        _coefficients[2];
    final green =
        cctSquared * _coefficients[3] +
        cct * _coefficients[4] +
        _coefficients[5];
    final blue =
        cctSquared * _coefficients[6] +
        cct * _coefficients[7] +
        _coefficients[8];
    return <double>[
      red,
      0,
      0,
      0,
      0,
      0,
      green,
      0,
      0,
      0,
      0,
      0,
      blue,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  /// 强度 → Flutter 颜色滤镜（与参考版 Compose ColorFilter 等价）
  ///
  /// 强度 0 时仍返回单位矩阵滤镜（参考版 `enabled` 即挂载滤镜，零强度
  /// 无视觉变化），保持「生效」与「滤镜挂载」语义一致。
  static ColorFilter colorFilterForIntensity(int intensity) {
    return ColorFilter.matrix(matrixForIntensity(intensity));
  }

  /// 计算护眼在给定时刻是否生效（参考版 `EyeProtection.isActiveAt`）
  ///
  /// - 手动开关开启，或「深色模式时自动开启」开启且当前为深色 → 候选生效；
  /// - 未启用定时 → 候选生效即生效；
  /// - 启用定时但时间无法解析 → 退化为不看时段（参考版同）；
  /// - 起止时间相同 → 全天生效；
  /// - 支持跨零点（如 22:00–07:00，结束时刻不含）。
  static bool isActiveAt({
    required EyeProtectionSettings settings,
    required bool isDark,
    required DateTime now,
  }) {
    if (!(settings.enabled || (settings.autoNight && isDark))) return false;
    if (!settings.schedule) return true;
    final start = parseClock(settings.startTime);
    final end = parseClock(settings.endTime);
    if (start == null || end == null) return true;
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    if (startMinutes == endMinutes) return true;
    final nowMinutes = now.hour * 60 + now.minute;
    return startMinutes < endMinutes
        ? nowMinutes >= startMinutes && nowMinutes < endMinutes
        : nowMinutes >= startMinutes || nowMinutes < endMinutes;
  }

  /// 解析 `HH:mm` / `HH:mm:ss`（参考版先归一 Unicode 数字再 LocalTime.parse）
  ///
  /// 解析失败返回 null（调用方按「定时不生效→全天」处理）。小时/分钟/秒
  /// 必须为两位数字且落在合法范围，与 java.time.LocalTime.parse 的
  /// ISO_LOCAL_TIME 形状一致；秒被忽略（界面选择器只产出 HH:mm）。
  static ({int hour, int minute})? parseClock(String value) {
    final parts = value.trim().split(':');
    if (parts.length != 2 && parts.length != 3) return null;
    if (parts[0].length != 2 || parts[1].length != 2) return null;
    if (parts.length == 3 && parts[2].length != 2) return null;
    final hour = _parseDigits(parts[0]);
    final minute = _parseDigits(parts[1]);
    if (hour == null || minute == null) return null;
    if (parts.length == 3 && _parseDigits(parts[2]) == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return (hour: hour, minute: minute);
  }

  /// 十进制数字解析（支持 Unicode Nd 数字，对齐 Character.digit(char, 10)）
  ///
  /// 逐字符必须是十进制数字（不允许正负号/空格）；任一非数字返回 null。
  static int? _parseDigits(String text) {
    if (text.isEmpty) return null;
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final digit = _digitValue(rune);
      if (digit == null) return null;
      buffer.write(digit);
    }
    return int.tryParse(buffer.toString());
  }

  /// Unicode 十进制数字（Nd）区段零码点；码点落在 [zero, zero+9] 即数字
  ///
  /// 覆盖 Unicode 常见文种（含参考版测试用到的阿拉伯-印度数字 ٠-٩），
  /// 等价于 Kotlin Character.digit(char, 10) 对 Nd 区的支持。
  static const List<int> _decimalZeroCodePoints = <int>[
    0x0030,
    0x0660,
    0x06F0,
    0x07C0,
    0x0966,
    0x09E6,
    0x0A66,
    0x0AE6,
    0x0B66,
    0x0BE6,
    0x0C66,
    0x0CE6,
    0x0D66,
    0x0DE6,
    0x0E50,
    0x0ED0,
    0x0F20,
    0x1040,
    0x1090,
    0x17E0,
    0x1810,
    0x1946,
    0x19D0,
    0x1A80,
    0x1A90,
    0x1B50,
    0x1BB0,
    0x1C40,
    0x1C50,
    0xA620,
    0xA8D0,
    0xA900,
    0xA9D0,
    0xA9F0,
    0xAA50,
    0xABF0,
    0xFF10,
  ];

  static int? _digitValue(int rune) {
    for (final zero in _decimalZeroCodePoints) {
      if (rune >= zero && rune <= zero + 9) return rune - zero;
    }
    return null;
  }
}
