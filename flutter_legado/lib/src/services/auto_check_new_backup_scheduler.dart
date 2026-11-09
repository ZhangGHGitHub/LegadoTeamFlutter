// 批10：autoCheckNewBackup 启动检查与提示
//
// 对齐参考版（MainActivity 冷启动检查一次 / AppWebDav.lastBackUp）：
// - 触发：应用冷启动、隐私闸门放行后延迟 5s 检查一次；进程内只执行一次，
//   不注册 resumed（回前台不重复检查）；
// - 数据源只看 WebDAV 远端：`webdavListDir` 里过滤目录与非 `backup` 前缀，
//   取 `last_modified` 最大的文件；`last_modified` 用 Dart `HttpDate.parse`
//   解析，失败按文件名 `backup_yyyyMMdd_HHmmss[_SSS].(json|zip)` 回退；
// - 判定：`mtime > max(lastBackup, lastSeenRemoteBackupMtime) + 60s`
//   （严格大于；正好 60s 不提示）；
// - 去重：`lastSeenRemoteBackupMtime`（设备级，不随备份往返）在**弹窗前**
//   写入——用户取消即永久忽略该备份（对齐 MD3）；不写 `lastBackup`，避免
//   推迟自动备份周期；
// - 需密码的 zip 不自动恢复，提示前往备份恢复页手动处理（差异已登记）；
// - 异常/未配置/开关关闭/备份恢复 busy 一律静默（仅调试日志，不打印
//   URL/凭据）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../constants/pref_keys.dart';
import '../utils/error_message.dart';
import '../widgets/auto_check_new_backup_dialog.dart';
import 'book_api.dart';
import 'local_backup_service.dart';
import 'platform_bridge_service.dart';
import 'settings_service.dart';
import 'webdav_backup_service.dart';
import 'webdav_restore_service.dart';

/// 远端备份比本地新多少才提示（对齐参考版 DateUtils.MINUTE_IN_MILLIS）
const Duration kAutoCheckNewBackupThreshold = Duration(minutes: 1);

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

/// 自动检查判定结果（便于单测断言与调试日志）
enum AutoCheckNewBackupDecision {
  /// 开关关闭
  disabled,

  /// WebDAV 未配置
  notConfigured,

  /// 已有备份/恢复在执行，本次跳过
  busy,

  /// 隐私闸门未放行：未检查，解锁后可再触发一次
  privacyLocked,

  /// 远端没有 `backup*` 文件
  noRemoteBackup,

  /// 远端备份不比本地新（未超过 60s 阈值）
  noNewBackup,

  /// 有更新但用户取消（已写入去重键，本次启动不再提示）
  promptDeclined,

  /// 备份需要密码，未自动恢复（已提示手动处理）
  passwordRequired,

  /// 用户确认且恢复成功
  restored,

  /// 用户确认但恢复失败（已提示失败）
  restoreFailed,

  /// 列表/其它异常，静默
  failed,

  /// 本进程已检查过，不再重复
  skipped,
}

/// 解析 `webdavListDir` 返回的 JSON，过滤目录与非 `backup` 前缀文件
///
/// 非法 JSON / 非数组抛 [FormatException]（调用方按「检查失败」静默）；
/// 单条元素形态不符或时间无法解析时跳过该条，不拖垮整次检查。
@visibleForTesting
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
    final millis = parseRemoteBackupModified(item['last_modified'], name);
    if (millis == null) continue;
    candidates.add(
      RemoteBackupCandidate(name: name, lastModifiedMillis: millis),
    );
  }
  return candidates;
}

/// 取最后修改时间最大的远端备份（同时间取列表先出现者）
@visibleForTesting
RemoteBackupCandidate? latestRemoteBackupCandidate(String rawJson) {
  final candidates = parseRemoteBackupCandidates(rawJson);
  if (candidates.isEmpty) return null;
  var latest = candidates.first;
  for (final candidate in candidates.skip(1)) {
    if (candidate.lastModifiedMillis > latest.lastModifiedMillis) {
      latest = candidate;
    }
  }
  return latest;
}

/// 解析单条远端备份的最后修改时间
///
/// 优先 `HttpDate.parse`（RFC1123，参考版 `WebDav.kt` 同口径）；缺失/非法
/// 时按我方命名 `backup_yyyyMMdd_HHmmss[_SSS].(json|zip)` 回退；两者都不
/// 可用返回 null（该条跳过）。
@visibleForTesting
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

/// 自动检查新备份调度器（全局单例）
class AutoCheckNewBackupScheduler {
  AutoCheckNewBackupScheduler({
    required BookApi api,
    SettingsService? settings,
    WebDavBackupService? webDavBackupService,
    WebDavRestoreService? restoreService,
    ValueListenable<bool>? privacyLocked,
    Future<bool> Function(String fileName)? confirmRestore,
    Future<void> Function(String message)? notify,
    Future<void> Function()? refreshAfterRestore,
    Duration startupDelay = const Duration(seconds: 5),
    Future<void> Function(Duration duration)? delay,
    DateTime Function()? clock,
  }) : _api = api,
       _settings = settings ?? SettingsService(),
       _webDavBackup =
           webDavBackupService ??
           WebDavBackupService(api: api, settings: settings),
       _restoreService =
           restoreService ?? WebDavRestoreService(api: api, settings: settings),
       _privacyLocked = privacyLocked,
       _confirmRestore = confirmRestore ?? _defaultConfirmRestore,
       _notify = notify ?? _defaultNotify,
       _refreshAfterRestore = refreshAfterRestore,
       _startupDelay = startupDelay,
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now {
    _privacyLocked?.addListener(_handlePrivacyChanged);
  }

  final BookApi _api;
  final SettingsService _settings;
  final WebDavBackupService _webDavBackup;
  final WebDavRestoreService _restoreService;
  final ValueListenable<bool>? _privacyLocked;
  final Future<bool> Function(String fileName) _confirmRestore;
  final Future<void> Function(String message) _notify;
  final Future<void> Function()? _refreshAfterRestore;
  final Duration _startupDelay;
  final Future<void> Function(Duration duration) _delay;
  final DateTime Function() _clock;

  static AutoCheckNewBackupScheduler? _instance;

  bool _started = false;
  bool _delayElapsed = false;
  bool _completed = false;
  bool _disposed = false;
  Future<AutoCheckNewBackupDecision>? _inFlight;

  /// 装配入口（app.dart initState）
  ///
  /// 重复调用幂等；首帧后启动 5s 延迟检查。`privacyLocked` 由 app.dart 用
  /// 隐私 provider 状态驱动（true = 闸门未放行），解锁时若延迟已过会立即
  /// 补检查一次。
  static AutoCheckNewBackupScheduler attach({
    required BookApi api,
    ValueListenable<bool>? privacyLocked,
    Future<void> Function()? refreshAfterRestore,
  }) {
    final existing = _instance;
    if (existing != null) return existing;
    final instance = AutoCheckNewBackupScheduler(
      api: api,
      privacyLocked: privacyLocked,
      refreshAfterRestore: refreshAfterRestore,
    );
    _instance = instance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(instance.start());
    });
    return instance;
  }

  /// 当前单例（测试/装配诊断用）
  static AutoCheckNewBackupScheduler? get instance => _instance;

  /// 测试用：解除监听并清空单例
  @visibleForTesting
  static void resetForTest() {
    _instance?.dispose();
    _instance = null;
  }

  /// 解除隐私监听
  void dispose() {
    _disposed = true;
    _privacyLocked?.removeListener(_handlePrivacyChanged);
    if (identical(_instance, this)) _instance = null;
  }

  /// 延迟到启动后检查一次（attach 调用；直接调用便于测试注入零延迟）
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _delay(_startupDelay);
    if (_disposed) return;
    _delayElapsed = true;
    await checkNow();
  }

  /// 判定并执行一次检查
  ///
  /// - 进程内只真正执行一次（[AutoCheckNewBackupDecision.skipped] 表示已执行）；
  /// - 隐私闸门未放行时返回 [AutoCheckNewBackupDecision.privacyLocked] 且
  ///   不消费「一次」配额，解锁后仍可检查；
  /// - 并发调用共享同一 Future，不重复列目录/弹窗。
  Future<AutoCheckNewBackupDecision> checkNow() {
    if (_completed) {
      return Future.value(AutoCheckNewBackupDecision.skipped);
    }
    final running = _inFlight;
    if (running != null) return running;
    final future = _runCheck();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<AutoCheckNewBackupDecision> _runCheck() async {
    if (_privacyLocked?.value ?? false) {
      return AutoCheckNewBackupDecision.privacyLocked;
    }
    // 闸门已放行：本进程只尝试一次（失败/未配置/busy 均不再重试）
    _completed = true;
    try {
      final enabled = await _settings.getBoolPref(
        PrefKeys.autoCheckNewBackup,
        defaultValue: true,
      );
      if (!enabled) return AutoCheckNewBackupDecision.disabled;
      if (LocalBackupService.isBusy) {
        return AutoCheckNewBackupDecision.busy;
      }
      final configJson = await _webDavBackup.resolveConfigJson();
      if (configJson == null) {
        return AutoCheckNewBackupDecision.notConfigured;
      }

      final raw = await _api.webdavListDir(configJson, '');
      final candidate = latestRemoteBackupCandidate(raw);
      if (candidate == null) {
        return AutoCheckNewBackupDecision.noRemoteBackup;
      }

      final lastBackupMillis = await _settings.getLastBackupTime();
      final lastSeenMillis = await _settings.getIntPref(
        PrefKeys.lastSeenRemoteBackupMtime,
        defaultValue: 0,
      );
      final nowMillis = _clock().millisecondsSinceEpoch;
      debugPrint(
        '[AutoCheckNewBackupScheduler] 远端最新=${candidate.name} '
        'mtime=${candidate.lastModifiedMillis} lastBackup=$lastBackupMillis '
        'seen=$lastSeenMillis now=$nowMillis',
      );
      if (!shouldPrompt(
        remoteMillis: candidate.lastModifiedMillis,
        lastBackupMillis: lastBackupMillis,
        lastSeenMillis: lastSeenMillis,
      )) {
        return AutoCheckNewBackupDecision.noNewBackup;
      }

      // 弹窗前写入去重键：用户取消即永久忽略该备份（对齐 MD3 口径），
      // 且不得写 lastBackup（避免推迟自动备份周期）。
      await _settings.setIntPref(
        PrefKeys.lastSeenRemoteBackupMtime,
        candidate.lastModifiedMillis,
      );
      final confirmed = await _confirmRestore(candidate.name);
      if (!confirmed) return AutoCheckNewBackupDecision.promptDeclined;

      final result = await _restoreService.restoreRemoteBackupExclusive(
        remoteName: candidate.name,
        configJson: configJson,
        refresh: _refreshAfterRestore,
      );
      switch (result.status) {
        case WebDavRestoreStatus.success:
          await _notify('恢复成功');
          return AutoCheckNewBackupDecision.restored;
        case WebDavRestoreStatus.passwordRequired:
          await _notify('该备份需要密码，请在备份恢复页手动恢复');
          return AutoCheckNewBackupDecision.passwordRequired;
        case WebDavRestoreStatus.busy:
          await _notify('正在备份或恢复，请稍候');
          return AutoCheckNewBackupDecision.busy;
        case WebDavRestoreStatus.failed:
          final error = result.error;
          await _notify(error == null ? '恢复失败' : '恢复失败：${errorMessage(error)}');
          return AutoCheckNewBackupDecision.restoreFailed;
      }
    } catch (e, stack) {
      // 静默：仅调试日志，不打印 URL/凭据等敏感信息（异常 message 可能
      // 携带远端地址，故只打印类型与栈）。
      debugPrint(
        '[AutoCheckNewBackupScheduler] 自动检查失败（静默，'
        '${e.runtimeType}）:\n$stack',
      );
      return AutoCheckNewBackupDecision.failed;
    }
  }

  /// 是否提示恢复
  ///
  /// `remote > max(lastBackup, seen) + 60s`，严格大于：差值正好 60s 不提示。
  /// 负数基线按 0 处理。
  static bool shouldPrompt({
    required int remoteMillis,
    required int lastBackupMillis,
    required int lastSeenMillis,
  }) {
    final rawBaseline = lastBackupMillis > lastSeenMillis
        ? lastBackupMillis
        : lastSeenMillis;
    final baseline = rawBaseline < 0 ? 0 : rawBaseline;
    return remoteMillis - baseline >
        kAutoCheckNewBackupThreshold.inMilliseconds;
  }

  void _handlePrivacyChanged() {
    if (_disposed) return;
    if ((_privacyLocked?.value ?? false) == false &&
        _delayElapsed &&
        !_completed &&
        _inFlight == null) {
      // 解锁时若 5s 延迟已过，立即补检查一次
      unawaited(checkNow());
    }
  }

  /// 默认确认框（经全局 Navigator context）
  static Future<bool> _defaultConfirmRestore(String fileName) async {
    final context = PlatformBridgeService.navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    return showAutoCheckNewBackupDialog(context, fileName: fileName);
  }

  /// 默认提示（SnackBar，经全局 Navigator context）
  static Future<void> _defaultNotify(String message) async {
    final context = PlatformBridgeService.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }
}
