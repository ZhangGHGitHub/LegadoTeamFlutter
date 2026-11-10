// 批11：远端备份候选解析（由批10 AutoCheckNewBackupScheduler 抽出共用）
//
// 设置页「网络恢复」「远端最新」与启动自动检查必须使用同一套口径，避免
// 两处过滤/时间解析漂移：
// - 只接受 `backup` 前缀的单段文件名（拒绝 `/`、`\`、`..`，防目录穿越）；
// - 目录（`is_dir = true`）与非对象元素跳过；
// - mtime 优先 HTTP 日期（RFC1123，参考版 `WebDav.kt` 同口径），失败回退
//   文件名时间 `backup_yyyyMMdd_HHmmss[_SSS].(json|zip)`，两者都不可用则
//   跳过该条。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 远端备份候选（列表过滤后的单条记录）
@immutable
class RemoteBackupCandidate {
  const RemoteBackupCandidate({
    required this.name,
    required this.lastModifiedMillis,
  });

  /// 远端文件名（用于展示与下载）
  final String name;

  /// 最后修改时间（毫秒时间戳；HTTP 头解析失败时取文件名时间）
  final int lastModifiedMillis;
}

/// 解析 `webdavListDir` 返回的 JSON，过滤目录与非 `backup` 前缀文件
///
/// 非法 JSON / 非数组抛 [FormatException]（调用方按「检查失败」静默）；
/// 单条元素形态不符或时间无法解析时跳过该条，不拖垮整次检查。
List<RemoteBackupCandidate> parseRemoteBackupCandidates(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) {
    throw const FormatException('webdavListDir 返回的不是数组');
  }
  final candidates = <RemoteBackupCandidate>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    if (item['is_dir'] == true) continue;
    final name = item['name']?.toString().trim() ?? '';
    if (!name.startsWith('backup')) continue;
    // displayname 含路径分隔符或 `..` 直接跳过（目录穿越/非单段文件名），
    // 不能进入候选；下载侧还有第二道校验。
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      continue;
    }
    final millis = parseRemoteBackupModified(item['last_modified'], name);
    if (millis == null) continue;
    candidates.add(
      RemoteBackupCandidate(name: name, lastModifiedMillis: millis),
    );
  }
  return candidates;
}

/// 取最后修改时间最大的远端备份（同时间取列表先出现者）
RemoteBackupCandidate? latestRemoteBackupCandidate(String rawJson) {
  return latestRemoteBackupFromCandidates(parseRemoteBackupCandidates(rawJson));
}

/// 从已解析候选中取最后修改时间最大者（同时间取列表先出现者）
///
/// 网络恢复列表按**名称降序**展示，远端最新按 **mtime 最大**选取；两者
/// 共用 [parseRemoteBackupCandidates] 的过滤结果，仅排序口径不同。
RemoteBackupCandidate? latestRemoteBackupFromCandidates(
  Iterable<RemoteBackupCandidate> candidates,
) {
  RemoteBackupCandidate? latest;
  for (final candidate in candidates) {
    if (latest == null ||
        candidate.lastModifiedMillis > latest.lastModifiedMillis) {
      latest = candidate;
    }
  }
  return latest;
}

/// 按文件名降序排列（对齐参考版 `WebDavManager` 远端备份列表）
List<RemoteBackupCandidate> sortRemoteBackupsByNameDescending(
  Iterable<RemoteBackupCandidate> candidates,
) {
  final sorted = [...candidates]..sort((a, b) => b.name.compareTo(a.name));
  return sorted;
}

/// 解析单条远端备份的最后修改时间
///
/// 优先 `HttpDate.parse`（RFC1123，参考版 `WebDav.kt` 同口径）；缺失/非法
/// 时按我方命名 `backup_yyyyMMdd_HHmmss[_SSS].(json|zip)` 回退；两者都不
/// 可用返回 null（该条跳过）。
int? parseRemoteBackupModified(Object? raw, String name) {
  if (raw is String) {
    final text = raw.trim();
    if (text.isNotEmpty) {
      try {
        return HttpDate.parse(text).millisecondsSinceEpoch;
      } catch (_) {
        // 非法 HTTP 日期：走文件名时间回退
      }
    }
  }
  return _parseBackupFileNameTime(name);
}

/// 我方备份文件名中的时间（无时区后缀，按本地时间解释）
int? _parseBackupFileNameTime(String name) {
  final match = _backupFileNamePattern.firstMatch(name);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final millis = int.parse(match.group(7) ?? '0');
  final time = DateTime(year, month, day, hour, minute, second, millis);
  // DateTime 会把越界字段进位，必须逐项回读校验（如 13 月 → 次年 1 月）
  if (time.year != year ||
      time.month != month ||
      time.day != day ||
      time.hour != hour ||
      time.minute != minute ||
      time.second != second ||
      time.millisecond != millis) {
    return null;
  }
  return time.millisecondsSinceEpoch;
}

final RegExp _backupFileNamePattern = RegExp(
  r'^backup_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})'
  r'(?:_(\d{3}))?\.(?:json|zip)$',
  caseSensitive: false,
);
