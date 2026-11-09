/// 隐私设置页 widget 测试（设置批9b；审查回修）
///
/// 覆盖：设置主页入口与路由、进入验证闸门（取消/错误/通过/只验不授权）、
/// 三组与默认值、启用开关（无密码弹设密框、取消不开启、成功后自动开启）、
/// 密码对话框校验、改密旧密错误、清密二次确认/enabled 回落/保存中不可关闭、
/// 策略写失败提示、生物快捷开关（开启/失败/关闭）、360dp + 1.6 倍字体无溢出。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/privacy_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/privacy_biometric_service.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

/// 清除凭据挂起（保存中禁止关闭测试）
class _SlowClearApi extends MockBookApi {
  final Completer<void> pendingClear = Completer<void>();

  @override
  Future<void> privacyClearPassword() => pendingClear.future;
}

/// 删除凭据抛错（清密失败文案测试）
class _FailingClearApi extends MockBookApi {
  @override
  Future<void> privacyClearPassword() async {
    throw StateError('删除失败');
  }
}

/// 私密标记读取失败（设置页“暂不可用”提示测试）
class _BrokenMarkersApi extends MockBookApi {
  @override
  Future<List<String>> getPrivateBookUrls() async {
    throw StateError('标记读取失败');
  }
}

/// 生物识别平台 Fake（批9d）
class _FakeBiometricService implements PrivacyBiometricService {
  static final String token = base64Encode(List<int>.filled(32, 7));
  static final String envelope = base64Encode(List<int>.filled(64, 9));
  static final String iv = base64Encode(List<int>.filled(12, 5));

  PrivacyBiometricStatus status = const PrivacyBiometricStatus(available: true);
  PrivacyBiometricErrorCode? enableError;
  int deleteCalls = 0;

  @override
  Future<PrivacyBiometricStatus> getStatus() async => status;

  @override
  Future<PrivacyBiometricEnvelope> enable(String tokenBase64) async {
    if (enableError != null) throw PrivacyBiometricException(enableError!);
    return PrivacyBiometricEnvelope(envelope: envelope, iv: iv);
  }

  @override
  Future<String> unlock({required String envelope, required String iv}) async =>
      token;

  @override
  Future<void> deleteKey() async => deleteCalls++;
}

/// 策略写入恒失败（UI SnackBar 测试）
class _FailingWriteStore extends PrivacyPolicyStore {
  const _FailingWriteStore();

  @override
  Future<bool> writeBool(String key, bool value) async => false;

  @override
  Future<bool> writeString(String key, String value) async => false;

  @override
  Future<bool> writeInt(String key, int value) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBookApi api;

  setUp(() {
    api = MockBookApi();
    SharedPreferences.setMockInitialValues({});
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    Size physicalSize = const Size(1080, 3000),
    double textScale = 1.0,
    Widget? home,
    PrivacyPolicyStore? store,
    PrivacyBiometricService? biometricService,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final overrides = <Override>[bookApiProvider.overrideWithValue(api)];
    if (store != null) {
      overrides.add(privacyPolicyStoreProvider.overrideWithValue(store));
    }
    if (biometricService != null) {
      overrides.add(
        privacyBiometricServiceProvider.overrideWithValue(biometricService),
      );
    }
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          onGenerateRoute: AppRoutes.generateRoute,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: home ?? const PrivacySettingsScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  PrivacyState stateOf(ProviderContainer container) =>
      container.read(privacyNotifierProvider);

  testWidgets('设置主页提供「隐私」入口并导航到隐私设置页', (tester) async {
    await pumpScreen(
      tester,
      home: const SettingsHomeScreen(),
      physicalSize: const Size(1080, 3600),
    );

    expect(find.text('隐私'), findsOneWidget);
    expect(find.text('应用锁与私密内容'), findsOneWidget);

    await tester.tap(find.text('隐私'));
    await tester.pumpAndSettle();

    expect(find.byType(PrivacySettingsScreen), findsOneWidget);
    expect(find.text('设置'), findsNothing);
  });

  testWidgets('隐私路由经 AppRoutes 构建设置页而非首页兜底', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          onGenerateRoute: AppRoutes.generateRoute,
          initialRoute: AppRoutes.privacy,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PrivacySettingsScreen), findsOneWidget);
    expect(find.text('隐私'), findsOneWidget);
  });

  testWidgets('进入验证：未验证看不到设置项、取消返回、验证通过且只验不授权', (tester) async {
    await api.privacySetPassword('pw');
    final container = await pumpScreen(
      tester,
      home: const SettingsHomeScreen(),
      prefs: {PrefKeys.privateEnabled: true},
      physicalSize: const Size(1080, 3600),
    );

    await tester.tap(find.text('隐私'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('privacySettingsVerifyGate')),
      findsOneWidget,
    );
    expect(find.text('凭据'), findsNothing, reason: '未验证不得展示设置项');

    await tester.enterText(
      find.byKey(const ValueKey('privacySettingsVerifyField')),
      'bad',
    );
    await tester.tap(find.byKey(const ValueKey('privacySettingsVerifyButton')));
    await tester.pumpAndSettle();
    expect(find.text('密码错误'), findsOneWidget);
    expect(find.text('凭据'), findsNothing);

    // 取消返回上一页
    await tester.tap(find.byKey(const ValueKey('privacySettingsVerifyCancel')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsHomeScreen), findsOneWidget);
    expect(find.byType(PrivacySettingsScreen), findsNothing);

    // 重新进入并验证通过：只授予设置页访问，不置会话/启动解锁
    await tester.tap(find.text('隐私'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacySettingsVerifyField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacySettingsVerifyButton')));
    await tester.pumpAndSettle();
    expect(find.text('凭据'), findsOneWidget);
    expect(stateOf(container).sessionUnlocked, isFalse);
    expect(stateOf(container).appStartVerified, isFalse);
  });

  testWidgets('策略写入失败：提示保存失败且开关回滚', (tester) async {
    final container = await pumpScreen(
      tester,
      store: const _FailingWriteStore(),
    );
    expect(stateOf(container).verifyOnEnterGroup, isTrue);

    await tester.tap(
      find.byKey(const ValueKey('privacyVerifyEnterGroupSwitch')),
    );
    await tester.pumpAndSettle();

    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(stateOf(container).verifyOnEnterGroup, isTrue);
    final row = tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('privacyVerifyEnterGroupSwitch')),
    );
    expect(row.value, isTrue);
  });

  testWidgets('三组与默认值：凭据/验证时机/说明，生物快捷需先设密码', (tester) async {
    await pumpScreen(tester);

    expect(find.text('凭据'), findsOneWidget);
    expect(find.text('验证时机'), findsOneWidget);
    expect(find.text('说明'), findsOneWidget);

    SettingSwitchRow row(String key) =>
        tester.widget<SettingSwitchRow>(find.byKey(ValueKey(key)));

    expect(row('privacyEnabledSwitch').value, isFalse);
    expect(row('privacyVerifyEnterGroupSwitch').value, isTrue);
    expect(row('privacyVerifyOpenBookSwitch').value, isTrue);
    expect(row('privacyVerifyAppStartSwitch').value, isFalse);

    final scope = tester.widget<DropdownButton<PrivacyUnlockScope>>(
      find.byKey(const ValueKey('privacyUnlockScopeDropdown')),
    );
    expect(scope.value, PrivacyUnlockScope.appSession);
    expect(
      find.byKey(const ValueKey('privacyBackgroundGraceRow')),
      findsNothing,
    );

    final biometric = row('privacyBiometricSwitch');
    expect(biometric.value, isFalse);
    expect(biometric.onChanged, isNull, reason: '无密码/桌面平台不支持时生物开关置灰');
    expect(find.text('请先设置隐私密码'), findsOneWidget);

    final clearRow = tester.widget<IosListTile>(
      find.byKey(const ValueKey('privacyClearPasswordRow')),
    );
    expect(clearRow.enabled, isFalse, reason: '无密码时不可清除');
  });

  testWidgets('启用开关：无密码弹设密框，取消不开启，成功后自动开启', (tester) async {
    final container = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('privacyEnabledSwitch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyPasswordDialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyOldPasswordField')), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(stateOf(container).enabled, isFalse);
    expect(
      tester
          .widget<SettingSwitchRow>(
            find.byKey(const ValueKey('privacyEnabledSwitch')),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('privacyEnabledSwitch')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacyNewPasswordField')),
      'pass-1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacyConfirmPasswordField')),
      'pass-1',
    );
    await tester.tap(find.byKey(const ValueKey('privacyPasswordSaveButton')));
    await tester.pumpAndSettle();

    final s = stateOf(container);
    expect(s.hasPassword, isTrue);
    expect(s.enabled, isTrue);
    expect(await api.privacyVerifyPassword('pass-1'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateEnabled), isTrue);
  });

  testWidgets('密码对话框校验：空新密码、两次不一致', (tester) async {
    final container = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('privacyPasswordRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacyPasswordSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('新密码不能为空'), findsOneWidget);
    expect(stateOf(container).hasPassword, isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('privacyNewPasswordField')),
      'abc',
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacyConfirmPasswordField')),
      'abd',
    );
    await tester.tap(find.byKey(const ValueKey('privacyPasswordSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    expect(stateOf(container).hasPassword, isFalse);
  });

  testWidgets('改密：旧密错误内联提示，正确旧密后新密码生效', (tester) async {
    await api.privacySetPassword('old-pass');
    final container = await pumpScreen(tester);

    expect(find.text('修改密码'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('privacyPasswordRow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('privacyOldPasswordField')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('privacyOldPasswordField')),
      'bad',
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacyNewPasswordField')),
      'new-pass',
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacyConfirmPasswordField')),
      'new-pass',
    );
    await tester.tap(find.byKey(const ValueKey('privacyPasswordSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('密码错误'), findsOneWidget);
    expect(stateOf(container).hasPassword, isTrue);
    expect(await api.privacyVerifyPassword('old-pass'), isTrue);

    await tester.enterText(
      find.byKey(const ValueKey('privacyOldPasswordField')),
      'old-pass',
    );
    await tester.tap(find.byKey(const ValueKey('privacyPasswordSaveButton')));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyPasswordDialog), findsNothing);
    expect(await api.privacyVerifyPassword('new-pass'), isTrue);
    expect(await api.privacyVerifyPassword('old-pass'), isFalse);
  });

  testWidgets('清密：空密码与错密拦截，成功后提示并关闭 enabled', (tester) async {
    await api.privacySetPassword('pw');
    final container = await pumpScreen(
      tester,
      prefs: {PrefKeys.privateEnabled: true},
    );

    // enabled + 已有密码：先通过设置页验证闸门
    expect(
      find.byKey(const ValueKey('privacySettingsVerifyGate')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacySettingsVerifyField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacySettingsVerifyButton')));
    await tester.pumpAndSettle();
    expect(find.text('凭据'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('privacyClearPasswordRow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('privacyClearPasswordDialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('privacyClearPasswordConfirmButton')),
    );
    await tester.pumpAndSettle();
    expect(find.text('请输入当前密码'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('privacyClearPasswordField')),
      'bad',
    );
    await tester.tap(
      find.byKey(const ValueKey('privacyClearPasswordConfirmButton')),
    );
    await tester.pumpAndSettle();
    expect(find.text('密码错误'), findsOneWidget);
    expect(stateOf(container).hasPassword, isTrue);

    await tester.enterText(
      find.byKey(const ValueKey('privacyClearPasswordField')),
      'pw',
    );
    await tester.tap(
      find.byKey(const ValueKey('privacyClearPasswordConfirmButton')),
    );
    await tester.pumpAndSettle();

    final s = stateOf(container);
    expect(s.hasPassword, isFalse);
    expect(s.enabled, isFalse);
    expect(find.text('私密功能已关闭'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateEnabled), isFalse);
  });

  testWidgets('清密删除失败：提示清除失败且凭据保持有效', (tester) async {
    final failing = _FailingClearApi();
    api = failing;
    await failing.privacySetPassword('pw');
    final container = await pumpScreen(
      tester,
      prefs: {PrefKeys.privateEnabled: true},
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacySettingsVerifyField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacySettingsVerifyButton')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('privacyClearPasswordRow')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacyClearPasswordField')),
      'pw',
    );
    await tester.tap(
      find.byKey(const ValueKey('privacyClearPasswordConfirmButton')),
    );
    await tester.pumpAndSettle();

    expect(find.text('清除失败，请重试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('privacyClearPasswordDialog')),
      findsOneWidget,
    );
    expect(stateOf(container).hasPassword, isTrue);
    expect(await failing.privacyVerifyPassword('pw'), isTrue);
  });

  testWidgets('清密保存中：遮罩点击与系统返回都不能关闭对话框', (tester) async {
    final slow = _SlowClearApi();
    api = slow;
    await slow.privacySetPassword('pw');
    final container = await pumpScreen(
      tester,
      prefs: {PrefKeys.privateEnabled: true},
    );
    await tester.enterText(
      find.byKey(const ValueKey('privacySettingsVerifyField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacySettingsVerifyButton')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('privacyClearPasswordRow')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacyClearPasswordField')),
      'pw',
    );
    await tester.tap(
      find.byKey(const ValueKey('privacyClearPasswordConfirmButton')),
    );
    await tester.pump();

    // 遮罩点击不关闭
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('privacyClearPasswordDialog')),
      findsOneWidget,
    );

    // 系统返回被 PopScope 消费
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('privacyClearPasswordDialog')),
      findsOneWidget,
    );

    slow.pendingClear.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('privacyClearPasswordDialog')),
      findsNothing,
    );
    expect(stateOf(container).hasPassword, isFalse);
    expect(stateOf(container).enabled, isFalse);
  });

  testWidgets('验证频率下拉：切到 untilBackground 显示宽限，选 30 秒持久化', (tester) async {
    final container = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('privacyUnlockScopeDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离开后台后').last);
    await tester.pumpAndSettle();

    expect(stateOf(container).unlockScope, PrivacyUnlockScope.untilBackground);
    expect(
      find.byKey(const ValueKey('privacyBackgroundGraceRow')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('privacyBackgroundGraceDropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 秒').last);
    await tester.pumpAndSettle();
    expect(stateOf(container).backgroundGraceSeconds, 30);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.privateBackgroundGraceSeconds), 30);
    expect(prefs.getString(PrefKeys.privateUnlockScope), 'until_background');

    // 切回 AppSession 后宽限行隐藏
    await tester.tap(find.byKey(const ValueKey('privacyUnlockScopeDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用会话内').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('privacyBackgroundGraceRow')),
      findsNothing,
    );
  });

  testWidgets('私密标记读取失败：设置页提示暂不可用（仍 fail-open）', (tester) async {
    api = _BrokenMarkersApi();
    await pumpScreen(tester);
    expect(
      find.byKey(const ValueKey('privacyMarkersUnavailable')),
      findsOneWidget,
    );
    expect(find.textContaining('私密标记暂不可用'), findsOneWidget);
  });

  testWidgets('360dp + 1.6 倍字体：页面与密码对话框无溢出', (tester) async {
    await pumpScreen(
      tester,
      physicalSize: const Size(1080, 1920),
      textScale: 1.6,
    );
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('privacyPasswordRow')),
      100,
    );
    await tester.tap(find.byKey(const ValueKey('privacyPasswordRow')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(PrivacyPasswordDialog), findsOneWidget);
  });

  // ===== [批9d] 生物快捷解锁开关 =====

  testWidgets('生物开关：有密码且平台可用时可开启，成功后状态点亮', (tester) async {
    final fake = _FakeBiometricService();
    await api.privacySetPassword('pw');
    final container = await pumpScreen(tester, biometricService: fake);

    SettingSwitchRow row() => tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('privacyBiometricSwitch')),
    );
    expect(row().value, isFalse);
    expect(row().onChanged, isNotNull);
    expect(find.text('使用指纹或面容快速解锁'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('privacyBiometricSwitch')));
    await tester.pumpAndSettle();

    expect(row().value, isTrue);
    expect(stateOf(container).biometricConfigured, isTrue);
    expect(find.text('已开启，解锁时可使用指纹或面容'), findsOneWidget);
  });

  testWidgets('生物开启失败：不点亮、提示中文原因并置灰', (tester) async {
    final fake = _FakeBiometricService()
      ..enableError = PrivacyBiometricErrorCode.noHardware;
    await api.privacySetPassword('pw');
    final container = await pumpScreen(tester, biometricService: fake);

    await tester.tap(find.byKey(const ValueKey('privacyBiometricSwitch')));
    await tester.pumpAndSettle();

    expect(stateOf(container).biometricConfigured, isFalse);
    expect(find.text('设备不支持指纹或面容识别'), findsWidgets);
    final row = tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('privacyBiometricSwitch')),
    );
    expect(row.value, isFalse);
    expect(row.onChanged, isNull);
  });

  testWidgets('生物关闭：清信封、销毁原生密钥并回到关闭态', (tester) async {
    final fake = _FakeBiometricService();
    await api.privacySetPassword('pw');
    await api.privacyBiometricSet(
      _FakeBiometricService.token,
      _FakeBiometricService.envelope,
      _FakeBiometricService.iv,
    );
    final container = await pumpScreen(tester, biometricService: fake);

    SettingSwitchRow row() => tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('privacyBiometricSwitch')),
    );
    expect(row().value, isTrue);
    await tester.tap(find.byKey(const ValueKey('privacyBiometricSwitch')));
    await tester.pumpAndSettle();

    expect(row().value, isFalse);
    expect(stateOf(container).biometricConfigured, isFalse);
    expect(fake.deleteCalls, 1);
    expect(
      await api.privacyBiometricVerify(_FakeBiometricService.token),
      isFalse,
    );
  });
}
