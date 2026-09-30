// AppScaffold 页壳测试（GLOBALCOMP B4）
//
// 覆盖四层证据：
// 1) 壳基本结构：topBar/body/bottomBar/FAB 各就各位、几何贴边正确；
// 2) 背景契约：backgroundColor 默认 null → 由 ThemeData.scaffoldBackgroundColor
//    供给（背景图透明壁纸策略 P1-8 依赖此项），显式传入时直通；
// 3) 同构等价：与裸 Scaffold 相同组合逐元素几何一致（迁移点行为等价证据），
//    且壳对未提供参数零改写（resizeToAvoidBottomInset 等保持 Scaffold 默认）；
// 4) 迁移屏等价：HomeScreen 经壳渲染后，壳内 Scaffold 参数与迁移前逐项一致
//    （appBar==null / bottomNavigationBar!=null / backgroundColor==null /
//    无 FAB），且结构（PageView + 五页签底栏）与迁移前一致。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/widgets/app_scaffold.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  testWidgets('壳基本结构：topBar/body/bottomBar/FAB 各就各位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppScaffold(
          topBar: AppBar(title: const Text('壳标题')),
          body: const Center(child: Text('壳主体')),
          bottomBar: NavigationBar(
            selectedIndex: 0,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_rounded), label: '甲'),
              NavigationDestination(icon: Icon(Icons.person_rounded), label: '乙'),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () {},
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );

    // 壳下仍是标准 Scaffold（既有 find.byType(Scaffold) 断言全兼容）
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('壳标题'), findsOneWidget);
    expect(find.text('壳主体'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);

    final scaffold = tester.getRect(find.byType(Scaffold));
    final appBar = tester.getRect(find.byType(AppBar));
    final navBar = tester.getRect(find.byType(NavigationBar));
    // 顶栏贴顶、底栏贴底（测试画布无系统 inset）
    expect(appBar.top, scaffold.top);
    expect(navBar.bottom, scaffold.bottom);
    // FAB 默认 endFloat：位于底栏之上、屏内右侧
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(fab.right, lessThanOrEqualTo(scaffold.right));
    expect(fab.bottom, lessThanOrEqualTo(navBar.top));
  });

  testWidgets('背景契约：默认跟随主题（不硬编码），显式传入直通', (tester) async {
    const themeBg = Color(0xFF123456);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(scaffoldBackgroundColor: themeBg),
        home: AppScaffold(body: const SizedBox.expand()),
      ),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    // 不写死背景色：保留「设置背景图 → scaffoldBackgroundColor 透明露壁纸」
    expect(scaffold.backgroundColor, isNull);
    final materials = tester.widgetList<Material>(
      find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(Material),
      ),
    );
    expect(materials.any((m) => m.color == themeBg), isTrue);

    const override = Color(0xFFABCDEF);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScaffold(backgroundColor: override, body: const SizedBox.expand()),
      ),
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      override,
    );
  });

  testWidgets('同构等价：与裸 Scaffold 相同组合逐元素几何一致', (tester) async {
    Widget compose(bool shell) {
      final bar = AppBar(title: const Text('等价标题'));
      final body = Container(
        key: const ValueKey('body'),
        color: const Color(0x22000000),
      );
      const bottom = SizedBox(
        key: ValueKey('bottom'),
        height: 48,
        child: ColoredBox(color: Colors.blue),
      );
      final fab = FloatingActionButton(
        key: const ValueKey('fab'),
        onPressed: () {},
        child: const Icon(Icons.add),
      );
      if (shell) {
        return AppScaffold(
          topBar: bar,
          body: body,
          bottomBar: bottom,
          floatingActionButton: fab,
        );
      }
      return Scaffold(
        appBar: bar,
        body: body,
        bottomNavigationBar: bottom,
        floatingActionButton: fab,
      );
    }

    Map<String, Rect> capture() => {
          'scaffold': tester.getRect(find.byType(Scaffold)),
          'bar': tester.getRect(find.byType(AppBar)),
          'body': tester.getRect(find.byKey(const ValueKey('body'))),
          'bottom': tester.getRect(find.byKey(const ValueKey('bottom'))),
          'fab': tester.getRect(find.byKey(const ValueKey('fab'))),
        };

    await tester.pumpWidget(MaterialApp(home: compose(false)));
    final raw = capture();
    await tester.pumpWidget(MaterialApp(home: compose(true)));
    final shell = capture();

    expect(shell, raw);

    // 参数零改写：未提供项保持 Scaffold 默认（resizeToAvoidBottomInset 为
    // null 即「未设置」，Scaffold 内部按 true 处理；位置为 null 即默认位）
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, isNull);
    expect(scaffold.resizeToAvoidBottomInset, isNull);
    expect(scaffold.floatingActionButtonLocation, isNull);
  });

  testWidgets('迁移屏 HomeScreen：经壳渲染且结构与迁移前逐参数一致', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
    when(() => mockApi.getReadRecords()).thenAnswer((_) async => []);
    when(() => mockApi.readRecordDailyList(any())).thenAnswer((_) async => []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 迁移点 1：页壳已换用 AppScaffold（PageView 预载相邻 Tab，书架页亦是
    // 壳，故树中可出现多个；取外层=HomeScreen 自身页壳）
    expect(find.byType(AppScaffold), findsWidgets);
    final homeShell = find.byType(AppScaffold).first;

    // 迁移点 2：壳内 Scaffold 参数与迁移前逐项一致（5 页签容器）
    final scaffold = tester.widget<Scaffold>(
      find
          .descendant(of: homeShell, matching: find.byType(Scaffold))
          .first,
    );
    expect(scaffold.appBar, isNull); // 迁移前无 appBar
    expect(scaffold.bottomNavigationBar, isNotNull); // 底栏三形态装配
    expect(scaffold.backgroundColor, isNull); // 跟随主题/壁纸策略
    expect(scaffold.floatingActionButton, isNull);
    expect(scaffold.resizeToAvoidBottomInset, isNull); // 零改写

    // 迁移点 3：结构与迁移前一致（PageView 滑动切页 + 五页签底栏）
    expect(
      find.descendant(
        of: find.byType(HomeScreen),
        matching: find.byType(PageView),
      ),
      findsWidgets,
    );
    expect(find.byType(NavigationBar), findsWidgets);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
  });
}
