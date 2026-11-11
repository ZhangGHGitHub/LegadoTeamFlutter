/// 本地恢复「备份密码」流程（批17b）
///
/// 契约 §2.11：原版 zip 备份可能带备份密码（`servers.json` 恒加密，
/// `cookies.json` / `runtimeSourceCache.json` 设过密码时加密）。
/// 本测试钉住：
/// - 探测需要密码 → 弹密码框（列出受保护文件中文标签），取消即中止、
///   零 restore 调用；
/// - 密码错误 → 重开密码框并内联提示，允许重试；正确后以 password 调用；
/// - 探测无需密码 → 不弹框，restore 的 password 为 null；
/// - 中文/含空格密码原样透传（不 trim）；
/// - `.json` 备份不调用 backupInspect；
/// - 加密内容损坏 → 提示备份文件损坏，不进入重试；
/// - [批17c P2-2] 空/纯空白密码提交 → 内联「请输入备份密码」，不调用 restore；
/// - [批17c P3-5] `.json` 命名的加密 zip（按文件魔数判定）仍弹密码框；
/// - [批17c P3-7] 探测称无需密码但后端返回 BACKUP_PASSWORD_REQUIRED →
///   防御性重开密码框。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/eye_protection.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_menu_style_notifier.dart';
import 'package:flutter_legado/src/providers/theme/eye_protection_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_style.dart';

import '../mocks/mocks.dart';

/// 记录 pickFiles 调用/参数并返回预置结果的 FilePicker 桩
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

/// 注入 FilePicker 平台桩并登记恢复（同 bookshelf_add_local_cbz_test 模式）
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

void main() {
  late FakeServersRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    // 批40 回修 P2-2：恢复/备份互斥为进程内静态状态，逐用例复位
    // （上一用例可能在上一个 pump 结束前仍持有锁）
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
    when(
      () => mockApi.getBookSources(),
    ).thenAnswer((_) async => <BookSource>[]);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(
      () => mockApi.restore(any(), password: any(named: 'password')),
    ).thenAnswer((_) async {});
  });

  /// 探测结果：原版 zip、需要密码、三个受保护条目
  void stubPasswordRequired() {
    when(() => mockApi.backupInspect(any())).thenAnswer(
      (_) async => const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: true,
        passwordProtectedFiles: [
          'servers.json',
          'cookies.json',
          'runtimeSourceCache.json',
        ],
      ),
    );
  }

  /// 探测结果：原版 zip、无需密码
  void stubPasswordNotRequired() {
    when(() => mockApi.backupInspect(any())).thenAnswer(
      (_) async => const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: false,
        passwordProtectedFiles: [],
      ),
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    ProviderContainer? container,
  }) async {
    final child = const MaterialApp(home: WebDavSettingsScreen());
    await tester.pumpWidget(
      container == null
          ? ProviderScope(
              overrides: [bookApiProvider.overrideWithValue(mockApi)],
              child: child,
            )
          : UncontrolledProviderScope(container: container, child: child),
    );
    await tester.pumpAndSettle();
  }

  Finder dialogButton(String label) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(label));

  /// 长按「恢复」→ 选文件 → 覆盖确认 → 进入（可选密码框）
  Future<void> startLocalRestore(
    WidgetTester tester, {
    required String backupPath,
    ProviderContainer? container,
  }) async {
    _useFakeFilePicker(
      _FakeFilePicker(
        FilePickerResult([
          PlatformFile(name: 'backup.zip', size: 0, path: backupPath),
        ]),
      ),
    );
    await pumpScreen(tester, container: container);

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('恢复'));
    await tester.pumpAndSettle();
    // 覆盖确认（本地恢复）
    expect(find.text('确认恢复吗？'), findsOneWidget);
    await tester.tap(dialogButton('恢复'));
    await tester.pumpAndSettle();
  }

  String fakeBackupPath(String name) =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}$name';

  testWidgets('探测需要密码：弹密码框列出受保护文件，取消后不调用 restore', (tester) async {
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_encrypted.zip');

    await startLocalRestore(tester, backupPath: backupPath);

    expect(find.text('输入备份密码'), findsOneWidget);
    expect(find.text('· 服务器配置（servers.json）'), findsOneWidget);
    expect(find.text('· 登录信息（cookies.json）'), findsOneWidget);
    expect(find.text('· 书源运行变量（runtimeSourceCache.json）'), findsOneWidget);
    // 密码默认隐藏（显示/隐藏切换按钮存在）
    expect(find.byTooltip('显示密码'), findsOneWidget);

    await tester.tap(dialogButton('取消'));
    await tester.pumpAndSettle();

    expect(find.text('输入备份密码'), findsNothing);
    verifyNever(() => mockApi.restore(any(), password: any(named: 'password')));
  });

  testWidgets('密码错误一次：重开密码框内联提示，第二次正确后以密码恢复', (tester) async {
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_retry.zip');
    when(() => mockApi.restore(any(), password: 'wrong')).thenAnswer(
      (_) async => throw Exception(
        'FFI error: Internal error: BACKUP_PASSWORD_INVALID: 备份密码错误',
      ),
    );

    await startLocalRestore(tester, backupPath: backupPath);
    expect(find.text('输入备份密码'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    // 密码框重开并内联提示（密码错误或备份已损坏）
    expect(find.text('输入备份密码'), findsOneWidget);
    expect(find.text('密码错误或备份已损坏，请重试'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '正确的 密码');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    expect(find.text('输入备份密码'), findsNothing);
    verify(() => mockApi.restore(backupPath, password: 'wrong')).called(1);
    verify(() => mockApi.restore(backupPath, password: '正确的 密码')).called(1);
  });

  testWidgets('本地恢复：密码连续错误三次后仍可继续重试（不设上限）', (tester) async {
    // 审查回修 P2-3：3 次上限只用于网络恢复；本地恢复沿用批17b 的无限重试。
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_retry_unlimited.zip');
    when(() => mockApi.restore(any(), password: 'wrong')).thenAnswer(
      (_) async => throw Exception(
        'FFI error: Internal error: BACKUP_PASSWORD_INVALID: 备份密码错误',
      ),
    );

    await startLocalRestore(tester, backupPath: backupPath);
    for (var i = 0; i < 3; i++) {
      expect(find.text('输入备份密码'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(dialogButton('确定'));
      await tester.pumpAndSettle();
      expect(find.text('密码错误或备份已损坏，请重试'), findsOneWidget);
    }

    await tester.enterText(find.byType(TextField), 'right');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    expect(find.text('输入备份密码'), findsNothing);
    verify(() => mockApi.restore(backupPath, password: 'wrong')).called(3);
    verify(() => mockApi.restore(backupPath, password: 'right')).called(1);
  });

  testWidgets('探测无需密码：不弹密码框，restore 的 password 为 null', (tester) async {
    stubPasswordNotRequired();
    final backupPath = fakeBackupPath('legado_backup_plain.zip');

    await startLocalRestore(tester, backupPath: backupPath);

    expect(find.text('输入备份密码'), findsNothing);
    verify(() => mockApi.restore(backupPath, password: null)).called(1);
  });

  // 批9b-4 审查回修 P2-2：恢复完成的 appPrefs 需同步全局 UserAgent 到 Rust
  testWidgets('恢复完成后把 userAgent 同步到 Rust config', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.userAgent: ' RestoredUA/1.0 ',
    });
    stubPasswordNotRequired();
    final backupPath = fakeBackupPath('legado_backup_ua.zip');

    await startLocalRestore(tester, backupPath: backupPath);

    verify(() => mockApi.restore(backupPath, password: null)).called(1);
    verify(
      () => mockApi.setConfig(PrefKeys.userAgent, 'RestoredUA/1.0'),
    ).called(1);
  });

  // 批9b-2 审查回修：恢复完成的 appPrefs 需同步 threadCount 到 Rust
  testWidgets('恢复完成后把 threadCount 同步到 Rust config', (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 12});
    stubPasswordNotRequired();
    final backupPath = fakeBackupPath('legado_backup_thread.zip');

    await startLocalRestore(tester, backupPath: backupPath);

    verify(() => mockApi.restore(backupPath, password: null)).called(1);
    verify(() => mockApi.setConfig(PrefKeys.threadCount, '12')).called(1);
  });

  // 批9b-2 审查回修：恢复后存量 >256 夹逼为 256 再同步 Rust
  testWidgets('恢复后 threadCount 存量 999 夹逼为 256 同步 Rust', (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 999});
    stubPasswordNotRequired();
    final backupPath = fakeBackupPath('legado_backup_thread_clamp.zip');

    await startLocalRestore(tester, backupPath: backupPath);

    verify(() => mockApi.setConfig(PrefKeys.threadCount, '256')).called(1);
  });

  // [设置批2a-1 P2-1] 恢复 appPrefs 后护眼设置同会话重读（reload 而非
  // invalidate：避免 provider 重建时先以默认值渲染一帧导致滤镜闪断）。
  // 恢复写盘放在 mockApi.restore stub 内，模拟真实恢复顺序；同时监听
  // provider 中间状态，断言 reload 期间没有默认值帧、且状态变化发生在
  // 恢复写盘之后。
  testWidgets('恢复 appPrefs 后护眼设置同会话立即重读（无默认值中间帧）', (tester) async {
    final backupPath = fakeBackupPath('legado_backup_eye_settings.zip');
    var restoreWrotePrefs = false;
    when(
      () => mockApi.restore(any(), password: any(named: 'password')),
    ).thenAnswer((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PrefKeys.eyeProtectionEnabled, true);
      await prefs.setInt(PrefKeys.colorTemperature, 30);
      await prefs.setString(PrefKeys.eyeProtectionStartTime, '23:00');
      restoreWrotePrefs = true;
    });

    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    // 先挂一个空宿主并冲刷加载，使 provider 以默认值稳定（模拟恢复前已
    // 打开过护眼设置/全局叠加层）
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    container.read(eyeProtectionProvider);
    await tester.pumpAndSettle();
    expect(container.read(eyeProtectionProvider).enabled, isFalse);

    // 监听 reload 期间的状态迁移（首轮加载已稳定，之后只应有恢复后的新值）
    final transitions = <EyeProtectionSettings>[];
    final wroteFlags = <bool>[];
    final subscription = container.listen<EyeProtectionSettings>(
      eyeProtectionProvider,
      (previous, next) {
        transitions.add(next);
        wroteFlags.add(restoreWrotePrefs);
      },
      fireImmediately: false,
    );
    addTearDown(subscription.close);

    stubPasswordNotRequired();
    await startLocalRestore(
      tester,
      backupPath: backupPath,
      container: container,
    );

    verify(() => mockApi.restore(backupPath, password: null)).called(1);
    final restored = container.read(eyeProtectionProvider);
    expect(restored.enabled, isTrue, reason: '恢复后同会话内应立即生效，不得等重启');
    expect(restored.intensity, 30);
    expect(restored.startTime, '23:00');
    // 中间状态证据：reload 直接旧值→新值，不得出现默认值帧；且此次状态
    // 迁移必须发生在恢复写盘之后（若实现退回 invalidate，会先发默认值）
    expect(
      transitions.where((s) => s == const EyeProtectionSettings()),
      isEmpty,
      reason: 'reload 期间不得回落默认 EyeProtectionSettings（会闪断滤镜）',
    );
    expect(transitions, isNotEmpty);
    expect(transitions.last, restored);
    expect(
      wroteFlags,
      everyElement(isTrue),
      reason: 'provider 更新必须晚于 mock restore 写盘',
    );
  });

  testWidgets('恢复 appPrefs 后容器外观设置同会话立即重读', (tester) async {
    // [设置批2b-1a] 容器不透明度/容器背景图/背景图虚化随 appPrefs 恢复后，
    // _reloadPrefsAfterRestore 必须 await 重读 uiSettingsProvider，否则页面
    // 与 IosGroup/全局背景层继续用恢复前的旧值到重启为止。
    final backupPath = fakeBackupPath('legado_backup_container_theme.zip');
    var restoreWrotePrefs = false;
    when(
      () => mockApi.restore(any(), password: any(named: 'password')),
    ).thenAnswer((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(PrefKeys.containerOpacity, 30);
      await prefs.setBool(PrefKeys.enableContainerBackgroundImage, true);
      await prefs.setInt(PrefKeys.bgImageBlurring, 44);
      await prefs.setString(
        PrefKeys.largeContainerBackgroundImageLight,
        'theme_backgrounds/large_light/restored.png',
      );
      restoreWrotePrefs = true;
    });

    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await container.read(uiSettingsProvider.notifier).reload();
    await tester.pumpAndSettle();
    expect(container.read(uiSettingsProvider).containerOpacity, 100);

    final transitions = <UiSettingsState>[];
    final wroteFlags = <bool>[];
    final subscription = container.listen<UiSettingsState>(uiSettingsProvider, (
      previous,
      next,
    ) {
      transitions.add(next);
      wroteFlags.add(restoreWrotePrefs);
    }, fireImmediately: false);
    addTearDown(subscription.close);

    stubPasswordNotRequired();
    await startLocalRestore(
      tester,
      backupPath: backupPath,
      container: container,
    );

    verify(() => mockApi.restore(backupPath, password: null)).called(1);
    final restored = container.read(uiSettingsProvider);
    expect(restored.containerOpacity, 30, reason: '恢复后同会话立即生效');
    expect(restored.enableContainerBackgroundImage, isTrue);
    expect(restored.bgImageBlurring, 44);
    expect(
      restored.largeContainerBackgroundImageLight,
      'theme_backgrounds/large_light/restored.png',
    );
    expect(transitions, isNotEmpty);
    expect(transitions.last.containerOpacity, 30);
    expect(
      wroteFlags,
      everyElement(isTrue),
      reason: 'provider 更新必须晚于 mock restore 写盘',
    );
  });

  testWidgets('恢复 appPrefs 后菜单样式 provider 同会话重读（批3a）', (tester) async {
    // 备份恢复会覆盖 readBarStyle/底栏布局/标题模式等键；若 webdav 恢复
    // 完成只 invalidate 旧顶栏配置而漏掉 readerMenuStyleProvider，本会话
    // 会继续用恢复前的样式直到重启。
    final backupPath = fakeBackupPath('legado_backup_menu_style.zip');
    var restoreWrotePrefs = false;
    when(
      () => mockApi.restore(any(), password: any(named: 'password')),
    ).thenAnswer((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(PrefKeys.readBarStyle, 2);
      await prefs.setInt(PrefKeys.readMenuIconItemsPerRow, 3);
      await prefs.setString(PrefKeys.titleBarMode, '2');
      restoreWrotePrefs = true;
    });

    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    expect(container.read(readerMenuStyleProvider).readBarStyle, 1);

    final postRestoreUpdates = <ReaderMenuStyle>[];
    final subscription = container.listen<ReaderMenuStyle>(
      readerMenuStyleProvider,
      (previous, next) {
        if (restoreWrotePrefs) postRestoreUpdates.add(next);
      },
      fireImmediately: false,
    );
    addTearDown(subscription.close);

    stubPasswordNotRequired();
    await startLocalRestore(
      tester,
      backupPath: backupPath,
      container: container,
    );
    await tester.pumpAndSettle();

    verify(() => mockApi.restore(backupPath, password: null)).called(1);
    final restored = container.read(readerMenuStyleProvider);
    expect(restored.readBarStyle, 2, reason: '恢复后同会话立即生效');
    expect(restored.itemsPerRow, 3);
    expect(restored.titleBarMode, '2');
    expect(postRestoreUpdates, isNotEmpty, reason: '恢复后必须触发重读');
    expect(
      postRestoreUpdates.last.readBarStyle,
      2,
      reason: 'provider 更新必须晚于 mock restore 写盘并使用新值',
    );
  });

  testWidgets('中文/含空格密码原样透传（不 trim）', (tester) async {
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_cn_pwd.zip');

    await startLocalRestore(tester, backupPath: backupPath);
    await tester.enterText(find.byType(TextField), '  密码 中文 ');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    verify(() => mockApi.restore(backupPath, password: '  密码 中文 ')).called(1);
  });

  testWidgets('加密内容损坏：提示备份文件损坏，不进入密码重试', (tester) async {
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_corrupt.zip');
    when(
      () => mockApi.restore(any(), password: any(named: 'password')),
    ).thenAnswer(
      (_) async => throw Exception(
        'FFI error: Internal error: BACKUP_ENCRYPTED_CONTENT_CORRUPT: '
        '备份中的 cookies.json 内容损坏',
      ),
    );

    await startLocalRestore(tester, backupPath: backupPath);
    await tester.enterText(find.byType(TextField), 'whatever');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    expect(find.text('备份文件已损坏，无法恢复加密内容'), findsOneWidget);
    expect(find.text('输入备份密码'), findsNothing);
  });

  testWidgets('JSON 备份不探测密码（不调用 backupInspect）', (tester) async {
    // 不 stub backupInspect：一旦误调用会抛 mocktail missing stub。
    // .json 恢复链会触发真实文件 IO（FakeAsync 不驱动），故不进 pumpAndSettle，
    // 只断言：确认后直接进入「恢复中…」，不出现「检查备份…」/密码框。
    final backupPath = fakeBackupPath('legado_backup_plain_pwd.json');
    _useFakeFilePicker(
      _FakeFilePicker(
        FilePickerResult([
          PlatformFile(name: 'backup.json', size: 0, path: backupPath),
        ]),
      ),
    );
    await pumpScreen(tester);

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(find.text('确认恢复吗？'), findsOneWidget);
    await tester.tap(dialogButton('恢复'));
    await tester.pump();

    expect(find.text('恢复中…'), findsOneWidget);
    expect(find.text('检查备份…'), findsNothing);
    expect(find.text('输入备份密码'), findsNothing);
    verifyNever(() => mockApi.backupInspect(any()));
  });

  // ─── 批17c P2-2：空密码提交不得静默成功 ─────────────────────────────

  testWidgets('空密码提交：内联提示且留在对话框，不调用 restore', (tester) async {
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_empty_pwd.zip');

    await startLocalRestore(tester, backupPath: backupPath);
    expect(find.text('输入备份密码'), findsOneWidget);

    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    // 对话框仍在、内联校验提示可见、零 restore 调用（后端会把空串当未提供）
    expect(find.text('输入备份密码'), findsOneWidget);
    expect(find.text('请输入备份密码'), findsOneWidget);
    verifyNever(() => mockApi.restore(any(), password: any(named: 'password')));
  });

  testWidgets('纯空白密码提交同样被拦截（密码原文不 trim）', (tester) async {
    stubPasswordRequired();
    final backupPath = fakeBackupPath('legado_backup_blank_pwd.zip');

    await startLocalRestore(tester, backupPath: backupPath);
    await tester.enterText(find.byType(TextField), '    ');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    expect(find.text('请输入备份密码'), findsOneWidget);
    verifyNever(() => mockApi.restore(any(), password: any(named: 'password')));

    // 补输真实密码后校验提示消失并原样透传（含首尾空格）
    await tester.enterText(find.byType(TextField), '  pwd  ');
    await tester.pumpAndSettle();
    expect(find.text('请输入备份密码'), findsNothing);
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();
    verify(() => mockApi.restore(backupPath, password: '  pwd  ')).called(1);
  });

  // ─── 批17c P3-5：`.json` 命名的加密 zip 也弹密码框 ──────────────────

  testWidgets('.json 命名的加密 zip（文件魔数判定）仍弹密码框并透传密码', (tester) async {
    stubPasswordRequired();
    // 真实文件：PK\x03\x04 魔数（内容不必是合法 zip——本用例只驱动 UI 判定）。
    // 同步写入：testWidgets 的 FakeAsync 不驱动真实异步 I/O
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'legado_backup_renamed.json',
    );
    file.writeAsBytesSync([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    await startLocalRestore(tester, backupPath: file.path);

    expect(
      find.text('输入备份密码'),
      findsOneWidget,
      reason: '扩展名是 .json，但魔数表明是 zip 备份 → 必须探测并要求密码',
    );
    verify(() => mockApi.backupInspect(file.path)).called(1);

    await tester.enterText(find.byType(TextField), 'renamed-pwd');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();
    verify(() => mockApi.restore(file.path, password: 'renamed-pwd')).called(1);
  });

  // ─── 批17c P3-7：防御性 BACKUP_PASSWORD_REQUIRED 重开密码框 ──────────

  testWidgets('探测无需密码但后端要求密码：防御性重开密码框', (tester) async {
    stubPasswordNotRequired();
    final backupPath = fakeBackupPath('legado_backup_defensive.zip');
    when(() => mockApi.restore(any(), password: null)).thenAnswer(
      (_) async => throw Exception(
        'FFI error: Internal error: BACKUP_PASSWORD_REQUIRED: '
        '该备份包含原版加密的登录信息（cookies.json）',
      ),
    );
    when(
      () => mockApi.restore(any(), password: 'late-pwd'),
    ).thenAnswer((_) async {});

    await startLocalRestore(tester, backupPath: backupPath);

    // 探测称无需密码 → 先以 null 恢复 → 后端要求密码 → 重开密码框
    expect(find.text('输入备份密码'), findsOneWidget);
    verify(() => mockApi.restore(backupPath, password: null)).called(1);

    await tester.enterText(find.byType(TextField), 'late-pwd');
    await tester.tap(dialogButton('确定'));
    await tester.pumpAndSettle();

    expect(find.text('输入备份密码'), findsNothing);
    verify(() => mockApi.restore(backupPath, password: 'late-pwd')).called(1);
  });
}
