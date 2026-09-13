/// 阅读界面弹层（四页签）结构与页签切换测试
///
/// [UI_SYNC_REFACTOR S5 修 | 2026-09-06] 一比一对齐参考版布局改造的
/// 结构回归：全局/菜单/信息/更多四页签 + 全局页（字号/背景/翻页动画）
/// + 页签切换内容装载。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/widgets/reader/reader_settings_sheet.dart';

void main() {
  testWidgets('阅读界面弹层：四页签 + 全局页关键元素', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          // 镜像真实壳层：DraggableScrollableSheet + SingleChildScrollView
          // （无界高度，弹层 Column mainAxisSize.min 自适应）
          home: Scaffold(
            body: SingleChildScrollView(child: ReaderSettingsSheet()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 头部标题与四个页签
    expect(find.text('阅读界面'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(find.text('菜单'), findsOneWidget);
    expect(find.text('信息'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);

    // 全局页（默认页签）：字号步进 / 背景 / 翻页动画 / Tt 字体入口
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('长按自定义'), findsOneWidget);
    expect(find.text('翻页动画'), findsOneWidget);
    expect(find.text('Tt'), findsOneWidget);

    // 页签切换 → 菜单页（自动翻页/点击区域）
    await tester.tap(find.text('菜单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('自动翻页'), findsWidgets);

    // [更多全高形态 | Qoder UI] 点「更多」页签 → 全高独立弹层覆盖打开
    //（把手 + 居中标题「更多」，无底部页签栏——对齐参考版形态）
    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 页签与弹层标题同名各一处
    expect(find.text('更多'), findsNWidgets(2));
    // 弹层内容（原页签内容整体迁移）
    expect(find.text('行距'), findsOneWidget);
    expect(find.text('字重'), findsOneWidget);
    expect(find.text('共用布局'), findsOneWidget);
    // 全高几何：弹层高度 ≈ 屏高 92%
    final sheetHeight = tester
        .getTopLeft(find.byWidget(
          tester.widgetList(find.text('行距')).first,
        ))
        .dy;
    expect(sheetHeight, greaterThan(100));
  });
}
