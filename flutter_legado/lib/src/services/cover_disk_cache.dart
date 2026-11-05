// 封面磁盘缓存探测（设置批6b-1 审查 R-P2-1）
//
// 仅 WiFi 门控前置条件：CachedNetworkImage 的磁盘缓存若「有效」（未过期
// 且文件存在），命中可直接渲染，不应因蜂窝网络占位；过期/被删除的条目
// 必须按未命中处理，否则会跳过 WiFi 判定后由 CachedNetworkImage 重新下载。
//
// 抽为独立服务便于单测：测试经 [debugLoader] 注入 FileInfo（临时文件 +
// 任意 validTill），无需平台 path_provider。
//
// 编写：全栈工程师（设置批6b-1 审查） ｜ 2026-11-06
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 缓存条目（测试注入用；生产从 FileInfo 映射）
class CoverDiskCacheEntry {
  final File file;
  final DateTime validTill;

  const CoverDiskCacheEntry({required this.file, required this.validTill});
}

/// 封面磁盘缓存探测
class CoverDiskCache {
  CoverDiskCache._();

  /// 缓存库查询超时：平台通道无响应时按未命中处理，避免封面无限等待
  static const Duration timeout = Duration(milliseconds: 500);

  /// 测试注入：返回条目或 null（null = 未命中）
  @visibleForTesting
  static Future<CoverDiskCacheEntry?> Function(String url)? debugLoader;

  /// 返回有效缓存文件；未命中 / 已过期 / 文件被删除 / 查询异常 → null
  static Future<File?> validFile(String url) async {
    try {
      final loader = debugLoader;
      final CoverDiskCacheEntry? entry;
      if (loader != null) {
        entry = await loader(url);
      } else {
        final info = await DefaultCacheManager()
            .getFileFromCache(url)
            .timeout(timeout);
        entry = info == null
            ? null
            : CoverDiskCacheEntry(
                file: File(info.file.path),
                validTill: info.validTill,
              );
      }
      if (entry == null) return null;
      // [审查 R-P2-1] 过期缓存不能算命中：否则会跳过仅 WiFi 判定，
      // 由 CachedNetworkImage 重新下载
      if (!entry.validTill.isAfter(DateTime.now())) return null;
      // 同步存在性检查：封面缓存路径探测在 UI 首帧路径上，避免额外异步
      // IO 让占位多闪一帧；文件系统 stat 成本可忽略。
      if (!entry.file.existsSync()) return null;
      return entry.file;
    } catch (_) {
      return null;
    }
  }

  /// 测试重置
  @visibleForTesting
  static void reset() {
    debugLoader = null;
  }
}
