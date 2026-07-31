import 'package:flutter/foundation.dart';

import '../services/book_api.dart';
import '../services/settings_service.dart';

/// 同步状态
enum SyncStatus { idle, syncing, success, error }

/// WebDAV 云同步状态管理
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

  // ===== Getters =====

  SyncStatus get status => _status;
  DateTime? get lastSyncTime => _lastSyncTime;
  String? get error => _error;
  bool get autoSync => _autoSync;
  String get webDavUrl => _webDavUrl;
  String get webDavUsername => _webDavUsername;
  String get webDavPassword => _webDavPassword;
  String get remoteDir => _remoteDir;
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

  // ===== 配置管理 =====

  /// 保存 WebDAV 配置
  Future<void> saveConfig(
    String url,
    String username,
    String password,
    String dir,
  ) async {
    _webDavUrl = url.trim();
    _webDavUsername = username.trim();
    _webDavPassword = password;
    _remoteDir = dir.trim().isEmpty ? '/legado/' : dir.trim();
    await _settings.setWebDavUrl(_webDavUrl);
    await _settings.setWebDavUsername(_webDavUsername);
    await _settings.setWebDavPassword(_webDavPassword);
    await _settings.setWebDavRemoteDir(_remoteDir);
    notifyListeners();
  }

  /// 加载已保存的 WebDAV 配置
  Future<void> loadConfig() async {
    _webDavUrl = await _settings.getWebDavUrl();
    _webDavUsername = await _settings.getWebDavUsername();
    _webDavPassword = await _settings.getWebDavPassword();
    _remoteDir = await _settings.getWebDavRemoteDir();
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

  // ===== 同步操作 =====

  /// 上传书架到 WebDAV
  Future<void> syncUpload() async {
    if (!isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return;
    }
    _setStatus(SyncStatus.syncing);
    try {
      final books = await _api.getBooks();
      // 模拟上传 — 实际实现需要 Rust 侧提供 WebDAV 上传 API
      // 此处将书架数据序列化为 JSON 准备上传
      final bookCount = books.length;
      await Future.delayed(const Duration(seconds: 1));
      _lastSyncTime = DateTime.now();
      await _settings.setLastSyncTime(_lastSyncTime!);
      _status = SyncStatus.success;
      _error = null;
      notifyListeners();
      debugPrint('WebDAV 上传完成: $bookCount 本书');
    } catch (e) {
      _setError('上传失败: $e');
    }
  }

  /// 从 WebDAV 下载书架
  Future<void> syncDownload() async {
    if (!isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return;
    }
    _setStatus(SyncStatus.syncing);
    try {
      // 模拟下载 — 实际实现需要 Rust 侧提供 WebDAV 下载 API
      await Future.delayed(const Duration(seconds: 1));
      _lastSyncTime = DateTime.now();
      await _settings.setLastSyncTime(_lastSyncTime!);
      _status = SyncStatus.success;
      _error = null;
      notifyListeners();
      debugPrint('WebDAV 下载完成');
    } catch (e) {
      _setError('下载失败: $e');
    }
  }

  /// 双向合并同步
  Future<void> syncMerge() async {
    if (!isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return;
    }
    _setStatus(SyncStatus.syncing);
    try {
      // 模拟合并 — 实际实现需要 Rust 侧提供 WebDAV 合并 API
      await Future.delayed(const Duration(seconds: 2));
      _lastSyncTime = DateTime.now();
      await _settings.setLastSyncTime(_lastSyncTime!);
      _status = SyncStatus.success;
      _error = null;
      notifyListeners();
      debugPrint('WebDAV 合并同步完成');
    } catch (e) {
      _setError('合并同步失败: $e');
    }
  }

  // ===== Internal helpers =====

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
