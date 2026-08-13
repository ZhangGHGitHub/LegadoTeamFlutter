// 沉浸式状态栏 / 导航栏偏好状态（对齐原版 transparentStatusBar / immNavigationBar）
//
// — Composer + UI ｜ 2026-08-14
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../constants/pref_keys.dart';
import '../../services/settings_service.dart';

/// 系统栏偏好状态
class SystemBarState {
  final bool transparentStatusBar;
  final bool immNavigationBar;
  final bool loaded;

  const SystemBarState({
    this.transparentStatusBar = true,
    this.immNavigationBar = true,
    this.loaded = false,
  });

  SystemBarState copyWith({
    bool? transparentStatusBar,
    bool? immNavigationBar,
    bool? loaded,
  }) {
    return SystemBarState(
      transparentStatusBar: transparentStatusBar ?? this.transparentStatusBar,
      immNavigationBar: immNavigationBar ?? this.immNavigationBar,
      loaded: loaded ?? this.loaded,
    );
  }
}

class SystemBarNotifier extends Notifier<SystemBarState> {
  final _settings = SettingsService();

  @override
  SystemBarState build() {
    _loadFromPrefs();
    return const SystemBarState();
  }

  Future<void> _loadFromPrefs() async {
    final transparentStatusBar = await _settings.getBoolPref(
      PrefKeys.transparentStatusBar,
      defaultValue: true,
    );
    final immNavigationBar = await _settings.getBoolPref(
      PrefKeys.immNavigationBar,
      defaultValue: true,
    );
    state = SystemBarState(
      transparentStatusBar: transparentStatusBar,
      immNavigationBar: immNavigationBar,
      loaded: true,
    );
  }

  Future<void> setTransparentStatusBar(bool value) async {
    await _settings.setBoolPref(PrefKeys.transparentStatusBar, value);
    state = state.copyWith(transparentStatusBar: value);
  }

  Future<void> setImmNavigationBar(bool value) async {
    await _settings.setBoolPref(PrefKeys.immNavigationBar, value);
    state = state.copyWith(immNavigationBar: value);
  }

  Future<void> reload() => _loadFromPrefs();
}

final systemBarProvider =
    NotifierProvider<SystemBarNotifier, SystemBarState>(
  SystemBarNotifier.new,
);
