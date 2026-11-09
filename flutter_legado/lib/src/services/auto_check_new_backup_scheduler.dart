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
// - 去重：`lastSeenRemoteBackupMtime`（设备级，不随备份往返）在用户明确
//   选择（取消/确定）后写入——取消即永久忽略该备份（对齐 MD3）；点遮罩/
//   返回键（null）或主路由未稳定（未真正展示）不写；不写 `lastBackup`，
//   避免推迟自动备份周期；
// - 弹窗前等待主路由稳定（闪屏 /welcome 期间弹窗会被 replace 丢弃）；
// - 备份/恢复 busy 不消费「一次」配额，延迟 30s 重试（最多 3 次）；
// - 需密码的 zip 不自动恢复，提示前往备份恢复页手动处理（差异已登记）；
// - 异常/未配置/开关关闭一律静默（仅调试日志，不打印 URL/凭据）。
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

  /// 确认框未得到明确选择（点遮罩/返回键）：不写去重键，下次启动可再提示
  promptDismissed,

  /// 主路由未稳定（如仍在闪屏）且等待超时：未弹窗、未写去重键
  promptDeferred,

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
    // 审查回修 P3：displayname 含路径分隔符或 `..` 直接跳过（目录穿越/
    // 非单段文件名），不能进入候选；下载侧还有第二道校验。
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
    Future<bool?> Function(String fileName)? confirmRestore,
    Future<void> Function(String message)? notify,
    Future<void> Function()? refreshAfterRestore,
    bool Function()? canPresentPrompt,
    Duration startupDelay = const Duration(seconds: 5),
    Duration busyRetryDelay = const Duration(seconds: 30),
    int maxBusyRetries = 3,
    Duration promptReadyRetryDelay = const Duration(seconds: 1),
    int maxPromptReadyChecks = 30,
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
       _canPresentPrompt = canPresentPrompt,
       _startupDelay = startupDelay,
       _busyRetryDelay = busyRetryDelay,
       _maxBusyRetries = maxBusyRetries,
       _promptReadyRetryDelay = promptReadyRetryDelay,
       _maxPromptReadyChecks = maxPromptReadyChecks,
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now {
    _privacyLocked?.addListener(_handlePrivacyChanged);
  }

  final BookApi _api;
  final SettingsService _settings;
  final WebDavBackupService _webDavBackup;
  final WebDavRestoreService _restoreService;
  final ValueListenable<bool>? _privacyLocked;
  final Future<bool?> Function(String fileName) _confirmRestore;
  final Future<void> Function(String message) _notify;
  final Future<void> Function()? _refreshAfterRestore;
  final bool Function()? _canPresentPrompt;
  final Duration _startupDelay;
  final Duration _busyRetryDelay;
  final int _maxBusyRetries;
  final Duration _promptReadyRetryDelay;
  final int _maxPromptReadyChecks;
  final Future<void> Function(Duration duration) _delay;
  final DateTime Function() _clock;

  static AutoCheckNewBackupScheduler? _instance;

  bool _started = false;
  bool _delayElapsed = false;
  bool _completed = false;
  bool _disposed = false;
  int _busyRetries = 0;
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
    bool Function()? canPresentPrompt,
  }) {
    final existing = _instance;
    if (existing != null) return existing;
    final instance = AutoCheckNewBackupScheduler(
      api: api,
      privacyLocked: privacyLocked,
      refreshAfterRestore: refreshAfterRestore,
      canPresentPrompt: canPresentPrompt,
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
  /// - 备份/恢复 busy 同样不消费配额（延迟重试，见 [_scheduleBusyRetry]）；
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
    try {
      final enabled = await _settings.getBoolPref(
        PrefKeys.autoCheckNewBackup,
        defaultValue: true,
      );
      if (!enabled) {
        // 审查回修 P3：开关关闭不算「完成一次检查」，不置 _completed；
        // 用户本会话内再开启时，隐私解锁/显式触发仍可补查。
        return AutoCheckNewBackupDecision.disabled;
      }
      // 审查回修 P2：备份/恢复 busy 不消费本次进程的「一次」配额——
      // 新配置 WebDAV 后首次启动常与自动备份撞车，直接跳过会让最需要
      // 恢复的会话永远不提示。改为延迟重试，重试用尽才收口。
      if (LocalBackupService.isBusy) {
        _scheduleBusyRetry();
        return AutoCheckNewBackupDecision.busy;
      }
      final configJson = await _webDavBackup.resolveConfigJson();
      if (configJson == null) {
        return _finish(AutoCheckNewBackupDecision.notConfigured);
      }

      final raw = await _api.webdavListDir(configJson, '');
      final candidate = latestRemoteBackupCandidate(raw);
      if (candidate == null) {
        return _finish(AutoCheckNewBackupDecision.noRemoteBackup);
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
        nowMillis: nowMillis,
      )) {
        return _finish(AutoCheckNewBackupDecision.noNewBackup);
      }

      // 审查回修 P2：闪屏（/welcome）期间弹窗会被 pushReplacement 连带
      // 替换，showDialog 返回 null。必须先等主路由稳定；等待期间不写
      // 去重键，避免「没看到弹窗却永久忽略」。
      if (!await _waitForPromptReady()) {
        return _finish(AutoCheckNewBackupDecision.promptDeferred);
      }

      final confirmed = await _confirmRestore(candidate.name);
      // 未得到明确选择（点遮罩/返回键）：不写 seen，下次启动可再提示。
      if (confirmed == null) {
        debugPrint('[AutoCheckNewBackupScheduler] 确认框未明确选择，不写去重键');
        return _finish(AutoCheckNewBackupDecision.promptDismissed);
      }
      // 用户已看到提示：取消也永久忽略该备份（对齐 MD3 口径）；确定则
      // 进入恢复链。不得写 lastBackup（避免推迟自动备份周期）。
      await _settings.setIntPref(
        PrefKeys.lastSeenRemoteBackupMtime,
        candidate.lastModifiedMillis,
      );
      if (!confirmed) {
        return _finish(AutoCheckNewBackupDecision.promptDeclined);
      }

      final result = await _restoreService.restoreRemoteBackupExclusive(
        remoteName: candidate.name,
        configJson: configJson,
        refresh: _refreshAfterRestore,
      );
      switch (result.status) {
        case WebDavRestoreStatus.success:
          await _notify('恢复成功');
          return _finish(AutoCheckNewBackupDecision.restored);
        case WebDavRestoreStatus.passwordRequired:
          // 已写 seen：同一远端备份本进程/下次启动不再重复弹窗；用户需
          // 前往备份恢复页手动输入密码（差异已登记）。
          await _notify('该备份需要密码，请在备份恢复页手动恢复');
          return _finish(AutoCheckNewBackupDecision.passwordRequired);
        case WebDavRestoreStatus.busy:
          // 用户确认后撞上并发备份/恢复：seen 已写入，不重试弹窗，
          // 只如实提示稍候（不得提示成功）。
          await _notify('正在备份或恢复，请稍候');
          return _finish(AutoCheckNewBackupDecision.busy);
        case WebDavRestoreStatus.failed:
          final error = result.error;
          await _notify(error == null ? '恢复失败' : '恢复失败：${errorMessage(error)}');
          return _finish(AutoCheckNewBackupDecision.restoreFailed);
      }
    } catch (e, stack) {
      // 静默：仅调试日志，不打印 URL/凭据等敏感信息（异常 message 可能
      // 携带远端地址，故只打印类型与栈）。
      debugPrint(
        '[AutoCheckNewBackupScheduler] 自动检查失败（静默，'
        '${e.runtimeType}）:\n$stack',
      );
      return _finish(AutoCheckNewBackupDecision.failed);
    }
  }

  /// 记录「本次进程已完成检查」并返回结果
  ///
  /// 只有真正得到确定结论（未配置/无远端/未到期/已提示/恢复结束/异常）
  /// 才置位；开关关闭、隐私锁定与备份 busy 不置位，以便后续补检查/重试。
  AutoCheckNewBackupDecision _finish(AutoCheckNewBackupDecision decision) {
    _completed = true;
    return decision;
  }

  /// 备份/恢复 busy 的延迟重试（不排队、不阻塞调用方）
  void _scheduleBusyRetry() {
    if (_disposed || _completed) return;
    if (_busyRetries >= _maxBusyRetries) {
      // 重试次数用尽：接受本次跳过，本进程不再检查（与「进程内一次」一致）
      debugPrint('[AutoCheckNewBackupScheduler] busy 重试 $_busyRetries 次后放弃');
      _completed = true;
      return;
    }
    _busyRetries++;
    unawaited(_retryAfterBusy());
  }

  Future<void> _retryAfterBusy() async {
    await _delay(_busyRetryDelay);
    if (_disposed || _completed) return;
    // 当前这次检查可能尚未收尾（_inFlight 未清空），先等它完成再发起
    // 重试，避免重试被 single-flight 当成并发调用直接返回。
    final running = _inFlight;
    if (running != null) {
      try {
        await running;
      } catch (_) {
        // 原检查内部已捕获异常，这里只需等待收尾
      }
    }
    if (_disposed || _completed) return;
    await checkNow();
  }

  /// 等待主路由稳定（不在闪屏/弹层上）再弹确认框
  ///
  /// 返回 false = 等待超时或已销毁（未弹窗，调用方不得写去重键）。
  Future<bool> _waitForPromptReady() async {
    final canPresent = _canPresentPrompt;
    if (canPresent == null) return true;
    var checks = 0;
    while (!canPresent()) {
      if (_disposed || _completed) return false;
      if (checks >= _maxPromptReadyChecks) {
        debugPrint('[AutoCheckNewBackupScheduler] 主路由未稳定，放弃本次提示');
        return false;
      }
      checks++;
      await _delay(_promptReadyRetryDelay);
    }
    return true;
  }

  /// 是否提示恢复
  ///
  /// `remote > max(lastBackup, seen) + 60s`，严格大于：差值正好 60s 不提示。
  /// 负数基线按 0 处理。
  ///
  /// 未来时间处理（批10 设备验收回修）：
  /// - 仅 `lastBackup` 落在未来（时钟回拨/恢复他机偏好）时按 0 处理，
  ///   对齐 [AutoBackupScheduler]「未来时间视为到期」口径，避免永久抑制
  ///   提示；
  /// - `lastSeen` **不**做未来归零：它记录的正是远端 mtime，服务器时钟
  ///   超前时 seen 天然是未来值；归零会导致同一备份每次启动重复提示。
  static bool shouldPrompt({
    required int remoteMillis,
    required int lastBackupMillis,
    required int lastSeenMillis,
    int? nowMillis,
  }) {
    final now = nowMillis;
    final lastBackup = (now != null && lastBackupMillis > now)
        ? 0
        : lastBackupMillis;
    final rawBaseline = lastBackup > lastSeenMillis
        ? lastBackup
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
  ///
  /// 返回 null = 未能展示/未明确选择（无 Navigator、点遮罩或返回键），
  /// 调用方不写去重键。
  static Future<bool?> _defaultConfirmRestore(String fileName) async {
    final context = PlatformBridgeService.navigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
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
