// [UI-fix v2.0.5 | 2026-08-08] 主界面偏好状态管理：对齐原版 pref_config_other.xml
// 主界面分组（showDiscovery/showRss/defaultHomePage），驱动首页底栏 Tab
// 显隐与默认首页即时生效（对标原版 MainActivity 读取 AppConfig） — Qoder
//
// [设置批2b-2a | 2026-11-02] 补齐参考版「首页与导航」：
// - 新增 showHome / mainNavigationOrder / 10 个导航自定义图标路径键；
// - 键名逐字对齐参考版 `PreferKey`（showHome/showDiscovery/showRss/
//   mainNavigationOrder/navIcon*）；默认值对齐 `AppShellSettings`；
// - 显隐约束对齐参考版 `MainNavigationSettingsSheet.isRouteVisible`：
//   仅首页/发现/订阅可隐藏，书架与我的恒显示（至少保留一项）；
// - 隐藏当前默认页时回落 bookshelf（参考版
//   ThemeConfigViewModel.fallbackHomePage）。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/main_tab.dart';
import '../services/settings_service.dart';

/// 主界面偏好状态
class MainPrefsState {
  /// 显示首页（参考版 showHome，默认 true）
  final bool showHome;

  /// 显示发现（对齐原版 showDiscovery，默认 true）
  final bool showDiscovery;

  /// 显示订阅/RSS（对齐原版 showRss，默认 true）
  final bool showRss;

  /// 默认首页（home/bookshelf/explore/rss/my，默认 bookshelf）
  final String defaultHomePage;

  /// 导航顺序原始字符串（参考版 mainNavigationOrder）
  final String navigationOrder;

  /// 自定义导航图标（未选中态）路径；无自定义时为空 Map
  final Map<MainTab, String> navIconPaths;

  /// 自定义导航图标（选中态）路径；无自定义时为空 Map
  final Map<MainTab, String> navIconSelectedPaths;

  /// 是否已完成持久化读取（避免默认值覆盖/提前应用默认首页）
  final bool loaded;

  const MainPrefsState({
    this.showHome = true,
    this.showDiscovery = true,
    this.showRss = true,
    this.defaultHomePage = 'bookshelf',
    this.navigationOrder = kDefaultMainNavigationOrder,
    this.navIconPaths = const {},
    this.navIconSelectedPaths = const {},
    this.loaded = false,
  });

  /// 全部页签（含隐藏项，按配置顺序）
  List<MainTab> get orderedTabs => orderedMainTabs(navigationOrder);

  /// 可见页签（按配置顺序；书架/我的恒显示，至少一项）
  List<MainTab> get visibleTabs => visibleMainTabs(
        order: navigationOrder,
        showHome: showHome,
        showDiscovery: showDiscovery,
        showRss: showRss,
      );

  /// 指定页签的自定义图标路径（空串 = 未设置）
  String navIconPath(MainTab tab, {bool selected = false}) =>
      (selected ? navIconSelectedPaths : navIconPaths)[tab] ?? '';

  MainPrefsState copyWith({
    bool? showHome,
    bool? showDiscovery,
    bool? showRss,
    String? defaultHomePage,
    String? navigationOrder,
    Map<MainTab, String>? navIconPaths,
    Map<MainTab, String>? navIconSelectedPaths,
    bool? loaded,
  }) {
    return MainPrefsState(
      showHome: showHome ?? this.showHome,
      showDiscovery: showDiscovery ?? this.showDiscovery,
      showRss: showRss ?? this.showRss,
      defaultHomePage: defaultHomePage ?? this.defaultHomePage,
      navigationOrder: navigationOrder ?? this.navigationOrder,
      navIconPaths: navIconPaths ?? this.navIconPaths,
      navIconSelectedPaths:
          navIconSelectedPaths ?? this.navIconSelectedPaths,
      loaded: loaded ?? this.loaded,
    );
  }
}

/// 主界面偏好 Notifier（读写 SharedPreferences 并驱动首页重建）
class MainPrefsNotifier extends Notifier<MainPrefsState> {
  final SettingsService _settings = SettingsService();

  /// 首次加载 Future（测试可 await；生产不依赖）
  Future<void>? _loadFuture;

  /// 首次持久化读取 Future（测试用）
  @visibleForTesting
  Future<void>? get loadFuture => _loadFuture;

  @override
  MainPrefsState build() {
    _loadFuture = _load();
    return const MainPrefsState();
  }

  /// 启动时异步加载持久化偏好
  Future<void> _load() async {
    final showHome = await _settings.getBoolPref(
      PrefKeys.showHome,
      defaultValue: true,
    );
    final showDiscovery = await _settings.getBoolPref(
      PrefKeys.showDiscovery,
      defaultValue: true,
    );
    final showRss = await _settings.getBoolPref(
      PrefKeys.showRss,
      defaultValue: true,
    );
    final defaultHomePage = await _settings.getStringPref(
      PrefKeys.defaultHomePage,
      defaultValue: 'bookshelf',
    );
    final order = await _settings.getStringPref(
      PrefKeys.mainNavigationOrder,
      defaultValue: kDefaultMainNavigationOrder,
    );
    final icons = <MainTab, String>{};
    final selectedIcons = <MainTab, String>{};
    for (final tab in MainTab.values) {
      final path = await _settings.getStringPref(_iconKey(tab));
      if (path.isNotEmpty) icons[tab] = path;
      final selectedPath =
          await _settings.getStringPref(_iconKey(tab, selected: true));
      if (selectedPath.isNotEmpty) selectedIcons[tab] = selectedPath;
    }
    state = MainPrefsState(
      showHome: showHome,
      showDiscovery: showDiscovery,
      showRss: showRss,
      defaultHomePage: defaultHomePage,
      navigationOrder: serializeMainTabs(orderedMainTabs(order)),
      navIconPaths: Map.unmodifiable(icons),
      navIconSelectedPaths: Map.unmodifiable(selectedIcons),
      loaded: true,
    );
  }

  /// 设置显示首页
  Future<void> setShowHome(bool value) =>
      _setTabVisible(MainTab.home, value);

  /// 设置显示发现
  Future<void> setShowDiscovery(bool value) =>
      _setTabVisible(MainTab.explore, value);

  /// 设置显示订阅
  Future<void> setShowRss(bool value) => _setTabVisible(MainTab.rss, value);

  /// 统一显隐入口（对齐参考版 setMainDestinationVisible）
  ///
  /// 书架/我的不可隐藏（参考版无对应开关）；隐藏时若该页正是默认首页，
  /// 默认首页回落 bookshelf。
  Future<void> setTabVisible(MainTab tab, bool value) =>
      _setTabVisible(tab, value);

  Future<void> _setTabVisible(MainTab tab, bool value) async {
    if (!kHideableMainTabs.contains(tab)) return;
    final current = switch (tab) {
      MainTab.home => state.showHome,
      MainTab.explore => state.showDiscovery,
      MainTab.rss => state.showRss,
      _ => true,
    };
    if (current == value) return;

    final previousDefault = state.defaultHomePage;
    final previousOrder = state.navigationOrder;
    final fallbackDefault = !value && previousDefault == tab.route
        ? MainTab.bookshelf.route
        : previousDefault;
    var nextOrder = previousOrder;
    if (!value) {
      // 对齐参考版：隐藏项挪到顺序末尾，重新显示时从末尾出现
      final order = [...state.orderedTabs]
        ..remove(tab)
        ..add(tab);
      nextOrder = serializeMainTabs(order);
    }
    state = state.copyWith(
      showHome: tab == MainTab.home ? value : null,
      showDiscovery: tab == MainTab.explore ? value : null,
      showRss: tab == MainTab.rss ? value : null,
      defaultHomePage: fallbackDefault,
      navigationOrder: nextOrder,
    );
    final visibleKey = switch (tab) {
      MainTab.home => PrefKeys.showHome,
      MainTab.explore => PrefKeys.showDiscovery,
      MainTab.rss => PrefKeys.showRss,
      _ => null,
    };
    if (visibleKey != null) {
      await _settings.setBoolPref(visibleKey, value);
    }
    if (nextOrder != previousOrder) {
      await _settings.setStringPref(
        PrefKeys.mainNavigationOrder,
        nextOrder,
      );
    }
    if (fallbackDefault != previousDefault) {
      await _settings.setStringPref(
        PrefKeys.defaultHomePage,
        fallbackDefault,
      );
    }
  }

  /// 设置导航顺序（仅接受内置页签；去重并补齐缺失项）
  Future<void> setNavigationOrder(List<MainTab> tabs) async {
    final normalized = serializeMainTabs(tabs);
    if (normalized == state.navigationOrder) return;
    state = state.copyWith(navigationOrder: normalized);
    await _settings.setStringPref(PrefKeys.mainNavigationOrder, normalized);
  }

  /// 设置默认首页（home/bookshelf/explore/rss/my）
  ///
  /// 未知 route 忽略；隐藏页允许写入但首页消费时会回退到首个可见页
  /// （参考版下拉仅列可见项，正常路径不会产生隐藏默认页）。
  Future<void> setDefaultHomePage(String value) async {
    final tab = mainTabFromRoute(value);
    if (tab == null) return;
    if (state.defaultHomePage == tab.route) return;
    state = state.copyWith(defaultHomePage: tab.route);
    await _settings.setStringPref(PrefKeys.defaultHomePage, tab.route);
  }

  /// 设置导航自定义图标路径（空字符串 = 清除）
  Future<void> setNavIconPath(
    MainTab tab, {
    required bool selected,
    required String path,
  }) async {
    final target = Map<MainTab, String>.from(
      selected ? state.navIconSelectedPaths : state.navIconPaths,
    );
    if (path.isEmpty) {
      target.remove(tab);
    } else {
      target[tab] = path;
    }
    final immutable = Map<MainTab, String>.unmodifiable(target);
    state = state.copyWith(
      navIconPaths: selected ? null : immutable,
      navIconSelectedPaths: selected ? immutable : null,
    );
    final key = _iconKey(tab, selected: selected);
    if (path.isEmpty) {
      await _settings.removePref(key);
    } else {
      await _settings.setStringPref(key, path);
    }
  }

  /// 恢复「首页与导航」默认值（显隐/顺序/默认首页/自定义图标）
  ///
  /// 底栏文字档位存于 uiSettings，由设置页另行恢复；图标文件由调用方
  /// 经 NavIconStore.deleteAll() 清理。
  Future<void> resetNavigationSettings() async {
    state = MainPrefsState(loaded: true);
    for (final tab in MainTab.values) {
      await _settings.removePref(_iconKey(tab));
      await _settings.removePref(_iconKey(tab, selected: true));
    }
    await _settings.removePref(PrefKeys.showHome);
    await _settings.removePref(PrefKeys.showDiscovery);
    await _settings.removePref(PrefKeys.showRss);
    await _settings.removePref(PrefKeys.defaultHomePage);
    await _settings.removePref(PrefKeys.mainNavigationOrder);
  }

  static String _iconKey(MainTab tab, {bool selected = false}) =>
      switch (tab) {
        MainTab.home =>
          selected ? PrefKeys.navIconHomeSelected : PrefKeys.navIconHome,
        MainTab.bookshelf => selected
            ? PrefKeys.navIconBookshelfSelected
            : PrefKeys.navIconBookshelf,
        MainTab.explore => selected
            ? PrefKeys.navIconExploreSelected
            : PrefKeys.navIconExplore,
        MainTab.rss =>
          selected ? PrefKeys.navIconRssSelected : PrefKeys.navIconRss,
        MainTab.my =>
          selected ? PrefKeys.navIconMySelected : PrefKeys.navIconMy,
      };
}

/// 主界面偏好全局 Provider
final mainPrefsProvider = NotifierProvider<MainPrefsNotifier, MainPrefsState>(
  MainPrefsNotifier.new,
);
