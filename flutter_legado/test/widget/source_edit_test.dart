// 书源编辑页 widget 测试
//
// 验证 Phase 5.1 书源编辑表单（对标 Android BookSourceEditActivity）：
// - 8 个 Tab：基本信息/搜索规则/发现规则/详情规则/目录规则/内容规则/评论规则/测试
// - 发现/详情/评论 Tab 的字段与开关可见
// - 必填校验（书源名称/URL）与保存创建
// - 编辑模式回填发现/详情/评论规则
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/source/source_notifier.dart';
import 'package:flutter_legado/src/screens/source_edit_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 在底层页面上 push 书源编辑页，便于验证保存后的返回行为
  Future<void> pumpEdit(WidgetTester tester, {String? sourceUrl}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SourceEditScreen(sourceUrl: sourceUrl),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('SourceEditScreen 多 Tab 结构', () {
    testWidgets('新建模式渲染 8 个规则 Tab', (tester) async {
      await pumpEdit(tester);

      expect(find.text('新建书源'), findsOneWidget);
      final tabBar = find.byType(TabBar);
      expect(tabBar, findsOneWidget);
      for (final label in const [
        '基本信息',
        '搜索规则',
        '发现规则',
        '详情规则',
        '目录规则',
        '内容规则',
        '评论规则',
        '测试',
      ]) {
        expect(
          find.descendant(of: tabBar, matching: find.text(label)),
          findsOneWidget,
          reason: 'TabBar 应包含「$label」',
        );
      }
    });

    testWidgets('切换到发现/详情/评论 Tab 展示对应字段与开关', (tester) async {
      // 加高可视区域，确保各 Tab 列表字段完整构建
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpEdit(tester);

      // 发现规则
      await tester.tap(find.text('发现规则'));
      await tester.pumpAndSettle();
      expect(find.text('启用发现'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '发现 URL'), findsOneWidget);

      // 详情规则
      await tester.tap(find.text('详情规则'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '目录 URL'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '修改书名'), findsOneWidget);

      // 评论规则
      await tester.tap(find.text('评论规则'));
      await tester.pumpAndSettle();
      expect(find.text('启用段评'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '段评 URL'), findsOneWidget);
    });
  });

  group('SourceEditScreen 校验与保存', () {
    testWidgets('必填字段为空时阻止保存并提示', (tester) async {
      await pumpEdit(tester);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('请输入书源名称'), findsOneWidget);
      expect(find.text('请输入书源 URL'), findsOneWidget);
      verifyNever(() => mockApi.addBookSource(any()));
    });

    testWidgets('填写名称与 URL 后保存成功创建书源', (tester) async {
      when(
        () => mockApi.addBookSource(any()),
      ).thenAnswer((inv) async => inv.positionalArguments[0] as BookSource);
      await pumpEdit(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, '书源名称 *'),
        '测试书源',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '书源 URL *'),
        'https://test.com',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('书源已创建'), findsOneWidget);
      final captured =
          verify(() => mockApi.addBookSource(captureAny())).captured.single
              as BookSource;
      expect(captured.bookSourceName, '测试书源');
      expect(captured.bookSourceUrl, 'https://test.com');
      // 保存后返回上一页
      expect(find.byType(SourceEditScreen), findsNothing);
    });
  });

  group('SourceEditScreen 编辑模式回填', () {
    testWidgets('回填发现/详情/评论规则字段与开关', (tester) async {
      // 加高可视区域，确保各 Tab 列表字段完整构建
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const source = BookSource(
        bookSourceUrl: 'https://edit.com',
        bookSourceName: '可编辑源',
        exploreUrl: '分类::https://edit.com/sort',
        ruleExplore: ExploreRule(bookList: '.explore-list', name: '.e-name'),
        ruleBookInfo: BookInfoRule(init: '.init', tocUrl: '.toc'),
        ruleReview: ReviewRule(enabled: true, reviewUrl: '.review'),
      );
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [source]);
      // 预加载书源到 notifier 状态
      await container.read(sourceNotifierProvider.notifier).loadSources();

      await pumpEdit(tester, sourceUrl: 'https://edit.com');

      // 标题为编辑模式
      expect(find.text('编辑书源'), findsOneWidget);
      // 基本信息回填
      expect(find.text('可编辑源'), findsOneWidget);

      // 发现规则回填
      await tester.tap(find.text('发现规则'));
      await tester.pumpAndSettle();
      expect(find.text('分类::https://edit.com/sort'), findsOneWidget);
      expect(find.text('.explore-list'), findsOneWidget);

      // 详情规则回填
      await tester.tap(find.text('详情规则'));
      await tester.pumpAndSettle();
      expect(find.text('.init'), findsOneWidget);
      expect(find.text('.toc'), findsOneWidget);

      // 评论规则回填（开关开启 + URL）
      await tester.tap(find.text('评论规则'));
      await tester.pumpAndSettle();
      expect(find.text('.review'), findsOneWidget);
      final reviewSwitch = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '启用段评'),
      );
      expect(reviewSwitch.value, isTrue);
    });
  });
}
