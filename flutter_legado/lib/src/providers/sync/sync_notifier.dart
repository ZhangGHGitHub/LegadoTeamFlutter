import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../services/settings_service.dart';
import '../providers.dart';
import 'sync_state.dart';

export 'sync_state.dart';

/// WebDAV 云同步 Riverpod Notifier
///
/// 对接真实的 BookApi WebDAV 契约（webdavFullSync / importBookSources），
/// 对齐 Android 原版 BackupConfigFragment 的 WebDAV 设置组
/// （服务器地址/账号/密码/子目录/设备名/同步书籍进度）。
class SyncNotifier extends Notifier<SyncState> {
  final SettingsService _settings = SettingsService();

  @override
  SyncState build() {
    // 原 SyncProvider 构造不自动加载，配置由页面 initState 触发 loadConfig()
    return const SyncState();
  }

  /// 远端子目录（保证以 '/' 结尾；Rust WebDavClient 拼接
  /// full_url = url + remote_dir + path，直接拼接 path）
  /// [Task #52 | 2026-08-10] — Qoder
  String get normalizedRemoteDir {
    final dir = state.remoteDir.isEmpty ? '/legado/' : state.remoteDir;
    return dir.endsWith('/') ? dir : '$dir/';
  }

  /// 构建 Rust 侧 WebDavConfig 期望的 JSON（{url, username, password, remote_dir}）
  ///
  /// [Task #52 | 2026-08-10] 补齐 remote_dir（legado-net WebDavConfig 必需字段，
  /// 缺失会导致 Rust 侧配置解析失败） — Qoder
  String buildConfigJson() => jsonEncode({
        'url': state.webDavUrl,
        'username': state.webDavUsername,
        'password': state.webDavPassword,
        'remote_dir': normalizedRemoteDir,
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
    final webDavUrl = url.trim();
    final webDavUsername = username.trim();
    final remoteDir = dir.trim().isEmpty ? '/legado/' : dir.trim();
    final device = deviceName.trim();
    state = state.copyWith(
      webDavUrl: webDavUrl,
      webDavUsername: webDavUsername,
      webDavPassword: password,
      remoteDir: remoteDir,
      deviceName: device,
    );
    await _settings.setWebDavUrl(webDavUrl);
    await _settings.setWebDavUsername(webDavUsername);
    await _settings.setWebDavPassword(password);
    await _settings.setWebDavRemoteDir(remoteDir);
    await _settings.setWebDavDeviceName(device);
  }

  /// 加载已保存的 WebDAV 配置
  Future<void> loadConfig() async {
    state = state.copyWith(
      webDavUrl: await _settings.getWebDavUrl(),
      webDavUsername: await _settings.getWebDavUsername(),
      webDavPassword: await _settings.getWebDavPassword(),
      remoteDir: await _settings.getWebDavRemoteDir(),
      deviceName: await _settings.getWebDavDeviceName(),
      syncBookProgress: await _settings.getSyncBookProgress(),
      syncBookProgressPlus: await _settings.getSyncBookProgressPlus(),
      autoSync: await _settings.getAutoSync(),
      lastSyncTime: await _settings.getLastSyncTime(),
    );
  }

  /// 切换自动同步
  Future<void> toggleAutoSync(bool enabled) async {
    state = state.copyWith(autoSync: enabled);
    await _settings.setAutoSync(enabled);
  }

  /// 设置「同步书籍进度」开关
  Future<void> setSyncBookProgress(bool enabled) async {
    state = state.copyWith(syncBookProgress: enabled);
    await _settings.setSyncBookProgress(enabled);
  }

  /// 设置「同步书籍进度增强」开关
  Future<void> setSyncBookProgressPlus(bool enabled) async {
    state = state.copyWith(syncBookProgressPlus: enabled);
    await _settings.setSyncBookProgressPlus(enabled);
  }

  // ===== 同步操作（真实 BookApi 调用） =====

  /// 备份到 WebDAV（上传本地书架 + 书源）
  ///
  /// 调用真实 webdavFullSync，对齐原版 web_dav_backup。
  Future<void> backupToWebDav() async {
    if (!state.isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return;
    }
    _setStatus(SyncStatus.syncing);
    try {
      final api = ref.read(bookApiProvider);
      final (localBooks, localSources) = await _collectLocalData();
      await api.webdavFullSync(buildConfigJson(), localBooks, localSources);
      await _markSyncSuccess();
    } catch (e) {
      _setError('备份失败: $e');
    }
  }

  /// 从 WebDAV 恢复（获取远端数据并回写书源）
  ///
  /// 调用真实 webdavFullSync 取得远端合并数据，书源经 importBookSources 回写；
  /// 书架批量回写受限于 BookApi 暂无批量导入契约，登记为跨轨需求。
  /// 返回用于展示的结果描述。
  Future<String> restoreFromWebDav() async {
    if (!state.isConfigured) {
      _setError('请先配置 WebDAV 服务器信息');
      return '请先配置 WebDAV 服务器信息';
    }
    _setStatus(SyncStatus.syncing);
    try {
      final api = ref.read(bookApiProvider);
      final (localBooks, localSources) = await _collectLocalData();
      final result =
          await api.webdavFullSync(buildConfigJson(), localBooks, localSources);
      var imported = 0;
      final remote = jsonDecode(result) as Map<String, dynamic>;
      final remoteSources = remote['sources']?.toString() ?? '';
      if (remoteSources.isNotEmpty && remoteSources != '[]') {
        imported = await api.importBookSources(remoteSources);
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
    final api = ref.read(bookApiProvider);
    final books = await api.getBooks();
    final sources = await api.getBookSources();
    final localBooks = jsonEncode(books.map((e) => e.toJson()).toList());
    final localSources = jsonEncode(sources.map((e) => e.toJson()).toList());
    return (localBooks, localSources);
  }

  Future<void> _markSyncSuccess() async {
    final now = DateTime.now();
    state = state.copyWith(
      lastSyncTime: now,
      status: SyncStatus.success,
      error: null,
    );
    await _settings.setLastSyncTime(now);
  }

  void _setStatus(SyncStatus status) {
    state = state.copyWith(status: status, error: null);
  }

  void _setError(String message) {
    state = state.copyWith(status: SyncStatus.error, error: message);
    debugPrint('SyncNotifier 错误: $message');
  }
}

/// WebDAV 云同步 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(syncNotifierProvider);
/// ref.read(syncNotifierProvider.notifier).backupToWebDav();
/// ```
final syncNotifierProvider = NotifierProvider<SyncNotifier, SyncState>(
  SyncNotifier.new,
);
