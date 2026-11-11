// 启动清扫：系统临时目录中残留的 WebDAV 备份/恢复临时目录
//
// 背景（批10/批11 登记的遗留项）：
// - 「仅网络备份」在 `Directory.systemTemp` 下创建 `legado_webdav_only_*`；
// - 「网络恢复」在 `Directory.systemTemp` 下创建 `legado_webdav_restore_*`；
// 正常路径都在 finally 清理，但进程被强杀/崩溃时不会执行，目录会一直残留。
//
// 本服务在启动首帧后异步扫描系统临时目录：
// - 只处理上述两个前缀的**目录**（同名普通文件不碰）；
// - 只删除**超过 [maxAge]（默认 1 小时）未修改**的目录。注意：目录 mtime
//   只在增删条目时更新，写入文件内容**不会**更新目录 mtime；因此按「目录
//   mtime 与最新直接子项 mtime 的较大者」判定，避免把长时间写入中的备份/
//   恢复目录误判为残留；
// - 任何失败（列举/stat/删除）只记日志并继续，不抛错、不提示用户。
//
// 限制（登记）：桌面系统的临时目录多进程共享，理论上第三方可以创建同名
// 目录并被本清扫器命中；Android/iOS 的临时目录是应用私有的，不受影响。
// 前缀命名已尽量降低碰撞概率，长任务/多实例场景仍存在极小误删可能。
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 系统临时目录清扫器
class TempDirCleaner {
  TempDirCleaner({
    Directory Function()? tempDirProvider,
    DateTime Function()? now,
    Future<DateTime> Function(Directory dir)? modifiedTimeProvider,
    Future<void> Function(Directory dir)? deleteDir,
    this.maxAge = const Duration(hours: 1),
  }) : _tempDirProvider = tempDirProvider ?? (() => Directory.systemTemp),
       _now = now ?? DateTime.now,
       _modifiedTimeProvider = modifiedTimeProvider ?? _latestModified,
       _deleteDir = deleteDir;

  /// 本服务负责的临时目录前缀（与创建方保持一致）
  static const List<String> managedPrefixes = [
    'legado_webdav_only_',
    'legado_webdav_restore_',
  ];

  final Directory Function() _tempDirProvider;
  final DateTime Function() _now;

  /// 目录最近活动时间（默认取目录与最新直接子项的较大者）
  final Future<DateTime> Function(Directory dir) _modifiedTimeProvider;

  /// 测试注入：模拟删除失败；生产为 null，走 [Directory.delete]
  final Future<void> Function(Directory dir)? _deleteDir;

  /// 超过该时长未修改才视为残留（默认 1 小时）
  final Duration maxAge;

  /// 扫描并清理一次，返回实际删除的目录数
  ///
  /// 任何异常都在内部消化（仅日志），调用方可直接 `unawaited(...)`。
  Future<int> sweep() async {
    var deleted = 0;
    try {
      final base = _tempDirProvider();
      if (!await base.exists()) return deleted;
      final current = _now();

      await for (final entity in base.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (!_isManaged(entity)) continue;
        try {
          final modified = await _modifiedTimeProvider(entity);
          // 只清理严格超过 maxAge 的目录：新建/正在写入的目录最近活动时间
          // 很新，留给创建方自己的 finally 清理。
          if (current.difference(modified) <= maxAge) continue;
          await (_deleteDir ?? _deleteRecursively)(entity);
          deleted++;
        } catch (e) {
          // 单个目录失败（权限/占用/已删除）不影响其余目录，下次启动重试
          debugPrint('[TempDirCleaner] 清理临时目录失败（忽略，路径=${entity.path}）：$e');
        }
      }
    } catch (e) {
      // 系统临时目录不可读等极端情况：静默，不阻塞启动
      debugPrint('[TempDirCleaner] 扫描系统临时目录失败（忽略）：$e');
    }
    return deleted;
  }

  /// 目录名是否命中本服务管理的前缀
  bool _isManaged(Directory dir) {
    final segments = dir.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final name = segments.isEmpty ? '' : segments.last;
    return managedPrefixes.any(name.startsWith);
  }

  /// 目录最近活动时间：目录自身 mtime 与最新**直接子项** mtime 取较大者
  ///
  /// 目录 mtime 只在增删条目时更新，写入备份文件内容时不变；只看目录 mtime
  /// 会把「创建目录后长时间写入」的任务误判为残留。直接子项已覆盖备份文件
  /// 与恢复下载文件（两者都直接落在临时目录内）。
  static Future<DateTime> _latestModified(Directory dir) async {
    var latest = (await dir.stat()).modified;
    try {
      await for (final child in dir.list(followLinks: false)) {
        try {
          final modified = (await child.stat()).modified;
          if (modified.isAfter(latest)) latest = modified;
        } catch (e) {
          // 单个子项 stat 失败（并发删除等）不影响整目录判定
          debugPrint('[TempDirCleaner] 读取子项时间失败（忽略，路径=${child.path}）：$e');
        }
      }
    } catch (e) {
      // 子项列举失败：退回目录自身 mtime
      debugPrint('[TempDirCleaner] 列举子项失败（退回目录 mtime，路径=${dir.path}）：$e');
    }
    return latest;
  }

  /// 测试用：读取目录最近活动时间（目录与最新直接子项的较大者）
  @visibleForTesting
  static Future<DateTime> latestModifiedForTest(Directory dir) =>
      _latestModified(dir);

  static Future<void> _deleteRecursively(Directory dir) async {
    await dir.delete(recursive: true);
  }
}
