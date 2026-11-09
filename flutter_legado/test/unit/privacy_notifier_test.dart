/// 隐私/应用锁 Notifier 测试（设置批9b；审查回修）
///
/// 覆盖：默认策略与持久化、启用需密码、解锁成功/失败、只验不授权、
/// 改密验旧、清密需验证与错误分类、AppSession 后台不失效、
/// UntilBackground 宽限 0/30s（paused/hidden）、策略/凭据读取失败
/// fail-closed 与重试、策略写入失败回滚、备份口径。
library;

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

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

/// 策略写入恒失败（setter bool / UI SnackBar 测试）
class _FailingWriteStore extends PrivacyPolicyStore {
  const _FailingWriteStore();

  @override
  Future<bool> writeBool(String key, bool value) async => false;

  @override
  Future<bool> writeString(String key, String value) async => false;

  @override
  Future<bool> writeInt(String key, int value) async => false;
}

/// 删除凭据抛错（清密失败分类测试）
class _FailingClearApi extends MockBookApi {
  @override
  Future<void> privacyClearPassword() async {
    throw const BridgeError(message: '删除凭据失败');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBookApi api;
  late ProviderContainer container;

  setUp(() {
    api = MockBookApi();
  });

  Future<PrivacyNotifier> boot({
    Map<String, Object> prefs = const {},
    MockBookApi? overrideApi,
    PrivacyPolicyStore? store,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final overrides = <Override>[
      bookApiProvider.overrideWithValue(overrideApi ?? api),
    ];
    if (store != null) {
      overrides.add(privacyPolicyStoreProvider.overrideWithValue(store));
    }
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    final notifier = container.read(privacyNotifierProvider.notifier);
    await notifier.ensureLoaded();
    return notifier;
  }

  PrivacyState state() => container.read(privacyNotifierProvider);

  test('默认策略：启用关、验证时机 开/开/关、AppSession、宽限 0', () async {
    await boot();
    final s = state();
    expect(s.loaded, isTrue);
    expect(s.enabled, isFalse);
    expect(s.hasPassword, isFalse);
    expect(s.policyError, isNull);
    expect(s.credentialError, isNull);
    expect(s.verifyOnEnterGroup, isTrue);
    expect(s.verifyOnOpenBook, isTrue);
    expect(s.verifyOnAppStart, isFalse);
    expect(s.unlockScope, PrivacyUnlockScope.appSession);
    expect(s.backgroundGraceSeconds, 0);
    expect(s.sessionUnlocked, isFalse);
    expect(s.appStartVerified, isFalse);
  });

  test('策略持久化：读取已存值并写回偏好', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnEnterGroup: false,
        PrefKeys.privateVerifyOnOpenBook: false,
        PrefKeys.privateVerifyOnAppStart: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 120,
      },
    );
    var s = state();
    expect(s.enabled, isTrue);
    expect(s.hasPassword, isTrue);
    expect(s.verifyOnEnterGroup, isFalse);
    expect(s.verifyOnOpenBook, isFalse);
    expect(s.verifyOnAppStart, isTrue);
    expect(s.unlockScope, PrivacyUnlockScope.untilBackground);
    expect(s.backgroundGraceSeconds, 120);

    await notifier.setVerifyOnEnterGroup(true);
    await notifier.setVerifyOnOpenBook(true);
    await notifier.setVerifyOnAppStart(false);
    await notifier.setUnlockScope(PrivacyUnlockScope.everyTime);
    await notifier.setBackgroundGraceSeconds(300);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateVerifyOnEnterGroup), isTrue);
    expect(prefs.getBool(PrefKeys.privateVerifyOnOpenBook), isTrue);
    expect(prefs.getBool(PrefKeys.privateVerifyOnAppStart), isFalse);
    expect(prefs.getString(PrefKeys.privateUnlockScope), 'every_time');
    expect(prefs.getInt(PrefKeys.privateBackgroundGraceSeconds), 300);
    s = state();
    expect(s.unlockScope, PrivacyUnlockScope.everyTime);
    expect(s.backgroundGraceSeconds, 300);
  });

  test('非法宽限值回落 0，未知频率回落 AppSession', () async {
    await boot(
      prefs: {
        PrefKeys.privateUnlockScope: 'nonsense',
        PrefKeys.privateBackgroundGraceSeconds: 42,
      },
    );
    expect(state().unlockScope, PrivacyUnlockScope.appSession);
    expect(state().backgroundGraceSeconds, 0);
  });

  test('启用需密码：无凭据开启失败，设密后可开启', () async {
    final notifier = await boot();
    expect(await notifier.setEnabled(true), isFalse);
    expect(state().enabled, isFalse);
    expect(
      await notifier.setPassword('new-pass'),
      PrivacyPasswordChangeResult.success,
    );
    expect(state().hasPassword, isTrue);
    expect(await notifier.setEnabled(true), isTrue);
    expect(state().enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateEnabled), isTrue);
    // 关闭只改开关，不改凭据与策略
    await notifier.setEnabled(false);
    expect(state().enabled, isFalse);
    expect(state().hasPassword, isTrue);
    expect(await api.privacyVerifyPassword('new-pass'), isTrue);
  });

  test('解锁成功置会话与启动标记；失败不改状态', () async {
    final notifier = await boot();
    await notifier.setPassword('pw');
    expect(await notifier.unlock('wrong'), isFalse);
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
    expect(await notifier.unlock('pw'), isTrue);
    expect(state().sessionUnlocked, isTrue);
    expect(state().appStartVerified, isTrue);
    notifier.lock();
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
  });

  test('改密必须验旧：缺失/错误旧密拒绝，正确旧密生效并重新上锁', () async {
    final notifier = await boot();
    await notifier.setPassword('first-pass');
    await notifier.unlock('first-pass');
    expect(state().sessionUnlocked, isTrue);

    expect(
      await notifier.setPassword('second-pass'),
      PrivacyPasswordChangeResult.oldPasswordWrong,
    );
    expect(
      await notifier.setPassword('second-pass', oldPassword: 'bad'),
      PrivacyPasswordChangeResult.oldPasswordWrong,
    );
    expect(await api.privacyVerifyPassword('first-pass'), isTrue);

    expect(
      await notifier.setPassword('second-pass', oldPassword: 'first-pass'),
      PrivacyPasswordChangeResult.success,
    );
    expect(state().hasPassword, isTrue);
    expect(state().sessionUnlocked, isFalse, reason: '改密后需重新解锁');
    expect(state().appStartVerified, isFalse);
    expect(await api.privacyVerifyPassword('first-pass'), isFalse);
    expect(await api.privacyVerifyPassword('second-pass'), isTrue);
  });

  test('新密码非法：空串/全空白/超 128 字符拒绝', () async {
    final notifier = await boot();
    expect(
      await notifier.setPassword(''),
      PrivacyPasswordChangeResult.invalidPassword,
    );
    expect(
      await notifier.setPassword('   '),
      PrivacyPasswordChangeResult.invalidPassword,
    );
    expect(
      await notifier.setPassword('a' * 129),
      PrivacyPasswordChangeResult.invalidPassword,
    );
    expect(state().hasPassword, isFalse);
  });

  test('清密需验证：错误密码不清除，正确后 hasPassword=false、enabled 保持', () async {
    final notifier = await boot();
    await notifier.setPassword('pw');
    await notifier.setEnabled(true);
    await notifier.unlock('pw');
    expect(
      await notifier.clearPassword(password: 'bad'),
      PrivacyClearPasswordResult.passwordWrong,
    );
    expect(
      await notifier.clearPassword(password: ''),
      PrivacyClearPasswordResult.passwordWrong,
    );
    expect(state().hasPassword, isTrue);
    expect(await api.privacyHasPassword(), isTrue);

    expect(
      await notifier.clearPassword(password: 'pw'),
      PrivacyClearPasswordResult.success,
    );
    expect(state().hasPassword, isFalse);
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
    expect(state().enabled, isTrue, reason: 'Notifier 保持 enabled，由设置页提示关闭');
    expect(await api.privacyHasPassword(), isFalse);
  });

  test('只验不授权：verifyPasswordOnly 成功不置会话/启动标记', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot();
    expect(await notifier.verifyPasswordOnly('bad'), isFalse);
    expect(await notifier.verifyPasswordOnly('pw'), isTrue);
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
  });

  test('清密失败分类：API 删除异常归为 failure 且凭据保持不变', () async {
    final failing = _FailingClearApi();
    await failing.privacySetPassword('pw');
    final notifier = await boot(overrideApi: failing);
    expect(
      await notifier.clearPassword(password: 'pw'),
      PrivacyClearPasswordResult.failure,
    );
    expect(state().hasPassword, isTrue);
    expect(await failing.privacyVerifyPassword('pw'), isTrue);
  });

  test('AppSession：后台任意时长不失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'app_session',
      },
    );
    await notifier.unlock('pw');
    final base = DateTime(2026, 11, 9, 10);
    notifier.handleLifecycleState(AppLifecycleState.paused, now: base);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: base.add(const Duration(days: 1)),
    );
    expect(state().sessionUnlocked, isTrue);
  });

  test('UntilBackground 宽限 0：回到前台立即失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 0,
      },
    );
    await notifier.unlock('pw');
    final base = DateTime(2026, 11, 9, 10);
    notifier.handleLifecycleState(AppLifecycleState.paused, now: base);
    notifier.handleLifecycleState(AppLifecycleState.resumed, now: base);
    expect(state().sessionUnlocked, isFalse);
  });

  test('UntilBackground 宽限 30s：未超时保持，超时失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 30,
      },
    );
    final base = DateTime(2026, 11, 9, 10);
    await notifier.unlock('pw');
    notifier.handleLifecycleState(AppLifecycleState.paused, now: base);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: base.add(const Duration(seconds: 29)),
    );
    expect(state().sessionUnlocked, isTrue);

    final second = base.add(const Duration(minutes: 1));
    notifier.handleLifecycleState(AppLifecycleState.paused, now: second);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: second.add(const Duration(seconds: 31)),
    );
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
  });

  test('凭据读取失败 fail-closed：记错误且不当作无密码，重试成功后恢复', () async {
    final flaky = _FlakyCredentialApi();
    await flaky.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
      overrideApi: flaky,
    );
    expect(state().loaded, isTrue);
    expect(state().credentialError, '无法读取隐私凭据');
    expect(state().hasPassword, isFalse, reason: '失败时不把凭据状态写成 false');
    expect(state().enabled, isTrue, reason: '失败时不擅自关闭已启用开关');

    flaky.failHasPassword = false;
    await notifier.retryCredentialCheck();
    expect(state().credentialError, isNull);
    expect(state().hasPassword, isTrue);
    expect(state().needsAppStartLock, isTrue);
  });

  test('成功读到无密码但 enabled=true：回落关闭，避免无凭据锁死', () async {
    await boot(prefs: {PrefKeys.privateEnabled: true});
    expect(state().hasPassword, isFalse);
    expect(state().enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateEnabled), isFalse);
  });

  test('UntilBackground hidden→resumed 同样按宽限失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 30,
      },
    );
    await notifier.unlock('pw');
    final base = DateTime(2026, 11, 9, 10);
    notifier.handleLifecycleState(AppLifecycleState.hidden, now: base);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: base.add(const Duration(seconds: 31)),
    );
    expect(state().sessionUnlocked, isFalse);
  });

  test('策略单键类型错误：policyError 非空，不按默认策略继续', () async {
    await boot(prefs: {PrefKeys.privateVerifyOnEnterGroup: 'not-bool'});
    expect(state().loaded, isTrue);
    expect(state().policyError, '无法读取隐私设置');
    expect(state().credentialError, isNull);
  });

  test('策略 store 抛错：policyError 非空，重试成功后恢复策略', () async {
    await api.privacySetPassword('pw');
    final store = _FlakyPolicyStore();
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 120,
      },
      store: store,
    );
    expect(state().policyError, '无法读取隐私设置');
    expect(state().credentialError, isNull);

    store.failRead = false;
    await notifier.retryCredentialCheck();
    expect(state().policyError, isNull);
    expect(state().enabled, isTrue);
    expect(state().verifyOnAppStart, isTrue);
    expect(state().unlockScope, PrivacyUnlockScope.untilBackground);
    expect(state().backgroundGraceSeconds, 120);
  });

  test('策略写入失败：setter 返回 false 并回滚内存状态', () async {
    final notifier = await boot(store: const _FailingWriteStore());
    expect(await notifier.setVerifyOnEnterGroup(false), isFalse);
    expect(state().verifyOnEnterGroup, isTrue);
    expect(
      await notifier.setUnlockScope(PrivacyUnlockScope.untilBackground),
      isFalse,
    );
    expect(state().unlockScope, PrivacyUnlockScope.appSession);
    expect(await notifier.setBackgroundGraceSeconds(30), isFalse);
    expect(state().backgroundGraceSeconds, 0);

    await notifier.setPassword('pw');
    expect(await notifier.setEnabled(true), isFalse);
    expect(state().enabled, isFalse);
  });

  test('备份口径：仅 private_enabled 排除，其余策略随 appPrefs 往返', () async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnEnterGroup: false,
      PrefKeys.privateVerifyOnOpenBook: false,
      PrefKeys.privateVerifyOnAppStart: true,
      PrefKeys.privateUnlockScope: 'until_background',
      PrefKeys.privateBackgroundGraceSeconds: 120,
    });
    final collected = await RestoreIgnorePrefs.collectForBackup(const {});
    expect(collected.containsKey(PrefKeys.privateEnabled), isFalse);
    expect(collected[PrefKeys.privateVerifyOnEnterGroup], isFalse);
    expect(collected[PrefKeys.privateVerifyOnOpenBook], isFalse);
    expect(collected[PrefKeys.privateVerifyOnAppStart], isTrue);
    expect(collected[PrefKeys.privateUnlockScope], 'until_background');
    expect(collected[PrefKeys.privateBackgroundGraceSeconds], 120);

    expect(
      RestoreIgnorePrefs.alwaysIgnoreKeys,
      contains(PrefKeys.privateEnabled),
    );
    expect(
      RestoreIgnorePrefs.alwaysIgnoreKeys,
      isNot(contains(PrefKeys.privateVerifyOnEnterGroup)),
    );

    SharedPreferences.setMockInitialValues({});
    await RestoreIgnorePrefs.applyFromBackup(collected, const {});
    final restored = await SharedPreferences.getInstance();
    expect(restored.containsKey(PrefKeys.privateEnabled), isFalse);
    expect(restored.getBool(PrefKeys.privateVerifyOnEnterGroup), isFalse);
    expect(restored.getBool(PrefKeys.privateVerifyOnOpenBook), isFalse);
    expect(restored.getBool(PrefKeys.privateVerifyOnAppStart), isTrue);
    expect(restored.getString(PrefKeys.privateUnlockScope), 'until_background');
    expect(restored.getInt(PrefKeys.privateBackgroundGraceSeconds), 120);
  });
}
