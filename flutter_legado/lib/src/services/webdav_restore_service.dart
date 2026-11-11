// 批10：WebDAV 备份恢复链（下载 → 探测 → 偏好回填 → 恢复 → 账号/服务器
// 迁移 → 刷新），供设置页本地恢复与启动自动检查共用。
//
// 背景：
// - 设置页原有恢复链（`webdav_settings_screen.dart` 的
//   `_performLocalRestoreLocked`）包含 zip/json 分流、恢复忽略、旧备份
//   WebDAV 账号回填、旧远程书库强制迁移等步骤；启动自动检查需要同一套
//   语义，不能复制第二份实现；
// - 自动检查先经 `webdavDownloadFile` 把远端备份落到临时目录（文件名保留
//   远端名与 `.json`/`.zip` 后缀，Rust 依赖后缀/魔数分流），整链（下载 +
//   探测 + 恢复）跑在 `LocalBackupService.runExclusiveRestore` 内，与备份
//   互斥；临时文件在 finally 删除；
// - 需要密码的 zip 在探测阶段返回 [WebDavRestoreStatus.passwordRequired] 与
//   探测信息；设置页网络恢复据此弹密码框，用户输入后携带 `password` 再次
//   调用本链完成恢复。启动自动检查不使用该交互，仍按「需用户手动处理」处理
//   （差异已登记）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/backup_inspect_info.dart';
import '../models/book.dart';
import 'book_api.dart';
import 'local_backup_service.dart';
import 'restore_ignore_prefs.dart';
import 'server_service.dart';
import 'settings_service.dart';
import 'webdav_backup_service.dart';
import 'webdav_server_service.dart';

/// 备份密码相关错误码前缀（契约 §2.11 批17a）
///
/// 后端以 `LegadoError::Internal` 返回，Display 形如
/// `Internal error: BACKUP_PASSWORD_INVALID: ...`，调用方必须按「包含」
/// 前缀识别，不能按字符串起始位置判断。
const String kBackupPasswordRequiredCode = 'BACKUP_PASSWORD_REQUIRED';
const String kBackupPasswordInvalidCode = 'BACKUP_PASSWORD_INVALID';
const String kBackupEncryptedContentCorruptCode =
    'BACKUP_ENCRYPTED_CONTENT_CORRUPT';

/// 自动恢复结果状态
enum WebDavRestoreStatus {
  /// 恢复成功（调用方提示「恢复成功」）
  success,

  /// 已有备份/恢复执行中，本次未执行（调用方提示稍候，不得提示成功）
  busy,

  /// 备份需要密码：不自动恢复，调用方提示前往备份恢复页手动处理
  passwordRequired,

  /// 恢复失败（[WebDavRestoreRunResult.error] 为原始异常）
  failed,
}

/// 自动恢复整链结果
@immutable
class WebDavRestoreRunResult {
  const WebDavRestoreRunResult._(this.status, this.error, this.inspect);

  const WebDavRestoreRunResult.success()
    : this._(WebDavRestoreStatus.success, null, null);

  const WebDavRestoreRunResult.busy()
    : this._(WebDavRestoreStatus.busy, null, null);

  /// [inspect] 为探测结果，调用方弹密码框时需要受保护条目清单；旧调用方
  /// 可不传（仅用于测试构造）。
  const WebDavRestoreRunResult.passwordRequired([BackupInspectInfo? inspect])
    : this._(WebDavRestoreStatus.passwordRequired, null, inspect);

  const WebDavRestoreRunResult.failed(Object error)
    : this._(WebDavRestoreStatus.failed, error, null);

  /// 结果状态
  final WebDavRestoreStatus status;

  /// 失败异常（仅 [WebDavRestoreStatus.failed]）
  final Object? error;

  /// zip 密码探测结果（仅 [WebDavRestoreStatus.passwordRequired]）
  final BackupInspectInfo? inspect;
}

/// 本地恢复链（无 UI，调用方负责提示与页面刷新）
class WebDavRestoreService {
  WebDavRestoreService({
    required BookApi api,
    SettingsService? settings,
    LocalBackupService? backupService,
    WebDavBackupService? webDavBackupService,
    Directory Function()? tempDirProvider,
  }) : _api = api,
       _settings = settings ?? SettingsService(),
       _backupService = backupService ?? LocalBackupService.instance,
       _webDavBackup =
           webDavBackupService ??
           WebDavBackupService(api: api, settings: settings),
       _tempDirProvider = tempDirProvider ?? (() => Directory.systemTemp);

  final BookApi _api;
  final SettingsService _settings;
  final LocalBackupService _backupService;
  final WebDavBackupService _webDavBackup;
  final Directory Function() _tempDirProvider;

  /// 判定备份文件是不是原版 zip 备份（扩展名快判 + **文件魔数**）
  ///
  /// 只看扩展名会把「zip 改名 `.json`」误判为自有 JSON 备份：不探测密码
  /// → 直接恢复 → 后端因加密内容要求密码 → 用户看不到密码框。魔数口径与
  /// Rust `is_zip_backup` 一致（`PK\x03\x04` 普通条目 / `PK\x05\x06` 空
  /// zip）；读取失败（文件不存在/权限）按非 zip 处理，由后续恢复流程给出
  /// 统一错误。
  static bool isZipBackupFile(String path) {
    if (path.toLowerCase().endsWith('.zip')) return true;
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      final head = file.readSync(4);
      if (head.length < 4) return false;
      return head[0] == 0x50 &&
          head[1] == 0x4B &&
          ((head[2] == 0x03 && head[3] == 0x04) ||
              (head[2] == 0x05 && head[3] == 0x06));
    } catch (_) {
      return false;
    } finally {
      try {
        file?.closeSync();
      } catch (_) {
        // 关闭失败不影响判定结果
      }
    }
  }

  /// 下载远端备份到独立临时目录，文件名保留远端名（含 `.json`/`.zip`）
  ///
  /// 远端名必须是**单段文件名**：含 `/`、`\` 或 `..` 的 displayname 直接
  /// 拒绝（防目录穿越），不做静默截断。失败时删除刚创建的临时目录后原样
  /// 上抛，避免残留半截文件。
  Future<String> downloadRemoteBackup({
    required String configJson,
    required String remoteName,
  }) async {
    if (remoteName.contains('/') ||
        remoteName.contains('\\') ||
        remoteName.contains('..')) {
      throw const FormatException('远端备份文件名无效');
    }
    final safeName = _sanitizeFileName(remoteName);
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      throw const FormatException('远端备份文件名无效');
    }
    final base = _tempDirProvider();
    final dir = await Directory(
      '${base.path}${Platform.pathSeparator}'
      'legado_webdav_restore_'
      '${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final path = '${dir.path}${Platform.pathSeparator}$safeName';
    try {
      // 下载路径使用远端原始名（含子目录时由 Rust 拼 remote_dir），
      // 本地落盘名只做非法字符替换，扩展名保持不变。
      await _api.webdavDownloadFile(configJson, remoteName, path);
      return path;
    } catch (_) {
      await _deleteTempDir(dir);
      rethrow;
    }
  }

  /// 自动检查整链：下载 → 探测 → 恢复，独占备份/恢复互斥锁
  ///
  /// - [configJson] 由调用方预解析（自动检查已为列目录读取过，避免重复读
  ///   DB）；为空时自行解析，未配置 WebDAV 按失败处理；
  /// - 需要密码的 zip 且未提供 [password] 时，在探测阶段返回
  ///   [WebDavRestoreStatus.passwordRequired]（携带探测信息），不调用 restore
  ///   （零写入）；调用方弹密码框后携带 [password] 再次调用本方法即可完成
  ///   恢复。自动检查不传 password，行为不变（不自动恢复）；
  /// - 临时目录/文件在 finally 删除；
  /// - [refresh] 恢复成功后调用（全局 provider 重读），异常向上抛给调用方
  ///   判定为恢复失败。
  Future<WebDavRestoreRunResult> restoreRemoteBackupExclusive({
    required String remoteName,
    String? configJson,
    String? password,
    Future<void> Function()? refresh,
  }) async {
    final result = await _backupService
        .runExclusiveRestore<WebDavRestoreRunResult>(() async {
          String? downloadedPath;
          try {
            final config =
                configJson ?? await _webDavBackup.resolveConfigJson();
            if (config == null) {
              throw StateError('未配置 WebDAV');
            }
            downloadedPath = await downloadRemoteBackup(
              configJson: config,
              remoteName: remoteName,
            );
            final isZip = isZipBackupFile(downloadedPath);
            if (isZip) {
              final inspect = await _api.backupInspect(downloadedPath);
              if (inspect.passwordRequired && password == null) {
                return WebDavRestoreRunResult.passwordRequired(inspect);
              }
            }
            await restoreBackupFile(
              downloadedPath,
              // JSON 备份没有密码语义；仅 zip 容器透传（防御误传）。
              password: isZip ? password : null,
              isZipContainer: isZip,
              refresh: refresh,
            );
            return const WebDavRestoreRunResult.success();
          } catch (e, stack) {
            // 静默失败：只记录异常类型与栈，不打印 URL/凭据等敏感信息
            debugPrint(
              '[WebDavRestoreService] 远端备份恢复失败（${e.runtimeType}）:\n$stack',
            );
            return WebDavRestoreRunResult.failed(e);
          } finally {
            final path = downloadedPath;
            if (path != null) {
              await _deleteTempDir(File(path).parent);
            }
          }
        });
    return result ?? const WebDavRestoreRunResult.busy();
  }

  /// 执行恢复全链（偏好回填 + 业务表恢复 + 服务器迁移 + 刷新）
  ///
  /// **调用方须自行持有** `LocalBackupService` 的备份/恢复互斥锁（设置页
  /// 经 `runExclusiveRestore`；自动检查经
  /// [restoreRemoteBackupExclusive]）。异常原样上抛，调用方负责提示。
  ///
  /// [password] 仅对原版 zip 备份生效；JSON 备份传 null。
  /// [isZipContainer] 容器判定结果（调用方已按文件魔数算好）；缺省时此处
  /// 现算。zip 容器**不做** JSON 偏好/账号回读（zip 备份没有 `appPrefs`
  /// 段，按 `.json` 扩展名硬读会把压缩字节当 JSON 解析）。
  Future<void> restoreBackupFile(
    String backupPath, {
    String? password,
    bool? isZipContainer,
    Future<void> Function()? refresh,
  }) async {
    final isZip = isZipContainer ?? isZipBackupFile(backupPath);
    var pathToRestore = backupPath;
    File? filteredFile;
    final accountSource = isZip
        ? WebDavBackupAccountSource.none
        : await WebDavServerService.backupAccountSource(backupPath);
    final ignore = await _settings.getRestoreIgnoreConfig();
    try {
      if (ignore['localBook'] == true && !isZip) {
        filteredFile = await _writeJsonSkippingLocalBooks(backupPath);
        if (filteredFile != null) pathToRestore = filteredFile.path;
      }

      final serverService = ServerService(api: _api, settings: _settings);
      // 批18a：远程书库服务器密码以 servers 表为准；恢复旧备份时按 DB
      // 既有 id / url+username 保留本机密码（读失败退回旧偏好，不阻断恢复）
      LocalServerPasswordIndex? localPasswords;
      if (!isZip) {
        try {
          localPasswords = await serverService.localPasswordIndex();
        } catch (e) {
          debugPrint('读取本机服务器密码索引失败（退回旧偏好）：$e');
        }
      }

      if (!isZip) {
        await RestoreIgnorePrefs.applyAppPrefsFromBackupFile(
          backupPath,
          ignore,
          localPasswordsById: localPasswords?.byId,
          localPasswordsByEndpoint: localPasswords?.byEndpoint,
        );
      }
      await _api.restore(pathToRestore, password: password);
      // 偏好已由上面写回本地；v1/v2 备份把恢复所得账号显式覆盖到 DB
      // （v3 交由恢复器写入的 servers 行，不回读偏好）
      if (accountSource == WebDavBackupAccountSource.legacyPrefs) {
        await WebDavServerService(
          api: _api,
          settings: _settings,
        ).applyLegacyPrefsOverwrite();
      }
      // 批18a：旧格式备份（无 servers 段或仅 id=-1）携带 remote_servers 时，
      // 恢复后强制重跑一次 prefs → servers 表迁移。失败由
      // [ServerService.forceMigrateAfterRestore] 记崩溃日志并复位迁移标记
      //（下次启动重试）；取舍说明见该方法注释。
      if (!isZip &&
          await ServerService.backupNeedsLegacyRemoteServerMigration(
            backupPath,
          )) {
        await serverService.forceMigrateAfterRestore();
      }
      // 批10 审查回修 P1：refresh（provider 重读）发生在恢复成功之后，
      // 其失败不得把已落库的恢复改判为失败——否则用户看到「恢复失败」，
      // 且自动检查已写入 seen、本次进程不会再提示。这里只记日志。
      if (refresh != null) {
        try {
          await refresh();
        } catch (e, stack) {
          debugPrint('[WebDavRestoreService] 恢复成功但刷新失败（不改变结果）：$e\n$stack');
        }
      }
    } finally {
      // 恢复忽略「本地书籍」时写入的临时 JSON 必须清理，避免路径泄露与
      // 磁盘残留；删除失败不影响恢复结果。
      final filtered = filteredFile;
      if (filtered != null) {
        try {
          if (await filtered.exists()) await filtered.delete();
        } catch (e) {
          debugPrint('[WebDavRestoreService] 删除临时过滤备份失败（忽略）：$e');
        }
      }
    }
  }

  /// 写出剔除「本地书籍」的临时 JSON（恢复忽略 `localBook` 时）
  ///
  /// 判定与备份侧 `_filterLocalBooksIfNeeded` 一致：按 origin 的本地前缀
  /// 或 `BookType.local` 位判定。临时文件保留 `.json` 后缀供 Rust 分流。
  /// 无需过滤（非对象 / 无 books 列表）时返回 null，调用方不得删除原文件。
  Future<File?> _writeJsonSkippingLocalBooks(String backupPath) async {
    final raw = await File(backupPath).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final books = decoded['books'];
    if (books is! List) return null;

    decoded['books'] = books.where((item) {
      if (item is! Map) return true;
      final origin = item['origin']?.toString() ?? '';
      final type = item['type'];
      final typeInt = type is int ? type : int.tryParse('$type') ?? 0;
      final isLocal =
          BookType.isLocalOrigin(origin) || (typeInt & BookType.local) != 0;
      return !isLocal;
    }).toList();

    final base = _tempDirProvider();
    final out = File(
      '${base.path}${Platform.pathSeparator}'
      'legado_restore_no_local_'
      '${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await out.writeAsString(jsonEncode(decoded));
    return out;
  }

  /// 远端文件名转本地落盘名：取末段并替换路径非法字符，保留扩展名
  static String _sanitizeFileName(String remoteName) {
    final segments = remoteName
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return '';
    return segments.last.replaceAll(RegExp(r'[:*?"<>|]'), '_');
  }

  /// 删除临时目录（只处理文件名带本服务前缀的目录，防误删）
  static Future<void> _deleteTempDir(Directory dir) async {
    try {
      // Directory.uri 对目录会带尾斜杠，pathSegments 末尾是空串；过滤后
      // 再取最后一段才是真实目录名（Windows/Linux 一致）。
      final segments = dir.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      final name = segments.isEmpty ? '' : segments.last;
      if (!name.startsWith('legado_webdav_restore_') &&
          !name.startsWith('legado_restore_no_local_')) {
        return;
      }
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[WebDavRestoreService] 清理临时文件失败（忽略）：$e');
    }
  }
}
