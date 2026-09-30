// [深色主题 Batch A-1] 漫画设置底栏 scheme 化回归测试
//
// 背景：MangaConfigSheet 原硬编码 iOS 浅色调色板（#F2F2F7 底 / 白卡 /
// #1C1C1E 主文字 / #8E8E93 次文字 / #E5E5EA 分隔线 / #C7C7CC 把手），
// 暗色主题下无法跟随。Batch A-1 全部改为 Theme scheme 槽位，本测试：
// 1. 暗色主题下无异常渲染，且各颜色取自 dark scheme（旧硬编码色不再出现）；
// 2. 亮色主题下颜色取自 light scheme（亮色外观由 scheme 值锚定，防回归）。
//
// [P4-3 M3 修4] 面板重组断言（新增）：
// 3. 标题「漫画阅读设置」（M2 旧称「漫画设置」）；
// 4. 阅读模式 5 按钮组（单页式 ×3 + 条漫 ×2，选中 primaryContainer 高亮）
//    + 模式条件行互斥（单页式「页面适配」下拉 / 条漫「侧边留白」滑杆
//    0..45%）+ 页脚快捷行（左对齐/居中/隐藏页脚 三按钮 + 页脚预览条）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/manga_config.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/widgets/manga/manga_config_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildSheet(
    ThemeMode mode, {
    // [P4-3 M3 修4] 可选参数（缺省 null 保持既有调用方行为不变）
    int sidePadding = 0,
    ValueChanged<int>? onSidePaddingChanged,
    ValueChanged<int>? onPageScaleTypeChanged,
    ValueChanged<MangaFooterConfig>? onFooterChanged,
    ValueChanged<int>? onScrollModeChanged,
  }) {
    return MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      home: Scaffold(
        body: MangaConfigSheet(
          // MangaColorFilterConfig 字段可变态，构造器非 const
          colorFilter: MangaColorFilterConfig(r: 12, l: 40),
          footer: MangaFooterConfig(),
          enableEInk: false,
          enableGray: false,
          eInkThreshold: 128,
          // [P4-3 E1] 翻页模式（缺省条漫 4）
          scrollMode: 4,
          onColorFilterChanged: (_) {},
          // [P4-3 M3 修4] 页脚快捷行测试需要捕获回调（缺省 no-op）
          onFooterChanged: onFooterChanged ?? (_) {},
          onEnableEInkChanged: (_) {},
          onEnableGrayChanged: (_) {},
          onEInkThresholdChanged: (_) {},
          // [P4-3 M3 修4] 翻页模式变更（缺省 no-op，修4 测试传入捕获）
          onScrollModeChanged: onScrollModeChanged ?? (_) {},
          // [P4-3 M3 修4] 侧边留白 / 页面适配（传回调才渲染对应条件行）
          sidePadding: sidePadding,
          onSidePaddingChanged: onSidePaddingChanged,
          onPageScaleTypeChanged: onPageScaleTypeChanged,
        ),
      ),
    );
  }

  /// 收集 sheet 内所有带显式 BoxDecoration.color 的容器颜色集合
  Set<Color> containerColors(WidgetTester tester) {
    final containers = tester.widgetList<Container>(
      find.descendant(of: find.byType(MangaConfigSheet), matching: find.byType(Container)),
    );
    return containers
        .map((c) => (c.decoration as BoxDecoration?)?.color)
        .whereType<Color>()
        .toSet();
  }

  void assertColorsFromScheme(WidgetTester tester, ColorScheme scheme) {
    // 标题 / 滑杆标题 → onSurface
    // [P4-3 M3 修4] 标题对齐参考版「漫画阅读设置」（M2 旧称「漫画设置」）
    expect(
      tester.widget<Text>(find.text('漫画阅读设置')).style!.color,
      scheme.onSurface,
    );
    expect(tester.widget<Text>(find.text('亮度')).style!.color, scheme.onSurface);

    // 分组标题 / 开关副标题 / 滑杆数值 → onSurfaceVariant
    expect(tester.widget<Text>(find.text('显示效果')).style!.color, scheme.onSurfaceVariant);
    expect(
      tester.widget<Text>(find.text('灰度近似；阈值已持久化')).style!.color,
      scheme.onSurfaceVariant,
    );
    expect(tester.widget<Text>(find.text('40')).style!.color, scheme.onSurfaceVariant);

    // 容器底色：根背景 = surfaceContainerHighest / 卡片 = surface
    final colors = containerColors(tester);
    expect(colors, contains(scheme.surfaceContainerHighest),
        reason: 'sheet 根背景应取自 surfaceContainerHighest');
    expect(colors, contains(scheme.surface),
        reason: '卡片底色应取自 surface');

    // 旧 iOS 硬编码浅色调色板不应再出现
    expect(colors, isNot(contains(const Color(0xFFF2F2F7))),
        reason: '旧硬编码背景 #F2F2F7 不应残留');
    expect(colors, isNot(contains(Colors.white)),
        reason: '旧硬编码白卡不应残留');
    expect(colors, isNot(contains(const Color(0xFFC7C7CC))),
        reason: '旧硬编码把手 #C7C7CC 不应残留');

    // 把手（36×5）→ outlineVariant
    final containers = tester.widgetList<Container>(
      find.descendant(of: find.byType(MangaConfigSheet), matching: find.byType(Container)),
    );
    final handleConstraints = BoxConstraints.tight(const Size(36, 5));
    final handle = containers.singleWhere((c) => c.constraints == handleConstraints);
    expect((handle.decoration as BoxDecoration).color, scheme.outlineVariant,
        reason: '拖动把手应取自 outlineVariant');

    // 分隔线 → outlineVariant
    for (final d in tester.widgetList<Divider>(find.byType(Divider))) {
      expect(d.color, scheme.outlineVariant, reason: '分隔线应取自 outlineVariant');
    }
  }

  testWidgets('暗色主题：无异常渲染且颜色取自 dark scheme', (tester) async {
    await tester.pumpWidget(buildSheet(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    assertColorsFromScheme(tester, AppTheme.dark.colorScheme);
  });

  testWidgets('亮色主题：无异常渲染且颜色取自 light scheme（亮色回归锚定）',
      (tester) async {
    await tester.pumpWidget(buildSheet(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    assertColorsFromScheme(tester, AppTheme.light.colorScheme);
  });

  // ---------------------------------------------------------------------------
  // [P4-3 M3 修4] 面板重组（对齐用户截图 / 参考版 MangaSettingsPanel）
  // ---------------------------------------------------------------------------
  group('[P4-3 M3 修4] 面板重组', () {
    testWidgets(
        '阅读模式 5 按钮组 + 模式条件行互斥（条漫侧边留白 / 单页式页面适配）',
        (tester) async {
      var capturedMode = -1;
      var capturedSide = -1;
      var sideCalls = 0;
      await tester.pumpWidget(buildSheet(
        ThemeMode.dark,
        sidePadding: 15,
        onSidePaddingChanged: (v) {
          capturedSide = v;
          sideCalls++;
        },
        onPageScaleTypeChanged: (_) {},
        onScrollModeChanged: (m) => capturedMode = m,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 5 按钮组：单页式 ×3 + 条漫 ×2，按值 1..5 顺序全量渲染
      for (final label in const [
        '单页式（从左到右）',
        '单页式（从右到左）',
        '单页式（从上到下）',
        '条漫',
        '条漫（页面有空隙）',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '按钮组缺 $label');
      }

      // 条漫态（scrollMode 4）：侧边留白滑杆存在（min 0 / max 45，label 15%），
      // 页面适配下拉不渲染（isPaged = false）
      expect(find.text('侧边留白'), findsOneWidget);
      expect(find.text('15%'), findsOneWidget);
      final sideSlider = tester
          .widgetList<Slider>(find.byType(Slider))
          .singleWhere((s) => s.min == 0 && s.max == 45);
      expect(sideSlider.value, 15);
      expect(find.text('页面适配'), findsNothing);

      // 切到单页式（3）：侧边留白滑杆消失，页面适配下拉出现
      await tester.tap(find.text('单页式（从上到下）'));
      await tester.pumpAndSettle();
      expect(capturedMode, 3);
      expect(find.text('侧边留白'), findsNothing);
      expect(find.text('页面适配'), findsOneWidget);

      // 切到条漫（有空隙，5）：侧边留白滑杆重新出现
      await tester.tap(find.text('条漫（页面有空隙）'));
      await tester.pumpAndSettle();
      expect(capturedMode, 5);
      expect(find.text('侧边留白'), findsOneWidget);

      // 滑杆拖动 → 四舍五入后持久化回调（15 → 30）
      await tester.drag(find.byType(Slider).at(0), const Offset(200, 0));
      await tester.pumpAndSettle();
      // 注：drag 终点值不确定，只断言回调被调用过且收敛在 0..45
      expect(sideCalls, greaterThan(0));
      expect(capturedSide, inInclusiveRange(0, 45));
    });

    testWidgets('页脚快捷行：左对齐/居中/隐藏页脚 三按钮 + 预览条',
        (tester) async {
      // sheet 内 setState 原地修改同一 _footer 实例后再回调，故在回调时
      // 快照 (orientation, hideFooter) 字段值
      final records = <(int, bool)>[];
      await tester.pumpWidget(buildSheet(
        ThemeMode.dark,
        onFooterChanged: (f) =>
            records.add((f.footerOrientation, f.hideFooter)),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 页脚设置区在列表底部（测试视口 800×600，sheet 内容超可视区，
      // ListView 懒构建未到达）→ 先滚到底再断言
      await tester.fling(find.byType(ListView), const Offset(0, -800), 2000);
      await tester.pumpAndSettle();

      // 三按钮 + 预览条（默认 MangaFooterConfig：hideFooter=false、左对齐、
      // 全字段未隐藏 → buildLabel 非空，含样例章名「第三话」）
      expect(find.text('左对齐'), findsOneWidget);
      expect(find.text('居中'), findsOneWidget);
      expect(find.text('隐藏页脚'), findsOneWidget);
      expect(find.textContaining('第三话'), findsOneWidget);

      // 点「居中」→ orientation=居中 且取消隐藏
      await tester.tap(find.text('居中'));
      await tester.pumpAndSettle();
      expect(records, [(MangaFooterConfig.alignCenter, false)]);
      // 预览条文字随对齐切换仍为同一样例（textAlign 随 orientation 变）
      final previewText =
          tester.widgetList<Text>(find.byType(Text)).firstWhere(
                (t) =>
                    t.data?.isNotEmpty == true &&
                    (t.textAlign ?? TextAlign.left) == TextAlign.center,
              );
      expect(previewText.data, contains('第三话'));

      // 点「隐藏页脚」→ hideFooter 置位，预览条改为「页脚已隐藏」占位
      await tester.tap(find.text('隐藏页脚'));
      await tester.pumpAndSettle();
      expect(records.last, (MangaFooterConfig.alignCenter, true));
      expect(find.text('页脚已隐藏'), findsOneWidget);
      expect(find.textContaining('第三话'), findsNothing);

      // 再点「隐藏页脚」→ 恢复显示（toggle 语义）
      await tester.tap(find.text('隐藏页脚'));
      await tester.pumpAndSettle();
      expect(records.last, (MangaFooterConfig.alignCenter, false));
      expect(find.textContaining('第三话'), findsOneWidget);

      // 点「左对齐」→ orientation 回左对齐且取消隐藏
      await tester.tap(find.text('左对齐'));
      await tester.pumpAndSettle();
      expect(records.last, (MangaFooterConfig.alignLeft, false));
    });
  });
}
