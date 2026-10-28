import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/md3_colors.dart';

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
  // [MD3 Batch 0 | 2026-08-28] 内置 MD3 调色板 id（UI_MD3_PLAN.md 第九节：
  // SharedPreferences 本地持久化，非 Rust FFI，免 API_CONTRACT 变更） — Qoder UI
  static const _keyPaletteId = 'app_palette_id';
  static const _keyLocale = 'app_locale';
  static const _keyBookshelfTabPosition = 'bookshelf_tab_position';
  static const _keyBookshelfLayout = 'bookshelf_layout'; // true=网格 false=列表
  // [批33 | 正文搜索选项持久化] 键名前缀独立（不占用原版业务表键）：
  // 原版把搜索范围/替换/正则放在 ViewModel 进程内静态（关页面重进保留、
  // 重启丢失），本批按裁决落 SharedPreferences，重进/重启均保持。
  static const _keySearchContentUseReplace = 'search_content_use_replace';
  static const _keySearchContentUseRegex = 'search_content_use_regex';
  static const _keySearchContentScope = 'search_content_scope';

  /// 正文搜索范围档位（对齐 C4 双基准三档；取值同时作为持久化字符串）
  static const searchScopeCurrent = 'current';
  static const searchScopeCached = 'current_and_cached';
  static const searchScopeNetwork = 'current_and_network';

  /// 默认范围 = 仅本书（已缓存），对齐原版/参考版「只搜已缓存」口径
  static const searchScopeDefault = searchScopeCached;

  static const Set<String> _searchScopes = {
    searchScopeCurrent,
    searchScopeCached,
    searchScopeNetwork,
  };
  // [UI-fix v2.0.3 | 2026-08-08] 删除提醒/目录页加载字数开关（对齐原版
  // LocalConfig.deleteBookAlert / AppConfig.tocCountWords） — Qoder
  static const _keyDeleteBookAlert = 'delete_book_alert';
  static const _keyTocLoadWordCount = 'toc_load_word_count';
  // 对齐原版 PreferKey.enableReadRecord / LocalConfig readRecordSort
  static const _keyEnableReadRecord = 'enableReadRecord';
  static const _keyReadRecordSort = 'readRecordSort';

  // ===== 字体大小 =====

  /// 正文字号下限（批33 裁决：参考版口径 5–50，步进 1，默认 20）
  static const double minFontSize = 5.0;

  /// 正文字号上限（同参考版口径）
  static const double maxFontSize = 50.0;

  /// 读取字号（越界值统一收敛到 5–50）
  ///
  /// [批33b | 字号越界收口] 本方法为字号的**唯一读写收口**：
  /// - 读取侧 clamp：第三方备份/历史手工写入可能 >50 或 <5；
  /// - 写入侧 clamp：主题导入、外部调用等任何写入点都不会落越界值；
  /// - 阅读器状态（`ReaderNotifier`）、Rust 注入（`RustApi`）均经此读取，
  ///   不再各自维护第二套范围。
  Future<double> getFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_keyFontSize);
      if (stored == null) return 20.0;
      final clamped = stored.clamp(minFontSize, maxFontSize);
      // 越界历史值：读取即收敛并回写，避免每次启动重复归一
      // （与批33 _loadSettings 的回写语义一致，收口位置前移到本服务）
      if (clamped != stored) {
        await prefs.setDouble(_keyFontSize, clamped);
      }
      return clamped;
    } catch (e) {
      debugPrint('SettingsService.getFontSize 异常: $e');
      return 20.0;
    }
  }

  /// 写入字号（统一 clamp 到 5–50，越界值不入库）
  Future<void> setFontSize(double size) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyFontSize, size.clamp(minFontSize, maxFontSize));
    } catch (e) {
      debugPrint('SettingsService.setFontSize 异常: $e');
    }
  }

  // ===== 行距 =====

  Future<double> getLineHeight() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyLineHeight) ?? 1.7;
    } catch (e) {
      debugPrint('SettingsService.getLineHeight 异常: $e');
      return 1.7;
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

  /// [M1 深色态默认修复] 可空读取背景索引：null = 从未设置（与显式 0 区分），
  /// 供阅读背景默认解析判断「用户是否显式选择过」
  Future<int?> getBgColorIndexOrNull() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyBgColorIndex);
    } catch (e) {
      debugPrint('SettingsService.getBgColorIndexOrNull 异常: $e');
      return null;
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

  // ===== 正文搜索选项（批33） =====

  /// 搜索前是否应用替换净化规则（默认 false）
  Future<bool> getSearchContentUseReplace() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keySearchContentUseReplace) ?? false;
    } catch (e) {
      debugPrint('SettingsService.getSearchContentUseReplace 异常: $e');
      return false;
    }
  }

  Future<void> setSearchContentUseReplace(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keySearchContentUseReplace, value);
    } catch (e) {
      debugPrint('SettingsService.setSearchContentUseReplace 异常: $e');
    }
  }

  /// 关键词是否按正则解释（默认 false）
  Future<bool> getSearchContentUseRegex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keySearchContentUseRegex) ?? false;
    } catch (e) {
      debugPrint('SettingsService.getSearchContentUseRegex 异常: $e');
      return false;
    }
  }

  Future<void> setSearchContentUseRegex(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keySearchContentUseRegex, value);
    } catch (e) {
      debugPrint('SettingsService.setSearchContentUseRegex 异常: $e');
    }
  }

  /// 搜索范围（三档；非法/缺失回退默认「仅本书（已缓存）」）
  Future<String> getSearchContentScope() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keySearchContentScope);
      return raw != null && _searchScopes.contains(raw)
          ? raw
          : searchScopeDefault;
    } catch (e) {
      debugPrint('SettingsService.getSearchContentScope 异常: $e');
      return searchScopeDefault;
    }
  }

  /// 写入搜索范围（非法档位忽略，避免脏值进入持久化）
  Future<void> setSearchContentScope(String scope) async {
    if (!_searchScopes.contains(scope)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keySearchContentScope, scope);
    } catch (e) {
      debugPrint('SettingsService.setSearchContentScope 异常: $e');
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

  // ===== 内置 MD3 调色板 =====

  /// 内置 MD3 调色板 id（对应 [Md3Palettes] 的 id；未知值由 byId 回退默认 def）
  Future<String> getPaletteId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyPaletteId) ?? Md3Palettes.defaultId;
    } catch (e) {
      debugPrint('SettingsService.getPaletteId 异常: $e');
      return Md3Palettes.defaultId;
    }
  }

  Future<void> setPaletteId(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyPaletteId, value);
    } catch (e) {
      debugPrint('SettingsService.setPaletteId 异常: $e');
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
      return prefs.getBool(_keyBookshelfLayout) ?? false; // 默认列表（对齐 AppConfig.bookshelfLayout=0）
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

  /// WebDAV 同步账号密码偏好键（**设备级秘密**：备份/恢复必须排除）
  static const webDavPasswordKey = 'sync_webdav_password';
  static const _keyWebDavUrl = 'sync_webdav_url';
  static const _keyWebDavUsername = 'sync_webdav_username';
  static const _keyWebDavPassword = webDavPasswordKey;
  static const _keyWebDavRemoteDir = 'sync_webdav_remote_dir';
  static const _keyWebDavDeviceName = 'sync_webdav_device_name';
  static const _keySyncBookProgress = 'sync_book_progress';
  static const _keySyncBookProgressPlus = 'sync_book_progress_plus';
  static const _keyAutoSync = 'sync_auto';
  static const _keyLastSyncTime = 'sync_last_time';
  // 远程书库服务器（对齐原版 servers 表 + AppConfig.remoteServerId）
  //
  // [批18a] 服务器列表已迁到 servers 表（`ServerService` 读写）；本键仅作为
  // **一次性迁移来源**保留（旧数据/回滚安全），新代码不再写入。迁移标记为
  // `remote_servers_migrated`。`remote_server_id` 仍是当前选中 id 的权威偏好。
  static const remoteServersKey = 'remote_servers';
  static const _keyRemoteServers = remoteServersKey;
  static const _keyRemoteServerId = 'remote_server_id';
  /// 默认 WebDAV（同步设置），对齐原版 DEFAULT_WEBDAV_ID = -1
  static const int defaultRemoteServerId = -1;

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

  /// 远程书库自定义服务器列表 JSON（`[{id,name,url,username,password}]`）
  ///
  /// [批18a] 仅由 `ServerService.migrateLegacyPrefs` 读取（一次性迁移来源）；
  /// 服务器列表的权威来源是 servers 表，本方法不再用于业务读写。
  Future<String> getRemoteServersJson() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyRemoteServers) ?? '[]';
    } catch (e) {
      debugPrint('SettingsService.getRemoteServersJson 异常: $e');
      return '[]';
    }
  }

  Future<void> setRemoteServersJson(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyRemoteServers, value);
    } catch (e) {
      debugPrint('SettingsService.setRemoteServersJson 异常: $e');
    }
  }

  /// 当前选用的远程服务器 id（-1 = 默认 WebDAV）
  Future<int> getRemoteServerId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyRemoteServerId) ?? defaultRemoteServerId;
    } catch (e) {
      debugPrint('SettingsService.getRemoteServerId 异常: $e');
      return defaultRemoteServerId;
    }
  }

  Future<void> setRemoteServerId(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyRemoteServerId, id);
    } catch (e) {
      debugPrint('SettingsService.setRemoteServerId 异常: $e');
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

  // ===== 删除提醒（对齐原版 LocalConfig.deleteBookAlert，默认开启） =====
  // [UI-fix v2.0.3 | 2026-08-08] 删除书籍时是否弹确认框 — Qoder

  Future<bool> getDeleteBookAlert() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyDeleteBookAlert) ?? true;
    } catch (e) {
      debugPrint('SettingsService.getDeleteBookAlert 异常: $e');
      return true;
    }
  }

  Future<void> setDeleteBookAlert(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyDeleteBookAlert, value);
    } catch (e) {
      debugPrint('SettingsService.setDeleteBookAlert 异常: $e');
    }
  }

  // ===== 目录页加载字数（对齐原版 AppConfig.tocCountWords，默认开启） =====
  // [UI-fix v2.0.3 | 2026-08-08] 控制目录页章节字数显隐 — Qoder

  Future<bool> getTocLoadWordCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyTocLoadWordCount) ?? true;
    } catch (e) {
      debugPrint('SettingsService.getTocLoadWordCount 异常: $e');
      return true;
    }
  }

  Future<void> setTocLoadWordCount(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyTocLoadWordCount, value);
    } catch (e) {
      debugPrint('SettingsService.setTocLoadWordCount 异常: $e');
    }
  }

  // ===== 通用偏好读写助手 =====
  // [UI-fix v2.0.5 | 2026-08-08] 主题/其他设置页对齐原版新增大量键，
  // 提供按键名直接读写的通用助手，键名统一收敛在 PrefKeys 常量类 — Qoder

  /// 读取布尔偏好（键不存在时返回 [defaultValue]）
  Future<bool> getBoolPref(String key, {required bool defaultValue}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? defaultValue;
    } catch (e) {
      debugPrint('SettingsService.getBoolPref($key) 异常: $e');
      return defaultValue;
    }
  }

  /// 写入布尔偏好
  Future<void> setBoolPref(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      debugPrint('SettingsService.setBoolPref($key) 异常: $e');
    }
  }

  /// 读取整数偏好（键不存在时返回 [defaultValue]）
  Future<int> getIntPref(String key, {required int defaultValue}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(key) ?? defaultValue;
    } catch (e) {
      debugPrint('SettingsService.getIntPref($key) 异常: $e');
      return defaultValue;
    }
  }

  /// 写入整数偏好
  Future<void> setIntPref(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (e) {
      debugPrint('SettingsService.setIntPref($key) 异常: $e');
    }
  }

  /// 读取可空整数偏好（键不存在时返回 null，用于"未设置"语义，如自定义主题色）
  Future<int?> getIntPrefOrNull(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(key);
    } catch (e) {
      debugPrint('SettingsService.getIntPrefOrNull($key) 异常: $e');
      return null;
    }
  }

  /// 读取字符串偏好（键不存在时返回 [defaultValue]）
  Future<String> getStringPref(String key, {String defaultValue = ''}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key) ?? defaultValue;
    } catch (e) {
      debugPrint('SettingsService.getStringPref($key) 异常: $e');
      return defaultValue;
    }
  }

  // ===== 阅读记录（对齐 ReadRecordActivity） =====

  /// 是否启用阅读时长记录（默认 true）
  Future<bool> getEnableReadRecord() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyEnableReadRecord) ?? true;
    } catch (e) {
      debugPrint('SettingsService.getEnableReadRecord 异常: $e');
      return true;
    }
  }

  Future<void> setEnableReadRecord(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyEnableReadRecord, value);
    } catch (e) {
      debugPrint('SettingsService.setEnableReadRecord 异常: $e');
    }
  }

  /// 阅读记录排序：0=书名 1=时长 2=最后阅读（对齐 LocalConfig readRecordSort）
  Future<int> getReadRecordSort() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyReadRecordSort) ?? 0;
    } catch (e) {
      debugPrint('SettingsService.getReadRecordSort 异常: $e');
      return 0;
    }
  }

  Future<void> setReadRecordSort(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyReadRecordSort, value);
    } catch (e) {
      debugPrint('SettingsService.setReadRecordSort 异常: $e');
    }
  }

  // ===== 恢复忽略项（对齐 BackupConfig.restoreIgnore.json）=====

  /// 忽略键顺序与原版 [BackupConfig.ignoreKeys] 一致
  static const restoreIgnoreKeys = <String>[
    'readConfig',
    'themeMode',
    'themeConfig',
    'coverConfig',
    'bookshelfLayout',
    'showRss',
    'threadCount',
    'localBook',
  ];

  /// 忽略项标题（对齐 BackupConfig.ignoreTitle）
  static const restoreIgnoreTitles = <String>[
    '阅读界面配置',
    '主题模式',
    '主题配置',
    '封面规则',
    '书架布局',
    '显示订阅',
    '线程数',
    '本地书籍',
  ];

  static const _keyRestoreIgnore = 'restoreIgnore';

  /// 恢复忽略配置持久化键（供备份始终排除，避免恢复时覆盖本地忽略策略）
  static const restoreIgnoreStorageKey = _keyRestoreIgnore;

  /// 读取恢复忽略配置（缺省全 false）
  Future<Map<String, bool>> getRestoreIgnoreConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyRestoreIgnore);
      if (raw == null || raw.isEmpty) {
        return {for (final k in restoreIgnoreKeys) k: false};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return {for (final k in restoreIgnoreKeys) k: false};
      }
      return {
        for (final k in restoreIgnoreKeys)
          k: decoded[k] == true,
      };
    } catch (e) {
      debugPrint('SettingsService.getRestoreIgnoreConfig 异常: $e');
      return {for (final k in restoreIgnoreKeys) k: false};
    }
  }

  /// 持久化恢复忽略配置（对齐 BackupConfig.saveIgnoreConfig）
  Future<void> saveRestoreIgnoreConfig(Map<String, bool> config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalized = {
        for (final k in restoreIgnoreKeys) k: config[k] == true,
      };
      await prefs.setString(_keyRestoreIgnore, jsonEncode(normalized));
    } catch (e) {
      debugPrint('SettingsService.saveRestoreIgnoreConfig 异常: $e');
    }
  }

  /// 写入字符串偏好
  Future<void> setStringPref(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      debugPrint('SettingsService.setStringPref($key) 异常: $e');
    }
  }

  /// 移除偏好（恢复默认，对齐原版 removePref）
  Future<void> removePref(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (e) {
      debugPrint('SettingsService.removePref($key) 异常: $e');
    }
  }
}
