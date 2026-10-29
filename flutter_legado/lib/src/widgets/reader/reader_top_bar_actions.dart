// 阅读器顶栏动作池（对齐参考版 ReadMenuActionDefs.kt，批37）
//
// 参考版把顶栏/浮动图标/底栏三处按钮收敛成一份「按钮注册表」：
// 每个按钮的 id/图标/文案/长按二级菜单/适用书型只写一遍，各处按自己的
// 配置顺序取用。本文件只落顶栏这一处（参考版 `ReadMenuActionDefs.kt`
// `ReadBookTopBarOnlyActionIds` + 共享图标池子集），其余入口维持现状。
//
// 默认顺序对齐参考版 `ReadButtonConfigDelegate.DEFAULT_TITLE_BAR_ACTION_IDS`
// = { download, refresh, change_source, toc_rule, charset, more_actions }，
// 其中 toc_rule/charset 只对本地书生效，所以在线书默认仍是旧版那套
// 「换源 / 刷新 / 缓存 / 更多」四个图标（池顺序即默认展示顺序）。
//
// [批37b P2-2 登记] 本仓库的 `toc_rule` 目前只打开「目录规则库」管理页，
// 尚未把选中规则作用于当前本地 TXT（参考版 MenuTocRegex 会写 book.tocUrl
// 并重解析目录）。为不误导用户，本批将其移出默认启用集；入口文案改为
// 「目录规则库（仅管理规则）」，配置页仍可手动开启，后续批次打通后再
// 恢复默认开启。
//
// 持久化键对齐参考版 SharedPreferences 文件名 + 键名：
// `title_bar_actions` / `actions`。Flutter 只有单一 prefs 存储，故实际键
// 写作 `title_bar_actions.actions`；值格式沿用参考版
// `id,enabled;id,enabled`（`ReadButtonConfigDelegate.saveButtonConfig`）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData;
import 'package:material_symbols_icons/symbols.dart';

import '../../constants/pref_keys.dart';

/// 顶栏最多展示的按钮数（对齐参考版 `MAX_TITLE_BAR_ACTIONS = 6`）
///
/// 含末尾固定的「更多」按钮，避免挤压书名/章节信息。
const int kReaderTopBarMaxActions = 6;

/// 「更多」动作 id（对齐参考版 `more_actions`）
const String kReaderMoreActionsId = 'more_actions';

/// 顶栏动作配置持久化键（参考版 prefs 文件 `title_bar_actions` + 键 `actions`）
const String kReaderTopBarActionsPrefsKey = PrefKeys.readerTopBarActions;

/// 动作适用书型（对齐参考版 `isReadMenuActionApplicable` 的判定分组）
enum ReaderBookScope {
  /// 所有书都可用
  all,

  /// 仅在线书（非本地/WebDAV）
  online,

  /// 仅本地书
  local,

  /// 仅本地 TXT（需 TXT 目录规则等能力）
  localTxt;

  /// 配置页副标题（null = 不标注，所有书都适用）
  String? get scopeLabel {
    switch (this) {
      case ReaderBookScope.all:
        return null;
      case ReaderBookScope.online:
        return '仅在线书';
      case ReaderBookScope.local:
        return '仅本地书';
      case ReaderBookScope.localTxt:
        return '仅本地 TXT';
    }
  }
}

/// 长按二级动作（参考版 `ReadMenuLongPressMenu` 的子集）
///
/// 参考版仅在「换源」「刷新」上挂长按菜单；本批实现换源与缓存两个入口，
/// 刷新等其余动作在描述符里登记为不支持长按（`longPress == null`）。
enum ReaderTopBarLongPress {
  /// 换源长按：换书源 / 单章换源
  changeSource,

  /// 缓存长按：进入缓存管理页
  cacheManage,
}

/// 当前书籍的书型特征（渲染期过滤用；不随配置变化）
@immutable
class ReaderBookTraits {
  /// 本地/WebDAV 书（对齐 BookType.isLocalOrigin 的调用口径）
  final bool isLocal;

  /// 本地 TXT 书（对齐 Book.isLocalTxt）
  final bool isLocalTxt;

  const ReaderBookTraits({this.isLocal = false, this.isLocalTxt = false});

  /// 在线书（非本地）
  bool get isOnline => !isLocal;
}

/// 一个顶栏动作的静态描述符（参考版 `ReadMenuActionDef` 去掉运行时回调）
@immutable
class ReaderTopBarActionDef {
  final String id;
  final IconData icon;
  final String label;
  final ReaderBookScope scope;

  /// 长按二级动作；null = 不支持长按
  final ReaderTopBarLongPress? longPress;

  const ReaderTopBarActionDef({
    required this.id,
    required this.icon,
    required this.label,
    this.scope = ReaderBookScope.all,
    this.longPress,
  });

  /// 是否支持长按二级动作
  bool get supportsLongPress => longPress != null;

  /// 当前书是否用得上这个按钮（对齐参考版 isReadMenuActionApplicable）
  bool isApplicable(ReaderBookTraits traits) {
    switch (scope) {
      case ReaderBookScope.all:
        return true;
      case ReaderBookScope.online:
        return traits.isOnline;
      case ReaderBookScope.local:
        return traits.isLocal;
      case ReaderBookScope.localTxt:
        return traits.isLocalTxt;
    }
  }
}

/// 完整顶栏动作池（顺序 = 配置页初始顺序 = 参考版按钮池顺序）
///
/// 仅收录我方已接通的行为入口；参考版池中的 source_login/source_pay/
/// edit_source/disable_source/audio_download 等依赖书源异步查询或未接通的
/// 动作暂不入池（见批37交付说明「未做项」）。
const List<ReaderTopBarActionDef> readerTopBarActionPool = [
  ReaderTopBarActionDef(
    id: 'download',
    icon: Symbols.download_rounded,
    label: '下载（离线缓存）',
    scope: ReaderBookScope.online,
    longPress: ReaderTopBarLongPress.cacheManage,
  ),
  ReaderTopBarActionDef(
    id: 'refresh',
    icon: Symbols.refresh_rounded,
    label: '刷新正文',
    scope: ReaderBookScope.online,
  ),
  ReaderTopBarActionDef(
    id: 'change_source',
    icon: Symbols.swap_horiz_rounded,
    label: '换源',
    scope: ReaderBookScope.online,
    longPress: ReaderTopBarLongPress.changeSource,
  ),
  ReaderTopBarActionDef(
    id: 'toc_rule',
    icon: Symbols.toc_rounded,
    // [批37b P2-2] 当前仅打开规则库管理页，不作用于当前书——文案如实标注
    label: '目录规则库（仅管理规则）',
    scope: ReaderBookScope.localTxt,
  ),
  ReaderTopBarActionDef(
    id: 'charset',
    icon: Symbols.translate_rounded,
    label: '设置编码',
    scope: ReaderBookScope.local,
  ),
  ReaderTopBarActionDef(
    id: 'catalog',
    icon: Symbols.format_list_bulleted_rounded,
    label: '目录',
  ),
  ReaderTopBarActionDef(
    id: 'search',
    icon: Symbols.search_rounded,
    label: '全文搜索',
  ),
  ReaderTopBarActionDef(
    id: 'auto_page',
    icon: Symbols.play_arrow_rounded,
    label: '自动翻页',
  ),
  ReaderTopBarActionDef(
    id: 'read_aloud',
    icon: Symbols.record_voice_over_rounded,
    label: '朗读',
  ),
  ReaderTopBarActionDef(
    id: 'setting',
    icon: Symbols.settings_rounded,
    label: '界面设置',
  ),
  ReaderTopBarActionDef(
    id: 'addBookmark',
    icon: Symbols.bookmark_add_rounded,
    label: '添加书签',
  ),
  ReaderTopBarActionDef(
    id: 'replace',
    icon: Symbols.find_replace_rounded,
    label: '替换规则',
  ),
  ReaderTopBarActionDef(
    id: 'theme',
    icon: Symbols.dark_mode_rounded,
    label: '日/夜切换',
  ),
  ReaderTopBarActionDef(
    id: 'prev_chapter',
    icon: Symbols.skip_previous_rounded,
    label: '上一章',
  ),
  ReaderTopBarActionDef(
    id: 'next_chapter',
    icon: Symbols.skip_next_rounded,
    label: '下一章',
  ),
  ReaderTopBarActionDef(
    id: kReaderMoreActionsId,
    icon: Symbols.more_vert_rounded,
    label: '更多',
  ),
];

/// 动作 id → 描述符（池内 id 唯一）
final Map<String, ReaderTopBarActionDef> readerTopBarActionById = {
  for (final def in readerTopBarActionPool) def.id: def,
};

/// 参考版默认开启的顶栏动作（顺序由 [readerTopBarActionPool] 决定）
///
/// [批37b P2-2] `toc_rule` 暂未接通「作用于当前书」的语义，默认关闭
/// （入口仍在池内，用户可在配置页手动开启；见文件头登记）。
const Set<String> kReaderDefaultTopBarActionIds = {
  'download',
  'refresh',
  'change_source',
  'charset',
  kReaderMoreActionsId,
};

/// 配置项：动作 id + 是否开启
@immutable
class ReaderTopBarActionItem {
  final String id;
  final bool enabled;

  const ReaderTopBarActionItem({required this.id, required this.enabled});

  ReaderTopBarActionItem copyWith({bool? enabled}) =>
      ReaderTopBarActionItem(id: id, enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is ReaderTopBarActionItem &&
      other.id == id &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, enabled);

  @override
  String toString() => 'ReaderTopBarActionItem($id, enabled: $enabled)';
}

/// 顶栏动作配置（不可变，顺序即展示顺序）
@immutable
class ReaderTopBarActionsState {
  final List<ReaderTopBarActionItem> items;

  const ReaderTopBarActionsState(this.items);

  ReaderTopBarActionItem? itemFor(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderTopBarActionsState && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

/// 默认配置：参考版默认开启项，池顺序
List<ReaderTopBarActionItem> defaultReaderTopBarActionItems() => [
  for (final def in readerTopBarActionPool)
    ReaderTopBarActionItem(
      id: def.id,
      enabled: kReaderDefaultTopBarActionIds.contains(def.id),
    ),
];

/// 归一化配置项（对齐参考版 `normalizeButtonConfig`）
///
/// - 未知 id / 重复 id 丢弃；
/// - 缺失的池内 id 追加在末尾（默认关闭）；
/// - 「更多」固定开启且固定末位（保证顶栏不会出现无任何入口的死角，
///   配置页也不允许拖动它）。
List<ReaderTopBarActionItem> normalizeReaderTopBarActionItems(
  Iterable<ReaderTopBarActionItem> items,
) {
  final seen = <String>{};
  final out = <ReaderTopBarActionItem>[];
  for (final item in items) {
    if (!readerTopBarActionById.containsKey(item.id)) continue;
    if (item.id == kReaderMoreActionsId) continue;
    if (!seen.add(item.id)) continue;
    out.add(ReaderTopBarActionItem(id: item.id, enabled: item.enabled));
  }
  for (final def in readerTopBarActionPool) {
    if (def.id == kReaderMoreActionsId) continue;
    if (!seen.add(def.id)) continue;
    out.add(ReaderTopBarActionItem(id: def.id, enabled: false));
  }
  out.add(
    const ReaderTopBarActionItem(id: kReaderMoreActionsId, enabled: true),
  );
  return out;
}

/// 序列化为参考版格式：`id,true;id,false`
String encodeReaderTopBarActions(Iterable<ReaderTopBarActionItem> items) {
  return normalizeReaderTopBarActionItems(
    items,
  ).map((e) => '${e.id},${e.enabled}').join(';');
}

/// 解析参考版格式配置；空/非法值回退默认（对齐 loadButtonConfig 的
/// `defaultEnabled` 分支）
List<ReaderTopBarActionItem> decodeReaderTopBarActions(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return defaultReaderTopBarActionItems();
  final parsed = <ReaderTopBarActionItem>[];
  for (final token in text.split(';')) {
    final parts = token.split(',');
    if (parts.length != 2) continue;
    final id = parts[0].trim();
    final enabled = switch (parts[1].trim().toLowerCase()) {
      'true' => true,
      'false' => false,
      _ => null,
    };
    if (enabled == null || !readerTopBarActionById.containsKey(id)) continue;
    parsed.add(ReaderTopBarActionItem(id: id, enabled: enabled));
  }
  if (parsed.isEmpty) return defaultReaderTopBarActionItems();
  return normalizeReaderTopBarActionItems(parsed);
}

/// 计算顶栏实际展示的动作（对齐参考版 `loadTitleBarActions`）
///
/// 顺序 = 配置顺序；过滤掉未开启/当前书不适用的动作；最多
/// [kReaderTopBarMaxActions] 个，末尾固定补「更多」（占一个名额）。
/// 返回列表始终非空且最后一个 id 必为 [kReaderMoreActionsId]。
List<ReaderTopBarActionDef> buildReaderTopBarActions(
  ReaderTopBarActionsState config, {
  required ReaderBookTraits traits,
  int max = kReaderTopBarMaxActions,
}) {
  final out = <ReaderTopBarActionDef>[];
  final limit = max < 2 ? 1 : max - 1;
  for (final item in config.items) {
    if (!item.enabled || item.id == kReaderMoreActionsId) continue;
    final def = readerTopBarActionById[item.id];
    if (def == null || !def.isApplicable(traits)) continue;
    out.add(def);
    if (out.length >= limit) break;
  }
  out.add(readerTopBarActionById[kReaderMoreActionsId]!);
  return out;
}

/// 被移出顶栏的动作（「更多」菜单兜底用）
///
/// 范围 = 当前书适用的全部池内动作（不论配置开关，只要是「顶栏没有显示」），
/// 去掉「更多」本身与 [excludeIds]（已在「更多」菜单里以原名存在的项）。
///
/// [批37b P3-11] 顺序按用户配置（`config.items`）而非动作池顺序：兜底菜单
/// 与顶栏配置页顺序一致，用户上移/下移后「更多」里的排列同步变化。
List<ReaderTopBarActionDef> hiddenReaderTopBarActions(
  ReaderTopBarActionsState config, {
  required ReaderBookTraits traits,
  required Set<String> visibleIds,
  Set<String> excludeIds = const {},
}) {
  return [
    for (final item in config.items)
      if (item.id != kReaderMoreActionsId &&
          !visibleIds.contains(item.id) &&
          !excludeIds.contains(item.id))
        ?readerTopBarActionById[item.id],
  ].where((def) => def.isApplicable(traits)).toList();
}
