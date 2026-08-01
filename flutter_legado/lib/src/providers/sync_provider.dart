import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/book_api.dart';
import '../services/settings_service.dart';

/// 同步状态
enum SyncStatus { idle, syncing, success, error }

/// WebDAV 云同步状态管理
///
/// 对接真实的 BookApi WebDAV 契约（[BookApi.webdavFullSync] /
/// [BookApi.importBookSources]），对齐 Android 原版 BackupConfigFragment
/// 的 WebDAV 设置组（服务器地址/账号/密码/子目录/设备名/同步书籍进度）。
class SyncProvider extends ChangeNotifier {
  final BookApi _api;
  final SettingsService _settings = SettingsService();

  SyncProvider(this._api);

  SyncStatus _status = SyncStatus.idle;
  DateTime? _lastSyncTime;
  String? _error;
  bool _autoSync = false;

  // WebDAV 配置
  String _webDavUrl = '';
  String _webDavUsername = '';
  String _webDavPassword = '';
  String _remoteDir = '/legado/';
  String _deviceName = '';
  bool _syncBookProgress = true;
  bool _syncBookProgressPlus = false;

  // ===== Getters =====

  SyncStatus get status => _status;
  DateTime? get lastSyncTime => _lastSyncTime;
  String? get error => _error;
  bool get autoSync => _autoSync;
  String get webDavUrl => _webDavUrl;
  String get webDavUsername => _webDavUsername;
  String get webDavPassword => _webDavPassword;
  String get remoteDir => _remoteDir;
  String get deviceName => _deviceName;
  bool get syncBookProgress => _syncBookProgress;
  bool get syncBookProgressPlus => _syncBookProgressPlus;
  bool get isConfigured =>
      _webDavUrl.isNotEmpty &&
      _webDavUsername.isNotEmpty &&
      _webDavPassword.isNotEmpty;

  String get lastSyncTimeLabel {
    if (_lastSyncTime == null) return '从未同步';
    final now = DateTime.now();
    final diff = now.difference(_lastSyncTime!);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  /// 构建 Rust 侧 WebDavConfig 期望的 JSON（{url, username, password}）
  String buildConfigJson() => jsonEncode({
        'url': _webDavUrl,
        'username': _webDavUsername,
        'password': _webDavPassword,
      });

  // ===== 配置管理 =====

  /// 保存 WebDAV 配置
  Future<void> saveConfig(
    String url,
    String username,
    String password,
    String dir, {
    String deviceName = '',
  }) async {
    _webDavUrl = url.trim();
    _webDavUsername = username.trim();
    _webDavPassword = password;
    _remoteDir = dir.trim().isEmpty ? '/legado/' : dir.trim();
    _deviceName = deviceName.trim();
    await _settings.setWebDavUrl(_webDavUrl);
    await _settings.setWebDavUsername(_webDavUsername);
    await _settings.setWebDavPassword(_webDavPassword);
    await _settings.setWebDavRemoteDir(_remoteDir);
    await _settings.setWebDavDeviceName(_deviceName);
    notifyListeners();
  }

  /// 加载已保存的 WebDAV 配置
  Future<void> loadConfig() async {
    _webDavUrl = await _settings.getWebDavUrl();
    _webDavUsername = await _settings.getWebDavUsername();
    _webDavPassword = await _settings.getWebDavPassword();
    _remoteDir = await _settings.getWebDavRemoteDir();
    _deviceName = await _settings.getWebDavDeviceName();
    _syncBookProgress = await _settings.getSyncBookProgress();
    _syncBookProgressPlus = await _settings.getSyncBookProgressPlus();
    _autoSync = await _settings.getAutoSync();
    _lastSyncTime = await _settings.getLastSyncTime();
    notifyListeners();
  }

  /// 切换自动同步
  Future<void> toggleAutoSync(bool enabled) async {
    _autoSync = enabled;
    await _settings.setAutoSync(enabled);
    notifyListeners();
  }

  /// 设置「同步书籍进度」开关
  Future<void> setSyncBookProgress(bool enabled) async {
    _syncBookProgress = enabled;
    await _settings.setSyncBookProgress(enabled);
    notifyListeners();
  }

  /// 设置「同步书籍进度增强」开关
  Future<void> setSyncBookProgressPlus(bool enabled) async {
    _syncBookProgressPlus = enabled;
    await _settings.setSyncBookProgressPlus(enabled);
    notifyListeners();
  }

  // ===== 同步操作（真实 BookApi 调用） =====

  /// 备份到 WebDAV（上传本地书架 + 书源）
  ///
  /// 调用真实 [BookApi.webdavFullSync]，对齐原版 web_dav_backup。
  Future<void> backupToWebDav() async {
    if (!isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return;
    }
    _setStatus(SyncStatus.syncing);
    try {
      final (localBooks, localSources) = await _collectLocalData();
      await _api.webdavFullSync(buildConfigJson(), localBooks, localSources);
      await _markSyncSuccess();
    } catch (e) {
      _setError('备份失败: $e');
    }
  }

  /// 从 WebDAV 恢复（获取远端数据并回写书源）
  ///
  /// 调用真实 [BookApi.webdavFullSync] 取得远端合并数据，
  /// 书源经 [BookApi.importBookSources] 回写；书架批量回写受限于
  /// BookApi 暂无批量导入契约，登记为跨轨需求。
  /// 返回用于展示的结果描述。
  Future<String> restoreFromWebDav() async {
    if (!isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return '请先配置 WebDAV 服务器信息';
    }
    _setStatus(SyncStatus.syncing);
    try {
      final (localBooks, localSources) = await _collectLocalData();
      final result =
          await _api.webdavFullSync(buildConfigJson(), localBooks, localSources);
      var imported = 0;
      final remote = jsonDecode(result) as Map<String, dynamic>;
      final remoteSources = remote['sources']?.toString() ?? '';
      if (remoteSources.isNotEmpty && remoteSources != '[]') {
        imported = await _api.importBookSources(remoteSources);
      }
      await _markSyncSuccess();
      return '恢复完成，回写 $imported 条书源';
    } catch (e) {
      _setError('恢复失败: $e');
      return '恢复失败: $e';
    }
  }

  // ===== Internal helpers =====

  /// 序列化本地书架 + 书源为 JSON（供 webdavFullSync 上传）
  Future<(String, String)> _collectLocalData() async {
    final books = await _api.getBooks();
    final sources = await _api.getBookSources();
    final localBooks = jsonEncode(books.map((e) => e.toJson()).toList());
    final localSources = jsonEncode(sources.map((e) => e.toJson()).toList());
    return (localBooks, localSources);
  }

  Future<void> _markSyncSuccess() async {
    _lastSyncTime = DateTime.now();
    await _settings.setLastSyncTime(_lastSyncTime!);
    _status = SyncStatus.success;
    _error = null;
    notifyListeners();
  }

  void _setStatus(SyncStatus status) {
    _status = status;
    _error = null;
    notifyListeners();
  }

  void _setError(String message) {
    _status = SyncStatus.error;
    _error = message;
    notifyListeners();
    debugPrint('SyncProvider 错误: $message');
  }
}
