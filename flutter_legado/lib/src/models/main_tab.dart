// [设置批2b-2a | 2026-11-02] 首页主导航页签模型（对齐参考版
// MainDestination / AppShellSettings.mainNavigationOrder）
//
// 语义基准（参考版 legado-with-MD3）：
// - `ui/main/MainDestination.kt:7-48`：route = home/bookshelf/explore/rss/my，
//   顺序解析 ordered() 会去重并补齐缺失项；
// - `domain/model/settings/AppShellSettings.kt:7-9,20-21`：默认
//   showHome/showDiscovery/showRss = true，defaultHomePage = bookshelf，
//   mainNavigationOrder = home,bookshelf,explore,rss,my；
// - `ui/config/themeConfig/MainNavigationSettingsSheet.kt:63-68`：仅首页/
//   发现/订阅可显隐，书架与我的恒显示（因此「至少保留一项」天然成立）。
// — 全栈工程师 + UI，2026-11-02
import '../l10n/app_strings.dart';

/// 首页主导航页签（route 用 enum name，与参考版 route 字符串一致）
enum MainTab {
  home,
  bookshelf,
  explore,
  rss,
  my;

  /// 参考版 route 字符串（等同 [name]，显式命名便于调用点自解释）
  String get route => name;
}

/// 参考版 MainDestination.mainDestinations 的默认顺序
const List<MainTab> kDefaultMainTabOrder = [
  MainTab.home,
  MainTab.bookshelf,
  MainTab.explore,
  MainTab.rss,
  MainTab.my,
];

/// 参考版 AppShellSettings.mainNavigationOrder 默认值
const String kDefaultMainNavigationOrder = 'home,bookshelf,explore,rss,my';

/// 可从设置显隐的页签（对齐参考版 isRouteVisible：书架/我的恒显示）
const Set<MainTab> kHideableMainTabs = {
  MainTab.home,
  MainTab.explore,
  MainTab.rss,
};

/// 页签中文名（首页/书架/发现/订阅/我的）
///
/// 书架/我的沿用 [AppStrings]（系统语言切换入口），其余与参考版文案一致。
String mainTabLabel(MainTab tab) => switch (tab) {
  MainTab.home => '首页',
  MainTab.bookshelf => AppStrings.bookshelf,
  MainTab.explore => AppStrings.discover,
  MainTab.rss => AppStrings.rss,
  MainTab.my => AppStrings.my,
};

/// route 字符串 → 页签（未知值返回 null）
MainTab? mainTabFromRoute(String route) {
  final trimmed = route.trim();
  for (final tab in MainTab.values) {
    if (tab.route == trimmed) return tab;
  }
  return null;
}

/// 解析导航顺序字符串（对齐参考版 MainDestination.ordered）
///
/// - 按逗号拆分、去空白、去重、忽略未知 route；
/// - 缺失的内置页签按默认顺序补到末尾，保证 5 项齐全。
List<MainTab> orderedMainTabs(String rawOrder) {
  final seen = <MainTab>{};
  final ordered = <MainTab>[];
  for (final part in rawOrder.split(',')) {
    final tab = mainTabFromRoute(part);
    if (tab != null && seen.add(tab)) ordered.add(tab);
  }
  for (final tab in kDefaultMainTabOrder) {
    if (seen.add(tab)) ordered.add(tab);
  }
  return ordered;
}

/// 序列化顺序为参考版逗号字符串
String serializeMainTabs(List<MainTab> tabs) {
  final seen = <MainTab>{};
  final parts = <String>[];
  for (final tab in tabs) {
    if (seen.add(tab)) parts.add(tab.route);
  }
  for (final tab in kDefaultMainTabOrder) {
    if (seen.add(tab)) parts.add(tab.route);
  }
  return parts.join(',');
}

/// 计算可见页签（按顺序 + 显隐过滤）
///
/// 防御性兜底：书架/我的恒显示，正常情况至少 2 项；若调用方传入异常配置
/// （例如未来新增可隐藏项后全部隐藏），回退到书架，保证「至少保留一项」。
List<MainTab> visibleMainTabs({
  required String order,
  required bool showHome,
  required bool showDiscovery,
  required bool showRss,
}) {
  final visible = <MainTab>[];
  for (final tab in orderedMainTabs(order)) {
    final shown = switch (tab) {
      MainTab.home => showHome,
      MainTab.explore => showDiscovery,
      MainTab.rss => showRss,
      MainTab.bookshelf || MainTab.my => true,
    };
    if (shown) visible.add(tab);
  }
  if (visible.isEmpty) return const [MainTab.bookshelf];
  return visible;
}

/// 拖拽排序结果（仅对可见项生效；隐藏项保持原相对顺序接在末尾）
///
/// Flutter `ReorderableListView` 的旧 `onReorder` 回调：向下拖动时目标索引
/// 需要先减一（被拖动项移除后的插入位置）。本函数封装该语义，便于单测；
/// 新 API `onReorderItem` 已由框架完成该调整，传 [newIndexAdjusted]=true。
List<MainTab> reorderVisibleTabs({
  required List<MainTab> visible,
  required List<MainTab> all,
  required int oldIndex,
  required int newIndex,
  bool newIndexAdjusted = false,
}) {
  if (oldIndex < 0 || oldIndex >= visible.length) {
    return orderedMainTabs(serializeMainTabs(all));
  }
  var target = newIndex;
  if (!newIndexAdjusted && target > oldIndex) target -= 1;
  if (target < 0) {
    target = 0;
  }
  if (target > visible.length - 1) {
    target = visible.length - 1;
  }
  final reordered = [...visible];
  final moved = reordered.removeAt(oldIndex);
  reordered.insert(target, moved);
  final hidden = all.where((tab) => !visible.contains(tab)).toList();
  return [...reordered, ...hidden];
}
