import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'book_api.dart';
import 'crash_log_service.dart';
import 'settings_service.dart';

/// 远程书库服务器行（servers 表，`type = WEBDAV`）
///
/// 对齐原版 `Server` 实体 + `Server.WebDavConfig`：url/username/password 存于
/// `config` JSON 字符串；[isValid] 表示该行 config 是否可解析为可用配置。
/// **单行 config 非法只标记该行无效**（[isValid] = false），不拖垮整页。
class RemoteBookServerRow {
  const RemoteBookServerRow({
    required this.id,
    required this.name,
    required this.url,
    required this.username,
    required this.password,
    required this.sortNumber,
    required this.isValid,
  });

  final int id;
  final String name;
  final String url;
  final String username;
  final String password;
  final int sortNumber;

  /// config 可解析且 type 为 WEBDAV；false 时 url/username/password 均为空串
  final bool isValid;

  factory RemoteBookServerRow.fromJson(Map<String, dynamic> json) {
    // 主键/名称/排序为契约保证字段：形态不符显式报错（防复发规定 4，
    // 不静默兜底成 0 / ''）；仅 config 按需求做单行容错。
    final id = switch (json['id']) {
      final num value => value.toInt(),
      final other => throw FormatException('servers 行 id 形态不符: $other'),
    };
    final name = switch (json['name']) {
      final String value => value,
      final other => throw FormatException('servers 行 name 形态不符: $other'),
    };
    final sortNumber = switch (json['sortNumber']) {
      final num value => value.toInt(),
      final other =>
        throw FormatException('servers 行 sortNumber 形态不符: $other'),
    };
    final type = switch (json['type']) {
      final String value => value,
      final other => throw FormatException('servers 行 type 形态不符: $other'),
    };
    // config 按需求做单行容错：非字符串（如数字）同样只标记该行无效
    final rawConfig = json['config'];
    final configIsString = rawConfig == null || rawConfig is String;

    var isValid = type == 'WEBDAV' && configIsString;
    var url = '';
    var username = '';
    var password = '';
    if (isValid && rawConfig is String && rawConfig.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawConfig);
        if (decoded is Map) {
          url = _stringValue(decoded['url']);
          username = _stringValue(decoded['username']);
          password = _stringValue(decoded['password']);
        } else {
          isValid = false;
        }
      } catch (e) {
        // 单行 config 损坏只标记该行无效：远程书库页仍可展示/编辑/删除
        debugPrint('ServerService: servers 行 id=$id config 解析失败: $e');
        isValid = false;
      }
    } else if (isValid) {
      // config 缺失/空白：无可用 WebDAV 配置
      isValid = false;
    }
    // url 为空（如 config="{}"）同样视为无效：否则页面会展示一条无法列举
    // 目录的「可用」服务器，选中后才在 refresh 阶段报错
    if (isValid && url.trim().isEmpty) isValid = false;

    return RemoteBookServerRow(
      id: id,
      name: name,
      url: url,
      username: username,
      password: password,
      sortNumber: sortNumber,
      isValid: isValid,
    );
  }

  static String _stringValue(Object? value) => value?.toString() ?? '';
}

/// 本机既有服务器密码索引（恢复旧备份时按 id / url+username 取回本机密码）
class LocalServerPasswordIndex {
  const LocalServerPasswordIndex({
    this.byId = const {},
    this.byEndpoint = const {},
  });

  final Map<int, String> byId;
  final Map<String, String> byEndpoint;

  static String endpointKey(Object? url, Object? username) =>
      '${url ?? ''}\u0000${username ?? ''}';
}

/// 远程书库服务器读写服务（servers 表 §2.28 三方法的唯一业务入口）
///
/// 与 [WebDavServerService] 的分工：
/// - `WebDavServerService` 服务**同步账号**（`id = -1`），对整表形态严格
///   （任何异常行都抛错，避免同步配置静默丢失），语义被既有测试钉死；
/// - 本服务服务**远程书库列表**（`id > 0`），按批18a 要求对单行 config
///   做容错（非法行标记 [RemoteBookServerRow.isValid] = false），避免一条
///   坏数据导致整页不可用。两者共用同一组 FFI（§2.28），不新增契约。
///
/// 一次性迁移（`remote_servers` 旧偏好 → servers 表）：
/// - 标记键 [migratedPrefKey] 默认 false；非数组/解析失败/字段形态非法不置标记（下次重试）；
/// - 跳过 `id < 0`（`-1` 为默认 WebDAV 固定身份）；正数 id 原样保留；
///   重复 id 的后续条目重新分配（id = 0），重试时**可能复用上次已分配的行**；
/// - 密码：prefs 有值用 prefs；为空时按 DB 同 id 行保留既有密码；
/// - 全部成功才置标记；同 id REPLACE 保证幂等；
/// - 旧键 `remote_servers` / `remote_server_id` **保留不删**（回滚安全）。
class ServerService {
  ServerService({
    required BookApi api,
    SettingsService? settings,
  })  : _api = api,
        _settings = settings ?? SettingsService();

  final BookApi _api;
  final SettingsService _settings;

  /// 默认 WebDAV 同步账号主键（对齐原版 `AppConst.DEFAULT_WEBDAV_ID`）
  static const int defaultServerId = -1;

  /// 一次性迁移标记（全部条目写入 DB 后置位）
  static const String migratedPrefKey = 'remote_servers_migrated';

  /// 旧偏好键（仅迁移读取；保留不删，便于回滚）
  static const String legacyPrefKey = SettingsService.remoteServersKey;

  /// 列出 servers 表全部行（含 `id = -1` 与无效行；调用方自行过滤）
  ///
  /// 整表形态异常（非 JSON 数组 / 元素非对象 / 契约字段缺失）显式报错；
  /// 单行 config 非法只标记该行 [RemoteBookServerRow.isValid] = false。
  Future<List<RemoteBookServerRow>> listServers() async {
    final raw = await _api.webdavServersList();
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw FormatException('webdavServersList 返回非 JSON 数组: $raw');
    }
    final rows = <RemoteBookServerRow>[];
    for (var i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map) {
        throw FormatException('webdavServersList 第 $i 项不是 JSON 对象: $item');
      }
      rows.add(RemoteBookServerRow.fromJson(Map<String, dynamic>.from(item)));
    }
    return rows;
  }

  /// 保存服务器（新建或编辑），返回落库结果
  ///
  /// - `id` 为正数：原样保留（编辑），并沿用既有 `sortNumber`；
  /// - `id` 为 0 / 缺省：交给 Rust 按当前毫秒分配；
  /// - `id < 0`（默认 WebDAV）：拒绝，远程书库不得覆盖同步账号。
  Future<RemoteBookServerRow> saveServer({
    int? id,
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    final targetId = id ?? 0;
    if (targetId < 0) {
      throw ArgumentError.value(
        id,
        'id',
        '默认 WebDAV（id=-1）不可经远程书库编辑',
      );
    }
    var sortNumber = 0;
    if (targetId > 0) {
      final existing = await _findById(targetId);
      sortNumber = existing?.sortNumber ?? 0;
    }
    return _writeServer(
      targetId: targetId,
      name: name,
      url: url,
      username: username,
      password: password,
      sortNumber: sortNumber,
    );
  }

  /// 实际落库（[sortNumber] 由调用方给定）
  ///
  /// 拆分原因（批18a 审查回修 P3）：迁移循环已持有整表快照，若逐台走
  /// [saveServer] 会为取 sortNumber 再查一次全表，N 台即 O(N²)。
  Future<RemoteBookServerRow> _writeServer({
    required int targetId,
    required String name,
    required String url,
    required String username,
    required String password,
    required int sortNumber,
  }) async {
    if (targetId < 0) {
      throw ArgumentError.value(
        targetId,
        'id',
        '默认 WebDAV（id=-1）不可经远程书库编辑',
      );
    }
    final normalizedName = name.trim();
    final normalizedUrl = url.trim();
    final normalizedUsername = username.trim();
    final serverJson = jsonEncode({
      'id': targetId,
      'name': normalizedName,
      'type': 'WEBDAV',
      'config': jsonEncode({
        'url': normalizedUrl,
        'username': normalizedUsername,
        'password': password,
      }),
      'sortNumber': sortNumber,
    });
    final savedId = await _api.webdavServerSave(serverJson);
    return RemoteBookServerRow(
      id: savedId,
      name: normalizedName,
      url: normalizedUrl,
      username: normalizedUsername,
      password: password,
      sortNumber: sortNumber,
      isValid: true,
    );
  }

  /// 删除服务器（`id = -1` 永不删除）
  Future<bool> deleteServer(int id) async {
    if (id < 0) {
      throw ArgumentError.value(id, 'id', '默认 WebDAV（id=-1）不可删除');
    }
    return _api.webdavServerDelete(id);
  }

  /// 本机既有服务器密码索引（按 id / url+username），供旧备份恢复保留密码
  Future<LocalServerPasswordIndex> localPasswordIndex() async {
    final rows = await listServers();
    final byId = <int, String>{};
    final byEndpoint = <String, String>{};
    for (final row in rows) {
      if (row.password.isEmpty) continue;
      byId[row.id] = row.password;
      byEndpoint[LocalServerPasswordIndex.endpointKey(row.url, row.username)] =
          row.password;
    }
    return LocalServerPasswordIndex(byId: byId, byEndpoint: byEndpoint);
  }

  /// 一次性迁移 `remote_servers` 旧偏好 → servers 表
  ///
  /// [force] = true 时忽略迁移标记（恢复旧格式备份后重跑）。返回是否真正
  /// 执行并成功置标记（标记已置且非 force → false）。写入异常向上抛，调用方
  /// 自行决定是否阻断（启动期只记崩溃日志；恢复流程只记日志不阻断）。
  Future<bool> migrateLegacyPrefs({bool force = false}) async {
    if (!force && await _isMigrated()) return false;
    final entries = await _readLegacyEntries();
    // 非数组/元素非对象/字段形态非法：不置标记，下次启动重试
    if (entries == null) return false;

    final dbRows = await listServers();
    final dbById = <int, RemoteBookServerRow>{
      for (final row in dbRows) row.id: row,
    };
    final keptIds = <int>{};
    final reusedIds = <int>{};

    for (final entry in entries) {
      // -1（及其他负数）为默认 WebDAV 固定身份，不迁移
      if (entry.id < 0) continue;

      var id = entry.id;
      if (id > 0 && keptIds.contains(id)) {
        debugPrint(
          'ServerService: remote_servers 存在重复 id=${entry.id}，'
          '后续条目重新分配主键（重试时可能复用上次分配行）',
        );
        id = 0;
      }
      if (id > 0) keptIds.add(id);

      // 密码：prefs 有值用 prefs；为空时按 DB 同 id 行保留既有密码
      var password = entry.password;
      if (password.isEmpty) {
        password = dbById[entry.id]?.password ?? '';
      }

      if (id == 0) {
        // 幂等加固：上次迁移中断留下的分配行（同端点+同名）优先复用，
        // 避免重复 id 条目在重试时不断产生新行
        final reusable = _findReusableRow(
          dbRows,
          entry,
          excludedIds: {...keptIds, ...reusedIds},
        );
        if (reusable != null) {
          id = reusable.id;
          reusedIds.add(id);
          if (password.isEmpty) password = reusable.password;
        }
      }

      // 直接复用本次已读的整表快照取 sortNumber，避免逐台再查全表（O(N²)）
      await _writeServer(
        targetId: id,
        name: entry.name,
        url: entry.url,
        username: entry.username,
        password: password,
        sortNumber: dbById[id]?.sortNumber ?? 0,
      );
    }

    await _markMigrated();
    return true;
  }

  /// 恢复旧格式备份后的强制迁移（`webdav_settings_screen` 接线）
  ///
  /// 失败时写 [CrashLogService] 并**把迁移标记复位 false**，让下次启动重试，
  /// 而不是让「标记已置」永久掩盖失败（旧实现只 debugPrint，失败后永不重试）。
  ///
  /// 取舍：复位标记会让下次启动重新读取旧偏好 `remote_servers` 并写回
  /// servers 表；若用户在迁移成功后又删除了某些服务器，旧偏好里仍保留的
  /// 条目会被「复活」。相较静默永久丢失远程书库配置，选择可重试 + 日志可查。
  Future<bool> forceMigrateAfterRestore() async {
    try {
      return await migrateLegacyPrefs(force: true);
    } catch (e, stack) {
      CrashLogService.instance.logError(e, stack);
      debugPrint('ServerService.forceMigrateAfterRestore 失败，'
          '复位迁移标记待下次启动重试：$e');
      await _settings.setBoolPref(migratedPrefKey, false);
      return false;
    }
  }

  /// 判定旧格式备份恢复后是否需要强制重跑远程书库迁移
  ///
  /// 条件（仅 `.json` 备份）：`appPrefs` 携带 `remote_servers`，且备份的
  /// `servers` 段缺失或仅含负数 id（`-1` 默认 WebDAV）——此时远程书库列表
  /// 只存在于旧偏好中，恢复后必须再迁一次。zip 备份由 Rust 恢复 servers，
  /// 不走本判定。
  static Future<bool> backupNeedsLegacyRemoteServerMigration(
    String backupPath,
  ) async {
    if (!backupPath.toLowerCase().endsWith('.json')) return false;
    try {
      final decoded = jsonDecode(await File(backupPath).readAsString());
      if (decoded is! Map) return false;
      final appPrefs = decoded['appPrefs'];
      if (appPrefs is! Map || !appPrefs.containsKey(legacyPrefKey)) {
        return false;
      }
      // 旧偏好必须可解析为对象数组：形态非法时恢复侧不会写 prefs，
      // 此处也不得强制迁移（否则会把设备上的旧 prefs 覆盖回 DB）
      final legacyValue = appPrefs[legacyPrefKey];
      Object? legacyDecoded = legacyValue;
      if (legacyDecoded is String) {
        legacyDecoded = jsonDecode(legacyDecoded);
      }
      if (legacyDecoded is! List) return false;
      for (final item in legacyDecoded) {
        if (item is! Map) return false;
      }
      final servers = decoded['servers'];
      if (servers == null) return true;
      if (servers is! List) return false;
      for (final row in servers) {
        if (row is Map) {
          final id = (row['id'] as num?)?.toInt() ?? 0;
          if (id >= 0) return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('ServerService.backupNeedsLegacyRemoteServerMigration 异常: $e');
      return false;
    }
  }

  Future<RemoteBookServerRow?> _findById(int id) async {
    final rows = await listServers();
    for (final row in rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  /// 迁移幂等辅助：按端点 + 名称匹配上次中断留下的分配行
  ///
  /// 两侧统一 trim 后比较：旧偏好里的 name/url/username 可能带首尾空格，
  /// 而落库时已被 trim；不归一会在重试时匹配不上，导致重复新增行。
  RemoteBookServerRow? _findReusableRow(
    List<RemoteBookServerRow> rows,
    _LegacyServerEntry entry, {
    required Set<int> excludedIds,
  }) {
    final name = entry.name.trim();
    final endpoint = LocalServerPasswordIndex.endpointKey(
      entry.url.trim(),
      entry.username.trim(),
    );
    for (final row in rows) {
      if (row.id <= 0 || excludedIds.contains(row.id)) continue;
      if (row.name.trim() != name) continue;
      if (LocalServerPasswordIndex.endpointKey(
            row.url.trim(),
            row.username.trim(),
          ) !=
          endpoint) {
        continue;
      }
      return row;
    }
    return null;
  }

  /// 解析旧偏好列表；非数组/元素非对象/字段形态非法 → null（不置标记）
  Future<List<_LegacyServerEntry>?> _readLegacyEntries() async {
    final raw = await _settings.getRemoteServersJson();
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! List) return null;
    final out = <_LegacyServerEntry>[];
    for (final item in decoded) {
      if (item is! Map) return null;
      final map = Map<String, dynamic>.from(item);
      final name = _strictString(map['name']);
      final url = _strictString(map['url']);
      final username = _strictString(map['username']);
      final password = _strictString(map['password']);
      if (name == null || url == null || username == null || password == null) {
        return null;
      }
      // id 显式判型：缺省/null 视为 0（新建），非数字（如 "abc"）属形态非法，
      // 返回 null 且不置标记（旧实现强转 num 会抛 TypeError，每次启动重试都崩）
      final rawId = map['id'];
      final int id;
      if (rawId == null) {
        id = 0;
      } else if (rawId is num) {
        id = rawId.toInt();
      } else {
        return null;
      }
      out.add(_LegacyServerEntry(
        id: id,
        name: name,
        url: url,
        username: username,
        password: password,
      ));
    }
    return out;
  }

  static String? _strictString(Object? value) {
    if (value == null) return '';
    return value is String ? value : null;
  }

  Future<bool> _isMigrated() =>
      _settings.getBoolPref(migratedPrefKey, defaultValue: false);

  Future<void> _markMigrated() => _settings.setBoolPref(migratedPrefKey, true);
}

/// 旧偏好条目（`{id,name,url,username,password}`）
class _LegacyServerEntry {
  const _LegacyServerEntry({
    required this.id,
    required this.name,
    required this.url,
    required this.username,
    required this.password,
  });

  final int id;
  final String name;
  final String url;
  final String username;
  final String password;
}
