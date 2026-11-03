// [批1a | 2026-10-31] 独立「阅读设置」页行为测试（非仅渲染）— 全栈工程师
//
// 覆盖：
// 1. 三组渲染 + 行数（屏幕 10 / 页面控制 14 / 其他 4；[批1b-1] 屏幕组增
//    「保持亮屏」「亮度条模式」，亮度条位置行仅模式=竖排时渲染；
//    [批1b-2a] 页面控制组增「按键长按翻页」；[批1b-2b] 增「点击图片方式」）
// 2. 页面默认值与 ReaderAdvancedConfig.load() 一致（空存储）
// 3. 改值生效：开关切换 → save 落盘 → 共享 provider 推送
// 4. 下拉/滑块/步进行改值生效（含值域钳制）
// 5. 返回后状态保持（再次进入读取同一持久化值）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/read_config_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: const ReadConfigScreen(),
        // 路由表注册断言：readConfig 路由可解析（入口一致性）
        routes: <String, WidgetBuilder>{
          AppRoutes.readConfig: (_) => const ReadConfigScreen(),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 放大测试视口到 800x2400（页面 23 行一次渲染，便于整体断言；
/// 测试结束由 teardown 还原）
void useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('阅读设置页：结构与默认值', () {
    testWidgets('三组标题与行数齐备（屏幕10/页面控制14/其他4）', (tester) async {
      useTallViewport(tester);
      await _pump(tester);

      expect(find.text('阅读设置'), findsOneWidget);
      expect(find.text('屏幕'), findsOneWidget);
      expect(find.text('页面控制'), findsOneWidget);
      expect(find.text('其他'), findsOneWidget);

      // 屏幕组 10 行（[批1b-1] +保持亮屏 +亮度条模式；位置行默认模式 0 不渲染）
      expect(find.text('屏幕方向'), findsOneWidget);
      expect(find.text('保持亮屏'), findsOneWidget);
      expect(find.text('隐藏状态栏'), findsOneWidget);
      expect(find.text('隐藏导航栏'), findsOneWidget);
      expect(find.text('填充刘海区域'), findsOneWidget);
      expect(find.text('扩展到刘海'), findsOneWidget);
      expect(find.text('亮度条模式'), findsOneWidget);
      expect(find.text('亮度条位置'), findsNothing,
          reason: '默认模式 0=不显示时位置行不渲染（对齐参考版条件渲染）');
      expect(find.text('平板/横屏双页'), findsOneWidget);
      expect(find.text('进度条行为'), findsOneWidget);

      // 页面控制组 14 行（随滚动分批可见；[批1b-2a] +按键长按翻页；
      // [批1b-2b] +点击图片方式）
      expect(find.text('使用自定义中文分行'), findsOneWidget);
      expect(find.text('文字两端对齐'), findsOneWidget);
      expect(find.text('段首标点悬挂'), findsOneWidget);
      expect(find.text('边缘点击阈值'), findsOneWidget);
      expect(find.text('点击区域设置'), findsOneWidget);
      expect(find.text('滑动翻页阈值'), findsOneWidget);
      expect(find.text('鼠标滚轮翻页'), findsOneWidget);
      expect(find.text('音量键翻页'), findsOneWidget);
      expect(find.text('朗读时音量键翻页'), findsOneWidget);
      expect(find.text('按键长按翻页'), findsOneWidget);
      expect(find.text('禁用滚动点击动画'), findsOneWidget);
      expect(find.text('点击图片方式'), findsOneWidget);
      expect(find.text('自动换源'), findsOneWidget);
      expect(find.text('长按选择文本'), findsOneWidget);
      expect(find.text('展示顶部工具栏附加区域'), findsOneWidget);

      // 其他组 4 行（[批1b-3] +无目录时每章字数）
      expect(find.text('翻页成功振动'), findsOneWidget);
      expect(find.text('选词振动'), findsOneWidget);
      expect(find.text('禁用返回键'), findsOneWidget);
      expect(find.text('无目录时每章字数'), findsOneWidget);
    });

    testWidgets('页面默认值与 ReaderAdvancedConfig.load() 一致', (tester) async {
      useTallViewport(tester);
      final expected = await ReaderAdvancedConfig.load();
      await _pump(tester);

      // 从行的 widget 取值：SettingSwitchRow.value
      bool rowValue(String title) => tester
          .widgetList<SettingSwitchRow>(find.byType(SettingSwitchRow))
          .firstWhere((r) => r.title == title)
          .value;

      expect(rowValue('隐藏状态栏'), expected.hideStatusBar, reason: '默认 false');
      expect(rowValue('隐藏导航栏'), expected.hideNavigationBar);
      expect(rowValue('填充刘海区域'), expected.paddingDisplayCutouts);
      expect(rowValue('扩展到刘海'), expected.readBodyToLh, reason: '默认 true');
      expect(rowValue('鼠标滚轮翻页'), expected.mouseWheelPage, reason: '默认 true');
      expect(rowValue('音量键翻页'), expected.volumeKeyPage, reason: '默认 true');
      expect(rowValue('朗读时音量键翻页'), expected.volumeKeyPageOnPlay,
          reason: '默认 false（原版口径）');
      expect(rowValue('按键长按翻页'), expected.keyPageOnLongPress,
          reason: '默认 false（原版 AppConfig / pref_config_read.xml）');
      expect(rowValue('自动换源'), expected.autoChangeSource, reason: '默认 true');
      expect(rowValue('长按选择文本'), expected.selectText, reason: '默认 true');
      expect(rowValue('展示顶部工具栏附加区域'), expected.showReadTitleAddition,
          reason: '默认 true');
      expect(rowValue('翻页成功振动'), expected.sliderVibrator, reason: '默认 false');
      expect(rowValue('选词振动'), expected.selectVibrator, reason: '默认 false');
      expect(rowValue('禁用返回键'), expected.disableReturnKey, reason: '默认 false');

      // 下拉默认值（泛型行用 is 判定匹配全部实例化后转回具体类型）
      final dropdowns = tester
          .widgetList(find.byWidgetPredicate(
            (w) => w is SettingDropdownRow,
          ))
          .whereType<SettingDropdownRow>()
          .toList();
      // [批1b-1] 屏幕组下拉 +2（保持亮屏 / 亮度条模式）
      // [批1b-2b] 页面控制组 +1（点击图片方式）
      expect(dropdowns, hasLength(6));
      final orientationRow = dropdowns.firstWhere((d) => d.title == '屏幕方向');
      expect(orientationRow.value, expected.screenOrientation, reason: '默认 0');
      final keepLightRow = dropdowns.firstWhere((d) => d.title == '保持亮屏');
      expect(keepLightRow.value, expected.keepLight, reason: '默认 0（系统策略）');
      final brightnessModeRow =
          dropdowns.firstWhere((d) => d.title == '亮度条模式');
      expect(brightnessModeRow.value, expected.readBrightnessMode,
          reason: "默认 '0'（参考版 ReadSettings）");
      final doubleRow = dropdowns.firstWhere((d) => d.title == '平板/横屏双页');
      expect(doubleRow.value, expected.doubleHorizontalPage, reason: '默认 0');
      final progressRow = dropdowns.firstWhere((d) => d.title == '进度条行为');
      expect(progressRow.value, expected.progressBarBehavior, reason: "默认 'page'");
      final clickImgRow = dropdowns.firstWhere((d) => d.title == '点击图片方式');
      expect(clickImgRow.value, expected.clickImgWay,
          reason: "默认 '2'=兼容旧版（参考版口径）");
      expect(clickImgRow.options.keys, ['0', '1', '2', '3', '4'],
          reason: '五档对齐原版 click_image_way_value');

      // 步进/滑块默认值
      final steppers = tester
          .widgetList<SettingStepperRow>(find.byType(SettingStepperRow))
          .toList();
      expect(steppers.single.value, expected.pageTouchClick, reason: '默认 0');
      final sliders = tester
          .widgetList<SettingSliderRow>(find.byType(SettingSliderRow))
          .toList();
      // [批1b-3] 其他组 +1 滑块（无目录时每章字数）
      expect(sliders, hasLength(2));
      final slopRow =
          sliders.firstWhere((s) => s.title == '滑动翻页阈值');
      expect(slopRow.value, expected.pageTouchSlop, reason: '默认 0');
      final maxLenRow =
          sliders.firstWhere((s) => s.title == '无目录时每章字数');
      expect(maxLenRow.value, expected.maxLengthWithNoToc, reason: '默认 3000');
      expect(maxLenRow.min, 3000, reason: '对齐参考版 valueRange 下限');
      expect(maxLenRow.max, 100000, reason: '对齐参考版 valueRange 上限');
    });

    testWidgets('[批1b-1] keepLight/亮度条两行已入页且消费接线', (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      // 1b-1 起 keepLight 平台通道接通、亮度条三档接线消费，两行转正
      expect(find.text('保持亮屏'), findsOneWidget);
      expect(find.text('亮度条模式'), findsOneWidget);
    });
  });

  group('阅读设置页：改值生效', () {
    testWidgets('开关切换 → 持久化 + 共享 provider 推送', (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ReadConfigScreen)));

      // 关 → 开：禁用返回键
      await tester.tap(find.text('禁用返回键'));
      await tester.pumpAndSettle();

      // 共享 provider 收到推送
      expect(container.read(readerAdvConfigProvider)?.disableReturnKey, isTrue);
      // 落盘可读回
      final saved = await ReaderAdvancedConfig.load();
      expect(saved.disableReturnKey, isTrue);

      // 反向：长按选择文本 默认开 → 关
      await tester.tap(find.text('长按选择文本'));
      await tester.pumpAndSettle();
      expect(container.read(readerAdvConfigProvider)?.selectText, isFalse);
      expect((await ReaderAdvancedConfig.load()).selectText, isFalse);
    });

    testWidgets('[批1b-2a] 按键长按翻页开关 → 持久化 + 共享 provider 推送',
        (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(ReadConfigScreen)));

      // 默认 false → 开
      expect(container.read(readerAdvConfigProvider)?.keyPageOnLongPress,
          isFalse);
      await tester.tap(find.text('按键长按翻页'));
      await tester.pumpAndSettle();

      expect(
        container.read(readerAdvConfigProvider)?.keyPageOnLongPress,
        isTrue,
        reason: '改值即推送共享 provider（阅读器即时生效）',
      );
      expect((await ReaderAdvancedConfig.load()).keyPageOnLongPress, isTrue,
          reason: 'save 落盘可读回');

      // 再点回 false
      await tester.tap(find.text('按键长按翻页'));
      await tester.pumpAndSettle();
      expect(
        container.read(readerAdvConfigProvider)?.keyPageOnLongPress,
        isFalse,
      );
      expect(
        (await ReaderAdvancedConfig.load()).keyPageOnLongPress,
        isFalse,
      );
    });

    testWidgets('下拉选择 → 持久化生效（屏幕方向 1=竖屏）', (tester) async {
      await _pump(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ReadConfigScreen)));

      // 点行弹 SimpleDialog（可达性兜底路径）
      await tester.tap(find.text('屏幕方向'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('竖屏'));
      await tester.pumpAndSettle();

      expect(container.read(readerAdvConfigProvider)?.screenOrientation, 1);
      expect((await ReaderAdvancedConfig.load()).screenOrientation, 1);
    });

    testWidgets('进度条行为下拉 → 持久化生效（chapter）', (tester) async {
      // [批1b-1] 屏幕组 +2 行后默认视口放不下，放大视口保证行可见可点
      useTallViewport(tester);
      await _pump(tester);
      await tester.tap(find.text('进度条行为'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整章节位置'));
      await tester.pumpAndSettle();

      expect((await ReaderAdvancedConfig.load()).progressBarBehavior, 'chapter');
    });

    testWidgets('[批1b-2b] 点击图片方式下拉 → 持久化 + 共享 provider 推送',
        (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(ReadConfigScreen)));

      // 默认 "2" → 选 "4"=双击生效
      expect(container.read(readerAdvConfigProvider)?.clickImgWay, '2');
      await tester.tap(find.text('点击图片方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('双击生效'));
      await tester.pumpAndSettle();

      expect(container.read(readerAdvConfigProvider)?.clickImgWay, '4',
          reason: '改值即推送共享 provider（阅读器即时生效）');
      expect((await ReaderAdvancedConfig.load()).clickImgWay, '4',
          reason: 'save 落盘可读回');

      // 选回默认 "0"=默认行为
      await tester.tap(find.text('点击图片方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('默认行为'));
      await tester.pumpAndSettle();
      expect(container.read(readerAdvConfigProvider)?.clickImgWay, '0');
      expect((await ReaderAdvancedConfig.load()).clickImgWay, '0');
    });

    testWidgets('步进行 +/- 钳制在值域内（边缘点击阈值 0..399）', (tester) async {
      useTallViewport(tester);
      await _pump(tester);

      // +10 × 2 → 20
      await tester.tap(find.byTooltip('增加'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('增加'));
      await tester.pumpAndSettle();
      expect(find.text('20'), findsOneWidget);
      expect((await ReaderAdvancedConfig.load()).pageTouchClick, 20);

      // −10 × 3 → 0（到下界按钮禁用，不再减）
      await tester.tap(find.byTooltip('减少'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('减少'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('减少'));
      await tester.pumpAndSettle();
      final decBtn = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('减少'),
          matching: find.byType(IconButton),
        ).first,
      );
      expect(
        decBtn.onPressed,
        isNull,
        reason: '到下界 0 后减少按钮禁用',
      );
    });

    testWidgets('滑块拖动 → 持久化生效（滑动翻页阈值）', (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ReadConfigScreen)));

      // [批1b-3] 页面现有两个滑块行，取「滑动翻页阈值」行内的 Slider
      final slopSliderFinder = find.descendant(
        of: find.widgetWithText(Column, '滑动翻页阈值'),
        matching: find.byType(Slider),
      );
      final slider = tester.widget<Slider>(slopSliderFinder);
      expect(slider.min, 0.0);
      expect(slider.max, 1000.0);

      // 拖到最右 → 1000
      final sliderCenter = tester.getCenter(slopSliderFinder);
      await tester.dragFrom(sliderCenter, const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(container.read(readerAdvConfigProvider)?.pageTouchSlop, 1000);
      expect((await ReaderAdvancedConfig.load()).pageTouchSlop, 1000);
    });

    testWidgets('[批1b-3] 无目录时每章字数滑块 → 持久化 + Rust config 真源同步',
        (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ReadConfigScreen)));

      final maxLenSliderFinder = find.descendant(
        of: find.widgetWithText(Column, '无目录时每章字数'),
        matching: find.byType(Slider),
      );
      final slider = tester.widget<Slider>(maxLenSliderFinder);
      expect(slider.min, 3000.0);
      expect(slider.max, 100000.0);

      // 拖到最右 → 100000
      final sliderCenter = tester.getCenter(maxLenSliderFinder);
      await tester.dragFrom(sliderCenter, const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(container.read(readerAdvConfigProvider)?.maxLengthWithNoToc,
          100000);
      expect(
        (await ReaderAdvancedConfig.load()).maxLengthWithNoToc,
        100000,
      );
      // Rust 真源（caches config:maxLengthWithNoToc）的联动语义由
      // _updateMaxLengthWithNoToc 经 bookApiProvider.setConfig 落库，
      // 真实链路由 FFI 层用例（local_txt_no_rule_length_split_follows_config）
      // 覆盖——widget 测试无 Rust 运行时，仅锁定 UI 持久化面。
    });

    testWidgets('滑块拖动中只预览不落盘，松手才提交一次（审查回修 P2-2）',
        (tester) async {
      useTallViewport(tester);
      await _pump(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ReadConfigScreen)));

      // [批1b-3] 取「滑动翻页阈值」行内的 Slider（页面现有两个滑块行）
      final slopSliderFinder = find.descendant(
        of: find.widgetWithText(Column, '滑动翻页阈值'),
        matching: find.byType(Slider),
      );
      final sliderCenter = tester.getCenter(slopSliderFinder);
      // 拖动到中段（手势未松手）
      final gesture = await tester.startGesture(sliderCenter);
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      // 拖动中：持久值未变（仍 0），页面显示本地预览值
      expect(container.read(readerAdvConfigProvider)?.pageTouchSlop, 0,
          reason: '拖动中不得写盘/推送（逐帧 save 回修点）');
      expect((await ReaderAdvancedConfig.load()).pageTouchSlop, 0);

      // 松手提交
      await gesture.up();
      await tester.pumpAndSettle();

      final committed = container.read(readerAdvConfigProvider)?.pageTouchSlop;
      expect(committed, greaterThan(0), reason: '松手后提交最终值');
      expect((await ReaderAdvancedConfig.load()).pageTouchSlop, committed);
      // 预览值复位：行数值显示回到已提交值
      final row = tester
          .widgetList<SettingSliderRow>(find.byType(SettingSliderRow))
          .firstWhere((r) => r.title == '滑动翻页阈值');
      expect(row.value, committed);
    });

    testWidgets('往返幂等：改值后 load()==save 的值；重进页面回显', (tester) async {
      useTallViewport(tester);
      await _pump(tester);

      await tester.tap(find.text('选词振动'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用自定义中文分行'));
      await tester.pumpAndSettle();

      final once = await ReaderAdvancedConfig.load();
      expect(once.selectVibrator, isTrue);
      expect(once.useZhLayout, isTrue);

      // 重进页面：回显持久化值（_load 读取）
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: Scaffold(body: SizedBox()))),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: const ReadConfigScreen(),
            routes: <String, WidgetBuilder>{
              AppRoutes.readConfig: (_) => const ReadConfigScreen(),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      bool rowValue(String title) => tester
          .widgetList<SettingSwitchRow>(find.byType(SettingSwitchRow))
          .firstWhere((r) => r.title == title)
          .value;
      expect(rowValue('选词振动'), isTrue);
      expect(rowValue('使用自定义中文分行'), isTrue);
    });
  });
}
