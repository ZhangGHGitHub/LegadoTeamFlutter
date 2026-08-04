import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读设置持久化服务
class SettingsService {
  static const _keyFontSize = 'reader_font_size';
  static const _keyLineHeight = 'reader_line_height';
  static const _keyBgColorIndex = 'reader_bg_color_index';
  static const _keyFlipMode = 'reader_flip_mode';
  static const _keyFlipModeName = 'reader_flip_mode_name'; // 新版枚举名存储
  static const _keyBrightness = 'reader_brightness';
  static const _keyThemeMode = 'app_theme_mode';
  static const _keyFontScale = 'app_font_scale';
  static const _keyLocale = 'app_locale';
  static const _keyShowBookshelfRecentReading = 'bookshelf_show_recent_reading';
  static const _keyShowBookshelfStats = 'bookshelf_show_stats';
  static const _keyBookshelfTabPosition = 'bookshelf_tab_position';
  static const _keyBookshelfLayout = 'bookshelf_layout'; // true=网格 false=列表

  // ===== 字体大小 =====

  Future<double> getFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyFontSize) ?? 18.0;
    } catch (e) {
      debugPrint('SettingsService.getFontSize 异常: $e');
      return 18.0;
    }
  }

  Future<void> setFontSize(double size) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyFontSize, size);
    } catch (e) {
      debugPrint('SettingsService.setFontSize 异常: $e');
    }
  }

  // ===== 行距 =====

  Future<double> getLineHeight() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyLineHeight) ?? 1.6;
    } catch (e) {
      debugPrint('SettingsService.getLineHeight 异常: $e');
      return 1.6;
    }
  }

  Future<void> setLineHeight(double height) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyLineHeight, height);
    } catch (e) {
      debugPrint('SettingsService.setLineHeight 异常: $e');
    }
  }

  // ===== 背景色索引 =====

  Future<int> getBgColorIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyBgColorIndex) ?? 0;
    } catch (e) {
      debugPrint('SettingsService.getBgColorIndex 异常: $e');
      return 0;
    }
  }

  Future<void> setBgColorIndex(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyBgColorIndex, index);
    } catch (e) {
      debugPrint('SettingsService.setBgColorIndex 异常: $e');
    }
  }

  // ===== 翻页模式 =====

  /// 获取旧版 int 索引存储的翻页模式（兼容旧用户）
  Future<int> getFlipMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyFlipMode) ?? -1; // -1 表示无旧版存储
    } catch (e) {
      debugPrint('SettingsService.getFlipMode 异常: $e');
      return -1;
    }
  }

  Future<void> setFlipMode(int mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyFlipMode, mode);
    } catch (e) {
      debugPrint('SettingsService.setFlipMode 异常: $e');
    }
  }

  /// 获取新版 enum name 存储的翻页模式（避免索引变动破坏映射）
  Future<String?> getFlipModeName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyFlipModeName);
    } catch (e) {
      debugPrint('SettingsService.getFlipModeName 异常: $e');
      return null;
    }
  }

  Future<void> setFlipModeName(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFlipModeName, name);
    } catch (e) {
      debugPrint('SettingsService.setFlipModeName 异常: $e');
    }
  }

  // ===== 亮度 =====

  Future<double> getBrightness() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyBrightness) ?? -1.0; // -1 表示跟随系统
    } catch (e) {
      debugPrint('SettingsService.getBrightness 异常: $e');
      return -1.0;
    }
  }

  Future<void> setBrightness(double brightness) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyBrightness, brightness);
    } catch (e) {
      debugPrint('SettingsService.setBrightness 异常: $e');
    }
  }

  // ===== 应用主题模式 =====

  Future<ThemeMode> getThemeMode() async {
    try {
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
    } catch (e) {
      debugPrint('SettingsService.getThemeMode 异常: $e');
      return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    try {
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
    } catch (e) {
      debugPrint('SettingsService.setThemeMode 异常: $e');
    }
  }

  // ===== 全局字体缩放 =====

  /// 全局 UI 字体缩放原始值（对齐原版 PreferKey.fontScale）
  ///
  /// 0 = 跟随系统；8~16 → 0.8x~1.6x（见 AppContextWrapper.getFontScale）。
  Future<int> getFontScale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyFontScale) ?? 0;
    } catch (e) {
      debugPrint('SettingsService.getFontScale 异常: $e');
      return 0;
    }
  }

  Future<void> setFontScale(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyFontScale, value);
    } catch (e) {
      debugPrint('SettingsService.setFontScale 异常: $e');
    }
  }

  // ===== 书架偏好：显示最近阅读 =====

  Future<bool> getShowBookshelfRecentReading() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyShowBookshelfRecentReading) ?? true;
    } catch (e) {
      debugPrint('SettingsService.getShowBookshelfRecentReading 异常: $e');
      return true;
    }
  }

  Future<void> setShowBookshelfRecentReading(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyShowBookshelfRecentReading, value);
    } catch (e) {
      debugPrint('SettingsService.setShowBookshelfRecentReading 异常: $e');
    }
  }

  // ===== 书架偏好：显示阅读统计 =====

  Future<bool> getShowBookshelfStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyShowBookshelfStats) ?? true;
    } catch (e) {
      debugPrint('SettingsService.getShowBookshelfStats 异常: $e');
      return true;
    }
  }

  Future<void> setShowBookshelfStats(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyShowBookshelfStats, value);
    } catch (e) {
      debugPrint('SettingsService.setShowBookshelfStats 异常: $e');
    }
  }

  // ===== 书架分组 Tab 位置（对标原版 AppConfig.saveTabPosition）=====

  Future<int> getBookshelfTabPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyBookshelfTabPosition) ?? 0;
    } catch (e) {
      debugPrint('SettingsService.getBookshelfTabPosition 异常: $e');
      return 0;
    }
  }

  Future<void> setBookshelfTabPosition(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyBookshelfTabPosition, index);
    } catch (e) {
      debugPrint('SettingsService.setBookshelfTabPosition 异常: $e');
    }
  }

  // ===== 书架布局（网格/列表，对标原版 AppConfig.bookshelfLayout）=====

  Future<bool> getBookshelfLayout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyBookshelfLayout) ?? true; // 默认网格视图
    } catch (e) {
      debugPrint('SettingsService.getBookshelfLayout 异常: $e');
      return true;
    }
  }

  Future<void> setBookshelfLayout(bool isGridView) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyBookshelfLayout, isGridView);
    } catch (e) {
      debugPrint('SettingsService.setBookshelfLayout 异常: $e');
    }
  }

  // ===== 语言设置 =====

  Future<String> getLocale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyLocale) ?? 'system';
    } catch (e) {
      debugPrint('SettingsService.getLocale 异常: $e');
      return 'system';
    }
  }

  Future<void> setLocale(String locale) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLocale, locale);
    } catch (e) {
      debugPrint('SettingsService.setLocale 异常: $e');
    }
  }

  // ===== 网络设置：代理 =====

  static const _keyProxyType = 'net_proxy_type'; // none / http / socks5
  static const _keyProxyHost = 'net_proxy_host';
  static const _keyProxyPort = 'net_proxy_port';
  static const _keyRequestTimeout = 'net_request_timeout';

  Future<String> getProxyType() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyProxyType) ?? 'none';
    } catch (e) {
      debugPrint('SettingsService.getProxyType 异常: $e');
      return 'none';
    }
  }

  Future<void> setProxyType(String type) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyProxyType, type);
    } catch (e) {
      debugPrint('SettingsService.setProxyType 异常: $e');
    }
  }

  Future<String> getProxyHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyProxyHost) ?? '';
    } catch (e) {
      debugPrint('SettingsService.getProxyHost 异常: $e');
      return '';
    }
  }

  Future<void> setProxyHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyProxyHost, host);
    } catch (e) {
      debugPrint('SettingsService.setProxyHost 异常: $e');
    }
  }

  Future<int> getProxyPort() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyProxyPort) ?? 0;
    } catch (e) {
      debugPrint('SettingsService.getProxyPort 异常: $e');
      return 0;
    }
  }

  Future<void> setProxyPort(int port) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyProxyPort, port);
    } catch (e) {
      debugPrint('SettingsService.setProxyPort 异常: $e');
    }
  }

  // ===== 网络设置：请求超时（秒） =====

  Future<int> getRequestTimeout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyRequestTimeout) ?? 30;
    } catch (e) {
      debugPrint('SettingsService.getRequestTimeout 异常: $e');
      return 30;
    }
  }

  Future<void> setRequestTimeout(int seconds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyRequestTimeout, seconds);
    } catch (e) {
      debugPrint('SettingsService.setRequestTimeout 异常: $e');
    }
  }

  // ===== WebDAV 云同步配置 =====

  static const _keyWebDavUrl = 'sync_webdav_url';
  static const _keyWebDavUsername = 'sync_webdav_username';
  static const _keyWebDavPassword = 'sync_webdav_password';
  static const _keyWebDavRemoteDir = 'sync_webdav_remote_dir';
  static const _keyWebDavDeviceName = 'sync_webdav_device_name';
  static const _keySyncBookProgress = 'sync_book_progress';
  static const _keySyncBookProgressPlus = 'sync_book_progress_plus';
  static const _keyAutoSync = 'sync_auto';
  static const _keyLastSyncTime = 'sync_last_time';

  Future<String> getWebDavUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyWebDavUrl) ?? '';
    } catch (e) {
      debugPrint('SettingsService.getWebDavUrl 异常: $e');
      return '';
    }
  }

  Future<void> setWebDavUrl(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyWebDavUrl, value);
    } catch (e) {
      debugPrint('SettingsService.setWebDavUrl 异常: $e');
    }
  }

  Future<String> getWebDavUsername() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyWebDavUsername) ?? '';
    } catch (e) {
      debugPrint('SettingsService.getWebDavUsername 异常: $e');
      return '';
    }
  }

  Future<void> setWebDavUsername(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyWebDavUsername, value);
    } catch (e) {
      debugPrint('SettingsService.setWebDavUsername 异常: $e');
    }
  }

  Future<String> getWebDavPassword() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyWebDavPassword) ?? '';
    } catch (e) {
      debugPrint('SettingsService.getWebDavPassword 异常: $e');
      return '';
    }
  }

  Future<void> setWebDavPassword(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyWebDavPassword, value);
    } catch (e) {
      debugPrint('SettingsService.setWebDavPassword 异常: $e');
    }
  }

  Future<String> getWebDavRemoteDir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyWebDavRemoteDir) ?? '/legado/';
    } catch (e) {
      debugPrint('SettingsService.getWebDavRemoteDir 异常: $e');
      return '/legado/';
    }
  }

  Future<void> setWebDavRemoteDir(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyWebDavRemoteDir, value);
    } catch (e) {
      debugPrint('SettingsService.setWebDavRemoteDir 异常: $e');
    }
  }

  Future<String> getWebDavDeviceName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyWebDavDeviceName) ?? '';
    } catch (e) {
      debugPrint('SettingsService.getWebDavDeviceName 异常: $e');
      return '';
    }
  }

  Future<void> setWebDavDeviceName(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyWebDavDeviceName, value);
    } catch (e) {
      debugPrint('SettingsService.setWebDavDeviceName 异常: $e');
    }
  }

  Future<bool> getSyncBookProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keySyncBookProgress) ?? true;
    } catch (e) {
      debugPrint('SettingsService.getSyncBookProgress 异常: $e');
      return true;
    }
  }

  Future<void> setSyncBookProgress(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keySyncBookProgress, value);
    } catch (e) {
      debugPrint('SettingsService.setSyncBookProgress 异常: $e');
    }
  }

  Future<bool> getSyncBookProgressPlus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keySyncBookProgressPlus) ?? false;
    } catch (e) {
      debugPrint('SettingsService.getSyncBookProgressPlus 异常: $e');
      return false;
    }
  }

  Future<void> setSyncBookProgressPlus(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keySyncBookProgressPlus, value);
    } catch (e) {
      debugPrint('SettingsService.setSyncBookProgressPlus 异常: $e');
    }
  }

  Future<bool> getAutoSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyAutoSync) ?? false;
    } catch (e) {
      debugPrint('SettingsService.getAutoSync 异常: $e');
      return false;
    }
  }

  Future<void> setAutoSync(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoSync, value);
    } catch (e) {
      debugPrint('SettingsService.setAutoSync 异常: $e');
    }
  }

  Future<DateTime?> getLastSyncTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final millis = prefs.getInt(_keyLastSyncTime);
      return millis != null ? DateTime.fromMillisecondsSinceEpoch(millis) : null;
    } catch (e) {
      debugPrint('SettingsService.getLastSyncTime 异常: $e');
      return null;
    }
  }

  Future<void> setLastSyncTime(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyLastSyncTime, time.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('SettingsService.setLastSyncTime 异常: $e');
    }
  }
}
