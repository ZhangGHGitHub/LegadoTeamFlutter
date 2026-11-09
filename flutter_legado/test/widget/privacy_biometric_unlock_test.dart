/// 统一解锁弹窗与锁定页生物入口测试（契约 §2.53 批9d）
///
/// 覆盖：弹窗「使用生物识别」成功授权并关闭、取消/失败留在弹窗且可回退
/// 密码、PrivateLockedPage 次入口渲染与回调。
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
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/privacy_biometric_service.dart';
import 'package:flutter_legado/src/widgets/privacy/private_locked_page.dart';
import 'package:flutter_legado/src/widgets/privacy/privacy_unlock_dialog.dart';

class _FakeBiometricService implements PrivacyBiometricService {
  static final String token = base64Encode(List<int>.filled(32, 7));
  static final String envelope = base64Encode(List<int>.filled(64, 9));
  static final String iv = base64Encode(List<int>.filled(12, 5));

  PrivacyBiometricStatus status = const PrivacyBiometricStatus(available: true);
  PrivacyBiometricErrorCode? unlockError;
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
    return token;
  }

  @override
  Future<void> deleteKey() async {}
}

class _DialogHost extends ConsumerWidget {
  const _DialogHost({required this.result});

  final ValueNotifier<bool?> result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const ValueKey('openUnlockDialog'),
          onPressed: () async {
            result.value = await showPrivacyUnlockDialog(
              context,
              ref,
              bookUrl: 'https://a/private',
              title: '验证后查看',
            );
          },
          child: const Text('打开'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final token = _FakeBiometricService.token;
  final envelope = _FakeBiometricService.envelope;
  final iv = _FakeBiometricService.iv;

  Future<(ProviderContainer, ValueNotifier<bool?>)> pumpDialog(
    WidgetTester tester, {
    required _FakeBiometricService fake,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateUnlockScope: 'app_session',
    });
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    await api.privacyBiometricSet(token, envelope, iv);
    final container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        privacyBiometricServiceProvider.overrideWithValue(fake),
      ],
    );
    addTearDown(container.dispose);
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();
    final result = ValueNotifier<bool?>(null);
    addTearDown(result.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: _DialogHost(result: result)),
      ),
    );
    await tester.pumpAndSettle();
    return (container, result);
  }

  testWidgets('弹窗生物解锁成功：关闭并返回 true', (tester) async {
    final (container, result) = await pumpDialog(
      tester,
      fake: _FakeBiometricService(),
    );

    await tester.tap(find.byKey(const ValueKey('openUnlockDialog')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('privacyUnlockBiometric')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('privacyUnlockBiometric')));
    await tester.pumpAndSettle();

    expect(result.value, isTrue);
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsNothing);
    expect(container.read(privacyNotifierProvider).sessionUnlocked, isTrue);
  });

  testWidgets('弹窗生物取消：留在弹窗并回退密码验证', (tester) async {
    final fake = _FakeBiometricService()
      ..unlockError = PrivacyBiometricErrorCode.cancelled;
    final (_, result) = await pumpDialog(tester, fake: fake);

    await tester.tap(find.byKey(const ValueKey('openUnlockDialog')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacyUnlockBiometric')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);
    expect(find.text('已取消生物识别'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();
    expect(result.value, isTrue);
  });

  testWidgets('弹窗认证悬挂时回到前台复位 busy，可重试', (tester) async {
    final fake = _FakeBiometricService()..unlockCompleter = Completer<String>();
    await pumpDialog(tester, fake: fake);

    await tester.tap(find.byKey(const ValueKey('openUnlockDialog')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacyUnlockBiometric')));
    await tester.pump();
    OutlinedButton button() => tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('privacyUnlockBiometric')),
    );
    expect(button().onPressed, isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(button().onPressed, isNotNull, reason: '回前台应复位 busy');
  });

  testWidgets('弹窗未配置生物识别时不显示生物按钮', (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.privateEnabled: true});
    final api = MockBookApi();
    await api.privacySetPassword('pw');
    final container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        privacyBiometricServiceProvider.overrideWithValue(
          _FakeBiometricService(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: _DialogHost(result: ValueNotifier(null))),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('openUnlockDialog')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyUnlockBiometric')), findsNothing);
  });

  testWidgets('PrivateLockedPage：生物次入口渲染并回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrivateLockedPage(
            title: '私密分组',
            description: '验证后查看分组内容',
            actionText: '验证并查看',
            onAction: () {},
            onBiometric: () => tapped++,
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('private-locked-biometric')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('private-locked-biometric')));
    expect(tapped, 1);
  });

  testWidgets('PrivateLockedPage：未提供回调时不渲染生物入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrivateLockedPage(
            title: '私密书籍',
            description: '验证后查看书籍详情',
            actionText: '验证并查看',
            onAction: () {},
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('private-locked-biometric')),
      findsNothing,
    );
  });
}
