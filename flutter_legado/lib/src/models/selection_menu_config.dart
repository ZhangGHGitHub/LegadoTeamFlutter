// 正文选择菜单配置（批4c）
//
// 参考 `ReadBookController.kt:2153-2181`（内置 12 项 id/顺序）、
// `:2205-2256`（textSelectMenuConfig JSON：`{id, enabled, showState}` 列表，
// 空配置=全部一级，未知新项追加）与 `TextSelectMenuConfigSheet.kt`
// 的三组（一级/折叠/隐藏）。
//
// 批4c 未实现后端项（AI 净化/改写、插入 BGM）保留 id/配置但默认不渲染；
// PROCESS_TEXT 第三方项本批不做。`menu_mark` 映射现有高亮能力，
// `menu_edit` 映射编辑内容 helper。
//
// 编写：全栈工程师（批4c） ｜ 2026-11-04
import 'dart:convert';

import 'package:flutter/material.dart';

abstract final class SelectionMenuIds {
  static const copy = 'menu_copy';
  static const share = 'menu_share_str';
  static const browser = 'menu_browser';
  static const aloud = 'menu_aloud';
  static const bookmark = 'menu_bookmark';
  static const mark = 'menu_mark';
  static const dict = 'menu_dict';
  static const replace = 'menu_replace';
  static const edit = 'menu_edit';
  static const aiClean = 'menu_ai_clean';
  static const aiRewrite = 'menu_ai_rewrite';
  static const search = 'menu_search_content';
  static const insertBgmBefore = 'menu_insert_bgm_before';
  static const insertBgmAfter = 'menu_insert_bgm_after';

  /// 参考内置顺序（空配置默认全一级）
  static const List<String> all = [
    copy,
    share,
    browser,
    aloud,
    bookmark,
    mark,
    dict,
    replace,
    edit,
    aiClean,
    aiRewrite,
    search,
    insertBgmBefore,
    insertBgmAfter,
  ];

  /// 批4c 已实现/可渲染项（其余默认不渲染）
  static const Set<String> implemented = {
    copy,
    share,
    browser,
    aloud,
    bookmark,
    mark,
    dict,
    replace,
    edit,
    search,
  };

  /// 参考文案（menu_mark 沿用现有「高亮」能力命名；其余对齐 zh-CN）
  static const Map<String, String> labels = {
    copy: '复制',
    share: '分享',
    browser: '浏览器',
    aloud: '朗读',
    bookmark: '书签',
    mark: '高亮',
    dict: '字典',
    replace: '替换',
    edit: '编辑',
    aiClean: 'AI 净化',
    aiRewrite: 'AI 改写',
    search: '全文搜索',
    insertBgmBefore: '插入背景音乐（前）',
    insertBgmAfter: '插入背景音乐（后）',
  };

  static const Map<String, IconData> icons = {
    copy: Icons.copy_outlined,
    share: Icons.share_outlined,
    browser: Icons.open_in_browser_outlined,
    aloud: Icons.record_voice_over_outlined,
    bookmark: Icons.bookmark_border,
    mark: Icons.highlight_outlined,
    dict: Icons.menu_book_outlined,
    replace: Icons.swap_horiz,
    edit: Icons.edit_outlined,
    aiClean: Icons.auto_awesome_outlined,
    aiRewrite: Icons.edit_note_outlined,
    search: Icons.search,
    insertBgmBefore: Icons.music_note_outlined,
    insertBgmAfter: Icons.music_note_outlined,
  };
}

class SelectionMenuItemDef {
  final String id;
  final String label;
  final IconData icon;
  final bool implemented;

  const SelectionMenuItemDef({
    required this.id,
    required this.label,
    required this.icon,
    required this.implemented,
  });
}

final List<SelectionMenuItemDef> kSelectionMenuItems = [
  for (final id in SelectionMenuIds.all)
    SelectionMenuItemDef(
      id: id,
      label: SelectionMenuIds.labels[id]!,
      icon: SelectionMenuIds.icons[id]!,
      implemented: SelectionMenuIds.implemented.contains(id),
    ),
];

SelectionMenuItemDef? selectionMenuDefById(String id) {
  for (final def in kSelectionMenuItems) {
    if (def.id == id) return def;
  }
  return null;
}

/// 单条配置：showState 0 一级 / 1 折叠 / 2 隐藏
class SelectionMenuConfigItem {
  final String id;
  final int showState;

  const SelectionMenuConfigItem({required this.id, this.showState = 0});

  bool get enabled => showState == 0;

  SelectionMenuConfigItem copyWith({int? showState}) =>
      SelectionMenuConfigItem(id: id, showState: showState ?? this.showState);

  Map<String, Object> toJson() => {
    'id': id,
    'enabled': enabled,
    'showState': showState,
  };
}

/// 解析后的视图分区（仅已实现项）
class SelectionMenuView {
  final List<SelectionMenuItemDef> primary;
  final List<SelectionMenuItemDef> collapsed;
  final List<SelectionMenuItemDef> hidden;
  final List<SelectionMenuItemDef> active;

  const SelectionMenuView({
    required this.primary,
    required this.collapsed,
    required this.hidden,
    required this.active,
  });
}

/// 选择菜单配置（有序；未知 id 保留在 [items] 中但不渲染）
class SelectionMenuConfig {
  final List<SelectionMenuConfigItem> items;

  SelectionMenuConfig(this.items);

  static SelectionMenuConfig defaults() => SelectionMenuConfig([
    for (final id in SelectionMenuIds.all) SelectionMenuConfigItem(id: id),
  ]);

  /// 宽松解析 showState：Gson 可把 `"1"` 转为 Int，这里同样兼容字符串
  static int? _parseShowState(Object? raw) {
    if (raw is num) return raw.toInt().clamp(0, 2);
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null) return parsed.clamp(0, 2);
    }
    return null;
  }

  /// 宽松解析 enabled：兼容 `"false"` / `"0"` 等历史字符串写法
  static bool? _parseEnabled(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      switch (raw.trim().toLowerCase()) {
        case 'true':
        case '1':
          return true;
        case 'false':
        case '0':
          return false;
      }
    }
    return null;
  }

  /// 空/非法回落默认；去重保序；缺失内置项按参考顺序补齐
  static SelectionMenuConfig decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return defaults();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return defaults();
      final out = <SelectionMenuConfigItem>[];
      final seen = <String>{};
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final id = entry['id'];
        if (id is! String || id.trim().isEmpty) continue;
        if (!seen.add(id)) continue;
        // 宽松兼容：showState 优先，缺失时用 enabled=false 表示折叠
        final state =
            _parseShowState(entry['showState']) ??
            (_parseEnabled(entry['enabled']) == false ? 1 : 0);
        out.add(SelectionMenuConfigItem(id: id, showState: state));
      }
      for (final id in SelectionMenuIds.all) {
        if (!seen.contains(id)) out.add(SelectionMenuConfigItem(id: id));
      }
      return SelectionMenuConfig(out);
    } catch (_) {
      return defaults();
    }
  }

  String encode() => jsonEncode([for (final item in items) item.toJson()]);

  static String normalize(String? raw) => decode(raw).encode();

  SelectionMenuView get view {
    final primary = <SelectionMenuItemDef>[];
    final collapsed = <SelectionMenuItemDef>[];
    final hidden = <SelectionMenuItemDef>[];
    final active = <SelectionMenuItemDef>[];
    for (final item in items) {
      final def = selectionMenuDefById(item.id);
      if (def == null || !def.implemented) continue;
      switch (item.showState) {
        case 0:
          primary.add(def);
          active.add(def);
        case 1:
          collapsed.add(def);
          active.add(def);
        case 2:
          hidden.add(def);
      }
    }
    return SelectionMenuView(
      primary: primary,
      collapsed: collapsed,
      hidden: hidden,
      active: active,
    );
  }

  SelectionMenuConfigItem? itemFor(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  int stateOf(String id) => itemFor(id)?.showState ?? 0;

  SelectionMenuConfig moveToState(String id, int state) {
    final clamped = state.clamp(0, 2);
    return SelectionMenuConfig([
      for (final item in items)
        item.id == id ? item.copyWith(showState: clamped) : item,
    ]);
  }

  /// 将 [id] 移动到同 state 的 [targetId] 位置（组内拖拽/上下移）
  SelectionMenuConfig moveWithinGroup(String id, String targetId) {
    final from = items.indexWhere((e) => e.id == id);
    final to = items.indexWhere((e) => e.id == targetId);
    if (from < 0 || to < 0 || from == to) return this;
    final list = [...items];
    final moved = list.removeAt(from);
    list.insert(to, moved);
    return SelectionMenuConfig(list);
  }

  SelectionMenuConfig moveBy(String id, int delta) {
    final item = itemFor(id);
    if (item == null) return this;
    final group = [
      for (final e in items)
        if (e.showState == item.showState &&
            (selectionMenuDefById(e.id)?.implemented ?? false))
          e,
    ];
    final index = group.indexWhere((e) => e.id == id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= group.length) return this;
    return moveWithinGroup(id, group[target].id);
  }
}
