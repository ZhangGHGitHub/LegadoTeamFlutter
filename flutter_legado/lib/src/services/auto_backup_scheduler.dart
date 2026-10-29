// 批40：自动备份调度（对齐原版 Backup.autoBack / shouldBackup）
//
// 触发点（对齐原版 MainActivity/ReadBookActivity onResume 调 autoBack）：
// - 应用启动装配（app.dart initState → attach，首帧后判定一次）
// - 应用自后台恢复（didChangeAppLifecycleState.resumed）
//
// 判定：`now - lastBackup >= autoBackupIntervalDays × 24h`；`autoBackup`
// 默认开启、间隔默认 1 天（读取时 clamp ≥1）。与手动备份共用
// `LocalBackupService.runExclusive` 互斥锁；锁定后**二次判定**（对齐原版
// autoBackupLocked 的 shouldBackup 双检），避免并发触发重复备份。
//
// 失败仅日志：不弹 UI、不写 lastBackup（下次启动/回前台重试）。
// 备份目录：优先设置页「备份路径」；未设置时回退
// `getApplicationDocumentsDirectory()/backup`（原版回退 Android externalFiles，
// 平台差异已登记 docs/API_CONTRACT.md §2.28 批40 注）。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'book_api.dart';
import 'crash_log_service.dart';
import 'local_backup_service.dart';
import 'settings_service.dart';

/// 自动备份判定结果（便于单测断言与日志）
enum AutoBackupDecision {
  /// 自动备份开关关闭
  disabled,

  /// 距上次备份未达到间隔天数
  notDue,

  /// 已有备份在执行（手动/另一次自动），本次跳过
  busy,

  /// 已创建本地备份（上传结果见 LocalBackupResult）
  done,

  /// 备份失败（已记日志，未更新 lastBackup）
  failed,
}

/// 应用内自动备份调度器（全局单例）
class AutoBackupScheduler with WidgetsBindingObserver {
  AutoBackupScheduler({
    required BookApi api,
    SettingsService? settings,
    LocalBackupService? backupService,
    Future<String> Function()? resolveBackupDir,
    DateTime Function()? clock,
  })  : _api = api,
        _settings = settings ?? SettingsService(),
        _backupService = backupService ?? LocalBackupService.instance,
        _resolveBackupDir = resolveBackupDir,
        _clock = clock ?? DateTime.now;

  final BookApi _api;
  final SettingsService _settings;
  final LocalBackupService _backupService;
  final Future<String> Function()? _resolveBackupDir;
  final DateTime Function() _clock;

  static AutoBackupScheduler? _instance;

  /// 装配入口（app.dart initState，对齐 AutoTaskScheduler.attach）
  ///
  /// 重复调用幂等；注册生命周期观察，并在首帧后判定一次
  /// （避开启动期 DB 初始化争用）。
  static AutoBackupScheduler attach(BookApi api) {
    final existing = _instance;
    if (existing != null) return existing;
    final instance = AutoBackupScheduler(api: api);
    _instance = instance;
    WidgetsBinding.instance.addObserver(instance);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      instance.checkNow();
    });
    return instance;
  }

  /// 测试用：解除观察者并清空单例
  @visibleForTesting
  static void resetForTest() {
    final instance = _instance;
    if (instance != null) {
      WidgetsBinding.instance.removeObserver(instance);
      _instance = null;
    }
  }

  /// 解除生命周期观察
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_instance, this)) _instance = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkNow();
    }
  }

  /// 是否应执行自动备份（对齐原版 `shouldBackup`）
  ///
  /// `lastBackup == null`（从未备份）视为到期；边界取 `>=`（正好达到
  /// 间隔天数即触发，与原版毫秒差比较一致）。
  static bool shouldBackup({
    required DateTime now,
    required DateTime? lastBackup,
    required int intervalDays,
  }) {
    final days = intervalDays < 1 ? 1 : intervalDays;
    if (lastBackup == null) return true;
    return now.difference(lastBackup) >= Duration(days: days);
  }

  /// 判定并执行一次自动备份
  Future<AutoBackupDecision> checkNow() async {
    if (!await _settings.getAutoBackup()) {
      return AutoBackupDecision.disabled;
    }
    if (!await _isDue()) {
      return AutoBackupDecision.notDue;
    }

    final uploadWebDav = await _settings.getAutoBackupWebDav();
    // 锁定后二次判定：并发的手动备份刚完成时不再重复备份
    var acquired = false;
    try {
      final result = await _backupService.runExclusive<LocalBackupResult?>(
        () async {
          acquired = true;
          if (!await _isDue()) return null;
          final dir = await _backupDir();
          return _backupService.createBackup(
            api: _api,
            settings: _settings,
            dirPath: dir,
            uploadWebDav: uploadWebDav,
            now: _clock(),
          );
        },
      );
      if (!acquired) return AutoBackupDecision.busy;
      if (result == null) return AutoBackupDecision.notDue;
      debugPrint(
        '[AutoBackupScheduler] 自动备份完成: ${result.filePath}'
        '（上传=${result.uploaded}）',
      );
      return AutoBackupDecision.done;
    } catch (e, stack) {
      // 失败仅日志（对齐原版 runCatching + AppLog），lastBackup 不更新
      debugPrint('[AutoBackupScheduler] 自动备份失败: $e\n$stack');
      return AutoBackupDecision.failed;
    }
  }

  /// 当前是否到达备份周期
  Future<bool> _isDue() async {
    final lastMillis = await _settings.getLastBackupTime();
    return shouldBackup(
      now: _clock(),
      lastBackup: lastMillis <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastMillis),
      intervalDays: await _settings.getAutoBackupIntervalDays(),
    );
  }

  /// 备份目录：设置页路径优先，否则回退应用文档目录下 `backup/`
  Future<String> _backupDir() async {
    final custom = _resolveBackupDir;
    if (custom != null) return custom();
    final configured = await CrashLogService.instance.getBackupPath();
    if (configured != null && configured.trim().isNotEmpty) {
      return configured;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}backup');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }
}
