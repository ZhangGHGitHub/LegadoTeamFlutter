// [设置批10a | 2026-11-04] AI 设置/翻译设置/实验室占位页测试 — 全栈工程师
//
// 用户裁决：参考版三入口先做「入口 + 页面壳」，明确暂未支持，不接功能。
// 本文件守护：
// 1. 三条路由经 AppRoutes.generateRoute 可构建（非首页兜底）；
// 2. 设置主页三入口可达、副题「暂未支持」，并可返回；
// 3. 占位页文案明确，且无输入框/开关/提交按钮等可用假象。
//
// — 全栈工程师 + UI ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_placeholder_screen.dart';

void main() {
  setUp(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
  });

  /// 三个占位路由的期望元数据
  final placeholders =
      <
        ({
          String route,
          String title,
          String emptyTitle,
          String description,
          IconData icon,
        })
      >[
        (
          route: AppRoutes.aiSettings,
          title: 'AI 设置',
          emptyTitle: 'AI 设置暂未支持',
          description: '待 Rust AI 能力接入后开放',
          icon: Symbols.auto_awesome_rounded,
        ),
        (
          route: AppRoutes.translationSettings,
          title: '翻译设置',
          emptyTitle: '翻译设置暂未支持',
          description: '待 Rust 翻译能力接入后开放',
          icon: Symbols.translate_rounded,
        ),
        (
          route: AppRoutes.labSettings,
          title: '实验室',
          emptyTitle: '实验室暂未支持',
          description: '待后续实验能力接入后开放',
          icon: Symbols.science_rounded,
        ),
      ];

  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 直达占位路由的 MaterialApp。
  ///
  /// [MaterialApp.initialRoute] 会先生成 '/' 根路由再推目标路由；home 用
  /// 空白占位（而非默认 HomeScreen），避免测试环境缺 ProviderScope 报错，
  /// 同时目标页仍处于可返回的 push 栈上（与真实深链语义一致）。
  Widget appForRoute(String route) => MaterialApp(
    // 循环内多次 pumpWidget：用路由名作 key 强制重建 Navigator，
    // 否则 MaterialApp 复用旧状态、initialRoute 变更不生效
    key: ValueKey('placeholder-app-$route'),
    home: const SizedBox.shrink(),
    onGenerateRoute: AppRoutes.generateRoute,
    initialRoute: route,
  );

  test('三条路由常量唯一且已注册（不落首页兜底）', () {
    final names = <String>{
      AppRoutes.aiSettings,
      AppRoutes.translationSettings,
      AppRoutes.labSettings,
    };
    expect(names.length, 3, reason: '三个路由名不得重复');
    for (final entry in placeholders) {
      expect(
        AppRoutes.routes.containsKey(entry.route),
        isTrue,
        reason: '${entry.route} 必须注册到 AppRoutes.routes',
      );
    }
  });

  testWidgets('generateRoute：三条占位路由可构建且文案明确', (tester) async {
    for (final entry in placeholders) {
      await tester.pumpWidget(appForRoute(entry.route));
      await tester.pumpAndSettle();

      expect(
        find.byType(SettingsPlaceholderScreen),
        findsOneWidget,
        reason: '${entry.route} 应构建占位页而非首页兜底',
      );
      expect(find.text(entry.title), findsOneWidget, reason: '顶栏标题');
      expect(find.text(entry.emptyTitle), findsOneWidget, reason: '暂未支持文案');
      expect(find.text(entry.description), findsOneWidget, reason: '说明文案');
      expect(find.byIcon(entry.icon), findsOneWidget, reason: '图标');
    }
  });

  testWidgets('设置主页三入口：副题暂未支持，导航与返回正常', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: AppRoutes.generateRoute,
        home: const SettingsHomeScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // 三入口同屏可见，且副题统一为「暂未支持」
    for (final entry in placeholders) {
      expect(find.text(entry.title), findsOneWidget);
    }
    expect(
      find.text('暂未支持'),
      findsNWidgets(3),
      reason: 'AI 设置/翻译设置/实验室副题均为「暂未支持」',
    );

    // 逐入口进入占位页并返回设置主页
    for (final entry in placeholders) {
      await tester.tap(find.text(entry.title));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPlaceholderScreen), findsOneWidget);
      expect(find.text(entry.emptyTitle), findsOneWidget);
      expect(find.text(entry.description), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        find.byType(SettingsHomeScreen),
        findsOneWidget,
        reason: '返回后应回到设置主页',
      );
      expect(find.text(entry.title), findsOneWidget);
    }
  });

  testWidgets('占位页无输入/开关/提交按钮（不制造可用假象）', (tester) async {
    for (final entry in placeholders) {
      await tester.pumpWidget(appForRoute(entry.route));
      await tester.pumpAndSettle();

      expect(
        find.byType(TextField),
        findsNothing,
        reason: '${entry.route} 无输入框',
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(Switch), findsNothing, reason: '${entry.route} 无开关');
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.byWidgetPredicate((w) => w is DropdownButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing, reason: '无提交按钮');
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      // 直达路径下 AppBar 仅一个返回按钮（Navigator 可 pop），无其它操作钮
      expect(
        find.byType(IconButton),
        findsOneWidget,
        reason: '仅顶栏返回按钮，无提交/执行类操作',
      );
      expect(
        find.descendant(
          of: find.byType(IconButton),
          matching: find.byIcon(Symbols.arrow_back_rounded),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('三个占位页各自保留独立标题，不串页', (tester) async {
    for (final entry in placeholders) {
      await tester.pumpWidget(
        MaterialApp(
          home: switch (entry.route) {
            AppRoutes.aiSettings => const SettingsPlaceholderScreen.ai(),
            AppRoutes.translationSettings =>
              const SettingsPlaceholderScreen.translation(),
            _ => const SettingsPlaceholderScreen.lab(),
          },
        ),
      );
      await tester.pumpAndSettle();

      for (final other in placeholders.where((e) => e.route != entry.route)) {
        expect(
          find.text(other.emptyTitle),
          findsNothing,
          reason: '${entry.route} 不得出现 ${other.route} 的文案',
        );
        expect(find.text(other.description), findsNothing);
      }
    }
  });
}
