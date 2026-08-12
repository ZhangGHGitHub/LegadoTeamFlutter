import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';
import 'settings_service.dart';

/// 备份 JSON 中偏好字段名（Flutter 单文件备份扩展，对齐原版 config.xml）
const kBackupAppPrefsKey = 'appPrefs';

/// 恢复忽略项的偏好备份/恢复（对齐 [BackupConfig.keyIsNotIgnore] + Restore 写 prefs）
///
/// 原版 ZIP 含 SharedPreferences `config`；重构版 JSON 仅有业务表时，
/// 由本助手在备份后注入 / 恢复前应用 `appPrefs`，使 ignore 键除 localBook 外亦可生效。
class RestoreIgnorePrefs {
  RestoreIgnorePrefs._();

  /// 始终不备份/不恢复（对齐 BackupConfig.ignorePrefKeys）
  static const alwaysIgnoreKeys = <String>{
    PrefKeys.webServiceWakeLock,
    PrefKeys.defaultBookTreeUri,
    PrefKeys.bitmapCacheSize,
    'defaultCover',
    'defaultCoverDark',
    'backupPath',
    'webDavDeviceName',
    'jsSourceApiToken',
    PrefKeys.launcherIcon,
    'readAloudWakeLock',
    'audioPlayWakeLock',
    SettingsService.restoreIgnoreStorageKey,
  };

  /// 阅读界面相关键（对齐 BackupConfig.readPrefKeys + Flutter 阅读偏好）
  static const readPrefKeys = <String>{
    'readStyleSelect',
    'comicStyleSelect',
    'shareLayout',
    'hideStatusBar',
    'hideNavigationBar',
    'autoReadSpeed',
    'clickActionTL',
    'clickActionTC',
    'clickActionTR',
    'clickActionML',
    'clickActionMC',
    'clickActionMR',
    'clickActionBL',
    'clickActionBC',
    'clickActionBR',
    'reader_font_size',
    'reader_line_height',
    'reader_bg_color_index',
    'reader_flip_mode',
    'reader_flip_mode_name',
    'reader_brightness',
    'reader_font_family',
  };

  /// 主题颜色相关键（对齐 BackupConfig.themePrefKeys）
  static const themePrefKeys = <String>{
    PrefKeys.cPrimary,
    PrefKeys.cAccent,
    PrefKeys.cBackground,
    PrefKeys.cBBackground,
    PrefKeys.bgImage,
    PrefKeys.bgImageN,
    PrefKeys.cNPrimary,
    PrefKeys.cNAccent,
    PrefKeys.cNBackground,
    PrefKeys.cNBBackground,
    PrefKeys.transparentNavBar,
    PrefKeys.transparentNavBarNight,
    'themeConfigList',
    'bgImageBlurring',
    'bgImageNBlurring',
  };

  /// 封面规则相关键（对齐 BackupConfig.coverPrefKeys）
  static const coverPrefKeys = <String>{
    PrefKeys.useDefaultCover,
    PrefKeys.loadCoverOnlyWifi,
    PrefKeys.coverShowName,
    PrefKeys.coverShowAuthor,
    'coverShowNameN',
    'coverShowAuthorN',
  };

  /// Flutter 侧主题模式存储键（SettingsService）
  static const themeModeStorageKey = 'app_theme_mode';

  /// Flutter 侧书架布局存储键
  static const bookshelfLayoutStorageKey = 'bookshelf_layout';

  /// 判断偏好键是否应写入备份 / 从备份恢复（对齐 BackupConfig.keyIsNotIgnore）
  static bool keyIsNotIgnore(String key, Map<String, bool> ignore) {
    if (alwaysIgnoreKeys.contains(key)) return false;
    if (ignore['readConfig'] == true && readPrefKeys.contains(key)) {
      return false;
    }
    if (ignore['themeConfig'] == true && themePrefKeys.contains(key)) {
      return false;
    }
    if (ignore['coverConfig'] == true && coverPrefKeys.contains(key)) {
      return false;
    }
    if (ignore['themeMode'] == true &&
        (key == 'themeMode' || key == themeModeStorageKey)) {
      return false;
    }
    if (ignore['bookshelfLayout'] == true &&
        (key == 'bookshelfLayout' || key == bookshelfLayoutStorageKey)) {
      return false;
    }
    if (ignore['showRss'] == true && key == PrefKeys.showRss) return false;
    if (ignore['threadCount'] == true && key == PrefKeys.threadCount) {
      return false;
    }
    return true;
  }

  /// 从当前 SharedPreferences 收集可备份偏好（已按 ignore 过滤）
  static Future<Map<String, dynamic>> collectForBackup(
    Map<String, bool> ignore,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (!keyIsNotIgnore(key, ignore)) continue;
      final value = prefs.get(key);
      if (value == null) continue;
      out[key] = value;
    }
    return out;
  }

  /// 将备份中的 appPrefs 写入 SharedPreferences（按 ignore 过滤）
  static Future<void> applyFromBackup(
    Map<String, dynamic>? appPrefs,
    Map<String, bool> ignore,
  ) async {
    if (appPrefs == null || appPrefs.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    for (final entry in appPrefs.entries) {
      final key = entry.key;
      if (!keyIsNotIgnore(key, ignore)) continue;
      final value = entry.value;
      try {
        if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is String) {
          await prefs.setString(key, value);
        } else if (value is List) {
          await prefs.setStringList(
            key,
            value.map((e) => '$e').toList(),
          );
        } else if (value is num) {
          if (value == value.roundToDouble()) {
            await prefs.setInt(key, value.toInt());
          } else {
            await prefs.setDouble(key, value.toDouble());
          }
        }
      } catch (e) {
        debugPrint('RestoreIgnorePrefs.applyFromBackup($key) 异常: $e');
      }
    }
  }

  /// 向备份 JSON 注入 appPrefs
  static Future<void> injectAppPrefsIntoBackupFile(
    String backupPath,
    Map<String, bool> ignore,
  ) async {
    if (!backupPath.toLowerCase().endsWith('.json')) return;
    try {
      final file = await _readJsonMap(backupPath);
      if (file == null) return;
      file[kBackupAppPrefsKey] = await collectForBackup(ignore);
      await File(backupPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(file),
      );
    } catch (e) {
      debugPrint('RestoreIgnorePrefs.injectAppPrefsIntoBackupFile 异常: $e');
    }
  }

  /// 从备份 JSON 读取并应用 appPrefs（不改动供 Rust restore 的文件）
  static Future<void> applyAppPrefsFromBackupFile(
    String backupPath,
    Map<String, bool> ignore,
  ) async {
    if (!backupPath.toLowerCase().endsWith('.json')) return;
    try {
      final file = await _readJsonMap(backupPath);
      if (file == null) return;
      final raw = file[kBackupAppPrefsKey];
      Map<String, dynamic>? appPrefs;
      if (raw is Map<String, dynamic>) {
        appPrefs = raw;
      } else if (raw is Map) {
        appPrefs = raw.map((k, v) => MapEntry('$k', v));
      }
      await applyFromBackup(appPrefs, ignore);
    } catch (e) {
      debugPrint('RestoreIgnorePrefs.applyAppPrefsFromBackupFile 异常: $e');
    }
  }

  static Future<Map<String, dynamic>?> _readJsonMap(String path) async {
    final raw = await File(path).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry('$k', v));
    }
    return null;
  }
}
