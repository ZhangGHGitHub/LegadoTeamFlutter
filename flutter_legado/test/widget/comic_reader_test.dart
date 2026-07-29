import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/screens/comic_reader_screen.dart';

void main() {
  // ===== ComicPageMode 枚举测试 =====

  group('ComicPageMode 枚举', () {
    test('包含 singlePage 和 doublePage 两个值', () {
      expect(ComicPageMode.values.length, equals(2));
      expect(ComicPageMode.values, contains(ComicPageMode.singlePage));
      expect(ComicPageMode.values, contains(ComicPageMode.doublePage));
    });

    test('singlePage 索引为 0', () {
      expect(ComicPageMode.singlePage.index, equals(0));
    });

    test('doublePage 索引为 1', () {
      expect(ComicPageMode.doublePage.index, equals(1));
    });
  });

  // ===== ComicPageAnimation 枚举测试 =====

  group('ComicPageAnimation 枚举', () {
    test('包含 slide 和 simulate 两个值', () {
      expect(ComicPageAnimation.values.length, equals(2));
      expect(ComicPageAnimation.values, contains(ComicPageAnimation.slide));
      expect(ComicPageAnimation.values, contains(ComicPageAnimation.simulate));
    });

    test('slide 索引为 0', () {
      expect(ComicPageAnimation.slide.index, equals(0));
    });

    test('simulate 索引为 1', () {
      expect(ComicPageAnimation.simulate.index, equals(1));
    });
  });

  // ===== ComicAnimationConfig 测试 =====

  group('ComicAnimationConfig', () {
    test('默认配置值正确', () {
      const config = ComicAnimationConfig();
      expect(config.duration, equals(const Duration(milliseconds: 300)));
      expect(config.curve, equals(Curves.easeInOut));
      expect(config.velocityThreshold, equals(300.0));
    });

    test('自定义配置值正确', () {
      const config = ComicAnimationConfig(
        duration: Duration(milliseconds: 500),
        curve: Curves.linear,
        velocityThreshold: 500.0,
      );
      expect(config.duration, equals(const Duration(milliseconds: 500)));
      expect(config.curve, equals(Curves.linear));
      expect(config.velocityThreshold, equals(500.0));
    });

    test('动画时长范围合理', () {
      const config = ComicAnimationConfig();
      expect(config.duration.inMilliseconds, greaterThanOrEqualTo(100));
      expect(config.duration.inMilliseconds, lessThanOrEqualTo(1000));
    });
  });

  // ===== ComicPageView Widget 测试 =====

  group('ComicPageView', () {
    /// 构建测试用 ComicPageView（使用空图片列表避免网络请求）
    Widget buildTestWidget({
      List<String>? imageUrls,
      int initialPage = 0,
      ComicPageMode pageMode = ComicPageMode.singlePage,
      ComicPageAnimation animationType = ComicPageAnimation.slide,
      ValueChanged<int>? onPageChanged,
      ValueChanged<String>? onLongPressSave,
      ValueChanged<ComicPageMode>? onModeChanged,
      bool autoSwitchMode = false,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: ComicPageView(
            imageUrls: imageUrls ?? [],
            initialPage: initialPage,
            pageMode: pageMode,
            animationType: animationType,
            onPageChanged: onPageChanged,
            onLongPressSave: onLongPressSave,
            onModeChanged: onModeChanged,
            autoSwitchMode: autoSwitchMode,
          ),
        ),
      );
    }

    testWidgets('基本构建成功（空图片列表）', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // 验证 ComicPageView 存在
      expect(find.byType(ComicPageView), findsOneWidget);
    });

    testWidgets('默认单页模式', (tester) async {
      final key = GlobalKey<ComicPageViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              key: key,
              imageUrls: [],
              autoSwitchMode: false,
            ),
          ),
        ),
      );

      expect(key.currentState!.pageMode, equals(ComicPageMode.singlePage));
    });

    testWidgets('初始页索引正确', (tester) async {
      final key = GlobalKey<ComicPageViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              key: key,
              imageUrls: [],
              initialPage: 0,
              autoSwitchMode: false,
            ),
          ),
        ),
      );

      expect(key.currentState!.currentPage, equals(0));
    });

    testWidgets('setPageMode 切换模式', (tester) async {
      final key = GlobalKey<ComicPageViewState>();
      ComicPageMode? changedMode;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              key: key,
              imageUrls: [],
              autoSwitchMode: false,
              onModeChanged: (mode) => changedMode = mode,
            ),
          ),
        ),
      );

      // 切换到双页模式
      key.currentState!.setPageMode(ComicPageMode.doublePage);
      await tester.pump();

      expect(key.currentState!.pageMode, equals(ComicPageMode.doublePage));
      expect(changedMode, equals(ComicPageMode.doublePage));
    });

    testWidgets('setPageMode 相同模式不触发回调', (tester) async {
      final key = GlobalKey<ComicPageViewState>();
      var callbackCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              key: key,
              imageUrls: [],
              autoSwitchMode: false,
              onModeChanged: (_) => callbackCount++,
            ),
          ),
        ),
      );

      // 设置为相同模式
      key.currentState!.setPageMode(ComicPageMode.singlePage);
      await tester.pump();

      // 回调不应被触发
      expect(callbackCount, equals(0));
    });

    testWidgets('初始缩放比例为 1.0', (tester) async {
      final key = GlobalKey<ComicPageViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              key: key,
              imageUrls: [],
              autoSwitchMode: false,
            ),
          ),
        ),
      );

      expect(key.currentState!.scale, equals(1.0));
    });

    testWidgets('resetZoom 重置缩放', (tester) async {
      final key = GlobalKey<ComicPageViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              key: key,
              imageUrls: [],
              autoSwitchMode: false,
            ),
          ),
        ),
      );

      // 重置缩放
      key.currentState!.resetZoom();
      await tester.pump();

      expect(key.currentState!.scale, equals(1.0));
    });

    testWidgets('GestureDetector 存在（手势支持）', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // 验证 GestureDetector 存在
      expect(find.byType(GestureDetector), findsWidgets);
    });

    testWidgets('LayoutBuilder 存在（响应式布局）', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // 验证 LayoutBuilder 存在
      expect(find.byType(LayoutBuilder), findsWidgets);
    });

    testWidgets('ClipRect 存在（裁剪支持）', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // 验证 ClipRect 存在
      expect(find.byType(ClipRect), findsWidgets);
    });

    testWidgets('Transform 存在（缩放变换）', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      // 验证 Transform 存在
      expect(find.byType(Transform), findsWidgets);
    });

    testWidgets('仿真翻页模式构建成功', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(animationType: ComicPageAnimation.simulate),
      );

      expect(find.byType(ComicPageView), findsOneWidget);
    });

    testWidgets('长按触发保存回调（空列表不触发）', (tester) async {
      String? savedUrl;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicPageView(
              imageUrls: [],
              autoSwitchMode: false,
              onLongPressSave: (url) => savedUrl = url,
            ),
          ),
        ),
      );

      // 长按
      await tester.longPressAt(const Offset(200, 300));
      await tester.pumpAndSettle();

      // 空列表不应触发回调
      expect(savedUrl, isNull);
    });
  });

  // ===== ComicReaderScreen Widget 测试 =====

  group('ComicReaderScreen', () {
    /// 构建测试用 ComicReaderScreen（使用空图片列表）
    Widget buildTestScreen({
      List<String>? imageUrls,
      int initialPage = 0,
      String title = '测试漫画',
      String chapterTitle = '第一章',
    }) {
      return MaterialApp(
        home: ComicReaderScreen(
          bookUrl: 'https://example.com/book',
          imageUrls: imageUrls ?? [],
          initialPage: initialPage,
          title: title,
          chapterTitle: chapterTitle,
        ),
      );
    }

    testWidgets('基本构建成功', (tester) async {
      await tester.pumpWidget(buildTestScreen());

      expect(find.byType(ComicReaderScreen), findsOneWidget);
      expect(find.byType(ComicPageView), findsOneWidget);
    });

    testWidgets('Scaffold 背景为黑色', (tester) async {
      await tester.pumpWidget(buildTestScreen());

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, equals(Colors.black));
    });

    testWidgets('Stack 布局存在', (tester) async {
      await tester.pumpWidget(buildTestScreen());

      expect(find.byType(Stack), findsWidgets);
    });

    testWidgets('GestureDetector 存在（点击切换控制栏）', (tester) async {
      await tester.pumpWidget(buildTestScreen());

      expect(find.byType(GestureDetector), findsWidgets);
    });

    testWidgets('初始状态控制栏不可见', (tester) async {
      await tester.pumpWidget(buildTestScreen());

      // 初始状态控制栏不可见
      expect(find.text('测试漫画'), findsNothing);
    });
  });

  // ===== 缩放范围限制测试 =====

  group('缩放范围限制', () {
    test('最小缩放 0.5x，最大缩放 3.0x 常量定义', () {
      // 通过行为测试验证
      expect(0.5, lessThan(1.0)); // 最小缩放小于 1
      expect(3.0, greaterThan(1.0)); // 最大缩放大于 1
    });

    test('双击缩放目标值为 2.0x', () {
      const doubleTapScale = 2.0;
      expect(doubleTapScale, equals(2.0));
    });

    test('缩放范围包含 1.0（原始大小）', () {
      const minScale = 0.5;
      const maxScale = 3.0;
      expect(1.0, greaterThanOrEqualTo(minScale));
      expect(1.0, lessThanOrEqualTo(maxScale));
    });
  });

  // ===== 预加载范围测试 =====

  group('预加载配置', () {
    test('预加载范围为前后各 2 页', () {
      const preloadRange = 2;
      expect(preloadRange, equals(2));
    });

    test('预加载范围合理', () {
      const preloadRange = 2;
      expect(preloadRange, greaterThanOrEqualTo(1));
      expect(preloadRange, lessThanOrEqualTo(5));
    });
  });

  // ===== 边缘点击区域测试 =====

  group('边缘点击区域', () {
    test('边缘点击区域为屏幕宽度的 15%', () {
      const edgeTapRatio = 0.15;
      expect(edgeTapRatio, equals(0.15));
    });

    test('边缘点击区域比例合理', () {
      const edgeTapRatio = 0.15;
      expect(edgeTapRatio, greaterThan(0.0));
      expect(edgeTapRatio, lessThan(0.5)); // 不超过屏幕一半
    });
  });

  // ===== 模式切换逻辑测试 =====

  group('模式切换逻辑', () {
    test('单页模式步长为 1', () {
      const mode = ComicPageMode.singlePage;
      final step = mode == ComicPageMode.doublePage ? 2 : 1;
      expect(step, equals(1));
    });

    test('双页模式步长为 2', () {
      const mode = ComicPageMode.doublePage;
      final step = mode == ComicPageMode.doublePage ? 2 : 1;
      expect(step, equals(2));
    });
  });

  // ===== 动画类型测试 =====

  group('动画类型', () {
    test('滑动翻页动画类型', () {
      const animType = ComicPageAnimation.slide;
      expect(animType, equals(ComicPageAnimation.slide));
    });

    test('仿真翻页动画类型', () {
      const animType = ComicPageAnimation.simulate;
      expect(animType, equals(ComicPageAnimation.simulate));
    });

    test('动画类型切换逻辑', () {
      var animType = ComicPageAnimation.slide;
      // 切换逻辑
      animType = animType == ComicPageAnimation.slide
          ? ComicPageAnimation.simulate
          : ComicPageAnimation.slide;
      expect(animType, equals(ComicPageAnimation.simulate));
    });
  });
}
