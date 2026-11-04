// [批4c] 选择菜单配置模型测试
//
// 编写：全栈工程师（批4c） ｜ 2026-11-04
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/selection_menu_config.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('空配置默认全 14 顺序 state0', () {
    final config = SelectionMenuConfig.decode('');
    expect(config.items, hasLength(14));
    expect(
      config.items.map((e) => e.id).toList(),
      SelectionMenuIds.all,
    );
    expect(config.items.every((e) => e.showState == 0), isTrue);
  });

  test('JSON 往返与参考字段（id/enabled/showState）', () {
    final config = SelectionMenuConfig.defaults()
        .moveToState(SelectionMenuIds.copy, 1)
        .moveToState(SelectionMenuIds.share, 2);
    final json = config.encode();
    final first = (jsonDecode(json) as List).first as Map;
    expect(first['id'], SelectionMenuIds.copy);
    expect(first['enabled'], isFalse);
    expect(first['showState'], 1);
    expect(SelectionMenuConfig.decode(json).encode(), json);
  });

  test('enabled 兼容：无 showState 时 false→折叠、true→一级', () {
    final config = SelectionMenuConfig.decode(
      jsonEncode([
        {'id': SelectionMenuIds.copy, 'enabled': false},
        {'id': SelectionMenuIds.share, 'enabled': true},
      ]),
    );
    expect(config.stateOf(SelectionMenuIds.copy), 1);
    expect(config.stateOf(SelectionMenuIds.share), 0);
    // 缺失内置项追加为一级
    expect(config.items, hasLength(14));
    expect(config.stateOf(SelectionMenuIds.mark), 0);
  });

  test('非法 JSON/空列表回落默认；未知 id 保留；重复去重', () {
    expect(
      SelectionMenuConfig.decode('bad-json').items.map((e) => e.id).toList(),
      SelectionMenuIds.all,
    );
    expect(
      SelectionMenuConfig.decode('[]').items.map((e) => e.id).toList(),
      SelectionMenuIds.all,
    );

    final config = SelectionMenuConfig.decode(
      jsonEncode([
        {'id': 'menu_unknown', 'showState': 1},
        {'id': SelectionMenuIds.copy, 'showState': 0},
        {'id': SelectionMenuIds.copy, 'showState': 2},
      ]),
    );
    expect(config.itemFor('menu_unknown')?.showState, 1);
    expect(config.items.where((e) => e.id == SelectionMenuIds.copy), hasLength(1));
    expect(config.stateOf(SelectionMenuIds.copy), 0, reason: '首次出现优先');
  });

  test('state 分区：0 一级 / 1 折叠 / 2 隐藏；未实现 id 不渲染', () {
    final config = SelectionMenuConfig.defaults()
        .moveToState(SelectionMenuIds.copy, 0)
        .moveToState(SelectionMenuIds.share, 1)
        .moveToState(SelectionMenuIds.browser, 2)
        .moveToState(SelectionMenuIds.aiClean, 0)
        .moveToState(SelectionMenuIds.insertBgmBefore, 1);
    final view = config.view;
    expect(view.primary.map((e) => e.id), contains(SelectionMenuIds.copy));
    expect(view.collapsed.map((e) => e.id), contains(SelectionMenuIds.share));
    expect(view.hidden.map((e) => e.id), contains(SelectionMenuIds.browser));
    expect(view.active.map((e) => e.id), isNot(contains(SelectionMenuIds.browser)));
    expect(view.active.map((e) => e.id), isNot(contains(SelectionMenuIds.aiClean)));
    expect(
      view.active.map((e) => e.id),
      isNot(contains(SelectionMenuIds.insertBgmBefore)),
    );
  });

  test('组内移动/上下移只作用于已实现项', () {
    final config = SelectionMenuConfig.defaults()
        .moveToState(SelectionMenuIds.copy, 0)
        .moveToState(SelectionMenuIds.share, 0)
        .moveToState(SelectionMenuIds.browser, 0);
    final moved = config.moveWithinGroup(
      SelectionMenuIds.copy,
      SelectionMenuIds.browser,
    );
    final primary = moved.view.primary.map((e) => e.id).toList();
    expect(primary.indexOf(SelectionMenuIds.copy), greaterThan(primary.indexOf(SelectionMenuIds.share)));

    final down = config.moveBy(SelectionMenuIds.copy, 1);
    expect(
      down.view.primary.map((e) => e.id).take(2),
      [SelectionMenuIds.share, SelectionMenuIds.copy],
    );
    // 越界忽略
    expect(config.moveBy(SelectionMenuIds.copy, -1).encode(), config.encode());
  });

  test('ReaderAdvancedConfig 保存 normalize、开关与忽略阅读配置', () async {
    final cfg = await ReaderAdvancedConfig.load();
    cfg.textSelectMenuConfig = jsonEncode([
      {'id': SelectionMenuIds.copy, 'showState': 2},
      {'id': SelectionMenuIds.copy, 'showState': 0},
      {'id': 'menu_unknown'},
    ]);
    cfg.expandTextMenu = true;
    cfg.showSelectMenuIcon = false;
    await cfg.save();

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(PrefKeys.textSelectMenuConfig)!;
    expect(saved, cfg.textSelectMenuConfig);
    final decoded = SelectionMenuConfig.decode(saved);
    expect(decoded.stateOf(SelectionMenuIds.copy), 2);
    expect(decoded.itemFor('menu_unknown'), isNotNull);

    final loaded = await ReaderAdvancedConfig.load();
    expect(loaded.expandTextMenu, isTrue);
    expect(loaded.showSelectMenuIcon, isFalse);

    for (final key in [
      PrefKeys.textSelectMenuConfig,
      PrefKeys.expandTextMenu,
      PrefKeys.showSelectMenuIcon,
    ]) {
      expect(RestoreIgnorePrefs.readPrefKeys, contains(key));
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(key, const {'readConfig': true}),
        isFalse,
      );
    }
  });
}
