// 主题配置页 widget 测试
//
// [队列⑦c A3] IA 对齐参考版 ThemeConfigScreen.kt：页标题「外观」；
// 新增「主题模式」分组（主题模式三段选择器 + 13 内置色卡）置于页首，
// 通用组重排（纯黑深色模式→切换图标→字体大小→主题管理→导出/导入→…），
// 「顶栏与布局」+「底栏与导航」合并为「主界面」，「详情与圆角」拆为
// 「书籍详情页」+「容器设置」，「毛玻璃」改名「模糊效果」；
// 「导出/导入」并入通用组（不再页首）；参考独有功能仅登记不实现。
// 关键分组标题断言见各 test；惰性列表需滚动到可见区再断言。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ThemeConfigScreen()),
    );
  }

  Future<void> openThemeManage(WidgetTester tester) async {
    await tester.dragUntilVisible(
      find.text('主题管理'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题管理'));
    await tester.pumpAndSettle();
  }

  Future<List<Map<String, dynamic>>> readThemeList() async {
    final prefs = await SharedPreferences.getInstance();
    return (jsonDecode(prefs.getString('themeConfigList')!) as List)
        .cast<Map<String, dynamic>>();
  }

  testWidgets('主界面组提供多栏布局入口并写入偏好（设置批2b-2b）', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('大屏导航形态'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    expect(find.text('多栏布局'), findsOneWidget);
    expect(find.text('自动（宽窗口）'), findsOneWidget);

    await tester.tap(find.text('多栏布局'));
    await tester.pumpAndSettle();
    // 四档条目（参考版 multi_pane_layout_entries 中文文案）
    expect(find.text('自动（宽窗口）'), findsWidgets);
    expect(find.text('横屏开启（宽窗口）'), findsOneWidget);
    expect(find.text('始终开启（空间足够时）'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('横屏开启（宽窗口）'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.multiPaneMode), 'landscape');
    expect(find.text('横屏开启（宽窗口）'), findsOneWidget);
  });

  testWidgets('渲染关键分组标题与自定义主题分组（IA 对齐参考版）', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 页首「主题模式」分组（三段主题模式选择器 + 13 色卡）：分组标题 +
    // 选择器 浅色/深色 段（"跟随系统"与字体大小副标题重名，不做唯一断言）
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    // [2.0.268/2.0.269 用户裁决] 配色轮卡/外观预览卡已移除
    expect(find.text('配色轮'), findsNothing);
    expect(find.text('外观预览'), findsNothing);

    // 13 色卡（默认 def「默认」选中；[队列⑦a A2] 显示名对齐参考 zh 名）
    await tester.dragUntilVisible(
      find.text('黑白'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('黑白'), findsOneWidget);
    expect(find.text('春'), findsOneWidget);
    expect(find.text('电子书'), findsOneWidget);

    // 通用组：纯黑深色模式 → 切换图标 → 字体大小 → 主题管理 → 导出/导入（并入）
    await tester.dragUntilVisible(
      find.text('纯黑深色模式'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('纯黑深色模式'), findsOneWidget);
    expect(find.text('切换图标'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('主题管理'), findsOneWidget);
    expect(find.text('导出主题'), findsOneWidget);
    expect(find.text('导入主题'), findsOneWidget);
    expect(find.text('底栏图集'), findsOneWidget);

    // 「主界面」组（顶栏 + 底栏合并）
    await tester.dragUntilVisible(
      find.text('主界面'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('主界面'), findsOneWidget);

    // 「书籍详情页」组（原详情与圆角的封面三行）
    await tester.dragUntilVisible(
      find.text('书籍详情页'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('书籍详情页'), findsOneWidget);
    expect(find.text('界面颜色跟随封面取色'), findsOneWidget);

    // 「护眼模式」组（[设置批2a-1] 对齐参考版 ThemeConfigScreen：书籍详情页
    // 之后、容器设置之前；默认两开关关闭，强度/定时行收起）
    await tester.dragUntilVisible(
      find.text('护眼模式'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('护眼模式'), findsOneWidget);
    expect(find.text('启用护眼模式'), findsOneWidget);
    expect(find.text('深色模式时自动开启'), findsOneWidget);

    // 「容器设置」组（原详情与圆角的卡片圆角/分隔线两行）。注意页内顺序：
    // 容器设置 位于 模糊效果 之上（书籍详情页→护眼模式→容器设置→模糊效果），
    // 单向下滚的 dragUntilVisible 必须先断言靠上的组，否则滚过后再找上方组会失败
    await tester.dragUntilVisible(
      find.text('容器设置'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('容器设置'), findsOneWidget);
    expect(find.text('显示分隔线'), findsOneWidget);

    // 「模糊效果」组（原"毛玻璃"改名，位于容器设置之后）
    await tester.dragUntilVisible(
      find.text('模糊效果'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('模糊效果'), findsOneWidget);

    // 自定义主题 · 白天 / 夜间（与内置主题并存的双区结构）
    await tester.dragUntilVisible(
      find.text(r'自定义主题 · 白天'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义主题 · 白天'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text(r'自定义主题 · 夜间'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义主题 · 夜间'), findsOneWidget);
  });

  testWidgets('内置主题网格点按切换调色板并更新 ThemeState', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 默认调色板为 def「默认」（阶段D 2.0.270 起；黑白等 12 套保留可切换）
    expect(container.read(themeNotifierProvider).paletteId, equals('def'));

    // [队列⑦c A3] 色卡行位于页首「主题模式」分组，先滚动到可见区
    // [队列⑦a A2] koharu 显示名 小春→春（对齐参考 zh 名）
    await tester.dragUntilVisible(
      find.text('春'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    // 点按「春」（koharu）→ paletteId 更新并持久化
    await tester.tap(find.text('春'));
    await tester.pumpAndSettle();
    expect(container.read(themeNotifierProvider).paletteId, equals('koharu'));
  });

  testWidgets('字体大小对话框可设置倍数并跟随系统重置', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // 字体大小项在通用组，先滚动到可见区
    await tester.dragUntilVisible(
      find.text(r'字体大小'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('字体大小'));
    await tester.pumpAndSettle();
    expect(find.text('字体缩放'), findsOneWidget);
    // [队列⑦c A3] 对齐参考 font_scale_summary 半角冒号「当前字体大小: 1.0」
    expect(find.text('当前字体大小: 1.0'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('确定')),
    );
    await tester.pumpAndSettle();
    var state = container.read(themeNotifierProvider);
    expect(state.fontScaleRaw, equals(10));
    expect(state.fontScale, equals(1.0));
    // [队列⑦c A3] 半角冒号（对齐参考 font_scale_summary）
    expect(state.fontScaleLabel, equals('当前字体大小: 1.0'));

    await tester.tap(find.text('字体大小'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '跟随系统'),
      ),
    );
    await tester.pumpAndSettle();
    state = container.read(themeNotifierProvider);
    expect(state.fontScaleRaw, equals(0));
    expect(state.fontScale, isNull);
  });

  group('主题管理重命名（批8b）', () {
    const initialList = [
      {
        'name': '日间旧名',
        'isNight': false,
        'primary': 1,
        'accent': 2,
        'background': 3,
        'bottomBackground': 4,
      },
      {
        'name': '夜间旧名',
        'isNight': true,
        'primary': 5,
        'accent': 6,
        'background': 7,
        'bottomBackground': 8,
      },
    ];

    testWidgets('重命名白天主题：持久化 JSON 并刷新界面', (tester) async {
      SharedPreferences.setMockInitialValues({
        'themeConfigList': jsonEncode(initialList),
      });
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await openThemeManage(tester);

      await tester.tap(find.byKey(const ValueKey('theme-config-rename-0')));
      await tester.pumpAndSettle();
      expect(find.text('重命名主题'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('theme-config-rename-field')),
      );
      expect(field.controller?.text, '日间旧名');

      await tester.enterText(
        find.byKey(const ValueKey('theme-config-rename-field')),
        '  新日间  ',
      );
      await tester.tap(
        find.byKey(const ValueKey('theme-config-rename-confirm')),
      );
      await tester.pumpAndSettle();

      expect(find.text('新日间'), findsOneWidget);
      expect(find.text('日间旧名'), findsNothing);
      final stored = await readThemeList();
      expect(stored[0]['name'], '新日间');
      expect(stored[0]['isNight'], isFalse);
      expect(stored[1]['name'], '夜间旧名');
    });

    testWidgets('取消或空名不修改主题名称与偏好', (tester) async {
      SharedPreferences.setMockInitialValues({
        'themeConfigList': jsonEncode(initialList),
      });
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await openThemeManage(tester);

      await tester.tap(find.byKey(const ValueKey('theme-config-rename-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('theme-config-rename-field')),
        '取消名',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('日间旧名'), findsOneWidget);
      expect(find.text('取消名'), findsNothing);
      expect((await readThemeList())[0]['name'], '日间旧名');

      await tester.tap(find.byKey(const ValueKey('theme-config-rename-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('theme-config-rename-field')),
        '   ',
      );
      await tester.tap(
        find.byKey(const ValueKey('theme-config-rename-confirm')),
      );
      await tester.pumpAndSettle();
      expect(find.text('日间旧名'), findsOneWidget);
      expect((await readThemeList())[0]['name'], '日间旧名');
    });

    testWidgets('夜间主题同样支持重命名且保留 isNight', (tester) async {
      SharedPreferences.setMockInitialValues({
        'themeConfigList': jsonEncode(initialList),
      });
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await openThemeManage(tester);

      await tester.tap(find.byKey(const ValueKey('theme-config-rename-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('theme-config-rename-field')),
        '新夜间',
      );
      await tester.tap(
        find.byKey(const ValueKey('theme-config-rename-confirm')),
      );
      await tester.pumpAndSettle();

      expect(find.text('新夜间'), findsOneWidget);
      final stored = await readThemeList();
      expect(stored[1]['name'], '新夜间');
      expect(stored[1]['isNight'], isTrue);
      expect(stored[0]['name'], '日间旧名');
    });

    testWidgets('320dp 下「测试夜间」完整显示、副标题单行且按钮可点', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'themeConfigList': jsonEncode([
          {
            'name': '测试夜间',
            'isNight': true,
            'primary': 1,
            'accent': 2,
            'background': 3,
            'bottomBackground': 4,
          },
        ]),
      });
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await openThemeManage(tester);

      final item = find.byKey(const ValueKey('theme-config-item-0'));
      final title = find.descendant(of: item, matching: find.text('测试夜间'));
      final subtitle = find.descendant(of: item, matching: find.text('夜间主题'));
      expect(title, findsOneWidget);
      expect(subtitle, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
        isFalse,
        reason: '「测试夜间」不得截断',
      );
      expect(
        tester.renderObject<RenderParagraph>(subtitle).didExceedMaxLines,
        isFalse,
        reason: '副标题必须单行',
      );
      expect(tester.takeException(), isNull);

      // 重命名按钮可点
      await tester.tap(find.byKey(const ValueKey('theme-config-rename-0')));
      await tester.pumpAndSettle();
      expect(find.text('重命名主题'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 删除按钮可点，且不会误触行点击应用
      await tester.tap(find.byKey(const ValueKey('theme-config-delete-0')));
      await tester.pumpAndSettle();
      expect(item, findsNothing);
      expect((await readThemeList()), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360dp 8 个中文字符标题完整显示', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'themeConfigList': jsonEncode([
          {
            'name': '测试夜间主题名称',
            'isNight': true,
            'primary': 1,
            'accent': 2,
            'background': 3,
            'bottomBackground': 4,
          },
        ]),
      });
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await openThemeManage(tester);

      final title = find.descendant(
        of: find.byKey(const ValueKey('theme-config-item-0')),
        matching: find.text('测试夜间主题名称'),
      );
      expect(title, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
        isFalse,
        reason: '8 个中文字符不得截断',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('320dp 长名称省略且无 overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'themeConfigList': jsonEncode([
          {
            'name': '这是一个非常非常非常长的主题名称用于验证窄屏列表行不会溢出',
            'isNight': false,
            'primary': 1,
            'accent': 2,
            'background': 3,
            'bottomBackground': 4,
          },
        ]),
      });
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await openThemeManage(tester);

      final item = find.byKey(const ValueKey('theme-config-item-0'));
      final title = find.descendant(
        of: item,
        matching: find.text('这是一个非常非常非常长的主题名称用于验证窄屏列表行不会溢出'),
      );
      final subtitle = find.descendant(of: item, matching: find.text('白天主题'));
      expect(title, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
        isTrue,
        reason: '超长名称才省略',
      );
      expect(
        tester.renderObject<RenderParagraph>(subtitle).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('theme-config-rename-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('theme-config-delete-0')),
        findsOneWidget,
      );
    });
  });
}
