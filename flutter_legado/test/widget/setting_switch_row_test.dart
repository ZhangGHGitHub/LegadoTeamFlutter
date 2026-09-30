import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

/// M3 设置开关行（`SettingSwitchRow`，对齐参考版 `SwitchSettingItem`）测试
///
/// 覆盖：标题/副标题渲染、整行点击即切换（参考版非 Miuix 分支
/// `onClick = onCheckedChange(!checked)`）、开关直点、禁用态（行不可点 +
/// ListTile.enabled=false + 开关灰置）、icon/leading 前导、无 Chevron、
/// 语义合并（MergeSemantics，同 SwitchListTile）、dense/contentPadding 透传、
/// enableItemDivider 打开时的行底 80dp 分隔线。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('渲染标题/副标题，开关取 value', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingSwitchRow(
          title: '自动刷新',
          subtitle: '打开软件时自动更新书籍',
          value: true,
          onChanged: _noop,
        ),
      ),
    );

    expect(find.text('自动刷新'), findsOneWidget);
    expect(find.text('打开软件时自动更新书籍'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('未传副标题时不渲染副标题', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingSwitchRow(
          title: '显示订阅',
          value: false,
          onChanged: _noop,
        ),
      ),
    );

    expect(find.text('显示订阅'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('整行点击即切换（标题处点击传 !value）', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '自动刷新',
          value: false,
          onChanged: calls.add,
        ),
      ),
    );

    await tester.tap(find.text('自动刷新'));
    await tester.pump();

    expect(calls, [true]);
  });

  testWidgets('直点开关触发 onChanged（传状态机新值）', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '自动刷新',
          value: true,
          onChanged: calls.add,
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(calls, [false]);
  });

  testWidgets('onChanged 为 null 时行禁用：不可点、ListTile 停用、开关灰置',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingSwitchRow(title: '同步书籍进度增强', value: false),
      ),
    );

    expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);

    // 禁用行点击不抛异常也不产生任何回调（无可点 InkWell 目标即静默）
    await tester.tap(find.text('同步书籍进度增强'), warnIfMissed: false);
    await tester.pump();
  });

  testWidgets('icon 渲染裸前导图标；leading 优先于 icon', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingSwitchRow(
          icon: Icons.alarm,
          title: '运行定时任务',
          value: false,
          onChanged: _noop,
        ),
      ),
    );
    expect(find.byIcon(Icons.alarm), findsOneWidget);

    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          icon: Icons.alarm,
          leading: const SizedBox(key: Key('busy'), width: 20, height: 20),
          title: 'MCP 服务',
          value: false,
          onChanged: _noop,
        ),
      ),
    );
    expect(find.byKey(const Key('busy')), findsOneWidget);
    expect(find.byIcon(Icons.alarm), findsNothing);
  });

  testWidgets('开关行不显示 Chevron', (tester) async {
    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '自动刷新',
          value: false,
          onChanged: _noop,
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('语义合并为单一开关节点（MergeSemantics 包住整行）', (tester) async {
    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '自动刷新',
          value: true,
          onChanged: _noop,
        ),
      ),
    );

    expect(
      find.ancestor(
        of: find.byType(IosListTile),
        matching: find.byType(MergeSemantics),
      ),
      findsOneWidget,
    );
    // 控件不参与焦点（同 SwitchListTile：ExcludeFocus 包 Switch）
    expect(
      find.ancestor(
        of: find.byType(Switch),
        matching: find.byType(ExcludeFocus),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dense/contentPadding 透传（WebDav 密排行形态）', (tester) async {
    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '同步书籍进度',
          subtitle: '在多设备间同步书籍阅读进度',
          value: true,
          onChanged: _noop,
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        ),
      ),
    );

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.dense, isTrue);
    expect(
      tile.contentPadding,
      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
    );
  });

  testWidgets('enableItemDivider 打开时行底出现 80dp 胶囊线', (tester) async {
    final before = uiSettingsListenable.value;
    addTearDown(() => uiSettingsListenable.value = before);

    // IosListTile 分隔线形态：80×1dp 圆角线（enableItemDivider 打开时）
    final pill = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.constraints?.maxWidth == 80 &&
          w.constraints?.maxHeight == 1,
    );

    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '自动刷新',
          value: false,
          onChanged: _noop,
        ),
      ),
    );
    expect(pill, findsNothing);

    uiSettingsListenable.value = before.copyWith(enableItemDivider: true);
    await tester.pumpWidget(
      wrap(
        SettingSwitchRow(
          title: '自动刷新',
          value: false,
          onChanged: _noop,
        ),
      ),
    );
    expect(pill, findsOneWidget);
  });
}

void _noop(bool _) {}
