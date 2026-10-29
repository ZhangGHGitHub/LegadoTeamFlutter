// 批40：本地备份执行 + 手动/自动互斥（对齐原版 Backup.backupLocked /
// autoBackupLocked 共用的 backupRestoreMutex）
//
// 职责：
// - 统一「创建本地 JSON 备份 → 注入 appPrefs → 可选上传 WebDAV → 写
//   lastBackup」链路，手动备份与自动备份共用，避免两套实现漂移；
// - 进程内互斥锁：同一时刻只允许一次备份（手动点击与自动调度并发时后者
//   直接跳过，不排队），对齐原版 `backupRestoreLocked`；
// - 上传失败不回滚本地备份，也不阻止 `lastBackup` 更新（本地备份已成功），
//   失败原因交由调用方提示/记日志。
import 'package:flutter/foundation.dart';

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
class LocalBackupService {
  /// 公共构造仅用于测试替身（互斥锁为**全局静态**，所有实例共享；
  /// 生产代码一律经 [instance] 使用单例）
  LocalBackupService();

  /// 全局单例（手动入口与自动调度必须共用同一把锁）
  static final LocalBackupService instance = LocalBackupService();

  /// 进程内互斥标志（Dart 单线程事件循环保证读写原子性）
  static bool _running = false;

  /// 是否有备份正在执行
  static bool get isRunning => _running;

  /// 测试用：复位互斥标志（生产代码不得调用）
  @visibleForTesting
  static void resetForTest() {
    _running = false;
  }

  /// 在互斥锁内执行 [action]
  ///
  /// - 已有备份在执行：返回 `null`（**不排队**，对齐原版重复触发跳过）；
  /// - [action] 抛出的异常原样上抛，锁在 finally 中释放。
  Future<T?> runExclusive<T>(Future<T> Function() action) async {
    if (_running) {
      debugPrint('[LocalBackupService] 已有备份执行中，跳过本次触发');
      return null;
    }
    _running = true;
    try {
      return await action();
    } finally {
      _running = false;
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

    // 与手动入口一致：把 appPrefs 注入 JSON 备份（忽略项过滤）
    final ignore = await s.getRestoreIgnoreConfig();
    await RestoreIgnorePrefs.injectAppPrefsIntoBackupFile(filePath, ignore);

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

    await s.setLastBackupTime((now ?? DateTime.now()).millisecondsSinceEpoch);
    return LocalBackupResult(
      filePath: filePath,
      upload: upload,
      uploadError: uploadError,
      uploadSkipped: uploadSkipped,
    );
  }
}
