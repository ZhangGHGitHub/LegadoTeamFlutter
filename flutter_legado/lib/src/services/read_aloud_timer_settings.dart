import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 朗读定时模式（设置批5c）
///
/// 与参考版 `ReadAloudTimerMode` 同构：分钟倒计时与按章停止互斥。
/// 存储值对齐参考版（`minute` / `chapter`），未知值回落分钟模式。
enum ReadAloudTimerMode {
  minute('minute'),
  chapter('chapter');

  const ReadAloudTimerMode(this.storageValue);

  final String storageValue;

  static ReadAloudTimerMode fromStorage(String? value) {
    return values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => ReadAloudTimerMode.minute,
    );
  }
}

/// 分钟定时上限（对齐参考版 `PlaybackTimer.MAX_MINUTES = 180`）
const int kMaxReadAloudTimerMinutes = 180;

/// 按章定时上限（对齐参考版 `PlaybackTimer.MAX_CHAPTERS = 50`）
const int kMaxReadAloudTimerChapters = 50;

/// 分钟预设（0 = 关闭；对齐参考版 ReadAloudTimerSheet）
const List<int> kReadAloudTimerMinutePresets = [
  0,
  10,
  15,
  20,
  25,
  30,
  45,
  60,
  90,
  120,
  180,
];

/// 章节预设（0 = 关闭；对齐参考版 ReadAloudTimerSheet）
const List<int> kReadAloudTimerChapterPresets = [0, 1, 2, 3, 5, 8, 10, 15, 20];

/// 系统 TTS 缓存保留时间上下限（分钟）
const int kMinReadAloudCacheRetentionMinutes = 0;
const int kMaxReadAloudCacheRetentionMinutes = 10080;

/// 系统 TTS 缓存默认保留时间（分钟）
const int kDefaultReadAloudCacheRetentionMinutes = 10;

/// 分钟数收敛到 0–[kMaxReadAloudTimerMinutes]
int normalizeReadAloudTimerMinutes(int minutes) =>
    minutes.clamp(0, kMaxReadAloudTimerMinutes);

/// 章节数收敛到 0–[kMaxReadAloudTimerChapters]
int normalizeReadAloudTimerChapters(int chapters) =>
    chapters.clamp(0, kMaxReadAloudTimerChapters);

/// 缓存保留时间收敛到 0–[kMaxReadAloudCacheRetentionMinutes]
int normalizeReadAloudCacheRetentionMinutes(int minutes) => minutes.clamp(
  kMinReadAloudCacheRetentionMinutes,
  kMaxReadAloudCacheRetentionMinutes,
);

/// 朗读定时 Sheet 的持久化设置快照
///
/// 只承载「用户设置值」，不承载运行中剩余量：应用重启后 Sheet 回显这些
/// 值，但**不会自动恢复倒计时**（对齐参考版仅恢复设置、由用户再次开始的
/// 产品语义）。
@immutable
class ReadAloudTimerConfig {
  const ReadAloudTimerConfig({
    this.mode = ReadAloudTimerMode.minute,
    this.minutes = 0,
    this.chapters = 0,
    this.finishCurrentChapterAfterTimer = false,
  });

  final ReadAloudTimerMode mode;
  final int minutes;
  final int chapters;
  final bool finishCurrentChapterAfterTimer;

  ReadAloudTimerConfig copyWith({
    ReadAloudTimerMode? mode,
    int? minutes,
    int? chapters,
    bool? finishCurrentChapterAfterTimer,
  }) {
    return ReadAloudTimerConfig(
      mode: mode ?? this.mode,
      minutes: minutes ?? this.minutes,
      chapters: chapters ?? this.chapters,
      finishCurrentChapterAfterTimer:
          finishCurrentChapterAfterTimer ?? this.finishCurrentChapterAfterTimer,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ReadAloudTimerConfig &&
        other.mode == mode &&
        other.minutes == minutes &&
        other.chapters == chapters &&
        other.finishCurrentChapterAfterTimer == finishCurrentChapterAfterTimer;
  }

  @override
  int get hashCode =>
      Object.hash(mode, minutes, chapters, finishCurrentChapterAfterTimer);
}

/// 朗读定时设置持久化（SharedPreferences）
///
/// 键名见 [PrefKeys.readAloudTimerMode] 等。读取失败/类型异常一律回落到
/// 默认值并 debugPrint，不向 UI 抛异常（设置页/Sheet 可用性优先）。
class ReadAloudTimerSettings {
  const ReadAloudTimerSettings._();

  /// 从已取得的 [SharedPreferences] 读取（供 AudioNotifier 会话入口复用）
  static ReadAloudTimerConfig loadFromPrefs(SharedPreferences prefs) {
    try {
      final rawMode = prefs.get(PrefKeys.readAloudTimerMode);
      final mode = ReadAloudTimerMode.fromStorage(
        rawMode is String ? rawMode : null,
      );
      final rawMinutes = prefs.get(PrefKeys.readAloudTimerMinutes);
      final rawChapters = prefs.get(PrefKeys.readAloudTimerChapters);
      final rawFinish = prefs.get(PrefKeys.finishCurrentChapterAfterTimer);
      return ReadAloudTimerConfig(
        mode: mode,
        minutes: normalizeReadAloudTimerMinutes(
          rawMinutes is int ? rawMinutes : 0,
        ),
        chapters: normalizeReadAloudTimerChapters(
          rawChapters is int ? rawChapters : 0,
        ),
        finishCurrentChapterAfterTimer: rawFinish is bool && rawFinish,
      );
    } catch (e) {
      debugPrint('读取朗读定时设置失败（使用默认值）: $e');
      return const ReadAloudTimerConfig();
    }
  }

  /// 读取设置（SharedPreferences 不可用时回默认值）
  static Future<ReadAloudTimerConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return loadFromPrefs(prefs);
    } catch (e) {
      debugPrint('读取朗读定时设置失败（使用默认值）: $e');
      return const ReadAloudTimerConfig();
    }
  }

  /// 保存模式（失败静默，仅 debugPrint）
  static Future<void> saveMode(ReadAloudTimerMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PrefKeys.readAloudTimerMode, mode.storageValue);
    } catch (e) {
      debugPrint('保存朗读定时模式失败: $e');
    }
  }

  /// 保存分钟预设值
  static Future<void> saveMinutes(int minutes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        PrefKeys.readAloudTimerMinutes,
        normalizeReadAloudTimerMinutes(minutes),
      );
    } catch (e) {
      debugPrint('保存朗读分钟定时失败: $e');
    }
  }

  /// 保存章节预设值
  static Future<void> saveChapters(int chapters) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        PrefKeys.readAloudTimerChapters,
        normalizeReadAloudTimerChapters(chapters),
      );
    } catch (e) {
      debugPrint('保存朗读按章定时失败: $e');
    }
  }

  /// 保存「读完本章再停」开关
  static Future<void> saveFinishCurrentChapterAfterTimer(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PrefKeys.finishCurrentChapterAfterTimer, enabled);
    } catch (e) {
      debugPrint('保存「读完本章再停」失败: $e');
    }
  }
}

/// 缓存保留时间的展示文案（设置页/Sheet 共用）
String readAloudCacheRetentionLabel(int minutes) {
  if (minutes <= 0) return '即听即焚';
  if (minutes < 60) return '$minutes 分钟';
  if (minutes % 1440 == 0) return '${minutes ~/ 1440} 天';
  if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
  return '$minutes 分钟';
}
