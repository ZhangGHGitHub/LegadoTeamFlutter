
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/main_tab.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/explore/explore_main_notifier.dart';
import '../providers/explore/explore_notifier.dart';
import '../routes.dart';
import '../utils/multi_pane_layout.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/navigation/adaptive_my_pane.dart';
import '../widgets/navigation/app_navigation_bars.dart';
import '../widgets/navigation/main_detail_pane_scope.dart';
import '../providers/bottom_bar_skin_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/theme/system_bar_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import 'bookshelf_screen.dart';
import 'explore_screen.dart';
import 'home_tab_screen.dart';
import 'rss_screen.dart';

/// 首页 - 底部 Tab 导航 + 左右滑动切页
///
/// 对齐安卓原版 MainActivity（activity_main.xml）：
/// - ViewPager（左右滑动切页）与 BottomNavigationView（图标底栏）并存
/// - 双击底栏项（300ms 内）：书架页回滚顶部 / 发现页收起展开项
///   （对标 onNavigationItemReselected → gotoTop/compressExplore）
/// - 返回键两段式：非书架页先回书架页；书架页 2 秒内二次返回退出
///   （对标 onBackPressedDispatcher + double_click_exit）
/// - [UI-fix v2.0.5 | 2026-08-08] 接通其他设置页主界面分组：显示发现/
///   显示订阅控制 Tab 显隐、默认首页控制启动落地页
///   （对标原版 AppConfig.showDiscovery/showRSS/defaultHomePage） — Qoder
///
/// [设置批2b-2a | 2026-11-02] 对齐参考版「首页与导航」：
/// - 底栏页签按 mainNavigationOrder 动态排序/显隐（参考版 MainScreen
///   `destinations = MainDestination.ordered(...).filter{...}`）；
/// - 隐藏当前页签（含恢复备份后的异常配置）回退到首个可见页签
///   （任务约定；参考版为越界回退 lastIndex，见 MainScreen.kt:257-261）；
/// - 默认首页在偏好加载后按可见页签映射索引（参考版 initialPage 同口径）；
/// - 自定义导航图标经 AppNavSpec 透传给三态底栏/Rail。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.detailRouteGenerator});

  /// 右侧详情栏路由生成器（默认 [AppRoutes.generateRoute]；测试可注入
  /// 桩页面，避免为结构用例构建真实详情页）。
  ///
  /// 不用 Flutter 的 `RouteFactory`：其返回类型为 `Route<dynamic>?`，而
  /// nested Navigator 的 `onGenerateRoute` 契约要求非空路由。
  final Route<dynamic> Function(RouteSettings)? detailRouteGenerator;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// 底栏双击判定窗口（对标原版 bookshelfReselected/exploreReselected 300ms）
  static const _reselectInterval = Duration(milliseconds: 300);

  /// 返回键双击退出判定窗口（对标原版 EXIT_INTERVAL = 2000ms）
  static const _exitInterval = Duration(seconds: 2);

  /// [LAYOUT_MOTION_AUDIT L3] 当前页签索引由 [_currentTab] 在 tabs 中反查，
  /// 不再单独维护栈索引（顺序变化时不会出现索引与页签错位）。
  ///
  /// 初始页沿用默认配置（书架位于索引 1），偏好异步加载完成后再按
  /// defaultHomePage/顺序校正一次。
  final PageController _pageController = PageController(initialPage: 1);

  /// 当前逻辑 Tab（Tab 显隐/顺序变化时据此重新定位索引）
  MainTab _currentTab = MainTab.bookshelf;

  /// 已访问过的 Tab 集合（首屏默认访问书架）— 保留懒构建语义
  final Set<MainTab> _visitedTabs = {MainTab.home, MainTab.bookshelf};

  /// 书架页回滚顶部信号（双击书架底栏项时自增）
  final ValueNotifier<int> _bookshelfScrollTopSignal = ValueNotifier(0);

  /// 发现页收起展开项信号（双击发现底栏项时自增）
  final ValueNotifier<int> _exploreCollapseSignal = ValueNotifier(0);

  /// 「我的」双栏右栏 nested Navigator（返回键优先 pop 右栏）
  final GlobalKey<NavigatorState> _myPaneNavigatorKey =
      GlobalKey<NavigatorState>();

  /// 书架/发现/RSS 列表-详情右栏 nested Navigator
  ///
  /// 始终挂载（隐藏时零宽 + Offstage）：窗口变窄只隐藏右栏、不清栈，
  /// 重新变宽原样恢复；只有切换 Tab 才清空（[MainDetailPaneController.clear]）。
  final GlobalKey<NavigatorState> _detailPaneNavigatorKey =
      GlobalKey<NavigatorState>();

  final MainDetailPaneController _detailPaneController =
      MainDetailPaneController();

  late final _MainDetailNavigatorObserver _detailPaneObserver =
      _MainDetailNavigatorObserver(_onDetailPaneStackChanged);

  /// 配置变化导致当前 Tab 被隐藏时，帧末清空右栏（避免显示旧 Tab 详情）
  bool _detailClearScheduled = false;

  DateTime? _lastTapTime;
  int _lastTapIndex = -1;
  DateTime? _lastBackTime;

  /// 默认首页是否已应用（偏好异步加载完成后仅应用一次）
  bool _defaultHomePageApplied = false;

  /// 用户是否已手动切页（加载完成前手动切页则不再套用默认首页）
  bool _userNavigated = false;

  /// 待校正的 PageView 目标索引（同帧多次 build 只保留最后一次）
  int? _pendingPageIndex;

  /// 是否已调度 post-frame 校正（避免同帧重复注册回调）
  bool _pageSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    _detailPaneController.navigatorKey = _detailPaneNavigatorKey;
  }

  @override
  void dispose() {
    _detailPaneController.dispose();
    _pageController.dispose();
    _bookshelfScrollTopSignal.dispose();
    _exploreCollapseSignal.dispose();
    super.dispose();
  }

  /// 右栏栈变化：回写 hasStack（HomeScreen 经 ListenableBuilder 重排）
  void _onDetailPaneStackChanged() {
    _detailPaneController.updateStack(
      depth: _detailPaneObserver.stackDepth,
      hasPage: _detailPaneObserver.hasPage,
    );
  }

  /// 主 Tab 是否支持列表-详情（书架/发现/RSS）
  bool _tabSupportsDetail(MainTab tab) => switch (tab) {
    MainTab.bookshelf || MainTab.explore || MainTab.rss => true,
    MainTab.home || MainTab.my => false,
  };

  /// 帧末清空右栏（配置变更等 build 阶段无法同步 pop 的场景）
  void _scheduleDetailPaneClear() {
    if (_detailClearScheduled) return;
    _detailClearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detailClearScheduled = false;
      if (!mounted) return;
      _detailPaneController.clear();
    });
  }

  /// 默认首页偏好值 → 逻辑 Tab（对标原版 defaultHomePage 数组值）
  MainTab _tabOfHomePage(String value) =>
      mainTabFromRoute(value) ?? MainTab.bookshelf;

  void _onDestinationSelected(List<MainTab> tabs, int index) {
    if (index < 0 || index >= tabs.length) return;
    final now = DateTime.now();
    final currentIndex = tabs.indexOf(_currentTab);
    // 双击检测：300ms 内再次点击当前选中项 → 触发 reselect 动作
    if (index == currentIndex &&
        _lastTapIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!) <= _reselectInterval) {
      _lastTapTime = null;
      _onReselect(tabs[index]);
      return;
    }
    _lastTapTime = now;
    _lastTapIndex = index;
    if (index != currentIndex) {
      _userNavigated = true;
      // 切 Tab 清空列表-详情右栏（登记行为：不跨 Tab 复用详情栈）
      _detailPaneController.clear();
      setState(() {
        _currentTab = tabs[index];
        _visitedTabs.add(_currentTab);
      });
      // 对标原版 setCurrentItem(position, false)：无过渡动画
      if (_pageController.hasClients) {
        _pageController.jumpToPage(index);
      }
    }
  }

  /// 底栏双击动作（对标 onNavigationItemReselected）
  void _onReselect(MainTab tab) {
    switch (tab) {
      case MainTab.bookshelf: // 书架：gotoTop
        _bookshelfScrollTopSignal.value++;
      case MainTab.explore: // 发现：compressExplore（收起已展开的分类）
        _exploreCollapseSignal.value++;
      default:
        break;
    }
  }

  void _onPageChanged(List<MainTab> tabs, int index) {
    if (index < 0 || index >= tabs.length) return;
    if (tabs[index] != _currentTab) {
      // 滑动切页视为用户主动导航：偏好加载完成前不再套用默认首页
      _userNavigated = true;
      // 切 Tab 清空列表-详情右栏
      _detailPaneController.clear();
    }
    setState(() {
      _currentTab = tabs[index];
      _visitedTabs.add(_currentTab);
    });
  }

  /// 返回键两段式处理（对标 MainActivity.onBackPressedDispatcher）
  Future<void> _handleBack(List<MainTab> tabs) async {
    // [设置批2b-2b] 「我的」容器：先 pop 容器 nested Navigator（双栏/单栏
    // 都保留同一栈），空栈后继续走原有「切回书架 / 双击退出」逻辑。
    if (_currentTab == MainTab.my) {
      final myPane = _myPaneNavigatorKey.currentState;
      if (myPane != null && myPane.canPop()) {
        myPane.maybePop();
        return;
      }
    }
    // [设置批2b-2c] 书架/发现/RSS 列表-详情：先 pop 右侧详情栈；空栈后
    // 继续走原有「切回书架 / 双击退出」逻辑。仅在多栏可用（右栏可见）时
    // 消费返回：窄屏隐藏的旧栈不拦截返回。
    if (_tabSupportsDetail(_currentTab) && _detailPaneController.isEnabled) {
      final detailPane = _detailPaneNavigatorKey.currentState;
      if (detailPane != null && detailPane.canPop()) {
        detailPane.maybePop();
        return;
      }
    }
    // [批36c 源内容模式返回键归属] 内容模式的返回由宿主统一消费：
    // 发现页与首页根节点同属一个 ModalRoute，Flutter 返回处理会依次通知
    // 该路由上所有 PopScope（didPop=false），内层 PopScope 无法「消费」本次
    // 返回；旧实现因此同时关闭内容模式并把 Tab 切回书架（设备验收场景 6）。
    // 现在先判定「发现 Tab 正在展示源内容」，命中则回源列表并直接返回，
    // 不再走切 Tab 分支。
    if (_currentTab == MainTab.explore && _consumeExploreContentBack()) {
      return;
    }
    if (_currentTab != MainTab.bookshelf) {
      final bookshelfIndex = tabs.indexOf(MainTab.bookshelf);
      final targetIndex = bookshelfIndex >= 0 ? bookshelfIndex : 0;
      if (targetIndex >= 0 && targetIndex < tabs.length) {
        // 返回切回书架同样清空右栏（右栏内容属于原 Tab）
        _detailPaneController.clear();
        setState(() {
          _currentTab = tabs[targetIndex];
          _visitedTabs.add(_currentTab);
        });
        if (_pageController.hasClients) {
          _pageController.jumpToPage(targetIndex);
        }
      }
      return;
    }
    final now = DateTime.now();
    if (_lastBackTime != null &&
        now.difference(_lastBackTime!) <= _exitInterval) {
      await SystemNavigator.pop();
      return;
    }
    _lastBackTime = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppStrings.doubleClickExit),
          duration: _exitInterval,
        ),
      );
  }

  /// 发现 Tab 源内容模式返回：切回源列表并返回 true（已消费本次返回）
  ///
  /// 判定口径与 [ExploreScreen] 的展示条件保持一致：仅当 `showContent` 为真
  /// 且选中书源仍在当前发现源列表中（源内容实际可见）才算内容模式；
  /// 源列表模式、书源解析过渡帧、选中源失效回退等情况一律返回 false，
  /// 交由原有 Tab 返回逻辑（切回书架）。
  bool _consumeExploreContentBack() {
    final main = ref.read(exploreMainNotifierProvider);
    if (!main.showContent) return false;
    final url = main.selectedSourceUrl;
    final explore = ref.read(exploreNotifierProvider);
    final hasSource = url.isNotEmpty &&
        explore.bookSources.any((s) => s.bookSourceUrl == url);
    if (!hasSource) return false;
    ref.read(exploreMainNotifierProvider.notifier).setShowContent(false);
    return true;
  }

  /// 逻辑 Tab → 页面内容（未访问过的 Tab 用占位以保留懒构建语义）
  Widget _pageOf(MainTab tab) {
    switch (tab) {
      case MainTab.home:
        return _visitedTabs.contains(tab)
            ? const HomeTabScreen()
            : const SizedBox.shrink();
      case MainTab.bookshelf:
        return BookshelfScreen(scrollTopSignal: _bookshelfScrollTopSignal);
      case MainTab.explore:
        return _visitedTabs.contains(tab)
            ? ExploreScreen(collapseSignal: _exploreCollapseSignal)
            : const SizedBox.shrink();
      case MainTab.rss:
        return _visitedTabs.contains(tab)
            ? const RssScreen()
            : const SizedBox.shrink();
      case MainTab.my:
        return _visitedTabs.contains(tab)
            ? AdaptiveMyPane(
                navigatorKey: _myPaneNavigatorKey,
                active: _currentTab == MainTab.my,
              )
            : const SizedBox.shrink();
    }
  }

  /// 校正 PageController 到当前页签索引
  ///
  /// 不能只在顺序/显隐变化时校正：横竖屏切换导致底栏 ↔ Rail 布局变化时，
  /// PageView 的父级结构改变会被重建，`PageController` 会按 initialPage
  /// 重新挂载（回到索引 1），而选中页签与内容索引仍保留。因此每次 build
  /// 都调度一次 post-frame 检查，发现 page 与目标索引不一致就 jump。
  ///
  /// 单页配置下目标恒为 0，initialPage=1 也会在此收敛。
  void _syncPageController(int index) {
    _pendingPageIndex = index;
    if (_pageSyncScheduled) return;
    _pageSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageSyncScheduled = false;
      final target = _pendingPageIndex;
      _pendingPageIndex = null;
      if (!mounted || !_pageController.hasClients || target == null) return;
      final page = _pageController.page;
      if (page != null && page.round() == target) return;
      _pageController.jumpToPage(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(mainPrefsProvider);
    final skinState = ref.watch(bottomBarSkinProvider);
    final activeSkin = skinState.active;
    final tabs = prefs.visibleTabs;

    // 偏好加载完成后应用默认首页（仅启动时生效一次，对标参考版 MainScreen
    // initialPage = destinations.indexOf(defaultHomePage)；目标不可见时回退
    // 首个可见页签（参考版回退 index 0）
    if (prefs.loaded && !_defaultHomePageApplied) {
      _defaultHomePageApplied = true;
      if (!_userNavigated) {
        final target = _tabOfHomePage(prefs.defaultHomePage);
        _currentTab = tabs.contains(target) ? target : tabs.first;
      }
    }
    // Tab 显隐/顺序变化后当前 Tab 可能被隐藏：回退首个可见页签
    //（参考版越界回退 lastIndex；本实现按任务约定回退 first visible）
    if (!tabs.contains(_currentTab)) {
      _currentTab = tabs.first;
      // 旧 Tab 的右栏详情不能展示在新 Tab 上；build 阶段不能同步 pop，
      // 帧末清空（与用户切 Tab 的显式 clear 同一语义）。
      _scheduleDetailPaneClear();
    }
    final currentIndex = tabs.indexOf(_currentTab);
    _visitedTabs.add(_currentTab);
    _syncPageController(currentIndex);

    // [设置批2b-2b] 单栏匿名栈全屏：隐藏底栏/Rail 并禁用横滑，避免
    // 页面被底栏压缩或滑动切走（参考版单栏目的地覆盖 MainScreen）。
    final myPaneFullscreen =
        ref.watch(myPaneFullscreenProvider) && _currentTab == MainTab.my;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack(tabs);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ui = ref.watch(uiSettingsProvider);
          final useRail = _railActive(
            ui,
            constraints.maxWidth,
            MediaQuery.of(context).orientation,
          );
          // 单页配置：NavigationBar/Rail 均要求 ≥2 项，隐藏导航容器，
          // 仅保留单页内容（PageView 由 post-frame 收敛到索引 0）。
          final showRail =
              useRail && tabs.length >= 2 && !myPaneFullscreen;
          final pageArea = PageView.builder(
            controller: _pageController,
            // [UI_SYNC_REFACTOR S1] 滑动切页（对齐参考 HorizontalPager
            // userScrollEnabled=true；allowImplicitScrolling≈预载相邻页）
            // 单栏匿名栈全屏时禁止横滑，避免退出全屏页面。
            physics: myPaneFullscreen
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            allowImplicitScrolling: true,
            itemCount: tabs.length,
            // 顺序变化时按页签 key 找回新索引，保住各页 State（滚动位置等）
            findChildIndexCallback: (key) {
              if (key is ValueKey<MainTab>) {
                final index = tabs.indexOf(key.value);
                return index >= 0 ? index : null;
              }
              return null;
            },
            onPageChanged: (index) => _onPageChanged(tabs, index),
            itemBuilder: (context, index) {
              final tab = tabs[index];
              return _KeepAlivePage(
                key: ValueKey(tab),
                child: _pageOf(tab),
              );
            },
          );
          // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
          return AppScaffold(
            // 沉浸式状态栏开启时顶栏延伸至状态栏区域（对标原版 fullScreen +
            // AppConfig.isTransparentStatusBar）；关闭时保留顶部 SafeArea
            body: SafeArea(
              top: !ref.watch(
                systemBarProvider.select((s) => s.transparentStatusBar),
              ),
              bottom: false,
              // [UI_SYNC_REFACTOR B3] tabletInterface + sw≥600 切 NavigationRail
              //（简版：系统图标不带皮肤，expand 持久化登记差异延后）
              // [批2b-2a 旋转回修] 保持 Row/Expanded 结构恒定，Rail 用
              // 零尺寸占位替代：横竖屏切换时 PageView 的父链不改变，元素与
              // PageController position 不会被重建（否则会按 initialPage
              // 回到索引 1，与选中页签不一致）。NavigationRail 仅在 useRail
              // 时构建，窄屏仍保持底栏形态。
              child: Row(
                children: [
                  if (showRail)
                    _buildRail(ui, tabs, currentIndex, prefs)
                  else
                    const SizedBox.shrink(),
                  if (showRail)
                    const VerticalDivider(width: 1, thickness: 0)
                  else
                    const SizedBox.shrink(),
                  Expanded(
                    child: _buildPageAreaWithDetail(
                      pageArea,
                      ui.multiPaneMode,
                    ),
                  ),
                ],
              ),
            ),
            // [UI_SYNC_REFACTOR B3] 底栏三形态：隐藏 / 悬浮 64dp 胶囊 / 标准
            // NavigationBar（label 三档 + 透明度）；皮肤图标两种形态均保留
            // 单栏匿名栈全屏时整条底栏隐藏（退出该栈后恢复）。
            bottomBar: myPaneFullscreen
                ? null
                : _buildBottomBar(
                    context,
                    ui,
                    tabs,
                    currentIndex,
                    activeSkin,
                    prefs,
                  ),
          );
        },
      ),
    );
  }

  /// 主 Tab 内容 + 列表-详情右栏
  ///
  /// 结构恒定：`Row[Expanded(PageView), 间距槽, 右栏槽]`。右栏槽宽度为 0
  /// （空栈/窄屏/off）时仍挂载 nested Navigator（Offstage），窗口变窄不会
  /// 销毁右栏栈，重新变宽原样恢复；PageView 的父链在横竖屏切换时不变，
  /// 保住 PageController position 与各页 State（2b-2a 旋转回修口径）。
  ///
  /// 多栏判定用当前 PageView 区域尺寸（已扣 Rail）+ 完整窗口尺寸，与
  /// `AdaptiveMyPane` 同口径；右栏只在当前 Tab ∈ 书架/发现/RSS 且栈非空
  /// 时占位。
  Widget _buildPageAreaWithDetail(Widget pageArea, MultiPaneMode mode) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final paneSize = Size(constraints.maxWidth, constraints.maxHeight);
        final multi = resolveMultiPane(
          mode,
          paneSize,
          windowSize: MediaQuery.sizeOf(context),
        );
        final enabled = multi && _tabSupportsDetail(_currentTab);
        // build 期间静默写入（不通知），列表点击时经 controller 读取。
        _detailPaneController.setEnabled(enabled);
        return MainDetailPaneScope(
          controller: _detailPaneController,
          isMultiPane: enabled,
          child: ListenableBuilder(
            listenable: _detailPaneController,
            builder: (context, _) {
              final rightWidth =
                  enabled && _detailPaneController.hasStack
                  ? resolveListDetailRightWidth(paneSize.width)
                  : 0.0;
              final showDetail = rightWidth > 0;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: pageArea),
                  SizedBox(
                    key: const ValueKey('main-detail-gap'),
                    width: showDetail ? kMultiPaneGap : 0,
                  ),
                  SizedBox(
                    key: const ValueKey('main-detail-right'),
                    width: rightWidth,
                    child: TickerMode(
                      // 隐藏期间暂停页面动画（Offstage 只停绘制，不停 ticker）
                      enabled: showDetail,
                      child: Offstage(
                        offstage: !showDetail,
                        child: _buildDetailNavigator(),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 右侧详情 nested Navigator（路由表与 root 一致）
  Widget _buildDetailNavigator() {
    return Navigator(
      key: _detailPaneNavigatorKey,
      initialRoute: kMainDetailEmptyRoute,
      // 只生成一个空态路由：默认 initialRoutes 会把哨兵路径拆成
      // `/` + 目标两页，导致初始栈深 2（canPop 为真）。
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: kMainDetailEmptyRoute),
          builder: (_) => const SizedBox.shrink(),
        ),
      ],
      onGenerateRoute: widget.detailRouteGenerator ?? AppRoutes.generateRoute,
      observers: [_detailPaneObserver],
    );
  }

  /// 导航项规格（三态底栏统一消费源）
  List<AppNavSpec> _specsFor(
    List<MainTab> tabs,
    MainPrefsState prefs,
  ) =>
      [
        for (final tab in tabs)
          mainTabNavSpec(
            tab,
            customIconPath: prefs.navIconPath(tab),
            customSelectedIconPath: prefs.navIconPath(tab, selected: true),
          ),
      ];

  /// Rail 激活判定（对齐参考仓 tabletInterface：auto/always/landscape/off）
  bool _railActive(UiSettingsState ui, double width, Orientation orientation) {
    switch (ui.tabletInterface) {
      case TabletInterfaceMode.always:
        return true;
      case TabletInterfaceMode.landscape:
        return orientation == Orientation.landscape;
      case TabletInterfaceMode.off:
        return false;
      case TabletInterfaceMode.auto:
        return width >= 600;
    }
  }

  /// 平板侧栏（组件化：皮肤图标+头部搜索钮+书架分组菜单+expand 持久化）
  Widget _buildRail(
    UiSettingsState ui,
    List<MainTab> tabs,
    int currentIndex,
    MainPrefsState prefs,
  ) {
    final bookshelf = ref.watch(bookshelfNotifierProvider);
    return AppRailBar(
      specs: _specsFor(tabs, prefs),
      currentIndex: currentIndex,
      activeSkin: ref.watch(bottomBarSkinProvider.select((s) => s.active)),
      extended: ui.railExtended,
      showLabel: ui.labelVisibilityMode != BottomBarLabelMode.unlabeled,
      onSelect: (index) => _onDestinationSelected(tabs, index),
      onToggleExtended: () => ref
          .read(uiSettingsProvider.notifier)
          .setRailExtended(!ui.railExtended),
      onSearch: () => Navigator.of(context).pushNamed(AppRoutes.search),
      groups: [
        for (final g in bookshelf.groups) g.groupName,
      ],
      selectedGroupIndex: bookshelf.selectedGroupIndex,
      onGroupSelected: (index) =>
          ref.read(bookshelfNotifierProvider.notifier).selectGroup(index),
    );
  }

  /// 底栏构建：隐藏 / 悬浮胶囊 / 标准 NavigationBar（label 三档+透明度）
  Widget? _buildBottomBar(
    BuildContext context,
    UiSettingsState ui,
    List<MainTab> tabs,
    int currentIndex,
    String activeSkin,
    MainPrefsState prefs,
  ) {
    // NavigationBar/悬浮栏单页无意义，且 Flutter NavigationBar 断言 ≥2 项
    if (!ui.showBottomView || tabs.length < 2) return null;
    final specs = _specsFor(tabs, prefs);
    final labelBehavior = _labelBehaviorOf(ui.labelVisibilityMode);
    if (ui.useFloatingBottomBar) {
      return AppFloatingBottomBar(
        specs: specs,
        currentIndex: currentIndex,
        activeSkin: activeSkin,
        onSelect: (index) => _onDestinationSelected(tabs, index),
        useBlur: ui.enableBlur,
        blurRadius: ui.bottomBarBlurRadius,
        blurAlpha: ui.bottomBarBlurAlpha,
        labelBehavior: labelBehavior,
      );
    }
    return AppShortNavigationBar(
      specs: specs,
      currentIndex: currentIndex,
      activeSkin: activeSkin,
      labelBehavior: labelBehavior,
      opacity: ui.bottomBarOpacity / 100,
      onSelect: (index) => _onDestinationSelected(tabs, index),
    );
  }

  /// 底栏文字档位 → Flutter NavigationBar 标签行为
  NavigationDestinationLabelBehavior _labelBehaviorOf(
    BottomBarLabelMode mode,
  ) =>
      switch (mode) {
        // 参考版 auto 与 selected 都映射 IconWithSelectedLabel
        BottomBarLabelMode.auto ||
        BottomBarLabelMode.selected =>
          NavigationDestinationLabelBehavior.onlyShowSelected,
        BottomBarLabelMode.labeled =>
          NavigationDestinationLabelBehavior.alwaysShow,
        BottomBarLabelMode.unlabeled =>
          NavigationDestinationLabelBehavior.alwaysHide,
      };
}

/// [UI_SYNC_REFACTOR S1] 页保活（对齐参考 HorizontalPager
/// beyondViewportPageCount=4：全部页常驻不销毁，懒构建语义保留）
class _KeepAlivePage extends StatefulWidget {
  final Widget child;

  const _KeepAlivePage({super.key, required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 列表-详情右栏 Navigator 观察者：维护栈顶与业务页面存在性
class _MainDetailNavigatorObserver extends NavigatorObserver {
  _MainDetailNavigatorObserver(this.onChanged);

  final VoidCallback onChanged;
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];

  /// 当前栈深度（初始空态为 1）
  int get stackDepth => _stack.length;

  /// 是否有初始空态之外的业务页面（匿名路由也算，不能只看 name）
  bool get hasPage =>
      _stack.isNotEmpty &&
      !(_stack.length == 1 &&
          _stack.single.settings.name == kMainDetailEmptyRoute);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0) {
      _stack[index] = newRoute;
    } else {
      _stack.add(newRoute);
    }
    onChanged();
  }
}
