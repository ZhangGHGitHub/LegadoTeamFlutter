/// 隐私启动闸门 widget 测试（设置批9b；审查回修）
///
/// 覆盖：未启用直通（加载期不闪现主页）、需要锁时不显示但保留 child、
/// 错误密码重试、正确解锁显示、回车提交、连续提交防抖、策略/凭据读取
/// 失败 fail-closed 与重试、退出调用 SystemNavigator.pop、返回键消费、
/// 隐藏子树焦点隔离、软键盘 viewInsets 抬升、后台超时重新锁定、
/// 生物快捷解锁（成功/取消/失败回退密码）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/privacy_biometric_service.dart';
import 'package:flutter_legado/src/widgets/privacy/privacy_app_start_gate.dart';

/// 凭据读取可失败的 Mock（fail-closed 测试）
class _FlakyCredentialApi extends MockBookApi {
  bool failHasPassword = true;

  @override
  Future<bool> privacyHasPassword() {
    if (failHasPassword) {
      throw const BridgeError(message: '数据库尚未初始化');
    }
    return super.privacyHasPassword();
  }
}

/// 策略读取可恢复失败（fail-closed 重试测试）
class _FlakyPolicyStore extends PrivacyPolicyStore {
  bool failRead = true;

  @override
  Future<PrivacyPolicy> read() {
    if (failRead) throw const FormatException('策略存储不可读');
    return super.read();
  }
}

/// 生物识别平台 Fake（批9d）
class _FakeBiometricService implements PrivacyBiometricService {
  static final String token = base64Encode(List<int>.filled(32, 7));
  static final String envelope = base64Encode(List<int>.filled(64, 9));
  static final String iv = base64Encode(List<int>.filled(12, 5));

  PrivacyBiometricStatus status = const PrivacyBiometricStatus(available: true);
  PrivacyBiometricErrorCode? unlockError;
  String? unlockTokenOverride;
  Completer<String>? unlockCompleter;

  @override
  Future<PrivacyBiometricStatus> getStatus() async => status;

  @override
  Future<PrivacyBiometricEnvelope> enable(String tokenBase64) async =>
      PrivacyBiometricEnvelope(envelope: envelope, iv: iv);

  @override
  Future<String> unlock({required String envelope, required String iv}) async {
    if (unlockCompleter != null) return unlockCompleter!.future;
    if (unlockError != null) throw PrivacyBiometricException(unlockError!);
    return unlockTokenOverride ?? token;
  }

  @override
  Future<void> deleteKey() async {}
}

/// 预置「密码 + 生物凭据」
Future<void> _seedBiometric(MockBookApi api) async {
  await api.privacySetPassword('pw');
  await api.privacyBiometricSet(
    _FakeBiometricService.token,
    _FakeBiometricService.envelope,
    _FakeBiometricService.iv,
  );
}

/// 解锁校验挂起（连续提交防抖测试）
class _SlowVerifyApi extends MockBookApi {
  int verifyCalls = 0;
  final Completer<bool> pending = Completer<bool>();

  @override
  Future<bool> privacyVerifyPassword(String password) {
    verifyCalls++;
    return pending.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpGate(
    WidgetTester tester, {
    required MockBookApi api,
    Map<String, Object> prefs = const {},
    PrivacyPolicyStore? store,
    GlobalKey<NavigatorState>? navigatorKey,
    Widget? home,
    double textScale = 1.0,
    bool earlyBackGuard = false,
    bool settle = true,
    PrivacyBiometricService? biometricService,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = const Size(1080, 1920);
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
    if (earlyBackGuard) {
      // 复刻 LegadoApp 根级守卫：先于 MaterialApp/WidgetsApp 注册
      final guard = PrivacyBackGuard(
        () => container.read(privacyNotifierProvider),
      );
      WidgetsBinding.instance.addObserver(guard);
      addTearDown(() => WidgetsBinding.instance.removeObserver(guard));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: PrivacyAppStartGate(child: child ?? const SizedBox.shrink()),
          ),
          home: home ?? const Scaffold(body: Center(child: Text('应用主页'))),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
    return container;
  }

  testWidgets('异步加载期间显示占位且不闪现主页；未启用时直通', (tester) async {
    final api = MockBookApi();
    await pumpGate(tester, api: api, settle: false);

    // 首帧加载未完成：占位可见，主页虽在树中但处于 Offstage
    expect(find.byKey(const ValueKey('privacyGateSplash')), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyGateSplash')), findsNothing);
    expect(find.text('应用主页'), findsOneWidget);
  });

  testWidgets('需要锁时不显示 child，错误密码重试后正确密码解锁', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('correct-pass');
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    expect(find.text('隐私空间'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
    // child 仍挂载（Offstage），仅不可见
    expect(find.text('应用主页', skipOffstage: false), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      'wrong',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockButton')));
    await tester.pumpAndSettle();
    expect(find.text('密码错误'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      'correct-pass',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockButton')));
    await tester.pumpAndSettle();
    expect(find.text('隐私空间'), findsNothing);
    expect(find.text('应用主页'), findsOneWidget);
  });

  testWidgets('回车提交解锁', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('enter-pass');
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      'enter-pass',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('应用主页'), findsOneWidget);
  });

  testWidgets('连续提交只发起一次校验', (tester) async {
    final api = _SlowVerifyApi();
    await api.privacySetPassword('pw');
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockButton')));
    await tester.tap(find.byKey(const ValueKey('privacyUnlockButton')));
    expect(api.verifyCalls, 1);

    api.pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('应用主页'), findsOneWidget);
  });

  testWidgets('策略 store 抛错 fail-closed，重试后进入锁页', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    final store = _FlakyPolicyStore();
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
      store: store,
    );

    expect(find.text('无法读取隐私设置'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
    expect(find.text('应用主页', skipOffstage: false), findsOneWidget);

    store.failRead = false;
    await tester.tap(find.byKey(const ValueKey('privacyPolicyRetryButton')));
    await tester.pumpAndSettle();
    expect(find.text('无法读取隐私设置'), findsNothing);
    expect(find.text('隐私空间'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
  });

  testWidgets('策略单键类型错误时不显示 child（fail-closed）', (tester) async {
    await pumpGate(
      tester,
      api: MockBookApi(),
      prefs: {PrefKeys.privateEnabled: 'yes'},
    );

    expect(find.text('无法读取隐私设置'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
    expect(find.text('应用主页', skipOffstage: false), findsOneWidget);
  });

  testWidgets('锁页消费系统返回键，不 pop 隐藏路由', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    final navKey = GlobalKey<NavigatorState>();
    await pumpGate(
      tester,
      api: api,
      navigatorKey: navKey,
      earlyBackGuard: true,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('隐藏路由')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('隐藏路由', skipOffstage: false), findsOneWidget);
    expect(navKey.currentState!.canPop(), isTrue);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue);
    expect(navKey.currentState!.canPop(), isTrue, reason: '返回键不得穿透闸门');
    expect(find.text('隐藏路由', skipOffstage: false), findsOneWidget);
    expect(find.text('隐私空间'), findsOneWidget);
  });

  testWidgets('隐藏子树不可聚焦，锁页显式聚焦密码框', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    final hiddenFocus = FocusNode();
    addTearDown(hiddenFocus.dispose);
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
      home: Scaffold(
        body: Center(
          child: TextField(
            key: const ValueKey('gateHiddenInput'),
            focusNode: hiddenFocus,
            autofocus: true,
          ),
        ),
      ),
    );

    expect(hiddenFocus.hasFocus, isFalse, reason: 'Offstage 内容不得抢焦点');
    final lockField = tester.widget<TextField>(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
    );
    expect(lockField.focusNode?.hasFocus, isTrue, reason: '锁页密码框应显式聚焦');
  });

  testWidgets('软键盘 viewInsets 抬升闸门内容', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.resetViewInsets);
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    expect(find.text('隐私空间'), findsOneWidget);
    final padding =
        tester
                .widget<AnimatedPadding>(
                  find.byKey(const ValueKey('privacyGateKeyboardPadding')),
                )
                .padding
            as EdgeInsets;
    expect(padding.bottom, 300, reason: '900 物理像素 / dpr 3');
    expect(find.byKey(const ValueKey('privacyUnlockButton')), findsOneWidget);
  });

  testWidgets('credentialError fail-closed：不显示 child，重试后进入锁页', (tester) async {
    final api = _FlakyCredentialApi();
    await api.privacySetPassword('pw');
    final container = await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    expect(find.text('无法读取隐私凭据'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
    expect(find.text('隐私空间'), findsNothing);
    expect(container.read(privacyNotifierProvider).credentialError, isNotNull);

    api.failHasPassword = false;
    await tester.tap(
      find.byKey(const ValueKey('privacyCredentialRetryButton')),
    );
    await tester.pumpAndSettle();

    expect(find.text('无法读取隐私凭据'), findsNothing);
    expect(find.text('隐私空间'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
  });

  testWidgets('退出应用调用 SystemNavigator.pop', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );
    await tester.tap(find.byKey(const ValueKey('privacyExitAppButton')));
    await tester.pump();
    expect(calls, contains('SystemNavigator.pop'));
  });

  testWidgets('未启用时凭据读取失败仍 fail-closed，不放行', (tester) async {
    final api = _FlakyCredentialApi();
    await pumpGate(tester, api: api);

    expect(find.text('无法读取隐私凭据'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
  });

  testWidgets('360dp + 1.6 倍字体：锁页无溢出', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
      textScale: 1.6,
    );

    expect(find.text('隐私空间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UntilBackground 宽限 0：后台返回后重新上锁', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    await pumpGate(
      tester,
      api: api,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 0,
      },
    );
    expect(find.text('隐私空间'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockButton')));
    await tester.pumpAndSettle();
    expect(find.text('应用主页'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('隐私空间'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
  });

  // ===== [批9d] 启动闸门生物快捷解锁 =====

  testWidgets('生物按钮：已配置且可用时出现，认证成功解锁', (tester) async {
    final api = MockBookApi();
    final fake = _FakeBiometricService();
    await _seedBiometric(api);
    await pumpGate(
      tester,
      api: api,
      biometricService: fake,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    expect(find.text('隐私空间'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('privacyLockBiometricButton')),
      findsOneWidget,
    );
    // 密码入口仍保留（回退路径）
    expect(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('privacyLockBiometricButton')));
    await tester.pumpAndSettle();

    expect(find.text('应用主页'), findsOneWidget);
    expect(find.text('隐私空间'), findsNothing);
  });

  testWidgets('生物取消：留在锁页并提示，仍可回退密码解锁', (tester) async {
    final api = MockBookApi();
    final fake = _FakeBiometricService()
      ..unlockError = PrivacyBiometricErrorCode.cancelled;
    await _seedBiometric(api);
    await pumpGate(
      tester,
      api: api,
      biometricService: fake,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    await tester.tap(find.byKey(const ValueKey('privacyLockBiometricButton')));
    await tester.pumpAndSettle();

    expect(find.text('隐私空间'), findsOneWidget);
    expect(find.text('应用主页'), findsNothing);
    expect(find.text('已取消生物识别'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockPasswordField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockButton')));
    await tester.pumpAndSettle();
    expect(find.text('应用主页'), findsOneWidget);
  });

  testWidgets('生物令牌不匹配：保持锁定，回退密码可用', (tester) async {
    final api = MockBookApi();
    final fake = _FakeBiometricService()
      ..unlockTokenOverride = base64Encode(List<int>.filled(32, 8));
    await _seedBiometric(api);
    await pumpGate(
      tester,
      api: api,
      biometricService: fake,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    await tester.tap(find.byKey(const ValueKey('privacyLockBiometricButton')));
    await tester.pumpAndSettle();

    expect(find.text('隐私空间'), findsOneWidget);
    expect(find.text('生物识别失败，请重试或改用密码'), findsOneWidget);
  });

  testWidgets('认证请求悬挂时回到前台复位 busy，可重试', (tester) async {
    final api = MockBookApi();
    final fake = _FakeBiometricService()..unlockCompleter = Completer<String>();
    await _seedBiometric(api);
    await pumpGate(
      tester,
      api: api,
      biometricService: fake,
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );

    await tester.tap(find.byKey(const ValueKey('privacyLockBiometricButton')));
    await tester.pump();
    OutlinedButton button() => tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('privacyLockBiometricButton')),
    );
    expect(button().onPressed, isNull, reason: '认证中禁止重复提交');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(button().onPressed, isNotNull, reason: '回前台应复位 busy');
  });

  testWidgets('未配置生物识别时不显示生物按钮', (tester) async {
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    await pumpGate(
      tester,
      api: api,
      biometricService: _FakeBiometricService(),
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
    );
    expect(
      find.byKey(const ValueKey('privacyLockBiometricButton')),
      findsNothing,
    );
  });
}
