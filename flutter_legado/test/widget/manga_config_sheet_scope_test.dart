// [漫画设置作用域 2026-10-01] MangaConfigSheet「跟随全局 / 本书」作用域控件
//
// 语义（用户裁决 + 参考版取证）：
// - 仅翻页模式（scrollMode）与条漫侧边留白（sidePadding）具备「本书覆盖 +
//   全局回退」；长按存图/自动速度/九区点击动作保持全局；
// - 无当前书 → 只显示全局路径（不渲染作用域控件）；
// - 选「本书」= 物化书级覆盖；选「跟随全局」= 清除覆盖（回调传 null，
//   不以写入默认值冒充清除）并回显全局值；
// - 面板不新增「长按设为全局默认」按钮（原版/参考版均无该入口）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/manga_config.dart';
import 'package:flutter_legado/src/widgets/manga/manga_config_sheet.dart';

Widget _buildSheet({
  int scrollMode = 4,
  bool hasCurrentBook = false,
  int? bookScrollMode,
  int? globalScrollMode,
  ValueChanged<int>? onScrollModeChanged,
  ValueChanged<int?>? onBookScrollModeChanged,
  int sidePadding = 0,
  int? bookSidePadding,
  int? globalSidePadding,
  ValueChanged<int>? onSidePaddingChanged,
  ValueChanged<int?>? onBookSidePaddingChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MangaConfigSheet(
        colorFilter: MangaColorFilterConfig(),
        footer: MangaFooterConfig(),
        enableEInk: false,
        enableGray: false,
        eInkThreshold: 128,
        scrollMode: scrollMode,
        onColorFilterChanged: (_) {},
        onFooterChanged: (_) {},
        onEnableEInkChanged: (_) {},
        onEnableGrayChanged: (_) {},
        onEInkThresholdChanged: (_) {},
        onScrollModeChanged: onScrollModeChanged ?? (_) {},
        sidePadding: sidePadding,
        onSidePaddingChanged: onSidePaddingChanged,
        hasCurrentBook: hasCurrentBook,
        bookScrollMode: bookScrollMode,
        globalScrollMode: globalScrollMode,
        onBookScrollModeChanged: onBookScrollModeChanged,
        bookSidePadding: bookSidePadding,
        globalSidePadding: globalSidePadding,
        onBookSidePaddingChanged: onBookSidePaddingChanged,
      ),
    ),
  );
}

/// 作用域药丸当前底色（选中 = primaryContainer，未选 = 透明）
Color? _pillColor(WidgetTester tester, String key) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (container.decoration as BoxDecoration?)?.color;
}

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(MangaConfigSheet))).colorScheme;

/// 定位「侧边留白」滑杆（标题与滑杆同卡片 Column；色彩滤镜区另有 5 条滑杆）
Finder _sidePaddingSlider() {
  final tile = find
      .ancestor(of: find.text('侧边留白'), matching: find.byType(Column))
      .first;
  return find.descendant(of: tile, matching: find.byType(Slider));
}

void main() {
  group('[漫画设置作用域] 无当前书：仅全局路径', () {
    testWidgets('不渲染作用域药丸；模式/留白变更只走全局回调', (tester) async {
      final globalModeCalls = <int>[];
      final globalPadCalls = <int>[];
      final bookModeCalls = <int?>[];
      final bookPadCalls = <int?>[];
      await tester.pumpWidget(_buildSheet(
        hasCurrentBook: false,
        scrollMode: 4,
        onScrollModeChanged: globalModeCalls.add,
        onBookScrollModeChanged: bookModeCalls.add,
        onSidePaddingChanged: globalPadCalls.add,
        onBookSidePaddingChanged: bookPadCalls.add,
      ));

      // 无书即使上游接线书级回调，也不渲染作用域控件（只显示全局）
      expect(find.byKey(const ValueKey('mangaScrollMode-scopeGlobal')),
          findsNothing);
      expect(find.byKey(const ValueKey('mangaScrollMode-scopeBook')),
          findsNothing);
      expect(find.byKey(const ValueKey('mangaSidePadding-scopeGlobal')),
          findsNothing);
      expect(find.byKey(const ValueKey('mangaSidePadding-scopeBook')),
          findsNothing);
      expect(find.text('跟随全局'), findsNothing);
      expect(find.text('本书'), findsNothing);

      // 拖动侧边留白 → 仅全局回调（须在切到单页式前：条漫滑杆仅条漫模式渲染）
      expect(_sidePaddingSlider(), findsOneWidget);
      await tester.drag(_sidePaddingSlider(), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(globalPadCalls, isNotEmpty);
      expect(globalPadCalls.last, greaterThan(0));
      expect(bookPadCalls, isEmpty);

      // 切换模式 → 仅全局 setConfig 回调
      await tester.tap(find.text('单页式（从右到左）'));
      await tester.pump();
      expect(globalModeCalls, [2]);
      expect(bookModeCalls, isEmpty);
    });

    testWidgets('面板不新增「长按设为全局默认」按钮', (tester) async {
      await tester.pumpWidget(_buildSheet(hasCurrentBook: false));
      expect(find.textContaining('长按设为全局'), findsNothing);
    });
  });

  group('[漫画设置作用域] 有当前书 + 书级未覆盖（跟随全局）', () {
    testWidgets('默认选中「跟随全局」；点「本书」以当前有效值物化覆盖',
        (tester) async {
      final bookModeCalls = <int?>[];
      await tester.pumpWidget(_buildSheet(
        hasCurrentBook: true,
        scrollMode: 2,
        globalScrollMode: 2,
        bookScrollMode: null,
        onBookScrollModeChanged: bookModeCalls.add,
      ));

      final scheme = _scheme(tester);
      expect(find.byKey(const ValueKey('mangaScrollMode-scopeGlobal')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('mangaScrollMode-scopeBook')),
          findsOneWidget);
      expect(
        _pillColor(tester, 'mangaScrollMode-scopeGlobal'),
        scheme.primaryContainer,
        reason: '无书级覆盖时应选中「跟随全局」',
      );
      expect(_pillColor(tester, 'mangaScrollMode-scopeBook'),
          isNot(scheme.primaryContainer));

      await tester.tap(find.byKey(const ValueKey('mangaScrollMode-scopeBook')));
      await tester.pump();
      // 物化覆盖：以当前有效值（2）写入书级
      expect(bookModeCalls, [2]);
      expect(
        _pillColor(tester, 'mangaScrollMode-scopeBook'),
        scheme.primaryContainer,
        reason: '切到「本书」后应选中书级药丸',
      );
    });

    testWidgets('侧边留白「本书」物化覆盖（当前 0 值）', (tester) async {
      final bookPadCalls = <int?>[];
      await tester.pumpWidget(_buildSheet(
        hasCurrentBook: true,
        scrollMode: 4,
        sidePadding: 0,
        globalSidePadding: 0,
        bookSidePadding: null,
        onSidePaddingChanged: (_) {},
        onBookSidePaddingChanged: bookPadCalls.add,
      ));

      await tester.tap(
          find.byKey(const ValueKey('mangaSidePadding-scopeBook')));
      await tester.pump();
      expect(bookPadCalls, [0]);

      // 「本书」作用下拖动滑杆 → 书级回调（不再走全局）
      final globalPadCalls = <int>[];
      // 该实例未接全局回调（null），滑块仍可拖动并只写书级
      await tester.drag(_sidePaddingSlider(), const Offset(600, 0));
      await tester.pumpAndSettle();
      // 拖动会连续派发 onChanged（多次回调），断言末值与回调序列首项
      expect(bookPadCalls.length, greaterThanOrEqualTo(2));
      expect(bookPadCalls.first, 0, reason: '「本书」物化覆盖先以当前值回调');
      expect(bookPadCalls.last, greaterThan(0));
      expect(globalPadCalls, isEmpty);
    });
  });

  group('[漫画设置作用域] 有当前书 + 书级已覆盖', () {
    testWidgets('初始选中「本书」；点「跟随全局」清除覆盖并回显全局值',
        (tester) async {
      final globalModeCalls = <int>[];
      final bookModeCalls = <int?>[];
      await tester.pumpWidget(_buildSheet(
        hasCurrentBook: true,
        // 有效值 = 书级 3（上游按优先级传入）
        scrollMode: 3,
        bookScrollMode: 3,
        globalScrollMode: 1,
        onScrollModeChanged: globalModeCalls.add,
        onBookScrollModeChanged: bookModeCalls.add,
      ));

      final scheme = _scheme(tester);
      expect(_pillColor(tester, 'mangaScrollMode-scopeBook'),
          scheme.primaryContainer);

      // 清除覆盖：回调传 null（不是写入默认值）
      await tester.tap(
          find.byKey(const ValueKey('mangaScrollMode-scopeGlobal')));
      await tester.pump();
      expect(bookModeCalls, [null]);
      expect(_pillColor(tester, 'mangaScrollMode-scopeGlobal'),
          scheme.primaryContainer);

      // 回显全局值后，面板内改模式只走全局回调
      await tester.tap(find.text('单页式（从上到下）'));
      await tester.pump();
      expect(globalModeCalls, [3]);
      expect(bookModeCalls, [null], reason: '清除后不得再写书级');

      // 清除操作本身不触发全局写入（不写入默认值冒充清除）
      expect(globalModeCalls.length, 1);
    });

    testWidgets('侧边留白：点「跟随全局」清除覆盖并回显全局百分比',
        (tester) async {
      final bookPadCalls = <int?>[];
      final globalPadCalls = <int>[];
      await tester.pumpWidget(_buildSheet(
        hasCurrentBook: true,
        scrollMode: 4,
        // 有效值 = 书级 20
        sidePadding: 20,
        bookSidePadding: 20,
        globalSidePadding: 5,
        onSidePaddingChanged: globalPadCalls.add,
        onBookSidePaddingChanged: bookPadCalls.add,
      ));

      expect(find.text('20%'), findsOneWidget, reason: '初始显示书级覆盖值');

      await tester.tap(
          find.byKey(const ValueKey('mangaSidePadding-scopeGlobal')));
      await tester.pump();
      expect(bookPadCalls, [null]);
      expect(find.text('5%'), findsOneWidget, reason: '清除后回显全局值');
      expect(globalPadCalls, isEmpty, reason: '清除覆盖不写全局键');
    });

    testWidgets('上游未接书级写回调时不渲染作用域控件', (tester) async {
      await tester.pumpWidget(_buildSheet(
        hasCurrentBook: true,
        scrollMode: 4,
        // hasCurrentBook=true 但 onBookScrollModeChanged / onBookSidePaddingChanged 缺省 null
        sidePadding: 10,
        onSidePaddingChanged: (_) {},
      ));

      expect(find.text('跟随全局'), findsNothing);
      expect(find.text('本书'), findsNothing);
    });
  });
}
