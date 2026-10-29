/// 发现页「源内容模式」状态与持久化键
///
/// 参考版依据（`legado-with-MD3`）：
/// - `constant/PreferKey.kt:74-76`：三个偏好键
///   `exploreMainContent`（是否停在源内容模式）、`exploreMainSourceUrl`
///   （当前书源地址）、`exploreMainKind`（书源 → 上次浏览分类的映射）；
/// - `feature/explore/ExploreMainViewModel.kt:56-198`：模式/书源/分类的
///   解析与落盘；
/// - `ui/main/MainScreen.kt:608`：发现 Tab 由 ExploreMainRoute 承载。
///
/// [exploreMainKind] 的编码与参考版一致：条目以 `\u0001` 分隔、条目内
/// `书源地址\u0000分类键`；分类键 = `标题长度:标题:分类URL`（标题可重复，
/// 必须带 URL 才能稳定定位）。
library;

import '../../models/models.dart';

/// 是否停留在「源内容模式」（参考版 PreferKey.exploreMainContent）
const String exploreMainContentKey = 'exploreMainContent';

/// 源内容模式当前书源地址（参考版 PreferKey.exploreMainSourceUrl）
const String exploreMainSourceUrlKey = 'exploreMainSourceUrl';

/// 书源 → 上次浏览分类映射（参考版 PreferKey.exploreMainKind）
const String exploreMainKindKey = 'exploreMainKind';

/// 发现书单布局模式（0=列表，1=网格；参考版 LocalPreferencesKeys.EXPLORE_LAYOUT_MODE）
const String exploreLayoutModeKey = 'explore_layout_mode';

/// 网格列数 - 竖屏（参考版 EXPLORE_LAYOUT_GRID_PORTRAIT）
const String exploreLayoutGridPortraitKey = 'explore_layout_grid_portrait';

/// 网格列数 - 横屏（参考版 EXPLORE_LAYOUT_GRID_LANDSCAPE）
const String exploreLayoutGridLandscapeKey = 'explore_layout_grid_landscape';

/// 网格列数上下限（对齐参考版 ValueStepper 1..10）
const int exploreGridCountMin = 1;
const int exploreGridCountMax = 10;

const String _kindEntrySeparator = '\u0001';
const String _kindValueSeparator = '\u0000';

/// 发现页源内容模式状态（不可变）
class ExploreMainState {
  /// 偏好是否已读取完成（未完成时不做书源回退判断，避免误清选择）
  final bool loaded;

  /// 是否停留在源内容模式
  final bool showContent;

  /// 当前书源地址（空 = 未选择）
  final String selectedSourceUrl;

  /// 书源地址 → 上次浏览分类键
  final Map<String, String> kindSelections;

  /// 是否网格布局
  final bool gridMode;

  /// 竖屏网格列数
  final int gridCountPortrait;

  /// 横屏网格列数
  final int gridCountLandscape;

  const ExploreMainState({
    this.loaded = false,
    this.showContent = false,
    this.selectedSourceUrl = '',
    this.kindSelections = const {},
    this.gridMode = false,
    this.gridCountPortrait = 3,
    this.gridCountLandscape = 7,
  });

  /// 按屏幕方向取网格列数
  int gridCountFor({required bool landscape}) =>
      landscape ? gridCountLandscape : gridCountPortrait;

  /// 指定书源上次浏览的分类键（空 = 未选择过）
  String kindKeyFor(String sourceUrl) => kindSelections[sourceUrl] ?? '';

  ExploreMainState copyWith({
    bool? loaded,
    bool? showContent,
    String? selectedSourceUrl,
    Map<String, String>? kindSelections,
    bool? gridMode,
    int? gridCountPortrait,
    int? gridCountLandscape,
  }) {
    return ExploreMainState(
      loaded: loaded ?? this.loaded,
      showContent: showContent ?? this.showContent,
      selectedSourceUrl: selectedSourceUrl ?? this.selectedSourceUrl,
      kindSelections: kindSelections ?? this.kindSelections,
      gridMode: gridMode ?? this.gridMode,
      gridCountPortrait: gridCountPortrait ?? this.gridCountPortrait,
      gridCountLandscape: gridCountLandscape ?? this.gridCountLandscape,
    );
  }
}

/// 分类在偏好与页面之间的稳定标识（对齐参考版 `exploreKindKey`）
String exploreKindKey(ExploreCategory kind) =>
    '${kind.title.length}:${kind.title}:${kind.url ?? ''}';

/// 可加载的源内容分类：URL 型且地址非空；排除解析失败占位项（标题 ERROR）
List<ExploreCategory> loadableExploreMainKinds(List<ExploreCategory> kinds) {
  final seen = <String>{};
  final result = <ExploreCategory>[];
  for (final kind in kinds) {
    final url = kind.url?.trim() ?? '';
    if (kind.type != 'url' || url.isEmpty) continue;
    if (kind.title == 'ERROR' || kind.title.startsWith('ERROR:')) continue;
    if (!seen.add(exploreKindKey(kind))) continue;
    result.add(kind);
  }
  return result;
}

/// 编码「书源 → 分类」选择（对齐参考版 encodeExploreKindSelections）
String encodeExploreKindSelections(Map<String, String> selections) {
  return selections.entries
      .map((e) => '${e.key}$_kindValueSeparator${e.value}')
      .join(_kindEntrySeparator);
}

/// 解码「书源 → 分类」选择（对齐参考版 parseExploreKindSelections）
///
/// 源地址与分类标题都不会包含控制字符，因此无需 JSON 依赖即可稳定往返；
/// 非法条目（缺分隔符/值为空）直接丢弃。
Map<String, String> parseExploreKindSelections(String raw) {
  if (raw.isEmpty) return const {};
  final result = <String, String>{};
  for (final entry in raw.split(_kindEntrySeparator)) {
    final index = entry.indexOf(_kindValueSeparator);
    if (index <= 0 || index == entry.length - 1) continue;
    result[entry.substring(0, index)] = entry.substring(index + 1);
  }
  return result;
}
