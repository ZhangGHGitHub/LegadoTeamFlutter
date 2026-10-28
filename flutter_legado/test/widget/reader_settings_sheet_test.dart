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

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/reader_settings_sheet.dart';

/// 测试专用 ReaderNotifier：固定初始状态 + 记录 updateFontSize 调用次数
///
/// 不调父类 build（其 `Future.microtask(_loadSettings)` 会用持久化值覆写
/// 初始状态）；updateFontSize 仍走父类实现（写 state + 落盘 + 推 FFI），
/// 以便同时断言「拖动中不写盘、结束后只提交一次」。
class _CountingReaderNotifier extends ReaderNotifier {
  _CountingReaderNotifier(this.initial);

  final ReaderState initial;
  final List<double> updates = [];

  @override
  ReaderState build() => initial;

  @override
  void updateFontSize(double size) {
    updates.add(size);
    super.updateFontSize(size);
  }
}

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

    // [批33 | 字号范围 5–50] 字号卡 = 滑块（5..50，45 档）+ 数值 + 加减
    final fontSlider = tester.widget<Slider>(find.byType(Slider));
    expect(fontSlider.min, 5.0);
    expect(fontSlider.max, 50.0);
    expect(fontSlider.divisions, 45);
    expect(find.text('20'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    expect(find.text('21'), findsOneWidget);

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

  /// [批33b | 字号滑块提交时机] 拖动中只做本地预览，松手才提交一次
  ///
  /// 缺陷背景：`onChanged` 直连 `notifier.updateFontSize`，拖动 45 档会逐帧
  /// 触发整章重排 + 盘写 + FFI 注入。修复后拖动过程仅更新本卡片预览值
  /// （数字/滑条），`onChangeEnd` 统一提交一次。
  testWidgets('字号滑块：拖动过程不提交，松手只提交一次', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final notifier =
        _CountingReaderNotifier(const ReaderState(fontSize: 20));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerNotifierProvider.overrideWith(() => notifier),
          bookApiProvider.overrideWithValue(MockBookApi()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ReaderSettingsSheet()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await tester.pump();
    // 向右侧拖动约 60px（跨多档）
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();

    // 拖动中：滑条值已变（本地预览），但 notifier 未被调用、未写盘
    final previewValue = tester.widget<Slider>(slider).value;
    expect(previewValue, isNot(20.0), reason: '拖动应实时预览');
    expect(notifier.updates, isEmpty, reason: '拖动中不得调用 updateFontSize');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getDouble('reader_font_size'),
      isNull,
      reason: '拖动中不得写 prefs',
    );
    expect(
      find.text(previewValue.round().toString()),
      findsOneWidget,
      reason: '数字显示应跟随预览值',
    );

    await gesture.up();
    await tester.pumpAndSettle();

    // 松手：恰好提交一次，值与预览一致并落盘
    expect(notifier.updates, hasLength(1), reason: '松手只提交一次');
    expect(notifier.updates.single, previewValue);
    expect(tester.widget<Slider>(slider).value, previewValue);
    expect(prefs.getDouble('reader_font_size'), previewValue);
  });

  /// [批33b | 窄屏与触控] 320dp 下字号卡不溢出，步进按钮触控区 ≥44dp
  ///
  /// 半宽卡在 320dp 窗口下内容区仅约 148dp：若「字号 + 数值 + 两个
  /// 44dp 按钮」同行会横向溢出，故改为两行布局；本用例同时用
  /// `tester.drag` 走真实滑动手势，确认松手只提交一次。
  testWidgets('320dp 窄屏：字号卡不溢出、步进按钮触控区 ≥44dp、拖动提交一次',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notifier =
        _CountingReaderNotifier(const ReaderState(fontSize: 20));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerNotifierProvider.overrideWith(() => notifier),
          bookApiProvider.overrideWithValue(MockBookApi()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ReaderSettingsSheet()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull, reason: '320dp 下不得溢出');

    // 触控区：44×44 透明命中区包住 28dp 视觉圆钮
    final minusHitBox = tester.getSize(find
        .ancestor(
          of: find.byIcon(Icons.remove_rounded),
          matching: find.byType(SizedBox),
        )
        .first);
    expect(minusHitBox.width, greaterThanOrEqualTo(44.0));
    expect(minusHitBox.height, greaterThanOrEqualTo(44.0));

    // 真实滑动手势：拖动中不提交，松手恰好一次
    await tester.drag(find.byType(Slider), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(notifier.updates, hasLength(1));
  });
}
