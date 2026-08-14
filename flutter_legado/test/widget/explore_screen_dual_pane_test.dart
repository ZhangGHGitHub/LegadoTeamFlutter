// ExploreScreen 平板双栏响应式 widget 测试
//
// 验证 UI_RESTRUCTURE_PLAN.md §6.2 发现页响应式策略：
// - expanded/large（≥840dp）：左侧书源列表 + 右侧内容占位双栏
// - compact（<840dp）：单栏列表（保持安卓原版行为，无右栏占位）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  final sources = [
    const BookSource(
      bookSourceUrl: 'https://a.com',
      bookSourceName: '发现源A',
      exploreUrl: '分类::https://a.com/explore',
    ),
  ];

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
  });

  Widget buildApp() {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
      child: const MaterialApp(home: ExploreScreen()),
    );
  }

  testWidgets('宽屏（≥840dp）渲染左源右内容双栏 + 右栏占位提示', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 左栏书源已渲染
    expect(find.text('发现源A'), findsOneWidget);
    // 右栏占位提示
    expect(find.text('选择发现分类'), findsOneWidget);
  });

  testWidgets('窄屏（<840dp）单栏布局，无右栏占位提示', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 书源列表正常渲染
    expect(find.text('发现源A'), findsOneWidget);
    // 无右栏占位提示（单栏）
    expect(find.text('选择发现分类'), findsNothing);
  });

  testWidgets('长按书源行弹出完整菜单（编辑/置顶/登录/搜索/刷新/删除）', (tester) async {
    // 带 loginUrl 的书源 → 显示「登录」菜单项（对齐原版 hasLoginUrl 条件）
    final loginSource = const BookSource(
      bookSourceUrl: 'https://login.com',
      bookSourceName: '登录源B',
      exploreUrl: '分类::https://login.com/explore',
      loginUrl: 'https://login.com/login',
    );
    when(() => mockApi.getBookSources())
        .thenAnswer((_) async => [...sources, loginSource]);

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('登录源B'));
    await tester.pumpAndSettle();

    // 六项菜单齐全（发现页修复 R2，对齐原版 ExploreAdapter.showMenu）
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('无登录配置的书源菜单不显示登录项（hasLoginUrl 条件）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('发现源A'));
    await tester.pumpAndSettle();

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });
}
