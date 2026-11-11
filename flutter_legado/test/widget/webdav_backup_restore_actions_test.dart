// 批11：备份/恢复设置页动作链路测试
//
// 覆盖（真断言，均在修复前会失败）：
// - 备份 Sheet 各选项调用正确服务：仅本地不触网；仅网络不写用户目录且
//   清理临时目录；未配置 WebDAV 时仅网络禁用；长按备份行保留本地+WebDAV；
// - 恢复 Sheet：四项顺序；网络恢复列表名称降序、选中后下载覆盖并写
//   lastSeen（不写 lastBackup）；远端最新按 mtime 最大；本地最新挑选
//   最新文件（无文件提示）；列表失败回退本地选择器；空列表提示；
// - 本地恢复（Sheet 入口）zip 需要密码时仍弹密码框。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

import '../mocks/mocks.dart';

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;
  int pickCalls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCalls++;
    return result;
  }
}

void _useFakeFilePicker(FilePicker fake) {
  FilePicker? original;
  var initialized = false;
  try {
    original = FilePicker.platform;
    initialized = true;
  } catch (_) {
    // 宿主未初始化（测试 registrant 无本平台分支）
  }
  FilePicker.platform = fake;
  addTearDown(
    () => FilePicker.platform = initialized ? original! : FilePickerIO(),
  );
}

String _sep() => Platform.pathSeparator;

String _nameOf(FileSystemEntity entity) {
  final segments = entity.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.isEmpty ? '' : segments.last;
}

Set<String> _tempArtifacts(String prefix) {
  return Directory.systemTemp
      .listSync()
      .map(_nameOf)
      .where((name) => name.startsWith(prefix))
      .toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServersRustApi api;
  late Directory userDir;

  setUpAll(registerFallbacks);

  setUp(() {
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    userDir = Directory.systemTemp.createTempSync('legado_user_backup_');
    when(() => api.getBooks()).thenAnswer((_) async => <Book>[]);
    when(() => api.getBookSources()).thenAnswer((_) async => <BookSource>[]);
    when(() => api.setConfig(any(), any())).thenAnswer((_) async {});
    when(
      () => api.restore(any(), password: any(named: 'password')),
    ).thenAnswer((_) async {});
    when(() => api.backupInspect(any())).thenAnswer(
      (_) async => const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: false,
        passwordProtectedFiles: [],
      ),
    );
  });

  tearDown(() {
    LocalBackupService.resetForTest();
    try {
      if (userDir.existsSync()) userDir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 文件句柄延迟释放不影响断言
    }
  });

  void configureWebDav() {
    api.seedServer(
      config: jsonEncode({
        'url': 'https://dav.example.com/',
        'username': 'u',
        'password': 'p',
      }),
    );
  }

  /// 匿名 WebDAV：只有 URL，账号/密码为空（上传/列目录仍需可用）
  void configureWebDavAnonymous() {
    api.seedServer(
      config: jsonEncode({
        'url': 'https://dav.example.com/',
        'username': '',
        'password': '',
      }),
    );
  }

  void setUserBackupPath() {
    SharedPreferences.setMockInitialValues({'app_backup_path': userDir.path});
  }

  /// `api.backup` 在传入目录内写一个合法 JSON 备份文件
  void stubBackupWritingFile({String name = 'legado_backup_100.json'}) {
    when(() => api.backup(any())).thenAnswer((invocation) async {
      final dir = invocation.positionalArguments.first as String;
      final path = '$dir${_sep()}$name';
      await File(path).writeAsString('{}');
      return path;
    });
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openBackupSheet(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('备份'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份'));
    await tester.pumpAndSettle();
  }

  Future<void> openRestoreSheet(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
  }

  /// 推进真实事件循环直到目标出现（进度框/文件 IO 场景不能用 pumpAndSettle）
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
  }

  Finder dialogButton(String label) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(label));

  /// 远端列表 JSON 桩（last_modified 留空 → 回退文件名时间）
  void stubRemoteList(List<Map<String, Object?>> items) {
    when(
      () => api.webdavListDir(any(), ''),
    ).thenAnswer((_) async => jsonEncode(items));
  }

  /// 打开恢复 Sheet → 网络恢复 → 等远端列表入场完成
  Future<void> openRemoteBackupList(WidgetTester tester) async {
    await openRestoreSheet(tester);
    await tester.tap(find.text('网络恢复'));
    await pumpUntilFound(tester, find.text('选择远端备份'));
    await tester.pumpAndSettle();
  }

  group('备份 Sheet 动作', () {
    testWidgets('仅本地：调用 api.backup 用户目录，不上传 WebDAV', (tester) async {
      setUserBackupPath();
      stubBackupWritingFile();
      final settings = SettingsService();

      await pumpScreen(tester);
      await openBackupSheet(tester);
      await tester.tap(find.text('备份至本地'));
      await pumpUntilFound(tester, find.textContaining('备份成功'));

      verify(() => api.backup(userDir.path)).called(1);
      verifyNever(() => api.webdavUploadFile(any(), any(), any()));
      expect(
        File('${userDir.path}${_sep()}legado_backup_100.json').existsSync(),
        isTrue,
      );
      expect(await settings.getLastBackupTime(), greaterThan(0));
    });

    testWidgets('点遮罩取消：不执行任何备份', (tester) async {
      setUserBackupPath();
      await pumpScreen(tester);
      await openBackupSheet(tester);

      // 遮罩层点按关闭（参考版无取消按钮）
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(find.text('备份至本地'), findsNothing);
      verifyNever(() => api.backup(any()));
      verifyNever(() => api.webdavUploadFile(any(), any(), any()));
    });

    testWidgets('仅网络：未配置时禁用，点按不创建备份', (tester) async {
      await pumpScreen(tester);
      await openBackupSheet(tester);

      // 批11 回修 P2-2：「备份至网络」与「备份至本地与网络」均置灰
      expect(find.text('请先配置 WebDAV'), findsNWidgets(2));
      await tester.tap(find.text('备份至网络'));
      await tester.pumpAndSettle();

      // 禁用原因只保留行内副标题（无 SnackBar），点按不执行
      expect(find.text('请先配置 WebDAV'), findsNWidgets(2));
      verifyNever(() => api.backup(any()));
      verifyNever(() => api.webdavUploadFile(any(), any(), any()));
    });

    testWidgets('仅网络：备份落临时目录、上传后清理，不写用户备份目录', (tester) async {
      configureWebDav();
      setUserBackupPath();
      String? tempBackupPath;
      when(() => api.backup(any())).thenAnswer((invocation) async {
        final dir = invocation.positionalArguments.first as String;
        final path = '$dir${_sep()}legado_backup_100.json';
        tempBackupPath = path;
        await File(path).writeAsString('{}');
        return path;
      });
      when(
        () => api.webdavUploadFile(any(), any(), any()),
      ).thenAnswer((_) async {});
      final before = _tempArtifacts('legado_webdav_only_');
      final settings = SettingsService();

      await pumpScreen(tester);
      await openBackupSheet(tester);
      await tester.tap(find.text('备份至网络'));
      await pumpUntilFound(tester, find.textContaining('备份成功'));

      expect(tempBackupPath, isNotNull);
      expect(tempBackupPath, contains('legado_webdav_only_'));
      verify(
        () => api.webdavUploadFile(any(), any(), tempBackupPath!),
      ).called(1);
      // 用户目录不得出现备份文件
      expect(userDir.listSync(), isEmpty);
      // 临时目录已清理
      final after = _tempArtifacts('legado_webdav_only_');
      expect(after.difference(before), isEmpty);
      expect(await settings.getLastBackupTime(), greaterThan(0));
    });

    testWidgets('忙碌态：Sheet 全部选项禁用，点按不执行备份', (tester) async {
      final gate = Completer<void>();
      final lock = LocalBackupService.instance.runExclusive(() async {
        await gate.future;
        return null;
      });

      await pumpScreen(tester);
      await openBackupSheet(tester);

      expect(find.text('正在备份或恢复，请稍候'), findsNWidgets(3));
      await tester.tap(find.text('备份至本地'));
      await tester.pumpAndSettle();

      expect(find.text('正在备份或恢复，请稍候'), findsNWidgets(3));
      verifyNever(() => api.backup(any()));

      gate.complete();
      await lock;
    });

    testWidgets('长按备份行保留本地+WebDAV 快捷', (tester) async {
      configureWebDav();
      setUserBackupPath();
      stubBackupWritingFile();
      when(
        () => api.webdavUploadFile(any(), any(), any()),
      ).thenAnswer((_) async {});

      await pumpScreen(tester);
      await tester.scrollUntilVisible(find.text('备份'), 100);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('备份'));
      await pumpUntilFound(tester, find.textContaining('已上传 WebDAV'));

      verify(() => api.backup(userDir.path)).called(1);
      verify(() => api.webdavUploadFile(any(), any(), any())).called(1);
    });

    testWidgets('仅网络：上传失败提示「备份失败」，不写用户目录/临时目录并回滚 lastBackup', (tester) async {
      configureWebDav();
      setUserBackupPath();
      stubBackupWritingFile();
      when(
        () => api.webdavUploadFile(any(), any(), any()),
      ).thenThrow(Exception('上传失败'));
      final settings = SettingsService();
      await settings.setLastBackupTime(4242);
      final before = _tempArtifacts('legado_webdav_only_');

      await pumpScreen(tester);
      await openBackupSheet(tester);
      await tester.tap(find.text('备份至网络'));
      await pumpUntilFound(tester, find.textContaining('备份失败'));

      expect(find.textContaining('备份失败'), findsOneWidget);
      expect(userDir.listSync(), isEmpty);
      final after = _tempArtifacts('legado_webdav_only_');
      expect(after.difference(before), isEmpty, reason: '失败后临时目录必须清理');
      expect(
        await settings.getLastBackupTime(),
        4242,
        reason: '仅网络失败不得推迟自动备份周期',
      );
    });

    testWidgets('匿名 WebDAV（仅 URL）：备份至网络可用', (tester) async {
      configureWebDavAnonymous();
      setUserBackupPath();
      stubBackupWritingFile();
      when(
        () => api.webdavUploadFile(any(), any(), any()),
      ).thenAnswer((_) async {});

      await pumpScreen(tester);
      await openBackupSheet(tester);

      expect(
        find.text('请先配置 WebDAV'),
        findsNothing,
        reason: '上传只要求 URL，账号/密码可空',
      );
      await tester.tap(find.text('备份至网络'));
      await pumpUntilFound(tester, find.textContaining('备份成功'));

      verify(() => api.webdavUploadFile(any(), any(), any())).called(1);
    });
  });

  group('恢复 Sheet 动作', () {
    testWidgets('本地恢复：文件选择 → 确认 → restore，写 seen 不改 lastBackup', (
      tester,
    ) async {
      setUserBackupPath();
      final backupPath = '${userDir.path}${_sep()}legado_backup_manual.json';
      File(backupPath).writeAsStringSync('{}');
      final picker = _FakeFilePicker(
        FilePickerResult([
          PlatformFile(
            name: 'legado_backup_manual.json',
            size: 0,
            path: backupPath,
          ),
        ]),
      );
      _useFakeFilePicker(picker);

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      expect(find.text('本地恢复'), findsOneWidget);
      await tester.tap(find.text('本地恢复'));
      await tester.pumpAndSettle();

      expect(find.text('确认恢复吗？'), findsOneWidget);
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.text('恢复成功'));

      verify(() => api.restore(backupPath, password: null)).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), greaterThan(0));
      expect(prefs.getInt(PrefKeys.lastBackup), isNull);
    });

    testWidgets('本地恢复：zip 需要密码时仍弹密码框（Sheet 入口）', (tester) async {
      setUserBackupPath();
      final backupPath = '${userDir.path}${_sep()}legado_backup_pwd.zip';
      File(backupPath).writeAsStringSync('PK\x03\x04');
      when(() => api.backupInspect(any())).thenAnswer(
        (_) async => const BackupInspectInfo(
          format: BackupFormat.zip,
          passwordRequired: true,
          passwordProtectedFiles: ['servers.json'],
        ),
      );
      _useFakeFilePicker(
        _FakeFilePicker(
          FilePickerResult([
            PlatformFile(
              name: 'legado_backup_pwd.zip',
              size: 0,
              path: backupPath,
            ),
          ]),
        ),
      );

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('本地恢复'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('恢复'));
      await tester.pumpAndSettle();

      expect(find.text('输入备份密码'), findsOneWidget);
      verifyNever(() => api.restore(any(), password: any(named: 'password')));
    });

    testWidgets('本地最新：挑选 millis 最大文件并恢复', (tester) async {
      setUserBackupPath();
      final latest = '${userDir.path}${_sep()}legado_backup_300.json';
      File(
        '${userDir.path}${_sep()}legado_backup_100.json',
      ).writeAsStringSync('{}');
      File(latest).writeAsStringSync('{}');
      File(
        '${userDir.path}${_sep()}legado_backup_200.json',
      ).writeAsStringSync('{}');
      File('${userDir.path}${_sep()}other.json').writeAsStringSync('{}');

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('本地最新'));
      await pumpUntilFound(tester, find.text('确认恢复吗？'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.text('恢复成功'));

      verify(() => api.restore(latest, password: null)).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), greaterThan(0));
      expect(prefs.getInt(PrefKeys.lastBackup), isNull);
    });

    testWidgets('本地最新：无备份文件提示「未找到本地备份」且不恢复', (tester) async {
      setUserBackupPath();

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('本地最新'));
      await pumpUntilFound(tester, find.text('未找到本地备份'));

      verifyNever(() => api.restore(any(), password: any(named: 'password')));
    });

    testWidgets('网络恢复：列表名称降序，选中项下载覆盖并写远端 mtime', (tester) async {
      configureWebDav();
      final jan1 = HttpDate.parse(
        'Thu, 01 Jan 2026 12:00:00 GMT',
      ).millisecondsSinceEpoch;
      final jan2 = HttpDate.parse(
        'Fri, 02 Jan 2026 12:00:00 GMT',
      ).millisecondsSinceEpoch;
      final jan3 = HttpDate.parse(
        'Sat, 03 Jan 2026 12:00:00 GMT',
      ).millisecondsSinceEpoch;
      when(() => api.webdavListDir(any(), '')).thenAnswer(
        (_) async => jsonEncode([
          {
            'name': 'backup_20260101_120000.json',
            'is_dir': false,
            'last_modified': 'Thu, 01 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'backup_20260103_120000.json',
            'is_dir': false,
            'last_modified': 'Sat, 03 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'backup_20260102_120000.json',
            'is_dir': false,
            'last_modified': 'Fri, 02 Jan 2026 12:00:00 GMT',
          },
        ]),
      );
      final downloaded = <String>[];
      when(() => api.webdavDownloadFile(any(), any(), any())).thenAnswer((
        invocation,
      ) async {
        final remoteName = invocation.positionalArguments[1] as String;
        final localPath = invocation.positionalArguments[2] as String;
        downloaded.add(remoteName);
        await File(localPath).writeAsString('{}');
      });
      final before = _tempArtifacts('legado_webdav_restore_');

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('网络恢复'));
      await pumpUntilFound(tester, find.text('选择远端备份'));
      // 等 Sheet 入场动画结束，避免按坐标点按落在屏幕外
      await tester.pumpAndSettle();

      final y3 = tester.getTopLeft(find.text('backup_20260103_120000.json')).dy;
      final y2 = tester.getTopLeft(find.text('backup_20260102_120000.json')).dy;
      final y1 = tester.getTopLeft(find.text('backup_20260101_120000.json')).dy;
      expect(y3, lessThan(y2));
      expect(y2, lessThan(y1), reason: '远端列表按名称降序');

      await tester.tap(find.text('backup_20260102_120000.json'));
      await tester.pumpAndSettle();
      expect(find.text('确认恢复吗？'), findsOneWidget);
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.text('恢复成功'));

      expect(downloaded, ['backup_20260102_120000.json']);
      verify(() => api.restore(any(), password: null)).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), jan2);
      expect(prefs.getInt(PrefKeys.lastBackup), isNull);
      final after = _tempArtifacts('legado_webdav_restore_');
      expect(after.difference(before), isEmpty, reason: '下载临时目录必须清理');

      // sanity：三个时间戳均有效且互不相同
      expect({jan1, jan2, jan3}, hasLength(3));
    });

    testWidgets('远端最新：按 mtime 最大（不是名称最大）下载恢复并写 seen', (tester) async {
      configureWebDav();
      final latestMillis = HttpDate.parse(
        'Sat, 03 Jan 2026 12:00:00 GMT',
      ).millisecondsSinceEpoch;
      when(() => api.webdavListDir(any(), '')).thenAnswer(
        (_) async => jsonEncode([
          {
            // 名称最大，但 mtime 最新的是 20260101 这条
            'name': 'backup_20260103_120000.json',
            'is_dir': false,
            'last_modified': 'Thu, 01 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'backup_20260101_120000.json',
            'is_dir': false,
            'last_modified': 'Sat, 03 Jan 2026 12:00:00 GMT',
          },
          {
            'name': 'backup_20260102_120000.json',
            'is_dir': false,
            'last_modified': 'Fri, 02 Jan 2026 12:00:00 GMT',
          },
        ]),
      );
      final downloaded = <String>[];
      when(() => api.webdavDownloadFile(any(), any(), any())).thenAnswer((
        invocation,
      ) async {
        final remoteName = invocation.positionalArguments[1] as String;
        final localPath = invocation.positionalArguments[2] as String;
        downloaded.add(remoteName);
        await File(localPath).writeAsString('{}');
      });

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('远端最新'));
      await pumpUntilFound(tester, find.text('确认恢复吗？'));
      await tester.pumpAndSettle();
      expect(find.text('选择远端备份'), findsNothing, reason: '远端最新不弹列表');
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.text('恢复成功'));

      expect(downloaded, ['backup_20260101_120000.json']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), latestMillis);
      expect(prefs.getInt(PrefKeys.lastBackup), isNull);
    });

    testWidgets('网络恢复：列表为空提示「未找到远端备份」', (tester) async {
      configureWebDav();
      when(() => api.webdavListDir(any(), '')).thenAnswer((_) async => '[]');

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('网络恢复'));
      await pumpUntilFound(tester, find.text('未找到远端备份'));

      verifyNever(() => api.webdavDownloadFile(any(), any(), any()));
      verifyNever(() => api.restore(any(), password: any(named: 'password')));
    });

    testWidgets('网络恢复：列表失败回退询问，确认后走本地选择器', (tester) async {
      configureWebDav();
      when(
        () => api.webdavListDir(any(), ''),
      ).thenThrow(const SocketException('offline'));
      final picker = _FakeFilePicker(null);
      _useFakeFilePicker(picker);

      await pumpScreen(tester);
      await openRestoreSheet(tester);
      await tester.tap(find.text('网络恢复'));
      await pumpUntilFound(tester, find.text('网络备份列表获取失败，是否改为本地恢复？'));

      verifyNever(() => api.webdavDownloadFile(any(), any(), any()));
      await tester.tap(dialogButton('本地恢复'));
      await tester.pumpAndSettle();

      expect(picker.pickCalls, 1);
      verifyNever(() => api.restore(any(), password: any(named: 'password')));
    });

    testWidgets('匿名 WebDAV（仅 URL）：网络恢复/远端最新可用', (tester) async {
      configureWebDavAnonymous();
      stubRemoteList(const []);

      await pumpScreen(tester);
      await openRestoreSheet(tester);

      expect(
        find.text('请先配置 WebDAV'),
        findsNothing,
        reason: '列目录只要求 URL，账号/密码可空',
      );
      await tester.tap(find.text('远端最新'));
      await pumpUntilFound(tester, find.text('未找到远端备份'));

      verify(() => api.webdavListDir(any(), '')).called(1);
    });

    testWidgets('网络恢复：下载异常 → 恢复失败且不写 seen', (tester) async {
      configureWebDav();
      stubRemoteList([
        {
          'name': 'backup_20260101_120000.json',
          'is_dir': false,
          'last_modified': '',
        },
      ]);
      when(
        () => api.webdavDownloadFile(any(), any(), any()),
      ).thenThrow(Exception('下载失败'));

      await pumpScreen(tester);
      await openRemoteBackupList(tester);
      await tester.tap(find.text('backup_20260101_120000.json'));
      await tester.pumpAndSettle();
      expect(find.text('确认恢复吗？'), findsOneWidget);
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.textContaining('恢复失败'));

      expect(find.textContaining('恢复失败'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime),
        isNull,
        reason: '恢复失败不得写去重键',
      );
      verifyNever(() => api.restore(any(), password: any(named: 'password')));
    });

    testWidgets('网络恢复：restore 异常 → 恢复失败且不写 seen', (tester) async {
      configureWebDav();
      stubRemoteList([
        {
          'name': 'backup_20260101_120000.json',
          'is_dir': false,
          'last_modified': '',
        },
      ]);
      when(() => api.webdavDownloadFile(any(), any(), any())).thenAnswer((
        invocation,
      ) async {
        final localPath = invocation.positionalArguments[2] as String;
        await File(localPath).writeAsString('{}');
      });
      when(
        () => api.restore(any(), password: any(named: 'password')),
      ).thenThrow(Exception('写入失败'));

      await pumpScreen(tester);
      await openRemoteBackupList(tester);
      await tester.tap(find.text('backup_20260101_120000.json'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.textContaining('恢复失败'));

      expect(find.textContaining('恢复失败'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), isNull);
    });

    /// 密码 zip 网络恢复公共桩：远端只有一份加密 zip，下载写 zip 魔数，
    /// 探测恒为「需要密码」。
    void stubPasswordZipRemote({
      String name = 'backup_20260101_120000.zip',
      String lastModified = 'Thu, 01 Jan 2026 12:00:00 GMT',
    }) {
      stubRemoteList([
        {'name': name, 'is_dir': false, 'last_modified': lastModified},
      ]);
      when(() => api.webdavDownloadFile(any(), any(), any())).thenAnswer((
        invocation,
      ) async {
        final localPath = invocation.positionalArguments[2] as String;
        await File(localPath).writeAsString('PK\x03\x04');
      });
      when(() => api.backupInspect(any())).thenAnswer(
        (_) async => const BackupInspectInfo(
          format: BackupFormat.zip,
          passwordRequired: true,
          passwordProtectedFiles: ['servers.json'],
        ),
      );
    }

    /// 等待唯一一个备份密码对话框稳定出现（输入框 + 确定按钮）
    ///
    /// 密码错误重试时旧对话框退场、新对话框入场会有短暂重叠；光标闪烁
    /// 会持续调度帧（pumpAndSettle 可能超时），故按「唯一 AlertDialog +
    /// 唯一 TextField」判定并用固定时长推进入场动画。
    Future<void> waitForPasswordDialog(WidgetTester tester) async {
      for (var i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        final dialogs = find.byType(AlertDialog).evaluate();
        final fields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        if (dialogs.length == 1 &&
            fields.evaluate().length == 1 &&
            find.text('输入备份密码').evaluate().isNotEmpty) {
          await tester.pump(const Duration(milliseconds: 300));
          return;
        }
      }
      fail('备份密码对话框未出现');
    }

    /// 打开网络恢复列表并选中密码 zip、确认恢复，等密码框出现
    Future<void> startRemotePasswordRestore(WidgetTester tester) async {
      await pumpScreen(tester);
      await openRemoteBackupList(tester);
      await tester.tap(find.text('backup_20260101_120000.zip'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('恢复'));
      await waitForPasswordDialog(tester);
    }

    testWidgets('网络恢复：密码 zip 弹密码框，正确密码完成恢复并写 seen', (tester) async {
      configureWebDav();
      final expectedSeen = HttpDate.parse(
        'Thu, 01 Jan 2026 12:00:00 GMT',
      ).millisecondsSinceEpoch;
      stubPasswordZipRemote();

      await startRemotePasswordRestore(tester);
      await tester.enterText(find.byType(TextField), '正确的 密码');
      await tester.tap(dialogButton('确定'));
      await pumpUntilFound(tester, find.text('恢复成功'));

      verify(() => api.restore(any(), password: '正确的 密码')).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), expectedSeen);
      expect(prefs.getInt(PrefKeys.lastBackup), isNull);
    });

    testWidgets('网络恢复：密码 zip 取消输入 → 不恢复、不写 seen', (tester) async {
      configureWebDav();
      stubPasswordZipRemote();

      await startRemotePasswordRestore(tester);
      await tester.tap(dialogButton('取消'));
      await tester.pumpAndSettle();

      expect(find.text('输入备份密码'), findsNothing);
      verifyNever(() => api.restore(any(), password: any(named: 'password')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), isNull);
    });

    testWidgets('网络恢复：密码连续错误三次 → 中止且不写 seen', (tester) async {
      configureWebDav();
      stubPasswordZipRemote();
      when(() => api.restore(any(), password: 'wrong')).thenAnswer(
        (_) async => throw Exception(
          'FFI error: Internal error: BACKUP_PASSWORD_INVALID: 备份密码错误',
        ),
      );

      await startRemotePasswordRestore(tester);
      for (var i = 0; i < 3; i++) {
        await waitForPasswordDialog(tester);
        await tester.enterText(find.byType(TextField), 'wrong');
        await tester.tap(dialogButton('确定'));
        if (i < 2) {
          // 前两次：密码框重开并内联提示，允许继续重试
          await pumpUntilFound(tester, find.text('密码错误或备份已损坏，请重试'));
        } else {
          // 第三次：中止循环，不再重开密码框
          await pumpUntilFound(tester, find.text('密码错误次数过多，已取消恢复'));
        }
      }

      // 第三次提交后密码框开始退场；pumpUntilFound 只保证提示已插入，
      // 再固定推进一段以完成对话框退场动画。
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('输入备份密码'), findsNothing);
      expect(find.text('密码错误次数过多，已取消恢复'), findsOneWidget);
      verify(() => api.restore(any(), password: 'wrong')).called(3);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), isNull);
    });

    testWidgets('网络恢复：忙碌 → 提示稍候、不下载/不恢复/不写 seen', (tester) async {
      configureWebDav();
      stubRemoteList([
        {
          'name': 'backup_20260101_120000.json',
          'is_dir': false,
          'last_modified': '',
        },
      ]);
      when(
        () => api.webdavDownloadFile(any(), any(), any()),
      ).thenAnswer((_) async {});

      await pumpScreen(tester);
      await openRemoteBackupList(tester);

      // 列表已取到后模拟自动备份启动，再确认恢复 → 互斥拒绝
      final gate = Completer<void>();
      final lock = LocalBackupService.instance.runExclusive(() async {
        await gate.future;
        return null;
      });
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      await tester.tap(find.text('backup_20260101_120000.json'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.text('正在备份或恢复，请稍候'));

      verifyNever(() => api.webdavDownloadFile(any(), any(), any()));
      verifyNever(() => api.restore(any(), password: any(named: 'password')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime), isNull);

      gate.complete();
      await lock;
    });

    testWidgets('远端恢复成功：seen 取 max(现有, 候选 mtime)，不调低', (tester) async {
      configureWebDav();
      stubRemoteList([
        {
          'name': 'backup_20260101_120000.json',
          'is_dir': false,
          'last_modified': '',
        },
      ]);
      when(() => api.webdavDownloadFile(any(), any(), any())).thenAnswer((
        invocation,
      ) async {
        final localPath = invocation.positionalArguments[2] as String;
        await File(localPath).writeAsString('{}');
      });
      const futureSeen = 9999999999999;
      SharedPreferences.setMockInitialValues({
        PrefKeys.lastSeenRemoteBackupMtime: futureSeen,
      });

      await pumpScreen(tester);
      await openRemoteBackupList(tester);
      await tester.tap(find.text('backup_20260101_120000.json'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('恢复'));
      await pumpUntilFound(tester, find.text('恢复成功'));

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime),
        futureSeen,
        reason: '恢复较旧远端不得把 seen 调低（会重复提示）',
      );
    });
  });
}
