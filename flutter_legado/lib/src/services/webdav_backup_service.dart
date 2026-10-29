// 批40：WebDAV 备份上传 + 保留数清理（对齐原版 AppWebDav.backUpWebDav /
// pruneOldBackups）
//
// 与本仓库既有 `SyncNotifier.backupToWebDav`（上传 bookshelf.json + sources.json
// 的全量同步）不同：本服务上传的是**本次本地备份文件本身**，与设置页「备份」
// 入口语义对齐（原版 web_dav_backup 上传 zip 备份）。
//
// 格式差异（已登记 docs/API_CONTRACT.md §2.28 批40 注）：原版/参考版备份是
// `backup<yyyy-MM-dd>[-<设备名>].zip`，我方是单文件 JSON；远端命名取
// `backup_yyyyMMdd_HHmmss_SSS.json`（毫秒段用于同秒去重，批40 回修 P3-9；
// 本地文件名保持 `legado_backup_<millis>.json` 不变），保留数清理只处理
// `backup_yyyyMMdd_HHmmss[_SSS].json`（大小写敏感），不触碰远端
// `backup*.zip` 与其它文件。
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/book.dart' show BookType;
import 'book_api.dart';
import 'settings_service.dart';
import 'webdav_server_service.dart';

/// 远端备份文件名前缀（对齐原版 `displayName.startsWith("backup")`）
const String kWebDavBackupPrefix = 'backup';

/// 单份备份删除失败项（`webdavPruneBackups` 返回的 `failed` 元素）
@immutable
class WebDavBackupPruneFailure {
  const WebDavBackupPruneFailure({required this.name, required this.error});

  /// 备份文件名（相对 remote_dir 根目录）
  final String name;

  /// 失败原因（Rust 侧中文文案/HTTP 状态码）
  final String error;

  @override
  String toString() => '$name: $error';
}

/// 备份保留清理结果
@immutable
class WebDavBackupPruneResult {
  const WebDavBackupPruneResult({
    this.deleted = const [],
    this.failed = const [],
  });

  static const empty = WebDavBackupPruneResult();

  /// 实际删除的文件名
  final List<String> deleted;

  /// 删除失败清单（仅日志用途）
  final List<WebDavBackupPruneFailure> failed;

  bool get isEmpty => deleted.isEmpty && failed.isEmpty;

  /// 解析 Rust `BackupPruneResult` JSON（形态不符/非法 JSON 返回 [empty]，
  /// 不抛错）
  factory WebDavBackupPruneResult.fromJsonString(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return empty;
    }
    if (decoded is! Map) return empty;
    final deletedRaw = decoded['deleted'];
    final failedRaw = decoded['failed'];
    return WebDavBackupPruneResult(
      deleted: deletedRaw is List
          ? deletedRaw.map((e) => '$e').toList(growable: false)
          : const [],
      failed: failedRaw is List
          ? failedRaw
              .whereType<Map>()
              .map(
                (e) => WebDavBackupPruneFailure(
                  name: '${e['name'] ?? ''}',
                  error: '${e['error'] ?? ''}',
                ),
              )
              .toList(growable: false)
          : const [],
    );
  }
}

/// 备份上传结果
@immutable
class WebDavBackupUploadResult {
  const WebDavBackupUploadResult({
    required this.remoteFileName,
    this.prune = WebDavBackupPruneResult.empty,
    this.pruneError,
  });

  /// 远端备份文件名（`backup_yyyyMMdd_HHmmss.json`）
  final String remoteFileName;

  /// 保留数清理结果
  final WebDavBackupPruneResult prune;

  /// 清理异常（列出失败等）；仅日志用途，不影响上传成功判定
  final Object? pruneError;
}

/// WebDAV 备份上传与历史备份清理
///
/// - [uploadBackup]：上传本地备份文件；未配置 WebDAV 返回 null（跳过）；
///   上传失败向上抛（调用方提示）；上传成功后按「WebDAV 备份保留数量」
///   清理历史备份，清理失败只记日志（[WebDavBackupUploadResult.pruneError]）。
/// - [resolveConfigJson]：从 DB `servers` 表默认行 + 子目录偏好构造
///   `WebDavConfig` JSON（与 `SyncNotifier.buildConfigJson` 同形）。
class WebDavBackupService {
  WebDavBackupService({
    required BookApi api,
    SettingsService? settings,
  })  : _api = api,
        _settings = settings ?? SettingsService();

  final BookApi _api;
  final SettingsService _settings;

  /// 构造远端备份文件名：`backup_yyyyMMdd_HHmmss_SSS.json`
  ///
  /// 名称即时间序（保留数清理按名称降序 = 时间降序）。
  ///
  /// 批40 回修 P3-9：原命名精确到秒，同一秒内连续两次备份（手动紧接着
  /// 自动/连点）会覆盖同一远端文件；追加毫秒段去重。Rust 清理侧同时接受
  /// 无毫秒的旧命名（`backup_yyyyMMdd_HHmmss.json`）。
  static String buildRemoteFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    final millis = now.millisecond.toString().padLeft(3, '0');
    return '${kWebDavBackupPrefix}_'
        '${now.year.toString().padLeft(4, '0')}'
        '${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}_$millis.json';
  }

  /// 从默认 WebDAV 配置构造 Rust `WebDavConfig` JSON
  ///
  /// 返回 null 表示未配置（url 为空）。配置读取失败向上抛（调用方按
  /// 「上传失败」处理并提示）。
  Future<String?> resolveConfigJson() async {
    final server = await WebDavServerService(
      api: _api,
      settings: _settings,
    ).loadSyncServer();
    if (server.url.trim().isEmpty) return null;
    final config = BookType.normalizeWebDavConfig(
      server.url,
      await _settings.getWebDavRemoteDir(),
    );
    return jsonEncode({
      'url': config.url,
      'username': server.username,
      'password': server.password,
      'remote_dir': config.remoteDir,
    });
  }

  /// 上传本地备份文件并按保留数清理历史备份
  ///
  /// 返回 null = 未配置 WebDAV，本次跳过（不视为失败）。
  Future<WebDavBackupUploadResult?> uploadBackup({
    required String localFilePath,
    DateTime? now,
  }) async {
    final configJson = await resolveConfigJson();
    if (configJson == null) {
      debugPrint('[WebDavBackupService] 未配置 WebDAV，跳过备份上传');
      return null;
    }

    final remoteFileName = buildRemoteFileName(now ?? DateTime.now());
    // 上传失败向上抛：调用方负责提示，且不得吞掉本地备份成功结果
    await _api.webdavUploadFile(configJson, remoteFileName, localFilePath);

    final keepCount = await _settings.getWebDavBackupKeepCount();
    WebDavBackupPruneResult prune = WebDavBackupPruneResult.empty;
    Object? pruneError;
    if (keepCount > 0) {
      try {
        prune = await pruneBackups(
          configJson: configJson,
          currentFileName: remoteFileName,
          keepCount: keepCount,
        );
      } catch (e) {
        // 对齐原版：清理失败只记日志，不影响备份/上传本身
        pruneError = e;
        debugPrint('[WebDavBackupService] 清理旧备份失败: $e');
      }
    }
    return WebDavBackupUploadResult(
      remoteFileName: remoteFileName,
      prune: prune,
      pruneError: pruneError,
    );
  }

  /// 调用 Rust 清理历史备份（`keepCount = 0` 时 Rust 侧直接返回空结果）
  Future<WebDavBackupPruneResult> pruneBackups({
    required String configJson,
    required String currentFileName,
    required int keepCount,
  }) async {
    final raw = await _api.webdavPruneBackups(
      configJson,
      currentFileName,
      keepCount,
    );
    final result = WebDavBackupPruneResult.fromJsonString(raw);
    if (result.deleted.isNotEmpty || result.failed.isNotEmpty) {
      debugPrint(
        '[WebDavBackupService] 清理备份 keep=$keepCount '
        '删除=${result.deleted} 失败=${result.failed}',
      );
    }
    return result;
  }
}
