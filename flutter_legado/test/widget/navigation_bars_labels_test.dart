// [复核 P2-3/P2-4/P2-7 | 2026-11-02] 导航组件标签档位/图标回退测试
//
// 覆盖：
// - 悬浮底栏 labeled / unlabeled / onlyShowSelected 三种标签渲染；
// - Rail 展开+labeled（显示文字）、折叠+labeled、展开+unlabeled（强制折叠、
//   不显示文字且隐藏展开钮）；
// - 图标缺文件回退内置 symbol；选中态优先用 selected 自定义图标。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/main_tab.dart';
import 'package:flutter_legado/src/services/nav_icon_store.dart';
import 'package:flutter_legado/src/widgets/navigation/app_navigation_bars.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final specs = [for (final tab in kDefaultMainTabOrder) mainTabNavSpec(tab)];

  Widget wrap(Widget child) => MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: Scaffold(body: child),
    ),
  );

  Widget floating({
    required NavigationDestinationLabelBehavior labelBehavior,
    int currentIndex = 0,
  }) => Align(
    alignment: Alignment.bottomCenter,
    child: AppFloatingBottomBar(
      specs: specs,
      currentIndex: currentIndex,
      activeSkin: '',
      onSelect: (_) {},
      useBlur: false,
      blurRadius: 0,
      blurAlpha: 0,
      labelBehavior: labelBehavior,
    ),
  );

  Widget rail({required bool extended, required bool showLabel}) => AppRailBar(
    specs: specs,
    currentIndex: 0,
    activeSkin: '',
    extended: extended,
    showLabel: showLabel,
    onSelect: (_) {},
    onToggleExtended: () {},
    onSearch: () {},
  );

  group('悬浮底栏标签', () {
    testWidgets('labeled：五项标签全部显示', (tester) async {
      await tester.pumpWidget(
        wrap(
          floating(
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          ),
        ),
      );
      await tester.pump();
      for (final spec in specs) {
        expect(find.text(spec.label), findsOneWidget);
      }
    });

    testWidgets('unlabeled：不渲染任何标签', (tester) async {
      await tester.pumpWidget(
        wrap(
          floating(
            labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          ),
        ),
      );
      await tester.pump();
      for (final spec in specs) {
        expect(find.text(spec.label), findsNothing);
      }
    });

    testWidgets('onlyShowSelected：仅当前选中项显示标签', (tester) async {
      await tester.pumpWidget(
        wrap(
          floating(
            labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
            currentIndex: 2,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('发现'), findsOneWidget);
      expect(find.text('首页'), findsNothing);
      expect(find.text('书架'), findsNothing);
      expect(find.text('订阅'), findsNothing);
      expect(find.text('我的'), findsNothing);
    });
  });

  group('Rail 标签', () {
    testWidgets('展开 + labeled：NavigationRail 展开且显示文字', (tester) async {
      await tester.pumpWidget(wrap(rail(extended: true, showLabel: true)));
      await tester.pump();
      final navRail = tester.widget<NavigationRail>(
        find.byType(NavigationRail),
      );
      expect(navRail.extended, isTrue);
      for (final spec in specs) {
        expect(find.text(spec.label), findsOneWidget);
      }
      expect(find.byTooltip('收起侧栏'), findsOneWidget);
    });

    testWidgets('折叠 + labeled：显示文字（labelType.all）', (tester) async {
      await tester.pumpWidget(wrap(rail(extended: false, showLabel: true)));
      await tester.pump();
      final navRail = tester.widget<NavigationRail>(
        find.byType(NavigationRail),
      );
      expect(navRail.extended, isFalse);
      expect(navRail.labelType, NavigationRailLabelType.all);
      for (final spec in specs) {
        expect(find.text(spec.label), findsOneWidget);
      }
      expect(find.byTooltip('展开侧栏'), findsOneWidget);
    });

    testWidgets('unlabeled：强制折叠、不显示文字且隐藏展开钮', (tester) async {
      await tester.pumpWidget(wrap(rail(extended: true, showLabel: false)));
      await tester.pump();
      final navRail = tester.widget<NavigationRail>(
        find.byType(NavigationRail),
      );
      expect(
        navRail.extended,
        isFalse,
        reason: 'Flutter extended 强制标签，unlabeled 时强制折叠',
      );
      expect(navRail.labelType, NavigationRailLabelType.none);
      // Flutter 为语义保留 label 子树（Visibility.maintain），因此不断言
      // Text 不存在；labelType=none + 折叠态即用户不可见文字。
      expect(find.byTooltip('展开侧栏'), findsNothing);
      expect(find.byTooltip('收起侧栏'), findsNothing);
    });
  });

  group('自定义图标回退/选中态', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('legado_nav_icon_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Future<File> writePng(String name) async {
      final file = File('${temp.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(_pngBytes);
      return file;
    }

    testWidgets('缺文件：回退内置 symbol，不渲染 Image', (tester) async {
      final missing = '${temp.path}${Platform.pathSeparator}missing.png';
      final spec = mainTabNavSpec(MainTab.home, customIconPath: missing);
      await tester.pumpWidget(
        wrap(
          Center(
            child: NavSpecIcon(spec: spec, selected: false, activeSkin: ''),
          ),
        ),
      );
      await tester.pump();
      expect(find.byIcon(spec.symbol), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    test('选中态优先 selected 自定义图标，否则回落未选中', () async {
      final normal = await writePng('normal.png');
      final selected = await writePng('selected.png');
      final spec = mainTabNavSpec(
        MainTab.home,
        customIconPath: normal.path,
        customSelectedIconPath: selected.path,
      );
      expect(NavIconStore.isUsableSync(normal.path), isTrue);
      expect(NavIconStore.isUsableSync(selected.path), isTrue);
      expect(navSpecIconPath(spec, selected: true), selected.path);
      expect(navSpecIconPath(spec, selected: false), normal.path);
    });

    test('选中态未配置时回落未选中自定义图标', () async {
      final normal = await writePng('normal-only.png');
      final spec = mainTabNavSpec(MainTab.home, customIconPath: normal.path);
      expect(navSpecIconPath(spec, selected: true), normal.path);
      expect(navSpecIconPath(spec, selected: false), normal.path);
    });

    test('两者都为空：路径为空→内置图标', () {
      final spec = mainTabNavSpec(MainTab.home);
      expect(navSpecIconPath(spec, selected: true), isEmpty);
      expect(navSpecIconPath(spec, selected: false), isEmpty);
    });
  });
}
