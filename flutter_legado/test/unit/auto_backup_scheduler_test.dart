// 批40：AutoBackupScheduler 单测
//
// 覆盖：shouldBackup 天数边界（从未备份/差 1 毫秒/正好 N 天/间隔归一）、
// 开关关闭、未到期、到期执行（上传开关透传）、备份失败不写 lastBackup、
// 与手动备份互斥（busy 时跳过且不创建备份）、恢复互斥（恢复进行中 busy）、
// 锁内二次判定（autoBackup 关闭/已到期状态变化）、lastBackup 在未来视为到期。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/auto_backup_scheduler.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_backup_service.dart';

import '../mocks/mocks.dart';

/// 假本地备份服务：可注入 busy/异常/结果，记录调用参数
class _FakeLocalBackupService extends LocalBackupService {
  bool busy = false;
  Object? error;
  int createCalls = 0;
  bool? lastUploadWebDav;
  String? lastDirPath;

  @override
  Future<T?> runExclusive<T>(Future<T> Function() action) async {
    if (busy) return null;
    return action();
  }

  @override
  Future<LocalBackupResult> createBackup({
    required BookApi api,
    required String dirPath,
    required bool uploadWebDav,
    SettingsService? settings,
    WebDavBackupService? webDavBackupService,
    DateTime? now,
  }) async {
    createCalls++;
    lastUploadWebDav = uploadWebDav;
    lastDirPath = dirPath;
    final e = error;
    if (e != null) throw e;
    return const LocalBackupResult(filePath: '/tmp/legado_backup_auto.json');
  }
}

/// 可按调用次序返回不同值的设置桩（批40 回修 P3-5 锁内二次判定用例）
class _SequencedSettings extends SettingsService {
  _SequencedSettings({this.autoBackupValues, this.lastBackupValues});

  final List<bool>? autoBackupValues;
  final List<int>? lastBackupValues;
  int autoBackupCalls = 0;
  int lastBackupCalls = 0;

  @override
  Future<bool> getAutoBackup() async {
    final values = autoBackupValues;
    if (values == null || values.isEmpty) return super.getAutoBackup();
    final value = values[autoBackupCalls.clamp(0, values.length - 1)];
    autoBackupCalls++;
    return value;
  }

  @override
  Future<int> getLastBackupTime() async {
    final values = lastBackupValues;
    if (values == null || values.isEmpty) return super.getLastBackupTime();
    final value = values[lastBackupCalls.clamp(0, values.length - 1)];
    lastBackupCalls++;
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServersRustApi api;
  late SettingsService settings;
  late _FakeLocalBackupService backupService;
  final now = DateTime(2026, 10, 29, 12, 0, 0);

  setUp(() {
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    settings = SettingsService();
    backupService = _FakeLocalBackupService();
  });

  tearDown(LocalBackupService.resetForTest);

  AutoBackupScheduler buildScheduler({SettingsService? overrideSettings}) =>
      AutoBackupScheduler(
        api: api,
        settings: overrideSettings ?? settings,
        backupService: backupService,
        resolveBackupDir: () async => '/tmp/backup',
        clock: () => now,
      );

  group('shouldBackup 天数边界', () {
    test('从未备份 → 到期', () {
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: null,
          intervalDays: 1,
        ),
        isTrue,
      );
    });

    test('差 1 毫秒未满 1 天 → 未到期', () {
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.subtract(const Duration(days: 1, milliseconds: -1)),
          intervalDays: 1,
        ),
        isFalse,
      );
    });

    test('正好 1 天 → 到期（>= 边界）', () {
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.subtract(const Duration(days: 1)),
          intervalDays: 1,
        ),
        isTrue,
      );
    });

    test('间隔 2 天：48 小时未满 → 未到期；正好 48 小时 → 到期', () {
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.subtract(const Duration(hours: 47, minutes: 59)),
          intervalDays: 2,
        ),
        isFalse,
      );
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.subtract(const Duration(days: 2)),
          intervalDays: 2,
        ),
        isTrue,
      );
    });

    test('间隔 0/负数按 1 天处理', () {
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.subtract(const Duration(hours: 23)),
          intervalDays: 0,
        ),
        isFalse,
      );
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.subtract(const Duration(days: 1)),
          intervalDays: -5,
        ),
        isTrue,
      );
    });

    test('lastBackup 在未来（时钟回拨/恢复他机偏好）→ 视为到期', () {
      expect(
        AutoBackupScheduler.shouldBackup(
          now: now,
          lastBackup: now.add(const Duration(days: 3)),
          intervalDays: 1,
        ),
        isTrue,
      );
    });
  });

  group('checkNow', () {
    test('自动备份关闭 → disabled 且不创建备份', () async {
      await settings.setAutoBackup(false);
      expect(
        await buildScheduler().checkNow(),
        AutoBackupDecision.disabled,
      );
      expect(backupService.createCalls, 0);
    });

    test('未到间隔 → notDue 且不创建备份', () async {
      await settings.setLastBackupTime(
        now.subtract(const Duration(hours: 23)).millisecondsSinceEpoch,
      );
      expect(await buildScheduler().checkNow(), AutoBackupDecision.notDue);
      expect(backupService.createCalls, 0);
    });

    test('从未备份 → 到期执行，上传开关透传（默认 true）', () async {
      final decision = await buildScheduler().checkNow();
      expect(decision, AutoBackupDecision.done);
      expect(backupService.createCalls, 1);
      expect(backupService.lastUploadWebDav, isTrue);
      expect(backupService.lastDirPath, '/tmp/backup');
    });

    test('关闭「自动备份上传 WebDAV」→ uploadWebDav=false', () async {
      await settings.setAutoBackupWebDav(false);
      final decision = await buildScheduler().checkNow();
      expect(decision, AutoBackupDecision.done);
      expect(backupService.lastUploadWebDav, isFalse);
    });

    test('正好到达间隔天数 → 执行', () async {
      await settings.setLastBackupTime(
        now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      );
      expect(await buildScheduler().checkNow(), AutoBackupDecision.done);
      expect(backupService.createCalls, 1);
    });

    test('备份失败 → failed 且不更新 lastBackup', () async {
      backupService.error = Exception('备份失败');
      expect(
        await buildScheduler().checkNow(),
        AutoBackupDecision.failed,
      );
      expect(await settings.getLastBackupTime(), 0);
    });

    test('已有备份在执行 → busy 且不创建备份', () async {
      backupService.busy = true;
      expect(
        await buildScheduler().checkNow(),
        AutoBackupDecision.busy,
      );
      expect(backupService.createCalls, 0);
    });

    test('恢复进行中 → busy 且不创建备份（批40 回修 P2-2）', () async {
      final gate = Completer<void>();
      final restore = LocalBackupService.instance.runExclusiveRestore(() async {
        await gate.future;
        return true;
      });
      await Future<void>.delayed(Duration.zero);

      final scheduler = AutoBackupScheduler(
        api: api,
        settings: settings,
        backupService: LocalBackupService.instance,
        resolveBackupDir: () async => '/tmp/backup',
        clock: () => now,
      );
      expect(await scheduler.checkNow(), AutoBackupDecision.busy);
      expect(backupService.createCalls, 0);

      gate.complete();
      expect(await restore, isTrue);
    });

    test('锁内复检开关：首次判定后被关闭 → disabled 且不创建备份', () async {
      final sequenced = _SequencedSettings(autoBackupValues: [true, false]);
      final scheduler = buildScheduler(overrideSettings: sequenced);

      expect(await scheduler.checkNow(), AutoBackupDecision.disabled);
      expect(sequenced.autoBackupCalls, 2, reason: '锁内必须复检 autoBackup');
      expect(backupService.createCalls, 0);
    });

    test('锁内二次判定到期状态：等待锁期间已备份 → notDue', () async {
      final sequenced = _SequencedSettings(
        lastBackupValues: [0, now.millisecondsSinceEpoch],
      );
      final scheduler = buildScheduler(overrideSettings: sequenced);

      expect(await scheduler.checkNow(), AutoBackupDecision.notDue);
      expect(sequenced.lastBackupCalls, 2, reason: '锁内必须复检到期状态');
      expect(backupService.createCalls, 0);
    });
  });
}
