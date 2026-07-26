import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读设置持久化服务
class SettingsService {
  static const _keyFontSize = 'reader_font_size';
  static const _keyLineHeight = 'reader_line_height';
  static const _keyBgColorIndex = 'reader_bg_color_index';
  static const _keyFlipMode = 'reader_flip_mode';
  static const _keyBrightness = 'reader_brightness';
  static const _keyThemeMode = 'app_theme_mode';
  static const _keyLocale = 'app_locale';
  static const _keyShowBookshelfRecentReading = 'bookshelf_show_recent_reading';
  static const _keyShowBookshelfStats = 'bookshelf_show_stats';

  // ===== 字体大小 =====

  Future<double> getFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyFontSize) ?? 18.0;
  }

  Future<void> setFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, size);
  }

  // ===== 行距 =====

  Future<double> getLineHeight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyLineHeight) ?? 1.6;
  }

  Future<void> setLineHeight(double height) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLineHeight, height);
  }

  // ===== 背景色索引 =====

  Future<int> getBgColorIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyBgColorIndex) ?? 0;
  }

  Future<void> setBgColorIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyBgColorIndex, index);
  }

  // ===== 翻页模式 =====

  Future<int> getFlipMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyFlipMode) ?? 0;
  }

  Future<void> setFlipMode(int mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyFlipMode, mode);
  }

  // ===== 亮度 =====

  Future<double> getBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyBrightness) ?? -1.0; // -1 表示跟随系统
  }

  Future<void> setBrightness(double brightness) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBrightness, brightness);
  }

  // ===== 应用主题模式 =====

  Future<ThemeMode> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_keyThemeMode) ?? 'system';
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    String value;
    switch (mode) {
      case ThemeMode.light:
        value = 'light';
        break;
      case ThemeMode.dark:
        value = 'dark';
        break;
      default:
        value = 'system';
    }
    await prefs.setString(_keyThemeMode, value);
  }

  // ===== 书架偏好：显示最近阅读 =====

  Future<bool> getShowBookshelfRecentReading() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowBookshelfRecentReading) ?? true;
  }

  Future<void> setShowBookshelfRecentReading(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowBookshelfRecentReading, value);
  }

  // ===== 书架偏好：显示阅读统计 =====

  Future<bool> getShowBookshelfStats() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowBookshelfStats) ?? true;
  }

  Future<void> setShowBookshelfStats(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowBookshelfStats, value);
  }

  // ===== 语言设置 =====

  Future<String> getLocale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLocale) ?? 'system';
  }

  Future<void> setLocale(String locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLocale, locale);
  }

  // ===== WebDAV 云同步配置 =====

  static const _keyWebDavUrl = 'sync_webdav_url';
  static const _keyWebDavUsername = 'sync_webdav_username';
  static const _keyWebDavPassword = 'sync_webdav_password';
  static const _keyWebDavRemoteDir = 'sync_webdav_remote_dir';
  static const _keyAutoSync = 'sync_auto';
  static const _keyLastSyncTime = 'sync_last_time';

  Future<String> getWebDavUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyWebDavUrl) ?? '';
  }

  Future<void> setWebDavUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWebDavUrl, value);
  }

  Future<String> getWebDavUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyWebDavUsername) ?? '';
  }

  Future<void> setWebDavUsername(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWebDavUsername, value);
  }

  Future<String> getWebDavPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyWebDavPassword) ?? '';
  }

  Future<void> setWebDavPassword(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWebDavPassword, value);
  }

  Future<String> getWebDavRemoteDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyWebDavRemoteDir) ?? '/legado/';
  }

  Future<void> setWebDavRemoteDir(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWebDavRemoteDir, value);
  }

  Future<bool> getAutoSync() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoSync) ?? false;
  }

  Future<void> setAutoSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoSync, value);
  }

  Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_keyLastSyncTime);
    return millis != null ? DateTime.fromMillisecondsSinceEpoch(millis) : null;
  }

  Future<void> setLastSyncTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastSyncTime, time.millisecondsSinceEpoch);
  }
}
