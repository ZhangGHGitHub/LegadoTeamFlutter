// 隐私/应用锁 Notifier（设置批9b）
//
// 职责：
// - 加载/持久化隐私策略（键名逐字对齐参考版 PreferKey）并读取
//   Rust `privacyHasPassword`（凭据 salt/verifier 由 Rust 保管）；
// - 提供解锁（`unlock`）与会话锁定（`lock`），供启动闸门与 9c 阅读闸门复用；
// - 生命周期钩子：untilBackground 模式在离开后台超过宽限后自动 `lock`；
// - 设置/改密/清密：改密必须验旧密码；清密先验证再删除凭据。
//
// **fail-closed**：`privacyHasPassword` 读取失败时记录 [PrivacyState.credentialError]
// 并保持 `hasPassword=false` 但不视为「无密码放行」——启动闸门遇到凭据错误
// 只展示重试页，绝不显示应用内容。成功读到「无密码」时才回落关闭 enabled。
//
// 编写：全栈工程师（设置批9b） ｜ 2026-11-09
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/pref_keys.dart';
import '../providers.dart';
import 'privacy_state.dart';

/// 隐私设置 Provider
final privacyNotifierProvider = NotifierProvider<PrivacyNotifier, PrivacyState>(
  PrivacyNotifier.new,
);

/// 隐私/应用锁 Notifier
class PrivacyNotifier extends Notifier<PrivacyState> {
  Future<void>? _loading;
  bool _disposed = false;

  /// 进入后台的时间（paused/hidden 首次触发时记录；resumed 判定后清空）
  DateTime? _backgroundedAt;

  @override
  PrivacyState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    _loading ??= _load();
    return const PrivacyState();
  }

  /// 等待首次加载完成（测试与启动闸门重试可显式调用）
  Future<void> ensureLoaded() => _loading ??= _load();

  void _set(PrivacyState next) {
    if (_disposed) return;
    state = next;
  }

  Future<void> _load() async {
    var next = const PrivacyState();
    String? credentialError;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawGrace =
          prefs.getInt(PrefKeys.privateBackgroundGraceSeconds) ?? 0;
      next = PrivacyState(
        enabled: prefs.getBool(PrefKeys.privateEnabled) ?? false,
        verifyOnEnterGroup:
            prefs.getBool(PrefKeys.privateVerifyOnEnterGroup) ?? true,
        verifyOnOpenBook:
            prefs.getBool(PrefKeys.privateVerifyOnOpenBook) ?? true,
        verifyOnAppStart:
            prefs.getBool(PrefKeys.privateVerifyOnAppStart) ?? false,
        unlockScope: PrivacyUnlockScope.fromStorage(
          prefs.getString(PrefKeys.privateUnlockScope),
        ),
        backgroundGraceSeconds:
            kPrivacyBackgroundGraceOptions.contains(rawGrace) ? rawGrace : 0,
      );
    } catch (e) {
      // 偏好读取失败：按默认策略继续；凭据读取仍可能成功
      debugPrint('[隐私] 读取隐私策略失败（按默认值继续）：$e');
    }

    if (_disposed) return;
    try {
      final hasPassword = await ref.read(bookApiProvider).privacyHasPassword();
      next = next.copyWith(hasPassword: hasPassword);
      // 成功读取到「无密码」时关闭 enabled，避免无凭据锁死；读取失败
      // 不走此分支（凭据状态未知，由启动闸门 fail-closed）。
      if (next.enabled && !hasPassword) {
        next = next.copyWith(enabled: false);
        await _writeBool(PrefKeys.privateEnabled, false);
      }
    } catch (e) {
      debugPrint('[隐私] 读取隐私凭据失败（fail-closed）：$e');
      credentialError = '无法读取隐私凭据';
    }

    _set(next.copyWith(credentialError: credentialError, loaded: true));
  }

  /// 重新检查凭据（启动闸门凭据错误页的「重试」）
  ///
  /// 成功后清除 [PrivacyState.credentialError]；若成功读到「无密码」且
  /// enabled 仍为 true，则回落关闭 enabled。
  Future<void> retryCredentialCheck() async {
    try {
      final hasPassword = await ref.read(bookApiProvider).privacyHasPassword();
      var next = state.copyWith(
        hasPassword: hasPassword,
        credentialError: null,
        loaded: true,
      );
      if (next.enabled && !hasPassword) {
        next = next.copyWith(enabled: false);
        await _writeBool(PrefKeys.privateEnabled, false);
      }
      _set(next);
    } catch (e) {
      debugPrint('[隐私] 重试读取凭据仍失败：$e');
      _set(state.copyWith(credentialError: '无法读取隐私凭据', loaded: true));
    }
  }

  // ===== 解锁 / 锁定 =====

  /// 校验密码并解锁本次会话
  ///
  /// 成功：`sessionUnlocked = appStartVerified = true`；失败/异常：返回 false，
  /// 不改变既有解锁状态（防爆破不额外泄露信息）。
  Future<bool> unlock(String password) async {
    if (password.isEmpty) return false;
    bool ok;
    try {
      ok = await ref.read(bookApiProvider).privacyVerifyPassword(password);
    } catch (e) {
      debugPrint('[隐私] 校验密码异常（保持锁定）：$e');
      return false;
    }
    if (!ok) return false;
    _set(state.copyWith(sessionUnlocked: true, appStartVerified: true));
    return true;
  }

  /// 清除本次会话解锁状态（启动闸门后台失效、9c 离开阅读器时复用）
  void lock() {
    if (!state.sessionUnlocked && !state.appStartVerified) return;
    _set(state.copyWith(sessionUnlocked: false, appStartVerified: false));
  }

  /// 生命周期钩子（由启动闸门转发）
  ///
  /// - paused/hidden：记录进入后台时间（多次事件保留最早时间）；
  /// - resumed：仅 untilBackground 模式且已解锁时判定；宽限 0 立即锁定，
  ///   否则离台时长达到宽限后锁定；AppSession 模式后台不失效。
  ///
  /// [now] 仅测试注入虚拟时间；生产不传。
  void handleLifecycleState(AppLifecycleState lifecycleState, {DateTime? now}) {
    final at = now ?? DateTime.now();
    switch (lifecycleState) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= at;
      case AppLifecycleState.resumed:
        final backgroundedAt = _backgroundedAt;
        _backgroundedAt = null;
        if (backgroundedAt == null) return;
        if (state.unlockScope != PrivacyUnlockScope.untilBackground) return;
        if (!state.sessionUnlocked) return;
        final graceSeconds = state.backgroundGraceSeconds;
        final elapsed = at.difference(backgroundedAt);
        if (graceSeconds <= 0 || elapsed >= Duration(seconds: graceSeconds)) {
          lock();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // inactive（来电/通知中心短暂失焦）不触发宽限计时
        break;
    }
  }

  // ===== 策略写入 =====

  /// 启用/关闭私密功能
  ///
  /// 开启前必须已有隐私密码（否则返回 false，由 UI 引导先设置密码）；
  /// 关闭只改开关，不清凭据与验证策略。
  Future<bool> setEnabled(bool value) async {
    if (value && !state.hasPassword) return false;
    if (state.enabled != value) {
      _set(state.copyWith(enabled: value));
      await _writeBool(PrefKeys.privateEnabled, value);
    }
    return true;
  }

  Future<void> setVerifyOnEnterGroup(bool value) async {
    if (state.verifyOnEnterGroup == value) return;
    _set(state.copyWith(verifyOnEnterGroup: value));
    await _writeBool(PrefKeys.privateVerifyOnEnterGroup, value);
  }

  Future<void> setVerifyOnOpenBook(bool value) async {
    if (state.verifyOnOpenBook == value) return;
    _set(state.copyWith(verifyOnOpenBook: value));
    await _writeBool(PrefKeys.privateVerifyOnOpenBook, value);
  }

  Future<void> setVerifyOnAppStart(bool value) async {
    if (state.verifyOnAppStart == value) return;
    _set(state.copyWith(verifyOnAppStart: value));
    await _writeBool(PrefKeys.privateVerifyOnAppStart, value);
  }

  Future<void> setUnlockScope(PrivacyUnlockScope scope) async {
    if (state.unlockScope == scope) return;
    _set(state.copyWith(unlockScope: scope));
    await _writeString(PrefKeys.privateUnlockScope, scope.storageValue);
  }

  Future<void> setBackgroundGraceSeconds(int seconds) async {
    final normalized = kPrivacyBackgroundGraceOptions.contains(seconds)
        ? seconds
        : 0;
    if (state.backgroundGraceSeconds == normalized) return;
    _set(state.copyWith(backgroundGraceSeconds: normalized));
    await _writeInt(PrefKeys.privateBackgroundGraceSeconds, normalized);
  }

  // ===== 密码设置 / 修改 / 清除 =====

  /// 设置或修改隐私密码
  ///
  /// 已有凭据时 [oldPassword] 必须匹配（缺失/错误归为
  /// [PrivacyPasswordChangeResult.oldPasswordWrong]）；成功后置
  /// `hasPassword=true` 并 `lock()`（改密后需重新解锁）。
  Future<PrivacyPasswordChangeResult> setPassword(
    String newPassword, {
    String? oldPassword,
  }) async {
    final trimmed = newPassword.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 128) {
      return PrivacyPasswordChangeResult.invalidPassword;
    }
    final api = ref.read(bookApiProvider);
    final hadPassword = state.hasPassword;
    if (hadPassword) {
      final old = oldPassword ?? '';
      if (old.isEmpty) return PrivacyPasswordChangeResult.oldPasswordWrong;
      bool oldOk;
      try {
        oldOk = await api.privacyVerifyPassword(old);
      } catch (e) {
        debugPrint('[隐私] 校验旧密码异常：$e');
        return PrivacyPasswordChangeResult.failure;
      }
      if (!oldOk) return PrivacyPasswordChangeResult.oldPasswordWrong;
    }

    bool ok;
    try {
      ok = await api.privacySetPassword(
        newPassword,
        oldPassword: hadPassword ? oldPassword : null,
      );
    } catch (e) {
      debugPrint('[隐私] 设置密码异常：$e');
      return PrivacyPasswordChangeResult.failure;
    }
    if (!ok) return PrivacyPasswordChangeResult.failure;

    _set(
      state.copyWith(
        hasPassword: true,
        sessionUnlocked: false,
        appStartVerified: false,
      ),
    );
    return PrivacyPasswordChangeResult.success;
  }

  /// 清除隐私密码（先验证当前密码，再删除两键）
  ///
  /// 成功后 `hasPassword=false` 并清除会话解锁标记；**enabled 保持原值**，
  /// 由设置页提示并调用 [setEnabled] 关闭（避免无凭据锁死）。返回 false
  /// 表示密码错误或 API 异常（凭据未删除）。
  Future<bool> clearPassword({required String password}) async {
    if (password.isEmpty) return false;
    final api = ref.read(bookApiProvider);
    bool verified;
    try {
      verified = await api.privacyVerifyPassword(password);
    } catch (e) {
      debugPrint('[隐私] 清除密码前校验异常：$e');
      return false;
    }
    if (!verified) return false;
    try {
      await api.privacyClearPassword();
    } catch (e) {
      debugPrint('[隐私] 清除密码异常：$e');
      return false;
    }
    _set(
      state.copyWith(
        hasPassword: false,
        sessionUnlocked: false,
        appStartVerified: false,
      ),
    );
    return true;
  }

  // ===== 持久化辅助 =====

  Future<void> _writeBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      debugPrint('[隐私] 写入偏好 $key 失败：$e');
    }
  }

  Future<void> _writeString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      debugPrint('[隐私] 写入偏好 $key 失败：$e');
    }
  }

  Future<void> _writeInt(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (e) {
      debugPrint('[隐私] 写入偏好 $key 失败：$e');
    }
  }
}
