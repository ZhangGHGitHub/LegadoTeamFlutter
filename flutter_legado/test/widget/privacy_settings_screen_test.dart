/// 隐私设置页 widget 测试（设置批9b）
///
/// 覆盖：设置主页入口与路由、三组与默认值、启用开关（无密码弹设密框、
/// 取消不开启、成功后自动开启）、密码对话框校验、改密旧密错误、
/// 清密二次确认与 enabled 回落、生物快捷置灰、360dp + 1.6 倍字体无溢出。
library;

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
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

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
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
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

  testWidgets('三组与默认值：凭据/验证时机/说明，生物快捷暂未支持', (tester) async {
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
    expect(biometric.onChanged, isNull, reason: '9d 生物识别前置灰');
    expect(find.text('暂未支持'), findsOneWidget);

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
}
