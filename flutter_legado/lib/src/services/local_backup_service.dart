// 批40：本地备份执行 + 手动/自动互斥（对齐原版 Backup.backupLocked /
// autoBackupLocked 共用的 backupRestoreMutex）
//
// 职责：
// - 统一「创建本地 JSON 备份 → 注入 appPrefs → 过滤本地书（可选）→
//   可选上传 WebDAV → 写 lastBackup」链路，手动备份与自动备份共用，
//   避免两套实现漂移；
// - 进程内互斥锁：同一时刻只允许一次备份（手动点击与自动调度并发时后者
//   直接跳过，不排队），对齐原版 `backupRestoreLocked`；
// - 上传失败不回滚本地备份，也不阻止 `lastBackup` 更新（本地备份已成功），
//   失败原因交由调用方提示/记日志。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../constants/pref_keys.dart';
import '../models/book.dart';
import 'book_api.dart';
import 'restore_ignore_prefs.dart';
import 'settings_service.dart';
import 'webdav_backup_service.dart';

/// 本地备份结果
@immutable
class LocalBackupResult {
  const LocalBackupResult({
    required this.filePath,
    this.upload,
    this.uploadError,
    this.uploadSkipped = false,
  });

  /// 本地备份文件绝对路径
  final String filePath;

  /// WebDAV 上传结果（null = 未上传；见 [uploadError]/[uploadSkipped]）
  final WebDavBackupUploadResult? upload;

  /// 上传异常（本地备份仍成功）
  final Object? uploadError;

  /// 本次按开关未上传（或未配置 WebDAV）
  final bool uploadSkipped;

  bool get uploaded => upload != null;
}

/// 本地备份服务（互斥 + 统一备份链路）
///
/// 批40 回修 P2-2：互斥语义扩展为「备份/恢复共用」——恢复（WebDAV 短按
/// 同步、本地长按恢复）也会写库，与自动备份并发会互相覆盖；恢复期间
/// 自动备份必须按 busy 返回（对齐原版共用 `backupRestoreLocked`）。
class LocalBackupService {
  /// 公共构造仅用于测试替身（互斥锁为**全局静态**，所有实例共享；
  /// 生产代码一律经 [instance] 使用单例）
  LocalBackupService({Future<void> Function(File file)? deleteFileForTest})
    : _deleteFile = deleteFileForTest;

  /// 测试注入：模拟旧备份删除失败（生产为 null，走 File.delete）
  final Future<void> Function(File file)? _deleteFile;

  /// 全局单例（手动入口与自动调度必须共用同一把锁）
  static final LocalBackupService instance = LocalBackupService();

  /// 进程内互斥标志（Dart 单线程事件循环保证读写原子性）
  static bool _running = false;

  /// 恢复进行中标志（与 [_running] 共用忙碌语义）
  static bool _restoring = false;

  /// 是否有备份正在执行
  static bool get isRunning => _running;

  /// 是否有恢复正在执行
  static bool get isRestoring => _restoring;

  /// 是否有备份或恢复正在执行（自动备份需据此返回 busy）
  static bool get isBusy => _running || _restoring;

  /// 测试用：复位互斥标志（生产代码不得调用）
  @visibleForTesting
  static void resetForTest() {
    _running = false;
    _restoring = false;
  }

  /// 在互斥锁内执行 [action]
  ///
  /// - 已有备份/恢复在执行：返回 `null`（**不排队**，对齐原版重复触发跳过）；
  /// - [action] 抛出的异常原样上抛，锁在 finally 中释放。
  Future<T?> runExclusive<T>(Future<T> Function() action) async {
    if (isBusy) {
      debugPrint('[LocalBackupService] 已有备份/恢复执行中，跳过本次备份触发');
      return null;
    }
    _running = true;
    try {
      return await action();
    } finally {
      _running = false;
    }
  }

  /// 在「恢复」互斥内执行 [action]（批40 回修 P2-2）
  ///
  /// 与 [runExclusive] 共用忙碌判定：备份进行中时恢复直接返回 `null`
  /// （调用方提示稍候）；恢复进行中时自动备份/手动备份同样返回 `null`。
  Future<T?> runExclusiveRestore<T>(Future<T> Function() action) async {
    if (isBusy) {
      debugPrint('[LocalBackupService] 已有备份/恢复执行中，跳过本次恢复触发');
      return null;
    }
    _restoring = true;
    try {
      return await action();
    } finally {
      _restoring = false;
    }
  }

  /// 创建一次本地备份（调用方须自行持有 [runExclusive] 锁）
  ///
  /// [uploadWebDav] 为 true 时尝试上传；未配置 WebDAV 时静默跳过
  /// （[LocalBackupResult.uploadSkipped]），上传失败记录在
  /// [LocalBackupResult.uploadError]，均不影响本地备份成功。
  ///
  /// `lastBackup` 在 `api.backup` 成功返回后写入（上传失败不回退：本地
  /// 备份已成功，下一次周期再补传；本地备份失败则异常上抛、不写入）。
  Future<LocalBackupResult> createBackup({
    required BookApi api,
    required String dirPath,
    required bool uploadWebDav,
    SettingsService? settings,
    WebDavBackupService? webDavBackupService,
    DateTime? now,
  }) async {
    final s = settings ?? SettingsService();
    final filePath = await api.backup(dirPath);

    // 与手动入口一致：把 appPrefs 注入 JSON 备份（备份忽略项过滤）。
    // [批8a] 备份忽略与恢复忽略为两份独立配置：备份侧只看 backupIgnore；
    // 恢复侧仍用 restoreIgnore。
    final ignore = await s.getBackupIgnoreConfig();
    await RestoreIgnorePrefs.injectAppPrefsIntoBackupFile(filePath, ignore);
    // [批8a 回修 P2-1] 「本地书籍」在恢复侧由 UI 预过滤备份 JSON；备份侧
    // 同样需在上传前剔除，否则本地路径会随 WebDAV 备份外泄。失败必须
    // fail-closed：删除未过滤文件并上抛，UI 显示备份失败。
    await _filterLocalBooksIfNeeded(filePath: filePath, ignore: ignore);

    WebDavBackupUploadResult? upload;
    Object? uploadError;
    var uploadSkipped = !uploadWebDav;
    if (uploadWebDav) {
      final service =
          webDavBackupService ?? WebDavBackupService(api: api, settings: s);
      try {
        upload = await service.uploadBackup(localFilePath: filePath, now: now);
        if (upload == null) uploadSkipped = true;
      } catch (e) {
        // 上传失败不阻断本地备份成功提示（对齐原版 runCatching 语义）
        uploadError = e;
        debugPrint('[LocalBackupService] WebDAV 备份上传失败: $e');
      }
    }

    // [批8a] 仅保留最新本地备份：上传尝试结束后再清理（上传失败也已
    // catch，仍执行），避免影响上传；清理失败只记日志，不影响备份成功。
    await _pruneOldLocalBackups(dirPath: dirPath, currentPath: filePath, s: s);

    await s.setLastBackupTime((now ?? DateTime.now()).millisecondsSinceEpoch);
    return LocalBackupResult(
      filePath: filePath,
      upload: upload,
      uploadError: uploadError,
      uploadSkipped: uploadSkipped,
    );
  }

  /// 备份忽略「本地书籍」：剔除 JSON `books` 中的本地书
  ///
  /// 判定与恢复侧 `_backupPathSkippingLocalBooks` 一致。启用时失败必须
  /// fail-closed：删除未过滤备份并上抛，避免本地路径随上传外泄。
  Future<void> _filterLocalBooksIfNeeded({
    required String filePath,
    required Map<String, bool> ignore,
  }) async {
    if (ignore['localBook'] != true) return;
    if (!filePath.toLowerCase().endsWith('.json')) return;

    final file = File(filePath);
    final tmp = File('$filePath.filtering.tmp');
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('备份 JSON 顶层不是对象');
      }
      final books = decoded['books'];
      if (books is List) {
        decoded['books'] = books.where((item) {
          if (item is! Map) return true;
          final origin = item['origin']?.toString() ?? '';
          final type = item['type'];
          final typeInt = type is int ? type : int.tryParse('$type') ?? 0;
          final isLocal =
              BookType.isLocalOrigin(origin) || (typeInt & BookType.local) != 0;
          return !isLocal;
        }).toList();
        await tmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(decoded),
          flush: true,
        );
        try {
          await tmp.rename(filePath);
        } on FileSystemException {
          // Windows 部分文件系统不允许 rename 覆盖既有文件；先删再改名。
          if (await file.exists()) await file.delete();
          await tmp.rename(filePath);
        }
      }
    } catch (e) {
      debugPrint('[LocalBackupService] 备份本地书过滤失败，删除未过滤文件: $e');
      for (final f in [tmp, file]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {
          // fail-closed 清理由后续错误提示兜底，删除失败不掩盖原异常
        }
      }
      throw StateError('备份本地书过滤失败，已取消本次备份');
    }
  }

  /// 仅上传到 WebDAV 的备份（批11：备份 Sheet「备份至网络」）
  ///
  /// 与「本地 + WebDAV」的区别：本地只作为上传中转，**不写用户备份目录**，
  /// 也不受「仅保留最新备份」影响——
  /// 1. 先确认 WebDAV 已配置（未配置直接抛 [StateError]，不创建临时文件）；
  /// 2. 在系统临时目录创建隔离目录，调用 [createBackup]（uploadWebDav=true）；
  /// 3. 上传失败/未上传视为本次备份失败（异常上抛，调用方提示「备份失败」），
  ///    并回滚 `lastBackup`，避免失败的「仅网络」推迟自动备份周期；
  /// 4. 无论成功失败，finally 删除临时目录（含本次备份文件）。
  ///
  /// 成功返回上传结果（远端文件名供调用方提示）；`lastBackup` 由
  /// [createBackup] 在本地备份成功后写入，成功路径保留。
  Future<WebDavBackupUploadResult> createBackupToWebDavOnly({
    required BookApi api,
    SettingsService? settings,
    WebDavBackupService? webDavBackupService,
    DateTime? now,
    Directory Function()? tempDirProvider,
  }) async {
    final s = settings ?? SettingsService();
    final service =
        webDavBackupService ?? WebDavBackupService(api: api, settings: s);
    // 先确认配置：未配置时既不应该生成临时备份，也不应该写 lastBackup
    if (await service.resolveConfigJson() == null) {
      throw StateError('未配置 WebDAV');
    }

    final base = (tempDirProvider ?? () => Directory.systemTemp)();
    final sep = Platform.pathSeparator;
    final dir = await Directory(
      '${base.path}$sep$_webDavOnlyTempPrefix'
      '${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final previousLastBackup = await s.getLastBackupTime();
    try {
      final result = await createBackup(
        api: api,
        settings: s,
        dirPath: dir.path,
        uploadWebDav: true,
        webDavBackupService: service,
        now: now,
      );
      // 「仅网络」下上传失败 = 备份失败（与「本地+WebDAV」的宽容语义不同）
      final uploadError = result.uploadError;
      if (uploadError != null) {
        await s.setLastBackupTime(previousLastBackup);
        throw uploadError;
      }
      final upload = result.upload;
      if (upload == null) {
        await s.setLastBackupTime(previousLastBackup);
        throw StateError('未配置 WebDAV');
      }
      return upload;
    } finally {
      await _deleteTempDir(dir);
    }
  }

  /// 系统临时目录前缀（仅清理本方法创建的目录）
  static const String _webDavOnlyTempPrefix = 'legado_webdav_only_';

  /// 删除本服务创建的临时目录（前缀不匹配时不删，防误删）
  ///
  /// 进程被强杀时 finally 不会执行；失败日志保留完整路径前缀
  /// `legado_webdav_only_`，供后续启动清扫任务定位残留（清扫实现本批只
  /// 登记、不实现）。
  static Future<void> _deleteTempDir(Directory dir) async {
    try {
      final segments = dir.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      final name = segments.isEmpty ? '' : segments.last;
      if (!name.startsWith(_webDavOnlyTempPrefix)) return;
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint(
        '[LocalBackupService] 清理仅网络备份临时目录失败'
        '（忽略，待清扫路径=${dir.path}）：$e',
      );
    }
  }

  /// 查找备份目录内最新的本地备份文件（批11「本地最新」快捷恢复）
  ///
  /// 口径与「仅保留最新」共用 [_localBackupName]：只认
  /// `legado_backup_<millis>.json`（大小写敏感、仅直接子文件、不递归），
  /// 取文件名中 millis 最大者；目录不存在/空串/无匹配返回 null。
  /// 目录列举失败向上抛（调用方按恢复失败提示）。
  static Future<String?> findLatestLocalBackup(String dirPath) async {
    final trimmed = dirPath.trim();
    if (trimmed.isEmpty) return null;
    final dir = Directory(trimmed);
    if (!await dir.exists()) return null;

    String? latestPath;
    var latestMillis = -1;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final segments = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      final name = segments.isEmpty ? '' : segments.last;
      final match = _localBackupName.firstMatch(name);
      if (match == null) continue;
      final millis = int.tryParse(match.group(1)!);
      if (millis == null) continue;
      if (millis > latestMillis) {
        latestMillis = millis;
        latestPath = entity.path;
      }
    }
    return latestPath;
  }

  /// 本地备份命名（Dart `RustApi.backup` 生成：`legado_backup_<millis>.json`）
  static final RegExp _localBackupName = RegExp(r'^legado_backup_(\d+)\.json$');

  /// 仅保留最新本地备份（对齐原版 `Backup.kt:435-439`）
  ///
  /// - 开关 `onlyLatestBackup` 默认 true；
  /// - 只匹配本项目命名 `legado_backup_<数字>.json`（大小写敏感、仅直接
  ///   子文件、不递归），保留本次 [currentPath]，其余删除；
  /// - 按文件名比较，避免目录尾分隔符导致路径字符串不等而误删本次备份；
  /// - 失败只 debugPrint，不影响备份成功。
  Future<void> _pruneOldLocalBackups({
    required String dirPath,
    required String currentPath,
    required SettingsService s,
  }) async {
    try {
      final onlyLatest = await s.getBoolPref(
        PrefKeys.onlyLatestBackup,
        defaultValue: true,
      );
      if (!onlyLatest) return;
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      final currentName = File(currentPath).uri.pathSegments.isEmpty
          ? ''
          : File(currentPath).uri.pathSegments.last;

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (!_localBackupName.hasMatch(name)) continue;
        if (name == currentName) continue;
        try {
          await (_deleteFile ?? (file) => file.delete())(entity);
        } catch (e) {
          debugPrint('[LocalBackupService] 删除旧备份失败（忽略）: $e');
        }
      }
    } catch (e) {
      debugPrint('[LocalBackupService] 清理旧本地备份失败（忽略）: $e');
    }
  }
}
