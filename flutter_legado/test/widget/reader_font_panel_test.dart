/// Tt 行内字体面板（阅读界面弹层「全局」页 Tt 小卡展开）测试
///
/// [C3 形态对齐 | full-stack-engineer + UI] 登记项 C3：Tt 入口由「跳转
/// 整页字体管理」改为弹层内行内面板（对齐参考版形态）。本文件覆盖：
/// ① Sheet 内 Tt 点按展开/收起行内面板与面板控件清单；
/// ② 面板直测：字重/首行缩进持久化、简繁转换走 BookApi（Mock）并回调
///    正文重载、选择字体跳转字体管理路由（AppRoutes.fonts，链路不丢失）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/font_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/reader_settings_sheet.dart';

void main() {
  group('阅读界面弹层 · Tt 行内字体面板', () {
    testWidgets('Tt 点按展开行内面板，再点收起', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            // 镜像真实壳层：DraggableScrollableSheet + SingleChildScrollView
            home: Scaffold(
              body: SingleChildScrollView(child: ReaderSettingsSheet()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 折叠态：仅 Tt 小卡，无面板控件
      expect(find.text('Tt'), findsOneWidget);
      expect(find.text('选择字体'), findsNothing);

      // 点按 Tt → 行内面板展开（对齐参考版行内形态的控件清单）
      await tester.tap(find.text('Tt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('字体'), findsOneWidget);
      expect(find.text('选择字体'), findsOneWidget);
      expect(find.text('正文字距'), findsOneWidget);
      expect(find.text('首行缩进'), findsOneWidget);
      expect(find.text('标题字体'), findsOneWidget);
      // [C3 核实结论] 「斜体」不在原版（开源版无斜体配置字段，为参考版自有
      // 增强），按重构红线不放入面板 —— 断言其不存在，防后续误加
      expect(find.text('斜体'), findsNothing);
      expect(find.text('字重'), findsOneWidget);
      expect(find.text('简繁转换'), findsOneWidget);

      // 再点 Tt → 面板收起
      await tester.tap(find.text('Tt'));
      await tester.pump();
      expect(find.text('选择字体'), findsNothing);
    });

    testWidgets('面板直测：字重/首行缩进持久化 + 简繁转换 + 选择字体跳转',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockBookApi();
      var reloadCount = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(mockApi)],
          child: MaterialApp(
            // 「选择字体」跳转 AppRoutes.fonts：以桩路由承接，验证链路不丢失
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.fonts) {
                return MaterialPageRoute<void>(
                  builder: (_) => const FontScreen(),
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => ReaderFontPanel(
                  config: ReaderAdvancedConfig(),
                  // 模拟主 Sheet _commitAdv：变更经 save() 持久化
                  onChanged: (cfg) => unawaited(cfg.save()),
                  onReload: () => reloadCount++,
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 面板控件清单
      expect(find.text('选择字体'), findsOneWidget);
      expect(find.text('正文字距'), findsOneWidget);
      expect(find.text('简繁转换'), findsOneWidget);

      // ① 字重切「粗」→ 持久化 textBold=1（既有字段链路）
      await tester.tap(find.text('粗').last);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('textBold'), 1);

      // ② 首行缩进 → 选「三字符」→ 持久化 paragraph_indent_chars=3
      // （save() 同时写日夜桶键 reader_layout_day_* 与旧键 reader_adv_*）
      await tester.tap(find.text('首行缩进').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('三字符'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(prefs.getInt('reader_layout_day_paragraph_indent_chars'), 3);
      expect(prefs.getInt('reader_adv_paragraph_indent_chars'), 3);

      // ③ 简繁转换「简→繁」→ 经 BookApi 持久化并回调正文重载
      final before = await mockApi.getChineseConvertType();
      expect(before, 0);
      await tester.tap(find.text('简→繁').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(await mockApi.getChineseConvertType(), 2);
      expect(reloadCount, 1);

      // ④ 「选择字体」跳转字体管理路由（AppRoutes.fonts → FontScreen）
      await tester.tap(find.text('选择字体').last);
      await tester.pumpAndSettle();
      expect(find.text('字体管理'), findsWidgets);
    });
  });
}
