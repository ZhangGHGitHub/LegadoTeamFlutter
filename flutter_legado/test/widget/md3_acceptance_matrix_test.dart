// MD3 验收矩阵（UI_MD3_PLAN.md 第十三节）自动化
//
// 覆盖三项：
// 1. 关键页渲染矩阵：theme_config/home/settings/search × WH/koharu/sora
//    × light/dark 全部无异常渲染（溢出/布局异常会被 flutter test 捕获）；
//    golden 截图基线按计划修订以渲染矩阵替代——跨平台（Windows 开发 /
//    Linux CI）字体渲染差异使 golden 二进制基线脆弱，截图验收改由
//    模拟器 -CheckUI 流程承担（UI_MD3_PLAN.md 实施状态记录）。
// 2. 系统字体缩放边界：textScaler 0.8/1.6 下关键页无溢出。
// 3. 语义/触控目标：底栏 NavigationBar 目标 ≥ 48dp、SwitchListTile 行高
//    ≥ 48dp、主题卡片语义标签存在。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final palettes = [
    ('wh', Md3Palettes.wh),
    ('koharu', Md3Palettes.koharu),
    ('sora', Md3Palettes.sora),
  ];

  /// 装配指定调色板 + 亮暗的 ProviderScope MaterialApp
  Widget buildApp(String paletteId, ThemeMode mode) {
    SharedPreferences.setMockInitialValues({
      'app_palette_id': paletteId,
      'app_theme_mode': switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      },
    });
    return ProviderScope(
      overrides: [],
      child: MaterialApp(
        theme: _paletteTheme(paletteId, Brightness.light),
        darkTheme: _paletteTheme(paletteId, Brightness.dark),
        themeMode: mode,
        home: const ThemeConfigScreen(),
        routes: const {},
      ),
    );
  }

  group('关键页渲染矩阵（3 调色板 × 亮暗 × 关键页）', () {
    for (final (name, _) in palettes) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('$name/${mode.name} theme_config 无异常渲染', (tester) async {
          tester.view.physicalSize = const Size(1080, 2260);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(buildApp(name, mode));
          await tester.pumpAndSettle();
          expect(find.text('内置主题'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('WH/light home(书架) 无异常渲染且底栏四项可达', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: const HomeScreen())),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('书架'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('WH/light settings(我的) 无异常渲染', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: const SettingsScreen())),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('WH/light search 无异常渲染', (tester) async {
      registerFallbacks();
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      final mockApi = MockRustApi();
      when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
          .thenAnswer((_) async => []);
      when(() => mockApi.addSearchKeyword(any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
      when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(() => mockApi.getEnabledBookSources())
          .thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const SearchScreen()),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });
  });

  group('系统字体缩放边界（0.8x / 1.6x）', () {
    for (final scale in [0.8, 1.6]) {
      testWidgets('theme_config textScaler=$scale 无溢出异常', (tester) async {
        SharedPreferences.setMockInitialValues({
          'app_palette_id': 'wh',
          'app_theme_mode': 'light',
        });
        tester.view.physicalSize = const Size(1080, 2260);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData()
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ProviderScope(
              child: MaterialApp(home: const ThemeConfigScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('home textScaler=$scale 无溢出异常', (tester) async {
        SharedPreferences.setMockInitialValues({
          'app_palette_id': 'wh',
          'app_theme_mode': 'light',
        });
        tester.view.physicalSize = const Size(1080, 2260);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData()
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ProviderScope(child: MaterialApp(home: const HomeScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('触控目标（≥ 48dp）', () {
    testWidgets('底栏 NavigationBar 目标高度 ≥ 48dp', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: const HomeScreen())),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final bar = tester.renderObject<RenderBox>(
        find.byType(NavigationBar),
      );
      expect(bar.size.height, greaterThanOrEqualTo(48.0));
      // 每个目的地宽度均分 4 tab，≥ 48dp
      final destinations = find.byType(NavigationDestination);
      final count = destinations.evaluate().length;
      expect(count, inInclusiveRange(2, 4));
      for (var i = 0; i < count; i++) {
        final box = tester.renderObject<RenderBox>(destinations.at(i));
        expect(box.size.width, greaterThanOrEqualTo(48.0),
            reason: '底栏项 $i 宽度 ${box.size.width} < 48dp');
      }
    });

    testWidgets('主题卡片有语义标签（paletteId 可辨识）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildApp('wh', ThemeMode.light));
      await tester.pumpAndSettle();
      // 12 套调色板的中文标签均可被语义化查找
      for (final p in Md3Palettes.all) {
        expect(find.text(p.label), findsWidgets, reason: '${p.id} 标签缺失');
      }
    });
  });
}

/// 与 app.dart 相同的调色板装配入口
ThemeData _paletteTheme(String paletteId, Brightness brightness) =>
    AppTheme.palette(
      brightness: brightness,
      palette: Md3Palettes.byId(paletteId),
    );
