// 批10：AutoCheckNewBackupScheduler 单测
//
// 覆盖：60s 阈值边界（=60s 不提示 / >60s 提示）、lastBackup/seen 取最大、
// 列表过滤（目录/非 backup/坏时间文件名回退）、取 mtime 最大、开关关闭、
// WebDAV 未配置、异常静默、busy 跳过、进程内只查一次、seen 去重、
// 不写 lastBackup、隐私闸门锁定不弹/解锁后补检查、用户取消即写去重键、
// 需密码备份不自动恢复、恢复失败不提示成功。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/auto_check_new_backup_scheduler.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_backup_service.dart';
import 'package:flutter_legado/src/services/webdav_restore_service.dart';

/// 可注入列表结果/异常的 BookApi 假实现
class _FakeApi extends MockBookApi {
  String listJson = '[]';
  Object? listError;
  int listCalls = 0;

  @override
  Future<String> webdavListDir(String configJson, String path) async {
    listCalls++;
    final error = listError;
    if (error != null) throw error;
    return listJson;
  }
}

/// 可注入配置结果的 WebDAV 备份服务假实现
class _FakeWebDavBackupService extends WebDavBackupService {
  _FakeWebDavBackupService({required super.api, this.configJson});

  String? configJson;
  int resolveCalls = 0;

  @override
  Future<String?> resolveConfigJson() async {
    resolveCalls++;
    return configJson;
  }
}

/// 可注入结果的恢复服务假实现
class _FakeRestoreService extends WebDavRestoreService {
  _FakeRestoreService({required super.api, super.settings});

  WebDavRestoreRunResult result = const WebDavRestoreRunResult.success();
  int calls = 0;
  String? lastName;
  String? lastConfigJson;
  int refreshCalls = 0;

  @override
  Future<WebDavRestoreRunResult> restoreRemoteBackupExclusive({
    required String remoteName,
    String? configJson,
    Future<void> Function()? refresh,
  }) async {
    calls++;
    lastName = remoteName;
    lastConfigJson = configJson;
    if (result.status == WebDavRestoreStatus.success && refresh != null) {
      refreshCalls++;
      await refresh();
    }
    return result;
  }
}

String _listJson({
  required String name,
  String? lastModified,
  bool isDir = false,
}) => jsonEncode([
  {'name': name, 'is_dir': isDir, 'last_modified': lastModified},
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeApi api;
  late SettingsService settings;
  late _FakeWebDavBackupService webDav;
  late _FakeRestoreService restoreService;
  late int confirmCalls;
  late String? lastConfirmName;
  late bool? confirmAnswer;
  late List<String> messages;

  final remoteMillis = DateTime(2026, 11, 10, 12).millisecondsSinceEpoch;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalBackupService.resetForTest();
    api = _FakeApi();
    settings = SettingsService();
    webDav = _FakeWebDavBackupService(api: api, configJson: '{"url":"x"}');
    restoreService = _FakeRestoreService(api: api, settings: settings);
    confirmCalls = 0;
    lastConfirmName = null;
    confirmAnswer = false;
    messages = [];
  });

  tearDown(() {
    LocalBackupService.resetForTest();
    AutoCheckNewBackupScheduler.resetForTest();
  });

  AutoCheckNewBackupScheduler build({
    ValueNotifier<bool>? gate,
    Duration startupDelay = Duration.zero,
    Duration busyRetryDelay = const Duration(seconds: 30),
    int maxBusyRetries = 3,
    Duration promptReadyRetryDelay = Duration.zero,
    int maxPromptReadyChecks = 30,
    bool Function()? canPresentPrompt,
    Future<void> Function(Duration duration)? delay,
  }) {
    return AutoCheckNewBackupScheduler(
      api: api,
      settings: settings,
      webDavBackupService: webDav,
      restoreService: restoreService,
      privacyLocked: gate,
      confirmRestore: (fileName) async {
        confirmCalls++;
        lastConfirmName = fileName;
        return confirmAnswer;
      },
      notify: (message) async => messages.add(message),
      refreshAfterRestore: () async {},
      canPresentPrompt: canPresentPrompt,
      startupDelay: startupDelay,
      busyRetryDelay: busyRetryDelay,
      maxBusyRetries: maxBusyRetries,
      promptReadyRetryDelay: promptReadyRetryDelay,
      maxPromptReadyChecks: maxPromptReadyChecks,
      delay: delay ?? (_) async {},
      clock: () => DateTime(2026, 11, 10, 12),
    );
  }

  /// 预置一条比本地新（超过 60s）的远端备份
  void seedNewerRemote({String name = 'backup_20261110_120000_123.json'}) {
    api.listJson = _listJson(
      name: name,
      lastModified: HttpDate.format(
        DateTime.fromMillisecondsSinceEpoch(remoteMillis),
      ),
    );
  }

  group('60s 阈值（shouldPrompt）', () {
    test('差值正好 60s 不提示', () {
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 1060000,
          lastBackupMillis: 1000000,
          lastSeenMillis: 0,
        ),
        isFalse,
      );
    });

    test('差值 60s + 1ms 提示', () {
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 1060001,
          lastBackupMillis: 1000000,
          lastSeenMillis: 0,
        ),
        isTrue,
      );
    });

    test('基线取 lastBackup 与 seen 的最大值', () {
      // seen 更大：远端仅比 lastBackup 新 60s+1，但不超过 seen+60s
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 1060001,
          lastBackupMillis: 1000000,
          lastSeenMillis: 1000001,
        ),
        isFalse,
      );
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 1060001,
          lastBackupMillis: 1000000,
          lastSeenMillis: 1000000,
        ),
        isTrue,
      );
    });

    test('从未备份/从未提示：远端须晚于 epoch+60s', () {
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 60000,
          lastBackupMillis: 0,
          lastSeenMillis: 0,
        ),
        isFalse,
      );
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 60001,
          lastBackupMillis: 0,
          lastSeenMillis: 0,
        ),
        isTrue,
      );
    });

    test('lastBackup 在未来（时钟回拨/跨机）视为到期，不永久抑制', () {
      // now=100000、lastBackup=10000000（未来）、远端=1000000：
      // 不处理未来时间会得到负差值而不提示。
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 1000000,
          lastBackupMillis: 10000000,
          lastSeenMillis: 0,
          nowMillis: 100000,
        ),
        isTrue,
      );
    });

    test('lastSeen 在未来同样按 0 处理', () {
      expect(
        AutoCheckNewBackupScheduler.shouldPrompt(
          remoteMillis: 1000000,
          lastBackupMillis: 0,
          lastSeenMillis: 10000000,
          nowMillis: 100000,
        ),
        isTrue,
      );
    });
  });

  group('列表解析', () {
    test('过滤目录/非 backup 前缀/无法解析时间的条目', () {
      final raw = jsonEncode([
        {'name': 'backup_dir', 'is_dir': true, 'last_modified': 'x'},
        {'name': 'notes.txt', 'is_dir': false, 'last_modified': 'x'},
        {
          'name': 'backup_bad_name.json',
          'is_dir': false,
          'last_modified': 'not-a-date',
        },
        {
          'name': 'backup_../evil.json',
          'is_dir': false,
          'last_modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
        },
        {
          'name': 'backup_..json',
          'is_dir': false,
          'last_modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
        },
        {
          'name': 'backup_a\\b.json',
          'is_dir': false,
          'last_modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
        },
        {
          'name': 'backup_20260101_120000_000.json',
          'is_dir': false,
          'last_modified': 'not-a-date',
        },
        {
          'name': 'backup_20260102_120000.zip',
          'is_dir': false,
          'last_modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
        },
      ]);
      final candidates = parseRemoteBackupCandidates(raw);
      expect(candidates.map((e) => e.name), [
        'backup_20260101_120000_000.json',
        'backup_20260102_120000.zip',
      ]);
      expect(
        candidates.first.lastModifiedMillis,
        DateTime(2026, 1, 1, 12).millisecondsSinceEpoch,
        reason: 'HTTP 日期非法时必须回退文件名时间',
      );
      expect(
        candidates.last.lastModifiedMillis,
        HttpDate.parse('Wed, 21 Oct 2015 07:28:00 GMT').millisecondsSinceEpoch,
        reason: 'HTTP 日期优先于文件名时间',
      );
    });

    test('非法日期回退失败（月/日越界）时跳过该条', () {
      final raw = jsonEncode([
        {
          'name': 'backup_20261301_120000.json',
          'is_dir': false,
          'last_modified': '',
        },
        {
          'name': 'backup_20260101_250000.json',
          'is_dir': false,
          'last_modified': 'bad',
        },
      ]);
      expect(parseRemoteBackupCandidates(raw), isEmpty);
    });

    test('取 mtime 最大的条目（同时间取先出现者）', () {
      final raw = jsonEncode([
        {
          'name': 'backup_a.json',
          'last_modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
        },
        {
          'name': 'backup_b.json',
          'last_modified': 'Thu, 22 Oct 2015 07:28:00 GMT',
        },
        {
          'name': 'backup_c.json',
          'last_modified': 'Thu, 22 Oct 2015 07:28:00 GMT',
        },
      ]);
      expect(latestRemoteBackupCandidate(raw)?.name, 'backup_b.json');
    });

    test('顶层不是数组时抛 FormatException', () {
      expect(
        () => parseRemoteBackupCandidates('{}'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('checkNow 条件', () {
    test('开关关闭 → disabled，不列目录', () async {
      await settings.setBoolPref(PrefKeys.autoCheckNewBackup, false);
      seedNewerRemote();
      expect(await build().checkNow(), AutoCheckNewBackupDecision.disabled);
      expect(api.listCalls, 0);
      expect(confirmCalls, 0);
    });

    test('开关关闭不消费配额：本会话再次开启后仍可检查', () async {
      await settings.setBoolPref(PrefKeys.autoCheckNewBackup, false);
      final scheduler = build();
      expect(await scheduler.checkNow(), AutoCheckNewBackupDecision.disabled);
      expect(api.listCalls, 0);

      await settings.setBoolPref(PrefKeys.autoCheckNewBackup, true);
      api.listJson = '[]';
      expect(
        await scheduler.checkNow(),
        AutoCheckNewBackupDecision.noRemoteBackup,
      );
      expect(api.listCalls, 1);
    });

    test('WebDAV 未配置 → notConfigured，不列目录', () async {
      webDav.configJson = null;
      seedNewerRemote();
      expect(
        await build().checkNow(),
        AutoCheckNewBackupDecision.notConfigured,
      );
      expect(api.listCalls, 0);
    });

    test('备份/恢复进行中 → busy，不列目录', () async {
      seedNewerRemote();
      final gate = Completer<void>();
      final running = LocalBackupService.instance.runExclusive(() async {
        await gate.future;
        return null;
      });
      await Future<void>.delayed(Duration.zero);

      // maxBusyRetries=0：本用例只验证首次 busy 判定，不产生延迟重试
      expect(
        await build(maxBusyRetries: 0).checkNow(),
        AutoCheckNewBackupDecision.busy,
      );
      expect(api.listCalls, 0);
      expect(confirmCalls, 0);

      gate.complete();
      await running;
    });

    test('busy 不消费配额：锁释放后延迟重试并完成检查', () async {
      seedNewerRemote();
      final lockGate = Completer<void>();
      final running = LocalBackupService.instance.runExclusive(() async {
        await lockGate.future;
        return null;
      });
      await Future<void>.delayed(Duration.zero);

      final retryGate = Completer<void>();
      final promptReached = Completer<void>();
      var delayCalls = 0;
      final scheduler = AutoCheckNewBackupScheduler(
        api: api,
        settings: settings,
        webDavBackupService: webDav,
        restoreService: restoreService,
        confirmRestore: (fileName) async {
          if (!promptReached.isCompleted) promptReached.complete();
          return false;
        },
        notify: (message) async => messages.add(message),
        startupDelay: Duration.zero,
        busyRetryDelay: const Duration(seconds: 30),
        delay: (duration) async {
          delayCalls++;
          await retryGate.future;
        },
        clock: () => DateTime(2026, 11, 10, 12),
      );

      expect(await scheduler.checkNow(), AutoCheckNewBackupDecision.busy);
      expect(delayCalls, 1, reason: 'busy 必须安排延迟重试');
      expect(api.listCalls, 0);

      lockGate.complete();
      await running;
      retryGate.complete();
      await promptReached.future;
      await pumpEventQueue();
      expect(api.listCalls, 1, reason: '锁释放后重试应真正检查');
      expect(await scheduler.checkNow(), AutoCheckNewBackupDecision.skipped);
    });

    test('列表异常 → 静默 failed，不弹窗不提示', () async {
      api.listError = Exception('network down');
      expect(await build().checkNow(), AutoCheckNewBackupDecision.failed);
      expect(confirmCalls, 0);
      expect(messages, isEmpty);
    });

    test('远端无 backup 文件 → noRemoteBackup', () async {
      api.listJson = jsonEncode([
        {'name': 'books', 'is_dir': true, 'last_modified': null},
      ]);
      expect(
        await build().checkNow(),
        AutoCheckNewBackupDecision.noRemoteBackup,
      );
      expect(confirmCalls, 0);
    });

    test('远端未超过阈值 → noNewBackup，不弹窗', () async {
      await settings.setLastBackupTime(remoteMillis - 60000);
      seedNewerRemote();
      expect(await build().checkNow(), AutoCheckNewBackupDecision.noNewBackup);
      expect(confirmCalls, 0);
    });

    test('进程内只执行一次：第二次返回 skipped 且不再列目录', () async {
      api.listJson = '[]';
      final scheduler = build();
      expect(
        await scheduler.checkNow(),
        AutoCheckNewBackupDecision.noRemoteBackup,
      );
      expect(await scheduler.checkNow(), AutoCheckNewBackupDecision.skipped);
      expect(api.listCalls, 1);
    });
  });

  group('提示与去重', () {
    test('确认恢复成功：提示「恢复成功」、写 seen、不写 lastBackup', () async {
      seedNewerRemote();
      confirmAnswer = true;
      final scheduler = build();

      expect(await scheduler.checkNow(), AutoCheckNewBackupDecision.restored);
      expect(confirmCalls, 1);
      expect(lastConfirmName, 'backup_20261110_120000_123.json');
      expect(restoreService.calls, 1);
      expect(restoreService.lastName, 'backup_20261110_120000_123.json');
      expect(restoreService.lastConfigJson, '{"url":"x"}');
      expect(restoreService.refreshCalls, 1);
      expect(messages, ['恢复成功']);
      expect(
        await settings.getIntPref(
          PrefKeys.lastSeenRemoteBackupMtime,
          defaultValue: 0,
        ),
        remoteMillis,
      );
      expect(await settings.getLastBackupTime(), 0, reason: '不得改 lastBackup');
    });

    test('取消：不恢复、已写 seen、无成功提示', () async {
      seedNewerRemote();
      confirmAnswer = false;
      expect(
        await build().checkNow(),
        AutoCheckNewBackupDecision.promptDeclined,
      );
      expect(restoreService.calls, 0);
      expect(messages, isEmpty);
      expect(
        await settings.getIntPref(
          PrefKeys.lastSeenRemoteBackupMtime,
          defaultValue: 0,
        ),
        remoteMillis,
      );
    });

    test('点遮罩/返回（null）：不恢复、不写 seen、下次可再提示', () async {
      seedNewerRemote();
      confirmAnswer = null;
      expect(
        await build().checkNow(),
        AutoCheckNewBackupDecision.promptDismissed,
      );
      expect(restoreService.calls, 0);
      expect(messages, isEmpty);
      expect(
        await settings.getIntPref(
          PrefKeys.lastSeenRemoteBackupMtime,
          defaultValue: 0,
        ),
        0,
        reason: '未明确选择不得写去重键',
      );
    });

    test('主路由未稳定（闪屏）：不弹窗、不写 seen', () async {
      seedNewerRemote();
      var checks = 0;
      final scheduler = build(
        canPresentPrompt: () {
          checks++;
          return false;
        },
        maxPromptReadyChecks: 2,
      );
      expect(
        await scheduler.checkNow(),
        AutoCheckNewBackupDecision.promptDeferred,
      );
      expect(checks, 3, reason: '初始判定 + 2 次延迟复检');
      expect(confirmCalls, 0);
      expect(
        await settings.getIntPref(
          PrefKeys.lastSeenRemoteBackupMtime,
          defaultValue: 0,
        ),
        0,
      );
    });

    test('主路由延迟就绪：等待后弹窗并写 seen', () async {
      seedNewerRemote();
      confirmAnswer = false;
      var checks = 0;
      final scheduler = build(
        canPresentPrompt: () => ++checks >= 3,
        maxPromptReadyChecks: 5,
      );
      expect(
        await scheduler.checkNow(),
        AutoCheckNewBackupDecision.promptDeclined,
      );
      expect(confirmCalls, 1);
      expect(
        await settings.getIntPref(
          PrefKeys.lastSeenRemoteBackupMtime,
          defaultValue: 0,
        ),
        remoteMillis,
      );
    });

    test('seen 已覆盖远端 → noNewBackup，不弹窗', () async {
      await settings.setIntPref(
        PrefKeys.lastSeenRemoteBackupMtime,
        remoteMillis,
      );
      seedNewerRemote();
      expect(await build().checkNow(), AutoCheckNewBackupDecision.noNewBackup);
      expect(confirmCalls, 0);
    });

    test('需密码备份：确认后不恢复、提示手动处理、seen 已消费', () async {
      seedNewerRemote();
      confirmAnswer = true;
      restoreService.result = const WebDavRestoreRunResult.passwordRequired();
      final scheduler = build();
      expect(
        await scheduler.checkNow(),
        AutoCheckNewBackupDecision.passwordRequired,
      );
      expect(restoreService.calls, 1);
      expect(messages, ['该备份需要密码，请在备份恢复页手动恢复']);
      expect(
        await settings.getIntPref(
          PrefKeys.lastSeenRemoteBackupMtime,
          defaultValue: 0,
        ),
        remoteMillis,
        reason: '用户已看到提示，同备份不再重复弹窗',
      );
      expect(await scheduler.checkNow(), AutoCheckNewBackupDecision.skipped);
    });

    test('恢复失败：提示失败且不出现「恢复成功」', () async {
      seedNewerRemote();
      confirmAnswer = true;
      restoreService.result = WebDavRestoreRunResult.failed(
        Exception('restore boom'),
      );
      expect(
        await build().checkNow(),
        AutoCheckNewBackupDecision.restoreFailed,
      );
      expect(messages.length, 1);
      expect(messages.single, startsWith('恢复失败'));
      expect(messages, isNot(contains('恢复成功')));
    });
  });

  group('隐私闸门', () {
    test('锁定期间不检查不弹窗；解锁后立即补检查一次', () async {
      final gate = ValueNotifier<bool>(true);
      addTearDown(gate.dispose);
      seedNewerRemote();
      final confirmReached = Completer<void>();
      final scheduler = AutoCheckNewBackupScheduler(
        api: api,
        settings: settings,
        webDavBackupService: webDav,
        restoreService: restoreService,
        privacyLocked: gate,
        confirmRestore: (fileName) async {
          if (!confirmReached.isCompleted) confirmReached.complete();
          return false;
        },
        notify: (message) async => messages.add(message),
        startupDelay: Duration.zero,
        delay: (_) async {},
      );

      await scheduler.start();
      expect(api.listCalls, 0, reason: '锁定期间不得列目录');
      expect(confirmCalls, 0);

      gate.value = false;
      await confirmReached.future;
      expect(api.listCalls, 1, reason: '解锁且延迟已过应立即补检查');
    });

    test('延迟未结束前解锁：延迟结束后检查一次', () async {
      final gate = ValueNotifier<bool>(true);
      addTearDown(gate.dispose);
      final delayGate = Completer<void>();
      seedNewerRemote();
      final scheduler = build(
        gate: gate,
        startupDelay: const Duration(seconds: 5),
        delay: (_) => delayGate.future,
      );

      final started = scheduler.start();
      gate.value = false;
      await Future<void>.delayed(Duration.zero);
      expect(confirmCalls, 0, reason: '延迟未结束不得检查');

      delayGate.complete();
      await started;
      expect(api.listCalls, 1);
      expect(confirmCalls, 1);
    });
  });

  group('attach', () {
    testWidgets('首帧后延迟 5s 检查一次', (tester) async {
      api.listJson = '[]';
      await api.webdavServerSave(
        jsonEncode({
          'id': -1,
          'name': '默认 WebDAV',
          'type': 'WEBDAV',
          'config': jsonEncode({
            'url': 'https://dav.example.com',
            'username': '',
            'password': '',
          }),
          'sortNumber': 0,
        }),
      );
      final gate = ValueNotifier<bool>(false);
      addTearDown(gate.dispose);

      AutoCheckNewBackupScheduler.attach(api: api, privacyLocked: gate);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(api.listCalls, 0, reason: '5s 延迟未到不得检查');

      await tester.pump(const Duration(seconds: 4));
      expect(api.listCalls, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.listCalls, 1, reason: '延迟 5s 后应检查一次');
    });
  });
}
