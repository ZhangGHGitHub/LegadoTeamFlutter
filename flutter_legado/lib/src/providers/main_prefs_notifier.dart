// [UI-fix v2.0.5 | 2026-08-08] 主界面偏好状态管理：对齐原版 pref_config_other.xml
// 主界面分组（showDiscovery/showRss/defaultHomePage），驱动首页底栏 Tab
// 显隐与默认首页即时生效（对标原版 MainActivity 读取 AppConfig） — Qoder
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../services/settings_service.dart';

/// 主界面偏好状态
class MainPrefsState {
  /// 显示发现（对齐原版 showDiscovery，默认 true）
  final bool showDiscovery;

  /// 显示订阅/RSS（对齐原版 showRss，默认 true）
  final bool showRss;

  /// 默认首页（对齐原版 defaultHomePage：bookshelf/explore/rss/my）
  final String defaultHomePage;

  const MainPrefsState({
    this.showDiscovery = true,
    this.showRss = true,
    this.defaultHomePage = 'bookshelf',
  });

  MainPrefsState copyWith({
    bool? showDiscovery,
    bool? showRss,
    String? defaultHomePage,
  }) {
    return MainPrefsState(
      showDiscovery: showDiscovery ?? this.showDiscovery,
      showRss: showRss ?? this.showRss,
      defaultHomePage: defaultHomePage ?? this.defaultHomePage,
    );
  }
}

/// 主界面偏好 Notifier（读写 SharedPreferences 并驱动首页重建）
class MainPrefsNotifier extends Notifier<MainPrefsState> {
  final SettingsService _settings = SettingsService();

  @override
  MainPrefsState build() {
    _load();
    return const MainPrefsState();
  }

  /// 启动时异步加载持久化偏好
  Future<void> _load() async {
    state = MainPrefsState(
      showDiscovery: await _settings.getBoolPref(
        PrefKeys.showDiscovery,
        defaultValue: true,
      ),
      showRss: await _settings.getBoolPref(
        PrefKeys.showRss,
        defaultValue: true,
      ),
      defaultHomePage: await _settings.getStringPref(
        PrefKeys.defaultHomePage,
        defaultValue: 'bookshelf',
      ),
    );
  }

  /// 设置显示发现
  Future<void> setShowDiscovery(bool value) async {
    state = state.copyWith(showDiscovery: value);
    await _settings.setBoolPref(PrefKeys.showDiscovery, value);
  }

  /// 设置显示订阅
  Future<void> setShowRss(bool value) async {
    state = state.copyWith(showRss: value);
    await _settings.setBoolPref(PrefKeys.showRss, value);
  }

  /// 设置默认首页（bookshelf/explore/rss/my）
  Future<void> setDefaultHomePage(String value) async {
    state = state.copyWith(defaultHomePage: value);
    await _settings.setStringPref(PrefKeys.defaultHomePage, value);
  }
}

/// 主界面偏好全局 Provider
final mainPrefsProvider = NotifierProvider<MainPrefsNotifier, MainPrefsState>(
  MainPrefsNotifier.new,
);
