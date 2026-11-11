// 启动清扫：系统临时目录中残留的 WebDAV 备份/恢复临时目录
//
// 背景（批10/批11 登记的遗留项）：
// - 「仅网络备份」在 `Directory.systemTemp` 下创建 `legado_webdav_only_*`；
// - 「网络恢复」在 `Directory.systemTemp` 下创建 `legado_webdav_restore_*`；
// 正常路径都在 finally 清理，但进程被强杀/崩溃时不会执行，目录会一直残留。
//
// 本服务在启动首帧后异步扫描系统临时目录：
// - 只处理上述两个前缀的**目录**（同名普通文件不碰）；
// - 只删除**超过 [maxAge]（默认 1 小时）未修改**的目录，避免误删另一个
//   正在进行的备份/恢复（写入中的目录 mtime 会持续更新）；
// - 任何失败（列举/stat/删除）只记日志并继续，不抛错、不提示用户。
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 系统临时目录清扫器
class TempDirCleaner {
  TempDirCleaner({
    Directory Function()? tempDirProvider,
    DateTime Function()? now,
    Future<void> Function(Directory dir)? deleteDir,
    this.maxAge = const Duration(hours: 1),
  }) : _tempDirProvider = tempDirProvider ?? (() => Directory.systemTemp),
       _now = now ?? DateTime.now,
       _deleteDir = deleteDir;

  /// 本服务负责的临时目录前缀（与创建方保持一致）
  static const List<String> managedPrefixes = [
    'legado_webdav_only_',
    'legado_webdav_restore_',
  ];

  final Directory Function() _tempDirProvider;
  final DateTime Function() _now;

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
          final modified = (await entity.stat()).modified;
          // 只清理严格超过 maxAge 的目录：新建/正在写入的目录 mtime 很新，
          // 留给创建方自己的 finally 清理。
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

  static Future<void> _deleteRecursively(Directory dir) async {
    await dir.delete(recursive: true);
  }
}
