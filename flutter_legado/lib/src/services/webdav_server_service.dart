import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'book_api.dart';
import 'settings_service.dart';

/// WebDAV 同步服务器配置（DB `servers` 表 `id = -1` 行的视图）
///
/// 对齐原版 `Server` 实体 + `Server.WebDavConfig`：url/username/password
/// 存于 `config` JSON 字符串；子目录与设备名不属于 servers 列（原版
/// `AppConfig.webDavDir` 亦为偏好），继续由 [SettingsService] 承载。
@immutable
class WebDavSyncServerConfig {
  const WebDavSyncServerConfig({
    this.id = WebDavServerService.defaultServerId,
    this.url = '',
    this.username = '',
    this.password = '',
  });

  /// servers 表主键（固定 -1 = 默认 WebDAV，对齐原版 DEFAULT_WEBDAV_ID）
  final int id;
  final String url;
  final String username;
  final String password;

  bool get isEmpty => url.isEmpty && username.isEmpty && password.isEmpty;

  /// Rust `WebDavConfig` 期望的 JSON（含 remote_dir 由调用方补齐）
  Map<String, dynamic> toConfigJson() => {
        'url': url,
        'username': username,
        'password': password,
      };
}

/// servers 表 WebDAV 同步配置读写 + 一次性偏好迁移
///
/// 背景（批8 用户裁决②）：原版 servers 表承载服务器配置、备份 zip 含
/// `servers.json`；我方此前把 WebDAV 同步账号存在 Flutter 偏好
/// （`sync_webdav_url/username/password`）。本服务把该配置收敛到 DB：
/// - 读取：`webdavServersList` 中找 `id = -1` 的 WEBDAV 行；
/// - 写入：`webdavServerSave`（全字段 upsert，固定 id/name/type）；
/// - 迁移：DB 无该行且迁移标记未置时，把旧偏好一次性写入 DB 并置标记
///   `webdav_servers_migrated`（幂等；旧偏好保留，不再参与读写）。
///
/// 单实现原则：所有 servers 表访问都经 [BookApi] 的 §2.28 三方法，
/// 不在 Flutter 侧另写持久化。
class WebDavServerService {
  WebDavServerService({
    required BookApi api,
    SettingsService? settings,
  })  : _api = api,
        _settings = settings ?? SettingsService();

  final BookApi _api;
  final SettingsService _settings;

  /// 默认 WebDAV 同步服务器主键（对齐原版 `AppConst.DEFAULT_WEBDAV_ID`）
  static const int defaultServerId = -1;

  /// 默认 WebDAV 同步服务器显示名（迁移首次写入）
  static const String defaultServerName = '默认 WebDAV';

  /// 一次性迁移标记（写入 DB 成功后置位；之后即使 DB 行被删也不重复迁移）
  static const String migratedPrefKey = 'webdav_servers_migrated';

  /// 读取同步服务器配置；必要时执行一次性 prefs → DB 迁移
  ///
  /// - DB 已有 `id = -1` 行：直接返回（忽略旧偏好）；
  /// - 无该行且迁移标记未置：旧偏好非空则写入 DB 并置标记（返回新配置）；
  ///   旧偏好为空则不写、不置标记（后续若从旧备份恢复出偏好，仍可迁移）；
  /// - 无该行且标记已置：返回空配置（一次性语义，不再回读偏好）。
  Future<WebDavSyncServerConfig> loadSyncServer() async {
    final servers = await _listServers();
    final existing = _findDefault(servers);
    if (existing != null) return _parseConfig(existing);
    if (await _isMigrated()) return const WebDavSyncServerConfig();

    final legacy = WebDavSyncServerConfig(
      url: await _settings.getWebDavUrl(),
      username: await _settings.getWebDavUsername(),
      password: await _settings.getWebDavPassword(),
    );
    if (legacy.isEmpty) return const WebDavSyncServerConfig();

    final saved = await saveSyncServer(
      url: legacy.url,
      username: legacy.username,
      password: legacy.password,
    );
    await _markMigrated();
    return saved;
  }

  /// 写入同步服务器配置（全字段 upsert），返回落库配置
  ///
  /// 保留既有行的 `name` / `sortNumber`（未来自建服务器改名/排序不被同步
  /// 设置覆盖）；无既有行时使用默认名与 sortNumber=0。
  Future<WebDavSyncServerConfig> saveSyncServer({
    required String url,
    required String username,
    required String password,
  }) async {
    final normalizedUrl = url.trim();
    final normalizedUsername = username.trim();
    final servers = await _listServers();
    final existing = _findDefault(servers);
    final serverJson = jsonEncode({
      'id': defaultServerId,
      'name': existing?.name ?? defaultServerName,
      'type': 'WEBDAV',
      'config': jsonEncode({
        'url': normalizedUrl,
        'username': normalizedUsername,
        'password': password,
      }),
      'sortNumber': existing?.sortNumber ?? 0,
    });
    final id = await _api.webdavServerSave(serverJson);
    if (id != defaultServerId) {
      // 不静默吞掉主键漂移：固定 id 写入却得到其他 id 说明契约实现异常
      throw StateError('servers 保存返回 id=$id，期望 $defaultServerId');
    }
    await _markMigrated();
    return WebDavSyncServerConfig(
      id: id,
      url: normalizedUrl,
      username: normalizedUsername,
      password: password,
    );
  }

  Future<List<_ServerRow>> _listServers() async {
    final raw = await _api.webdavServersList();
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw FormatException('webdavServersList 返回非 JSON 数组: $raw');
    }
    return decoded
        .whereType<Map>()
        .map((e) => _ServerRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  _ServerRow? _findDefault(List<_ServerRow> servers) {
    for (final server in servers) {
      if (server.id == defaultServerId) return server;
    }
    return null;
  }

  WebDavSyncServerConfig _parseConfig(_ServerRow server) {
    var url = '';
    var username = '';
    var password = '';
    final rawConfig = server.config;
    if (rawConfig != null && rawConfig.trim().isNotEmpty) {
      final decoded = jsonDecode(rawConfig);
      if (decoded is Map) {
        url = _stringValue(decoded['url']);
        username = _stringValue(decoded['username']);
        password = _stringValue(decoded['password']);
      } else {
        // 形态不符必须显式（防复发规定 4）：config 非对象不静默当空配置
        throw FormatException('servers.config 非 JSON 对象: $rawConfig');
      }
    }
    return WebDavSyncServerConfig(
      id: server.id,
      url: url,
      username: username,
      password: password,
    );
  }

  static String _stringValue(Object? value) => value?.toString() ?? '';

  Future<bool> _isMigrated() =>
      _settings.getBoolPref(migratedPrefKey, defaultValue: false);

  Future<void> _markMigrated() => _settings.setBoolPref(migratedPrefKey, true);
}

/// servers 表原始行（仅保留本服务消费的字段）
class _ServerRow {
  const _ServerRow({
    required this.id,
    required this.name,
    required this.config,
    required this.sortNumber,
  });

  final int id;
  final String name;
  final String? config;
  final int sortNumber;

  factory _ServerRow.fromJson(Map<String, dynamic> json) => _ServerRow(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        config: json['config']?.toString(),
        sortNumber: (json['sortNumber'] as num?)?.toInt() ?? 0,
      );
}
